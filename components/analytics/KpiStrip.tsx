"use client";

import type { ReactNode } from "react";
import { ArrowDownRight, ArrowUpRight, Minus } from "lucide-react";
import { cn } from "@/lib/utils";
import type { AnalyticsModel } from "@/lib/analytics/model";
import { change } from "@/lib/analytics/sales";
import { BasisBadge, MethodNote, num, usd, type Basis } from "./primitives";

type Card = {
  id: string;
  label: string;
  basis: Basis;
  value: string;
  raw: number | null;
  previous: number | null | undefined;
  money: boolean;
  sub?: ReactNode;
  definition: string;
  primary?: boolean;
};

function Delta({ current, previous, money, comparisonLabel }: { current: number | null; previous: number | null | undefined; money: boolean; comparisonLabel: string | null }) {
  if (comparisonLabel === null) return null;
  if (current === null || previous === null || previous === undefined) return <p className="mt-1 text-[10px] text-slate-400">No comparable history</p>;
  const c = change(current, previous)!;
  const Icon = c.delta > 0 ? ArrowUpRight : c.delta < 0 ? ArrowDownRight : Minus;
  const abs = money ? usd(Math.abs(c.delta)) : num(Math.abs(c.delta));
  return (
    <p className={cn("mt-1 inline-flex items-center gap-0.5 text-[10px] font-semibold", c.delta > 0 ? "text-emerald-700" : c.delta < 0 ? "text-rose-700" : "text-slate-500")} title={`vs ${comparisonLabel}`}>
      <Icon className="h-3 w-3" />
      {c.delta >= 0 ? "+" : "−"}{abs}
      {c.pct !== null && <span className="font-medium">({c.pct >= 0 ? "+" : ""}{c.pct.toFixed(1)}%)</span>}
      <span className="ml-0.5 font-normal text-slate-400">vs {comparisonLabel.toLowerCase()}</span>
    </p>
  );
}

export function KpiStrip({ m }: { m: AnalyticsModel }) {
  const k = m.kpis, c = m.comparisonKpis;
  const cmpLabel = m.comparison ? m.comparison.label : null;
  const cards: Card[] = [
    { id: "delivered-revenue", label: "Delivered revenue", basis: "actual", value: usd(k.deliveredCents), raw: k.deliveredCents, previous: c?.deliveredCents, money: true, primary: true,
      sub: <>{num(k.deliveredUnits)} balls delivered</>, definition: "Delivered quantity × actual unit price, on non-cancelled orders dated in the period (order date)." },
    { id: "booked-revenue", label: "Booked revenue", basis: "booked", value: usd(k.bookedCents), raw: k.bookedCents, previous: c?.bookedCents, money: true, primary: true,
      sub: <span className="inline-flex items-center gap-1">{usd(k.undeliveredCents)} still to deliver <BasisBadge basis="committed" /></span>, definition: "Ordered quantity × actual unit price on every non-cancelled order dated in the period: pending, confirmed, processing, partially delivered and delivered." },
    { id: "orders", label: "Orders", basis: "booked", value: num(k.orders), raw: k.orders, previous: c?.orders, money: false,
      sub: <>{num(k.fullyDeliveredOrders)} fully delivered</>, definition: "Non-cancelled orders dated in the period. With a product filter: orders containing that product." },
    { id: "delivered-units", label: "Delivered units", basis: "actual", value: num(k.deliveredUnits), raw: k.deliveredUnits, previous: c?.deliveredUnits, money: false,
      sub: <>{num(k.bookedUnits)} booked</>, definition: "Balls delivered (deliveries plus recorded corrections) on orders dated in the period." },
    { id: "aov", label: "Average order value", basis: "booked", value: usd(k.aovCents), raw: k.aovCents, previous: c?.aovCents, money: true,
      definition: "Booked revenue ÷ orders." },
    { id: "buying-customers", label: "Buying customers", basis: "actual", value: num(k.buyingCustomers), raw: k.buyingCustomers, previous: c?.buyingCustomers, money: false,
      sub: <>{m.newReturning.newCustomers} new · {m.newReturning.returningCustomers} returning{k.unlinkedOrders ? ` · ${k.unlinkedOrders} order(s) without a customer record` : ""}</>, definition: "Distinct customer records (by customer ID) with an order in the period. New = first ever order falls in the period." },
  ];
  return (
    <div className="space-y-2">
      <div className="grid grid-cols-2 gap-2.5 md:grid-cols-3 xl:grid-cols-6">
        {cards.map((card) => (
          <div key={card.id} data-testid={`kpi-${card.id}`} data-value={card.raw ?? ""} className={cn("rounded-xl border bg-white p-3 shadow-sm", card.primary ? "border-slate-300" : "border-slate-200")}>
            <div className="flex items-start justify-between gap-1">
              <p className="text-[10px] font-bold uppercase tracking-wider text-slate-500">{card.label}</p>
              <BasisBadge basis={card.basis} />
            </div>
            <p className={cn("mt-1.5 font-extrabold tabular-nums tracking-tight text-slate-900", card.primary ? "text-2xl" : "text-xl")} title={card.definition}>{card.value}</p>
            {card.sub && <p className="mt-0.5 text-[10px] text-slate-500">{card.sub}</p>}
            <Delta current={card.raw} previous={card.previous} money={card.money} comparisonLabel={cmpLabel} />
          </div>
        ))}
      </div>
      <div className="flex flex-col gap-2 rounded-xl border border-slate-200 bg-slate-50/70 px-3 py-2 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex flex-wrap items-center gap-2 text-xs" data-testid="kpi-cash-received" data-value={k.cashReceivedCents ?? ""}>
          <span className="text-[10px] font-bold uppercase tracking-wider text-slate-500">Cash received</span>
          <BasisBadge basis="actual" />
          {k.cashReceivedCents === null
            ? <span className="text-slate-500">Not shown with a product filter (a payment belongs to a whole order).</span>
            : <><strong className="tabular-nums text-slate-900">{usd(k.cashReceivedCents)}</strong><span className="text-slate-500">from {k.cashPayments} payment{k.cashPayments === 1 ? "" : "s"} dated in the period</span>
              <Delta current={k.cashReceivedCents} previous={c?.cashReceivedCents} money comparisonLabel={cmpLabel} /></>}
        </div>
        <span className="text-[10px] text-slate-400">Collections, balances and payment analysis belong to the Financial page.</span>
      </div>
      <MethodNote label="KPI definitions">
        {cards.map((card) => <p key={card.id}><strong>{card.label}:</strong> {card.definition}</p>)}
        <p><strong>Cash received:</strong> payments whose payment date falls in the period, on non-cancelled orders matching the filters.</p>
        <p>Dates are Mogadishu (EAT) business dates. Cancelled orders are excluded everywhere. Comparisons use a period of the same length (for example this month to date vs the same days last month).</p>
      </MethodNote>
    </div>
  );
}
