-- ChopPool update 10: payment details, customer cancellations, full delivery at checkout + cashback (also for guests)
-- Paste into Supabase > SQL Editor > New query, then Run. Run update-7 and update-8 first. Safe to run more than once.
-- (You can skip update-9: this replaces it.)

-- 1. MoMo network for the payment instructions
alter table settings add column if not exists momo_network text not null default 'MTN';

-- 2. Checkout charges FULL delivery: the lower of the max fee per meal and the whole trip cost by distance.
--    After the cut-off, everyone gets back what the pool saved, as wallet cashback.
create or replace function place_order(p_site uuid, p_item uuid, p_qty int, p_name text, p_phone text, p_ref text,
                                       p_addons text[] default '{}', p_note text default null,
                                       p_special text default null, p_use_wallet boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare
  s settings; m menu_items; k kitchens; si sites; pl pools;
  d date := current_order_date();
  v_load int; v_code text; v_id uuid; v_add jsonb; v_add_total numeric; v_special text; v_pay json;
  v_open boolean;
begin
  perform housekeeping();
  select * into s from settings where id = 1;
  select * into m from menu_items where id = p_item and active;
  if not found then raise exception 'That dish is no longer available.'; end if;
  select * into k from kitchens where id = m.kitchen_id and active;
  if not found then raise exception 'That seller is not taking orders.'; end if;
  select * into si from sites where id = p_site and active;
  if not found then raise exception 'That drop point is not active.'; end if;
  if k.site_id is not null and k.site_id <> si.id then raise exception 'That seller only delivers to another drop point.'; end if;
  if p_qty is null or p_qty < 1 or p_qty > least(5, s.max_meals) then raise exception 'Choose between 1 and 5 meals.'; end if;

  v_special := nullif(trim(coalesce(p_special, '')), '');
  if v_special is not null and d = (now() at time zone 'utc')::date and (now() at time zone 'utc')::time >= s.special_cutoff then
    raise exception 'Special requests close at %. You can still order from the menu.', to_char(s.special_cutoff, 'HH24:MI');
  end if;

  select coalesce(jsonb_agg(a), '[]'::jsonb), coalesce(sum((a ->> 'price')::numeric), 0)
    into v_add, v_add_total
  from jsonb_array_elements(m.addons) a where a ->> 'name' = any(coalesce(p_addons, '{}'));

  perform pg_advisory_xact_lock(hashtext('cp' || k.id::text || d::text));

  select coalesce(sum(qty), 0) into v_load from orders where kitchen_id = k.id and order_date = d and status <> 'cancelled';
  if v_load + p_qty > k.capacity then raise exception 'This menu is fully booked for today. Try another one.'; end if;

  v_open := kitchen_is_open(k.id, d);
  if not v_open then
    if exists (select 1 from pools where kitchen_id = k.id and order_date = d and status = 'waiting') then
      raise exception '% has not confirmed today yet. Try again in a few minutes.', k.public_name;
    end if;
    insert into pools (order_date, site_id, kitchen_id, seq, status)
    values (d, si.id, k.id, coalesce((select max(seq) from pools where order_date = d and site_id = si.id and kitchen_id = k.id), 0) + 1, 'waiting')
    returning * into pl;
  else
    select p.* into pl from pools p
     where p.order_date = d and p.site_id = si.id and p.kitchen_id = k.id and p.status = 'collecting'
       and pool_meals(p.id) + p_qty <= s.max_meals
     order by p.seq limit 1;
    if not found then
      insert into pools (order_date, site_id, kitchen_id, seq)
      values (d, si.id, k.id, coalesce((select max(seq) from pools where order_date = d and site_id = si.id and kitchen_id = k.id), 0) + 1)
      returning * into pl;
    end if;
  end if;

  loop
    v_code := (1000 + floor(random() * 9000))::int::text;
    exit when not exists (select 1 from orders where order_date = d and code = v_code);
  end loop;

  insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                      addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status)
  values (d, pl.id, si.id, k.id, m.id, auth.uid(), m.name, m.price, p_qty, v_add, v_add_total,
          nullif(trim(coalesce(p_note, '')), ''), v_special, trim(p_name), regexp_replace(p_phone, '\D', '', 'g'),
          v_code, fee_for(1, pool_trip(pl.id)), s.service_fee, case when v_special is null then 'pending' else 'quote_requested' end)
  returning id into v_id;

  if v_special is null then
    v_pay := settle_payment(v_id, p_ref, p_use_wallet);
  end if;

  return json_build_object('id', v_id, 'code', v_code, 'order_date', d, 'pool_seq', pl.seq, 'pool_status', pl.status,
    'meals', pool_meals(pl.id), 'status', (select status from orders where id = v_id), 'payment', v_pay);
end $$;

-- 3. Customers cancel before the cut-off. The order id is the customer's own receipt (same as viewing it).
--    Wallet money goes straight back to the wallet. A confirmed MoMo payment goes to the wallet, or is flagged
--    for a MoMo refund if they ask (or have no account). A MoMo payment still being checked is flagged for the team.
create or replace function cancel_order(p_order uuid, p_reason text, p_refund text default 'wallet')
returns json language plpgsql security definer set search_path = public as $$
declare o orders; s settings; v_total numeric; v_momo numeric; v_credit numeric := 0; v_to text;
begin
  select * into s from settings where id = 1;
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'Order not found.'; end if;
  if o.user_id is not null and o.user_id is distinct from auth.uid() then raise exception 'Sign in with the account that placed this order.'; end if;
  if o.status not in ('pending', 'paid', 'quote_requested', 'quoted') then raise exception 'This order can no longer be cancelled.'; end if;
  if (now() at time zone 'utc') >= o.order_date + s.cutoff then
    raise exception 'Orders close at %. The kitchen is already cooking, so it can''t be cancelled now.', to_char(s.cutoff, 'HH24:MI');
  end if;

  v_total := (coalesce(o.quote_price, o.unit_price) + o.addons_total) * o.qty + o.max_fee * o.qty + o.service_fee;
  v_momo := greatest(0, v_total - o.wallet_used);

  if o.status in ('quote_requested', 'quoted') then
    v_to := 'nothing';                                         -- not paid yet
  elsif o.status = 'paid' and v_momo > 0 and o.user_id is not null and coalesce(p_refund, 'wallet') = 'wallet' then
    v_credit := v_momo; v_to := 'wallet';
  elsif v_momo > 0 then
    v_to := 'momo';                                            -- team refunds (or checks) the MoMo payment
  else
    v_to := 'wallet';
  end if;
  v_credit := v_credit + o.wallet_used;

  update orders set status = 'cancelled',
         cancel_reason = 'You cancelled' || coalesce(' (' || nullif(left(trim(p_reason), 80), '') || ')', ''),
         refund_needed = (v_to = 'momo')
  where id = o.id;

  if v_credit > 0 and o.user_id is not null then
    insert into wallet_entries (user_id, amount, reason, order_id)
    values (o.user_id, v_credit, 'Refund: cancelled order ' || o.code, o.id);
  end if;

  -- A pool nobody is left in shouldn't keep waiting for the seller
  update pools set status = 'cancelled' where id = o.pool_id and status = 'waiting' and pool_meals(id) = 0;

  return json_build_object('refund', v_to, 'wallet_credit', case when o.user_id is not null then v_credit else 0 end, 'momo', case when v_to = 'momo' then v_momo else 0 end);
end $$;

-- 4. Orders show the delivery saved so far (the cashback), so guests can see what they'd keep with an account
drop function if exists my_orders(uuid[]);
create function my_orders(p_ids uuid[])
returns table (id uuid, order_date date, code text, status text, qty int, item_name text, site_id uuid,
               kitchen_id uuid, pool_seq int, pool_status text, special_request text, quote_price numeric,
               amount_due numeric, cancel_reason text, unit_price numeric, addons jsonb, addons_total numeric,
               max_fee numeric, service_fee numeric, wallet_used numeric, saving numeric, has_account boolean,
               refund_needed boolean)
language sql stable security definer set search_path = public as $$
  select o.id, o.order_date, o.code, o.status, o.qty, o.item_name, o.site_id, o.kitchen_id, p.seq, p.status,
         o.special_request, o.quote_price,
         (coalesce(o.quote_price, o.unit_price) + o.addons_total) * o.qty + o.max_fee * o.qty + o.service_fee - o.wallet_used,
         o.cancel_reason, o.unit_price, o.addons, o.addons_total, o.max_fee, o.service_fee, o.wallet_used,
         case when o.status in ('pending', 'paid', 'collected') and p.status <> 'cancelled'
              then round(greatest(0, (o.max_fee - fee_for(pool_meals(o.pool_id), pool_trip(o.pool_id))) * o.qty), 2) else 0 end,
         o.user_id is not null, o.refund_needed
  from orders o join pools p on p.id = o.pool_id
  where (o.id = any(p_ids) or (auth.uid() is not null and o.user_id = auth.uid()))
    and o.order_date >= (now() at time zone 'utc')::date - 1
  order by o.created_at desc;
$$;

grant execute on function cancel_order(uuid, text, text), my_orders(uuid[]) to anon, authenticated;

notify pgrst, 'reload schema';
