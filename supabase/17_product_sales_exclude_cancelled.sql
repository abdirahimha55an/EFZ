-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 17 : product_sales excludes cancelled orders
-- ----------------------------------------------------------------------------
-- Run AFTER 01..16. Idempotent: safe to re-run. Apply to EFZ-Staging first.
--
-- BUG (deployed by 11_order_scope_and_audit.sql)
--   The view filtered cancelled orders on a separate
--       LEFT JOIN public.orders o ON o.id = oi.order_id AND o.status <> 'cancelled'
--   whose columns are never used. A LEFT JOIN keeps every order_items row
--   whether that condition matches or not, so units_sold, revenue, cost, profit
--   and order_count all included the items of CANCELLED orders.
--
-- FIX
--   The cancelled condition moves into the visibility subquery that already
--   decides which order_items rows join a product, and the unused join is
--   removed:
--       EXISTS (SELECT 1 FROM orders ov
--                WHERE ov.id = oi.order_id
--                  AND ov.status <> 'cancelled'                     <- 17
--                  AND can_see_customer_order(ov.customer_id, ov.marketing_officer_id))
--   Rule: an order item counts unless its order's status is 'cancelled'
--   (pending, confirmed, processing, partially_delivered and delivered all
--   count - the same "sales set" as financial_summary, daily_sales,
--   inventory_status.units_sold and the Sales & Analytics page). Products with
--   no counted items still appear with 0 (unchanged LEFT JOIN).
--
-- UNCHANGED: column names, types and order; security_invoker = false;
--   security_barrier = true; cost / profit masking (can_view_cost); product
--   visibility (can_see_products); order visibility (can_see_customer_order);
--   ordering; owner; grants (CREATE OR REPLACE keeps them). No table, data,
--   function, policy or trigger is touched. No application change needed.
--
-- GUARD: refuses to run unless the current definition is EXACTLY the one
--   deployed by 11 (md5 0fdaf7b0ce549cc4011731e1eac6e55a, verified on
--   Production 2026-10-04) or already this fix - so it can never overwrite an
--   unexpected definition. Everything runs in one transaction.
-- ============================================================================
\set ON_ERROR_STOP on
begin;

do $pre$
declare
  v_def text;
begin
  select replace(definition, E'\r', '') into v_def from pg_views where schemaname = 'public' and viewname = 'product_sales';
  if v_def is null then
    raise exception '17: public.product_sales does not exist';
  end if;
  if md5(v_def) = '0fdaf7b0ce549cc4011731e1eac6e55a' then
    raise notice '17: product_sales is the 11 definition - applying the fix';
  elsif position('LEFT JOIN orders o ON' in v_def) = 0
        and v_def ~ 'ov\.status <> ''cancelled''::order_status' then
    raise notice '17: product_sales is already fixed - re-applying (idempotent)';
  else
    raise exception '17: unexpected product_sales definition (md5 %) - refusing to replace it', md5(v_def);
  end if;
end
$pre$;

create or replace view public.product_sales
with (security_invoker = false, security_barrier = true) as
select
  p.id,
  p.name,
  p.category,
  coalesce(sum(oi.quantity), 0)     as units_sold,
  coalesce(sum(oi.line_revenue), 0) as revenue,
  (case when public.can_view_cost() then coalesce(sum(oi.line_cost), 0) end)::numeric   as cost,
  (case when public.can_view_cost() then coalesce(sum(oi.line_profit), 0) end)::numeric as profit,
  count(distinct oi.order_id)       as order_count
from public.products p
left join public.order_items oi
  on oi.product_id = p.id
 and exists (select 1 from public.orders ov
              where ov.id = oi.order_id
                and ov.status <> 'cancelled'
                and public.can_see_customer_order(ov.customer_id, ov.marketing_officer_id))
where public.can_see_products()
group by p.id, p.name, p.category
order by units_sold desc;

do $post$
declare
  v_def text;
  v_opts text[];
begin
  select replace(definition, E'\r', '') into v_def from pg_views where schemaname = 'public' and viewname = 'product_sales';
  if position('LEFT JOIN orders o ON' in v_def) > 0 or v_def !~ 'ov\.status <> ''cancelled''::order_status' then
    raise exception '17: post-check failed - the cancelled filter is not in the visibility subquery';
  end if;
  select reloptions into v_opts from pg_class where oid = 'public.product_sales'::regclass;
  if not (v_opts @> array['security_barrier=true'] and v_opts @> array['security_invoker=false']) then
    raise exception '17: post-check failed - view options changed: %', v_opts;
  end if;
  raise notice '17: product_sales fixed (md5 %)', md5(v_def);
end
$post$;

commit;
