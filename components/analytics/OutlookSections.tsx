"use client";

import { useState } from "react";
import Link from "next/link";
import { Gauge } from "lucide-react";
import { cn } from "@/lib/utils";
import type { AnalyticsModel } from "@/lib/analytics/model";
import { STATUS_LABEL, type PipelineOrder } from "@/lib/analytics/pipeline";
import { RUN_RATE_MIN_DAYS, SUFFICIENCY_RULES } from "@/lib/analytics/outlook";
import { SHORT_WINDOW_DAYS, STOCK_OUT_ALERT_DAYS, STOCK_STATE_LABEL, VELOCITY_WINDOW_DAYS, type StockRow } from "@/lib/analytics/inventory";
import { formatYmd } from "@/lib/analytics/period";
import { BasisBadge, ChartCard, DataTable, MethodNote, SectionCard, StatTile, num, usd, type Column } from "./primitives";
import { PipelineStatusChart, StockCoverChart, WeeklyVelocityChart } from "./lazyCharts";
import { ordersLink } from "./SalesSections";

const LEVEL_STYLE: Record<string, string> = {
  none: "bg-slate-100 text-slate-700 border-slate-200",
  limited: "bg-amber-50 text-amber-900 border-amber-200",
  developing: "bg-sky-50 text-sky-900 border-sky-200",
  established: "bg-emerald-50 text-emerald-900 border-emerald-200",
};

export function PipelineOutlookSection({ m }: { m: AnalyticsModel }) {
  const [metric, setMetric] = useState<"revenue" | "units">("revenue");
  const p = m.pipeline, r = m.runRate, s = m.sufficiency, v = m.velocity;
  const cols: Column<PipelineOrder>[] = [
    { key: "id", header: "Order", primary: true, render: (o) => <Link href={ordersLink(o.orderId)} className="font-semibold text-brand-blue hover:underline">{o.orderId}</Link> },
    { key: "d", header: "Ordered", align: "right", render: (o) => formatYmd(o.date) },
    { key: "a", header: "Age", align: "right", render: (o) => `${o.ageDays}d` },
    { key: "c", header: "Customer", render: (o) => o.customerName },
    { key: "s", header: "Status", render: (o) => STATUS_LABEL[o.status] },
    { key: "u", header: "Balls to deliver", align: "right", render: (o) => num(o.remainingUnits) },
    { key: "v", header: "Value to deliver", align: "right", render: (o) => usd(o.remainingCents) },
  ];
  return (
    <SectionCard id="pipeline" title="Pipeline & sales outlook" subtitle="What is committed but not yet delivered, the current pace, and what that pace would mean for the month. Shown as of today; the period selector does not apply.">
      {/* Data sufficiency first: it frames every number below. */}
      <div className={cn("mb-4 rounded-xl border p-3 text-xs", LEVEL_STYLE[s.level])} data-testid="sufficiency" data-level={s.level}>
        <div className="flex flex-wrap items-center gap-2">
          <Gauge className="h-4 w-4" />
          <strong className="text-sm">{s.label}</strong>
          <span>{s.historyDays} days of history · {s.orders} orders · {s.completeMonths} complete month{s.completeMonths === 1 ? "" : "s"}</span>
        </div>
        <p className="mt-1">{s.explanation}</p>
        {s.next && <p className="mt-0.5 opacity-80">{s.next}</p>}
        <p className="mt-1 text-[10px] opacity-70">An operational indicator of how much sales history exists — not a measure of statistical reliability.</p>
      </div>

      <div className="mb-4 grid grid-cols-2 gap-2.5 lg:grid-cols-4">
        <StatTile label="Open orders" basis="committed" value={num(p.totalOrders)} raw={p.totalOrders} testId="pipe-orders" hint={p.oldest ? `Oldest: ${p.oldest.ageDays} days` : "Nothing waiting"} />
        <StatTile label="Balls to deliver" basis="committed" value={num(p.remainingUnits)} raw={p.remainingUnits} testId="pipe-units" />
        <StatTile label="Value to deliver" basis="committed" value={usd(p.remainingCents)} raw={p.remainingCents} testId="pipe-value" />
        <StatTile label="Booked per day (28 days)" basis="actual" value={usd(Math.round(v.last28.revenuePerDayCents))} testId="velocity-28" hint={`${num(v.last28.unitsPerDay, 2)} balls/day · last ${SHORT_WINDOW_DAYS} days: ${num(v.last7.unitsPerDay, 2)}/day`} />
      </div>

      <div className="grid gap-4 lg:grid-cols-3">
        <ChartCard title="Still to deliver, by status" basis={["committed"]} testId="chart-pipeline"
          chart={p.totalOrders ? <PipelineStatusChart rows={p.byStatus} metric={metric} /> : <div className="flex h-40 items-center justify-center text-xs text-slate-400">No open orders.</div>}
          table={<DataTable rows={p.byStatus} rowKey={(x) => x.status} columns={[
            { key: "s", header: "Status", primary: true, render: (x) => STATUS_LABEL[x.status] },
            { key: "o", header: "Orders", align: "right", render: (x) => num(x.orders) },
            { key: "u", header: "Balls", align: "right", render: (x) => num(x.remainingUnits) },
            { key: "v", header: "Value", align: "right", render: (x) => usd(x.remainingCents) },
          ]} />}
          note={<div className="flex gap-1">
            {(["revenue", "units"] as const).map((k) => <button key={k} type="button" onClick={() => setMetric(k)} className={cn("rounded-md px-2 py-0.5 text-[10px] font-bold", metric === k ? "bg-slate-900 text-white" : "bg-slate-100 text-slate-600")}>{k === "revenue" ? "Value" : "Balls"}</button>)}
          </div>} />

        <ChartCard title="Weekly sales pace" basis={["actual"]} testId="chart-weekly" subtitle="Booked balls per week (Mon–Sun); the current week is so far."
          chart={<WeeklyVelocityChart data={v.weekly} />}
          table={<DataTable rows={v.weekly} rowKey={(w) => w.bucket} columns={[
            { key: "w", header: "Week", primary: true, render: (w) => `${w.label}${w.partial ? " (so far)" : ""}` },
            { key: "u", header: "Balls", align: "right", render: (w) => num(w.bookedUnits) },
            { key: "b", header: "Booked", align: "right", render: (w) => usd(w.bookedCents) },
          ]} />} />

        <div className="flex flex-col rounded-xl border border-dashed border-amber-300 bg-amber-50/40 p-3 sm:p-4" data-testid="run-rate" data-available={r.available ? "yes" : "no"}>
          <div className="mb-2 flex items-center gap-1.5">
            <h3 className="text-sm font-bold text-slate-800">Month-end run rate</h3>
            <BasisBadge basis="indicative" />
          </div>
          <p className="text-[11px] text-slate-600">Booked this month so far <BasisBadge basis="actual" /></p>
          <p className="text-xl font-extrabold tabular-nums text-slate-900" data-testid="run-rate-mtd" data-value={r.monthToDateCents}>{usd(r.monthToDateCents)}</p>
          <p className="text-[11px] text-slate-500">Day {r.daysElapsed} of {r.daysInMonth}</p>
          {r.available ? (
            <>
              <p className="mt-3 text-[11px] text-slate-600">If the current pace continues, the month could end at</p>
              <p className="text-xl font-extrabold tabular-nums text-amber-900" data-testid="run-rate-range" data-low={r.lowCents} data-high={r.highCents}>{usd(r.lowCents)} – {usd(r.highCents)}</p>
              <p className="text-[11px] text-slate-500">Delivered so far: {usd(r.deliveredToDateCents)}</p>
            </>
          ) : (
            <p className="mt-3 text-[11px] text-slate-600" data-testid="run-rate-unavailable">{r.reason}</p>
          )}
          <div className="mt-auto pt-2">
            <MethodNote>
              <p>R = booked revenue this month to date, d = days elapsed (today included), D = days in the month.</p>
              <p>Month-to-date pace: R + (R ÷ d) × (D − d). 28-day pace: R + (booked revenue of the last 28 days ÷ 28) × (D − d). The range runs from the lower to the higher of the two.</p>
              <p>Shown from day {RUN_RATE_MIN_DAYS}. It assumes the recent pace simply continues: no seasonality, no trend model and no confidence interval. Page filters apply; the period selector does not.</p>
            </MethodNote>
          </div>
        </div>
      </div>

      <div className="mt-4">
        <p className="mb-1.5 text-xs font-bold text-slate-800">Open orders <span className="font-normal text-slate-500">(oldest first; click to open the order)</span></p>
        <DataTable rows={p.orders} rowKey={(o) => o.orderId} columns={cols} maxRows={10} testId="pipeline-table" empty="No open orders." />
      </div>
      <div className="mt-2"><MethodNote>
        <p>Open = pending, confirmed, processing or partially delivered. Balls and value to deliver use the remaining quantity on each line × its actual unit price. Thresholds for “Developing” history: {SUFFICIENCY_RULES.developing.historyDays} days, {SUFFICIENCY_RULES.developing.orders} orders and {SUFFICIENCY_RULES.developing.completeMonths} complete months; “Established”: {SUFFICIENCY_RULES.established.completeMonths} complete months and {SUFFICIENCY_RULES.established.orders} orders.</p>
      </MethodNote></div>
    </SectionCard>
  );
}

export function InventorySection({ m }: { m: AnalyticsModel }) {
  const cols: Column<StockRow>[] = [
    { key: "n", header: "Product", primary: true, render: (s) => s.name },
    { key: "s", header: "On hand", align: "right", render: (s) => num(s.stock) },
    { key: "c", header: "Committed", align: "right", render: (s) => num(s.commitments) },
    { key: "a", header: "Available", align: "right", render: (s) => <span className={cn(s.available < 0 && "font-bold text-rose-700")}>{num(s.available)}</span> },
    { key: "t", header: "Threshold", align: "right", render: (s) => num(s.threshold) },
    { key: "v", header: "Per day (28d)", align: "right", render: (s) => num(s.velocity28, 2) },
    { key: "d", header: "Days of cover", align: "right", render: (s) => (s.daysOfCover === null ? "No recent demand" : num(Math.floor(s.daysOfCover))) },
    { key: "o", header: "Stock-out", align: "right", render: (s) => (s.stockOutDate ? formatYmd(s.stockOutDate) : "—") },
    { key: "st", header: "State", render: (s) => <span className={cn("rounded px-1.5 py-0.5 text-[10px] font-bold", s.state === "ok" ? "bg-emerald-50 text-emerald-800" : s.state === "slow" ? "bg-slate-100 text-slate-600" : s.state === "shortfall" || s.state === "out" ? "bg-rose-100 text-rose-800" : "bg-amber-100 text-amber-900")}>{STOCK_STATE_LABEL[s.state]}</span> },
  ];
  return (
    <SectionCard id="inventory" title="Sales-driven stock cover" subtitle="How long current stock lasts at the recent sales pace. For stock levels and adjustments use Inventory." actions={<BasisBadge basis="indicative" />}>
      <div className="grid gap-4 lg:grid-cols-2">
        <ChartCard title="Days of cover" basis={["indicative"]} testId="chart-stock" subtitle={`Dashed line: ${STOCK_OUT_ALERT_DAYS} days. Bars are capped at 90 days.`}
          chart={m.stock.length ? <StockCoverChart rows={m.stock} /> : <div className="flex h-40 items-center justify-center text-xs text-slate-400">No active products.</div>}
          table={<DataTable rows={m.stock} rowKey={(s) => s.productKey} columns={[cols[0], cols[3], cols[5], cols[6], cols[7]]} />} />
        <div className="min-w-0 space-y-2">
          <DataTable rows={m.stock} rowKey={(s) => s.productKey} columns={cols} testId="stock-table" empty="No active products." />
          <MethodNote>
            <p>Committed = balls still to deliver on open orders taken under per-delivery stock (orders taken before that change were deducted when entered, so they are not counted again). Available = on hand − committed.</p>
            <p>Pace = booked balls per day over the last {VELOCITY_WINDOW_DAYS} days (all customers; only the product filter applies). Days of cover = available ÷ pace; stock-out = today + days of cover. Booked balls are used because delivery dates are not recorded for older deliveries.</p>
            <p>With a short sales history one large order can move these dates a lot. They are indicative, not a forecast.</p>
          </MethodNote>
        </div>
      </div>
    </SectionCard>
  );
}
