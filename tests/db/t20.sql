\set ON_ERROR_STOP 0
\pset tuples_only on
begin;
update settings set cutoff = '23:59', special_cutoff = '23:00', max_meals = 30, trip_max = 80 where id = 1;
select id as s1, lat as slat from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer order by name limit 1 \gset
select k.id as k2, k.token as tk2 from kitchens k where k.active and not k.added_by_customer and k.id <> :'k1' order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active limit 1 \gset
select id as i2 from menu_items where kitchen_id = :'k2' and active limit 1 \gset
select kitchen_accept_terms(:'tk'), kitchen_accept_terms(:'tk2');
select kitchen_open_day(:'tk', current_order_date()), kitchen_open_day(:'tk2', current_order_date());

-- Ama (account) orders 1 meal: pays the full trip
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","email":"ama@x.com"}'; set role authenticated;
select place_order(:'s1', :'i1', 1, 'Ama', '0240000011', 'REF-A1') ->> 'id' as a1 \gset
reset role;
select 'P1 solo pays full trip', o.max_fee = pool_trip(o.pool_id) as ok, o.max_fee, pool_trip(o.pool_id) from orders o where id = :'a1';
-- Kofi orders 2 meals in the same pool
set request.jwt.claims = '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","email":"kofi@x.com"}'; set role authenticated;
select place_order(:'s1', :'i1', 2, 'Kofi', '0240000022', 'REF-K1') ->> 'id' as b1 \gset
reset role;
select 'P2 two meals pay the trip once', abs(o.max_fee * o.qty - pool_trip(o.pool_id)) <= 1 as ok, o.max_fee * o.qty from orders o where id = :'b1';
update orders set status = 'paid' where id in (:'a1', :'b1');
-- close orders
update settings set cutoff = '00:00' where id = 1;
select housekeeping();
select 'C1 no cashback before received', wallet_balance('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') = 0 as ok;
select 'C2 pending shown', ((select my_wallet() from (select set_config('request.jwt.claims','{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}', true)) z) ->> 'pending')::numeric > 0 as ok;
-- delivered + collected + Ama confirms
update pools set status = 'delivered', delivered_at = now() where id = (select pool_id from orders where id = :'a1');
update orders set status = 'collected', collected_at = now() where id in (:'a1', :'b1');
select set_config('request.jwt.claims','{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}', true);
select confirm_received(:'a1');
select 'C3 cashback posted once fixed', wallet_balance('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') as bal, (select count(*) from wallet_entries where order_id = :'a1') = 1 as ok;
select wallet_balance('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') as bal_before \gset
-- Kofi reports a problem: no cashback until resolved
select set_config('request.jwt.claims','{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}', true);
select report_problem(:'b1', 'One plate missing');
select housekeeping();
select 'C4 problem pauses cashback', wallet_balance('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') = 0 as ok;
-- later change to the pool doesn't move Ama's balance
update orders set status = 'cancelled' where id = :'b1';
select housekeeping();
select 'C5 balance never changes after posting', wallet_balance('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') = :bal_before as ok;
-- forward-only steps
select kitchen_update(:'tk', (select pool_id from orders where id = :'a1'), 'ready'); select 'F1 cannot go back', status from pools where id = (select pool_id from orders where id = :'a1');
rollback;

begin;
update settings set cutoff = '23:59', special_cutoff = '23:00', quote_pay_min = 15 where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer order by name limit 1 \gset
select k.id as k2 from kitchens k where k.active and not k.added_by_customer and k.id <> :'k1' order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active limit 1 \gset
select id as i2 from menu_items where kitchen_id = :'k2' and active order by price desc limit 1 \gset
select kitchen_accept_terms(token), kitchen_open_day(token, current_order_date()) from kitchens where id in (:'k1', :'k2');
set request.jwt.claims = '{}'; set role anon;
-- special order: priced, window set, expires
select place_order(:'s1', :'i1', 1, 'Esi', '0240000033', null, null, null, 'Extra pepper, no fish') ->> 'id' as q1 \gset
reset role;
select kitchen_quote(:'tk', :'q1', 70);
select 'Q1 pay window set', quote_pay_by between now() + interval '14 minutes' and now() + interval '16 minutes' as ok from orders where id = :'q1';
update orders set quote_pay_by = now() - interval '1 minute' where id = :'q1';
select housekeeping();
select 'Q2 unpaid special released', status = 'cancelled' and cancel_reason in ('Special request not paid in time', 'Custom order not paid in time') as ok from orders where id = :'q1';
-- switch a guest order to another vendor's pool
set role anon;
select place_order(:'s1', :'i1', 1, 'Yaw', '0240000044', 'REF-Y1') ->> 'id' as g1 \gset
reset role; update orders set status = 'paid' where id = :'g1';
set role anon;
select switch_order(:'g1', :'s1', :'i2', 1, null, null, 'REF-Y2') as sw \gset
reset role;
select 'S1 old order moved', status = 'cancelled' and cancel_reason = 'Moved to another pool' as ok from orders where id = :'g1';
select 'S2 new order carries payment', carried_amount > 0 and kitchen_id = :'k2' as ok, status, carried_amount, order_total(o) from orders o where moved_from = :'g1';
-- unpaid limit: 3 pending per phone
set role anon;
select place_order(:'s1', :'i1', 1, 'Spam', '0249999999', 'X1000001'), place_order(:'s1', :'i1', 1, 'Spam', '0249999999', 'X2000002'), place_order(:'s1', :'i1', 1, 'Spam', '0249999999', 'X3000003') \gset
savepoint z; select place_order(:'s1', :'i1', 1, 'Spam', '0249999999', 'X4000004'); rollback to z;
select record_unmatched('Spam', '0249999999', 50, 'X4REF', 'Too many pending');
reset role;
select 'U1 unmatched kept', count(*) = 1 as ok from unmatched_payments where momo_ref = 'X4REF';
-- coordinator action is logged
insert into admins(email, role) values ('coord@x.com', 'coordinator') on conflict (email) do update set role = 'coordinator';
set request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","email":"coord@x.com"}'; set role authenticated;
update orders set status = 'paid' where id = (select id from orders where phone = '0249999999' limit 1);
select 'D1 dues ok', admin_dues(current_date - 7, current_date) is not null as ok;
reset role;
select 'L1 logged', count(*) >= 1 as ok from activity_log where actor = 'coord@x.com' and entity = 'orders';
select 'M1 my_orders new cols', count(*) > 0 as ok from my_orders(array[:'g1'::uuid]);
rollback;
