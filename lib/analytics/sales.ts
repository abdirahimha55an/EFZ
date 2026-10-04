/**
 * Executive sales KPIs and time series. Pure functions over the Dataset.
 */

import { addDaysYmd } from "@/lib/dates";
import { paymentsReceived } from "@/lib/finance/facts";
import { isSale, select, type Dataset, type SalesFilters, type Selection } from "./dataset";
import { bucketLabel, bucketOf, daysInMonth, eachDay, type DateRange, type Granularity } from "./period";

export type SalesTotals = {
  bookedCents: number;
  deliveredCents: number;
  undeliveredCents: number;
  bookedUnits: number;
  deliveredUnits: number;
  orders: number;
  fullyDeliveredOrders: number;
};

export function totalsOf(selection: Selection[]): SalesTotals {
  const t: SalesTotals = { bookedCents: 0, deliveredCents: 0, undeliveredCents: 0, bookedUnits: 0, deliveredUnits: 0, orders: 0, fullyDeliveredOrders: 0 };
  for (const { order, lines } of selection) {
    t.orders += 1;
    if (order.status === "delivered") t.fullyDeliveredOrders += 1;
    for (const l of lines) {
      t.bookedCents += l.unitPriceCents * l.quantity;
      t.deliveredCents += l.unitPriceCents * l.delivered;
      t.undeliveredCents += l.unitPriceCents * l.remaining;
      t.bookedUnits += l.quantity;
      t.deliveredUnits += l.delivered;
    }
  }
  return t;
}

export type Kpis = SalesTotals & {
  /** Booked revenue / orders; null when there are no orders. */
  aovCents: number | null;
  buyingCustomers: number;
  /** Orders in the set with no customer record (never merged by name). */
  unlinkedOrders: number;
  /**
   * Payments RECEIVED in the period (payment_date), on non-cancelled orders that
   * match the order filters. Null with a product filter: a payment belongs to a
   * whole order, not to a product line.
   */
  cashReceivedCents: number | null;
  cashPayments: number;
};

export function computeKpis(ds: Dataset, f: SalesFilters, range: DateRange): Kpis {
  const selection = select(ds, f, range);
  const totals = totalsOf(selection);
  const customers = new Set<string>();
  let unlinked = 0;
  for (const { order } of selection) {
    if (order.customerId) customers.add(order.customerId);
    else unlinked += 1;
  }
  const cash = f.productKey === null ? paymentsReceived(ds, f, range) : null;
  return {
    ...totals,
    aovCents: totals.orders > 0 ? Math.round(totals.bookedCents / totals.orders) : null,
    buyingCustomers: customers.size,
    unlinkedOrders: unlinked,
    cashReceivedCents: cash ? cash.totalCents : null,
    cashPayments: cash ? cash.payments : 0,
  };
}

/** Change against a comparison value: absolute, and a percentage only when the base is above zero. */
export function change(current: number, previous: number | null | undefined): { delta: number; pct: number | null } | null {
  if (previous === null || previous === undefined) return null;
  return { delta: current - previous, pct: previous > 0 ? ((current - previous) / previous) * 100 : null };
}

// ---------------------------------------------------------------------------
// Time series (every day in the range is present, zero days included)
// ---------------------------------------------------------------------------

export type SeriesPoint = {
  bucket: string;
  label: string;
  bookedCents: number;
  deliveredCents: number;
  bookedUnits: number;
  deliveredUnits: number;
  orders: number;
};

export function salesSeries(ds: Dataset, f: SalesFilters, range: DateRange, granularity: Granularity): SeriesPoint[] {
  const points = new Map<string, SeriesPoint>();
  for (const day of eachDay(range)) {
    const b = bucketOf(day, granularity);
    if (!points.has(b)) points.set(b, { bucket: b, label: bucketLabel(b, granularity), bookedCents: 0, deliveredCents: 0, bookedUnits: 0, deliveredUnits: 0, orders: 0 });
  }
  for (const s of select(ds, f, range)) {
    const p = points.get(bucketOf(s.order.date, granularity));
    if (!p) continue;
    const t = totalsOf([s]);
    p.bookedCents += t.bookedCents;
    p.deliveredCents += t.deliveredCents;
    p.bookedUnits += t.bookedUnits;
    p.deliveredUnits += t.deliveredUnits;
    p.orders += 1;
  }
  return [...points.values()];
}

export type CumulativePoint = {
  day: number;
  /** Cumulative booked revenue this month; null after today. */
  currentCents: number | null;
  /** Cumulative booked revenue last month; null past its last day. */
  previousCents: number | null;
  /** Indicative path from today to month end (pace projection); null before today. */
  projectedCents: number | null;
};

/**
 * Month-to-date cumulative booked revenue against the same days last month.
 * `paceDailyCents`, when given, draws the indicative path from today to month end.
 */
export function cumulativeMonth(ds: Dataset, f: SalesFilters, today: string, paceDailyCents: number | null): CumulativePoint[] {
  const y = Number(today.slice(0, 4)), m = Number(today.slice(5, 7)), d = Number(today.slice(8, 10));
  const dim = daysInMonth(y, m);
  const prevY = m === 1 ? y - 1 : y, prevM = m === 1 ? 12 : m - 1;
  const prevDim = daysInMonth(prevY, prevM);
  const pad = (n: number) => String(n).padStart(2, "0");
  const cur = new Array(dim + 1).fill(0);
  const prev = new Array(prevDim + 1).fill(0);
  const curRange = { from: `${y}-${pad(m)}-01`, to: today };
  const prevRange = { from: `${prevY}-${pad(prevM)}-01`, to: `${prevY}-${pad(prevM)}-${pad(prevDim)}` };
  for (const s of select(ds, f, curRange)) cur[Number(s.order.date.slice(8, 10))] += totalsOf([s]).bookedCents;
  for (const s of select(ds, f, prevRange)) prev[Number(s.order.date.slice(8, 10))] += totalsOf([s]).bookedCents;
  const out: CumulativePoint[] = [];
  let c = 0, p = 0;
  const days = Math.max(dim, prevDim);
  for (let day = 1; day <= days; day++) {
    if (day <= dim) c += cur[day] ?? 0;
    if (day <= prevDim) p += prev[day] ?? 0;
    out.push({
      day,
      currentCents: day <= d ? c : null,
      previousCents: day <= prevDim ? p : null,
      projectedCents: null,
    });
  }
  // The indicative path starts from today's actual cumulative value.
  if (paceDailyCents !== null) {
    const base = out[d - 1]?.currentCents ?? 0;
    for (const pt of out) if (pt.day >= d && pt.day <= dim) pt.projectedCents = base + Math.round(paceDailyCents * (pt.day - d));
  }
  return out;
}

/** Booked units and revenue per day over the `days` days ending today (zero days included). */
export function trailing(ds: Dataset, f: SalesFilters, today: string, days: number) {
  const range = { from: addDaysYmd(today, -(days - 1)), to: today };
  const t = totalsOf(select(ds, f, range));
  return { range, days, bookedCents: t.bookedCents, bookedUnits: t.bookedUnits, revenuePerDayCents: t.bookedCents / days, unitsPerDay: t.bookedUnits / days };
}

/** Sales orders (any filter) — used where a figure must not depend on the page filters. */
export const salesOrders = (ds: Dataset) => ds.orders.filter(isSale);
