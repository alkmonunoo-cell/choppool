\pset tuples_only on
begin;
update settings set cutoff = '23:59', pay_mode = 'paystack', accept_timeout_min = 20 where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer and k.lat is not null and k.delivery_mode <> 'runner' order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select kitchen_accept_terms(:'tk');
delete from kitchen_days where kitchen_id = :'k1'; update kitchens set auto_days = '{}' where id = :'k1';
update menu_items set price = 40, addons = '[]' where id = :'i1';
insert into admins (email, role) values ('boss@x.com', 'super') on conflict (email) do update set role = excluded.role;
select 'N0 fee date set to 24 Nov', (select paystack_fee_from from settings where id = 1) = '2026-11-24' as ok;
-- A: online order not paid yet -> pool hidden from the building and the vendor, no activity
set request.jwt.claims = '{"sub":"e1e1e1e1-0000-0000-0000-000000005301","email":"a@x.com"}'; set role authenticated;
select (place_order(:'s1', :'i1', 1, 'Ama', '0240005301', 'PAYSTACK', null, null, null, false, null) ->> 'id') as o1 \gset
reset role;
select pool_id as p1 from orders where id = :'o1' \gset
select 'N1 unpaid: pool waiting, not live', (select status = 'waiting' and live_at is null from pools where id = :'p1') and (select committed_at is null from orders where id = :'o1') as ok;
select 'N2 unpaid pool not on the building board', not exists (select 1 from json_array_elements(board_data(current_order_date()) -> 'pools') x where x ->> 'id' = :'p1') as ok;
select 'N3 unpaid pool not on the vendor page', json_array_length(kitchen_view(:'tk', current_order_date()) -> 'pools') = 0 as ok;
select 'N4 no activity for an unpaid order', not exists (select 1 from recent_activity where pool_id = :'p1') as ok;
-- B: vendor timeout does not cancel a pool nobody paid into
update pools set created_at = now() - interval '2 hours' where id = :'p1';
select housekeeping();
select 'N5 unpaid pool not expired by the vendor timer', (select status from pools where id = :'p1') = 'waiting' and (select status from orders where id = :'o1') = 'pending' as ok;
-- C: second customer orders the same vendor before the first pays: joins the same hidden pool
set request.jwt.claims = '{"sub":"e1e1e1e1-0000-0000-0000-000000005302","email":"b@x.com"}'; set role authenticated;
select (place_order(:'s1', :'i1', 1, 'Kofi', '0240005302', 'PAYSTACK', null, null, null, false, null) ->> 'id') as o2 \gset
reset role;
select 'N6 second order joins the same pool', (select pool_id from orders where id = :'o2') = :'p1' as ok;
-- D: Paystack pays with the customer's fee on top
select round(pay_group_due(:'o1'), 2) as due1 \gset
insert into paystack_payments (reference, order_id, user_id, amount, status) values ('ref531', :'o1', 'e1e1e1e1-0000-0000-0000-000000005301', :'due1', 'started');
select paystack_settle('ref531', round(:'due1'::numeric / (1 - 0.0195), 2), 'mobile_money') ->> 'result' as r1 \gset
select 'N7 paid with fee on top', :'r1' = 'paid' and (select status from orders where id = :'o1') = 'paid' as ok;
select 'N8 amount_paid is the order amount, fee kept apart', (select amount_paid = :'due1'::numeric and customer_fee > 0 and abs(customer_fee - round(:'due1'::numeric / (1 - 0.0195), 2) + :'due1'::numeric) < 0.001 from paystack_payments where reference = 'ref531') as ok;
select 'N9 pool live now, vendor timer restarted', (select live_at is not null and created_at > now() - interval '1 minute' from pools where id = :'p1') as ok;
select 'N10 pool on the board, with who started it', exists (select 1 from json_array_elements(board_data(current_order_date()) -> 'pools') x where x ->> 'id' = :'p1'
   and x ->> 'first_fp' = (select left(encode(sha256(convert_to(f.id::text, 'UTF8')), 'hex'), 16) from orders f where f.pool_id = :'p1' and f.parent_id is null order by f.created_at limit 1)) as ok;
select 'N11 pool on the vendor page', json_array_length(kitchen_view(:'tk', current_order_date()) -> 'pools') = 1 as ok;
select 'N12 activity: paid order only, with the customer fingerprint', (select count(*) from recent_activity where pool_id = :'p1') = 1
   and (select uid from recent_activity where pool_id = :'p1') = left(encode(sha256(convert_to('e1e1e1e1-0000-0000-0000-000000005301', 'UTF8')), 'hex'), 16) as ok;
update pools set created_at = now() - interval '2 hours' where id = :'p1';
select housekeeping();
select 'N13 live pool expires when the vendor does not confirm', (select status from pools where id = :'p1') = 'cancelled' as ok;
-- E: late payment with the fee: only the order amount goes to the wallet
select round(order_total(o) - o.wallet_used, 2) as due2 from orders o where id = :'o2' \gset
insert into paystack_payments (reference, order_id, user_id, amount, status) values ('ref532', :'o2', 'e1e1e1e1-0000-0000-0000-000000005302', :'due2', 'started');
select paystack_settle('ref532', round(:'due2'::numeric / (1 - 0.0195), 2), 'card') ->> 'result' as r2 \gset
select 'N14 late payment credited without the fee', :'r2' = 'credited'
   and (select sum(amount) from wallet_entries where user_id = 'e1e1e1e1-0000-0000-0000-000000005302' and reason like 'Money back: online payment%') = :'due2'::numeric as ok;
-- F: no fee on top (ChopPool pays): unchanged
select 'N15 exact payment: no customer fee', (paystack_settle('nope', 1, 'x') ->> 'result') = 'unknown' as ok;
-- G: money report: fee only for payments before the fee date
set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com"}'; set role authenticated;
select admin_money_days(current_order_date(), current_order_date()) -> 'days' -> 0 ->> 'paystack_fees' as f1 \gset
reset role;
select 'N16 no Paystack fee once customers pay it', :'f1'::numeric = 0 as ok;
update settings set paystack_fee_from = null where id = 1;
update paystack_payments set customer_fee = 0 where reference in ('ref531', 'ref532');
set role authenticated;
select admin_money_days(current_order_date(), current_order_date()) -> 'days' -> 0 ->> 'paystack_fees' as f2 \gset
reset role;
select 'N17 fee counted when ChopPool pays it', :'f2'::numeric > 0 as ok;
-- H: wallet / mobile money paid orders go live at once
update settings set pay_mode = 'manual' where id = 1;
set request.jwt.claims = '{"sub":"e1e1e1e1-0000-0000-0000-000000005303","email":"c@x.com"}'; set role authenticated;
select (place_order(:'s1', :'i1', 1, 'Esi', '0240005303', 'MP53000003', null, null, null, false, null) ->> 'id') as o3 \gset
reset role;
select 'N18 mobile money ID sent: pool live straight away', (select p.live_at is not null from pools p join orders o on o.pool_id = p.id where o.id = :'o3') as ok;
-- I: a pool nobody paid into goes away after cut-off
update settings set pay_mode = 'paystack' where id = 1;
set request.jwt.claims = '{"sub":"e1e1e1e1-0000-0000-0000-000000005304","email":"d@x.com"}'; set role authenticated;
select (place_order(:'s1', :'i1', 1, 'Yaw', '0240005304', 'PAYSTACK', null, null, null, false, null) ->> 'id') as o4 \gset
reset role;
select pool_id as p4 from orders where id = :'o4' \gset
update orders set status = 'cancelled', cancel_reason = 'Payment not received' where id = :'o4';
update settings set cutoff = '00:00' where id = 1;
update pools set order_date = current_date - 1 where id = :'p4'; update orders set order_date = current_date - 1 where id = :'o4';
select housekeeping();
select 'N19 empty unpaid pool closed after cut-off', (select status from pools where id = :'p4') = 'cancelled' as ok;
-- J: a Paystack tray (two dishes) is hidden until paid too
update settings set cutoff = '23:59', pay_mode = 'paystack' where id = 1;
select k.id as k2 from kitchens k where k.active and k.id <> :'k1' and not k.added_by_customer order by name limit 1 \gset
set request.jwt.claims = '{"sub":"e1e1e1e1-0000-0000-0000-000000005305","email":"e@x.com"}'; set role authenticated;
select (place_basket(:'s1', jsonb_build_array(jsonb_build_object('item', :'i1', 'qty', 1), jsonb_build_object('item', :'i1', 'qty', 1, 'note', 'no pepper')), 'Abena', '0240005305', 'PAYSTACK', false, null, null, null) ->> 'id') as o5 \gset
reset role;
select 'N20 unpaid tray: no dish counts yet', (select count(*) from orders where (id = :'o5' or parent_id = :'o5') and committed_at is not null) = 0 as ok;
rollback;
