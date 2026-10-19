# Migration 28 - request conversion keeps the design and the agreed price

Status: **prepared, NOT applied anywhere.** Staging only, after the owner approves the reviewed SQL. Not for Production without a separate approval.

Files: `supabase/28_convert_request_designs.sql`, `supabase/rollback/28_convert_request_designs_rollback.sql`, `supabase/checks/28_preflight.sql`, `supabase/checks/28_post_deploy.sql`.
Hub: `components/admin/requests/ConvertRequestDialog.tsx`, `lib/requestConversion.ts` (+ test), `lib/supabase/queries.ts`, `lib/types/index.ts`.

## What changes

One function: `convert_website_request(uuid, jsonb)`. No table, column, index, policy, grant or permission. `create_order()` is not touched. The function text is the migration-27 text
except the line loop: a line may carry `designId` / `designName`, `actualUnitPrice` is optional, and a product + design pair may appear once.

| Question | Answer |
|---|---|
| Default price | Price left out -> `create_order()` -> `_price_resolve()`: design agreement, else product agreement, else list. A pending / conflicting / unapproved-below-cost agreement blocks the line. |
| Design | `designId` (catalogue) or `designName` (recorded name, e.g. a removed design) is forwarded; `create_order()` validates it, writes `order_items.design_name` and `order_price_resolutions.design_id`. |
| Override | A price that is sent and differs from an agreed price needs `priceOverrideReason` (10+ chars) - enforced by `create_order()`, not by the Hub. It becomes `staff_override` and a WARNING `system_logs` row (`agreed_price_overridden`: agreed price, charged price, reason, actor, order). |
| Below cost | Unchanged: Super Admin only, with `belowCostReason`; an exact agreed price is exempt (approved when the agreement was verified). |
| Duplicate conversion | Unchanged and still enforced: `FOR UPDATE` on the request, status must be `confirmed`, unique index `order_requests_converted_order_uq`; a failed `create_order` rolls the whole call back. |
| Snapshots | `order_items` freezes `standard_unit_price`, `actual_unit_price`, `historical_unit_cost` and `design_name` at creation; later price, agreement or design changes never rewrite them. |
| Existing data | Not touched. The five already-converted app requests keep their orders (`28_post_deploy.sql` shows their lines and that they gained no resolution rows). No backfill. |

## Override authorization review (code and read-only Staging facts)

* The caller needs `convert_website_requests` (checked in `convert_website_request`) AND `create_orders` (checked in `create_order`). Super Admin passes every permission check.
  On Staging, active holders: `convert_website_requests` = 2 Managers; `create_orders` = 2 Managers, 2 Marketing Officers, 1 Customer Service. So **only Managers and the Super Admin can convert, and therefore only they can override**.
* There is **no separate "override price" permission**: any converter may charge a different price for an agreement customer if they give a 10+ character reason. The Hub's pricing-admin notion
  (`managePricing` = Super Admin or Manager with `edit_products`) is not enforced here. This is the migration-27 policy as approved ("documented reason") and migration 28 does not widen or narrow it.
* The reason is enforced by the database; the Hub only asks for it early. A forged client cannot skip it.
* Audit: `order_price_resolutions.source = 'staff_override'` (+ agreement id, list price, applied price) and the WARNING `system_logs` row. The reason text is in the log, not on the order line.
* Decision for the owner (not implemented): if overrides should need a stronger right than `convert_website_requests`, that is a change to `create_order()` (a new permission check) and is outside this migration.

## Migration-history table (was unverified)

Staging has **no `supabase_migrations` schema** (`information_schema` shows only `auth`, `storage` and `realtime` migration tables): migrations were applied through the SQL editor and are not recorded.
So "which migrations are applied" is established from the objects and fingerprints, which is what `28_preflight.sql` does. The earlier empty result was a missing schema, not a permissions problem.
Verified read-only on Staging: `create_order` md5 `265e9745...` (= migration 27), `convert_website_request` md5 `fe992c8a...` (= migration 27), `convert_order_request` unchanged `fc18ea5e...`.
A local PGlite run reproduces the same `fe992c8a...` md5 for the migration-27 function text, so the guard value in migration 28 and the rollback target are exactly right.

## Repeated product lines with different designs: stock and pricing (checked before enabling)

* **Stock.** `create_order()` locks the product row (`FOR UPDATE`) for every line and checks `stock - product_committed_quantity(product)`. `product_committed_quantity` sums `order_items` of every open `at_delivery` order
  for that product, and the new order's earlier lines are already inserted, so a second line of the same product sees the first as committed. Stock is per product, not per design, so two designs of one product
  draw on the same shelf - correct. (Read from the live Staging definitions of both functions.)
* **Pricing.** Each line is resolved on its own with its own design id: the design's agreement beats the product-wide agreement, and a design without its own agreement falls back to the product-wide one.
* **Not proven on live data**: no order has yet been created through the migration-27 pricing path on Staging (`order_price_resolutions` is empty). Tests T6-T8 below prove it before the workflow is relied on.
  The Hub previously blocked repeated products; it now allows them only with different designs, and the database refuses an identical product + design pair.

## Tests that need NO database write (run now / in CI)

| # | What | Where | State |
|---|---|---|---|
| A1 | Hub rules: price omitted unless changed; same price typed is not an override; agreement override needs 10+ chars; list-price change needs no reason; review lines blocked; lookup failure keeps the old behaviour; design by id or name; duplicate product+design refused; agreed price not a below-cost case | `lib/requestConversion.test.ts` (`npm run test:hub`) | passing (9) |
| A2 | Existing Hub tests (accounts, requests, finance, prices) | `npm run test:hub` | passing (37) |
| A3 | `tsc --noEmit`, `eslint` on the changed files, `next build --webpack` | local | passing |
| A4 | Migration-28 function against a **local in-memory Postgres (PGlite)** with a stubbed `create_order`: compiles; price omitted is not forwarded; price + design + reason forwarded; two designs of one product accepted; same product+design twice refused; bad design id / non-numeric price / no product / no lines refused; refused calls leave the request confirmed; converted / non-confirmed / no-permission refused; marker survives in the stored definition; rollback text == migration-27 text; M27 text fingerprints to the Staging md5 | scratch harness (22 checks, 22 pass) - not part of the repo | passing |
| A5 | Read-only SQL on Staging: `28_preflight.sql` (before), `28_post_deploy.sql` (after) - plain SELECTs; both were already executed read-only against the current Staging and returned as expected (marker false, M27 text true, counts) | Staging, read-only | done once |

## Tests that REQUIRE writes on Staging (synthetic data only; NOTHING below has been run or created)

Needs owner approval for the writes, and staff sessions (the functions use `auth.uid()`): the synthetic Staging staff (`efz.superadmin@example.com`, a Manager) signing in to the Hub **preview**, or an authenticated test script.
Orders and converted requests cannot be deleted afterwards (append-only), so the rows stay on Staging; they are synthetic and marked `TEST-28`.

Setup (approval needed): 3 synthetic customers (A with a product agreement, B with a design agreement, C with none), 1 agreement each via `create_price_agreement` (verified by a Manager), one pending agreement on customer D,
~8 synthetic confirmed requests (website form + the customer-app RPC for the two designed products), no change to the 5 converted requests.

| # | Case | Expected |
|---|---|---|
| T1 | Convert a website request (no designs), customer C, no price sent | order at list price; `order_price_resolutions.source='list'`; line count = request lines |
| T2 | Customer A (product agreement), price omitted | line at agreed price; `source='agreement'`; `agreement_id` set |
| T3 | Customer B, app request line with design X, price omitted | design agreement price; `order_items.design_name='X'`; `order_price_resolutions.design_id` = X |
| T4 | Customer with product agreement AND design agreement, design line | design agreement wins; the other line of the same product without a design gets the product agreement |
| T5 | Customer D (agreement pending review) | conversion refused with the review message; request still confirmed; no order |
| T6 | One request, same product twice with two designs | one order, two lines, each priced by its own design; stock check is joint |
| T7 | Same, quantities that fit each line alone but not together | refused with "Insufficient stock"; nothing written |
| T8 | Same product + same design twice | refused ("listed once") |
| T9 | Agreement customer, different price, no reason / 9 chars | refused, nothing written |
| T10 | Same, reason of 10+ chars | order created; `source='staff_override'`; WARNING log `agreed_price_overridden` with agreed, charged, reason, actor |
| T11 | Price below cost by a Manager; by a Super Admin with `belowCostReason` | Manager refused; Super Admin allowed; exact agreed price below cost needs no reason |
| T12 | Convert the same request twice, and two simultaneous conversions | one order only; the second gets "already converted" |
| T13 | Convert as a Marketing Officer / Customer Service | permission error; nothing written |
| T14 | Old Hub (price sent on every line, as before) against migration 28 | still works exactly as before |
| T15 | Totals: order total, delivered-stock effect, commission, revenue and finance views for the new orders vs a hand calculation; `validate_financials.sql` | unchanged semantics, no FAIL |
| T16 | Re-run `28_post_deploy.sql` | `create_order` unchanged; the 5 old orders unchanged with 0 resolution rows; only the tested orders added |
| T17 | Run the rollback on Staging, repeat T12/T14, re-apply migration 28 | rollback restores md5 `fe992c8a...`; re-apply works (retry-safe) |

## Risks

1. The migration-27 pricing path has never produced an order on Staging; T2-T4 are the first real proof. Mitigation: run them before the Hub change is deployed anywhere.
2. Deployment order: migration 28 must be live before this Hub build is used. With the new Hub on the old function, a price-less line is refused ("needs a confirmed unit price") - a clear error, nothing written. An old Hub on the new function keeps working (T14).
3. A design id the app recorded is passed through as-is; `create_order` checks it belongs to the product but (existing behaviour) not that it is still active. Left unchanged on purpose.
4. Production does not have migrations 26-27 (assumed - not verified here); do not deploy this Hub build or migration 28 to Production before them.

## Rollback

Hub: revert the commit. Database: `rollback/28_convert_request_designs_rollback.sql` (guarded: refuses unless the function is the 28 or the 27 text; restores the migration-27 text byte for byte). Nothing stored is lost; orders created while 28 was live keep their design and prices.

## Addendum (cleanup before the Staging migration)

* The Convert dialog never submits a displayed price as a fallback: a failed or malformed `resolve_order_price` answer blocks the line with a Retry; a price typed for one customer is dropped when another is chosen.
* `supabase/checks/28_post_deploy.sql` now pins the five customer-app requests converted before migration 28 by their exact ids; the "all converted app requests" query is labelled as such (it grows after migration 28).
* `supabase/checks/28_fingerprint.sql` (one read-only SELECT) hashes the full content of the historical tables and the schema (indexes, policies, columns, grants, triggers, every function body except `convert_website_request`). Run it immediately before and after the migration: all values must be identical except `convert_website_request`.

## Result of the Staging integration run (2026-10-19)

Run with `supabase/checks/28_integration/` against EFZ-Staging only. Groups g1-g6 passed with 0 failures (15 + 21 + 21 + 32 + 13 + 14 checks, each rolled back); the concurrency test (the only one that commits) left exactly 1 customer, 1 request and 1 order, all `TEST-28`. Schema fingerprints after all tests are identical to right after migration 28; the hashes of all pre-existing orders, order items, requests and logs are identical to before migration 28. Findings and limits are in the run report (u-stg-nologin untestable; one concurrent CLI session failed to connect; same-transaction timestamp tie for the first-order bonus holder; T17 was done inside a rolled-back transaction).
