-- ChopPool update 24
-- Tray checkout: when the wallet covers only part of the total, every dish stays waiting for the
-- mobile money check (before, the first dish could show as paid on its own).
-- Handing over a code moves the pool to Delivered if nobody tapped it.
-- Vendors can say "not cooking today" while customers wait (kitchen_skip_day); a paused day takes no orders.
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
           status = case when v_use >= v_total then 'paid' else 'pending' end,   -- one payment: all dishes paid together
           momo_ref = case when o.id = v_main and v_use < v_total then trim(p_ref) else null end
     where id = o.id;
  end loop;
  return json_build_object('id', v_main, 'code', v_code, 'ids', v_ids, 'total', v_total, 'wallet_used', v_use, 'momo_due', v_total - v_use,
                           'status', (select status from orders where id = v_main), 'order_date', (select order_date from orders where id = v_main));
end $$;

-- A code handed over at the drop point also marks the bag as delivered (the rider may have forgotten to tap it)
CREATE OR REPLACE FUNCTION public.collect_code(p_token text, p_code text, p_date date, p_pool uuid DEFAULT NULL::uuid, p_unpaid text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v text := norm_code(p_code); n int; v_done int; who text; v_ids uuid[]; v_name text; v_items text; v_qty int; v_paid boolean;
begin
  select count(*), count(*) filter (where o2.status = 'collected'),
         array_agg(o2.id order by o2.created_at) filter (where o2.status <> 'collected'),
         (array_agg(o2.customer_name order by o2.created_at))[1],
         string_agg(o2.qty || ' × ' || o2.item_name, ' + ' order by o2.created_at) filter (where o2.status <> 'collected'),
         sum(o2.qty) filter (where o2.status <> 'collected'),
         bool_and(o2.status in ('paid', 'collected'))
    into n, v_done, v_ids, v_name, v_items, v_qty, v_paid
    from orders o2
    join pools p on p.id = o2.pool_id
    left join riders r on r.id = p.rider_id
    join sites si on si.id = o2.site_id
    join kitchens k on k.id = o2.kitchen_id
   where o2.order_date = p_date and o2.code = v and o2.status in ('pending', 'paid', 'collected')
     and (p_pool is null or o2.pool_id = p_pool)
     and (r.token = p_token or si.host_token = p_token or (k.token = p_token and (k.delivery_mode = 'runner' or pool_free(p.id))));
  if n = 0 then raise exception 'No order with code % for you today.', coalesce(nullif(v, ''), p_code); end if;
  if v_done = n then raise exception 'Code % was already collected.', v; end if;
  -- Not paid yet: the person handing over chooses "Collect cash" or "Hold the meal" first
  if not v_paid and coalesce(p_unpaid, '') <> 'cash' then
    raise exception 'UNPAID:%:%', v_name, coalesce((select sum(order_total(o3) - o3.wallet_used - coalesce(o3.carried_amount, 0)) from orders o3 where o3.id = any(v_ids) and o3.status = 'pending'), 0);
  end if;
  who := case when exists (select 1 from riders where token = p_token) then 'rider'
              when exists (select 1 from kitchens where token = p_token) then 'runner' else 'host' end;
  update orders set status = 'collected', collected_at = now(), collected_by = who || case when p_unpaid = 'cash' and not v_paid then ' (cash)' else '' end where id = any(v_ids);
  -- A meal handed over means the bag is here: move the pool to Delivered if nobody tapped it yet
  update pools set status = 'delivered', delivered_at = coalesce(delivered_at, now())
   where id in (select pool_id from orders where id = any(v_ids)) and status in ('accepted', 'ready', 'picked_up', 'arriving');
  return json_build_object('name', v_name, 'items', v_items, 'item_name', v_items, 'qty', v_qty, 'was_paid', v_paid, 'code', v);
end $function$;

-- A vendor who can't cook can say so straight away, instead of customers waiting until the confirm time runs out.
-- Waiting pools are cancelled with the same money-back rules as a vendor who didn't confirm, and the day is paused.
create or replace function kitchen_skip_day(p_token text, p_date date)
returns json language plpgsql security definer set search_path = public as $$
declare k kitchens; v_pools uuid[]; v_n int := 0;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  if exists (select 1 from pools p where p.kitchen_id = k.id and p.order_date = p_date and p.status not in ('waiting', 'cancelled') and pool_meals(p.id) > 0) then
    raise exception 'You already confirmed this day and have orders. Message ChopPool if you can''t cook them.';
  end if;
  with gone as (
    update pools set status = 'cancelled' where kitchen_id = k.id and order_date = p_date and status = 'waiting' returning id)
  select coalesce(array_agg(id), '{}') into v_pools from gone;
  update orders o set status = 'cancelled', cancel_reason = 'The vendor isn''t cooking today',
                      refund_due = case when o.status in ('paid', 'collected') then greatest(0, order_total(o) - o.wallet_used) else 0 end,
                      refund_needed = (o.momo_ref is not null and not (o.user_id is not null and o.status in ('paid', 'collected')))
   where o.pool_id = any(v_pools) and o.status <> 'cancelled';
  get diagnostics v_n = row_count;
  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.wallet_used, 'Refund: the vendor isn''t cooking today', o.id from orders o
   where o.pool_id = any(v_pools) and o.status = 'cancelled' and o.wallet_used > 0 and o.user_id is not null
     and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.amount > 0 and w.reason like 'Refund:%');
  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.refund_due, 'Money back: the vendor isn''t cooking today, code ' || o.code, o.id from orders o
   where o.pool_id = any(v_pools) and o.status = 'cancelled' and o.refund_due > 0 and o.user_id is not null and not o.refund_needed
     and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.reason like 'Money back:%');
  update kitchens set paused_dates = array(select distinct x from unnest(paused_dates || p_date) x where x >= (now() at time zone 'utc')::date - 1) where id = k.id;
  delete from kitchen_days where kitchen_id = k.id and order_date = p_date;
  return json_build_object('orders', v_n, 'pools', coalesce(array_length(v_pools, 1), 0));
end $$;
revoke all on function kitchen_skip_day(text, date) from public;
grant execute on function kitchen_skip_day(text, date) to anon, authenticated;

-- A vendor who paused a day ("not cooking") can't receive orders for it, and the menu says so
create or replace function order_paused_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where id = new.kitchen_id;
  if found and new.order_date = any(k.paused_dates)
     and not exists (select 1 from kitchen_days where kitchen_id = k.id and order_date = new.order_date) then
    raise exception '% isn''t cooking %. Choose another vendor.', k.public_name,
      case when new.order_date = (now() at time zone 'utc')::date then 'today' else 'on that day' end;
  end if;
  return new;
end $$;
drop trigger if exists order_paused_guard on orders;
create trigger order_paused_guard before insert on orders for each row execute function order_paused_guard();

create or replace function board_data(p_date date) returns json
language plpgsql volatile security definer set search_path = public as $$
begin
  perform housekeeping();
  return json_build_object(
    'pools', coalesce((select json_agg(x) from (select p.id, p.order_date, p.site_id, p.kitchen_id, p.seq, p.status, p.created_at, pool_meals(p.id) as meals,
                                                       case when p.status = 'waiting' then wait_deadline(p.created_at, p.order_date) end as wait_until,
                                                       pool_free(p.id) as free
                                                  from pools p where p.order_date = p_date and p.status <> 'cancelled') x), '[]'::json),
    'load', coalesce((select json_object_agg(kitchen_id, meals) from (select kitchen_id, sum(qty)::int as meals from orders
                                                  where order_date = p_date and status <> 'cancelled' group by 1) l), '{}'::json),
    'activity', coalesce((select json_agg(a order by a.created_at desc) from (select * from recent_activity order by created_at desc limit 50) a), '[]'::json),
    'open', coalesce((select json_agg(k.id) from kitchens k where k.active and kitchen_is_open(k.id, p_date)), '[]'::json),
    'off', coalesce((select json_agg(k.id) from kitchens k where k.active and p_date = any(k.paused_dates)
                       and not exists (select 1 from kitchen_days d where d.kitchen_id = k.id and d.order_date = p_date)), '[]'::json));
end $$;

-- No cancelling once the vendor has confirmed the final batch (the app already hides the button)
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
  if exists (select 1 from pools p where p.id = o.pool_id and p.status not in ('waiting', 'collecting')) then
    raise exception 'The vendor is already cooking this order, so it can''t be cancelled now.';
  end if;
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

select 'ChopPool database is up to date (version 24)' as result;
