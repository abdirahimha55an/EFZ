// Writes supabase/production/release_manifest.json: the ordered migration files of each release phase, their SHA-256 (bytes as stored, LF) and the object markers
// used to prove "not applied yet" / "applied". run_release_phase.ps1 refuses any file whose hash differs from this manifest.
// Usage: node scripts/make_release_manifest.mjs         (write)    node scripts/make_release_manifest.mjs --check   (fail if stale)
import fs from "node:fs"; import crypto from "node:crypto"; import path from "node:path";
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1")), "..");
const q = (s) => s.replace(/\s+/g, " ").trim();
const col = (t, c) => `exists(select 1 from information_schema.columns where table_schema='public' and table_name='${t}' and column_name='${c}')`;
const f = (name, post) => ({ file: name, post: q(post) });
const phases = {
  A: [
    f("19_website_request_delegation.sql", "to_regprocedure('public.assign_order_request(uuid,text)') is not null"),
    f("19b_permission_change_audit.sql", "to_regprocedure('public.log_permission_changes()') is not null"),
    f("21_customer_accounts.sql", "to_regclass('public.customer_accounts') is not null"),
    f("22_customer_ordering.sql", "to_regclass('public.customer_order_requests') is not null"),
    f("23_customer_checkout_credit.sql", "to_regclass('public.customer_checkouts') is not null"),
    f("24_credit_policy_refinement.sql", col("credit_policy", "min_approved_days")),
    f("25_credit_policy_v2.sql", col("credit_policy", "company_cap_percent")),
    f("26_customer_price_agreements.sql", "to_regclass('public.customer_price_agreements') is not null"),
    f("27_price_policy_no_expiry.sql", "md5(replace(pg_get_functiondef('public.create_order(jsonb)'::regprocedure), chr(13), '')) = '265e9745acb9418787e6d8cebfb450af'"),
    f("28_convert_request_designs.sql", "position('migration 28 marker' in pg_get_functiondef('public.convert_website_request(uuid,jsonb)'::regprocedure)) > 0"),
    f("29a_dispatch_enum.sql", `${col("orders", "dispatched_at")} and exists(select 1 from pg_enum e join pg_type t on t.oid=e.enumtypid where t.typname='order_status' and e.enumlabel='dispatched')`),
    f("production/29b_dispatch_and_live_orders.crtolerant.sql", "(select md5(prosrc) from pg_proc where pronamespace='public'::regnamespace and proname='update_order_status') = 'cb9a5600965a3f0a89c2bf7aff3e708a'"),
    f("29c_order_details_dispatched.sql", col("order_details", "dispatched_at")),
    f("29d_live_orders_topic_by_user.sql", "true"), // no unique marker; the 29d effect is covered by the final preflight
  ],
  C: [
    f("production/29e_enforce_dispatch.crtolerant.sql", "(select md5(prosrc) from pg_proc where pronamespace='public'::regnamespace and proname='update_order_status') = 'e6548ff6bf1de8d5dfc7ed67343aa0fa'"),
  ],
};
const sup = path.join(root, "supabase");
const out = { generated_by: "scripts/make_release_manifest.mjs", phases: {} };
for (const [p, list] of Object.entries(phases)) out.phases[p] = list.map((e) => {
  const b = fs.readFileSync(path.join(sup, e.file));
  if (b.includes(13)) throw new Error(`${e.file} contains CR bytes; the release files must be LF`);
  return { file: e.file, sha256: crypto.createHash("sha256").update(b).digest("hex"), post: e.post, post_is_unique: e.post !== "true" };
});
const text = JSON.stringify(out, null, 2) + "\n";
const dest = path.join(sup, "production", "release_manifest.json");
if (process.argv.includes("--check")) { const cur = fs.existsSync(dest) ? fs.readFileSync(dest, "utf8") : ""; console.log(cur === text ? "manifest current" : "manifest STALE"); process.exit(cur === text ? 0 : 1); }
fs.writeFileSync(dest, text); console.log("wrote", path.relative(root, dest), Object.values(out.phases).flat().length, "files");
