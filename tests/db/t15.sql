\set ON_ERROR_STOP 1
begin;
update settings set cutoff = '23:59', special_cutoff = '23:58', accept_timeout_min = 20 where id = 1;
select current_order_date() as d \gset
select id as s1 from sites where name like 'Heritage%' \gset
select k.id as k1 from kitchens k where k.active order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active limit 1 \gset
delete from kitchen_days where kitchen_id = :'k1'; update kitchens set auto_days = '{}' where id = :'k1';
set role authenticated;
set request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333","email":"cust@x.com"}';
select place_order(:'s1', :'i1', 1, 'Ama', '0241111111', 'REF1234') ->> 'id' as oa \gset
reset role;
set request.jwt.claims = '{}'; set role anon;
select place_order(:'s1', :'i1', 1, 'Guest', '0242222222', 'REF2234') ->> 'id' as og \gset
reset role;
update orders set status = 'paid' where id in (:'oa', :'og');
update pools set created_at = now() - interval '30 minutes' where id = (select pool_id from orders where id = :'oa');
select housekeeping();
select 'after', customer_name, status, refund_due, refund_needed from orders where id in (:'oa', :'og') order by customer_name;
select 'wallet', wallet_balance('33333333-3333-3333-3333-333333333333');
set role authenticated;
set request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444","email":"guest@x.com"}';
select 'claim', claim_orders(array[:'og'::uuid]);
reset role;
select 'guest wallet', wallet_balance('44444444-4444-4444-4444-444444444444'), (select refund_needed from orders where id = :'og');
select housekeeping(); select 'again', wallet_balance('44444444-4444-4444-4444-444444444444'), wallet_balance('33333333-3333-3333-3333-333333333333');
rollback;
