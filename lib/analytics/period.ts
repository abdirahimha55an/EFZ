/**
 * Sales periods as Mogadishu (EAT) calendar dates.
 *
 * Every date here is a YYYY-MM-DD string compared as text: orders.order_date
 * and payments.payment_date are business dates already, so nothing is ever
 * parsed into the viewer's local time. Arithmetic goes through UTC on purpose
 * (addDaysYmd), which is timezone-independent for whole calendar days.
 */

import { addDaysYmd, isYmd } from "@/lib/dates";

export type PeriodPreset = "today" | "week" | "month" | "lastMonth" | "last90" | "year" | "all" | "custom";

export type DateRange = { from: string; to: string };
export type Period = DateRange & { preset: PeriodPreset; label: string };

export const PERIOD_PRESETS: { key: PeriodPreset; label: string }[] = [
  { key: "today", label: "Today" },
  { key: "week", label: "This week" },
  { key: "month", label: "This month" },
  { key: "lastMonth", label: "Last month" },
  { key: "last90", label: "Last 90 days" },
  { key: "year", label: "This year" },
  { key: "all", label: "All time" },
  { key: "custom", label: "Custom" },
];

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
export const MONTH_NAMES = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];

const ymdParts = (ymd: string) => ({ y: Number(ymd.slice(0, 4)), m: Number(ymd.slice(5, 7)), d: Number(ymd.slice(8, 10)) });
const pad = (n: number) => String(n).padStart(2, "0");
export const ymd = (y: number, m: number, d: number) => `${y}-${pad(m)}-${pad(d)}`;

/** Days in month m (1-12) of year y. */
export function daysInMonth(y: number, m: number): number {
  return new Date(Date.UTC(y, m, 0)).getUTCDate();
}

/** 0 = Monday ... 6 = Sunday. */
export function weekdayMon0(date: string): number {
  return (new Date(`${date}T00:00:00Z`).getUTCDay() + 6) % 7;
}

/** Whole days from a to b (b - a). */
export function daysBetween(a: string, b: string): number {
  return Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86_400_000);
}

export function rangeLength(range: DateRange): number {
  return daysBetween(range.from, range.to) + 1;
}

export function inRange(date: string, range: DateRange): boolean {
  return date >= range.from && date <= range.to;
}

/** Every date from..to inclusive. */
export function eachDay(range: DateRange): string[] {
  const out: string[] = [];
  for (let d = range.from; d <= range.to; d = addDaysYmd(d, 1)) out.push(d);
  return out;
}

export const monthStart = (date: string) => `${date.slice(0, 8)}01`;
export const weekStart = (date: string) => addDaysYmd(date, -weekdayMon0(date));

export function monthEnd(date: string): string {
  const { y, m } = ymdParts(date);
  return ymd(y, m, daysInMonth(y, m));
}

/** First day of the month `offset` months from the month of `date`. */
export function shiftMonth(date: string, offset: number): string {
  const { y, m } = ymdParts(date);
  const idx = y * 12 + (m - 1) + offset;
  return ymd(Math.floor(idx / 12), (idx % 12) + 1, 1);
}

/** "Oct 4, 2026" for a business date, the same for every viewer. */
export function formatYmd(date: string, withYear = true): string {
  const { y, m, d } = ymdParts(date);
  return withYear ? `${MONTHS[m - 1]} ${d}, ${y}` : `${MONTHS[m - 1]} ${d}`;
}

export function formatRange(range: DateRange): string {
  if (range.from === range.to) return formatYmd(range.from);
  const sameYear = range.from.slice(0, 4) === range.to.slice(0, 4);
  return `${formatYmd(range.from, !sameYear)} – ${formatYmd(range.to)}`;
}

/**
 * The inclusive date range of a preset. "all" runs from the first sales date
 * (or today when there is none) to today. A custom range with a bad date falls
 * back to this month.
 */
export function resolvePeriod(
  preset: PeriodPreset,
  today: string,
  options: { custom?: { from?: string; to?: string }; firstSaleDate?: string | null } = {}
): Period {
  const make = (from: string, to: string, label: string): Period => ({ preset, from, to, label });
  switch (preset) {
    case "today":
      return make(today, today, "Today");
    case "week":
      return make(weekStart(today), today, "This week");
    case "lastMonth": {
      const from = shiftMonth(today, -1);
      return make(from, monthEnd(from), "Last month");
    }
    case "last90":
      return make(addDaysYmd(today, -89), today, "Last 90 days");
    case "year":
      return make(`${today.slice(0, 4)}-01-01`, today, "This year");
    case "all": {
      const first = options.firstSaleDate && options.firstSaleDate <= today ? options.firstSaleDate : today;
      return make(first, today, "All time");
    }
    case "custom": {
      const f = options.custom?.from, t = options.custom?.to;
      if (f && t && isYmd(f) && isYmd(t)) {
        const [from, to] = f <= t ? [f, t] : [t, f];
        return make(from, to, "Custom range");
      }
      return { ...resolvePeriod("month", today), preset: "custom" };
    }
    case "month":
    default:
      return { preset: "month", from: monthStart(today), to: today, label: "This month" };
  }
}

/**
 * A fair comparison window (fixes comparing part of a month with a whole one):
 *   today -> yesterday; this week (Mon..today) -> the same weekdays last week;
 *   this month (1..d) -> last month 1..min(d, its length); last month -> the
 *   month before; this year -> the same days last year; last 90 / custom of N
 *   days -> the N days just before. All time has no comparison.
 */
export function comparisonRange(period: Period): (DateRange & { label: string }) | null {
  const n = rangeLength(period);
  switch (period.preset) {
    case "all":
      return null;
    case "today":
      return { from: addDaysYmd(period.from, -1), to: addDaysYmd(period.from, -1), label: "Yesterday" };
    case "week":
      return { from: addDaysYmd(period.from, -7), to: addDaysYmd(period.to, -7), label: "Same days last week" };
    case "month": {
      const prev = shiftMonth(period.from, -1);
      const { y, m } = ymdParts(prev);
      const day = Math.min(ymdParts(period.to).d, daysInMonth(y, m));
      return { from: prev, to: ymd(y, m, day), label: "Same days last month" };
    }
    case "lastMonth": {
      const prev = shiftMonth(period.from, -1);
      return { from: prev, to: monthEnd(prev), label: "The month before" };
    }
    case "year": {
      const { y, m, d } = ymdParts(period.to);
      const day = Math.min(d, daysInMonth(y - 1, m));
      return { from: `${y - 1}-01-01`, to: ymd(y - 1, m, day), label: "Same days last year" };
    }
    default:
      return { from: addDaysYmd(period.from, -n), to: addDaysYmd(period.from, -1), label: `Previous ${n} day${n === 1 ? "" : "s"}` };
  }
}

export type Granularity = "day" | "week" | "month";

/** Days up to 45, weeks up to 26 weeks, months beyond. */
export function autoGranularity(range: DateRange): Granularity {
  const n = rangeLength(range);
  if (n <= 45) return "day";
  if (n <= 182) return "week";
  return "month";
}

export function bucketOf(date: string, granularity: Granularity): string {
  if (granularity === "week") return weekStart(date);
  if (granularity === "month") return monthStart(date);
  return date;
}

export function bucketLabel(bucket: string, granularity: Granularity): string {
  if (granularity === "month") return `${MONTHS[Number(bucket.slice(5, 7)) - 1]} ${bucket.slice(0, 4)}`;
  if (granularity === "week") return `Wk of ${formatYmd(bucket, false)}`;
  return formatYmd(bucket, false);
}
