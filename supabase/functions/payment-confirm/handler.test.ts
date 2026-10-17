// Unit tests for the provider confirmation handler with a FAKE adapter (no real provider exists). Run: npm run test:payments
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import { handlePaymentConfirmation, VerificationError, type PaymentDeps, type ProviderAdapter } from "./handler.ts";

const CK = "11111111-1111-4111-8111-111111111111";
// A fake provider that signs its callback with HMAC-SHA256 (stands in for a real provider's authentication).
const SECRET = "test-secret";
const fake: ProviderAdapter = {
  async verify(req, raw) {
    const sig = req.headers.get("x-sig") ?? "";
    const good = createHmac("sha256", SECRET).update(raw).digest("hex");
    if (sig.length !== good.length || !timingSafeEqual(Buffer.from(sig), Buffer.from(good))) throw new VerificationError("bad signature");
    const b = JSON.parse(raw);
    return { checkoutId: b.checkout, methodCode: "fake", providerEventId: b.event, kind: b.kind, amount: b.amount ?? null, providerRef: b.ref ?? null };
  },
};
function harness(over: { rpcError?: { code?: string; message?: string }; rpcData?: unknown } = {}) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const deps: PaymentDeps = {
    adapters: { fake },
    rpc: async (fn, args) => { calls.push({ fn, args }); return over.rpcError ? { data: null, error: over.rpcError } : { data: over.rpcData ?? { status: "paid", orderId: "ORD-1", duplicate: false }, error: null }; },
    sha256: async (s) => createHash("sha256").update(s).digest("hex"),
  };
  return { deps, calls };
}
const signed = (body: object, path = "/payment-confirm/fake", over: Record<string, string> = {}) => {
  const raw = JSON.stringify(body);
  return new Request("https://f.example" + path, { method: "POST", headers: { "x-sig": createHmac("sha256", SECRET).update(raw).digest("hex"), ...over }, body: raw });
};
const ev = { checkout: CK, event: "evt-1", kind: "succeeded", amount: 30, ref: "PROV-1" };

test("a verified success calls the database function exactly once, with the hash of the raw body and never allow_test", async () => {
  const h = harness();
  const res = await handlePaymentConfirmation(signed(ev), h.deps);
  assert.equal(res.status, 200); assert.deepEqual(await res.json(), { status: "paid", orderId: "ORD-1", duplicate: false });
  assert.equal(h.calls.length, 1); assert.equal(h.calls[0].fn, "finalize_customer_checkout");
  assert.deepEqual(h.calls[0].args, { p_checkout_id: CK, p_method_code: "fake", p_provider_event_id: "evt-1", p_kind: "succeeded", p_amount: 30, p_provider_ref: "PROV-1", p_payload_hash: createHash("sha256").update(JSON.stringify(ev)).digest("hex"), p_allow_test: false });
});
test("a method with no adapter is refused with 501 and the database is never called (no provider is integrated)", async () => {
  const h = harness();
  for (const p of ["/payment-confirm/evc", "/payment-confirm/", "/payment-confirm/constructor", "/payment-confirm/__proto__", "/payment-confirm/stg_test"]) {
    const res = await handlePaymentConfirmation(signed(ev, p), h.deps); assert.equal(res.status, 501, p);
  }
  assert.equal(h.calls.length, 0);
});
test("a callback that fails verification is 401 and the database is never called", async () => {
  const h = harness();
  const bad = new Request("https://f.example/payment-confirm/fake", { method: "POST", headers: { "x-sig": "00".repeat(32) }, body: JSON.stringify(ev) });
  assert.equal((await handlePaymentConfirmation(bad, h.deps)).status, 401);
  const none = new Request("https://f.example/payment-confirm/fake", { method: "POST", body: JSON.stringify(ev) });
  assert.equal((await handlePaymentConfirmation(none, h.deps)).status, 401);
  const tampered = signed(ev); const body = JSON.stringify({ ...ev, amount: 1 });
  assert.equal((await handlePaymentConfirmation(new Request("https://f.example/payment-confirm/fake", { method: "POST", headers: { "x-sig": tampered.headers.get("x-sig") as string }, body }), h.deps)).status, 401);
  assert.equal(h.calls.length, 0);
});
test("only POST; oversized bodies are refused", async () => {
  const h = harness();
  assert.equal((await handlePaymentConfirmation(new Request("https://f.example/payment-confirm/fake", { method: "GET" }), h.deps)).status, 405);
  assert.equal((await handlePaymentConfirmation(new Request("https://f.example/payment-confirm/fake", { method: "POST", body: "x".repeat(70000) }), h.deps)).status, 413);
  assert.equal(h.calls.length, 0);
});
test("malformed events are 400: a method mismatch, a bad checkout id, an unknown kind, a success without an amount", async () => {
  const h = harness();
  const mismatch: ProviderAdapter = { verify: async () => ({ checkoutId: CK, methodCode: "other", providerEventId: "e", kind: "succeeded", amount: 1, providerRef: null }) };
  assert.equal((await handlePaymentConfirmation(signed(ev), { ...h.deps, adapters: { fake: mismatch } })).status, 400);
  for (const bad of [{ ...ev, checkout: "not-a-uuid" }, { ...ev, kind: "refunded" }, { ...ev, amount: null }, { ...ev, amount: -5 }, { ...ev, event: "" }]) assert.equal((await handlePaymentConfirmation(signed(bad), h.deps)).status, 400, JSON.stringify(bad));
  assert.equal(h.calls.length, 0);
});
test("duplicates are reported as such; a database refusal is 422; any other database problem is a generic 500", async () => {
  assert.deepEqual(await (await handlePaymentConfirmation(signed(ev), harness({ rpcData: { duplicate: true, status: "paid", orderId: "ORD-1" } }).deps)).json(), { status: "paid", orderId: "ORD-1", duplicate: true });
  assert.equal((await handlePaymentConfirmation(signed(ev), harness({ rpcError: { code: "22023", message: "x" } }).deps)).status, 422);
  const r = await handlePaymentConfirmation(signed(ev), harness({ rpcError: { code: "XX000", message: "secret internal detail" } }).deps);
  assert.equal(r.status, 500); assert.ok(!JSON.stringify(await r.json()).includes("secret internal detail"));
});
test("an adapter crash is a generic 500, not a leak", async () => {
  const boom: ProviderAdapter = { verify: async () => { throw new Error("provider api key abc123 rejected"); } };
  const r = await handlePaymentConfirmation(signed(ev), { ...harness().deps, adapters: { fake: boom } });
  assert.equal(r.status, 500); assert.ok(!JSON.stringify(await r.json()).includes("abc123"));
});
