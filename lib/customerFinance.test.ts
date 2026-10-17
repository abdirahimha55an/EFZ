// Hub pre-checks for customer payments and credit (they mirror rules the database enforces). Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import { creditGrantProblem, money, policyProblem } from "./customerFinance.ts";

const off = { enabled: false, minCompletedPurchases: null, minTotalValue: null, requireNoUnpaidDelivered: true, defaultTermsDays: null };

test("a policy change needs a reason; credit stays off with empty thresholds", () => {
  assert.match(policyProblem(off, "") as string, /reason/);
  assert.equal(policyProblem(off, "keep it off"), null);
});
test("credit cannot be enabled without a purchase requirement and a repayment period (EFZ decides them, nothing is invented)", () => {
  assert.match(policyProblem({ ...off, enabled: true }, "enable now") as string, /completed purchases or a minimum total value/);
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
test("money is shown with two decimals", () => { assert.equal(money(5), "$5.00"); assert.equal(money("12.5"), "$12.50"); });
