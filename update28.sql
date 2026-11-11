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

select 'ChopPool database is up to date (version 28)' as result;
