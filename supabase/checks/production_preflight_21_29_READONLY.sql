-- =============================================================================
-- EFZ PRODUCTION - preflight for migrations 21-29e. READ-ONLY: runs inside BEGIN READ ONLY ... ROLLBACK.
-- It contains only SELECT statements over the system catalogs plus row COUNTS of a few business tables (no customer data, no amounts, no names).
-- It creates, replaces, grants and writes NOTHING. PostgreSQL itself refuses any write in a READ ONLY transaction.
-- It does not run any migration, does not impersonate a role (no set_config / SET ROLE) and does not call any application function.
--
-- Output: one line per fact, '|' separated, first field = section tag. Return the output as-is (it holds no secrets).
-- Expected values are copied from the guards in 27/28/29b/29c/29e. They describe STAGING at the time each migration was written;
-- nothing here assumes Production matches. Every comparison prints the ACTUAL md5 next to the expected one.
-- Flavours (the migrations use different ones, so all are printed):
--   raw   = md5(prosrc)                      (what 29b and 29e compare)
--   crs   = md5(prosrc with CR removed)
--   deff  = md5(pg_get_functiondef with CR removed)   (what 27 and 28 compare)
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off
\pset footer off
\pset tuples_only on
\pset format unaligned
begin read only;

-- 1. identity: proves what we are connected to, that the transaction is read only and that TLS is in use
select 'identity|db=' || current_database() || '|user=' || current_user || '|read_only=' || current_setting('transaction_read_only')
    || '|server=' || current_setting('server_version') || '|ssl=' || coalesce((select ssl::text from pg_stat_ssl where pid = pg_backend_pid()), 'unknown')
    || '|test_marker_products=' || (select count(*) from public.products where id like 'prod-stg-%');

-- 2. migration history tables (Staging had none; migrations were applied through the SQL editor)
select 'history|supabase_migrations_schema_exists=' || exists(select 1 from pg_namespace where nspname = 'supabase_migrations')
    || '|schema_migrations_table=' || (to_regclass('supabase_migrations.schema_migrations') is not null);

-- 3. which migrations look applied (object markers only; a missing marker means "not applied", an extra one means "already applied")
select 'marker|' || m.mig || '|' || m.what || '|' || m.present
from (values
  ('20', 'orders.payment_terms column',          exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'orders' and column_name = 'payment_terms')),
  ('21', 'table customer_accounts',              to_regclass('public.customer_accounts') is not null),
  ('21', 'column customer_accounts.deletion_requested_at', exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customer_accounts' and column_name = 'deletion_requested_at')),
  ('21', 'function my_customer_account',         exists(select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'my_customer_account')),
  ('21', 'function my_orders',                   exists(select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'my_orders')),
  ('22', 'table customer_order_requests',        to_regclass('public.customer_order_requests') is not null),
  ('23', 'table customer_checkouts',             to_regclass('public.customer_checkouts') is not null),
  ('23', 'table payment_methods',                to_regclass('public.payment_methods') is not null),
  ('23', 'table credit_policy',                  to_regclass('public.credit_policy') is not null),
  ('24', 'column credit_policy.min_approved_days', exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'credit_policy' and column_name = 'min_approved_days')),
  ('24', 'function credit_history',              exists(select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'credit_history')),
  ('25', 'column credit_policy.company_cap_percent', exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'credit_policy' and column_name = 'company_cap_percent')),
  ('25', 'function _credit_company_cap',         exists(select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = '_credit_company_cap')),
  ('26', 'table customer_price_agreements',      to_regclass('public.customer_price_agreements') is not null),
  ('26', 'table order_price_resolutions',        to_regclass('public.order_price_resolutions') is not null),
  ('26', 'table product_designs',                to_regclass('public.product_designs') is not null),
  ('27', 'function _price_resolve',              exists(select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = '_price_resolve')),
  ('28', 'convert_website_request carries "migration 28 marker"', coalesce((select bool_or(position('migration 28 marker' in pg_get_functiondef(p.oid)) > 0) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'convert_website_request'), false)),
  ('29a', 'enum order_status has label dispatched', exists(select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'order_status' and e.enumlabel = 'dispatched')),
  ('29a', 'column orders.dispatched_at',         exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'orders' and column_name = 'dispatched_at')),
  ('29a', 'column orders.dispatched_by',         exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'orders' and column_name = 'dispatched_by')),
  ('29b', 'function notify_customer_order_change', exists(select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'notify_customer_order_change')),
  ('29b', 'trigger trg_orders_notify_customer_ins', exists(select 1 from pg_trigger t where t.tgname = 'trg_orders_notify_customer_ins' and not t.tgisinternal)),
  ('29b', 'trigger trg_orders_notify_customer_upd', exists(select 1 from pg_trigger t where t.tgname = 'trg_orders_notify_customer_upd' and not t.tgisinternal)),
  ('29b', 'policy customer_orders_receive on realtime.messages', exists(select 1 from pg_policies where schemaname = 'realtime' and tablename = 'messages' and policyname = 'customer_orders_receive')),
  ('29c', 'order_details exposes dispatched_at', exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'order_details' and column_name = 'dispatched_at'))
) as m(mig, what, present)
order by 1;

-- 4. dependency guards: ACTUAL vs EXPECTED, taken from the migration files. RESULT is MATCH, MATCH_AFTER_CR_STRIP (differs only by CR characters), DIFF or ABSENT.
with exp(mig, fn, flavour, expected, label) as (values
  ('29b', 'update_order_status',        'raw',  '5a43e0acdf3b9a9ea7668334d753bc29', 'pre-29b baseline'),
  ('29b', 'guard_orders_write',         'raw',  'ff206ab922a3781a1f2516c4236ce16c', 'pre-29b baseline'),
  ('29b', 'deliver_order_internal',     'raw',  '73ad332fd466b672d28fc40d070733ec', 'pre-29b baseline'),
  ('29b', 'sync_order_commission',      'raw',  'b60b769d150eb6acfcfa206148ba7720', 'pre-29b baseline'),
  ('29b', 'transfer_customer_owner',    'raw',  'aadc6d69293d767ec2282eedb8dfddd3', 'pre-29b baseline'),
  ('29b', 'correct_delivered_quantity', 'raw',  'b8b58f459c5a71497f1a3fc091a9bbb6', 'pre-29b baseline'),
  ('29b', 'my_orders',                  'raw',  '4dc43b4c60fbcd2cb2b4581f9f051ef9', 'pre-29b baseline (exists only after 21)'),
  ('29e', 'update_order_status',        'raw',  'cb9a5600965a3f0a89c2bf7aff3e708a', 'post-29b state'),
  ('29e', 'deliver_order_internal',     'raw',  'aaccef881132fa34a8e1102528432316', 'post-29b state'),
  ('27',  'create_order',               'deff', 'bad8d28eac60a8243e6bba614f6191a1', 'pre-27 baseline'),
  ('27',  'create_order',               'deff', '265e9745acb9418787e6d8cebfb450af', 'post-27 state (also 28 expects this)'),
  ('27',  'convert_website_request',    'deff', 'bc32b50df6f50e37e6759086a1f6dd1c', 'pre-27 baseline'),
  ('28',  'convert_website_request',    'deff', 'fe992c8ab3edc37522d08e3e6eb41c9c', 'post-27 state (28 expects this)'),
  ('27',  'convert_order_request',      'deff', 'fc18ea5ee175c1448b399754c3baf6ef', 'must stay unchanged by 27')
), act as (
  select p.proname, p.oid, md5(p.prosrc) as raw, md5(replace(p.prosrc, E'\r', '')) as crs, md5(replace(pg_get_functiondef(p.oid), E'\r', '')) as deff
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
)
select 'guard|' || e.mig || '|' || e.fn || '|' || e.label || '|' || e.flavour || '|expected=' || e.expected
    || '|actual_raw=' || coalesce(a.raw, '-') || '|actual_crs=' || coalesce(a.crs, '-') || '|actual_deff=' || coalesce(a.deff, '-')
    || '|result=' || case when a.proname is null then 'ABSENT'
                          when e.flavour = 'raw'  and a.raw  = e.expected then 'MATCH'
                          when e.flavour = 'raw'  and a.crs  = e.expected then 'MATCH_AFTER_CR_STRIP'
                          when e.flavour = 'deff' and a.deff = e.expected then 'MATCH'
                          else 'DIFF' end
from exp e left join act a on a.proname = e.fn
order by e.mig, e.fn, e.label;

-- 5. view order_details (29c compares md5(pg_get_viewdef(oid, true)) with 005da524de6ede9a11ec010a2d98c74d)
select 'view|order_details|viewdef_md5=' || md5(pg_get_viewdef(c.oid, true)) || '|expected_29c=005da524de6ede9a11ec010a2d98c74d|result='
    || case when md5(pg_get_viewdef(c.oid, true)) = '005da524de6ede9a11ec010a2d98c74d' then 'MATCH' else 'DIFF' end
    || '|viewdef_md5_cr_stripped=' || md5(replace(pg_get_viewdef(c.oid, true), E'\r', ''))
    || '|reloptions=' || coalesce(array_to_string(c.reloptions, ','), '-') || '|owner=' || pg_get_userbyid(c.relowner) || '|acl=' || coalesce(array_to_string(c.relacl, ','), '-')
from pg_class c where c.oid = to_regclass('public.order_details');
select 'view|order_details|columns|' || string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod), ',' order by a.attnum)
from pg_attribute a where a.attrelid = to_regclass('public.order_details') and a.attnum > 0 and not a.attisdropped;
select 'view|order_details|dependents|' || coalesce((select string_agg(distinct dc.relname, ',') from pg_depend d join pg_rewrite r on r.oid = d.objid join pg_class dc on dc.oid = r.ev_class
       where d.refobjid = to_regclass('public.order_details') and dc.oid <> to_regclass('public.order_details')), '(none)');
select 'view|order_details|definition_text|' || replace(replace(pg_get_viewdef(to_regclass('public.order_details'), true), E'\r', ''), E'\n', '\n');

-- 6. enum labels (a new label cannot be removed afterwards, so the order of existing labels matters)
select 'enum|' || t.typname || '|' || string_agg(e.enumlabel, ',' order by e.enumsortorder)
from pg_type t join pg_enum e on e.enumtypid = t.oid join pg_namespace n on n.oid = t.typnamespace where n.nspname = 'public' group by t.typname order by t.typname;

-- 7. columns of the order tables that migrations 20, 21 and 29a touch
select 'columns|' || table_name || '|' || string_agg(column_name || ':' || data_type || ':' || is_nullable, ',' order by ordinal_position)
from information_schema.columns where table_schema = 'public' and table_name in ('orders', 'order_items', 'order_deliveries', 'order_delivery_lines', 'commissions', 'order_requests', 'customers', 'profiles')
group by table_name order by table_name;

-- 8. constraints on the order tables (text is CR-stripped)
select 'constraint|' || cl.relname || '|' || c.conname || '|' || c.contype::text || '|' || replace(replace(pg_get_constraintdef(c.oid), E'\r', ''), E'\n', ' ')
from pg_constraint c join pg_class cl on cl.oid = c.conrelid join pg_namespace n on n.oid = cl.relnamespace
where n.nspname = 'public' and cl.relname in ('orders', 'order_items', 'order_deliveries', 'order_delivery_lines', 'commissions', 'order_requests')
order by cl.relname, c.conname;

-- 9. user triggers in public, plus the auth.users triggers that migration 21 changes the behaviour of
select 'trigger|' || n.nspname || '.' || cl.relname || '|' || t.tgname || '|enabled=' || t.tgenabled::text || '|fn=' || p.proname || '|def_md5=' || md5(replace(pg_get_triggerdef(t.oid), E'\r', ''))
from pg_trigger t join pg_class cl on cl.oid = t.tgrelid join pg_namespace n on n.oid = cl.relnamespace join pg_proc p on p.oid = t.tgfoid
where not t.tgisinternal and (n.nspname = 'public' or (n.nspname = 'auth' and cl.relname = 'users'))
order by n.nspname, cl.relname, t.tgname;

-- 10. RLS policies: tables in public (md5 of the expression) and the Realtime table that 29b/29d add a policy to
select 'policy|' || schemaname || '.' || tablename || '|' || policyname || '|' || cmd || '|roles=' || array_to_string(roles, ',')
    || '|qual_md5=' || md5(coalesce(qual, '')) || '|check_md5=' || md5(coalesce(with_check, ''))
from pg_policies where schemaname in ('public', 'realtime') order by schemaname, tablename, policyname;
select 'rls|' || n.nspname || '.' || c.relname || '|enabled=' || c.relrowsecurity || '|forced=' || c.relforcerowsecurity
from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname in ('public', 'realtime') and c.relkind = 'r' and c.relname in ('orders', 'messages', 'customers', 'order_requests') order by 1;

-- 11. every public function: identity, three md5 flavours, security attributes, and who may EXECUTE (use this for the full Staging-versus-Production diff)
select 'fn|' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
    || '|raw=' || md5(p.prosrc) || '|crs=' || md5(replace(p.prosrc, E'\r', '')) || '|deff=' || md5(replace(pg_get_functiondef(p.oid), E'\r', ''))
    || '|secdef=' || p.prosecdef || '|config=' || coalesce(array_to_string(p.proconfig, ';'), '-') || '|owner=' || pg_get_userbyid(p.proowner)
    || '|anon=' || has_function_privilege('anon', p.oid, 'execute') || '|auth=' || has_function_privilege('authenticated', p.oid, 'execute')
    || '|service=' || has_function_privilege('service_role', p.oid, 'execute')
from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
order by p.proname, pg_get_function_identity_arguments(p.oid);

-- 12. dispatch-related status: order counts per status (labels and counts only) and the stock-affecting functions' presence
select 'orders_by_status|' || status::text || '|' || count(*) from public.orders group by status order by status::text;

-- 13. other connections (decides whether a quiet window is needed; no query text, no client addresses)
select 'activity|state=' || coalesce(state, '-') || '|user=' || coalesce(usename, '-') || '|app=' || coalesce(nullif(application_name, ''), '-') || '|count=' || count(*)
    || '|oldest_xact_age_s=' || coalesce(max(extract(epoch from (now() - xact_start)))::bigint::text, '-')
from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid() group by state, usename, application_name order by 1;

-- 14. row counts (counts only) for before/after comparison
select 'count|' || t.name || '|' || t.n
from (
  select 'orders' as name, count(*) as n from public.orders
  union all select 'order_items', count(*) from public.order_items
  union all select 'order_deliveries', count(*) from public.order_deliveries
  union all select 'payments', count(*) from public.payments
  union all select 'commissions', count(*) from public.commissions
  union all select 'customers', count(*) from public.customers
  union all select 'profiles', count(*) from public.profiles
  union all select 'order_requests', count(*) from public.order_requests
  union all select 'products', count(*) from public.products
  union all select 'stock_movements', count(*) from public.stock_movements
  union all select 'system_logs', count(*) from public.system_logs
) t order by t.name;

select 'done|read_only=' || current_setting('transaction_read_only');
rollback;
