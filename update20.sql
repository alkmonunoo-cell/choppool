-- ============================================================
-- ChopPool update 20 (Release B: money, order flow, admin control). Safe to run more than once.
-- ============================================================

-- Settings
alter table settings add column if not exists trip_max numeric not null default 80;            -- safety ceiling on a whole trip (GHS)
alter table settings add column if not exists quote_pay_min int not null default 15;           -- minutes to pay a priced special order
alter table settings add column if not exists auto_receive_min int not null default 120;       -- "Got my food" confirms itself after this
alter table settings add column if not exists admin_idle_min int not null default 15;          -- admin screen timeout
alter table settings add column if not exists cashback_ledger_from timestamptz;
update settings set cashback_ledger_from = coalesce(cashback_ledger_from, now()) where id = 1;

-- Orders: received / problem / special-order payment window / pool switch / refund records / solo answer
alter table orders add column if not exists received_at timestamptz;
alter table orders add column if not exists problem text;
alter table orders add column if not exists problem_at timestamptz;
alter table orders add column if not exists problem_resolved_at timestamptz;
alter table orders add column if not exists problem_note text;
alter table orders add column if not exists cashback_posted boolean not null default false;
alter table orders add column if not exists quoted_at timestamptz;
alter table orders add column if not exists quote_pay_by timestamptz;
alter table orders add column if not exists carried_amount numeric not null default 0;
alter table orders add column if not exists moved_from uuid;
alter table orders add column if not exists refund_amount numeric;
alter table orders add column if not exists refund_ref text;
alter table orders add column if not exists refunded_at timestamptz;
alter table orders add column if not exists refunded_by text;
alter table orders add column if not exists solo_choice text;

-- Pricing: every customer pays the full trip once (spread over the meals on their code); cashback returns the shared part.
-- The only cap is a safety ceiling on the whole trip.
create or replace function fee_for(p_meals integer, p_trip numeric) returns numeric language sql stable security definer set search_path = public as $$
  select case when p_meals <= 0 then ceil(least(coalesce(p_trip, s.trip_cost), s.trip_max) * 2) / 2
              else ceil(least(coalesce(p_trip, s.trip_cost), s.trip_max) / p_meals * 2) / 2 end
  from settings s where s.id = 1;
$$;
create or replace function fee_for(p_meals integer) returns numeric language sql stable security definer set search_path = public as $$
  select fee_for(p_meals, null::numeric);
$$;
create or replace function pool_trip(p uuid) returns numeric language sql stable security definer set search_path = public as $$
  select case
    when pool_free(p) then 0
    when coalesce(k.lat, case when k.added_by_customer then st.lat end) is null or st.lat is null then least(s.trip_cost, s.trip_max)
    else least(s.trip_max, round(s.base_fare + s.per_km * dist_m(
           coalesce(k.lat, case when k.added_by_customer then st.lat end),
           coalesce(k.lng, case when k.added_by_customer then st.lng end),
           st.lat, st.lng) / 1000 * 1.3))
  end
  from pools pl join kitchens k on k.id = pl.kitchen_id join sites st on st.id = pl.site_id cross join settings s
  where pl.id = p and s.id = 1;
$$;

-- One order for the steps every screen shows
create or replace function step_rank(p text) returns int language sql immutable as $$
  select case p when 'waiting' then 0 when 'collecting' then 1 when 'accepted' then 2 when 'ready' then 3
                when 'picked_up' then 4 when 'arriving' then 5 when 'delivered' then 6 else -1 end;
$$;

-- Wallet = fixed entries only (cashback is posted once, as its own line, when the order is received)
create or replace function wallet_balance(p_user uuid) returns numeric language sql stable security definer set search_path = public as $$
  select round(coalesce((select sum(amount) from wallet_entries where user_id = p_user), 0), 2);
$$;
create or replace function my_wallet() returns json language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Sign in to see your wallet.'; end if;
  return json_build_object(
    'balance', wallet_balance(v_uid),
    'pending', coalesce((select round(sum(order_cashback(o.id)), 2) from orders o join pools p on p.id = o.pool_id cross join settings s
                         where s.id = 1 and o.user_id = v_uid and o.parent_id is null and o.status in ('paid', 'collected') and not o.cashback_posted
                           and p.status <> 'cancelled' and (now() at time zone 'utc') >= o.order_date + s.cutoff), 0),
    'entries', coalesce((select json_agg(x order by x.at desc) from (
        select created_at as at, amount, reason from wallet_entries where user_id = v_uid order by created_at desc limit 60) x), '[]'::json));
end $$;

-- "Got my food" / "Report a problem" (owner of the order: the account, or the phone holding the order's private ID)
create or replace function confirm_received(p_order uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  update orders set received_at = coalesce(received_at, now())
   where id = p_order and parent_id is null and status = 'collected' and (user_id is null or user_id = auth.uid());
  perform housekeeping();
end $$;
create or replace function report_problem(p_order uuid, p_text text) returns void language plpgsql security definer set search_path = public as $$
begin
  if char_length(trim(coalesce(p_text, ''))) < 3 then raise exception 'Say what went wrong.'; end if;
  update orders set problem = left(trim(p_text), 500), problem_at = now(), problem_resolved_at = null
   where id = p_order and parent_id is null and status in ('paid', 'collected') and not cashback_posted
     and (user_id is null or user_id = auth.uid());
  if not found then raise exception 'This order can''t take a report any more.'; end if;
end $$;
create or replace function resolve_problem(p_order uuid, p_note text, p_credit numeric default 0) returns void language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  if coalesce(p_credit, 0) <> 0 and not is_super() then raise exception 'Only the owner can add wallet credit.'; end if;
  update orders set problem_resolved_at = now(), problem_note = left(trim(coalesce(p_note, '')), 500) where id = p_order returning * into o;
  if coalesce(p_credit, 0) > 0 and o.user_id is not null then
    insert into wallet_entries (user_id, amount, reason, order_id) values (o.user_id, p_credit, 'Sorted: ' || coalesce(nullif(trim(p_note), ''), 'problem with code ' || o.code), o.id);
  end if;
  perform housekeeping();
end $$;

-- Solo-pool answer (Keep / Cancel / Switch), so the team can see it
create or replace function solo_choice(p_order uuid, p_choice text) returns void language plpgsql security definer set search_path = public as $$
begin
  if p_choice not in ('keep', 'cancel', 'switch', 'share') then raise exception 'Unknown choice.'; end if;
  update orders set solo_choice = p_choice where id = p_order and (user_id is null or user_id = auth.uid());
end $$;

-- Move an order to another open pool before cut-off: the money already paid moves across
create or replace function switch_order(p_from uuid, p_site uuid, p_item uuid, p_qty int, p_addons text[], p_note text, p_ref text default null)
returns json language plpgsql security definer set search_path = public as $$
declare o orders; s settings; v_paid numeric; r json; n orders; v_new_total numeric; v_diff numeric;
begin
  select * into s from settings where id = 1;
  select * into o from orders where id = p_from and parent_id is null for update;
  if not found then raise exception 'Order not found.'; end if;
  if o.user_id is not null and o.user_id is distinct from auth.uid() then raise exception 'Sign in with the account that placed this order.'; end if;
  if o.status not in ('pending', 'paid') then raise exception 'This order can''t be moved.'; end if;
  if exists (select 1 from orders c where c.parent_id = o.id and c.status <> 'cancelled') then raise exception 'Cancel the extra plates on this order first.'; end if;
  if (now() at time zone 'utc') >= o.order_date + s.cutoff then raise exception 'Orders have closed, so this order can''t move now.'; end if;
  v_paid := order_total(o);   -- everything paid for this order (MoMo, wallet and anything carried in from an earlier move)
  update orders set status = 'cancelled', cancel_reason = 'Moved to another pool', refund_needed = false, refund_due = 0, wallet_used = 0 where id = o.id;
  r := place_order(p_site, p_item, p_qty, o.customer_name, o.phone, coalesce(nullif(trim(coalesce(p_ref, '')), ''), o.momo_ref), p_addons, p_note, null, false, null);
  select * into n from orders where id = (r ->> 'id')::uuid for update;
  update orders set user_id = o.user_id, moved_from = o.id, carried_amount = least(v_paid, order_total(n)),
                    momo_ref = case when p_ref is not null and trim(p_ref) <> '' and o.momo_ref is not null then o.momo_ref || ' + ' || trim(p_ref) else n.momo_ref end,
                    status = case when o.status = 'paid' and order_total(n) <= v_paid then 'paid' else n.status end,
                    pay_issue = null
   where id = n.id returning * into n;
  v_new_total := order_total(n); v_diff := v_paid - v_new_total;
  if v_diff > 0 then
    if o.user_id is not null and o.status = 'paid' then
      insert into wallet_entries (user_id, amount, reason, order_id) values (o.user_id, v_diff, 'Money back: moved to a cheaper order, code ' || n.code, n.id);
    else
      update orders set refund_due = v_diff, refund_needed = true where id = o.id;
    end if;
  end if;
  return json_build_object('id', n.id, 'code', n.code, 'status', n.status, 'to_pay', greatest(0, -v_diff), 'refund', greatest(0, v_diff),
                           'meals', pool_meals(n.pool_id), 'pool_status', (select status from pools where id = n.pool_id), 'pool_seq', (select seq from pools where id = n.pool_id), 'order_date', n.order_date);
end $$;

-- Payments that arrived but couldn't become an order (sold out, closed): kept for a refund
create table if not exists unmatched_payments (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  name text, phone text, amount numeric, momo_ref text, reason text,
  refunded_at timestamptz, refund_ref text, refunded_by text
);
alter table unmatched_payments enable row level security;
drop policy if exists "team unmatched" on unmatched_payments;
create policy "team unmatched" on unmatched_payments for all to authenticated using (is_admin()) with check (is_admin());
create or replace function record_unmatched(p_name text, p_phone text, p_amount numeric, p_ref text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if char_length(trim(coalesce(p_ref, ''))) < 4 then return; end if;
  if (select count(*) from unmatched_payments where phone = v_phone and created_at > now() - interval '1 day') >= 5 then return; end if;
  if exists (select 1 from unmatched_payments where momo_ref = trim(p_ref)) then return; end if;
  insert into unmatched_payments (name, phone, amount, momo_ref, reason)
  values (left(trim(coalesce(p_name, '')), 80), v_phone, least(greatest(coalesce(p_amount, 0), 0), 5000), left(trim(p_ref), 60), left(coalesce(p_reason, ''), 200));
end $$;

-- MoMo references already used on another order (last 30 days)
create or replace function admin_refs_seen(p_refs text[], p_date date) returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  return coalesce((select json_object_agg(ref, n) from (
    select trim(o.momo_ref) as ref, count(*) as n from orders o
     where trim(o.momo_ref) = any(p_refs) and o.order_date between p_date - 30 and p_date + 1 and o.status <> 'cancelled'
     group by 1 having count(*) > 1) x), '{}'::json);
end $$;

-- Payouts to sellers and riders, and what's still due
create table if not exists payouts (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  payee_type text not null check (payee_type in ('seller', 'rider')),
  kitchen_id uuid references kitchens(id),
  rider_id uuid references riders(id),
  amount numeric not null check (amount > 0),
  momo_ref text, note text, paid_by text
);
alter table payouts enable row level security;
drop policy if exists "team payouts read" on payouts;
drop policy if exists "owner payouts" on payouts;
create policy "team payouts read" on payouts for select to authenticated using (is_admin());
create policy "owner payouts" on payouts for all to authenticated using (is_super()) with check (is_super());

create or replace function admin_dues(p_from date, p_to date) returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  return json_build_object(
    'sellers', coalesce((select json_agg(x order by x.due desc) from (
      select k.id, k.name, k.whatsapp,
             round(coalesce(sum(e.food) filter (where e.order_date between p_from and p_to), 0), 2) as food,
             round(coalesce(sum(e.fee) filter (where e.order_date between p_from and p_to), 0), 2) as fee,
             round(coalesce(sum(e.food - e.fee), 0) - coalesce((select sum(amount) from payouts py where py.kitchen_id = k.id and py.payee_type = 'seller'), 0), 2) as due,
             coalesce((select sum(amount) from payouts py where py.kitchen_id = k.id and py.payee_type = 'seller'), 0) as paid
        from kitchens k
        left join (select p.kitchen_id, p.order_date, p.id,
                          coalesce((select sum((coalesce(o.quote_price, o.unit_price) + o.addons_total) * o.qty) from orders o
                                     where o.pool_id = p.id and o.status in ('paid', 'collected') and (o.received_at is not null or o.cashback_posted)), 0) as food,
                          coalesce(pool_fee(p.id), 0) as fee
                     from pools p where p.status = 'delivered') e on e.kitchen_id = k.id
       group by k.id) x where x.food > 0 or x.due <> 0), '[]'::json),
    'riders', coalesce((select json_agg(x order by x.due desc) from (
      select r.id, r.name, r.phone,
             round(coalesce(sum(p.trip_cost) filter (where p.order_date between p_from and p_to), 0), 2) as trips,
             round(coalesce(sum(p.trip_cost), 0) - coalesce((select sum(amount) from payouts py where py.rider_id = r.id and py.payee_type = 'rider'), 0), 2) as due,
             coalesce((select sum(amount) from payouts py where py.rider_id = r.id and py.payee_type = 'rider'), 0) as paid
        from riders r left join pools p on p.rider_id = r.id and p.status = 'delivered'
       group by r.id) x where x.trips > 0 or x.due <> 0), '[]'::json));
end $$;

-- Activity log: who changed what, when (team actions only)
create table if not exists activity_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor text, entity text not null, entity_id text, action text not null, changes jsonb
);
alter table activity_log enable row level security;
drop policy if exists "owner log" on activity_log;
create policy "owner log" on activity_log for select to authenticated using (is_super());
create or replace function log_change() returns trigger language plpgsql security definer set search_path = public as $$
declare a jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end; b jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end; d jsonb := '{}'; k text;
begin
  if coalesce(current_setting('role', true), '') <> 'authenticated' or not is_admin() then return coalesce(new, old); end if;   -- team actions only
  if tg_op = 'UPDATE' then
    for k in select key from jsonb_each(b) loop
      if (a -> k) is distinct from (b -> k) then d := d || jsonb_build_object(k, jsonb_build_array(a -> k, b -> k)); end if;
    end loop;
    if d = '{}'::jsonb then return new; end if;
  else d := coalesce(b, a); end if;
  insert into activity_log (actor, entity, entity_id, action, changes)
  values (coalesce(auth.jwt() ->> 'email', 'unknown'), tg_table_name, coalesce(b ->> 'id', a ->> 'id'), lower(tg_op), d);
  return coalesce(new, old);
end $$;
do $$ declare t text; begin
  foreach t in array array['orders', 'wallet_entries', 'settings', 'pools', 'payouts', 'admins', 'kitchens', 'riders', 'sites', 'unmatched_payments'] loop
    execute format('drop trigger if exists log_change on %I', t);
    execute format('create trigger log_change after insert or update or delete on %I for each row execute function log_change()', t);
  end loop;
end $$;

-- Coordinators: also allowed to record refunds and close problem reports
create or replace function orders_coordinator_guard() returns trigger language plpgsql as $$
declare a jsonb; b jsonb; k text;
begin
  if current_user not in ('authenticated', 'anon') or is_super() then return new; end if;
  a := to_jsonb(old); b := to_jsonb(new);
  for k in select key from jsonb_each(b) loop
    if k in ('status', 'pay_issue', 'amount_received', 'refund_needed', 'collected_at', 'collected_by',
             'refund_amount', 'refund_ref', 'refunded_at', 'refunded_by', 'problem_resolved_at', 'problem_note') then continue; end if;
    if k = 'refund_due' and coalesce((b->>k)::numeric, 0) = 0 then continue; end if;
    if (a->k) is distinct from (b->k) then raise exception 'Coordinators can''t change % on an order. Ask the owner.', k; end if;
  end loop;
  return new;
end $$;

-- Pay for a priced special order only inside its payment window
create or replace function quote_window_guard() returns trigger language plpgsql as $$
begin
  if old.status = 'quoted' and new.status in ('pending', 'paid') and old.quote_pay_by is not null and now() > old.quote_pay_by + interval '30 seconds' then
    raise exception 'The time to pay for this special order has run out.';
  end if;
  return new;
end $$;
drop trigger if exists quote_window_guard on orders;
create trigger quote_window_guard before update on orders for each row execute function quote_window_guard();


-- ---------- updated functions ----------
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
  select coalesce(sum(qty), 0) into v_load from orders where kitchen_id = k.id and order_date = d and status <> 'cancelled'
     and not (status = 'pending' and pay_issue is not null and pay_issue <> 'short');   -- payments we couldn't find don't hold seats
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
    if (select count(*) from orders where phone = v_phone and parent_id is null and status = 'pending' and created_at > now() - interval '1 day') >= 3 then
      raise exception 'You have 3 orders waiting for their payment to be checked. Wait for those before placing another.';
    end if;
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

drop function if exists public.my_orders(uuid[]);
CREATE OR REPLACE FUNCTION public.my_orders(p_ids uuid[])
 RETURNS TABLE(id uuid, order_date date, code text, status text, qty integer, item_name text, site_id uuid, kitchen_id uuid, pool_seq integer, pool_status text, special_request text, quote_price numeric, amount_due numeric, cancel_reason text, unit_price numeric, addons jsonb, addons_total numeric, max_fee numeric, service_fee numeric, wallet_used numeric, saving numeric, has_account boolean, refund_needed boolean, parent_id uuid, fee_per_meal boolean, item_id uuid, pool_id uuid, created_at timestamp with time zone, refund_due numeric, my_rating integer, my_photo text, pay_issue text, amount_received numeric, momo_ref text, wait_until timestamp with time zone, vendor_delivers boolean, received_at timestamp with time zone, problem text, problem_resolved boolean, quote_pay_by timestamp with time zone, carried_amount numeric, collected_at timestamp with time zone, cashback_posted boolean, solo_choice text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select o.id, o.order_date, o.code, o.status, o.qty, o.item_name, o.site_id, o.kitchen_id, p.seq, p.status,
         o.special_request, o.quote_price,
         order_total(o) - o.wallet_used - coalesce(o.carried_amount, 0),
         o.cancel_reason, o.unit_price, o.addons, o.addons_total, o.max_fee, o.service_fee, o.wallet_used,
         case when o.status in ('pending', 'paid', 'collected') and p.status <> 'cancelled' then order_cashback(o.id) else 0 end,
         o.user_id is not null, o.refund_needed, o.parent_id, o.fee_per_meal, o.item_id, o.pool_id, o.created_at, o.refund_due,
         r.rating, r.photo_url, o.pay_issue, o.amount_received, o.momo_ref,
         case when p.status = 'waiting' then wait_deadline(p.created_at, p.order_date) end, pool_free(p.id),
         o.received_at, o.problem, o.problem_resolved_at is not null, o.quote_pay_by, coalesce(o.carried_amount, 0), o.collected_at, o.cashback_posted, o.solo_choice
  from orders o join pools p on p.id = o.pool_id left join reviews r on r.order_id = o.id
  where (o.id = any(p_ids) or o.parent_id = any(p_ids) or (auth.uid() is not null and o.user_id = auth.uid()))
    and o.order_date >= (now() at time zone 'utc')::date - 1
  order by o.created_at desc;
$function$;

CREATE OR REPLACE FUNCTION public.kitchen_quote(p_token text, p_order uuid, p_price numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_price is null or p_price <= 0 or p_price > 1000 then raise exception 'Enter a price per meal in cedis.'; end if;
  if exists (select 1 from orders o, settings s where o.id = p_order and s.id = 1
             and (now() at time zone 'utc') >= o.order_date + s.cutoff - make_interval(mins => s.quote_pay_min)) then
    raise exception 'Pricing for today has closed, so the customer would have no time to pay.';
  end if;
  update orders o set quote_price = p_price, status = 'quoted', quoted_at = now(),
         quote_pay_by = least(now() + make_interval(mins => (select quote_pay_min from settings where id = 1)),
                              (o.order_date + (select cutoff from settings where id = 1)) at time zone 'utc')
  from kitchens k
  where k.token = p_token and k.active and o.kitchen_id = k.id and o.id = p_order and o.status in ('quote_requested', 'quoted');
  if not found then raise exception 'That request can no longer be priced.'; end if;
end $function$;

CREATE OR REPLACE FUNCTION public.rider_update(p_token text, p_pool uuid, p_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_status not in ('picked_up', 'arriving', 'delivered') then raise exception 'Unknown step.'; end if;
  if exists (select 1 from pools where id = p_pool and step_rank(status) >= step_rank(p_status)) then return; end if;   -- steps only move forward
  update pools p set status = p_status,
    picked_up_at = case when p_status = 'picked_up' then now() else p.picked_up_at end,
    arriving_at  = case when p_status = 'arriving'  then now() else p.arriving_at end,
    delivered_at = case when p_status = 'delivered' then now() else p.delivered_at end
  from riders r
  where r.token = p_token and r.active and p.rider_id = r.id and p.id = p_pool;
  if not found then raise exception 'That pool is not assigned to you.'; end if;
end $function$;

CREATE OR REPLACE FUNCTION public.rider_view(p_token text, p_date date)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        'site', si.name, 'drop_point', si.drop_point, 'site_lat', si.lat, 'site_lng', si.lng, 'picked_up_at', p.picked_up_at, 'handoff', si.handoff, 'host_label', si.host_label,
        'orders', (select json_agg(json_build_object('code', o.code, 'name', o.customer_name, 'qty', o.qty,
                                                     'item_name', o.item_name, 'collected', o.status = 'collected')
                                   order by o.customer_name)
                   from orders o where o.pool_id = p.id and o.status <> 'cancelled'))
        order by si.name, p.seq)
      from pools p join sites si on si.id = p.site_id join kitchens k on k.id = p.kitchen_id
      where p.rider_id = r.id and p.order_date = p_date and p.status not in ('cancelled', 'waiting')
    ), '[]'::json));
end $function$;

CREATE OR REPLACE FUNCTION public.request_site(p_name text, p_drop_point text, p_lat double precision, p_lng double precision, p_note text DEFAULT NULL::text, p_endpoint text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare si sites; v_joined boolean := false; v_n int;
begin
  if char_length(trim(coalesce(p_name, ''))) < 3 then raise exception 'Add the building''s name.'; end if;
  if char_length(trim(coalesce(p_drop_point, ''))) < 3 then raise exception 'Say where the food should be dropped, like "Main gate".'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'Drop a pin on the map first.'; end if;
  if p_endpoint is not null and (p_endpoint !~ '^https://' or length(p_endpoint) > 1000) then p_endpoint := null; end if;
  -- Already requested? Same name, or a pending building within 80 m: join its waitlist instead
  select * into si from sites
   where status = 'pending' and not archived
     and (lower(regexp_replace(name, '\s+', ' ', 'g')) = lower(regexp_replace(trim(p_name), '\s+', ' ', 'g'))
          or (lat is not null and dist_m(lat, lng, p_lat, p_lng) <= 80))
   order by created_at limit 1;
  if found then
    v_joined := true;
  else
    if (select count(*) from site_waiters w where w.created_at > now() - interval '1 day'
        and ((auth.uid() is not null and w.user_id = auth.uid()) or (p_endpoint is not null and w.endpoint = p_endpoint))) >= 5
     or (select count(*) from sites where status = 'pending' and created_at > now() - interval '1 day') >= 300 then
      raise exception 'Too many building requests today. Please try again tomorrow.';
    end if;
    insert into sites (name, drop_point, lat, lng, status, requested_by, request_note)
    values (trim(p_name), trim(p_drop_point), p_lat, p_lng, 'pending', auth.uid(), nullif(trim(coalesce(p_note, '')), ''))
    returning * into si;
  end if;
  if auth.uid() is not null or p_endpoint is not null then
    insert into site_waiters (site_id, user_id, endpoint) values (si.id, auth.uid(), p_endpoint) on conflict do nothing;
  end if;
  select count(*) into v_n from site_waiters where site_id = si.id;
  return json_build_object('id', si.id, 'name', si.name, 'status', si.status, 'joined', v_joined, 'waiting', greatest(v_n, 1));
end $function$;


CREATE OR REPLACE FUNCTION public.kitchen_update(p_token text, p_pool uuid, p_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p pools; k kitchens;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This seller link is not valid.'; end if;
  select * into p from pools where id = p_pool and kitchen_id = k.id;
  if not found then raise exception 'That pool is not for you.'; end if;
  if step_rank(p.status) >= step_rank(p_status) then return; end if;   -- steps only move forward
  if p_status = 'accepted' then
    if (now() at time zone 'utc') < p.order_date + (select cutoff from settings where id = 1) then
      raise exception 'Orders are still coming in. Confirm the final batch once the pool closes.';
    end if;
  elsif p_status in ('picked_up', 'arriving', 'delivered') then
    if k.delivery_mode <> 'runner' and not pool_free(p.id) then raise exception 'A ChopPool rider delivers this pool.'; end if;
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
end $function$;

CREATE OR REPLACE FUNCTION public.kitchen_view(p_token text, p_date date)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare k kitchens; s settings;
begin
  perform housekeeping();
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid. Ask ChopPool for a new one.'; end if;
  select * into s from settings where id = 1;
  return json_build_object(
    'kitchen', json_build_object('name', k.name, 'public_name', k.public_name, 'capacity', k.capacity,
                                 'delivery_mode', k.delivery_mode, 'added_by_customer', k.added_by_customer,
                                 'open', kitchen_is_open(k.id, p_date), 'listing_status', k.listing_status, 'listing', k.listing,
                                 'auto_days', k.auto_days, 'paused', p_date = any(k.paused_dates),
                                 'confirmed', exists (select 1 from kitchen_days where kitchen_id = k.id and order_date = p_date),
                                 'has_pin', k.lat is not null, 'free_m', k.free_m, 'free_min', k.free_min, 'free_max_m', s.free_max_m,
                                 'fee_ack', k.fee_ack, 'fee_free_ack', k.fee_free_ack, 'fee_rate', s.vendor_fee_rate, 'fee_free', s.vendor_fee_free,
                                 'next_day_confirm_by', s.next_day_confirm_by),
    'menu', coalesce((select json_agg(json_build_object('id', id, 'name', name, 'price', price, 'addons', addons,
                                                        'photo_url', photo_url, 'icon', icon) order by name)
                      from menu_items where kitchen_id = k.id and active), '[]'::json),
    'pools', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'seq', p.seq, 'status', p.status, 'site', si.name, 'drop_point', si.drop_point,
        'handoff', si.handoff, 'host_label', si.host_label, 'created_at', p.created_at,
        'wait_until', case when p.status = 'waiting' then wait_deadline(p.created_at, p.order_date) end,
        'free', pool_free(p.id), 'fee_rate', p.fee_rate, 'fee_free', p.fee_free, 'fee', pool_fee(p.id),
        'orders', (select json_agg(json_build_object('id', case when o.status in ('quote_requested', 'quoted') then o.id end, 'code', o.code, 'created_at', o.created_at, 'qty', o.qty, 'item_name', o.item_name,
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
end $function$;

CREATE OR REPLACE FUNCTION public.admin_weekly_report(p_week_start date)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s settings; w0 date := p_week_start; w1 date := p_week_start + 6; v0 date := p_week_start - 7; v1 date := p_week_start - 1;
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
        'trip_estimate', round(coalesce((select sum(pool_trip(p2.id)) from pools p2 where p2.order_date between w0 and w1 and p2.status = 'delivered'), 0), 2),
        'trip_paid', round(coalesce((select sum(p2.trip_cost) from pools p2 where p2.order_date between w0 and w1 and p2.status = 'delivered'), 0), 2),
        'commission', round(coalesce((select sum(pool_fee(p2.id)) from pools p2 where p2.order_date between w0 and w1 and p2.status <> 'cancelled'), 0), 2),
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
end $function$;


CREATE OR REPLACE FUNCTION public.housekeeping()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s settings;
begin
  select * into s from settings where id = 1;

  -- Vendors who didn't confirm in time: confirmed payments come back to the wallet (account holders) or by MoMo (guests)
  with expired as (
    update pools set status = 'cancelled'
    where status = 'waiting' and now() >= wait_deadline(created_at, order_date)
    returning id)
  update orders o set status = 'cancelled', cancel_reason = 'The seller did not confirm in time',
                      refund_due = case when o.status in ('paid', 'collected') then greatest(0, order_total(o) - o.wallet_used) else 0 end,
                      refund_needed = (o.momo_ref is not null and not (o.user_id is not null and o.status in ('paid', 'collected')))
  from expired e where o.pool_id = e.id and o.status <> 'cancelled';

  -- Payment never found by the time orders close: cancelled; anything that did arrive (short payment) goes back
  update orders set status = 'cancelled', cancel_reason = 'Payment not received',
                    refund_due = coalesce(amount_received, 0),
                    refund_needed = coalesce(amount_received, 0) > 0 and user_id is null
  where status = 'pending' and pay_issue is not null and (now() at time zone 'utc') >= order_date + s.cutoff;

  insert into wallet_entries (user_id, amount, reason, order_id)
  select o.user_id, o.refund_due, 'Money back: payment was short, code ' || o.code, o.id
  from orders o
  where o.status = 'cancelled' and o.cancel_reason = 'Payment not received' and o.refund_due > 0 and o.user_id is not null and not o.refund_needed
    and not exists (select 1 from wallet_entries w where w.order_id = o.id and w.reason like 'Money back:%');

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

  -- Special orders: the seller must price in time, and the customer must pay inside the payment window
  update orders o set status = 'cancelled', cancel_reason = 'The seller didn''t price your request in time'
   where o.status = 'quote_requested' and (now() at time zone 'utc') >= o.order_date + s.cutoff - make_interval(mins => s.quote_pay_min);
  update orders set status = 'cancelled', cancel_reason = 'Special request not paid in time'
   where status = 'quoted' and quote_pay_by is not null and now() > quote_pay_by + interval '30 seconds';

  -- "Got my food" confirms itself a while after handover, unless a problem was reported
  update orders set received_at = now()
   where parent_id is null and status = 'collected' and received_at is null and problem is null
     and collected_at is not null and collected_at + make_interval(mins => s.auto_receive_min) <= now();

  -- Cashback: posted once, as a fixed wallet line, when the order is received (or its pool was delivered a while ago).
  -- Orders from before the ledger started keep the old timing (after cut-off) so no balance changes.
  with e as (
    select o.id, o.user_id, o.code, order_cashback(o.id) as cb
      from orders o join pools p on p.id = o.pool_id
     where o.parent_id is null and o.user_id is not null and not o.cashback_posted
       and o.status in ('paid', 'collected') and p.status <> 'cancelled'
       and (o.problem is null or o.problem_resolved_at is not null)
       and ((s.cashback_ledger_from is not null and o.created_at < s.cashback_ledger_from and (now() at time zone 'utc') >= o.order_date + s.cutoff)
            or o.received_at is not null
            or (p.status = 'delivered' and p.delivered_at is not null and p.delivered_at + make_interval(mins => s.auto_receive_min) <= now()))
     for update of o skip locked),
  ins as (
    insert into wallet_entries (user_id, amount, reason, order_id)
    select e.user_id, e.cb, 'Delivery cashback, code ' || e.code, e.id from e where e.cb > 0
      and not exists (select 1 from wallet_entries w where w.order_id = e.id and w.reason like 'Delivery cashback%')
    returning 1)
  update orders set cashback_posted = true where id in (select id from e);
end $function$;

-- Old 11-column my_orders result shape is replaced above; refresh grants
revoke execute on function wallet_balance(uuid) from public, anon, authenticated;
revoke execute on function fee_for(integer) from public, anon, authenticated;
revoke execute on function fee_for(integer, numeric) from public, anon, authenticated;
revoke execute on function pool_trip(uuid) from public, anon, authenticated;

-- Keep alert subscriptions small: forget order IDs older than two days
create or replace function prune_push_subs() returns void language sql security definer set search_path = public as $$
  update push_subs ps set order_ids = coalesce((select array_agg(x) from unnest(ps.order_ids) x join orders o on o.id = x
                                                 where o.order_date >= (now() at time zone 'utc')::date - 2), '{}')
   where cardinality(ps.order_ids) > 0;
$$;
revoke execute on function prune_push_subs() from public, anon, authenticated;

-- Owner-only settings now also include the team screen timeout
create or replace function settings_owner_guard() returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') and not is_super()
     and (new.vendor_fee_rate is distinct from old.vendor_fee_rate or new.vendor_fee_free is distinct from old.vendor_fee_free
          or new.admin_idle_min is distinct from old.admin_idle_min) then
    raise exception 'Only the owner can change this setting.';
  end if;
  return new;
end $$;

-- Handover of an unpaid order needs a choice (Collect cash / Hold the meal)
drop function if exists collect_code(text, text, date, uuid);
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
  return json_build_object('name', v_name, 'items', v_items, 'item_name', v_items, 'qty', v_qty, 'was_paid', v_paid, 'code', v);
end $function$;
