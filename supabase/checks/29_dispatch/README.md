# Migration 29: Dispatched status and live order updates

Files, in order: `29a_dispatch_enum.sql` (enum label + two columns), `29b_dispatch_and_live_orders.sql` (status logic, my_orders, Realtime trigger and policy),
`29c_order_details_dispatched.sql` (the Hub view gets `dispatched_at`), `29d_live_orders_topic_by_user.sql` (topic addressed by the customer's sign-in id).
Rollback: `../../rollback/29_dispatch_rollback.sql`.

## Status rules (update_order_status)
pending -> confirmed -> processing -> **dispatched** -> delivered; processing -> delivered stays valid; partially_delivered follows recorded deliveries and can only go to delivered;
cancelled is allowed before delivery (dispatched included). Anything else is a Super Admin override with a written reason. Entering `dispatched` stamps `dispatched_at` /
`dispatched_by` and the normal audit line (system_logs, category ORDER) records who, from -> to and the optional dispatch details. An override back to pending/confirmed/processing clears
`dispatched_at` (the audit log keeps the history). Existing orders keep `dispatched_at = null`: history is never invented.

## Running the tests (STAGING ONLY, nothing is committed: the batch ends by raising T28RESULT)
- `./run.sh` : database already has 29a..29c, applies 29d inside the test transaction and runs `body.sql` (29 checks: transitions, timestamps, audit, partial delivery, cancellation,
  overrides, my_orders ownership, Realtime messages and who can receive them).
- `./run.sh --full` : database has only 29a: applies 29b, 29c and 29d inside the test transaction first.
- `./rollback_test.sh` : applies the rollback inside a transaction that is aborted and prints the restored function checksums, view checksum and ACL.

## Notes
- The 29b/29c preflight compares the CURRENT function/view definitions with the exact definitions it was written against (md5). On a database where they differ it refuses to run.
- Function bodies authored on Windows carry CR characters; the Management API strips them, so a rollback restores the text equal to the original after CR removal (whitespace only).
- A new enum label cannot be used in the transaction that adds it, which is why 29a is a separate, committed step.
