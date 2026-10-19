-- =============================================================================
-- 28 - POST-DEPLOYMENT VERIFICATION, READ-ONLY (plain SELECTs, changes nothing). Run after migration 28 on Staging, and again after the Staging tests.
-- Expected right after applying: convert_website_request has_28_marker = true; create_order matches_27 still true; every "unchanged" count equals the 28_preflight snapshot.
-- After the rollback: has_28_marker = false and matches_27 = true for convert_website_request (md5 fe992c8a...).
-- =============================================================================
select 'create_order (must be unchanged)' as check_name,
       md5(replace(pg_get_functiondef('public.create_order(jsonb)'::regprocedure), chr(13), '')) = '265e9745acb9418787e6d8cebfb450af' as ok;
select 'convert_website_request' as check_name,
       position('migration 28 marker' in pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure)) > 0 as has_28_marker,
       md5(replace(pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure), chr(13), '')) = 'fe992c8ab3edc37522d08e3e6eb41c9c' as is_27_text;
select 'convert_order_request (must be unchanged)' as check_name,
       md5(replace(pg_get_functiondef('public.convert_order_request(uuid, text)'::regprocedure), chr(13), '')) = 'fc18ea5ee175c1448b399754c3baf6ef' as ok;
-- grants unchanged: authenticated only
select p.proname, array(select r.rolname from pg_roles r where r.rolname in ('anon', 'authenticated', 'service_role') and has_function_privilege(r.oid, p.oid, 'execute') order by 1) as callable_by
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'convert_website_request';
-- counts: before any Staging test these equal the 28_preflight snapshot; afterwards only the tested conversions may differ
select (select count(*) from public.orders) as orders, (select count(*) from public.order_items) as order_items, (select count(*) from public.order_price_resolutions) as price_resolutions,
       (select count(*) from public.order_requests where status = 'converted') as converted_requests, (select count(*) from public.order_requests where status = 'confirmed') as confirmed_requests;
-- the five requests converted BEFORE migration 28 are untouched: their orders still exist with the lines they had, and none gained a price-resolution row
select r.id as request_id, r.converted_order_id, (select count(*) from public.order_items i where i.order_id = r.converted_order_id) as lines,
       (select count(*) from public.order_price_resolutions x where x.order_id = r.converted_order_id) as resolution_rows
  from public.order_requests r join public.customer_order_requests c on c.request_id = r.id
 where r.status = 'converted' order by r.status_changed_at;
-- every line created by a post-28 conversion has exactly one price-resolution row (traceability), and an override line has its WARNING log
select i.order_id, i.product_name, i.design_name, i.actual_unit_price, x.source, x.design_id, x.agreement_id, x.list_price, x.applied_price
  from public.order_price_resolutions x join public.order_items i on i.id = x.order_item_id order by x.at desc limit 50;
select occurred_at, message from public.system_logs where metadata ->> 'event' = 'agreed_price_overridden' order by occurred_at desc limit 20;
