\pset tuples_only on
begin;
insert into admins(email, role) values ('own@x.com', 'super') on conflict (email) do update set role = 'super';
set request.jwt.claims = '{"sub":"dddddddd-dddd-dddd-dddd-dddddddddddd","email":"own@x.com"}'; set role authenticated;
select 'R1 report has pending cashback', (admin_weekly_report(date_trunc('week', now())::date) -> 'money')::jsonb ? 'cashback_pending' as ok;
reset role;
set request.jwt.claims = '{"sub":"eeeeeeee-dddd-dddd-dddd-dddddddddddd","email":"nobody@x.com"}'; set role authenticated;
select 'R2 non-admin money hidden', (admin_weekly_report(date_trunc('week', now())::date) -> 'money') is null or json_typeof(admin_weekly_report(date_trunc('week', now())::date) -> 'money') = 'null' as ok;
reset role;
rollback;
