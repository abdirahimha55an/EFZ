-- =============================================================================
-- OPTIONAL: schedule the daily credit run inside the database with pg_cron. NOT part of migration 25 and NOT run by anything. Read docs/CREDIT_SCHEDULER.md first.
--   * Needs the pg_cron extension (Supabase: Dashboard > Database > Extensions). If it is not available this script does nothing and says so.
--   * Idempotent: running it again replaces the one job named efz-credit-daily.
--   * 21:05 UTC = 00:05 in Mogadishu (UTC+3), just after the EFZ day changes, so "due today", "overdue" and the reminders follow the EFZ calendar.
--   * The job runs as the database owner, which is allowed to call credit_daily_run (it is owned by the owner and granted to service_role).
-- Run it only after migration 25 is applied and the owner has approved scheduling, on Staging first.
-- =============================================================================
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron is not enabled in this database: the daily credit run is NOT scheduled. Enable the extension, or use the credit-daily Edge Function with an external scheduler.';
    return;
  end if;
  if to_regprocedure('public.credit_daily_run()') is null then
    raise exception 'migration 25 is not applied: public.credit_daily_run() does not exist';
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'efz-credit-daily';
  perform cron.schedule('efz-credit-daily', '5 21 * * *', 'select public.credit_daily_run()');
  raise notice 'scheduled: efz-credit-daily at 21:05 UTC daily';
end
$$;
