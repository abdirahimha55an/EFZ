-- =============================================================================
-- 20 - Explicit payment terms on orders (Phase 14d, invoices and receipts)
-- -----------------------------------------------------------------------------
-- Every NEW order records how it was sold:
--   'paid_at_sale'  immediate payment at the time of sale  -> receipts only
--   'credit'        the customer may pay later              -> invoice + receipts
-- Existing orders keep NULL ("not recorded") until reviewed; nothing is inferred
-- or written for them here (see checks/20_payment_terms_backfill_PREVIEW.sql).
--
-- Rules enforced by the database:
--   * Once set, payment_terms never changes (payments, backdating, balance or
--     total changes cannot touch it).
--   * Signed-in clients can never write payment_terms directly (not even NULL ->
--     value). Only these SECURITY DEFINER functions set it:
--       create_order_with_terms(payload, terms)  - create_order() + terms + the
--         initial payment, atomic; paid_at_sale must be fully paid at creation
--       set_order_payment_terms(order, terms, reason) - Super Admin review of a
--         NULL (legacy / converted) order; audited.
--   * create_order() itself is NOT modified. Orders it creates without the wrapper
--     (the website-request conversions) get NULL terms, i.e. "for review".
--   * Read access: view order_payment_terms, same visibility rule as order_details
--     (can_see_customer_order). orders stays without client SELECT.
--
-- Idempotent. Additive only (one nullable column, functions, triggers, a view).
-- Rollback: rollback/20_order_payment_terms_rollback.sql
-- =============================================================================

begin;

set local lock_timeout = '30s';

alter table public.orders add column if not exists payment_terms text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'orders_payment_terms_check' and conrelid = 'public.orders'::regclass) then
    alter table public.orders add constraint orders_payment_terms_check
      check (payment_terms is null or payment_terms in ('paid_at_sale', 'credit'));
  end if;
end $$;

comment on column public.orders.payment_terms is
  'paid_at_sale | credit, fixed when the order is created (create_order_with_terms) or once by Super Admin review (set_order_payment_terms). NULL = not recorded (legacy, awaiting review).';

-- -----------------------------------------------------------------------------
-- Insert: clients cannot choose terms; server code passes them through a
-- transaction-local setting read here (set only by create_order_with_terms).
-- -----------------------------------------------------------------------------
create or replace function public.orders_payment_terms_on_insert()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if public.is_client_request() then
    new.payment_terms := null;
  else
    new.payment_terms := coalesce(new.payment_terms, nullif(current_setting('efz.order_payment_terms', true), ''));
  end if;
  return new;
end;
$$;

drop trigger if exists trg_orders_payment_terms_ins on public.orders;
create trigger trg_orders_payment_terms_ins
  before insert on public.orders
  for each row execute function public.orders_payment_terms_on_insert();

-- -----------------------------------------------------------------------------
-- Update: fixed once set; never writable by a client.
-- -----------------------------------------------------------------------------
create or replace function public.guard_order_payment_terms()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if new.payment_terms is distinct from old.payment_terms then
    if public.is_client_request() then
      raise exception 'Payment terms are set when the order is created; they cannot be written directly'
        using errcode = '42501';
    end if;
    if old.payment_terms is not null then
      raise exception 'Payment terms of order % are fixed (%) and cannot be changed', old.id, old.payment_terms
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_orders_payment_terms_fixed on public.orders;
create trigger trg_orders_payment_terms_fixed
  before update of payment_terms on public.orders
  for each row execute function public.guard_order_payment_terms();

-- -----------------------------------------------------------------------------
-- New orders: create_order() + terms + the initial payment in one transaction.
--   payload.initialPayment  amount received now (default 0), at most 2 decimals
--   payload.paymentMethod   method for that payment (default Cash)
-- Checked against the order total that create_order() computed:
--   paid_at_sale  initialPayment = total (fully paid at creation)
--   credit        initialPayment < total (partly or wholly unpaid); 0 for a $0 order
-- Any violation raises before record_payment() is called, and the raise rolls
-- back the whole transaction, so no order, line, log or payment remains.
-- -----------------------------------------------------------------------------
create or replace function public.create_order_with_terms(payload jsonb, p_payment_terms text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_order_id text;
  v_paid     numeric;
  v_total    numeric;
begin
  if p_payment_terms is null or p_payment_terms not in ('paid_at_sale', 'credit') then
    raise exception 'Choose the payment terms: paid_at_sale or credit' using errcode = '22023';
  end if;

  if payload is null or jsonb_typeof(payload) <> 'object' then
    raise exception 'Order payload must be an object' using errcode = '22023';
  end if;
  if payload ? 'initialPayment' and jsonb_typeof(payload -> 'initialPayment') not in ('number', 'null') then
    raise exception 'initialPayment must be a number' using errcode = '22023';
  end if;
  v_paid := coalesce((payload ->> 'initialPayment')::numeric, 0);
  if v_paid < 0 or v_paid <> round(v_paid, 2) then
    raise exception 'The initial payment must be zero or more, in whole cents (got %)', v_paid using errcode = '22023';
  end if;

  -- create_order() checks create_orders and everything else, exactly as before.
  perform set_config('efz.order_payment_terms', p_payment_terms, true);
  v_order_id := public.create_order(payload - 'initialPayment' - 'paymentMethod');
  perform set_config('efz.order_payment_terms', '', true);

  select o.total into v_total from public.orders o where o.id = v_order_id;
  if (select o.payment_terms from public.orders o where o.id = v_order_id) is distinct from p_payment_terms then
    raise exception 'Payment terms were not recorded on order %', v_order_id;
  end if;

  if p_payment_terms = 'paid_at_sale' and v_paid <> v_total then
    raise exception 'Paid at sale means the full order total (%) is paid now; the initial payment is %. Enter the total, or choose credit.', v_total, v_paid
      using errcode = '22023';
  end if;
  if p_payment_terms = 'credit' and v_total > 0 and v_paid >= v_total then
    raise exception 'The full order total (%) is being paid now, so this is a paid_at_sale order, not credit.', v_total
      using errcode = '22023';
  end if;
  if p_payment_terms = 'credit' and v_total = 0 and v_paid > 0 then
    raise exception 'The order total is 0; no initial payment can be recorded' using errcode = '22023';
  end if;

  -- record_payment() keeps its own checks (permission, order access, overpayment)
  -- and its audit line; dated today (Mogadishu), as the app did before.
  if v_paid > 0 then
    perform public.record_payment(
      p_order_id  => v_order_id,
      p_amount    => v_paid,
      p_method    => coalesce(nullif(payload ->> 'paymentMethod', ''), 'Cash'),
      p_notes     => 'Initial payment');
  end if;

  if p_payment_terms = 'paid_at_sale'
     and (select o.outstanding_balance from public.orders o where o.id = v_order_id) <> 0 then
    raise exception 'Order % would be left with a balance although paid at sale', v_order_id;
  end if;
  return v_order_id;
end;
$$;

revoke all on function public.create_order_with_terms(jsonb, text) from public, anon;
grant execute on function public.create_order_with_terms(jsonb, text) to authenticated;

-- -----------------------------------------------------------------------------
-- Review of an order without terms (legacy / converted): Super Admin, once, audited.
-- -----------------------------------------------------------------------------
create or replace function public.set_order_payment_terms(p_order_id text, p_payment_terms text, p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_actor      text := public.current_profile_id();
  v_actor_name text;
begin
  if not public.is_super_admin() then
    raise exception 'Only a Super Admin can record payment terms on an existing order' using errcode = '42501';
  end if;
  if p_payment_terms is null or p_payment_terms not in ('paid_at_sale', 'credit') then
    raise exception 'Payment terms must be paid_at_sale or credit' using errcode = '22023';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) < 5 then
    raise exception 'Give the evidence for these payment terms (at least 5 characters)' using errcode = '22023';
  end if;

  update public.orders set payment_terms = p_payment_terms
   where id = p_order_id and payment_terms is null;
  if not found then
    raise exception 'Order % does not exist or already has payment terms', p_order_id;
  end if;

  select p.name into v_actor_name from public.profiles p where p.id = v_actor;
  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values (
    'log-' || replace(gen_random_uuid()::text, '-', ''),
    'INFO', 'FINANCIAL',
    format('Payment terms of order %s recorded as %s after review', p_order_id, p_payment_terms),
    v_actor, coalesce(v_actor_name, ''), p_order_id,
    jsonb_build_object('source', 'db', 'event', 'payment_terms_reviewed', 'terms', p_payment_terms, 'reason', btrim(p_reason))
  );
end;
$$;

revoke all on function public.set_order_payment_terms(text, text, text) from public, anon;
grant execute on function public.set_order_payment_terms(text, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- Read: same rows a caller sees in order_details.
-- -----------------------------------------------------------------------------
create or replace view public.order_payment_terms
with (security_invoker = false, security_barrier = true) as
select o.id, o.payment_terms
  from public.orders o
 where public.can_see_customer_order(o.customer_id, o.marketing_officer_id);

-- authenticated must be revoked too: Supabase default privileges grant it ALL on
-- new relations, and this one-table view is auto-updatable as its owner, so an
-- INSERT/UPDATE/DELETE through it would bypass create_order() and orders RLS.
revoke all on public.order_payment_terms from public, anon, authenticated;
grant select on public.order_payment_terms to authenticated;

commit;
