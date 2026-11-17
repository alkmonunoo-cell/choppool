\pset tuples_only on
begin;
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer order by name limit 1 \gset
update settings set vendor_fee_rate = 0.05, vendor_fee_free = 5 where id = 1;
select kitchen_accept_terms(:'tk');
insert into admins (email, role) values ('boss@x.com', 'super') on conflict (email) do update set role = excluded.role;
insert into admins (email, role) values ('co@x.com', 'coordinator') on conflict (email) do update set role = excluded.role;
select 'G1 default terms apply', vendor_fee_rate_of(:'k1') = 0.05 and vendor_fee_free_of(:'k1') = 5 as ok;
-- G2 a coordinator cannot set a vendor's own fee
set request.jwt.claims = '{"sub":"dddddddd-dddd-dddd-dddd-dddddddddddd","email":"co@x.com"}'; set role authenticated;
select set_config('t.k', :'k1', false);
do $$ begin begin update kitchens set fee_own = true, fee_own_rate = 0.02, fee_own_free = 3 where id = current_setting('t.k')::uuid;
  if found then raise notice 'G2 FAIL coordinator changed the fee'; else raise notice 'G2 FAIL no row (rls)'; end if;
  exception when others then raise notice 'G2 ok coordinators cannot change the fee: %', sqlerrm; end; end $$;
-- G3 coordinator can still edit other vendor fields
update kitchens set tagline = 'edited' where id = :'k1';
reset role;
select 'G3 coordinator edits other fields', (select tagline = 'edited' from kitchens where id = :'k1') as ok;
-- G4 owner sets a lower own fee: applies at once, no acceptance needed
set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com"}'; set role authenticated;
update kitchens set fee_own = true, fee_own_rate = 0.02, fee_own_free = 8 where id = :'k1';
reset role;
select 'G4 own terms apply', vendor_fee_rate_of(:'k1') = 0.02 and vendor_fee_free_of(:'k1') = 8 as ok;
select kitchen_view(:'tk', current_order_date()) as kv \gset
select 'G5 vendor page shows own terms', (:'kv'::json -> 'kitchen' ->> 'fee_rate')::numeric = 0.02 and (:'kv'::json -> 'kitchen' ->> 'fee_free')::int = 8 and (:'kv'::json -> 'kitchen' ->> 'fee_own')::boolean as ok;
-- G6 a better deal needs no acceptance: the vendor can confirm a day
select kitchen_open_day(:'tk', current_order_date() + 7);
select 'G6 lower fee confirms fine', true as ok;
-- G7 owner raises the vendor's own fee: they must accept first; auto days pause until then
update kitchens set fee_own_rate = 0.10, auto_days = array[1,2,3,4,5,6,7] where id = :'k1';
select set_config('t.tk', :'tk', false);
do $$ begin begin perform kitchen_open_day(current_setting('t.tk'), current_order_date() + 8); raise notice 'G7 FAIL opened without accepting';
  exception when others then raise notice 'G7 ok must accept: %', sqlerrm; end; end $$;
select 'G8 auto days wait for acceptance', not kitchen_is_open(:'k1', current_order_date() + 9) as ok;
select kitchen_accept_terms(:'tk') as acc \gset
select 'G9 accepting takes their own terms', (:'acc'::json ->> 'rate')::numeric = 0.10 and (:'acc'::json ->> 'free')::int = 8
  and (select fee_ack = 0.10 and fee_free_ack = 8 from kitchens where id = :'k1') as ok;
select 'G10 open after accepting', kitchen_is_open(:'k1', current_order_date() + 9) as ok;
-- G11 a new pool takes the vendor's terms
select id as s1 from sites where status = 'active' limit 1 \gset
insert into pools (kitchen_id, site_id, order_date, status) values (:'k1', :'s1', current_order_date() + 20, 'waiting') returning fee_rate as pr, fee_free as pf \gset
select 'G11 new pool uses own terms', :'pr'::numeric = 0.10 and :'pf'::int = 8 as ok;
-- G12 a Settings change does not touch a vendor on own terms
update settings set vendor_fee_rate = 0.20 where id = 1;
select 'G12 default change leaves own terms', vendor_fee_rate_of(:'k1') = 0.10 and kitchen_is_open(:'k1', current_order_date() + 9) as ok;
-- G13 back to default: default applies (now 20%, so acceptance needed)
update kitchens set fee_own = false, fee_own_rate = null, fee_own_free = null where id = :'k1';
select 'G13 back to default', vendor_fee_rate_of(:'k1') = 0.20 and vendor_fee_free_of(:'k1') = 5 and not kitchen_is_open(:'k1', current_order_date() + 9) as ok;
-- G14 own terms need both values, within limits
do $$ begin begin update kitchens set fee_own = true where id = current_setting('t.k')::uuid; raise notice 'G14 FAIL own without values';
  exception when others then raise notice 'G14 ok values required'; end;
  begin update kitchens set fee_own = true, fee_own_rate = 0.6, fee_own_free = 5 where id = current_setting('t.k')::uuid; raise notice 'G14b FAIL 60%%';
  exception when others then raise notice 'G14b ok capped at 50%%'; end; end $$;
rollback;
