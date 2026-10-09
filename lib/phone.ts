/**
 * Phone numbers for website requests, as the database reads them.
 *
 * A browser-side mirror of normalize_phone() / validate_request_phone() in
 * supabase/18b_website_request_inbox.sql, used only for instant feedback on the
 * order form. The database check is the authority: it runs again on submit with
 * the settings in force (website_request_settings), which this file does not see.
 *
 * Canonical form is E.164: "+252612345678". Accepted Somali inputs (after
 * removing spaces, hyphens, dots and parentheses): +252612345678,
 * 00252612345678, 252612345678, 0612345678, 612345678.
 */

/** Default policy, the same as the 18b settings row. */
export const DEFAULT_SO_LEADING_DIGITS = "679";

/** Pure canonicalization, or null. `country` decides only numbers typed without a prefix. */
export function normalizePhone(raw: string | null | undefined, country = "SO"): string | null {
  if (raw == null) return null;
  let s = raw.trim().replace(/[\s().-]/g, "");
  if (!/^\+?[0-9]+$/.test(s)) return null;
  if (s.startsWith("00")) s = "+" + s.slice(2);

  if (s.startsWith("+")) {
    const d = s.slice(1);
    if (d.startsWith("252")) return /^252[1-9][0-9]{8}$/.test(d) ? "+" + d : null;
    return /^[1-9][0-9]{7,14}$/.test(d) ? "+" + d : null;
  }

  if (country === "SO") {
    if (/^252[1-9][0-9]{8}$/.test(s)) return "+" + s;
    if (/^0[1-9][0-9]{8}$/.test(s)) return "+252" + s.slice(1);
    if (/^[1-9][0-9]{8}$/.test(s)) return "+252" + s;
  }
  return null;
}

/** The form's check with the default policy: Somali numbers starting 6, 7 or 9. */
export function isAcceptedRequestPhone(raw: string, leadingDigits = DEFAULT_SO_LEADING_DIGITS): boolean {
  const c = normalizePhone(raw);
  return c !== null && c.startsWith("+252") && leadingDigits.includes(c.charAt(4));
}

export const PHONE_HINT = "Please enter a valid Somali phone number, e.g. 061 234 5678";
