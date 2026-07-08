-- Le trigger protect_profile_fields bloquait TOUTE modification de la ligne
-- super_admin, y compris par le titulaire du compte lui-même sur des champs anodins
-- (poste, équipe). On ne protège plus que rôle/statut/former_bureau sur cette ligne,
-- pas le reste du profil.
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
  ) then
    raise exception 'seuls le bureau ou le super_admin peuvent modifier rôle/statut';
  end if;

  if new.role = 'super_admin' and old.role <> 'super_admin' then
    raise exception 'le rôle super_admin ne peut pas être attribué depuis l''application';
  end if;

  return new;
end;
$$;
