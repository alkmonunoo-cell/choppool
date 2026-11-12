\pset tuples_only on
begin;
select k.token as tk from kitchens k where k.active limit 1 \gset
select r.token as rt from riders r where r.active limit 1 \gset
insert into admins (email, role) values ('boss@x.com', 'super') on conflict do nothing;
-- guest
set request.jwt.claims = '{}'; set role anon;
select 'F1 guest can send', send_feedback('problem', 'Map is slow', 'customer:home', 'iPhone', 'web', '{}', 'Esi', '0240000000') is not null as ok;
select 'F2 guest cannot read feedback', (select count(*) from feedback) = 0 as ok;
do $$ begin begin insert into feedback (role, kind, message) values ('guest','idea','direct'); raise notice 'F3 FAIL'; exception when others then raise notice 'F3 ok'; end; end $$;
select 'F4 bad kind refused', (select count(*) = 0 from (select 1) z where false) as ok;
do $$ begin begin perform send_feedback('rant', 'x x'); raise notice 'F4b FAIL'; exception when others then raise notice 'F4b ok kind'; end; end $$;
do $$ begin begin perform send_feedback('idea', 'hi', null, null, null, array['../secret.png']); raise notice 'F5 FAIL'; exception when others then raise notice 'F5 ok bad image path'; end; end $$;
do $$ begin begin perform send_feedback('idea', 'hi', null, null, null, array['fb/11111111-1111-4111-8111-111111111111/a.webp','fb/11111111-1111-4111-8111-111111111111/b.webp','fb/11111111-1111-4111-8111-111111111111/c.webp','fb/11111111-1111-4111-8111-111111111111/d.webp']); raise notice 'F6 FAIL'; exception when others then raise notice 'F6 ok max 3'; end; end $$;
select 'F7 vendor by link', send_feedback('idea', 'More pool sizes', null, null, null, array['fb/11111111-1111-4111-8111-111111111111/1.webp'], null, null, 'vendor', :'tk') is not null as ok;
do $$ begin begin perform send_feedback('idea', 'hi', null, null, null, '{}', null, null, 'vendor', 'nope'); raise notice 'F8 FAIL'; exception when others then raise notice 'F8 ok bad vendor link'; end; end $$;
select 'F9 rider by link', send_feedback('problem', 'Map did not load', null, null, null, '{}', null, null, 'rider', :'rt') is not null as ok;
do $$ begin begin perform send_feedback('idea', 'hi', null, null, null, '{}', null, null, 'team'); raise notice 'F10 FAIL'; exception when others then raise notice 'F10 ok team needs sign-in'; end; end $$;
-- signed-in customer
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","email":"ama@x.com"}'; set role authenticated;
select 'F11 customer can send', send_feedback('other', 'Love it', 'customer:account') is not null as ok;
select 'F12 customer cannot read', (select count(*) from feedback) = 0 as ok;
update feedback set status = 'done';
-- team
set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com"}';
select 'F13 team reads all', (select count(*) from feedback) = 4 as ok;
select 'F14 customer update had no effect', (select count(*) from feedback where status = 'done') = 0 as ok;
select 'F15 roles recorded', (select string_agg(role, ',' order by role) from feedback) = 'customer,guest,rider,vendor' as ok;
select 'F16 user linked', (select user_id from feedback where role = 'customer') = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' as ok;
update feedback set status = 'done', team_note = 'fixed' where role = 'guest';
select 'F17 team can update', (select status from feedback where role = 'guest') = 'done' as ok;
select send_feedback('idea', 'Note to self', null, null, null, '{}', null, null, 'team') as tid \gset
select 'F18 team can send as team', (select role from feedback where id = :'tid') = 'team' as ok;
-- spam guard
reset role; set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'; set role authenticated;
do $$ declare i int; begin for i in 1..9 loop perform send_feedback('idea', 'again ' || i); end loop;
  begin perform send_feedback('idea', 'eleventh'); raise notice 'F19 FAIL'; exception when others then raise notice 'F19 ok rate limit'; end; end $$;
reset role;
rollback;
