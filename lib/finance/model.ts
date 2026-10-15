/**
 * Financial Management model: one pure function over the shared sales dataset
 * (lib/analytics/dataset), so the Financial page, its tests and any later
 * export cannot disagree. Builds on lib/finance/facts.
 *
 * Bases (never mixed in one figure). Orders: non-cancelled, dated by
 * order_date in the period (the same sales date as Sales & Analytics).
 *  - Delivered revenue: delivered balls x the actual unit price. Revenue is
 *    counted once, when delivered; a later payment is cash, not new revenue.
 *  - Pending order value: balls still to deliver x the actual unit price.
 *    Delivered revenue + pending order value = the orders' booked value.
 *  - Cash received: payments dated (payment_date) in the period.
 *  - Balances: orders.outstanding_balance / amount_paid as the database keeps
 *    them, as of now (not period-bound). Never subtracted from revenue.
 *  - Cost and gross profit: on delivered balls, at the unit cost frozen when
 *    the line was sold (order_items.historical_unit_cost). Never today's
 *    product cost. Null when cost is withheld.
 *  - EFZ records money coming in only (no expenses), so "cash flow" here is
 *    inflow; nothing is invented for outflows.
 */

import { isSale, select, type Dataset, type SalesFilters, type SalesLine, type SalesOrder } from "@/lib/analytics/dataset";
import {
  autoGranularity, bucketLabel, bucketOf, comparisonRange, eachDay, formatRange, inRange, resolvePeriod,
  type DateRange, type Granularity, type Period, type PeriodPreset,
} from "@/lib/analytics/period";
import { offersInvoice } from "./documents";
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
/** Delivered revenue of a line: delivered balls x the actual unit price. */
export const lineDeliveredCents = (l: SalesLine) => l.unitPriceCents * l.delivered;
/** Pending order value of a line: balls still to deliver x the actual unit price. */
export const linePendingCents = (l: SalesLine) => l.unitPriceCents * l.remaining;
/** Frozen cost of the delivered balls; null when cost is withheld. */
export const lineDeliveredCostCents = (l: SalesLine) => (l.unitCostCents === null ? null : l.unitCostCents * l.delivered);

/**
 * False as soon as any line lacks cost (the database withheld it from this
 * user). With no lines at all there is no cost to withhold, so nothing is
 * claimed to be hidden.
 */
export function costVisible(ds: Dataset): boolean {
  for (const o of ds.orders) for (const l of o.lines) if (l.costCents === null || l.unitCostCents === null) return false;
  return true;
}

export type PeriodFigures = {
  orders: number;
  /** Booked value of the period's orders (delivered + pending). */
  bookedCents: number;
  deliveredRevenueCents: number;
  pendingValueCents: number;
  cash: Collections;
  /** Frozen cost of the delivered balls. Null when cost is withheld. */
  costCents: number | null;
  /** Delivered revenue - its frozen cost. Null when cost is withheld. */
  grossProfitCents: number | null;
  /** Gross profit / delivered revenue. */
  marginPct: number | null;
  /** Paid so far (any date) on the orders booked in the period; null with a product filter (payments are per order). */
  paidOnPeriodOrdersCents: number | null;
  paidOnPeriodOrdersPct: number | null;
};

export function periodFigures(ds: Dataset, f: SalesFilters, range: DateRange): PeriodFigures {
  let booked = 0, delivered = 0, pending = 0, cost = 0, costKnown = true, paid = 0, orders = 0;
  for (const { order, lines } of select(ds, f, range)) {
    orders += 1;
    for (const l of lines) {
      booked += lineRevenueCents(l);
      delivered += lineDeliveredCents(l);
      pending += linePendingCents(l);
      const c = lineDeliveredCostCents(l);
      if (c === null) costKnown = false;
      else cost += c;
    }
    paid += order.amountPaidCents;
  }
  const productFiltered = f.productKey !== null;
  const gp = costKnown ? delivered - cost : null;
  return {
    orders,
    bookedCents: booked,
    deliveredRevenueCents: delivered,
    pendingValueCents: pending,
    cash: paymentsReceived(ds, f, range),
    costCents: costKnown ? cost : null,
    grossProfitCents: gp,
    marginPct: gp !== null && delivered > 0 ? (gp / delivered) * 100 : null,
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

export type ReceivableStatus = "paid" | "partial" | "unpaid";
export type ReceivableFilter = "all" | ReceivableStatus;

/**
 * The order's payment status exactly as Customer Database showed it
 * (lib/financial getOrderPaymentStatus): from the order total and the
 * database-maintained amount paid.
 */
export function receivableStatus(o: Pick<SalesOrder, "totalCents" | "amountPaidCents">): ReceivableStatus {
  if (o.totalCents <= 0) return "paid";
  if (o.amountPaidCents <= 0) return "unpaid";
  return o.amountPaidCents >= o.totalCents ? "paid" : "partial";
}

export type ReceivableOrderRow = {
  orderId: string;
  customerId: string | null;
  customerName: string;
  date: string;
  totalCents: number;
  collectedCents: number;
  outstandingCents: number;
  status: ReceivableStatus;
  /** A credit order: an invoice is offered (lib/finance/documents). */
  invoice: boolean;
  /** Stored payment terms; null = not recorded (awaiting review). */
  terms: "paid_at_sale" | "credit" | null;
};

/**
 * Receivables by order (the view moved from Customer Database): every
 * non-cancelled order matching the page filters (not the period: balances are
 * as of now; not the product: payments belong to whole orders), newest first.
 * "all" keeps every such order, as Customer Database did; the other filters
 * keep that payment status only.
 */
export function receivableOrders(ds: Dataset, f: SalesFilters, status: ReceivableFilter): ReceivableOrderRow[] {
  const rows: ReceivableOrderRow[] = [];
  for (const { order } of select(ds, { ...f, productKey: null }, null)) {
    const s = receivableStatus(order);
    if (status !== "all" && s !== status) continue;
    const linked = order.customerId ? ds.customers.find((c) => c.id === order.customerId) : undefined;
    rows.push({
      orderId: order.id, customerId: order.customerId, customerName: linked?.name || order.customerName, date: order.date,
      totalCents: order.totalCents, collectedCents: order.amountPaidCents, outstandingCents: order.outstandingCents, status: s,
      invoice: offersInvoice(order),
      terms: order.paymentTerms,
    });
  }
  return rows.sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : a.orderId < b.orderId ? -1 : 1));
}

export type ReceivableCustomerRow = {
  key: string;
  customerId: string | null;
  customerName: string;
  orders: number;
  ordersWithBalance: number;
  outstandingCents: number;
  rows: ReceivableOrderRow[];
};

/** The same order rows grouped by customer (an unlinked order is its own row), largest balance first. */
export function receivablesByCustomer(rows: ReceivableOrderRow[]): ReceivableCustomerRow[] {
  const map = new Map<string, ReceivableCustomerRow>();
  for (const r of rows) {
    const key = r.customerId ?? `__order__${r.orderId}`;
    const g = map.get(key) ?? { key, customerId: r.customerId, customerName: r.customerName, orders: 0, ordersWithBalance: 0, outstandingCents: 0, rows: [] };
    g.orders += 1;
    if (r.outstandingCents > 0) g.ordersWithBalance += 1;
    g.outstandingCents += r.outstandingCents;
    g.rows.push(r);
    map.set(key, g);
  }
  return [...map.values()].sort((a, b) => b.outstandingCents - a.outstandingCents || a.customerName.localeCompare(b.customerName));
}

export type PaymentRow = { key: string; paymentId: string; date: string; orderId: string; customerName: string; method: string; amountCents: number };

/** Every payment dated in the period on matching orders, newest first. */
export function paymentHistory(ds: Dataset, f: SalesFilters, range: DateRange): PaymentRow[] {
  const scope: SalesFilters = { ...f, productKey: null };
  const rows: PaymentRow[] = [];
  for (const { order } of select(ds, scope, null)) {
    order.payments.forEach((p, i) => {
      if (!inRange(p.date, range)) return;
      rows.push({ key: `${order.id}#${i}`, paymentId: p.id, date: p.date, orderId: order.id, customerName: order.customerName, method: p.method || METHOD_NOT_RECORDED, amountCents: p.amountCents });
    });
  }
  return rows.sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : a.key < b.key ? -1 : 1));
}

export type CashFlowPoint = { bucket: string; label: string; cashInCents: number; bookedCents: number; deliveredCents: number; cumulativeCashCents: number };

export function cashFlowSeries(ds: Dataset, f: SalesFilters, range: DateRange): { granularity: Granularity; points: CashFlowPoint[] } {
  const granularity = autoGranularity(range);
  const map = new Map<string, CashFlowPoint>();
  for (const d of eachDay(range)) {
    const b = bucketOf(d, granularity);
    if (!map.has(b)) map.set(b, { bucket: b, label: bucketLabel(b, granularity), cashInCents: 0, bookedCents: 0, deliveredCents: 0, cumulativeCashCents: 0 });
  }
  for (const { order, lines } of select(ds, f, range)) {
    const p = map.get(bucketOf(order.date, granularity));
    if (p) for (const l of lines) { p.bookedCents += lineRevenueCents(l); p.deliveredCents += lineDeliveredCents(l); }
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

/**
 * Profit by product on the DELIVERED balls of orders dated in the period, at
 * the frozen unit cost; null when cost is withheld. Products with nothing
 * delivered yet are left out. The flags look at the whole line as sold.
 */
export function productProfitability(ds: Dataset, f: SalesFilters, range: DateRange): ProductProfitRow[] | null {
  const map = new Map<string, ProductProfitRow>();
  for (const { lines } of select(ds, f, range)) {
    for (const l of lines) {
      const deliveredCost = lineDeliveredCostCents(l);
      if (deliveredCost === null || l.costCents === null) return null;
      if (l.delivered <= 0) continue;
      const r = map.get(l.productKey) ?? { productKey: l.productKey, productName: l.productName, units: 0, revenueCents: 0, costCents: 0, profitCents: 0, marginPct: null, zeroCostLines: 0, belowCostLines: 0 };
      r.units += l.delivered;
      r.revenueCents += lineDeliveredCents(l);
      r.costCents += deliveredCost;
      if (l.costCents === 0 && l.quantity > 0) r.zeroCostLines += 1;
      if (lineRevenueCents(l) < l.costCents) r.belowCostLines += 1;
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
  /** What the finding means and what to do about it. */
  action: string;
};

/** The collapsed header of Financial Checks & Exceptions. */
export function checksSummary(checks: ReconciliationCheck[]): { errors: number; warnings: number; unavailable: number; findings: number } {
  const on = checks.filter((c) => c.available && c.count > 0);
  return {
    errors: on.filter((c) => c.severity === "FAIL").length,
    warnings: on.filter((c) => c.severity === "WARN").length,
    unavailable: checks.filter((c) => !c.available).length,
    findings: on.length,
  };
}

const ACTIONS: Record<string, string> = {
  total: "The order total no longer equals its line items. Do not edit the order; report it for a database check (Diagnostics).",
  cost: "The order cost no longer equals its lines' frozen costs. Report it for a database check; profit for this order is unreliable.",
  profit: "Gross profit is not total minus cost. Report it for a database check.",
  paid: "The amount paid does not match the recorded payments. Do not re-enter a payment; report it for a database check.",
  balance: "The outstanding balance is not total minus paid. Do not record a payment against it until it is checked.",
  status: "The payment status does not match the payments. Report it for a database check.",
  overpaid: "Payments exceed the order total. Confirm with the customer whether this is a refund or credit, then report it.",
  noLines: "The order has no products. Check the order; it may need to be cancelled.",
  deliveredBalance: "Fully delivered but not fully paid: follow up with the customer and record the payment when it arrives.",
  cancelledPaid: "A cancelled order still holds payments, which are left out of Cash received. Decide whether to refund or move the money.",
  noProduct: "A line refers to a product that no longer exists. Historical figures stand; no action unless the product was deleted by mistake.",
  termsMissing: "No invoice can be issued until a Super Admin records whether it was paid at sale or on credit (set_order_payment_terms, with the evidence). Receipts are unaffected.",
  paidAtSaleBalance: "Recorded as paid at sale, but money is still owed (for example the initial payment failed). Collect it; the terms stay as recorded.",
  zeroCost: "A line was sold with no recorded cost, so its profit is overstated. Record the product cost for future sales.",
  belowCost: "A line was sold below its recorded cost (approved below-cost sale or pricing error). Review the price.",
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
    { key: "termsMissing", label: "Orders with no recorded payment terms (awaiting review)", severity: "WARN", needsCost: false, test: (o) => isSale(o) && o.paymentTerms === null },
    { key: "paidAtSaleBalance", label: "Paid-at-sale orders that still have a balance", severity: "WARN", needsCost: false, test: (o) => isSale(o) && o.paymentTerms === "paid_at_sale" && o.outstandingCents > 0 },
    { key: "zeroCost", label: "Orders with a line at no recorded cost (profit overstated)", severity: "WARN", needsCost: true, test: (o) => o.lines.some((l) => l.costCents === 0) },
    { key: "belowCost", label: "Orders with a line sold below its recorded cost", severity: "WARN", needsCost: true, test: (o) => o.lines.some((l) => l.costCents !== null && lineRevenueCents(l) < l.costCents) },
  ];
  return checks.map((c) => {
    const action = ACTIONS[c.key] ?? "";
    if (c.needsCost && !withCost) return { key: c.key, label: c.label, severity: c.severity, count: 0, orderIds: [], available: false, action };
    const ids = ds.orders.filter(c.test).map((o) => o.id);
    return { key: c.key, label: c.label, severity: c.severity, count: ids.length, orderIds: ids, available: true, action };
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
