\set ON_ERROR_STOP 0
\pset tuples_only on
begin;
update settings set cutoff = '23:59', special_cutoff = '23:00' where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
insert into admins(email, role) values ('coord@x.com', 'coordinator') on conflict (email) do update set role = 'coordinator';
-- guest order, then hide name with its id
set request.jwt.claims = '{}'; set role anon;
select place_order(:'s1', :'i1', 1, 'Ama Mensah', '0240000011', 'REF-NP1') ->> 'id' as g1 \gset
select set_name_privacy(array[:'g1']::uuid[], true);
reset role;
select 'N1 guest hides name', hide_name as ok from orders where id = :'g1';
-- someone else cannot flip an account order by id
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","email":"ama@x.com"}'; set role authenticated;
select place_order(:'s1', :'i1', 1, 'Kofi Boat', '0240000022', 'REF-NP2') ->> 'id' as a1 \gset
reset role;
set request.jwt.claims = '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}'; set role authenticated;
select set_name_privacy(array[:'a1']::uuid[], true);
reset role;
select 'N2 stranger cannot change account order', not hide_name as ok from orders where id = :'a1';
set request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","email":"ama@x.com"}'; set role authenticated;
select set_name_privacy(array[]::uuid[], true);
reset role;
select 'N3 owner hides all own orders', hide_name as ok from orders where id = :'a1';
-- review name hidden
insert into reviews(order_id, kitchen_id, site_id, rating) select id, kitchen_id, site_id, 5 from orders where id = :'g1';
set role anon; select 'N4 review shows no name', name is null as ok from public_reviews where kitchen_id = :'k1' and rating = 5 limit 1; reset role;
-- anon cannot write to view
select 'N5 anon has no update on view', not has_table_privilege('anon','public_reviews','UPDATE') as ok;
-- photos: seller upload is pending, admin approves, admin upload approved
set role anon; select vendor_set_photo(:'tk', :'i1', 'https://x/dish-photos/' || kitchen_folder(:'tk') || '/p1.jpg'); reset role;
select 'F1 seller photo pending', photo_status = 'pending' as ok from menu_items where id = :'i1';
set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"coord@x.com"}'; set role authenticated;
update menu_items set photo_status = 'approved' where id = :'i1';
reset role;
select 'F2 admin approves', photo_status = 'approved' as ok from menu_items where id = :'i1';
set role authenticated; update menu_items set photo_url = 'https://x/p2.jpg' where id = :'i1'; reset role;
select 'F3 admin upload approved', photo_status = 'approved' as ok from menu_items where id = :'i1';
update menu_items set photo_status = 'pending' where id = :'i1';
set request.jwt.claims = '{}'; set role anon; update menu_items set photo_status = 'approved' where id = :'i1'; reset role;
select 'F4 anon cannot approve', photo_status = 'pending' as ok from menu_items where id = :'i1';
rollback;
