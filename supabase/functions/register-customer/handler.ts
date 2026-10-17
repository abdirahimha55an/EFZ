/**
 * Customer registration for the EFZ Android app - the request handler.
 *
 * Pure and dependency-injected so it runs the same under Deno (Supabase Edge
 * Functions, see index.ts) and under Node (handler.test.ts). It holds NO secret:
 * the service-role client is built in index.ts from the function's own environment
 * and passed in as `deps`. Nothing here is imported by the Next.js app.
 *
 * Contract
 *   POST { email, password, fullName, phone, organization? }
 *   202  { status: "pending_approval", message }   registered, OR the request could not be
 *                                                  honoured for a reason we must not reveal
 *                                                  (staff email, email already registered):
 *                                                  the response is byte-identical.
 *   405  not POST        413  body too large      415  not JSON
 *   422  invalid input (generic message, never echoes the input)
 *   429  rate limited
 *   500  / 502  server problem (generic message)
 *
 * What it guarantees
 *   - The auth user is created through the Admin API with app_metadata.efz_kind = "customer"
 *     (a user cannot set app_metadata). The database trigger never links such a user to a
 *     staff profile. Auth sign-up stays disabled project-wide.
 *   - A staff email, or an email that already has an account, creates nothing and looks like
 *     success. The response never contains an id, a CRM record or any staff information.
 *   - The client address is only ever used as a salted hash, for rate limiting.
 *   - The password is passed to the Admin API only: never logged, never stored, never in a
 *     database call.
 *   - If the database refuses the account after the auth user was created, the auth user is
 *     deleted again (no orphan).
 */

export type Json = Record<string, unknown>;

export type RegistrationDeps = {
  /** Calls a SECURITY DEFINER function as service_role. Resolves { data, error }. */
  rpc: (fn: string, args: Json) => Promise<{ data: unknown; error: { code?: string; message?: string } | null }>;
  /** Admin API: auth.admin.createUser. */
  createUser: (attrs: { email: string; password: string; email_confirm: boolean; app_metadata: Json; user_metadata: Json }) =>
    Promise<{ data: { user: { id: string } | null }; error: { status?: number; code?: string; message?: string } | null }>;
  /** Admin API: auth.admin.deleteUser (compensation only). */
  deleteUser: (id: string) => Promise<unknown>;
  /** Hex SHA-256 of a string. */
  sha256: (input: string) => Promise<string>;
  /** Secret salt for the client-address hash. */
  hintSalt: string;
  /**
   * false (default): the Auth user is created already confirmed; EFZ's phone/identity check at approval is the only control.
   * true: the Auth user is created UNCONFIRMED, so password sign-in is refused until the customer proves the mailbox with the
   * 6-digit code the app requests afterwards (auth.resend type 'signup'). Turn on only once custom SMTP and the code email
   * template are in place, otherwise nobody can ever confirm.
   */
  requireEmailVerification?: boolean;
};

const MAX_BODY_BYTES = 4096;

const PENDING = { status: "pending_approval", message: "Your registration was received. EFZ will review it and contact you." } as const;

const json = (status: number, body: Json): Response =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

const pending = () => json(202, { ...PENDING });
const bad = (message: string) => json(422, { error: message });

const isString = (v: unknown): v is string => typeof v === "string";

export function clientAddress(headers: Headers): string | null {
  const fwd = headers.get("cf-connecting-ip") ?? headers.get("x-real-ip") ?? headers.get("x-forwarded-for");
  const first = fwd?.split(",")[0]?.trim();
  return first ? first : null;
}

export async function handleRegistration(req: Request, deps: RegistrationDeps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });
  if (!(req.headers.get("content-type") ?? "").toLowerCase().startsWith("application/json")) return json(415, { error: "Send JSON" });

  const raw = await req.text();
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) return json(413, { error: "Request too large" });
  let body: Json;
  try {
    const parsed = JSON.parse(raw);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return bad("Invalid request");
    body = parsed as Json;
  } catch {
    return bad("Invalid request");
  }

  const email = isString(body.email) ? body.email.trim().toLowerCase() : "";
  const password = isString(body.password) ? body.password : "";
  const fullName = isString(body.fullName) ? body.fullName.trim() : "";
  const phone = isString(body.phone) ? body.phone.trim() : "";
  const organization = body.organization === undefined || body.organization === null ? "" : isString(body.organization) ? body.organization.trim() : null;

  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || email.length > 254) return bad("Please enter a valid email address");
  if (password.length < 10 || password.length > 72) return bad("Choose a password of 10 to 72 characters");
  if (fullName.length < 1 || fullName.length > 200) return bad("Please enter your name");
  if (phone.length < 1 || phone.length > 50) return bad("Please enter a valid phone number");
  if (organization === null || organization.length > 200) return bad("Please check the organization field");

  const addr = clientAddress(req.headers);
  const hint = addr ? (await deps.sha256(`${deps.hintSalt}:${addr}`)).slice(0, 32) : null;

  // 1. Pre-flight BEFORE any auth user exists: validation, rate limits, staff email, duplicates.
  const check = await deps.rpc("customer_registration_check", { p_email: email, p_phone: phone, p_client_hint: hint });
  if (check.error) {
    if (check.error.code === "WR429") return json(429, { error: "Too many registrations. Please try again later." });
    if (check.error.code === "WR422") return bad("Please check your phone number and email");
    return json(500, { error: "Registration is unavailable right now" });
  }
  const verdict = Array.isArray(check.data) ? (check.data[0] as Json | undefined)?.verdict : (check.data as Json | null)?.verdict;
  if (verdict === "reserved" || verdict === "duplicate") return pending();   // identical to success: nothing is revealed
  if (verdict !== "ok") return json(500, { error: "Registration is unavailable right now" });

  // 2. Create the auth user through the Admin API, marked as a customer registration.
  const created = await deps.createUser({
    email,
    password,
    email_confirm: deps.requireEmailVerification !== true,
    app_metadata: { efz_kind: "customer" },
    user_metadata: { name: fullName },
  });
  if (created.error || !created.data.user) {
    const e = created.error;
    if (e && (e.code === "email_exists" || e.code === "user_already_exists" || /already (been )?registered|already exists/i.test(e.message ?? ""))) return pending();
    return json(502, { error: "Registration is unavailable right now" });
  }
  const authId = created.data.user.id;

  // 3. Create the pending account. On any refusal remove the auth user again.
  const reg = await deps.rpc("register_customer_account", {
    p_auth_user_id: authId, p_email: email, p_full_name: fullName, p_phone: phone, p_organization: organization, p_client_hint: hint,
  });
  if (reg.error) {
    try { await deps.deleteUser(authId); } catch { /* best effort; an unmarked-by-account auth user is inert (no profile, no account) */ }
    if (reg.error.code === "WR429") return json(429, { error: "Too many registrations. Please try again later." });
    if (reg.error.code === "WR422") return bad("Please check your details");
    return json(500, { error: "Registration is unavailable right now" });
  }
  return pending();
}
