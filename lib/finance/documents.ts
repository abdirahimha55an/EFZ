/**
 * Invoices and receipts, built only from what the database already stores:
 * order lines at the agreed price (actual_unit_price), the order total, the
 * payment rows, the database-maintained amount_paid / outstanding_balance and
 * the order's fixed payment terms (orders.payment_terms, migration 20).
 * Nothing is recalculated into the records and nothing is written.
 *
 * Business rules (one place to change them):
 *  - credit        the customer may pay later: invoice + a receipt per payment.
 *                  The invoice stays available after full settlement.
 *  - paid_at_sale  paid in full at the sale: receipts only, never an invoice.
 *  - not recorded  (legacy / converted orders awaiting review): no invoice until
 *                  a Super Admin records the terms; receipts are still available.
 *  Terms are never inferred from payment dates or balances.
 *  Cancelled orders, a total that does not equal its lines, and non-positive
 *  payments produce no document.
 *
 * Numbering, stable and unique without a new table:
 *  - Invoice  INV-<order id>      (order ids are unique and never change)
 *  - Receipt  RCT-<rest>   for ids 'pay-<rest>' whose rest does not start with '_'
 *             (every record_payment() id and the imported legacy ids), RCT-_<id>
 *             for every other id. Injective: the two families differ in the first
 *             character after 'RCT-', each mapping is one-to-one, and payment ids
 *             are the payments primary key.
 *
 * Receipt figures (paid to date, balance after) are RECONSTRUCTED from the
 * payment records and order total as they stand when the document is opened,
 * not a snapshot taken when the payment was recorded.
 */

import type { Order, PaymentTerms } from "@/lib/types";
import { toCents } from "@/lib/analytics/dataset";

export type DocPayment = { id: string; date: string; createdAt: string; amountCents: number; method: string; reference: string };

/** The order fields a document needs, in integer cents. */
export type DocOrder = {
  id: string;
  date: string;
  status: Order["status"];
  paymentTerms: PaymentTerms | null;
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
    paymentTerms: order.paymentTerms ?? null,
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
export const receiptNumber = (paymentId: string) =>
  paymentId.startsWith("pay-") && !paymentId.startsWith("pay-_") ? `RCT-${paymentId.slice(4)}` : `RCT-_${paymentId}`;

/** Payments in the order they were received: payment date, then entry time, then id. */
export function chronological(payments: DocPayment[]): DocPayment[] {
  return [...payments].sort((a, b) => (a.date !== b.date ? (a.date < b.date ? -1 : 1) : a.createdAt !== b.createdAt ? (a.createdAt < b.createdAt ? -1 : 1) : a.id < b.id ? -1 : 1));
}

export type Eligibility = { ok: true } | { ok: false; reason: string };

export const TERMS_NOT_RECORDED = "Payment terms are not recorded for this order (it predates them or came from a website request). A Super Admin must review it before an invoice can be issued.";

export function invoiceEligibility(o: DocOrder): Eligibility {
  if (o.status === "cancelled") return { ok: false, reason: "Cancelled orders have no invoice." };
  if (o.paymentTerms === "paid_at_sale") return { ok: false, reason: "Paid at sale: no invoice; use the receipt." };
  if (o.paymentTerms !== "credit") return { ok: false, reason: TERMS_NOT_RECORDED };
  if (o.totalCents <= 0) return { ok: false, reason: "The order has no amount to invoice." };
  if (o.lines.reduce((s, l) => s + l.lineTotalCents, 0) !== o.totalCents) {
    return { ok: false, reason: "The order total does not match its lines; see Financial Checks & Exceptions before issuing documents." };
  }
  return { ok: true };
}

/** For list views (no line reconciliation): is an invoice offered for this order? Stored terms only. */
export const offersInvoice = (o: { status: Order["status"]; totalCents: number; paymentTerms: PaymentTerms | null }) =>
  o.status !== "cancelled" && o.totalCents > 0 && o.paymentTerms === "credit";

export type PaymentStatusLabel = "PAID" | "PARTIALLY PAID" | "UNPAID";
export const statusLabel = (o: Pick<DocOrder, "outstandingCents" | "amountPaidCents">): PaymentStatusLabel =>
  o.outstandingCents <= 0 ? "PAID" : o.amountPaidCents > 0 ? "PARTIALLY PAID" : "UNPAID";

export type InvoiceDoc = {
  number: string;
  issueDate: string;
  order: DocOrder;
  /** Database-maintained figures as they stand on asOf. */
  totalCents: number;
  paidCents: number;
  outstandingCents: number;
  status: PaymentStatusLabel;
  asOf: string;
  payments: (DocPayment & { receiptNumber: string })[];
};

export function buildInvoice(o: DocOrder, asOf: string): InvoiceDoc | { error: string } {
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
    asOf,
    payments: chronological(o.payments).filter((p) => p.amountCents > 0).map((p) => ({ ...p, receiptNumber: receiptNumber(p.id) })),
  };
}

export type ReceiptDoc = {
  number: string;
  payment: DocPayment;
  order: DocOrder;
  /** INV-… only for a credit order with a valid invoice. */
  invoiceNumber: string | null;
  /** True only when the stored terms say paid_at_sale. */
  paidAtSale: boolean;
  /** Reconstructed on asOf: received on this order up to and including this payment. */
  paidToDateCents: number;
  /** Reconstructed on asOf: current order total minus paidToDate (never below 0). */
  balanceAfterCents: number;
  asOf: string;
};

export function buildReceipt(o: DocOrder, paymentId: string, asOf: string): ReceiptDoc | { error: string } {
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
    paidAtSale: o.paymentTerms === "paid_at_sale",
    paidToDateCents: paidToDate,
    balanceAfterCents: Math.max(0, o.totalCents - paidToDate),
    asOf,
  };
}
