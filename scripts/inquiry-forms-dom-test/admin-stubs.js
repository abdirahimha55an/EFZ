// Stands in for @/lib/supabase/db and next/navigation during the admin DOM test. The test sets globalThis.__world before mounting.
import { useSyncExternalStore } from "react";

const w = () => globalThis.__world;

export const describeDbError = (e) => (e instanceof Error ? e.message : "Something went wrong.");

export const getDb = () => ({
  auth: { getProfile: async () => w().profile },
  users: { list: async () => w().staff },
  inquiries: {
    list: async () => w().inquiries.map((i) => ({ ...i })),
    activity: async () => ({ notes: w().notes, events: w().events }),
    assignees: async () => w().assignees,
    setStatus: async (id, to, reason) => { w().calls.push(["setStatus", id, to, reason ?? null]); const i = w().inquiries.find((x) => x.id === id); i.status = to; },
    assign: async (id, to) => { w().calls.push(["assign", id, to]); w().inquiries.find((x) => x.id === id).assignedTo = to; },
    addNote: async (id, body) => { w().calls.push(["addNote", id, body]); return "n1"; },
    editNote: async () => {},
  },
});

// useSearchParams follows the live URL like Next does: history.replaceState (which the inbox uses to open a row) re-renders its readers.
const listeners = new Set();
let patched = false;
const patch = () => {
  if (patched) return;
  patched = true;
  const h = globalThis.window.history;
  const original = h.replaceState.bind(h);
  h.replaceState = (...args) => { original(...args); listeners.forEach((l) => l()); };
};
const subscribe = (l) => { listeners.add(l); return () => listeners.delete(l); };
export const useSearchParams = () => {
  patch();
  const search = useSyncExternalStore(subscribe, () => globalThis.window.location.search, () => "");
  return new URLSearchParams(search);
};
export const useRouter = () => ({ replace() {}, push() {} });
