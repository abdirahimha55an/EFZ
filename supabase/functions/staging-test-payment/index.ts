// STAGING ONLY. Enabled only when STAGING_TEST_PAYMENTS=true AND the project is the EFZ Staging project; otherwise it answers 404. Never deploy to Production.
// Deploy with --no-verify-jwt is NOT needed: the handler reads the caller's own token and passes it to the database.
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { handleTestPayment } from "./handler.ts";

const STAGING_REF = "adjjamiqwboawqedaapi";
const url = Deno.env.get("SUPABASE_URL") ?? "";
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const enabled = Deno.env.get("STAGING_TEST_PAYMENTS") === "true" && url.includes(STAGING_REF) && !!serviceKey && !!anonKey;

const admin = enabled ? createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } }) : null;
Deno.serve((req) =>
  handleTestPayment(req, {
    enabled,
    userRpc: (token, fn, args) => createClient(url, anonKey, { global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false, autoRefreshToken: false } }).rpc(fn, args) as never,
    adminRpc: (fn, args) => (admin as NonNullable<typeof admin>).rpc(fn, args) as never,
    newId: () => crypto.randomUUID(),
  }),
);
