-- Calendrier, actus, invitations manuelles. Voir spec "Site Rugby ENTPE" (juillet 2026).

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
-- Max 3 photos par actu : vérifié côté application avant insert.

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

-- Un candidat non authentifié doit pouvoir vérifier la validité de son lien
-- d'invitation avant même d'avoir un compte, sans exposer toute la table.
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

-- Ré-écrit handle_new_user (défini en 0003) pour tenir compte d'une invitation valide :
-- un compte créé via un lien d'invitation du bureau est directement actif, sans
-- passer par la validation manuelle.
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

-- Génère automatiquement un brouillon d'actu résultat quand le bureau saisit le score.
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
