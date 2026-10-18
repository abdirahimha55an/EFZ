# Staging rollout runbook: Migrations 25 and 26 (PREPARED, NOT EXECUTED)

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
* Confirm `credit_policy.enabled = false` and no payment method enabled.
* Confirm no open credit orders / overdue invoices that Migration 25 rules would classify differently (the rehearsal on the Staging backup showed none).

## 3. Apply, in this order only (authorization needed for each)
1. `supabase/25_credit_policy_v2.sql` (single transaction). Credit stays OFF.
2. Post-apply checks for M25 (section 4). Only if all pass:
3. `supabase/26_customer_price_agreements.sql` (single transaction, depends on 25).
4. Post-apply checks for M26 (section 4).
Each file is one transaction: if it errors, nothing is applied. Do not edit the files; do not apply them out of order. Do **not** run the import in Save mode in this step.

## 4. Post-apply verification
* Integrity query equals the baseline exactly (orders, lines, payments, terms).
* Function fingerprint changes only by the objects named in the migration headers.
* Run, against Staging, only the suites that are designed to run there and roll back: `21_customer_accounts_checks.sql`, `23_customer_checkout_credit_checks.sql`, `25_credit_policy_v2_checks.sql`, `26_price_agreements_checks.sql`, `customer_data_exposure_checks.sql` (all roll back; the concurrency tests COMMIT fixtures and must never be run on Staging).
* Credit still OFF; payment methods still disabled; `credit_daily_run` not scheduled.
* Hub (pointed at Staging): Customer Prices page loads for Super Admin and Manager, refused for Officer; Customer Payments & Credit loads.
* Run the import in **dry-run** only and file the report; confirm no agreement exists yet.
* Customer app (Staging build): list prices unchanged for every customer.

## 5. Rollback (tested locally on a data-rich clone; ask before using)
* Do not roll back automatically. If a post-apply check fails, stop and report.
* Order: `supabase/rollback/26_customer_price_agreements_rollback.sql`, then `supabase/rollback/25_credit_policy_v2_rollback.sql`. Restore from the section 1 backup only if the owner chooses a restore.
* Local result: orders, lines, payments and credit accounts unchanged; function fingerprint identical to Migration 24.
* **History that would be lost:** M26: all agreements, agreement events and order price resolutions (export first). M25: defaults, credit events, due extensions, disputes, reminders, customer notifications, the seven policy columns; credit accounts with status `revoked` become `suspended`. The audit lines already written to `system_logs` remain.

## 6. Acceptance criteria
All of: integrity equals baseline; all listed suites pass on Staging; credit OFF and methods disabled; no customer sees a changed price; import dry-run report filed; Hub and app smoke checks pass; backup and result folders kept.

## 7. Separate authorizations still required afterwards (not part of this runbook)
Verifying real agreements and saving import candidates; enabling credit; scheduling `credit_daily_run` (pg_cron or the `credit-daily` function; steps in `CREDIT_SCHEDULER.md`); enabling any payment method; anything on Production; any push, merge or deploy.
