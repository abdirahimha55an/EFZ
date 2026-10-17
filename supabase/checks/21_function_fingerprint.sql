-- =============================================================================
-- 21 - FINGERPRINT of every public function, RLS policy and auth-schema trigger.
-- READ-ONLY (a plain SELECT). Run it before and after migration 21 and diff the
-- outputs: only the objects migration 21 names as changed or added may differ
-- (see the header of supabase/21_customer_accounts.sql). Proves create_order,
-- create_order_with_terms, record_payment, update_order_status,
-- set_order_payment_terms, submit_order_request, convert_website_request and every
-- RLS policy on an existing table are untouched.
-- =============================================================================
\pset tuples_only on
\pset format unaligned
select 'function|' || p.oid::regprocedure::text || '|' || md5(pg_get_functiondef(p.oid))
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
 order by 1;
select 'policy|' || schemaname || '.' || tablename || '.' || policyname || '|' || md5(coalesce(roles::text, '') || cmd || coalesce(qual, '') || coalesce(with_check, ''))
  from pg_policies where schemaname = 'public' order by 1;
select 'authtrigger|' || tgname || '|' || md5(pg_get_triggerdef(t.oid))
  from pg_trigger t where tgrelid = 'auth.users'::regclass and not tgisinternal order by 1;
select 'table|' || c.relname || '|' || c.relrowsecurity::text || '|' || coalesce(c.relacl::text, '')
  from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v') order by 1;
