/**
 * The public Contact and Wholesale forms (migration 30).
 *
 * A browser-side mirror of the checks in submit_public_inquiry() (supabase/30_public_inquiries.sql), used only for instant feedback. The database
 * check is the authority: it runs again on submit, together with the per-visitor limit and the duplicate check.
 *
 * Pure (no Supabase, no React) so node --test can run it.
 */

import { isAcceptedRequestPhone, PHONE_HINT } from "@/lib/phone";

/** Field limits, the same numbers as the table's CHECK constraints. */
export const INQUIRY_LIMITS = {
  name: 200,
  organization: 200,
  phone: 50,
  email: 254,
  subject: 200,
  message: 3000,
} as const;

/** The wholesale business types the database accepts (submit_public_inquiry checks the same list). */
export const BUSINESS_TYPES = ["Futsal Arena", "Football Academy/School", "Sports Retailer", "Tournament Organizer", "Other"] as const;
export type BusinessType = (typeof BUSINESS_TYPES)[number];

export type ContactValues = { name: string; phone: string; email: string; subject: string; message: string };
export type WholesaleValues = { organization: string; name: string; phone: string; businessType: string; message: string };

export type FieldErrors<K extends string> = Partial<Record<K, string>>;

/** Same pattern as the database: something@something.tld, no spaces. */
const EMAIL_PATTERN = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

export const isPlausibleEmail = (value: string): boolean => EMAIL_PATTERN.test(value.trim());

const tooLong = (value: string, max: number) => value.trim().length > max;

export function validateContact(v: ContactValues): FieldErrors<keyof ContactValues> {
  const errors: FieldErrors<keyof ContactValues> = {};
  const name = v.name.trim();
  const phone = v.phone.trim();
  const email = v.email.trim();

  if (!name) errors.name = "Please enter your name.";
  else if (tooLong(name, INQUIRY_LIMITS.name)) errors.name = `Please keep your name under ${INQUIRY_LIMITS.name} characters.`;

  if (phone && !isAcceptedRequestPhone(phone)) errors.phone = PHONE_HINT;
  if (email && !isPlausibleEmail(email)) errors.email = "Please enter a valid email address, e.g. name@example.com.";
  else if (tooLong(email, INQUIRY_LIMITS.email)) errors.email = "That email address is too long.";
  // A reply needs somewhere to go.
  if (!phone && !email) {
    errors.phone = errors.phone ?? "Please give a phone number or an email address so we can reply.";
    errors.email = errors.email ?? "Please give a phone number or an email address so we can reply.";
  }

  const subject = v.subject.trim();
  if (!subject) errors.subject = "Please enter a subject.";
  else if (tooLong(subject, INQUIRY_LIMITS.subject)) errors.subject = `Please keep the subject under ${INQUIRY_LIMITS.subject} characters.`;

  const message = v.message.trim();
  if (!message) errors.message = "Please enter your message.";
  else if (tooLong(message, INQUIRY_LIMITS.message)) errors.message = `Please keep your message under ${INQUIRY_LIMITS.message} characters.`;

  return errors;
}

export function validateWholesale(v: WholesaleValues): FieldErrors<keyof WholesaleValues> {
  const errors: FieldErrors<keyof WholesaleValues> = {};

  const organization = v.organization.trim();
  if (!organization) errors.organization = "Please enter your organization or arena name.";
  else if (tooLong(organization, INQUIRY_LIMITS.organization)) errors.organization = `Please keep this under ${INQUIRY_LIMITS.organization} characters.`;

  const name = v.name.trim();
  if (!name) errors.name = "Please enter the contact person's name.";
  else if (tooLong(name, INQUIRY_LIMITS.name)) errors.name = `Please keep the name under ${INQUIRY_LIMITS.name} characters.`;

  if (!isAcceptedRequestPhone(v.phone)) errors.phone = PHONE_HINT;

  if (!(BUSINESS_TYPES as readonly string[]).includes(v.businessType)) errors.businessType = "Please choose your business type.";

  if (tooLong(v.message, INQUIRY_LIMITS.message)) errors.message = `Please keep this under ${INQUIRY_LIMITS.message} characters.`;

  return errors;
}

/** The first field with an error, in the order the form shows them, so the form can move focus to it. */
export function firstInvalid<K extends string>(errors: FieldErrors<K>, order: readonly K[]): K | null {
  return order.find((k) => Boolean(errors[k])) ?? null;
}

/**
 * Turns the sentence describeDbError() produced into one a visitor should see. The database's own sentences for validation, duplicates and the
 * rate limit are already written for visitors and pass through; network and permission failures are replaced.
 */
export function visitorFriendlyError(sentence: string): string {
  const s = sentence.trim();
  if (!s) return "Something went wrong. Please try again, or contact us on WhatsApp.";
  if (/failed to fetch|network|load failed|timed? ?out/i.test(s)) {
    return "We could not reach the server. Please check your connection and try again.";
  }
  if (/permission denied|row-level security|schema cache|does not exist|jwt|not allowed/i.test(s)) {
    return "This form is temporarily unavailable. Please contact us on WhatsApp instead.";
  }
  return s;
}
