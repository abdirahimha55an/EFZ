/**
 * The public Supabase settings, read in one place for the browser client, the
 * server client and the proxy, so the three can never disagree.
 *
 * Supabase now issues "publishable" keys; older projects use the "anon" key.
 * @supabase/ssr accepts either. NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY is used
 * when it is set; otherwise NEXT_PUBLIC_SUPABASE_ANON_KEY, so an environment
 * that only has the anon key keeps working exactly as before.
 *
 * Each variable is written out by its full literal name on purpose: Next.js
 * only inlines NEXT_PUBLIC_ values into browser code when referenced this way.
 */
export function getSupabasePublicEnv(): { url: string | undefined; key: string | undefined } {
  return {
    url: process.env.NEXT_PUBLIC_SUPABASE_URL || undefined,
    key:
      process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ||
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ||
      undefined,
  };
}

export const MISSING_SUPABASE_ENV =
  "Missing NEXT_PUBLIC_SUPABASE_URL, or a key in NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY / NEXT_PUBLIC_SUPABASE_ANON_KEY.";
