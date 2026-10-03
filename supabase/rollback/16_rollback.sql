-- EFZ - rollback of 16_commission_eligibility.sql.
-- Restores the five replaced functions EXACTLY as deployed before 16 (Production backup
-- 20261003-174012Z), removes the eligibility gate, trigger, view and functions.
-- KEPT on purpose (evidence, no data is deleted): commission_eligibility_changes,
-- commission_withheld_events, and the widened bonus status / event values (an entitlement
-- recorded as not_awarded_ineligible stays not awarded; the restored functions ignore it).
begin;

drop trigger if exists trg_commissions_eligibility_guard on public.commissions;
drop function if exists public.guard_commissions_eligibility();
drop view if exists public.commission_eligibility_status;
drop function if exists public.set_commission_eligibility(text, boolean, text);

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
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'Unknown order: %', p_order_id;
  end if;
  if v_order.status = 'cancelled' then
    raise exception 'Order % is cancelled; nothing can be delivered', p_order_id;
  end if;
  if not p_any_open_status and v_order.status::text not in ('processing', 'partially_delivered') then
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
    insert into public.commissions (order_id, user_id, rate, base_amount, amount, status,
                                    rule_version, kind, delivery_id, units, per_ball_rate, earned_at)
    values (p_order_id, v_order.marketing_officer_id, 0, 0, round(v_units * v_rate, 2), 'pending',
            'per_ball_v1', 'delivery', v_delivery_id, v_units, v_rate, now());
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
                             'complete', v_all_done, 'commissionModel', v_model, 'requestId', p_request_id));
  return v_delivery_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.bonus_award_on_full_delivery(p_order_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_o      public.orders%rowtype;
  v_e      public.customer_bonus_entitlements%rowtype;
  v_policy public.commission_policy%rowtype;
  v_cid    uuid;
begin
  select * into v_o from public.orders where id = p_order_id;
  if v_o.order_type = 'trial' or v_o.marketing_officer_id is null or v_o.customer_id is null then
    return;
  end if;
  perform public.bonus_refresh(v_o.customer_id);
  -- Re-verify the history before any money is created (backdating guard).
  perform public.bonus_recheck(v_o.customer_id, 'checked before awarding on order ' || p_order_id);
  select * into v_e from public.customer_bonus_entitlements where customer_id = v_o.customer_id for update;
  select * into v_policy from public.commission_policy where id;

  -- D3: the bonus order must still have >= 4 ORDERED balls (an edit before
  -- delivery may have reduced it since eligibility was decided).
  if v_e.status = 'pending_first_order' and v_e.holder_order_id = p_order_id
     and public.original_ordered_balls(p_order_id) < v_policy.bonus_min_balls then
    update public.customer_bonus_entitlements set status = 'review_required', updated_at = now() where customer_id = v_o.customer_id;
    perform public.bonus_event(v_o.customer_id, 'review_flagged', p_order_id, null, 'pending_first_order', 'review_required', null,
                               'ordered quantity fell below the threshold after eligibility was decided');
    perform public.bonus_review_log(v_o.customer_id, p_order_id,
      format('order %s now has %s ordered balls, below %s', p_order_id, public.original_ordered_balls(p_order_id), v_policy.bonus_min_balls));
    return;
  end if;

  if not ((v_e.status = 'pending_first_order' and v_e.holder_order_id = p_order_id)
          or (v_e.status = 'transferable' and public.original_ordered_balls(p_order_id) >= v_policy.bonus_min_balls)) then
    return;
  end if;

  insert into public.commissions (order_id, user_id, rate, base_amount, amount, status,
                                  rule_version, kind, bonus_customer_id, earned_at)
  values (p_order_id, v_o.marketing_officer_id, 0, 0, v_policy.first_order_bonus, 'pending',
          'per_ball_v1', 'first_order_bonus', v_o.customer_id, now())
  returning id into v_cid;

  update public.customer_bonus_entitlements
     set status = 'earned', holder_order_id = p_order_id, holder_commission_id = v_cid, updated_at = now()
   where customer_id = v_o.customer_id;
  perform public.bonus_event(v_o.customer_id, 'earned', p_order_id, v_cid, v_e.status, 'earned', v_policy.first_order_bonus, '');

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'FINANCIAL',
          format('First-order bonus of $%s earned on order %s', v_policy.first_order_bonus, p_order_id),
          public.current_profile_id(), coalesce(public.current_profile_name(), ''), p_order_id,
          jsonb_build_object('source', 'db', 'event', 'first_order_bonus_earned', 'customerId', v_o.customer_id,
                             'commissionId', v_cid, 'officerId', v_o.marketing_officer_id));
end;
$function$;

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

    if v_paid or v_officers > 1 then
      -- D8: never claw back or add automatically once paid; record and flag.
      v_review := v_expected <> v_active;
      if v_review then
        update public.commissions
           set review_required = true, updated_at = now(),
               review_reason = format('Delivered quantity corrected after payment (adjustment %s): expected $%s, recorded $%s', v_adj_id, v_expected, v_active)
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
                   else 'processing' end;
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
            format('Commission review required: order %s delivered quantity corrected after commission was paid', v_order.id),
            v_actor, v_actor_name, v_order.id,
            jsonb_build_object('source', 'db', 'event', 'commission_review_required', 'adjustmentId', v_adj_id));
  end if;
  return v_adj_id;
end;
$function$;

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

  v_eligible := new.status::text in ('confirmed', 'processing', 'partially_delivered', 'delivered')
                and new.marketing_officer_id is not null;
  if not v_eligible then
    return new;
  end if;

  if v_row.id is null then
    -- First eligible moment: the officer's rate today is frozen on the row.
    select commission_percentage into v_rate from public.profiles where id = new.marketing_officer_id;
    v_rate := coalesce(v_rate, 0);
    insert into public.commissions (order_id, user_id, rate, base_amount, amount, status, rule_version, kind)
    values (new.id, new.marketing_officer_id, v_rate, new.total, round(new.total * v_rate / 100.0, 2),
            'pending', 'legacy_percent', 'legacy')
    on conflict (order_id, user_id) where kind = 'legacy' do nothing;
    return new;
  end if;

  if tg_op = 'UPDATE' and old.status = 'cancelled' and v_row.status = 'void' then
    -- Reactivated by a Super Admin override: the commission comes back, original rate.
    update public.commissions
       set status = 'pending', voided_at = null, void_reason = '', updated_at = now(),
           base_amount = new.total, amount = round(new.total * v_row.rate / 100.0, 2)
     where id = v_row.id;
    return new;
  end if;

  -- D6: edited before delivery -> recalculate with the ORIGINAL rate.
  if tg_op = 'UPDATE' and new.total is distinct from old.total then
    if v_row.status in ('pending', 'approved') and new.status::text in ('confirmed', 'processing') then
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

CREATE OR REPLACE FUNCTION public.guard_system_logs_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if public.is_client_request() then
    if (new.category = 'ORDER'     and new.message like 'New order created: %')
       or (new.category = 'FINANCIAL' and new.message like 'Payment of $%')
       or (new.category = 'CUSTOMER'  and new.message like 'New customer registered: %')
       or (new.category = 'INVENTORY' and new.message ~ '^Stock (increased|decreased) for ') then
      return null;  -- recorded by the database in the same transaction as the event
    end if;

    if new.message ~ '^(Order \S+ status changed from |Below-cost sale approved |Customer .+ transferred from |Order \S+ created with a past date |Order \S+: requested marketing officer |Payment of \S+ on order |Commission created for order |Commission for order |Delivery recorded on order |Delivered quantity corrected |Commission model activated|First-order bonus |Commission review required)' then
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
$function$;

drop function if exists public.commission_withheld(text, text, text, uuid, text, integer, numeric, numeric);
drop function if exists public.commission_gate(text);
drop function if exists public.commission_eligible(text);

commit;
