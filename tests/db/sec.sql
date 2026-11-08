\set ON_ERROR_STOP 0
begin;
update settings set cutoff = '23:59', special_cutoff = '23:58', max_meals = 30 where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1 from kitchens k where k.active order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active limit 1 \gset
select kitchen_accept_terms(token) from kitchens where id = :'k1';
select kitchen_open_day(token, current_order_date()) from kitchens where id = :'k1';
set request.jwt.claims = '{}'; set role anon;
select place_order(:'s1', :'i1', 2, 'Victim Guest', '0241111111', 'REF1234') ->> 'id' as v \gset
reset role; update orders set status = 'paid' where id = :'v';
set role anon;
select 'T1 feed hides id', not exists(select 1 from recent_activity where id::text = :'v') as ok;
select 'T2 board hides id', position(:'v' in board_data(current_order_date())::text) = 0 as ok;
select 'T3 vendor view hides id', position(:'v' in (select kitchen_view(token, current_order_date())::text from kitchens where id = :'k1')) = 0 as ok;
savepoint a; update public_sites set name = 'HACKED'; rollback to a;
savepoint b; insert into public_sites(id, name) values (gen_random_uuid(), 'Fake'); rollback to b;
savepoint c; delete from recent_activity; rollback to c;
savepoint d; select wallet_balance('11111111-1111-1111-1111-111111111111'); rollback to d;
savepoint e; select pool_meals(id) from pools limit 1; rollback to e;
reset role;
select 'T4 no fake site', not exists(select 1 from sites where name in ('Fake','HACKED')) as ok;
-- coordinator
insert into admins(email, role) values ('coord@x.com', 'coordinator') on conflict (email) do update set role = 'coordinator';
set request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","email":"coord@x.com"}'; set role authenticated;
savepoint f; update settings set vendor_fee_rate = 0.5 where id = 1; rollback to f;
savepoint g; insert into wallet_entries(user_id, amount, reason) values ('22222222-2222-2222-2222-222222222222', 500, 'me'); rollback to g;
savepoint h; update orders set unit_price = 1 where id = :'v'; rollback to h;
savepoint i; update orders set status = 'collected', collected_at = now(), collected_by = 'coordinator' where id = :'v'; select 'T5 coordinator status ok', status = 'collected' as ok from orders where id = :'v'; rollback to i;
savepoint j; update settings set base_fare = 21 where id = 1; select 'T6 coordinator pricing ok', base_fare = 21 as ok from settings; rollback to j;
savepoint k2; delete from orders where id = :'v'; select 'T7 coordinator cannot delete', exists(select 1 from orders where id = :'v') as ok; rollback to k2;
reset role;
rollback;
