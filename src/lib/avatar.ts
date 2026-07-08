import { supabase } from './supabase';

const ROLE_COLORS: Record<string, { bg: string; fg: string }> = {
  joueur: { bg: '#EEF1F9', fg: '#24336D' },
  coach: { bg: '#F9E416', fg: '#24336D' },
  bureau: { bg: '#24336D', fg: '#F9E416' },
  respo_site: { bg: '#24336D', fg: '#F9E416' },
  super_admin: { bg: '#24336D', fg: '#F9E416' },
};

function initials(firstName: string, lastName: string): string {
  const a = (firstName || '?').trim()[0] ?? '?';
  const b = (lastName || '').trim()[0] ?? '';
  return `${a}${b}`.toUpperCase();
}

export function defaultAvatarUrl(profile: { first_name: string; last_name: string; role: string }): string {
  const { bg, fg } = ROLE_COLORS[profile.role] ?? ROLE_COLORS.joueur;
  const label = initials(profile.first_name, profile.last_name);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><circle cx="50" cy="50" r="50" fill="${bg}"/><text x="50" y="52" font-family="Outfit, sans-serif" font-size="38" font-weight="500" fill="${fg}" text-anchor="middle" dominant-baseline="middle">${label}</text></svg>`;
  return `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`;
}

export function avatarUrl(profile: {
  avatar_path: string | null;
  first_name: string;
  last_name: string;
  role: string;
}): string {
  if (profile.avatar_path) {
    return supabase.storage.from('avatars').getPublicUrl(profile.avatar_path).data.publicUrl;
  }
  return defaultAvatarUrl(profile);
}
