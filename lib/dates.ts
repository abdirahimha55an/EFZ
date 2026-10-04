/**
 * EFZ business dates are Mogadishu calendar dates (UTC+3, no daylight saving),
 * the same as public.efz_today() in supabase/10_rpc_hardening.sql.
 *
 * `new Date().toISOString().slice(0, 10)` is the UTC date: between 00:00 and
 * 03:00 in Mogadishu it is still yesterday, and the database would reject it
 * as a backdated order or payment for anyone but a Super Admin.
 */

export const EFZ_TIME_ZONE = "Africa/Mogadishu";

const efzDateTime = new Intl.DateTimeFormat("en-US", {
  timeZone: EFZ_TIME_ZONE,
  month: "short",
  day: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
});

const efzTime = new Intl.DateTimeFormat("en-US", {
  timeZone: EFZ_TIME_ZONE,
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});

/**
 * A stored timestamp (UTC) shown in Mogadishu time whatever the viewer's
 * clock is set to, e.g. "Oct 1, 06:35:37 EAT".
 */
export function formatEfzDateTime(value: string | Date): string {
  return `${efzDateTime.format(new Date(value))} EAT`;
}

/** Hours and minutes in Mogadishu time, e.g. "06:35 EAT". */
export function formatEfzTime(value: string | Date): string {
  return `${efzTime.format(new Date(value))} EAT`;
}

/** Today's date in Mogadishu as YYYY-MM-DD. */
export function efzToday(now: Date = new Date()): string {
  // en-CA formats as YYYY-MM-DD.
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: EFZ_TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(now);
}

/**
 * Mogadishu is UTC+3 all year (no daylight saving), so a Mogadishu calendar day
 * D runs from D 00:00+03:00 up to (not including) D+1 00:00+03:00.
 */
export const EFZ_UTC_OFFSET = "+03:00";
const EFZ_OFFSET_MS = 3 * 60 * 60 * 1000;

/** True for a real calendar date written as YYYY-MM-DD. */
export function isYmd(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const d = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === value;
}

/** YYYY-MM-DD plus `days` (calendar arithmetic, independent of the viewer's timezone). */
export function addDaysYmd(ymd: string, days: number): string {
  const d = new Date(`${ymd}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

/** The instant a Mogadishu calendar day begins, as an ISO timestamp with offset. */
export function efzDayStartIso(ymd: string): string {
  return `${ymd}T00:00:00${EFZ_UTC_OFFSET}`;
}

export type EfzDatePreset = "all" | "today" | "yesterday" | "last7" | "last30" | "date" | "custom";

/**
 * Inclusive Mogadishu calendar range for a preset (from / to as YYYY-MM-DD),
 * or null for "all time". "last7" is today and the six days before it.
 */
export function efzDateRange(
  preset: EfzDatePreset,
  custom: { from?: string; to?: string } = {},
  now: Date = new Date()
): { from: string; to: string } | null {
  const today = efzToday(now);
  switch (preset) {
    case "today": return { from: today, to: today };
    case "yesterday": { const y = addDaysYmd(today, -1); return { from: y, to: y }; }
    case "last7": return { from: addDaysYmd(today, -6), to: today };
    case "last30": return { from: addDaysYmd(today, -29), to: today };
    case "date": return custom.from && isYmd(custom.from) ? { from: custom.from, to: custom.from } : null;
    case "custom": {
      const from = custom.from && isYmd(custom.from) ? custom.from : undefined;
      const to = custom.to && isYmd(custom.to) ? custom.to : undefined;
      if (!from && !to) return null;
      const f = from ?? to!, t = to ?? from!;
      return f <= t ? { from: f, to: t } : { from: t, to: f };
    }
    default: return null;
  }
}

/** Query bounds for an inclusive Mogadishu date range: occurred_at >= gte and < lt. */
export function efzRangeBounds(range: { from: string; to: string }): { gte: string; lt: string } {
  return { gte: efzDayStartIso(range.from), lt: efzDayStartIso(addDaysYmd(range.to, 1)) };
}

/** A stored timestamp as Mogadishu wall-clock milliseconds (for Excel date cells). */
export function efzWallClockMs(value: string | Date): number {
  return new Date(value).getTime() + EFZ_OFFSET_MS;
}
