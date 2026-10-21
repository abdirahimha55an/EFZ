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
    when 'processing'          then array['delivered', 'cancelled']
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
  if v_to in ('confirmed', 'processing', 'delivered')
     and not exists (select 1 from public.order_commission_class where order_id = p_order_id) then
    v_model := public.classify_order_commission(p_order_id);
  end if;

  if v_to = 'delivered' then
    -- Delivers everything still outstanding as one delivery (sets the status).
    perform public.deliver_order_internal(p_order_id, null, coalesce(v_reason, ''), null, true);
  else
    update public.orders
       set status = p_status, updated_at = now(),
           cancelled_at = case when v_to = 'cancelled' then now() else cancelled_at end
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
    'confirmed_at', 'cancelled_at', 'stock_mode'
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
       and status::text in ('pending', 'confirmed', 'processing', 'partially_delivered')
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
