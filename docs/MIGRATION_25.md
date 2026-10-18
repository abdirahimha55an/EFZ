# Migration 25 (credit policy v2): apply, verify, roll back

**Status: a DRAFT applied to no database.** Do not apply it to Staging or Production without the owner's explicit authorization. Credit stays OFF throughout.

Files: `supabase/25_credit_policy_v2.sql`, `supabase/rollback/25_credit_policy_v2_rollback.sql`, `supabase/checks/25_credit_policy_v2_checks.sql` (135 checks), `supabase/checks/25_credit_concurrency.mjs` (13 checks, local only), `supabase/checks/customer_data_exposure_checks.sql` (18 checks), `supabase/scheduler/25_credit_daily_schedule.sql` (optional, separate).

## Prerequisites
Migration 24 applied (the file stops with a clear error otherwise). A fresh **sealed, restore-verified Staging backup** taken for this change, no drift, and the guarded apply window (the same procedure as migrations 22-24). Production is out of scope: it is still at migration 20.

## What it changes (no existing financial data)
Adds 7 settings columns to `credit_policy`; widens the credit-account status rule to include `revoked`; adds 6 tables (defaults, credit events, due-date extensions, disputes, reminders, customer notices) with every client privilege revoked, plus append-only guards; adds helper and admin/customer functions; redefines 10 existing functions (eligibility, summary, status, payment methods, place credit order, my_finance, set_credit_policy [same signature], set_customer_credit, credit_overview, credit_history); loads the approved proposal into an untouched policy row with credit OFF. Orders, payments, order creation and payment recording are untouched.

## Verification after applying (on Staging, in the guarded window)
1. Schema fingerprint after == the tested local result; baseline changes only by the pinned deltas; policy still `enabled = false`.
2. M21, M22, M23 suites and the M25 and exposure suites (rolled-back transactions).
3. Hub: the credit page shows the v2 panels for a Super Admin only.
4. Do **not** run the concurrency or mutation tests on Staging (they commit data or apply modified code); they are local-only by design.
5. Financial validation: integrity FAIL = 0 (its output was identical before and after the migration on the local clone).

## Rollback (tested locally only)
`supabase/rollback/25_credit_policy_v2_rollback.sql` restores the exact migration-23/24 definitions of the ten functions, drops everything migration 25 added and restores the narrower status rule. **Tested on a disposable local database restored to the M25 state, including after real defaults, disputes and concurrent orders existed**: the schema fingerprint (functions, columns, constraints, triggers, policies, ACLs, indexes) is **identical** to the pre-M25 database, it can be run twice, the M21 (81), M22 (33), M23 (97) and M24 (62) suites pass afterwards, M25 re-applies and passes, and the order, payment and outstanding totals were unchanged.
**Data-loss and irreversible effects (read before ever running it):**
* The six tables are **dropped with their rows**: the default history, credit events, extensions, disputes, reminders and customer notices. **Export them first** if any real record exists. Their audit lines in `system_logs` stay.
* The seven policy columns are dropped; the proposal values in the shared columns are cleared only while the row is still the untouched proposal.
* `revoked` accounts become `suspended`. After rollback the migration-24 behaviour returns: paying an overdue invoice would restore credit and a default is forgotten.
* Never run it on Staging merely to test it; use a disposable copy.

## Deployment checklist (nothing below has been done)
- [ ] Owner reviews this migration, the policy document and the decisions in `docs/CREDIT_POLICY.md`.
- [ ] Owner authorizes applying migration 25 to **Staging** (fresh backup + restore verification first).
- [ ] Apply and verify in the guarded window; keep credit OFF.
- [ ] Choose and test the scheduler (`docs/CREDIT_SCHEDULER.md`) on Staging; confirm reminders end to end.
- [ ] Verify the Hub page, permissions and the Android app against the migrated Staging (replace the mock-backed browser checks with real ones).
- [ ] Real-device Android testing.
- [ ] Decide the open policy questions; **separately authorize activation** on Staging with a synthetic customer.
- [ ] Only then consider Production (apply migrations 21-25 there is a separate project with its own backup, rollback and approval).
- [ ] EVC Plus and eDahab remain **unavailable for real payments** until each provider is contracted, its integration is verified against the provider's sandbox and a supervised small live payment has been checked (see `docs/PAYMENT_PROVIDERS.md`).
