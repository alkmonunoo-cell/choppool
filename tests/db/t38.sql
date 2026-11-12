\pset tuples_only on
begin;
update settings set cutoff = '23:59' where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer and k.lat is not null order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
update menu_items set addons = '[{"name":"Fish","price":15},{"name":"Fish","price":20},{"name":"Fish","price":30.5},{"name":"Fried eggs","price":4}]' where id = :'i1';
select place_order(:'s1', :'i1', 2, 'Ama', '0240000201', 'REFXB1', array['Fried eggs'], null, null, false, null) as o1 \gset
select place_order(:'s1', :'i1', 1, 'Kofi', '0240000202', 'REFXB2', '{}', null, null, false, null) as o2 \gset
select place_order(:'s1', :'i1', 1, 'Esi', '0240000203', 'REFXB3', '{}', null, null, false, null) as o3 \gset
update orders set status = 'paid' where id in ((:'o1'::json ->> 'id')::uuid, (:'o2'::json ->> 'id')::uuid);
update orders set user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' where id = (:'o1'::json ->> 'id')::uuid;
insert into wallet_entries (user_id, amount, reason, order_id) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 2.5, 'Delivery cashback, code X', (:'o1'::json ->> 'id')::uuid);
insert into payouts (payee_type, kitchen_id, amount) values ('seller', :'k1', 40);
insert into admins (email, role) values ('boss@x.com', 'super'), ('co@x.com', 'coordinator') on conflict (email) do update set role = excluded.role;
select sum(order_total(o)) as rec, sum((coalesce(quote_price, unit_price) + addons_total) * qty) as food, sum(service_fee * case when fee_per_meal then qty else 1 end) as svc, sum(max_fee * qty) as din
  from orders o where id in ((:'o1'::json ->> 'id')::uuid, (:'o2'::json ->> 'id')::uuid) \gset
select coalesce(trip_cost, pool_trip(id)) as trip, pool_fee(id) as vfee from pools where id = (select pool_id from orders where id = (:'o1'::json ->> 'id')::uuid) \gset
set request.jwt.claims = '{"sub":"dddddddd-dddd-dddd-dddd-dddddddddddd","email":"co@x.com"}'; set role authenticated;
do $$ begin begin perform admin_money_days(current_date, current_date); raise notice 'M1 FAIL'; exception when others then raise notice 'M1 ok coordinators cannot see it'; end; end $$;
reset role; set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com"}'; set role authenticated;
select admin_money_days(current_order_date() - 1, current_order_date() + 1) as r \gset
reset role;
select 'M2 one day row', json_array_length((:'r'::json) -> 'days') = 1 as ok;
select 'M3 orders and meals (unpaid left out)', ((:'r'::json) -> 'days' -> 0 ->> 'orders')::int = 2 and ((:'r'::json) -> 'days' -> 0 ->> 'meals')::int = 3 as ok;
select 'M4 received', ((:'r'::json) -> 'days' -> 0 ->> 'received')::numeric = round(:rec, 2) as ok;
select 'M5 food and service', ((:'r'::json) -> 'days' -> 0 ->> 'food')::numeric = round(:food, 2) and ((:'r'::json) -> 'days' -> 0 ->> 'service')::numeric = round(:svc, 2) as ok;
select 'M6 delivery and cashback', ((:'r'::json) -> 'days' -> 0 ->> 'trips_apps')::numeric + ((:'r'::json) -> 'days' -> 0 ->> 'trips_riders')::numeric = round(:trip, 2)
   and ((:'r'::json) -> 'days' -> 0 ->> 'cashback')::numeric = 2.5 and ((:'r'::json) -> 'days' -> 0 ->> 'delivery_in')::numeric = round(:din, 2) as ok;
select 'M7 vendor payout on the day', ((:'r'::json) -> 'days' -> 0 ->> 'paid_vendors')::numeric = 40 as ok;
select 'M8 vendor summary', ((:'r'::json) -> 'vendors' -> 0 ->> 'earned')::numeric = round(:food - :vfee, 2) and ((:'r'::json) -> 'vendors' -> 0 ->> 'paid')::numeric = 40 as ok;
rollback;
