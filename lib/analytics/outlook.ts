/**
 * Sales outlook: velocity, the indicative month-end run rate, data sufficiency
 * and the attention list.
 *
 * EFZ has a short sales history, so nothing here is a statistical forecast:
 *  - run rate   = arithmetic on the current pace (INDICATIVE), shown as a range
 *  - sufficiency = an OPERATIONAL indicator of how much history exists. It is
 *                  not a measure of statistical reliability or confidence.
 */

import { addDaysYmd } from "@/lib/dates";
import { isSale, select, type Dataset, type SalesFilters } from "./dataset";
import { daysBetween, daysInMonth, formatYmd, monthStart, shiftMonth, weekStart } from "./period";
import { totalsOf, trailing } from "./sales";

// ---------------------------------------------------------------------------
// Data sufficiency
// ---------------------------------------------------------------------------

export type SufficiencyLevel = "none" | "limited" | "developing" | "established";

export const SUFFICIENCY_RULES = {
  developing: { historyDays: 60, orders: 30, completeMonths: 2 },
  established: { completeMonths: 6, orders: 150 },
} as const;

export type Sufficiency = {
  level: SufficiencyLevel;
  label: string;
  historyDays: number;
  orders: number;
  completeMonths: number;
  firstSaleDate: string | null;
  /** What the level allows, and what is still missing for the next one. */
  explanation: string;
  next: string | null;
};

/**
 * Complete months = calendar months that have fully ended, began on or after
 * the first sale date's month start AND after history began (the first sale on
 * or before the 1st), and contain at least one sale.
 */
export function dataSufficiency(ds: Dataset, today: string): Sufficiency {
  const sales = ds.orders.filter(isSale);
  const first = ds.firstSaleDate;
  if (!first || sales.length === 0) {
    return { level: "none", label: "No sales history", historyDays: 0, orders: 0, completeMonths: 0, firstSaleDate: null, explanation: "There are no sales yet, so there is nothing to project.", next: null };
  }
  const historyDays = daysBetween(first, today) + 1;
  const thisMonth = monthStart(today);
  const monthsWithSales = new Set(sales.map((o) => monthStart(o.date)));
  let completeMonths = 0;
  for (let m = monthStart(first); m < thisMonth; m = shiftMonth(m, 1)) {
    if (m >= first && monthsWithSales.has(m)) completeMonths += 1;
  }
  const orders = sales.length;
  const d = SUFFICIENCY_RULES.developing, e = SUFFICIENCY_RULES.established;
  const missing = (pairs: [number, number, string][]) => pairs.filter(([v, need]) => v < need).map(([v, need, what]) => `${what} ${v} of ${need}`).join(", ");
  if (completeMonths >= e.completeMonths && orders >= e.orders) {
    return { level: "established", label: "Established history", historyDays, orders, completeMonths, firstSaleDate: first,
      explanation: "Enough history for longer trend analysis. Statistical models are not part of this version; projections remain simple run-rate arithmetic.", next: null };
  }
  if (historyDays >= d.historyDays && orders >= d.orders && completeMonths >= d.completeMonths) {
    return { level: "developing", label: "Developing history", historyDays, orders, completeMonths, firstSaleDate: first,
      explanation: "Month-over-month comparisons are meaningful. Projections are still indicative run-rate arithmetic.",
      next: `For "Established": ${missing([[completeMonths, e.completeMonths, "complete months"], [orders, e.orders, "orders"]])}.` };
  }
  return { level: "limited", label: "Limited history", historyDays, orders, completeMonths, firstSaleDate: first,
    explanation: "Only actual, booked and committed figures are firm. Run-rate and stock-cover figures are indicative and can swing with a single order.",
    next: `For "Developing": ${missing([[historyDays, d.historyDays, "days of history"], [orders, d.orders, "orders"], [completeMonths, d.completeMonths, "complete months"]])}.` };
}

// ---------------------------------------------------------------------------
// Velocity
// ---------------------------------------------------------------------------

export type WeeklyPoint = { bucket: string; label: string; bookedUnits: number; bookedCents: number; partial: boolean };

/** The last `weeks` Monday-start weeks, the current (partial) week included. */
export function weeklyVelocity(ds: Dataset, f: SalesFilters, today: string, weeks = 8): WeeklyPoint[] {
  const thisWeek = weekStart(today);
  const out: WeeklyPoint[] = [];
  for (let i = weeks - 1; i >= 0; i--) {
    const from = addDaysYmd(thisWeek, -7 * i);
    const to = i === 0 ? today : addDaysYmd(from, 6);
    const t = totalsOf(select(ds, f, { from, to }));
    out.push({ bucket: from, label: `Wk of ${formatYmd(from, false)}`, bookedUnits: t.bookedUnits, bookedCents: t.bookedCents, partial: i === 0 });
  }
  return out;
}

export type Velocity = {
  last7: ReturnType<typeof trailing>;
  last28: ReturnType<typeof trailing>;
  weekly: WeeklyPoint[];
};

export function velocity(ds: Dataset, f: SalesFilters, today: string): Velocity {
  return { last7: trailing(ds, f, today, 7), last28: trailing(ds, f, today, 28), weekly: weeklyVelocity(ds, f, today) };
}

// ---------------------------------------------------------------------------
// Month-end run rate (INDICATIVE)
// ---------------------------------------------------------------------------

export const RUN_RATE_MIN_DAYS = 7;

export type RunRate =
  | { available: false; reason: string; monthToDateCents: number; daysElapsed: number; daysInMonth: number }
  | {
      available: true;
      monthToDateCents: number;
      deliveredToDateCents: number;
      daysElapsed: number;
      daysInMonth: number;
      paceProjectionCents: number;
      trailingProjectionCents: number;
      lowCents: number;
      highCents: number;
      /** Daily pace used for the cumulative chart's indicative path. */
      paceDailyCents: number;
    };

/**
 *   R = month-to-date booked revenue, d = days elapsed (today included), D = days in month
 *   pace projection     = R + (R / d) x (D - d)
 *   trailing projection = R + (28-day booked revenue / 28) x (D - d)
 *   range               = lower .. higher of the two
 * Not shown before day 7, or when nothing has been booked this month.
 */
export function runRate(ds: Dataset, f: SalesFilters, today: string): RunRate {
  const y = Number(today.slice(0, 4)), m = Number(today.slice(5, 7));
  const D = daysInMonth(y, m);
  const d = Number(today.slice(8, 10));
  const mtd = totalsOf(select(ds, f, { from: monthStart(today), to: today }));
  const R = mtd.bookedCents;
  if (d < RUN_RATE_MIN_DAYS) {
    return { available: false, reason: `Too early in the month: a projection is shown from day ${RUN_RATE_MIN_DAYS}.`, monthToDateCents: R, daysElapsed: d, daysInMonth: D };
  }
  if (R <= 0) {
    return { available: false, reason: "Nothing has been booked this month, so there is no pace to extend.", monthToDateCents: R, daysElapsed: d, daysInMonth: D };
  }
  const pace = R + (R / d) * (D - d);
  const t28 = trailing(ds, f, today, 28);
  const trail = R + t28.revenuePerDayCents * (D - d);
  return {
    available: true,
    monthToDateCents: R,
    deliveredToDateCents: mtd.deliveredCents,
    daysElapsed: d,
    daysInMonth: D,
    paceProjectionCents: Math.round(pace),
    trailingProjectionCents: Math.round(trail),
    lowCents: Math.round(Math.min(pace, trail)),
    highCents: Math.round(Math.max(pace, trail)),
    paceDailyCents: R / d,
  };
}
