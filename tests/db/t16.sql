\set ON_ERROR_STOP 1
begin;
update settings set cutoff = '23:59', special_cutoff = '23:58' where id = 1;
select id as s1 from sites where name like 'Heritage%' \gset
select k.id as k1 from kitchens k where k.active order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active limit 1 \gset
insert into kitchen_days values (:'k1', current_order_date()) on conflict do nothing;
set request.jwt.claims = '{}'; set role anon;
select place_order(:'s1', :'i1', 1, 'Ama Mensah', '0241111111', 'REF1234') ->> 'id' as oa \gset
do $$ begin perform submit_review(current_setting('x.o', true)::uuid, '0241111111', 5, 'x'); exception when others then raise notice 'early: %', sqlerrm; end $$;
reset role;
update orders set status = 'collected' where id = :'oa';
set role anon;
select submit_review(:'oa', '0241111111', 4, 'Very tasty', null);
select submit_review(:'oa', '0241111111', 5, 'Even better', 'https://x.supabase.co/storage/v1/object/public/dish-photos/reviews/' || :'oa' || '/a.webp');
select 'public', name, rating, comment, photo_url is not null from public_reviews;
select 'folder ok', review_folder_ok(:'oa');
select 'scores', rating, ratings from kitchen_scores where kitchen_id = :'k1';
reset role;
select 'mine', my_rating, my_photo is not null from my_orders(array[:'oa'::uuid]);
rollback;
