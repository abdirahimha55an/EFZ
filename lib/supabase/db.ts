"use client";

import { getSupabaseBrowserClient } from "./client";
import { createDb, type EfzDb } from "./queries";

let cached: EfzDb | null = null;

/**
 * The query surface for Client Components.
 *
 *   const db = getDb();
 *   const orders = await db.orders.list();
 *
 * Lazy, so importing this module never throws when the environment variables
 * are still missing - only calling it does.
 */
export function getDb(): EfzDb {
  if (!cached) cached = createDb(getSupabaseBrowserClient());
  return cached;
}

export type { EfzDb };
export { EfzDbError, describeDbError } from "./queries";
