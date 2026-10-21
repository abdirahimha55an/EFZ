-- ============================================================================
-- EFZ - BACKUP BASELINE (READ-ONLY)  - run with psql, identically against
--   (A) Production, immediately BEFORE and AFTER the backup dump, and
--   (C) the disposable restore target after the restore.
-- ----------------------------------------------------------------------------
-- Writes nothing: everything runs inside BEGIN READ ONLY ... ROLLBACK, so any
-- write would be refused by PostgreSQL. Prints counts, totals and md5
-- fingerprints only - no emails, names, phone numbers, keys or passwords.
--
-- Deterministic across servers: timestamps are rendered in UTC and rows are
-- ordered with COLLATE "C", so the same data gives the same fingerprint on
-- Supabase and on a local PostgreSQL 17.
--
-- Column "compare":
--   MATCH  must be identical between the Production run and the restored copy
--   INFO   recorded for the report; expected to differ (server, time, auth churn)
-- ============================================================================
\set ON_ERROR_STOP on
\pset pager off
\pset footer off

begin read only;
set local timezone to 'UTC';
set local statement_timeout to '300s';

with
fp(schema_name, table_name, n, h) as (
  -- every base table in public, and the two Auth tables that hold accounts
  select c.schema_name, c.table_name,
         (xpath('/row/n/text()', x))[1]::text,
         (xpath('/row/h/text()', x))[1]::text
  from (
    select n.nspname as schema_name, cl.relname as table_name
      from pg_class cl join pg_namespace n on n.oid = cl.relnamespace
     where cl.relkind in ('r', 'p')
       and (n.nspname = 'public' or (n.nspname = 'auth' and cl.relname in ('users', 'identities')))
  ) c
  cross join lateral query_to_xml(format(
    'select count(*) as n, md5(coalesce(string_agg(to_jsonb(t)::text, %L order by to_jsonb(t)::text collate "C"), %L)) as h from %I.%I t',
    '|', '', c.schema_name, c.table_name), false, true, '') as x
),
auth_other(table_name, n) as (
  -- other Auth tables churn with every sign-in / token refresh: counts for the record only
  select cl.relname, (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from auth.%I', cl.relname), false, true, '')))[1]::text
    from pg_class cl join pg_namespace n on n.oid = cl.relnamespace
   where n.nspname = 'auth' and cl.relkind = 'r' and cl.relname not in ('users', 'identities')
)
select section, item, compare, value
from (
  -- 0. identity -------------------------------------------------------------
  select '0 identity' as section, 'server version' as item, 'INFO' as compare, current_setting('server_version') as value
  union all select '0 identity', 'captured at (UTC)', 'INFO', to_char(clock_timestamp() at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS')
  union all select '0 identity', 'database', 'INFO', current_database()

  -- 1. migration state --------------------------------------------------------
  union all select '1 migrations', '08 security hardening (is_client_request)', 'MATCH',
         (to_regprocedure('public.is_client_request()') is not null)::text
  union all select '1 migrations', '10 RPC hardening (below_cost_overrides)', 'MATCH',
         (to_regclass('public.below_cost_overrides') is not null)::text
  union all select '1 migrations', '11 order scope (system_logs.origin)', 'MATCH',
         exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'system_logs' and column_name = 'origin')::text
  union all select '1 migrations', '12 commission model (commission_policy)', 'MATCH',
         (to_regclass('public.commission_policy') is not null)::text

  -- 2. database objects -------------------------------------------------------
  union all select '2 objects', 'public base tables', 'MATCH',
         (select count(*)::text from pg_class cl join pg_namespace n on n.oid = cl.relnamespace where n.nspname = 'public' and cl.relkind in ('r', 'p'))
  union all select '2 objects', 'public views', 'MATCH',
         (select count(*)::text from pg_class cl join pg_namespace n on n.oid = cl.relnamespace where n.nspname = 'public' and cl.relkind in ('v', 'm'))
  union all select '2 objects', 'public functions (count / definitions md5)', 'MATCH',
         (select count(*) || ' / ' || md5(coalesce(string_agg(pg_get_functiondef(p.oid), '|' order by p.oid::regprocedure::text collate "C"), ''))
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind in ('f', 'p'))
  union all select '2 objects', 'triggers on public + auth.users (count / md5)', 'MATCH',
         (select count(*) || ' / ' || md5(coalesce(string_agg(pg_get_triggerdef(t.oid), '|' order by pg_get_triggerdef(t.oid) collate "C"), ''))
            from pg_trigger t join pg_class cl on cl.oid = t.tgrelid join pg_namespace n on n.oid = cl.relnamespace
           where not t.tgisinternal and (n.nspname = 'public' or (n.nspname = 'auth' and cl.relname = 'users')))
  union all select '2 objects', 'RLS policies on public (count / md5)', 'MATCH',
         (select count(*) || ' / ' || md5(coalesce(string_agg(tablename || ':' || policyname || ':' || cmd || ':' || coalesce(qual, '') || ':' || coalesce(with_check, ''),
                                                    '|' order by tablename || policyname collate "C"), ''))
            from pg_policies where schemaname = 'public')
  union all select '2 objects', 'public tables with RLS enabled', 'MATCH',
         (select count(*)::text from pg_class cl join pg_namespace n on n.oid = cl.relnamespace
           where n.nspname = 'public' and cl.relkind = 'r' and cl.relrowsecurity)
  union all select '2 objects', 'public enum types (count / labels md5)', 'MATCH',
         (select count(distinct t.oid) || ' / ' || md5(coalesce(string_agg(t.typname || '.' || e.enumlabel, '|' order by t.typname || '.' || lpad(e.enumsortorder::text, 6, '0') collate "C"), ''))
            from pg_type t join pg_namespace n on n.oid = t.typnamespace join pg_enum e on e.enumtypid = t.oid where n.nspname = 'public')

  -- 3. every table: rows and full-content fingerprint ---------------------------
  union all select '3 tables', schema_name || '.' || table_name, 'MATCH', 'rows=' || n || ' md5=' || h from fp
  union all select '3 tables', 'auth.' || table_name || ' (churns with sign-ins)', 'INFO', 'rows=' || n from auth_other

  -- 4. money and stock, human-readable --------------------------------------------
  union all select '4 totals', 'orders by status: count / total / paid / outstanding', 'MATCH',
         (select string_agg(s, ' | ' order by s collate "C") from (
            select status::text || ': ' || count(*) || ' / ' || sum(total) || ' / ' || sum(amount_paid) || ' / ' || sum(outstanding_balance) as s
              from public.orders group by status) x)
  union all select '4 totals', 'payments: count / sum', 'MATCH',
         (select count(*) || ' / ' || coalesce(sum(amount), 0) from public.payments)
  union all select '4 totals', 'commissions by status: count / sum', 'MATCH',
         (select coalesce(string_agg(s, ' | ' order by s collate "C"), 'none') from (
            select status::text || ': ' || count(*) || ' / ' || sum(amount) as s from public.commissions group by status) x)
  union all select '4 totals', 'stock per product', 'MATCH',
         (select string_agg(id || '=' || stock, ' | ' order by id collate "C") from public.products)
  union all select '4 totals', 'audit lines', 'MATCH',
         (select count(*)::text from public.system_logs)

  -- 5. outside the dump ------------------------------------------------------------
  union all select '5 not in dump', 'storage.objects (Supabase Storage files)', 'INFO',
         coalesce((select (xpath('/row/n/text()', query_to_xml('select count(*) as n from storage.objects', false, true, '')))[1]::text
                    where to_regclass('storage.objects') is not null), 'schema absent')
) r
order by section collate "C", item collate "C";

rollback;
