# EFZ Hub - Project status

Last verified: 2026-10-17 (branch `android/customer-accounts`, based on `origin/main` = `c1e873b`).
Sources: the repository, git history, the migration files and the recorded evidence of earlier releases. Production
state below is **as last reported by the owner's and Claude's read-only checks**, not re-inspected for this document.
This file did not exist before; the repository's only other status file, `PROJECT_STATE.md.txt`, is empty and was left untouched.

## Live in Production (`main` = `c1e873b`)

| Area | State |
| --- | --- |
| Security hardening (migrations 08-11, 14, 19c Part A) | Live. Auth sign-up disabled (owner, 2026-10-02). |
| Orders, deliveries, per-ball commission model (12), eligibility (16), officer experience (13) | Live. |
| Realtime alerts (15), audit trail + export, sales analytics, Financial Management | Live. No known defect. |
| Website order-request inbox (18a/b/c) | Live. Delegated handling (19, 19b) is built and Staging-tested but **not** on `main`/Production. |
| Payment terms, invoices and receipts (20) | Live. Invoice/receipt links open in the same tab with a Back control. |
| Legacy payment-terms review screen (`/admin/terms-review`, Super Admin) | Live. 21 of 29 legacy orders classified; 7 delivered orders (`EFZ-*`) await a business decision; `ORD-7165077` is cancelled and intentionally not listed. |

## In progress: Android customer app, Phase 1 - secure customer accounts (this branch, NOT released)

Nothing below is merged, pushed or deployed. **Migration 21 has not been applied to Production.**

| Item | Status |
| --- | --- |
| `supabase/21_customer_accounts.sql` (+ rollback) | Written. Applied and tested on local Staging- and Production-shaped restores (see Tests). Staging apply: see "Staging" below. |
| Auth trigger corrected | Written and tested: unknown sign-ups never get a staff profile; customer registrations (`app_metadata.efz_kind = 'customer'`) are never linked to staff. |
| Approval workflow (approve / reject / suspend / reinstate, audited, permission `manage_customer_accounts`, reserved to Super Admin) | Written and tested. **No Hub screen yet** (out of scope for this phase). |
| Customer read access (`my_customer_account`, `customer_catalog`, `my_orders`) | Written and tested. Public website catalog (`public_products`) unchanged. |
| Registration Edge Function `supabase/functions/register-customer` | Written, unit- and integration-tested locally. **Cannot be deployed from this workstation** (see Blockers). |
| Expo/React Native app, push notifications, checkout, design catalog, Hub approval screen | Not started (explicitly out of scope). |

### Tests (all run locally unless marked)

- `supabase/checks/21_customer_accounts_checks.sql`: 80 checks against real RLS/grants as the actual `anon` / `authenticated` / `service_role` roles with simulated JWTs; transaction rolled back. 80/80 PASS on a Staging-shaped and a Production-shaped local restore.
- Mutation test (`C:\EFZ-checks\P21\mutation_test.mjs`, outside the repo): 9 deliberate security regressions (old trigger rule, anon read, no approval check, unscoped orders, no verification flag, no transition guard, no permission check, unreserved permission, suspended treated as approved) were each caught by the suite.
- `supabase/checks/21_function_fingerprint.sql` before/after: exactly four existing functions changed (`link_auth_user_to_profile`, `handle_new_auth_user`, `handle_auth_user_confirmed`, `reserved_permissions`); no RLS policy or table ACL of any existing table changed; `create_order`, `create_order_with_terms`, `record_payment`, `update_order_status`, `set_order_payment_terms`, `submit_order_request`, `convert_website_request` are byte-identical.
- `npm run test:registration`: 13 handler unit tests PASS; 5 integration tests (real local database) PASS.
- Typecheck passes; lint adds no new error (the repository has pre-existing lint errors in files this work does not touch).

### Staging

**Migration 21 is applied to Staging (2026-10-17 07:43Z) and verified.** Production is untouched.

- Target proven before any write: sealed Staging backup `20261017-073736Z` (BRACKET OK, restore-verified exit 0), connection identity (user/host/TLS) and Staging markers `5|Super Admin/active|0|0`, live baseline identical to the backup (no drift), Migration 21 absent.
- Applied once, in one transaction (exit 0). No rollback run, no retry.
- Fingerprint of all 226 public functions / policies / table ACLs / auth triggers before and after: only `link_auth_user_to_profile`, `handle_new_auth_user`, `handle_auth_user_confirmed`, `reserved_permissions` changed; exactly the 20 expected objects were added; nothing else differs (create_order, create_order_with_terms, record_payment, update_order_status, set_order_payment_terms, submit_order_request, convert_website_request unchanged).
- Business data baseline (51 rows: orders, payments, customers, products, commissions, ...) unchanged apart from the pinned deltas (functions +16, policies +2, tables +2, RLS tables +2, triggers +3, permissions +1, two new EMPTY tables).
- 80-check security and regression suite run ON Staging (rolled back, synthetic rows only): 80 PASS, 0 FAIL. `validate_financials`: 0 integrity FAIL (4 WARN, as before).
- State after: `customer_accounts` and `customer_account_events` exist and are empty (the suite's rows were rolled back); no customer account was created on Staging.
- Evidence: `C:\EFZ-checks\P21\staging\APPLY21_20261017-074356Z` (status.txt, fingerprints, baselines, checks.txt). Not exercised on Staging: the Edge Function (cannot be deployed, see Blockers) and a real approval through the app (no Hub screen yet).

Pinned file hashes (sha256): 21_customer_accounts.sql `708da602...`, rollback `fe4aa654...`, checks `479708d5...`, fingerprint `7bcde5d7...`.

### Blockers and decisions still open

1. **Edge Function deployment**: needs the Supabase CLI (not installed), a Supabase access token, the function secret `REGISTRATION_HINT_SALT`, and deployment with `--no-verify-jwt`. No such infrastructure exists on this workstation, so nothing was invented.
2. **Email ownership is not verified at registration** (the Admin API creates a confirmed user). EFZ's phone/identity verification at approval is the control; a verification email should be added before launch.
3. **Rate-limit side effects**: 3 registrations per phone and 300 per day overall can be exhausted by an attacker (a registration denial of service); acceptable for Phase 1, revisit with CAPTCHA.
4. **Commission ownership** for self-registered customers is deliberately unassigned; the business rule is undecided.
5. A CRM customer can be linked to at most one app account (partial unique index) and cannot be deleted while linked.
6. Customer account deletion (a Google Play requirement) and password reset are not built.

## Milestone 2: Hub customer-account review screen (this branch, NOT released, Staging-tested)

New screen **Customer App Accounts** (`/admin/customer-accounts`, sidebar entry only for holders of `manage_customer_accounts`; Super Admin always). It lists registrations
(pending first, oldest first; filters + search), shows the registration details, the masked-phone CRM matches, the account history, and offers Approve / Reject
(pending), Suspend (approved), Reinstate (suspended). A rejected account is final. All rules stay in the Migration 21 functions; the page only calls them and shows their sentence.

- **Authorization:** the page hides itself without the permission, but the control is the database: without `manage_customer_accounts` the account tables return no rows and every review function is refused (403). Verified on Staging for an officer and a manager.
- **Linking safety:** nothing is preselected. Linking an existing CRM customer needs the explicit "I verified this person" box plus a note; creating a new customer when the phone already matches someone needs the "different person" confirmation. No commission owner is ever assigned.
- **Data shown:** only the registration details, masked phones and history. Never loaded: the address hash, auth user id, canonical phone, orders or any other customer's data (asserted on the actual network responses).
- **Files:** `app/admin/customer-accounts/page.tsx`, `lib/customerAccounts.ts` (presentation helpers) and `lib/customerAccounts.test.ts`, `lib/supabase/queries.ts` (+ `customerAccounts` API), `lib/supabase/database.types.ts`, `lib/types/index.ts`, `lib/permissions.ts` (`manageCustomerAccounts` flag), `app/admin/layout.tsx` (sidebar), `scripts/test-loader.mjs` + `scripts/register-test-loader.mjs` (lets Node's test runner import the TypeScript), `package.json` (`test:hub`), `tsconfig.json` (test files excluded from the web typecheck). Existing staff-user management is unchanged apart from the new permission appearing in its list.

### Milestone 2 tests

| Test | Result |
| --- | --- |
| `npm run test:hub`: 16 tests (permission flag, offered actions, approval/verification gating, phone-match rules, list safety, query-layer calls and error sentences) | 16/16 PASS. A deliberate removal of the verification gate made it fail, then the code was restored. |
| `npm run test:registration` (Edge Function handler) | 13 unit PASS; 5 integration PASS against a local database (18/18); the integration tests are skipped without `EFZ_TEST_PG`. |
| `supabase/checks/21_customer_accounts_checks.sql` re-run on a local copy of the Staging backup | 80/80 PASS (Migration 21 unchanged in this milestone). |
| Browser tests against real Staging (`C:\EFZ-checks\P21\staging_ui_results.log`), 10 tests | 10/10 PASS (T10 first failed on my own allowlist, which omitted the read-only lookup and the existing sign-in audit line; corrected and re-run: PASS). Covers: officer and manager without the permission (no menu entry, denied page, no rows, functions refused 403); list/filters/search and no sensitive columns; link flow with masked match and verification gating (customer owner stays NULL, event + database audit line written); create flow (new unassigned customer); reject (reason required, final); suspend + reinstate (history complete); stale-screen error shows the database's sentence and refreshes; a manager granted the permission can review and revoking it removes access (permissions restored to the original set); empty and load-error states (responses mocked); orders/payments/balances identical before and after. |
| Typecheck, lint on changed files, webpack production build | PASS (0 new lint errors). Turbopack build was not run (the worktree's `node_modules` is a link, which Turbopack rejects). |

Staging changes made for the tests (synthetic, left in place): 5 registrations through the real registration function (`e2e21-*@example.test`), 1 synthetic CRM customer `cust-e2e21-match`, and the outcomes of the tests (3 approved incl. one reinstated, 2 rejected; 2 new CRM customers `cust-...` with no commission owner). The manager's permissions were changed and restored to the original set (the audit trail shows both changes). Seed evidence: `C:\EFZ-checks\P21\staging\SEED21_*`.

## Milestone 3: Edge Function deployment readiness and Expo plan (this branch, NOT released; nothing deployed)

Verified 2026-10-17 (no credential was read, printed or used; nothing on Supabase was changed):

| Prerequisite for deploying `register-customer` to Staging | Verified status |
| --- | --- |
| Supabase CLI | **Missing** (not on PATH; no `~/.supabase`). Latest on npm: `supabase@2.121.0`. |
| Authentication | **Missing**: `SUPABASE_ACCESS_TOKEN` not set, no Supabase entry in the Windows credential store. Owner must run `supabase login`. |
| Edge Functions on the project's plan | Gateway **reachable** on Staging (`GET /functions/v1/register-customer` -> 404 "Requested function was not found", i.e. live, function not deployed). Plan tier **not readable** without the token. Supabase's docs include Edge Functions on Free (500K invocations/org/month) and Pro/Team (2M): not expected to block. |
| Staging Auth sign-up | **Disabled** (`disable_signup: true`). |
| Secret `REGISTRATION_HINT_SALT` | Not set. `deploy-staging.ps1 -Deploy` generates it, passes it through an owner-only temp file to `supabase secrets set --env-file`, deletes the file; the value is never shown or put on a command line. |
| Custom SMTP and code email templates | **Not verified**; needed only for email verification/recovery. The built-in sender is about 2 emails per hour project-wide, which would block registrations. |

**Decision: deployment stops here.** The CLI, login and secret are missing, so nothing was deployed or configured. Prepared instead:
- `supabase/functions/register-customer/deploy-staging.ps1` (owner-run): preflight (CLI, login, Staging visible, sign-up disabled, tests pass; changes nothing), `-Deploy`, `-Smoke`. It refuses the Production ref. Syntax-checked and run here: it stops at the missing CLI and changes nothing.
- README rewritten with the verified prerequisite table, safe secret provisioning, the deploy/smoke procedure and expected responses.
- **Email confirmation / password recovery proposal** (smallest secure option, documented in the README): custom SMTP, put `{{ .Token }}` in the *Confirm signup* and *Reset password* templates, create customers **unconfirmed** (new switch `REGISTRATION_REQUIRE_EMAIL_VERIFICATION`, default off, implemented and unit-tested), and use code-based `resend`/`verifyOtp`/`resetPasswordForEmail`/`updateUser` in the app. Left off until SMTP exists, otherwise nobody could confirm.
- `docs/ANDROID_APP_PLAN.md`: Expo skeleton plan (separate repository, Expo Router routes and the status-gate table, LargeSecureStore session storage, env configuration with a build-time project/APP_ENV guard, API integration table, tests, release path) with the gating items and the exact next step. **Missing interfaces identified**: customer order placement (a reviewed Migration 22 for account-bound requests with design names), a design catalog, and push tokens/feed/sender.

Test changes this milestone:
- Registration handler: 14 unit + 5 integration = 19 tests (the verification switch test is new). Typecheck unaffected.
- Database suite: now **81 checks** (new A8: a customer-marked user confirming its email *later* does not claim a staff profile). While adding it I found that the earlier A7 was vacuous (the staff profile it used was already linked, so even a broken trigger passed); A7 and A8 now target UNLINKED staff profiles. 81/81 on a fresh local copy of the Staging backup. The mutation suite now has 10 mutations (new M10: confirmation trigger not customer-aware); **10/10 caught**, and A7 now fails under the old-trigger mutation.
- The 81-check file differs from the 80-check file that was run on Staging on 2026-10-17 07:43Z (Migration 21 itself is unchanged). Re-running it on Staging needs one more owner password window; not done.

### Milestone 4 (2026-10-17): Migration 22, Expo app, Edge Function on Staging

- **Migration 22** (product_designs, customer_order_requests + lines, submit_customer_order_request, my_order_requests, customer_designs, request_account_deletion) is **applied to Staging**. Fingerprint check passed (only my_customer_account/require_approved_customer changed; 15 objects added). Staging suites after apply: **81/81 (M21) and 33/33 (M22)**; validate_financials integrity 14 pass / 4 warn (existing Staging data) / 0 fail. Evidence: C:EFZ-checksP21stagingAPPLY22_*. Not on Production.
- **register-customer Edge Function deployed to Staging only** (REGISTRATION_HINT_SALT created, value never shown). Smoke: valid 202, repeat 202 identical, bad phone 422, short password 422, GET 405. API gating test (publishable key only): registered account signs in, is pending, catalog/designs/orders/order-requests/order submit all refused (403), orders and profiles not readable, direct public sign-up refused (422), wrong password refused. Rate limit: 8 accepted then 429. Email verification is OFF (needs custom SMTP).
- **Expo app** (C:UsersAbdirahimDesktopefz-customer-app, local git only): sign-in, registration, gate screens, catalog, designs, cart, order requests, order history, account + deletion request. tsc clean, Jest 61/61, ESLint 0 errors, Android bundle export OK, secret scan OK. **Not tested on an emulator/device** (no JDK/Android SDK on this PC).
- **Hub**: request inbox shows an "request from app" badge, designs, preselects the verified customer (test:hub 20/20).
- **API journey on Staging (2026-10-17, C:\EFZ-checks\P21\e2e\journey.mjs, 33/33)**: pending account denied catalog/designs/orders; staff approve (RPC the Hub uses) links a verified CRM customer; catalog visible (5 items); order request submitted and idempotent, lands in staff inbox as status new with NO order created; suspend denies everything at once with the existing token; deletion request returns 204 and sets the flag; events registered/approved/suspended/deletion_requested recorded; no staff profile for the customer. Used a pending synthetic account from the rate-limit probe because the per-client 24h registration limit (8) was used up. Hub browser (Playwright) run for this step NOT done.
- **Hub browser journey on Staging (2026-10-17, Playwright, 7/7)**: real login form as the Staging test admin; account approved and later suspended through the real Hub screens; request from the app shown with the "request from app" badge, product and design chip (screenshots in C:\EFZ-checks\P21\e2e\shots); staff Mark Contacted, Mark Confirmed, Convert to Order: verified customer preselected, design in the order notes, exactly one order created, second conversion refused by the database (WR409) and no Convert button after; the Hub required a below-cost reason (Staging clearance ball) before creating the order. Customer calls denied (403) right after suspension; events registered > approved > suspended; browser wrote only through the expected functions. Converted test orders were cancelled; ~4 earlier aborted-run orders were cancelled too (history kept). Synthetic records (e2e-rate-*, E2E Red Design, cancelled orders) remain on Staging.
- **Create order disabled (explained)**: on Staging the product "EFZ - Clearance Ball" is priced $8 with cost $9. The Hub dialog (ConvertRequestDialog, validation unchanged) requires a Super Admin reason before a below-cost order can be created, so the button stays disabled until it is entered. Business rule working as designed, not a bug; Staging test data only. Retest with a normally priced product (Fire Ball): button enabled, one order, no duplicate, 7/7.
- Not done: push notifications, deletion processing UI/retention policy, email verification, design management UI, Hub browser test for the badge, Play Store requirements.

### Next blockers

1. (done 2026-10-17) CLI login, deploy and smoke on Staging.
2. Owner: decide email verification (needs custom SMTP and two template edits) and the open business decisions (commission ownership, website catalog visibility).
3. Owner: Expo/EAS account and an Android emulator or device.
4. Then: Expo skeleton steps 1-2 (scaffold with the guarded environment, sign-in/registration against the Staging function).

### Next phase (recommended)

Expo app skeleton per `docs/ANDROID_APP_PLAN.md` once the Edge Function is deployed to Staging. Before Production: the owner decisions above, a Production backup + rehearsal as for earlier migrations, and Super Admin granting `manage_customer_accounts` to the right staff.

## Milestone 5 (2026-10-17): checkout, payments and credit (Migrations 23 and 24 on Staging)

Everything here is on this branch only. **Production is untouched; nothing is pushed, merged or released.** The app is **not production-ready**.

### Migration 23: applied to Staging `adjjamiqwboawqedaapi` only
* Backup `20261017-151604Z` restore-verified before the apply. Applied and verified in owner-run windows; existing objects unchanged (fingerprints), validation 14 pass / 4 warn / 0 fail.
* Direct checkout (paid online or on credit) as server-side functions that reuse the existing orders, order lines and payments tables, triggers, stock model, invoices and receipts. No parallel ledger. `create_order` and `record_payment` are unchanged and still staff-only.
* Payments Edge Function (`payments`) with a WaafiPay adapter (EVC Plus) and an eDahab adapter, callbacks as triggers only, server-side status query, idempotent finalization. `staging-test-payment` provides the labelled simulated payment (Staging only). **No real provider is connected** (see `docs/PAYMENT_PROVIDERS.md`; the WaafiPay credential format is unconfirmed).
* Credit: policy OFF and empty by default; Super Admin-only administration; per-customer limit and terms; atomic reservation; partial repayments through the existing payment function. See `docs/CREDIT_POLICY.md`.
* Staging state, re-read on 2026-10-17 after all of this work: credit policy OFF, no thresholds, `evc_plus`, `edahab`, `stg_test` all disabled.

### Migration 24: credit policy refinement, **APPLIED to Staging 2026-10-17 17:03Z (not Production)**
Adds minimum days as an approved customer, a maximum total outstanding per customer and an overdue rule; separates unmet *requirements* (overridable with a recorded reason) from account *standing* (never overridable); lets an authorized override account actually buy (M23 did not); adds `credit_history`. Staging apply: backup `C:\EFZ-backups\staging\20261017-165739Z` (24 checksums OK, BRACKET OK, enum snapshot, restore verified exit 0, 61/61 data fingerprints identical), rehearsed first on the restored copy of that data (apply, 81/33/97/62 suites, concurrency 9/9, rollback with identical function fingerprint and baseline, re-apply), then applied in the guarded window `C:\EFZ-checks\P21\staging\APPLY24_20261017-170303Z`: no drift, Staging fingerprint after == the tested post-M24 state (3 redefined, 1 replaced, 1 added, nothing else), baseline +1 function only, **credit policy still OFF and empty, all three payment methods still disabled**, suites on the actual Staging database 81 / 33 / 97 / 62 with 0 failures, validate_financials integrity 14 PASS / 4 WARN / 0 FAIL. The rollback was NOT run on Staging (only on the local copy). Mutation and concurrency tests are local by design (they commit or alter objects); Staging got the rolled-back suites. Post-apply probe on Staging: 23 of 23 (policy state, authorization of Manager / Officer / Customer Service / anonymous, customer responses have no field named cost, margin, profit, commission, officer or supplier at any depth, direct table reads by a customer return nothing). Hub browser test on the live M24 Staging: 34 of 34 (9 use invented customers).

### Verified results (local disposable PostgreSQL clones unless marked Staging)
| Check | Result |
|---|---|
| M21 / M22 / M23 suites on M23+M24 | 81 / 33 / 97 checks, 0 failures |
| M24 suite (`supabase/checks/24_credit_policy_checks.sql`) | 62 checks, 0 failures |
| M24 concurrency (`24_credit_concurrency.mjs`, real parallel sessions) | 9 of 9 |
| M24 mutation tests | 36 of 36 caught (35 migration changes + 1 lock removal); one further mutation was dropped as equivalent |
| M23 mutation tests (earlier) | 25 caught |
| Rollback (`rollback/24_credit_policy_refinement_rollback.sql`) | schema fingerprint identical to pre-M24 (functions, columns, constraints, triggers, policies, ACLs, indexes); rerunnable; M23 suite 97/97 afterwards; M24 re-applies cleanly |
| Payments functions tests | 29 pass |
| Hub unit tests (`npm run test:hub`) | 28 pass; `tsc` clean; ESLint clean on changed files |
| Staging end-to-end journey (real Staging DB + deployed functions, simulated payments) | 55 of 55 |
| Hub browser test against Staging (Playwright, Chromium) | 34 of 34, of which 9 are **mock-backed** (Staging has no M24, so the Hub's RPC answers were replaced in the browser; this proves the Hub UI and the arguments it sends, not the database) |
| Customer app | `tsc` clean, ESLint 0 errors (15 warnings), Jest 129 pass, Android export OK, secret scan clean (only the guard's own rejection strings match) |

Hub browser coverage: Super Admin sees the page and the new fields, validation, History fails gracefully before M24; Manager, Officer and Customer Service do not see the link, are shown "Access Restricted" at the URL, and every credit administration function refuses them at the API; anonymous callers are refused; no request went to Production. Scripts: `C:\EFZ-checks\P21\hubbrowser`.

### What is browser-tested and what is not
All screenshots and layout checks of the customer app were made in the **web build in a browser**. **No native Android device or emulator was available**, so nothing here is tested natively (fonts, keyboard behaviour, safe areas, performance, deep links). A real-device pass is still required.

### Remaining limitations and risks
1. No real payment provider is connected; EVC Plus (WaafiPay) credential format and eDahab agent code are unconfirmed; no sandbox is documented for either.
2. The Hub and app changes tolerate a database without Migration 24; Production (still at Migration 20) has none of milestones 4 and 5 yet.
3. Credit policy values and the decisions in `docs/CREDIT_POLICY.md` belong to EFZ; nothing is activated.
4. Disputes, late fees and reminders are not modelled; provider reversals are flagged for staff and never change records automatically.
5. The no-cost-exposure check exists only as the external Staging probe `post_apply_probe.mjs`; fold it into a repository test before release. Real product photography is still needed for the catalogue.
6. The owner's Staging test logins in `.env.e2e` should be rotated or removed after testing, as that file says.

### Exact approvals and decisions needed
* Decide the credit policy values and rules in `docs/CREDIT_POLICY.md`.
* Start merchant onboarding with WaafiPay and eDahab (next actions are in `docs/PAYMENT_PROVIDERS.md`); never send secrets in chat.

## Milestone 6 (2026-10-18): credit policy v2 (Migration 25), a DRAFT applied nowhere

Everything here is on this branch only, **local**. Migration 25 is applied to **no** database (Staging is at migration 24). Credit is OFF. Production untouched. Nothing pushed, merged or deployed. Read `docs/CREDIT_POLICY.md`, `docs/MIGRATION_25.md`, `docs/CREDIT_SCHEDULER.md`.

### Implemented (local)
Permanent immediate default with no grace period (revocation at the first overdue day, enforced when an order is accepted and recorded by any look or by the daily run); paying settles but never restores credit; requalification from the settlement and Super Admin re-approval at the initial limit; the approved proposal (3 orders, 90-day window, 60-day age, $40, 30 days, 25% cap over 3 complete months) loaded with credit OFF; company-wide cap on EFZ's existing revenue definition that blocks activation when history is insufficient; extensions that keep the original due date; disputes with void-only-after-billing-error; idempotent reminders and escalations with failure records and retries; append-only default and credit history; duplicate-phone guard; Hub controls; Android status, requalification steps, notices, invoice dates and a report-a-problem form; customer data exposure suites.

### Verified results (local disposable PostgreSQL clones unless stated)
| Check | Result |
|---|---|
| M25 suite (`25_credit_policy_v2_checks.sql`) | **135 checks, 0 failures** |
| M25 concurrency, real parallel sessions (`25_credit_concurrency.mjs`) | **13 of 13**: company cap across 5 different customers (exactly 1 of 5 $30 orders), the last $20 of cap (exactly 2 of 6), personal $40 limit (exactly 2 of 8), one submission key from 5 sessions (1 order), default race over 8 sessions (1 default, 1 revocation, 1+1 notices), 5 concurrent daily runs (no duplicate reminder), 5 simultaneous disputes (1 opened) |
| M25 mutation tests | **52 of 54 caught.** Survivors: **M26** (a defaulted invoice can be extended) and **C2** (no per-customer lock): both **equivalent** (another guard already covers each: a defaulted invoice is always overdue-unpaid or paid, and every path that takes the customer lock takes the company lock first). Three gaps found and closed by new tests (late-paid default, voided default, populated-table exposure) |
| Rollback (`rollback/25_credit_policy_v2_rollback.sql`) | schema fingerprint **identical** to pre-M25 on a populated database; rerunnable; M21 81, M22 33, M23 97, M24 62 pass afterwards; M25 re-applies (135). Two real defects found by the test and fixed (drop order; proposal values left behind) |
| M21 / M22 / M23 suites on M25 | 81 / 33 / 97, 0 failures (the M23 suite gained a conditional preamble and passes on M24 and M25) |
| M24 suite | **62 of 62 on a migration-24 database (the live Staging level)**; on migration 25, 43 of 62 fail **by design** (listed in `docs/CREDIT_POLICY.md`; valid cases ported to M25 sections J and K) |
| Customer data exposure (`customer_data_exposure_checks.sql`) | 17 checks on M24, 18 on M25, 0 failures; a deliberately leaked cost field **is caught**. Observation: the `financial_summary` view is selectable by customers but returns one all-zero, all-null row |
| Financial validation | output identical before and after M25 on the clone (integrity 0 failures; the Production-specific baseline rows are not applicable to Staging) |
| Scheduler trigger Edge Function + payments functions | **35 of 35** (`npm run test:payments`) |
| Hub | `tsc` clean, ESLint clean on changed files, **31 of 31** unit tests, production `next build` OK |
| Hub browser test (Playwright) | **52 of 52**: **26 against real Staging** (login, permissions of Manager / Officer / Customer Service, API refusals, page behaviour on a migration-24 database, no Production traffic) and **26 mock-backed** (Staging has no migration 25: 9 for M24 states, 17 for the M25 controls and the arguments they send) |
| Customer app | `tsc` clean, ESLint 0 errors, **142 of 142** Jest tests (including the dedicated exposure test), Android export + secret scan (see the report) |

### What is NOT done or NOT verified
* **Migration 25 is not applied to Staging.** No Staging-backed test of it exists: the Staging checks above are on migration 24 (the Hub degrades gracefully there). Applying needs your authorization, a fresh backup and the guarded window.
* **The daily run is not scheduled** and whether pg_cron exists on the projects was not verified; reminders are **not operational** (`docs/CREDIT_SCHEDULER.md`). Only the in-app channel exists.
* No native Android device or emulator testing; layout was checked in a browser only.
* **EVC Plus and eDahab remain unavailable for real payments.**
* Open policy decisions listed in `docs/CREDIT_POLICY.md` (requalification interpretation, minimum purchase value, per-customer ceiling, revenue basis, extension length, overrides).
* A stray **empty folder `C:\ABDIR~1`** (created 2026-10-17 20:56 by a mistaken file write of mine, containing nothing) could not be removed by me (a safety check blocked it); please delete it with `rmdir C:\ABDIR~1` if you agree.

## Milestone 7 (2026-10-18): negotiated customer pricing (Migration 26), a DRAFT applied nowhere

Branch only, **local**. Migrations 25 and 26 are applied to **no** database (Staging is at M24, credit OFF, no payment method enabled). Production untouched. Nothing pushed, merged or deployed. Read `docs/CUSTOMER_PRICING.md`, `docs/MIGRATION_26.md`, `docs/STAGING_RUNBOOK.md`.

### Results (final code; "local" = disposable PostgreSQL 17 clones; "Staging-backed" = real Staging read/sign-in only; "mock-backed" = browser with invented server answers)
| Check | Result | Kind |
|---|---|---|
| M21 / M22 / M23 / M25 / M26 / exposure suites on M24+M25+M26 | 81 / 33 / 97 / 135 / 63 / 19, 0 failures | local |
| M24 suite on a fresh M24 clone | 62 of 62 | local |
| Concurrency M24 / M25 / M26 (real parallel sessions) | 9 / 13 / 11, all pass | local |
| Rollback of M26 then M25 on a data-rich clone | financial figures identical; fingerprint identical to M24 | local |
| Mutation tests | M25: 52 of 54 caught; M26: 44 of 45 caught; the 3 survivors are equivalent (reasons in `MIGRATION_26.md`) | local |
| Staging-shaped rehearsal (Staging backup data + M25 + M26) | integrity unchanged, all suites pass, import dry-run produced | local |
| Hub | `tsc` clean; **37 of 37** unit tests; production build OK with `next build --webpack` (Turbopack cannot build in the worktree because `node_modules` is a junction outside the root; unrelated to the code); ESLint: 9 errors, all in files this work did not change (`any` in backend/ and lib/storage, types, validators; empty interface in `components/ui/input.tsx`) | local |
| Hub browser test, Customer Prices page | **19 of 19**: permissions (Super Admin and Manager see it, Officer refused) on **real Staging**; screen and exact arguments **mock-backed** (Staging has no M26) | mixed |
| Edge function unit tests (credit-daily 6, payments 16, register-customer 14, staging-test-payment 5) | 41 of 41 | local (no network) |
| Customer app | `tsc` clean, ESLint 0 errors (26 warnings), **151 of 151** Jest tests (9 are the pricing tests), Android export OK | local |
| App secret scan (bundle + source) | no service-role key, no secret key, no JWT, no cost or margin field; the only hits are the app's own guard strings (`service_role`, `sb_secret_`, the project refs) | local |

### Customer app journey
Registration, email verification, approval/rejection states, the approved-only catalogue, multi-design cart, server-validated checkout, order history, invoices/receipts, notices/disputes/credit status, password recovery and account management are covered by the 151 Jest tests (mock API) and the database suites 21-26 (real SQL). Staging-backed end-to-end runs were done earlier against Staging at M24 (`docs/ANDROID_APP_PLAN.md`). **Not done: any native Android device or emulator run.** No device or emulator was available; layout was checked only in unit tests and a bundle export. Nothing in this milestone claims device testing.

### Credit, reminders, payments
Credit remains disabled by default and for every real customer. EVC Plus and eDahab remain unavailable for real payments (need provider access, server-side verification and supervised payment tests, `docs/PAYMENT_PROVIDERS.md`). The scheduler is **not operational**: the run (`credit_daily_run`), the Hub manual trigger and the `credit-daily` handler are tested locally (M25 suite, 5-simultaneous-run concurrency test, handler tests 6/6); how to schedule and verify on Staging is in `docs/CREDIT_SCHEDULER.md` and needs separate authorization.

### Decisions needed (not decided silently)
Pricing: see `CUSTOMER_PRICING.md` (expired agreements: revert or hold; unverified candidates; who verifies varying histories; staff `create_order` default price; percentage/tier discounts; below-cost policy). Credit (from `CREDIT_POLICY.md`): requalification timing, maximum extension length, administrative exceptions, billing corrections. Business: who owns agreement verification day to day.

### Missing or ambiguous agreements
Production data was not examined. On the Staging data (test customers only): 1 candidate (Test Club Alpha / EFZ - Fire Ball, $10.00, 2 orders) and 7 needing manual confirmation (5 single-order, 2 varying). The real list must come from a dry run on a Production copy.

### Launch blockers
Approve and apply M25 and M26 to Staging (runbook), then supervised Staging testing of the app against M26; a native device/emulator run; owner decisions above; verified real price agreements; payment provider onboarding; scheduler enablement; backup B.4 encrypted copy (older item); the leftover empty folder `C:\ABDIR~1` (please run `rmdir C:\ABDIR~1`).

## How to run the checks

```bash
# Database checks (any database that has migration 21; they roll back):
psql -X -v ON_ERROR_STOP=1 -d <db> -f supabase/checks/21_customer_accounts_checks.sql
# Before/after proof that nothing else changed:
psql -X -d <db> -f supabase/checks/21_function_fingerprint.sql > before.txt   # apply 21 ...   > after.txt ; diff
# Registration handler (Node's built-in runner; integration tests need a LOCAL database with migration 21):
npm run test:registration
EFZ_TEST_PG="<psql.exe>|127.0.0.1|<port>|postgres|<database>" npm run test:registration
```
