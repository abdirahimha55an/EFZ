import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "./database.types";
import { getSupabasePublicEnv, MISSING_SUPABASE_ENV } from "./env";

export type EfzSupabaseClient = SupabaseClient<Database>;

export async function createSupabaseServerClient(): Promise<EfzSupabaseClient> {
  const { url, key } = getSupabasePublicEnv();

  if (!url || !key) {
    throw new Error(MISSING_SUPABASE_ENV);
  }

  const cookieStore = await cookies();

  return createServerClient<Database>(url, key, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },

      setAll(cookiesToSet) {
        try {
          for (const { name, value, options } of cookiesToSet) {
            cookieStore.set(name, value, options);
          }
        } catch {
          // Server Components cannot set cookies.
        }
      },
    },
  });
}