# Daily credit run: scheduling status and setup

**Status: NOT OPERATIONAL.** The code is written and tested; nothing is scheduled anywhere, and no scheduler has been verified against Staging or Production. Reminders and escalations must be treated as **not working** until the steps below are done and tested.

## What exists
* `public.credit_daily_run()` (migration 25, service_role only) and `public.run_credit_checks()` (Super Admin, "Run the daily checks now" in the Hub): record defaults, send the 7-day / due-date / overdue / 7-day-overdue / 30-day-overdue notices, mark the 30-day risk review, retry failed deliveries. **Idempotent**: one delivery record per invoice, kind and audience, so retries, parallel runs and restarts never duplicate a notice (proved by the SQL suite and by the parallel-session test, 5 simultaneous runs).
* The customer-side decision does **not** depend on the run: a missed due date is recorded and acted on whenever the customer, the Hub or the order path looks, so credit is revoked on the first overdue day even if no job ran. The run only adds the notices, escalations and the 30-day review.
* The only delivery channel is **in-app** (customer notices table, staff notifications). There is no push, SMS or email channel; a delivery failure can only be simulated in tests.

## Two ways to schedule it (choose one; both need your approval)
**A. pg_cron inside the database (simplest).** Enable the `pg_cron` extension (Supabase Dashboard > Database > Extensions), then run `supabase/scheduler/25_credit_daily_schedule.sql`. It schedules `select public.credit_daily_run()` at **21:05 UTC (00:05 in Mogadishu)** daily, and does nothing (with a notice) if pg_cron is absent.
**B. An HTTPS trigger.** Deploy `supabase/functions/credit-daily` with `--no-verify-jwt`, set a secret of at least 24 random characters with `supabase secrets set CREDIT_CRON_SECRET=...` (never in the repository or in chat), and have any scheduler (Supabase Cron with pg_net, GitHub Actions, an external cron) send `POST` with header `x-cron-secret`. It refuses to run without the secret (501), with a wrong one (401), and returns only counts. Its tests are in `npm run test:payments`.

## What is missing (exact dependencies)
1. **pg_cron (or another scheduler) enabled and a job created** on Staging, then on Production. Whether pg_cron is available on the EFZ projects was **not verified** (it needs a database connection; no Staging window was opened).
2. For option B: the Edge Function deployed and `CREDIT_CRON_SECRET` set, and a caller configured.
3. A **supervised Staging test after migration 25 is applied**: schedule it, wait for a run, and check `credit_reminders` for exactly one `sent` row per kind; stop one delivery on purpose and confirm `failed` then `sent` on the next run; confirm the job's own history (`cron.job_run_details`) shows success.
4. Decide on additional channels (push, SMS, email) if in-app notices are not enough; none is built.

## Failure behaviour to know
A failed delivery stays `failed` with its attempt count and a short error, appears in the Hub ("Reminders that failed to deliver") and is retried at the start of the next run, up to 5 attempts. A run that cannot start (scheduler down) delays notices but never delays a default or a refusal.
