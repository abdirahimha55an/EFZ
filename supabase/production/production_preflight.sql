-- ============================================================================
-- EFZ - PRODUCTION PREFLIGHT for 08_security_hardening.sql and
--       09_fix_run_diagnostics.sql            (READ-ONLY)
-- ----------------------------------------------------------------------------
-- ONE SELECT statement. It reads catalog metadata and counts; it writes,
-- creates, grants and changes nothing. It prints no emails, names, keys or
-- passwords - only counts, flags, object names and md5 fingerprints.
--
-- Every row carries a verdict:
--   EXPECTED        matches what 08/09 were built and tested against, or is a
--                   figure recorded for comparison after the apply
--   REVIEW REQUIRED differs from the tested state; decide before applying
--   BLOCKER         08 or 09 would fail, or must not be applied, until fixed
--
-- Pre-08 "expected" values come from the repository's 01-07 as applied and
-- verified in EFZ-Staging. Production row counts and money totals are never
-- assumed: they are recorded (EXPECTED) and only their internal consistency
-- is judged.
--
-- Run in the PRODUCTION SQL Editor as the default `postgres` role. Save the
-- whole output (Export -> CSV): the "record" rows are the baseline that the
-- post-apply checks are compared against.
-- ============================================================================

with
-- ---------------------------------------------------------------------------
-- Inventories of what 01-09 expect to find
-- ---------------------------------------------------------------------------
expected_tables(t) as (
  values ('profiles'), ('permissions'), ('user_permissions'), ('customers'), ('products'),
         ('stock_movements'), ('orders'), ('order_items'), ('payments'), ('order_requests'),
         ('commission_payouts'), ('commissions'), ('system_logs'), ('system_issues'),
         ('notifications'), ('settings'), ('backups'), ('testimonials')
),
expected_views(v) as (
  values ('public_products'), ('order_details'), ('inventory_status'), ('customer_financials'),
         ('officer_commission_summary'), ('financial_summary'), ('daily_sales'), ('product_sales')
),
-- Functions 08 and 09 depend on (created by 02, 05 and 07).
required_functions(sig) as (
  values ('public.current_profile_id()'), ('public.has_permission(text)'), ('public.is_super_admin()'),
         ('public.require_permission(text)'), ('public.set_user_permissions(text, text[])'),
         ('public.recalc_order_financials(text)'), ('public.refresh_profile_commission_totals(text)'),
         ('public.handle_new_auth_user()'), ('public.grant_role_preset(text, public.user_role)'),
         ('public.upsert_issue(text, integer, text, public.log_severity, text, text, text, text, text, boolean)'),
         ('public.run_diagnostics()'), ('public.repair_issue(text)'), ('public.operational_metrics()')
),
-- Functions that only exist once 08 has been applied.
functions_from_08(name) as (
  values ('is_client_request'), ('is_active_staff'), ('current_profile_name'), ('user_holds_permission'),
         ('reserved_permissions'), ('changed_columns'), ('guard_profiles_write'), ('guard_profiles_delete'),
         ('link_auth_user_to_profile'), ('handle_auth_user_confirmed'), ('guard_products_write'),
         ('guard_orders_write'), ('guard_system_logs_insert'), ('stamp_settings_actor'),
         ('stamp_backups_actor'), ('guard_notifications_update'), ('guard_order_requests_write')
),
-- RPCs that trust a null auth.uid(). anon must never be able to call them.
sensitive_rpcs(sig) as (
  values ('public.create_order(jsonb)'),
         ('public.record_payment(text, numeric, text, date, text, text)'),
         ('public.update_order_status(text, public.order_status, text)'),
         ('public.adjust_stock(text, integer, text, public.stock_movement_type)'),
         ('public.pay_commissions(text, uuid[], text, text, text)'),
         ('public.set_user_permissions(text, text[])'),
         ('public.convert_order_request(uuid, text)'),
         ('public.grant_role_preset(text, public.user_role)'),
         ('public.run_diagnostics()'), ('public.repair_issue(text)'), ('public.operational_metrics()')
),
baseline_ids(id) as (
  values ('EFZ-SKY-24'), ('EFZ-SKY-26'), ('EFZ-DHIMBIL-TRIAL'), ('EFZ-DHIMBIL-REG'),
         ('EFZ-GOOBE-ONE'), ('EFZ-HAYAAN-ONE'), ('EFZ-ABD-ONE')
),

-- ---------------------------------------------------------------------------
-- Gathered facts (every lookup is guarded so a missing object reports
-- instead of aborting the whole preflight)
-- ---------------------------------------------------------------------------
f as (
  select
    current_user                                                         as run_as,
    split_part(version(), ' ', 2)                                        as pg_version,
    (select count(*) from expected_tables where to_regclass('public.' || t) is not null) as tables_present,
    (select count(*) from expected_views  where to_regclass('public.' || v) is not null) as views_present,
    (select count(*) from required_functions where to_regprocedure(sig) is not null)     as required_fns_present,
    (select string_agg(sig, '; ') from required_functions where to_regprocedure(sig) is null) as required_fns_missing,
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname in (select name from functions_from_08))   as fns_from_08,
    (select count(*) from information_schema.columns
      where table_schema = 'auth' and table_name = 'users'
        and column_name in ('email_confirmed_at', 'invited_at', 'raw_user_meta_data'))    as auth_columns,
    case when to_regclass('auth.users') is null then null
         else has_table_privilege(current_user, 'auth.users', 'TRIGGER') end              as can_trigger_auth_users,
    (select pg_get_userbyid(relowner) from pg_class where oid = to_regclass('public.public_products')) as public_products_owner,
    (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind in ('r', 'v')
        and c.relname in (select t from expected_tables union all select v from expected_views)
        and pg_get_userbyid(c.relowner) <> current_user)                                  as objects_not_owned,
    (select count(*) from pg_policies where schemaname = 'public')                        as policies,
    (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid
       join pg_namespace n on n.oid = c.relnamespace
      where not t.tgisinternal and n.nspname = 'public')                                  as public_triggers,
    (select count(*) from pg_trigger where tgname = 'trg_on_auth_user_created')           as auth_trigger_created,
    (select count(*) from pg_trigger where tgname = 'trg_on_auth_user_confirmed')         as auth_trigger_confirmed,
    (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
        and c.relname in (select t from expected_tables))                                 as rls_enabled_tables,
    coalesce((select array_to_string(reloptions, ',') from pg_class
               where oid = to_regclass('public.public_products')), '')                    as public_products_options,
    case when to_regclass('public.products') is null then null
         else has_table_privilege('anon', 'public.products', 'select') end                as anon_reads_products,
    case when to_regclass('public.public_products') is null then null
         else has_table_privilege('anon', 'public.public_products', 'select') end         as anon_reads_catalogue,
    case when to_regclass('public.public_products') is null then null
         else has_table_privilege('anon', 'public.public_products', 'update') end         as anon_updates_catalogue,
    case when to_regclass('public.inventory_status') is null then null
         else has_table_privilege('anon', 'public.inventory_status', 'select') end        as anon_reads_inventory,
    (select count(*) from expected_tables
      where to_regclass('public.' || t) is not null
        and not has_table_privilege('authenticated', 'public.' || t, 'select'))           as staff_tables_without_select,
    (select string_agg(sig, '; ') from sensitive_rpcs
      where to_regprocedure(sig) is not null
        and has_function_privilege('anon', to_regprocedure(sig), 'execute'))              as anon_executable_rpcs,
    case when to_regprocedure('public.upsert_issue(text, integer, text, public.log_severity, text, text, text, text, text, boolean)') is null then null
         else has_function_privilege('authenticated',
           'public.upsert_issue(text, integer, text, public.log_severity, text, text, text, text, text, boolean)', 'execute') end
                                                                                          as staff_can_upsert_issue,
    case when to_regprocedure('public.recalc_order_financials(text)') is null then null
         else has_function_privilege('authenticated', 'public.recalc_order_financials(text)', 'execute') end
                                                                                          as staff_can_recalc,
    case when to_regprocedure('public.refresh_profile_commission_totals(text)') is null then null
         else has_function_privilege('authenticated', 'public.refresh_profile_commission_totals(text)', 'execute') end
                                                                                          as staff_can_refresh_totals,
    pg_get_functiondef(to_regprocedure('public.run_diagnostics()'))                       as run_diagnostics_def
),

-- Row counts and fingerprints, computed only for tables that exist.
tables_data as (
  select t,
         case when to_regclass('public.' || t) is null then null else
           (xpath('/row/c/text()', query_to_xml(
              format('select count(*) as c from public.%I', t), false, true, '')))[1]::text::bigint
         end as row_count,
         case when to_regclass('public.' || t) is null then null else
           (xpath('/row/h/text()', query_to_xml(
              format('select md5(coalesce(string_agg(x::text, %L order by x::text), %L)) as h from public.%I x',
                     '|', '', t), false, true, '')))[1]::text
         end as fingerprint
    from expected_tables
),

checks(sort, section, check_name, actual, expectation, verdict) as (
  -- ---- 1. identity ------------------------------------------------------------
  select 101, '1 identity', 'Running as', run_as, 'postgres',
         case when run_as = 'postgres' then 'EXPECTED' else 'BLOCKER' end from f
  union all
  select 102, '1 identity', 'PostgreSQL version', pg_version, 'record', 'EXPECTED' from f
  union all
  select 103, '1 identity', 'Synthetic staging rows (@example.com profiles, STG ids)',
         ((select count(*) from public.profiles where email like '%@example.com')
          + (select count(*) from public.orders where id like 'STG-%' or id like 'ORD-STG-%')
          + (select count(*) from public.customers where id like 'cust-stg-%'))::text,
         '0 - otherwise this is EFZ-Staging, not production',
         case when (select count(*) from public.profiles where email like '%@example.com')
                 + (select count(*) from public.orders where id like 'STG-%' or id like 'ORD-STG-%')
                 + (select count(*) from public.customers where id like 'cust-stg-%') = 0
              then 'EXPECTED' else 'BLOCKER' end
  union all
  select 104, '1 identity', 'Approved historical baseline orders present',
         (select count(*) from public.orders o join baseline_ids b on b.id = o.id)::text, '7',
         case when (select count(*) from public.orders o join baseline_ids b on b.id = o.id) = 7
              then 'EXPECTED' else 'REVIEW REQUIRED' end

  -- ---- 2. already applied? ----------------------------------------------------
  union all
  select 201, '2 not yet applied', 'Functions created by 08 already present', fns_from_08::text, '0',
         case when fns_from_08 = 0 then 'EXPECTED' else 'REVIEW REQUIRED' end from f
  union all
  select 202, '2 not yet applied', 'run_diagnostics() already fixed by 09',
         (run_diagnostics_def like '%array_append(v_seen%')::text, 'false',
         case when run_diagnostics_def is null then 'BLOCKER'
              when run_diagnostics_def like '%array_append(v_seen%' then 'REVIEW REQUIRED'
              else 'EXPECTED' end from f
  union all
  select 203, '2 not yet applied', 'Auth confirm-link trigger (created by 08)', auth_trigger_confirmed::text, '0',
         case when auth_trigger_confirmed = 0 then 'EXPECTED' else 'REVIEW REQUIRED' end from f

  -- ---- 3. prerequisites for 08 / 09 --------------------------------------------
  union all
  select 301, '3 prerequisites', 'Tables from 01 present', tables_present::text, '18',
         case when tables_present = 18 then 'EXPECTED' else 'BLOCKER' end from f
  union all
  select 302, '3 prerequisites', 'Views from 04 present', views_present::text, '8',
         case when views_present = 8 then 'EXPECTED' else 'BLOCKER' end from f
  union all
  select 303, '3 prerequisites', 'Functions 08/09 depend on (02, 05, 07)',
         required_fns_present::text || coalesce(' - missing: ' || required_fns_missing, ''), '13',
         case when required_fns_present = 13 then 'EXPECTED' else 'BLOCKER' end from f
  union all
  select 304, '3 prerequisites', 'run_diagnostics() still has the malformed-array bug',
         (run_diagnostics_def like '%v_seen := v_seen ||%')::text, 'true (09 fixes it)',
         case when run_diagnostics_def like '%v_seen := v_seen ||%' then 'EXPECTED' else 'REVIEW REQUIRED' end from f
  union all
  select 305, '3 prerequisites', 'auth.users columns 08 uses (email_confirmed_at, invited_at, raw_user_meta_data)',
         auth_columns::text, '3',
         case when auth_columns = 3 then 'EXPECTED' else 'BLOCKER' end from f
  union all
  select 306, '3 prerequisites', 'Current role may create triggers on auth.users',
         coalesce(can_trigger_auth_users::text, 'auth.users missing'), 'true',
         case when can_trigger_auth_users then 'EXPECTED' else 'BLOCKER' end from f
  union all
  select 307, '3 prerequisites', 'public_products owned by the current role (08 alters it)',
         coalesce(public_products_owner, 'missing'), 'postgres',
         case when public_products_owner = run_as then 'EXPECTED' else 'BLOCKER' end from f
  union all
  select 308, '3 prerequisites', 'EFZ tables/views NOT owned by the current role', objects_not_owned::text, '0',
         case when objects_not_owned = 0 then 'EXPECTED' else 'BLOCKER' end from f

  -- ---- 4. current security state (pre-08 values from 01-07) ---------------------
  union all
  select 401, '4 security state', 'RLS policies in public', policies::text, '51',
         case when policies = 51 then 'EXPECTED' else 'REVIEW REQUIRED' end from f
  union all
  select 402, '4 security state', 'Non-internal triggers in public', public_triggers::text, '11',
         case when public_triggers = 11 then 'EXPECTED' else 'REVIEW REQUIRED' end from f
  union all
  select 403, '4 security state', 'Sign-up link trigger on auth.users (from 02)', auth_trigger_created::text, '1',
         case when auth_trigger_created = 1 then 'EXPECTED' else 'REVIEW REQUIRED' end from f
  union all
  select 404, '4 security state', 'EFZ tables with RLS enabled', rls_enabled_tables::text, '18',
         case when rls_enabled_tables = 18 then 'EXPECTED' else 'REVIEW REQUIRED' end from f
  union all
  select 405, '4 security state', 'public_products options', public_products_options, 'security_invoker=true',
         case when public_products_options = 'security_invoker=true' then 'EXPECTED' else 'REVIEW REQUIRED' end from f
  union all
  select 406, '4 security state', 'anon can SELECT products (cost_price leak 08 closes)',
         coalesce(anon_reads_products::text, 'missing'), 'true before 08',
         case when anon_reads_products then 'EXPECTED' else 'REVIEW REQUIRED' end from f
  union all
  select 407, '4 security state', 'anon can SELECT public_products (public catalogue)',
         coalesce(anon_reads_catalogue::text, 'missing'), 'true',
         case when anon_reads_catalogue then 'EXPECTED' else 'REVIEW REQUIRED' end from f
  union all
  select 408, '4 security state', 'anon can UPDATE public_products (08 revokes)',
         coalesce(anon_updates_catalogue::text, 'missing'), 'record', 'EXPECTED' from f
  union all
  select 409, '4 security state', 'anon can SELECT inventory_status (leak 08 closes)',
         coalesce(anon_reads_inventory::text, 'missing'), 'true before 08',
         case when anon_reads_inventory then 'EXPECTED' else 'REVIEW REQUIRED' end from f
  union all
  select 410, '4 security state', 'EFZ tables the signed-in role cannot SELECT (app needs 0)',
         staff_tables_without_select::text, '0',
         case when staff_tables_without_select = 0 then 'EXPECTED' else 'REVIEW REQUIRED' end from f
  union all
  select 411, '4 security state', 'Sensitive RPCs anon can execute (they trust a null auth.uid())',
         coalesce(anon_executable_rpcs, 'none'), 'none',
         case when anon_executable_rpcs is null then 'EXPECTED' else 'BLOCKER' end from f
  union all
  select 412, '4 security state', 'Signed-in role can execute upsert_issue() (forgery hole 08 closes)',
         coalesce(staff_can_upsert_issue::text, 'missing'), 'record', 'EXPECTED' from f
  union all
  select 413, '4 security state', 'Signed-in role can execute recalc_order_financials() (08 revokes)',
         coalesce(staff_can_recalc::text, 'missing'), 'record', 'EXPECTED' from f
  union all
  select 414, '4 security state', 'Signed-in role can execute refresh_profile_commission_totals() (08 revokes)',
         coalesce(staff_can_refresh_totals::text, 'missing'), 'record', 'EXPECTED' from f

  -- ---- 5. profiles and Auth linkage ---------------------------------------------
  union all
  select 501, '5 profiles/auth', 'Profiles', (select count(*) from public.profiles)::text, 'record', 'EXPECTED'
  union all
  select 502, '5 profiles/auth', 'Active profiles',
         (select count(*) from public.profiles where status = 'active')::text, 'record', 'EXPECTED'
  union all
  select 503, '5 profiles/auth', 'Active Super Admins linked to an Auth user',
         (select count(*) from public.profiles
           where role = 'Super Admin' and status = 'active' and auth_user_id is not null)::text,
         '>= 1 (after 08 only a Super Admin can manage user managers and reserved permissions)',
         case when (select count(*) from public.profiles
                     where role = 'Super Admin' and status = 'active' and auth_user_id is not null) >= 1
              then 'EXPECTED' else 'BLOCKER' end
  union all
  select 504, '5 profiles/auth', 'Active profiles with no Auth user (cannot sign in)',
         (select count(*) from public.profiles where status = 'active' and auth_user_id is null)::text, '0',
         case when (select count(*) from public.profiles where status = 'active' and auth_user_id is null) = 0
              then 'EXPECTED' else 'REVIEW REQUIRED' end
  union all
  select 505, '5 profiles/auth', 'Auth users',
         (select count(*) from auth.users)::text, 'record', 'EXPECTED'
  union all
  select 506, '5 profiles/auth', 'Auth users not linked to any profile (possible self-signups)',
         (select count(*) from auth.users u
           where not exists (select 1 from public.profiles p where p.auth_user_id = u.id))::text, '0',
         case when (select count(*) from auth.users u
                     where not exists (select 1 from public.profiles p where p.auth_user_id = u.id)) = 0
              then 'EXPECTED' else 'REVIEW REQUIRED' end
  union all
  select 507, '5 profiles/auth', 'Profiles linked to an UNCONFIRMED Auth user (possible squatting)',
         (select count(*) from public.profiles p join auth.users u on u.id = p.auth_user_id
           where u.email_confirmed_at is null)::text, '0',
         case when (select count(*) from public.profiles p join auth.users u on u.id = p.auth_user_id
                     where u.email_confirmed_at is null) = 0
              then 'EXPECTED' else 'REVIEW REQUIRED' end
  union all
  select 508, '5 profiles/auth', 'Inactive profiles created by self-signup (not provisioned by an admin)',
         (select count(*) from public.profiles
           where status = 'inactive' and id = 'u-' || replace(auth_user_id::text, '-', ''))::text, '0',
         case when (select count(*) from public.profiles
                     where status = 'inactive' and id = 'u-' || replace(auth_user_id::text, '-', '')) = 0
              then 'EXPECTED' else 'REVIEW REQUIRED' end
  union all
  select 509, '5 profiles/auth', 'Non-Super-Admin profiles holding manage_users (restricted by 08)',
         (select count(distinct p.id) from public.profiles p
            join public.user_permissions up on up.user_id = p.id
           where up.permission_code = 'manage_users' and p.role <> 'Super Admin')::text, '0',
         case when (select count(distinct p.id) from public.profiles p
                      join public.user_permissions up on up.user_id = p.id
                     where up.permission_code = 'manage_users' and p.role <> 'Super Admin') = 0
              then 'EXPECTED' else 'REVIEW REQUIRED' end
  union all
  select 510, '5 profiles/auth', 'Profiles sharing an email (case-insensitive)',
         (select count(*) from (select lower(email) from public.profiles group by 1 having count(*) > 1) d)::text, '0',
         case when (select count(*) from (select lower(email) from public.profiles group by 1 having count(*) > 1) d) = 0
              then 'EXPECTED' else 'REVIEW REQUIRED' end

  -- ---- 6. financial / data integrity (full report: checks/validate_financials.sql)
  union all
  select 601, '6 integrity', 'Orders whose total differs from their line items',
         (select count(*) from public.orders o
           where abs(o.total - coalesce((select sum(line_revenue) from public.order_items i
                                          where i.order_id = o.id), 0)) > 0.005)::text, '0',
         case when (select count(*) from public.orders o
                     where abs(o.total - coalesce((select sum(line_revenue) from public.order_items i
                                                    where i.order_id = o.id), 0)) > 0.005) = 0
              then 'EXPECTED' else 'REVIEW REQUIRED' end
  union all
  select 602, '6 integrity', 'Orders whose amount paid differs from their payments',
         (select count(*) from public.orders o
           where abs(o.amount_paid - least(coalesce((select sum(amount) from public.payments p
                                                      where p.order_id = o.id), 0), o.total)) > 0.005)::text, '0',
         case when (select count(*) from public.orders o
                     where abs(o.amount_paid - least(coalesce((select sum(amount) from public.payments p
                                                                where p.order_id = o.id), 0), o.total)) > 0.005) = 0
              then 'EXPECTED' else 'REVIEW REQUIRED' end
  union all
  select 603, '6 integrity', 'Profiles whose commission totals differ from the ledger',
         (select count(*) from public.profiles p
           where abs(p.earned_commission_total - coalesce((select sum(c.amount) from public.commissions c
                    where c.user_id = p.id and c.status in ('pending', 'approved', 'paid')), 0)) > 0.005)::text, '0',
         case when (select count(*) from public.profiles p
                     where abs(p.earned_commission_total - coalesce((select sum(c.amount) from public.commissions c
                              where c.user_id = p.id and c.status in ('pending', 'approved', 'paid')), 0)) > 0.005) = 0
              then 'EXPECTED' else 'REVIEW REQUIRED' end
  union all
  select 604, '6 integrity', 'Approved baseline revenue (7 historical orders)',
         (select coalesce(sum(o.total), 0)::numeric(14,2) from public.orders o
            join baseline_ids b on b.id = o.id)::text, '119.00',
         case when (select coalesce(sum(o.total), 0) from public.orders o join baseline_ids b on b.id = o.id) = 119
              then 'EXPECTED' else 'REVIEW REQUIRED' end
  union all
  select 605, '6 integrity', 'Total stock on hand', (select coalesce(sum(stock), 0) from public.products)::text,
         'record', 'EXPECTED'
  union all
  select 606, '6 integrity', 'Total amount paid across orders',
         (select coalesce(sum(amount_paid), 0)::numeric(14,2) from public.orders)::text, 'record', 'EXPECTED'
  union all
  select 607, '6 integrity', 'Revenue excluding cancelled orders',
         (select coalesce(sum(total), 0)::numeric(14,2) from public.orders where status <> 'cancelled')::text,
         'record', 'EXPECTED'

  -- ---- 7. row counts and fingerprints (record; compare after the apply) -----------
  union all
  select 700 + row_number() over (order by t)::int, '7 data record', 'Rows: ' || t,
         coalesce(row_count::text, 'table missing'), 'record',
         case when row_count is null then 'BLOCKER' else 'EXPECTED' end
    from tables_data
  union all
  select 750 + row_number() over (order by t)::int, '7 data record', 'Fingerprint: ' || t,
         coalesce(fingerprint, 'table missing'), 'record (must be identical after 08/09)',
         case when fingerprint is null then 'BLOCKER' else 'EXPECTED' end
    from tables_data
)
select section, check_name, actual, expectation, verdict
  from checks
 order by sort;
