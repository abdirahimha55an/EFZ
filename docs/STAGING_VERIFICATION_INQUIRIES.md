# Staging verification: public inquiries (migrations 30 + 31) on `integration/pre-launch`

Written 2026-11-05. **Staging only** (`adjjamiqwboawqedaapi`). Nothing here is to be run against Production
(`rodmdvfjashiohgwople`); every script that connects refuses a Production URL, and you must still check the ref yourself.
Migration 31 has so far only been **parsed**, never executed. Treat the first run of step 4 as the real test and expect to fix mistakes.

## 0. Preconditions
| Needed | How to confirm |
| --- | --- |
| Staging restored (status ACTIVE) | Supabase dashboard, project `adjjamiqwboawqedaapi`. Owner action. |
| Staging at migrations through 29e | `supabase db query --linked --project-ref adjjamiqwboawqedaapi "select to_regprocedure('public.submit_order_request(jsonb)') is not null"` and the guards in `supabase/staging/RUNBOOK.md` |
| Staging synthetic data present (`u-stg-*` profiles) | `select count(*) from public.profiles where id like 'u-stg-%'` is 8 or more |
| Working tree on `integration/pre-launch` | `git rev-parse --short HEAD` equals the commit named in `docs/PROJECT_STATUS.md` |
| `.env.local` = Staging; `.env.e2e` holds staff passwords | `grep -c adjjamiqwboawqedaapi .env.local` is 1. Never print the values. |

## 1. Environment variables (names only; values come from the dashboards)
| Variable | Where | Value |
| --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | local `.env.local`, Vercel **Preview** | the **Staging** project URL (contains `adjjamiqwboawqedaapi`) |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` (or `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, which wins when both are set) | same | the **Staging** public key |
| `INQUIRY_HMAC_SECRET` | same, server-only, never `NEXT_PUBLIC_` | 32+ random characters, a **Staging-only** value, identical to the one stored in step 5 |
| `SUPABASE_SERVICE_ROLE_KEY` | not needed by the inquiry feature | leave unset on Preview |
| `E2E_ENV` | shell, path to the git-ignored `.env.e2e` | staff passwords for the E2E script |
| `E2E_BASE_URL` | shell | URL of the Hub that talks to Staging (default `http://localhost:3000`) |

**Preview must not point at Production.** Vercel dashboard, Project, Settings, Environment Variables: the `Preview` scope must list the
Staging URL/key and `INQUIRY_HMAC_SECRET`; the `Production` scope keeps the Production URL/key. Anything set for "All Environments" with a
Production URL is a defect. (Claude could not check this: the Vercel CLI is not installed or logged in on this machine.)
After a Preview deploys, `view-source` of any page, search for the Supabase ref in the bundled JS, and confirm it is `adjjamiqwboawqedaapi`.

## 2. Local checks (no database; repeat after any change)
```bash
npx tsc --noEmit                       # expect no output
npm run test:hub                       # expect: tests 102, pass 102, fail 0
npx eslint app components lib proxy.ts # expect: 0 errors (41 cosmetic warnings: unused imports, <img>)
npx next build --webpack               # expect: lists /about /admin/inquiries /contact /wholesale and /api/inquiries (dynamic)
```
(`next build` with Turbopack fails in a git worktree whose `node_modules` is a junction to another folder; use `--webpack` there. A normal clone and Vercel are unaffected.)

## 3. Migration 30 on Staging
```bash
supabase db query --linked --project-ref adjjamiqwboawqedaapi -f supabase/30_public_inquiries.sql           # skip if already applied
supabase db query --linked --project-ref adjjamiqwboawqedaapi -f supabase/checks/30_public_inquiries_checks.sql
```
Expected: the check script ends in an error whose text is the report: **`M30 CHECKS: 100 PASS, 0 FAIL`** (the transaction always rolls back).

## 4. Migration 31 (first real execution)
```bash
# 4a. back up the table you are about to alter (Staging data is synthetic, so a copy of the inquiries is enough)
supabase db query --linked --project-ref adjjamiqwboawqedaapi "create table if not exists public.zz_inquiries_pre31 as select * from public.public_inquiries"
# 4b. apply (idempotent, one transaction, refuses unless 30 is applied)
supabase db query --linked --project-ref adjjamiqwboawqedaapi -f supabase/31_inquiry_rate_limits.sql
# 4c. SQL checks. Run BEFORE storing a secret (the script inserts and rolls back its own)
supabase db query --linked --project-ref adjjamiqwboawqedaapi -f supabase/checks/31_inquiry_rate_limits_checks.sql
```
Expected 4b: notice `31: inquiry rate limits installed (legacy mode: no secret stored yet)`.
Expected 4c: error text `M31 CHECKS: <n> PASS, 0 FAIL`. Any FAIL: stop, read the line, decide whether the check or the migration is wrong, fix, re-run
(4b is idempotent). Do not continue to step 5 until 0 FAIL.
Behavioural expectations the checks cover: legacy mode behaves exactly like 30; a valid signature is accepted and marked `ip_verified`; wrong,
expired, other-key or other-secret signatures are accepted into the unverified bucket (20/h) with the address ignored; a forged `x-forwarded-for`
is ignored once a secret exists; replay is idempotent; the same email is limited across different phones; `anon`/`authenticated` cannot read
`inquiry_signing_secret`.

## 5. Store a Staging secret and turn on strict mode
```bash
# generate locally, do not paste it into chat or commit it
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
supabase db query --linked --project-ref adjjamiqwboawqedaapi "insert into public.inquiry_signing_secret (secret) values ('<THE VALUE>') on conflict (id) do update set secret = excluded.secret, updated_at = now()"
```
Put the same value in `.env.local` and the Vercel Preview as `INQUIRY_HMAC_SECRET`, then restart the local server / redeploy the Preview.

## 6. End to end through the real route
```bash
npm run build && npm start              # Hub on http://localhost:3000 with .env.local = Staging (or use a Preview and set E2E_BASE_URL)
# grant u-stg-delivery view_inquiries + manage_inquiries first (plain INSERT into user_permissions; see docs/PUBLIC_INQUIRIES.md)
E2E_ENV=<path to .env.e2e> E2E_BASE_URL=http://localhost:3000 node --import ./scripts/register-test-loader.mjs supabase/checks/30_inquiries_e2e.mjs
```
Expected: **34 PASS, 0 FAIL**. This is the first time the E2E goes through `/api/inquiries` (earlier runs called the RPC directly).
Then confirm the verified path really is used:
```sql
select ip_verified, count(*) from public.public_inquiries where name like 'E2E-INQ%' group by 1;   -- expect true for all rows when run from a Vercel Preview; on localhost there is no x-vercel-forwarded-for, so rows are false (unverified) and that is correct
```
**Open question to settle here:** on a Vercel Preview, `ip_verified` must be `true` and `ip_hash` must differ between two different networks
(e.g. Wi-Fi and a phone on mobile data). If every row is unverified, `x-vercel-forwarded-for` is not reaching the route; fix before anything else.
Also confirm the legacy-mode concern: with a secret **not** stored, requests via the route reach PostgREST from Vercel, so `x-forwarded-for` is
Vercel's address and all visitors may share one `ip_hash` (30/h cap for everyone). If `select count(distinct ip_hash)` over rows from two networks is 1,
that is why migration 31 and the secret must go live together with this route (see rollout rule below).

## 7. Browser run (Chrome, against the Staging-backed Hub or Preview)
| # | Do | Expect |
| --- | --- | --- |
| 1 | `/contact`, submit empty | field errors, nothing sent, focus on first invalid field |
| 2 | submit a valid message (phone `061 234 5678`) | success state; row appears in `/admin/inquiries` for Super Admin within seconds; bell and menu badge increment |
| 3 | double-click Send / press Enter twice | one inquiry only |
| 4 | repeat the same message | no second row |
| 5 | send 4 different messages from one phone | the 4th shows the "already have your recent messages" sentence and `WR429` |
| 6 | `/wholesale` valid and invalid (missing business type) | success / inline errors |
| 7 | stop the Staging database (or set a wrong URL on a throwaway Preview) | generic "temporarily unavailable" message, no technical text |
| 8 | `/admin/inquiries` as Super Admin: open, change status, add and edit a note, assign | each action recorded in the timeline; deep link to an inquiry opens it |
| 9 | as `u-stg-delivery` without `view_inquiries` | menu item absent, `/admin/inquiries` shows no data |
| 10 | footer on desktop and 375px width | Facebook and TikTok icons open the owner's pages in a new tab; no Instagram/X icons; Quick Links all resolve (no 404) |
| 11 | `/about`, navbar and footer links, "Forgot Access" absent on `/admin/login` | all pages load; no dead `#` links |

## 8. Cleanup
```sql
delete from public.public_inquiries where name like 'E2E-INQ%';   -- notes and events cascade
delete from public.user_permissions where user_id = 'u-stg-delivery' and permission_code in ('view_inquiries','manage_inquiries');  -- only if you granted them
drop table if exists public.zz_inquiries_pre31;
```
Also delete the test inquiries made by hand in step 7 (any row you created from the browser).

## 9. Rollback (Staging; the same files are the Production rollback)
| Situation | Action | Result |
| --- | --- | --- |
| Migration 31 misbehaves | `supabase db query ... -f supabase/rollback/31_inquiry_rate_limits_rollback.sql` | the migration 30 function is restored, `inquiry_signing_secret` dropped. `ip_verified` and two indexes stay (additive, harmless). No inquiry rows are lost. The app keeps working: the route sends proof fields that migration 30 ignores. |
| Migration 30 must go too | roll back **31 first**, then `supabase/rollback/30_public_inquiries_rollback.sql` | removes the inquiry tables, functions and policies; **deletes stored inquiries**, so export first: `copy public.public_inquiries to ...` |
| App problem on the Preview | redeploy the previous Preview / delete the branch deployment | Production untouched |
| Secret leaked or rotated | store a new secret in the table and in Vercel together | requests in flight for up to 5 minutes land in the unverified bucket |

## 10. Rollout rule for later (not authorised now)
Production would need, in this order, with explicit owner approval: fresh sealed backup, migration 30, migration 31 **and** the secret stored, `INQUIRY_HMAC_SECRET` set
in the Production scope, then the app deploy. Do not ship the app with only migration 30: the per-network limit would then be keyed on Vercel's address (see step 6).

## Pass criteria for "ready for Production review"
Steps 3, 4 (0 FAIL), 6 (34/34 and verified rows on a Preview) and 7 (all 11 rows) complete, Preview environment confirmed to be Staging-only, cleanup done, results recorded in `docs/PROJECT_STATUS.md`.
