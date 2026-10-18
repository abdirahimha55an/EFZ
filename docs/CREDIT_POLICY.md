# Customer credit policy v2: what the system does

Status: implemented in **migration 25 (a draft: applied to no database)**, on top of migrations 23 and 24 (applied to Staging). **Credit is OFF.** Switching it on needs your separate, explicit authorization after the review, the Staging verification and the decisions listed at the end.

Only a **Super Admin** can read or change the policy, authorize a customer, raise a limit, extend a due date, resolve a dispute, void a default or record a risk review (Hub > Customer Payments & Credit). Everything is enforced in the database; the Hub only shows buttons.

## The approved proposal (loaded with credit OFF)

| Setting | Value | Column |
|---|---|---|
| Credit policy enabled | **false** | `enabled` |
| Qualifying completed, paid orders | **3** (distinct orders) | `min_completed_purchases` |
| Purchase-history window | **90 days** | `purchase_window_days` |
| Approved-account age | **60 days** | `min_approved_days` |
| Minimum purchase value | **none** (see "existing configuration" below) | `min_total_value` |
| Initial credit limit | **$40** | `initial_credit_limit` |
| Repayment term | **30 calendar days** from the invoice date | `default_terms_days` |
| Company-wide outstanding credit cap | **25%** | `company_cap_percent` |
| Cap basis | average monthly sales over the previous **3 complete calendar months** | `cap_basis_months` |
| Automatic limit increases | **off, cannot be switched on** (check constraint) | `auto_limit_increase_enabled` |
| Late fees or interest | **off, cannot be switched on** (check constraint) | `late_fees_enabled` |
| Staff overrides of unmet requirements | **off** (a Super Admin may allow them; they never cover a default) | `allow_requirement_override` |

The migration loads these only into a policy row that is still completely empty and writes an audit line; a policy the owner already edited is never overwritten. Enabling credit additionally requires that every number above is set **and** that the company cap can be computed (below).

### Existing configuration, flagged for review
* **Minimum purchase value (`min_total_value`)**: it existed since migration 23 and is **empty on Staging**. It was **not** removed or replaced; it is preserved and enforced if set (`C8` tests it). Because you approved no value, it stays empty. **Decision for you:** keep it empty (the three paid orders are the only purchase requirement) or set a value.
* **Per-customer total-outstanding ceiling (`max_outstanding`)**, from migration 24: it also exists, is empty and is preserved (counts all of a customer's outstanding balances, not only credit invoices). **Decision for you:** leave empty (the $40 limit already caps credit) or set one.
* **"No unpaid balance on a delivered order"** (`require_no_unpaid_delivered`, on): kept; an unpaid delivered balance pauses credit until paid.
* **The overdue rule** is no longer a setting: a missed due date always revokes credit (see below). Migration 24 allowed switching it off; migration 25 refuses.

## Eligibility (all must hold; the server decides again when the order is accepted)
1. The app account is approved and has been approved for at least 60 days (counted on the Mogadishu calendar from the **first** approval).
2. At least 3 **distinct** qualifying orders in the preceding 90 days: **delivered, fully paid, regular** orders only (not cancelled, trial, undelivered, unpaid or part-paid; not orders whose online payment was reversed or is under review). Lines do not multiply an order. A credit order counts once it has been fully paid and delivered. The window is by order date, 90 days back inclusive.
3. The minimum purchase value, if EFZ sets one.
4. No overdue invoice, no unpaid delivered balance, no open dispute, no default that is not settled.
5. Available credit under both the customer's limit and the company-wide cap.
6. The policy is ON, the credit account is `approved` (not `suspended` or `revoked`).

Eligibility never grants credit: a Super Admin authorizes a limit for each customer.

## Limits and terms
* Available credit = the customer's limit minus their outstanding **credit** balance. The limit is the maximum they can owe at any time, **not** a per-order allowance.
* A new or renewed limit cannot exceed the **initial limit ($40)**. Lowering a limit is allowed. Raising one is a separate Super Admin action (`increase_customer_credit_limit`) with a reason (10+ characters), audited, never automatic, and refused for a customer who defaulted, who has a standing problem, or who does not currently meet the policy.
* The term is fixed by the policy (30 days); the app and the client can never choose it.
* Credit is reserved atomically: credit orders are decided one at a time under a company-wide lock and a per-customer lock. Repayments free credit only when staff record a verified payment in the existing payments table.

## Company-wide cap
`cap = 25% x (sum of orders.total of NON-CANCELLED orders by order date over the previous 3 complete calendar months) / 3`. This is EFZ's existing revenue definition: the same figure as the `daily_sales` and `financial_summary` views and the Sales analytics "booked revenue". (Booked sales include unpaid and undelivered orders; if you prefer delivered or collected revenue, that is a policy change.) The cap is compared with the total outstanding on **all** credit invoices of all customers. A new credit order is refused if it would take the company above the cap, and nothing is accepted at or above it. Customers are never shown the cap or any company figure.

**Insufficient history blocks activation.** The cap is "not computable" unless sales exist, EFZ's history reaches back to the start of the window, and the window holds revenue. In that case credit **cannot be enabled**, no credit order is accepted, and the Hub shows why and that an administrator must review it. No number is ever invented.

## Default: permanent, immediate, no grace
* An invoice not paid by its due date is a **default from the first overdue day** (due today is not yet overdue; there is **no grace period**). It is recorded the moment the customer, an admin or the daily run looks (and again before any credit order is accepted), so it never depends on a job or on the app being opened. An invoice paid **after** its due date is also recorded as a default.
* On default: the credit account becomes `revoked`, all new credit orders are refused (including a checkout in progress, because the check is made when the order is accepted), the customer gets an in-app notice and authorized staff are notified, the history and audit log record it, and the original invoice, due date, amount and payment history are preserved.
* **Paying does not restore credit.** Partial repayment changes nothing. Full repayment settles the debt (the default is marked settled with the time of the last payment) but the account stays revoked. "Debt settled" and "credit restored" are separate states, and the app says so.
* **Requalification starts from the settlement**, using the standard rules: 3 qualifying paid orders placed **after** the settlement (within 90 days), 60 days since the settlement with the account in good standing, no overdue debt or open dispute, then **a Super Admin approves credit again**. The renewed limit cannot exceed the initial limit ($40), whatever it was before. No override covers a default.
* The default record is permanent: it cannot be edited or deleted (database guard). It can only be **voided** through the dispute process below.
* **Account duplication:** credit state belongs to the customer record, not the device or the app install. A second customer record with the **same canonical phone number** inherits the default history. Existing safeguards remain: one app account per customer, and creating a customer whose phone already belongs to another needs explicit staff confirmation. No device tracking is used.

### Interpretation to confirm (the brief was ambiguous)
"Complete the full requalification process" is implemented as: purchases and account age are counted **from the last settlement**, not from the original approval. Otherwise a long-standing customer would requalify instantly. If you intended something different (for example counting only the 60-day age, or only the orders), tell me.

## Due-date extensions
`extend_credit_due_date`: Super Admin only, reason of 10+ characters, a later date, and only **before** the invoice is overdue and while it has no default. The **original due date is never changed**: the extension is a separate append-only record (previous date, new date, who, why, when) and an audit line. Customers see the issue date, the original due date and the extension. An extension cannot undo a default. Open decision: no maximum extension length is set.

## Disputes
A customer can report a problem with **their own** credit invoice (10+ characters; one unresolved report per invoice; 5 a day). It **restricts new credit** until reviewed. It does **not** pause the due date and does **not** remove a default. Staff investigate (assignee, private notes), then resolve as **rejected** or **billing error**; the customer gets the resolution text (never the staff notes). A default can be **voided** only after a dispute on that very invoice was resolved as a billing error: the default is kept, marked voided with who, why and which dispute. Voiding does not restore credit; a Super Admin must approve it again, and an invoice that is still unpaid and past due keeps restricting credit until staff correct it through the normal order tools or it is settled. **Design note:** disputed amounts are recorded for information, but the default timer always runs on the whole invoice; there is no partial "disputed balance" accounting, so a billing error must be corrected on the order itself.

## Reminders and escalation
| When | What |
|---|---|
| 7 days before the due date (or later, if the run was missed, while not yet due) | reminder to the customer |
| the due date | due-date reminder to the customer |
| first overdue day | credit revoked; notice to the customer and to authorized staff |
| 7 days overdue | overdue reminder to the customer; staff follow-up flagged |
| 30 days overdue | escalation to **Super Admins**; a documented credit-risk review is required (a Super Admin records it once) |

One delivery record per invoice, kind and audience (unique): repeated, parallel or restarted runs never duplicate a notice. A failed delivery is recorded (attempts, short error), shown in the Hub and retried by the next run, up to 5 attempts. The only delivery channel built is the **in-app notice** (customer app) and the staff notifications table; push or SMS are not built. **The daily run must be scheduled: see `docs/CREDIT_SCHEDULER.md`. Reminders are NOT operational until that is done and tested.**

## What the customer sees (Android app)
Whether credit is available (with the server's own reason), the limit, available credit and outstanding balance; each credit invoice with issue date, original and current due date, extension, payments and remaining balance; overdue status; for a defaulted customer: that credit is switched off, that paying settles the debt but does **not** restore credit, the requalification steps with their own progress, and that the renewed limit starts at the initial limit; notices; a "report a problem" form on each invoice. Ordinary upfront purchases keep working. Customers never receive costs, margins, profits, commissions, officers, suppliers or any company figure (regression tests in `supabase/checks/customer_data_exposure_checks.sql` and `__tests__/exposure.test.ts`).

## Differences between migration 24 and migration 25 (intentional)
| Topic | M24 | M25 |
|---|---|---|
| Overdue invoice | pauses credit; paying restores it | **default, permanent**; paying settles only; requalify and re-approve |
| Overdue rule | could be switched off | cannot |
| Enabling credit | one requirement + a term was enough | the whole policy must be set and the company cap computable |
| Term | any 1-365 days | fixed by the policy (30) |
| Limits | any figure up to 1,000,000 | new or renewed limit at most the initial limit ($40); raises only by the audited action |
| Override | allowed with a reason (unmet requirements only) | off by default; when allowed never covers a default |
| Purchases counted | all time | within the 90-day window (and after the last settlement) |
| Account age | from first approval | from first approval, restarted at a settlement |
| Company-wide cap | none | 25% of average monthly sales |
| Outstanding used for the limit | all outstanding balances | credit invoices (the optional ceiling still uses all balances) |
| Disputes, reminders, extensions, history | none | yes |

The M24 suite (`24_credit_policy_checks.sql`) still passes **62/62 on a migration-24 database (the live Staging level)**. On a migration-25 database 43 of its 62 checks fail **by design** (they specify the behaviours in the table above, e.g. "paying restores credit", "enable with only a day requirement"). Their still-valid cases (ceiling, overrides, standing, suspension, policy off) were ported into the M25 suite (sections J and K).

## Decisions and approvals still needed before credit can be activated
1. Confirm the requalification interpretation above.
2. Keep `min_total_value` and `max_outstanding` empty, or set values.
3. Accept "booked sales" as the revenue basis for the cap, or choose delivered or collected revenue.
4. Set a maximum extension length (or accept none).
5. Decide whether staff overrides will ever be allowed (the approved policy has none).
6. How disputes that need a billing correction, collections and any penalty are handled operationally (no fees or interest exist).
7. Approve migration 25 for Staging (new backup, apply and verify windows), schedule the daily run, then review the Staging verification.
8. **Separately authorize activation.** Until then credit stays OFF and no real customer is given credit.
