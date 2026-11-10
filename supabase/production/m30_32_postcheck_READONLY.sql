-- EFZ PRODUCTION - READ-ONLY post-checks after migrations 30, 31, 32 (and the secret). Writes nothing. Every verdict must be OK.
-- The secret VALUE is never selected, only whether one row exists.
begin read only;

select 'm30_function' as item, case when to_regprocedure('public.submit_public_inquiry(jsonb)') is not null then 'OK' else 'FAIL' end as verdict;
select 'm31_signing_logic' as item, case when position('inquiry_signing_secret' in pg_get_functiondef('public.submit_public_inquiry(jsonb)'::regprocedure)) > 0 then 'OK' else 'FAIL' end as verdict;
select 'm31_secret_stored(one row)' as item, case when (select count(*) from public.inquiry_signing_secret) = 1 then 'OK' else 'FAIL: expected exactly 1' end as verdict;
select 'm32_order_function_has_designId' as item, case when position('designId' in pg_get_functiondef('public.submit_order_request(jsonb)'::regprocedure)) > 0 then 'OK' else 'FAIL' end as verdict;
select 'm32_public_designs_function' as item, case when to_regprocedure('public.public_product_designs()') is not null
        and has_function_privilege('anon', 'public.public_product_designs()', 'execute') then 'OK' else 'FAIL' end as verdict;
select 'anon_submit_functions_executable' as item, case when has_function_privilege('anon', 'public.submit_public_inquiry(jsonb)', 'execute')
        and has_function_privilege('anon', 'public.submit_order_request(jsonb)', 'execute') then 'OK' else 'FAIL' end as verdict;
select 'anon_cannot_read_tables' as item, case when not has_table_privilege('anon', 'public.product_designs', 'select')
        and not has_table_privilege('anon', 'public.customer_order_request_lines', 'select')
        and not has_table_privilege('anon', 'public.public_inquiries', 'select')
        and not has_table_privilege('anon', 'public.inquiry_signing_secret', 'select') then 'OK' else 'FAIL' end as verdict;
select 'clients_cannot_read_secret' as item, case when not has_table_privilege('authenticated', 'public.inquiry_signing_secret', 'select') then 'OK' else 'FAIL' end as verdict;
select 'm32_triggers' as item, case when (select count(*) from pg_trigger where tgrelid = 'public.product_designs'::regclass and not tgisinternal and tgname in (
        select t.tgname from pg_trigger t join pg_proc p on p.oid = t.tgfoid where t.tgrelid = 'public.product_designs'::regclass and p.proname in ('guard_product_design', 'log_product_design_changes'))) = 2 then 'OK' else 'FAIL' end as verdict;
select 'rls_on_new_tables' as item, case when (select bool_and(relrowsecurity) from pg_class where oid in ('public.public_inquiries'::regclass, 'public.inquiry_signing_secret'::regclass)) then 'OK' else 'FAIL' end as verdict;
select 'unchanged_after_release' as item,
       (select count(*) from public.orders) as orders, (select count(*) from public.payments) as payments, (select count(*) from public.commissions) as commissions,
       (select count(*) from public.customers) as customers, (select count(*) from public.product_designs) as product_designs,
       (select count(*) from public.order_requests) as order_requests, (select count(*) from public.stock_movements) as stock_movements;

rollback;
