-- Bio + photo de profil, éditables par le joueur lui-même sur "Mon profil".
alter table profiles
  add column bio text,
  add column avatar_path text;

-- Bucket public en lecture (photos de profil, pas de donnée sensible), écriture
-- limitée à son propre dossier (chemin préfixé par l'uid de l'utilisateur).
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

create policy "avatars publicly readable"
  on storage.objects for select
  using (bucket_id = 'avatars');

create policy "a user can upload their own avatar"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "a user can update their own avatar"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "a user can delete their own avatar"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
