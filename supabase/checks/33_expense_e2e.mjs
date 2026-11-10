// EFZ-STAGING ONLY. End-to-end check of migration 33 through the Hub's real data layer (lib/supabase/queries.ts) over PostgREST, signed in as real Staging staff:
// the app's own RPC calls, view reads and row mapping, the permission model, the workflow, and the profit chain on real orders (its gross profit must equal the
// Financial page's existing figure). The SQL checks (33_expense_management_checks.sql) cover the database rules; this covers what the app actually sends and reads.
//
//   E2E_ENV=<path to .env.e2e> node --import ./scripts/register-test-loader.mjs supabase/checks/33_expense_e2e.mjs
//
// Reads .env.local (must be EFZ-Staging) and the staff passwords from E2E_ENV. Never prints a key or password.
// Temporarily grants expense permissions to three staff and RESTORES their exact permission sets at the end. Expenses are never deleted: the test
// expenses ("E2E33 ...") are paid-then-voided / withdrawn so they no longer count, and remain in the history (synthetic, Staging only).
import fs from "node:fs";
import { createClient } from "@supabase/supabase-js";
import { createDb, describeDbError } from "../../lib/supabase/queries.ts";
import { buildDataset } from "../../lib/analytics/dataset.ts";
import { NO_FILTERS } from "../../lib/analytics/dataset.ts";
import { periodFigures } from "../../lib/finance/model.ts";
import { profitModel } from "../../lib/finance/profit.ts";
import { summarizeExpenses } from "../../lib/finance/expenses.ts";

const STAGING_REF = "adjjamiqwboawqedaapi";
const PROD_REF = "rodmdvfjashiohgwople";
const readEnv = (file) => {
  const out = {};
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (m) out[m[1]] = m[2].replace(/^"|"$/g, "");
  }
  return out;
};
const env = { ...readEnv(".env.local"), ...(process.env.E2E_ENV ? readEnv(process.env.E2E_ENV) : {}) };
const url = env.NEXT_PUBLIC_SUPABASE_URL;
const anonKey = env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
if (!url || !anonKey || !url.includes(STAGING_REF) || url.includes(PROD_REF)) { console.error("REFUSED: .env.local is not the EFZ-Staging project"); process.exit(2); }

const results = [];
const check = (id, name, ok, info = "") => { results.push(ok); console.log(`${ok ? "PASS" : "FAIL"} ${id} ${name}${ok ? "" : info ? `  [${info}]` : ""}`); };
const fresh = () => createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
const errOf = async (fn) => { try { await fn(); return null; } catch (e) { return describeDbError(e); } };
async function staff(email, passwordKey) {
  const client = fresh();
  const { error } = await client.auth.signInWithPassword({ email, password: env[passwordKey] ?? "" });
  if (error) throw new Error(`sign-in failed for ${email}: ${error.message}`);
  return { client, db: createDb(client) };
}
const today = new Date(Date.now() + 3 * 3600 * 1000).toISOString().slice(0, 10);   // Mogadishu date
const monthStart = `${today.slice(0, 7)}-01`;
const NEW = ["submit_expenses", "view_expenses", "approve_expenses", "pay_expenses"];
const original = new Map();     // user id -> exact permission list before the run
let sa;

try {
  sa = await staff("efz.superadmin@example.com", "E2E_SUPERADMIN_PASSWORD");
  const cs = await staff("efz.cs@example.com", "E2E_CS_PASSWORD");
  const ops = await staff("efz.ops@example.com", "E2E_MANAGER_PASSWORD");          // Manager with view_reports + view_commissions
  const off1 = await staff("efz.officer1@example.com", "E2E_OFFICER_PASSWORD");

  // ---- grants for the run (restored in finally) ----
  const all = await sa.db.users.list();
  const grant = async (id, extra) => {
    const u = all.find((x) => x.id === id);
    original.set(id, [...u.permissions]);
    await sa.db.users.setPermissions(id, [...new Set([...u.permissions, ...extra])]);
  };
  await grant("u-stg-cs", ["submit_expenses"]);
  await grant("u-stg-officer1", ["submit_expenses"]);
  await grant("u-stg-ops", ["approve_expenses", "view_expenses", "pay_expenses"]);

  // ---- categories ----
  const cats = await sa.db.expenses.categories();
  check("E1", "categories load through the data layer (13, mapped)", cats.length === 13 && cats.every((c) => typeof c.isActive === "boolean") && cats.some((c) => c.id === "delivery" && c.kind === "direct_order"), `n=${cats.length}`);

  // ---- submit, list mapping ----
  const id1 = await cs.db.expenses.submit({ categoryId: "rent", description: "E2E33 rent", amount: "120.00", expenseDate: today, vendor: "E2E33 landlord", paymentMethod: "Cash" });
  const mine = await cs.db.expenses.list();
  const e1 = mine.find((e) => e.id === id1);
  check("E2", "a submitter lists their own expense, mapped (number amount, pending, reference)", !!e1 && e1.amount === 120 && e1.status === "pending" && /^EXP-\d{4}-\d{6}$/.test(e1.reference) && e1.paymentStatus === null && e1.submittedBy === "u-stg-cs", JSON.stringify(e1));
  check("E3", "...and sees only their own", mine.every((e) => e.submittedBy === "u-stg-cs"));
  check("E4", "a submitter cannot approve (database sentence shown)", /not allowed to approve/i.test((await errOf(() => cs.db.expenses.decide(id1, "approve"))) ?? ""));
  const badAmount = await errOf(() => cs.db.expenses.submit({ categoryId: "rent", description: "E2E33 bad", amount: "12.345", expenseDate: today }));
  check("E5", "a 3-decimal amount is refused with a readable sentence", /at most 2 decimals/i.test(badAmount ?? ""), badAmount ?? "accepted");

  // ---- edit, reject (reason), resubmit, approve ----
  await cs.db.expenses.edit(id1, { categoryId: "rent", description: "E2E33 rent", amount: "130.00", expenseDate: today, vendor: "E2E33 landlord", paymentMethod: "Cash" });
  check("E6", "the submitter edits a pending expense", (await cs.db.expenses.list()).find((e) => e.id === id1).amount === 130);
  check("E7", "a rejection without a reason is refused", /needs a reason/i.test((await errOf(() => ops.db.expenses.decide(id1, "reject", ""))) ?? ""));
  await ops.db.expenses.decide(id1, "reject", "E2E33 receipt missing");
  const rej = (await cs.db.expenses.list()).find((e) => e.id === id1);
  check("E8", "rejected with a visible reason", rej.status === "rejected" && rej.rejectionReason === "E2E33 receipt missing" && rej.decidedByName !== "");
  await cs.db.expenses.edit(id1, { categoryId: "rent", description: "E2E33 rent", amount: "130.00", expenseDate: today, vendor: "E2E33 landlord", paymentMethod: "Cash", notes: "receipt EVC-1" });
  check("E9", "editing a rejected expense resubmits it", (await cs.db.expenses.list()).find((e) => e.id === id1).status === "pending");
  await ops.db.expenses.decide(id1, "approve");
  check("E10", "an approver approves it", (await ops.db.expenses.list()).find((e) => e.id === id1).status === "approved");
  check("E11", "an approved expense can no longer be edited", /cannot be edited/i.test((await errOf(() => cs.db.expenses.edit(id1, { categoryId: "rent", description: "x", amount: "1.00", expenseDate: today }))) ?? ""));

  // ---- Super Admin: submits, cannot approve own ----
  const idSa = await sa.db.expenses.submit({ categoryId: "administration", description: "E2E33 admin cost", amount: "40.00", expenseDate: today });
  const own = await errOf(() => sa.db.expenses.decide(idSa, "approve"));
  check("E12", "Super Admin cannot approve their own expense", /your own expense/i.test(own ?? ""), own ?? "accepted");
  await ops.db.expenses.decide(idSa, "approve");
  check("E13", "another approver approves the Super Admin's expense", (await sa.db.expenses.list()).find((e) => e.id === idSa).status === "approved");

  // ---- direct order expense + order scope ----
  const orders = await sa.db.orders.listAll();
  const o1 = orders.find((o) => o.marketingOfficerId === "u-stg-officer1" && o.status !== "cancelled");
  const o2 = orders.find((o) => o.marketingOfficerId === "u-stg-officer2" && o.status !== "cancelled");
  const idDir = await off1.db.expenses.submit({ categoryId: "delivery", description: "E2E33 delivery", amount: "15.50", expenseDate: today, orderId: o1.id });
  check("E14", "an officer submits a direct expense on their own order", (await off1.db.expenses.list()).some((e) => e.id === idDir && e.orderId === o1.id && e.kind === "direct_order"));
  const wrong = await errOf(() => off1.db.expenses.submit({ categoryId: "delivery", description: "E2E33 other", amount: "9.00", expenseDate: today, orderId: o2.id }));
  check("E15", "...but not on another officer's order", /cannot see it/i.test(wrong ?? ""), wrong ?? "accepted");
  check("E16", "a direct expense without an order is refused", /must name its order/i.test((await errOf(() => cs.db.expenses.submit({ categoryId: "delivery", description: "x", amount: "1.00", expenseDate: today }))) ?? ""));
  await ops.db.expenses.decide(idDir, "approve");

  // ---- payments ----
  check("E17", "an approver without pay cannot pay... (ops has pay) so a non-payer is refused", /not allowed to record/i.test((await errOf(() => cs.db.expenses.recordPayment(id1, { amount: "10.00", paidOn: today, method: "Cash" }))) ?? ""));
  const p1 = await ops.db.expenses.recordPayment(id1, { amount: "50.00", paidOn: today, method: "EVC Plus", reference: "E2E33-1" });
  let ex = (await ops.db.expenses.list()).find((e) => e.id === id1);
  check("E18", "a partial payment: status partial, paid 50, outstanding 80", ex.paymentStatus === "partial" && ex.paidAmount === 50 && ex.outstandingAmount === 80, JSON.stringify([ex.paymentStatus, ex.paidAmount, ex.outstandingAmount]));
  check("E19", "overpaying is refused", /more than the approved/i.test((await errOf(() => ops.db.expenses.recordPayment(id1, { amount: "80.01", paidOn: today, method: "Cash" }))) ?? ""));
  const pays = await ops.db.expenses.payments(id1);
  check("E20", "payments load mapped", pays.length === 1 && pays[0].amount === 50 && pays[0].method === "EVC Plus" && pays[0].voidedAt === null);
  const ev = await ops.db.expenses.events(id1);
  check("E21", "the timeline loads in order with who did what", ev.map((x) => x.event).join(",") === "submitted,edited,rejected,resubmitted,approved,payment_recorded" && ev.every((x) => x.actorName), ev.map((x) => x.event).join(","));
  check("E22", "void with active payments is refused", /payments of this expense first/i.test((await errOf(() => ops.db.expenses.void(id1, "E2E33 cleanup"))) ?? ""));

  // ---- profit chain on real orders: gross profit must equal the Financial page's own figure ----
  const costs = await ops.db.financeCosts.expenses();
  const comms = await ops.db.financeCosts.commissions();
  check("E23", "finance_expense_costs returns approved expenses, mapped, with no description/vendor", costs.some((c) => c.expenseId === id1 && c.amount === 130) && costs.every((c) => !("description" in c) && !("vendor" in c)));
  check("E24", "finance_commission_costs returns non-void commissions, mapped", comms.length > 0 && comms.every((c) => c.status !== "void" && typeof c.amount === "number" && c.attributedAt));
  const ordersFull = await ops.db.orders.listAll();
  const ds = buildDataset(ordersFull, await ops.db.products.list(), await ops.db.customers.list({ includeArchived: true }));
  const range = { from: monthStart, to: today };
  const figures = periodFigures(ds, NO_FILTERS, range);
  const pm = profitModel({ ds, filters: NO_FILTERS, range, expenses: costs, commissions: comms });
  check("E25", "chain gross profit and revenue equal the Financial page's figures (no second calculation)", pm.chain.grossProfitCents === figures.grossProfitCents && pm.chain.deliveredRevenueCents === figures.deliveredRevenueCents && pm.chain.cogsCents === figures.costCents, JSON.stringify([pm.chain.grossProfitCents, figures.grossProfitCents]));
  const c = pm.chain;
  check("E26", "contribution and net follow the formulas", c.contributionProfitCents === c.grossProfitCents - c.directExpensesCents - c.cancelledOrderExpensesCents - c.commissionsCents && c.netOperatingProfitCents === c.contributionProfitCents - c.operatingExpensesCents);
  const approvedThisMonth = costs.filter((x) => x.expenseDate >= monthStart && x.expenseDate <= today && x.kind === "operating").reduce((a, x) => a + Math.round(x.amount * 100), 0);
  check("E27", "operating expenses in the chain = approved operating expenses of the month", c.operatingExpensesCents === approvedThisMonth, `${c.operatingExpensesCents} vs ${approvedThisMonth}`);
  check("E28", "per-order rows are computed on real data (the exact reconciliation is proved in the unit test)", Number.isFinite(pm.orders.reduce((a, o) => a + (o.netProfitCents ?? 0), 0)));

  // ---- access ----
  check("E29", "an officer without reports is refused the cost reads", /Permission denied|needs|not allowed|reports/i.test((await errOf(() => off1.db.financeCosts.commissions())) ?? "") && !!(await errOf(() => off1.db.financeCosts.expenses())));
  check("E30", "a submitter without view/approve cannot see other people's expenses", (await cs.db.expenses.list()).every((e) => e.submittedBy === "u-stg-cs"));
  const dash = summarizeExpenses(await ops.db.expenses.list());
  check("E31", "dashboard figures add up (approved = paid + outstanding)", dash.approvedCents === dash.paidCents + dash.outstandingCents, JSON.stringify(dash));

  // ---- clean up the test expenses so they no longer count: void payments, void approved (by someone other than the submitter), withdraw ----
  for (const p of await ops.db.expenses.payments(id1)) if (!p.voidedAt) await ops.db.expenses.voidPayment(p.id, "E2E33 cleanup");
  await ops.db.expenses.void(id1, "E2E33 cleanup");
  await ops.db.expenses.void(idSa, "E2E33 cleanup");
  await ops.db.expenses.void(idDir, "E2E33 cleanup");
  const after = await sa.db.expenses.list();
  check("E32", "all test expenses are void and kept in the history", [id1, idSa, idDir].every((id) => after.find((e) => e.id === id)?.status === "void"));
  void p1;
} catch (error) {
  console.log("FAIL ABORTED", describeDbError(error));
  results.push(false);
} finally {
  // restore the exact permission sets
  try {
    if (sa) for (const [id, perms] of original) await sa.db.users.setPermissions(id, perms);
    if (sa) {
      const now = await sa.db.users.list();
      const leaked = [...original.keys()].filter((id) => now.find((u) => u.id === id).permissions.some((p) => NEW.includes(p)) && !original.get(id).some((p) => NEW.includes(p)));
      check("R1", "permission sets restored exactly", leaked.length === 0 && [...original].every(([id, p]) => JSON.stringify([...now.find((u) => u.id === id).permissions].sort()) === JSON.stringify([...p].sort())));
    }
  } catch (e) { check("R1", "permission sets restored", false, describeDbError(e)); }
}
const failed = results.filter((x) => !x).length;
console.log(`\nE2E33: ${results.length - failed} PASS, ${failed} FAIL`);
process.exit(failed ? 1 : 0);
