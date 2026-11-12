-- ChopPool update 36: the team can correct an extra's name on open orders (the vendor sees the new name).
-- Prices, counts and totals on those orders never change. Safe to run more than once.

create or replace function admin_rename_addons(p_item uuid, p_renames jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; c int;
begin
  if not is_admin() then raise exception 'Only the ChopPool team can do this.'; end if;
  for r in select * from jsonb_to_recordset(coalesce(p_renames, '[]'::jsonb)) as x("from" text, "to" text, price numeric) loop
    if char_length(trim(coalesce(r."to", ''))) < 2 or char_length(r."to") > 80 then raise exception 'Each extra needs a name.'; end if;
    if r."from" is null or r."from" = r."to" then continue; end if;
    update orders o set addons = (
        select jsonb_agg(case when e ->> 'name' = r."from" and coalesce(nullif(e ->> 'price', '')::numeric, 0) = coalesce(r.price, 0)
                              then jsonb_set(e, '{name}', to_jsonb(trim(r."to"))) else e end order by i)
        from jsonb_array_elements(o.addons) with ordinality t(e, i))
    where o.item_id = p_item and o.order_date >= (now() at time zone 'utc')::date and o.status not in ('cancelled', 'collected')
      and exists (select 1 from jsonb_array_elements(o.addons) e where e ->> 'name' = r."from" and coalesce(nullif(e ->> 'price', '')::numeric, 0) = coalesce(r.price, 0));
    get diagnostics c = row_count; n := n + c;
  end loop;
  return n;
end $$;
revoke all on function admin_rename_addons(uuid, jsonb) from public, anon;
grant execute on function admin_rename_addons(uuid, jsonb) to authenticated;
