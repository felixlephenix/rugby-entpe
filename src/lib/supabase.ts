import { createClient } from '@supabase/supabase-js';

const supabaseUrl = import.meta.env.PUBLIC_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.PUBLIC_SUPABASE_ANON_KEY;

export const supabase = createClient(supabaseUrl, supabaseAnonKey);

export type ProfileStatus = 'pending' | 'active' | 'ancien' | 'banned';
export type ProfileRole = 'joueur' | 'coach' | 'bureau' | 'respo_site' | 'super_admin';

export interface Profile {
  id: string;
  first_name: string;
  last_name: string;
  position: string | null;
  default_team: 'E1' | 'E2' | null;
  role: ProfileRole;
  status: ProfileStatus;
  former_bureau: boolean;
  bio: string | null;
  avatar_path: string | null;
  promo: number | null;
}

export function isAdminRole(role: ProfileRole): boolean {
  return role === 'coach' || role === 'bureau' || role === 'super_admin';
}
