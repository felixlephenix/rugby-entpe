-- gen_random_bytes (pgcrypto) n'était pas trouvable : l'extension s'installe dans un
-- schéma ('extensions') que le search_path restreint de la fonction ('public') ne
-- voit pas. On évite la dépendance à pgcrypto : gen_random_uuid() est natif à
-- Postgres (déjà utilisé ailleurs dans le schéma) et suffit largement pour un token.
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
