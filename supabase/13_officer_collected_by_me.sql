-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 13 : "Collected by Me" for Marketing Officers (2026-10-02)
-- ----------------------------------------------------------------------------
-- Run AFTER 01..05, 07, 08, 09, 10, 11 and 12. Idempotent: safe to re-run.
-- Apply to EFZ-Staging (adjjamiqwboawqedaapi) first.
--
-- WHY
--   "Collected by Me" (locked 2026-10-02) = SUM(payments.amount) WHERE
--   payments.recorded_by = the signed-in Marketing Officer - including payments
--   they recorded on an order they can no longer see (customer transferred
--   away, or recorded before 11). Under the RLS of 11 an officer reads only the
--   payments of orders they can currently see, so the app cannot add those up.
--
-- WHAT
--   One read-only function, public.my_collected_payments(), returning ONE row:
--   the caller's own total, this month's total (Mogadishu calendar) and count.
--   Nothing else changes: no table, column, row, policy or existing function.
--
-- WHY IT IS SAFE
--   * No parameters: the caller cannot name another officer, order or customer.
--     The identity is current_profile_id(), i.e. the active profile linked to
--     auth.uid() from the caller's own JWT.
--   * Refuses unless that profile is an ACTIVE Marketing Officer. Signed-out
--     callers have no EXECUTE at all; the trusted SQL editor (no JWT) is refused
--     too, because it has no profile.
--   * Returns three aggregates only - no payment, order, customer or officer
--     row, id, name or date leaves the function.
--   * Only payments the caller personally recorded are summed. RLS on payments,
--     orders and customers is untouched for every other purpose.
--   * SECURITY DEFINER with a fixed search_path (public, pg_temp) and STABLE:
--     it contains no INSERT, UPDATE or DELETE and cannot run any.
--
-- Rollback: supabase/rollback/13_rollback.sql (drops this one function).
-- ============================================================================

begin;

create or replace function public.my_collected_payments()
returns table (total_amount numeric(14,2), this_month_amount numeric(14,2), payment_count integer)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_me    text := public.current_profile_id();
  v_month date := date_trunc('month', public.efz_today())::date;
begin
  if v_me is null or not exists (
       select 1 from public.profiles p
        where p.id = v_me and p.role = 'Marketing Officer' and p.status = 'active') then
    raise exception 'Only a signed-in, active Marketing Officer can read their own collections'
      using errcode = '42501';
  end if;

  return query
    select coalesce(sum(pm.amount), 0)::numeric(14,2),
           coalesce(sum(pm.amount) filter (where pm.payment_date >= v_month), 0)::numeric(14,2),
           count(*)::integer
      from public.payments pm
     where pm.recorded_by = v_me;
end;
$fn$;

comment on function public.my_collected_payments() is
  'Collected by Me: the signed-in Marketing Officer''s own recorded payments (total, this month, count). No parameters, aggregates only.';

revoke all on function public.my_collected_payments() from public, anon, authenticated;
grant execute on function public.my_collected_payments() to authenticated;

commit;
