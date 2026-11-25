-- ChopPool update 54: customers invite vendors safely (ChopPool sends the link, never the customer); vendors sign in
-- with their phone number and a 4-digit PIN; login codes and invites go by WhatsApp or SMS. Safe to run more than once.

-- ---------- 1. Settings ----------
alter table settings add column if not exists msg_first text not null default 'whatsapp';   -- which channel is tried first
alter table settings drop constraint if exists settings_msg_first_chk;
alter table settings add constraint settings_msg_first_chk check (msg_first in ('whatsapp', 'sms'));
alter table settings add column if not exists wa_ready boolean not null default true;        -- WhatsApp on (also needs WHATSAPP_TOKEN)
alter table settings add column if not exists sms_ready boolean not null default false;      -- switch on once Arkesel approves "ChopPool"
alter table settings add column if not exists msg_reply text;                                -- auto-reply when someone messages the alerts number
alter table settings add column if not exists invites_per_day int not null default 3;        -- new vendors one customer can invite a day

-- ---------- 2. Vendor fields ----------
alter table kitchens add column if not exists phone text;                -- 233XXXXXXXXX, one vendor per number
alter table kitchens add column if not exists invite_status text;        -- pending, sent, team, claimed, declined, merged
alter table kitchens add column if not exists invite_channel text;       -- whatsapp, sms, team
alter table kitchens add column if not exists invite_sent_at timestamptz;
alter table kitchens add column if not exists invite_error text;
alter table kitchens add column if not exists dup_of uuid;               -- possible duplicate of this vendor (team checks)
alter table kitchens add column if not exists wants_wider boolean not null default false;   -- vendor asked to serve other buildings
alter table kitchens add column if not exists setup_help boolean not null default false;    -- vendor asked the team to set up the menu
alter table kitchens add column if not exists suggested_dishes text[];   -- dish names the customer gave (no prices)
alter table kitchens add column if not exists declined_at timestamptz;

create or replace function phone_norm(p text) returns text
language sql immutable as $$
  select case when d ~ '^0[0-9]{9}$' then '233' || substr(d, 2)
              when d ~ '^233[0-9]{9}$' then d
              when d ~ '^[1-9][0-9]{8}$' then '233' || d end
    from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) x;
$$;

-- Existing vendors get their number in the standard form. Two vendors on one number: the oldest keeps it, the others are flagged.
with c as (
  select id, phone_norm(whatsapp) as ph, row_number() over (partition by phone_norm(whatsapp) order by created_at, id) as n,
         first_value(id) over (partition by phone_norm(whatsapp) order by created_at, id) as first_id
    from kitchens where not archived and phone_norm(whatsapp) is not null)
update kitchens k set phone = case when c.n = 1 then c.ph end, dup_of = case when c.n > 1 then c.first_id else k.dup_of end
  from c where k.id = c.id and k.phone is null and not exists (select 1 from kitchens x where x.phone = c.ph);
create unique index if not exists kitchens_phone_uniq on kitchens (phone) where not archived and phone is not null;

-- Vendors the team adds, or whose WhatsApp number changes, keep their sign-in number in step (unless another vendor has it)
create or replace function kitchens_phone_sync() returns trigger
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if tg_op = 'INSERT' and new.phone is not null then return new; end if;
  if tg_op = 'UPDATE' and new.whatsapp is not distinct from old.whatsapp then return new; end if;
  v := phone_norm(new.whatsapp);
  if v is not null and not exists (select 1 from kitchens x where x.phone = v and not x.archived and x.id <> new.id) then new.phone := v; end if;
  return new;
end $$;
drop trigger if exists kitchens_phone_sync on kitchens;
create trigger kitchens_phone_sync before insert or update of whatsapp on kitchens for each row execute function kitchens_phone_sync();

-- Sign-in secrets: nobody reads this table directly, not even the team
create table if not exists vendor_auth (
  kitchen_id uuid primary key references kitchens(id) on delete cascade,
  invite_code text unique,              -- the setup link ChopPool sends her
  invite_created_at timestamptz,
  invite_used_at timestamptz,
  pin_hash text,
  pin_fails int not null default 0,
  locked_until timestamptz,
  reset_hash text,                      -- "Forgot PIN" code (sha256), 10 minutes
  reset_expires timestamptz,
  reset_tries int not null default 0,
  reset_last_at timestamptz,
  reset_day date,
  reset_count int not null default 0
);
alter table vendor_auth enable row level security;
revoke all on vendor_auth from anon, authenticated;

-- Customers waiting for a vendor (the invite, "Remind", and asking for a vendor from another building)
create table if not exists vendor_waiters (
  kitchen_id uuid not null references kitchens(id) on delete cascade,
  user_id uuid not null,
  site_id uuid references sites(id),
  created_at timestamptz not null default now(),
  reminded_at timestamptz,
  primary key (kitchen_id, user_id)
);
alter table vendor_waiters enable row level security;
drop policy if exists "team reads waiters" on vendor_waiters;
create policy "team reads waiters" on vendor_waiters for select to authenticated using (is_admin());
revoke all on vendor_waiters from anon;
grant select on vendor_waiters to authenticated;

-- Every WhatsApp/SMS ChopPool sends or receives (team only)
create table if not exists msg_log (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  kind text not null,                   -- login_code, vendor_invite, vendor_code, test, inbound, auto_reply
  phone text,
  channel text,                         -- whatsapp, sms, team
  status text not null,                 -- sent, failed, received, delivered, read
  detail text,
  ref text,                             -- WhatsApp message id
  kitchen_id uuid references kitchens(id) on delete set null
);
create index if not exists msg_log_created_idx on msg_log (created_at desc);
create index if not exists msg_log_ref_idx on msg_log (ref) where ref is not null;
alter table msg_log enable row level security;
drop policy if exists "team reads messages" on msg_log;
create policy "team reads messages" on msg_log for select to authenticated using (is_admin());
revoke all on msg_log from anon;
grant select on msg_log to authenticated;

-- ---------- 3. Matching names ----------
-- "Auntie Ama's Kitchen" and "Aunty Ama" are the same name for duplicate checks; "Ama" matches "Ama Waakye"
create or replace function name_words(p text) returns text
language sql immutable as $$
  select trim(regexp_replace(regexp_replace(lower(coalesce(p, '')),
           '\m(auntie|aunty|aunt|mama|maame|ma|sister|sis|madam|mummy|mum|kitchen|kitchens|chop|bar|chopbar|joint|spot|food|foods|restaurant|eatery|canteen|the|and|s)\M', ' ', 'g'),
         '[^a-z0-9]+', ' ', 'g'));
$$;
create or replace function name_key(p text) returns text
language sql immutable as $$ select replace(name_words(p), ' ', ''); $$;
create or replace function name_sim(a text, b text) returns numeric
language plpgsql immutable as $$
declare ka text := name_key(a); kb text := name_key(b); wa text[]; wb text[]; ta text[]; tb text[]; inter int;
begin
  if ka = '' or kb = '' then return 0; end if;
  if ka = kb then return 1; end if;
  if least(length(ka), length(kb)) >= 4 and (strpos(ka, kb) > 0 or strpos(kb, ka) > 0) then return 0.8; end if;
  -- every word of the shorter name is in the longer one ("Ama" / "Ama Waakye")
  wa := array_remove(string_to_array(name_words(a), ' '), ''); wb := array_remove(string_to_array(name_words(b), ' '), '');
  if cardinality(wa) > cardinality(wb) then ta := wa; wa := wb; wb := ta; end if;
  if cardinality(wa) > 0 and wa <@ wb and (select min(length(x)) from unnest(wa) x) >= 3 then return 0.7; end if;
  ka := '  ' || ka || ' '; kb := '  ' || kb || ' ';
  select array_agg(distinct substr(ka, g, 3)) into ta from generate_series(1, length(ka) - 2) g;
  select array_agg(distinct substr(kb, g, 3)) into tb from generate_series(1, length(kb) - 2) g;
  select count(*) into inter from unnest(ta) x where x = any(tb);
  return round(inter::numeric / (cardinality(ta) + cardinality(tb) - inter), 3);
end $$;

-- Vendors near a spot with a similar name
create or replace function vendor_similar(p_name text, p_lat float8, p_lng float8, p_skip uuid default null) returns json
language sql stable security definer set search_path = public as $$
  select json_agg(json_build_object('id', id, 'name', public_name, 'area', address, 'dist', round(d), 'live', live) order by s desc, d)
    from (select k.id, k.public_name, k.address, dist_m(p_lat, p_lng, k.lat, k.lng) as d, name_sim(k.public_name, p_name) as s,
                 (k.active and k.setup_status is null) as live
            from kitchens k
           where not k.archived and k.lat is not null and k.id is distinct from p_skip
             and coalesce(k.invite_status, '') not in ('declined', 'merged')
             and abs(k.lat - p_lat) < 0.01 and abs(k.lng - p_lng) < 0.01
             and dist_m(p_lat, p_lng, k.lat, k.lng) <= 300 and name_sim(k.public_name, p_name) >= 0.5
           order by s desc, d limit 3) x;
$$;
revoke execute on function vendor_similar(text, float8, float8, uuid) from public, anon, authenticated;

-- ---------- 4. Customer invites a vendor ----------
-- Joining a vendor that already exists: count the customer as waiting for her (or asking for her at their building)
create or replace function vendor_join(p_kitchen uuid, p_user uuid, p_site uuid) returns json
language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where id = p_kitchen;
  insert into vendor_waiters (kitchen_id, user_id, site_id) values (k.id, p_user, p_site) on conflict (kitchen_id, user_id) do update set site_id = excluded.site_id;
  if k.setup_status is null and k.active then
    if k.site_id is null or k.site_id = p_site then return json_build_object('result', 'here', 'id', k.id, 'name', k.public_name); end if;
    return json_build_object('result', 'elsewhere', 'id', k.id, 'name', k.public_name);
  end if;
  if k.setup_status is null then return json_build_object('result', 'paused', 'id', k.id, 'name', k.public_name); end if;
  return json_build_object('result', 'invited_already', 'id', k.id, 'name', k.public_name);
end $$;
revoke execute on function vendor_join(uuid, uuid, uuid) from public, anon, authenticated;

create or replace function vendor_invite(p_site uuid, p_name text, p_phone text, p_lat float8, p_lng float8, p_dishes text[],
                                         p_same uuid default null, p_new boolean default false)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_uid uuid := auth.uid(); si sites; s settings; k kitchens; v_ph text := phone_norm(p_phone); m json;
  v_dishes text[]; v_dup uuid;
begin
  if v_uid is null then raise exception 'Sign in to invite a vendor.'; end if;
  select * into s from settings where id = 1;
  select * into si from sites where id = p_site and active and status = 'active';
  if not found then raise exception 'Pick your building first.'; end if;
  if p_same is not null then   -- "Yes, that's her"
    select * into k from kitchens where id = p_same and not archived and coalesce(invite_status, '') not in ('declined', 'merged');
    if not found then raise exception 'That vendor is no longer on ChopPool.'; end if;
    return vendor_join(k.id, v_uid, p_site);
  end if;
  if char_length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Add the vendor''s name.'; end if;
  if v_ph is null then raise exception 'Enter the vendor''s 10-digit phone number, like 024 123 4567.'; end if;
  if p_lat is null or p_lng is null or p_lat not between 4 and 12 or p_lng not between -4 and 2 then
    raise exception 'Search for where she cooks, or drop a pin on the map.';
  end if;
  -- Same phone number: it's the same vendor
  select * into k from kitchens where phone = v_ph and not archived;
  if found then
    if k.invite_status = 'declined' then
      if k.declined_at > now() - interval '30 days' then
        raise exception 'This vendor asked not to be invited for now. You can invite her again from %.', to_char(k.declined_at + interval '30 days', 'FMDD Mon');
      end if;
      update kitchens set invite_status = 'pending', invite_channel = null, invite_sent_at = null, invite_error = null, declined_at = null,
                          added_by = v_uid, site_id = p_site where id = k.id;
      update vendor_auth set invite_code = encode(gen_random_bytes(9), 'hex'), invite_created_at = now(), invite_used_at = null where kitchen_id = k.id;
      insert into vendor_waiters (kitchen_id, user_id, site_id) values (k.id, v_uid, p_site) on conflict (kitchen_id, user_id) do update set site_id = excluded.site_id, created_at = now();
      return json_build_object('result', 'invited', 'id', k.id, 'name', k.public_name);
    end if;
    return vendor_join(k.id, v_uid, p_site);
  end if;
  -- A similar name close by: ask the customer first
  m := vendor_similar(p_name, p_lat, p_lng);
  if m is not null and not coalesce(p_new, false) then return json_build_object('result', 'similar', 'matches', m); end if;
  if m is not null then v_dup := (m -> 0 ->> 'id')::uuid; end if;
  -- Limits
  if (select count(*) from kitchens where added_by = v_uid and added_by_customer and created_at > now() - interval '1 day') >= coalesce(s.invites_per_day, 3) then
    raise exception 'You can invite % new vendors a day. Try again tomorrow.', coalesce(s.invites_per_day, 3);
  end if;
  if (select count(*) from kitchens where site_id = p_site and added_by_customer and created_at > now() - interval '1 day') >= 10 then
    raise exception 'Too many vendors were invited here today. Ask the ChopPool team to help.';
  end if;
  select array_agg(d) into v_dishes from (
    select distinct on (lower(trim(x))) left(trim(x), 40) as d from unnest(coalesce(p_dishes, '{}')) x where char_length(trim(x)) >= 2 limit 8) t;
  begin
    insert into kitchens (name, public_name, whatsapp, phone, capacity, site_id, added_by_customer, added_by, lat, lng, active,
                          setup_status, invite_status, suggested_dishes, dup_of)
    values (left(trim(p_name), 60), left(trim(p_name), 60), '0' || substr(v_ph, 4), v_ph, 30, p_site, true, v_uid, p_lat, p_lng, false,
            'draft', 'pending', v_dishes, v_dup)
    returning * into k;
  exception when unique_violation then   -- someone invited the same number a moment ago
    select * into k from kitchens where phone = v_ph and not archived;
    return vendor_join(k.id, v_uid, p_site);
  end;
  insert into vendor_auth (kitchen_id, invite_code, invite_created_at) values (k.id, encode(gen_random_bytes(9), 'hex'), now());
  insert into vendor_waiters (kitchen_id, user_id, site_id) values (k.id, v_uid, p_site) on conflict do nothing;
  return json_build_object('result', 'invited', 'id', k.id, 'name', k.public_name);
end $$;
revoke execute on function vendor_invite(uuid, text, text, float8, float8, text[], uuid, boolean) from public, anon;
grant execute on function vendor_invite(uuid, text, text, float8, float8, text[], uuid, boolean) to authenticated;

-- The old "Add a vendor" gave the customer the vendor's link. Closed: an old copy of the app asks to be refreshed.
create or replace function add_vendor(p_site uuid, p_name text, p_whatsapp text, p_items jsonb, p_lat float8 default null, p_lng float8 default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  raise exception 'ChopPool has been updated. Close the app, open it again, then invite the vendor.';
end $$;

-- The customer's vendors that aren't live yet (the "Waiting for…" cards)
create or replace function my_vendor_invites() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
           'id', k.id, 'name', k.public_name, 'invited_at', w.created_at, 'reminded_at', w.reminded_at,
           'status', case when k.invite_status = 'declined' then 'declined' when k.setup_status = 'submitted' then 'checking'
                          when k.invite_status = 'claimed' or k.setup_status = 'returned' then 'setting_up' else 'invited' end,
           'waiting', (select count(*) from vendor_waiters x where x.kitchen_id = k.id)) order by w.created_at desc), '[]'::json)
    from vendor_waiters w join kitchens k on k.id = w.kitchen_id
   where w.user_id = auth.uid() and not k.archived and k.setup_status is not null;
$$;
revoke execute on function my_vendor_invites() from public, anon;
grant execute on function my_vendor_invites() to authenticated;

-- "Remind": goes to the ChopPool team only (once a day per customer). Nothing is sent to the vendor.
create or replace function vendor_remind(p_kitchen uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update vendor_waiters set reminded_at = now()
   where kitchen_id = p_kitchen and user_id = auth.uid() and (reminded_at is null or reminded_at < now() - interval '20 hours');
  if not found then
    if exists (select 1 from vendor_waiters where kitchen_id = p_kitchen and user_id = auth.uid()) then
      raise exception 'You''ve already reminded us today. We''re on it.';
    end if;
    raise exception 'You''re not waiting for this vendor.';
  end if;
end $$;
revoke execute on function vendor_remind(uuid) from public, anon;
grant execute on function vendor_remind(uuid) to authenticated;

create or replace function vendor_wait_stop(p_kitchen uuid) returns void
language sql security definer set search_path = public as $$
  delete from vendor_waiters where kitchen_id = p_kitchen and user_id = auth.uid();
$$;
revoke execute on function vendor_wait_stop(uuid) from public, anon;
grant execute on function vendor_wait_stop(uuid) to authenticated;

-- ---------- 5. Vendor: open the link, set a PIN, sign in ----------
-- The link from ChopPool works until she has set her PIN (so she can come back to finish), then only phone + PIN.
create or replace function vendor_claim(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare a vendor_auth; k kitchens;
begin
  select * into a from vendor_auth where invite_code = p_code and coalesce(p_code, '') <> '';
  if not found then raise exception 'This link isn''t valid. If you''ve set up before, sign in with your phone number and PIN.'; end if;
  select * into k from kitchens where id = a.kitchen_id;
  if k.archived or coalesce(k.invite_status, '') in ('declined', 'merged') then raise exception 'This link isn''t valid any more. Ask ChopPool for a new one.'; end if;
  if a.invite_used_at is not null and a.pin_hash is not null then
    raise exception 'This link has already been used. Sign in with your phone number and PIN.';
  end if;
  if a.invite_created_at < now() - interval '30 days' then raise exception 'This link has expired. Ask ChopPool for a new one.'; end if;
  update vendor_auth set invite_used_at = coalesce(invite_used_at, now()) where kitchen_id = k.id;
  if k.invite_status in ('pending', 'sent', 'team') then update kitchens set invite_status = 'claimed' where id = k.id; end if;
  return json_build_object('token', k.token, 'name', k.public_name, 'status', coalesce(k.setup_status, 'live'), 'has_pin', a.pin_hash is not null);
end $$;
revoke execute on function vendor_claim(text) from public;
grant execute on function vendor_claim(text) to anon, authenticated;

-- "Not interested": no more invites to her number for 30 days
create or replace function vendor_decline(p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare a vendor_auth;
begin
  select * into a from vendor_auth where invite_code = p_code and coalesce(p_code, '') <> '';
  if not found then raise exception 'This link isn''t valid.'; end if;
  update kitchens set invite_status = 'declined', declined_at = now() where id = a.kitchen_id and setup_status is not null;
  update vendor_auth set invite_used_at = now() where kitchen_id = a.kitchen_id;
end $$;
revoke execute on function vendor_decline(text) from public;
grant execute on function vendor_decline(text) to anon, authenticated;

create or replace function pin_ok(p text) returns boolean
language sql immutable as $$
  select p ~ '^\d{4}$' and p !~ '^(\d)\1{3}$' and p not in ('1234', '2345', '3456', '4567', '5678', '6789', '4321', '9876', '0123', '1212', '2580');
$$;

create or replace function vendor_set_pin(p_token text, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare k kitchens;
begin
  select * into k from kitchens where token = p_token and not archived;
  if not found then raise exception 'This link is not valid. Ask ChopPool for a new one.'; end if;
  if coalesce(p_pin, '') !~ '^\d{4}$' then raise exception 'Choose a 4-digit PIN.'; end if;
  if not pin_ok(p_pin) then raise exception 'Pick a PIN that''s harder to guess than %.', p_pin; end if;
  insert into vendor_auth (kitchen_id) values (k.id) on conflict do nothing;
  update vendor_auth set pin_hash = crypt(p_pin, gen_salt('bf', 8)), pin_fails = 0, locked_until = null, invite_used_at = coalesce(invite_used_at, now())
   where kitchen_id = k.id;
end $$;
revoke execute on function vendor_set_pin(text, text) from public;
grant execute on function vendor_set_pin(text, text) to anon, authenticated;

-- Phone + PIN. Returns {token} or {error}: wrong tries must be counted, so this never raises on a wrong PIN.
create or replace function vendor_login(p_phone text, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare k kitchens; a vendor_auth; v_ph text := phone_norm(p_phone);
begin
  select * into k from kitchens where phone = v_ph and not archived and coalesce(invite_status, '') not in ('declined', 'merged');
  if not found then return json_build_object('error', 'Wrong phone number or PIN.'); end if;
  select * into a from vendor_auth where kitchen_id = k.id for update;
  if not found or a.pin_hash is null then return json_build_object('error', 'You haven''t set a PIN yet. Tap Forgot PIN to get a code.'); end if;
  if a.locked_until > now() then return json_build_object('error', 'Too many wrong tries. Wait 15 minutes, or tap Forgot PIN.'); end if;
  if crypt(coalesce(p_pin, ''), a.pin_hash) <> a.pin_hash then
    update vendor_auth set pin_fails = case when pin_fails + 1 >= 5 then 0 else pin_fails + 1 end,
                           locked_until = case when pin_fails + 1 >= 5 then now() + interval '15 minutes' else locked_until end
     where kitchen_id = k.id;
    return json_build_object('error', 'Wrong phone number or PIN.');
  end if;
  update vendor_auth set pin_fails = 0, locked_until = null where kitchen_id = k.id;
  return json_build_object('token', k.token, 'name', k.public_name, 'status', coalesce(k.setup_status, 'live'));
end $$;
revoke execute on function vendor_login(text, text) from public;
grant execute on function vendor_login(text, text) to anon, authenticated;

-- Forgot PIN: the sms function sends the code; this checks it and sets the new PIN. Returns {token} or {error}.
create or replace function vendor_reset_pin(p_phone text, p_code text, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare k kitchens; a vendor_auth; v_ph text := phone_norm(p_phone);
begin
  select * into k from kitchens where phone = v_ph and not archived and coalesce(invite_status, '') not in ('declined', 'merged');
  if not found then return json_build_object('error', 'That code isn''t right. Ask for a new one.'); end if;
  select * into a from vendor_auth where kitchen_id = k.id for update;
  if not found or a.reset_hash is null or a.reset_expires < now() then return json_build_object('error', 'That code has expired. Ask for a new one.'); end if;
  if a.reset_tries >= 5 then return json_build_object('error', 'Too many wrong tries. Ask for a new code.'); end if;
  if encode(digest(coalesce(p_code, ''), 'sha256'), 'hex') <> a.reset_hash then
    update vendor_auth set reset_tries = reset_tries + 1 where kitchen_id = k.id;
    return json_build_object('error', 'That code isn''t right. Check the message and try again.');
  end if;
  if coalesce(p_pin, '') !~ '^\d{4}$' then return json_build_object('error', 'Choose a 4-digit PIN.'); end if;
  if not pin_ok(p_pin) then return json_build_object('error', 'Pick a PIN that''s harder to guess.'); end if;
  update vendor_auth set pin_hash = crypt(p_pin, gen_salt('bf', 8)), pin_fails = 0, locked_until = null, reset_hash = null, reset_expires = null,
                         reset_tries = 0, invite_used_at = coalesce(invite_used_at, now())
   where kitchen_id = k.id;
  return json_build_object('token', k.token, 'name', k.public_name, 'status', coalesce(k.setup_status, 'live'));
end $$;
revoke execute on function vendor_reset_pin(text, text, text) from public;
grant execute on function vendor_reset_pin(text, text, text) to anon, authenticated;

-- What the vendor's phone needs to open the right screen
create or replace function vendor_me(p_token text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('name', k.public_name, 'status', case when k.setup_status is not null then k.setup_status when k.active then 'live' else 'paused' end,
                           'note', k.setup_note, 'has_pin', a.pin_hash is not null)
    from kitchens k left join vendor_auth a on a.kitchen_id = k.id
   where k.token = p_token and not k.archived and coalesce(k.invite_status, '') not in ('declined', 'merged');
$$;
revoke execute on function vendor_me(text) from public;
grant execute on function vendor_me(text) to anon, authenticated;

-- The setup form also shows the customer's dish names, the vendor's phone and her choices
create or replace function vendor_setup_get(p_token text) returns json
language plpgsql stable security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where token = p_token and not coalesce(archived, false);
  if not found then raise exception 'This link is not valid. Ask ChopPool for a new one.'; end if;
  if k.setup_status is null then return json_build_object('live', k.active, 'name', k.public_name); end if;
  return json_build_object(
    'status', k.setup_status, 'note', k.setup_note, 'name', k.public_name, 'tagline', k.tagline, 'owner_name', k.owner_name,
    'whatsapp', k.whatsapp, 'address', k.address, 'lat', k.lat, 'lng', k.lng, 'auto_days', k.auto_days, 'capacity', k.capacity,
    'payout_momo', k.payout_momo, 'payout_network', k.payout_network,
    'invited', k.added_by_customer, 'suggested', coalesce(k.suggested_dishes, '{}'), 'wants_wider', k.wants_wider, 'setup_help', k.setup_help,
    'has_pin', exists (select 1 from vendor_auth a where a.kitchen_id = k.id and a.pin_hash is not null),
    'items', coalesce((select json_agg(json_build_object('id', i.id, 'name', i.name, 'price', i.price, 'addons', i.addons, 'icon', i.icon) order by i.sort_order, i.name)
                       from menu_items i where i.kitchen_id = k.id), '[]'::json));
end $$;

-- "Also serve other buildings nearby" and "Set it up for me"
create or replace function vendor_setup_extra(p_token text, p_wider boolean, p_help boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  update kitchens set wants_wider = coalesce(p_wider, wants_wider), setup_help = coalesce(p_help, setup_help)
   where token = p_token and not archived and setup_status is not null;
  if not found then raise exception 'Your page is already live. Open your vendor page to make changes.'; end if;
end $$;
revoke execute on function vendor_setup_extra(text, boolean, boolean) from public;
grant execute on function vendor_setup_extra(text, boolean, boolean) to anon, authenticated;

-- ---------- 6. Team ----------
-- A new setup link to send by hand (WhatsApp/SMS failed, or she lost it). The old link stops working.
create or replace function admin_vendor_link(p_kitchen uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_code text := encode(gen_random_bytes(9), 'hex');
begin
  if not is_admin() then raise exception 'Only the ChopPool team can do this.'; end if;
  if not exists (select 1 from kitchens where id = p_kitchen and not archived) then raise exception 'Vendor not found.'; end if;
  insert into vendor_auth (kitchen_id, invite_code, invite_created_at) values (p_kitchen, v_code, now())
  on conflict (kitchen_id) do update set invite_code = v_code, invite_created_at = now(), invite_used_at = null;
  update kitchens set invite_status = case when invite_status in ('pending', 'declined') or invite_status is null then 'team' else invite_status end,
                      invite_channel = 'team', invite_sent_at = now(), declined_at = null
   where id = p_kitchen and setup_status is not null;
  return v_code;
end $$;
revoke execute on function admin_vendor_link(uuid) from public, anon;
grant execute on function admin_vendor_link(uuid) to authenticated;

-- A duplicate that isn't live yet: its waiting customers move to the real vendor, then it's archived
create or replace function admin_vendor_merge(p_from uuid, p_into uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Only the ChopPool team can do this.'; end if;
  if p_from = p_into then raise exception 'Pick a different vendor.'; end if;
  if not exists (select 1 from kitchens where id = p_from and setup_status is not null and not archived) then raise exception 'Only a vendor that isn''t live yet can be merged.'; end if;
  if not exists (select 1 from kitchens where id = p_into and not archived) then raise exception 'Vendor not found.'; end if;
  if exists (select 1 from orders where kitchen_id = p_from) then raise exception 'This vendor has orders, so it can''t be merged.'; end if;
  insert into vendor_waiters (kitchen_id, user_id, site_id, created_at, reminded_at)
    select p_into, user_id, site_id, created_at, reminded_at from vendor_waiters where kitchen_id = p_from
    on conflict (kitchen_id, user_id) do nothing;
  delete from vendor_waiters where kitchen_id = p_from;
  update kitchens set archived = true, active = false, invite_status = 'merged', phone = null where id = p_from;
  update kitchens set dup_of = null where dup_of = p_from or id = p_into;
end $$;
revoke execute on function admin_vendor_merge(uuid, uuid) from public, anon;
grant execute on function admin_vendor_merge(uuid, uuid) to authenticated;

create or replace function admin_vendor_not_dup(p_kitchen uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Only the ChopPool team can do this.'; end if;
  update kitchens set dup_of = null where id = p_kitchen;
end $$;
revoke execute on function admin_vendor_not_dup(uuid) from public, anon;
grant execute on function admin_vendor_not_dup(uuid) to authenticated;

-- Customers waiting for a vendor hear when she's live (bell, and push when the app sends it)
create or replace function vendor_tell_waiters(p_kitchen uuid) returns int
language plpgsql security definer set search_path = public as $$
declare k kitchens; n int;
begin
  select * into k from kitchens where id = p_kitchen;
  insert into notifications (user_id, title, body, url, tag, type)
    select w.user_id, k.public_name || ' is on ChopPool', 'You can now order from her. Find her under Vendors.', '/#kitchens', 'vendor-live-' || k.id, 'vendor_live'
      from vendor_waiters w
     where w.kitchen_id = k.id and (k.site_id is null or w.site_id = k.site_id or w.site_id is null)
       and not exists (select 1 from notifications x where x.user_id = w.user_id and x.tag = 'vendor-live-' || k.id);
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function vendor_tell_waiters(uuid) from public, anon, authenticated;

-- Approve (optionally for every building) or send back
drop function if exists admin_vendor_review(uuid, boolean, text);
create or replace function admin_vendor_review(p_kitchen uuid, p_ok boolean, p_note text, p_all_sites boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  if not is_admin() then raise exception 'Only the ChopPool team can do this.'; end if;
  select * into k from kitchens where id = p_kitchen for update;
  if not found or k.setup_status is null then raise exception 'This vendor form isn''t waiting for review.'; end if;
  if p_ok then
    if k.setup_status <> 'submitted' then raise exception 'The vendor hasn''t submitted their form yet.'; end if;
    update kitchens set setup_status = null, setup_note = null, active = true, setup_help = false,
                        invite_status = case when invite_status is null then null else 'claimed' end,
                        site_id = case when coalesce(p_all_sites, false) then null else site_id end,
                        wants_wider = case when coalesce(p_all_sites, false) then false else wants_wider end
     where id = k.id;
    perform vendor_tell_waiters(k.id);
  else
    if char_length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Say what they should change.'; end if;
    update kitchens set setup_status = 'returned', setup_note = left(trim(p_note), 300) where id = k.id;
  end if;
end $$;
revoke execute on function admin_vendor_review(uuid, boolean, text, boolean) from public, anon;
grant execute on function admin_vendor_review(uuid, boolean, text, boolean) to authenticated;

-- Customers at another building want a live vendor: let her serve every building, or clear the requests
create or replace function admin_vendor_open_all(p_kitchen uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Only the ChopPool team can do this.'; end if;
  update kitchens set site_id = null, wants_wider = false where id = p_kitchen and not archived;
  if not found then raise exception 'Vendor not found.'; end if;
  perform vendor_tell_waiters(p_kitchen);
end $$;
revoke execute on function admin_vendor_open_all(uuid) from public, anon;
grant execute on function admin_vendor_open_all(uuid) to authenticated;

create or replace function admin_vendor_requests_clear(p_kitchen uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Only the ChopPool team can do this.'; end if;
  delete from vendor_waiters w using kitchens k
   where w.kitchen_id = p_kitchen and k.id = w.kitchen_id and k.setup_status is null and k.site_id is not null and w.site_id is distinct from k.site_id;
  update kitchens set wants_wider = false where id = p_kitchen;
end $$;
revoke execute on function admin_vendor_requests_clear(uuid) from public, anon;
grant execute on function admin_vendor_requests_clear(uuid) to authenticated;

select 'ChopPool database is up to date (version 54)' as result;
