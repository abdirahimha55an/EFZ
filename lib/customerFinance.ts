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
  /** migration 25 (absent before it): the approved credit policy v2 settings. */
  purchaseWindowDays?: number | null;
  initialCreditLimit?: number | null;
  companyCapPercent?: number | null;
  capBasisMonths?: number | null;
  allowRequirementOverride?: boolean;
  autoLimitIncreaseEnabled?: boolean;
  lateFeesEnabled?: boolean;
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
  openDisputes?: number;
  defaultHistory?: { count: number; open: number; lastDefaultedOn: string | null; lastSettledOn: string | null; requalifyingFrom: string | null };
};
export type CreditAccount = { customer_id: string; status: "approved" | "suspended"; credit_limit: number | string; terms_days: number; reason: string; override_used: boolean; set_at: string };
export type CreditOverviewRow = { customerId: string; name: string; eligibility: Eligibility; outstanding: number | string; account: CreditAccount | null };

export type CreditHistory = {
  defaults?: { id: string; orderId: string; dueDate: string; defaultedOn: string; amountAtDefault: number | string; settledAt: string | null; requalifiedAt: string | null; voidedAt: string | null; voidReason: string | null; reviewRequiredAt: string | null; reviewedAt: string | null; reviewNote: string | null }[];
  disputes?: { id: string; orderId: string; status: string; reason: string; openedAt: string; resolution: string; assignedTo: string | null }[];
  reminders?: { orderId: string; kind: string; audience: string; status: string; attempts: number; lastError: string; sentAt: string | null }[];
  account: { status: string; credit_limit: number | string; terms_days: number; reason: string; override_used: boolean; set_at: string } | null;
  events: { at: string; by: string; message: string; event: string }[];
  orders: { orderId: string; date: string; dueDate: string; originalDueDate?: string; issueDate?: string; extensions?: { previousDue: string; newDue: string; by: string; reason: string; at: string }[]; termsDays: number; limitAtTime: number | string; total: number | string; paid: number | string; outstanding: number | string; status: string; overdue: boolean }[];
};

export type CompanyCap = { configured: boolean; sufficient: boolean; reason: string; windowStart?: string; windowEnd?: string; months?: number; revenue?: number | string; averageMonthly?: number | string; percent?: number | string; cap?: number | string | null; outstanding: number | string; available: number | string };
export type CreditDefaultRow = { id: string; customerId: string; customerName: string; orderId: string; dueDate: string; defaultedOn: string; amountAtDefault: number | string; outstanding: number | string; daysOverdue: number | null; status: "open" | "settled" | "voided"; settledAt: string | null; requalifiedAt: string | null; followUpDue: boolean; reviewRequiredAt: string | null; reviewedAt: string | null; reviewNote: string | null; voidedAt: string | null };
export type CreditOperations = { asOf: string; companyCap: CompanyCap; defaults: CreditDefaultRow[]; failedReminders: { id: number; orderId: string; kind: string; audience: string; attempts: number; lastError: string; createdAt: string }[]; openDisputes: number };
export type CreditDispute = { id: string; customerId: string; customerName: string; orderId: string; reason: string; disputedAmount: number | string | null; status: "open" | "investigating" | "resolved_billing_error" | "resolved_rejected" | "withdrawn"; openedBy: string; openedAt: string; assignedTo: string | null; staffNotes: string; resolution: string; resolvedBy: string | null; resolvedAt: string | null; defaultId: string | null };

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

/** An extension needs a reason, a later date, and an invoice that has not yet passed its due date (the database enforces the same). */
export function extensionProblem(i: { currentDue: string; newDue: string; reason: string; today: string }): string | null {
  if (i.reason.trim().length < MIN_OVERRIDE) return `Give a reason of at least ${MIN_OVERRIDE} characters.`;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(i.newDue)) return "Pick the new due date.";
  if (i.currentDue < i.today) return "The invoice is already past its due date; a default cannot be undone by an extension.";
  if (i.newDue <= i.currentDue) return `The new due date must be later than the current one (${i.currentDue}).`;
  return null;
}
/** Resolving a dispute and recording a risk review both need a documented note. */
export function noteProblem(note: string, min = MIN_OVERRIDE): string | null { return note.trim().length < min ? `Write at least ${min} characters.` : null; }
/** Whether the Hub should offer "void this default": only after a dispute on the same invoice was resolved as a billing error. */
export function canVoidDefault(d: { status: string; voidedAt: string | null }, disputes: { orderId: string; status: string }[], orderId: string): boolean {
  return d.status !== "voided" && d.voidedAt === null && disputes.some((x) => x.orderId === orderId && x.status === "resolved_billing_error");
}
export function capSummary(c: CompanyCap): string {
  if (!c.configured) return "The company-wide cap is not configured.";
  if (!c.sufficient) return `Not computable: ${c.reason}`;
  return `Cap $${Number(c.cap).toFixed(2)} (${c.percent}% of the $${Number(c.averageMonthly).toFixed(2)} average monthly sales over ${c.months} complete months); $${Number(c.outstanding).toFixed(2)} outstanding, $${Number(c.available).toFixed(2)} available.`;
}
export function rulesProblem(r: { purchaseWindowDays: number | null; initialLimit: number | null; capPercent: number | null; capMonths: number | null }, reason: string): string | null {
  if (reason.trim().length < MIN_REASON) return `Give a reason (at least ${MIN_REASON} characters).`;
  if (r.purchaseWindowDays !== null && (!Number.isInteger(r.purchaseWindowDays) || r.purchaseWindowDays < 1)) return "The purchase-history window must be a whole number of days, at least 1.";
  if (r.initialLimit !== null && (!(r.initialLimit > 0) || r.initialLimit > 1_000_000 || Math.round(r.initialLimit * 100) !== r.initialLimit * 100)) return "The initial limit must be more than 0, in whole cents.";
  if (r.capPercent !== null && !(r.capPercent > 0 && r.capPercent <= 100)) return "The company-wide cap must be above 0% and at most 100%.";
  if (r.capMonths !== null && (!Number.isInteger(r.capMonths) || r.capMonths < 1 || r.capMonths > 24)) return "The cap basis must be 1 to 24 complete calendar months.";
  return null;
}

export const money = (n: number | string) => `$${Number(n).toFixed(2)}`;
