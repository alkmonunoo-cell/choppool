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
