\set ON_ERROR_STOP 1
begin;
update settings set cutoff = '23:59', special_cutoff = '23:58', vendor_fee_rate = 0.05, vendor_fee_free = 5, max_meals = 30 where id = 1;
select id as s1, lat as slat, lng as slng from sites where name like 'Heritage%' \gset
select k.id as k1 from kitchens k where k.active order by name limit 1 \gset
select id as i1, price as p1 from menu_items where kitchen_id = :'k1' and active limit 1 \gset
select 'order date', current_order_date(), extract(isodow from current_order_date());
-- vendor at ~300 m from the building, free within 800 m from 1 meal
update kitchens set lat = :slat + 0.0027, lng = :'slng', free_m = 800, free_min = 0, fee_ack = 0, fee_free_ack = 5 where id = :'k1';
select 'terms block', (select count(*) from kitchens where id=:'k1');
do $$ begin perform kitchen_open_day((select token from kitchens order by name limit 1), current_order_date()); raise notice 'should have failed'; exception when others then raise notice 'open_day blocked: %', sqlerrm; end $$;
select kitchen_accept_terms(token) from kitchens where id = :'k1';
select kitchen_open_day(token, current_order_date()) from kitchens where id = :'k1';
set request.jwt.claims = '{}'; set role anon;
select place_order(:'s1', :'i1', 4, 'Ama Mensah', '0241111111', 'REF1234') ->> 'id' as oa \gset
select place_order(:'s1', :'i1', 4, 'Kofi Boateng', '0242222222', 'REF5678') ->> 'id' as ob \gset
reset role;
select pool_id as pl from orders where id = :'oa' \gset
select 'free?', pool_free(:'pl'), 'trip', pool_trip(:'pl'), 'max_fee charged', (select max_fee from orders where id=:'oa');
select 'pool terms', fee_rate, fee_free from pools where id = :'pl';
update orders set status = 'paid' where id in (:'oa', :'ob');
select 'fee', pool_fee(:'pl'), 'expected', round(0.05 * :p1 * 8 * 3 / 8, 2);
-- payment issue flow
update orders set status = 'pending', pay_issue = 'not_found' where id = :'ob';
set role anon;
do $$ begin perform fix_payment(current_setting('x.ob', true)::uuid, '0249999999', 'ABC12345'); exception when others then raise notice 'wrong phone: %', sqlerrm; end $$;
select fix_payment(:'ob', '024 222 2222', 'NEWREF999');
reset role;
select 'fixed', status, pay_issue, momo_ref from orders where id = :'ob';
update orders set pay_issue = 'short', amount_received = 20 where id = :'ob';
set role anon; select fix_payment(:'ob', '0242222222', 'TOPUP7777'); reset role;
select 'short fixed', momo_ref, pay_issue from orders where id = :'ob';
update orders set pay_issue = 'short', amount_received = 20 where id = :'ob';
update settings set cutoff = '00:00' where id = 1;
select housekeeping();
select 'after cutoff', status, cancel_reason, refund_due, refund_needed from orders where id = :'ob';
select 'mine', pay_issue, amount_received, vendor_delivers from my_orders(array[:'oa'::uuid]);
update settings set cutoff = '23:59' where id = 1;
-- next-day deadline
select 'deadline today', wait_deadline(now(), (now() at time zone 'utc')::date) - now() < interval '21 minutes';
select 'deadline tomorrow', wait_deadline(now(), (now() at time zone 'utc')::date + 1);
-- waitlist
set role anon;
select request_site('Ridge Towers', 'Main gate', 5.60, -0.18, null, 'https://push.test/a');
select request_site('ridge  towers', 'Gate', 5.6001, -0.1801, null, 'https://push.test/b');
select request_site('Other Place', 'Gate', 5.6005, -0.1800, null, null);
reset role;
select 'waiters', count(*) from site_waiters;
select id as r1 from sites where name = 'Ridge Towers' \gset
select admin_merge_sites(:'r1', :'s1') is not null as merge_needs_admin_check;
rollback;
