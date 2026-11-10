-- ChopPool update 27 (tester feedback)

-- Adding several dishes to an order you already have (joining your own code): one payment for all of them.
-- place_basket gains p_join; the first new dish carries the payment and the others follow it (same code, packed together).
drop function if exists place_basket(uuid, jsonb, text, text, text, boolean, text, text);
create or replace function place_basket(p_site uuid, p_lines jsonb, p_name text, p_phone text, p_ref text,
                                        p_use_wallet boolean default false, p_payer_phone text default null, p_payer_network text default null,
                                        p_join uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  ln jsonb; n int := 0; r json; v_main uuid; v_code text; v_ids uuid[] := '{}'; v_total numeric := 0; v_use numeric := 0; v_left numeric;
  v_uid uuid := auth.uid(); o record; v_payer uuid; v_part numeric; v_meals int := 0; v_kitchen uuid; v_pp text := regexp_replace(coalesce(p_payer_phone, ''), '\D', '', 'g');
  s settings;
begin
  select * into s from settings where id = 1;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Your tray is empty.'; end if;
  if jsonb_array_length(p_lines) > 8 then raise exception 'Up to 8 different dishes in one order.'; end if;
  select coalesce(sum(greatest(1, coalesce((x ->> 'qty')::int, 1))), 0) into v_meals from jsonb_array_elements(p_lines) x;
  if v_meals > least(10, s.max_meals) then raise exception 'Up to % meals in one order.', least(10, s.max_meals); end if;
  if (select count(distinct m.kitchen_id) from jsonb_array_elements(p_lines) x join menu_items m on m.id = (x ->> 'item')::uuid) > 1
     or (p_join is not null and exists (select 1 from jsonb_array_elements(p_lines) x join menu_items m on m.id = (x ->> 'item')::uuid
                                         where m.kitchen_id <> (select kitchen_id from orders where id = p_join))) then
    raise exception 'Order from one vendor at a time.';
  end if;
  if v_pp <> '' and v_pp !~ '^0\d{9}$' then raise exception 'Enter the 10-digit mobile money number you paid from.'; end if;

  for ln in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    r := place_order(p_site, (ln ->> 'item')::uuid, greatest(1, coalesce((ln ->> 'qty')::int, 1)), p_name, p_phone, 'BASKET',
                     coalesce((select array_agg(a) from jsonb_array_elements_text(coalesce(ln -> 'addons', '[]'::jsonb)) a), '{}'),
                     ln ->> 'note', null, false, coalesce(p_join, v_main));
    if n = 1 then v_main := (r ->> 'id')::uuid; v_code := r ->> 'code'; end if;   -- with p_join: the first new dish is the one that carries the payment
    v_ids := v_ids || (r ->> 'id')::uuid;
  end loop;

  -- One payment for everything under this code: wallet first, the rest by mobile money
  update orders set momo_ref = null, status = 'pending', basket = (id <> v_main),
         payer_phone = nullif(v_pp, ''), payer_network = nullif(trim(coalesce(p_payer_network, '')), '')
   where id = any(v_ids);
  select coalesce(sum(order_total(x)), 0) into v_total from orders x where x.id = any(v_ids);
  if p_use_wallet and v_uid is not null and exists (select 1 from orders where id = v_main and user_id = v_uid) then
    v_use := greatest(0, least(wallet_balance(v_uid), v_total));
    if v_use > 0 then
      insert into wallet_entries (user_id, amount, reason, order_id) values (v_uid, -v_use, 'Paid for order ' || v_code, v_main);
    end if;
  end if;
  if v_use < v_total and (p_ref is null or char_length(trim(p_ref)) < 4) then
    raise exception 'Enter the mobile money transaction ID for the remaining %.', to_char(v_total - v_use, 'FM999990.00');
  end if;
  -- Spread the wallet part across the dishes (first dish first) so refunds stay exact
  v_left := v_use;
  for o in select x.id, order_total(x) as t from orders x where x.id = any(v_ids) order by (x.id <> v_main), x.created_at loop
    v_part := least(v_left, o.t); v_left := v_left - v_part;
    update orders set wallet_used = v_part,
           status = case when v_use >= v_total then 'paid' else 'pending' end,   -- one payment: all dishes paid together
           momo_ref = case when o.id = v_main and v_use < v_total then trim(p_ref) else null end
     where id = o.id;
  end loop;
  return json_build_object('id', v_main, 'code', v_code, 'ids', v_ids, 'total', v_total, 'wallet_used', v_use, 'momo_due', v_total - v_use,
                           'status', (select status from orders where id = v_main), 'order_date', (select order_date from orders where id = v_main));
end $$;

revoke all on function place_basket(uuid, jsonb, text, text, text, boolean, text, text, uuid) from public;
grant execute on function place_basket(uuid, jsonb, text, text, text, boolean, text, text, uuid) to anon, authenticated;

create or replace function basket_follow() returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- The dish carrying a payment decides for the dishes paid with it: the code's added dishes (new order),
  -- or the dishes added together to an existing code (same parent, placed in the same moment)
  if new.status is distinct from old.status then
    if new.status = 'paid' and old.status = 'pending' then
      update orders set status = 'paid' where basket and status = 'pending'
         and (parent_id = new.id or (new.parent_id is not null and parent_id = new.parent_id and created_at = new.created_at and id <> new.id));
    elsif new.status = 'cancelled' and new.cancel_reason = 'Payment not received' then
      update orders set status = 'cancelled', cancel_reason = 'Payment not received', refund_due = 0, refund_needed = false
       where basket and status = 'pending'
         and (parent_id = new.id or (new.parent_id is not null and parent_id = new.parent_id and created_at = new.created_at and id <> new.id));
    end if;
  end if;
  return null;
end $$;

-- Vendor fee: a vendor's automatic cooking days only open once they've accepted the current ChopPool fee
-- (before, automatic days kept running at the old 0% because the "Accept terms" step never came up)
create or replace function kitchen_is_open(p_kitchen uuid, p_date date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from kitchen_days where kitchen_id = p_kitchen and order_date = p_date)
      or exists (select 1 from kitchens k, settings s where s.id = 1 and k.id = p_kitchen and k.active
                   and extract(isodow from p_date)::int = any(k.auto_days) and not (p_date = any(k.paused_dates))
                   and s.vendor_fee_rate <= coalesce(k.fee_ack, 0) and s.vendor_fee_free >= coalesce(k.fee_free_ack, 5));
$$;

-- Rider sign-up: Ghana Card number, driving licence number and expiry (seen only by the ChopPool team)
alter table riders add column if not exists ghana_card text;
alter table riders add column if not exists licence_no text;
alter table riders add column if not exists licence_expiry date;
drop function if exists rider_apply(text, text, text, text, text);
create or replace function rider_apply(p_name text, p_phone text, p_bike text, p_area text, p_momo text,
                                       p_ghana_card text default null, p_licence_no text default null, p_licence_expiry date default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
        v_card text := upper(regexp_replace(coalesce(p_ghana_card, ''), '[^0-9A-Za-z]', '', 'g'));
        v_lic text := upper(left(trim(coalesce(p_licence_no, '')), 20));
begin
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Add your full name.'; end if;
  if v_phone !~ '^0\d{9}$' then raise exception 'Enter your 10-digit phone number, like 024 123 4567.'; end if;
  if v_card !~ '^GHA\d{10}$' then raise exception 'Enter your Ghana Card number, like GHA-123456789-0.'; end if;
  if length(regexp_replace(v_lic, '[^0-9A-Z]', '', 'g')) < 5 then raise exception 'Enter your driving licence number.'; end if;
  if p_licence_expiry is null or p_licence_expiry < (now() at time zone 'utc')::date then raise exception 'Your driving licence has expired. Renew it, then apply.'; end if;
  if exists (select 1 from riders where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = v_phone) then raise exception 'This phone number has already applied.'; end if;
  if exists (select 1 from riders where ghana_card = 'GHA-' || substr(v_card, 4, 9) || '-' || substr(v_card, 13, 1)) then raise exception 'This Ghana Card has already applied.'; end if;
  if (select count(*) from riders where status = 'pending' and created_at > now() - interval '1 day') > 50 then raise exception 'Too many applications today. Please try tomorrow.'; end if;
  insert into riders (name, phone, bike, area, momo, status, active, ghana_card, licence_no, licence_expiry)
  values (left(trim(p_name), 60), v_phone, left(trim(coalesce(p_bike, '')), 60), left(trim(coalesce(p_area, '')), 60), left(regexp_replace(coalesce(p_momo, ''), '[^0-9 ]', '', 'g'), 20), 'pending', false,
          'GHA-' || substr(v_card, 4, 9) || '-' || substr(v_card, 13, 1), v_lic, p_licence_expiry);
end $$;
revoke all on function rider_apply(text, text, text, text, text, text, text, date) from public;
grant execute on function rider_apply(text, text, text, text, text, text, text, date) to anon, authenticated;

-- Buildings customers add go live straight away (an existing one nearby or with the same name is reused)
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
  -- Already on ChopPool (or already asked for)? Same name, or a building within 80 m: use that one instead of a copy
  select * into si from sites
   where status in ('active', 'pending') and not archived
     and (lower(regexp_replace(name, '\s+', ' ', 'g')) = lower(regexp_replace(trim(p_name), '\s+', ' ', 'g'))
          or (lat is not null and dist_m(lat, lng, p_lat, p_lng) <= 80))
   order by (status = 'active') desc, created_at limit 1;
  if found then
    v_joined := true;
  else
    if (select count(*) from site_waiters w where w.created_at > now() - interval '1 day'
        and ((auth.uid() is not null and w.user_id = auth.uid()) or (p_endpoint is not null and w.endpoint = p_endpoint))) >= 5
     or (select count(*) from sites where requested_by is not null and created_at > now() - interval '1 day') >= 300 then
      raise exception 'Too many building requests today. Please try again tomorrow.';
    end if;
    -- New buildings go live straight away; the team reviews them and merges any duplicates
    insert into sites (name, drop_point, lat, lng, status, requested_by, request_note)
    values (trim(p_name), trim(p_drop_point), p_lat, p_lng, 'active', auth.uid(), coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Added by a customer'))
    returning * into si;
  end if;
  if auth.uid() is not null or p_endpoint is not null then
    insert into site_waiters (site_id, user_id, endpoint) values (si.id, auth.uid(), p_endpoint) on conflict do nothing;
  end if;
  select count(*) into v_n from site_waiters where site_id = si.id;
  return json_build_object('id', si.id, 'name', si.name, 'status', si.status, 'joined', v_joined, 'waiting', greatest(v_n, 1));
end $function$;
-- Buildings already waiting for approval go live now too
update sites set status = 'active' where status = 'pending' and not archived;

select 'ChopPool database is up to date (version 27)' as result;
