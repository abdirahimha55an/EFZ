# EFZ Customer app (Android) - Expo skeleton plan

Status: **plan only, no app code exists.** Written 2026-10-17 on branch `android/customer-accounts`. Start implementing only after the
gating items in "Before the first line of app code" are resolved. Everything below the database (`my_customer_account`, `customer_catalog`,
`my_orders`, the registration Edge Function) already exists on Staging except where marked MISSING.

## Before the first line of app code (gates)

| # | Gate | Owner | Status 2026-10-17 |
| --- | --- | --- | --- |
| 1 | Registration Edge Function deployed to **Staging** (`deploy-staging.ps1`) | owner: Supabase CLI + login | not done (no CLI/token here) |
| 2 | Decide email verification: on (recommended, needs custom SMTP + code templates) or off for Staging only | owner | undecided |
| 3 | Expo account + EAS project (free tier is enough for development builds) | owner | not done |
| 4 | A way to run Android: an emulator (Android Studio) or a physical device with USB debugging | owner | not verified |
| 5 | Owner decisions: commission ownership of app customers, website catalog stays public or not | owner | open |

## Project structure

A **separate repository** (`efz-customer-app`), not a folder of this Next.js repo: it keeps Vercel's build, the web lint/typecheck and the web
dependency tree untouched. Share the database types by copying the generated/hand-written `database.types.ts` subset the app needs
(it is a snapshot; regenerate from Staging with `supabase gen types` when the schema changes).

```
efz-customer-app/
  app.config.ts            reads env, fails the build on a project/APP_ENV mismatch (see Environment)
  eas.json                 profiles: development, staging, production
  app/                     Expo Router (file based)
    _layout.tsx            providers (QueryClient, SessionProvider), splash until the session + account state are known
    index.tsx              redirect by state (see Routing)
    (auth)/sign-in.tsx  register.tsx  verify-email.tsx  forgot-password.tsx  reset-password.tsx
    (gate)/pending.tsx  rejected.tsx  suspended.tsx  no-account.tsx
    (app)/_layout.tsx      tabs
    (app)/catalog.tsx      private catalog (customer_catalog)
    (app)/orders/index.tsx order history (my_orders)
    (app)/orders/[id].tsx  order detail: items with design names, payments (receipt data), balance
    (app)/account.tsx      status, name, sign out
  src/lib/supabase.ts      the only place the client is created (secure storage adapter)
  src/lib/api.ts           typed wrappers over the three customer RPCs + the Edge Function
  src/lib/errors.ts        maps database/auth errors to sentences (never shows raw SQL text for unknown errors)
  src/state/session.tsx    session + account-status state machine
  src/components/ ...
```

Stack: Expo (current SDK at kickoff), TypeScript strict, Expo Router, `@supabase/supabase-js` 2.x, `expo-secure-store`,
`@react-native-async-storage/async-storage`, `@tanstack/react-query`, `react-hook-form` + `zod`, `expo-notifications` (later milestone). No state library beyond that.

## Routing and the status gate

The app has one source of truth for "what may this user see": the session plus `my_customer_account()`.

| Session | `my_customer_account().status` | Screen |
| --- | --- | --- |
| none | - | `(auth)/sign-in` (register, forgot password links) |
| yes, email unconfirmed | - | sign-in is refused by Auth (`email_not_confirmed`) -> `(auth)/verify-email` |
| yes | `null` (no customer account: a staff user or unknown sign-in) | `(gate)/no-account`: explains and offers sign-out. Never any data. |
| yes | `pending` | `(gate)/pending` (polls every 60 s while foregrounded) |
| yes | `rejected` | `(gate)/rejected` (final; contact EFZ) |
| yes | `suspended` | `(gate)/suspended` |
| yes | `approved` | `(app)` tabs |

Rules: the gate is re-evaluated on app foreground and after any `42501` from a customer RPC (a suspension applies to the very next request, so a
`42501` means "re-check status", not "retry"). Deep links are not used in the first milestone (verification and recovery use codes, not links).
A client-side gate is a convenience: the database refuses every customer RPC for non-approved accounts regardless.

## Secure session storage

- supabase-js `auth.storage` = Supabase's documented **LargeSecureStore** pattern for Expo: a random AES key is kept in `expo-secure-store`
  (Android Keystore) and the encrypted session blob in AsyncStorage (SecureStore alone caps values at about 2 KB, a session is larger).
- `persistSession: true`, `autoRefreshToken: true` started/stopped with `AppState` (`startAutoRefresh` on active, `stopAutoRefresh` on background),
  `detectSessionInUrl: false`.
- Sign-out clears the session, the React Query cache and the key. Android `allowBackup: false` in `app.config.ts` so tokens never reach cloud backups.
- Never log tokens, passwords, codes or full RPC payloads; no analytics SDK in the first milestone.
- Only the **publishable key** is in the app. The service-role key and the registration salt exist only inside the Edge Function.

## Environment configuration

| Variable | Where | Value |
| --- | --- | --- |
| `APP_ENV` | EAS profile | `staging` or `production` |
| `EXPO_PUBLIC_SUPABASE_URL` | EAS profile environment | Staging `https://adjjamiqwboawqedaapi.supabase.co`; Production only for the production profile |
| `EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | EAS profile environment | the project's publishable key (public by design) |

Registration URL is derived (`<url>/functions/v1/register-customer`). `app.config.ts` **refuses to build** when the project ref in the URL does not match
`APP_ENV` (staging build must contain `adjjamiqwboawqedaapi`, production `rodmdvfjashiohgwople`) and the same check runs at app start, mirroring
`guard.mjs` used by the Hub's Staging tests. Staging builds are visibly labelled ("STAGING" banner) so a tester cannot mistake them for the real app.

## Integration with the approved-customer APIs

| Need | Call | Notes |
| --- | --- | --- |
| Register | `POST` Edge Function (`email`, `password`, `fullName`, `phone`, `organization?`) | 202 always for accepted/duplicate/staff-email (identical body); 422, 429 mapped to friendly text |
| Verify email (if enabled) | `auth.resend({ type: "signup", email })` then `auth.verifyOtp({ email, token, type: "signup" })` | needs custom SMTP + code in the *Confirm signup* template; see the function README |
| Sign in / out | `auth.signInWithPassword`, `auth.signOut` | |
| Forgot password | `auth.resetPasswordForEmail(email)` then `verifyOtp({ type: "recovery" })` then `auth.updateUser({ password })` | code based, no web redirect; needs the *Reset password* template to include the code |
| Account status | `rpc("my_customer_account")` | returns status, name, requested/reviewed time; no CRM data |
| Catalog | `rpc("customer_catalog")` | active products with price, `in_stock` flag; no cost, no exact stock |
| Orders | `rpc("my_orders")` | own orders only: items (design name, unit price), payments, balance, status; no cost/profit/commission/officer |
| **Place an order** | **MISSING** | see below |
| Notifications | **MISSING** | see below |

### Missing interfaces (each needs its own reviewed migration, not part of the skeleton)

1. **Order placement.** A customer cannot call `create_order`. The safe path is an account-bound request that staff confirm through the existing
   pipeline: a new function (for example `submit_customer_order_request`, Migration 22) that requires an *approved* account, accepts up to 20 lines with
   a design name per line (the existing request function allows each product once and has no design field), writes into `order_requests`/`order_request_items`
   linked to the account, and never accepts a customer id or price from the client. Staff convert it with the existing `convert_website_request`.
2. **Design catalog.** `order_items.design_name` is free text today. Decide: a `product_designs` table, or designs as separate products.
3. **Push notifications.** A `customer_push_tokens` table, a customer-scoped notification feed, and a sender (database webhook or Edge Function) that fires on order status changes.
   External setup: Firebase project, FCM v1 service-account key uploaded to EAS, Expo push credentials.

## Skeleton milestone: sequence and estimate (one developer with Claude)

| Step | Output | Estimate |
| --- | --- | --- |
| 1 | Scaffold, `app.config.ts` environment guard, Supabase client with LargeSecureStore, Staging banner | 0.5 day |
| 2 | Auth screens: sign-in, register (calls the Edge Function), verify-email, forgot/reset password | 1.5 days |
| 3 | Session + status state machine, the four gate screens, polling | 1 day |
| 4 | Private catalog screen | 1 day |
| 5 | Order history + detail | 1 day |
| 6 | Tests (below) and a Staging end-to-end run on an emulator | 2 days |
| | **Total** | **about 1 week** |

## Tests

- Unit (Jest + `jest-expo` + React Native Testing Library): the status state machine (every row of the routing table), error mapping, the environment guard
  (mismatched project/APP_ENV refuses), the registration form (validation, 202/422/429 handling), LargeSecureStore round trip with mocked stores.
- Contract tests against **Staging** with real accounts: pending/approved/suspended customers see exactly what the database tests promise (reuse the 81-check
  database suite for the server side; the app tests only assert the app reacts correctly to each answer).
- End to end (Maestro on an emulator): register -> pending screen -> approve in the Hub -> catalog appears -> orders list -> suspend in the Hub -> app returns to the suspended screen.
- Security checks in the pipeline: no service-role key or salt in the bundle (grep the built JS), `allowBackup` false, no `console.log` of session objects.

## Release path (later)

EAS Build `staging` profile -> internal testing track. Google Play requirements to confirm at that time: in-app account deletion (needs a deletion function: a
reviewed migration, because accounts are append-only history today), privacy policy URL, Data Safety form, and any closed-testing requirement for a new
developer account. Production builds only after the Production database work (backup, rehearsal, Edge Function deployment) is separately authorized.

## The exact next implementation step

Once gates 1-2 are resolved: **Step 1 and Step 2** above (scaffold + guarded environment + sign-in/registration against the Staging Edge Function), because
every other screen depends on a working, safely stored session.
