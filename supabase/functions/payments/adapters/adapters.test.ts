// Adapter tests with the PROVIDERS' PUBLISHED request/response shapes (docs.waafipay.com HPP, docs.edahab.net) and a fake network. No provider is called.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { waafiPayAdapter } from "./waafipay.ts";
import { edahabAdapter } from "./edahab.ts";
import { ProviderRefused } from "../handler.ts";

const CK = "11111111-1111-4111-8111-111111111111";
const ok = (b: unknown) => new Response(JSON.stringify(b), { status: 200 });
const sha = async (s: string) => createHash("sha256").update(s).digest("hex");

function waafi(reply: unknown, status = 200) {
  const sent: { url: string; body: any }[] = [];
  const a = waafiPayAdapter({ apiUrl: "https://api.example.test/asm", merchantUid: "M0912345", storeId: "1234567", hppKey: "KEY-SECRET-123", now: () => new Date("2026-10-17T10:00:00.123Z"), uuid: () => "req-1",
    fetchImpl: (async (url: string, init: RequestInit) => { sent.push({ url, body: JSON.parse(init.body as string) }); return status === 200 ? ok(reply) : new Response("x", { status }); }) as never });
  return { a, sent };
}
test("WaafiPay start: sends the documented HPP_PURCHASE envelope with the checkout id as reference, the wallet as subscriptionId, USD and two decimals", async () => {
  const { a, sent } = waafi({ errorCode: "0", responseCode: "2001", params: { hppUrl: "https://sandbox.waafipay.com/hpp/token/ABC", orderId: "1185941", referenceId: "OrderId_" + CK } });
  const r = await a.start({ checkoutId: CK, amount: 24, currency: "USD", walletNumber: "252612345678", callbackBase: "https://f.example/functions/v1/payments" });
  assert.deepEqual(r, { providerRef: "OrderId_" + CK, redirectUrl: "https://sandbox.waafipay.com/hpp/token/ABC" });
  const b = sent[0].body;
  assert.equal(sent[0].url, "https://api.example.test/asm");
  assert.equal(b.serviceName, "HPP_PURCHASE"); assert.equal(b.schemaVersion, "1.0"); assert.equal(b.channelName, "WEB"); assert.equal(b.timestamp, "2026-10-17 10:00:00.123");
  assert.deepEqual(Object.keys(b.serviceParams).sort(), ["hppFailureCallbackUrl", "hppKey", "hppRespDataFormat", "hppSuccessCallbackUrl", "merchantUid", "payerInfo", "paymentMethod", "storeId", "transactionInfo"]);
  assert.equal(b.serviceParams.paymentMethod, "MWALLET_ACCOUNT"); assert.equal(b.serviceParams.payerInfo.subscriptionId, "252612345678"); assert.equal(b.serviceParams.storeId, 1234567);
  assert.deepEqual(b.serviceParams.transactionInfo, { referenceId: CK, amount: 24, currency: "USD", description: "EFZ order payment" });
  assert.equal(b.serviceParams.hppSuccessCallbackUrl, `https://f.example/functions/v1/payments/callback/evc_plus?c=${CK}`);
  assert.ok(!JSON.stringify(b).match(/pin/i));
});
test("WaafiPay start: an error answer or a non-https page is refused", async () => {
  await assert.rejects(waafi({ errorCode: "9", params: {} }).a.start({ checkoutId: CK, amount: 1, currency: "USD", walletNumber: "252612345678", callbackBase: "https://x" }), ProviderRefused);
  await assert.rejects(waafi({ errorCode: "0", params: { hppUrl: "http://evil.example/x" } }).a.start({ checkoutId: CK, amount: 1, currency: "USD", walletNumber: "252612345678", callbackBase: "https://x" }), ProviderRefused);
  await assert.rejects(waafi({}, 500).a.start({ checkoutId: CK, amount: 1, currency: "USD", walletNumber: "252612345678", callbackBase: "https://x" }));
});
test("WaafiPay query: only an explicit Approved status (id 3) for the SAME reference is paid; everything else stays pending", async () => {
  const approved = { errorCode: "0", params: { status: "Approved", tranStatusDesc: "Approved", tranStatusId: "3", referenceId: "REF", tranAmount: "24.0", amount: "24.0", currency: "USD", transactionId: "126895" } };
  const q = (r: unknown) => waafi(r).a.query({ checkoutId: CK, providerRef: "REF", amount: 24 });
  assert.deepEqual(await q(approved), { kind: "succeeded", amount: 24, currency: "USD", providerRef: "126895", eventId: "waafi:REF:approved" });
  for (const notPaid of [{ ...approved, params: { ...approved.params, status: "Pending", tranStatusDesc: "Pending", tranStatusId: "1" } }, { ...approved, params: { ...approved.params, tranStatusId: "9" } }, { ...approved, errorCode: "5" },
                         { ...approved, params: { ...approved.params, referenceId: "SOMEONE-ELSE" } }, { errorCode: "0", params: {} }]) {
    assert.equal((await q(notPaid)).kind, "pending");
  }
});
test("WaafiPay query asks HPP_GETTRANINFO with the provider reference and the merchant credentials", async () => {
  const { a, sent } = waafi({ errorCode: "0", params: {} }); await a.query({ checkoutId: CK, providerRef: "REF", amount: 24 });
  assert.equal(sent[0].body.serviceName, "HPP_GETTRANINFO"); assert.equal(sent[0].body.serviceParams.referenceId, "REF"); assert.equal(sent[0].body.serviceParams.hppKey, "KEY-SECRET-123"); assert.equal(sent[0].body.serviceParams.storeId, "1234567");
});

function eda(reply: unknown, status = 200) {
  const sent: { url: string; raw: string }[] = [];
  const a = edahabAdapter({ apiKey: "KEY", apiSecret: "secretapikey", agentCode: "AG1", sha256Hex: sha, fetchImpl: (async (url: string, init: RequestInit) => { sent.push({ url, raw: init.body as string }); return status === 200 ? ok(reply) : new Response("x", { status }); }) as never });
  return { a, sent };
}
test("eDahab signs exactly as documented: SHA-256 hex of the raw body followed by the secret, as ?hash=", async () => {
  const { a, sent } = eda({ StatusCode: 0, invoiceId: "INV-1", InvoiceStatus: "Pending" });
  await a.start({ checkoutId: CK, amount: 24.5, currency: "USD", walletNumber: "252612345678", callbackBase: "x" });
  const hash = new URL(sent[0].url).searchParams.get("hash");
  assert.equal(hash, createHash("sha256").update(sent[0].raw + "secretapikey").digest("hex"));
  assert.equal(sent[0].url.split("?")[0], "https://edahab.net/api/api/Issueinvoice");
  assert.deepEqual(JSON.parse(sent[0].raw), { apiKey: "KEY", edahabNumber: "252612345678", amount: 24.5, agentCode: "AG1", currency: "USD" });
  assert.ok(!sent[0].raw.includes("secretapikey"));        // the secret is never sent, only mixed into the hash
});
test("eDahab start: success returns the invoice id; insufficient balance and other refusals are plain messages", async () => {
  const s = (r: unknown) => eda(r).a.start({ checkoutId: CK, amount: 24, currency: "USD", walletNumber: "252612345678", callbackBase: "x" });
  assert.deepEqual(await s({ StatusCode: 0, invoiceId: "INV-9" }), { providerRef: "INV-9" });
  await assert.rejects(s({ StatusCode: 5, invoiceId: null }), /balance is not enough/);
  await assert.rejects(s({ StatusCode: 4 }), ProviderRefused); await assert.rejects(s({ StatusCode: 0, invoiceId: null }), ProviderRefused);
  await assert.rejects(eda({}, 503).a.start({ checkoutId: CK, amount: 1, currency: "USD", walletNumber: "252612345678", callbackBase: "x" }));
});
test("eDahab local number format is available as configuration", async () => {
  const sent: string[] = [];
  const a = edahabAdapter({ apiKey: "K", apiSecret: "s", agentCode: "A", numberFormat: "local", sha256Hex: sha, fetchImpl: (async (_u: string, init: RequestInit) => { sent.push(init.body as string); return ok({ StatusCode: 0, invoiceId: "I" }); }) as never });
  await a.start({ checkoutId: CK, amount: 1, currency: "USD", walletNumber: "252612345678", callbackBase: "x" });
  assert.equal(JSON.parse(sent[0]).edahabNumber, "0612345678");
});
test("eDahab query: only Paid with success code for OUR invoice is paid, and it reports the CHECKOUT's amount; unknown invoice is failed; everything else pending", async () => {
  const q = (r: unknown) => eda(r).a.query({ checkoutId: CK, providerRef: "INV-1", amount: 24 });
  assert.deepEqual(await q({ StatusCode: 0, InvoiceStatus: "Paid", invoiceId: "INV-1", TransactionId: "MP260222.1316" }), { kind: "succeeded", amount: 24, currency: "USD", providerRef: "MP260222.1316", eventId: "edahab:INV-1:paid" });
  assert.equal((await q({ StatusCode: 0, InvoiceStatus: "Paid", invoiceId: "OTHER" })).kind, "pending");          // an answer about a different invoice
  for (const r of [{ StatusCode: 0, InvoiceStatus: "Pending" }, { StatusCode: 0, InvoiceStatus: "Unpaid" }, { StatusCode: 7, InvoiceStatus: "Invalid" }, { StatusCode: 1 }, { StatusCode: 5 }]) assert.equal((await q(r)).kind, "pending");
  assert.equal((await q({ StatusCode: 6 })).kind, "failed");
  const { sent } = eda({ StatusCode: 0, InvoiceStatus: "Pending" }); void sent;
});
