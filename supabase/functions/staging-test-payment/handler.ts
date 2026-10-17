/**
 * STAGING-ONLY test payment, so the complete customer journey (checkout -> verified payment -> order -> receipt) can be exercised without a
 * real payment provider. It is NOT a payment provider. It is dead code outside Staging:
 *   - it does nothing (404) unless STAGING_TEST_PAYMENTS=true AND the project URL is the Staging project (decided in index.ts);
 *   - it only touches checkouts of the payment method 'stg_test', which only a Super Admin can create and which the database refuses
 *     to finalize without the explicit test flag this function sets;
 *   - the customer must own the checkout (checked with the caller's own token through the database's row rules).
 * Do NOT deploy it to Production.
 *
 *   POST { checkoutId, outcome }  with Authorization: Bearer <the customer's access token>
 *   outcome: succeeded | failed | cancelled | pending | reversed
 */
export type Json = Record<string, unknown>;
export type TestPaymentDeps = {
  enabled: boolean;
  /** Calls a database function with the CALLER's token (so row/ownership rules apply). */
  userRpc: (token: string, fn: string, args: Json) => Promise<{ data: unknown; error: { code?: string; message?: string } | null }>;
  /** Calls the service_role-only finalize function. */
  adminRpc: (fn: string, args: Json) => Promise<{ data: unknown; error: { code?: string; message?: string } | null }>;
  newId: () => string;
};
const json = (status: number, body: Json): Response => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const OUTCOMES = new Set(["succeeded", "failed", "cancelled", "pending", "reversed"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function handleTestPayment(req: Request, deps: TestPaymentDeps): Promise<Response> {
  if (!deps.enabled) return json(404, { error: "Not found" });
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });
  const token = /^Bearer (.+)$/.exec(req.headers.get("authorization") ?? "")?.[1];
  if (!token) return json(401, { error: "Sign in first" });
  let body: Json;
  try { body = (await req.json()) as Json; } catch { return json(422, { error: "Invalid request" }); }
  const checkoutId = String(body.checkoutId ?? ""), outcome = String(body.outcome ?? "");
  if (!UUID.test(checkoutId) || !OUTCOMES.has(outcome)) return json(422, { error: "Invalid request" });

  const own = await deps.userRpc(token, "my_checkout_status", { p_checkout_id: checkoutId });
  if (own.error) return json(own.error.code === "42501" ? 403 : 500, { error: "Not allowed" });
  const c = own.data as { methodCode?: string; amount?: number } | null;
  if (!c) return json(404, { error: "Not found" });
  if (c.methodCode !== "stg_test") return json(403, { error: "Only the Staging test payment method can be used here" });

  const id = deps.newId();
  const { data, error } = await deps.adminRpc("finalize_customer_checkout", {
    p_checkout_id: checkoutId, p_method_code: "stg_test", p_provider_event_id: "stg-" + id, p_kind: outcome,
    p_amount: outcome === "succeeded" || outcome === "reversed" ? c.amount : null, p_provider_ref: "STG-" + id.slice(0, 12), p_payload_hash: "staging-test", p_allow_test: true,
  });
  if (error) return json(error.code === "22023" || error.code === "42501" ? 422 : 500, { error: "Could not process" });
  const d = (data ?? {}) as Json;
  return json(200, { status: d.status ?? null, orderId: d.orderId ?? null });
}
