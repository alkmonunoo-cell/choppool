\pset tuples_only on
begin;
update settings set cutoff = '23:59' where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer and k.lat is not null order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
update menu_items set addons = '[{"name":"Fish","price":15},{"name":"Fish","price":20},{"name":"Fish","price":30.5},{"name":"Fried eggs","price":4}]' where id = :'i1';
update kitchens set added_by_customer = false where id = :'k1';
update menu_items set price = 5, addons = '[{"name":"Fish","price":15},{"name":"Fish","price":20},{"name":"Eggs","price":4}]' where id = :'i1';
insert into admins (email, role) values ('boss@x.com', 'super'), ('co@x.com', 'coordinator') on conflict (email) do update set role = excluded.role;
-- vendor (listed by ChopPool) edits: dish 5 -> 6 (up), Fish 15 -> 18 (up), Fish 20 -> 12 (down), Eggs off, new Gizzard 10, rename Eggs? no
select vendor_set_menu(:'tk', jsonb_build_array(jsonb_build_object('id', :'i1', 'name', 'Kenkey', 'price', 6, 'addons', jsonb_build_array(
  jsonb_build_object('name', 'Fish', 'price', 18, 'orig_name', 'Fish', 'orig_price', 15),
  jsonb_build_object('name', 'Fish', 'price', 12, 'orig_name', 'Fish', 'orig_price', 20),
  jsonb_build_object('name', 'Eggs', 'price', 4, 'off', true, 'orig_name', 'Eggs', 'orig_price', 4),
  jsonb_build_object('name', 'Gizzard', 'price', 10))),
  jsonb_build_object('name', 'Waakye', 'price', 30)));
select 'V1 vendors listed by ChopPool can save', true as ok;
select 'V2 higher dish price waits', (select price from menu_items where id = :'i1') = 5 as ok;
select 'V3 lower extra price applies, higher waits', (select addons -> 0 ->> 'price' = '15' and addons -> 1 ->> 'price' = '12' from menu_items where id = :'i1') as ok;
select 'V4 off and pending flags kept', (select (addons -> 2 ->> 'off')::boolean and (addons -> 3 ->> 'pending')::boolean from menu_items where id = :'i1') as ok;
select 'V5 four requests (dish, extra, new extra, new dish)', (select string_agg(kind, ',' order by kind) from price_requests where kitchen_id = :'k1' and status = 'pending') = 'dish,extra,new_dish,new_extra' as ok;
select 'V6 new dish hidden', (select not active from menu_items where kitchen_id = :'k1' and name = 'Waakye') as ok;
-- vendor tries to switch the new dish on: stays hidden
select vendor_set_menu(:'tk', jsonb_build_array(jsonb_build_object('id', (select id from menu_items where kitchen_id = :'k1' and name = 'Waakye'), 'name', 'Waakye', 'price', 28, 'active', true)));
select 'V7 vendor cannot switch on a dish waiting for approval', (select not active and price = 28 from menu_items where kitchen_id = :'k1' and name = 'Waakye')
  and (select new_price = 28 from price_requests where kind = 'new_dish' and status = 'pending' and kitchen_id = :'k1') as ok;
-- a faked orig (pretend Fish was 18 already) doesn't count
select vendor_set_menu(:'tk', jsonb_build_array(jsonb_build_object('id', :'i1', 'name', 'Kenkey', 'price', 5, 'addons', jsonb_build_array(
  jsonb_build_object('name', 'Fish', 'price', 25, 'orig_name', 'Fish', 'orig_price', 25), jsonb_build_object('name', 'Fish', 'price', 12, 'orig_name', 'Fish', 'orig_price', 12)))));
select 'V8 made-up original counts as new (hidden until approved)', (select (addons -> 0 ->> 'pending')::boolean from menu_items where id = :'i1') as ok;
-- ordering a hidden or off extra is refused
update menu_items set addons = '[{"name":"Fish","price":15},{"name":"Eggs","price":4,"off":true}]' where id = :'i1';
do $$ begin begin perform place_order((select id from sites where name like 'Pent%'), (select id from menu_items where name = 'Kenkey' limit 1), 1, 'Ama', '0240000901', 'REFXD1', array['Eggs'], null, null, false, null); raise notice 'V9 FAIL'; exception when others then raise notice 'V9 ok switched-off extra refused: %', sqlerrm; end; end $$;
select place_order(:'s1', :'i1', 1, 'Ama', '0240000902', 'REFXD2', array['Fish'], null, null, false, null) is not null as v10 \gset
select 'V10 live extra still fine', :'v10' as ok;
-- decisions
set request.jwt.claims = '{"sub":"dddddddd-dddd-dddd-dddd-dddddddddddd","email":"co@x.com"}'; set role authenticated;
do $$ begin begin perform admin_price_decide((select id from price_requests where kind = 'dish' and status = 'pending' limit 1), true); raise notice 'V11 FAIL'; exception when others then raise notice 'V11 ok coordinators cannot approve'; end; end $$;
reset role; set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com"}'; set role authenticated;
select admin_price_decide((select id from price_requests where kind = 'dish' and status = 'pending' and kitchen_id = :'k1' limit 1), true);
select admin_price_decide((select id from price_requests where kind = 'new_dish' and status = 'pending' and kitchen_id = :'k1' limit 1), true, 'Looks good');
reset role;
select 'V12 approved dish price applies', (select price from menu_items where id = :'i1') = 6 as ok;
select 'V13 approved new dish goes live', (select active from menu_items where kitchen_id = :'k1' and name = 'Waakye') as ok;
select 'V14 vendor told in their bell', (select count(*) from notifications where kitchen_id = :'k1' and title like 'Price change approved') = 2 as ok;
select 'V15 vendor sees requests', (select count(*) from vendor_price_requests(:'tk')) >= 4 as ok;
update menu_items set addons = '[{"name":"Fish","price":15},{"name":"Fish","price":20}]' where id = :'i1';
update price_requests set status = 'replaced' where kitchen_id = :'k1' and status = 'pending';
select vendor_set_menu(:'tk', jsonb_build_array(jsonb_build_object('id', :'i1', 'name', 'Kenkey', 'price', 6, 'addons', jsonb_build_array(
  jsonb_build_object('name', 'Fish', 'price', 18, 'orig_name', 'Fish', 'orig_price', 15), jsonb_build_object('name', 'Fish', 'price', 20, 'orig_name', 'Fish', 'orig_price', 20),
  jsonb_build_object('name', 'Shito', 'price', 2)))));
set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com"}'; set role authenticated;
select admin_price_decide((select id from price_requests where kind = 'extra' and status = 'pending' and kitchen_id = :'k1'), true);
select admin_price_decide((select id from price_requests where kind = 'new_extra' and status = 'pending' and kitchen_id = :'k1'), false, 'Shito is free here');
reset role;
select 'V16 approved extra price applies to the right Fish', (select addons::text from menu_items where id = :'i1') = '[{"name": "Fish", "price": 18}, {"name": "Fish", "price": 20}]' as ok;
reset role;
update orders set user_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' where phone like '%0902';
set request.jwt.claims = '{"sub":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"}'; set role authenticated;
select 'V17 history shows own order', (select count(*) from my_order_history(null, 20)) = 1 as ok;
reset role; update orders set order_date = current_date - 100 where user_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
set role authenticated;
select 'V18 history drops orders older than 3 months', (select count(*) from my_order_history(null, 20)) = 0 as ok;
reset role; set request.jwt.claims = '{"sub":"ffffffff-ffff-ffff-ffff-ffffffffffff"}'; update orders set order_date = current_date where user_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'; set role authenticated;
select 'V19 others cannot see it', (select count(*) from my_order_history(null, 20)) = 0 as ok;
reset role;
rollback;
