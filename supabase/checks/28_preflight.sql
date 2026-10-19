-- =============================================================================
-- 28 - PREFLIGHT, READ-ONLY (plain SELECTs, changes nothing). Run on Staging BEFORE applying migration 28 (and on any other database before it is applied there).
-- Expected on Staging as of the 2026-10 read-only check: create_order matches_27 = true; convert_website_request matches_27 = true, has_28_marker = false.
-- If a definition row is false, the database has drifted from what migration 28 was written against: STOP and send the definition for review. Migration 28 refuses to run anyway.
-- NOTE: Staging has no supabase_migrations schema (migrations were applied through the SQL editor), so "which migrations are applied" is established by the object checks below, not by a history table.
-- =============================================================================
select 'create_order' as definition,
       md5(replace(pg_get_functiondef('public.create_order(jsonb)'::regprocedure), chr(13), '')) as md5_cr_stripped,
       md5(replace(pg_get_functiondef('public.create_order(jsonb)'::regprocedure), chr(13), '')) = '265e9745acb9418787e6d8cebfb450af' as matches_27;
select 'convert_website_request' as definition,
       md5(replace(pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure), chr(13), '')) as md5_cr_stripped,
       md5(replace(pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure), chr(13), '')) = 'fe992c8ab3edc37522d08e3e6eb41c9c' as matches_27,
       position('migration 28 marker' in pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure)) > 0 as has_28_marker;
-- objects migration 28 relies on (all must be true)
select to_regclass('public.order_price_resolutions') is not null as order_price_resolutions,
       to_regclass('public.product_designs') is not null as product_designs,
       to_regclass('public.customer_price_agreements') is not null as customer_price_agreements,
       to_regprocedure('public._price_resolve(text, text, uuid, date)') is not null as price_resolve,
       to_regclass('public.order_requests_converted_order_uq') is not null as converted_order_unique_index;
-- who may call the two functions (expected: authenticated only)
select p.proname, array(select r.rolname from pg_roles r where r.rolname in ('anon', 'authenticated', 'service_role') and has_function_privilege(r.oid, p.oid, 'execute') order by 1) as callable_by
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('convert_website_request', 'create_order') order by 1;
-- a snapshot to compare after the change (counts only, no customer data)
select (select count(*) from public.orders) as orders, (select count(*) from public.order_items) as order_items, (select count(*) from public.order_price_resolutions) as price_resolutions,
       (select count(*) from public.order_requests where status = 'converted') as converted_requests, (select count(*) from public.order_requests where status = 'confirmed') as confirmed_requests;
