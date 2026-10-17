/**
 * Presentation helpers for the Hub's customer-account review screen (migration 21).
 *
 * NOTHING here decides who may review or what is legal: the database functions do (permission
 * manage_customer_accounts, allowed transitions, the verification rules). These helpers only
 * decide which buttons to offer and when a form is complete enough to submit, so staff get an
 * immediate hint instead of a round trip. If a helper and the database ever disagree, the
 * database wins and its sentence is shown.
 */
import type { CustomerAccount, CustomerAccountMatch, CustomerAccountStatus } from "./types";

export const STATUS_LABEL: Record<CustomerAccountStatus, string> = { pending: "Pending", approved: "Approved", rejected: "Rejected", suspended: "Suspended" };
export const FILTERS = ["pending", "approved", "suspended", "rejected", "all"] as const;
export type AccountFilter = (typeof FILTERS)[number];

export type AccountAction = "approve" | "reject" | "suspend" | "reinstate";

/** The transitions the database allows, so only those buttons are offered. A rejected account is final. */
export function allowedActions(status: CustomerAccountStatus): AccountAction[] {
  switch (status) {
    case "pending": return ["approve", "reject"];
    case "approved": return ["suspend"];
    case "suspended": return ["reinstate"];
    default: return [];
  }
}

export function filterAccounts(list: CustomerAccount[], filter: AccountFilter, query: string): CustomerAccount[] {
  const q = query.trim().toLowerCase();
  return list.filter((a) =>
    (filter === "all" || a.status === filter) &&
    (q === "" || [a.fullName, a.organization, a.email, a.phone].some((v) => v.toLowerCase().includes(q))));
}

export function countByStatus(list: CustomerAccount[]): Record<CustomerAccountStatus, number> {
  const c: Record<CustomerAccountStatus, number> = { pending: 0, approved: 0, rejected: 0, suspended: 0 };
  for (const a of list) c[a.status]++;
  return c;
}

export const MIN_VERIFY_NOTE = 10;   // mirrors the database's minimum for an approval note (UX hint only)
export const MIN_REASON = 5;         // mirrors the database's minimum for a reject/suspend/reinstate reason

export type ApprovalDraft = {
  mode: "link" | "create" | null;
  linkCustomerId: string | null;
  verified: boolean;
  note: string;
};

/**
 * Whether the approval form is complete. Linking an existing customer ALWAYS needs the explicit "I verified this
 * person" box; creating a new customer needs it when the phone number already belongs to someone (the reviewer
 * must confirm this is a different person). A candidate that is already linked to an app account can never be chosen.
 */
export function approvalProblem(d: ApprovalDraft, matches: CustomerAccountMatch[]): string | null {
  if (d.mode === null) return "Choose to link an existing customer or create a new one.";
  if (d.mode === "link") {
    const m = matches.find((x) => x.customerId === d.linkCustomerId);
    if (!d.linkCustomerId || !m) return "Select the customer to link.";
    if (m.linked) return "That customer is already linked to another app account.";
    if (m.status !== "active") return "Only an active customer can be linked.";
    if (!d.verified) return "Confirm that you verified this person before linking an existing customer.";
  } else if (matches.length > 0 && !d.verified) {
    return "A customer with this phone number exists. Confirm this is a different person, or link that customer instead.";
  }
  if (d.note.trim().length < MIN_VERIFY_NOTE) return `Describe how you verified this person (at least ${MIN_VERIFY_NOTE} characters).`;
  return null;
}

export function reasonProblem(reason: string): string | null {
  return reason.trim().length < MIN_REASON ? `Give a reason (at least ${MIN_REASON} characters).` : null;
}

export const ACTION_LABEL: Record<AccountAction, string> = { approve: "Approve", reject: "Reject", suspend: "Suspend", reinstate: "Reinstate" };
export const ACTION_RESULT: Record<AccountAction, string> = { approve: "approved", reject: "rejected", suspend: "suspended", reinstate: "reinstated" };
