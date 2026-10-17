-- =============================================================================
-- 25 - Customer credit policy v2 (follows migrations 23 and 24). NOT APPLIED to any database until the owner approves it.
-- -----------------------------------------------------------------------------
-- Implements the credit policy EFZ approved for review:
--   * Default is permanent: a credit invoice that is not paid by its due date (no grace period) revokes the customer's credit at once. Paying the debt
--     settles it but does NOT restore credit: the customer must requalify from the beginning (approved period, qualifying paid orders, standing)
--     and a Super Admin must approve credit again, at the INITIAL limit. The default itself is kept forever (it can only be voided through a documented,
--     dispute-backed action, never silently). The check is made on the server at the moment a credit order is accepted, so it does not depend on any
--     scheduled job or on the customer opening the app; a daily run records defaults, sends the reminders and escalations.
--   * Standard eligibility: approved >= N days, >= N distinct qualifying completed and paid orders within a purchase window, no overdue invoice, no open
--     dispute, no unpaid delivered balance. All numbers live in the policy row; none is hard-coded.
--   * One fixed initial credit limit and one fixed repayment term; the limit is the customer's maximum OUTSTANDING credit balance (not a per-order allowance).
--     Automatic increases and late fees/interest cannot be switched on (a check constraint holds them off).
--   * A company-wide cap: a percentage of the average monthly sales revenue (orders.total of non-cancelled orders by order date, the same definition as the
--     daily_sales view and the Sales analytics "booked revenue") over the previous N complete calendar months. If the history is too short or empty the cap
--     is "not computable": credit cannot be enabled and no credit order is accepted.
--   * Authorized due-date extensions (recorded, never overwriting the original), a dispute workflow (customers raise, staff investigate and resolve;
--     an open dispute blocks new credit; nothing erases a default except a documented void), reminders at 7 days before / on the due date / 1 day,
--     7 days and 30 days overdue with idempotent delivery records, and an append-only credit event history.
--   * Account-duplication guard: default history follows the customer record AND any other customer record with the same canonical phone number.
-- Redefines: _customer_credit_eligibility, _customer_credit_summary, customer_credit_status, customer_payment_methods, my_finance,
--   customer_place_credit_order, set_credit_policy (same signature), set_customer_credit, credit_overview, credit_history.
-- Adds: 5 tables + customer_notifications, helper functions, and the admin/customer functions listed at the end.
-- Orders, payments, create_order, record_payment and every earlier object not named above are untouched.
-- Rollback: rollback/25_credit_policy_v2_rollback.sql (restores the migration-24 definitions; drops what this adds; read its header first).
-- =============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
begin
  if to_regprocedure('public.credit_history(text)') is null or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'credit_policy' and column_name = 'min_approved_days') then
    raise exception 'Migration 25 cannot run: migration 24 is not applied';
  end if;
end
$pre$;

-- -----------------------------------------------------------------------------
-- 1. Policy settings (every one empty/off until configured; the proposal values are loaded at the end, with credit OFF)
-- -----------------------------------------------------------------------------
alter table public.credit_policy add column if not exists purchase_window_days integer check (purchase_window_days is null or purchase_window_days >= 1);
alter table public.credit_policy add column if not exists initial_credit_limit numeric(14,2) check (initial_credit_limit is null or initial_credit_limit > 0);
alter table public.credit_policy add column if not exists company_cap_percent numeric(5,2) check (company_cap_percent is null or (company_cap_percent > 0 and company_cap_percent <= 100));
alter table public.credit_policy add column if not exists cap_basis_months integer check (cap_basis_months is null or cap_basis_months between 1 and 24);
alter table public.credit_policy add column if not exists allow_requirement_override boolean not null default false;
alter table public.credit_policy add column if not exists auto_limit_increase_enabled boolean not null default false check (not auto_limit_increase_enabled);
alter table public.credit_policy add column if not exists late_fees_enabled boolean not null default false check (not late_fees_enabled);

alter table public.customer_credit_accounts drop constraint if exists customer_credit_accounts_status_check;
alter table public.customer_credit_accounts add constraint customer_credit_accounts_status_check check (status in ('approved', 'suspended', 'revoked'));

-- -----------------------------------------------------------------------------
-- 2. Tables
-- -----------------------------------------------------------------------------
-- One row per invoice that missed its due date. Kept forever; only the settlement, void and review facts may be written later, once.
create table if not exists public.customer_credit_defaults (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        text not null references public.customers(id),
  order_id           text not null unique references public.orders(id),
  due_date           date not null,
  defaulted_on       date not null,
  amount_at_default  numeric(14,2) not null check (amount_at_default >= 0),
  limit_at_default   numeric(14,2),
  detected_at        timestamptz not null default now(),
  settled_at         timestamptz,
  requalified_at     timestamptz,
  voided_at          timestamptz,
  voided_by          text,
  void_reason        text,
  void_dispute_id    uuid,
  review_required_at timestamptz,
  reviewed_at        timestamptz,
  reviewed_by        text,
  review_note        text
);
create index if not exists customer_credit_defaults_customer_idx on public.customer_credit_defaults (customer_id);

-- Append-only history of everything that happens to a customer's credit.
create table if not exists public.customer_credit_events (
  id          bigserial primary key,
  customer_id text not null references public.customers(id),
  at          timestamptz not null default now(),
  kind        text not null,
  message     text not null default '',
  actor       text not null default 'system',
  metadata    jsonb not null default '{}'::jsonb
);
create index if not exists customer_credit_events_customer_idx on public.customer_credit_events (customer_id, id desc);

create table if not exists public.credit_due_extensions (
  id            bigserial primary key,
  order_id      text not null references public.customer_credit_orders(order_id),
  previous_due  date not null,
  new_due       date not null check (new_due > previous_due),
  authorized_by text not null,
  reason        text not null check (char_length(btrim(reason)) >= 10),
  created_at    timestamptz not null default now()
);
create index if not exists credit_due_extensions_order_idx on public.credit_due_extensions (order_id, id desc);

create table if not exists public.credit_disputes (
  id              uuid primary key default gen_random_uuid(),
  customer_id     text not null references public.customers(id),
  order_id        text not null references public.customer_credit_orders(order_id),
  reason          text not null check (char_length(btrim(reason)) between 10 and 1000),
  disputed_amount numeric(14,2) check (disputed_amount is null or disputed_amount > 0),
  status          text not null default 'open' check (status in ('open', 'investigating', 'resolved_billing_error', 'resolved_rejected', 'withdrawn')),
  opened_by       text not null default 'customer' check (opened_by in ('customer', 'staff')),
  opened_at       timestamptz not null default now(),
  assigned_to     text,
  staff_notes     text not null default '',
  resolution      text not null default '',
  resolved_by     text,
  resolved_at     timestamptz,
  updated_at      timestamptz not null default now()
);
create unique index if not exists credit_disputes_one_unresolved on public.credit_disputes (order_id) where status in ('open', 'investigating');
create index if not exists credit_disputes_customer_idx on public.credit_disputes (customer_id, opened_at desc);

create table if not exists public.credit_reminders (
  id          bigserial primary key,
  order_id    text not null references public.customer_credit_orders(order_id),
  customer_id text not null references public.customers(id),
  kind        text not null check (kind in ('due_7', 'due_0', 'overdue_1', 'overdue_7', 'overdue_30')),
  audience    text not null check (audience in ('customer', 'staff', 'super_admin')),
  channel     text not null default 'in_app' check (channel in ('in_app')),
  status      text not null default 'pending' check (status in ('pending', 'sent', 'failed')),
  attempts    integer not null default 0,
  last_error  text not null default '',
  title       text not null default '',
  body        text not null default '',
  created_at  timestamptz not null default now(),
  sent_at     timestamptz,
  unique (order_id, kind, audience, channel)
);

create table if not exists public.customer_notifications (
  id          uuid primary key default gen_random_uuid(),
  customer_id text not null references public.customers(id),
  kind        text not null,
  title       text not null,
  body        text not null,
  order_id    text,
  created_at  timestamptz not null default now(),
  read_at     timestamptz
);
create index if not exists customer_notifications_customer_idx on public.customer_notifications (customer_id, created_at desc);

do $$
declare t text;
begin
  foreach t in array array['customer_credit_defaults', 'customer_credit_events', 'credit_due_extensions', 'credit_disputes', 'credit_reminders', 'customer_notifications'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);
  end loop;
end $$;
revoke all on sequence public.customer_credit_events_id_seq, public.credit_due_extensions_id_seq, public.credit_reminders_id_seq from public, anon, authenticated, service_role;

-- History is never edited or removed (a default may only gain its settlement, requalification, void and review facts, each once).
create or replace function public.guard_credit_history()
returns trigger language plpgsql set search_path = public as $fn$
begin
  if tg_op = 'DELETE' then raise exception '% rows are never deleted', tg_table_name using errcode = '42501'; end if;
  if tg_table_name = 'customer_credit_defaults' then
    if (new.customer_id, new.order_id, new.due_date, new.defaulted_on, new.amount_at_default, new.limit_at_default, new.detected_at)
       is distinct from (old.customer_id, old.order_id, old.due_date, old.defaulted_on, old.amount_at_default, old.limit_at_default, old.detected_at) then
      raise exception 'a recorded default cannot be changed' using errcode = '42501';
    end if;
    if (old.settled_at is not null and new.settled_at is distinct from old.settled_at) or (old.requalified_at is not null and new.requalified_at is distinct from old.requalified_at)
       or (old.voided_at is not null and (new.voided_at, new.voided_by, new.void_reason, new.void_dispute_id) is distinct from (old.voided_at, old.voided_by, old.void_reason, old.void_dispute_id))
       or (old.reviewed_at is not null and (new.reviewed_at, new.reviewed_by, new.review_note) is distinct from (old.reviewed_at, old.reviewed_by, old.review_note)) then
      raise exception 'a default fact that was recorded cannot be rewritten' using errcode = '42501';
    end if;
    return new;
  end if;
  raise exception '% rows are append-only', tg_table_name using errcode = '42501';
end;
$fn$;
drop trigger if exists trg_credit_defaults_guard on public.customer_credit_defaults;
create trigger trg_credit_defaults_guard before update or delete on public.customer_credit_defaults for each row execute function public.guard_credit_history();
drop trigger if exists trg_credit_events_guard on public.customer_credit_events;
create trigger trg_credit_events_guard before update or delete on public.customer_credit_events for each row execute function public.guard_credit_history();
drop trigger if exists trg_credit_extensions_guard on public.credit_due_extensions;
create trigger trg_credit_extensions_guard before update or delete on public.credit_due_extensions for each row execute function public.guard_credit_history();
drop trigger if exists trg_credit_disputes_nodelete on public.credit_disputes;
create trigger trg_credit_disputes_nodelete before delete on public.credit_disputes for each row execute function public.guard_no_delete_finance();
drop trigger if exists trg_credit_reminders_nodelete on public.credit_reminders;
create trigger trg_credit_reminders_nodelete before delete on public.credit_reminders for each row execute function public.guard_no_delete_finance();

-- -----------------------------------------------------------------------------
-- 3. Internal helpers (nobody can call them directly)
-- -----------------------------------------------------------------------------
create or replace function public._credit_related_customers(p_customer_id text)
returns text[]
language sql stable security definer set search_path = public
as $fn$
  select array_agg(distinct x) from (
    select p_customer_id as x
    union
    select c2.id from public.customers c1
      join public.customers c2 on public.customer_phone_canonical(c2.phone) = public.customer_phone_canonical(c1.phone)
     where c1.id = p_customer_id and coalesce(public.customer_phone_canonical(c1.phone), '') <> ''
  ) s;
$fn$;

-- The due date in force: the latest recorded extension, else the original due date.
create or replace function public._credit_effective_due(p_order_id text)
returns date
language sql stable security definer set search_path = public
as $fn$
  select coalesce((select e.new_due from public.credit_due_extensions e where e.order_id = p_order_id order by e.id desc limit 1),
                  (select cc.due_date from public.customer_credit_orders cc where cc.order_id = p_order_id));
$fn$;

create or replace function public._credit_audit(p_severity text, p_message text, p_target text, p_meta jsonb)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
begin
  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), p_severity::public.log_severity, 'FINANCIAL', p_message, public.current_profile_id(),
          coalesce(public.current_profile_name(), 'system'), p_target, coalesce(p_meta, '{}'::jsonb) || jsonb_build_object('source', 'db'));
end;
$fn$;

create or replace function public._credit_event(p_customer_id text, p_kind text, p_message text, p_meta jsonb)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
begin
  insert into public.customer_credit_events (customer_id, kind, message, actor, metadata)
  values (p_customer_id, p_kind, p_message, coalesce(public.current_profile_name(), 'system'), coalesce(p_meta, '{}'::jsonb));
end;
$fn$;

-- Staff notifications: only the people who may act on credit (never a broadcast to every staff member).
create or replace function public._credit_notify_staff(p_level text, p_title text, p_message text)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
begin
  insert into public.notifications (id, title, message, type, user_id)
  select 'ntf-' || replace(gen_random_uuid()::text, '-', ''), p_title, p_message, 'system', p.id
    from public.profiles p
   where p.status = 'active'
     and (p.role = 'Super Admin'
          or (p_level = 'staff' and exists (select 1 from public.user_permissions up where up.user_id = p.id and up.permission_code = 'manage_customer_accounts')));
end;
$fn$;

-- Tries one reminder row's delivery; a failure is recorded on the row (status, attempts, a short error) and retried by the next run.
create or replace function public._credit_deliver(p_id bigint)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
declare r public.credit_reminders%rowtype;
begin
  select * into r from public.credit_reminders where id = p_id for update;
  if not found or r.status = 'sent' then return; end if;
  begin
    if r.audience = 'customer' then
      insert into public.customer_notifications (customer_id, kind, title, body, order_id) values (r.customer_id, r.kind, r.title, r.body, r.order_id);
    else
      perform public._credit_notify_staff(case when r.audience = 'staff' then 'staff' else 'super_admin' end, r.title, r.body);
    end if;
    update public.credit_reminders set status = 'sent', attempts = attempts + 1, sent_at = now(), last_error = '' where id = p_id;
  exception when others then
    update public.credit_reminders set status = 'failed', attempts = attempts + 1, last_error = left(sqlerrm, 200) where id = p_id;
  end;
end;
$fn$;

-- Idempotent: one row per (invoice, kind, audience, channel) however often it is called.
create or replace function public._credit_send(p_order_id text, p_customer_id text, p_kind text, p_audience text, p_title text, p_body text)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
declare v_id bigint;
begin
  insert into public.credit_reminders (order_id, customer_id, kind, audience, title, body) values (p_order_id, p_customer_id, p_kind, p_audience, p_title, p_body)
  on conflict (order_id, kind, audience, channel) do nothing returning id into v_id;
  if v_id is not null then perform public._credit_deliver(v_id); end if;
end;
$fn$;

-- The company-wide cap. Revenue = orders.total of NON-CANCELLED orders by order_date (as daily_sales / financial_summary / Sales analytics booked revenue).
create or replace function public._credit_company_cap()
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare
  pol public.credit_policy%rowtype; v_today date := public.efz_today(); v_first date; v_start date; v_end date;
  v_rev numeric; v_earliest date; v_out numeric; v_avg numeric; v_cap numeric; v_ok boolean; v_why text := '';
begin
  select * into pol from public.credit_policy where id;
  v_out := coalesce((select sum(o.outstanding_balance) from public.orders o where o.payment_terms = 'credit' and o.status <> 'cancelled'), 0);
  if pol.company_cap_percent is null or pol.cap_basis_months is null then
    return jsonb_build_object('configured', false, 'sufficient', false, 'reason', 'The company-wide cap is not configured.', 'outstanding', v_out, 'available', 0);
  end if;
  v_first := date_trunc('month', v_today)::date;
  v_start := (v_first - make_interval(months => pol.cap_basis_months))::date;
  v_end := v_first - 1;
  select coalesce(sum(o.total), 0) into v_rev from public.orders o where o.status <> 'cancelled' and o.order_date between v_start and v_end;
  select min(o.order_date) into v_earliest from public.orders o where o.status <> 'cancelled';
  v_ok := v_earliest is not null and v_earliest <= v_start and v_rev > 0;
  if v_earliest is null then v_why := 'There is no sales history.';
  elsif v_earliest > v_start then v_why := format('Sales history starts on %s, which is after the first of the %s complete months used for the cap (%s).', v_earliest, pol.cap_basis_months, v_start);
  elsif v_rev <= 0 then v_why := 'There was no sales revenue in the months used for the cap.';
  end if;
  v_avg := v_rev / pol.cap_basis_months;
  v_cap := case when v_ok then round(v_avg * pol.company_cap_percent / 100, 2) else null end;
  return jsonb_build_object('configured', true, 'sufficient', v_ok, 'reason', v_why, 'windowStart', v_start, 'windowEnd', v_end, 'months', pol.cap_basis_months,
    'revenue', v_rev, 'averageMonthly', round(v_avg, 2), 'percent', pol.company_cap_percent, 'cap', v_cap, 'outstanding', v_out,
    'available', case when v_ok then greatest(v_cap - v_out, 0) else 0 end);
end;
$fn$;

-- Records defaults and settlements for one customer. Idempotent. Called at every point that decides about credit, so a missed due date is acted on
-- the moment anyone looks, whether or not the daily run has happened.
create or replace function public._credit_sync_defaults(p_customer_id text)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
declare
  r record; v_today date := public.efz_today(); v_acc public.customer_credit_accounts%rowtype; v_amt numeric; v_id uuid; v_name text;
begin
  for r in
    select o.id, o.customer_id, o.total, o.outstanding_balance, public._credit_effective_due(o.id) as eff,
           (select max(p.payment_date) from public.payments p where p.order_id = o.id and p.amount > 0) as last_pay
      from public.orders o join public.customer_credit_orders cc on cc.order_id = o.id
     where o.customer_id = p_customer_id and o.status <> 'cancelled'
       and not exists (select 1 from public.customer_credit_defaults d where d.order_id = o.id)
  loop
    if (r.outstanding_balance > 0 and r.eff < v_today) or (r.outstanding_balance <= 0 and r.last_pay is not null and r.last_pay > r.eff) then
      v_amt := greatest(r.total - coalesce((select sum(p.amount) from public.payments p where p.order_id = r.id and p.payment_date <= r.eff), 0), 0);
      select * into v_acc from public.customer_credit_accounts where customer_id = r.customer_id;
      v_id := null;
      insert into public.customer_credit_defaults (customer_id, order_id, due_date, defaulted_on, amount_at_default, limit_at_default)
      values (r.customer_id, r.id, r.eff, r.eff + 1, v_amt, v_acc.credit_limit) on conflict (order_id) do nothing returning id into v_id;
      if v_id is not null then
        select name into v_name from public.customers where id = r.customer_id;
        perform public._credit_event(r.customer_id, 'default_recorded', format('Invoice INV-%s missed its due date (%s); $%s was unpaid on that day', r.id, r.eff, v_amt),
                                     jsonb_build_object('orderId', r.id, 'dueDate', r.eff, 'amount', v_amt));
        if v_acc.customer_id is not null and v_acc.status <> 'revoked' then
          update public.customer_credit_accounts set status = 'revoked', reason = format('Credit revoked: invoice INV-%s missed its due date', r.id), set_by = null, set_at = now() where customer_id = r.customer_id;
          perform public._credit_event(r.customer_id, 'credit_revoked', 'Credit eligibility revoked after a missed due date; the customer must requalify from the beginning',
                                       jsonb_build_object('orderId', r.id, 'formerLimit', v_acc.credit_limit, 'formerStatus', v_acc.status));
        end if;
        perform public._credit_audit('WARNING', format('Credit default recorded for %s: invoice INV-%s missed its due date (%s)', coalesce(v_name, r.customer_id), r.id, r.eff), r.customer_id,
                                     jsonb_build_object('event', 'credit_default_recorded', 'orderId', r.id, 'dueDate', r.eff, 'amountAtDefault', v_amt, 'lateSettled', r.outstanding_balance <= 0));
        perform public._credit_send(r.id, r.customer_id, 'overdue_1', 'customer', 'Credit invoice overdue',
          format('Invoice INV-%s was due on %s and was not paid in time. Credit purchasing is now switched off for your account. Paying the balance settles the debt but does not restore credit: you will need to qualify again.', r.id, r.eff));
        perform public._credit_send(r.id, r.customer_id, 'overdue_1', 'staff', 'Customer credit revoked',
          format('%s missed the due date (%s) of invoice INV-%s. Credit was revoked automatically; the customer must requalify.', coalesce(v_name, r.customer_id), r.eff, r.id));
      end if;
    end if;
  end loop;
  -- settlement: the debt is cleared (fully paid, or the order cancelled by staff). The default stays on record.
  for r in
    select d.id, d.customer_id, d.order_id, o.status, (select max(p.created_at) from public.payments p where p.order_id = o.id) as ts
      from public.customer_credit_defaults d join public.orders o on o.id = d.order_id
     where d.customer_id = p_customer_id and d.settled_at is null and d.voided_at is null and (o.status = 'cancelled' or o.outstanding_balance <= 0)
  loop
    update public.customer_credit_defaults set settled_at = case when r.status = 'cancelled' then now() else coalesce(r.ts, now()) end where id = r.id and settled_at is null;
    perform public._credit_event(r.customer_id, 'default_settled', format('The overdue debt on invoice INV-%s is settled. Credit stays revoked until the customer requalifies and a Super Admin approves credit again', r.order_id),
                                 jsonb_build_object('orderId', r.order_id));
    perform public._credit_audit('INFO', format('Credit default on invoice INV-%s settled (eligibility is NOT restored)', r.order_id), r.customer_id, jsonb_build_object('event', 'credit_default_settled', 'orderId', r.order_id));
  end loop;
end;
$fn$;

-- The daily run: syncs defaults, then sends the pre-due, due-date and overdue reminders and the escalations. Idempotent.
create or replace function public._credit_run()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $fn$
declare
  r record; v_today date := public.efz_today(); d integer; v_before integer; v_after integer; v_name text; v_inv text; v_maxid bigint;
begin
  perform pg_advisory_xact_lock(hashtext('credit:run'));
  select coalesce(max(id), 0) into v_maxid from public.credit_reminders;
  select count(*) into v_before from public.credit_reminders where status = 'sent';
  for r in select distinct customer_id from public.customer_credit_orders loop perform public._credit_sync_defaults(r.customer_id); end loop;
  for r in
    select o.id, o.customer_id, o.outstanding_balance as bal, public._credit_effective_due(o.id) as eff
      from public.orders o join public.customer_credit_orders cc on cc.order_id = o.id where o.status <> 'cancelled' and o.outstanding_balance > 0
  loop
    d := v_today - r.eff; v_inv := 'INV-' || r.id; select name into v_name from public.customers where id = r.customer_id;
    if d < 0 and d >= -7 then
      perform public._credit_send(r.id, r.customer_id, 'due_7', 'customer', 'Payment due soon', format('Invoice %s ($%s outstanding) is due on %s.', v_inv, r.bal, r.eff));
    elsif d = 0 then
      perform public._credit_send(r.id, r.customer_id, 'due_0', 'customer', 'Payment due today', format('Invoice %s ($%s outstanding) is due today (%s). Paying after today makes it overdue and switches off your credit.', v_inv, r.bal, r.eff));
    elsif d >= 1 then
      perform public._credit_send(r.id, r.customer_id, 'overdue_1', 'customer', 'Credit invoice overdue', format('Invoice %s was due on %s and is overdue ($%s outstanding). Credit purchasing is switched off for your account.', v_inv, r.eff, r.bal));
      perform public._credit_send(r.id, r.customer_id, 'overdue_1', 'staff', 'Customer credit revoked', format('%s: invoice %s is overdue since %s. Credit was revoked automatically.', coalesce(v_name, r.customer_id), v_inv, r.eff));
      if d >= 7 then
        perform public._credit_send(r.id, r.customer_id, 'overdue_7', 'customer', 'Overdue reminder', format('Invoice %s is now %s days overdue ($%s outstanding). Please pay as soon as possible. Credit stays off until you requalify.', v_inv, d, r.bal));
        perform public._credit_send(r.id, r.customer_id, 'overdue_7', 'staff', 'Overdue 7 days: follow up', format('%s: invoice %s is %s days overdue ($%s). Staff follow-up is required.', coalesce(v_name, r.customer_id), v_inv, d, r.bal));
      end if;
      if d >= 30 then
        perform public._credit_send(r.id, r.customer_id, 'overdue_30', 'super_admin', 'Overdue 30 days: credit-risk review', format('%s: invoice %s is %s days overdue ($%s). A documented credit-risk review is required.', coalesce(v_name, r.customer_id), v_inv, d, r.bal));
        update public.customer_credit_defaults set review_required_at = now() where order_id = r.id and voided_at is null and review_required_at is null;
      end if;
    end if;
  end loop;
  for r in select id from public.credit_reminders where status = 'failed' and attempts < 5 and id <= v_maxid order by id loop perform public._credit_deliver(r.id); end loop;
  select count(*) into v_after from public.credit_reminders where status = 'sent';
  return jsonb_build_object('asOf', v_today, 'remindersSent', v_after - v_before, 'failed', (select count(*) from public.credit_reminders where status = 'failed'));
end;
$fn$;

do $$
declare f text;
begin
  foreach f in array array['_credit_related_customers(text)', '_credit_effective_due(text)', '_credit_audit(text,text,text,jsonb)', '_credit_event(text,text,text,jsonb)', '_credit_notify_staff(text,text,text)',
                           '_credit_deliver(bigint)', '_credit_send(text,text,text,text,text,text)', '_credit_company_cap()', '_credit_sync_defaults(text)', '_credit_run()', 'guard_credit_history()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- 4. Eligibility and summary (what the server decides, every time)
-- -----------------------------------------------------------------------------
create or replace function public._customer_credit_eligibility(p_customer_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  pol         public.credit_policy%rowtype;
  v_today     date := public.efz_today();
  v_ids       text[] := public._credit_related_customers(p_customer_id);
  v_first     date;
  v_ref       date;
  v_last_settle date; v_hist integer; v_open_def integer; v_last_def date; v_last_settled_on date;
  v_start     date;
  v_count     integer; v_value numeric; v_unpaid integer; v_od_n integer; v_od_amt numeric; v_out numeric; v_days integer; v_disp integer;
  v_reasons   text[] := '{}';
  v_standing  text[] := '{}';
begin
  select * into pol from public.credit_policy where id;
  select ((min(e.created_at)) at time zone 'Africa/Mogadishu')::date into v_first
    from public.customer_account_events e join public.customer_accounts a on a.id = e.account_id where a.customer_id = p_customer_id and e.event = 'approved';
  select ((max(d.settled_at)) at time zone 'Africa/Mogadishu')::date, count(*), count(*) filter (where d.settled_at is null), max(d.defaulted_on)
    into v_last_settle, v_hist, v_open_def, v_last_def
    from public.customer_credit_defaults d where d.customer_id = any (v_ids) and d.voided_at is null;
  v_ref := case when v_first is null then null else greatest(v_first, coalesce(v_last_settle, v_first)) end;
  -- purchases count from the start of the window; only a settled default moves that start (requalification counts purchases made AFTER the last settlement).
  -- Orders placed before the app account existed still count: they are the customer's history with EFZ.
  v_start := greatest(case when pol.purchase_window_days is null then date '1970-01-01' else v_today - pol.purchase_window_days end, coalesce(v_last_settle, date '1970-01-01'));
  select count(*), coalesce(sum(o.total), 0) into v_count, v_value
    from public.orders o
   where o.customer_id = p_customer_id and o.status = 'delivered' and o.order_type = 'regular' and o.total > 0 and o.amount_paid >= o.total
     and o.order_date >= v_start and o.order_date <= v_today
     and not exists (select 1 from public.customer_checkouts c where c.order_id = o.id and c.status in ('reversed', 'needs_review'));
  select count(*) into v_unpaid from public.orders o where o.customer_id = p_customer_id and o.status = 'delivered' and o.outstanding_balance > 0;
  select count(*), coalesce(sum(o.outstanding_balance), 0) into v_od_n, v_od_amt
    from public.orders o join public.customer_credit_orders cc on cc.order_id = o.id
   where o.customer_id = p_customer_id and o.status <> 'cancelled' and o.outstanding_balance > 0 and public._credit_effective_due(o.id) < v_today;
  select coalesce(sum(o.outstanding_balance), 0) into v_out from public.orders o where o.customer_id = p_customer_id and o.status <> 'cancelled';
  select count(*) into v_disp from public.credit_disputes x where x.customer_id = p_customer_id and x.status in ('open', 'investigating');
  v_days := case when v_ref is null then 0 else greatest(v_today - v_ref, 0) end;

  if not pol.enabled then
    v_reasons := array_append(v_reasons, 'Credit purchasing is not active yet.');
  else
    if pol.min_completed_purchases is not null and v_count < pol.min_completed_purchases then
      v_reasons := array_append(v_reasons, format('%s more completed purchase(s) needed (%s of %s%s).', pol.min_completed_purchases - v_count, v_count, pol.min_completed_purchases,
                                                  case when pol.purchase_window_days is null then '' else format(' in the last %s days', pol.purchase_window_days) end));
    end if;
    if pol.min_total_value is not null and v_value < pol.min_total_value then
      v_reasons := array_append(v_reasons, format('Completed purchases total $%s; $%s is required.', v_value, pol.min_total_value));
    end if;
    if pol.min_approved_days is not null and v_days < pol.min_approved_days then
      v_reasons := array_append(v_reasons, format('Approved for %s of the %s days required.', v_days, pol.min_approved_days));
    end if;
    if pol.min_completed_purchases is null and pol.min_total_value is null and pol.min_approved_days is null then
      v_reasons := array_append(v_reasons, 'EFZ has not defined the purchase requirement yet.');
    end if;
    if v_open_def > 0 then
      v_standing := array_append(v_standing, 'Credit was revoked after a missed due date and the overdue debt is not settled.');
    end if;
    if v_od_n > 0 then
      v_standing := array_append(v_standing, format('A credit invoice is overdue ($%s).', v_od_amt));
    end if;
    if pol.require_no_unpaid_delivered and v_unpaid > 0 then
      v_standing := array_append(v_standing, 'A delivered order still has an unpaid balance.');
    end if;
    if v_disp > 0 then
      v_standing := array_append(v_standing, 'A billing dispute is open on this account.');
    end if;
    if pol.max_outstanding is not null and v_out >= pol.max_outstanding then
      v_standing := array_append(v_standing, format('The outstanding balance ($%s) has reached the maximum ($%s).', v_out, pol.max_outstanding));
    end if;
  end if;
  return jsonb_build_object(
    'eligible', pol.enabled and cardinality(v_reasons) = 0 and cardinality(v_standing) = 0,
    'completedPurchases', v_count, 'completedValue', v_value, 'unpaidDeliveredOrders', v_unpaid, 'daysApproved', v_days, 'overdueAmount', v_od_amt, 'openDisputes', v_disp,
    'requirements', jsonb_build_object('minCompletedPurchases', pol.min_completed_purchases, 'minTotalValue', pol.min_total_value, 'minApprovedDays', pol.min_approved_days,
                                        'purchaseWindowDays', pol.purchase_window_days, 'maxOutstanding', pol.max_outstanding, 'requireNoUnpaidDelivered', pol.require_no_unpaid_delivered, 'requireNoOverdue', true),
    'defaultHistory', jsonb_build_object('count', v_hist, 'open', v_open_def, 'lastDefaultedOn', v_last_def, 'lastSettledOn', v_last_settle, 'requalifyingFrom', case when v_hist > 0 then v_ref end),
    'reasons', to_jsonb(v_reasons), 'standingReasons', to_jsonb(v_standing));
end;
$fn$;

create or replace function public._customer_credit_summary(p_customer_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  pol         public.credit_policy%rowtype;
  acc         public.customer_credit_accounts%rowtype;
  v_elig      jsonb := public._customer_credit_eligibility(p_customer_id);
  v_cap       jsonb := public._credit_company_cap();
  v_credit_out numeric; v_all_out numeric; v_ceiling numeric; v_avail numeric := 0; v_next_due date; v_can boolean;
  v_standing  boolean := jsonb_array_length(v_elig -> 'standingReasons') > 0;
  v_unmet     boolean := jsonb_array_length(v_elig -> 'reasons') > 0;
  v_hist      integer := (v_elig -> 'defaultHistory' ->> 'count')::integer;
  v_open      integer := (v_elig -> 'defaultHistory' ->> 'open')::integer;
  v_overdue   numeric := (v_elig ->> 'overdueAmount')::numeric;
  v_cap_ok    boolean;
  v_msg       text;
begin
  select * into pol from public.credit_policy where id;
  select * into acc from public.customer_credit_accounts where customer_id = p_customer_id;
  select coalesce(sum(o.outstanding_balance), 0) into v_credit_out from public.orders o where o.customer_id = p_customer_id and o.status <> 'cancelled' and o.payment_terms = 'credit';
  select coalesce(sum(o.outstanding_balance), 0) into v_all_out from public.orders o where o.customer_id = p_customer_id and o.status <> 'cancelled';
  select min(public._credit_effective_due(cc.order_id)) into v_next_due from public.customer_credit_orders cc join public.orders o on o.id = cc.order_id
   where cc.customer_id = p_customer_id and o.status <> 'cancelled' and o.outstanding_balance > 0;
  v_cap_ok := coalesce((v_cap ->> 'sufficient')::boolean, false);
  if acc.customer_id is not null then
    v_avail := greatest(acc.credit_limit - v_credit_out, 0);
    if pol.max_outstanding is not null then v_avail := least(v_avail, greatest(pol.max_outstanding - v_all_out, 0)); end if;
    if pol.company_cap_percent is not null then v_avail := least(v_avail, case when v_cap_ok then (v_cap ->> 'available')::numeric else 0 end); end if;
  end if;
  -- An override is a staff exception for unmet requirements only; it never covers standing or a default, and it exists only if the policy allows it.
  v_can := coalesce(pol.enabled and acc.customer_id is not null and acc.status = 'approved' and not v_standing and v_avail > 0 and (pol.company_cap_percent is null or v_cap_ok)
           and ((v_hist = 0 and (not v_unmet or (pol.allow_requirement_override and acc.override_used)))
                or (v_hist > 0 and not v_unmet and not exists (select 1 from public.customer_credit_defaults d where d.customer_id = any (public._credit_related_customers(p_customer_id)) and d.voided_at is null and d.requalified_at is null))), false);
  v_msg := case
      when not pol.enabled then 'Credit purchasing is not currently available.'
      when v_open > 0 or v_overdue > 0 then 'Your credit invoice is overdue, so credit purchasing is switched off for your account. Paying the balance settles the debt but does not restore credit: you will have to qualify again.'
      when v_hist > 0 and (acc.customer_id is null or acc.status = 'revoked' or v_unmet) then 'Your overdue debt is settled, but credit stays switched off. To get credit again you must qualify again (see your progress below) and EFZ must approve it.'
      when v_standing then 'Credit purchasing is paused until the item above is resolved.'
      when acc.customer_id is null and (v_elig ->> 'eligible')::boolean then 'You meet the requirements. EFZ will confirm your credit limit and terms.'
      when acc.customer_id is null then 'Credit purchasing is not available on your account yet.'
      when acc.status = 'suspended' then 'Credit purchasing is paused on your account. Please contact EFZ.'
      when acc.status = 'revoked' then 'Credit purchasing is switched off for your account. Please contact EFZ.'
      when v_unmet and not (pol.allow_requirement_override and acc.override_used) then 'Credit purchasing is not available on your account at the moment.'
      when pol.company_cap_percent is not null and not v_cap_ok then 'Credit purchasing is temporarily unavailable. Please try again later.'
      when v_avail <= 0 then 'You have used all of your available credit.'
      else 'You can buy on credit within your limit.' end;
  return jsonb_build_object(
    'policyEnabled', pol.enabled, 'eligibility', v_elig, 'canBuyOnCredit', coalesce(v_can, false),
    'account', case when acc.customer_id is null then null else jsonb_build_object('status', acc.status, 'creditLimit', acc.credit_limit, 'termsDays', acc.terms_days,
                                                                                     'outstanding', v_credit_out, 'available', v_avail, 'nextDueDate', v_next_due,
                                                                                     'overdue', v_overdue, 'override', acc.override_used) end,
    'default', jsonb_build_object('inDefault', v_open > 0 or v_overdue > 0, 'everDefaulted', v_hist > 0, 'revoked', acc.status = 'revoked',
                                  'lastDefaultedOn', v_elig -> 'defaultHistory' -> 'lastDefaultedOn', 'lastSettledOn', v_elig -> 'defaultHistory' -> 'lastSettledOn',
                                  'requalifyingFrom', v_elig -> 'defaultHistory' -> 'requalifyingFrom',
                                  'initialLimitAfterRequalifying', pol.initial_credit_limit),
    'message', v_msg);
end;
$fn$;

-- The three customer entry points now settle the customer's defaults first (so they are volatile, called with POST like every other rpc).
create or replace function public.customer_credit_status()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $fn$
declare v_customer text := public.require_approved_customer();
begin
  perform public._credit_sync_defaults(v_customer);
  return public._customer_credit_summary(v_customer);
end;
$fn$;

create or replace function public.customer_payment_methods()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $fn$
declare
  v_customer text := public.require_approved_customer();
  v_credit   jsonb;
begin
  perform public._credit_sync_defaults(v_customer);
  v_credit := public._customer_credit_summary(v_customer);
  return jsonb_build_object(
    'methods', coalesce((select jsonb_agg(jsonb_build_object('code', m.code, 'label', m.label, 'kind', m.kind) order by m.sort_order, m.code)
                           from public.payment_methods m where m.enabled), '[]'::jsonb),
    'credit', jsonb_build_object('available', (v_credit ->> 'canBuyOnCredit')::boolean, 'message', v_credit ->> 'message', 'account', v_credit -> 'account'));
end;
$fn$;

-- -----------------------------------------------------------------------------
-- 5. Placing a credit order: the final server-side decision, under a company-wide and a per-customer lock
-- -----------------------------------------------------------------------------
create or replace function public.customer_place_credit_order(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_customer text := public.require_approved_customer();
  v_acc      uuid;
  v_key      uuid;
  v_location text := btrim(coalesce(p_payload ->> 'deliveryLocation', ''));
  v_notes    text := btrim(coalesce(p_payload ->> 'notes', ''));
  v_existing public.customer_checkouts%rowtype;
  v_summary  jsonb;
  v_priced   jsonb;
  v_total    numeric;
  v_avail    numeric;
  cr         public.customer_credit_accounts%rowtype;
  v_order    text;
  v_id       uuid;
  v_name     text;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then raise exception 'Invalid checkout' using errcode = '22023'; end if;
  begin v_key := (p_payload ->> 'submissionKey')::uuid; exception when others then v_key := null; end;
  if v_key is null then raise exception 'A submission key is required' using errcode = '22023'; end if;
  select id into v_acc from public.customer_accounts a where a.auth_user_id = auth.uid();
  perform pg_advisory_xact_lock(hashtext('credit:company'));            -- the company-wide cap is shared by everyone, so credit orders are decided one at a time
  perform pg_advisory_xact_lock(hashtext('checkout:' || v_customer));

  select * into v_existing from public.customer_checkouts c where c.customer_id = v_customer and c.submission_key = v_key;
  if found then
    return jsonb_build_object('checkoutId', v_existing.id, 'status', v_existing.status, 'orderId', v_existing.order_id, 'amount', v_existing.amount, 'repeat', true);
  end if;

  if char_length(v_location) < 3 or char_length(v_location) > 300 then raise exception 'Enter a delivery location (3 to 300 characters)' using errcode = '22023'; end if;
  if char_length(v_notes) > 1000 then raise exception 'Notes are too long' using errcode = '22023'; end if;

  perform public._credit_sync_defaults(v_customer);                      -- a missed due date is acted on right now, not when a job next runs
  v_summary := public._customer_credit_summary(v_customer);
  if not (v_summary ->> 'canBuyOnCredit')::boolean then
    raise exception 'Credit purchasing is not available on this account' using errcode = '42501';
  end if;
  select * into cr from public.customer_credit_accounts where customer_id = v_customer;
  v_priced := public._customer_price_cart(p_payload -> 'lines');
  v_total := (v_priced ->> 'total')::numeric;
  v_avail := (v_summary -> 'account' ->> 'available')::numeric;
  if v_total > v_avail then
    raise exception 'This order ($%) is above your available credit ($%)', v_total, v_avail using errcode = '22023';
  end if;
  if (select count(*) from public.customer_checkouts c where c.customer_id = v_customer and c.created_at > now() - interval '24 hours') >= 30 then
    raise exception 'Too many checkouts today. Please try again later.' using errcode = 'WR429';
  end if;

  select name into v_name from public.customers where id = v_customer;
  v_order := public._customer_create_order(v_customer, v_priced, 'credit', v_location, v_notes, 'Customer app (' || coalesce(v_name, v_customer) || ')');
  insert into public.customer_credit_orders (order_id, customer_id, terms_days, due_date, credit_limit_at_time)
  values (v_order, v_customer, cr.terms_days, public.efz_today() + cr.terms_days, cr.credit_limit);
  insert into public.customer_checkouts (customer_id, account_id, submission_key, method_code, status, lines, amount, delivery_location, notes, order_id, verified_at)
  values (v_customer, v_acc, v_key, 'credit', 'credit_placed', v_priced -> 'lines', v_total, v_location, v_notes, v_order, now())
  returning id into v_id;
  perform public._credit_event(v_customer, 'credit_order_placed', format('Credit order %s ($%s) placed; due %s', v_order, v_total, public.efz_today() + cr.terms_days),
                               jsonb_build_object('orderId', v_order, 'total', v_total, 'dueDate', public.efz_today() + cr.terms_days, 'limit', cr.credit_limit));
  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'FINANCIAL',
          format('Credit order %s placed by the customer ($%s, limit $%s, %s days)', v_order, v_total, cr.credit_limit, cr.terms_days), null,
          'Customer app (' || coalesce(v_name, v_customer) || ')', v_order,
          jsonb_build_object('source', 'db', 'event', 'credit_order_placed', 'customerId', v_customer, 'total', v_total, 'limit', cr.credit_limit,
                             'termsDays', cr.terms_days, 'availableBefore', v_avail));
  return jsonb_build_object('checkoutId', v_id, 'status', 'credit_placed', 'orderId', v_order, 'amount', v_total, 'repeat', false);
end;
$fn$;

-- -----------------------------------------------------------------------------
-- 6. The customer's finance dashboard (migration 23's, with issue date, original and current due dates, extensions, default flags and disputes)
-- -----------------------------------------------------------------------------
create or replace function public.my_finance()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_customer text := public.require_approved_customer();
  v_today    date := public.efz_today();
begin
  perform public._credit_sync_defaults(v_customer);
  return jsonb_build_object(
    'asOf', v_today,
    'summary', (select jsonb_build_object(
        'confirmedOrders', count(*), 'confirmedPurchases', coalesce(sum(o.total), 0), 'totalPaid', coalesce(sum(o.amount_paid), 0),
        'outstanding', coalesce(sum(o.outstanding_balance), 0),
        'unpaidInvoices', count(*) filter (where o.payment_terms = 'credit' and o.total > 0 and o.amount_paid = 0 and o.outstanding_balance > 0),
        'partialInvoices', count(*) filter (where o.payment_terms = 'credit' and o.total > 0 and o.amount_paid > 0 and o.outstanding_balance > 0),
        'paidInvoices', count(*) filter (where o.payment_terms = 'credit' and o.total > 0 and o.outstanding_balance = 0),
        'overdueInvoices', count(*) filter (where o.payment_terms = 'credit' and o.outstanding_balance > 0 and cc.due_date is not null and public._credit_effective_due(o.id) < v_today))
       from public.orders o left join public.customer_credit_orders cc on cc.order_id = o.id
      where o.customer_id = v_customer and o.status <> 'cancelled'),
    'pendingPayments', (select jsonb_build_object('count', count(*), 'amount', coalesce(sum(c.amount), 0))
                          from public.customer_checkouts c where c.customer_id = v_customer and c.status in ('created', 'pending')),
    'underReview', (select count(*) from public.customer_checkouts c where c.customer_id = v_customer and c.status in ('needs_review', 'reversed')),
    'invoices', coalesce((
      select jsonb_agg(jsonb_build_object(
               'number', 'INV-' || o.id, 'orderId', o.id, 'date', o.order_date, 'issueDate', o.order_date, 'originalDueDate', cc.due_date, 'dueDate', public._credit_effective_due(o.id),
               'termsDays', cc.terms_days,
               'total', o.total, 'paid', o.amount_paid, 'outstanding', o.outstanding_balance,
               'status', case when o.outstanding_balance <= 0 then 'PAID' when o.amount_paid > 0 then 'PARTIALLY PAID' else 'UNPAID' end,
               'overdue', (o.outstanding_balance > 0 and cc.due_date is not null and public._credit_effective_due(o.id) < v_today),
               'defaulted', exists (select 1 from public.customer_credit_defaults d where d.order_id = o.id and d.voided_at is null),
               'extensions', coalesce((select jsonb_agg(jsonb_build_object('previousDue', e.previous_due, 'newDue', e.new_due, 'at', e.created_at) order by e.id)
                                         from public.credit_due_extensions e where e.order_id = o.id), '[]'::jsonb),
               'dispute', (select jsonb_build_object('status', x.status, 'openedAt', x.opened_at, 'resolution', x.resolution) from public.credit_disputes x where x.order_id = o.id order by x.opened_at desc limit 1),
               'items', coalesce((select jsonb_agg(jsonb_build_object('productName', i.product_name, 'designName', i.design_name, 'quantity', i.quantity,
                                                                        'unitPrice', i.actual_unit_price, 'lineTotal', i.line_revenue) order by i.created_at, i.id)
                                    from public.order_items i where i.order_id = o.id), '[]'::jsonb),
               'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'receiptNumber', case when p.id like 'pay-%' and p.id not like 'pay-\_%' then 'RCT-' || substr(p.id, 5) else 'RCT-_' || p.id end,
                                                                           'date', p.payment_date, 'amount', p.amount, 'method', p.payment_method, 'reference', p.reference)
                                                       order by p.payment_date, p.created_at, p.id)
                                       from public.payments p where p.order_id = o.id), '[]'::jsonb))
             order by o.order_date desc, o.created_at desc, o.id)
        from public.orders o left join public.customer_credit_orders cc on cc.order_id = o.id
       where o.customer_id = v_customer and o.status <> 'cancelled' and o.payment_terms = 'credit' and o.total > 0), '[]'::jsonb),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', x.id, 'receiptNumber', x.receipt_no, 'orderId', x.order_id, 'date', x.payment_date, 'amount', x.amount, 'method', x.payment_method,
               'reference', x.reference, 'terms', x.payment_terms, 'invoiceNumber', case when x.payment_terms = 'credit' then 'INV-' || x.order_id end,
               'orderTotal', x.total, 'paidToDate', x.paid_to_date, 'balanceAfter', greatest(x.total - x.paid_to_date, 0))
             order by x.payment_date desc, x.created_at desc, x.id)
        from (select p.id, p.order_id, p.payment_date, p.created_at, p.amount, p.payment_method, p.reference, o.payment_terms, o.total,
                     case when p.id like 'pay-%' and p.id not like 'pay-\_%' then 'RCT-' || substr(p.id, 5) else 'RCT-_' || p.id end as receipt_no,
                     sum(p.amount) over (partition by p.order_id order by p.payment_date, p.created_at, p.id) as paid_to_date
                from public.payments p join public.orders o on o.id = p.order_id
               where o.customer_id = v_customer and o.status <> 'cancelled' and p.amount > 0) x), '[]'::jsonb),
    'statement', jsonb_build_object(
      'openingBalance', 0,
      'entries', coalesce((
        select jsonb_agg(jsonb_build_object('date', s.d, 'kind', s.kind, 'reference', s.ref, 'orderId', s.order_id, 'description', s.descr, 'debit', s.debit, 'credit', s.credit, 'balance', s.balance)
                         order by s.d, s.ts, s.ord, s.ref)
          from (select e.*, sum(e.debit - e.credit) over (order by e.d, e.ts, e.ord, e.ref) as balance
                  from (select o.order_date as d, o.created_at as ts, 0 as ord,
                               case when o.payment_terms = 'credit' then 'invoice' else 'order' end as kind,
                               case when o.payment_terms = 'credit' then 'INV-' || o.id else o.id end as ref, o.id as order_id,
                               case when o.payment_terms = 'credit' then 'Invoice for order ' || o.id else 'Order ' || o.id end as descr,
                               o.total as debit, 0::numeric as credit
                          from public.orders o where o.customer_id = v_customer and o.status <> 'cancelled' and o.total > 0
                        union all
                        select p.payment_date, p.created_at, 1, 'payment',
                               case when p.id like 'pay-%' and p.id not like 'pay-\_%' then 'RCT-' || substr(p.id, 5) else 'RCT-_' || p.id end, p.order_id,
                               'Payment (' || p.payment_method || ') for order ' || p.order_id, 0::numeric, p.amount
                          from public.payments p join public.orders o on o.id = p.order_id
                         where o.customer_id = v_customer and o.status <> 'cancelled' and p.amount > 0) e) s), '[]'::jsonb),
      'closingBalance', (select coalesce(sum(o.outstanding_balance), 0) from public.orders o where o.customer_id = v_customer and o.status <> 'cancelled')),
    'credit', public._customer_credit_summary(v_customer));
end;
$fn$;

-- -----------------------------------------------------------------------------
-- 7. Customer functions: notices and disputes
-- -----------------------------------------------------------------------------
create or replace function public.my_notifications()
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare v_customer text := public.require_approved_customer();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'orderId', n.order_id, 'createdAt', n.created_at, 'read', n.read_at is not null) order by n.created_at desc)
                     from (select * from public.customer_notifications where customer_id = v_customer order by created_at desc limit 30) n), '[]'::jsonb);
end;
$fn$;
revoke all on function public.my_notifications() from public, anon;
grant execute on function public.my_notifications() to authenticated;

create or replace function public.customer_mark_notification_read(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
declare v_customer text := public.require_approved_customer();
begin
  update public.customer_notifications set read_at = now() where id = p_id and customer_id = v_customer and read_at is null;
end;
$fn$;
revoke all on function public.customer_mark_notification_read(uuid) from public, anon;
grant execute on function public.customer_mark_notification_read(uuid) to authenticated;

-- A customer may raise a dispute about their own credit invoice; they can never change its status. It does not stop the invoice from defaulting.
create or replace function public.customer_open_credit_dispute(p_order_id text, p_reason text, p_amount numeric default null)
returns uuid
language plpgsql volatile security definer set search_path = public
as $fn$
declare v_customer text := public.require_approved_customer(); v_id uuid; v_reason text := btrim(coalesce(p_reason, '')); v_total numeric;
begin
  perform pg_advisory_xact_lock(hashtext('dispute:' || v_customer));
  select o.total into v_total from public.orders o join public.customer_credit_orders cc on cc.order_id = o.id where o.id = p_order_id and o.customer_id = v_customer and o.status <> 'cancelled';
  if not found then raise exception 'That invoice was not found' using errcode = '22023'; end if;
  if char_length(v_reason) < 10 or char_length(v_reason) > 1000 then raise exception 'Describe the problem (10 to 1000 characters)' using errcode = '22023'; end if;
  if p_amount is not null and (p_amount <= 0 or p_amount > v_total) then raise exception 'The disputed amount must be more than 0 and not more than the invoice total' using errcode = '22023'; end if;
  if exists (select 1 from public.credit_disputes x where x.order_id = p_order_id and x.status in ('open', 'investigating')) then raise exception 'A dispute is already open on this invoice' using errcode = '22023'; end if;
  if (select count(*) from public.credit_disputes x where x.customer_id = v_customer and x.opened_at > now() - interval '24 hours') >= 5 then raise exception 'Too many disputes today. Please contact EFZ.' using errcode = 'WR429'; end if;
  insert into public.credit_disputes (customer_id, order_id, reason, disputed_amount) values (v_customer, p_order_id, v_reason, p_amount) returning id into v_id;
  perform public._credit_event(v_customer, 'dispute_opened', format('The customer opened a dispute on invoice INV-%s', p_order_id), jsonb_build_object('orderId', p_order_id, 'disputeId', v_id, 'amount', p_amount));
  perform public._credit_audit('INFO', format('Credit dispute opened on invoice INV-%s', p_order_id), v_customer, jsonb_build_object('event', 'credit_dispute_opened', 'orderId', p_order_id, 'disputeId', v_id));
  perform public._credit_notify_staff('staff', 'Credit invoice disputed', format('A customer disputed invoice INV-%s. The invoice still falls due; review it in Customer Payments & Credit.', p_order_id));
  return v_id;
end;
$fn$;
revoke all on function public.customer_open_credit_dispute(text, text, numeric) from public, anon;
grant execute on function public.customer_open_credit_dispute(text, text, numeric) to authenticated;

-- -----------------------------------------------------------------------------
-- 8. Administration (Super Admin only; every change is audited with the old values)
-- -----------------------------------------------------------------------------
-- Same signature as migration 24. Enabling now needs the whole approved policy to be defined, and the company-wide cap to be computable.
create or replace function public.set_credit_policy(
  p_enabled boolean, p_min_purchases integer, p_min_value numeric, p_require_no_unpaid boolean, p_default_terms_days integer, p_reason text,
  p_min_approved_days integer default null, p_max_outstanding numeric default null, p_require_no_overdue boolean default true)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare v_before jsonb; pol public.credit_policy%rowtype; v_cap jsonb; v_missing text[] := '{}';
begin
  perform public._require_finance_admin();
  if p_reason is null or char_length(btrim(p_reason)) < 5 then raise exception 'Give a reason (at least 5 characters)' using errcode = '22023'; end if;
  if p_require_no_overdue is false then
    raise exception 'The overdue rule cannot be switched off: under the credit policy a missed due date revokes credit at once, with no grace period' using errcode = '22023';
  end if;
  select * into pol from public.credit_policy where id;
  if p_enabled then
    if p_min_purchases is null then v_missing := array_append(v_missing, 'minimum qualifying purchases'); end if;
    if p_min_approved_days is null then v_missing := array_append(v_missing, 'minimum approved-account age'); end if;
    if pol.purchase_window_days is null then v_missing := array_append(v_missing, 'purchase-history window'); end if;
    if pol.initial_credit_limit is null then v_missing := array_append(v_missing, 'initial credit limit'); end if;
    if p_default_terms_days is null then v_missing := array_append(v_missing, 'repayment term'); end if;
    if pol.company_cap_percent is null or pol.cap_basis_months is null then v_missing := array_append(v_missing, 'company-wide cap (percentage and months)'); end if;
    if cardinality(v_missing) > 0 then
      raise exception 'Credit cannot be enabled until the policy is complete. Missing: %', array_to_string(v_missing, ', ') using errcode = '22023';
    end if;
    v_cap := public._credit_company_cap();
    if not (v_cap ->> 'sufficient')::boolean then
      raise exception 'Credit cannot be enabled: the company-wide cap cannot be computed reliably. % An authorized administrator must review this.', v_cap ->> 'reason' using errcode = '22023';
    end if;
  end if;
  select to_jsonb(p) into v_before from public.credit_policy p where p.id;
  update public.credit_policy set enabled = coalesce(p_enabled, false), min_completed_purchases = p_min_purchases, min_total_value = p_min_value,
         min_approved_days = p_min_approved_days, max_outstanding = p_max_outstanding, require_no_overdue = true,
         require_no_unpaid_delivered = coalesce(p_require_no_unpaid, true), default_terms_days = p_default_terms_days,
         updated_by = public.current_profile_id(), updated_at = now(), note = btrim(p_reason) where id;
  perform public.finance_audit(format('Credit policy %s', case when p_enabled then 'enabled' else 'saved (credit off)' end), 'credit_policy',
    jsonb_build_object('event', 'credit_policy_set', 'before', v_before, 'enabled', p_enabled, 'minPurchases', p_min_purchases, 'minValue', p_min_value,
                       'minApprovedDays', p_min_approved_days, 'maxOutstanding', p_max_outstanding, 'requireNoOverdue', true,
                       'requireNoUnpaid', p_require_no_unpaid, 'defaultTermsDays', p_default_terms_days, 'reason', btrim(p_reason)));
end;
$fn$;

-- The settings migration 24's function does not carry. All arguments are explicit (null clears a value).
create or replace function public.set_credit_policy_rules(
  p_purchase_window_days integer, p_initial_limit numeric, p_cap_percent numeric, p_cap_months integer, p_allow_override boolean, p_reason text)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
declare v_before jsonb;
begin
  perform public._require_finance_admin();
  if p_reason is null or char_length(btrim(p_reason)) < 5 then raise exception 'Give a reason (at least 5 characters)' using errcode = '22023'; end if;
  if p_purchase_window_days is not null and p_purchase_window_days < 1 then raise exception 'The purchase-history window must be at least 1 day' using errcode = '22023'; end if;
  if p_initial_limit is not null and (p_initial_limit <= 0 or p_initial_limit > 1000000 or p_initial_limit <> round(p_initial_limit, 2)) then raise exception 'The initial limit must be more than 0 and at most 1,000,000, in whole cents' using errcode = '22023'; end if;
  if p_cap_percent is not null and (p_cap_percent <= 0 or p_cap_percent > 100) then raise exception 'The company-wide cap percentage must be above 0 and at most 100' using errcode = '22023'; end if;
  if p_cap_months is not null and p_cap_months not between 1 and 24 then raise exception 'The cap basis must be 1 to 24 complete calendar months' using errcode = '22023'; end if;
  if (select enabled from public.credit_policy where id) and (p_purchase_window_days is null or p_initial_limit is null or p_cap_percent is null or p_cap_months is null) then
    raise exception 'Credit is enabled: switch it off before clearing one of these settings' using errcode = '22023';
  end if;
  select to_jsonb(p) into v_before from public.credit_policy p where p.id;
  update public.credit_policy set purchase_window_days = p_purchase_window_days, initial_credit_limit = p_initial_limit, company_cap_percent = p_cap_percent, cap_basis_months = p_cap_months,
         allow_requirement_override = coalesce(p_allow_override, false), updated_by = public.current_profile_id(), updated_at = now(), note = btrim(p_reason) where id;
  perform public.finance_audit('Credit policy rules saved', 'credit_policy',
    jsonb_build_object('event', 'credit_policy_rules_set', 'before', v_before, 'purchaseWindowDays', p_purchase_window_days, 'initialLimit', p_initial_limit, 'capPercent', p_cap_percent,
                       'capMonths', p_cap_months, 'allowOverride', coalesce(p_allow_override, false), 'reason', btrim(p_reason)));
end;
$fn$;
revoke all on function public.set_credit_policy_rules(integer, numeric, numeric, integer, boolean, text) from public, anon;
grant execute on function public.set_credit_policy_rules(integer, numeric, numeric, integer, boolean, text) to authenticated;

create or replace function public.credit_company_cap()
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
begin
  perform public._require_finance_admin();
  return public._credit_company_cap();
end;
$fn$;
revoke all on function public.credit_company_cap() from public, anon;
grant execute on function public.credit_company_cap() to authenticated;

-- Authorizing credit. The term is the policy's fixed term; the first (or renewed) limit can be at most the initial limit; a customer with a default is
-- authorized only after completing the full requalification, and no override ever covers a default or the account's standing.
create or replace function public.set_customer_credit(p_customer_id text, p_limit numeric, p_terms_days integer, p_reason text, p_override_reason text default null)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  pol      public.credit_policy%rowtype;
  acc      public.customer_credit_accounts%rowtype;
  v_elig   jsonb;
  v_before jsonb;
  v_over   text := nullif(btrim(coalesce(p_override_reason, '')), '');
  v_unmet  boolean;
  v_hist   integer;
  v_renew  boolean;
begin
  perform public._require_finance_admin();
  perform pg_advisory_xact_lock(hashtext('credit:company'));
  perform pg_advisory_xact_lock(hashtext('checkout:' || p_customer_id));
  select * into pol from public.credit_policy where id;
  if not pol.enabled then raise exception 'Credit purchasing is not enabled in the credit policy' using errcode = '22023'; end if;
  if not exists (select 1 from public.customer_accounts a where a.customer_id = p_customer_id and a.status = 'approved' and a.deletion_requested_at is null) then
    raise exception 'The customer has no approved app account' using errcode = '22023';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) < 5 then raise exception 'Give a reason (at least 5 characters)' using errcode = '22023'; end if;
  if p_limit is null or p_limit <= 0 or p_limit > 1000000 or p_limit <> round(p_limit, 2) then raise exception 'The credit limit must be more than 0 and at most 1,000,000, in whole cents' using errcode = '22023'; end if;
  if pol.default_terms_days is null or p_terms_days is distinct from pol.default_terms_days then
    raise exception 'The repayment term is fixed by the credit policy (% days)', coalesce(pol.default_terms_days::text, 'not set') using errcode = '22023';
  end if;
  perform public._credit_sync_defaults(p_customer_id);
  select * into acc from public.customer_credit_accounts where customer_id = p_customer_id;
  v_renew := acc.customer_id is null or acc.status = 'revoked';
  if v_renew and (pol.initial_credit_limit is null or p_limit > pol.initial_credit_limit) then
    raise exception 'A new or renewed credit limit cannot exceed the initial limit ($%)', coalesce(pol.initial_credit_limit::text, 'not set') using errcode = '22023';
  end if;
  if not v_renew and p_limit > acc.credit_limit then
    raise exception 'Use the audited limit increase for a higher limit; this action can only keep or lower it' using errcode = '22023';
  end if;
  v_elig := public._customer_credit_eligibility(p_customer_id);
  v_hist := (v_elig -> 'defaultHistory' ->> 'count')::integer;
  if jsonb_array_length(v_elig -> 'standingReasons') > 0 then
    raise exception 'The customer''s account standing does not allow credit (%). Credit cannot be authorized until it is resolved; an override does not apply.', v_elig -> 'standingReasons' using errcode = '22023';
  end if;
  v_unmet := jsonb_array_length(v_elig -> 'reasons') > 0;
  if v_unmet then
    if v_hist > 0 then
      raise exception 'The customer defaulted and has not completed requalification (%). No override applies to a default.', v_elig -> 'reasons' using errcode = '22023';
    elsif not pol.allow_requirement_override then
      raise exception 'The customer does not meet the credit policy (%). Requirement overrides are not enabled in the policy.', v_elig -> 'reasons' using errcode = '22023';
    elsif v_over is null or char_length(v_over) < 10 then
      raise exception 'The customer does not meet the credit policy (%). A recorded override reason of at least 10 characters is required.', v_elig -> 'reasons' using errcode = '22023';
    end if;
  end if;
  select to_jsonb(a) into v_before from public.customer_credit_accounts a where a.customer_id = p_customer_id;
  insert into public.customer_credit_accounts (customer_id, status, credit_limit, terms_days, reason, override_used, set_by, set_at)
  values (p_customer_id, 'approved', p_limit, p_terms_days, btrim(p_reason), v_unmet, public.current_profile_id(), now())
  on conflict (customer_id) do update set status = 'approved', credit_limit = excluded.credit_limit, terms_days = excluded.terms_days, reason = excluded.reason,
         override_used = excluded.override_used, set_by = excluded.set_by, set_at = now();
  update public.customer_credit_defaults set requalified_at = now() where customer_id = any (public._credit_related_customers(p_customer_id)) and voided_at is null and settled_at is not null and requalified_at is null;
  perform public._credit_event(p_customer_id, case when v_hist > 0 then 'requalified' else 'credit_approved' end,
                               format('Credit %s: limit $%s, %s days', case when v_hist > 0 then 'approved again after requalification' else 'approved' end, p_limit, p_terms_days),
                               jsonb_build_object('limit', p_limit, 'termsDays', p_terms_days, 'reason', btrim(p_reason), 'override', v_unmet));
  perform public.finance_audit(format('Credit limit of $%s (%s days) set for customer %s', p_limit, p_terms_days, p_customer_id), p_customer_id,
    jsonb_build_object('event', 'customer_credit_set', 'before', v_before, 'limit', p_limit, 'termsDays', p_terms_days, 'reason', btrim(p_reason),
                       'eligibility', v_elig, 'overrideReason', v_over, 'requalification', v_hist > 0));
end;
$fn$;

-- The only way a limit goes up: a Super Admin action with a reason, audited, and never for a customer who has defaulted. Nothing raises limits by itself.
create or replace function public.increase_customer_credit_limit(p_customer_id text, p_new_limit numeric, p_reason text)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
declare acc public.customer_credit_accounts%rowtype; v_elig jsonb;
begin
  perform public._require_finance_admin();
  perform pg_advisory_xact_lock(hashtext('credit:company'));
  perform pg_advisory_xact_lock(hashtext('checkout:' || p_customer_id));
  if (select enabled from public.credit_policy where id) is not true then raise exception 'Credit purchasing is not enabled in the credit policy' using errcode = '22023'; end if;
  if p_reason is null or char_length(btrim(p_reason)) < 10 then raise exception 'Give a reason (at least 10 characters)' using errcode = '22023'; end if;
  perform public._credit_sync_defaults(p_customer_id);
  select * into acc from public.customer_credit_accounts where customer_id = p_customer_id;
  if not found or acc.status <> 'approved' then raise exception 'The customer has no active credit account' using errcode = '22023'; end if;
  if p_new_limit is null or p_new_limit <= acc.credit_limit or p_new_limit > 1000000 or p_new_limit <> round(p_new_limit, 2) then
    raise exception 'The new limit must be higher than the current limit ($%) and at most 1,000,000, in whole cents', acc.credit_limit using errcode = '22023';
  end if;
  v_elig := public._customer_credit_eligibility(p_customer_id);
  if (v_elig -> 'defaultHistory' ->> 'count')::integer > 0 then
    raise exception 'A customer who has defaulted keeps the initial limit; raising it needs a separately approved policy' using errcode = '22023';
  end if;
  if jsonb_array_length(v_elig -> 'standingReasons') > 0 or jsonb_array_length(v_elig -> 'reasons') > 0 then
    raise exception 'The limit cannot be raised while the customer does not meet the policy or has an account-standing problem' using errcode = '22023';
  end if;
  update public.customer_credit_accounts set credit_limit = p_new_limit, reason = btrim(p_reason), set_by = public.current_profile_id(), set_at = now() where customer_id = p_customer_id;
  perform public._credit_event(p_customer_id, 'limit_increase', format('Credit limit raised from $%s to $%s', acc.credit_limit, p_new_limit), jsonb_build_object('from', acc.credit_limit, 'to', p_new_limit, 'reason', btrim(p_reason)));
  perform public.finance_audit(format('Credit limit raised from $%s to $%s for customer %s', acc.credit_limit, p_new_limit, p_customer_id), p_customer_id,
    jsonb_build_object('event', 'customer_credit_limit_increase', 'from', acc.credit_limit, 'to', p_new_limit, 'reason', btrim(p_reason)));
end;
$fn$;
revoke all on function public.increase_customer_credit_limit(text, numeric, text) from public, anon;
grant execute on function public.increase_customer_credit_limit(text, numeric, text) to authenticated;

-- An approved extension: recorded with the old and new date, who authorized it, why and when. Only before the invoice is overdue; the original date is never changed.
create or replace function public.extend_credit_due_date(p_order_id text, p_new_due date, p_reason text)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
declare o public.orders%rowtype; v_eff date; v_cust text;
begin
  perform public._require_finance_admin();
  if p_reason is null or char_length(btrim(p_reason)) < 10 then raise exception 'Give a reason (at least 10 characters)' using errcode = '22023'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found or not exists (select 1 from public.customer_credit_orders where order_id = p_order_id) then raise exception 'That is not a credit invoice' using errcode = '22023'; end if;
  if o.status = 'cancelled' or o.outstanding_balance <= 0 then raise exception 'Only an unpaid credit invoice can be extended' using errcode = '22023'; end if;
  perform public._credit_sync_defaults(o.customer_id);
  if exists (select 1 from public.customer_credit_defaults d where d.order_id = p_order_id) then
    raise exception 'The invoice has already defaulted; a default cannot be undone by an extension' using errcode = '22023';
  end if;
  v_eff := public._credit_effective_due(p_order_id);
  if v_eff < public.efz_today() then raise exception 'The invoice is already past its due date' using errcode = '22023'; end if;
  if p_new_due is null or p_new_due <= v_eff then raise exception 'The new due date must be later than the current one (%)', v_eff using errcode = '22023'; end if;
  insert into public.credit_due_extensions (order_id, previous_due, new_due, authorized_by, reason) values (p_order_id, v_eff, p_new_due, coalesce(public.current_profile_name(), public.current_profile_id()), btrim(p_reason));
  perform public._credit_event(o.customer_id, 'due_date_extended', format('Invoice INV-%s: due date moved from %s to %s', p_order_id, v_eff, p_new_due), jsonb_build_object('orderId', p_order_id, 'from', v_eff, 'to', p_new_due, 'reason', btrim(p_reason)));
  perform public.finance_audit(format('Due date of INV-%s extended from %s to %s', p_order_id, v_eff, p_new_due), o.customer_id,
    jsonb_build_object('event', 'credit_due_extended', 'orderId', p_order_id, 'from', v_eff, 'to', p_new_due, 'reason', btrim(p_reason)));
end;
$fn$;
revoke all on function public.extend_credit_due_date(text, date, text) from public, anon;
grant execute on function public.extend_credit_due_date(text, date, text) to authenticated;

create or replace function public.record_credit_risk_review(p_default_id uuid, p_note text)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
declare d public.customer_credit_defaults%rowtype;
begin
  perform public._require_finance_admin();
  if p_note is null or char_length(btrim(p_note)) < 10 then raise exception 'Document the review (at least 10 characters)' using errcode = '22023'; end if;
  select * into d from public.customer_credit_defaults where id = p_default_id for update;
  if not found or d.review_required_at is null then raise exception 'No credit-risk review is required for that default' using errcode = '22023'; end if;
  if d.reviewed_at is not null then raise exception 'That review is already recorded' using errcode = '22023'; end if;
  update public.customer_credit_defaults set reviewed_at = now(), reviewed_by = coalesce(public.current_profile_name(), public.current_profile_id()), review_note = btrim(p_note) where id = p_default_id;
  perform public._credit_event(d.customer_id, 'risk_review', format('Credit-risk review recorded for invoice INV-%s', d.order_id), jsonb_build_object('orderId', d.order_id, 'note', btrim(p_note)));
  perform public.finance_audit(format('Credit-risk review recorded for INV-%s', d.order_id), d.customer_id, jsonb_build_object('event', 'credit_risk_review', 'orderId', d.order_id, 'note', btrim(p_note)));
end;
$fn$;
revoke all on function public.record_credit_risk_review(uuid, text) from public, anon;
grant execute on function public.record_credit_risk_review(uuid, text) to authenticated;

-- Disputes (staff side)
create or replace function public.list_credit_disputes(p_status text default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
begin
  perform public._require_finance_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'customerId', x.customer_id, 'customerName', c.name, 'orderId', x.order_id, 'reason', x.reason, 'disputedAmount', x.disputed_amount,
                                                       'status', x.status, 'openedBy', x.opened_by, 'openedAt', x.opened_at, 'assignedTo', x.assigned_to, 'staffNotes', x.staff_notes,
                                                       'resolution', x.resolution, 'resolvedBy', x.resolved_by, 'resolvedAt', x.resolved_at,
                                                       'defaultId', (select d.id from public.customer_credit_defaults d where d.order_id = x.order_id and d.voided_at is null limit 1))
                              order by (x.status in ('open', 'investigating')) desc, x.opened_at desc)
                     from public.credit_disputes x join public.customers c on c.id = x.customer_id where p_status is null or x.status = p_status), '[]'::jsonb);
end;
$fn$;
revoke all on function public.list_credit_disputes(text) from public, anon;
grant execute on function public.list_credit_disputes(text) to authenticated;

create or replace function public.update_credit_dispute(p_id uuid, p_assign_to text, p_note text)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
declare x public.credit_disputes%rowtype;
begin
  perform public._require_finance_admin();
  select * into x from public.credit_disputes where id = p_id for update;
  if not found or x.status not in ('open', 'investigating') then raise exception 'Only an unresolved dispute can be updated' using errcode = '22023'; end if;
  if p_note is null or char_length(btrim(p_note)) < 5 then raise exception 'Add a note (at least 5 characters)' using errcode = '22023'; end if;
  update public.credit_disputes set status = 'investigating', assigned_to = coalesce(nullif(btrim(p_assign_to), ''), assigned_to, public.current_profile_name()),
         staff_notes = case when staff_notes = '' then btrim(p_note) else staff_notes || E'\n' || btrim(p_note) end, updated_at = now() where id = p_id;
  perform public._credit_event(x.customer_id, 'dispute_updated', format('Dispute on INV-%s is being investigated', x.order_id), jsonb_build_object('disputeId', p_id, 'orderId', x.order_id));
  perform public.finance_audit(format('Dispute on INV-%s updated', x.order_id), x.customer_id, jsonb_build_object('event', 'credit_dispute_updated', 'disputeId', p_id, 'assignedTo', p_assign_to));
end;
$fn$;
revoke all on function public.update_credit_dispute(uuid, text, text) from public, anon;
grant execute on function public.update_credit_dispute(uuid, text, text) to authenticated;

create or replace function public.resolve_credit_dispute(p_id uuid, p_outcome text, p_resolution text)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
declare x public.credit_disputes%rowtype;
begin
  perform public._require_finance_admin();
  if p_outcome not in ('billing_error', 'rejected') then raise exception 'The outcome must be billing_error or rejected' using errcode = '22023'; end if;
  if p_resolution is null or char_length(btrim(p_resolution)) < 10 then raise exception 'Record the resolution (at least 10 characters)' using errcode = '22023'; end if;
  select * into x from public.credit_disputes where id = p_id for update;
  if not found or x.status not in ('open', 'investigating') then raise exception 'Only an unresolved dispute can be resolved' using errcode = '22023'; end if;
  update public.credit_disputes set status = case when p_outcome = 'billing_error' then 'resolved_billing_error' else 'resolved_rejected' end, resolution = btrim(p_resolution),
         resolved_by = coalesce(public.current_profile_name(), public.current_profile_id()), resolved_at = now(), updated_at = now() where id = p_id;
  perform public._credit_event(x.customer_id, 'dispute_resolved', format('Dispute on INV-%s resolved: %s', x.order_id, p_outcome), jsonb_build_object('disputeId', p_id, 'orderId', x.order_id, 'outcome', p_outcome));
  perform public.finance_audit(format('Dispute on INV-%s resolved (%s)', x.order_id, p_outcome), x.customer_id, jsonb_build_object('event', 'credit_dispute_resolved', 'disputeId', p_id, 'outcome', p_outcome, 'resolution', btrim(p_resolution)));
  insert into public.customer_notifications (customer_id, kind, title, body, order_id)
  values (x.customer_id, 'dispute_resolved', 'Your invoice dispute was reviewed', format('EFZ reviewed your dispute on invoice INV-%s: %s', x.order_id, btrim(p_resolution)), x.order_id);
end;
$fn$;
revoke all on function public.resolve_credit_dispute(uuid, text, text) from public, anon;
grant execute on function public.resolve_credit_dispute(uuid, text, text) to authenticated;

-- The documented way to correct a legitimate billing error without erasing history: a default is VOIDED (kept, marked, with who/why/which dispute),
-- never deleted, and only when a dispute on that very invoice was resolved as a billing error. Credit is not restored by this: a Super Admin approves it again.
create or replace function public.void_credit_default(p_default_id uuid, p_dispute_id uuid, p_reason text)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
declare d public.customer_credit_defaults%rowtype; x public.credit_disputes%rowtype;
begin
  perform public._require_finance_admin();
  if p_reason is null or char_length(btrim(p_reason)) < 10 then raise exception 'Give a reason (at least 10 characters)' using errcode = '22023'; end if;
  select * into d from public.customer_credit_defaults where id = p_default_id for update;
  if not found or d.voided_at is not null then raise exception 'That default does not exist or is already voided' using errcode = '22023'; end if;
  select * into x from public.credit_disputes where id = p_dispute_id;
  if not found or x.status <> 'resolved_billing_error' or x.order_id <> d.order_id or x.customer_id <> d.customer_id then
    raise exception 'A default can be voided only after a dispute on the same invoice was resolved as a billing error' using errcode = '22023';
  end if;
  update public.customer_credit_defaults set voided_at = now(), voided_by = coalesce(public.current_profile_name(), public.current_profile_id()), void_reason = btrim(p_reason), void_dispute_id = p_dispute_id where id = p_default_id;
  perform public._credit_event(d.customer_id, 'default_voided', format('The default on INV-%s was voided after a billing error (the record is kept)', d.order_id), jsonb_build_object('orderId', d.order_id, 'disputeId', p_dispute_id, 'reason', btrim(p_reason)));
  perform public._credit_audit('WARNING', format('Credit default on INV-%s voided (billing error)', d.order_id), d.customer_id, jsonb_build_object('event', 'credit_default_voided', 'orderId', d.order_id, 'disputeId', p_dispute_id, 'reason', btrim(p_reason)));
end;
$fn$;
revoke all on function public.void_credit_default(uuid, uuid, text) from public, anon;
grant execute on function public.void_credit_default(uuid, uuid, text) to authenticated;

-- The daily run: for the scheduler (service_role) and, for a manual run, a Super Admin.
create or replace function public.credit_daily_run()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $fn$
begin
  return public._credit_run();
end;
$fn$;
revoke all on function public.credit_daily_run() from public, anon, authenticated;
grant execute on function public.credit_daily_run() to service_role;

create or replace function public.run_credit_checks()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $fn$
begin
  perform public._require_finance_admin();
  return public._credit_run();
end;
$fn$;
revoke all on function public.run_credit_checks() from public, anon;
grant execute on function public.run_credit_checks() to authenticated;

-- -----------------------------------------------------------------------------
-- 9. What staff see
-- -----------------------------------------------------------------------------
create or replace function public.credit_overview()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare v_r record;
begin
  perform public._require_finance_admin();
  for v_r in select distinct customer_id from public.customer_credit_orders loop perform public._credit_sync_defaults(v_r.customer_id); end loop;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'customerId', c.id, 'name', c.name, 'eligibility', public._customer_credit_eligibility(c.id),
             'outstanding', (select coalesce(sum(o.outstanding_balance), 0) from public.orders o where o.customer_id = c.id and o.status <> 'cancelled'),
             'creditOutstanding', (select coalesce(sum(o.outstanding_balance), 0) from public.orders o where o.customer_id = c.id and o.status <> 'cancelled' and o.payment_terms = 'credit'),
             'account', (select to_jsonb(a) - 'set_by' from public.customer_credit_accounts a where a.customer_id = c.id))
           order by c.name, c.id)
      from public.customers c
     where exists (select 1 from public.customer_accounts ca where ca.customer_id = c.id and ca.status = 'approved')), '[]'::jsonb);
end;
$fn$;

create or replace function public.credit_history(p_customer_id text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $fn$
begin
  perform public._require_finance_admin();
  perform public._credit_sync_defaults(p_customer_id);
  return jsonb_build_object(
    'account', (select to_jsonb(a) - 'set_by' from public.customer_credit_accounts a where a.customer_id = p_customer_id),
    'events', coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'by', e.actor, 'message', e.message, 'event', e.kind) order by e.id desc) from public.customer_credit_events e where e.customer_id = p_customer_id), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(jsonb_build_object('orderId', cc.order_id, 'date', o.order_date, 'issueDate', o.order_date, 'originalDueDate', cc.due_date, 'dueDate', public._credit_effective_due(cc.order_id),
                                                              'termsDays', cc.terms_days, 'limitAtTime', cc.credit_limit_at_time, 'total', o.total, 'paid', o.amount_paid, 'outstanding', o.outstanding_balance, 'status', o.status::text,
                                                              'overdue', (o.status <> 'cancelled' and o.outstanding_balance > 0 and public._credit_effective_due(cc.order_id) < public.efz_today()),
                                                              'extensions', coalesce((select jsonb_agg(jsonb_build_object('previousDue', x.previous_due, 'newDue', x.new_due, 'by', x.authorized_by, 'reason', x.reason, 'at', x.created_at) order by x.id)
                                                                                        from public.credit_due_extensions x where x.order_id = cc.order_id), '[]'::jsonb))
                                                order by o.order_date desc, cc.order_id)
                          from public.customer_credit_orders cc join public.orders o on o.id = cc.order_id where cc.customer_id = p_customer_id), '[]'::jsonb),
    'defaults', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'orderId', d.order_id, 'dueDate', d.due_date, 'defaultedOn', d.defaulted_on, 'amountAtDefault', d.amount_at_default, 'limitAtDefault', d.limit_at_default,
                                                                'settledAt', d.settled_at, 'requalifiedAt', d.requalified_at, 'voidedAt', d.voided_at, 'voidReason', d.void_reason,
                                                                'reviewRequiredAt', d.review_required_at, 'reviewedAt', d.reviewed_at, 'reviewNote', d.review_note) order by d.defaulted_on desc)
                          from public.customer_credit_defaults d where d.customer_id = p_customer_id), '[]'::jsonb),
    'disputes', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'orderId', x.order_id, 'status', x.status, 'reason', x.reason, 'openedAt', x.opened_at, 'resolution', x.resolution, 'assignedTo', x.assigned_to) order by x.opened_at desc)
                            from public.credit_disputes x where x.customer_id = p_customer_id), '[]'::jsonb),
    'reminders', coalesce((select jsonb_agg(jsonb_build_object('orderId', r.order_id, 'kind', r.kind, 'audience', r.audience, 'status', r.status, 'attempts', r.attempts, 'lastError', r.last_error, 'sentAt', r.sent_at, 'createdAt', r.created_at) order by r.id desc)
                             from public.credit_reminders r where r.customer_id = p_customer_id), '[]'::jsonb));
end;
$fn$;

-- One call for the Hub's operations panel: the company cap, every default with its follow-up and review state, failed reminders, open disputes.
create or replace function public.credit_operations()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare v_r record; v_today date := public.efz_today();
begin
  perform public._require_finance_admin();
  for v_r in select distinct customer_id from public.customer_credit_orders loop perform public._credit_sync_defaults(v_r.customer_id); end loop;
  return jsonb_build_object(
    'asOf', v_today,
    'companyCap', public._credit_company_cap(),
    'defaults', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'customerId', d.customer_id, 'customerName', cu.name, 'orderId', d.order_id, 'dueDate', d.due_date, 'defaultedOn', d.defaulted_on,
                                                              'amountAtDefault', d.amount_at_default, 'outstanding', o.outstanding_balance, 'daysOverdue', case when o.outstanding_balance > 0 then v_today - public._credit_effective_due(d.order_id) end,
                                                              'status', case when d.voided_at is not null then 'voided' when d.settled_at is not null then 'settled' else 'open' end,
                                                              'settledAt', d.settled_at, 'requalifiedAt', d.requalified_at,
                                                              'followUpDue', (d.settled_at is null and d.voided_at is null and v_today - public._credit_effective_due(d.order_id) >= 7),
                                                              'reviewRequiredAt', d.review_required_at, 'reviewedAt', d.reviewed_at, 'reviewNote', d.review_note, 'voidedAt', d.voided_at)
                                   order by (d.settled_at is null and d.voided_at is null) desc, d.defaulted_on desc)
                          from public.customer_credit_defaults d join public.customers cu on cu.id = d.customer_id join public.orders o on o.id = d.order_id), '[]'::jsonb),
    'failedReminders', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'orderId', r.order_id, 'kind', r.kind, 'audience', r.audience, 'attempts', r.attempts, 'lastError', r.last_error, 'createdAt', r.created_at) order by r.id desc)
                                   from public.credit_reminders r where r.status = 'failed'), '[]'::jsonb),
    'openDisputes', (select count(*) from public.credit_disputes x where x.status in ('open', 'investigating')));
end;
$fn$;
revoke all on function public.credit_operations() from public, anon;
grant execute on function public.credit_operations() to authenticated;

-- -----------------------------------------------------------------------------
-- 10. The approved policy proposal, loaded ONLY into an untouched policy row, with credit OFF. Nothing here activates credit.
-- -----------------------------------------------------------------------------
do $$
declare v_n integer;
begin
  update public.credit_policy set min_completed_purchases = 3, min_approved_days = 60, purchase_window_days = 90, initial_credit_limit = 40, default_terms_days = 30,
         company_cap_percent = 25, cap_basis_months = 3, updated_at = now(), note = 'Approved proposal loaded by migration 25; credit remains OFF until an authorized administrator enables it'
   where id and enabled = false and min_completed_purchases is null and min_total_value is null and min_approved_days is null and max_outstanding is null
     and default_terms_days is null and purchase_window_days is null and initial_credit_limit is null and company_cap_percent is null and cap_basis_months is null;
  get diagnostics v_n = row_count;
  if v_n = 1 then
    insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
    values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'FINANCIAL', 'Credit policy proposal loaded by migration 25 (credit remains OFF)', null, 'migration 25', 'credit_policy',
            jsonb_build_object('source', 'db', 'event', 'credit_policy_proposal_loaded', 'minPurchases', 3, 'minApprovedDays', 60, 'purchaseWindowDays', 90, 'initialLimit', 40, 'termsDays', 30, 'capPercent', 25, 'capMonths', 3, 'enabled', false));
  end if;
end $$;

commit;
