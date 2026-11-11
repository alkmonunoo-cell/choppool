\pset tuples_only on
begin;
update settings set cutoff = '23:59', pool_ceiling = 15 where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select id as i2 from menu_items where kitchen_id = :'k1' and active order by name desc limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
select 'P1 default is 10 meals per pool', (select max_meals from settings where id = 1) = 10 and kitchen_pool_size(:'k1') = 10 as ok;
-- vendor chooses 6 a pool, 12 a day
set role anon;
select vendor_set_capacity(:'tk', 6, 12, false);
reset role;
select 'P2 vendor pool size saved', kitchen_pool_size(:'k1') = 6 and (select capacity from kitchens where id = :'k1') = 12 as ok;
select 'P3 public view shows the size', (select pool_size from public_menus where id = :'k1') = 6 as ok;
savepoint a; set role anon; select vendor_set_capacity(:'tk', 40, 12, false); rollback to savepoint a;
select 'P4 above the ceiling refused', kitchen_pool_size(:'k1') = 6 as ok;
savepoint a; set role anon; select vendor_set_capacity(:'tk', 3, 12, false); rollback to savepoint a;
select 'P5 below 5 refused', kitchen_pool_size(:'k1') = 6 as ok;
-- fill pool 1 (6), next order goes to pool 2 with the same vendor
select place_order(:'s1', :'i1', 4, 'Ama', '0240000101', 'REFX1', '{}', null, null, false, null) as o1 \gset
select place_order(:'s1', :'i1', 2, 'Ben', '0240000102', 'REFX2', '{}', null, null, false, null) as o2 \gset
select place_order(:'s1', :'i1', 3, 'Cal', '0240000103', 'REFX3', '{}', null, null, false, null) as o3 \gset
select 'P6 full pool: next order opens pool 2 with the same vendor', (:'o1'::json ->> 'pool_seq') = '1' and (:'o2'::json ->> 'pool_seq') = '1' and (:'o3'::json ->> 'pool_seq') = '2' as ok;
-- adding a plate to a full pool is refused
savepoint a; select place_order(:'s1', :'i1', 1, 'Ama', '0240000101', 'REFX4', '{}', null, null, false, (:'o1'::json ->> 'id')::uuid); rollback to savepoint a;
select 'P7 no plate added to a full pool', not exists (select 1 from orders where momo_ref = 'REFX4') as ok;
-- daily limit 12: 9 so far, 4 more refused
savepoint a; select place_order(:'s1', :'i1', 4, 'Dede', '0240000104', 'REFX5', '{}', null, null, false, null); rollback to savepoint a;
select 'P8 daily limit holds', not exists (select 1 from orders where momo_ref = 'REFX5') as ok;
-- no daily limit: allowed
set role anon; select vendor_set_capacity(:'tk', 6, null, true); reset role;
select place_order(:'s1', :'i1', 4, 'Dede', '0240000104', 'REFX6', '{}', null, null, false, null) as o6 \gset
select 'P9 no daily limit takes more pools', (:'o6'::json ->> 'pool_seq') = '3' as ok;
-- an order larger than the pool is refused (tray)
savepoint a; select place_basket(:'s1', jsonb_build_array(jsonb_build_object('item', :'i1', 'qty', 4), jsonb_build_object('item', :'i2', 'qty', 3)), 'Esi', '0240000105', 'REFX7'); rollback to savepoint a;
select 'P10 tray bigger than the pool refused', not exists (select 1 from orders where momo_ref = 'REFX7') as ok;
-- a tray goes into one pool that fits all of it, never split over a full one
select place_basket(:'s1', jsonb_build_array(jsonb_build_object('item', :'i1', 'qty', 2), jsonb_build_object('item', :'i2', 'qty', 1)), 'Fifi', '0240000106', 'REFX8') as t \gset
select 'P11 whole tray lands in one pool with room', count(distinct pool_id) = 1 and max(pool_meals(pool_id)) <= 6 as ok from orders where id = (:'t'::json ->> 'id')::uuid or parent_id = (:'t'::json ->> 'id')::uuid;
select 'P12 setting reset after the tray', coalesce(current_setting('cp.basket_meals', true), '') = '' as ok;
-- back to the default
set role anon; select vendor_set_capacity(:'tk', 10, 40, false); reset role;
select 'P13 choosing the default stores no override', (select pool_size from kitchens where id = :'k1') is null and kitchen_pool_size(:'k1') = 10 as ok;
select 'P14 weekly report counts full pools by vendor size', prosrc like '%kitchen_pool_size(kitchen_id)%' as ok from pg_proc where proname = 'admin_weekly_report';
rollback;
