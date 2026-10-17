# Payment providers for the EFZ customer app: EVC Plus and eDahab

Status: researched from the providers' public documentation on 2026-10-17. **No live payment is possible yet**: both integrations need merchant credentials from the providers. Everything below marked "confirm" is something the public pages do not state.

## Options compared

| | A. Direct: WaafiPay (EVC Plus) + eDahab API | B. Aggregator: Sifalo Pay |
|---|---|---|
| EVC Plus | Yes, through **WaafiPay's Hosted Payment Page** (`MWALLET_ACCOUNT`, which WaafiPay documents as Waafi/EVC Plus, Zaad and Sahal). Hormuud publishes no public merchant API. | Listed |
| eDahab | Yes, **eDahab's own merchant API** (docs.edahab.net) | Listed |
| Credentials | Two sets, two onboardings: WaafiPay (`merchantUid`, `storeId`, `hppKey`) and eDahab (API key + secret + agent code from the eDahab dashboard, needs an approved merchant account) | One set, one onboarding; how keys are issued is not stated publicly |
| PIN handling | EVC Plus: entered on WaafiPay's hosted page / wallet prompt. eDahab: entered in eDahab's own phone prompt. EFZ never sees it. | Not documented on the public page |
| Server-side verification | WaafiPay `HPP_GETTRANINFO` (status by reference, authenticated with the HPP key). eDahab `CheckInvoiceStatus` (SHA-256 of body + secret) | A REST API exists (developer.sifalopay.com); no webhook or verification mechanism is described on the public page |
| Callbacks / webhooks | WaafiPay: success and failure callback URLs (signing not documented). eDahab: webhooks mentioned, no page | None described |
| Sandbox | WaafiPay: a sandbox hosted-page host is shown in examples, no setup steps. eDahab: none documented | None described |
| Settlement | Direct to EFZ's own merchant accounts | Into a Sifalo balance that EFZ withdraws to bank/mobile money (bank needs a Business plan); a third party holds the funds in between |
| Fees | Not published: ask each provider | "Vary by gateway": in the portal |
| Dependency | Two providers, but no intermediary | One intermediary |

## Recommendation

**Direct integrations (option A), each behind the same server-side adapter interface**, with Sifalo Pay kept only as a fallback if a direct merchant agreement is refused or very slow.

Why: both direct APIs document the two things that matter for safe money handling: a customer authorization step that happens inside the provider (so EFZ never touches a PIN) and a server-to-server status query EFZ can call itself. Funds settle straight to EFZ's own merchant accounts. The aggregator's public material describes neither a verification mechanism nor a sandbox, so it cannot be judged safe without private documentation.

## How it is built (already in the repository)

`supabase/functions/payments` (Edge Function, deploy with `--no-verify-jwt`):

* `POST /start { checkoutId, walletNumber }`: a signed-in customer starts the provider payment of **their own** checkout. The only customer input is the wallet's mobile number.
* `POST /status { checkoutId }`: EFZ's server asks the provider and records a **verified** result.
* `/callback/<method>?c=<checkoutId>`: the provider's redirect. **The body is ignored**; the callback only makes EFZ query the provider itself, so a forged or replayed callback cannot mark anything paid.
* A result becomes real only through the database function `finalize_customer_checkout` (service role only): it checks the amount, re-prices, re-checks stock, is idempotent per provider event, creates exactly one order and one payment row, and parks anything doubtful for staff review. Pending, failed, cancelled, expired and reversed outcomes never create a paid order.
* Adapters: `adapters/waafipay.ts` (EVC Plus) and `adapters/edahab.ts`, written from the published request/response formats and unit-tested with those formats. They are **only active when their secrets are set**; otherwise every route answers 501.

Secrets (set with `supabase secrets set`, never in the repository or the app):

```
PAYMENTS_PUBLIC_URL   https://<project-ref>.supabase.co/functions/v1/payments
WAAFIPAY_API_URL, WAAFIPAY_MERCHANT_UID, WAAFIPAY_STORE_ID, WAAFIPAY_HPP_KEY
EDAHAB_API_KEY, EDAHAB_API_SECRET, EDAHAB_AGENT_CODE   (optional: EDAHAB_BASE_URL, EDAHAB_NUMBER_FORMAT=international|local)
```

Then a Super Admin adds the methods in **Hub > Customer Payments & Credit** with the codes `evc_plus` and `edahab` and enables them. Until then customers see no payment method.

## Exactly what is still needed before live payments

1. **WaafiPay merchant account** for EVC Plus: `merchantUid`, `storeId`, `hppKey`, the production API address for `POST /asm`, sandbox credentials, fees, settlement terms. Confirm: the wording of declined / cancelled payment statuses (only `Approved` is documented; the adapter treats everything else as still pending until the checkout expires), whether a callback signature exists, and whether WaafiPay can also carry eDahab.
2. **eDahab merchant account**: an approved merchant account, an Agent created in the eDahab dashboard (API key, API secret, agent code). Confirm: a sandbox or test method, IP whitelisting, the expected format of `edahabNumber`, webhooks, and the maximum invoice amount and daily limits. The status answer carries no amount, so EFZ relies on the invoice it issued for the exact checkout amount.
3. **Staging test with provider sandboxes** (WaafiPay sandbox) before any live use, then a small real payment under supervision.
4. **A decision on refunds and reversals**: today a provider reversal flags the checkout, notifies staff and writes a CRITICAL audit line, but deliberately does **not** change the order or its payment automatically. Staff handle it in Hub.
5. Production checklist: rotate no secret into the repository; set the secrets only in the Production project at go-live; run the full Staging verification again; owner approval.

## Simulated payments

Until the above exists, the only payment that completes is the **Staging test method** (`stg_test`): its checkouts can be finalized only by the `staging-test-payment` function, which answers 404 unless the project is Staging, and its label says "test only". It is never real money and is never created in Production.
