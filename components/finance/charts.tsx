"use client";

/**
 * Recharts views of the finance model (lib/finance/model). Loaded on the client
 * only (next/dynamic in lazyCharts). Nothing is calculated here except unit
 * conversion.
 */

import { Bar, BarChart, CartesianGrid, Cell, ComposedChart, Legend, Line, ReferenceLine, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { fromCents } from "@/lib/analytics/dataset";
import type { CashFlowPoint, ProductProfitRow, Receivables } from "@/lib/finance/model";

const C = { cash: "#10B981", booked: "#1F2F5E", cumulative: "#0EA5E9", grid: "#E2E8F0", axis: "#64748B", aging: ["#10B981", "#F59E0B", "#F97316", "#E11D48"], profit: "#10B981", loss: "#E11D48" };
const usd = (v: unknown) => `$${Number(v ?? 0).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const usdShort = (v: unknown) => { const n = Number(v ?? 0); return Math.abs(n) >= 1000 ? `$${(n / 1000).toFixed(1)}k` : `$${n.toFixed(0)}`; };
const axis = { stroke: C.axis, fontSize: 10, tickLine: false, axisLine: false } as const;
const tooltipStyle = { contentStyle: { fontSize: 11, borderRadius: 8, borderColor: "#E2E8F0" }, labelStyle: { fontWeight: 700, color: "#0F172A" } };
const H = 260;
const NAMES: Record<string, string> = { cash: "Cash received (actual)", booked: "Booked sales", cumulative: "Cumulative cash" };

export function CashFlowChart({ data, showBooked = true }: { data: CashFlowPoint[]; showBooked?: boolean }) {
  const rows = data.map((p) => ({ label: p.label, cash: fromCents(p.cashInCents), booked: fromCents(p.bookedCents), cumulative: fromCents(p.cumulativeCashCents) }));
  return (
    <ResponsiveContainer width="100%" height={H}>
      <ComposedChart data={rows} margin={{ top: 8, right: 4, left: -8, bottom: 0 }}>
        <CartesianGrid stroke={C.grid} vertical={false} />
        <XAxis dataKey="label" {...axis} minTickGap={16} />
        <YAxis {...axis} tickFormatter={usdShort} width={48} />
        <Tooltip {...tooltipStyle} formatter={(v, n) => [usd(v), NAMES[String(n)] ?? String(n)]} />
        <Legend wrapperStyle={{ fontSize: 11 }} formatter={(v) => NAMES[String(v)] ?? String(v)} />
        <Bar dataKey="cash" fill={C.cash} radius={[3, 3, 0, 0]} maxBarSize={18} />
        {showBooked && <Line dataKey="booked" stroke={C.booked} strokeWidth={1.5} dot={false} type="monotone" />}
        <Line dataKey="cumulative" stroke={C.cumulative} strokeWidth={1.5} strokeDasharray="4 3" dot={false} type="monotone" />
      </ComposedChart>
    </ResponsiveContainer>
  );
}

export function AgingChart({ data }: { data: Receivables["aging"] }) {
  const rows = data.map((a) => ({ label: a.label, amount: fromCents(a.cents), orders: a.orders }));
  return (
    <ResponsiveContainer width="100%" height={H}>
      <BarChart data={rows} margin={{ top: 8, right: 4, left: -8, bottom: 0 }}>
        <CartesianGrid stroke={C.grid} vertical={false} />
        <XAxis dataKey="label" {...axis} />
        <YAxis {...axis} tickFormatter={usdShort} width={48} />
        <Tooltip {...tooltipStyle} formatter={(v) => [usd(v), "Outstanding"]} />
        <Bar dataKey="amount" radius={[3, 3, 0, 0]} maxBarSize={48}>
          {rows.map((_, i) => <Cell key={i} fill={C.aging[i] ?? C.aging[C.aging.length - 1]} />)}
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  );
}

export function ProductProfitChart({ rows }: { rows: ProductProfitRow[] }) {
  const data = rows.slice(0, 12).map((r) => ({ label: r.productName, profit: fromCents(r.profitCents) }));
  return (
    <ResponsiveContainer width="100%" height={Math.max(H, data.length * 28)}>
      <BarChart data={data} layout="vertical" margin={{ top: 4, right: 12, left: 8, bottom: 0 }}>
        <CartesianGrid stroke={C.grid} horizontal={false} />
        <XAxis type="number" {...axis} tickFormatter={usdShort} />
        <YAxis type="category" dataKey="label" {...axis} width={120} />
        <Tooltip {...tooltipStyle} formatter={(v) => [usd(v), "Gross profit"]} />
        <ReferenceLine x={0} stroke={C.axis} />
        <Bar dataKey="profit" radius={[0, 3, 3, 0]} maxBarSize={18}>
          {data.map((d, i) => <Cell key={i} fill={d.profit < 0 ? C.loss : C.profit} />)}
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  );
}
