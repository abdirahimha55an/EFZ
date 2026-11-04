"use client";

/**
 * Contact & Wholesale inquiries: what visitors wrote on the public /contact and /wholesale forms (migration 30).
 *
 * The list is RLS-scoped (public_inquiries_select), so anyone without view_inquiries reads nothing even by calling the API directly; without
 * view_all_inquiries a delegate sees only the inquiries assigned to them. The layout's alert loop signals new or changed inquiries
 * (Realtime + 30 s poll) through the same RequestSignal the request pages use.
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { AlertCircle, Inbox, Loader2, Search } from "lucide-react";

import { Card, CardContent } from "@/components/ui/card";
import { InquiryDetail } from "@/components/admin/inquiries/InquiryDetail";
import { INQUIRY_KIND_CLASS, INQUIRY_KIND_LABEL, INQUIRY_STATUS_CLASS, INQUIRY_STATUS_LABEL } from "@/components/admin/inquiries/inquiryUi";
import { useRequestSignal } from "@/components/admin/requests/RequestSignal";
import { ageOf } from "@/components/admin/requests/requestUi";
import { cn } from "@/lib/utils";
import { describeDbError, getDb } from "@/lib/supabase/db";
import type { AdminUser, InquiryKind, InquiryStatus, PublicInquiry } from "@/lib/types";

type Tab = "open" | InquiryStatus | "all";
type Sort = "newest" | "oldest";
type KindFilter = "all" | InquiryKind;

const TITLE = "Contact & Wholesale";
const BASE = "/admin/inquiries";

export function InquiriesInbox() {
  const searchParams = useSearchParams();
  const openId = searchParams.get("id");
  const { version, refresh } = useRequestSignal();

  const [profile, setProfile] = useState<AdminUser | null>(null);
  const [inquiries, setInquiries] = useState<PublicInquiry[]>([]);
  const [staff, setStaff] = useState<AdminUser[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("open");
  const [kind, setKind] = useState<KindFilter>("all");
  const [query, setQuery] = useState("");
  const [sort, setSort] = useState<Sort>("newest");
  const [now, setNow] = useState(() => Date.now());

  const load = useCallback(async () => {
    const db = getDb();
    const [me, rows] = await Promise.all([db.auth.getProfile(), db.inquiries.list()]);
    setProfile(me);
    setInquiries(rows);
    setNow(Date.now());
  }, []);

  // Staff names for "Assigned to" and "Handled by"; not essential.
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
    const c: Record<InquiryStatus, number> = { new: 0, contacted: 0, closed: 0 };
    for (const i of inquiries) c[i.status] += 1;
    return c;
  }, [inquiries]);

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase();
    const qDigits = q.replace(/\D/g, "");
    return inquiries
      .filter((i) => (tab === "all" ? true : tab === "open" ? i.status !== "closed" : i.status === tab))
      .filter((i) => kind === "all" || i.kind === kind)
      .filter((i) => {
        if (!q) return true;
        return (
          i.name.toLowerCase().includes(q) ||
          i.reference.toLowerCase().includes(q) ||
          i.organization.toLowerCase().includes(q) ||
          i.subject.toLowerCase().includes(q) ||
          i.message.toLowerCase().includes(q) ||
          i.email.toLowerCase().includes(q) ||
          (qDigits.length >= 3 && i.phone.replace(/\D/g, "").includes(qDigits))
        );
      })
      .sort((a, b) => (sort === "newest" ? b.createdAt.localeCompare(a.createdAt) : a.createdAt.localeCompare(b.createdAt)));
  }, [inquiries, tab, kind, query, sort]);

  const selected = openId ? inquiries.find((i) => i.id === openId) ?? null : null;
  // Native history (Next.js keeps useSearchParams in sync with it), as in the requests inbox.
  const openInquiry = (id: string | null) => window.history.replaceState(null, "", id ? `${BASE}?id=${id}` : BASE);

  const afterChange = useCallback(async () => {
    await load();
    refresh();
  }, [load, refresh]);

  if (loading) {
    return (
      <div>
        <h1 className="font-heading text-2xl font-bold tracking-tight text-slate-900" data-testid="inquiries-title">{TITLE}</h1>
        <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400">
          <Loader2 className="h-6 w-6 animate-spin text-brand-blue" />
          <p className="text-xs font-medium">Loading inquiries…</p>
        </div>
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

  const counters: { id: InquiryStatus; hint: string }[] = [
    { id: "new", hint: "Waiting for a first reply" },
    { id: "contacted", hint: "Visitor reached" },
    { id: "closed", hint: "Dealt with" },
  ];

  return (
    <div className="space-y-6 animate-in fade-in duration-500">
      <div>
        <h1 className="font-heading text-2xl font-bold tracking-tight text-slate-900" data-testid="inquiries-title">{TITLE}</h1>
        <p className="mt-0.5 text-xs text-slate-500">
          Messages and wholesale quote requests sent from the public Contact and Wholesale pages. Reply to the visitor, keep notes, and close the inquiry when it is dealt with. Nothing here is an order.
        </p>
      </div>

      <div className="grid grid-cols-3 gap-3">
        {counters.map((c) => (
          <button
            key={c.id}
            type="button"
            onClick={() => setTab(c.id)}
            className={cn("rounded-xl border bg-white p-4 text-left shadow-sm transition-colors hover:border-brand-blue", tab === c.id && "border-brand-blue ring-1 ring-brand-blue")}
            data-testid={`inquiry-counter-${c.id}`}
          >
            <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">{INQUIRY_STATUS_LABEL[c.id]}</p>
            <p className="mt-0.5 font-mono text-2xl font-bold text-slate-900">{counts[c.id]}</p>
            <p className="mt-1 text-[10px] text-slate-500">{c.hint}</p>
          </button>
        ))}
      </div>

      <Card className="border-none shadow-sm">
        <CardContent className="p-0">
          <div className="flex flex-col gap-3 border-b border-slate-100 p-4 md:flex-row md:items-center md:justify-between">
            <div className="flex flex-wrap gap-1 text-xs">
              {(["open", "new", "contacted", "closed", "all"] as Tab[]).map((t) => (
                <button
                  key={t}
                  type="button"
                  onClick={() => setTab(t)}
                  className={cn("rounded-lg px-2.5 py-1 font-bold", tab === t ? "bg-brand-blue text-white" : "text-slate-500 hover:bg-slate-100")}
                >
                  {t === "open" ? "Open" : t === "all" ? "All" : INQUIRY_STATUS_LABEL[t]}
                </button>
              ))}
            </div>
            <div className="flex flex-wrap gap-2 text-xs">
              <div className="relative flex-1 md:w-64">
                <Search className="absolute left-2 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-slate-400" />
                <input
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  placeholder="Name, phone, email, message, INQ-…"
                  aria-label="Search inquiries"
                  className="w-full rounded-md border border-slate-200 py-1.5 pl-7 pr-2"
                />
              </div>
              <select aria-label="Type" value={kind} onChange={(e) => setKind(e.target.value as KindFilter)} className="rounded-md border border-slate-200 px-2 py-1">
                <option value="all">All types</option>
                <option value="contact">Contact</option>
                <option value="wholesale">Wholesale</option>
              </select>
              <select aria-label="Sort" value={sort} onChange={(e) => setSort(e.target.value as Sort)} className="rounded-md border border-slate-200 px-2 py-1">
                <option value="newest">Newest first</option>
                <option value="oldest">Oldest first</option>
              </select>
            </div>
          </div>

          <div className="overflow-x-auto">
            <table className="w-full text-left text-xs" data-testid="inquiries-table">
              <thead className="bg-slate-50 text-[9px] font-bold uppercase tracking-widest text-slate-400">
                <tr>
                  <th className="px-4 py-3">Submitted</th>
                  <th className="px-4 py-3">Age</th>
                  <th className="px-4 py-3">Type</th>
                  <th className="px-4 py-3">From</th>
                  <th className="px-4 py-3">Contact</th>
                  <th className="px-4 py-3">About</th>
                  <th className="px-4 py-3">Status</th>
                  <th className="px-4 py-3">Assigned to</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-50">
                {visible.length === 0 && (
                  <tr>
                    <td colSpan={8} className="px-4 py-12 text-center text-slate-400">
                      <Inbox className="mx-auto mb-2 h-6 w-6" />
                      No inquiries here.
                    </td>
                  </tr>
                )}
                {visible.map((i) => {
                  const age = ageOf(i.createdAt, now);
                  const open = i.status !== "closed";
                  return (
                    <tr
                      key={i.id}
                      onClick={() => openInquiry(i.id)}
                      className={cn("cursor-pointer hover:bg-slate-50", i.id === openId && "bg-blue-50/50")}
                      data-testid="inquiry-row"
                      data-status={i.status}
                      data-kind={i.kind}
                    >
                      <td className="whitespace-nowrap px-4 py-3">
                        <p className="font-mono text-[10px] text-slate-400">{i.reference}</p>
                        {new Date(i.createdAt).toLocaleString()}
                      </td>
                      <td className={cn("whitespace-nowrap px-4 py-3 font-bold", open && age.hours >= 24 ? "text-red-600" : "text-slate-500")}>{age.label}</td>
                      <td className="px-4 py-3">
                        <span className={cn("inline-flex rounded px-1.5 py-0.5 text-[9px] font-bold uppercase", INQUIRY_KIND_CLASS[i.kind])}>{INQUIRY_KIND_LABEL[i.kind]}</span>
                      </td>
                      <td className="px-4 py-3">
                        <p className="font-bold text-slate-900">{i.name}</p>
                        {i.organization && <p className="text-[10px] text-slate-500">{i.organization}</p>}
                      </td>
                      <td className="px-4 py-3">
                        {i.phone && <p className="whitespace-nowrap font-mono">{i.phone}</p>}
                        {i.email && <p className="break-all text-slate-500">{i.email}</p>}
                      </td>
                      <td className="max-w-xs px-4 py-3">
                        <p className="truncate font-bold text-slate-900">{i.subject || i.businessType || "—"}</p>
                        {i.message && <p className="truncate text-slate-500">{i.message}</p>}
                      </td>
                      <td className="px-4 py-3">
                        <span className={cn("inline-flex rounded-full border px-2 py-0.5 text-[9px] font-bold uppercase", INQUIRY_STATUS_CLASS[i.status])}>{INQUIRY_STATUS_LABEL[i.status]}</span>
                      </td>
                      <td className="px-4 py-3 text-slate-700" data-testid="inquiry-assignee">{i.assignedTo ? staffName(i.assignedTo) : <span className="text-slate-400">Unassigned</span>}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </CardContent>
      </Card>

      {selected && profile && (
        <InquiryDetail
          key={selected.id}
          inquiry={selected}
          profile={profile}
          staff={staff}
          onClose={() => openInquiry(null)}
          onChanged={afterChange}
        />
      )}
      {openId && !selected && (
        <p className="text-center text-xs text-slate-400">That inquiry is not available to you, or no longer exists.</p>
      )}
    </div>
  );
}
