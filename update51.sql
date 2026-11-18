-- ChopPool update 51: reports start from a chosen day (test days before it are left out)
-- Settings › Reports start from. Nothing is deleted. Safe to run more than once.

alter table settings add column if not exists reports_from date;
update settings set reports_from = '2026-11-12' where id = 1 and reports_from is null;   -- real customer testing began Thu 12 Nov 2026

create or replace function admin_money_days(p_from date, p_to date) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_super() then raise exception 'Only the owner can see the money report.'; end if;
  if p_to < p_from then raise exception 'The end date is before the start date.'; end if;
  if p_to - p_from > 370 then raise exception 'Pick a period of a year or less.'; end if;
  -- Nothing before the day real use started (Settings › Reports start from)
  p_from := greatest(p_from, coalesce((select reports_from from settings where id = 1), p_from));
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
        round(coalesce((select sum(coalesce(trip_cost, trip_price, pool_trip(pl.id))) from pl where order_date = dd.day and not no_trip and rider_id is not null), 0), 2) as trips_riders,
        round(coalesce((select sum(coalesce(trip_cost, trip_price, pool_trip(pl.id))) from pl where order_date = dd.day and not no_trip and rider_id is null), 0), 2) as trips_apps,
        (select count(*) from pl where order_date = dd.day and not no_trip and trip_cost is null and trip_price is null) as trips_estimated,
        -- Cashback: what was paid into wallets, plus what's still due on orders not received yet (worked out the same way)
        round(coalesce((select sum(w.amount) from wallet_entries w join orders o on o.id = w.order_id where o.order_date = dd.day and w.reason like 'Delivery cashback%'), 0)
            + coalesce((select sum(order_cashback(p2.id)) from paid p2 join pools px on px.id = p2.pool_id
                         where p2.order_date = dd.day and p2.parent_id is null and p2.user_id is not null and not p2.cashback_posted and px.status <> 'cancelled'
                           and not exists (select 1 from wallet_entries w2 where w2.order_id = p2.id and w2.reason like 'Delivery cashback%')), 0), 2) as cashback,
        (select count(*) from paid p2 join pools px on px.id = p2.pool_id
          where p2.order_date = dd.day and p2.parent_id is null and p2.user_id is not null and not p2.cashback_posted and px.status <> 'cancelled'
                           and not exists (select 1 from wallet_entries w2 where w2.order_id = p2.id and w2.reason like 'Delivery cashback%') and order_cashback(p2.id) > 0) as cashback_estimated,
        -- Wallet credit given to sort out problems with that day's orders, and credit the team added by hand that day
        round(coalesce((select sum(w.amount) from wallet_entries w join orders o on o.id = w.order_id where o.order_date = dd.day and w.reason like 'Sorted:%'), 0)
            + coalesce((select sum(w.amount) from wallet_entries w where w.order_id is null and w.created_by <> 'system' and (w.created_at at time zone 'utc')::date = dd.day), 0), 2) as credits,
        -- Paystack keeps 1.95% of each online payment (Ghana, cards and mobile money)
        round(coalesce((select sum(coalesce(pp.amount_paid, pp.amount)) * 0.0195 from paystack_payments pp join orders o on o.id = pp.order_id
                         where o.order_date = dd.day and pp.status in ('paid', 'credited')), 0), 2) as paystack_fees,
        round(coalesce((select sum(w.amount) from wallet_entries w join orders o on o.id = w.order_id where o.order_date = dd.day and w.amount > 0 and (w.reason like 'Refund%' or w.reason like 'Money back%')), 0)
            + coalesce((select sum(refund_amount) from orders where order_date = dd.day and refunded_at is not null), 0), 2) as refunds,
        round(coalesce((select sum(amount) from payouts where payee_type = 'seller' and (created_at at time zone 'utc')::date = dd.day), 0), 2) as paid_vendors,
        round(coalesce((select sum(amount) from payouts where payee_type = 'rider' and (created_at at time zone 'utc')::date = dd.day), 0), 2) as paid_riders
      from days dd) d where d.orders > 0 or d.paid_vendors > 0 or d.paid_riders > 0 or d.refunds > 0 or d.credits <> 0), '[]'::json),
    'vendors', coalesce((select json_agg(x order by x.food desc) from (
      select k.id, k.name, round(sum(f.food), 2) as food, round(sum(f.fee), 2) as fee, round(sum(f.food - f.fee), 2) as earned,
             round(coalesce((select sum(amount) from payouts py where py.kitchen_id = k.id and py.payee_type = 'seller' and (py.created_at at time zone 'utc')::date between p_from and p_to), 0), 2) as paid
        from kitchens k join (select p.kitchen_id, pool_fee(p.id) as fee,
               (select coalesce(sum((coalesce(quote_price, unit_price) + addons_total) * qty), 0) from orders o where o.pool_id = p.id and o.status in ('paid', 'collected')) as food
             from pools p where p.order_date between p_from and p_to and p.status <> 'cancelled') f on f.kitchen_id = k.id
       group by k.id having sum(f.food) > 0) x), '[]'::json),
    'riders', coalesce((select json_agg(x order by x.trips desc) from (
      select r.id, r.name, count(p.id) as deliveries, round(sum(coalesce(p.trip_cost, p.trip_price, pool_trip(p.id))), 2) as trips,
             round(coalesce((select sum(amount) from payouts py where py.rider_id = r.id and py.payee_type = 'rider' and (py.created_at at time zone 'utc')::date between p_from and p_to), 0), 2) as paid
        from riders r join pools p on p.rider_id = r.id and p.order_date between p_from and p_to and p.status = 'delivered'
       group by r.id) x), '[]'::json));
end $$;

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
  -- Leave out days before real use started (Settings › Reports start from)
  w0 := greatest(w0, coalesce(s.reports_from, w0)); v0 := greatest(v0, coalesce(s.reports_from, v0));
  return (
  with o as (select o.*, coalesce(o.phone, o.user_id::text) as cust, p.status as pool_status from orders o join pools p on p.id = o.pool_id where o.order_date between v0 and w1),
  live as (select * from o where status in ('paid', 'collected', 'pending')),
  cur as (select * from live where order_date between w0 and w1),
  prev as (select * from live where order_date between v0 and v1),
  pl as (select p.*, pool_meals(p.id) as meals from pools p where p.order_date between v0 and w1),
  firsts as (select coalesce(phone, user_id::text) as cust, min(order_date) as first_day from orders where status in ('paid', 'collected', 'pending') and order_date >= coalesce((select reports_from from settings where id = 1), '-infinity'::date) group by 1),
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
    'week_start', p_week_start, 'week_end', w1,
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
