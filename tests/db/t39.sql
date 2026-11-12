\pset tuples_only on
begin;
insert into admins (email, role) values ('co@x.com', 'coordinator') on conflict (email) do update set role = excluded.role;
insert into notifications (user_id, title) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Hi');
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","email":"ama@x.com"}'; set role authenticated;
do $$ begin begin perform bell_status(); raise notice 'B1 FAIL'; exception when others then raise notice 'B1 ok customers cannot'; end; end $$;
set request.jwt.claims = '{"sub":"dddddddd-dddd-dddd-dddd-dddddddddddd","email":"co@x.com"}';
select 'B2 team sees last alert', (bell_status() ->> 'today')::int = 1 and bell_status() ->> 'last_at' is not null as ok;
reset role; rollback;
