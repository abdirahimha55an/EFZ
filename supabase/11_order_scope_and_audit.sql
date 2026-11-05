-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 11 : Order scope for Marketing Officers, cost-free below-cost errors,
--           database-side audit trail (2026-10-01)
-- ----------------------------------------------------------------------------
-- Run AFTER 01..05, 07, 08, 09 and 10. Idempotent: safe to re-run. Atomic:
-- one explicit transaction (see "ATOMIC" below).
-- Apply to EFZ-Staging (adjjamiqwboawqedaapi) first; run
-- staging/staging_preflight_11.sql there before it.
--
-- It adds one nullable column (with a check constraint), five helper
-- functions, two audit triggers with their two functions, and a column-level
-- SELECT grant on profiles; it replaces six functions, five views and five
-- policies, and restates one trigger. Every replaced view keeps its exact
-- columns. It does not UPDATE, DELETE or re-compute any
-- existing row: every order, payment, commission, stock figure and audit line
-- stays exactly as it is (existing audit lines keep origin = NULL, "written
-- before 11"). The commission formula is NOT changed here.
--
-- Fixes from the 2026-10-01 Phase 4 validation:
--
--   1. Below-cost disclosure. create_order told a caller who may not see cost
--      "... is below its cost of 6.70". The refusal now names the cost only to
--      callers who may see it (view_inventory / view_reports, as everywhere
--      else). The Super Admin approval path is unchanged.
--
--   2. Order scope. view_orders meant "every order", and the Marketing Officer
--      preset holds it, so through the API an officer could read every order
--      (and its payments and lines) and record payments against other
--      officers' orders. Decisions 2026-10-01:
--        * a Marketing Officer may only see and take payments on orders of
--          customers CURRENTLY assigned to them;
--        * after a transfer the new officer sees the customer's whole order
--          history (including orders taken by the previous officer) and the
--          previous officer sees none of it.
--      Rule (can_access_order(customer, officer)): Super Admin; or view_orders
--      WITHOUT view_own_customers_only (Manager, Customer Service, Delivery,
--      Inventory); or the order's customer is currently assigned to the caller.
--      An order with no customer (legacy) falls back to the order's officer.
--      Enforced in the orders_select policy (and so in order_items / payments,
--      whose policies read orders), in can_see_customer_order (used by
--      order_details, inventory_status, financial_summary, daily_sales,
--      product_sales), and in record_payment and update_order_status.
--      create_order: an officer may order only for a customer currently
--      assigned to them (having registered it no longer counts).
--      orders.marketing_officer_id is unchanged: it still records whose
--      commission an order earned.
--
--   3. Audit trail written by the database. Payments, order creation, stock
--      adjustments, customer registration and commission changes now write
--      their audit line inside the same transaction as the change, so the line
--      exists exactly when the change does. system_logs.origin records who
--      wrote a line: 'database' (a function or trigger) or 'client' (a direct
--      insert from the browser/API). Clients cannot choose it. The browser's
--      own copies of the five events above are skipped (no duplicates), and a
--      client line imitating a database-only event is refused.
--
--   4. Commission visibility. view_commissions meant "every officer's
--      commissions", and the Marketing Officer preset holds it. Decision
--      2026-10-01: an officer sees only their own commissions; management sees
--      everyone's. Rule (can_view_all_commissions): Super Admin, or
--      view_commissions WITHOUT view_own_customers_only (Manager). Enforced in
--      commissions_select and commission_payouts_select (and so in
--      officer_commission_summary, a security-invoker view). The running
--      totals stored on profiles (earned/pending/paid_commission_total) were
--      readable by every active staff member: those three columns are no
--      longer selectable through the API at all (REQUIRES the matching Phase 4
--      app change, which stops selecting them). An officer also no longer
--      sees other Marketing Officers' profile rows, nor customer ownership
--      transfers they were not part of (view_commissions used to open them
--      all). Calculation, payout, cancellation and audit behaviour are
--      unchanged.
--
-- Documented, unchanged: the officer who registered a customer can still read
-- that customer's record after a transfer (see the end of this file).
--
-- "Trusted" callers (auth.uid() IS NULL: SQL editor, imports) keep 10's rules.
-- The customer and commission triggers do not log their writes, so bulk
-- imports do not flood the audit trail.
--
-- Rollback: supabase/rollback/11_rollback.sql restores every function, view
-- and policy exactly as 02/03/08/10 define them and drops the triggers and
-- helpers. system_logs.origin is left in place (it labels audit records).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- ATOMIC: everything below runs in ONE explicit transaction (begin ... commit).
--  * Supabase SQL Editor (the whole file is sent as one request): if any
--    statement fails, PostgreSQL skips the rest of the file and nothing is
--    committed. The failed transaction may stay open in that editor session:
--    run   rollback;   once before anything else (harmless if none is open).
--  * Clients that send statements one at a time (e.g. psql -f): after a
--    failure every later statement is refused, and the final COMMIT is turned
--    into a ROLLBACK by PostgreSQL.
--  * If a transaction is already open, BEGIN only warns and COMMIT ends it.
--  Nothing in this file is disallowed inside a transaction block (no
--  CONCURRENTLY, VACUUM or ALTER TYPE ... ADD VALUE).
-- ----------------------------------------------------------------------------
begin;

-- ============================================================================
-- 1. AUDIT ORIGIN
-- ============================================================================

alter table public.system_logs add column if not exists origin text;

alter table public.system_logs drop constraint if exists system_logs_origin_check;
alter table public.system_logs add constraint system_logs_origin_check
  check (origin is null or origin in ('database', 'client'));

comment on column public.system_logs.origin is
  'Who wrote the line: database (a function or trigger, trusted) or client (a direct insert from a signed-in user). NULL for lines written before migration 11.';

-- Direct client inserts: the actor and time come from the session (as in 08),
-- the origin is always 'client', the browser's copy of an event the database
-- now records itself is skipped, and a line imitating a database-only event
-- is refused. Lines written inside SECURITY DEFINER functions are 'database'.
create or replace function public.guard_system_logs_insert()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if public.is_client_request() then
    if (new.category = 'ORDER'     and new.message like 'New order created: %')
       or (new.category = 'FINANCIAL' and new.message like 'Payment of $%')
       or (new.category = 'CUSTOMER'  and new.message like 'New customer registered: %')
       or (new.category = 'INVENTORY' and new.message ~ '^Stock (increased|decreased) for ') then
      return null;  -- recorded by the database in the same transaction as the event
    end if;

    if new.message ~ '^(Order \S+ status changed from |Below-cost sale approved |Customer .+ transferred from |Order \S+ created with a past date |Order \S+: requested marketing officer |Payment of \S+ on order |Commission created for order |Commission for order )' then
      raise exception 'This kind of audit line is written by the database only'
        using errcode = '42501';
    end if;

    new.user_id     := public.current_profile_id();
    new.username    := coalesce(public.current_profile_name(), '');
    new.occurred_at := now();
    new.origin      := 'client';
  else
    new.origin      := 'database';
  end if;
  return new;
end;
$fn$;

-- (trg_system_logs_guard from 08 already calls this function; restated so
-- this file stands alone.)
drop trigger if exists trg_system_logs_guard on public.system_logs;
create trigger trg_system_logs_guard
  before insert on public.system_logs
  for each row execute function public.guard_system_logs_insert();

-- ============================================================================
-- 2. ORDER SCOPE
-- ============================================================================

-- An own-customers-only caller (the Marketing Officer preset). has_permission()
-- is true for every code for a Super Admin, including view_own_customers_only,
-- hence the explicit Super Admin exclusion.
create or replace function public.is_own_customers_caller()
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select not public.is_super_admin()
     and public.has_permission('view_own_customers_only');
$fn$;

-- Sees every order (management and operations roles).
create or replace function public.has_all_order_scope()
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select public.is_super_admin()
      or (public.has_permission('view_orders') and not public.is_own_customers_caller());
$fn$;

-- The caller may see / act on an order of p_customer_id (owned by p_officer_id
-- when it has no customer). Follows the customer's CURRENT officer, so a
-- transfer moves the whole order history. SECURITY DEFINER so it reads the
-- customer's assignment without depending on the caller's customers RLS, and
-- unlike can_see_customer_order it does not short-circuit on "not a client
-- request", so SECURITY DEFINER functions can call it for the real caller.
create or replace function public.can_access_order(p_customer_id text, p_officer_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select public.has_all_order_scope()
      or case
           when p_customer_id is not null then exists (
             select 1 from public.customers c
              where c.id = p_customer_id
                and c.marketing_officer_id = public.current_profile_id())
           else coalesce(p_officer_id = public.current_profile_id(), false)
         end;
$fn$;

-- Mirrors the orders_select policy below. The owner-rights views filter with
-- this, so it must stay identical to that policy.
create or replace function public.can_see_customer_order(p_customer_id text, p_officer_id text)
returns boolean
language sql
stable
set search_path = public
as $fn$
  select not public.is_client_request()
      or public.can_access_order(p_customer_id, p_officer_id);
$fn$;

-- 10's one-argument helper cannot know the customer. Nothing in 11 calls it;
-- it is kept (an older caller would still resolve) but grants only the
-- management scope, never per-officer access by the order's old officer.
create or replace function public.can_see_order(p_officer_id text)
returns boolean
language sql
stable
set search_path = public
as $fn$
  select not public.is_client_request()
      or public.has_all_order_scope();
$fn$;

-- An earlier, never-applied draft of 11 had can_access_order(text).
drop function if exists public.can_access_order(text);

revoke all on function public.is_own_customers_caller()                from public, anon;
revoke all on function public.has_all_order_scope()                    from public, anon;
revoke all on function public.can_access_order(text, text)             from public, anon;
revoke all on function public.can_see_customer_order(text, text)       from public, anon;
grant execute on function public.is_own_customers_caller()             to authenticated;
grant execute on function public.has_all_order_scope()                 to authenticated;
grant execute on function public.can_access_order(text, text)          to authenticated;
grant execute on function public.can_see_customer_order(text, text)    to authenticated;

drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders
  for select to authenticated
  using (public.can_access_order(customer_id, marketing_officer_id));

-- The owner-rights reporting views from 10, unchanged except that each now
-- filters orders with can_see_customer_order(customer, officer).

create or replace view public.order_details
with (security_invoker = false, security_barrier = true) as
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
  (case when v.cost_ok then o.cost end)::numeric(14,2)         as cost,
  (case when v.cost_ok then o.gross_profit end)::numeric(14,2) as gross_profit,
  o.amount_paid,
  o.outstanding_balance,
  o.commission_paid,
  o.legacy_order_ids,
  o.legacy_reference_id,
  o.created_at,
  o.updated_at,
  coalesce(i.items,    '[]'::jsonb) as items,
  coalesce(pay.payments, '[]'::jsonb) as payments,
  coalesce(i.unit_count, 0) as unit_count,
  o.delivered_at
from public.orders o
cross join lateral (select public.can_view_cost() as cost_ok) v
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
        'historicalUnitCost', case when v.cost_ok then oi.historical_unit_cost end,
        'costPrice',          case when v.cost_ok then oi.historical_unit_cost end,
        'lineRevenue',        oi.line_revenue,
        'lineCost',           case when v.cost_ok then oi.line_cost end,
        'lineProfit',         case when v.cost_ok then oi.line_profit end
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
) pay on true
where public.can_see_customer_order(o.customer_id, o.marketing_officer_id);

create or replace view public.inventory_status
with (security_invoker = false, security_barrier = true) as
select
  p.id,
  p.name,
  p.category,
  p.stock,
  p.low_stock_threshold,
  (case when v.cost_ok then p.cost_price end)::numeric(12,2) as cost_price,
  p.selling_price,
  (case when v.cost_ok then p.selling_price - p.cost_price end)::numeric as unit_margin,
  (case
     when not v.cost_ok then null
     when p.selling_price > 0
     then round((p.selling_price - p.cost_price) / p.selling_price * 100, 2)
     else 0
   end)::numeric as margin_percentage,
  (case when v.cost_ok then p.stock * p.cost_price end)::numeric as stock_value_at_cost,
  case
    when p.stock <= 0                       then 'out_of_stock'
    when p.stock <= p.low_stock_threshold   then 'low_stock'
    else 'healthy'
  end as stock_state,
  coalesce(sold.units_sold, 0) as units_sold,
  p.is_active
from public.products p
cross join lateral (select public.can_view_cost() as cost_ok) v
left join lateral (
  select sum(oi.quantity) as units_sold
  from public.order_items oi
  join public.orders o on o.id = oi.order_id
  where oi.product_id = p.id
    and o.status <> 'cancelled'
    and public.can_see_customer_order(o.customer_id, o.marketing_officer_id)
) sold on true
where public.can_see_products();

create or replace view public.financial_summary
with (security_invoker = false, security_barrier = true) as
select
  count(*)                                        as total_orders,
  coalesce(sum(o.total), 0)                       as revenue_generated,
  (case when public.can_view_cost() then coalesce(sum(o.cost), 0) end)::numeric         as total_cost,
  (case when public.can_view_cost() then coalesce(sum(o.gross_profit), 0) end)::numeric as gross_profit,
  coalesce(sum(o.amount_paid), 0)                 as cash_collected,
  coalesce(sum(o.outstanding_balance), 0)         as outstanding_receivables,
  coalesce(sum(u.units), 0)                       as total_units,
  (case
     when not public.can_view_cost() then null
     when coalesce(sum(o.total), 0) > 0
     then round(coalesce(sum(o.gross_profit), 0) / sum(o.total) * 100, 2)
     else 0
   end)::numeric                                  as gross_margin
from public.orders o
left join lateral (
  select coalesce(sum(oi.quantity), 0) as units
  from public.order_items oi where oi.order_id = o.id
) u on true
where o.status <> 'cancelled'
  and public.can_see_customer_order(o.customer_id, o.marketing_officer_id);

create or replace view public.daily_sales
with (security_invoker = false, security_barrier = true) as
select
  o.order_date,
  count(*)                                as order_count,
  coalesce(sum(o.total), 0)               as revenue,
  (case when public.can_view_cost() then coalesce(sum(o.cost), 0) end)::numeric         as cost,
  (case when public.can_view_cost() then coalesce(sum(o.gross_profit), 0) end)::numeric as gross_profit,
  coalesce(sum(o.amount_paid), 0)         as collected,
  coalesce(sum(u.units), 0)               as units_sold
from public.orders o
left join lateral (
  select coalesce(sum(oi.quantity), 0) as units
  from public.order_items oi where oi.order_id = o.id
) u on true
where o.status <> 'cancelled'
  and public.can_see_customer_order(o.customer_id, o.marketing_officer_id)
group by o.order_date
order by o.order_date desc;

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
                and public.can_see_customer_order(ov.customer_id, ov.marketing_officer_id))
left join public.orders o       on o.id = oi.order_id and o.status <> 'cancelled'
where public.can_see_products()
group by p.id, p.name, p.category
order by units_sold desc;

-- ============================================================================
-- 3. create_order - cost-free refusal, audit line
-- ============================================================================

create or replace function public.create_order(payload jsonb)
returns text
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_order_id     text;
  v_actor        text    := public.current_profile_id();
  v_actor_name   text    := coalesce(public.current_profile_name(), '');
  v_elevated     boolean := public.is_elevated_caller();
  v_today        date    := public.efz_today();
  v_customer     public.customers%rowtype;
  v_customer_id  text;
  v_requested    text;
  v_status       text;
  v_date         date;
  v_reason       text;
  v_item         jsonb;
  v_product      public.products%rowtype;
  v_qty_raw      numeric;
  v_qty          integer;
  v_actual       numeric(12,2);
  v_item_id      text;
  v_seq          integer := 0;
begin
  perform public.require_permission('create_orders');

  if payload is null
     or jsonb_typeof(payload -> 'items') is distinct from 'array'
     or jsonb_array_length(payload -> 'items') = 0 then
    raise exception 'Order must contain at least one item';
  end if;

  v_status := coalesce(nullif(payload ->> 'status', ''), 'pending');
  if v_status <> 'pending' then
    raise exception 'Orders are always created as pending; move them forward with update_order_status()'
      using errcode = '42501';
  end if;

  v_order_id := nullif(btrim(coalesce(payload ->> 'id', '')), '');
  if v_order_id is not null and not v_elevated then
    raise exception 'Only a Super Admin can choose an order id'
      using errcode = '42501';
  end if;

  if v_order_id is null then
    loop
      v_order_id := 'ORD-' || lpad((floor(random() * 9000000) + 1000000)::text, 7, '0');
      exit when not exists (select 1 from public.orders where id = v_order_id);
    end loop;
  end if;

  -- The customer decides who owns the commission.
  v_customer_id := nullif(btrim(coalesce(payload ->> 'customerId', '')), '');
  if v_customer_id is null then
    raise exception 'An order must belong to a customer';
  end if;

  select * into v_customer from public.customers where id = v_customer_id;

  -- 11: an officer limited to their own customers may order only for a
  -- customer CURRENTLY assigned to them. Having registered a customer that
  -- has since been transferred to another officer no longer counts.
  if not found
     or (auth.uid() is not null
         and not public.has_permission('view_all_customers')
         and not public.has_permission('view_customers')
         and v_customer.marketing_officer_id is distinct from v_actor) then
    raise exception 'Unknown customer: %', v_customer_id;
  end if;

  v_requested := nullif(btrim(coalesce(payload ->> 'marketingOfficerId', '')), '');

  v_date := coalesce(nullif(payload ->> 'orderDate', '')::date, v_today);
  if v_date > v_today then
    raise exception 'An order cannot be dated in the future (%)', v_date;
  end if;
  if v_date < v_today and not v_elevated then
    raise exception 'Only a Super Admin can create an order dated before today (%)', v_date
      using errcode = '42501';
  end if;

  v_reason := nullif(btrim(coalesce(payload ->> 'belowCostReason', '')), '');

  insert into public.orders (
    id, customer_id, customer_name, phone, marketing_officer_id,
    status, order_type, order_date, delivery_notes, created_by, legacy_reference_id
  )
  values (
    v_order_id,
    v_customer.id,
    coalesce(nullif(payload ->> 'customerName', ''), v_customer.name, ''),
    coalesce(nullif(payload ->> 'phone', ''), v_customer.phone, ''),
    v_customer.marketing_officer_id,
    'pending',
    coalesce(nullif(payload ->> 'orderType', ''), 'regular')::public.order_type,
    v_date,
    coalesce(payload ->> 'deliveryNotes', ''),
    v_actor,
    v_order_id
  );

  for v_item in select * from jsonb_array_elements(payload -> 'items')
  loop
    v_seq := v_seq + 1;

    select * into v_product
      from public.products
     where id = v_item ->> 'productId'
     for update;

    if not found then
      raise exception 'Unknown product: %', v_item ->> 'productId';
    end if;

    v_qty_raw := coalesce((v_item ->> 'quantity')::numeric, 1);
    if v_qty_raw < 1 or v_qty_raw <> trunc(v_qty_raw) then
      raise exception 'Quantity for % must be a whole number of at least 1 (got %)',
        v_product.name, v_qty_raw;
    end if;
    v_qty := v_qty_raw::integer;

    if v_product.stock < v_qty then
      raise exception 'Insufficient stock for %: % in stock, % requested',
        v_product.name, v_product.stock, v_qty;
    end if;

    v_actual := coalesce((v_item ->> 'actualUnitPrice')::numeric, v_product.selling_price);
    if v_actual < 0 then
      raise exception 'Price for % cannot be negative', v_product.name;
    end if;

    if v_actual < v_product.cost_price then
      if not v_elevated then
        -- 11: name the cost only to a caller allowed to see it (the rule of
        -- can_view_cost(), which cannot be called here: inside a SECURITY
        -- DEFINER function it would always say yes).
        if public.has_any_permission(array['view_inventory', 'view_reports']) then
          raise exception 'Price % for % is below its cost of %. Only a Super Admin can approve a below-cost sale.',
            v_actual, v_product.name, v_product.cost_price
            using errcode = '42501';
        end if;
        raise exception 'Price % for % is below the product''s cost. Only a Super Admin can approve a below-cost sale.',
          v_actual, v_product.name
          using errcode = '42501';
      end if;
      if v_reason is null then
        raise exception 'Price % for % is below its cost of %. A below-cost sale needs a belowCostReason.',
          v_actual, v_product.name, v_product.cost_price;
      end if;
    end if;

    v_item_id := 'itm-' || replace(gen_random_uuid()::text, '-', '') || '-' || v_seq;

    insert into public.order_items (
      id, order_id, product_id, product_name, design_name, quantity,
      standard_unit_price, actual_unit_price, historical_unit_cost
    )
    values (
      v_item_id,
      v_order_id,
      v_product.id,
      v_product.name,
      coalesce(nullif(v_item ->> 'designName', ''), v_product.name),
      v_qty,
      v_product.selling_price,   -- list price at the time of sale, never caller-supplied
      v_actual,
      v_product.cost_price       -- frozen cost snapshot
    );

    if v_actual < v_product.cost_price then
      insert into public.below_cost_overrides (
        order_id, order_item_id, product_id, product_name, quantity,
        selling_price, unit_cost, line_margin, margin_percentage,
        reason, approved_by, approved_by_name
      )
      values (
        v_order_id, v_item_id, v_product.id, v_product.name, v_qty,
        v_actual, v_product.cost_price,
        (v_actual - v_product.cost_price) * v_qty,
        case when v_actual > 0
             then round((v_actual - v_product.cost_price) / v_actual * 100, 2) end,
        v_reason, v_actor, v_actor_name
      );

      insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
      values (
        'log-' || replace(gen_random_uuid()::text, '-', ''),
        'WARNING', 'FINANCIAL',
        format('Below-cost sale approved on order %s: %s x %s at %s (cost %s)',
               v_order_id, v_qty, v_product.name, v_actual, v_product.cost_price),
        v_actor, v_actor_name, v_order_id,
        jsonb_build_object(
          'source', 'db', 'event', 'below_cost_override',
          'productId', v_product.id, 'quantity', v_qty,
          'sellingPrice', v_actual, 'unitCost', v_product.cost_price,
          'lineMargin', (v_actual - v_product.cost_price) * v_qty,
          'reason', v_reason)
      );
    end if;

    update public.products
       set stock = stock - v_qty
     where id = v_product.id;

    insert into public.stock_movements (
      id, product_id, product_name, type, quantity_change, reason, created_by
    )
    values (
      'mv-' || replace(gen_random_uuid()::text, '-', ''),
      v_product.id,
      v_product.name,
      'sale',
      -v_qty,
      'Order ' || v_order_id || ' created',
      v_actor
    );
  end loop;

  if v_date < v_today then
    insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
    values (
      'log-' || replace(gen_random_uuid()::text, '-', ''),
      'WARNING', 'ORDER',
      format('Order %s created with a past date %s (created on %s)', v_order_id, v_date, v_today),
      v_actor, v_actor_name, v_order_id,
      jsonb_build_object('source', 'db', 'event', 'backdated_order',
                         'orderDate', v_date, 'createdOn', v_today)
    );
  end if;

  if v_requested is not null and v_requested is distinct from v_customer.marketing_officer_id then
    insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
    values (
      'log-' || replace(gen_random_uuid()::text, '-', ''),
      'WARNING', 'ORDER',
      format('Order %s: requested marketing officer %s ignored; the customer''s officer %s was used',
             v_order_id, v_requested, coalesce(v_customer.marketing_officer_id, '(none)')),
      v_actor, v_actor_name, v_order_id,
      jsonb_build_object('source', 'db', 'event', 'officer_override_ignored',
                         'requested', v_requested, 'applied', v_customer.marketing_officer_id)
    );
  end if;

  -- 11: the order's audit line is written here, in the same transaction, so
  -- an order can never exist without one and a failed order leaves none.
  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  select
    'log-' || replace(gen_random_uuid()::text, '-', ''),
    'INFO', 'ORDER',
    format('New order created: %s for %s ($%s)', o.id, o.customer_name, o.total),
    v_actor, v_actor_name, o.id,
    jsonb_build_object('source', 'db', 'event', 'order_created',
                       'total', o.total, 'items', v_seq, 'orderType', o.order_type,
                       'orderDate', o.order_date, 'marketingOfficerId', o.marketing_officer_id)
    from public.orders o
   where o.id = v_order_id;

  return v_order_id;
end;
$fn$;

-- ============================================================================
-- 4. update_order_status - same order scope
-- ============================================================================

create or replace function public.update_order_status(
  p_order_id text,
  p_status   public.order_status,
  p_reason   text default ''
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_order    public.orders%rowtype;
  v_allowed  public.order_status[];
  v_actor    text    := public.current_profile_id();
  v_elevated boolean := public.is_elevated_caller();
  v_reason   text    := nullif(btrim(coalesce(p_reason, '')), '');
  v_override boolean := false;
  v_locked   boolean;
  v_item     record;
begin
  perform public.require_permission('edit_orders');

  select * into v_order
    from public.orders
   where id = p_order_id
   for update;

  if not found
     or (auth.uid() is not null
         and not public.can_access_order(v_order.customer_id, v_order.marketing_officer_id)) then
    raise exception 'Unknown order: %', p_order_id;
  end if;

  if v_order.status = p_status then
    return;
  end if;

  v_allowed := case v_order.status
    when 'pending'    then array['confirmed', 'cancelled']::public.order_status[]
    when 'confirmed'  then array['processing', 'cancelled']::public.order_status[]
    when 'processing' then array['delivered', 'cancelled']::public.order_status[]
    when 'delivered'  then array[]::public.order_status[]
    when 'cancelled'  then array[]::public.order_status[]
  end;

  if not (p_status = any(v_allowed)) then
    if not v_elevated then
      raise exception 'Illegal status transition % -> %. Super Admin override required.',
        v_order.status, p_status
        using errcode = '42501';
    end if;
    if v_reason is null then
      raise exception 'A reason is required to override % -> %', v_order.status, p_status;
    end if;
    v_override := true;
  end if;

  v_locked := v_order.amount_paid > 0
              or v_order.commission_paid
              or exists (select 1 from public.payments where order_id = p_order_id);

  if p_status = 'cancelled' and v_locked then
    if not v_elevated then
      raise exception 'Order % has payments or paid commission. Only a Super Admin can cancel it.', p_order_id
        using errcode = '42501';
    end if;
    if v_reason is null then
      raise exception 'A reason is required to cancel order %, which has payments or paid commission', p_order_id;
    end if;
  end if;

  -- Cancelling returns stock to the shelf.
  if p_status = 'cancelled' then
    for v_item in
      select product_id, product_name, quantity
        from public.order_items
       where order_id = p_order_id and product_id is not null
    loop
      update public.products set stock = stock + v_item.quantity where id = v_item.product_id;

      insert into public.stock_movements (
        id, product_id, product_name, type, quantity_change, reason, created_by
      )
      values (
        'mv-' || replace(gen_random_uuid()::text, '-', ''),
        v_item.product_id, v_item.product_name, 'return', v_item.quantity,
        'Order ' || p_order_id || ' cancelled', v_actor
      );
    end loop;
  end if;

  -- Reactivating a cancelled order takes the stock back off the shelf.
  if v_order.status = 'cancelled' then
    for v_item in
      select oi.product_id, oi.product_name, oi.quantity, p.stock
        from public.order_items oi
        join public.products p on p.id = oi.product_id
       where oi.order_id = p_order_id
       for update of p
    loop
      if v_item.stock < v_item.quantity then
        raise exception 'Cannot reactivate: only % of % left in stock',
          v_item.stock, v_item.product_name;
      end if;

      update public.products set stock = stock - v_item.quantity where id = v_item.product_id;

      insert into public.stock_movements (
        id, product_id, product_name, type, quantity_change, reason, created_by
      )
      values (
        'mv-' || replace(gen_random_uuid()::text, '-', ''),
        v_item.product_id, v_item.product_name, 'correction', -v_item.quantity,
        'Order ' || p_order_id || ' reactivated', v_actor
      );
    end loop;
  end if;

  update public.orders
     set status       = p_status,
         -- First delivery time is kept for good: it is when commission is earned.
         delivered_at = case when p_status = 'delivered'
                             then coalesce(delivered_at, now())
                             else delivered_at end,
         updated_at   = now()
   where id = p_order_id;

  insert into public.system_logs (id, severity, category, message, user_id, target_id, metadata)
  values (
    'log-' || replace(gen_random_uuid()::text, '-', ''),
    case when v_override or (p_status = 'cancelled' and v_locked) then 'WARNING' else 'INFO' end::public.log_severity,
    'ORDER',
    format('Order %s status changed from %s to %s%s', p_order_id, v_order.status, p_status,
           case when v_override then ' (Super Admin override)' else '' end),
    v_actor, p_order_id,
    jsonb_build_object('source', 'db', 'from', v_order.status, 'to', p_status,
                       'override', v_override, 'reason', coalesce(v_reason, ''))
  );
end;
$fn$;

-- ============================================================================
-- 5. record_payment - same order scope, one audit line per payment
-- ============================================================================

create or replace function public.record_payment(
  p_order_id  text,
  p_amount    numeric,
  p_method    text default 'Cash',
  p_date      date default null,
  p_reference text default '',
  p_notes     text default ''
)
returns text
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_order       public.orders%rowtype;
  v_payment_id  text;
  v_today       date := public.efz_today();
  v_date        date := coalesce(p_date, public.efz_today());
begin
  perform public.require_any_permission(array['create_orders', 'edit_orders']);

  if p_amount is null or p_amount <= 0 then
    raise exception 'Payment amount must be greater than zero';
  end if;

  if v_date > v_today then
    raise exception 'A payment cannot be dated in the future (%)', v_date;
  end if;

  if v_date < v_today and not public.is_elevated_caller() then
    raise exception 'Only a Super Admin can record a payment dated before today (%)', v_date
      using errcode = '42501';
  end if;

  select * into v_order
    from public.orders
   where id = p_order_id
   for update;

  -- An order the caller cannot see does not exist as far as they are concerned.
  if not found
     or (auth.uid() is not null
         and not public.can_access_order(v_order.customer_id, v_order.marketing_officer_id)) then
    raise exception 'Unknown order: %', p_order_id;
  end if;

  if v_order.status = 'cancelled' then
    raise exception 'Order % is cancelled; payments cannot be recorded against it', p_order_id;
  end if;

  if p_amount > v_order.outstanding_balance then
    raise exception 'Payment of % exceeds the outstanding balance of %',
      p_amount, v_order.outstanding_balance;
  end if;

  v_payment_id := 'pay-' || replace(gen_random_uuid()::text, '-', '');

  insert into public.payments (
    id, order_id, amount, payment_date, payment_method, reference, notes, recorded_by
  )
  values (
    v_payment_id, p_order_id, p_amount, v_date,
    coalesce(nullif(p_method, ''), 'Cash'),
    coalesce(p_reference, ''), coalesce(p_notes, ''),
    public.current_profile_id()
  );

  -- 11: every payment gets exactly one audit line, written here in the same
  -- transaction. A backdated payment keeps its WARNING line (same text as 10).
  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values (
    'log-' || replace(gen_random_uuid()::text, '-', ''),
    (case when v_date < v_today then 'WARNING' else 'INFO' end)::public.log_severity,
    'FINANCIAL',
    case when v_date < v_today
         then format('Payment of %s on order %s recorded with a past date %s (recorded on %s)',
                     p_amount, p_order_id, v_date, v_today)
         else format('Payment of $%s recorded against order %s', p_amount, p_order_id)
    end,
    public.current_profile_id(), coalesce(public.current_profile_name(), ''), p_order_id,
    jsonb_build_object('source', 'db',
                       'event', case when v_date < v_today then 'backdated_payment' else 'payment_recorded' end,
                       'paymentId', v_payment_id, 'amount', p_amount, 'paymentDate', v_date,
                       'recordedOn', v_today, 'method', coalesce(nullif(p_method, ''), 'Cash'),
                       'reference', coalesce(p_reference, ''))
  );

  return v_payment_id;
end;
$fn$;

-- ============================================================================
-- 6. adjust_stock - audit line
-- ============================================================================

create or replace function public.adjust_stock(
  p_product_id      text,
  p_quantity_change integer,
  p_reason          text,
  p_type            public.stock_movement_type default 'manual_adjustment'
)
returns text
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_product     public.products%rowtype;
  v_movement_id text;
begin
  perform public.require_permission('adjust_stock');

  if p_quantity_change = 0 then
    raise exception 'Stock adjustment cannot be zero';
  end if;

  select * into v_product from public.products where id = p_product_id for update;
  if not found then
    raise exception 'Unknown product: %', p_product_id;
  end if;

  if v_product.stock + p_quantity_change < 0 then
    raise exception 'Adjustment would drive % below zero (% in stock, % requested)',
      v_product.name, v_product.stock, p_quantity_change;
  end if;

  update public.products
     set stock = stock + p_quantity_change
   where id = p_product_id;

  v_movement_id := 'mv-' || replace(gen_random_uuid()::text, '-', '');

  insert into public.stock_movements (
    id, product_id, product_name, type, quantity_change, reason, created_by
  )
  values (
    v_movement_id, p_product_id, v_product.name, p_type, p_quantity_change,
    coalesce(p_reason, ''), public.current_profile_id()
  );

  -- 11: audited here, in the same transaction as the movement.
  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values (
    'log-' || replace(gen_random_uuid()::text, '-', ''),
    'INFO', 'INVENTORY',
    format('Stock %s for %s: %s -> %s',
           case when p_quantity_change > 0 then 'increased' else 'decreased' end,
           v_product.name, v_product.stock, v_product.stock + p_quantity_change),
    public.current_profile_id(), coalesce(public.current_profile_name(), ''), p_product_id,
    jsonb_build_object('source', 'db', 'event', 'stock_adjustment', 'movementId', v_movement_id,
                       'type', p_type, 'quantityChange', p_quantity_change,
                       'reason', coalesce(p_reason, ''),
                       'oldValue', v_product.stock, 'newValue', v_product.stock + p_quantity_change)
  );

  return v_movement_id;
end;
$fn$;

-- ============================================================================
-- 7. CUSTOMER REGISTRATION AUDIT
-- ----------------------------------------------------------------------------
-- Customers are inserted directly (RLS customers_insert + trg_customers_guard),
-- not through an RPC, so the audit line comes from an AFTER INSERT trigger.
-- ============================================================================

create or replace function public.audit_customer_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null then
    return null;  -- SQL editor / import: trusted, not logged (unchanged)
  end if;

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values (
    'log-' || replace(gen_random_uuid()::text, '-', ''),
    'INFO', 'CUSTOMER',
    format('New customer registered: %s', new.name),
    public.current_profile_id(), coalesce(public.current_profile_name(), ''), new.id,
    jsonb_build_object('source', 'db', 'event', 'customer_created',
                       'marketingOfficerId', new.marketing_officer_id,
                       'registeredBy', new.registered_by)
  );
  return null;
end;
$fn$;

revoke all on function public.audit_customer_created() from public, anon, authenticated;

drop trigger if exists trg_customers_audit on public.customers;
create trigger trg_customers_audit
  after insert on public.customers
  for each row execute function public.audit_customer_created();

-- ============================================================================
-- 8. COMMISSION CHANGE AUDIT
-- ----------------------------------------------------------------------------
-- Logs a commission when it is created and whenever its officer, amount or
-- status actually changes. sync_order_commission() re-upserts the same values
-- on every eligible status change; those no-op updates are not logged.
-- The commission formula itself is untouched.
-- ============================================================================

create or replace function public.audit_commission_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null then
    return null;  -- SQL editor / import: trusted, not logged
  end if;

  if tg_op = 'UPDATE'
     and old.user_id is not distinct from new.user_id
     and old.amount  is not distinct from new.amount
     and old.status  is not distinct from new.status then
    return null;
  end if;

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values (
    'log-' || replace(gen_random_uuid()::text, '-', ''),
    'INFO', 'FINANCIAL',
    case when tg_op = 'INSERT'
         then format('Commission created for order %s: officer %s, $%s (%s)',
                     new.order_id, new.user_id, new.amount, new.status)
         else format('Commission for order %s changed: %s $%s -> %s $%s (officer %s)',
                     new.order_id, old.status, old.amount, new.status, new.amount, new.user_id)
    end,
    public.current_profile_id(), coalesce(public.current_profile_name(), ''), new.order_id,
    jsonb_build_object('source', 'db',
                       'event', case when tg_op = 'INSERT' then 'commission_created' else 'commission_changed' end,
                       'commissionId', new.id, 'officerId', new.user_id,
                       'oldStatus', case when tg_op = 'UPDATE' then old.status end,
                       'newStatus', new.status,
                       'oldAmount', case when tg_op = 'UPDATE' then old.amount end,
                       'newAmount', new.amount, 'payoutId', new.payout_id)
  );
  return null;
end;
$fn$;

revoke all on function public.audit_commission_change() from public, anon, authenticated;

drop trigger if exists trg_commissions_audit on public.commissions;
create trigger trg_commissions_audit
  after insert or update on public.commissions
  for each row execute function public.audit_commission_change();

-- ============================================================================
-- 9. COMMISSION VISIBILITY
-- ----------------------------------------------------------------------------
-- An officer sees only their own commissions and payouts; management (Super
-- Admin, and view_commissions holders who are not own-customers-only, i.e.
-- Manager) sees all. officer_commission_summary is security_invoker, so it
-- follows these policies and profiles_select below.
-- ============================================================================

create or replace function public.can_view_all_commissions()
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select public.is_super_admin()
      or (public.has_permission('view_commissions') and not public.is_own_customers_caller());
$fn$;

revoke all on function public.can_view_all_commissions() from public, anon;
grant execute on function public.can_view_all_commissions() to authenticated;

drop policy if exists commissions_select on public.commissions;
create policy commissions_select on public.commissions
  for select to authenticated
  using (
    public.can_view_all_commissions()
    or user_id = public.current_profile_id()
  );

drop policy if exists commission_payouts_select on public.commission_payouts;
create policy commission_payouts_select on public.commission_payouts
  for select to authenticated
  using (
    public.can_view_all_commissions()
    or user_id = public.current_profile_id()
  );

-- profiles carries each officer's running commission totals
-- (earned/pending/paid_commission_total). Any active staff member could read
-- every profile row, so every role could read every officer's totals. Those
-- three columns are no longer readable through the API by anyone; commission
-- totals are read from officer_commission_summary, which follows the
-- commission policies above (management: everyone; officer: own; others:
-- none). The Phase 4 app must stop selecting the three columns in the same
-- release (lib/supabase/queries.ts PROFILE_COLUMNS) - otherwise its profile
-- queries are refused.
revoke select on public.profiles from anon, authenticated;
grant select (
  id, auth_user_id, name, email, phone, avatar, role, status,
  commission_percentage, created_at, updated_at
) on public.profiles to authenticated;

-- Customer ownership history. view_commissions used to open every transfer
-- (customer, old and new officer, reason) to every officer. An officer now
-- sees only transfers they were part of (old or new officer); customer staff,
-- auditors and commission management keep the full history as before.
drop policy if exists customer_ownership_changes_select on public.customer_ownership_changes;
create policy customer_ownership_changes_select on public.customer_ownership_changes
  for select to authenticated
  using (
    public.has_any_permission(array['view_all_customers', 'view_customers', 'view_audit_trail'])
    or public.can_view_all_commissions()
    or old_officer_id = public.current_profile_id()
    or new_officer_id = public.current_profile_id()
  );

-- A Marketing Officer (own-customers-only caller) no longer sees other
-- Marketing Officers' profiles (name, email, phone). Historical orders still
-- show the officer who took them: order_details carries marketing_officer_name
-- for the orders the caller may see. Their own row is always visible; every
-- other role's visibility is unchanged from 08.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (
    auth_user_id = auth.uid()
    or (
      public.is_active_staff()
      and (not public.is_own_customers_caller() or role <> 'Marketing Officer')
    )
  );

-- ============================================================================
-- DOCUMENTED, DELIBERATELY UNCHANGED
-- ----------------------------------------------------------------------------
-- customers_select (03) still lets the officer who REGISTERED a customer read
-- that customer's record (name, phone, email, notes) after it has been
-- transferred to another officer. 11 removes that officer's access to the
-- customer's orders, payments and order creation, but changing customer-record
-- visibility needs an explicit business rule first.
-- ============================================================================

commit;
