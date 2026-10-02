/**
 * Presentation helpers for commission (migration 12 model). Pure - no queries.
 *
 * Every EARNED figure here is read from the commission rows the database
 * recorded (one row per legacy order, delivery, correction or first-order
 * bonus). Nothing is recalculated: a row's `amount` is shown exactly as stored.
 *
 * The only computed figure is the EXPECTED commission on balls not yet
 * delivered. It is a forecast, never stored, never added to an earned total,
 * and every screen labels it as expected.
 */
import type { CommissionRow, OrderDeliveryLineRow, OrderDeliveryRow } from "@/lib/supabase/database.types";
import type { Order, OrderStatus } from "@/lib/types";

/** A commission row with the order it belongs to (null when that order is no longer visible). */
export type CommissionEvent = CommissionRow & {
  orders: { id: string; customer_name: string; order_date: string; status: OrderStatus } | null;
};

export type DeliveryWithLines = OrderDeliveryRow & { lines: OrderDeliveryLineRow[] };

export type CommissionPolicyView = {
  perBallRate: number;
  firstOrderBonus: number;
  bonusMinBalls: number;
  cutoverAt: string | null;
};

/** Always two decimals: $0.30 must never read as $0. */
export function money(value: number | string | null | undefined): string {
  const n = Number(value ?? 0);
  return `${n < 0 ? "-" : ""}$${Math.abs(Number.isFinite(n) ? n : 0).toFixed(2)}`;
}

const round2 = (n: number) => Math.round(n * 100) / 100;

export type CommissionKind = NonNullable<CommissionRow["kind"]>;

export function kindLabel(row: Pick<CommissionRow, "kind">): string {
  switch (row.kind) {
    case "delivery": return "Delivery";
    case "correction": return "Correction";
    case "first_order_bonus": return "First-order bonus";
    default: return "Legacy commission";
  }
}

const balls = (n: number) => `${n} Football ball${n === 1 ? "" : "s"}`;

/** What the row records, in words, using only the row's own stored values. */
export function eventDescription(row: CommissionRow): string {
  let text: string;
  switch (row.kind) {
    case "delivery":
      text = `${balls(Number(row.units ?? 0))} × ${money(row.per_ball_rate)}`;
      break;
    case "correction":
      text = `Delivered-quantity correction: +${balls(Number(row.units ?? 0))} × ${money(row.per_ball_rate)}`;
      break;
    case "first_order_bonus":
      text = "First-order bonus";
      break;
    default:
      text = `${Number(row.rate)}% of ${money(row.base_amount)} (legacy rate)`;
  }
  if (row.status === "void" && row.void_reason) text += ` — voided: ${row.void_reason}`;
  else if (row.review_required && row.review_reason) text += ` — on hold: ${row.review_reason}`;
  return text;
}

export type DisplayStatus = "Pending" | "Approved" | "On hold" | "Paid" | "Void";

/**
 * The officer-facing status of one recorded commission. "On hold" is an unpaid
 * row flagged for review (blocked from payout). A paid row stays "Paid" even if
 * later flagged - it is never clawed back.
 */
export function displayStatus(row: Pick<CommissionRow, "status" | "review_required">): DisplayStatus {
  if (row.status === "void") return "Void";
  if (row.status === "paid") return "Paid";
  if (row.review_required) return "On hold";
  return row.status === "approved" ? "Approved" : "Pending";
}

export const STATUS_HINT: Record<DisplayStatus, string> = {
  Pending: "Earned · unpaid",
  Approved: "Earned · unpaid (approved)",
  "On hold": "Earned · on hold for review",
  Paid: "Paid out",
  Void: "Cancelled · not owed",
};

export function statusClass(status: DisplayStatus): string {
  switch (status) {
    case "Paid": return "bg-green-100 text-green-700 border-green-200";
    case "On hold": return "bg-amber-100 text-amber-800 border-amber-200";
    case "Void": return "bg-slate-100 text-slate-500 border-slate-200 line-through";
    case "Approved": return "bg-blue-100 text-blue-700 border-blue-200";
    default: return "bg-orange-50 text-orange-700 border-orange-200";
  }
}

/** When the commission was earned (per-ball and bonus rows), else when it was recorded. */
export const eventDate = (row: Pick<CommissionRow, "earned_at" | "created_at">) => row.earned_at ?? row.created_at;

export type CommissionTotals = {
  /** Every recorded, non-void commission: unpaid + on hold + paid. A fact. */
  earned: number;
  /** Earned, not paid, not on hold. */
  unpaid: number;
  /** Earned, not paid, flagged for review. */
  onHold: number;
  /** Paid out. */
  paid: number;
};

/** Totals of recorded commission only. Expected commission is never included. */
export function summarize(rows: Pick<CommissionRow, "amount" | "status" | "review_required">[]): CommissionTotals {
  const totals = { earned: 0, unpaid: 0, onHold: 0, paid: 0 };
  for (const row of rows) {
    const amount = Number(row.amount ?? 0);
    const status = displayStatus(row);
    if (status === "Void") continue;
    totals.earned += amount;
    if (status === "Paid") totals.paid += amount;
    else if (status === "On hold") totals.onHold += amount;
    else totals.unpaid += amount;
  }
  return {
    earned: round2(totals.earned),
    unpaid: round2(totals.unpaid),
    onHold: round2(totals.onHold),
    paid: round2(totals.paid),
  };
}

/** Ids of the products that earn per-ball commission (category Football). Null if categories are unknown. */
export function footballIdsOf(products: { id: string; category?: string | null }[] | null): Set<string> | null {
  if (!products || products.length === 0) return null;
  return new Set(products.filter((p) => p.category === "Football").map((p) => p.id));
}

/** Footballs ordered and delivered on an order (null when the product categories are unknown). */
export function footballCounts(order: Order, footballIds: Set<string> | null): { ordered: number; delivered: number; remaining: number } | null {
  if (!footballIds) return null;
  const items = order.items.filter((item) => footballIds.has(item.productId));
  const ordered = items.reduce((s, i) => s + Number(i.quantity || 0), 0);
  const delivered = items.reduce((s, i) => s + Number(i.deliveredQuantity ?? 0), 0);
  const remaining = items.reduce((s, i) => s + Number(i.remainingQuantity ?? Math.max(0, Number(i.quantity || 0) - Number(i.deliveredQuantity ?? 0))), 0);
  return { ordered, delivered, remaining };
}

/**
 * EXPECTED (forecast) per-ball commission on the balls of this order not yet
 * delivered. Null when the order will not earn per-ball commission (legacy
 * model, cancelled, fully delivered) or when it cannot be worked out (product
 * categories unknown, model not active). Never earned money.
 */
export function expectedForOrder(
  order: Order,
  policy: CommissionPolicyView | null,
  footballIds: Set<string> | null
): { balls: number; amount: number } | null {
  if (!policy || order.status === "cancelled" || order.status === "delivered") return null;
  const perBall =
    order.commissionModel === "per_ball_v1" ||
    // Still pending: classified at first confirmation, which is after the cut-over.
    (!order.commissionModel && order.status === "pending" && Boolean(policy.cutoverAt));
  if (!perBall) return null;
  const counts = footballCounts(order, footballIds);
  if (!counts) return null;
  return { balls: counts.remaining, amount: round2(counts.remaining * policy.perBallRate) };
}

export type DeliveryLineBreakdown = { productName: string; quantity: number; rate: number; amount: number };

/**
 * Splits ONE recorded delivery commission row across the products of that
 * delivery, using the delivery's own lines and the row's own stored rate.
 * Shown only when it reproduces the stored row exactly (same balls, same
 * amount); otherwise the caller shows the stored row total alone.
 */
export function deliveryBreakdown(
  row: CommissionRow,
  delivery: DeliveryWithLines | undefined,
  order: Order,
  footballIds: Set<string> | null
): { lines: DeliveryLineBreakdown[]; consistent: boolean } {
  if (row.kind !== "delivery" || !delivery || !footballIds) return { lines: [], consistent: false };
  const rate = Number(row.per_ball_rate ?? 0);
  const lines: DeliveryLineBreakdown[] = [];
  for (const line of delivery.lines) {
    const item = order.items.find((i) => i.id === line.order_item_id);
    if (!item || !footballIds.has(item.productId)) continue;
    lines.push({ productName: item.productName, quantity: line.quantity, rate, amount: round2(line.quantity * rate) });
  }
  const units = lines.reduce((s, l) => s + l.quantity, 0);
  const amount = round2(lines.reduce((s, l) => s + l.amount, 0));
  const consistent = units === Number(row.units ?? -1) && amount === round2(Number(row.amount));
  return { lines, consistent };
}

/** Whole days between an ISO date/time and now (0 on the same day). */
export function daysSince(iso: string | null | undefined): number | null {
  if (!iso) return null;
  const t = new Date(iso).getTime();
  if (!Number.isFinite(t)) return null;
  return Math.max(0, Math.floor((Date.now() - t) / 86_400_000));
}
