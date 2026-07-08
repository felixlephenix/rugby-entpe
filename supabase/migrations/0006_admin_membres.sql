-- Support pour le module admin "Membres" : suppression définitive de compte,
-- et création d'invitations manuelles (fallback quand le bureau crée un compte
-- directement plutôt que d'attendre une auto-inscription).

create or replace function admin_delete_profile(target_id uuid)
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

grant execute on function admin_delete_profile(uuid) to authenticated;

-- Crée une invitation et renvoie son token (à transmettre manuellement au joueur
-- tant qu'aucun service d'emailing transactionnel n'est branché).
create or replace function create_member_invitation(invite_email text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  new_token text;
begin
  if not is_admin() then
    raise exception 'réservé au bureau ou au super_admin';
  end if;

  new_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');

  insert into member_invitations (email, created_by, token, expires_at)
  values (invite_email, auth.uid(), new_token, now() + interval '14 days');

  return new_token;
end;
$$;

grant execute on function create_member_invitation(text) to authenticated;
