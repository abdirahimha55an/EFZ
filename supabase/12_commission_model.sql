-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 12 : Per-ball commission model, partial deliveries, delivered-quantity
--           corrections, ownership visibility, Football-only products
-- ----------------------------------------------------------------------------
-- Run AFTER 01..05, 07, 08, 09, 10 and 11. Idempotent: safe to re-run.
-- Apply to EFZ-Staging first. Production only after the documented gates.
--
-- THE NEW COMMISSION MODEL IS NOT ACTIVE AFTER THIS FILE RUNS.
-- commission_policy.cutover_at stays NULL until a Super Admin (or the trusted
-- SQL editor) calls activate_commission_model(note). That call records the
-- actual activation moment as cutover_at; no date is chosen in advance.
-- Until then every order confirmation is classified legacy_percent.
-- Activation is REFUSED until the bonus-timing assumption A1 (below) has been
-- approved with approve_bonus_timing(note) - see section 1.
--
-- Business rules implemented (EFZ final decisions, 2026-10-01):
--  * $0.30 per Football actually delivered, earned at each delivery (partial
--    deliveries earn per delivery), whether or not the customer has paid.
--    Trial orders earn it too.
--  * $3 first-order bonus, at most once per customer. The customer's first-ever
--    NON-TRIAL order decides eligibility by its original ORDERED quantity (>= 4),
--    even if that order was cancelled. Its era (legacy / per-ball) comes from
--    its immutable confirmation classification (D11) - never from its order
--    date or creation time. A first order cancelled WITHOUT ever being
--    confirmed has no confirmation timestamp: if it was cancelled before the
--    cut-over (or before this file) any confirmation would have been earlier
--    still, so it is legacy with certainty; if it was cancelled at/after the
--    cut-over and could qualify (>= 4), the era cannot be derived and the
--    bonus is put on manual review (no automatic award, no automatic denial).
--    "First-ever" is the earliest order by order date (then entry time). A
--    Super Admin can backdate an order, move an order to another customer or
--    switch it between trial and regular, so the order dated first is
--    trusted only when it is ALSO the first order entered. If the two differ
--    and either could carry the bonus, the bonus goes to manual review; if a
--    later change puts a different order first after eligibility was decided
--    and a bonus is pending, earned or paid, it is flagged for review (an
--    unpaid bonus is blocked from payment; a paid one is never clawed back).
--    At award time the history and the >= 4 ordered balls are re-verified. A first order from before the cut-over
--    (legacy) never pays a bonus and no later order can claim it. If the
--    bonus order is cancelled before the bonus is paid, the bonus moves to the
--    next non-trial order with >= 4 ordered balls. A paid bonus is never
--    re-awarded; a cancellation after payment is flagged for manual review.
--
--  ASSUMPTION A1 - NOT AN APPROVED BUSINESS RULE (bonus timing):
--    the $3 bonus row is created when the qualifying order becomes FULLY
--    delivered, and "the next qualifying order" is the next one to become
--    fully delivered. All of this lives in bonus_award_on_full_delivery().
--    commission_policy.bonus_timing records it as 'on_full_delivery' with
--    bonus_timing_status = 'assumption_unapproved'; activate_commission_model()
--    refuses until approve_bonus_timing() records an explicit approval.
--  * Cut-over by CONFIRMATION time: each order is classified once, at its first
--    confirmation, legacy_percent (before cutover_at) or per_ball_v1, and that
--    classification can never change. Orders already past pending when this
--    file runs are classified legacy_percent now.
--  * Legacy commissions stay legacy: created at confirmation at the officer's
--    rate; recalculated only when the order is edited before delivery (D6),
--    with its ORIGINAL rate; never moved by a customer transfer (D7); voided
--    with its amount kept when an unpaid order is cancelled; flagged for review
--    (no clawback) when a paid one is cancelled.
--  * Payments and financial recalculation can no longer touch any commission:
--    the commission trigger now fires only when status, officer or total
--    genuinely change, and recalc_order_financials rewrites total unchanged.
--  * NORMAL PARTIAL DELIVERY - record_delivery(): records the balls handed
--    over per line. Ordered quantity, invoice (total) and receivable are NEVER
--    changed by it: order 10, deliver 6 -> ordered 10, delivered 6, remaining
--    4, total unchanged; status 'partially_delivered' until all is delivered.
--    INVENTORY: for orders taken after this file (stock_mode = at_delivery)
--    create_order() deducts nothing; each delivery deducts exactly the balls
--    delivered (6, then 4). Orders taken before this file (stock_mode =
--    at_creation) already had their stock deducted when they were taken; that
--    history is not rewritten, so their deliveries move no stock.
--  * SUPER ADMIN CORRECTION - correct_delivered_quantity(), a separate function
--    that partial delivery never calls: fixes a wrong delivered count, written
--    reason required. Mode 'keep_invoice': invoice unchanged, the balls stay
--    owed on the order. Mode 'reduce_invoice': the order line and invoice are
--    reduced to the corrected delivered count. Either way an append-only
--    record keeps old/new delivered and line quantity, stock change, commission
--    before/after, invoice/receivable before/after, reason, actor and time.
--    If commission on the order was already paid, nothing is clawed back or
--    added automatically: the difference is recorded and flagged for review.
--  * Former officers lose a transferred customer's profile and orders; they see
--    only that it was transferred and when (customer_transfer_notices).
--  * Football is the only category a product may be created with or changed to.
--
-- It does not UPDATE or DELETE any existing row. New columns on existing rows
-- are filled by constant column defaults (no row trigger fires, updated_at is
-- untouched); history tables are back-filled by INSERT only.
--
-- Rollback: supabase/rollback/12_rollback.sql - refuses once Migration 12 data
-- exists (see that file); new tables, columns and the enum value stay.
-- ============================================================================

alter type public.order_status add value if not exists 'partially_delivered' after 'processing';

-- ----------------------------------------------------------------------------
-- ATOMIC: everything below runs in ONE explicit transaction (begin ... commit).
--  * Supabase SQL Editor (the whole file is sent as one request): if any
--    statement fails, PostgreSQL skips the rest of the file and nothing is
--    committed. The failed transaction may stay open in that editor session:
--    run   rollback;   once before anything else (harmless if none is open).
--  * Clients that send statements one at a time (e.g. psql -f): after a
--    failure every later statement is refused, and the final COMMIT is turned
--    into a ROLLBACK by PostgreSQL.
--  The one statement BEFORE begin adds the enum value 'partially_delivered'.
--  Sent as one request, PostgreSQL folds it into the same transaction, so a
--  failure removes it too (verified offline); nothing in this file uses the new
--  value while the transaction is open. Sent statement by statement, it
--  commits on its own: purely additive, an unused value is all that remains.
-- ----------------------------------------------------------------------------
begin;

-- ============================================================================
-- 1. COMMISSION POLICY (one row) AND ACTIVATION
-- ============================================================================

create table if not exists public.commission_policy (
  id                boolean primary key default true check (id),
  per_ball_rate     numeric(6,2) not null default 0.30 check (per_ball_rate >= 0),
  first_order_bonus numeric(6,2) not null default 3.00 check (first_order_bonus >= 0),
  bonus_min_balls   integer      not null default 4    check (bonus_min_balls > 0),
  cutover_at        timestamptz,
  activated_by      text references public.profiles(id) on delete set null,
  activation_note   text not null default '',
  created_at        timestamptz not null default now(),
  -- ASSUMPTION A1 (see header): the only timing implemented, unapproved by default.
  bonus_timing               text not null default 'on_full_delivery' check (bonus_timing = 'on_full_delivery'),
  bonus_timing_status        text not null default 'assumption_unapproved'
                             check (bonus_timing_status in ('assumption_unapproved', 'approved')),
  bonus_timing_approved_by   text references public.profiles(id) on delete set null,
  bonus_timing_approved_at   timestamptz,
  bonus_timing_approval_note text not null default '',
  check ((bonus_timing_status = 'approved') = (bonus_timing_approved_at is not null))
);
insert into public.commission_policy (id) values (true) on conflict (id) do nothing;

comment on column public.commission_policy.bonus_timing is
  'ASSUMPTION A1, not an approved business rule: the first-order bonus is created when the qualifying order is fully delivered. Activation is refused until bonus_timing_status = approved.';

comment on column public.commission_policy.cutover_at is
  'Actual activation moment of the per-ball model (UTC; shown in Africa/Mogadishu). NULL = not yet activated. Set once by activate_commission_model().';

-- Once active, the policy cannot change: no new cut-over, no new rates.
create or replace function public.guard_commission_policy()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if tg_op = 'DELETE' then
    raise exception 'The commission policy row cannot be deleted' using errcode = '42501';
  end if;
  if old.cutover_at is not null
     and (new.cutover_at is distinct from old.cutover_at
          or new.per_ball_rate is distinct from old.per_ball_rate
          or new.first_order_bonus is distinct from old.first_order_bonus
          or new.bonus_min_balls is distinct from old.bonus_min_balls) then
    raise exception 'The commission model is active since %; its cut-over and rates cannot change', old.cutover_at
      using errcode = '42501';
  end if;
  if old.bonus_timing_approved_at is not null
     and (new.bonus_timing_status is distinct from old.bonus_timing_status
          or new.bonus_timing_approved_at is distinct from old.bonus_timing_approved_at
          or new.bonus_timing_approved_by is distinct from old.bonus_timing_approved_by
          or new.bonus_timing_approval_note is distinct from old.bonus_timing_approval_note) then
    raise exception 'The bonus-timing approval was recorded on % and cannot be changed', old.bonus_timing_approved_at
      using errcode = '42501';
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_commission_policy_guard on public.commission_policy;
create trigger trg_commission_policy_guard
  before update or delete on public.commission_policy
  for each row execute function public.guard_commission_policy();

create or replace function public.activate_commission_model(p_note text default '')
returns timestamptz
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_policy public.commission_policy%rowtype;
  v_now    timestamptz := now();
begin
  if not public.is_elevated_caller() then
    raise exception 'Only a Super Admin can activate the commission model' using errcode = '42501';
  end if;

  select * into v_policy from public.commission_policy where id for update;
  if v_policy.cutover_at is not null then
    raise exception 'The commission model is already active since %', v_policy.cutover_at;
  end if;
  if v_policy.bonus_timing_status <> 'approved' then
    raise exception 'Activation refused: the first-order bonus timing (%) is an implementation assumption that has not been approved. Record the owner''s approval with approve_bonus_timing(note) first.', v_policy.bonus_timing
      using errcode = '42501';
  end if;

  update public.commission_policy
     set cutover_at = v_now, activated_by = public.current_profile_id(),
         activation_note = coalesce(p_note, '')
   where id;

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'WARNING', 'FINANCIAL',
          format('Commission model activated: $%s per delivered football and a one-time $%s first-order bonus for orders confirmed from %s (Mogadishu %s)',
                 v_policy.per_ball_rate, v_policy.first_order_bonus, v_now,
                 to_char(v_now at time zone 'Africa/Mogadishu', 'YYYY-MM-DD HH24:MI:SS')),
          public.current_profile_id(), coalesce(public.current_profile_name(), ''), 'commission_policy',
          jsonb_build_object('source', 'db', 'event', 'commission_model_activated', 'cutoverAt', v_now,
                             'perBallRate', v_policy.per_ball_rate, 'firstOrderBonus', v_policy.first_order_bonus,
                             'bonusMinBalls', v_policy.bonus_min_balls, 'note', coalesce(p_note, '')));
  return v_now;
end;
$fn$;

-- Records the owner's explicit approval of ASSUMPTION A1. Super Admin (or the
-- trusted SQL editor) only, written note required, once, audited.
create or replace function public.approve_bonus_timing(p_note text)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_policy public.commission_policy%rowtype;
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
  v_now    timestamptz := now();
begin
  if not public.is_elevated_caller() then
    raise exception 'Only a Super Admin can record the bonus-timing approval' using errcode = '42501';
  end if;
  if v_note is null then
    raise exception 'A written note is required (who approved the bonus timing, and when)';
  end if;
  select * into v_policy from public.commission_policy where id for update;
  if v_policy.bonus_timing_status = 'approved' then
    raise exception 'The bonus timing was already approved on %', v_policy.bonus_timing_approved_at;
  end if;

  update public.commission_policy
     set bonus_timing_status = 'approved', bonus_timing_approved_at = v_now,
         bonus_timing_approved_by = public.current_profile_id(), bonus_timing_approval_note = v_note
   where id;

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'WARNING', 'FINANCIAL',
          format('First-order bonus timing approved: %s. Note: %s', v_policy.bonus_timing, v_note),
          public.current_profile_id(), coalesce(public.current_profile_name(), ''), 'commission_policy',
          jsonb_build_object('source', 'db', 'event', 'bonus_timing_approved', 'bonusTiming', v_policy.bonus_timing,
                             'approvedAt', v_now, 'note', v_note));
  return v_now;
end;
$fn$;

-- ============================================================================
-- 2. ORDERS: confirmation time and stock mode
-- ============================================================================

alter table public.orders add column if not exists confirmed_at timestamptz;
-- Last time the order was cancelled (from 12 on; NULL for earlier cancellations,
-- which all happened before any cut-over). Used only to place a never-confirmed
-- cancelled order relative to the cut-over.
alter table public.orders add column if not exists cancelled_at timestamptz;
-- Existing orders had their stock deducted at creation: they get 'at_creation'
-- from the column default (no UPDATE). Orders taken from now on: 'at_delivery'.
alter table public.orders add column if not exists stock_mode text not null default 'at_creation';
alter table public.orders alter column stock_mode set default 'at_delivery';
alter table public.orders drop constraint if exists orders_stock_mode_check;
alter table public.orders add constraint orders_stock_mode_check check (stock_mode in ('at_creation', 'at_delivery'));

comment on column public.orders.confirmed_at is 'First time the order was confirmed (set by update_order_status from Migration 12). NULL for orders confirmed earlier.';
comment on column public.orders.cancelled_at is 'Last cancellation (set by update_order_status from Migration 12). NULL for orders cancelled earlier.';
comment on column public.orders.stock_mode is 'at_creation: stock was deducted when the order was taken (orders from before Migration 12). at_delivery: stock leaves the shelf per delivered ball.';

grant select (confirmed_at, cancelled_at, stock_mode) on public.orders to authenticated;

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
$fn$;

-- ============================================================================
-- 3. IMMUTABLE COMMISSION CLASSIFICATION PER ORDER
-- ============================================================================

create table if not exists public.order_commission_class (
  order_id            text primary key references public.orders(id) on delete cascade,
  model               text not null check (model in ('legacy_percent', 'per_ball_v1')),
  classified_at       timestamptz not null default now(),
  cutover_at_snapshot timestamptz,
  source              text not null check (source in ('backfill', 'confirmation'))
);

create or replace function public.guard_immutable_row()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if tg_op = 'UPDATE' then
    raise exception '% rows are append-only and cannot be changed', tg_table_name using errcode = '42501';
  end if;
  -- DELETE: allowed only as the cascade of a deleted parent order.
  if exists (select 1 from public.orders o where o.id = old.order_id) then
    raise exception '% rows are append-only and cannot be deleted', tg_table_name using errcode = '42501';
  end if;
  return old;
end;
$fn$;

drop trigger if exists trg_order_commission_class_guard on public.order_commission_class;
create trigger trg_order_commission_class_guard
  before update or delete on public.order_commission_class
  for each row execute function public.guard_immutable_row();

-- Orders already past pending were confirmed before the new model existed.
-- A cancelled order with a commission row was confirmed too.
insert into public.order_commission_class (order_id, model, classified_at, cutover_at_snapshot, source)
select o.id, 'legacy_percent', now(), null, 'backfill'
  from public.orders o
 where o.status in ('confirmed', 'processing', 'delivered')
    or (o.status = 'cancelled' and exists (select 1 from public.commissions c where c.order_id = o.id))
on conflict (order_id) do nothing;

-- ============================================================================
-- 4. DELIVERIES (append-only) AND DELIVERED-QUANTITY CORRECTIONS
-- ============================================================================

create table if not exists public.order_deliveries (
  id               uuid primary key default gen_random_uuid(),
  order_id         text not null references public.orders(id) on delete restrict,
  delivered_at     timestamptz,
  recorded_by      text references public.profiles(id) on delete set null,
  recorded_by_name text not null default '',
  source           text not null check (source in ('delivery', 'backfill')),
  request_id       uuid unique,
  note             text not null default '',
  created_at       timestamptz not null default now(),
  check (source = 'backfill' or delivered_at is not null)
);
create index if not exists order_deliveries_order_idx on public.order_deliveries(order_id);

create table if not exists public.order_delivery_lines (
  id            uuid primary key default gen_random_uuid(),
  delivery_id   uuid not null references public.order_deliveries(id) on delete restrict,
  order_id      text not null references public.orders(id) on delete restrict,
  order_item_id text not null references public.order_items(id) on delete restrict,
  quantity      integer not null check (quantity > 0),
  unique (delivery_id, order_item_id)
);
create index if not exists order_delivery_lines_item_idx on public.order_delivery_lines(order_item_id);

create table if not exists public.delivered_quantity_adjustments (
  id                    uuid primary key default gen_random_uuid(),
  order_id              text not null references public.orders(id) on delete restrict,
  order_item_id         text not null references public.order_items(id) on delete restrict,
  mode                  text not null check (mode in ('keep_invoice', 'reduce_invoice')),
  old_delivered         integer not null,
  new_delivered         integer not null check (new_delivered >= 0),
  delta                 integer not null,
  old_line_quantity     integer not null,
  new_line_quantity     integer not null,
  stock_delta           integer not null,
  commission_model      text,
  commission_before     numeric(14,2) not null,
  commission_after      numeric(14,2) not null,
  commission_difference numeric(14,2) not null,
  review_required       boolean not null,
  financial_before      jsonb not null,
  financial_after       jsonb not null,
  reason                text not null check (char_length(btrim(reason)) > 0),
  actor                 text references public.profiles(id) on delete set null,
  actor_name            text not null default '',
  created_at            timestamptz not null default now()
);
create index if not exists delivered_quantity_adjustments_item_idx on public.delivered_quantity_adjustments(order_item_id);

drop trigger if exists trg_order_deliveries_guard on public.order_deliveries;
create trigger trg_order_deliveries_guard before update or delete on public.order_deliveries
  for each row execute function public.guard_immutable_row();
drop trigger if exists trg_order_delivery_lines_guard on public.order_delivery_lines;
create trigger trg_order_delivery_lines_guard before update or delete on public.order_delivery_lines
  for each row execute function public.guard_immutable_row();
drop trigger if exists trg_delivered_quantity_adjustments_guard on public.delivered_quantity_adjustments;
create trigger trg_delivered_quantity_adjustments_guard before update or delete on public.delivered_quantity_adjustments
  for each row execute function public.guard_immutable_row();

-- Delivered orders from before 12 were delivered in full: one back-filled
-- delivery per order (delivered_at as recorded, NULL where none was).
insert into public.order_deliveries (order_id, delivered_at, recorded_by, recorded_by_name, source, note)
select o.id, o.delivered_at, null, '', 'backfill', 'Delivered in full before Migration 12'
  from public.orders o
 where o.status = 'delivered'
   and not exists (select 1 from public.order_deliveries d where d.order_id = o.id);

insert into public.order_delivery_lines (delivery_id, order_id, order_item_id, quantity)
select d.id, d.order_id, oi.id, oi.quantity
  from public.order_deliveries d
  join public.order_items oi on oi.order_id = d.order_id
 where d.source = 'backfill'
   and not exists (select 1 from public.order_delivery_lines l where l.delivery_id = d.id and l.order_item_id = oi.id);

-- Delivered balls on one order line: deliveries plus corrections.
create or replace function public.item_delivered_quantity(p_order_item_id text)
returns integer
language sql
stable
security definer
set search_path = public
as $fn$
  select (coalesce((select sum(l.quantity) from public.order_delivery_lines l where l.order_item_id = p_order_item_id), 0)
        + coalesce((select sum(a.delta) from public.delivered_quantity_adjustments a where a.order_item_id = p_order_item_id), 0))::integer;
$fn$;

create or replace function public.order_delivered_quantity(p_order_id text)
returns integer
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(sum(public.item_delivered_quantity(oi.id)), 0)::integer
    from public.order_items oi where oi.order_id = p_order_id;
$fn$;

-- Balls promised to open orders whose stock leaves at delivery.
create or replace function public.product_committed_quantity(p_product_id text)
returns integer
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(sum(greatest(oi.quantity - public.item_delivered_quantity(oi.id), 0)), 0)::integer
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
   where oi.product_id = p_product_id
     and o.stock_mode = 'at_delivery'
     and o.status not in ('cancelled', 'delivered');
$fn$;

-- The ordered football quantity of an order, before any close-short correction
-- (the bonus threshold uses the original ORDERED quantity).
create or replace function public.original_ordered_balls(p_order_id text)
returns integer
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(sum(oi.quantity
           + coalesce((select sum(a.old_line_quantity - a.new_line_quantity)
                         from public.delivered_quantity_adjustments a
                        where a.order_item_id = oi.id and a.mode = 'reduce_invoice'), 0)), 0)::integer
    from public.order_items oi
    join public.products p on p.id = oi.product_id
   where oi.order_id = p_order_id
     and p.category = 'Football';
$fn$;

-- A line with delivered balls cannot be removed, re-pointed or cut below what
-- was delivered by a direct edit (only correct_delivered_quantity() can).
create or replace function public.guard_order_items_delivered()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_delivered integer;
begin
  if not public.is_client_request() then
    return coalesce(new, old);
  end if;
  v_delivered := public.item_delivered_quantity(old.id);
  if v_delivered = 0 then
    return coalesce(new, old);
  end if;
  if tg_op = 'DELETE' then
    raise exception 'Order line % has % delivered ball(s) and cannot be deleted', old.id, v_delivered using errcode = '42501';
  end if;
  if new.product_id is distinct from old.product_id or new.quantity < v_delivered then
    raise exception 'Order line % has % delivered ball(s): its product cannot change and its quantity cannot go below that', old.id, v_delivered
      using errcode = '42501';
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_order_items_delivered_guard on public.order_items;
create trigger trg_order_items_delivered_guard
  before update or delete on public.order_items
  for each row execute function public.guard_order_items_delivered();

-- ============================================================================
-- 5. COMMISSION ROWS: explicit rule version and kind
-- ============================================================================
-- Existing rows become rule_version 'legacy_percent', kind 'legacy' through the
-- column default (no UPDATE, no trigger, updated_at untouched). The defaults are
-- then removed, so every new row must state its rule.

alter table public.commissions add column if not exists rule_version text not null default 'legacy_percent';
alter table public.commissions alter column rule_version drop default;
alter table public.commissions add column if not exists kind text not null default 'legacy';
alter table public.commissions alter column kind drop default;
alter table public.commissions add column if not exists delivery_id uuid references public.order_deliveries(id) on delete restrict;
alter table public.commissions add column if not exists adjustment_id uuid;
alter table public.commissions add column if not exists units integer;
alter table public.commissions add column if not exists per_ball_rate numeric(6,2);
alter table public.commissions add column if not exists earned_at timestamptz;
alter table public.commissions add column if not exists bonus_customer_id text references public.customers(id) on delete restrict;
alter table public.commissions add column if not exists review_required boolean not null default false;
alter table public.commissions add column if not exists review_reason text not null default '';
alter table public.commissions add column if not exists void_reason text not null default '';
alter table public.commissions add column if not exists voided_at timestamptz;

-- A correction row is written before its adjustment record (which needs the
-- after-values): the reference is checked at commit.
alter table public.commissions drop constraint if exists commissions_adjustment_id_fkey;
alter table public.commissions add constraint commissions_adjustment_id_fkey
  foreign key (adjustment_id) references public.delivered_quantity_adjustments(id)
  on delete restrict deferrable initially deferred;

alter table public.commissions drop constraint if exists commissions_shape_check;
alter table public.commissions add constraint commissions_shape_check check (
  (rule_version = 'legacy_percent' and kind = 'legacy'
     and delivery_id is null and adjustment_id is null and units is null
     and per_ball_rate is null and bonus_customer_id is null)
  or (rule_version = 'per_ball_v1' and kind = 'delivery'
     and delivery_id is not null and adjustment_id is null and units > 0
     and per_ball_rate is not null and amount = round(units * per_ball_rate, 2)
     and earned_at is not null and bonus_customer_id is null)
  or (rule_version = 'per_ball_v1' and kind = 'correction'
     and adjustment_id is not null and delivery_id is null and units > 0
     and per_ball_rate is not null and amount = round(units * per_ball_rate, 2)
     and earned_at is not null and bonus_customer_id is null)
  or (rule_version = 'per_ball_v1' and kind = 'first_order_bonus'
     and bonus_customer_id is not null and delivery_id is null and adjustment_id is null
     and units is null and per_ball_rate is null and earned_at is not null)
);

-- One legacy row per order and officer (as before); one row per delivery; one
-- per correction; at most one live first-order bonus per customer.
alter table public.commissions drop constraint if exists commissions_order_id_user_id_key;
create unique index if not exists commissions_legacy_order_user_uq on public.commissions(order_id, user_id) where kind = 'legacy';
create unique index if not exists commissions_delivery_uq on public.commissions(delivery_id) where kind = 'delivery';
create unique index if not exists commissions_correction_uq on public.commissions(adjustment_id) where kind = 'correction';
create unique index if not exists commissions_bonus_customer_uq on public.commissions(bonus_customer_id) where kind = 'first_order_bonus' and status <> 'void';

-- Clients (even a Super Admin through the API) cannot rewrite what a commission
-- is or how much it is; only the database functions do.
create or replace function public.guard_commissions_write()
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
    raise exception 'Commissions are created by the database' using errcode = '42501';
  end if;
  v_locked := public.changed_columns(to_jsonb(old), to_jsonb(new), array[
    'order_id', 'user_id', 'rate', 'base_amount', 'amount', 'rule_version', 'kind', 'delivery_id',
    'adjustment_id', 'units', 'per_ball_rate', 'earned_at', 'bonus_customer_id', 'review_required',
    'review_reason', 'void_reason', 'voided_at', 'created_at'
  ]);
  if cardinality(v_locked) > 0 then
    raise exception 'Commission field(s) % are maintained by the database', v_locked using errcode = '42501';
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_commissions_guard on public.commissions;
create trigger trg_commissions_guard
  before insert or update on public.commissions
  for each row execute function public.guard_commissions_write();

-- ============================================================================
-- 6. FIRST-ORDER BONUS ENTITLEMENT (one row per customer) AND EVENTS
-- ============================================================================

create table if not exists public.customer_bonus_entitlements (
  customer_id             text primary key references public.customers(id) on delete restrict,
  status                  text not null check (status in ('undetermined', 'not_eligible', 'historical_no_award',
                                                          'pending_first_order', 'transferable', 'earned', 'paid',
                                                          'review_required')),
  deciding_order_id       text references public.orders(id) on delete set null,
  deciding_order_quantity integer,
  deciding_era            text check (deciding_era in ('legacy', 'new', 'unconfirmed')),
  holder_order_id         text references public.orders(id) on delete set null,
  holder_commission_id    uuid references public.commissions(id) on delete set null,
  determined_at           timestamptz,
  updated_at              timestamptz not null default now()
);

alter table public.customer_bonus_entitlements drop constraint if exists customer_bonus_entitlements_status_check;
alter table public.customer_bonus_entitlements add constraint customer_bonus_entitlements_status_check
  check (status in ('undetermined', 'not_eligible', 'historical_no_award', 'pending_first_order', 'transferable',
                    'earned', 'paid', 'review_required'));
alter table public.customer_bonus_entitlements drop constraint if exists customer_bonus_entitlements_deciding_era_check;
alter table public.customer_bonus_entitlements add constraint customer_bonus_entitlements_deciding_era_check
  check (deciding_era in ('legacy', 'new', 'unconfirmed'));

create table if not exists public.commission_bonus_events (
  id            uuid primary key default gen_random_uuid(),
  customer_id   text not null references public.customers(id) on delete restrict,
  event         text not null check (event in ('determined', 'earned', 'voided', 'released', 'paid', 'review_flagged')),
  order_id      text references public.orders(id) on delete set null,
  commission_id uuid references public.commissions(id) on delete set null,
  from_status   text,
  to_status     text,
  amount        numeric(14,2),
  actor         text,
  actor_name    text not null default '',
  note          text not null default '',
  occurred_at   timestamptz not null default now()
);

create or replace function public.guard_append_only()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  raise exception '% rows are append-only', tg_table_name using errcode = '42501';
end;
$fn$;

drop trigger if exists trg_commission_bonus_events_guard on public.commission_bonus_events;
create trigger trg_commission_bonus_events_guard before update or delete on public.commission_bonus_events
  for each row execute function public.guard_append_only();

create or replace function public.bonus_event(p_customer text, p_event text, p_order text, p_commission uuid,
                                              p_from text, p_to text, p_amount numeric, p_note text)
returns void
language sql
security definer
set search_path = public
as $fn$
  insert into public.commission_bonus_events (customer_id, event, order_id, commission_id, from_status, to_status, amount, actor, actor_name, note)
  values (p_customer, p_event, p_order, p_commission, p_from, p_to, p_amount,
          public.current_profile_id(), coalesce(public.current_profile_name(), ''), coalesce(p_note, ''));
$fn$;

-- The eligibility outcome one order would give if it is the customer's first
-- non-trial order. No row while it cannot be decided yet (pending, never
-- confirmed). Era = its immutable confirmation classification (D11).
create or replace function public.bonus_decision(p_order_id text)
returns table (status text, era text, qty integer)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_o     public.orders%rowtype;
  v_model text;
  v_cut   timestamptz;
  v_min   integer;
begin
  select * into v_o from public.orders where id = p_order_id;
  if not found then
    return;
  end if;
  select cutover_at, bonus_min_balls into v_cut, v_min from public.commission_policy where id;
  select model into v_model from public.order_commission_class where order_id = p_order_id;
  if v_model is not null then
    era := case when v_model = 'per_ball_v1' then 'new' else 'legacy' end;
  elsif v_o.status = 'cancelled' then
    -- Cancelled without ever being confirmed: no confirmation timestamp.
    -- Cancelled before the cut-over (or before Migration 12, cancelled_at
    -- NULL, or while no cut-over exists): any confirmation would have been
    -- earlier still -> legacy with certainty. At/after the cut-over: unknown.
    era := case when v_o.cancelled_at is null or v_cut is null or v_o.cancelled_at < v_cut
                then 'legacy' else 'unconfirmed' end;
  else
    return;   -- not confirmed yet: decided at its confirmation
  end if;
  qty := public.original_ordered_balls(p_order_id);
  status := case
    when qty < v_min                then 'not_eligible'
    when era = 'legacy'             then 'historical_no_award'
    when era = 'unconfirmed'        then 'review_required'
    when v_o.status = 'cancelled'   then 'transferable'
    else 'pending_first_order'
  end;
  return next;
end;
$fn$;

-- The customer's first non-trial order by business date (then entry time),
-- and the first one entered. They differ only after backdating, moving an
-- order between customers or switching trial/regular.
create or replace function public.bonus_first_orders(p_customer_id text, out by_date text, out by_entry text)
language sql
stable
security definer
set search_path = public
as $fn$
  select (select o.id from public.orders o
           where o.customer_id = p_customer_id and o.order_type <> 'trial'
           order by o.order_date, o.created_at, o.id limit 1),
         (select o.id from public.orders o
           where o.customer_id = p_customer_id and o.order_type <> 'trial'
           order by o.created_at, o.id limit 1);
$fn$;

create or replace function public.bonus_review_log(p_customer_id text, p_order_id text, p_reason text)
returns void
language sql
security definer
set search_path = public
as $fn$
  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'WARNING', 'FINANCIAL',
          format('First-order bonus review required for customer %s: %s', p_customer_id, p_reason),
          public.current_profile_id(), coalesce(public.current_profile_name(), ''), coalesce(p_order_id, p_customer_id),
          jsonb_build_object('source', 'db', 'event', 'first_order_bonus_review', 'customerId', p_customer_id,
                             'orderId', p_order_id, 'reason', p_reason));
$fn$;

-- Decides eligibility once the customer's first-ever non-trial order is known
-- well enough: confirmed (classified), or cancelled. Final once decided.
create or replace function public.bonus_refresh(p_customer_id text)
returns text
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_e      public.customer_bonus_entitlements%rowtype;
  v_first  record;
  v_d      record;
  v_x      record;
  v_status text;
  v_reason text;
begin
  if p_customer_id is null then
    return null;
  end if;
  insert into public.customer_bonus_entitlements (customer_id, status) values (p_customer_id, 'undetermined')
  on conflict (customer_id) do nothing;
  select * into v_e from public.customer_bonus_entitlements where customer_id = p_customer_id for update;
  if v_e.status <> 'undetermined' then
    return v_e.status;
  end if;

  select * into v_first from public.bonus_first_orders(p_customer_id);
  if v_first.by_date is null then
    return 'undetermined';
  end if;
  select * into v_d from public.bonus_decision(v_first.by_date);
  if not found then
    return 'undetermined';   -- the first order is not confirmed yet
  end if;
  v_status := v_d.status;

  if v_first.by_entry is distinct from v_first.by_date then
    -- The order dated first is not the order entered first (backdating, a
    -- moved order or a trial/regular switch). Decide automatically only if
    -- neither candidate could carry the bonus; otherwise manual review.
    select * into v_x from public.bonus_decision(v_first.by_entry);
    if not found then
      return 'undetermined';   -- wait until the first-entered order is decided too
    end if;
    if not (v_d.status in ('not_eligible', 'historical_no_award') and v_x.status in ('not_eligible', 'historical_no_award')) then
      v_status := 'review_required';
      v_reason := format('order %s is dated first but order %s was entered first (backdated, moved or re-typed order)',
                         v_first.by_date, v_first.by_entry);
    end if;
  elsif v_status = 'review_required' then
    v_reason := format('first order %s (%s balls) was cancelled after the cut-over without ever being confirmed', v_first.by_date, v_d.qty);
  end if;

  update public.customer_bonus_entitlements
     set status = v_status, deciding_order_id = v_first.by_date, deciding_order_quantity = v_d.qty, deciding_era = v_d.era,
         holder_order_id = case when v_status = 'pending_first_order' then v_first.by_date end,
         determined_at = now(), updated_at = now()
   where customer_id = p_customer_id;
  perform public.bonus_event(p_customer_id, 'determined', v_first.by_date, null, 'undetermined', v_status, null,
                             format('First non-trial order %s: %s ball(s) ordered, %s era%s', v_first.by_date, v_d.qty, v_d.era,
                                    case when v_reason is not null then '; review: ' || v_reason else '' end));
  if v_status = 'review_required' then
    perform public.bonus_review_log(p_customer_id, v_first.by_date, v_reason);
  end if;
  return v_status;
end;
$fn$;

-- After eligibility was decided: if a later change puts a different order
-- first (by date or by entry) while a bonus is pending, earned or paid, the
-- decision can no longer be trusted. Never changes money automatically:
-- pending -> review; earned (unpaid) -> review and blocked from payment;
-- paid -> flagged for review, no clawback.
create or replace function public.bonus_recheck(p_customer_id text, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_e     public.customer_bonus_entitlements%rowtype;
  v_first record;
  v_why   text;
begin
  if p_customer_id is null then
    return;
  end if;
  select * into v_e from public.customer_bonus_entitlements where customer_id = p_customer_id for update;
  if not found or v_e.status not in ('pending_first_order', 'transferable', 'earned', 'paid') then
    return;
  end if;
  select * into v_first from public.bonus_first_orders(p_customer_id);
  if v_first.by_date is not distinct from v_e.deciding_order_id
     and v_first.by_entry is not distinct from v_e.deciding_order_id then
    return;   -- the deciding order is still first by date and by entry
  end if;
  v_why := format('%s: the deciding order %s is no longer first (first by date %s, first entered %s)',
                  p_reason, coalesce(v_e.deciding_order_id, '(deleted)'), coalesce(v_first.by_date, '-'), coalesce(v_first.by_entry, '-'));

  if v_e.status in ('earned', 'paid') and v_e.holder_commission_id is not null then
    update public.commissions
       set review_required = true, updated_at = now(), review_reason = 'First-order bonus eligibility in doubt: ' || v_why
     where id = v_e.holder_commission_id and not review_required;
  end if;
  if v_e.status <> 'paid' then
    update public.customer_bonus_entitlements set status = 'review_required', updated_at = now() where customer_id = p_customer_id;
  end if;
  perform public.bonus_event(p_customer_id, 'review_flagged', v_e.holder_order_id, v_e.holder_commission_id, v_e.status,
                             case when v_e.status = 'paid' then 'paid' else 'review_required' end, null, v_why);
  perform public.bonus_review_log(p_customer_id, v_e.deciding_order_id, v_why);
end;
$fn$;

create or replace function public.trg_orders_bonus_recheck()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    perform public.bonus_recheck(old.customer_id, case tg_op when 'DELETE' then 'order ' || old.id || ' deleted'
                                                  else 'order ' || old.id || ' date, customer or type changed' end);
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.customer_id is distinct from (case when tg_op = 'UPDATE' then old.customer_id end) then
    perform public.bonus_recheck(new.customer_id, 'order ' || new.id || case when tg_op = 'INSERT' then ' entered' else ' moved to this customer' end);
  end if;
  return null;
end;
$fn$;

-- An order that decided, holds or appears in a customer's first-order bonus
-- history cannot be deleted (the history is append-only evidence).
create or replace function public.guard_orders_bonus_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if exists (select 1 from public.commission_bonus_events where order_id = old.id)
     or exists (select 1 from public.customer_bonus_entitlements where deciding_order_id = old.id or holder_order_id = old.id) then
    raise exception 'Order % is part of a customer''s first-order bonus history and cannot be deleted', old.id
      using errcode = '42501';
  end if;
  return old;
end;
$fn$;

drop trigger if exists trg_orders_bonus_history_guard on public.orders;
create trigger trg_orders_bonus_history_guard
  before delete on public.orders
  for each row execute function public.guard_orders_bonus_history();

drop trigger if exists trg_orders_bonus_recheck on public.orders;
create trigger trg_orders_bonus_recheck
  after insert or delete or update of order_date, customer_id, order_type on public.orders
  for each row execute function public.trg_orders_bonus_recheck();

-- ASSUMPTION A1 (bonus timing, unapproved until approve_bonus_timing()): the
-- bonus is decided and created here, when a per-ball, non-trial order becomes
-- fully delivered. This is the only place the timing is implemented.
create or replace function public.bonus_award_on_full_delivery(p_order_id text)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
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
$fn$;

-- Called when an order is cancelled.
create or replace function public.bonus_on_order_cancelled(p_order_id text)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_o public.orders%rowtype;
  v_e public.customer_bonus_entitlements%rowtype;
  v_c public.commissions%rowtype;
begin
  select * into v_o from public.orders where id = p_order_id;
  if v_o.order_type = 'trial' or v_o.customer_id is null then
    return;
  end if;
  perform public.bonus_refresh(v_o.customer_id);
  select * into v_e from public.customer_bonus_entitlements where customer_id = v_o.customer_id for update;
  if v_e.holder_order_id is distinct from p_order_id then
    return;
  end if;

  if v_e.status = 'pending_first_order' then
    update public.customer_bonus_entitlements
       set status = 'transferable', holder_order_id = null, updated_at = now()
     where customer_id = v_o.customer_id;
    perform public.bonus_event(v_o.customer_id, 'released', p_order_id, null, 'pending_first_order', 'transferable', null,
                               'Deciding order cancelled before earning the bonus');
  elsif v_e.status = 'earned' then
    select * into v_c from public.commissions where id = v_e.holder_commission_id for update;
    if v_c.status in ('pending', 'approved') then
      update public.commissions
         set status = 'void', voided_at = now(), updated_at = now(),
             void_reason = 'Order cancelled before the first-order bonus was paid; bonus released'
       where id = v_c.id;
      update public.customer_bonus_entitlements
         set status = 'transferable', holder_order_id = null, holder_commission_id = null, updated_at = now()
       where customer_id = v_o.customer_id;
      perform public.bonus_event(v_o.customer_id, 'voided', p_order_id, v_c.id, 'earned', 'earned', v_c.amount, 'Order cancelled');
      perform public.bonus_event(v_o.customer_id, 'released', p_order_id, v_c.id, 'earned', 'transferable', null, '');
    end if;
  elsif v_e.status = 'paid' then
    update public.commissions
       set review_required = true, updated_at = now(),
           review_reason = 'Order cancelled after its first-order bonus was paid'
     where id = v_e.holder_commission_id and not review_required;
    perform public.bonus_event(v_o.customer_id, 'review_flagged', p_order_id, v_e.holder_commission_id, 'paid', 'paid', null,
                               'Order cancelled after the bonus was paid - manual review, no clawback');
    insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
    values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'WARNING', 'FINANCIAL',
            format('Commission review required: order %s was cancelled after its first-order bonus was paid', p_order_id),
            public.current_profile_id(), coalesce(public.current_profile_name(), ''), p_order_id,
            jsonb_build_object('source', 'db', 'event', 'commission_review_required', 'commissionId', v_e.holder_commission_id));
  end if;
end;
$fn$;

-- A paid bonus marks the entitlement paid.
create or replace function public.trg_bonus_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if new.kind = 'first_order_bonus' and new.status = 'paid' and old.status is distinct from 'paid' then
    update public.customer_bonus_entitlements
       set status = 'paid', updated_at = now()
     where customer_id = new.bonus_customer_id and holder_commission_id = new.id;
    perform public.bonus_event(new.bonus_customer_id, 'paid', new.order_id, new.id, 'earned', 'paid', new.amount, '');
  end if;
  return null;
end;
$fn$;

drop trigger if exists trg_commissions_bonus_paid on public.commissions;
create trigger trg_commissions_bonus_paid
  after update of status on public.commissions
  for each row execute function public.trg_bonus_paid();

-- Back-fill: customers whose first non-trial order is already decided.
do $bf$
declare
  v_c record;
begin
  for v_c in select distinct customer_id from public.orders where customer_id is not null and order_type <> 'trial'
  loop
    perform public.bonus_refresh(v_c.customer_id);
  end loop;
end
$bf$;

-- ============================================================================
-- 7. LEGACY COMMISSION SYNC (percentage) - never touches per-ball rows
-- ============================================================================

create or replace function public.sync_order_commission()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
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
$fn$;

drop trigger if exists trg_orders_commission on public.orders;
drop trigger if exists trg_orders_commission_ins on public.orders;
drop trigger if exists trg_orders_commission_upd on public.orders;
create trigger trg_orders_commission_ins
  after insert on public.orders
  for each row execute function public.sync_order_commission();
-- Fires only on a GENUINE change: recalc_order_financials rewrites total on
-- every payment with the same value, which no longer reaches commissions.
create trigger trg_orders_commission_upd
  after update of status, marketing_officer_id, total on public.orders
  for each row
  when (old.status is distinct from new.status
        or old.marketing_officer_id is distinct from new.marketing_officer_id
        or old.total is distinct from new.total)
  execute function public.sync_order_commission();

-- ============================================================================
-- 8. CLASSIFICATION AT CONFIRMATION, DELIVERIES, STATUS CHANGES
-- ============================================================================

create or replace function public.classify_order_commission(p_order_id text)
returns text
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_model text;
  v_cut   timestamptz;
begin
  select model into v_model from public.order_commission_class where order_id = p_order_id;
  if v_model is not null then
    return v_model;
  end if;
  select cutover_at into v_cut from public.commission_policy where id;
  v_model := case when v_cut is not null and now() >= v_cut then 'per_ball_v1' else 'legacy_percent' end;
  insert into public.order_commission_class (order_id, model, classified_at, cutover_at_snapshot, source)
  values (p_order_id, v_model, now(), v_cut, 'confirmation')
  on conflict (order_id) do nothing;
  update public.orders set confirmed_at = coalesce(confirmed_at, now()) where id = p_order_id;
  return (select model from public.order_commission_class where order_id = p_order_id);
end;
$fn$;

-- Records one delivery. p_lines = [{orderItemId, quantity}], or NULL for
-- "everything still outstanding". Internal: callers check permission and scope.
create or replace function public.deliver_order_internal(p_order_id text, p_lines jsonb, p_note text,
                                                         p_request_id uuid, p_any_open_status boolean)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
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
$fn$;

-- Public RPC: record a (partial) delivery. Same permission and order scope as
-- status changes. p_request_id makes a retry return the same delivery.
create or replace function public.record_delivery(p_order_id text, p_lines jsonb, p_note text default '',
                                                  p_request_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_order    public.orders%rowtype;
  v_existing public.order_deliveries%rowtype;
begin
  perform public.require_permission('edit_orders');

  select * into v_order from public.orders where id = p_order_id for update;
  if not found
     or (auth.uid() is not null
         and not public.can_access_order(v_order.customer_id, v_order.marketing_officer_id)) then
    raise exception 'Unknown order: %', p_order_id;
  end if;

  if p_request_id is not null then
    select * into v_existing from public.order_deliveries where request_id = p_request_id;
    if found then
      if v_existing.order_id <> p_order_id then
        raise exception 'Request % was already used for another order', p_request_id;
      end if;
      return v_existing.id;   -- retry of the same delivery: nothing new is recorded
    end if;
  end if;

  if p_lines is null then
    raise exception 'record_delivery needs the delivered lines and quantities';
  end if;
  return public.deliver_order_internal(p_order_id, p_lines, p_note, p_request_id, false);
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
$fn$;

-- ============================================================================
-- 9. DELIVERED-QUANTITY CORRECTION (Super Admin, reason, append-only record)
-- ============================================================================

create or replace function public.correct_delivered_quantity(
  p_order_item_id text,
  p_new_delivered integer,
  p_mode          text,
  p_reason        text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
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
$fn$;

-- ============================================================================
-- 10. create_order (stock at delivery), transfers (D7), payouts
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
  v_committed    integer;
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
    status, order_type, order_date, delivery_notes, created_by, legacy_reference_id, stock_mode
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
    v_order_id,
    'at_delivery'
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

    -- 12: stock leaves the shelf when balls are delivered, not when the order is
    -- taken. Refuse what is not available once earlier open orders are served.
    v_committed := public.product_committed_quantity(v_product.id);
    if v_product.stock - v_committed < v_qty then
      raise exception 'Insufficient stock for %: % available (% in stock, % promised to open orders), % requested',
        v_product.name, greatest(v_product.stock - v_committed, 0), v_product.stock, v_committed, v_qty;
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

    -- 12: no stock movement here; record_delivery() moves stock per delivered ball.
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
                                     and not c.review_required
                                     -- 12: per-ball commission is earned per delivery, so it is
                                     -- payable once delivered, even before the order is complete;
                                     -- legacy and bonus commission still need a delivered order.
                                     and ((c.kind in ('delivery', 'correction')
                                           and o.status::text in ('partially_delivered', 'delivered'))
                                          or (c.kind in ('legacy', 'first_order_bonus')
                                              and o.status::text = 'delivered')))),
         coalesce(sum(c.amount), 0)
    into v_found, v_bad, v_total
    from public.commissions c
    join public.orders o on o.id = c.order_id
   where c.id = any(v_ids);

  if v_found <> cardinality(v_ids) then
    raise exception '% of the selected commissions do not exist', cardinality(v_ids) - v_found;
  end if;

  if v_bad > 0 then
    raise exception '% of the selected commissions are not payable (already paid, void, $0, flagged for review, another officer''s, or not yet delivered)', v_bad;
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
-- 11. CUSTOMER OWNERSHIP: former officers lose the customer
-- ============================================================================
-- A Marketing Officer (own-customers-only) reaches a customer only while it is
-- assigned to them; having registered it no longer counts.

drop policy if exists customers_select on public.customers;
create policy customers_select on public.customers
  for select to authenticated
  using (
    public.has_permission('view_all_customers')
    or public.has_permission('view_customers')
    or (
      public.has_permission('view_own_customers_only')
      and marketing_officer_id = public.current_profile_id()
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
    )
  )
  with check (public.has_permission('edit_customers'));

-- The full transfer record (reason, officers, actor) is for management.
drop policy if exists customer_ownership_changes_select on public.customer_ownership_changes;
create policy customer_ownership_changes_select on public.customer_ownership_changes
  for select to authenticated
  using (
    public.has_any_permission(array['view_all_customers', 'view_customers', 'view_audit_trail'])
    or public.can_view_all_commissions()
  );

-- What an officer may know about transfers involving them: which customer, when,
-- and in which direction - never the reason or who did it.
create or replace view public.customer_transfer_notices
with (security_invoker = false, security_barrier = true) as
select
  ch.id,
  ch.customer_id,
  ch.customer_name,
  ch.changed_at,
  case when ch.old_officer_id = public.current_profile_id() then 'transferred_away'
       else 'transferred_to_you' end as direction
from public.customer_ownership_changes ch
where public.current_profile_id() is not null
  and (ch.old_officer_id = public.current_profile_id() or ch.new_officer_id = public.current_profile_id());

revoke all on public.customer_transfer_notices from public, anon;
grant select on public.customer_transfer_notices to authenticated;

-- ============================================================================
-- 12. FOOTBALL-ONLY PRODUCTS
-- ============================================================================
-- New products, and any category change, must be Football. Existing rows are
-- not rewritten (history is preserved).
create or replace function public.guard_products_football()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if new.category is distinct from 'Football'
     and (tg_op = 'INSERT' or new.category is distinct from old.category) then
    raise exception 'Football is the only active product category' using errcode = '42501';
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_products_football on public.products;
create trigger trg_products_football
  before insert or update of category on public.products
  for each row execute function public.guard_products_football();

-- ============================================================================
-- 13. VIEWS, AUDIT GUARD, ACCESS
-- ============================================================================

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
  o.delivered_at,
  o.confirmed_at,
  o.stock_mode,
  cc.model as commission_model
from public.orders o
left join public.order_commission_class cc on cc.order_id = o.id
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
        'lineProfit',         case when v.cost_ok then oi.line_profit end,
        'deliveredQuantity',  dq.delivered,
        'remainingQuantity',  greatest(oi.quantity - dq.delivered, 0)
      )
      order by oi.created_at, oi.id
    ) as items,
    sum(oi.quantity) as unit_count
  from public.order_items oi
  cross join lateral (
    select (coalesce((select sum(l.quantity) from public.order_delivery_lines l where l.order_item_id = oi.id), 0)
          + coalesce((select sum(a.delta) from public.delivered_quantity_adjustments a where a.order_item_id = oi.id), 0))::integer as delivered
  ) dq
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
    count(distinct order_id) filter (where status <> 'void')         as order_count
  from public.commissions
  where user_id = p.id
) c on true
left join lateral (
  select count(*) as customer_count
  from public.customers
  where marketing_officer_id = p.id
) cust on true;

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
$fn$;

alter table public.commission_policy              enable row level security;
alter table public.order_commission_class         enable row level security;
alter table public.order_deliveries               enable row level security;
alter table public.order_delivery_lines           enable row level security;
alter table public.delivered_quantity_adjustments enable row level security;
alter table public.customer_bonus_entitlements    enable row level security;
alter table public.commission_bonus_events        enable row level security;

drop policy if exists commission_policy_select on public.commission_policy;
create policy commission_policy_select on public.commission_policy
  for select to authenticated using (public.is_active_staff());

drop policy if exists order_commission_class_select on public.order_commission_class;
create policy order_commission_class_select on public.order_commission_class
  for select to authenticated using (exists (select 1 from public.orders o where o.id = order_id));

drop policy if exists order_deliveries_select on public.order_deliveries;
create policy order_deliveries_select on public.order_deliveries
  for select to authenticated using (exists (select 1 from public.orders o where o.id = order_id));

drop policy if exists order_delivery_lines_select on public.order_delivery_lines;
create policy order_delivery_lines_select on public.order_delivery_lines
  for select to authenticated using (exists (select 1 from public.orders o where o.id = order_id));

drop policy if exists delivered_quantity_adjustments_select on public.delivered_quantity_adjustments;
create policy delivered_quantity_adjustments_select on public.delivered_quantity_adjustments
  for select to authenticated using (public.is_super_admin() or public.has_permission('view_audit_trail'));

drop policy if exists customer_bonus_entitlements_select on public.customer_bonus_entitlements;
create policy customer_bonus_entitlements_select on public.customer_bonus_entitlements
  for select to authenticated using (public.can_view_all_commissions());

drop policy if exists commission_bonus_events_select on public.commission_bonus_events;
create policy commission_bonus_events_select on public.commission_bonus_events
  for select to authenticated using (public.can_view_all_commissions());

revoke all on public.commission_policy, public.order_commission_class, public.order_deliveries,
              public.order_delivery_lines, public.delivered_quantity_adjustments,
              public.customer_bonus_entitlements, public.commission_bonus_events
  from public, anon, authenticated;
grant select on public.commission_policy, public.order_commission_class, public.order_deliveries,
                public.order_delivery_lines, public.delivered_quantity_adjustments,
                public.customer_bonus_entitlements, public.commission_bonus_events
  to authenticated;

-- Public entry points (each checks its own permission).
revoke all on function public.record_delivery(text, jsonb, text, uuid)                 from public, anon;
revoke all on function public.correct_delivered_quantity(text, integer, text, text)    from public, anon;
revoke all on function public.activate_commission_model(text)                          from public, anon;
revoke all on function public.approve_bonus_timing(text)                               from public, anon;
grant execute on function public.approve_bonus_timing(text)                            to authenticated;
grant execute on function public.record_delivery(text, jsonb, text, uuid)              to authenticated;
grant execute on function public.correct_delivered_quantity(text, integer, text, text) to authenticated;
grant execute on function public.activate_commission_model(text)                       to authenticated;

-- Internal helpers: database functions only.
revoke all on function public.deliver_order_internal(text, jsonb, text, uuid, boolean) from public, anon, authenticated;
revoke all on function public.classify_order_commission(text)                           from public, anon, authenticated;
revoke all on function public.bonus_refresh(text)                                       from public, anon, authenticated;
revoke all on function public.bonus_decision(text)                                      from public, anon, authenticated;
revoke all on function public.bonus_first_orders(text)                                  from public, anon, authenticated;
revoke all on function public.bonus_recheck(text, text)                                 from public, anon, authenticated;
revoke all on function public.bonus_review_log(text, text, text)                        from public, anon, authenticated;
revoke all on function public.bonus_award_on_full_delivery(text)                        from public, anon, authenticated;
revoke all on function public.bonus_on_order_cancelled(text)                            from public, anon, authenticated;
revoke all on function public.bonus_event(text, text, text, uuid, text, text, numeric, text) from public, anon, authenticated;
revoke all on function public.item_delivered_quantity(text)                             from public, anon, authenticated;
revoke all on function public.order_delivered_quantity(text)                            from public, anon, authenticated;
revoke all on function public.product_committed_quantity(text)                          from public, anon, authenticated;
revoke all on function public.original_ordered_balls(text)                              from public, anon, authenticated;

commit;
