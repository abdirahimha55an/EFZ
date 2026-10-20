-- =============================================================================
-- 29c. order_details gains dispatched_at (appended as the LAST column; every existing column keeps its name, type and position)
-- The Hub reads orders through this view. It has no dependent views; privileges are kept by CREATE OR REPLACE. Run after 29b.
-- ROLLBACK: supabase/rollback/29_dispatch_rollback.sql (drops and recreates the view as it was, with the same grants)
-- =============================================================================
begin;
do $pre$
begin
  if md5(pg_get_viewdef('public.order_details'::regclass, true)) is distinct from '005da524de6ede9a11ec010a2d98c74d' then
    raise exception 'order_details is not the expected definition; refusing to replace it';
  end if;
end
$pre$;

create or replace view public.order_details with (security_barrier = true, security_invoker = false) as
 SELECT o.id,
    o.customer_id,
    o.customer_name,
    o.phone,
    o.marketing_officer_id,
    mo.name AS marketing_officer_name,
    o.status,
    o.payment_status,
    o.order_type,
    o.order_date,
    o.delivery_notes,
    o.total,
        CASE
            WHEN v.cost_ok THEN o.cost
            ELSE NULL::numeric
        END::numeric(14,2) AS cost,
        CASE
            WHEN v.cost_ok THEN o.gross_profit
            ELSE NULL::numeric
        END::numeric(14,2) AS gross_profit,
    o.amount_paid,
    o.outstanding_balance,
    o.commission_paid,
    o.legacy_order_ids,
    o.legacy_reference_id,
    o.created_at,
    o.updated_at,
    COALESCE(i.items, '[]'::jsonb) AS items,
    COALESCE(pay.payments, '[]'::jsonb) AS payments,
    COALESCE(i.unit_count, 0::bigint) AS unit_count,
    o.delivered_at,
    o.confirmed_at,
    o.stock_mode,
    cc.model AS commission_model,
    o.dispatched_at
   FROM orders o
     LEFT JOIN order_commission_class cc ON cc.order_id = o.id
     CROSS JOIN LATERAL ( SELECT can_view_cost() AS cost_ok) v
     LEFT JOIN profiles mo ON mo.id = o.marketing_officer_id
     LEFT JOIN LATERAL ( SELECT jsonb_agg(jsonb_build_object('id', oi.id, 'productId', oi.product_id, 'productName', oi.product_name, 'designName', oi.design_name, 'quantity', oi.quantity, 'standardUnitPrice', oi.standard_unit_price, 'actualUnitPrice', oi.actual_unit_price, 'price', oi.actual_unit_price, 'historicalUnitCost',
                CASE
                    WHEN v.cost_ok THEN oi.historical_unit_cost
                    ELSE NULL::numeric
                END, 'costPrice',
                CASE
                    WHEN v.cost_ok THEN oi.historical_unit_cost
                    ELSE NULL::numeric
                END, 'lineRevenue', oi.line_revenue, 'lineCost',
                CASE
                    WHEN v.cost_ok THEN oi.line_cost
                    ELSE NULL::numeric
                END, 'lineProfit',
                CASE
                    WHEN v.cost_ok THEN oi.line_profit
                    ELSE NULL::numeric
                END, 'deliveredQuantity', dq.delivered, 'remainingQuantity', GREATEST(oi.quantity - dq.delivered, 0)) ORDER BY oi.created_at, oi.id) AS items,
            sum(oi.quantity) AS unit_count
           FROM order_items oi
             CROSS JOIN LATERAL ( SELECT (COALESCE(( SELECT sum(l.quantity) AS sum
                           FROM order_delivery_lines l
                          WHERE l.order_item_id = oi.id), 0::bigint) + COALESCE(( SELECT sum(a.delta) AS sum
                           FROM delivered_quantity_adjustments a
                          WHERE a.order_item_id = oi.id), 0::bigint))::integer AS delivered) dq
          WHERE oi.order_id = o.id) i ON true
     LEFT JOIN LATERAL ( SELECT jsonb_agg(jsonb_build_object('id', pm.id, 'orderId', pm.order_id, 'amount', pm.amount, 'paymentDate', pm.payment_date, 'paymentMethod', pm.payment_method, 'reference', pm.reference, 'notes', pm.notes, 'recordedBy', pm.recorded_by, 'createdAt', pm.created_at) ORDER BY pm.payment_date, pm.created_at) AS payments
           FROM payments pm
          WHERE pm.order_id = o.id) pay ON true
  WHERE can_see_customer_order(o.customer_id, o.marketing_officer_id);

commit;
