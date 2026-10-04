/**
 * Customer analytics. The identity key is ALWAYS customer_id; two customers
 * with the same name stay separate. Orders without a customer record are
 * reported as one "No customer record" row and never merged by name.
 *
 * "First order" = the customer's earliest non-cancelled order among the orders
 * this user can see (date, then entry time), whatever the page filters are.
 */

import { isSale, orderMatches, select, type Dataset, type SalesFilters } from "./dataset";
import { totalsOf as totalsOfSelection } from "./sales";
import { bucketLabel, bucketOf, daysBetween, eachDay, inRange, type DateRange, type Granularity } from "./period";

export const NO_CUSTOMER_KEY = "__no_customer__";

export type CustomerRow = {
  key: string;
  customerId: string | null;
  name: string;
  orders: number;
  bookedUnits: number;
  bookedCents: number;
  deliveredCents: number;
  sharePct: number;
  firstOrderDate: string | null;
  lastOrderDateInPeriod: string | null;
  /** All-time average days between this customer's orders; null with fewer than 2 orders. */
  avgDaysBetweenOrders: number | null;
  isNew: boolean;
};

export function customerName(ds: Dataset, customerId: string | null, fallback: string): string {
  if (!customerId) return "No customer record";
  return ds.customers.find((c) => c.id === customerId)?.name || fallback || "Unknown customer";
}

function allTimeOrderDates(ds: Dataset): Map<string, string[]> {
  const m = new Map<string, string[]>();
  for (const o of ds.orders) {
    if (!isSale(o) || !o.customerId) continue;
    const list = m.get(o.customerId) ?? [];
    list.push(o.date);
    m.set(o.customerId, list);
  }
  return m;
}

export function customerPerformance(ds: Dataset, f: SalesFilters, range: DateRange): CustomerRow[] {
  const dates = allTimeOrderDates(ds);
  const map = new Map<string, CustomerRow>();
  let total = 0;
  for (const s of select(ds, f, range)) {
    const key = s.order.customerId ?? NO_CUSTOMER_KEY;
    let r = map.get(key);
    if (!r) {
      const first = s.order.customerId ? ds.firstOrderByCustomer.get(s.order.customerId) ?? null : null;
      const all = s.order.customerId ? dates.get(s.order.customerId) ?? [] : [];
      r = {
        key,
        customerId: s.order.customerId,
        name: customerName(ds, s.order.customerId, s.order.customerName),
        orders: 0, bookedUnits: 0, bookedCents: 0, deliveredCents: 0, sharePct: 0,
        firstOrderDate: first?.date ?? null,
        lastOrderDateInPeriod: null,
        avgDaysBetweenOrders: all.length >= 2 ? daysBetween(all[0], all[all.length - 1]) / (all.length - 1) : null,
        isNew: first ? inRange(first.date, range) : false,
      };
      map.set(key, r);
    }
    const t = totalsOfSelection([s]);
    r.orders += 1;
    r.bookedUnits += t.bookedUnits;
    r.bookedCents += t.bookedCents;
    r.deliveredCents += t.deliveredCents;
    total += t.bookedCents;
    if (!r.lastOrderDateInPeriod || s.order.date > r.lastOrderDateInPeriod) r.lastOrderDateInPeriod = s.order.date;
  }
  return [...map.values()]
    .map((r) => ({ ...r, sharePct: total > 0 ? (r.bookedCents / total) * 100 : 0 }))
    .sort((a, b) => b.bookedCents - a.bookedCents || a.name.localeCompare(b.name));
}

export type Concentration = {
  /** Share of booked revenue held by the top 1 / 3 / 5 customers (customer records only). */
  top1Pct: number;
  top3Pct: number;
  top5Pct: number;
  /** Top 10 customers plus an "Others" bucket, with the cumulative share. */
  pareto: { name: string; key: string; bookedCents: number; cumulativePct: number }[];
};

export function concentration(rows: CustomerRow[]): Concentration {
  const total = rows.reduce((s, r) => s + r.bookedCents, 0);
  const named = rows.filter((r) => r.customerId !== null);
  const share = (n: number) => (total > 0 ? (named.slice(0, n).reduce((s, r) => s + r.bookedCents, 0) / total) * 100 : 0);
  const top = rows.slice(0, 10);
  const rest = rows.slice(10).reduce((s, r) => s + r.bookedCents, 0);
  const bars = [...top.map((r) => ({ name: r.name, key: r.key, bookedCents: r.bookedCents })), ...(rest > 0 ? [{ name: `Others (${rows.length - 10})`, key: "__others__", bookedCents: rest }] : [])];
  let run = 0;
  return {
    top1Pct: share(1),
    top3Pct: share(3),
    top5Pct: share(5),
    pareto: bars.map((b) => {
      run += b.bookedCents;
      return { ...b, cumulativePct: total > 0 ? (run / total) * 100 : 0 };
    }),
  };
}

export type NewReturning = { newCustomers: number; returningCustomers: number; buyingCustomers: number };

/** A buying customer is NEW when their first order falls in the range, RETURNING when it is earlier. */
export function newVsReturning(rows: CustomerRow[]): NewReturning {
  const named = rows.filter((r) => r.customerId !== null);
  const n = named.filter((r) => r.isNew).length;
  return { newCustomers: n, returningCustomers: named.length - n, buyingCustomers: named.length };
}

export type NewReturningPoint = { bucket: string; label: string; newCustomers: number; returningCustomers: number };

export function newVsReturningSeries(ds: Dataset, f: SalesFilters, range: DateRange, granularity: Granularity): NewReturningPoint[] {
  const buckets = new Map<string, { label: string; customers: Map<string, boolean> }>();
  for (const d of eachDay(range)) {
    const b = bucketOf(d, granularity);
    if (!buckets.has(b)) buckets.set(b, { label: bucketLabel(b, granularity), customers: new Map() });
  }
  for (const { order } of select(ds, f, range)) {
    if (!order.customerId) continue;
    const b = bucketOf(order.date, granularity);
    const entry = buckets.get(b);
    if (!entry) continue;
    const first = ds.firstOrderByCustomer.get(order.customerId);
    const isNew = first ? bucketOf(first.date, granularity) === b : false;
    entry.customers.set(order.customerId, (entry.customers.get(order.customerId) ?? false) || isNew);
  }
  return [...buckets.entries()].map(([bucket, e]) => {
    const values = [...e.customers.values()];
    const n = values.filter(Boolean).length;
    return { bucket, label: e.label, newCustomers: n, returningCustomers: values.length - n };
  });
}

export type TrialConversion = {
  trialCustomers: number;
  converted: number;
  /** Trial customers without a later regular order, oldest trial first. */
  notConverted: { customerId: string; name: string; trialDate: string; daysSinceTrial: number }[];
};

/**
 * All-time (period-independent): customers with a non-cancelled TRIAL order,
 * and how many later placed a non-cancelled REGULAR order (dated after the
 * first trial, or the same day but entered later). The customer and officer
 * filters apply; product, type and status filters do not.
 */
export function trialConversion(ds: Dataset, f: SalesFilters, today: string): TrialConversion {
  const scope: SalesFilters = { ...f, productKey: null, orderType: "all", status: "all" };
  const firstTrial = new Map<string, { date: string; createdAt: string; name: string }>();
  for (const o of ds.orders) {
    if (!o.customerId || o.orderType !== "trial" || !orderMatches(o, scope)) continue;
    if (!firstTrial.has(o.customerId)) firstTrial.set(o.customerId, { date: o.date, createdAt: o.createdAt, name: customerName(ds, o.customerId, o.customerName) });
  }
  const converted = new Set<string>();
  for (const o of ds.orders) {
    if (!o.customerId || o.orderType !== "regular" || !orderMatches(o, scope)) continue;
    const t = firstTrial.get(o.customerId);
    if (t && (o.date > t.date || (o.date === t.date && o.createdAt > t.createdAt))) converted.add(o.customerId);
  }
  const notConverted = [...firstTrial.entries()]
    .filter(([id]) => !converted.has(id))
    .map(([customerId, t]) => ({ customerId, name: t.name, trialDate: t.date, daysSinceTrial: daysBetween(t.date, today) }))
    .sort((a, b) => b.daysSinceTrial - a.daysSinceTrial);
  return { trialCustomers: firstTrial.size, converted: converted.size, notConverted };
}
