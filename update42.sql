-- ============================================================
-- ChopPool update 42: online payments with Paystack (mobile money and card). Safe to run more than once.
-- Off until switched on: Settings › Payments decides who pays online (nobody, the team only for testing, or everyone).
-- How it works: the app places the order with the marker 'PAYSTACK' instead of a MoMo transaction ID; the order waits
-- as "paying online". The paystack function starts the payment for the amount the database works out, and marks the
-- order paid only after Paystack confirms it. Orders not paid by cut-off are cancelled and any wallet part comes back.
-- ============================================================

alter table settings add column if not exists pay_mode text not null default 'manual';
alter table settings drop constraint if exists settings_pay_mode_check;
alter table settings add constraint settings_pay_mode_check check (pay_mode in ('manual', 'team', 'paystack'));

alter table orders add column if not exists pay_via text;
alter table orders drop constraint if exists orders_pay_via_check;
alter table orders add constraint orders_pay_via_check check (pay_via is null or pay_via in ('paystack'));

create table if not exists paystack_payments (
  reference text primary key,
  order_id uuid not null references orders(id) on delete cascade,
  user_id uuid,
  amount numeric not null check (amount > 0),
  status text not null default 'started' check (status in ('started', 'paid', 'credited')),
  amount_paid numeric,
  channel text,
  created_at timestamptz not null default now(),
  paid_at timestamptz
);
create index if not exists paystack_payments_order on paystack_payments(order_id);
alter table paystack_payments enable row level security;
drop policy if exists "team reads paystack payments" on paystack_payments;
create policy "team reads paystack payments" on paystack_payments for select using (is_admin());

-- The marker: an order placed with 'PAYSTACK' becomes "paying online" (no MoMo reference), if online payments are on for this person
create or replace function orders_paystack_marker() returns trigger language plpgsql security definer set search_path = public as $$
declare v_mode text;
begin
  if new.momo_ref is not null and upper(trim(new.momo_ref)) = 'PAYSTACK' then
    select pay_mode into v_mode from settings where id = 1;
    if not (v_mode = 'paystack' or (v_mode = 'team' and is_admin())) then
      raise exception 'Online payment isn''t available right now. Pay by mobile money instead.';
    end if;
    new.momo_ref := null;
    new.pay_via := 'paystack';
  end if;
  return new;
end $$;
drop trigger if exists orders_paystack_marker on orders;
create trigger orders_paystack_marker before insert or update of momo_ref on orders
  for each row execute function orders_paystack_marker();

-- What is still owed for an order: the order plus the other dishes paid with it in one go (same rule as the app's tray)
create or replace function pay_group_due(p_order uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(greatest(0, order_total(x) - x.wallet_used)), 0)
  from orders m join orders x
    on x.id = m.id
    or (x.basket and x.status = 'pending'
        and (x.parent_id = m.id or (m.parent_id is not null and x.parent_id = m.parent_id and x.created_at = m.created_at and x.id <> m.id)))
  where m.id = p_order and x.status = 'pending';
$$;
revoke execute on function pay_group_due(uuid) from public, anon, authenticated;

-- Can this order be paid online now? Returns the amount, or a reason it can't. Used by the paystack function (server only).
create or replace function paystack_check_order(p_order uuid, p_user uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare o orders; s settings; v_due numeric;
begin
  select * into o from orders where id = p_order;
  if not found or o.user_id is distinct from p_user then return json_build_object('error', 'This order isn''t yours.'); end if;
  if o.status = 'paid' or o.status = 'collected' then return json_build_object('error', 'This order is already paid.'); end if;
  if o.status <> 'pending' or o.pay_via is distinct from 'paystack' then return json_build_object('error', 'This order can''t be paid online.'); end if;
  select * into s from settings where id = 1;
  if (now() at time zone 'utc') >= o.order_date + s.cutoff then return json_build_object('error', 'Orders have closed for this day.'); end if;
  v_due := pay_group_due(o.id);
  if v_due <= 0 then return json_build_object('error', 'Nothing left to pay on this order.'); end if;
  return json_build_object('amount', round(v_due, 2), 'code', o.code, 'order_date', o.order_date);
end $$;
revoke execute on function paystack_check_order(uuid, uuid) from public, anon, authenticated;

-- A confirmed Paystack payment (called by the paystack function after it has checked with Paystack). Runs once per reference.
-- Paid in full and the order still open: the order (and its tray) is paid. Anything else: the money goes to the customer's wallet.
create or replace function paystack_settle(p_ref text, p_amount numeric, p_channel text) returns json
language plpgsql security definer set search_path = public as $$
declare p paystack_payments; o orders;
begin
  select * into p from paystack_payments where reference = p_ref for update;
  if not found then return json_build_object('result', 'unknown'); end if;
  if p.status <> 'started' then return json_build_object('result', p.status, 'order_id', p.order_id); end if;
  select * into o from orders where id = p.order_id for update;
  if o.status = 'pending' and o.pay_via = 'paystack' and p_amount + 0.005 >= pay_group_due(o.id) then
    update paystack_payments set status = 'paid', amount_paid = p_amount, channel = p_channel, paid_at = now() where reference = p_ref;
    update orders set status = 'paid', momo_ref = left('PSK:' || p_ref, 40), pay_issue = null where id = o.id;
    return json_build_object('result', 'paid', 'order_id', o.id);
  end if;
  -- Order already closed, cancelled or paid another way, or the amount doesn't match: keep the money for the customer
  update paystack_payments set status = 'credited', amount_paid = p_amount, channel = p_channel, paid_at = now() where reference = p_ref;
  if p.user_id is not null and p_amount > 0 then
    insert into wallet_entries (user_id, amount, reason, order_id)
    values (p.user_id, p_amount, 'Money back: online payment for code ' || coalesce(o.code, '') || ' arrived after the order closed', p.order_id);
  end if;
  return json_build_object('result', 'credited', 'order_id', p.order_id);
end $$;
revoke execute on function paystack_settle(text, numeric, text) from public, anon, authenticated;

-- Unpaid online orders close at cut-off (with a few minutes' grace for payments already under way)
create or replace function paystack_expire() returns void language plpgsql security definer set search_path = public as $$
declare s settings;
begin
  select * into s from settings where id = 1;
  update orders set status = 'cancelled', cancel_reason = 'Payment not received', refund_due = 0, refund_needed = false
  where status = 'pending' and pay_via = 'paystack' and not basket and pay_issue is null
    and (now() at time zone 'utc') >= order_date + s.cutoff + interval '10 minutes'
    and not exists (select 1 from paystack_payments p where p.order_id = orders.id and p.status = 'paid');
end $$;
revoke execute on function paystack_expire() from public, anon, authenticated;

-- Your orders still waiting for an online payment (the app shows "Finish paying" for each)
create or replace function my_unpaid_online() returns table (id uuid, code text, order_date date, amount numeric, parent_id uuid)
language sql stable security definer set search_path = public as $$
  select o.id, o.code, o.order_date, round(pay_group_due(o.id), 2), o.parent_id
  from orders o, settings s
  where s.id = 1 and auth.uid() is not null and o.user_id = auth.uid() and o.status = 'pending' and o.pay_via = 'paystack'
    and not o.basket and (now() at time zone 'utc') < o.order_date + s.cutoff
  order by o.created_at;
$$;
revoke execute on function my_unpaid_online() from public, anon;
grant execute on function my_unpaid_online() to authenticated;

-- Housekeeping (runs every minute from the notify function) now also closes unpaid online orders first
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
