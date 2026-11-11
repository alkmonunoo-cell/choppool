\pset tuples_only on
begin;
update settings set cutoff = '23:59' where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer and k.delivery_mode = 'rider' order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
select place_order(:'s1', :'i1', 2, 'Ama Owusu', '0240000101', 'REFX1', '{}', null, null, false, null) as o1 \gset
select pool_id as pid from orders where id = (:'o1'::json ->> 'id')::uuid \gset
update pools set status = 'delivered', delivered_at = now() where id = :'pid';
select 'T1 delivered pool gets its trip cost', trip_cost is not null and trip_cost = pool_trip(id) as ok from pools where id = :'pid';
update pools set trip_cost = 99 where id = :'pid'; update pools set status = 'accepted' where id = :'pid'; update pools set status = 'delivered' where id = :'pid';
select 'T2 a typed cost is kept', trip_cost = 99 as ok from pools where id = :'pid';
update kitchens set delivery_mode = 'runner' where id = :'k1';
select place_order(:'s1', :'i1', 1, 'Kofi Mensah', '0240000102', 'REFX2', '{}', null, null, false, null) as o2 \gset
update pools set trip_cost = null, status = 'accepted' where id = :'pid'; update pools set status = 'delivered' where id = :'pid';
select 'T3 own-runner vendor owes no rider', trip_cost is null as ok from pools where id = :'pid';
rollback;
