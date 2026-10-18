# Staging rollout runbook: Migrations 25, 26 and 27 (PREPARED, NOT EXECUTED)

**Nothing in this file has been run.** Staging `adjjamiqwboawqedaapi` is still at Migration 24 (credit OFF, no payment method enabled). Production is untouched and is out of scope. Every step below needs the owner's explicit written authorization for that step; approval of one step is not approval of the next. The Staging database password is entered only at the secure PowerShell prompt, never in chat, files or logs.

## 0. Preconditions
* Branch `android/customer-accounts` committed and clean; Hub tests, app tests and all database suites green (see PROJECT_STATUS milestone 7).
* The owner has read `docs/MIGRATION_25.md`, `docs/MIGRATION_26.md`, `docs/CUSTOMER_PRICING.md` and decided the questions listed in `docs/PROJECT_STATUS.md` ("Decisions needed").
* Nobody else is changing Staging; announce a window.

## 1. Fresh backup (authorization needed)
1. Take a full logical backup of Staging (schema + data, including `auth`) with the established backup script; seal it (checksum) in `C:\EFZ-backups\staging\<UTC stamp>`.
2. Restore the backup into a LOCAL disposable database with the restore drill and compare row counts: it must match Staging. The previous backup (20261017-165739Z) is **not** acceptable now unless nothing has changed since; take a new one.
3. Record the baseline integrity figures (the query used in the rehearsal): orders count/sum, order lines count/sum (charged and standard), payments count/sum, `order_payment_terms` count, credit accounts and credit orders.

## 2. Preflight (read-only on Staging)
* Confirm the target URL contains `adjjamiqwboawqedaapi` and not `rodmdvfjashiohgwople`.
* Run `supabase/checks/21_function_fingerprint.sql`-style fingerprint (`fp24.sql`): it must equal the recorded Migration 24 fingerprint (`functions|168|6d7d19fc1058a19315d39454e2d4f742` on the local reference). A difference means Staging drifted: stop and investigate.
* **Live definition check for migration 27 (mandatory, read-only).** Run `supabase/checks/27_preflight_live_definitions.sql` on Staging through the established secure read-only procedure (the Staging password only at the secure prompt). `create_order` and `convert_website_request` must show `matches_pre27 = true` (md5 of the stored definition with carriage returns removed: `bad8d28eac60a8243e6bba614f6191a1` and `bc32b50df6f50e37e6759086a1f6dd1c`), and `convert_order_request` must show `true`. These expected values come from a restore of backup 20261017-165739Z, **not** from the live database: until this query has been run on live Staging the match is unverified. A `false` is a **stop condition** (Staging drifted; do not apply; send the full definitions for review). Migration 27 also checks this itself and refuses to replace a definition it was not written against.
* Confirm `credit_policy.enabled = false` and no payment method enabled.
* Fingerprints are compared with carriage returns removed (the stored text of `create_order` uses CRLF; the migration-27 text uses LF). Record the whole-schema fingerprint (`fp24.sql`) before each migration and after each, and compare only the objects each migration header names.
* Confirm no open credit orders / overdue invoices that Migration 25 rules would classify differently (the rehearsal on the Staging backup showed none).

## 3. Apply, in this order only (authorization needed for each)
1. `supabase/25_credit_policy_v2.sql` (single transaction). Credit stays OFF.
2. Post-apply checks for M25 (section 4). Only if all pass:
3. `supabase/26_customer_price_agreements.sql` (single transaction, depends on 25).
4. Post-apply checks for M26 (section 4). Only if all pass:
5. `supabase/27_price_policy_no_expiry.sql` (single transaction, depends on 26; it redefines the staff `create_order`: check it against the live text first, see below).
6. Post-apply checks for M27 (section 4), plus: a staff order for a customer with no agreement yields exactly the old price, and the Hub order form still opens.
Each file is one transaction: if it errors, nothing is applied. Migration 27 additionally refuses to run if the live `create_order` / `convert_website_request` differ from what it was written against (that is a stop condition, not something to work around).

### Hub sequencing (migration 27 changes what staff orders accept)
* **Deploy the Hub build that contains the migration-27 order form together with migration 27 (same window), or apply migration 27 only while Staging holds NO price agreements.** The previous Hub always sends `actualUnitPrice`; once any customer has an agreement, that Hub's order for that customer is refused ("give a priceOverrideReason") and the user cannot supply one. With the new Hub the form shows the agreed price, sends no price unless the user types one, and asks for the reason.
* Do not save import candidates (pending agreements) before the new Hub is live: a pending agreement blocks that product for that customer in **both** the app and staff orders (see "Review-state limitation" below).
* The website-request conversion (`convert_website_request`) now accepts `priceOverrideReason` in its payload; the Hub inbox screen does not show a field for it yet (there is no conversion screen in this build). Until one exists, converting a request at a price that differs from a customer's agreed price must be done by creating the order from the order form instead. Do not edit the files; do not apply them out of order. Do **not** run the import in Save mode in this step.

## 4. Post-apply verification
* Integrity query equals the baseline exactly (orders, lines, payments, terms).
* Function fingerprint changes only by the objects named in the migration headers.
* Run, against Staging, only the suites that are designed to run there and roll back: `21_customer_accounts_checks.sql`, `23_customer_checkout_credit_checks.sql`, `25_credit_policy_v2_checks.sql`, `26_price_agreements_checks.sql`, `27_price_policy_checks.sql`, `customer_data_exposure_checks.sql` (all roll back; the concurrency tests COMMIT fixtures and must never be run on Staging).
* Credit still OFF; payment methods still disabled; `credit_daily_run` and `price_daily_run` not scheduled.
* Re-run the live-definition query: after migration 27 `create_order` must show `matches_27 = true` (`265e9745acb9418787e6d8cebfb450af`) and `convert_website_request` `matches_27 = true` (`fe992c8ab3edc37522d08e3e6eb41c9c`).

### Guarded test window and what the Staging test runs lock
The 26 and 27 suites (and 21, 23, 25 in part) start by running `alter table orders disable trigger user` and a mass `update orders` **inside a transaction that is rolled back at the end**. For the duration of a suite that takes a lock that **blocks every concurrent write to `orders`** (and scans all real orders), and it inserts fixture users and customers (rolled back). Run them only in the announced window with nobody using the Hub, one suite at a time, never leave a psql session open between suites, and stop at once if any suite aborts (an aborted session rolls back, but confirm no session is left open with `select * from pg_stat_activity where state like 'idle in transaction%'`). The concurrency scripts (`*_concurrency.mjs`) **commit** their fixtures and must never be run on Staging.
* Hub (pointed at Staging): Customer Prices page loads for Super Admin and Manager, refused for Officer; Customer Payments & Credit loads.
* Run the import in **dry-run** only and file the report; confirm no agreement exists yet.
* Customer app (Staging build): list prices unchanged for every customer.

## 5. Rollback (tested locally on a data-rich clone; ask before using)
* The rollback scripts now **enforce the order**: the 26 rollback refuses while migration 27 is applied, the 25 rollback refuses while 26 or 27 is applied, and the 27 rollback refuses if the migration-26 objects are gone; a refused script changes nothing. Do not try to bypass the guard.
* Do not roll back automatically. If a post-apply check fails, stop and report.
* Order: `supabase/rollback/27_price_policy_no_expiry_rollback.sql`, then `26_customer_price_agreements_rollback.sql`, then `25_credit_policy_v2_rollback.sql`. Restore from the section 1 backup only if the owner chooses a restore.
* The restored `create_order` / `convert_website_request` text is the one in the backup the migration was written against. If the live definitions had drifted, the migration refuses to apply, so the rollback can never overwrite something it did not replace.
* Local result: orders, lines, payments and credit accounts unchanged; function fingerprint identical to Migration 24.
* **History that would be lost:** M27: the record of which expiry notices were sent (notices already delivered stay). M26: all agreements, agreement events and order price resolutions (export first). M25: defaults, credit events, due extensions, disputes, reminders, customer notifications, the seven policy columns; credit accounts with status `revoked` become `suspended`. The audit lines already written to `system_logs` remain.

## 6. Acceptance criteria
(In addition: the live-definition query matched before and after, and the Hub sequencing above was followed.)
All of: integrity equals baseline; all listed suites pass on Staging; credit OFF and methods disabled; no customer sees a changed price; import dry-run report filed; Hub and app smoke checks pass; backup and result folders kept.

## Review-state limitation (migration 27, intentional)
A product/customer pair whose price is in the **review** state (an agreement waiting for verification, or an agreed price that is now below cost and was never approved) **cannot be ordered by anyone** — not in the app, not by staff, not even by a Super Admin, and there is deliberately no bypass or override. The staff error says only that the price needs confirming (it never mentions cost to staff without cost permissions). **Authorized resolution path:** a Super Admin or Manager opens **Customer Prices**, then verifies the agreement (a below-cost price needs a Super Admin and a reason), rejects it, or revokes/replaces it; the order can then be placed. Until then the business can sell that item to that customer only after the agreement is resolved.

## 7. Separate authorizations still required afterwards (not part of this runbook)
Verifying real agreements and saving import candidates; enabling credit; scheduling `credit_daily_run` (pg_cron or the `credit-daily` function; steps in `CREDIT_SCHEDULER.md`); enabling any payment method; anything on Production; any push, merge or deploy.
