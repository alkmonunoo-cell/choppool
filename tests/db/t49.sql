\pset tuples_only on
begin;
update settings set cutoff = '23:59' where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer and k.lat is not null order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
update menu_items set price = 30, addons = '[{"name":"Egg","price":3},{"name":"Shito","price":0}]' where id = :'i1';
select (place_order(:'s1', :'i1', 1, 'Ama', '0240004901', 'MP49000001', array['Egg','Egg','Egg','Egg','Egg','Egg','Egg','Egg','Shito'], null, null, false, null) ->> 'id') as o1 \gset
select 'X1 eight eggs on one plate', (select (addons -> 0 ->> 'qty')::int = 8 and addons_total = 24 from orders where id = :'o1') as ok;
select (place_order(:'s1', :'i1', 1, 'Ama', '0240004902', 'MP49000002', array_fill('Egg'::text, array[120]), null, null, false, null) ->> 'id') as o2 \gset
select 'X2 capped at 99', (select (addons -> 0 ->> 'qty')::int = 99 from orders where id = :'o2') as ok;
rollback;
