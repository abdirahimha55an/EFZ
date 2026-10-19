-- =============================================================================
-- 28 - CONTENT FINGERPRINT, READ-ONLY (a single SELECT, changes nothing). Run on Staging immediately BEFORE and again immediately AFTER migration 28.
-- Every value must be IDENTICAL, except `convert_website_request` (the one function migration 28 replaces) and `all_other_function_bodies` stays identical because that
-- hash EXCLUDES convert_website_request. If someone else is working in Staging between the two runs, the data hashes (orders ... system_logs) can legitimately differ:
-- re-run both close together; the schema hashes never change on their own.
-- The data hashes are md5 over the full text of every row (ordered by a stable key), so any rewritten, deleted or added historical row changes them.
-- =============================================================================
select
  -- historical data
  (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.orders t)                         as orders,
  (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.order_items t)                    as order_items,
  (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.order_requests t)                 as order_requests,
  (select md5(coalesce(string_agg(t::text, '|' order by t.request_id, t.line_no), '')) from public.customer_order_request_lines t) as customer_order_request_lines,
  (select md5(coalesce(string_agg(t::text, '|' order by t.request_id), '')) from public.customer_order_requests t) as customer_order_requests,
  (select md5(coalesce(string_agg(t::text, '|' order by t.order_item_id), '')) from public.order_price_resolutions t) as order_price_resolutions,
  (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.system_logs t)                    as system_logs,
  (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.product_designs t)                as product_designs,
  (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.customer_price_agreements t)      as customer_price_agreements,
  (select md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.products t)                       as products,
  -- schema
  (select md5(coalesce(string_agg(indexdef, '|' order by schemaname, tablename, indexname), '')) from pg_indexes where schemaname = 'public')                                   as indexes,
  (select md5(coalesce(string_agg(tablename || '.' || policyname || '.' || cmd || '.' || coalesce(qual, '') || '.' || coalesce(with_check, ''), '|' order by tablename, policyname), '')) from pg_policies where schemaname = 'public') as policies,
  (select md5(coalesce(string_agg(table_name || '.' || column_name || '.' || data_type || '.' || is_nullable || '.' || coalesce(column_default, ''), '|' order by table_name, ordinal_position), '')) from information_schema.columns where table_schema = 'public') as columns,
  (select md5(coalesce(string_agg(grantee || '.' || table_name || '.' || privilege_type, '|' order by grantee, table_name, privilege_type), '')) from information_schema.role_table_grants where table_schema = 'public') as table_grants,
  (select md5(coalesce(string_agg(grantee || '.' || routine_name || '.' || specific_name || '.' || privilege_type, '|' order by grantee, specific_name, privilege_type), '')) from information_schema.role_routine_grants where routine_schema = 'public') as function_grants,
  (select md5(coalesce(string_agg(pg_get_triggerdef(t.oid), '|' order by t.tgrelid::regclass::text, t.tgname), '')) from pg_trigger t where not t.tgisinternal and exists (select 1 from pg_class c where c.oid = t.tgrelid and c.relnamespace = 'public'::regnamespace))                     as triggers,
  (select count(*) from pg_proc where pronamespace = 'public'::regnamespace)                                                                                                       as function_count,
  (select md5(coalesce(string_agg(md5(pg_get_functiondef(p.oid)), '|' order by p.oid::regprocedure::text), '')) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.proname <> 'convert_website_request') as all_other_function_bodies,
  (select md5(replace(pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure), chr(13), ''))) as convert_website_request;
