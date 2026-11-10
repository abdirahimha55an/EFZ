-- EFZ PRODUCTION - READ-ONLY preflight for migrations 30, 31, 32. Runs inside BEGIN READ ONLY ... ROLLBACK; writes nothing.
-- Expected BEFORE applying: every line says OK. Any line that says STOP: do not apply, send the output.
begin read only;

select 'read_only_transaction' as item, case when current_setting('transaction_read_only') = 'on' then 'OK' else 'STOP' end as result;

-- A. Production identity (this must be the EFZ Production database: 30 orders+ and no @example.com staff)
select 'no_example_com_staff' as item,
       case when (select count(*) from public.profiles where email ilike '%@example.com') = 0 then 'OK' else 'STOP: looks like Staging' end as result;

-- B. None of 30/31/32 is applied yet
select 'm30_not_applied' as item, case when to_regprocedure('public.submit_public_inquiry(jsonb)') is null and to_regclass('public.public_inquiries') is null then 'OK' else 'STOP: already present' end as result;
select 'm31_not_applied' as item, case when to_regclass('public.inquiry_signing_secret') is null then 'OK' else 'STOP: already present' end as result;
select 'm32_not_applied' as item, case when to_regprocedure('public.public_product_designs()') is null then 'OK' else 'STOP: already present' end as result;

-- C. Dependencies of 30 (18b objects), 32 (18b + 22)
select 'dependencies_present' as item,
       case when to_regprocedure('public.submit_order_request(jsonb)') is not null
             and to_regprocedure('public.website_request_admission(text, uuid)') is not null
             and to_regprocedure('public.validate_request_phone(text)') is not null
             and to_regprocedure('public.current_profile_id()') is not null
             and to_regprocedure('public.current_profile_name()') is not null
             and to_regclass('public.website_request_settings') is not null
             and to_regclass('public.product_designs') is not null
             and to_regclass('public.customer_order_request_lines') is not null
            then 'OK' else 'STOP: a prerequisite object is missing' end as result;

-- D. Fingerprint of the live submit_order_request (CRs removed). Required by 32: c819251209a3ae536b731340daaa3a4b
select 'submit_order_request_md5' as item,
       md5(replace(pg_get_functiondef('public.submit_order_request(jsonb)'::regprocedure), chr(13), '')) as result,
       case when md5(replace(pg_get_functiondef('public.submit_order_request(jsonb)'::regprocedure), chr(13), '')) = 'c819251209a3ae536b731340daaa3a4b' then 'OK' else 'STOP: differs from 18b' end as verdict;

-- E. pgcrypto (31 creates it in schema "extensions" if missing; if it lives elsewhere 31 would fail to find it)
select 'pgcrypto_schema' as item, coalesce((select extnamespace::regnamespace::text from pg_extension where extname = 'pgcrypto'), 'not installed') as result,
       case when coalesce((select extnamespace::regnamespace::text from pg_extension where extname = 'pgcrypto'), 'extensions') = 'extensions' then 'OK' else 'STOP: pgcrypto is not in schema extensions' end as verdict;

-- F. Quiet database: no session sitting in a transaction (a concurrent session once deadlocked an earlier migration)
select 'idle_in_transaction_sessions' as item, count(*)::text as result, case when count(*) = 0 then 'OK' else 'STOP: close other clients' end as verdict
from pg_stat_activity where state like 'idle in transaction%' and pid <> pg_backend_pid();

-- G. Baseline row counts to compare after the release (nothing here may change because of 30-32 except the new tables)
select 'baseline' as item,
       (select count(*) from public.orders) as orders, (select count(*) from public.payments) as payments, (select count(*) from public.commissions) as commissions,
       (select count(*) from public.customers) as customers, (select count(*) from public.product_designs) as product_designs,
       (select count(*) from public.order_requests) as order_requests, (select count(*) from public.stock_movements) as stock_movements;

rollback;
