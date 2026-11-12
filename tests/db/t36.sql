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
select place_order(:'s1', :'i1', 2, 'Ama B', '0240000105', 'REFXA5', array['Fried eggs','Fried eggs','Fish#20'], null, null, false, null) as o5 \gset
select 'A5 2 eggs + Fish 20 per plate', addons_total = 28 and (select (e ->> 'qty')::int from jsonb_array_elements(addons) e where e ->> 'name' = 'Fried eggs') = 2 from orders where id = (:'o5'::json ->> 'id')::uuid;
select place_order(:'s1', :'i1', 1, 'Ama C', '0240000106', 'REFXA6', array['Fried eggs','Fried eggs','Fried eggs','Fried eggs','Fried eggs','Fried eggs','Fried eggs'], null, null, false, null) as o6 \gset
select 'A6 at most 5 of one extra', addons_total = 20 from orders where id = (:'o6'::json ->> 'id')::uuid;
insert into admins (email, role) values ('boss@x.com', 'coordinator') on conflict do nothing;
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","email":"ama@x.com"}'; set role authenticated;
do $$ begin begin perform admin_rename_addons(null, '[]'); raise notice 'R1 FAIL'; exception when others then raise notice 'R1 ok not team'; end; end $$;
reset role; set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com"}'; set role authenticated;
select admin_rename_addons(:'i1', '[{"from":"Fish","to":"Fish (medium)","price":20},{"from":"Fried eggs","to":"Fried egg","price":4}]') as nr \gset
reset role;
select 'R2 orders renamed', :nr >= 3 as ok;
select 'R3 Fish 20 renamed, Fish 15 untouched, totals same', (select addons_total = 28 and addons @> '[{"name":"Fish (medium)","price":20}]' and addons @> '[{"name":"Fried egg","qty":2}]' from orders where id = (:'o5'::json ->> 'id')::uuid)
  and (select addons @> '[{"name":"Fish","price":15}]' and addons_total = 15 from orders where id = (:'o1'::json ->> 'id')::uuid) as ok;
rollback;
