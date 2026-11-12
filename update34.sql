-- ChopPool update 34: tester agreement. Customers, vendors and riders accept it once before using the app;
-- each acceptance is kept (who, when, which version). The owner can switch it off at launch. Safe to run more than once.

alter table settings add column if not exists tester_terms_on boolean not null default true;
alter table settings add column if not exists tester_terms_version int not null default 1;

create table if not exists tester_acceptances (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  role text not null check (role in ('customer', 'vendor', 'rider')),
  user_id uuid,
  kitchen_id uuid references kitchens(id) on delete cascade,
  rider_id uuid references riders(id) on delete cascade,
  email text,
  name text,
  version int not null,
  device text
);
create unique index if not exists tester_acc_user_v on tester_acceptances (user_id, version) where user_id is not null;
create unique index if not exists tester_acc_kitchen_v on tester_acceptances (kitchen_id, version) where kitchen_id is not null;
create unique index if not exists tester_acc_rider_v on tester_acceptances (rider_id, version) where rider_id is not null;
alter table tester_acceptances enable row level security;
drop policy if exists "team reads acceptances" on tester_acceptances;
create policy "team reads acceptances" on tester_acceptances for select to authenticated using (is_admin());
revoke insert, update, delete on tester_acceptances from anon, authenticated;

-- Has this person (signed-in customer, or vendor/rider by their link) accepted the current version? null = nothing to accept
create or replace function tester_terms_due(p_as text default null, p_token text default null) returns int
language plpgsql stable security definer set search_path = public as $$
declare s settings; v_k uuid; v_r uuid;
begin
  select * into s from settings where id = 1;
  if not s.tester_terms_on then return null; end if;
  if p_as = 'vendor' then select id into v_k from kitchens where token = p_token and active; if v_k is null then return null; end if;
    return case when exists (select 1 from tester_acceptances where kitchen_id = v_k and version = s.tester_terms_version) then null else s.tester_terms_version end;
  elsif p_as = 'rider' then select id into v_r from riders where token = p_token and active; if v_r is null then return null; end if;
    return case when exists (select 1 from tester_acceptances where rider_id = v_r and version = s.tester_terms_version) then null else s.tester_terms_version end;
  elsif auth.uid() is not null then
    return case when exists (select 1 from tester_acceptances where user_id = auth.uid() and version = s.tester_terms_version) then null else s.tester_terms_version end;
  end if;
  return null;
end $$;

create or replace function accept_tester_terms(p_version int, p_as text default null, p_token text default null, p_name text default null, p_device text default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare s settings; v_k kitchens; v_r riders;
begin
  select * into s from settings where id = 1;
  if p_version is distinct from s.tester_terms_version then raise exception 'The agreement was just updated. Please read it again.'; end if;
  if p_as = 'vendor' then
    select * into v_k from kitchens where token = p_token and active; if not found then raise exception 'This vendor link is not valid.'; end if;
    insert into tester_acceptances (role, kitchen_id, name, version, device) values ('vendor', v_k.id, coalesce(nullif(trim(p_name), ''), v_k.public_name), p_version, left(p_device, 200)) on conflict do nothing;
  elsif p_as = 'rider' then
    select * into v_r from riders where token = p_token and active; if not found then raise exception 'This rider link is not valid.'; end if;
    insert into tester_acceptances (role, rider_id, name, version, device) values ('rider', v_r.id, coalesce(nullif(trim(p_name), ''), v_r.name), p_version, left(p_device, 200)) on conflict do nothing;
  else
    if auth.uid() is null then raise exception 'Sign in first.'; end if;
    insert into tester_acceptances (role, user_id, email, name, version, device)
    values ('customer', auth.uid(), lower(auth.jwt() ->> 'email'), left(nullif(trim(p_name), ''), 80), p_version, left(p_device, 200)) on conflict do nothing;
  end if;
  return true;
end $$;
revoke all on function tester_terms_due(text, text) from public;
revoke all on function accept_tester_terms(int, text, text, text, text) from public;
grant execute on function tester_terms_due(text, text) to anon, authenticated;
grant execute on function accept_tester_terms(int, text, text, text, text) to anon, authenticated;
