"use client";

/**
 * Financial Management sections. Every number comes from lib/finance/model
 * (buildFinanceModel); these components only lay it out.
 */

import { AlertTriangle, CheckCircle2, MinusCircle } from "lucide-react";
import { cn } from "@/lib/utils";
import { WHOLE_ORDER_NOTE, type FinanceModel, type PaymentRow, type ProductProfitRow, type ReconciliationCheck } from "@/lib/finance/model";
import type { Balance } from "@/lib/finance/facts";
import { ChartCard, DataTable, MethodNote, SectionCard, StatTile, num, pct, usd, type Column } from "@/components/analytics/primitives";
import { AgingChart, CashFlowChart, ProductProfitChart } from "./lazyCharts";

const delta = (now: number, before: number | undefined) => {
  if (before === undefined) return null;
  if (before === 0) return now === 0 ? "No change" : "New this period";
  const d = ((now - before) / Math.abs(before)) * 100;
  return `${d >= 0 ? "+" : ""}${d.toFixed(1)}% vs comparison`;
};

export function FinanceKpis({ m }: { m: FinanceModel }) {
  const c = m.current, p = m.comparison?.figures;
  return (
    <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-5" data-testid="finance-kpis">
      <StatTile testId="kpi-cash" raw={c.cash.totalCents} label="Cash received" basis="actual" value={usd(c.cash.totalCents)}
        hint={<>{m.productFiltered && <span className="block font-semibold text-amber-700" data-testid="kpi-cash-scope">{WHOLE_ORDER_NOTE}</span>}{num(c.cash.payments)} payment{c.cash.payments === 1 ? "" : "s"}{p ? ` · ${delta(c.cash.totalCents, p.cash.totalCents)}` : ""}</>} />
      <StatTile testId="kpi-booked" raw={c.bookedCents} label="Booked sales" basis="booked" value={usd(c.bookedCents)}
        hint={<>{num(c.orders)} order{c.orders === 1 ? "" : "s"}{p ? ` · ${delta(c.bookedCents, p.bookedCents)}` : ""}</>} />
      <StatTile testId="kpi-paid-on-orders" raw={c.paidOnPeriodOrdersCents} label="Paid on these orders" basis="actual"
        value={c.paidOnPeriodOrdersPct === null ? "—" : pct(c.paidOnPeriodOrdersPct)}
        hint={c.paidOnPeriodOrdersCents === null ? "Payments are per order, not per product." : `${usd(c.paidOnPeriodOrdersCents)} of ${usd(c.bookedCents)} so far`} />
      <StatTile testId="kpi-outstanding" raw={m.receivables.totalCents} label="Outstanding now" basis="actual" value={usd(m.receivables.totalCents)}
        hint={<>{m.productFiltered && <span className="block font-semibold text-amber-700">{WHOLE_ORDER_NOTE}</span>}{usd(m.receivables.deliveredCents)} on delivered orders</>} />
      {m.costVisible ? (
        <StatTile testId="kpi-gross-profit" raw={c.grossProfitCents} label="Gross profit" basis="booked" value={usd(c.grossProfitCents)}
          hint={c.marginPct === null ? "No sales in this period" : `${pct(c.marginPct)} margin${p && p.grossProfitCents !== null ? ` · ${delta(c.grossProfitCents ?? 0, p.grossProfitCents)}` : ""}`} />
      ) : (
        <StatTile testId="kpi-gross-profit" label="Gross profit" value="—" hint="Cost is not available to your account." />
      )}
    </div>
  );
}

const balanceColumns: Column<Balance>[] = [
  { key: "name", header: "Customer", primary: true, render: (r) => <span className="font-semibold text-slate-800">{r.name}</span> },
  { key: "orders", header: "Orders with balance", align: "right", render: (r) => num(r.ordersWithBalance) },
  { key: "amount", header: "Outstanding", align: "right", render: (r) => <span className="font-semibold">{usd(r.outstandingCents)}</span> },
];

export function ReceivablesSection({ m }: { m: FinanceModel }) {
  const r = m.receivables;
  return (
    <SectionCard id="receivables" title="Receivables" subtitle="Money still owed on non-cancelled orders, as of now (not limited to the period).">
      <div className="mb-4 grid grid-cols-2 gap-2 sm:grid-cols-4">
        <StatTile testId="recv-total" raw={r.totalCents} label="Total outstanding" basis="actual" value={usd(r.totalCents)}
          hint={`${num(r.linkedCustomers)} customer${r.linkedCustomers === 1 ? "" : "s"}${r.unlinkedOrders ? ` + ${num(r.unlinkedOrders)} unlinked order${r.unlinkedOrders === 1 ? "" : "s"}` : ""}`} />
        <StatTile testId="recv-delivered" raw={r.deliveredCents} label="On delivered orders" basis="actual" value={usd(r.deliveredCents)} hint={`${num(r.deliveredOrders)} order${r.deliveredOrders === 1 ? "" : "s"} · collectable now`} />
        <StatTile label="On open orders" basis="committed" value={usd(r.openCents)} hint={`${num(r.openOrders)} order${r.openOrders === 1 ? "" : "s"} not yet fully delivered`} />
        <StatTile testId="recv-overpaid" raw={r.overpaidCents} label="Overpaid" value={usd(r.overpaidCents)} hint={r.overpaidOrders ? `${num(r.overpaidOrders)} order(s) paid above total` : "None"} />
      </div>
      <div className="grid gap-4 lg:grid-cols-2">
        <ChartCard title="Outstanding by order age" basis={["actual"]} testId="aging-card"
          subtitle="Age since the order date. EFZ has no invoice due dates, so this is not days overdue."
          chart={<AgingChart data={r.aging} />}
          table={<DataTable rows={r.aging} rowKey={(a) => a.label} columns={[
            { key: "age", header: "Order age", primary: true, render: (a) => a.label },
            { key: "orders", header: "Orders", align: "right", render: (a) => num(a.orders) },
            { key: "amount", header: "Outstanding", align: "right", render: (a) => usd(a.cents) },
          ]} />} />
        <div className="rounded-xl border border-slate-200 p-3 sm:p-4">
          <h3 className="mb-2 text-sm font-bold text-slate-800">Who owes</h3>
          <DataTable testId="balances-table" rows={r.customers} rowKey={(b) => b.customerId ?? b.name} columns={balanceColumns} maxRows={10} empty="No outstanding balances." />
        </div>
      </div>
      <div className="mt-3">
        <MethodNote>
          <p>Balances are the database&apos;s own orders.outstanding_balance (total − amount paid, never below 0), kept up to date by record_payment. Nothing is re-added in the browser.</p>
          <p>A product filter does not apply here: payments and balances belong to whole orders. Cancelled orders are excluded.</p>
        </MethodNote>
      </div>
    </SectionCard>
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
      subtitle={`Payments dated in the period (${m.periodText}).${m.productFiltered ? ` ${WHOLE_ORDER_NOTE}: payments are recorded per order.` : ""}`}>
      <div className="grid gap-4 lg:grid-cols-3">
        <div className="rounded-xl border border-slate-200 p-3 sm:p-4">
          <h3 className="mb-2 text-sm font-bold text-slate-800">By payment method</h3>
          <DataTable testId="methods-table" rows={cash.byMethod} rowKey={(r) => r.method} empty="No payments in this period." columns={[
            { key: "method", header: "Method", primary: true, render: (r) => <span className="font-semibold text-slate-800">{r.method}</span> },
            { key: "count", header: "Payments", align: "right", render: (r) => num(r.payments) },
            { key: "amount", header: "Amount", align: "right", render: (r) => usd(r.cents) },
            { key: "share", header: "Share", align: "right", render: (r) => pct(r.sharePct) },
          ]} />
        </div>
        <div className="rounded-xl border border-slate-200 p-3 sm:p-4 lg:col-span-2">
          <h3 className="mb-2 text-sm font-bold text-slate-800">Payment history</h3>
          <DataTable testId="payments-table" rows={m.payments} rowKey={(r) => r.key} columns={paymentColumns} maxRows={15} empty="No payments in this period." />
        </div>
      </div>
      <div className="mt-3">
        <MethodNote>
          <p>Dated by payments.payment_date, the day the money came in. Methods are shown exactly as recorded; an empty method is &quot;Not recorded&quot;, never assumed to be Cash.</p>
          <p>Payments are recorded from the order, not on this page.</p>
        </MethodNote>
      </div>
    </SectionCard>
  );
}

export function CashFlowSection({ m }: { m: FinanceModel }) {
  const pts = m.cashFlow.points;
  return (
    <SectionCard id="cash-flow" title="Cash flow" subtitle="Money received against sales booked, per period bucket.">
      <ChartCard title={m.productFiltered ? "Cash received" : "Cash received vs booked"} basis={m.productFiltered ? ["actual"] : ["actual", "booked"]} testId="cashflow-card"
        subtitle={m.productFiltered
          ? <span data-testid="cashflow-scope">By {m.cashFlow.granularity}. {WHOLE_ORDER_NOTE}; booked sales are hidden because they would cover the selected product only.</span>
          : `By ${m.cashFlow.granularity}.`}
        chart={<CashFlowChart data={pts} showBooked={!m.productFiltered} />}
        table={<DataTable rows={[...pts].reverse()} rowKey={(p) => p.bucket} maxRows={20} columns={[
          { key: "bucket", header: "Period", primary: true, render: (p) => p.label },
          ...(m.productFiltered ? [] : [{ key: "booked", header: "Booked", align: "right" as const, render: (p: (typeof pts)[number]) => usd(p.bookedCents) }]),
          { key: "cash", header: "Cash received", align: "right", render: (p) => usd(p.cashInCents) },
          { key: "cum", header: "Cumulative cash", align: "right", render: (p) => usd(p.cumulativeCashCents) },
        ]} />}
        note={<MethodNote>
          <p>EFZ records money coming in (payments) but no expenses, so this shows inflows only. Nothing is estimated for outflows.</p>
          <p>Booked uses the order date; cash uses the payment date, so the two need not match in any one bucket.</p>
        </MethodNote>} />
    </SectionCard>
  );
}

const productColumns: Column<ProductProfitRow>[] = [
  { key: "product", header: "Product", primary: true, render: (r) => <span className="font-semibold text-slate-800">{r.productName}</span> },
  { key: "units", header: "Units", align: "right", render: (r) => num(r.units) },
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
      <SectionCard id="profitability" title="Profitability" subtitle="Cost, gross profit and margin.">
        <p className="py-6 text-center text-xs text-slate-500" data-testid="profit-withheld">Cost and profit are not available to your account.</p>
      </SectionCard>
    );
  }
  const c = m.current;
  return (
    <SectionCard id="profitability" title="Profitability" subtitle={`Lines booked in the period, at the unit cost frozen when each was sold.`}>
      <div className="mb-4 grid grid-cols-2 gap-2 sm:grid-cols-4">
        <StatTile label="Revenue (booked)" basis="booked" value={usd(c.bookedCents)} />
        <StatTile label="Cost" basis="booked" value={usd(c.costCents)} />
        <StatTile label="Gross profit" basis="booked" value={usd(c.grossProfitCents)} />
        <StatTile label="Gross margin" basis="booked" value={pct(c.marginPct)} />
      </div>
      <div className="grid gap-4 lg:grid-cols-2">
        <ChartCard title="Gross profit by product" basis={["booked"]} testId="product-profit-card"
          chart={m.products.length ? <ProductProfitChart rows={m.products} /> : <p className="py-6 text-center text-xs text-slate-400">No sales in this period.</p>}
          table={<DataTable rows={m.products} rowKey={(r) => r.productKey} columns={productColumns.slice(0, 6)} />} />
        <div className="rounded-xl border border-slate-200 p-3 sm:p-4">
          <h3 className="mb-2 text-sm font-bold text-slate-800">Product profitability</h3>
          <DataTable testId="product-profit-table" rows={m.products} rowKey={(r) => r.productKey} columns={productColumns} maxRows={10} />
        </div>
      </div>
      <div className="mt-3">
        <MethodNote>
          <p>Cost is order_items.line_cost: quantity × the unit cost recorded when the line was sold (historical_unit_cost). Later changes to a product&apos;s cost never rewrite past profit.</p>
          <p>&quot;At no cost&quot; lines have a recorded cost of 0, so their profit is overstated. Gross profit is before commissions and any other expense.</p>
        </MethodNote>
      </div>
    </SectionCard>
  );
}

const checkIcon = (c: ReconciliationCheck) =>
  !c.available ? <MinusCircle className="h-4 w-4 text-slate-300" /> : c.count === 0 ? <CheckCircle2 className="h-4 w-4 text-emerald-600" /> : <AlertTriangle className={cn("h-4 w-4", c.severity === "FAIL" ? "text-rose-600" : "text-amber-500")} />;

export function ReconciliationSection({ m }: { m: FinanceModel }) {
  const failing = m.reconciliation.filter((c) => c.available && c.count > 0 && c.severity === "FAIL").length;
  return (
    <SectionCard id="reconciliation" title="Reconciliation" subtitle={failing ? `${failing} integrity check${failing === 1 ? "" : "s"} failing.` : "Every order you can see, whatever the filters."}>
      <ul className="divide-y divide-slate-100" data-testid="reconciliation-list">
        {m.reconciliation.map((c) => (
          <li key={c.key} className="flex items-start gap-2 py-2" data-check={c.key} data-count={c.available ? c.count : undefined}>
            <span className="mt-0.5">{checkIcon(c)}</span>
            <div className="min-w-0 flex-1">
              <p className="text-xs font-semibold text-slate-800">{c.label}</p>
              {!c.available && <p className="text-[11px] text-slate-400">Needs cost, which is not available to your account.</p>}
              {c.available && c.count > 0 && (
                <p className="break-words text-[11px] text-slate-500">
                  {c.orderIds.slice(0, 8).join(", ")}{c.orderIds.length > 8 ? ` and ${c.orderIds.length - 8} more` : ""}
                </p>
              )}
            </div>
            {c.available && (
              <span className={cn("shrink-0 rounded-full px-2 py-px text-[10px] font-bold",
                c.count === 0 ? "bg-emerald-50 text-emerald-700" : c.severity === "FAIL" ? "bg-rose-50 text-rose-700" : "bg-amber-50 text-amber-800")}>
                {c.count === 0 ? "OK" : `${c.count} ${c.severity === "FAIL" ? "mismatch" : "to review"}`}
              </span>
            )}
          </li>
        ))}
      </ul>
      <div className="mt-3">
        <MethodNote>
          <p>The same integrity rules as the database&apos;s validate_financials check, re-run in the browser over the orders you can see: order totals, costs and profit against their lines; amount paid against the payments; balance = total − paid.</p>
          <p>&quot;To review&quot; items are real business states (for example a delivered order not yet fully paid), not data errors. This page reads only; nothing is corrected here.</p>
        </MethodNote>
      </div>
    </SectionCard>
  );
}
