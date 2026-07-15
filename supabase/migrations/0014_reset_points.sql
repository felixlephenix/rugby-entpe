-- Permet à un admin de réinitialiser les points d'un joueur (ou de tout le monde,
-- si le JS appelle delete() sans filtre sur player_id) en supprimant les lignes
-- de points_log. Une simple policy RLS suffit : on ne touche qu'une seule table,
-- pas besoin d'une fonction security definer ici.
create policy "an admin can reset a player point score or all point score"
  on points_log for delete
  to authenticated
  using (is_admin());
