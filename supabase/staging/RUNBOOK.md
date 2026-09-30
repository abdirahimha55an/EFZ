# EFZ-Staging runbook

**STAGING ONLY.** Every step below is for the separate, empty **EFZ-Staging**
Supabase project. Nothing here touches production, and no real customer data is
used — `06_data_import.sql` is deliberately skipped.

The whole sequence was dry-run on a local in-memory PostgreSQL (PGlite) with a
stand-in `auth` schema: every step succeeded, 08 and 09 left all 16 business
tables byte-identical, and the security checks went from 30 FAIL to 43/43 PASS.
Staging's job is to confirm that on real Supabase.

## Before you start

1. **Confirm you are in EFZ-Staging.** Check the project name at the top left of
   the dashboard, and that the URL's project ref is **not** the production one
   (production starts `rodm…`). Re-check before every paste.
2. **Authentication → Sign In / Providers:** turn **off** "Allow new users to
   sign up" (mirror the intended production setting). Keep "Confirm email" on.
3. Open **SQL Editor**, new snippet, role **postgres** (the default).
4. Supabase may show a *"destructive operation"* warning for files that contain
   `drop policy if exists` / `drop trigger if exists` (02, 03, 08). Those only
   replace policies and triggers, never tables or data. Confirm **only** while
   you are in EFZ-Staging.

Paste each file's **entire contents** and click **Run**. Run them one at a time,
in this order. If any step errors, stop and send me the message.

## Steps

| # | Paste this file | Creates / changes | Data? | Expected result |
|---|---|---|---|---|
| 1 | `supabase/01_schema.sql` | Extension `pgcrypto`, 13 enums, 18 tables, indexes | None | "Success. No rows returned" (a notice that pgcrypto already exists is fine) |
| 2 | `supabase/02_functions.sql` | Helper functions, financial and commission triggers, the RPCs, trigger on `auth.users` | None | Success. **If it fails with a permission error on `auth.users`, stop** — that is a Supabase platform restriction to solve before production too |
| 3 | `supabase/03_rls.sql` | Enables RLS on every table, policies, RPC grants | None | Success |
| 4 | `supabase/04_views.sql` | 8 reporting views including `public_products` | None | Success |
| 5 | `supabase/05_seed.sql` | 26 permission codes, the settings row, 3 marketing testimonials, `grant_role_preset()` | Reference data only (no people, customers or orders) | Success |
| — | ~~`06_data_import.sql`~~ | **Skip.** Real customer data | — | — |
| 6 | `supabase/07_diagnostics.sql` | `upsert_issue`, `run_diagnostics`, `repair_issue`, `operational_metrics` | None | Success |
| 7 | `supabase/staging/staging_test_data.sql` | Synthetic staff, customers, products, 11 orders, payments, commissions, 1 website request | **Synthetic only** (`@example.com`, `+000` phones) | A table: profiles 9, user_permissions 78, customers 7, products 5, stock_movements 19, orders 11, order_items 14, payments 8, commissions 10, commission_payouts 1, order_requests 1, system_logs 27. A second run is refused with "STAGING TEST DATA ABORTED" |
| 8 | *(dashboard)* Authentication → Users → **Add user → Create new user**, tick **Auto Confirm User**, one per email below | Auth accounts, linked to the profiles by email | Synthetic | 8 users. In SQL: `select id, auth_user_id is not null as linked from public.profiles order by id;` → 8 `true`, only `u-stg-nologin` `false` |
| 8b | `supabase/staging/staging_api_grants.sql` | Table/view privileges for `anon`, `authenticated`, `service_role` (SELECT/INSERT/UPDATE/DELETE). No function grants | None | A table: each role can select **18** tables and **8** views. Needed because EFZ-Staging was created without Supabase's automatic API grants, which 01–09 rely on; without it every client request is "permission denied for table". Refuses to run unless every profile is `@example.com` |
| 9 | `supabase/staging/staging_validate_financials.sql` (staging copy keyed to the `STG-BASE` ids) | Nothing (read-only) | — | **Save the output.** FAIL 0, WARN 2 (1 delivered unpaid order, 1 product below cost), baseline rows all PASS |
| 10 | `select public.run_diagnostics();` | Nothing | — | **Error** `malformed array literal: "orders-without-items"` — confirms the bug 09 fixes |
| 11 | `supabase/staging/staging_security_checks.sql` | Temporary results table only; every attempt is rolled back | — | **Save the output.** Roughly 30 FAIL: the holes 08 closes |
| 12 | `supabase/08_security_hardening.sql` | Guards, policies, hierarchy, grants, auth-link triggers. No data | None | Success |
| 13 | `supabase/09_fix_run_diagnostics.sql` | Replaces `run_diagnostics()` | None | Success |
| 14 | `supabase/staging/staging_validate_financials.sql` | Nothing (read-only) | — | **Identical to step 9**, figure for figure |
| 15 | `select public.run_diagnostics();` | Refreshes `system_issues` | — | `6` — then `select id, affected_count from public.system_issues where resolved_at is null order by id;` → customers-without-officer, orders-delivered-unpaid, products-low-stock, products-negative-margin, products-out-of-stock, profiles-without-auth (1 each) |
| 16 | `supabase/staging/staging_security_checks.sql` | Temporary results table only | — | **Every row PASS** (43) |
| 17 | Re-run `08` then `09` | Nothing new | None | Success both times (idempotent); repeat step 14 → still identical |
| 18 | *(dashboard)* Add a user `efz.new@example.com` **without** a profile, auto-confirmed | A new inactive profile | Synthetic | `select role, status from public.profiles where email = 'efz.new@example.com';` → `Marketing Officer`, `inactive` |

### Step 8: accounts to create

Use any password you like; these accounts exist only in staging.

| Email | Profile | Role |
|---|---|---|
| `efz.superadmin@example.com` | `u-stg-admin` | Super Admin |
| `efz.manager@example.com` | `u-stg-manager` | Manager + manage_users (a non-Super-Admin admin) |
| `efz.ops@example.com` | `u-stg-ops` | Manager + view_diagnostics |
| `efz.officer1@example.com` | `u-stg-officer1` | Marketing Officer (5%) |
| `efz.officer2@example.com` | `u-stg-officer2` | Marketing Officer (10%) |
| `efz.inventory@example.com` | `u-stg-inventory` | Inventory Staff |
| `efz.delivery@example.com` | `u-stg-delivery` | Delivery Staff |
| `efz.suspended@example.com` | `u-stg-suspended` | Marketing Officer, **inactive** |

Do **not** create `efz.nologin@example.com` — it exists to trigger the
"active staff with no sign-in account" diagnostic.

## What the synthetic data covers

| Scenario | Where |
|---|---|
| Super Admin, user manager, ops manager, officers, inventory, delivery | 9 profiles |
| Suspended account | `u-stg-suspended` |
| Staff with no login | `u-stg-nologin` |
| Products, stock ledger, low stock, out of stock, priced below cost | 5 products, opening stock via `adjust_stock()` |
| Approved historical baseline (7 orders, 11 units, $119.00, $73.70, $45.30, 38.07%) | `STG-BASE-01` … `STG-BASE-07`: synthetic orders with neutral ids and dates that reproduce the signed-off totals, delivered and fully paid |
| Partial payment and outstanding balance | `ORD-STG-1001`: $36.00, paid $20.00, owes $16.00 |
| Delivered but unpaid | `ORD-STG-1002`: owes $24.00 |
| Pending order, customer with no officer | `ORD-STG-1003` |
| Cancelled order (stock returned, commission voided) | `ORD-STG-1004` |
| Commissions pending and paid (one payout) | Officer One paid for `STG-BASE-01` and `STG-BASE-02` |
| Public website order request | 1 request, status `new` |

## Optional: the app against staging

Only after step 16 passes. Next.js reads `.env.development.local` **before**
`.env.local`, so `npm run dev` can target staging without touching the
production `.env.local`:

1. Create `.env.development.local` (git-ignored by `.env*`) with EFZ-Staging's
   `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY`. Leave
   `SUPABASE_SERVICE_ROLE_KEY` out; the app does not need it.
2. `npm run dev`, then check the browser's network tab shows the **staging**
   project ref before signing in.
3. Sign in as each account above; submit `/order` signed out; open Users,
   Orders, Products, Diagnostics.
4. **Delete `.env.development.local` afterwards.** Otherwise `npm run dev` will
   keep pointing at staging.

## Clean-up

Nothing to clean up in the database for the checks — they roll themselves
back. The EFZ-Staging project can be kept for the next migration or deleted
from the dashboard; it never shares anything with production.
