# Migration 26 (customer price agreements): apply, verify, roll back

**Status: a DRAFT applied to no database.** Not on Staging, not on Production. Do not apply without the owner's explicit authorization; follow `docs/STAGING_RUNBOOK.md`. Product behaviour and decisions: `docs/CUSTOMER_PRICING.md`.

Files: `supabase/26_customer_price_agreements.sql`, `supabase/rollback/26_customer_price_agreements_rollback.sql`, `supabase/checks/26_price_agreements_checks.sql` (63 checks), `supabase/checks/26_price_concurrency.mjs` (11 checks, local only: it commits fixtures), exposure checks (19).

## Prerequisites
Migration 25 applied (the file stops with a clear error otherwise). A sealed, restore-verified backup, no drift, a guarded window.

## What it changes
* Adds 3 tables with every client privilege revoked: `customer_price_agreements`, `price_agreement_events` (append-only), `order_price_resolutions`.
* Adds the internal resolver `_price_resolve`, the admin functions (create / replace / verify / reject / revoke / end / list / history / alerts / import), `resolve_customer_price` (staff) and `my_price_agreements`.
* Replaces the customer catalogue, designs, price-preview, checkout and credit-order functions so that each line is priced by the server from the agreement (or list) price, and records which agreement produced it.
* Does **not** change any existing order, line, payment, invoice or the staff `create_order`.

## Verification after applying
Integrity query (orders, lines, payments, terms) equals the pre-apply baseline; fingerprint changes only by the objects above; suites 21, 22, 23, 25, 26 and exposure pass (they roll back); import in **dry-run** only; customers still see list prices because no agreement exists yet.

## Rollback (tested on a data-rich local clone)
Run `rollback/26_...` then, if needed, `rollback/25_...`.
* Result: orders (107 / $2,783.00), lines (117 / $2,783.00 charged, $2,848.00 standard), payments (87 / $1,414.35) and payment terms identical before and after each rollback; after both, the function fingerprint equals Migration 24 exactly (one leftover function seen in the first comparison was a helper that the concurrency test itself creates, `t26c_active`, not a migration object).
* **Lost by the M26 rollback (irreversible, export first):** all agreements (46 in the test clone), their events (87), and the per-line price resolutions (12). Order lines keep the list price and the charged price, so history, invoices and revenue are unaffected. The audit lines in `system_logs` stay.
* **After M26 rollback the app prices every line at the list price again:** customers with negotiated prices would pay more online. Do not roll back while agreements are in use unless the customer app is paused.
* **Lost by the M25 rollback (irreversible, export first):** defaults (the permanent default history), credit events, due-date extensions, disputes, reminders, customer notifications, and the seven new policy columns; accounts with status `revoked` become `suspended`; after rollback paying an overdue invoice would restore credit again (the M24 rule). Orders, payments and credit accounts are unchanged. In the test clone this removed 1 default, 15 credit events, 1 dispute and 3 reminders; credit accounts (6) and credit orders (6) were intact.

## Equivalent mutation survivors (documented, not hidden)
* M25 **M26 "a defaulted invoice can be extended"**: an invoice is defaulted only when it was overdue and unpaid on its due date; extending is allowed only for an invoice that is not yet due and unpaid, so the two states never co-exist. Removing the explicit check changes no reachable outcome.
* M25 **C2 "credit placement takes no per-customer lock"**: every path that takes the per-customer lock first takes the company-wide lock, which already serializes all credit placements; the extra lock adds nothing observable (the concurrency tests with 8 simultaneous orders for one customer pass without it).
* M26 **M42 "an agreement can be end-dated later"**: the table guard trigger rejects any later or removed end date, so the function-level check is redundant (kept for its clear message).
