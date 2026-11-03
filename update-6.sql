-- ChopPool update 6 (safe to run more than once; includes update 5)
-- 1) Remove kitchens and buildings
alter table kitchens add column if not exists archived boolean not null default false;
alter table sites add column if not exists archived boolean not null default false;

create or replace function admin_remove_kitchen(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  if exists (select 1 from orders where kitchen_id = p_id) then
    update kitchens set archived = true, active = false where id = p_id;
    return 'archived';
  end if;
  delete from kitchen_days where kitchen_id = p_id;
  delete from pools where kitchen_id = p_id;
  delete from menu_items where kitchen_id = p_id;
  delete from kitchens where id = p_id;
  return 'deleted';
end $$;

create or replace function admin_remove_site(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  update kitchens set archived = true, active = false where site_id = p_id;
  if exists (select 1 from orders where site_id = p_id) or exists (select 1 from kitchens where site_id = p_id) then
    update sites set archived = true, active = false where id = p_id;
    return 'archived';
  end if;
  delete from pools where site_id = p_id;
  delete from sites where id = p_id;
  return 'deleted';
end $$;

grant execute on function admin_remove_kitchen(uuid), admin_remove_site(uuid) to authenticated;

-- 2) Map pins for kitchens, so customers see kitchens near them
alter table kitchens add column if not exists lat double precision;
alter table kitchens add column if not exists lng double precision;

create or replace view public_menus as
  select id, public_name, tagline, capacity, site_id, added_by_customer, lat, lng from kitchens where active;
grant select on public_menus to anon, authenticated;

-- Sellers added by customers take their building's pin
update kitchens k set lat = s.lat, lng = s.lng from sites s
 where k.site_id = s.id and k.lat is null;

create or replace function add_vendor(p_site uuid, p_name text, p_whatsapp text, p_items jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare k kitchens; si sites; v_wa text := regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g'); it jsonb; n int := 0;
begin
  select * into si from sites where id = p_site and active and status = 'active';
  if not found then raise exception 'Pick your drop point first.'; end if;
  if char_length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Add the seller''s name.'; end if;
  if v_wa !~ '^0[0-9]{9}$' then raise exception 'Enter the seller''s 10-digit WhatsApp number, like 024 123 4567.'; end if;
  if (select count(*) from kitchens where site_id = p_site and created_at > now() - interval '1 day') >= 10 then
    raise exception 'Too many sellers were added here today. Ask the ChopPool team to help.';
  end if;
  insert into kitchens (name, public_name, tagline, whatsapp, capacity, site_id, added_by_customer, added_by, lat, lng)
  values (trim(p_name), trim(p_name), 'Added by a customer', v_wa, 30, p_site, true, auth.uid(), si.lat, si.lng)
  returning * into k;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    if char_length(trim(coalesce(it ->> 'name', ''))) >= 2 and coalesce((it ->> 'price')::numeric, 0) > 0 then
      insert into menu_items (kitchen_id, name, price) values (k.id, trim(it ->> 'name'), (it ->> 'price')::numeric);
      n := n + 1;
    end if;
  end loop;
  if n = 0 then raise exception 'Add at least one dish with its price.'; end if;
  return json_build_object('id', k.id, 'token', k.token, 'whatsapp', k.whatsapp, 'name', k.public_name);
end $$;

-- Example kitchens get example pins (Osu and Airport Residential). Change them in the app.
update kitchens set lat = 5.5560, lng = -0.1820 where name = 'Auntie Akos Kitchen' and lat is null;
update kitchens set lat = 5.6010, lng = -0.1780 where name = 'Green Bowl' and lat is null;

notify pgrst, 'reload schema';
