# Launch-readiness checklist

Prepared 2026-11-05 for `integration/pre-launch` (release candidate, see `docs/PROJECT_STATUS.md` for the exact commit). Nothing is merged to `main`, applied to a database, or deployed.
Legend: **DONE** = verified on this tree or in the repo today. **BLOCKED** = needs an external action. **DECIDE** = needs an owner decision. **OPEN** = not yet verified.
The Android app is a separate repository; its commercial-model question (open registration, arena partners) is a separate assessment and is **not** part of this release candidate.

## 1. Website (Hub, public pages)
| Item | State |
| --- | --- |
| tsc, 102 unit tests, jsdom 34 + 24, lint 0 errors, `next build --webpack` | **DONE** (re-run before release) |
| `/about`, `/contact`, `/wholesale`, footer links, no dead `#` links, no "Forgot Access" | **DONE** in code and jsdom; browser run **OPEN** (needs Staging) |
| Facebook and TikTok footer links (owner-supplied URLs); Instagram and X empty | **DONE**; **DECIDE** whether Instagram/X exist |
| `/wholesale` benefit copy ("significant discounts", free delivery in Mogadishu, partner warranty) | **DECIDE**: written by the owner, not verified against real terms |
| `/privacy` and `/account-deletion` | **BLOCKED**: all 11 placeholders in `lib/legal/content.ts` are open on this tree, so the pages 404. A partial draft (entity, phone, jurisdiction, handler) exists only as a local, unpushed Hub commit `ac823e5` on `android/customer-accounts`, not in this candidate. Owner supplies the rest. |
| Domain and sender email | **DECIDE**: no domain chosen; no email notifications exist for inquiries |

## 2. Android app (separate repo `efz-customer-app`, inspected read-only)
| Item | State |
| --- | --- |
| Working tree | **DONE**: clean, branch `feature/skeleton`, nothing uncommitted |
| `npm run verify` | **DONE**: typecheck, lint 0 errors (1 unused-import warning), 219/219 tests |
| Pushed | **OPEN**: 9 local commits (`5dbc839` and earlier: branding, `production-apk` profile, AAB script) are **not pushed** to `origin/feature/skeleton`; the "OTA TEST" subtitle commit was reverted (no such text remains) |
| Version / application id | **DONE**: 1.0.0; `so.efz.customer.staging` for Staging; Production `so.efz.customer` is **provisional and permanent once on Play: DECIDE** |
| Production signing, EAS `production` variables, Play Console account, store listing, privacy and deletion URLs | **BLOCKED**: owner accounts and legal text (see its `docs/LAUNCH_CHECKLIST.md`, `docs/RELEASE_PROCESS.md`) |
| EAS project owner | **DECIDE**: personal account `rami_ha55an` vs an organisation |
| OTA update verified on a device | **OPEN**: never run; an APK download problem on one phone was diagnosed as device-side, not proven |
| Payments, credit, email recovery | Intentionally **OFF** in Production; need provider accounts and an email sender domain |
| Customer approval gate | Unchanged. Open registration / partner pricing is a **DECIDE** (assessment delivered, nothing built) |

## 3. Supabase
| Item | State |
| --- | --- |
| Staging `adjjamiqwboawqedaapi` and Production `rodmdvfjashiohgwople` | **DONE**: both `ACTIVE_HEALTHY` since 2026-11-05. Read-only integrity audit: no data loss (see `docs/PROJECT_STATUS.md`). |
| Production backup | **BLOCKED (owner)**: newest sealed backup is `20261021-085210Z` (15 days old, one PC, checksums verified). A fresh sealed backup needs the owner to type the Production database password (`supabase/production/run_backup_and_seal.ps1`; its dry run passes). The encrypted off-machine copy needs the owner's passphrase and a destination (`C:\EFZ-checks\M19\truncate_hardening\closeout\encrypt_backup_copy.ps1`); the existing encrypted copy only covers folders up to about 2026-10-04. |
| Platform backups / PITR | **OPEN (owner)**: CLI shows PITR off and no managed backups for either project; check the plan and dashboard settings. |
| Production schema | Recorded at migration 29e; migrations 30 and 31 are **not** on Production |
| Migration 30 | Applied on Staging and identical to the repo file (8 of 8 functions); the 100-check script is blocked until 3 test inquiries are cleared (owner approval) |
| Migration 31 | **OPEN**: syntax-parsed only, never executed. It is not tested and not production-ready |
| Execution order | 30, 30 checks, 31, 31 checks, E2E, then the secret (`docs/STAGING_VERIFICATION_INQUIRIES.md` sections 2 and 5 to 8); rollback in reverse (section 10) |
| Supabase CLI | **DONE**: installed, logged in; `db query` needs `--linked --project-ref`; this PC reported an IPv6 error, so run `supabase link --project-ref adjjamiqwboawqedaapi` in the worktree first |

## 4. Vercel Preview
| Item | State |
| --- | --- |
| Preview uses Staging URL and key, not Production | **OPEN**: Vercel CLI is not installed or logged in here; the owner or Claude with a login checks Settings, Environment Variables (Preview scope only; nothing Production-valued under "All Environments") |
| `INQUIRY_HMAC_SECRET` (Preview, Sensitive, Staging-only value) | **OPEN**: created in section 7 of the verification procedure |
| Preview built from `integration/pre-launch` | **OPEN**: confirm a deployment exists for commit and that its Network tab calls only the Staging ref |

## 5. Security
| Item | State |
| --- | --- |
| `/api/inquiries`: size limit, proof fields stripped, HMAC-SHA256 over `ip|ts|submissionKey`, 5-minute window, constant-time compare, trusted-address headers only, no service-role key | **DONE** (code review, unit tests); database half **OPEN** until the 31 checks run |
| Legacy-mode caveat: route without migration 31 and its secret shares one per-network bucket (Vercel's address) | **OPEN**: confirm on Staging; rule is "ship route + 31 + secret together" |
| Secret handling (generated unprinted, ignored scratch files, Vercel Sensitive, different value per environment, rotation = upsert + Vercel) | **DONE** as procedure; **OPEN** until exercised |
| RLS and grants on inquiry tables and functions (anon may only submit; staff via permissions) | **DONE** in migration text and earlier Staging checks; re-verify after restore |
| Procedure cannot target Production by accident | **DONE** as far as possible: environment checks, `--linked`/`--project-ref` rules, check scripts that refuse non-Staging, E2E that refuses a Production env or a non-local base. The two migration files themselves have no environment guard. |
| Known gaps recorded earlier: no CAPTCHA, no email notifications, Android registration rate limit uses a forgeable address fallback, 300/day registration cap can be used up deliberately | **DECIDE** / backlog (see the Android commercial assessment) |

## 6. Order and inquiry submission
| Item | State |
| --- | --- |
| Contact and Wholesale forms: validation, honeypot, double-submit and repeat protection, per-phone/email/network/global limits, friendly error and WhatsApp fallback | **DONE** in code and jsdom; end-to-end through the route **OPEN** (Staging) |
| Existing website order requests (`/order`) | Unchanged by this candidate |
| Android orders | Pay-on-delivery requests only; payments and credit off |
| Data-layer rule: migration before app (the forms show "temporarily unavailable" until migration 30 exists) | **DONE** as documented |

## 7. Admin operations
| Item | State |
| --- | --- |
| `/admin/inquiries` inbox: statuses, notes, assignment, timeline, deep link, menu badge, bell, Realtime | **DONE** in code, jsdom, earlier Staging E2E; browser run **OPEN** |
| Who handles inquiries and requests, how fast | **DECIDE**: Super Admin only at launch; delegation via `view_inquiries`, `manage_inquiries`, `assign_inquiries` |
| Notifications | In-app only (no email or SMS provider configured) |
| Release record | Add the result to `docs/RELEASE_RUNBOOK.md` after any Production step |

## External dependencies still outstanding (nothing else blocks the website candidate)
1. **Restore Staging** (Supabase dashboard). Unblocks every verification step.
2. **Vercel access** (login, or the owner confirms the Preview environment scopes).
3. **Staging staff passwords in `.env.e2e`** and a Staging `.env.local` created in the worktree from the dashboard (never copied from the main checkout).
4. **Restore Production and take a fresh backup**, before any Production work, and within the pause window.
5. Owner inputs: legal text (11 placeholders), Instagram/X URLs if they exist, `/wholesale` benefit wording, domain and email sender, and approval for each later stage.
6. Android only: Play Console account and listing material, Production signing and EAS `production` variables, final application id, and a decision to push the 9 local commits.
