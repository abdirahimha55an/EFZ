# Staging verification: public inquiries (migrations 30 + 31) on `integration/pre-launch`

Written 2026-11-05, reviewed and corrected the same day (second pass). **Staging only** (`adjjamiqwboawqedaapi`).
Production is `rodmdvfjashiohgwople`: nothing here is ever run against it.
Migration 31 has so far only been **parsed**, never executed. Treat the first run of section 6 as the real test and expect to fix mistakes.
Commands are written for Git Bash. The `node -e` lines work unchanged in PowerShell; for `VAR=value command` lines use `$env:VAR="value"; command` there.

## 0. Safety: how this procedure is kept away from Production

**Neither `30_public_inquiries.sql` nor `31_inquiry_rate_limits.sql` checks which project it runs in.** Their only guards are dependency checks, so applied to the
wrong project they would succeed. The protection is therefore the following, in this order. Do not skip any line.

1. **Work only in a worktree of this branch, never in the main checkout.** The main checkout's `.env.local` points at **Production**. Never copy it. Create a new
   `.env.local` in the worktree from the Staging dashboard (Project Settings, API).
2. **Prove the env file is Staging-only** (prints no values; exits non-zero otherwise):
   ```bash
   node -e "const s=require('fs').readFileSync('.env.local','utf8');const a=s.includes('adjjamiqwboawqedaapi'),b=s.includes('rodmdvfjashiohgwople');console.log(a&&!b?'OK: Staging only':'REFUSED: not Staging-only');process.exit(a&&!b?0:1)"
   ls -a | grep "^\.env"      # only .env.local (and .env.e2e / .env.example). No .env.production.local, .env.development.local or .env
   ```
   Next.js also reads those other `.env*` files and shell variables, which override `.env.local`. Make sure `NEXT_PUBLIC_SUPABASE_URL` is not set in your shell
   (`echo "$NEXT_PUBLIC_SUPABASE_URL"` prints nothing).
3. **Supabase CLI.** `--project-ref` is accepted only together with `--linked` (the CLI rejects it alone), so every command below uses
   `--linked --project-ref adjjamiqwboawqedaapi`. If a directory was ever linked to Production, `--linked` could resolve to it, so link **this worktree** to Staging first
   and confirm:
   ```bash
   supabase link --project-ref adjjamiqwboawqedaapi          # may ask for the database password; also the fix if db query reports "IPv6 is not supported on your current network" (seen on this PC)
   cat supabase/.temp/project-ref                            # must print exactly: adjjamiqwboawqedaapi   (the folder is git-ignored)
   supabase projects list                                     # Staging must show ACTIVE_HEALTHY; leave Production alone
   ```
   Re-read the ref in the command before pressing Enter, every time.
4. **Second line of defence, built in:** both SQL check scripts abort with `REFUSED` unless Staging's synthetic markers exist (`prod-stg-*` products, `u-stg-admin`
   Super Admin) and Production's markers are absent (`prod-1787244881309`, `u-1`). The E2E script refuses a `.env.local` that is not the Staging project, and
   refuses an `E2E_BASE_URL` that is not `localhost`/`127.0.0.1` unless you set `E2E_ALLOW_REMOTE_BASE=1` (only for a Preview you have confirmed uses Staging).
   These guard the **checks and the test script**, not the two migration files, which is why points 1 to 3 matter.
5. **Never `git add -A` blindly** after secret handling in section 7: secret scratch files are ignored by `.gitignore` (`.inquiry-secret*`), but check `git status` before committing.

## 1. Preconditions (all read-only)
| Needed | How to confirm |
| --- | --- |
| Staging restored | Dashboard shows the project active; `supabase projects list` shows `ACTIVE_HEALTHY`. **Owner action.** |
| Branch and commit | `git rev-parse --short HEAD` equals the release candidate named in `docs/PROJECT_STATUS.md`; `git status --short` is empty |
| Staging identity | `supabase db query --linked --project-ref adjjamiqwboawqedaapi "select (select count(*) from public.products where id like 'prod-stg-%') as stg_products, (select count(*) from public.profiles where id = 'u-1') as prod_marker"` expects `stg_products` of 1 or more and `prod_marker` 0. Anything else: **stop, you may be on the wrong project.** |
| Migration state | `supabase db query --linked --project-ref adjjamiqwboawqedaapi "select to_regprocedure('public.submit_public_inquiry(jsonb)') is not null as m30, to_regclass('public.inquiry_signing_secret') is not null as m31, (select count(*) from public.public_inquiries) as inquiries"` (the last column needs M30; if M30 is missing the query errors, which also answers the question) |
| Empty inquiry table | `inquiries` must be 0 before **each** run of a check script (both scripts refuse otherwise). Clean up per section 9 first. |
| No stored secret | Before the 31 checks only (section 6): `select count(*) from public.inquiry_signing_secret` (after M31) must be 0. The 31 checks do a plain `insert` into this one-row table and fail on a duplicate; they also test "no secret stored" behaviour. |
| Staff passwords | `.env.e2e` (git-ignored) holds them; never print it |

## 2. Execution order and dependencies
| Row | Step | Depends on | Notes |
| --- | --- | --- | --- |
| A | Staging active, identity confirmed (sections 0 and 1) | owner restores Staging | |
| B | `30_public_inquiries.sql` | the 18b website-request objects and base helpers: `submit_order_request(jsonb)`, `validate_request_phone(text)`, `has_permission(text)`, `current_profile_id()`, tables `website_request_settings`, `notifications`, `permissions`. Its own pre-guard refuses if any is missing. | Idempotent. Staging already had it in early November per the project notes; confirm with the state query, re-apply is harmless. |
| C | `30_public_inquiries_checks.sql` | row B, empty `public_inquiries`, Staging synthetic data | expects `M30 CHECKS: 100 PASS, 0 FAIL` |
| D | `31_inquiry_rate_limits.sql` | **row B** (its own pre-guard: "migration 30 is not applied - refusing"); `pgcrypto` in schema `extensions` (the file creates it if missing; if pgcrypto already lives in another schema the signature code cannot find `extensions.hmac` and the 31 checks will say so) | Idempotent, one transaction, forward only. Behaves exactly like 30 until a secret is stored. |
| E | `31_inquiry_rate_limits_checks.sql` | row D, empty table, **no stored secret** | expects `M31 CHECKS: <n> PASS, 0 FAIL` |
| F | E2E `30_inquiries_e2e.mjs` in legacy mode | rows B and D, a local Hub on Staging | 34 PASS. Run **before** storing the secret (see section 6). |
| G | Store the secret, set `INQUIRY_HMAC_SECRET`, restart/redeploy | row E passed with 0 FAIL | strict mode starts |
| H | Signed-path proof, then browser run | row G | |
| Rollback | the reverse: **31 first, then 30** | | section 10 |

## 3. Environment variables (names only; values come from the dashboards)
| Variable | Where | Value |
| --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | worktree `.env.local`; Vercel **Preview** scope | the **Staging** project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` (or `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, which wins when both are set) | same | the **Staging** public key |
| `INQUIRY_HMAC_SECRET` | same two places; server-only, never `NEXT_PUBLIC_`; Vercel Preview scope only (optionally limited to branch `integration/pre-launch`), marked **Sensitive** | 64 hex characters generated in section 7, Staging-only, identical to the database value |
| `SUPABASE_SERVICE_ROLE_KEY` | not used by the inquiry feature | leave unset on Preview and out of `.env.local` for this work |
| `E2E_ENV` | shell | path to the git-ignored `.env.e2e` |
| `E2E_BASE_URL` | shell | default `http://localhost:3000`; remote only with `E2E_ALLOW_REMOTE_BASE=1` |

`NEXT_PUBLIC_*` values are **baked into the build**. Before running a production-mode server for section 6, `rm -rf .next` and rebuild with `.env.local` = Staging; a stale build
(including the placeholder-value builds made during code review) would talk to the wrong URL.

**Vercel Preview must not point at Production.** Vercel, Project, Settings, Environment Variables: the `Preview` scope lists the Staging URL/key and `INQUIRY_HMAC_SECRET`;
the `Production` scope keeps the Production values. Anything under "All Environments" that holds a Production URL is a defect. Claude could not check this (no Vercel login on
this PC). After a Preview deploys, confirm it from the outside: open the Preview, DevTools, Network, any request to `*.supabase.co` must be `adjjamiqwboawqedaapi`.

## 4. Local checks (no database; repeat after any change)
```bash
npx tsc --noEmit                        # expect no output
npm run test:hub                        # expect: tests 102, pass 102, fail 0
npx eslint app components lib proxy.ts  # expect 0 errors (41 cosmetic warnings: unused imports, <img>)
npx next build --webpack                # expect the route list incl. /about /admin/inquiries /contact /wholesale and /api/inquiries (dynamic); needs no database
npm i --no-save jsdom esbuild           # only if missing; then:
node scripts/inquiry-forms-dom-test/run.mjs && node scripts/inquiry-forms-dom-test/admin-run.mjs   # DOM: 34 PASS / ADMIN DOM: 24 PASS
```
(`next build` with Turbopack fails in a git worktree whose `node_modules` is a junction to another folder; use `--webpack` there. A normal clone and Vercel are unaffected.)

## 5. Migration 30 (skip the apply if the state query showed m30 = true)
```bash
supabase db query --linked --project-ref adjjamiqwboawqedaapi -f supabase/30_public_inquiries.sql
supabase db query --linked --project-ref adjjamiqwboawqedaapi -f supabase/checks/30_public_inquiries_checks.sql
```
Expected: the check script always ends in an error whose text is the report: `M30 CHECKS: 100 PASS, 0 FAIL` (the transaction rolls back everything it did).
`REFUSED: ...` means a precondition (Staging markers, M30 applied, empty table) failed: read the message, do not work around it.

## 6. Migration 31 (first real execution)
```bash
# 6a. apply: idempotent, one transaction, refuses unless 30 is applied. Expected notice: "31: inquiry rate limits installed (legacy mode: no secret stored yet)"
supabase db query --linked --project-ref adjjamiqwboawqedaapi -f supabase/31_inquiry_rate_limits.sql
# 6b. SQL checks: inquiry table empty, no stored secret
supabase db query --linked --project-ref adjjamiqwboawqedaapi -f supabase/checks/31_inquiry_rate_limits_checks.sql
```
No data backup is taken first: 31 only adds a column, two indexes and a table and replaces one function, drops nothing, and its rollback restores migration 30's
function. (Do not copy the inquiry table into `public` as a backup: new `public` tables are exposed through the API by default privileges.)
Expected 6b: error text `M31 CHECKS: <n> PASS, 0 FAIL`. Any FAIL: stop, read the line, decide whether the check or the migration is wrong, fix, rerun (6a is idempotent). Do not continue until 0 FAIL.
Covered: legacy mode equals migration 30; a valid signature is accepted and marked `ip_verified`; wrong, expired, other-key and other-secret signatures go to the unverified bucket (20/h)
with the address ignored; a forged `x-forwarded-for` is ignored once a secret exists; replay is idempotent; the same email is limited across phones; `anon`/`authenticated` cannot read `inquiry_signing_secret`.

**E2E in legacy mode** (still no secret stored). Start the Hub locally against Staging, then run the script from a second terminal:
```bash
rm -rf .next && npm run build && npm start                    # terminal 1: .env.local = Staging (section 0), http://localhost:3000
# grant u-stg-delivery view_inquiries + manage_inquiries first (plain INSERT into user_permissions; see docs/PUBLIC_INQUIRIES.md)
E2E_ENV=<path to .env.e2e> E2E_BASE_URL=http://localhost:3000 node --import ./scripts/register-test-loader.mjs supabase/checks/30_inquiries_e2e.mjs
```
Expected: **34 PASS, 0 FAIL**, the first run of this script through `/api/inquiries` (earlier runs called the database function directly). Once the secret is stored, unsigned
localhost traffic falls into the 20-per-hour unverified bucket, so rerun the E2E in strict mode at most once an hour.

## 7. Store a Staging secret and turn on strict mode
Generates the secret into git-ignored scratch files **without printing it** and without putting it on a command line (command lines land in shell history and process lists):
```bash
node -e "const c=require('crypto'),f=require('fs'),q=String.fromCharCode(39),s=c.randomBytes(32).toString('hex');f.writeFileSync('.inquiry-secret.tmp',s);f.writeFileSync('.inquiry-secret.sql.tmp','insert into public.inquiry_signing_secret (secret) values ('+q+s+q+') on conflict (id) do update set secret = excluded.secret, updated_at = now();')"
supabase db query --linked --project-ref adjjamiqwboawqedaapi -f .inquiry-secret.sql.tmp      # database side
rm .inquiry-secret.sql.tmp
node -e "const f=require('fs');f.appendFileSync('.env.local','INQUIRY_HMAC_SECRET='+f.readFileSync('.inquiry-secret.tmp','utf8')+'\n')"   # local server side
```
Then the Vercel Preview: dashboard, Environment Variables, add `INQUIRY_HMAC_SECRET`, scope **Preview** only, **Sensitive** on; open `.inquiry-secret.tmp` in an editor and paste the single line
(no spaces, no newline). Redeploy: variables apply to new deployments only. Finally `rm .inquiry-secret.tmp` (the value then lives only in the database, `.env.local` and Vercel).
Properties: 64 hex characters (256 bits; the database requires 32 or more and the route ignores shorter), generated by the OS random source, never printed, never committed, never the same as a Production value.
**Mismatch is silent but safe:** if the three copies differ (a stray space, an old value), signatures fail and every visitor lands in the 20-per-hour unverified bucket instead of failing open.
That is why section 8 proves the signed path. **Rotation:** run the same commands again (the insert upserts) and update Vercel in the same sitting; requests in flight for up to 5 minutes use the unverified bucket.
Restart the local server after changing `.env.local`.

## 8. Proof that the signed path works, then the browser run
Local server restarted with the secret. The route trusts `x-real-ip` (on Vercel the platform sets `x-vercel-forwarded-for` instead), so a header sent from here exercises the same code:
```bash
node -e "fetch('http://localhost:3000/api/inquiries',{method:'POST',headers:{'content-type':'application/json','x-real-ip':'203.0.113.50'},body:JSON.stringify({kind:'contact',name:'E2E-INQ signed',email:'signed@example.com',subject:'s',message:'m',submissionKey:crypto.randomUUID()})}).then(async r=>console.log(r.status,await r.text()))"
supabase db query --linked --project-ref adjjamiqwboawqedaapi "select name, ip_verified, ip_hash is not null as has_hash from public.public_inquiries where name = 'E2E-INQ signed'"
```
Expected: `200 {"id":"<uuid>"}`, then `ip_verified = true, has_hash = true`. Repeat with the `x-real-ip` header removed (and a new name, `E2E-INQ unsigned`): `ip_verified = false, has_hash = false`.
If the first request is `false/false`, the secret does not match between `.env.local` and the database (or the server was not restarted): fix this before anything else.
On a Vercel Preview the same result is expected from a normal browser submission, and `ip_hash` must differ between two networks (Wi-Fi vs mobile data).

**Legacy-mode concern to settle (section 6 data):** with only migration 30 (or 31 without a secret) the database sees the route's own address in `x-forwarded-for`, not the visitor's. Compare
`select count(distinct ip_hash)` over E2E rows submitted from the local server: one value for all of them confirms the per-network limit is shared by every visitor in that mode, which is why migration 31 and
the secret must go live together with this route.

**Browser run** (Chrome, against the Staging-backed Hub or Preview):
| # | Do | Expect |
| --- | --- | --- |
| 1 | `/contact`, submit empty | field errors, nothing sent, focus on first invalid field |
| 2 | submit a valid message (phone `061 234 5678`) | success state; row appears in `/admin/inquiries` for Super Admin within seconds; bell and menu badge increment |
| 3 | double-click Send / press Enter twice | one inquiry only |
| 4 | repeat the same message | no second row |
| 5 | send 4 different messages from one phone | the 4th shows the "already have your recent messages" sentence (`WR429`) |
| 6 | `/wholesale` valid and invalid (missing business type) | success / inline errors |
| 7 | restart the local server with `NEXT_PUBLIC_SUPABASE_URL=https://invalid.invalid` set in the shell (use `npm run dev`; throwaway, never in `.env.local`), submit | generic "temporarily unavailable" message (502), no technical text; restart normally afterwards |
| 8 | `/admin/inquiries` as Super Admin: open, change status, add and edit a note, assign | each action recorded in the timeline; a deep link to an inquiry opens it |
| 9 | as `u-stg-delivery` without `view_inquiries` | menu item absent, `/admin/inquiries` shows no data |
| 10 | footer on desktop and at 375px width | Facebook and TikTok icons open the owner's pages in a new tab; no Instagram/X icons; Quick Links all resolve |
| 11 | `/about`, navbar and footer links, `/admin/login` | all pages load; no dead `#` links; no "Forgot Access" button |

## 9. Cleanup (Staging only)
```sql
delete from public.public_inquiries where name like 'E2E-INQ%';     -- notes and events cascade; also delete any row you created by hand in the browser run
delete from public.user_permissions where user_id = 'u-stg-delivery' and permission_code in ('view_inquiries','manage_inquiries');   -- only if you granted them
```
Before **re-running either check script** the table must be empty again (`select count(*) from public.public_inquiries` is 0) and, for the 31 checks, no secret may be stored
(`delete from public.inquiry_signing_secret;` returns to legacy mode, then store a secret again in section 7).

## 10. Rollback (Staging; the same files are the Production rollback)
| Situation | Action | Result |
| --- | --- | --- |
| Strict mode misbehaves (everyone throttled, wrong signatures) | `delete from public.inquiry_signing_secret;` and remove `INQUIRY_HMAC_SECRET` from Vercel/`.env.local` | legacy mode at once, no restart of the database; the route forwards unsigned. Nothing else changes. |
| Migration 31 misbehaves | `supabase db query --linked --project-ref adjjamiqwboawqedaapi -f supabase/rollback/31_inquiry_rate_limits_rollback.sql` | migration 30's function restored, `inquiry_signing_secret` dropped. `ip_verified` and two indexes stay (additive, harmless). No inquiry rows lost. The app keeps working: the route sends proof fields that migration 30 ignores. |
| Migration 30 must go too | roll back **31 first**, then `supabase/rollback/30_public_inquiries_rollback.sql` | removes the inquiry tables, functions and policies; **deletes stored inquiries**, so export them first |
| App problem on the Preview | redeploy the previous Preview or delete the branch deployment | Production untouched |
| Secret leaked or rotated | section 7 again, database and Vercel together | requests in flight for up to 5 minutes use the unverified bucket |

## 11. Rollout rule for later (not authorised now)
Production would need, in this order, with explicit owner approval: fresh sealed backup, migration 30, migration 31 **and** the secret stored, `INQUIRY_HMAC_SECRET` in the Production scope, then the app deploy.
Do not ship the app with only migration 30 (the per-network limit would be keyed on Vercel's address). The Production secret must be a **different** value from Staging's.

## Pass criteria for "ready for Production review"
Sections 5 (100/100), 6 (0 FAIL, E2E 34/34), 8 (signed proof true/false pair, browser table complete), Preview confirmed Staging-only, cleanup done, results recorded in `docs/PROJECT_STATUS.md`.

## Preflight record, 2026-11-05 (Staging restored; nothing written to any database)
- **Identity:** worktree linked to `adjjamiqwboawqedaapi` (`supabase/.temp/project-ref`); read-only transaction on; 5 `prod-stg-*` products; `u-1` and `prod-1787244881309` absent; `u-stg-admin` is a Super Admin.
- **`.env.local`** for the worktree: Staging URL and the Staging **anon** key only, produced from the CLI key listing without printing it; the token's own claims were checked (`role=anon`, `ref=adjjamiqwboawqedaapi`) and the file passes the section 0 guard. No service-role key is present anywhere in the worktree.
- **State:** migration 30 present and **identical to the repo file** (8 of 8 functions); migration 31 absent (`inquiry_signing_secret` does not exist); `u-stg-delivery` holds no inquiry permission yet (the section 6 grant is a write, done after approval). All `u-stg-*` profiles needed by the checks have logins except `u-stg-nologin` (by design).
- **Local checks on this tree:** tsc clean; 102/102 unit tests; jsdom 34/34 and 24/24; lint 0 errors (40 cosmetic warnings); `next build --webpack` passes with the Staging URL baked in and no Production reference in the build output.
- **Vercel Preview:** deployments for `396152d` and `db1d452` succeeded, but the Preview is behind Vercel Deployment Protection (every request redirects to the Vercel login), so its environment cannot be inspected from outside. It needs a Vercel login (or the owner reading Settings, Environment Variables).
- **Not verifiable yet:** whether the Staging passwords in `.env.e2e` (written 2026-10-03) are still valid (first sign-in is part of the E2E run).

### The one blocker: three leftover test inquiries
Both check scripts start with a guard that refuses to run unless `public.public_inquiries` is empty (`REFUSED: public_inquiries is not empty`), because their limit assertions count rows. These three rows (the owner's own browser tests of 2026-10-26, submitted while signed in as the Staging Test Super Admin, status `new`, no notes) are the only thing in the way:
| id | kind | created (UTC) |
| --- | --- | --- |
| `8e1b6db9-38be-4e13-a444-8021abe93c02` | contact | 2026-10-26 12:26:41 |
| `8b5b38cc-2abc-4d85-ab4b-7924b57ac52d` | contact | 2026-10-26 12:28:42 |
| `57840cfb-34fa-417b-a383-2722cb84286f` | wholesale | 2026-10-26 12:29:46 |

Deleting them also removes their 3 `submitted` events (cascade). **Not done: needs the owner's explicit approval.** The statement, once approved, is
`delete from public.public_inquiries where id in ('8e1b6db9-38be-4e13-a444-8021abe93c02','8b5b38cc-2abc-4d85-ab4b-7924b57ac52d','57840cfb-34fa-417b-a383-2722cb84286f')` on Staging only.

## Verification results, 2026-11-05 (Staging `adjjamiqwboawqedaapi`, owner-approved)
Every database step was preceded by a check that the worktree link and the Staging markers identified Staging. Nothing was run against Production.
| Step | Result |
| --- | --- |
| Delete the 3 approved test inquiries | Done in one guarded transaction (aborts unless the table holds exactly those 3 rows and their 3 events). Afterwards only `public_inquiries` and `public_inquiry_events` differ from the pre-delete baseline; every other table fingerprint is identical. The 23 audit-log lines about inquiries were kept. |
| Section 5, migration 30 checks | **100 PASS, 0 FAIL** |
| Section 6a, apply migration 31 | Applied cleanly. State verified: signing-secret table exists (0 rows), `ip_verified` column present, function updated, `anon`/`authenticated` cannot read the secret, `anon` can submit. |
| Section 6b, migration 31 checks | First run **18 PASS, 1 FAIL (E1)**; after fixing two defects in the check itself, **19 PASS, 0 FAIL** (details below). |
| Section 6, legacy E2E through `/api/inquiries` | Run 1: **33 PASS, 1 FAIL (RT1, Realtime)**. Run 2: **34 PASS, 0 FAIL**. See below. |
| Section 7, secret | 64-hex secret generated without printing; database and `.env.local` values proved identical by sha256; scratch files deleted; local server restarted. |
| Section 8, signed path | Request with a trusted address header: stored `ip_verified = true` with an address hash; a different address gives a different hash. No header, forged proof fields in the body, and a forged `x-forwarded-for` were all stored `ip_verified = false` with **no** hash. |
| Section 8, browser matrix | **Not run in a real browser** (no browser automation was available). Substituted by: jsdom form tests 34/34 and admin inbox 24/24, the E2E, and a crawl of the served pages (below). |
| Section 9, cleanup | 16 synthetic E2E/proof rows deleted (the table had been verified empty before the runs; the transaction aborts on any non-`E2E-INQ` row) and the two temporary `u-stg-delivery` grants revoked. The signing secret stays stored, so Staging is in strict mode. |

**Defects found in `31_inquiry_rate_limits_checks.sql` (fixed; the assertion was strengthened, not weakened).** Check E1 had never run before. (1) B1 deliberately fills the 20-per-hour unverified bucket, so E1's unsigned submissions were refused by the *bucket* before the email rule could apply; the script now deletes B1's filler rows first. (2) E1 compared `left(result, 4)` with `'OK|,OK|,OK|,WR42'`, which can never match (`OK|` is followed by a UUID character); it now maps each result to `OK|` or its first five characters and requires exactly `OK|,OK|,OK|,WR429`, so a phone-validation error (`WR422`) can no longer pass for a limit refusal. Nothing in the migration changed.

**RT1 (Realtime) failed once in two runs.** A standalone probe on Staging showed Realtime working (the event arrived 0.3 s after the submission) and the second full run passed 34/34, so this is intermittent, not a service or policy fault. The likely cause is that the check does not wait for the channel's `SUBSCRIBED` status before submitting (it only races an 8-second timeout and ignores the result). Not yet changed; worth hardening so a failure says which it was. Treat the E2E as 34/34 on the second run, 33/34 on the first.

**Served-page crawl** (local Hub on Staging, GET only): 7 pages return 200; 6 internal and 4 external links, none dead, none `#`; Facebook and TikTok anchors open in a new tab with `rel="noopener noreferrer"`; no Instagram or X links; "Forgot Access" absent on `/admin/login`; both forms present with the honeypot field; `/privacy` and `/account-deletion` return 404 while the legal placeholders are open.

**Legacy-mode observation.** All rows submitted from the local server share one `ip_hash` (they all come from one machine), so this run cannot show whether, on Vercel, the database would see the visitor's address or the platform's. That still needs a Preview run with the secret in place.

### Vercel Preview inspection (read-only; project `efz`, team `efz1`, Hobby plan)
- Preview deployments exist for `396152d` and `db1d452` and are behind Vercel Deployment Protection.
- **Correct:** `NEXT_PUBLIC_SUPABASE_URL` has its own Preview entry and points at **Staging**. The Preview-only `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` is **accepted by Staging (HTTP 200) and rejected by Production (HTTP 401)**. The app prefers the publishable key, so the Preview talks to Staging.
- **Missing:** `INQUIRY_HMAC_SECRET` is **not set in any scope**. Until it is, the route forwards unsigned requests and the Preview would run in the weaker legacy path (and, with migration 31 now on Staging and a secret stored, every Preview visitor would fall into the 20-per-hour unverified bucket).
- **Risk:** `SUPABASE_SERVICE_ROLE_KEY` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` are each **one Sensitive entry scoped to both Production and Preview**, i.e. the same value in both. Sensitive values cannot be read back, so whether they are Production's cannot be proved from here, but a shared entry cannot hold two different projects' keys. The service-role key bypasses row-level security. The application code does not import it (only `lib/supabase/admin.ts` references it and nothing imports that file), so it is not used at runtime today, but it should not be present in Preview.
- **Proposed corrections (not applied, awaiting your approval):** (1) add `INQUIRY_HMAC_SECRET` for Preview only, marked Sensitive, using the Staging value that is stored in the Staging database (it exists only in the git-ignored worktree `.env.local`); (2) remove `Preview` from the shared `SUPABASE_SERVICE_ROLE_KEY` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` entries (leaving their Production scope untouched) and, only if the app needs it there, add Staging-valued Preview entries; (3) redeploy the Preview of `integration/pre-launch` and repeat the signed-path proof against it with a *Preview-only* test submission (the Preview is Staging-backed, so it writes only to Staging).
