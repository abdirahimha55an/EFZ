# Inquiry rate-limit hardening (migration 31)

Status (2026-11-04): the application half is built and unit-tested. The database half (migration 31) is **not written as SQL yet on purpose**: it changes `submit_public_inquiry()` and cannot be tested until Staging is restored. Nothing here is applied anywhere, and nothing calls the new route yet.

## Weaknesses in migration 30 this fixes
1. The per-network limit trusts the first `x-forwarded-for` hop, which a caller can set. One abuser can rotate fake addresses and skip the limit, or send a victim's address to lock them out.
2. One flooder can fill the single 300-per-hour global bucket and block every real visitor.
3. The per-contact limit is bypassed by changing phone or email.

## What is built (this branch)
- `lib/inquirySignature.ts`: reads the address from `x-vercel-forwarded-for` / `x-real-ip` only (Vercel sets these; plain `x-forwarded-for` is never used), and signs `ip|timestamp|submissionKey` with HMAC-SHA256. `verifyClientProof` is the same rule the database must apply (5-minute window, constant-time compare).
- `lib/inquiryRoute.ts` + `app/api/inquiries/route.ts`: `POST /api/inquiries` strips any proof fields the browser sends, adds its own, and calls the existing RPC with the anon key (no service-role key). Without a secret, a trusted address or a submission key it forwards unsigned.
- Backward compatible: proof fields travel inside `p_payload`, which migration 30 ignores, so the route works against the current database unchanged.
- `lib/inquirySignature.test.ts`: 6 tests (header trust, signature tamper/expiry/future, no-proof cases, route behaviour). `npm run test:hub` is 89/89.
- Not yet done: the forms still call the RPC directly (`lib/supabase/queries.ts`, `inquiries.submit`). Switching them to `fetch("/api/inquiries")` is a deliberate later step.

## Migration 31 (to write and test on Staging first)
1. Store the shared secret where only the database can read it (a table with RLS on and no grants, or Supabase Vault), set by the owner, never in git.
2. In `submit_public_inquiry`: if `_ip`, `_ts`, `_sig` are present, recompute `hmac(_ip||'|'||_ts||'|'||submissionKey, secret, 'sha256')` (pgcrypto), require `now - _ts` within 300 s (and not more than 30 s ahead) and a constant-time compare. Valid: use `_ip` for the per-network limit. Otherwise: do not use `x-forwarded-for` at all; the inquiry is accepted into the **unverified** bucket.
3. Two global buckets: verified 300/h, unverified 20/h, so direct-RPC abuse cannot block real visitors. Record which bucket on the row (new column `ip_verified boolean`).
4. Limit by normalised phone and by normalised email separately.
5. Rollback script back to migration 30 behaviour; extend `supabase/checks/30_public_inquiries_checks.sql` style checks (valid, wrong, expired and replayed signature; bucket isolation; forged `x-forwarded-for` ignored; limit by phone and by email) and the E2E through the route.
6. Phase 2, optional: Cloudflare Turnstile in the route (needs an owner Cloudflare account and site key).

## Owner action when this goes live
Add one server-only variable, `INQUIRY_HMAC_SECRET` (at least 32 random characters), in Vercel for Preview first and Production later, and the same value in the database. Until it exists the route simply forwards unsigned.

## Order
Staging restored, then write migration 31 with its checks, apply to Staging, rewire the forms, browser run, Preview. Production only after Staging proof and owner approval, migration before app.
