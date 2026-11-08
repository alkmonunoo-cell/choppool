\set ON_ERROR_STOP 0
\pset tuples_only on
begin;
update settings set cutoff = '23:59', special_cutoff = '23:00', max_meals = 30 where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select id as i2 from menu_items where kitchen_id = :'k1' and active order by name desc limit 1 \gset
select kitchen_accept_terms(:'tk');
select current_order_date() as d \gset
-- P: wallet covers only part of a tray: every dish waits for the payment check
insert into wallet_entries(user_id, amount, reason) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 10, 'test credit');
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","email":"ama@x.com"}'; set role authenticated;
select place_basket(:'s1', jsonb_build_array(jsonb_build_object('item', :'i1', 'qty', 1), jsonb_build_object('item', :'i2', 'qty', 1)), 'Ama', '0240000011', 'REF-P1', true) as b \gset
reset role;
select (:'b'::json ->> 'id') as bm \gset
select 'P1 partly wallet: all dishes pending', bool_and(status = 'pending') as ok from orders where id = :'bm' or parent_id = :'bm';
select 'P2 wallet still applied', (select sum(wallet_used) from orders where id = :'bm' or parent_id = :'bm') = 10 as ok;
-- S: vendor not cooking while customers wait
select 'S1 pool is waiting', status = 'waiting' as ok from pools where id = (select pool_id from orders where id = :'bm');
update orders set status = 'paid' where id = :'bm';
set request.jwt.claims = ''; select place_order(:'s1', :'i1', 1, 'Kofi', '0201234567', 'REF-K1', '{}', null, null, false, null) as g \gset
select (:'g'::json ->> 'id') as gid \gset
update orders set status = 'paid' where id = :'gid';
set role anon; select kitchen_skip_day(:'tk', :'d'); reset role;
select 'S2 all waiting orders cancelled', bool_and(status = 'cancelled' and cancel_reason = 'The vendor isn''t cooking today') as ok from orders where pool_id = (select pool_id from orders where id = :'bm');
select 'S3 account holder money back in wallet', (select sum(amount) from wallet_entries where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' and reason like 'Money back:%') = (select sum(order_total(o) - o.wallet_used) from orders o where o.id = :'bm' or o.parent_id = :'bm') and exists (select 1 from wallet_entries where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' and amount = 10 and reason like 'Refund:%') as ok;
select 'S4 guest flagged for mobile money refund', refund_needed and refund_due > 0 as ok from orders where id = :'gid';
select 'S5 day paused', :'d'::date = any(paused_dates) as ok from kitchens where id = :'k1';
select 'S6 board says off', (board_data(:'d') -> 'off')::jsonb ? :'k1' as ok;
savepoint a;
select place_order(:'s1', :'i1', 1, 'Esi', '0551234567', 'REF-E1', '{}', null, null, false, null);
rollback to savepoint a;
select 'S7 paused day refuses new orders', not exists (select 1 from orders where customer_name = 'Esi') as ok;
select 'S8 skip twice is harmless', (kitchen_skip_day(:'tk', :'d') ->> 'orders')::int = 0 as ok;
savepoint b; select kitchen_skip_day('nope', :'d'); rollback to savepoint b;
-- confirmed day with orders: skip refused
select kitchen_open_day(:'tk', :'d');
select 'S9 confirming lifts the pause', not (:'d'::date = any(paused_dates)) as ok from kitchens where id = :'k1';
select place_order(:'s1', :'i1', 1, 'Yaw', '0261234567', 'REF-Y1', '{}', null, null, false, null) as y \gset
savepoint c; select kitchen_skip_day(:'tk', :'d'); rollback to savepoint c;
select 'S10 skip refused once confirmed with orders', exists (select 1 from orders where id = (:'y'::json ->> 'id')::uuid and status <> 'cancelled') as ok;
-- H: handover moves the pool to delivered
update orders set status = 'paid' where id = (:'y'::json ->> 'id')::uuid;
update pools set status = 'ready' where id = (select pool_id from orders where id = (:'y'::json ->> 'id')::uuid);
select host_token as ht from sites where id = :'s1' \gset
set role anon; select collect_code(:'ht', (:'y'::json ->> 'code'), :'d'); reset role;
select 'H1 handover marks bag delivered', status = 'delivered' and delivered_at is not null as ok from pools where id = (select pool_id from orders where id = (:'y'::json ->> 'id')::uuid);
select 'H2 order collected', status = 'collected' as ok from orders where id = (:'y'::json ->> 'id')::uuid;
rollback;
begin;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
update settings set cutoff = '23:59' where id = 1;
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
select place_order(:'s1', :'i1', 1, 'Abena', '0209998887', 'REF-A9', '{}', null, null, false, null) as a \gset
update pools set status = 'accepted' where id = (select pool_id from orders where id = (:'a'::json ->> 'id')::uuid);
savepoint z; select cancel_order((:'a'::json ->> 'id')::uuid, 'x', null); rollback to savepoint z;
select 'C1 no cancel once cooking', status = 'pending' as ok from orders where id = (:'a'::json ->> 'id')::uuid;
rollback;
