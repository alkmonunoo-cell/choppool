\pset tuples_only on
begin;
update settings set cutoff = '23:59', special_cutoff = '00:01' where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select id as i1 from menu_items where active order by name limit 1 \gset
savepoint a;
do $$ begin perform place_order((select id from sites where name like 'Pent%'), (select id from menu_items where active order by name limit 1), 1, 'Ama', '0240000099', null, '{}', null, 'Jollof with goat', false, null);
exception when others then raise notice 'MSG: %', sqlerrm; create temp table m25 as select sqlerrm as m; end $$;
select 'U1 custom order wording', (select m from m25) like 'Custom orders close at%' as ok;
rollback;
