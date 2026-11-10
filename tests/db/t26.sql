\pset tuples_only on
begin;
update settings set cutoff = '23:59' where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select kitchen_accept_terms(:'tk');
insert into wallet_entries(user_id, amount, reason) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 20, 'test credit');
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","email":"ama@x.com"}'; set role authenticated;
select place_order(:'s1', :'i1', 3, 'Ama', '0240000011', 'REF-R1', '{}', null, null, true, null) as a \gset
reset role;
select (:'a'::json ->> 'id') as aid \gset
-- R1 pending: refused
set role authenticated;
savepoint x; select reduce_plates(:'aid'::uuid, 1, 'test'); rollback to savepoint x;
reset role;
select 'R1 waiting payment cannot be reduced', qty = 3 as ok from orders where id = :'aid';
update orders set status = 'paid' where id = :'aid';
select order_total(o) as tot0, max_fee * qty as dlv0, wallet_used as wu0, unit_price + addons_total + case when fee_per_meal then service_fee else 0 end as per from orders o where id = :'aid' \gset
select coalesce(sum(amount), 0) as bal0 from wallet_entries where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' \gset
set role authenticated;
select reduce_plates(:'aid'::uuid, 1, 'too much food') as r \gset
reset role;
select 'R2 qty 3 -> 2', qty = 2 as ok from orders where id = :'aid';
select 'R3 delivery kept (full trip still paid)', abs(max_fee * qty - :dlv0) < 0.01 as ok from orders where id = :'aid';
select 'R4 refund = one plate (food + service fee)', abs((:'r'::json ->> 'wallet_credit')::numeric - :per) < 0.01 as ok;
select 'R5 wallet credited by that amount', abs((select sum(amount) from wallet_entries where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') - :bal0 - :per) < 0.01 as ok;
select 'R6 order total drops by exactly that', abs(order_total(o) - (:tot0 - :per)) < 0.01 as ok from orders o where id = :'aid';
select 'R7 wallet used comes back first', wallet_used = greatest(0, :wu0 - :per) as ok from orders where id = :'aid';
set role authenticated;
savepoint y; select reduce_plates(:'aid'::uuid, 2, null); rollback to savepoint y;
savepoint z; select reduce_plates(:'aid'::uuid, 0, null); rollback to savepoint z;
reset role;
select 'R8 cannot remove all or zero (cancel instead)', qty = 2 as ok from orders where id = :'aid';
-- someone else's order
set request.jwt.claims = '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","email":"x@x.com"}'; set role authenticated;
savepoint w; select reduce_plates(:'aid'::uuid, 1, null); rollback to savepoint w;
reset role;
select 'R9 another account cannot reduce it', qty = 2 as ok from orders where id = :'aid';
-- guest paid by mobile money: refund flagged for ChopPool to send
set request.jwt.claims = ''; 
select place_order(:'s1', :'i1', 4, 'Kofi', '0201234567', 'REF-G1', '{}', null, null, false, null) as g \gset
select (:'g'::json ->> 'id') as gid \gset
update orders set status = 'paid' where id = :'gid';
set role anon; select reduce_plates(:'gid'::uuid, 2, null) as rg \gset
reset role;
select 'R10 guest: refund to send by mobile money', refund_needed and abs(refund_due - 2 * (unit_price + addons_total + case when fee_per_meal then service_fee else 0 end)) < 0.01 and qty = 2 as ok from orders where id = :'gid';
set role anon; select reduce_plates(:'gid'::uuid, 1, null); reset role;
select 'R11 a second removal adds to the refund', abs(refund_due - 3 * (unit_price + addons_total + case when fee_per_meal then service_fee else 0 end)) < 0.01 and qty = 1 as ok from orders where id = :'gid';
-- after cooking starts: refused
update orders set status = 'paid' where id = :'aid';
update pools set status = 'accepted' where id = (select pool_id from orders where id = :'aid');
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","email":"ama@x.com"}'; set role authenticated;
savepoint v; select reduce_plates(:'aid'::uuid, 1, null); rollback to savepoint v;
reset role;
select 'R12 no changes once cooking', qty = 2 as ok from orders where id = :'aid';
rollback;
