/**
 * Financial Management model: one pure function over the shared sales dataset
 * (lib/analytics/dataset), so the Financial page, its tests and any later
 * export cannot disagree. Builds on lib/finance/facts.
 *
 * Bases (never mixed in one figure):
 *  - Booked: lines of non-cancelled orders dated (order_date) in the period,
 *    quantity x the actual unit price.
 *  - Cash received: payments dated (payment_date) in the period.
 *  - Balances: orders.outstanding_balance / amount_paid as the database keeps
 *    them, as of now (not period-bound).
 *  - Cost and profit: order_items.line_cost, the unit cost frozen when the line
 *    was sold. Never today's product cost. Null when cost is withheld.
 *  - EFZ records money coming in only (no expenses), so "cash flow" here is
 *    inflow; nothing is invented for outflows.
 */

import { isSale, select, type Dataset, type SalesFilters, type SalesLine, type SalesOrder } from "@/lib/analytics/dataset";
import {
  autoGranularity, bucketLabel, bucketOf, comparisonRange, eachDay, formatRange, inRange, resolvePeriod,
  type DateRange, type Granularity, type Period, type PeriodPreset,
} from "@/lib/analytics/period";
import { METHOD_NOT_RECORDED, outstandingBalances, outstandingByAge, paymentsReceived, type Balance, type Collections } from "./facts";

export type FinanceInput = {
  ds: Dataset;
  filters: SalesFilters;
  preset: PeriodPreset;
  custom: { from: string; to: string };
  compare: boolean;
  today: string;
};

export const lineRevenueCents = (l: SalesLine) => l.unitPriceCents * l.quantity;

/**
 * False as soon as any line lacks cost (the database withheld it from this
 * user). With no lines at all there is no cost to withhold, so nothing is
 * claimed to be hidden.
 */
export function costVisible(ds: Dataset): boolean {
  for (const o of ds.orders) for (const l of o.lines) if (l.costCents === null) return false;
  return true;
}

export type PeriodFigures = {
  orders: number;
  bookedCents: number;
  cash: Collections;
  /** Null when cost is withheld. */
  costCents: number | null;
  grossProfitCents: number | null;
  marginPct: number | null;
  /** Paid so far (any date) on the orders booked in the period; null with a product filter (payments are per order). */
  paidOnPeriodOrdersCents: number | null;
  paidOnPeriodOrdersPct: number | null;
};

export function periodFigures(ds: Dataset, f: SalesFilters, range: DateRange): PeriodFigures {
  let booked = 0, cost = 0, costKnown = true, paid = 0, orders = 0;
  for (const { order, lines } of select(ds, f, range)) {
    orders += 1;
    for (const l of lines) {
      booked += lineRevenueCents(l);
      if (l.costCents === null) costKnown = false;
      else cost += l.costCents;
    }
    paid += order.amountPaidCents;
  }
  const productFiltered = f.productKey !== null;
  const gp = costKnown ? booked - cost : null;
  return {
    orders,
    bookedCents: booked,
    cash: paymentsReceived(ds, f, range),
    costCents: costKnown ? cost : null,
    grossProfitCents: gp,
    marginPct: gp !== null && booked > 0 ? (gp / booked) * 100 : null,
    paidOnPeriodOrdersCents: productFiltered ? null : paid,
    paidOnPeriodOrdersPct: productFiltered || booked <= 0 ? null : (paid / booked) * 100,
  };
}

export type Receivables = {
  totalCents: number;
  customers: Balance[];
  /** Customers with a balance (entries with a customer id). */
  linkedCustomers: number;
  /** Orders with a balance but no linked customer (listed by order, not counted as customers). */
  unlinkedOrders: number;
  aging: { label: string; cents: number; orders: number }[];
  /** Balance on orders already fully delivered (collectable now). */
  deliveredCents: number;
  deliveredOrders: number;
  /** Balance on orders not yet fully delivered. */
  openCents: number;
  openOrders: number;
  /**
   * Payments received above an order's line revenue. The database caps
   * amount_paid at the total and floors the balance at 0, so this is measured
   * from the payments themselves (validate_financials 207).
   */
  overpaidCents: number;
  overpaidOrders: number;
};

export function receivables(ds: Dataset, f: SalesFilters, today: string): Receivables {
  const scope: SalesFilters = { ...f, productKey: null };
  const balances = outstandingBalances(ds, scope);
  let deliveredCents = 0, deliveredOrders = 0, openCents = 0, openOrders = 0, overpaidCents = 0, overpaidOrders = 0;
  for (const { order } of select(ds, scope, null)) {
    if (order.outstandingCents > 0) {
      if (order.status === "delivered") { deliveredCents += order.outstandingCents; deliveredOrders += 1; }
      else { openCents += order.outstandingCents; openOrders += 1; }
    }
    const over = paymentsCents(order) - revenueCents(order);
    if (over > 0) { overpaidCents += over; overpaidOrders += 1; }
  }
  return {
    totalCents: balances.totalCents,
    customers: balances.customers,
    linkedCustomers: balances.customers.filter((c) => c.customerId !== null).length,
    unlinkedOrders: balances.customers.filter((c) => c.customerId === null).reduce((s, c) => s + c.ordersWithBalance, 0),
    aging: outstandingByAge(ds, scope, today),
    deliveredCents, deliveredOrders, openCents, openOrders, overpaidCents, overpaidOrders,
  };
}

export type PaymentRow = { key: string; date: string; orderId: string; customerName: string; method: string; amountCents: number };

/** Every payment dated in the period on matching orders, newest first. */
export function paymentHistory(ds: Dataset, f: SalesFilters, range: DateRange): PaymentRow[] {
  const scope: SalesFilters = { ...f, productKey: null };
  const rows: PaymentRow[] = [];
  for (const { order } of select(ds, scope, null)) {
    order.payments.forEach((p, i) => {
      if (!inRange(p.date, range)) return;
      rows.push({ key: `${order.id}#${i}`, date: p.date, orderId: order.id, customerName: order.customerName, method: p.method || METHOD_NOT_RECORDED, amountCents: p.amountCents });
    });
  }
  return rows.sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : a.key < b.key ? -1 : 1));
}

export type CashFlowPoint = { bucket: string; label: string; cashInCents: number; bookedCents: number; cumulativeCashCents: number };

export function cashFlowSeries(ds: Dataset, f: SalesFilters, range: DateRange): { granularity: Granularity; points: CashFlowPoint[] } {
  const granularity = autoGranularity(range);
  const map = new Map<string, CashFlowPoint>();
  for (const d of eachDay(range)) {
    const b = bucketOf(d, granularity);
    if (!map.has(b)) map.set(b, { bucket: b, label: bucketLabel(b, granularity), cashInCents: 0, bookedCents: 0, cumulativeCashCents: 0 });
  }
  for (const { order, lines } of select(ds, f, range)) {
    const p = map.get(bucketOf(order.date, granularity));
    if (p) for (const l of lines) p.bookedCents += lineRevenueCents(l);
  }
  for (const { order } of select(ds, { ...f, productKey: null }, null)) {
    for (const pay of order.payments) {
      if (!inRange(pay.date, range)) continue;
      const p = map.get(bucketOf(pay.date, granularity));
      if (p) p.cashInCents += pay.amountCents;
    }
  }
  const points = [...map.values()].sort((a, b) => (a.bucket < b.bucket ? -1 : 1));
  let run = 0;
  for (const p of points) { run += p.cashInCents; p.cumulativeCashCents = run; }
  return { granularity, points };
}

export type ProductProfitRow = {
  productKey: string;
  productName: string;
  units: number;
  revenueCents: number;
  costCents: number;
  profitCents: number;
  marginPct: number | null;
  /** Lines sold with a recorded cost of 0: their profit is overstated. */
  zeroCostLines: number;
  /** Lines sold below their recorded cost. */
  belowCostLines: number;
};

/** Profit by product on lines booked in the period; null when cost is withheld. */
export function productProfitability(ds: Dataset, f: SalesFilters, range: DateRange): ProductProfitRow[] | null {
  const map = new Map<string, ProductProfitRow>();
  for (const { lines } of select(ds, f, range)) {
    for (const l of lines) {
      if (l.costCents === null) return null;
      const r = map.get(l.productKey) ?? { productKey: l.productKey, productName: l.productName, units: 0, revenueCents: 0, costCents: 0, profitCents: 0, marginPct: null, zeroCostLines: 0, belowCostLines: 0 };
      const rev = lineRevenueCents(l);
      r.units += l.quantity;
      r.revenueCents += rev;
      r.costCents += l.costCents;
      if (l.costCents === 0 && l.quantity > 0) r.zeroCostLines += 1;
      if (rev < l.costCents) r.belowCostLines += 1;
      map.set(l.productKey, r);
    }
  }
  return [...map.values()]
    .map((r) => ({ ...r, profitCents: r.revenueCents - r.costCents, marginPct: r.revenueCents > 0 ? ((r.revenueCents - r.costCents) / r.revenueCents) * 100 : null }))
    .sort((a, b) => b.profitCents - a.profitCents || a.productName.localeCompare(b.productName));
}

export type ReconciliationCheck = {
  key: string;
  label: string;
  /** "FAIL" breaks a database invariant; "WARN" is a business state worth review. */
  severity: "FAIL" | "WARN";
  count: number;
  orderIds: string[];
  /** Null when the check cannot run for this user (cost withheld). */
  available: boolean;
};

const paymentsCents = (o: SalesOrder) => sum(o.payments.map((p) => p.amountCents));
const revenueCents = (o: SalesOrder) => sum(o.lines.map(lineRevenueCents));

/** validate_financials 206: the status the payments imply. */
export function expectedPaymentStatus(o: SalesOrder): string {
  if (o.paymentStatus === "refunded" || o.paymentStatus === "credit") return o.paymentStatus;
  const rev = revenueCents(o), paid = Math.min(paymentsCents(o), rev);
  if (rev <= 0) return "paid";
  if (paid <= 0) return "unpaid";
  return paid >= rev ? "paid" : "partial";
}

/**
 * The validate_financials order and line checks (201-208, 210, 220-222) re-run
 * over the orders this user can see, with the same formulas, so a mismatch is
 * visible where money is managed. Every visible order counts (cancelled too),
 * whatever the filters, as in the database script. 209 (legacy merged ids)
 * needs data this page does not load and stays database-only. Line checks are
 * reported per order. "cancelledPaid" is page-specific: such payments are left
 * out of Cash received.
 */
export function reconciliation(ds: Dataset): ReconciliationCheck[] {
  const withCost = costVisible(ds);
  const checks: { key: string; label: string; severity: "FAIL" | "WARN"; needsCost: boolean; test: (o: SalesOrder) => boolean }[] = [
    { key: "total", label: "Order total differs from its line items", severity: "FAIL", needsCost: false, test: (o) => o.totalCents !== revenueCents(o) },
    { key: "cost", label: "Order cost differs from its line items", severity: "FAIL", needsCost: true, test: (o) => o.costCents !== null && o.costCents !== sum(o.lines.map((l) => l.costCents ?? 0)) },
    { key: "profit", label: "Gross profit is not total − cost", severity: "FAIL", needsCost: true, test: (o) => o.costCents !== null && o.grossProfitCents !== null && o.grossProfitCents !== o.totalCents - o.costCents },
    { key: "paid", label: "Amount paid differs from the payments (capped at the line-item total)", severity: "FAIL", needsCost: false, test: (o) => o.amountPaidCents !== Math.min(paymentsCents(o), revenueCents(o)) },
    { key: "balance", label: "Outstanding balance is not total − paid", severity: "FAIL", needsCost: false, test: (o) => o.outstandingCents !== Math.max(o.totalCents - o.amountPaidCents, 0) },
    { key: "status", label: "Payment status disagrees with the payments", severity: "FAIL", needsCost: false, test: (o) => o.paymentStatus !== expectedPaymentStatus(o) },
    { key: "overpaid", label: "Payments above the order total", severity: "FAIL", needsCost: false, test: (o) => paymentsCents(o) > revenueCents(o) },
    { key: "noLines", label: "Orders with no line items", severity: "FAIL", needsCost: false, test: (o) => o.lines.length === 0 },
    { key: "deliveredBalance", label: "Delivered orders with an outstanding balance", severity: "WARN", needsCost: false, test: (o) => o.status === "delivered" && o.outstandingCents > 0 },
    { key: "cancelledPaid", label: "Cancelled orders holding payments (not in Cash received)", severity: "WARN", needsCost: false, test: (o) => !isSale(o) && o.payments.length > 0 },
    { key: "noProduct", label: "Orders with a line whose product no longer exists", severity: "WARN", needsCost: false, test: (o) => o.lines.some((l) => l.productId === null) },
    { key: "zeroCost", label: "Orders with a line at no recorded cost (profit overstated)", severity: "WARN", needsCost: true, test: (o) => o.lines.some((l) => l.costCents === 0) },
    { key: "belowCost", label: "Orders with a line sold below its recorded cost", severity: "WARN", needsCost: true, test: (o) => o.lines.some((l) => l.costCents !== null && lineRevenueCents(l) < l.costCents) },
  ];
  return checks.map((c) => {
    if (c.needsCost && !withCost) return { key: c.key, label: c.label, severity: c.severity, count: 0, orderIds: [], available: false };
    const ids = ds.orders.filter(c.test).map((o) => o.id);
    return { key: c.key, label: c.label, severity: c.severity, count: ids.length, orderIds: ids, available: true };
  });
}

const sum = (xs: number[]) => xs.reduce((s, x) => s + x, 0);

/** Shown wherever cash or balances appear while a product filter is on (they are per whole order). */
export const WHOLE_ORDER_NOTE = "Whole orders, not split by product";

export type FinanceModel = {
  today: string;
  /**
   * True with a product filter. Booked, cost and profit then cover that product's
   * lines only, while cash received, collections and balances stay whole-order
   * (payments are recorded per order), so the UI labels them and drops the
   * booked line from the cash-flow chart.
   */
  productFiltered: boolean;
  period: Period;
  periodText: string;
  comparison: (DateRange & { label: string; text: string; figures: PeriodFigures }) | null;
  costVisible: boolean;
  current: PeriodFigures;
  receivables: Receivables;
  payments: PaymentRow[];
  cashFlow: { granularity: Granularity; points: CashFlowPoint[] };
  products: ProductProfitRow[] | null;
  reconciliation: ReconciliationCheck[];
};

export function buildFinanceModel({ ds, filters, preset, custom, compare, today }: FinanceInput): FinanceModel {
  const period = resolvePeriod(preset, today, { custom, firstSaleDate: ds.firstSaleDate });
  const cmp = compare ? comparisonRange(period) : null;
  return {
    today,
    productFiltered: filters.productKey !== null,
    period,
    periodText: `${period.label}: ${formatRange(period)}`,
    comparison: cmp ? { ...cmp, text: formatRange(cmp), figures: periodFigures(ds, filters, cmp) } : null,
    costVisible: costVisible(ds),
    current: periodFigures(ds, filters, period),
    receivables: receivables(ds, filters, today),
    payments: paymentHistory(ds, filters, period),
    cashFlow: cashFlowSeries(ds, filters, period),
    products: productProfitability(ds, filters, period),
    reconciliation: reconciliation(ds),
  };
}
