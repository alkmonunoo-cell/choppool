-- ChopPool update 41: extras can be switched off; vendors edit their own menu with price increases approved by the owner;
-- past orders for the last 3 months; a daily lunch reminder time. Safe to run more than once.

alter table settings add column if not exists reminder_time time not null default '09:00';

-- Price increases and new paid items from vendors wait for the owner
create table if not exists price_requests (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  kitchen_id uuid not null references kitchens(id) on delete cascade,
  item_id uuid references menu_items(id) on delete cascade,
  kind text not null check (kind in ('dish', 'extra', 'new_extra', 'new_dish')),
  name text not null,
  old_price numeric,
  new_price numeric not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'declined', 'replaced')),
  note text,
  decided_at timestamptz,
  decided_by text
);
create index if not exists price_requests_kitchen_idx on price_requests (kitchen_id, created_at desc);
alter table price_requests enable row level security;
drop policy if exists "team reads price requests" on price_requests;
create policy "team reads price requests" on price_requests for select to authenticated using (is_admin());
revoke insert, update, delete on price_requests from anon, authenticated;

-- One pending request per thing: a newer one replaces the older
create or replace function price_request_add(p_k uuid, p_item uuid, p_kind text, p_name text, p_old numeric, p_new numeric) returns void
language plpgsql security definer set search_path = public as $$
begin
  update price_requests set status = 'replaced', decided_at = now() where kitchen_id = p_k and status = 'pending'
    and coalesce(item_id, '00000000-0000-0000-0000-000000000000') = coalesce(p_item, '00000000-0000-0000-0000-000000000000')
    and kind = p_kind and (p_kind in ('dish', 'new_dish') or (name = p_name and coalesce(old_price, -1) = coalesce(p_old, -1)));
  insert into price_requests (kitchen_id, item_id, kind, name, old_price, new_price) values (p_k, p_item, p_kind, p_name, p_old, p_new);
end $$;
revoke all on function price_request_add(uuid, uuid, text, text, numeric, numeric) from public, anon, authenticated;

-- Vendors save their menu (every vendor now, not only those added by customers).
-- Lower prices, names, order, on/off apply at once; a higher price keeps the old one until approved; new paid extras/dishes stay hidden until approved.
-- Each extra may carry orig_name/orig_price (what it was when the editor opened); they only count if that extra really exists.
create or replace function vendor_set_menu(p_token text, p_items jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare k kitchens; it jsonb; o menu_items; a jsonb; v_add jsonb; v_new jsonb; v_price numeric; v_orig jsonb; v_id uuid; v_name text; n_new int;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    o := null;
    if nullif(it ->> 'id', '') is not null then select * into o from menu_items where id = (it ->> 'id')::uuid and kitchen_id = k.id; end if;
    v_name := left(trim(coalesce(it ->> 'name', '')), 60);
    v_price := greatest(0, coalesce(nullif(it ->> 'price', '')::numeric, 0));
    -- extras
    v_add := null;
    if jsonb_typeof(it -> 'addons') = 'array' then
      v_add := '[]'::jsonb;
      for a in select * from jsonb_array_elements(it -> 'addons') loop
        continue when char_length(trim(coalesce(a ->> 'name', ''))) < 2;
        v_new := jsonb_build_object('name', left(trim(a ->> 'name'), 40), 'price', greatest(0, coalesce(nullif(a ->> 'price', '')::numeric, 0)));
        if coalesce((a ->> 'off')::boolean, false) then v_new := v_new || '{"off": true}'; end if;
        v_orig := null;
        if o.id is not null and a ? 'orig_name' then
          select e into v_orig from jsonb_array_elements(o.addons) e
           where e ->> 'name' = a ->> 'orig_name' and coalesce(nullif(e ->> 'price', '')::numeric, 0) = coalesce(nullif(a ->> 'orig_price', '')::numeric, 0) limit 1;
        end if;
        if v_orig is not null then
          if coalesce((v_orig ->> 'pending')::boolean, false) then v_new := v_new || '{"pending": true}'; end if;   -- still waiting
          if (v_new ->> 'price')::numeric > coalesce(nullif(v_orig ->> 'price', '')::numeric, 0) and not coalesce((v_orig ->> 'pending')::boolean, false) then
            perform price_request_add(k.id, o.id, 'extra', v_new ->> 'name', (v_orig ->> 'price')::numeric, (v_new ->> 'price')::numeric);
            v_new := jsonb_set(v_new, '{price}', v_orig -> 'price');
          end if;
        elsif (v_new ->> 'price')::numeric > 0 then
          v_new := v_new || '{"pending": true}';
          if o.id is not null and not exists (select 1 from price_requests where item_id = o.id and kind = 'new_dish' and status = 'pending') then
            perform price_request_add(k.id, o.id, 'new_extra', v_new ->> 'name', null, (v_new ->> 'price')::numeric); end if;
        end if;
        v_add := v_add || jsonb_build_array(v_new);
      end loop;
    end if;
    if o.id is not null then
      if exists (select 1 from price_requests where item_id = o.id and kind = 'new_dish' and status = 'pending') then
        -- a new dish still waiting: it stays hidden; its request follows the vendor's latest name and price
        update price_requests set name = coalesce(nullif(v_name, ''), name), new_price = case when v_price > 0 then v_price else new_price end
         where item_id = o.id and kind = 'new_dish' and status = 'pending';
        update menu_items set name = coalesce(nullif(v_name, ''), name), price = case when v_price > 0 then v_price else price end,
          addons = coalesce((select jsonb_agg(e - 'pending') from jsonb_array_elements(v_add) e), addons), active = false where id = o.id;
        continue;
      end if;
      if v_price > o.price then perform price_request_add(k.id, o.id, 'dish', coalesce(nullif(v_name, ''), o.name), o.price, v_price); v_price := o.price; end if;
      update menu_items set name = coalesce(nullif(v_name, ''), name), price = case when v_price > 0 then v_price else price end,
        addons = coalesce(v_add, addons), active = coalesce((it ->> 'active')::boolean, true)
      where id = o.id;
    elsif char_length(v_name) >= 2 and v_price > 0 then
      -- a new dish waits (hidden) for the owner; its new paid extras are approved with it
      insert into menu_items (kitchen_id, name, price, addons, active) values (k.id, v_name, v_price,
        coalesce((select jsonb_agg(e - 'pending') from jsonb_array_elements(coalesce(v_add, '[]'::jsonb)) e), '[]'::jsonb), false)
      returning id into v_id;
      perform price_request_add(k.id, v_id, 'new_dish', v_name, null, v_price);
    end if;
  end loop;
end $$;

-- What the vendor sees about their requests (last 30 days)
create or replace function vendor_price_requests(p_token text) returns setof price_requests
language sql stable security definer set search_path = public as $$
  select r.* from price_requests r join kitchens k on k.id = r.kitchen_id
   where k.token = p_token and k.active and r.status <> 'replaced' and r.created_at > now() - interval '30 days'
   order by r.created_at desc limit 50;
$$;

-- The owner approves or declines; the vendor's bell gets the outcome
create or replace function admin_price_decide(p_id uuid, p_ok boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r price_requests; m menu_items;
begin
  if not is_super() then raise exception 'Only the owner can approve price changes.'; end if;
  select * into r from price_requests where id = p_id for update;
  if not found or r.status <> 'pending' then raise exception 'This request was already handled.'; end if;
  select * into m from menu_items where id = r.item_id;
  if p_ok then
    if r.kind = 'dish' and m.id is not null then update menu_items set price = r.new_price where id = m.id;
    elsif r.kind = 'new_dish' and m.id is not null then update menu_items set active = true where id = m.id;
    elsif r.kind in ('extra', 'new_extra') and m.id is not null then
      update menu_items set addons = (select coalesce(jsonb_agg(case when e ->> 'name' = r.name and (
            (r.kind = 'extra' and coalesce(nullif(e ->> 'price', '')::numeric, 0) = r.old_price and not coalesce((e ->> 'pending')::boolean, false))
         or (r.kind = 'new_extra' and coalesce((e ->> 'pending')::boolean, false)))
        then (e - 'pending') || jsonb_build_object('price', r.new_price) else e end order by i), '[]'::jsonb)
        from jsonb_array_elements(m.addons) with ordinality t(e, i)) where id = m.id;
    end if;
  else
    if r.kind = 'new_extra' and m.id is not null then
      update menu_items set addons = (select coalesce(jsonb_agg(e order by i), '[]'::jsonb) from jsonb_array_elements(m.addons) with ordinality t(e, i)
        where not (e ->> 'name' = r.name and coalesce((e ->> 'pending')::boolean, false))) where id = m.id;
    end if;
  end if;
  update price_requests set status = case when p_ok then 'approved' else 'declined' end, note = nullif(trim(p_note), ''), decided_at = now(), decided_by = lower(auth.jwt() ->> 'email') where id = p_id;
  if to_regclass('public.notifications') is not null then
    insert into notifications (kitchen_id, title, body, type) values (r.kitchen_id,
      case when p_ok then 'Price change approved' else 'Price change declined' end,
      r.name || case when r.kind in ('new_dish', 'new_extra') then ' at GHS ' || trim_scale(r.new_price) else ': GHS ' || trim_scale(r.old_price) || ' → ' || trim_scale(r.new_price) end
        || case when p_note is not null and trim(p_note) <> '' then '. ' || trim(p_note) else '' end, 'price');
  end if;
end $$;
revoke all on function vendor_price_requests(text) from public;
grant execute on function vendor_price_requests(text) to anon, authenticated;
revoke all on function admin_price_decide(uuid, boolean, text) from public, anon;
grant execute on function admin_price_decide(uuid, boolean, text) to authenticated;

-- Past orders: your account's orders from the last 3 months, newest first, a page at a time
CREATE OR REPLACE FUNCTION public.my_order_history(p_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 20)
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
  where auth.uid() is not null and o.user_id = auth.uid()
    and o.order_date >= (now() at time zone 'utc')::date - 92
    and (p_before is null or o.created_at < p_before)
  order by o.created_at desc
  limit least(greatest(coalesce(p_limit, 20), 1), 100);
$function$;
revoke all on function my_order_history(timestamptz, integer) from public, anon;
grant execute on function my_order_history(timestamptz, integer) to authenticated;

-- Ordering: refuse extras that are switched off or waiting for approval
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
  -- Extras the vendor has switched off (or that wait for ChopPool's approval) can't be ordered
  if exists (select 1 from jsonb_array_elements(v_add) e where coalesce((e ->> 'off')::boolean, false) or coalesce((e ->> 'pending')::boolean, false)) then
    raise exception 'An extra you picked is no longer available. Close the dish and open it again to see what''s on today.';
  end if;

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
