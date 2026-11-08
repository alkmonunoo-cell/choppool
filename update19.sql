-- ============================================================
-- ChopPool update 19 (Release A: security). Safe to run more than once.
-- ============================================================

-- 1. Public views are read-only (they run with the owner's rights, so writes would bypass row security)
revoke insert, update, delete, truncate, references, trigger on
  public_sites, public_pools, kitchen_load, recent_activity, public_menus, dish_popularity, site_kitchen_counts, public_reviews, kitchen_scores
  from anon, authenticated, public;

-- 2. The activity feed no longer shows real order IDs (a one-way fingerprint instead)
drop view if exists recent_activity;
create view recent_activity as
select left(encode(sha256(convert_to(o.id::text, 'UTF8')), 'hex'), 16) as id,
       o.order_date, o.site_id, o.kitchen_id, o.pool_id, o.item_name, o.qty, o.created_at
  from orders o
 where o.status not in ('cancelled', 'quote_requested', 'quoted') and o.created_at > now() - interval '6 hours';
revoke all on recent_activity from anon, authenticated, public;
grant select on recent_activity to anon, authenticated;

-- 3. Sellers only see order IDs for special requests they need to price
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
        'orders', (select json_agg(json_build_object('id', case when o.status in ('quote_requested', 'quoted') then o.id end, 'code', o.code, 'qty', o.qty, 'item_name', o.item_name,
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

-- 4. Internal helpers can't be called from outside (functions that use them still work)
do $$ declare f text; begin
  foreach f in array array['fee_for(integer)', 'fee_for(integer, numeric)', 'new_code(uuid, date, uuid)', 'order_cashback(uuid)', 'pool_fee(uuid)', 'pool_free(uuid)',
                           'pool_meals(uuid)', 'pool_trip(uuid)', 'wait_deadline(timestamp with time zone, date)', 'wallet_balance(uuid)'] loop
    if to_regprocedure('public.' || f) is not null then
      execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    end if;
  end loop;
end $$;

-- 5. Owner-only money settings, enforced by the database
create or replace function settings_owner_guard() returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') and not is_super()
     and (new.vendor_fee_rate is distinct from old.vendor_fee_rate or new.vendor_fee_free is distinct from old.vendor_fee_free) then
    raise exception 'Only the owner can change the ChopPool vendor fee.';
  end if;
  return new;
end $$;
drop trigger if exists settings_owner_guard on settings;
create trigger settings_owner_guard before update on settings for each row execute function settings_owner_guard();

-- 6. Wallet credits and debits: owner only (coordinators can still see wallets)
drop policy if exists "admin wallets" on wallet_entries;
drop policy if exists "team wallets read" on wallet_entries;
drop policy if exists "owner wallets" on wallet_entries;
create policy "team wallets read" on wallet_entries for select to authenticated using (is_admin());
create policy "owner wallets" on wallet_entries for all to authenticated using (is_super()) with check (is_super());

-- 7. Coordinators can only change payment checks, status and refund flags on orders
create or replace function orders_coordinator_guard() returns trigger language plpgsql as $$
declare a jsonb; b jsonb; k text;
begin
  if current_user not in ('authenticated', 'anon') or is_super() then return new; end if;
  a := to_jsonb(old); b := to_jsonb(new);
  for k in select key from jsonb_each(b) loop
    if k in ('status', 'pay_issue', 'amount_received', 'refund_needed', 'collected_at', 'collected_by') then continue; end if;
    if k = 'refund_due' and coalesce((b->>k)::numeric, 0) = 0 then continue; end if;
    if (a->k) is distinct from (b->k) then raise exception 'Coordinators can''t change % on an order. Ask the owner.', k; end if;
  end loop;
  return new;
end $$;
drop trigger if exists orders_coordinator_guard on orders;
create trigger orders_coordinator_guard before update on orders for each row execute function orders_coordinator_guard();
-- Coordinators can't delete orders either
drop policy if exists "admin orders" on orders;
drop policy if exists "team orders" on orders;
drop policy if exists "team orders update" on orders;
drop policy if exists "owner orders" on orders;
create policy "team orders" on orders for select to authenticated using (is_admin());
create policy "team orders update" on orders for update to authenticated using (is_admin()) with check (is_admin());
create policy "owner orders" on orders for all to authenticated using (is_super()) with check (is_super());
