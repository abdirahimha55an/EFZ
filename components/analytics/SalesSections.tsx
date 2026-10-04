"use client";

import { useState } from "react";
import Link from "next/link";
import { AlertTriangle } from "lucide-react";
import { cn } from "@/lib/utils";
import type { AnalyticsModel } from "@/lib/analytics/model";
import { ATTENTION_RULES } from "@/lib/analytics/model";
import type { ProductRow } from "@/lib/analytics/products";
import type { CustomerRow } from "@/lib/analytics/customers";
import type { OfficerRow } from "@/lib/analytics/officers";
import { formatYmd } from "@/lib/analytics/period";
import { ChartCard, DataTable, MethodNote, SectionCard, StatTile, num, pct, usd, type Column } from "./primitives";
import { CumulativeChart, NewReturningChart, OfficerChart, ParetoChart, PriceRealizationChart, ProductMixChart, SalesTrendChart } from "./lazyCharts";

function Toggle<T extends string>({ value, options, onChange, testId }: { value: T; options: [T, string][]; onChange: (v: T) => void; testId?: string }) {
  return (
    <div className="inline-flex rounded-lg border border-slate-200 p-0.5" data-testid={testId}>
      {options.map(([v, l]) => (
        <button key={v} type="button" onClick={() => onChange(v)} className={cn("rounded-md px-2 py-0.5 text-[11px] font-bold", value === v ? "bg-slate-900 text-white" : "text-slate-600 hover:bg-slate-100")}>{l}</button>
      ))}
    </div>
  );
}

export const ordersLink = (search: string) => `/admin/orders?search=${encodeURIComponent(search)}`;

// ---------------------------------------------------------------------------
// Attention
// ---------------------------------------------------------------------------

export function AttentionPanel({ m }: { m: AnalyticsModel }) {
  if (m.attention.length === 0) return null;
  return (
    <section className="rounded-2xl border border-amber-200 bg-amber-50/60 p-4" data-testid="attention-panel">
      <div className="mb-2 flex items-center gap-2">
        <AlertTriangle className="h-4 w-4 text-amber-600" />
        <h2 className="text-sm font-bold text-amber-950">Needs attention</h2>
      </div>
      <ul className="grid gap-2 md:grid-cols-2">
        {m.attention.map((a) => (
          <li key={a.id} data-testid={`attention-${a.id}`}>
            <a href={`#${a.section}`} className="flex items-start gap-2 rounded-lg bg-white/80 p-2.5 text-xs hover:bg-white">
              <span className={cn("mt-1 h-2 w-2 shrink-0 rounded-full", a.severity === "high" ? "bg-rose-600" : "bg-amber-500")} />
              <span className="min-w-0">
                <span className="block font-bold text-slate-900">{a.title}</span>
                <span className="block text-slate-600">{a.detail}</span>
              </span>
            </a>
          </li>
        ))}
      </ul>
      <div className="mt-2">
        <MethodNote label="Attention rules">
          <p>Shown when: a product with recent demand (open orders, or sales in the last 28 days) cannot cover its open orders, has nothing available, is at or below its low-stock threshold, or would run out within {ATTENTION_RULES.stockOutDays} days at the 28-day pace (indicative); an open order is older than {ATTENTION_RULES.openOrderAgeDays} days; one customer holds over {ATTENTION_RULES.concentrationPct}% of booked revenue (with at least two buying customers); a trial customer has no regular order after {ATTENTION_RULES.trialFollowUpDays} days; booked revenue is {ATTENTION_RULES.revenueDropPct}% or more below the comparison period (only once the history is at least “developing”).</p>
        </MethodNote>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Sales trends
// ---------------------------------------------------------------------------

export function TrendsSection({ m }: { m: AnalyticsModel }) {
  const [metric, setMetric] = useState<"revenue" | "units">("revenue");
  const unit = m.granularity === "day" ? "day" : m.granularity === "week" ? "week (Mon–Sun)" : "month";
  return (
    <SectionCard id="trends" title="Sales trends" subtitle={`Booked vs delivered, per ${unit}, ${m.periodText}. Every ${unit} is shown, including those with no sales.`}
      actions={<Toggle value={metric} options={[["revenue", "Revenue"], ["units", "Units"]]} onChange={setMetric} testId="trend-metric" />}>
      <div className="grid gap-4 xl:grid-cols-5">
        <div className="xl:col-span-3">
          <ChartCard title={metric === "revenue" ? "Revenue over time" : "Units over time"} basis={["booked", "actual"]} testId="chart-trend"
            chart={<SalesTrendChart data={m.series} metric={metric} />}
            table={<DataTable rows={m.series} rowKey={(r) => r.bucket} maxRows={31}
              columns={[
                { key: "b", header: m.granularity === "day" ? "Date" : "Period", primary: true, render: (r) => r.label },
                { key: "o", header: "Orders", align: "right", render: (r) => num(r.orders) },
                { key: "bk", header: "Booked", align: "right", render: (r) => (metric === "revenue" ? usd(r.bookedCents) : num(r.bookedUnits)) },
                { key: "dl", header: "Delivered", align: "right", render: (r) => (metric === "revenue" ? usd(r.deliveredCents) : num(r.deliveredUnits)) },
              ]} />}
            note={<MethodNote><p>Each order is placed on its order date (Mogadishu). Booked = everything ordered and not cancelled; delivered = the balls delivered so far on those orders. Historical deliveries carry no delivery date, so delivered sales are shown on the order date.</p></MethodNote>} />
        </div>
        <div className="xl:col-span-2">
          <ChartCard title="This month vs last month (cumulative)" basis={["booked", "indicative"]} testId="chart-cumulative"
            subtitle={m.runRate.available ? "Dashed: the indicative path if the month-to-date pace continues." : m.runRate.reason}
            chart={<CumulativeChart data={m.cumulative} />}
            table={<DataTable rows={m.cumulative} rowKey={(r) => String(r.day)} maxRows={31}
              columns={[
                { key: "d", header: "Day", primary: true, render: (r) => `Day ${r.day}` },
                { key: "c", header: "This month", align: "right", render: (r) => usd(r.currentCents) },
                { key: "p", header: "Last month", align: "right", render: (r) => usd(r.previousCents) },
                { key: "x", header: "Indicative", align: "right", render: (r) => usd(r.projectedCents) },
              ]} />}
            note={<MethodNote><p>Running total of booked revenue by day of the month, independent of the period selector (the other filters apply). The indicative line extends the month-to-date daily average to the month end.</p></MethodNote>} />
        </div>
      </div>
    </SectionCard>
  );
}

// ---------------------------------------------------------------------------
// Products
// ---------------------------------------------------------------------------

export function ProductsSection({ m, velocityByProduct }: { m: AnalyticsModel; velocityByProduct: Map<string, number> }) {
  const [metric, setMetric] = useState<"revenue" | "units">("revenue");
  const cols: Column<ProductRow>[] = [
    { key: "n", header: "Product", primary: true, render: (r) => r.name },
    { key: "bu", header: "Booked units", align: "right", render: (r) => num(r.bookedUnits) },
    { key: "du", header: "Delivered", align: "right", render: (r) => num(r.deliveredUnits) },
    { key: "br", header: "Booked revenue", align: "right", render: (r) => usd(r.bookedCents) },
    { key: "sh", header: "Share", align: "right", render: (r) => pct(r.sharePct) },
    { key: "ap", header: "Avg price", align: "right", render: (r) => usd(r.avgPriceCents) },
    { key: "rz", header: "Of list", align: "right", render: (r) => pct(r.realizationPct) },
    { key: "o", header: "Orders", align: "right", render: (r) => num(r.orders) },
    { key: "c", header: "Customers", align: "right", render: (r) => num(r.customers) },
    { key: "v", header: "Per day (28d)", align: "right", render: (r) => (velocityByProduct.has(r.productKey) ? num(velocityByProduct.get(r.productKey)!, 2) : "—") },
    { key: "l", header: "Last sale", align: "right", render: (r) => (r.lastSaleDate ? formatYmd(r.lastSaleDate, false) : "—") },
  ];
  return (
    <SectionCard id="products" title="Products" subtitle="What is selling, at what price. Calculated per order line: a product filter never counts the other products on the same order."
      actions={<Toggle value={metric} options={[["revenue", "Revenue"], ["units", "Units"]]} onChange={setMetric} testId="product-metric" />}>
      <div className="grid gap-4 lg:grid-cols-2">
        <ChartCard title="Product mix" basis={["booked"]} testId="chart-product-mix"
          chart={m.products.length ? <ProductMixChart rows={m.products} metric={metric} /> : <Empty />}
          table={<DataTable rows={m.products} rowKey={(r) => r.productKey} columns={cols.slice(0, 5)} />} />
        <ChartCard title="Price realisation" basis={["booked"]} testId="chart-price"
          subtitle={m.realization.realizationPct === null ? "No lines with a list price in this selection." : `Customers paid ${pct(m.realization.realizationPct)} of list price overall (${usd(m.realization.discountCents)} below list).`}
          chart={m.products.some((p) => p.avgListPriceCents !== null) ? <PriceRealizationChart rows={m.products} /> : <Empty />}
          table={<DataTable rows={m.products.filter((p) => p.avgListPriceCents !== null)} rowKey={(r) => r.productKey}
            columns={[cols[0], { key: "lp", header: "Avg list", align: "right", render: (r) => usd(r.avgListPriceCents) }, cols[5], cols[6], { key: "d", header: "Below list", align: "right", render: (r) => usd(r.discountCents) }]} />}
          note={<MethodNote><p>Realisation = Σ(price charged × qty) ÷ Σ(list price × qty), over lines that carry a list price (the standard price at the time of sale).</p></MethodNote>} />
      </div>
      <div className="mt-4">
        <DataTable rows={m.products} rowKey={(r) => r.productKey} columns={cols} testId="products-table" empty="No product sales in this selection." />
      </div>
    </SectionCard>
  );
}

// ---------------------------------------------------------------------------
// Customers
// ---------------------------------------------------------------------------

export function CustomersSection({ m }: { m: AnalyticsModel }) {
  const t = m.trials;
  const cols: Column<CustomerRow>[] = [
    { key: "n", header: "Customer", primary: true, render: (r) => (
      <span className="inline-flex flex-wrap items-center gap-1">
        {r.customerId ? <Link className="font-semibold text-brand-blue hover:underline" href={ordersLink(r.name)}>{r.name}</Link> : <span className="italic text-slate-500">{r.name}</span>}
        {r.isNew && <span className="rounded bg-emerald-100 px-1 text-[9px] font-bold uppercase text-emerald-800">New</span>}
      </span>) },
    { key: "o", header: "Orders", align: "right", render: (r) => num(r.orders) },
    { key: "u", header: "Balls", align: "right", render: (r) => num(r.bookedUnits) },
    { key: "b", header: "Booked", align: "right", render: (r) => usd(r.bookedCents) },
    { key: "d", header: "Delivered", align: "right", render: (r) => usd(r.deliveredCents) },
    { key: "s", header: "Share", align: "right", render: (r) => pct(r.sharePct) },
    { key: "f", header: "First order", align: "right", render: (r) => (r.firstOrderDate ? formatYmd(r.firstOrderDate) : "—") },
    { key: "g", header: "Avg days between", align: "right", render: (r) => (r.avgDaysBetweenOrders === null ? "—" : num(r.avgDaysBetweenOrders, 1)) },
  ];
  return (
    <SectionCard id="customers" title="Customers" subtitle="Who is buying. Customers are identified by their customer record, never by name.">
      <div className="mb-4 grid grid-cols-2 gap-2.5 lg:grid-cols-4">
        <StatTile label="Buying customers" basis="actual" value={num(m.newReturning.buyingCustomers)} raw={m.newReturning.buyingCustomers} testId="stat-buying" hint={`${m.newReturning.newCustomers} new · ${m.newReturning.returningCustomers} returning`} />
        <StatTile label="Top customer share" basis="booked" value={pct(m.concentration.top1Pct)} testId="stat-top1" hint={`Top 3: ${pct(m.concentration.top3Pct)} · Top 5: ${pct(m.concentration.top5Pct)}`} />
        <StatTile label="Orders per customer" basis="booked" value={m.newReturning.buyingCustomers ? num(m.customers.filter((c) => c.customerId).reduce((s, c) => s + c.orders, 0) / m.newReturning.buyingCustomers, 1) : "—"} hint="In this period" />
        <StatTile label="Trial → regular" basis="actual" value={t.trialCustomers ? `${t.converted} of ${t.trialCustomers}` : "No trials"} testId="stat-trials"
          hint={t.trialCustomers >= 10 ? `${pct((t.converted / t.trialCustomers) * 100, 0)} converted (all time)` : "All time; a rate is shown from 10 trial customers"} />
      </div>
      <div className="grid gap-4 lg:grid-cols-2">
        <ChartCard title="Customer concentration" basis={["booked"]} testId="chart-pareto" subtitle="Bars: booked revenue. Line: cumulative share of the period's booked revenue."
          chart={m.concentration.pareto.length ? <ParetoChart data={m.concentration.pareto} /> : <Empty />}
          table={<DataTable rows={m.concentration.pareto} rowKey={(r) => r.key} columns={[
            { key: "n", header: "Customer", primary: true, render: (r) => r.name },
            { key: "b", header: "Booked", align: "right", render: (r) => usd(r.bookedCents) },
            { key: "c", header: "Cumulative", align: "right", render: (r) => pct(r.cumulativePct) },
          ]} />} />
        <ChartCard title="New vs returning customers" basis={["actual"]} testId="chart-new-returning" subtitle="Buying customers per period. New = their first ever order falls in that period."
          chart={<NewReturningChart data={m.newReturningSeries} />}
          table={<DataTable rows={m.newReturningSeries} rowKey={(r) => r.bucket} maxRows={31} columns={[
            { key: "b", header: "Period", primary: true, render: (r) => r.label },
            { key: "n", header: "New", align: "right", render: (r) => num(r.newCustomers) },
            { key: "r", header: "Returning", align: "right", render: (r) => num(r.returningCustomers) },
          ]} />} />
      </div>
      {t.notConverted.length > 0 && (
        <div className="mt-4 rounded-xl border border-slate-200 p-3" data-testid="trials-open">
          <p className="mb-1.5 text-xs font-bold text-slate-800">Trial customers without a regular order yet</p>
          <ul className="flex flex-wrap gap-1.5 text-[11px]">
            {t.notConverted.map((x) => <li key={x.customerId} className="rounded-full bg-slate-100 px-2 py-0.5 text-slate-700">{x.name} · trial {formatYmd(x.trialDate)} · {x.daysSinceTrial} days</li>)}
          </ul>
        </div>
      )}
      <div className="mt-4">
        <DataTable rows={m.customers} rowKey={(r) => r.key} columns={cols} maxRows={15} testId="customers-table" empty="No customer orders in this selection." />
      </div>
      <div className="mt-2"><MethodNote>
        <p>First order = the customer’s earliest non-cancelled order you can see, whatever the filters. Trial conversion counts customers with a trial order who later placed a regular order (all time; the customer and officer filters apply). Orders without a customer record are grouped as one row and never matched by name.</p>
      </MethodNote></div>
    </SectionCard>
  );
}

// ---------------------------------------------------------------------------
// Marketing Officers (breakdown only)
// ---------------------------------------------------------------------------

export function OfficersSection({ m }: { m: AnalyticsModel }) {
  const cols: Column<OfficerRow>[] = [
    { key: "n", header: "Marketing Officer", primary: true, render: (r) => r.name },
    { key: "o", header: "Orders", align: "right", render: (r) => num(r.orders) },
    { key: "d", header: "Delivered revenue", align: "right", render: (r) => usd(r.deliveredCents) },
    { key: "b", header: "Booked revenue", align: "right", render: (r) => usd(r.bookedCents) },
    { key: "du", header: "Delivered units", align: "right", render: (r) => num(r.deliveredUnits) },
    { key: "c", header: "Customers", align: "right", render: (r) => num(r.customers) },
  ];
  return (
    <SectionCard id="officers" title="Sales by Marketing Officer" subtitle="Who generated the sales in this period. A breakdown, not a target comparison.">
      <div className="grid gap-4 lg:grid-cols-2">
        <ChartCard title="Booked vs delivered by officer" basis={["booked", "actual"]} testId="chart-officers"
          chart={m.officers.length ? <OfficerChart rows={m.officers} /> : <Empty />}
          table={<DataTable rows={m.officers} rowKey={(r) => r.officerId} columns={cols} />} />
        <div className="min-w-0">
          <DataTable rows={m.officers} rowKey={(r) => r.officerId} columns={cols} testId="officers-table" empty="No sales in this selection." />
          <div className="mt-2"><MethodNote><p>Attributed to the Marketing Officer recorded on the order. Orders without one are “Unassigned”. Commission is not shown here.</p></MethodNote></div>
        </div>
      </div>
    </SectionCard>
  );
}

function Empty() {
  return <div className="flex h-40 items-center justify-center text-xs text-slate-400">No data for this selection.</div>;
}


