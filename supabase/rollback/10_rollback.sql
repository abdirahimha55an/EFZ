-- ============================================================================
-- EFZ - ROLLBACK for 10_rpc_hardening.sql
-- ----------------------------------------------------------------------------
-- Restores every function, trigger, policy, view, grant and column default
-- that 10 replaced, exactly as 02_functions.sql, 03_rls.sql, 04_views.sql,
-- 05_seed.sql and 08_security_hardening.sql defined them (the function and
-- view bodies below are copied from those files by a generator, not retyped).
--
-- Deliberately LEFT IN PLACE (additive, and they may hold audit records):
--   * the user_role value 'Customer Service' (Postgres cannot drop an enum value)
--   * orders.delivered_at
--   * below_cost_overrides, customer_ownership_changes
--
-- Touches no business rows. Idempotent.
-- ============================================================================

-- 1. Functions 10 replaced ----------------------------------------------------

create or replace function public.create_order(payload jsonb)
returns text
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_order_id  text;
  v_actor     text := public.current_profile_id();
  v_officer   text;
  v_customer  text;
  v_item      jsonb;
  v_product   public.products%rowtype;
  v_qty       integer;
  v_actual    numeric(12,2);
  v_standard  numeric(12,2);
  v_seq       integer := 0;
begin
  perform public.require_permission('create_orders');

  if jsonb_typeof(payload -> 'items') <> 'array'
     or jsonb_array_length(payload -> 'items') = 0 then
    raise exception 'Order must contain at least one item';
  end if;

  v_order_id := nullif(payload ->> 'id', '');
  if v_order_id is null then
    loop
      v_order_id := 'ORD-' || lpad((floor(random() * 9000000) + 1000000)::text, 7, '0');
      exit when not exists (select 1 from public.orders where id = v_order_id);
    end loop;
  end if;

  v_customer := nullif(payload ->> 'customerId', '');
  v_officer  := nullif(payload ->> 'marketingOfficerId', '');

  if v_officer is null and v_customer is not null then
    select coalesce(marketing_officer_id, registered_by)
      into v_officer
      from public.customers
     where id = v_customer;
  end if;

  insert into public.orders (
    id, customer_id, customer_name, phone, marketing_officer_id,
    status, order_type, order_date, delivery_notes, created_by, legacy_reference_id
  )
  values (
    v_order_id,
    v_customer,
    coalesce(nullif(payload ->> 'customerName', ''),
             (select name from public.customers where id = v_customer), ''),
    coalesce(nullif(payload ->> 'phone', ''),
             (select phone from public.customers where id = v_customer), ''),
    v_officer,
    coalesce(nullif(payload ->> 'status', ''), 'pending')::public.order_status,
    coalesce(nullif(payload ->> 'orderType', ''), 'regular')::public.order_type,
    coalesce((payload ->> 'orderDate')::date, current_date),
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

    v_qty := greatest(1, coalesce((v_item ->> 'quantity')::integer, 1));

    if v_product.stock < v_qty then
      raise exception 'Insufficient stock for %: % in stock, % requested',
        v_product.name, v_product.stock, v_qty;
    end if;

    v_actual   := coalesce((v_item ->> 'actualUnitPrice')::numeric,   v_product.selling_price);
    v_standard := coalesce((v_item ->> 'standardUnitPrice')::numeric, v_product.selling_price);

    insert into public.order_items (
      id, order_id, product_id, product_name, design_name, quantity,
      standard_unit_price, actual_unit_price, historical_unit_cost
    )
    values (
      'itm-' || replace(gen_random_uuid()::text, '-', '') || '-' || v_seq,
      v_order_id,
      v_product.id,
      v_product.name,
      coalesce(nullif(v_item ->> 'designName', ''), v_product.name),
      v_qty,
      v_standard,
      v_actual,
      v_product.cost_price   -- frozen cost snapshot
    );

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
  v_current  public.order_status;
  v_allowed  public.order_status[];
  v_actor    text := public.current_profile_id();
  v_item     record;
begin
  perform public.require_permission('edit_orders');

  select status into v_current
    from public.orders
   where id = p_order_id
   for update;

  if not found then
    raise exception 'Unknown order: %', p_order_id;
  end if;

  if v_current = p_status then
    return;
  end if;

  v_allowed := case v_current
    when 'pending'    then array['confirmed', 'cancelled']::public.order_status[]
    when 'confirmed'  then array['processing', 'cancelled']::public.order_status[]
    when 'processing' then array['delivered', 'cancelled']::public.order_status[]
    when 'delivered'  then array[]::public.order_status[]
    when 'cancelled'  then array['pending']::public.order_status[]
  end;

  if not (p_status = any(v_allowed)) and not public.is_super_admin() then
    raise exception 'Illegal status transition % -> %. Super Admin override required.',
      v_current, p_status;
  end if;

  -- Cancelling returns stock to the shelf.
  if p_status = 'cancelled' and v_current <> 'cancelled' then
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
  if v_current = 'cancelled' and p_status <> 'cancelled' then
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
     set status = p_status, updated_at = now()
   where id = p_order_id;

  insert into public.system_logs (id, severity, category, message, user_id, target_id, metadata)
  values (
    'log-' || replace(gen_random_uuid()::text, '-', ''),
    'INFO', 'ORDER',
    format('Order %s status changed from %s to %s', p_order_id, v_current, p_status),
    v_actor, p_order_id,
    jsonb_build_object('from', v_current, 'to', p_status, 'reason', coalesce(p_reason, ''))
  );
end;
$fn$;

create or replace function public.record_payment(
  p_order_id  text,
  p_amount    numeric,
  p_method    text default 'Cash',
  p_date      date default current_date,
  p_reference text default '',
  p_notes     text default ''
)
returns text
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_outstanding numeric(14,2);
  v_payment_id  text;
begin
  perform public.require_any_permission(array['create_orders', 'edit_orders']);

  if p_amount is null or p_amount <= 0 then
    raise exception 'Payment amount must be greater than zero';
  end if;

  select outstanding_balance
    into v_outstanding
    from public.orders
   where id = p_order_id
   for update;

  if not found then
    raise exception 'Unknown order: %', p_order_id;
  end if;

  if p_amount > v_outstanding then
    raise exception 'Payment of % exceeds the outstanding balance of %',
      p_amount, v_outstanding;
  end if;

  v_payment_id := 'pay-' || replace(gen_random_uuid()::text, '-', '');

  insert into public.payments (
    id, order_id, amount, payment_date, payment_method, reference, notes, recorded_by
  )
  values (
    v_payment_id, p_order_id, p_amount, coalesce(p_date, current_date),
    coalesce(nullif(p_method, ''), 'Cash'),
    coalesce(p_reference, ''), coalesce(p_notes, ''),
    public.current_profile_id()
  );

  return v_payment_id;
end;
$fn$;

create or replace function public.pay_commissions(
  p_user_id        text,
  p_commission_ids uuid[],
  p_method         text default 'Cash',
  p_reference      text default '',
  p_notes          text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_total     numeric(14,2);
  v_payout_id uuid;
begin
  perform public.require_permission('mark_commissions_paid');

  select coalesce(sum(amount), 0)
    into v_total
    from public.commissions
   where id = any(p_commission_ids)
     and user_id = p_user_id
     and status <> 'paid';

  if v_total <= 0 then
    raise exception 'No unpaid commissions found for this payout';
  end if;

  insert into public.commission_payouts (user_id, amount, method, reference, notes, paid_by)
  values (
    p_user_id, v_total,
    coalesce(nullif(p_method, ''), 'Cash'),
    coalesce(p_reference, ''), coalesce(p_notes, ''),
    public.current_profile_id()
  )
  returning id into v_payout_id;

  update public.commissions
     set status     = 'paid',
         payout_id  = v_payout_id,
         updated_at = now()
   where id = any(p_commission_ids)
     and user_id = p_user_id
     and status <> 'paid';

  return v_payout_id;
end;
$fn$;

create or replace function public.grant_role_preset(p_user_id text, p_role public.user_role)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_codes text[];
begin
  v_codes := case p_role
    when 'Super Admin' then array[]::text[]   -- bypasses permission checks entirely

    when 'Manager' then array[
      'view_dashboard',
      'view_orders', 'create_orders', 'edit_orders',
      'view_products', 'add_products', 'edit_products',
      'view_inventory', 'adjust_stock',
      'view_customers', 'add_customers', 'edit_customers', 'view_all_customers',
      'view_reports', 'view_commissions', 'mark_commissions_paid',
      'view_audit_trail'
    ]

    when 'Marketing Officer' then array[
      'view_dashboard',
      'view_orders', 'create_orders',
      'view_products',
      'add_customers', 'edit_customers', 'view_own_customers_only',
      'view_commissions'
    ]

    when 'Inventory Staff' then array[
      'view_dashboard',
      'view_orders',
      'view_products', 'add_products', 'edit_products',
      'view_inventory', 'adjust_stock'
    ]

    when 'Delivery Staff' then array[
      'view_dashboard',
      'view_orders', 'edit_orders',
      'view_customers'
    ]
  end;

  perform public.set_user_permissions(p_user_id, v_codes);
end;
$fn$;

create or replace function public.guard_orders_write()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_locked text[];
begin
  if not public.is_client_request() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.total <> 0 or new.cost <> 0 or new.gross_profit <> 0
       or new.amount_paid <> 0 or new.outstanding_balance <> 0
       or new.commission_paid
       or new.payment_status <> 'unpaid'
       or new.status <> 'pending' then
      raise exception 'Orders are created through create_order()'
        using errcode = '42501';
    end if;

    new.created_by := public.current_profile_id();
    return new;
  end if;

  v_locked := public.changed_columns(to_jsonb(old), to_jsonb(new), array[
    'id', 'status', 'payment_status',
    'total', 'cost', 'gross_profit', 'amount_paid', 'outstanding_balance',
    'commission_paid', 'created_by', 'created_at',
    'legacy_order_ids', 'legacy_reference_id'
  ]);

  if cardinality(v_locked) > 0 then
    raise exception 'Order field(s) % are maintained by the database and cannot be written directly', v_locked
      using errcode = '42501';
  end if;

  if new.marketing_officer_id is distinct from old.marketing_officer_id
     and not public.is_super_admin() then
    raise exception 'Only a Super Admin can reassign an order''s marketing officer'
      using errcode = '42501';
  end if;

  return new;
end;
$fn$;

create or replace function public.guard_products_write()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if not public.is_client_request() then
    return new;
  end if;

  if tg_op = 'INSERT' and new.stock <> 0 then
    raise exception 'Create products with stock 0, then use adjust_stock()'
      using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' and new.stock is distinct from old.stock then
    raise exception 'Stock changes must go through adjust_stock()'
      using errcode = '42501';
  end if;

  return new;
end;
$fn$;

-- 1b. Cost visibility: views back to 04_views.sql, table SELECT back -----------

-- order_details gained a column, which CREATE OR REPLACE cannot remove.
drop view if exists public.order_details;
drop view if exists public.staff_products;

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

alter view public.inventory_status  reset (security_barrier);
alter view public.financial_summary reset (security_barrier);
alter view public.daily_sales       reset (security_barrier);
alter view public.product_sales     reset (security_barrier);

revoke all    on public.order_details from public, anon;
grant  select on public.order_details, public.inventory_status, public.financial_summary,
                 public.daily_sales, public.product_sales
  to authenticated;

-- Table-level SELECT as before 10 (default Supabase grants, or
-- staging_api_grants.sql on EFZ-Staging).
grant select on public.products, public.orders, public.order_items to authenticated;
grant select on public.orders, public.order_items to anon;

-- Column defaults back to the UTC date.
alter table public.orders    alter column order_date    set default current_date;
alter table public.payments  alter column payment_date  set default current_date;
alter table public.customers alter column registered_on set default current_date;

revoke all on function public.grant_role_preset(text, public.user_role) from public, anon;
grant execute on function public.grant_role_preset(text, public.user_role) to authenticated;

-- 2. Triggers and functions 10 added -------------------------------------------

drop trigger if exists trg_customers_guard        on public.customers;
drop trigger if exists trg_customers_guard_delete on public.customers;
drop trigger if exists trg_orders_guard_delete    on public.orders;

drop function if exists public.guard_customers_write();
drop function if exists public.guard_customers_delete();
drop function if exists public.guard_orders_delete();
drop function if exists public.transfer_customer_owner(text, text, text);
drop function if exists public.is_elevated_caller();
drop function if exists public.can_manage_pricing();
drop function if exists public.can_view_cost();
drop function if exists public.can_see_order(text);
drop function if exists public.can_see_products();
drop function if exists public.efz_today();

-- 3. Policies as 03_rls.sql defined them ---------------------------------------

drop policy if exists products_update on public.products;
create policy products_update on public.products
  for update to authenticated
  using (public.has_permission('edit_products') or public.has_permission('adjust_stock'))
  with check (public.has_permission('edit_products') or public.has_permission('adjust_stock'));

drop policy if exists orders_insert on public.orders;
create policy orders_insert on public.orders
  for insert to authenticated
  with check (public.has_permission('create_orders'));

drop policy if exists orders_delete on public.orders;
create policy orders_delete on public.orders
  for delete to authenticated
  using (
    public.has_permission('delete_orders')
    and (commission_paid = false or public.is_super_admin())
  );
