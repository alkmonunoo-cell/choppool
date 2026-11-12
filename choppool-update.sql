-- ============================================================================
-- ChopPool database update (latest). ONE file for every update.
-- In Supabase > SQL Editor, open your saved query "ChopPool update", select all, paste this file over it, Run.
-- Safe to run as many times as you like: it only adds or replaces what's needed, and never deletes your data.
-- ============================================================================


-- ---------- from update6 ----------
-- ChopPool update 6 (safe to run more than once; includes update 5)
-- 1) Remove kitchens and buildings
alter table kitchens add column if not exists archived boolean not null default false;
alter table sites add column if not exists archived boolean not null default false;

create or replace function admin_remove_kitchen(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  if exists (select 1 from orders where kitchen_id = p_id) then
    update kitchens set archived = true, active = false where id = p_id;
    return 'archived';
  end if;
  delete from kitchen_days where kitchen_id = p_id;
  delete from pools where kitchen_id = p_id;
  delete from menu_items where kitchen_id = p_id;
  delete from kitchens where id = p_id;
  return 'deleted';
end $$;

create or replace function admin_remove_site(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  update kitchens set archived = true, active = false where site_id = p_id;
  if exists (select 1 from orders where site_id = p_id) or exists (select 1 from kitchens where site_id = p_id) then
    update sites set archived = true, active = false where id = p_id;
    return 'archived';
  end if;
  delete from pools where site_id = p_id;
  delete from sites where id = p_id;
  return 'deleted';
end $$;

grant execute on function admin_remove_kitchen(uuid), admin_remove_site(uuid) to authenticated;

-- 2) Map pins for kitchens, so customers see kitchens near them
alter table kitchens add column if not exists lat double precision;
alter table kitchens add column if not exists lng double precision;

drop view if exists public_menus;
create or replace view public_menus as
  select id, public_name, tagline, capacity, site_id, added_by_customer, lat, lng from kitchens where active;
grant select on public_menus to anon, authenticated;

-- Sellers added by customers take their building's pin
update kitchens k set lat = s.lat, lng = s.lng from sites s
 where k.site_id = s.id and k.lat is null;

create or replace function add_vendor(p_site uuid, p_name text, p_whatsapp text, p_items jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare k kitchens; si sites; v_wa text := regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g'); it jsonb; n int := 0;
begin
  select * into si from sites where id = p_site and active and status = 'active';
  if not found then raise exception 'Pick your drop point first.'; end if;
  if char_length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Add the seller''s name.'; end if;
  if v_wa !~ '^0[0-9]{9}$' then raise exception 'Enter the seller''s 10-digit WhatsApp number, like 024 123 4567.'; end if;
  if (select count(*) from kitchens where site_id = p_site and created_at > now() - interval '1 day') >= 10 then
    raise exception 'Too many sellers were added here today. Ask the ChopPool team to help.';
  end if;
  insert into kitchens (name, public_name, tagline, whatsapp, capacity, site_id, added_by_customer, added_by, lat, lng)
  values (trim(p_name), trim(p_name), 'Added by a customer', v_wa, 30, p_site, true, auth.uid(), si.lat, si.lng)
  returning * into k;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    if char_length(trim(coalesce(it ->> 'name', ''))) >= 2 and coalesce((it ->> 'price')::numeric, 0) > 0 then
      insert into menu_items (kitchen_id, name, price) values (k.id, trim(it ->> 'name'), (it ->> 'price')::numeric);
      n := n + 1;
    end if;
  end loop;
  if n = 0 then raise exception 'Add at least one dish with its price.'; end if;
  return json_build_object('id', k.id, 'token', k.token, 'whatsapp', k.whatsapp, 'name', k.public_name);
end $$;

-- Example kitchens get example pins (Osu and Airport Residential). Change them in the app.
update kitchens set lat = 5.5560, lng = -0.1820 where name = 'Auntie Akos Kitchen' and lat is null;
update kitchens set lat = 5.6010, lng = -0.1780 where name = 'Green Bowl' and lat is null;


-- ---------- from update7 ----------
-- ChopPool update 7: distance-based delivery pricing + customer account counts for the owner
-- Paste into Supabase > SQL Editor > New query, then Run. Safe to run more than once.

-- 1. Pricing settings: base fare + rate per km (road km = straight line x 1.3)
alter table settings add column if not exists base_fare numeric not null default 20;
alter table settings add column if not exists per_km numeric not null default 6;

-- Straight-line distance in metres between two pins
create or replace function dist_m(lat1 float8, lng1 float8, lat2 float8, lng2 float8) returns numeric
language sql immutable as $$
  select (6371000 * 2 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2))))::numeric;
$$;

-- Estimated rider trip cost for a pool: kitchen pin to building pin.
-- Customer-added sellers sit at their building. No pins = the flat trip cost.
create or replace function pool_trip(p uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select case
    when coalesce(k.lat, case when k.added_by_customer then st.lat end) is null or st.lat is null then s.trip_cost
    else round(s.base_fare + s.per_km * dist_m(
           coalesce(k.lat, case when k.added_by_customer then st.lat end),
           coalesce(k.lng, case when k.added_by_customer then st.lng end),
           st.lat, st.lng) / 1000 * 1.3)
  end
  from pools pl join kitchens k on k.id = pl.kitchen_id join sites st on st.id = pl.site_id cross join settings s
  where pl.id = p and s.id = 1;
$$;

-- Delivery share per meal for a given trip cost
create or replace function fee_for(p_meals int, p_trip numeric) returns numeric
language sql stable security definer set search_path = public as $$
  select case when p_meals <= 0 then s.max_fee
              else least(s.max_fee, ceil(coalesce(p_trip, s.trip_cost) / p_meals * 2) / 2) end
  from settings s where s.id = 1;
$$;

-- Wallet cashback now uses each pool's own trip cost
create or replace function wallet_balance(p_user uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select round(
    coalesce((select sum(amount) from wallet_entries where user_id = p_user), 0) +
    coalesce((select sum(greatest(0, (o.max_fee - fee_for(pool_meals(o.pool_id), pool_trip(o.pool_id))) * o.qty))
              from orders o join pools p on p.id = o.pool_id cross join settings s
              where s.id = 1 and o.user_id = p_user and o.status in ('paid', 'collected')
                and p.status <> 'cancelled'
                and (now() at time zone 'utc') >= o.order_date + s.cutoff), 0), 2);
$$;

create or replace function my_wallet() returns json
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in to see your wallet.'; end if;
  return json_build_object(
    'balance', wallet_balance(v_uid),
    'entries', coalesce((select json_agg(x order by x.at desc) from (
        select created_at as at, amount, reason from wallet_entries where user_id = v_uid
        union all
        select o.order_date + s.cutoff, round((o.max_fee - fee_for(pool_meals(o.pool_id), pool_trip(o.pool_id))) * o.qty, 2),
               'Delivery cashback, code ' || o.code
        from orders o join pools p on p.id = o.pool_id cross join settings s
        where s.id = 1 and o.user_id = v_uid and o.status in ('paid', 'collected') and p.status <> 'cancelled'
          and (now() at time zone 'utc') >= o.order_date + s.cutoff
          and o.max_fee > fee_for(pool_meals(o.pool_id), pool_trip(o.pool_id))
        order by 1 desc limit 30) x), '[]'::json));
end $$;

-- 2. Owner only: how many customers have accounts, and how many ordered in the last 30 days
create or replace function admin_account_stats() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_super() then raise exception 'Only the owner can see this.'; end if;
  return json_build_object(
    'accounts', (select count(*) from auth.users u where lower(u.email) not in (select email from admins)),
    'active', (select count(distinct o.user_id) from orders o where o.user_id is not null and o.status <> 'cancelled'
                 and o.created_at > now() - interval '30 days'));
end $$;

grant execute on function pool_trip(uuid) to anon, authenticated;
grant execute on function fee_for(int, numeric) to anon, authenticated;
grant execute on function admin_account_stats() to authenticated;


-- ---------- from update8 ----------
-- ChopPool update 8: clearer special requests, sellers can decline them, full bill for customers
-- Paste into Supabase > SQL Editor > New query, then Run. Safe to run more than once.

-- 1. Seller page: show the meal and its menu price next to each special request
create or replace function kitchen_view(p_token text, p_date date)
returns json language plpgsql volatile security definer set search_path = public as $$
declare k kitchens;
begin
  perform housekeeping();
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This seller link is not valid. Ask ChopPool for a new one.'; end if;
  return json_build_object(
    'kitchen', json_build_object('name', k.name, 'public_name', k.public_name, 'capacity', k.capacity,
                                 'delivery_mode', k.delivery_mode, 'added_by_customer', k.added_by_customer,
                                 'open', kitchen_is_open(k.id, p_date)),
    'menu', coalesce((select json_agg(json_build_object('id', id, 'name', name, 'price', price) order by name)
                      from menu_items where kitchen_id = k.id and active), '[]'::json),
    'pools', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'seq', p.seq, 'status', p.status, 'site', si.name, 'drop_point', si.drop_point,
        'handoff', si.handoff, 'host_label', si.host_label,
        'orders', (select json_agg(json_build_object('id', o.id, 'code', o.code, 'qty', o.qty, 'item_name', o.item_name,
                                                     'unit_price', o.unit_price, 'addons_total', o.addons_total,
                                                     'addons', o.addons, 'note', o.note, 'special_request', o.special_request,
                                                     'quote_price', o.quote_price, 'status', o.status,
                                                     'paid', o.status in ('paid', 'collected'), 'collected', o.status = 'collected')
                                   order by o.code)
                   from orders o where o.pool_id = p.id and o.status <> 'cancelled'))
        order by si.name, p.seq)
      from pools p join sites si on si.id = p.site_id
      where p.kitchen_id = k.id and p.order_date = p_date and p.status <> 'cancelled' and pool_meals(p.id) > 0
    ), '[]'::json));
end $$;

-- 2. Seller declines a special request (only while it's unpaid). Nothing is charged.
create or replace function kitchen_decline(p_token text, p_order uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update orders o set status = 'cancelled',
         cancel_reason = 'The seller can''t do this request' || coalesce(': ' || nullif(left(trim(p_reason), 120), ''), '')
  from kitchens k
  where k.token = p_token and k.active and o.kitchen_id = k.id and o.id = p_order and o.status in ('quote_requested', 'quoted');
  if not found then raise exception 'That request has already been paid or closed.'; end if;
end $$;

-- 3. Customer orders now include what's needed for the full bill
drop function if exists my_orders(uuid[]);
create function my_orders(p_ids uuid[])
returns table (id uuid, order_date date, code text, status text, qty int, item_name text, site_id uuid,
               kitchen_id uuid, pool_seq int, pool_status text, special_request text, quote_price numeric,
               amount_due numeric, cancel_reason text, unit_price numeric, addons jsonb, addons_total numeric,
               max_fee numeric, service_fee numeric, wallet_used numeric)
language sql stable security definer set search_path = public as $$
  select o.id, o.order_date, o.code, o.status, o.qty, o.item_name, o.site_id, o.kitchen_id, p.seq, p.status,
         o.special_request, o.quote_price,
         (coalesce(o.quote_price, o.unit_price) + o.addons_total) * o.qty + o.max_fee * o.qty + o.service_fee - o.wallet_used,
         o.cancel_reason, o.unit_price, o.addons, o.addons_total, o.max_fee, o.service_fee, o.wallet_used
  from orders o join pools p on p.id = o.pool_id
  where (o.id = any(p_ids) or (auth.uid() is not null and o.user_id = auth.uid()))
    and o.order_date >= (now() at time zone 'utc')::date - 1
  order by o.created_at desc;
$$;

grant execute on function kitchen_view(text, date), kitchen_decline(text, uuid, text), my_orders(uuid[]) to anon, authenticated;


-- ---------- from update10 ----------
-- ChopPool update 10: payment details, customer cancellations, full delivery at checkout + cashback (also for guests)
-- Paste into Supabase > SQL Editor > New query, then Run. Run update-7 and update-8 first. Safe to run more than once.
-- (You can skip update-9: this replaces it.)

-- 1. MoMo network for the payment instructions
alter table settings add column if not exists momo_network text not null default 'MTN';

-- 2. Checkout charges FULL delivery: the lower of the max fee per meal and the whole trip cost by distance.
--    After the cut-off, everyone gets back what the pool saved, as wallet cashback.
create or replace function place_order(p_site uuid, p_item uuid, p_qty int, p_name text, p_phone text, p_ref text,
                                       p_addons text[] default '{}', p_note text default null,
                                       p_special text default null, p_use_wallet boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare
  s settings; m menu_items; k kitchens; si sites; pl pools;
  d date := current_order_date();
  v_load int; v_code text; v_id uuid; v_add jsonb; v_add_total numeric; v_special text; v_pay json;
  v_open boolean;
begin
  perform housekeeping();
  select * into s from settings where id = 1;
  select * into m from menu_items where id = p_item and active;
  if not found then raise exception 'That dish is no longer available.'; end if;
  select * into k from kitchens where id = m.kitchen_id and active;
  if not found then raise exception 'That seller is not taking orders.'; end if;
  select * into si from sites where id = p_site and active;
  if not found then raise exception 'That drop point is not active.'; end if;
  if k.site_id is not null and k.site_id <> si.id then raise exception 'That seller only delivers to another drop point.'; end if;
  if p_qty is null or p_qty < 1 or p_qty > least(5, s.max_meals) then raise exception 'Choose between 1 and 5 meals.'; end if;

  v_special := nullif(trim(coalesce(p_special, '')), '');
  if v_special is not null and d = (now() at time zone 'utc')::date and (now() at time zone 'utc')::time >= s.special_cutoff then
    raise exception 'Special requests close at %. You can still order from the menu.', to_char(s.special_cutoff, 'HH24:MI');
  end if;

  select coalesce(jsonb_agg(a), '[]'::jsonb), coalesce(sum((a ->> 'price')::numeric), 0)
    into v_add, v_add_total
  from jsonb_array_elements(m.addons) a where a ->> 'name' = any(coalesce(p_addons, '{}'));

  perform pg_advisory_xact_lock(hashtext('cp' || k.id::text || d::text));

  select coalesce(sum(qty), 0) into v_load from orders where kitchen_id = k.id and order_date = d and status <> 'cancelled';
  if v_load + p_qty > k.capacity then raise exception 'This menu is fully booked for today. Try another one.'; end if;

  v_open := kitchen_is_open(k.id, d);
  if not v_open then
    if exists (select 1 from pools where kitchen_id = k.id and order_date = d and status = 'waiting') then
      raise exception '% has not confirmed today yet. Try again in a few minutes.', k.public_name;
    end if;
    insert into pools (order_date, site_id, kitchen_id, seq, status)
    values (d, si.id, k.id, coalesce((select max(seq) from pools where order_date = d and site_id = si.id and kitchen_id = k.id), 0) + 1, 'waiting')
    returning * into pl;
  else
    select p.* into pl from pools p
     where p.order_date = d and p.site_id = si.id and p.kitchen_id = k.id and p.status = 'collecting'
       and pool_meals(p.id) + p_qty <= s.max_meals
     order by p.seq limit 1;
    if not found then
      insert into pools (order_date, site_id, kitchen_id, seq)
      values (d, si.id, k.id, coalesce((select max(seq) from pools where order_date = d and site_id = si.id and kitchen_id = k.id), 0) + 1)
      returning * into pl;
    end if;
  end if;

  loop
    v_code := (1000 + floor(random() * 9000))::int::text;
    exit when not exists (select 1 from orders where order_date = d and code = v_code);
  end loop;

  insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                      addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status)
  values (d, pl.id, si.id, k.id, m.id, auth.uid(), m.name, m.price, p_qty, v_add, v_add_total,
          nullif(trim(coalesce(p_note, '')), ''), v_special, trim(p_name), regexp_replace(p_phone, '\D', '', 'g'),
          v_code, fee_for(1, pool_trip(pl.id)), s.service_fee, case when v_special is null then 'pending' else 'quote_requested' end)
  returning id into v_id;

  if v_special is null then
    v_pay := settle_payment(v_id, p_ref, p_use_wallet);
  end if;

  return json_build_object('id', v_id, 'code', v_code, 'order_date', d, 'pool_seq', pl.seq, 'pool_status', pl.status,
    'meals', pool_meals(pl.id), 'status', (select status from orders where id = v_id), 'payment', v_pay);
end $$;

-- 3. Customers cancel before the cut-off. The order id is the customer's own receipt (same as viewing it).
--    Wallet money goes straight back to the wallet. A confirmed MoMo payment goes to the wallet, or is flagged
--    for a MoMo refund if they ask (or have no account). A MoMo payment still being checked is flagged for the team.
create or replace function cancel_order(p_order uuid, p_reason text, p_refund text default 'wallet')
returns json language plpgsql security definer set search_path = public as $$
declare o orders; s settings; v_total numeric; v_momo numeric; v_credit numeric := 0; v_to text;
begin
  select * into s from settings where id = 1;
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'Order not found.'; end if;
  if o.user_id is not null and o.user_id is distinct from auth.uid() then raise exception 'Sign in with the account that placed this order.'; end if;
  if o.status not in ('pending', 'paid', 'quote_requested', 'quoted') then raise exception 'This order can no longer be cancelled.'; end if;
  if (now() at time zone 'utc') >= o.order_date + s.cutoff then
    raise exception 'Orders close at %. The kitchen is already cooking, so it can''t be cancelled now.', to_char(s.cutoff, 'HH24:MI');
  end if;

  v_total := (coalesce(o.quote_price, o.unit_price) + o.addons_total) * o.qty + o.max_fee * o.qty + o.service_fee;
  v_momo := greatest(0, v_total - o.wallet_used);

  if o.status in ('quote_requested', 'quoted') then
    v_to := 'nothing';                                         -- not paid yet
  elsif o.status = 'paid' and v_momo > 0 and o.user_id is not null and coalesce(p_refund, 'wallet') = 'wallet' then
    v_credit := v_momo; v_to := 'wallet';
  elsif v_momo > 0 then
    v_to := 'momo';                                            -- team refunds (or checks) the MoMo payment
  else
    v_to := 'wallet';
  end if;
  v_credit := v_credit + o.wallet_used;

  update orders set status = 'cancelled',
         cancel_reason = 'You cancelled' || coalesce(' (' || nullif(left(trim(p_reason), 80), '') || ')', ''),
         refund_needed = (v_to = 'momo')
  where id = o.id;

  if v_credit > 0 and o.user_id is not null then
    insert into wallet_entries (user_id, amount, reason, order_id)
    values (o.user_id, v_credit, 'Refund: cancelled order ' || o.code, o.id);
  end if;

  -- A pool nobody is left in shouldn't keep waiting for the seller
  update pools set status = 'cancelled' where id = o.pool_id and status = 'waiting' and pool_meals(id) = 0;

  return json_build_object('refund', v_to, 'wallet_credit', case when o.user_id is not null then v_credit else 0 end, 'momo', case when v_to = 'momo' then v_momo else 0 end);
end $$;

-- 4. Orders show the delivery saved so far (the cashback), so guests can see what they'd keep with an account
drop function if exists my_orders(uuid[]);
create function my_orders(p_ids uuid[])
returns table (id uuid, order_date date, code text, status text, qty int, item_name text, site_id uuid,
               kitchen_id uuid, pool_seq int, pool_status text, special_request text, quote_price numeric,
               amount_due numeric, cancel_reason text, unit_price numeric, addons jsonb, addons_total numeric,
               max_fee numeric, service_fee numeric, wallet_used numeric, saving numeric, has_account boolean,
               refund_needed boolean)
language sql stable security definer set search_path = public as $$
  select o.id, o.order_date, o.code, o.status, o.qty, o.item_name, o.site_id, o.kitchen_id, p.seq, p.status,
         o.special_request, o.quote_price,
         (coalesce(o.quote_price, o.unit_price) + o.addons_total) * o.qty + o.max_fee * o.qty + o.service_fee - o.wallet_used,
         o.cancel_reason, o.unit_price, o.addons, o.addons_total, o.max_fee, o.service_fee, o.wallet_used,
         case when o.status in ('pending', 'paid', 'collected') and p.status <> 'cancelled'
              then round(greatest(0, (o.max_fee - fee_for(pool_meals(o.pool_id), pool_trip(o.pool_id))) * o.qty), 2) else 0 end,
         o.user_id is not null, o.refund_needed
  from orders o join pools p on p.id = o.pool_id
  where (o.id = any(p_ids) or (auth.uid() is not null and o.user_id = auth.uid()))
    and o.order_date >= (now() at time zone 'utc')::date - 1
  order by o.created_at desc;
$$;

grant execute on function cancel_order(uuid, text, text), my_orders(uuid[]) to anon, authenticated;



-- ---------- from update11 ----------
-- Pool numbers count live pools only (cancelled pools no longer use up numbers)
alter table pools drop constraint if exists pools_order_date_site_id_kitchen_id_seq_key;

create or replace function place_order(p_site uuid, p_item uuid, p_qty int, p_name text, p_phone text, p_ref text,
                                       p_addons text[] default '{}', p_note text default null,
                                       p_special text default null, p_use_wallet boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare
  s settings; m menu_items; k kitchens; si sites; pl pools;
  d date := current_order_date();
  v_load int; v_code text; v_id uuid; v_add jsonb; v_add_total numeric; v_special text; v_pay json;
  v_open boolean;
begin
  perform housekeeping();
  select * into s from settings where id = 1;
  select * into m from menu_items where id = p_item and active;
  if not found then raise exception 'That dish is no longer available.'; end if;
  select * into k from kitchens where id = m.kitchen_id and active;
  if not found then raise exception 'That seller is not taking orders.'; end if;
  select * into si from sites where id = p_site and active;
  if not found then raise exception 'That drop point is not active.'; end if;
  if k.site_id is not null and k.site_id <> si.id then raise exception 'That seller only delivers to another drop point.'; end if;
  if p_qty is null or p_qty < 1 or p_qty > least(5, s.max_meals) then raise exception 'Choose between 1 and 5 meals.'; end if;

  v_special := nullif(trim(coalesce(p_special, '')), '');
  if v_special is not null and d = (now() at time zone 'utc')::date and (now() at time zone 'utc')::time >= s.special_cutoff then
    raise exception 'Special requests close at %. You can still order from the menu.', to_char(s.special_cutoff, 'HH24:MI');
  end if;

  select coalesce(jsonb_agg(a), '[]'::jsonb), coalesce(sum((a ->> 'price')::numeric), 0)
    into v_add, v_add_total
  from jsonb_array_elements(m.addons) a where a ->> 'name' = any(coalesce(p_addons, '{}'));

  perform pg_advisory_xact_lock(hashtext('cp' || k.id::text || d::text));

  select coalesce(sum(qty), 0) into v_load from orders where kitchen_id = k.id and order_date = d and status <> 'cancelled';
  if v_load + p_qty > k.capacity then raise exception 'This menu is fully booked for today. Try another one.'; end if;

  v_open := kitchen_is_open(k.id, d);
  if not v_open then
    if exists (select 1 from pools where kitchen_id = k.id and order_date = d and status = 'waiting') then
      raise exception '% has not confirmed today yet. Try again in a few minutes.', k.public_name;
    end if;
    insert into pools (order_date, site_id, kitchen_id, seq, status)
    values (d, si.id, k.id, coalesce((select max(seq) from pools where order_date = d and site_id = si.id and kitchen_id = k.id and status <> 'cancelled'), 0) + 1, 'waiting')
    returning * into pl;
  else
    select p.* into pl from pools p
     where p.order_date = d and p.site_id = si.id and p.kitchen_id = k.id and p.status = 'collecting'
       and pool_meals(p.id) + p_qty <= s.max_meals
     order by p.seq limit 1;
    if not found then
      insert into pools (order_date, site_id, kitchen_id, seq)
      values (d, si.id, k.id, coalesce((select max(seq) from pools where order_date = d and site_id = si.id and kitchen_id = k.id and status <> 'cancelled'), 0) + 1)
      returning * into pl;
    end if;
  end if;

  loop
    v_code := (1000 + floor(random() * 9000))::int::text;
    exit when not exists (select 1 from orders where order_date = d and code = v_code);
  end loop;

  insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                      addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status)
  values (d, pl.id, si.id, k.id, m.id, auth.uid(), m.name, m.price, p_qty, v_add, v_add_total,
          nullif(trim(coalesce(p_note, '')), ''), v_special, trim(p_name), regexp_replace(p_phone, '\D', '', 'g'),
          v_code, fee_for(1, pool_trip(pl.id)), s.service_fee, case when v_special is null then 'pending' else 'quote_requested' end)
  returning id into v_id;

  if v_special is null then
    v_pay := settle_payment(v_id, p_ref, p_use_wallet);
  end if;

  return json_build_object('id', v_id, 'code', v_code, 'order_date', d, 'pool_seq', pl.seq, 'pool_status', pl.status,
    'meals', pool_meals(pl.id), 'status', (select status from orders where id = v_id), 'payment', v_pay);
end $$;

-- Renumber today's and future live pools 1, 2, 3...
with r as (
  select id, row_number() over (partition by order_date, site_id, kitchen_id order by seq, created_at) as rn
  from pools where status <> 'cancelled' and order_date >= (now() at time zone 'utc')::date)
update pools p set seq = r.rn from r where p.id = r.id and p.seq <> r.rn;


-- ---------- from update12 ----------
-- Several payment options (owner manages them; customers see the active ones)
create table if not exists payment_methods (
  id uuid primary key default gen_random_uuid(),
  network text not null default 'MTN',
  number text not null,
  name text not null,
  is_main boolean not null default false,
  active boolean not null default true,
  sort int not null default 0,
  created_at timestamptz not null default now()
);
alter table payment_methods enable row level security;
drop policy if exists "read pay methods" on payment_methods;
create policy "read pay methods" on payment_methods for select using (active or is_admin());
drop policy if exists "owner pay methods" on payment_methods;
create policy "owner pay methods" on payment_methods for all to authenticated using (is_super()) with check (is_super());
grant select on payment_methods to anon, authenticated;
grant insert, update, delete on payment_methods to authenticated;
-- First option = the MoMo details already saved in settings
insert into payment_methods (network, number, name, is_main, sort)
select coalesce(momo_network, 'MTN'), momo_number, momo_name, true, 1 from settings
where id = 1 and not exists (select 1 from payment_methods);

-- Date added, shown on each rider
alter table riders add column if not exists created_at timestamptz not null default now();

-- Dish pictures: blank = chosen automatically from the dish name
alter table menu_items add column if not exists icon text;

-- Most-ordered dishes (counts only, no customer details): each kitchen shows its top dish
create or replace view dish_popularity as
  select item_id, sum(qty)::int as n from orders
  where status <> 'cancelled' and created_at > now() - interval '60 days' group by item_id;
grant select on dish_popularity to anon, authenticated;


-- ---------- from update13 ----------
-- ===== Batch B: sellers list themselves, riders apply, ratings from real orders, push alerts =====

-- Sellers added by customers can ask to be listed for free
alter table kitchens add column if not exists listing_status text not null default 'none';   -- none | pending | approved | declined
alter table kitchens add column if not exists listing jsonb;                                    -- what the seller sent
alter table kitchens add column if not exists listing_requested_at timestamptz;

create or replace function vendor_request_listing(p_token text, p_listing jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This seller link is not valid.'; end if;
  if not k.added_by_customer or k.listing_status = 'approved' then raise exception 'You are already listed on ChopPool.'; end if;
  if length(coalesce(p_listing ->> 'name', '')) < 2 then raise exception 'Add your business name.'; end if;
  if (p_listing ->> 'lat') is null then raise exception 'Set your location on the map.'; end if;
  update kitchens set listing = p_listing, listing_status = 'pending', listing_requested_at = now() where id = k.id;
end $$;
grant execute on function vendor_request_listing(text, jsonb) to anon, authenticated;

create or replace function kitchen_view(p_token text, p_date date)
returns json language plpgsql volatile security definer set search_path = public as $$
declare k kitchens;
begin
  perform housekeeping();
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This seller link is not valid. Ask ChopPool for a new one.'; end if;
  return json_build_object(
    'kitchen', json_build_object('name', k.name, 'public_name', k.public_name, 'capacity', k.capacity,
                                 'delivery_mode', k.delivery_mode, 'added_by_customer', k.added_by_customer,
                                 'open', kitchen_is_open(k.id, p_date), 'listing_status', k.listing_status, 'listing', k.listing),
    'menu', coalesce((select json_agg(json_build_object('id', id, 'name', name, 'price', price) order by name)
                      from menu_items where kitchen_id = k.id and active), '[]'::json),
    'pools', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'seq', p.seq, 'status', p.status, 'site', si.name, 'drop_point', si.drop_point,
        'handoff', si.handoff, 'host_label', si.host_label,
        'orders', (select json_agg(json_build_object('id', o.id, 'code', o.code, 'qty', o.qty, 'item_name', o.item_name,
                                                     'unit_price', o.unit_price, 'addons_total', o.addons_total,
                                                     'addons', o.addons, 'note', o.note, 'special_request', o.special_request,
                                                     'quote_price', o.quote_price, 'status', o.status,
                                                     'paid', o.status in ('paid', 'collected'), 'collected', o.status = 'collected')
                                   order by o.code)
                   from orders o where o.pool_id = p.id and o.status <> 'cancelled'))
        order by si.name, p.seq)
      from pools p join sites si on si.id = p.site_id
      where p.kitchen_id = k.id and p.order_date = p_date and p.status <> 'cancelled' and pool_meals(p.id) > 0
    ), '[]'::json));
end $$;

-- Riders apply themselves; the team approves
alter table riders add column if not exists status text not null default 'approved';           -- pending | approved | declined
alter table riders add column if not exists bike text;
alter table riders add column if not exists area text;
alter table riders add column if not exists momo text;

create or replace function rider_apply(p_name text, p_phone text, p_bike text, p_area text, p_momo text)
returns void language plpgsql security definer set search_path = public as $$
declare v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Add your full name.'; end if;
  if v_phone !~ '^0\d{9}$' then raise exception 'Enter your 10-digit phone number, like 024 123 4567.'; end if;
  if exists (select 1 from riders where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = v_phone) then raise exception 'This phone number has already applied.'; end if;
  if (select count(*) from riders where status = 'pending' and created_at > now() - interval '1 day') > 50 then raise exception 'Too many applications today. Please try tomorrow.'; end if;
  insert into riders (name, phone, bike, area, momo, status, active)
  values (left(trim(p_name), 60), v_phone, left(trim(coalesce(p_bike, '')), 60), left(trim(coalesce(p_area, '')), 60), left(regexp_replace(coalesce(p_momo, ''), '[^0-9 ]', '', 'g'), 20), 'pending', false);
end $$;
grant execute on function rider_apply(text, text, text, text, text) to anon, authenticated;

-- Kitchen scores from real orders only (last 90 days). Counts and percentages, no customer details.
drop view if exists kitchen_scores;
create or replace view kitchen_scores as
  with p as (
    select pl.kitchen_id, pl.id, pl.status, pl.delivered_at, pl.order_date,
           exists (select 1 from orders o where o.pool_id = pl.id and o.cancel_reason in ('The seller did not confirm in time') ) as no_show
    from pools pl where pl.order_date > (now() at time zone 'utc')::date - 90),
  o as (select kitchen_id, phone, count(*) as n from orders where status in ('paid', 'collected') and order_date > (now() at time zone 'utc')::date - 90 group by 1, 2)
  select k.id as kitchen_id,
    coalesce((select sum(n) from o where o.kitchen_id = k.id), 0)::int as orders,
    (select round(100.0 * count(*) filter (where p.delivered_at <= (p.order_date + s.delivery_time + interval '15 minutes')) / nullif(count(*) filter (where p.delivered_at is not null), 0))
       from p cross join settings s where s.id = 1 and p.kitchen_id = k.id)::int as on_time,
    (select round(100.0 * count(*) filter (where p.status <> 'cancelled') / nullif(count(*) filter (where p.status <> 'cancelled' or p.no_show), 0)) from p where p.kitchen_id = k.id)::int as reliable,
    (select round(100.0 * count(*) filter (where o.n >= 2) / nullif(count(*), 0)) from o where o.kitchen_id = k.id)::int as come_back
  from kitchens k where k.active and not k.archived;
grant select on kitchen_scores to anon, authenticated;

-- Which kitchens each building orders from (counts only): used to show a building its own favourites first
create or replace view site_kitchen_counts as
  select site_id, kitchen_id, sum(qty)::int as n from orders
  where status <> 'cancelled' and order_date > (now() at time zone 'utc')::date - 60 group by 1, 2;
grant select on site_kitchen_counts to anon, authenticated;

-- Push alerts: each phone that switches alerts on, and what it wants to hear about
create table if not exists push_subs (
  endpoint text primary key,
  p256dh text not null,
  auth text not null,
  user_id uuid,
  order_ids uuid[] not null default '{}',
  kitchen_id uuid references kitchens(id) on delete cascade,
  rider_id uuid references riders(id) on delete cascade,
  is_team boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table push_subs enable row level security;   -- no direct access; only the functions below and the server
create table if not exists push_log (key text primary key, sent_at timestamptz not null default now());
alter table push_log enable row level security;

create or replace function save_push_sub(p_endpoint text, p_p256dh text, p_auth text, p_order_ids uuid[] default '{}',
                                         p_kitchen_token text default null, p_rider_token text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_k uuid; v_r uuid;
begin
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 then raise exception 'Invalid subscription.'; end if;
  if p_kitchen_token is not null then select id into v_k from kitchens where token = p_kitchen_token and active; end if;
  if p_rider_token is not null then select id into v_r from riders where token = p_rider_token and active; end if;
  insert into push_subs (endpoint, p256dh, auth, user_id, order_ids, kitchen_id, rider_id, is_team)
  values (p_endpoint, p_p256dh, p_auth, auth.uid(), coalesce(p_order_ids, '{}'), v_k, v_r, is_admin())
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth,
    user_id = coalesce(excluded.user_id, push_subs.user_id),
    order_ids = (select array(select distinct unnest(push_subs.order_ids || excluded.order_ids))),
    kitchen_id = coalesce(excluded.kitchen_id, push_subs.kitchen_id), rider_id = coalesce(excluded.rider_id, push_subs.rider_id),
    is_team = push_subs.is_team or excluded.is_team, updated_at = now();
end $$;
grant execute on function save_push_sub(text, text, text, uuid[], text, text) to anon, authenticated;


-- ---------- from update14 ----------
-- =====================================================================
-- Update 14: vendors anywhere + long-distance pricing, "Always cooking", add a plate to your order,
-- easy codes (K-27), service fee per meal, joining while the vendor confirms, dish photos,
-- weekly reports, a faster home screen
-- =====================================================================

-- ---------- New columns and indexes ----------
alter table settings add column if not exists cap_km numeric default 8;               -- the per-meal cap applies up to this many km by road
alter table kitchens add column if not exists auto_days int[] not null default '{}';  -- "Always cooking": 1 = Monday ... 5 = Friday
alter table kitchens add column if not exists paused_dates date[] not null default '{}'; -- "Not cooking today"
alter table orders add column if not exists parent_id uuid references orders(id);     -- another plate added under the same code
alter table orders add column if not exists fee_per_meal boolean not null default false; -- service fee charged per meal (new orders)
alter table menu_items add column if not exists photo_url text;
create index if not exists orders_date_site_idx on orders (order_date, site_id);
create index if not exists orders_parent_idx on orders (parent_id);
create index if not exists pools_date_kitchen_idx on pools (order_date, kitchen_id);
create index if not exists pools_date_site_idx on pools (order_date, site_id);

-- ---------- Pricing: no cap for long-distance trips ----------
create or replace function fee_for(p_meals int, p_trip numeric) returns numeric
language sql stable security definer set search_path = public as $$
  select case
    when coalesce(p_trip, s.trip_cost) > round(s.base_fare + s.per_km * s.cap_km) then   -- long distance: shared at cost
      case when p_meals <= 0 then ceil(coalesce(p_trip, s.trip_cost) * 2) / 2
           else ceil(coalesce(p_trip, s.trip_cost) / p_meals * 2) / 2 end
    when p_meals <= 0 then s.max_fee
    else least(s.max_fee, ceil(coalesce(p_trip, s.trip_cost) / p_meals * 2) / 2) end
  from settings s where s.id = 1;
$$;

-- What an order costs in full (old orders keep a per-order service fee)
create or replace function order_total(o orders) returns numeric
language sql immutable as $$
  select (coalesce(o.quote_price, o.unit_price) + o.addons_total) * o.qty + o.max_fee * o.qty
       + o.service_fee * case when o.fee_per_meal then o.qty else 1 end;
$$;

-- Delivery cashback for one code: delivery was paid once; the final share counts every meal under the code
create or replace function order_cashback(p_order uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select case when o.parent_id is not null or p.status = 'cancelled' then 0
    else round(greatest(0, o.max_fee * o.qty - fee_for(pool_meals(o.pool_id), pool_trip(o.pool_id)) *
      (o.qty + coalesce((select sum(c.qty) from orders c where c.parent_id = o.id and c.status in ('pending', 'paid', 'collected')), 0))), 2) end
  from orders o join pools p on p.id = o.pool_id where o.id = p_order;
$$;

create or replace function wallet_balance(p_user uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select round(
    coalesce((select sum(amount) from wallet_entries where user_id = p_user), 0) +
    coalesce((select sum(order_cashback(o.id))
              from orders o join pools p on p.id = o.pool_id cross join settings s
              where s.id = 1 and o.user_id = p_user and o.status in ('paid', 'collected') and o.parent_id is null
                and p.status <> 'cancelled'
                and (now() at time zone 'utc') >= o.order_date + s.cutoff), 0), 2);
$$;

create or replace function my_wallet() returns json
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in to see your wallet.'; end if;
  return json_build_object(
    'balance', wallet_balance(v_uid),
    'entries', coalesce((select json_agg(x order by x.at desc) from (
        select created_at as at, amount, reason from wallet_entries where user_id = v_uid
        union all
        select o.order_date + s.cutoff, order_cashback(o.id), 'Delivery cashback, code ' || o.code
        from orders o join pools p on p.id = o.pool_id cross join settings s
        where s.id = 1 and o.user_id = v_uid and o.status in ('paid', 'collected') and p.status <> 'cancelled'
          and o.parent_id is null and (now() at time zone 'utc') >= o.order_date + s.cutoff
          and order_cashback(o.id) > 0
        order by 1 desc limit 60) x), '[]'::json));
end $$;

-- ---------- "Always cooking" (auto-confirm on chosen weekdays) and "Not cooking today" ----------
create or replace function kitchen_is_open(p_kitchen uuid, p_date date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from kitchen_days where kitchen_id = p_kitchen and order_date = p_date)
      or exists (select 1 from kitchens k where k.id = p_kitchen and k.active
                   and extract(isodow from p_date)::int = any(k.auto_days) and not (p_date = any(k.paused_dates)));
$$;

create or replace function kitchen_set_auto(p_token text, p_days int[])
returns void language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  if exists (select 1 from unnest(coalesce(p_days, '{}')) d where d not between 1 and 7) then raise exception 'Choose weekdays.'; end if;
  update kitchens set auto_days = (select coalesce(array_agg(distinct d order by d), '{}') from unnest(coalesce(p_days, '{}')) d) where id = k.id;
  -- Pools already waiting today open straight away
  update pools set status = 'collecting' where kitchen_id = k.id and status = 'waiting' and kitchen_is_open(k.id, order_date);
end $$;

create or replace function kitchen_pause(p_token text, p_date date, p_paused boolean)
returns void language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  if p_paused then
    if exists (select 1 from pools p where p.kitchen_id = k.id and p.order_date = p_date and p.status <> 'cancelled' and pool_meals(p.id) > 0) then
      raise exception 'You already have orders for this day. Message ChopPool if you can''t cook them.';
    end if;
    update kitchens set paused_dates = array(select distinct x from unnest(paused_dates || p_date) x where x >= (now() at time zone 'utc')::date - 1) where id = k.id;
    delete from kitchen_days where kitchen_id = k.id and order_date = p_date;
  else
    update kitchens set paused_dates = array_remove(paused_dates, p_date) where id = k.id;
  end if;
end $$;

-- A vendor confirming a day also lifts a pause for it
create or replace function kitchen_open_day(p_token text, p_date date)
returns void language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  update kitchens set paused_dates = array_remove(paused_dates, p_date) where id = k.id;
  insert into kitchen_days (kitchen_id, order_date) values (k.id, p_date) on conflict do nothing;
  update pools set status = 'collecting' where kitchen_id = k.id and order_date = p_date and status = 'waiting';
end $$;

-- ---------- Easy collection codes: one letter + 2 digits (K-27) ----------
-- No O, I, S, Z or B (they look like digits). Unique per building per day; never two look-alikes in one bag.
create or replace function new_code(p_site uuid, p_date date, p_pool uuid) returns text
language plpgsql volatile security definer set search_path = public as $$
declare v text; l text := 'ACDEFGHJKLMNPQRTUVWXY'; n int := 0; near boolean;
begin
  loop
    n := n + 1;
    v := substr(l, 1 + floor(random() * length(l))::int, 1) || '-' ||
         lpad(floor(random() * case when n > 300 then 1000 else 100 end)::int::text, case when n > 300 then 3 else 2 end, '0');
    if exists (select 1 from orders where order_date = p_date and site_id = p_site and code = v) then continue; end if;
    exit when n > 300;
    select exists (select 1 from orders o where o.pool_id = p_pool and o.status <> 'cancelled' and o.code ~ '^[A-Z]-[0-9]{2}$' and (
        (left(o.code, 1) = left(v, 1) and (substr(o.code, 3, 1) = substr(v, 3, 1) or substr(o.code, 4, 1) = substr(v, 4, 1)
                                           or (substr(o.code, 3, 1) = substr(v, 4, 1) and substr(o.code, 4, 1) = substr(v, 3, 1))))
        or right(o.code, 2) = right(v, 2))) into near;
    exit when not near;
  end loop;
  return v;
end $$;

-- Typed codes: any case, with or without the dash ("k27" = "K-27"); old 4-digit codes still work
create or replace function norm_code(p text) returns text
language sql immutable as $$
  select case when x ~ '^[A-Z][0-9]{2,3}$' then left(x, 1) || '-' || substr(x, 2) else x end
  from (select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) as x) t;
$$;

-- ---------- Payment uses the full total (service fee per meal on new orders) ----------
create or replace function settle_payment(p_order uuid, p_ref text, p_use_wallet boolean)
returns json language plpgsql security definer set search_path = public as $$
declare o orders; v_total numeric; v_bal numeric; v_use numeric := 0; v_uid uuid := auth.uid();
begin
  select * into o from orders where id = p_order;
  v_total := order_total(o);
  if p_use_wallet and v_uid is not null and o.user_id = v_uid then
    v_bal := wallet_balance(v_uid);
    v_use := greatest(0, least(v_bal, v_total));
    if v_use > 0 then
      insert into wallet_entries (user_id, amount, reason, order_id) values (v_uid, -v_use, 'Paid for order ' || o.code, o.id);
    end if;
  end if;
  if v_use < v_total and (p_ref is null or char_length(trim(p_ref)) < 4) then
    raise exception 'Enter the MoMo transaction ID for the remaining %.', to_char(v_total - v_use, 'FM999990.00');
  end if;
  update orders set wallet_used = wallet_used + v_use,
    momo_ref = case when v_use < v_total then trim(p_ref) else momo_ref end,
    status = case when v_use >= v_total then 'paid' else 'pending' end
  where id = o.id;
  return json_build_object('total', v_total, 'wallet_used', v_use, 'momo_due', v_total - v_use);
end $$;

-- ---------- Ordering: join a pool while the vendor confirms, add a plate under the same code ----------
drop function if exists place_order(uuid, uuid, int, text, text, text, text[], text, text, boolean);
create or replace function place_order(p_site uuid, p_item uuid, p_qty int, p_name text, p_phone text, p_ref text,
                                       p_addons text[] default '{}', p_note text default null,
                                       p_special text default null, p_use_wallet boolean default false,
                                       p_join uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  s settings; m menu_items; k kitchens; si sites; pl pools; par orders;
  d date := current_order_date();
  v_load int; v_code text; v_id uuid; v_add jsonb; v_add_total numeric; v_special text; v_pay json;
  v_open boolean; v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  perform housekeeping();
  select * into s from settings where id = 1;
  select * into m from menu_items where id = p_item and active;
  if not found then raise exception 'That dish is no longer available.'; end if;
  select * into k from kitchens where id = m.kitchen_id and active;
  if not found then raise exception 'That vendor is not taking orders.'; end if;
  if p_qty is null or p_qty < 1 or p_qty > least(5, s.max_meals) then raise exception 'Choose between 1 and 5 meals.'; end if;

  v_special := nullif(trim(coalesce(p_special, '')), '');
  select coalesce(jsonb_agg(a), '[]'::jsonb), coalesce(sum((a ->> 'price')::numeric), 0)
    into v_add, v_add_total
  from jsonb_array_elements(m.addons) a where a ->> 'name' = any(coalesce(p_addons, '{}'));

  perform pg_advisory_xact_lock(hashtext('cp' || k.id::text || d::text));
  select coalesce(sum(qty), 0) into v_load from orders where kitchen_id = k.id and order_date = d and status <> 'cancelled';
  if v_load + p_qty > k.capacity then raise exception 'This menu is fully booked for today. Try another one.'; end if;

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
    if v_special is not null then raise exception 'Special requests can''t be added to an order. Choose from the menu.'; end if;
    select * into pl from pools where id = par.pool_id;
    if pl.status not in ('waiting', 'collecting') then raise exception 'This pool has closed. Start a new order instead.'; end if;
    if pool_meals(pl.id) + p_qty > s.max_meals then raise exception 'This pool is full. Start a new order for more plates.'; end if;
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status,
                        parent_id, fee_per_meal)
    values (d, pl.id, par.site_id, k.id, m.id, par.user_id, m.name, m.price, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), null, par.customer_name, par.phone, par.code, 0, s.service_fee, 'pending',
            par.id, true)
    returning id, code into v_id, v_code;
  else
    select * into si from sites where id = p_site and active;
    if not found then raise exception 'That drop point is not active.'; end if;
    if k.site_id is not null and k.site_id <> si.id then raise exception 'That vendor only delivers to another drop point.'; end if;
    if v_special is not null and d = (now() at time zone 'utc')::date and (now() at time zone 'utc')::time >= s.special_cutoff then
      raise exception 'Special requests close at %. You can still order from the menu.', to_char(s.special_cutoff, 'HH24:MI');
    end if;
    -- While the vendor hasn't confirmed, everyone at the building joins the same waiting pool
    v_open := kitchen_is_open(k.id, d);
    select p.* into pl from pools p
     where p.order_date = d and p.site_id = si.id and p.kitchen_id = k.id
       and p.status = case when v_open then 'collecting' else 'waiting' end
       and pool_meals(p.id) + p_qty <= s.max_meals
     order by p.seq limit 1;
    if not found then
      insert into pools (order_date, site_id, kitchen_id, seq, status)
      values (d, si.id, k.id, coalesce((select max(seq) from pools where order_date = d and site_id = si.id and kitchen_id = k.id and status <> 'cancelled'), 0) + 1,
              case when v_open then 'collecting' else 'waiting' end)
      returning * into pl;
    end if;
    v_code := new_code(si.id, d, pl.id);
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status, fee_per_meal)
    values (d, pl.id, si.id, k.id, m.id, auth.uid(), m.name, m.price, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), v_special, trim(p_name), v_phone,
            v_code, fee_for(1, pool_trip(pl.id)), s.service_fee, case when v_special is null then 'pending' else 'quote_requested' end, true)
    returning id into v_id;
  end if;

  if v_special is null then
    v_pay := settle_payment(v_id, p_ref, p_use_wallet);
  end if;

  return json_build_object('id', v_id, 'code', v_code, 'order_date', d, 'pool_seq', pl.seq, 'pool_status', pl.status,
    'pool_id', pl.id, 'meals', pool_meals(pl.id), 'status', (select status from orders where id = v_id), 'payment', v_pay,
    'parent_id', p_join);
end $$;
grant execute on function place_order(uuid, uuid, int, text, text, text, text[], text, text, boolean, uuid) to anon, authenticated;

-- ---------- Cancelling: a whole code (with its added plates) or just one added plate ----------
create or replace function cancel_order(p_order uuid, p_reason text, p_refund text default 'wallet')
returns json language plpgsql security definer set search_path = public as $$
declare o orders; s settings; v_total numeric; v_momo numeric; v_credit numeric := 0; v_to text; c record; r json;
        v_wallet numeric := 0; v_momo_all numeric := 0;
begin
  select * into s from settings where id = 1;
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'Order not found.'; end if;
  if o.user_id is not null and o.user_id is distinct from auth.uid() then raise exception 'Sign in with the account that placed this order.'; end if;
  if o.status not in ('pending', 'paid', 'quote_requested', 'quoted') then raise exception 'This order can no longer be cancelled.'; end if;
  if (now() at time zone 'utc') >= o.order_date + s.cutoff then
    raise exception 'Orders close at %. The kitchen is already cooking, so it can''t be cancelled now.', to_char(s.cutoff, 'HH24:MI');
  end if;

  v_total := order_total(o);
  v_momo := greatest(0, v_total - o.wallet_used);

  if o.status in ('quote_requested', 'quoted') then
    v_to := 'nothing';
  elsif o.status = 'paid' and v_momo > 0 and o.user_id is not null and coalesce(p_refund, 'wallet') = 'wallet' then
    v_credit := v_momo; v_to := 'wallet';
  elsif v_momo > 0 then
    v_to := 'momo';
  else
    v_to := 'wallet';
  end if;
  v_credit := v_credit + o.wallet_used;

  update orders set status = 'cancelled',
         cancel_reason = 'You cancelled' || coalesce(' (' || nullif(left(trim(p_reason), 80), '') || ')', ''),
         refund_needed = (v_to = 'momo')
  where id = o.id;

  if v_credit > 0 and o.user_id is not null then
    insert into wallet_entries (user_id, amount, reason, order_id)
    values (o.user_id, v_credit, 'Refund: cancelled order ' || o.code, o.id);
  end if;
  v_wallet := case when o.user_id is not null then v_credit else 0 end;
  v_momo_all := case when v_to = 'momo' then v_momo else 0 end;

  -- Cancelling the main order cancels the plates added under its code
  for c in select id from orders where parent_id = o.id and status in ('pending', 'paid') loop
    r := cancel_order(c.id, p_reason, p_refund);
    v_wallet := v_wallet + coalesce((r ->> 'wallet_credit')::numeric, 0);
    v_momo_all := v_momo_all + coalesce((r ->> 'momo')::numeric, 0);
    if (r ->> 'refund') = 'momo' then v_to := 'momo'; end if;
  end loop;

  update pools set status = 'cancelled' where id = o.pool_id and status = 'waiting' and pool_meals(id) = 0;

  return json_build_object('refund', v_to, 'wallet_credit', v_wallet, 'momo', v_momo_all);
end $$;

-- ---------- Customer orders: added plates, reorder details, totals with the per-meal service fee ----------
drop function if exists my_orders(uuid[]);
create function my_orders(p_ids uuid[])
returns table (id uuid, order_date date, code text, status text, qty int, item_name text, site_id uuid,
               kitchen_id uuid, pool_seq int, pool_status text, special_request text, quote_price numeric,
               amount_due numeric, cancel_reason text, unit_price numeric, addons jsonb, addons_total numeric,
               max_fee numeric, service_fee numeric, wallet_used numeric, saving numeric, has_account boolean,
               refund_needed boolean, parent_id uuid, fee_per_meal boolean, item_id uuid, pool_id uuid, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select o.id, o.order_date, o.code, o.status, o.qty, o.item_name, o.site_id, o.kitchen_id, p.seq, p.status,
         o.special_request, o.quote_price,
         order_total(o) - o.wallet_used,
         o.cancel_reason, o.unit_price, o.addons, o.addons_total, o.max_fee, o.service_fee, o.wallet_used,
         case when o.status in ('pending', 'paid', 'collected') and p.status <> 'cancelled' then order_cashback(o.id) else 0 end,
         o.user_id is not null, o.refund_needed, o.parent_id, o.fee_per_meal, o.item_id, o.pool_id, o.created_at
  from orders o join pools p on p.id = o.pool_id
  where (o.id = any(p_ids) or o.parent_id = any(p_ids) or (auth.uid() is not null and o.user_id = auth.uid()))
    and o.order_date >= (now() at time zone 'utc')::date - 1
  order by o.created_at desc;
$$;
grant execute on function cancel_order(uuid, text, text), my_orders(uuid[]) to anon, authenticated;

-- ---------- Customers add a vendor anywhere (optional pin where they cook) ----------
drop function if exists add_vendor(uuid, text, text, jsonb);
create or replace function add_vendor(p_site uuid, p_name text, p_whatsapp text, p_items jsonb,
                                      p_lat float8 default null, p_lng float8 default null)
returns json language plpgsql security definer set search_path = public as $$
declare k kitchens; si sites; v_wa text := regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g'); it jsonb; n int := 0;
begin
  select * into si from sites where id = p_site and active and status = 'active';
  if not found then raise exception 'Pick your building first.'; end if;
  if char_length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Add the vendor''s name.'; end if;
  if v_wa !~ '^0[0-9]{9}$' then raise exception 'Enter the vendor''s 10-digit WhatsApp number, like 024 123 4567.'; end if;
  if (p_lat is null) <> (p_lng is null) or (p_lat is not null and (p_lat not between 4 and 12 or p_lng not between -4 and 2)) then
    raise exception 'Pin the vendor somewhere in Ghana.';
  end if;
  if (select count(*) from kitchens where site_id = p_site and created_at > now() - interval '1 day') >= 10 then
    raise exception 'Too many vendors were added here today. Ask the ChopPool team to help.';
  end if;
  insert into kitchens (name, public_name, tagline, whatsapp, capacity, site_id, added_by_customer, added_by, lat, lng)
  values (trim(p_name), trim(p_name), 'Added by a customer', v_wa, 30, p_site, true, auth.uid(), coalesce(p_lat, si.lat), coalesce(p_lng, si.lng))
  returning * into k;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    if char_length(trim(coalesce(it ->> 'name', ''))) >= 2 and coalesce((it ->> 'price')::numeric, 0) > 0 then
      insert into menu_items (kitchen_id, name, price) values (k.id, trim(it ->> 'name'), (it ->> 'price')::numeric);
      n := n + 1;
    end if;
  end loop;
  if n = 0 then raise exception 'Add at least one dish with its price.'; end if;
  return json_build_object('id', k.id, 'token', k.token, 'whatsapp', k.whatsapp, 'name', k.public_name);
end $$;
grant execute on function add_vendor(uuid, text, text, jsonb, float8, float8) to anon, authenticated;

-- ---------- Vendor page: always-cooking days, pause, menu with extras and photos, codes grouped ----------
create or replace function kitchen_view(p_token text, p_date date)
returns json language plpgsql volatile security definer set search_path = public as $$
declare k kitchens;
begin
  perform housekeeping();
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid. Ask ChopPool for a new one.'; end if;
  return json_build_object(
    'kitchen', json_build_object('name', k.name, 'public_name', k.public_name, 'capacity', k.capacity,
                                 'delivery_mode', k.delivery_mode, 'added_by_customer', k.added_by_customer,
                                 'open', kitchen_is_open(k.id, p_date), 'listing_status', k.listing_status, 'listing', k.listing,
                                 'auto_days', k.auto_days, 'paused', p_date = any(k.paused_dates),
                                 'confirmed', exists (select 1 from kitchen_days where kitchen_id = k.id and order_date = p_date)),
    'menu', coalesce((select json_agg(json_build_object('id', id, 'name', name, 'price', price, 'addons', addons,
                                                        'photo_url', photo_url, 'icon', icon) order by name)
                      from menu_items where kitchen_id = k.id and active), '[]'::json),
    'pools', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'seq', p.seq, 'status', p.status, 'site', si.name, 'drop_point', si.drop_point,
        'handoff', si.handoff, 'host_label', si.host_label, 'created_at', p.created_at,
        'orders', (select json_agg(json_build_object('id', o.id, 'code', o.code, 'qty', o.qty, 'item_name', o.item_name,
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
end $$;

-- Vendors added by customers edit their own menu: dishes, prices and extras
create or replace function vendor_set_menu(p_token text, p_items jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare k kitchens; it jsonb; v_add jsonb;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  if not k.added_by_customer then raise exception 'ChopPool manages this menu. Contact the coordinator to change it.'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_add := case when jsonb_typeof(it -> 'addons') = 'array' then
      (select coalesce(jsonb_agg(jsonb_build_object('name', left(trim(a ->> 'name'), 40), 'price', greatest(0, coalesce(nullif(a ->> 'price', '')::numeric, 0)))), '[]'::jsonb)
         from jsonb_array_elements(it -> 'addons') a where char_length(trim(coalesce(a ->> 'name', ''))) >= 2) end;
    if it ? 'id' and nullif(it ->> 'id', '') is not null then
      update menu_items set name = coalesce(nullif(trim(it ->> 'name'), ''), name),
        price = coalesce(nullif(it ->> 'price', '')::numeric, price),
        addons = coalesce(v_add, addons),
        active = coalesce((it ->> 'active')::boolean, true)
      where id = (it ->> 'id')::uuid and kitchen_id = k.id;
    elsif char_length(trim(coalesce(it ->> 'name', ''))) >= 2 and coalesce(nullif(it ->> 'price', '')::numeric, 0) > 0 then
      insert into menu_items (kitchen_id, name, price, addons) values (k.id, trim(it ->> 'name'), (it ->> 'price')::numeric, coalesce(v_add, '[]'::jsonb));
    end if;
  end loop;
end $$;

-- Dish photos: public bucket "dish-photos". Vendors upload only into their own folder (a hash of their link, never the link itself).
create or replace function kitchen_folder(p_token text) returns text
language sql immutable set search_path = public, extensions as $$ select encode(digest(p_token, 'sha256'), 'hex'); $$;
create or replace function photo_folder_ok(p_folder text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select is_admin() or exists (select 1 from kitchens where active and encode(digest(token, 'sha256'), 'hex') = p_folder);
$$;
grant execute on function photo_folder_ok(text) to anon, authenticated;

create or replace function vendor_set_photo(p_token text, p_item uuid, p_url text)
returns void language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  if p_url is not null and position('/dish-photos/' || kitchen_folder(p_token) || '/' in p_url) = 0 then raise exception 'Upload the photo from your page.'; end if;
  update menu_items set photo_url = p_url where id = p_item and kitchen_id = k.id;
  if not found then raise exception 'That dish is not on your menu.'; end if;
end $$;

do $$ begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('dish-photos', 'dish-photos', true, 1048576, array['image/webp', 'image/jpeg', 'image/png'])
    on conflict (id) do update set public = true, file_size_limit = 1048576, allowed_mime_types = array['image/webp', 'image/jpeg', 'image/png'];
    execute 'drop policy if exists "dish photos read" on storage.objects';
    execute 'create policy "dish photos read" on storage.objects for select using (bucket_id = ''dish-photos'')';
    execute 'drop policy if exists "dish photos add" on storage.objects';
    execute 'create policy "dish photos add" on storage.objects for insert to anon, authenticated with check (bucket_id = ''dish-photos'' and public.photo_folder_ok((storage.foldername(name))[1]))';
    execute 'drop policy if exists "dish photos change" on storage.objects';
    execute 'create policy "dish photos change" on storage.objects for update to anon, authenticated using (bucket_id = ''dish-photos'' and public.photo_folder_ok((storage.foldername(name))[1]))';
    execute 'drop policy if exists "dish photos remove" on storage.objects';
    execute 'create policy "dish photos remove" on storage.objects for delete to anon, authenticated using (bucket_id = ''dish-photos'' and public.photo_folder_ok((storage.foldername(name))[1]))';
  end if;
end $$;

-- ---------- Handover: one code can hold several plates; typed codes in any form ----------
drop function if exists collect_code(text, text, date);
create or replace function collect_code(p_token text, p_code text, p_date date, p_pool uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare v text := norm_code(p_code); n int; v_done int; who text; v_ids uuid[]; v_name text; v_items text; v_qty int; v_paid boolean;
begin
  select count(*), count(*) filter (where o2.status = 'collected'),
         array_agg(o2.id order by o2.created_at) filter (where o2.status <> 'collected'),
         (array_agg(o2.customer_name order by o2.created_at))[1],
         string_agg(o2.qty || ' × ' || o2.item_name, ' + ' order by o2.created_at) filter (where o2.status <> 'collected'),
         sum(o2.qty) filter (where o2.status <> 'collected'),
         bool_and(o2.status in ('paid', 'collected'))
    into n, v_done, v_ids, v_name, v_items, v_qty, v_paid
    from orders o2
    join pools p on p.id = o2.pool_id
    left join riders r on r.id = p.rider_id
    join sites si on si.id = o2.site_id
    join kitchens k on k.id = o2.kitchen_id
   where o2.order_date = p_date and o2.code = v and o2.status in ('pending', 'paid', 'collected')
     and (p_pool is null or o2.pool_id = p_pool)
     and (r.token = p_token or si.host_token = p_token or (k.token = p_token and k.delivery_mode = 'runner'));
  if n = 0 then raise exception 'No order with code % for you today.', coalesce(nullif(v, ''), p_code); end if;
  if v_done = n then raise exception 'Code % was already collected.', v; end if;
  who := case when exists (select 1 from riders where token = p_token) then 'rider'
              when exists (select 1 from kitchens where token = p_token) then 'runner' else 'host' end;
  update orders set status = 'collected', collected_at = now(), collected_by = who where id = any(v_ids);
  return json_build_object('name', v_name, 'items', v_items, 'item_name', v_items, 'qty', v_qty, 'was_paid', v_paid, 'code', v);
end $$;
grant execute on function collect_code(text, text, date, uuid) to anon, authenticated;

-- ---------- Faster home screen: one call for everything the customer app shows ----------
create or replace function board_data(p_date date) returns json
language plpgsql volatile security definer set search_path = public as $$
begin
  perform housekeeping();
  return json_build_object(
    'pools', coalesce((select json_agg(x) from (select p.id, p.order_date, p.site_id, p.kitchen_id, p.seq, p.status, p.created_at, pool_meals(p.id) as meals
                                                  from pools p where p.order_date = p_date and p.status <> 'cancelled') x), '[]'::json),
    'load', coalesce((select json_object_agg(kitchen_id, meals) from (select kitchen_id, sum(qty)::int as meals from orders
                                                  where order_date = p_date and status <> 'cancelled' group by 1) l), '{}'::json),
    'activity', coalesce((select json_agg(a order by a.created_at desc) from (select * from recent_activity order by created_at desc limit 50) a), '[]'::json),
    'open', coalesce((select json_agg(k.id) from kitchens k where k.active and kitchen_is_open(k.id, p_date)), '[]'::json));
end $$;
grant execute on function board_data(date) to anon, authenticated;

create or replace view public_menus as
  select id, public_name, tagline, capacity, site_id, added_by_customer, lat, lng from kitchens where active;
grant select on public_menus to anon, authenticated;

-- ---------- Weekly report (Mon–Fri) for the team; money lines for the owner only ----------
create or replace function admin_weekly_report(p_week_start date) returns json
language plpgsql stable security definer set search_path = public as $$
declare s settings; w0 date := p_week_start; w1 date := p_week_start + 4; v0 date := p_week_start - 7; v1 date := p_week_start - 3;
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  select * into s from settings where id = 1;
  return (
  with o as (select o.*, p.status as pool_status from orders o join pools p on p.id = o.pool_id where o.order_date between v0 and w1),
  live as (select * from o where status in ('paid', 'collected', 'pending')),
  cur as (select * from live where order_date between w0 and w1),
  prev as (select * from live where order_date between v0 and v1),
  pl as (select p.*, pool_meals(p.id) as meals from pools p where p.order_date between v0 and w1),
  firsts as (select phone, min(order_date) as first_day from orders where status in ('paid', 'collected', 'pending') group by phone),
  head as (
    select wk, sum(qty)::int as meals, count(*) filter (where parent_id is null)::int as orders, count(distinct phone)::int as customers,
           count(distinct phone) filter (where (select first_day from firsts f where f.phone = x.phone) >= x.ws)::int as new_customers
    from (select *, 'cur' as wk, w0 as ws from cur union all select *, 'prev', v0 from prev) x group by wk),
  rep as (
    select wk, round(100.0 * count(*) filter (where n >= 2) / nullif(count(*), 0))::int as repeat_rate
    from (select 'cur' as wk, phone, count(distinct order_date) as n from live where order_date between w0 - 7 and w1 and phone in (select phone from cur) group by phone
          union all select 'prev', phone, count(distinct order_date) from live where order_date between v0 - 7 and v1 and phone in (select phone from prev) group by phone) r group by wk),
  pools_w as (
    select case when order_date >= w0 then 'cur' else 'prev' end as wk, round(avg(meals), 1) as avg_meals,
           count(*) filter (where meals >= s.max_meals)::int as filled, count(*)::int as pools
    from pl where status <> 'cancelled' and meals > 0 group by 1),
  canc as (select case when order_date >= w0 then 'cur' else 'prev' end as wk, count(*)::int as n from o where status = 'cancelled' group by 1)
  select json_build_object(
    'week_start', w0, 'week_end', w1,
    'headline', (select json_object_agg(h.wk, json_build_object('meals', h.meals, 'orders', h.orders, 'customers', h.customers, 'new_customers', h.new_customers,
                    'repeat_rate', (select repeat_rate from rep where rep.wk = h.wk), 'avg_meals', (select avg_meals from pools_w where pools_w.wk = h.wk),
                    'pools', (select pools from pools_w where pools_w.wk = h.wk), 'filled', (select filled from pools_w where pools_w.wk = h.wk),
                    'cancelled', coalesce((select n from canc where canc.wk = h.wk), 0))) from head h),
    'money', case when is_super() then (select json_build_object(
        'food', round(coalesce(sum((coalesce(quote_price, unit_price) + addons_total) * qty), 0), 2),
        'commission', round(coalesce(sum((coalesce(quote_price, unit_price) + addons_total) * qty), 0) * s.commission_rate, 2),
        'service_fees', round(coalesce(sum(service_fee * case when fee_per_meal then qty else 1 end), 0), 2),
        'cashback', round(coalesce(sum(case when parent_id is null and status in ('paid', 'collected') then order_cashback(id) else 0 end), 0), 2),
        'refunds', round(coalesce((select sum(amount) from wallet_entries where amount > 0 and reason like 'Refund%' and created_at::date between w0 and w1 + 2), 0), 2),
        'momo_refunds', (select count(*) from orders where refund_needed and order_date between w0 and w1),
        'wallets_owed', round(coalesce((select sum(wallet_balance(u)) from (select distinct user_id as u from orders where user_id is not null union select distinct user_id from wallet_entries) us), 0), 2))
      from cur) end,
    'buildings', coalesce((select json_agg(b order by b.meals desc) from (
        select si.name, sum(c.qty)::int as meals, count(distinct c.pool_id)::int as pools,
               round(sum(c.qty)::numeric / nullif(count(distinct c.pool_id), 0), 1) as avg_pool,
               coalesce((select sum(qty) from prev where prev.site_id = si.id), 0)::int as prev_meals
        from cur c join sites si on si.id = c.site_id group by si.id, si.name order by 2 desc limit 15) b), '[]'::json),
    'quiet', coalesce((select json_agg(q) from (
        select si.name, sum(p.qty)::int as prev_meals from prev p join sites si on si.id = p.site_id
        where not exists (select 1 from cur c where c.site_id = p.site_id) group by si.name order by 2 desc) q), '[]'::json),
    'customers', coalesce((select json_agg(c2) from (
        select (array_agg(customer_name order by created_at desc))[1] as name,
               (select si.name from cur c3 join sites si on si.id = c3.site_id where c3.phone = c.phone group by si.name order by count(*) desc limit 1) as building,
               case when is_super() then c.phone end as phone,
               count(*) filter (where parent_id is null)::int as orders, sum(qty)::int as meals
        from cur c group by c.phone order by sum(qty) desc, count(*) desc limit 15) c2), '[]'::json),
    'vendors', coalesce((select json_agg(v order by v.meals desc) from (
        select k.public_name as name, coalesce(sum(c.qty), 0)::int as meals,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status <> 'cancelled' and pl.meals > 0)::int as pools,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status = 'cancelled'
                  and exists (select 1 from orders x where x.pool_id = pl.id and x.cancel_reason = 'The seller did not confirm in time'))::int as expired,
               (select round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*) filter (where pl.delivered_at is not null), 0))
                  from pl where pl.kitchen_id = k.id and pl.order_date >= w0)::int as on_time,
               (select count(*) from o where o.kitchen_id = k.id and o.order_date >= w0 and o.cancel_reason like 'The seller can''t%')::int as declined,
               (select count(*) from (select phone from live where live.kitchen_id = k.id and live.order_date between w0 - 28 and w1 group by phone having count(distinct order_date) >= 2) r)::int as repeat_customers,
               cardinality(k.auto_days) > 0 as always_cooking
        from kitchens k left join cur c on c.kitchen_id = k.id where k.active
        group by k.id, k.public_name, k.auto_days having coalesce(sum(c.qty), 0) > 0
           or exists (select 1 from pl where pl.kitchen_id = k.id and pl.order_date >= w0)) v), '[]'::json),
    'riders', coalesce((select json_agg(r) from (
        select rd.name, count(*)::int as deliveries,
               round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*), 0))::int as on_time
        from pl join riders rd on rd.id = pl.rider_id where pl.order_date >= w0 and pl.delivered_at is not null group by rd.name order by 2 desc) r), '[]'::json)
  ));
end $$;
grant execute on function admin_weekly_report(date) to authenticated;

grant execute on function kitchen_set_auto(text, int[]), kitchen_pause(text, date, boolean), vendor_set_photo(text, uuid, text),
  vendor_set_menu(text, jsonb), kitchen_view(text, date), kitchen_open_day(text, date) to anon, authenticated;


-- ---------- from update15 ----------
-- =====================================================================
-- Update 15: when a vendor doesn't confirm in time, paid money goes straight to the customer's wallet
-- (guests get a MoMo refund, or the wallet credit if they create an account first)
-- =====================================================================
alter table orders add column if not exists refund_due numeric not null default 0;   -- confirmed payment to return when a vendor doesn't confirm

create or replace function housekeeping() returns void
language plpgsql volatile security definer set search_path = public as $$
declare s settings;
begin
  select * into s from settings where id = 1;

  -- Vendors who didn't confirm in time: confirmed payments come back to the wallet (account holders) or by MoMo (guests)
  with expired as (
    update pools set status = 'cancelled'
    where status = 'waiting' and created_at < now() - make_interval(mins => s.accept_timeout_min)
    returning id)
  update orders o set status = 'cancelled', cancel_reason = 'The seller did not confirm in time',
                      refund_due = case when o.status in ('paid', 'collected') then greatest(0, order_total(o) - o.wallet_used) else 0 end,
                      refund_needed = (o.momo_ref is not null and not (o.user_id is not null and o.status in ('paid', 'collected')))
  from expired e where o.pool_id = e.id and o.status <> 'cancelled';

  -- Wallet part of any cancelled order goes back to the wallet
  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.wallet_used, 'Refund: ' || coalesce(o.cancel_reason, 'order cancelled'), o.id
  from orders o
  where o.status = 'cancelled' and o.wallet_used > 0 and o.user_id is not null
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.amount > 0 and w.reason like 'Refund:%');

  -- MoMo part of a confirmed payment, for account holders, once (never when ChopPool refunds the MoMo instead)
  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.refund_due, 'Money back: the vendor didn''t confirm, code ' || o.code, o.id
  from orders o
  where o.status = 'cancelled' and o.refund_due > 0 and o.user_id is not null and not o.refund_needed
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.reason like 'Money back:%');

  update orders set status = 'cancelled', cancel_reason = 'Special request not paid before cut-off'
  where status in ('quote_requested', 'quoted')
    and (now() at time zone 'utc') >= order_date + s.cutoff;
end $$;

-- A guest who creates an account: money waiting for a MoMo refund goes to the new wallet instead
create or replace function claim_orders(p_ids uuid[]) returns int
language plpgsql volatile security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null then return 0; end if;
  update orders set user_id = auth.uid() where id = any(p_ids) and user_id is null;
  get diagnostics n = row_count;
  update orders set refund_needed = false
   where id = any(p_ids) and user_id = auth.uid() and status = 'cancelled' and refund_due > 0 and refund_needed;
  perform housekeeping();
  return n;
end $$;
grant execute on function claim_orders(uuid[]) to authenticated;

-- Orders now say how much came (or can come) back to the wallet
drop function if exists my_orders(uuid[]);
create function my_orders(p_ids uuid[])
returns table (id uuid, order_date date, code text, status text, qty int, item_name text, site_id uuid,
               kitchen_id uuid, pool_seq int, pool_status text, special_request text, quote_price numeric,
               amount_due numeric, cancel_reason text, unit_price numeric, addons jsonb, addons_total numeric,
               max_fee numeric, service_fee numeric, wallet_used numeric, saving numeric, has_account boolean,
               refund_needed boolean, parent_id uuid, fee_per_meal boolean, item_id uuid, pool_id uuid, created_at timestamptz,
               refund_due numeric)
language sql stable security definer set search_path = public as $$
  select o.id, o.order_date, o.code, o.status, o.qty, o.item_name, o.site_id, o.kitchen_id, p.seq, p.status,
         o.special_request, o.quote_price,
         order_total(o) - o.wallet_used,
         o.cancel_reason, o.unit_price, o.addons, o.addons_total, o.max_fee, o.service_fee, o.wallet_used,
         case when o.status in ('pending', 'paid', 'collected') and p.status <> 'cancelled' then order_cashback(o.id) else 0 end,
         o.user_id is not null, o.refund_needed, o.parent_id, o.fee_per_meal, o.item_id, o.pool_id, o.created_at, o.refund_due
  from orders o join pools p on p.id = o.pool_id
  where (o.id = any(p_ids) or o.parent_id = any(p_ids) or (auth.uid() is not null and o.user_id = auth.uid()))
    and o.order_date >= (now() at time zone 'utc')::date - 1
  order by o.created_at desc;
$$;
grant execute on function my_orders(uuid[]) to anon, authenticated;

-- ---------- from update16 ----------
-- =====================================================================
-- Update 16: customer ratings and photos (only from collected orders), hidden by the team when needed
-- =====================================================================
create table if not exists reviews (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references orders(id),
  kitchen_id uuid not null references kitchens(id),
  site_id uuid references sites(id),
  user_id uuid,
  rating int not null check (rating between 1 and 5),
  comment text check (comment is null or char_length(comment) <= 280),
  photo_url text,
  hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists reviews_kitchen_idx on reviews (kitchen_id, created_at desc);
alter table reviews enable row level security;
drop policy if exists "team reviews" on reviews;
create policy "team reviews" on reviews for all to authenticated using (is_admin()) with check (is_admin());
grant select, update on reviews to authenticated;

-- What customers see: rating, comment, photo and first name only (never phone numbers or accounts)
create or replace view public_reviews as
  select r.id, r.kitchen_id, r.rating, r.comment, r.photo_url, r.created_at,
         split_part(trim(o.customer_name), ' ', 1) as name, o.item_name
  from reviews r join orders o on o.id = r.order_id
  where not r.hidden;
grant select on public_reviews to anon, authenticated;

-- Rate a collected order (and add a photo). Same phone or account that placed it; can be changed later.
create or replace function submit_review(p_order uuid, p_phone text, p_rating int, p_comment text default null, p_photo text default null)
returns json language plpgsql security definer set search_path = public as $$
declare o orders; v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  select * into o from orders where id = p_order and parent_id is null;
  if not found then raise exception 'Order not found.'; end if;
  if not ((auth.uid() is not null and o.user_id = auth.uid()) or o.phone = v_phone) then raise exception 'Use the phone or account that placed the order.'; end if;
  if o.status <> 'collected' then raise exception 'You can rate your lunch once you''ve collected it.'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Choose 1 to 5 stars.'; end if;
  if p_photo is not null and position('/dish-photos/reviews/' || o.id::text || '/' in p_photo) = 0 then raise exception 'Upload the photo from your order.'; end if;
  insert into reviews (order_id, kitchen_id, site_id, user_id, rating, comment, photo_url)
  values (o.id, o.kitchen_id, o.site_id, o.user_id, p_rating, nullif(left(trim(coalesce(p_comment, '')), 280), ''), p_photo)
  on conflict (order_id) do update set rating = excluded.rating, comment = excluded.comment,
    photo_url = coalesce(excluded.photo_url, reviews.photo_url), updated_at = now();
  return json_build_object('ok', true);
end $$;
grant execute on function submit_review(uuid, text, int, text, text) to anon, authenticated;

-- Photos for a review go in dish-photos/reviews/<order id>/, only for an order collected in the last 7 days
create or replace function review_folder_ok(p_order text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from orders where id::text = p_order and status = 'collected' and order_date > (now() at time zone 'utc')::date - 7);
$$;
grant execute on function review_folder_ok(text) to anon, authenticated;
do $$ begin
  if to_regclass('storage.objects') is not null then
    execute 'drop policy if exists "review photos add" on storage.objects';
    execute 'create policy "review photos add" on storage.objects for insert to anon, authenticated with check (bucket_id = ''dish-photos'' and (storage.foldername(name))[1] = ''reviews'' and public.review_folder_ok((storage.foldername(name))[2]))';
  end if;
end $$;

-- Orders show whether you've rated them
drop function if exists my_orders(uuid[]);
create function my_orders(p_ids uuid[])
returns table (id uuid, order_date date, code text, status text, qty int, item_name text, site_id uuid,
               kitchen_id uuid, pool_seq int, pool_status text, special_request text, quote_price numeric,
               amount_due numeric, cancel_reason text, unit_price numeric, addons jsonb, addons_total numeric,
               max_fee numeric, service_fee numeric, wallet_used numeric, saving numeric, has_account boolean,
               refund_needed boolean, parent_id uuid, fee_per_meal boolean, item_id uuid, pool_id uuid, created_at timestamptz,
               refund_due numeric, my_rating int, my_photo text)
language sql stable security definer set search_path = public as $$
  select o.id, o.order_date, o.code, o.status, o.qty, o.item_name, o.site_id, o.kitchen_id, p.seq, p.status,
         o.special_request, o.quote_price,
         order_total(o) - o.wallet_used,
         o.cancel_reason, o.unit_price, o.addons, o.addons_total, o.max_fee, o.service_fee, o.wallet_used,
         case when o.status in ('pending', 'paid', 'collected') and p.status <> 'cancelled' then order_cashback(o.id) else 0 end,
         o.user_id is not null, o.refund_needed, o.parent_id, o.fee_per_meal, o.item_id, o.pool_id, o.created_at, o.refund_due,
         r.rating, r.photo_url
  from orders o join pools p on p.id = o.pool_id left join reviews r on r.order_id = o.id
  where (o.id = any(p_ids) or o.parent_id = any(p_ids) or (auth.uid() is not null and o.user_id = auth.uid()))
    and o.order_date >= (now() at time zone 'utc')::date - 1
  order by o.created_at desc;
$$;
grant execute on function my_orders(uuid[]) to anon, authenticated;

-- Vendor scores now include the average rating (last 90 days, hidden reviews excluded)
create or replace view kitchen_scores as
  with p as (
    select pl.kitchen_id, pl.id, pl.status, pl.delivered_at, pl.order_date,
           exists (select 1 from orders o where o.pool_id = pl.id and o.cancel_reason in ('The seller did not confirm in time') ) as no_show
    from pools pl where pl.order_date > (now() at time zone 'utc')::date - 90),
  o as (select kitchen_id, phone, count(*) as n from orders where status in ('paid', 'collected') and order_date > (now() at time zone 'utc')::date - 90 group by 1, 2)
  select k.id as kitchen_id,
    coalesce((select sum(n) from o where o.kitchen_id = k.id), 0)::int as orders,
    (select round(100.0 * count(*) filter (where p.delivered_at <= (p.order_date + s.delivery_time + interval '15 minutes')) / nullif(count(*) filter (where p.delivered_at is not null), 0))
       from p cross join settings s where s.id = 1 and p.kitchen_id = k.id)::int as on_time,
    (select round(100.0 * count(*) filter (where p.status <> 'cancelled') / nullif(count(*) filter (where p.status <> 'cancelled' or p.no_show), 0)) from p where p.kitchen_id = k.id)::int as reliable,
    (select round(100.0 * count(*) filter (where o.n >= 2) / nullif(count(*), 0)) from o where o.kitchen_id = k.id)::int as come_back,
    (select round(avg(r.rating), 1) from reviews r where r.kitchen_id = k.id and not r.hidden and r.created_at > now() - interval '90 days') as rating,
    (select count(*) from reviews r where r.kitchen_id = k.id and not r.hidden and r.created_at > now() - interval '90 days')::int as ratings
  from kitchens k where k.active and not k.archived;
grant select on kitchen_scores to anon, authenticated;

-- Weekly report: average rating per vendor
create or replace function admin_weekly_report(p_week_start date) returns json
language plpgsql stable security definer set search_path = public as $$
declare s settings; w0 date := p_week_start; w1 date := p_week_start + 4; v0 date := p_week_start - 7; v1 date := p_week_start - 3;
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  select * into s from settings where id = 1;
  return (
  with o as (select o.*, p.status as pool_status from orders o join pools p on p.id = o.pool_id where o.order_date between v0 and w1),
  live as (select * from o where status in ('paid', 'collected', 'pending')),
  cur as (select * from live where order_date between w0 and w1),
  prev as (select * from live where order_date between v0 and v1),
  pl as (select p.*, pool_meals(p.id) as meals from pools p where p.order_date between v0 and w1),
  firsts as (select phone, min(order_date) as first_day from orders where status in ('paid', 'collected', 'pending') group by phone),
  head as (
    select wk, sum(qty)::int as meals, count(*) filter (where parent_id is null)::int as orders, count(distinct phone)::int as customers,
           count(distinct phone) filter (where (select first_day from firsts f where f.phone = x.phone) >= x.ws)::int as new_customers
    from (select *, 'cur' as wk, w0 as ws from cur union all select *, 'prev', v0 from prev) x group by wk),
  rep as (
    select wk, round(100.0 * count(*) filter (where n >= 2) / nullif(count(*), 0))::int as repeat_rate
    from (select 'cur' as wk, phone, count(distinct order_date) as n from live where order_date between w0 - 7 and w1 and phone in (select phone from cur) group by phone
          union all select 'prev', phone, count(distinct order_date) from live where order_date between v0 - 7 and v1 and phone in (select phone from prev) group by phone) r group by wk),
  pools_w as (
    select case when order_date >= w0 then 'cur' else 'prev' end as wk, round(avg(meals), 1) as avg_meals,
           count(*) filter (where meals >= s.max_meals)::int as filled, count(*)::int as pools
    from pl where status <> 'cancelled' and meals > 0 group by 1),
  canc as (select case when order_date >= w0 then 'cur' else 'prev' end as wk, count(*)::int as n from o where status = 'cancelled' group by 1)
  select json_build_object(
    'week_start', w0, 'week_end', w1,
    'headline', (select json_object_agg(h.wk, json_build_object('meals', h.meals, 'orders', h.orders, 'customers', h.customers, 'new_customers', h.new_customers,
                    'repeat_rate', (select repeat_rate from rep where rep.wk = h.wk), 'avg_meals', (select avg_meals from pools_w where pools_w.wk = h.wk),
                    'pools', (select pools from pools_w where pools_w.wk = h.wk), 'filled', (select filled from pools_w where pools_w.wk = h.wk),
                    'cancelled', coalesce((select n from canc where canc.wk = h.wk), 0))) from head h),
    'money', case when is_super() then (select json_build_object(
        'food', round(coalesce(sum((coalesce(quote_price, unit_price) + addons_total) * qty), 0), 2),
        'commission', round(coalesce(sum((coalesce(quote_price, unit_price) + addons_total) * qty), 0) * s.commission_rate, 2),
        'service_fees', round(coalesce(sum(service_fee * case when fee_per_meal then qty else 1 end), 0), 2),
        'cashback', round(coalesce(sum(case when parent_id is null and status in ('paid', 'collected') then order_cashback(id) else 0 end), 0), 2),
        'refunds', round(coalesce((select sum(amount) from wallet_entries where amount > 0 and reason like 'Refund%' and created_at::date between w0 and w1 + 2), 0), 2),
        'momo_refunds', (select count(*) from orders where refund_needed and order_date between w0 and w1),
        'wallets_owed', round(coalesce((select sum(wallet_balance(u)) from (select distinct user_id as u from orders where user_id is not null union select distinct user_id from wallet_entries) us), 0), 2))
      from cur) end,
    'buildings', coalesce((select json_agg(b order by b.meals desc) from (
        select si.name, sum(c.qty)::int as meals, count(distinct c.pool_id)::int as pools,
               round(sum(c.qty)::numeric / nullif(count(distinct c.pool_id), 0), 1) as avg_pool,
               coalesce((select sum(qty) from prev where prev.site_id = si.id), 0)::int as prev_meals
        from cur c join sites si on si.id = c.site_id group by si.id, si.name order by 2 desc limit 15) b), '[]'::json),
    'quiet', coalesce((select json_agg(q) from (
        select si.name, sum(p.qty)::int as prev_meals from prev p join sites si on si.id = p.site_id
        where not exists (select 1 from cur c where c.site_id = p.site_id) group by si.name order by 2 desc) q), '[]'::json),
    'customers', coalesce((select json_agg(c2) from (
        select (array_agg(customer_name order by created_at desc))[1] as name,
               (select si.name from cur c3 join sites si on si.id = c3.site_id where c3.phone = c.phone group by si.name order by count(*) desc limit 1) as building,
               case when is_super() then c.phone end as phone,
               count(*) filter (where parent_id is null)::int as orders, sum(qty)::int as meals
        from cur c group by c.phone order by sum(qty) desc, count(*) desc limit 15) c2), '[]'::json),
    'vendors', coalesce((select json_agg(v order by v.meals desc) from (
        select k.public_name as name, coalesce(sum(c.qty), 0)::int as meals,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status <> 'cancelled' and pl.meals > 0)::int as pools,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status = 'cancelled'
                  and exists (select 1 from orders x where x.pool_id = pl.id and x.cancel_reason = 'The seller did not confirm in time'))::int as expired,
               (select round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*) filter (where pl.delivered_at is not null), 0))
                  from pl where pl.kitchen_id = k.id and pl.order_date >= w0)::int as on_time,
               (select count(*) from o where o.kitchen_id = k.id and o.order_date >= w0 and o.cancel_reason like 'The seller can''t%')::int as declined,
               (select count(*) from (select phone from live where live.kitchen_id = k.id and live.order_date between w0 - 28 and w1 group by phone having count(distinct order_date) >= 2) r)::int as repeat_customers,
               cardinality(k.auto_days) > 0 as always_cooking,
               (select round(avg(r.rating), 1) from reviews r where r.kitchen_id = k.id and not r.hidden and r.created_at::date between w0 and w1 + 2) as rating
        from kitchens k left join cur c on c.kitchen_id = k.id where k.active
        group by k.id, k.public_name, k.auto_days having coalesce(sum(c.qty), 0) > 0
           or exists (select 1 from pl where pl.kitchen_id = k.id and pl.order_date >= w0)) v), '[]'::json),
    'riders', coalesce((select json_agg(r) from (
        select rd.name, count(*)::int as deliveries,
               round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*), 0))::int as on_time
        from pl join riders rd on rd.id = pl.rider_id where pl.order_date >= w0 and pl.delivered_at is not null group by rd.name order by 2 desc) r), '[]'::json)
  ));
end $$;
grant execute on function admin_weekly_report(date) to authenticated;

-- ---------- from update17 ----------
-- =====================================================================
-- Update 17: choose which alerts reach your phone
-- =====================================================================
alter table push_subs add column if not exists mute text[] not null default '{}';   -- alert types this phone switched off

drop function if exists save_push_sub(text, text, text, uuid[], text, text);
create or replace function save_push_sub(p_endpoint text, p_p256dh text, p_auth text, p_order_ids uuid[] default '{}',
                                         p_kitchen_token text default null, p_rider_token text default null, p_mute text[] default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_k uuid; v_r uuid;
begin
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 then raise exception 'Invalid subscription.'; end if;
  if p_mute is not null and (array_length(p_mute, 1) > 20 or exists (select 1 from unnest(p_mute) m where length(m) > 20)) then raise exception 'Invalid alert settings.'; end if;
  if p_kitchen_token is not null then select id into v_k from kitchens where token = p_kitchen_token and active; end if;
  if p_rider_token is not null then select id into v_r from riders where token = p_rider_token and active; end if;
  insert into push_subs (endpoint, p256dh, auth, user_id, order_ids, kitchen_id, rider_id, is_team, mute)
  values (p_endpoint, p_p256dh, p_auth, auth.uid(), coalesce(p_order_ids, '{}'), v_k, v_r, is_admin(), coalesce(p_mute, '{}'))
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth,
    user_id = coalesce(excluded.user_id, push_subs.user_id),
    order_ids = (select array(select distinct unnest(push_subs.order_ids || excluded.order_ids))),
    kitchen_id = coalesce(excluded.kitchen_id, push_subs.kitchen_id), rider_id = coalesce(excluded.rider_id, push_subs.rider_id),
    is_team = push_subs.is_team or excluded.is_team,
    mute = coalesce(p_mute, push_subs.mute), updated_at = now();
end $$;
grant execute on function save_push_sub(text, text, text, uuid[], text, text, text[]) to anon, authenticated;

-- ---------- from update18 ----------
-- =====================================================================
-- Update 18: weekends, next-day confirm deadline, vendor fee on bigger pools,
-- free delivery by the vendor, payment not received, building waitlist + merge
-- =====================================================================

-- ---------- New settings (all editable in Admin › Settings) ----------
alter table settings add column if not exists next_day_confirm_by time not null default '08:30';  -- pools for tomorrow: vendor confirms by this time on the day
alter table settings add column if not exists countdown_start time not null default '06:00';      -- Home countdown starts on the order day
alter table settings add column if not exists near_max_fee numeric not null default 50;           -- "Vendors near you": delivery at most this
alter table settings add column if not exists free_max_m numeric not null default 1500;           -- furthest a vendor may deliver free (road metres)
alter table settings add column if not exists vendor_fee_rate numeric not null default 0;         -- ChopPool fee on meals after the free ones (0.05 = 5%)
alter table settings add column if not exists vendor_fee_free int not null default 5;             -- meals in each pool with no fee
alter table settings drop constraint if exists settings_vendor_fee_check;
alter table settings add constraint settings_vendor_fee_check check (vendor_fee_rate between 0 and 0.5 and vendor_fee_free between 0 and 100);

-- ---------- Vendors ----------
alter table kitchens add column if not exists free_m numeric;                     -- vendor's free-delivery distance by road (metres); null = off
alter table kitchens add column if not exists free_min int not null default 0;   -- free from this many meals in the pool
alter table kitchens add column if not exists fee_ack numeric not null default 0; -- fee rate the vendor has accepted
alter table kitchens add column if not exists fee_free_ack int not null default 5;-- free meals the vendor has accepted

-- ---------- Pools keep the fee terms they started with ----------
alter table pools add column if not exists fee_rate numeric;
alter table pools add column if not exists fee_free int;

-- ---------- Orders: payment problems ----------
alter table orders add column if not exists pay_issue text;            -- null | not_found | short
alter table orders add column if not exists amount_received numeric;   -- what actually arrived when it was short
alter table orders drop constraint if exists orders_pay_issue_check;
alter table orders add constraint orders_pay_issue_check check (pay_issue is null or pay_issue in ('not_found', 'short'));

-- ---------- Building waitlist ----------
create table if not exists site_waiters (
  site_id uuid not null references sites on delete cascade,
  user_id uuid,
  endpoint text,
  created_at timestamptz not null default now(),
  notified_at timestamptz);
create unique index if not exists site_waiters_uniq on site_waiters (site_id, coalesce(user_id::text, ''), coalesce(endpoint, ''));
alter table site_waiters enable row level security;
drop policy if exists "team waiters" on site_waiters;
create policy "team waiters" on site_waiters for select to authenticated using (is_admin());

-- ---------- Lunch every day, weekends included ----------
create or replace function current_order_date() returns date
language sql stable set search_path = public as $$
  select case when (now() at time zone 'utc')::time >= (select cutoff from settings where id = 1)
              then (now() at time zone 'utc')::date + 1
              else (now() at time zone 'utc')::date end;
$$;

-- ---------- How long a vendor has to confirm a new pool ----------
-- Same-day pools: the usual minutes. Pools for a later day: until the "confirm by" time that morning (never after orders close).
create or replace function wait_deadline(p_created timestamptz, p_date date) returns timestamptz
language sql stable security definer set search_path = public as $$
  select case when p_date > (p_created at time zone 'utc')::date
              then (p_date + least(s.next_day_confirm_by, s.cutoff)) at time zone 'utc'
              else p_created + make_interval(mins => s.accept_timeout_min) end
  from settings s where s.id = 1;
$$;

-- ---------- Free delivery by the vendor ----------
-- The vendor's own runner brings it when the building is within their free distance (and the admin limit) and the pool has enough meals.
create or replace function pool_free(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(k.free_m > 0 and k.lat is not null and st.lat is not null
           and dist_m(k.lat, k.lng, st.lat, st.lng) * 1.3 <= least(k.free_m, s.free_max_m)
           and pool_meals(pl.id) >= coalesce(k.free_min, 0), false)
  from pools pl join kitchens k on k.id = pl.kitchen_id join sites st on st.id = pl.site_id cross join settings s
  where pl.id = p and s.id = 1;
$$;

create or replace function pool_trip(p uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select case
    when pool_free(p) then 0
    when coalesce(k.lat, case when k.added_by_customer then st.lat end) is null or st.lat is null then s.trip_cost
    else round(s.base_fare + s.per_km * dist_m(
           coalesce(k.lat, case when k.added_by_customer then st.lat end),
           coalesce(k.lng, case when k.added_by_customer then st.lng end),
           st.lat, st.lng) / 1000 * 1.3)
  end
  from pools pl join kitchens k on k.id = pl.kitchen_id join sites st on st.id = pl.site_id cross join settings s
  where pl.id = p and s.id = 1;
$$;

create or replace view public_menus as
  select k.id, k.public_name, k.tagline, k.capacity, k.site_id, k.added_by_customer, k.lat, k.lng,
         case when k.free_m > 0 then least(k.free_m, s.free_max_m) end as free_m, k.free_min
  from kitchens k cross join settings s where k.active and s.id = 1;
grant select on public_menus to anon, authenticated;

-- Vendor sets their free-delivery distance (0 or null switches it off)
create or replace function vendor_set_free(p_token text, p_m numeric, p_min int)
returns json language plpgsql security definer set search_path = public as $$
declare k kitchens; s settings;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  select * into s from settings where id = 1;
  if k.lat is null then raise exception 'Ask ChopPool to pin your kitchen on the map first.'; end if;
  update kitchens set free_m = case when coalesce(p_m, 0) <= 0 then null else least(round(p_m), s.free_max_m) end,
                      free_min = greatest(0, least(coalesce(p_min, 0), 50))
  where id = k.id returning * into k;
  return json_build_object('free_m', k.free_m, 'free_min', k.free_min);
end $$;
grant execute on function vendor_set_free(text, numeric, int) to anon, authenticated;

-- ---------- Vendor fee on bigger pools ----------
-- A new pool starts with the better of the terms the vendor accepted and today's terms.
create or replace function pools_fee_terms() returns trigger language plpgsql security definer set search_path = public as $$
declare k kitchens; s settings;
begin
  select * into k from kitchens where id = new.kitchen_id; select * into s from settings where id = 1;
  if new.fee_rate is null then new.fee_rate := least(coalesce(k.fee_ack, 0), s.vendor_fee_rate); end if;
  if new.fee_free is null then new.fee_free := greatest(coalesce(k.fee_free_ack, 5), s.vendor_fee_free); end if;
  return new;
end $$;
drop trigger if exists pools_fee_terms on pools;
create trigger pools_fee_terms before insert on pools for each row execute function pools_fee_terms();

-- ChopPool's fee for one pool: rate x the food value of the meals after the free ones (average meal price)
create or replace function pool_fee(p uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(round(coalesce(pl.fee_rate, 0) * x.food * greatest(0, x.meals - coalesce(pl.fee_free, 5)) / nullif(x.meals, 0), 2), 0)
  from pools pl,
       lateral (select coalesce(sum((coalesce(quote_price, unit_price) + addons_total) * qty), 0) as food, coalesce(sum(qty), 0) as meals
                from orders where pool_id = pl.id and status in ('paid', 'collected')) x
  where pl.id = p;
$$;

create or replace function kitchen_accept_terms(p_token text)
returns json language plpgsql security definer set search_path = public as $$
declare k kitchens; s settings;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  select * into s from settings where id = 1;
  update kitchens set fee_ack = s.vendor_fee_rate, fee_free_ack = s.vendor_fee_free where id = k.id;
  -- Pools still waiting for this vendor take the terms they just accepted
  update pools set fee_rate = s.vendor_fee_rate, fee_free = s.vendor_fee_free where kitchen_id = k.id and status = 'waiting';
  return json_build_object('rate', s.vendor_fee_rate, 'free', s.vendor_fee_free);
end $$;
grant execute on function kitchen_accept_terms(text) to anon, authenticated;

-- Confirming a day needs today's terms accepted when they are less favourable than the ones the vendor agreed
create or replace function kitchen_open_day(p_token text, p_date date)
returns void language plpgsql security definer set search_path = public as $$
declare k kitchens; s settings;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  select * into s from settings where id = 1;
  if s.vendor_fee_rate > k.fee_ack or s.vendor_fee_free < k.fee_free_ack then
    raise exception 'Accept the new ChopPool fee terms first.';
  end if;
  update kitchens set paused_dates = array_remove(paused_dates, p_date) where id = k.id;
  insert into kitchen_days (kitchen_id, order_date) values (k.id, p_date) on conflict do nothing;
  update pools set status = 'collecting', fee_rate = least(k.fee_ack, s.vendor_fee_rate), fee_free = greatest(k.fee_free_ack, s.vendor_fee_free)
  where kitchen_id = k.id and order_date = p_date and status = 'waiting';
end $$;

-- ---------- The vendor's own runner delivers free pools ----------
create or replace function kitchen_update(p_token text, p_pool uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare p pools; k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This seller link is not valid.'; end if;
  select * into p from pools where id = p_pool and kitchen_id = k.id;
  if not found then raise exception 'That pool is not for you.'; end if;
  if p_status = 'accepted' then
    if (now() at time zone 'utc') < p.order_date + (select cutoff from settings where id = 1) then
      raise exception 'Orders are still coming in. Confirm the final batch once the pool closes.';
    end if;
  elsif p_status in ('picked_up', 'arriving', 'delivered') then
    if k.delivery_mode <> 'runner' and not pool_free(p.id) then raise exception 'A ChopPool rider delivers this pool.'; end if;
  elsif p_status <> 'ready' then
    raise exception 'Unknown step.';
  end if;
  update pools set status = p_status,
    accepted_at  = case when p_status = 'accepted'  then coalesce(accepted_at, now()) else accepted_at end,
    ready_at     = case when p_status = 'ready'     then now() else ready_at end,
    picked_up_at = case when p_status = 'picked_up' then now() else picked_up_at end,
    arriving_at  = case when p_status = 'arriving'  then now() else arriving_at end,
    delivered_at = case when p_status = 'delivered' then now() else delivered_at end
  where id = p.id and status not in ('waiting', 'cancelled');
end $$;

create or replace function collect_code(p_token text, p_code text, p_date date, p_pool uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare v text := norm_code(p_code); n int; v_done int; who text; v_ids uuid[]; v_name text; v_items text; v_qty int; v_paid boolean;
begin
  select count(*), count(*) filter (where o2.status = 'collected'),
         array_agg(o2.id order by o2.created_at) filter (where o2.status <> 'collected'),
         (array_agg(o2.customer_name order by o2.created_at))[1],
         string_agg(o2.qty || ' × ' || o2.item_name, ' + ' order by o2.created_at) filter (where o2.status <> 'collected'),
         sum(o2.qty) filter (where o2.status <> 'collected'),
         bool_and(o2.status in ('paid', 'collected'))
    into n, v_done, v_ids, v_name, v_items, v_qty, v_paid
    from orders o2
    join pools p on p.id = o2.pool_id
    left join riders r on r.id = p.rider_id
    join sites si on si.id = o2.site_id
    join kitchens k on k.id = o2.kitchen_id
   where o2.order_date = p_date and o2.code = v and o2.status in ('pending', 'paid', 'collected')
     and (p_pool is null or o2.pool_id = p_pool)
     and (r.token = p_token or si.host_token = p_token or (k.token = p_token and (k.delivery_mode = 'runner' or pool_free(p.id))));
  if n = 0 then raise exception 'No order with code % for you today.', coalesce(nullif(v, ''), p_code); end if;
  if v_done = n then raise exception 'Code % was already collected.', v; end if;
  who := case when exists (select 1 from riders where token = p_token) then 'rider'
              when exists (select 1 from kitchens where token = p_token) then 'runner' else 'host' end;
  update orders set status = 'collected', collected_at = now(), collected_by = who where id = any(v_ids);
  return json_build_object('name', v_name, 'items', v_items, 'item_name', v_items, 'qty', v_qty, 'was_paid', v_paid, 'code', v);
end $$;
grant execute on function collect_code(text, text, date, uuid) to anon, authenticated;

-- ---------- Housekeeping: next-day deadlines and unpaid orders at cut-off ----------
create or replace function housekeeping() returns void
language plpgsql volatile security definer set search_path = public as $$
declare s settings;
begin
  select * into s from settings where id = 1;

  -- Vendors who didn't confirm in time: confirmed payments come back to the wallet (account holders) or by MoMo (guests)
  with expired as (
    update pools set status = 'cancelled'
    where status = 'waiting' and now() >= wait_deadline(created_at, order_date)
    returning id)
  update orders o set status = 'cancelled', cancel_reason = 'The seller did not confirm in time',
                      refund_due = case when o.status in ('paid', 'collected') then greatest(0, order_total(o) - o.wallet_used) else 0 end,
                      refund_needed = (o.momo_ref is not null and not (o.user_id is not null and o.status in ('paid', 'collected')))
  from expired e where o.pool_id = e.id and o.status <> 'cancelled';

  -- Payment never found by the time orders close: cancelled; anything that did arrive (short payment) goes back
  update orders set status = 'cancelled', cancel_reason = 'Payment not received',
                    refund_due = coalesce(amount_received, 0),
                    refund_needed = coalesce(amount_received, 0) > 0 and user_id is null
  where status = 'pending' and pay_issue is not null and (now() at time zone 'utc') >= order_date + s.cutoff;

  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.refund_due, 'Money back: payment was short, code ' || o.code, o.id
  from orders o
  where o.status = 'cancelled' and o.cancel_reason = 'Payment not received' and o.refund_due > 0 and o.user_id is not null and not o.refund_needed
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.reason like 'Money back:%');

  -- Wallet part of any cancelled order goes back to the wallet
  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.wallet_used, 'Refund: ' || coalesce(o.cancel_reason, 'order cancelled'), o.id
  from orders o
  where o.status = 'cancelled' and o.wallet_used > 0 and o.user_id is not null
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.amount > 0 and w.reason like 'Refund:%');

  -- MoMo part of a confirmed payment, for account holders, once (never when ChopPool refunds the MoMo instead)
  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.refund_due, 'Money back: the vendor didn''t confirm, code ' || o.code, o.id
  from orders o
  where o.status = 'cancelled' and o.refund_due > 0 and o.user_id is not null and not o.refund_needed
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.reason like 'Money back:%');

  update orders set status = 'cancelled', cancel_reason = 'Special request not paid before cut-off'
  where status in ('quote_requested', 'quoted')
    and (now() at time zone 'utc') >= order_date + s.cutoff;
end $$;

-- ---------- Customers fix a payment we couldn't find ----------
create or replace function fix_payment(p_order uuid, p_phone text, p_ref text)
returns json language plpgsql security definer set search_path = public as $$
declare o orders; s settings; v_ref text := upper(regexp_replace(coalesce(p_ref, ''), '\s', '', 'g'));
begin
  select * into o from orders where id = p_order;
  if not found then raise exception 'Order not found.'; end if;
  if not ((auth.uid() is not null and o.user_id = auth.uid())
          or regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') = regexp_replace(coalesce(o.phone, ''), '\D', '', 'g')) then
    raise exception 'This order isn''t yours.';
  end if;
  if o.status <> 'pending' or o.pay_issue is null then raise exception 'This payment doesn''t need fixing.'; end if;
  select * into s from settings where id = 1;
  if (now() at time zone 'utc') >= o.order_date + s.cutoff then raise exception 'Orders have closed for this day.'; end if;
  if v_ref !~ '^[A-Z0-9.]{6,30}$' then raise exception 'Enter the MoMo transaction ID from your payment message.'; end if;
  update orders set momo_ref = case when o.pay_issue = 'short' and o.momo_ref is not null then left(o.momo_ref || ' + ' || v_ref, 120) else v_ref end,
                    pay_issue = null
  where id = o.id;
  return json_build_object('ok', true);
end $$;
grant execute on function fix_payment(uuid, text, text) to anon, authenticated;

drop function if exists my_orders(uuid[]);
create function my_orders(p_ids uuid[])
returns table (id uuid, order_date date, code text, status text, qty int, item_name text, site_id uuid,
               kitchen_id uuid, pool_seq int, pool_status text, special_request text, quote_price numeric,
               amount_due numeric, cancel_reason text, unit_price numeric, addons jsonb, addons_total numeric,
               max_fee numeric, service_fee numeric, wallet_used numeric, saving numeric, has_account boolean,
               refund_needed boolean, parent_id uuid, fee_per_meal boolean, item_id uuid, pool_id uuid, created_at timestamptz,
               refund_due numeric, my_rating int, my_photo text, pay_issue text, amount_received numeric, momo_ref text, wait_until timestamptz, vendor_delivers boolean)
language sql stable security definer set search_path = public as $$
  select o.id, o.order_date, o.code, o.status, o.qty, o.item_name, o.site_id, o.kitchen_id, p.seq, p.status,
         o.special_request, o.quote_price,
         order_total(o) - o.wallet_used,
         o.cancel_reason, o.unit_price, o.addons, o.addons_total, o.max_fee, o.service_fee, o.wallet_used,
         case when o.status in ('pending', 'paid', 'collected') and p.status <> 'cancelled' then order_cashback(o.id) else 0 end,
         o.user_id is not null, o.refund_needed, o.parent_id, o.fee_per_meal, o.item_id, o.pool_id, o.created_at, o.refund_due,
         r.rating, r.photo_url, o.pay_issue, o.amount_received, o.momo_ref,
         case when p.status = 'waiting' then wait_deadline(p.created_at, p.order_date) end, pool_free(p.id)
  from orders o join pools p on p.id = o.pool_id left join reviews r on r.order_id = o.id
  where (o.id = any(p_ids) or o.parent_id = any(p_ids) or (auth.uid() is not null and o.user_id = auth.uid()))
    and o.order_date >= (now() at time zone 'utc')::date - 1
  order by o.created_at desc;
$$;
grant execute on function my_orders(uuid[]) to anon, authenticated;

-- ---------- Home board: each pool says when the vendor must confirm by, and whether the vendor delivers free ----------
create or replace function board_data(p_date date) returns json
language plpgsql volatile security definer set search_path = public as $$
begin
  perform housekeeping();
  return json_build_object(
    'pools', coalesce((select json_agg(x) from (select p.id, p.order_date, p.site_id, p.kitchen_id, p.seq, p.status, p.created_at, pool_meals(p.id) as meals,
                                                       case when p.status = 'waiting' then wait_deadline(p.created_at, p.order_date) end as wait_until,
                                                       pool_free(p.id) as free
                                                  from pools p where p.order_date = p_date and p.status <> 'cancelled') x), '[]'::json),
    'load', coalesce((select json_object_agg(kitchen_id, meals) from (select kitchen_id, sum(qty)::int as meals from orders
                                                  where order_date = p_date and status <> 'cancelled' group by 1) l), '{}'::json),
    'activity', coalesce((select json_agg(a order by a.created_at desc) from (select * from recent_activity order by created_at desc limit 50) a), '[]'::json),
    'open', coalesce((select json_agg(k.id) from kitchens k where k.active and kitchen_is_open(k.id, p_date)), '[]'::json));
end $$;
grant execute on function board_data(date) to anon, authenticated;

-- ---------- Vendor page: fee terms, free delivery and deadlines ----------
create or replace function kitchen_view(p_token text, p_date date)
returns json language plpgsql volatile security definer set search_path = public as $$
declare k kitchens; s settings;
begin
  perform housekeeping();
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid. Ask ChopPool for a new one.'; end if;
  select * into s from settings where id = 1;
  return json_build_object(
    'kitchen', json_build_object('name', k.name, 'public_name', k.public_name, 'capacity', k.capacity,
                                 'delivery_mode', k.delivery_mode, 'added_by_customer', k.added_by_customer,
                                 'open', kitchen_is_open(k.id, p_date), 'listing_status', k.listing_status, 'listing', k.listing,
                                 'auto_days', k.auto_days, 'paused', p_date = any(k.paused_dates),
                                 'confirmed', exists (select 1 from kitchen_days where kitchen_id = k.id and order_date = p_date),
                                 'has_pin', k.lat is not null, 'free_m', k.free_m, 'free_min', k.free_min, 'free_max_m', s.free_max_m,
                                 'fee_ack', k.fee_ack, 'fee_free_ack', k.fee_free_ack, 'fee_rate', s.vendor_fee_rate, 'fee_free', s.vendor_fee_free,
                                 'next_day_confirm_by', s.next_day_confirm_by),
    'menu', coalesce((select json_agg(json_build_object('id', id, 'name', name, 'price', price, 'addons', addons,
                                                        'photo_url', photo_url, 'icon', icon) order by name)
                      from menu_items where kitchen_id = k.id and active), '[]'::json),
    'pools', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'seq', p.seq, 'status', p.status, 'site', si.name, 'drop_point', si.drop_point,
        'handoff', si.handoff, 'host_label', si.host_label, 'created_at', p.created_at,
        'wait_until', case when p.status = 'waiting' then wait_deadline(p.created_at, p.order_date) end,
        'free', pool_free(p.id), 'fee_rate', p.fee_rate, 'fee_free', p.fee_free, 'fee', pool_fee(p.id),
        'orders', (select json_agg(json_build_object('id', o.id, 'code', o.code, 'qty', o.qty, 'item_name', o.item_name,
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
end $$;

-- ---------- Building requests join a waitlist ----------
drop function if exists request_site(text, text, double precision, double precision, text);
create or replace function request_site(p_name text, p_drop_point text, p_lat double precision, p_lng double precision,
                                        p_note text default null, p_endpoint text default null)
returns json language plpgsql security definer set search_path = public as $$
declare si sites; v_joined boolean := false; v_n int;
begin
  if char_length(trim(coalesce(p_name, ''))) < 3 then raise exception 'Add the building''s name.'; end if;
  if char_length(trim(coalesce(p_drop_point, ''))) < 3 then raise exception 'Say where the food should be dropped, like "Main gate".'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'Drop a pin on the map first.'; end if;
  if p_endpoint is not null and (p_endpoint !~ '^https://' or length(p_endpoint) > 1000) then p_endpoint := null; end if;
  -- Already requested? Same name, or a pending building within 80 m: join its waitlist instead
  select * into si from sites
   where status = 'pending' and not archived
     and (lower(regexp_replace(name, '\s+', ' ', 'g')) = lower(regexp_replace(trim(p_name), '\s+', ' ', 'g'))
          or (lat is not null and dist_m(lat, lng, p_lat, p_lng) <= 80))
   order by created_at limit 1;
  if found then
    v_joined := true;
  else
    if (select count(*) from sites where status = 'pending' and created_at > now() - interval '1 day') >= 30 then
      raise exception 'Too many building requests today. Please try again tomorrow.';
    end if;
    insert into sites (name, drop_point, lat, lng, status, requested_by, request_note)
    values (trim(p_name), trim(p_drop_point), p_lat, p_lng, 'pending', auth.uid(), nullif(trim(coalesce(p_note, '')), ''))
    returning * into si;
  end if;
  if auth.uid() is not null or p_endpoint is not null then
    insert into site_waiters (site_id, user_id, endpoint) values (si.id, auth.uid(), p_endpoint) on conflict do nothing;
  end if;
  select count(*) into v_n from site_waiters where site_id = si.id;
  return json_build_object('id', si.id, 'name', si.name, 'status', si.status, 'joined', v_joined, 'waiting', greatest(v_n, 1));
end $$;
grant execute on function request_site(text, text, double precision, double precision, text, text) to anon, authenticated;

-- Merge a duplicate building into the right one (team only)
create or replace function admin_merge_sites(p_from uuid, p_into uuid)
returns text language plpgsql security definer set search_path = public as $$
declare a sites; b sites; n int;
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  if p_from = p_into then raise exception 'Pick two different buildings.'; end if;
  select * into a from sites where id = p_from; select * into b from sites where id = p_into;
  if a.id is null or b.id is null then raise exception 'Building not found.'; end if;
  update pools set site_id = b.id, seq = seq + 100 where site_id = a.id;
  update orders set site_id = b.id where site_id = a.id;
  get diagnostics n = row_count;
  update kitchens set site_id = b.id where site_id = a.id;
  insert into site_waiters (site_id, user_id, endpoint, created_at)
    select b.id, user_id, endpoint, created_at from site_waiters where site_id = a.id on conflict do nothing;
  delete from site_waiters where site_id = a.id;
  update sites set archived = true, status = case when status = 'pending' then 'declined' else status end,
                   request_note = left(coalesce(request_note || ' · ', '') || 'Merged into ' || b.name, 300)
  where id = a.id;
  return a.name || ' merged into ' || b.name || (case when n > 0 then ' (' || n || ' orders moved)' else '' end) || '.';
end $$;
grant execute on function admin_merge_sites(uuid, uuid) to authenticated;

-- Weekly report: full 7-day weeks now, and ChopPool's fee is the vendor fee actually charged on each pool
create or replace function admin_weekly_report(p_week_start date) returns json
language plpgsql stable security definer set search_path = public as $$
declare s settings; w0 date := p_week_start; w1 date := p_week_start + 6; v0 date := p_week_start - 7; v1 date := p_week_start - 1;
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  select * into s from settings where id = 1;
  return (
  with o as (select o.*, p.status as pool_status from orders o join pools p on p.id = o.pool_id where o.order_date between v0 and w1),
  live as (select * from o where status in ('paid', 'collected', 'pending')),
  cur as (select * from live where order_date between w0 and w1),
  prev as (select * from live where order_date between v0 and v1),
  pl as (select p.*, pool_meals(p.id) as meals from pools p where p.order_date between v0 and w1),
  firsts as (select phone, min(order_date) as first_day from orders where status in ('paid', 'collected', 'pending') group by phone),
  head as (
    select wk, sum(qty)::int as meals, count(*) filter (where parent_id is null)::int as orders, count(distinct phone)::int as customers,
           count(distinct phone) filter (where (select first_day from firsts f where f.phone = x.phone) >= x.ws)::int as new_customers
    from (select *, 'cur' as wk, w0 as ws from cur union all select *, 'prev', v0 from prev) x group by wk),
  rep as (
    select wk, round(100.0 * count(*) filter (where n >= 2) / nullif(count(*), 0))::int as repeat_rate
    from (select 'cur' as wk, phone, count(distinct order_date) as n from live where order_date between w0 - 7 and w1 and phone in (select phone from cur) group by phone
          union all select 'prev', phone, count(distinct order_date) from live where order_date between v0 - 7 and v1 and phone in (select phone from prev) group by phone) r group by wk),
  pools_w as (
    select case when order_date >= w0 then 'cur' else 'prev' end as wk, round(avg(meals), 1) as avg_meals,
           count(*) filter (where meals >= s.max_meals)::int as filled, count(*)::int as pools
    from pl where status <> 'cancelled' and meals > 0 group by 1),
  canc as (select case when order_date >= w0 then 'cur' else 'prev' end as wk, count(*)::int as n from o where status = 'cancelled' group by 1)
  select json_build_object(
    'week_start', w0, 'week_end', w1,
    'headline', (select json_object_agg(h.wk, json_build_object('meals', h.meals, 'orders', h.orders, 'customers', h.customers, 'new_customers', h.new_customers,
                    'repeat_rate', (select repeat_rate from rep where rep.wk = h.wk), 'avg_meals', (select avg_meals from pools_w where pools_w.wk = h.wk),
                    'pools', (select pools from pools_w where pools_w.wk = h.wk), 'filled', (select filled from pools_w where pools_w.wk = h.wk),
                    'cancelled', coalesce((select n from canc where canc.wk = h.wk), 0))) from head h),
    'money', case when is_super() then (select json_build_object(
        'food', round(coalesce(sum((coalesce(quote_price, unit_price) + addons_total) * qty), 0), 2),
        'commission', round(coalesce((select sum(pool_fee(p2.id)) from pools p2 where p2.order_date between w0 and w1 and p2.status <> 'cancelled'), 0), 2),
        'service_fees', round(coalesce(sum(service_fee * case when fee_per_meal then qty else 1 end), 0), 2),
        'cashback', round(coalesce(sum(case when parent_id is null and status in ('paid', 'collected') then order_cashback(id) else 0 end), 0), 2),
        'refunds', round(coalesce((select sum(amount) from wallet_entries where amount > 0 and reason like 'Refund%' and created_at::date between w0 and w1 + 2), 0), 2),
        'momo_refunds', (select count(*) from orders where refund_needed and order_date between w0 and w1),
        'wallets_owed', round(coalesce((select sum(wallet_balance(u)) from (select distinct user_id as u from orders where user_id is not null union select distinct user_id from wallet_entries) us), 0), 2))
      from cur) end,
    'buildings', coalesce((select json_agg(b order by b.meals desc) from (
        select si.name, sum(c.qty)::int as meals, count(distinct c.pool_id)::int as pools,
               round(sum(c.qty)::numeric / nullif(count(distinct c.pool_id), 0), 1) as avg_pool,
               coalesce((select sum(qty) from prev where prev.site_id = si.id), 0)::int as prev_meals
        from cur c join sites si on si.id = c.site_id group by si.id, si.name order by 2 desc limit 15) b), '[]'::json),
    'quiet', coalesce((select json_agg(q) from (
        select si.name, sum(p.qty)::int as prev_meals from prev p join sites si on si.id = p.site_id
        where not exists (select 1 from cur c where c.site_id = p.site_id) group by si.name order by 2 desc) q), '[]'::json),
    'customers', coalesce((select json_agg(c2) from (
        select (array_agg(customer_name order by created_at desc))[1] as name,
               (select si.name from cur c3 join sites si on si.id = c3.site_id where c3.phone = c.phone group by si.name order by count(*) desc limit 1) as building,
               case when is_super() then c.phone end as phone,
               count(*) filter (where parent_id is null)::int as orders, sum(qty)::int as meals
        from cur c group by c.phone order by sum(qty) desc, count(*) desc limit 15) c2), '[]'::json),
    'vendors', coalesce((select json_agg(v order by v.meals desc) from (
        select k.public_name as name, coalesce(sum(c.qty), 0)::int as meals,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status <> 'cancelled' and pl.meals > 0)::int as pools,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status = 'cancelled'
                  and exists (select 1 from orders x where x.pool_id = pl.id and x.cancel_reason = 'The seller did not confirm in time'))::int as expired,
               (select round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*) filter (where pl.delivered_at is not null), 0))
                  from pl where pl.kitchen_id = k.id and pl.order_date >= w0)::int as on_time,
               (select count(*) from o where o.kitchen_id = k.id and o.order_date >= w0 and o.cancel_reason like 'The seller can''t%')::int as declined,
               (select count(*) from (select phone from live where live.kitchen_id = k.id and live.order_date between w0 - 28 and w1 group by phone having count(distinct order_date) >= 2) r)::int as repeat_customers,
               cardinality(k.auto_days) > 0 as always_cooking,
               (select round(avg(r.rating), 1) from reviews r where r.kitchen_id = k.id and not r.hidden and r.created_at::date between w0 and w1 + 2) as rating
        from kitchens k left join cur c on c.kitchen_id = k.id where k.active
        group by k.id, k.public_name, k.auto_days having coalesce(sum(c.qty), 0) > 0
           or exists (select 1 from pl where pl.kitchen_id = k.id and pl.order_date >= w0)) v), '[]'::json),
    'riders', coalesce((select json_agg(r) from (
        select rd.name, count(*)::int as deliveries,
               round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*), 0))::int as on_time
        from pl join riders rd on rd.id = pl.rider_id where pl.order_date >= w0 and pl.delivered_at is not null group by rd.name order by 2 desc) r), '[]'::json)
  ));
end $$;
grant execute on function admin_weekly_report(date) to authenticated;

notify pgrst, 'reload schema';

-- ---------- from update19 ----------
-- ============================================================
-- ChopPool update 19 (Release A: security). Safe to run more than once.
-- ============================================================

-- 1. Public views are read-only (they run with the owner's rights, so writes would bypass row security)
revoke insert, update, delete, truncate, references, trigger on
  public_sites, public_pools, kitchen_load, recent_activity, public_menus, dish_popularity, site_kitchen_counts, public_reviews, kitchen_scores
  from anon, authenticated, public;

-- 2. The activity feed no longer shows real order IDs (a one-way fingerprint instead)
drop view if exists recent_activity;
create view recent_activity as
select left(encode(sha256(convert_to(o.id::text, 'UTF8')), 'hex'), 16) as id,
       o.order_date, o.site_id, o.kitchen_id, o.pool_id, o.item_name, o.qty, o.created_at
  from orders o
 where o.status not in ('cancelled', 'quote_requested', 'quoted') and o.created_at > now() - interval '6 hours';
revoke all on recent_activity from anon, authenticated, public;
grant select on recent_activity to anon, authenticated;

-- 3. Sellers only see order IDs for special requests they need to price
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
                                 'delivery_mode', k.delivery_mode, 'added_by_customer', k.added_by_customer,
                                 'open', kitchen_is_open(k.id, p_date), 'listing_status', k.listing_status, 'listing', k.listing,
                                 'auto_days', k.auto_days, 'paused', p_date = any(k.paused_dates),
                                 'confirmed', exists (select 1 from kitchen_days where kitchen_id = k.id and order_date = p_date),
                                 'has_pin', k.lat is not null, 'free_m', k.free_m, 'free_min', k.free_min, 'free_max_m', s.free_max_m,
                                 'fee_ack', k.fee_ack, 'fee_free_ack', k.fee_free_ack, 'fee_rate', s.vendor_fee_rate, 'fee_free', s.vendor_fee_free,
                                 'next_day_confirm_by', s.next_day_confirm_by),
    'menu', coalesce((select json_agg(json_build_object('id', id, 'name', name, 'price', price, 'addons', addons,
                                                        'photo_url', photo_url, 'icon', icon) order by name)
                      from menu_items where kitchen_id = k.id and active), '[]'::json),
    'pools', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'seq', p.seq, 'status', p.status, 'site', si.name, 'drop_point', si.drop_point,
        'handoff', si.handoff, 'host_label', si.host_label, 'created_at', p.created_at,
        'wait_until', case when p.status = 'waiting' then wait_deadline(p.created_at, p.order_date) end,
        'free', pool_free(p.id), 'fee_rate', p.fee_rate, 'fee_free', p.fee_free, 'fee', pool_fee(p.id),
        'orders', (select json_agg(json_build_object('id', case when o.status in ('quote_requested', 'quoted') then o.id end, 'code', o.code, 'qty', o.qty, 'item_name', o.item_name,
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

-- 4. Internal helpers can't be called from outside (functions that use them still work)
do $$ declare f text; begin
  foreach f in array array['fee_for(integer)', 'fee_for(integer, numeric)', 'new_code(uuid, date, uuid)', 'order_cashback(uuid)', 'pool_fee(uuid)', 'pool_free(uuid)',
                           'pool_meals(uuid)', 'pool_trip(uuid)', 'wait_deadline(timestamp with time zone, date)', 'wallet_balance(uuid)'] loop
    if to_regprocedure('public.' || f) is not null then
      execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    end if;
  end loop;
end $$;

-- 5. Owner-only money settings, enforced by the database
create or replace function settings_owner_guard() returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') and not is_super()
     and (new.vendor_fee_rate is distinct from old.vendor_fee_rate or new.vendor_fee_free is distinct from old.vendor_fee_free) then
    raise exception 'Only the owner can change the ChopPool vendor fee.';
  end if;
  return new;
end $$;
drop trigger if exists settings_owner_guard on settings;
create trigger settings_owner_guard before update on settings for each row execute function settings_owner_guard();

-- 6. Wallet credits and debits: owner only (coordinators can still see wallets)
drop policy if exists "admin wallets" on wallet_entries;
drop policy if exists "team wallets read" on wallet_entries;
drop policy if exists "owner wallets" on wallet_entries;
create policy "team wallets read" on wallet_entries for select to authenticated using (is_admin());
create policy "owner wallets" on wallet_entries for all to authenticated using (is_super()) with check (is_super());

-- 7. Coordinators can only change payment checks, status and refund flags on orders
create or replace function orders_coordinator_guard() returns trigger language plpgsql as $$
declare a jsonb; b jsonb; k text;
begin
  if current_user not in ('authenticated', 'anon') or is_super() then return new; end if;
  a := to_jsonb(old); b := to_jsonb(new);
  for k in select key from jsonb_each(b) loop
    if k in ('status', 'pay_issue', 'amount_received', 'refund_needed', 'collected_at', 'collected_by') then continue; end if;
    if k = 'refund_due' and coalesce((b->>k)::numeric, 0) = 0 then continue; end if;
    if (a->k) is distinct from (b->k) then raise exception 'Coordinators can''t change % on an order. Ask the owner.', k; end if;
  end loop;
  return new;
end $$;
drop trigger if exists orders_coordinator_guard on orders;
create trigger orders_coordinator_guard before update on orders for each row execute function orders_coordinator_guard();
-- Coordinators can't delete orders either
drop policy if exists "admin orders" on orders;
drop policy if exists "team orders" on orders;
drop policy if exists "team orders update" on orders;
drop policy if exists "owner orders" on orders;
create policy "team orders" on orders for select to authenticated using (is_admin());
create policy "team orders update" on orders for update to authenticated using (is_admin()) with check (is_admin());
create policy "owner orders" on orders for all to authenticated using (is_super()) with check (is_super());

-- ---------- from update20 ----------
-- ============================================================
-- ChopPool update 20 (Release B: money, order flow, admin control). Safe to run more than once.
-- ============================================================

-- Settings
alter table settings add column if not exists trip_max numeric not null default 80;            -- safety ceiling on a whole trip (GHS)
alter table settings add column if not exists quote_pay_min int not null default 15;           -- minutes to pay a priced special order
alter table settings add column if not exists auto_receive_min int not null default 120;       -- "Got my food" confirms itself after this
alter table settings add column if not exists admin_idle_min int not null default 15;          -- admin screen timeout
alter table settings add column if not exists cashback_ledger_from timestamptz;
update settings set cashback_ledger_from = coalesce(cashback_ledger_from, now()) where id = 1;

-- Orders: received / problem / special-order payment window / pool switch / refund records / solo answer
alter table orders add column if not exists received_at timestamptz;
alter table orders add column if not exists problem text;
alter table orders add column if not exists problem_at timestamptz;
alter table orders add column if not exists problem_resolved_at timestamptz;
alter table orders add column if not exists problem_note text;
alter table orders add column if not exists cashback_posted boolean not null default false;
alter table orders add column if not exists quoted_at timestamptz;
alter table orders add column if not exists quote_pay_by timestamptz;
alter table orders add column if not exists carried_amount numeric not null default 0;
alter table orders add column if not exists moved_from uuid;
alter table orders add column if not exists refund_amount numeric;
alter table orders add column if not exists refund_ref text;
alter table orders add column if not exists refunded_at timestamptz;
alter table orders add column if not exists refunded_by text;
alter table orders add column if not exists solo_choice text;

-- Pricing: every customer pays the full trip once (spread over the meals on their code); cashback returns the shared part.
-- The only cap is a safety ceiling on the whole trip.
create or replace function fee_for(p_meals integer, p_trip numeric) returns numeric language sql stable security definer set search_path = public as $$
  select case when p_meals <= 0 then ceil(least(coalesce(p_trip, s.trip_cost), s.trip_max) * 2) / 2
              else ceil(least(coalesce(p_trip, s.trip_cost), s.trip_max) / p_meals * 2) / 2 end
  from settings s where s.id = 1;
$$;
create or replace function fee_for(p_meals integer) returns numeric language sql stable security definer set search_path = public as $$
  select fee_for(p_meals, null::numeric);
$$;
create or replace function pool_trip(p uuid) returns numeric language sql stable security definer set search_path = public as $$
  select case
    when pool_free(p) then 0
    when coalesce(k.lat, case when k.added_by_customer then st.lat end) is null or st.lat is null then least(s.trip_cost, s.trip_max)
    else least(s.trip_max, round(s.base_fare + s.per_km * dist_m(
           coalesce(k.lat, case when k.added_by_customer then st.lat end),
           coalesce(k.lng, case when k.added_by_customer then st.lng end),
           st.lat, st.lng) / 1000 * 1.3))
  end
  from pools pl join kitchens k on k.id = pl.kitchen_id join sites st on st.id = pl.site_id cross join settings s
  where pl.id = p and s.id = 1;
$$;

-- One order for the steps every screen shows
create or replace function step_rank(p text) returns int language sql immutable as $$
  select case p when 'waiting' then 0 when 'collecting' then 1 when 'accepted' then 2 when 'ready' then 3
                when 'picked_up' then 4 when 'arriving' then 5 when 'delivered' then 6 else -1 end;
$$;

-- Wallet = fixed entries only (cashback is posted once, as its own line, when the order is received)
create or replace function wallet_balance(p_user uuid) returns numeric language sql stable security definer set search_path = public as $$
  select round(coalesce((select sum(amount) from wallet_entries where user_id = p_user), 0), 2);
$$;
create or replace function my_wallet() returns json language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in to see your wallet.'; end if;
  return json_build_object(
    'balance', wallet_balance(v_uid),
    'pending', coalesce((select round(sum(order_cashback(o.id)), 2) from orders o join pools p on p.id = o.pool_id cross join settings s
                         where s.id = 1 and o.user_id = v_uid and o.parent_id is null and o.status in ('paid', 'collected') and not o.cashback_posted
                           and p.status <> 'cancelled' and (now() at time zone 'utc') >= o.order_date + s.cutoff), 0),
    'entries', coalesce((select json_agg(x order by x.at desc) from (
        select created_at as at, amount, reason from wallet_entries where user_id = v_uid order by created_at desc limit 60) x), '[]'::json));
end $$;

-- "Got my food" / "Report a problem" (owner of the order: the account, or the phone holding the order's private ID)
create or replace function confirm_received(p_order uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  update orders set received_at = coalesce(received_at, now())
   where id = p_order and parent_id is null and status = 'collected' and (user_id is null or user_id = auth.uid());
  perform housekeeping();
end $$;
create or replace function report_problem(p_order uuid, p_text text) returns void language plpgsql security definer set search_path = public as $$
begin
  if char_length(trim(coalesce(p_text, ''))) < 3 then raise exception 'Say what went wrong.'; end if;
  update orders set problem = left(trim(p_text), 500), problem_at = now(), problem_resolved_at = null
   where id = p_order and parent_id is null and status in ('paid', 'collected') and not cashback_posted
     and (user_id is null or user_id = auth.uid());
  if not found then raise exception 'This order can''t take a report any more.'; end if;
end $$;
create or replace function resolve_problem(p_order uuid, p_note text, p_credit numeric default 0) returns void language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  if coalesce(p_credit, 0) <> 0 and not is_super() then raise exception 'Only the owner can add wallet credit.'; end if;
  update orders set problem_resolved_at = now(), problem_note = left(trim(coalesce(p_note, '')), 500) where id = p_order returning * into o;
  if coalesce(p_credit, 0) > 0 and o.user_id is not null then
    insert into wallet_entries (user_id, amount, reason, order_id) values (o.user_id, p_credit, 'Sorted: ' || coalesce(nullif(trim(p_note), ''), 'problem with code ' || o.code), o.id);
  end if;
  perform housekeeping();
end $$;

-- Solo-pool answer (Keep / Cancel / Switch), so the team can see it
create or replace function solo_choice(p_order uuid, p_choice text) returns void language plpgsql security definer set search_path = public as $$
begin
  if p_choice not in ('keep', 'cancel', 'switch', 'share') then raise exception 'Unknown choice.'; end if;
  update orders set solo_choice = p_choice where id = p_order and (user_id is null or user_id = auth.uid());
end $$;

-- Move an order to another open pool before cut-off: the money already paid moves across
create or replace function switch_order(p_from uuid, p_site uuid, p_item uuid, p_qty int, p_addons text[], p_note text, p_ref text default null)
returns json language plpgsql security definer set search_path = public as $$
declare o orders; s settings; v_paid numeric; r json; n orders; v_new_total numeric; v_diff numeric;
begin
  select * into s from settings where id = 1;
  select * into o from orders where id = p_from and parent_id is null for update;
  if not found then raise exception 'Order not found.'; end if;
  if o.user_id is not null and o.user_id is distinct from auth.uid() then raise exception 'Sign in with the account that placed this order.'; end if;
  if o.status not in ('pending', 'paid') then raise exception 'This order can''t be moved.'; end if;
  if exists (select 1 from orders c where c.parent_id = o.id and c.status <> 'cancelled') then raise exception 'Cancel the extra plates on this order first.'; end if;
  if (now() at time zone 'utc') >= o.order_date + s.cutoff then raise exception 'Orders have closed, so this order can''t move now.'; end if;
  v_paid := order_total(o);   -- everything paid for this order (MoMo, wallet and anything carried in from an earlier move)
  update orders set status = 'cancelled', cancel_reason = 'Moved to another pool', refund_needed = false, refund_due = 0, wallet_used = 0 where id = o.id;
  r := place_order(p_site, p_item, p_qty, o.customer_name, o.phone, coalesce(nullif(trim(coalesce(p_ref, '')), ''), o.momo_ref), p_addons, p_note, null, false, null);
  select * into n from orders where id = (r ->> 'id')::uuid for update;
  update orders set user_id = o.user_id, moved_from = o.id, carried_amount = least(v_paid, order_total(n)),
                    momo_ref = case when p_ref is not null and trim(p_ref) <> '' and o.momo_ref is not null then o.momo_ref || ' + ' || trim(p_ref) else n.momo_ref end,
                    status = case when o.status = 'paid' and order_total(n) <= v_paid then 'paid' else n.status end,
                    pay_issue = null
   where id = n.id returning * into n;
  v_new_total := order_total(n); v_diff := v_paid - v_new_total;
  if v_diff > 0 then
    if o.user_id is not null and o.status = 'paid' then
      insert into wallet_entries (user_id, amount, reason, order_id) values (o.user_id, v_diff, 'Money back: moved to a cheaper order, code ' || n.code, n.id);
    else
      update orders set refund_due = v_diff, refund_needed = true where id = o.id;
    end if;
  end if;
  return json_build_object('id', n.id, 'code', n.code, 'status', n.status, 'to_pay', greatest(0, -v_diff), 'refund', greatest(0, v_diff),
                           'meals', pool_meals(n.pool_id), 'pool_status', (select status from pools where id = n.pool_id), 'pool_seq', (select seq from pools where id = n.pool_id), 'order_date', n.order_date);
end $$;

-- Payments that arrived but couldn't become an order (sold out, closed): kept for a refund
create table if not exists unmatched_payments (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  name text, phone text, amount numeric, momo_ref text, reason text,
  refunded_at timestamptz, refund_ref text, refunded_by text
);
alter table unmatched_payments enable row level security;
drop policy if exists "team unmatched" on unmatched_payments;
create policy "team unmatched" on unmatched_payments for all to authenticated using (is_admin()) with check (is_admin());
create or replace function record_unmatched(p_name text, p_phone text, p_amount numeric, p_ref text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if char_length(trim(coalesce(p_ref, ''))) < 4 then return; end if;
  if (select count(*) from unmatched_payments where phone = v_phone and created_at > now() - interval '1 day') >= 5 then return; end if;
  if exists (select 1 from unmatched_payments where momo_ref = trim(p_ref)) then return; end if;
  insert into unmatched_payments (name, phone, amount, momo_ref, reason)
  values (left(trim(coalesce(p_name, '')), 80), v_phone, least(greatest(coalesce(p_amount, 0), 0), 5000), left(trim(p_ref), 60), left(coalesce(p_reason, ''), 200));
end $$;

-- MoMo references already used on another order (last 30 days)
create or replace function admin_refs_seen(p_refs text[], p_date date) returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  return coalesce((select json_object_agg(ref, n) from (
    select trim(o.momo_ref) as ref, count(*) as n from orders o
     where trim(o.momo_ref) = any(p_refs) and o.order_date between p_date - 30 and p_date + 1 and o.status <> 'cancelled'
     group by 1 having count(*) > 1) x), '{}'::json);
end $$;

-- Payouts to sellers and riders, and what's still due
create table if not exists payouts (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  payee_type text not null check (payee_type in ('seller', 'rider')),
  kitchen_id uuid references kitchens(id),
  rider_id uuid references riders(id),
  amount numeric not null check (amount > 0),
  momo_ref text, note text, paid_by text
);
alter table payouts enable row level security;
drop policy if exists "team payouts read" on payouts;
drop policy if exists "owner payouts" on payouts;
create policy "team payouts read" on payouts for select to authenticated using (is_admin());
create policy "owner payouts" on payouts for all to authenticated using (is_super()) with check (is_super());

create or replace function admin_dues(p_from date, p_to date) returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  return json_build_object(
    'sellers', coalesce((select json_agg(x order by x.due desc) from (
      select k.id, k.name, k.whatsapp,
             round(coalesce(sum(e.food) filter (where e.order_date between p_from and p_to), 0), 2) as food,
             round(coalesce(sum(e.fee) filter (where e.order_date between p_from and p_to), 0), 2) as fee,
             round(coalesce(sum(e.food - e.fee), 0) - coalesce((select sum(amount) from payouts py where py.kitchen_id = k.id and py.payee_type = 'seller'), 0), 2) as due,
             coalesce((select sum(amount) from payouts py where py.kitchen_id = k.id and py.payee_type = 'seller'), 0) as paid
        from kitchens k
        left join (select p.kitchen_id, p.order_date, p.id,
                          coalesce((select sum((coalesce(o.quote_price, o.unit_price) + o.addons_total) * o.qty) from orders o
                                     where o.pool_id = p.id and o.status in ('paid', 'collected') and (o.received_at is not null or o.cashback_posted)), 0) as food,
                          coalesce(pool_fee(p.id), 0) as fee
                     from pools p where p.status = 'delivered') e on e.kitchen_id = k.id
       group by k.id) x where x.food > 0 or x.due <> 0), '[]'::json),
    'riders', coalesce((select json_agg(x order by x.due desc) from (
      select r.id, r.name, r.phone,
             round(coalesce(sum(p.trip_cost) filter (where p.order_date between p_from and p_to), 0), 2) as trips,
             round(coalesce(sum(p.trip_cost), 0) - coalesce((select sum(amount) from payouts py where py.rider_id = r.id and py.payee_type = 'rider'), 0), 2) as due,
             coalesce((select sum(amount) from payouts py where py.rider_id = r.id and py.payee_type = 'rider'), 0) as paid
        from riders r left join pools p on p.rider_id = r.id and p.status = 'delivered'
       group by r.id) x where x.trips > 0 or x.due <> 0), '[]'::json));
end $$;

-- Activity log: who changed what, when (team actions only)
create table if not exists activity_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor text, entity text not null, entity_id text, action text not null, changes jsonb
);
alter table activity_log enable row level security;
drop policy if exists "owner log" on activity_log;
create policy "owner log" on activity_log for select to authenticated using (is_super());
create or replace function log_change() returns trigger language plpgsql security definer set search_path = public as $$
declare a jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end; b jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end; d jsonb := '{}'; k text;
begin
  if coalesce(current_setting('role', true), '') <> 'authenticated' or not is_admin() then return coalesce(new, old); end if;   -- team actions only
  if tg_op = 'UPDATE' then
    for k in select key from jsonb_each(b) loop
      if (a -> k) is distinct from (b -> k) then d := d || jsonb_build_object(k, jsonb_build_array(a -> k, b -> k)); end if;
    end loop;
    if d = '{}'::jsonb then return new; end if;
  else d := coalesce(b, a); end if;
  insert into activity_log (actor, entity, entity_id, action, changes)
  values (coalesce(auth.jwt() ->> 'email', 'unknown'), tg_table_name, coalesce(b ->> 'id', a ->> 'id'), lower(tg_op), d);
  return coalesce(new, old);
end $$;
do $$ declare t text; begin
  foreach t in array array['orders', 'wallet_entries', 'settings', 'pools', 'payouts', 'admins', 'kitchens', 'riders', 'sites', 'unmatched_payments'] loop
    execute format('drop trigger if exists log_change on %I', t);
    execute format('create trigger log_change after insert or update or delete on %I for each row execute function log_change()', t);
  end loop;
end $$;

-- Coordinators: also allowed to record refunds and close problem reports
create or replace function orders_coordinator_guard() returns trigger language plpgsql as $$
declare a jsonb; b jsonb; k text;
begin
  if current_user not in ('authenticated', 'anon') or is_super() then return new; end if;
  a := to_jsonb(old); b := to_jsonb(new);
  for k in select key from jsonb_each(b) loop
    if k in ('status', 'pay_issue', 'amount_received', 'refund_needed', 'collected_at', 'collected_by',
             'refund_amount', 'refund_ref', 'refunded_at', 'refunded_by', 'problem_resolved_at', 'problem_note') then continue; end if;
    if k = 'refund_due' and coalesce((b->>k)::numeric, 0) = 0 then continue; end if;
    if (a->k) is distinct from (b->k) then raise exception 'Coordinators can''t change % on an order. Ask the owner.', k; end if;
  end loop;
  return new;
end $$;

-- Pay for a priced special order only inside its payment window
create or replace function quote_window_guard() returns trigger language plpgsql as $$
begin
  if old.status = 'quoted' and new.status in ('pending', 'paid') and old.quote_pay_by is not null and now() > old.quote_pay_by + interval '30 seconds' then
    raise exception 'The time to pay for this special order has run out.';
  end if;
  return new;
end $$;
drop trigger if exists quote_window_guard on orders;
create trigger quote_window_guard before update on orders for each row execute function quote_window_guard();


-- ---------- updated functions ----------
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
begin
  perform housekeeping();
  select * into s from settings where id = 1;
  select * into m from menu_items where id = p_item and active;
  if not found then raise exception 'That dish is no longer available.'; end if;
  select * into k from kitchens where id = m.kitchen_id and active;
  if not found then raise exception 'That vendor is not taking orders.'; end if;
  if p_qty is null or p_qty < 1 or p_qty > least(5, s.max_meals) then raise exception 'Choose between 1 and 5 meals.'; end if;

  v_special := nullif(trim(coalesce(p_special, '')), '');
  select coalesce(jsonb_agg(a), '[]'::jsonb), coalesce(sum((a ->> 'price')::numeric), 0)
    into v_add, v_add_total
  from jsonb_array_elements(m.addons) a where a ->> 'name' = any(coalesce(p_addons, '{}'));

  perform pg_advisory_xact_lock(hashtext('cp' || k.id::text || d::text));
  select coalesce(sum(qty), 0) into v_load from orders where kitchen_id = k.id and order_date = d and status <> 'cancelled'
     and not (status = 'pending' and pay_issue is not null and pay_issue <> 'short');   -- payments we couldn't find don't hold seats
  if v_load + p_qty > k.capacity then raise exception 'This menu is fully booked for today. Try another one.'; end if;

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
    if v_special is not null then raise exception 'Special requests can''t be added to an order. Choose from the menu.'; end if;
    select * into pl from pools where id = par.pool_id;
    if pl.status not in ('waiting', 'collecting') then raise exception 'This pool has closed. Start a new order instead.'; end if;
    if pool_meals(pl.id) + p_qty > s.max_meals then raise exception 'This pool is full. Start a new order for more plates.'; end if;
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status,
                        parent_id, fee_per_meal)
    values (d, pl.id, par.site_id, k.id, m.id, par.user_id, m.name, m.price, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), null, par.customer_name, par.phone, par.code, 0, s.service_fee, 'pending',
            par.id, true)
    returning id, code into v_id, v_code;
  else
    if (select count(*) from orders where phone = v_phone and parent_id is null and status = 'pending' and created_at > now() - interval '1 day') >= 3 then
      raise exception 'You have 3 orders waiting for their payment to be checked. Wait for those before placing another.';
    end if;
    select * into si from sites where id = p_site and active;
    if not found then raise exception 'That drop point is not active.'; end if;
    if k.site_id is not null and k.site_id <> si.id then raise exception 'That vendor only delivers to another drop point.'; end if;
    if v_special is not null and d = (now() at time zone 'utc')::date and (now() at time zone 'utc')::time >= s.special_cutoff then
      raise exception 'Special requests close at %. You can still order from the menu.', to_char(s.special_cutoff, 'HH24:MI');
    end if;
    -- While the vendor hasn't confirmed, everyone at the building joins the same waiting pool
    v_open := kitchen_is_open(k.id, d);
    select p.* into pl from pools p
     where p.order_date = d and p.site_id = si.id and p.kitchen_id = k.id
       and p.status = case when v_open then 'collecting' else 'waiting' end
       and pool_meals(p.id) + p_qty <= s.max_meals
     order by p.seq limit 1;
    if not found then
      insert into pools (order_date, site_id, kitchen_id, seq, status)
      values (d, si.id, k.id, coalesce((select max(seq) from pools where order_date = d and site_id = si.id and kitchen_id = k.id and status <> 'cancelled'), 0) + 1,
              case when v_open then 'collecting' else 'waiting' end)
      returning * into pl;
    end if;
    v_code := new_code(si.id, d, pl.id);
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status, fee_per_meal)
    values (d, pl.id, si.id, k.id, m.id, auth.uid(), m.name, m.price, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), v_special, trim(p_name), v_phone,
            v_code, ceil(fee_for(0, pool_trip(pl.id)) / p_qty * 2) / 2, s.service_fee, case when v_special is null then 'pending' else 'quote_requested' end, true)
    returning id into v_id;
  end if;

  if v_special is null then
    v_pay := settle_payment(v_id, p_ref, p_use_wallet);
  end if;

  return json_build_object('id', v_id, 'code', v_code, 'order_date', d, 'pool_seq', pl.seq, 'pool_status', pl.status,
    'pool_id', pl.id, 'meals', pool_meals(pl.id), 'status', (select status from orders where id = v_id), 'payment', v_pay,
    'parent_id', p_join);
end $function$;

drop function if exists public.my_orders(uuid[]);
CREATE OR REPLACE FUNCTION public.my_orders(p_ids uuid[])
 RETURNS TABLE(id uuid, order_date date, code text, status text, qty integer, item_name text, site_id uuid, kitchen_id uuid, pool_seq integer, pool_status text, special_request text, quote_price numeric, amount_due numeric, cancel_reason text, unit_price numeric, addons jsonb, addons_total numeric, max_fee numeric, service_fee numeric, wallet_used numeric, saving numeric, has_account boolean, refund_needed boolean, parent_id uuid, fee_per_meal boolean, item_id uuid, pool_id uuid, created_at timestamp with time zone, refund_due numeric, my_rating integer, my_photo text, pay_issue text, amount_received numeric, momo_ref text, wait_until timestamp with time zone, vendor_delivers boolean, received_at timestamp with time zone, problem text, problem_resolved boolean, quote_pay_by timestamp with time zone, carried_amount numeric, collected_at timestamp with time zone, cashback_posted boolean, solo_choice text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select o.id, o.order_date, o.code, o.status, o.qty, o.item_name, o.site_id, o.kitchen_id, p.seq, p.status,
         o.special_request, o.quote_price,
         order_total(o) - o.wallet_used - coalesce(o.carried_amount, 0),
         o.cancel_reason, o.unit_price, o.addons, o.addons_total, o.max_fee, o.service_fee, o.wallet_used,
         case when o.status in ('pending', 'paid', 'collected') and p.status <> 'cancelled' then order_cashback(o.id) else 0 end,
         o.user_id is not null, o.refund_needed, o.parent_id, o.fee_per_meal, o.item_id, o.pool_id, o.created_at, o.refund_due,
         r.rating, r.photo_url, o.pay_issue, o.amount_received, o.momo_ref,
         case when p.status = 'waiting' then wait_deadline(p.created_at, p.order_date) end, pool_free(p.id),
         o.received_at, o.problem, o.problem_resolved_at is not null, o.quote_pay_by, coalesce(o.carried_amount, 0), o.collected_at, o.cashback_posted, o.solo_choice
  from orders o join pools p on p.id = o.pool_id left join reviews r on r.order_id = o.id
  where (o.id = any(p_ids) or o.parent_id = any(p_ids) or (auth.uid() is not null and o.user_id = auth.uid()))
    and o.order_date >= (now() at time zone 'utc')::date - 1
  order by o.created_at desc;
$function$;

CREATE OR REPLACE FUNCTION public.kitchen_quote(p_token text, p_order uuid, p_price numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_price is null or p_price <= 0 or p_price > 1000 then raise exception 'Enter a price per meal in cedis.'; end if;
  if exists (select 1 from orders o, settings s where o.id = p_order and s.id = 1
             and (now() at time zone 'utc') >= o.order_date + s.cutoff - make_interval(mins => s.quote_pay_min)) then
    raise exception 'Pricing for today has closed, so the customer would have no time to pay.';
  end if;
  update orders o set quote_price = p_price, status = 'quoted', quoted_at = now(),
         quote_pay_by = least(now() + make_interval(mins => (select quote_pay_min from settings where id = 1)),
                              (o.order_date + (select cutoff from settings where id = 1)) at time zone 'utc')
  from kitchens k
  where k.token = p_token and k.active and o.kitchen_id = k.id and o.id = p_order and o.status in ('quote_requested', 'quoted');
  if not found then raise exception 'That request can no longer be priced.'; end if;
end $function$;

CREATE OR REPLACE FUNCTION public.rider_update(p_token text, p_pool uuid, p_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_status not in ('picked_up', 'arriving', 'delivered') then raise exception 'Unknown step.'; end if;
  if exists (select 1 from pools where id = p_pool and step_rank(status) >= step_rank(p_status)) then return; end if;   -- steps only move forward
  update pools p set status = p_status,
    picked_up_at = case when p_status = 'picked_up' then now() else p.picked_up_at end,
    arriving_at  = case when p_status = 'arriving'  then now() else p.arriving_at end,
    delivered_at = case when p_status = 'delivered' then now() else p.delivered_at end
  from riders r
  where r.token = p_token and r.active and p.rider_id = r.id and p.id = p_pool;
  if not found then raise exception 'That pool is not assigned to you.'; end if;
end $function$;

CREATE OR REPLACE FUNCTION public.rider_view(p_token text, p_date date)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r riders;
begin
  select * into r from riders where token = p_token and active;
  if not found then raise exception 'This rider link is not valid.'; end if;
  return json_build_object(
    'rider', json_build_object('name', r.name),
    'pools', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'seq', p.seq, 'status', p.status, 'meals', pool_meals(p.id),
        'kitchen', k.name, 'kitchen_address', k.address, 'kitchen_phone', k.whatsapp,
        'site', si.name, 'drop_point', si.drop_point, 'site_lat', si.lat, 'site_lng', si.lng, 'picked_up_at', p.picked_up_at, 'handoff', si.handoff, 'host_label', si.host_label,
        'orders', (select json_agg(json_build_object('code', o.code, 'name', o.customer_name, 'qty', o.qty,
                                                     'item_name', o.item_name, 'collected', o.status = 'collected')
                                   order by o.customer_name)
                   from orders o where o.pool_id = p.id and o.status <> 'cancelled'))
        order by si.name, p.seq)
      from pools p join sites si on si.id = p.site_id join kitchens k on k.id = p.kitchen_id
      where p.rider_id = r.id and p.order_date = p_date and p.status not in ('cancelled', 'waiting')
    ), '[]'::json));
end $function$;

CREATE OR REPLACE FUNCTION public.request_site(p_name text, p_drop_point text, p_lat double precision, p_lng double precision, p_note text DEFAULT NULL::text, p_endpoint text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare si sites; v_joined boolean := false; v_n int;
begin
  if char_length(trim(coalesce(p_name, ''))) < 3 then raise exception 'Add the building''s name.'; end if;
  if char_length(trim(coalesce(p_drop_point, ''))) < 3 then raise exception 'Say where the food should be dropped, like "Main gate".'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'Drop a pin on the map first.'; end if;
  if p_endpoint is not null and (p_endpoint !~ '^https://' or length(p_endpoint) > 1000) then p_endpoint := null; end if;
  -- Already requested? Same name, or a pending building within 80 m: join its waitlist instead
  select * into si from sites
   where status = 'pending' and not archived
     and (lower(regexp_replace(name, '\s+', ' ', 'g')) = lower(regexp_replace(trim(p_name), '\s+', ' ', 'g'))
          or (lat is not null and dist_m(lat, lng, p_lat, p_lng) <= 80))
   order by created_at limit 1;
  if found then
    v_joined := true;
  else
    if (select count(*) from site_waiters w where w.created_at > now() - interval '1 day'
        and ((auth.uid() is not null and w.user_id = auth.uid()) or (p_endpoint is not null and w.endpoint = p_endpoint))) >= 5
     or (select count(*) from sites where status = 'pending' and created_at > now() - interval '1 day') >= 300 then
      raise exception 'Too many building requests today. Please try again tomorrow.';
    end if;
    insert into sites (name, drop_point, lat, lng, status, requested_by, request_note)
    values (trim(p_name), trim(p_drop_point), p_lat, p_lng, 'pending', auth.uid(), nullif(trim(coalesce(p_note, '')), ''))
    returning * into si;
  end if;
  if auth.uid() is not null or p_endpoint is not null then
    insert into site_waiters (site_id, user_id, endpoint) values (si.id, auth.uid(), p_endpoint) on conflict do nothing;
  end if;
  select count(*) into v_n from site_waiters where site_id = si.id;
  return json_build_object('id', si.id, 'name', si.name, 'status', si.status, 'joined', v_joined, 'waiting', greatest(v_n, 1));
end $function$;


CREATE OR REPLACE FUNCTION public.kitchen_update(p_token text, p_pool uuid, p_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p pools; k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This seller link is not valid.'; end if;
  select * into p from pools where id = p_pool and kitchen_id = k.id;
  if not found then raise exception 'That pool is not for you.'; end if;
  if step_rank(p.status) >= step_rank(p_status) then return; end if;   -- steps only move forward
  if p_status = 'accepted' then
    if (now() at time zone 'utc') < p.order_date + (select cutoff from settings where id = 1) then
      raise exception 'Orders are still coming in. Confirm the final batch once the pool closes.';
    end if;
  elsif p_status in ('picked_up', 'arriving', 'delivered') then
    if k.delivery_mode <> 'runner' and not pool_free(p.id) then raise exception 'A ChopPool rider delivers this pool.'; end if;
  elsif p_status <> 'ready' then
    raise exception 'Unknown step.';
  end if;
  update pools set status = p_status,
    accepted_at  = case when p_status = 'accepted'  then coalesce(accepted_at, now()) else accepted_at end,
    ready_at     = case when p_status = 'ready'     then now() else ready_at end,
    picked_up_at = case when p_status = 'picked_up' then now() else picked_up_at end,
    arriving_at  = case when p_status = 'arriving'  then now() else arriving_at end,
    delivered_at = case when p_status = 'delivered' then now() else delivered_at end
  where id = p.id and status not in ('waiting', 'cancelled');
end $function$;

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
                                 'delivery_mode', k.delivery_mode, 'added_by_customer', k.added_by_customer,
                                 'open', kitchen_is_open(k.id, p_date), 'listing_status', k.listing_status, 'listing', k.listing,
                                 'auto_days', k.auto_days, 'paused', p_date = any(k.paused_dates),
                                 'confirmed', exists (select 1 from kitchen_days where kitchen_id = k.id and order_date = p_date),
                                 'has_pin', k.lat is not null, 'free_m', k.free_m, 'free_min', k.free_min, 'free_max_m', s.free_max_m,
                                 'fee_ack', k.fee_ack, 'fee_free_ack', k.fee_free_ack, 'fee_rate', s.vendor_fee_rate, 'fee_free', s.vendor_fee_free,
                                 'next_day_confirm_by', s.next_day_confirm_by),
    'menu', coalesce((select json_agg(json_build_object('id', id, 'name', name, 'price', price, 'addons', addons,
                                                        'photo_url', photo_url, 'icon', icon) order by name)
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

CREATE OR REPLACE FUNCTION public.admin_weekly_report(p_week_start date)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s settings; w0 date := p_week_start; w1 date := p_week_start + 6; v0 date := p_week_start - 7; v1 date := p_week_start - 1;
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  select * into s from settings where id = 1;
  return (
  with o as (select o.*, p.status as pool_status from orders o join pools p on p.id = o.pool_id where o.order_date between v0 and w1),
  live as (select * from o where status in ('paid', 'collected', 'pending')),
  cur as (select * from live where order_date between w0 and w1),
  prev as (select * from live where order_date between v0 and v1),
  pl as (select p.*, pool_meals(p.id) as meals from pools p where p.order_date between v0 and w1),
  firsts as (select phone, min(order_date) as first_day from orders where status in ('paid', 'collected', 'pending') group by phone),
  head as (
    select wk, sum(qty)::int as meals, count(*) filter (where parent_id is null)::int as orders, count(distinct phone)::int as customers,
           count(distinct phone) filter (where (select first_day from firsts f where f.phone = x.phone) >= x.ws)::int as new_customers
    from (select *, 'cur' as wk, w0 as ws from cur union all select *, 'prev', v0 from prev) x group by wk),
  rep as (
    select wk, round(100.0 * count(*) filter (where n >= 2) / nullif(count(*), 0))::int as repeat_rate
    from (select 'cur' as wk, phone, count(distinct order_date) as n from live where order_date between w0 - 7 and w1 and phone in (select phone from cur) group by phone
          union all select 'prev', phone, count(distinct order_date) from live where order_date between v0 - 7 and v1 and phone in (select phone from prev) group by phone) r group by wk),
  pools_w as (
    select case when order_date >= w0 then 'cur' else 'prev' end as wk, round(avg(meals), 1) as avg_meals,
           count(*) filter (where meals >= s.max_meals)::int as filled, count(*)::int as pools
    from pl where status <> 'cancelled' and meals > 0 group by 1),
  canc as (select case when order_date >= w0 then 'cur' else 'prev' end as wk, count(*)::int as n from o where status = 'cancelled' group by 1)
  select json_build_object(
    'week_start', w0, 'week_end', w1,
    'headline', (select json_object_agg(h.wk, json_build_object('meals', h.meals, 'orders', h.orders, 'customers', h.customers, 'new_customers', h.new_customers,
                    'repeat_rate', (select repeat_rate from rep where rep.wk = h.wk), 'avg_meals', (select avg_meals from pools_w where pools_w.wk = h.wk),
                    'pools', (select pools from pools_w where pools_w.wk = h.wk), 'filled', (select filled from pools_w where pools_w.wk = h.wk),
                    'cancelled', coalesce((select n from canc where canc.wk = h.wk), 0))) from head h),
    'money', case when is_super() then (select json_build_object(
        'food', round(coalesce(sum((coalesce(quote_price, unit_price) + addons_total) * qty), 0), 2),
        'trip_estimate', round(coalesce((select sum(pool_trip(p2.id)) from pools p2 where p2.order_date between w0 and w1 and p2.status = 'delivered'), 0), 2),
        'trip_paid', round(coalesce((select sum(p2.trip_cost) from pools p2 where p2.order_date between w0 and w1 and p2.status = 'delivered'), 0), 2),
        'commission', round(coalesce((select sum(pool_fee(p2.id)) from pools p2 where p2.order_date between w0 and w1 and p2.status <> 'cancelled'), 0), 2),
        'service_fees', round(coalesce(sum(service_fee * case when fee_per_meal then qty else 1 end), 0), 2),
        'cashback', round(coalesce(sum(case when parent_id is null and status in ('paid', 'collected') then order_cashback(id) else 0 end), 0), 2),
        'refunds', round(coalesce((select sum(amount) from wallet_entries where amount > 0 and reason like 'Refund%' and created_at::date between w0 and w1 + 2), 0), 2),
        'momo_refunds', (select count(*) from orders where refund_needed and order_date between w0 and w1),
        'wallets_owed', round(coalesce((select sum(wallet_balance(u)) from (select distinct user_id as u from orders where user_id is not null union select distinct user_id from wallet_entries) us), 0), 2))
      from cur) end,
    'buildings', coalesce((select json_agg(b order by b.meals desc) from (
        select si.name, sum(c.qty)::int as meals, count(distinct c.pool_id)::int as pools,
               round(sum(c.qty)::numeric / nullif(count(distinct c.pool_id), 0), 1) as avg_pool,
               coalesce((select sum(qty) from prev where prev.site_id = si.id), 0)::int as prev_meals
        from cur c join sites si on si.id = c.site_id group by si.id, si.name order by 2 desc limit 15) b), '[]'::json),
    'quiet', coalesce((select json_agg(q) from (
        select si.name, sum(p.qty)::int as prev_meals from prev p join sites si on si.id = p.site_id
        where not exists (select 1 from cur c where c.site_id = p.site_id) group by si.name order by 2 desc) q), '[]'::json),
    'customers', coalesce((select json_agg(c2) from (
        select (array_agg(customer_name order by created_at desc))[1] as name,
               (select si.name from cur c3 join sites si on si.id = c3.site_id where c3.phone = c.phone group by si.name order by count(*) desc limit 1) as building,
               case when is_super() then c.phone end as phone,
               count(*) filter (where parent_id is null)::int as orders, sum(qty)::int as meals
        from cur c group by c.phone order by sum(qty) desc, count(*) desc limit 15) c2), '[]'::json),
    'vendors', coalesce((select json_agg(v order by v.meals desc) from (
        select k.public_name as name, coalesce(sum(c.qty), 0)::int as meals,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status <> 'cancelled' and pl.meals > 0)::int as pools,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status = 'cancelled'
                  and exists (select 1 from orders x where x.pool_id = pl.id and x.cancel_reason = 'The seller did not confirm in time'))::int as expired,
               (select round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*) filter (where pl.delivered_at is not null), 0))
                  from pl where pl.kitchen_id = k.id and pl.order_date >= w0)::int as on_time,
               (select count(*) from o where o.kitchen_id = k.id and o.order_date >= w0 and o.cancel_reason like 'The seller can''t%')::int as declined,
               (select count(*) from (select phone from live where live.kitchen_id = k.id and live.order_date between w0 - 28 and w1 group by phone having count(distinct order_date) >= 2) r)::int as repeat_customers,
               cardinality(k.auto_days) > 0 as always_cooking,
               (select round(avg(r.rating), 1) from reviews r where r.kitchen_id = k.id and not r.hidden and r.created_at::date between w0 and w1 + 2) as rating
        from kitchens k left join cur c on c.kitchen_id = k.id where k.active
        group by k.id, k.public_name, k.auto_days having coalesce(sum(c.qty), 0) > 0
           or exists (select 1 from pl where pl.kitchen_id = k.id and pl.order_date >= w0)) v), '[]'::json),
    'riders', coalesce((select json_agg(r) from (
        select rd.name, count(*)::int as deliveries,
               round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*), 0))::int as on_time
        from pl join riders rd on rd.id = pl.rider_id where pl.order_date >= w0 and pl.delivered_at is not null group by rd.name order by 2 desc) r), '[]'::json)
  ));
end $function$;


CREATE OR REPLACE FUNCTION public.housekeeping()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s settings;
begin
  select * into s from settings where id = 1;

  -- Vendors who didn't confirm in time: confirmed payments come back to the wallet (account holders) or by MoMo (guests)
  with expired as (
    update pools set status = 'cancelled'
    where status = 'waiting' and now() >= wait_deadline(created_at, order_date)
    returning id)
  update orders o set status = 'cancelled', cancel_reason = 'The seller did not confirm in time',
                      refund_due = case when o.status in ('paid', 'collected') then greatest(0, order_total(o) - o.wallet_used) else 0 end,
                      refund_needed = (o.momo_ref is not null and not (o.user_id is not null and o.status in ('paid', 'collected')))
  from expired e where o.pool_id = e.id and o.status <> 'cancelled';

  -- Payment never found by the time orders close: cancelled; anything that did arrive (short payment) goes back
  update orders set status = 'cancelled', cancel_reason = 'Payment not received',
                    refund_due = coalesce(amount_received, 0),
                    refund_needed = coalesce(amount_received, 0) > 0 and user_id is null
  where status = 'pending' and pay_issue is not null and (now() at time zone 'utc') >= order_date + s.cutoff;

  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.refund_due, 'Money back: payment was short, code ' || o.code, o.id
  from orders o
  where o.status = 'cancelled' and o.cancel_reason = 'Payment not received' and o.refund_due > 0 and o.user_id is not null and not o.refund_needed
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.reason like 'Money back:%');

  -- Wallet part of any cancelled order goes back to the wallet
  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.wallet_used, 'Refund: ' || coalesce(o.cancel_reason, 'order cancelled'), o.id
  from orders o
  where o.status = 'cancelled' and o.wallet_used > 0 and o.user_id is not null
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.amount > 0 and w.reason like 'Refund:%');

  -- MoMo part of a confirmed payment, for account holders, once (never when ChopPool refunds the MoMo instead)
  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.refund_due, 'Money back: the vendor didn''t confirm, code ' || o.code, o.id
  from orders o
  where o.status = 'cancelled' and o.refund_due > 0 and o.user_id is not null and not o.refund_needed
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.reason like 'Money back:%');

  update orders set status = 'cancelled', cancel_reason = 'Special request not paid before cut-off'
  where status in ('quote_requested', 'quoted')
    and (now() at time zone 'utc') >= order_date + s.cutoff;

  -- Special orders: the seller must price in time, and the customer must pay inside the payment window
  update orders o set status = 'cancelled', cancel_reason = 'The seller didn''t price your request in time'
   where o.status = 'quote_requested' and (now() at time zone 'utc') >= o.order_date + s.cutoff - make_interval(mins => s.quote_pay_min);
  update orders set status = 'cancelled', cancel_reason = 'Special request not paid in time'
   where status = 'quoted' and quote_pay_by is not null and now() > quote_pay_by + interval '30 seconds';

  -- "Got my food" confirms itself a while after handover, unless a problem was reported
  update orders set received_at = now()
   where parent_id is null and status = 'collected' and received_at is null and problem is null
     and collected_at is not null and collected_at + make_interval(mins => s.auto_receive_min) <= now();

  -- Cashback: posted once, as a fixed wallet line, when the order is received (or its pool was delivered a while ago).
  -- Orders from before the ledger started keep the old timing (after cut-off) so no balance changes.
  with e as (
    select o.id, o.user_id, o.code, order_cashback(o.id) as cb
      from orders o join pools p on p.id = o.pool_id
     where o.parent_id is null and o.user_id is not null and not o.cashback_posted
       and o.status in ('paid', 'collected') and p.status <> 'cancelled'
       and (o.problem is null or o.problem_resolved_at is not null)
       and ((s.cashback_ledger_from is not null and o.created_at < s.cashback_ledger_from and (now() at time zone 'utc') >= o.order_date + s.cutoff)
            or o.received_at is not null
            or (p.status = 'delivered' and p.delivered_at is not null and p.delivered_at + make_interval(mins => s.auto_receive_min) <= now()))
     for update of o skip locked),
  ins as (
    insert into wallet_entries (user_id, amount, reason, order_id)
    select e.user_id, e.cb, 'Delivery cashback, code ' || e.code, e.id from e where e.cb > 0
      and not exists (select 1 from wallet_entries w where w.order_id = e.id and w.reason like 'Delivery cashback%')
    returning 1)
  update orders set cashback_posted = true where id in (select id from e);
end $function$;

-- Old 11-column my_orders result shape is replaced above; refresh grants
revoke execute on function wallet_balance(uuid) from public, anon, authenticated;
revoke execute on function fee_for(integer) from public, anon, authenticated;
revoke execute on function fee_for(integer, numeric) from public, anon, authenticated;
revoke execute on function pool_trip(uuid) from public, anon, authenticated;

-- Keep alert subscriptions small: forget order IDs older than two days
create or replace function prune_push_subs() returns void language sql security definer set search_path = public as $$
  update push_subs ps set order_ids = coalesce((select array_agg(x) from unnest(ps.order_ids) x join orders o on o.id = x
                                                 where o.order_date >= (now() at time zone 'utc')::date - 2), '{}')
   where cardinality(ps.order_ids) > 0;
$$;
revoke execute on function prune_push_subs() from public, anon, authenticated;

-- Owner-only settings now also include the team screen timeout
create or replace function settings_owner_guard() returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') and not is_super()
     and (new.vendor_fee_rate is distinct from old.vendor_fee_rate or new.vendor_fee_free is distinct from old.vendor_fee_free
          or new.admin_idle_min is distinct from old.admin_idle_min) then
    raise exception 'Only the owner can change this setting.';
  end if;
  return new;
end $$;

-- Handover of an unpaid order needs a choice (Collect cash / Hold the meal)
drop function if exists collect_code(text, text, date, uuid);
CREATE OR REPLACE FUNCTION public.collect_code(p_token text, p_code text, p_date date, p_pool uuid DEFAULT NULL::uuid, p_unpaid text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v text := norm_code(p_code); n int; v_done int; who text; v_ids uuid[]; v_name text; v_items text; v_qty int; v_paid boolean;
begin
  select count(*), count(*) filter (where o2.status = 'collected'),
         array_agg(o2.id order by o2.created_at) filter (where o2.status <> 'collected'),
         (array_agg(o2.customer_name order by o2.created_at))[1],
         string_agg(o2.qty || ' × ' || o2.item_name, ' + ' order by o2.created_at) filter (where o2.status <> 'collected'),
         sum(o2.qty) filter (where o2.status <> 'collected'),
         bool_and(o2.status in ('paid', 'collected'))
    into n, v_done, v_ids, v_name, v_items, v_qty, v_paid
    from orders o2
    join pools p on p.id = o2.pool_id
    left join riders r on r.id = p.rider_id
    join sites si on si.id = o2.site_id
    join kitchens k on k.id = o2.kitchen_id
   where o2.order_date = p_date and o2.code = v and o2.status in ('pending', 'paid', 'collected')
     and (p_pool is null or o2.pool_id = p_pool)
     and (r.token = p_token or si.host_token = p_token or (k.token = p_token and (k.delivery_mode = 'runner' or pool_free(p.id))));
  if n = 0 then raise exception 'No order with code % for you today.', coalesce(nullif(v, ''), p_code); end if;
  if v_done = n then raise exception 'Code % was already collected.', v; end if;
  -- Not paid yet: the person handing over chooses "Collect cash" or "Hold the meal" first
  if not v_paid and coalesce(p_unpaid, '') <> 'cash' then
    raise exception 'UNPAID:%:%', v_name, coalesce((select sum(order_total(o3) - o3.wallet_used - coalesce(o3.carried_amount, 0)) from orders o3 where o3.id = any(v_ids) and o3.status = 'pending'), 0);
  end if;
  who := case when exists (select 1 from riders where token = p_token) then 'rider'
              when exists (select 1 from kitchens where token = p_token) then 'runner' else 'host' end;
  update orders set status = 'collected', collected_at = now(), collected_by = who || case when p_unpaid = 'cash' and not v_paid then ' (cash)' else '' end where id = any(v_ids);
  return json_build_object('name', v_name, 'items', v_items, 'item_name', v_items, 'qty', v_qty, 'was_paid', v_paid, 'code', v);
end $function$;


-- ---------- from update21 ----------
-- ============================================================
-- ChopPool update 21 (Release C: name privacy, dish photo approval). Safe to run more than once.
-- ============================================================

-- Name in pools: a customer can hide their first name from other customers (riders and hosts still see it)
alter table orders add column if not exists hide_name boolean not null default false;
create or replace function set_name_privacy(p_ids uuid[], p_hide boolean) returns void language sql security definer set search_path = public as $$
  update orders set hide_name = coalesce(p_hide, false)
   where (id = any(p_ids) and (user_id is null or user_id = auth.uid())) or (auth.uid() is not null and user_id = auth.uid());
$$;
create or replace view public_reviews as
select r.id, r.kitchen_id, r.rating, r.comment, r.photo_url, r.created_at,
       case when o.hide_name then null else split_part(trim(o.customer_name), ' ', 1) end as name, o.item_name
  from reviews r join orders o on o.id = r.order_id
 where not r.hidden;
revoke insert, update, delete, truncate, references, trigger on public_reviews from anon, authenticated, public;
grant select on public_reviews to anon, authenticated;

-- Dish photos: shown to customers only once the team approves them
alter table menu_items add column if not exists photo_status text not null default 'approved';   -- existing photos stay as they are
create or replace function photo_pending_guard() returns trigger language plpgsql set search_path = public as $$
begin
  -- A new or changed photo from a seller link waits for approval; the team's own uploads are approved straight away
  if new.photo_url is distinct from old.photo_url and new.photo_url is not null then
    new.photo_status := case when current_setting('role', true) = 'authenticated' and is_admin() then 'approved' else 'pending' end;
  end if;
  return new;
end $$;
drop trigger if exists photo_pending_guard on menu_items;
create trigger photo_pending_guard before update on menu_items for each row execute function photo_pending_guard();

-- Weekly report: cashback already in wallets vs still waiting for the customer to get their lunch
CREATE OR REPLACE FUNCTION public.admin_weekly_report(p_week_start date)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s settings; w0 date := p_week_start; w1 date := p_week_start + 6; v0 date := p_week_start - 7; v1 date := p_week_start - 1;
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  select * into s from settings where id = 1;
  return (
  with o as (select o.*, p.status as pool_status from orders o join pools p on p.id = o.pool_id where o.order_date between v0 and w1),
  live as (select * from o where status in ('paid', 'collected', 'pending')),
  cur as (select * from live where order_date between w0 and w1),
  prev as (select * from live where order_date between v0 and v1),
  pl as (select p.*, pool_meals(p.id) as meals from pools p where p.order_date between v0 and w1),
  firsts as (select phone, min(order_date) as first_day from orders where status in ('paid', 'collected', 'pending') group by phone),
  head as (
    select wk, sum(qty)::int as meals, count(*) filter (where parent_id is null)::int as orders, count(distinct phone)::int as customers,
           count(distinct phone) filter (where (select first_day from firsts f where f.phone = x.phone) >= x.ws)::int as new_customers
    from (select *, 'cur' as wk, w0 as ws from cur union all select *, 'prev', v0 from prev) x group by wk),
  rep as (
    select wk, round(100.0 * count(*) filter (where n >= 2) / nullif(count(*), 0))::int as repeat_rate
    from (select 'cur' as wk, phone, count(distinct order_date) as n from live where order_date between w0 - 7 and w1 and phone in (select phone from cur) group by phone
          union all select 'prev', phone, count(distinct order_date) from live where order_date between v0 - 7 and v1 and phone in (select phone from prev) group by phone) r group by wk),
  pools_w as (
    select case when order_date >= w0 then 'cur' else 'prev' end as wk, round(avg(meals), 1) as avg_meals,
           count(*) filter (where meals >= s.max_meals)::int as filled, count(*)::int as pools
    from pl where status <> 'cancelled' and meals > 0 group by 1),
  canc as (select case when order_date >= w0 then 'cur' else 'prev' end as wk, count(*)::int as n from o where status = 'cancelled' group by 1)
  select json_build_object(
    'week_start', w0, 'week_end', w1,
    'headline', (select json_object_agg(h.wk, json_build_object('meals', h.meals, 'orders', h.orders, 'customers', h.customers, 'new_customers', h.new_customers,
                    'repeat_rate', (select repeat_rate from rep where rep.wk = h.wk), 'avg_meals', (select avg_meals from pools_w where pools_w.wk = h.wk),
                    'pools', (select pools from pools_w where pools_w.wk = h.wk), 'filled', (select filled from pools_w where pools_w.wk = h.wk),
                    'cancelled', coalesce((select n from canc where canc.wk = h.wk), 0))) from head h),
    'money', case when is_super() then (select json_build_object(
        'food', round(coalesce(sum((coalesce(quote_price, unit_price) + addons_total) * qty), 0), 2),
        'trip_estimate', round(coalesce((select sum(pool_trip(p2.id)) from pools p2 where p2.order_date between w0 and w1 and p2.status = 'delivered'), 0), 2),
        'trip_paid', round(coalesce((select sum(p2.trip_cost) from pools p2 where p2.order_date between w0 and w1 and p2.status = 'delivered'), 0), 2),
        'commission', round(coalesce((select sum(pool_fee(p2.id)) from pools p2 where p2.order_date between w0 and w1 and p2.status <> 'cancelled'), 0), 2),
        'service_fees', round(coalesce(sum(service_fee * case when fee_per_meal then qty else 1 end), 0), 2),
        'cashback', round(coalesce(sum(case when parent_id is null and status in ('paid', 'collected') and not (parent_id is null and status in ('paid', 'collected') and not cashback_posted and created_at >= coalesce(s.cashback_ledger_from, '-infinity'::timestamptz)) then order_cashback(id) else 0 end), 0), 2),
        'cashback_pending', round(coalesce(sum(case when parent_id is null and status in ('paid', 'collected') and not cashback_posted and created_at >= coalesce(s.cashback_ledger_from, '-infinity'::timestamptz) then order_cashback(id) else 0 end), 0), 2),
        'refunds', round(coalesce((select sum(amount) from wallet_entries where amount > 0 and reason like 'Refund%' and created_at::date between w0 and w1 + 2), 0), 2),
        'momo_refunds', (select count(*) from orders where refund_needed and order_date between w0 and w1),
        'wallets_owed', round(coalesce((select sum(wallet_balance(u)) from (select distinct user_id as u from orders where user_id is not null union select distinct user_id from wallet_entries) us), 0), 2))
      from cur) end,
    'buildings', coalesce((select json_agg(b order by b.meals desc) from (
        select si.name, sum(c.qty)::int as meals, count(distinct c.pool_id)::int as pools,
               round(sum(c.qty)::numeric / nullif(count(distinct c.pool_id), 0), 1) as avg_pool,
               coalesce((select sum(qty) from prev where prev.site_id = si.id), 0)::int as prev_meals
        from cur c join sites si on si.id = c.site_id group by si.id, si.name order by 2 desc limit 15) b), '[]'::json),
    'quiet', coalesce((select json_agg(q) from (
        select si.name, sum(p.qty)::int as prev_meals from prev p join sites si on si.id = p.site_id
        where not exists (select 1 from cur c where c.site_id = p.site_id) group by si.name order by 2 desc) q), '[]'::json),
    'customers', coalesce((select json_agg(c2) from (
        select (array_agg(customer_name order by created_at desc))[1] as name,
               (select si.name from cur c3 join sites si on si.id = c3.site_id where c3.phone = c.phone group by si.name order by count(*) desc limit 1) as building,
               case when is_super() then c.phone end as phone,
               count(*) filter (where parent_id is null)::int as orders, sum(qty)::int as meals
        from cur c group by c.phone order by sum(qty) desc, count(*) desc limit 15) c2), '[]'::json),
    'vendors', coalesce((select json_agg(v order by v.meals desc) from (
        select k.public_name as name, coalesce(sum(c.qty), 0)::int as meals,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status <> 'cancelled' and pl.meals > 0)::int as pools,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status = 'cancelled'
                  and exists (select 1 from orders x where x.pool_id = pl.id and x.cancel_reason = 'The seller did not confirm in time'))::int as expired,
               (select round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*) filter (where pl.delivered_at is not null), 0))
                  from pl where pl.kitchen_id = k.id and pl.order_date >= w0)::int as on_time,
               (select count(*) from o where o.kitchen_id = k.id and o.order_date >= w0 and o.cancel_reason like 'The seller can''t%')::int as declined,
               (select count(*) from (select phone from live where live.kitchen_id = k.id and live.order_date between w0 - 28 and w1 group by phone having count(distinct order_date) >= 2) r)::int as repeat_customers,
               cardinality(k.auto_days) > 0 as always_cooking,
               (select round(avg(r.rating), 1) from reviews r where r.kitchen_id = k.id and not r.hidden and r.created_at::date between w0 and w1 + 2) as rating
        from kitchens k left join cur c on c.kitchen_id = k.id where k.active
        group by k.id, k.public_name, k.auto_days having coalesce(sum(c.qty), 0) > 0
           or exists (select 1 from pl where pl.kitchen_id = k.id and pl.order_date >= w0)) v), '[]'::json),
    'riders', coalesce((select json_agg(r) from (
        select rd.name, count(*)::int as deliveries,
               round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*), 0))::int as on_time
        from pl join riders rd on rd.id = pl.rider_id where pl.order_date >= w0 and pl.delivered_at is not null group by rd.name order by 2 desc) r), '[]'::json)
  ));
end $function$;

-- Security Advisor: pin the search path on helper and guard functions
alter function public.dist_m(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision) set search_path = public;
alter function public.order_total(o orders) set search_path = public;
alter function public.norm_code(p text) set search_path = public;
alter function public.orders_coordinator_guard() set search_path = public;
alter function public.quote_window_guard() set search_path = public;
alter function public.settings_owner_guard() set search_path = public;
alter function public.step_rank(p text) set search_path = public;

-- ---------- from update22 ----------
-- ============================================================
-- ChopPool update 22 (rider taps Delivered; customer confirms Got my food; auto after 2 hours). Safe to run more than once.
-- ============================================================

-- "Got my food" works as soon as the rider has marked the pool Delivered, whether or not the code was checked.
-- It also counts as the handover, so the pool can finish.
create or replace function confirm_received(p_order uuid) returns void language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  select * into o from orders where id = p_order and parent_id is null and (user_id is null or user_id = auth.uid());
  if not found then raise exception 'Order not found.'; end if;
  if o.status not in ('paid', 'collected') then raise exception 'This order can''t be confirmed.'; end if;
  if o.status = 'paid' and not exists (select 1 from pools p where p.id = o.pool_id and p.status = 'delivered') then
    raise exception 'Your lunch hasn''t been delivered yet.';
  end if;
  update orders set received_at = coalesce(received_at, now()), status = 'collected',
         collected_at = coalesce(collected_at, now()), collected_by = coalesce(collected_by, 'customer')
   where id = o.id;
  update orders set status = 'collected', collected_at = coalesce(collected_at, now()), collected_by = coalesce(collected_by, 'with main order')
   where parent_id = o.id and status = 'paid';
  perform housekeeping();
end $$;

CREATE OR REPLACE FUNCTION public.housekeeping()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s settings;
begin
  select * into s from settings where id = 1;

  -- Vendors who didn't confirm in time: confirmed payments come back to the wallet (account holders) or by MoMo (guests)
  with expired as (
    update pools set status = 'cancelled'
    where status = 'waiting' and now() >= wait_deadline(created_at, order_date)
    returning id)
  update orders o set status = 'cancelled', cancel_reason = 'The seller did not confirm in time',
                      refund_due = case when o.status in ('paid', 'collected') then greatest(0, order_total(o) - o.wallet_used) else 0 end,
                      refund_needed = (o.momo_ref is not null and not (o.user_id is not null and o.status in ('paid', 'collected')))
  from expired e where o.pool_id = e.id and o.status <> 'cancelled';

  -- Payment never found by the time orders close: cancelled; anything that did arrive (short payment) goes back
  update orders set status = 'cancelled', cancel_reason = 'Payment not received',
                    refund_due = coalesce(amount_received, 0),
                    refund_needed = coalesce(amount_received, 0) > 0 and user_id is null
  where status = 'pending' and pay_issue is not null and (now() at time zone 'utc') >= order_date + s.cutoff;

  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.refund_due, 'Money back: payment was short, code ' || o.code, o.id
  from orders o
  where o.status = 'cancelled' and o.cancel_reason = 'Payment not received' and o.refund_due > 0 and o.user_id is not null and not o.refund_needed
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.reason like 'Money back:%');

  -- Wallet part of any cancelled order goes back to the wallet
  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.wallet_used, 'Refund: ' || coalesce(o.cancel_reason, 'order cancelled'), o.id
  from orders o
  where o.status = 'cancelled' and o.wallet_used > 0 and o.user_id is not null
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.amount > 0 and w.reason like 'Refund:%');

  -- MoMo part of a confirmed payment, for account holders, once (never when ChopPool refunds the MoMo instead)
  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.refund_due, 'Money back: the vendor didn''t confirm, code ' || o.code, o.id
  from orders o
  where o.status = 'cancelled' and o.refund_due > 0 and o.user_id is not null and not o.refund_needed
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.reason like 'Money back:%');

  update orders set status = 'cancelled', cancel_reason = 'Special request not paid before cut-off'
  where status in ('quote_requested', 'quoted')
    and (now() at time zone 'utc') >= order_date + s.cutoff;

  -- Special orders: the seller must price in time, and the customer must pay inside the payment window
  update orders o set status = 'cancelled', cancel_reason = 'The seller didn''t price your request in time'
   where o.status = 'quote_requested' and (now() at time zone 'utc') >= o.order_date + s.cutoff - make_interval(mins => s.quote_pay_min);
  update orders set status = 'cancelled', cancel_reason = 'Special request not paid in time'
   where status = 'quoted' and quote_pay_by is not null and now() > quote_pay_by + interval '30 seconds';

  -- "Got my food" confirms itself a while after handover, unless a problem was reported
  -- Counted from when the rider marks the pool Delivered (or from the code check, whichever came first)
  update orders o set received_at = now(), status = 'collected', collected_at = coalesce(o.collected_at, now()), collected_by = coalesce(o.collected_by, 'auto')
    from pools p
   where p.id = o.pool_id and o.parent_id is null and o.status in ('paid', 'collected') and o.received_at is null and o.problem is null
     and ((p.status = 'delivered' and p.delivered_at is not null and p.delivered_at + make_interval(mins => s.auto_receive_min) <= now())
          or (o.collected_at is not null and o.collected_at + make_interval(mins => s.auto_receive_min) <= now()));
  -- Extra plates in the same bag follow their main order
  update orders c set status = 'collected', collected_at = coalesce(c.collected_at, now()), collected_by = coalesce(c.collected_by, 'with main order')
    from orders m
   where c.parent_id = m.id and c.status = 'paid' and m.received_at is not null;

  -- Cashback: posted once, as a fixed wallet line, when the order is received (or its pool was delivered a while ago).
  -- Orders from before the ledger started keep the old timing (after cut-off) so no balance changes.
  with e as (
    select o.id, o.user_id, o.code, order_cashback(o.id) as cb
      from orders o join pools p on p.id = o.pool_id
     where o.parent_id is null and o.user_id is not null and not o.cashback_posted
       and o.status in ('paid', 'collected') and p.status <> 'cancelled'
       and (o.problem is null or o.problem_resolved_at is not null)
       and ((s.cashback_ledger_from is not null and o.created_at < s.cashback_ledger_from and (now() at time zone 'utc') >= o.order_date + s.cutoff)
            or o.received_at is not null
            or (p.status = 'delivered' and p.delivered_at is not null and p.delivered_at + make_interval(mins => s.auto_receive_min) <= now()))
     for update of o skip locked),
  ins as (
    insert into wallet_entries (user_id, amount, reason, order_id)
    select e.user_id, e.cb, 'Delivery cashback, code ' || e.code, e.id from e where e.cb > 0
      and not exists (select 1 from wallet_entries w where w.order_id = e.id and w.reason like 'Delivery cashback%')
    returning 1)
  update orders set cashback_posted = true where id in (select id from e);
end $function$;

-- ---------- from update23 ----------
-- ============================================================
-- ChopPool update 23 (tray checkout, vendor confirm window, payer number). Safe to run more than once.
-- ============================================================

-- Vendor confirm window. Orders for a later day: until the confirm-by time that morning (8:30).
-- Same-day orders placed before 8:30: also until 8:30. After that: the usual minutes, never past the order cut-off.
create or replace function wait_deadline(p_created timestamptz, p_date date) returns timestamptz
language sql stable security definer set search_path = public as $$
  select case when p_date > (p_created at time zone 'utc')::date
              then (p_date + least(s.next_day_confirm_by, s.cutoff)) at time zone 'utc'
              else least((p_date + s.cutoff) at time zone 'utc',
                         greatest(p_created + make_interval(mins => s.accept_timeout_min),
                                  (p_date + least(s.next_day_confirm_by, s.cutoff)) at time zone 'utc')) end
  from settings s where s.id = 1;
$$;
revoke execute on function wait_deadline(timestamptz, date) from public, anon, authenticated;

-- Tray orders: extra dishes paid together with the first one (one payment, one code)
alter table orders add column if not exists basket boolean not null default false;
-- The mobile money number the customer paid from (refunds go back there)
alter table orders add column if not exists payer_phone text;
alter table orders add column if not exists payer_network text;
-- Saved payment methods (up to 3 mobile money numbers, one default), so they follow the account to any phone
alter table profiles add column if not exists pay_methods jsonb not null default '[]'::jsonb;

-- Several dishes from one vendor, one payment. Lines: [{item, qty, addons[], note}]
create or replace function place_basket(p_site uuid, p_lines jsonb, p_name text, p_phone text, p_ref text,
                                        p_use_wallet boolean default false, p_payer_phone text default null, p_payer_network text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  ln jsonb; n int := 0; r json; v_main uuid; v_code text; v_ids uuid[] := '{}'; v_total numeric := 0; v_use numeric := 0; v_left numeric;
  v_uid uuid := auth.uid(); o record; v_part numeric; v_meals int := 0; v_kitchen uuid; v_pp text := regexp_replace(coalesce(p_payer_phone, ''), '\D', '', 'g');
  s settings;
begin
  select * into s from settings where id = 1;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Your tray is empty.'; end if;
  if jsonb_array_length(p_lines) > 8 then raise exception 'Up to 8 different dishes in one order.'; end if;
  select coalesce(sum(greatest(1, coalesce((x ->> 'qty')::int, 1))), 0) into v_meals from jsonb_array_elements(p_lines) x;
  if v_meals > least(10, s.max_meals) then raise exception 'Up to % meals in one order.', least(10, s.max_meals); end if;
  if (select count(distinct m.kitchen_id) from jsonb_array_elements(p_lines) x join menu_items m on m.id = (x ->> 'item')::uuid) > 1 then
    raise exception 'Order from one vendor at a time.';
  end if;
  if v_pp <> '' and v_pp !~ '^0\d{9}$' then raise exception 'Enter the 10-digit mobile money number you paid from.'; end if;

  for ln in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    r := place_order(p_site, (ln ->> 'item')::uuid, greatest(1, coalesce((ln ->> 'qty')::int, 1)), p_name, p_phone, 'BASKET',
                     coalesce((select array_agg(a) from jsonb_array_elements_text(coalesce(ln -> 'addons', '[]'::jsonb)) a), '{}'),
                     ln ->> 'note', null, false, v_main);
    if n = 1 then v_main := (r ->> 'id')::uuid; v_code := r ->> 'code'; end if;
    v_ids := v_ids || (r ->> 'id')::uuid;
  end loop;

  -- One payment for everything under this code: wallet first, the rest by mobile money
  update orders set momo_ref = null, status = 'pending', basket = (id <> v_main),
         payer_phone = nullif(v_pp, ''), payer_network = nullif(trim(coalesce(p_payer_network, '')), '')
   where id = any(v_ids);
  select coalesce(sum(order_total(x)), 0) into v_total from orders x where x.id = any(v_ids);
  if p_use_wallet and v_uid is not null and exists (select 1 from orders where id = v_main and user_id = v_uid) then
    v_use := greatest(0, least(wallet_balance(v_uid), v_total));
    if v_use > 0 then
      insert into wallet_entries (user_id, amount, reason, order_id) values (v_uid, -v_use, 'Paid for order ' || v_code, v_main);
    end if;
  end if;
  if v_use < v_total and (p_ref is null or char_length(trim(p_ref)) < 4) then
    raise exception 'Enter the mobile money transaction ID for the remaining %.', to_char(v_total - v_use, 'FM999990.00');
  end if;
  -- Spread the wallet part across the dishes (first dish first) so refunds stay exact
  v_left := v_use;
  for o in select x.id, order_total(x) as t from orders x where x.id = any(v_ids) order by (x.id <> v_main), x.created_at loop
    v_part := least(v_left, o.t); v_left := v_left - v_part;
    update orders set wallet_used = v_part,
           status = case when v_part >= o.t then 'paid' else 'pending' end,
           momo_ref = case when o.id = v_main and v_use < v_total then trim(p_ref) else null end
     where id = o.id;
  end loop;
  return json_build_object('id', v_main, 'code', v_code, 'ids', v_ids, 'total', v_total, 'wallet_used', v_use, 'momo_due', v_total - v_use,
                           'status', (select status from orders where id = v_main), 'order_date', (select order_date from orders where id = v_main));
end $$;
grant execute on function place_basket(uuid, jsonb, text, text, text, boolean, text, text) to anon, authenticated;

-- Tray dishes follow the first dish: paid together, cancelled together if the payment never arrives
create or replace function basket_follow() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.parent_id is null and new.status is distinct from old.status then
    if new.status = 'paid' and old.status = 'pending' then
      update orders set status = 'paid' where parent_id = new.id and basket and status = 'pending';
    elsif new.status = 'cancelled' and new.cancel_reason = 'Payment not received' then
      update orders set status = 'cancelled', cancel_reason = 'Payment not received', refund_due = 0, refund_needed = false
       where parent_id = new.id and basket and status = 'pending';
    end if;
  end if;
  return null;
end $$;
drop trigger if exists basket_follow on orders;
create trigger basket_follow after update of status on orders for each row execute function basket_follow();

-- Cancel reasons: room for the customer's own words ("Other: ...")
create or replace function cancel_order(p_order uuid, p_reason text, p_refund text default 'wallet')
returns json language plpgsql security definer set search_path = public as $$
declare o orders; s settings; v_total numeric; v_momo numeric; v_credit numeric := 0; v_to text; c record; r json;
        v_wallet numeric := 0; v_momo_all numeric := 0;
begin
  select * into s from settings where id = 1;
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'Order not found.'; end if;
  if o.user_id is not null and o.user_id is distinct from auth.uid() then raise exception 'Sign in with the account that placed this order.'; end if;
  if o.status not in ('pending', 'paid', 'quote_requested', 'quoted') then raise exception 'This order can no longer be cancelled.'; end if;
  if (now() at time zone 'utc') >= o.order_date + s.cutoff then
    raise exception 'Orders close at %. The kitchen is already cooking, so it can''t be cancelled now.', to_char(s.cutoff, 'HH24:MI');
  end if;

  v_total := order_total(o);
  v_momo := greatest(0, v_total - o.wallet_used);

  if o.status in ('quote_requested', 'quoted') then
    v_to := 'nothing';
  elsif o.status = 'paid' and v_momo > 0 and o.user_id is not null and coalesce(p_refund, 'wallet') = 'wallet' then
    v_credit := v_momo; v_to := 'wallet';
  elsif v_momo > 0 then
    v_to := 'momo';
  else
    v_to := 'wallet';
  end if;
  v_credit := v_credit + o.wallet_used;

  update orders set status = 'cancelled',
         cancel_reason = 'You cancelled' || coalesce(' (' || nullif(left(trim(p_reason), 200), '') || ')', ''),
         refund_needed = (v_to = 'momo')
  where id = o.id;

  if v_credit > 0 and o.user_id is not null then
    insert into wallet_entries (user_id, amount, reason, order_id)
    values (o.user_id, v_credit, 'Refund: cancelled order ' || o.code, o.id);
  end if;
  v_wallet := case when o.user_id is not null then v_credit else 0 end;
  v_momo_all := case when v_to = 'momo' then v_momo else 0 end;

  -- Cancelling the main order cancels the plates added under its code
  for c in select id from orders where parent_id = o.id and status in ('pending', 'paid') loop
    r := cancel_order(c.id, p_reason, p_refund);
    v_wallet := v_wallet + coalesce((r ->> 'wallet_credit')::numeric, 0);
    v_momo_all := v_momo_all + coalesce((r ->> 'momo')::numeric, 0);
    if (r ->> 'refund') = 'momo' then v_to := 'momo'; end if;
  end loop;

  update pools set status = 'cancelled' where id = o.pool_id and status = 'waiting' and pool_meals(id) = 0;

  return json_build_object('refund', v_to, 'wallet_credit', v_wallet, 'momo', v_momo_all);
end $$;


-- Say mobile money, not MoMo (MTN's brand), in messages customers see
create or replace function settle_payment(p_order uuid, p_ref text, p_use_wallet boolean)
returns json language plpgsql security definer set search_path = public as $$
declare o orders; v_total numeric; v_bal numeric; v_use numeric := 0; v_uid uuid := auth.uid();
begin
  select * into o from orders where id = p_order;
  v_total := order_total(o);
  if p_use_wallet and v_uid is not null and o.user_id = v_uid then
    v_bal := wallet_balance(v_uid);
    v_use := greatest(0, least(v_bal, v_total));
    if v_use > 0 then
      insert into wallet_entries (user_id, amount, reason, order_id) values (v_uid, -v_use, 'Paid for order ' || o.code, o.id);
    end if;
  end if;
  if v_use < v_total and (p_ref is null or char_length(trim(p_ref)) < 4) then
    raise exception 'Enter the mobile money transaction ID for the remaining %.', to_char(v_total - v_use, 'FM999990.00');
  end if;
  update orders set wallet_used = wallet_used + v_use,
    momo_ref = case when v_use < v_total then trim(p_ref) else momo_ref end,
    status = case when v_use >= v_total then 'paid' else 'pending' end
  where id = o.id;
  return json_build_object('total', v_total, 'wallet_used', v_use, 'momo_due', v_total - v_use);
end $$;

create or replace function fix_payment(p_order uuid, p_phone text, p_ref text)
returns json language plpgsql security definer set search_path = public as $$
declare o orders; s settings; v_ref text := upper(regexp_replace(coalesce(p_ref, ''), '\s', '', 'g'));
begin
  select * into o from orders where id = p_order;
  if not found then raise exception 'Order not found.'; end if;
  if not ((auth.uid() is not null and o.user_id = auth.uid())
          or regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') = regexp_replace(coalesce(o.phone, ''), '\D', '', 'g')) then
    raise exception 'This order isn''t yours.';
  end if;
  if o.status <> 'pending' or o.pay_issue is null then raise exception 'This payment doesn''t need fixing.'; end if;
  select * into s from settings where id = 1;
  if (now() at time zone 'utc') >= o.order_date + s.cutoff then raise exception 'Orders have closed for this day.'; end if;
  if v_ref !~ '^[A-Z0-9.]{6,30}$' then raise exception 'Enter the mobile money transaction ID from your payment message.'; end if;
  update orders set momo_ref = case when o.pay_issue = 'short' and o.momo_ref is not null then left(o.momo_ref || ' + ' || v_ref, 120) else v_ref end,
                    pay_issue = null
  where id = o.id;
  return json_build_object('ok', true);
end $$;

-- Admin: which of these orders can get a phone alert (the customer turned alerts on for them)
create or replace function admin_alert_reach(p_ids uuid[]) returns uuid[]
language sql stable security definer set search_path = public as $$
  select case when not is_admin() then '{}'::uuid[] else coalesce(array_agg(o.id), '{}') end
  from orders o
  where o.id = any(p_ids)
    and exists (select 1 from push_subs ps where o.id = any(ps.order_ids) or (o.user_id is not null and ps.user_id = o.user_id));
$$;
grant execute on function admin_alert_reach(uuid[]) to authenticated;

select 1;

-- ---------- from update24 ----------
-- ChopPool update 24
-- Tray checkout: when the wallet covers only part of the total, every dish stays waiting for the
-- mobile money check (before, the first dish could show as paid on its own).
-- Handing over a code moves the pool to Delivered if nobody tapped it.
-- Vendors can say "not cooking today" while customers wait (kitchen_skip_day); a paused day takes no orders.
create or replace function place_basket(p_site uuid, p_lines jsonb, p_name text, p_phone text, p_ref text,
                                        p_use_wallet boolean default false, p_payer_phone text default null, p_payer_network text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  ln jsonb; n int := 0; r json; v_main uuid; v_code text; v_ids uuid[] := '{}'; v_total numeric := 0; v_use numeric := 0; v_left numeric;
  v_uid uuid := auth.uid(); o record; v_part numeric; v_meals int := 0; v_kitchen uuid; v_pp text := regexp_replace(coalesce(p_payer_phone, ''), '\D', '', 'g');
  s settings;
begin
  select * into s from settings where id = 1;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Your tray is empty.'; end if;
  if jsonb_array_length(p_lines) > 8 then raise exception 'Up to 8 different dishes in one order.'; end if;
  select coalesce(sum(greatest(1, coalesce((x ->> 'qty')::int, 1))), 0) into v_meals from jsonb_array_elements(p_lines) x;
  if v_meals > least(10, s.max_meals) then raise exception 'Up to % meals in one order.', least(10, s.max_meals); end if;
  if (select count(distinct m.kitchen_id) from jsonb_array_elements(p_lines) x join menu_items m on m.id = (x ->> 'item')::uuid) > 1 then
    raise exception 'Order from one vendor at a time.';
  end if;
  if v_pp <> '' and v_pp !~ '^0\d{9}$' then raise exception 'Enter the 10-digit mobile money number you paid from.'; end if;

  for ln in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    r := place_order(p_site, (ln ->> 'item')::uuid, greatest(1, coalesce((ln ->> 'qty')::int, 1)), p_name, p_phone, 'BASKET',
                     coalesce((select array_agg(a) from jsonb_array_elements_text(coalesce(ln -> 'addons', '[]'::jsonb)) a), '{}'),
                     ln ->> 'note', null, false, v_main);
    if n = 1 then v_main := (r ->> 'id')::uuid; v_code := r ->> 'code'; end if;
    v_ids := v_ids || (r ->> 'id')::uuid;
  end loop;

  -- One payment for everything under this code: wallet first, the rest by mobile money
  update orders set momo_ref = null, status = 'pending', basket = (id <> v_main),
         payer_phone = nullif(v_pp, ''), payer_network = nullif(trim(coalesce(p_payer_network, '')), '')
   where id = any(v_ids);
  select coalesce(sum(order_total(x)), 0) into v_total from orders x where x.id = any(v_ids);
  if p_use_wallet and v_uid is not null and exists (select 1 from orders where id = v_main and user_id = v_uid) then
    v_use := greatest(0, least(wallet_balance(v_uid), v_total));
    if v_use > 0 then
      insert into wallet_entries (user_id, amount, reason, order_id) values (v_uid, -v_use, 'Paid for order ' || v_code, v_main);
    end if;
  end if;
  if v_use < v_total and (p_ref is null or char_length(trim(p_ref)) < 4) then
    raise exception 'Enter the mobile money transaction ID for the remaining %.', to_char(v_total - v_use, 'FM999990.00');
  end if;
  -- Spread the wallet part across the dishes (first dish first) so refunds stay exact
  v_left := v_use;
  for o in select x.id, order_total(x) as t from orders x where x.id = any(v_ids) order by (x.id <> v_main), x.created_at loop
    v_part := least(v_left, o.t); v_left := v_left - v_part;
    update orders set wallet_used = v_part,
           status = case when v_use >= v_total then 'paid' else 'pending' end,   -- one payment: all dishes paid together
           momo_ref = case when o.id = v_main and v_use < v_total then trim(p_ref) else null end
     where id = o.id;
  end loop;
  return json_build_object('id', v_main, 'code', v_code, 'ids', v_ids, 'total', v_total, 'wallet_used', v_use, 'momo_due', v_total - v_use,
                           'status', (select status from orders where id = v_main), 'order_date', (select order_date from orders where id = v_main));
end $$;

-- A code handed over at the drop point also marks the bag as delivered (the rider may have forgotten to tap it)
CREATE OR REPLACE FUNCTION public.collect_code(p_token text, p_code text, p_date date, p_pool uuid DEFAULT NULL::uuid, p_unpaid text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v text := norm_code(p_code); n int; v_done int; who text; v_ids uuid[]; v_name text; v_items text; v_qty int; v_paid boolean;
begin
  select count(*), count(*) filter (where o2.status = 'collected'),
         array_agg(o2.id order by o2.created_at) filter (where o2.status <> 'collected'),
         (array_agg(o2.customer_name order by o2.created_at))[1],
         string_agg(o2.qty || ' × ' || o2.item_name, ' + ' order by o2.created_at) filter (where o2.status <> 'collected'),
         sum(o2.qty) filter (where o2.status <> 'collected'),
         bool_and(o2.status in ('paid', 'collected'))
    into n, v_done, v_ids, v_name, v_items, v_qty, v_paid
    from orders o2
    join pools p on p.id = o2.pool_id
    left join riders r on r.id = p.rider_id
    join sites si on si.id = o2.site_id
    join kitchens k on k.id = o2.kitchen_id
   where o2.order_date = p_date and o2.code = v and o2.status in ('pending', 'paid', 'collected')
     and (p_pool is null or o2.pool_id = p_pool)
     and (r.token = p_token or si.host_token = p_token or (k.token = p_token and (k.delivery_mode = 'runner' or pool_free(p.id))));
  if n = 0 then raise exception 'No order with code % for you today.', coalesce(nullif(v, ''), p_code); end if;
  if v_done = n then raise exception 'Code % was already collected.', v; end if;
  -- Not paid yet: the person handing over chooses "Collect cash" or "Hold the meal" first
  if not v_paid and coalesce(p_unpaid, '') <> 'cash' then
    raise exception 'UNPAID:%:%', v_name, coalesce((select sum(order_total(o3) - o3.wallet_used - coalesce(o3.carried_amount, 0)) from orders o3 where o3.id = any(v_ids) and o3.status = 'pending'), 0);
  end if;
  who := case when exists (select 1 from riders where token = p_token) then 'rider'
              when exists (select 1 from kitchens where token = p_token) then 'runner' else 'host' end;
  update orders set status = 'collected', collected_at = now(), collected_by = who || case when p_unpaid = 'cash' and not v_paid then ' (cash)' else '' end where id = any(v_ids);
  -- A meal handed over means the bag is here: move the pool to Delivered if nobody tapped it yet
  update pools set status = 'delivered', delivered_at = coalesce(delivered_at, now())
   where id in (select pool_id from orders where id = any(v_ids)) and status in ('accepted', 'ready', 'picked_up', 'arriving');
  return json_build_object('name', v_name, 'items', v_items, 'item_name', v_items, 'qty', v_qty, 'was_paid', v_paid, 'code', v);
end $function$;

-- A vendor who can't cook can say so straight away, instead of customers waiting until the confirm time runs out.
-- Waiting pools are cancelled with the same money-back rules as a vendor who didn't confirm, and the day is paused.
create or replace function kitchen_skip_day(p_token text, p_date date)
returns json language plpgsql security definer set search_path = public as $$
declare k kitchens; v_pools uuid[]; v_n int := 0;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  if exists (select 1 from pools p where p.kitchen_id = k.id and p.order_date = p_date and p.status not in ('waiting', 'cancelled') and pool_meals(p.id) > 0) then
    raise exception 'You already confirmed this day and have orders. Message ChopPool if you can''t cook them.';
  end if;
  with gone as (
    update pools set status = 'cancelled' where kitchen_id = k.id and order_date = p_date and status = 'waiting' returning id)
  select coalesce(array_agg(id), '{}') into v_pools from gone;
  update orders o set status = 'cancelled', cancel_reason = 'The vendor isn''t cooking today',
                      refund_due = case when o.status in ('paid', 'collected') then greatest(0, order_total(o) - o.wallet_used) else 0 end,
                      refund_needed = (o.momo_ref is not null and not (o.user_id is not null and o.status in ('paid', 'collected')))
   where o.pool_id = any(v_pools) and o.status <> 'cancelled';
  get diagnostics v_n = row_count;
  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.wallet_used, 'Refund: the vendor isn''t cooking today', o.id from orders o
   where o.pool_id = any(v_pools) and o.status = 'cancelled' and o.wallet_used > 0 and o.user_id is not null
     and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.amount > 0 and w.reason like 'Refund:%');
  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.refund_due, 'Money back: the vendor isn''t cooking today, code ' || o.code, o.id from orders o
   where o.pool_id = any(v_pools) and o.status = 'cancelled' and o.refund_due > 0 and o.user_id is not null and not o.refund_needed
     and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.reason like 'Money back:%');
  update kitchens set paused_dates = array(select distinct x from unnest(paused_dates || p_date) x where x >= (now() at time zone 'utc')::date - 1) where id = k.id;
  delete from kitchen_days where kitchen_id = k.id and order_date = p_date;
  return json_build_object('orders', v_n, 'pools', coalesce(array_length(v_pools, 1), 0));
end $$;
revoke all on function kitchen_skip_day(text, date) from public;
grant execute on function kitchen_skip_day(text, date) to anon, authenticated;

-- A vendor who paused a day ("not cooking") can't receive orders for it, and the menu says so
create or replace function order_paused_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where id = new.kitchen_id;
  if found and new.order_date = any(k.paused_dates)
     and not exists (select 1 from kitchen_days where kitchen_id = k.id and order_date = new.order_date) then
    raise exception '% isn''t cooking %. Choose another vendor.', k.public_name,
      case when new.order_date = (now() at time zone 'utc')::date then 'today' else 'on that day' end;
  end if;
  return new;
end $$;
drop trigger if exists order_paused_guard on orders;
create trigger order_paused_guard before insert on orders for each row execute function order_paused_guard();

create or replace function board_data(p_date date) returns json
language plpgsql volatile security definer set search_path = public as $$
begin
  perform housekeeping();
  return json_build_object(
    'pools', coalesce((select json_agg(x) from (select p.id, p.order_date, p.site_id, p.kitchen_id, p.seq, p.status, p.created_at, pool_meals(p.id) as meals,
                                                       case when p.status = 'waiting' then wait_deadline(p.created_at, p.order_date) end as wait_until,
                                                       pool_free(p.id) as free
                                                  from pools p where p.order_date = p_date and p.status <> 'cancelled') x), '[]'::json),
    'load', coalesce((select json_object_agg(kitchen_id, meals) from (select kitchen_id, sum(qty)::int as meals from orders
                                                  where order_date = p_date and status <> 'cancelled' group by 1) l), '{}'::json),
    'activity', coalesce((select json_agg(a order by a.created_at desc) from (select * from recent_activity order by created_at desc limit 50) a), '[]'::json),
    'open', coalesce((select json_agg(k.id) from kitchens k where k.active and kitchen_is_open(k.id, p_date)), '[]'::json),
    'off', coalesce((select json_agg(k.id) from kitchens k where k.active and p_date = any(k.paused_dates)
                       and not exists (select 1 from kitchen_days d where d.kitchen_id = k.id and d.order_date = p_date)), '[]'::json));
end $$;

-- No cancelling once the vendor has confirmed the final batch (the app already hides the button)
create or replace function cancel_order(p_order uuid, p_reason text, p_refund text default 'wallet')
returns json language plpgsql security definer set search_path = public as $$
declare o orders; s settings; v_total numeric; v_momo numeric; v_credit numeric := 0; v_to text; c record; r json;
        v_wallet numeric := 0; v_momo_all numeric := 0;
begin
  select * into s from settings where id = 1;
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'Order not found.'; end if;
  if o.user_id is not null and o.user_id is distinct from auth.uid() then raise exception 'Sign in with the account that placed this order.'; end if;
  if o.status not in ('pending', 'paid', 'quote_requested', 'quoted') then raise exception 'This order can no longer be cancelled.'; end if;
  if exists (select 1 from pools p where p.id = o.pool_id and p.status not in ('waiting', 'collecting')) then
    raise exception 'The vendor is already cooking this order, so it can''t be cancelled now.';
  end if;
  if (now() at time zone 'utc') >= o.order_date + s.cutoff then
    raise exception 'Orders close at %. The kitchen is already cooking, so it can''t be cancelled now.', to_char(s.cutoff, 'HH24:MI');
  end if;

  v_total := order_total(o);
  v_momo := greatest(0, v_total - o.wallet_used);

  if o.status in ('quote_requested', 'quoted') then
    v_to := 'nothing';
  elsif o.status = 'paid' and v_momo > 0 and o.user_id is not null and coalesce(p_refund, 'wallet') = 'wallet' then
    v_credit := v_momo; v_to := 'wallet';
  elsif v_momo > 0 then
    v_to := 'momo';
  else
    v_to := 'wallet';
  end if;
  v_credit := v_credit + o.wallet_used;

  update orders set status = 'cancelled',
         cancel_reason = 'You cancelled' || coalesce(' (' || nullif(left(trim(p_reason), 200), '') || ')', ''),
         refund_needed = (v_to = 'momo')
  where id = o.id;

  if v_credit > 0 and o.user_id is not null then
    insert into wallet_entries (user_id, amount, reason, order_id)
    values (o.user_id, v_credit, 'Refund: cancelled order ' || o.code, o.id);
  end if;
  v_wallet := case when o.user_id is not null then v_credit else 0 end;
  v_momo_all := case when v_to = 'momo' then v_momo else 0 end;

  -- Cancelling the main order cancels the plates added under its code
  for c in select id from orders where parent_id = o.id and status in ('pending', 'paid') loop
    r := cancel_order(c.id, p_reason, p_refund);
    v_wallet := v_wallet + coalesce((r ->> 'wallet_credit')::numeric, 0);
    v_momo_all := v_momo_all + coalesce((r ->> 'momo')::numeric, 0);
    if (r ->> 'refund') = 'momo' then v_to := 'momo'; end if;
  end loop;

  update pools set status = 'cancelled' where id = o.pool_id and status = 'waiting' and pool_meals(id) = 0;

  return json_build_object('refund', v_to, 'wallet_credit', v_wallet, 'momo', v_momo_all);
end $$;

-- ---------- from update25 ----------
-- ChopPool update 25
-- "Special request" is now "Custom order" in every message the database sends (wording only:
-- no tables or data change; older cancelled orders keep their old reason, the app shows it with the new words).

CREATE OR REPLACE FUNCTION public.housekeeping()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s settings;
begin
  select * into s from settings where id = 1;

  -- Vendors who didn't confirm in time: confirmed payments come back to the wallet (account holders) or by MoMo (guests)
  with expired as (
    update pools set status = 'cancelled'
    where status = 'waiting' and now() >= wait_deadline(created_at, order_date)
    returning id)
  update orders o set status = 'cancelled', cancel_reason = 'The seller did not confirm in time',
                      refund_due = case when o.status in ('paid', 'collected') then greatest(0, order_total(o) - o.wallet_used) else 0 end,
                      refund_needed = (o.momo_ref is not null and not (o.user_id is not null and o.status in ('paid', 'collected')))
  from expired e where o.pool_id = e.id and o.status <> 'cancelled';

  -- Payment never found by the time orders close: cancelled; anything that did arrive (short payment) goes back
  update orders set status = 'cancelled', cancel_reason = 'Payment not received',
                    refund_due = coalesce(amount_received, 0),
                    refund_needed = coalesce(amount_received, 0) > 0 and user_id is null
  where status = 'pending' and pay_issue is not null and (now() at time zone 'utc') >= order_date + s.cutoff;

  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.refund_due, 'Money back: payment was short, code ' || o.code, o.id
  from orders o
  where o.status = 'cancelled' and o.cancel_reason = 'Payment not received' and o.refund_due > 0 and o.user_id is not null and not o.refund_needed
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.reason like 'Money back:%');

  -- Wallet part of any cancelled order goes back to the wallet
  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.wallet_used, 'Refund: ' || coalesce(o.cancel_reason, 'order cancelled'), o.id
  from orders o
  where o.status = 'cancelled' and o.wallet_used > 0 and o.user_id is not null
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.amount > 0 and w.reason like 'Refund:%');

  -- MoMo part of a confirmed payment, for account holders, once (never when ChopPool refunds the MoMo instead)
  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.refund_due, 'Money back: the vendor didn''t confirm, code ' || o.code, o.id
  from orders o
  where o.status = 'cancelled' and o.refund_due > 0 and o.user_id is not null and not o.refund_needed
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.reason like 'Money back:%');

  update orders set status = 'cancelled', cancel_reason = 'Custom order not paid before cut-off'
  where status in ('quote_requested', 'quoted')
    and (now() at time zone 'utc') >= order_date + s.cutoff;

  -- Custom orders: the seller must price in time, and the customer must pay inside the payment window
  update orders o set status = 'cancelled', cancel_reason = 'The seller didn''t price your request in time'
   where o.status = 'quote_requested' and (now() at time zone 'utc') >= o.order_date + s.cutoff - make_interval(mins => s.quote_pay_min);
  update orders set status = 'cancelled', cancel_reason = 'Custom order not paid in time'
   where status = 'quoted' and quote_pay_by is not null and now() > quote_pay_by + interval '30 seconds';

  -- "Got my food" confirms itself a while after handover, unless a problem was reported
  -- Counted from when the rider marks the pool Delivered (or from the code check, whichever came first)
  update orders o set received_at = now(), status = 'collected', collected_at = coalesce(o.collected_at, now()), collected_by = coalesce(o.collected_by, 'auto')
    from pools p
   where p.id = o.pool_id and o.parent_id is null and o.status in ('paid', 'collected') and o.received_at is null and o.problem is null
     and ((p.status = 'delivered' and p.delivered_at is not null and p.delivered_at + make_interval(mins => s.auto_receive_min) <= now())
          or (o.collected_at is not null and o.collected_at + make_interval(mins => s.auto_receive_min) <= now()));
  -- Extra plates in the same bag follow their main order
  update orders c set status = 'collected', collected_at = coalesce(c.collected_at, now()), collected_by = coalesce(c.collected_by, 'with main order')
    from orders m
   where c.parent_id = m.id and c.status = 'paid' and m.received_at is not null;

  -- Cashback: posted once, as a fixed wallet line, when the order is received (or its pool was delivered a while ago).
  -- Orders from before the ledger started keep the old timing (after cut-off) so no balance changes.
  with e as (
    select o.id, o.user_id, o.code, order_cashback(o.id) as cb
      from orders o join pools p on p.id = o.pool_id
     where o.parent_id is null and o.user_id is not null and not o.cashback_posted
       and o.status in ('paid', 'collected') and p.status <> 'cancelled'
       and (o.problem is null or o.problem_resolved_at is not null)
       and ((s.cashback_ledger_from is not null and o.created_at < s.cashback_ledger_from and (now() at time zone 'utc') >= o.order_date + s.cutoff)
            or o.received_at is not null
            or (p.status = 'delivered' and p.delivered_at is not null and p.delivered_at + make_interval(mins => s.auto_receive_min) <= now()))
     for update of o skip locked),
  ins as (
    insert into wallet_entries (user_id, amount, reason, order_id)
    select e.user_id, e.cb, 'Delivery cashback, code ' || e.code, e.id from e where e.cb > 0
      and not exists (select 1 from wallet_entries w where w.order_id = e.id and w.reason like 'Delivery cashback%')
    returning 1)
  update orders set cashback_posted = true where id in (select id from e);
end $function$;

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
begin
  perform housekeeping();
  select * into s from settings where id = 1;
  select * into m from menu_items where id = p_item and active;
  if not found then raise exception 'That dish is no longer available.'; end if;
  select * into k from kitchens where id = m.kitchen_id and active;
  if not found then raise exception 'That vendor is not taking orders.'; end if;
  if p_qty is null or p_qty < 1 or p_qty > least(5, s.max_meals) then raise exception 'Choose between 1 and 5 meals.'; end if;

  v_special := nullif(trim(coalesce(p_special, '')), '');
  select coalesce(jsonb_agg(a), '[]'::jsonb), coalesce(sum((a ->> 'price')::numeric), 0)
    into v_add, v_add_total
  from jsonb_array_elements(m.addons) a where a ->> 'name' = any(coalesce(p_addons, '{}'));

  perform pg_advisory_xact_lock(hashtext('cp' || k.id::text || d::text));
  select coalesce(sum(qty), 0) into v_load from orders where kitchen_id = k.id and order_date = d and status <> 'cancelled'
     and not (status = 'pending' and pay_issue is not null and pay_issue <> 'short');   -- payments we couldn't find don't hold seats
  if v_load + p_qty > k.capacity then raise exception 'This menu is fully booked for today. Try another one.'; end if;

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
    if pool_meals(pl.id) + p_qty > s.max_meals then raise exception 'This pool is full. Start a new order for more plates.'; end if;
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status,
                        parent_id, fee_per_meal)
    values (d, pl.id, par.site_id, k.id, m.id, par.user_id, m.name, m.price, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), null, par.customer_name, par.phone, par.code, 0, s.service_fee, 'pending',
            par.id, true)
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
       and pool_meals(p.id) + p_qty <= s.max_meals
     order by p.seq limit 1;
    if not found then
      insert into pools (order_date, site_id, kitchen_id, seq, status)
      values (d, si.id, k.id, coalesce((select max(seq) from pools where order_date = d and site_id = si.id and kitchen_id = k.id and status <> 'cancelled'), 0) + 1,
              case when v_open then 'collecting' else 'waiting' end)
      returning * into pl;
    end if;
    v_code := new_code(si.id, d, pl.id);
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status, fee_per_meal)
    values (d, pl.id, si.id, k.id, m.id, auth.uid(), m.name, m.price, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), v_special, trim(p_name), v_phone,
            v_code, ceil(fee_for(0, pool_trip(pl.id)) / p_qty * 2) / 2, s.service_fee, case when v_special is null then 'pending' else 'quote_requested' end, true)
    returning id into v_id;
  end if;

  if v_special is null then
    v_pay := settle_payment(v_id, p_ref, p_use_wallet);
  end if;

  return json_build_object('id', v_id, 'code', v_code, 'order_date', d, 'pool_seq', pl.seq, 'pool_status', pl.status,
    'pool_id', pl.id, 'meals', pool_meals(pl.id), 'status', (select status from orders where id = v_id), 'payment', v_pay,
    'parent_id', p_join);
end $function$;

CREATE OR REPLACE FUNCTION public.quote_window_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if old.status = 'quoted' and new.status in ('pending', 'paid') and old.quote_pay_by is not null and now() > old.quote_pay_by + interval '30 seconds' then
    raise exception 'The time to pay for this custom order has run out.';
  end if;
  return new;
end $function$;

-- ---------- from update26 ----------
-- ChopPool update 26
-- Remove some plates, not the whole order: a customer can take, say, 1 of 3 plates off before cut-off.
-- The food (and per-meal service fee) for the removed plates is refunded; the delivery already paid stays with the order.
-- Only for orders whose payment is confirmed (a waiting payment can still be cancelled whole, as before).

create or replace function reduce_plates(p_order uuid, p_remove int, p_reason text default null, p_refund text default 'wallet')
returns json language plpgsql security definer set search_path = public as $$
declare o orders; s settings; v_new int; v_per numeric; v_back numeric; v_w numeric; v_m numeric; v_credit numeric := 0; v_to text := 'wallet';
begin
  select * into s from settings where id = 1;
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'Order not found.'; end if;
  if o.user_id is not null and o.user_id is distinct from auth.uid() then raise exception 'Sign in with the account that placed this order.'; end if;
  if o.status = 'pending' then raise exception 'Your payment is still being checked. You can remove plates once it''s confirmed, or cancel this order.'; end if;
  if o.status <> 'paid' or o.special_request is not null then raise exception 'Plates can''t be removed from this order.'; end if;
  if exists (select 1 from pools p where p.id = o.pool_id and p.status not in ('waiting', 'collecting')) then
    raise exception 'The vendor is already cooking this order, so it can''t be changed now.';
  end if;
  if (now() at time zone 'utc') >= o.order_date + s.cutoff then
    raise exception 'Orders close at %. The kitchen is already cooking, so it can''t be changed now.', to_char(s.cutoff, 'HH24:MI');
  end if;
  if p_remove is null or p_remove < 1 or p_remove >= o.qty then
    raise exception 'Choose between 1 and % plates to remove. To remove them all, cancel the order.', o.qty - 1;
  end if;

  v_new := o.qty - p_remove;
  v_per := o.unit_price + o.addons_total + case when o.fee_per_meal then o.service_fee else 0 end;
  v_back := round(v_per * p_remove, 2);

  -- Wallet money goes back to the wallet first, then the rest as the customer chose
  v_w := least(v_back, o.wallet_used);
  v_m := v_back - v_w;
  if o.user_id is not null then v_credit := v_w; end if;
  if v_m > 0 and o.user_id is not null and coalesce(p_refund, 'wallet') = 'wallet' then v_credit := v_credit + v_m; v_m := 0; end if;
  if v_m > 0 then v_to := 'momo'; end if;

  update orders set qty = v_new,
         -- the main order carries the delivery: keep the full trip it paid for
         max_fee = case when parent_id is null and max_fee > 0 then max_fee * o.qty / v_new else max_fee end,
         wallet_used = wallet_used - v_w,
         refund_needed = refund_needed or v_m > 0,
         refund_due = case when v_m > 0 then (case when refund_needed then coalesce(refund_due, 0) else 0 end) + v_m else refund_due end,
         note = note
   where id = o.id;

  if v_credit > 0 then
    insert into wallet_entries (user_id, amount, reason, order_id)
    values (o.user_id, v_credit, 'Refund: removed ' || p_remove || ' plate' || case when p_remove = 1 then '' else 's' end || ' from code ' || o.code
            || coalesce(' (' || nullif(left(trim(p_reason), 200), '') || ')', ''), o.id);
  end if;

  return json_build_object('refund', v_to, 'wallet_credit', v_credit, 'momo', v_m, 'qty', v_new);
end $$;
revoke all on function reduce_plates(uuid, int, text, text) from public;
grant execute on function reduce_plates(uuid, int, text, text) to anon, authenticated;

-- ---------- from update27 ----------
-- ChopPool update 27 (tester feedback)

-- Adding several dishes to an order you already have (joining your own code): one payment for all of them.
-- place_basket gains p_join; the first new dish carries the payment and the others follow it (same code, packed together).
drop function if exists place_basket(uuid, jsonb, text, text, text, boolean, text, text);
create or replace function place_basket(p_site uuid, p_lines jsonb, p_name text, p_phone text, p_ref text,
                                        p_use_wallet boolean default false, p_payer_phone text default null, p_payer_network text default null,
                                        p_join uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  ln jsonb; n int := 0; r json; v_main uuid; v_code text; v_ids uuid[] := '{}'; v_total numeric := 0; v_use numeric := 0; v_left numeric;
  v_uid uuid := auth.uid(); o record; v_payer uuid; v_part numeric; v_meals int := 0; v_kitchen uuid; v_pp text := regexp_replace(coalesce(p_payer_phone, ''), '\D', '', 'g');
  s settings;
begin
  select * into s from settings where id = 1;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Your tray is empty.'; end if;
  if jsonb_array_length(p_lines) > 8 then raise exception 'Up to 8 different dishes in one order.'; end if;
  select coalesce(sum(greatest(1, coalesce((x ->> 'qty')::int, 1))), 0) into v_meals from jsonb_array_elements(p_lines) x;
  if v_meals > least(10, s.max_meals) then raise exception 'Up to % meals in one order.', least(10, s.max_meals); end if;
  if (select count(distinct m.kitchen_id) from jsonb_array_elements(p_lines) x join menu_items m on m.id = (x ->> 'item')::uuid) > 1
     or (p_join is not null and exists (select 1 from jsonb_array_elements(p_lines) x join menu_items m on m.id = (x ->> 'item')::uuid
                                         where m.kitchen_id <> (select kitchen_id from orders where id = p_join))) then
    raise exception 'Order from one vendor at a time.';
  end if;
  if v_pp <> '' and v_pp !~ '^0\d{9}$' then raise exception 'Enter the 10-digit mobile money number you paid from.'; end if;

  for ln in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    r := place_order(p_site, (ln ->> 'item')::uuid, greatest(1, coalesce((ln ->> 'qty')::int, 1)), p_name, p_phone, 'BASKET',
                     coalesce((select array_agg(a) from jsonb_array_elements_text(coalesce(ln -> 'addons', '[]'::jsonb)) a), '{}'),
                     ln ->> 'note', null, false, coalesce(p_join, v_main));
    if n = 1 then v_main := (r ->> 'id')::uuid; v_code := r ->> 'code'; end if;   -- with p_join: the first new dish is the one that carries the payment
    v_ids := v_ids || (r ->> 'id')::uuid;
  end loop;

  -- One payment for everything under this code: wallet first, the rest by mobile money
  update orders set momo_ref = null, status = 'pending', basket = (id <> v_main),
         payer_phone = nullif(v_pp, ''), payer_network = nullif(trim(coalesce(p_payer_network, '')), '')
   where id = any(v_ids);
  select coalesce(sum(order_total(x)), 0) into v_total from orders x where x.id = any(v_ids);
  if p_use_wallet and v_uid is not null and exists (select 1 from orders where id = v_main and user_id = v_uid) then
    v_use := greatest(0, least(wallet_balance(v_uid), v_total));
    if v_use > 0 then
      insert into wallet_entries (user_id, amount, reason, order_id) values (v_uid, -v_use, 'Paid for order ' || v_code, v_main);
    end if;
  end if;
  if v_use < v_total and (p_ref is null or char_length(trim(p_ref)) < 4) then
    raise exception 'Enter the mobile money transaction ID for the remaining %.', to_char(v_total - v_use, 'FM999990.00');
  end if;
  -- Spread the wallet part across the dishes (first dish first) so refunds stay exact
  v_left := v_use;
  for o in select x.id, order_total(x) as t from orders x where x.id = any(v_ids) order by (x.id <> v_main), x.created_at loop
    v_part := least(v_left, o.t); v_left := v_left - v_part;
    update orders set wallet_used = v_part,
           status = case when v_use >= v_total then 'paid' else 'pending' end,   -- one payment: all dishes paid together
           momo_ref = case when o.id = v_main and v_use < v_total then trim(p_ref) else null end
     where id = o.id;
  end loop;
  return json_build_object('id', v_main, 'code', v_code, 'ids', v_ids, 'total', v_total, 'wallet_used', v_use, 'momo_due', v_total - v_use,
                           'status', (select status from orders where id = v_main), 'order_date', (select order_date from orders where id = v_main));
end $$;

revoke all on function place_basket(uuid, jsonb, text, text, text, boolean, text, text, uuid) from public;
grant execute on function place_basket(uuid, jsonb, text, text, text, boolean, text, text, uuid) to anon, authenticated;

create or replace function basket_follow() returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- The dish carrying a payment decides for the dishes paid with it: the code's added dishes (new order),
  -- or the dishes added together to an existing code (same parent, placed in the same moment)
  if new.status is distinct from old.status then
    if new.status = 'paid' and old.status = 'pending' then
      update orders set status = 'paid' where basket and status = 'pending'
         and (parent_id = new.id or (new.parent_id is not null and parent_id = new.parent_id and created_at = new.created_at and id <> new.id));
    elsif new.status = 'cancelled' and new.cancel_reason = 'Payment not received' then
      update orders set status = 'cancelled', cancel_reason = 'Payment not received', refund_due = 0, refund_needed = false
       where basket and status = 'pending'
         and (parent_id = new.id or (new.parent_id is not null and parent_id = new.parent_id and created_at = new.created_at and id <> new.id));
    end if;
  end if;
  return null;
end $$;

-- Vendor fee: a vendor's automatic cooking days only open once they've accepted the current ChopPool fee
-- (before, automatic days kept running at the old 0% because the "Accept terms" step never came up)
create or replace function kitchen_is_open(p_kitchen uuid, p_date date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from kitchen_days where kitchen_id = p_kitchen and order_date = p_date)
      or exists (select 1 from kitchens k, settings s where s.id = 1 and k.id = p_kitchen and k.active
                   and extract(isodow from p_date)::int = any(k.auto_days) and not (p_date = any(k.paused_dates))
                   and s.vendor_fee_rate <= coalesce(k.fee_ack, 0) and s.vendor_fee_free >= coalesce(k.fee_free_ack, 5));
$$;

-- Rider sign-up: Ghana Card number, driving licence number and expiry (seen only by the ChopPool team)
alter table riders add column if not exists ghana_card text;
alter table riders add column if not exists licence_no text;
alter table riders add column if not exists licence_expiry date;
drop function if exists rider_apply(text, text, text, text, text);
create or replace function rider_apply(p_name text, p_phone text, p_bike text, p_area text, p_momo text,
                                       p_ghana_card text default null, p_licence_no text default null, p_licence_expiry date default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
        v_card text := upper(regexp_replace(coalesce(p_ghana_card, ''), '[^0-9A-Za-z]', '', 'g'));
        v_lic text := upper(left(trim(coalesce(p_licence_no, '')), 20));
begin
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Add your full name.'; end if;
  if v_phone !~ '^0\d{9}$' then raise exception 'Enter your 10-digit phone number, like 024 123 4567.'; end if;
  if v_card !~ '^GHA\d{10}$' then raise exception 'Enter your Ghana Card number, like GHA-123456789-0.'; end if;
  if length(regexp_replace(v_lic, '[^0-9A-Z]', '', 'g')) < 5 then raise exception 'Enter your driving licence number.'; end if;
  if p_licence_expiry is null or p_licence_expiry < (now() at time zone 'utc')::date then raise exception 'Your driving licence has expired. Renew it, then apply.'; end if;
  if exists (select 1 from riders where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = v_phone) then raise exception 'This phone number has already applied.'; end if;
  if exists (select 1 from riders where ghana_card = 'GHA-' || substr(v_card, 4, 9) || '-' || substr(v_card, 13, 1)) then raise exception 'This Ghana Card has already applied.'; end if;
  if (select count(*) from riders where status = 'pending' and created_at > now() - interval '1 day') > 50 then raise exception 'Too many applications today. Please try tomorrow.'; end if;
  insert into riders (name, phone, bike, area, momo, status, active, ghana_card, licence_no, licence_expiry)
  values (left(trim(p_name), 60), v_phone, left(trim(coalesce(p_bike, '')), 60), left(trim(coalesce(p_area, '')), 60), left(regexp_replace(coalesce(p_momo, ''), '[^0-9 ]', '', 'g'), 20), 'pending', false,
          'GHA-' || substr(v_card, 4, 9) || '-' || substr(v_card, 13, 1), v_lic, p_licence_expiry);
end $$;
revoke all on function rider_apply(text, text, text, text, text, text, text, date) from public;
grant execute on function rider_apply(text, text, text, text, text, text, text, date) to anon, authenticated;

-- Buildings customers add go live straight away (an existing one nearby or with the same name is reused)
CREATE OR REPLACE FUNCTION public.request_site(p_name text, p_drop_point text, p_lat double precision, p_lng double precision, p_note text DEFAULT NULL::text, p_endpoint text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare si sites; v_joined boolean := false; v_n int;
begin
  if char_length(trim(coalesce(p_name, ''))) < 3 then raise exception 'Add the building''s name.'; end if;
  if char_length(trim(coalesce(p_drop_point, ''))) < 3 then raise exception 'Say where the food should be dropped, like "Main gate".'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'Drop a pin on the map first.'; end if;
  if p_endpoint is not null and (p_endpoint !~ '^https://' or length(p_endpoint) > 1000) then p_endpoint := null; end if;
  -- Already on ChopPool (or already asked for)? Same name, or a building within 80 m: use that one instead of a copy
  select * into si from sites
   where status in ('active', 'pending') and not archived
     and (lower(regexp_replace(name, '\s+', ' ', 'g')) = lower(regexp_replace(trim(p_name), '\s+', ' ', 'g'))
          or (lat is not null and dist_m(lat, lng, p_lat, p_lng) <= 80))
   order by (status = 'active') desc, created_at limit 1;
  if found then
    v_joined := true;
  else
    if (select count(*) from site_waiters w where w.created_at > now() - interval '1 day'
        and ((auth.uid() is not null and w.user_id = auth.uid()) or (p_endpoint is not null and w.endpoint = p_endpoint))) >= 5
     or (select count(*) from sites where requested_by is not null and created_at > now() - interval '1 day') >= 300 then
      raise exception 'Too many building requests today. Please try again tomorrow.';
    end if;
    -- New buildings go live straight away; the team reviews them and merges any duplicates
    insert into sites (name, drop_point, lat, lng, status, requested_by, request_note)
    values (trim(p_name), trim(p_drop_point), p_lat, p_lng, 'active', auth.uid(), coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Added by a customer'))
    returning * into si;
  end if;
  if auth.uid() is not null or p_endpoint is not null then
    insert into site_waiters (site_id, user_id, endpoint) values (si.id, auth.uid(), p_endpoint) on conflict do nothing;
  end if;
  select count(*) into v_n from site_waiters where site_id = si.id;
  return json_build_object('id', si.id, 'name', si.name, 'status', si.status, 'joined', v_joined, 'waiting', greatest(v_n, 1));
end $function$;
-- Buildings already waiting for approval go live now too
update sites set status = 'active' where status = 'pending' and not archived;

-- ---------- from update28 ----------
-- ChopPool update 28: vendors set meals per pool and meals per day (or no daily limit)
-- Safe to run more than once.

-- Settings: the default pool size (was the app-wide 15 seats) and the most any vendor can choose
alter table settings add column if not exists pool_ceiling int not null default 15;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'settings_pool_ceiling_chk') then
    alter table settings add constraint settings_pool_ceiling_chk check (pool_ceiling between 5 and 50);
  end if;
end $$;

-- Vendors: their own pool size (empty = the default) and an optional "no daily limit"
alter table kitchens add column if not exists pool_size int;
alter table kitchens add column if not exists no_daily_limit boolean not null default false;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'kitchens_pool_size_chk') then
    alter table kitchens add constraint kitchens_pool_size_chk check (pool_size is null or pool_size between 5 and 50);
  end if;
end $$;
-- One-time switch from 15 seats to a default of 10 (only before anyone has chosen a size)
update settings set max_meals = 10 where id = 1 and max_meals = 15 and not exists (select 1 from kitchens where pool_size is not null);

-- The size of this vendor's pools: their choice, or the default, never above the ceiling or below 5
create or replace function kitchen_pool_size(p_kitchen uuid) returns int language sql stable security definer set search_path = public as $$
  select greatest(5, least(coalesce(k.pool_size, s.max_meals), s.pool_ceiling))
  from kitchens k cross join settings s where k.id = p_kitchen and s.id = 1;
$$;
grant execute on function kitchen_pool_size(uuid) to anon, authenticated;

-- What customers see about each vendor now includes the pool size and the daily limit
create or replace view public_menus as
  select k.id, k.public_name, k.tagline, k.capacity, k.site_id, k.added_by_customer, k.lat, k.lng,
         case when k.free_m > 0 then least(k.free_m, s.free_max_m) end as free_m, k.free_min,
         greatest(5, least(coalesce(k.pool_size, s.max_meals), s.pool_ceiling)) as pool_size, k.no_daily_limit, k.pool_size as pool_size_own
  from kitchens k cross join settings s where k.active and s.id = 1;
grant select on public_menus to anon, authenticated;

-- Vendor sets meals per pool (empty = ChopPool's default) and meals per day (or no limit)
create or replace function vendor_set_capacity(p_token text, p_pool int, p_daily int, p_no_limit boolean)
returns json language plpgsql security definer set search_path = public as $$
declare k kitchens; s settings;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  select * into s from settings where id = 1;
  if p_pool is not null and (p_pool < 5 or p_pool > s.pool_ceiling) then
    raise exception 'Meals per pool must be between 5 and %.', s.pool_ceiling;
  end if;
  if not coalesce(p_no_limit, false) and (p_daily is null or p_daily < 5 or p_daily > 1000) then
    raise exception 'Enter how many meals you can make in a day (5 or more), or tick No daily limit.';
  end if;
  update kitchens set pool_size = case when p_pool = s.max_meals then null else p_pool end,
                      no_daily_limit = coalesce(p_no_limit, false),
                      capacity = case when coalesce(p_no_limit, false) then capacity else p_daily end
  where id = k.id returning * into k;
  return json_build_object('pool_size', kitchen_pool_size(k.id), 'pool_size_own', k.pool_size, 'capacity', k.capacity, 'no_daily_limit', k.no_daily_limit);
end $$;
revoke execute on function vendor_set_capacity(text, int, int, boolean) from public;
grant execute on function vendor_set_capacity(text, int, int, boolean) to anon, authenticated;

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
  v_ps int; v_need int;
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
  select coalesce(jsonb_agg(a), '[]'::jsonb), coalesce(sum((a ->> 'price')::numeric), 0)
    into v_add, v_add_total
  from jsonb_array_elements(m.addons) a where a ->> 'name' = any(coalesce(p_addons, '{}'));

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
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status,
                        parent_id, fee_per_meal)
    values (d, pl.id, par.site_id, k.id, m.id, par.user_id, m.name, m.price, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), null, par.customer_name, par.phone, par.code, 0, s.service_fee, 'pending',
            par.id, true)
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
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status, fee_per_meal)
    values (d, pl.id, si.id, k.id, m.id, auth.uid(), m.name, m.price, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), v_special, trim(p_name), v_phone,
            v_code, ceil(fee_for(0, pool_trip(pl.id)) / p_qty * 2) / 2, s.service_fee, case when v_special is null then 'pending' else 'quote_requested' end, true)
    returning id into v_id;
  end if;

  if v_special is null then
    v_pay := settle_payment(v_id, p_ref, p_use_wallet);
  end if;

  return json_build_object('id', v_id, 'code', v_code, 'order_date', d, 'pool_seq', pl.seq, 'pool_status', pl.status,
    'pool_id', pl.id, 'meals', pool_meals(pl.id), 'status', (select status from orders where id = v_id), 'payment', v_pay,
    'parent_id', p_join);
end $function$;

CREATE OR REPLACE FUNCTION public.place_basket(p_site uuid, p_lines jsonb, p_name text, p_phone text, p_ref text, p_use_wallet boolean DEFAULT false, p_payer_phone text DEFAULT NULL::text, p_payer_network text DEFAULT NULL::text, p_join uuid DEFAULT NULL::uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  ln jsonb; n int := 0; r json; v_main uuid; v_code text; v_ids uuid[] := '{}'; v_total numeric := 0; v_use numeric := 0; v_left numeric;
  v_uid uuid := auth.uid(); o record; v_payer uuid; v_part numeric; v_meals int := 0; v_kitchen uuid; v_pp text := regexp_replace(coalesce(p_payer_phone, ''), '\D', '', 'g');
  s settings; v_ps int;
begin
  select * into s from settings where id = 1;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Your tray is empty.'; end if;
  if jsonb_array_length(p_lines) > 8 then raise exception 'Up to 8 different dishes in one order.'; end if;
  select coalesce(sum(greatest(1, coalesce((x ->> 'qty')::int, 1))), 0) into v_meals from jsonb_array_elements(p_lines) x;
  -- One order can't be bigger than the vendor's pool
  select kitchen_pool_size(min(m.kitchen_id::text)::uuid) into v_ps from jsonb_array_elements(p_lines) x join menu_items m on m.id = (x ->> 'item')::uuid;
  if v_meals > least(10, coalesce(v_ps, s.max_meals)) then raise exception 'Up to % meals in one order from this vendor.', least(10, coalesce(v_ps, s.max_meals)); end if;
  if p_join is null then perform set_config('cp.basket_meals', v_meals::text, true); end if;
  if (select count(distinct m.kitchen_id) from jsonb_array_elements(p_lines) x join menu_items m on m.id = (x ->> 'item')::uuid) > 1
     or (p_join is not null and exists (select 1 from jsonb_array_elements(p_lines) x join menu_items m on m.id = (x ->> 'item')::uuid
                                         where m.kitchen_id <> (select kitchen_id from orders where id = p_join))) then
    raise exception 'Order from one vendor at a time.';
  end if;
  if v_pp <> '' and v_pp !~ '^0\d{9}$' then raise exception 'Enter the 10-digit mobile money number you paid from.'; end if;

  for ln in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    r := place_order(p_site, (ln ->> 'item')::uuid, greatest(1, coalesce((ln ->> 'qty')::int, 1)), p_name, p_phone, 'BASKET',
                     coalesce((select array_agg(a) from jsonb_array_elements_text(coalesce(ln -> 'addons', '[]'::jsonb)) a), '{}'),
                     ln ->> 'note', null, false, coalesce(p_join, v_main));
    if n = 1 then v_main := (r ->> 'id')::uuid; v_code := r ->> 'code'; end if;   -- with p_join: the first new dish is the one that carries the payment
    v_ids := v_ids || (r ->> 'id')::uuid;
  end loop;

  perform set_config('cp.basket_meals', '', true);
  -- One payment for everything under this code: wallet first, the rest by mobile money
  update orders set momo_ref = null, status = 'pending', basket = (id <> v_main),
         payer_phone = nullif(v_pp, ''), payer_network = nullif(trim(coalesce(p_payer_network, '')), '')
   where id = any(v_ids);
  select coalesce(sum(order_total(x)), 0) into v_total from orders x where x.id = any(v_ids);
  if p_use_wallet and v_uid is not null and exists (select 1 from orders where id = v_main and user_id = v_uid) then
    v_use := greatest(0, least(wallet_balance(v_uid), v_total));
    if v_use > 0 then
      insert into wallet_entries (user_id, amount, reason, order_id) values (v_uid, -v_use, 'Paid for order ' || v_code, v_main);
    end if;
  end if;
  if v_use < v_total and (p_ref is null or char_length(trim(p_ref)) < 4) then
    raise exception 'Enter the mobile money transaction ID for the remaining %.', to_char(v_total - v_use, 'FM999990.00');
  end if;
  -- Spread the wallet part across the dishes (first dish first) so refunds stay exact
  v_left := v_use;
  for o in select x.id, order_total(x) as t from orders x where x.id = any(v_ids) order by (x.id <> v_main), x.created_at loop
    v_part := least(v_left, o.t); v_left := v_left - v_part;
    update orders set wallet_used = v_part,
           status = case when v_use >= v_total then 'paid' else 'pending' end,   -- one payment: all dishes paid together
           momo_ref = case when o.id = v_main and v_use < v_total then trim(p_ref) else null end
     where id = o.id;
  end loop;
  return json_build_object('id', v_main, 'code', v_code, 'ids', v_ids, 'total', v_total, 'wallet_used', v_use, 'momo_due', v_total - v_use,
                           'status', (select status from orders where id = v_main), 'order_date', (select order_date from orders where id = v_main));
end $function$;

CREATE OR REPLACE FUNCTION public.admin_weekly_report(p_week_start date)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s settings; w0 date := p_week_start; w1 date := p_week_start + 6; v0 date := p_week_start - 7; v1 date := p_week_start - 1;
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  select * into s from settings where id = 1;
  return (
  with o as (select o.*, p.status as pool_status from orders o join pools p on p.id = o.pool_id where o.order_date between v0 and w1),
  live as (select * from o where status in ('paid', 'collected', 'pending')),
  cur as (select * from live where order_date between w0 and w1),
  prev as (select * from live where order_date between v0 and v1),
  pl as (select p.*, pool_meals(p.id) as meals from pools p where p.order_date between v0 and w1),
  firsts as (select phone, min(order_date) as first_day from orders where status in ('paid', 'collected', 'pending') group by phone),
  head as (
    select wk, sum(qty)::int as meals, count(*) filter (where parent_id is null)::int as orders, count(distinct phone)::int as customers,
           count(distinct phone) filter (where (select first_day from firsts f where f.phone = x.phone) >= x.ws)::int as new_customers
    from (select *, 'cur' as wk, w0 as ws from cur union all select *, 'prev', v0 from prev) x group by wk),
  rep as (
    select wk, round(100.0 * count(*) filter (where n >= 2) / nullif(count(*), 0))::int as repeat_rate
    from (select 'cur' as wk, phone, count(distinct order_date) as n from live where order_date between w0 - 7 and w1 and phone in (select phone from cur) group by phone
          union all select 'prev', phone, count(distinct order_date) from live where order_date between v0 - 7 and v1 and phone in (select phone from prev) group by phone) r group by wk),
  pools_w as (
    select case when order_date >= w0 then 'cur' else 'prev' end as wk, round(avg(meals), 1) as avg_meals,
           count(*) filter (where meals >= kitchen_pool_size(kitchen_id))::int as filled, count(*)::int as pools
    from pl where status <> 'cancelled' and meals > 0 group by 1),
  canc as (select case when order_date >= w0 then 'cur' else 'prev' end as wk, count(*)::int as n from o where status = 'cancelled' group by 1)
  select json_build_object(
    'week_start', w0, 'week_end', w1,
    'headline', (select json_object_agg(h.wk, json_build_object('meals', h.meals, 'orders', h.orders, 'customers', h.customers, 'new_customers', h.new_customers,
                    'repeat_rate', (select repeat_rate from rep where rep.wk = h.wk), 'avg_meals', (select avg_meals from pools_w where pools_w.wk = h.wk),
                    'pools', (select pools from pools_w where pools_w.wk = h.wk), 'filled', (select filled from pools_w where pools_w.wk = h.wk),
                    'cancelled', coalesce((select n from canc where canc.wk = h.wk), 0))) from head h),
    'money', case when is_super() then (select json_build_object(
        'food', round(coalesce(sum((coalesce(quote_price, unit_price) + addons_total) * qty), 0), 2),
        'trip_estimate', round(coalesce((select sum(pool_trip(p2.id)) from pools p2 where p2.order_date between w0 and w1 and p2.status = 'delivered'), 0), 2),
        'trip_paid', round(coalesce((select sum(p2.trip_cost) from pools p2 where p2.order_date between w0 and w1 and p2.status = 'delivered'), 0), 2),
        'commission', round(coalesce((select sum(pool_fee(p2.id)) from pools p2 where p2.order_date between w0 and w1 and p2.status <> 'cancelled'), 0), 2),
        'service_fees', round(coalesce(sum(service_fee * case when fee_per_meal then qty else 1 end), 0), 2),
        'cashback', round(coalesce(sum(case when parent_id is null and status in ('paid', 'collected') and not (parent_id is null and status in ('paid', 'collected') and not cashback_posted and created_at >= coalesce(s.cashback_ledger_from, '-infinity'::timestamptz)) then order_cashback(id) else 0 end), 0), 2),
        'cashback_pending', round(coalesce(sum(case when parent_id is null and status in ('paid', 'collected') and not cashback_posted and created_at >= coalesce(s.cashback_ledger_from, '-infinity'::timestamptz) then order_cashback(id) else 0 end), 0), 2),
        'refunds', round(coalesce((select sum(amount) from wallet_entries where amount > 0 and reason like 'Refund%' and created_at::date between w0 and w1 + 2), 0), 2),
        'momo_refunds', (select count(*) from orders where refund_needed and order_date between w0 and w1),
        'wallets_owed', round(coalesce((select sum(wallet_balance(u)) from (select distinct user_id as u from orders where user_id is not null union select distinct user_id from wallet_entries) us), 0), 2))
      from cur) end,
    'buildings', coalesce((select json_agg(b order by b.meals desc) from (
        select si.name, sum(c.qty)::int as meals, count(distinct c.pool_id)::int as pools,
               round(sum(c.qty)::numeric / nullif(count(distinct c.pool_id), 0), 1) as avg_pool,
               coalesce((select sum(qty) from prev where prev.site_id = si.id), 0)::int as prev_meals
        from cur c join sites si on si.id = c.site_id group by si.id, si.name order by 2 desc limit 15) b), '[]'::json),
    'quiet', coalesce((select json_agg(q) from (
        select si.name, sum(p.qty)::int as prev_meals from prev p join sites si on si.id = p.site_id
        where not exists (select 1 from cur c where c.site_id = p.site_id) group by si.name order by 2 desc) q), '[]'::json),
    'customers', coalesce((select json_agg(c2) from (
        select (array_agg(customer_name order by created_at desc))[1] as name,
               (select si.name from cur c3 join sites si on si.id = c3.site_id where c3.phone = c.phone group by si.name order by count(*) desc limit 1) as building,
               case when is_super() then c.phone end as phone,
               count(*) filter (where parent_id is null)::int as orders, sum(qty)::int as meals
        from cur c group by c.phone order by sum(qty) desc, count(*) desc limit 15) c2), '[]'::json),
    'vendors', coalesce((select json_agg(v order by v.meals desc) from (
        select k.public_name as name, coalesce(sum(c.qty), 0)::int as meals,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status <> 'cancelled' and pl.meals > 0)::int as pools,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status = 'cancelled'
                  and exists (select 1 from orders x where x.pool_id = pl.id and x.cancel_reason = 'The seller did not confirm in time'))::int as expired,
               (select round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*) filter (where pl.delivered_at is not null), 0))
                  from pl where pl.kitchen_id = k.id and pl.order_date >= w0)::int as on_time,
               (select count(*) from o where o.kitchen_id = k.id and o.order_date >= w0 and o.cancel_reason like 'The seller can''t%')::int as declined,
               (select count(*) from (select phone from live where live.kitchen_id = k.id and live.order_date between w0 - 28 and w1 group by phone having count(distinct order_date) >= 2) r)::int as repeat_customers,
               cardinality(k.auto_days) > 0 as always_cooking,
               (select round(avg(r.rating), 1) from reviews r where r.kitchen_id = k.id and not r.hidden and r.created_at::date between w0 and w1 + 2) as rating
        from kitchens k left join cur c on c.kitchen_id = k.id where k.active
        group by k.id, k.public_name, k.auto_days having coalesce(sum(c.qty), 0) > 0
           or exists (select 1 from pl where pl.kitchen_id = k.id and pl.order_date >= w0)) v), '[]'::json),
    'riders', coalesce((select json_agg(r) from (
        select rd.name, count(*)::int as deliveries,
               round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*), 0))::int as on_time
        from pl join riders rd on rd.id = pl.rider_id where pl.order_date >= w0 and pl.delivered_at is not null group by rd.name order by 2 desc) r), '[]'::json)
  ));
end $function$;


-- The vendor page shows their pool size and daily limit
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
                                 'fee_ack', k.fee_ack, 'fee_free_ack', k.fee_free_ack, 'fee_rate', s.vendor_fee_rate, 'fee_free', s.vendor_fee_free,
                                 'next_day_confirm_by', s.next_day_confirm_by),
    'menu', coalesce((select json_agg(json_build_object('id', id, 'name', name, 'price', price, 'addons', addons,
                                                        'photo_url', photo_url, 'icon', icon) order by name)
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

-- ---------- from update29 ----------
-- ChopPool update 29: a delivered pool's trip cost fills itself in (no typing it by hand)
-- Safe to run more than once.

-- When a pool is marked delivered and nobody has entered a trip cost, use the trip price for that vendor and building
-- (the same base fare + rate per km the app charges). Vendors who deliver with their own runner, and free-delivery
-- pools, owe no rider. A cost you type yourself is never overwritten.
create or replace function pool_trip_on_delivery() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'delivered' and old.status is distinct from 'delivered' and new.trip_cost is null
     and not exists (select 1 from kitchens k where k.id = new.kitchen_id and k.delivery_mode = 'runner')
     and not pool_free(new.id) then
    new.trip_cost := pool_trip(new.id);
  end if;
  return new;
end $$;
drop trigger if exists pool_trip_on_delivery on pools;
create trigger pool_trip_on_delivery before update on pools for each row execute function pool_trip_on_delivery();

-- Pools already delivered without a trip cost: fill them in the same way
update pools pl set trip_cost = pool_trip(pl.id)
 where pl.status = 'delivered' and pl.trip_cost is null
   and not exists (select 1 from kitchens k where k.id = pl.kitchen_id and k.delivery_mode = 'runner')
   and not pool_free(pl.id);


-- ---------- from update30 ----------
-- ChopPool update 30: a lowest trip price (minimum fare), like Bolt and Yango
-- Safe to run more than once.

-- Trips cost base fare + rate per km, never below the lowest trip price and never above the highest.
-- Starts at GHS 10, so nothing changes until you lower the base fare.
alter table settings add column if not exists trip_min numeric not null default 10;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'settings_trip_min_chk') then
    alter table settings add constraint settings_trip_min_chk check (trip_min >= 0);
  end if;
end $$;

create or replace function pool_trip(p uuid) returns numeric language sql stable security definer set search_path = public as $$
  select case
    when pool_free(p) then 0
    when coalesce(k.lat, case when k.added_by_customer then st.lat end) is null or st.lat is null then greatest(s.trip_min, least(s.trip_cost, s.trip_max))
    else greatest(s.trip_min, least(s.trip_max, round(s.base_fare + s.per_km * dist_m(
           coalesce(k.lat, case when k.added_by_customer then st.lat end),
           coalesce(k.lng, case when k.added_by_customer then st.lng end),
           st.lat, st.lng) / 1000 * 1.3)))
  end
  from pools pl join kitchens k on k.id = pl.kitchen_id join sites st on st.id = pl.site_id cross join settings s
  where pl.id = p and s.id = 1;
$$;


-- ---------- from update31 ----------
-- ChopPool update 31: "Send feedback" from every screen (customers, vendors, riders, team), with up to 3 photos.
-- Photos go to a private bucket that only the team can open. Safe to run more than once.

create table if not exists feedback (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  role text not null check (role in ('customer', 'guest', 'vendor', 'rider', 'team')),
  user_id uuid,
  kitchen_id uuid references kitchens(id) on delete set null,
  rider_id uuid references riders(id) on delete set null,
  name text,
  contact text,
  kind text not null default 'problem' check (kind in ('problem', 'idea', 'other')),
  message text not null check (char_length(message) between 2 and 2000),
  screen text,
  device text,
  app_version text,
  images text[] not null default '{}',
  status text not null default 'new' check (status in ('new', 'seen', 'done')),
  team_note text
);
create index if not exists feedback_created_idx on feedback (created_at desc);
alter table feedback enable row level security;
drop policy if exists "team reads feedback" on feedback;
create policy "team reads feedback" on feedback for select to authenticated using (is_admin());
drop policy if exists "team updates feedback" on feedback;
create policy "team updates feedback" on feedback for update to authenticated using (is_admin()) with check (is_admin());
revoke insert, delete on feedback from anon, authenticated;

-- Everyone sends through this, so the sender is worked out here (a vendor or rider by their link, the team by their sign-in)
create or replace function send_feedback(p_kind text, p_message text, p_screen text default null, p_device text default null, p_version text default null,
  p_images text[] default '{}', p_name text default null, p_contact text default null, p_as text default null, p_token text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_role text; v_kitchen uuid; v_rider uuid; v_user uuid := auth.uid(); v_id uuid; v_img text; v_n int;
begin
  if coalesce(p_kind, '') not in ('problem', 'idea', 'other') then raise exception 'Choose what kind of feedback this is.'; end if;
  if char_length(trim(coalesce(p_message, ''))) < 2 then raise exception 'Tell us a little more.'; end if;
  if char_length(p_message) > 2000 then raise exception 'Keep it under 2,000 characters.'; end if;
  if coalesce(array_length(p_images, 1), 0) > 3 then raise exception 'Add up to 3 photos.'; end if;
  foreach v_img in array coalesce(p_images, '{}') loop
    if v_img !~ '^fb/[0-9a-f-]{36}/[A-Za-z0-9._-]{1,80}$' then raise exception 'Upload the photos from the feedback form.'; end if;
  end loop;
  if p_as = 'vendor' then
    select id into v_kitchen from kitchens where token = p_token and active; if v_kitchen is null then raise exception 'This vendor link is not valid.'; end if; v_role := 'vendor';
  elsif p_as = 'rider' then
    select id into v_rider from riders where token = p_token and active; if v_rider is null then raise exception 'This rider link is not valid.'; end if; v_role := 'rider';
  elsif p_as = 'team' then
    if not is_admin() then raise exception 'Sign in to the team screen first.'; end if; v_role := 'team';
  elsif v_user is not null then v_role := 'customer';
  else v_role := 'guest';
  end if;
  -- Spam guard: 10 an hour per sender, 30 an hour from guests altogether
  select count(*) into v_n from feedback where created_at > now() - interval '1 hour' and (
    (v_kitchen is not null and kitchen_id = v_kitchen) or (v_rider is not null and rider_id = v_rider)
    or (v_role in ('customer', 'team') and user_id = v_user) or (v_role = 'guest' and role = 'guest'));
  if v_n >= (case when v_role = 'guest' then 30 else 10 end) then raise exception 'Thanks, we have your feedback. Try again in a little while.'; end if;
  insert into feedback (role, user_id, kitchen_id, rider_id, name, contact, kind, message, screen, device, app_version, images)
  values (v_role, case when v_role in ('customer', 'team') then v_user end, v_kitchen, v_rider, left(nullif(trim(p_name), ''), 80), left(nullif(trim(p_contact), ''), 120),
    p_kind, trim(p_message), left(p_screen, 80), left(p_device, 200), left(p_version, 40), coalesce(p_images, '{}'))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function send_feedback(text, text, text, text, text, text[], text, text, text, text) from public;
grant execute on function send_feedback(text, text, text, text, text, text[], text, text, text, text) to anon, authenticated;

-- Private bucket: anyone can add a photo under fb/ (max 1.5 MB, images only); only the team can view them
do $$ begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('feedback', 'feedback', false, 1572864, array['image/webp', 'image/jpeg', 'image/png'])
    on conflict (id) do update set public = false, file_size_limit = 1572864, allowed_mime_types = array['image/webp', 'image/jpeg', 'image/png'];
    execute 'drop policy if exists "feedback photos add" on storage.objects';
    execute 'create policy "feedback photos add" on storage.objects for insert to anon, authenticated with check (bucket_id = ''feedback'' and (storage.foldername(name))[1] = ''fb'')';
    execute 'drop policy if exists "feedback photos team" on storage.objects';
    execute 'create policy "feedback photos team" on storage.objects for select to authenticated using (bucket_id = ''feedback'' and public.is_admin())';
  end if;
end $$;

-- ---------- from update32 ----------
-- ChopPool update 32: extras with the same name (Fish at GHS 15, 20, 30...) are charged one at a time
-- Before this, picking one "Fish" charged every Fish on the list. Safe to run more than once.

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
  v_ps int; v_need int;
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
  select coalesce(jsonb_agg(a), '[]'::jsonb), coalesce(sum((a ->> 'price')::numeric), 0)
    into v_add, v_add_total
  from jsonb_array_elements(m.addons) with ordinality x(a, i)
  -- Each extra is picked by name, or by name#price when a dish lists the same name more than once (e.g. Fish at 15, 20, 30);
  -- a bare name that appears more than once counts once (the first), never all of them
  where (a ->> 'name') || '#' || trim_scale(coalesce(nullif(a ->> 'price', '')::numeric, 0))::text = any(coalesce(p_addons, '{}'))
     or (a ->> 'name' = any(coalesce(p_addons, '{}')) and i = (select min(j) from jsonb_array_elements(m.addons) with ordinality y(b, j) where b ->> 'name' = a ->> 'name'));

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
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status,
                        parent_id, fee_per_meal)
    values (d, pl.id, par.site_id, k.id, m.id, par.user_id, m.name, m.price, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), null, par.customer_name, par.phone, par.code, 0, s.service_fee, 'pending',
            par.id, true)
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
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status, fee_per_meal)
    values (d, pl.id, si.id, k.id, m.id, auth.uid(), m.name, m.price, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), v_special, trim(p_name), v_phone,
            v_code, ceil(fee_for(0, pool_trip(pl.id)) / p_qty * 2) / 2, s.service_fee, case when v_special is null then 'pending' else 'quote_requested' end, true)
    returning id into v_id;
  end if;

  if v_special is null then
    v_pay := settle_payment(v_id, p_ref, p_use_wallet);
  end if;

  return json_build_object('id', v_id, 'code', v_code, 'order_date', d, 'pool_seq', pl.seq, 'pool_status', pl.status,
    'pool_id', pl.id, 'meals', pool_meals(pl.id), 'status', (select status from orders where id = v_id), 'payment', v_pay,
    'parent_id', p_join);
end $function$;

-- ---------- from update33 ----------
-- ChopPool update 33: extras with a count (2 x Fried eggs on each plate, up to 5), charged price x count.
-- Older orders without a count read as 1. Safe to run more than once.

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
  v_ps int; v_need int;
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
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status,
                        parent_id, fee_per_meal)
    values (d, pl.id, par.site_id, k.id, m.id, par.user_id, m.name, m.price, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), null, par.customer_name, par.phone, par.code, 0, s.service_fee, 'pending',
            par.id, true)
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
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status, fee_per_meal)
    values (d, pl.id, si.id, k.id, m.id, auth.uid(), m.name, m.price, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), v_special, trim(p_name), v_phone,
            v_code, ceil(fee_for(0, pool_trip(pl.id)) / p_qty * 2) / 2, s.service_fee, case when v_special is null then 'pending' else 'quote_requested' end, true)
    returning id into v_id;
  end if;

  if v_special is null then
    v_pay := settle_payment(v_id, p_ref, p_use_wallet);
  end if;

  return json_build_object('id', v_id, 'code', v_code, 'order_date', d, 'pool_seq', pl.seq, 'pool_status', pl.status,
    'pool_id', pl.id, 'meals', pool_meals(pl.id), 'status', (select status from orders where id = v_id), 'payment', v_pay,
    'parent_id', p_join);
end $function$;

-- ---------- from update34 ----------
-- ChopPool update 34: tester agreement. Customers, vendors and riders accept it once before using the app;
-- each acceptance is kept (who, when, which version). The owner can switch it off at launch. Safe to run more than once.

alter table settings add column if not exists tester_terms_on boolean not null default true;
alter table settings add column if not exists tester_terms_version int not null default 1;

create table if not exists tester_acceptances (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  role text not null check (role in ('customer', 'vendor', 'rider')),
  user_id uuid,
  kitchen_id uuid references kitchens(id) on delete cascade,
  rider_id uuid references riders(id) on delete cascade,
  email text,
  name text,
  version int not null,
  device text
);
create unique index if not exists tester_acc_user_v on tester_acceptances (user_id, version) where user_id is not null;
create unique index if not exists tester_acc_kitchen_v on tester_acceptances (kitchen_id, version) where kitchen_id is not null;
create unique index if not exists tester_acc_rider_v on tester_acceptances (rider_id, version) where rider_id is not null;
alter table tester_acceptances enable row level security;
drop policy if exists "team reads acceptances" on tester_acceptances;
create policy "team reads acceptances" on tester_acceptances for select to authenticated using (is_admin());
revoke insert, update, delete on tester_acceptances from anon, authenticated;

-- Has this person (signed-in customer, or vendor/rider by their link) accepted the current version? null = nothing to accept
create or replace function tester_terms_due(p_as text default null, p_token text default null) returns int
language plpgsql stable security definer set search_path = public as $$
declare s settings; v_k uuid; v_r uuid;
begin
  select * into s from settings where id = 1;
  if not s.tester_terms_on then return null; end if;
  if p_as = 'vendor' then select id into v_k from kitchens where token = p_token and active; if v_k is null then return null; end if;
    return case when exists (select 1 from tester_acceptances where kitchen_id = v_k and version = s.tester_terms_version) then null else s.tester_terms_version end;
  elsif p_as = 'rider' then select id into v_r from riders where token = p_token and active; if v_r is null then return null; end if;
    return case when exists (select 1 from tester_acceptances where rider_id = v_r and version = s.tester_terms_version) then null else s.tester_terms_version end;
  elsif auth.uid() is not null then
    return case when exists (select 1 from tester_acceptances where user_id = auth.uid() and version = s.tester_terms_version) then null else s.tester_terms_version end;
  end if;
  return null;
end $$;

create or replace function accept_tester_terms(p_version int, p_as text default null, p_token text default null, p_name text default null, p_device text default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare s settings; v_k kitchens; v_r riders;
begin
  select * into s from settings where id = 1;
  if p_version is distinct from s.tester_terms_version then raise exception 'The agreement was just updated. Please read it again.'; end if;
  if p_as = 'vendor' then
    select * into v_k from kitchens where token = p_token and active; if not found then raise exception 'This vendor link is not valid.'; end if;
    insert into tester_acceptances (role, kitchen_id, name, version, device) values ('vendor', v_k.id, coalesce(nullif(trim(p_name), ''), v_k.public_name), p_version, left(p_device, 200)) on conflict do nothing;
  elsif p_as = 'rider' then
    select * into v_r from riders where token = p_token and active; if not found then raise exception 'This rider link is not valid.'; end if;
    insert into tester_acceptances (role, rider_id, name, version, device) values ('rider', v_r.id, coalesce(nullif(trim(p_name), ''), v_r.name), p_version, left(p_device, 200)) on conflict do nothing;
  else
    if auth.uid() is null then raise exception 'Sign in first.'; end if;
    insert into tester_acceptances (role, user_id, email, name, version, device)
    values ('customer', auth.uid(), lower(auth.jwt() ->> 'email'), left(nullif(trim(p_name), ''), 80), p_version, left(p_device, 200)) on conflict do nothing;
  end if;
  return true;
end $$;
revoke all on function tester_terms_due(text, text) from public;
revoke all on function accept_tester_terms(int, text, text, text, text) from public;
grant execute on function tester_terms_due(text, text) to anon, authenticated;
grant execute on function accept_tester_terms(int, text, text, text, text) to anon, authenticated;

-- ---------- from update35 ----------
-- ChopPool update 35: every alert is saved on the server, so the bell shows the same list on every phone
-- (app or browser), including alerts that never popped up. Only the last 7 days are kept. Safe to run more than once.

create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id uuid,                                                   -- a customer with an account
  order_id uuid,                                                  -- a customer without one (their order)
  kitchen_id uuid references kitchens(id) on delete cascade,
  rider_id uuid references riders(id) on delete cascade,
  title text not null,
  body text,
  url text,
  tag text,
  type text,
  read_at timestamptz
);
create index if not exists notifications_user_idx on notifications (user_id, created_at desc) where user_id is not null;
create index if not exists notifications_order_idx on notifications (order_id) where order_id is not null;
create index if not exists notifications_kitchen_idx on notifications (kitchen_id, created_at desc) where kitchen_id is not null;
create index if not exists notifications_rider_idx on notifications (rider_id, created_at desc) where rider_id is not null;
create index if not exists notifications_created_idx on notifications (created_at);
alter table notifications enable row level security;   -- no policies: only the notify function (service key) writes; people read through the functions below
revoke all on notifications from anon, authenticated;

-- Your alerts from the last 7 days: a signed-in customer (plus orders placed on this phone), or a vendor/rider by their link
create or replace function my_notifications(p_order_ids uuid[] default '{}', p_as text default null, p_token text default null)
returns setof notifications language plpgsql stable security definer set search_path = public as $$
declare v_k uuid; v_r uuid;
begin
  if p_as = 'vendor' then select id into v_k from kitchens where token = p_token and active; if v_k is null then return; end if;
    return query select * from notifications where kitchen_id = v_k and created_at > now() - interval '7 days' order by created_at desc limit 100;
  elsif p_as = 'rider' then select id into v_r from riders where token = p_token and active; if v_r is null then return; end if;
    return query select * from notifications where rider_id = v_r and created_at > now() - interval '7 days' order by created_at desc limit 100;
  else
    return query select * from notifications where created_at > now() - interval '7 days'
      and ((auth.uid() is not null and user_id = auth.uid()) or order_id = any(coalesce(p_order_ids, '{}'))) order by created_at desc limit 100;
  end if;
end $$;

create or replace function read_notifications(p_order_ids uuid[] default '{}', p_as text default null, p_token text default null)
returns int language plpgsql security definer set search_path = public as $$
declare v_k uuid; v_r uuid; n int;
begin
  if p_as = 'vendor' then select id into v_k from kitchens where token = p_token and active;
    update notifications set read_at = now() where kitchen_id = v_k and read_at is null and created_at > now() - interval '7 days';
  elsif p_as = 'rider' then select id into v_r from riders where token = p_token and active;
    update notifications set read_at = now() where rider_id = v_r and read_at is null and created_at > now() - interval '7 days';
  else
    update notifications set read_at = now() where read_at is null and created_at > now() - interval '7 days'
      and ((auth.uid() is not null and user_id = auth.uid()) or order_id = any(coalesce(p_order_ids, '{}')));
  end if;
  get diagnostics n = row_count; return n;
end $$;

-- Daily clean-up (called by the notify function once a day)
create or replace function prune_notifications() returns int language plpgsql security definer set search_path = public as $$
declare n int; begin delete from notifications where created_at < now() - interval '7 days'; get diagnostics n = row_count; return n; end $$;

revoke all on function my_notifications(uuid[], text, text) from public;
revoke all on function read_notifications(uuid[], text, text) from public;
revoke all on function prune_notifications() from public, anon, authenticated;
grant execute on function my_notifications(uuid[], text, text) to anon, authenticated;
grant execute on function read_notifications(uuid[], text, text) to anon, authenticated;

-- ---------- from update36 ----------
-- ChopPool update 36: the team can correct an extra's name on open orders (the vendor sees the new name).
-- Prices, counts and totals on those orders never change. Safe to run more than once.

create or replace function admin_rename_addons(p_item uuid, p_renames jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; c int;
begin
  if not is_admin() then raise exception 'Only the ChopPool team can do this.'; end if;
  for r in select * from jsonb_to_recordset(coalesce(p_renames, '[]'::jsonb)) as x("from" text, "to" text, price numeric) loop
    if char_length(trim(coalesce(r."to", ''))) < 2 or char_length(r."to") > 80 then raise exception 'Each extra needs a name.'; end if;
    if r."from" is null or r."from" = r."to" then continue; end if;
    update orders o set addons = (
        select jsonb_agg(case when e ->> 'name' = r."from" and coalesce(nullif(e ->> 'price', '')::numeric, 0) = coalesce(r.price, 0)
                              then jsonb_set(e, '{name}', to_jsonb(trim(r."to"))) else e end order by i)
        from jsonb_array_elements(o.addons) with ordinality t(e, i))
    where o.item_id = p_item and o.order_date >= (now() at time zone 'utc')::date and o.status not in ('cancelled', 'collected')
      and exists (select 1 from jsonb_array_elements(o.addons) e where e ->> 'name' = r."from" and coalesce(nullif(e ->> 'price', '')::numeric, 0) = coalesce(r.price, 0));
    get diagnostics c = row_count; n := n + c;
  end loop;
  return n;
end $$;
revoke all on function admin_rename_addons(uuid, jsonb) from public, anon;
grant execute on function admin_rename_addons(uuid, jsonb) to authenticated;

-- ---------- from update37 ----------
-- ChopPool update 37: mobile money payments (and refunds sent back to mobile money) listed in the customer's Activity.
-- Read-only; safe to run more than once.

-- One line per order code: what was paid by mobile money, and any refund sent back to mobile money. Last 6 months.
create or replace function my_payments()
returns table (at timestamptz, order_date date, code text, items text, paid numeric, refunded numeric, refunded_at timestamptz)
language sql stable security definer set search_path = public as $$
  with mine as (
    select o.*, greatest(order_total(o) - coalesce(o.wallet_used, 0) - coalesce(o.carried_amount, 0), 0) as momo
    from orders o
    where auth.uid() is not null and o.user_id = auth.uid() and o.created_at > now() - interval '180 days'
      and (o.status in ('paid', 'collected')
           or (o.status = 'cancelled' and (o.refund_needed or o.refunded_at is not null
               or exists (select 1 from wallet_entries w where w.order_id = o.id and w.amount > 0 and (w.reason like 'Refund%' or w.reason like 'Money back%')))))
  )
  select min(created_at), order_date, code,
         string_agg(qty || ' × ' || item_name, ', ' order by created_at),
         round(sum(momo), 2),
         round(sum(coalesce(refund_amount, 0)) filter (where refunded_at is not null), 2),
         max(refunded_at)
  from mine group by order_date, code having sum(momo) > 0
  order by 1 desc limit 200;
$$;
revoke all on function my_payments() from public, anon;
grant execute on function my_payments() to authenticated;

-- ---------- from update38 ----------
-- ChopPool update 38: owner's daily money report for any period (one row per day, totals, what each vendor and rider earned).
-- Read-only; same rules as the dashboard. Safe to run more than once.

create or replace function admin_money_days(p_from date, p_to date) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_super() then raise exception 'Only the owner can see the money report.'; end if;
  if p_to < p_from then raise exception 'The end date is before the start date.'; end if;
  if p_to - p_from > 370 then raise exception 'Pick a period of a year or less.'; end if;
  return json_build_object(
    'days', coalesce((select json_agg(d order by d.day) from (
      with paid as (select o.* from orders o where o.order_date between p_from and p_to and o.status in ('paid', 'collected')),
      pl as (select p.*, (select sum(qty) from paid where paid.pool_id = p.id) as meals,
                    (exists (select 1 from kitchens k where k.id = p.kitchen_id and k.delivery_mode = 'runner') or pool_free(p.id)) as no_trip
               from pools p where p.order_date between p_from and p_to and p.status <> 'cancelled' and exists (select 1 from paid where paid.pool_id = p.id)),
      days as (select generate_series(p_from, p_to, interval '1 day')::date as day)
      select dd.day,
        (select count(distinct code) from paid where order_date = dd.day) as orders,
        coalesce((select sum(qty) from paid where order_date = dd.day), 0) as meals,
        round(coalesce((select sum(order_total(paid)) from paid where order_date = dd.day), 0), 2) as received,
        round(coalesce((select sum(wallet_used) from paid where order_date = dd.day), 0), 2) as wallet_used,
        round(coalesce((select sum((coalesce(quote_price, unit_price) + addons_total) * qty) from paid where order_date = dd.day), 0), 2) as food,
        round(coalesce((select sum(pool_fee(pl.id)) from pl where order_date = dd.day), 0), 2) as vendor_fee,
        round(coalesce((select sum(service_fee * case when fee_per_meal then qty else 1 end) from paid where order_date = dd.day), 0), 2) as service,
        round(coalesce((select sum(max_fee * qty) from paid where order_date = dd.day), 0), 2) as delivery_in,
        round(coalesce((select sum(coalesce(trip_cost, pool_trip(pl.id))) from pl where order_date = dd.day and not no_trip and rider_id is not null), 0), 2) as trips_riders,
        round(coalesce((select sum(coalesce(trip_cost, pool_trip(pl.id))) from pl where order_date = dd.day and not no_trip and rider_id is null), 0), 2) as trips_apps,
        (select count(*) from pl where order_date = dd.day and not no_trip and trip_cost is null) as trips_estimated,
        round(coalesce((select sum(w.amount) from wallet_entries w join orders o on o.id = w.order_id where o.order_date = dd.day and w.reason like 'Delivery cashback%'), 0), 2) as cashback,
        round(coalesce((select sum(w.amount) from wallet_entries w join orders o on o.id = w.order_id where o.order_date = dd.day and w.amount > 0 and (w.reason like 'Refund%' or w.reason like 'Money back%')), 0)
            + coalesce((select sum(refund_amount) from orders where order_date = dd.day and refunded_at is not null), 0), 2) as refunds,
        round(coalesce((select sum(amount) from payouts where payee_type = 'seller' and (created_at at time zone 'utc')::date = dd.day), 0), 2) as paid_vendors,
        round(coalesce((select sum(amount) from payouts where payee_type = 'rider' and (created_at at time zone 'utc')::date = dd.day), 0), 2) as paid_riders
      from days dd) d where d.orders > 0 or d.paid_vendors > 0 or d.paid_riders > 0 or d.refunds > 0), '[]'::json),
    'vendors', coalesce((select json_agg(x order by x.food desc) from (
      select k.id, k.name, round(sum(f.food), 2) as food, round(sum(f.fee), 2) as fee, round(sum(f.food - f.fee), 2) as earned,
             round(coalesce((select sum(amount) from payouts py where py.kitchen_id = k.id and py.payee_type = 'seller' and (py.created_at at time zone 'utc')::date between p_from and p_to), 0), 2) as paid
        from kitchens k join (select p.kitchen_id, pool_fee(p.id) as fee,
               (select coalesce(sum((coalesce(quote_price, unit_price) + addons_total) * qty), 0) from orders o where o.pool_id = p.id and o.status in ('paid', 'collected')) as food
             from pools p where p.order_date between p_from and p_to and p.status <> 'cancelled') f on f.kitchen_id = k.id
       group by k.id having sum(f.food) > 0) x), '[]'::json),
    'riders', coalesce((select json_agg(x order by x.trips desc) from (
      select r.id, r.name, count(p.id) as deliveries, round(sum(coalesce(p.trip_cost, pool_trip(p.id))), 2) as trips,
             round(coalesce((select sum(amount) from payouts py where py.rider_id = r.id and py.payee_type = 'rider' and (py.created_at at time zone 'utc')::date between p_from and p_to), 0), 2) as paid
        from riders r join pools p on p.rider_id = r.id and p.order_date between p_from and p_to and p.status = 'delivered'
       group by r.id) x), '[]'::json));
end $$;
revoke all on function admin_money_days(date, date) from public, anon;
grant execute on function admin_money_days(date, date) to authenticated;

select 'ChopPool database is up to date (version 38)' as result;
