\pset tuples_only on
begin;
insert into admins (email, role) values ('boss@x.com', 'super') on conflict (email) do update set role = excluded.role;
insert into admins (email, role) values ('co@x.com', 'coordinator') on conflict (email) do update set role = excluded.role;
set request.jwt.claims = '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","email":"boss@x.com"}'; set role authenticated;
insert into business_costs (cost_date, category, description, amount, paid_from, treatment, months) values ('2026-11-05', 'Software & hosting', 'Domain, 1 year', 120, 'owner', 'spread', 12) returning id as c1 \gset
insert into business_costs (cost_date, category, description, amount, treatment, months, residual) values ('2026-11-10', 'Equipment', 'Laptop', 6000, 'asset', 36, 600);
select 'C1 owner adds and reads costs', (select count(*) from business_costs) = 2 and (select created_by from business_costs where id = :'c1') = 'boss@x.com' as ok;
reset role;
set request.jwt.claims = '{"sub":"dddddddd-dddd-dddd-dddd-dddddddddddd","email":"co@x.com"}'; set role authenticated;
select 'C2 coordinators see nothing', (select count(*) from business_costs) = 0 as ok;
do $$ begin begin insert into business_costs (cost_date, category, amount) values ('2026-11-05', 'Other', 5); raise notice 'C3 FAIL coordinator added';
  exception when others then raise notice 'C3 ok coordinators cannot add'; end; end $$;
reset role;
set request.jwt.claims = ''; set role anon;
do $$ begin begin perform 1 from business_costs; raise notice 'C4 FAIL anon read'; exception when others then raise notice 'C4 ok anon cannot read'; end; end $$;
reset role;
do $$ begin begin insert into business_costs (cost_date, category, amount, treatment) values ('2026-11-05', 'Other', 5, 'spread'); raise notice 'C5 FAIL spread without months';
  exception when others then raise notice 'C5 ok spread needs months'; end;
  begin insert into business_costs (cost_date, category, amount, treatment, months, residual) values ('2026-11-05', 'Equipment', 100, 'asset', 12, 100); raise notice 'C6 FAIL residual = cost';
  exception when others then raise notice 'C6 ok residual below cost'; end; end $$;
rollback;
