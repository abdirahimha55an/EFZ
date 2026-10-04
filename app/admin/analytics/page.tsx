"use client";

/**
 * Sales & Analytics: sales performance, products, customers, Marketing Officer
 * breakdown, pipeline, an honest sales outlook and sales-driven stock cover.
 *
 * Every figure comes from lib/analytics (buildAnalyticsModel), the same model
 * the Business Assistant and the Excel export use. Detailed finance (profit,
 * collections, balances, payment analysis) belongs to the Financial page; only
 * Cash Received is shown here. Payments are recorded from the order, not here.
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import { AlertCircle, Download, Loader2, RefreshCw, Shield, Sparkles } from "lucide-react";
import { cn } from "@/lib/utils";
import type { AdminProfile, Customer, Order, Product } from "@/lib/types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";
import { efzToday, formatEfzTime } from "@/lib/dates";
import { NO_FILTERS, UNASSIGNED_OFFICER, buildDataset, productKeyOf, type SalesFilters } from "@/lib/analytics/dataset";
import { buildAnalyticsModel } from "@/lib/analytics/model";
import { monthStart, type PeriodPreset } from "@/lib/analytics/period";
import { officersOnOrders } from "@/lib/analytics/officers";
import { analyticsExportFileName, analyticsExportMetadata, buildAnalyticsSheets, buildAnalyticsWorkbook, type FilterLabels } from "@/lib/analytics/export";
import { Controls, type Option } from "@/components/analytics/Controls";
import { KpiStrip } from "@/components/analytics/KpiStrip";
import { BasisLegend } from "@/components/analytics/primitives";
import { AttentionPanel, CustomersSection, OfficersSection, ProductsSection, TrendsSection } from "@/components/analytics/SalesSections";
import { InventorySection, PipelineOutlookSection } from "@/components/analytics/OutlookSections";
import { AssistantPanel } from "@/components/analytics/AssistantPanel";

type Loaded = { orders: Order[]; products: Product[]; customers: Customer[]; today: string; loadedAt: string };
type ExportState = { busy: boolean; message: string | null; error: boolean };

export default function AnalyticsPage() {
  const [profile, setProfile] = useState<AdminProfile | null>(null);
  const [data, setData] = useState<Loaded | null>(null);
  const [status, setStatus] = useState<"loading" | "ready" | "error" | "denied">("loading");
  const [loadError, setLoadError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [reloadKey, setReloadKey] = useState(0);

  const [preset, setPreset] = useState<PeriodPreset>("month");
  const [custom, setCustom] = useState(() => { const t = efzToday(); return { from: monthStart(t), to: t }; });
  const [compare, setCompare] = useState(true);
  const [filters, setFilters] = useState<SalesFilters>(NO_FILTERS);
  const [assistantOpen, setAssistantOpen] = useState(false);
  const [exportState, setExportState] = useState<ExportState>({ busy: false, message: null, error: false });

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const db = getDb();
        const me = await db.auth.getProfile();
        if (cancelled) return;
        setProfile(me);
        if (!me || !derivePermissions(me).viewReports) {
          setStatus("denied");
          return;
        }
        const [orders, products, customers] = await Promise.all([
          db.orders.listAll(),
          db.products.list(),
          db.customers.list({ includeArchived: true }),
        ]);
        if (cancelled) return;
        setData({ orders, products, customers, today: efzToday(), loadedAt: new Date().toISOString() });
        setLoadError(null);
        setStatus("ready");
      } catch (error) {
        if (cancelled) return;
        setLoadError(describeDbError(error));
        setStatus("error");
      } finally {
        if (!cancelled) setRefreshing(false);
      }
    })();
    return () => { cancelled = true; };
  }, [reloadKey]);

  const perms = derivePermissions(profile);
  const ds = useMemo(() => (data ? buildDataset(data.orders, data.products, data.customers) : null), [data]);
  // An officer filter is meaningless without the officer breakdown.
  const effectiveFilters = useMemo(() => (perms.allOrderScope ? filters : { ...filters, officerId: null }), [filters, perms.allOrderScope]);
  const model = useMemo(
    () => (ds && data ? buildAnalyticsModel({ ds, filters: effectiveFilters, preset, custom, compare, today: data.today }) : null),
    [ds, data, effectiveFilters, preset, custom, compare]
  );

  const options = useMemo(() => {
    if (!ds) return { products: [] as Option[], customers: [] as Option[], officers: [] as Option[] };
    const products = new Map<string, string>();
    for (const p of ds.products) products.set(productKeyOf(p.id, p.name), p.name);
    for (const o of ds.orders) for (const l of o.lines) if (!products.has(l.productKey)) products.set(l.productKey, l.productName);
    const nameCount = new Map<string, number>();
    for (const c of ds.customers) nameCount.set(c.name, (nameCount.get(c.name) ?? 0) + 1);
    return {
      products: [...products.entries()].map(([value, label]) => ({ value, label })).sort((a, b) => a.label.localeCompare(b.label)),
      // Same-name customers are told apart by their ID; the filter is always by ID.
      customers: ds.customers.map((c) => ({ value: c.id, label: (nameCount.get(c.name) ?? 0) > 1 ? `${c.name} (${c.id})` : c.name })).sort((a, b) => a.label.localeCompare(b.label)),
      officers: officersOnOrders(ds).map((o) => ({ value: o.id, label: o.name })),
    };
  }, [ds]);

  const filterLabels = useCallback((): FilterLabels => {
    const find = (opts: Option[], v: string | null) => (v === null ? "All" : opts.find((o) => o.value === v)?.label ?? v);
    return {
      product: find(options.products, effectiveFilters.productKey),
      customer: find(options.customers, effectiveFilters.customerId),
      officer: effectiveFilters.officerId === UNASSIGNED_OFFICER ? "Unassigned" : find(options.officers, effectiveFilters.officerId),
      orderType: effectiveFilters.orderType === "all" ? "Regular and trial" : effectiveFilters.orderType === "trial" ? "Trial" : "Regular",
      status: effectiveFilters.status === "all" ? "All (not cancelled)" : effectiveFilters.status === "open" ? "Open" : "Fully delivered",
    };
  }, [options, effectiveFilters]);

  /** Excel export of exactly what is on screen. Recorded in the audit trail BEFORE the download (Phase 12 rule). */
  const exportExcel = useCallback(async () => {
    if (!model) return;
    setExportState({ busy: true, message: null, error: false });
    try {
      const labels = filterLabels();
      const sheets = buildAnalyticsSheets(model, labels, { includeOfficers: perms.allOrderScope, generatedAt: `${model.today} ${formatEfzTime(new Date())}` });
      const bytes = buildAnalyticsWorkbook(sheets);
      const fileName = analyticsExportFileName(model);
      try {
        await getDb().logs.write({
          category: "SYSTEM",
          severity: "INFO",
          message: `Sales analytics exported to Excel: ${model.periodText}`,
          metadata: analyticsExportMetadata(model, fileName, labels, sheets),
        });
      } catch (error) {
        setExportState({ busy: false, message: `Export cancelled: the export could not be recorded in the audit trail (${describeDbError(error)}). Nothing was downloaded.`, error: true });
        return;
      }
      const blob = new Blob([bytes as BlobPart], { type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" });
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = fileName;
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      window.setTimeout(() => URL.revokeObjectURL(url), 1000);
      setExportState({ busy: false, message: `Exported to ${fileName}.`, error: false });
    } catch (error) {
      setExportState({ busy: false, message: describeDbError(error), error: true });
    }
  }, [model, filterLabels, perms.allOrderScope]);

  if (status === "loading") {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400">
        <Loader2 className="h-6 w-6 animate-spin text-brand-blue" />
        <p className="text-xs font-medium">Building report…</p>
      </div>
    );
  }
  if (status === "denied") {
    return (
      <div className="flex min-h-[60vh] flex-col items-center justify-center space-y-4" data-testid="analytics-denied">
        <Shield className="h-16 w-16 text-slate-300" />
        <h2 className="text-xl font-bold text-slate-700">Access Denied</h2>
        <p className="text-slate-500">You do not have permission to view Sales &amp; Analytics.</p>
      </div>
    );
  }
  if (status === "error" || !model || !ds || !data) {
    return (
      <div className="flex flex-col items-center gap-3 rounded-xl border border-slate-200 bg-white py-16 text-center">
        <AlertCircle className="h-8 w-8 text-red-500" />
        <h2 className="text-lg font-bold text-slate-900">Could not build the report</h2>
        <p className="max-w-md text-xs text-slate-500">{loadError ?? "Unknown error."}</p>
      </div>
    );
  }

  const velocityByProduct = new Map(model.stock.map((s) => [s.productKey, s.velocity28]));

  return (
    <div className="space-y-5 pb-12" data-testid="analytics-page">
      <header className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-slate-900 sm:text-3xl">Sales &amp; Analytics</h1>
          <p className="mt-1 text-xs text-slate-500">Sales performance, pipeline and an honest outlook. Data as of {formatEfzTime(data.loadedAt)}.</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <button type="button" onClick={() => { setRefreshing(true); setReloadKey((k) => k + 1); }} disabled={refreshing}
            className="inline-flex h-9 items-center gap-1.5 rounded-xl border border-slate-200 bg-white px-3 text-xs font-semibold text-slate-700 shadow-sm hover:bg-slate-50 disabled:opacity-60">
            <RefreshCw className={cn("h-3.5 w-3.5", refreshing && "animate-spin")} /> Refresh
          </button>
          <button type="button" data-testid="assistant-open" onClick={() => setAssistantOpen(true)}
            className="inline-flex h-9 items-center gap-1.5 rounded-xl border border-slate-200 bg-white px-3 text-xs font-semibold text-slate-700 shadow-sm hover:bg-slate-50">
            <Sparkles className="h-3.5 w-3.5 text-emerald-600" /> Assistant
          </button>
          <button type="button" data-testid="analytics-export" onClick={exportExcel} disabled={exportState.busy}
            className="inline-flex h-9 items-center gap-1.5 rounded-xl bg-slate-900 px-3 text-xs font-semibold text-white shadow-sm hover:bg-slate-800 disabled:opacity-60">
            {exportState.busy ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Download className="h-3.5 w-3.5" />} Export to Excel
          </button>
        </div>
      </header>
      {exportState.message && (
        <p data-testid="analytics-export-message" className={cn("rounded-lg px-3 py-2 text-xs", exportState.error ? "bg-rose-50 text-rose-800" : "bg-emerald-50 text-emerald-800")}>{exportState.message}</p>
      )}

      <Controls
        preset={preset} onPreset={setPreset}
        custom={custom} onCustom={setCustom}
        compare={compare} onCompare={setCompare}
        filters={effectiveFilters} onFilters={setFilters}
        products={options.products} customers={options.customers}
        officers={perms.allOrderScope ? options.officers : null}
        periodText={model.periodText}
        comparisonText={model.comparison ? `${model.comparison.label.toLowerCase()} (${model.comparison.text})` : null}
      />
      <BasisLegend />

      <KpiStrip m={model} />
      <AttentionPanel m={model} />
      <TrendsSection m={model} />
      <ProductsSection m={model} velocityByProduct={velocityByProduct} />
      <CustomersSection m={model} />
      {perms.allOrderScope && <OfficersSection m={model} />}
      <PipelineOutlookSection m={model} />
      <InventorySection m={model} />

      <AssistantPanel
        open={assistantOpen}
        onClose={() => setAssistantOpen(false)}
        ctx={{ ds, filters: effectiveFilters, preset, custom, today: data.today, model, canSeeOfficers: perms.allOrderScope }}
      />
    </div>
  );
}
