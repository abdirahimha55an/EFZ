-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 15 : Realtime change feed for public.orders (2026-10-03)
-- ----------------------------------------------------------------------------
-- Run AFTER 01..05, 07..14. Idempotent: safe to re-run. Apply to EFZ-Staging first.
--
-- WHY
--   Personal "New Order" alerts are written by each user's own admin tab when it
--   re-derives its alert feed (app/admin/layout.tsx, every 30 s). A new order
--   therefore showed up only on that tab's next 30 s refresh. Publishing orders
--   to Supabase Realtime lets an open tab hear "an order I can see changed" and
--   re-derive its feed at once.
--
-- WHAT
--   Adds public.orders to the supabase_realtime publication. Nothing else: no
--   table, column, row, policy, function, grant or replica identity changes.
--
-- WHY IT IS SAFE
--   * Realtime delivers an INSERT/UPDATE change only to subscribers whose own
--     JWT passes the orders SELECT policy (orders_select / can_access_order), so
--     a user hears about exactly the orders the app already lets them read.
--   * The app uses the event only as a "refresh now" signal: it never reads the
--     payload and never writes a notification from it.
--   * Replica identity stays DEFAULT, so a DELETE change carries the primary key
--     only. The app does not subscribe to DELETE.
--
-- Rollback: supabase/rollback/15_rollback.sql (removes orders from the publication).
-- ============================================================================

begin;

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    raise exception 'supabase_realtime publication is missing - Realtime is not set up on this project';
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'orders'
  ) then
    alter publication supabase_realtime add table public.orders;
  end if;
end
$$;

commit;
