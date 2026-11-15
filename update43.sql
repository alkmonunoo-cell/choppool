-- ============================================================
-- ChopPool update 43: phone number + PIN sign-in (codes by SMS through Arkesel). Safe to run more than once.
-- Off until you switch it on in Admin › Settings › Phone sign-in (after "ChopPool" is approved as the SMS sender).
-- ============================================================
alter table settings add column if not exists phone_signin boolean not null default false;

-- Accounts made with a phone number have no email: count them too
create or replace function admin_account_stats() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_super() then raise exception 'Only the owner can see this.'; end if;
  return json_build_object(
    'accounts', (select count(*) from auth.users u where u.email is null or lower(u.email) not in (select email from admins)),
    'active', (select count(distinct o.user_id) from orders o where o.user_id is not null and o.status <> 'cancelled'
                 and o.created_at > now() - interval '30 days'));
end $$;
