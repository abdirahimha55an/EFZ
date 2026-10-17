# Customer credit policy: every setting and what it does

Status: implemented in migrations 23 and 24 (24 is a **draft, not applied to Staging or Production**). **Credit is OFF and every threshold is empty.** EFZ has not chosen any value, and nothing in the code, the tests or the defaults is a recommended number. The values used in the test suites exist only inside rolled-back test transactions.

Only a **Super Admin** can read or change the policy, authorize a customer, or suspend credit (Hub > Customer Payments & Credit). Every change is written to the audit log with the old values and a reason of at least 5 characters.

## Two different ideas

* **Requirements** decide whether a customer *qualifies*. Staff may authorize credit for a customer who does not qualify, but only with a recorded **override reason** (10+ characters). The override is flagged on the account and in the audit line.
* **Account standing** decides whether credit is *safe right now*. It can never be overridden. It switches credit off automatically when the problem appears and back on when it is paid.

Qualifying never grants credit. A customer can buy on credit only when a Super Admin has authorized a **limit and repayment period** for them, the policy is ON, the account is approved (not suspended), and standing is clear.

## Settings

| Setting | Stored in | Default | Effect | Validation |
|---|---|---|---|---|
| Credit purchasing on | `credit_policy.enabled` | **off** | Master switch. Off stops every credit purchase, including for authorized and override accounts. | Cannot be turned on until a requirement and the default repayment period are set. |
| Completed purchases needed | `min_completed_purchases` | empty | Number of *completed purchases* required. A completed purchase is an order that is **delivered, fully paid, regular** (not trial, not cancelled, not zero value). Part-paid, undelivered and trial orders never count. | whole number, at least 1 |
| Completed purchase value needed ($) | `min_total_value` | empty | Total of those completed purchases required. Equal counts as met. | more than 0 |
| Days as an approved customer *(M24)* | `min_approved_days` | empty | Whole days since the customer's app account was **first** approved (Mogadishu calendar). A later re-approval does not restart the clock; registration date does not count. Equal counts as met. | whole number, at least 1 |
| Default repayment days | `default_terms_days` | empty | Required before credit can be enabled. The terms actually used on an order come from the customer's authorized account, never from the app. | 1 to 365 |
| No unpaid balance on a delivered order | `require_no_unpaid_delivered` | on | **Standing.** A delivered order with money still owed pauses credit until it is paid. | on/off |
| No credit invoice past its due date *(M24)* | `require_no_overdue` | **on** | **Standing.** A credit invoice that is past its due date with a balance pauses credit until it is paid or cancelled. Due **today** is not overdue; the day after is. Cancelled invoices never count. | on/off |
| Maximum total outstanding per customer ($) *(M24)* | `max_outstanding` | empty | **Standing and cap.** Counts **all** the customer's outstanding balances on non-cancelled orders (credit invoices *and* any unpaid staff or app order). Available credit is the smaller of the personal limit and this ceiling, minus what is owed. At or above the ceiling credit pauses. Lowering it pauses customers who already owe more; it never changes their existing orders. | more than 0 |

When several requirements are filled in, **all** must be met. The customer sees exactly the configured ones with their own progress, never a number that is not configured.

## Per customer (set by a Super Admin)

* **Credit limit** (0 to 1,000,000, whole cents) and **repayment period** (1 to 365 days) with a reason. The customer's available credit is limit minus the total outstanding, capped by the ceiling above.
* Each credit order records its own due date and the limit in force at that time.
* **Suspend** stops credit at once; re-authorizing starts it again.
* An authorized **override** customer can buy on credit (M24; in M23 an override account could never buy) but is still stopped by standing, the limit, the ceiling, a suspension and the master switch.

## What happens, step by step

1. The customer places a credit order. The server re-checks everything at that moment under a per-customer lock, so two simultaneous orders cannot both pass the limit check (tested with real parallel sessions).
2. The order is an ordinary EFZ order with payment terms "credit"; it appears in the customer's invoices and in the Hub order list with its due date. There is no separate ledger.
3. Staff record repayments with the existing payment function. Partial payments reduce the balance and the overdue amount; paid in full lifts the pause automatically.
4. Cancelling a credit order through the existing staff workflow releases its credit.

## What is deliberately not automatic or not modelled

* No late fees, interest or reminders are calculated.
* **Disputes are not modelled.** A disputed invoice is handled by staff (cancel or adjust through the existing order workflow).
* Pausing for overdue is automatic and reversible; it is not a recorded "suspension" in the audit log. Staff can still suspend an account explicitly.
* A provider reversal of an online payment is flagged for staff and never changes records by itself.

## Decisions EFZ must make before credit can be switched on in Staging, and later in Production

1. Which requirements to use, and their numbers: completed purchases, purchase value, days as an approved customer (any combination; leave the others empty).
2. The default repayment period.
3. Whether to keep the two standing rules on (they are on by default) and whether to set a **maximum total outstanding** for every customer.
4. The credit limit and period for each customer who will get credit.
5. Whether staff may use overrides at all, and who approves them (the system only requires a recorded reason).
6. How disputes, late fees and collections are handled by staff.

After the owner decides, the Staging steps are: apply Migration 24 (new backup + apply + verify windows), set the policy in the Hub, verify with a synthetic customer, and only then consider Production.
