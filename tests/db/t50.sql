\pset tuples_only on
begin;
update settings set paystack_fee_from = null where id = 1;
update settings set cutoff = '23:59' where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer and k.lat is not null and k.delivery_mode <> 'runner' order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
update menu_items set price = 40, addons = '[]' where id = :'i1';
insert into admins (email, role) values ('boss@x.com', 'super') on conflict (email) do update set role = excluded.role;
set request.jwt.claims = '{"sub":"e1e1e1e1-0000-0000-0000-000000005001","email":"a@x.com"}'; set role authenticated;
select (place_order(:'s1', :'i1', 1, 'Ama', '0240005001', 'MP50000001', null, null, null, false, null) ->> 'id') as o1 \gset
reset role;
set request.jwt.claims = '{"sub":"e1e1e1e1-0000-0000-0000-000000005002","email":"b@x.com"}'; set role authenticated;
select (place_order(:'s1', :'i1', 1, 'Kofi', '0240005002', 'MP50000002', null, null, null, false, null) ->> 'id') as o2 \gset
reset role;
update orders set status = 'paid' where id in (:'o1', :'o2');
select order_cashback(:'o1') as cb1 \gset
select order_cashback(:'o2') as cb2 \gset
select set_config('request.jwt.claims', '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com"}', false);
set role authenticated;
select admin_money_days(current_order_date(), current_order_date()) -> 'days' -> 0 as d \gset
reset role;
select 'R1 cashback still due is counted', abs((:'d'::json ->> 'cashback')::numeric - (:'cb1'::numeric + :'cb2'::numeric)) < 0.01 and (:'cb1'::numeric + :'cb2'::numeric) > 0 and (:'d'::json ->> 'cashback_estimated')::int = 2 as ok;
-- post o1's cashback as the app does: counted once, from the wallet line
insert into wallet_entries (user_id, amount, reason, order_id) values ('e1e1e1e1-0000-0000-0000-000000005001', :'cb1', 'Delivery cashback, code X', :'o1');
update orders set cashback_posted = true where id = :'o1';
-- problem credit, hand credit, Paystack payment
insert into wallet_entries (user_id, amount, reason, order_id) values ('e1e1e1e1-0000-0000-0000-000000005002', 6, 'Sorted: cold food', :'o2');
insert into wallet_entries (user_id, amount, reason, created_by) values ('e1e1e1e1-0000-0000-0000-000000005002', 4, 'Goodwill', 'boss@x.com');
insert into paystack_payments (reference, order_id, user_id, amount, status, amount_paid) values ('ref50', :'o2', 'e1e1e1e1-0000-0000-0000-000000005002', 100, 'paid', 100);
set role authenticated;
select admin_money_days(current_order_date(), current_order_date()) -> 'days' -> 0 as d2 \gset
reset role;
select 'R2 posted + still due, no double count', abs((:'d2'::json ->> 'cashback')::numeric - (:'cb1'::numeric + :'cb2'::numeric)) < 0.01 and (:'d2'::json ->> 'cashback_estimated')::int = 1 as ok;
select 'R3 credits given (problem + by hand)', (:'d2'::json ->> 'credits')::numeric = 10 as ok;
select 'R4 Paystack fee 1.95%', (:'d2'::json ->> 'paystack_fees')::numeric = 1.95 as ok;
select 'R5 other columns unchanged', (:'d2'::json ->> 'received')::numeric > 80 and (:'d2'::json ->> 'orders')::int = 2 as ok;
rollback;
