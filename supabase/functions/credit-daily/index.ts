// Trigger for the daily credit run (see handler.ts). Deploy with --no-verify-jwt; the shared secret CREDIT_CRON_SECRET is the credential.
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { handleCreditDaily } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL") ?? "";
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const admin = url && serviceKey ? createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } }) : null;

Deno.serve((req) =>
  handleCreditDaily(req, {
    secret: Deno.env.get("CREDIT_CRON_SECRET"),
    run: async () => (admin ? ((await admin.rpc("credit_daily_run")) as never) : { data: null, error: { message: "not configured" } }),
    // migration 27 (price expiry notices); until it is applied the call fails harmlessly and priceNoticesSent is null
    runPrices: async () => (admin ? ((await admin.rpc("price_daily_run")) as never) : { data: null, error: { message: "not configured" } }),
  }),
);
