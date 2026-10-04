/**
 * Dismissed "Needs attention" notices, remembered per user in this browser.
 *
 * Dismissing only hides a notice from the user's active attention list: it
 * writes nothing to the database and changes no customer, order, stock or
 * commission. A notice is matched by its key (rule + the records it is about),
 * so a changed situation produces a new key and is shown again.
 */

import type { AttentionItem } from "./model";

const MAX_REMEMBERED = 200;

export const dismissStorageKey = (userId: string) => `efz.analytics.attention-dismissed.${userId}`;

/** Never throws: storage can be blocked (private mode, policy) - then nothing is hidden. */
export function loadDismissed(userId: string, storage: Pick<Storage, "getItem"> | null = safeStorage()): Set<string> {
  try {
    const raw = storage?.getItem(dismissStorageKey(userId));
    const list = raw ? JSON.parse(raw) : [];
    return new Set(Array.isArray(list) ? list.filter((k) => typeof k === "string") : []);
  } catch {
    return new Set();
  }
}

export function saveDismissed(userId: string, keys: Set<string>, storage: Pick<Storage, "setItem"> | null = safeStorage()): void {
  try {
    storage?.setItem(dismissStorageKey(userId), JSON.stringify([...keys].slice(-MAX_REMEMBERED)));
  } catch {
    /* storage full or blocked: the dismissal lasts for this visit only */
  }
}

export function visibleAttention(items: AttentionItem[], dismissed: Set<string>): AttentionItem[] {
  return items.filter((i) => !dismissed.has(i.key));
}

function safeStorage(): Storage | null {
  try {
    return typeof window === "undefined" ? null : window.localStorage;
  } catch {
    return null;
  }
}
