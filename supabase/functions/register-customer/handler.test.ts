// Unit tests for the registration handler with mocked dependencies. Run: npm run test:registration
// (Node's built-in test runner; no framework). The database side is covered by
// supabase/checks/21_customer_accounts_checks.sql and the integration test next to this file.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { handleRegistration, type RegistrationDeps } from "./handler.ts";

type Call = { fn: string; args: Record<string, unknown> };

function harness(over: Partial<{ checkVerdict: string; checkError: { code: string }; createError: { status?: number; code?: string; message?: string }; regError: { code: string } }> = {}) {
  const calls: Call[] = [], created: unknown[] = [], deleted: string[] = [];
  const deps: RegistrationDeps = {
    rpc: async (fn, args) => {
      calls.push({ fn, args });
      if (fn === "customer_registration_check") return over.checkError ? { data: null, error: over.checkError } : { data: [{ verdict: over.checkVerdict ?? "ok", phone_canonical: "+252611111111" }], error: null };
      if (fn === "register_customer_account") return over.regError ? { data: null, error: over.regError } : { data: "00000000-0000-4000-8000-000000000001", error: null };
      return { data: null, error: { message: "unexpected rpc " + fn } };
    },
    createUser: async (attrs) => { created.push(attrs); return over.createError ? { data: { user: null }, error: over.createError } : { data: { user: { id: "11111111-1111-4111-8111-111111111111" } }, error: null }; },
    deleteUser: async (id) => { deleted.push(id); },
    sha256: async (s) => createHash("sha256").update(s).digest("hex"),
    hintSalt: "test-salt",
  };
  return { deps, calls, created, deleted };
}
const valid = { email: "Buyer@Example.com ", password: "correct horse battery", fullName: " Amina Buyer ", phone: "061 234 5678", organization: "Club X" };
const post = (body: unknown, headers: Record<string, string> = {}, method = "POST") =>
  new Request("https://f.example/register-customer", { method, headers: { "content-type": "application/json", "x-forwarded-for": "203.0.113.9, 10.0.0.1", ...headers }, body: method === "POST" ? (typeof body === "string" ? body : JSON.stringify(body)) : undefined });
const PENDING_BODY = { status: "pending_approval", message: "Your registration was received. EFZ will review it and contact you." };

test("success: auth user created as a marked customer, pending account created, 202 with a fixed body", async () => {
  const h = harness();
  const res = await handleRegistration(post(valid), h.deps);
  assert.equal(res.status, 202);
  assert.deepEqual(await res.json(), PENDING_BODY);
  assert.equal(h.created.length, 1);
  const c = h.created[0] as Record<string, unknown>;
  assert.equal(c.email, "buyer@example.com");
  assert.deepEqual(c.app_metadata, { efz_kind: "customer" });
  assert.equal(c.email_confirm, true);
  assert.deepEqual(h.calls.map((x) => x.fn), ["customer_registration_check", "register_customer_account"]);
  assert.deepEqual(h.deleted, []);
});

test("email verification switch: off by default (confirmed user); on = created UNCONFIRMED so sign-in needs the emailed code", async () => {
  const off = harness();
  await handleRegistration(post(valid), off.deps);
  assert.equal((off.created[0] as Record<string, unknown>).email_confirm, true);
  const on = harness();
  on.deps.requireEmailVerification = true;
  const res = await handleRegistration(post(valid), on.deps);
  assert.equal(res.status, 202);
  assert.equal((on.created[0] as Record<string, unknown>).email_confirm, false);
  assert.deepEqual((on.created[0] as Record<string, unknown>).app_metadata, { efz_kind: "customer" }, "still marked as a customer");
  assert.deepEqual(await res.json(), PENDING_BODY, "the response does not reveal which mode is active");
});

test("the password reaches only the Admin API: never a database call, never the response", async () => {
  const h = harness();
  const res = await handleRegistration(post(valid), h.deps);
  assert.ok(!JSON.stringify(h.calls).includes(valid.password));
  assert.ok(!(await res.text()).includes(valid.password));
});

test("the client address is only used as a salted hash (32 hex chars), never raw", async () => {
  const h = harness();
  await handleRegistration(post(valid), h.deps);
  const hint = h.calls[0].args.p_client_hint as string;
  assert.match(hint, /^[0-9a-f]{32}$/);
  assert.ok(!JSON.stringify(h.calls).includes("203.0.113.9"));
  assert.equal(hint, createHash("sha256").update("test-salt:203.0.113.9").digest("hex").slice(0, 32));
});

test("a staff email or an already registered email creates nothing and returns the IDENTICAL success response", async () => {
  const ok = harness();
  const okRes = await handleRegistration(post(valid), ok.deps);
  for (const verdict of ["reserved", "duplicate"]) {
    const h = harness({ checkVerdict: verdict });
    const res = await handleRegistration(post(valid), h.deps);
    assert.equal(res.status, okRes.status);
    assert.equal(await res.text(), await okRes.clone().text());
    assert.equal(h.created.length, 0, `${verdict}: no auth user`);
    assert.deepEqual(h.calls.map((x) => x.fn), ["customer_registration_check"], `${verdict}: nothing registered`);
  }
});

test("an email that exists in Auth (race) also looks like success", async () => {
  const h = harness({ createError: { status: 422, code: "email_exists", message: "A user with this email address has already been registered" } });
  const res = await handleRegistration(post(valid), h.deps);
  assert.equal(res.status, 202);
  assert.deepEqual(await res.json(), PENDING_BODY);
  assert.deepEqual(h.calls.map((x) => x.fn), ["customer_registration_check"]);
});

test("rate limit from the database becomes 429, before any auth user exists", async () => {
  const h = harness({ checkError: { code: "WR429" } });
  const res = await handleRegistration(post(valid), h.deps);
  assert.equal(res.status, 429);
  assert.equal(h.created.length, 0);
});

test("an invalid phone/email from the database becomes a generic 422", async () => {
  const h = harness({ checkError: { code: "WR422" } });
  const res = await handleRegistration(post(valid), h.deps);
  assert.equal(res.status, 422);
  assert.ok(!(await res.text()).includes("061 234 5678"));
});

test("if the account cannot be created after the auth user exists, the auth user is deleted (no orphan)", async () => {
  const h = harness({ regError: { code: "42501" } });
  const res = await handleRegistration(post(valid), h.deps);
  assert.equal(res.status, 500);
  assert.deepEqual(h.deleted, ["11111111-1111-4111-8111-111111111111"]);
  const h2 = harness({ regError: { code: "WR429" } });
  assert.equal((await handleRegistration(post(valid), h2.deps)).status, 429);
  assert.equal(h2.deleted.length, 1);
});

test("other Admin API failures are a generic 502 and register nothing", async () => {
  const h = harness({ createError: { status: 500, message: "boom with details" } });
  const res = await handleRegistration(post(valid), h.deps);
  assert.equal(res.status, 502);
  assert.ok(!(await res.text()).includes("boom"));
  assert.deepEqual(h.calls.map((x) => x.fn), ["customer_registration_check"]);
});

test("input validation: 422 with a generic message and nothing is called", async () => {
  const bads: Record<string, unknown>[] = [
    { ...valid, email: "not-an-email" }, { ...valid, email: "a b@c.co" }, { ...valid, password: "short" }, { ...valid, password: "x".repeat(73) },
    { ...valid, fullName: "  " }, { ...valid, fullName: "n".repeat(201) }, { ...valid, phone: "" }, { ...valid, organization: "o".repeat(201) },
    { ...valid, organization: 5 }, { ...valid, email: 7 }, {},
  ];
  for (const b of bads) {
    const h = harness();
    const res = await handleRegistration(post(b), h.deps);
    assert.equal(res.status, 422, JSON.stringify(b).slice(0, 60));
    assert.equal(h.calls.length + h.created.length, 0);
    const text = await res.text();
    assert.ok(!text.includes("short") && !text.includes("not-an-email"));
  }
});

test("protocol guards: only POST, only JSON, bounded body, JSON object required", async () => {
  const h = harness();
  assert.equal((await handleRegistration(post(valid, {}, "GET"), h.deps)).status, 405);
  assert.equal((await handleRegistration(post(valid, { "content-type": "text/plain" }), h.deps)).status, 415);
  assert.equal((await handleRegistration(post("x".repeat(5000)), h.deps)).status, 413);
  assert.equal((await handleRegistration(post("{not json"), h.deps)).status, 422);
  assert.equal((await handleRegistration(post("[1,2]"), h.deps)).status, 422);
  assert.equal(h.calls.length + h.created.length, 0);
});

test("no client address available: still works, hint is null", async () => {
  const h = harness();
  const res = await handleRegistration(new Request("https://f.example/x", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(valid) }), h.deps);
  assert.equal(res.status, 202);
  assert.equal(h.calls[0].args.p_client_hint, null);
});

test("responses are never cacheable and never carry ids, customers or staff data", async () => {
  const h = harness();
  const res = await handleRegistration(post(valid), h.deps);
  assert.equal(res.headers.get("cache-control"), "no-store");
  const text = await res.text();
  assert.ok(!/[0-9a-f]{8}-[0-9a-f]{4}-/.test(text) && !/cust-|profile|staff|u-/.test(text));
});
