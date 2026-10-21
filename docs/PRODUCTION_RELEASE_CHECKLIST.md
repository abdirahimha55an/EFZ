# EFZ Production release report and checklist (2026-10-21)
Production now: Hub `c1e873b`, database at migration 20 (read-only preflights `C:\EFZ-checks\M29_preflight_*`, `M29_defs_*`).
Release candidate: branch `android/customer-accounts` @ merge of phase19 UI (local commits, NOT pushed). Tested: tsc 0 errors, 70 Hub unit tests, `next build --webpack` OK (Turbopack cannot build inside the worktree symlink; Vercel builds normally), lint: only pre-existing issues.

## Fresh backup (verified)
`C:\EFZ-backups\20261021-062637Z` taken 2026-10-21 by partA_backup.ps1 (read-only transactions): BRACKET OK, 51 MATCH rows; sealed, 14/14 checksums OK. Restored to an isolated local PG17 cluster (`C:\EFZ-restore-m29`, port 54451, db efz_restore_drill): restore verified, all MATCH rows identical except the documented enum sort-number row (true label order identical for all 13 enums); validate_financials 0 FAIL / 32 PASS / 1 WARN.

## Verified migration sequence (rehearsed on that restore, `supabase/production/rehearsal/rehearse_full_on_restore.sh`)
19, 19b, 21, 22, 23, 24, 25, 26, 27, 28, 29a, **29b crtolerant**, 29c, 29d, **29e crtolerant** (files `supabase/production/*.crtolerant.sql`): all exit 0 (about 1 s each).
- SQL suites on the final DB: 21 = 81/81, 22 = 33/33, 23 = 97/97, 25 = 135/135, 26 = 63/63, 27 = 55/55, customer data exposure 19/19. Suite 24 has one failing check (G7b) that M25 supersedes (M25's own suite passes); not a regression of the rollout.
- Concurrency: 25 = 13/13, 26 = 11/11, 27 = 12/12 (24's script is superseded by 25).
- validate_financials after the chain: 0 FAIL; business row counts unchanged.
- Rollback 29e then 29: dispatch columns/triggers gone, order_details view md5 restored; re-apply of 29a..29e succeeds and returns identical function md5s.
- 29 dispatch suite (35 checks) cannot run on Production data (needs synthetic Staging staff); the post-29e function bodies are byte-identical to the Staging-shaped rehearsal where it passed 35/35. 19/19b staging checks likewise refuse on Production data (Staging evidence stands; M19's own guard passes on the restore).
- Not run: migration 19/19b concurrency (n/a), a real Production window.

## Deployment order (Production, each step needs your approval; stop after each)
0. Push branch -> Vercel Preview (Staging) green. Fast-forward is NOT done until step 6.
1. Fresh backup again right before the window (this one is from 2026-10-21; re-take if anything changes), 0 other connections except Supabase services.
2. Apply 19, 19b (single transaction, lock_timeout 30s) -> verify with preflight markers.
3. Apply 21..28 one at a time, fingerprint after each.
4. Apply 29a (alone), then `29b.crtolerant`, 29c, 29d.
5. Immediately deploy the Hub (merge to main -> Vercel Production) and smoke test (Super Admin sign-in, create/confirm/dispatch/deliver an order, requests inbox).
6. Apply `29e.crtolerant`. Re-run the read-only preflight; keep rollback 29e ready.
7. Auth/email/Edge Functions/secrets, then Android build and Play (see below). Payments and credit stay disabled.
Windows checkout warning: apply the .sql files from LF copies (git autocrlf converts them); the crtolerant guards accept either.

## Remaining external setup (not code)
- Supabase Production: Auth sign-up/email confirmation, SMTP + sender domain, Edge Functions (`register-customer`; `payments`/`credit-daily` only when enabled) and secrets; confirm `stg_test` payment method does not exist in Production.
- Privacy policy URL and account-deletion page URL (owner content) -> `EXPO_PUBLIC_PRIVACY_POLICY_URL`, `EXPO_PUBLIC_ACCOUNT_DELETION_URL`; EAS `production` variables.
- Android: final package id (`so.efz.customer` provisional), Play Console account, Production keystore (Play App Signing), version (app.config 0.1.0 vs package 1.0.0), staged rollout.
- Grant the new request permissions (`view/assign/convert/reject_website_requests`) to the staff who should handle requests; today Production has none.
- Delete `C:\EFZ-restore-m29` when no longer needed (contains a copy of Production data).
