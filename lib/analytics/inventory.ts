/**
 * Sales-driven inventory intelligence (INDICATIVE). Not a replacement for the
 * Inventory module: it only relates current stock to recent sales demand.
 *
 *  commitments  = balls still to deliver on open orders taken with
 *                 stock_mode 'at_delivery' (stock leaves the shelf per delivered
 *                 ball). 'at_creation' orders were deducted when taken, so they
 *                 are not counted again.
 *  available    = products.stock - commitments (negative = shortfall)
 *  velocity     = booked units per day over the trailing 28 days (and 7 days),
 *                 non-cancelled orders, zero days included. Booked units are
 *                 used because historical delivery dates are not recorded.
 *  days of cover = available / velocity28
 *  stock-out    = today + floor(days of cover)
 *  threshold on = today + floor((available - low_stock_threshold) / velocity28)
 *
 * Stock is shared by every customer, so only the product filter applies here.
 */

import { addDaysYmd } from "@/lib/dates";
import type { Product } from "@/lib/types";
import { isOpen, isSale, productKeyOf, type Dataset } from "./dataset";
import { inRange } from "./period";

export const VELOCITY_WINDOW_DAYS = 28;
export const SHORT_WINDOW_DAYS = 7;
export const SLOW_MOVING_DAYS = 30;
export const STOCK_OUT_ALERT_DAYS = 14;

export type StockState = "shortfall" | "out" | "low" | "at_risk" | "slow" | "ok";

export type StockRow = {
  productKey: string;
  productId: string;
  name: string;
  stock: number;
  threshold: number;
  commitments: number;
  available: number;
  unitsLast7: number;
  unitsLast28: number;
  unitsLast30: number;
  velocity7: number;
  velocity28: number;
  daysOfCover: number | null;
  stockOutDate: string | null;
  thresholdDate: string | null;
  state: StockState;
};

export function stockCover(ds: Dataset, today: string, productKey: string | null = null): StockRow[] {
  const w28 = { from: addDaysYmd(today, -(VELOCITY_WINDOW_DAYS - 1)), to: today };
  const w7 = { from: addDaysYmd(today, -(SHORT_WINDOW_DAYS - 1)), to: today };
  const w30 = { from: addDaysYmd(today, -(SLOW_MOVING_DAYS - 1)), to: today };
  const acc = new Map<string, { c: number; u7: number; u28: number; u30: number }>();
  const get = (k: string) => {
    let a = acc.get(k);
    if (!a) acc.set(k, (a = { c: 0, u7: 0, u28: 0, u30: 0 }));
    return a;
  };
  for (const o of ds.orders) {
    if (!isSale(o)) continue;
    for (const l of o.lines) {
      if (!l.productId) continue;
      const a = get(l.productId);
      if (isOpen(o) && o.stockMode === "at_delivery") a.c += l.remaining;
      if (inRange(o.date, w28)) a.u28 += l.quantity;
      if (inRange(o.date, w7)) a.u7 += l.quantity;
      if (inRange(o.date, w30)) a.u30 += l.quantity;
    }
  }
  return ds.products
    .filter((p: Product) => p.isActive !== false)
    .filter((p) => productKey === null || productKeyOf(p.id, p.name) === productKey)
    .map((p) => {
      const a = acc.get(p.id) ?? { c: 0, u7: 0, u28: 0, u30: 0 };
      const stock = Number(p.stock || 0);
      const threshold = Number(p.lowStockThreshold || 0);
      const available = stock - a.c;
      const v28 = a.u28 / VELOCITY_WINDOW_DAYS;
      const v7 = a.u7 / SHORT_WINDOW_DAYS;
      let daysOfCover: number | null = null, stockOutDate: string | null = null, thresholdDate: string | null = null;
      if (available < 0 || (available === 0 && (v28 > 0 || a.c > 0))) {
        // Short now, or empty while there is demand.
        daysOfCover = 0;
        stockOutDate = today;
      } else if (available > 0 && v28 > 0) {
        daysOfCover = available / v28;
        stockOutDate = addDaysYmd(today, Math.floor(daysOfCover));
      }
      if (available <= threshold) thresholdDate = today;
      else if (v28 > 0) thresholdDate = addDaysYmd(today, Math.floor((available - threshold) / v28));
      let state: StockState;
      if (available < 0) state = "shortfall";
      else if (available === 0) state = "out";
      else if (available <= threshold) state = "low";
      else if (daysOfCover !== null && daysOfCover <= STOCK_OUT_ALERT_DAYS) state = "at_risk";
      else if (a.u30 === 0) state = "slow";
      else state = "ok";
      return {
        productKey: productKeyOf(p.id, p.name), productId: p.id, name: p.name, stock, threshold,
        commitments: a.c, available, unitsLast7: a.u7, unitsLast28: a.u28, unitsLast30: a.u30,
        velocity7: v7, velocity28: v28, daysOfCover, stockOutDate, thresholdDate, state,
      };
    })
    .sort((x, y) => (x.daysOfCover ?? Infinity) - (y.daysOfCover ?? Infinity) || x.name.localeCompare(y.name));
}

export const STOCK_STATE_LABEL: Record<StockState, string> = {
  shortfall: "Shortfall",
  out: "Out of stock",
  low: "At or below threshold",
  at_risk: `Stock-out within ${STOCK_OUT_ALERT_DAYS} days`,
  slow: `No sales in ${SLOW_MOVING_DAYS} days`,
  ok: "Healthy",
};
