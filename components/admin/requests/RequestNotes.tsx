"use client";

/**
 * Staff processing notes on a request. They belong to the request, never to the
 * order. Anyone who may work the request can add one, in any status; only the
 * author (while they still have access) or the Super Admin can edit it
 * (edit_order_request_note() enforces this; the previous text stays in the
 * timeline). Notes cannot be deleted.
 */
import { useState } from "react";
import { Loader2, Pencil } from "lucide-react";

import { Button } from "@/components/ui/button";
import { describeDbError, getDb } from "@/lib/supabase/db";
import type { AdminUser, WebsiteRequestNote } from "@/lib/types";

type Props = {
  requestId: string;
  notes: WebsiteRequestNote[];
  profile: AdminUser;
  staff: AdminUser[];
  canWrite: boolean;
  onChanged: () => Promise<void>;
};

export function RequestNotes({ requestId, notes, profile, staff, canWrite, onChanged }: Props) {
  const [draft, setDraft] = useState("");
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editText, setEditText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const isSuperAdmin = profile.role === "Super Admin" && profile.status === "active";
  const nameOf = (id: string | null) => (id ? staff.find((s) => s.id === id)?.name ?? "" : "");

  const run = async (action: () => Promise<unknown>) => {
    setBusy(true);
    setError(null);
    try {
      await action();
      await onChanged();
      return true;
    } catch (e) {
      setError(describeDbError(e));
      return false;
    } finally {
      setBusy(false);
    }
  };

  const add = async () => {
    if (await run(() => getDb().orderRequests.addNote(requestId, draft.trim()))) setDraft("");
  };

  const save = async (noteId: string) => {
    if (await run(() => getDb().orderRequests.editNote(noteId, editText.trim()))) setEditingId(null);
  };

  return (
    <section>
      <p className="mb-2 text-[9px] font-bold uppercase tracking-widest text-slate-400">Request notes</p>
      <div className="space-y-2">
        {notes.length === 0 && <p className="text-slate-400">No notes yet.</p>}
        {notes.map((n) => {
          const mayEdit = canWrite && (isSuperAdmin || n.authorId === profile.id);
          return (
            <div key={n.id} className="rounded-lg border border-slate-100 bg-slate-50/50 p-3">
              {editingId === n.id ? (
                <div className="space-y-2">
                  <textarea value={editText} maxLength={2000} onChange={(e) => setEditText(e.target.value)} className="w-full rounded-md border border-slate-200 p-2" aria-label="Edit note" />
                  <div className="flex gap-2">
                    <Button size="sm" disabled={busy || !editText.trim()} onClick={() => save(n.id)}>Save</Button>
                    <Button size="sm" variant="ghost" disabled={busy} onClick={() => setEditingId(null)}>Cancel</Button>
                  </div>
                </div>
              ) : (
                <>
                  <p className="whitespace-pre-wrap text-slate-900">{n.body}</p>
                  <div className="mt-1 flex items-center justify-between text-[10px] text-slate-400">
                    <span>
                      {n.authorName || "—"} · {new Date(n.createdAt).toLocaleString()}
                      {n.editedBy && ` · edited${nameOf(n.editedBy) ? ` by ${nameOf(n.editedBy)}` : ""}`}
                    </span>
                    {mayEdit && (
                      <button type="button" onClick={() => { setEditingId(n.id); setEditText(n.body); }} className="inline-flex items-center gap-1 text-brand-blue hover:underline">
                        <Pencil className="h-3 w-3" /> Edit
                      </button>
                    )}
                  </div>
                </>
              )}
            </div>
          );
        })}
      </div>

      {canWrite && (
        <div className="mt-3 space-y-2">
          <textarea
            value={draft}
            maxLength={2000}
            onChange={(e) => setDraft(e.target.value)}
            placeholder="Add a note for the team (not shown on the order)"
            className="w-full rounded-md border border-slate-200 p-2"
            aria-label="New note"
          />
          <div className="flex items-center gap-2">
            <Button size="sm" variant="secondary" disabled={busy || !draft.trim()} onClick={add}>Add note</Button>
            {busy && <Loader2 className="h-4 w-4 animate-spin text-brand-blue" />}
          </div>
        </div>
      )}
      {error && <p className="mt-2 text-red-600">{error}</p>}
    </section>
  );
}
