/**
 * EFZ customer payments: start a provider payment, ask the provider what happened, and turn a VERIFIED answer into a paid order.
 *
 * Trust model (read this before changing anything)
 *  - A payment is real only when EFZ's own server asked the payment provider (server to server, with EFZ's merchant secret) and the
 *    provider said "paid" for the invoice EFZ created. Nothing the app, a browser redirect or a callback BODY says is believed.
 *  - A provider callback is only a trigger: its body is ignored and EFZ queries the provider itself. A forged or replayed callback can
 *    therefore do nothing except cause a harmless, idempotent status query.
 *  - The result is recorded by the database function finalize_customer_checkout() (service_role only), which re-checks amount, price and
 *    stock, is idempotent per provider event, and parks anything doubtful for staff review. This file never creates an order.
 *  - The customer types a PIN only in the provider's own screen or phone prompt. This code has no field for a PIN or card number and
 *    never sees one; the only customer input is the wallet PHONE NUMBER.
 *  - Provider secrets exist only in this function's environment (index.ts), never in the app or the repository.
 *
 * Routes (the function URL is .../payments)
 *   POST /start                  { checkoutId, walletNumber }      signed-in customer; starts the provider payment of THEIR checkout
 *   POST /status                 { checkoutId }                    signed-in customer; asks the provider, records a verified result, returns the checkout's status
 *   GET|POST /callback/<method>?c=<checkoutId>                     the provider's redirect/callback: body ignored, EFZ queries the provider
 */

export type Json = Record<string, unknown>;

export type ProviderResult = {
  kind: "pending" | "succeeded" | "failed" | "cancelled" | "expired";
  /** What the provider reports as charged, when it reports it. null when the provider's answer carries no amount. */
  amount: number | null;
  currency: string | null;
  providerRef: string | null;
  /** Stable id of this answer, so asking twice records once. */
  eventId: string;
};

/** Thrown when the provider refuses to start a payment for a reason the customer can act on (never contains secrets). */
export class ProviderRefused extends Error {}

export type StartInput = { checkoutId: string; amount: number; currency: string; walletNumber: string; callbackBase: string };
export type ProviderAdapter = {
  /** Creates the payment at the provider. Returns the provider's own reference (used later to query) and, for hosted pages, the URL to open. */
  start(i: StartInput): Promise<{ providerRef: string; redirectUrl?: string }>;
  /** Asks the provider for the CURRENT status of this checkout's payment. Must authenticate to the provider with EFZ's secret. */
  query(i: { checkoutId: string; providerRef: string; amount: number }): Promise<ProviderResult>;
};

type Rpc = (fn: string, args: Json) => Promise<{ data: unknown; error: { code?: string; message?: string } | null }>;
export type PaymentsDeps = {
  adapters: Record<string, ProviderAdapter>;
  adminRpc: Rpc;
  userRpc: (token: string, fn: string, args: Json) => ReturnType<Rpc>;
  /** The public URL of this function (used to build callback URLs). */
  baseUrl: string;
  now: () => number;
};

const json = (status: number, body: Json): Response => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const own = (o: object, k: string) => Object.prototype.hasOwnProperty.call(o, k);
const MIN_QUERY_GAP_MS = 2000;
const lastQuery = new Map<string, number>();

/** A mobile-money wallet number in international form without "+" or leading zeros (for example 252612345678). Digits only, 11 to 13 of them. */
export function normalizeWallet(input: unknown): string | null {
  const d = String(input ?? "").replace(/[\s()+-]/g, "");
  if (!/^\d+$/.test(d)) return null;
  const n = /^252\d{8,10}$/.test(d) ? d : /^0\d{8,10}$/.test(d) ? "252" + d.slice(1) : /^\d{8,10}$/.test(d) ? "252" + d : null;
  return n && /^252\d{8,10}$/.test(n) ? n : null;
}

export async function handlePayments(req: Request, deps: PaymentsDeps): Promise<Response> {
  const url = new URL(req.url);
  const parts = url.pathname.split("/").filter(Boolean);
  const at = parts.indexOf("payments");
  const route = parts.slice(at >= 0 ? at + 1 : 0);
  if (route[0] === "callback") return callback(req, url, route[1] ?? "", deps);
  if (route[0] === "start") return start(req, deps);
  if (route[0] === "status") return status(req, deps);
  return json(404, { error: "Not found" });
}

async function customerCheckout(req: Request, deps: PaymentsDeps): Promise<{ ok: true; id: string; token: string; method: string; status: string; body: Json } | { ok: false; res: Response }> {
  if (req.method !== "POST") return { ok: false, res: json(405, { error: "Method not allowed" }) };
  const token = /^Bearer (.+)$/.exec(req.headers.get("authorization") ?? "")?.[1];
  if (!token) return { ok: false, res: json(401, { error: "Sign in first" }) };
  let body: Json;
  try { body = (await req.json()) as Json; } catch { return { ok: false, res: json(422, { error: "Invalid request" }) }; }
  const id = String(body.checkoutId ?? "");
  if (!UUID.test(id)) return { ok: false, res: json(422, { error: "Invalid request" }) };
  // Ownership: the database answers this only for the caller's OWN checkout (and only for an approved customer).
  const mine = await deps.userRpc(token, "my_checkout_status", { p_checkout_id: id });
  if (mine.error) return { ok: false, res: json(mine.error.code === "42501" ? 403 : 500, { error: "Not allowed" }) };
  const c = mine.data as { methodCode?: string; status?: string } | null;
  if (!c) return { ok: false, res: json(404, { error: "Not found" }) };
  return { ok: true, id, token, method: String(c.methodCode), status: String(c.status), body };
}

async function start(req: Request, deps: PaymentsDeps): Promise<Response> {
  const c = await customerCheckout(req, deps);
  if (!c.ok) return c.res;
  const adapter = own(deps.adapters, c.method) ? deps.adapters[c.method] : undefined;
  if (!adapter) return json(501, { error: "This payment method has no verified provider integration" });
  const wallet = normalizeWallet(c.body.walletNumber);
  if (!wallet) return json(422, { error: "Enter the mobile number of your wallet, for example 061 234 5678" });

  const info = await deps.adminRpc("checkout_for_provider", { p_checkout_id: c.id });
  const ck = info.data as { methodKind?: string; methodEnabled?: boolean; status?: string; amount?: number; currency?: string; providerRef?: string | null } | null;
  if (info.error || !ck) return json(500, { error: "Could not start the payment" });
  if (ck.methodKind !== "provider" || !ck.methodEnabled) return json(422, { error: "That payment method is not available" });
  if (ck.status !== "created" && ck.status !== "pending") return json(409, { error: "This payment is already settled", status: ck.status });
  // A payment that was already started is never started twice (no double charge): the customer resumes by checking the status.
  if (ck.providerRef) return json(200, { mode: "resume", message: "This payment was already started. Check its status." });

  let started: { providerRef: string; redirectUrl?: string };
  try {
    started = await adapter.start({ checkoutId: c.id, amount: Number(ck.amount), currency: ck.currency ?? "USD", walletNumber: wallet, callbackBase: deps.baseUrl });
  } catch (e) {
    if (e instanceof ProviderRefused) return json(422, { error: e.message });
    return json(502, { error: "The payment provider could not be reached. Nothing was charged." });
  }
  const rec = await deps.adminRpc("set_checkout_provider_ref", { p_checkout_id: c.id, p_method_code: c.method, p_ref: started.providerRef });
  if (rec.error) return json(500, { error: "The payment could not be recorded. Do not pay; try again." });
  return json(200, started.redirectUrl ? { mode: "redirect", url: started.redirectUrl } : { mode: "push", message: "Approve the payment in the prompt on your phone." });
}

/** Asks the provider and records a verified result. Returns the database's resulting status (or "pending" when the provider is still waiting). */
async function verify(checkoutId: string, deps: PaymentsDeps): Promise<{ status: string; orderId: string | null } | { error: number }> {
  const info = await deps.adminRpc("checkout_for_provider", { p_checkout_id: checkoutId });
  const ck = info.data as { methodCode?: string; status?: string; amount?: number; currency?: string; providerRef?: string | null; orderId?: string | null } | null;
  if (info.error || !ck) return { error: 500 };
  if (ck.status !== "created" && ck.status !== "pending") return { status: String(ck.status), orderId: ck.orderId ?? null };   // already settled: the database is the truth
  const method = String(ck.methodCode);
  const adapter = own(deps.adapters, method) ? deps.adapters[method] : undefined;
  if (!adapter) return { error: 501 };
  if (!ck.providerRef) return { status: String(ck.status), orderId: null };      // not started at the provider yet

  const t = deps.now(), last = lastQuery.get(checkoutId) ?? 0;
  if (t - last < MIN_QUERY_GAP_MS) return { status: String(ck.status), orderId: null };   // no provider hammering
  lastQuery.set(checkoutId, t);

  let r: ProviderResult;
  try { r = await adapter.query({ checkoutId, providerRef: ck.providerRef, amount: Number(ck.amount) }); } catch { return { status: String(ck.status), orderId: null }; }
  if (r.kind === "pending") return { status: "pending", orderId: null };
  // A success must be for the expected currency; anything else is handed to the database as a mismatch (it parks the checkout for review).
  const amount = r.kind === "succeeded" ? (r.currency !== null && r.currency !== (ck.currency ?? "USD") ? 0 : r.amount) : r.amount;
  const fin = await deps.adminRpc("finalize_customer_checkout", {
    p_checkout_id: checkoutId, p_method_code: method, p_provider_event_id: r.eventId, p_kind: r.kind, p_amount: amount, p_provider_ref: r.providerRef ?? ck.providerRef, p_payload_hash: null, p_allow_test: false,
  });
  if (fin.error) return { error: fin.error.code === "22023" || fin.error.code === "42501" ? 422 : 500 };
  const d = (fin.data ?? {}) as Json;
  return { status: String(d.status ?? "pending"), orderId: (d.orderId as string | null) ?? null };
}

async function status(req: Request, deps: PaymentsDeps): Promise<Response> {
  const c = await customerCheckout(req, deps);
  if (!c.ok) return c.res;
  const r = await verify(c.id, deps);
  if ("error" in r) return json(r.error, { error: r.error === 501 ? "This payment method has no verified provider integration" : "Could not check the payment" });
  return json(200, { status: r.status, orderId: r.orderId });
}

async function callback(req: Request, url: URL, method: string, deps: PaymentsDeps): Promise<Response> {
  if (!own(deps.adapters, method)) return json(501, { error: "This payment method has no verified provider integration" });
  const id = url.searchParams.get("c") ?? "";
  if (!UUID.test(id)) return json(400, { error: "Malformed callback" });
  // The body (and any query value other than the checkout id) is deliberately NOT read: it proves nothing. EFZ asks the provider itself.
  const r = await verify(id, deps);
  if ("error" in r) return json(r.error === 501 ? 501 : 200, { received: true });     // the provider must get a 200 for a valid callback address
  return json(200, { received: true });
}
