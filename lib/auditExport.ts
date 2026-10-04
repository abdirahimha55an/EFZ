/**
 * Audit Trail -> Excel. Pure: turns the audit lines the user is allowed to read
 * (already filtered by the database) into a one-sheet .xlsx file.
 *
 * Only fields the Audit Trail itself shows are exported. Times are Mogadishu
 * time (EAT, UTC+3), the business timezone used everywhere else in EFZ, as real
 * Excel date/time values.
 */
import type { SystemLog } from "@/lib/types";
import { buildXlsx, excelSerialFromWallClockMs, type XlsxCell, type XlsxColumn } from "@/lib/xlsx";
import { efzToday, efzWallClockMs } from "@/lib/dates";

export const AUDIT_SOURCE_LABEL: Record<"database" | "client" | "unknown", string> = {
  database: "Database",
  client: "Browser",
  unknown: "Unverified",
};

/** The details recorded with an audit line, as readable JSON ("" when there are none). */
export function auditDetailsText(log: Pick<SystemLog, "metadata">): string {
  const meta = log.metadata ?? {};
  return Object.keys(meta).length === 0 ? "" : JSON.stringify(meta, null, 2);
}

export const AUDIT_EXPORT_COLUMNS: XlsxColumn[] = [
  { header: "Date (EAT)", width: 12 },
  { header: "Time (EAT)", width: 10 },
  { header: "Date & Time (EAT)", width: 20 },
  { header: "Severity", width: 11 },
  { header: "Category", width: 12 },
  { header: "Action / Description", width: 70, wrap: true },
  { header: "User", width: 22 },
  { header: "User ID", width: 26 },
  { header: "Target ID", width: 26 },
  { header: "Source", width: 12 },
  { header: "Details", width: 70, wrap: true },
];

const text = (value: string | undefined | null): XlsxCell => (value ? { kind: "text", value } : { kind: "empty" });

export function auditExportRow(log: SystemLog): XlsxCell[] {
  const serial = excelSerialFromWallClockMs(efzWallClockMs(log.timestamp));
  const day = Math.floor(serial);
  return [
    { kind: "date", serial: day, format: "date" },
    { kind: "date", serial: serial - day, format: "time" },
    { kind: "date", serial, format: "datetime" },
    text(log.severity),
    text(log.category),
    text(log.message),
    text(log.username),
    text(log.userId),
    text(log.targetId),
    text(AUDIT_SOURCE_LABEL[log.origin ?? "unknown"]),
    text(auditDetailsText(log)),
  ];
}

/** audit-trail-2026-10-04.xlsx, or audit-trail-2026-09-01-to-2026-09-30.xlsx for a date range. */
export function auditExportFileName(range: { from: string; to: string } | null, now: Date = new Date()): string {
  if (!range) return `audit-trail-${efzToday(now)}.xlsx`;
  return range.from === range.to ? `audit-trail-${range.from}.xlsx` : `audit-trail-${range.from}-to-${range.to}.xlsx`;
}

export function buildAuditWorkbook(logs: SystemLog[]): Uint8Array {
  return buildXlsx("Audit Trail", AUDIT_EXPORT_COLUMNS, logs.map(auditExportRow));
}
