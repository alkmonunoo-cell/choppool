-- ChopPool update 39: a quick check for the team that the bell history is being saved (Settings > Alerts check). Read-only.

create or replace function bell_status() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Team members only.'; end if;
  return json_build_object('last_at', (select max(created_at) from notifications),
                           'today', (select count(*) from notifications where created_at > now() - interval '24 hours'));
end $$;
revoke all on function bell_status() from public, anon;
grant execute on function bell_status() to authenticated;
