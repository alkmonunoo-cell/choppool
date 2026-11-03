-- ChopPool update 9: each order is charged the pool's delivery fee by distance (capped at the maximum),
-- not the full maximum. It's the most they'll pay; cashback returns the difference as the pool fills.
-- Paste into Supabase > SQL Editor > New query, then Run. Run update-7.sql first. Safe to run more than once.

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
          v_code, fee_for(pool_meals(pl.id) + p_qty, pool_trip(pl.id)), s.service_fee, case when v_special is null then 'pending' else 'quote_requested' end)
  returning id into v_id;

  if v_special is null then
    v_pay := settle_payment(v_id, p_ref, p_use_wallet);
  end if;

  return json_build_object('id', v_id, 'code', v_code, 'order_date', d, 'pool_seq', pl.seq, 'pool_status', pl.status,
    'meals', pool_meals(pl.id), 'status', (select status from orders where id = v_id), 'payment', v_pay);
end $$;

notify pgrst, 'reload schema';
