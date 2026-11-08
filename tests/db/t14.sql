\set ON_ERROR_STOP 1
begin;
update settings set cap_km = 8, max_fee = 10, base_fare = 20, per_km = 6, service_fee = 2, accept_timeout_min = 20, cutoff = '23:59', special_cutoff = '23:58' where id = 1;
select current_order_date() as d \gset
select 'fee', fee_for(1, 50) a, fee_for(1, 200) b, fee_for(15, 200) c, fee_for(15, 50) dd, fee_for(0, 200) e;
select id as s1 from sites where name like 'Heritage%' \gset
select k.id as k1, k.token as kt from kitchens k where k.active order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active limit 1 \gset
delete from kitchen_days where kitchen_id = :'k1';
update kitchens set auto_days = '{}', paused_dates = '{}' where id = :'k1';
set role anon;
select place_order(:'s1', :'i1', 2, 'Ama', '0241111111', 'REF1234') ->> 'id' as oa \gset
select place_order(:'s1', :'i1', 1, 'Kofi', '0242222222', 'REF2234') ->> 'id' as ob \gset
reset role;
select 'waiting pool', o.code, p.status, p.seq, pool_meals(p.id), o.max_fee, o.fee_per_meal, order_total(o) from orders o join pools p on p.id = o.pool_id where o.id in (:'oa', :'ob');
set role anon;
select set_config('x.oa', :'oa', false);
reset role;
do $$ begin perform place_order(null, (select item_id from orders where id = current_setting('x.oa')::uuid), 1, 'X', '0249999999', 'REF', '{}', null, null, false, current_setting('x.oa')::uuid); exception when others then raise notice 'refused: %', sqlerrm; end $$;
set role anon;
select place_order(null, :'i1', 1, 'Ama', '0241111111', 'REF3234', '{}', null, null, false, :'oa'::uuid) ->> 'code' as childcode;
reset role;
select 'after child', code, qty, max_fee, parent_id is not null as child, status, order_total(o) from orders o where o.id = :'oa' or o.parent_id = :'oa' order by created_at;
select 'my_orders', code, amount_due, saving, parent_id is not null from my_orders(array[:'oa'::uuid]);
set role anon;
select kitchen_open_day(:'kt', :'d');
reset role;
select 'pool now', status from pools where id = (select pool_id from orders where id = :'oa');
update orders set status = 'paid' where pool_id = (select pool_id from orders where id = :'oa');
select 'cashback', order_cashback(:'oa'), order_cashback(:'ob'), pool_trip((select pool_id from orders where id = :'oa'));
-- codes
select 'codes ok', bool_and(code ~ '^[A-Z]-[0-9]{2}$') from orders where order_date = :'d' and fee_per_meal;
-- collect with host token: lower-case, no dash
select host_token as ht from sites where id = :'s1' \gset
update pools set status = 'delivered' where id = (select pool_id from orders where id = :'oa');
select lower(replace(code, '-', '')) as typed from orders where id = :'oa' \gset
set role anon;
select 'collect', collect_code(:'ht', :'typed', :'d');
reset role;
select 'collected', count(*) from orders where code = (select code from orders where id = :'oa') and status = 'collected';
-- many codes in one pool: no look-alikes
create temp table cs as select new_code(:'s1', :'d', (select pool_id from orders where id = :'ob')) c from generate_series(1, 30);
select 'distinct codes', count(distinct c), count(*) from cs;
-- auto days + pause
update kitchens set auto_days = array[extract(isodow from :'d'::date)::int] where id = :'k1';
delete from kitchen_days where kitchen_id = :'k1';
select 'auto open', kitchen_is_open(:'k1', :'d');
select k.id as k2, k.token as kt2 from kitchens k where k.active and k.id <> :'k1' limit 1 \gset
set role anon;
select kitchen_set_auto(:'kt2', array[1,2,3,4,5]);
select kitchen_pause(:'kt2', :'d', true);
reset role;
select 'k2 paused open?', kitchen_is_open(:'k2', :'d'), auto_days, paused_dates from kitchens where id = :'k2';
-- cancel parent with child (new order today in open pool)
set role anon;
select place_order(:'s1', :'i1', 1, 'Esi', '0243333333', 'REF4234') ->> 'id' as oc \gset
select place_order(null, :'i1', 1, 'Esi', '0243333333', 'REF5234', '{}', null, null, false, :'oc'::uuid) ->> 'id' as occ \gset
select 'cancel', cancel_order(:'oc', 'test', 'momo');
reset role;
select 'cancelled both', count(*) from orders where (id = :'oc' or parent_id = :'oc') and status = 'cancelled';
select 'board', json_array_length(board_data(:'d') -> 'pools'), board_data(:'d') -> 'open';
select 'vendor add', (add_vendor(:'s1', 'Far Away Kenkey', '0245555555', '[{"name":"Kenkey","price":20}]'::jsonb, 5.75, -0.2) ->> 'name');
select 'far pin', lat, lng from kitchens where name = 'Far Away Kenkey';
select 'kitchen_view', (kitchen_view(:'kt', :'d') -> 'kitchen') ->> 'auto_days', json_array_length(kitchen_view(:'kt', :'d') -> 'pools');
select 'menu set', vendor_set_menu((select token from kitchens where name = 'Far Away Kenkey'), '[{"name":"Kenkey and fish","price":35,"addons":[{"name":"Extra fish","price":10},{"name":"x","price":1}]}]'::jsonb);
select 'menu', name, price, addons from menu_items where kitchen_id = (select id from kitchens where name = 'Far Away Kenkey') order by name;
-- report as owner
insert into admins (email, role) values ('owner@x.com', 'super') on conflict do nothing;
set role authenticated;
set request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","email":"owner@x.com"}';
select 'report', left(admin_weekly_report(date_trunc('week', :'d'::date)::date)::text, 600);
reset role;
rollback;
