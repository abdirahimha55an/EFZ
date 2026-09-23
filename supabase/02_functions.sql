-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 2 of 5 : Helper functions, triggers, and transactional RPCs
-- ============================================================================

-- ============================================================================
-- 1. GENERIC updated_at TRIGGER
-- ============================================================================

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $fn$
begin
  new.updated_at := now();
  return new;
end;
$fn$;

do $touch$
declare
  t text;
begin
  foreach t in array array[
    'profiles', 'customers', 'products', 'orders',
    'order_requests', 'commissions', 'settings'
  ]
  loop
    execute format('drop trigger if exists trg_%1$s_updated_at on public.%1$s', t);
    execute format(
      'create trigger trg_%1$s_updated_at before update on public.%1$s
         for each row execute function public.set_updated_at()', t);
  end loop;
end;
$touch$;

-- ============================================================================
-- 2. AUTH HELPERS (used by every RLS policy in 03_rls.sql)
-- ----------------------------------------------------------------------------
-- All are SECURITY DEFINER so that policies on `profiles` do not recurse into
-- themselves when they call these.
-- ============================================================================

-- The text profile id ('u-1') of the currently authenticated auth.users row.
create or replace function public.current_profile_id()
returns text
language sql
stable
security definer
set search_path = public
as $fn$
  select p.id
    from public.profiles p
   where p.auth_user_id = auth.uid()
   limit 1;
$fn$;

create or replace function public.current_profile_role()
returns public.user_role
language sql
stable
security definer
set search_path = public
as $fn$
  select p.role
    from public.profiles p
   where p.auth_user_id = auth.uid()
   limit 1;
$fn$;

create or replace function public.is_super_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1 from public.profiles p
     where p.auth_user_id = auth.uid()
       and p.role = 'Super Admin'
       and p.status = 'active'
  );
$fn$;

-- Mirrors storage.hasPermission(): Super Admin always passes, everyone else
-- must hold the permission and be active.
create or replace function public.has_permission(perm text)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1
      from public.profiles p
     where p.auth_user_id = auth.uid()
       and p.status = 'active'
       and (
         p.role = 'Super Admin'
         or exists (
           select 1 from public.user_permissions up
            where up.user_id = p.id
              and up.permission_code = perm
         )
       )
  );
$fn$;

create or replace function public.has_any_permission(perms text[])
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1
      from public.profiles p
     where p.auth_user_id = auth.uid()
       and p.status = 'active'
       and (
         p.role = 'Super Admin'
         or exists (
           select 1 from public.user_permissions up
            where up.user_id = p.id
              and up.permission_code = any(perms)
         )
       )
  );
$fn$;

-- ---------------------------------------------------------------------------
-- require_permission / require_any_permission
--
-- The RPCs below are SECURITY DEFINER, which means they run past RLS. These
-- guards are therefore the ONLY thing standing between a signed-in user and an
-- operation they are not entitled to - every RPC that mutates data must open
-- with one.
--
-- A null auth.uid() means the caller is service_role or a direct SQL session
-- (a migration, an import, psql). Those are already trusted, and `anon` is
-- revoked from executing the RPCs in 03_rls.sql, so it can never reach here.
-- ---------------------------------------------------------------------------

create or replace function public.require_permission(perm text)
returns void
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null then
    return;
  end if;

  if not public.has_permission(perm) then
    raise exception 'Permission denied: % is required', perm using errcode = '42501';
  end if;
end;
$fn$;

create or replace function public.require_any_permission(perms text[])
returns void
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null then
    return;
  end if;

  if not public.has_any_permission(perms) then
    raise exception 'Permission denied: one of % is required', perms using errcode = '42501';
  end if;
end;
$fn$;

-- ============================================================================
-- 3. AUTH.USERS -> PROFILES LINKING
-- ----------------------------------------------------------------------------
-- When someone signs up (or an admin invites them) we attach the new auth user
-- to the matching profile by email. If no profile exists we create one that is
-- INACTIVE, so an unknown signup cannot act until an admin activates it.
-- ============================================================================

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_profile_id text;
begin
  select id into v_profile_id
    from public.profiles
   where lower(email) = lower(new.email)
   limit 1;

  if v_profile_id is not null then
    update public.profiles
       set auth_user_id = new.id,
           updated_at   = now()
     where id = v_profile_id;
  else
    insert into public.profiles (id, auth_user_id, name, email, role, status)
    values (
      'u-' || replace(new.id::text, '-', ''),
      new.id,
      coalesce(nullif(new.raw_user_meta_data ->> 'name', ''), split_part(new.email, '@', 1)),
      new.email,
      'Marketing Officer',
      'inactive'
    );
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_on_auth_user_created on auth.users;
create trigger trg_on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- ============================================================================
-- 4. ORDER FINANCIAL RECALCULATION
-- ----------------------------------------------------------------------------
-- orders.total / cost / gross_profit are derived from order_items.
-- orders.amount_paid / outstanding_balance / payment_status from payments.
-- Nothing else should ever write these columns.
-- ============================================================================

create or replace function public.recalc_order_financials(p_order_id text)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_total       numeric(14,2);
  v_cost        numeric(14,2);
  v_paid        numeric(14,2);
  v_outstanding numeric(14,2);
  v_status      public.payment_status;
begin
  select coalesce(sum(line_revenue), 0), coalesce(sum(line_cost), 0)
    into v_total, v_cost
    from public.order_items
   where order_id = p_order_id;

  select coalesce(sum(amount), 0)
    into v_paid
    from public.payments
   where order_id = p_order_id;

  v_paid        := least(v_paid, v_total);
  v_outstanding := greatest(v_total - v_paid, 0);

  v_status := case
    when v_total <= 0 then 'paid'
    when v_paid  <= 0 then 'unpaid'
    when v_paid >= v_total then 'paid'
    else 'partial'
  end;

  update public.orders
     set total               = v_total,
         cost                = v_cost,
         gross_profit        = v_total - v_cost,
         amount_paid         = v_paid,
         outstanding_balance = v_outstanding,
         -- 'refunded' and 'credit' are set manually and must not be overwritten
         payment_status      = case
                                 when payment_status in ('refunded', 'credit')
                                 then payment_status
                                 else v_status
                               end,
         updated_at          = now()
   where id = p_order_id;
end;
$fn$;

create or replace function public.trg_recalc_order_financials()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  perform public.recalc_order_financials(
    case when tg_op = 'DELETE' then old.order_id else new.order_id end
  );
  return null;
end;
$fn$;

drop trigger if exists trg_order_items_recalc on public.order_items;
create trigger trg_order_items_recalc
  after insert or update or delete on public.order_items
  for each row execute function public.trg_recalc_order_financials();

drop trigger if exists trg_payments_recalc on public.payments;
create trigger trg_payments_recalc
  after insert or update or delete on public.payments
  for each row execute function public.trg_recalc_order_financials();

-- ============================================================================
-- 5. COMMISSION LEDGER
-- ----------------------------------------------------------------------------
-- Eligible statuses match ELIGIBLE_STATUSES in the admin UI:
--   'confirmed', 'processing', 'delivered'
-- A commission that has already been paid is frozen and never recalculated.
-- ============================================================================

create or replace function public.sync_order_commission()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_rate     numeric(5,2);
  v_eligible boolean;
begin
  v_eligible := new.status in ('confirmed', 'processing', 'delivered')
                and new.marketing_officer_id is not null;

  if not v_eligible then
    update public.commissions
       set status     = 'void',
           amount     = 0,
           updated_at = now()
     where order_id = new.id
       and status <> 'paid';
    return new;
  end if;

  select commission_percentage
    into v_rate
    from public.profiles
   where id = new.marketing_officer_id;

  v_rate := coalesce(v_rate, 0);

  insert into public.commissions (order_id, user_id, rate, base_amount, amount, status)
  values (
    new.id,
    new.marketing_officer_id,
    v_rate,
    new.total,
    round(new.total * v_rate / 100.0, 2),
    'pending'
  )
  on conflict (order_id, user_id) do update
     set base_amount = excluded.base_amount,
         rate        = case when commissions.status = 'paid' then commissions.rate   else excluded.rate   end,
         amount      = case when commissions.status = 'paid' then commissions.amount else excluded.amount end,
         status      = case when commissions.status = 'paid' then 'paid'::public.commission_status else 'pending'::public.commission_status end,
         updated_at  = now();

  return new;
end;
$fn$;

drop trigger if exists trg_orders_commission on public.orders;
create trigger trg_orders_commission
  after insert or update of status, total, marketing_officer_id on public.orders
  for each row execute function public.sync_order_commission();

-- Keep profiles.*_commission_total columns in step with the ledger.
create or replace function public.refresh_profile_commission_totals(p_user_id text)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_earned numeric(14,2);
  v_paid   numeric(14,2);
begin
  select coalesce(sum(amount) filter (where status in ('pending', 'approved', 'paid')), 0),
         coalesce(sum(amount) filter (where status = 'paid'), 0)
    into v_earned, v_paid
    from public.commissions
   where user_id = p_user_id;

  update public.profiles
     set earned_commission_total  = v_earned,
         paid_commission_total    = v_paid,
         pending_commission_total = greatest(v_earned - v_paid, 0),
         updated_at               = now()
   where id = p_user_id;
end;
$fn$;

create or replace function public.trg_refresh_commission_totals()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if tg_op = 'DELETE' then
    perform public.refresh_profile_commission_totals(old.user_id);
  else
    perform public.refresh_profile_commission_totals(new.user_id);
    if tg_op = 'UPDATE' and old.user_id is distinct from new.user_id then
      perform public.refresh_profile_commission_totals(old.user_id);
    end if;

    -- Mirror the ledger onto the order's lock flag used by the admin UI.
    update public.orders o
       set commission_paid = exists (
             select 1 from public.commissions c
              where c.order_id = o.id and c.status = 'paid'
           )
     where o.id = new.order_id;
  end if;

  return null;
end;
$fn$;

drop trigger if exists trg_commissions_totals on public.commissions;
create trigger trg_commissions_totals
  after insert or update or delete on public.commissions
  for each row execute function public.trg_refresh_commission_totals();

-- ============================================================================
-- 6. TRANSACTIONAL RPCs
-- ----------------------------------------------------------------------------
-- These run as one transaction each, so an order can never be half-written
-- with stock half-deducted - the exact failure mode localStorage allowed.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- create_order(payload jsonb) -> order id
--
-- payload shape (camelCase, matching lib/types Order):
-- {
--   "id": "ORD-1234567",            -- optional, generated when absent
--   "customerId": "cust-...",
--   "customerName": "Sky Dome",
--   "phone": "615934772",
--   "marketingOfficerId": "u-...",  -- optional, falls back to the customer's
--   "orderType": "regular",
--   "orderDate": "2026-09-14",
--   "deliveryNotes": "",
--   "status": "pending",
--   "items": [
--     { "productId": "prod-...", "quantity": 2, "actualUnitPrice": 10 }
--   ]
-- }
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- record_payment(...) -> payment id
-- Rejects overpayment, exactly like storage.addPaymentToOrder().
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- update_order_status(...)
-- Enforces ORDER_STATUS_TRANSITIONS. Super Admins may override any transition.
-- Cancelling restores stock; reactivating a cancelled order deducts it again.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- adjust_stock(...) -> movement id
-- The only supported way to change products.stock outside of an order.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- pay_commissions(...) -> payout id
-- Settles a set of pending commissions for one officer in a single payout.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- set_user_permissions(...)
-- Replaces a user's whole permission set in one call.
-- ---------------------------------------------------------------------------
create or replace function public.set_user_permissions(
  p_user_id text,
  p_codes   text[]
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  perform public.require_permission('manage_users');

  delete from public.user_permissions
   where user_id = p_user_id
     and permission_code <> all(coalesce(p_codes, array[]::text[]));

  insert into public.user_permissions (user_id, permission_code)
  select p_user_id, code
    from public.permissions
   where code = any(coalesce(p_codes, array[]::text[]))
  on conflict do nothing;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- convert_order_request(...) -> order id
-- Turns a public website submission into a real order.
-- ---------------------------------------------------------------------------
create or replace function public.convert_order_request(
  p_request_id  uuid,
  p_customer_id text
)
returns text
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_request public.order_requests%rowtype;
  v_order_id text;
begin
  perform public.require_permission('create_orders');

  select * into v_request from public.order_requests where id = p_request_id for update;
  if not found then
    raise exception 'Unknown order request: %', p_request_id;
  end if;

  if v_request.status = 'converted' then
    raise exception 'Order request % has already been converted', p_request_id;
  end if;

  v_order_id := public.create_order(jsonb_build_object(
    'customerId',   p_customer_id,
    'customerName', v_request.customer_name,
    'phone',        v_request.phone,
    'deliveryNotes', trim(both from v_request.delivery_location || ' ' || v_request.notes),
    'items', jsonb_build_array(jsonb_build_object(
      'productId', v_request.product_id,
      'quantity',  v_request.quantity
    ))
  ));

  update public.order_requests
     set status             = 'converted',
         converted_order_id = v_order_id,
         handled_by         = public.current_profile_id(),
         updated_at         = now()
   where id = p_request_id;

  return v_order_id;
end;
$fn$;
