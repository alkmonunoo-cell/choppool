-- ChopPool update 33: extras with a count (2 x Fried eggs on each plate, up to 5), charged price x count.
-- Older orders without a count read as 1. Safe to run more than once.

CREATE OR REPLACE FUNCTION public.place_order(p_site uuid, p_item uuid, p_qty integer, p_name text, p_phone text, p_ref text, p_addons text[] DEFAULT '{}'::text[], p_note text DEFAULT NULL::text, p_special text DEFAULT NULL::text, p_use_wallet boolean DEFAULT false, p_join uuid DEFAULT NULL::uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s settings; m menu_items; k kitchens; si sites; pl pools; par orders;
  d date := current_order_date();
  v_load int; v_code text; v_id uuid; v_add jsonb; v_add_total numeric; v_special text; v_pay json;
  v_open boolean; v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_ps int; v_need int;
begin
  perform housekeeping();
  select * into s from settings where id = 1;
  select * into m from menu_items where id = p_item and active;
  if not found then raise exception 'That dish is no longer available.'; end if;
  select * into k from kitchens where id = m.kitchen_id and active;
  if not found then raise exception 'That vendor is not taking orders.'; end if;
  v_ps := kitchen_pool_size(k.id);
  if p_qty is null or p_qty < 1 or p_qty > least(5, v_ps) then raise exception 'Choose between 1 and % meals.', least(5, v_ps); end if;
  -- A tray of several dishes needs one pool with room for all of it
  v_need := greatest(p_qty, coalesce(nullif(current_setting('cp.basket_meals', true), '')::int, 0));

  v_special := nullif(trim(coalesce(p_special, '')), '');
  -- Extras: picked by name, or by name#price when a dish lists the same name more than once (Fish at 15, 20, 30).
  -- Sending a pick twice means two of it on each plate (2 eggs), up to 5; each extra is saved with its count.
  select coalesce(jsonb_agg(a || jsonb_build_object('qty', c)), '[]'::jsonb), coalesce(sum(coalesce(nullif(a ->> 'price', '')::numeric, 0) * c), 0)
    into v_add, v_add_total
  from (select a, least(5, (select count(*) from unnest(coalesce(p_addons, '{}')) u(pick)
                  where pick = (a ->> 'name') || '#' || trim_scale(coalesce(nullif(a ->> 'price', '')::numeric, 0))::text
                     or (pick = a ->> 'name' and i = (select min(j) from jsonb_array_elements(m.addons) with ordinality y(b, j) where b ->> 'name' = a ->> 'name')))) as c
        from jsonb_array_elements(m.addons) with ordinality x(a, i)) z
  where c > 0;

  perform pg_advisory_xact_lock(hashtext('cp' || k.id::text || d::text));
  select coalesce(sum(qty), 0) into v_load from orders where kitchen_id = k.id and order_date = d and status <> 'cancelled'
     and not (status = 'pending' and pay_issue is not null and pay_issue <> 'short');   -- payments we couldn't find don't hold seats
  if not k.no_daily_limit and v_load + p_qty > k.capacity then raise exception 'This menu is fully booked for today. Try another one.'; end if;

  if p_join is not null then
    -- Another plate for an order already placed: same code and bag, no extra delivery
    select * into par from orders where id = p_join and parent_id is null for update;
    if not found or par.status not in ('pending', 'paid') then raise exception 'That order can''t take another plate. Start a new order instead.'; end if;
    if not ((auth.uid() is not null and par.user_id = auth.uid()) or par.phone = v_phone) then
      raise exception 'Use the phone or account that placed the order.';
    end if;
    if par.kitchen_id <> k.id then raise exception 'Add a dish from the same vendor.'; end if;
    if par.order_date <> d or (now() at time zone 'utc') >= par.order_date + s.cutoff then
      raise exception 'Orders closed at %. You can''t add to this order now.', to_char(s.cutoff, 'HH24:MI');
    end if;
    if v_special is not null then raise exception 'Custom orders can''t be added to an order. Choose from the menu.'; end if;
    select * into pl from pools where id = par.pool_id;
    if pl.status not in ('waiting', 'collecting') then raise exception 'This pool has closed. Start a new order instead.'; end if;
    if pool_meals(pl.id) + p_qty > v_ps then raise exception 'This pool is full. Start a new order for more plates.'; end if;
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status,
                        parent_id, fee_per_meal)
    values (d, pl.id, par.site_id, k.id, m.id, par.user_id, m.name, m.price, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), null, par.customer_name, par.phone, par.code, 0, s.service_fee, 'pending',
            par.id, true)
    returning id, code into v_id, v_code;
  else
    if (select count(*) from orders where phone = v_phone and parent_id is null and status = 'pending' and created_at > now() - interval '1 day') >= 3 then
      raise exception 'You have 3 orders waiting for their payment to be checked. Wait for those before placing another.';
    end if;
    select * into si from sites where id = p_site and active;
    if not found then raise exception 'That drop point is not active.'; end if;
    if k.site_id is not null and k.site_id <> si.id then raise exception 'That vendor only delivers to another drop point.'; end if;
    if v_special is not null and d = (now() at time zone 'utc')::date and (now() at time zone 'utc')::time >= s.special_cutoff then
      raise exception 'Custom orders close at %. You can still order from the menu.', to_char(s.special_cutoff, 'HH24:MI');
    end if;
    -- While the vendor hasn't confirmed, everyone at the building joins the same waiting pool
    v_open := kitchen_is_open(k.id, d);
    select p.* into pl from pools p
     where p.order_date = d and p.site_id = si.id and p.kitchen_id = k.id
       and p.status = case when v_open then 'collecting' else 'waiting' end
       and pool_meals(p.id) + v_need <= v_ps
     order by p.seq limit 1;
    if not found then
      insert into pools (order_date, site_id, kitchen_id, seq, status)
      values (d, si.id, k.id, coalesce((select max(seq) from pools where order_date = d and site_id = si.id and kitchen_id = k.id and status <> 'cancelled'), 0) + 1,
              case when v_open then 'collecting' else 'waiting' end)
      returning * into pl;
    end if;
    v_code := new_code(si.id, d, pl.id);
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status, fee_per_meal)
    values (d, pl.id, si.id, k.id, m.id, auth.uid(), m.name, m.price, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), v_special, trim(p_name), v_phone,
            v_code, ceil(fee_for(0, pool_trip(pl.id)) / p_qty * 2) / 2, s.service_fee, case when v_special is null then 'pending' else 'quote_requested' end, true)
    returning id into v_id;
  end if;

  if v_special is null then
    v_pay := settle_payment(v_id, p_ref, p_use_wallet);
  end if;

  return json_build_object('id', v_id, 'code', v_code, 'order_date', d, 'pool_seq', pl.seq, 'pool_status', pl.status,
    'pool_id', pl.id, 'meals', pool_meals(pl.id), 'status', (select status from orders where id = v_id), 'payment', v_pay,
    'parent_id', p_join);
end $function$;
