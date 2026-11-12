-- ChopPool update 35: every alert is saved on the server, so the bell shows the same list on every phone
-- (app or browser), including alerts that never popped up. Only the last 7 days are kept. Safe to run more than once.

create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id uuid,                                                   -- a customer with an account
  order_id uuid,                                                  -- a customer without one (their order)
  kitchen_id uuid references kitchens(id) on delete cascade,
  rider_id uuid references riders(id) on delete cascade,
  title text not null,
  body text,
  url text,
  tag text,
  type text,
  read_at timestamptz
);
create index if not exists notifications_user_idx on notifications (user_id, created_at desc) where user_id is not null;
create index if not exists notifications_order_idx on notifications (order_id) where order_id is not null;
create index if not exists notifications_kitchen_idx on notifications (kitchen_id, created_at desc) where kitchen_id is not null;
create index if not exists notifications_rider_idx on notifications (rider_id, created_at desc) where rider_id is not null;
create index if not exists notifications_created_idx on notifications (created_at);
alter table notifications enable row level security;   -- no policies: only the notify function (service key) writes; people read through the functions below
revoke all on notifications from anon, authenticated;

-- Your alerts from the last 7 days: a signed-in customer (plus orders placed on this phone), or a vendor/rider by their link
create or replace function my_notifications(p_order_ids uuid[] default '{}', p_as text default null, p_token text default null)
returns setof notifications language plpgsql stable security definer set search_path = public as $$
declare v_k uuid; v_r uuid;
begin
  if p_as = 'vendor' then select id into v_k from kitchens where token = p_token and active; if v_k is null then return; end if;
    return query select * from notifications where kitchen_id = v_k and created_at > now() - interval '7 days' order by created_at desc limit 100;
  elsif p_as = 'rider' then select id into v_r from riders where token = p_token and active; if v_r is null then return; end if;
    return query select * from notifications where rider_id = v_r and created_at > now() - interval '7 days' order by created_at desc limit 100;
  else
    return query select * from notifications where created_at > now() - interval '7 days'
      and ((auth.uid() is not null and user_id = auth.uid()) or order_id = any(coalesce(p_order_ids, '{}'))) order by created_at desc limit 100;
  end if;
end $$;

create or replace function read_notifications(p_order_ids uuid[] default '{}', p_as text default null, p_token text default null)
returns int language plpgsql security definer set search_path = public as $$
declare v_k uuid; v_r uuid; n int;
begin
  if p_as = 'vendor' then select id into v_k from kitchens where token = p_token and active;
    update notifications set read_at = now() where kitchen_id = v_k and read_at is null and created_at > now() - interval '7 days';
  elsif p_as = 'rider' then select id into v_r from riders where token = p_token and active;
    update notifications set read_at = now() where rider_id = v_r and read_at is null and created_at > now() - interval '7 days';
  else
    update notifications set read_at = now() where read_at is null and created_at > now() - interval '7 days'
      and ((auth.uid() is not null and user_id = auth.uid()) or order_id = any(coalesce(p_order_ids, '{}')));
  end if;
  get diagnostics n = row_count; return n;
end $$;

-- Daily clean-up (called by the notify function once a day)
create or replace function prune_notifications() returns int language plpgsql security definer set search_path = public as $$
declare n int; begin delete from notifications where created_at < now() - interval '7 days'; get diagnostics n = row_count; return n; end $$;

revoke all on function my_notifications(uuid[], text, text) from public;
revoke all on function read_notifications(uuid[], text, text) from public;
revoke all on function prune_notifications() from public, anon, authenticated;
grant execute on function my_notifications(uuid[], text, text) to anon, authenticated;
grant execute on function read_notifications(uuid[], text, text) to anon, authenticated;
