\pset tuples_only on
begin;
create function t_fails(q text) returns text language plpgsql as $f$ begin execute q; return 'NO ERROR'; exception when others then return sqlerrm; end $f$;
grant execute on function t_fails(text) to public;
select id as s1 from sites where name like 'Heritage%' \gset
select id as s2 from sites where name like 'Pent%' \gset
insert into admins (email, role) values ('boss@x.com', 'super') on conflict (email) do update set role = excluded.role;
update settings set invites_per_day = 3 where id = 1;
-- A: signed out can't invite; the old add_vendor is closed
set role anon;
select 'E1 anon invite refused:', t_fails(format('select vendor_invite(%L, %L, %L, 5.565, -0.202, null)', :'s1', 'Auntie Ama', '0241110001'));
reset role;
set request.jwt.claims = '{"sub":"a0a0a0a0-0000-0000-0000-000000005401","email":"c1@x.com"}'; set role authenticated;
select 'E2 old add_vendor closed:', t_fails(format('select add_vendor(%L, %L, %L, %L::jsonb, null, null)', :'s1', 'X', '0241110009', '[]'));
-- B: first invite
select (vendor_invite(:'s1', 'Auntie Ama''s Kitchen', '024 111 0001', 5.565, -0.202, '{Waakye,waakye,"Fried rice"}') ->> 'id') as k1 \gset
reset role;
select 'V2 invite creates a draft vendor with a normalised phone', (select setup_status = 'draft' and not active and phone = '233241110001' and whatsapp = '0241110001'
   and invite_status = 'pending' and site_id = :'s1' and suggested_dishes @> '{Waakye,"Fried rice"}' and cardinality(suggested_dishes) = 2 from kitchens where id = :'k1') as ok;
select 'V3 a setup code exists and the customer is waiting', exists (select 1 from vendor_auth where kitchen_id = :'k1' and length(invite_code) = 18)
   and exists (select 1 from vendor_waiters where kitchen_id = :'k1' and user_id = 'a0a0a0a0-0000-0000-0000-000000005401') as ok;
select 'V4 the invite result gives no token or code', (select count(*) from json_object_keys(json_build_object('result', 'invited', 'id', :'k1', 'name', 'x'))) = 3 as ok;
-- C: same number from someone else (different format): joins, no second vendor
set request.jwt.claims = '{"sub":"a0a0a0a0-0000-0000-0000-000000005402","email":"c2@x.com"}'; set role authenticated;
select 'V5 same phone in +233 form joins the existing invite', vendor_invite(:'s1', 'Ama Waakye', '+233 24 111 0001', 5.6, -0.2, null) ->> 'result' = 'invited_already' as ok;
-- D: similar name close by, different phone: asks first
select 'V6 similar name nearby is offered', (vendor_invite(:'s1', 'Aunty Ama', '0241110002', 5.5652, -0.2021, null) -> 'matches' -> 0 ->> 'id') = :'k1' as ok;
select 'V7 far away is not a match', vendor_invite(:'s1', 'Aunty Ama', '0241110003', 5.60, -0.25, null) ->> 'result' = 'invited' as ok;
select 'V8 "Yes, that is her" joins', vendor_invite(:'s1', 'Aunty Ama', '0241110002', 5.5652, -0.2021, null, :'k1') ->> 'result' = 'invited_already' as ok;
select (vendor_invite(:'s1', 'Aunty Ama', '0241110004', 5.5652, -0.2021, null, null, true) ->> 'id') as k2 \gset
reset role;
select 'V9 "different vendor" is flagged as a possible duplicate', (select dup_of from kitchens where id = :'k2') = :'k1' as ok;
select 'V10 three people wait for the first vendor... two', (select count(*) from vendor_waiters where kitchen_id = :'k1') = 2 as ok;
-- E: daily limit (c2 has 2 new vendors; a third is fine, a fourth is not)
set request.jwt.claims = '{"sub":"a0a0a0a0-0000-0000-0000-000000005402","email":"c2@x.com"}'; set role authenticated;
select vendor_invite(:'s1', 'Kofi Kenkey', '0241110005', 5.58, -0.21, null) ->> 'result';
select 'E3 fourth invite:', t_fails(format('select vendor_invite(%L, %L, %L, 5.59, -0.22, null)', :'s1', 'Efua Fufu', '0241110006'));
select 'V11 fourth invite in a day refused', not exists (select 1 from kitchens where phone = '233241110006') as ok;
-- F: Remind goes to the team, once a day
select vendor_remind(:'k1');
select 'E4 second remind:', t_fails(format('select vendor_remind(%L)', :'k1'));
reset role;
select 'V12 reminder recorded', (select reminded_at is not null from vendor_waiters where kitchen_id = :'k1' and user_id = 'a0a0a0a0-0000-0000-0000-000000005402') as ok;
set request.jwt.claims = '{"sub":"a0a0a0a0-0000-0000-0000-000000005401","email":"c1@x.com"}'; set role authenticated;
select 'V13 waiting card shows the vendor with 2 people waiting', (select x ->> 'status' = 'invited' and (x ->> 'waiting')::int = 2 from json_array_elements(my_vendor_invites()) x where x ->> 'id' = :'k1') as ok;
-- G: customers cannot read the secrets or the team tables
select 'V14 customer cannot read waiters or the message log', (select count(*) from vendor_waiters) = 0 and (select count(*) from msg_log) = 0 as ok;
select 'E5 customer reads secrets:', t_fails('select count(*) from vendor_auth');
reset role;
-- H: the vendor opens her link
select invite_code as c1 from vendor_auth where kitchen_id = :'k1' \gset
set role anon;
select (vendor_claim(:'c1') ->> 'token') as tk1 \gset
select 'V16 the link still works until she sets a PIN', vendor_claim(:'c1') ->> 'token' = :'tk1' as ok;
select 'E6 weak PIN:', t_fails(format('select vendor_set_pin(%L, %L)', :'tk1', '1111'));
select vendor_set_pin(:'tk1', '4826');
select 'E7 link after PIN:', t_fails(format('select vendor_claim(%L)', :'c1'));
reset role;
select 'V15 claim returns her token', (select token from kitchens where id = :'k1') = :'tk1' as ok;
select 'V17 status claimed, PIN saved hashed', (select invite_status from kitchens where id = :'k1') = 'claimed' and (select pin_hash like '$2%' from vendor_auth where kitchen_id = :'k1') as ok;
set role anon;
select 'V18 login with phone + PIN', vendor_login('024 111 0001', '4826') ->> 'token' = :'tk1' as ok;
select 'V19 wrong PIN refused', vendor_login('0241110001', '4827') ->> 'error' = 'Wrong phone number or PIN.' as ok;
select vendor_login('0241110001', '0000'), vendor_login('0241110001', '0001'), vendor_login('0241110001', '0002'), vendor_login('0241110001', '0003');
select 'V20 after 5 wrong tries it locks, even with the right PIN', vendor_login('0241110001', '4826') ->> 'error' like 'Too many%' as ok;
reset role;
-- I: forgot PIN (the function stores the code hash)
update vendor_auth set reset_hash = encode(digest('482913', 'sha256'), 'hex'), reset_expires = now() + interval '10 minutes', reset_tries = 0 where kitchen_id = :'k1';
set role anon;
select 'V21 wrong code refused', vendor_reset_pin('0241110001', '111111', '7392') ->> 'error' like 'That code%' as ok;
select 'V22 right code sets the new PIN and signs in', vendor_reset_pin('0241110001', '482913', '7392') ->> 'token' = :'tk1' as ok;
select 'V23 new PIN works, lock cleared', vendor_login('0241110001', '7392') ->> 'token' = :'tk1' as ok;
select 'V24 code works once', vendor_reset_pin('0241110001', '482913', '5555') ->> 'error' is not null as ok;
-- J: setup + approval for every building tells the waiting customers
select vendor_setup_extra(:'tk1', true, false);
select vendor_setup_save(:'tk1', '{"payout_momo":"0241110001","payout_network":"MTN"}'::jsonb, '[{"name":"Waakye","price":30}]'::jsonb, true) ->> 'status';
reset role;
set request.jwt.claims = '{"sub":"b0b0b0b0-0000-0000-0000-000000000001","email":"boss@x.com"}'; set role authenticated;
select 'V25 team sees waiters and the wider request', (select count(*) from vendor_waiters where kitchen_id = :'k1') = 2 and (select wants_wider from kitchens where id = :'k1') as ok;
select admin_vendor_review(:'k1', true, null, true);
reset role;
select 'V26 live for every building', (select active and setup_status is null and site_id is null from kitchens where id = :'k1') as ok;
select 'V27 both waiting customers get a bell alert', (select count(*) from notifications where tag = 'vendor-live-' || :'k1') = 2 as ok;
-- K: a live vendor that serves one building: someone elsewhere asks for her
update kitchens set site_id = :'s1' where id = :'k1';
set request.jwt.claims = '{"sub":"a0a0a0a0-0000-0000-0000-000000005403","email":"c3@x.com"}'; set role authenticated;
select 'V28 live elsewhere: request recorded for the team', vendor_invite(:'s2', 'Ama', '0241110001', 5.65, -0.18, null) ->> 'result' = 'elsewhere' as ok;
select 'V29 live here', vendor_invite(:'s1', 'Ama', '0241110001', 5.65, -0.18, null) ->> 'result' = 'here' as ok;
reset role;
-- L: declining pauses invites for 30 days
select invite_code as c3 from vendor_auth a join kitchens k on k.id = a.kitchen_id where k.phone = '233241110003' \gset
set role anon;
select vendor_decline(:'c3');
reset role;
set request.jwt.claims = '{"sub":"a0a0a0a0-0000-0000-0000-000000005403","email":"c3@x.com"}'; set role authenticated;
select 'E8 declined within 30 days:', t_fails(format('select vendor_invite(%L, %L, %L, 5.60, -0.25, null)', :'s1', 'Someone', '0241110003'));
reset role;
update kitchens set declined_at = now() - interval '31 days' where phone = '233241110003';
set request.jwt.claims = '{"sub":"a0a0a0a0-0000-0000-0000-000000005403","email":"c3@x.com"}'; set role authenticated;
select 'V30 after 30 days she can be invited again', vendor_invite(:'s1', 'Someone', '0241110003', 5.60, -0.25, null) ->> 'result' = 'invited' as ok;
reset role;
select 'V31 back to pending with a new code', (select invite_status = 'pending' from kitchens where phone = '233241110003')
   and (select invite_code <> :'c3' from vendor_auth a join kitchens k on k.id = a.kitchen_id where k.phone = '233241110003') as ok;
-- M: team link and merge
set request.jwt.claims = '{"sub":"b0b0b0b0-0000-0000-0000-000000000001","email":"boss@x.com"}'; set role authenticated;
select admin_vendor_link(:'k2') as c2 \gset
select admin_vendor_merge(:'k2', :'k1');
reset role;
select 'V32 merged duplicate archived, waiters moved', (select archived and phone is null and invite_status = 'merged' from kitchens where id = :'k2')
   and not exists (select 1 from vendor_waiters where kitchen_id = :'k2') as ok;
set role anon;
select 'E9 merged link:', t_fails(format('select vendor_claim(%L)', :'c2'));
reset role;
-- N: a customer is not the team
set request.jwt.claims = '{"sub":"a0a0a0a0-0000-0000-0000-000000005401","email":"c1@x.com"}'; set role authenticated;
select 'E10 customer link:', t_fails(format('select admin_vendor_link(%L)', :'k1'));
select 'E11 customer open all:', t_fails(format('select admin_vendor_open_all(%L)', :'k1'));
reset role;
-- O: vendors the team adds get their sign-in number
insert into kitchens (name, public_name, whatsapp) values ('Team Add', 'Team Add', '0201234567');
select 'V33 team-added vendor gets a phone', (select phone from kitchens where name = 'Team Add') = '233201234567' as ok;
select 'V34 name matching ignores Auntie/Kitchen', name_sim('Auntie Ama''s Kitchen', 'Aunty Ama') = 1 and name_sim('Kofi Kenkey', 'Ama Waakye') < 0.5 as ok;
select 'V35 a shorter name inside a longer one matches', name_sim('Auntie Ama Waakye', 'Aunty Ama') >= 0.5 and name_sim('Ama', 'Abena Waakye') < 0.5 as ok;
rollback;
