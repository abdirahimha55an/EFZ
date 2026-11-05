# Inquiry rate-limit hardening (migration 31)

Status (2026-11-04): the application half is built, wired into the forms and unit-tested (96 tests, jsdom 34/34). Migration 31, its rollback and its checks are written and pass the PostgreSQL parser (syntax only). **They have never run against a database**, so nothing is applied anywhere. Applying migration 31 changes nothing by itself: until the owner stores a secret the function behaves exactly like migration 30.

## Weaknesses in migration 30 this fixes
1. The per-network limit trusts the first `x-forwarded-for` hop, which a caller can set. One abuser can rotate fake addresses and skip the limit, or send a victim's address to lock them out.
2. One flooder can fill the single 300-per-hour global bucket and block every real visitor.
3. The per-contact limit is bypassed by changing phone or email.

## What is built (this branch)
- `lib/inquirySignature.ts`: reads the address from `x-vercel-forwarded-for` / `x-real-ip` only (Vercel sets these; plain `x-forwarded-for` is never used), and signs `ip|timestamp|submissionKey` with HMAC-SHA256. `verifyClientProof` is the same rule the database must apply (5-minute window, constant-time compare).
- `lib/inquiryRoute.ts` + `app/api/inquiries/route.ts`: `POST /api/inquiries` strips any proof fields the browser sends, adds its own, and calls the existing RPC with the anon key (no service-role key). Without a secret, a trusted address or a submission key it forwards unsigned.
- Backward compatible: proof fields travel inside `p_payload`, which migration 30 ignores, so the route works against the current database. Caveat (to confirm on Staging): in legacy mode the database sees the route's own address (Vercel) in `x-forwarded-for`, not the visitor's, so the per-network limit may be shared by all visitors. Ship the route only together with migration 31 and the secret.
- `lib/inquirySignature.test.ts`: 6 tests (header trust, signature tamper/expiry/future, no-proof cases, route behaviour). `npm run test:hub` is 89/89.
- The forms now post to `/api/inquiries` (`lib/inquirySubmit.ts`, wired in `lib/supabase/queries.ts`). Route errors keep the database sentence and code (429 for limits); an unreachable database returns a generic 502 without echoing its text. The submission key is signed in canonical lower-case uuid form.
- Security review notes: the signature binds address, time and submission key (not the content), so a captured proof cannot be reused for another submission key or after 5 minutes, and a replay of the same request is idempotent. A proof can only be minted through the route, which signs the caller's own platform-reported address. Secret rotation is not built: to rotate, store a new secret and update Vercel together; requests in flight in that moment fall into the unverified bucket for up to 5 minutes.

## Migration 31 (written, untested)
Files: `supabase/31_inquiry_rate_limits.sql`, `supabase/rollback/31_inquiry_rate_limits_rollback.sql` (restores the migration 30 function), `supabase/checks/31_inquiry_rate_limits_checks.sql` (legacy mode, valid/wrong/expired/other-key/other-secret signatures, forged `x-forwarded-for` ignored, replay, verified network limit, bucket isolation, email limit across phones, secret not readable by clients). The checks file has never run; expect to fix mistakes on the first Staging run, which is the real test.
What it does: a one-row `inquiry_signing_secret` table (no client access); strict mode only when a secret is stored; verified and unverified global buckets (300/h and 20/h) via a new `ip_verified` column; a separate per-email limit with a second advisory lock; constant-time-style signature comparison through a random throwaway key (pgcrypto in the `extensions` schema). Optional later: Cloudflare Turnstile in the route.

## Owner action when this goes live
Add one server-only variable, `INQUIRY_HMAC_SECRET` (at least 32 random characters), in Vercel for Preview first and Production later, and the same value in the database. Until it exists the route simply forwards unsigned.

## Order
Staging restored, apply 30 if needed, run its checks, apply 31, run the 31 checks and fix, store a test secret on Staging and set `INQUIRY_HMAC_SECRET` on the Preview, browser run, Preview. Production only after Staging proof and owner approval, migration before app.
