\pset tuples_only on
begin;
update settings set cutoff = '23:59', base_fare = 5, per_km = 5, trip_min = 10, trip_max = 100 where id = 1;
select id as s1 from sites where name like 'Pent%' \gset
select k.id as k1, k.token as tk from kitchens k where k.active and not k.added_by_customer and k.delivery_mode = 'rider' and k.lat is not null order by name limit 1 \gset
select id as i1 from menu_items where kitchen_id = :'k1' and active order by name limit 1 \gset
select kitchen_accept_terms(:'tk'); select kitchen_open_day(:'tk', current_order_date());
update kitchens set free_m = 0 where id = :'k1';
select place_order(:'s1', :'i1', 1, 'Ama Owusu', '0240000101', 'REFX1', '{}', null, null, false, null) as o1 \gset
select pool_id as pid from orders where id = (:'o1'::json ->> 'id')::uuid \gset
-- put the vendor right next to the building: the trip is the minimum
update kitchens k set lat = st.lat + 0.0005, lng = st.lng from sites st where k.id = :'k1' and st.id = :'s1';
select 'M1 very short trip charges the lowest price', pool_trip(:'pid') = 10 as ok;
-- about 10 km away: base + rate x road km
update kitchens k set lat = st.lat + 0.07, lng = st.lng from sites st where k.id = :'k1' and st.id = :'s1';
select 'M2 long trip is base + rate per km', pool_trip(:'pid') > 10 and pool_trip(:'pid') = round(5 + 5 * dist_m(k.lat, k.lng, st.lat, st.lng) / 1000 * 1.3) as ok from kitchens k, sites st where k.id = :'k1' and st.id = :'s1';
update settings set trip_max = 30 where id = 1;
select 'M3 never above the highest', pool_trip(:'pid') = 30 as ok;
rollback;
