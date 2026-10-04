"use client";

import { useState } from "react";
import { Calendar, Filter, X } from "lucide-react";
import { cn } from "@/lib/utils";
import { NO_FILTERS, hasNarrowingFilter, type SalesFilters } from "@/lib/analytics/dataset";
import { PERIOD_PRESETS, type PeriodPreset } from "@/lib/analytics/period";

export type Option = { value: string; label: string };

export type ControlsProps = {
  preset: PeriodPreset;
  onPreset: (p: PeriodPreset) => void;
  custom: { from: string; to: string };
  onCustom: (c: { from: string; to: string }) => void;
  compare: boolean;
  onCompare: (v: boolean) => void;
  filters: SalesFilters;
  onFilters: (f: SalesFilters) => void;
  products: Option[];
  customers: Option[];
  /** Null hides the officer filter (no all-order scope). */
  officers: Option[] | null;
  periodText: string;
  comparisonText: string | null;
};

const selectCls = "h-8 min-w-0 rounded-lg border border-slate-200 bg-white px-2 text-xs font-medium text-slate-700 shadow-sm outline-none focus:border-slate-400";

export function Controls(p: ControlsProps) {
  const [open, setOpen] = useState(false);
  const set = (patch: Partial<SalesFilters>) => p.onFilters({ ...p.filters, ...patch });
  const active = hasNarrowingFilter(p.filters);
  const label = (opts: Option[] | null, v: string | null) => opts?.find((o) => o.value === v)?.label ?? v ?? "";

  const filterFields = (
    <>
      <select aria-label="Product" data-testid="filter-product" className={selectCls} value={p.filters.productKey ?? ""} onChange={(e) => set({ productKey: e.target.value || null })}>
        <option value="">All products</option>
        {p.products.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select>
      <select aria-label="Customer" data-testid="filter-customer" className={selectCls} value={p.filters.customerId ?? ""} onChange={(e) => set({ customerId: e.target.value || null })}>
        <option value="">All customers</option>
        {p.customers.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select>
      {p.officers && (
        <select aria-label="Marketing Officer" data-testid="filter-officer" className={selectCls} value={p.filters.officerId ?? ""} onChange={(e) => set({ officerId: e.target.value || null })}>
          <option value="">All Marketing Officers</option>
          {p.officers.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
        </select>
      )}
      <select aria-label="Order type" data-testid="filter-type" className={selectCls} value={p.filters.orderType} onChange={(e) => set({ orderType: e.target.value as SalesFilters["orderType"] })}>
        <option value="all">Regular and trial</option>
        <option value="regular">Regular orders</option>
        <option value="trial">Trial orders</option>
      </select>
      <select aria-label="Delivery status" data-testid="filter-status" className={selectCls} value={p.filters.status} onChange={(e) => set({ status: e.target.value as SalesFilters["status"] })}>
        <option value="all">All orders (not cancelled)</option>
        <option value="delivered">Fully delivered only</option>
        <option value="open">Open (not fully delivered)</option>
      </select>
    </>
  );

  return (
    <div className="sticky top-0 z-20 -mx-1 space-y-2 rounded-xl border border-slate-200/80 bg-white/95 px-3 py-2.5 shadow-sm backdrop-blur">
      <div className="flex flex-wrap items-center gap-2">
        <div className="flex max-w-full flex-wrap gap-0.5 rounded-lg border border-slate-200 bg-slate-50 p-0.5">
          {PERIOD_PRESETS.map(({ key, label: l }) => (
            <button
              key={key}
              type="button"
              data-testid={`period-${key}`}
              onClick={() => p.onPreset(key)}
              className={cn("rounded-md px-2 py-1 text-[11px] font-bold transition-colors", p.preset === key ? "bg-slate-900 text-white shadow-sm" : "text-slate-600 hover:bg-white hover:text-slate-900")}
            >
              {l}
            </button>
          ))}
        </div>
        {p.preset === "custom" && (
          <div className="flex items-center gap-1">
            <input aria-label="From date" data-testid="filter-from" type="date" value={p.custom.from} onChange={(e) => p.onCustom({ ...p.custom, from: e.target.value })} className="h-8 rounded-lg border border-slate-200 px-2 text-[11px]" />
            <span className="text-[11px] text-slate-400">to</span>
            <input aria-label="To date" data-testid="filter-to" type="date" value={p.custom.to} onChange={(e) => p.onCustom({ ...p.custom, to: e.target.value })} className="h-8 rounded-lg border border-slate-200 px-2 text-[11px]" />
          </div>
        )}
        <label className="inline-flex items-center gap-1.5 text-[11px] font-semibold text-slate-600">
          <input type="checkbox" data-testid="filter-compare" checked={p.compare} onChange={(e) => p.onCompare(e.target.checked)} className="h-3.5 w-3.5 accent-slate-900" disabled={p.preset === "all"} />
          Compare
        </label>
        <button type="button" onClick={() => setOpen((v) => !v)} className="inline-flex items-center gap-1 rounded-lg border border-slate-200 px-2 py-1 text-[11px] font-bold text-slate-700 md:hidden">
          <Filter className="h-3 w-3" /> Filters{active ? " •" : ""}
        </button>
      </div>
      <div className={cn("flex-wrap items-center gap-2", open ? "grid grid-cols-1" : "hidden", "md:flex")}>
        <span className="hidden items-center gap-1 text-[10px] font-bold uppercase tracking-wider text-slate-400 md:inline-flex"><Filter className="h-3 w-3" /> Filters</span>
        {filterFields}
        {active && (
          <button type="button" data-testid="filter-reset" onClick={() => p.onFilters(NO_FILTERS)} className="text-[11px] font-bold text-slate-500 underline hover:text-slate-900">Reset</button>
        )}
      </div>
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-slate-500">
        <span className="inline-flex items-center gap-1" data-testid="period-text"><Calendar className="h-3 w-3" /> <strong className="text-slate-800">{p.periodText}</strong> (Mogadishu dates)</span>
        {p.compare && p.preset !== "all" && <span data-testid="comparison-text">vs {p.comparisonText ?? "no comparable history"}</span>}
        {active && (
          <span className="flex flex-wrap gap-1">
            {p.filters.productKey && <Chip text={label(p.products, p.filters.productKey)} onClear={() => set({ productKey: null })} />}
            {p.filters.customerId && <Chip text={label(p.customers, p.filters.customerId)} onClear={() => set({ customerId: null })} />}
            {p.filters.officerId && <Chip text={label(p.officers, p.filters.officerId)} onClear={() => set({ officerId: null })} />}
            {p.filters.orderType !== "all" && <Chip text={p.filters.orderType === "trial" ? "Trial orders" : "Regular orders"} onClear={() => set({ orderType: "all" })} />}
            {p.filters.status !== "all" && <Chip text={p.filters.status === "open" ? "Open orders" : "Fully delivered"} onClear={() => set({ status: "all" })} />}
          </span>
        )}
      </div>
    </div>
  );
}

function Chip({ text, onClear }: { text: string; onClear: () => void }) {
  return (
    <span className="inline-flex items-center gap-1 rounded-full bg-slate-100 px-2 py-0.5 text-[10px] font-semibold text-slate-700">
      {text}
      <button type="button" aria-label={`Remove ${text}`} onClick={onClear} className="text-slate-400 hover:text-slate-800"><X className="h-3 w-3" /></button>
    </span>
  );
}
