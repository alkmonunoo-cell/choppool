begin;
update settings set cutoff = '23:59', special_cutoff = '23:58', max_meals = 30 where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
select place_order(:'s1', :'i1', 2, 'Victim Guest', '0241111111', 'REF1234') ->> 'id' as v \gset
select (kitchen_view(:'tk', current_order_date()) -> 'pools' -> 0 -> 'orders' -> 0)::text as first_order;
rollback;
