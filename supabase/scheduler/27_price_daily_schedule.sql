-- =============================================================================
-- OPTIONAL: schedule the daily agreed-price expiry notices inside the database with pg_cron. NOT part of migration 27 and NOT run by anything. Read docs/CREDIT_SCHEDULER.md first.
--   * Needs the pg_cron extension. If it is not available this script does nothing and says so.
--   * Idempotent: running it again replaces the one job named efz-price-daily.
--   * 21:10 UTC = 00:10 in Mogadishu (UTC+3), just after the EFZ day changes. The notices are idempotent (one per agreement and stage), and customers are also told whenever they
--     open the catalogue, so a missed run delays nothing the customer would not see.
-- Run it only after migration 27 is applied and the owner has approved scheduling, on Staging first.
-- =============================================================================
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron is not enabled in this database: the daily price notices are NOT scheduled (customers are still told when they open the catalogue).';
    return;
  end if;
  if to_regprocedure('public.price_daily_run()') is null then
    raise exception 'migration 27 is not applied: public.price_daily_run() does not exist';
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'efz-price-daily';
  perform cron.schedule('efz-price-daily', '10 21 * * *', 'select public.price_daily_run()');
  raise notice 'scheduled: efz-price-daily at 21:10 UTC daily';
end
$$;
