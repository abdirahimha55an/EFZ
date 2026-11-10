-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 33 : Expense Management (Phase 14)
-- ----------------------------------------------------------------------------
-- STATUS: written 2026-11-10. Applied to EFZ-Staging ONLY (see docs/EXPENSE_MANAGEMENT.md). NOT on Production.
-- Additive and forward-only: no existing table, view, policy, grant or function is changed. It only
--   * adds four rows to public.permissions (granted to nobody; Super Admin has everything),
--   * adds 4 tables, 1 view, 1 sequence, helper/trigger functions and 8 RPCs,
--   * reads orders, profiles and commissions (never writes them).
-- Idempotent: safe to re-run. Rollback: supabase/rollback/33_expense_management_rollback.sql
--
-- MODEL
--   expense_categories  fixed seeded list; kind = direct_order | operating. Inventory purchases / cost of goods are
--                       deliberately NOT categories: delivered stock is already costed through order_items.historical_unit_cost.
--   expenses            one row per expense; status pending | approved | rejected | void. USD only. Never deleted.
--                       direct_order expenses must name an order; operating expenses must not.
--   expense_payments    append-only cash records against an APPROVED expense; approval and payment are separate.
--   expense_events      append-only timeline (who, when, what changed).
--   expense_overview    view (security_invoker): each expense plus paid / outstanding / payment_status, derived from payments.
-- WRITES: only through RPCs (submit_expense, edit_expense, decide_expense, void_expense, record_expense_payment,
--   void_expense_payment). No client has INSERT/UPDATE/DELETE on any table. Every RPC checks the caller, writes an event and a
--   FINANCIAL audit line (system_logs) in the same transaction.
-- ACCESS (flat permissions, granted explicitly, never by role):
--   submit_expenses  submit, edit own pending/rejected, see own expenses, withdraw own pending/rejected
--   view_expenses    see all expenses
--   approve_expenses approve / reject (never your own, Super Admin included) and void approved ones (never your own); sees all
--   pay_expenses     record / void payments; sees all
-- PROFIT READS: finance_expense_costs() and finance_commission_costs() feed the Financial page. They are SECURITY DEFINER
--   functions gated by explicit permissions (see each), so a user without them gets a refusal, never a silently partial figure.
-- ============================================================================

begin;

set local lock_timeout = '30s';

-- ============================================================================
-- 0. PRE-GUARD
-- ============================================================================
do $pre$
begin
  if to_regprocedure('public.has_permission(text)') is null
     or to_regprocedure('public.has_any_permission(text[])') is null
     or to_regprocedure('public.current_profile_id()') is null
     or to_regprocedure('public.current_profile_name()') is null
     or to_regprocedure('public.efz_today()') is null
     or to_regprocedure('public.can_access_order(text, text)') is null
     or to_regclass('public.orders') is null
     or to_regclass('public.profiles') is null
     or to_regclass('public.commissions') is null
     or to_regclass('public.permissions') is null
     or to_regclass('public.system_logs') is null then
    raise exception '33: a required base object is missing - refusing';
  end if;
end
$pre$;

-- ============================================================================
-- 1. PERMISSIONS (granted to nobody here)
-- ============================================================================
insert into public.permissions (code, label, category, sort_order) values
  ('view_expenses',    'View all expenses',                      'Finance', 63),
  ('submit_expenses',  'Submit expenses (and see own)',          'Finance', 64),
  ('approve_expenses', 'Approve / reject / void expenses',       'Finance', 65),
  ('pay_expenses',     'Record expense payments',                'Finance', 66)
on conflict (code) do nothing;

-- ============================================================================
-- 2. TABLES
-- ============================================================================
create table if not exists public.expense_categories (
  id         text primary key check (id ~ '^[a-z0-9_]+$'),
  name       text not null unique check (char_length(btrim(name)) between 1 and 80),
  kind       text not null check (kind in ('direct_order', 'operating')),
  is_active  boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

insert into public.expense_categories (id, name, kind, sort_order) values
  ('delivery',            'Delivery',                    'direct_order', 10),
  ('packaging',           'Packaging',                   'direct_order', 20),
  ('shopping_bags',       'Shopping bags',               'direct_order', 30),
  ('special_transport',   'Special transport',           'direct_order', 40),
  ('other_fulfilment',    'Other fulfilment cost',       'direct_order', 50),
  ('rent',                'Rent',                        'operating',    110),
  ('salaries',            'Salaries',                    'operating',    120),
  ('utilities',           'Utilities',                   'operating',    130),
  ('internet',            'Internet',                    'operating',    140),
  ('marketing',           'Marketing',                   'operating',    150),
  ('transport_allowance', 'Transport allowance',         'operating',    160),
  ('administration',      'Administration',              'operating',    170),
  ('other_operating',     'Other operating expense',     'operating',    180)
on conflict (id) do nothing;

create sequence if not exists public.expense_reference_seq;

create table if not exists public.expenses (
  id                uuid primary key default gen_random_uuid(),
  reference         text not null unique
                    default ('EXP-' || to_char(public.efz_today(), 'YYYY') || '-' || lpad(nextval('public.expense_reference_seq')::text, 6, '0')),
  kind              text not null check (kind in ('direct_order', 'operating')),
  category_id       text not null references public.expense_categories(id),
  description       text not null check (char_length(btrim(description)) between 1 and 300),
  amount            numeric(14, 2) not null check (amount > 0 and amount <= 1000000),
  currency          text not null default 'USD' check (currency = 'USD'),
  expense_date      date not null check (expense_date >= date '2020-01-01'),
  payment_method    text not null default '' check (char_length(payment_method) <= 60),
  vendor            text not null default '' check (char_length(vendor) <= 200),
  order_id          text references public.orders(id) on delete restrict,
  notes             text not null default '' check (char_length(notes) <= 1000),
  receipt_path      text check (receipt_path is null or char_length(receipt_path) <= 500),   -- reserved for the receipt-upload stage
  submitted_by      text not null references public.profiles(id),
  submitted_by_name text not null default '',
  submitted_at      timestamptz not null default now(),
  approval_status   text not null default 'pending' check (approval_status in ('pending', 'approved', 'rejected', 'void')),
  decided_by        text references public.profiles(id),
  decided_by_name   text not null default '',
  decided_at        timestamptz,
  rejection_reason  text check (rejection_reason is null or char_length(btrim(rejection_reason)) between 3 and 500),
  void_reason       text check (void_reason is null or char_length(btrim(void_reason)) between 3 and 500),
  voided_by         text references public.profiles(id),
  voided_by_name    text not null default '',
  voided_at         timestamptz,
  updated_at        timestamptz not null default now(),
  constraint expenses_order_link_check     check ((kind = 'direct_order') = (order_id is not null)),
  constraint expenses_decision_check       check (approval_status not in ('approved', 'rejected') or (decided_by is not null and decided_at is not null)),
  constraint expenses_rejection_check      check (approval_status <> 'rejected' or rejection_reason is not null),
  constraint expenses_void_check           check (approval_status <> 'void' or (void_reason is not null and voided_at is not null and voided_by is not null)),
  -- nobody decides their own expense (Super Admin included); the RPC says so in words, this is the backstop
  constraint expenses_no_self_decision     check (decided_by is null or decided_by <> submitted_by)
);
create index if not exists expenses_status_idx    on public.expenses (approval_status, expense_date desc);
create index if not exists expenses_date_idx      on public.expenses (expense_date desc);
create index if not exists expenses_order_idx     on public.expenses (order_id) where order_id is not null;
create index if not exists expenses_submitter_idx on public.expenses (submitted_by, submitted_at desc);

create table if not exists public.expense_payments (
  id          uuid primary key default gen_random_uuid(),
  expense_id  uuid not null references public.expenses(id) on delete restrict,
  amount      numeric(14, 2) not null check (amount > 0),
  paid_on     date not null check (paid_on >= date '2020-01-01'),
  method      text not null default '' check (char_length(method) <= 60),
  reference   text not null default '' check (char_length(reference) <= 120),
  recorded_by text not null references public.profiles(id),
  recorded_by_name text not null default '',
  recorded_at timestamptz not null default now(),
  void_reason text check (void_reason is null or char_length(btrim(void_reason)) between 3 and 500),
  voided_by   text references public.profiles(id),
  voided_at   timestamptz,
  constraint expense_payments_void_check check ((voided_at is null) = (void_reason is null and voided_by is null))
);
create index if not exists expense_payments_expense_idx on public.expense_payments (expense_id, recorded_at);

create table if not exists public.expense_events (
  id          uuid primary key default gen_random_uuid(),
  seq         bigint generated always as identity,
  expense_id  uuid not null references public.expenses(id) on delete restrict,
  event       text not null check (event in ('submitted', 'edited', 'resubmitted', 'approved', 'rejected', 'voided', 'payment_recorded', 'payment_voided')),
  from_status text,
  to_status   text,
  actor_id    text references public.profiles(id),
  actor_name  text not null default '',
  note        text,
  details     jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);
create index if not exists expense_events_expense_idx on public.expense_events (expense_id, seq);

-- ============================================================================
-- 3. GUARDS (defence in depth: the RPCs are the only writers, these make the rules hold for anyone, including the table owner)
-- ============================================================================
create or replace function public.guard_expense_row()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if tg_op = 'DELETE' then
    raise exception 'Expenses cannot be deleted - void them instead' using errcode = '42501';
  end if;
  -- identity never changes
  if new.id is distinct from old.id or new.reference is distinct from old.reference
     or new.currency is distinct from old.currency or new.submitted_by is distinct from old.submitted_by
     or new.submitted_at is distinct from old.submitted_at then
    raise exception 'An expense''s identity (id, reference, currency, submitter, submission time) cannot change' using errcode = '42501';
  end if;
  if old.approval_status = 'void' then
    raise exception 'A void expense cannot be changed' using errcode = '42501';
  end if;
  if old.approval_status = 'approved' then
    -- approved: the only legal change is to void, and nothing else moves
    if new.approval_status <> 'void'
       or new.kind is distinct from old.kind or new.category_id is distinct from old.category_id
       or new.description is distinct from old.description or new.amount is distinct from old.amount
       or new.expense_date is distinct from old.expense_date or new.payment_method is distinct from old.payment_method
       or new.vendor is distinct from old.vendor or new.order_id is distinct from old.order_id
       or new.notes is distinct from old.notes or new.receipt_path is distinct from old.receipt_path
       or new.decided_by is distinct from old.decided_by or new.decided_at is distinct from old.decided_at then
      raise exception 'An approved expense cannot be modified - void it (with a reason) and submit a new one' using errcode = '42501';
    end if;
  elsif old.approval_status = 'pending' then
    if new.approval_status not in ('pending', 'approved', 'rejected', 'void') then
      raise exception 'Invalid expense status change' using errcode = '42501';
    end if;
  elsif old.approval_status = 'rejected' then
    if new.approval_status not in ('rejected', 'pending', 'void') then
      raise exception 'A rejected expense can only be resubmitted or voided' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_expenses_guard on public.expenses;
create trigger trg_expenses_guard
  before update or delete on public.expenses
  for each row execute function public.guard_expense_row();

create or replace function public.guard_expense_child()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if tg_table_name = 'expense_events' then
    raise exception 'expense_events rows are append-only' using errcode = '42501';
  end if;
  -- expense_payments: never deleted; the only update is voiding an active payment
  if tg_op = 'DELETE' then
    raise exception 'Payments cannot be deleted - void them instead' using errcode = '42501';
  end if;
  if old.voided_at is not null
     or new.expense_id is distinct from old.expense_id or new.amount is distinct from old.amount
     or new.paid_on is distinct from old.paid_on or new.method is distinct from old.method
     or new.reference is distinct from old.reference or new.recorded_by is distinct from old.recorded_by
     or new.recorded_at is distinct from old.recorded_at or new.voided_at is null then
    raise exception 'A payment can only be voided, once' using errcode = '42501';
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_expense_events_guard on public.expense_events;
create trigger trg_expense_events_guard
  before update or delete on public.expense_events
  for each row execute function public.guard_expense_child();

drop trigger if exists trg_expense_payments_guard on public.expense_payments;
create trigger trg_expense_payments_guard
  before update or delete on public.expense_payments
  for each row execute function public.guard_expense_child();

-- ============================================================================
-- 4. INTERNAL HELPERS (not callable by clients)
-- ============================================================================
create or replace function public.expense_record(p_expense_id uuid, p_event text, p_from text, p_to text, p_note text, p_details jsonb, p_message text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
begin
  insert into public.expense_events (expense_id, event, from_status, to_status, actor_id, actor_name, note, details)
  values (p_expense_id, p_event, p_from, p_to, public.current_profile_id(), coalesce(public.current_profile_name(), ''), p_note, coalesce(p_details, '{}'::jsonb));
  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'FINANCIAL', p_message,
          public.current_profile_id(), coalesce(public.current_profile_name(), ''), p_expense_id::text,
          jsonb_build_object('source', 'db', 'event', 'expense_' || p_event, 'expenseId', p_expense_id) || coalesce(p_details, '{}'::jsonb));
end;
$fn$;

-- Validates and normalises an expense payload (used by submit and edit). Returns the cleaned values.
create or replace function public.expense_clean(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_cat      public.expense_categories%rowtype;
  v_desc     text := btrim(coalesce(p_payload ->> 'description', ''));
  v_amount   numeric;
  v_date     date;
  v_method   text := btrim(coalesce(p_payload ->> 'paymentMethod', ''));
  v_vendor   text := btrim(coalesce(p_payload ->> 'vendor', ''));
  v_notes    text := btrim(coalesce(p_payload ->> 'notes', ''));
  v_order_id text := nullif(btrim(coalesce(p_payload ->> 'orderId', '')), '');
  v_order    public.orders%rowtype;
begin
  select * into v_cat from public.expense_categories where id = btrim(coalesce(p_payload ->> 'categoryId', ''));
  if not found or not v_cat.is_active then
    raise exception 'Please choose an expense category' using errcode = '22023';
  end if;
  if char_length(v_desc) not between 1 and 300 then
    raise exception 'Please describe the expense (up to 300 characters)' using errcode = '22023';
  end if;
  begin
    v_amount := (p_payload ->> 'amount')::numeric;
  exception when others then
    raise exception 'The amount must be a number' using errcode = '22023';
  end;
  if v_amount is null or v_amount <= 0 or v_amount > 1000000 or round(v_amount, 2) <> v_amount then
    raise exception 'The amount must be above 0, at most 1,000,000, with at most 2 decimals' using errcode = '22023';
  end if;
  begin
    v_date := (p_payload ->> 'expenseDate')::date;
  exception when others then
    raise exception 'Please give the expense date' using errcode = '22023';
  end;
  if v_date is null or v_date < date '2020-01-01' or v_date > public.efz_today() then
    raise exception 'The expense date cannot be in the future' using errcode = '22023';
  end if;
  if char_length(v_method) > 60 or char_length(v_vendor) > 200 or char_length(v_notes) > 1000 then
    raise exception 'A field is too long' using errcode = '22023';
  end if;
  if v_cat.kind = 'direct_order' then
    if v_order_id is null then
      raise exception 'A direct order expense must name its order' using errcode = '22023';
    end if;
    select * into v_order from public.orders where id = v_order_id;
    if not found or not public.can_access_order(v_order.customer_id, v_order.marketing_officer_id) then
      raise exception 'That order does not exist or you cannot see it' using errcode = '22023';
    end if;
  elsif v_order_id is not null then
    raise exception 'An operating expense is not linked to an order' using errcode = '22023';
  end if;
  return jsonb_build_object('category_id', v_cat.id, 'kind', v_cat.kind, 'description', v_desc, 'amount', v_amount,
                            'expense_date', v_date, 'payment_method', v_method, 'vendor', v_vendor,
                            'order_id', v_order_id, 'notes', v_notes);
end;
$fn$;

-- ============================================================================
-- 5. RPCs
-- ============================================================================
create or replace function public.submit_expense(p_payload jsonb)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_me    text := public.current_profile_id();
  v_clean jsonb;
  v_id    uuid := gen_random_uuid();
  v_ref   text;
begin
  if v_me is null or not public.has_permission('submit_expenses') then
    raise exception 'You are not allowed to submit expenses' using errcode = '42501';
  end if;
  v_clean := public.expense_clean(p_payload);
  insert into public.expenses (id, kind, category_id, description, amount, expense_date, payment_method, vendor, order_id, notes,
                               submitted_by, submitted_by_name)
  values (v_id, v_clean ->> 'kind', v_clean ->> 'category_id', v_clean ->> 'description', (v_clean ->> 'amount')::numeric,
          (v_clean ->> 'expense_date')::date, v_clean ->> 'payment_method', v_clean ->> 'vendor', v_clean ->> 'order_id',
          v_clean ->> 'notes', v_me, coalesce(public.current_profile_name(), ''))
  returning reference into v_ref;
  perform public.expense_record(v_id, 'submitted', null, 'pending', null,
          jsonb_build_object('reference', v_ref, 'kind', v_clean ->> 'kind', 'amount', (v_clean ->> 'amount')::numeric, 'orderId', v_clean ->> 'order_id'),
          format('Expense %s submitted: %s $%s', v_ref, v_clean ->> 'kind', to_char((v_clean ->> 'amount')::numeric, 'FM999999990.00')));
  return v_id;
end;
$fn$;

create or replace function public.edit_expense(p_expense_id uuid, p_payload jsonb)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_me      text := public.current_profile_id();
  v_row     public.expenses%rowtype;
  v_clean   jsonb;
  v_before  jsonb;
  v_changed text[] := '{}';
  v_key     text;
begin
  select * into v_row from public.expenses where id = p_expense_id for update;
  if not found or v_me is null or v_row.submitted_by <> v_me or not public.has_permission('submit_expenses') then
    raise exception 'Only the person who submitted an expense can edit it' using errcode = '42501';
  end if;
  if v_row.approval_status not in ('pending', 'rejected') then
    raise exception 'A % expense cannot be edited', v_row.approval_status using errcode = 'WR409';
  end if;
  v_clean := public.expense_clean(p_payload);
  v_before := jsonb_build_object('category_id', v_row.category_id, 'kind', v_row.kind, 'description', v_row.description,
                                 'amount', v_row.amount, 'expense_date', v_row.expense_date, 'payment_method', v_row.payment_method,
                                 'vendor', v_row.vendor, 'order_id', v_row.order_id, 'notes', v_row.notes);
  for v_key in select jsonb_object_keys(v_clean) loop
    if (v_clean -> v_key) is distinct from (v_before -> v_key)
       and not (jsonb_typeof(v_clean -> v_key) = 'number' and (v_clean ->> v_key)::numeric = (v_before ->> v_key)::numeric)
       and not (v_key = 'expense_date' and (v_clean ->> v_key)::date = (v_before ->> v_key)::date) then
      v_changed := v_changed || v_key;
    end if;
  end loop;
  if cardinality(v_changed) = 0 and v_row.approval_status = 'pending' then
    return;   -- nothing changed: no write, no event
  end if;
  update public.expenses
     set kind = v_clean ->> 'kind', category_id = v_clean ->> 'category_id', description = v_clean ->> 'description',
         amount = (v_clean ->> 'amount')::numeric, expense_date = (v_clean ->> 'expense_date')::date,
         payment_method = v_clean ->> 'payment_method', vendor = v_clean ->> 'vendor', order_id = v_clean ->> 'order_id',
         notes = v_clean ->> 'notes', updated_at = now(),
         approval_status = 'pending', decided_by = null, decided_by_name = '', decided_at = null, rejection_reason = null
   where id = p_expense_id;
  perform public.expense_record(p_expense_id,
          case when v_row.approval_status = 'rejected' then 'resubmitted' else 'edited' end,
          v_row.approval_status, 'pending', v_row.rejection_reason,
          jsonb_build_object('changed', to_jsonb(v_changed), 'before', v_before, 'after', v_clean),
          format('Expense %s %s', v_row.reference, case when v_row.approval_status = 'rejected' then 'resubmitted after rejection' else 'edited (' || array_to_string(v_changed, ', ') || ')' end));
end;
$fn$;

create or replace function public.decide_expense(p_expense_id uuid, p_decision text, p_reason text default null)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_me     text := public.current_profile_id();
  v_row    public.expenses%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if v_me is null or not public.has_permission('approve_expenses') then
    raise exception 'You are not allowed to approve or reject expenses' using errcode = '42501';
  end if;
  if p_decision not in ('approve', 'reject') then
    raise exception 'Decision must be approve or reject' using errcode = '22023';
  end if;
  select * into v_row from public.expenses where id = p_expense_id for update;
  if not found then
    raise exception 'Unknown expense' using errcode = '42501';
  end if;
  if v_row.submitted_by = v_me then
    raise exception 'You cannot approve or reject your own expense' using errcode = '42501';
  end if;
  if v_row.approval_status <> 'pending' then
    raise exception 'A % expense cannot be decided', v_row.approval_status using errcode = 'WR409';
  end if;
  if p_decision = 'reject' and (v_reason is null or char_length(v_reason) not between 3 and 500) then
    raise exception 'A rejection needs a reason (3 to 500 characters)' using errcode = '22023';
  end if;
  update public.expenses
     set approval_status = case when p_decision = 'approve' then 'approved' else 'rejected' end,
         decided_by = v_me, decided_by_name = coalesce(public.current_profile_name(), ''), decided_at = now(),
         rejection_reason = case when p_decision = 'reject' then v_reason else null end, updated_at = now()
   where id = p_expense_id;
  perform public.expense_record(p_expense_id, case when p_decision = 'approve' then 'approved' else 'rejected' end,
          'pending', case when p_decision = 'approve' then 'approved' else 'rejected' end, v_reason,
          jsonb_build_object('amount', v_row.amount, 'kind', v_row.kind),
          format('Expense %s %s', v_row.reference, case when p_decision = 'approve' then 'approved' else 'rejected: ' || v_reason end));
end;
$fn$;

create or replace function public.void_expense(p_expense_id uuid, p_reason text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_me     text := public.current_profile_id();
  v_row    public.expenses%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  select * into v_row from public.expenses where id = p_expense_id for update;
  if not found or v_me is null then
    raise exception 'Unknown expense' using errcode = '42501';
  end if;
  if char_length(v_reason) not between 3 and 500 then
    raise exception 'A reason is needed (3 to 500 characters)' using errcode = '22023';
  end if;
  if v_row.approval_status = 'void' then
    raise exception 'That expense is already void' using errcode = 'WR409';
  elsif v_row.approval_status in ('pending', 'rejected') then
    -- the submitter withdraws their own, or an approver voids it
    if not ((v_row.submitted_by = v_me and public.has_permission('submit_expenses')) or public.has_permission('approve_expenses')) then
      raise exception 'You are not allowed to void this expense' using errcode = '42501';
    end if;
  else
    -- approved: only an approver, never the submitter, and only with no active payment
    if not public.has_permission('approve_expenses') then
      raise exception 'You are not allowed to void an approved expense' using errcode = '42501';
    end if;
    if v_row.submitted_by = v_me then
      raise exception 'You cannot void your own approved expense; another approver must' using errcode = '42501';
    end if;
    if exists (select 1 from public.expense_payments where expense_id = p_expense_id and voided_at is null) then
      raise exception 'Void the payments of this expense first' using errcode = 'WR409';
    end if;
  end if;
  update public.expenses
     set approval_status = 'void', void_reason = v_reason, voided_by = v_me,
         voided_by_name = coalesce(public.current_profile_name(), ''), voided_at = now(), updated_at = now()
   where id = p_expense_id;
  perform public.expense_record(p_expense_id, 'voided', v_row.approval_status, 'void', v_reason,
          jsonb_build_object('amount', v_row.amount, 'wasApproved', v_row.approval_status = 'approved'),
          format('Expense %s voided (was %s): %s', v_row.reference, v_row.approval_status, v_reason));
end;
$fn$;

create or replace function public.record_expense_payment(p_expense_id uuid, p_amount numeric, p_paid_on date, p_method text, p_reference text default '')
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_me     text := public.current_profile_id();
  v_row    public.expenses%rowtype;
  v_paid   numeric;
  v_id     uuid := gen_random_uuid();
  v_method text := btrim(coalesce(p_method, ''));
  v_ref    text := btrim(coalesce(p_reference, ''));
begin
  if v_me is null or not public.has_permission('pay_expenses') then
    raise exception 'You are not allowed to record expense payments' using errcode = '42501';
  end if;
  select * into v_row from public.expenses where id = p_expense_id for update;
  if not found then
    raise exception 'Unknown expense' using errcode = '42501';
  end if;
  if v_row.approval_status <> 'approved' then
    raise exception 'Only an approved expense can be paid (this one is %)', v_row.approval_status using errcode = 'WR409';
  end if;
  if p_amount is null or p_amount <= 0 or round(p_amount, 2) <> p_amount then
    raise exception 'The payment must be above 0 with at most 2 decimals' using errcode = '22023';
  end if;
  if p_paid_on is null or p_paid_on < date '2020-01-01' or p_paid_on > public.efz_today() then
    raise exception 'The payment date cannot be in the future' using errcode = '22023';
  end if;
  if char_length(v_method) > 60 or char_length(v_ref) > 120 then
    raise exception 'A field is too long' using errcode = '22023';
  end if;
  select coalesce(sum(amount), 0) into v_paid from public.expense_payments where expense_id = p_expense_id and voided_at is null;
  if v_paid + p_amount > v_row.amount then
    raise exception 'That would pay more than the approved amount (approved %, already paid %)', v_row.amount, v_paid using errcode = 'WR409';
  end if;
  insert into public.expense_payments (id, expense_id, amount, paid_on, method, reference, recorded_by, recorded_by_name)
  values (v_id, p_expense_id, p_amount, p_paid_on, v_method, v_ref, v_me, coalesce(public.current_profile_name(), ''));
  perform public.expense_record(p_expense_id, 'payment_recorded', 'approved', 'approved', null,
          jsonb_build_object('paymentId', v_id, 'amount', p_amount, 'paidOn', p_paid_on, 'paidTotal', v_paid + p_amount, 'approved', v_row.amount),
          format('Expense %s payment recorded: $%s (paid %s of %s)', v_row.reference, to_char(p_amount, 'FM999999990.00'),
                 to_char(v_paid + p_amount, 'FM999999990.00'), to_char(v_row.amount, 'FM999999990.00')));
  return v_id;
end;
$fn$;

create or replace function public.void_expense_payment(p_payment_id uuid, p_reason text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_me     text := public.current_profile_id();
  v_pay    public.expense_payments%rowtype;
  v_exp    public.expenses%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if v_me is null or not public.has_permission('pay_expenses') then
    raise exception 'You are not allowed to void expense payments' using errcode = '42501';
  end if;
  select * into v_pay from public.expense_payments where id = p_payment_id for update;
  if not found then
    raise exception 'Unknown payment' using errcode = '42501';
  end if;
  if v_pay.voided_at is not null then
    raise exception 'That payment is already void' using errcode = 'WR409';
  end if;
  if char_length(v_reason) not between 3 and 500 then
    raise exception 'A reason is needed (3 to 500 characters)' using errcode = '22023';
  end if;
  select * into v_exp from public.expenses where id = v_pay.expense_id;
  update public.expense_payments set voided_at = now(), voided_by = v_me, void_reason = v_reason where id = p_payment_id;
  perform public.expense_record(v_pay.expense_id, 'payment_voided', v_exp.approval_status, v_exp.approval_status, v_reason,
          jsonb_build_object('paymentId', p_payment_id, 'amount', v_pay.amount),
          format('Expense %s payment of $%s voided: %s', v_exp.reference, to_char(v_pay.amount, 'FM999999990.00'), v_reason));
end;
$fn$;

-- ============================================================================
-- 6. READS
-- ============================================================================
create or replace view public.expense_overview with (security_invoker = true) as
select e.*,
       coalesce(p.paid, 0)::numeric(14, 2) as paid_amount,
       case when e.approval_status = 'approved' then (e.amount - coalesce(p.paid, 0))::numeric(14, 2) else 0::numeric(14, 2) end as outstanding_amount,
       case when e.approval_status <> 'approved' then null
            when coalesce(p.paid, 0) >= e.amount then 'paid'
            when coalesce(p.paid, 0) > 0 then 'partial'
            else 'unpaid' end as payment_status
  from public.expenses e
  left join lateral (select sum(x.amount) as paid from public.expense_payments x where x.expense_id = e.id and x.voided_at is null) p on true;

-- NOTE: inside SECURITY DEFINER functions can_see_customer_order() and can_view_cost() short-circuit to true (is_client_request() looks at
-- current_user), so order scope uses can_access_order() (11) and cost visibility is the explicit view_reports requirement.
-- Approved expenses for the profit chain. Explicit access only: view_reports AND (view_expenses or approve_expenses).
-- No vendor, description or notes leave this function.
create or replace function public.finance_expense_costs()
returns table (expense_id uuid, reference text, kind text, category_id text, amount numeric, expense_date date, order_id text, order_status text, payment_status text, paid_amount numeric)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not (public.has_permission('view_reports') and public.has_any_permission(array['view_expenses', 'approve_expenses'])
          and public.has_permission('view_reports')) then
    raise exception 'Expense figures need Financial reports plus expense access' using errcode = '42501';
  end if;
  return query
    select e.id, e.reference, e.kind, e.category_id, e.amount, e.expense_date, e.order_id, o.status::text,
           v.payment_status, v.paid_amount
      from public.expenses e
      join public.expense_overview v on v.id = e.id
      left join public.orders o on o.id = e.order_id
     where e.approval_status = 'approved'
       and (e.order_id is null or public.can_access_order(o.customer_id, o.marketing_officer_id));
end;
$fn$;

-- Commission cost per order for the profit chain: never void; dated by earned_at (legacy rows without it fall back to the order's
-- delivery date, then its order date). view_reports AND view_commissions; only orders the caller may see.
create or replace function public.finance_commission_costs()
returns table (commission_id uuid, order_id text, kind text, status text, amount numeric, attributed_at timestamptz, earned boolean, review_required boolean)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not (public.has_permission('view_reports') and public.has_permission('view_commissions')) then
    raise exception 'Commission figures need Financial reports plus commission access' using errcode = '42501';
  end if;
  return query
    select c.id, c.order_id, coalesce(c.kind, 'legacy'), c.status::text, c.amount,
           coalesce(c.earned_at, o.delivered_at, o.order_date::timestamptz),
           (c.earned_at is not null or o.status = 'delivered'),
           c.review_required
      from public.commissions c
      join public.orders o on o.id = c.order_id
     where c.status <> 'void' and c.amount > 0
       and public.can_access_order(o.customer_id, o.marketing_officer_id);
end;
$fn$;

-- ============================================================================
-- 7. ROW SECURITY AND GRANTS
-- ============================================================================
alter table public.expense_categories enable row level security;
alter table public.expenses           enable row level security;
alter table public.expense_payments   enable row level security;
alter table public.expense_events     enable row level security;

drop policy if exists expense_categories_select on public.expense_categories;
create policy expense_categories_select on public.expense_categories
  for select to authenticated
  using (public.has_any_permission(array['submit_expenses', 'view_expenses', 'approve_expenses', 'pay_expenses']));

drop policy if exists expenses_select on public.expenses;
create policy expenses_select on public.expenses
  for select to authenticated
  using (public.has_any_permission(array['view_expenses', 'approve_expenses', 'pay_expenses'])
         or (submitted_by = public.current_profile_id() and public.has_permission('submit_expenses')));

drop policy if exists expense_payments_select on public.expense_payments;
create policy expense_payments_select on public.expense_payments
  for select to authenticated
  using (exists (select 1 from public.expenses e where e.id = expense_payments.expense_id));

drop policy if exists expense_events_select on public.expense_events;
create policy expense_events_select on public.expense_events
  for select to authenticated
  using (exists (select 1 from public.expenses e where e.id = expense_events.expense_id));

-- No INSERT/UPDATE/DELETE policy exists for anyone: the RPCs are the only writers.
revoke all on public.expense_categories, public.expenses, public.expense_payments, public.expense_events, public.expense_overview
  from public, anon, authenticated;
grant select on public.expense_categories, public.expenses, public.expense_payments, public.expense_events, public.expense_overview to authenticated;
revoke all on sequence public.expense_reference_seq from public, anon, authenticated;

revoke all on function public.guard_expense_row()   from public, anon, authenticated;
revoke all on function public.guard_expense_child() from public, anon, authenticated;
revoke all on function public.expense_record(uuid, text, text, text, text, jsonb, text) from public, anon, authenticated;
revoke all on function public.expense_clean(jsonb)  from public, anon, authenticated;
revoke all on function public.submit_expense(jsonb)                              from public, anon, authenticated;
revoke all on function public.edit_expense(uuid, jsonb)                          from public, anon, authenticated;
revoke all on function public.decide_expense(uuid, text, text)                   from public, anon, authenticated;
revoke all on function public.void_expense(uuid, text)                           from public, anon, authenticated;
revoke all on function public.record_expense_payment(uuid, numeric, date, text, text) from public, anon, authenticated;
revoke all on function public.void_expense_payment(uuid, text)                   from public, anon, authenticated;
revoke all on function public.finance_expense_costs()                            from public, anon, authenticated;
revoke all on function public.finance_commission_costs()                         from public, anon, authenticated;

grant execute on function public.submit_expense(jsonb)                              to authenticated;
grant execute on function public.edit_expense(uuid, jsonb)                          to authenticated;
grant execute on function public.decide_expense(uuid, text, text)                   to authenticated;
grant execute on function public.void_expense(uuid, text)                           to authenticated;
grant execute on function public.record_expense_payment(uuid, numeric, date, text, text) to authenticated;
grant execute on function public.void_expense_payment(uuid, text)                   to authenticated;
grant execute on function public.finance_expense_costs()                            to authenticated;
grant execute on function public.finance_commission_costs()                         to authenticated;

-- ============================================================================
-- 8. POST-CHECKS: abort the whole migration if anything is half-installed
-- ============================================================================
do $post$
declare v_problem text;
begin
  select string_agg(p, '; ') into v_problem from (
    select 'permissions' as p where (select count(*) from public.permissions where code in ('view_expenses', 'submit_expenses', 'approve_expenses', 'pay_expenses')) <> 4
    union all select 'categories' where (select count(*) from public.expense_categories) < 13
    union all select 'rls' where not (select bool_and(relrowsecurity) from pg_class where oid in (
        'public.expense_categories'::regclass, 'public.expenses'::regclass, 'public.expense_payments'::regclass, 'public.expense_events'::regclass))
    union all select 'rpc ' || f from unnest(array['submit_expense(jsonb)', 'edit_expense(uuid,jsonb)', 'decide_expense(uuid,text,text)', 'void_expense(uuid,text)',
        'record_expense_payment(uuid,numeric,date,text,text)', 'void_expense_payment(uuid,text)', 'finance_expense_costs()', 'finance_commission_costs()']) f
        where to_regprocedure('public.' || f) is null
    union all select 'anon access' where has_table_privilege('anon', 'public.expenses', 'select') or has_function_privilege('anon', 'public.submit_expense(jsonb)', 'execute')
    union all select 'client write access' where has_table_privilege('authenticated', 'public.expenses', 'insert')
        or has_table_privilege('authenticated', 'public.expenses', 'update') or has_table_privilege('authenticated', 'public.expenses', 'delete')
    union all select 'triggers' where (select count(*) from pg_trigger where not tgisinternal and tgname in ('trg_expenses_guard', 'trg_expense_events_guard', 'trg_expense_payments_guard')) <> 3
  ) x;
  if v_problem is not null then
    raise exception '33 post-check failed: % - aborting', v_problem;
  end if;
  raise notice '33: expense management installed';
end
$post$;

commit;
