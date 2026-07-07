-- La policy d'insertion sur players référence roster via une sous-requête, mais roster
-- a RLS activée sans policy SELECT : la sous-requête ne voit donc jamais aucune ligne
-- et l'insertion échoue systématiquement. On déplace la logique d'inscription dans une
-- fonction SECURITY DEFINER qui contourne proprement les deux RLS.
create or replace function claim_roster_username(uname text)
returns players
language plpgsql
security definer
set search_path = public
as $$
declare
  roster_display_name text;
  new_player players;
begin
  select display_name into roster_display_name from roster where username = uname;

  if roster_display_name is null then
    raise exception 'username not in roster';
  end if;

  if exists (select 1 from players where username = uname) then
    raise exception 'username already claimed';
  end if;

  insert into players (id, username, display_name)
  values (auth.uid(), uname, roster_display_name)
  returning * into new_player;

  return new_player;
end;
$$;

grant execute on function claim_roster_username(text) to authenticated;
