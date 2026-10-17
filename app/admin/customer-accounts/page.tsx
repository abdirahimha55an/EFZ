"use client";

/**
 * Customer app accounts: review, approve, reject, suspend, reinstate (migration 21).
 *
 * Access: staff holding manage_customer_accounts (Super Admin always). This page only HIDES itself from
 * anyone else; the protection is the database - the account tables return no rows and every review
 * function refuses without the permission, whatever this page does.
 *
 * Every rule (legal transitions, the verification needed to link an existing CRM customer, the notes) is
 * enforced by the audited database functions; the client calls them and shows their answer. Approving never
 * assigns a commission owner. Shown to the reviewer: the registration details the customer typed and the
 * MASKED phone of possible CRM matches. Never loaded: the client address hash, auth ids, any order data.
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import { AlertCircle, CheckCircle2, Loader2, Search, Shield, UserCheck, X } from "lucide-react";
import type { AdminProfile, CustomerAccount, CustomerAccountEvent, CustomerAccountMatch } from "@/lib/types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";
import {
  ACTION_LABEL, ACTION_RESULT, FILTERS, MIN_VERIFY_NOTE, STATUS_LABEL, allowedActions, approvalProblem, countByStatus,
  filterAccounts, reasonProblem, type AccountAction, type AccountFilter, type ApprovalDraft,
} from "@/lib/customerAccounts";

const BADGE: Record<string, string> = {
  pending: "bg-amber-50 text-amber-800 border-amber-200", approved: "bg-emerald-50 text-emerald-800 border-emerald-200",
  rejected: "bg-slate-100 text-slate-600 border-slate-200", suspended: "bg-rose-50 text-rose-800 border-rose-200",
};
const when = (iso: string | null) => (iso ? iso.replace("T", " ").slice(0, 16) + " UTC" : "—");

type Loaded = { state: "ready"; list: CustomerAccount[] } | { state: "denied" } | { state: "error"; message: string };

export default function CustomerAccountsPage() {
  const [state, setState] = useState<"loading" | "ready" | "denied" | "error">("loading");
  const [message, setMessage] = useState<string | null>(null);
  const [list, setList] = useState<CustomerAccount[]>([]);
  const [filter, setFilter] = useState<AccountFilter>("pending");
  const [query, setQuery] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [matches, setMatches] = useState<CustomerAccountMatch[] | null>(null);
  const [matchError, setMatchError] = useState<string | null>(null);
  const [history, setHistory] = useState<CustomerAccountEvent[]>([]);
  const [draft, setDraft] = useState<ApprovalDraft>({ mode: null, linkCustomerId: null, verified: false, note: "" });
  const [reason, setReason] = useState("");
  const [confirming, setConfirming] = useState<AccountAction | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  const fetchList = useCallback(async (): Promise<Loaded> => {
    try {
      const db = getDb();
      const me: AdminProfile | null = await db.auth.getProfile();
      if (!derivePermissions(me).manageCustomerAccounts) return { state: "denied" };
      return { state: "ready", list: await db.customerAccounts.list() };
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

  const selected = list.find((a) => a.id === selectedId) ?? null;
  const counts = useMemo(() => countByStatus(list), [list]);
  const shown = useMemo(() => filterAccounts(list, filter, query), [list, filter, query]);

  // Candidates (pending only) and history load when an account is selected. State is reset in the handler, not in an effect.
  const select = async (a: CustomerAccount) => {
    setSelectedId(a.id); setMatches(null); setMatchError(null); setHistory([]); setConfirming(null); setActionError(null); setReason("");
    setDraft({ mode: null, linkCustomerId: null, verified: false, note: "" });
    const db = getDb();
    db.customerAccounts.history(a.id).then(setHistory).catch(() => setHistory([]));
    if (a.status === "pending") {
      try { setMatches(await db.customerAccounts.candidates(a.id)); } catch (error) { setMatchError(describeDbError(error)); setMatches([]); }
    }
  };

  const run = async (action: AccountAction) => {
    if (!selected || busy) return;
    setBusy(true); setActionError(null);
    try {
      const db = getDb().customerAccounts;
      if (action === "approve") await db.approve({ accountId: selected.id, linkCustomerId: draft.mode === "link" ? draft.linkCustomerId : null, verified: draft.verified, note: draft.note.trim() });
      else if (action === "reject") await db.reject(selected.id, reason.trim());
      else if (action === "suspend") await db.suspend(selected.id, reason.trim());
      else await db.reinstate(selected.id, reason.trim());
      setDone(`${selected.fullName} ${ACTION_RESULT[action]}. The change and its audit entry were recorded by the database.`);
      setConfirming(null);
      const r = await fetchList(); apply(r);
      const fresh = r.state === "ready" ? r.list.find((a) => a.id === selected.id) : undefined;
      if (fresh) { setSelectedId(null); await select(fresh); } else setSelectedId(null);
    } catch (error) {
      setActionError(`${selected.fullName}: ${describeDbError(error)}`);
      setConfirming(null);
      const r = await fetchList(); apply(r);   // the account may have changed under us (another reviewer)
    } finally {
      setBusy(false);
    }
  };

  if (state === "loading") return <div className="flex items-center justify-center gap-2 py-32 text-xs text-slate-400"><Loader2 className="h-5 w-5 animate-spin" /> Loading…</div>;
  if (state === "denied") return (
    <div className="flex min-h-[50vh] flex-col items-center justify-center gap-3" data-testid="accounts-denied">
      <Shield className="h-12 w-12 text-slate-300" /><p className="text-sm text-slate-500">You do not have permission to review customer app accounts.</p>
    </div>
  );
  if (state === "error") return (
    <div className="mx-auto flex max-w-md flex-col items-center gap-2 rounded-xl border border-slate-200 bg-white py-12 text-center" data-testid="accounts-error">
      <AlertCircle className="h-7 w-7 text-amber-500" /><p className="text-sm font-semibold text-slate-800">Could not load customer accounts</p><p className="px-4 text-xs text-slate-500">{message}</p>
    </div>
  );

  const actions = selected ? allowedActions(selected.status) : [];
  const approvalIssue = selected?.status === "pending" ? approvalProblem(draft, matches ?? []) : null;
  const reasonIssue = reasonProblem(reason);
  const needsReason = confirming === "reject" || confirming === "suspend" || confirming === "reinstate";

  return (
    <div className="space-y-5" data-testid="customer-accounts-page">
      <div>
        <h1 className="flex items-center gap-2 text-xl font-bold text-slate-900"><UserCheck className="h-5 w-5" /> Customer app accounts</h1>
        <p className="mt-1 max-w-3xl text-xs text-slate-500">
          Customers register in the Android app and cannot see the private catalog or their orders until you approve them. Verify each person yourself
          (phone call, WhatsApp, in person) before approving. Linking an existing customer needs your explicit confirmation; a matching phone number alone is never enough.
          Approving does not assign a commission owner.
        </p>
      </div>

      {done && (
        <div className="flex items-start justify-between gap-3 rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-xs text-emerald-900" data-testid="accounts-success">
          <span><CheckCircle2 className="mr-1 inline h-4 w-4" /> {done}</span>
          <button type="button" onClick={() => setDone(null)} aria-label="Dismiss"><X className="h-4 w-4" /></button>
        </div>
      )}
      {actionError && (
        <div className="flex items-start justify-between gap-3 rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-xs text-rose-900" data-testid="accounts-action-error" role="alert">
          <span><AlertCircle className="mr-1 inline h-4 w-4" /> Not saved - {actionError}</span>
          <button type="button" onClick={() => setActionError(null)} aria-label="Dismiss"><X className="h-4 w-4" /></button>
        </div>
      )}

      <div className="flex flex-wrap items-center gap-2" data-testid="accounts-filters">
        {FILTERS.map((f) => (
          <button key={f} type="button" onClick={() => setFilter(f)} data-testid={`accounts-filter-${f}`}
            className={`rounded-full border px-3 py-1 text-[11px] font-semibold ${filter === f ? "border-slate-900 bg-slate-900 text-white" : "border-slate-200 bg-white text-slate-600 hover:bg-slate-50"}`}>
            {f === "all" ? `All (${list.length})` : `${STATUS_LABEL[f]} (${counts[f]})`}
          </button>
        ))}
        <label className="relative ml-auto"><Search className="absolute left-2 top-2 h-3.5 w-3.5 text-slate-400" />
          <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search name, phone, email" data-testid="accounts-search"
            className="h-8 w-56 rounded-lg border border-slate-200 pl-7 pr-2 text-xs focus:border-slate-400 focus:outline-none" />
        </label>
      </div>

      {list.length === 0 ? (
        <div className="rounded-xl border border-slate-200 bg-white py-16 text-center" data-testid="accounts-empty">
          <UserCheck className="mx-auto h-9 w-9 text-slate-300" />
          <p className="mt-2 text-sm font-semibold text-slate-800">No customer has registered yet.</p>
          <p className="text-xs text-slate-500">New registrations from the app will appear here for review.</p>
        </div>
      ) : (
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.3fr)]">
          <div className="overflow-hidden rounded-xl border border-slate-200 bg-white" data-testid="accounts-list">
            {shown.length === 0 ? (
              <p className="px-4 py-10 text-center text-xs text-slate-400" data-testid="accounts-filter-empty">No accounts match this filter.</p>
            ) : (
              <ul className="divide-y divide-slate-100">
                {shown.map((a) => (
                  <li key={a.id}>
                    <button type="button" onClick={() => void select(a)} data-testid="accounts-row" data-account={a.id} data-status={a.status}
                      className={`flex w-full items-center justify-between gap-3 px-4 py-3 text-left text-xs hover:bg-slate-50 ${selectedId === a.id ? "bg-slate-50" : ""}`}>
                      <span><span className="font-bold text-slate-900">{a.fullName}</span>{a.organization && <span className="text-slate-500"> · {a.organization}</span>}<br /><span className="text-slate-500">{a.phone} · requested {when(a.requestedAt)}</span></span>
                      <span className={`shrink-0 rounded-full border px-2 py-0.5 text-[10px] font-bold ${BADGE[a.status]}`}>{STATUS_LABEL[a.status]}</span>
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </div>

          <div data-testid="accounts-detail">
            {!selected ? (
              <div className="rounded-xl border border-dashed border-slate-200 bg-white px-6 py-16 text-center text-xs text-slate-400">Select an account to review it.</div>
            ) : (
              <div className="space-y-4 rounded-xl border border-slate-200 bg-white p-5">
                <div className="flex items-start justify-between gap-2">
                  <div>
                    <h2 className="text-sm font-bold text-slate-900">{selected.fullName}</h2>
                    <p className="text-[11px] text-slate-500">{selected.organization || "No organization given"}</p>
                  </div>
                  <span className={`rounded-full border px-2 py-0.5 text-[10px] font-bold ${BADGE[selected.status]}`} data-testid="accounts-status">{STATUS_LABEL[selected.status]}</span>
                </div>
                <dl className="grid grid-cols-2 gap-2 text-xs">
                  <div className="rounded-lg bg-slate-50 p-2"><dt className="text-slate-500">Email (as typed, not verified)</dt><dd className="break-all font-semibold" data-testid="accounts-email">{selected.email}</dd></div>
                  <div className="rounded-lg bg-slate-50 p-2"><dt className="text-slate-500">Phone (as typed)</dt><dd className="font-semibold">{selected.phone}</dd></div>
                  <div className="rounded-lg bg-slate-50 p-2"><dt className="text-slate-500">Requested</dt><dd className="font-semibold">{when(selected.requestedAt)}</dd></div>
                  <div className="rounded-lg bg-slate-50 p-2"><dt className="text-slate-500">Linked CRM customer</dt><dd className="font-semibold">{selected.customerId ?? "Not linked yet"}</dd></div>
                </dl>
                {selected.reviewedAt && <p className="text-[11px] text-slate-500">Last review by {selected.reviewedByName || "staff"} on {when(selected.reviewedAt)}: <span className="italic">{selected.reviewNote}</span></p>}

                {history.length > 0 && (
                  <div>
                    <p className="mb-1 text-[11px] font-bold uppercase tracking-wide text-slate-500">History</p>
                    <ul className="space-y-1 text-[11px] text-slate-600" data-testid="accounts-history">
                      {history.map((e) => <li key={e.id}>{when(e.at)} · <b>{e.event}</b>{e.actorName ? ` by ${e.actorName}` : " (customer)"}{e.note ? ` - ${e.note}` : ""}</li>)}
                    </ul>
                  </div>
                )}

                {selected.status === "pending" && (
                  <div className="space-y-3 rounded-xl border border-slate-200 p-3" data-testid="accounts-approve-panel">
                    <p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Possible matches in the customer database (same phone)</p>
                    {matches === null ? <p className="flex items-center gap-2 text-xs text-slate-400"><Loader2 className="h-4 w-4 animate-spin" /> Looking up…</p>
                      : matchError ? <p className="rounded-lg bg-rose-50 px-3 py-2 text-xs text-rose-800" data-testid="accounts-match-error">Could not look up matches: {matchError}</p>
                      : matches.length === 0 ? <p className="text-xs text-slate-500" data-testid="accounts-no-matches">No customer has this phone number.</p>
                      : (
                        <ul className="space-y-1" data-testid="accounts-matches">
                          {matches.map((m) => (
                            <li key={m.customerId}>
                              <label className={`flex gap-2 rounded-lg border px-3 py-2 text-xs ${m.linked || m.status !== "active" ? "opacity-50" : "cursor-pointer"} ${draft.mode === "link" && draft.linkCustomerId === m.customerId ? "border-slate-900 bg-slate-50" : "border-slate-200"}`}>
                                <input type="radio" name="match" disabled={m.linked || m.status !== "active"} checked={draft.mode === "link" && draft.linkCustomerId === m.customerId}
                                  onChange={() => setDraft({ ...draft, mode: "link", linkCustomerId: m.customerId })} data-testid="accounts-match-radio" data-customer={m.customerId} className="mt-0.5" />
                                <span><b>{m.name}</b> · {m.phoneMasked} · {m.orders} order{m.orders === 1 ? "" : "s"} · {m.status}{m.linked ? " · already linked to an app account" : ""}</span>
                              </label>
                            </li>
                          ))}
                        </ul>
                      )}
                    <label className={`flex cursor-pointer gap-2 rounded-lg border px-3 py-2 text-xs ${draft.mode === "create" ? "border-slate-900 bg-slate-50" : "border-slate-200"}`}>
                      <input type="radio" name="match" checked={draft.mode === "create"} onChange={() => setDraft({ ...draft, mode: "create", linkCustomerId: null })} data-testid="accounts-create-radio" className="mt-0.5" />
                      <span><b>Create a new customer</b> from these details. No commission owner is assigned.</span>
                    </label>
                    <label className="flex cursor-pointer items-start gap-2 text-xs text-slate-700">
                      <input type="checkbox" checked={draft.verified} onChange={(e) => setDraft({ ...draft, verified: e.target.checked })} data-testid="accounts-verified" className="mt-0.5" />
                      {draft.mode === "create" && (matches?.length ?? 0) > 0
                        ? "I confirm this is a different person from the customers listed above."
                        : "I verified this person myself (outside the app) and they are the customer I selected."}
                    </label>
                    <div>
                      <label htmlFor="verify-note" className="text-[11px] font-bold uppercase tracking-wide text-slate-500">How did you verify? (kept in the audit trail)</label>
                      <textarea id="verify-note" rows={2} value={draft.note} onChange={(e) => setDraft({ ...draft, note: e.target.value.slice(0, 500) })} data-testid="accounts-note"
                        placeholder="e.g. Called the number, confirmed the club name and delivery address."
                        className="mt-1 w-full rounded-lg border border-slate-200 px-3 py-2 text-xs focus:border-slate-400 focus:outline-none" />
                      <p className="text-[11px] text-slate-400">At least {MIN_VERIFY_NOTE} characters.</p>
                    </div>
                    {approvalIssue && <p className="text-[11px] text-amber-700" data-testid="accounts-approve-hint">{approvalIssue}</p>}
                  </div>
                )}

                {actions.length > 0 && (
                  <div className="flex flex-wrap gap-2" data-testid="accounts-actions">
                    {actions.map((a) => (
                      <button key={a} type="button" data-testid={`accounts-${a}`}
                        disabled={a === "approve" ? approvalIssue !== null : false}
                        onClick={() => { setReason(""); setConfirming(a); }}
                        className={`inline-flex h-9 items-center rounded-xl px-4 text-xs font-semibold disabled:cursor-not-allowed disabled:opacity-40 ${a === "approve" || a === "reinstate" ? "bg-slate-900 text-white hover:bg-slate-800" : "border border-rose-200 bg-white text-rose-700 hover:bg-rose-50"}`}>
                        {ACTION_LABEL[a]}…
                      </button>
                    ))}
                  </div>
                )}
                {selected.status === "rejected" && <p className="text-[11px] text-slate-500">A rejected account is final. The person can register again only with a different email.</p>}
              </div>
            )}
          </div>
        </div>
      )}

      {confirming && selected && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/50 p-4" role="dialog" aria-modal="true" data-testid="accounts-confirm">
          <div className="w-full max-w-md space-y-3 rounded-2xl bg-white p-5 shadow-xl">
            <h3 className="text-sm font-bold text-slate-900">{ACTION_LABEL[confirming]} {selected.fullName}?</h3>
            {confirming === "approve" ? (
              <>
                <p className="text-xs text-slate-600">{draft.mode === "link" ? `Links this app account to the existing customer ${matches?.find((m) => m.customerId === draft.linkCustomerId)?.name ?? ""}, who will then see that customer's orders in the app.` : "Creates a new customer and gives this account access to the private catalog."} No commission owner is assigned.</p>
                <p className="rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-600"><b>Verification note:</b> {draft.note.trim()}</p>
              </>
            ) : (
              <>
                <p className="text-xs text-slate-600">{confirming === "reject" ? "Rejecting is final." : confirming === "suspend" ? "The customer loses access to the catalog and their orders immediately." : "The customer regains access immediately."}</p>
                <label htmlFor="reason" className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Reason (kept in the audit trail)</label>
                <textarea id="reason" rows={2} value={reason} onChange={(e) => setReason(e.target.value.slice(0, 500))} data-testid="accounts-reason"
                  className="w-full rounded-lg border border-slate-200 px-3 py-2 text-xs focus:border-slate-400 focus:outline-none" />
                {reasonIssue && <p className="text-[11px] text-amber-700">{reasonIssue}</p>}
              </>
            )}
            <div className="flex justify-end gap-2">
              <button type="button" onClick={() => setConfirming(null)} disabled={busy} className="h-9 rounded-xl border border-slate-200 px-3 text-xs font-semibold text-slate-700 hover:bg-slate-50">Cancel</button>
              <button type="button" onClick={() => void run(confirming)} disabled={busy || (needsReason && reasonIssue !== null) || (confirming === "approve" && approvalIssue !== null)} data-testid="accounts-confirm-save"
                className="inline-flex h-9 items-center gap-1.5 rounded-xl bg-slate-900 px-4 text-xs font-semibold text-white hover:bg-slate-800 disabled:cursor-not-allowed disabled:opacity-40">
                {busy && <Loader2 className="h-3.5 w-3.5 animate-spin" />} {ACTION_LABEL[confirming]}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
