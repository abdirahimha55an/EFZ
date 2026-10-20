-- =============================================================================
-- 29e. Dispatch is an enforced stage: an order cannot be delivered until it has been dispatched.
--
-- THE BYPASS THIS CLOSES (found in the live Staging code):
--   1. update_order_status(): the normal transitions still listed  processing -> delivered  (kept in 29b so old workflows would not break).
--   2. record_delivery() -> deliver_order_internal(): a delivery was accepted on a PROCESSING order, so recording all quantities delivered the order without any status change.
-- WHAT CHANGES (two functions, exact replacements of the live definitions, each guarded by an md5 check):
--   update_order_status: processing allows only dispatched | cancelled. A non-elevated caller who asks for delivered from pending/confirmed/processing gets a clear refusal.
--     A Super Admin can still override, but only with a written reason, and the existing audit line marks it "(Super Admin override)" at WARNING level.
--   deliver_order_internal: recording a delivery needs the order to be dispatched or already partially_delivered (existing partial deliveries can be completed, so
--     nothing in flight is stranded). The Super Admin override path (update_order_status with a reason) is unchanged.
-- UNCHANGED: cancelled orders (still cancellable before delivery), partial deliveries and their commission, correct_delivered_quantity, historical orders (no status or time is touched).
-- ROLLBACK: supabase/rollback/29e_enforce_dispatch_rollback.sql
-- =============================================================================
begin;

do $pre$
declare v_md5 text;
begin
    select md5(p.prosrc) into v_md5 from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'update_order_status';
    if v_md5 is distinct from 'cb9a5600965a3f0a89c2bf7aff3e708a' then raise exception 'update_order_status is not the expected definition (md5 %); refusing to replace it', v_md5; end if;
    select md5(p.prosrc) into v_md5 from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'deliver_order_internal';
    if v_md5 is distinct from 'aaccef881132fa34a8e1102528432316' then raise exception 'deliver_order_internal is not the expected definition (md5 %); refusing to replace it', v_md5; end if;
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
    when 'processing'          then array['dispatched', 'cancelled']          -- 29e: a prepared order must be dispatched before it can be delivered
    when 'dispatched'          then array['delivered', 'cancelled']
    when 'partially_delivered' then array['delivered']
    else array[]::text[]
  end;

  if not (v_to = any(v_allowed)) then
    if not v_elevated then
      if v_to = 'delivered' and v_from in ('pending', 'confirmed', 'processing') then
        raise exception 'Order % is %: record it as dispatched before it can be delivered (only a Super Admin can override, with a reason)', p_order_id, v_from
          using errcode = '42501';
      end if;
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
  if not p_any_open_status and v_order.status::text not in ('dispatched', 'partially_delivered') then
    raise exception 'Order % is %: record it as dispatched before recording deliveries', p_order_id, v_order.status using errcode = '42501';
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

commit;
