// Tests for the review screen's presentation rules and the query layer's calls. Run: npm run test:hub
// (Node's built-in runner + scripts/test-loader.mjs; no framework). The business rules themselves live in the database
// and are tested in supabase/checks/21_customer_accounts_checks.sql; browser behaviour against Staging is tested separately.
import { test } from "node:test";
import assert from "node:assert/strict";
import { allowedActions, approvalProblem, countByStatus, filterAccounts, reasonProblem } from "./customerAccounts.ts";
import { derivePermissions } from "./permissions.ts";
import { createDb, describeDbError } from "./supabase/queries.ts";
import type { AdminProfile, CustomerAccount, CustomerAccountMatch } from "./types/index.ts";

const acct = (o: Partial<CustomerAccount> = {}): CustomerAccount => ({
  id: "a1", email: "x@example.test", fullName: "Amina Buyer", organization: "Club X", phone: "061 234 5678", status: "pending", customerId: null,
  requestedAt: "2026-10-01T10:00:00Z", reviewedByName: "", reviewedAt: null, reviewNote: "", ...o,
});
const match = (o: Partial<CustomerAccountMatch> = {}): CustomerAccountMatch => ({ customerId: "cust-1", name: "Club X", phoneMasked: "******678", status: "active", linked: false, orders: 3, ...o });
const draft = (o = {}) => ({ mode: null as "link" | "create" | null, linkCustomerId: null as string | null, verified: false, note: "", ...o });

// ------------------------------------------------------------------ permissions (UI flag only; the database is the control)
const profile = (role: string, perms: string[], status = "active") => ({ id: "u", name: "n", email: "e", role, status, permissions: perms } as unknown as AdminProfile);
test("manageCustomerAccounts: Super Admin and explicit holders only", () => {
  assert.equal(derivePermissions(profile("Super Admin", [])).manageCustomerAccounts, true);
  assert.equal(derivePermissions(profile("Manager", ["manage_customer_accounts"])).manageCustomerAccounts, true);
  assert.equal(derivePermissions(profile("Manager", ["manage_users", "view_orders"])).manageCustomerAccounts, false);
  assert.equal(derivePermissions(profile("Marketing Officer", [])).manageCustomerAccounts, false);
  assert.equal(derivePermissions(null).manageCustomerAccounts, false);
  assert.equal(derivePermissions(profile("Super Admin", [], "inactive")).manageCustomerAccounts, false, "a suspended staff account holds nothing");
});

// ------------------------------------------------------------------ which actions are offered
test("actions follow the legal transitions; a rejected account is final", () => {
  assert.deepEqual(allowedActions("pending"), ["approve", "reject"]);
  assert.deepEqual(allowedActions("approved"), ["suspend"]);
  assert.deepEqual(allowedActions("suspended"), ["reinstate"]);
  assert.deepEqual(allowedActions("rejected"), []);
});

// ------------------------------------------------------------------ approval form (UX gating only)
test("linking an existing customer always needs the explicit verification box", () => {
  const m = [match()];
  assert.match(approvalProblem(draft({ mode: "link", linkCustomerId: "cust-1", verified: false, note: "Called and confirmed the club" }), m)!, /verified this person/);
  assert.equal(approvalProblem(draft({ mode: "link", linkCustomerId: "cust-1", verified: true, note: "Called and confirmed the club" }), m), null);
});
test("a phone match alone is never enough: nothing is selected by default and the form stays incomplete", () => {
  assert.match(approvalProblem(draft(), [match()])!, /Choose/);
  assert.match(approvalProblem(draft({ mode: "link", linkCustomerId: null }), [match()])!, /Select the customer/);
});
test("creating a new customer when the phone already belongs to someone needs the 'different person' confirmation", () => {
  const note = "Called, different shop";
  assert.match(approvalProblem(draft({ mode: "create", verified: false, note }), [match()])!, /different person/);
  assert.equal(approvalProblem(draft({ mode: "create", verified: true, note }), [match()]), null);
  assert.equal(approvalProblem(draft({ mode: "create", verified: false, note }), []), null, "no phone match: no confirmation needed");
});
test("an already-linked or inactive candidate can never be chosen", () => {
  const note = "Called and confirmed the club";
  assert.match(approvalProblem(draft({ mode: "link", linkCustomerId: "cust-1", verified: true, note }), [match({ linked: true })])!, /already linked/);
  assert.match(approvalProblem(draft({ mode: "link", linkCustomerId: "cust-1", verified: true, note }), [match({ status: "archived" })])!, /active/);
});
test("a verification note is required (10 characters) and so is a reason (5)", () => {
  assert.match(approvalProblem(draft({ mode: "create", verified: true, note: "short" }), [])!, /at least 10/);
  assert.match(reasonProblem("no")!, /at least 5/);
  assert.equal(reasonProblem("Dispute"), null);
});

// ------------------------------------------------------------------ list helpers
test("filter by status and search never mutates or leaks other accounts", () => {
  const list = [acct({ id: "1" }), acct({ id: "2", status: "approved", fullName: "Omar Shop", phone: "069 999 0000" }), acct({ id: "3", status: "rejected" })];
  assert.deepEqual(filterAccounts(list, "pending", "").map((a) => a.id), ["1"]);
  assert.deepEqual(filterAccounts(list, "all", "omar").map((a) => a.id), ["2"]);
  assert.deepEqual(filterAccounts(list, "all", "0000").map((a) => a.id), ["2"]);
  assert.deepEqual(countByStatus(list), { pending: 1, approved: 1, rejected: 1, suspended: 0 });
  assert.equal(list.length, 3);
});

// ------------------------------------------------------------------ query layer with a recording fake client
type Call = { kind: "rpc" | "from"; name: string; args?: Record<string, unknown>; select?: string };
function fake(over: { rows?: unknown[]; rpc?: Record<string, { data?: unknown; error?: { code: string; message: string; details?: string; hint?: string } }>; }) {
  const calls: Call[] = [];
  const client = {
    from(table: string) {
      const c: Call = { kind: "from", name: table }; calls.push(c);
      const chain: Record<string, unknown> = {};
      for (const m of ["select", "order", "limit", "eq"]) chain[m] = (...a: unknown[]) => { if (m === "select") c.select = String(a[0]); return chain; };
      (chain as { then: unknown }).then = (res: (v: unknown) => unknown) => res({ data: over.rows ?? [], error: null });
      return chain;
    },
    async rpc(name: string, args: Record<string, unknown>) { calls.push({ kind: "rpc", name, args }); const r = over.rpc?.[name]; return { data: r?.data ?? null, error: r?.error ?? null }; },
  };
  return { db: createDb(client as never), calls };
}
const row = (o: Record<string, unknown>) => ({ id: "a", email: "e@example.test", full_name: "N", organization: "", phone: "061", status: "pending", customer_id: null, requested_at: "2026-10-01T00:00:00Z", reviewed_by_name: "", reviewed_at: null, review_note: "", ...o });

test("list: loads only the safe columns, pending oldest first, then the rest newest first", async () => {
  const { db, calls } = fake({ rows: [row({ id: "new-pending", requested_at: "2026-10-05T00:00:00Z" }), row({ id: "approved", status: "approved" }), row({ id: "old-pending", requested_at: "2026-10-01T00:00:00Z" })] });
  const list = await db.customerAccounts.list();
  assert.deepEqual(list.map((a) => a.id), ["old-pending", "new-pending", "approved"]);
  const sel = calls[0].select!;
  for (const secret of ["ip_hash", "auth_user_id", "phone_canonical", "created_at", "updated_at", "reviewed_by,"]) assert.ok(!sel.includes(secret), `must not select ${secret}`);
  assert.ok(sel.includes("full_name") && sel.includes("status"));
});
test("list: no permission means the database returns no rows, which is an empty list, not a crash", async () => {
  assert.deepEqual(await fake({ rows: [] }).db.customerAccounts.list(), []);
});
test("candidates: calls find_customers_for_account with the account id only and maps the masked rows", async () => {
  const { db, calls } = fake({ rpc: { find_customers_for_account: { data: [{ customer_id: "cust-1", name: "Club X", phone_masked: "******678", status: "active", linked: false, orders: "3" }] } } });
  const m = await db.customerAccounts.candidates("acc-1");
  assert.deepEqual(calls[0], { kind: "rpc", name: "find_customers_for_account", args: { p_account_id: "acc-1" } });
  assert.deepEqual(m, [{ customerId: "cust-1", name: "Club X", phoneMasked: "******678", status: "active", linked: false, orders: 3 }]);
});
test("approve linking an existing customer sends the verification flag and the note, and nothing about commission or owners", async () => {
  const { db, calls } = fake({ rpc: { approve_customer_account: { data: "cust-1" } } });
  const id = await db.customerAccounts.approve({ accountId: "a", linkCustomerId: "cust-1", verified: true, note: "Called and confirmed" });
  assert.equal(id, "cust-1");
  assert.deepEqual(calls[0].args, { p_account_id: "a", p_customer_id: "cust-1", p_create_customer: false, p_verified: true, p_note: "Called and confirmed" });
  assert.ok(!Object.keys(calls[0].args!).some((k) => /officer|commission|owner/i.test(k)));
});
test("approve creating a new customer sends no customer id", async () => {
  const { db, calls } = fake({ rpc: { approve_customer_account: { data: "cust-new" } } });
  await db.customerAccounts.approve({ accountId: "a", linkCustomerId: null, verified: false, note: "Called, new buyer" });
  assert.deepEqual(calls[0].args, { p_account_id: "a", p_customer_id: null, p_create_customer: true, p_verified: false, p_note: "Called, new buyer" });
});
test("reject / suspend / reinstate call their own functions with the reason", async () => {
  const { db, calls } = fake({});
  await db.customerAccounts.reject("a", "Could not verify"); await db.customerAccounts.suspend("a", "Dispute"); await db.customerAccounts.reinstate("a", "Resolved");
  assert.deepEqual(calls.map((c) => [c.name, c.args]), [
    ["reject_customer_account", { p_account_id: "a", p_reason: "Could not verify" }],
    ["suspend_customer_account", { p_account_id: "a", p_reason: "Dispute" }],
    ["reinstate_customer_account", { p_account_id: "a", p_reason: "Resolved" }]]);
});
test("database refusals reach the user as the database's own sentence", async () => {
  const cases: [string, string, RegExp][] = [
    ["42501", "Permission denied: manage_customer_accounts is required", /needs the manage_customer_accounts permission/],
    ["22023", "Linking an existing customer needs your explicit confirmation that you verified this person", /explicit confirmation/],
    ["22023", "That customer is already linked to an app account", /already linked/],
    ["42501", "Only a pending account can be approved (this one is approved)", /Only a pending account/],
    ["42501", "new row violates row-level security policy for table \"customer_accounts\"", /Permission denied: your account is not allowed/],
  ];
  for (const [code, message, expect] of cases) {
    const { db } = fake({ rpc: { approve_customer_account: { error: { code, message } } } });
    await assert.rejects(db.customerAccounts.approve({ accountId: "a", linkCustomerId: "c", verified: true, note: "Called and confirmed" }), (e) => { assert.match(describeDbError(e), expect); return true; });
  }
});
test("a failed lookup surfaces as an error for the screen's error state", async () => {
  const { db } = fake({ rpc: { find_customers_for_account: { error: { code: "42501", message: "Permission denied: manage_customer_accounts is required" } } } });
  await assert.rejects(db.customerAccounts.candidates("a"), /customerAccounts.candidates/);
});
