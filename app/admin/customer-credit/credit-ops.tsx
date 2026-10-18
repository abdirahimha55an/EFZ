"use client";

/**
 * Credit policy v2 controls (migration 25): the approved rules and the company-wide cap, the defaults / escalations / reminders panel, and disputes.
 * Every action here is a Super Admin database function; this file only asks for the inputs and shows the database's own answers.
 */

import { useState } from "react";
import { getDb } from "@/lib/supabase/db";
import {
  MIN_OVERRIDE, MIN_REASON, canVoidDefault, capSummary, extensionProblem, money, noteProblem, rulesProblem,
  type CreditDispute, type CreditOperations, type CreditPolicy,
} from "@/lib/customerFinance";

type RunFn = (what: string, fn: () => Promise<void>) => Promise<void>;
const input = "h-8 rounded-lg border border-slate-200 px-2 text-xs focus:border-slate-400 focus:outline-none";
const btn = "rounded-lg bg-slate-900 px-3 py-1.5 text-[11px] font-semibold text-white disabled:opacity-40";
const btn2 = "rounded-lg border border-slate-200 bg-white px-3 py-1.5 text-[11px] font-semibold text-slate-700 hover:bg-slate-50 disabled:opacity-40";
const card = "rounded-xl border border-slate-200 bg-white p-4";

export function RulesCard({ policy, ops, busy, run }: { policy: CreditPolicy; ops: CreditOperations | null; busy: boolean; run: RunFn }) {
  const db = getDb();
  const [window, setWindow] = useState(policy.purchaseWindowDays?.toString() ?? "");
  const [initial, setInitial] = useState(policy.initialCreditLimit?.toString() ?? "");
  const [percent, setPercent] = useState(policy.companyCapPercent?.toString() ?? "");
  const [months, setMonths] = useState(policy.capBasisMonths?.toString() ?? "");
  const [allow, setAllow] = useState(policy.allowRequirementOverride ?? false);
  const [reason, setReason] = useState("");
  const draft = { purchaseWindowDays: window === "" ? null : Number(window), initialLimit: initial === "" ? null : Number(initial), capPercent: percent === "" ? null : Number(percent), capMonths: months === "" ? null : Number(months) };
  const issue = rulesProblem(draft, reason);
  return (
    <section className={card} data-testid="rules-card">
      <h2 className="text-sm font-bold text-slate-900">Credit rules and company-wide cap</h2>
      <p className="mb-3 text-xs text-slate-500">
        The initial limit is the most a customer can owe on credit at any time (not per order) and is the most any new or renewed limit may be. The company-wide cap is a percentage of the average monthly
        sales (non-cancelled orders by order date, the same figure as Sales and the daily sales view) over the previous complete calendar months. Automatic limit increases and late fees are not approved and cannot be switched on.
      </p>
      <div className="flex flex-wrap items-end gap-3 text-[11px] text-slate-500">
        <label>Purchase-history window (days)<br /><input className={`${input} w-24`} inputMode="numeric" value={window} onChange={(e) => setWindow(e.target.value)} data-testid="rules-window" /></label>
        <label>Initial credit limit ($)<br /><input className={`${input} w-24`} inputMode="decimal" value={initial} onChange={(e) => setInitial(e.target.value)} data-testid="rules-initial" /></label>
        <label>Company cap (% of average monthly sales)<br /><input className={`${input} w-24`} inputMode="decimal" value={percent} onChange={(e) => setPercent(e.target.value)} data-testid="rules-percent" /></label>
        <label>Cap basis (complete months)<br /><input className={`${input} w-24`} inputMode="numeric" value={months} onChange={(e) => setMonths(e.target.value)} data-testid="rules-months" /></label>
        <label className="flex items-center gap-2"><input type="checkbox" checked={allow} onChange={(e) => setAllow(e.target.checked)} data-testid="rules-override" /> Allow staff to authorize customers who do not meet the requirements (override with a recorded reason). Never covers a default.</label>
      </div>
      <div className="mt-3 flex flex-wrap items-end gap-2">
        <label className="text-[11px] text-slate-500">Reason for the change<br /><input className={`${input} w-72`} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="rules-reason" /></label>
        <button type="button" className={btn} disabled={busy || !!issue} data-testid="rules-save"
          onClick={() => void run("Credit rules saved.", () => db.financeAdmin.setCreditPolicyRules({ ...draft, allowOverride: allow }, reason))}>Save rules</button>
        {issue && reason.trim().length >= MIN_REASON && <span className="text-[11px] text-amber-700" data-testid="rules-issue">{issue}</span>}
      </div>
      {ops && (
        <p className={`mt-3 rounded-lg border px-3 py-2 text-[11px] ${ops.companyCap.sufficient ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-amber-200 bg-amber-50 text-amber-900"}`} data-testid="cap-summary">
          {capSummary(ops.companyCap)}
          {!ops.companyCap.sufficient && " Credit cannot be enabled, and no credit order is accepted, until an administrator has reviewed this."}
        </p>
      )}
    </section>
  );
}

export function OperationsCard({ ops, disputes, busy, run }: { ops: CreditOperations; disputes: CreditDispute[]; busy: boolean; run: RunFn }) {
  const db = getDb();
  const [note, setNote] = useState<Record<string, string>>({});
  return (
    <section className={card} data-testid="ops-card">
      <div className="flex items-center justify-between gap-3">
        <h2 className="text-sm font-bold text-slate-900">Defaults, follow-up and reminders</h2>
        <button type="button" className={btn2} disabled={busy} data-testid="run-checks"
          onClick={() => void run("Credit checks ran.", async () => { const r = await db.financeAdmin.runCreditChecks(); if (r.failed > 0) throw new Error(`${r.failed} reminder(s) failed to deliver; see below.`); })}>Run the daily checks now</button>
      </div>
      <p className="mb-3 text-xs text-slate-500">
        A missed due date revokes credit at once, with no grace period; paying settles the debt but does not restore credit. At 7 days overdue a staff follow-up is due; at 30 days a documented credit-risk review is required.
        Reminders are sent by the daily run (a scheduler must call it; see the deployment checklist). The customer-side check never waits for that run.
      </p>
      {ops.defaults.length === 0 ? <p className="text-xs text-slate-400" data-testid="ops-empty">No default has been recorded.</p> : (
        <ul className="divide-y divide-slate-100 text-xs">
          {ops.defaults.map((d) => (
            <li key={d.id} className="space-y-1 py-2" data-testid="default-row" data-status={d.status}>
              <p><b>{d.customerName}</b> · invoice INV-{d.orderId} · due {d.dueDate} · defaulted {d.defaultedOn} · ${Number(d.amountAtDefault).toFixed(2)} unpaid then ·{" "}
                <span className={d.status === "open" ? "font-semibold text-red-700" : d.status === "settled" ? "text-emerald-700" : "text-slate-500"}>{d.status === "open" ? `OPEN, ${d.daysOverdue ?? 0} days overdue, ${money(d.outstanding)} owed` : d.status === "settled" ? `settled ${d.settledAt?.slice(0, 10)} (credit NOT restored${d.requalifiedAt ? "; requalified and approved again" : ""})` : "voided after a billing error (record kept)"}</span></p>
              {d.followUpDue && <p className="text-amber-700" data-testid="followup">Staff follow-up due (7+ days overdue).</p>}
              {d.reviewRequiredAt && !d.reviewedAt && (
                <div className="flex flex-wrap items-center gap-2" data-testid="review-required">
                  <span className="text-red-700">Credit-risk review required (30+ days overdue).</span>
                  <input className={`${input} w-80`} placeholder={`Document the review (min ${MIN_OVERRIDE} characters)`} value={note[d.id] ?? ""} onChange={(e) => setNote({ ...note, [d.id]: e.target.value })} />
                  <button type="button" className={btn2} disabled={busy || !!noteProblem(note[d.id] ?? "")} data-testid="review-save" onClick={() => void run("Review recorded.", () => db.financeAdmin.recordCreditRiskReview(d.id, note[d.id]))}>Record review</button>
                </div>
              )}
              {d.reviewedAt && <p className="text-slate-500">Reviewed {d.reviewedAt.slice(0, 10)}: {d.reviewNote}</p>}
              {canVoidDefault(d, disputes, d.orderId) && (
                <div className="flex flex-wrap items-center gap-2" data-testid="void-form">
                  <span className="text-slate-600">A dispute on this invoice was resolved as a billing error.</span>
                  <input className={`${input} w-80`} placeholder={`Reason for voiding (min ${MIN_OVERRIDE} characters)`} value={note["v" + d.id] ?? ""} onChange={(e) => setNote({ ...note, ["v" + d.id]: e.target.value })} />
                  <button type="button" className={btn2} disabled={busy || !!noteProblem(note["v" + d.id] ?? "")} data-testid="void-save"
                    onClick={() => void run("Default voided (the record is kept).", () => db.financeAdmin.voidCreditDefault(d.id, disputes.find((x) => x.orderId === d.orderId && x.status === "resolved_billing_error")!.id, note["v" + d.id]))}>Void this default</button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
      {ops.failedReminders.length > 0 && (
        <div className="mt-3 rounded-lg border border-rose-200 bg-rose-50 p-3 text-[11px] text-rose-900" data-testid="failed-reminders">
          <p className="font-semibold">Reminders that failed to deliver (retried by each daily run, up to 5 attempts)</p>
          <ul className="list-disc pl-4">{ops.failedReminders.map((f) => <li key={f.id}>{f.kind} to {f.audience} for INV-{f.orderId}: {f.attempts} attempt(s), {f.lastError || "no detail"}</li>)}</ul>
        </div>
      )}
    </section>
  );
}

export function DisputesCard({ disputes, busy, run }: { disputes: CreditDispute[]; busy: boolean; run: RunFn }) {
  const db = getDb();
  const [note, setNote] = useState<Record<string, string>>({});
  const open = disputes.filter((d) => d.status === "open" || d.status === "investigating");
  return (
    <section className={card} data-testid="disputes-card">
      <h2 className="text-sm font-bold text-slate-900">Credit invoice disputes {open.length > 0 && <span className="ml-2 rounded-full bg-amber-100 px-2 py-0.5 text-[10px] text-amber-800" data-testid="disputes-open-count">{open.length} open</span>}</h2>
      <p className="mb-3 text-xs text-slate-500">
        An open dispute stops NEW credit orders for that customer. It does not pause the due date or remove a default. If a dispute proves a billing error, correct the invoice through the normal order tools, resolve the dispute as a billing error, and
        only then can the default be voided (kept on record, marked, with the reason). Staff notes are never shown to customers.
      </p>
      {disputes.length === 0 ? <p className="text-xs text-slate-400" data-testid="disputes-empty">No disputes.</p> : (
        <ul className="divide-y divide-slate-100 text-xs">
          {disputes.map((d) => (
            <li key={d.id} className="space-y-1 py-2" data-testid="dispute-row" data-status={d.status}>
              <p><b>{d.customerName}</b> · INV-{d.orderId} · {d.status.replace("_", " ")} · opened {d.openedAt.slice(0, 10)}{d.disputedAmount ? ` · $${Number(d.disputedAmount).toFixed(2)} disputed` : ""}</p>
              <p className="text-slate-600">Customer says: {d.reason}</p>
              {d.staffNotes && <p className="whitespace-pre-line text-slate-500">Staff notes: {d.staffNotes}</p>}
              {d.resolution && <p className="text-slate-500">Resolution: {d.resolution}</p>}
              {(d.status === "open" || d.status === "investigating") && (
                <div className="flex flex-wrap items-center gap-2">
                  <input className={`${input} w-96`} placeholder={`Note or resolution (min ${MIN_OVERRIDE} characters)`} value={note[d.id] ?? ""} onChange={(e) => setNote({ ...note, [d.id]: e.target.value })} data-testid="dispute-note" />
                  <button type="button" className={btn2} disabled={busy || (note[d.id] ?? "").trim().length < 5} data-testid="dispute-investigate" onClick={() => void run("Dispute updated.", () => db.financeAdmin.updateCreditDispute(d.id, null, note[d.id]))}>Add note / investigate</button>
                  <button type="button" className={btn2} disabled={busy || !!noteProblem(note[d.id] ?? "")} data-testid="dispute-reject" onClick={() => void run("Dispute rejected.", () => db.financeAdmin.resolveCreditDispute(d.id, "rejected", note[d.id]))}>Resolve: rejected</button>
                  <button type="button" className={btn2} disabled={busy || !!noteProblem(note[d.id] ?? "")} data-testid="dispute-billing" onClick={() => void run("Dispute resolved as a billing error.", () => db.financeAdmin.resolveCreditDispute(d.id, "billing_error", note[d.id]))}>Resolve: billing error</button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

/** Extend one invoice's due date (before it is overdue). The original date stays on record. */
export function ExtensionForm({ orderId, currentDue, today, busy, run, onDone }: { orderId: string; currentDue: string; today: string; busy: boolean; run: RunFn; onDone: () => void }) {
  const db = getDb();
  const [date, setDate] = useState(""); const [reason, setReason] = useState("");
  const issue = extensionProblem({ currentDue, newDue: date, reason, today });
  return (
    <div className="mt-1 flex flex-wrap items-center gap-2" data-testid="extension-form">
      <input type="date" className={`${input} w-36`} value={date} onChange={(e) => setDate(e.target.value)} data-testid="extension-date" />
      <input className={`${input} w-72`} placeholder={`Reason (min ${MIN_OVERRIDE} characters)`} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="extension-reason" />
      <button type="button" className={btn2} disabled={busy || !!issue} data-testid="extension-save" onClick={() => void run(`Due date of INV-${orderId} extended.`, async () => { await db.financeAdmin.extendCreditDueDate(orderId, date, reason); onDone(); })}>Extend</button>
      {issue && reason.trim().length > 0 && <span className="text-[11px] text-amber-700" data-testid="extension-issue">{issue}</span>}
    </div>
  );
}
