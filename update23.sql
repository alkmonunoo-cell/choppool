-- ============================================================
-- ChopPool update 23 (tray checkout, vendor confirm window, payer number). Safe to run more than once.
-- ============================================================

-- Vendor confirm window. Orders for a later day: until the confirm-by time that morning (8:30).
-- Same-day orders placed before 8:30: also until 8:30. After that: the usual minutes, never past the order cut-off.
create or replace function wait_deadline(p_created timestamptz, p_date date) returns timestamptz
language sql stable security definer set search_path = public as $$
  select case when p_date > (p_created at time zone 'utc')::date
              then (p_date + least(s.next_day_confirm_by, s.cutoff)) at time zone 'utc'
              else least((p_date + s.cutoff) at time zone 'utc',
                         greatest(p_created + make_interval(mins => s.accept_timeout_min),
                                  (p_date + least(s.next_day_confirm_by, s.cutoff)) at time zone 'utc')) end
  from settings s where s.id = 1;
$$;
revoke execute on function wait_deadline(timestamptz, date) from public, anon, authenticated;

-- Tray orders: extra dishes paid together with the first one (one payment, one code)
alter table orders add column if not exists basket boolean not null default false;
-- The mobile money number the customer paid from (refunds go back there)
alter table orders add column if not exists payer_phone text;
alter table orders add column if not exists payer_network text;
-- Saved payment methods (up to 3 mobile money numbers, one default), so they follow the account to any phone
alter table profiles add column if not exists pay_methods jsonb not null default '[]'::jsonb;

-- Several dishes from one vendor, one payment. Lines: [{item, qty, addons[], note}]
create or replace function place_basket(p_site uuid, p_lines jsonb, p_name text, p_phone text, p_ref text,
                                        p_use_wallet boolean default false, p_payer_phone text default null, p_payer_network text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  ln jsonb; n int := 0; r json; v_main uuid; v_code text; v_ids uuid[] := '{}'; v_total numeric := 0; v_use numeric := 0; v_left numeric;
  v_uid uuid := auth.uid(); o record; v_part numeric; v_meals int := 0; v_kitchen uuid; v_pp text := regexp_replace(coalesce(p_payer_phone, ''), '\D', '', 'g');
  s settings;
begin
  select * into s from settings where id = 1;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Your tray is empty.'; end if;
  if jsonb_array_length(p_lines) > 8 then raise exception 'Up to 8 different dishes in one order.'; end if;
  select coalesce(sum(greatest(1, coalesce((x ->> 'qty')::int, 1))), 0) into v_meals from jsonb_array_elements(p_lines) x;
  if v_meals > least(10, s.max_meals) then raise exception 'Up to % meals in one order.', least(10, s.max_meals); end if;
  if (select count(distinct m.kitchen_id) from jsonb_array_elements(p_lines) x join menu_items m on m.id = (x ->> 'item')::uuid) > 1 then
    raise exception 'Order from one vendor at a time.';
  end if;
  if v_pp <> '' and v_pp !~ '^0\d{9}$' then raise exception 'Enter the 10-digit mobile money number you paid from.'; end if;

  for ln in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    r := place_order(p_site, (ln ->> 'item')::uuid, greatest(1, coalesce((ln ->> 'qty')::int, 1)), p_name, p_phone, 'BASKET',
                     coalesce((select array_agg(a) from jsonb_array_elements_text(coalesce(ln -> 'addons', '[]'::jsonb)) a), '{}'),
                     ln ->> 'note', null, false, v_main);
    if n = 1 then v_main := (r ->> 'id')::uuid; v_code := r ->> 'code'; end if;
    v_ids := v_ids || (r ->> 'id')::uuid;
  end loop;

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
           status = case when v_part >= o.t then 'paid' else 'pending' end,
           momo_ref = case when o.id = v_main and v_use < v_total then trim(p_ref) else null end
     where id = o.id;
  end loop;
  return json_build_object('id', v_main, 'code', v_code, 'ids', v_ids, 'total', v_total, 'wallet_used', v_use, 'momo_due', v_total - v_use,
                           'status', (select status from orders where id = v_main), 'order_date', (select order_date from orders where id = v_main));
end $$;
grant execute on function place_basket(uuid, jsonb, text, text, text, boolean, text, text) to anon, authenticated;

-- Tray dishes follow the first dish: paid together, cancelled together if the payment never arrives
create or replace function basket_follow() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.parent_id is null and new.status is distinct from old.status then
    if new.status = 'paid' and old.status = 'pending' then
      update orders set status = 'paid' where parent_id = new.id and basket and status = 'pending';
    elsif new.status = 'cancelled' and new.cancel_reason = 'Payment not received' then
      update orders set status = 'cancelled', cancel_reason = 'Payment not received', refund_due = 0, refund_needed = false
       where parent_id = new.id and basket and status = 'pending';
    end if;
  end if;
  return null;
end $$;
drop trigger if exists basket_follow on orders;
create trigger basket_follow after update of status on orders for each row execute function basket_follow();

-- Cancel reasons: room for the customer's own words ("Other: ...")
create or replace function cancel_order(p_order uuid, p_reason text, p_refund text default 'wallet')
returns json language plpgsql security definer set search_path = public as $$
declare o orders; s settings; v_total numeric; v_momo numeric; v_credit numeric := 0; v_to text; c record; r json;
        v_wallet numeric := 0; v_momo_all numeric := 0;
begin
  select * into s from settings where id = 1;
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'Order not found.'; end if;
  if o.user_id is not null and o.user_id is distinct from auth.uid() then raise exception 'Sign in with the account that placed this order.'; end if;
  if o.status not in ('pending', 'paid', 'quote_requested', 'quoted') then raise exception 'This order can no longer be cancelled.'; end if;
  if (now() at time zone 'utc') >= o.order_date + s.cutoff then
    raise exception 'Orders close at %. The kitchen is already cooking, so it can''t be cancelled now.', to_char(s.cutoff, 'HH24:MI');
  end if;

  v_total := order_total(o);
  v_momo := greatest(0, v_total - o.wallet_used);

  if o.status in ('quote_requested', 'quoted') then
    v_to := 'nothing';
  elsif o.status = 'paid' and v_momo > 0 and o.user_id is not null and coalesce(p_refund, 'wallet') = 'wallet' then
    v_credit := v_momo; v_to := 'wallet';
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
end $$;


-- Say mobile money, not MoMo (MTN's brand), in messages customers see
create or replace function settle_payment(p_order uuid, p_ref text, p_use_wallet boolean)
returns json language plpgsql security definer set search_path = public as $$
declare o orders; v_total numeric; v_bal numeric; v_use numeric := 0; v_uid uuid := auth.uid();
begin
  select * into o from orders where id = p_order;
  v_total := order_total(o);
  if p_use_wallet and v_uid is not null and o.user_id = v_uid then
    v_bal := wallet_balance(v_uid);
    v_use := greatest(0, least(v_bal, v_total));
    if v_use > 0 then
      insert into wallet_entries (user_id, amount, reason, order_id) values (v_uid, -v_use, 'Paid for order ' || o.code, o.id);
    end if;
  end if;
  if v_use < v_total and (p_ref is null or char_length(trim(p_ref)) < 4) then
    raise exception 'Enter the mobile money transaction ID for the remaining %.', to_char(v_total - v_use, 'FM999990.00');
  end if;
  update orders set wallet_used = wallet_used + v_use,
    momo_ref = case when v_use < v_total then trim(p_ref) else momo_ref end,
    status = case when v_use >= v_total then 'paid' else 'pending' end
  where id = o.id;
  return json_build_object('total', v_total, 'wallet_used', v_use, 'momo_due', v_total - v_use);
end $$;

create or replace function fix_payment(p_order uuid, p_phone text, p_ref text)
returns json language plpgsql security definer set search_path = public as $$
declare o orders; s settings; v_ref text := upper(regexp_replace(coalesce(p_ref, ''), '\s', '', 'g'));
begin
  select * into o from orders where id = p_order;
  if not found then raise exception 'Order not found.'; end if;
  if not ((auth.uid() is not null and o.user_id = auth.uid())
          or regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') = regexp_replace(coalesce(o.phone, ''), '\D', '', 'g')) then
    raise exception 'This order isn''t yours.';
  end if;
  if o.status <> 'pending' or o.pay_issue is null then raise exception 'This payment doesn''t need fixing.'; end if;
  select * into s from settings where id = 1;
  if (now() at time zone 'utc') >= o.order_date + s.cutoff then raise exception 'Orders have closed for this day.'; end if;
  if v_ref !~ '^[A-Z0-9.]{6,30}$' then raise exception 'Enter the mobile money transaction ID from your payment message.'; end if;
  update orders set momo_ref = case when o.pay_issue = 'short' and o.momo_ref is not null then left(o.momo_ref || ' + ' || v_ref, 120) else v_ref end,
                    pay_issue = null
  where id = o.id;
  return json_build_object('ok', true);
end $$;

-- Admin: which of these orders can get a phone alert (the customer turned alerts on for them)
create or replace function admin_alert_reach(p_ids uuid[]) returns uuid[]
language sql stable security definer set search_path = public as $$
  select case when not is_admin() then '{}'::uuid[] else coalesce(array_agg(o.id), '{}') end
  from orders o
  where o.id = any(p_ids)
    and exists (select 1 from push_subs ps where o.id = any(ps.order_ids) or (o.user_id is not null and ps.user_id = o.user_id));
$$;
grant execute on function admin_alert_reach(uuid[]) to authenticated;

select 1;
