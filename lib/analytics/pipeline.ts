/**
 * Open order pipeline: COMMITTED sales that are booked but not fully delivered.
 *
 * It describes the state right now, so the period filter does not apply. The
 * product (per line), customer, officer and order-type filters do.
 */

import { OPEN_STATUSES, isOpen, lineMatches, orderMatches, type Dataset, type SalesFilters } from "./dataset";
import type { OrderStatus } from "@/lib/types";
import { daysBetween } from "./period";

export type PipelineOrder = {
  orderId: string;
  date: string;
  ageDays: number;
  customerId: string | null;
  customerName: string;
  officerName: string;
  status: OrderStatus;
  remainingUnits: number;
  remainingCents: number;
  bookedCents: number;
};

export type PipelineStatusRow = { status: OrderStatus; orders: number; remainingUnits: number; remainingCents: number };

export type Pipeline = {
  orders: PipelineOrder[];
  byStatus: PipelineStatusRow[];
  totalOrders: number;
  remainingUnits: number;
  remainingCents: number;
  oldest: PipelineOrder | null;
};

export function pipeline(ds: Dataset, f: SalesFilters, today: string): Pipeline {
  const scope: SalesFilters = { ...f, status: f.status === "delivered" ? "delivered" : "open" };
  const rows: PipelineOrder[] = [];
  for (const o of ds.orders) {
    if (!isOpen(o) || !orderMatches(o, scope)) continue;
    const lines = o.lines.filter((l) => lineMatches(l, f));
    if (f.productKey !== null && lines.length === 0) continue;
    let units = 0, cents = 0, booked = 0;
    for (const l of lines) {
      units += l.remaining;
      cents += l.remaining * l.unitPriceCents;
      booked += l.quantity * l.unitPriceCents;
    }
    rows.push({
      orderId: o.id, date: o.date, ageDays: Math.max(0, daysBetween(o.date, today)),
      customerId: o.customerId, customerName: o.customerName, officerName: o.officerName,
      status: o.status, remainingUnits: units, remainingCents: cents, bookedCents: booked,
    });
  }
  rows.sort((a, b) => b.ageDays - a.ageDays || a.orderId.localeCompare(b.orderId));
  const byStatus = OPEN_STATUSES.map((status) => {
    const of = rows.filter((r) => r.status === status);
    return {
      status,
      orders: of.length,
      remainingUnits: of.reduce((s, r) => s + r.remainingUnits, 0),
      remainingCents: of.reduce((s, r) => s + r.remainingCents, 0),
    };
  });
  return {
    orders: rows,
    byStatus,
    totalOrders: rows.length,
    remainingUnits: rows.reduce((s, r) => s + r.remainingUnits, 0),
    remainingCents: rows.reduce((s, r) => s + r.remainingCents, 0),
    oldest: rows[0] ?? null,
  };
}

export const STATUS_LABEL: Record<OrderStatus, string> = {
  pending: "Pending",
  confirmed: "Confirmed",
  processing: "Processing",
  partially_delivered: "Partially delivered",
  delivered: "Delivered",
  cancelled: "Cancelled",
};
