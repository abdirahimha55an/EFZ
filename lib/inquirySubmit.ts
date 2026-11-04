/**
 * Browser side of POST /api/inquiries: builds the payload the database function expects and turns the route's
 * answers into errors the forms already know how to show (a sentence plus a code such as WR429).
 */
import type { PublicInquiryInput } from "@/lib/types";

export class InquirySubmitError extends Error {
  readonly code: string;
  constructor(message: string, code = "") {
    super(message);
    this.name = "InquirySubmitError";
    this.code = code;
  }
}

export function inquiryPayload(input: PublicInquiryInput) {
  return {
    kind: input.kind,
    name: input.name,
    phone: input.phone ?? "",
    email: input.email ?? "",
    organization: input.organization ?? "",
    businessType: input.businessType ?? "",
    subject: input.subject ?? "",
    message: input.message ?? "",
    hp: input.hp ?? "",
    submissionKey: input.submissionKey ?? null,
  };
}

/** Sends the inquiry and returns its id. A network failure throws the browser's own TypeError ("Failed to fetch"). */
export async function postInquiry(input: PublicInquiryInput, fetchImpl: typeof fetch = fetch): Promise<string> {
  const res = await fetchImpl("/api/inquiries", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(inquiryPayload(input)),
  });
  let body: { id?: unknown; message?: unknown; code?: unknown } = {};
  try {
    body = await res.json();
  } catch {
    // not JSON (for example a gateway error page): fall through to the generic message
  }
  if (res.ok && typeof body.id === "string") return body.id;
  const message = typeof body.message === "string" && body.message ? body.message : "Something went wrong. Please try again.";
  throw new InquirySubmitError(message, typeof body.code === "string" ? body.code : "");
}
