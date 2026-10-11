"use client";

/**
 * Financial Management: cash received, receivables and aging, payment history,
 * cash flow, profitability on frozen historical costs, and reconciliation.
 *
 * Read only. Every figure comes from lib/finance/model (buildFinanceModel) over
 * the same dataset as Sales & Analytics, which stays sales-only. Payments are
 * recorded from the order, never here. Cost and profit appear only when the
 * database sends cost to this user (can_view_cost); the page never fills gaps.
 */

import { useEffect, useMemo, useState } from "react";
import { AlertCircle, Loader2, RefreshCw, Shield } from "lucide-react";
import { cn } from "@/lib/utils";
import type { AdminProfile, Customer, Order, Product } from "@/lib/types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";
import { efzToday, formatEfzTime } from "@/lib/dates";
import { NO_FILTERS, buildDataset, productKeyOf, type SalesFilters } from "@/lib/analytics/dataset";
import { monthStart, type PeriodPreset } from "@/lib/analytics/period";
import { officersOnOrders } from "@/lib/analytics/officers";
import { buildFinanceModel, receivableOrders, type ReceivableFilter } from "@/lib/finance/model";
import { Controls, type Option } from "@/components/analytics/Controls";
import { CashFlowSection, CollectionsSection, FinanceKpis, FinancialChecksSection, ProfitabilitySection, ReceivablesSection } from "@/components/finance/FinanceSections";
import { RecordPaymentDialog, canRecordPayment } from "@/components/admin/RecordPaymentDialog";

type Loaded = { orders: Order[]; products: Product[]; customers: Customer[]; today: string; loadedAt: string };

export default function FinancialPage() {
  const [profile, setProfile] = useState<AdminProfile | null>(null);
  const [data, setData] = useState<Loaded | null>(null);
  const [status, setStatus] = useState<"loading" | "ready" | "error" | "denied">("loading");
  const [loadError, setLoadError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [reloadKey, setReloadKey] = useState(0);

  const [preset, setPreset] = useState<PeriodPreset>("month");
  const [custom, setCustom] = useState(() => { const t = efzToday(); return { from: monthStart(t), to: t }; });
  const [compare, setCompare] = useState(true);
  // Customer Database links here with ?customer=<id>#receivables (read once, client side;
  // the page shows its loading state before any filter is rendered).
  const [customerFromLink] = useState<string | null>(() => (typeof window === "undefined" ? null : new URLSearchParams(window.location.search).get("customer")));
  const [filters, setFilters] = useState<SalesFilters>(() => (customerFromLink ? { ...NO_FILTERS, customerId: customerFromLink } : NO_FILTERS));
  const [receivableStatus, setReceivableStatus] = useState<ReceivableFilter>("all");
  const [paymentOrderId, setPaymentOrderId] = useState<string | null>(null);
  const [notification, setNotification] = useState<{ type: "success" | "error"; message: string } | null>(null);

  useEffect(() => {
    if (!notification) return;
    const t = setTimeout(() => setNotification(null), 3000);
    return () => clearTimeout(t);
  }, [notification]);

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
  const effectiveFilters = useMemo(() => (perms.allOrderScope ? filters : { ...filters, officerId: null }), [filters, perms.allOrderScope]);
  const model = useMemo(
    () => (ds && data ? buildFinanceModel({ ds, filters: effectiveFilters, preset, custom, compare, today: data.today }) : null),
    [ds, data, effectiveFilters, preset, custom, compare]
  );

  const orderRows = useMemo(() => (ds ? receivableOrders(ds, effectiveFilters, receivableStatus) : []), [ds, effectiveFilters, receivableStatus]);
  const paymentOrder = paymentOrderId && data ? data.orders.find((o) => o.id === paymentOrderId) ?? null : null;

  // Arriving from a customer's profile: bring the receivables into view once.
  useEffect(() => {
    if (status === "ready" && customerFromLink && window.location.hash === "#receivables") {
      document.getElementById("receivables")?.scrollIntoView({ block: "start" });
    }
  }, [status, customerFromLink]);

  const options = useMemo(() => {
    if (!ds) return { products: [] as Option[], customers: [] as Option[], officers: [] as Option[] };
    const products = new Map<string, string>();
    for (const p of ds.products) products.set(productKeyOf(p.id, p.name), p.name);
    for (const o of ds.orders) for (const l of o.lines) if (!products.has(l.productKey)) products.set(l.productKey, l.productName);
    const nameCount = new Map<string, number>();
    for (const c of ds.customers) nameCount.set(c.name, (nameCount.get(c.name) ?? 0) + 1);
    return {
      products: [...products.entries()].map(([value, label]) => ({ value, label })).sort((a, b) => a.label.localeCompare(b.label)),
      customers: ds.customers.map((c) => ({ value: c.id, label: (nameCount.get(c.name) ?? 0) > 1 ? `${c.name} (${c.id})` : c.name })).sort((a, b) => a.label.localeCompare(b.label)),
      officers: officersOnOrders(ds).map((o) => ({ value: o.id, label: o.name })),
    };
  }, [ds]);

  if (status === "loading") {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400">
        <Loader2 className="h-6 w-6 animate-spin text-brand-blue" />
        <p className="text-xs font-medium">Building financial report…</p>
      </div>
    );
  }
  if (status === "denied") {
    return (
      <div className="flex min-h-[60vh] flex-col items-center justify-center space-y-4" data-testid="financial-denied">
        <Shield className="h-16 w-16 text-slate-300" />
        <h2 className="text-xl font-bold text-slate-700">Access Denied</h2>
        <p className="text-slate-500">You do not have permission to view Financial Management.</p>
      </div>
    );
  }
  if (status === "error" || !model || !data) {
    return (
      <div className="flex flex-col items-center gap-3 rounded-xl border border-slate-200 bg-white py-16 text-center">
        <AlertCircle className="h-8 w-8 text-red-500" />
        <h2 className="text-lg font-bold text-slate-900">Could not build the financial report</h2>
        <p className="max-w-md text-xs text-slate-500">{loadError ?? "Unknown error."}</p>
      </div>
    );
  }

  return (
    <div className="space-y-6 pb-12" data-testid="financial-page">
      <header className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-slate-900 sm:text-3xl">Financial Management</h1>
          <p className="mt-1 text-xs text-slate-500">
            Cash, receivables, profitability and reconciliation{perms.allOrderScope ? "" : " for your own orders"}. Data as of {formatEfzTime(data.loadedAt)}.
          </p>
        </div>
        <button type="button" onClick={() => { setRefreshing(true); setReloadKey((k) => k + 1); }} disabled={refreshing}
          className="inline-flex h-9 items-center gap-1.5 self-start rounded-xl border border-slate-200 bg-white px-3 text-xs font-semibold text-slate-700 shadow-sm hover:bg-slate-50 disabled:opacity-60 sm:self-auto">
          <RefreshCw className={cn("h-3.5 w-3.5", refreshing && "animate-spin")} /> Refresh
        </button>
      </header>

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

      {/* Summary first (Outstanding receivables stays in the KPIs); detailed receivables management below the analysis. */}
      <FinanceKpis m={model} />
      <CollectionsSection m={model} />
      <CashFlowSection m={model} />
      <ProfitabilitySection m={model} />
      <ReceivablesSection m={model} orderRows={orderRows} status={receivableStatus} onStatus={setReceivableStatus}
        onRecordPayment={canRecordPayment(perms) ? setPaymentOrderId : undefined} />
      <FinancialChecksSection m={model} />

      {/* The same Record Payment workflow as Customer Database (record_payment() + audit line). */}
      {paymentOrder && (
        <RecordPaymentDialog
          order={paymentOrder}
          canBackdate={perms.backdate}
          onClose={() => setPaymentOrderId(null)}
          onRecorded={() => setReloadKey((k) => k + 1)}
          notify={(type, message) => setNotification({ type, message })}
        />
      )}
      {notification && (
        <div className="fixed bottom-6 right-6 z-[130] rounded-xl border border-slate-200 bg-white px-4 py-3 text-xs font-semibold shadow-lg" role="status">
          <span className={notification.type === "error" ? "text-red-600" : "text-green-600"}>{notification.message}</span>
        </div>
      )}
    </div>
  );
}
