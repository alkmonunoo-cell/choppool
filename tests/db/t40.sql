\pset tuples_only on
begin;
update settings set cutoff = '23:59' where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer and k.lat is not null order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
update menu_items set addons = '[{"name":"Fish","price":15},{"name":"Fish","price":20},{"name":"Fish","price":30.5},{"name":"Fried eggs","price":4}]' where id = :'i1';
select place_order(:'s1', :'i1', 1, 'Ama', '0240000301', 'REFXC1', '{}', null, null, false, null) as o1 \gset
update orders set status = 'paid' where id = (:'o1'::json ->> 'id')::uuid;
select pool_id as pid, max_fee * qty as charged from orders where id = (:'o1'::json ->> 'id')::uuid \gset
select pool_trip(:'pid') as before_trip \gset
update settings set base_fare = base_fare + 50, trip_min = trip_min + 50, trip_max = trip_max + 100 where id = 1;
select 'K1 pricing change moves the live estimate', pool_trip(:'pid') <> :before_trip as ok;
update pools set status = 'accepted' where id = :'pid';
select 'K2 closing keeps what customers were charged', (select trip_price from pools where id = :'pid') = :charged as ok;
update settings set base_fare = base_fare + 10 where id = 1;
update pools set status = 'delivered' where id = :'pid';
select 'K3 delivery cost uses the kept price', (select trip_cost from pools where id = :'pid') = :charged as ok;
insert into admins (email, role) values ('boss@x.com', 'super') on conflict (email) do update set role = excluded.role;
set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com"}'; set role authenticated;
select admin_money_days(current_order_date() - 1, current_order_date() + 1) as r \gset
reset role;
select 'K4 report trips use it', ((:'r'::json) -> 'days' -> 0 ->> 'trips_apps')::numeric + ((:'r'::json) -> 'days' -> 0 ->> 'trips_riders')::numeric = :charged as ok;
rollback;
