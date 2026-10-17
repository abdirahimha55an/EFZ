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
- Not done: push notifications, deletion processing UI/retention policy, email verification, design management UI, Hub browser test for the badge, Play Store requirements.

### Next blockers

1. (done 2026-10-17) CLI login, deploy and smoke on Staging.
2. Owner: decide email verification (needs custom SMTP and two template edits) and the open business decisions (commission ownership, website catalog visibility).
3. Owner: Expo/EAS account and an Android emulator or device.
4. Then: Expo skeleton steps 1-2 (scaffold with the guarded environment, sign-in/registration against the Staging function).

### Next phase (recommended)

Expo app skeleton per `docs/ANDROID_APP_PLAN.md` once the Edge Function is deployed to Staging. Before Production: the owner decisions above, a Production backup + rehearsal as for earlier migrations, and Super Admin granting `manage_customer_accounts` to the right staff.

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
