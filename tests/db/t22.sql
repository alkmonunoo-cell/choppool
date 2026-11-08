\set ON_ERROR_STOP 0
\pset tuples_only on
begin;
update settings set cutoff = '23:59', special_cutoff = '23:00', max_meals = 30, trip_max = 80, auto_receive_min = 120 where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","email":"ama@x.com"}'; set role authenticated;
select place_order(:'s1', :'i1', 1, 'Ama', '0240000011', 'REF-R1') ->> 'id' as a1 \gset
reset role;
set request.jwt.claims = '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","email":"kofi@x.com"}'; set role authenticated;
select place_order(:'s1', :'i1', 2, 'Kofi', '0240000022', 'REF-R2') ->> 'id' as b1 \gset
reset role;
update orders set status = 'paid' where id in (:'a1', :'b1');
select pool_id as pl from orders where id = :'a1' \gset
update settings set cutoff = '00:00' where id = 1;
-- before delivery: not allowed
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'; set role authenticated;
savepoint s; select confirm_received(:'a1'); rollback to savepoint s;
reset role;
select 'R1 cannot confirm before Delivered', received_at is null and status = 'paid' as ok from orders where id = :'a1';
-- rider taps Delivered
update pools set status = 'delivered', delivered_at = now() where id = :'pl';
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'; set role authenticated;
select confirm_received(:'a1');
reset role;
select 'R2 Got my food without a code check', status = 'collected' and received_at is not null and collected_by = 'customer' as ok from orders where id = :'a1';
select 'R3 cashback posted on receipt', cashback_posted as ok from orders where id = :'a1';
-- someone else can't confirm Kofi's order
set request.jwt.claims = '{"sub":"cccccccc-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'; set role authenticated;
savepoint s2; select confirm_received(:'b1'); rollback to savepoint s2;
reset role;
select 'R4 stranger cannot confirm', received_at is null as ok from orders where id = :'b1';
-- code check still works for Kofi, Ama's code now says already collected
set role anon;
savepoint s3; select collect_code(:'tk', (select code from orders where id = :'a1'), current_order_date(), null, 'cash'); rollback to savepoint s3;
reset role;
-- 2 hours later Kofi's order confirms itself
update pools set delivered_at = now() - interval '121 minutes' where id = :'pl';
select housekeeping();
select 'R5 auto-received after 2 hours', status = 'collected' and received_at is not null and collected_by = 'auto' and cashback_posted as ok from orders where id = :'b1';
select 'R6 balance', wallet_balance('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') > 0 as ok;
rollback;
