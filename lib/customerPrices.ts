/**
 * Customer price agreements (migration 26): the Hub's types and the pure rules the screen uses to explain things before the database answers. The database is the
 * authority (it validates every rule again and records the audit trail); every function here only mirrors a rule it enforces.
 */

export type AgreementStatus = "pending_review" | "active" | "revoked" | "rejected";

export type PriceAgreement = {
  id: string; customerId: string; customerName: string; productId: string; productName: string; designId: string | null; designName: string;
  unitPrice: number | string; listPrice: number | string; effectiveFrom: string; effectiveTo: string | null; status: AgreementStatus; source: "manual" | "import";
  inEffect: boolean; expired: boolean; expiresSoon: boolean; belowCurrentCost: boolean; belowCostApproved: boolean; reason: string;
  evidence: { orders?: number; prices?: (number | string)[]; firstOrder?: string; lastOrder?: string; since?: string } | null;
  createdAt: string; verifiedAt: string | null; verifyNote: string | null; closedAt: string | null; closedReason: string | null;
};

export type PriceAlerts = { asOf: string; pending: number; expiringSoon: number; expiredLast30Days: number; belowCurrentCost: number };

export type ImportItem = {
  customerId: string; customerName: string; productId: string; productName: string | null; designName: string; orders: number; prices: (number | string)[];
  latestPrice: number | string; firstOrder: string; lastOrder: string; listPriceNow: number | string | null;
  proposedPrice?: number | string; proposedFrom?: string; designId?: string | null; reason?: string;
};
export type ImportReport = { dryRun: boolean; since: string; minOrders: number; candidates: ImportItem[]; needsConfirmation: ImportItem[]; alreadyCovered: number; created: number };

export type PriceHistoryEvent = { at: string; by: string; kind: string; agreementId: string; details: Record<string, unknown> };

export const MIN_NOTE = 10;

/** What the Hub checks before it enables the Save button (the database checks all of it again). */
export function agreementProblem(i: { customerId: string; productId: string; price: string; from: string; to: string; reason: string; belowCost: boolean; belowCostReason: string; isSuperAdmin: boolean }): string | null {
  if (!i.customerId) return "Choose a customer.";
  if (!i.productId) return "Choose a product.";
  const price = Number(i.price);
  if (!(price > 0) || price > 1_000_000 || Math.round(price * 100) !== price * 100) return "The agreed price must be more than 0, in whole cents.";
  if (!/^\d{4}-\d{2}-\d{2}$/.test(i.from)) return "Give the date the price starts.";
  if (i.to !== "" && !/^\d{4}-\d{2}-\d{2}$/.test(i.to)) return "The end date is not valid.";
  if (i.to !== "" && i.to < i.from) return "The end date cannot be before the start date.";
  if (i.reason.trim().length < MIN_NOTE) return `Record the authorization or evidence (at least ${MIN_NOTE} characters).`;
  if (i.belowCost) {
    if (!i.isSuperAdmin) return "This price is below the product's cost. Only a Super Admin can approve a below-cost price.";
    if (i.belowCostReason.trim().length < MIN_NOTE) return `A below-cost price needs a reason of at least ${MIN_NOTE} characters.`;
  }
  return null;
}

/** A note or reason for verifying, rejecting, revoking or ending: at least MIN_NOTE characters. */
export function noteProblem(note: string): string | null { return note.trim().length < MIN_NOTE ? `Write at least ${MIN_NOTE} characters.` : null; }

export function statusLabel(a: Pick<PriceAgreement, "status" | "inEffect" | "expired" | "expiresSoon" | "effectiveFrom">, today: string): string {
  if (a.status === "pending_review") return "Waiting for verification (not used)";
  if (a.status === "rejected") return "Rejected";
  if (a.status === "revoked") return "Revoked";
  if (a.expired) return "Expired";
  if (!a.inEffect && a.effectiveFrom > today) return `Starts ${a.effectiveFrom}`;
  return a.expiresSoon ? "Active, ends soon" : "Active";
}

/** The whole manual-confirmation list as CSV text (for the owner to work through); quotes are escaped. */
export function manualConfirmationCsv(items: ImportItem[]): string {
  const q = (v: unknown) => `"${String(v ?? "").replace(/"/g, '""')}"`;
  const head = ["Customer", "Customer id", "Product", "Design", "Orders", "Prices seen", "Latest price", "Current list price", "First order", "Last order", "Why it needs confirmation"];
  return [head.map(q).join(","), ...items.map((i) => [i.customerName, i.customerId, i.productName ?? i.productId, i.designName, i.orders, i.prices.join(" / "), i.latestPrice, i.listPriceNow ?? "", i.firstOrder, i.lastOrder, i.reason ?? ""].map(q).join(","))].join("\r\n");
}

export function importSummary(r: ImportReport): string {
  const mode = r.dryRun ? "Preview only: nothing was saved." : `${r.created} candidate(s) were saved as pending (not used until verified).`;
  return `${mode} ${r.candidates.length} consistent price(s) found, ${r.needsConfirmation.length} need manual confirmation, ${r.alreadyCovered} already covered. Orders since ${r.since}, at least ${r.minOrders} per price.`;
}
