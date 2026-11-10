"use client";

/**
 * Financial Management: the profit chain (gross -> contribution -> net operating) and the approved-expense summary.
 * Every number comes from lib/finance/profit and lib/finance/expenses (pure, tested); these components only lay it out.
 * Shown only with explicit access: the database refuses the two cost reads otherwise, and the page never fills gaps.
 */

import { useState } from "react";
import { Loader2, ShieldAlert } from "lucide-react";
import { cn } from "@/lib/utils";
import type { ExpenseCategory, ExpenseCost } from "@/lib/types";

type CostRow = Pick<ExpenseCost, "amount" | "kind" | "expenseDate" | "categoryId" | "paidAmount">;
import { monthlyTrend, totalsByCategory } from "@/lib/finance/expenses";
import type { OrderProfitRow, ProductProfitChainRow, ProfitModel } from "@/lib/finance/profit";
import { DataTable, MethodNote, SectionCard, num, pct, usd, type Column } from "@/components/analytics/primitives";
import { InfoTip } from "./FinanceSections";

export type ProfitState =
  | { status: "loading" }
  | { status: "needs_access"; missing: string[] }
  | { status: "error"; message: string }
  | { status: "ready"; model: ProfitModel };

function Line({ label, value, sign, strong, tip, testId, note }: { label: string; value: number | null; sign?: "-" | "="; strong?: boolean; tip?: string; testId?: string; note?: string }) {
  return (
    <tr className={cn("border-b border-slate-100 last:border-0", strong && "bg-slate-50")} data-testid={testId}>
      <td className={cn("py-2 pr-3 text-xs", strong ? "font-bold text-slate-900" : "text-slate-700")}>
        <span className="mr-2 inline-block w-3 text-slate-400">{sign ?? ""}</span>{label}
        {tip && <> <InfoTip text={tip} /></>}
        {note && <span className="ml-2 rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-bold uppercase text-amber-700">{note}</span>}
      </td>
      <td className={cn("py-2 text-right text-xs tabular-nums", strong ? "font-bold text-slate-900" : "text-slate-800")} data-value={value ?? undefined}>{usd(value)}</td>
    </tr>
  );
}

const orderColumns: Column<OrderProfitRow>[] = [
  { key: "order", header: "Order", primary: true, render: (r) => <span className="font-mono text-[11px]">{r.orderId}</span> },
  { key: "customer", header: "Customer", render: (r) => r.customerName },
  { key: "date", header: "Date", render: (r) => r.date },
  { key: "rev", header: "Delivered revenue", align: "right", render: (r) => usd(r.deliveredRevenueCents) },
  { key: "gp", header: "Gross profit", align: "right", render: (r) => usd(r.grossProfitCents) },
  { key: "dir", header: "Direct expenses", align: "right", render: (r) => usd(r.directExpensesCents) },
  { key: "com", header: "Commissions", align: "right", render: (r) => usd(r.commissionsCents) },
  { key: "contrib", header: "Contribution", align: "right", render: (r) => <span className="font-semibold">{usd(r.contributionProfitCents)}</span> },
  { key: "op", header: "Operating (allocated)", align: "right", render: (r) => usd(r.allocatedOperatingCents) },
  { key: "net", header: "Net (allocated)", align: "right", render: (r) => <span className="font-semibold">{usd(r.netProfitCents)}</span> },
];

const productColumns: Column<ProductProfitChainRow>[] = [
  { key: "product", header: "Product", primary: true, render: (r) => <span className="font-semibold text-slate-800">{r.productName}</span> },
  { key: "units", header: "Delivered", align: "right", render: (r) => num(r.deliveredUnits) },
  { key: "rev", header: "Delivered revenue", align: "right", render: (r) => usd(r.deliveredRevenueCents) },
  { key: "gp", header: "Gross profit", align: "right", render: (r) => usd(r.grossProfitCents) },
  { key: "dir", header: "Direct expenses", align: "right", render: (r) => usd(r.directExpensesCents) },
  { key: "com", header: "Commissions", align: "right", render: (r) => usd(r.commissionsCents) },
  { key: "contrib", header: "Contribution", align: "right", render: (r) => <span className="font-semibold">{usd(r.contributionProfitCents)}</span> },
  { key: "op", header: "Operating (allocated)", align: "right", render: (r) => usd(r.allocatedOperatingCents) },
  { key: "net", header: "Net (allocated)", align: "right", render: (r) => <span className="font-semibold">{usd(r.netProfitCents)}</span> },
];

export function ProfitChainSection({ state, costVisible, productFiltered }: { state: ProfitState; costVisible: boolean; productFiltered: boolean }) {
  const [tab, setTab] = useState<"orders" | "products">("orders");
  const title = "Profit after expenses";
  if (!costVisible) {
    return <SectionCard id="profit-chain" title={title}><p className="py-6 text-center text-xs text-slate-500" data-testid="chain-withheld">Cost and profit are not available to your account.</p></SectionCard>;
  }
  if (state.status === "loading") {
    return <SectionCard id="profit-chain" title={title}><div className="flex justify-center py-8 text-slate-400"><Loader2 className="h-5 w-5 animate-spin" /></div></SectionCard>;
  }
  if (state.status === "needs_access") {
    return (
      <SectionCard id="profit-chain" title={title}>
        <div className="flex items-start gap-3 rounded-xl border border-slate-200 bg-slate-50 p-4 text-xs text-slate-600" data-testid="chain-needs-access">
          <ShieldAlert className="mt-0.5 h-4 w-4 shrink-0 text-slate-400" />
          <p>Contribution and net operating profit need an explicit permission that your account does not have: {state.missing.join("; ")}. Gross profit above is unchanged. Ask a Super Admin to grant the access if you need these figures.</p>
        </div>
      </SectionCard>
    );
  }
  if (state.status === "error") {
    return <SectionCard id="profit-chain" title={title}><p className="py-6 text-center text-xs text-red-600" data-testid="chain-error">Could not load expenses and commissions: {state.message}</p></SectionCard>;
  }
  const { chain, orders, products } = state.model;
  return (
    <SectionCard id="profit-chain" title={title}
      subtitle={<span className="inline-flex items-center gap-1">Gross profit, then direct order expenses and commissions, then operating expenses. Approved expenses only.
        <InfoTip text="Expenses count when APPROVED (accrual); whether and when they were paid does not change profit. Commissions come from the commission records, never from manual expenses." /></span>}>
      <table className="w-full" data-testid="chain-table">
        <tbody>
          <Line label="Delivered revenue" value={chain.deliveredRevenueCents} testId="chain-revenue" />
          <Line sign="-" label="Cost of delivered balls (COGS)" value={chain.cogsCents} testId="chain-cogs" tip="Delivered balls x the unit cost recorded when each line was sold. Inventory purchases are not expenses, so stock is never costed twice." />
          <Line sign="=" strong label="Gross profit" value={chain.grossProfitCents} testId="chain-gross" />
          <Line sign="-" label="Direct order expenses" value={chain.directExpensesCents} testId="chain-direct" tip="Approved delivery, packaging, bags and other fulfilment costs linked to orders dated in this period." />
          <Line sign="-" label="Direct expenses on cancelled orders" value={chain.cancelledOrderExpensesCents} testId="chain-cancelled" tip="Costs paid on orders that were later cancelled earned no revenue. They are shown on their own line, by expense date." />
          <Line sign="-" label="Commissions" value={chain.commissionsCents} testId="chain-commissions" tip="Non-void commissions earned in the period (by earned date), from the commission records. Not entered again as an expense." />
          <Line sign="=" strong label="Contribution profit" value={chain.contributionProfitCents} testId="chain-contribution" />
          <Line sign="-" label="Operating expenses" value={chain.operatingExpensesCents} testId="chain-operating" note={chain.allocated ? "allocated" : undefined}
            tip={chain.allocated ? `Allocated: the company's operating expenses x this selection's ${pct(chain.operatingShare * 100)} share of the period's delivered revenue.` : "Approved rent, salaries, utilities, internet, marketing, transport allowance and administration dated in this period."} />
          <Line sign="=" strong label="Net operating profit" value={chain.netOperatingProfitCents} testId="chain-net" />
        </tbody>
      </table>
      <p className="mt-2 text-[11px] text-slate-500" data-testid="chain-margins">
        Contribution margin {pct(chain.contributionMarginPct)} · Net margin {pct(chain.netMarginPct)} (of delivered revenue)
        {chain.commissionsNotYetEarnedCents > 0 && <> · {usd(chain.commissionsNotYetEarnedCents)} of commissions on these orders are not earned yet and are not deducted</>}
        {chain.commissionsUnderReviewCents > 0 && <> · {usd(chain.commissionsUnderReviewCents)} of the commissions are flagged for review</>}
      </p>
      {productFiltered && <p className="mt-1 text-[11px] font-semibold text-amber-700">Product filter: operating expenses are allocated by this product&apos;s share of delivered revenue; expenses on cancelled orders cannot be assigned to a product and are left out.</p>}

      <div className="mt-5">
        <div className="mb-2 flex items-center gap-2">
          <h3 className="mr-2 text-sm font-bold text-slate-800">Profit per {tab === "orders" ? "order" : "product"}</h3>
          {(["orders", "products"] as const).map((t) => (
            <button key={t} type="button" onClick={() => setTab(t)} data-testid={`chain-tab-${t}`}
              className={cn("rounded-full border px-3 py-1 text-[11px] font-semibold", tab === t ? "border-brand-blue bg-blue-50 text-brand-blue" : "border-slate-200 text-slate-600 hover:bg-slate-50")}>
              {t === "orders" ? "By order" : "By product"}
            </button>
          ))}
        </div>
        {tab === "orders"
          ? <DataTable testId="chain-orders" rows={orders} rowKey={(r) => r.orderId} columns={orderColumns} maxRows={15} empty="No orders in this period." />
          : <DataTable testId="chain-products" rows={products} rowKey={(r) => r.productKey} columns={productColumns} empty="Nothing delivered in this period." />}
        <p className="mt-2 text-[11px] text-slate-500">&quot;Allocated&quot; operating expenses are spread by each row&apos;s share of the period&apos;s delivered revenue, calculated on demand and never stored. Direct expenses are exact per order (per product: split by delivered revenue within the order); commissions are the order&apos;s earned commissions (per product: per-ball ones by delivered balls, others by delivered revenue).</p>
      </div>
      <MethodNote>
        Gross profit = delivered revenue - COGS (frozen unit cost). Contribution profit = gross profit - direct order expenses - direct expenses on cancelled orders - commissions.
        Net operating profit = contribution profit - operating expenses. Only approved expenses count; payment status does not change profit. Period rules: direct expenses follow
        their order&apos;s date, operating expenses their own date, commissions their earned date. Per-order rows use all earned commissions on the order, so their total can differ
        from the period figure by commissions earned in this period on orders dated earlier (and by the cancelled-order line).
      </MethodNote>
    </SectionCard>
  );
}

export function ApprovedExpensesSection({ costs, categories, range, today }: { costs: CostRow[]; categories: ExpenseCategory[]; range: { from: string; to: string }; today: string }) {
  const inPeriod = costs.filter((c) => c.expenseDate >= range.from && c.expenseDate <= range.to);
  const total = inPeriod.reduce((a, c) => a + Math.round(c.amount * 100), 0);
  const direct = inPeriod.filter((c) => c.kind === "direct_order").reduce((a, c) => a + Math.round(c.amount * 100), 0);
  const unpaid = inPeriod.reduce((a, c) => a + Math.round((c.amount - c.paidAmount) * 100), 0);
  const byCategory = totalsByCategory(inPeriod, categories);
  const trend = monthlyTrend(costs, 6, today);
  const peak = Math.max(1, ...trend.map((t) => t.totalCents));
  return (
    <SectionCard id="expenses-summary" title="Approved expenses" subtitle="Approved expenses dated in the period. Approval makes it a cost; payment is a separate record.">
      <div className="mb-4 grid grid-cols-2 gap-3 sm:grid-cols-4" data-testid="expense-kpis">
        <Mini label="Approved in period" value={usd(total)} />
        <Mini label="Direct order expenses" value={usd(direct)} />
        <Mini label="Operating expenses" value={usd(total - direct)} />
        <Mini label="Approved, not yet paid" value={usd(unpaid)} />
      </div>
      <div className="grid gap-4 lg:grid-cols-2">
        <div>
          <h3 className="mb-2 text-sm font-bold text-slate-800">By category</h3>
          <DataTable testId="expense-by-category" rows={byCategory} rowKey={(r) => r.categoryId}
            columns={[{ key: "cat", header: "Category", primary: true, render: (r) => r.name }, { key: "kind", header: "Type", render: (r) => (r.kind === "direct_order" ? "Direct order" : "Operating") }, { key: "amt", header: "Approved", align: "right", render: (r) => usd(r.cents) }]}
            empty="No approved expenses in this period." />
        </div>
        <div>
          <h3 className="mb-2 text-sm font-bold text-slate-800">Last 6 months (approved, by expense date)</h3>
          <div className="space-y-1.5" data-testid="expense-trend">
            {trend.map((t) => (
              <div key={t.month} className="flex items-center gap-2 text-[11px]">
                <span className="w-14 shrink-0 text-slate-500">{t.month}</span>
                <div className="flex h-4 flex-1 overflow-hidden rounded bg-slate-100">
                  <div className="h-full bg-brand-blue" style={{ width: `${(t.directCents / peak) * 100}%` }} title={`Direct ${usd(t.directCents)}`} />
                  <div className="h-full bg-slate-500" style={{ width: `${(t.operatingCents / peak) * 100}%` }} title={`Operating ${usd(t.operatingCents)}`} />
                </div>
                <span className="w-20 shrink-0 text-right tabular-nums text-slate-700">{usd(t.totalCents)}</span>
              </div>
            ))}
            <p className="pt-1 text-[10px] text-slate-400"><span className="mr-1 inline-block h-2 w-2 rounded-sm bg-brand-blue" />Direct order <span className="ml-2 mr-1 inline-block h-2 w-2 rounded-sm bg-slate-500" />Operating</p>
          </div>
        </div>
      </div>
    </SectionCard>
  );
}

function Mini({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border border-slate-200 bg-slate-50 p-3">
      <p className="text-[11px] font-semibold text-slate-500">{label}</p>
      <p className="mt-1 text-lg font-bold tabular-nums text-slate-900">{value}</p>
    </div>
  );
}
