"use client";

/**
 * Customer payments and credit (migration 23). Super Admin only: this page hides itself from everyone else; the protection is the database,
 * whose functions refuse any other caller.
 *
 *  - Payment methods: what customers may pay with in the app. Nothing is enabled by default and none is invented: a method appears only when
 *    a Super Admin adds it here AND a provider integration exists to verify its payments.
 *  - Credit policy: the eligibility rules. Credit is OFF and every threshold is empty until EFZ decides them.
 *  - Customers: who meets the policy, and the limit and terms a Super Admin authorizes. Eligibility never grants credit by itself.
 *  - Checkouts needing review: payments the provider confirmed that could not become an order (amount, price or stock changed), and reversals.
 */

import { useCallback, useEffect, useState } from "react";
import { AlertCircle, CheckCircle2, CreditCard, Loader2, Shield, X } from "lucide-react";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";
import {
  MIN_OVERRIDE, MIN_REASON, creditGrantProblem, money, policyProblem,
  type CreditHistory, type CreditOverviewRow, type CreditPolicy, type PaymentMethodRow, type ReviewCheckout,
} from "@/lib/customerFinance";

type Data = { methods: PaymentMethodRow[]; policy: CreditPolicy; overview: CreditOverviewRow[]; review: ReviewCheckout[] };
const input = "h-8 rounded-lg border border-slate-200 px-2 text-xs focus:border-slate-400 focus:outline-none";
const btn = "rounded-lg bg-slate-900 px-3 py-1.5 text-[11px] font-semibold text-white disabled:opacity-40";
const btn2 = "rounded-lg border border-slate-200 bg-white px-3 py-1.5 text-[11px] font-semibold text-slate-700 hover:bg-slate-50 disabled:opacity-40";

export default function CustomerCreditPage() {
  const [state, setState] = useState<"loading" | "ready" | "denied" | "error">("loading");
  const [message, setMessage] = useState<string | null>(null);
  const [data, setData] = useState<Data | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);

  type Loaded = { state: "ready"; data: Data } | { state: "denied" } | { state: "error"; message: string };
  const fetchAll = useCallback(async (): Promise<Loaded> => {
    try {
      const db = getDb();
      const me = await db.auth.getProfile();
      if (!derivePermissions(me).isSuperAdmin) return { state: "denied" };
      const [methods, policy, overview, review] = await Promise.all([db.financeAdmin.paymentMethods(), db.financeAdmin.creditPolicy(), db.financeAdmin.creditOverview(), db.financeAdmin.checkoutsForReview()]);
      return { state: "ready", data: { methods, policy, overview, review } };
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
    <div className="flex min-h-[50vh] flex-col items-center justify-center gap-3" data-testid="credit-denied">
      <Shield className="h-12 w-12 text-slate-300" /><p className="text-sm text-slate-500">Only a Super Admin can manage customer payments and credit.</p>
    </div>
  );
  if (state === "error" || !data) return (
    <div className="mx-auto flex max-w-md flex-col items-center gap-2 rounded-xl border border-slate-200 bg-white py-12 text-center" data-testid="credit-error">
      <AlertCircle className="h-7 w-7 text-amber-500" /><p className="text-sm font-semibold text-slate-800">Could not load customer payments and credit</p><p className="px-4 text-xs text-slate-500">{message}</p>
    </div>
  );

  return (
    <div className="space-y-6" data-testid="customer-credit-page">
      <div>
        <h1 className="flex items-center gap-2 text-xl font-bold text-slate-900"><CreditCard className="h-5 w-5" /> Customer payments and credit</h1>
        <p className="mt-1 max-w-3xl text-xs text-slate-500">
          Payment methods and credit rules for the Android customer app. Nothing here is on by default, and a customer&apos;s PIN is never collected or stored by EFZ.
          Eligibility never grants credit by itself: you authorize the limit and terms for each customer.
        </p>
      </div>
      {done && <div className="flex items-start justify-between gap-3 rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-xs text-emerald-900" data-testid="credit-success"><span><CheckCircle2 className="mr-1 inline h-4 w-4" /> {done}</span><button type="button" onClick={() => setDone(null)} aria-label="Dismiss"><X className="h-4 w-4" /></button></div>}
      {problem && <div className="flex items-start justify-between gap-3 rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-xs text-rose-900" data-testid="credit-problem" role="alert"><span><AlertCircle className="mr-1 inline h-4 w-4" /> Not saved - {problem}</span><button type="button" onClick={() => setProblem(null)} aria-label="Dismiss"><X className="h-4 w-4" /></button></div>}

      <MethodsCard methods={data.methods} busy={busy} run={run} />
      <PolicyCard policy={data.policy} busy={busy} run={run} />
      <CustomersCard rows={data.overview} policyEnabled={data.policy.enabled} busy={busy} run={run} />
      <ReviewCard rows={data.review} busy={busy} run={run} />
    </div>
  );
}

type RunFn = (what: string, fn: () => Promise<void>) => Promise<void>;

function MethodsCard({ methods, busy, run }: { methods: PaymentMethodRow[]; busy: boolean; run: RunFn }) {
  const db = getDb();
  const [code, setCode] = useState(""); const [label, setLabel] = useState(""); const [reason, setReason] = useState("");
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4" data-testid="methods-card">
      <h2 className="text-sm font-bold text-slate-900">Payment methods</h2>
      <p className="mb-3 text-xs text-slate-500">Customers see only enabled methods. Enable a method only after its provider integration can verify payments server to server.</p>
      {methods.length === 0 ? <p className="mb-3 text-xs text-slate-400" data-testid="methods-empty">No payment method is configured. Customers cannot pay online.</p> : (
        <ul className="mb-3 divide-y divide-slate-100 text-xs">
          {methods.map((m) => (
            <li key={m.code} className="flex items-center justify-between gap-3 py-2" data-testid="method-row" data-code={m.code}>
              <span><b>{m.label}</b> <span className="text-slate-400">({m.code}, {m.kind === "staging_test" ? "Staging test only" : "provider"})</span></span>
              <button type="button" disabled={busy || reason.trim().length < MIN_REASON} className={btn2} data-testid="method-toggle"
                onClick={() => void run(`${m.label} ${m.enabled ? "disabled" : "enabled"}.`, () => db.financeAdmin.setPaymentMethod({ code: m.code, label: m.label, kind: m.kind, enabled: !m.enabled, reason }))}>
                {m.enabled ? "Disable" : "Enable"}
              </button>
            </li>
          ))}
        </ul>
      )}
      <div className="flex flex-wrap items-end gap-2">
        <label className="text-[11px] text-slate-500">Code<br /><input className={input} value={code} onChange={(e) => setCode(e.target.value.toLowerCase())} placeholder="evc" data-testid="method-code" /></label>
        <label className="text-[11px] text-slate-500">Name shown to customers<br /><input className={input} value={label} onChange={(e) => setLabel(e.target.value)} placeholder="EVC Plus" data-testid="method-label" /></label>
        <label className="text-[11px] text-slate-500">Reason for the change<br /><input className={`${input} w-56`} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="method-reason" /></label>
        <button type="button" className={btn} disabled={busy || !/^[a-z0-9_]{2,40}$/.test(code) || label.trim().length < 2 || reason.trim().length < MIN_REASON} data-testid="method-add"
          onClick={() => void run(`${label} added (disabled).`, async () => { await db.financeAdmin.setPaymentMethod({ code, label: label.trim(), kind: "provider", enabled: false, reason }); setCode(""); setLabel(""); })}>
          Add (disabled)
        </button>
      </div>
    </section>
  );
}

function PolicyCard({ policy, busy, run }: { policy: CreditPolicy; busy: boolean; run: RunFn }) {
  const db = getDb();
  const [enabled, setEnabled] = useState(policy.enabled);
  const [purchases, setPurchases] = useState(policy.minCompletedPurchases?.toString() ?? "");
  const [value, setValue] = useState(policy.minTotalValue?.toString() ?? "");
  const [terms, setTerms] = useState(policy.defaultTermsDays?.toString() ?? "");
  const [noUnpaid, setNoUnpaid] = useState(policy.requireNoUnpaidDelivered);
  const [days, setDays] = useState(policy.minApprovedDays?.toString() ?? "");
  const [ceiling, setCeiling] = useState(policy.maxOutstanding?.toString() ?? "");
  const [noOverdue, setNoOverdue] = useState(policy.requireNoOverdue);
  const [reason, setReason] = useState("");
  const draft = { enabled, minCompletedPurchases: purchases === "" ? null : Number(purchases), minTotalValue: value === "" ? null : Number(value), requireNoUnpaidDelivered: noUnpaid, defaultTermsDays: terms === "" ? null : Number(terms),
                  minApprovedDays: days === "" ? null : Number(days), maxOutstanding: ceiling === "" ? null : Number(ceiling), requireNoOverdue: noOverdue };
  const issue = policyProblem(draft, reason);
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4" data-testid="policy-card">
      <h2 className="text-sm font-bold text-slate-900">Credit policy <span className={`ml-2 rounded-full px-2 py-0.5 text-[10px] ${policy.enabled ? "bg-emerald-50 text-emerald-800" : "bg-slate-100 text-slate-600"}`} data-testid="policy-state">{policy.enabled ? "ON" : "OFF"}</span></h2>
      <p className="mb-3 text-xs text-slate-500">A customer becomes eligible when EVERY requirement filled in below is met: completed purchases (delivered, fully paid, regular orders only: never cancelled, trial, unpaid or undelivered ones), their total value, and the days since the customer was first approved. Leave a requirement empty to ignore it. The rules under Account standing can pause a customer at any time and cannot be overridden. EFZ has not set any of these values yet.</p>
      <div className="flex flex-wrap items-end gap-3 text-[11px] text-slate-500">
        <label className="flex items-center gap-2"><input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} data-testid="policy-enabled" /> Credit purchasing on</label>
        <label>Completed purchases needed<br /><input className={`${input} w-24`} inputMode="numeric" value={purchases} onChange={(e) => setPurchases(e.target.value)} data-testid="policy-purchases" /></label>
        <label>Completed purchase value needed ($)<br /><input className={`${input} w-28`} inputMode="decimal" value={value} onChange={(e) => setValue(e.target.value)} data-testid="policy-value" /></label>
        <label>Default repayment days<br /><input className={`${input} w-24`} inputMode="numeric" value={terms} onChange={(e) => setTerms(e.target.value)} data-testid="policy-terms" /></label>
        <label>Days as an approved customer<br /><input className={`${input} w-24`} inputMode="numeric" value={days} onChange={(e) => setDays(e.target.value)} data-testid="policy-days" /></label>
      </div>
      <p className="mt-3 text-[11px] font-semibold text-slate-700">Account standing (pauses credit; never overridable)</p>
      <div className="mt-1 flex flex-wrap items-end gap-3 text-[11px] text-slate-500">
        <label className="flex items-center gap-2"><input type="checkbox" checked={noUnpaid} onChange={(e) => setNoUnpaid(e.target.checked)} data-testid="policy-nounpaid" /> No unpaid balance on a delivered order</label>
        <label className="flex items-center gap-2"><input type="checkbox" checked={noOverdue} onChange={(e) => setNoOverdue(e.target.checked)} data-testid="policy-nooverdue" /> No credit invoice past its due date</label>
        <label>Maximum total outstanding per customer ($)<br /><input className={`${input} w-28`} inputMode="decimal" value={ceiling} onChange={(e) => setCeiling(e.target.value)} data-testid="policy-ceiling" /></label>
      </div>
      <div className="mt-3 flex flex-wrap items-end gap-2">
        <label className="text-[11px] text-slate-500">Reason for the change<br /><input className={`${input} w-72`} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="policy-reason" /></label>
        <button type="button" className={btn} disabled={busy || !!issue} data-testid="policy-save" onClick={() => void run("Credit policy saved.", () => db.financeAdmin.setCreditPolicy(draft, reason))}>Save policy</button>
        {issue && reason.trim().length >= MIN_REASON && <span className="text-[11px] text-amber-700" data-testid="policy-issue">{issue}</span>}
      </div>
    </section>
  );
}

function CustomersCard({ rows, policyEnabled, busy, run }: { rows: CreditOverviewRow[]; policyEnabled: boolean; busy: boolean; run: RunFn }) {
  const db = getDb();
  const [open, setOpen] = useState<string | null>(null);
  const [limit, setLimit] = useState(""); const [days, setDays] = useState(""); const [reason, setReason] = useState(""); const [override, setOverride] = useState("");
  const [hist, setHist] = useState<{ id: string; name: string; data: CreditHistory } | null>(null);
  const [histError, setHistError] = useState<string | null>(null);
  const row = rows.find((r) => r.customerId === open) ?? null;
  const standing = row?.eligibility.standingReasons ?? [];
  const unmet = row ? row.eligibility.reasons.length > 0 : false;
  const issue = row ? creditGrantProblem({ limit: Number(limit), termsDays: Number(days), reason, overrideReason: override, eligible: !unmet, standingReasons: standing }) : null;
  const showHistory = async (r: CreditOverviewRow) => {
    setHistError(null);
    try { setHist({ id: r.customerId, name: r.name, data: await getDb().financeAdmin.creditHistory(r.customerId) }); } catch (e) { setHist(null); setHistError(describeDbError(e)); }
  };
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4" data-testid="customers-card">
      <h2 className="text-sm font-bold text-slate-900">Customers with an approved app account</h2>
      {!policyEnabled && <p className="mb-2 text-xs text-slate-500">Credit is off, so no limit can be set yet.</p>}
      {rows.length === 0 ? <p className="text-xs text-slate-400">No customer has an approved app account yet.</p> : (
        <div className="overflow-x-auto"><table className="w-full text-left text-xs">
          <thead className="text-[10px] uppercase text-slate-400"><tr><th className="py-1">Customer</th><th>Completed purchases</th><th>Eligible</th><th>Outstanding</th><th>Credit</th><th /></tr></thead>
          <tbody className="divide-y divide-slate-100">
            {rows.map((r) => (
              <tr key={r.customerId} data-testid="credit-row" data-customer={r.customerId}>
                <td className="py-2 font-semibold text-slate-800">{r.name}</td>
                <td>{r.eligibility.completedPurchases} ({money(r.eligibility.completedValue)})</td>
                <td title={[...r.eligibility.reasons, ...(r.eligibility.standingReasons ?? [])].join(" ")} className={r.eligibility.eligible ? "text-emerald-700" : (r.eligibility.standingReasons ?? []).length > 0 ? "text-amber-700" : "text-slate-500"} data-testid="credit-eligible">{r.eligibility.eligible ? "Yes" : (r.eligibility.standingReasons ?? []).length > 0 ? "Paused" : "No"}</td>
                <td>{money(r.outstanding)}</td>
                <td>{r.account ? `${r.account.status} · ${money(r.account.credit_limit)} · ${r.account.terms_days} days${r.account.override_used ? " · override" : ""}` : "none"}</td>
                <td className="text-right">
                  <button type="button" className={`${btn2} mr-1`} disabled={busy} data-testid="credit-history" onClick={() => void showHistory(r)}>History</button>
                  <button type="button" className={btn2} disabled={busy || !policyEnabled} data-testid="credit-edit" onClick={() => { setOpen(r.customerId); setLimit(r.account ? String(Number(r.account.credit_limit)) : ""); setDays(r.account ? String(r.account.terms_days) : ""); setReason(""); setOverride(""); }}>{r.account ? "Change" : "Authorize"}</button>
                  {r.account?.status === "approved" && <button type="button" className={`${btn2} ml-1`} disabled={busy || reason.trim().length < MIN_REASON || open !== r.customerId} title="Needs a reason in the form below" data-testid="credit-suspend"
                    onClick={() => void run(`Credit suspended for ${r.name}.`, () => db.financeAdmin.suspendCustomerCredit(r.customerId, reason))}>Suspend</button>}
                </td>
              </tr>
            ))}
          </tbody>
        </table></div>
      )}
      {row && (
        <div className="mt-3 rounded-lg border border-slate-200 bg-slate-50 p-3 text-[11px] text-slate-600" data-testid="credit-form">
          <p className="mb-2 font-semibold text-slate-800">{row.name}: {row.eligibility.eligible ? "meets the policy" : standing.length > 0 ? "account paused" : "does not meet the policy"}</p>
          {unmet && <ul className="mb-2 list-disc pl-4" data-testid="credit-unmet">{row.eligibility.reasons.map((x) => <li key={x}>{x}</li>)}</ul>}
          {standing.length > 0 && <ul className="mb-2 list-disc pl-4 text-amber-800" data-testid="credit-standing">{standing.map((x) => <li key={x}>{x}</li>)}<li className="list-none">Credit cannot be authorized until this is resolved; an override does not apply.</li></ul>}
          <div className="flex flex-wrap items-end gap-2">
            <label>Credit limit ($)<br /><input className={`${input} w-28`} inputMode="decimal" value={limit} onChange={(e) => setLimit(e.target.value)} data-testid="credit-limit" /></label>
            <label>Repayment days<br /><input className={`${input} w-24`} inputMode="numeric" value={days} onChange={(e) => setDays(e.target.value)} data-testid="credit-days" /></label>
            <label>Reason<br /><input className={`${input} w-56`} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="credit-reason" /></label>
            {unmet && standing.length === 0 && <label>Override reason (min {MIN_OVERRIDE})<br /><input className={`${input} w-64`} value={override} onChange={(e) => setOverride(e.target.value)} data-testid="credit-override" /></label>}
            <button type="button" className={btn} disabled={busy || !!issue} data-testid="credit-save"
              onClick={() => void run(`Credit authorized for ${row.name}.`, async () => { await db.financeAdmin.setCustomerCredit({ customerId: row.customerId, limit: Number(limit), termsDays: Number(days), reason, overrideReason: unmet ? override : null }); setOpen(null); })}>Save</button>
            <button type="button" className={btn2} onClick={() => setOpen(null)}>Close</button>
          </div>
          {issue && <p className="mt-2 text-amber-700" data-testid="credit-issue">{issue}</p>}
        </div>
      )}
      {histError && <p className="mt-3 text-xs text-red-700" data-testid="history-error">{histError}</p>}
      {hist && (
        <div className="mt-3 rounded-lg border border-slate-200 bg-white p-3 text-[11px] text-slate-600" data-testid="credit-history-panel">
          <div className="mb-2 flex items-center justify-between"><p className="font-semibold text-slate-800">Credit history: {hist.name}</p><button type="button" className={btn2} onClick={() => setHist(null)}>Close</button></div>
          {hist.data.orders.length === 0 ? <p data-testid="history-no-orders">No credit orders yet.</p> : (
            <table className="mb-2 w-full text-left"><thead className="text-[10px] uppercase text-slate-400"><tr><th>Order</th><th>Date</th><th>Due</th><th>Total</th><th>Paid</th><th>Balance</th><th /></tr></thead>
              <tbody className="divide-y divide-slate-100">{hist.data.orders.map((o) => (
                <tr key={o.orderId} data-testid="history-order"><td className="py-1 font-semibold">{o.orderId}</td><td>{o.date}</td><td>{o.dueDate}</td><td>{money(o.total)}</td><td>{money(o.paid)}</td><td>{money(o.outstanding)}</td><td className={o.overdue ? "font-semibold text-red-700" : "text-slate-400"}>{o.status === "cancelled" ? "cancelled" : o.overdue ? "OVERDUE" : Number(o.outstanding) > 0 ? "open" : "paid"}</td></tr>
              ))}</tbody></table>
          )}
          {hist.data.events.length === 0 ? <p data-testid="history-no-events">No limit changes recorded.</p> : <ul className="list-disc pl-4" data-testid="history-events">{hist.data.events.map((e, i) => <li key={i}>{new Date(e.at).toLocaleString()} · {e.by}: {e.message}</li>)}</ul>}
        </div>
      )}
    </section>
  );
}

function ReviewCard({ rows, busy, run }: { rows: ReviewCheckout[]; busy: boolean; run: RunFn }) {
  const db = getDb();
  const [note, setNote] = useState<Record<string, string>>({});
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4" data-testid="review-card">
      <h2 className="text-sm font-bold text-slate-900">Checkouts needing review</h2>
      <p className="mb-3 text-xs text-slate-500">A payment was confirmed by the provider but could not become an order (the price or stock changed, or the amount differed), or the provider reversed it. Nothing is changed automatically: handle the customer and the books, then record how it was resolved.</p>
      {rows.length === 0 ? <p className="text-xs text-slate-400" data-testid="review-empty">Nothing needs review.</p> : (
        <ul className="divide-y divide-slate-100 text-xs">
          {rows.map((c) => (
            <li key={c.id} className="space-y-1 py-2" data-testid="review-row">
              <p><b>{c.customerName ?? c.customerId}</b> · {money(c.amount)} · {c.method} · {c.status === "reversed" ? "reversed by the provider" : "needs review"}{c.orderId ? ` · order ${c.orderId}` : ""}</p>
              <p className="text-slate-500">{c.reason || "—"}</p>
              <div className="flex items-center gap-2">
                <input className={`${input} w-96`} placeholder={`How it was resolved (min 10 characters)`} value={note[c.id] ?? ""} onChange={(e) => setNote({ ...note, [c.id]: e.target.value })} />
                <button type="button" className={btn2} disabled={busy || (note[c.id] ?? "").trim().length < 10} onClick={() => void run("Marked as resolved.", () => db.financeAdmin.resolveCheckout(c.id, note[c.id]))}>Mark resolved</button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
