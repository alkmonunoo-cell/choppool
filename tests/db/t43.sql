\pset tuples_only on
begin;
select 'H1 phone sign-in off by default', (select phone_signin = false from settings where id = 1) as ok;
set role anon;
select 'H2 the app can read the switch', (select count(*) from settings where id = 1 and phone_signin is not null) = 1 as ok;
reset role;
set request.jwt.claims = '{"sub":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","email":"u1@x.com"}'; set role authenticated;
do $$ begin begin update settings set phone_signin = true where id = 1; if (select phone_signin from settings where id = 1) then raise notice 'H3 FAIL customer switched it on'; else raise notice 'H3 ok customers cannot switch it'; end if; exception when others then raise notice 'H3 ok customers cannot switch it'; end; end $$;
reset role;
rollback;
