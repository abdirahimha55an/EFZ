/**
 * Provider payment confirmation for EFZ customer checkouts - the request handler.
 *
 * This is the ONLY door through which a payment can become real: it turns a result that a payment provider's own server has
 * authenticated into one call of the service_role-only database function finalize_customer_checkout(). The mobile app can never
 * mark anything paid.
 *
 * IMPORTANT - no provider is integrated yet. A provider integration is an ADAPTER: code that checks the provider's signature or
 * calls the provider's API, and returns a normalized event. Until an adapter is registered for a payment method code, this
 * function answers 501 for that code and nothing happens. No adapter ships in this repository because EFZ has not chosen or
 * been given access to a provider. The customer's PIN is entered only in the provider's own authorization flow and never
 * reaches EFZ: nothing here has a field for it.
 *
 * Contract
 *   POST /payment-confirm/<methodCode>      (the provider's callback; the adapter decides how the body is authenticated)
 *   200 { status, orderId, duplicate }      processed (duplicates are safe: same provider event id changes nothing)
 *   401 verification failed                 400 malformed event / method mismatch   405 not POST   413 too large
 *   422 the database refused the event      501 no verified provider integration for this method   500 server problem
 */

export type Json = Record<string, unknown>;

export type NormalizedEvent = {
  checkoutId: string;
  methodCode: string;
  providerEventId: string;
  kind: "pending" | "succeeded" | "failed" | "cancelled" | "expired" | "reversed";
  amount: number | null;
  providerRef: string | null;
};

export class VerificationError extends Error {}

/** A provider integration: authenticates the callback (signature, or a call back to the provider) and returns a normalized event. */
export type ProviderAdapter = { verify(req: Request, rawBody: string): Promise<NormalizedEvent> };

export type PaymentDeps = {
  adapters: Record<string, ProviderAdapter>;
  rpc: (fn: string, args: Json) => Promise<{ data: unknown; error: { code?: string; message?: string } | null }>;
  sha256: (input: string) => Promise<string>;
};

const MAX_BODY_BYTES = 65536;
const KINDS = new Set(["pending", "succeeded", "failed", "cancelled", "expired", "reversed"]);
const json = (status: number, body: Json): Response => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function handlePaymentConfirmation(req: Request, deps: PaymentDeps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });
  const method = decodeURIComponent(new URL(req.url).pathname.split("/").filter(Boolean).pop() ?? "");
  const adapter = Object.prototype.hasOwnProperty.call(deps.adapters, method) ? deps.adapters[method] : undefined;
  if (!adapter) return json(501, { error: "This payment method has no verified provider integration" });

  const raw = await req.text();
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) return json(413, { error: "Body too large" });

  let ev: NormalizedEvent;
  try {
    ev = await adapter.verify(req, raw);
  } catch (e) {
    if (e instanceof VerificationError) return json(401, { error: "Verification failed" });
    return json(500, { error: "Verification is unavailable right now" });
  }
  if (!ev || ev.methodCode !== method || !UUID.test(ev.checkoutId) || !KINDS.has(ev.kind) || !ev.providerEventId || ev.providerEventId.length > 200) {
    return json(400, { error: "Malformed event" });
  }
  if (ev.kind === "succeeded" && !(typeof ev.amount === "number" && Number.isFinite(ev.amount) && ev.amount > 0)) return json(400, { error: "A success event needs the amount" });

  const { data, error } = await deps.rpc("finalize_customer_checkout", {
    p_checkout_id: ev.checkoutId, p_method_code: method, p_provider_event_id: ev.providerEventId, p_kind: ev.kind,
    p_amount: ev.amount, p_provider_ref: ev.providerRef, p_payload_hash: await deps.sha256(raw), p_allow_test: false,
  });
  if (error) {
    if (error.code === "22023" || error.code === "42501") return json(422, { error: "The event was refused" });
    return json(500, { error: "Could not process the event" });
  }
  const d = (data ?? {}) as Json;
  return json(200, { status: d.status ?? null, orderId: d.orderId ?? null, duplicate: d.duplicate === true });
}
