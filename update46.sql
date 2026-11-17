-- ChopPool update 46: a vendor can have their own fee terms (the Settings fee stays the default)
-- Safe to run more than once.

alter table kitchens add column if not exists fee_own boolean not null default false;   -- true = this vendor's own terms below
alter table kitchens add column if not exists fee_own_rate numeric;                     -- 0.05 = 5%
alter table kitchens add column if not exists fee_own_free int;                         -- meals in each pool with no fee
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'kitchens_fee_own_chk') then
    alter table kitchens add constraint kitchens_fee_own_chk check (
      (fee_own_rate is null or fee_own_rate between 0 and 0.5) and (fee_own_free is null or fee_own_free between 0 and 100)
      and (not fee_own or (fee_own_rate is not null and fee_own_free is not null)));
  end if;
end $$;

-- The terms that apply to one vendor: their own when set, else the Settings default
create or replace function vendor_fee_rate_of(p_kitchen uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select case when k.fee_own then k.fee_own_rate else s.vendor_fee_rate end from kitchens k, settings s where s.id = 1 and k.id = p_kitchen;
$$;
create or replace function vendor_fee_free_of(p_kitchen uuid) returns int
language sql stable security definer set search_path = public as $$
  select case when k.fee_own then k.fee_own_free else s.vendor_fee_free end from kitchens k, settings s where s.id = 1 and k.id = p_kitchen;
$$;

-- Only the owner sets a vendor's own fee (same rule as the default fee in Settings)
create or replace function kitchens_fee_owner_guard() returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') and not is_super()
     and (case when tg_op = 'INSERT' then new.fee_own or new.fee_own_rate is not null or new.fee_own_free is not null
          else new.fee_own is distinct from old.fee_own or new.fee_own_rate is distinct from old.fee_own_rate or new.fee_own_free is distinct from old.fee_own_free end) then
    raise exception 'Only the owner can change a vendor''s fee.';
  end if;
  return new;
end $$;
drop trigger if exists kitchens_fee_owner_guard on kitchens;
create trigger kitchens_fee_owner_guard before insert or update on kitchens for each row execute function kitchens_fee_owner_guard();

create or replace function pools_fee_terms() returns trigger language plpgsql security definer set search_path = public as $$
declare k kitchens;
begin
  select * into k from kitchens where id = new.kitchen_id;
  if new.fee_rate is null then new.fee_rate := least(coalesce(k.fee_ack, 0), vendor_fee_rate_of(k.id)); end if;
  if new.fee_free is null then new.fee_free := greatest(coalesce(k.fee_free_ack, 5), vendor_fee_free_of(k.id)); end if;
  return new;
end $$;

create or replace function kitchen_accept_terms(p_token text)
returns json language plpgsql security definer set search_path = public as $$
declare k kitchens; r numeric; f int;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  r := vendor_fee_rate_of(k.id); f := vendor_fee_free_of(k.id);
  update kitchens set fee_ack = r, fee_free_ack = f where id = k.id;
  update pools set fee_rate = r, fee_free = f where kitchen_id = k.id and status = 'waiting';
  return json_build_object('rate', r, 'free', f);
end $$;

create or replace function kitchen_open_day(p_token text, p_date date)
returns void language plpgsql security definer set search_path = public as $$
declare k kitchens; r numeric; f int;
begin
  select * into k from kitchens where token = p_token and active;
  if not found then raise exception 'This vendor link is not valid.'; end if;
  r := vendor_fee_rate_of(k.id); f := vendor_fee_free_of(k.id);
  if r > k.fee_ack or f < k.fee_free_ack then
    raise exception 'Accept the new ChopPool fee terms first.';
  end if;
  update kitchens set paused_dates = array_remove(paused_dates, p_date) where id = k.id;
  insert into kitchen_days (kitchen_id, order_date) values (k.id, p_date) on conflict do nothing;
  update pools set status = 'collecting', fee_rate = least(k.fee_ack, r), fee_free = greatest(k.fee_free_ack, f)
  where kitchen_id = k.id and order_date = p_date and status = 'waiting';
end $$;

create or replace function kitchen_is_open(p_kitchen uuid, p_date date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from kitchen_days where kitchen_id = p_kitchen and order_date = p_date)
      or exists (select 1 from kitchens k where k.id = p_kitchen and k.active
                   and extract(isodow from p_date)::int = any(k.auto_days) and not (p_date = any(k.paused_dates))
                   and vendor_fee_rate_of(k.id) <= coalesce(k.fee_ack, 0) and vendor_fee_free_of(k.id) >= coalesce(k.fee_free_ack, 5));
$$;

-- The vendor page shows the terms that apply to them
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
                                 'pool_size', kitchen_pool_size(k.id), 'pool_size_own', k.pool_size, 'no_daily_limit', k.no_daily_limit,
                                 'pool_default', s.max_meals, 'pool_ceiling', s.pool_ceiling,
                                 'delivery_mode', k.delivery_mode, 'added_by_customer', k.added_by_customer,
                                 'open', kitchen_is_open(k.id, p_date), 'listing_status', k.listing_status, 'listing', k.listing,
                                 'auto_days', k.auto_days, 'paused', p_date = any(k.paused_dates),
                                 'confirmed', exists (select 1 from kitchen_days where kitchen_id = k.id and order_date = p_date),
                                 'has_pin', k.lat is not null, 'free_m', k.free_m, 'free_min', k.free_min, 'free_max_m', s.free_max_m,
                                 'fee_ack', k.fee_ack, 'fee_free_ack', k.fee_free_ack, 'fee_rate', vendor_fee_rate_of(k.id), 'fee_free', vendor_fee_free_of(k.id), 'fee_own', k.fee_own,
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
