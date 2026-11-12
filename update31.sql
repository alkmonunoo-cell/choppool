-- ChopPool update 31: "Send feedback" from every screen (customers, vendors, riders, team), with up to 3 photos.
-- Photos go to a private bucket that only the team can open. Safe to run more than once.

create table if not exists feedback (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  role text not null check (role in ('customer', 'guest', 'vendor', 'rider', 'team')),
  user_id uuid,
  kitchen_id uuid references kitchens(id) on delete set null,
  rider_id uuid references riders(id) on delete set null,
  name text,
  contact text,
  kind text not null default 'problem' check (kind in ('problem', 'idea', 'other')),
  message text not null check (char_length(message) between 2 and 2000),
  screen text,
  device text,
  app_version text,
  images text[] not null default '{}',
  status text not null default 'new' check (status in ('new', 'seen', 'done')),
  team_note text
);
create index if not exists feedback_created_idx on feedback (created_at desc);
alter table feedback enable row level security;
drop policy if exists "team reads feedback" on feedback;
create policy "team reads feedback" on feedback for select to authenticated using (is_admin());
drop policy if exists "team updates feedback" on feedback;
create policy "team updates feedback" on feedback for update to authenticated using (is_admin()) with check (is_admin());
revoke insert, delete on feedback from anon, authenticated;

-- Everyone sends through this, so the sender is worked out here (a vendor or rider by their link, the team by their sign-in)
create or replace function send_feedback(p_kind text, p_message text, p_screen text default null, p_device text default null, p_version text default null,
  p_images text[] default '{}', p_name text default null, p_contact text default null, p_as text default null, p_token text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_role text; v_kitchen uuid; v_rider uuid; v_user uuid := auth.uid(); v_id uuid; v_img text; v_n int;
begin
  if coalesce(p_kind, '') not in ('problem', 'idea', 'other') then raise exception 'Choose what kind of feedback this is.'; end if;
  if char_length(trim(coalesce(p_message, ''))) < 2 then raise exception 'Tell us a little more.'; end if;
  if char_length(p_message) > 2000 then raise exception 'Keep it under 2,000 characters.'; end if;
  if coalesce(array_length(p_images, 1), 0) > 3 then raise exception 'Add up to 3 photos.'; end if;
  foreach v_img in array coalesce(p_images, '{}') loop
    if v_img !~ '^fb/[0-9a-f-]{36}/[A-Za-z0-9._-]{1,80}$' then raise exception 'Upload the photos from the feedback form.'; end if;
  end loop;
  if p_as = 'vendor' then
    select id into v_kitchen from kitchens where token = p_token and active; if v_kitchen is null then raise exception 'This vendor link is not valid.'; end if; v_role := 'vendor';
  elsif p_as = 'rider' then
    select id into v_rider from riders where token = p_token and active; if v_rider is null then raise exception 'This rider link is not valid.'; end if; v_role := 'rider';
  elsif p_as = 'team' then
    if not is_admin() then raise exception 'Sign in to the team screen first.'; end if; v_role := 'team';
  elsif v_user is not null then v_role := 'customer';
  else v_role := 'guest';
  end if;
  -- Spam guard: 10 an hour per sender, 30 an hour from guests altogether
  select count(*) into v_n from feedback where created_at > now() - interval '1 hour' and (
    (v_kitchen is not null and kitchen_id = v_kitchen) or (v_rider is not null and rider_id = v_rider)
    or (v_role in ('customer', 'team') and user_id = v_user) or (v_role = 'guest' and role = 'guest'));
  if v_n >= (case when v_role = 'guest' then 30 else 10 end) then raise exception 'Thanks, we have your feedback. Try again in a little while.'; end if;
  insert into feedback (role, user_id, kitchen_id, rider_id, name, contact, kind, message, screen, device, app_version, images)
  values (v_role, case when v_role in ('customer', 'team') then v_user end, v_kitchen, v_rider, left(nullif(trim(p_name), ''), 80), left(nullif(trim(p_contact), ''), 120),
    p_kind, trim(p_message), left(p_screen, 80), left(p_device, 200), left(p_version, 40), coalesce(p_images, '{}'))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function send_feedback(text, text, text, text, text, text[], text, text, text, text) from public;
grant execute on function send_feedback(text, text, text, text, text, text[], text, text, text, text) to anon, authenticated;

-- Private bucket: anyone can add a photo under fb/ (max 1.5 MB, images only); only the team can view them
do $$ begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('feedback', 'feedback', false, 1572864, array['image/webp', 'image/jpeg', 'image/png'])
    on conflict (id) do update set public = false, file_size_limit = 1572864, allowed_mime_types = array['image/webp', 'image/jpeg', 'image/png'];
    execute 'drop policy if exists "feedback photos add" on storage.objects';
    execute 'create policy "feedback photos add" on storage.objects for insert to anon, authenticated with check (bucket_id = ''feedback'' and (storage.foldername(name))[1] = ''fb'')';
    execute 'drop policy if exists "feedback photos team" on storage.objects';
    execute 'create policy "feedback photos team" on storage.objects for select to authenticated using (bucket_id = ''feedback'' and public.is_admin())';
  end if;
end $$;
