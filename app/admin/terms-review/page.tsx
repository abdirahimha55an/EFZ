"use client";

/**
 * Super Admin review of legacy orders whose payment terms were never recorded.
 *
 * Lists orders with orders.payment_terms IS NULL, shows what the records do and do
 * not establish, and lets the Super Admin choose paid_at_sale or credit ONCE per
 * order, with an evidence note. The write is the existing audited
 * set_order_payment_terms() function (migration 20); the DATABASE enforces who may
 * call it, that terms can only go from NULL to a value once, and the audit line.
 * This page only hides the control from other roles - it is not the protection.
 * Nothing here changes totals, payments, balances, statuses or commissions, and
 * nothing is bulk-applied or pre-selected: each order needs its own choice,
 * evidence note and confirmation.
 */

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { AlertCircle, CheckCircle2, ClipboardCheck, HelpCircle, Loader2, Shield, X } from "lucide-react";
import type { AdminProfile, Order, PaymentTerms } from "@/lib/types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";
import { toCents } from "@/lib/analytics/dataset";
import { usd } from "@/components/analytics/primitives";
import { evidenceLean, evidenceSummary, legacyEvidence, MAX_EVIDENCE_CHARS, MIN_EVIDENCE_CHARS, type EvidenceKind } from "@/lib/finance/legacyTerms";

const toReview = (o: Order) => ({
  date: o.date,
  totalCents: toCents(o.total),
  amountPaidCents: toCents(o.amountPaid),
  outstandingCents: toCents(o.outstandingBalance),
  payments: (o.payments ?? []).map((p) => ({ date: p.paymentDate, createdAt: p.createdAt, amountCents: toCents(p.amount), recordedBy: p.recordedBy || undefined })),
});

const KIND: Record<EvidenceKind, { label: string; cls: string; Icon: typeof CheckCircle2 }> = {
  confirmed: { label: "Confirmed", cls: "bg-emerald-50 text-emerald-800 border-emerald-200", Icon: CheckCircle2 },
  ambiguous: { label: "Ambiguous", cls: "bg-amber-50 text-amber-800 border-amber-200", Icon: HelpCircle },
  missing: { label: "Not recorded", cls: "bg-slate-50 text-slate-600 border-slate-200", Icon: AlertCircle },
};
const TERMS_LABEL: Record<PaymentTerms, string> = { paid_at_sale: "Paid at sale", credit: "Credit" };
const CONSEQUENCE: Record<PaymentTerms, string> = {
  paid_at_sale: "Receipt workflow only. No invoice can be issued for this order.",
  credit: "An invoice becomes available (it stays available after full payment). Receipts can still document each payment.",
};

export default function TermsReviewPage() {
  const [state, setState] = useState<"loading" | "ready" | "denied" | "error">("loading");
  const [message, setMessage] = useState<string | null>(null);
  const [list, setList] = useState<Order[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [choice, setChoice] = useState<PaymentTerms | "">("");
  const [note, setNote] = useState("");
  const [confirming, setConfirming] = useState(false);
  const [understood, setUnderstood] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [done, setDone] = useState<{ id: string; terms: PaymentTerms } | null>(null);

  type Loaded = { state: "ready"; list: Order[] } | { state: "denied" } | { state: "error"; message: string };
  const fetchList = useCallback(async (): Promise<Loaded> => {
    try {
      const db = getDb();
      const me: AdminProfile | null = await db.auth.getProfile();
      if (!derivePermissions(me).isSuperAdmin) return { state: "denied" };
      return { state: "ready", list: await db.orders.listWithoutTerms() };
    } catch (error) {
      return { state: "error", message: describeDbError(error) };
    }
  }, []);
  const apply = useCallback((r: Loaded) => { if (r.state === "ready") setList(r.list); if (r.state === "error") setMessage(r.message); setState(r.state); }, []);
  useEffect(() => {
    let cancelled = false;
    (async () => { const r = await fetchList(); if (!cancelled) apply(r); })();
    return () => { cancelled = true; };
  }, [fetchList, apply]);

  const selected = list.find((o) => o.id === selectedId) ?? null;
  const lines = selected ? legacyEvidence(toReview(selected)) : [];
  const lean = evidenceLean(lines);
  const noteOk = note.trim().length >= MIN_EVIDENCE_CHARS;

  const select = (id: string) => { setSelectedId(id); setChoice(""); setNote(""); setConfirming(false); setUnderstood(false); setSaveError(null); };

  const save = async () => {
    if (!selected || !choice || !noteOk || !understood || saving) return;
    setSaving(true); setSaveError(null);
    try {
      await getDb().orders.setPaymentTerms(selected.id, choice, note.trim());
      setDone({ id: selected.id, terms: choice });
      setSelectedId(null); setConfirming(false); setChoice(""); setNote(""); setUnderstood(false);
      apply(await fetchList());
    } catch (error) {
      setSaveError(`${selected.id}: ${describeDbError(error)}`);
      setConfirming(false);
      apply(await fetchList()); // the list may be stale (e.g. another session already classified it)
    } finally {
      setSaving(false);
    }
  };

  if (state === "loading") return <div className="flex items-center justify-center gap-2 py-32 text-xs text-slate-400"><Loader2 className="h-5 w-5 animate-spin" /> Loading…</div>;
  if (state === "denied") return (
    <div className="flex min-h-[50vh] flex-col items-center justify-center gap-3" data-testid="terms-denied">
      <Shield className="h-12 w-12 text-slate-300" /><p className="text-sm text-slate-500">Only a Super Admin can review legacy payment terms.</p>
    </div>
  );
  if (state === "error") return (
    <div className="mx-auto flex max-w-md flex-col items-center gap-2 rounded-xl border border-slate-200 bg-white py-12 text-center" data-testid="terms-error">
      <AlertCircle className="h-7 w-7 text-amber-500" /><p className="text-sm font-semibold text-slate-800">Could not load the review list</p><p className="px-4 text-xs text-slate-500">{message}</p>
    </div>
  );

  return (
    <div className="space-y-5" data-testid="terms-review-page">
      <div>
        <h1 className="flex items-center gap-2 text-xl font-bold text-slate-900"><ClipboardCheck className="h-5 w-5" /> Legacy payment terms review</h1>
        <p className="mt-1 max-w-3xl text-xs text-slate-500">
          These orders have no recorded payment terms, so no invoice can be issued for them. Terms are not inferred from whether an order is paid today.
          Choose the terms only when the records support it, give your evidence, and confirm. Each order can be classified once; the choice is permanent and audited.
          Orders where the evidence is unclear can stay here.
        </p>
      </div>

      {done && (
        <div className="flex items-start justify-between gap-3 rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-xs text-emerald-900" data-testid="terms-success">
          <span><CheckCircle2 className="mr-1 inline h-4 w-4" /> {done.id} recorded as <b>{TERMS_LABEL[done.terms]}</b>. The audit entry was written by the database.</span>
          <button type="button" onClick={() => setDone(null)} aria-label="Dismiss"><X className="h-4 w-4" /></button>
        </div>
      )}

      {saveError && (
        <div className="flex items-start justify-between gap-3 rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-xs text-rose-900" data-testid="terms-save-error" role="alert">
          <span><AlertCircle className="mr-1 inline h-4 w-4" /> Not saved - {saveError}</span>
          <button type="button" onClick={() => setSaveError(null)} aria-label="Dismiss"><X className="h-4 w-4" /></button>
        </div>
      )}

      {list.length === 0 ? (
        <div className="rounded-xl border border-slate-200 bg-white py-16 text-center" data-testid="terms-empty">
          <CheckCircle2 className="mx-auto h-9 w-9 text-emerald-500" />
          <p className="mt-2 text-sm font-semibold text-slate-800">No orders are waiting for a payment-terms decision.</p>
          <p className="text-xs text-slate-500">Every order the database shows has its terms recorded.</p>
        </div>
      ) : (
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]">
          <div className="overflow-hidden rounded-xl border border-slate-200 bg-white" data-testid="terms-list">
            <p className="border-b border-slate-100 px-4 py-2 text-[11px] font-bold uppercase tracking-wide text-slate-500">{list.length} order{list.length === 1 ? "" : "s"} without terms</p>
            <ul className="divide-y divide-slate-100">
              {list.map((o) => (
                <li key={o.id}>
                  <button type="button" onClick={() => select(o.id)} data-testid="terms-row" data-order={o.id}
                    className={`flex w-full items-center justify-between gap-3 px-4 py-3 text-left text-xs hover:bg-slate-50 ${selectedId === o.id ? "bg-slate-50" : ""}`}>
                    <span><span className="font-bold text-slate-900">{o.id}</span><br /><span className="text-slate-500">{o.customer || o.customerName} · {o.date} · {o.status}</span></span>
                    <span className="text-right"><span className="font-semibold">{usd(toCents(o.total))}</span><br /><span className={toCents(o.outstandingBalance) > 0 ? "text-rose-600" : "text-slate-400"}>owes {usd(toCents(o.outstandingBalance))}</span></span>
                  </button>
                </li>
              ))}
            </ul>
          </div>

          <div data-testid="terms-detail">
            {!selected ? (
              <div className="rounded-xl border border-dashed border-slate-200 bg-white px-6 py-16 text-center text-xs text-slate-400">Select an order to review its evidence.</div>
            ) : (
              <div className="space-y-4 rounded-xl border border-slate-200 bg-white p-5">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <h2 className="text-sm font-bold text-slate-900">{selected.id} <span className="font-normal text-slate-500">· {selected.customer || selected.customerName}</span></h2>
                  <span className="text-[11px] text-slate-500">order date {selected.date} · {selected.status}{selected.deliveredAt ? ` · delivered ${selected.deliveredAt.slice(0, 10)}` : ""}</span>
                </div>
                <dl className="grid grid-cols-3 gap-2 text-xs">
                  <div className="rounded-lg bg-slate-50 p-2"><dt className="text-slate-500">Total</dt><dd className="font-bold">{usd(toCents(selected.total))}</dd></div>
                  <div className="rounded-lg bg-slate-50 p-2"><dt className="text-slate-500">Paid</dt><dd className="font-bold">{usd(toCents(selected.amountPaid))}</dd></div>
                  <div className="rounded-lg bg-slate-50 p-2"><dt className="text-slate-500">Outstanding</dt><dd className="font-bold">{usd(toCents(selected.outstandingBalance))}</dd></div>
                </dl>

                <div>
                  <p className="mb-1 text-[11px] font-bold uppercase tracking-wide text-slate-500">Payment history</p>
                  {(selected.payments ?? []).length === 0 ? <p className="text-xs text-slate-400">No payments recorded.</p> : (
                    <ul className="space-y-1 text-xs" data-testid="terms-payments">
                      {(selected.payments ?? []).map((p) => (
                        <li key={p.id} className="flex justify-between gap-2 rounded-lg border border-slate-100 px-2 py-1">
                          <span>{p.paymentDate} · {p.paymentMethod || "—"}{p.reference ? ` · ${p.reference}` : ""}{p.recordedBy ? " · recorded in the app" : ""}</span>
                          <b>{usd(toCents(p.amount))}</b>
                        </li>
                      ))}
                    </ul>
                  )}
                </div>

                <div>
                  <p className="mb-1 text-[11px] font-bold uppercase tracking-wide text-slate-500">What the records show</p>
                  <ul className="space-y-1.5" data-testid="terms-evidence">
                    {lines.map((l, i) => { const k = KIND[l.kind]; return (
                      <li key={i} className={`flex gap-2 rounded-lg border px-2 py-1.5 text-xs ${k.cls}`} data-kind={l.kind}>
                        <k.Icon className="mt-0.5 h-3.5 w-3.5 shrink-0" /><span><b>{k.label}:</b> {l.text}</span>
                      </li>); })}
                  </ul>
                  <p className="mt-1.5 text-[11px] text-slate-500" data-testid="terms-lean">
                    {lean.lean === "none" ? "The records do not point clearly either way. Leaving the order unclassified is a valid choice." : `Records lean towards ${TERMS_LABEL[lean.lean]} (${lean.strength === "confirmed" ? "supported by confirmed facts" : "weak: ambiguous evidence only"}). This is not a decision; nothing is pre-selected.`}
                  </p>
                </div>

                <fieldset className="space-y-2" data-testid="terms-choice">
                  <legend className="mb-1 text-[11px] font-bold uppercase tracking-wide text-slate-500">Payment terms for this order</legend>
                  {(["paid_at_sale", "credit"] as PaymentTerms[]).map((t) => (
                    <label key={t} className={`flex cursor-pointer gap-2 rounded-lg border px-3 py-2 text-xs ${choice === t ? "border-slate-900 bg-slate-50" : "border-slate-200"}`}>
                      <input type="radio" name="terms" value={t} checked={choice === t} onChange={() => setChoice(t)} data-testid={`terms-radio-${t}`} className="mt-0.5" />
                      <span><b>{TERMS_LABEL[t]}</b><br /><span className="text-slate-500">{CONSEQUENCE[t]}</span></span>
                    </label>
                  ))}
                </fieldset>

                <div>
                  <div className="mb-1 flex items-center justify-between">
                    <label htmlFor="terms-note" className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Evidence note (kept in the audit trail)</label>
                    <button type="button" onClick={() => setNote(evidenceSummary(lines).slice(0, MAX_EVIDENCE_CHARS))} data-testid="terms-insert-facts" className="text-[11px] font-semibold text-blue-700 hover:underline">Insert recorded facts</button>
                  </div>
                  <textarea id="terms-note" value={note} onChange={(e) => setNote(e.target.value.slice(0, MAX_EVIDENCE_CHARS))} rows={3} data-testid="terms-note"
                    placeholder="Why is this classification justified? State what you know and where it comes from."
                    className="w-full rounded-lg border border-slate-200 px-3 py-2 text-xs focus:border-slate-400 focus:outline-none" />
                  <p className="text-[11px] text-slate-400">At least {MIN_EVIDENCE_CHARS} characters. {note.trim().length}/{MAX_EVIDENCE_CHARS}</p>
                </div>

                <button type="button" disabled={!choice || !noteOk} onClick={() => { setUnderstood(false); setConfirming(true); }} data-testid="terms-review-button"
                  className="inline-flex h-9 items-center rounded-xl bg-slate-900 px-4 text-xs font-semibold text-white hover:bg-slate-800 disabled:cursor-not-allowed disabled:opacity-40">
                  Review and confirm…
                </button>
              </div>
            )}
          </div>
        </div>
      )}

      {confirming && selected && choice && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/50 p-4" role="dialog" aria-modal="true" data-testid="terms-confirm">
          <div className="w-full max-w-md space-y-3 rounded-2xl bg-white p-5 shadow-xl">
            <h3 className="text-sm font-bold text-slate-900">Record {TERMS_LABEL[choice]} for {selected.id}?</h3>
            <p className="text-xs text-slate-600">{CONSEQUENCE[choice]}</p>
            <p className="rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-600"><b>Evidence note:</b> {note.trim()}</p>
            <p className="text-xs font-semibold text-rose-700">This is permanent. The terms cannot be changed afterwards, and an audit entry is written. Totals, payments and balances are not changed.</p>
            <label className="flex cursor-pointer items-start gap-2 text-xs text-slate-700">
              <input type="checkbox" checked={understood} onChange={(e) => setUnderstood(e.target.checked)} data-testid="terms-understood" className="mt-0.5" />
              I have reviewed the evidence and understand this cannot be undone.
            </label>
            <div className="flex justify-end gap-2">
              <button type="button" onClick={() => setConfirming(false)} disabled={saving} className="h-9 rounded-xl border border-slate-200 px-3 text-xs font-semibold text-slate-700 hover:bg-slate-50">Cancel</button>
              <button type="button" onClick={save} disabled={!understood || saving} data-testid="terms-confirm-save"
                className="inline-flex h-9 items-center gap-1.5 rounded-xl bg-slate-900 px-4 text-xs font-semibold text-white hover:bg-slate-800 disabled:cursor-not-allowed disabled:opacity-40">
                {saving && <Loader2 className="h-3.5 w-3.5 animate-spin" />} Record {TERMS_LABEL[choice]}
              </button>
            </div>
          </div>
        </div>
      )}

      <p className="text-[11px] text-slate-400"><Link href="/admin/financial" className="underline">Back to Financial Management</Link></p>
    </div>
  );
}
