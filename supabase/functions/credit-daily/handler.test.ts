// Unit tests for the daily credit run trigger. Run: npm run test:payments
import { test } from "node:test";
import assert from "node:assert/strict";
import { handleCreditDaily, safeEqual } from "./handler.ts";

const SECRET = "s".repeat(32);
const mk = (over: { secret?: string | undefined; error?: boolean } = {}) => {
  let called = 0;
  return { calls: () => called, deps: { secret: "secret" in over ? over.secret : SECRET, run: async () => { called++; return over.error ? { data: null, error: { message: "db password is hunter2" } } : { data: { asOf: "2026-10-18", remindersSent: 3, failed: 0 }, error: null }; } } };
};
const req = (headers: Record<string, string> = {}, method = "POST") => new Request("https://f.example/credit-daily", { method, headers });

test("without a configured secret (or a short one) the function refuses to run at all (501) and calls nothing", async () => {
  for (const secret of [undefined, "", "short"]) { const h = mk({ secret }); assert.equal((await handleCreditDaily(req({ "x-cron-secret": "anything" }), h.deps)).status, 501); assert.equal(h.calls(), 0); }
});
test("a missing or wrong secret is refused (401) and the database function is never called", async () => {
  const h = mk();
  assert.equal((await handleCreditDaily(req(), h.deps)).status, 401);
  assert.equal((await handleCreditDaily(req({ "x-cron-secret": SECRET + "x" }), h.deps)).status, 401);
  assert.equal((await handleCreditDaily(req({ "x-cron-secret": SECRET.slice(0, -1) }), h.deps)).status, 401);
  assert.equal(h.calls(), 0);
});
test("only POST runs it", async () => { const h = mk(); assert.equal((await handleCreditDaily(req({ "x-cron-secret": SECRET }, "GET"), h.deps)).status, 405); assert.equal(h.calls(), 0); });
test("the right secret runs the database function once and returns only the counts", async () => {
  const h = mk(); const r = await handleCreditDaily(req({ "x-cron-secret": SECRET }), h.deps);
  assert.equal(r.status, 200); assert.deepEqual(await r.json(), { ok: true, asOf: "2026-10-18", remindersSent: 3, failed: 0 }); assert.equal(h.calls(), 1);
});
test("a database failure is reported as a plain 500 without any detail from the database", async () => {
  const h = mk({ error: true }); const r = await handleCreditDaily(req({ "x-cron-secret": SECRET }), h.deps); const text = await r.text();
  assert.equal(r.status, 500); assert.ok(!text.includes("hunter2")); assert.deepEqual(JSON.parse(text), { error: "The daily run failed" });
});
test("the constant-time comparison is correct", () => { assert.ok(safeEqual("abc", "abc")); assert.ok(!safeEqual("abc", "abd")); assert.ok(!safeEqual("abc", "abcd")); assert.ok(!safeEqual("", "a")); });
