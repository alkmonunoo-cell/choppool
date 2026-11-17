\pset tuples_only on
begin;
update settings set cutoff = '23:59' where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select id as s2 from sites where active and status = 'active' and id <> :'s1' order by name limit 1 \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer and k.lat is not null order by name limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select id as i2 from menu_items where kitchen_id = :'k1' and active order by name offset 1 limit 1 \gset
update menu_items set price = 40, addons = '[{"name":"Shito","price":2},{"name":"Regular chicken","price":0,"group":"Choose your protein"},{"name":"Spicy wings","price":5,"group":"Choose your protein"}]' where id = :'i1';
-- H1 vendor saves the menu in a new order: the order is kept
select set_config('t.tk', :'tk', false);
select vendor_set_menu(:'tk', jsonb_build_array(
  jsonb_build_object('id', :'i2', 'name', (select name from menu_items where id = :'i2'), 'price', (select price from menu_items where id = :'i2'), 'addons', (select addons from menu_items where id = :'i2')),
  jsonb_build_object('id', :'i1', 'name', (select name from menu_items where id = :'i1'), 'price', 40,
    'addons', '[{"name":"Shito","price":2,"orig_name":"Shito","orig_price":2},{"name":"Regular chicken","price":0,"group":"Choose your protein","orig_name":"Regular chicken","orig_price":0},{"name":"Spicy wings","price":5,"group":"Choose your protein","orig_name":"Spicy wings","orig_price":5}]'::jsonb)));
select 'H1 menu order kept', (select sort_order from menu_items where id = :'i2') = 1 and (select sort_order from menu_items where id = :'i1') = 2 as ok;
select 'H2 choices kept with their group', (select count(*) from menu_items m, jsonb_array_elements(m.addons) e where m.id = :'i1' and e ->> 'group' = 'Choose your protein') = 2 as ok;
-- H3 more than 3 choice groups refused
do $$ begin begin perform vendor_set_menu(current_setting('t.tk'), jsonb_build_array(jsonb_build_object('name', 'Test dish', 'price', 30, 'addons',
  '[{"name":"Aa","group":"G1"},{"name":"Bb","group":"G2"},{"name":"Cc","group":"G3"},{"name":"Dd","group":"G4"}]'::jsonb)));
  raise notice 'H3 FAIL 4 groups saved'; exception when others then raise notice 'H3 ok: %', sqlerrm; end; end $$;
-- H4 ordering without the required choice is refused
select set_config('t.s1', :'s1', false); select set_config('t.i1', :'i1', false);
do $$ begin begin perform place_order(current_setting('t.s1')::uuid, current_setting('t.i1')::uuid, 1, 'Ama', '0240004701', 'REFH41', '{}', null, null, false, null);
  raise notice 'H4 FAIL no choice accepted'; exception when others then raise notice 'H4 ok: %', sqlerrm; end; end $$;
-- H5 two options from one group refused
do $$ begin begin perform place_order(current_setting('t.s1')::uuid, current_setting('t.i1')::uuid, 1, 'Ama', '0240004702', 'REFH51', array['Regular chicken','Spicy wings'], null, null, false, null);
  raise notice 'H5 FAIL two picks accepted'; exception when others then raise notice 'H5 ok: %', sqlerrm; end; end $$;
do $$ begin begin perform place_order(current_setting('t.s1')::uuid, current_setting('t.i1')::uuid, 1, 'Ama', '0240004703', 'REFH52', array['Spicy wings','Spicy wings'], null, null, false, null);
  raise notice 'H5b FAIL double pick accepted'; exception when others then raise notice 'H5b ok: %', sqlerrm; end; end $$;
-- H6 one choice: priced like an extra
select place_order(:'s1', :'i1', 1, 'Ama', '0240004704', 'REFH61', array['Spicy wings','Shito'], null, null, false, null) as o1 \gset
select 'H6 choice priced', (select unit_price = 40 and addons_total = 7 and discount_pct = 0 from orders where id = (:'o1'::json ->> 'id')::uuid) as ok;
-- H7 building discount: vendor sets 20% for one building
select vendor_discount_set(:'tk', :'s1', 20);
select place_order(:'s1', :'i1', 2, 'Kofi', '0240004705', 'REFH71', array['Spicy wings','Shito'], null, null, false, null) as o2 \gset
select 'H7 discounted at that building', (select unit_price = 32 and addons_total = 5.6 and discount_pct = 20 and (addons -> 0 ->> 'was')::numeric in (2, 5) from orders where id = (:'o2'::json ->> 'id')::uuid) as ok;
select 'H7b order total uses the discount', (select order_total(o) - max_fee * qty - service_fee * (case when fee_per_meal then qty else 1 end) = (32 + 5.6) * 2 from orders o where id = (:'o2'::json ->> 'id')::uuid) as ok;
-- H8 another building pays full price
select place_order(:'s2', :'i1', 1, 'Esi', '0240004706', 'REFH81', array['Regular chicken'], null, null, false, null) as o3 \gset
select 'H8 other buildings full price', (select unit_price = 40 and addons_total = 0 and discount_pct = 0 from orders where id = (:'o3'::json ->> 'id')::uuid) as ok;
-- H9 an extra plate on a discounted order gets the discount
select place_order(:'s1', :'i1', 1, 'Kofi', '0240004705', 'REFH91', array['Regular chicken'], null, null, false, (:'o2'::json ->> 'id')::uuid) as o4 \gset
select 'H9 added plate discounted', (select unit_price = 32 and discount_pct = 20 from orders where id = (:'o4'::json ->> 'id')::uuid) as ok;
-- H10 limits, and only through the vendor link
do $$ begin begin perform vendor_discount_set(current_setting('t.tk'), current_setting('t.s1')::uuid, 60); raise notice 'H10 FAIL 60%%';
  exception when others then raise notice 'H10 ok: %', sqlerrm; end;
  begin perform vendor_discount_set('nope', current_setting('t.s1')::uuid, 10); raise notice 'H10b FAIL bad token';
  exception when others then raise notice 'H10b ok bad link refused'; end; end $$;
set request.jwt.claims = ''; set role anon;
do $$ begin begin insert into kitchen_discounts (kitchen_id, site_id, pct) select id, current_setting('t.s1')::uuid, 50 from kitchens limit 1; raise notice 'H11 FAIL anon inserted';
  exception when others then raise notice 'H11 ok customers cannot write discounts'; end; end $$;
select 'H12 customers can read discounts', (select count(*) from kitchen_discounts) >= 1 as ok;
select 'H13 vendor sees building list', json_array_length(vendor_discount_sites(:'tk')) >= 2 as ok;
reset role;
select kitchen_view(:'tk', current_order_date()) as kv \gset
select 'H14 vendor page: discounts and menu order', (:'kv'::json -> 'kitchen' -> 'discounts' -> 0 ->> 'pct')::int = 20 and (select min(i) filter (where e ->> 'id' = :'i2') < min(i) filter (where e ->> 'id' = :'i1') from json_array_elements(:'kv'::json -> 'menu') with ordinality t(e, i)) as ok;
-- H15 removing the discount: next order full price, earlier orders keep theirs
select vendor_discount_set(:'tk', :'s1', 0);
select place_order(:'s1', :'i1', 1, 'Yaw', '0240004707', 'REFH151', array['Regular chicken'], null, null, false, null) as o5 \gset
select 'H15 removed', (select unit_price = 40 from orders where id = (:'o5'::json ->> 'id')::uuid) and (select unit_price = 32 from orders where id = (:'o2'::json ->> 'id')::uuid) as ok;
-- H16 a choice switched off is not required; all off = no choice needed
update menu_items set addons = '[{"name":"Regular chicken","price":0,"group":"Choose your protein","off":true}]' where id = :'i1';
select place_order(:'s1', :'i1', 1, 'Yaw', '0240004708', 'REFH161', '{}', null, null, false, null) is not null as h16 \gset
select 'H16 no live options, no choice needed', :'h16'::boolean as ok;
-- H17 a new paid option waits for approval and is not required meanwhile
select vendor_set_menu(:'tk', jsonb_build_array(jsonb_build_object('id', :'i1', 'name', (select name from menu_items where id = :'i1'), 'price', 40,
  'addons', '[{"name":"Fish","price":10,"group":"Pick a side"}]'::jsonb)));
select 'H17 new paid option pending', (select (addons -> 0 ->> 'pending')::boolean and addons -> 0 ->> 'group' = 'Pick a side' from menu_items where id = :'i1')
  and exists (select 1 from price_requests where item_id = :'i1' and kind = 'new_extra' and status = 'pending') as ok;
select place_order(:'s1', :'i1', 1, 'Yaw', '0240004709', 'REFH171', '{}', null, null, false, null) is not null as h17b \gset
select 'H17b pending option not required', :'h17b'::boolean as ok;
rollback;
