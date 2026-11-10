# Expense Management (Phase 14) - migration 33

Implemented 2026-11-10 on branch `phase14/expenses` (from `main` 60cb998). **Applied to EFZ-Staging only. Not applied to Production, not merged to `main`, not deployed.**

## What it adds
- **Expenses** (`/admin/expenses`, Finance menu): submit, edit own pending/rejected, approve, reject (reason mandatory), resubmit, void, withdraw; separate payment records (unpaid / partly paid / paid); a register with filters, an event timeline per expense and dashboard figures (pending, approved, paid, approved-not-yet-paid, monthly trend, by category).
- **Profit after expenses** on `/admin/financial`: gross -> contribution -> net operating profit, per order and per product, plus an approved-expenses summary.
- Database: `supabase/33_expense_management.sql` (4 tables, 1 view, 8 functions, 4 permissions), rollback `supabase/rollback/33_expense_management_rollback.sql`, checks `supabase/checks/33_expense_management_checks.sql` (SQL, 96 checks) and `supabase/checks/33_expense_e2e.mjs` (through the Hub's data layer, 33 checks). Unit tests: `lib/finance/profit.test.ts` (11, hand-computed).

## Rules that are enforced by the database (not just the screen)
| Rule | How |
|---|---|
| Only RPCs write | No INSERT/UPDATE/DELETE grant or policy on any expense table; every RPC checks the caller |
| Nobody approves/rejects their own expense (Super Admin included) | `decide_expense()` refuses; table check `expenses_no_self_decision` is the backstop |
| Nobody voids their own *approved* expense | `void_expense()`; another approver must |
| Approved expenses are never silently modified | trigger `guard_expense_row()`: the only legal change is to void (with a reason); applies to the table owner too |
| Expenses are never deleted; events and payments are append-only | triggers; payments can only be voided, once |
| Approval is separate from payment | `record_expense_payment()` needs `pay_expenses`, an *approved* expense and cannot exceed the approved amount |
| Rejection and void need a reason (3-500 chars) | RPC + table checks |
| Every action is audited | each RPC writes an `expense_events` row and a `FINANCIAL` `system_logs` line in the same transaction (96-check proof: events = audit lines) |
| USD only, amount 0 < x <= 1,000,000 with at most 2 decimals, no future date | table checks + `expense_clean()` |
| Direct expense must name an order; operating must not | table check + RPC; the submitter must be able to see that order (`can_access_order`) |

Note for maintainers: inside `SECURITY DEFINER` functions `can_see_customer_order()` and `can_view_cost()` short-circuit to true (they test `current_user`). Migration 33 therefore uses `can_access_order()` (migration 11 documents this) and explicit permissions. The SQL checks caught this in the first draft.

## Permission matrix (granted explicitly, never by role; Super Admin has all)
| Capability | Permission |
|---|---|
| Submit, edit own pending/rejected, withdraw own, see own expenses | `submit_expenses` |
| See all expenses and the dashboard | `view_expenses` |
| Approve / reject; void an approved expense (never your own) | `approve_expenses` (also sees all) |
| Record / void payments | `pay_expenses` (also sees all) |
| Contribution and net operating profit on the Financial page | `view_reports` **and** (`view_expenses` or `approve_expenses`) **and** `view_commissions` |
"Finance Manager" = a Manager (existing role) with `approve_expenses` (and usually `view_expenses`, `pay_expenses`) granted in Users & Privileges. No new role, no enum change. Without the profit permissions the Financial page shows gross profit exactly as before and a note naming what is missing; it never shows a partial contribution/net figure.

## Approval workflow
submit -> **pending** -> approve -> **approved** -> payments -> derived paid status (unpaid / partial / paid).
Pending -> rejected (reason) -> submitter edits = **resubmitted** (pending again; the rejection stays in the history). Approved/pending/rejected -> **void** (reason). Statuses: pending, approved, rejected, void.

## Financial calculation methodology
All figures in cents; approved, non-void expenses only; payment status never changes profit (approval is the cost, payment is cash).
- **Gross profit = delivered revenue - COGS.** Unchanged: delivered balls x actual unit price; COGS = delivered balls x `order_items.historical_unit_cost` (the frozen cost). Computed by the existing `periodFigures()`; the profit chain does not recompute it (proved equal on real Staging data, check E25).
- **Contribution profit = gross profit - direct order expenses - direct expenses on cancelled orders - commissions.**
  - Direct order expenses: approved delivery/packaging/bags/special transport/other fulfilment linked to an order dated in the period (the order's sales date, like its revenue).
  - Cancelled orders: a direct expense on an order that was later cancelled earned no revenue. It is its **own line**, dated by its expense date, never dropped and never hidden inside another figure. (Under a product filter it cannot be assigned to a product and is left out, with a note.)
  - Commissions: from the commission records (`finance_commission_costs()`), **not** from manual expenses (no commission category exists, so they cannot be counted twice). Non-void, positive, earned; dated by `earned_at` (legacy percentage rows without it fall back to the order's delivery date, then its order date). Not-yet-earned rows are reported, not deducted. Commissions flagged for review are included and reported separately.
- **Net operating profit = contribution profit - operating expenses** (approved rent, salaries, utilities, internet, marketing, transport allowance, administration, other; by their own expense date).
- **COGS is never deducted twice:** there is no inventory-purchase / cost-of-goods category (a stock purchase reaches profit once, through COGS at delivery); the SQL checks assert no such category exists. A cash view will not reconcile to profit for the same reason: purchases are not recorded as expenses.
- **Overhead allocation (documented, dynamic, never stored):** the company's period operating expenses are allocated to a filtered selection, an order or a product by its share of the period's **delivered revenue** (largest-remainder rounding, so parts add up to the total exactly). Anything allocated is labelled "allocated". Direct expenses are exact per order; per product they are split by delivered revenue within the order. An order's commissions go to its products by delivered balls (per-ball kinds) or delivered revenue (bonus/legacy).
- **Cost withheld** (`can_view_cost`): every profit figure is null, never zero.
- **Period mixing, stated openly:** revenue and direct expenses follow the order's date, operating expenses their own date, commissions their earned date (as approved). Per-order rows use all earned commissions on the order, so the sum of order rows differs from the period figure by (cancelled-order line) + (commissions earned in the period on orders dated earlier).

## Receipt attachments: deferred (decision 6)
Not implemented. The requirement is a **private** Supabase Storage bucket (`expense-receipts`, never public), path `<expense id>/<random>-<name>`, storage policies that allow upload only by the submitter of a pending/rejected expense and read only by people who may see that expense (`view_expenses`/`approve_expenses`/`pay_expenses` or the submitter), short-lived signed URLs, a size/type limit, and negative tests (anon read, other-user read, upload after approval). Storage is not provisioned on EFZ-Staging (no buckets) and Production's setting is unknown; policies on `storage.objects` belong to `supabase_storage_admin`. It is a separate migration (34) with its own verification; `expenses.receipt_path` already exists (null) for it. Until then the form says to keep the receipt and quote its number in the notes.

## Backward compatibility
Additive only. Migration 33 changes no existing table, view, policy, grant or function; it inserts four rows into `permissions` (granted to nobody). Orders, payments, commissions, stock and customers were byte-identical (fingerprint) before and after applying 33 and after the end-to-end run. The Financial page output is unchanged for anyone without the new permissions, and for everyone until approved expenses exist. The public website and `/order` are not touched. Known interaction: an order that has an expense cannot be deleted (FK `on delete restrict`); cancelled orders with expenses stay as they are.

## Staging state (2026-11-10)
M33 applied; SQL checks 96/96 (always rolled back), end-to-end 33/33, unit 124/124 (11 new), `tsc` clean, lint 0 errors. The end-to-end run left three synthetic expenses `E2E33 ...` (all void) with their events and audit lines on Staging; expenses cannot be deleted by design. Staff permissions were restored exactly. No browser test was run.

## Production release (NOT done; needs the owner's separate approval)
1. Decide whether to ship receipts first or later (M34 is independent).
2. Fresh sealed Production backup (owner-run, as for M30-32); read-only preflight confirming `can_access_order`, `has_permission`, `current_profile_*`, `efz_today` and the `commissions` columns exist.
3. Apply `33_expense_management.sql` (single transaction; refuses if a base object is missing), then run the read-only post-checks (4 permissions, 13 categories, RLS on, no anon/client write access, 3 guard triggers).
4. Deploy the app (it degrades safely: before the migration the Financial page says expenses are not set up; Expenses shows the same sentence). Migration first.
5. Super Admin grants `submit_expenses` / `view_expenses` / `approve_expenses` / `pay_expenses` to the right people in Users & Privileges. Nobody has them by default.
Rollback: `33_expense_management_rollback.sql` (refuses once any expense exists; then roll back the app and fix forward), or promote the previous Vercel deployment (the old app ignores the new tables).
