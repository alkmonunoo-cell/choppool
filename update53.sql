-- ChopPool update 53: customers pay the Paystack fee; alerts only after payment, never about your own actions.
-- Safe to run more than once.

-- ---------- 1. Paystack fee paid by the customer ----------
-- Settings › Payments: from this day the customer pays Paystack's 1.95% (switched on in Paystack). Blank: ChopPool pays it.
alter table settings add column if not exists paystack_fee_from date;
update settings set paystack_fee_from = '2026-11-24' where id = 1 and paystack_fee_from is null
  and not exists (select 1 from settings where id = 1 and paystack_fee_from is not null);
-- The fee the customer paid on top of the order (kept by Paystack); amount_paid stays the order amount
alter table paystack_payments add column if not exists customer_fee numeric not null default 0;

-- A confirmed Paystack payment. Paid in full and the order still open: the order is paid. Anything else: the order
-- amount goes to the customer's wallet. The Paystack fee the customer paid is never refunded (decided 24 Nov 2026).
create or replace function paystack_settle(p_ref text, p_amount numeric, p_channel text) returns json
language plpgsql security definer set search_path = public as $$
declare p paystack_payments; o orders; v_fee numeric := 0; v_net numeric := p_amount;
begin
  select * into p from paystack_payments where reference = p_ref for update;
  if not found then return json_build_object('result', 'unknown'); end if;
  if p.status <> 'started' then return json_build_object('result', p.status, 'order_id', p.order_id); end if;
  -- More than we asked for = Paystack added its fee for the customer
  if p_amount > p.amount + 0.005 then v_fee := round(p_amount - p.amount, 2); v_net := p.amount; end if;
  select * into o from orders where id = p.order_id for update;
  if o.status = 'pending' and o.pay_via = 'paystack' and v_net + 0.005 >= pay_group_due(o.id) then
    update paystack_payments set status = 'paid', amount_paid = v_net, customer_fee = v_fee, channel = p_channel, paid_at = now() where reference = p_ref;
    update orders set status = 'paid', momo_ref = left('PSK:' || p_ref, 40), pay_issue = null where id = o.id;
    return json_build_object('result', 'paid', 'order_id', o.id);
  end if;
  -- Order already closed, cancelled or paid another way, or the amount doesn't match: keep the money for the customer
  update paystack_payments set status = 'credited', amount_paid = v_net, customer_fee = v_fee, channel = p_channel, paid_at = now() where reference = p_ref;
  if p.user_id is not null and v_net > 0 then
    insert into wallet_entries (user_id, amount, reason, order_id)
    values (p.user_id, v_net, 'Money back: online payment for code ' || coalesce(o.code, '') || ' arrived after the order closed', p.order_id);
  end if;
  return json_build_object('result', 'credited', 'order_id', p.order_id);
end $$;
revoke execute on function paystack_settle(text, numeric, text) from public, anon, authenticated;

-- Money report: ChopPool only bears the Paystack fee on payments before the customer started paying it
CREATE OR REPLACE FUNCTION public.admin_money_days(p_from date, p_to date)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
                         where o.order_date = dd.day and pp.status in ('paid', 'credited')
                           -- update 53: from Settings › Payments "Customers pay the Paystack fee from", the customer pays it, not ChopPool
                           and coalesce(pp.customer_fee, 0) = 0
                           and (o.order_date < (select paystack_fee_from from settings where id = 1)) is not false), 0), 2) as paystack_fees,
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
end $function$;

-- ---------- 2. A pool only counts once someone has paid into it ----------
-- committed_at: when the customer finished paying (wallet or Paystack confirmed, or a mobile money transaction ID
-- sent for the team to check). live_at: the first time anyone paid into the pool. Until then the pool is hidden from
-- the building, the vendor and alerts.
alter table orders add column if not exists committed_at timestamptz;
alter table pools add column if not exists live_at timestamptz;

create or replace function order_is_committed(o orders) returns boolean language sql immutable as $$
  select o.status in ('paid', 'collected')
      or (o.status = 'pending' and o.pay_via is distinct from 'paystack' and o.momo_ref is not null and upper(o.momo_ref) <> 'BASKET' and o.pay_issue is null)   -- tray dishes follow the first one
$$;

create or replace function orders_mark_committed() returns trigger language plpgsql as $$
begin
  if new.committed_at is null and order_is_committed(new) then new.committed_at := now(); end if;
  return new;
end $$;
drop trigger if exists zz_orders_committed on orders;
create trigger zz_orders_committed before insert or update on orders for each row execute function orders_mark_committed();

-- The pool goes live with its first payment; the vendor's time to confirm starts then
create or replace function pools_go_live() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.committed_at is not null and (tg_op = 'INSERT' or old.committed_at is null) then
    update pools set live_at = now(), created_at = case when status = 'waiting' then now() else created_at end
     where id = new.pool_id and live_at is null;
  end if;
  return null;
end $$;
drop trigger if exists zz_pools_go_live on orders;
create trigger zz_pools_go_live after insert or update on orders for each row execute function pools_go_live();

-- Existing orders and pools: anything already paid counts from when it was made
update orders o set committed_at = o.created_at where o.committed_at is null and order_is_committed(o);
update pools p set live_at = p.created_at
 where p.live_at is null and exists (select 1 from orders o where o.pool_id = p.id and o.committed_at is not null);

-- Building activity ("someone just ordered"): paid orders only, timed by the payment; uid is a one-way fingerprint
-- of the customer's account so the app never alerts you about your own order
drop view if exists recent_activity;
create view recent_activity as
select left(encode(sha256(convert_to(o.id::text, 'UTF8')), 'hex'), 16) as id,
       o.order_date, o.site_id, o.kitchen_id, o.pool_id, o.item_name, o.qty, o.committed_at as created_at,
       case when o.user_id is not null then left(encode(sha256(convert_to(o.user_id::text, 'UTF8')), 'hex'), 16) end as uid
  from orders o
 where o.status not in ('cancelled', 'quote_requested', 'quoted') and o.committed_at is not null
   and o.committed_at > now() - interval '6 hours';
revoke all on recent_activity from anon, authenticated, public;
grant select on recent_activity to anon, authenticated;

CREATE OR REPLACE FUNCTION public.board_data(p_date date)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform housekeeping();
  return json_build_object(
    'pools', coalesce((select json_agg(x) from (select p.id, p.order_date, p.site_id, p.kitchen_id, p.seq, p.status, p.created_at, pool_meals(p.id) as meals,
                                                       case when p.status = 'waiting' then wait_deadline(p.created_at, p.order_date) end as wait_until,
                                                       pool_free(p.id) as free,
                                                       -- update 53: who started it (fingerprint of the first order, like the activity feed)
                                                       (select left(encode(sha256(convert_to(f.id::text, 'UTF8')), 'hex'), 16) from orders f where f.pool_id = p.id and f.parent_id is null order by f.created_at limit 1) as first_fp
                                                  from pools p where p.order_date = p_date and p.status <> 'cancelled' and p.live_at is not null) x), '[]'::json),
    'load', coalesce((select json_object_agg(kitchen_id, meals) from (select kitchen_id, sum(qty)::int as meals from orders
                                                  where order_date = p_date and status <> 'cancelled' group by 1) l), '{}'::json),
    'activity', coalesce((select json_agg(a order by a.created_at desc) from (select * from recent_activity order by created_at desc limit 50) a), '[]'::json),
    'open', coalesce((select json_agg(k.id) from kitchens k where k.active and kitchen_is_open(k.id, p_date)), '[]'::json),
    'off', coalesce((select json_agg(k.id) from kitchens k where k.active and p_date = any(k.paused_dates)
                       and not exists (select 1 from kitchen_days d where d.kitchen_id = k.id and d.order_date = p_date)), '[]'::json));
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
        -- update 53: a pool shows once someone has paid into it (custom orders to price show straight away)
        and (p.live_at is not null or exists (select 1 from orders q where q.pool_id = p.id and q.status in ('quote_requested', 'quoted')))
    ), '[]'::json));
end $function$;

CREATE OR REPLACE FUNCTION public.housekeeping()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s settings;
begin
  perform paystack_expire();   -- update 42: unpaid online orders close at cut-off (their wallet part comes back below)
  select * into s from settings where id = 1;

  -- Vendors who didn't confirm in time: confirmed payments come back to the wallet (account holders) or by MoMo (guests)
  with expired as (
    update pools set status = 'cancelled'
    where status = 'waiting' and live_at is not null and now() >= wait_deadline(created_at, order_date)   -- update 53: only pools someone has paid into
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
  -- update 53: a pool nobody paid into goes away quietly once orders close and nothing is left in it
  update pools p set status = 'cancelled'
   where p.live_at is null and p.status in ('waiting', 'collecting')
     and (now() at time zone 'utc') >= p.order_date + s.cutoff + interval '15 minutes'
     and not exists (select 1 from orders o where o.pool_id = p.id and o.status <> 'cancelled');
end $function$;

select 1;
