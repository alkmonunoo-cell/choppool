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
