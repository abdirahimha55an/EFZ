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
-- (1) The FIVE customer-app requests that were converted before migration 28, pinned by their exact ids (recorded read-only on Staging on 2026-10-19, converted 2026-10-17).
--     Expected after migration 28 (and after any later test): each row present, status 'converted', 1 line, 0 price-resolution rows, the same converted_order_id as below.
select v.request_id, r.status, r.converted_order_id, (r.converted_order_id = v.order_id) as same_order,
       (select count(*) from public.order_items i where i.order_id = r.converted_order_id) as lines,
       (select count(*) from public.order_price_resolutions x where x.order_id = r.converted_order_id) as resolution_rows
  from (values ('7d25d3a1-15b9-4011-a747-192d7aba5303'::uuid, 'ORD-5605802'), ('a0a22c75-9f7b-4a45-9152-774a8363b865'::uuid, 'ORD-9090024'),
               ('fd72242f-082c-4938-8dd3-af7fd250d9fa'::uuid, 'ORD-7187520'), ('398bf0b4-765e-4989-9e2a-47852a3d8f50'::uuid, 'ORD-9393300'),
               ('c2543ad7-c273-45f6-a953-b5b5658b57d1'::uuid, 'ORD-8166332')) as v(request_id, order_id)
  left join public.order_requests r on r.id = v.request_id
 order by v.order_id;
-- (2) EVERY converted request that came from the customer app (not only the five above): after migration 28 and later tests this list can grow, and the extra rows are
--     the post-28 conversions. Do not read its row count as "five".
select r.id as request_id, r.converted_order_id, r.status_changed_at,
       (select count(*) from public.order_items i where i.order_id = r.converted_order_id) as lines,
       (select count(*) from public.order_price_resolutions x where x.order_id = r.converted_order_id) as resolution_rows
  from public.order_requests r join public.customer_order_requests c on c.request_id = r.id
 where r.status = 'converted' order by r.status_changed_at;
-- (3) Content proof that no historical row changed: run supabase/checks/28_fingerprint.sql and compare it with the run taken just before migration 28.
-- every line created by a post-28 conversion has exactly one price-resolution row (traceability), and an override line has its WARNING log
select i.order_id, i.product_name, i.design_name, i.actual_unit_price, x.source, x.design_id, x.agreement_id, x.list_price, x.applied_price
  from public.order_price_resolutions x join public.order_items i on i.id = x.order_item_id order by x.at desc limit 50;
select occurred_at, message from public.system_logs where metadata ->> 'event' = 'agreed_price_overridden' order by occurred_at desc limit 20;
