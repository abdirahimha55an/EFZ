/**
 * Privacy policy and account-deletion page content. EVERY value marked [[REQUIRED: ...]] is a placeholder the business owner must supply.
 * The pages 404 while any placeholder remains (see legalStatus), so an incomplete legal page can never be published by accident.
 * Do not fill a placeholder with a guess: legal entity, contact, retention periods and the deletion process are the owner decisions.
 */
export const LEGAL = {
  entityName: "[[REQUIRED: legal entity name]]",
  entityAddress: "[[REQUIRED: registered address]]",
  contactEmail: "[[REQUIRED: privacy / support email]]",
  contactPhone: "[[REQUIRED: support phone or WhatsApp]]",
  lastUpdated: "[[REQUIRED: date this text was approved]]",
  retentionAccount: "[[REQUIRED: how long account data is kept after deletion is processed]]",
  retentionRecords: "[[REQUIRED: how long order, payment and invoice records are kept, and why]]",
  deletionResponseTime: "[[REQUIRED: days within which EFZ processes a deletion request]]",
  deletionHandler: "[[REQUIRED: who at EFZ handles deletion requests]]",
  governingLaw: "[[REQUIRED: governing law / jurisdiction]]",
  deletionScope: "[[REQUIRED: exactly what is removed when a deletion is processed]]",
} as const;

export type LegalKey = keyof typeof LEGAL;
const MARK = "[[REQUIRED";

/** Which placeholders are still open. */
export function openPlaceholders(values: Record<string, string> = LEGAL): string[] {
  return Object.entries(values).filter(([, v]) => v.includes(MARK)).map(([k]) => k);
}

/**
 * "published": every placeholder replaced -> the pages are served.
 * "draft": placeholders remain but NEXT_PUBLIC_LEGAL_PREVIEW=true (Staging/Preview review only) -> served with a DRAFT banner.
 * "hidden": placeholders remain in any other case (Production) -> the pages return 404.
 */
export function legalStatus(values: Record<string, string> = LEGAL, preview: string | undefined = process.env.NEXT_PUBLIC_LEGAL_PREVIEW): "published" | "draft" | "hidden" {
  if (openPlaceholders(values).length === 0) return "published";
  return preview === "true" ? "draft" : "hidden";
}

/** What the customer app and the Hub actually handle (taken from the code and migrations 21-29). The owner reviews this before publication. */
export const DATA_WE_HANDLE = [
  "Account: full name, phone number, email address and password (the password is held by the sign-in service, never readable by EFZ staff).",
  "Orders and requests: products, quantities, delivery location and notes, dates and status, and the prices agreed with you.",
  "Account statements: invoices, payments and balances for your orders.",
  "Account administration: approval status, and the reason you give if you ask for deletion.",
];
