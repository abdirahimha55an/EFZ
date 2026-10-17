// Supabase Edge Function entry point (Deno). NOT deployed by this repository's workflow yet - see README.md.
// Secrets come from the function's own environment (supabase secrets set ...), never from the repo or the app:
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY   injected by Supabase for every Edge Function
//   REGISTRATION_HINT_SALT                    random string you create and set once
//   REGISTRATION_REQUIRE_EMAIL_VERIFICATION   optional, "true" once custom SMTP + the code email template exist (default off)
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { handleRegistration } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL");
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const hintSalt = Deno.env.get("REGISTRATION_HINT_SALT");

if (!url || !serviceKey || !hintSalt) {
  // Fail closed: without all three the function answers 500 and never creates anything.
  Deno.serve(() => new Response(JSON.stringify({ error: "Registration is unavailable right now" }), { status: 500, headers: { "content-type": "application/json" } }));
} else {
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const sha256 = async (s: string) => {
    const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
    return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
  };
  Deno.serve((req) =>
    handleRegistration(req, {
      rpc: (fn, args) => admin.rpc(fn, args) as never,
      createUser: (attrs) => admin.auth.admin.createUser(attrs) as never,
      deleteUser: (id) => admin.auth.admin.deleteUser(id),
      sha256,
      hintSalt,
      requireEmailVerification: Deno.env.get("REGISTRATION_REQUIRE_EMAIL_VERIFICATION") === "true",
    }),
  );
}
