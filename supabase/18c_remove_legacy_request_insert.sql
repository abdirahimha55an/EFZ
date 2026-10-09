-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 18c : remove the legacy direct-insert path into order_requests
-- ----------------------------------------------------------------------------
-- Run AFTER 18b, and ONLY after the approved runtime-evidence gate (design M,
-- "18c gate"): the new app is live, a fresh page submits through
-- submit_order_request only, and no direct order_requests INSERT is in use.
-- Idempotent: safe to re-run.
--
-- WHAT
--   drops policy order_requests_insert_public; revokes INSERT on order_requests
--   from anon and authenticated; drops the temporary legacy-admission triggers
--   and function from 18b. After this, submit_order_request() is the only way
--   to create a request. No row is read, updated or deleted.
--
-- Rollback: supabase/rollback/18c_rollback.sql (restores the path exactly as 18b left it).
-- ============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
begin
  if to_regprocedure('public.submit_order_request(jsonb)') is null
     or to_regprocedure('public.website_request_admission(text,uuid)') is null then
    raise exception '18c: 18b is not applied - refusing';
  end if;
  if not has_function_privilege('anon', 'public.submit_order_request(jsonb)', 'EXECUTE') then
    raise exception '18c: anon cannot execute submit_order_request - refusing (the website would have no way to submit)';
  end if;
  if exists (select 1 from pg_policy where polrelid = 'public.order_requests'::regclass and polname = 'order_requests_insert_public') then
    raise notice '18c: removing the legacy direct-insert path';
  else
    raise notice '18c: legacy path already removed - re-applying (idempotent)';
  end if;
end
$pre$;

drop policy if exists order_requests_insert_public on public.order_requests;
revoke insert on public.order_requests from anon, authenticated;

drop trigger if exists trg_order_requests_legacy_admission on public.order_requests;
drop trigger if exists trg_order_requests_legacy_admission_after on public.order_requests;
drop function if exists public.order_requests_legacy_admission();

do $post$
declare
  v_problem text;
begin
  select string_agg(x, ', ') into v_problem from (
    select r || ' can INSERT order_requests' as x from unnest(array['anon', 'authenticated']) r
     where has_table_privilege(r, 'public.order_requests', 'INSERT')
    union all
    select 'insert policy still present' where exists (
      select 1 from pg_policy where polrelid = 'public.order_requests'::regclass and polname = 'order_requests_insert_public')
    union all
    select 'legacy trigger still present' where exists (
      select 1 from pg_trigger where tgrelid = 'public.order_requests'::regclass and tgname like 'trg_order_requests_legacy_admission%')
    union all
    select r || ' cannot execute submit_order_request' from unnest(array['anon', 'authenticated']) r
     where not has_function_privilege(r, 'public.submit_order_request(jsonb)', 'EXECUTE')
  ) q;
  if v_problem is not null then
    raise exception '18c post-check failed: % - aborting', v_problem;
  end if;
  raise notice '18c: only submit_order_request() can create website requests now';
end
$post$;

commit;
