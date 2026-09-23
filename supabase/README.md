# EFZ Supabase Layer

The PostgreSQL schema, security policies and data import for Elite Football Zone.

> [!IMPORTANT]
> This is PostgreSQL / Supabase. The scripts in `../database/` are Microsoft T-SQL
> for a separate SQL Server target — do not mix the two.

## Files, in run order

| File | What it does |
| --- | --- |
| `01_schema.sql` | 13 enums, 18 tables, indexes |
| `02_functions.sql` | Auth helpers, financial triggers, commission ledger, transactional RPCs |
| `03_rls.sql` | Row Level Security on every table |
| `04_views.sql` | 8 reporting views |
| `05_seed.sql` | Permission catalog, settings row, testimonials, role presets |
| `06_data_import.sql` | Your real records. Generated — see below |
| `07_diagnostics.sql` | Integrity scanner, automatic repairs, operational metrics |

## Setup

### 1. Create the project

Create a Supabase project, then open **SQL Editor** and run `01` through `05`
and then `07` in order (`06` is your data - see below). Each file is
idempotent, so a re-run is safe.

### 2. Import your data

`06_data_import.sql` is generated from a localStorage backup:

```bash
node scripts/generate-supabase-import.mjs
# or point at a specific snapshot:
node scripts/generate-supabase-import.mjs Backup/efz_full_backup_2026-09-09.json
```

The script prints a summary and any warnings, then writes the SQL file. Paste it
into the SQL Editor and run it. It finishes with a verification block that
compares every trigger-computed order total against the backup and raises a
warning for each mismatch.

### 3. Create the Auth accounts

No password ever reaches this database. For each staff member, go to
**Authentication → Users → Add user** and use the **same email** as their
profile row. The `trg_on_auth_user_created` trigger links the new auth user to
the existing profile automatically.

From the 2026-09-09 backup that is:

| Email | Role | Profile id |
| --- | --- | --- |
| `admin@efz.so` | Super Admin | `u-1` |
| `abdi@efz.so` | Marketing Officer | `u-db5f39ee-…` |
| `hassan@efz.so` | Marketing Officer | `u-c4649f3f-…` |

A signup with an email that matches no profile gets a new **inactive** profile,
so an unknown account can do nothing until an admin activates it.

### 4. Configure the app

```bash
cp .env.example .env.local
```

Fill in `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` from
**Project Settings → API**. `SUPABASE_SERVICE_ROLE_KEY` is only needed for
server-side jobs — it bypasses RLS, so never expose it to a browser.

## How the schema works

### Money is never written by a client

`orders.total`, `cost`, `gross_profit`, `amount_paid` and `outstanding_balance`
are maintained by `recalc_order_financials()`, which fires whenever an order
item or payment changes. The app cannot write them — the TypeScript `Insert` and
`Update` types omit those columns, and the triggers would overwrite them anyway.
The same holds for `products.price` and the `order_items.line_*` columns, which
are generated columns.

This is what makes the numbers trustworthy: a total can no longer drift away
from the lines it is supposed to sum.

### Stock changes only through a ledger

`products.stock` moves in exactly two ways, each of which writes a
`stock_movements` row in the same transaction:

- `create_order()` deducts it, and refuses the whole order if any line is short.
- `adjust_stock()` handles everything else and refuses to go below zero.

Cancelling an order returns the stock; reactivating a cancelled order takes it
back off the shelf, and fails if it is no longer there.

### Commissions are history, not arithmetic

Every order that reaches `confirmed`, `processing` or `delivered` gets a
`commissions` row with the officer's rate **frozen at that moment**. Changing an
officer's percentage later never rewrites what they already earned. A commission
marked `paid` is immutable, and `orders.commission_paid` follows the ledger
automatically.

### Permissions are rows, not an array

The 26 codes in `OFFICIAL_PERMISSIONS` live in the `permissions` table, granted
per user through `user_permissions`. Every RLS policy calls
`has_permission('code')`, which short-circuits to true for a Super Admin.

`grant_role_preset(user_id, role)` applies a sensible default set for a role.

### Diagnostics scans for what constraints cannot catch

`run_diagnostics()` rewrites `public.system_issues` from nine checks. It does
**not** look for duplicate ids, orphaned references or negative stock — primary
keys, foreign keys and CHECK constraints refuse those at write time, so a
scanner hunting them would only ever find nothing.

What it looks for instead is data that is structurally valid but operationally
wrong: an order with no lines, a product priced below cost, a customer nobody
owns, a delivered order still owing money, active staff with no sign-in account.
Two checks watch the machinery itself — order totals that disagree with their
own lines, and profile commission totals that disagree with the ledger. A hit on
either means a trigger was dropped or bypassed, which is the most serious thing
this page can tell you.

Only those last two are `repairable`, because only they have a single correct
answer a machine can compute. `repair_issue()` recomputes them from source and
writes a CRITICAL audit line. Everything else needs a person to decide, and the
page says so rather than offering a button that would guess.

### RLS is the security boundary

The `proxy.ts` redirect away from `/admin` is a convenience. The real boundary
is `03_rls.sql`: even a signed-in user calling the REST API directly only sees
rows their permissions allow. A Marketing Officer with
`view_own_customers_only` cannot read another officer's customers no matter what
request they craft.

Views are declared `security_invoker = true`, so they respect the caller's
policies rather than the view owner's.

## Using it from the app

```ts
// Client Component
import { getDb } from "@/lib/supabase/db";

const db = getDb();
const orders = await db.orders.list({ status: "pending" });
const summary = await db.analytics.financialSummary();
```

```ts
// Server Component, Server Action or Route Handler
import { getServerDb } from "@/lib/supabase/db.server";

const db = await getServerDb();
const products = await db.products.listPublic();
```

Writes that touch more than one table go through an RPC so they are atomic:

```ts
await db.orders.create({
  customerId: "cust-1787416286614",
  items: [{ productId: "prod-1787244881309", quantity: 2, actualUnitPrice: 10 }],
});

await db.orders.addPayment({ orderId: "ORD-3567957", amount: 20, paymentMethod: "EVC" });
await db.orders.setStatus("ORD-3567957", "delivered");
await db.inventory.adjust("prod-1787244881309", 50, "New shipment", "import");
await db.commissions.pay("u-db5f39ee-…", [commissionId], { method: "EVC" });
```

Failures throw `EfzDbError`, which carries the Postgres `code` — `42501` means
RLS refused the operation, so the message can say "you don't have permission"
rather than something generic.

## Migration status

Done. Every page and shared component reads from Supabase; nothing imports
`lib/storage.ts` or `lib/data.ts` any more.

| Page | Source |
| --- | --- |
| `app/admin/login` | Supabase |
| `app/admin/layout.tsx` | Supabase |
| `app/admin/products` | Supabase |
| `app/admin/orders` | Supabase |
| `app/admin/customers` | Supabase |
| `app/admin` (dashboard) | Supabase |
| `app/admin/audit` | Supabase |
| `app/admin/diagnostics` | Supabase |
| `app/admin/users` | Supabase |
| `app/admin/analytics` | Supabase |
| `app/admin/system` | Supabase |
| `app/{page,contact,products,order,wholesale}` | Supabase |
| `components/{Navbar,Footer,FloatingWhatsApp,LayoutContent}` | Supabase |

### The public site

Five pages and four shared components render for signed-out visitors, so they
read only what anon is allowed:

- **Products** come from the `public_products` view, never the `products` table.
  The view has no `cost_price` column at all, so there is nothing for a visitor
  to read even by accident.
- **Branding** comes from `settings` through `usePublicSettings()` in
  `lib/settings.ts`, which shares one request across the navbar, footer,
  WhatsApp button and three pages instead of issuing six.
- **The order form** writes to `order_requests`, not `orders`. A stranger must
  not be able to create a real order — that would deduct stock and book revenue.
  The team reviews the request, then converts it with `convert_order_request()`.
  This insert is the only write anon is granted anywhere in the schema.

### Dead code left behind

`lib/storage.ts`, `lib/data.ts`, `lib/storage/`, `lib/services/` and
`lib/diagnostics/` — about 2,000 lines — are no longer imported by anything in
`app/` or `components/`. The only remaining reference is
`scripts/validate-approved-historical-orders.ts`, a one-off from the 2026-09-01
parent-order migration. They still carry most of the repo's lint errors.

`lib/financial.ts` and `lib/validators/` are **still in use** and should stay.

### Wiring a page

Wiring a page follows what `app/admin/products/page.tsx` does:

1. Swap `storage.getX()` for `await db.x.list()` inside the existing `useEffect`.
2. Add `isLoading`, `loadError` and `isSaving` state — these calls are now
   network calls, and buttons that fire them need to be disabled while in flight.
3. Replace `storage.canDoX(profile)` with `derivePermissions(profile)` from
   `lib/permissions.ts`.
4. Report failures with `describeDbError(error)`.
5. End every mutation with `await refresh()` instead of patching local state, so
   the screen shows what the triggers actually computed rather than what the
   client guessed.

A page that used to do bookkeeping by hand usually gets *smaller*. The orders
page lost about 120 lines of client-side stock arithmetic: `create_order()` and
`update_order_status()` already deduct, restore and re-deduct stock in the same
transaction that writes the order, and they refuse outright rather than leaving
stock half-moved. Delete now cancels first, so the units go back through the
ledger instead of vanishing with the row.

A view answers one question, and it is worth checking it is the question the
page is asking. `financial_summary` aggregates every order the caller may
select — the whole business. The dashboard uses it for managers and admins, but
a Marketing Officer scoped to `view_own_customers_only` wants *their* slice, so
their figures are summed from their own rows instead. Handing them the view's
totals would have shown them the company's revenue.

Reports should read a view, not re-derive the numbers. The customers page now
takes receivables from `customer_financials` and commissions from
`officer_commission_summary` instead of summing orders in the browser, so the
figures it shows are the same ones any other report would produce. The one
number still computed client-side is the forecast for orders that are *still
pending* — those have earned nothing yet, so no ledger row exists for them, and
pretending otherwise would put a guess where a fact belongs.

Four behaviours changed on the way, because they could not survive the move:

- **Deleting a product** now deactivates it (`is_active = false`) instead of
  erasing the row, so past orders keep their product link and their profit
  figures.
- **"Remember Session"** is gone from the login form. Supabase keeps the session
  in a cookie and rotates it per request; there was no longer a choice to offer.
- **Restore and factory reset** are gone from System Management. Overwriting a
  real database belongs in a reviewed script, not a button — use the import
  script above, or Supabase's Point-in-Time Recovery.
- **Deleting an order** cancels it first when it is not already cancelled, so
  its lines return to stock with a movement record explaining why.
- **Dashboard revenue** no longer counts cancelled orders. It used to, while the
  top-seller lists on the same page skipped them, so the headline and the
  breakdown disagreed. Every figure on that page now excludes them.
- **Failed sign-ins** no longer appear in the audit trail. The caller is not
  authenticated at that point and the insert policy is authenticated-only.
  Supabase Auth records them under Authentication → Logs, and the card on the
  audit page says so instead of showing a permanent zero.
- **The password field is gone** from the user form. Credentials live in
  Supabase Auth; a box here would look like it set something and quietly do
  nothing. The form now says where to invite the person instead.
- **"Recalculate Commissions"** recomputes profile totals from the ledger. The
  old version re-derived them from the order list at today's rate, which
  silently rewrote history whenever a percentage changed.
- **Clearing the audit log** is gone, and cannot come back: `system_logs` has
  an insert policy and no delete policy, so nobody can erase an entry. An audit
  trail anyone can clear is not an audit trail.
- **"Repair Storage"** became "Recompute Stored Totals". It used to re-index
  duplicate user IDs and fix broken references; a primary key refuses the first
  and a foreign key the second, so it had nothing left to do.
- **Diagnostics metrics** report the database (row counts, health score, errors
  in the last 24h, Postgres version) rather than localStorage quota and latency,
  which no longer describe anything.

One thing worth knowing about order creation: the order and its initial payment
are two calls, not one, because a payment is its own audited event. If the
payment fails the order still stands — unpaid — and the message says exactly
that rather than pretending nothing happened.

## Regenerating the TypeScript types

`lib/supabase/database.types.ts` is hand-written to match `01_schema.sql`. Once
the project is linked you can regenerate it instead:

```bash
npx supabase gen types typescript --project-id <your-ref> > lib/supabase/database.types.ts
```

Note that generated types do not mark trigger-maintained columns as read-only,
so the `Derived` guard in the current file would be lost.
