import { createSupabaseAdminClient } from "./admin";
import { createSupabaseServerClient } from "./server";
import { createDb, type EfzDb } from "./queries";

/**
 * The query surface for Server Components, Server Actions and Route Handlers.
 * Builds a fresh client per call, so sessions never bleed between requests.
 *
 *   const db = await getServerDb();
 *   const products = await db.products.listPublic();
 */
export async function getServerDb(): Promise<EfzDb> {
  return createDb(await createSupabaseServerClient());
}

/**
 * Query surface that bypasses RLS. For trusted server-side jobs only -
 * imports, scheduled backups, repair scripts. Never call this from anything
 * that renders for a visitor.
 */
export function getAdminDb(): EfzDb {
  return createDb(createSupabaseAdminClient());
}

export type { EfzDb };
export { EfzDbError } from "./queries";
