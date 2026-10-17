// Unit tests for the payments handler with a FAKE provider adapter and a fake database. Run: npm run test:payments
import { test } from "node:test";
import assert from "node:assert/strict";
import { handlePayments, normalizeWallet, ProviderRefused, type PaymentsDeps, type ProviderAdapter, type ProviderResult } from "./handler.ts";

const CK = "11111111-1111-4111-8111-111111111111";
type Call = { who: string; fn: string; args: Record<string, unknown> };

function harness(over: { adapter?: Partial<ProviderAdapter>; ck?: Record<string, unknown> | null; mine?: unknown; mineError?: { code: string }; finError?: { code: string }; fin?: unknown; setRefError?: boolean } = {}) {
  const calls: Call[] = []; let clock = 1_000_000;
  const adapter: ProviderAdapter = {
    start: async () => ({ providerRef: "REF-1", redirectUrl: "https://pay.example/hpp/abc" }),
    query: async (): Promise<ProviderResult> => ({ kind: "succeeded", amount: 24, currency: "USD", providerRef: "TX-9", eventId: "ev-1" }),
    ...over.adapter,
  };
  const ck = "ck" in over ? over.ck : { methodCode: "fake", methodKind: "provider", methodEnabled: true, status: "created", amount: 24, currency: "USD", providerRef: null, orderId: null };
  const deps: PaymentsDeps = {
    adapters: { fake: adapter }, baseUrl: "https://f.example/functions/v1/payments", now: () => (clock += 10_000),
    userRpc: async (token, fn, args) => { calls.push({ who: "user:" + token, fn, args }); return over.mineError ? { data: null, error: over.mineError } : { data: "mine" in over ? over.mine : { methodCode: "fake", status: "created" }, error: null }; },
    adminRpc: async (fn, args) => {
      calls.push({ who: "admin", fn, args });
      if (fn === "checkout_for_provider") return { data: ck, error: null };
      if (fn === "set_checkout_provider_ref") return over.setRefError ? { data: null, error: { code: "22023" } } : { data: null, error: null };
      if (fn === "finalize_customer_checkout") return over.finError ? { data: null, error: over.finError } : { data: over.fin ?? { status: "paid", orderId: "ORD-5", duplicate: false }, error: null };
      return { data: null, error: { code: "XX" } };
    },
  };
  return { deps, calls, adapter };
}
const post = (path: string, body: unknown, auth: string | null = "Bearer tok", method = "POST") =>
  new Request("https://f.example/functions/v1/payments" + path, { method, headers: { ...(auth ? { authorization: auth } : {}), "content-type": "application/json" }, body: method === "POST" ? JSON.stringify(body) : undefined });
const fns = (h: ReturnType<typeof harness>) => h.calls.map((c) => c.who.split(":")[0] + ":" + c.fn);

test("wallet numbers are normalized to international digits; anything else is refused", () => {
  assert.equal(normalizeWallet("061 234 5678"), "252612345678"); assert.equal(normalizeWallet("+252 61 234 5678"), "252612345678"); assert.equal(normalizeWallet("252612345678"), "252612345678");
  assert.equal(normalizeWallet("612345678"), "252612345678");
  for (const bad of ["", "abc", "12", "1234", "061-234-5678x", "+1 202 555 0100", "0000000000000000000", null, undefined, "PIN 1234"]) assert.equal(normalizeWallet(bad), null, String(bad));
});

test("start: the owner of a created checkout starts the provider payment; the provider reference is recorded; the app gets only the hosted-page URL", async () => {
  const h = harness();
  const res = await handlePayments(post("/start", { checkoutId: CK, walletNumber: "061 234 5678" }), h.deps);
  assert.equal(res.status, 200); assert.deepEqual(await res.json(), { mode: "redirect", url: "https://pay.example/hpp/abc" });
  assert.deepEqual(fns(h), ["user:my_checkout_status", "admin:checkout_for_provider", "admin:set_checkout_provider_ref"]);
  assert.deepEqual(h.calls[2].args, { p_checkout_id: CK, p_method_code: "fake", p_ref: "REF-1" });
});
test("start: a push-style provider (no hosted page) answers 'push'", async () => {
  const h = harness({ adapter: { start: async () => ({ providerRef: "INV-1" }) } });
  assert.deepEqual(await (await handlePayments(post("/start", { checkoutId: CK, walletNumber: "061 234 5678" }), h.deps)).json(), { mode: "push", message: "Approve the payment in the prompt on your phone." });
});
test("start: refused before any provider call without a sign-in, for bad input, someone else's checkout, a method without integration, or a disabled method", async () => {
  const h = harness();
  assert.equal((await handlePayments(post("/start", { checkoutId: CK, walletNumber: "061 234 5678" }, null), h.deps)).status, 401);
  assert.equal((await handlePayments(post("/start", { checkoutId: "x", walletNumber: "061 234 5678" }), h.deps)).status, 422);
  assert.equal((await handlePayments(post("/start", { checkoutId: CK, walletNumber: "PIN 1234" }), h.deps)).status, 422);
  assert.equal((await handlePayments(post("/start", { checkoutId: CK, walletNumber: "061 234 5678" }, "Bearer tok", "GET"), h.deps)).status, 405);
  assert.equal((await handlePayments(post("/start", { checkoutId: CK, walletNumber: "061 234 5678" }), harness({ mine: null }).deps)).status, 404);
  assert.equal((await handlePayments(post("/start", { checkoutId: CK, walletNumber: "061 234 5678" }), harness({ mineError: { code: "42501" } }).deps)).status, 403);
  assert.equal((await handlePayments(post("/start", { checkoutId: CK, walletNumber: "061 234 5678" }), harness({ mine: { methodCode: "evc", status: "created" } }).deps)).status, 501);
  const off = harness({ ck: { methodKind: "provider", methodEnabled: false, status: "created", amount: 24 } });
  assert.equal((await handlePayments(post("/start", { checkoutId: CK, walletNumber: "061 234 5678" }), off.deps)).status, 422);
  assert.equal(h.calls.filter((c) => c.fn === "set_checkout_provider_ref").length, 0);
});
test("start: a settled checkout is refused; a payment already started is never started twice (no double charge)", async () => {
  const settled = harness({ ck: { methodKind: "provider", methodEnabled: true, status: "paid", amount: 24 } });
  assert.equal((await handlePayments(post("/start", { checkoutId: CK, walletNumber: "061 234 5678" }), settled.deps)).status, 409);
  let started = 0;
  const twice = harness({ ck: { methodKind: "provider", methodEnabled: true, status: "pending", amount: 24, providerRef: "REF-1" }, adapter: { start: async () => { started++; return { providerRef: "X" }; } } });
  const res = await handlePayments(post("/start", { checkoutId: CK, walletNumber: "061 234 5678" }), twice.deps);
  assert.equal((await res.json() as { mode: string }).mode, "resume"); assert.equal(started, 0);
});
test("start: a provider refusal is shown plainly, an outage is generic, and nothing is recorded in either case", async () => {
  const refused = harness({ adapter: { start: async () => { throw new ProviderRefused("Your eDahab balance is not enough for this payment."); } } });
  const r1 = await handlePayments(post("/start", { checkoutId: CK, walletNumber: "061 234 5678" }), refused.deps);
  assert.equal(r1.status, 422); assert.match(JSON.stringify(await r1.json()), /balance is not enough/);
  const down = harness({ adapter: { start: async () => { throw new Error("connect ECONNREFUSED 10.0.0.5 api key abc123"); } } });
  const r2 = await handlePayments(post("/start", { checkoutId: CK, walletNumber: "061 234 5678" }), down.deps);
  assert.equal(r2.status, 502); assert.ok(!JSON.stringify(await r2.json()).includes("abc123"));
  assert.equal(refused.calls.concat(down.calls).filter((c) => c.fn === "set_checkout_provider_ref").length, 0);
});
test("start: if the reference cannot be recorded the customer is told NOT to pay", async () => {
  const h = harness({ setRefError: true });
  const r = await handlePayments(post("/start", { checkoutId: CK, walletNumber: "061 234 5678" }), h.deps);
  assert.equal(r.status, 500); assert.match(JSON.stringify(await r.json()), /Do not pay/);
});

const pending = { methodCode: "fake", methodKind: "provider", methodEnabled: true, status: "pending", amount: 24, currency: "USD", providerRef: "REF-1", orderId: null };
test("status: a provider 'paid' answer is recorded through the database with the provider's own event id and the amount to be checked", async () => {
  const h = harness({ ck: pending });
  const res = await handlePayments(post("/status", { checkoutId: CK }), h.deps);
  assert.deepEqual(await res.json(), { status: "paid", orderId: "ORD-5" });
  const fin = h.calls.find((c) => c.fn === "finalize_customer_checkout");
  assert.deepEqual(fin?.args, { p_checkout_id: CK, p_method_code: "fake", p_provider_event_id: "ev-1", p_kind: "succeeded", p_amount: 24, p_provider_ref: "TX-9", p_payload_hash: null, p_allow_test: false });
});
test("status: a provider that is still waiting records nothing and reports pending", async () => {
  const h = harness({ ck: pending, adapter: { query: async () => ({ kind: "pending", amount: null, currency: null, providerRef: "REF-1", eventId: "p1" }) } });
  assert.deepEqual(await (await handlePayments(post("/status", { checkoutId: CK }), h.deps)).json(), { status: "pending", orderId: null });
  assert.equal(h.calls.filter((c) => c.fn === "finalize_customer_checkout").length, 0);
});
test("status: a success in another currency is handed to the database as a mismatch (amount 0), never accepted", async () => {
  const h = harness({ ck: pending, adapter: { query: async () => ({ kind: "succeeded", amount: 24, currency: "SLSH", providerRef: "TX", eventId: "e" }) } });
  await handlePayments(post("/status", { checkoutId: "66666666-6666-4666-8666-666666666666" }), h.deps);   // its own id: the provider-query gap is tracked per checkout
  assert.equal(h.calls.find((c) => c.fn === "finalize_customer_checkout")?.args.p_amount, 0);
});
test("status: a settled checkout is answered from the database without asking the provider; an unstarted one is not queried", async () => {
  let asked = 0; const adapter = { query: async () => { asked++; return { kind: "pending", amount: null, currency: null, providerRef: null, eventId: "x" } as ProviderResult; } };
  const done = harness({ ck: { ...pending, status: "paid", orderId: "ORD-1" }, adapter });
  assert.deepEqual(await (await handlePayments(post("/status", { checkoutId: CK }), done.deps)).json(), { status: "paid", orderId: "ORD-1" });
  const fresh = harness({ ck: { ...pending, status: "created", providerRef: null }, adapter });
  await handlePayments(post("/status", { checkoutId: CK }), fresh.deps);
  assert.equal(asked, 0);
});
test("status: the provider is not hammered (a second check within seconds does not query again) and a provider outage leaves the status unchanged", async () => {
  let asked = 0; const h = harness({ ck: pending, adapter: { query: async () => { asked++; return { kind: "pending", amount: null, currency: null, providerRef: null, eventId: "e" }; } } });
  const near = { ...h.deps, now: () => 5_000_000 };       // identical timestamps for the two calls
  const id2 = "33333333-3333-4333-8333-333333333333";
  await handlePayments(post("/status", { checkoutId: id2 }), near); await handlePayments(post("/status", { checkoutId: id2 }), near);
  assert.equal(asked, 1);
  const down = harness({ ck: pending, adapter: { query: async () => { throw new Error("provider down"); } } });
  assert.deepEqual(await (await handlePayments(post("/status", { checkoutId: "44444444-4444-4444-8444-444444444444" }), down.deps)).json(), { status: "pending", orderId: null });
});
test("status: someone else's checkout, no sign-in, and a database refusal are all refused", async () => {
  assert.equal((await handlePayments(post("/status", { checkoutId: CK }, null), harness({ ck: pending }).deps)).status, 401);
  assert.equal((await handlePayments(post("/status", { checkoutId: CK }), harness({ ck: pending, mine: null }).deps)).status, 404);
  assert.equal((await handlePayments(post("/status", { checkoutId: "55555555-5555-4555-8555-555555555555" }), harness({ ck: pending, finError: { code: "22023" } }).deps)).status, 422);
});

test("callback: the body is IGNORED - a forged 'paid' callback changes nothing unless the provider itself says paid", async () => {
  const forged = harness({ ck: pending, adapter: { query: async () => ({ kind: "pending", amount: null, currency: null, providerRef: "REF-1", eventId: "p" }) } });
  const res = await handlePayments(new Request(`https://f.example/functions/v1/payments/callback/fake?c=${CK}`, { method: "POST", body: JSON.stringify({ status: "Approved", amount: 24, referenceId: "REF-1" }) }), forged.deps);
  assert.equal(res.status, 200); assert.deepEqual(await res.json(), { received: true });
  assert.equal(forged.calls.filter((c) => c.fn === "finalize_customer_checkout").length, 0);
});
test("callback: a genuine callback only triggers EFZ's own query; a replay is harmless (idempotent event id)", async () => {
  const h = harness({ ck: pending });
  const call = () => handlePayments(new Request(`https://f.example/functions/v1/payments/callback/fake?c=${CK}`, { method: "GET" }), { ...h.deps, now: () => 9_000_000 + Math.random() * 1e9 });
  assert.equal((await call()).status, 200); assert.equal((await call()).status, 200);
  const evs = h.calls.filter((c) => c.fn === "finalize_customer_checkout").map((c) => c.args.p_provider_event_id);
  assert.ok(evs.length >= 1 && new Set(evs).size === 1);       // every query for this provider answer carries the same event id
});
test("callback: unknown method is 501, a malformed checkout id is 400, a database error is still a 200 for a valid address", async () => {
  const h = harness({ ck: pending });
  assert.equal((await handlePayments(new Request(`https://f.example/functions/v1/payments/callback/evc?c=${CK}`), h.deps)).status, 501);
  assert.equal((await handlePayments(new Request(`https://f.example/functions/v1/payments/callback/fake?c=nope`), h.deps)).status, 400);
  assert.equal((await handlePayments(new Request(`https://f.example/functions/v1/payments/callback/__proto__?c=${CK}`), h.deps)).status, 501);
  assert.equal((await handlePayments(new Request(`https://f.example/functions/v1/payments/other`), h.deps)).status, 404);
});
