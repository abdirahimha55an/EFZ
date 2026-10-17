/**
 * EVC Plus through WaafiPay's Hosted Payment Page (HPP). Built from WaafiPay's published HPP documentation (docs.waafipay.com, HPP_PURCHASE and
 * HPP_GETTRANINFO): the customer is sent to WaafiPay's hosted page where the wallet authorization (PIN / USSD prompt) happens; EFZ never sees it.
 *
 * What is NOT in the public documentation and must be confirmed with WaafiPay at merchant onboarding (the adapter is built so each is configuration,
 * not a guess hard-coded here):
 *   - the API address of the POST /asm endpoint (WaafiPay publishes only the sandbox hosted-page host)      -> WAAFIPAY_API_URL
 *   - the transaction-status vocabulary for declined / cancelled / expired payments (only "Approved" is documented): this adapter treats ONLY an
 *     explicit Approved status (tranStatusId 3) as paid; everything else stays "pending" until EFZ's checkout window expires. It never invents a failure.
 *   - callback signing: not documented, so the callback body is ignored by the handler and EFZ queries WaafiPay itself.
 * Credentials (merchantUid, storeId, hppKey) come from the function's environment only.
 */
import type { ProviderAdapter, ProviderResult, StartInput } from "../handler.ts";
import { ProviderRefused } from "../handler.ts";

export type WaafiConfig = { apiUrl: string; merchantUid: string; storeId: string; hppKey: string; fetchImpl?: typeof fetch; now?: () => Date; uuid?: () => string };
type Obj = Record<string, unknown>;

const stamp = (d: Date) => d.toISOString().replace("T", " ").slice(0, 23);

export function waafiPayAdapter(cfg: WaafiConfig): ProviderAdapter {
  const doFetch = cfg.fetchImpl ?? fetch;
  const now = cfg.now ?? (() => new Date());
  const uuid = cfg.uuid ?? (() => crypto.randomUUID());
  const envelope = (serviceName: string, serviceParams: Obj): Obj => ({
    schemaVersion: "1.0", requestId: uuid(), timestamp: stamp(now()), channelName: "WEB", serviceName,
    serviceParams: { merchantUid: cfg.merchantUid, storeId: Number.isFinite(Number(cfg.storeId)) && serviceName === "HPP_PURCHASE" ? Number(cfg.storeId) : cfg.storeId, hppKey: cfg.hppKey, ...serviceParams },
  });
  async function post(body: Obj): Promise<Obj> {
    const res = await doFetch(cfg.apiUrl, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
    if (!res.ok) throw new Error("provider http " + res.status);
    return (await res.json()) as Obj;
  }

  return {
    async start(i: StartInput) {
      const r = await post(envelope("HPP_PURCHASE", {
        paymentMethod: "MWALLET_ACCOUNT",
        hppSuccessCallbackUrl: `${i.callbackBase}/callback/evc_plus?c=${i.checkoutId}`,
        hppFailureCallbackUrl: `${i.callbackBase}/callback/evc_plus?c=${i.checkoutId}`,
        hppRespDataFormat: 1,
        payerInfo: { subscriptionId: i.walletNumber },
        transactionInfo: { referenceId: i.checkoutId, amount: Math.round(i.amount * 100) / 100, currency: i.currency, description: "EFZ order payment" },
      }));
      const p = (r.params ?? {}) as Obj;
      if (String(r.errorCode) !== "0" || typeof p.hppUrl !== "string" || !p.hppUrl.startsWith("https://")) throw new ProviderRefused("WaafiPay could not start this payment. Please try again.");
      return { providerRef: String(p.referenceId ?? i.checkoutId), redirectUrl: p.hppUrl as string };
    },
    async query(i): Promise<ProviderResult> {
      const r = await post(envelope("HPP_GETTRANINFO", { referenceId: i.providerRef }));
      const p = (r.params ?? {}) as Obj;
      const approved = String(r.errorCode) === "0" && String(p.status ?? p.tranStatusDesc) === "Approved" && String(p.tranStatusId) === "3";
      // The answer must be about the payment EFZ asked for.
      const sameRef = p.referenceId === undefined || String(p.referenceId) === i.providerRef;
      if (approved && sameRef) {
        const amount = Number(p.tranAmount ?? p.amount);
        return { kind: "succeeded", amount: Number.isFinite(amount) ? amount : null, currency: p.currency ? String(p.currency) : null, providerRef: String(p.transactionId ?? i.providerRef), eventId: `waafi:${i.providerRef}:approved` };
      }
      return { kind: "pending", amount: null, currency: null, providerRef: i.providerRef, eventId: `waafi:${i.providerRef}:pending` };
    },
  };
}
