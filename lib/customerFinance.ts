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
  /** migration 24: minimum whole days as an approved customer; empty = no such requirement. */
  minApprovedDays: number | null;
  /** migration 24: ceiling on the customer's TOTAL outstanding balance; empty = only the personal limit applies. */
  maxOutstanding: number | null;
  /** migration 24: a credit invoice past its due date with a balance stops credit (on by default). */
  requireNoOverdue: boolean;
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
  /** unmet REQUIREMENTS: staff may authorize credit anyway with a recorded override. */
  reasons: string[];
  /** account STANDING (unpaid or overdue balance, ceiling reached): never overridable. Absent before migration 24. */
  standingReasons?: string[];
  daysApproved?: number;
  overdueAmount?: number | string;
};
export type CreditAccount = { customer_id: string; status: "approved" | "suspended"; credit_limit: number | string; terms_days: number; reason: string; override_used: boolean; set_at: string };
export type CreditOverviewRow = { customerId: string; name: string; eligibility: Eligibility; outstanding: number | string; account: CreditAccount | null };

export type CreditHistory = {
  account: { status: string; credit_limit: number | string; terms_days: number; reason: string; override_used: boolean; set_at: string } | null;
  events: { at: string; by: string; message: string; event: string }[];
  orders: { orderId: string; date: string; dueDate: string; termsDays: number; limitAtTime: number | string; total: number | string; paid: number | string; outstanding: number | string; status: string; overdue: boolean }[];
};

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
  if (p.minApprovedDays !== null && (!Number.isInteger(p.minApprovedDays) || p.minApprovedDays < 1)) return "The period as an approved customer must be a whole number of days, at least 1.";
  if (p.maxOutstanding !== null && !(p.maxOutstanding > 0)) return "The maximum outstanding balance must be more than 0.";
  if (p.defaultTermsDays !== null && (!Number.isInteger(p.defaultTermsDays) || p.defaultTermsDays < 1 || p.defaultTermsDays > 365)) return "The repayment period must be 1 to 365 days.";
  if (p.enabled && p.minCompletedPurchases === null && p.minTotalValue === null && p.minApprovedDays === null) return "Define a number of completed purchases, a minimum total value or a period as an approved customer before enabling credit.";
  if (p.enabled && p.defaultTermsDays === null) return "Define the default repayment period before enabling credit.";
  return null;
}

/** A credit limit and terms for one customer; an override reason is needed when the customer does not meet the policy. */
export function creditGrantProblem(i: { limit: number; termsDays: number; reason: string; overrideReason: string; eligible: boolean; standingReasons?: string[] }): string | null {
  if ((i.standingReasons ?? []).length > 0) return `The account standing does not allow credit: ${(i.standingReasons ?? []).join(" ")} This cannot be overridden; it clears when the balance is paid.`;
  if (!Number.isFinite(i.limit) || i.limit < 0 || i.limit > 1_000_000 || Math.round(i.limit * 100) !== i.limit * 100) return "The credit limit must be between 0 and 1,000,000, in whole cents.";
  if (!Number.isInteger(i.termsDays) || i.termsDays < 1 || i.termsDays > 365) return "The repayment period must be 1 to 365 days.";
  if (i.reason.trim().length < MIN_REASON) return `Give a reason (at least ${MIN_REASON} characters).`;
  if (!i.eligible && i.overrideReason.trim().length < MIN_OVERRIDE) return `This customer does not meet the policy. Record an override reason of at least ${MIN_OVERRIDE} characters, or do not grant credit.`;
  return null;
}

/** The six original arguments are sent alone when the three migration-24 settings are at their defaults, so the Hub still works against a database that has not had migration 24 yet. */
export function policyRpcArgs(p: CreditPolicyInput, reason: string) {
  const base = { p_enabled: p.enabled, p_min_purchases: p.minCompletedPurchases, p_min_value: p.minTotalValue, p_require_no_unpaid: p.requireNoUnpaidDelivered, p_default_terms_days: p.defaultTermsDays, p_reason: reason };
  if (p.minApprovedDays === null && p.maxOutstanding === null && p.requireNoOverdue) return base;
  return { ...base, p_min_approved_days: p.minApprovedDays, p_max_outstanding: p.maxOutstanding, p_require_no_overdue: p.requireNoOverdue };
}

export const money = (n: number | string) => `$${Number(n).toFixed(2)}`;
