-- Page de profil joueur (photo/bio/poste/équipe publics ; planning réservé aux
-- membres connectés, pas public).

-- Profils actifs/anciens visibles sans connexion (photo, bio, poste, équipe...).
-- Les profils pending/banned restent invisibles pour anon.
create policy "active and former players publicly readable"
  on profiles for select
  to anon
  using (status in ('active', 'ancien'));

-- N'importe quel membre connecté peut consulter le planning de n'importe quel
-- joueur (pas seulement le sien) ; anon reste exclu. Policy additive : les
-- policies "for all" existantes continuent de restreindre l'écriture au propriétaire.
create policy "authenticated can view any weekly plan"
  on weekly_plans for select
  to authenticated
  using (true);

create policy "authenticated can view any planned session"
  on planned_sessions for select
  to authenticated
  using (true);
