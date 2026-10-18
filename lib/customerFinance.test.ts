// Hub pre-checks for customer payments and credit (they mirror rules the database enforces). Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import { canVoidDefault, capSummary, creditGrantProblem, extensionProblem, money, noteProblem, policyProblem, policyRpcArgs, rulesProblem } from "./customerFinance.ts";

const off = { enabled: false, minCompletedPurchases: null, minTotalValue: null, requireNoUnpaidDelivered: true, defaultTermsDays: null, minApprovedDays: null, maxOutstanding: null, requireNoOverdue: true };

test("a policy change needs a reason; credit stays off with empty thresholds", () => {
  assert.match(policyProblem(off, "") as string, /reason/);
  assert.equal(policyProblem(off, "keep it off"), null);
});
test("credit cannot be enabled without a purchase requirement and a repayment period (EFZ decides them, nothing is invented)", () => {
  assert.match(policyProblem({ ...off, enabled: true }, "enable now") as string, /completed purchases, a minimum total value or a period as an approved customer/);
  assert.match(policyProblem({ ...off, enabled: true, minCompletedPurchases: 3 }, "enable now") as string, /repayment period/);
  assert.equal(policyProblem({ ...off, enabled: true, minCompletedPurchases: 3, defaultTermsDays: 30 }, "enable now"), null);
  assert.equal(policyProblem({ ...off, enabled: true, minTotalValue: 500, defaultTermsDays: 14 }, "enable now"), null);
});
test("policy values are validated", () => {
  for (const bad of [{ minCompletedPurchases: 0 }, { minCompletedPurchases: 1.5 }, { minTotalValue: 0 }, { minTotalValue: -5 }, { defaultTermsDays: 0 }, { defaultTermsDays: 366 }]) {
    assert.ok(policyProblem({ ...off, ...bad }, "valid reason"), JSON.stringify(bad));
  }
});
test("granting credit: limit, terms and reason are validated; an ineligible customer needs a recorded override", () => {
  const ok = { limit: 150, termsDays: 14, reason: "agreed by management", overrideReason: "", eligible: true };
  assert.equal(creditGrantProblem(ok), null);
  for (const bad of [{ limit: -1 }, { limit: 2_000_000 }, { limit: 10.005 }, { termsDays: 0 }, { termsDays: 400 }, { termsDays: 1.5 }, { reason: "no" }]) assert.ok(creditGrantProblem({ ...ok, ...bad }), JSON.stringify(bad));
  assert.match(creditGrantProblem({ ...ok, eligible: false }) as string, /override/i);
  assert.match(creditGrantProblem({ ...ok, eligible: false, overrideReason: "short" }) as string, /override/i);
  assert.equal(creditGrantProblem({ ...ok, eligible: false, overrideReason: "policy exception approved by the owner" }), null);
});
test("migration 24: a period as an approved customer alone is a valid requirement; the new values are validated", () => {
  assert.equal(policyProblem({ ...off, enabled: true, minApprovedDays: 30, defaultTermsDays: 14 }, "enable now"), null);
  for (const bad of [{ minApprovedDays: 0 }, { minApprovedDays: 2.5 }, { maxOutstanding: 0 }, { maxOutstanding: -10 }]) assert.ok(policyProblem({ ...off, ...bad }, "valid reason"), JSON.stringify(bad));
  assert.equal(policyProblem({ ...off, maxOutstanding: 500 }, "valid reason"), null);
});
test("migration 24: account standing can never be overridden, and the message says why", () => {
  const ok = { limit: 150, termsDays: 14, reason: "agreed by management", overrideReason: "policy exception approved by the owner", eligible: false };
  assert.match(creditGrantProblem({ ...ok, standingReasons: ["A credit invoice is overdue ($30.00)."] }) as string, /cannot be overridden/);
  assert.equal(creditGrantProblem({ ...ok, standingReasons: [] }), null);
  assert.equal(creditGrantProblem({ ...ok, standingReasons: undefined }), null);
});
test("migration 24: the original six arguments are sent alone while the new settings are at their defaults (works before and after the migration)", () => {
  const six = policyRpcArgs(off, "keep it off");
  assert.deepEqual(Object.keys(six).sort(), ["p_default_terms_days", "p_enabled", "p_min_purchases", "p_min_value", "p_reason", "p_require_no_unpaid"]);
  const nine = policyRpcArgs({ ...off, minApprovedDays: 30 }, "set days");
  assert.equal(nine.p_min_approved_days, 30); assert.equal(nine.p_max_outstanding, null); assert.equal(nine.p_require_no_overdue, true);
  assert.equal(policyRpcArgs({ ...off, requireNoOverdue: false }, "relax overdue").p_require_no_overdue, false);
  assert.equal(policyRpcArgs({ ...off, maxOutstanding: 500 }, "ceiling").p_max_outstanding, 500);
});
test("money is shown with two decimals", () => { assert.equal(money(5), "$5.00"); assert.equal(money("12.5"), "$12.50"); });

test("migration 25: the extension form mirrors the database (reason, later date, not already overdue)", () => {
  const ok = { currentDue: "2026-11-10", newDue: "2026-11-20", reason: "Customer travelling; agreed", today: "2026-11-01" };
  assert.equal(extensionProblem(ok), null);
  assert.match(extensionProblem({ ...ok, reason: "short" }) as string, /reason/);
  assert.match(extensionProblem({ ...ok, newDue: "" }) as string, /Pick/);
  assert.match(extensionProblem({ ...ok, newDue: "2026-11-10" }) as string, /later than/);
  assert.match(extensionProblem({ ...ok, currentDue: "2026-10-30" }) as string, /past its due date/);
});
test("migration 25: notes, rules and the void rule", () => {
  assert.ok(noteProblem("short")); assert.equal(noteProblem("a documented note"), null);
  const r = { purchaseWindowDays: 90, initialLimit: 40, capPercent: 25, capMonths: 3 };
  assert.equal(rulesProblem(r, "approved proposal"), null);
  for (const bad of [{ purchaseWindowDays: 0 }, { initialLimit: 0 }, { initialLimit: 10.005 }, { capPercent: 0 }, { capPercent: 101 }, { capMonths: 0 }, { capMonths: 25 }]) assert.ok(rulesProblem({ ...r, ...bad }, "valid reason"), JSON.stringify(bad));
  assert.ok(rulesProblem(r, "no"));
  const d = { status: "settled", voidedAt: null };
  assert.equal(canVoidDefault(d, [{ orderId: "o1", status: "open" }], "o1"), false);
  assert.equal(canVoidDefault(d, [{ orderId: "o2", status: "resolved_billing_error" }], "o1"), false);
  assert.equal(canVoidDefault(d, [{ orderId: "o1", status: "resolved_billing_error" }], "o1"), true);
  assert.equal(canVoidDefault({ status: "voided", voidedAt: "2026-10-01" }, [{ orderId: "o1", status: "resolved_billing_error" }], "o1"), false);
});
test("migration 25: the company cap is explained, and an insufficient history is said plainly", () => {
  assert.match(capSummary({ configured: false, sufficient: false, reason: "", outstanding: 0, available: 0 }), /not configured/);
  assert.match(capSummary({ configured: true, sufficient: false, reason: "There is no sales history.", outstanding: 0, available: 0 }), /Not computable: There is no sales history/);
  assert.equal(capSummary({ configured: true, sufficient: true, reason: "", months: 3, percent: 25, averageMonthly: 200, cap: 50, outstanding: 30, available: 20 }), "Cap $50.00 (25% of the $200.00 average monthly sales over 3 complete months); $30.00 outstanding, $20.00 available.");
});
