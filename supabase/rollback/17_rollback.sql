-- EFZ - rollback of 17_product_sales_exclude_cancelled.sql.
-- Restores public.product_sales EXACTLY as deployed by 11 (text taken verbatim from the sealed Production
-- backup 20261004-053354Z, public schema). That definition counts cancelled order items again (the bug 17 fixes).
-- Only the view changes; no data is touched. Safe to re-run: it refuses an unexpected definition and is a no-op
-- when the 11 definition is already in place. Post-check: definition md5 = 0fdaf7b0ce549cc4011731e1eac6e55a.
\set ON_ERROR_STOP on
begin;

do $pre$
declare
  v_def text;
begin
  select replace(definition, E'\r', '') into v_def from pg_views where schemaname = 'public' and viewname = 'product_sales';
  if v_def is null then
    raise exception '17 rollback: public.product_sales does not exist';
  elsif md5(v_def) = '0fdaf7b0ce549cc4011731e1eac6e55a' then
    raise notice '17 rollback: already the 11 definition - re-applying (no change)';
  elsif position('LEFT JOIN orders o ON' in v_def) = 0 and v_def ~ 'ov\.status <> ''cancelled''::order_status' then
    raise notice '17 rollback: restoring the 11 definition';
  else
    raise exception '17 rollback: unexpected product_sales definition (md5 %) - refusing', md5(v_def);
  end if;
end
$pre$;

CREATE OR REPLACE VIEW public.product_sales WITH (security_invoker='false', security_barrier='true') AS
 SELECT p.id,
    p.name,
    p.category,
    COALESCE(sum(oi.quantity), (0)::bigint) AS units_sold,
    COALESCE(sum(oi.line_revenue), (0)::numeric) AS revenue,
        CASE
            WHEN public.can_view_cost() THEN COALESCE(sum(oi.line_cost), (0)::numeric)
            ELSE NULL::numeric
        END AS cost,
        CASE
            WHEN public.can_view_cost() THEN COALESCE(sum(oi.line_profit), (0)::numeric)
            ELSE NULL::numeric
        END AS profit,
    count(DISTINCT oi.order_id) AS order_count
   FROM ((public.products p
     LEFT JOIN public.order_items oi ON (((oi.product_id = p.id) AND (EXISTS ( SELECT 1
           FROM public.orders ov
          WHERE ((ov.id = oi.order_id) AND public.can_see_customer_order(ov.customer_id, ov.marketing_officer_id)))))))
     LEFT JOIN public.orders o ON (((o.id = oi.order_id) AND (o.status <> 'cancelled'::public.order_status))))
  WHERE public.can_see_products()
  GROUP BY p.id, p.name, p.category
  ORDER BY COALESCE(sum(oi.quantity), (0)::bigint) DESC;

do $post$
begin
  if (select md5(replace(definition, E'\r', '')) from pg_views where schemaname = 'public' and viewname = 'product_sales')
     <> '0fdaf7b0ce549cc4011731e1eac6e55a' then
    raise exception '17 rollback: post-check failed - definition is not the 11 one';
  end if;
  raise notice '17 rollback: product_sales restored to the 11 definition';
end
$post$;

commit;
