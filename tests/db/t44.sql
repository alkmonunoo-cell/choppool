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

update settings set pay_mode = 'paystack' where id = 1;
insert into wallet_entries (user_id, amount, reason) values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 5, 'Test credit');
set request.jwt.claims = '{"sub":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","email":"u1@x.com"}'; set role authenticated;
-- W1 an online order never paid: cancelling refunds nothing (only the wallet part comes back)
select (place_order(:'s1', :'i1', 1, 'Ama', '0240000911', 'PAYSTACK', null, null, null, true, null) ->> 'id') as o1 \gset
select cancel_order(:'o1', 'Changed my plans', 'momo') ->> 'refund' as r1 \gset
reset role;
select 'W1 unpaid online order: nothing to refund', :'r1' = 'nothing' and (select not refund_needed and status = 'cancelled' from orders where id = :'o1') as ok;
select 'W2 its wallet part came back', exists (select 1 from wallet_entries where order_id = :'o1' and amount = 5 and reason like 'Refund:%') as ok;
-- W3 a MoMo transfer order still being checked: refund still flagged (money may have been sent)
set role authenticated;
select (place_order(:'s1', :'i1', 1, 'Ama', '0240000911', 'REFW344', null, null, null, false, null) ->> 'id') as o3 \gset
select cancel_order(:'o3', 'Changed my plans', 'wallet') ->> 'refund' as r3 \gset
reset role;
select 'W3 MoMo order being checked: refund still flagged', :'r3' = 'momo' and (select refund_needed from orders where id = :'o3') as ok;
-- W4 a tray paid by MoMo transfer: the second dish is still refunded with the first
set role authenticated;
select (place_basket(:'s1', jsonb_build_array(jsonb_build_object('item', :'i1', 'qty', 1), jsonb_build_object('item', :'i1', 'qty', 1, 'note', 'x')), 'Ama', '0240000911', 'REFW344B', false, null, null, null) ->> 'id') as o4 \gset
select cancel_order(:'o4', 'Changed my plans', 'wallet') ->> 'refund' as r4 \gset
reset role;
select 'W4 tray paid by MoMo: both dishes flagged for refund', :'r4' = 'momo' and (select bool_and(refund_needed) from orders where id = :'o4' or (parent_id = :'o4' and basket)) as ok;
-- W5 a paid online order cancelled: refund to wallet or mobile money as chosen
set role authenticated;
select (place_order(:'s1', :'i1', 1, 'Ama', '0240000911', 'PAYSTACK', null, null, null, false, null) ->> 'id') as o5 \gset
reset role;
insert into paystack_payments (reference, order_id, user_id, amount) values ('RW5', :'o5', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', pay_group_due(:'o5'));
select paystack_settle('RW5', (select amount from paystack_payments where reference = 'RW5'), 'mobile_money') ->> 'result' as s5 \gset
set role authenticated;
select cancel_order(:'o5', 'Changed my plans', 'momo') ->> 'refund' as r5 \gset
reset role;
select 'W5 paid online order: refund as chosen', :'s5' = 'paid' and :'r5' = 'momo' and (select refund_needed from orders where id = :'o5') as ok;
-- W6-W9 wallet changes need a fresh password
set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com","amr":[{"method":"password","timestamp":1000}]}'; set role authenticated;
do $$ begin begin insert into wallet_entries (user_id, amount, reason, created_by) values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 10, 'Goodwill', 'coordinator'); raise notice 'W6 FAIL old sign-in allowed';
  exception when others then raise notice 'W6 ok old sign-in refused: %', sqlerrm; end; end $$;
reset role;
select set_config('request.jwt.claims', json_build_object('sub','cccccccc-cccc-cccc-cccc-cccccccccccc','email','boss@x.com','amr', json_build_array(json_build_object('method','password','timestamp', extract(epoch from now())::bigint - 30)))::text, false);
set role authenticated;
insert into wallet_entries (user_id, amount, reason, created_by) values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 10, 'Goodwill W7', 'coordinator');
reset role;
select 'W7 password entered just now: allowed', exists (select 1 from wallet_entries where reason = 'Goodwill W7') as ok;
set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com","amr":[{"method":"otp","timestamp":9999999999}]}'; set role authenticated;
do $$ begin begin insert into wallet_entries (user_id, amount, reason, created_by) values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 10, 'x', 'coordinator'); raise notice 'W8 FAIL code sign-in allowed';
  exception when others then raise notice 'W8 ok signed in with a code, no password: refused'; end; end $$;
reset role;
set request.jwt.claims = '{"sub":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","email":"u1@x.com","amr":[{"method":"password","timestamp":1000}]}'; set role authenticated;
select (place_order(:'s1', :'i1', 1, 'Ama', '0240000911', 'PAYSTACK', null, null, null, true, null) ->> 'id') as o9 \gset
select cancel_order(:'o9', 'Changed my plans', 'wallet') ->> 'refund' as r9 \gset
reset role;
select 'W9 refunds the database makes itself still work with an old sign-in', exists (select 1 from wallet_entries where order_id = :'o9' and reason like 'Refund:%') as ok;
rollback;
