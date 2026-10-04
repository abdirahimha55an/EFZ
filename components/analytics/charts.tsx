"use client";

/**
 * Recharts views of the analytics model. Loaded on the client only (see
 * next/dynamic in the sections). Every chart receives data already computed by
 * lib/analytics; nothing is calculated here except unit conversion.
 */

import {
  Bar, BarChart, CartesianGrid, Cell, ComposedChart, Legend, Line, LineChart, ReferenceLine,
  ResponsiveContainer, Tooltip, XAxis, YAxis,
} from "recharts";
import { fromCents } from "@/lib/analytics/dataset";
import type { CumulativePoint, SeriesPoint } from "@/lib/analytics/sales";
import type { ProductRow } from "@/lib/analytics/products";
import type { Concentration, NewReturningPoint } from "@/lib/analytics/customers";
import type { OfficerRow } from "@/lib/analytics/officers";
import type { PipelineStatusRow } from "@/lib/analytics/pipeline";
import { STATUS_LABEL } from "@/lib/analytics/pipeline";
import type { StockRow } from "@/lib/analytics/inventory";
import type { WeeklyPoint } from "@/lib/analytics/outlook";
import { STOCK_OUT_ALERT_DAYS } from "@/lib/analytics/inventory";

const C = {
  delivered: "#10B981",
  booked: "#1F2F5E",
  bookedFill: "#C7D2FE",
  previous: "#94A3B8",
  indicative: "#D97706",
  grid: "#E2E8F0",
  axis: "#64748B",
  committed: "#6366F1",
};

const usd = (v: unknown) => `$${Number(v ?? 0).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const usdShort = (v: unknown) => {
  const n = Number(v ?? 0);
  return Math.abs(n) >= 1000 ? `$${(n / 1000).toFixed(1)}k` : `$${n.toFixed(0)}`;
};
const axis = { stroke: C.axis, fontSize: 10, tickLine: false, axisLine: false } as const;
const tooltipStyle = { contentStyle: { fontSize: 11, borderRadius: 8, borderColor: "#E2E8F0" }, labelStyle: { fontWeight: 700, color: "#0F172A" } };
const H = 260;

export function SalesTrendChart({ data, metric }: { data: SeriesPoint[]; metric: "revenue" | "units" }) {
  const rows = data.map((p) => ({
    label: p.label,
    booked: metric === "revenue" ? fromCents(p.bookedCents) : p.bookedUnits,
    delivered: metric === "revenue" ? fromCents(p.deliveredCents) : p.deliveredUnits,
  }));
  const fmt = metric === "revenue" ? usd : (v: unknown) => `${v} balls`;
  return (
    <ResponsiveContainer width="100%" height={H}>
      <BarChart data={rows} margin={{ top: 8, right: 4, left: -8, bottom: 0 }} barGap={-14}>
        <CartesianGrid stroke={C.grid} vertical={false} />
        <XAxis dataKey="label" {...axis} minTickGap={16} />
        <YAxis {...axis} tickFormatter={metric === "revenue" ? usdShort : undefined} allowDecimals={false} width={48} />
        <Tooltip {...tooltipStyle} formatter={(v, n) => [fmt(v), n === "booked" ? "Booked" : "Delivered (actual)"]} />
        <Legend wrapperStyle={{ fontSize: 11 }} formatter={(v) => (v === "booked" ? "Booked" : "Delivered (actual)")} />
        <Bar dataKey="booked" fill={C.bookedFill} stroke={C.booked} strokeWidth={1} radius={[3, 3, 0, 0]} maxBarSize={22} />
        <Bar dataKey="delivered" fill={C.delivered} radius={[3, 3, 0, 0]} maxBarSize={14} />
      </BarChart>
    </ResponsiveContainer>
  );
}

export function CumulativeChart({ data }: { data: CumulativePoint[] }) {
  const rows = data.map((p) => ({
    day: p.day,
    current: p.currentCents === null ? null : fromCents(p.currentCents),
    previous: p.previousCents === null ? null : fromCents(p.previousCents),
    projected: p.projectedCents === null ? null : fromCents(p.projectedCents),
  }));
  const names: Record<string, string> = { current: "This month (booked)", previous: "Last month (booked)", projected: "Indicative pace" };
  return (
    <ResponsiveContainer width="100%" height={H}>
      <LineChart data={rows} margin={{ top: 8, right: 8, left: -8, bottom: 0 }}>
        <CartesianGrid stroke={C.grid} vertical={false} />
        <XAxis dataKey="day" {...axis} tickFormatter={(d) => `${d}`} />
        <YAxis {...axis} tickFormatter={usdShort} width={48} />
        <Tooltip {...tooltipStyle} labelFormatter={(d) => `Day ${d}`} formatter={(v, n) => [usd(v), names[String(n)] ?? String(n)]} />
        <Legend wrapperStyle={{ fontSize: 11 }} formatter={(v) => names[String(v)] ?? v} />
        <Line type="monotone" dataKey="previous" stroke={C.previous} strokeWidth={1.5} dot={false} connectNulls={false} />
        <Line type="monotone" dataKey="current" stroke={C.booked} strokeWidth={2.5} dot={false} connectNulls={false} />
        <Line type="monotone" dataKey="projected" stroke={C.indicative} strokeWidth={2} strokeDasharray="5 4" dot={false} connectNulls={false} />
      </LineChart>
    </ResponsiveContainer>
  );
}

export function ProductMixChart({ rows, metric }: { rows: ProductRow[]; metric: "revenue" | "units" }) {
  const data = rows.slice(0, 12).map((p) => ({ name: p.name, value: metric === "revenue" ? fromCents(p.bookedCents) : p.bookedUnits, share: p.sharePct }));
  return (
    <ResponsiveContainer width="100%" height={Math.max(160, data.length * 34 + 30)}>
      <BarChart data={data} layout="vertical" margin={{ top: 4, right: 16, left: 4, bottom: 0 }}>
        <CartesianGrid stroke={C.grid} horizontal={false} />
        <XAxis type="number" {...axis} tickFormatter={metric === "revenue" ? usdShort : undefined} allowDecimals={false} />
        <YAxis type="category" dataKey="name" {...axis} width={110} tickFormatter={(n: string) => (n.length > 18 ? `${n.slice(0, 17)}…` : n)} />
        <Tooltip {...tooltipStyle} formatter={(v) => [metric === "revenue" ? usd(v) : `${v} balls`, metric === "revenue" ? "Booked revenue" : "Booked units"]} />
        <Bar dataKey="value" fill={C.booked} radius={[0, 4, 4, 0]} maxBarSize={20} />
      </BarChart>
    </ResponsiveContainer>
  );
}

export function PriceRealizationChart({ rows }: { rows: ProductRow[] }) {
  const data = rows.filter((p) => p.avgListPriceCents !== null).slice(0, 12).map((p) => ({
    name: p.name,
    list: fromCents(p.avgListPriceCents ?? 0),
    actual: fromCents(Math.round(p.actualOnListCents / Math.max(1, p.listUnits))),
  }));
  return (
    <ResponsiveContainer width="100%" height={H}>
      <BarChart data={data} margin={{ top: 8, right: 4, left: -8, bottom: 0 }}>
        <CartesianGrid stroke={C.grid} vertical={false} />
        <XAxis dataKey="name" {...axis} tickFormatter={(n: string) => (n.length > 12 ? `${n.slice(0, 11)}…` : n)} />
        <YAxis {...axis} tickFormatter={usdShort} width={48} />
        <Tooltip {...tooltipStyle} formatter={(v, n) => [usd(v), n === "list" ? "Average list price" : "Average price charged"]} />
        <Legend wrapperStyle={{ fontSize: 11 }} formatter={(v) => (v === "list" ? "Average list price" : "Average price charged")} />
        <Bar dataKey="list" fill={C.previous} radius={[3, 3, 0, 0]} maxBarSize={22} />
        <Bar dataKey="actual" fill={C.booked} radius={[3, 3, 0, 0]} maxBarSize={22} />
      </BarChart>
    </ResponsiveContainer>
  );
}

export function ParetoChart({ data }: { data: Concentration["pareto"] }) {
  const rows = data.map((d) => ({ name: d.name, revenue: fromCents(d.bookedCents), cumulative: Math.round(d.cumulativePct * 10) / 10 }));
  return (
    <ResponsiveContainer width="100%" height={H}>
      <ComposedChart data={rows} margin={{ top: 8, right: 0, left: -8, bottom: 0 }}>
        <CartesianGrid stroke={C.grid} vertical={false} />
        <XAxis dataKey="name" {...axis} interval={0} tickFormatter={(n: string) => (n.length > 10 ? `${n.slice(0, 9)}…` : n)} />
        <YAxis yAxisId="l" {...axis} tickFormatter={usdShort} width={48} />
        <YAxis yAxisId="r" orientation="right" {...axis} domain={[0, 100]} tickFormatter={(v) => `${v}%`} width={36} />
        <Tooltip {...tooltipStyle} formatter={(v, n) => (n === "revenue" ? [usd(v), "Booked revenue"] : [`${v}%`, "Cumulative share"])} />
        <Bar yAxisId="l" dataKey="revenue" fill={C.booked} radius={[3, 3, 0, 0]} maxBarSize={28} />
        <Line yAxisId="r" type="monotone" dataKey="cumulative" stroke={C.indicative} strokeWidth={2} dot={{ r: 2 }} />
      </ComposedChart>
    </ResponsiveContainer>
  );
}

export function NewReturningChart({ data }: { data: NewReturningPoint[] }) {
  return (
    <ResponsiveContainer width="100%" height={H}>
      <BarChart data={data} margin={{ top: 8, right: 4, left: -16, bottom: 0 }}>
        <CartesianGrid stroke={C.grid} vertical={false} />
        <XAxis dataKey="label" {...axis} minTickGap={16} />
        <YAxis {...axis} allowDecimals={false} width={40} />
        <Tooltip {...tooltipStyle} formatter={(v, n) => [`${v}`, n === "newCustomers" ? "New customers" : "Returning customers"]} />
        <Legend wrapperStyle={{ fontSize: 11 }} formatter={(v) => (v === "newCustomers" ? "New" : "Returning")} />
        <Bar dataKey="returningCustomers" stackId="c" fill={C.booked} maxBarSize={22} />
        <Bar dataKey="newCustomers" stackId="c" fill={C.delivered} radius={[3, 3, 0, 0]} maxBarSize={22} />
      </BarChart>
    </ResponsiveContainer>
  );
}

export function OfficerChart({ rows }: { rows: OfficerRow[] }) {
  const data = rows.map((r) => ({ name: r.name, booked: fromCents(r.bookedCents), delivered: fromCents(r.deliveredCents) }));
  return (
    <ResponsiveContainer width="100%" height={Math.max(160, data.length * 44 + 40)}>
      <BarChart data={data} layout="vertical" margin={{ top: 4, right: 16, left: 4, bottom: 0 }}>
        <CartesianGrid stroke={C.grid} horizontal={false} />
        <XAxis type="number" {...axis} tickFormatter={usdShort} />
        <YAxis type="category" dataKey="name" {...axis} width={110} />
        <Tooltip {...tooltipStyle} formatter={(v, n) => [usd(v), n === "booked" ? "Booked" : "Delivered (actual)"]} />
        <Legend wrapperStyle={{ fontSize: 11 }} formatter={(v) => (v === "booked" ? "Booked" : "Delivered (actual)")} />
        <Bar dataKey="booked" fill={C.bookedFill} stroke={C.booked} radius={[0, 3, 3, 0]} maxBarSize={14} />
        <Bar dataKey="delivered" fill={C.delivered} radius={[0, 3, 3, 0]} maxBarSize={14} />
      </BarChart>
    </ResponsiveContainer>
  );
}

export function PipelineStatusChart({ rows, metric }: { rows: PipelineStatusRow[]; metric: "revenue" | "units" }) {
  const data = rows.map((r) => ({ name: STATUS_LABEL[r.status], value: metric === "revenue" ? fromCents(r.remainingCents) : r.remainingUnits, orders: r.orders }));
  return (
    <ResponsiveContainer width="100%" height={200}>
      <BarChart data={data} layout="vertical" margin={{ top: 4, right: 16, left: 4, bottom: 0 }}>
        <CartesianGrid stroke={C.grid} horizontal={false} />
        <XAxis type="number" {...axis} tickFormatter={metric === "revenue" ? usdShort : undefined} allowDecimals={false} />
        <YAxis type="category" dataKey="name" {...axis} width={120} />
        <Tooltip {...tooltipStyle} formatter={(v) => [metric === "revenue" ? usd(v) : `${v} balls`, "Still to deliver"]} />
        <Bar dataKey="value" fill={C.committed} radius={[0, 4, 4, 0]} maxBarSize={20} />
      </BarChart>
    </ResponsiveContainer>
  );
}

export function WeeklyVelocityChart({ data }: { data: WeeklyPoint[] }) {
  const rows = data.map((w) => ({ label: w.partial ? `${w.label} (so far)` : w.label, units: w.bookedUnits, partial: w.partial }));
  return (
    <ResponsiveContainer width="100%" height={200}>
      <BarChart data={rows} margin={{ top: 8, right: 4, left: -16, bottom: 0 }}>
        <CartesianGrid stroke={C.grid} vertical={false} />
        <XAxis dataKey="label" {...axis} minTickGap={8} tickFormatter={(l: string) => l.replace("Wk of ", "")} />
        <YAxis {...axis} allowDecimals={false} width={40} />
        <Tooltip {...tooltipStyle} formatter={(v) => [`${v} balls`, "Booked units"]} />
        <Bar dataKey="units" radius={[3, 3, 0, 0]} maxBarSize={26}>
          {rows.map((r) => <Cell key={r.label} fill={r.partial ? C.bookedFill : C.booked} />)}
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  );
}

export function StockCoverChart({ rows }: { rows: StockRow[] }) {
  const cap = 90;
  const data = rows.slice(0, 12).map((s) => ({
    name: s.name,
    days: s.daysOfCover === null ? null : Math.min(cap, Math.round(s.daysOfCover * 10) / 10),
    real: s.daysOfCover,
    state: s.state,
  }));
  return (
    <ResponsiveContainer width="100%" height={Math.max(160, data.length * 34 + 30)}>
      <BarChart data={data} layout="vertical" margin={{ top: 4, right: 16, left: 4, bottom: 0 }}>
        <CartesianGrid stroke={C.grid} horizontal={false} />
        <XAxis type="number" {...axis} domain={[0, cap]} tickFormatter={(v) => `${v}d`} />
        <YAxis type="category" dataKey="name" {...axis} width={110} tickFormatter={(n: string) => (n.length > 18 ? `${n.slice(0, 17)}…` : n)} />
        <Tooltip {...tooltipStyle} formatter={(_v, _n, item) => {
          const real = (item?.payload as { real: number | null } | undefined)?.real;
          return [real === null || real === undefined ? "No recent demand" : `${Math.floor(real)} days (indicative)`, "Days of cover"];
        }} />
        <ReferenceLine x={STOCK_OUT_ALERT_DAYS} stroke={C.indicative} strokeDasharray="4 3" label={{ value: `${STOCK_OUT_ALERT_DAYS}d`, fontSize: 10, fill: C.indicative, position: "top" }} />
        <Bar dataKey="days" radius={[0, 4, 4, 0]} maxBarSize={18}>
          {data.map((d) => <Cell key={d.name} fill={d.state === "ok" || d.state === "slow" ? C.delivered : d.state === "at_risk" || d.state === "low" ? C.indicative : "#DC2626"} />)}
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  );
}
