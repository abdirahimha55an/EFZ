-- =============================================================================
-- EFZ PRODUCTION - second preflight: full text of the functions whose md5 differed, permission holders (counts only), request policies.
-- READ-ONLY: BEGIN READ ONLY ... ROLLBACK, SELECT over catalogs and COUNTS only. No customer names, no amounts, no secrets.
-- Output tags: crinfo, def (one line per source line of the CR-stripped definition), perm_catalog, perm_holders, role_counts, req_status, policy_text.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off
\pset footer off
\pset tuples_only on
\pset format unaligned
begin read only;

select 'identity|db=' || current_database() || '|read_only=' || current_setting('transaction_read_only') || '|server=' || current_setting('server_version');

-- 1. does any stored function body contain CR characters? (Production bodies must be LF only for the 29b/29e guards to be reasoned about)
select 'crinfo|' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|cr_chars=' || (length(p.prosrc) - length(replace(p.prosrc, E'\r', '')))
    || '|lf_chars=' || (length(p.prosrc) - length(replace(p.prosrc, E'\n', ''))) || '|len=' || length(p.prosrc)
from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
  and p.proname in ('update_order_status', 'guard_orders_write', 'transfer_customer_owner', 'convert_website_request', 'can_access_order_request', 'deliver_order_internal', 'create_order', 'grant_role_preset', 'set_user_permissions')
order by 1;
select 'crinfo_total|functions_with_cr=' || count(*) filter (where position(E'\r' in p.prosrc) > 0) || '|of=' || count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f';

-- 2. full definitions, one output line per source line: def|function|lineno|text
select 'def|' || p.proname || '|' || lpad(l.n::text, 4, '0') || '|' || l.t
from pg_proc p
cross join lateral regexp_split_to_table(replace(pg_get_functiondef(p.oid), E'\r', ''), E'\n') with ordinality as l(t, n)
where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
  and p.proname in ('update_order_status', 'guard_orders_write', 'transfer_customer_owner', 'convert_website_request', 'can_access_order_request', 'deliver_order_internal')
order by p.proname, l.n;

-- 3. permission catalog (codes only) and holders per role (counts only)
select 'perm_catalog|' || string_agg(code, ',' order by code) from public.permissions;
select 'perm_holders|' || pr.role::text || '|' || up.permission_code || '|' || count(*)
from public.user_permissions up join public.profiles pr on pr.id = up.user_id
where pr.status = 'active' and up.permission_code ~ '(request|order|customer)'
group by pr.role, up.permission_code order by 1;
select 'role_counts|' || role::text || '|' || status::text || '|' || count(*) from public.profiles group by role, status order by 1;

-- 4. website request pipeline state (counts only)
select 'req_status|' || status::text || '|assigned=' || (assigned_to is not null) || '|' || count(*) from public.order_requests group by status, (assigned_to is not null) order by 1;

-- 5. policies on the request tables and Realtime (text, to compare visibility rules with migration 19)
select 'policy_text|' || tablename || '|' || policyname || '|' || cmd || '|using=' || replace(coalesce(qual, '-'), E'\n', ' ') || '|check=' || replace(coalesce(with_check, '-'), E'\n', ' ')
from pg_policies where schemaname = 'public' and tablename like 'order_request%' order by tablename, policyname;

select 'done|read_only=' || current_setting('transaction_read_only');
rollback;
