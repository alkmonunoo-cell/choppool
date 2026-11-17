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

-- F1 only the team can start a vendor form
set request.jwt.claims = '{"sub":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","email":"u1@x.com"}'; set role authenticated;
do $$ begin begin perform admin_vendor_invite('Auntie Akos', '0241112223'); raise notice 'F1 FAIL customer started a form'; exception when others then raise notice 'F1 ok customers cannot start a form'; end; end $$;
reset role; set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com"}'; set role authenticated;
select admin_vendor_invite('Auntie Akos', '024 111 2223') ->> 'token' as vt \gset
reset role;
select id as vk from kitchens where token = :'vt' \gset
select 'F2 draft is hidden from customers', (select not active and setup_status = 'draft' from kitchens where id = :'vk')
  and not exists (select 1 from public_menus where id = :'vk') as ok;
-- F3 the vendor opens the link (no sign-in) and saves part of the form
set request.jwt.claims = ''; set role anon;
select vendor_setup_get(:'vt') ->> 'status' as st0 \gset
select vendor_setup_save(:'vt', '{"name":"Akos Kitchen","tagline":"Jollof and waakye","owner_name":"Akosua Mensah","whatsapp":"0241112223","capacity":"40","auto_days":[1,2,3,4,5]}'::jsonb,
  '[{"name":"Jollof with chicken","price":"45","addons":[{"name":"Egg","price":5},{"name":"Shito","price":0,"off":true}]},{"name":"x","price":"10"},{"name":"No price","price":"0"}]'::jsonb, false) ->> 'dishes' as d1 \gset
reset role;
select 'F3 vendor can open and save without signing in', :'st0' = 'draft' and :'d1' = '1'
  and (select public_name = 'Akos Kitchen' and owner_name = 'Akosua Mensah' and capacity = 40 and auto_days = '{1,2,3,4,5}' from kitchens where id = :'vk')
  and (select addons = '[{"name":"Egg","price":5},{"name":"Shito","off":true,"price":0}]'::jsonb from menu_items where kitchen_id = :'vk') as ok;
-- F4 submitting checks the essentials
select set_config('t.vt', :'vt', false);
set role anon;
do $$ begin begin perform vendor_setup_save(current_setting('t.vt'), '{}'::jsonb, null, true); raise notice 'F4 FAIL submitted without location';
  exception when others then raise notice 'F4 ok submit needs the essentials: %', sqlerrm; end; end $$;
select vendor_setup_save(:'vt', '{"name":"Akos Kitchen","whatsapp":"0241112223","lat":"5.56","lng":"-0.19","payout_momo":"0559998887","payout_network":"MTN","capacity":"40"}'::jsonb, null, true) ->> 'status' as st1 \gset
reset role;
select 'F5 submitted, menu kept, still hidden', :'st1' = 'submitted' and (select setup_status = 'submitted' and not active and payout_momo = '0559998887' from kitchens where id = :'vk')
  and (select count(*) from menu_items where kitchen_id = :'vk') = 1 as ok;
-- F6 customers can't approve; the team sends it back, then approves
set request.jwt.claims = '{"sub":"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","email":"u1@x.com"}'; set role authenticated;
do $$ begin begin perform admin_vendor_review((select id from kitchens where public_name = 'Akos Kitchen'), true, null); raise notice 'F6 FAIL customer approved'; exception when others then raise notice 'F6 ok customers cannot approve'; end; end $$;
reset role; set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com"}'; set role authenticated;
select admin_vendor_review(:'vk', false, 'Add a photo-worthy name for your jollof');
reset role;
select 'F7 sent back with a note the vendor sees', (vendor_setup_get(:'vt') ->> 'status') = 'returned' and (vendor_setup_get(:'vt') ->> 'note') like 'Add a photo%' as ok;
set role anon;
select vendor_setup_save(:'vt', '{"name":"Akos Kitchen","whatsapp":"0241112223","lat":"5.56","lng":"-0.19","payout_momo":"0559998887"}'::jsonb, '[{"name":"Smoky party jollof","price":"45"}]'::jsonb, true) ->> 'status' as st2 \gset
reset role; set role authenticated;
select admin_vendor_review(:'vk', true, null);
reset role;
select 'F8 approved: live and on the menus', :'st2' = 'submitted' and (select active and setup_status is null from kitchens where id = :'vk')
  and exists (select 1 from public_menus where id = :'vk') as ok;
-- F9 once live, the form can't change anything
set role anon;
do $$ begin begin perform vendor_setup_save(current_setting('t.vt'), '{"name":"Hacked"}'::jsonb, null, false); raise notice 'F9 FAIL live vendor changed by form';
  exception when others then raise notice 'F9 ok live vendor: form closed'; end; end $$;
select (vendor_setup_get(:'vt') ->> 'live') as live \gset
reset role;
select 'F10 link of a live vendor says it is live', :'live' = 'true' as ok;
select 'F11 payout number stays team-only', not has_column_privilege('anon', 'kitchens', 'payout_momo', 'select') or not exists (select 1 from pg_policy where polrelid = 'kitchens'::regclass and polroles @> array[(select oid from pg_roles where rolname = 'anon')]) as ok;
set role anon;
do $$ begin begin perform vendor_setup_get('nope'); raise notice 'F12 FAIL bad link opened'; exception when others then raise notice 'F12 ok bad link refused'; end; end $$;
reset role;
rollback;
