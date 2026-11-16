-- ============================================================
-- ChopPool update 44: no refund when nothing was paid; wallet changes by the team need the password again. Safe to run more than once.
-- ============================================================

-- Cancelling an order that was never paid (an online payment that didn't go through) just cancels it: no refund to send.
-- Any wallet part still comes back to the wallet, as before.
create or replace function cancel_order(p_order uuid, p_reason text, p_refund text DEFAULT 'wallet'::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o orders; s settings; v_total numeric; v_momo numeric; v_credit numeric := 0; v_to text; c record; r json;
        v_wallet numeric := 0; v_momo_all numeric := 0; v_sent boolean;
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

  -- Was any mobile money actually sent for it? A MoMo transaction ID on the order, or on the first dish it was paid with.
  -- An online (Paystack) order still waiting has no payment yet.
  v_sent := o.momo_ref is not null
    or (o.basket and exists (select 1 from orders m where not m.basket and m.momo_ref is not null
          and (m.id = o.parent_id or (o.parent_id is not null and m.parent_id = o.parent_id and m.created_at = o.created_at))));
  v_total := order_total(o);
  v_momo := greatest(0, v_total - o.wallet_used);

  if o.status in ('quote_requested', 'quoted') then
    v_to := 'nothing';
  elsif o.status = 'paid' and v_momo > 0 and o.user_id is not null and coalesce(p_refund, 'wallet') = 'wallet' then
    v_credit := v_momo; v_to := 'wallet';
  elsif v_momo > 0 and o.status = 'pending' and not v_sent then
    v_to := 'nothing';   -- update 44: nothing was paid (online payment never made), so there's nothing to refund
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
end $function$;

-- Paid-for-nothing orders already flagged for a refund by mistake: clear them
update orders set refund_needed = false, refund_due = 0
where status = 'cancelled' and refund_needed and pay_via = 'paystack' and momo_ref is null
  and not exists (select 1 from paystack_payments p where p.order_id = orders.id and p.status = 'paid');

-- Adjusting a customer's wallet from the app needs the team member's password, entered in the last 10 minutes.
-- (Checked from the sign-in itself, so it can't be skipped by calling the database directly. Wallet changes the
-- database makes on its own, like refunds and cashback, are not affected.)
create or replace function wallet_entries_need_password() returns trigger language plpgsql set search_path = public as $$
declare v_amr jsonb;
begin
  if current_user = 'authenticated' then
    v_amr := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb -> 'amr', 'null'::jsonb);
    if jsonb_typeof(v_amr) = 'array' and not exists (
      select 1 from jsonb_array_elements(v_amr) e
      where e ->> 'method' = 'password' and (e ->> 'timestamp')::numeric > extract(epoch from now()) - 600) then
      raise exception 'For safety, enter your password again to adjust a wallet.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists wallet_entries_need_password on wallet_entries;
create trigger wallet_entries_need_password before insert on wallet_entries for each row execute function wallet_entries_need_password();
