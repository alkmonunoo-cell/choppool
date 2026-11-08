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
