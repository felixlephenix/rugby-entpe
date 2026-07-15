-- 0014 avait ajouté une policy RLS permettant à un admin de DELETE sur points_log
-- directement depuis le client. En pratique cette approche s'est révélée peu fiable
-- (RLS + RETURNING sur une table qui a par ailleurs une policy SELECT restrictive
-- se comporte de façon inattendue). On revient au pattern déjà utilisé partout
-- ailleurs dans ce projet pour les actions admin sensibles : une fonction
-- security definer qui vérifie is_admin() elle-même, plutôt qu'un DELETE direct
-- gouverné par RLS.
drop policy if exists "an admin can reset a player point score or all point score" on points_log;
drop policy if exists "temp_test" on points_log;

-- Réinitialise les points d'un joueur (p_player_id fourni) ou de tout le monde
-- (p_player_id null).
create or replace function reset_player_points(p_player_id uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'réservé au bureau ou au super_admin';
  end if;

  if p_player_id is null then
    delete from points_log where true;
  else
    delete from points_log where player_id = p_player_id;
  end if;
end;
$$;

grant execute on function reset_player_points(uuid) to authenticated;
