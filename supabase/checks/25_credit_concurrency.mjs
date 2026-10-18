// Concurrent credit behaviour (migration 25). Needs REAL parallel database sessions, so it cannot live inside the single-transaction SQL suite.
// Run against a DISPOSABLE LOCAL database that already has migrations 21..25 (it COMMITS its own fixtures; never point it at Staging or Production):
//   node supabase/checks/25_credit_concurrency.mjs <database> [host] [port] [user]
// Environment: PSQL = path to psql (default "psql"). A password, if the server needs one, is read from PGPASSWORD (the usual libpq way).
import { spawn, spawnSync } from "node:child_process";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [db, host = "127.0.0.1", port = "54399", user = "postgres"] = process.argv.slice(2);
if (!db) { console.error("usage: node 25_credit_concurrency.mjs <database> [host] [port] [user]"); process.exit(2); }
if (!/^(localhost|127\.0\.0\.1)$/.test(host)) { console.error("refusing to run: this test commits fixtures and is for a local disposable database only"); process.exit(2); }
const PSQL = process.env.PSQL || "psql";
const base = ["-X", "-q", "-A", "-t", "-h", host, "-p", port, "-U", user, "-d", db];
const dir = mkdtempSync(join(tmpdir(), "efz-conc25-"));
const sql = (text, extra = []) => { const f = join(dir, "s" + Math.random().toString(36).slice(2) + ".sql"); writeFileSync(f, text); return spawnSync(PSQL, [...base, "-v", "ON_ERROR_STOP=1", ...extra, "-f", f], { encoding: "utf8" }); };
const q = (text) => sql(text).stdout.trim();

const SA = "a5100000-0000-4000-8000-000000000001", MGR = "a5100000-0000-4000-8000-000000000002";
const names = ["one", "two", "three", "four", "five", "six"];
const CUST = Object.fromEntries(names.map((n, i) => [n, `c5100000-0000-4000-8000-00000000000${i + 1}`]));
const as = (sub, role) => `select set_config('request.jwt.claims', '${JSON.stringify(sub ? { sub, role } : { role })}', false); set role ${role};`;

// ---- fixtures (committed): a Super Admin, a Manager, six approved customers (approved long ago, 3 paid orders each), a sales history, the approved policy enabled
const setup = `
-- the disposable database may already hold orders (a clone of Staging data): neutralise them so the arithmetic below is exact
alter table public.orders disable trigger user;
update public.orders set status = 'cancelled' where status <> 'cancelled';
alter table public.orders enable trigger user;
insert into public.profiles (id, name, email, role, status) values ('u-t25c-sa', 'T25C Super Admin', 't25c-sa@example.test', 'Super Admin', 'active'), ('u-t25c-mgr', 'T25C Manager', 't25c-mgr@example.test', 'Manager', 'active');
insert into public.user_permissions (user_id, permission_code) values ('u-t25c-mgr', 'manage_customer_accounts'), ('u-t25c-mgr', 'view_all_customers');
insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
  ('${SA}', 'authenticated', 'authenticated', 't25c-sa@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
  ('${MGR}', 'authenticated', 'authenticated', 't25c-mgr@example.test', now(), '{"provider":"email"}', '{}', now(), now());
insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select u, 'authenticated', 'authenticated', e, now(), '{"provider":"email","efz_kind":"customer"}', '{}', now(), now()
  from (values ${names.map((n) => `('${CUST[n]}'::uuid, 't25c-${n}@example.test')`).join(", ")}) v(u, e);
insert into public.products (id, name, selling_price, cost_price, stock, is_active) values ('p25c-plain', 'T25C Ball', 10, 5, 1000000, true);
insert into public.customers (id, name, email, phone, notes, status) values ('cust-t25c-hist', 'T25C History', 'h@example.test', '069 825 9998', 'history', 'active');
${as(null, "service_role")}
${names.map((n, i) => `select public.register_customer_account('${CUST[n]}', 't25c-${n}@example.test', 'T25C ${n}', '069 825 91${String(i).padStart(2, "0")}', '', null);`).join("\n")}
reset role;
${as(MGR, "authenticated")}
select public.approve_customer_account(id, null, true, false, 'Verified (T25C)') from public.customer_accounts where email like 't25c-%';
reset role;
alter table public.customer_account_events disable trigger trg_customer_account_events_guard;
update public.customer_account_events set created_at = now() - interval '400 days' where event = 'approved' and account_id in (select id from public.customer_accounts where email like 't25c-%');
alter table public.customer_account_events enable trigger trg_customer_account_events_guard;
${names.map((n, i) => [10, 20, 30].map((d, j) => `
insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) select 'ORD-T25C-${i}${j}', customer_id, 'T25C', '', 'delivered', 'regular', public.efz_today() - ${d}, '' from public.customer_accounts where email = 't25c-${n}@example.test';
insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost) values ('itm-t25c-${i}${j}', 'ORD-T25C-${i}${j}', 'p25c-plain', 'P', 'P', 2, 10, 10, 5);
insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes) values ('pay-t25c-${i}${j}', 'ORD-T25C-${i}${j}', 20, public.efz_today() - ${d}, 'Cash', '', '');`).join("")).join("\n")}
-- sales history: an old order, then a top-up so that the three previous complete months hold exactly 600 of booked revenue (cap 25% = 50.00)
insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) values ('ORD-T25C-HOLD', 'cust-t25c-hist', 'T25C', '', 'delivered', 'regular', (date_trunc('month', public.efz_today()) - interval '3 month' - interval '40 days')::date, '');
insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost) values ('itm-t25c-hold', 'ORD-T25C-HOLD', 'p25c-plain', 'P', 'P', 1, 10, 10, 5);
insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes)
  select 'ORD-T25C-HTOP', 'cust-t25c-hist', 'T25C', '', 'delivered', 'regular', (date_trunc('month', public.efz_today()) - interval '2 month')::date + 3, ''
   where (select coalesce(sum(o.total), 0) from public.orders o where o.status <> 'cancelled' and o.order_date between (date_trunc('month', public.efz_today()) - interval '3 month')::date and date_trunc('month', public.efz_today())::date - 1) <= 590;
insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost)
  select 'itm-t25c-htop', 'ORD-T25C-HTOP', 'p25c-plain', 'P', 'P',
         ((600 - (select coalesce(sum(o.total), 0) from public.orders o where o.status <> 'cancelled' and o.id <> 'ORD-T25C-HTOP' and o.order_date between (date_trunc('month', public.efz_today()) - interval '3 month')::date and date_trunc('month', public.efz_today())::date - 1)) / 10)::integer, 10, 10, 5
   where exists (select 1 from public.orders where id = 'ORD-T25C-HTOP');
${as(SA, "authenticated")}
select public.set_credit_policy(true, 3, null, true, 30, 'T25 concurrency test policy', 60, null, true);
${names.map((n) => `select public.set_customer_credit(customer_id, 40, 30, 'Concurrency test limit') from public.customer_accounts where email = 't25c-${n}@example.test';`).join("\n")}
reset role;
`;
const r0 = sql(setup);
if (r0.status !== 0) { console.error("fixture setup failed:\n" + r0.stderr); process.exit(2); }
const capNow = JSON.parse(q("select public._credit_company_cap()::text"));

const customerId = (n) => q(`select customer_id from public.customer_accounts where email = 't25c-${n}@example.test'`);
const results = []; const t = (name, ok, detail = "") => { results.push(ok); console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : "   [" + String(detail).slice(0, 300) + "]"}`); };
t("setup: the company cap is computable and equals 50.00 (25% of 200 average monthly)", capNow.sufficient === true && Number(capNow.cap) === 50 && Number(capNow.outstanding) === 0, JSON.stringify(capNow));

// every session waits for the same instant, then runs its own statements as its own real role
const parallel = (jobs) => new Promise((resolve) => {
  const at = new Date(Date.now() + 3500).toISOString();
  Promise.all(jobs.map((job) => new Promise((res) => {
    const f = join(dir, "j" + Math.random().toString(36).slice(2) + ".sql");
    writeFileSync(f, `${as(job.sub, job.role)}\nselect pg_sleep(greatest(0, extract(epoch from (timestamptz '${at}' - clock_timestamp()))));\n${job.sql}`);
    const p = spawn(PSQL, [...base, "-f", f]); let out = "", err = "";
    p.stdout.on("data", (d) => (out += d)); p.stderr.on("data", (d) => (err += d)); p.on("close", () => res({ out: out.trim().split("\n").pop(), err: err.trim() }));
  }))).then(resolve);
});
const uuid = () => crypto.randomUUID();
const place = (n, qty, key) => ({ sub: CUST[n], role: "authenticated", sql: `select public.customer_place_credit_order('${JSON.stringify({ deliveryLocation: "Hodan", submissionKey: key, lines: [{ productId: "p25c-plain", quantity: qty }] })}'::jsonb)::text;` });
const ok = (rs) => rs.filter((r) => /"status": "credit_placed"/.test(r.out));
const creditOut = (cond = "true") => Number(q(`select coalesce(sum(outstanding_balance), 0) from public.orders where payment_terms = 'credit' and status <> 'cancelled' and ${cond}`));

// 1. company-wide cap across DIFFERENT customers: five customers each ask for $30 at the same instant; cap $50 allows one
let rs = await parallel(names.slice(0, 5).map((n) => place(n, 3, uuid())));
t("company cap $50, five different customers each ordering $30 at once: exactly ONE order is placed and the company outstanding is $30, never above the cap", ok(rs).length === 1 && creditOut() === 30, JSON.stringify({ placed: ok(rs).length, outstanding: creditOut() }));
t("the four refused customers get the ordinary credit message (no partial order, no cap figure shown)", rs.filter((r) => /above your available credit/.test(r.err) && !/cap/i.test(r.err)).length === 4, rs.map((r) => r.err.slice(0, 70)).join(" | "));
// 2. smaller orders from many customers: the remaining $20 fits two $10 orders and no more
rs = await parallel(names.map((n) => place(n, 1, uuid())));
t("the remaining $20 of cap, six customers each ordering $10 at once: exactly TWO more are accepted, the company outstanding ends at exactly the cap ($50)", ok(rs).length === 2 && creditOut() === 50, JSON.stringify({ placed: ok(rs).length, outstanding: creditOut() }));
// 3. the per-customer limit, one customer, many sessions (use a customer with room: free the cap first by cancelling nothing - use the customer limit test on a fresh cap instead)
q(`update public.credit_policy set company_cap_percent = 100 where id`);   // widen the cap so that the PERSONAL limit is what is tested next
const free = names.find((n) => Number(q(`select coalesce(sum(outstanding_balance), 0) from public.orders where customer_id = '${customerId(n)}' and payment_terms = 'credit' and status <> 'cancelled'`)) === 0);
rs = await parallel(Array.from({ length: 8 }, () => place(free, 2, uuid())));
t(`personal limit $40, eight simultaneous $20 orders from ONE customer (${free}): exactly two are placed ($40 outstanding, never above the limit)`, ok(rs).length === 2 && creditOut(`customer_id = '${customerId(free)}'`) === 40, JSON.stringify({ placed: ok(rs).length }));
// 4. the same submission key from five sessions
const other = names.find((n) => n !== free && Number(q(`select coalesce(sum(outstanding_balance), 0) from public.orders where customer_id = '${customerId(n)}' and payment_terms = 'credit' and status <> 'cancelled'`)) <= 20);
const key = uuid(); const before = Number(q(`select count(*) from public.orders where customer_id = '${customerId(other)}' and payment_terms = 'credit'`));
rs = await parallel(Array.from({ length: 5 }, () => place(other, 1, key)));
t("one submission key from five simultaneous sessions creates exactly one order", Number(q(`select count(*) from public.orders where customer_id = '${customerId(other)}' and payment_terms = 'credit'`)) === before + 1 && new Set(rs.map((r) => (/"orderId": "([^"]+)"/.exec(r.out) || [])[1])).size === 1, rs.map((r) => r.out.slice(0, 60)).join(" | "));

// 5. the default race: an invoice is overdue, many sessions look at the account and try to buy at the same instant
const owing = (n) => Number(q(`select coalesce(sum(outstanding_balance), 0) from public.orders where customer_id = '${customerId(n)}' and payment_terms = 'credit' and status <> 'cancelled'`));
const victim = names.find((n) => n !== free && n !== other && owing(n) > 0);
if (!victim) { console.error("setup problem: no customer with a credit invoice to default"); process.exit(2); }
const vOrder = q(`select o.id from public.orders o join public.customer_credit_orders c on c.order_id = o.id where o.customer_id = '${customerId(victim)}' and o.status <> 'cancelled' limit 1`);
q(`alter table public.customer_credit_orders disable trigger trg_credit_orders_nodelete; update public.customer_credit_orders set due_date = public.efz_today() - 1 where order_id = '${vOrder}'; alter table public.customer_credit_orders enable trigger trg_credit_orders_nodelete;`);
rs = await parallel([...Array.from({ length: 4 }, () => place(victim, 1, uuid())), ...Array.from({ length: 4 }, () => ({ sub: CUST[victim], role: "authenticated", sql: "select public.customer_credit_status()::text;" }))]);
const nDef = Number(q(`select count(*) from public.customer_credit_defaults where order_id = '${vOrder}'`));
t("a missed due date seen by eight simultaneous sessions is recorded as exactly ONE default, with one revocation event and one customer + one staff notice", nDef === 1
  && Number(q(`select count(*) from public.customer_credit_events where customer_id = '${customerId(victim)}' and kind = 'default_recorded'`)) === 1 && Number(q(`select count(*) from public.credit_reminders where order_id = '${vOrder}' and kind = 'overdue_1'`)) === 2, String(nDef));
t("none of the simultaneous orders from the defaulted customer was accepted, and the account is revoked", ok(rs.slice(0, 4)).length === 0 && q(`select status from public.customer_credit_accounts where customer_id = '${customerId(victim)}'`) === "revoked");

// 6. concurrent daily runs (a job retry, a manual run and the scheduler at once) never duplicate a reminder
const dueOrder = q(`select o.id from public.orders o join public.customer_credit_orders c on c.order_id = o.id where o.customer_id = '${customerId(free)}' and o.status <> 'cancelled' order by o.created_at limit 1`);
q(`alter table public.customer_credit_orders disable trigger trg_credit_orders_nodelete; update public.customer_credit_orders set due_date = public.efz_today() + 5 where order_id = '${dueOrder}'; alter table public.customer_credit_orders enable trigger trg_credit_orders_nodelete;`);
await parallel([...Array.from({ length: 4 }, () => ({ sub: null, role: "service_role", sql: "select public.credit_daily_run()::text;" })), { sub: SA, role: "authenticated", sql: "select public.run_credit_checks()::text;" }]);
t("five simultaneous runs (four scheduler calls and a manual one) leave exactly one reminder per invoice, kind and audience, and exactly one customer notice for the pre-due reminder",
  Number(q(`select count(*) from (select order_id, kind, audience, count(*) c from public.credit_reminders group by 1, 2, 3 having count(*) > 1) d`)) === 0 && Number(q(`select count(*) from public.credit_reminders where order_id = '${dueOrder}' and kind = 'due_7'`)) === 1
  && Number(q(`select count(*) from public.customer_notifications where order_id = '${dueOrder}' and kind = 'due_7'`)) === 1);

// 7. duplicate disputes
rs = await parallel(Array.from({ length: 5 }, () => ({ sub: CUST[free], role: "authenticated", sql: `select public.customer_open_credit_dispute('${dueOrder}', 'The amount on this invoice does not look right', null)::text;` })));
t("five simultaneous disputes on one invoice: exactly one is opened", Number(q(`select count(*) from public.credit_disputes where order_id = '${dueOrder}'`)) === 1 && rs.filter((r) => /already open/.test(r.err)).length === 4, rs.map((r) => r.err.slice(0, 60)).join(" | "));

// 8. consistency after the storm
t("every credit order is a normal order: total = sum of lines, paid + balance = total", q("select count(*) from public.orders o join public.customer_credit_orders c on c.order_id = o.id where o.total <> (select sum(line_revenue) from public.order_items where order_id = o.id) or o.amount_paid + o.outstanding_balance <> o.total") === "0");
t("every credit order has its audit and history records", q("select count(*) from public.customer_credit_orders c where not exists (select 1 from public.system_logs l where l.target_id = c.order_id and l.metadata ->> 'event' = 'credit_order_placed') or not exists (select 1 from public.customer_credit_events e where e.metadata ->> 'orderId' = c.order_id and e.kind = 'credit_order_placed')") === "0");
t("no customer is above their personal limit", q("select count(*) from public.customer_credit_accounts a where (select coalesce(sum(o.outstanding_balance), 0) from public.orders o where o.customer_id = a.customer_id and o.payment_terms = 'credit' and o.status <> 'cancelled') > a.credit_limit") === "0");

console.log(results.every(Boolean) ? `CONCURRENCY: ${results.length} of ${results.length} checks passed` : `CONCURRENCY: ${results.filter((x) => !x).length} FAILED`);
process.exit(results.every(Boolean) ? 0 : 1);
