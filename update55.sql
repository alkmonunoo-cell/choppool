-- ChopPool update 55: one vendor, several branches. The owner's phone number and PIN sign in to all her branches;
-- each branch has its own location, menu, days and (optionally) its own phone for riders. Safe to run more than once.

alter table kitchens add column if not exists parent_id uuid references kitchens(id) on delete set null;   -- set = a branch of that vendor
create index if not exists kitchens_parent_idx on kitchens (parent_id) where parent_id is not null;

-- Branches don't take the sign-in number (the owner has it), even when the branch phone is a different number
create or replace function kitchens_phone_sync() returns trigger
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if new.parent_id is not null then new.phone := null; return new; end if;
  if tg_op = 'INSERT' and new.phone is not null then return new; end if;
  if tg_op = 'UPDATE' and new.whatsapp is not distinct from old.whatsapp and new.parent_id is not distinct from old.parent_id then return new; end if;
  v := phone_norm(new.whatsapp);
  if v is not null and not exists (select 1 from kitchens x where x.phone = v and not x.archived and x.id <> new.id) then new.phone := v; end if;
  return new;
end $$;
drop trigger if exists kitchens_phone_sync on kitchens;
create trigger kitchens_phone_sync before insert or update of whatsapp, parent_id on kitchens for each row execute function kitchens_phone_sync();

-- A new branch copies the owner's menu, days, payout and details
create or replace function vendor_branch_new(p_parent uuid, p_lat float8, p_lng float8, p_site uuid, p_by uuid, p_status text) returns kitchens
language plpgsql security definer set search_path = public, extensions as $$
declare m kitchens; k kitchens;
begin
  select * into m from kitchens where id = p_parent;
  if (select count(*) from kitchens where parent_id = m.id and not archived) >= 10 then raise exception 'A vendor can have up to 10 branches. Ask ChopPool for more.'; end if;
  insert into kitchens (name, public_name, tagline, owner_name, whatsapp, capacity, delivery_mode, site_id, added_by_customer, added_by, lat, lng, active,
                        setup_status, invite_status, parent_id, auto_days, payout_momo, payout_network, fee_ack, fee_free_ack)
  values (m.name, m.public_name, m.tagline, m.owner_name, m.whatsapp, m.capacity, m.delivery_mode, p_site, p_by is not null, p_by, p_lat, p_lng, false,
          'draft', p_status, m.id, m.auto_days, m.payout_momo, m.payout_network, m.fee_ack, m.fee_free_ack)
  returning * into k;
  insert into menu_items (kitchen_id, name, price, addons, active, icon, sort_order)
    select k.id, name, price, addons, active, icon, sort_order from menu_items where kitchen_id = m.id and active;
  insert into vendor_auth (kitchen_id, invite_code, invite_created_at) values (k.id, encode(gen_random_bytes(9), 'hex'), now());
  return k;
end $$;
revoke execute on function vendor_branch_new(uuid, float8, float8, uuid, uuid, text) from public, anon, authenticated;


create or replace function vendor_similar(p_name text, p_lat float8, p_lng float8, p_skip uuid default null) returns json
language sql stable security definer set search_path = public as $$
  select json_agg(json_build_object('id', id, 'name', public_name, 'area', address, 'dist', round(d), 'live', live) order by s desc, d)
    from (select k.id, k.public_name, k.address, dist_m(p_lat, p_lng, k.lat, k.lng) as d, name_sim(k.public_name, p_name) as s,
                 (k.active and k.setup_status is null) as live
            from kitchens k
           where not k.archived and k.lat is not null and k.id is distinct from p_skip
             and coalesce(k.invite_status, '') not in ('declined', 'merged', 'not_mine')
             and abs(k.lat - p_lat) < 0.01 and abs(k.lng - p_lng) < 0.01
             and dist_m(p_lat, p_lng, k.lat, k.lng) <= 300 and name_sim(k.public_name, p_name) >= 0.5
           order by s desc, d limit 3) x;
$$;
revoke execute on function vendor_similar(text, float8, float8, uuid) from public, anon, authenticated;

-- ---------- Customer: the same number far away may be another branch ----------
drop function if exists vendor_invite(uuid, text, text, float8, float8, text[], uuid, boolean);
create or replace function vendor_invite(p_site uuid, p_name text, p_phone text, p_lat float8, p_lng float8, p_dishes text[],
                                         p_same uuid default null, p_new boolean default false, p_branch boolean default null)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_uid uuid := auth.uid(); si sites; s settings; k kitchens; n kitchens; v_ph text := phone_norm(p_phone); m json;
  v_dishes text[]; v_dup uuid; v_dist float8;
begin
  if v_uid is null then raise exception 'Sign in to invite a vendor.'; end if;
  select * into s from settings where id = 1;
  select * into si from sites where id = p_site and active and status = 'active';
  if not found then raise exception 'Pick your building first.'; end if;
  if p_same is not null then   -- "Yes, that's her"
    select * into k from kitchens where id = p_same and not archived and coalesce(invite_status, '') not in ('declined', 'merged', 'not_mine');
    if not found then raise exception 'That vendor is no longer on ChopPool.'; end if;
    return vendor_join(k.id, v_uid, p_site);
  end if;
  if char_length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Add the vendor''s name.'; end if;
  if v_ph is null then raise exception 'Enter the vendor''s 10-digit phone number, like 024 123 4567.'; end if;
  if p_lat is null or p_lng is null or p_lat not between 4 and 12 or p_lng not between -4 and 2 then
    raise exception 'Search for where she cooks, or drop a pin on the map.';
  end if;
  -- Same phone number: the same vendor (one of her branches, or a new branch of hers)
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
    if k.setup_status is not null or k.lat is null then return vendor_join(k.id, v_uid, p_site); end if;   -- not live yet: nothing to branch from
    -- her branch nearest the pin
    select x.* into n from kitchens x where (x.id = k.id or x.parent_id = k.id) and not x.archived and x.lat is not null
       and coalesce(x.invite_status, '') not in ('declined', 'merged', 'not_mine')
     order by dist_m(p_lat, p_lng, x.lat, x.lng) limit 1;
    v_dist := dist_m(p_lat, p_lng, n.lat, n.lng);
    if v_dist <= 300 then return vendor_join(n.id, v_uid, p_site); end if;
    if p_branch is null then   -- ask the customer first
      return json_build_object('result', 'branch_q', 'id', n.id, 'name', k.public_name,
        'area', coalesce(nullif(n.address, ''), (select name from sites where id = n.site_id), 'another area'), 'dist', round(v_dist));
    end if;
    if not p_branch then   -- "No": probably a wrong number; the team checks
      raise exception 'That number belongs to another vendor on ChopPool. Check the number, or ask the ChopPool team to help.';
    end if;
    if (select count(*) from kitchens where added_by = v_uid and added_by_customer and created_at > now() - interval '1 day') >= coalesce(s.invites_per_day, 3) then
      raise exception 'You can invite % new vendors a day. Try again tomorrow.', coalesce(s.invites_per_day, 3);
    end if;
    n := vendor_branch_new(k.id, p_lat, p_lng, p_site, v_uid, 'pending');
    update kitchens set suggested_dishes = (select array_agg(left(trim(x), 40)) from unnest(coalesce(p_dishes, '{}')) x where char_length(trim(x)) >= 2) where id = n.id;
    insert into vendor_waiters (kitchen_id, user_id, site_id) values (n.id, v_uid, p_site) on conflict do nothing;
    return json_build_object('result', 'branch_asked', 'id', n.id, 'name', k.public_name);
  end if;
  -- A similar name close by: ask the customer first
  m := vendor_similar(p_name, p_lat, p_lng);
  if m is not null and not coalesce(p_new, false) then return json_build_object('result', 'similar', 'matches', m); end if;
  if m is not null then v_dup := (m -> 0 ->> 'id')::uuid; end if;
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
  exception when unique_violation then
    select * into k from kitchens where phone = v_ph and not archived;
    return vendor_join(k.id, v_uid, p_site);
  end;
  insert into vendor_auth (kitchen_id, invite_code, invite_created_at) values (k.id, encode(gen_random_bytes(9), 'hex'), now());
  insert into vendor_waiters (kitchen_id, user_id, site_id) values (k.id, v_uid, p_site) on conflict do nothing;
  return json_build_object('result', 'invited', 'id', k.id, 'name', k.public_name);
end $$;
revoke execute on function vendor_invite(uuid, text, text, float8, float8, text[], uuid, boolean, boolean) from public, anon;
grant execute on function vendor_invite(uuid, text, text, float8, float8, text[], uuid, boolean, boolean) to authenticated;

-- Waiting cards: a branch request says so
create or replace function my_vendor_invites() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
           'id', k.id, 'name', k.public_name, 'invited_at', w.created_at, 'reminded_at', w.reminded_at, 'branch', k.parent_id is not null,
           'status', case when k.invite_status in ('declined', 'not_mine') then 'declined' when k.setup_status = 'submitted' then 'checking'
                          when k.invite_status = 'claimed' or k.setup_status = 'returned' then 'setting_up' else 'invited' end,
           'waiting', (select count(*) from vendor_waiters x where x.kitchen_id = k.id)) order by w.created_at desc), '[]'::json)
    from vendor_waiters w join kitchens k on k.id = w.kitchen_id
   where w.user_id = auth.uid() and not k.archived and k.setup_status is not null;
$$;

-- ---------- The owner confirms a branch from the link ----------
create or replace function vendor_claim(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare a vendor_auth; k kitchens; m kitchens;
begin
  select * into a from vendor_auth where invite_code = p_code and coalesce(p_code, '') <> '';
  if not found then raise exception 'This link isn''t valid. If you''ve set up before, sign in with your phone number and PIN.'; end if;
  select * into k from kitchens where id = a.kitchen_id;
  if k.archived or coalesce(k.invite_status, '') in ('declined', 'merged', 'not_mine') then raise exception 'This link isn''t valid any more. Ask ChopPool for a new one.'; end if;
  if a.invite_created_at < now() - interval '30 days' then raise exception 'This link has expired. Ask ChopPool for a new one.'; end if;
  if k.parent_id is not null then   -- a branch: works until the branch is live
    if k.setup_status is null then raise exception 'This branch is already on ChopPool. Sign in with your phone number and PIN.'; end if;
    select * into m from kitchens where id = k.parent_id;
    update vendor_auth set invite_used_at = coalesce(invite_used_at, now()) where kitchen_id = k.id;
    return json_build_object('token', k.token, 'name', m.public_name, 'status', k.setup_status, 'branch', true, 'claimed', k.invite_status = 'claimed',
      'lat', k.lat, 'lng', k.lng, 'near', (select name from sites where id = k.site_id));
  end if;
  if a.invite_used_at is not null and a.pin_hash is not null then
    raise exception 'This link has already been used. Sign in with your phone number and PIN.';
  end if;
  update vendor_auth set invite_used_at = coalesce(invite_used_at, now()) where kitchen_id = k.id;
  if k.invite_status in ('pending', 'sent', 'team') then update kitchens set invite_status = 'claimed' where id = k.id; end if;
  return json_build_object('token', k.token, 'name', k.public_name, 'status', coalesce(k.setup_status, 'live'), 'has_pin', a.pin_hash is not null);
end $$;

-- "Yes, add this branch" / "That's not mine"
create or replace function vendor_branch_answer(p_code text, p_mine boolean) returns void
language plpgsql security definer set search_path = public as $$
declare a vendor_auth; k kitchens;
begin
  select * into a from vendor_auth where invite_code = p_code and coalesce(p_code, '') <> '';
  select * into k from kitchens where id = a.kitchen_id and parent_id is not null and setup_status is not null and not archived;
  if not found then raise exception 'This link isn''t valid any more.'; end if;
  update kitchens set invite_status = case when p_mine then 'claimed' else 'not_mine' end where id = k.id;
end $$;
revoke execute on function vendor_branch_answer(text, boolean) from public;
grant execute on function vendor_branch_answer(text, boolean) to anon, authenticated;

-- The owner's branches (only with the owner's own token: that's what she signs in with)
create or replace function vendor_branches(p_token text) returns json
language sql stable security definer set search_path = public as $$
  select json_agg(json_build_object('id', x.id, 'name', x.public_name, 'token', x.token, 'main', x.parent_id is null,
           'area', coalesce(nullif(x.address, ''), (select name from sites where id = x.site_id)),
           'status', case when x.setup_status is not null then x.setup_status when x.active then 'live' else 'paused' end)
         order by x.parent_id nulls first, x.created_at)
    from kitchens m join kitchens x on (x.id = m.id or x.parent_id = m.id)
   where m.token = p_token and m.parent_id is null and not m.archived and not x.archived
     and coalesce(x.invite_status, '') not in ('declined', 'merged', 'not_mine');
$$;
revoke execute on function vendor_branches(text) from public;
grant execute on function vendor_branches(text) to anon, authenticated;

-- She adds a branch herself: menu, days and payout copied; she sets the spot
create or replace function vendor_branch_add(p_token text, p_lat float8, p_lng float8) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare m kitchens; k kitchens;
begin
  select * into m from kitchens where token = p_token and parent_id is null and not archived and setup_status is null;
  if not found then raise exception 'Open your main page to add a branch.'; end if;
  if p_lat is null or p_lng is null or p_lat not between 4 and 12 or p_lng not between -4 and 2 then raise exception 'Show where this branch is on the map.'; end if;
  if exists (select 1 from kitchens x where (x.id = m.id or x.parent_id = m.id) and not x.archived and x.lat is not null and dist_m(p_lat, p_lng, x.lat, x.lng) <= 100) then
    raise exception 'You already have a branch at that spot.';
  end if;
  k := vendor_branch_new(m.id, p_lat, p_lng, m.site_id, null, 'claimed');
  return k.token;
end $$;
revoke execute on function vendor_branch_add(text, float8, float8) from public;
grant execute on function vendor_branch_add(text, float8, float8) to anon, authenticated;

-- The setup form knows it's a branch (no PIN step; the owner's PIN signs in)
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
    'branch', k.parent_id is not null, 'near', (select name from sites where id = k.site_id),
    'has_pin', k.parent_id is not null or exists (select 1 from vendor_auth a where a.kitchen_id = k.id and a.pin_hash is not null),
    'items', coalesce((select json_agg(json_build_object('id', i.id, 'name', i.name, 'price', i.price, 'addons', i.addons, 'icon', i.icon) order by i.sort_order, i.name)
                       from menu_items i where i.kitchen_id = k.id), '[]'::json));
end $$;

create or replace function vendor_set_pin(p_token text, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare k kitchens;
begin
  select * into k from kitchens where token = p_token and not archived;
  if not found then raise exception 'This link is not valid. Ask ChopPool for a new one.'; end if;
  if k.parent_id is not null then raise exception 'Your PIN is the same for all your branches. Change it on your main page.'; end if;
  if coalesce(p_pin, '') !~ '^\d{4}$' then raise exception 'Choose a 4-digit PIN.'; end if;
  if not pin_ok(p_pin) then raise exception 'Pick a PIN that''s harder to guess than %.', p_pin; end if;
  insert into vendor_auth (kitchen_id) values (k.id) on conflict do nothing;
  update vendor_auth set pin_hash = crypt(p_pin, gen_salt('bf', 8)), pin_fails = 0, locked_until = null, invite_used_at = coalesce(invite_used_at, now())
   where kitchen_id = k.id;
end $$;

-- ---------- Team: link existing vendors as branches ----------
create or replace function admin_vendor_set_parent(p_kitchen uuid, p_parent uuid) returns void
language plpgsql security definer set search_path = public as $$
declare k kitchens; m kitchens;
begin
  if not is_admin() then raise exception 'Only the ChopPool team can do this.'; end if;
  select * into k from kitchens where id = p_kitchen and not archived;
  if not found then raise exception 'Vendor not found.'; end if;
  if p_parent is null then   -- unlink: she becomes her own vendor again
    update kitchens set parent_id = null where id = k.id;
    return;
  end if;
  select * into m from kitchens where id = p_parent and not archived;
  if not found or m.id = k.id then raise exception 'Pick the main vendor.'; end if;
  if m.parent_id is not null then raise exception '% is itself a branch. Pick the main vendor.', m.public_name; end if;
  if exists (select 1 from kitchens where parent_id = k.id and not archived) then raise exception 'This vendor has branches of her own. Move them first.'; end if;
  update kitchens set parent_id = m.id, dup_of = null where id = k.id;
  update kitchens set dup_of = null where id = m.id and dup_of = k.id;
end $$;
revoke execute on function admin_vendor_set_parent(uuid, uuid) from public, anon;
grant execute on function admin_vendor_set_parent(uuid, uuid) to authenticated;

select 'ChopPool database is up to date (version 55)' as result;
