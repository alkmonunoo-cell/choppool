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



-- ---------- from update11 ----------
-- Pool numbers count live pools only (cancelled pools no longer use up numbers)
alter table pools drop constraint if exists pools_order_date_site_id_kitchen_id_seq_key;

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
    values (d, si.id, k.id, coalesce((select max(seq) from pools where order_date = d and site_id = si.id and kitchen_id = k.id and status <> 'cancelled'), 0) + 1, 'waiting')
    returning * into pl;
  else
    select p.* into pl from pools p
     where p.order_date = d and p.site_id = si.id and p.kitchen_id = k.id and p.status = 'collecting'
       and pool_meals(p.id) + p_qty <= s.max_meals
     order by p.seq limit 1;
    if not found then
      insert into pools (order_date, site_id, kitchen_id, seq)
      values (d, si.id, k.id, coalesce((select max(seq) from pools where order_date = d and site_id = si.id and kitchen_id = k.id and status <> 'cancelled'), 0) + 1)
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

-- Renumber today's and future live pools 1, 2, 3...
with r as (
  select id, row_number() over (partition by order_date, site_id, kitchen_id order by seq, created_at) as rn
  from pools where status <> 'cancelled' and order_date >= (now() at time zone 'utc')::date)
update pools p set seq = r.rn from r where p.id = r.id and p.seq <> r.rn;


-- ---------- from update12 ----------
-- Several payment options (owner manages them; customers see the active ones)
create table if not exists payment_methods (
  id uuid primary key default gen_random_uuid(),
  network text not null default 'MTN',
  number text not null,
  name text not null,
  is_main boolean not null default false,
  active boolean not null default true,
  sort int not null default 0,
  created_at timestamptz not null default now()
);
alter table payment_methods enable row level security;
drop policy if exists "read pay methods" on payment_methods;
create policy "read pay methods" on payment_methods for select using (active or is_admin());
drop policy if exists "owner pay methods" on payment_methods;
create policy "owner pay methods" on payment_methods for all to authenticated using (is_super()) with check (is_super());
grant select on payment_methods to anon, authenticated;
grant insert, update, delete on payment_methods to authenticated;
-- First option = the MoMo details already saved in settings
insert into payment_methods (network, number, name, is_main, sort)
select coalesce(momo_network, 'MTN'), momo_number, momo_name, true, 1 from settings
where id = 1 and not exists (select 1 from payment_methods);

-- Date added, shown on each rider
alter table riders add column if not exists created_at timestamptz not null default now();

-- Dish pictures: blank = chosen automatically from the dish name
alter table menu_items add column if not exists icon text;

-- Most-ordered dishes (counts only, no customer details): each kitchen shows its top dish
create or replace view dish_popularity as
  select item_id, sum(qty)::int as n from orders
  where status <> 'cancelled' and created_at > now() - interval '60 days' group by item_id;
grant select on dish_popularity to anon, authenticated;


-- ---------- from update13 ----------
-- ===== Batch B: sellers list themselves, riders apply, ratings from real orders, push alerts =====

-- Sellers added by customers can ask to be listed for free
alter table kitchens add column if not exists listing_status text not null default 'none';   -- none | pending | approved | declined
alter table kitchens add column if not exists listing jsonb;                                    -- what the seller sent
alter table kitchens add column if not exists listing_requested_at timestamptz;

create or replace function vendor_request_listing(p_token text, p_listing jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This seller link is not valid.'; end if;
  if not k.added_by_customer or k.listing_status = 'approved' then raise exception 'You are already listed on ChopPool.'; end if;
  if length(coalesce(p_listing ->> 'name', '')) < 2 then raise exception 'Add your business name.'; end if;
  if (p_listing ->> 'lat') is null then raise exception 'Set your location on the map.'; end if;
  update kitchens set listing = p_listing, listing_status = 'pending', listing_requested_at = now() where id = k.id;
end $$;
grant execute on function vendor_request_listing(text, jsonb) to anon, authenticated;

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
                                 'open', kitchen_is_open(k.id, p_date), 'listing_status', k.listing_status, 'listing', k.listing),
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

-- Riders apply themselves; the team approves
alter table riders add column if not exists status text not null default 'approved';           -- pending | approved | declined
alter table riders add column if not exists bike text;
alter table riders add column if not exists area text;
alter table riders add column if not exists momo text;

create or replace function rider_apply(p_name text, p_phone text, p_bike text, p_area text, p_momo text)
returns void language plpgsql security definer set search_path = public as $$
declare v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Add your full name.'; end if;
  if v_phone !~ '^0\d{9}$' then raise exception 'Enter your 10-digit phone number, like 024 123 4567.'; end if;
  if exists (select 1 from riders where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = v_phone) then raise exception 'This phone number has already applied.'; end if;
  if (select count(*) from riders where status = 'pending' and created_at > now() - interval '1 day') > 50 then raise exception 'Too many applications today. Please try tomorrow.'; end if;
  insert into riders (name, phone, bike, area, momo, status, active)
  values (left(trim(p_name), 60), v_phone, left(trim(coalesce(p_bike, '')), 60), left(trim(coalesce(p_area, '')), 60), left(regexp_replace(coalesce(p_momo, ''), '[^0-9 ]', '', 'g'), 20), 'pending', false);
end $$;
grant execute on function rider_apply(text, text, text, text, text) to anon, authenticated;

-- Kitchen scores from real orders only (last 90 days). Counts and percentages, no customer details.
drop view if exists kitchen_scores;
create or replace view kitchen_scores as
  with p as (
    select pl.kitchen_id, pl.id, pl.status, pl.delivered_at, pl.order_date,
           exists (select 1 from orders o where o.pool_id = pl.id and o.cancel_reason in ('The seller did not confirm in time') ) as no_show
    from pools pl where pl.order_date > (now() at time zone 'utc')::date - 90),
  o as (select kitchen_id, phone, count(*) as n from orders where status in ('paid', 'collected') and order_date > (now() at time zone 'utc')::date - 90 group by 1, 2)
  select k.id as kitchen_id,
    coalesce((select sum(n) from o where o.kitchen_id = k.id), 0)::int as orders,
    (select round(100.0 * count(*) filter (where p.delivered_at <= (p.order_date + s.delivery_time + interval '15 minutes')) / nullif(count(*) filter (where p.delivered_at is not null), 0))
       from p cross join settings s where s.id = 1 and p.kitchen_id = k.id)::int as on_time,
    (select round(100.0 * count(*) filter (where p.status <> 'cancelled') / nullif(count(*) filter (where p.status <> 'cancelled' or p.no_show), 0)) from p where p.kitchen_id = k.id)::int as reliable,
    (select round(100.0 * count(*) filter (where o.n >= 2) / nullif(count(*), 0)) from o where o.kitchen_id = k.id)::int as come_back
  from kitchens k where k.active and not k.archived;
grant select on kitchen_scores to anon, authenticated;

-- Which kitchens each building orders from (counts only): used to show a building its own favourites first
create or replace view site_kitchen_counts as
  select site_id, kitchen_id, sum(qty)::int as n from orders
  where status <> 'cancelled' and order_date > (now() at time zone 'utc')::date - 60 group by 1, 2;
grant select on site_kitchen_counts to anon, authenticated;

-- Push alerts: each phone that switches alerts on, and what it wants to hear about
create table if not exists push_subs (
  endpoint text primary key,
  p256dh text not null,
  auth text not null,
  user_id uuid,
  order_ids uuid[] not null default '{}',
  kitchen_id uuid references kitchens(id) on delete cascade,
  rider_id uuid references riders(id) on delete cascade,
  is_team boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table push_subs enable row level security;   -- no direct access; only the functions below and the server
create table if not exists push_log (key text primary key, sent_at timestamptz not null default now());
alter table push_log enable row level security;

create or replace function save_push_sub(p_endpoint text, p_p256dh text, p_auth text, p_order_ids uuid[] default '{}',
                                         p_kitchen_token text default null, p_rider_token text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_k uuid; v_r uuid;
begin
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 then raise exception 'Invalid subscription.'; end if;
  if p_kitchen_token is not null then select id into v_k from kitchens where token = p_kitchen_token and active; end if;
  if p_rider_token is not null then select id into v_r from riders where token = p_rider_token and active; end if;
  insert into push_subs (endpoint, p256dh, auth, user_id, order_ids, kitchen_id, rider_id, is_team)
  values (p_endpoint, p_p256dh, p_auth, auth.uid(), coalesce(p_order_ids, '{}'), v_k, v_r, is_admin())
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth,
    user_id = coalesce(excluded.user_id, push_subs.user_id),
    order_ids = (select array(select distinct unnest(push_subs.order_ids || excluded.order_ids))),
    kitchen_id = coalesce(excluded.kitchen_id, push_subs.kitchen_id), rider_id = coalesce(excluded.rider_id, push_subs.rider_id),
    is_team = push_subs.is_team or excluded.is_team, updated_at = now();
end $$;
grant execute on function save_push_sub(text, text, text, uuid[], text, text) to anon, authenticated;


-- ---------- from update14 ----------
-- =====================================================================
-- Update 14: vendors anywhere + long-distance pricing, "Always cooking", add a plate to your order,
-- easy codes (K-27), service fee per meal, joining while the vendor confirms, dish photos,
-- weekly reports, a faster home screen
-- =====================================================================

-- ---------- New columns and indexes ----------
alter table settings add column if not exists cap_km numeric default 8;               -- the per-meal cap applies up to this many km by road
alter table kitchens add column if not exists auto_days int[] not null default '{}';  -- "Always cooking": 1 = Monday ... 5 = Friday
alter table kitchens add column if not exists paused_dates date[] not null default '{}'; -- "Not cooking today"
alter table orders add column if not exists parent_id uuid references orders(id);     -- another plate added under the same code
alter table orders add column if not exists fee_per_meal boolean not null default false; -- service fee charged per meal (new orders)
alter table menu_items add column if not exists photo_url text;
create index if not exists orders_date_site_idx on orders (order_date, site_id);
create index if not exists orders_parent_idx on orders (parent_id);
create index if not exists pools_date_kitchen_idx on pools (order_date, kitchen_id);
create index if not exists pools_date_site_idx on pools (order_date, site_id);

-- ---------- Pricing: no cap for long-distance trips ----------
create or replace function fee_for(p_meals int, p_trip numeric) returns numeric
language sql stable security definer set search_path = public as $$
  select case
    when coalesce(p_trip, s.trip_cost) > round(s.base_fare + s.per_km * s.cap_km) then   -- long distance: shared at cost
      case when p_meals <= 0 then ceil(coalesce(p_trip, s.trip_cost) * 2) / 2
           else ceil(coalesce(p_trip, s.trip_cost) / p_meals * 2) / 2 end
    when p_meals <= 0 then s.max_fee
    else least(s.max_fee, ceil(coalesce(p_trip, s.trip_cost) / p_meals * 2) / 2) end
  from settings s where s.id = 1;
$$;

-- What an order costs in full (old orders keep a per-order service fee)
create or replace function order_total(o orders) returns numeric
language sql immutable as $$
  select (coalesce(o.quote_price, o.unit_price) + o.addons_total) * o.qty + o.max_fee * o.qty
       + o.service_fee * case when o.fee_per_meal then o.qty else 1 end;
$$;

-- Delivery cashback for one code: delivery was paid once; the final share counts every meal under the code
create or replace function order_cashback(p_order uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select case when o.parent_id is not null or p.status = 'cancelled' then 0
    else round(greatest(0, o.max_fee * o.qty - fee_for(pool_meals(o.pool_id), pool_trip(o.pool_id)) *
      (o.qty + coalesce((select sum(c.qty) from orders c where c.parent_id = o.id and c.status in ('pending', 'paid', 'collected')), 0))), 2) end
  from orders o join pools p on p.id = o.pool_id where o.id = p_order;
$$;

create or replace function wallet_balance(p_user uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select round(
    coalesce((select sum(amount) from wallet_entries where user_id = p_user), 0) +
    coalesce((select sum(order_cashback(o.id))
              from orders o join pools p on p.id = o.pool_id cross join settings s
              where s.id = 1 and o.user_id = p_user and o.status in ('paid', 'collected') and o.parent_id is null
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
        select o.order_date + s.cutoff, order_cashback(o.id), 'Delivery cashback, code ' || o.code
        from orders o join pools p on p.id = o.pool_id cross join settings s
        where s.id = 1 and o.user_id = v_uid and o.status in ('paid', 'collected') and p.status <> 'cancelled'
          and o.parent_id is null and (now() at time zone 'utc') >= o.order_date + s.cutoff
          and order_cashback(o.id) > 0
        order by 1 desc limit 60) x), '[]'::json));
end $$;

-- ---------- "Always cooking" (auto-confirm on chosen weekdays) and "Not cooking today" ----------
create or replace function kitchen_is_open(p_kitchen uuid, p_date date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from kitchen_days where kitchen_id = p_kitchen and order_date = p_date)
      or exists (select 1 from kitchens k where k.id = p_kitchen and k.active
                   and extract(isodow from p_date)::int = any(k.auto_days) and not (p_date = any(k.paused_dates)));
$$;

create or replace function kitchen_set_auto(p_token text, p_days int[])
returns void language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  if exists (select 1 from unnest(coalesce(p_days, '{}')) d where d not between 1 and 7) then raise exception 'Choose weekdays.'; end if;
  update kitchens set auto_days = (select coalesce(array_agg(distinct d order by d), '{}') from unnest(coalesce(p_days, '{}')) d) where id = k.id;
  -- Pools already waiting today open straight away
  update pools set status = 'collecting' where kitchen_id = k.id and status = 'waiting' and kitchen_is_open(k.id, order_date);
end $$;

create or replace function kitchen_pause(p_token text, p_date date, p_paused boolean)
returns void language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  if p_paused then
    if exists (select 1 from pools p where p.kitchen_id = k.id and p.order_date = p_date and p.status <> 'cancelled' and pool_meals(p.id) > 0) then
      raise exception 'You already have orders for this day. Message ChopPool if you can''t cook them.';
    end if;
    update kitchens set paused_dates = array(select distinct x from unnest(paused_dates || p_date) x where x >= (now() at time zone 'utc')::date - 1) where id = k.id;
    delete from kitchen_days where kitchen_id = k.id and order_date = p_date;
  else
    update kitchens set paused_dates = array_remove(paused_dates, p_date) where id = k.id;
  end if;
end $$;

-- A vendor confirming a day also lifts a pause for it
create or replace function kitchen_open_day(p_token text, p_date date)
returns void language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  update kitchens set paused_dates = array_remove(paused_dates, p_date) where id = k.id;
  insert into kitchen_days (kitchen_id, order_date) values (k.id, p_date) on conflict do nothing;
  update pools set status = 'collecting' where kitchen_id = k.id and order_date = p_date and status = 'waiting';
end $$;

-- ---------- Easy collection codes: one letter + 2 digits (K-27) ----------
-- No O, I, S, Z or B (they look like digits). Unique per building per day; never two look-alikes in one bag.
create or replace function new_code(p_site uuid, p_date date, p_pool uuid) returns text
language plpgsql volatile security definer set search_path = public as $$
declare v text; l text := 'ACDEFGHJKLMNPQRTUVWXY'; n int := 0; near boolean;
begin
  loop
    n := n + 1;
    v := substr(l, 1 + floor(random() * length(l))::int, 1) || '-' ||
         lpad(floor(random() * case when n > 300 then 1000 else 100 end)::int::text, case when n > 300 then 3 else 2 end, '0');
    if exists (select 1 from orders where order_date = p_date and site_id = p_site and code = v) then continue; end if;
    exit when n > 300;
    select exists (select 1 from orders o where o.pool_id = p_pool and o.status <> 'cancelled' and o.code ~ '^[A-Z]-[0-9]{2}$' and (
        (left(o.code, 1) = left(v, 1) and (substr(o.code, 3, 1) = substr(v, 3, 1) or substr(o.code, 4, 1) = substr(v, 4, 1)
                                           or (substr(o.code, 3, 1) = substr(v, 4, 1) and substr(o.code, 4, 1) = substr(v, 3, 1))))
        or right(o.code, 2) = right(v, 2))) into near;
    exit when not near;
  end loop;
  return v;
end $$;

-- Typed codes: any case, with or without the dash ("k27" = "K-27"); old 4-digit codes still work
create or replace function norm_code(p text) returns text
language sql immutable as $$
  select case when x ~ '^[A-Z][0-9]{2,3}$' then left(x, 1) || '-' || substr(x, 2) else x end
  from (select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) as x) t;
$$;

-- ---------- Payment uses the full total (service fee per meal on new orders) ----------
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
    raise exception 'Enter the MoMo transaction ID for the remaining %.', to_char(v_total - v_use, 'FM999990.00');
  end if;
  update orders set wallet_used = wallet_used + v_use,
    momo_ref = case when v_use < v_total then trim(p_ref) else momo_ref end,
    status = case when v_use >= v_total then 'paid' else 'pending' end
  where id = o.id;
  return json_build_object('total', v_total, 'wallet_used', v_use, 'momo_due', v_total - v_use);
end $$;

-- ---------- Ordering: join a pool while the vendor confirms, add a plate under the same code ----------
drop function if exists place_order(uuid, uuid, int, text, text, text, text[], text, text, boolean);
create or replace function place_order(p_site uuid, p_item uuid, p_qty int, p_name text, p_phone text, p_ref text,
                                       p_addons text[] default '{}', p_note text default null,
                                       p_special text default null, p_use_wallet boolean default false,
                                       p_join uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  s settings; m menu_items; k kitchens; si sites; pl pools; par orders;
  d date := current_order_date();
  v_load int; v_code text; v_id uuid; v_add jsonb; v_add_total numeric; v_special text; v_pay json;
  v_open boolean; v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  perform housekeeping();
  select * into s from settings where id = 1;
  select * into m from menu_items where id = p_item and active;
  if not found then raise exception 'That dish is no longer available.'; end if;
  select * into k from kitchens where id = m.kitchen_id and active;
  if not found then raise exception 'That vendor is not taking orders.'; end if;
  if p_qty is null or p_qty < 1 or p_qty > least(5, s.max_meals) then raise exception 'Choose between 1 and 5 meals.'; end if;

  v_special := nullif(trim(coalesce(p_special, '')), '');
  select coalesce(jsonb_agg(a), '[]'::jsonb), coalesce(sum((a ->> 'price')::numeric), 0)
    into v_add, v_add_total
  from jsonb_array_elements(m.addons) a where a ->> 'name' = any(coalesce(p_addons, '{}'));

  perform pg_advisory_xact_lock(hashtext('cp' || k.id::text || d::text));
  select coalesce(sum(qty), 0) into v_load from orders where kitchen_id = k.id and order_date = d and status <> 'cancelled';
  if v_load + p_qty > k.capacity then raise exception 'This menu is fully booked for today. Try another one.'; end if;

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
    if v_special is not null then raise exception 'Special requests can''t be added to an order. Choose from the menu.'; end if;
    select * into pl from pools where id = par.pool_id;
    if pl.status not in ('waiting', 'collecting') then raise exception 'This pool has closed. Start a new order instead.'; end if;
    if pool_meals(pl.id) + p_qty > s.max_meals then raise exception 'This pool is full. Start a new order for more plates.'; end if;
    insert into orders (order_date, pool_id, site_id, kitchen_id, item_id, user_id, item_name, unit_price, qty,
                        addons, addons_total, note, special_request, customer_name, phone, code, max_fee, service_fee, status,
                        parent_id, fee_per_meal)
    values (d, pl.id, par.site_id, k.id, m.id, par.user_id, m.name, m.price, p_qty, v_add, v_add_total,
            nullif(trim(coalesce(p_note, '')), ''), null, par.customer_name, par.phone, par.code, 0, s.service_fee, 'pending',
            par.id, true)
    returning id, code into v_id, v_code;
  else
    select * into si from sites where id = p_site and active;
    if not found then raise exception 'That drop point is not active.'; end if;
    if k.site_id is not null and k.site_id <> si.id then raise exception 'That vendor only delivers to another drop point.'; end if;
    if v_special is not null and d = (now() at time zone 'utc')::date and (now() at time zone 'utc')::time >= s.special_cutoff then
      raise exception 'Special requests close at %. You can still order from the menu.', to_char(s.special_cutoff, 'HH24:MI');
    end if;
    -- While the vendor hasn't confirmed, everyone at the building joins the same waiting pool
    v_open := kitchen_is_open(k.id, d);
    select p.* into pl from pools p
     where p.order_date = d and p.site_id = si.id and p.kitchen_id = k.id
       and p.status = case when v_open then 'collecting' else 'waiting' end
       and pool_meals(p.id) + p_qty <= s.max_meals
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
            v_code, fee_for(1, pool_trip(pl.id)), s.service_fee, case when v_special is null then 'pending' else 'quote_requested' end, true)
    returning id into v_id;
  end if;

  if v_special is null then
    v_pay := settle_payment(v_id, p_ref, p_use_wallet);
  end if;

  return json_build_object('id', v_id, 'code', v_code, 'order_date', d, 'pool_seq', pl.seq, 'pool_status', pl.status,
    'pool_id', pl.id, 'meals', pool_meals(pl.id), 'status', (select status from orders where id = v_id), 'payment', v_pay,
    'parent_id', p_join);
end $$;
grant execute on function place_order(uuid, uuid, int, text, text, text, text[], text, text, boolean, uuid) to anon, authenticated;

-- ---------- Cancelling: a whole code (with its added plates) or just one added plate ----------
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
         cancel_reason = 'You cancelled' || coalesce(' (' || nullif(left(trim(p_reason), 80), '') || ')', ''),
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

-- ---------- Customer orders: added plates, reorder details, totals with the per-meal service fee ----------
drop function if exists my_orders(uuid[]);
create function my_orders(p_ids uuid[])
returns table (id uuid, order_date date, code text, status text, qty int, item_name text, site_id uuid,
               kitchen_id uuid, pool_seq int, pool_status text, special_request text, quote_price numeric,
               amount_due numeric, cancel_reason text, unit_price numeric, addons jsonb, addons_total numeric,
               max_fee numeric, service_fee numeric, wallet_used numeric, saving numeric, has_account boolean,
               refund_needed boolean, parent_id uuid, fee_per_meal boolean, item_id uuid, pool_id uuid, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select o.id, o.order_date, o.code, o.status, o.qty, o.item_name, o.site_id, o.kitchen_id, p.seq, p.status,
         o.special_request, o.quote_price,
         order_total(o) - o.wallet_used,
         o.cancel_reason, o.unit_price, o.addons, o.addons_total, o.max_fee, o.service_fee, o.wallet_used,
         case when o.status in ('pending', 'paid', 'collected') and p.status <> 'cancelled' then order_cashback(o.id) else 0 end,
         o.user_id is not null, o.refund_needed, o.parent_id, o.fee_per_meal, o.item_id, o.pool_id, o.created_at
  from orders o join pools p on p.id = o.pool_id
  where (o.id = any(p_ids) or o.parent_id = any(p_ids) or (auth.uid() is not null and o.user_id = auth.uid()))
    and o.order_date >= (now() at time zone 'utc')::date - 1
  order by o.created_at desc;
$$;
grant execute on function cancel_order(uuid, text, text), my_orders(uuid[]) to anon, authenticated;

-- ---------- Customers add a vendor anywhere (optional pin where they cook) ----------
drop function if exists add_vendor(uuid, text, text, jsonb);
create or replace function add_vendor(p_site uuid, p_name text, p_whatsapp text, p_items jsonb,
                                      p_lat float8 default null, p_lng float8 default null)
returns json language plpgsql security definer set search_path = public as $$
declare k kitchens; si sites; v_wa text := regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g'); it jsonb; n int := 0;
begin
  select * into si from sites where id = p_site and active and status = 'active';
  if not found then raise exception 'Pick your building first.'; end if;
  if char_length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Add the vendor''s name.'; end if;
  if v_wa !~ '^0[0-9]{9}$' then raise exception 'Enter the vendor''s 10-digit WhatsApp number, like 024 123 4567.'; end if;
  if (p_lat is null) <> (p_lng is null) or (p_lat is not null and (p_lat not between 4 and 12 or p_lng not between -4 and 2)) then
    raise exception 'Pin the vendor somewhere in Ghana.';
  end if;
  if (select count(*) from kitchens where site_id = p_site and created_at > now() - interval '1 day') >= 10 then
    raise exception 'Too many vendors were added here today. Ask the ChopPool team to help.';
  end if;
  insert into kitchens (name, public_name, tagline, whatsapp, capacity, site_id, added_by_customer, added_by, lat, lng)
  values (trim(p_name), trim(p_name), 'Added by a customer', v_wa, 30, p_site, true, auth.uid(), coalesce(p_lat, si.lat), coalesce(p_lng, si.lng))
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
grant execute on function add_vendor(uuid, text, text, jsonb, float8, float8) to anon, authenticated;

-- ---------- Vendor page: always-cooking days, pause, menu with extras and photos, codes grouped ----------
create or replace function kitchen_view(p_token text, p_date date)
returns json language plpgsql volatile security definer set search_path = public as $$
declare k kitchens;
begin
  perform housekeeping();
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid. Ask ChopPool for a new one.'; end if;
  return json_build_object(
    'kitchen', json_build_object('name', k.name, 'public_name', k.public_name, 'capacity', k.capacity,
                                 'delivery_mode', k.delivery_mode, 'added_by_customer', k.added_by_customer,
                                 'open', kitchen_is_open(k.id, p_date), 'listing_status', k.listing_status, 'listing', k.listing,
                                 'auto_days', k.auto_days, 'paused', p_date = any(k.paused_dates),
                                 'confirmed', exists (select 1 from kitchen_days where kitchen_id = k.id and order_date = p_date)),
    'menu', coalesce((select json_agg(json_build_object('id', id, 'name', name, 'price', price, 'addons', addons,
                                                        'photo_url', photo_url, 'icon', icon) order by name)
                      from menu_items where kitchen_id = k.id and active), '[]'::json),
    'pools', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'seq', p.seq, 'status', p.status, 'site', si.name, 'drop_point', si.drop_point,
        'handoff', si.handoff, 'host_label', si.host_label, 'created_at', p.created_at,
        'orders', (select json_agg(json_build_object('id', o.id, 'code', o.code, 'qty', o.qty, 'item_name', o.item_name,
                                                     'unit_price', o.unit_price, 'addons_total', o.addons_total,
                                                     'addons', o.addons, 'note', o.note, 'special_request', o.special_request,
                                                     'quote_price', o.quote_price, 'status', o.status, 'parent_id', o.parent_id,
                                                     'paid', o.status in ('paid', 'collected'), 'collected', o.status = 'collected')
                                   order by o.code, o.created_at)
                   from orders o where o.pool_id = p.id and o.status <> 'cancelled'))
        order by si.name, p.seq)
      from pools p join sites si on si.id = p.site_id
      where p.kitchen_id = k.id and p.order_date = p_date and p.status <> 'cancelled' and pool_meals(p.id) > 0
    ), '[]'::json));
end $$;

-- Vendors added by customers edit their own menu: dishes, prices and extras
create or replace function vendor_set_menu(p_token text, p_items jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare k kitchens; it jsonb; v_add jsonb;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  if not k.added_by_customer then raise exception 'ChopPool manages this menu. Contact the coordinator to change it.'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_add := case when jsonb_typeof(it -> 'addons') = 'array' then
      (select coalesce(jsonb_agg(jsonb_build_object('name', left(trim(a ->> 'name'), 40), 'price', greatest(0, coalesce(nullif(a ->> 'price', '')::numeric, 0)))), '[]'::jsonb)
         from jsonb_array_elements(it -> 'addons') a where char_length(trim(coalesce(a ->> 'name', ''))) >= 2) end;
    if it ? 'id' and nullif(it ->> 'id', '') is not null then
      update menu_items set name = coalesce(nullif(trim(it ->> 'name'), ''), name),
        price = coalesce(nullif(it ->> 'price', '')::numeric, price),
        addons = coalesce(v_add, addons),
        active = coalesce((it ->> 'active')::boolean, true)
      where id = (it ->> 'id')::uuid and kitchen_id = k.id;
    elsif char_length(trim(coalesce(it ->> 'name', ''))) >= 2 and coalesce(nullif(it ->> 'price', '')::numeric, 0) > 0 then
      insert into menu_items (kitchen_id, name, price, addons) values (k.id, trim(it ->> 'name'), (it ->> 'price')::numeric, coalesce(v_add, '[]'::jsonb));
    end if;
  end loop;
end $$;

-- Dish photos: public bucket "dish-photos". Vendors upload only into their own folder (a hash of their link, never the link itself).
create or replace function kitchen_folder(p_token text) returns text
language sql immutable set search_path = public, extensions as $$ select encode(digest(p_token, 'sha256'), 'hex'); $$;
create or replace function photo_folder_ok(p_folder text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select is_admin() or exists (select 1 from kitchens where active and encode(digest(token, 'sha256'), 'hex') = p_folder);
$$;
grant execute on function photo_folder_ok(text) to anon, authenticated;

create or replace function vendor_set_photo(p_token text, p_item uuid, p_url text)
returns void language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  if p_url is not null and position('/dish-photos/' || kitchen_folder(p_token) || '/' in p_url) = 0 then raise exception 'Upload the photo from your page.'; end if;
  update menu_items set photo_url = p_url where id = p_item and kitchen_id = k.id;
  if not found then raise exception 'That dish is not on your menu.'; end if;
end $$;

do $$ begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('dish-photos', 'dish-photos', true, 1048576, array['image/webp', 'image/jpeg', 'image/png'])
    on conflict (id) do update set public = true, file_size_limit = 1048576, allowed_mime_types = array['image/webp', 'image/jpeg', 'image/png'];
    execute 'drop policy if exists "dish photos read" on storage.objects';
    execute 'create policy "dish photos read" on storage.objects for select using (bucket_id = ''dish-photos'')';
    execute 'drop policy if exists "dish photos add" on storage.objects';
    execute 'create policy "dish photos add" on storage.objects for insert to anon, authenticated with check (bucket_id = ''dish-photos'' and public.photo_folder_ok((storage.foldername(name))[1]))';
    execute 'drop policy if exists "dish photos change" on storage.objects';
    execute 'create policy "dish photos change" on storage.objects for update to anon, authenticated using (bucket_id = ''dish-photos'' and public.photo_folder_ok((storage.foldername(name))[1]))';
    execute 'drop policy if exists "dish photos remove" on storage.objects';
    execute 'create policy "dish photos remove" on storage.objects for delete to anon, authenticated using (bucket_id = ''dish-photos'' and public.photo_folder_ok((storage.foldername(name))[1]))';
  end if;
end $$;

-- ---------- Handover: one code can hold several plates; typed codes in any form ----------
drop function if exists collect_code(text, text, date);
create or replace function collect_code(p_token text, p_code text, p_date date, p_pool uuid default null)
returns json language plpgsql security definer set search_path = public as $$
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
     and (r.token = p_token or si.host_token = p_token or (k.token = p_token and k.delivery_mode = 'runner'));
  if n = 0 then raise exception 'No order with code % for you today.', coalesce(nullif(v, ''), p_code); end if;
  if v_done = n then raise exception 'Code % was already collected.', v; end if;
  who := case when exists (select 1 from riders where token = p_token) then 'rider'
              when exists (select 1 from kitchens where token = p_token) then 'runner' else 'host' end;
  update orders set status = 'collected', collected_at = now(), collected_by = who where id = any(v_ids);
  return json_build_object('name', v_name, 'items', v_items, 'item_name', v_items, 'qty', v_qty, 'was_paid', v_paid, 'code', v);
end $$;
grant execute on function collect_code(text, text, date, uuid) to anon, authenticated;

-- ---------- Faster home screen: one call for everything the customer app shows ----------
create or replace function board_data(p_date date) returns json
language plpgsql volatile security definer set search_path = public as $$
begin
  perform housekeeping();
  return json_build_object(
    'pools', coalesce((select json_agg(x) from (select p.id, p.order_date, p.site_id, p.kitchen_id, p.seq, p.status, p.created_at, pool_meals(p.id) as meals
                                                  from pools p where p.order_date = p_date and p.status <> 'cancelled') x), '[]'::json),
    'load', coalesce((select json_object_agg(kitchen_id, meals) from (select kitchen_id, sum(qty)::int as meals from orders
                                                  where order_date = p_date and status <> 'cancelled' group by 1) l), '{}'::json),
    'activity', coalesce((select json_agg(a order by a.created_at desc) from (select * from recent_activity order by created_at desc limit 50) a), '[]'::json),
    'open', coalesce((select json_agg(k.id) from kitchens k where k.active and kitchen_is_open(k.id, p_date)), '[]'::json));
end $$;
grant execute on function board_data(date) to anon, authenticated;

create or replace view public_menus as
  select id, public_name, tagline, capacity, site_id, added_by_customer, lat, lng from kitchens where active;
grant select on public_menus to anon, authenticated;

-- ---------- Weekly report (Mon–Fri) for the team; money lines for the owner only ----------
create or replace function admin_weekly_report(p_week_start date) returns json
language plpgsql stable security definer set search_path = public as $$
declare s settings; w0 date := p_week_start; w1 date := p_week_start + 4; v0 date := p_week_start - 7; v1 date := p_week_start - 3;
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  select * into s from settings where id = 1;
  return (
  with o as (select o.*, p.status as pool_status from orders o join pools p on p.id = o.pool_id where o.order_date between v0 and w1),
  live as (select * from o where status in ('paid', 'collected', 'pending')),
  cur as (select * from live where order_date between w0 and w1),
  prev as (select * from live where order_date between v0 and v1),
  pl as (select p.*, pool_meals(p.id) as meals from pools p where p.order_date between v0 and w1),
  firsts as (select phone, min(order_date) as first_day from orders where status in ('paid', 'collected', 'pending') group by phone),
  head as (
    select wk, sum(qty)::int as meals, count(*) filter (where parent_id is null)::int as orders, count(distinct phone)::int as customers,
           count(distinct phone) filter (where (select first_day from firsts f where f.phone = x.phone) >= x.ws)::int as new_customers
    from (select *, 'cur' as wk, w0 as ws from cur union all select *, 'prev', v0 from prev) x group by wk),
  rep as (
    select wk, round(100.0 * count(*) filter (where n >= 2) / nullif(count(*), 0))::int as repeat_rate
    from (select 'cur' as wk, phone, count(distinct order_date) as n from live where order_date between w0 - 7 and w1 and phone in (select phone from cur) group by phone
          union all select 'prev', phone, count(distinct order_date) from live where order_date between v0 - 7 and v1 and phone in (select phone from prev) group by phone) r group by wk),
  pools_w as (
    select case when order_date >= w0 then 'cur' else 'prev' end as wk, round(avg(meals), 1) as avg_meals,
           count(*) filter (where meals >= s.max_meals)::int as filled, count(*)::int as pools
    from pl where status <> 'cancelled' and meals > 0 group by 1),
  canc as (select case when order_date >= w0 then 'cur' else 'prev' end as wk, count(*)::int as n from o where status = 'cancelled' group by 1)
  select json_build_object(
    'week_start', w0, 'week_end', w1,
    'headline', (select json_object_agg(h.wk, json_build_object('meals', h.meals, 'orders', h.orders, 'customers', h.customers, 'new_customers', h.new_customers,
                    'repeat_rate', (select repeat_rate from rep where rep.wk = h.wk), 'avg_meals', (select avg_meals from pools_w where pools_w.wk = h.wk),
                    'pools', (select pools from pools_w where pools_w.wk = h.wk), 'filled', (select filled from pools_w where pools_w.wk = h.wk),
                    'cancelled', coalesce((select n from canc where canc.wk = h.wk), 0))) from head h),
    'money', case when is_super() then (select json_build_object(
        'food', round(coalesce(sum((coalesce(quote_price, unit_price) + addons_total) * qty), 0), 2),
        'commission', round(coalesce(sum((coalesce(quote_price, unit_price) + addons_total) * qty), 0) * s.commission_rate, 2),
        'service_fees', round(coalesce(sum(service_fee * case when fee_per_meal then qty else 1 end), 0), 2),
        'cashback', round(coalesce(sum(case when parent_id is null and status in ('paid', 'collected') then order_cashback(id) else 0 end), 0), 2),
        'refunds', round(coalesce((select sum(amount) from wallet_entries where amount > 0 and reason like 'Refund%' and created_at::date between w0 and w1 + 2), 0), 2),
        'momo_refunds', (select count(*) from orders where refund_needed and order_date between w0 and w1),
        'wallets_owed', round(coalesce((select sum(wallet_balance(u)) from (select distinct user_id as u from orders where user_id is not null union select distinct user_id from wallet_entries) us), 0), 2))
      from cur) end,
    'buildings', coalesce((select json_agg(b order by b.meals desc) from (
        select si.name, sum(c.qty)::int as meals, count(distinct c.pool_id)::int as pools,
               round(sum(c.qty)::numeric / nullif(count(distinct c.pool_id), 0), 1) as avg_pool,
               coalesce((select sum(qty) from prev where prev.site_id = si.id), 0)::int as prev_meals
        from cur c join sites si on si.id = c.site_id group by si.id, si.name order by 2 desc limit 15) b), '[]'::json),
    'quiet', coalesce((select json_agg(q) from (
        select si.name, sum(p.qty)::int as prev_meals from prev p join sites si on si.id = p.site_id
        where not exists (select 1 from cur c where c.site_id = p.site_id) group by si.name order by 2 desc) q), '[]'::json),
    'customers', coalesce((select json_agg(c2) from (
        select (array_agg(customer_name order by created_at desc))[1] as name,
               (select si.name from cur c3 join sites si on si.id = c3.site_id where c3.phone = c.phone group by si.name order by count(*) desc limit 1) as building,
               case when is_super() then c.phone end as phone,
               count(*) filter (where parent_id is null)::int as orders, sum(qty)::int as meals
        from cur c group by c.phone order by sum(qty) desc, count(*) desc limit 15) c2), '[]'::json),
    'vendors', coalesce((select json_agg(v order by v.meals desc) from (
        select k.public_name as name, coalesce(sum(c.qty), 0)::int as meals,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status <> 'cancelled' and pl.meals > 0)::int as pools,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status = 'cancelled'
                  and exists (select 1 from orders x where x.pool_id = pl.id and x.cancel_reason = 'The seller did not confirm in time'))::int as expired,
               (select round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*) filter (where pl.delivered_at is not null), 0))
                  from pl where pl.kitchen_id = k.id and pl.order_date >= w0)::int as on_time,
               (select count(*) from o where o.kitchen_id = k.id and o.order_date >= w0 and o.cancel_reason like 'The seller can''t%')::int as declined,
               (select count(*) from (select phone from live where live.kitchen_id = k.id and live.order_date between w0 - 28 and w1 group by phone having count(distinct order_date) >= 2) r)::int as repeat_customers,
               cardinality(k.auto_days) > 0 as always_cooking
        from kitchens k left join cur c on c.kitchen_id = k.id where k.active
        group by k.id, k.public_name, k.auto_days having coalesce(sum(c.qty), 0) > 0
           or exists (select 1 from pl where pl.kitchen_id = k.id and pl.order_date >= w0)) v), '[]'::json),
    'riders', coalesce((select json_agg(r) from (
        select rd.name, count(*)::int as deliveries,
               round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*), 0))::int as on_time
        from pl join riders rd on rd.id = pl.rider_id where pl.order_date >= w0 and pl.delivered_at is not null group by rd.name order by 2 desc) r), '[]'::json)
  ));
end $$;
grant execute on function admin_weekly_report(date) to authenticated;

grant execute on function kitchen_set_auto(text, int[]), kitchen_pause(text, date, boolean), vendor_set_photo(text, uuid, text),
  vendor_set_menu(text, jsonb), kitchen_view(text, date), kitchen_open_day(text, date) to anon, authenticated;


-- ---------- from update15 ----------
-- =====================================================================
-- Update 15: when a vendor doesn't confirm in time, paid money goes straight to the customer's wallet
-- (guests get a MoMo refund, or the wallet credit if they create an account first)
-- =====================================================================
alter table orders add column if not exists refund_due numeric not null default 0;   -- confirmed payment to return when a vendor doesn't confirm

create or replace function housekeeping() returns void
language plpgsql volatile security definer set search_path = public as $$
declare s settings;
begin
  select * into s from settings where id = 1;

  -- Vendors who didn't confirm in time: confirmed payments come back to the wallet (account holders) or by MoMo (guests)
  with expired as (
    update pools set status = 'cancelled'
    where status = 'waiting' and created_at < now() - make_interval(mins => s.accept_timeout_min)
    returning id)
  update orders o set status = 'cancelled', cancel_reason = 'The seller did not confirm in time',
                      refund_due = case when o.status in ('paid', 'collected') then greatest(0, order_total(o) - o.wallet_used) else 0 end,
                      refund_needed = (o.momo_ref is not null and not (o.user_id is not null and o.status in ('paid', 'collected')))
  from expired e where o.pool_id = e.id and o.status <> 'cancelled';

  -- Wallet part of any cancelled order goes back to the wallet
  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.wallet_used, 'Refund: ' || coalesce(o.cancel_reason, 'order cancelled'), o.id
  from orders o
  where o.status = 'cancelled' and o.wallet_used > 0 and o.user_id is not null
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.amount > 0 and w.reason like 'Refund:%');

  -- MoMo part of a confirmed payment, for account holders, once (never when ChopPool refunds the MoMo instead)
  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.refund_due, 'Money back: the vendor didn''t confirm, code ' || o.code, o.id
  from orders o
  where o.status = 'cancelled' and o.refund_due > 0 and o.user_id is not null and not o.refund_needed
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.reason like 'Money back:%');

  update orders set status = 'cancelled', cancel_reason = 'Special request not paid before cut-off'
  where status in ('quote_requested', 'quoted')
    and (now() at time zone 'utc') >= order_date + s.cutoff;
end $$;

-- A guest who creates an account: money waiting for a MoMo refund goes to the new wallet instead
create or replace function claim_orders(p_ids uuid[]) returns int
language plpgsql volatile security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null then return 0; end if;
  update orders set user_id = auth.uid() where id = any(p_ids) and user_id is null;
  get diagnostics n = row_count;
  update orders set refund_needed = false
   where id = any(p_ids) and user_id = auth.uid() and status = 'cancelled' and refund_due > 0 and refund_needed;
  perform housekeeping();
  return n;
end $$;
grant execute on function claim_orders(uuid[]) to authenticated;

-- Orders now say how much came (or can come) back to the wallet
drop function if exists my_orders(uuid[]);
create function my_orders(p_ids uuid[])
returns table (id uuid, order_date date, code text, status text, qty int, item_name text, site_id uuid,
               kitchen_id uuid, pool_seq int, pool_status text, special_request text, quote_price numeric,
               amount_due numeric, cancel_reason text, unit_price numeric, addons jsonb, addons_total numeric,
               max_fee numeric, service_fee numeric, wallet_used numeric, saving numeric, has_account boolean,
               refund_needed boolean, parent_id uuid, fee_per_meal boolean, item_id uuid, pool_id uuid, created_at timestamptz,
               refund_due numeric)
language sql stable security definer set search_path = public as $$
  select o.id, o.order_date, o.code, o.status, o.qty, o.item_name, o.site_id, o.kitchen_id, p.seq, p.status,
         o.special_request, o.quote_price,
         order_total(o) - o.wallet_used,
         o.cancel_reason, o.unit_price, o.addons, o.addons_total, o.max_fee, o.service_fee, o.wallet_used,
         case when o.status in ('pending', 'paid', 'collected') and p.status <> 'cancelled' then order_cashback(o.id) else 0 end,
         o.user_id is not null, o.refund_needed, o.parent_id, o.fee_per_meal, o.item_id, o.pool_id, o.created_at, o.refund_due
  from orders o join pools p on p.id = o.pool_id
  where (o.id = any(p_ids) or o.parent_id = any(p_ids) or (auth.uid() is not null and o.user_id = auth.uid()))
    and o.order_date >= (now() at time zone 'utc')::date - 1
  order by o.created_at desc;
$$;
grant execute on function my_orders(uuid[]) to anon, authenticated;

-- ---------- from update16 ----------
-- =====================================================================
-- Update 16: customer ratings and photos (only from collected orders), hidden by the team when needed
-- =====================================================================
create table if not exists reviews (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references orders(id),
  kitchen_id uuid not null references kitchens(id),
  site_id uuid references sites(id),
  user_id uuid,
  rating int not null check (rating between 1 and 5),
  comment text check (comment is null or char_length(comment) <= 280),
  photo_url text,
  hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists reviews_kitchen_idx on reviews (kitchen_id, created_at desc);
alter table reviews enable row level security;
drop policy if exists "team reviews" on reviews;
create policy "team reviews" on reviews for all to authenticated using (is_admin()) with check (is_admin());
grant select, update on reviews to authenticated;

-- What customers see: rating, comment, photo and first name only (never phone numbers or accounts)
create or replace view public_reviews as
  select r.id, r.kitchen_id, r.rating, r.comment, r.photo_url, r.created_at,
         split_part(trim(o.customer_name), ' ', 1) as name, o.item_name
  from reviews r join orders o on o.id = r.order_id
  where not r.hidden;
grant select on public_reviews to anon, authenticated;

-- Rate a collected order (and add a photo). Same phone or account that placed it; can be changed later.
create or replace function submit_review(p_order uuid, p_phone text, p_rating int, p_comment text default null, p_photo text default null)
returns json language plpgsql security definer set search_path = public as $$
declare o orders; v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  select * into o from orders where id = p_order and parent_id is null;
  if not found then raise exception 'Order not found.'; end if;
  if not ((auth.uid() is not null and o.user_id = auth.uid()) or o.phone = v_phone) then raise exception 'Use the phone or account that placed the order.'; end if;
  if o.status <> 'collected' then raise exception 'You can rate your lunch once you''ve collected it.'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Choose 1 to 5 stars.'; end if;
  if p_photo is not null and position('/dish-photos/reviews/' || o.id::text || '/' in p_photo) = 0 then raise exception 'Upload the photo from your order.'; end if;
  insert into reviews (order_id, kitchen_id, site_id, user_id, rating, comment, photo_url)
  values (o.id, o.kitchen_id, o.site_id, o.user_id, p_rating, nullif(left(trim(coalesce(p_comment, '')), 280), ''), p_photo)
  on conflict (order_id) do update set rating = excluded.rating, comment = excluded.comment,
    photo_url = coalesce(excluded.photo_url, reviews.photo_url), updated_at = now();
  return json_build_object('ok', true);
end $$;
grant execute on function submit_review(uuid, text, int, text, text) to anon, authenticated;

-- Photos for a review go in dish-photos/reviews/<order id>/, only for an order collected in the last 7 days
create or replace function review_folder_ok(p_order text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from orders where id::text = p_order and status = 'collected' and order_date > (now() at time zone 'utc')::date - 7);
$$;
grant execute on function review_folder_ok(text) to anon, authenticated;
do $$ begin
  if to_regclass('storage.objects') is not null then
    execute 'drop policy if exists "review photos add" on storage.objects';
    execute 'create policy "review photos add" on storage.objects for insert to anon, authenticated with check (bucket_id = ''dish-photos'' and (storage.foldername(name))[1] = ''reviews'' and public.review_folder_ok((storage.foldername(name))[2]))';
  end if;
end $$;

-- Orders show whether you've rated them
drop function if exists my_orders(uuid[]);
create function my_orders(p_ids uuid[])
returns table (id uuid, order_date date, code text, status text, qty int, item_name text, site_id uuid,
               kitchen_id uuid, pool_seq int, pool_status text, special_request text, quote_price numeric,
               amount_due numeric, cancel_reason text, unit_price numeric, addons jsonb, addons_total numeric,
               max_fee numeric, service_fee numeric, wallet_used numeric, saving numeric, has_account boolean,
               refund_needed boolean, parent_id uuid, fee_per_meal boolean, item_id uuid, pool_id uuid, created_at timestamptz,
               refund_due numeric, my_rating int, my_photo text)
language sql stable security definer set search_path = public as $$
  select o.id, o.order_date, o.code, o.status, o.qty, o.item_name, o.site_id, o.kitchen_id, p.seq, p.status,
         o.special_request, o.quote_price,
         order_total(o) - o.wallet_used,
         o.cancel_reason, o.unit_price, o.addons, o.addons_total, o.max_fee, o.service_fee, o.wallet_used,
         case when o.status in ('pending', 'paid', 'collected') and p.status <> 'cancelled' then order_cashback(o.id) else 0 end,
         o.user_id is not null, o.refund_needed, o.parent_id, o.fee_per_meal, o.item_id, o.pool_id, o.created_at, o.refund_due,
         r.rating, r.photo_url
  from orders o join pools p on p.id = o.pool_id left join reviews r on r.order_id = o.id
  where (o.id = any(p_ids) or o.parent_id = any(p_ids) or (auth.uid() is not null and o.user_id = auth.uid()))
    and o.order_date >= (now() at time zone 'utc')::date - 1
  order by o.created_at desc;
$$;
grant execute on function my_orders(uuid[]) to anon, authenticated;

-- Vendor scores now include the average rating (last 90 days, hidden reviews excluded)
create or replace view kitchen_scores as
  with p as (
    select pl.kitchen_id, pl.id, pl.status, pl.delivered_at, pl.order_date,
           exists (select 1 from orders o where o.pool_id = pl.id and o.cancel_reason in ('The seller did not confirm in time') ) as no_show
    from pools pl where pl.order_date > (now() at time zone 'utc')::date - 90),
  o as (select kitchen_id, phone, count(*) as n from orders where status in ('paid', 'collected') and order_date > (now() at time zone 'utc')::date - 90 group by 1, 2)
  select k.id as kitchen_id,
    coalesce((select sum(n) from o where o.kitchen_id = k.id), 0)::int as orders,
    (select round(100.0 * count(*) filter (where p.delivered_at <= (p.order_date + s.delivery_time + interval '15 minutes')) / nullif(count(*) filter (where p.delivered_at is not null), 0))
       from p cross join settings s where s.id = 1 and p.kitchen_id = k.id)::int as on_time,
    (select round(100.0 * count(*) filter (where p.status <> 'cancelled') / nullif(count(*) filter (where p.status <> 'cancelled' or p.no_show), 0)) from p where p.kitchen_id = k.id)::int as reliable,
    (select round(100.0 * count(*) filter (where o.n >= 2) / nullif(count(*), 0)) from o where o.kitchen_id = k.id)::int as come_back,
    (select round(avg(r.rating), 1) from reviews r where r.kitchen_id = k.id and not r.hidden and r.created_at > now() - interval '90 days') as rating,
    (select count(*) from reviews r where r.kitchen_id = k.id and not r.hidden and r.created_at > now() - interval '90 days')::int as ratings
  from kitchens k where k.active and not k.archived;
grant select on kitchen_scores to anon, authenticated;

-- Weekly report: average rating per vendor
create or replace function admin_weekly_report(p_week_start date) returns json
language plpgsql stable security definer set search_path = public as $$
declare s settings; w0 date := p_week_start; w1 date := p_week_start + 4; v0 date := p_week_start - 7; v1 date := p_week_start - 3;
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  select * into s from settings where id = 1;
  return (
  with o as (select o.*, p.status as pool_status from orders o join pools p on p.id = o.pool_id where o.order_date between v0 and w1),
  live as (select * from o where status in ('paid', 'collected', 'pending')),
  cur as (select * from live where order_date between w0 and w1),
  prev as (select * from live where order_date between v0 and v1),
  pl as (select p.*, pool_meals(p.id) as meals from pools p where p.order_date between v0 and w1),
  firsts as (select phone, min(order_date) as first_day from orders where status in ('paid', 'collected', 'pending') group by phone),
  head as (
    select wk, sum(qty)::int as meals, count(*) filter (where parent_id is null)::int as orders, count(distinct phone)::int as customers,
           count(distinct phone) filter (where (select first_day from firsts f where f.phone = x.phone) >= x.ws)::int as new_customers
    from (select *, 'cur' as wk, w0 as ws from cur union all select *, 'prev', v0 from prev) x group by wk),
  rep as (
    select wk, round(100.0 * count(*) filter (where n >= 2) / nullif(count(*), 0))::int as repeat_rate
    from (select 'cur' as wk, phone, count(distinct order_date) as n from live where order_date between w0 - 7 and w1 and phone in (select phone from cur) group by phone
          union all select 'prev', phone, count(distinct order_date) from live where order_date between v0 - 7 and v1 and phone in (select phone from prev) group by phone) r group by wk),
  pools_w as (
    select case when order_date >= w0 then 'cur' else 'prev' end as wk, round(avg(meals), 1) as avg_meals,
           count(*) filter (where meals >= s.max_meals)::int as filled, count(*)::int as pools
    from pl where status <> 'cancelled' and meals > 0 group by 1),
  canc as (select case when order_date >= w0 then 'cur' else 'prev' end as wk, count(*)::int as n from o where status = 'cancelled' group by 1)
  select json_build_object(
    'week_start', w0, 'week_end', w1,
    'headline', (select json_object_agg(h.wk, json_build_object('meals', h.meals, 'orders', h.orders, 'customers', h.customers, 'new_customers', h.new_customers,
                    'repeat_rate', (select repeat_rate from rep where rep.wk = h.wk), 'avg_meals', (select avg_meals from pools_w where pools_w.wk = h.wk),
                    'pools', (select pools from pools_w where pools_w.wk = h.wk), 'filled', (select filled from pools_w where pools_w.wk = h.wk),
                    'cancelled', coalesce((select n from canc where canc.wk = h.wk), 0))) from head h),
    'money', case when is_super() then (select json_build_object(
        'food', round(coalesce(sum((coalesce(quote_price, unit_price) + addons_total) * qty), 0), 2),
        'commission', round(coalesce(sum((coalesce(quote_price, unit_price) + addons_total) * qty), 0) * s.commission_rate, 2),
        'service_fees', round(coalesce(sum(service_fee * case when fee_per_meal then qty else 1 end), 0), 2),
        'cashback', round(coalesce(sum(case when parent_id is null and status in ('paid', 'collected') then order_cashback(id) else 0 end), 0), 2),
        'refunds', round(coalesce((select sum(amount) from wallet_entries where amount > 0 and reason like 'Refund%' and created_at::date between w0 and w1 + 2), 0), 2),
        'momo_refunds', (select count(*) from orders where refund_needed and order_date between w0 and w1),
        'wallets_owed', round(coalesce((select sum(wallet_balance(u)) from (select distinct user_id as u from orders where user_id is not null union select distinct user_id from wallet_entries) us), 0), 2))
      from cur) end,
    'buildings', coalesce((select json_agg(b order by b.meals desc) from (
        select si.name, sum(c.qty)::int as meals, count(distinct c.pool_id)::int as pools,
               round(sum(c.qty)::numeric / nullif(count(distinct c.pool_id), 0), 1) as avg_pool,
               coalesce((select sum(qty) from prev where prev.site_id = si.id), 0)::int as prev_meals
        from cur c join sites si on si.id = c.site_id group by si.id, si.name order by 2 desc limit 15) b), '[]'::json),
    'quiet', coalesce((select json_agg(q) from (
        select si.name, sum(p.qty)::int as prev_meals from prev p join sites si on si.id = p.site_id
        where not exists (select 1 from cur c where c.site_id = p.site_id) group by si.name order by 2 desc) q), '[]'::json),
    'customers', coalesce((select json_agg(c2) from (
        select (array_agg(customer_name order by created_at desc))[1] as name,
               (select si.name from cur c3 join sites si on si.id = c3.site_id where c3.phone = c.phone group by si.name order by count(*) desc limit 1) as building,
               case when is_super() then c.phone end as phone,
               count(*) filter (where parent_id is null)::int as orders, sum(qty)::int as meals
        from cur c group by c.phone order by sum(qty) desc, count(*) desc limit 15) c2), '[]'::json),
    'vendors', coalesce((select json_agg(v order by v.meals desc) from (
        select k.public_name as name, coalesce(sum(c.qty), 0)::int as meals,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status <> 'cancelled' and pl.meals > 0)::int as pools,
               (select count(*) from pl where pl.kitchen_id = k.id and pl.order_date >= w0 and pl.status = 'cancelled'
                  and exists (select 1 from orders x where x.pool_id = pl.id and x.cancel_reason = 'The seller did not confirm in time'))::int as expired,
               (select round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*) filter (where pl.delivered_at is not null), 0))
                  from pl where pl.kitchen_id = k.id and pl.order_date >= w0)::int as on_time,
               (select count(*) from o where o.kitchen_id = k.id and o.order_date >= w0 and o.cancel_reason like 'The seller can''t%')::int as declined,
               (select count(*) from (select phone from live where live.kitchen_id = k.id and live.order_date between w0 - 28 and w1 group by phone having count(distinct order_date) >= 2) r)::int as repeat_customers,
               cardinality(k.auto_days) > 0 as always_cooking,
               (select round(avg(r.rating), 1) from reviews r where r.kitchen_id = k.id and not r.hidden and r.created_at::date between w0 and w1 + 2) as rating
        from kitchens k left join cur c on c.kitchen_id = k.id where k.active
        group by k.id, k.public_name, k.auto_days having coalesce(sum(c.qty), 0) > 0
           or exists (select 1 from pl where pl.kitchen_id = k.id and pl.order_date >= w0)) v), '[]'::json),
    'riders', coalesce((select json_agg(r) from (
        select rd.name, count(*)::int as deliveries,
               round(100.0 * count(*) filter (where pl.delivered_at <= pl.order_date + s.delivery_time + interval '15 minutes') / nullif(count(*), 0))::int as on_time
        from pl join riders rd on rd.id = pl.rider_id where pl.order_date >= w0 and pl.delivered_at is not null group by rd.name order by 2 desc) r), '[]'::json)
  ));
end $$;
grant execute on function admin_weekly_report(date) to authenticated;

notify pgrst, 'reload schema';
select 'ChopPool database is up to date (version 16)' as result;
