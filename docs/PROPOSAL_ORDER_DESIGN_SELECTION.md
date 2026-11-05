# Proposal: per-line design selection on the website order form

Written 2026-11-05. **Status: awaiting owner approval. Nothing here is built, applied or deployed.** Reason for stopping: this needs a database migration, which the brief forbids without approval.

## What was asked
Each order line gets its own product *and design* selector; one order may contain several designs, including several designs of the same product; each line keeps its own quantity and price; the chosen design is stored with the request and visible in the Hub.

## What the system does today (evidence)
Checked on 2026-11-05 against the real `submit_order_request` function on Staging, as the anonymous role, in rolled-back transactions (0 rows left behind):

| Case | Result |
| --- | --- |
| Two **different products**, quantities 3 and 7 | Works: two request lines, each with its own product, name and quantity |
| The **same product on two lines** | Refused: "Each product can be listed once; change its quantity instead." (database rule, `18b`) |
| A line carrying a **real design id** | Accepted, but the design is **silently dropped** (no row is written) |

Why designs cannot work without database changes:
1. **Visitors cannot see designs.** `product_designs` has no `anon` grant and no policy (migration 22): only signed-in staff, and the app's approved customers through `customer_designs()`.
2. **The request line has nowhere to keep a design** for website requests. `order_request_items` has `product_id, product_name, quantity` only. (App requests keep theirs in `customer_order_request_lines (request_id, line_no, design_id, design_name)`, which is keyed to `order_requests` itself, so it can be reused: no new table or column.)
3. **The function rejects one product on two lines**, and ignores any `designId`.

What already works and needs no change: the Hub's request screen reads `customer_order_request_lines` for every request and shows the design; conversion to an order (`convert_website_request`, migration 28) already forwards `designId`/`designName` to `create_order`, which stores `design_name` on the order line and prices it through the existing resolver. Stock, payments and commissions are untouched by any of this because a request is not an order.

## Facts that affect the decision
- **There is no screen to create or edit designs** anywhere in the Hub. They are inserted with SQL only.
- **Production has 0 designs.** (Staging has 3 rows, 2 active.) The three balls EFZ sells today (Nexus, Fire Ball, Phantom Blue) are separate **products**, and the current form already lets a visitor pick a different product, with its own quantity, on every line.
- So even with the database change, the design dropdown would stay empty on Production until designs are created.

## Proposed change (migration 32, function-only, no table/column/policy/grant on existing objects)
1. **New function** `public.public_product_designs()`: `security definer`, read-only, returns `(id, product_id, name, image_url)` for active designs of active products; `execute` granted to `anon, authenticated`. (Exposes only what a visitor would see in a picker.)
2. **Replace** `public.submit_order_request(jsonb)` (defined once, in 18b; no fingerprint guards; called only by the website order form), keeping everything it does today (validation, phone rules, per-phone limit, de-duplication, header mirror, event, audit log) and adding:
   - an optional `designId` per line, validated: the design must exist, be active and belong to that line's product;
   - a product may repeat when its designs differ (pair uniqueness, as migration 28 already does for conversion); a repeat of the same product+design is still refused;
   - for every line, one row in `customer_order_request_lines` (`design_id`, `design_name`; empty when no design), exactly as app requests do.
   A payload without `designId` behaves exactly as today.
3. **Rollback file** restoring the 18b function and dropping the new one; **pre-guard** that refuses unless the live function text matches the 18b definition; **checks file** (case table above, plus wrong-product design, inactive design, duplicate pair, no-design payload, anon cannot read anything else, requests from the app still work, conversion keeps the design).

## Application changes (after approval, no further database work)
- `app/order/page.tsx`: per-line design select, shown only for products that have active designs; the "already chosen" rule becomes product+design pairs; payload sends `designId`.
- `lib/supabase/queries.ts`: `products.listDesigns()` calling the new function; `orderRequests.submit` sends `designId`.
- Tests: unit tests for the line rules and payload; jsdom test of the form; Staging checks and an end-to-end run; admin display verified in the Hub.

## Order of work if approved
Take a fresh Staging backup (the newest is 2026-10-18), then apply 32 to **Staging only**, run its checks, ship the form to the Preview, test two designs with two quantities end to end including the Hub display and conversion, then stop. Production only on a separate, explicit approval (fresh sealed backup first; the migration is not applied to Production by this proposal).

## Decisions needed from the owner
1. Approve migration 32 as described (function-only), applied to Staging first?
2. How will designs get created in Production: approve a small admin screen for designs (a separate feature), or will you add them with SQL when needed? Or are Nexus / Fire Ball / Phantom Blue meant to *be* the designs, in which case the existing form already does what is needed and nothing has to change?
3. Should the price shown in the dropdown stay per product (designs carry no list price of their own today; a design price exists only as a per-customer agreement)?
