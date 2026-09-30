-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 9 : Fix run_diagnostics() (2026-09-26)
-- ----------------------------------------------------------------------------
-- Run AFTER 07_diagnostics.sql (and 08). Idempotent: one CREATE OR REPLACE.
--
-- The bug: every check ended with
--     v_seen := v_seen || 'orders-without-items';
-- With a text[] on the left and an untyped literal on the right, PostgreSQL
-- resolves || as array || array and tries to parse the literal as an array,
-- so the very first check raised
--     malformed array literal: "orders-without-items"
-- and run_diagnostics() - and repair_issue(), which calls it - always failed.
--
-- The fix: array_append(v_seen, '<id>'::text). The body below is otherwise
-- byte-for-byte the function from 07_diagnostics.sql: same checks, same
-- permission gate (view_diagnostics), same SECURITY DEFINER + search_path.
-- ============================================================================

create or replace function public.run_diagnostics()
returns integer
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_open integer := 0;
  v_seen text[] := array[]::text[];
begin
  perform public.require_permission('view_diagnostics');

  -- ---------------------------------------------------------------------
  -- Each block computes a count and a sample entity, then upserts.
  -- ---------------------------------------------------------------------

  -- 1. Orders with no line items. Their total is necessarily zero, which is
  --    almost always a half-finished write rather than a real free order.
  declare
    v_count integer;
    v_sample text;
  begin
    select count(*), min(o.id) into v_count, v_sample
      from public.orders o
     where not exists (select 1 from public.order_items oi where oi.order_id = o.id);

    perform public.upsert_issue(
      'orders-without-items', v_count,
      'Orders with no line items',
      'ERROR', 'orders', 'order', v_sample,
      format('%s order(s) have no items, so their total is $0.', v_count),
      'Open each order and add the missing lines, or delete the order.',
      false
    );
    v_seen := array_append(v_seen, 'orders-without-items'::text);
  end;

  -- 2. Order totals that disagree with their own lines. This should be
  --    impossible while the triggers are installed, so a hit here means a
  --    trigger was dropped or bypassed - the most important check on the page.
  declare
    v_count integer;
    v_sample text;
  begin
    select count(*), min(t.id) into v_count, v_sample
      from (
        select o.id, o.total, coalesce(sum(oi.line_revenue), 0) as computed
          from public.orders o
          left join public.order_items oi on oi.order_id = o.id
         group by o.id, o.total
        having abs(o.total - coalesce(sum(oi.line_revenue), 0)) > 0.01
      ) t;

    perform public.upsert_issue(
      'orders-total-drift', v_count,
      'Order totals do not match their line items',
      'CRITICAL', 'orders', 'order', v_sample,
      format('%s order(s) have a stored total that differs from the sum of their lines.', v_count),
      'Repairable: recomputes every affected order from its line items.',
      true
    );
    v_seen := array_append(v_seen, 'orders-total-drift'::text);
  end;

  -- 3. Commission totals on profiles drifting from the ledger.
  declare
    v_count integer;
    v_sample text;
  begin
    select count(*), min(t.id) into v_count, v_sample
      from (
        select p.id
          from public.profiles p
          left join public.commissions c
            on c.user_id = p.id and c.status in ('pending', 'approved', 'paid')
         group by p.id, p.earned_commission_total
        having abs(p.earned_commission_total - coalesce(sum(c.amount), 0)) > 0.01
      ) t;

    perform public.upsert_issue(
      'commission-totals-drift', v_count,
      'Commission totals do not match the ledger',
      'ERROR', 'commissions', 'profile', v_sample,
      format('%s staff profile(s) show a commission total that the ledger does not support.', v_count),
      'Repairable: recomputes each profile total from its commission rows.',
      true
    );
    v_seen := array_append(v_seen, 'commission-totals-drift'::text);
  end;

  -- 4. Products out of stock.
  declare
    v_count integer;
    v_sample text;
  begin
    select count(*), min(id) into v_count, v_sample
      from public.products where is_active and stock = 0;

    perform public.upsert_issue(
      'products-out-of-stock', v_count,
      'Products out of stock',
      'WARNING', 'inventory', 'product', v_sample,
      format('%s active product(s) cannot be sold right now.', v_count),
      'Restock from Inventory Control, or deactivate the product.',
      false
    );
    v_seen := array_append(v_seen, 'products-out-of-stock'::text);
  end;

  -- 5. Products at or below their own low-stock threshold.
  declare
    v_count integer;
    v_sample text;
  begin
    select count(*), min(id) into v_count, v_sample
      from public.products
     where is_active and stock > 0 and stock <= low_stock_threshold;

    perform public.upsert_issue(
      'products-low-stock', v_count,
      'Products below their stock threshold',
      'WARNING', 'inventory', 'product', v_sample,
      format('%s product(s) are running low.', v_count),
      'Reorder before they run out.',
      false
    );
    v_seen := array_append(v_seen, 'products-low-stock'::text);
  end;

  -- 6. Products sold at a loss.
  declare
    v_count integer;
    v_sample text;
  begin
    select count(*), min(id) into v_count, v_sample
      from public.products
     where is_active and selling_price < cost_price;

    perform public.upsert_issue(
      'products-negative-margin', v_count,
      'Products priced below cost',
      'ERROR', 'inventory', 'product', v_sample,
      format('%s product(s) lose money on every unit sold.', v_count),
      'Raise the selling price or correct the cost price.',
      false
    );
    v_seen := array_append(v_seen, 'products-negative-margin'::text);
  end;

  -- 7. Customers with no marketing officer. Their orders earn nobody a
  --    commission, which usually means the assignment was missed.
  declare
    v_count integer;
    v_sample text;
  begin
    select count(*), min(id) into v_count, v_sample
      from public.customers
     where status = 'active' and marketing_officer_id is null;

    perform public.upsert_issue(
      'customers-without-officer', v_count,
      'Customers with no marketing officer',
      'WARNING', 'customers', 'customer', v_sample,
      format('%s active customer(s) are unassigned, so their orders earn no commission.', v_count),
      'Assign an officer from the Customer Database.',
      false
    );
    v_seen := array_append(v_seen, 'customers-without-officer'::text);
  end;

  -- 8. Delivered orders that were never fully paid.
  declare
    v_count integer;
    v_sample text;
    v_amount numeric(14,2);
  begin
    select count(*), min(id), coalesce(sum(outstanding_balance), 0)
      into v_count, v_sample, v_amount
      from public.orders
     where status = 'delivered' and outstanding_balance > 0;

    perform public.upsert_issue(
      'orders-delivered-unpaid', v_count,
      'Delivered orders with an outstanding balance',
      'WARNING', 'finance', 'order', v_sample,
      format('%s delivered order(s) still owe $%s.', v_count, v_amount),
      'Chase payment, or record it from the Customer Database.',
      false
    );
    v_seen := array_append(v_seen, 'orders-delivered-unpaid'::text);
  end;

  -- 9. Staff who cannot sign in because no auth user is linked to them.
  declare
    v_count integer;
    v_sample text;
  begin
    select count(*), min(id) into v_count, v_sample
      from public.profiles
     where status = 'active' and auth_user_id is null;

    perform public.upsert_issue(
      'profiles-without-auth', v_count,
      'Active staff with no sign-in account',
      'ERROR', 'security', 'profile', v_sample,
      format('%s active staff profile(s) have no Supabase Auth account, so they cannot sign in.', v_count),
      'Invite them in Authentication > Users using the same email as their profile.',
      false
    );
    v_seen := array_append(v_seen, 'profiles-without-auth'::text);
  end;

  -- Anything this scanner owns but did not raise this run is now resolved.
  update public.system_issues
     set resolved_at = now()
   where source in ('orders', 'inventory', 'customers', 'finance', 'security', 'commissions')
     and resolved_at is null
     and id <> all(v_seen);

  select count(*) into v_open from public.system_issues where resolved_at is null;
  return v_open;
end;
$fn$;

-- CREATE OR REPLACE keeps existing grants; restate them so this file is
-- correct on its own.
revoke all on function public.run_diagnostics() from public, anon;
grant execute on function public.run_diagnostics() to authenticated;
