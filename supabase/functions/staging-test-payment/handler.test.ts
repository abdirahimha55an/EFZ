// Unit tests for the Staging-only test payment handler. Run: npm run test:payments
import { test } from "node:test";
import assert from "node:assert/strict";
import { handleTestPayment, type TestPaymentDeps } from "./handler.ts";

const CK = "22222222-2222-4222-8222-222222222222";
function harness(over: { enabled?: boolean; own?: unknown; ownError?: { code: string }; finError?: { code: string } } = {}) {
  const calls: { who: string; fn: string; args: Record<string, unknown> }[] = [];
  const deps: TestPaymentDeps = {
    enabled: over.enabled ?? true,
    userRpc: async (token, fn, args) => { calls.push({ who: "user:" + token, fn, args }); return over.ownError ? { data: null, error: over.ownError } : { data: "own" in over ? over.own : { methodCode: "stg_test", amount: 30 }, error: null }; },
    adminRpc: async (fn, args) => { calls.push({ who: "admin", fn, args }); return over.finError ? { data: null, error: over.finError } : { data: { status: "paid", orderId: "ORD-9" }, error: null }; },
    newId: () => "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
  };
  return { deps, calls };
}
const req = (body: unknown, auth: string | null = "Bearer tok", method = "POST") =>
  new Request("https://f.example/staging-test-payment", { method, headers: { ...(auth ? { authorization: auth } : {}), "content-type": "application/json" }, body: method === "POST" ? JSON.stringify(body) : undefined });

test("outside Staging the function does not exist (404) and calls nothing", async () => {
  const h = harness({ enabled: false });
  assert.equal((await handleTestPayment(req({ checkoutId: CK, outcome: "succeeded" }), h.deps)).status, 404);
  assert.equal(h.calls.length, 0);
});
test("a signed-in owner of a stg_test checkout can finalize it: ownership is checked with THEIR token, then the service function is called with the test flag", async () => {
  const h = harness();
  const res = await handleTestPayment(req({ checkoutId: CK, outcome: "succeeded" }), h.deps);
  assert.equal(res.status, 200); assert.deepEqual(await res.json(), { status: "paid", orderId: "ORD-9" });
  assert.deepEqual(h.calls.map((c) => c.who + ":" + c.fn), ["user:tok:my_checkout_status", "admin:finalize_customer_checkout"]);
  assert.deepEqual(h.calls[1].args, { p_checkout_id: CK, p_method_code: "stg_test", p_provider_event_id: "stg-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", p_kind: "succeeded", p_amount: 30, p_provider_ref: "STG-aaaaaaaa-bbb", p_payload_hash: "staging-test", p_allow_test: true });
});
test("a failure outcome sends no amount", async () => {
  const h = harness(); await handleTestPayment(req({ checkoutId: CK, outcome: "failed" }), h.deps);
  assert.equal(h.calls[1].args.p_amount, null); assert.equal(h.calls[1].args.p_kind, "failed");
});
test("not signed in, not POST, bad input: refused before any call", async () => {
  const h = harness();
  assert.equal((await handleTestPayment(req({ checkoutId: CK, outcome: "succeeded" }, null), h.deps)).status, 401);
  assert.equal((await handleTestPayment(req(null, "Bearer tok", "GET"), h.deps)).status, 405);
  for (const b of [{ checkoutId: "x", outcome: "succeeded" }, { checkoutId: CK, outcome: "paid" }, {}]) assert.equal((await handleTestPayment(req(b), h.deps)).status, 422);
  assert.equal(h.calls.length, 0);
});
test("someone else's checkout (not visible to the caller) is 404; a real provider checkout is 403; a database refusal is 403", async () => {
  assert.equal((await handleTestPayment(req({ checkoutId: CK, outcome: "succeeded" }), harness({ own: null }).deps)).status, 404);
  const real = harness({ own: { methodCode: "evc", amount: 5 } });
  assert.equal((await handleTestPayment(req({ checkoutId: CK, outcome: "succeeded" }), real.deps)).status, 403);
  assert.equal(real.calls.filter((c) => c.who === "admin").length, 0);
  assert.equal((await handleTestPayment(req({ checkoutId: CK, outcome: "succeeded" }), harness({ ownError: { code: "42501" } }).deps)).status, 403);
});
