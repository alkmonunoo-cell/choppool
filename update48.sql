-- ChopPool update 48: checkout no longer asks for name and phone (the account has them)
-- The order takes the name from the account and the phone from the account or saved profile, or the mobile money number
-- they pay from. A signed-in customer paying online with no phone on file can still order: the order's phone is then empty.
-- Safe to run more than once.

alter table orders alter column phone drop not null;

alter table orders drop column if exists cust;   -- (not used: reports work out "phone or account" themselves)

-- Fill the phone from the profile when the app sends none; an order needs a phone or an account
create or replace function orders_fill_phone() returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.phone := nullif(regexp_replace(coalesce(new.phone, ''), '\D', '', 'g'), '');
  if new.phone is null and new.user_id is not null then
    select phone into new.phone from profiles where user_id = new.user_id and phone ~ '^0[0-9]{9}$';
  end if;
  if new.phone is null and new.user_id is null then raise exception 'Sign in to order.'; end if;
  return new;
end $$;
drop trigger if exists orders_fill_phone on orders;
create trigger orders_fill_phone before insert on orders for each row execute function orders_fill_phone();

-- Weekly report: a customer is their phone, or their account when the order has no phone
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
  with o as (select o.*, coalesce(o.phone, o.user_id::text) as cust, p.status as pool_status from orders o join pools p on p.id = o.pool_id where o.order_date between v0 and w1),
  live as (select * from o where status in ('paid', 'collected', 'pending')),
  cur as (select * from live where order_date between w0 and w1),
  prev as (select * from live where order_date between v0 and v1),
  pl as (select p.*, pool_meals(p.id) as meals from pools p where p.order_date between v0 and w1),
  firsts as (select coalesce(phone, user_id::text) as cust, min(order_date) as first_day from orders where status in ('paid', 'collected', 'pending') group by 1),
  head as (
    select wk, sum(qty)::int as meals, count(*) filter (where parent_id is null)::int as orders, count(distinct cust)::int as customers,
           count(distinct cust) filter (where (select first_day from firsts f where f.cust = x.cust) >= x.ws)::int as new_customers
    from (select *, 'cur' as wk, w0 as ws from cur union all select *, 'prev', v0 from prev) x group by wk),
  rep as (
    select wk, round(100.0 * count(*) filter (where n >= 2) / nullif(count(*), 0))::int as repeat_rate
    from (select 'cur' as wk, cust, count(distinct order_date) as n from live where order_date between w0 - 7 and w1 and cust in (select cust from cur) group by cust
          union all select 'prev', cust, count(distinct order_date) from live where order_date between v0 - 7 and v1 and cust in (select cust from prev) group by cust) r group by wk),
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
               (select si.name from cur c3 join sites si on si.id = c3.site_id where c3.cust = c.cust group by si.name order by count(*) desc limit 1) as building,
               case when is_super() then max(c.phone) end as phone,
               count(*) filter (where parent_id is null)::int as orders, sum(qty)::int as meals
        from cur c group by c.cust order by sum(qty) desc, count(*) desc limit 15) c2), '[]'::json),
    'vendors', coalesce((select json_agg(v order by v.meals desc) from (
        select k.public_name as name, coalesce(sum(c.qty), 0)::int as meals,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status <> 'cancelled' and pl.meals > 0)::int as pools,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status = 'cancelled'
                  and exists (select 1 from orders x where x.pool_id = pl.id and x.cancel_reason = 'The seller did not confirm in time'))::int as expired,
               (select round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*) filter (where pl.delivered_at is not null), 0))
                  from pl where pl.kitchen_id = k.id and pl.order_date >= w0)::int as on_time,
               (select count(*) from o where o.kitchen_id = k.id and o.order_date >= w0 and o.cancel_reason like 'The seller can''t%')::int as declined,
               (select count(*) from (select cust from live where live.kitchen_id = k.id and live.order_date between w0 - 28 and w1 group by cust having count(distinct order_date) >= 2) r)::int as repeat_customers,
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
