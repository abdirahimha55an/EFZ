# Ball designs on the order form (migration 32)

> **Update 2026-11-09 (owner decision): the public `/order` page was restored to its pre-migration-32 version (`4b9bca2`).** Visitors see no design choice, no line cards, no price summary and no estimated total; the original one-line-per-product rule is back. Everything below that describes a *visitor* design selector or order-form totals is therefore NOT in the shipped app. Designs are managed in the Admin Hub (`/admin/product-designs`) only. Migration 32 and its public function are unchanged; the order form simply no longer calls `public_product_designs()`.

Implemented 2026-11-05 on `integration/pre-launch`. **Applied to EFZ-Staging only. Not applied to Production, not deployed to Production, not merged to `main`.**
Approval for Production is a separate step the owner has not given. This document is the record of what was built, how it was tested, and exactly what Production would need.

## What changed for people
- **Visitors** (`/order`): every order line has its own Product, **Design** (shown only when that product has active designs), Quantity and price (`$12.5 × 3 = $37.50`), with an estimated order total. One order may contain several designs of the same product; the same product + design cannot be listed twice (change the quantity instead). A product with no designs is ordered as before.
- **Staff** (`/admin/product-designs`, sidebar: Products & Inventory → Product Designs): create a design (product, name, optional https:// picture link, display order), edit it, switch it on or off, filter and search. Switching off hides it from the order form at once; requests and orders that already carry it keep it. There is deliberately **no delete button**: a design may be referenced by requests, orders and price agreements, so it is switched off instead.
- **Admin order management**: the website request screen now shows each line's design (it did not for website requests before; see "Root causes"), and Convert-to-Order carries the design and quantity onto the order line, priced by the existing resolver.

## Who may do what (enforced by the database, not by the screen)
| Action | Who |
| --- | --- |
| See active designs on the order form | anyone (through `public_product_designs()` only) |
| Read all designs, including switched-off ones | any active staff member |
| Create / edit / switch on or off / delete a design | holders of `edit_products` (Super Admin, Manager, Inventory Staff on Staging). Customer Service, Delivery, Marketing Officers: refused (verified). |
| See the Product Designs menu item and page | `edit_products`; others get an explanation, not the screen |
Every change is written to the Audit Trail by a database trigger in the same transaction (category INVENTORY, origin `database`): created, updated (naming what changed and the old name), activated, deactivated, deleted. A save that changes nothing writes nothing.

## Migration 32 (`supabase/32_order_designs.sql`) — function-only
No table, column, policy or grant on an existing object is added, changed or removed.
1. **New** `public_product_designs()` (security definer, read-only): active designs of active products → `(id, product_id, name, image_url)`, granted to `anon, authenticated`. The design table itself stays closed to visitors.
2. **Replaced** `submit_order_request(jsonb)` (defined once, in 18b; Production and Staging both ran the identical text, fingerprint `c819251209a3ae536b731340daaa3a4b`). Everything it did stays; it adds an optional `designId` per line (must be an active design of that line's product, else "A selected design is not available"), lets a product repeat when its designs differ (a repeated product without a design is still refused with the original sentence), and records each chosen design in `customer_order_request_lines`, the table the Android app already used and the Hub already reads. A payload without `designId` writes exactly what it wrote before.
3. **New** trigger functions on `product_designs`: `guard_product_design()` (trims the name; picture link must be `https://…` without spaces, ≤ 500 characters; display order 0–100000; a design never moves to another product) and `log_product_design_changes()` (the audit lines above).
The migration refuses to run unless the live `submit_order_request` is exactly the known 18b text or this file's own text (so a re-run is safe), ends with post-checks that abort the whole thing if anything is half-installed, and is idempotent.
**Rollback**: `supabase/rollback/32_order_designs_rollback.sql` restores the 18b function (copied verbatim from the 18b file), drops the new function and both triggers, and verifies the restored fingerprint. Design rows and the design a visitor already chose on a request are kept. Proven on Staging in a dry-run transaction.
**Ordering**: the app degrades safely either way. Before the migration the order form simply shows no designs (the lookup answers an empty list) and the admin screen can already read/write the table; so deploying the app before or after the migration cannot break ordering. Migration first is still the recommended order.

## Root causes found on the way
- *No design choice on the form*: visitors could not read designs (no grant), the request lines had nowhere to keep one for website requests, and the function refused a repeated product and silently dropped any `designId`.
- *Designs invisible in the admin for website requests*: `withAppInfo()` in `lib/supabase/queries.ts` attached a line's design only to requests with a customer-app link. It now attaches designs to any request that has them, and marks only genuine app requests as app requests (both verified).
- *A bug in my first draft of the audit trigger* (an untyped literal appended to a `text[]` made every rename fail) was caught by the new database checks, fixed, and re-applied before anything else relied on it.

## Evidence (all on Staging; nothing touched Production)
| Test | Result |
| --- | --- |
| Migration 32 dry run (rolled back) / apply / re-apply after the fix | clean; post-checks pass |
| `supabase/checks/32_order_designs_checks.sql` | **60 PASS, 0 FAIL** (visibility, every refusal path, mixed orders, double submit, management permissions, validation, audit lines, nothing else moved). First run found the bug above (48/12). |
| Rollback file, dry run | restores fingerprint `c8192512…`, removes the function and both triggers |
| `supabase/checks/32_order_designs_e2e.mjs` (real Hub data layer, real roles) | **39 PASS, 0 FAIL** (see below) |
| Unit tests (`npm run test:hub`) | 126/126 (22 new) |
| Order form in jsdom (real page, stubbed backend) | **33/33**; breaking the availability rule or the payload made exactly the right tests fail |
| Product Designs screen in jsdom | **31/31**; removing the permission gate or the duplicate-name rule made the right tests fail |
| Convert-to-Order dialog (existing suite) | 32/32, incl. two designs of one product with their own prices |
| Existing public-form and inbox suites | 34/34 and 24/24 |
| TypeScript / lint / production build | clean / 0 errors, 40 warnings (none new) / passes, 33 pages incl. `/admin/product-designs` |
End-to-end highlights: Inventory staff created designs; Customer Service was refused (create and switch-off); a visitor saw only active designs, in display order; switching off hid a design at once and switching on restored it; the database refused `http://` links and duplicate names; a visitor ordered **two designs of one product with quantities 4 and 6, a design of another product (×2) and a plain product (×3)**; the admin data showed each line with its own design and quantity; the request moved new → contacted → confirmed and converted to an order whose lines were `E2E32 Crimson ×4 @ $12.00`, `E2E32 Blue ×6 @ $12.00`, `E2E Red Design ×2 @ $100.00`, `EFZ - Training Ball ×3 @ $8.00` = **$344.00** (each price equals what the resolver gave: agreement, else list; a design carries no price of its own); stock, payments and commissions did not move; converting twice was refused; the test order was cancelled.

## What the tests left on Staging (synthetic, harmless)
16 test designs named `E2E32 …` (all switched off), 4 requests named `E2E32 Probe …` (rejected or converted), 2 cancelled orders (one `ORD-1923463`), and their audit lines. Payments, commissions, customers, profiles, permissions, products, stock movements and per-product stock are byte-identical to before (checked by fingerprint).

## Things to know
- **Production has no designs and the order form will not change there until staff add some** with the new screen. Nexus / Fire Ball / Phantom Blue are separate *products* and keep working exactly as before.
- A design has no price of its own; a line is priced from its product (and a per-customer design agreement at conversion, if one exists). The form shows list prices and says EFZ confirms the final price.
- Staging's Fire Ball is over-promised (88 units open against 84 in stock), so `create_order` refuses to convert more of it; that is the existing inventory protection, not a defect.
- **Older check scripts and strict mode.** Staging now holds a signing secret (strict mode, left on deliberately). The 30 and 31 check scripts assume legacy mode: the M30 checks give 95/100 (their network-limit checks and a notification count) until the secret and two leftover notifications from earlier E2E runs are removed; proven 100/100 in a rolled-back transaction that first removed them. Remove the secret (`delete from public.inquiry_signing_secret;`) before rerunning them, then store one again.

## Production rollout (NOT done; needs the owner's separate approval)
1. Fresh sealed Production backup (owner-run; the newest is 2026-10-21).
2. Read-only confirmation that Production's `submit_order_request` fingerprint is still `c819251209a3ae536b731340daaa3a4b` (it was, on 2026-11-05) and that migrations 18b and 22 are present.
3. Apply `supabase/32_order_designs.sql` to Production (the checks scripts refuse Production by design; verify with read-only queries instead: the function text contains `designId`, `public_product_designs()` exists and is executable by `anon`, `anon` cannot select `product_designs` or `customer_order_request_lines`, both triggers exist).
4. Deploy the app (Preview first, which already runs against Staging).
5. Smoke test with a real phone: add one design in the Hub, place a test request, confirm it shows with its design, reject it.
Rollback at any point: the rollback file, then redeploy the previous app version (the app also works without the migration).
