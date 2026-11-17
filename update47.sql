-- ChopPool update 47: vendors arrange their menu, add required choices to a dish, and give buildings a discount
-- Safe to run more than once.

-- 1. Menu order: vendors move dishes up and down; customers see that order
alter table menu_items add column if not exists sort_order int not null default 0;

-- 2. Required choices ("Choose your protein"): options live with the extras, tagged with their group.
--    Price approval, totals and receipts treat them like extras; ordering needs exactly one from each group.
create or replace function addon_group_of(a jsonb) returns jsonb language sql immutable as $$
  select case when char_length(trim(coalesce(a ->> 'group', ''))) >= 2 then jsonb_build_object('group', left(trim(a ->> 'group'), 40)) else '{}'::jsonb end;
$$;
create or replace function menu_check_groups(p_add jsonb) returns void language plpgsql immutable as $$
begin
  if (select count(distinct e ->> 'group') from jsonb_array_elements(coalesce(p_add, '[]'::jsonb)) e where nullif(e ->> 'group', '') is not null) > 3 then
    raise exception 'A dish can have up to 3 required choices.';
  end if;
end $$;

-- 3. Building discounts: a vendor gives one building a % off the food (dish, extras and choices; not delivery or service)
create table if not exists kitchen_discounts (
  kitchen_id uuid not null references kitchens(id) on delete cascade,
  site_id uuid not null references sites(id) on delete cascade,
  pct int not null check (pct between 5 and 50),
  created_at timestamptz not null default now(),
  primary key (kitchen_id, site_id)
);
alter table kitchen_discounts enable row level security;
drop policy if exists "anyone reads discounts" on kitchen_discounts;
create policy "anyone reads discounts" on kitchen_discounts for select using (true);
drop policy if exists "team removes discounts" on kitchen_discounts;
create policy "team removes discounts" on kitchen_discounts for delete to authenticated using (is_admin());
revoke insert, update on kitchen_discounts from anon, authenticated;
grant select on kitchen_discounts to anon, authenticated;
grant delete on kitchen_discounts to authenticated;

alter table orders add column if not exists discount_pct int not null default 0;   -- the building discount this order got

-- Prices after a discount, to the pesewa; each extra keeps what it was before ("was")
create or replace function discount_addons(p_add jsonb, p_pct int, out addons jsonb, out total numeric) language sql immutable as $$
  select coalesce(jsonb_agg(case when coalesce(p_pct, 0) > 0
                                 then e || jsonb_build_object('price', round(coalesce(nullif(e ->> 'price', '')::numeric, 0) * (100 - p_pct) / 100.0, 2), 'was', e -> 'price')
                                 else e end order by i), '[]'::jsonb),
         coalesce(sum(round(coalesce(nullif(e ->> 'price', '')::numeric, 0) * (100 - coalesce(p_pct, 0)) / 100.0, 2) * coalesce(nullif(e ->> 'qty', '')::int, 1)), 0)
  from jsonb_array_elements(coalesce(p_add, '[]'::jsonb)) with ordinality t(e, i);
$$;

-- The vendor sets or removes a building's discount (0 or empty removes it)
create or replace function vendor_discount_set(p_token text, p_site uuid, p_pct int) returns void
language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  if coalesce(p_pct, 0) = 0 then delete from kitchen_discounts where kitchen_id = k.id and site_id = p_site; return; end if;
  if p_pct < 5 or p_pct > 50 then raise exception 'A discount must be from 5%% to 50%%.'; end if;
  if not exists (select 1 from sites where id = p_site and active and status = 'active' and not archived) then raise exception 'Choose a ChopPool building.'; end if;
  if k.site_id is not null and k.site_id <> p_site then raise exception 'You deliver to one building only.'; end if;
  insert into kitchen_discounts (kitchen_id, site_id, pct) values (k.id, p_site, p_pct)
  on conflict (kitchen_id, site_id) do update set pct = excluded.pct, created_at = now();
end $$;
revoke execute on function vendor_discount_set(text, uuid, int) from public;
grant execute on function vendor_discount_set(text, uuid, int) to anon, authenticated;

-- The buildings a vendor can pick from: nearest first
create or replace function vendor_discount_sites(p_token text) returns json
language plpgsql stable security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  return coalesce((select json_agg(json_build_object('id', si.id, 'name', si.name, 'drop_point', si.drop_point)
                     order by case when k.lat is null or si.lat is null then 1e9 else (si.lat - k.lat) ^ 2 + ((si.lng - k.lng) * cos(radians(k.lat))) ^ 2 end, si.name)
                   from sites si where si.active and si.status = 'active' and not si.archived and (k.site_id is null or si.id = k.site_id)), '[]'::json);
end $$;
revoke execute on function vendor_discount_sites(text) from public;
grant execute on function vendor_discount_sites(text) to anon, authenticated;

-- Vendors save their menu: their order and required choices are kept
create or replace function vendor_set_menu(p_token text, p_items jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare k kitchens; it jsonb; v_pos int; o menu_items; a jsonb; v_add jsonb; v_new jsonb; v_price numeric; v_orig jsonb; v_id uuid; v_name text; n_new int;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  for it, v_pos in select e, x.i::int from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) with ordinality x(e, i) loop
    o := null;
    if nullif(it ->> 'id', '') is not null then select * into o from menu_items where id = (it ->> 'id')::uuid and kitchen_id = k.id; end if;
    v_name := left(trim(coalesce(it ->> 'name', '')), 60);
    v_price := greatest(0, coalesce(nullif(it ->> 'price', '')::numeric, 0));
    -- extras
    v_add := null;
    if jsonb_typeof(it -> 'addons') = 'array' then
      v_add := '[]'::jsonb;
      for a in select * from jsonb_array_elements(it -> 'addons') loop
        continue when char_length(trim(coalesce(a ->> 'name', ''))) < 2;
        v_new := jsonb_build_object('name', left(trim(a ->> 'name'), 40), 'price', greatest(0, coalesce(nullif(a ->> 'price', '')::numeric, 0))) || addon_group_of(a);
        if coalesce((a ->> 'off')::boolean, false) then v_new := v_new || '{"off": true}'; end if;
        v_orig := null;
        if o.id is not null and a ? 'orig_name' then
          select e into v_orig from jsonb_array_elements(o.addons) e
           where e ->> 'name' = a ->> 'orig_name' and coalesce(nullif(e ->> 'price', '')::numeric, 0) = coalesce(nullif(a ->> 'orig_price', '')::numeric, 0) limit 1;
        end if;
        if v_orig is not null then
          if coalesce((v_orig ->> 'pending')::boolean, false) then v_new := v_new || '{"pending": true}'; end if;   -- still waiting
          if (v_new ->> 'price')::numeric > coalesce(nullif(v_orig ->> 'price', '')::numeric, 0) and not coalesce((v_orig ->> 'pending')::boolean, false) then
            perform price_request_add(k.id, o.id, 'extra', v_new ->> 'name', (v_orig ->> 'price')::numeric, (v_new ->> 'price')::numeric);
            v_new := jsonb_set(v_new, '{price}', v_orig -> 'price');
          end if;
        elsif (v_new ->> 'price')::numeric > 0 then
          v_new := v_new || '{"pending": true}';
          if o.id is not null and not exists (select 1 from price_requests where item_id = o.id and kind = 'new_dish' and status = 'pending') then
            perform price_request_add(k.id, o.id, 'new_extra', v_new ->> 'name', null, (v_new ->> 'price')::numeric); end if;
        end if;
        v_add := v_add || jsonb_build_array(v_new);
      end loop;
    end if;
    perform menu_check_groups(v_add);
    if o.id is not null then
      if exists (select 1 from price_requests where item_id = o.id and kind = 'new_dish' and status = 'pending') then
        -- a new dish still waiting: it stays hidden; its request follows the vendor's latest name and price
        update price_requests set name = coalesce(nullif(v_name, ''), name), new_price = case when v_price > 0 then v_price else new_price end
         where item_id = o.id and kind = 'new_dish' and status = 'pending';
        update menu_items set name = coalesce(nullif(v_name, ''), name), price = case when v_price > 0 then v_price else price end,
          addons = coalesce((select jsonb_agg(e - 'pending') from jsonb_array_elements(v_add) e), addons), active = false, sort_order = v_pos where id = o.id;
        continue;
      end if;
      if v_price > o.price then perform price_request_add(k.id, o.id, 'dish', coalesce(nullif(v_name, ''), o.name), o.price, v_price); v_price := o.price; end if;
      update menu_items set name = coalesce(nullif(v_name, ''), name), price = case when v_price > 0 then v_price else price end,
        addons = coalesce(v_add, addons), active = coalesce((it ->> 'active')::boolean, true), sort_order = v_pos
      where id = o.id;
    elsif char_length(v_name) >= 2 and v_price > 0 then
      -- a new dish waits (hidden) for the owner; its new paid extras are approved with it
      insert into menu_items (kitchen_id, name, price, addons, active, sort_order) values (k.id, v_name, v_price,
        coalesce((select jsonb_agg(e - 'pending') from jsonb_array_elements(coalesce(v_add, '[]'::jsonb)) e), '[]'::jsonb), false, v_pos)
      returning id into v_id;
      perform price_request_add(k.id, v_id, 'new_dish', v_name, null, v_price);
    end if;
  end loop;
end $$;

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
    'items', coalesce((select json_agg(json_build_object('id', i.id, 'name', i.name, 'price', i.price, 'addons', i.addons, 'icon', i.icon) order by i.sort_order, i.name)
                       from menu_items i where i.kitchen_id = k.id), '[]'::json));
end $$;

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
            || case when coalesce((a ->> 'off')::boolean, false) then '{"off": true}'::jsonb else '{}'::jsonb end || addon_group_of(a));
        end loop;
      end if;
      perform menu_check_groups(v_add);
      insert into menu_items (kitchen_id, name, price, addons, icon, active, sort_order) values (k.id, v_name, round(v_price, 2), v_add, nullif(it ->> 'icon', ''), true, n + 1);
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

-- The vendor page: menu in their order, and their building discounts
CREATE OR REPLACE FUNCTION public.kitchen_view(p_token text, p_date date)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare k kitchens; s settings;
begin
  perform housekeeping();
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid. Ask ChopPool for a new one.'; end if;
  select * into s from settings where id = 1;
  return json_build_object(
    'kitchen', json_build_object('name', k.name, 'public_name', k.public_name, 'capacity', k.capacity,
                                 'pool_size', kitchen_pool_size(k.id), 'pool_size_own', k.pool_size, 'no_daily_limit', k.no_daily_limit,
                                 'pool_default', s.max_meals, 'pool_ceiling', s.pool_ceiling,
                                 'delivery_mode', k.delivery_mode, 'added_by_customer', k.added_by_customer,
                                 'open', kitchen_is_open(k.id, p_date), 'listing_status', k.listing_status, 'listing', k.listing,
                                 'auto_days', k.auto_days, 'paused', p_date = any(k.paused_dates),
                                 'confirmed', exists (select 1 from kitchen_days where kitchen_id = k.id and order_date = p_date),
                                 'has_pin', k.lat is not null, 'free_m', k.free_m, 'free_min', k.free_min, 'free_max_m', s.free_max_m,
                                 'fee_ack', k.fee_ack, 'fee_free_ack', k.fee_free_ack, 'fee_rate', vendor_fee_rate_of(k.id), 'fee_free', vendor_fee_free_of(k.id), 'fee_own', k.fee_own,
                                 'next_day_confirm_by', s.next_day_confirm_by,
                                 'discounts', coalesce((select json_agg(json_build_object('site_id', d.site_id, 'name', si.name, 'pct', d.pct) order by si.name)
                                                        from kitchen_discounts d join sites si on si.id = d.site_id where d.kitchen_id = k.id), '[]'::json)),
    'menu', coalesce((select json_agg(json_build_object('id', id, 'name', name, 'price', price, 'addons', addons,
                                                        'photo_url', photo_url, 'icon', icon) order by sort_order, name)
                      from menu_items where kitchen_id = k.id and active), '[]'::json),
    'pools', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'seq', p.seq, 'status', p.status, 'site', si.name, 'drop_point', si.drop_point,
        'handoff', si.handoff, 'host_label', si.host_label, 'created_at', p.created_at,
        'wait_until', case when p.status = 'waiting' then wait_deadline(p.created_at, p.order_date) end,
        'free', pool_free(p.id), 'fee_rate', p.fee_rate, 'fee_free', p.fee_free, 'fee', pool_fee(p.id),
        'orders', (select json_agg(json_build_object('id', case when o.status in ('quote_requested', 'quoted') then o.id end, 'code', o.code, 'created_at', o.created_at, 'qty', o.qty, 'item_name', o.item_name,
                                                     'unit_price', o.unit_price, 'addons_total', o.addons_total,
                                                     'addons', o.addons, 'note', o.note, 'special_request', o.special_request,
                                                     'quote_price', o.quote_price, 'status', o.status, 'parent_id', o.parent_id,
                                                     'paid', o.status in ('paid', 'collected'), 'collected', o.status = 'collected')
                                   order by o.code, o.created_at)
                   from orders o where o.pool_id = p.id and o.status <> 'cancelled'))
        order by si.name, p.seq)
      from pools p join sites si on si.id = p.site_id
      where p.kitchen_id = k.id and p.order_date = p_date and p.status <> 'cancelled' and pool_meals(p.id) > 0
    ), '[]'::json));
end $function$;

-- Placing an order: required choices are checked; the building discount is applied and kept on the order
CREATE OR REPLACE FUNCTION public.place_order(p_site uuid, p_item uuid, p_qty integer, p_name text, p_phone text, p_ref text, p_addons text[] DEFAULT '{}'::text[], p_note text DEFAULT NULL::text, p_special text DEFAULT NULL::text, p_use_wallet boolean DEFAULT false, p_join uuid DEFAULT NULL::uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s settings; m menu_items; k kitchens; si sites; pl pools; par orders;
  d date := current_order_date();
  v_load int; v_code text; v_id uuid; v_add jsonb; v_add_total numeric; v_special text; v_pay json;
  v_open boolean; v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_ps int; v_need int; v_pct int := 0; v_unit numeric; v_grp text; v_c int; v_q int;
begin
  perform housekeeping();
  select * into s from settings where id = 1;
  select * into m from menu_items where id = p_item and active;
  if not found then raise exception 'That dish is no longer available.'; end if;
  select * into k from kitchens where id = m.kitchen_id and active;
  if not found then raise exception 'That vendor is not taking orders.'; end if;
  v_ps := kitchen_pool_size(k.id);
  if p_qty is null or p_qty < 1 or p_qty > least(5, v_ps) then raise exception 'Choose between 1 and % meals.', least(5, v_ps); end if;
  -- A tray of several dishes needs one pool with room for all of it
  v_need := greatest(p_qty, coalesce(nullif(current_setting('cp.basket_meals', true), '')::int, 0));

  v_special := nullif(trim(coalesce(p_special, '')), '');
  -- Extras: picked by name, or by name#price when a dish lists the same name more than once (Fish at 15, 20, 30).
  -- Sending a pick twice means two of it on each plate (2 eggs), up to 5; each extra is saved with its count.
  select coalesce(jsonb_agg(a || jsonb_build_object('qty', c)), '[]'::jsonb), coalesce(sum(coalesce(nullif(a ->> 'price', '')::numeric, 0) * c), 0)
    into v_add, v_add_total
  from (select a, least(5, (select count(*) from unnest(coalesce(p_addons, '{}')) u(pick)
                  where pick = (a ->> 'name') || '#' || trim_scale(coalesce(nullif(a ->> 'price', '')::numeric, 0))::text
                     or (pick = a ->> 'name' and i = (select min(j) from jsonb_array_elements(m.addons) with ordinality y(b, j) where b ->> 'name' = a ->> 'name')))) as c
        from jsonb_array_elements(m.addons) with ordinality x(a, i)) z
  where c > 0;
  -- Extras the vendor has switched off (or that wait for ChopPool's approval) can't be ordered
  if exists (select 1 from jsonb_array_elements(v_add) e where coalesce((e ->> 'off')::boolean, false) or coalesce((e ->> 'pending')::boolean, false)) then
    raise exception 'An extra you picked is no longer available. Close the dish and open it again to see what''s on today.';
  end if;
  -- Required choices (update 47): exactly one option from each group the vendor set (custom orders are priced by the vendor instead)
  if v_special is null then
    for v_grp in select distinct a ->> 'group' from jsonb_array_elements(m.addons) a
                  where nullif(a ->> 'group', '') is not null and not coalesce((a ->> 'off')::boolean, false) and not coalesce((a ->> 'pending')::boolean, false) loop
      select count(*), coalesce(sum((e ->> 'qty')::int), 0) into v_c, v_q from jsonb_array_elements(v_add) e where e ->> 'group' = v_grp;
      if v_c = 0 then raise exception 'Pick one option for "%" on %.', v_grp, m.name; end if;
      if v_c > 1 or v_q > 1 then raise exception 'Pick just one option for "%" on %.', v_grp, m.name; end if;
    end loop;
  end if;

  perform pg_advisory_xact_lock(hashtext('cp' || k.id::text || d::text));
  select coalesce(sum(qty), 0) into v_load from orders where kitchen_id = k.id and order_date = d and status <> 'cancelled'
     and not (status = 'pending' and pay_issue is not null and pay_issue <> 'short');   -- payments we couldn't find don't hold seats
  if not k.no_daily_limit and v_load + p_qty > k.capacity then raise exception 'This menu is fully booked for today. Try another one.'; end if;

  if p_join is not null then
    -- Another plate for an order already placed: same code and bag, no extra delivery
    select * into par from orders where id = p_join and parent_id is null for update;
    if not found or par.status not in ('pending', 'paid') then raise exception 'That order can''t take another plate. Start a new order instead.'; end if;
    if not ((auth.uid() is not null and par.user_id = auth.uid()) or par.phone = v_phone) then
      raise exception 'Use the phone or account that placed the order.';
    end if;
    if par.kitchen_id <> k.id then raise exception 'Add a dish from the same vendor.'; end if;
    if par.order_date <> d or (now() at time zone 'utc') >= par.order_date + s.cutoff then
      raise exception 'Orders closed at %. You can''t add to this order now.', to_char(s.cutoff, 'HH24:MI');
    end if;
    if v_special is not null then raise exception 'Custom orders can''t be added to an order. Choose from the menu.'; end if;
    select * into pl from pools where id = par.pool_id;
    if pl.status not in ('waiting', 'collecting') then raise exception 'This pool has closed. Start a new order instead.'; end if;
    if pool_meals(pl.id) + p_qty > v_ps then raise exception 'This pool is full. Start a new order for more plates.'; end if;
    -- The vendor's discount for this building (update 47)
    v_pct := coalesce((select pct from kitchen_discounts where kitchen_id = k.id and site_id = par.site_id), 0);
    select x.addons, x.total into v_add, v_add_total from discount_addons(v_add, v_pct) x; v_unit := round(m.price * (100 - v_pct) / 100.0, 2);
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status,
                        parent_id, fee_per_meal, discount_pct)
    values (d, pl.id, par.site_id, k.id, m.id, par.user_id, m.name, v_unit, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), null, par.customer_name, par.phone, par.code, 0, s.service_fee, 'pending',
            par.id, true, v_pct)
    returning id, code into v_id, v_code;
  else
    if (select count(*) from orders where phone = v_phone and parent_id is null and status = 'pending' and created_at > now() - interval '1 day') >= 3 then
      raise exception 'You have 3 orders waiting for their payment to be checked. Wait for those before placing another.';
    end if;
    select * into si from sites where id = p_site and active;
    if not found then raise exception 'That drop point is not active.'; end if;
    if k.site_id is not null and k.site_id <> si.id then raise exception 'That vendor only delivers to another drop point.'; end if;
    if v_special is not null and d = (now() at time zone 'utc')::date and (now() at time zone 'utc')::time >= s.special_cutoff then
      raise exception 'Custom orders close at %. You can still order from the menu.', to_char(s.special_cutoff, 'HH24:MI');
    end if;
    -- While the vendor hasn't confirmed, everyone at the building joins the same waiting pool
    v_open := kitchen_is_open(k.id, d);
    select p.* into pl from pools p
     where p.order_date = d and p.site_id = si.id and p.kitchen_id = k.id
       and p.status = case when v_open then 'collecting' else 'waiting' end
       and pool_meals(p.id) + v_need <= v_ps
     order by p.seq limit 1;
    if not found then
      insert into pools (order_date, site_id, kitchen_id, seq, status)
      values (d, si.id, k.id, coalesce((select max(seq) from pools where order_date = d and site_id = si.id and kitchen_id = k.id and status <> 'cancelled'), 0) + 1,
              case when v_open then 'collecting' else 'waiting' end)
      returning * into pl;
    end if;
    v_code := new_code(si.id, d, pl.id);
    v_pct := coalesce((select pct from kitchen_discounts where kitchen_id = k.id and site_id = si.id), 0);
    select x.addons, x.total into v_add, v_add_total from discount_addons(v_add, v_pct) x; v_unit := round(m.price * (100 - v_pct) / 100.0, 2);
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status, fee_per_meal, discount_pct)
    values (d, pl.id, si.id, k.id, m.id, auth.uid(), m.name, v_unit, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), v_special, trim(p_name), v_phone,
            v_code, ceil(fee_for(0, pool_trip(pl.id)) / p_qty * 2) / 2, s.service_fee, case when v_special is null then 'pending' else 'quote_requested' end, true, v_pct)
    returning id into v_id;
  end if;

  if v_special is null then
    v_pay := settle_payment(v_id, p_ref, p_use_wallet);
  end if;

  return json_build_object('id', v_id, 'code', v_code, 'order_date', d, 'pool_seq', pl.seq, 'pool_status', pl.status,
    'pool_id', pl.id, 'meals', pool_meals(pl.id), 'status', (select status from orders where id = v_id), 'payment', v_pay,
    'parent_id', p_join);
end $function$;
