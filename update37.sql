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
