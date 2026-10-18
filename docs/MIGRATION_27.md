# Migration 27 (price policy): apply, verify, roll back

**Status: a DRAFT applied to no database** (not Staging, not Production). Do not apply without the owner's explicit authorization; follow `docs/STAGING_RUNBOOK.md`. It sits on top of Migrations 25 and 26.

Files: `supabase/27_price_policy_no_expiry.sql` (generated from the text of `create_order` restored from Staging backup 20261017-165739Z (not read from live Staging) and the M26 text by `C:\EFZ-checks\P21\gen_m27.mjs`), `supabase/rollback/27_price_policy_no_expiry_rollback.sql`, `supabase/checks/27_price_policy_checks.sql` (55 checks), `supabase/checks/27_price_policy_concurrency.mjs` (12 checks, local only: it commits fixtures), `supabase/scheduler/27_price_daily_schedule.sql` (optional pg_cron job, not run by anything), `supabase/checks/27_preflight_live_definitions.sql` (read-only live check), `27_precondition_check.sh`, `27_rollback_chain_check.sh` (local only).

## The owner's confirmed rule (2026-10-18) and where each point is implemented and tested
| # | Rule | Implementation | Test |
|---|---|---|---|
| 1, 2 | An agreement without an end date stays in force until authorized staff change, revoke or end it; nothing expires it for being old | `effective_to is null` means open-ended in `_price_resolve` (M26); M27 adds nothing that expires and a mutation test proves a "365-day auto-expiry" would be caught | A1 (still the agreed price 400 days on and 10 years ahead), A3 (the daily run leaves it active, no notice, no alert), mutant M27 |
| 3 | Explicit end dates follow that date | M26 resolver: valid through the end date, list price the day after; staff can only bring an end date forward | B1, B2, B3 |
| 4 | The customer is told when an agreement is scheduled to expire | `_price_expiry_notices`: one customer notice per agreement and stage (within 30 days, within 7 days, after it ended), recorded in `price_agreement_notices` (insert-only). Triggered when the customer opens the catalogue and by `price_daily_run()` (service role; the `credit-daily` function calls it after the credit run; optional pg_cron job) | C1-C7, concurrency test (notice race) |
| 5 | Changes are authorized and audited: previous price, new price, reason, staff member, time | Pricing admins only (Super Admin / Manager). Every event now carries the agreement's price, product and design; a change records `previousPrice` and the new `unitPrice` with the reason; actor and time on the event and in `system_logs` | D1-D3 |
| 6 | Changes are prospective; orders, invoices, payments, revenue keep their prices | Order lines freeze list and charged price; M27 additionally keeps the current price in force until the day before a future-dated change starts | E0-E2, D4, concurrency tests 1-3 |
| 7 | An established verified agreement is never silently replaced by the list price | A pending, conflicting or unapproved-below-cost agreement blocks the line (app and staff) instead of falling back to list; a future-dated replacement no longer revokes the old price at once (this was a real gap found while writing the tests) | F7, D4 |
| 8 | Historical prices that do not establish a reliable agreement are flagged, not imported | `import_price_candidates` (M26): only consistent prices become *pending* candidates; everything else is a manual-confirmation case | M26 suite (import) |
| 9 | Android checkout and staff-created orders use the same server-side pricing function | `create_order` (and `create_order_with_terms` through it) now call `_price_resolve` as of the order date. No price typed = the agreed (else list) price. A different price for a customer with an agreement needs `priceOverrideReason` (10+ chars), is recorded as `staff_override` and audited as a WARNING. Customers without an agreement behave exactly as before. `resolve_order_price` lets the Hub form show the price | F1-F14, parity test F10 |
| 10 | Automated tests | 55 SQL checks, 12 concurrency checks, mutation test (see PROJECT_STATUS milestone 9), Hub browser checks O1-O7, edge tests | below |

## Review fixes (2026-10-18, second pass)
* **Precondition (H1):** the migration refuses to replace `create_order` / `convert_website_request` unless their stored text (CR removed, md5) is the expected pre-27 text or migration 27's own (safe retry). The expected values come from a restore of Staging backup 20261017-165739Z, **not from live Staging; H1 is therefore NOT fully resolved until `checks/27_preflight_live_definitions.sql` has been run on live Staging and matched.** Tested by `checks/27_precondition_check.sh`.
* **Rollback guards (H2):** rollback 26 refuses while 27 is applied; rollback 25 refuses while 26/27 are applied; rollback 27 refuses if 26 is missing. Tested by `checks/27_rollback_chain_check.sh`.
* **Request conversion (H3):** `convert_website_request` passes `priceOverrideReason` to `create_order` (same rules as staff orders; review-state lines block the conversion and leave the request `confirmed`). `convert_order_request` is a legacy path **not granted to any client role**; it sends no price, so the agreed (else list) price applies, and review-state lines block it. Customers without agreements: unchanged.
* **M1:** revoking a replacement that has not started continues the predecessor's terms with a new audited agreement (the predecessor's end date can never be extended, and nothing is rewritten). **M2:** an agreement whose successor takes over gets no "price ends" notice.
* **M4:** the resolver's review reason no longer mentions cost.
* **M3:** unchanged by design (see the runbook, "Review-state limitation").

## What it changes
* New table `price_agreement_notices` (RLS on, all client privileges revoked, update/delete blocked by trigger).
* `order_price_resolutions.source` also accepts `staff_override`.
* New functions: `_price_expiry_notices`, `price_daily_run` (service role only), `run_price_checks` (pricing admins), `resolve_order_price` (create_orders permission).
* Redefined: `create_order` (staff pricing), `replace_price_agreement` (future-dated changes), `_price_event` (richer events), `customer_catalog` (now volatile: it records the notices).
* Untouched: every existing order, line, payment, invoice, credit record and view.

## Verification after applying (Staging, guarded window)
Integrity baseline unchanged; suites 21, 22, 23, 25, 26, 27 and exposure pass (they roll back); credit OFF; staff order for a customer with no agreement gives exactly the old result; the Hub order form loads; `price_daily_run` is not scheduled.

## Rollback (tested on a data-rich local clone)
Order: **27, then 26, then 25.** After the three rollbacks on a clone holding 203 orders / 213 lines / 83 payments: all financial totals identical at every step, and every function definition identical to Migration 24 (compared with carriage returns removed: the stored text of `create_order` uses CRLF line endings, the restored text uses LF; behaviour is the same).
* **Lost by the M27 rollback (irreversible):** `price_agreement_notices` (which expiry notices were sent; the notices already placed in `customer_notifications` stay). Order lines resolved as `staff_override` are relabelled `agreement` in `order_price_resolutions` (their prices are untouched; the override reasons stay in `system_logs`). After rollback staff orders again take whatever price is typed.
* Losses of the M26 and M25 rollbacks are listed in `MIGRATION_26.md`.
