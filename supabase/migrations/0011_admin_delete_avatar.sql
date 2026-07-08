-- Permet à un admin de supprimer la photo de profil de n'importe quel utilisateur
-- (jusqu'ici seul le propriétaire du dossier pouvait supprimer son propre avatar).
create policy "admins can delete any avatar"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'avatars' and is_admin());
