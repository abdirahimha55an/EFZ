/**
 * Marketing Officer dashboard metrics (business definitions locked 2026-10-02).
 * Pure functions over data the officer may already read. No forecasts, no rounding
 * beyond cents.
 *
 * ACTIVE CUSTOMERS
 *   A customer currently assigned to the officer who placed at least one order
 *   (order date, not cancelled) within the last 90 days, counted on the
 *   Mogadishu calendar. Payment, delivery and customer-creation dates play no part.
 *
 * COLLECTED BY ME
 *   Payments whose recorded_by is the signed-in officer's own profile id - the
 *   identity the database stamped when the payment was recorded. A payment is
 *   never attributed to the officer just because the customer is theirs.
 *
 * COLLECTED FROM MY CUSTOMERS
 *   Payments on orders of customers CURRENTLY assigned to the officer, whoever
 *   recorded them. Follows current ownership: after a transfer, the customer's
 *   payments count for the new owner. Payment rows themselves are never changed.
 */
import type { Customer, Order, PaymentRecord } from "@/lib/types";

export const ACTIVE_WINDOW_DAYS = 90;

const round2 = (n: number) => Math.round(n * 100) / 100;

/** The YYYY-MM-DD calendar date `days` before `isoDate` (both plain dates). */
export function daysBefore(isoDate: string, days: number): string {
  const d = new Date(`${isoDate}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - days);
  return d.toISOString().slice(0, 10);
}

/** Customers (of those given) with a non-cancelled order dated within the last 90 days, inclusive. */
export function activeCustomers(customers: Customer[], orders: Order[], today: string): Customer[] {
  const cutoff = daysBefore(today, ACTIVE_WINDOW_DAYS);
  return customers.filter((c) =>
    orders.some((o) => o.customerId === c.id && o.status !== "cancelled" && (o.date ?? "") >= cutoff && (o.date ?? "") <= today)
  );
}

export type CollectionTotal = { total: number; thisMonth: number; payments: number };

type PaymentWithOrder = PaymentRecord & { order: Order };

const paymentsOf = (orders: Order[]): PaymentWithOrder[] =>
  orders.flatMap((order) => (order.payments ?? []).map((p) => ({ ...p, order })));

function totalOf(payments: PaymentWithOrder[], month: string): CollectionTotal {
  return {
    total: round2(payments.reduce((s, p) => s + Number(p.amount || 0), 0)),
    thisMonth: round2(payments.filter((p) => (p.paymentDate ?? "").startsWith(month)).reduce((s, p) => s + Number(p.amount || 0), 0)),
    payments: payments.length,
  };
}

/** Payments the signed-in officer personally recorded (payments.recorded_by = their profile id). */
export function collectedByMe(orders: Order[], profileId: string, month: string): CollectionTotal {
  return totalOf(paymentsOf(orders).filter((p) => p.recordedBy === profileId), month);
}

/** Payments on orders of customers currently assigned to the officer, whoever recorded them. */
export function collectedFromMyCustomers(orders: Order[], myCurrentCustomers: Customer[], month: string): CollectionTotal {
  const mine = new Set(myCurrentCustomers.map((c) => c.id));
  return totalOf(paymentsOf(orders).filter((p) => Boolean(p.order.customerId) && mine.has(p.order.customerId as string)), month);
}
