# register-customer (Supabase Edge Function)

Creates a **pending** customer account for the Android app. It is the only way a customer account is created: Auth
sign-up stays **disabled** project-wide, so nobody can create an Auth user through the public Auth API.

Status: written and tested locally (`npm run test:registration`: 14 unit tests, plus 5 integration tests against a local database).
**Not deployed anywhere.** This workstation has no Supabase CLI, Deno or Docker, no Supabase access token, and no saved Supabase login.

## How it stays safe

- The service-role key lives only in the function's own environment (injected by Supabase). It is never in this repository,
  the Next.js app or the Android app. The Android app holds only the public URL and publishable key.
- The caller is anonymous, so the function is deployed with `--no-verify-jwt`. Its protection is the input validation, the
  database rate limits (3 registrations per phone, 10 per hashed address, 300 in total per 24 h) and the fact that it can only
  create a *pending* account: a pending account sees no catalog and no orders until a staff member approves it in the Hub.
- The Auth user is created with `app_metadata.efz_kind = "customer"` (a user cannot set `app_metadata`). The database trigger
  never links such a user to a staff profile, even when the email matches staff, whether it is confirmed at creation or later. A staff
  email, or an email that already has an account, creates nothing and receives the **identical** success response.
- The client address is used only as a salted hash for rate limiting. The password goes to the Admin API only: it is never
  logged or stored, and the function does not log request bodies.

## Prerequisites and their verified status (2026-10-17)

| # | Prerequisite | Verified status |
| --- | --- | --- |
| 1 | Migration 21 applied to the target project | Staging: yes (2026-10-17 07:43Z). Production: **no** |
| 2 | Auth sign-up disabled | Staging: **verified** (`disable_signup: true`, public settings endpoint). Production: reported disabled 2026-10-02 |
| 3 | Supabase CLI | **Missing.** Not on PATH, no `~/.supabase`. Latest on npm: `supabase@2.121.0` (`npm i -g supabase@2.121.0` or the Windows release binary). Not installed by Claude: it is the owner's tool and login |
| 4 | Authentication | **Missing.** `SUPABASE_ACCESS_TOKEN` is not set, no Supabase entry in the Windows credential store. The owner runs `supabase login` (interactive browser flow) in their own terminal |
| 5 | Edge Functions on the project's plan | **Gateway reachable, plan not readable.** `GET /functions/v1/register-customer` on Staging answers `404 NOT_FOUND "Requested function was not found"`, i.e. the Functions gateway is live and the function simply is not deployed. The plan tier itself needs the access token (or the Dashboard: Settings > Billing). Per [Supabase's pricing docs](https://supabase.com/docs/guides/functions/pricing) Edge Functions are included on the Free plan (500,000 invocations per organization per month) and Pro/Team (2 million), so this is not expected to block |
| 6 | Secret `REGISTRATION_HINT_SALT` | **Not set** (needs 3-4). Provisioning method below |
| 7 | Custom SMTP + code email templates | **Not verified**, required only for email verification and password recovery (see below) |

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected into every Edge Function by Supabase. Do **not** set secrets with the
`SUPABASE_` prefix (the CLI refuses) and never paste the service-role key anywhere, including chat.

## Provisioning `REGISTRATION_HINT_SALT` safely

The salt only hashes client addresses for rate limiting, but treat it as a secret anyway. `deploy-staging.ps1 -Deploy` does this for you:
it generates 32 random bytes, writes them to a throw-away file readable only by you, passes the file to
`supabase secrets set --env-file`, and deletes it in a `finally` block. The value is never printed, logged or put on a command line (a
command-line argument would be visible in the process list and shell history, which is why the plain `secrets set NAME=value` form is avoided).
Rotating it later only resets the per-address counters. If you prefer to do it by hand, generate the value with a password manager and use
`supabase secrets set --env-file <protected file> --project-ref adjjamiqwboawqedaapi`, then delete the file.

## Deploy and smoke test (Staging only; run by the owner)

```powershell
# one-time, in YOUR terminal (nothing is pasted anywhere else)
npm i -g supabase@2.121.0
supabase login
$env:EFZ_STAGING_PUBLISHABLE_KEY = "<Staging publishable key>"   # public by design; not a secret

cd <repo root>\supabase\functions\register-customer
.\deploy-staging.ps1            # preflight only: CLI, login, Staging visible, sign-up disabled, tests pass. Changes nothing.
.\deploy-staging.ps1 -Deploy    # creates the salt secret if missing, deploys with --no-verify-jwt
.\deploy-staging.ps1 -Smoke     # valid / repeat (identical body) / invalid phone / short password / GET
```

The script refuses the Production ref (`rodmdvfjashiohgwople`), a checkout linked to Production, and a Staging project whose sign-up is enabled.
Then verify in the database (read-only): one `pending` `customer_accounts` row with `customer_id` null, one `registered` event, and **no** `profiles` row for the email.
Smoke-test accounts are append-only history and stay on Staging (use only `@example.test` emails).

Expected responses: valid -> `202 {"status":"pending_approval",...}`; repeat -> identical body, no second account; staff email -> identical body, nothing
created; phone `12345` or short password -> `422`; 4th registration for one phone in 24 h -> `429`; `GET` -> `405`.

## Email confirmation and password recovery

Today (`REGISTRATION_REQUIRE_EMAIL_VERIFICATION` unset) the Auth user is created **already confirmed**: nobody proves they own the mailbox. EFZ's phone/identity
check at approval is the control, so a stranger cannot get catalog or order access, but a typo in the email means the customer can never recover the password.

**Smallest secure implementation (proposal; needs the owner's Dashboard/SMTP work, no code beyond the switch already in `handler.ts`):**

1. Configure **custom SMTP** on the project. The built-in sender is limited to about 2 emails per hour project-wide ([rate limits](https://supabase.com/docs/guides/auth/rate-limits),
   [custom SMTP](https://supabase.com/docs/guides/auth/auth-smtp)), which would block registrations. Staging can use any transactional provider's free tier.
2. Edit two Auth email templates so they include the 6-digit code `{{ .Token }}` (keep the existing link too): **Confirm signup** and **Reset password**
   ([email templates](https://supabase.com/docs/guides/auth/auth-email-templates)). The templates are project-wide; staff only use password sign-in, so they are unaffected.
3. Set the function secret `REGISTRATION_REQUIRE_EMAIL_VERIFICATION=true`. The function then creates the Auth user **unconfirmed**; password sign-in is refused
   (`email_not_confirmed`) until the app confirms the code: `auth.resend({ type: "signup", email })` sends it, `auth.verifyOtp({ email, token, type: "signup" })` confirms.
   The confirmation fires the existing trigger, which skips customer-marked users (covered by database check A8).
4. Recovery uses the same code mechanism, no web page or deep link: `auth.resetPasswordForEmail(email)`, then `verifyOtp({ type: "recovery" })`, then `auth.updateUser({ password })`.
   OTP requests have their own limit of 360 per hour and a 60-second resend window ([passwordless/OTP](https://supabase.com/docs/guides/auth/auth-email-passwordless)).

Trade-offs: Supabase's responses to resend/recover for unknown emails can reveal whether an address exists (accepted for Phase 1; the registration endpoint itself does not). Until
steps 1-2 are done, leave the switch off; turning it on without working email would make every new account unconfirmable.

## Not done / out of scope here

- Production deployment (needs its own backup, rehearsal and approval as for every earlier Production change).
- CAPTCHA, account deletion (a Google Play requirement) and the app itself (see `docs/ANDROID_APP_PLAN.md`).
