-- =============================================================================
-- 29b. Dispatched status behaviour + live customer order updates (Supabase Realtime)
-- Run AFTER 29a_dispatch_enum.sql has been committed (a new enum label cannot be used in the transaction that adds it).
--
-- WHAT CHANGES
--  1. Order flow gains one step: pending -> confirmed -> processing -> dispatched -> delivered (partially_delivered still follows recorded deliveries;
--     cancelled is still available before delivery). processing -> delivered stays valid, so existing workflows and orders are untouched.
--     update_order_status() stamps dispatched_at / dispatched_by and the existing system_logs audit line records who, when and the optional details (reason).
--  2. Status-dependent logic learns the new status (written as exact replacements of the live definitions, each guarded by an md5 check):
--     deliver_order_internal (a dispatched order accepts deliveries), sync_order_commission (still commission-eligible), transfer_customer_owner (still an open order),
--     guard_orders_write (dispatched_at / dispatched_by are database-maintained), correct_delivered_quantity (back to dispatched, not processing, if deliveries are corrected to 0).
--  3. my_orders() also returns confirmedAt and dispatchedAt (real timestamps only; null when never recorded).
--  4. Live updates: a trigger sends a MINIMAL private Realtime broadcast (order id, status, three timestamps; no money, no cost) to the topic
--     'customer-orders:<customer id>' whenever an order is created or its status / payment status / confirm / dispatch / delivery time changes. A policy on
--     realtime.messages lets an authenticated user receive ONLY the topic of their own approved customer id. The app refetches my_orders() on every message.
-- NOT CHANGED: no existing order, no historical dispatch time (dispatched_at stays null), no price, no stock rule, no RLS on public tables.
-- ROLLBACK: supabase/rollback/29_dispatch_rollback.sql
-- =============================================================================
begin;

do $pre$
declare v_md5 text;
begin
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'order_status' and e.enumlabel = 'dispatched') then
    raise exception 'Run 29a_dispatch_enum.sql first (order_status has no dispatched label)';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'orders' and column_name = 'dispatched_at') then
    raise exception 'Run 29a_dispatch_enum.sql first (orders.dispatched_at is missing)';
  end if;
  if to_regprocedure('realtime.send(jsonb,text,text,boolean)') is null then raise exception 'Supabase Realtime (realtime.send) is not available in this project'; end if;
    select md5(p.prosrc) into v_md5 from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'update_order_status';
    if v_md5 is distinct from '5a43e0acdf3b9a9ea7668334d753bc29' then raise exception 'update_order_status is not the expected definition (md5 %); refusing to replace it', v_md5; end if;
    select md5(p.prosrc) into v_md5 from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'guard_orders_write';
    if v_md5 is distinct from 'ff206ab922a3781a1f2516c4236ce16c' then raise exception 'guard_orders_write is not the expected definition (md5 %); refusing to replace it', v_md5; end if;
    select md5(p.prosrc) into v_md5 from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'deliver_order_internal';
    if v_md5 is distinct from '73ad332fd466b672d28fc40d070733ec' then raise exception 'deliver_order_internal is not the expected definition (md5 %); refusing to replace it', v_md5; end if;
    select md5(p.prosrc) into v_md5 from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'sync_order_commission';
    if v_md5 is distinct from 'b60b769d150eb6acfcfa206148ba7720' then raise exception 'sync_order_commission is not the expected definition (md5 %); refusing to replace it', v_md5; end if;
    select md5(p.prosrc) into v_md5 from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'transfer_customer_owner';
    if v_md5 is distinct from 'aadc6d69293d767ec2282eedb8dfddd3' then raise exception 'transfer_customer_owner is not the expected definition (md5 %); refusing to replace it', v_md5; end if;
    select md5(p.prosrc) into v_md5 from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'correct_delivered_quantity';
    if v_md5 is distinct from 'b8b58f459c5a71497f1a3fc091a9bbb6' then raise exception 'correct_delivered_quantity is not the expected definition (md5 %); refusing to replace it', v_md5; end if;
    select md5(p.prosrc) into v_md5 from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'my_orders';
    if v_md5 is distinct from '4dc43b4c60fbcd2cb2b4581f9f051ef9' then raise exception 'my_orders is not the expected definition (md5 %); refusing to replace it', v_md5; end if;
end
$pre$;

-- update_order_status
CREATE OR REPLACE FUNCTION public.update_order_status(p_order_id text, p_status order_status, p_reason text DEFAULT ''::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order     public.orders%rowtype;
  v_allowed   text[];
  v_actor     text    := public.current_profile_id();
  v_elevated  boolean := public.is_elevated_caller();
  v_reason    text    := nullif(btrim(coalesce(p_reason, '')), '');
  v_override  boolean := false;
  v_locked    boolean;
  v_item      record;
  v_from      text;
  v_to        text    := p_status::text;
  v_delivered integer;
  v_model     text;
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

  v_from := v_order.status::text;
  if v_from = v_to then
    return;
  end if;

  -- 12: a partial delivery is recorded with its quantities.
  if v_to = 'partially_delivered' then
    raise exception 'Record a partial delivery with record_delivery() and the delivered quantities';
  end if;

  -- 12: once balls are delivered, the status follows the delivered quantities. It
  -- changes only by delivering the rest, or (Super Admin) correct_delivered_quantity().
  v_delivered := public.order_delivered_quantity(p_order_id);
  if v_delivered > 0 and v_to <> 'delivered' then
    raise exception 'Order % has % delivered ball(s). Correct the delivered quantities with correct_delivered_quantity() first.',
      p_order_id, v_delivered
      using errcode = '42501';
  end if;

  v_allowed := case v_from
    when 'pending'             then array['confirmed', 'cancelled']
    when 'confirmed'           then array['processing', 'cancelled']
    when 'processing'          then array['dispatched', 'delivered', 'cancelled']
    when 'dispatched'          then array['delivered', 'cancelled']
    when 'partially_delivered' then array['delivered']
    else array[]::text[]
  end;

  if not (v_to = any(v_allowed)) then
    if not v_elevated then
      raise exception 'Illegal status transition % -> %. Super Admin override required.', v_from, v_to
        using errcode = '42501';
    end if;
    if v_reason is null then
      raise exception 'A reason is required to override % -> %', v_from, v_to;
    end if;
    v_override := true;
  end if;

  v_locked := v_order.amount_paid > 0
              or v_order.commission_paid
              or exists (select 1 from public.payments where order_id = p_order_id);

  if v_to = 'cancelled' and v_locked then
    if not v_elevated then
      raise exception 'Order % has payments or paid commission. Only a Super Admin can cancel it.', p_order_id
        using errcode = '42501';
    end if;
    if v_reason is null then
      raise exception 'A reason is required to cancel order %, which has payments or paid commission', p_order_id;
    end if;
  end if;

  -- Orders whose stock left at creation (taken before 12) get it back when
  -- cancelled, and lose it again when reactivated. Orders taken from 12 on
  -- move stock only at delivery, and nothing is delivered here.
  if v_to = 'cancelled' and v_order.stock_mode = 'at_creation' then
    for v_item in
      select product_id, product_name, quantity
        from public.order_items
       where order_id = p_order_id and product_id is not null
    loop
      update public.products set stock = stock + v_item.quantity where id = v_item.product_id;
      insert into public.stock_movements (id, product_id, product_name, type, quantity_change, reason, created_by)
      values ('mv-' || replace(gen_random_uuid()::text, '-', ''), v_item.product_id, v_item.product_name, 'return',
              v_item.quantity, 'Order ' || p_order_id || ' cancelled', v_actor);
    end loop;
  end if;

  if v_from = 'cancelled' and v_order.stock_mode = 'at_creation' then
    for v_item in
      select oi.product_id, oi.product_name, oi.quantity, p.stock
        from public.order_items oi
        join public.products p on p.id = oi.product_id
       where oi.order_id = p_order_id
       for update of p
    loop
      if v_item.stock < v_item.quantity then
        raise exception 'Cannot reactivate: only % of % left in stock', v_item.stock, v_item.product_name;
      end if;
      update public.products set stock = stock - v_item.quantity where id = v_item.product_id;
      insert into public.stock_movements (id, product_id, product_name, type, quantity_change, reason, created_by)
      values ('mv-' || replace(gen_random_uuid()::text, '-', ''), v_item.product_id, v_item.product_name, 'correction',
              -v_item.quantity, 'Order ' || p_order_id || ' reactivated', v_actor);
    end loop;
  end if;

  -- 12: the commission model is fixed at the first confirmation (or any later
  -- step reached directly by an override) and never changes afterwards.
  if v_to in ('confirmed', 'processing', 'dispatched', 'delivered')
     and not exists (select 1 from public.order_commission_class where order_id = p_order_id) then
    v_model := public.classify_order_commission(p_order_id);
  end if;

  if v_to = 'delivered' then
    -- Delivers everything still outstanding as one delivery (sets the status).
    perform public.deliver_order_internal(p_order_id, null, coalesce(v_reason, ''), null, true);
  else
    update public.orders
       set status = p_status, updated_at = now(),
           cancelled_at = case when v_to = 'cancelled' then now() else cancelled_at end,
           -- 29: the real dispatch moment and who recorded it; moving an order back before dispatch clears it (the audit log keeps the history)
           dispatched_at = case when v_to = 'dispatched' then now() when v_to in ('pending', 'confirmed', 'processing') then null else dispatched_at end,
           dispatched_by = case when v_to = 'dispatched' then v_actor when v_to in ('pending', 'confirmed', 'processing') then null else dispatched_by end
     where id = p_order_id;
  end if;

  if v_to = 'cancelled' then
    perform public.bonus_on_order_cancelled(p_order_id);
  end if;
  if v_model is not null and v_order.order_type <> 'trial' then
    perform public.bonus_refresh(v_order.customer_id);
  end if;

  insert into public.system_logs (id, severity, category, message, user_id, target_id, metadata)
  values (
    'log-' || replace(gen_random_uuid()::text, '-', ''),
    case when v_override or (v_to = 'cancelled' and v_locked) then 'WARNING' else 'INFO' end::public.log_severity,
    'ORDER',
    format('Order %s status changed from %s to %s%s', p_order_id, v_from, v_to,
           case when v_override then ' (Super Admin override)' else '' end),
    v_actor, p_order_id,
    jsonb_build_object('source', 'db', 'from', v_from, 'to', v_to,
                       'override', v_override, 'reason', coalesce(v_reason, ''),
                       'commissionModel', coalesce(v_model, (select model from public.order_commission_class where order_id = p_order_id)))
  );
end;
$function$;

-- guard_orders_write
CREATE OR REPLACE FUNCTION public.guard_orders_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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
       or new.delivered_at is not null
       or new.confirmed_at is not null
       or new.cancelled_at is not null then
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
    'legacy_order_ids', 'legacy_reference_id', 'delivered_at',
    'confirmed_at', 'cancelled_at', 'stock_mode', 'dispatched_at', 'dispatched_by'
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
$function$;

-- deliver_order_internal
CREATE OR REPLACE FUNCTION public.deliver_order_internal(p_order_id text, p_lines jsonb, p_note text, p_request_id uuid, p_any_open_status boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order       public.orders%rowtype;
  v_lines       jsonb;
  v_req         jsonb;
  v_item        public.order_items%rowtype;
  v_product     public.products%rowtype;
  v_qty_raw     numeric;
  v_qty         integer;
  v_remaining   integer;
  v_delivery_id uuid;
  v_units       integer := 0;
  v_balls       integer := 0;
  v_all_done    boolean;
  v_model       text;
  v_rate        numeric(6,2);
  v_actor       text := public.current_profile_id();
  v_actor_name  text := coalesce(public.current_profile_name(), '');
  v_ordered     integer;
  v_delivered   integer;
  v_withheld    boolean := false;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'Unknown order: %', p_order_id;
  end if;
  if v_order.status = 'cancelled' then
    raise exception 'Order % is cancelled; nothing can be delivered', p_order_id;
  end if;
  if not p_any_open_status and v_order.status::text not in ('processing', 'dispatched', 'partially_delivered') then
    raise exception 'Order % is %: move it to processing before recording deliveries', p_order_id, v_order.status;
  end if;

  if p_lines is null then
    select jsonb_agg(jsonb_build_object('orderItemId', oi.id, 'quantity', oi.quantity - public.item_delivered_quantity(oi.id)) order by oi.created_at, oi.id)
      into v_lines
      from public.order_items oi
     where oi.order_id = p_order_id and oi.quantity > public.item_delivered_quantity(oi.id);
    if v_lines is null then
      raise exception 'Order % has nothing left to deliver', p_order_id;
    end if;
  else
    if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then
      raise exception 'A delivery needs at least one order line with a quantity';
    end if;
    v_lines := p_lines;
  end if;

  insert into public.order_deliveries (order_id, delivered_at, recorded_by, recorded_by_name, source, request_id, note)
  values (p_order_id, now(), v_actor, v_actor_name, 'delivery', p_request_id, coalesce(p_note, ''))
  returning id into v_delivery_id;

  for v_req in select * from jsonb_array_elements(v_lines)
  loop
    select * into v_item from public.order_items
     where id = v_req ->> 'orderItemId' and order_id = p_order_id
     for update;
    if not found then
      raise exception 'Order line % does not belong to order %', v_req ->> 'orderItemId', p_order_id;
    end if;
    v_qty_raw := (v_req ->> 'quantity')::numeric;
    if v_qty_raw is null or v_qty_raw < 1 or v_qty_raw <> trunc(v_qty_raw) then
      raise exception 'Delivered quantity for % must be a whole number of at least 1 (got %)', v_item.product_name, v_req ->> 'quantity';
    end if;
    v_qty := v_qty_raw::integer;
    v_remaining := v_item.quantity - public.item_delivered_quantity(v_item.id);
    if v_qty > v_remaining then
      raise exception 'Only % of % ball(s) of % remain to be delivered on order % (tried %)',
        v_remaining, v_item.quantity, v_item.product_name, p_order_id, v_qty;
    end if;

    insert into public.order_delivery_lines (delivery_id, order_id, order_item_id, quantity)
    values (v_delivery_id, p_order_id, v_item.id, v_qty);

    if v_order.stock_mode = 'at_delivery' and v_item.product_id is not null then
      select * into v_product from public.products where id = v_item.product_id for update;
      if v_product.stock < v_qty then
        raise exception 'Insufficient stock to deliver %: % in stock, % to deliver', v_product.name, v_product.stock, v_qty;
      end if;
      update public.products set stock = stock - v_qty where id = v_product.id;
      insert into public.stock_movements (id, product_id, product_name, type, quantity_change, reason, created_by)
      values ('mv-' || replace(gen_random_uuid()::text, '-', ''), v_product.id, v_product.name, 'sale', -v_qty,
              'Order ' || p_order_id || ' delivery ' || left(v_delivery_id::text, 8), v_actor);
    end if;

    v_balls := v_balls + v_qty;
    if exists (select 1 from public.products p where p.id = v_item.product_id and p.category = 'Football') then
      v_units := v_units + v_qty;
    end if;
  end loop;

  select coalesce(sum(oi.quantity), 0), coalesce(sum(public.item_delivered_quantity(oi.id)), 0)
    into v_ordered, v_delivered
    from public.order_items oi where oi.order_id = p_order_id;
  v_all_done := v_delivered >= v_ordered;

  update public.orders
     set status       = (case when v_all_done then 'delivered' else 'partially_delivered' end)::public.order_status,
         delivered_at = case when v_all_done then coalesce(delivered_at, now()) else delivered_at end,
         updated_at   = now()
   where id = p_order_id;

  select model into v_model from public.order_commission_class where order_id = p_order_id;
  if v_model = 'per_ball_v1' and v_order.marketing_officer_id is not null and v_units > 0 then
    select per_ball_rate into v_rate from public.commission_policy where id;
    -- 16: the officer's commission eligibility at this delivery decides. OFF: this
    -- delivery earns no commission (recorded as withheld); nothing is back-filled later.
    if public.commission_gate(v_order.marketing_officer_id) then
      insert into public.commissions (order_id, user_id, rate, base_amount, amount, status,
                                      rule_version, kind, delivery_id, units, per_ball_rate, earned_at)
      values (p_order_id, v_order.marketing_officer_id, 0, 0, round(v_units * v_rate, 2), 'pending',
              'per_ball_v1', 'delivery', v_delivery_id, v_units, v_rate, now());
    else
      v_withheld := true;
      perform public.commission_withheld(p_order_id, v_order.marketing_officer_id, 'delivery', v_delivery_id, null,
                                         v_units, v_rate, round(v_units * v_rate, 2));
    end if;
  end if;

  if v_all_done and v_model = 'per_ball_v1' then
    perform public.bonus_award_on_full_delivery(p_order_id);
  end if;

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'ORDER',
          format('Delivery recorded on order %s: %s ball(s), %s of %s delivered%s',
                 p_order_id, v_balls, v_delivered, v_ordered, case when v_all_done then ' (complete)' else '' end),
          v_actor, v_actor_name, p_order_id,
          jsonb_build_object('source', 'db', 'event', 'delivery_recorded', 'deliveryId', v_delivery_id,
                             'balls', v_balls, 'footballs', v_units, 'delivered', v_delivered, 'ordered', v_ordered,
                             'complete', v_all_done, 'commissionModel', v_model, 'requestId', p_request_id,
                             'commissionWithheld', v_withheld));
  return v_delivery_id;
end;
$function$;

-- sync_order_commission
CREATE OR REPLACE FUNCTION public.sync_order_commission()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_model    text;
  v_row      public.commissions%rowtype;
  v_rate     numeric(5,2);
  v_eligible boolean;
begin
  select model into v_model from public.order_commission_class where order_id = new.id;
  if v_model is distinct from 'legacy_percent' then
    -- Per-ball commission is written by record_delivery() / correct_delivered_quantity();
    -- an order that was never confirmed earns nothing yet.
    return new;
  end if;

  select * into v_row
    from public.commissions
   where order_id = new.id and kind = 'legacy'
   order by (status = 'void'), created_at desc
   limit 1
   for update;

  if new.status = 'cancelled' then
    update public.commissions
       set status = 'void', voided_at = now(), updated_at = now(), void_reason = 'Order cancelled'
     where order_id = new.id and kind = 'legacy' and status in ('pending', 'approved');
    update public.commissions
       set review_required = true, updated_at = now(),
           review_reason = 'Order cancelled after this commission was paid - manual review, no clawback'
     where order_id = new.id and kind = 'legacy' and status = 'paid' and not review_required;
    return new;
  end if;

  v_eligible := new.status::text in ('confirmed', 'processing', 'dispatched', 'partially_delivered', 'delivered')
                and new.marketing_officer_id is not null;
  if not v_eligible then
    return new;
  end if;

  if v_row.id is null then
    -- 16 (E7): a legacy commission withheld once (officer OFF at its first eligible
    -- moment) is never created later.
    if exists (select 1 from public.commission_withheld_events w where w.order_id = new.id and w.kind = 'legacy') then
      return new;
    end if;
    -- First eligible moment: the officer's rate today is frozen on the row.
    select commission_percentage into v_rate from public.profiles where id = new.marketing_officer_id;
    v_rate := coalesce(v_rate, 0);
    if not public.commission_gate(new.marketing_officer_id) then
      perform public.commission_withheld(new.id, new.marketing_officer_id, 'legacy', null, null,
                                         null, v_rate, round(new.total * v_rate / 100.0, 2));
      return new;
    end if;
    insert into public.commissions (order_id, user_id, rate, base_amount, amount, status, rule_version, kind)
    values (new.id, new.marketing_officer_id, v_rate, new.total, round(new.total * v_rate / 100.0, 2),
            'pending', 'legacy_percent', 'legacy')
    on conflict (order_id, user_id) where kind = 'legacy' do nothing;
    return new;
  end if;

  if tg_op = 'UPDATE' and old.status = 'cancelled' and v_row.status = 'void' then
    -- 16 (E6): with the commission's officer OFF it stays void, flagged for review.
    if not public.commission_gate(v_row.user_id) then
      update public.commissions
         set review_required = true, updated_at = now(),
             review_reason = 'Order reactivated while the officer''s commission eligibility was OFF - commission stays void (manual review)'
       where id = v_row.id and not review_required;
      insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
      values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'WARNING', 'FINANCIAL',
              format('Commission review required: order %s reactivated while officer %s commission eligibility is OFF; the commission stays void', new.id, v_row.user_id),
              public.current_profile_id(), coalesce(public.current_profile_name(), ''), new.id,
              jsonb_build_object('source', 'db', 'event', 'commission_review_required', 'commissionId', v_row.id,
                                 'officerId', v_row.user_id, 'reason', 'reactivated_while_ineligible'));
      return new;
    end if;
    -- Reactivated by a Super Admin override: the commission comes back, original rate.
    update public.commissions
       set status = 'pending', voided_at = null, void_reason = '', updated_at = now(),
           base_amount = new.total, amount = round(new.total * v_row.rate / 100.0, 2)
     where id = v_row.id;
    return new;
  end if;

  -- D6: edited before delivery -> recalculate with the ORIGINAL rate.
  if tg_op = 'UPDATE' and new.total is distinct from old.total then
    if v_row.status in ('pending', 'approved') and new.status::text in ('confirmed', 'processing', 'dispatched') then
      update public.commissions
         set base_amount = new.total, amount = round(new.total * v_row.rate / 100.0, 2), updated_at = now()
       where id = v_row.id;
    elsif v_row.status = 'paid' then
      update public.commissions
         set review_required = true, updated_at = now(),
             review_reason = 'Order total changed after this commission was paid - manual review'
       where id = v_row.id and not review_required;
    end if;
  end if;

  -- D7: an officer change (customer transfer) never moves a legacy commission.
  return new;
end;
$function$;

-- transfer_customer_owner
CREATE OR REPLACE FUNCTION public.transfer_customer_owner(p_customer_id text, p_new_officer_id text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
       and status::text in ('pending', 'confirmed', 'processing', 'dispatched', 'partially_delivered')
       and marketing_officer_id is distinct from p_new_officer_id
    returning id
  )
  select coalesce(array_agg(id order by id), array[]::text[]) into v_moved from moved;

  -- 12 (D7): a transfer never moves or voids commission already recorded. A legacy
  -- order confirmed before the transfer keeps its commission with the original
  -- officer; balls delivered later on a per-ball order earn for the new officer.

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
$function$;

-- correct_delivered_quantity
CREATE OR REPLACE FUNCTION public.correct_delivered_quantity(p_order_item_id text, p_new_delivered integer, p_mode text, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_reason     text := nullif(btrim(coalesce(p_reason, '')), '');
  v_item       public.order_items%rowtype;
  v_order      public.orders%rowtype;
  v_product    public.products%rowtype;
  v_old_del    integer;
  v_delta      integer;
  v_new_qty    integer;
  v_stock      integer := 0;
  v_model      text;
  v_rate       numeric(6,2);
  v_before     numeric(14,2);
  v_after      numeric(14,2);
  v_expected   numeric(14,2);
  v_active     numeric(14,2);
  v_units      integer;
  v_review     boolean := false;
  v_paid       boolean;
  v_officers   integer;
  v_officer    text;
  v_fin_before jsonb;
  v_fin_after  jsonb;
  v_adj_id     uuid := gen_random_uuid();
  v_ordered    integer;
  v_delivered  integer;
  v_status     text;
  v_legacy     public.commissions%rowtype;
  v_actor      text := public.current_profile_id();
  v_actor_name text := coalesce(public.current_profile_name(), '');
  v_eligibility boolean := false;
begin
  if not public.is_elevated_caller() then
    raise exception 'Only a Super Admin can correct a delivered quantity' using errcode = '42501';
  end if;
  if v_reason is null then
    raise exception 'A written reason is required to correct a delivered quantity';
  end if;
  if p_mode is null or p_mode not in ('keep_invoice', 'reduce_invoice') then
    raise exception 'Mode must be keep_invoice (invoice unchanged, the rest stays owed on the order) or reduce_invoice (order line and invoice reduced to the corrected delivered count)';
  end if;

  select * into v_item from public.order_items where id = p_order_item_id for update;
  if not found then
    raise exception 'Unknown order line: %', p_order_item_id;
  end if;
  select * into v_order from public.orders where id = v_item.order_id for update;
  if v_order.status::text not in ('partially_delivered', 'delivered') then
    raise exception 'Order % is %: only a partially or fully delivered order can have its delivered quantity corrected',
      v_order.id, v_order.status;
  end if;

  v_old_del := public.item_delivered_quantity(v_item.id);
  if p_new_delivered is null or p_new_delivered < 0 or p_new_delivered > v_item.quantity then
    raise exception 'The corrected delivered quantity must be between 0 and the % ordered', v_item.quantity;
  end if;
  if p_mode = 'reduce_invoice' and p_new_delivered < 1 then
    raise exception 'reduce_invoice needs at least 1 delivered ball; to undo a whole line use keep_invoice (and cancel the order if nothing is delivered)';
  end if;
  if p_mode = 'keep_invoice' and p_new_delivered = v_old_del then
    raise exception 'Nothing to correct: % ball(s) are already recorded as delivered', v_old_del;
  end if;
  if p_mode = 'reduce_invoice' and p_new_delivered = v_item.quantity and p_new_delivered = v_old_del then
    raise exception 'Nothing to correct: the line is fully delivered';
  end if;

  v_delta   := p_new_delivered - v_old_del;
  v_new_qty := case when p_mode = 'reduce_invoice' then p_new_delivered else v_item.quantity end;
  select model into v_model from public.order_commission_class where order_id = v_order.id;
  v_fin_before := jsonb_build_object('total', v_order.total, 'amountPaid', v_order.amount_paid,
                                     'outstanding', v_order.outstanding_balance, 'lineQuantity', v_item.quantity);
  select coalesce(sum(amount), 0) into v_before from public.commissions where order_id = v_order.id and status <> 'void';

  -- Stock: balls leave the shelf only when delivered (at_delivery), so the
  -- delivered difference moves stock. Orders taken before 12 (at_creation) had
  -- every ordered ball deducted: closing a line short returns what will never go.
  if v_item.product_id is not null then
    v_stock := case when v_order.stock_mode = 'at_delivery' then -v_delta
                    else v_item.quantity - v_new_qty end;
    if v_stock <> 0 then
      select * into v_product from public.products where id = v_item.product_id for update;
      if v_product.stock + v_stock < 0 then
        raise exception 'Insufficient stock: % in stock, % more ball(s) needed for this correction', v_product.stock, -v_stock;
      end if;
      update public.products set stock = stock + v_stock where id = v_product.id;
      insert into public.stock_movements (id, product_id, product_name, type, quantity_change, reason, created_by)
      values ('mv-' || replace(gen_random_uuid()::text, '-', ''), v_product.id, v_product.name,
              (case when v_stock > 0 then 'return' else 'correction' end)::public.stock_movement_type, v_stock,
              format('Delivered quantity corrected on order %s: %s', v_order.id, v_reason), v_actor);
    end if;
  end if;

  -- Invoice: only reduce_invoice changes the line (total and receivable follow).
  if p_mode = 'reduce_invoice' and v_new_qty <> v_item.quantity then
    update public.order_items set quantity = v_new_qty where id = v_item.id;
  end if;

  -- Commission.
  if v_model = 'per_ball_v1' then
    select coalesce(sum(case when (oi.id = v_item.id) then p_new_delivered else public.item_delivered_quantity(oi.id) end), 0)
      into v_units
      from public.order_items oi
      join public.products p on p.id = oi.product_id
     where oi.order_id = v_order.id and p.category = 'Football';
    select per_ball_rate into v_rate from public.commission_policy where id;
    v_expected := round(v_units * v_rate, 2);
    select coalesce(sum(amount), 0), bool_or(status = 'paid'), count(distinct user_id), min(user_id)
      into v_active, v_paid, v_officers, v_officer
      from public.commissions
     where order_id = v_order.id and kind in ('delivery', 'correction') and status <> 'void';
    v_paid := coalesce(v_paid, false);
    if v_officers = 0 then
      v_officer := v_order.marketing_officer_id;
    end if;

    -- 16 (E4): a correction re-computes the whole order. If the officer's commission
    -- eligibility is OFF now, or a delivery on this order was withheld while OFF, an
    -- automatic re-issue would erase or back-fill earlier events: review instead.
    v_eligibility := v_officer is not null
                     and (not public.commission_gate(v_officer)
                          or exists (select 1 from public.commission_withheld_events w
                                      where w.order_id = v_order.id and w.kind = 'delivery'));
    if v_paid or v_officers > 1 or v_eligibility then
      -- D8: never claw back or add automatically once paid; record and flag.
      v_review := v_expected <> v_active;
      if v_review then
        update public.commissions
           set review_required = true, updated_at = now(),
               review_reason = case when v_paid or v_officers > 1
                 then format('Delivered quantity corrected after payment (adjustment %s): expected $%s, recorded $%s', v_adj_id, v_expected, v_active)
                 else format('Delivered quantity corrected while commission eligibility is involved (adjustment %s): expected $%s, recorded $%s', v_adj_id, v_expected, v_active)
               end
         where order_id = v_order.id and kind in ('delivery', 'correction') and status <> 'void';
      end if;
    elsif v_expected <> v_active then
      update public.commissions
         set status = 'void', voided_at = now(), updated_at = now(),
             void_reason = format('Superseded by delivered-quantity correction %s', v_adj_id)
       where order_id = v_order.id and kind in ('delivery', 'correction') and status <> 'void';
      if v_units > 0 and v_officer is not null then
        insert into public.commissions (order_id, user_id, rate, base_amount, amount, status,
                                        rule_version, kind, adjustment_id, units, per_ball_rate, earned_at)
        values (v_order.id, v_officer, 0, 0, v_expected, 'pending',
                'per_ball_v1', 'correction', v_adj_id, v_units, v_rate, now());
      end if;
    end if;
  elsif v_model = 'legacy_percent' and p_mode = 'reduce_invoice' then
    -- Legacy rules kept: percentage of the (reduced) order total, original rate.
    select * into v_legacy from public.commissions
     where order_id = v_order.id and kind = 'legacy' and status <> 'void'
     order by created_at desc limit 1 for update;
    if v_legacy.id is not null then
      if v_legacy.status = 'paid' then
        v_review := true;
        update public.commissions
           set review_required = true, updated_at = now(),
               review_reason = format('Order reduced by delivered-quantity correction %s after payment', v_adj_id)
         where id = v_legacy.id;
      else
        update public.commissions
           set base_amount = (select total from public.orders where id = v_order.id),
               amount = round((select total from public.orders where id = v_order.id) * v_legacy.rate / 100.0, 2),
               updated_at = now()
         where id = v_legacy.id;
      end if;
    end if;
  end if;

  -- Status follows the delivered quantities.
  select coalesce(sum(oi.quantity), 0),
         coalesce(sum(case when oi.id = v_item.id then p_new_delivered else public.item_delivered_quantity(oi.id) end), 0)
    into v_ordered, v_delivered
    from public.order_items oi where oi.order_id = v_order.id;
  v_status := case when v_delivered >= v_ordered then 'delivered'
                   when v_delivered > 0 then 'partially_delivered'
                   else (case when v_order.dispatched_at is not null then 'dispatched' else 'processing' end) end;
  update public.orders
     set status = v_status::public.order_status,
         delivered_at = case when v_status = 'delivered' then coalesce(delivered_at, now()) else delivered_at end,
         updated_at = now()
   where id = v_order.id;

  select jsonb_build_object('total', total, 'amountPaid', amount_paid, 'outstanding', outstanding_balance, 'lineQuantity', v_new_qty)
    into v_fin_after from public.orders where id = v_order.id;
  select coalesce(sum(amount), 0) into v_after from public.commissions where order_id = v_order.id and status <> 'void';

  insert into public.delivered_quantity_adjustments (
    id, order_id, order_item_id, mode, old_delivered, new_delivered, delta, old_line_quantity, new_line_quantity,
    stock_delta, commission_model, commission_before, commission_after, commission_difference, review_required,
    financial_before, financial_after, reason, actor, actor_name)
  values (
    v_adj_id, v_order.id, v_item.id, p_mode, v_old_del, p_new_delivered, v_delta, v_item.quantity, v_new_qty,
    v_stock, v_model, v_before, v_after,
    case when v_review and v_model = 'per_ball_v1' then v_expected - v_active else v_after - v_before end,
    v_review, v_fin_before, v_fin_after, v_reason, v_actor, v_actor_name);

  if v_status = 'delivered' and v_model = 'per_ball_v1' then
    perform public.bonus_award_on_full_delivery(v_order.id);
  end if;

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'WARNING', 'ORDER',
          format('Delivered quantity corrected on order %s (%s): %s -> %s ball(s), %s. Reason: %s',
                 v_order.id, v_item.product_name, v_old_del, p_new_delivered, p_mode, v_reason),
          v_actor, v_actor_name, v_order.id,
          jsonb_build_object('source', 'db', 'event', 'delivered_quantity_corrected', 'adjustmentId', v_adj_id,
                             'orderItemId', v_item.id, 'from', v_old_del, 'to', p_new_delivered, 'mode', p_mode,
                             'stockDelta', v_stock, 'commissionBefore', v_before, 'commissionAfter', v_after,
                             'reviewRequired', v_review, 'financialBefore', v_fin_before, 'financialAfter', v_fin_after));
  if v_review then
    insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
    values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'WARNING', 'FINANCIAL',
            case when v_eligibility and not (coalesce(v_paid, false) or coalesce(v_officers, 0) > 1)
                 then format('Commission review required: order %s delivered quantity corrected while commission eligibility is involved', v_order.id)
                 else format('Commission review required: order %s delivered quantity corrected after commission was paid', v_order.id) end,
            v_actor, v_actor_name, v_order.id,
            jsonb_build_object('source', 'db', 'event', 'commission_review_required', 'adjustmentId', v_adj_id));
  end if;
  return v_adj_id;
end;
$function$;

-- my_orders
CREATE OR REPLACE FUNCTION public.my_orders()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_customer text := public.require_approved_customer();
begin
  return coalesce((
    select jsonb_agg(x.obj order by x.order_date desc, x.created_at desc, x.id)
      from (
        select o.order_date, o.created_at, o.id,
               jsonb_build_object(
                 'id', o.id, 'status', o.status::text, 'paymentStatus', o.payment_status::text, 'orderType', o.order_type::text,
                 'date', o.order_date, 'total', o.total, 'amountPaid', o.amount_paid, 'outstandingBalance', o.outstanding_balance,
                 'deliveredAt', o.delivered_at, 'confirmedAt', o.confirmed_at, 'dispatchedAt', o.dispatched_at,
                 'items', coalesce((select jsonb_agg(jsonb_build_object('productName', i.product_name, 'designName', i.design_name,
                                                                         'quantity', i.quantity, 'unitPrice', i.actual_unit_price, 'lineTotal', i.line_revenue)
                                                     order by i.created_at, i.id)
                                      from public.order_items i where i.order_id = o.id), '[]'::jsonb),
                 'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'paymentDate', p.payment_date, 'amount', p.amount,
                                                                            'paymentMethod', p.payment_method, 'reference', p.reference)
                                                        order by p.payment_date, p.created_at, p.id)
                                         from public.payments p where p.order_id = o.id), '[]'::jsonb)
               ) as obj
          from public.orders o
         where o.customer_id = v_customer
      ) x
  ), '[]'::jsonb);
end;
$function$;

-- ---- live customer order updates --------------------------------------------------------------------------------------------------------------------------
create or replace function public._my_approved_customer_id()
returns text
language sql stable security definer set search_path = public
as $f$
  select a.customer_id from public.customer_accounts a
   where a.auth_user_id = auth.uid() and a.status = 'approved' and a.customer_id is not null and a.deletion_requested_at is null
$f$;
revoke all on function public._my_approved_customer_id() from public, anon;
grant execute on function public._my_approved_customer_id() to authenticated;

create or replace function public.notify_customer_order_change()
returns trigger
language plpgsql security definer set search_path = public, realtime
as $f$
begin
  begin
    perform realtime.send(
      jsonb_build_object('orderId', new.id, 'status', new.status::text, 'confirmedAt', new.confirmed_at, 'dispatchedAt', new.dispatched_at, 'deliveredAt', new.delivered_at),
      'order_changed', 'customer-orders:' || new.customer_id, true);
  exception when others then
    null;   -- a failed notification must never block an order write; the app also refetches on foreground and on a timer
  end;
  return null;
end
$f$;
revoke all on function public.notify_customer_order_change() from public, anon, authenticated;

drop trigger if exists trg_orders_notify_customer_ins on public.orders;
create trigger trg_orders_notify_customer_ins after insert on public.orders
  for each row execute function public.notify_customer_order_change();
drop trigger if exists trg_orders_notify_customer_upd on public.orders;
create trigger trg_orders_notify_customer_upd after update on public.orders
  for each row when (old.status is distinct from new.status or old.payment_status is distinct from new.payment_status
                     or old.confirmed_at is distinct from new.confirmed_at or old.dispatched_at is distinct from new.dispatched_at or old.delivered_at is distinct from new.delivered_at)
  execute function public.notify_customer_order_change();

drop policy if exists customer_orders_receive on realtime.messages;
create policy customer_orders_receive on realtime.messages for select to authenticated
  using (realtime.messages.extension = 'broadcast' and public._my_approved_customer_id() is not null and realtime.topic() = 'customer-orders:' || public._my_approved_customer_id());

commit;
