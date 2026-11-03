-- =====================================================================
-- ChopPool pilot database, version 10
-- Run once in Supabase: SQL Editor > New query > paste everything > Run.
-- If you ran an earlier version, run the RESET block at the very bottom
-- first (it deletes pilot test data), then run this whole file.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table if not exists settings (
  id int primary key default 1 check (id = 1),
  cutoff time not null default '10:30',
  special_cutoff time not null default '10:00',   -- special requests must come in before this
  delivery_time time not null default '12:30',
  trip_cost numeric not null default 60,           -- one rider trip (GHS)
  max_fee numeric not null default 10,             -- most anyone pays for delivery, per meal (GHS)
  service_fee numeric not null default 2,          -- per order (GHS)
  min_pool int not null default 6,                 -- meals; below this the pool is flagged
  max_meals int not null default 15,               -- meals per pool = one motorbike load
  commission_rate numeric not null default 0.15,
  accept_timeout_min int not null default 20,      -- how long a seller has to confirm the first order
  arrival_window_min int not null default 10,      -- how long the rider waits at meet-the-rider sites
  notify_daily_cap int not null default 5,         -- max "someone ordered" alerts per person per day
  momo_number text not null default '024 000 0000',
  momo_name text not null default 'ChopPool Pilot'
);

create table if not exists sites (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  drop_point text not null,
  handoff text not null default 'meet_rider' check (handoff in ('meet_rider', 'host')),
  host_label text,
  host_token text not null unique default encode(gen_random_bytes(9), 'hex'),
  lat double precision,                            -- map pin
  lng double precision,
  status text not null default 'active' check (status in ('active', 'pending', 'declined')),
  requested_by uuid,                               -- customer who asked for this building
  request_note text,
  created_at timestamptz not null default now(),
  active boolean not null default true
);

-- Kitchens and sellers. ChopPool partner kitchens have site_id null (all drop points).
-- Sellers added by a customer have site_id set (only that drop point) and added_by_customer true.
create table if not exists kitchens (
  id uuid primary key default gen_random_uuid(),
  name text not null,                              -- real name (hidden from customers for partner kitchens)
  public_name text not null,                       -- menu name customers see
  tagline text,
  address text,
  whatsapp text,                                   -- e.g. 0241234567; tickets and the link go here
  capacity int not null default 45,                -- meals per lunch wave
  delivery_mode text not null default 'rider' check (delivery_mode in ('rider', 'runner')),
  site_id uuid references sites(id),
  added_by_customer boolean not null default false,
  added_by uuid,
  token text not null unique default encode(gen_random_bytes(9), 'hex'),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists menu_items (
  id uuid primary key default gen_random_uuid(),
  kitchen_id uuid not null references kitchens(id),
  name text not null,
  price numeric not null check (price > 0),
  addons jsonb not null default '[]',              -- [{"name":"Extra chicken","price":15},{"name":"No shito","price":0}]
  active boolean not null default true
);

-- A seller confirming they are cooking on a given day
create table if not exists kitchen_days (
  kitchen_id uuid not null references kitchens(id),
  order_date date not null,
  opened_at timestamptz not null default now(),
  primary key (kitchen_id, order_date)
);

create table if not exists riders (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  token text not null unique default encode(gen_random_bytes(9), 'hex'),
  active boolean not null default true
);

create table if not exists pools (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  order_date date not null,
  site_id uuid not null references sites(id),
  kitchen_id uuid not null references kitchens(id),
  seq int not null default 1,
  status text not null default 'collecting'
    check (status in ('waiting','collecting','accepted','ready','picked_up','arriving','delivered','cancelled')),
  rider_id uuid references riders(id),
  trip_ref text,
  trip_cost numeric,
  accepted_at timestamptz, ready_at timestamptz, picked_up_at timestamptz,
  arriving_at timestamptz, delivered_at timestamptz,
  unique (order_date, site_id, kitchen_id, seq)
);

create table if not exists orders (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  order_date date not null,
  pool_id uuid not null references pools(id),
  site_id uuid not null references sites(id),
  kitchen_id uuid not null references kitchens(id),
  item_id uuid not null references menu_items(id),
  user_id uuid,                                    -- set when the customer has an account
  item_name text not null,
  unit_price numeric not null,
  qty int not null check (qty between 1 and 5),
  addons jsonb not null default '[]',
  addons_total numeric not null default 0,         -- per meal
  note text check (note is null or char_length(note) <= 140),
  special_request text check (special_request is null or char_length(special_request) <= 300),
  quote_price numeric,                             -- per meal, set by the seller for special requests
  customer_name text not null check (char_length(customer_name) between 2 and 80),
  phone text not null check (phone ~ '^0[0-9]{9}$'),
  momo_ref text check (momo_ref is null or char_length(momo_ref) between 4 and 40),
  wallet_used numeric not null default 0,
  code text not null,
  max_fee numeric not null,
  service_fee numeric not null,
  status text not null default 'pending'
    check (status in ('quote_requested','quoted','pending','paid','collected','cancelled')),
  cancel_reason text,
  refund_needed boolean not null default false,
  collected_at timestamptz,
  collected_by text
);
create index if not exists orders_pool_idx on orders (pool_id);
create index if not exists orders_date_idx on orders (order_date, kitchen_id);
create index if not exists orders_user_idx on orders (user_id);

create table if not exists profiles (
  user_id uuid primary key,
  email text,
  name text,
  phone text,
  created_at timestamptz not null default now()
);

create table if not exists wallet_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  amount numeric not null,                         -- positive = credit, negative = spent
  reason text not null,
  order_id uuid references orders(id),
  created_by text not null default 'system',
  created_at timestamptz not null default now()
);
create index if not exists wallet_user_idx on wallet_entries (user_id);

-- ChopPool team. role 'super' = owner (manages the team), 'coordinator' = runs daily operations
create table if not exists admins (
  email text primary key,
  role text not null default 'coordinator' check (role in ('super', 'coordinator')),
  added_by text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create or replace function current_order_date() returns date
language sql stable set search_path = public as $$
  select case extract(isodow from d) when 6 then d + 2 when 7 then d + 1 else d end
  from (select case when (now() at time zone 'utc')::time >= (select cutoff from settings where id = 1)
                    then (now() at time zone 'utc')::date + 1
                    else (now() at time zone 'utc')::date end as d) x;
$$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where email = lower(auth.jwt() ->> 'email'));
$$;

create or replace function is_super() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where email = lower(auth.jwt() ->> 'email') and role = 'super');
$$;

-- The very first signed-in person to call this becomes the owner (super admin). Works only while the team is empty.
create or replace function claim_owner() returns text
language plpgsql security definer set search_path = public as $$
declare v_email text := lower(auth.jwt() ->> 'email');
begin
  if v_email is null then raise exception 'Sign in first.'; end if;
  perform pg_advisory_xact_lock(hashtext('claim_owner'));
  if exists (select 1 from admins) then raise exception 'This ChopPool already has an owner. Ask them to add you to the team.'; end if;
  insert into admins (email, role, added_by) values (v_email, 'super', 'self');
  return 'super';
end $$;

create or replace function my_role() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select role from admins where email = lower(auth.jwt() ->> 'email')),
                  case when exists (select 1 from admins) then 'none' else 'unclaimed' end);
$$;

create or replace function pool_meals(p uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(qty), 0)::int from orders where pool_id = p and status <> 'cancelled';
$$;

-- Delivery share per meal for a pool of p_meals meals
create or replace function fee_for(p_meals int) returns numeric
language sql stable security definer set search_path = public as $$
  select case when p_meals <= 0 then s.max_fee
              else least(s.max_fee, ceil(s.trip_cost / p_meals * 2) / 2) end
  from settings s where s.id = 1;
$$;

-- Wallet = credits and spending in the ledger + delivery cashback from closed pools
create or replace function wallet_balance(p_user uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select round(
    coalesce((select sum(amount) from wallet_entries where user_id = p_user), 0) +
    coalesce((select sum(greatest(0, (o.max_fee - fee_for(pool_meals(o.pool_id))) * o.qty))
              from orders o join pools p on p.id = o.pool_id cross join settings s
              where s.id = 1 and o.user_id = p_user and o.status in ('paid', 'collected')
                and p.status <> 'cancelled'
                and (now() at time zone 'utc') >= o.order_date + s.cutoff), 0), 2);
$$;

-- Tidy-up run on every page refresh: sellers who didn't confirm, and unpaid special requests
create or replace function housekeeping() returns void
language plpgsql volatile security definer set search_path = public as $$
declare s settings;
begin
  select * into s from settings where id = 1;

  with expired as (
    update pools set status = 'cancelled'
    where status = 'waiting' and created_at < now() - make_interval(mins => s.accept_timeout_min)
    returning id)
  update orders o set status = 'cancelled', cancel_reason = 'The seller did not confirm in time',
                      refund_needed = (o.momo_ref is not null)
  from expired e where o.pool_id = e.id and o.status <> 'cancelled';

  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.wallet_used, 'Refund: ' || coalesce(o.cancel_reason, 'order cancelled'), o.id
  from orders o
  where o.status = 'cancelled' and o.wallet_used > 0 and o.user_id is not null
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.amount > 0);

  update orders set status = 'cancelled', cancel_reason = 'Special request not paid before cut-off'
  where status in ('quote_requested', 'quoted')
    and (now() at time zone 'utc') >= order_date + s.cutoff;
end $$;

-- Is this seller cooking today? true/false; opens waiting pools when it is
create or replace function kitchen_is_open(p_kitchen uuid, p_date date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from kitchen_days where kitchen_id = p_kitchen and order_date = p_date);
$$;

-- Take payment for an order: wallet first (signed-in customers), then MoMo for the rest
create or replace function settle_payment(p_order uuid, p_ref text, p_use_wallet boolean)
returns json language plpgsql security definer set search_path = public as $$
declare o orders; v_total numeric; v_bal numeric; v_use numeric := 0; v_uid uuid := auth.uid();
begin
  select * into o from orders where id = p_order;
  v_total := (coalesce(o.quote_price, o.unit_price) + o.addons_total) * o.qty + o.max_fee * o.qty + o.service_fee;
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

-- ---------------------------------------------------------------------
-- Customers
-- ---------------------------------------------------------------------
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
          v_code, s.max_fee, s.service_fee, case when v_special is null then 'pending' else 'quote_requested' end)
  returning id into v_id;

  if v_special is null then
    v_pay := settle_payment(v_id, p_ref, p_use_wallet);
  end if;

  return json_build_object('id', v_id, 'code', v_code, 'order_date', d, 'pool_seq', pl.seq, 'pool_status', pl.status,
    'meals', pool_meals(pl.id), 'status', (select status from orders where id = v_id), 'payment', v_pay);
end $$;

-- Pay for a special request once the seller has priced it
create or replace function pay_quote(p_order uuid, p_ref text, p_use_wallet boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  perform housekeeping();
  select * into o from orders where id = p_order;
  if not found or o.status <> 'quoted' then raise exception 'This request is not waiting for payment.'; end if;
  return settle_payment(o.id, p_ref, p_use_wallet);
end $$;

-- Orders on this phone (by id) and, when signed in, all of the customer's orders
create or replace function my_orders(p_ids uuid[])
returns table (id uuid, order_date date, code text, status text, qty int, item_name text, site_id uuid,
               kitchen_id uuid, pool_seq int, pool_status text, special_request text, quote_price numeric,
               amount_due numeric, cancel_reason text)
language sql stable security definer set search_path = public as $$
  select o.id, o.order_date, o.code, o.status, o.qty, o.item_name, o.site_id, o.kitchen_id, p.seq, p.status,
         o.special_request, o.quote_price,
         (coalesce(o.quote_price, o.unit_price) + o.addons_total) * o.qty + o.max_fee * o.qty + o.service_fee - o.wallet_used,
         o.cancel_reason
  from orders o join pools p on p.id = o.pool_id
  where (o.id = any(p_ids) or (auth.uid() is not null and o.user_id = auth.uid()))
    and o.order_date >= (now() at time zone 'utc')::date - 1
  order by o.created_at desc;
$$;

-- Attach guest orders made on this phone to the new account (their cashback follows)
create or replace function claim_orders(p_ids uuid[]) returns int
language sql volatile security definer set search_path = public as $$
  with c as (update orders set user_id = auth.uid() where auth.uid() is not null and id = any(p_ids) and user_id is null returning 1)
  select count(*)::int from c;
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
        select o.order_date + s.cutoff, round((o.max_fee - fee_for(pool_meals(o.pool_id))) * o.qty, 2),
               'Delivery cashback, code ' || o.code
        from orders o join pools p on p.id = o.pool_id cross join settings s
        where s.id = 1 and o.user_id = v_uid and o.status in ('paid', 'collected') and p.status <> 'cancelled'
          and (now() at time zone 'utc') >= o.order_date + s.cutoff
          and o.max_fee > fee_for(pool_meals(o.pool_id))
        order by 1 desc limit 30) x), '[]'::json));
end $$;

-- A customer adds a food seller they know, for their own drop point
create or replace function add_vendor(p_site uuid, p_name text, p_whatsapp text, p_items jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare k kitchens; v_wa text := regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g'); it jsonb; n int := 0;
begin
  if not exists (select 1 from sites where id = p_site and active) then raise exception 'Pick your drop point first.'; end if;
  if char_length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Add the seller''s name.'; end if;
  if v_wa !~ '^0[0-9]{9}$' then raise exception 'Enter the seller''s 10-digit WhatsApp number, like 024 123 4567.'; end if;
  if (select count(*) from kitchens where site_id = p_site and created_at > now() - interval '1 day') >= 10 then
    raise exception 'Too many sellers were added here today. Ask the ChopPool team to help.';
  end if;
  insert into kitchens (name, public_name, tagline, whatsapp, capacity, site_id, added_by_customer, added_by)
  values (trim(p_name), trim(p_name), 'Added by a customer', v_wa, 30, p_site, true, auth.uid())
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

-- A customer asks ChopPool to add their building (goes to the team for approval)
create or replace function request_site(p_name text, p_drop_point text, p_lat double precision, p_lng double precision, p_note text default null)
returns json language plpgsql security definer set search_path = public as $$
declare si sites;
begin
  if char_length(trim(coalesce(p_name, ''))) < 3 then raise exception 'Add the building''s name.'; end if;
  if char_length(trim(coalesce(p_drop_point, ''))) < 3 then raise exception 'Say where the food should be dropped, like "Main gate".'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'Drop a pin on the map first.'; end if;
  if (select count(*) from sites where status = 'pending' and created_at > now() - interval '1 day') >= 30 then
    raise exception 'Too many building requests today. Please try again tomorrow.';
  end if;
  insert into sites (name, drop_point, lat, lng, status, requested_by, request_note)
  values (trim(p_name), trim(p_drop_point), p_lat, p_lng, 'pending', auth.uid(), nullif(trim(coalesce(p_note, '')), ''))
  returning * into si;
  return json_build_object('id', si.id, 'name', si.name, 'status', si.status);
end $$;

-- ---------------------------------------------------------------------
-- Seller / kitchen link (codes only, never customer names)
-- ---------------------------------------------------------------------
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

-- "Yes, I'm cooking today": opens every waiting pool for that day
create or replace function kitchen_open_day(p_token text, p_date date)
returns void language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This seller link is not valid.'; end if;
  insert into kitchen_days (kitchen_id, order_date) values (k.id, p_date) on conflict do nothing;
  update pools set status = 'collecting' where kitchen_id = k.id and order_date = p_date and status = 'waiting';
end $$;

create or replace function kitchen_update(p_token text, p_pool uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare p pools; k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This seller link is not valid.'; end if;
  select * into p from pools where id = p_pool and kitchen_id = k.id;
  if not found then raise exception 'That pool is not for you.'; end if;
  if p_status = 'accepted' then
    if (now() at time zone 'utc') < p.order_date + (select cutoff from settings where id = 1) then
      raise exception 'Orders are still coming in. Confirm the final batch once the pool closes.';
    end if;
  elsif p_status in ('picked_up', 'arriving', 'delivered') then
    if k.delivery_mode <> 'runner' then raise exception 'A ChopPool rider delivers this pool.'; end if;
  elsif p_status <> 'ready' then
    raise exception 'Unknown step.';
  end if;
  update pools set status = p_status,
    accepted_at  = case when p_status = 'accepted'  then coalesce(accepted_at, now()) else accepted_at end,
    ready_at     = case when p_status = 'ready'     then now() else ready_at end,
    picked_up_at = case when p_status = 'picked_up' then now() else picked_up_at end,
    arriving_at  = case when p_status = 'arriving'  then now() else arriving_at end,
    delivered_at = case when p_status = 'delivered' then now() else delivered_at end
  where id = p.id and status not in ('waiting', 'cancelled');
end $$;

create or replace function kitchen_quote(p_token text, p_order uuid, p_price numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_price is null or p_price <= 0 or p_price > 1000 then raise exception 'Enter a price per meal in cedis.'; end if;
  update orders o set quote_price = p_price, status = 'quoted'
  from kitchens k
  where k.token = p_token and k.active and o.kitchen_id = k.id and o.id = p_order and o.status in ('quote_requested', 'quoted');
  if not found then raise exception 'That request can no longer be priced.'; end if;
end $$;

-- Sellers added by customers can correct their own dishes and prices
create or replace function vendor_set_menu(p_token text, p_items jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare k kitchens; it jsonb;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This seller link is not valid.'; end if;
  if not k.added_by_customer then raise exception 'ChopPool manages this menu. Contact the coordinator to change it.'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    if it ? 'id' and nullif(it ->> 'id', '') is not null then
      update menu_items set name = coalesce(nullif(trim(it ->> 'name'), ''), name),
        price = coalesce(nullif(it ->> 'price', '')::numeric, price),
        active = coalesce((it ->> 'active')::boolean, true)
      where id = (it ->> 'id')::uuid and kitchen_id = k.id;
    elsif char_length(trim(coalesce(it ->> 'name', ''))) >= 2 and coalesce(nullif(it ->> 'price', '')::numeric, 0) > 0 then
      insert into menu_items (kitchen_id, name, price) values (k.id, trim(it ->> 'name'), (it ->> 'price')::numeric);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Riders and drop-point hosts
-- ---------------------------------------------------------------------
create or replace function rider_view(p_token text, p_date date)
returns json language plpgsql stable security definer set search_path = public as $$
declare r riders;
begin
  select * into r from riders where token = p_token and active;
  if not found then raise exception 'This rider link is not valid.'; end if;
  return json_build_object(
    'rider', json_build_object('name', r.name),
    'pools', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'seq', p.seq, 'status', p.status, 'meals', pool_meals(p.id),
        'kitchen', k.name, 'kitchen_address', k.address, 'kitchen_phone', k.whatsapp,
        'site', si.name, 'drop_point', si.drop_point, 'handoff', si.handoff, 'host_label', si.host_label,
        'orders', (select json_agg(json_build_object('code', o.code, 'name', o.customer_name, 'qty', o.qty,
                                                     'item_name', o.item_name, 'collected', o.status = 'collected')
                                   order by o.customer_name)
                   from orders o where o.pool_id = p.id and o.status <> 'cancelled'))
        order by si.name, p.seq)
      from pools p join sites si on si.id = p.site_id join kitchens k on k.id = p.kitchen_id
      where p.rider_id = r.id and p.order_date = p_date and p.status not in ('cancelled', 'waiting')
    ), '[]'::json));
end $$;

create or replace function rider_update(p_token text, p_pool uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('picked_up', 'arriving', 'delivered') then raise exception 'Unknown step.'; end if;
  update pools p set status = p_status,
    picked_up_at = case when p_status = 'picked_up' then now() else p.picked_up_at end,
    arriving_at  = case when p_status = 'arriving'  then now() else p.arriving_at end,
    delivered_at = case when p_status = 'delivered' then now() else p.delivered_at end
  from riders r
  where r.token = p_token and r.active and p.rider_id = r.id and p.id = p_pool;
  if not found then raise exception 'That pool is not assigned to you.'; end if;
end $$;

create or replace function host_view(p_token text, p_date date)
returns json language plpgsql stable security definer set search_path = public as $$
declare si sites;
begin
  select * into si from sites where host_token = p_token and active;
  if not found then raise exception 'This host link is not valid.'; end if;
  return json_build_object(
    'site', json_build_object('name', si.name, 'drop_point', si.drop_point),
    'pools', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'seq', p.seq, 'status', p.status, 'menu', k.public_name, 'meals', pool_meals(p.id),
        'orders', (select json_agg(json_build_object('code', o.code, 'name', o.customer_name, 'qty', o.qty,
                                                     'item_name', o.item_name, 'collected', o.status = 'collected')
                                   order by o.customer_name)
                   from orders o where o.pool_id = p.id and o.status not in ('cancelled', 'quote_requested', 'quoted')))
        order by k.public_name, p.seq)
      from pools p join kitchens k on k.id = p.kitchen_id
      where p.site_id = si.id and p.order_date = p_date and p.status not in ('cancelled', 'waiting') and pool_meals(p.id) > 0
    ), '[]'::json));
end $$;

-- Rider, host or a seller's own runner enters the customer's 4-digit code
create or replace function collect_code(p_token text, p_code text, p_date date)
returns json language plpgsql security definer set search_path = public as $$
declare o orders; who text;
begin
  select o2.* into o from orders o2
    join pools p on p.id = o2.pool_id
    left join riders r on r.id = p.rider_id
    join sites si on si.id = o2.site_id
    join kitchens k on k.id = o2.kitchen_id
   where o2.order_date = p_date and o2.code = trim(p_code) and o2.status in ('pending', 'paid', 'collected')
     and (r.token = p_token or si.host_token = p_token or (k.token = p_token and k.delivery_mode = 'runner'));
  if not found then raise exception 'No order with code % for you today.', p_code; end if;
  if o.status = 'collected' then raise exception 'Code % was already collected.', p_code; end if;
  who := case when exists (select 1 from riders where token = p_token) then 'rider'
              when exists (select 1 from kitchens where token = p_token) then 'runner' else 'host' end;
  update orders set status = 'collected', collected_at = now(), collected_by = who where id = o.id;
  return json_build_object('name', o.customer_name, 'item_name', o.item_name, 'qty', o.qty, 'was_paid', o.status = 'paid');
end $$;

-- ---------------------------------------------------------------------
-- Coordinator helpers
-- ---------------------------------------------------------------------
create or replace function admin_wallets()
returns table (user_id uuid, email text, name text, phone text, balance numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Coordinators only.'; end if;
  return query select pr.user_id, pr.email, pr.name, pr.phone, wallet_balance(pr.user_id) from profiles pr order by pr.email;
end $$;

-- ---------------------------------------------------------------------
-- Public read-only views (no names, phone numbers, WhatsApp numbers or link tokens)
-- ---------------------------------------------------------------------
create or replace view public_sites as
  select id, name, drop_point, handoff, host_label, lat, lng from sites where active and status = 'active';
create or replace view public_menus as
  select id, public_name, tagline, capacity, site_id, added_by_customer from kitchens where active;
create or replace view public_pools as
  select p.id, p.order_date, p.site_id, p.kitchen_id, p.seq, p.status, p.created_at, pool_meals(p.id) as meals
  from pools p where p.status <> 'cancelled';
create or replace view kitchen_load as
  select order_date, kitchen_id, sum(qty)::int as meals from orders where status <> 'cancelled' group by 1, 2;
create or replace view recent_activity as
  select o.id, o.order_date, o.site_id, o.kitchen_id, o.pool_id, o.item_name, o.qty, o.created_at
  from orders o where o.status not in ('cancelled', 'quote_requested', 'quoted') and o.created_at > now() - interval '6 hours';

-- ---------------------------------------------------------------------
-- Access rules
-- ---------------------------------------------------------------------
alter table settings       enable row level security;
alter table sites          enable row level security;
alter table kitchens       enable row level security;
alter table menu_items     enable row level security;
alter table kitchen_days   enable row level security;
alter table riders         enable row level security;
alter table pools          enable row level security;
alter table orders         enable row level security;
alter table profiles       enable row level security;
alter table wallet_entries enable row level security;
alter table admins         enable row level security;

create policy "read settings"     on settings     for select using (true);
create policy "read menu"         on menu_items   for select using (true);
create policy "read kitchen days" on kitchen_days for select using (true);

create policy "own profile" on profiles for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own wallet"  on wallet_entries for select to authenticated using (user_id = auth.uid());

create policy "admin settings" on settings       for all to authenticated using (is_admin()) with check (is_admin());
create policy "admin sites"    on sites          for all to authenticated using (is_admin()) with check (is_admin());
create policy "admin kitchens" on kitchens       for all to authenticated using (is_admin()) with check (is_admin());
create policy "admin menu"     on menu_items     for all to authenticated using (is_admin()) with check (is_admin());
create policy "admin days"     on kitchen_days   for all to authenticated using (is_admin()) with check (is_admin());
create policy "admin riders"   on riders         for all to authenticated using (is_admin()) with check (is_admin());
create policy "admin pools"    on pools          for all to authenticated using (is_admin()) with check (is_admin());
create policy "admin orders"   on orders         for all to authenticated using (is_admin()) with check (is_admin());
create policy "admin profiles" on profiles       for select to authenticated using (is_admin());
create policy "admin wallets"  on wallet_entries for all to authenticated using (is_admin()) with check (is_admin());
create policy "admin list"     on admins         for select to authenticated using (is_admin());
create policy "owner team"     on admins         for all to authenticated using (is_super()) with check (is_super());

grant select on public_sites, public_menus, public_pools, kitchen_load, recent_activity to anon, authenticated;
grant execute on function
  place_order(uuid, uuid, int, text, text, text, text[], text, text, boolean), pay_quote(uuid, text, boolean),
  my_orders(uuid[]), claim_orders(uuid[]), my_wallet(), add_vendor(uuid, text, text, jsonb), housekeeping(),
  kitchen_view(text, date), kitchen_open_day(text, date), kitchen_update(text, uuid, text), kitchen_quote(text, uuid, numeric),
  vendor_set_menu(text, jsonb), rider_view(text, date), rider_update(text, uuid, text), host_view(text, date),
  collect_code(text, text, date), current_order_date(), is_admin(), is_super(), my_role(), claim_owner(), admin_wallets(),
  request_site(text, text, double precision, double precision, text)
  to anon, authenticated;
-- Internal helper: only callable through the functions above
revoke execute on function settle_payment(uuid, text, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Removing kitchens and buildings
-- ---------------------------------------------------------------------
alter table kitchens add column if not exists archived boolean not null default false;
alter table sites add column if not exists archived boolean not null default false;

-- Removes a kitchen. If it has past orders it is archived (hidden, history kept); otherwise deleted for good.
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

-- Removes a building the same way.
create or replace function admin_remove_site(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  if exists (select 1 from orders where site_id = p_id) then
    update sites set archived = true, active = false where id = p_id;
    update kitchens set archived = true, active = false where site_id = p_id;
    return 'archived';
  end if;
  update kitchens set archived = true, active = false where site_id = p_id;
  delete from pools where site_id = p_id;
  delete from sites where id = p_id and not exists (select 1 from kitchens where site_id = p_id);
  if found then return 'deleted'; end if;
  update sites set archived = true, active = false where id = p_id;
  return 'archived';
end $$;

grant execute on function admin_remove_kitchen(uuid), admin_remove_site(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Starter data: EXAMPLES. Replace with your real pilot details.
-- ---------------------------------------------------------------------
insert into settings (id) values (1) on conflict (id) do nothing;

insert into sites (name, drop_point, handoff, host_label, lat, lng) values
  ('Heritage Tower, Ridge', 'Lobby security desk', 'host', 'the security desk in the lobby', 5.5640, -0.2010),
  ('Pent Hostel, Legon', 'Porters'' lodge', 'host', 'the porter on duty', 5.6505, -0.1870),
  ('Avenue Apartments, East Legon', 'Main gate', 'meet_rider', null, 5.6360, -0.1610);

insert into kitchens (name, public_name, tagline, address, whatsapp, capacity) values
  ('Auntie Akos Kitchen', 'Local favourites', 'Ghanaian classics, cooked fresh each morning', 'Osu, Oxford Street', '0240000001', 45),
  ('Green Bowl', 'Fresh bowls', 'Salads, wraps and rice bowls', 'Airport Residential', '0240000002', 30);

insert into menu_items (kitchen_id, name, price, addons)
select k.id, x.name, x.price, x.addons::jsonb from kitchens k join (values
  ('Auntie Akos Kitchen', 'Jollof rice with grilled chicken', 65, '[{"name":"Extra chicken","price":15},{"name":"Extra spicy","price":0},{"name":"No pepper","price":0}]'),
  ('Auntie Akos Kitchen', 'Waakye with egg, gari and shito', 45, '[{"name":"Add wele","price":8},{"name":"No shito","price":0}]'),
  ('Auntie Akos Kitchen', 'Banku with grilled tilapia', 80, '[{"name":"Extra banku","price":5},{"name":"Mild pepper","price":0}]'),
  ('Green Bowl', 'Chicken avocado salad', 70, '[{"name":"Dressing on the side","price":0}]'),
  ('Green Bowl', 'Beef suya wrap', 55, '[{"name":"Extra suya","price":12}]'),
  ('Green Bowl', 'Veggie fried rice bowl', 50, '[{"name":"Add egg","price":5}]')
) as x(kname, name, price, addons) on x.kname = k.name;

insert into riders (name, phone) values ('Rider 1 (example)', '0240000003');

-- The owner (super admin) is set up from the app: open the link + #admin, create your account,
-- and tap "Make me the owner". That only works while no team member exists yet.

-- ---------------------------------------------------------------------
-- RESET (only if you ran an earlier version). Run these lines first.
-- ---------------------------------------------------------------------
-- drop view if exists pool_counts, public_sites, public_menus, public_pools, kitchen_load, recent_activity cascade;
-- drop table if exists wallet_entries, profiles, orders, pools, riders, kitchen_days, menu_items, kitchens, sites, settings, admins cascade;
-- drop function if exists prepare_order, place_order, my_orders cascade;

-- ---------------------------------------------------------------------
-- Version 6 additions (kitchen map pins)
-- ---------------------------------------------------------------------
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

notify pgrst, 'reload schema';

-- =====================================================================
-- Update 7 (also shipped as update-7.sql)
-- =====================================================================
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

notify pgrst, 'reload schema';

-- =====================================================================
-- Update 8 (also shipped as update-8.sql)
-- =====================================================================
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

-- =====================================================================
-- Update 9 (also shipped as update-9.sql)
-- =====================================================================
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

-- =====================================================================
-- Update 10 (also shipped as update-10.sql)
-- =====================================================================
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
