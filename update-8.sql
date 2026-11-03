-- ChopPool update 8: clearer special requests, sellers can decline them, full bill for customers
-- Paste into Supabase > SQL Editor > New query, then Run. Safe to run more than once.

-- 1. Seller page: show the meal and its menu price next to each special request
create or replace function kitchen_view(p_token text, p_date date)
returns json language plpgsql volatile security definer set search_path = public as $$
declare k kitchens;
begin
  perform housekeeping();
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This seller link is not valid. Ask ChopPool for a new one.'; end if;
  return json_build_object(
    'kitchen', json_build_object('name', k.name, 'public_name', k.public_name, 'capacity', k.capacity,
                                 'delivery_mode', k.delivery_mode, 'added_by_customer', k.added_by_customer,
                                 'open', kitchen_is_open(k.id, p_date)),
    'menu', coalesce((select json_agg(json_build_object('id', id, 'name', name, 'price', price) order by name)
                      from menu_items where kitchen_id = k.id and active), '[]'::json),
    'pools', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'seq', p.seq, 'status', p.status, 'site', si.name, 'drop_point', si.drop_point,
        'handoff', si.handoff, 'host_label', si.host_label,
        'orders', (select json_agg(json_build_object('id', o.id, 'code', o.code, 'qty', o.qty, 'item_name', o.item_name,
                                                     'unit_price', o.unit_price, 'addons_total', o.addons_total,
                                                     'addons', o.addons, 'note', o.note, 'special_request', o.special_request,
                                                     'quote_price', o.quote_price, 'status', o.status,
                                                     'paid', o.status in ('paid', 'collected'), 'collected', o.status = 'collected')
                                   order by o.code)
                   from orders o where o.pool_id = p.id and o.status <> 'cancelled'))
        order by si.name, p.seq)
      from pools p join sites si on si.id = p.site_id
      where p.kitchen_id = k.id and p.order_date = p_date and p.status <> 'cancelled' and pool_meals(p.id) > 0
    ), '[]'::json));
end $$;

-- 2. Seller declines a special request (only while it's unpaid). Nothing is charged.
create or replace function kitchen_decline(p_token text, p_order uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update orders o set status = 'cancelled',
         cancel_reason = 'The seller can''t do this request' || coalesce(': ' || nullif(left(trim(p_reason), 120), ''), '')
  from kitchens k
  where k.token = p_token and k.active and o.kitchen_id = k.id and o.id = p_order and o.status in ('quote_requested', 'quoted');
  if not found then raise exception 'That request has already been paid or closed.'; end if;
end $$;

-- 3. Customer orders now include what's needed for the full bill
drop function if exists my_orders(uuid[]);
create function my_orders(p_ids uuid[])
returns table (id uuid, order_date date, code text, status text, qty int, item_name text, site_id uuid,
               kitchen_id uuid, pool_seq int, pool_status text, special_request text, quote_price numeric,
               amount_due numeric, cancel_reason text, unit_price numeric, addons jsonb, addons_total numeric,
               max_fee numeric, service_fee numeric, wallet_used numeric)
language sql stable security definer set search_path = public as $$
  select o.id, o.order_date, o.code, o.status, o.qty, o.item_name, o.site_id, o.kitchen_id, p.seq, p.status,
         o.special_request, o.quote_price,
         (coalesce(o.quote_price, o.unit_price) + o.addons_total) * o.qty + o.max_fee * o.qty + o.service_fee - o.wallet_used,
         o.cancel_reason, o.unit_price, o.addons, o.addons_total, o.max_fee, o.service_fee, o.wallet_used
  from orders o join pools p on p.id = o.pool_id
  where (o.id = any(p_ids) or (auth.uid() is not null and o.user_id = auth.uid()))
    and o.order_date >= (now() at time zone 'utc')::date - 1
  order by o.created_at desc;
$$;

grant execute on function kitchen_view(text, date), kitchen_decline(text, uuid, text), my_orders(uuid[]) to anon, authenticated;

notify pgrst, 'reload schema';
