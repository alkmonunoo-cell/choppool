-- ============================================================================
-- ChopPool database update (latest). ONE file for every update.
-- In Supabase > SQL Editor, open your saved query "ChopPool update", select all, paste this file over it, Run.
-- Safe to run as many times as you like: it only adds or replaces what's needed, and never deletes your data.
-- ============================================================================


-- ---------- from update6 ----------
-- ChopPool update 6 (safe to run more than once; includes update 5)
-- 1) Remove kitchens and buildings
alter table kitchens add column if not exists archived boolean not null default false;
alter table sites add column if not exists archived boolean not null default false;

create or replace function admin_remove_kitchen(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  if exists (select 1 from orders where kitchen_id = p_id) then
    update kitchens set archived = true, active = false where id = p_id;
    return 'archived';
  end if;
  delete from kitchen_days where kitchen_id = p_id;
  delete from pools where kitchen_id = p_id;
  delete from menu_items where kitchen_id = p_id;
  delete from kitchens where id = p_id;
  return 'deleted';
end $$;

create or replace function admin_remove_site(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  update kitchens set archived = true, active = false where site_id = p_id;
  if exists (select 1 from orders where site_id = p_id) or exists (select 1 from kitchens where site_id = p_id) then
    update sites set archived = true, active = false where id = p_id;
    return 'archived';
  end if;
  delete from pools where site_id = p_id;
  delete from sites where id = p_id;
  return 'deleted';
end $$;

grant execute on function admin_remove_kitchen(uuid), admin_remove_site(uuid) to authenticated;

-- 2) Map pins for kitchens, so customers see kitchens near them
alter table kitchens add column if not exists lat double precision;
alter table kitchens add column if not exists lng double precision;

create or replace view public_menus as
  select id, public_name, tagline, capacity, site_id, added_by_customer, lat, lng from kitchens where active;
grant select on public_menus to anon, authenticated;

-- Sellers added by customers take their building's pin
update kitchens k set lat = s.lat, lng = s.lng from sites s
 where k.site_id = s.id and k.lat is null;

create or replace function add_vendor(p_site uuid, p_name text, p_whatsapp text, p_items jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare k kitchens; si sites; v_wa text := regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g'); it jsonb; n int := 0;
begin
  select * into si from sites where id = p_site and active and status = 'active';
  if not found then raise exception 'Pick your drop point first.'; end if;
  if char_length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Add the seller''s name.'; end if;
  if v_wa !~ '^0[0-9]{9}$' then raise exception 'Enter the seller''s 10-digit WhatsApp number, like 024 123 4567.'; end if;
  if (select count(*) from kitchens where site_id = p_site and created_at > now() - interval '1 day') >= 10 then
    raise exception 'Too many sellers were added here today. Ask the ChopPool team to help.';
  end if;
  insert into kitchens (name, public_name, tagline, whatsapp, capacity, site_id, added_by_customer, added_by, lat, lng)
  values (trim(p_name), trim(p_name), 'Added by a customer', v_wa, 30, p_site, true, auth.uid(), si.lat, si.lng)
  returning * into k;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    if char_length(trim(coalesce(it ->> 'name', ''))) >= 2 and coalesce((it ->> 'price')::numeric, 0) > 0 then
      insert into menu_items (kitchen_id, name, price) values (k.id, trim(it ->> 'name'), (it ->> 'price')::numeric);
      n := n + 1;
    end if;
  end loop;
  if n = 0 then raise exception 'Add at least one dish with its price.'; end if;
  return json_build_object('id', k.id, 'token', k.token, 'whatsapp', k.whatsapp, 'name', k.public_name);
end $$;

-- Example kitchens get example pins (Osu and Airport Residential). Change them in the app.
update kitchens set lat = 5.5560, lng = -0.1820 where name = 'Auntie Akos Kitchen' and lat is null;
update kitchens set lat = 5.6010, lng = -0.1780 where name = 'Green Bowl' and lat is null;


-- ---------- from update7 ----------
-- ChopPool update 7: distance-based delivery pricing + customer account counts for the owner
-- Paste into Supabase > SQL Editor > New query, then Run. Safe to run more than once.

-- 1. Pricing settings: base fare + rate per km (road km = straight line x 1.3)
alter table settings add column if not exists base_fare numeric not null default 20;
alter table settings add column if not exists per_km numeric not null default 6;

-- Straight-line distance in metres between two pins
create or replace function dist_m(lat1 float8, lng1 float8, lat2 float8, lng2 float8) returns numeric
language sql immutable as $$
  select (6371000 * 2 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2))))::numeric;
$$;

-- Estimated rider trip cost for a pool: kitchen pin to building pin.
-- Customer-added sellers sit at their building. No pins = the flat trip cost.
create or replace function pool_trip(p uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select case
    when coalesce(k.lat, case when k.added_by_customer then st.lat end) is null or st.lat is null then s.trip_cost
    else round(s.base_fare + s.per_km * dist_m(
           coalesce(k.lat, case when k.added_by_customer then st.lat end),
           coalesce(k.lng, case when k.added_by_customer then st.lng end),
           st.lat, st.lng) / 1000 * 1.3)
  end
  from pools pl join kitchens k on k.id = pl.kitchen_id join sites st on st.id = pl.site_id cross join settings s
  where pl.id = p and s.id = 1;
$$;

-- Delivery share per meal for a given trip cost
create or replace function fee_for(p_meals int, p_trip numeric) returns numeric
language sql stable security definer set search_path = public as $$
  select case when p_meals <= 0 then s.max_fee
              else least(s.max_fee, ceil(coalesce(p_trip, s.trip_cost) / p_meals * 2) / 2) end
  from settings s where s.id = 1;
$$;

-- Wallet cashback now uses each pool's own trip cost
create or replace function wallet_balance(p_user uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select round(
    coalesce((select sum(amount) from wallet_entries where user_id = p_user), 0) +
    coalesce((select sum(greatest(0, (o.max_fee - fee_for(pool_meals(o.pool_id), pool_trip(o.pool_id))) * o.qty))
              from orders o join pools p on p.id = o.pool_id cross join settings s
              where s.id = 1 and o.user_id = p_user and o.status in ('paid', 'collected')
                and p.status <> 'cancelled'
                and (now() at time zone 'utc') >= o.order_date + s.cutoff), 0), 2);
$$;

create or replace function my_wallet() returns json
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in to see your wallet.'; end if;
  return json_build_object(
    'balance', wallet_balance(v_uid),
    'entries', coalesce((select json_agg(x order by x.at desc) from (
        select created_at as at, amount, reason from wallet_entries where user_id = v_uid
        union all
        select o.order_date + s.cutoff, round((o.max_fee - fee_for(pool_meals(o.pool_id), pool_trip(o.pool_id))) * o.qty, 2),
               'Delivery cashback, code ' || o.code
        from orders o join pools p on p.id = o.pool_id cross join settings s
        where s.id = 1 and o.user_id = v_uid and o.status in ('paid', 'collected') and p.status <> 'cancelled'
          and (now() at time zone 'utc') >= o.order_date + s.cutoff
          and o.max_fee > fee_for(pool_meals(o.pool_id), pool_trip(o.pool_id))
        order by 1 desc limit 30) x), '[]'::json));
end $$;

-- 2. Owner only: how many customers have accounts, and how many ordered in the last 30 days
create or replace function admin_account_stats() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_super() then raise exception 'Only the owner can see this.'; end if;
  return json_build_object(
    'accounts', (select count(*) from auth.users u where lower(u.email) not in (select email from admins)),
    'active', (select count(distinct o.user_id) from orders o where o.user_id is not null and o.status <> 'cancelled'
                 and o.created_at > now() - interval '30 days'));
end $$;

grant execute on function pool_trip(uuid) to anon, authenticated;
grant execute on function fee_for(int, numeric) to anon, authenticated;
grant execute on function admin_account_stats() to authenticated;


-- ---------- from update8 ----------
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


-- ---------- from update10 ----------
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
select 'ChopPool database is up to date (version 10)' as result;
