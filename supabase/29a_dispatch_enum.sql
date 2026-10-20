-- =============================================================================
-- 29a. Dispatched status: the enum label and the two columns (additive; no behaviour change by itself)
-- A new enum label cannot be used in the transaction that adds it, so this runs and COMMITS before 29b_dispatch_and_live_orders.sql.
-- Nothing uses the label yet, no existing row changes, and dispatched_at is null for every existing order (history is never invented).
-- ROLLBACK: supabase/rollback/29_dispatch_rollback.sql drops the columns; the unused enum label remains (a label cannot be dropped without rebuilding the type).
-- =============================================================================
begin;
alter type public.order_status add value if not exists 'dispatched' after 'processing';
alter table public.orders add column if not exists dispatched_at timestamptz;
alter table public.orders add column if not exists dispatched_by text;
comment on column public.orders.dispatched_at is 'When EFZ recorded the order as dispatched (out for delivery). Null = never recorded. Maintained by update_order_status().';
comment on column public.orders.dispatched_by is 'Profile id of the staff member who recorded the dispatch.';
commit;
