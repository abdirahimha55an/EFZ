# Public Contact & Wholesale inquiries (migration 30)

The public `/contact` and `/wholesale` forms used to do nothing on submit. They now store an inquiry that staff
work in **Admin > Orders & Requests > Contact & Wholesale** (`/admin/inquiries`).

**Status: applied to EFZ-Staging only. NOT on Production.** Production needs the owner's explicit approval (see "Production" below).

## How it works

```
/contact, /wholesale  --(anon)-->  submit_public_inquiry(jsonb)  --> public_inquiries (+ events, system_logs)
                                                                          |
   Realtime + 30 s poll (admin layout)  -->  badge, bell alert  -->  /admin/inquiries (RLS-scoped)
                                                                          |
                    set_public_inquiry_status / add|edit_public_inquiry_note / assign_public_inquiry
```

- **Write path:** the RPC is the only way a visitor writes. `anon` has no table privilege at all (no read, no insert), and
  nobody (not even the Super Admin) has INSERT/UPDATE/DELETE on the tables from the API.
- **Validation:** client checks in `lib/inquiryForm.ts` for instant feedback; the RPC checks the same rules again (names,
  lengths, email shape, Somali phone via the 18b `validate_request_phone`, wholesale business-type list, "a reply needs a phone or email").
- **Duplicates:** one `submissionKey` per filled-in form (a retry or double click returns the first inquiry; the key changes when
  the visitor edits anything) **and** identical repeat content within the window is not stored twice.
- **Abuse:** hidden honeypot field (`hp`, nothing stored); per-visitor limit (`website_request_settings`: 3 per kind per 24 h by
  default, keyed by canonical phone or lower-cased email); per-network limit (30 per hour per hashed client address, never stored raw);
  global backstop (300 per hour). Limit sentences are written for visitors (`WR429`).
- **Staff access:** four new flat permissions, granted explicitly and **to nobody by default** (Super Admin only until delegated,
  per the launch decision): `view_inquiries` (assigned to me), `view_all_inquiries`, `manage_inquiries` (notes, contacted/closed),
  `assign_inquiries`. Delegation works exactly like website requests (Users & Privileges > Inquiries). Revocation is immediate.
- **Status:** `new -> contacted -> closed`; `new -> closed`; a closed inquiry can be reopened as `contacted`. Notes are append-only
  history (edits keep the old text on the timeline). Assigning notifies the assignee.
- **Audit:** every submission, move, note and assignment writes a timeline event and a `system_logs` line (written by the database).
- **Contact details on the public site:** the Contact page shows the WhatsApp number and email from Settings (no hardcoded
  addresses; the email row is hidden while Settings has none). No response-time promise is made anywhere.

## Files

| What | Where |
|---|---|
| Migration (forward only) | `supabase/30_public_inquiries.sql` |
| Rollback (refuses while inquiries exist) | `supabase/rollback/30_public_inquiries_rollback.sql` |
| SQL security + behavior checks (always rolls back; 100 checks) | `supabase/checks/30_public_inquiries_checks.sql` |
| Live E2E over PostgREST as real Staging staff + Realtime (34 checks) | `supabase/checks/30_inquiries_e2e.mjs` |
| Unit tests (validation mirror) | `lib/inquiryForm.test.ts` (in `npm run test:hub`) |
| Form behavior tests in jsdom (34) / admin inbox in jsdom (24) | `scripts/inquiry-forms-dom-test/run.mjs`, `admin-run.mjs` |
| Public forms | `components/public/{ContactForm,WholesaleForm,fields}.tsx`, `app/contact`, `app/wholesale` |
| Admin | `app/admin/inquiries`, `components/admin/inquiries/*`, `app/admin/layout.tsx` (nav, badge, alert, Realtime) |

## Running the checks (Staging only)

```bash
# SQL checks: one transaction that always ends in an error whose text is the report ("M30 CHECKS: n PASS, m FAIL")
supabase db query --linked --project-ref <STAGING ref> -f supabase/checks/30_public_inquiries_checks.sql

# unit tests
npm run test:hub

# E2E (needs .env.local = Staging, E2E_ENV = path to the git-ignored .env.e2e). It needs u-stg-delivery to hold view_inquiries and
# manage_inquiries: grant before, revoke after (both are plain INSERT/DELETE on user_permissions). Test rows are named "E2E-INQ ...";
# delete them as the table owner afterwards: delete from public.public_inquiries where name like 'E2E-INQ%';
E2E_ENV=<path to .env.e2e> node --import ./scripts/register-test-loader.mjs supabase/checks/30_inquiries_e2e.mjs

# jsdom tests (jsdom and esbuild are not project dependencies)
npm i --no-save jsdom esbuild
node scripts/inquiry-forms-dom-test/run.mjs
node scripts/inquiry-forms-dom-test/admin-run.mjs
```

## Production (not done; needs the owner's explicit approval)

1. **Production's state was not read by this work.** Per the project notes it is at M20 and its guards for 21-29 are unreconciled
   (see `docs/REMAINING_BEFORE_PRODUCTION.md`). Migration 30 deliberately depends only on the 18b objects (`submit_order_request`,
   `validate_request_phone`, `website_request_settings`) and the base helpers, not on 19 or later, and touches no existing table. Its own
   pre-guard refuses if they are missing. Confirm with a read-only query before applying.
2. Back up first (`supabase/production/`), apply `30_public_inquiries.sql`, run the SQL checks only if a clean-room Staging-like
   data set is used (the checks assume the Staging synthetic profiles and refuse on Production by design).
3. Deploy the Hub build **after** the migration (the forms call `submit_public_inquiry`; before the migration they show
   "This form is temporarily unavailable. Please contact us on WhatsApp instead.").
4. Delegate access in Users & Privileges only when the owner wants anyone besides the Super Admin to handle inquiries.

## Known limitations

- Email notifications are not sent (no mail provider is configured on the project). Staff are alerted in the Hub (badge, bell,
  Realtime) and the visitor is told we will reply on the phone/email they gave.
- No CAPTCHA (needs a third-party account); the honeypot, three database limits and the audit trail are the abuse controls.
- The 300/hour global backstop is deliberately blunt: a determined flood from many identities closes the forms for up to an hour
  (visitors are then pointed to WhatsApp). The constants live in `submit_public_inquiry`.
- `guard_system_logs_insert` is not extended: a signed-in client with insert rights on `system_logs` could write a line that
  *looks* like an inquiry audit line; its `origin` column says `client`. (Same exposure as other audit lines added since 18.)
- Wholesale benefit copy on `/wholesale` ("significant discounts", "free delivery within Mogadishu", partner warranty) was left
  as the owner wrote it; it is marketing content this change did not verify.
