-- Rollback of 20_order_payment_terms.sql. Removes the functions, triggers and view.
-- The column is dropped LAST and only if you pass -v drop_column=1, because it may
-- hold recorded terms (take a backup first). App releases that read
-- order_payment_terms must be rolled back before this runs.
begin;
set local lock_timeout = '30s';
drop view if exists public.order_payment_terms;
drop function if exists public.set_order_payment_terms(text, text, text);
drop function if exists public.create_order_with_terms(jsonb, text);
drop trigger if exists trg_orders_payment_terms_fixed on public.orders;
drop trigger if exists trg_orders_payment_terms_ins on public.orders;
drop function if exists public.guard_order_payment_terms();
drop function if exists public.orders_payment_terms_on_insert();
\if :{?drop_column}
  alter table public.orders drop constraint if exists orders_payment_terms_check;
  alter table public.orders drop column if exists payment_terms;
\endif
commit;
