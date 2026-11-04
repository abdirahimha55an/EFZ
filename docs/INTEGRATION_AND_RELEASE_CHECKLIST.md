# Integration and release checklist

Last updated 2026-11-04. Nothing below is merged to `main` or deployed to Production. The website and Android app are not open to customers. Only one external blocker remains: **Staging is paused** (restore in the Supabase dashboard).

## 1. Branches and how they combine

| Branch | Base | Content | Verified |
| --- | --- | --- | --- |
| `feature/public-inquiries` | main | Contact and Wholesale forms, migration 30, `/admin/inquiries` | Staging earlier: 83 unit, 100 SQL, 34 E2E, jsdom. Real-browser run pending Staging |
| `feature/inquiry-rate-limit-hardening` | public-inquiries | `/api/inquiries` signed-address route, forms wired to it, migration 31 + rollback + checks (written, never run) | unit tests, jsdom 34/34, route exercised with curl against an unreachable database (502, no leak); SQL parsed with the PostgreSQL parser (syntax only) |
| `fix/public-site-dead-links` | main | Footer dead links, no-op "Forgot Access?" | 76 unit, build |
| `feature/about-page` | dead-links | `/about` from published facts only | browser-viewed |
| `feature/social-links` | about-page | Footer Facebook and TikTok (owner-supplied URLs); Instagram and X empty | 80 unit, typecheck, lint, browser-viewed |
| `chore/remove-legacy-code` | main | Removes code with no importer | tsc, build |
| `chore/lint-errors` | remove-legacy-code | Lint errors 11 to 0 | lint, tsc, unit |
| `docs/project-status-update` | main | Status docs and this checklist | n/a |

**Integration branch `integration/pre-launch`** (off `origin/main` 4b9bca2) already contains social-links (with about-page and dead-links), lint-errors (with remove-legacy-code), rate-limit-hardening (with public-inquiries) and the docs. Two conflicts (`components/Footer.tsx`, `package.json` test list) were resolved: the footer keeps both guards, `test:hub` lists every test. Verified on the merged tree: tsc clean, 102/102 unit tests, lint 0 errors, jsdom 34/34 and admin 24/24, webpack build lists `/about`, `/admin/inquiries`, `/contact`, `/wholesale` and `/api/inquiries`. Not run: anything needing a database. The individual branches are unchanged.

Suggested merge order after owner review (each is a fast-forward or clean merge of its stack; re-run tests after each): dead-links, about-page, social-links, remove-legacy-code, lint-errors, public-inquiries (with its migration), rate-limit-hardening. Expect small conflicts in `package.json` (`test:hub` list) and `components/Footer.tsx` between the first group and `public-inquiries`; resolve by keeping both test lists.

## 2. Blocked on Staging (owner restores it, then Claude runs all of this)
- [ ] `supabase link`, confirm migrations through 29e and 30 on Staging.
- [ ] `30_public_inquiries_checks.sql` = 100/100, `30_inquiries_e2e.mjs` = 34/34.
- [ ] Chrome run of `/contact`, `/wholesale`, `/admin/inquiries` (script ready); fix defects.
- [ ] Apply migration 31 on Staging, run `31_inquiry_rate_limits_checks.sql` (never run: fix what the first run finds), set a test secret and `INQUIRY_HMAC_SECRET` on the Preview, rerun the E2E and the Chrome run against `/api/inquiries`.
- [ ] Confirm the Vercel Preview of each branch uses the Staging Supabase URL (needs `vercel login` or owner confirmation).

## 3. Owner decisions and inputs (not blockers for development)
- [ ] Production: restore, fresh sealed backup, plan decision (see recovery package, local only).
- [ ] `INQUIRY_HMAC_SECRET` (32+ random characters) in Vercel and the database, when hardening goes live.
- [ ] Instagram and X URLs, only if those accounts exist.
- [ ] `database/` legacy scripts: kept; delete only after owner review.
- [ ] Legal text in `lib/legal/content.ts`, email sender domain, Android package id, version, Expo owner, Play Console (see `docs/REMAINING_BEFORE_PRODUCTION.md`).

## 4. Before any Production release
1. Restore Production, verify, take a sealed backup with an encrypted off-machine copy, run the read-only integrity and financial checks.
2. Apply migration 30 (and 31 if ready) to Production **only with explicit owner approval**, migration before app.
3. Deploy the reviewed main to Production; smoke test public pages, `/admin/login`, an existing staff login.
4. Android release steps in the app repo's `docs/LAUNCH_CHECKLIST.md`.
5. Record the result in `docs/RELEASE_RUNBOOK.md`.

## 5. Independent work still open
Nothing substantial remains that can be verified without a database or an owner input. Candidates, all small: secret rotation (accept a current and previous secret; needs the Staging checks), Cloudflare Turnstile (needs an owner account and site key), `/products?category=` (needs product data to test). Android needs no code change (219 tests, lint clean).
