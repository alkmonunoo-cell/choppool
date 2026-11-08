\set ON_ERROR_STOP 1
begin;
select id as s1 from sites where name like 'Heritage%' \gset
set role anon;
select request_site('Ridge Towers', 'Main gate', 5.60, -0.18, null, 'https://push.test/a') ->> 'id' as r1 \gset
reset role;
insert into admins (email) values ('boss@test.gh') on conflict do nothing; select 'boss@test.gh' as em \gset
select set_config('request.jwt.claims', json_build_object('email', :'em', 'sub', gen_random_uuid())::text, true);
set role authenticated;
select admin_merge_sites(:'r1', :'s1');
select count(*) as waiters_on_target from site_waiters where site_id = :'s1';
reset role;
select archived, status, request_note from sites where id = :'r1';
rollback;
