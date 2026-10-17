// Concurrent credit reservations (migration 24). Needs REAL parallel database sessions, so it cannot live inside the single-transaction SQL suite.
// Run against a DISPOSABLE LOCAL database that already has migrations 21..24 (it COMMITS its own fixtures; never point it at Staging or Production):
//   node supabase/checks/24_credit_concurrency.mjs <database> [host] [port] [user]
// Environment: PSQL = path to psql (default "psql"). The password, if the server needs one, is read from PGPASSWORD (the usual libpq way).
import { spawn, spawnSync } from "node:child_process";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [db, host = "127.0.0.1", port = "54399", user = "postgres"] = process.argv.slice(2);
if (!db) { console.error("usage: node 24_credit_concurrency.mjs <database> [host] [port] [user]"); process.exit(2); }
if (!/^(localhost|127\.0\.0\.1)$/.test(host)) { console.error("refusing to run: this test commits fixtures and is for a local disposable database only"); process.exit(2); }
const PSQL = process.env.PSQL || "psql";
const base = ["-X", "-q", "-A", "-t", "-h", host, "-p", port, "-U", user, "-d", db];
const dir = mkdtempSync(join(tmpdir(), "efz-conc-"));
const sql = (text, extra = []) => { const f = join(dir, "s" + Math.random().toString(36).slice(2) + ".sql"); writeFileSync(f, text); return spawnSync(PSQL, [...base, "-v", "ON_ERROR_STOP=1", ...extra, "-f", f], { encoding: "utf8" }); };

const SA = "a4100000-0000-4000-8000-000000000001", MGR = "a4100000-0000-4000-8000-000000000002";
const CUST = { one: "c4100000-0000-4000-8000-000000000001", two: "c4100000-0000-4000-8000-000000000002", three: "c4100000-0000-4000-8000-000000000003", four: "c4100000-0000-4000-8000-000000000004" };
const as = (sub, role) => `select set_config('request.jwt.claims', '${JSON.stringify(sub ? { sub, role } : { role })}', false); set role ${role};`;

// ---- fixtures (committed): one Super Admin, one Manager, four approved customers who each have one completed purchase, a product with plenty of stock
let setup = `
insert into public.profiles (id, name, email, role, status) values ('u-t24c-sa', 'T24C Super Admin', 't24c-sa@example.test', 'Super Admin', 'active'), ('u-t24c-mgr', 'T24C Manager', 't24c-mgr@example.test', 'Manager', 'active');
insert into public.user_permissions (user_id, permission_code) values ('u-t24c-mgr', 'manage_customer_accounts'), ('u-t24c-mgr', 'view_all_customers');
insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
  ('${SA}', 'authenticated', 'authenticated', 't24c-sa@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
  ('${MGR}', 'authenticated', 'authenticated', 't24c-mgr@example.test', now(), '{"provider":"email"}', '{}', now(), now());
insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u, 'authenticated', 'authenticated', e, now(), '{"provider":"email","efz_kind":"customer"}', '{}', now(), now()
  from (values ${Object.entries(CUST).map(([k, u]) => `('${u}'::uuid, 't24c-${k}@example.test')`).join(", ")}) v(u, e);
insert into public.products (id, name, selling_price, cost_price, stock, is_active) values ('p24c-plain', 'T24C Ball', 10, 5, 100000, true);
${as(null, "service_role")}
${Object.entries(CUST).map(([k, u], i) => `select public.register_customer_account('${u}', 't24c-${k}@example.test', 'T24C ${k}', '069 824 900${i}', '', null);`).join("\n")}
reset role;
${as(MGR, "authenticated")}
select public.approve_customer_account(id, null, true, false, 'Verified (T24C)') from public.customer_accounts where email like 't24c-%';
reset role;
${Object.keys(CUST).map((k, i) => `
insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) select 'ORD-T24C-${i}', customer_id, 'T24C', '', 'delivered', 'regular', current_date, '' from public.customer_accounts where email = 't24c-${k}@example.test';
insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost) values ('itm-t24c-${i}', 'ORD-T24C-${i}', 'p24c-plain', 'P', 'P', 1, 10, 10, 5);
insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes) values ('pay-t24c-${i}', 'ORD-T24C-${i}', 10, current_date, 'Cash', '', '');`).join("\n")}
${as(SA, "authenticated")}
select public.set_credit_policy(true, 1, null, true, 14, 'T24 concurrency test policy', null, null, true);
${Object.keys(CUST).map((k) => `select public.set_customer_credit(customer_id, ${k === "two" ? 500 : 100}, 14, 'Concurrency test limit') from public.customer_accounts where email = 't24c-${k}@example.test';`).join("\n")}
reset role;
`;
const r0 = sql(setup);
if (r0.status !== 0) { console.error("fixture setup failed:\n" + r0.stderr); process.exit(2); }

const customerId = (k) => sql(`select customer_id from public.customer_accounts where email = 't24c-${k}@example.test'`).stdout.trim();
const q = (text) => sql(text).stdout.trim();
const results = []; const t = (name, ok, detail = "") => { results.push(ok); console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : "   [" + detail + "]"}`); };

// one session = one customer calling the real function as the real role, all released at the same instant
const placeMany = (k, keys, qty) => new Promise((resolve) => {
  const at = new Date(Date.now() + 3000).toISOString();
  const jobs = keys.map((key) => new Promise((res) => {
    const f = join(dir, "j" + Math.random().toString(36).slice(2) + ".sql");
    writeFileSync(f, `${as(CUST[k], "authenticated")}
select pg_sleep(greatest(0, extract(epoch from (timestamptz '${at}' - clock_timestamp()))));
select public.customer_place_credit_order('${JSON.stringify({ deliveryLocation: "Hodan", submissionKey: key, lines: [{ productId: "p24c-plain", quantity: qty }] })}'::jsonb)::text;`);
    const p = spawn(PSQL, [...base, "-f", f]); let out = "", err = "";
    p.stdout.on("data", (d) => (out += d)); p.stderr.on("data", (d) => (err += d)); p.on("close", () => res({ out: out.trim().split("\n").pop(), err: err.trim() }));
  }));
  Promise.all(jobs).then(resolve);
});
const uuid = () => crypto.randomUUID();
const okOrders = (rs) => rs.filter((r) => /"orderId"/.test(r.out) && /"status": "credit_placed"/.test(r.out));
const state = (k) => JSON.parse(q(`select jsonb_build_object('orders', (select count(*) from public.orders where customer_id = '${customerId(k)}' and payment_terms = 'credit'),
  'outstanding', (select coalesce(sum(outstanding_balance), 0) from public.orders where customer_id = '${customerId(k)}' and status <> 'cancelled' and payment_terms = 'credit'),
  'rows', (select count(*) from public.customer_credit_orders where customer_id = '${customerId(k)}'))::text`));

// 1. limit 100, eight sessions each want 40 at the same instant: at most two fit (80), the third would make 120
let rs = await placeMany("one", Array.from({ length: 8 }, uuid), 4);
let s = state("one");
t("limit 100, 8 simultaneous orders of 40: exactly 2 are placed", okOrders(rs).length === 2 && s.orders === 2, JSON.stringify({ placed: okOrders(rs).length, state: s }));
t("the other 6 are refused with the plain limit message (no partial or duplicate order)", rs.filter((r) => /above your available credit/.test(r.err)).length === 6, rs.map((r) => r.err.slice(0, 80)).join(" | "));
t("outstanding never exceeds the limit (80 <= 100) and every order has exactly one credit-terms row", Number(s.outstanding) === 80 && s.rows === s.orders, JSON.stringify(s));

// 2. the same submission key used by five simultaneous sessions creates ONE order
const sameKey = uuid();
rs = await placeMany("three", Array.from({ length: 5 }, () => sameKey), 2);
s = state("three");
t("one submission key sent by 5 simultaneous sessions creates exactly one order", s.orders === 1 && Number(s.outstanding) === 20 && new Set(rs.map((r) => (/"orderId": "([^"]+)"/.exec(r.out) || [])[1])).size === 1, JSON.stringify({ state: s, outs: rs.map((r) => r.out.slice(0, 90)) }));

// 3. outstanding ceiling 70 above a personal limit of 500: orders of 30 -> only two fit (60), the third would reach 90
if (sql(`${as(SA, "authenticated")} select public.set_credit_policy(true, 1, null, true, 14, 'T24 concurrency: ceiling of 70', null, 70, true);`).status !== 0) { console.error("could not set the ceiling"); process.exit(2); }
rs = await placeMany("two", Array.from({ length: 6 }, uuid), 3);
s = state("two");
t("ceiling 70 (personal limit 500), 6 simultaneous orders of 30: exactly 2 are placed", okOrders(rs).length === 2 && s.orders === 2 && Number(s.outstanding) === 60, JSON.stringify({ placed: okOrders(rs).length, state: s }));

// 4. credit orders racing with a suspension: nothing is placed after the suspension is committed, and what was placed never exceeds the limit
{
  const at = new Date(Date.now() + 3000).toISOString();
  const suspendFile = join(dir, "susp.sql");
  writeFileSync(suspendFile, `${as(SA, "authenticated")}
select pg_sleep(greatest(0, extract(epoch from (timestamptz '${at}' - clock_timestamp()))) + 0.05);
select public.suspend_customer_credit('${customerId("four")}', 'T24 concurrency: suspended during the race');`);
  const susp = new Promise((res) => { const p = spawn(PSQL, [...base, "-f", suspendFile]); p.on("close", res); });
  const [rs4] = await Promise.all([placeMany("four", Array.from({ length: 6 }, uuid), 2), susp]);
  s = state("four");
  const after = q(`select status from public.customer_credit_accounts where customer_id = '${customerId("four")}'`);
  t("racing with a suspension: the account ends suspended, nothing exceeds the limit, no half-written order", after === "suspended" && Number(s.outstanding) <= 100 && s.rows === s.orders, JSON.stringify({ after, state: s, placed: okOrders(rs4).length }));
  const late = await placeMany("four", [uuid()], 1);
  t("after the suspension is committed no further credit order is placed", okOrders(late).length === 0 && /not available on this account/.test(late[0].err), late[0].err.slice(0, 120));
}

// 5. database-wide consistency after the storm
t("every credit order created here is a normal order: total = sum of lines, paid + balance = total", q(`select count(*) from public.orders o join public.customer_credit_orders c on c.order_id = o.id where o.total <> (select sum(line_revenue) from public.order_items where order_id = o.id) or o.amount_paid + o.outstanding_balance <> o.total`) === "0");
t("every credit order has its audit lines", q(`select count(*) from public.customer_credit_orders c where not exists (select 1 from public.system_logs l where l.target_id = c.order_id and l.metadata ->> 'event' = 'credit_order_placed')`) === "0");

console.log(results.every(Boolean) ? `CONCURRENCY: ${results.length} of ${results.length} checks passed` : `CONCURRENCY: ${results.filter((x) => !x).length} FAILED`);
process.exit(results.every(Boolean) ? 0 : 1);
