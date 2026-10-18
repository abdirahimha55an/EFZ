# Negotiated customer pricing (Migration 26)

**Status: implemented and tested LOCALLY. Applied nowhere (not Staging, not Production).** Nothing here changes a price until an owner-approved migration is applied and agreements are verified.

## What already existed (and is reused)
* `order_items.standard_unit_price` = the list price at the time; `order_items.actual_unit_price` = the price charged. Staff orders (`create_order`) already store both and already have the "below cost needs a Super Admin and a reason" rule.
* `can_manage_pricing()` = Super Admin or Manager. Revenue = `sum(orders.total)` of non-cancelled orders; invoices, receipts, payments and revenue all read the order lines, so a charged price is already an immutable snapshot.
* No negotiated-price table existed. Past negotiated prices are only visible as `actual_unit_price <> standard_unit_price` on old orders. Migration 26 adds the missing agreement record; it does **not** create a second pricing system for staff orders.

## Rules (all enforced in the database, never by the app)
| Situation | What the customer sees / pays |
|---|---|
| No agreement | List price |
| Active, verified agreement in its dates | The agreed price. A design agreement beats a product agreement, which beats the list price |
| Agreement not yet started / ended / expired | List price (the Hub flags expired and soon-ending agreements) |
| Agreement waiting for verification (imported candidate) | **Not used.** Priced "to be confirmed": the item cannot be ordered online until staff verify or reject it. The price never silently falls back to list for a customer who had a negotiated price |
| Two active agreements in conflict, or an agreed price below cost without a Super Admin approval | Same "to be confirmed" hold |
| Customer sends a price in the order | Ignored. The app sends only product, design and quantity; the server resolves and re-resolves the price at checkout and stores it |

* **Per product or per design.** Agreement-wide percentage discounts are not supported (the business model was not stated; see decisions).
* **Immutable history.** The order line stores the list price and the charged price; `order_price_resolutions` stores which agreement produced it. Changing, ending or revoking an agreement never touches an existing order, invoice, payment or revenue figure.
* **Changes are atomic and audited.** `replace_price_agreement` closes the old agreement and opens the new one in one transaction; every create / verify / reject / revoke / end / replace writes `price_agreement_events` and an audit log line. Agreements are never edited in place or deleted.
* **Concurrency.** Overlap checks and revocations take locks; checkout takes the agreement row state at pricing time. A checkout racing an agreement change is priced either entirely before or entirely after it.
* **Privacy.** Customers can call only `customer_catalog` / `customer_designs` / `customer_price_preview` / `customer_start_checkout` (their own resolved price and the list price). Agreement tables have all client privileges revoked; staff access is through `can_manage_pricing()` functions. No cost, margin or other customers' agreements are reachable (exposure suite: `customer_data_exposure_checks.sql`).

## Who can do what
Super Admin and Manager: create, verify, reject, revoke, end, replace, import. Only a Super Admin can approve a below-cost price. Officers, Customer Service and customers cannot. Hub page: **Customer Prices**.

## Existing agreements: import workflow (never invents a price)
`import_price_candidates(dry_run, since, min_orders)` reads past non-cancelled orders and classifies each customer/product(/design):
* **Candidate** (becomes a *pending* agreement, not used until a human verifies it): at least `min_orders` orders, every one below list at the **same** price, not below cost, known design.
* **Needs manual confirmation** (listed, nothing created): a single order, varying prices, a mix of list and negotiated prices, a price below cost, or an unknown design.
* Dry-run (default in the Hub "Preview") writes nothing. The Hub offers the manual list as a CSV.

### Result on a copy of the Staging data (local, dry run, 2026-10-18)
This Staging data contains only test customers. **1 candidate and 7 cases needing manual confirmation:**
* Candidate: Test Club Alpha / EFZ - Fire Ball, $10.00, 2 orders since 2026-08-01.
* Manual: 5 single-order cases; Test Club Alpha / Nexus ($10-$12, varying); Test Club Bravo / Fire Ball ($12-$12.50 over 44 orders, varying).
* **Production was not examined**, so real missing or ambiguous agreements are **unknown**. The same dry run must be repeated on a Production copy by the owner before any agreement is trusted.

## Decisions the owner must make (nothing was decided silently)
1. **Expired agreement:** currently reverts to list price and is flagged. Alternative: hold the item ("to be confirmed") until renewed. Holding is safer for established customers but stops their online orders.
2. **Imported candidates:** currently block online ordering of that item until verified. Alternative: let candidates apply immediately (rejected: it would trust unverified history).
3. **Varying historical prices:** never auto-applied; who verifies, and what evidence is required?
4. **Staff-entered orders:** `create_order` still takes the price typed by staff; it does not auto-fill agreed prices. Should it default to the agreement?
5. **Agreement-wide % discounts or customer tiers:** not built; confirm whether they exist in the business.
6. **Below-cost agreements:** allowed only with Super Admin approval and a reason; confirm that is the policy.

## Tests (local disposable PostgreSQL 17 clones unless stated)
* `supabase/checks/26_price_agreements_checks.sql`: 63 checks (different prices for different customers and designs, precedence, expiry and start dates, missing/pending/conflicting/below-cost holds, price manipulation by the client, historical orders/invoices/revenue unchanged after agreement changes, authorization by role, customer data exposure, import classification, audit trail, populated-table access).
* `supabase/checks/26_price_concurrency.mjs`: 11 checks with real parallel sessions (simultaneous creations, revocations, imports, checkout versus agreement change).
* Mutation test of migration 26: 44 of 45 deliberate regressions caught; the survivor (M42, end-dating an agreement later than it already ends) is an equivalent mutant: `end_price_agreement` checks that an end date can only be brought forward, and the table's guard trigger (`guard_price_agreement`) independently rejects any later or removed end date ("an agreement can be shortened, not extended"). With the function check removed, the same request is still refused (same outcome, only the error text differs), so no test can tell the two apart. The function check is kept for its clear message.
* Hub: `lib/customerPrices.test.ts` (7 tests) and a browser test of the Customer Prices page (`hub_prices_browser.mjs`, 19 checks: permissions on real Staging; screen and arguments mock-backed).
* App: `__tests__/pricing.test.tsx` (9 tests; full app suite 151).
