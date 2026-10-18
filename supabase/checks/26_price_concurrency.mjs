// Concurrent behaviour of customer price agreements (migration 26). Needs REAL parallel database sessions, so it cannot live inside the single-transaction SQL suite.
// Run against a DISPOSABLE LOCAL database that already has migrations 21..26 (it COMMITS its own fixtures; never point it at Staging or Production):
//   node supabase/checks/26_price_concurrency.mjs <database> [host] [port] [user]
// Environment: PSQL = path to psql (default "psql"). A password, if the server needs one, is read from PGPASSWORD (the usual libpq way).
import { spawn, spawnSync } from "node:child_process";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [db, host = "127.0.0.1", port = "54399", user = "postgres"] = process.argv.slice(2);
if (!db) { console.error("usage: node 26_price_concurrency.mjs <database> [host] [port] [user]"); process.exit(2); }
if (!/^(localhost|127\.0\.0\.1)$/.test(host)) { console.error("refusing to run: this test commits fixtures and is for a local disposable database only"); process.exit(2); }
const PSQL = process.env.PSQL || "psql";
const base = ["-X", "-q", "-A", "-t", "-h", host, "-p", port, "-U", user, "-d", db];
const dir = mkdtempSync(join(tmpdir(), "efz-conc26-"));
const sql = (text, extra = []) => { const f = join(dir, "s" + Math.random().toString(36).slice(2) + ".sql"); writeFileSync(f, text); return spawnSync(PSQL, [...base, "-v", "ON_ERROR_STOP=1", ...extra, "-f", f], { encoding: "utf8" }); };
const q = (text) => sql(text).stdout.trim();

const SA = "a6100000-0000-4000-8000-000000000001", MGR = "a6100000-0000-4000-8000-000000000002", MGR2 = "a6100000-0000-4000-8000-000000000003";
const CA = "c6100000-0000-4000-8000-00000000000a";
const as = (sub, role) => `select set_config('request.jwt.claims', '${JSON.stringify(sub ? { sub, role } : { role })}', false); set role ${role};`;

const setup = `
-- the disposable database may already hold orders: neutralise them so the report below is exact
alter table public.orders disable trigger user; update public.orders set status = 'cancelled' where status <> 'cancelled'; alter table public.orders enable trigger user;
insert into public.profiles (id, name, email, role, status) values ('u-t26c-sa', 'T26C Super Admin', 't26c-sa@example.test', 'Super Admin', 'active'), ('u-t26c-mgr', 'T26C Manager', 't26c-mgr@example.test', 'Manager', 'active'), ('u-t26c-mgr2', 'T26C Manager 2', 't26c-mgr2@example.test', 'Manager', 'active');
insert into public.user_permissions (user_id, permission_code) values ('u-t26c-mgr', 'manage_customer_accounts'), ('u-t26c-mgr', 'view_all_customers'), ('u-t26c-mgr2', 'view_all_customers');
insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
  ('${SA}', 'authenticated', 'authenticated', 't26c-sa@example.test', now(), '{"provider":"email"}', '{}', now(), now()), ('${MGR}', 'authenticated', 'authenticated', 't26c-mgr@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
  ('${MGR2}', 'authenticated', 'authenticated', 't26c-mgr2@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
  ('${CA}', 'authenticated', 'authenticated', 't26c-a@example.test', now(), '{"provider":"email","efz_kind":"customer"}', '{}', now(), now());
insert into public.products (id, name, selling_price, cost_price, stock, is_active) values ('p26c-a', 'T26C Ball', 10, 6, 1000000, true);
insert into public.product_designs (id, product_id, name, sort_order, is_active) values ('d2610000-0000-4000-8000-000000000001', 'p26c-a', 'Red', 1, true), ('d2610000-0000-4000-8000-000000000002', 'p26c-a', 'Blue', 2, true);
insert into public.customers (id, name, email, phone, notes, status) values ('cust-t26c-h1', 'T26C History 1', 'h1@example.test', '069 826 1001', 'h', 'active'), ('cust-t26c-h2', 'T26C History 2', 'h2@example.test', '069 826 1002', 'h', 'active');
-- history for the import race: two customers with a consistent negotiated price (3 orders each)
${["h1", "h2"].map((h, i) => [1, 2, 3].map((n) => `insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) values ('ORD-T26C-${h}-${n}', 'cust-t26c-${h}', 'T26C', '', 'delivered', 'regular', public.efz_today() - ${n * 10}, '');
insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost) values ('itm-t26c-${h}-${n}', 'ORD-T26C-${h}-${n}', 'p26c-a', 'T', 'T26C Ball', 1, 10, ${7 + i}, 1);`).join("\n")).join("\n")}
${as(null, "service_role")}
select public.register_customer_account('${CA}', 't26c-a@example.test', 'T26C A', '069 826 1000', '', null);
reset role;
${as(MGR, "authenticated")}
select public.approve_customer_account(id, null, true, false, 'Verified (T26C)') from public.customer_accounts where email = 't26c-a@example.test';
reset role;
${as(SA, "authenticated")}
select public.set_payment_method('stg_test', 'Staging Test', 'staging_test', true, 'Staging test method (T26C)');
reset role;
-- a test helper: the id of a customer's active agreement (the agreements table is closed to every client role)
create or replace function public.t26c_active(p_customer text) returns uuid language sql security definer set search_path = public as $f$ select id from public.customer_price_agreements where customer_id = p_customer and product_id = 'p26c-a' and design_id is null and status = 'active' $f$;
grant execute on function public.t26c_active(text) to authenticated;
`;
const r0 = sql(setup);
if (r0.status !== 0) { console.error("fixture setup failed:\n" + r0.stderr); process.exit(2); }
const custA = q(`select customer_id from public.customer_accounts where email = 't26c-a@example.test'`);
{ const r = sql(`${as(MGR, "authenticated")}\nselect public.create_price_agreement('${custA}', 'p26c-a', null, 8.00, public.efz_today() - 1, null, 'Starting price for the concurrency test');`); if (r.status !== 0) { console.error("agreement setup failed:\n" + r.stderr); process.exit(2); } }

const results = []; const t = (name, ok, detail = "") => { results.push(ok); console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : "   [" + String(detail).slice(0, 300) + "]"}`); };
const AT = () => new Date(Date.now() + 3500).toISOString();
const session = (job, at) => new Promise((res) => {
  const f = join(dir, "j" + Math.random().toString(36).slice(2) + ".sql");
  writeFileSync(f, `${as(job.sub, job.role)}\nselect pg_sleep(greatest(0, extract(epoch from (timestamptz '${at}' - clock_timestamp()))));\n${job.sql}`);
  const p = spawn(PSQL, [...base, "-f", f]); let out = "", err = "";
  p.stdout.on("data", (d) => (out += d)); p.stderr.on("data", (d) => (err += d)); p.on("close", () => res({ out: out.trim().split("\n").filter(Boolean), err: err.trim() }));
});
const parallel = (jobs) => { const at = AT(); return Promise.all(jobs.map((j) => session(j, at))); };
const lines = (n) => `'[{"productId":"p26c-a","designId":"d2610000-0000-4000-8000-000000000001","quantity":${n}},{"productId":"p26c-a","designId":"d2610000-0000-4000-8000-000000000002","quantity":${n}}]'::jsonb`;

// 1. the price-change storm: the Manager changes the price 40 times (8 <-> 6, atomically) while readers price carts and customers start and cancel checkouts
const storm = { sub: MGR, role: "authenticated", sql: Array.from({ length: 40 }, (_, i) => `select public.replace_price_agreement(public.t26c_active('${custA}'), ${i % 2 === 0 ? "6.00" : "8.00"}, public.efz_today(), null, 'Price change number ${i + 1} in the concurrency storm');`).join("\n") };
const reader = { sub: CA, role: "authenticated", sql: Array.from({ length: 50 }, () => `select (p -> 'lines' -> 0 ->> 'unitPrice') || '|' || (p -> 'lines' -> 1 ->> 'unitPrice') || '|' || (p ->> 'total') from (select public.customer_price_preview(${lines(2)}) as p) s;`).join("\n") };
const rs = await parallel([storm, reader, reader, reader, { sub: CA, role: "authenticated", sql: Array.from({ length: 5 }, (_, i) => `select 'CK|' || (c ->> 'checkoutId') || '|' || (c ->> 'amount') from (select public.customer_start_checkout('{"methodCode":"stg_test","deliveryLocation":"Hodan","submissionKey":"f2610000-0000-4000-8000-0000000001${String(i).padStart(2, "0")}","lines":[{"productId":"p26c-a","designId":"d2610000-0000-4000-8000-000000000001","quantity":3},{"productId":"p26c-a","designId":"d2610000-0000-4000-8000-000000000002","quantity":2}]}'::jsonb) c) s;`).join("\n") }]);
const previews = rs.slice(1, 4).flatMap((r) => r.out.filter((l) => /^\d/.test(l)));
t("price-change storm: 40 atomic price changes, 150 simultaneous cart pricings: every one is 8.00 or 6.00 (never the 10.00 list price, never missing, never an error)", previews.length === 150 && previews.every((l) => { const [a, b] = l.split("|"); return ["8.00", "6.00"].includes(a) && ["8.00", "6.00"].includes(b); }), `${previews.length} answers; odd: ${previews.filter((l) => !/^(8|6)\.00\|(8|6)\.00\|/.test(l)).slice(0, 3).join(" ; ")} ${rs.map((r) => r.err.slice(0, 80)).join(" | ")}`);
t("each cart total equals the sum of its own two lines (no mixed snapshot): 2 x a + 2 x b", previews.every((l) => { const [a, b, tot] = l.split("|"); return Math.abs(2 * Number(a) + 2 * Number(b) - Number(tot)) < 0.001; }));
t("the storm itself ran cleanly (40 changes, no error)", rs[0].err === "" && q(`select count(*) from public.customer_price_agreements where customer_id = '${custA}' and product_id = 'p26c-a'`) === "41" && q(`select count(*) from public.customer_price_agreements where customer_id = '${custA}' and product_id = 'p26c-a' and status = 'active'`) === "1", rs[0].err);
const cks = rs[4].out.filter((l) => l.startsWith("CK|")).map((l) => l.split("|"));
t("checkouts started during the storm: each stored checkout holds a consistent snapshot (amount = 3 x price + 2 x price at one agreed price) and the prices are only 8.00 or 6.00",
  cks.length >= 5 && cks.every(([, id, amt]) => { const lns = JSON.parse(q(`select lines::text from public.customer_checkouts where id = '${id}'`)); const sumOk = Math.abs(lns.reduce((s, l) => s + Number(l.unitPrice) * l.quantity, 0) - Number(amt)) < 0.001; return sumOk && lns.every((l) => [8, 6].includes(Number(l.unitPrice))); }), JSON.stringify(cks.slice(0, 2)));

// 2. confirmations that race a price change: every verified payment either becomes an order at EXACTLY the checkout's prices, or is parked for review
const cur = Number(q(`select unit_price from public.customer_price_agreements where customer_id = '${custA}' and product_id = 'p26c-a' and status = 'active'`));
const fin = cks.map(([, id, amt], i) => sql(`${as(null, "service_role")}\nselect public.finalize_customer_checkout('${id}', 'stg_test', 'evt-26c-${i}', 'succeeded', ${amt}, 'PROV-26C-${i}', 'h${i}', true)::text;`));
const outcomes = cks.map(([, id, amt]) => ({ id, amt: Number(amt), status: q(`select status from public.customer_checkouts where id = '${id}'`), order: q(`select coalesce(order_id, '') from public.customer_checkouts where id = '${id}'`) }));
t(`confirming those payments after the storm (price now ${cur}): a checkout whose amount still equals today's price total becomes an order, any other is parked as needs_review; none is silently re-priced`,
  outcomes.every((o) => (o.amt === 5 * cur ? o.status === "paid" && o.order !== "" : o.status === "needs_review" && o.order === "")), JSON.stringify(outcomes.slice(0, 3)));
t("every order created that way carries the exact agreed prices on its lines and a matching resolution record (applied price = line price = the agreement's price)",
  q(`select count(*) from public.order_price_resolutions r join public.order_items i on i.id = r.order_item_id where r.applied_price <> i.actual_unit_price or r.list_price <> i.standard_unit_price`) === "0"
  && q(`select count(*) from public.order_price_resolutions r join public.customer_price_agreements g on g.id = r.agreement_id where r.applied_price <> g.unit_price`) === "0");

// 3. two managers revoke the same agreement at the same instant: exactly one succeeds
const active = q(`select public.t26c_active('${custA}')`);
const revs = await parallel([MGR, MGR2].map((sub) => ({ sub, role: "authenticated", sql: `select public.revoke_price_agreement('${active}', 'Revoked by ${sub.slice(-1)} at the same instant (concurrency test)');` })));
t("two simultaneous revocations of one agreement: exactly one succeeds, the other is refused, one revocation event", revs.filter((r) => r.err === "").length === 1 && revs.filter((r) => /Only an active agreement/.test(r.err)).length === 1 && q(`select count(*) from public.price_agreement_events where agreement_id = '${active}' and kind = 'revoked'`) === "1", revs.map((r) => r.err.slice(0, 100)).join(" | "));

// 4. two managers create the same agreement at the same instant: exactly one active agreement results
const creates = await parallel([MGR, MGR2].map((sub, i) => ({ sub, role: "authenticated", sql: `select public.create_price_agreement('${custA}', 'p26c-a', null, ${9 + i}.00, public.efz_today(), null, 'Created by manager ${i + 1} at the same instant (test)');` })));
t("two simultaneous creations of the same agreement: exactly one succeeds (an overlap is refused), and there is never more than one active agreement for the key", creates.filter((r) => r.err === "").length === 1 && creates.filter((r) => /overlapping/.test(r.err)).length === 1
  && q(`select count(*) from public.customer_price_agreements where customer_id = '${custA}' and product_id = 'p26c-a' and design_id is null and status = 'active'`) === "1", creates.map((r) => r.err.slice(0, 100)).join(" | "));

// 5. two imports at the same instant: no duplicate candidates
const imps = await parallel([MGR, MGR2].map((sub) => ({ sub, role: "authenticated", sql: `select (public.import_price_candidates(false, null, 2) ->> 'created');` })));
t("two simultaneous real imports: exactly the two consistent candidates exist afterwards, each once (no duplicates, no invented price)", q(`select count(*) from public.customer_price_agreements where source = 'import' and customer_id like 'cust-t26c-h%'`) === "2"
  && q(`select string_agg(customer_id || ':' || unit_price, ',' order by customer_id) from public.customer_price_agreements where source = 'import' and customer_id like 'cust-t26c-h%'`) === "cust-t26c-h1:7.00,cust-t26c-h2:8.00", imps.map((r) => r.out.join(",") + r.err.slice(0, 60)).join(" | "));

// 6. consistency after the storm
t("no customer has two overlapping active or pending agreements for the same product and design", q(`select count(*) from public.customer_price_agreements a join public.customer_price_agreements b on a.id < b.id and a.customer_id = b.customer_id and a.product_id = b.product_id and a.design_id is not distinct from b.design_id
  and a.status in ('active', 'pending_review') and b.status in ('active', 'pending_review') and a.effective_from <= coalesce(b.effective_to, date 'infinity') and b.effective_from <= coalesce(a.effective_to, date 'infinity')`) === "0");
t("every agreement change has its event (created / revoked / verified) and nothing was deleted", Number(q(`select count(*) from public.price_agreement_events`)) >= 80 && q(`select count(*) from public.customer_price_agreements g where g.status = 'revoked' and not exists (select 1 from public.price_agreement_events e where e.agreement_id = g.id and e.kind = 'revoked')`) === "0");

console.log(results.every(Boolean) ? `CONCURRENCY: ${results.length} of ${results.length} checks passed` : `CONCURRENCY: ${results.filter((x) => !x).length} FAILED`);
process.exit(results.every(Boolean) ? 0 : 1);
