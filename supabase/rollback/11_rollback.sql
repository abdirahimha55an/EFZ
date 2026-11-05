-- ============================================================================
-- EFZ - ROLLBACK for 11_order_scope_and_audit.sql
-- ----------------------------------------------------------------------------
-- Restores every function, view and policy 11 replaced, exactly as 02, 03, 08
-- and 10 define them (copied by a generator, not retyped), and removes the
-- triggers and helper functions 11 added.
--
-- Deliberately LEFT IN PLACE: system_logs.origin and its check constraint
-- (they label audit records written while 11 was active). Audit lines written
-- while 11 was active are kept, like every other audit line.
--
-- After rollback the issues 11 fixed are open again: officers can read and
-- pay every order through the API (by the order's officer, not the customer's
-- current one), officers can read every officer's commissions and profile
-- commission totals, the below-cost refusal names the cost, and payments /
-- orders / stock / customers are audited only by the browser.
--
-- Touches no business rows. Idempotent. Atomic: one explicit transaction
-- (see "ATOMIC" below).
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

-- 1. Remove what 11 added -----------------------------------------------------

drop trigger if exists trg_customers_audit   on public.customers;
drop trigger if exists trg_commissions_audit on public.commissions;
drop function if exists public.audit_customer_created();
drop function if exists public.audit_commission_change();

-- 2. Restore what 11 replaced -------------------------------------------------

create or replace function public.guard_system_logs_insert()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if public.is_client_request() then
    new.user_id     := public.current_profile_id();
    new.username    := coalesce(public.current_profile_name(), '');
    new.occurred_at := now();
  end if;
  return new;
end;
$fn$;

create or replace function public.can_see_order(p_officer_id text)
returns boolean
language sql
stable
set search_path = public
as $fn$
  select not public.is_client_request()
      or public.has_permission('view_orders')
      or coalesce(p_officer_id = public.current_profile_id(), false);
$fn$;

-- (as defined in 03)
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders
  for select to authenticated
  using (
    public.has_permission('view_orders')
    or marketing_officer_id = public.current_profile_id()
  );

-- (as defined in 03)
drop policy if exists commissions_select on public.commissions;
create policy commissions_select on public.commissions
  for select to authenticated
  using (
    public.has_permission('view_commissions')
    or user_id = public.current_profile_id()
  );

-- (as defined in 03)
drop policy if exists commission_payouts_select on public.commission_payouts;
create policy commission_payouts_select on public.commission_payouts
  for select to authenticated
  using (
    public.has_permission('view_commissions')
    or user_id = public.current_profile_id()
  );

-- (as defined in 08)
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (auth_user_id = auth.uid() or public.is_active_staff());

-- (as defined in 10)
drop policy if exists customer_ownership_changes_select on public.customer_ownership_changes;
create policy customer_ownership_changes_select on public.customer_ownership_changes
  for select to authenticated
  using (
    public.has_any_permission(array['view_all_customers', 'view_customers', 'view_audit_trail', 'view_commissions'])
    or old_officer_id = public.current_profile_id()
    or new_officer_id = public.current_profile_id()
  );

-- Reporting views exactly as 10 defines them (filtering with can_see_order).

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
where public.can_see_order(o.marketing_officer_id);

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
    and public.can_see_order(o.marketing_officer_id)
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
  and public.can_see_order(o.marketing_officer_id);

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
  and public.can_see_order(o.marketing_officer_id)
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
                and public.can_see_order(ov.marketing_officer_id))
left join public.orders o       on o.id = oi.order_id and o.status <> 'cancelled'
where public.can_see_products()
group by p.id, p.name, p.category
order by units_sold desc;

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

  -- Same visibility as the customers_select policy: an officer limited to
  -- their own customers cannot place orders against anyone else's.
  if not found
     or (auth.uid() is not null
         and not public.has_permission('view_all_customers')
         and not public.has_permission('view_customers')
         and v_customer.marketing_officer_id is distinct from v_actor
         and v_customer.registered_by        is distinct from v_actor) then
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
        raise exception 'Price % for % is below its cost of %. Only a Super Admin can approve a below-cost sale.',
          v_actual, v_product.name, v_product.cost_price
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

  return v_order_id;
end;
$fn$;

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
         and not public.has_permission('view_orders')
         and v_order.marketing_officer_id is distinct from v_actor) then
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
         and not public.has_permission('view_orders')
         and v_order.marketing_officer_id is distinct from public.current_profile_id()) then
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

  if v_date < v_today then
    insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
    values (
      'log-' || replace(gen_random_uuid()::text, '-', ''),
      'WARNING', 'FINANCIAL',
      format('Payment of %s on order %s recorded with a past date %s (recorded on %s)',
             p_amount, p_order_id, v_date, v_today),
      public.current_profile_id(), coalesce(public.current_profile_name(), ''), p_order_id,
      jsonb_build_object('source', 'db', 'event', 'backdated_payment', 'paymentId', v_payment_id,
                         'amount', p_amount, 'paymentDate', v_date, 'recordedOn', v_today)
    );
  end if;

  return v_payment_id;
end;
$fn$;

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

  return v_movement_id;
end;
$fn$;

-- profiles readable as a whole table again, as before 11 (Supabase's default
-- grant; staging_api_grants.sql on EFZ-Staging). Revoking the table privilege
-- also removes 11's column grants. NOTE: the Phase 4 app with the 11 change
-- keeps working after this rollback (it simply selects fewer columns).
revoke select on public.profiles from anon, authenticated;
grant  select on public.profiles to anon, authenticated;

-- 3. Helpers 11 added, unused once the above are restored ---------------------

drop function if exists public.can_see_customer_order(text, text);
drop function if exists public.can_access_order(text, text);
drop function if exists public.can_access_order(text);
drop function if exists public.can_view_all_commissions();
drop function if exists public.has_all_order_scope();
drop function if exists public.is_own_customers_caller();

commit;
