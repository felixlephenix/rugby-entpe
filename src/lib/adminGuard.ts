import { supabase, isAdminRole, type Profile } from './supabase';
import { url } from './paths';

export async function requireAdmin(): Promise<Profile | null> {
  const { data: sessionData } = await supabase.auth.getSession();
  if (!sessionData.session) {
    window.location.href = url('/connexion');
    return null;
  }

  const { data: profile } = await supabase
    .from('profiles')
    .select('*')
    .eq('id', sessionData.session.user.id)
    .single();

  if (!profile || profile.status !== 'active' || !isAdminRole(profile.role)) {
    window.location.href = url('/profil');
    return null;
  }

  return profile as Profile;
}
