-- ChopPool update 5: remove kitchens and buildings from the team pages
alter table kitchens add column if not exists archived boolean not null default false;
alter table sites add column if not exists archived boolean not null default false;

-- Removes a kitchen. If it has past orders it is archived (hidden, history kept); otherwise deleted for good.
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

-- Removes a building the same way.
create or replace function admin_remove_site(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  if exists (select 1 from orders where site_id = p_id) then
    update sites set archived = true, active = false where id = p_id;
    update kitchens set archived = true, active = false where site_id = p_id;
    return 'archived';
  end if;
  update kitchens set archived = true, active = false where site_id = p_id;
  delete from pools where site_id = p_id;
  delete from sites where id = p_id and not exists (select 1 from kitchens where site_id = p_id);
  if found then return 'deleted'; end if;
  update sites set archived = true, active = false where id = p_id;
  return 'archived';
end $$;

grant execute on function admin_remove_kitchen(uuid), admin_remove_site(uuid) to authenticated;
