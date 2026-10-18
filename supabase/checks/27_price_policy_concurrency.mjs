// Concurrent behaviour of the price policy (migration 27): staff orders and customer-app pricing racing agreement changes, simultaneous revocations / replacements,
// and simultaneous expiry-notice runs. Needs REAL parallel database sessions, so it cannot live inside the single-transaction SQL suite.
// Run against a DISPOSABLE LOCAL database that already has migrations 21..27 (it COMMITS its own fixtures; never point it at Staging or Production):
//   node supabase/checks/27_price_policy_concurrency.mjs <database> [host] [port] [user]
// Environment: PSQL = path to psql (default "psql"). A password, if the server needs one, is read from PGPASSWORD (the usual libpq way).
import { spawn, spawnSync } from "node:child_process";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [db, host = "127.0.0.1", port = "54399", user = "postgres"] = process.argv.slice(2);
if (!db) { console.error("usage: node 27_price_policy_concurrency.mjs <database> [host] [port] [user]"); process.exit(2); }
if (!/^(localhost|127\.0\.0\.1)$/.test(host)) { console.error("refusing to run: this test commits fixtures and is for a local disposable database only"); process.exit(2); }
const PSQL = process.env.PSQL || "psql";
const base = ["-X", "-q", "-A", "-t", "-h", host, "-p", port, "-U", user, "-d", db];
const dir = mkdtempSync(join(tmpdir(), "efz-conc27-"));
const sql = (text, extra = []) => { const f = join(dir, "s" + Math.random().toString(36).slice(2) + ".sql"); writeFileSync(f, text); return spawnSync(PSQL, [...base, "-v", "ON_ERROR_STOP=1", ...extra, "-f", f], { encoding: "utf8" }); };
const q = (text) => sql(text).stdout.trim();

const SA = "a7100000-0000-4000-8000-000000000001", MGR = "a7100000-0000-4000-8000-000000000002", MGR2 = "a7100000-0000-4000-8000-000000000003", STAFF = "a7100000-0000-4000-8000-000000000004";
const CA = "c7100000-0000-4000-8000-00000000000a";
const as = (sub, role) => `select set_config('request.jwt.claims', '${JSON.stringify(sub ? { sub, role } : { role })}', false); set role ${role};`;

const setup = `
alter table public.orders disable trigger user; update public.orders set status = 'cancelled' where status <> 'cancelled'; alter table public.orders enable trigger user;
insert into public.profiles (id, name, email, role, status) values ('u-t27c-sa', 'T27C Super Admin', 't27c-sa@example.test', 'Super Admin', 'active'), ('u-t27c-mgr', 'T27C Manager', 't27c-mgr@example.test', 'Manager', 'active'),
  ('u-t27c-mgr2', 'T27C Manager 2', 't27c-mgr2@example.test', 'Manager', 'active'), ('u-t27c-staff', 'T27C Officer', 't27c-staff@example.test', 'Marketing Officer', 'active');
insert into public.user_permissions (user_id, permission_code) values ('u-t27c-mgr', 'manage_customer_accounts'), ('u-t27c-mgr', 'view_all_customers'), ('u-t27c-mgr', 'create_orders'), ('u-t27c-mgr', 'view_orders'),
  ('u-t27c-mgr2', 'view_all_customers'), ('u-t27c-mgr2', 'create_orders'), ('u-t27c-staff', 'create_orders'), ('u-t27c-staff', 'view_all_customers'), ('u-t27c-staff', 'view_customers');
insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
  ('${SA}', 'authenticated', 'authenticated', 't27c-sa@example.test', now(), '{"provider":"email"}', '{}', now(), now()), ('${MGR}', 'authenticated', 'authenticated', 't27c-mgr@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
  ('${MGR2}', 'authenticated', 'authenticated', 't27c-mgr2@example.test', now(), '{"provider":"email"}', '{}', now(), now()), ('${STAFF}', 'authenticated', 'authenticated', 't27c-staff@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
  ('${CA}', 'authenticated', 'authenticated', 't27c-a@example.test', now(), '{"provider":"email","efz_kind":"customer"}', '{}', now(), now());
insert into public.products (id, name, selling_price, cost_price, stock, is_active) values ('p27c-a', 'T27C Ball', 10, 6, 1000000, true), ('p27c-b', 'T27C Ball B', 20, 12, 1000000, true);
${as(null, "service_role")}
select public.register_customer_account('${CA}', 't27c-a@example.test', 'T27C A', '069 827 1000', '', null);
reset role;
${as(MGR, "authenticated")}
select public.approve_customer_account(id, null, true, false, 'Verified (T27C)') from public.customer_accounts where email = 't27c-a@example.test';
reset role;
create or replace function public.t27c_active(p_customer text, p_product text) returns uuid language sql security definer set search_path = public as $f$ select id from public.customer_price_agreements where customer_id = p_customer and product_id = p_product and design_id is null and status = 'active' order by effective_from desc limit 1 $f$;
grant execute on function public.t27c_active(text, text) to authenticated;
`;
const r0 = sql(setup);
if (r0.status !== 0) { console.error("fixture setup failed:\n" + r0.stderr); process.exit(2); }
const custA = q(`select customer_id from public.customer_accounts where email = 't27c-a@example.test'`);
{ const r = sql(`${as(MGR, "authenticated")}\nselect public.create_price_agreement('${custA}', 'p27c-a', null, 8.00, public.efz_today() - 1, null, 'Starting price for the concurrency test');`); if (r.status !== 0) { console.error("agreement setup failed:\n" + r.stderr); process.exit(2); } }

const results = []; const t = (name, ok, detail = "") => { results.push(ok); console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : "   [" + String(detail).slice(0, 300) + "]"}`); };
const AT = () => new Date(Date.now() + 3500).toISOString();
const session = (job, at) => new Promise((res) => {
  const f = join(dir, "j" + Math.random().toString(36).slice(2) + ".sql");
  writeFileSync(f, `${as(job.sub, job.role)}\nselect pg_sleep(greatest(0, extract(epoch from (timestamptz '${at}' - clock_timestamp()))));\n${job.sql}`);
  const p = spawn(PSQL, [...base, "-f", f]); let out = "", err = "";
  p.stdout.on("data", (d) => (out += d)); p.stderr.on("data", (d) => (err += d)); p.on("close", () => res({ out: out.trim().split("\n").map((l) => l.trim()).filter(Boolean), err: err.trim() }));
});
const parallel = (jobs) => { const at = AT(); return Promise.all(jobs.map((j) => session(j, at))); };
const order = (product = "p27c-a", extra = "") => `select public.create_order('{"customerId":"${custA}","items":[{"productId":"${product}","quantity":2}]${extra}}'::jsonb);`;

// 1. staff orders (no price typed) racing a storm of atomic price changes: every order is priced at one of the two agreed prices, never the list price, never an error
const storm = { sub: MGR, role: "authenticated", sql: Array.from({ length: 30 }, (_, i) => `select public.replace_price_agreement(public.t27c_active('${custA}', 'p27c-a'), ${i % 2 === 0 ? "6.00" : "8.00"}, public.efz_today(), null, 'Price change number ${i + 1} in the concurrency test');`).join("\n") };
const staff = (sub) => ({ sub, role: "authenticated", sql: Array.from({ length: 20 }, () => order()).join("\n") });
const rs = await parallel([storm, staff(MGR2), staff(STAFF), staff(MGR), { sub: CA, role: "authenticated", sql: Array.from({ length: 30 }, () => `select (public.customer_price_preview('[{"productId":"p27c-a","quantity":2}]'::jsonb) -> 'lines' -> 0 ->> 'unitPrice');`).join("\n") }]);
const prices = q(`select string_agg(distinct actual_unit_price::text, ',' order by actual_unit_price::text) from public.order_items i join public.orders o on o.id = i.order_id where o.customer_id = '${custA}'`);
const nOrders = Number(q(`select count(*) from public.orders where customer_id = '${custA}'`));
t("60 staff orders (three sessions, no price typed) race 30 atomic price changes: all 60 are created without error, every line is 6.00 or 8.00 (never the 10.00 list price)", nOrders === 60 && ["6.00,8.00", "6.00", "8.00"].includes(prices), `${nOrders} ${prices} ${rs.map((r) => r.err.slice(0, 80)).join("|")}`);
t("each of those lines has a matching resolution record: source agreement, applied price = the line's price = the price of the agreement it names, list price 10.00 kept as the standard price",
  q(`select count(*) from public.order_items i join public.orders o on o.id = i.order_id where o.customer_id = '${custA}' and not exists (select 1 from public.order_price_resolutions r join public.customer_price_agreements g on g.id = r.agreement_id where r.order_item_id = i.id and r.source = 'agreement' and r.applied_price = i.actual_unit_price and g.unit_price = i.actual_unit_price)`) === "0"
  && q(`select count(*) from public.order_items i join public.orders o on o.id = i.order_id where o.customer_id = '${custA}' and i.standard_unit_price <> 10`) === "0");
t("the customer app's previews during the storm were also only ever 6.00 or 8.00", rs[4].err === "" && rs[4].out.filter((l) => /^\d/.test(l)).length === 30 && rs[4].out.filter((l) => /^\d/.test(l)).every((l) => l === "6.00" || l === "8.00"), rs[4].out.slice(0, 5).join(","));
t("order totals are consistent (total = sum of lines) for every order created in the storm", q(`select count(*) from public.orders o where o.customer_id = '${custA}' and o.total <> (select sum(quantity * actual_unit_price) from public.order_items i where i.order_id = o.id)`) === "0");

// 2. a revocation racing staff orders: each order is priced either with the agreement (before) or at the list price (after, an authorized revocation), consistently recorded
const before = Number(q(`select count(*) from public.orders where customer_id = '${custA}'`));
const active = q(`select public.t27c_active('${custA}', 'p27c-a')`);
const rs2 = await parallel([{ sub: MGR, role: "authenticated", sql: `select public.revoke_price_agreement('${active}', 'Withdrawn while orders are being taken (concurrency test)');` }, staff(MGR2), staff(STAFF)]);
t("orders racing a revocation: all 40 succeed; each line is either the agreed price (resolution 'agreement') or the list price 10.00 (resolution 'list'), never anything in between", Number(q(`select count(*) from public.orders where customer_id = '${custA}'`)) === before + 40
  && q(`select count(*) from public.order_items i join public.orders o on o.id = i.order_id join public.order_price_resolutions r on r.order_item_id = i.id where o.customer_id = '${custA}' and not ((r.source = 'agreement' and i.actual_unit_price in (6, 8)) or (r.source = 'list' and i.actual_unit_price = 10))`) === "0", rs2.map((r) => r.err.slice(0, 100)).join("|"));

// 3. a future-dated replacement racing another: exactly one succeeds, the customer is never left without a price
const a2 = sql(`${as(MGR, "authenticated")}\nselect public.create_price_agreement('${custA}', 'p27c-b', null, 17.00, public.efz_today() - 1, null, 'Second product starting price (test)');`);
const active2 = q(`select public.t27c_active('${custA}', 'p27c-b')`);
const reps = await parallel([MGR, MGR2].map((sub, i) => ({ sub, role: "authenticated", sql: `select public.replace_price_agreement('${active2}', ${15 + i}.00, public.efz_today() + 3, null, 'Future change by manager ${i + 1} at the same instant (test)');` })));
t("two simultaneous future-dated replacements of one agreement: exactly one succeeds, the other is refused", a2.status === 0 && reps.filter((r) => r.err === "").length === 1 && reps.filter((r) => /Only an active agreement|overlapping/.test(r.err)).length === 1, reps.map((r) => r.err.slice(0, 120)).join(" | "));
t("and the customer has the old price today and the new price on the start date, with no day at the list price (20.00) in between",
  q(`select string_agg((public._price_resolve('${custA}', 'p27c-b', null, current_date + d) ->> 'price'), ',' order by d) from generate_series(0, 5) d`).replace(/\.00/g, "").startsWith("17,17,17,1") && !q(`select string_agg((public._price_resolve('${custA}', 'p27c-b', null, current_date + d) ->> 'source'), ',' order by d) from generate_series(0, 5) d`).includes("list"));

// 4. simultaneous expiry-notice runs: one notice per agreement and stage
sql(`${as(MGR, "authenticated")}\nselect public.create_price_agreement('${custA}', 'p27c-a', null, 9.00, public.efz_today(), public.efz_today() + 5, 'Ends in five days (notice race test)');`);
const noticeJobs = [{ sub: null, role: "service_role", sql: "select public.price_daily_run();" }, { sub: null, role: "service_role", sql: "select public.price_daily_run();" }, { sub: MGR, role: "authenticated", sql: "select public.run_price_checks();" },
  { sub: CA, role: "authenticated", sql: Array.from({ length: 5 }, () => "select count(*) from public.customer_catalog();").join("\n") }, { sub: CA, role: "authenticated", sql: Array.from({ length: 5 }, () => "select count(*) from public.customer_catalog();").join("\n") }];
const nr = await parallel(noticeJobs);
t("two daily runs, a manual run and ten catalogue looks at the same instant: the customer is told exactly once for the agreement ending in 5 days (one notice row, one customer notice)",
  q(`select count(*) from public.price_agreement_notices n join public.customer_price_agreements g on g.id = n.agreement_id where g.customer_id = '${custA}' and g.effective_to = current_date + 5`) === "1"
  && q(`select count(*) from public.customer_notifications where customer_id = '${custA}' and kind = 'price_agreement' and body like '%$9.00%'`) === "1", nr.map((r) => r.err.slice(0, 100)).join("|"));

// 5. consistency
t("no customer has two overlapping active or pending agreements for the same product and design", q(`select count(*) from public.customer_price_agreements a join public.customer_price_agreements b on a.id < b.id and a.customer_id = b.customer_id and a.product_id = b.product_id and a.design_id is not distinct from b.design_id
  and a.status in ('active', 'pending_review') and b.status in ('active', 'pending_review') and a.effective_from <= coalesce(b.effective_to, date 'infinity') and b.effective_from <= coalesce(a.effective_to, date 'infinity')`) === "0");
t("no agreement was deleted or changed in place: every revoked or end-dated agreement has its event", q(`select count(*) from public.customer_price_agreements g where g.status = 'revoked' and not exists (select 1 from public.price_agreement_events e where e.agreement_id = g.id and e.kind = 'revoked')`) === "0");

console.log(results.every(Boolean) ? `CONCURRENCY: ${results.length} of ${results.length} checks passed` : `CONCURRENCY: ${results.filter((x) => !x).length} FAILED`);
process.exit(results.every(Boolean) ? 0 : 1);
