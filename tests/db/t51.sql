\pset tuples_only on
begin;
update settings set cutoff = '23:59', reports_from = null where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
insert into admins (email, role) values ('boss@x.com', 'super') on conflict (email) do update set role = excluded.role;
select (place_order(:'s1', :'i1', 1, 'Ama', '0240005101', 'MP51000001', null, null, null, false, null) ->> 'id') as o1 \gset
update orders set status = 'paid' where id = :'o1';
select set_config('request.jwt.claims', '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com"}', false);
set role authenticated;
select json_array_length(admin_money_days(current_order_date() - 3, current_order_date()) -> 'days') as n0 \gset
select admin_weekly_report(current_order_date() - extract(isodow from current_order_date())::int + 1) -> 'headline' as h0 \gset
reset role;
update settings set reports_from = current_order_date() + 1 where id = 1;
set role authenticated;
select json_array_length(admin_money_days(current_order_date() - 3, current_order_date()) -> 'days') as n1 \gset
select admin_weekly_report(current_order_date() - extract(isodow from current_order_date())::int + 1) as w1 \gset
reset role;
select 'S1 before: today in the money report', :n0 >= 1 and (:'h0'::json -> 'cur' ->> 'orders')::int >= 1 as ok;
select 'S2 after: days before the start are left out', :n1 = 0 as ok;
select 'S3 weekly report leaves them out too', coalesce((:'w1'::json -> 'headline' -> 'cur' ->> 'orders')::int, 0) = 0 as ok;
update settings set reports_from = current_order_date() where id = 1;
set role authenticated;
select json_array_length(admin_money_days(current_order_date() - 3, current_order_date()) -> 'days') as n2 \gset
reset role;
select 'S4 the start day itself is included', :n2 = 1 as ok;
select 'S5 week start stays the Monday', (:'w1'::json ->> 'week_start')::date = current_order_date() - extract(isodow from current_order_date())::int + 1 as ok;
rollback;
