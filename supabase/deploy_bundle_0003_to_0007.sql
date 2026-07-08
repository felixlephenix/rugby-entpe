-- ============================================================
-- Bundle de déploiement : migrations 0003 à 0007, à exécuter en une seule
-- fois dans Supabase SQL Editor. Enveloppé dans une transaction : si une
-- étape échoue, rien n'est appliqué (à re-tenter après correction).
-- Pré-requis : 0001_init.sql et 0002_fix_registration.sql déjà appliqués.
-- ============================================================

begin;

-- ===== 0003_roles_and_profiles.sql =====

alter table players rename to profiles;

alter table profiles
  add column first_name text not null default '',
  add column last_name text not null default '',
  add column position text,
  add column default_team text check (default_team in ('E1', 'E2')),
  add column role text not null default 'joueur'
    check (role in ('joueur', 'coach', 'bureau', 'respo_site', 'super_admin')),
  add column status text not null default 'pending'
    check (status in ('pending', 'active', 'ancien', 'banned')),
  add column former_bureau boolean not null default false;

drop function if exists claim_roster_username(text);
drop function if exists check_roster_username(text);
alter table profiles drop constraint if exists players_username_fkey;
alter table profiles drop column if exists username;
drop table if exists roster;

create or replace function is_admin(uid uuid default auth.uid())
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from profiles
    where id = uid
      and role in ('coach', 'bureau', 'super_admin')
      and status = 'active'
  );
$$;

grant execute on function is_admin(uuid) to authenticated;

create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into profiles (id, first_name, last_name, role, status)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'first_name', ''),
    coalesce(new.raw_user_meta_data->>'last_name', ''),
    'joueur',
    'pending'
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

create or replace function protect_profile_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return new;
  end if;

  if old.role = 'super_admin' then
    raise exception 'le compte super_admin est protégé et ne peut pas être modifié';
  end if;

  if not is_admin() and (
    new.role is distinct from old.role
    or new.status is distinct from old.status
    or new.former_bureau is distinct from old.former_bureau
  ) then
    raise exception 'seuls le bureau ou le super_admin peuvent modifier rôle/statut';
  end if;

  if new.role = 'super_admin' and old.role <> 'super_admin' then
    raise exception 'le rôle super_admin ne peut pas être attribué depuis l''application';
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_profile_field_permissions on profiles;
create trigger enforce_profile_field_permissions
  before update on profiles
  for each row execute function protect_profile_fields();

drop policy if exists "players are publicly readable" on profiles;

create policy "profiles readable by authenticated users"
  on profiles for select
  to authenticated
  using (true);

create policy "self or admin can update a profile"
  on profiles for update
  to authenticated
  using (id = auth.uid() or is_admin())
  with check (id = auth.uid() or is_admin());

create policy "admins can delete non protected profiles"
  on profiles for delete
  to authenticated
  using (is_admin() and role <> 'super_admin');

create policy "admins can create profiles directly (invitations)"
  on profiles for insert
  to authenticated
  with check (is_admin());

update profiles set first_name = coalesce(nullif(first_name, ''), display_name) where first_name = '';
alter table profiles drop column if exists display_name;

create or replace function get_monthly_leaderboard()
returns table(display_name text, total_points bigint)
language sql
security definer
set search_path = public
as $$
  select
    trim(p.first_name || ' ' || p.last_name) as display_name,
    coalesce(sum(pl.points), 0) as total_points
  from profiles p
  left join points_log pl
    on pl.player_id = p.id
    and pl.created_at >= date_trunc('month', now())
    and pl.created_at < date_trunc('month', now()) + interval '1 month'
  where p.status = 'active'
  group by p.id, p.first_name, p.last_name
  order by total_points desc, display_name asc;
$$;

grant execute on function get_monthly_leaderboard() to anon, authenticated;

create or replace function define_weekly_plan(week_start_date date, sessions jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  plan_id uuid;
  is_new_plan boolean;
  session jsonb;
begin
  if not exists (select 1 from profiles where id = auth.uid() and status = 'active') then
    raise exception 'compte non validé par le bureau';
  end if;

  select id into plan_id
  from weekly_plans
  where player_id = auth.uid() and week_start = week_start_date;

  is_new_plan := plan_id is null;

  if is_new_plan then
    insert into weekly_plans (player_id, week_start)
    values (auth.uid(), week_start_date)
    returning id into plan_id;
  end if;

  delete from planned_sessions where weekly_plan_id = plan_id and completed_at is null;

  for session in select * from jsonb_array_elements(sessions)
  loop
    insert into planned_sessions (weekly_plan_id, day_of_week, exercise_id, note)
    values (
      plan_id,
      (session->>'day_of_week')::smallint,
      nullif(session->>'exercise_id', '')::uuid,
      session->>'note'
    );
  end loop;

  if is_new_plan then
    insert into points_log (player_id, points, reason, reference_id)
    values (auth.uid(), 5, 'plan_defined', plan_id);
  end if;

  return plan_id;
end;
$$;

grant execute on function define_weekly_plan(date, jsonb) to authenticated;

create or replace function complete_session(session_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  owner_id uuid;
  already_done boolean;
begin
  if not exists (select 1 from profiles where id = auth.uid() and status = 'active') then
    raise exception 'compte non validé par le bureau';
  end if;

  select wp.player_id, ps.completed_at is not null
    into owner_id, already_done
  from planned_sessions ps
  join weekly_plans wp on wp.id = ps.weekly_plan_id
  where ps.id = session_id;

  if owner_id is null or owner_id <> auth.uid() then
    raise exception 'not allowed';
  end if;

  if already_done then
    return;
  end if;

  update planned_sessions set completed_at = now() where id = session_id;

  insert into points_log (player_id, points, reason, reference_id)
  values (auth.uid(), 10, 'session_completed', session_id);
end;
$$;

grant execute on function complete_session(uuid) to authenticated;

create or replace function reject_pending_profile(target_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'réservé au bureau ou au super_admin';
  end if;

  if exists (select 1 from profiles where id = target_id and role = 'super_admin') then
    raise exception 'le compte super_admin est protégé';
  end if;

  delete from auth.users where id = target_id;
end;
$$;

grant execute on function reject_pending_profile(uuid) to authenticated;

-- ===== 0004_calendar_and_news.sql =====

create table events (
  id            uuid primary key default gen_random_uuid(),
  title         text not null,
  type          text not null check (type in ('entrainement', 'match', 'extra')),
  date          date not null,
  time          time not null,
  location      text,
  teams         text[] not null default array['E1', 'E2'],
  note          text,
  status        text not null default 'active' check (status in ('active', 'cancelled')),
  cancel_reason text,
  created_by    uuid references profiles(id),
  created_at    timestamptz not null default now()
);

alter table events enable row level security;

create policy "events readable by authenticated"
  on events for select to authenticated using (true);

create policy "events writable by admins"
  on events for insert to authenticated with check (is_admin());

create policy "events updatable by admins"
  on events for update to authenticated using (is_admin()) with check (is_admin());

create policy "events deletable by admins"
  on events for delete to authenticated using (is_admin());

create table match_details (
  id                   uuid primary key default gen_random_uuid(),
  event_id             uuid not null references events(id) on delete cascade,
  opponent             text not null,
  score_home           int,
  score_away           int,
  actu_draft_generated boolean not null default false
);

alter table match_details enable row level security;

create policy "match_details readable by authenticated"
  on match_details for select to authenticated using (true);

create policy "match_details writable by admins"
  on match_details for insert to authenticated with check (is_admin());

create policy "match_details updatable by admins"
  on match_details for update to authenticated using (is_admin()) with check (is_admin());

create policy "match_details deletable by admins"
  on match_details for delete to authenticated using (is_admin());

create table event_compositions (
  id        uuid primary key default gen_random_uuid(),
  event_id  uuid not null references events(id) on delete cascade,
  player_id uuid not null references profiles(id) on delete cascade,
  team      text not null check (team in ('E1', 'E2')),
  unique (event_id, player_id)
);

alter table event_compositions enable row level security;

create policy "compositions readable by authenticated"
  on event_compositions for select to authenticated using (true);

create policy "compositions writable by admins"
  on event_compositions for insert to authenticated with check (is_admin());

create policy "compositions updatable by admins"
  on event_compositions for update to authenticated using (is_admin()) with check (is_admin());

create policy "compositions deletable by admins"
  on event_compositions for delete to authenticated using (is_admin());

create table news (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  content      text,
  status       text not null default 'draft' check (status in ('draft', 'published')),
  tag          text check (tag in ('resultat', 'annonce', 'evenement')),
  published_at timestamptz,
  event_id     uuid references events(id),
  created_by   uuid references profiles(id),
  created_at   timestamptz not null default now()
);

alter table news enable row level security;

create policy "published news readable by authenticated, drafts admin-only"
  on news for select to authenticated using (status = 'published' or is_admin());

create policy "news writable by admins"
  on news for insert to authenticated with check (is_admin());

create policy "news updatable by admins"
  on news for update to authenticated using (is_admin()) with check (is_admin());

create policy "news deletable by admins"
  on news for delete to authenticated using (is_admin());

create table news_photos (
  id           uuid primary key default gen_random_uuid(),
  news_id      uuid not null references news(id) on delete cascade,
  storage_path text not null,
  created_at   timestamptz not null default now()
);

alter table news_photos enable row level security;

create policy "news_photos readable when parent news is readable"
  on news_photos for select to authenticated
  using (
    exists (
      select 1 from news n
      where n.id = news_photos.news_id
        and (n.status = 'published' or is_admin())
    )
  );

create policy "news_photos writable by admins"
  on news_photos for insert to authenticated with check (is_admin());

create policy "news_photos deletable by admins"
  on news_photos for delete to authenticated using (is_admin());

create table member_invitations (
  id         uuid primary key default gen_random_uuid(),
  email      text not null,
  created_by uuid references profiles(id),
  token      text not null unique,
  expires_at timestamptz not null,
  used_at    timestamptz
);

alter table member_invitations enable row level security;

create policy "invitations manageable by admins"
  on member_invitations for all to authenticated
  using (is_admin())
  with check (is_admin());

create or replace function check_invitation_token(invitation_token text)
returns table(email text, valid boolean)
language sql
security definer
set search_path = public
as $$
  select email, (used_at is null and expires_at > now()) as valid
  from member_invitations
  where token = invitation_token;
$$;

grant execute on function check_invitation_token(text) to anon, authenticated;

create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  invitation_token text;
  invitation_valid boolean := false;
begin
  invitation_token := new.raw_user_meta_data->>'invitation_token';

  if invitation_token is not null then
    select (used_at is null and expires_at > now()) into invitation_valid
    from member_invitations
    where token = invitation_token;
  end if;

  insert into profiles (id, first_name, last_name, role, status)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'first_name', ''),
    coalesce(new.raw_user_meta_data->>'last_name', ''),
    'joueur',
    case when invitation_valid then 'active' else 'pending' end
  );

  if invitation_valid then
    update member_invitations set used_at = now() where token = invitation_token;
  end if;

  return new;
end;
$$;

create or replace function generate_match_result_draft()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  result_label text;
begin
  if new.score_home is not null and new.score_away is not null
     and (old.score_home is null or old.score_away is null)
     and not coalesce(old.actu_draft_generated, false) then

    result_label := case
      when new.score_home > new.score_away then 'Victoire'
      when new.score_home < new.score_away then 'Défaite'
      else 'Match nul'
    end;

    insert into news (title, status, tag, event_id, created_by)
    values (
      '[' || result_label || '] contre ' || new.opponent || ' — ' || new.score_home || '-' || new.score_away,
      'draft',
      'resultat',
      new.event_id,
      auth.uid()
    );

    new.actu_draft_generated := true;
  end if;

  return new;
end;
$$;

drop trigger if exists on_match_score_entered on match_details;
create trigger on_match_score_entered
  before update on match_details
  for each row execute function generate_match_result_draft();

-- ===== 0005_storage_and_notifications.sql =====

insert into storage.buckets (id, name, public)
values ('news-photos', 'news-photos', true)
on conflict (id) do nothing;

create policy "news photos publicly readable"
  on storage.objects for select
  using (bucket_id = 'news-photos');

create policy "news photos writable by admins"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'news-photos' and is_admin());

create policy "news photos deletable by admins"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'news-photos' and is_admin());

create table admin_notifications (
  id           uuid primary key default gen_random_uuid(),
  type         text not null,
  message      text not null,
  reference_id uuid,
  read_at      timestamptz,
  created_at   timestamptz not null default now()
);

alter table admin_notifications enable row level security;

create policy "notifications readable by admins"
  on admin_notifications for select to authenticated using (is_admin());

create policy "notifications updatable by admins"
  on admin_notifications for update to authenticated using (is_admin()) with check (is_admin());

create or replace function notify_new_signup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'pending' then
    insert into admin_notifications (type, message, reference_id)
    values ('new_signup', trim(new.first_name || ' ' || new.last_name) || ' a demandé à rejoindre le site', new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists on_new_pending_profile on profiles;
create trigger on_new_pending_profile
  after insert on profiles
  for each row execute function notify_new_signup();

create or replace function process_photo_archiving()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  photo record;
begin
  for photo in
    select * from news_photos
    where created_at <= now() - interval '3 years' + interval '14 days'
      and created_at > now() - interval '3 years' + interval '13 days'
  loop
    insert into admin_notifications (type, message, reference_id)
    values ('photo_archive_reminder', 'Photo à archiver dans 14 jours (actu ' || photo.news_id || ')', photo.id);
  end loop;

  for photo in
    select * from news_photos
    where created_at <= now() - interval '3 years' + interval '2 days'
      and created_at > now() - interval '3 years' + interval '1 day'
  loop
    insert into admin_notifications (type, message, reference_id)
    values ('photo_archive_reminder', 'Photo à archiver dans 2 jours (actu ' || photo.news_id || ')', photo.id);
  end loop;

  for photo in
    select * from news_photos where created_at <= now() - interval '3 years'
  loop
    insert into admin_notifications (type, message, reference_id)
    values ('photo_archive_due', 'Photo à supprimer maintenant (actu ' || photo.news_id || ', chemin ' || photo.storage_path || ')', photo.id);
  end loop;
end;
$$;

-- ===== 0006_admin_membres.sql =====

create extension if not exists pgcrypto;

create or replace function admin_delete_profile(target_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'réservé au bureau ou au super_admin';
  end if;

  if exists (select 1 from profiles where id = target_id and role = 'super_admin') then
    raise exception 'le compte super_admin est protégé';
  end if;

  delete from auth.users where id = target_id;
end;
$$;

grant execute on function admin_delete_profile(uuid) to authenticated;

create or replace function create_member_invitation(invite_email text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  new_token text;
begin
  if not is_admin() then
    raise exception 'réservé au bureau ou au super_admin';
  end if;

  new_token := encode(gen_random_bytes(24), 'hex');

  insert into member_invitations (email, created_by, token, expires_at)
  values (invite_email, auth.uid(), new_token, now() + interval '14 days');

  return new_token;
end;
$$;

grant execute on function create_member_invitation(text) to authenticated;

-- ===== 0007_public_calendar_and_news.sql =====

drop policy if exists "events readable by authenticated" on events;
create policy "events publicly readable"
  on events for select to anon, authenticated using (true);

drop policy if exists "match_details readable by authenticated" on match_details;
create policy "match_details publicly readable"
  on match_details for select to anon, authenticated using (true);

drop policy if exists "published news readable by authenticated, drafts admin-only" on news;
create policy "published news publicly readable, drafts admin-only"
  on news for select to anon, authenticated using (status = 'published' or is_admin());

drop policy if exists "news_photos readable when parent news is readable" on news_photos;
create policy "news_photos publicly readable when parent news is readable"
  on news_photos for select to anon, authenticated
  using (
    exists (
      select 1 from news n
      where n.id = news_photos.news_id
        and (n.status = 'published' or is_admin())
    )
  );

commit;
