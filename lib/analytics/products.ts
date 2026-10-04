/**
 * Product performance, calculated per order LINE (a product filter never pulls
 * in the other products of the same order). Cancelled orders are excluded.
 */

import { select, type Dataset, type SalesFilters } from "./dataset";
import type { DateRange } from "./period";

export type ProductRow = {
  productKey: string;
  productId: string | null;
  name: string;
  bookedUnits: number;
  deliveredUnits: number;
  bookedCents: number;
  deliveredCents: number;
  /** Share of booked revenue in the selection, 0-100. */
  sharePct: number;
  /** Booked revenue / booked units. */
  avgPriceCents: number | null;
  /** Average list (standard) price over lines that have one. */
  avgListPriceCents: number | null;
  /** Sum(actual x qty) / Sum(list x qty) x 100 over lines with a list price; null when none. */
  realizationPct: number | null;
  /** Sum((list - actual) x qty) over lines with a list price. */
  discountCents: number;
  /** Sum(list x qty) and Sum(actual x qty) over the lines that have a list price. */
  listBasisCents: number;
  actualOnListCents: number;
  /** Units on lines that have a list price. */
  listUnits: number;
  orders: number;
  customers: number;
  lastSaleDate: string | null;
};

export function productPerformance(ds: Dataset, f: SalesFilters, range: DateRange): ProductRow[] {
  type Acc = ProductRow & { _orders: Set<string>; _customers: Set<string> };
  const map = new Map<string, Acc>();
  let total = 0;
  for (const { order, lines } of select(ds, f, range)) {
    for (const l of lines) {
      let r = map.get(l.productKey);
      if (!r) {
        r = {
          productKey: l.productKey, productId: l.productId, name: l.productName,
          bookedUnits: 0, deliveredUnits: 0, bookedCents: 0, deliveredCents: 0, sharePct: 0,
          avgPriceCents: null, avgListPriceCents: null, realizationPct: null, discountCents: 0,
          listBasisCents: 0, actualOnListCents: 0, listUnits: 0,
          orders: 0, customers: 0, lastSaleDate: null,
          _orders: new Set(), _customers: new Set(),
        };
        map.set(l.productKey, r);
      }
      r.bookedUnits += l.quantity;
      r.deliveredUnits += l.delivered;
      r.bookedCents += l.unitPriceCents * l.quantity;
      r.deliveredCents += l.unitPriceCents * l.delivered;
      total += l.unitPriceCents * l.quantity;
      if (l.listPriceCents > 0) {
        r.listUnits += l.quantity;
        r.listBasisCents += l.listPriceCents * l.quantity;
        r.actualOnListCents += l.unitPriceCents * l.quantity;
      }
      r._orders.add(order.id);
      if (order.customerId) r._customers.add(order.customerId);
      if (!r.lastSaleDate || order.date > r.lastSaleDate) r.lastSaleDate = order.date;
    }
  }
  return [...map.values()]
    .map(({ _orders, _customers, ...r }) => ({
      ...r,
      sharePct: total > 0 ? (r.bookedCents / total) * 100 : 0,
      avgPriceCents: r.bookedUnits > 0 ? Math.round(r.bookedCents / r.bookedUnits) : null,
      avgListPriceCents: r.listUnits > 0 ? Math.round(r.listBasisCents / r.listUnits) : null,
      realizationPct: r.listBasisCents > 0 ? (r.actualOnListCents / r.listBasisCents) * 100 : null,
      discountCents: r.listBasisCents - r.actualOnListCents,
      orders: _orders.size,
      customers: _customers.size,
    }))
    .sort((a, b) => b.bookedCents - a.bookedCents || b.bookedUnits - a.bookedUnits || a.name.localeCompare(b.name));
}

/** Price realisation over the whole selection. */
export function overallRealization(rows: ProductRow[]): { realizationPct: number | null; discountCents: number } {
  const list = rows.reduce((sum, r) => sum + r.listBasisCents, 0);
  const actual = rows.reduce((sum, r) => sum + r.actualOnListCents, 0);
  return { realizationPct: list > 0 ? (actual / list) * 100 : null, discountCents: list - actual };
}
