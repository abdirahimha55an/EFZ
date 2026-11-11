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

## 7. Security log: Vercel credential cleanup (2026-11-11)
The Production database was not modified during the November 11 credential cleanup. No deployment was performed as part of that cleanup. Separately, on November 10, the existing known-good Production deployment was redeployed after the inquiry-signing secret was configured. No application code or database migrations were deployed as part of the November 11 cleanup.

**Context (2026-11-10).** `INQUIRY_HMAC_SECRET` did not exist in Vercel: the first inquiry-signing attempt left two test inquiries with `ip_verified = false`. The single row of `public.inquiry_signing_secret` was rotated in one guarded transaction, the new value was entered in Vercel by the owner (Sensitive, Production only, created 2026-11-10 15:03Z) and Production was redeployed (deployment `dpl_6ks3NSzZ5YHRmCG5Tgj3kEBtZrFp`, commit `60cb998`, READY 15:12Z). A new test inquiry then had `ip_verified = true`; exactly one secret row remained; the seven business-data counts matched their baselines.

**Findings that led to the cleanup**
- `SUPABASE_SERVICE_ROLE_KEY` was one manual entry shared by Production and Preview. No code reads it: only `lib/supabase/admin.ts` did, imported only by `db.server.ts` (`getAdminDb`), which nothing imports. No script, workflow, cron or `vercel.json` uses it; Edge Functions use Supabase's own injected copy.
- A Supabase integration (marketplace, installed 2026-09-24, Production project `rodmdvfjashiohgwople`, only the `efz` Vercel project selected) had created 13 Production-only variables. The Hub reads only one of them (`NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`).
- Deployment checks: none on any recent deployment. The "Supabase Preview" GitHub check comes from Supabase's GitHub app, not from these variables; the repo has no `supabase/config.toml` or `migrations/`.

**Before and after (Vercel environment entries)**
| | Before | After |
|---|---|---|
| Entries in total | 19 | **6** |
| Integration-managed entries | 13 | 1 |
| Entries in Preview | 3 | 2 (Staging URL, Staging publishable key) |
| Entries in Development | 0 | 0 |

Removed: `SUPABASE_SERVICE_ROLE_KEY` (Production+Preview, 2026-11-10 15:49Z); then on 2026-11-11, in this order: `POSTGRES_USER` (test, watched 5 minutes), then `POSTGRES_HOST`, `POSTGRES_DATABASE`, `POSTGRES_PASSWORD`, `POSTGRES_URL`, `POSTGRES_URL_NON_POOLING`, `POSTGRES_PRISMA_URL`, then `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY`, `SUPABASE_JWT_SECRET`.
Kept: `NEXT_PUBLIC_SUPABASE_URL` (Production, Preview), `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` (Production = integration-managed, Preview = manual), `NEXT_PUBLIC_SUPABASE_ANON_KEY` (Production, fallback only), `INQUIRY_HMAC_SECRET` (Production only).

**Verification evidence**
- Preview URL names the Staging project; the Preview publishable key is accepted by Staging's auth endpoint (a Staging key). Production URL names the Production project; its publishable key is rejected by Staging and equals the key inlined in the live bundle (fingerprint `ea0f381ccc`).
- Five minutes after the last deletion Vercel still listed 6 entries; none of the 13 removed variables had been re-added by the integration.
- Live site after each step: `/`, `/contact`, `/wholesale`, `/order` = 200; `/api/inquiries` answers 405 to a GET (route live). The public JavaScript contains no `sb_secret_` key, no JWT-shaped token and no reference to the removed variable names.
- Values-free before/after snapshots: `C:\EFZ-checks\vercel_env_housekeeping\`.

**Rules from this cleanup**
- The Supabase integration remains connected (write access to project variables). To remove it entirely, first turn the Production publishable key into a manual entry (its value is public), verify, then disconnect. Deleted values can be restored from the Supabase dashboard, or by reconnecting the integration (re-syncs all 13).
- Vercel CLI logins last 8 hours and refresh through the CLI's refresh token; direct API calls must refresh the same way. Run `vercel logout` when Vercel work is finished.
- Preview has no `INQUIRY_HMAC_SECRET`: Preview inquiries fall into the unverified bucket (harmless). A Preview value must be Staging's secret, never Production's.
- Code follow-up (branch `chore/security-cleanup-2026-11-11`, not merged): `lib/supabase/admin.ts`, `getAdminDb()` and the service-role line of `.env.example` removed.

