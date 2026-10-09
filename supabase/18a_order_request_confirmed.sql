-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 18a : order_request_status gains 'confirmed' (Website Request Inbox)
-- ----------------------------------------------------------------------------
-- Run AFTER 01..17. Idempotent: safe to re-run. Apply to EFZ-Staging first.
-- Run ALONE, before 18b: PostgreSQL cannot use a new enum value in the
-- transaction that adds it, and 18b uses 'confirmed' in functions and checks.
--
-- WHAT
--   order_request_status: new, contacted, [confirmed], converted, rejected.
--   Nothing else. No row is read, updated or deleted.
--
-- GUARD
--   Refuses unless the type is exactly {new, contacted, converted, rejected}
--   (Production 2026-10-08) or already has 'confirmed' in the right place.
--
-- Rollback: none. PostgreSQL cannot drop an enum value; an unused value is
-- harmless. supabase/rollback/18b_rollback.sql verifies no row uses it.
-- ============================================================================

do $guard$
declare
  v_labels text[];
begin
  select array_agg(enumlabel::text order by enumsortorder) into v_labels
    from pg_enum where enumtypid = 'public.order_request_status'::regtype;

  if v_labels = array['new', 'contacted', 'converted', 'rejected'] then
    raise notice '18a: adding confirmed to order_request_status';
  elsif v_labels = array['new', 'contacted', 'confirmed', 'converted', 'rejected'] then
    raise notice '18a: confirmed already present - nothing to do';
  else
    raise exception '18a: unexpected order_request_status values % - refusing', v_labels;
  end if;
end
$guard$;

alter type public.order_request_status add value if not exists 'confirmed' before 'converted';
