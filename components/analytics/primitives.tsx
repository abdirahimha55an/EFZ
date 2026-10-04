"use client";

import { useState, type ReactNode } from "react";
import { BarChart3, ChevronDown, Info, Table2 } from "lucide-react";
import { cn } from "@/lib/utils";
import { money } from "@/lib/commission";
import { fromCents } from "@/lib/analytics/dataset";

export type Basis = "actual" | "booked" | "committed" | "indicative";

/** Display helpers (cents in, text out). */
export const usd = (cents: number | null | undefined) => (cents === null || cents === undefined ? "—" : money(fromCents(cents)));
export const pct = (v: number | null | undefined, digits = 1) => (v === null || v === undefined ? "—" : `${v.toFixed(digits)}%`);
export const num = (v: number | null | undefined, digits = 0) => (v === null || v === undefined ? "—" : v.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits }));

const BASIS_STYLE: Record<Basis, { label: string; className: string; title: string }> = {
  actual: { label: "Actual", className: "bg-emerald-600 text-white border-emerald-600", title: "Recorded fact: delivered balls or money received." },
  booked: { label: "Booked", className: "border-brand-blue/40 text-brand-blue bg-white", title: "Ordered by customers (not cancelled), delivered or not." },
  committed: { label: "Committed", className: "border-indigo-300 text-indigo-700 bg-indigo-50/60", title: "Booked but not yet delivered." },
  indicative: { label: "Indicative", className: "border-dashed border-amber-400 text-amber-800 bg-amber-50", title: "Arithmetic on the current pace. Not a statistical forecast." },
};

export function BasisBadge({ basis, className }: { basis: Basis; className?: string }) {
  const s = BASIS_STYLE[basis];
  return (
    <span title={s.title} className={cn("inline-flex items-center rounded-full border px-1.5 py-px text-[9px] font-bold uppercase tracking-wider", s.className, className)}>
      {s.label}
    </span>
  );
}

export function BasisLegend() {
  return (
    <div className="flex flex-wrap items-center gap-2 text-[10px] text-slate-500">
      {(Object.keys(BASIS_STYLE) as Basis[]).map((b) => (
        <span key={b} className="inline-flex items-center gap-1">
          <BasisBadge basis={b} />
          <span className="hidden sm:inline">{BASIS_STYLE[b].title}</span>
        </span>
      ))}
    </div>
  );
}

/** "How is this calculated?" — always one click away from the number. */
export function MethodNote({ children, label = "How is this calculated?" }: { children: ReactNode; label?: string }) {
  return (
    <details className="group text-[11px] text-slate-500">
      <summary className="inline-flex cursor-pointer list-none items-center gap-1 font-semibold text-slate-500 hover:text-slate-800">
        <Info className="h-3 w-3" />
        {label}
        <ChevronDown className="h-3 w-3 transition-transform group-open:rotate-180" />
      </summary>
      <div className="mt-1.5 space-y-1 rounded-lg bg-slate-50 p-2.5 leading-relaxed text-slate-600">{children}</div>
    </details>
  );
}

export function SectionCard({ id, title, subtitle, actions, children, className }: { id?: string; title: string; subtitle?: ReactNode; actions?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section id={id} className={cn("scroll-mt-24 rounded-2xl border border-slate-200 bg-white p-4 shadow-sm sm:p-5", className)}>
      <div className="mb-4 flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <h2 className="text-base font-bold text-slate-900">{title}</h2>
          {subtitle && <p className="mt-0.5 text-xs text-slate-500">{subtitle}</p>}
        </div>
        {actions && <div className="flex shrink-0 flex-wrap items-center gap-2">{actions}</div>}
      </div>
      {children}
    </section>
  );
}

/** A chart with a one-click switch to the same data as a table. */
export function ChartCard({ title, basis, subtitle, chart, table, note, testId }: { title: string; basis?: Basis[]; subtitle?: ReactNode; chart: ReactNode; table: ReactNode; note?: ReactNode; testId?: string }) {
  const [view, setView] = useState<"chart" | "table">("chart");
  return (
    <div className="flex min-w-0 flex-col rounded-xl border border-slate-200 p-3 sm:p-4" data-testid={testId}>
      <div className="mb-2 flex items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-1.5">
            <h3 className="text-sm font-bold text-slate-800">{title}</h3>
            {basis?.map((b) => <BasisBadge key={b} basis={b} />)}
          </div>
          {subtitle && <p className="mt-0.5 text-[11px] text-slate-500">{subtitle}</p>}
        </div>
        <div className="flex shrink-0 rounded-lg border border-slate-200 p-0.5">
          <button type="button" aria-label="Show chart" onClick={() => setView("chart")} className={cn("rounded-md p-1", view === "chart" ? "bg-slate-900 text-white" : "text-slate-500 hover:bg-slate-100")}>
            <BarChart3 className="h-3.5 w-3.5" />
          </button>
          <button type="button" aria-label="Show data table" onClick={() => setView("table")} className={cn("rounded-md p-1", view === "table" ? "bg-slate-900 text-white" : "text-slate-500 hover:bg-slate-100")}>
            <Table2 className="h-3.5 w-3.5" />
          </button>
        </div>
      </div>
      <div className="min-w-0 flex-1">{view === "chart" ? chart : table}</div>
      {note && <div className="mt-2">{note}</div>}
    </div>
  );
}

export type Column<T> = {
  key: string;
  header: string;
  align?: "left" | "right";
  render: (row: T) => ReactNode;
  /** Shown as the card title on phones. */
  primary?: boolean;
};

/** A table on tablets and desktops, stacked cards on phones (no sideways page scroll). */
export function DataTable<T>({ columns, rows, rowKey, empty = "Nothing to show for this selection.", maxRows, testId }: { columns: Column<T>[]; rows: T[]; rowKey: (row: T) => string; empty?: string; maxRows?: number; testId?: string }) {
  const [all, setAll] = useState(false);
  if (rows.length === 0) return <p className="py-6 text-center text-xs text-slate-400" data-testid={testId ? `${testId}-empty` : undefined}>{empty}</p>;
  const shown = maxRows && !all ? rows.slice(0, maxRows) : rows;
  const primary = columns.find((c) => c.primary) ?? columns[0];
  return (
    <div data-testid={testId}>
      <div className="hidden overflow-x-auto sm:block">
        <table className="w-full text-left text-xs">
          <thead>
            <tr className="border-b border-slate-200 text-[10px] uppercase tracking-wider text-slate-400">
              {columns.map((c) => (
                <th key={c.key} className={cn("whitespace-nowrap px-2 py-2 font-bold", c.align === "right" && "text-right")}>{c.header}</th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {shown.map((r) => (
              <tr key={rowKey(r)} className="hover:bg-slate-50/70" data-row={rowKey(r)}>
                {columns.map((c) => (
                  <td key={c.key} className={cn("px-2 py-2 text-slate-700", c.align === "right" && "whitespace-nowrap text-right tabular-nums")}>{c.render(r)}</td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <ul className="space-y-2 sm:hidden">
        {shown.map((r) => (
          <li key={rowKey(r)} className="rounded-lg border border-slate-200 p-2.5">
            <div className="mb-1 text-xs font-bold text-slate-800">{primary.render(r)}</div>
            <dl className="grid grid-cols-2 gap-x-3 gap-y-0.5 text-[11px]">
              {columns.filter((c) => c !== primary).map((c) => (
                <div key={c.key} className="contents">
                  <dt className="text-slate-400">{c.header}</dt>
                  <dd className="text-right font-medium text-slate-700">{c.render(r)}</dd>
                </div>
              ))}
            </dl>
          </li>
        ))}
      </ul>
      {maxRows && rows.length > maxRows && (
        <button type="button" onClick={() => setAll((v) => !v)} className="mt-2 text-[11px] font-semibold text-brand-blue hover:underline">
          {all ? "Show fewer" : `Show all ${rows.length}`}
        </button>
      )}
    </div>
  );
}

export function StatTile({ label, value, basis, hint, testId, raw }: { label: string; value: ReactNode; basis?: Basis; hint?: ReactNode; testId?: string; raw?: number | null }) {
  return (
    <div className="rounded-xl border border-slate-200 bg-slate-50/60 p-3" data-testid={testId} data-value={raw ?? undefined}>
      <div className="flex items-center justify-between gap-1">
        <p className="text-[10px] font-bold uppercase tracking-wider text-slate-500">{label}</p>
        {basis && <BasisBadge basis={basis} />}
      </div>
      <p className="mt-1 text-lg font-bold tabular-nums text-slate-900">{value}</p>
      {hint && <p className="mt-0.5 text-[11px] text-slate-500">{hint}</p>}
    </div>
  );
}

export function ChartLoading() {
  return <div className="h-64 w-full animate-pulse rounded-lg bg-slate-100" />;
}
