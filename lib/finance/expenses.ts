/**
 * Expense management helpers: client-side validation that mirrors the database (which checks everything again), labels, which action
 * each person may take on a row, and the dashboard figures. Pure; money in cents.
 */

import type { Expense, ExpenseCategory, ExpenseInput, ExpenseKind, ExpenseStatus } from "@/lib/types";
import { toCents } from "@/lib/analytics/dataset";
import { isYmd } from "@/lib/dates";

export const STATUS_LABEL: Record<ExpenseStatus, string> = { pending: "Pending approval", approved: "Approved", rejected: "Rejected", void: "Void" };
export const KIND_LABEL: Record<ExpenseKind, string> = { direct_order: "Direct order expense", operating: "Operating expense" };
export const PAYMENT_LABEL = { unpaid: "Unpaid", partial: "Partly paid", paid: "Paid" } as const;
export const PAYMENT_METHODS = ["Cash", "EVC Plus", "Bank transfer", "Other"] as const;

export const LIMITS = { description: 300, vendor: 200, notes: 1000, method: 60, maxAmount: 1_000_000 } as const;

export type ExpenseErrors = Partial<Record<"categoryId" | "description" | "amount" | "expenseDate" | "orderId" | "vendor" | "notes", string>>;

/** The same rules as expense_clean() in migration 33, for instant feedback. The database remains the authority. */
export function validateExpense(input: ExpenseInput, categories: ExpenseCategory[], today: string): ExpenseErrors {
  const errors: ExpenseErrors = {};
  const category = categories.find((c) => c.id === input.categoryId && c.isActive);
  if (!category) errors.categoryId = "Please choose an expense category.";
  const description = input.description.trim();
  if (!description) errors.description = "Please describe the expense.";
  else if (description.length > LIMITS.description) errors.description = `Please keep it under ${LIMITS.description} characters.`;
  const amount = input.amount.trim();
  if (!/^\d+(\.\d{1,2})?$/.test(amount) || Number(amount) <= 0 || Number(amount) > LIMITS.maxAmount) {
    errors.amount = `Enter an amount above 0 and up to ${LIMITS.maxAmount.toLocaleString("en-US")}, with at most 2 decimals.`;
  }
  if (!isYmd(input.expenseDate) || input.expenseDate < "2020-01-01") errors.expenseDate = "Please give the expense date.";
  else if (input.expenseDate > today) errors.expenseDate = "The expense date cannot be in the future.";
  if (category?.kind === "direct_order" && !(input.orderId ?? "").trim()) errors.orderId = "A direct order expense must name its order.";
  if (category?.kind === "operating" && (input.orderId ?? "").trim()) errors.orderId = "An operating expense is not linked to an order.";
  if ((input.vendor ?? "").trim().length > LIMITS.vendor) errors.vendor = `Please keep it under ${LIMITS.vendor} characters.`;
  if ((input.notes ?? "").trim().length > LIMITS.notes) errors.notes = `Please keep it under ${LIMITS.notes} characters.`;
  return errors;
}

export type ExpenseActor = { id: string; submit: boolean; approve: boolean; pay: boolean };

/** What the signed-in person may do with one row. The database enforces the same rules; this only decides which buttons to offer. */
export function actionsFor(e: Expense, me: ExpenseActor) {
  const mine = e.submittedBy === me.id;
  const hasActivePayment = e.paidAmount > 0;
  return {
    edit: mine && me.submit && (e.status === "pending" || e.status === "rejected"),
    approve: me.approve && !mine && e.status === "pending",
    reject: me.approve && !mine && e.status === "pending",
    pay: me.pay && e.status === "approved" && e.outstandingAmount > 0,
    voidPayments: me.pay && e.status === "approved" && hasActivePayment,
    withdraw: (e.status === "pending" || e.status === "rejected") && ((mine && me.submit) || me.approve),
    voidApproved: me.approve && !mine && e.status === "approved" && !hasActivePayment,
  };
}

export type ExpenseFilter = { status: ExpenseStatus | "all"; kind: ExpenseKind | "all"; categoryId: string | "all"; from: string; to: string; mineOnly: boolean; search: string };
export const NO_EXPENSE_FILTER: ExpenseFilter = { status: "all", kind: "all", categoryId: "all", from: "", to: "", mineOnly: false, search: "" };

export function filterExpenses(rows: Expense[], f: ExpenseFilter, meId: string): Expense[] {
  const q = f.search.trim().toLowerCase();
  return rows.filter((e) =>
    (f.status === "all" || e.status === f.status) &&
    (f.kind === "all" || e.kind === f.kind) &&
    (f.categoryId === "all" || e.categoryId === f.categoryId) &&
    (!f.from || e.expenseDate >= f.from) && (!f.to || e.expenseDate <= f.to) &&
    (!f.mineOnly || e.submittedBy === meId) &&
    (!q || [e.reference, e.description, e.vendor, e.orderId ?? "", e.submittedByName].some((s) => s.toLowerCase().includes(q))));
}

export type ExpenseSummary = {
  pendingCount: number; pendingCents: number;
  approvedCount: number; approvedCents: number;
  paidCents: number; outstandingCents: number;
  rejectedCount: number; voidCount: number;
  /** Approved + pending: everything that is, or may become, a cost. */
  totalCents: number;
};

export function summarizeExpenses(rows: Pick<Expense, "status" | "amount" | "paidAmount" | "outstandingAmount">[]): ExpenseSummary {
  const s: ExpenseSummary = { pendingCount: 0, pendingCents: 0, approvedCount: 0, approvedCents: 0, paidCents: 0, outstandingCents: 0, rejectedCount: 0, voidCount: 0, totalCents: 0 };
  for (const e of rows) {
    const cents = toCents(e.amount);
    if (e.status === "pending") { s.pendingCount += 1; s.pendingCents += cents; }
    else if (e.status === "approved") { s.approvedCount += 1; s.approvedCents += cents; s.paidCents += toCents(e.paidAmount); s.outstandingCents += toCents(e.outstandingAmount); }
    else if (e.status === "rejected") s.rejectedCount += 1;
    else s.voidCount += 1;
  }
  s.totalCents = s.pendingCents + s.approvedCents;
  return s;
}

export type MonthlyExpense = { month: string; directCents: number; operatingCents: number; totalCents: number };

/** Approved expenses per calendar month of the expense date (accrual: approval makes it a cost; payment is a separate cash view). */
export function monthlyTrend(rows: { amount: number; kind: ExpenseKind; expenseDate: string }[], months: number, today: string): MonthlyExpense[] {
  const out = new Map<string, MonthlyExpense>();
  let [y, m] = today.split("-").map(Number);
  const keys: string[] = [];
  for (let i = 0; i < months; i++) {
    keys.unshift(`${y}-${String(m).padStart(2, "0")}`);
    m -= 1; if (m === 0) { m = 12; y -= 1; }
  }
  for (const k of keys) out.set(k, { month: k, directCents: 0, operatingCents: 0, totalCents: 0 });
  for (const r of rows) {
    const bucket = out.get(r.expenseDate.slice(0, 7));
    if (!bucket) continue;
    const cents = toCents(r.amount);
    if (r.kind === "direct_order") bucket.directCents += cents; else bucket.operatingCents += cents;
    bucket.totalCents += cents;
  }
  return keys.map((k) => out.get(k)!);
}

export type CategoryTotal = { categoryId: string; name: string; kind: ExpenseKind; cents: number };
export function totalsByCategory(rows: { amount: number; categoryId: string }[], categories: ExpenseCategory[]): CategoryTotal[] {
  const by = new Map<string, number>();
  for (const r of rows) by.set(r.categoryId, (by.get(r.categoryId) ?? 0) + toCents(r.amount));
  return categories.filter((c) => by.has(c.id)).map((c) => ({ categoryId: c.id, name: c.name, kind: c.kind, cents: by.get(c.id)! })).sort((a, b) => b.cents - a.cents);
}

export const money = (cents: number | null): string =>
  cents === null ? "-" : `${cents < 0 ? "-" : ""}$${(Math.abs(cents) / 100).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
