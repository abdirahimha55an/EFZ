// Supabase Edge Function entry point (Deno). Deploy with --no-verify-jwt (a provider calls it, not a signed-in user): the adapter authenticates the call.
// Secrets come from the function's own environment, never from the repo or the app:
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY   injected by Supabase
// No provider adapter is registered: every method answers 501 until one is written, reviewed and added to `adapters` below.
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { handlePaymentConfirmation, type ProviderAdapter } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL");
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

// One entry per configured payment method code, e.g.  evc: evcAdapter   (does not exist yet; needs the provider's credentials and documentation).
const adapters: Record<string, ProviderAdapter> = {};

if (!url || !serviceKey) {
  Deno.serve(() => new Response(JSON.stringify({ error: "Payments are unavailable right now" }), { status: 500, headers: { "content-type": "application/json" } }));
} else {
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const sha256 = async (s: string) => {
    const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
    return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
  };
  Deno.serve((req) => handlePaymentConfirmation(req, { adapters, rpc: (fn, args) => admin.rpc(fn, args) as never, sha256 }));
}
