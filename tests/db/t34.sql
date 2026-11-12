\pset tuples_only on
begin;
select k.token as tk from kitchens k where k.active limit 1 \gset
select r.token as rt from riders r where r.active limit 1 \gset
insert into admins (email, role) values ('boss@x.com', 'super') on conflict do nothing;
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","email":"Ama@x.com"}'; set role authenticated;
select 'T1 customer has version 1 to accept', tester_terms_due() = 1 as ok;
select 'T2 accept', accept_tester_terms(1, null, null, 'Ama', 'iPhone') as ok;
select 'T3 nothing due after', tester_terms_due() is null as ok;
select 'T4 accepting twice is fine', accept_tester_terms(1) as ok;
do $$ begin begin perform accept_tester_terms(2); raise notice 'T5 FAIL'; exception when others then raise notice 'T5 ok wrong version'; end; end $$;
select 'T6 customer cannot read the list', (select count(*) from tester_acceptances) = 0 as ok;
set request.jwt.claims = '{}'; set role anon;
select 'T7 guest: nothing due (signs in first)', tester_terms_due() is null as ok;
do $$ begin begin perform accept_tester_terms(1); raise notice 'T8 FAIL'; exception when others then raise notice 'T8 ok guest must sign in'; end; end $$;
select 'T9 vendor due', tester_terms_due('vendor', :'tk') = 1 as ok;
select 'T10 vendor accepts', accept_tester_terms(1, 'vendor', :'tk') as ok;
select 'T11 vendor done', tester_terms_due('vendor', :'tk') is null as ok;
select 'T12 bad vendor link: nothing', tester_terms_due('vendor', 'nope') is null as ok;
do $$ begin begin perform accept_tester_terms(1, 'vendor', 'nope'); raise notice 'T13 FAIL'; exception when others then raise notice 'T13 ok'; end; end $$;
select 'T14a rider accepts', accept_tester_terms(1, 'rider', :'rt') as ok;
select 'T14 rider done', tester_terms_due('rider', :'rt') is null as ok;
do $$ begin begin insert into tester_acceptances (role, version) values ('customer', 1); raise notice 'T15 FAIL'; exception when others then raise notice 'T15 ok no direct insert'; end; end $$;
reset role; set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com"}'; set role authenticated;
select 'T16 team sees 3', (select count(*) from tester_acceptances) = 3 as ok;
select 'T17 email lower-cased', (select email from tester_acceptances where role = 'customer') = 'ama@x.com' as ok;
reset role;
update settings set tester_terms_version = 2 where id = 1;
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'; set role authenticated;
select 'T18 new version asks again', tester_terms_due() = 2 as ok;
reset role; update settings set tester_terms_on = false where id = 1; set role authenticated;
select 'T19 switched off: nothing due', tester_terms_due() is null and tester_terms_due('vendor', :'tk') is null as ok;
reset role;
rollback;
