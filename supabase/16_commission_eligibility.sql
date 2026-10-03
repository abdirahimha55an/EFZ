-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 16 : Commission eligibility per Marketing Officer (Super Admin only)
-- ----------------------------------------------------------------------------
-- Run AFTER 01..05, 07..15. Idempotent: safe to re-run. Apply to EFZ-Staging first.
-- Generated from the deployed function definitions (Production backup
-- 20261003-174012Z) by make16.mjs; every change below is marked "16".
--
-- RULES (owner decisions E1-E12, 2026-10-03)
--  * Every Marketing Officer is ON unless a Super Admin switched them OFF (no row
--    = ON). A Super Admin can switch any Marketing Officer, active or inactive,
--    with a written reason. Officers and other roles cannot change it.
--  * Eligibility is read at the commission event, inside that event's
--    transaction, serialized with changes by a per-officer lock:
--      - per-ball delivery ($ per delivered ball): at each delivery;
--      - first-order bonus: at its award event (the qualifying order becoming
--        fully delivered); OFF = not awarded for that event, never later;
--      - legacy commission: at its first eligible moment; withheld once = never.
--  * OFF: the delivery / order event proceeds normally; no commission row is
--    created; the withheld event is recorded (commission_withheld_events) with
--    an audit line. Switching ON never back-fills.
--  * Changing eligibility never creates, changes, voids or re-amounts an existing
--    commission. Earned commissions stay payable while OFF.
--  * A delivered-quantity correction re-computes the whole order: if the officer
--    is OFF now, or a delivery on the order was withheld, it goes to review
--    (no automatic void / re-issue). A cancelled order reactivated while its
--    legacy commission's officer is OFF keeps that commission void, for review.
--
-- WHAT
--  new:      commission_eligibility_changes (append-only history, current state =
--            latest row), commission_withheld_events (append-only),
--            commission_eligibility_status (view), commission_eligible(),
--            commission_gate(), commission_withheld(), set_commission_eligibility(),
--            guard_commissions_eligibility() + trigger on commissions.
--  replaced: deliver_order_internal, bonus_award_on_full_delivery,
--            correct_delivered_quantity, sync_order_commission (gate added),
--            guard_system_logs_insert (two database-only audit prefixes added).
--  widened:  customer_bonus_entitlements.status (+ not_awarded_ineligible),
--            commission_bonus_events.event (+ not_awarded).
--  No existing row is updated or deleted.
--
-- Rollback: supabase/rollback/16_rollback.sql
-- ============================================================================

begin;

-- ============================================================================
-- 1. ELIGIBILITY HISTORY (append-only) AND CURRENT STATE
-- ============================================================================

create table if not exists public.commission_eligibility_changes (
  id                uuid primary key default gen_random_uuid(),
  seq               bigint generated always as identity,
  officer_id        text not null references public.profiles(id) on delete restrict,
  eligible          boolean not null,
  previous_eligible boolean not null,
  reason            text not null check (char_length(btrim(reason)) between 1 and 500),
  changed_by        text references public.profiles(id) on delete set null,
  changed_by_name   text not null default '',
  changed_at        timestamptz not null default now(),
  check (eligible <> previous_eligible)
);
create index if not exists commission_eligibility_changes_officer_idx
  on public.commission_eligibility_changes (officer_id, seq desc);

drop trigger if exists trg_commission_eligibility_changes_guard on public.commission_eligibility_changes;
create trigger trg_commission_eligibility_changes_guard
  before update or delete on public.commission_eligibility_changes
  for each row execute function public.guard_append_only();

-- Current state: the latest change, or ON when there is none (E1).
create or replace function public.commission_eligible(p_officer_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce((select e.eligible from public.commission_eligibility_changes e
                    where e.officer_id = p_officer_id order by e.seq desc limit 1), true);
$fn$;

-- The check made at a commission event. The per-officer lock serializes it with
-- set_commission_eligibility(): a change either committed before this event
-- read it, or waits until this event commits.
create or replace function public.commission_gate(p_officer_id text)
returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if p_officer_id is null then
    return true;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('efz:commission_eligibility:' || p_officer_id, 0));
  return coalesce((select e.eligible from public.commission_eligibility_changes e
                    where e.officer_id = p_officer_id order by e.seq desc limit 1), true);
end;
$fn$;

-- ============================================================================
-- 2. WITHHELD COMMISSION EVENTS (append-only evidence of what OFF prevented)
-- ============================================================================

create table if not exists public.commission_withheld_events (
  id          uuid primary key default gen_random_uuid(),
  order_id    text not null references public.orders(id) on delete cascade,
  officer_id  text not null references public.profiles(id) on delete restrict,
  kind        text not null check (kind in ('delivery', 'first_order_bonus', 'legacy')),
  delivery_id uuid references public.order_deliveries(id) on delete restrict,
  customer_id text references public.customers(id) on delete restrict,
  units       integer,
  rate        numeric(6,2),
  amount      numeric(14,2) not null,
  occurred_at timestamptz not null default now(),
  check ((kind = 'delivery') = (delivery_id is not null)),
  check ((kind = 'first_order_bonus') = (customer_id is not null))
);
create unique index if not exists commission_withheld_delivery_uq on public.commission_withheld_events (delivery_id) where kind = 'delivery';
create unique index if not exists commission_withheld_legacy_uq on public.commission_withheld_events (order_id) where kind = 'legacy';
create unique index if not exists commission_withheld_bonus_uq on public.commission_withheld_events (customer_id) where kind = 'first_order_bonus';
create index if not exists commission_withheld_order_idx on public.commission_withheld_events (order_id);

drop trigger if exists trg_commission_withheld_events_guard on public.commission_withheld_events;
create trigger trg_commission_withheld_events_guard
  before update or delete on public.commission_withheld_events
  for each row execute function public.guard_immutable_row();

create or replace function public.commission_withheld(p_order_id text, p_officer_id text, p_kind text, p_delivery_id uuid,
                                                      p_customer_id text, p_units integer, p_rate numeric, p_amount numeric)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_name text := (select name from public.profiles where id = p_officer_id);
begin
  insert into public.commission_withheld_events (order_id, officer_id, kind, delivery_id, customer_id, units, rate, amount)
  values (p_order_id, p_officer_id, p_kind, p_delivery_id, p_customer_id, p_units, p_rate, p_amount);

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'FINANCIAL',
          format('Commission not earned on order %s: %s of $%s - %s''s commission eligibility is OFF',
                 p_order_id,
                 case p_kind when 'delivery' then format('delivery commission (%s ball(s) x $%s)', p_units, p_rate)
                             when 'first_order_bonus' then 'first-order bonus'
                             else 'legacy commission' end,
                 p_amount, coalesce(v_name, p_officer_id)),
          public.current_profile_id(), coalesce(public.current_profile_name(), ''), p_order_id,
          jsonb_build_object('source', 'db', 'event', 'commission_withheld', 'kind', p_kind, 'officerId', p_officer_id,
                             'deliveryId', p_delivery_id, 'customerId', p_customer_id, 'units', p_units,
                             'rate', p_rate, 'amount', p_amount));
end;
$fn$;

-- ============================================================================
-- 3. SUPER ADMIN CHANGE (reason required, audited)
-- ============================================================================

create or replace function public.set_commission_eligibility(p_officer_id text, p_eligible boolean, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_reason  text := nullif(btrim(coalesce(p_reason, '')), '');
  v_officer public.profiles%rowtype;
  v_current boolean;
  v_id      uuid;
  v_actor   text := public.current_profile_id();
  v_actor_n text := coalesce(public.current_profile_name(), '');
begin
  if not public.is_elevated_caller() then
    raise exception 'Only a Super Admin can change commission eligibility' using errcode = '42501';
  end if;
  if p_eligible is null then
    raise exception 'Choose ON or OFF';
  end if;
  if v_reason is null then
    raise exception 'A written reason is required to change commission eligibility';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'The reason is too long (500 characters at most)';
  end if;
  select * into v_officer from public.profiles where id = p_officer_id;
  if not found or v_officer.role::text <> 'Marketing Officer' then
    raise exception 'Commission eligibility applies to Marketing Officers only';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('efz:commission_eligibility:' || p_officer_id, 0));
  v_current := coalesce((select e.eligible from public.commission_eligibility_changes e
                          where e.officer_id = p_officer_id order by e.seq desc limit 1), true);
  if v_current = p_eligible then
    raise exception 'Commission eligibility for % is already %', v_officer.name, case when p_eligible then 'ON' else 'OFF' end;
  end if;

  insert into public.commission_eligibility_changes (officer_id, eligible, previous_eligible, reason, changed_by, changed_by_name)
  values (p_officer_id, p_eligible, v_current, v_reason, v_actor, v_actor_n)
  returning id into v_id;

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'WARNING', 'FINANCIAL',
          format('Commission eligibility for %s turned %s (was %s). Reason: %s', v_officer.name,
                 case when p_eligible then 'ON' else 'OFF' end, case when v_current then 'ON' else 'OFF' end, v_reason),
          v_actor, v_actor_n, p_officer_id,
          jsonb_build_object('source', 'db', 'event', 'commission_eligibility_changed', 'changeId', v_id,
                             'officerId', p_officer_id, 'officerName', v_officer.name,
                             'previous', v_current, 'new', p_eligible, 'reason', v_reason));
  return v_id;
end;
$fn$;

-- ============================================================================
-- 4. SAFETY NET ON commissions: no new (or revived) commission for an officer
--    who is OFF, whatever code path tries.
-- ============================================================================

create or replace function public.guard_commissions_eligibility()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if tg_op = 'INSERT' and new.status <> 'void' and not public.commission_gate(new.user_id) then
    raise exception 'Commission refused: % has commission eligibility OFF', new.user_id using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and old.status = 'void' and new.status <> 'void' and not public.commission_gate(new.user_id) then
    raise exception 'Commission refused: a void commission cannot be revived while % has commission eligibility OFF', new.user_id
      using errcode = '42501';
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_commissions_eligibility_guard on public.commissions;
create trigger trg_commissions_eligibility_guard
  before insert or update on public.commissions
  for each row execute function public.guard_commissions_eligibility();

-- ============================================================================
-- 5. FIRST-ORDER BONUS: "not awarded - officer ineligible at the award event"
-- ============================================================================

alter table public.customer_bonus_entitlements drop constraint if exists customer_bonus_entitlements_status_check;
alter table public.customer_bonus_entitlements add constraint customer_bonus_entitlements_status_check
  check (status in ('undetermined', 'not_eligible', 'historical_no_award', 'pending_first_order', 'transferable',
                    'earned', 'paid', 'review_required', 'not_awarded_ineligible'));
alter table public.commission_bonus_events drop constraint if exists commission_bonus_events_event_check;
alter table public.commission_bonus_events add constraint commission_bonus_events_event_check
  check (event in ('determined', 'earned', 'voided', 'released', 'paid', 'review_flagged', 'not_awarded'));

-- ============================================================================
-- 6. COMMISSION ENGINE: eligibility checked at each commission event (16)
-- ============================================================================

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

  -- 16 (E3): this full delivery is the award event. If the officer's commission
  -- eligibility is OFF now, no bonus is awarded for it, and none is awarded later.
  if not public.commission_gate(v_o.marketing_officer_id) then
    update public.customer_bonus_entitlements
       set status = 'not_awarded_ineligible', holder_order_id = p_order_id, holder_commission_id = null, updated_at = now()
     where customer_id = v_o.customer_id;
    perform public.bonus_event(v_o.customer_id, 'not_awarded', p_order_id, null, v_e.status, 'not_awarded_ineligible', null,
                               'Not awarded: the officer''s commission eligibility was OFF at the award event');
    perform public.commission_withheld(p_order_id, v_o.marketing_officer_id, 'first_order_bonus', null, v_o.customer_id,
                                       null, null, v_policy.first_order_bonus);
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
            case when v_eligibility and not (coalesce(v_paid, false) or coalesce(v_officers, 0) > 1)
                 then format('Commission review required: order %s delivered quantity corrected while commission eligibility is involved', v_order.id)
                 else format('Commission review required: order %s delivered quantity corrected after commission was paid', v_order.id) end,
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

    if new.message ~ '^(Order \S+ status changed from |Below-cost sale approved |Customer .+ transferred from |Order \S+ created with a past date |Order \S+: requested marketing officer |Payment of \S+ on order |Commission created for order |Commission for order |Delivery recorded on order |Delivered quantity corrected |Commission model activated|First-order bonus |Commission review required|Commission eligibility |Commission not earned )' then
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

-- ============================================================================
-- 7. READ ACCESS
-- ============================================================================
-- Officers see only their own current state (no reason, no actor); the Super Admin
-- and management who see all commissions see every officer and the full history.

create or replace view public.commission_eligibility_status
with (security_invoker = false, security_barrier = true) as
select
  p.id as officer_id,
  coalesce(l.eligible, true) as eligible,
  l.changed_at as since
from public.profiles p
left join lateral (
  select e.eligible, e.changed_at from public.commission_eligibility_changes e
   where e.officer_id = p.id order by e.seq desc limit 1
) l on true
where p.role = 'Marketing Officer'
  and public.current_profile_id() is not null
  and (p.id = public.current_profile_id() or public.can_view_all_commissions());

alter table public.commission_eligibility_changes enable row level security;
alter table public.commission_withheld_events     enable row level security;

drop policy if exists commission_eligibility_changes_select on public.commission_eligibility_changes;
create policy commission_eligibility_changes_select on public.commission_eligibility_changes
  for select to authenticated using (public.can_view_all_commissions());

drop policy if exists commission_withheld_events_select on public.commission_withheld_events;
create policy commission_withheld_events_select on public.commission_withheld_events
  for select to authenticated using (public.can_view_all_commissions());

revoke all on public.commission_eligibility_changes, public.commission_withheld_events, public.commission_eligibility_status
  from public, anon, authenticated;
grant select on public.commission_eligibility_changes, public.commission_withheld_events, public.commission_eligibility_status
  to authenticated;

revoke all on function public.set_commission_eligibility(text, boolean, text) from public, anon;
grant execute on function public.set_commission_eligibility(text, boolean, text) to authenticated;
revoke all on function public.commission_eligible(text)                         from public, anon, authenticated;
revoke all on function public.commission_gate(text)                             from public, anon, authenticated;
revoke all on function public.commission_withheld(text, text, text, uuid, text, integer, numeric, numeric) from public, anon, authenticated;
revoke all on function public.guard_commissions_eligibility()                   from public, anon, authenticated;

commit;
