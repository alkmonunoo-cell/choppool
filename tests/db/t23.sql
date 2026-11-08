\set ON_ERROR_STOP 0
\pset tuples_only on
begin;
update settings set cutoff = '23:59', special_cutoff = '23:00', max_meals = 30, next_day_confirm_by = '08:30', accept_timeout_min = 20 where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select id as i2 from menu_items where kitchen_id = :'k1' and active order by name desc limit 1 \gset
select k.id as k2 from kitchens k where k.active and not k.added_by_customer and k.id <> :'k1' order by name limit 1 \gset
select id as j1 from menu_items where kitchen_id = :'k2' and active limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
-- wait window
select 'W1 same-day before 8:30 waits until 8:30', wait_deadline((current_date + time '07:00') at time zone 'utc', current_date) = (current_date + time '08:30') at time zone 'utc' as ok;
select 'W2 same-day after 8:30 gets 20 min', wait_deadline((current_date + time '09:00') at time zone 'utc', current_date) = (current_date + time '09:20') at time zone 'utc' as ok;
update settings set cutoff = '10:30' where id = 1;
select 'W3 never past cut-off', wait_deadline((current_date + time '10:20') at time zone 'utc', current_date) = (current_date + time '10:30') at time zone 'utc' as ok;
select 'W4 next day until 8:30', wait_deadline((current_date + time '19:00') at time zone 'utc', current_date + 1) = (current_date + 1 + time '08:30') at time zone 'utc' as ok;
update settings set cutoff = '23:59' where id = 1;
-- basket as signed-in customer with wallet credit
insert into wallet_entries(user_id, amount, reason) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 30, 'test credit');
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","email":"ama@x.com"}'; set role authenticated;
select place_basket(:'s1', jsonb_build_array(jsonb_build_object('item', :'i1', 'qty', 2), jsonb_build_object('item', :'i2', 'qty', 1, 'note', 'no pepper')), 'Ama', '0240000011', 'REF-B123', true, '0240000011', 'MTN') as b \gset
reset role;
select (:'b'::json ->> 'id') as bm \gset
select 'B1 one code for all dishes', count(distinct code) = 1 and count(*) = 2 as ok from orders where id = :'bm' or parent_id = :'bm';
select 'B2 one payment ref on the first dish only', (select momo_ref from orders where id = :'bm') = 'REF-B123' and (select count(*) from orders where parent_id = :'bm' and momo_ref is not null) = 0 as ok;
select 'B3 wallet used once', (select sum(amount) from wallet_entries where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') = 0 and (select sum(wallet_used) from orders where id = :'bm' or parent_id = :'bm') = 30 as ok;
select 'B4 total = sum of dishes', (:'b'::json ->> 'total')::numeric = (select sum(order_total(o)) from orders o where id = :'bm' or parent_id = :'bm') as ok;
select 'B5 extra dish marked as tray', bool_and(basket) as ok from orders where parent_id = :'bm';
select 'B6 payer saved', payer_phone = '0240000011' and payer_network = 'MTN' as ok from orders where id = :'bm';
-- admin marks the first dish paid -> the tray follows
update orders set status = 'paid' where id = :'bm';
select 'B7 tray paid together', bool_and(status = 'paid') as ok from orders where id = :'bm' or parent_id = :'bm';
-- unpaid basket gets cancelled together
set request.jwt.claims = '{}'; set role anon;
select place_basket(:'s1', jsonb_build_array(jsonb_build_object('item', :'i1', 'qty', 1), jsonb_build_object('item', :'i2', 'qty', 1)), 'Kofi', '0240000022', 'REF-B999') ->> 'id' as cm \gset
reset role;
update orders set pay_issue = 'not_found' where id = :'cm';
update settings set cutoff = '00:00' where id = 1; select housekeeping(); update settings set cutoff = '23:59' where id = 1;
select 'B8 unpaid tray cancelled together', bool_and(status = 'cancelled') as ok from orders where id = :'cm' or parent_id = :'cm';
-- guards
set request.jwt.claims = '{}'; set role anon;
savepoint a; select place_basket(:'s1', jsonb_build_array(jsonb_build_object('item', :'i1', 'qty', 1), jsonb_build_object('item', :'j1', 'qty', 1)), 'Esi', '0240000033', 'REF-B555'); rollback to savepoint a;
savepoint b2; select place_basket(:'s1', jsonb_build_array(jsonb_build_object('item', :'i1', 'qty', 1)), 'Esi', '0240000033', null); rollback to savepoint b2;
savepoint c; select place_basket(:'s1', '[]'::jsonb, 'Esi', '0240000033', 'REF-B555'); rollback to savepoint c;
reset role;
select 'B9 nothing left behind by refused trays', count(*) = 0 as ok from orders where phone = '0240000033';
-- cancel with own words
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'; set role authenticated;
select cancel_order(:'bm', 'Other: my meeting moved to the afternoon and I will be out of the office for lunch today', 'wallet');
reset role;
select 'C1 long reason kept', cancel_reason like '%out of the office for lunch today)' as ok from orders where id = :'bm';
select 'C2 tray cancelled with it', bool_and(status = 'cancelled') as ok from orders where parent_id = :'bm';
rollback;
begin;
select 'P1 profiles keep payment methods', exists (select 1 from information_schema.columns where table_name = 'profiles' and column_name = 'pay_methods') as ok;
set request.jwt.claims = '{"sub":"eeeeeeee-dddd-dddd-dddd-dddddddddddd","email":"nobody@x.com"}'; set role authenticated;
select 'A1 non-admin gets no alert reach', cardinality(admin_alert_reach(array(select id from orders limit 5))) = 0 as ok;
reset role;
select 'M1 message says mobile money', prosrc like '%mobile money transaction ID%' as ok from pg_proc where proname = 'settle_payment';
rollback;
