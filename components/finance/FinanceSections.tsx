"use client";

/**
 * Financial Management sections. Every number comes from lib/finance/model
 * (buildFinanceModel, receivableOrders, ...); these components only lay it out.
 * Definitions sit in small (i) tooltips next to each figure.
 */

import { useState, type ReactNode } from "react";
import { AlertTriangle, CheckCircle2, ChevronDown, Info, MinusCircle } from "lucide-react";
import { cn } from "@/lib/utils";
import {
  WHOLE_ORDER_NOTE, checksSummary, receivablesByCustomer,
  type FinanceModel, type PaymentRow, type ProductProfitRow, type ReceivableFilter, type ReceivableOrderRow, type ReconciliationCheck,
} from "@/lib/finance/model";
import { ChartCard, DataTable, MethodNote, SectionCard, num, pct, usd, type Column } from "@/components/analytics/primitives";
import { AgingChart, CashFlowChart, ProductProfitChart } from "./lazyCharts";

/** A small (i) with the definition, shown on hover / focus / long-press. */
export function InfoTip({ text }: { text: string }) {
  return (
    <span tabIndex={0} title={text} aria-label={text} className="inline-flex cursor-help text-slate-400 hover:text-slate-700 focus:text-slate-700 focus:outline-none">
      <Info className="h-3 w-3" />
    </span>
  );
}

function Kpi({ label, tip, value, sub, scope, testId, raw }: { label: string; tip: string; value: ReactNode; sub?: ReactNode; scope?: string | null; testId?: string; raw?: number | null }) {
  return (
    <div className="rounded-xl border border-slate-200 bg-white p-3.5 shadow-sm" data-testid={testId} data-value={raw ?? undefined}>
      <p className="flex items-center gap-1 text-[11px] font-semibold text-slate-500">{label} <InfoTip text={tip} /></p>
      <p className="mt-1 text-xl font-bold tabular-nums text-slate-900">{value}</p>
      {scope && <p className="mt-0.5 text-[11px] font-semibold text-amber-700" data-testid={testId ? `${testId}-scope` : undefined}>{scope}</p>}
      {sub && <p className="mt-0.5 text-[11px] text-slate-500">{sub}</p>}
    </div>
  );
}

const delta = (now: number, before: number | null | undefined) => {
  if (before === undefined || before === null) return null;
  if (before === 0) return now === 0 ? "no change" : "new";
  const d = ((now - before) / Math.abs(before)) * 100;
  return `${d >= 0 ? "+" : ""}${d.toFixed(1)}%`;
};
const vs = (now: number, before: number | null | undefined) => { const d = delta(now, before); return d ? ` · ${d} vs comparison` : ""; };

export const TIPS = {
  cash: "Money received: payments dated in the period, on non-cancelled orders. A payment for an earlier sale is cash now, not new revenue.",
  revenue: "Balls delivered x the agreed unit price, on orders dated in the period. Counted once, when delivered, whether paid or not.",
  pending: "Balls still to deliver x the agreed unit price, on orders dated in the period. Not revenue yet.",
  outstanding: "What customers still owe on non-cancelled orders right now (the database's outstanding balance). Not limited to the period.",
  profit: "Delivered revenue minus the cost of those balls at the unit cost recorded when each line was sold. Before commissions and other expenses.",
} as const;

export function FinanceKpis({ m }: { m: FinanceModel }) {
  const c = m.current, p = m.comparison?.figures;
  const scope = m.productFiltered ? WHOLE_ORDER_NOTE : null;
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5" data-testid="finance-kpis">
      <Kpi testId="kpi-cash" raw={c.cash.totalCents} label="Cash received" tip={TIPS.cash} value={usd(c.cash.totalCents)} scope={scope}
        sub={`${num(c.cash.payments)} payment${c.cash.payments === 1 ? "" : "s"}${vs(c.cash.totalCents, p?.cash.totalCents)}`} />
      <Kpi testId="kpi-revenue" raw={c.deliveredRevenueCents} label="Delivered revenue" tip={TIPS.revenue} value={usd(c.deliveredRevenueCents)}
        sub={`${num(c.orders)} order${c.orders === 1 ? "" : "s"}${vs(c.deliveredRevenueCents, p?.deliveredRevenueCents)}`} />
      <Kpi testId="kpi-pending" raw={c.pendingValueCents} label="Pending order value" tip={TIPS.pending} value={usd(c.pendingValueCents)}
        sub="Not yet delivered" />
      <Kpi testId="kpi-outstanding" raw={m.receivables.totalCents} label="Outstanding receivables" tip={TIPS.outstanding} value={usd(m.receivables.totalCents)} scope={scope}
        sub={`${usd(m.receivables.deliveredCents)} on delivered orders`} />
      {m.costVisible ? (
        <Kpi testId="kpi-gross-profit" raw={c.grossProfitCents} label="Gross profit" tip={TIPS.profit} value={usd(c.grossProfitCents)}
          sub={c.marginPct === null ? "Nothing delivered in this period" : `${pct(c.marginPct)} margin${vs(c.grossProfitCents ?? 0, p?.grossProfitCents)}`} />
      ) : (
        <Kpi testId="kpi-gross-profit" label="Gross profit" tip={TIPS.profit} value="—" sub="Cost is not available to your account." />
      )}
    </div>
  );
}

const STATUS_STYLE: Record<ReceivableOrderRow["status"], string> = {
  paid: "bg-green-100 text-green-700", partial: "bg-amber-100 text-amber-700", unpaid: "bg-red-100 text-red-700",
};
const StatusPill = ({ s }: { s: ReceivableOrderRow["status"] }) => <span className={cn("inline-flex rounded-full px-2 py-0.5 text-[10px] font-bold uppercase", STATUS_STYLE[s])}>{s}</span>;

function orderColumns(onRecordPayment?: (orderId: string) => void): Column<ReceivableOrderRow>[] {
  const cols: Column<ReceivableOrderRow>[] = [
    { key: "customer", header: "Customer", primary: true, render: (r) => <span className="font-semibold text-slate-800">{r.customerName}</span> },
    { key: "order", header: "Order", render: (r) => <span className="font-mono text-[11px]">{r.orderId}</span> },
    { key: "date", header: "Order date", render: (r) => r.date },
    { key: "total", header: "Order total", align: "right", render: (r) => usd(r.totalCents) },
    { key: "collected", header: "Collected", align: "right", render: (r) => usd(r.collectedCents) },
    { key: "outstanding", header: "Outstanding", align: "right", render: (r) => <span className="font-semibold">{usd(r.outstandingCents)}</span> },
    { key: "status", header: "Status", render: (r) => <StatusPill s={r.status} /> },
  ];
  if (onRecordPayment) {
    cols.push({ key: "action", header: "", render: (r) => r.outstandingCents > 0 ? (
      <button type="button" data-testid="fin-record-payment" onClick={() => onRecordPayment(r.orderId)}
        className="rounded-md border border-slate-200 bg-white px-2 py-1 text-[10px] font-bold uppercase text-slate-700 hover:bg-blue-50 hover:text-blue-700">Record payment</button>
    ) : null });
  }
  return cols;
}

/**
 * Receivables: summary, aging, and the order / customer views moved from
 * Customer Database. Record payment opens the shared RecordPaymentDialog (via the page).
 */
export function ReceivablesSection({ m, orderRows, status, onStatus, onRecordPayment }: {
  m: FinanceModel;
  orderRows: ReceivableOrderRow[];
  status: ReceivableFilter;
  onStatus: (s: ReceivableFilter) => void;
  /** Present only when the user may record payments (create_orders or edit_orders). */
  onRecordPayment?: (orderId: string) => void;
}) {
  const r = m.receivables;
  const [view, setView] = useState<"order" | "customer">("order");
  const [openCustomer, setOpenCustomer] = useState<string | null>(null);
  const byCustomer = receivablesByCustomer(orderRows);
  const cols = orderColumns(onRecordPayment);
  const custSummary = `${num(r.linkedCustomers)} customer${r.linkedCustomers === 1 ? "" : "s"}${r.unlinkedOrders ? ` + ${num(r.unlinkedOrders)} unlinked order${r.unlinkedOrders === 1 ? "" : "s"}` : ""}`;
  return (
    <SectionCard id="receivables" title="Receivables" subtitle={<>Owed now on non-cancelled orders · {custSummary}{m.productFiltered ? ` · ${WHOLE_ORDER_NOTE}` : ""}</>}>
      <div className="mb-4 grid grid-cols-2 gap-3 sm:grid-cols-4">
        <MiniStat testId="recv-total" raw={r.totalCents} label="Outstanding" value={usd(r.totalCents)} />
        <MiniStat testId="recv-delivered" raw={r.deliveredCents} label="On delivered orders" value={usd(r.deliveredCents)} hint={`${num(r.deliveredOrders)} order(s) · collectable now`} />
        <MiniStat label="On orders not yet delivered" value={usd(r.openCents)} hint={`${num(r.openOrders)} order(s)`} />
        <MiniStat testId="recv-overpaid" raw={r.overpaidCents} label="Overpaid" value={usd(r.overpaidCents)} hint={r.overpaidOrders ? `${num(r.overpaidOrders)} order(s)` : "None"} />
      </div>

      <div className="mb-3 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex rounded-lg border border-slate-200 p-0.5 text-[11px] font-semibold" role="tablist">
          {(["order", "customer"] as const).map((v) => (
            <button key={v} type="button" role="tab" aria-selected={view === v} data-testid={`recv-view-${v}`} onClick={() => setView(v)}
              className={cn("rounded-md px-3 py-1", view === v ? "bg-slate-900 text-white" : "text-slate-600 hover:bg-slate-100")}>
              {v === "order" ? "By order" : "By customer"}
            </button>
          ))}
        </div>
        <div className="flex flex-wrap gap-1.5">
          {(["all", "unpaid", "partial", "paid"] as const).map((s) => (
            <button key={s} type="button" data-testid={`recv-status-${s}`} onClick={() => onStatus(s)}
              className={cn("h-7 rounded-lg px-2.5 text-[10px] font-bold uppercase tracking-wide", status === s ? "bg-slate-900 text-white" : "bg-slate-100 text-slate-600")}>
              {s}
            </button>
          ))}
        </div>
      </div>

      {view === "order" ? (
        <DataTable testId="recv-orders" rows={orderRows} rowKey={(x) => x.orderId} columns={cols} maxRows={15} empty="No orders match this filter." />
      ) : (
        <div data-testid="recv-customers">
          {byCustomer.length === 0 && <p className="py-6 text-center text-xs text-slate-400">No orders match this filter.</p>}
          <ul className="divide-y divide-slate-100 rounded-xl border border-slate-200">
            {byCustomer.map((g) => (
              <li key={g.key}>
                <button type="button" onClick={() => setOpenCustomer(openCustomer === g.key ? null : g.key)} aria-expanded={openCustomer === g.key}
                  className="flex w-full items-center gap-3 px-3 py-2.5 text-left hover:bg-slate-50">
                  <ChevronDown className={cn("h-3.5 w-3.5 shrink-0 text-slate-400 transition-transform", openCustomer === g.key && "rotate-180")} />
                  <span className="min-w-0 flex-1 truncate text-xs font-semibold text-slate-800">{g.customerName}{g.customerId === null && <span className="ml-1 text-[10px] font-normal text-slate-400">(unlinked order)</span>}</span>
                  <span className="hidden text-[11px] text-slate-500 sm:inline">{num(g.ordersWithBalance)} of {num(g.orders)} order(s) owing</span>
                  <span className="w-24 text-right text-xs font-bold tabular-nums text-slate-900">{usd(g.outstandingCents)}</span>
                </button>
                {openCustomer === g.key && (
                  <div className="border-t border-slate-100 bg-slate-50/60 px-3 py-2">
                    <DataTable rows={g.rows} rowKey={(x) => x.orderId} columns={cols.filter((c) => c.key !== "customer")} />
                  </div>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="mt-4">
        <ChartCard title="Outstanding by order age" testId="aging-card"
          subtitle="Days since the order date. EFZ has no invoice due dates, so this is not days overdue."
          chart={<AgingChart data={r.aging} />}
          table={<DataTable rows={r.aging} rowKey={(a) => a.label} columns={[
            { key: "age", header: "Order age", primary: true, render: (a) => a.label },
            { key: "orders", header: "Orders", align: "right", render: (a) => num(a.orders) },
            { key: "amount", header: "Outstanding", align: "right", render: (a) => usd(a.cents) },
          ]} />} />
      </div>
      <div className="mt-3">
        <MethodNote>
          <p>Balances are the database&apos;s own outstanding balance (order total − amount paid, never below 0), kept current by Record payment. Nothing is re-added in the browser, and a balance is never subtracted from revenue.</p>
          <p>Status: <strong>paid</strong> = nothing left to pay, <strong>partial</strong> = some paid, <strong>unpaid</strong> = nothing paid. &quot;All&quot; lists every non-cancelled order. The product filter does not apply: payments belong to whole orders.</p>
        </MethodNote>
      </div>
    </SectionCard>
  );
}

function MiniStat({ label, value, hint, testId, raw }: { label: string; value: ReactNode; hint?: ReactNode; testId?: string; raw?: number | null }) {
  return (
    <div className="rounded-xl bg-slate-50 p-3" data-testid={testId} data-value={raw ?? undefined}>
      <p className="text-[11px] font-semibold text-slate-500">{label}</p>
      <p className="mt-0.5 text-base font-bold tabular-nums text-slate-900">{value}</p>
      {hint && <p className="text-[11px] text-slate-500">{hint}</p>}
    </div>
  );
}

const paymentColumns: Column<PaymentRow>[] = [
  { key: "date", header: "Date", render: (r) => r.date },
  { key: "customer", header: "Customer", primary: true, render: (r) => <span className="font-semibold text-slate-800">{r.customerName}</span> },
  { key: "order", header: "Order", render: (r) => <span className="font-mono text-[11px]">{r.orderId}</span> },
  { key: "method", header: "Method", render: (r) => r.method },
  { key: "amount", header: "Amount", align: "right", render: (r) => <span className="font-semibold">{usd(r.amountCents)}</span> },
];

export function CollectionsSection({ m }: { m: FinanceModel }) {
  const cash = m.current.cash;
  return (
    <SectionCard id="collections" title="Collections and payments"
      subtitle={<>Payments dated in the period{m.productFiltered ? <span className="font-semibold text-amber-700" data-testid="collections-scope"> · {WHOLE_ORDER_NOTE}</span> : null}</>}>
      <div className="grid gap-4 lg:grid-cols-3">
        <div>
          <h3 className="mb-2 text-sm font-bold text-slate-800">By payment method</h3>
          <DataTable testId="methods-table" rows={cash.byMethod} rowKey={(r) => r.method} empty="No payments in this period." columns={[
            { key: "method", header: "Method", primary: true, render: (r) => <span className="font-semibold text-slate-800">{r.method}</span> },
            { key: "count", header: "Payments", align: "right", render: (r) => num(r.payments) },
            { key: "amount", header: "Amount", align: "right", render: (r) => usd(r.cents) },
            { key: "share", header: "Share", align: "right", render: (r) => pct(r.sharePct) },
          ]} />
        </div>
        <div className="lg:col-span-2">
          <h3 className="mb-2 text-sm font-bold text-slate-800">Payment history</h3>
          <DataTable testId="payments-table" rows={m.payments} rowKey={(r) => r.key} columns={paymentColumns} maxRows={15} empty="No payments in this period." />
        </div>
      </div>
      <p className="mt-3 text-[11px] text-slate-500">Methods appear exactly as recorded; an empty method shows as &quot;Not recorded&quot;, never assumed to be Cash.</p>
    </SectionCard>
  );
}

export function CashFlowSection({ m }: { m: FinanceModel }) {
  const pts = m.cashFlow.points;
  const showRevenue = !m.productFiltered;
  return (
    <SectionCard id="cash-flow" title="Cash flow" subtitle={`Money received${showRevenue ? " against delivered revenue" : ""}, by ${m.cashFlow.granularity}. Inflows only: EFZ records no expenses.`}>
      <ChartCard title={showRevenue ? "Cash received vs delivered revenue" : "Cash received"} testId="cashflow-card"
        subtitle={m.productFiltered
          ? <span className="font-semibold text-amber-700" data-testid="cashflow-scope">{WHOLE_ORDER_NOTE}; delivered revenue is hidden because it would cover the selected product only.</span>
          : "Revenue by order date, cash by payment date: they need not match in any one bucket."}
        chart={<CashFlowChart data={pts} showRevenue={showRevenue} />}
        table={<DataTable rows={[...pts].reverse()} rowKey={(p) => p.bucket} maxRows={20} columns={[
          { key: "bucket", header: "Period", primary: true, render: (p) => p.label },
          ...(showRevenue ? [{ key: "revenue", header: "Delivered revenue", align: "right" as const, render: (p: (typeof pts)[number]) => usd(p.deliveredCents) }] : []),
          { key: "cash", header: "Cash received", align: "right", render: (p) => usd(p.cashInCents) },
          { key: "cum", header: "Cumulative cash", align: "right", render: (p) => usd(p.cumulativeCashCents) },
        ]} />} />
    </SectionCard>
  );
}

const productColumns: Column<ProductProfitRow>[] = [
  { key: "product", header: "Product", primary: true, render: (r) => <span className="font-semibold text-slate-800">{r.productName}</span> },
  { key: "units", header: "Delivered", align: "right", render: (r) => num(r.units) },
  { key: "revenue", header: "Revenue", align: "right", render: (r) => usd(r.revenueCents) },
  { key: "cost", header: "Cost", align: "right", render: (r) => usd(r.costCents) },
  { key: "profit", header: "Gross profit", align: "right", render: (r) => <span className={cn("font-semibold", r.profitCents < 0 && "text-rose-700")}>{usd(r.profitCents)}</span> },
  { key: "margin", header: "Margin", align: "right", render: (r) => pct(r.marginPct) },
  { key: "flags", header: "Flags", render: (r) => (r.zeroCostLines || r.belowCostLines)
    ? <span className="text-[11px] text-amber-700">{[r.zeroCostLines ? `${r.zeroCostLines} at no cost` : "", r.belowCostLines ? `${r.belowCostLines} below cost` : ""].filter(Boolean).join(" · ")}</span>
    : <span className="text-slate-300">—</span> },
];

export function ProfitabilitySection({ m }: { m: FinanceModel }) {
  if (!m.costVisible || m.products === null) {
    return (
      <SectionCard id="profitability" title="Profitability">
        <p className="py-6 text-center text-xs text-slate-500" data-testid="profit-withheld">Cost and profit are not available to your account.</p>
      </SectionCard>
    );
  }
  const c = m.current;
  return (
    <SectionCard id="profitability" title="Profitability" subtitle={<span className="inline-flex items-center gap-1">Delivered balls, at the cost recorded when each line was sold <InfoTip text={TIPS.profit} /></span>}>
      <div className="mb-4 grid grid-cols-2 gap-3 sm:grid-cols-4">
        <MiniStat label="Delivered revenue" value={usd(c.deliveredRevenueCents)} />
        <MiniStat label="Cost of delivered balls" value={usd(c.costCents)} />
        <MiniStat label="Gross profit" value={usd(c.grossProfitCents)} />
        <MiniStat label="Gross margin" value={pct(c.marginPct)} />
      </div>
      <div className="grid gap-4 lg:grid-cols-2">
        <ChartCard title="Gross profit by product" testId="product-profit-card"
          chart={m.products.length ? <ProductProfitChart rows={m.products} /> : <p className="py-6 text-center text-xs text-slate-400">Nothing delivered in this period.</p>}
          table={<DataTable rows={m.products} rowKey={(r) => r.productKey} columns={productColumns.slice(0, 6)} />} />
        <div>
          <h3 className="mb-2 text-sm font-bold text-slate-800">Product profitability</h3>
          <DataTable testId="product-profit-table" rows={m.products} rowKey={(r) => r.productKey} columns={productColumns} maxRows={10} empty="Nothing delivered in this period." />
        </div>
      </div>
      <p className="mt-3 text-[11px] text-slate-500">&quot;At no cost&quot; lines have a recorded cost of 0, so their profit is overstated. Later product cost changes never rewrite past profit.</p>
    </SectionCard>
  );
}

const checkIcon = (c: ReconciliationCheck) =>
  !c.available ? <MinusCircle className="h-4 w-4 text-slate-300" /> : c.count === 0 ? <CheckCircle2 className="h-4 w-4 text-emerald-600" /> : <AlertTriangle className={cn("h-4 w-4", c.severity === "FAIL" ? "text-rose-600" : "text-amber-500")} />;

/** Secondary control section: collapsed by default, the header always shows the number of findings. */
export function FinancialChecksSection({ m }: { m: FinanceModel }) {
  const s = checksSummary(m.reconciliation);
  const headline = s.findings === 0
    ? "No exceptions"
    : [s.errors ? `${s.errors} data error${s.errors === 1 ? "" : "s"}` : "", s.warnings ? `${s.warnings} item${s.warnings === 1 ? "" : "s"} to review` : ""].filter(Boolean).join(" · ");
  // Findings first, then clean checks.
  const ordered = [...m.reconciliation].sort((a, b) => Number(b.available && b.count > 0) - Number(a.available && a.count > 0));
  return (
    <section id="financial-checks" className="rounded-2xl border border-slate-200 bg-white shadow-sm" data-testid="financial-checks">
      <details className="group" data-testid="financial-checks-details">
        <summary className="flex cursor-pointer list-none items-center justify-between gap-3 p-4 sm:p-5">
          <div>
            <h2 className="text-base font-bold text-slate-900">Financial Checks &amp; Exceptions</h2>
            <p className="mt-0.5 text-xs text-slate-500">Integrity checks on every order you can see, whatever the filters.</p>
          </div>
          <span className="flex shrink-0 items-center gap-2">
            <span data-testid="financial-checks-summary" data-errors={s.errors} data-warnings={s.warnings}
              className={cn("rounded-full px-2.5 py-1 text-[11px] font-bold", s.errors ? "bg-rose-50 text-rose-700" : s.warnings ? "bg-amber-50 text-amber-800" : "bg-emerald-50 text-emerald-700")}>
              {headline}
            </span>
            <ChevronDown className="h-4 w-4 text-slate-400 transition-transform group-open:rotate-180" />
          </span>
        </summary>
        <ul className="divide-y divide-slate-100 border-t border-slate-100 px-4 sm:px-5" data-testid="reconciliation-list">
          {ordered.map((c) => (
            <li key={c.key} className="flex items-start gap-2 py-2.5" data-check={c.key} data-count={c.available ? c.count : undefined}>
              <span className="mt-0.5">{checkIcon(c)}</span>
              <div className="min-w-0 flex-1">
                <p className="text-xs font-semibold text-slate-800">{c.label}</p>
                {!c.available && <p className="text-[11px] text-slate-400">Needs cost, which is not available to your account.</p>}
                {c.available && c.count > 0 && (
                  <>
                    <p className="text-[11px] text-slate-600">{c.action}</p>
                    <p className="break-words font-mono text-[10px] text-slate-500">
                      {c.orderIds.slice(0, 8).join(", ")}{c.orderIds.length > 8 ? ` and ${c.orderIds.length - 8} more` : ""}
                    </p>
                  </>
                )}
              </div>
              {c.available && (
                <span className={cn("shrink-0 rounded-full px-2 py-px text-[10px] font-bold",
                  c.count === 0 ? "bg-emerald-50 text-emerald-700" : c.severity === "FAIL" ? "bg-rose-50 text-rose-700" : "bg-amber-50 text-amber-800")}>
                  {c.count === 0 ? "OK" : `${c.count} ${c.severity === "FAIL" ? "error" : "to review"}`}
                </span>
              )}
            </li>
          ))}
        </ul>
        <p className="px-4 pb-4 text-[11px] text-slate-500 sm:px-5">Same rules as the database&apos;s validate_financials check. This page only reads; nothing is corrected here.</p>
      </details>
    </section>
  );
}
