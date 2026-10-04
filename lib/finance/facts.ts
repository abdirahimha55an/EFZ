/**
 * Financial facts over the same normalised dataset as Sales & Analytics.
 *
 * Sales & Analytics shows only Cash Received from here; the Business Assistant
 * may answer the rest. The future Financial page is meant to build on these
 * functions rather than re-derive them.
 *
 *  - Balances come from the database-maintained orders.outstanding_balance and
 *    amount_paid (record_payment and the order triggers keep them), never from
 *    re-adding payments in the browser.
 *  - Collections are dated by payments.payment_date (when the money came in).
 *  - Payment methods are reported exactly as recorded. An empty method is
 *    "Not recorded"; nothing is ever assumed to be Cash.
 *  - Cancelled orders are excluded throughout.
 */

import { orderMatches, select, type Dataset, type SalesFilters } from "@/lib/analytics/dataset";
import { inRange, type DateRange } from "@/lib/analytics/period";

export const METHOD_NOT_RECORDED = "Not recorded";

/** Order-level scope for money facts: payments and balances belong to whole orders. */
const orderScope = (f: SalesFilters): SalesFilters => ({ ...f, productKey: null });

export type Collections = {
  totalCents: number;
  payments: number;
  byMethod: { method: string; cents: number; payments: number; sharePct: number }[];
};

export function paymentsReceived(ds: Dataset, f: SalesFilters, range: DateRange): Collections {
  const scope = orderScope(f);
  const methods = new Map<string, { cents: number; payments: number }>();
  let total = 0, count = 0;
  for (const o of ds.orders) {
    if (!orderMatches(o, scope)) continue;
    for (const p of o.payments) {
      if (!inRange(p.date, range)) continue;
      const method = p.method || METHOD_NOT_RECORDED;
      const m = methods.get(method) ?? { cents: 0, payments: 0 };
      m.cents += p.amountCents;
      m.payments += 1;
      methods.set(method, m);
      total += p.amountCents;
      count += 1;
    }
  }
  return {
    totalCents: total,
    payments: count,
    byMethod: [...methods.entries()]
      .map(([method, m]) => ({ method, ...m, sharePct: total > 0 ? (m.cents / total) * 100 : 0 }))
      .sort((a, b) => b.cents - a.cents),
  };
}

export type Balance = { customerId: string | null; name: string; outstandingCents: number; ordersWithBalance: number };

/** Outstanding balances right now (not period-bound), largest first. */
export function outstandingBalances(ds: Dataset, f: SalesFilters): { totalCents: number; customers: Balance[] } {
  const scope = orderScope(f);
  const map = new Map<string, Balance>();
  let total = 0;
  for (const o of ds.orders) {
    if (!orderMatches(o, scope) || o.outstandingCents <= 0) continue;
    const key = o.customerId ?? `__order__${o.id}`;
    const b = map.get(key) ?? {
      customerId: o.customerId,
      name: (o.customerId && ds.customers.find((c) => c.id === o.customerId)?.name) || o.customerName,
      outstandingCents: 0,
      ordersWithBalance: 0,
    };
    b.outstandingCents += o.outstandingCents;
    b.ordersWithBalance += 1;
    map.set(key, b);
    total += o.outstandingCents;
  }
  return { totalCents: total, customers: [...map.values()].sort((a, b) => b.outstandingCents - a.outstandingCents || a.name.localeCompare(b.name)) };
}

export const AGING_BUCKETS = [
  { label: "0-7 days", min: 0, max: 7 },
  { label: "8-30 days", min: 8, max: 30 },
  { label: "31-60 days", min: 31, max: 60 },
  { label: "Over 60 days", min: 61, max: Infinity },
] as const;

/**
 * Outstanding balances by the age of the ORDER (today - order_date). EFZ has no
 * invoice due dates, so this is age since the sale, not days overdue.
 */
export function outstandingByAge(ds: Dataset, f: SalesFilters, today: string): { label: string; cents: number; orders: number }[] {
  const scope = orderScope(f);
  const rows = AGING_BUCKETS.map((b) => ({ label: b.label, cents: 0, orders: 0 }));
  for (const o of ds.orders) {
    if (!orderMatches(o, scope) || o.outstandingCents <= 0) continue;
    const age = Math.max(0, Math.round((Date.parse(`${today}T00:00:00Z`) - Date.parse(`${o.date}T00:00:00Z`)) / 86_400_000));
    const i = AGING_BUCKETS.findIndex((b) => age >= b.min && age <= b.max);
    rows[i].cents += o.outstandingCents;
    rows[i].orders += 1;
  }
  return rows;
}

export type GrossProfit =
  | { available: false; reason: string }
  | { available: true; grossProfitCents: number; bookedCents: number; marginPct: number | null; orders: number };

/**
 * Gross profit on orders BOOKED in the period (order_date), from the
 * database-maintained orders.gross_profit (frozen historical unit costs).
 * Order-level, so not available with a product filter.
 */
export function grossProfit(ds: Dataset, f: SalesFilters, range: DateRange): GrossProfit {
  if (f.productKey !== null) return { available: false, reason: "Gross profit is recorded per order, so it cannot be split by product filter here." };
  let gp = 0, booked = 0, orders = 0;
  for (const { order, lines } of select(ds, f, range)) {
    if (order.grossProfitCents === null) return { available: false, reason: "Cost and profit are not available to your account." };
    gp += order.grossProfitCents;
    booked += lines.reduce((s, l) => s + l.unitPriceCents * l.quantity, 0);
    orders += 1;
  }
  return { available: true, grossProfitCents: gp, bookedCents: booked, marginPct: booked > 0 ? (gp / booked) * 100 : null, orders };
}
