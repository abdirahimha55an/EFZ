// The forms' call to POST /api/inquiries. Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import { inquiryPayload, postInquiry, InquirySubmitError } from "./inquirySubmit.ts";
import { visitorFriendlyError } from "./inquiryForm.ts";

const input = { kind: "contact", name: "Amina", message: "Hello", submissionKey: "k1" } as never;
const reply = (status: number, body: unknown, raw?: string) => async () => new Response(raw ?? JSON.stringify(body), { status });

test("payload has every field the database function reads, with safe defaults", () => {
  assert.deepEqual(inquiryPayload(input), {
    kind: "contact", name: "Amina", phone: "", email: "", organization: "", businessType: "", subject: "", message: "Hello", hp: "", submissionKey: "k1",
  });
});

test("posts JSON to /api/inquiries and returns the id", async () => {
  let seen: { url: string; init: RequestInit } | undefined;
  const f = (async (url: string, init: RequestInit) => ((seen = { url, init }), new Response(JSON.stringify({ id: "abc" }), { status: 200 }))) as never;
  assert.equal(await postInquiry(input, f), "abc");
  assert.equal(seen!.url, "/api/inquiries");
  assert.equal(seen!.init.method, "POST");
  assert.equal(JSON.parse(seen!.init.body as string).submissionKey, "k1");
});

test("a rate-limit answer keeps its sentence and code, and the visitor sees that sentence", async () => {
  const sentence = "Too many messages were sent from your connection. Please try again later or contact us on WhatsApp.";
  await assert.rejects(postInquiry(input, reply(429, { message: sentence, code: "WR429" }) as never), (e: unknown) => {
    assert.ok(e instanceof InquirySubmitError);
    assert.equal(e.code, "WR429");
    assert.equal(visitorFriendlyError(e.message), sentence);
    return true;
  });
});

test("non-JSON and empty failures give a generic message, never a crash or a raw body", async () => {
  await assert.rejects(postInquiry(input, reply(502, null, "<html>Bad gateway</html>") as never), /Something went wrong/);
  await assert.rejects(postInquiry(input, reply(200, {}) as never), /Something went wrong/);
});

test("a network failure surfaces as the browser error the forms already translate", async () => {
  const f = (async () => { throw new TypeError("Failed to fetch"); }) as never;
  await assert.rejects(postInquiry(input, f), (e: unknown) => {
    assert.ok(e instanceof TypeError);
    assert.match(visitorFriendlyError((e as Error).message), /could not reach the server/);
    return true;
  });
});
