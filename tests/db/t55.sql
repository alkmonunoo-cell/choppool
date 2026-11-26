\pset tuples_only on
begin;
create function t_fails(q text) returns text language plpgsql as $f$ begin execute q; return 'NO ERROR'; exception when others then return sqlerrm; end $f$;
grant execute on function t_fails(text) to public;
select id as s1 from sites where name like 'Heritage%' \gset
select id as s2 from sites where name like 'Pent%' \gset
insert into admins (email, role) values ('boss@x.com', 'super') on conflict (email) do update set role = excluded.role;
-- A live vendor with a PIN and a menu
insert into kitchens (name, public_name, whatsapp, capacity, lat, lng, active, payout_momo, payout_network, auto_days) values ('Ama Main', 'Auntie Ama', '0245550001', 30, 5.560, -0.200, true, '0245550001', 'MTN', '{1,2,3}') returning id as m1, token as mt \gset
insert into menu_items (kitchen_id, name, price) values (:'m1', 'Waakye', 30), (:'m1', 'Gari', 10);
set role anon; select vendor_set_pin(:'mt', '4826'); reset role;
select 'B1 main vendor has the sign-in phone', (select phone from kitchens where id = :'m1') = '233245550001' as ok;
-- Customer near her: joins
set request.jwt.claims = '{"sub":"a0a0a0a0-0000-0000-0000-000000005501","email":"c1@x.com"}'; set role authenticated;
select 'B2 same phone, same spot: joins her', vendor_invite(:'s1', 'Ama', '0245550001', 5.5601, -0.2001, null) ->> 'result' = 'here' as ok;
select 'B3 same phone far away: asks if it is a branch', (vendor_invite(:'s2', 'Ama', '0245550001', 5.650, -0.180, null)::jsonb) @> '{"result":"branch_q","name":"Auntie Ama"}' as ok;
select 'E1 "No": refused with a hint', t_fails(format('select vendor_invite(%L, %L, %L, 5.65, -0.18, null, null, false, false)', :'s2', 'Ama', '0245550001'));
select (vendor_invite(:'s2', 'Ama', '0245550001', 5.650, -0.180, '{Waakye}', null, false, true) ->> 'id') as b1 \gset
reset role;
select 'B4 branch created under her, menu and payout copied, no own sign-in number', (select parent_id = :'m1' and phone is null and setup_status = 'draft' and invite_status = 'pending'
   and payout_momo = '0245550001' and auto_days = '{1,2,3}' and site_id = :'s2' from kitchens where id = :'b1') and (select count(*) from menu_items where kitchen_id = :'b1') = 2 as ok;
set request.jwt.claims = '{"sub":"a0a0a0a0-0000-0000-0000-000000005502","email":"c2@x.com"}'; set role authenticated;
select 'B5 second customer at that spot joins the branch request', vendor_invite(:'s2', 'Ama', '0245550001', 5.6502, -0.1801, null) ->> 'result' = 'invited_already' as ok;
select 'B6 waiting card says branch', (select (x ->> 'branch')::boolean from json_array_elements(my_vendor_invites()) x where x ->> 'id' = :'b1') as ok;
reset role;
-- Owner opens the link
select invite_code as bc from vendor_auth where kitchen_id = :'b1' \gset
set role anon;
select 'B7 branch link returns the branch, with the spot', (vendor_claim(:'bc')::jsonb) @> '{"branch":true,"name":"Auntie Ama"}' as ok;
select vendor_branch_answer(:'bc', true);
reset role;
select token as bt from kitchens where id = :'b1' \gset
set role anon;
select 'E2 PIN on a branch:', t_fails(format('select vendor_set_pin(%L, %L)', :'bt', '7392'));
select 'B8 setup form knows it is a branch (no PIN step)', (vendor_setup_get(:'bt')::jsonb) @> '{"branch":true,"has_pin":true}' as ok;
select vendor_setup_save(:'bt', '{"payout_momo":"0245550001","payout_network":"MTN","lat":5.650,"lng":-0.180,"whatsapp":"0201112222"}'::jsonb, '[{"name":"Waakye","price":32}]'::jsonb, true) ->> 'status';
select 'B9 owner sees both, branch tokens only with her token', json_array_length(vendor_branches(:'mt')) = 2 and vendor_branches(:'bt') is null as ok;
select 'B10 owner PIN still signs in to the main page', vendor_login('0245550001', '4826') ->> 'token' = :'mt' as ok;
reset role;
select 'B11 branch with its own rider phone still has no sign-in number', (select phone is null and whatsapp = '0201112222' from kitchens where id = :'b1') as ok;
set request.jwt.claims = '{"sub":"b0b0b0b0-0000-0000-0000-000000000001","email":"boss@x.com"}'; set role authenticated;
select admin_vendor_review(:'b1', true, null);
reset role;
select 'B12 branch live, waiting customers told', (select active and setup_status is null from kitchens where id = :'b1') and (select count(*) from notifications where tag = 'vendor-live-' || :'b1') = 2 as ok;
set request.jwt.claims = '{"sub":"a0a0a0a0-0000-0000-0000-000000005503","email":"c3@x.com"}'; set role authenticated;
select 'B13 next customer near the branch joins the branch', vendor_invite(:'s2', 'Ama', '0245550001', 5.6501, -0.1801, null) ->> 'id' = :'b1' as ok;
reset role;
-- She adds a branch herself
set role anon;
select vendor_branch_add(:'mt', 5.600, -0.250) as b2t \gset
select 'E3 same spot twice:', t_fails(format('select vendor_branch_add(%L, 5.600, -0.250)', :'mt'));
select 'E4 branch token cannot add branches:', t_fails(format('select vendor_branch_add(%L, 5.62, -0.26)', :'bt'));
reset role;
select 'B14 self-added branch: claimed, menu copied', (select invite_status = 'claimed' and parent_id = :'m1' from kitchens where token = :'b2t') and (select count(*) from menu_items i join kitchens k on k.id = i.kitchen_id where k.token = :'b2t') = 2 as ok;
-- "That's not mine"
insert into kitchens (name, public_name, whatsapp, capacity, lat, lng, active) values ('Kofi', 'Kofi Kenkey', '0245550009', 30, 5.57, -0.21, true) returning id as m2 \gset
set request.jwt.claims = '{"sub":"a0a0a0a0-0000-0000-0000-000000005504","email":"c4@x.com"}'; set role authenticated;
select (vendor_invite(:'s1', 'Kofi', '0245550009', 5.70, -0.30, null, null, false, true) ->> 'id') as b3 \gset
reset role;
select invite_code as c3 from vendor_auth where kitchen_id = :'b3' \gset
set role anon; select vendor_branch_answer(:'c3', false); reset role;
select 'B15 not mine: team sees it, link closed', (select invite_status = 'not_mine' from kitchens where id = :'b3') as ok;
set role anon; select 'E5 claim after not mine:', t_fails(format('select vendor_claim(%L)', :'c3')); reset role;
-- Team links an existing vendor as a branch, then unlinks
insert into kitchens (name, public_name, whatsapp, capacity, lat, lng, active) values ('Ama 2', 'Auntie Ama Osu', '0249990000', 30, 5.55, -0.18, true) returning id as k3 \gset
set request.jwt.claims = '{"sub":"b0b0b0b0-0000-0000-0000-000000000001","email":"boss@x.com"}'; set role authenticated;
select admin_vendor_set_parent(:'k3', :'m1');
select 'E6 a branch as main:', t_fails(format('select admin_vendor_set_parent(%L, %L)', :'m2', :'k3'));
reset role;
select 'B16 linked: under her, sign-in number cleared', (select parent_id = :'m1' and phone is null from kitchens where id = :'k3') as ok;
set request.jwt.claims = '{"sub":"b0b0b0b0-0000-0000-0000-000000000001","email":"boss@x.com"}'; set role authenticated;
select admin_vendor_set_parent(:'k3', null);
reset role;
select 'B17 unlinked: her own number back', (select parent_id is null and phone = '233249990000' from kitchens where id = :'k3') as ok;
set request.jwt.claims = '{"sub":"a0a0a0a0-0000-0000-0000-000000005501","email":"c1@x.com"}'; set role authenticated;
select 'E7 customer cannot link:', t_fails(format('select admin_vendor_set_parent(%L, %L)', :'k3', :'m1'));
reset role;
rollback;
