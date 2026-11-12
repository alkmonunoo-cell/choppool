\pset tuples_only on
begin;
select k.id as kid, k.token as tk from kitchens k where k.active limit 1 \gset
insert into notifications (user_id, title, created_at) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Payment confirmed', now()), ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Old one', now() - interval '8 days'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Kofi only', now()), (null, 'Guest order alert', now());
update notifications set order_id = '11111111-1111-4111-8111-111111111111' where title = 'Guest order alert';
insert into notifications (kitchen_id, title) values (:'kid', 'New pool');
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'; set role authenticated;
select 'N1 Ama sees her recent alert only', (select string_agg(title, ',') from my_notifications()) = 'Payment confirmed' as ok;
select 'N2 cannot read the table directly', (select count(*) from (select 1) z) = 1 as ok;
do $$ begin begin perform count(*) from notifications; raise notice 'N3 FAIL'; exception when others then raise notice 'N3 ok no direct read'; end; end $$;
select 'N4 mark read', read_notifications() = 1 as ok;
select 'N5 read time kept', (select read_at is not null from my_notifications()) as ok;
set request.jwt.claims = '{}'; set role anon;
select 'N6 guest sees the alert for their order', (select string_agg(title, ',') from my_notifications(array['11111111-1111-4111-8111-111111111111']::uuid[])) = 'Guest order alert' as ok;
select 'N7 guest without order ids sees nothing', (select count(*) from my_notifications()) = 0 as ok;
select 'N8 vendor by link', (select string_agg(title, ',') from my_notifications('{}', 'vendor', :'tk')) = 'New pool' as ok;
select 'N9 bad link: nothing', (select count(*) from my_notifications('{}', 'vendor', 'nope')) = 0 as ok;
do $$ begin begin perform prune_notifications(); raise notice 'N10 FAIL'; exception when others then raise notice 'N10 ok prune is server-only'; end; end $$;
reset role;
select 'N11 prune removes 8-day-old', prune_notifications() = 1 as ok;
rollback;
