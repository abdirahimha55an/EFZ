// Hub pre-checks for customer payments and credit (they mirror rules the database enforces). Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import { creditGrantProblem, money, policyProblem, policyRpcArgs } from "./customerFinance.ts";

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
