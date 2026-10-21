# EFZ Production launch package (2026-10-21)
One checklist. Evidence and the rehearsal result are in `PRODUCTION_RELEASE_CHECKLIST.md`. Nothing here was applied to Production.
Legend: **[done]** prepared/verified locally, **[YOU]** you must provide or do it, **[APPROVE]** needs your explicit Production approval at that moment.

## 1. Supabase Production: Auth, email, Edge Functions
| # | Item | State |
|---|---|---|
| 1.1 | Auth sign-up disabled | Reported disabled 2026-10-02, not re-checked since. `deploy-production.ps1` preflight re-checks it through the public settings endpoint. **[done: check scripted]** |
| 1.2 | Custom SMTP + sender domain | **[YOU]** Register an EFZ domain, add it to Resend, create the DNS records (SPF/DKIM), choose the sender (e.g. `noreply@<domain>`), then enter the SMTP password ONLY in the dashboard secret field. Steps: `efz-customer-app/docs/EMAIL_DOMAIN_SETUP.md`. The Staging SMTP flow was never confirmed end to end either. **[APPROVE]** the Production dashboard change. |
| 1.3 | Email templates show the 6-digit code | **[YOU/APPROVE]** "Reset Password" (and "Confirm signup" if verification is on) must contain `{{ .Token }}`, not `{{ .ConfirmationURL }}`; OTP length 6, expiry 1 h (`AUTH_RECOVERY.md`). |
| 1.4 | Email verification for customers | Decision: `register-customer` creates users with `email_confirm: true` unless `REQUIRE_EMAIL_VERIFICATION=true`. Recommendation: leave OFF for the first release (no proof of mailbox, but staff approve every account anyway); turn ON only after SMTP is proven. |
| 1.5 | Edge Function `register-customer` | Only this function is needed at launch. `supabase/functions/register-customer/deploy-production.ps1` **[done]**: default = read-only preflight; `-Deploy -ConfirmProduction "DEPLOY register-customer TO PRODUCTION"` sets `REGISTRATION_HINT_SALT` (generated locally, never printed) and deploys with `--no-verify-jwt`. Needs migration 21 first. Prerequisites **[YOU]**: install Supabase CLI (`npm i -g supabase@2.121.0`), `supabase login` in your own terminal, confirm the plan allows Edge Functions, set `$env:EFZ_PRODUCTION_PUBLISHABLE_KEY` (public key). **[APPROVE]** the deploy. |
| 1.6 | `payments`, `credit-daily`, `staging-test-payment` | Do NOT deploy. Payments and credit stay disabled. `staging-test-payment` and the `stg_test` method must never exist in Production (verify `select code, enabled from payment_methods` after migration 23: only disabled providers). |
| 1.7 | Realtime private channels | 29b refuses to run if `realtime.send` is missing, so the migration itself proves Realtime is available. |

## 2. Privacy policy and account deletion
The app shows the links only when these build variables exist: `EXPO_PUBLIC_PRIVACY_POLICY_URL`, `EXPO_PUBLIC_ACCOUNT_DELETION_URL` (https only). Play requires both a public privacy policy URL and a public web page explaining account deletion, besides the in-app request that already exists (`request_account_deletion`; access ends immediately, EFZ processes it, orders/payments may be kept for legal records).
**[YOU] decisions and content:**
1. Hosting: recommended on EFZ's own domain (the one chosen for email), e.g. `https://<domain>/privacy` and `/account-deletion`. Alternative: public pages inside the Hub (needs the proxy/middleware to allow those two paths; I can add this once you confirm).
2. Legal entity name, address, support email/phone, governing law.
3. Data the app actually handles (from code): name, phone, email, password (Supabase Auth), delivery details and notes, orders/requests, prices/finance statements, deletion reason. No analytics SDK is present in the repo. Confirm retention periods for orders, payments and account data.
4. Deletion process: who handles `deletion_requested` accounts, within how many days, what is kept (financial records) and for how long.
5. Whether you want the deletion page to also accept requests by email/WhatsApp.
I will not invent legal text; send the above (or your lawyer's text) and I will build the pages and wire the variables.

## 3. Android
| Item | State / action |
|---|---|
| Package ID | `so.efz.customer` is provisional and **permanent after the first Play upload**. **[YOU]** confirm it (or give another). |
| Play Console | **[YOU]** Create the developer account (organisation accounts need business verification; new personal accounts need a closed test, currently 12 testers for 14 days: confirm in the Console), then the app, store listing text/graphics, support email, Data safety form, content rating, target audience. |
| Signing | EAS creates the Production upload keystore on the first production build (`eas build -p android --profile production`, answer "generate"); use Play App Signing. **[YOU]** run it in your terminal; never commit keystores. |
| Expo project | Currently under `@rami_ha55an`; moving to `elite-football-zone` is optional ([decision], procedure in `RELEASE_PROCESS.md` section 8). Do before the first production build, not after. |
| Version alignment | `app.config.ts` `version` = `0.1.0` is what users and Play see; `package.json` says `1.0.0` (unused). Recommendation: set both to `1.0.0` for the first store release; this is a native-config change, so Staging needs one rebuild afterwards. Not changed yet (decision). `versionCode` auto-increments remotely. |
| Production EAS variables | **[YOU]** (public values only): `eas env:create --environment production --name EXPO_PUBLIC_SUPABASE_URL --value https://rodmdvfjashiohgwople.supabase.co --visibility plaintext`, same for `EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY` (publishable key, not secret), `EXPO_PUBLIC_PRIVACY_POLICY_URL`, `EXPO_PUBLIC_ACCOUNT_DELETION_URL`. The build guard refuses a URL that does not match `EXPO_PUBLIC_APP_ENV=production`. |
| Build / release | `npm run verify`, then `npm run build:production` (.aab). Upload to Play **internal testing** first, test with an invented, approved customer against Production, then closed testing, then a staged rollout (10% / 50% / 100%). **[APPROVE]** each Play promotion. |
| OTA to Production | No Production update script exists, on purpose. Do not add one until the first .aab has been tested on a phone. |
| Payments | Hidden/disabled at launch: customers use "send as request". EVC Plus/eDahab need merchant credentials and an unresolved WaafiPay format question (`docs/PAYMENT_PROVIDERS.md`). |

## 4. Production permissions for Website Requests
Production staff today: 1 Super Admin, 3 Marketing Officers, no Managers. Nobody holds `manage_website_requests`, 3 old requests are all rejected. After migration 19 the Super Admin (bypasses all checks) can do everything; nobody else sees requests. The Manager preset no longer includes any request permission.
To let a person handle requests, the Super Admin ticks these in **Users & Privileges** (every change is audited by 19b): `view_website_requests` (their assigned requests) or add `view_all_website_requests`; `manage_website_requests` (notes/contacted/confirmed); `assign_website_requests`; `reject_website_requests`; `convert_website_requests` plus `create_orders` (and `add_customers` for a new customer). Customer-app accounts are approved by the Super Admin only (`manage_customer_accounts` is reserved).
**[YOU]** Decide who: recommended at launch = Super Admin only (no grants), then delegate one named person with view + manage + convert, assigned-only, after the first real requests arrive. Do not give the Marketing Officers request permissions by default (they already hold `create_orders`/`add_customers`). **[APPROVE]** the grants after the Hub is live.

## 5. Final Production sequence, rollback and backup rule
**Backup rule:** a sealed backup (`BRACKET OK`, 14/14 checksums, restore-verified) taken in the same window, immediately before step 1. The 2026-10-21 backup `20261021-062637Z` proved the procedure but must be re-taken: Production data changes daily. Command (owner terminal, prompts for the password): `powershell -File supabase\production\run_backup_and_seal.ps1`. Then the read-only drift check: `powershell -File supabase\production\run_readonly_preflight.ps1` (markers must still read "Production = migration 20", all 7 migration-19 preconditions MATCH).
Apply with the single-transaction pattern used before: `psql --single-transaction -v ON_ERROR_STOP=1 -c "set lock_timeout='30s'" -f <file>` from LF copies, in a separate window, with zero other app connections, one file at a time. The pinned apply-window script (modelled on `C:\EFZ-checks\P14\m20_prod\m20_prod_apply_window.ps1`: file hash pins, release-commit check, backup precondition, identity markers, attempt marker, post-baseline compare) is generated once the final release commit exists. **[APPROVE]** each step.

| Step | Action | Rollback |
|---|---|---|
| 0 | Fresh backup + preflight (above) | none needed |
| 1 | `19_website_request_delegation.sql`, `19b_permission_change_audit.sql` | `rollback/19b_rollback.sql`, `rollback/19_rollback.sql` (19 refuses once `assigned` events exist) |
| 2 | `21` … `28` one at a time (fingerprint after each) | `rollback/NN_*_rollback.sql` in reverse order (each has a dependency guard) |
| 3 | `29a_dispatch_enum.sql` alone, then `production/29b_dispatch_and_live_orders.crtolerant.sql`, `29c`, `29d` | `rollback/29_dispatch_rollback.sql` (the `dispatched` enum label stays; unused) |
| 4 | Deploy the Hub: merge the release branch to `main` (fast-forward) so Vercel builds Production; check the sidebar build stamp shows Production; smoke test as Super Admin (requests inbox, create/confirm/dispatch/deliver an order) | Vercel: promote the previous deployment (`c1e873b`) ; database objects from 19-29d are additive and the old Hub keeps working until 29e |
| 5 | `production/29e_enforce_dispatch.crtolerant.sql` (blocks processing→delivered; the old Hub still offers it, so this comes only after step 4) | `rollback/29e_enforce_dispatch_rollback.sql` |
| 6 | `register-customer` deploy (1.5), SMTP/templates (1.2-1.3), then Android internal test | undeploy the function / revert dashboard settings |
| Last resort | Restore from the same-day sealed backup (destructive, owner decision, tested procedure `BACKUP_AND_RESTORE_DRILL.md` Part C into a scratch DB first) | |

Line endings: the Hub repo's `.gitattributes` now forces LF for migrations, checks, rollbacks and production scripts, so a Windows checkout can no longer turn them into CRLF. The generated `*.crtolerant.sql` guards accept either form anyway.
