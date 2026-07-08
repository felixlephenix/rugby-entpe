-- Bucket de stockage pour les photos d'actus. Public en lecture (contenu de club,
-- pas de donnée sensible), écriture réservée aux admins via policy sur storage.objects.
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

-- Notifications in-app pour le bureau (nouvelles inscriptions, rappels d'archivage photo...).
-- Les emails transactionnels personnalisés (Resend) sont laissés pour plus tard : voir spec.
create table admin_notifications (
  id         uuid primary key default gen_random_uuid(),
  type       text not null, -- 'new_signup' | 'photo_archive_reminder' | ...
  message    text not null,
  reference_id uuid,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);

alter table admin_notifications enable row level security;

create policy "notifications readable by admins"
  on admin_notifications for select to authenticated using (is_admin());

create policy "notifications updatable by admins"
  on admin_notifications for update to authenticated using (is_admin()) with check (is_admin());

-- Notifie le bureau à chaque nouvelle inscription en attente de validation.
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

-- Archivage des photos de plus de 3 ans : à exécuter chaque semaine (pg_cron).
-- J-14 et J-2 : notification in-app au bureau. J0 : suppression du fichier Storage
-- (l'entrée news et son texte restent en base, seule la photo disparaît).
-- NB : nécessite l'extension pg_cron activée (Database → Extensions dans le dashboard
-- Supabase) et l'extension pg_net pour piloter le storage API depuis SQL le cas échéant.
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

  -- La suppression effective du fichier dans Storage ne peut pas se faire en SQL pur
  -- (c'est un appel API) : cette partie doit être terminée côté application ou via
  -- une Edge Function déclenchée par ce job. Ici on se contente de repérer les lignes
  -- concernées pour ne pas bloquer le reste du schéma.
  for photo in
    select * from news_photos where created_at <= now() - interval '3 years'
  loop
    insert into admin_notifications (type, message, reference_id)
    values ('photo_archive_due', 'Photo à supprimer maintenant (actu ' || photo.news_id || ', chemin ' || photo.storage_path || ')', photo.id);
  end loop;
end;
$$;

-- Si pg_cron est activé, décommenter pour exécuter chaque lundi à 6h :
-- select cron.schedule('photo-archiving-weekly', '0 6 * * 1', 'select process_photo_archiving();');
