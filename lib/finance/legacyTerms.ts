/**
 * Evidence shown to the Super Admin when reviewing a legacy order whose payment
 * terms were never recorded (orders.payment_terms IS NULL).
 *
 * Read only and advisory: this NEVER chooses the terms. It lists what the records
 * establish ("confirmed"), what they only hint at ("ambiguous") and what is not
 * recorded at all ("missing"). The Super Admin decides; set_order_payment_terms()
 * (migration 20) does the audited, one-time write. Terms are not inferred from
 * whether an order is paid today - only facts such as a balance still owed or a
 * payment recorded in the app after the order date count as evidence.
 */

export type EvidenceKind = "confirmed" | "ambiguous" | "missing";
export type EvidenceLine = { kind: EvidenceKind; text: string; points: "credit" | "paid_at_sale" | null };
export type ReviewPayment = { date: string; createdAt?: string; amountCents: number; recordedBy?: string };
export type ReviewOrder = { date: string; totalCents: number; amountPaidCents: number; outstandingCents: number; payments: ReviewPayment[] };

const money = (cents: number) => `$${(cents / 100).toFixed(2)}`;
const dayMs = 86_400_000;
const daysBetween = (from: string, to: string) => Math.round((Date.parse(to) - Date.parse(from)) / dayMs);

export function legacyEvidence(o: ReviewOrder): EvidenceLine[] {
  const out: EvidenceLine[] = [];
  if (o.outstandingCents > 0) {
    out.push({ kind: "confirmed", points: "credit", text: `Balance still owed: ${money(o.amountPaidCents)} of ${money(o.totalCents)} paid, ${money(o.outstandingCents)} outstanding, so the order was not paid in full.` });
  }
  const inApp = o.payments.filter((p) => !!p.recordedBy);
  for (const p of inApp) {
    const on = (p.createdAt ?? "").slice(0, 10) || p.date;
    if (on > o.date) out.push({ kind: "confirmed", points: "credit", text: `Payment of ${money(p.amountCents)} was recorded in the app on ${on} (${daysBetween(o.date, on)} days after the order date ${o.date}); it is audit-backed and not an initial payment.` });
  }
  const paidInFull = o.outstandingCents === 0 && o.totalCents > 0 && o.amountPaidCents === o.totalCents;
  if (paidInFull && o.payments.length > 0) {
    const later = o.payments.filter((p) => p.date > o.date);
    if (later.length === 0) {
      out.push({ kind: "ambiguous", points: "paid_at_sale", text: `Fully paid, with every payment dated the order date ${o.date}. The same calendar date does not prove the order was paid at the moment of sale.` });
    } else if (inApp.length === 0) {
      const sum = later.reduce((s, p) => s + p.amountCents, 0);
      out.push({ kind: "ambiguous", points: "credit", text: `${money(sum)} of ${money(o.totalCents)} carries a payment date after the order date (${[...new Set(later.map((p) => p.date))].join(", ")}). Payment dates are as recorded and have not been independently confirmed.` });
    }
  }
  if (o.totalCents === 0) out.push({ kind: "missing", points: null, text: "The order total is zero, so payment history says nothing about how it was sold." });
  if (o.payments.length === 0 && o.outstandingCents === 0 && o.totalCents > 0) out.push({ kind: "missing", points: null, text: "No payments are recorded." });
  out.push({ kind: "missing", points: null, text: "The terms agreed with the customer at the time of sale are not recorded anywhere in the system." });
  return out;
}

/** What the records lean towards, for display only. "none" when nothing points either way or the evidence conflicts. */
export function evidenceLean(lines: EvidenceLine[]): { lean: "credit" | "paid_at_sale" | "none"; strength: "confirmed" | "weak" | "none" } {
  const confirmed = new Set(lines.filter((l) => l.kind === "confirmed" && l.points).map((l) => l.points));
  if (confirmed.size === 1) return { lean: [...confirmed][0] as "credit" | "paid_at_sale", strength: "confirmed" };
  if (confirmed.size > 1) return { lean: "none", strength: "none" };
  const weak = new Set(lines.filter((l) => l.kind === "ambiguous" && l.points).map((l) => l.points));
  if (weak.size === 1) return { lean: [...weak][0] as "credit" | "paid_at_sale", strength: "weak" };
  return { lean: "none", strength: "none" };
}

/** A plain factual summary the Super Admin can insert into the evidence note and edit. Never states more than the records show. */
export function evidenceSummary(lines: EvidenceLine[]): string {
  return lines.filter((l) => l.kind !== "missing").map((l) => l.text).join(" ");
}

export const MIN_EVIDENCE_CHARS = 10;
export const MAX_EVIDENCE_CHARS = 500;
