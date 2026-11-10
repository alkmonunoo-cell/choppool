\pset tuples_only on
begin;
update settings set cutoff = '23:59', max_meals = 30 where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select id as i2 from menu_items where kitchen_id = :'k1' and active order by name desc limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
-- J: add several dishes to an existing code, one payment
select place_order(:'s1', :'i1', 1, 'Ama', '0240000011', 'REF-J0', '{}', null, null, false, null) as a \gset
select (:'a'::json ->> 'id') as aid \gset
update orders set status = 'paid' where id = :'aid';
set role anon;
select place_basket(:'s1', jsonb_build_array(jsonb_build_object('item', :'i1', 'qty', 2), jsonb_build_object('item', :'i2', 'qty', 1)), 'Ama', '0240000011', 'REF-J1', false, null, null, :'aid'::uuid) as b \gset
reset role;
select (:'b'::json ->> 'id') as payer \gset
select 'J1 dishes join the same code', count(*) = 2 and bool_and(parent_id = :'aid'::uuid) and bool_and(code = (select code from orders where id = :'aid')) as ok from orders where parent_id = :'aid';
select 'J2 one payment: ref on the first new dish only', (select momo_ref from orders where id = :'payer') = 'REF-J1' and (select count(*) from orders where parent_id = :'aid' and momo_ref is not null) = 1 as ok;
select 'J3 no delivery charged again', bool_and(max_fee = 0) as ok from orders where parent_id = :'aid';
update orders set status = 'paid' where id = :'payer';
select 'J4 payment confirmed: the other dish follows', bool_and(status = 'paid') as ok from orders where parent_id = :'aid';
-- payment not received: siblings cancelled too
set role anon;
select place_basket(:'s1', jsonb_build_array(jsonb_build_object('item', :'i1', 'qty', 1), jsonb_build_object('item', :'i2', 'qty', 1)), 'Ama', '0240000011', 'REF-J2', false, null, null, :'aid'::uuid) as c \gset
reset role;
select (:'c'::json ->> 'id') as payer2 \gset
update orders set status = 'cancelled', cancel_reason = 'Payment not received' where id = :'payer2';
select 'J5 unpaid: dishes paid with it are cancelled too', count(*) = 2 as ok from orders where parent_id = :'aid' and status = 'cancelled' and cancel_reason = 'Payment not received';
select 'J6 earlier dishes untouched', count(*) = 2 as ok from orders where parent_id = :'aid' and status = 'paid';
-- other vendor refused
select id as kother from kitchens where active and id <> :'k1' limit 1 \gset
select id as iother from menu_items where kitchen_id = :'kother' limit 1 \gset
savepoint v; select place_basket(:'s1', jsonb_build_array(jsonb_build_object('item', :'iother', 'qty', 1)), 'Ama', '0240000011', 'REF-J3', false, null, null, :'aid'::uuid); rollback to savepoint v;
select 'J7 other vendor can''t join this code', not exists (select 1 from orders where momo_ref = 'REF-J3') as ok;
-- new tray still works (no p_join)
select place_basket(:'s1', jsonb_build_array(jsonb_build_object('item', :'i1', 'qty', 1), jsonb_build_object('item', :'i2', 'qty', 1)), 'Kofi', '0200000022', 'REF-T1') as t \gset
update orders set status = 'paid' where id = (:'t'::json ->> 'id')::uuid;
select 'J8 normal tray still follows its first dish', bool_and(status = 'paid') as ok from orders where id = (:'t'::json ->> 'id')::uuid or parent_id = (:'t'::json ->> 'id')::uuid;
-- F: automatic days need the current fee accepted
update kitchens set auto_days = array[1,2,3,4,5,6,7] where id = :'k1';
delete from kitchen_days where kitchen_id = :'k1';
select 'F1 auto day open when fee terms are accepted', kitchen_is_open(:'k1', current_order_date() + 1) as ok;
update settings set vendor_fee_rate = 0.05 where id = 1;
select 'F2 raising the fee pauses automatic days until accepted', not kitchen_is_open(:'k1', current_order_date() + 1) as ok;
select kitchen_accept_terms(:'tk');
select 'F3 after accepting, automatic days open again', kitchen_is_open(:'k1', current_order_date() + 1) as ok;
-- R: rider sign-up
set role anon;
savepoint r1; select rider_apply('Yaw Mensah', '0244001122', 'Honda', 'Osu', '0244001122', 'GHA-12345', 'DL12345', current_date + 100); rollback to savepoint r1;
savepoint r2; select rider_apply('Yaw Mensah', '0244001122', 'Honda', 'Osu', '0244001122', 'GHA-123456789-0', 'DL12345', current_date - 1); rollback to savepoint r2;
select rider_apply('Yaw Mensah', '0244001122', 'Honda', 'Osu', '0244001122', 'gha 123456789 0', 'dl-123 45', current_date + 100);
savepoint r3; select rider_apply('Yaw M', '0244001133', 'Honda', 'Osu', '0244001133', 'GHA-123456789-0', 'DL99999', current_date + 100); rollback to savepoint r3;
reset role;
select 'R1 rider saved with Ghana Card in standard form', ghana_card = 'GHA-123456789-0' and licence_no = 'DL-123 45' and licence_expiry > current_date as ok from riders where phone = '0244001122';
select 'R2 bad card / expired licence / same card refused', (select count(*) from riders where phone in ('0244001133')) = 0 as ok;
set role anon;
savepoint r4; select ghana_card from riders; rollback to savepoint r4;
reset role;
-- B: buildings go live
set role anon;
select request_site('Kofi Annan Towers, Airport', 'Front desk', 5.6050, -0.1800, null, null) as ns \gset
select request_site('kofi annan towers, airport', 'Lobby', 5.6060, -0.1810, null, null) as ns2 \gset
reset role;
select 'B1 new building is live straight away', status = 'active' as ok from sites where id = (:'ns'::json ->> 'id')::uuid;
select 'B2 same name again reuses it (no copy)', (:'ns2'::json ->> 'id') = (:'ns'::json ->> 'id') and (:'ns2'::json ->> 'joined')::boolean as ok;
rollback;
begin;
set role anon;
select count(*) as n from riders \gset
reset role;
select 'R3 riders (with Ghana Card) hidden from the public', :n = 0 as ok;
rollback;
