# Production release plan: public inquiries, rate limits, product designs (migrations 30, 31, 32)

Prepared 2026-11-10 on `integration/pre-launch`. **Nothing here has been run against Production.** Production is still on Hub `4b9bca2` and at migration 29e.
Companion files (all in `supabase/production/`): `m30_32_preflight_READONLY.sql`, `run_m30_32_release.ps1`, `m30_32_postcheck_READONLY.sql`.

## Scope
Retained: the original public `/order` page (restored, byte-identical to `4b9bca2`, no design selection), Products, Footer and social icons, About, Contact and Wholesale with inquiries (M30 + M31 + the `/api/inquiries` route), Admin Hub inquiries inbox, Admin Product Designs, M32.
Also in the branch (not user-visible): removal of unreachable legacy code (`backend/`, `lib/storage`, `lib/data`, `lib/services`), lint fixes, docs.
Not in this release: Android, payments, credit, `/privacy` and `/account-deletion` (still 404 while legal placeholders are open; nothing in the Footer links to them).

## Migrations (order, all forward-only, one transaction each)
| # | File | Depends on | Effect |
|---|---|---|---|
| 30 | `30_public_inquiries.sql` | 18b objects | New tables/functions for inquiries; no existing table touched |
| 31 | `31_inquiry_rate_limits.sql` | 30, pgcrypto in schema `extensions` | Signed-address rate limits; strict mode only once a secret is stored |
| 32 | `32_order_designs.sql` | 18b, 22; live `submit_order_request` md5 `c819251209a3ae536b731340daaa3a4b` (it refuses otherwise) | `public_product_designs()`, design triggers/audit, replaces `submit_order_request` (identical behaviour without `designId`, which the restored form never sends) |
Migrations first, app second. The app tolerates a missing M32, but the Contact and Wholesale forms need M30 and the signing secret in place before the Hub that carries the route goes live.

## Production configuration (Vercel project `efz`, scope Production)
1. `INQUIRY_HMAC_SECRET`: **missing**, must be added (Production only, Sensitive, value different from Staging's). The release script generates it, stores it in the database and puts it on the clipboard; you paste it into Vercel. Without it the route forwards unsigned and the database throttles all visitors together as one unverified bucket (20/h).
2. Confirm (read-only, dashboard) that Production scope has `NEXT_PUBLIC_SUPABASE_URL` = `https://rodmdvfjashiohgwople.supabase.co`, a Production publishable or anon key and `SUPABASE_SERVICE_ROLE_KEY`. The service-role and anon entries are currently shared with Preview (Sensitive, scoped Production+Preview). The Preview build guard (`next.config.ts`) already refuses a Preview that points at Production, so this is not a release blocker; split the entries afterwards.
3. Variables apply to new deployments only: set `INQUIRY_HMAC_SECRET` **before** the merge to `main` that triggers the Production build.

## Findings reassessed
| Earlier finding | Now |
|---|---|
| Fresh sealed backup mandatory (newest 2026-10-21) | **Still open, owner-run** (needs the Production DB password). PITR off, no managed backups. |
| `INQUIRY_HMAC_SECRET` missing in Vercel | **Still open**, step 5 below. |
| Fingerprint of Production `submit_order_request` | Last read 2026-11-05 (match). **Re-read in the preflight** (M32 also refuses by itself if it differs). |
| M30/M31 only with their features | Features retained, so both are included. |
| M32 for Admin designs | Included. Note: the Admin screen works on the M22 table even without M32; M32 adds the guards/audit and no longer has any visitor-facing use. Rollback is proven, so it stays in scope. |
| Public `/order` changed by M32 | **Resolved**: restored in `00a1602`, approved by the owner on Preview. |

## Sequence (each numbered step needs the owner's go; nothing runs until Production is explicitly authorised)
0. Push the local docs/scripts commit (this plan and the three files above; no app code), so the Preview rebuilds. The **release commit is then that commit's full sha**; confirm its Preview is Ready.
1. Owner: sealed Production backup. `powershell -File supabase\production\run_backup_and_seal.ps1` (password at the prompt; must end `SEALED: all N checksums OK`). Recommended, not a gate: a fresh encrypted off-machine copy (`C:\EFZ-checks\M19\truncate_hardening\closeout\encrypt_backup_copy.ps1`).
2. Owner: `powershell -File supabase\production\run_m30_32_release.ps1 -Step Preflight`. Every verdict `OK`; keep the baseline counts. Anything else: stop and send it.
3. Owner: `powershell -File supabase\production\run_m30_32_release.ps1 -Step Apply -ReleaseCommit <40-char sha> -BackupDir C:\EFZ-backups\<timestamp>` (gates: clean tree, HEAD = release commit, sealed backup <= 24 h, pinned file hashes).
4. Owner: `... -Step Secret`, then add `INQUIRY_HMAC_SECRET` in Vercel (Production, Sensitive) by pasting; clear the clipboard (`Set-Clipboard -Value $null`).
5. Owner: `... -Step PostCheck`. Every verdict `OK`; counts equal the baseline.
6. Deploy: fast-forward `main` to the release commit (`4b9bca2` is its ancestor; 27+ commits ahead) so Vercel builds Production. Check the sidebar build stamp shows Production and the sha.
7. Smoke test (live, minimal): `/order` looks as before; `/contact` and `/wholesale` submit one inquiry each marked "TEST - ignore", seen in `/admin/inquiries`, then closed (do not delete); `/admin/product-designs` opens for Super Admin (create nothing); the Hub sign-in and orders list still work.
8. Record the result in `docs/RELEASE_RUNBOOK.md`.
Post-release: Super Admin only handles inquiries until delegated; staff add designs only when wanted (none exist on Production; the order form never shows them); watch `/admin/inquiries` for the first week; no E2E or check script ever against Production; split the shared Vercel Sensitive entries; plan a recurring backup (PITR is off).

## Rollback
- **App:** Vercel dashboard, promote the previous Production deployment (Hub `4b9bca2`, deployed 2026-10-21 09:30Z). The old app works with the migrations applied.
- **Database, reverse order, one file at a time (owner-run, same connection method):** `32_order_designs_rollback.sql` (restores the 18b function; design rows kept), `31_inquiry_rate_limits_rollback.sql` (restores the M30 function, drops the secret table), `30_public_inquiries_rollback.sql` (**refuses once inquiries exist**; then roll back the app and fix forward). Fast mitigation without any rollback: `delete from public.inquiry_signing_secret;` and remove the Vercel variable returns to legacy mode at once.
- **Last resort:** restore the sealed backup of step 1 to a scratch database first (`supabase/production/BACKUP_AND_RESTORE_DRILL.md`).

## Go / no-go
**GO for owner execution**, conditional on: sealed backup (1), preflight all `OK` (2), the secret on Vercel before the merge (4). No code blocker remains. Known, accepted limits: no CAPTCHA, no email notification for inquiries (in-app only), wholesale benefit wording is the owner's and unverified, legal pages hidden.
