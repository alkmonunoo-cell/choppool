\pset tuples_only on
begin;
update settings set cutoff = '23:59', pay_mode = 'paystack' where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer and k.lat is not null order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
update menu_items set price = 20, addons = '[]' where id = :'i1';
insert into admins (email, role) values ('boss@x.com', 'super') on conflict (email) do update set role = excluded.role;
delete from profiles where user_id in ('e1e1e1e1-0000-0000-0000-000000000001', 'e1e1e1e1-0000-0000-0000-000000000002');
insert into profiles (user_id, email, name, phone) values ('e1e1e1e1-0000-0000-0000-000000000002', 'p2@x.com', 'Kofi', '0550004802') on conflict (user_id) do update set phone = excluded.phone;
-- J1 signed in, no phone anywhere: the order goes through with no phone
set request.jwt.claims = '{"sub":"e1e1e1e1-0000-0000-0000-000000000001","email":"p1@x.com"}'; set role authenticated;
select (place_order(:'s1', :'i1', 1, 'Ama', '', 'PAYSTACK', null, null, null, false, null) ->> 'id') as o1 \gset
-- J6 they can cancel it, J7 and add a plate to it
select (place_order(:'s1', :'i1', 1, 'Ama', '', 'PAYSTACK', null, null, null, false, :'o1') ->> 'id') as o1b \gset
reset role;
select 'J1 no phone needed when signed in', (select phone is null and customer_name = 'Ama' from orders where id = :'o1') as ok;
select 'J7 extra plate on a no-phone order', (select parent_id = :'o1'::uuid from orders where id = :'o1b') as ok;
set request.jwt.claims = '{"sub":"e1e1e1e1-0000-0000-0000-000000000001","email":"p1@x.com"}'; set role authenticated;
select cancel_order(:'o1b', 'test', 'wallet') is not null as c \gset
reset role;
select 'J6 cancel works without a phone', (select status = 'cancelled' from orders where id = :'o1b') as ok;
-- J2 phone taken from the profile
set request.jwt.claims = '{"sub":"e1e1e1e1-0000-0000-0000-000000000002","email":"p2@x.com"}'; set role authenticated;
select (place_order(:'s1', :'i1', 1, 'Kofi', null, 'PAYSTACK', null, null, null, false, null) ->> 'id') as o2 \gset
reset role;
select 'J2 phone filled from the profile', (select phone = '0550004802' from orders where id = :'o2') as ok;
-- J3 not signed in and no phone: refused; J4 not signed in with a phone: still works
set request.jwt.claims = ''; set role anon;
select set_config('t.s1', :'s1', false); select set_config('t.i1', :'i1', false);
do $$ begin begin perform place_order(current_setting('t.s1')::uuid, current_setting('t.i1')::uuid, 1, 'Yaw', '', 'MP1234567', null, null, null, false, null);
  raise notice 'J3 FAIL anon without phone'; exception when others then raise notice 'J3 ok: %', sqlerrm; end; end $$;
select (place_order(:'s1', :'i1', 1, 'Yaw', '024 000 4803', 'MP12345678', null, null, null, false, null) ->> 'id') as o4 \gset
reset role;
select 'J4 phone given still works', (select phone = '0240004803' from orders where id = :'o4') as ok;
-- J5 weekly report counts the no-phone customer
set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com"}'; set role authenticated;
select admin_weekly_report(current_order_date() - extract(isodow from current_order_date())::int + 1) as rp \gset
reset role;
select 'J5 report runs and counts customers', (:'rp'::json -> 'head' -> 'cur' ->> 'customers')::int >= 3
  or exists (select 1 from json_array_elements(:'rp'::json -> 'customers') c where c ->> 'name' = 'Ama') as ok;
select 'J5b top customers include the no-phone one, phone empty', exists (select 1 from json_array_elements(:'rp'::json -> 'customers') c where c ->> 'name' = 'Ama' and c ->> 'phone' is null) as ok;
rollback;
