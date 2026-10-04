/**
 * The Sales & Analytics Excel export: exactly the model on screen, as sheets.
 * The page records the export in the audit trail BEFORE handing over the file
 * (the Phase 12 rule): an export that cannot be recorded does not happen.
 */

import { buildXlsxWorkbook, type XlsxCell, type XlsxColumn, type XlsxSheet } from "@/lib/xlsx";
import { fromCents, type SalesFilters } from "./dataset";
import { STOCK_STATE_LABEL } from "./inventory";
import type { AnalyticsModel } from "./model";
import { STATUS_LABEL } from "./pipeline";

const t = (value: string | null | undefined): XlsxCell => ({ kind: "text", value: value ?? "" });
const n = (value: number | null | undefined): XlsxCell => (value === null || value === undefined || !Number.isFinite(value) ? { kind: "empty" } : { kind: "number", value });
const usd = (cents: number | null | undefined): XlsxCell => (cents === null || cents === undefined ? { kind: "empty" } : { kind: "number", value: fromCents(cents) });
const p1 = (v: number | null) => (v === null ? { kind: "empty" as const } : { kind: "number" as const, value: Math.round(v * 10) / 10 });
const col = (header: string, width: number, wrap = false): XlsxColumn => ({ header, width, wrap });

export function analyticsExportFileName(m: AnalyticsModel): string {
  return m.period.from === m.period.to
    ? `sales-analytics-${m.period.from}.xlsx`
    : `sales-analytics-${m.period.from}-to-${m.period.to}.xlsx`;
}

export type FilterLabels = { product: string; customer: string; officer: string; orderType: string; status: string };

/** What the audit line records: the period, the filters (ids and labels) and the rows exported. */
export function analyticsExportMetadata(m: AnalyticsModel, fileName: string, labels: FilterLabels, sheets: XlsxSheet[]) {
  return {
    fileName,
    period: { preset: m.period.preset, from: m.period.from, to: m.period.to },
    comparison: m.comparison ? { from: m.comparison.from, to: m.comparison.to } : null,
    filter: filterForAudit(m.filters, labels),
    rows: Object.fromEntries(sheets.map((s) => [s.name, s.rows.length])),
  };
}

function filterForAudit(f: SalesFilters, labels: FilterLabels) {
  const out: Record<string, string> = {};
  if (f.productKey) out.product = `${labels.product} (${f.productKey})`;
  if (f.customerId) out.customer = `${labels.customer} (${f.customerId})`;
  if (f.officerId) out.officer = `${labels.officer} (${f.officerId})`;
  if (f.orderType !== "all") out.orderType = f.orderType;
  if (f.status !== "all") out.status = f.status;
  return out;
}

export function buildAnalyticsSheets(m: AnalyticsModel, labels: FilterLabels, options: { includeOfficers: boolean; generatedAt: string }): XlsxSheet[] {
  const k = m.kpis, c = m.comparisonKpis;
  const kpi = (name: string, value: XlsxCell, prev: XlsxCell, basis: string, definition: string): XlsxCell[] => [t("KPI"), t(name), value, prev, t(basis), t(definition)];
  const summary: XlsxCell[][] = [
    [t("Report"), t("Sales & Analytics"), { kind: "empty" }, { kind: "empty" }, t(""), t(`Generated ${options.generatedAt} (Mogadishu time)`)],
    [t("Period"), t(`${m.period.label}: ${m.periodText}`), t(m.period.from), t(m.period.to), t(""), t("Sales are dated by order date (EAT business date). Cancelled orders are excluded everywhere.")],
    [t("Comparison"), t(m.comparison ? `${m.comparison.label}: ${m.comparison.text}` : "None"), t(m.comparison?.from ?? ""), t(m.comparison?.to ?? ""), t(""), t("")],
    [t("Filter"), t(`Product: ${labels.product} · Customer: ${labels.customer} · Officer: ${labels.officer} · Order type: ${labels.orderType} · Status: ${labels.status}`), { kind: "empty" }, { kind: "empty" }, t(""), t("Product filters apply per order line.")],
    kpi("Delivered revenue", usd(k.deliveredCents), usd(c?.deliveredCents), "Actual", "Sum of delivered quantity x actual unit price."),
    kpi("Booked revenue", usd(k.bookedCents), usd(c?.bookedCents), "Booked", "Sum of ordered quantity x actual unit price (pending, confirmed, processing, partially delivered and delivered orders)."),
    kpi("Still to deliver", usd(k.undeliveredCents), usd(c?.undeliveredCents), "Committed", "Booked minus delivered."),
    kpi("Orders", n(k.orders), n(c?.orders), "Booked", "Non-cancelled orders dated in the period."),
    kpi("Fully delivered orders", n(k.fullyDeliveredOrders), n(c?.fullyDeliveredOrders), "Actual", "Orders with status delivered."),
    kpi("Delivered units", n(k.deliveredUnits), n(c?.deliveredUnits), "Actual", "Balls delivered."),
    kpi("Booked units", n(k.bookedUnits), n(c?.bookedUnits), "Booked", "Balls ordered."),
    kpi("Average order value", usd(k.aovCents), usd(c?.aovCents ?? null), "Booked", "Booked revenue / orders."),
    kpi("Buying customers", n(k.buyingCustomers), n(c?.buyingCustomers), "Actual", "Distinct customer records with an order in the period."),
    kpi("Cash received", usd(k.cashReceivedCents), usd(c?.cashReceivedCents ?? null), "Actual", "Payments dated (payment date) in the period; not available with a product filter."),
  ];
  const sheets: XlsxSheet[] = [
    {
      name: "Summary",
      columns: [col("Section", 12), col("Item", 44, true), col("Value", 14), col("Comparison", 14), col("Basis", 11), col("Definition", 70, true)],
      rows: summary,
    },
    {
      name: "Products",
      columns: [col("Product", 32), col("Booked units", 12), col("Delivered units", 14), col("Booked revenue", 15), col("Delivered revenue", 16), col("Share %", 9), col("Avg price", 11), col("Avg list price", 13), col("Realisation %", 13), col("Below list", 12), col("Orders", 8), col("Customers", 10), col("Last sale", 12)],
      rows: m.products.map((p) => [t(p.name), n(p.bookedUnits), n(p.deliveredUnits), usd(p.bookedCents), usd(p.deliveredCents), p1(p.sharePct), usd(p.avgPriceCents), usd(p.avgListPriceCents), p1(p.realizationPct), usd(p.discountCents), n(p.orders), n(p.customers), t(p.lastSaleDate)]),
    },
    {
      name: "Customers",
      columns: [col("Customer", 30), col("Customer ID", 22), col("Orders", 8), col("Booked units", 12), col("Booked revenue", 15), col("Delivered revenue", 16), col("Share %", 9), col("First order", 12), col("New in period", 13), col("Avg days between orders", 22)],
      rows: m.customers.map((r) => [t(r.name), t(r.customerId ?? ""), n(r.orders), n(r.bookedUnits), usd(r.bookedCents), usd(r.deliveredCents), p1(r.sharePct), t(r.firstOrderDate), t(r.isNew ? "Yes" : "No"), p1(r.avgDaysBetweenOrders)]),
    },
  ];
  if (options.includeOfficers) {
    sheets.push({
      name: "Marketing Officers",
      columns: [col("Marketing Officer", 28), col("Orders", 8), col("Booked revenue", 15), col("Delivered revenue", 16), col("Booked units", 12), col("Delivered units", 14), col("Customers", 10)],
      rows: m.officers.map((o) => [t(o.name), n(o.orders), usd(o.bookedCents), usd(o.deliveredCents), n(o.bookedUnits), n(o.deliveredUnits), n(o.customers)]),
    });
  }
  sheets.push(
    {
      name: "Open orders",
      columns: [col("Order", 16), col("Order date", 12), col("Age (days)", 10), col("Customer", 28), col("Marketing Officer", 22), col("Status", 18), col("Balls to deliver", 15), col("Value to deliver", 15), col("Booked value", 13)],
      rows: m.pipeline.orders.map((o) => [t(o.orderId), t(o.date), n(o.ageDays), t(o.customerName), t(o.officerName), t(STATUS_LABEL[o.status]), n(o.remainingUnits), usd(o.remainingCents), usd(o.bookedCents)]),
    },
    {
      name: "Stock cover",
      columns: [col("Product", 32), col("On hand", 9), col("Committed", 10), col("Available", 10), col("Threshold", 10), col("Units 7 days", 12), col("Units 28 days", 13), col("Per day (28d)", 13), col("Days of cover", 13), col("Indicative stock-out", 18), col("State", 26)],
      rows: m.stock.map((s) => [t(s.name), n(s.stock), n(s.commitments), n(s.available), n(s.threshold), n(s.unitsLast7), n(s.unitsLast28), { kind: "number", value: Math.round(s.velocity28 * 100) / 100 }, s.daysOfCover === null ? t("No recent demand") : n(Math.floor(s.daysOfCover)), t(s.stockOutDate), t(STOCK_STATE_LABEL[s.state])]),
    },
    {
      name: "Trend",
      columns: [col(m.granularity === "day" ? "Date" : m.granularity === "week" ? "Week starting" : "Month", 14), col("Orders", 8), col("Booked revenue", 15), col("Delivered revenue", 16), col("Booked units", 12), col("Delivered units", 14)],
      rows: m.series.map((s) => [t(s.bucket), n(s.orders), usd(s.bookedCents), usd(s.deliveredCents), n(s.bookedUnits), n(s.deliveredUnits)]),
    },
  );
  return sheets;
}

export function buildAnalyticsWorkbook(sheets: XlsxSheet[]): Uint8Array {
  return buildXlsxWorkbook(sheets);
}
