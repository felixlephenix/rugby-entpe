-- Roster : liste des noms d'utilisateur autorisés à créer un compte, gérée par le coach.
create table roster (
  username text primary key,
  display_name text not null,
  category text,
  created_at timestamptz not null default now()
);

alter table roster enable row level security;
-- Pas de policy SELECT/INSERT publique : l'accès passe uniquement par la fonction
-- is_username_available ci-dessous, pour ne pas exposer la liste complète des joueurs.

-- Joueurs inscrits, un par utilisateur Supabase Auth.
create table players (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique references roster(username),
  display_name text not null,
  created_at timestamptz not null default now()
);

alter table players enable row level security;

create policy "players are publicly readable"
  on players for select
  using (true);

create policy "a player can self-register with a valid roster username"
  on players for insert
  to authenticated
  with check (
    id = auth.uid()
    and exists (select 1 from roster r where r.username = players.username)
  );

-- Catalogue d'exercices (rempli plus tard avec la vraie liste transmise par le coach).
create table exercises (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null, -- 'cardio' | 'muscu' | 'mobilite'
  description text,
  created_at timestamptz not null default now()
);

alter table exercises enable row level security;

create policy "exercises are publicly readable"
  on exercises for select
  using (true);

-- Planning hebdomadaire : un par joueur et par semaine (date du lundi).
create table weekly_plans (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id) on delete cascade,
  week_start date not null,
  created_at timestamptz not null default now(),
  unique (player_id, week_start)
);

alter table weekly_plans enable row level security;

create policy "a player manages their own weekly plans"
  on weekly_plans for all
  to authenticated
  using (player_id = auth.uid())
  with check (player_id = auth.uid());

-- Séances planifiées à l'intérieur d'une semaine.
create table planned_sessions (
  id uuid primary key default gen_random_uuid(),
  weekly_plan_id uuid not null references weekly_plans(id) on delete cascade,
  day_of_week smallint not null check (day_of_week between 1 and 7), -- 1 = lundi
  exercise_id uuid references exercises(id),
  note text,
  completed_at timestamptz,
  created_at timestamptz not null default now()
);

alter table planned_sessions enable row level security;

create policy "a player manages sessions of their own weekly plans"
  on planned_sessions for all
  to authenticated
  using (
    exists (
      select 1 from weekly_plans wp
      where wp.id = planned_sessions.weekly_plan_id
        and wp.player_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from weekly_plans wp
      where wp.id = planned_sessions.weekly_plan_id
        and wp.player_id = auth.uid()
    )
  );

-- Historique des points. Écriture réservée aux fonctions ci-dessous (SECURITY DEFINER),
-- jamais directement par le client, pour éviter qu'un joueur ne s'attribue des points.
create table points_log (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id) on delete cascade,
  points integer not null,
  reason text not null, -- 'plan_defined' | 'session_completed'
  reference_id uuid,
  created_at timestamptz not null default now()
);

alter table points_log enable row level security;

create policy "a player can read their own points history"
  on points_log for select
  to authenticated
  using (player_id = auth.uid());

-- ============================================================
-- Fonctions
-- ============================================================

-- Vérifie si un nom d'utilisateur est dans le roster et pas encore réclamé, et renvoie
-- le nom d'affichage associé, sans exposer la liste complète du roster à un utilisateur anonyme.
create or replace function check_roster_username(uname text)
returns table(available boolean, display_name text)
language sql
security definer
set search_path = public
as $$
  select
    exists (select 1 from roster r where r.username = uname)
      and not exists (select 1 from players p where p.username = uname) as available,
    (select r.display_name from roster r where r.username = uname) as display_name;
$$;

grant execute on function check_roster_username(text) to anon, authenticated;

-- Définit le planning de la semaine courante et attribue +5 points (une seule fois par semaine).
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

-- Marque une séance planifiée comme faite et attribue +10 points (idempotent).
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

-- Classement du mois en cours, public (utilisé sur la page d'accueil).
create or replace function get_monthly_leaderboard()
returns table(display_name text, total_points bigint)
language sql
security definer
set search_path = public
as $$
  select p.display_name, coalesce(sum(pl.points), 0) as total_points
  from players p
  left join points_log pl
    on pl.player_id = p.id
    and pl.created_at >= date_trunc('month', now())
    and pl.created_at < date_trunc('month', now()) + interval '1 month'
  group by p.display_name
  order by total_points desc, p.display_name asc;
$$;

grant execute on function get_monthly_leaderboard() to anon, authenticated;
