-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 10 : RPC hardening and customer ownership (2026-09-29)
-- ----------------------------------------------------------------------------
-- Run AFTER 01..05, 07, 08 and 09. Idempotent: safe to re-run.
--
-- It adds guards, one column, two append-only record tables and one role.
-- It does not UPDATE, DELETE or re-compute a single existing row: every
-- historical order, payment, commission and stock figure is left exactly as
-- it is. The new orders.delivered_at column starts NULL for every existing
-- order - no delivery time is invented for history.
--
-- 08 closed direct table writes. The SECURITY DEFINER RPCs run past RLS and
-- past those guards, so their own checks are the only thing enforcing the
-- business rules. This file makes them authoritative:
--
--   1. Customer Service role, with its permission preset.
--   2. create_order: always pending, officer taken from the customer, no
--      caller-chosen id, today's date unless Super Admin, no below-cost line
--      unless a Super Admin approves it with a reason (recorded).
--   3. update_order_status: an order with payments or paid commission can only
--      be cancelled by a Super Admin with a reason; reactivating a cancelled
--      order and every other override needs a Super Admin and a reason;
--      delivered_at is stamped on delivery and never cleared.
--   4. record_payment: refused on cancelled orders and on orders the caller
--      cannot see.
--   5. pay_commissions: pays only unpaid, non-zero commission on delivered
--      orders; rows are locked, so a second payout of the same rows fails.
--   6. Customer ownership: the Marketing Officer on a customer changes only
--      through transfer_customer_owner() (Super Admin, reason, recorded).
--   7. Orders: customer, date and type edits need a Super Admin; the officer
--      follows the customer; direct inserts are Super Admin only; deletion is
--      Super Admin only, of cancelled orders with no payments.
--   8. Products: only a Super Admin or Manager sets price or cost
--      (adjust_stock alone no longer allows a products UPDATE at all).
--   9. Customers with orders cannot be deleted - archive them instead.
--  10. Payments: only a Super Admin records a payment dated before today;
--      nobody records one dated in the future.
--  11. "Today" is the Africa/Mogadishu calendar date (UTC+3), not UTC.
--  12. Cost and margin are visible only to holders of view_inventory or
--      view_reports (Super Admin, Manager, Inventory Staff by preset). The
--      cost columns of products / orders / order_items are no longer
--      selectable by the authenticated role at all; the reporting views mask
--      them per user, and staff_products is the product list with cost masked.
--
-- Decisions approved 2026-09-29 (Phase 2 review):
--   * Only a Marketing Officer's own registration sets a customer's owner;
--     everyone else (Customer Service, Manager, Super Admin in the app)
--     registers the customer unassigned, and the owner is then set with the
--     audited transfer_customer_owner().
--   * Every order has a customer. No future-dated orders, for anyone.
--   * A reason is required for every Super Admin override.
--
-- "Trusted" callers: a NULL auth.uid() means service_role or the SQL editor,
-- which were already trusted everywhere (see require_permission in 02). They
-- are treated like a Super Admin here, so imports and staging scripts work.
--
-- Rollback: supabase/rollback/10_rollback.sql restores every function and
-- policy this file replaces. The enum value, the column and the two record
-- tables are left in place by the rollback (they hold audit data).
-- ============================================================================

-- ============================================================================
-- 0. CUSTOMER SERVICE ROLE + delivered_at
-- ----------------------------------------------------------------------------
-- ADD VALUE is allowed inside a transaction; the new value simply cannot be
-- used as a literal until it commits. Nothing below uses it outside a
-- function body, which is resolved at call time.
-- ============================================================================

alter type public.user_role add value if not exists 'Customer Service';

alter table public.orders add column if not exists delivered_at timestamptz;

comment on column public.orders.delivered_at is
  'Set by update_order_status() the first time the order becomes delivered. NULL for orders delivered before 2026-09-29 (no time is invented for history).';

-- ============================================================================
-- 1. HELPERS
-- ============================================================================

-- Super Admin, or a trusted server-side session (service_role / SQL editor).
create or replace function public.is_elevated_caller()
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select auth.uid() is null or public.is_super_admin();
$fn$;

revoke all on function public.is_elevated_caller() from public, anon;
grant execute on function public.is_elevated_caller() to authenticated;

-- EFZ trades in Mogadishu (UTC+3, no daylight saving). Every "today" in the
-- business rules is this date, so an order taken at 01:00 local time is not
-- filed under the previous day as a UTC date would.
create or replace function public.efz_today()
returns date
language sql
stable
set search_path = public
as $fn$
  select (now() at time zone 'Africa/Mogadishu')::date;
$fn$;

revoke all on function public.efz_today() from public;
grant execute on function public.efz_today() to anon, authenticated;

-- Who may set a product's selling price or cost: a Super Admin or a Manager.
create or replace function public.can_manage_pricing()
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1 from public.profiles p
     where p.auth_user_id = auth.uid()
       and p.status = 'active'
       and p.role::text in ('Super Admin', 'Manager')
  );
$fn$;

revoke all on function public.can_manage_pricing() from public, anon;
grant execute on function public.can_manage_pricing() to authenticated;

-- The next three are SECURITY INVOKER on purpose: they run inside the
-- reporting views, and is_client_request() must see the real caller.
-- A trusted session (SQL editor, service_role) sees everything, as before.

-- Cost, margin and profit: view_inventory or view_reports.
create or replace function public.can_view_cost()
returns boolean
language sql
stable
set search_path = public
as $fn$
  select not public.is_client_request()
      or public.has_any_permission(array['view_inventory', 'view_reports']);
$fn$;

-- Mirrors the orders_select policy in 03_rls.sql. The owner-rights views
-- below filter with this, so it must stay identical to that policy.
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

-- Mirrors products_select_staff (08).
create or replace function public.can_see_products()
returns boolean
language sql
stable
set search_path = public
as $fn$
  select not public.is_client_request() or public.is_active_staff();
$fn$;

revoke all on function public.can_view_cost()         from public, anon;
revoke all on function public.can_see_order(text)     from public, anon;
revoke all on function public.can_see_products()      from public, anon;
grant execute on function public.can_view_cost()      to authenticated;
grant execute on function public.can_see_order(text)  to authenticated;
grant execute on function public.can_see_products()   to authenticated;

-- New rows default to the Mogadishu date too.
alter table public.orders    alter column order_date    set default public.efz_today();
alter table public.payments  alter column payment_date  set default public.efz_today();
alter table public.customers alter column registered_on set default public.efz_today();

-- ============================================================================
-- 2. RECORD TABLES (append-only, written only by the RPCs)
-- ============================================================================

create table if not exists public.below_cost_overrides (
  id                 uuid primary key default gen_random_uuid(),
  order_id           text not null,
  order_item_id      text,
  product_id         text references public.products(id) on delete set null,
  product_name       text not null default '',
  quantity           integer not null,
  selling_price      numeric(12,2) not null,
  unit_cost          numeric(12,2) not null,
  line_margin        numeric(14,2) not null,
  margin_percentage  numeric(9,2),
  reason             text not null check (char_length(btrim(reason)) > 0),
  approved_by        text references public.profiles(id) on delete set null,
  approved_by_name   text not null default '',
  created_at         timestamptz not null default now()
);

comment on table public.below_cost_overrides is
  'One row per order line sold below cost, approved by a Super Admin. Written only by create_order(). order_id has no foreign key on purpose, so the record survives the order.';

create index if not exists idx_below_cost_overrides_order on public.below_cost_overrides(order_id);

create table if not exists public.customer_ownership_changes (
  id                uuid primary key default gen_random_uuid(),
  customer_id       text not null,
  customer_name     text not null default '',
  old_officer_id    text references public.profiles(id) on delete set null,
  old_officer_name  text not null default '',
  new_officer_id    text references public.profiles(id) on delete set null,
  new_officer_name  text not null default '',
  reason            text not null check (char_length(btrim(reason)) > 0),
  orders_moved      text[] not null default '{}',
  changed_by        text references public.profiles(id) on delete set null,
  changed_by_name   text not null default '',
  changed_at        timestamptz not null default now()
);

comment on table public.customer_ownership_changes is
  'Every Marketing Officer transfer of a customer. Written only by transfer_customer_owner(). Commission already earned stays with the officer who earned it.';

create index if not exists idx_customer_ownership_changes_customer
  on public.customer_ownership_changes(customer_id, changed_at desc);

alter table public.below_cost_overrides       enable row level security;
alter table public.customer_ownership_changes enable row level security;

drop policy if exists below_cost_overrides_select on public.below_cost_overrides;
create policy below_cost_overrides_select on public.below_cost_overrides
  for select to authenticated
  using (public.has_any_permission(array['view_reports', 'view_inventory', 'view_audit_trail']));

drop policy if exists customer_ownership_changes_select on public.customer_ownership_changes;
create policy customer_ownership_changes_select on public.customer_ownership_changes
  for select to authenticated
  using (
    public.has_any_permission(array['view_all_customers', 'view_customers', 'view_audit_trail', 'view_commissions'])
    or old_officer_id = public.current_profile_id()
    or new_officer_id = public.current_profile_id()
  );

-- No insert/update/delete policies: only the SECURITY DEFINER RPCs write here.
-- Grants are explicit because EFZ-Staging has no automatic API grants.
revoke all    on public.below_cost_overrides, public.customer_ownership_changes from anon;
grant  select on public.below_cost_overrides, public.customer_ownership_changes to authenticated;

-- ============================================================================
-- 3. ROLE PRESETS - adds Customer Service
-- ----------------------------------------------------------------------------
-- Identical to 05_seed.sql except for the new branch. Customer Service runs
-- the customer relationship and the orders, but holds nothing that touches
-- commission, cost or pricing: no view/mark commissions, no edit_products,
-- no adjust_stock, no delete, no reports.
-- ============================================================================

create or replace function public.grant_role_preset(p_user_id text, p_role public.user_role)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_codes text[];
begin
  v_codes := case p_role::text
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

    when 'Customer Service' then array[
      'view_dashboard',
      'view_orders', 'create_orders', 'edit_orders',
      'view_products',
      'view_customers', 'view_all_customers', 'add_customers', 'edit_customers'
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

revoke all on function public.grant_role_preset(text, public.user_role) from public, anon;
grant execute on function public.grant_role_preset(text, public.user_role) to authenticated;

-- ============================================================================
-- 4. create_order
-- ----------------------------------------------------------------------------
-- Same payload and return value as before. What the database now decides
-- instead of the browser:
--   * status          always 'pending' (anything else is refused)
--   * id              generated, unless a Super Admin supplies one
--   * officer         the customer's marketing_officer_id; a supplied
--                     marketingOfficerId is ignored (and logged if different)
--   * order date      today in Mogadishu; a Super Admin may use a past date
--                     (logged); nobody may use a future date
--   * standard price  the product's selling price at the time of sale
--   * below cost      refused, unless a Super Admin passes belowCostReason;
--                     each such line is written to below_cost_overrides
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

-- ============================================================================
-- 5. update_order_status
-- ----------------------------------------------------------------------------
-- Normal pipeline (edit_orders):
--   pending -> confirmed | cancelled
--   confirmed -> processing | cancelled
--   processing -> delivered | cancelled
-- Everything else - leaving delivered, reactivating a cancelled order - is an
-- override: Super Admin only, and a reason is required.
-- Cancelling an order that has payments or paid commission is Super Admin
-- only, with a reason, even though cancel is otherwise a normal step.
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

-- ============================================================================
-- 6. record_payment
-- ----------------------------------------------------------------------------
-- The payment date decides which month the cash is reported in, so it gets
-- the same rule as the order date: today (Mogadishu) for everyone, a past
-- date for a Super Admin only (logged), a future date for nobody.
-- p_date now defaults to NULL, meaning today in Mogadishu.
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

-- ============================================================================
-- 7. pay_commissions
-- ----------------------------------------------------------------------------
-- Every requested row must be payable, or nothing is paid:
--   belongs to p_user_id, status pending/approved, amount > 0, order delivered.
-- The rows (and their orders) are locked first, so two payouts racing for the
-- same commission serialise and the second one finds it already paid.
-- ============================================================================

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
  v_ids       uuid[];
  v_found     integer;
  v_bad       integer;
  v_total     numeric(14,2);
  v_payout_id uuid;
begin
  perform public.require_permission('mark_commissions_paid');

  select coalesce(array_agg(distinct x), array[]::uuid[])
    into v_ids
    from unnest(coalesce(p_commission_ids, array[]::uuid[])) as x
   where x is not null;

  if cardinality(v_ids) = 0 then
    raise exception 'No commissions selected for this payout';
  end if;

  perform 1
     from public.commissions c
     join public.orders o on o.id = c.order_id
    where c.id = any(v_ids)
    order by c.id
      for update of c, o;

  select count(*),
         count(*) filter (where not (c.user_id = p_user_id
                                     and c.status in ('pending', 'approved')
                                     and c.amount > 0
                                     and o.status = 'delivered')),
         coalesce(sum(c.amount), 0)
    into v_found, v_bad, v_total
    from public.commissions c
    join public.orders o on o.id = c.order_id
   where c.id = any(v_ids);

  if v_found <> cardinality(v_ids) then
    raise exception '% of the selected commissions do not exist', cardinality(v_ids) - v_found;
  end if;

  if v_bad > 0 then
    raise exception '% of the selected commissions are not payable (already paid, void, $0, another officer''s, or the order is not delivered)', v_bad;
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
   where id = any(v_ids);

  return v_payout_id;
end;
$fn$;

-- ============================================================================
-- 8. CUSTOMER OWNERSHIP
-- ----------------------------------------------------------------------------
-- customers.marketing_officer_id is the acquisition / commission owner.
-- customers.registered_by is who typed the record in.
--   * A Marketing Officer's new customer is always their own.
--   * Everyone else (Customer Service, Manager, and a Super Admin through the
--     app) registers customers without an owner; a Super Admin then assigns
--     the Marketing Officer with transfer_customer_owner(), which is audited.
--   * Nobody changes the owner by editing the row - only the transfer RPC.
--   * A customer with orders cannot be deleted (archive instead): deleting it
--     would detach its sales history.
-- ============================================================================

create or replace function public.guard_customers_write()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_me   text;
  v_role text;
begin
  if not public.is_client_request() then
    return new;
  end if;

  v_me := public.current_profile_id();

  if tg_op = 'INSERT' then
    new.registered_by := v_me;

    select role::text into v_role from public.profiles where id = v_me;

    if v_role = 'Marketing Officer' then
      if new.marketing_officer_id is not null and new.marketing_officer_id <> v_me then
        raise exception 'A Marketing Officer can only register customers to themselves'
          using errcode = '42501';
      end if;
      new.marketing_officer_id := v_me;
    elsif new.marketing_officer_id is not null then
      -- Customer Service, Manager, and a Super Admin in the app alike: the
      -- owner is assigned afterwards with the audited transfer.
      raise exception 'Only a Marketing Officer registering their own customer sets its owner. Register it unassigned; a Super Admin assigns the Marketing Officer with transfer_customer_owner().'
        using errcode = '42501';
    end if;

    return new;
  end if;

  if new.id is distinct from old.id then
    raise exception 'A customer id cannot be changed'
      using errcode = '42501';
  end if;

  if new.marketing_officer_id is distinct from old.marketing_officer_id then
    raise exception 'A customer''s Marketing Officer can only be changed with transfer_customer_owner() (Super Admin only)'
      using errcode = '42501';
  end if;

  if new.registered_by is distinct from old.registered_by then
    raise exception 'registered_by records who registered the customer and cannot be changed'
      using errcode = '42501';
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_customers_guard on public.customers;
create trigger trg_customers_guard
  before insert or update on public.customers
  for each row execute function public.guard_customers_write();

create or replace function public.guard_customers_delete()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if not public.is_client_request() then
    return old;
  end if;

  if exists (select 1 from public.orders where customer_id = old.id) then
    raise exception 'Customer % has orders and cannot be deleted - archive it instead', old.name
      using errcode = '42501';
  end if;

  return old;
end;
$fn$;

drop trigger if exists trg_customers_guard_delete on public.customers;
create trigger trg_customers_guard_delete
  before delete on public.customers
  for each row execute function public.guard_customers_delete();

-- ---------------------------------------------------------------------------
-- transfer_customer_owner(customer, new officer, reason) -> jsonb
--
-- Orders not yet delivered (pending / confirmed / processing) move with the
-- customer, so they earn for the new officer when they are delivered.
-- Delivered and cancelled orders keep their officer: commission already
-- earned stays with whoever earned it. Under the commission ledger still in
-- place until migration 11, an unpaid ledger row for a moved order is voided
-- for the old officer (the ledger trigger opens one for the new officer).
-- ---------------------------------------------------------------------------

create or replace function public.transfer_customer_owner(
  p_customer_id    text,
  p_new_officer_id text,
  p_reason         text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_customer  public.customers%rowtype;
  v_new       public.profiles%rowtype;
  v_old_name  text;
  v_reason    text := nullif(btrim(coalesce(p_reason, '')), '');
  v_actor     text := public.current_profile_id();
  v_actor_nm  text := coalesce(public.current_profile_name(), '');
  v_moved     text[];
  v_change_id uuid;
begin
  if not public.is_elevated_caller() then
    raise exception 'Only a Super Admin can transfer a customer to another Marketing Officer'
      using errcode = '42501';
  end if;

  if v_reason is null then
    raise exception 'A reason is required to transfer customer ownership';
  end if;

  select * into v_customer from public.customers where id = p_customer_id for update;
  if not found then
    raise exception 'Unknown customer: %', p_customer_id;
  end if;

  select * into v_new from public.profiles where id = p_new_officer_id;
  if not found or v_new.role::text <> 'Marketing Officer' or v_new.status <> 'active' then
    raise exception 'The new owner must be an active Marketing Officer';
  end if;

  if v_customer.marketing_officer_id is not distinct from p_new_officer_id then
    raise exception '% is already owned by %', v_customer.name, v_new.name;
  end if;

  select name into v_old_name from public.profiles where id = v_customer.marketing_officer_id;

  update public.customers
     set marketing_officer_id = p_new_officer_id,
         updated_at           = now()
   where id = p_customer_id;

  with moved as (
    update public.orders
       set marketing_officer_id = p_new_officer_id,
           updated_at           = now()
     where customer_id = p_customer_id
       and status in ('pending', 'confirmed', 'processing')
       and marketing_officer_id is distinct from p_new_officer_id
    returning id
  )
  select coalesce(array_agg(id order by id), array[]::text[]) into v_moved from moved;

  update public.commissions
     set status     = 'void',
         amount     = 0,
         note       = trim(both from note || ' Voided: customer transferred to ' || p_new_officer_id),
         updated_at = now()
   where order_id = any(v_moved)
     and user_id is distinct from p_new_officer_id
     and status <> 'paid';

  insert into public.customer_ownership_changes (
    customer_id, customer_name, old_officer_id, old_officer_name,
    new_officer_id, new_officer_name, reason, orders_moved, changed_by, changed_by_name
  )
  values (
    v_customer.id, v_customer.name, v_customer.marketing_officer_id, coalesce(v_old_name, ''),
    p_new_officer_id, v_new.name, v_reason, v_moved, v_actor, v_actor_nm
  )
  returning id into v_change_id;

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values (
    'log-' || replace(gen_random_uuid()::text, '-', ''),
    'WARNING', 'CUSTOMER',
    format('Customer %s transferred from %s to %s: %s',
           v_customer.name, coalesce(v_old_name, '(no officer)'), v_new.name, v_reason),
    v_actor, v_actor_nm, v_customer.id,
    jsonb_build_object('source', 'db', 'event', 'customer_ownership_transfer',
                       'changeId', v_change_id,
                       'oldOfficerId', v_customer.marketing_officer_id,
                       'newOfficerId', p_new_officer_id,
                       'ordersMoved', to_jsonb(v_moved),
                       'reason', v_reason)
  );

  return jsonb_build_object(
    'changeId', v_change_id,
    'customerId', v_customer.id,
    'oldOfficerId', v_customer.marketing_officer_id,
    'newOfficerId', p_new_officer_id,
    'ordersMoved', to_jsonb(v_moved)
  );
end;
$fn$;

revoke all on function public.transfer_customer_owner(text, text, text) from public, anon;
grant execute on function public.transfer_customer_owner(text, text, text) to authenticated;

-- ============================================================================
-- 9. ORDERS - edits, inserts and deletes
-- ----------------------------------------------------------------------------
-- guard_orders_write() is 08's guard plus:
--   * delivered_at is database-maintained
--   * the officer follows the customer - nobody writes it directly
--   * customer_id / order_date / order_type (they move revenue between
--     customers, months, and commission rules) need a Super Admin
--   * no future order dates
-- ============================================================================

create or replace function public.guard_orders_write()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_locked     text[];
  v_restricted text[];
begin
  if not public.is_client_request() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.total <> 0 or new.cost <> 0 or new.gross_profit <> 0
       or new.amount_paid <> 0 or new.outstanding_balance <> 0
       or new.commission_paid
       or new.payment_status <> 'unpaid'
       or new.status <> 'pending'
       or new.delivered_at is not null then
      raise exception 'Orders are created through create_order()'
        using errcode = '42501';
    end if;

    new.created_by           := public.current_profile_id();
    new.marketing_officer_id := (select c.marketing_officer_id from public.customers c where c.id = new.customer_id);
    return new;
  end if;

  v_locked := public.changed_columns(to_jsonb(old), to_jsonb(new), array[
    'id', 'status', 'payment_status',
    'total', 'cost', 'gross_profit', 'amount_paid', 'outstanding_balance',
    'commission_paid', 'created_by', 'created_at',
    'legacy_order_ids', 'legacy_reference_id', 'delivered_at'
  ]);

  if cardinality(v_locked) > 0 then
    raise exception 'Order field(s) % are maintained by the database and cannot be written directly', v_locked
      using errcode = '42501';
  end if;

  if new.marketing_officer_id is distinct from old.marketing_officer_id then
    raise exception 'An order''s Marketing Officer follows its customer. Only a Super Admin can move it, with transfer_customer_owner().'
      using errcode = '42501';
  end if;

  v_restricted := public.changed_columns(to_jsonb(old), to_jsonb(new), array[
    'customer_id', 'order_date', 'order_type'
  ]);

  if cardinality(v_restricted) > 0 and not public.is_super_admin() then
    raise exception 'Changing % on an order needs a Super Admin: it moves revenue between customers or months', v_restricted
      using errcode = '42501';
  end if;

  if new.order_date is distinct from old.order_date and new.order_date > public.efz_today() then
    raise exception 'An order cannot be dated in the future (%)', new.order_date;
  end if;

  if new.customer_id is distinct from old.customer_id then
    if new.customer_id is null then
      raise exception 'An order must belong to a customer';
    end if;
    -- An undelivered order earns for the new customer's officer.
    if old.status not in ('delivered', 'cancelled') then
      new.marketing_officer_id := (select c.marketing_officer_id from public.customers c where c.id = new.customer_id);
    end if;
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_orders_guard on public.orders;
create trigger trg_orders_guard
  before insert or update on public.orders
  for each row execute function public.guard_orders_write();

-- Orders are created by create_order(). A direct insert can only produce an
-- empty order, so it is kept for a Super Admin's corrections only.
drop policy if exists orders_insert on public.orders;
create policy orders_insert on public.orders
  for insert to authenticated
  with check (public.is_super_admin());

-- Deletion: Super Admin, and only an order that was cancelled first (so its
-- stock is already back on the shelf) with no payments and no paid
-- commission. Anything else is cancelled, never deleted.
drop policy if exists orders_delete on public.orders;
create policy orders_delete on public.orders
  for delete to authenticated
  using (public.is_super_admin());

create or replace function public.guard_orders_delete()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if not public.is_client_request() then
    return old;
  end if;

  if old.status <> 'cancelled' then
    raise exception 'Cancel order % first so its stock is returned; only cancelled orders can be deleted', old.id
      using errcode = '42501';
  end if;

  if exists (select 1 from public.payments where order_id = old.id) then
    raise exception 'Order % has recorded payments and cannot be deleted', old.id
      using errcode = '42501';
  end if;

  if exists (select 1 from public.commissions where order_id = old.id and status = 'paid') then
    raise exception 'Order % has paid commission and cannot be deleted', old.id
      using errcode = '42501';
  end if;

  return old;
end;
$fn$;

drop trigger if exists trg_orders_guard_delete on public.orders;
create trigger trg_orders_guard_delete
  before delete on public.orders
  for each row execute function public.guard_orders_delete();

-- ============================================================================
-- 10. PRODUCTS - price and cost belong to a Super Admin or Manager
-- ----------------------------------------------------------------------------
-- adjust_stock holders move stock through adjust_stock(), a SECURITY DEFINER
-- RPC that does not need the UPDATE policy, so the policy now needs
-- edit_products alone. On top of that, selling_price and cost_price may only
-- be set by a Super Admin or a Manager: Inventory Staff keep edit_products
-- for the catalogue fields (name, description, image, threshold, active) but
-- cannot price. A product created by anyone else starts at price 0 and cost 0
-- for a manager to price.
--
-- guard_products_write() is 08's stock guard plus the pricing rule.
-- ============================================================================

drop policy if exists products_update on public.products;
create policy products_update on public.products
  for update to authenticated
  using (public.has_permission('edit_products'))
  with check (public.has_permission('edit_products'));

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

  if not public.can_manage_pricing() then
    if tg_op = 'INSERT' and (new.selling_price <> 0 or new.cost_price <> 0) then
      raise exception 'Only a Super Admin or Manager can set a product''s selling price or cost. Create it at 0 for a manager to price.'
        using errcode = '42501';
    end if;

    if tg_op = 'UPDATE' and (new.selling_price is distinct from old.selling_price
                             or new.cost_price is distinct from old.cost_price) then
      raise exception 'Only a Super Admin or Manager can change a product''s selling price or cost'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_products_guard on public.products;
create trigger trg_products_guard
  before insert or update on public.products
  for each row execute function public.guard_products_write();

-- ============================================================================
-- 11. COST VISIBILITY
-- ----------------------------------------------------------------------------
-- RLS decides rows, not columns, so hiding cost from some users takes two
-- steps:
--   a) The authenticated role loses SELECT on the cost columns themselves:
--        products.cost_price
--        orders.cost, orders.gross_profit
--        order_items.historical_unit_cost, line_cost, line_profit
--      Every other column stays selectable (listed explicitly below; a column
--      added to these tables later must be added to the grant). INSERT and
--      UPDATE privileges are unchanged - the triggers still own those values.
--   b) The reporting views that expose cost become owner-rights views that
--      re-apply the row rules themselves (can_see_order / can_see_products,
--      which mirror orders_select and products_select_staff) and return cost
--      only when can_view_cost(): view_inventory or view_reports. For anyone
--      else those columns are NULL. security_barrier stops a crafted filter
--      from peeking at rows the view hides.
--   c) staff_products is the product list for signed-in staff, cost masked the
--      same way. The app reads products through it from Phase 4.
--
-- The views keep every column name and type, so existing callers still work;
-- order_details gains delivered_at at the end. The SQL editor (a trusted
-- session) still sees every row and every cost, so validation is unchanged.
-- ============================================================================

revoke select on public.products, public.orders, public.order_items from authenticated;
revoke select on public.orders, public.order_items from anon;

grant select (
  id, name, description, category, size, durability, surface_type, is_wholesale,
  selling_price, stock, low_stock_threshold, image_url, is_active, price,
  created_at, updated_at
) on public.products to authenticated;

grant select (
  id, customer_id, customer_name, phone, marketing_officer_id, status, payment_status,
  order_type, order_date, delivery_notes, total, amount_paid, outstanding_balance,
  commission_paid, legacy_order_ids, legacy_reference_id, created_by, created_at,
  updated_at, delivered_at
) on public.orders to authenticated;

grant select (
  id, order_id, product_id, product_name, design_name, quantity,
  standard_unit_price, actual_unit_price, line_revenue, created_at
) on public.order_items to authenticated;

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

-- Row for row the same result as 04's product_sales, including how it treats
-- cancelled orders: correcting that is migration 14's job, and this file
-- changes access only.
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

-- The product list for signed-in staff: every products column, cost masked.
create or replace view public.staff_products
with (security_invoker = false, security_barrier = true) as
select
  p.id,
  p.name,
  p.description,
  p.category,
  p.size,
  p.durability,
  p.surface_type,
  p.is_wholesale,
  (case when public.can_view_cost() then p.cost_price end)::numeric(12,2) as cost_price,
  p.selling_price,
  p.stock,
  p.low_stock_threshold,
  p.image_url,
  p.is_active,
  p.price,
  p.created_at,
  p.updated_at
from public.products p
where public.can_see_products();

comment on view public.staff_products is
  'Products for signed-in staff. cost_price is NULL unless the caller holds view_inventory or view_reports.';

-- Views run with their owner's rights now; only signed-in staff may query
-- them (anon had these revoked in 08, restated so this file stands alone).
revoke all on public.order_details, public.inventory_status, public.financial_summary,
              public.daily_sales, public.product_sales, public.staff_products
  from public, anon;
grant select on public.order_details, public.inventory_status, public.financial_summary,
                public.daily_sales, public.product_sales, public.staff_products
  to authenticated;
