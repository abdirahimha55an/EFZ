/**
 * Invoices and receipts, built only from what the database already stores:
 * order lines at the agreed price (actual_unit_price), the order total, the
 * payment rows and the database-maintained amount_paid / outstanding_balance.
 * Nothing is recalculated into the records and nothing is written.
 *
 * Business rules (one place to change them):
 *  - Immediate-payment sale: payments dated ON the order date cover the whole
 *    order total. No invoice; each payment has a receipt.
 *  - Credit order: any other non-cancelled order with a positive total. It has
 *    an invoice (total fixed by the order) and a receipt per payment.
 *  - Cancelled orders, a total that does not equal its lines, and non-positive
 *    payments produce no document (they would be misleading).
 *
 * Numbering, stable and unique without a new table:
 *  - Invoice  INV-<order id>      (order ids are unique and never change)
 *  - Receipt  RCT-<first 12 hex of the payment uuid, upper case>
 */

import type { Order } from "@/lib/types";
import { toCents } from "@/lib/analytics/dataset";

export type DocPayment = { id: string; date: string; createdAt: string; amountCents: number; method: string; reference: string };

/** The order fields a document needs, in integer cents. */
export type DocOrder = {
  id: string;
  date: string;
  status: Order["status"];
  customerName: string;
  phone: string;
  orderType: string;
  totalCents: number;
  amountPaidCents: number;
  outstandingCents: number;
  lines: { name: string; quantity: number; unitPriceCents: number; lineTotalCents: number }[];
  payments: DocPayment[];
};

export function toDocOrder(order: Order): DocOrder {
  return {
    id: order.id,
    date: order.date,
    status: order.status,
    customerName: order.customer || order.customerName || "Customer",
    phone: order.phone || order.customerPhone || "",
    orderType: order.orderType || "regular",
    totalCents: toCents(order.total),
    amountPaidCents: toCents(order.amountPaid),
    outstandingCents: toCents(order.outstandingBalance),
    lines: (order.items ?? []).map((i) => {
      const unit = toCents(i.actualUnitPrice ?? i.price ?? 0);
      const qty = Math.max(0, Number(i.quantity || 0));
      return { name: [i.productName || "Item", i.designName].filter(Boolean).join(" — "), quantity: qty, unitPriceCents: unit, lineTotalCents: unit * qty };
    }),
    payments: (order.payments ?? []).map((p) => ({
      id: String(p.id), date: p.paymentDate, createdAt: p.createdAt ?? "", amountCents: toCents(p.amount),
      method: (p.paymentMethod ?? "").trim(), reference: (p.reference ?? "").trim(),
    })),
  };
}

/** Printable documents open in a new tab (app/admin/documents). */
export const invoiceHref = (orderId: string) => `/admin/documents?type=invoice&order=${encodeURIComponent(orderId)}`;
export const receiptHref = (orderId: string, paymentId: string) => `/admin/documents?type=receipt&order=${encodeURIComponent(orderId)}&payment=${encodeURIComponent(paymentId)}`;

export const invoiceNumber = (orderId: string) => `INV-${orderId}`;
export const receiptNumber = (paymentId: string) => `RCT-${paymentId.replace(/[^0-9a-fA-F]/g, "").slice(0, 12).toUpperCase()}`;

/** Payments in the order they were received: payment date, then entry time, then id. */
export function chronological(payments: DocPayment[]): DocPayment[] {
  return [...payments].sort((a, b) => (a.date !== b.date ? (a.date < b.date ? -1 : 1) : a.createdAt !== b.createdAt ? (a.createdAt < b.createdAt ? -1 : 1) : a.id < b.id ? -1 : 1));
}

type Shape = Pick<DocOrder, "status" | "date" | "totalCents"> & { payments: { date: string; amountCents: number }[] };

/** Paid in full by payments dated on the order date. */
export function isImmediatePayment(o: Shape): boolean {
  if (o.status === "cancelled" || o.totalCents <= 0) return false;
  const sameDay = o.payments.filter((p) => p.date === o.date && p.amountCents > 0).reduce((s, p) => s + p.amountCents, 0);
  return sameDay >= o.totalCents;
}

export type Eligibility = { ok: true } | { ok: false; reason: string };

export function invoiceEligibility(o: DocOrder): Eligibility {
  if (o.status === "cancelled") return { ok: false, reason: "Cancelled orders have no invoice." };
  if (o.totalCents <= 0) return { ok: false, reason: "The order has no amount to invoice." };
  if (o.lines.reduce((s, l) => s + l.lineTotalCents, 0) !== o.totalCents) {
    return { ok: false, reason: "The order total does not match its lines; see Financial Checks & Exceptions before issuing documents." };
  }
  if (isImmediatePayment(o)) return { ok: false, reason: "Paid in full at the sale: no invoice; use the receipt." };
  return { ok: true };
}

/** Light check for list views (no line reconciliation): is an invoice offered for this order? */
export const offersInvoice = (o: Shape) => o.status !== "cancelled" && o.totalCents > 0 && !isImmediatePayment(o);

export type PaymentStatusLabel = "PAID" | "PARTIALLY PAID" | "UNPAID";
export const statusLabel = (o: Pick<DocOrder, "outstandingCents" | "amountPaidCents">): PaymentStatusLabel =>
  o.outstandingCents <= 0 ? "PAID" : o.amountPaidCents > 0 ? "PARTIALLY PAID" : "UNPAID";

export type InvoiceDoc = {
  number: string;
  issueDate: string;
  order: DocOrder;
  /** Database-maintained figures, shown as they are. */
  totalCents: number;
  paidCents: number;
  outstandingCents: number;
  status: PaymentStatusLabel;
  payments: (DocPayment & { receiptNumber: string })[];
};

export function buildInvoice(o: DocOrder): InvoiceDoc | { error: string } {
  const e = invoiceEligibility(o);
  if (!e.ok) return { error: e.reason };
  return {
    number: invoiceNumber(o.id),
    issueDate: o.date,
    order: o,
    totalCents: o.totalCents,
    paidCents: o.amountPaidCents,
    outstandingCents: Math.max(0, o.outstandingCents),
    status: statusLabel(o),
    payments: chronological(o.payments).filter((p) => p.amountCents > 0).map((p) => ({ ...p, receiptNumber: receiptNumber(p.id) })),
  };
}

export type ReceiptDoc = {
  number: string;
  payment: DocPayment;
  order: DocOrder;
  /** INV-… for a credit order; null for an immediate-payment sale. */
  invoiceNumber: string | null;
  /** Received on this order up to and including this payment. */
  paidToDateCents: number;
  /** Order total minus everything received up to and including this payment (never below 0). */
  balanceAfterCents: number;
};

export function buildReceipt(o: DocOrder, paymentId: string): ReceiptDoc | { error: string } {
  if (o.status === "cancelled") return { error: "Payments on a cancelled order have no receipt; see Financial Checks & Exceptions." };
  const ordered = chronological(o.payments);
  const idx = ordered.findIndex((p) => p.id === paymentId);
  if (idx < 0) return { error: "Payment not found on this order." };
  const payment = ordered[idx];
  if (payment.amountCents <= 0) return { error: "Not a valid payment amount; no receipt." };
  const paidToDate = ordered.slice(0, idx + 1).reduce((s, p) => s + Math.max(0, p.amountCents), 0);
  return {
    number: receiptNumber(payment.id),
    payment,
    order: o,
    invoiceNumber: invoiceEligibility(o).ok ? invoiceNumber(o.id) : null,
    paidToDateCents: paidToDate,
    balanceAfterCents: Math.max(0, o.totalCents - paidToDate),
  };
}
