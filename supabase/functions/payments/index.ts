// Supabase Edge Function entry point (Deno). Deploy with --no-verify-jwt: the provider's callback has no Supabase token; /start and /status read the
// customer's own token from the Authorization header and the database checks it, and the callback body is never trusted (see handler.ts).
//
// Secrets (set with `supabase secrets set`, never in the repo or the app). Without the secrets of a provider that provider's adapter is simply absent
// and every route for it answers 501:
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY            injected by Supabase
//   PAYMENTS_PUBLIC_URL                                                    the public URL of THIS function, e.g. https://<ref>.supabase.co/functions/v1/payments
//   WAAFIPAY_API_URL, WAAFIPAY_MERCHANT_UID, WAAFIPAY_STORE_ID, WAAFIPAY_HPP_KEY     EVC Plus through WaafiPay HPP (from WaafiPay at onboarding)
//   EDAHAB_API_KEY, EDAHAB_API_SECRET, EDAHAB_AGENT_CODE                   eDahab merchant API (from the eDahab dashboard)
//   EDAHAB_BASE_URL (optional), EDAHAB_NUMBER_FORMAT (optional: "international" default, or "local")
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { handlePayments, type ProviderAdapter } from "./handler.ts";
import { waafiPayAdapter } from "./adapters/waafipay.ts";
import { edahabAdapter } from "./adapters/edahab.ts";

const env = (k: string) => Deno.env.get(k) ?? "";
const url = env("SUPABASE_URL"), serviceKey = env("SUPABASE_SERVICE_ROLE_KEY"), anonKey = env("SUPABASE_ANON_KEY"), baseUrl = env("PAYMENTS_PUBLIC_URL");
const sha256Hex = async (s: string) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))].map((b) => b.toString(16).padStart(2, "0")).join("");

const adapters: Record<string, ProviderAdapter> = {};
if (env("WAAFIPAY_API_URL") && env("WAAFIPAY_MERCHANT_UID") && env("WAAFIPAY_STORE_ID") && env("WAAFIPAY_HPP_KEY")) {
  adapters["evc_plus"] = waafiPayAdapter({ apiUrl: env("WAAFIPAY_API_URL"), merchantUid: env("WAAFIPAY_MERCHANT_UID"), storeId: env("WAAFIPAY_STORE_ID"), hppKey: env("WAAFIPAY_HPP_KEY") });
}
if (env("EDAHAB_API_KEY") && env("EDAHAB_API_SECRET") && env("EDAHAB_AGENT_CODE")) {
  adapters["edahab"] = edahabAdapter({ apiKey: env("EDAHAB_API_KEY"), apiSecret: env("EDAHAB_API_SECRET"), agentCode: env("EDAHAB_AGENT_CODE"), baseUrl: env("EDAHAB_BASE_URL") || undefined, numberFormat: env("EDAHAB_NUMBER_FORMAT") === "local" ? "local" : "international", sha256Hex });
}

if (!url || !serviceKey || !anonKey || !baseUrl) {
  Deno.serve(() => new Response(JSON.stringify({ error: "Payments are unavailable right now" }), { status: 500, headers: { "content-type": "application/json" } }));
} else {
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  Deno.serve((req) => handlePayments(req, {
    adapters, baseUrl,
    adminRpc: (fn, args) => admin.rpc(fn, args) as never,
    userRpc: (token, fn, args) => createClient(url, anonKey, { global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false, autoRefreshToken: false } }).rpc(fn, args) as never,
    now: () => Date.now(),
  }));
}
