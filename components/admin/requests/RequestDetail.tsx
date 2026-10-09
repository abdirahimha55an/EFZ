"use client";

/**
 * One website request: what was asked, its timeline and notes, and the moves its
 * status allows (WEBSITE_REQUEST_TRANSITIONS, enforced again by
 * set_order_request_status()). Convert to Order is offered only when confirmed.
 */
import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { AlertCircle, ArrowRightCircle, CheckCircle2, Loader2, MessageCircle, Phone, X, XCircle } from "lucide-react";

import { Button } from "@/components/ui/button";
import { ConvertRequestDialog } from "@/components/admin/requests/ConvertRequestDialog";
import { RequestNotes } from "@/components/admin/requests/RequestNotes";
import { STATUS_CLASS, STATUS_LABEL, ageOf } from "@/components/admin/requests/requestUi";
import { derivePermissions } from "@/lib/permissions";
import { cn } from "@/lib/utils";
import { describeDbError, getDb } from "@/lib/supabase/db";
import {
  WEBSITE_REQUEST_TRANSITIONS,
  type AdminUser,
  type WebsiteRequest,
  type WebsiteRequestEvent,
  type WebsiteRequestNote,
} from "@/lib/types";

type Props = {
  request: WebsiteRequest;
  profile: AdminUser;
  staff: AdminUser[];
  onClose: () => void;
  onChanged: () => Promise<void>;
};

const eventText = (e: WebsiteRequestEvent): string => {
  switch (e.event) {
    case "submitted":
      return e.source === "legacy_direct" ? "Submitted on the website (previous form)" : "Submitted on the website";
    case "status_changed":
      return `${STATUS_LABEL[(e.fromStatus ?? "new") as keyof typeof STATUS_LABEL] ?? e.fromStatus} → ${STATUS_LABEL[(e.toStatus ?? "new") as keyof typeof STATUS_LABEL] ?? e.toStatus}${e.note ? `: ${e.note}` : ""}`;
    case "converted":
      return `Converted to order ${e.orderId ?? ""}`;
    case "note_added":
      return "Note added";
    case "note_edited":
      return "Note edited";
  }
};

export function RequestDetail({ request, profile, staff, onClose, onChanged }: Props) {
  const perms = derivePermissions(profile);
  const [notes, setNotes] = useState<WebsiteRequestNote[]>([]);
  const [events, setEvents] = useState<WebsiteRequestEvent[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [rejecting, setRejecting] = useState(false);
  const [reason, setReason] = useState("");
  const [converting, setConverting] = useState(false);

  const loadActivity = useCallback(async () => {
    const activity = await getDb().orderRequests.activity(request.id);
    setNotes(activity.notes);
    setEvents(activity.events);
  }, [request.id]);

  // Re-read when the request itself changes (status, conversion).
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const activity = await getDb().orderRequests.activity(request.id);
        if (cancelled) return;
        setNotes(activity.notes);
        setEvents(activity.events);
      } catch (e) {
        if (!cancelled) setError(describeDbError(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [request.id, request.status, request.convertedOrderId]);

  const allowed = WEBSITE_REQUEST_TRANSITIONS[request.status];
  const canAct = perms.handleWebsiteRequests;
  const digits = request.phone.replace(/\D/g, "");

  const move = async (to: "contacted" | "confirmed" | "rejected", why?: string) => {
    setBusy(true);
    setError(null);
    try {
      await getDb().orderRequests.setStatus(request.id, to, why);
      setRejecting(false);
      setReason("");
      await onChanged();
      await loadActivity();
    } catch (e) {
      setError(describeDbError(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex justify-end bg-slate-900/30" onClick={onClose} role="dialog" aria-label={`Website request ${request.reference}`}>
      <div className="h-full w-full max-w-xl overflow-y-auto bg-white shadow-2xl dark:bg-slate-900" onClick={(e) => e.stopPropagation()} data-testid="request-detail">
        <div className="sticky top-0 z-10 flex items-center justify-between border-b border-slate-100 bg-white px-5 py-4 dark:bg-slate-900">
          <div>
            <p className="font-mono text-[10px] text-slate-400">{request.reference}</p>
            <h2 className="text-base font-bold text-slate-900">{request.customerName}</h2>
          </div>
          <div className="flex items-center gap-3">
            <span className={cn("inline-flex rounded-full border px-2 py-0.5 text-[9px] font-bold uppercase", STATUS_CLASS[request.status])}>{STATUS_LABEL[request.status]}</span>
            <button type="button" onClick={onClose} aria-label="Close" className="rounded-lg p-1.5 text-slate-400 hover:bg-slate-100">
              <X className="h-4 w-4" />
            </button>
          </div>
        </div>

        <div className="space-y-6 p-5 text-xs">
          <section className="grid grid-cols-2 gap-3">
            <div>
              <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Phone</p>
              <p className="font-mono text-slate-900">{request.phone}</p>
              <div className="mt-1 flex gap-2">
                <a href={`tel:${request.phoneCanonical ?? request.phone}`} className="inline-flex items-center gap-1 text-brand-blue hover:underline"><Phone className="h-3 w-3" />Call</a>
                {digits && (
                  <a href={`https://wa.me/${(request.phoneCanonical ?? digits).replace(/\D/g, "")}`} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 text-emerald-600 hover:underline">
                    <MessageCircle className="h-3 w-3" />WhatsApp
                  </a>
                )}
              </div>
            </div>
            <div>
              <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Submitted</p>
              <p className="text-slate-900">{new Date(request.createdAt).toLocaleString()}</p>
              <p className="text-slate-500">{ageOf(request.createdAt).label} ago</p>
            </div>
            {request.organization && (
              <div>
                <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Arena / Company</p>
                <p className="text-slate-900">{request.organization}</p>
              </div>
            )}
            <div>
              <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Delivery location</p>
              <p className="text-slate-900">{request.deliveryLocation || "—"}</p>
            </div>
            {request.visitorNotes && (
              <div className="col-span-2">
                <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Customer&apos;s notes</p>
                <p className="whitespace-pre-wrap text-slate-900">{request.visitorNotes}</p>
              </div>
            )}
          </section>

          <section>
            <p className="mb-2 text-[9px] font-bold uppercase tracking-widest text-slate-400">Requested products</p>
            <table className="w-full text-left">
              <tbody className="divide-y divide-slate-100">
                {request.lines.map((l) => (
                  <tr key={l.lineNo}>
                    <td className="py-2 font-bold text-slate-900">
                      {l.productName || "—"}
                      {!l.productId && <span className="ml-1 text-[10px] font-normal text-red-600">(product no longer exists)</span>}
                      {l.legacy && <span className="ml-1 rounded bg-slate-100 px-1 text-[9px] font-bold uppercase text-slate-500">legacy</span>}
                    </td>
                    <td className="py-2 text-right font-mono">× {l.quantity}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <p className="mt-1 text-[10px] text-slate-400">No stock is reserved and no price is set until the request is converted into an order.</p>
          </section>

          {request.status === "rejected" && request.rejectedReason && (
            <section className="rounded-lg border border-red-100 bg-red-50 p-3 text-red-700">
              <p className="font-bold">Rejected</p>
              <p>{request.rejectedReason}</p>
            </section>
          )}
          {request.status === "converted" && request.convertedOrderId && (
            <section className="rounded-lg border border-emerald-100 bg-emerald-50 p-3 text-emerald-800">
              <p className="font-bold">Converted to order <span className="font-mono">{request.convertedOrderId}</span></p>
              <Link href="/admin/orders" className="text-emerald-700 underline">Open Order Tracking</Link>
            </section>
          )}

          {error && (
            <div className="flex items-start gap-2 rounded-lg border border-red-100 bg-red-50 p-3 text-red-700">
              <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
              <p>{error}</p>
            </div>
          )}

          {canAct && (allowed.length > 0 || request.status === "confirmed") && (
            <section className="space-y-3">
              <div className="flex flex-wrap gap-2">
                {allowed.includes("contacted") && (
                  <Button size="sm" variant="secondary" disabled={busy} onClick={() => move("contacted")}>
                    <Phone className="mr-1.5 h-3.5 w-3.5" /> Mark Contacted
                  </Button>
                )}
                {allowed.includes("confirmed") && (
                  <Button size="sm" variant="secondary" disabled={busy} onClick={() => move("confirmed")}>
                    <CheckCircle2 className="mr-1.5 h-3.5 w-3.5" /> Mark Confirmed
                  </Button>
                )}
                {request.status === "confirmed" && perms.createOrders && (
                  <Button size="sm" disabled={busy} onClick={() => setConverting(true)}>
                    <ArrowRightCircle className="mr-1.5 h-3.5 w-3.5" /> Convert to Order
                  </Button>
                )}
                {allowed.includes("rejected") && !rejecting && (
                  <Button size="sm" variant="ghost" disabled={busy} onClick={() => setRejecting(true)} className="text-red-600">
                    <XCircle className="mr-1.5 h-3.5 w-3.5" /> Reject
                  </Button>
                )}
                {busy && <Loader2 className="h-4 w-4 animate-spin self-center text-brand-blue" />}
              </div>
              {rejecting && (
                <div className="space-y-2 rounded-lg border border-red-100 p-3">
                  <label className="block text-[10px] font-bold uppercase tracking-widest text-slate-500" htmlFor="reject-reason">Reason (required)</label>
                  <textarea
                    id="reject-reason"
                    value={reason}
                    maxLength={500}
                    onChange={(e) => setReason(e.target.value)}
                    className="w-full rounded-md border border-slate-200 p-2"
                    placeholder="e.g. duplicate request, customer cancelled, could not reach"
                  />
                  <div className="flex gap-2">
                    <Button size="sm" variant="danger" disabled={busy || !reason.trim()} onClick={() => move("rejected", reason.trim())}>Reject request</Button>
                    <Button size="sm" variant="ghost" disabled={busy} onClick={() => setRejecting(false)}>Cancel</Button>
                  </div>
                </div>
              )}
            </section>
          )}

          <section>
            <p className="mb-2 text-[9px] font-bold uppercase tracking-widest text-slate-400">Timeline</p>
            <ol className="space-y-2 border-l border-slate-200 pl-3">
              {events.map((e) => (
                <li key={e.seq}>
                  <p className="text-slate-900">{eventText(e)}</p>
                  <p className="text-[10px] text-slate-400">
                    {new Date(e.occurredAt).toLocaleString()}
                    {e.actorName ? ` · ${e.actorName}` : ""}
                  </p>
                </li>
              ))}
              {events.length === 0 && <li className="text-slate-400">No history recorded.</li>}
            </ol>
          </section>

          <RequestNotes
            requestId={request.id}
            notes={notes}
            profile={profile}
            staff={staff}
            canWrite={canAct}
            onChanged={loadActivity}
          />
        </div>
      </div>

      {converting && (
        <ConvertRequestDialog
          request={request}
          profile={profile}
          staff={staff}
          onClose={() => setConverting(false)}
          onConverted={async () => {
            setConverting(false);
            await onChanged();
            await loadActivity();
          }}
        />
      )}
    </div>
  );
}
