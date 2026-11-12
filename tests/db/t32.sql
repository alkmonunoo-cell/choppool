\pset tuples_only on
begin;
update settings set cutoff = '23:59' where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer and k.lat is not null order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
update menu_items set addons = '[{"name":"Fish","price":15},{"name":"Fish","price":20},{"name":"Fish","price":30.5},{"name":"Fried eggs","price":4}]' where id = :'i1';
select place_order(:'s1', :'i1', 1, 'Ama Owusu', '0240000101', 'REFXA1', array['Fish#15'], null, null, false, null) as o1 \gset
select 'A1 one Fish (15) charged once', addons_total = 15 from orders where id = (:'o1'::json ->> 'id')::uuid;
select place_order(:'s1', :'i1', 1, 'Kofi', '0240000102', 'REFXA2', array['Fish#30.5','Fried eggs'], null, null, false, null) as o2 \gset
select 'A2 Fish 30.5 + eggs', addons_total = 34.5 and jsonb_array_length(addons) = 2 from orders where id = (:'o2'::json ->> 'id')::uuid;
select place_order(:'s1', :'i1', 1, 'Esi', '0240000103', 'REFXA3', array['Fish'], null, null, false, null) as o3 \gset
select 'A3 old app sending bare Fish: charged once', addons_total = 15 from orders where id = (:'o3'::json ->> 'id')::uuid;
select place_order(:'s1', :'i1', 1, 'Yaw', '0240000104', 'REFXA4', array['Fried eggs'], null, null, false, null) as o4 \gset
select 'A4 unique name still works', addons_total = 4 from orders where id = (:'o4'::json ->> 'id')::uuid;
rollback;
