-- ============================================================================
-- EFZ - ROLLBACK for 12_commission_model.sql
-- ----------------------------------------------------------------------------
-- SAFE ONLY BEFORE MIGRATION 12 IS USED. It refuses (and changes nothing) when
-- any of these exists, because restoring the old functions would then corrupt
-- stock or commissions: the per-ball model activated; a per-ball order; a
-- delivery recorded after 12 (not a back-fill); a delivered-quantity
-- correction; an order taken after 12 (stock at delivery); a partially
-- delivered order. In that case fix forward with a new migration instead.
--
-- When allowed it restores every function, trigger, view and policy 12 replaced
-- exactly as 02, 03, 04, 10 and 11 define them, puts back the commissions
-- unique key and the column defaults the old functions rely on, and drops the
-- functions 12 added.
--
-- Deliberately LEFT IN PLACE (additive, harmless, and partly history):
--   * the enum value 'partially_delivered' (PostgreSQL cannot drop it)
--   * orders.confirmed_at / stock_mode, the commissions columns
--   * commission_policy, order_commission_class, order_deliveries,
--     order_delivery_lines, delivered_quantity_adjustments,
--     customer_bonus_entitlements, commission_bonus_events (back-fills only)
-- Touches no business rows. Idempotent.
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
-- ----------------------------------------------------------------------------
begin;

do $chk$
begin
  if exists (select 1 from public.commission_policy where cutover_at is not null)
     or exists (select 1 from public.order_commission_class where model = 'per_ball_v1')
     or exists (select 1 from public.order_deliveries where source = 'delivery')
     or exists (select 1 from public.delivered_quantity_adjustments)
     or exists (select 1 from public.orders where stock_mode = 'at_delivery')
     or exists (select 1 from public.orders where status::text = 'partially_delivered') then
    raise exception 'ROLLBACK REFUSED: Migration 12 is already in use (activation, per-ball orders, deliveries, corrections or orders taken after 12). Nothing was changed. Fix forward with a new migration.';
  end if;
end
$chk$;

-- 1. Triggers and guards 12 added ---------------------------------------------
drop trigger if exists trg_orders_commission_ins on public.orders;
drop trigger if exists trg_orders_commission_upd on public.orders;
drop trigger if exists trg_commissions_guard on public.commissions;
drop trigger if exists trg_commissions_bonus_paid on public.commissions;
drop trigger if exists trg_order_items_delivered_guard on public.order_items;
drop trigger if exists trg_products_football on public.products;
drop trigger if exists trg_orders_bonus_recheck on public.orders;
drop trigger if exists trg_orders_bonus_history_guard on public.orders;
drop view if exists public.customer_transfer_notices;

-- 2. What 12 replaced ----------------------------------------------------------
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

drop policy if exists customers_select on public.customers;
create policy customers_select on public.customers
  for select to authenticated
  using (
    public.has_permission('view_all_customers')
    or public.has_permission('view_customers')
    or (
      public.has_permission('view_own_customers_only')
      and (
        marketing_officer_id = public.current_profile_id()
        or registered_by     = public.current_profile_id()
      )
    )
  );

drop policy if exists customers_update on public.customers;
create policy customers_update on public.customers
  for update to authenticated
  using (
    public.has_permission('edit_customers')
    and (
      public.has_permission('view_all_customers')
      or public.has_permission('view_customers')
      or marketing_officer_id = public.current_profile_id()
      or registered_by       = public.current_profile_id()
    )
  )
  with check (public.has_permission('edit_customers'));

drop policy if exists customer_ownership_changes_select on public.customer_ownership_changes;
create policy customer_ownership_changes_select on public.customer_ownership_changes
  for select to authenticated
  using (
    public.has_any_permission(array['view_all_customers', 'view_customers', 'view_audit_trail'])
    or public.can_view_all_commissions()
    or old_officer_id = public.current_profile_id()
    or new_officer_id = public.current_profile_id()
  );

-- order_details lost the 3 columns 12 appended: a view cannot drop columns in
-- place, so it is recreated and its access restored exactly as 10 sets it.
drop view if exists public.order_details;
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
revoke all on public.order_details from public, anon;
grant select on public.order_details to authenticated;

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

-- 3. Commissions key and defaults the old functions rely on -------------------
drop index if exists public.commissions_legacy_order_user_uq;
drop index if exists public.commissions_delivery_uq;
drop index if exists public.commissions_correction_uq;
drop index if exists public.commissions_bonus_customer_uq;
alter table public.commissions drop constraint if exists commissions_order_id_user_id_key;
alter table public.commissions add constraint commissions_order_id_user_id_key unique (order_id, user_id);
alter table public.commissions alter column rule_version set default 'legacy_percent';
alter table public.commissions alter column kind set default 'legacy';
alter table public.orders alter column stock_mode set default 'at_creation';

-- 4. Functions 12 added ---------------------------------------------------------
drop function if exists public.record_delivery(text, jsonb, text, uuid);
drop function if exists public.correct_delivered_quantity(text, integer, text, text);
drop function if exists public.activate_commission_model(text);
drop function if exists public.approve_bonus_timing(text);
drop function if exists public.deliver_order_internal(text, jsonb, text, uuid, boolean);
drop function if exists public.classify_order_commission(text);
drop function if exists public.bonus_award_on_full_delivery(text);
drop function if exists public.bonus_on_order_cancelled(text);
drop function if exists public.trg_bonus_paid();
drop function if exists public.trg_orders_bonus_recheck();
drop function if exists public.guard_orders_bonus_history();
drop function if exists public.guard_commissions_write();
drop function if exists public.guard_order_items_delivered();
drop function if exists public.guard_products_football();

commit;
