# EFZ Production release runbook (repeatable)
Authoritative procedure for migrations 19-29e + the matching Hub. Owner-run, one PowerShell window per step, password typed only at the prompt.
Nothing below is run by Claude against Production. Rehearsed end to end on a local restore of the 2026-10-21 Production backup and with `run_release_phase.ps1 -Target Local` (phase A, then C, markers, attempt-marker refusal all verified).

## 0. Before the window
- Release commit = the commit that was pushed, built as a green Preview and approved. `git status` must be clean. Note the full 40-character sha: `git rev-parse HEAD`.
- `node scripts/make_release_manifest.mjs --check` and `node scripts/make_cr_tolerant_guards.mjs --check` must both say current.
- Legal pages: Production returns 404 for `/privacy` and `/account-deletion` until every `[[REQUIRED ...]]` in `lib/legal/content.ts` is filled (`npm run test:hub` guards this). The Hub deploy does not publish them while open.

## 1. Fresh sealed backup + drift check (owner window)
1. `powershell -File supabase\production\run_backup_and_seal.ps1` (prompts for the Production password; read-only transactions; ends with `SEALED: all 14 checksums OK` and the backup folder).
2. `powershell -File supabase\production\run_readonly_preflight.ps1` : markers must show migration 20 only (all 21-29 markers `false`) and the 7 migration-19 preconditions `MATCH` (see `docs/PRODUCTION_RELEASE_CHECKLIST.md`). Anything else: STOP and send the output.

## 2. Phase A: database before the Hub (owner window)
`powershell -File supabase\production\run_release_phase.ps1 -Phase A -ReleaseCommit <40-char sha> -BackupDir C:\EFZ-backups\<timestamp>`
Add `-DryRun` first (no connection). It checks the manifest hashes, release commit, clean tree, backup (sealed, BRACKET OK, <= 24 h) and the pinned CA, then applies 19, 19b, 21-28, 29a, 29b*, 29c, 29d one file at a time (single transaction, lock_timeout 30 s), checks each file's applied-marker and writes an attempt marker. It stops at the first problem; a failed step is rolled back. Close every other EFZ tab and client first (a concurrent session deadlocked migration 11 once).
Afterwards a read-only preflight is saved in `C:\EFZ-checks\M29_release\...\post_preflight.txt`.

## 3. Hub deploy and smoke test
Merge the release commit to `main` (fast-forward) so Vercel builds Production. Check the sidebar build stamp shows Production and the release commit. Smoke test as Super Admin: sign-in, requests inbox, create -> confirm -> processing -> dispatch -> deliver an order (cancel any test order afterwards, never delete), Users page lists the five new request permissions.
Rollback of the Hub: Vercel dashboard, promote the previous deployment (`c1e873b`). Database objects from phase A are additive; the old Hub keeps working until phase C.

## 4. Phase C: enforce dispatch (owner window)
`powershell -File supabase\production\run_release_phase.ps1 -Phase C -ReleaseCommit <sha> -BackupDir C:\EFZ-backups\<timestamp> -HubConfirmed "HUB <first 7 of sha> IS LIVE AND SMOKE TESTED"`
Then verify: `psql ... -f supabase\checks\production_post_checks_READONLY.sql` (use the same TLS connection string as the preflight): payment methods enabled = 0, `stg_test` absent, credit OFF, dispatch md5s as expected.

## 5. Rollback (database)
Reverse order, one file at a time, from `supabase\rollback\`: `29e_enforce_dispatch_rollback.sql`, `29_dispatch_rollback.sql` (the `dispatched` enum label remains; unused), then `28`...`21` rollbacks, `19b`, `19` (19 refuses once `assigned` events exist). Function text after a rollback is logically identical but may differ in line endings. Last resort: the same-day sealed backup (restore drill in `supabase/production/BACKUP_AND_RESTORE_DRILL.md`, to a scratch database first).

## 6. Things that stay OFF in Production
Payment providers and credit (migration 23/25 leave both OFF; the post-check proves it), the `stg_test` payment method and the `staging-test-payment` / `payments` / `credit-daily` Edge Functions, customer email verification (`REQUIRE_EMAIL_VERIFICATION`), and email password recovery in the Android Production build (`EXPO_PUBLIC_EMAIL_RECOVERY_ENABLED` unset => the sign-in screen tells customers to contact EFZ). Turn each on only after its end-to-end test on the Production project.
