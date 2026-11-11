-- ChopPool update 30: a lowest trip price (minimum fare), like Bolt and Yango
-- Safe to run more than once.

-- Trips cost base fare + rate per km, never below the lowest trip price and never above the highest.
-- Starts at GHS 10, so nothing changes until you lower the base fare.
alter table settings add column if not exists trip_min numeric not null default 10;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'settings_trip_min_chk') then
    alter table settings add constraint settings_trip_min_chk check (trip_min >= 0);
  end if;
end $$;

create or replace function pool_trip(p uuid) returns numeric language sql stable security definer set search_path = public as $$
  select case
    when pool_free(p) then 0
    when coalesce(k.lat, case when k.added_by_customer then st.lat end) is null or st.lat is null then greatest(s.trip_min, least(s.trip_cost, s.trip_max))
    else greatest(s.trip_min, least(s.trip_max, round(s.base_fare + s.per_km * dist_m(
           coalesce(k.lat, case when k.added_by_customer then st.lat end),
           coalesce(k.lng, case when k.added_by_customer then st.lng end),
           st.lat, st.lng) / 1000 * 1.3)))
  end
  from pools pl join kitchens k on k.id = pl.kitchen_id join sites st on st.id = pl.site_id cross join settings s
  where pl.id = p and s.id = 1;
$$;

select 'ChopPool database is up to date (version 30)' as result;
