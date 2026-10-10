"use client";

/**
 * Website Requests - what visitors asked for on /order (migration 18).
 *
 * A request is a lead, not an order: nothing here touches stock, prices or
 * money. Staff granted the website-request capabilities (migration 19: view,
 * view all, work, assign, reject, convert - Super Admin has all) contact the
 * customer, confirm, and convert it into a normal order; the database does the
 * conversion in one transaction through create_order().
 *
 * The list is RLS-scoped (order_requests_select = can_access_order_request()):
 * view_website_requests plus view_all_website_requests or being the assignee,
 * so anyone else reads nothing even by calling the API directly. The layout's
 * alert loop signals new or changed requests (Realtime + 30 s poll); see RequestSignal.
 */
import { Suspense, useCallback, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { AlertCircle, Inbox, Loader2, Search } from "lucide-react";

import { Card, CardContent } from "@/components/ui/card";
import { RequestDetail } from "@/components/admin/requests/RequestDetail";
import { useRequestSignal } from "@/components/admin/requests/RequestSignal";
import { STATUS_CLASS, STATUS_LABEL, ageOf } from "@/components/admin/requests/requestUi";
import { cn } from "@/lib/utils";
import { describeDbError, getDb } from "@/lib/supabase/db";
import type { AdminUser, WebsiteRequest, WebsiteRequestStatus } from "@/lib/types";

type Tab = "open" | WebsiteRequestStatus | "all";
type Sort = "newest" | "oldest";

export default function WebsiteRequestsPage() {
  // useSearchParams() needs a Suspense boundary to keep the route prerenderable.
  return (
    <Suspense
      fallback={
        <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400">
          <Loader2 className="h-6 w-6 animate-spin text-brand-blue" />
        </div>
      }
    >
      <WebsiteRequestsInbox />
    </Suspense>
  );
}

function WebsiteRequestsInbox() {
  const searchParams = useSearchParams();
  const openId = searchParams.get("id");
  const { version, refresh } = useRequestSignal();

  const [profile, setProfile] = useState<AdminUser | null>(null);
  const [requests, setRequests] = useState<WebsiteRequest[]>([]);
  const [staff, setStaff] = useState<AdminUser[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("open");
  const [query, setQuery] = useState("");
  const [sort, setSort] = useState<Sort>("newest");
  const [now, setNow] = useState(() => Date.now());

  const load = useCallback(async () => {
    const db = getDb();
    const [me, rows] = await Promise.all([db.auth.getProfile(), db.orderRequests.list()]);
    setProfile(me);
    setRequests(rows);
    setNow(Date.now());
  }, []);

  // Staff names for "Handled by" and the owner picker; not essential.
  useEffect(() => {
    getDb().users.list().then(setStaff).catch(() => setStaff([]));
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        await load();
        if (!cancelled) setError(null);
      } catch (e) {
        if (!cancelled) setError(describeDbError(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [load, version]);

  const staffName = useCallback((id: string | null) => (id ? staff.find((s) => s.id === id)?.name ?? id : ""), [staff]);

  const counts = useMemo(() => {
    const c: Record<WebsiteRequestStatus, number> = { new: 0, contacted: 0, confirmed: 0, converted: 0, rejected: 0 };
    for (const r of requests) c[r.status] += 1;
    return c;
  }, [requests]);

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase();
    const qDigits = q.replace(/\D/g, "");
    return requests
      .filter((r) =>
        tab === "all" ? true : tab === "open" ? ["new", "contacted", "confirmed"].includes(r.status) : r.status === tab
      )
      .filter((r) => {
        if (!q) return true;
        return (
          r.customerName.toLowerCase().includes(q) ||
          r.reference.toLowerCase().includes(q) ||
          r.organization.toLowerCase().includes(q) ||
          r.lines.some((l) => l.productName.toLowerCase().includes(q)) ||
          (qDigits.length >= 3 && r.phone.replace(/\D/g, "").includes(qDigits))
        );
      })
      .sort((a, b) =>
        sort === "newest"
          ? b.createdAt.localeCompare(a.createdAt)
          : a.createdAt.localeCompare(b.createdAt)
      );
  }, [requests, tab, query, sort]);

  const selected = openId ? requests.find((r) => r.id === openId) ?? null : null;
  // Native history (Next.js keeps useSearchParams in sync with it). router.replace("/admin/requests") is a no-op after a
  // fresh "?id=" load: this page is prerendered, so the router's current URL is already "/admin/requests".
  const openRequest = (id: string | null) => window.history.replaceState(null, "", id ? `/admin/requests?id=${id}` : "/admin/requests");

  const afterChange = useCallback(async () => {
    await load();
    refresh();
  }, [load, refresh]);

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400">
        <Loader2 className="h-6 w-6 animate-spin text-brand-blue" />
        <p className="text-xs font-medium">Loading website requests…</p>
      </div>
    );
  }
  if (error) {
    return (
      <Card className="border-none shadow-sm">
        <CardContent className="flex flex-col items-center gap-3 py-16 text-center">
          <AlertCircle className="h-8 w-8 text-red-500" />
          <p className="text-xs text-slate-500">{error}</p>
        </CardContent>
      </Card>
    );
  }

  const counters: { id: WebsiteRequestStatus; hint: string }[] = [
    { id: "new", hint: "Waiting for a first contact" },
    { id: "contacted", hint: "Customer reached" },
    { id: "confirmed", hint: "Ready to convert" },
    { id: "converted", hint: "Turned into orders" },
    { id: "rejected", hint: "Closed" },
  ];

  return (
    <div className="space-y-6 animate-in fade-in duration-500">
      <div>
        <h1 className="font-heading text-2xl font-bold tracking-tight text-slate-900">Website Requests</h1>
        <p className="mt-0.5 text-xs text-slate-500">
          Requests submitted on the public order page. Contact the customer, confirm, then convert into an order. Requests never reserve stock or record money.
        </p>
      </div>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
        {counters.map((c) => (
          <button
            key={c.id}
            type="button"
            onClick={() => setTab(c.id)}
            className={cn("rounded-xl border bg-white p-4 text-left shadow-sm transition-colors hover:border-brand-blue", tab === c.id && "border-brand-blue ring-1 ring-brand-blue")}
            data-testid={`counter-${c.id}`}
          >
            <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">{STATUS_LABEL[c.id]}</p>
            <p className="mt-0.5 font-mono text-2xl font-bold text-slate-900">{counts[c.id]}</p>
            <p className="mt-1 text-[10px] text-slate-500">{c.hint}</p>
          </button>
        ))}
      </div>

      <Card className="border-none shadow-sm">
        <CardContent className="p-0">
          <div className="flex flex-col gap-3 border-b border-slate-100 p-4 md:flex-row md:items-center md:justify-between">
            <div className="flex flex-wrap gap-1 text-xs">
              {(["open", "new", "contacted", "confirmed", "converted", "rejected", "all"] as Tab[]).map((t) => (
                <button
                  key={t}
                  type="button"
                  onClick={() => setTab(t)}
                  className={cn("rounded-lg px-2.5 py-1 font-bold", tab === t ? "bg-brand-blue text-white" : "text-slate-500 hover:bg-slate-100")}
                >
                  {t === "open" ? "Open" : t === "all" ? "All" : STATUS_LABEL[t]}
                </button>
              ))}
            </div>
            <div className="flex gap-2 text-xs">
              <div className="relative flex-1 md:w-64">
                <Search className="absolute left-2 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-slate-400" />
                <input
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  placeholder="Name, phone, product, REQ-…"
                  aria-label="Search requests"
                  className="w-full rounded-md border border-slate-200 py-1.5 pl-7 pr-2"
                />
              </div>
              <select aria-label="Sort" value={sort} onChange={(e) => setSort(e.target.value as Sort)} className="rounded-md border border-slate-200 px-2 py-1">
                <option value="newest">Newest first</option>
                <option value="oldest">Oldest first</option>
              </select>
            </div>
          </div>

          <div className="overflow-x-auto">
            <table className="w-full text-left text-xs" data-testid="requests-table">
              <thead className="bg-slate-50 text-[9px] font-bold uppercase tracking-widest text-slate-400">
                <tr>
                  <th className="px-4 py-3">Submitted</th>
                  <th className="px-4 py-3">Age</th>
                  <th className="px-4 py-3">Customer</th>
                  <th className="px-4 py-3">Phone</th>
                  <th className="px-4 py-3">Products</th>
                  <th className="px-4 py-3 text-right">Qty</th>
                  <th className="px-4 py-3">Status</th>
                  <th className="px-4 py-3">Assigned to</th>
                  <th className="px-4 py-3">Handled by</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-50">
                {visible.length === 0 && (
                  <tr>
                    <td colSpan={9} className="px-4 py-12 text-center text-slate-400">
                      <Inbox className="mx-auto mb-2 h-6 w-6" />
                      No requests here.
                    </td>
                  </tr>
                )}
                {visible.map((r) => {
                  const age = ageOf(r.createdAt, now);
                  const open = ["new", "contacted", "confirmed"].includes(r.status);
                  return (
                    <tr
                      key={r.id}
                      onClick={() => openRequest(r.id)}
                      className={cn("cursor-pointer hover:bg-slate-50", r.id === openId && "bg-blue-50/50")}
                      data-testid="request-row"
                      data-status={r.status}
                    >
                      <td className="whitespace-nowrap px-4 py-3">
                        <p className="font-mono text-[10px] text-slate-400">{r.reference}</p>
                        {new Date(r.createdAt).toLocaleString()}
                      </td>
                      <td className={cn("whitespace-nowrap px-4 py-3 font-bold", open && age.hours >= 24 ? "text-red-600" : "text-slate-500")}>{age.label}</td>
                      <td className="px-4 py-3">
                        <p className="font-bold text-slate-900">{r.customerName}</p>
                        {r.organization && <p className="text-[10px] text-slate-500">{r.organization}</p>}
                      </td>
                      <td className="whitespace-nowrap px-4 py-3 font-mono">{r.phone}</td>
                      <td className="px-4 py-3">
                        {r.lines.map((l) => (
                          <p key={l.lineNo}>
                            {l.productName || "—"} <span className="text-slate-400">× {l.quantity}</span>
                            {l.legacy && <span className="ml-1 rounded bg-slate-100 px-1 text-[9px] font-bold uppercase text-slate-500">legacy</span>}
                          </p>
                        ))}
                      </td>
                      <td className="px-4 py-3 text-right font-mono">{r.lines.reduce((s, l) => s + l.quantity, 0)}</td>
                      <td className="px-4 py-3">
                        <span className={cn("inline-flex rounded-full border px-2 py-0.5 text-[9px] font-bold uppercase", STATUS_CLASS[r.status])}>{STATUS_LABEL[r.status]}</span>
                      </td>
                      <td className="px-4 py-3 text-slate-700" data-testid="request-assignee">{r.assignedTo ? staffName(r.assignedTo) : <span className="text-slate-400">Unassigned</span>}</td>
                      <td className="px-4 py-3 text-slate-500">{staffName(r.handledBy)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </CardContent>
      </Card>

      {selected && profile && (
        <RequestDetail
          key={selected.id}
          request={selected}
          profile={profile}
          staff={staff}
          onClose={() => openRequest(null)}
          onChanged={afterChange}
        />
      )}
      {openId && !selected && (
        <p className="text-center text-xs text-slate-400">That request is not available to you, or no longer exists.</p>
      )}
    </div>
  );
}
