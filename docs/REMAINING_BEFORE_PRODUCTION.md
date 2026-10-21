# Remaining before Production (single consolidated list, 2026-10-21)
Production today: Hub `c1e873b`, database at migration 20. Release candidate: Hub `b85c794` (pushed, green CI, Staging Preview built; docs-only commits after it are local), Android `1fe18e7` pushed + `2864e99` (version 1.0.0) local. Procedure: `docs/RELEASE_RUNBOOK.md`.

## Done and verified (not to be repeated)
- Read-only Production preflights; fresh sealed backup `20261021-062637Z` restored and verified locally; full rehearsal 19..29e (suites, concurrency, rollback); generated CR-tolerant 29b/29e guards.
- Phase19 UI merged; Hub tsc/70+4 unit tests/build; release manifest and phase runner tested on a local restore; post-release safety SQL.
- Legal pages 404 without the preview flag and show a DRAFT banner with it (local builds). Android: lint 0 errors, 213/213 tests, bundle export and secret scan pass locally (the same steps as `.github/workflows/ci.yml`).
- Android CI itself: the repository is private; unauthenticated GitHub access returns 404, so the hosted run result could not be read. Check the Actions tab of `efz-customer-app` for commit `1fe18e7`.

## Decided (2026-10-21)
- Website Requests: Super Admin only at launch. NO request permissions are granted to other staff (`view/manage/assign/reject/convert_website_requests` stay ungranted; revisit after launch).
- Android app version 1.0.0: `app.config.ts` and `package.json` aligned (Android commit `2864e99`, local); the native fingerprint is unchanged, so existing Staging builds remain update-compatible.
- No domain now: email verification and recovery stay disabled; privacy/deletion URLs use the Hub address.

## A. Needs your decisions or content (nothing more I can do without them)
1. Legal details for `lib/legal/content.ts` (entity, address, contact, retention, deletion handler/time/scope, governing law). Pages stay 404 in Production until filled; app URLs then `https://efz-one.vercel.app/privacy` and `/account-deletion`.
2. Android: the final package ID only (`so.efz.customer` stays PROVISIONAL until the Play Console app exists) and whether the Expo project moves to `elite-football-zone` (before the first production build).
3. Email: no domain now, so customer email verification and email password recovery stay OFF in Production (Android hides recovery; contact EFZ instead). Revisit when a sender domain exists.

## B. Needs your accounts/credentials (you run it)
1. Google Play Console account, listing, Data safety, content rating, support email; EAS production keystore (generated on the first production build); Production EAS variables (public URL + publishable key + the two legal URLs).
2. Supabase CLI install and `supabase login`; then `deploy-production.ps1` for `register-customer` (after migration 21).

## C. Needs explicit approval at the time (each step, in order)
1. Optional: `NEXT_PUBLIC_LEGAL_PREVIEW=true` on the Vercel Preview to review the draft pages (live setting).
2. Window: fresh backup + drift preflight -> `run_release_phase.ps1 -Phase A` (19, 19b, 21-28, 29a, 29b*-29d) -> merge to `main` / Vercel Production deploy + smoke test -> `-Phase C` (29e) -> `production_post_checks_READONLY.sql`.
3. `register-customer` deploy. No permission grants at launch (Website Requests = Super Admin only).
4. First `.aab`: build, internal testing track, test with an invented approved customer, closed testing, staged rollout. No Production OTA until the first build is proven on a phone.

## Always off in Production
Real payment providers, credit, `stg_test`, `payments`/`credit-daily`/`staging-test-payment` functions, customer email verification, email recovery in the app.
