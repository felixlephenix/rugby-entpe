-- role_bureau n'est qu'un intitulé de poste, contrairement à role/status/former_bureau
-- qui touchent aux permissions du compte. Pas de raison de le bloquer sur la ligne du
-- super_admin : il reste protégé par le bloc is_admin() ci-dessous (un joueur ne peut
-- toujours pas se l'auto-attribuer), juste plus par la protection spécifique au
-- super_admin qui empêchait même un admin de le modifier sur sa propre ligne.
create or replace function protect_profile_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return new;
  end if;

  if old.role = 'super_admin' and (
    new.role is distinct from old.role
    or new.status is distinct from old.status
    or new.former_bureau is distinct from old.former_bureau
  ) then
    raise exception 'le rôle/statut du compte super_admin est protégé et ne peut pas être modifié';
  end if;

  if not is_admin() and (
    new.role is distinct from old.role
    or new.status is distinct from old.status
    or new.former_bureau is distinct from old.former_bureau
    or new.role_bureau is distinct from old.role_bureau
  ) then
    raise exception 'seuls le bureau ou le super_admin peuvent modifier rôle/statut/fonction';
  end if;

  if new.role = 'super_admin' and old.role <> 'super_admin' then
    raise exception 'le rôle super_admin ne peut pas être attribué depuis l''application';
  end if;

  return new;
end;
$$;
