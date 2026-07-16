alter table profiles
  add column if not exists role_bureau text;

alter table profiles
  drop constraint if exists role_bureau_check;

alter table profiles
  add constraint role_bureau_check
  check (role_bureau in ('capitaine_e1', 'capitaine_e2', 'respo'));

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
    or new.role_bureau is distinct from old.role_bureau
  ) then
    raise exception 'le rôle/statut du compte super_admin est protégé et ne peut pas être modifié';
  end if;

  if not is_admin() and (
    new.role is distinct from old.role
    or new.status is distinct from old.status
    or new.former_bureau is distinct from old.former_bureau
    or new.role_bureau is distinct from old.role_bureau
  ) then
    raise exception 'seuls le bureau ou le super_admin peuvent modifier rôle/statut';
  end if;

  if new.role = 'super_admin' and old.role <> 'super_admin' then
    raise exception 'le rôle super_admin ne peut pas être attribué depuis l''application';
  end if;

  return new;
end;
$$;