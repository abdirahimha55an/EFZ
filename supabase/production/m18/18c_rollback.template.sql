-- ============================================================================
-- EFZ - ROLLBACK of 18c_remove_legacy_request_insert.sql
-- ----------------------------------------------------------------------------
-- Restores the legacy direct-insert path exactly as 18b left it: the original
-- order_requests_insert_public policy, INSERT for anon and authenticated, and the
-- temporary legacy-admission triggers (same phone rules, limit and lock).
-- Deletes nothing. Run BEFORE rolling back the app or 18b. Idempotent.
-- ============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
begin
  if to_regprocedure('public.website_request_admission(text,uuid)') is null then
    raise exception '18c rollback: 18b objects are missing - nothing to restore onto';
  end if;
end
$pre$;

-- @@LEGACY_ADMISSION_FUNCTION@@

drop trigger if exists trg_order_requests_legacy_admission on public.order_requests;
create trigger trg_order_requests_legacy_admission
  before insert on public.order_requests
  for each row execute function public.order_requests_legacy_admission();

drop trigger if exists trg_order_requests_legacy_admission_after on public.order_requests;
create trigger trg_order_requests_legacy_admission_after
  after insert on public.order_requests
  for each row execute function public.order_requests_legacy_admission();

revoke all on function public.order_requests_legacy_admission() from public, anon, authenticated;

drop policy if exists order_requests_insert_public on public.order_requests;
-- @@INSERT_POLICY_ORIGINAL@@

grant insert on public.order_requests to anon, authenticated;

do $post$
begin
  if not has_table_privilege('anon', 'public.order_requests', 'INSERT')
     or not exists (select 1 from pg_policy where polrelid = 'public.order_requests'::regclass and polname = 'order_requests_insert_public')
     or (select count(*) from pg_trigger where tgrelid = 'public.order_requests'::regclass
          and tgname like 'trg_order_requests_legacy_admission%') <> 2 then
    raise exception '18c rollback post-check failed - aborting';
  end if;
  raise notice '18c rollback: legacy direct-insert path restored (held to the 18b rules)';
end
$post$;

commit;
