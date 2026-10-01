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
