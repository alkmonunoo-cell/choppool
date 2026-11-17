-- ============================================================
-- ChopPool update 45: vendors fill in their own details from a link. Safe to run more than once.
-- The team creates a draft vendor (name + WhatsApp) and shares its private link. The vendor completes the form
-- (details, location, days, menu, payout number) and submits it. The team approves it (it goes live) or sends it
-- back with a note. A draft stays hidden from customers until it's approved.
-- ============================================================
alter table kitchens add column if not exists setup_status text;
alter table kitchens drop constraint if exists kitchens_setup_status_check;
alter table kitchens add constraint kitchens_setup_status_check check (setup_status is null or setup_status in ('draft', 'submitted', 'returned'));
alter table kitchens add column if not exists setup_note text;
alter table kitchens add column if not exists setup_submitted_at timestamptz;
alter table kitchens add column if not exists owner_name text;
alter table kitchens add column if not exists payout_momo text;
alter table kitchens add column if not exists payout_network text;

-- The team starts a vendor form
create or replace function admin_vendor_invite(p_name text, p_whatsapp text) returns json
language plpgsql security definer set search_path = public as $$
declare k kitchens; v_wa text := regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g');
begin
  if not is_admin() then raise exception 'Only the ChopPool team can do this.'; end if;
  if char_length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Add the vendor''s name.'; end if;
  if v_wa <> '' and v_wa !~ '^0\d{9}$' then raise exception 'Enter a 10-digit WhatsApp number starting with 0.'; end if;
  insert into kitchens (name, public_name, whatsapp, active, added_by_customer, setup_status)
  values (left(trim(p_name), 60), left(trim(p_name), 60), nullif(v_wa, ''), false, false, 'draft')
  returning * into k;
  return json_build_object('id', k.id, 'token', k.token);
end $$;
revoke execute on function admin_vendor_invite(text, text) from public, anon;
grant execute on function admin_vendor_invite(text, text) to authenticated;

-- The vendor opens their link: what they've filled in so far (or that they're already live)
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
    'items', coalesce((select json_agg(json_build_object('id', i.id, 'name', i.name, 'price', i.price, 'addons', i.addons, 'icon', i.icon) order by i.name)
                       from menu_items i where i.kitchen_id = k.id), '[]'::json));
end $$;
revoke execute on function vendor_setup_get(text) from public;
grant execute on function vendor_setup_get(text) to anon, authenticated;

-- The vendor saves (and, when ready, submits) their form. Only while it isn't live yet.
create or replace function vendor_setup_save(p_token text, p_data jsonb, p_items jsonb, p_submit boolean) returns json
language plpgsql security definer set search_path = public as $$
declare k kitchens; it jsonb; a jsonb; v_add jsonb; v_name text; v_price numeric; n int := 0;
  v_wa text := regexp_replace(coalesce(p_data ->> 'whatsapp', ''), '\D', '', 'g');
  v_momo text := regexp_replace(coalesce(p_data ->> 'payout_momo', ''), '\D', '', 'g');
  v_days int[];
begin
  select * into k from kitchens where token = p_token and not coalesce(archived, false) for update;
  if not found then raise exception 'This link is not valid. Ask ChopPool for a new one.'; end if;
  if k.setup_status is null then raise exception 'Your page is already live. Open your vendor page to make changes.'; end if;
  if v_wa <> '' and v_wa !~ '^0\d{9}$' then raise exception 'Enter a 10-digit WhatsApp number starting with 0.'; end if;
  if v_momo <> '' and v_momo !~ '^0\d{9}$' then raise exception 'Enter a 10-digit mobile money number starting with 0.'; end if;
  if jsonb_typeof(p_data -> 'auto_days') = 'array' then
    select array_agg(distinct d::int order by d::int) into v_days from jsonb_array_elements_text(p_data -> 'auto_days') d where d ~ '^[0-6]$';
  end if;
  update kitchens set
    public_name = coalesce(nullif(left(trim(coalesce(p_data ->> 'name', '')), 60), ''), public_name),
    tagline = nullif(left(trim(coalesce(p_data ->> 'tagline', '')), 120), ''),
    owner_name = nullif(left(trim(coalesce(p_data ->> 'owner_name', '')), 60), ''),
    whatsapp = coalesce(nullif(v_wa, ''), whatsapp),
    address = nullif(left(trim(coalesce(p_data ->> 'address', '')), 120), ''),
    lat = coalesce(nullif(p_data ->> 'lat', '')::double precision, lat),
    lng = coalesce(nullif(p_data ->> 'lng', '')::double precision, lng),
    auto_days = coalesce(v_days, auto_days),
    capacity = greatest(1, least(500, coalesce(nullif(p_data ->> 'capacity', '')::int, capacity))),
    payout_momo = nullif(v_momo, ''),
    payout_network = nullif(left(coalesce(p_data ->> 'payout_network', ''), 20), '')
  where id = k.id;
  -- The menu: replaced as a whole (nothing has been ordered from a vendor that isn't live)
  if jsonb_typeof(p_items) = 'array' then
    delete from menu_items where kitchen_id = k.id and not exists (select 1 from orders o where o.item_id = menu_items.id);
    for it in select * from jsonb_array_elements(p_items) loop
      v_name := left(trim(coalesce(it ->> 'name', '')), 60);
      v_price := coalesce(nullif(it ->> 'price', '')::numeric, 0);
      continue when char_length(v_name) < 2 or v_price <= 0;
      v_add := '[]'::jsonb;
      if jsonb_typeof(it -> 'addons') = 'array' then
        for a in select * from jsonb_array_elements(it -> 'addons') loop
          continue when char_length(trim(coalesce(a ->> 'name', ''))) < 2;
          v_add := v_add || jsonb_build_array(jsonb_build_object('name', left(trim(a ->> 'name'), 40), 'price', greatest(0, coalesce(nullif(a ->> 'price', '')::numeric, 0)))
            || case when coalesce((a ->> 'off')::boolean, false) then '{"off": true}'::jsonb else '{}'::jsonb end);
        end loop;
      end if;
      insert into menu_items (kitchen_id, name, price, addons, icon, active) values (k.id, v_name, round(v_price, 2), v_add, nullif(it ->> 'icon', ''), true);
      n := n + 1;
    end loop;
  else
    select count(*) into n from menu_items where kitchen_id = k.id;
  end if;
  select * into k from kitchens where id = k.id;
  if p_submit then
    if char_length(coalesce(k.public_name, '')) < 2 then raise exception 'Add your business name.'; end if;
    if k.whatsapp is null then raise exception 'Add your WhatsApp number.'; end if;
    if k.lat is null then raise exception 'Show where you cook on the map.'; end if;
    if n = 0 then raise exception 'Add at least one dish with its price.'; end if;
    if k.payout_momo is null then raise exception 'Add the mobile money number we pay you on.'; end if;
    update kitchens set setup_status = 'submitted', setup_submitted_at = now(), setup_note = null where id = k.id;
  end if;
  return json_build_object('status', case when p_submit then 'submitted' else k.setup_status end, 'dishes', n);
end $$;
revoke execute on function vendor_setup_save(text, jsonb, jsonb, boolean) from public;
grant execute on function vendor_setup_save(text, jsonb, jsonb, boolean) to anon, authenticated;

-- The team approves a vendor form (it goes live) or sends it back with a note
create or replace function admin_vendor_review(p_kitchen uuid, p_ok boolean, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  if not is_admin() then raise exception 'Only the ChopPool team can do this.'; end if;
  select * into k from kitchens where id = p_kitchen for update;
  if not found or k.setup_status is null then raise exception 'This vendor form isn''t waiting for review.'; end if;
  if p_ok then
    if k.setup_status <> 'submitted' then raise exception 'The vendor hasn''t submitted their form yet.'; end if;
    update kitchens set setup_status = null, setup_note = null, active = true where id = k.id;
  else
    if char_length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Say what they should change.'; end if;
    update kitchens set setup_status = 'returned', setup_note = left(trim(p_note), 300) where id = k.id;
  end if;
end $$;
revoke execute on function admin_vendor_review(uuid, boolean, text) from public, anon;
grant execute on function admin_vendor_review(uuid, boolean, text) to authenticated;
