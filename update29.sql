-- ChopPool update 29: a delivered pool's trip cost fills itself in (no typing it by hand)
-- Safe to run more than once.

-- When a pool is marked delivered and nobody has entered a trip cost, use the trip price for that vendor and building
-- (the same base fare + rate per km the app charges). Vendors who deliver with their own runner, and free-delivery
-- pools, owe no rider. A cost you type yourself is never overwritten.
create or replace function pool_trip_on_delivery() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'delivered' and old.status is distinct from 'delivered' and new.trip_cost is null
     and not exists (select 1 from kitchens k where k.id = new.kitchen_id and k.delivery_mode = 'runner')
     and not pool_free(new.id) then
    new.trip_cost := pool_trip(new.id);
  end if;
  return new;
end $$;
drop trigger if exists pool_trip_on_delivery on pools;
create trigger pool_trip_on_delivery before update on pools for each row execute function pool_trip_on_delivery();

-- Pools already delivered without a trip cost: fill them in the same way
update pools pl set trip_cost = pool_trip(pl.id)
 where pl.status = 'delivered' and pl.trip_cost is null
   and not exists (select 1 from kitchens k where k.id = pl.kitchen_id and k.delivery_mode = 'runner')
   and not pool_free(pl.id);

select 'ChopPool database is up to date (version 29)' as result;
