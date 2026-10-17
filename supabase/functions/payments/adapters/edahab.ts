/**
 * eDahab (Dahabshiil) through eDahab's merchant API, built from the published documentation (docs.edahab.net: IssueInvoice, CheckInvoiceStatus,
 * API introduction, status codes). EFZ issues an invoice for the customer's eDahab number; eDahab pushes a pop-up to the customer's phone where
 * the customer enters the PIN in eDahab's own prompt (EFZ never sees it). EFZ then asks eDahab for the invoice status.
 *
 * Request signing, exactly as documented: hash = hex(SHA-256(<raw POST body> + <API secret>)), sent as the ?hash= query parameter.
 *
 * What the public documentation does NOT say, to confirm with eDahab at onboarding:
 *   - a sandbox / test environment (none is documented) and IP whitelisting;
 *   - webhooks (listed as a capability, no page): this adapter does not rely on them, EFZ polls CheckInvoiceStatus;
 *   - the format eDahab expects for edahabNumber (the adapter sends the customer's digits as the app normalized them: configure EDAHAB_NUMBER_FORMAT);
 *   - the CheckInvoiceStatus answer carries NO amount. The invoice was issued by EFZ for the checkout's exact amount, so "Paid" for that invoice id
 *     is paid for that amount; the adapter therefore reports the checkout's own amount, never an amount the customer could influence.
 * Credentials (apiKey, apiSecret, agentCode) come from the function's environment only.
 */
import type { ProviderAdapter, ProviderResult, StartInput } from "../handler.ts";
import { ProviderRefused } from "../handler.ts";

export type EdahabConfig = { apiKey: string; apiSecret: string; agentCode: string; baseUrl?: string; numberFormat?: "international" | "local"; sha256Hex: (s: string) => Promise<string>; fetchImpl?: typeof fetch };
type Obj = Record<string, unknown>;

export function edahabAdapter(cfg: EdahabConfig): ProviderAdapter {
  const doFetch = cfg.fetchImpl ?? fetch;
  const base = (cfg.baseUrl ?? "https://edahab.net/api/api/").replace(/\/?$/, "/");
  async function post(endpoint: string, body: Obj): Promise<Obj> {
    const raw = JSON.stringify(body);
    const hash = await cfg.sha256Hex(raw + cfg.apiSecret);
    const res = await doFetch(`${base}${endpoint}?hash=${hash}`, { method: "POST", headers: { "content-type": "application/json" }, body: raw });
    if (!res.ok) throw new Error("provider http " + res.status);
    return (await res.json()) as Obj;
  }
  const number = (w: string) => (cfg.numberFormat === "local" ? "0" + w.replace(/^252/, "") : w);

  return {
    async start(i: StartInput) {
      const r = await post("Issueinvoice", { apiKey: cfg.apiKey, edahabNumber: number(i.walletNumber), amount: Math.round(i.amount * 100) / 100, agentCode: cfg.agentCode, currency: i.currency });
      const code = Number(r.StatusCode);
      if (code === 5) throw new ProviderRefused("Your eDahab balance is not enough for this payment.");
      if (code !== 0 || typeof r.invoiceId !== "string" || !r.invoiceId) throw new ProviderRefused("eDahab could not start this payment. Check the number and try again.");
      return { providerRef: r.invoiceId };
    },
    async query(i): Promise<ProviderResult> {
      const r = await post("CheckInvoiceStatus", { apiKey: cfg.apiKey, invoiceId: i.providerRef });
      const code = Number(r.StatusCode);
      if (code === 0 && r.InvoiceStatus === "Paid" && (r.invoiceId === undefined || r.invoiceId === null || r.invoiceId === i.providerRef)) {
        return { kind: "succeeded", amount: i.amount, currency: "USD", providerRef: String(r.TransactionId ?? i.providerRef), eventId: `edahab:${i.providerRef}:paid` };
      }
      if (code === 6) return { kind: "failed", amount: null, currency: null, providerRef: i.providerRef, eventId: `edahab:${i.providerRef}:not-found` };   // the invoice does not exist: it cannot be paid
      return { kind: "pending", amount: null, currency: null, providerRef: i.providerRef, eventId: `edahab:${i.providerRef}:pending` };
    },
  };
}
