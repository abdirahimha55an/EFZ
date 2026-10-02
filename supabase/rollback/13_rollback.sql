-- ============================================================================
-- EFZ - Rollback of 13_officer_collected_by_me.sql
-- Drops the one read-only function 13 added. It holds no data, so rolling back
-- loses nothing; the app then shows "—" for Collected by Me.
-- ============================================================================
begin;
drop function if exists public.my_collected_payments();
commit;
