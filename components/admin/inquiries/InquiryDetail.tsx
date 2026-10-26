"use client";

/**
 * One inquiry from the public Contact or Wholesale form: what the visitor wrote, who it is assigned to, the moves its status allows
 * (INQUIRY_TRANSITIONS, enforced again by set_public_inquiry_status()), its timeline and staff notes. Each action needs its own capability
 * (view / work / assign); the database checks every one again.
 */
import { useCallback, useEffect, useState } from "react";
import { AlertCircle, CheckCircle2, Loader2, Mail, MessageCircle, Phone, RotateCcw, X, XCircle } from "lucide-react";

import { Button } from "@/components/ui/button";
import { InquiryNotes } from "@/components/admin/inquiries/InquiryNotes";
import { INQUIRY_KIND_CLASS, INQUIRY_KIND_LABEL, INQUIRY_STATUS_CLASS, INQUIRY_STATUS_LABEL } from "@/components/admin/inquiries/inquiryUi";
import { ageOf } from "@/components/admin/requests/requestUi";
import { derivePermissions } from "@/lib/permissions";
import { cn } from "@/lib/utils";
import { describeDbError, getDb } from "@/lib/supabase/db";
import {
  INQUIRY_TRANSITIONS,
  type AdminUser,
  type PublicInquiry,
  type PublicInquiryEvent,
  type PublicInquiryNote,
  type WebsiteRequestAssignee,
} from "@/lib/types";

type Props = {
  inquiry: PublicInquiry;
  profile: AdminUser;
  staff: AdminUser[];
  onClose: () => void;
  onChanged: () => Promise<void>;
};

const eventText = (e: PublicInquiryEvent): string => {
  switch (e.event) {
    case "submitted":
      return "Submitted on the website";
    case "status_changed":
      return `${INQUIRY_STATUS_LABEL[(e.fromStatus ?? "new") as keyof typeof INQUIRY_STATUS_LABEL] ?? e.fromStatus} → ${INQUIRY_STATUS_LABEL[(e.toStatus ?? "new") as keyof typeof INQUIRY_STATUS_LABEL] ?? e.toStatus}${e.note ? `: ${e.note}` : ""}`;
    case "note_added":
      return "Note added";
    case "note_edited":
      return "Note edited";
    case "assigned":
      return e.assignedToName ? `Assigned to ${e.assignedToName}` : "Unassigned";
  }
};

export function InquiryDetail({ inquiry, profile, staff, onClose, onChanged }: Props) {
  const perms = derivePermissions(profile);
  const [notes, setNotes] = useState<PublicInquiryNote[]>([]);
  const [events, setEvents] = useState<PublicInquiryEvent[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [closing, setClosing] = useState(false);
  const [reason, setReason] = useState("");
  const [assignees, setAssignees] = useState<WebsiteRequestAssignee[]>([]);
  // The picker shows the current assignee until the user picks someone else.
  const [assignDraft, setAssignDraft] = useState<string | null>(null);
  const assignTo = assignDraft ?? inquiry.assignedTo ?? "";

  const canAssign = perms.assignInquiries && inquiry.status !== "closed";
  useEffect(() => {
    if (!canAssign) return;
    let cancelled = false;
    getDb().inquiries.assignees()
      .then((list) => { if (!cancelled) setAssignees(list); })
      .catch((e) => { if (!cancelled) setError(describeDbError(e)); });
    return () => { cancelled = true; };
  }, [canAssign]);

  const loadActivity = useCallback(async () => {
    const activity = await getDb().inquiries.activity(inquiry.id);
    setNotes(activity.notes);
    setEvents(activity.events);
  }, [inquiry.id]);

  // Re-read when the inquiry itself changes (status, assignment).
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const activity = await getDb().inquiries.activity(inquiry.id);
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
  }, [inquiry.id, inquiry.status, inquiry.assignedTo]);

  const allowed = INQUIRY_TRANSITIONS[inquiry.status];
  const showContacted = perms.workInquiries && allowed.includes("contacted");
  const showClose = perms.workInquiries && allowed.includes("closed");
  const reopening = inquiry.status === "closed";
  const assigneeName = inquiry.assignedTo
    ? staff.find((s) => s.id === inquiry.assignedTo)?.name ?? assignees.find((a) => a.id === inquiry.assignedTo)?.name ?? inquiry.assignedTo
    : null;
  const digits = (inquiry.phoneCanonical ?? inquiry.phone).replace(/\D/g, "");

  const assign = async () => {
    setBusy(true);
    setError(null);
    try {
      await getDb().inquiries.assign(inquiry.id, assignTo || null);
      setAssignDraft(null);
      await onChanged();
      await loadActivity();
    } catch (e) {
      setError(describeDbError(e));
    } finally {
      setBusy(false);
    }
  };

  const move = async (to: "contacted" | "closed", why?: string) => {
    setBusy(true);
    setError(null);
    try {
      await getDb().inquiries.setStatus(inquiry.id, to, why);
      setClosing(false);
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
    <div className="fixed inset-0 z-50 flex justify-end bg-slate-900/30" onClick={onClose} role="dialog" aria-label={`Inquiry ${inquiry.reference}`}>
      <div className="h-full w-full max-w-xl overflow-y-auto bg-white shadow-2xl dark:bg-slate-900" onClick={(e) => e.stopPropagation()} data-testid="inquiry-detail">
        <div className="sticky top-0 z-10 flex items-center justify-between border-b border-slate-100 bg-white px-5 py-4 dark:bg-slate-900">
          <div>
            <p className="font-mono text-[10px] text-slate-400">{inquiry.reference}</p>
            <h2 className="text-base font-bold text-slate-900">{inquiry.name}</h2>
          </div>
          <div className="flex items-center gap-3">
            <span className={cn("inline-flex rounded px-1.5 py-0.5 text-[9px] font-bold uppercase", INQUIRY_KIND_CLASS[inquiry.kind])}>{INQUIRY_KIND_LABEL[inquiry.kind]}</span>
            <span className={cn("inline-flex rounded-full border px-2 py-0.5 text-[9px] font-bold uppercase", INQUIRY_STATUS_CLASS[inquiry.status])}>{INQUIRY_STATUS_LABEL[inquiry.status]}</span>
            <button type="button" onClick={onClose} aria-label="Close" className="rounded-lg p-1.5 text-slate-400 hover:bg-slate-100">
              <X className="h-4 w-4" />
            </button>
          </div>
        </div>

        <div className="space-y-6 p-5 text-xs">
          <section className="grid grid-cols-2 gap-3">
            {inquiry.phone && (
              <div>
                <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Phone</p>
                <p className="font-mono text-slate-900">{inquiry.phone}</p>
                <div className="mt-1 flex gap-2">
                  <a href={`tel:${inquiry.phoneCanonical ?? inquiry.phone}`} className="inline-flex items-center gap-1 text-brand-blue hover:underline"><Phone className="h-3 w-3" />Call</a>
                  {digits && (
                    <a href={`https://wa.me/${digits}`} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 text-emerald-600 hover:underline">
                      <MessageCircle className="h-3 w-3" />WhatsApp
                    </a>
                  )}
                </div>
              </div>
            )}
            {inquiry.email && (
              <div>
                <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Email</p>
                <p className="break-all text-slate-900">{inquiry.email}</p>
                <a href={`mailto:${inquiry.email}`} className="mt-1 inline-flex items-center gap-1 text-brand-blue hover:underline"><Mail className="h-3 w-3" />Write</a>
              </div>
            )}
            <div>
              <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Submitted</p>
              <p className="text-slate-900">{new Date(inquiry.createdAt).toLocaleString()}</p>
              <p className="text-slate-500">{ageOf(inquiry.createdAt).label} ago</p>
            </div>
            {inquiry.organization && (
              <div>
                <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Organization</p>
                <p className="text-slate-900">{inquiry.organization}</p>
              </div>
            )}
            {inquiry.businessType && (
              <div>
                <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Business type</p>
                <p className="text-slate-900">{inquiry.businessType}</p>
              </div>
            )}
          </section>

          <section>
            <p className="mb-1 text-[9px] font-bold uppercase tracking-widest text-slate-400">{inquiry.kind === "wholesale" ? "Products of interest" : "Message"}</p>
            {inquiry.subject && <p className="mb-1 font-bold text-slate-900">{inquiry.subject}</p>}
            <p className="whitespace-pre-wrap text-slate-900" data-testid="inquiry-message">{inquiry.message || "—"}</p>
          </section>

          {inquiry.status === "closed" && inquiry.closedReason && (
            <section className="rounded-lg border border-slate-200 bg-slate-50 p-3 text-slate-700">
              <p className="font-bold">Closed</p>
              <p>{inquiry.closedReason}</p>
            </section>
          )}

          {error && (
            <div className="flex items-start gap-2 rounded-lg border border-red-100 bg-red-50 p-3 text-red-700" role="alert">
              <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
              <p>{error}</p>
            </div>
          )}

          <section className="space-y-2" data-testid="inquiry-assignment">
            <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Assigned to</p>
            <p className="font-bold text-slate-900">{assigneeName ?? "Unassigned"}</p>
            {canAssign && (
              <div className="flex flex-wrap items-center gap-2">
                <label className="sr-only" htmlFor="inquiry-assignee">Assign to</label>
                <select
                  id="inquiry-assignee"
                  value={assignTo}
                  onChange={(e) => setAssignDraft(e.target.value)}
                  className="rounded-md border border-slate-200 p-1.5"
                >
                  <option value="">Unassigned</option>
                  {assignees.map((a) => (
                    <option key={a.id} value={a.id}>{a.name} ({a.role})</option>
                  ))}
                </select>
                <Button size="sm" variant="secondary" disabled={busy || assignTo === (inquiry.assignedTo ?? "")} onClick={assign}>
                  {inquiry.assignedTo ? "Reassign" : "Assign"}
                </Button>
              </div>
            )}
          </section>

          {(showContacted || showClose) && (
            <section className="space-y-3">
              <div className="flex flex-wrap gap-2">
                {showContacted && (
                  <Button size="sm" variant="secondary" disabled={busy} onClick={() => move("contacted")}>
                    {reopening ? <RotateCcw className="mr-1.5 h-3.5 w-3.5" /> : <CheckCircle2 className="mr-1.5 h-3.5 w-3.5" />}
                    {reopening ? "Reopen" : "Mark Contacted"}
                  </Button>
                )}
                {showClose && !closing && (
                  <Button size="sm" variant="ghost" disabled={busy} onClick={() => setClosing(true)}>
                    <XCircle className="mr-1.5 h-3.5 w-3.5" /> Close
                  </Button>
                )}
                {busy && <Loader2 className="h-4 w-4 animate-spin self-center text-brand-blue" />}
              </div>
              {closing && (
                <div className="space-y-2 rounded-lg border border-slate-200 p-3">
                  <label className="block text-[10px] font-bold uppercase tracking-widest text-slate-500" htmlFor="close-reason">Outcome (optional)</label>
                  <textarea
                    id="close-reason"
                    value={reason}
                    maxLength={500}
                    onChange={(e) => setReason(e.target.value)}
                    className="w-full rounded-md border border-slate-200 p-2"
                    placeholder="e.g. answered by phone, quote sent, spam"
                  />
                  <div className="flex gap-2">
                    <Button size="sm" disabled={busy} onClick={() => move("closed", reason.trim() || undefined)}>Close inquiry</Button>
                    <Button size="sm" variant="ghost" disabled={busy} onClick={() => setClosing(false)}>Cancel</Button>
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

          <InquiryNotes
            inquiryId={inquiry.id}
            notes={notes}
            profile={profile}
            staff={staff}
            canWrite={perms.workInquiries}
            onChanged={loadActivity}
          />
        </div>
      </div>
    </div>
  );
}
