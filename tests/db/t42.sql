\pset tuples_only on
begin;
update settings set cutoff = '23:59' where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer and k.lat is not null order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
update menu_items set price = 20, addons = '[]' where id = :'i1';
create temp table tv as select :'s1'::uuid as s1, :'i1'::uuid as i1; grant select on tv to authenticated;
insert into admins (email, role) values ('boss@x.com', 'super') on conflict (email) do update set role = excluded.role;
-- P1 off by default
set request.jwt.claims = '{"sub":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","email":"u1@x.com"}'; set role authenticated;
do $$ begin begin perform place_order((select s1 from tv), (select i1 from tv), 1, 'Ama', '0240000911', 'PAYSTACK', null, null, null, false, null);
  raise notice 'P1 FAIL'; exception when others then raise notice 'P1 ok off by default: %', sqlerrm; end; end $$;
reset role;
-- P2 team only: customers refused, team allowed
update settings set pay_mode = 'team' where id = 1;
set role authenticated;
do $$ begin begin perform place_order((select s1 from tv), (select i1 from tv), 1, 'Ama', '0240000911', 'PAYSTACK', null, null, null, false, null);
  raise notice 'P2a FAIL'; exception when others then raise notice 'P2a ok customer refused in team mode: %', sqlerrm; end; end $$;
reset role; set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com"}'; set role authenticated;
select (place_order(:'s1', :'i1', 1, 'Boss', '0240000912', 'PAYSTACK', null, null, null, false, null) ->> 'id') as ob \gset
reset role;
select 'P2b team member can pay online', (select status = 'pending' and pay_via = 'paystack' and momo_ref is null from orders where id = :'ob') as ok;
-- P3 everyone: a tray of two dishes, one payment
update settings set pay_mode = 'paystack' where id = 1;
set request.jwt.claims = '{"sub":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","email":"u1@x.com"}'; set role authenticated;
select (place_basket(:'s1', jsonb_build_array(jsonb_build_object('item', :'i1', 'qty', 2), jsonb_build_object('item', :'i1', 'qty', 1, 'note', 'no pepper')), 'Ama', '0240000911', 'PAYSTACK', false, null, null, null) ->> 'id') as ot \gset
reset role;
select 'P3 tray waits as paying online', (select status = 'pending' and pay_via = 'paystack' and momo_ref is null from orders where id = :'ot')
  and (select count(*) from orders where parent_id = :'ot' and basket and status = 'pending') = 1 as ok;
select 'P4 amount covers the whole tray', pay_group_due(:'ot') = (select sum(order_total(o)) from orders o where o.id = :'ot' or (o.parent_id = :'ot' and o.basket)) and pay_group_due(:'ot') > 0 as ok;
select round(pay_group_due(:'ot'), 2) as otdue \gset
set request.jwt.claims = '{"sub":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","email":"u1@x.com"}'; set role authenticated;
select 'P4b my unpaid online orders lists the tray once', (select count(*) from my_unpaid_online()) = 1 and (select amount from my_unpaid_online()) = (:'otdue')::numeric as ok;
reset role; set request.jwt.claims = '{"sub":"ffffffff-ffff-ffff-ffff-ffffffffffff"}'; set role authenticated;
select 'P4c nobody else sees them', (select count(*) from my_unpaid_online()) = 0 as ok;
reset role; set request.jwt.claims = '{"sub":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","email":"u1@x.com"}';
select 'P5 check: owner gets the amount, others refused', (paystack_check_order(:'ot', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee') ->> 'amount')::numeric = pay_group_due(:'ot')
  and paystack_check_order(:'ot', 'ffffffff-ffff-ffff-ffff-ffffffffffff') ->> 'error' is not null as ok;
set role authenticated;
do $$ begin begin perform paystack_settle('X', 1, 'card'); raise notice 'P6 FAIL'; exception when insufficient_privilege then raise notice 'P6 ok customers cannot mark payments'; end; end $$;
do $$ begin begin perform pay_group_due(gen_random_uuid()); raise notice 'P6b FAIL'; exception when insufficient_privilege then raise notice 'P6b ok'; end; end $$;
reset role;
insert into paystack_payments (reference, order_id, user_id, amount) values ('R1', :'ot', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', pay_group_due(:'ot'));
select paystack_settle('R1', (select amount from paystack_payments where reference = 'R1'), 'mobile_money');
select 'P7 confirmed payment marks the tray paid', (select status = 'paid' and momo_ref = 'PSK:R1' from orders where id = :'ot')
  and (select bool_and(status = 'paid') from orders where parent_id = :'ot' and basket) as ok;
select paystack_settle('R1', 999, 'card') ->> 'result' as r1b \gset
select 'P8 second confirmation does nothing', :'r1b' = 'paid'
  and (select count(*) from wallet_entries where user_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' and amount > 0) = 0 as ok;
-- P9 wallet first, the rest online
insert into wallet_entries (user_id, amount, reason) values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 5, 'Test credit');
set role authenticated;
select (place_order(:'s1', :'i1', 1, 'Ama', '0240000911', 'PAYSTACK', null, null, null, true, null) ->> 'id') as ow \gset
reset role;
select 'P9 wallet used first, rest online', (select wallet_used = 5 and pay_via = 'paystack' from orders where id = :'ow') and pay_group_due(:'ow') = (select order_total(o) - 5 from orders o where id = :'ow') as ok;
-- P10 short payment never marks paid; money kept in wallet
insert into paystack_payments (reference, order_id, user_id, amount) values ('R2', :'ow', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', pay_group_due(:'ow'));
select paystack_settle('R2', 1, 'card') ->> 'result' as r2 \gset
select 'P10 short amount goes to wallet, order not paid', :'r2' = 'credited'
  and (select status = 'pending' from orders where id = :'ow')
  and exists (select 1 from wallet_entries where order_id = :'ow' and amount = 1 and reason like 'Money back: online payment%') as ok;
-- P11 payment arriving after the order was cancelled goes to the wallet
update orders set status = 'cancelled', cancel_reason = 'Cancelled by customer' where id = :'ow';
insert into paystack_payments (reference, order_id, user_id, amount) values ('R3', :'ow', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 10);
select paystack_settle('R3', 10, 'mobile_money') ->> 'result' as r3 \gset
select 'P11 late payment is credited', :'r3' = 'credited'
  and (select count(*) from wallet_entries where order_id = :'ow' and reason like 'Money back: online payment%') = 2 as ok;
select 'P12 check refuses closed orders', paystack_check_order(:'ow', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee') ->> 'error' is not null as ok;
-- P13 unpaid online orders close at cut-off; the wallet part comes back
set role authenticated;
select (place_order(:'s1', :'i1', 1, 'Ama', '0240000911', 'PAYSTACK', null, null, null, true, null) ->> 'id') as ox \gset
reset role;
select wallet_used as oxw from orders where id = :'ox' \gset
update orders set order_date = current_date - 1 where id = :'ox' or parent_id = :'ox';
select housekeeping();
select 'P13 unpaid online order closed at cut-off', (select status = 'cancelled' and cancel_reason = 'Payment not received' from orders where id = :'ox') as ok;
select 'P14 its wallet part came back', (:'oxw')::numeric = 0 or exists (select 1 from wallet_entries where order_id = :'ox' and amount = (:'oxw')::numeric and reason like 'Refund:%') as ok;
-- P15 manual orders are untouched
set role authenticated;
select (place_order(:'s1', :'i1', 1, 'Ama', '0240000911', 'REFMAN42', null, null, null, false, null) ->> 'id') as om \gset
reset role;
select 'P15 MoMo reference orders work as before', (select momo_ref = 'REFMAN42' and pay_via is null and status = 'pending' from orders where id = :'om') as ok;
select 'P16 a paid online order with its paid record is not expired', (select status = 'paid' from orders where id = :'ot') as ok;
rollback;
