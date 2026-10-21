-- EFZ PRODUCTION - post-release safety checks. READ-ONLY (BEGIN READ ONLY ... ROLLBACK), settings and counts only, no customer data.
-- Expected after the full release: payments disabled, no stg_test, credit policy off, dispatch enforced, no leftover test data.
\set ON_ERROR_STOP on
\pset pager off
\pset footer off
\pset tuples_only on
\pset format unaligned
begin read only;
select 'identity|db=' || current_database() || '|read_only=' || current_setting('transaction_read_only');
select 'payment_methods|' || code || '|enabled=' || enabled from public.payment_methods order by code;
select 'payment_methods_summary|rows=' || count(*) || '|enabled=' || count(*) filter (where enabled) || '|stg_test_rows=' || count(*) filter (where code = 'stg_test') || '|EXPECT enabled=0 and stg_test_rows=0' from public.payment_methods;
select 'credit_policy|' || to_jsonb(p)::text || '|EXPECT enabled=false' from public.credit_policy p;
select 'dispatch|update_order_status_raw_md5=' || md5(prosrc) || '|EXPECT e6548ff6bf1de8d5dfc7ed67343aa0fa after 29e' from pg_proc where pronamespace = 'public'::regnamespace and proname = 'update_order_status';
select 'dispatch|deliver_order_internal_raw_md5=' || md5(prosrc) || '|EXPECT a4e50d113794e96689cde894d6b99636 after 29e' from pg_proc where pronamespace = 'public'::regnamespace and proname = 'deliver_order_internal';
select 'dispatch|orders_by_status|' || status::text || '|' || count(*) from public.orders group by status order by status::text;
select 'accounts|customer_accounts_by_status|' || status::text || '|' || count(*) from public.customer_accounts group by status order by status::text;
select 'test_data|customers_named_TEST=' || count(*) || '|EXPECT 0' from public.customers where name ilike 'TEST-%';
select 'permissions|website_request_holders|' || up.permission_code || '|' || count(*) from public.user_permissions up where up.permission_code like '%website_requests' group by up.permission_code order by up.permission_code;
select 'done|read_only=' || current_setting('transaction_read_only');
rollback;
