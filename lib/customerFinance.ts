/**
 * Customer payments and credit (migration 23): the Hub's types and the pure rules the screen uses to explain things before the database
 * answers. The database is the authority; every one of these is only a pre-check that mirrors an enforced rule.
 */

export type PaymentMethodRow = { code: string; label: string; kind: "provider" | "staging_test"; enabled: boolean; sort_order: number; updated_at: string };

export type CreditPolicy = {
  enabled: boolean;
  minCompletedPurchases: number | null;
  minTotalValue: number | null;
  requireNoUnpaidDelivered: boolean;
  defaultTermsDays: number | null;
  updatedAt: string;
  note: string;
};
export type CreditPolicyInput = Omit<CreditPolicy, "updatedAt" | "note">;

export type Eligibility = {
  eligible: boolean;
  completedPurchases: number;
  completedValue: number;
  unpaidDeliveredOrders: number;
  reasons: string[];
};
export type CreditAccount = { customer_id: string; status: "approved" | "suspended"; credit_limit: number | string; terms_days: number; reason: string; override_used: boolean; set_at: string };
export type CreditOverviewRow = { customerId: string; name: string; eligibility: Eligibility; outstanding: number | string; account: CreditAccount | null };

export type ReviewCheckout = {
  id: string; customerId: string; customerName: string | null; status: "needs_review" | "reversed"; amount: number | string; method: string;
  providerRef: string | null; orderId: string | null; reason: string; createdAt: string;
};

export const MIN_REASON = 5;
export const MIN_OVERRIDE = 10;

/** What must be filled in before credit can be switched on (the same rule the database enforces). */
export function policyProblem(p: CreditPolicyInput, reason: string): string | null {
  if (reason.trim().length < MIN_REASON) return `Give a reason (at least ${MIN_REASON} characters).`;
  if (p.minCompletedPurchases !== null && (!Number.isInteger(p.minCompletedPurchases) || p.minCompletedPurchases < 1)) return "The number of completed purchases must be a whole number of at least 1.";
  if (p.minTotalValue !== null && !(p.minTotalValue > 0)) return "The minimum purchase value must be more than 0.";
  if (p.defaultTermsDays !== null && (!Number.isInteger(p.defaultTermsDays) || p.defaultTermsDays < 1 || p.defaultTermsDays > 365)) return "The repayment period must be 1 to 365 days.";
  if (p.enabled && p.minCompletedPurchases === null && p.minTotalValue === null) return "Define a number of completed purchases or a minimum total value before enabling credit.";
  if (p.enabled && p.defaultTermsDays === null) return "Define the default repayment period before enabling credit.";
  return null;
}

/** A credit limit and terms for one customer; an override reason is needed when the customer does not meet the policy. */
export function creditGrantProblem(i: { limit: number; termsDays: number; reason: string; overrideReason: string; eligible: boolean }): string | null {
  if (!Number.isFinite(i.limit) || i.limit < 0 || i.limit > 1_000_000 || Math.round(i.limit * 100) !== i.limit * 100) return "The credit limit must be between 0 and 1,000,000, in whole cents.";
  if (!Number.isInteger(i.termsDays) || i.termsDays < 1 || i.termsDays > 365) return "The repayment period must be 1 to 365 days.";
  if (i.reason.trim().length < MIN_REASON) return `Give a reason (at least ${MIN_REASON} characters).`;
  if (!i.eligible && i.overrideReason.trim().length < MIN_OVERRIDE) return `This customer does not meet the policy. Record an override reason of at least ${MIN_OVERRIDE} characters, or do not grant credit.`;
  return null;
}

export const money = (n: number | string) => `$${Number(n).toFixed(2)}`;
