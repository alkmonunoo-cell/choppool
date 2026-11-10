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

select 'ChopPool database is up to date (version 26)' as result;
