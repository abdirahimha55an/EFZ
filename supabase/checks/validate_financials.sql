-- ============================================================================
-- EFZ - Financial & historical data validation (read-only)
-- ----------------------------------------------------------------------------
-- NOT a migration. One SELECT statement: it reads, it never writes, and it
-- creates nothing. Safe to run against production at any time.
--
-- Replaces scripts/validate-approved-historical-orders.ts, which validated
-- the localStorage import of 2026-09-01 and can no longer run. This checks
-- the Supabase source of truth instead, in three sections:
--
--   baseline   The seven parent orders approved in the 2026-09-01 historical
--              migration must still add up to the signed-off figures:
--              7 orders, 11 units, $119.00 revenue, $73.70 cost,
--              $45.30 gross profit, 38.07% margin - plus the per-product and
--              per-customer splits the old script asserted.
--   integrity  Every order, line item, payment, product, customer and
--              commission must agree with the rules the triggers enforce.
--   summary    Current totals, for the record (INFO only).
--
-- result: PASS / FAIL (must be fixed) / WARN (review) / INFO (figure only).
--
-- How to run
--   * Supabase SQL Editor: paste and run. Must be run as a role that can see
--     every row (the SQL Editor's postgres role does), or totals will be
--     filtered by RLS.
--   * psql, with the session forced read-only:
--       PGOPTIONS='-c default_transaction_read_only=on' \
--         psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/checks/validate_financials.sql
-- ============================================================================

with
-- ---------------------------------------------------------------------------
-- Baseline: the approved 2026-09-01 historical parent orders
-- ---------------------------------------------------------------------------
baseline_ids(id) as (
  values ('EFZ-SKY-24'), ('EFZ-SKY-26'), ('EFZ-DHIMBIL-TRIAL'), ('EFZ-DHIMBIL-REG'),
         ('EFZ-GOOBE-ONE'), ('EFZ-HAYAAN-ONE'), ('EFZ-ABD-ONE')
),
b_orders as (
  select o.* from public.orders o join baseline_ids b on b.id = o.id
),
b_items as (
  select oi.* from public.order_items oi join baseline_ids b on b.id = oi.order_id
),
b_tot as (
  select count(*)                                          as n,
         (select coalesce(sum(quantity), 0) from b_items)  as units,
         coalesce(sum(total), 0)::numeric(14,2)            as revenue,
         coalesce(sum(cost), 0)::numeric(14,2)             as cost,
         coalesce(sum(gross_profit), 0)::numeric(14,2)     as profit,
         count(*) filter (where status = 'cancelled')      as cancelled
    from b_orders
),
exp_prod(product_name, units, revenue) as (
  values ('EFZ - Nexus', 6, 65.50), ('EFZ - Fire Ball', 5, 53.50)
),
act_prod as (
  select product_name, sum(quantity) as units, sum(line_revenue)::numeric(14,2) as revenue
    from b_items group by product_name
),
-- Per-customer split, keyed by the approved order ids rather than by name so
-- no customer names live in the repository. Each group must still belong to
-- exactly one customer record.
exp_cust(sort, order_ids, n, units, revenue) as (
  values (1, array['EFZ-SKY-24', 'EFZ-SKY-26'],             2, 4, 40.00),
         (2, array['EFZ-DHIMBIL-TRIAL', 'EFZ-DHIMBIL-REG'],  2, 3, 32.00),
         (3, array['EFZ-GOOBE-ONE'],                         1, 2, 23.00),
         (4, array['EFZ-HAYAAN-ONE'],                        1, 1, 11.00),
         (5, array['EFZ-ABD-ONE'],                           1, 1, 13.00)
),
act_cust as (
  select e.sort,
         count(o.id)                                  as n,
         coalesce(sum(u.units), 0)                    as units,
         coalesce(sum(o.total), 0)::numeric(14,2)     as revenue,
         count(distinct o.customer_id)                as customers
    from exp_cust e
    left join public.orders o on o.id = any(e.order_ids)
    left join lateral (
      select sum(quantity) as units from public.order_items i where i.order_id = o.id
    ) u on true
   group by e.sort
),

-- ---------------------------------------------------------------------------
-- Integrity: every order recomputed from its own lines and payments
-- ---------------------------------------------------------------------------
recalc as (
  select o.id, o.status, o.payment_status, o.commission_paid,
         o.total, o.cost, o.gross_profit, o.amount_paid, o.outstanding_balance,
         coalesce(i.rev, 0)  as rev,
         coalesce(i.cst, 0)  as cst,
         coalesce(i.n, 0)    as n_items,
         coalesce(p.paid, 0) as paid
    from public.orders o
    left join (
      select order_id, sum(line_revenue) as rev, sum(line_cost) as cst, count(*) as n
        from public.order_items group by order_id
    ) i on i.order_id = o.id
    left join (
      select order_id, sum(amount) as paid from public.payments group by order_id
    ) p on p.order_id = o.id
),
recalc2 as (
  select r.*,
         least(r.paid, r.rev) as exp_paid,
         case
           when r.payment_status in ('refunded', 'credit') then r.payment_status::text
           when r.rev <= 0                    then 'paid'
           when least(r.paid, r.rev) <= 0     then 'unpaid'
           when least(r.paid, r.rev) >= r.rev then 'paid'
           else 'partial'
         end as exp_status
    from recalc r
),
legacy_children as (
  select o.id as parent_id, c.child_id
    from public.orders o, unnest(o.legacy_order_ids) as c(child_id)
),
live as (
  select * from recalc where status <> 'cancelled'
),

checks(sort, section, check_name, expected, actual, severity) as (
  -- ---- baseline -----------------------------------------------------------
  select 101, 'baseline', 'Approved parent orders present', '7', n::text, 'FAIL' from b_tot
  union all
  select 102, 'baseline', 'Units', '11', units::text, 'FAIL' from b_tot
  union all
  select 103, 'baseline', 'Revenue', '119.00', revenue::text, 'FAIL' from b_tot
  union all
  select 104, 'baseline', 'Cost', '73.70', cost::text, 'FAIL' from b_tot
  union all
  select 105, 'baseline', 'Gross profit', '45.30', profit::text, 'FAIL' from b_tot
  union all
  select 106, 'baseline', 'Gross margin %', '38.07',
         case when revenue > 0 then round(profit / revenue * 100, 2)::text else '0' end, 'FAIL'
    from b_tot
  union all
  select 107, 'baseline', 'Approved orders cancelled since', '0', cancelled::text, 'FAIL' from b_tot
  union all
  select 108, 'baseline', 'Merged child orders still present as separate orders (double count)', '0',
         (select count(*) from public.orders o
           where o.id in (select unnest(legacy_order_ids) from b_orders))::text, 'FAIL'
  union all
  select 110, 'baseline', 'Product: ' || coalesce(e.product_name, a.product_name),
         coalesce(e.units || ' units, ' || e.revenue::numeric(14,2), 'none'),
         coalesce(a.units || ' units, ' || a.revenue, 'none'), 'FAIL'
    from exp_prod e full join act_prod a on a.product_name = e.product_name
  union all
  select 120 + e.sort, 'baseline', 'Customer of ' || array_to_string(e.order_ids, ' + '),
         e.n || ' orders, ' || e.units || ' units, ' || e.revenue::numeric(14,2) || ', 1 customer',
         a.n || ' orders, ' || a.units || ' units, ' || a.revenue || ', ' || a.customers || ' customer'
           || case when a.customers = 1 then '' else 's' end,
         'FAIL'
    from exp_cust e join act_cust a on a.sort = e.sort

  -- ---- integrity: orders ---------------------------------------------------
  union all
  select 201, 'integrity', 'Orders whose total differs from their line items', '0',
         count(*) filter (where abs(total - rev) > 0.005)::text, 'FAIL' from recalc
  union all
  select 202, 'integrity', 'Orders whose cost differs from their line items', '0',
         count(*) filter (where abs(cost - cst) > 0.005)::text, 'FAIL' from recalc
  union all
  select 203, 'integrity', 'Orders whose gross profit is not total - cost', '0',
         count(*) filter (where abs(gross_profit - (total - cost)) > 0.005)::text, 'FAIL' from recalc
  union all
  select 204, 'integrity', 'Orders whose amount paid differs from their payments', '0',
         count(*) filter (where abs(amount_paid - exp_paid) > 0.005)::text, 'FAIL' from recalc2
  union all
  select 205, 'integrity', 'Orders whose outstanding balance is not total - paid', '0',
         count(*) filter (where abs(outstanding_balance - greatest(total - amount_paid, 0)) > 0.005)::text, 'FAIL'
    from recalc
  union all
  select 206, 'integrity', 'Orders whose payment status disagrees with their payments', '0',
         count(*) filter (where payment_status::text <> exp_status)::text, 'FAIL' from recalc2
  union all
  select 207, 'integrity', 'Orders paid more than their total', '0',
         count(*) filter (where paid > rev + 0.005)::text, 'FAIL' from recalc
  union all
  select 208, 'integrity', 'Orders with no line items', '0',
         count(*) filter (where n_items = 0)::text, 'FAIL' from recalc
  union all
  select 209, 'integrity', 'Order ids merged into more than one parent, or also present as an order', '0',
         (select count(distinct child_id) from legacy_children lc
           where exists (select 1 from public.orders o where o.id = lc.child_id)
              or (select count(*) from legacy_children x where x.child_id = lc.child_id) > 1)::text,
         'FAIL'
  union all
  select 210, 'integrity', 'Delivered orders with an outstanding balance', '0',
         count(*) filter (where status = 'delivered' and outstanding_balance > 0)::text, 'WARN' from recalc

  -- ---- integrity: line items, products, customers, commissions -------------
  union all
  select 220, 'integrity', 'Line items whose product no longer exists', '0',
         count(*) filter (where product_id is null)::text, 'WARN' from public.order_items
  union all
  select 221, 'integrity', 'Line items with no cost recorded (profit overstated)', '0',
         count(*) filter (where historical_unit_cost = 0)::text, 'WARN' from public.order_items
  union all
  select 222, 'integrity', 'Line items sold below their recorded cost', '0',
         count(*) filter (where actual_unit_price < historical_unit_cost)::text, 'WARN' from public.order_items
  union all
  select 230, 'integrity', 'Active products priced below cost', '0',
         count(*) filter (where is_active and selling_price < cost_price)::text, 'WARN' from public.products
  union all
  select 231, 'integrity', 'Products whose stock differs from their movement ledger', '0',
         (select count(*) from public.products p
           where p.stock <> coalesce((select sum(m.quantity_change) from public.stock_movements m
                                        where m.product_id = p.id), 0))::text,
         'INFO'
  union all
  select 240, 'integrity', 'Orders with no linked customer', '0',
         count(*) filter (where customer_id is null)::text, 'WARN' from public.orders
  union all
  select 241, 'integrity', 'Orders whose customer is archived', '0',
         (select count(*) from public.orders o join public.customers c on c.id = o.customer_id
           where c.status = 'archived')::text, 'INFO'
  union all
  select 242, 'integrity', 'Active customers sharing a phone number', '0',
         (select count(*) from (
            select phone from public.customers
             where status = 'active' and phone <> ''
             group by phone having count(*) > 1) d)::text, 'WARN'
  union all
  select 250, 'integrity', 'Profiles whose commission totals differ from the ledger', '0',
         (select count(*) from public.profiles p
           where abs(p.earned_commission_total - coalesce((
                   select sum(c.amount) from public.commissions c
                    where c.user_id = p.id and c.status in ('pending', 'approved', 'paid')), 0)) > 0.005
              or abs(p.paid_commission_total - coalesce((
                   select sum(c.amount) from public.commissions c
                    where c.user_id = p.id and c.status = 'paid'), 0)) > 0.005)::text,
         'FAIL'
  union all
  select 251, 'integrity', 'Orders whose commission_paid flag disagrees with the ledger', '0',
         count(*) filter (where commission_paid <> exists (
           select 1 from public.commissions c where c.order_id = recalc.id and c.status = 'paid'))::text,
         'FAIL'
    from recalc

  -- ---- summary (non-cancelled orders, same basis as financial_summary) -----
  union all
  select 301, 'summary', 'Orders (excluding cancelled)', '', count(*)::text, 'INFO' from live
  union all
  select 302, 'summary', 'Units', '',
         (select coalesce(sum(oi.quantity), 0) from public.order_items oi
            join live l on l.id = oi.order_id)::text, 'INFO'
  union all
  select 303, 'summary', 'Revenue', '', coalesce(sum(total), 0)::numeric(14,2)::text, 'INFO' from live
  union all
  select 304, 'summary', 'Cost', '', coalesce(sum(cost), 0)::numeric(14,2)::text, 'INFO' from live
  union all
  select 305, 'summary', 'Gross profit', '', coalesce(sum(gross_profit), 0)::numeric(14,2)::text, 'INFO' from live
  union all
  select 306, 'summary', 'Gross margin %', '',
         case when sum(total) > 0 then round(sum(gross_profit) / sum(total) * 100, 2)::text else '0' end,
         'INFO' from live
  union all
  select 307, 'summary', 'Cash collected', '', coalesce(sum(amount_paid), 0)::numeric(14,2)::text, 'INFO' from live
  union all
  select 308, 'summary', 'Outstanding receivables', '',
         coalesce(sum(outstanding_balance), 0)::numeric(14,2)::text, 'INFO' from live
  union all
  select 309, 'summary', 'Cancelled orders', '',
         count(*) filter (where status = 'cancelled')::text, 'INFO' from recalc
)
select section,
       check_name,
       expected,
       actual,
       case
         when severity = 'INFO'  then 'INFO'
         when expected = actual  then 'PASS'
         else severity
       end as result
  from checks
 order by sort, check_name;
