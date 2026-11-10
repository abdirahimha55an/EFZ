"use client";

/**
 * Expenses (Finance): submit, approve / reject, pay, void. Every write is a database function (migration 33) that checks the caller,
 * writes an event and an audit line; this page offers only the buttons the person may use and shows the database's own sentence
 * when it refuses. Nobody approves their own expense. Approval makes an expense a cost; payment is a separate record.
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import { AlertCircle, Loader2, Plus, RefreshCw, Shield } from "lucide-react";
import { cn } from "@/lib/utils";
import type { AdminProfile, Expense, ExpenseCategory, ExpensePayment, Order } from "@/lib/types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";
import { efzToday, formatEfzTime } from "@/lib/dates";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  KIND_LABEL, NO_EXPENSE_FILTER, PAYMENT_LABEL, STATUS_LABEL, actionsFor, filterExpenses, money, summarizeExpenses,
  type ExpenseActor, type ExpenseFilter,
} from "@/lib/finance/expenses";
import { DataTable, SectionCard, type Column } from "@/components/analytics/primitives";
import { ApprovedExpensesSection } from "@/components/finance/ExpenseSections";
import { ExpenseDetailDialog, ExpenseFormDialog, PaymentDialog, ReasonDialog } from "@/components/finance/ExpenseDialogs";

const STATUS_STYLE: Record<Expense["status"], string> = {
  pending: "bg-amber-100 text-amber-700", approved: "bg-green-100 text-green-700", rejected: "bg-red-100 text-red-700", void: "bg-slate-200 text-slate-600",
};

type Loaded = { expenses: Expense[]; categories: ExpenseCategory[]; orders: Order[]; loadedAt: string };
type Modal =
  | { type: "none" }
  | { type: "form"; expense: Expense | null }
  | { type: "detail"; id: string }
  | { type: "pay"; expense: Expense }
  | { type: "approve"; expense: Expense }
  | { type: "reject" | "withdraw" | "voidApproved"; expense: Expense }
  | { type: "voidPayment"; expense: Expense; payment: ExpensePayment };

function Kpi({ label, value, sub, testId }: { label: string; value: string; sub?: string; testId: string }) {
  return (
    <div className="rounded-xl border border-slate-200 bg-white p-3.5 shadow-sm" data-testid={testId}>
      <p className="text-[11px] font-semibold text-slate-500">{label}</p>
      <p className="mt-1 text-xl font-bold tabular-nums text-slate-900">{value}</p>
      {sub && <p className="mt-0.5 text-[11px] text-slate-500">{sub}</p>}
    </div>
  );
}

export default function ExpensesPage() {
  const [profile, setProfile] = useState<AdminProfile | null>(null);
  const [data, setData] = useState<Loaded | null>(null);
  const [status, setStatus] = useState<"loading" | "ready" | "error" | "denied">("loading");
  const [loadError, setLoadError] = useState<string | null>(null);
  const [reloadKey, setReloadKey] = useState(0);
  const [refreshing, setRefreshing] = useState(false);
  const [filter, setFilter] = useState<ExpenseFilter>(NO_EXPENSE_FILTER);
  const [modal, setModal] = useState<Modal>({ type: "none" });
  const [notice, setNotice] = useState<{ type: "success" | "error"; message: string } | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!notice) return;
    const t = setTimeout(() => setNotice(null), 4000);
    return () => clearTimeout(t);
  }, [notice]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const db = getDb();
        const me = await db.auth.getProfile();
        if (cancelled) return;
        setProfile(me);
        const p = derivePermissions(me);
        if (!me || !p.accessExpenses) { setStatus("denied"); return; }
        const [expenses, categories, orders] = await Promise.all([
          db.expenses.list(), db.expenses.categories(), p.submitExpenses ? db.orders.listAll() : Promise.resolve([] as Order[]),
        ]);
        if (cancelled) return;
        setData({ expenses, categories, orders, loadedAt: new Date().toISOString() });
        setLoadError(null);
        setStatus("ready");
      } catch (error) {
        if (cancelled) return;
        const code = (error as { code?: string } | null)?.code ?? "";
        setLoadError(["PGRST205", "PGRST202", "42P01"].includes(code) ? "Expense management is not set up on this database yet." : describeDbError(error));
        setStatus("error");
      } finally {
        if (!cancelled) setRefreshing(false);
      }
    })();
    return () => { cancelled = true; };
  }, [reloadKey]);

  const perms = derivePermissions(profile);
  const me: ExpenseActor = useMemo(() => ({ id: profile?.id ?? "", submit: perms.submitExpenses, approve: perms.approveExpenses, pay: perms.payExpenses }),
    [profile, perms.submitExpenses, perms.approveExpenses, perms.payExpenses]);
  const seesAll = perms.viewExpenses || perms.approveExpenses || perms.payExpenses;
  const categoryName = useCallback((id: string) => data?.categories.find((c) => c.id === id)?.name ?? id, [data]);
  const rows = useMemo(() => (data ? filterExpenses(data.expenses, filter, me.id) : []), [data, filter, me.id]);
  const summary = useMemo(() => summarizeExpenses(data?.expenses ?? []), [data]);
  const detail = modal.type === "detail" && data ? data.expenses.find((e) => e.id === modal.id) ?? null : null;

  const refresh = () => { setRefreshing(true); setReloadKey((k) => k + 1); };
  const done = (message: string) => { setModal({ type: "none" }); setNotice({ type: "success", message }); refresh(); };

  const approve = async (e: Expense) => {
    setBusy(true);
    try { await getDb().expenses.decide(e.id, "approve"); done(`${e.reference} approved.`); }
    catch (error) { setNotice({ type: "error", message: describeDbError(error) }); setModal({ type: "none" }); }
    finally { setBusy(false); }
  };

  const openAction = (e: Expense, action: "edit" | "approve" | "reject" | "pay" | "withdraw" | "voidApproved" | "voidPayment", payment?: ExpensePayment) => {
    if (action === "edit") setModal({ type: "form", expense: e });
    else if (action === "voidPayment" && payment) setModal({ type: "voidPayment", expense: e, payment });
    else if (action === "pay") setModal({ type: "pay", expense: e });
    else if (action === "approve") setModal({ type: "approve", expense: e });
    else if (action === "reject" || action === "withdraw" || action === "voidApproved") setModal({ type: action, expense: e });
  };

  const columns: Column<Expense>[] = [
    { key: "ref", header: "Reference", primary: true, render: (e) => <button type="button" className="font-mono text-[11px] font-semibold text-brand-blue hover:underline" data-testid="expense-open" onClick={() => setModal({ type: "detail", id: e.id })}>{e.reference}</button> },
    { key: "date", header: "Date", render: (e) => e.expenseDate },
    { key: "cat", header: "Category", render: (e) => <span><span className="font-semibold text-slate-800">{categoryName(e.categoryId)}</span><span className="block text-[10px] text-slate-400">{KIND_LABEL[e.kind]}{e.orderId ? ` · ${e.orderId}` : ""}</span></span> },
    { key: "desc", header: "Description", render: (e) => <span className="block max-w-[16rem] truncate" title={e.description}>{e.description}{e.vendor ? <span className="text-slate-400"> · {e.vendor}</span> : null}</span> },
    { key: "amount", header: "Amount", align: "right", render: (e) => <span className="font-semibold">{money(Math.round(e.amount * 100))}</span> },
    { key: "status", header: "Status", render: (e) => <span className={cn("inline-flex rounded-full px-2 py-0.5 text-[10px] font-bold uppercase", STATUS_STYLE[e.status])}>{STATUS_LABEL[e.status]}</span> },
    { key: "pay", header: "Payment", render: (e) => (e.paymentStatus ? <span className="text-[11px] text-slate-600">{PAYMENT_LABEL[e.paymentStatus]}{e.paymentStatus === "partial" ? ` (${money(Math.round(e.outstandingAmount * 100))} left)` : ""}</span> : <span className="text-slate-300">—</span>) },
    { key: "by", header: "Submitted by", render: (e) => e.submittedByName },
    { key: "act", header: "", render: (e) => {
      const a = actionsFor(e, me);
      return (
        <span className="flex flex-wrap justify-end gap-1">
          {a.approve && <button type="button" data-testid="row-approve" onClick={() => openAction(e, "approve")} className="rounded-md bg-green-600 px-2 py-1 text-[10px] font-bold uppercase text-white hover:bg-green-700">Approve</button>}
          {a.reject && <button type="button" data-testid="row-reject" onClick={() => openAction(e, "reject")} className="rounded-md border border-slate-200 px-2 py-1 text-[10px] font-bold uppercase text-red-700 hover:bg-red-50">Reject</button>}
          {a.pay && <button type="button" data-testid="row-pay" onClick={() => openAction(e, "pay")} className="rounded-md border border-slate-200 px-2 py-1 text-[10px] font-bold uppercase text-slate-700 hover:bg-blue-50">Pay</button>}
          {a.edit && <button type="button" onClick={() => openAction(e, "edit")} className="rounded-md border border-slate-200 px-2 py-1 text-[10px] font-bold uppercase text-slate-700 hover:bg-slate-50">{e.status === "rejected" ? "Resubmit" : "Edit"}</button>}
        </span>
      );
    } },
  ];

  if (status === "loading") {
    return (
      <div>
        <h1 className="text-2xl font-bold tracking-tight text-slate-900 sm:text-3xl">Expenses</h1>
        <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400"><Loader2 className="h-6 w-6 animate-spin text-brand-blue" /><p className="text-xs font-medium">Loading expenses…</p></div>
      </div>
    );
  }
  if (status === "denied") {
    return (
      <div className="flex min-h-[60vh] flex-col items-center justify-center space-y-4" data-testid="expenses-denied">
        <Shield className="h-16 w-16 text-slate-300" />
        <h2 className="text-xl font-bold text-slate-700">Access Denied</h2>
        <p className="text-slate-500">You do not have permission to use Expenses.</p>
      </div>
    );
  }
  if (status === "error" || !data) {
    return (
      <div className="flex flex-col items-center gap-3 rounded-xl border border-slate-200 bg-white py-16 text-center" data-testid="expenses-error">
        <AlertCircle className="h-8 w-8 text-red-500" />
        <h2 className="text-lg font-bold text-slate-900">Could not load expenses</h2>
        <p className="max-w-md text-xs text-slate-500">{loadError ?? "Unknown error."}</p>
      </div>
    );
  }

  const scopeText = seesAll ? "All expenses" : "Your expenses";
  const approved = data.expenses.filter((e) => e.status === "approved");

  return (
    <div className="space-y-6 pb-12" data-testid="expenses-page">
      <header className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-slate-900 sm:text-3xl">Expenses</h1>
          <p className="mt-1 text-xs text-slate-500">{scopeText}. Approval makes an expense a cost; payment is recorded separately. Nobody approves their own expense. Data as of {formatEfzTime(data.loadedAt)}.</p>
        </div>
        <div className="flex gap-2">
          <button type="button" onClick={refresh} disabled={refreshing} className="inline-flex h-9 items-center gap-1.5 rounded-xl border border-slate-200 bg-white px-3 text-xs font-semibold text-slate-700 shadow-sm hover:bg-slate-50 disabled:opacity-50">
            <RefreshCw className={cn("h-3.5 w-3.5", refreshing && "animate-spin")} /> Refresh
          </button>
          {perms.submitExpenses && (
            <Button type="button" className="h-9 rounded-xl bg-slate-900 px-3 text-xs text-white" data-testid="new-expense" onClick={() => setModal({ type: "form", expense: null })}><Plus className="mr-1 h-3.5 w-3.5" /> New expense</Button>
          )}
        </div>
      </header>

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4" data-testid="expense-summary">
        <Kpi testId="kpi-pending" label="Pending approval" value={money(summary.pendingCents)} sub={`${summary.pendingCount} expense${summary.pendingCount === 1 ? "" : "s"}`} />
        <Kpi testId="kpi-approved" label="Approved" value={money(summary.approvedCents)} sub={`${summary.approvedCount} expense${summary.approvedCount === 1 ? "" : "s"}`} />
        <Kpi testId="kpi-paid" label="Paid" value={money(summary.paidCents)} sub="Cash recorded against approved expenses" />
        <Kpi testId="kpi-outstanding" label="Approved, not yet paid" value={money(summary.outstandingCents)} sub={`${summary.rejectedCount} rejected · ${summary.voidCount} void`} />
      </div>

      <SectionCard title="Expense register" subtitle={`${rows.length} of ${data.expenses.length} shown`}
        actions={
          <div className="flex flex-wrap items-center gap-2 text-xs">
            <select aria-label="Status" className="h-8 rounded-lg border border-slate-200 bg-white px-2" value={filter.status} onChange={(e) => setFilter({ ...filter, status: e.target.value as ExpenseFilter["status"] })}>
              <option value="all">All statuses</option>{(Object.keys(STATUS_LABEL) as Expense["status"][]).map((s) => <option key={s} value={s}>{STATUS_LABEL[s]}</option>)}
            </select>
            <select aria-label="Type" className="h-8 rounded-lg border border-slate-200 bg-white px-2" value={filter.kind} onChange={(e) => setFilter({ ...filter, kind: e.target.value as ExpenseFilter["kind"] })}>
              <option value="all">All types</option><option value="direct_order">Direct order</option><option value="operating">Operating</option>
            </select>
            <select aria-label="Category" className="h-8 rounded-lg border border-slate-200 bg-white px-2" value={filter.categoryId} onChange={(e) => setFilter({ ...filter, categoryId: e.target.value })}>
              <option value="all">All categories</option>{data.categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
            <Input aria-label="From" type="date" className="h-8 w-36 rounded-lg text-xs" value={filter.from} onChange={(e) => setFilter({ ...filter, from: e.target.value })} />
            <Input aria-label="To" type="date" className="h-8 w-36 rounded-lg text-xs" value={filter.to} onChange={(e) => setFilter({ ...filter, to: e.target.value })} />
            <Input aria-label="Search" placeholder="Search…" className="h-8 w-36 rounded-lg text-xs" value={filter.search} onChange={(e) => setFilter({ ...filter, search: e.target.value })} />
            {seesAll && perms.submitExpenses && (
              <label className="flex items-center gap-1 text-slate-600"><input type="checkbox" checked={filter.mineOnly} onChange={(e) => setFilter({ ...filter, mineOnly: e.target.checked })} /> Mine only</label>
            )}
          </div>
        }>
        <DataTable testId="expense-table" rows={rows} rowKey={(e) => e.id} columns={columns} maxRows={50} empty="No expenses match." />
      </SectionCard>

      {seesAll && <ApprovedExpensesSection costs={approved} categories={data.categories} range={{ from: `${efzToday().slice(0, 7)}-01`, to: efzToday() }} today={efzToday()} />}

      {modal.type === "form" && (
        <ExpenseFormDialog expense={modal.expense} categories={data.categories} orders={data.orders} onClose={() => setModal({ type: "none" })} onSaved={done} />
      )}
      {detail && modal.type === "detail" && (
        <ExpenseDetailDialog expense={detail} me={me} categories={data.categories} onClose={() => setModal({ type: "none" })} onAction={(action, payment) => openAction(detail, action, payment)} />
      )}
      {modal.type === "pay" && <PaymentDialog expense={modal.expense} onClose={() => setModal({ type: "none" })} onDone={() => done(`Payment recorded on ${modal.expense.reference}.`)} />}
      {modal.type === "approve" && (
        <div className="fixed inset-0 z-[120] flex items-center justify-center bg-slate-900/60 p-4" role="dialog" aria-label="Approve expense" data-testid="expense-approve-dialog">
          <div className="w-full max-w-md rounded-2xl bg-white p-6 shadow-2xl">
            <h3 className="text-xl font-bold text-slate-900">Approve {modal.expense.reference}?</h3>
            <p className="mt-2 text-sm text-slate-600">{money(Math.round(modal.expense.amount * 100))} · {categoryName(modal.expense.categoryId)} · {modal.expense.description}. Once approved it counts as a cost and cannot be edited; to correct it you void it and submit a new one.</p>
            <div className="mt-5 flex gap-3">
              <Button type="button" variant="outline" className="h-11 flex-1 rounded-xl" onClick={() => setModal({ type: "none" })}>Cancel</Button>
              <Button type="button" disabled={busy} className="h-11 flex-1 rounded-xl bg-green-600 text-white hover:bg-green-700" data-testid="expense-approve-confirm" onClick={() => approve(modal.expense)}>
                {busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Approve
              </Button>
            </div>
          </div>
        </div>
      )}
      {modal.type === "reject" && (
        <ReasonDialog title={`Reject ${modal.expense.reference}`} subtitle="The submitter sees the reason and can resubmit" prompt="Reason for rejecting *" confirm="Reject" danger
          run={(r) => getDb().expenses.decide(modal.expense.id, "reject", r)} onClose={() => setModal({ type: "none" })} onDone={() => done(`${modal.expense.reference} rejected.`)} />
      )}
      {modal.type === "withdraw" && (
        <ReasonDialog title={`Withdraw ${modal.expense.reference}`} subtitle="It becomes void and no longer counts" prompt="Reason *" confirm="Withdraw" danger
          run={(r) => getDb().expenses.void(modal.expense.id, r)} onClose={() => setModal({ type: "none" })} onDone={() => done(`${modal.expense.reference} withdrawn.`)} />
      )}
      {modal.type === "voidApproved" && (
        <ReasonDialog title={`Void ${modal.expense.reference}`} subtitle="Removes an approved expense from the figures. It stays in the history" prompt="Reason for voiding *" confirm="Void expense" danger
          run={(r) => getDb().expenses.void(modal.expense.id, r)} onClose={() => setModal({ type: "none" })} onDone={() => done(`${modal.expense.reference} voided.`)} />
      )}
      {modal.type === "voidPayment" && (
        <ReasonDialog title={`Void payment of ${money(Math.round(modal.payment.amount * 100))}`} subtitle={modal.expense.reference} prompt="Reason for voiding the payment *" confirm="Void payment" danger
          run={(r) => getDb().expenses.voidPayment(modal.payment.id, r)} onClose={() => setModal({ type: "none" })} onDone={() => done("Payment voided.")} />
      )}

      {notice && (
        <div className="fixed bottom-6 right-6 z-[130] rounded-xl border border-slate-200 bg-white px-4 py-3 text-xs font-semibold shadow-lg" role="status" data-testid="expense-notice">
          <span className={notice.type === "error" ? "text-red-600" : "text-green-600"}>{notice.message}</span>
        </div>
      )}
    </div>
  );
}
