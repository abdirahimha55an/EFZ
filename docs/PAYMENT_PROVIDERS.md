# Payment providers for the EFZ customer app: EVC Plus and eDahab

> **EVC Plus (WaafiPay) and eDahab are NOT available for real payments.** The adapters are unit-tested against published formats only; no merchant account, credentials, sandbox or live payment exists, and the WaafiPay credential format is unconfirmed (see the onboarding findings below). Until each provider is contracted, its integration is verified server-side against the provider's sandbox and a supervised small live payment is checked, the only payment that completes is the clearly labelled Staging test method. Credit purchases (migration 25) never involve a provider: repayments are recorded by staff in the existing payments table.

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

## Merchant onboarding: what the public sources actually say (checked 2026-10-17)

Nothing below is an assumption about a process; where a public page is silent, it says "not published". The two providers publish very little, so the real requirements will come from them directly.

### EVC Plus through WaafiPay

| Question | What is published | Source |
|---|---|---|
| How to become a merchant | A contact form ("Start Accepting Payments" goes to `/contact`), a Merchant Portal and a Sign In link. No steps listed. Support email `support@waafipay.net`; address Salaam Tower, Djibouti. | waafipay.com |
| Required documents | Not published | waafipay.com |
| Credentials | docs.waafipay.com says that after registration you receive "an API key and a client ID". It does **not** mention `merchantUid`, `storeId` or `hppKey`, which are what the hosted-payment-page request format used by our adapter needs. | docs.waafipay.com |
| How access is obtained | docs.waafipay.com says to register in person at the "WAAFI HQ Offices (Telesom, Zaad, Golis, WAAFI SAB)". | docs.waafipay.com |
| Sandbox / test | Not documented. The home page links a "Demo POS" at `checkout.waafipay.net` and does not say what it is. | waafipay.com |
| Callbacks | "Webhooks" is a menu entry with no content. Signing is not documented. | waafipay.com, docs.waafipay.com |
| Fees, limits, settlement | Not published | |
| EVC Plus | Listed under "Local Wallet Payments" | waafipay.com |

**Open discrepancy to resolve with WaafiPay:** our adapter follows the hosted-payment-page request format (`HPP_PURCHASE`, `HPP_GETTRANINFO` with `merchantUid`, `storeId`, `hppKey`) that WaafiPay's integration examples and third-party plugins use. The official docs page we could read describes a different credential pair (API key + client ID). Before any live use, WaafiPay must confirm in writing which API EFZ's merchant account uses and give the matching credentials; if it is the API-key flow, the adapter (`supabase/functions/payments/adapters/waafipay.ts`) needs a rewrite and its tests will be re-done against the confirmed format. Until then it must be treated as **unverified**.

### eDahab

| Question | What is published | Source |
|---|---|---|
| How to get access | "Register for an eDahab account and request API access." | docs.edahab.net |
| Required documents, approval process | Not published | |
| Credentials | A key and a secret from the eDahab dashboard. The docs page does not mention an agent code, which our adapter currently expects (`EDAHAB_AGENT_CODE`). Confirm whether it exists. | docs.edahab.net |
| Capabilities listed | Merchant Integration (connect e-commerce or point-of-sale systems to mobile money) and Notification / Webhooks ("real-time updates on payment statuses"). No setup details. | docs.edahab.net |
| Sandbox / test, IP whitelisting, fees, limits | Not published | |
| Company | eDahab is Somtel's wallet (Dahabshiil group). Somtel's page says an eDahab API for local and global e-commerce has been released to developers. | somtelnetwork.net/eDahab |

For comparison only: Telesom's ZAAD business accounts are opened in person at a sales outlet with a business licence and personal ID. That is ZAAD, not eDahab, and is **not** evidence of eDahab's requirements.

### The exact next action for the owner

1. Contact **WaafiPay** (`support@waafipay.net` or the contact form, or visit WAAFI HQ) as EFZ, and ask for: a merchant account for EVC Plus; **which API EFZ's account uses and its credentials** (the discrepancy above); a **test/sandbox** account and URL; the published **fee schedule and settlement terms**; whether payments carry a **signature or hash on the callback**; the exact status values for declined, cancelled and timed-out payments; and the documents EFZ must bring (a business licence and owner ID are typical in this market, but only WaafiPay can say).
2. Contact **eDahab / Somtel** and ask for: an eDahab merchant account and API access; whether an **agent code** exists; a **test method**; fees and limits; webhook setup and signing; any IP whitelisting.
3. Do **not** send me any key, secret, PIN or password in chat. When the credentials exist, put them into the Staging project yourself with `supabase secrets set` (names listed above) or tell me when they are set, and I will run the sandbox tests on Staging only.
4. Decide the refund and reversal process (today a reversal is flagged for staff and never changes the books by itself).

Until both providers answer, the only payment that works is the clearly labelled Staging test method.
