-- Remplace le système "username pré-approuvé via roster" par un système de comptes
-- email + mot de passe avec statut (pending/active/ancien/banned) et rôles.
-- La table players devient profiles, enrichie. Les FK existantes (weekly_plans,
-- points_log) pointent déjà vers players(id) : le rename les préserve automatiquement.

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

-- L'ancien système de gating par roster n'a plus lieu d'être : l'inscription est
-- désormais ouverte (email + mot de passe), validée a posteriori par le bureau.
drop function if exists claim_roster_username(text);
drop function if exists check_roster_username(text);
alter table profiles drop constraint if exists players_username_fkey;
alter table profiles drop column if exists username;
drop table if exists roster;

-- ============================================================
-- Rôles
-- ============================================================

-- true si l'utilisateur a un rôle avec accès admin et un compte actif.
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

-- Création automatique du profil à l'inscription (email + mot de passe), en attente
-- de validation par le bureau. Le prénom/nom sont passés via les metadata du signUp.
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

-- Empêche un joueur de s'auto-attribuer un rôle/statut, et protège le compte
-- super_admin de toute modification, y compris par un autre admin.
-- N'est appliqué que pour les requêtes passant par l'API (auth.uid() renseigné) :
-- une modification directe en SQL Editor (auth.uid() null) reste possible, c'est
-- le mécanisme prévu par le spec pour désigner le super_admin "directement en base".
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

-- ============================================================
-- RLS sur profiles
-- ============================================================

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

-- Le profil lui-même est créé par le trigger handle_new_user (SECURITY DEFINER),
-- pas par le client : pas de policy INSERT nécessaire pour les utilisateurs normaux.
create policy "admins can create profiles directly (invitations)"
  on profiles for insert
  to authenticated
  with check (is_admin());

-- ============================================================
-- Mise à jour des objets qui référençaient l'ancien schéma (players.display_name)
-- ============================================================

-- display_name n'existe plus dans le nouveau spec (first_name/last_name à la place).
update profiles set first_name = coalesce(nullif(first_name, ''), display_name) where first_name = '';
alter table profiles drop column if exists display_name;

-- Classement public : uniquement les comptes actifs, nom complet reconstruit.
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

-- Le suivi d'entraînement (plan + check-off) est réservé aux comptes validés (status = 'active').
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

-- Rejet d'une inscription en attente : supprime le compte auth (cascade sur profiles).
-- L'approbation, elle, passe par un simple update de profiles.status (déjà autorisé par RLS).
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
