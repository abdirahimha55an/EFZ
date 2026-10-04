/**
 * One normalised set of sales facts, built once from order_details rows.
 *
 * Every Sales & Analytics figure, chart, forecast, export and assistant answer
 * is computed from this, so they cannot disagree. Money is held in integer
 * cents so sums are exact; convert with fromCents() only for display.
 *
 * Definitions (see docs in the page's "How is this calculated?" notes):
 *  - Sales set: every order whose status is not 'cancelled'.
 *  - Booked: the ordered quantity x the actual (negotiated) unit price.
 *  - Delivered: deliveredQuantity (delivery lines plus corrections, from the
 *    database) x the actual unit price.
 *  - Remaining: remainingQuantity, the balls still to deliver.
 *  - The sales date is orders.order_date (a Mogadishu business date).
 */

import type { Customer, Order, OrderStatus, OrderType, Product } from "@/lib/types";
import { inRange, type DateRange } from "./period";

export const OPEN_STATUSES: OrderStatus[] = ["pending", "confirmed", "processing", "partially_delivered"];

export type SalesLine = {
  orderId: string;
  /** product id, or "name:<product name>" when the line has no product id. */
  productKey: string;
  productId: string | null;
  productName: string;
  quantity: number;
  delivered: number;
  remaining: number;
  unitPriceCents: number;
  listPriceCents: number;
};

export type SalesPayment = { amountCents: number; date: string; method: string };

export type SalesOrder = {
  id: string;
  date: string;
  createdAt: string;
  status: OrderStatus;
  orderType: OrderType;
  customerId: string | null;
  customerName: string;
  officerId: string | null;
  officerName: string;
  stockMode: "at_creation" | "at_delivery";
  lines: SalesLine[];
  payments: SalesPayment[];
  /** Database-maintained (record_payment / triggers); never recomputed here. */
  outstandingCents: number;
  amountPaidCents: number;
  /** Null when the database withholds cost from this user. */
  grossProfitCents: number | null;
  costCents: number | null;
};

export type Dataset = {
  orders: SalesOrder[];
  products: Product[];
  customers: Customer[];
  /** First order_date in the sales set, or null when there are no sales. */
  firstSaleDate: string | null;
  /** First sales-set order of each customer: date then entry time (all visible orders). */
  firstOrderByCustomer: Map<string, { date: string; createdAt: string; orderId: string }>;
};

export const toCents = (value: number | null | undefined): number => Math.round(Number(value ?? 0) * 100);
export const fromCents = (cents: number): number => cents / 100;

export const isSale = (order: Pick<SalesOrder, "status">) => order.status !== "cancelled";
export const isOpen = (order: Pick<SalesOrder, "status">) => OPEN_STATUSES.includes(order.status);

export function productKeyOf(productId: string | null | undefined, productName: string): string {
  return productId ? productId : `name:${productName}`;
}

function toSalesLine(order: Order, item: Order["items"][number]): SalesLine {
  const quantity = Math.max(0, Number(item.quantity || 0));
  // order_details always sends deliveredQuantity (migration 12). The fallback
  // only covers an older row shape: a delivered order counts as fully delivered.
  const delivered = item.deliveredQuantity !== undefined
    ? Math.max(0, Number(item.deliveredQuantity))
    : order.status === "delivered" ? quantity : 0;
  const remaining = item.remainingQuantity !== undefined
    ? Math.max(0, Number(item.remainingQuantity))
    : Math.max(quantity - delivered, 0);
  const productId = item.productId ? String(item.productId) : null;
  const productName = item.productName || "Unknown product";
  return {
    orderId: order.id,
    productKey: productKeyOf(productId, productName),
    productId,
    productName,
    quantity,
    delivered,
    remaining,
    unitPriceCents: toCents(item.actualUnitPrice ?? item.price ?? 0),
    listPriceCents: toCents(item.standardUnitPrice ?? 0),
  };
}

export function toSalesOrder(order: Order): SalesOrder {
  return {
    id: order.id,
    date: order.date,
    createdAt: order.createdAt ?? "",
    status: order.status,
    orderType: order.orderType === "trial" ? "trial" : "regular",
    customerId: order.customerId ? String(order.customerId) : null,
    customerName: order.customer || order.customerName || "Unknown customer",
    officerId: order.marketingOfficerId ? String(order.marketingOfficerId) : null,
    officerName: order.marketingOfficerName || "",
    stockMode: order.stockMode === "at_delivery" ? "at_delivery" : "at_creation",
    lines: (order.items ?? []).map((item) => toSalesLine(order, item)),
    payments: (order.payments ?? []).map((p) => ({
      amountCents: toCents(p.amount),
      date: p.paymentDate,
      method: (p.paymentMethod ?? "").trim(),
    })),
    outstandingCents: toCents(order.outstandingBalance),
    amountPaidCents: toCents(order.amountPaid),
    grossProfitCents: order.grossProfit === null || order.grossProfit === undefined ? null : toCents(order.grossProfit),
    costCents: order.cost === null || order.cost === undefined ? null : toCents(order.cost),
  };
}

const byDateThenEntry = (a: SalesOrder, b: SalesOrder) =>
  a.date < b.date ? -1 : a.date > b.date ? 1 : a.createdAt < b.createdAt ? -1 : a.createdAt > b.createdAt ? 1 : a.id < b.id ? -1 : 1;

export function buildDataset(orders: Order[], products: Product[], customers: Customer[]): Dataset {
  const sales = orders.map(toSalesOrder).sort(byDateThenEntry);
  const firstOrderByCustomer = new Map<string, { date: string; createdAt: string; orderId: string }>();
  let firstSaleDate: string | null = null;
  for (const o of sales) {
    if (!isSale(o)) continue;
    if (firstSaleDate === null) firstSaleDate = o.date;
    if (o.customerId && !firstOrderByCustomer.has(o.customerId)) {
      firstOrderByCustomer.set(o.customerId, { date: o.date, createdAt: o.createdAt, orderId: o.id });
    }
  }
  return { orders: sales, products, customers, firstSaleDate, firstOrderByCustomer };
}

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

export const UNASSIGNED_OFFICER = "__unassigned__";

export type SalesFilters = {
  /** A productKey, or null for every product. Applied per order LINE. */
  productKey: string | null;
  customerId: string | null;
  /** An officer id, UNASSIGNED_OFFICER, or null for everyone. */
  officerId: string | null;
  orderType: "all" | "regular" | "trial";
  /** "all" = every non-cancelled order; "delivered" = fully delivered only; "open" = not yet fully delivered. */
  status: "all" | "delivered" | "open";
};

export const NO_FILTERS: SalesFilters = { productKey: null, customerId: null, officerId: null, orderType: "all", status: "all" };

export const hasNarrowingFilter = (f: SalesFilters) =>
  f.productKey !== null || f.customerId !== null || f.officerId !== null || f.orderType !== "all" || f.status !== "all";

/** Order-level filters (everything but product and date). Cancelled orders never match. */
export function orderMatches(order: SalesOrder, f: SalesFilters): boolean {
  if (!isSale(order)) return false;
  if (f.customerId !== null && order.customerId !== f.customerId) return false;
  if (f.officerId !== null) {
    if (f.officerId === UNASSIGNED_OFFICER ? order.officerId !== null : order.officerId !== f.officerId) return false;
  }
  if (f.orderType !== "all" && order.orderType !== f.orderType) return false;
  if (f.status === "delivered" && order.status !== "delivered") return false;
  if (f.status === "open" && !isOpen(order)) return false;
  return true;
}

export const lineMatches = (line: SalesLine, f: SalesFilters) => f.productKey === null || line.productKey === f.productKey;

export type Selection = { order: SalesOrder; lines: SalesLine[] };

/**
 * The orders (and their matching lines) in a date range. With a product
 * filter only that product's lines count, and an order counts only when it
 * has such a line.
 */
export function select(ds: Dataset, f: SalesFilters, range: DateRange | null): Selection[] {
  const out: Selection[] = [];
  for (const order of ds.orders) {
    if (range && !inRange(order.date, range)) continue;
    if (!orderMatches(order, f)) continue;
    const lines = order.lines.filter((l) => lineMatches(l, f));
    if (f.productKey !== null && lines.length === 0) continue;
    out.push({ order, lines });
  }
  return out;
}
