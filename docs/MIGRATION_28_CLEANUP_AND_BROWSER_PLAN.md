# Migration 28 - Staging cleanup proposal and browser verification plan

Status: PROPOSAL ONLY. Nothing below has been executed. Staging project `adjjamiqwboawqedaapi`. Production is never involved.

## 1. What the concurrency test left on Staging (verified read-only)

| Record | Detail |
|---|---|
| `customers` `cust-t28-conc` | "TEST-28 Concurrency customer", active, owner `u-stg-officer1`, registered by `u-stg-admin` |
| `order_requests` `ebba9830-923b-4659-8ce7-07cff8d267a6` | "TEST-28 Visitor", status `converted`, `converted_order_id = ORD-4877625`, handled by `u-stg-manager` |
| `order_request_items` | 1 row (Nexus x1) |
| `order_request_events` | 3 rows: submitted (rpc), status_changed new -> confirmed, converted |
| `orders` `ORD-4877625` | **pending**, unpaid, stock_mode `at_delivery`, total 12.00, cost 6.70, created by `u-stg-manager` |
| `order_items` | 1 row (Nexus x1 at 12.00) |
| `order_price_resolutions` | 1 row, source `list`, applied 12.00 |
| `system_logs` | 4 rows: request received, request confirmed, order created, request converted |

Checked and EMPTY for these records: payments, commissions, stock movements, delivery lines, delivered-quantity adjustments, below-cost overrides, bonus entitlements / events, credit tables, customer notifications, request notes, price agreements, notifications (alert rows).

Inventory effect: only a **reservation**. Nexus stock is 62 (unchanged); promised to open orders is 4, of which 1 is this order. Nothing was deducted (stock leaves the shelf only on delivery).
Reporting effect while it stays pending: `product_sales` and `daily_sales` count every non-cancelled order, so this order adds 1 unit / 12.00 / 6.70 cost to Nexus sales on Staging.

## 2. Can it be removed? (read from the live Staging definitions)

**Hard delete: not supported, and not safe.**
* `order_price_resolutions` rows are append-only (`guard_credit_history`: "rows are never deleted"). Deleting the order would leave that row orphaned (it has no foreign key to cascade).
* `system_logs` rows (audit) have no foreign key either and would dangle.
* `order_request_events` / `order_request_items` are append-only children; they only go with their parent request, and a converted request is never meant to be deleted.
* The app's delete guards only apply to client calls (`is_client_request()`); a direct superuser delete bypasses them, which is exactly why it must not be used: it would silently break the audit trail the guards protect.
* A customer with orders cannot be deleted by design: "archive it instead".

**Cancellation: supported.** `update_order_status(order, 'cancelled', reason)`: `pending -> cancelled` is a normal transition; a Manager (permission `edit_orders`) can do it; it is not "locked" (no payments, no paid commission).
Effects, read from the function:
1. `orders.status = 'cancelled'`, `cancelled_at = now()`, `updated_at` bumped. No other column changes.
2. Stock: none. This order is `at_delivery` and nothing was delivered (the stock-return branch is only for old `at_creation` orders).
3. One `system_logs` row (INFO, category ORDER): "Order ORD-4877625 status changed from pending to cancelled", with the reason.
4. `bonus_on_order_cancelled` runs `bonus_refresh(cust-t28-conc)`. **Measured in the rollback rehearsal:** it inserts one `customer_bonus_entitlements` row for the test customer, already DECIDED as `not_eligible` (era `unconfirmed`, 1 ball ordered; no holder order, no commission), and writes **one `commission_bonus_events` row** (`determined`, undetermined -> not_eligible, no amount). Both are permanent history rows. (An earlier draft of this document wrongly predicted `undetermined` and no event.)
5. Reporting: `product_sales` and `daily_sales` exclude cancelled orders again; promised-to-open-orders for Nexus drops 4 -> 3.
6. The converted request keeps its link to the (now cancelled) order. History is preserved by design. The order stays visible in Order Tracking as cancelled.

## 3. Proposed cleanup (needs your approval; not executed)

**Step 0 - rehearsal (DONE 2026-10-19, rolled back, 14/14 checks; script `supabase/checks/28_integration/rehearse_cancel.sql`).** Ran the Manager cancellation of the real record inside a transaction that was rolled back and measured it. Results: status pending -> cancelled with `cancelled_at`; Nexus promised units 4 -> 3, stock 62 unchanged, no stock movement; `product_sales` Nexus -1 unit / -12.00 / -6.70 cost / -1 order; `daily_sales` for 2026-10-19 disappears (the test order was that day's only active order); one INFO/ORDER log row by the Manager with the reason; one `not_eligible` entitlement row and one `determined` bonus event; order line, price resolution, request, request events, request logs and customer byte-for-byte unchanged; cancelling twice is a no-op; a Manager cannot reactivate it. Afterwards the order was still pending and the Staging fingerprint identical (19/19).

**Step 1 - cancel the order (recommended).** As `u-stg-manager` (or in the Hub as a Manager on a preview): `update_order_status('ORD-4877625', 'cancelled', 'TEST-28 concurrency test order: synthetic, cancelled after the Migration 28 integration run')`.
Expected net change (measured in the rehearsal): 1 order updated, 1 log row added, 1 bonus-entitlement row added, 1 bonus event added. Nothing deleted.

**Step 2 - archive the test customer (optional).** Set `cust-t28-conc` to `archived` (the Hub's Archive action / `customers.update(status = 'archived')`; the app allows this and rejects deletion). It then drops out of the active customer list. The order and request stay linked to it.

**Step 3 - verify (read-only).** Re-run `supabase/checks/28_fingerprint.sql`. Expected: schema values identical; `orders`, `system_logs` changed; a new `customer_bonus_entitlements` row and a new `commission_bonus_events` row; everything else identical. Re-run `28_post_deploy.sql`.

**Not proposed:** deleting any row, editing `status` directly, touching the request, price resolution, events or logs. Those records are the audit evidence of the test; leaving them (with the order cancelled and the customer archived) is the supported end state.
Alternative: leave everything as is. Impact: 1 pending order keeps reserving 1 Nexus and counts 12.00 in Staging sales until someone cancels it.

## 4. Hub preview feasibility (verified, nothing pushed)

* Vercel builds every pushed branch as a **Preview**. Evidence: the GitHub deployments for this branch's earlier commits (`4cc64bf`, `557538e`, `81851fe`) are all `environment = Preview`, `production_environment = false`. Production deploys only from `main`.
* `next.config.ts` refuses to build any non-production Vercel deployment whose `NEXT_PUBLIC_SUPABASE_URL` is not the Staging project. Tested here by simulating a preview build: Staging URL passes; the Production URL and an empty URL are both refused.
* I cannot read the Vercel project's stored environment values (and did not try). The guard makes a Production-pointing preview impossible to build; the earlier successful previews show the stored value is Staging.
* Needed from you: approval to **push** `android/customer-accounts` (5 commits ahead of origin; pushing triggers a Preview build only), and a Staging staff login for the browser run.

## 5. Browser verification checklist (Staging preview, synthetic data only)

Requires approval of the test data first. Proposed synthetic records (all `TEST-28`, committed this time because the browser needs them): 4 customers (A agreement, B design agreement, C list, D pending agreement), 1 extra design "TEST-28 Blue" on Fire Ball (also visible in the customer app until deactivated), agreements A: Nexus 10.00; B: Fire Ball + Red design 9.50; one pending agreement for D: Nexus 9.00; about 8 confirmed website requests; at most 5 orders result. Everything is cleaned up afterwards by cancelling/archiving, never deleting.

Sign in as a Manager, open Website Requests, open a confirmed TEST-28 request, press Convert.

| # | Case | Do | Expect in the dialog | Expect in the database (read-only check) |
|---|---|---|---|---|
| 1 | List price | pick customer C, Nexus x2 | badge "List price", price 12.00, no reason box, button "Create order" | order line 12.00, resolution `list` |
| 2a | Product agreement | customer A, Nexus x3 | "Agreed price", 10.00 | 10.00, resolution `agreement` + agreement id |
| 2b | Design agreement | request line with the Red design, customer B | "Design: E2E Red Design" chip + "Agreed price" 9.50 | design_name 'E2E Red Design', resolution design_id = Red, 9.50 |
| 3 | Failed lookup + Retry | open the dialog, DevTools > Network: block `resolve_order_price` (or go offline), pick a customer | red text "We could not check this customer's price for this product. Nothing was assumed - press Retry.", empty price box, **Create disabled**, Retry button | nothing written. Unblock, press Retry: badge appears, Create enables |
| 4 | Review blocking | customer D (pending agreement), Nexus | red "...needs to be confirmed first (an agreement is waiting to be verified)", price box disabled, Create disabled | nothing written |
| 5 | Override + reason | customer A, type 8.00 | "Price changed (agreed $10.00)", amber box "Price override..." with a table: product, qty, agreed 10.00, proposed 8.00, difference -$2.00 (-$2.00 each), button "Create order with price override" **disabled** until a reason of 10+ characters; 9 characters stays disabled; "Use the agreed price" link clears it | with reason: resolution `staff_override`, WARNING log with agreed 10 / charged 8 / reason |
| 6 | Several designs | a request/lines with Red and Blue on Fire Ball (add a line, choose the same product with the design) | two lines, each with its design chip and its own price; stock check is joint (3 available) | two order items with design names, two resolution rows |
| 7 | Customer switch | customer A, type a price, then pick customer C | price box and "Price changed" cleared, lookup re-asked, shows C's list price; no reason box | nothing written |
| 8 | No double conversion | convert once; reopen the same request (or two tabs) | Convert is no longer offered for a converted request; a second tab gets "already converted to order ..." | one order for the request |

Also check in both light and dark mode (the dialog reuses the shared theme), and that no console errors appear.
