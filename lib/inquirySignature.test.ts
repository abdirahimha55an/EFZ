// Trusted client address, signing and the route logic for public inquiries. Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import { clientProof, trustedClientIp, verifyClientProof, SIGNATURE_MAX_AGE_SECONDS } from "./inquirySignature.ts";
import { handleInquiry, MAX_BODY_BYTES } from "./inquiryRoute.ts";

const SECRET = "s".repeat(40);
const KEY = "11111111-1111-4111-8111-111111111111";
const H = (o: Record<string, string>) => new Headers(o);
const NOW = 1_800_000_000_000;

test("the trusted address comes from platform headers, never from x-forwarded-for", () => {
  assert.equal(trustedClientIp(H({ "x-vercel-forwarded-for": "203.0.113.9" })), "203.0.113.9");
  assert.equal(trustedClientIp(H({ "x-real-ip": "2001:DB8::1" })), "2001:db8::1");
  assert.equal(trustedClientIp(H({ "x-forwarded-for": "1.2.3.4" })), null);
  assert.equal(trustedClientIp(H({ "x-real-ip": "not-an-ip" })), null);
  assert.equal(trustedClientIp(H({})), null);
});

test("a proof verifies, and any change to address, key, secret or time breaks it", () => {
  const p = clientProof({ secret: SECRET, ip: "203.0.113.9", submissionKey: KEY, nowMs: NOW })!;
  assert.ok(verifyClientProof(p, KEY, SECRET, NOW));
  assert.ok(!verifyClientProof({ ...p, _ip: "203.0.113.10" }, KEY, SECRET, NOW));
  assert.ok(!verifyClientProof(p, KEY.replace("1", "2"), SECRET, NOW));
  assert.ok(!verifyClientProof(p, KEY, "t".repeat(40), NOW));
  assert.ok(!verifyClientProof(p, KEY, SECRET, NOW + (SIGNATURE_MAX_AGE_SECONDS + 5) * 1000), "expired");
  assert.ok(!verifyClientProof(p, KEY, SECRET, NOW - 120_000), "from the future");
  assert.ok(!verifyClientProof({ ...p, _sig: "" }, KEY, SECRET, NOW));
});

test("no proof without a long secret, an address and a submission key", () => {
  assert.equal(clientProof({ secret: undefined, ip: "1.2.3.4", submissionKey: KEY }), null);
  assert.equal(clientProof({ secret: "short", ip: "1.2.3.4", submissionKey: KEY }), null);
  assert.equal(clientProof({ secret: SECRET, ip: null, submissionKey: KEY }), null);
  assert.equal(clientProof({ secret: SECRET, ip: "1.2.3.4", submissionKey: null }), null);
});

test("route: forwards a signed payload and discards proof fields sent by the browser", async () => {
  let sent: Record<string, unknown> = {};
  const rpc = async (p: Record<string, unknown>) => ((sent = p), { data: "abc", error: null });
  const body = JSON.stringify({ kind: "contact", submissionKey: KEY, _ip: "9.9.9.9", _sig: "forged", _ts: 1 });
  const r = await handleInquiry(body, H({ "x-vercel-forwarded-for": "203.0.113.9" }), { rpc, secret: SECRET, nowMs: NOW });
  assert.deepEqual(r, { status: 200, body: { id: "abc" } });
  assert.equal(sent._ip, "203.0.113.9");
  assert.ok(verifyClientProof(sent as never, KEY, SECRET, NOW));
});

test("route: with no secret or no trusted address it forwards unsigned (database treats it as unverified)", async () => {
  let sent: Record<string, unknown> = {};
  const rpc = async (p: Record<string, unknown>) => ((sent = p), { data: "abc", error: null });
  const body = JSON.stringify({ kind: "contact", submissionKey: KEY, _sig: "forged" });
  await handleInquiry(body, H({ "x-forwarded-for": "1.2.3.4" }), { rpc, secret: SECRET });
  assert.ok(!("_sig" in sent) && !("_ip" in sent));
  await handleInquiry(body, H({ "x-real-ip": "1.2.3.4" }), { rpc, secret: undefined });
  assert.ok(!("_sig" in sent));
});

test("route: bad bodies and database errors map to clean responses", async () => {
  const ok = { rpc: async () => ({ data: null, error: { message: "Too many messages", code: "WR429" } }), secret: SECRET };
  assert.equal((await handleInquiry("{nope", H({}), ok)).status, 400);
  assert.equal((await handleInquiry("[1]", H({}), ok)).status, 400);
  assert.equal((await handleInquiry("x".repeat(MAX_BODY_BYTES + 1), H({}), ok)).status, 413);
  const r = await handleInquiry("{}", H({}), ok);
  assert.deepEqual(r, { status: 400, body: { message: "Too many messages", code: "WR429" } });
});
