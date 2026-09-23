-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 4 of 5 : Reporting views
-- ----------------------------------------------------------------------------
-- Every view is declared with security_invoker = true so it runs under the
-- caller's RLS policies. Without that flag a view silently leaks rows the
-- caller is not allowed to see.
-- ============================================================================

-- ============================================================================
-- 1. public_products - the anon-safe product feed
-- ----------------------------------------------------------------------------
-- cost_price is deliberately absent. The public site must select from this
-- view, never from public.products.
-- ============================================================================

create or replace view public.public_products
with (security_invoker = true) as
select
  p.id,
  p.name,
  p.description,
  p.category,
  p.size,
  p.durability,
  p.surface_type,
  p.is_wholesale,
  p.selling_price,
  p.price,
  p.image_url,
  (p.stock > 0) as in_stock
from public.products p
where p.is_active;

comment on view public.public_products is 'Anon-safe product feed. Excludes cost_price and exact stock levels.';

-- ============================================================================
-- 2. order_details - one row per order, items and payments nested
-- ----------------------------------------------------------------------------
-- The JSON keys are camelCase so the client can hand the arrays straight to
-- the existing Order / OrderItem / PaymentRecord types.
-- ============================================================================

create or replace view public.order_details
with (security_invoker = true) as
select
  o.id,
  o.customer_id,
  o.customer_name,
  o.phone,
  o.marketing_officer_id,
  mo.name as marketing_officer_name,
  o.status,
  o.payment_status,
  o.order_type,
  o.order_date,
  o.delivery_notes,
  o.total,
  o.cost,
  o.gross_profit,
  o.amount_paid,
  o.outstanding_balance,
  o.commission_paid,
  o.legacy_order_ids,
  o.legacy_reference_id,
  o.created_at,
  o.updated_at,
  coalesce(i.items,    '[]'::jsonb) as items,
  coalesce(pay.payments, '[]'::jsonb) as payments,
  coalesce(i.unit_count, 0) as unit_count
from public.orders o
left join public.profiles mo on mo.id = o.marketing_officer_id
left join lateral (
  select
    jsonb_agg(
      jsonb_build_object(
        'id',                 oi.id,
        'productId',          oi.product_id,
        'productName',        oi.product_name,
        'designName',         oi.design_name,
        'quantity',           oi.quantity,
        'standardUnitPrice',  oi.standard_unit_price,
        'actualUnitPrice',    oi.actual_unit_price,
        'price',              oi.actual_unit_price,
        'historicalUnitCost', oi.historical_unit_cost,
        'costPrice',          oi.historical_unit_cost,
        'lineRevenue',        oi.line_revenue,
        'lineCost',           oi.line_cost,
        'lineProfit',         oi.line_profit
      )
      order by oi.created_at, oi.id
    ) as items,
    sum(oi.quantity) as unit_count
  from public.order_items oi
  where oi.order_id = o.id
) i on true
left join lateral (
  select jsonb_agg(
    jsonb_build_object(
      'id',            pm.id,
      'orderId',       pm.order_id,
      'amount',        pm.amount,
      'paymentDate',   pm.payment_date,
      'paymentMethod', pm.payment_method,
      'reference',     pm.reference,
      'notes',         pm.notes,
      'recordedBy',    pm.recorded_by,
      'createdAt',     pm.created_at
    )
    order by pm.payment_date, pm.created_at
  ) as payments
  from public.payments pm
  where pm.order_id = o.id
) pay on true;

comment on view public.order_details is 'Complete order with nested items and payments. Replaces the localStorage Order shape one-for-one.';

-- ============================================================================
-- 3. inventory_status - stock health per product
-- ============================================================================

create or replace view public.inventory_status
with (security_invoker = true) as
select
  p.id,
  p.name,
  p.category,
  p.stock,
  p.low_stock_threshold,
  p.cost_price,
  p.selling_price,
  (p.selling_price - p.cost_price) as unit_margin,
  case
    when p.selling_price > 0
    then round((p.selling_price - p.cost_price) / p.selling_price * 100, 2)
    else 0
  end as margin_percentage,
  (p.stock * p.cost_price) as stock_value_at_cost,
  case
    when p.stock <= 0                       then 'out_of_stock'
    when p.stock <= p.low_stock_threshold   then 'low_stock'
    else 'healthy'
  end as stock_state,
  coalesce(sold.units_sold, 0) as units_sold,
  p.is_active
from public.products p
left join lateral (
  select sum(oi.quantity) as units_sold
  from public.order_items oi
  join public.orders o on o.id = oi.order_id
  where oi.product_id = p.id
    and o.status <> 'cancelled'
) sold on true;

-- ============================================================================
-- 4. customer_financials - per-customer receivables
-- ----------------------------------------------------------------------------
-- Mirrors getCustomerFinancialSummary() in lib/financial.ts.
-- ============================================================================

create or replace view public.customer_financials
with (security_invoker = true) as
select
  c.id,
  c.name,
  c.phone,
  c.email,
  c.status,
  c.marketing_officer_id,
  mo.name as marketing_officer_name,
  c.registered_on,
  coalesce(agg.total_orders, 0)     as total_orders,
  coalesce(agg.total_units, 0)      as total_units,
  coalesce(agg.revenue, 0)          as revenue_generated,
  coalesce(agg.collected, 0)        as cash_collected,
  coalesce(agg.outstanding, 0)      as outstanding,
  agg.last_order_date,
  case
    when coalesce(agg.outstanding, 0) <= 0 then 'paid'
    when coalesce(agg.collected, 0)   > 0  then 'partial'
    else 'unpaid'
  end as payment_status
from public.customers c
left join public.profiles mo on mo.id = c.marketing_officer_id
left join lateral (
  select
    count(*)                              as total_orders,
    sum(o.total)                          as revenue,
    sum(o.amount_paid)                    as collected,
    sum(o.outstanding_balance)            as outstanding,
    max(o.order_date)                     as last_order_date,
    sum((select coalesce(sum(oi.quantity), 0)
           from public.order_items oi where oi.order_id = o.id)) as total_units
  from public.orders o
  where o.customer_id = c.id
    and o.status <> 'cancelled'
) agg on true;

-- ============================================================================
-- 5. officer_commission_summary - the Marketing Officer payout board
-- ============================================================================

create or replace view public.officer_commission_summary
with (security_invoker = true) as
select
  p.id      as user_id,
  p.name,
  p.role,
  p.status,
  p.commission_percentage,
  coalesce(c.earned,   0) as earned_commission,
  coalesce(c.paid,     0) as paid_commission,
  coalesce(c.pending,  0) as pending_commission,
  coalesce(c.order_count, 0) as commissionable_orders,
  coalesce(cust.customer_count, 0) as customers_registered
from public.profiles p
left join lateral (
  select
    sum(amount) filter (where status in ('pending', 'approved', 'paid')) as earned,
    sum(amount) filter (where status = 'paid')                           as paid,
    sum(amount) filter (where status in ('pending', 'approved'))         as pending,
    count(*)    filter (where status <> 'void')                          as order_count
  from public.commissions
  where user_id = p.id
) c on true
left join lateral (
  select count(*) as customer_count
  from public.customers
  where marketing_officer_id = p.id
) cust on true;

-- ============================================================================
-- 6. financial_summary - the single-row dashboard KPI strip
-- ----------------------------------------------------------------------------
-- Mirrors getFinancialSummary() in lib/financial.ts. Cancelled orders excluded.
-- ============================================================================

create or replace view public.financial_summary
with (security_invoker = true) as
select
  count(*)                                        as total_orders,
  coalesce(sum(o.total), 0)                       as revenue_generated,
  coalesce(sum(o.cost), 0)                        as total_cost,
  coalesce(sum(o.gross_profit), 0)                as gross_profit,
  coalesce(sum(o.amount_paid), 0)                 as cash_collected,
  coalesce(sum(o.outstanding_balance), 0)         as outstanding_receivables,
  coalesce(sum(u.units), 0)                       as total_units,
  case
    when coalesce(sum(o.total), 0) > 0
    then round(coalesce(sum(o.gross_profit), 0) / sum(o.total) * 100, 2)
    else 0
  end                                             as gross_margin
from public.orders o
left join lateral (
  select coalesce(sum(oi.quantity), 0) as units
  from public.order_items oi where oi.order_id = o.id
) u on true
where o.status <> 'cancelled';

-- ============================================================================
-- 7. daily_sales - the analytics time series
-- ============================================================================

create or replace view public.daily_sales
with (security_invoker = true) as
select
  o.order_date,
  count(*)                                as order_count,
  coalesce(sum(o.total), 0)               as revenue,
  coalesce(sum(o.cost), 0)                as cost,
  coalesce(sum(o.gross_profit), 0)        as gross_profit,
  coalesce(sum(o.amount_paid), 0)         as collected,
  coalesce(sum(u.units), 0)               as units_sold
from public.orders o
left join lateral (
  select coalesce(sum(oi.quantity), 0) as units
  from public.order_items oi where oi.order_id = o.id
) u on true
where o.status <> 'cancelled'
group by o.order_date
order by o.order_date desc;

-- ============================================================================
-- 8. product_sales - best sellers for the analytics page
-- ============================================================================

create or replace view public.product_sales
with (security_invoker = true) as
select
  p.id,
  p.name,
  p.category,
  coalesce(sum(oi.quantity), 0)     as units_sold,
  coalesce(sum(oi.line_revenue), 0) as revenue,
  coalesce(sum(oi.line_cost), 0)    as cost,
  coalesce(sum(oi.line_profit), 0)  as profit,
  count(distinct oi.order_id)       as order_count
from public.products p
left join public.order_items oi on oi.product_id = p.id
left join public.orders o       on o.id = oi.order_id and o.status <> 'cancelled'
group by p.id, p.name, p.category
order by units_sold desc;

-- ============================================================================
-- 9. Grants
-- ============================================================================

grant select on public.public_products to anon, authenticated;
grant select on public.order_details,
                public.inventory_status,
                public.customer_financials,
                public.officer_commission_summary,
                public.financial_summary,
                public.daily_sales,
                public.product_sales
  to authenticated;
