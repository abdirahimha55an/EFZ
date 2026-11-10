"use client";

/**
 * Expense dialogs: submit / edit, a reason prompt (reject, void, withdraw, void payment), record payment and the detail view with its timeline.
 * They validate for instant feedback with lib/finance/expenses; the database rules (migration 33) decide and are shown verbatim when they refuse.
 */

import { useEffect, useState, type ReactNode } from "react";
import { Loader2, X } from "lucide-react";
import type { Expense, ExpenseCategory, ExpenseEvent, ExpenseInput, ExpensePayment, Order } from "@/lib/types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { efzToday, formatEfzDateTime } from "@/lib/dates";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { KIND_LABEL, PAYMENT_LABEL, PAYMENT_METHODS, STATUS_LABEL, money, validateExpense, type ExpenseActor } from "@/lib/finance/expenses";
import { actionsFor } from "@/lib/finance/expenses";
import { cn } from "@/lib/utils";

const label = "text-[10px] font-bold uppercase tracking-widest text-slate-600";
const field = "h-11 w-full rounded-xl border border-slate-200 bg-slate-50 px-3 text-sm";

function Shell({ title, subtitle, onClose, children, wide, testId }: { title: string; subtitle?: string; onClose: () => void; children: ReactNode; wide?: boolean; testId: string }) {
  return (
    <div className="fixed inset-0 z-[120] flex items-center justify-center overflow-y-auto bg-slate-900/60 p-4" role="dialog" aria-label={title} data-testid={testId}>
      <div className={cn("my-auto w-full rounded-2xl bg-white p-6 shadow-2xl", wide ? "max-w-3xl" : "max-w-xl")}>
        <div className="mb-4 flex items-start justify-between gap-3">
          <div>
            {subtitle && <p className="text-[10px] font-bold uppercase tracking-widest text-slate-400">{subtitle}</p>}
            <h3 className="text-xl font-bold text-slate-900">{title}</h3>
          </div>
          <button type="button" aria-label="Close" onClick={onClose} className="rounded-full border border-slate-200 p-2 text-slate-500"><X className="h-4 w-4" /></button>
        </div>
        {children}
      </div>
    </div>
  );
}

const FieldError = ({ text }: { text?: string }) => (text ? <p className="mt-1 text-[11px] font-semibold text-red-600">{text}</p> : null);

// ---------------------------------------------------------------------------------------------------------------- submit / edit
export function ExpenseFormDialog({ expense, categories, orders, onClose, onSaved }: {
  expense: Expense | null; categories: ExpenseCategory[]; orders: Order[]; onClose: () => void; onSaved: (message: string) => void;
}) {
  const today = efzToday();
  const [form, setForm] = useState<ExpenseInput>(() => expense
    ? { categoryId: expense.categoryId, description: expense.description, amount: expense.amount.toFixed(2), expenseDate: expense.expenseDate, paymentMethod: expense.paymentMethod, vendor: expense.vendor, orderId: expense.orderId ?? "", notes: expense.notes }
    : { categoryId: "", description: "", amount: "", expenseDate: today, paymentMethod: "", vendor: "", orderId: "", notes: "" });
  const [errors, setErrors] = useState<ReturnType<typeof validateExpense>>({});
  const [saving, setSaving] = useState(false);
  const [serverError, setServerError] = useState<string | null>(null);
  const category = categories.find((c) => c.id === form.categoryId);
  const active = categories.filter((c) => c.isActive || c.id === expense?.categoryId);
  const set = (patch: Partial<ExpenseInput>) => setForm((f) => ({ ...f, ...patch }));

  const save = async () => {
    const found = validateExpense(form, categories, today);
    setErrors(found);
    if (Object.keys(found).length) return;
    setSaving(true); setServerError(null);
    try {
      const db = getDb();
      if (expense) await db.expenses.edit(expense.id, form); else await db.expenses.submit(form);
      onSaved(expense ? (expense.status === "rejected" ? "Expense resubmitted for approval." : "Expense updated.") : "Expense submitted for approval.");
    } catch (error) {
      setServerError(describeDbError(error));
    } finally { setSaving(false); }
  };

  return (
    <Shell testId="expense-form" title={expense ? `Edit ${expense.reference}` : "New expense"} subtitle={expense?.status === "rejected" ? "Saving resubmits it for approval" : "Goes to approval before it counts"} onClose={onClose}>
      {expense?.status === "rejected" && expense.rejectionReason && (
        <p className="mb-3 rounded-xl bg-red-50 p-3 text-xs text-red-700"><strong>Rejected:</strong> {expense.rejectionReason}</p>
      )}
      <div className="space-y-3">
        <div>
          <label className={label} htmlFor="exp-category">Category *</label>
          <select id="exp-category" className={field} value={form.categoryId} onChange={(e) => set({ categoryId: e.target.value, orderId: categories.find((c) => c.id === e.target.value)?.kind === "direct_order" ? form.orderId : "" })}>
            <option value="">Choose a category…</option>
            <optgroup label="Direct order expenses (linked to an order)">{active.filter((c) => c.kind === "direct_order").map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</optgroup>
            <optgroup label="Operating expenses">{active.filter((c) => c.kind === "operating").map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</optgroup>
          </select>
          <FieldError text={errors.categoryId} />
          {category && <p className="mt-1 text-[11px] text-slate-500">{KIND_LABEL[category.kind]}{category.kind === "direct_order" ? ": pick the order it was spent on." : ": a general business cost, not tied to one order."}</p>}
        </div>
        {category?.kind === "direct_order" && (
          <div>
            <label className={label} htmlFor="exp-order">Order *</label>
            <select id="exp-order" className={field} value={form.orderId ?? ""} onChange={(e) => set({ orderId: e.target.value })}>
              <option value="">Choose the order…</option>
              {orders.map((o) => <option key={o.id} value={o.id}>{o.id} · {o.customer} · {o.date}{o.status === "cancelled" ? " (cancelled)" : ""}</option>)}
            </select>
            <FieldError text={errors.orderId} />
          </div>
        )}
        <div>
          <label className={label} htmlFor="exp-desc">Description *</label>
          <Input id="exp-desc" className="h-11 rounded-xl" value={form.description} onChange={(e) => set({ description: e.target.value })} placeholder="e.g. Delivery to Hodan arena" maxLength={300} />
          <FieldError text={errors.description} />
        </div>
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label className={label} htmlFor="exp-amount">Amount (USD) *</label>
            <Input id="exp-amount" className="h-11 rounded-xl" inputMode="decimal" value={form.amount} onChange={(e) => set({ amount: e.target.value })} placeholder="0.00" />
            <FieldError text={errors.amount} />
          </div>
          <div>
            <label className={label} htmlFor="exp-date">Expense date *</label>
            <Input id="exp-date" className="h-11 rounded-xl" type="date" max={today} value={form.expenseDate} onChange={(e) => set({ expenseDate: e.target.value })} />
            <FieldError text={errors.expenseDate} />
          </div>
        </div>
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label className={label} htmlFor="exp-method">Paid / to be paid by</label>
            <select id="exp-method" className={field} value={form.paymentMethod ?? ""} onChange={(e) => set({ paymentMethod: e.target.value })}>
              <option value="">Not specified</option>
              {PAYMENT_METHODS.map((m) => <option key={m}>{m}</option>)}
            </select>
          </div>
          <div>
            <label className={label} htmlFor="exp-vendor">Vendor / recipient</label>
            <Input id="exp-vendor" className="h-11 rounded-xl" value={form.vendor ?? ""} onChange={(e) => set({ vendor: e.target.value })} maxLength={200} />
            <FieldError text={errors.vendor} />
          </div>
        </div>
        <div>
          <label className={label} htmlFor="exp-notes">Notes</label>
          <Input id="exp-notes" className="h-11 rounded-xl" value={form.notes ?? ""} onChange={(e) => set({ notes: e.target.value })} maxLength={1000} />
          <FieldError text={errors.notes} />
        </div>
        <p className="text-[11px] text-slate-500">Receipt uploads are not available yet; keep the receipt and quote its number in the notes.</p>
        {serverError && <p className="rounded-xl bg-red-50 p-3 text-xs font-semibold text-red-700" data-testid="expense-form-error">{serverError}</p>}
      </div>
      <div className="mt-6 flex gap-3">
        <Button type="button" variant="outline" onClick={onClose} className="h-11 flex-1 rounded-xl">Cancel</Button>
        <Button type="button" disabled={saving} onClick={save} className="h-11 flex-1 rounded-xl bg-slate-900 text-white" data-testid="expense-save">
          {saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}{expense ? (expense.status === "rejected" ? "Resubmit" : "Save changes") : "Submit for approval"}
        </Button>
      </div>
    </Shell>
  );
}

// ---------------------------------------------------------------------------------------------------------------- reason prompt
export function ReasonDialog({ title, subtitle, prompt, confirm, danger, run, onClose, onDone }: {
  title: string; subtitle?: string; prompt: string; confirm: string; danger?: boolean; run: (reason: string) => Promise<void>; onClose: () => void; onDone: () => void;
}) {
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const go = async () => {
    if (reason.trim().length < 3) { setError("Please give a reason (at least 3 characters)."); return; }
    setSaving(true); setError(null);
    try { await run(reason.trim()); onDone(); } catch (e) { setError(describeDbError(e)); } finally { setSaving(false); }
  };
  return (
    <Shell testId="expense-reason" title={title} subtitle={subtitle} onClose={onClose}>
      <label className={label} htmlFor="exp-reason">{prompt}</label>
      <textarea id="exp-reason" className="mt-1 min-h-24 w-full rounded-xl border border-slate-200 bg-slate-50 p-3 text-sm" value={reason} maxLength={500} onChange={(e) => setReason(e.target.value)} />
      {error && <p className="mt-2 text-[11px] font-semibold text-red-600" data-testid="expense-reason-error">{error}</p>}
      <div className="mt-5 flex gap-3">
        <Button type="button" variant="outline" onClick={onClose} className="h-11 flex-1 rounded-xl">Cancel</Button>
        <Button type="button" disabled={saving} onClick={go} data-testid="expense-reason-confirm" className={cn("h-11 flex-1 rounded-xl text-white", danger ? "bg-red-600 hover:bg-red-700" : "bg-slate-900")}>
          {saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}{confirm}
        </Button>
      </div>
    </Shell>
  );
}

// ---------------------------------------------------------------------------------------------------------------- payment
export function PaymentDialog({ expense, onClose, onDone }: { expense: Expense; onClose: () => void; onDone: () => void }) {
  const today = efzToday();
  const [form, setForm] = useState({ amount: expense.outstandingAmount.toFixed(2), paidOn: today, method: expense.paymentMethod || "Cash", reference: "" });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const go = async () => {
    const amount = Number(form.amount);
    if (!/^\d+(\.\d{1,2})?$/.test(form.amount.trim()) || amount <= 0) { setError("Enter an amount above 0 with at most 2 decimals."); return; }
    if (amount > expense.outstandingAmount + 0.0001) { setError(`That is more than the ${money(Math.round(expense.outstandingAmount * 100))} still to pay.`); return; }
    setSaving(true); setError(null);
    try { await getDb().expenses.recordPayment(expense.id, { amount: form.amount.trim(), paidOn: form.paidOn, method: form.method, reference: form.reference }); onDone(); }
    catch (e) { setError(describeDbError(e)); } finally { setSaving(false); }
  };
  return (
    <Shell testId="expense-payment" title={`Pay ${expense.reference}`} subtitle="Records cash going out. Approval is already done" onClose={onClose}>
      <div className="mb-4 grid grid-cols-3 gap-3 text-xs">
        <div className="rounded-xl bg-slate-50 p-3"><span className="block text-[9px] uppercase tracking-widest text-slate-400">Approved</span><strong>{money(Math.round(expense.amount * 100))}</strong></div>
        <div className="rounded-xl bg-slate-50 p-3"><span className="block text-[9px] uppercase tracking-widest text-slate-400">Paid so far</span><strong>{money(Math.round(expense.paidAmount * 100))}</strong></div>
        <div className="rounded-xl bg-slate-50 p-3"><span className="block text-[9px] uppercase tracking-widest text-slate-400">Still to pay</span><strong>{money(Math.round(expense.outstandingAmount * 100))}</strong></div>
      </div>
      <div className="space-y-3">
        <div className="grid grid-cols-2 gap-3">
          <div><label className={label} htmlFor="pay-amount">Amount (USD)</label><Input id="pay-amount" className="h-11 rounded-xl" inputMode="decimal" value={form.amount} onChange={(e) => setForm({ ...form, amount: e.target.value })} /></div>
          <div><label className={label} htmlFor="pay-date">Paid on</label><Input id="pay-date" className="h-11 rounded-xl" type="date" max={today} value={form.paidOn} onChange={(e) => setForm({ ...form, paidOn: e.target.value })} /></div>
        </div>
        <div className="grid grid-cols-2 gap-3">
          <div><label className={label} htmlFor="pay-method">Method</label>
            <select id="pay-method" className={field} value={form.method} onChange={(e) => setForm({ ...form, method: e.target.value })}>{PAYMENT_METHODS.map((m) => <option key={m}>{m}</option>)}</select></div>
          <div><label className={label} htmlFor="pay-ref">Reference</label><Input id="pay-ref" className="h-11 rounded-xl" value={form.reference} maxLength={120} onChange={(e) => setForm({ ...form, reference: e.target.value })} /></div>
        </div>
        {error && <p className="rounded-xl bg-red-50 p-3 text-xs font-semibold text-red-700" data-testid="expense-payment-error">{error}</p>}
      </div>
      <div className="mt-6 flex gap-3">
        <Button type="button" variant="outline" onClick={onClose} className="h-11 flex-1 rounded-xl">Cancel</Button>
        <Button type="button" disabled={saving} onClick={go} data-testid="expense-payment-confirm" className="h-11 flex-1 rounded-xl bg-slate-900 text-white">{saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Record payment</Button>
      </div>
    </Shell>
  );
}

// ---------------------------------------------------------------------------------------------------------------- detail
const EVENT_TEXT: Record<string, string> = {
  submitted: "Submitted", edited: "Edited", resubmitted: "Resubmitted after rejection", approved: "Approved", rejected: "Rejected", voided: "Voided",
  payment_recorded: "Payment recorded", payment_voided: "Payment voided",
};

export function ExpenseDetailDialog({ expense, me, categories, onClose, onAction }: {
  expense: Expense; me: ExpenseActor; categories: ExpenseCategory[]; onClose: () => void;
  onAction: (action: "edit" | "approve" | "reject" | "pay" | "withdraw" | "voidApproved" | "voidPayment", payload?: ExpensePayment) => void;
}) {
  const [events, setEvents] = useState<ExpenseEvent[] | null>(null);
  const [payments, setPayments] = useState<ExpensePayment[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const db = getDb();
        const [ev, pay] = await Promise.all([db.expenses.events(expense.id), db.expenses.payments(expense.id)]);
        if (!cancelled) { setEvents(ev); setPayments(pay); }
      } catch (e) { if (!cancelled) setError(describeDbError(e)); }
    })();
    return () => { cancelled = true; };
  }, [expense.id, expense.status, expense.paidAmount]);
  const a = actionsFor(expense, me);
  const category = categories.find((c) => c.id === expense.categoryId);
  const row = (k: string, v: ReactNode) => <div className="rounded-xl bg-slate-50 p-3"><span className="block text-[9px] uppercase tracking-widest text-slate-400">{k}</span><span className="text-sm font-semibold text-slate-900">{v || "—"}</span></div>;
  return (
    <Shell testId="expense-detail" wide title={expense.reference} subtitle={`${KIND_LABEL[expense.kind]} · ${STATUS_LABEL[expense.status]}`} onClose={onClose}>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        {row("Amount", money(Math.round(expense.amount * 100)))}
        {row("Expense date", expense.expenseDate)}
        {row("Category", category?.name ?? expense.categoryId)}
        {row("Vendor / recipient", expense.vendor)}
        {row("Order", expense.orderId)}
        {row("Method", expense.paymentMethod)}
        {row("Submitted by", `${expense.submittedByName} · ${formatEfzDateTime(expense.submittedAt)}`)}
        {row("Decision", expense.decidedByName ? `${expense.decidedByName} · ${expense.decidedAt ? formatEfzDateTime(expense.decidedAt) : ""}` : "")}
        {row("Payment", expense.paymentStatus ? `${PAYMENT_LABEL[expense.paymentStatus]} · paid ${money(Math.round(expense.paidAmount * 100))}, to pay ${money(Math.round(expense.outstandingAmount * 100))}` : "Not payable until approved")}
      </div>
      <p className="mt-3 text-sm text-slate-700"><strong>Description:</strong> {expense.description}</p>
      {expense.notes && <p className="mt-1 text-sm text-slate-700"><strong>Notes:</strong> {expense.notes}</p>}
      {expense.rejectionReason && <p className="mt-2 rounded-xl bg-red-50 p-3 text-xs text-red-700"><strong>Rejected:</strong> {expense.rejectionReason}</p>}
      {expense.voidReason && <p className="mt-2 rounded-xl bg-slate-100 p-3 text-xs text-slate-700"><strong>Voided by {expense.voidedByName}:</strong> {expense.voidReason}</p>}

      <div className="mt-4 flex flex-wrap gap-2" data-testid="expense-actions">
        {a.edit && <Button type="button" variant="outline" className="rounded-xl" onClick={() => onAction("edit")}>{expense.status === "rejected" ? "Edit & resubmit" : "Edit"}</Button>}
        {a.approve && <Button type="button" className="rounded-xl bg-green-600 text-white hover:bg-green-700" data-testid="act-approve" onClick={() => onAction("approve")}>Approve</Button>}
        {a.reject && <Button type="button" variant="outline" className="rounded-xl text-red-700" data-testid="act-reject" onClick={() => onAction("reject")}>Reject…</Button>}
        {a.pay && <Button type="button" className="rounded-xl bg-slate-900 text-white" data-testid="act-pay" onClick={() => onAction("pay")}>Record payment</Button>}
        {a.voidApproved && <Button type="button" variant="outline" className="rounded-xl text-red-700" data-testid="act-void" onClick={() => onAction("voidApproved")}>Void…</Button>}
        {a.withdraw && <Button type="button" variant="outline" className="rounded-xl text-slate-700" data-testid="act-withdraw" onClick={() => onAction("withdraw")}>Withdraw…</Button>}
        {expense.status === "approved" && !a.voidApproved && expense.paidAmount > 0 && me.approve && <span className="self-center text-[11px] text-slate-500">To void it, first void its payments.</span>}
      </div>

      {error && <p className="mt-3 text-xs font-semibold text-red-600">{error}</p>}
      <div className="mt-5 grid gap-5 sm:grid-cols-2">
        <div>
          <h4 className="mb-2 text-sm font-bold text-slate-800">Payments</h4>
          {payments === null ? <Loader2 className="h-4 w-4 animate-spin text-slate-400" /> : payments.length === 0 ? <p className="text-xs text-slate-400">No payments recorded.</p> : (
            <ul className="space-y-1.5" data-testid="expense-payments">
              {payments.map((p) => (
                <li key={p.id} className={cn("rounded-lg border border-slate-100 p-2 text-xs", p.voidedAt && "opacity-60")}>
                  <div className="flex items-center justify-between gap-2">
                    <span className={cn("font-semibold", p.voidedAt && "line-through")}>{money(Math.round(p.amount * 100))}</span>
                    <span className="text-slate-500">{p.paidOn} · {p.method}{p.reference ? ` · ${p.reference}` : ""}</span>
                  </div>
                  <div className="flex items-center justify-between gap-2 text-[11px] text-slate-500">
                    <span>{p.voidedAt ? `Voided: ${p.voidReason}` : `By ${p.recordedByName}`}</span>
                    {!p.voidedAt && me.pay && expense.status === "approved" && <button type="button" className="font-semibold text-red-600 hover:underline" data-testid="act-void-payment" onClick={() => onAction("voidPayment", p)}>Void…</button>}
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
        <div>
          <h4 className="mb-2 text-sm font-bold text-slate-800">History</h4>
          {events === null ? <Loader2 className="h-4 w-4 animate-spin text-slate-400" /> : (
            <ol className="space-y-1.5" data-testid="expense-timeline">
              {events.map((ev) => (
                <li key={ev.id} className="rounded-lg border border-slate-100 p-2 text-xs">
                  <div className="flex justify-between gap-2"><span className="font-semibold text-slate-800">{EVENT_TEXT[ev.event] ?? ev.event}</span><span className="text-slate-400">{formatEfzDateTime(ev.occurredAt)}</span></div>
                  <div className="text-slate-500">{ev.actorName}{ev.note ? ` · ${ev.note}` : ""}{ev.event === "edited" && Array.isArray(ev.details.changed) ? ` · changed: ${(ev.details.changed as string[]).join(", ")}` : ""}</div>
                </li>
              ))}
            </ol>
          )}
        </div>
      </div>
    </Shell>
  );
}
