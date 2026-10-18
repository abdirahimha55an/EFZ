"use client";

/**
 * Customer prices (migration 26): the negotiated prices the Android app honours. Super Admin or Manager only (the page hides itself from everyone else; the protection
 * is the database, whose functions refuse any other caller).
 *
 *  - Agreements: one verified price per customer, product and (optionally) design, with start and end dates. Nothing is ever edited in place: a price change replaces
 *    the agreement (the old one is kept, revoked), and everything is in the history.
 *  - Review queue: candidates from the order history wait for verification; until then that product is held for review in the app (never silently charged at list price).
 *  - Import: reads the order history and PROPOSES only consistent negotiated prices; everything ambiguous is listed for manual confirmation. No price is invented.
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import { AlertCircle, CheckCircle2, Loader2, Shield, Tag, X } from "lucide-react";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";
import {
  MIN_NOTE, agreementProblem, importSummary, manualConfirmationCsv, noteProblem, statusLabel,
  type ImportReport, type PriceAgreement, type PriceAlerts, type PriceHistoryEvent,
} from "@/lib/customerPrices";
import type { Customer, Product } from "@/lib/types";

type Design = { id: string; productId: string; name: string };
type Data = { alerts: PriceAlerts; agreements: PriceAgreement[]; customers: Customer[]; products: Product[]; designs: Design[]; isSuperAdmin: boolean };
const input = "h-8 rounded-lg border border-slate-200 px-2 text-xs focus:border-slate-400 focus:outline-none";
const btn = "rounded-lg bg-slate-900 px-3 py-1.5 text-[11px] font-semibold text-white disabled:opacity-40";
const btn2 = "rounded-lg border border-slate-200 bg-white px-3 py-1.5 text-[11px] font-semibold text-slate-700 hover:bg-slate-50 disabled:opacity-40";
const card = "rounded-xl border border-slate-200 bg-white p-4";
const money = (n: number | string) => `$${Number(n).toFixed(2)}`;

export default function CustomerPricesPage() {
  const [state, setState] = useState<"loading" | "ready" | "denied" | "error">("loading");
  const [message, setMessage] = useState<string | null>(null);
  const [data, setData] = useState<Data | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [customerFilter, setCustomerFilter] = useState(""); const [statusFilter, setStatusFilter] = useState("");

  type Loaded = { state: "ready"; data: Data } | { state: "denied" } | { state: "error"; message: string };
  const fetchAll = useCallback(async (): Promise<Loaded> => {
    try {
      const db = getDb();
      const me = await db.auth.getProfile();
      const perms = derivePermissions(me);
      if (!perms.managePricing) return { state: "denied" };
      const [alerts, agreements, customers, products, designs] = await Promise.all([db.pricing.alerts(), db.pricing.list(), db.customers.list(), db.products.list({ includeInactive: false }), db.pricing.designs().catch(() => [] as Design[])]);
      return { state: "ready", data: { alerts, agreements, customers, products, designs, isSuperAdmin: perms.isSuperAdmin } };
    } catch (e) { return { state: "error", message: describeDbError(e) }; }
  }, []);
  const apply = useCallback((r: Loaded) => { if (r.state === "ready") setData(r.data); if (r.state === "error") setMessage(r.message); setState(r.state); }, []);
  useEffect(() => {
    let cancelled = false;
    (async () => { const r = await fetchAll(); if (!cancelled) apply(r); })();
    return () => { cancelled = true; };
  }, [fetchAll, apply]);

  /** Runs one database call, then refreshes. The database's own sentence is shown when it refuses. */
  const run = async (what: string, fn: () => Promise<void>) => {
    setBusy(true); setProblem(null); setDone(null);
    try { await fn(); setDone(what); apply(await fetchAll()); } catch (e) { setProblem(describeDbError(e)); } finally { setBusy(false); }
  };

  if (state === "loading") return <div className="flex items-center justify-center gap-2 py-32 text-xs text-slate-400"><Loader2 className="h-5 w-5 animate-spin" /> Loading…</div>;
  if (state === "denied") return (
    <div className="flex min-h-[50vh] flex-col items-center justify-center gap-3" data-testid="prices-denied">
      <Shield className="h-12 w-12 text-slate-300" /><p className="text-sm text-slate-500">Only a Super Admin or a Manager can manage customer prices.</p>
    </div>
  );
  if (state === "error" || !data) return (
    <div className="mx-auto flex max-w-md flex-col items-center gap-2 rounded-xl border border-slate-200 bg-white py-12 text-center" data-testid="prices-error">
      <AlertCircle className="h-7 w-7 text-amber-500" /><p className="text-sm font-semibold text-slate-800">Could not load customer prices</p><p className="px-4 text-xs text-slate-500">{message}</p>
    </div>
  );
  const shown = data.agreements.filter((a) => (!customerFilter || a.customerId === customerFilter) && (!statusFilter || a.status === statusFilter));
  return (
    <div className="space-y-6" data-testid="customer-prices-page">
      <div>
        <h1 className="flex items-center gap-2 text-xl font-bold text-slate-900"><Tag className="h-5 w-5" /> Customer prices</h1>
        <p className="mt-1 max-w-3xl text-xs text-slate-500">
          Negotiated prices the Android app charges. A customer without a verified agreement pays the list price. An agreement is never edited: changing a price replaces it and the old one stays on record.
          A price waiting for verification holds that product for review in the app until someone confirms it. Existing orders, invoices and revenue never change when an agreement does.
        </p>
      </div>
      {done && <div className="flex items-start justify-between gap-3 rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-xs text-emerald-900" data-testid="prices-success"><span><CheckCircle2 className="mr-1 inline h-4 w-4" /> {done}</span><button type="button" onClick={() => setDone(null)} aria-label="Dismiss"><X className="h-4 w-4" /></button></div>}
      {problem && <div className="flex items-start justify-between gap-3 rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-xs text-rose-900" data-testid="prices-problem" role="alert"><span><AlertCircle className="mr-1 inline h-4 w-4" /> Not saved - {problem}</span><button type="button" onClick={() => setProblem(null)} aria-label="Dismiss"><X className="h-4 w-4" /></button></div>}

      <section className="flex flex-wrap gap-2 text-[11px]" data-testid="price-alerts">
        <span className={`rounded-full px-3 py-1 ${data.alerts.pending > 0 ? "bg-amber-100 text-amber-900" : "bg-slate-100 text-slate-600"}`} data-testid="alert-pending">{data.alerts.pending} waiting for verification</span>
        <span className={`rounded-full px-3 py-1 ${data.alerts.expiringSoon > 0 ? "bg-amber-100 text-amber-900" : "bg-slate-100 text-slate-600"}`} data-testid="alert-expiring">{data.alerts.expiringSoon} ending within 14 days</span>
        <span className={`rounded-full px-3 py-1 ${data.alerts.expiredLast30Days > 0 ? "bg-amber-100 text-amber-900" : "bg-slate-100 text-slate-600"}`} data-testid="alert-expired">{data.alerts.expiredLast30Days} expired in the last 30 days</span>
        <span className={`rounded-full px-3 py-1 ${data.alerts.belowCurrentCost > 0 ? "bg-red-100 text-red-800" : "bg-slate-100 text-slate-600"}`} data-testid="alert-belowcost">{data.alerts.belowCurrentCost} now below cost and not approved</span>
      </section>

      <AgreementsCard data={data} shown={shown} customerFilter={customerFilter} setCustomerFilter={setCustomerFilter} statusFilter={statusFilter} setStatusFilter={setStatusFilter} busy={busy} run={run} />
      <CreateCard data={data} busy={busy} run={run} />
      <ImportCard busy={busy} run={run} onProblem={setProblem} />
    </div>
  );
}

type RunFn = (what: string, fn: () => Promise<void>) => Promise<void>;

function AgreementsCard({ data, shown, customerFilter, setCustomerFilter, statusFilter, setStatusFilter, busy, run }:
  { data: Data; shown: PriceAgreement[]; customerFilter: string; setCustomerFilter: (v: string) => void; statusFilter: string; setStatusFilter: (v: string) => void; busy: boolean; run: RunFn }) {
  const db = getDb();
  const [open, setOpen] = useState<{ id: string; kind: "verify" | "replace" | "end" | "revoke" | "reject" } | null>(null);
  const [price, setPrice] = useState(""); const [from, setFrom] = useState(""); const [to, setTo] = useState(""); const [note, setNote] = useState(""); const [below, setBelow] = useState("");
  const [hist, setHist] = useState<{ name: string; events: PriceHistoryEvent[] } | null>(null); const [histError, setHistError] = useState<string | null>(null);
  const today = data.alerts.asOf;
  const start = (a: PriceAgreement, kind: "verify" | "replace" | "end" | "revoke" | "reject") => { setOpen({ id: a.id, kind }); setPrice(String(Number(a.unitPrice))); setFrom(kind === "replace" ? today : a.effectiveFrom); setTo(a.effectiveTo ?? ""); setNote(""); setBelow(""); };
  const a = shown.find((x) => x.id === open?.id) ?? null;
  const priceBad = open && (open.kind === "verify" || open.kind === "replace") && (!(Number(price) > 0) || Math.round(Number(price) * 100) !== Number(price) * 100);
  const issue = !open ? null : priceBad ? "Enter the agreed price in whole cents." : open.kind === "end" ? (!/^\d{4}-\d{2}-\d{2}$/.test(to) ? "Pick the new end date." : noteProblem(note)) : noteProblem(note);
  const submit = () => {
    if (!open || !a) return;
    const toDate = to === "" ? null : to; const belowReason = below.trim() === "" ? null : below;
    const call = open.kind === "verify" ? () => db.pricing.verify(a.id, Number(price), from, toDate, note, belowReason)
      : open.kind === "replace" ? async () => { await db.pricing.replace(a.id, Number(price), from, toDate, note, belowReason); }
      : open.kind === "end" ? () => db.pricing.end(a.id, to, note) : open.kind === "revoke" ? () => db.pricing.revoke(a.id, note) : () => db.pricing.reject(a.id, note);
    void run(open.kind === "verify" ? "Agreement verified." : open.kind === "replace" ? "Price replaced." : open.kind === "end" ? "Agreement end-dated." : open.kind === "revoke" ? "Agreement revoked." : "Candidate rejected.", async () => { await call(); setOpen(null); });
  };
  const showHistory = async (customerId: string, name: string) => {
    setHistError(null);
    try { setHist({ name, events: await db.pricing.history(customerId) }); } catch (e) { setHist(null); setHistError(describeDbError(e)); }
  };
  return (
    <section className={card} data-testid="agreements-card">
      <div className="mb-3 flex flex-wrap items-end gap-3 text-[11px] text-slate-500">
        <h2 className="mr-auto text-sm font-bold text-slate-900">Agreements</h2>
        <label>Customer<br /><select className={`${input} w-56`} value={customerFilter} onChange={(e) => setCustomerFilter(e.target.value)} data-testid="filter-customer"><option value="">All customers</option>{data.customers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></label>
        <label>Status<br /><select className={`${input} w-44`} value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)} data-testid="filter-status"><option value="">Any</option><option value="pending_review">Waiting for verification</option><option value="active">Active</option><option value="revoked">Revoked</option><option value="rejected">Rejected</option></select></label>
      </div>
      {shown.length === 0 ? <p className="text-xs text-slate-400" data-testid="agreements-empty">No agreements match.</p> : (
        <div className="overflow-x-auto"><table className="w-full text-left text-xs">
          <thead className="text-[10px] uppercase text-slate-400"><tr><th className="py-1">Customer</th><th>Product / design</th><th>Agreed</th><th>List</th><th>Valid</th><th>Status</th><th /></tr></thead>
          <tbody className="divide-y divide-slate-100">
            {shown.map((g) => (
              <tr key={g.id} data-testid="agreement-row" data-status={g.status} data-id={g.id}>
                <td className="py-2 font-semibold text-slate-800">{g.customerName}</td>
                <td>{g.productName}{g.designName ? ` · ${g.designName}` : " (all designs)"}</td>
                <td className="font-semibold" data-testid="agreement-price">{money(g.unitPrice)}{g.belowCurrentCost && <span className="ml-1 rounded bg-red-100 px-1 text-[9px] text-red-800">{g.belowCostApproved ? "below cost (approved)" : "BELOW COST"}</span>}</td>
                <td className="text-slate-500">{money(g.listPrice)}</td>
                <td>{g.effectiveFrom} → {g.effectiveTo ?? "no end"}</td>
                <td data-testid="agreement-status" className={g.status === "pending_review" ? "text-amber-700" : g.status === "active" && !g.expired ? "text-emerald-700" : "text-slate-500"}>{statusLabel(g, today)}{g.source === "import" ? " · imported" : ""}</td>
                <td className="whitespace-nowrap text-right">
                  {g.status === "pending_review" && <><button type="button" className={btn2} disabled={busy} data-testid="act-verify" onClick={() => start(g, "verify")}>Verify</button> <button type="button" className={btn2} disabled={busy} data-testid="act-reject" onClick={() => start(g, "reject")}>Reject</button> </>}
                  {g.status === "active" && <><button type="button" className={btn2} disabled={busy} data-testid="act-replace" onClick={() => start(g, "replace")}>Change price</button> <button type="button" className={btn2} disabled={busy} data-testid="act-end" onClick={() => start(g, "end")}>End</button> <button type="button" className={btn2} disabled={busy} data-testid="act-revoke" onClick={() => start(g, "revoke")}>Revoke</button> </>}
                  <button type="button" className={btn2} disabled={busy} data-testid="act-history" onClick={() => void showHistory(g.customerId, g.customerName)}>History</button>
                </td>
              </tr>
            ))}
          </tbody></table></div>
      )}
      {open && a && (
        <div className="mt-3 rounded-lg border border-slate-200 bg-slate-50 p-3 text-[11px] text-slate-600" data-testid="action-form">
          <p className="mb-2 font-semibold text-slate-800">{open.kind === "verify" ? "Verify" : open.kind === "replace" ? "Change the price of" : open.kind === "end" ? "End" : open.kind === "revoke" ? "Revoke" : "Reject"}: {a.customerName}, {a.productName}{a.designName ? ` · ${a.designName}` : ""}</p>
          {open.kind === "verify" && a.evidence && <p className="mb-2 text-slate-500" data-testid="evidence">Evidence from the order history: {a.evidence.orders} order(s) at {(a.evidence.prices ?? []).map(money).join(" / ")}, first {a.evidence.firstOrder}, last {a.evidence.lastOrder}. Confirm or correct the price below.</p>}
          <div className="flex flex-wrap items-end gap-2">
            {(open.kind === "verify" || open.kind === "replace") && <>
              <label>Agreed price ($)<br /><input className={`${input} w-24`} inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} data-testid="act-price" /></label>
              <label>From<br /><input type="date" className={`${input} w-36`} value={from} onChange={(e) => setFrom(e.target.value)} data-testid="act-from" /></label>
              <label>Until (optional)<br /><input type="date" className={`${input} w-36`} value={to} onChange={(e) => setTo(e.target.value)} data-testid="act-to" /></label>
              {data.isSuperAdmin && <label>Below-cost reason (only if below cost)<br /><input className={`${input} w-56`} value={below} onChange={(e) => setBelow(e.target.value)} data-testid="act-below" /></label>}
            </>}
            {open.kind === "end" && <label>New end date<br /><input type="date" className={`${input} w-36`} value={to} onChange={(e) => setTo(e.target.value)} data-testid="act-to" /></label>}
            <label>{open.kind === "verify" ? "Confirmation (who confirmed, how)" : "Reason"} (min {MIN_NOTE})<br /><input className={`${input} w-80`} value={note} onChange={(e) => setNote(e.target.value)} data-testid="act-note" /></label>
            <button type="button" className={btn} disabled={busy || !!issue} data-testid="act-save" onClick={submit}>Save</button>
            <button type="button" className={btn2} onClick={() => setOpen(null)}>Close</button>
          </div>
          {issue && note.trim().length > 0 && <p className="mt-2 text-amber-700" data-testid="act-issue">{issue}</p>}
        </div>
      )}
      {histError && <p className="mt-3 text-xs text-red-700" data-testid="price-history-error">{histError}</p>}
      {hist && (
        <div className="mt-3 rounded-lg border border-slate-200 bg-white p-3 text-[11px] text-slate-600" data-testid="price-history">
          <div className="mb-2 flex items-center justify-between"><p className="font-semibold text-slate-800">Price history: {hist.name}</p><button type="button" className={btn2} onClick={() => setHist(null)}>Close</button></div>
          <ul className="list-disc pl-4">{hist.events.map((e, i) => <li key={i} data-testid="history-event">{new Date(e.at).toLocaleString()} · {e.by}: {e.kind}{e.details && e.details.unitPrice != null ? ` ${money(e.details.unitPrice as number)}` : ""}{e.details && e.details.reason ? ` (${String(e.details.reason)})` : ""}</li>)}</ul>
        </div>
      )}
    </section>
  );
}

function CreateCard({ data, busy, run }: { data: Data; busy: boolean; run: RunFn }) {
  const db = getDb();
  const [customerId, setCustomerId] = useState(""); const [productId, setProductId] = useState(""); const [designId, setDesignId] = useState(""); const [price, setPrice] = useState("");
  const [from, setFrom] = useState(data.alerts.asOf); const [to, setTo] = useState(""); const [reason, setReason] = useState(""); const [belowReason, setBelowReason] = useState("");
  const product = data.products.find((p) => p.id === productId);
  const designs = useMemo(() => data.designs.filter((d) => d.productId === productId), [data.designs, productId]);
  const belowCost = !!product && product.costPrice !== null && Number(price) > 0 && Number(price) < product.costPrice;
  const issue = agreementProblem({ customerId, productId, price, from, to, reason, belowCost, belowCostReason: belowReason, isSuperAdmin: data.isSuperAdmin });
  return (
    <section className={card} data-testid="create-card">
      <h2 className="text-sm font-bold text-slate-900">Record an agreement</h2>
      <p className="mb-3 text-xs text-slate-500">For a price EFZ has already agreed with the customer. It is used by the app straight away. Record who agreed it and how in the authorization box. A price below cost needs a Super Admin and a reason.</p>
      <div className="flex flex-wrap items-end gap-3 text-[11px] text-slate-500">
        <label>Customer<br /><select className={`${input} w-56`} value={customerId} onChange={(e) => setCustomerId(e.target.value)} data-testid="new-customer"><option value="">Choose…</option>{data.customers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></label>
        <label>Product<br /><select className={`${input} w-56`} value={productId} onChange={(e) => { setProductId(e.target.value); setDesignId(""); }} data-testid="new-product"><option value="">Choose…</option>{data.products.map((p) => <option key={p.id} value={p.id}>{p.name} (list {money(p.sellingPrice)})</option>)}</select></label>
        <label>Design<br /><select className={`${input} w-40`} value={designId} onChange={(e) => setDesignId(e.target.value)} data-testid="new-design"><option value="">All designs</option>{designs.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></label>
        <label>Agreed price ($)<br /><input className={`${input} w-24`} inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} data-testid="new-price" /></label>
        <label>From<br /><input type="date" className={`${input} w-36`} value={from} onChange={(e) => setFrom(e.target.value)} data-testid="new-from" /></label>
        <label>Until (optional)<br /><input type="date" className={`${input} w-36`} value={to} onChange={(e) => setTo(e.target.value)} data-testid="new-to" /></label>
      </div>
      <div className="mt-3 flex flex-wrap items-end gap-3 text-[11px] text-slate-500">
        <label>Authorization or evidence (min {MIN_NOTE})<br /><input className={`${input} w-96`} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="new-reason" /></label>
        {belowCost && <label>Below-cost reason (min {MIN_NOTE})<br /><input className={`${input} w-72`} value={belowReason} onChange={(e) => setBelowReason(e.target.value)} data-testid="new-below" /></label>}
        <button type="button" className={btn} disabled={busy || !!issue} data-testid="new-save"
          onClick={() => void run("Agreement recorded.", async () => { await db.pricing.create({ customerId, productId, designId: designId || null, unitPrice: Number(price), from, to: to || null, reason, belowCostReason: belowCost ? belowReason : null }); setPrice(""); setReason(""); setBelowReason(""); })}>Record agreement</button>
        {issue && reason.trim().length > 0 && <span className="text-[11px] text-amber-700" data-testid="new-issue">{issue}</span>}
      </div>
    </section>
  );
}

function ImportCard({ busy, run, onProblem }: { busy: boolean; run: RunFn; onProblem: (m: string | null) => void }) {
  const db = getDb();
  const [since, setSince] = useState(""); const [minOrders, setMinOrders] = useState("2");
  const [report, setReport] = useState<ImportReport | null>(null);
  const minBad = !(Number.isInteger(Number(minOrders)) && Number(minOrders) >= 1);
  const scan = async (dryRun: boolean) => {
    onProblem(null);
    try { setReport(await db.pricing.importCandidates(dryRun, since || null, Number(minOrders))); } catch (e) { onProblem(describeDbError(e)); }
  };
  const csv = report ? manualConfirmationCsv(report.needsConfirmation) : "";
  return (
    <section className={card} data-testid="import-card">
      <h2 className="text-sm font-bold text-slate-900">Existing negotiated prices (from the order history)</h2>
      <p className="mb-3 text-xs text-slate-500">
        Reads past orders and lists customers who consistently paid the same non-list price for a product. <b>Preview</b> writes nothing. <b>Save as pending</b> records only the consistent ones as candidates that are
        <b> not used</b> until someone verifies each (and may correct its price). Mixed, single-order, below-cost and unmatched cases are only listed here for manual confirmation: no price is invented.
      </p>
      <div className="flex flex-wrap items-end gap-2 text-[11px] text-slate-500">
        <label>Orders since (default: a year ago)<br /><input type="date" className={`${input} w-36`} value={since} onChange={(e) => setSince(e.target.value)} data-testid="import-since" /></label>
        <label>At least this many orders<br /><input className={`${input} w-20`} inputMode="numeric" value={minOrders} onChange={(e) => setMinOrders(e.target.value)} data-testid="import-min" /></label>
        <button type="button" className={btn2} disabled={busy || minBad} data-testid="import-preview" onClick={() => void scan(true)}>Preview (saves nothing)</button>
        <button type="button" className={btn} disabled={busy || minBad || !report || !report.dryRun || report.candidates.length === 0} data-testid="import-save"
          onClick={() => void run("Candidates saved as pending.", async () => { setReport(await db.pricing.importCandidates(false, since || null, Number(minOrders))); })}>Save {report?.candidates.length ?? 0} as pending</button>
      </div>
      {report && (
        <div className="mt-3 space-y-3 text-xs" data-testid="import-report">
          <p className="text-slate-600" data-testid="import-summary">{importSummary(report)}</p>
          {report.candidates.length > 0 && <div><p className="font-semibold text-slate-800">Consistent prices (proposed)</p>
            <ul className="list-disc pl-4" data-testid="import-candidates">{report.candidates.map((c, i) => <li key={i}>{c.customerName}: {c.productName}{c.designName && c.designName !== c.productName ? ` · ${c.designName}` : ""} at {money(c.proposedPrice ?? c.latestPrice)} in {c.orders} orders since {c.proposedFrom} (list now {money(c.listPriceNow ?? 0)})</li>)}</ul></div>}
          {report.needsConfirmation.length > 0 && <div><div className="flex items-center gap-3"><p className="font-semibold text-slate-800">Needs manual confirmation ({report.needsConfirmation.length})</p>
            <a className={btn2} download="price-agreements-needing-confirmation.csv" href={`data:text/csv;charset=utf-8,${encodeURIComponent(csv)}`} data-testid="import-csv">Download as CSV</a></div>
            <ul className="list-disc pl-4" data-testid="import-manual">{report.needsConfirmation.map((c, i) => <li key={i}>{c.customerName}: {c.productName ?? c.productId}{c.designName && c.designName !== c.productName ? ` · ${c.designName}` : ""}: {c.reason} (prices seen: {c.prices.map(money).join(", ")}; {c.orders} order(s))</li>)}</ul></div>}
        </div>
      )}
    </section>
  );
}
