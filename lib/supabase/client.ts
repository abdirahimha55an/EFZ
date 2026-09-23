"use client";

import { createBrowserClient } from "@supabase/ssr";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "./database.types";

export type EfzSupabaseClient = SupabaseClient<Database>;

let browserClient: EfzSupabaseClient | null = null;

/**
 * The Supabase client for Client Components.
 *
 * Every query it makes runs as the signed-in user, so RLS (supabase/03_rls.sql)
 * is what decides which rows come back. It is safe to ship to the browser: the
 * anon key grants nothing on its own.
 *
 * Cached in module scope so React re-renders reuse one realtime connection.
 */
export function getSupabaseBrowserClient(): EfzSupabaseClient {
  if (browserClient) return browserClient;

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!url || !anonKey) {
    throw new Error(
      "Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_ANON_KEY. " +
        "Copy .env.example to .env.local and fill in your project values."
    );
  }

  browserClient = createBrowserClient<Database>(url, anonKey);
  return browserClient;
}
