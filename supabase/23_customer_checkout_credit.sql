-- =============================================================================
-- 23 - Customer checkout (verified payments), customer finance, customer credit (Phase: Android customer app)
-- -----------------------------------------------------------------------------
-- Adds, on top of migrations 21 and 22 and the existing EFZ order/financial model:
--   * payment_methods         what EFZ has actually configured for customers (NONE enabled by default; no provider is assumed)
--   * customer_checkouts      one row per checkout attempt: a SERVER-priced snapshot of the cart, the payment status, the resulting order
--   * payment_checkout_events one row per provider confirmation (idempotent by provider event id)
--   * credit_policy           the configurable eligibility rules (credit is OFF and every threshold is empty until EFZ decides them)
--   * customer_credit_accounts / customer_credit_orders   an authorized limit and terms per customer, and the terms recorded on each credit order
--
-- Principles
--   * No parallel ledger: orders, order_items and payments are the only financial records. Orders are created with the same shape create_order()
--     uses (list price snapshot, cost snapshot, stock rule, payment terms through the same transaction setting) and payments are plain rows in
--     public.payments, so every existing trigger, view, document, commission rule and audit line keeps working.
--   * create_order() and record_payment() are NOT modified. They are staff-only (permissions); the customer channel uses its own SECURITY DEFINER
--     functions that apply the same invariants.
--   * Prices, totals, stock and the customer come from the database, never from the app.
--   * A payment is real only when finalize_customer_checkout() is called by service_role (the server side that verified the provider's result).
--     Clients cannot call it. It is idempotent, checks the amount, re-prices, and on any problem parks the checkout as needs_review (never a
--     falsely paid order).
--   * Credit is never granted silently: a staff member (Super Admin) sets the limit and terms, and only for a customer who meets the policy
--     (or with a recorded override reason). Eligibility is re-checked on the server at every credit checkout.
--   * EVC (or any provider) PINs never touch EFZ: this file has no field for them.
--
-- Idempotent. Additive only. Rollback: rollback/23_customer_checkout_credit_rollback.sql
-- =============================================================================

begin;

set local lock_timeout = '30s';

-- -----------------------------------------------------------------------------
-- Payment methods (Super Admin maintains them; customers see only enabled ones)
-- -----------------------------------------------------------------------------
create table if not exists public.payment_methods (
  code        text primary key check (code ~ '^[a-z0-9_]{2,40}$'),
  label       text not null check (char_length(btrim(label)) between 2 and 60),
  kind        text not null check (kind in ('provider', 'staging_test')),
  enabled     boolean not null default false,
  sort_order  integer not null default 0,
  updated_by  text,
  updated_at  timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Checkouts and provider events
-- -----------------------------------------------------------------------------
create table if not exists public.customer_checkouts (
  id                uuid primary key default gen_random_uuid(),
  customer_id       text not null references public.customers(id),
  account_id        uuid not null references public.customer_accounts(id),
  submission_key    uuid not null,
  method_code       text not null,                      -- a payment_methods.code, or 'credit'
  status            text not null check (status in ('created', 'pending', 'paid', 'failed', 'cancelled', 'expired', 'reversed', 'needs_review', 'credit_placed', 'resolved')),
  lines             jsonb not null,                     -- the server-priced snapshot (productId, designId, names, quantity, unitPrice, lineTotal)
  amount            numeric(14,2) not null check (amount > 0),
  delivery_location text not null default '',
  notes             text not null default '',
  provider_ref      text,
  order_id          text references public.orders(id),
  failure_reason    text not null default '',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  verified_at       timestamptz,
  expires_at        timestamptz,
  unique (customer_id, submission_key)
);
create unique index if not exists customer_checkouts_provider_ref_key on public.customer_checkouts (method_code, provider_ref) where provider_ref is not null;
create index if not exists customer_checkouts_customer_idx on public.customer_checkouts (customer_id, created_at desc);
create index if not exists customer_checkouts_status_idx on public.customer_checkouts (status) where status in ('created', 'pending', 'needs_review', 'reversed');

create table if not exists public.payment_checkout_events (
  id                 bigserial primary key,
  checkout_id        uuid not null references public.customer_checkouts(id),
  method_code        text not null,
  provider_event_id  text not null check (char_length(provider_event_id) between 1 and 200),
  kind               text not null check (kind in ('pending', 'succeeded', 'failed', 'cancelled', 'expired', 'reversed')),
  amount             numeric(14,2),
  provider_ref       text,
  payload_hash       text,
  outcome            text not null default '',
  received_at        timestamptz not null default now(),
  unique (method_code, provider_event_id)
);

-- -----------------------------------------------------------------------------
-- Credit: policy (one row), authorized accounts, terms recorded per credit order
-- -----------------------------------------------------------------------------
create table if not exists public.credit_policy (
  id                           boolean primary key default true check (id),
  enabled                      boolean not null default false,
  min_completed_purchases      integer check (min_completed_purchases is null or min_completed_purchases >= 1),
  min_total_value              numeric(14,2) check (min_total_value is null or min_total_value > 0),
  require_no_unpaid_delivered  boolean not null default true,
  default_terms_days           integer check (default_terms_days is null or default_terms_days between 1 and 365),
  updated_by                   text,
  updated_at                   timestamptz not null default now(),
  note                         text not null default ''
);
insert into public.credit_policy (id) values (true) on conflict (id) do nothing;

create table if not exists public.customer_credit_accounts (
  customer_id   text primary key references public.customers(id),
  status        text not null check (status in ('approved', 'suspended')),
  credit_limit  numeric(14,2) not null check (credit_limit >= 0),
  terms_days    integer not null check (terms_days between 1 and 365),
  reason        text not null default '',
  override_used boolean not null default false,
  set_by        text,
  set_at        timestamptz not null default now()
);

create table if not exists public.customer_credit_orders (
  order_id             text primary key references public.orders(id),
  customer_id          text not null references public.customers(id),
  terms_days           integer not null check (terms_days between 1 and 365),
  due_date             date not null,
  credit_limit_at_time numeric(14,2) not null,
  created_at           timestamptz not null default now()
);

-- No client may touch these tables: every grant is revoked (Supabase grants new relations to authenticated by default) and RLS is on with no policy.
do $$
declare t text;
begin
  foreach t in array array['payment_methods', 'customer_checkouts', 'payment_checkout_events', 'credit_policy', 'customer_credit_accounts', 'customer_credit_orders'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);   -- the SECURITY DEFINER functions are the only door; not even service_role (and its default TRUNCATE) touches these tables directly
  end loop;
end $$;
revoke all on sequence public.payment_checkout_events_id_seq from public, anon, authenticated, service_role;

-- Checkouts, events and credit orders are append-or-advance records: nothing is ever deleted.
create or replace function public.guard_no_delete_finance()
returns trigger language plpgsql set search_path = public as $fn$
begin
  raise exception '% rows are never deleted', tg_table_name using errcode = '42501';
end;
$fn$;
drop trigger if exists trg_customer_checkouts_nodelete on public.customer_checkouts;
create trigger trg_customer_checkouts_nodelete before delete on public.customer_checkouts for each row execute function public.guard_no_delete_finance();
-- A provider event row keeps its facts forever; only the outcome label (what the event led to) is written once, after processing.
create or replace function public.guard_payment_event_update()
returns trigger language plpgsql set search_path = public as $fn$
begin
  if tg_op = 'DELETE' then raise exception 'payment events are never deleted' using errcode = '42501'; end if;
  if (new.checkout_id, new.method_code, new.provider_event_id, new.kind, new.amount, new.provider_ref, new.payload_hash, new.received_at)
     is distinct from (old.checkout_id, old.method_code, old.provider_event_id, old.kind, old.amount, old.provider_ref, old.payload_hash, old.received_at) then
    raise exception 'payment events cannot be changed' using errcode = '42501';
  end if;
  return new;
end;
$fn$;
drop trigger if exists trg_payment_events_nodelete on public.payment_checkout_events;
create trigger trg_payment_events_nodelete before delete or update on public.payment_checkout_events for each row execute function public.guard_payment_event_update();
drop trigger if exists trg_credit_orders_nodelete on public.customer_credit_orders;
create trigger trg_credit_orders_nodelete before delete or update on public.customer_credit_orders for each row execute function public.guard_no_delete_finance();

-- =============================================================================
-- Internal helpers (nobody can call them directly; SECURITY DEFINER callers use them)
-- =============================================================================

-- Server pricing of a cart: list price from products, active product/design only, whole quantities, stock net of what open orders promise.
create or replace function public._customer_price_cart(p_lines jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_line     jsonb;
  v_product  public.products%rowtype;
  v_design   public.product_designs%rowtype;
  v_design_id uuid;
  v_qty_raw  numeric;
  v_qty      integer;
  v_out      jsonb := '[]'::jsonb;
  v_total    numeric := 0;
  v_keys     text[] := '{}';
  v_key      text;
  r          record;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Your cart is empty' using errcode = '22023';
  end if;
  if jsonb_array_length(p_lines) > 20 then
    raise exception 'A checkout can have at most 20 lines' using errcode = '22023';
  end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    if jsonb_typeof(v_line) <> 'object' then raise exception 'Invalid line' using errcode = '22023'; end if;
    select * into v_product from public.products p where p.id = v_line ->> 'productId' and p.is_active;
    if not found then raise exception 'A selected product is not available' using errcode = '22023'; end if;
    begin v_qty_raw := (v_line ->> 'quantity')::numeric; exception when invalid_text_representation then v_qty_raw := null; end;
    if v_qty_raw is null or v_qty_raw <> trunc(v_qty_raw) or v_qty_raw not between 1 and 100000 then
      raise exception 'Quantity must be a whole number between 1 and 100000' using errcode = '22023';
    end if;
    v_qty := v_qty_raw::integer;
    v_design_id := null;
    begin v_design_id := nullif(v_line ->> 'designId', '')::uuid; exception when invalid_text_representation then
      raise exception 'Invalid design' using errcode = '22023'; end;
    if v_design_id is not null then
      select * into v_design from public.product_designs d where d.id = v_design_id and d.product_id = v_product.id and d.is_active;
      if not found then raise exception 'A selected design is not available for that product' using errcode = '22023'; end if;
    elsif exists (select 1 from public.product_designs d where d.product_id = v_product.id and d.is_active) then
      raise exception 'Choose a design for %', v_product.name using errcode = '22023';
    end if;
    v_key := v_product.id || '/' || coalesce(v_design_id::text, '');
    if v_key = any (v_keys) then raise exception 'Each product and design can be listed once; change its quantity instead' using errcode = '22023'; end if;
    v_keys := v_keys || v_key;
    if v_product.selling_price is null or v_product.selling_price <= 0 then
      raise exception '% has no price yet and cannot be bought online', v_product.name using errcode = '22023';
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'productId', v_product.id, 'productName', v_product.name,
      'designId', v_design_id, 'designName', case when v_design_id is null then '' else v_design.name end,
      'quantity', v_qty, 'unitPrice', v_product.selling_price, 'lineTotal', v_product.selling_price * v_qty));
    v_total := v_total + v_product.selling_price * v_qty;
  end loop;
  -- Designs of one product share its stock: check the per-product sum against what is free (stock minus open orders' promises).
  for r in select l ->> 'productId' as pid, sum((l ->> 'quantity')::integer) as q from jsonb_array_elements(v_out) l group by 1 loop
    select * into v_product from public.products p where p.id = r.pid;
    if v_product.stock - public.product_committed_quantity(r.pid) < r.q then
      raise exception 'Not enough stock for %: % available, % requested', v_product.name, greatest(v_product.stock - public.product_committed_quantity(r.pid), 0), r.q
        using errcode = '22023';
    end if;
  end loop;
  return jsonb_build_object('lines', v_out, 'total', v_total);
end;
$fn$;
revoke all on function public._customer_price_cart(jsonb) from public, anon, authenticated;

-- Creates the order exactly as create_order() shapes it (list price snapshot, cost snapshot, at_delivery stock, terms through the same setting).
create or replace function public._customer_create_order(p_customer_id text, p_priced jsonb, p_terms text, p_location text, p_notes text, p_actor_label text)
returns text
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_customer public.customers%rowtype;
  v_order_id text;
  v_line     jsonb;
  v_product  public.products%rowtype;
  v_seq      integer := 0;
  v_notes    text;
begin
  if p_terms not in ('paid_at_sale', 'credit') then raise exception 'Invalid payment terms' using errcode = '22023'; end if;
  select * into v_customer from public.customers c where c.id = p_customer_id;
  if not found then raise exception 'Unknown customer' using errcode = '22023'; end if;
  loop
    v_order_id := 'ORD-' || lpad((floor(random() * 9000000) + 1000000)::text, 7, '0');
    exit when not exists (select 1 from public.orders where id = v_order_id);
  end loop;
  v_notes := 'Placed in the customer app. Deliver to: ' || btrim(coalesce(p_location, ''))
             || case when btrim(coalesce(p_notes, '')) <> '' then ' - Notes: ' || btrim(p_notes) else '' end;
  perform set_config('efz.order_payment_terms', p_terms, true);
  insert into public.orders (id, customer_id, customer_name, phone, marketing_officer_id, status, order_type, order_date, delivery_notes, created_by, legacy_reference_id, stock_mode)
  values (v_order_id, v_customer.id, coalesce(v_customer.name, ''), coalesce(v_customer.phone, ''), v_customer.marketing_officer_id, 'pending', 'regular',
          public.efz_today(), v_notes, null, v_order_id, 'at_delivery');
  perform set_config('efz.order_payment_terms', '', true);
  for v_line in select * from jsonb_array_elements(p_priced -> 'lines') loop
    v_seq := v_seq + 1;
    select * into v_product from public.products p where p.id = v_line ->> 'productId' for update;
    insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost)
    values ('itm-' || replace(gen_random_uuid()::text, '-', '') || '-' || v_seq, v_order_id, v_product.id, v_product.name,
            coalesce(nullif(v_line ->> 'designName', ''), v_product.name), (v_line ->> 'quantity')::integer,
            v_product.selling_price, v_product.selling_price, v_product.cost_price);
  end loop;
  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  select 'log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'ORDER',
         format('New order created: %s for %s ($%s)', o.id, o.customer_name, o.total), null, p_actor_label, o.id,
         jsonb_build_object('source', 'db', 'event', 'order_created', 'channel', 'customer_app', 'terms', p_terms,
                            'total', o.total, 'items', v_seq, 'orderType', o.order_type, 'orderDate', o.order_date, 'marketingOfficerId', o.marketing_officer_id)
    from public.orders o where o.id = v_order_id;
  return v_order_id;
end;
$fn$;
revoke all on function public._customer_create_order(text, jsonb, text, text, text, text) from public, anon, authenticated;

-- A verified online payment as an ordinary payments row (the existing triggers recompute the order's balance and status).
create or replace function public._record_online_payment(p_order_id text, p_amount numeric, p_method_label text, p_reference text, p_actor_label text)
returns text
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_order public.orders%rowtype;
  v_id    text := 'pay-' || replace(gen_random_uuid()::text, '-', '');
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found or v_order.status = 'cancelled' then raise exception 'Order % cannot take a payment', p_order_id; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Payment amount must be greater than zero'; end if;
  if p_amount > v_order.outstanding_balance then raise exception 'Payment of % exceeds the outstanding balance of %', p_amount, v_order.outstanding_balance; end if;
  insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes, recorded_by)
  values (v_id, p_order_id, p_amount, public.efz_today(), coalesce(nullif(p_method_label, ''), 'Online'), coalesce(p_reference, ''), 'Online payment verified by the payment provider', null);
  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'FINANCIAL', format('Payment of $%s recorded against order %s', p_amount, p_order_id), null, p_actor_label, p_order_id,
          jsonb_build_object('source', 'db', 'event', 'payment_recorded', 'channel', 'customer_app_verified', 'paymentId', v_id, 'amount', p_amount,
                             'method', p_method_label, 'reference', coalesce(p_reference, '')));
  return v_id;
end;
$fn$;
revoke all on function public._record_online_payment(text, numeric, text, text, text) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Credit eligibility, from authoritative completed orders (delivered, fully paid, positive total, regular; never cancelled, trial or unpaid)
-- -----------------------------------------------------------------------------
create or replace function public._customer_credit_eligibility(p_customer_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  pol       public.credit_policy%rowtype;
  v_count   integer;
  v_value   numeric;
  v_unpaid  integer;
  v_reasons text[] := '{}';
begin
  select * into pol from public.credit_policy where id;
  select count(*), coalesce(sum(o.total), 0) into v_count, v_value
    from public.orders o
   where o.customer_id = p_customer_id and o.status = 'delivered' and o.order_type = 'regular' and o.total > 0 and o.amount_paid >= o.total;
  select count(*) into v_unpaid from public.orders o
   where o.customer_id = p_customer_id and o.status = 'delivered' and o.outstanding_balance > 0;
  if not pol.enabled then
    v_reasons := array_append(v_reasons, ('Credit purchasing is not active yet.')::text);
  else
    if pol.min_completed_purchases is not null and v_count < pol.min_completed_purchases then
      v_reasons := array_append(v_reasons, (format('%s more completed purchase(s) needed (%s of %s).', pol.min_completed_purchases - v_count, v_count, pol.min_completed_purchases))::text);
    end if;
    if pol.min_total_value is not null and v_value < pol.min_total_value then
      v_reasons := array_append(v_reasons, format('Completed purchases total $%s; $%s is required.', v_value, pol.min_total_value));
    end if;
    if pol.require_no_unpaid_delivered and v_unpaid > 0 then
      v_reasons := array_append(v_reasons, ('A delivered order still has an unpaid balance.')::text);
    end if;
    if pol.min_completed_purchases is null and pol.min_total_value is null then
      v_reasons := array_append(v_reasons, ('EFZ has not defined the purchase requirement yet.')::text);
    end if;
  end if;
  return jsonb_build_object(
    'eligible', pol.enabled and cardinality(v_reasons) = 0,
    'completedPurchases', v_count, 'completedValue', v_value, 'unpaidDeliveredOrders', v_unpaid,
    'requirements', jsonb_build_object('minCompletedPurchases', pol.min_completed_purchases, 'minTotalValue', pol.min_total_value, 'requireNoUnpaidDelivered', pol.require_no_unpaid_delivered),
    'reasons', to_jsonb(v_reasons));
end;
$fn$;
revoke all on function public._customer_credit_eligibility(text) from public, anon, authenticated;

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
  v_out       numeric;
  v_available numeric := 0;
  v_can       boolean;
begin
  select * into pol from public.credit_policy where id;
  select * into acc from public.customer_credit_accounts where customer_id = p_customer_id;
  select coalesce(sum(o.outstanding_balance), 0) into v_out from public.orders o where o.customer_id = p_customer_id and o.status <> 'cancelled';
  if acc.customer_id is not null then v_available := greatest(acc.credit_limit - v_out, 0); end if;
  v_can := pol.enabled and acc.customer_id is not null and acc.status = 'approved' and (v_elig ->> 'eligible')::boolean and v_available > 0;
  return jsonb_build_object(
    'policyEnabled', pol.enabled, 'eligibility', v_elig, 'canBuyOnCredit', coalesce(v_can, false),
    'account', case when acc.customer_id is null then null else jsonb_build_object('status', acc.status, 'creditLimit', acc.credit_limit, 'termsDays', acc.terms_days,
                                                                                     'outstanding', v_out, 'available', v_available) end,
    'message', case
      when not pol.enabled then 'Credit purchasing is not currently available.'
      when acc.customer_id is null and (v_elig ->> 'eligible')::boolean then 'You meet the requirements. EFZ will confirm your credit limit and terms.'
      when acc.customer_id is null then 'Credit purchasing is not available on your account yet.'
      when acc.status <> 'approved' then 'Credit purchasing is paused on your account. Please contact EFZ.'
      when not (v_elig ->> 'eligible')::boolean then 'Credit purchasing is not available on your account at the moment.'
      else 'You can buy on credit within your limit.' end);
end;
$fn$;
revoke all on function public._customer_credit_summary(text) from public, anon, authenticated;

-- =============================================================================
-- Customer functions (approved accounts only; each reads only the caller's own data)
-- =============================================================================

create or replace function public.customer_payment_methods()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_customer text := public.require_approved_customer();
  v_credit   jsonb := public._customer_credit_summary(v_customer);
begin
  return jsonb_build_object(
    'methods', coalesce((select jsonb_agg(jsonb_build_object('code', m.code, 'label', m.label, 'kind', m.kind) order by m.sort_order, m.code)
                           from public.payment_methods m where m.enabled), '[]'::jsonb),
    'credit', jsonb_build_object('available', (v_credit ->> 'canBuyOnCredit')::boolean, 'message', v_credit ->> 'message',
                                 'account', v_credit -> 'account'));
end;
$fn$;
revoke all on function public.customer_payment_methods() from public, anon;
grant execute on function public.customer_payment_methods() to authenticated;

create or replace function public.customer_credit_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  return public._customer_credit_summary(public.require_approved_customer());
end;
$fn$;
revoke all on function public.customer_credit_status() from public, anon;
grant execute on function public.customer_credit_status() to authenticated;

-- Read-only price check of a cart (the cart screen asks before checkout): server prices, availability, and the database's own refusal sentence.
create or replace function public.customer_price_preview(p_lines jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  perform public.require_approved_customer();
  return public._customer_price_cart(p_lines);
end;
$fn$;
revoke all on function public.customer_price_preview(jsonb) from public, anon;
grant execute on function public.customer_price_preview(jsonb) to authenticated;

-- Start a checkout: server-priced snapshot of the cart, no order and no payment yet. Idempotent by submissionKey.
create or replace function public.customer_start_checkout(p_payload jsonb)
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
  v_method   text := btrim(coalesce(p_payload ->> 'methodCode', ''));
  v_location text := btrim(coalesce(p_payload ->> 'deliveryLocation', ''));
  v_notes    text := btrim(coalesce(p_payload ->> 'notes', ''));
  v_existing public.customer_checkouts%rowtype;
  v_priced   jsonb;
  v_id       uuid;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then raise exception 'Invalid checkout' using errcode = '22023'; end if;
  begin v_key := (p_payload ->> 'submissionKey')::uuid; exception when others then v_key := null; end;
  if v_key is null then raise exception 'A submission key is required' using errcode = '22023'; end if;
  select id into v_acc from public.customer_accounts a where a.auth_user_id = auth.uid();
  perform pg_advisory_xact_lock(hashtext('checkout:' || v_customer));

  select * into v_existing from public.customer_checkouts c where c.customer_id = v_customer and c.submission_key = v_key;
  if found then
    return jsonb_build_object('checkoutId', v_existing.id, 'status', v_existing.status, 'amount', v_existing.amount, 'methodCode', v_existing.method_code,
                              'lines', v_existing.lines, 'orderId', v_existing.order_id, 'repeat', true);
  end if;

  if char_length(v_location) < 3 or char_length(v_location) > 300 then raise exception 'Enter a delivery location (3 to 300 characters)' using errcode = '22023'; end if;
  if char_length(v_notes) > 1000 then raise exception 'Notes are too long' using errcode = '22023'; end if;
  if not exists (select 1 from public.payment_methods m where m.code = v_method and m.enabled) then
    raise exception 'That payment method is not available' using errcode = '22023';
  end if;
  if (select count(*) from public.customer_checkouts c where c.customer_id = v_customer and c.created_at > now() - interval '24 hours') >= 30 then
    raise exception 'Too many checkouts today. Please try again later.' using errcode = 'WR429';
  end if;
  if (select count(*) from public.customer_checkouts c where c.customer_id = v_customer and c.status in ('created', 'pending')) >= 5 then
    raise exception 'You have several payments waiting. Finish or cancel them first.' using errcode = 'WR429';
  end if;

  v_priced := public._customer_price_cart(p_payload -> 'lines');
  insert into public.customer_checkouts (customer_id, account_id, submission_key, method_code, status, lines, amount, delivery_location, notes, expires_at)
  values (v_customer, v_acc, v_key, v_method, 'created', v_priced -> 'lines', (v_priced ->> 'total')::numeric, v_location, v_notes, now() + interval '30 minutes')
  returning id into v_id;
  return jsonb_build_object('checkoutId', v_id, 'status', 'created', 'amount', (v_priced ->> 'total')::numeric, 'methodCode', v_method, 'lines', v_priced -> 'lines', 'orderId', null, 'repeat', false);
end;
$fn$;
revoke all on function public.customer_start_checkout(jsonb) from public, anon;
grant execute on function public.customer_start_checkout(jsonb) to authenticated;

create or replace function public.my_checkout_status(p_checkout_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_customer text := public.require_approved_customer();
  c public.customer_checkouts%rowtype;
begin
  select * into c from public.customer_checkouts x where x.id = p_checkout_id and x.customer_id = v_customer;
  if not found then return null; end if;
  return jsonb_build_object('checkoutId', c.id, 'status', c.status, 'amount', c.amount, 'methodCode', c.method_code, 'orderId', c.order_id,
                            'message', case c.status
                              when 'paid' then 'Payment confirmed. Your order is placed.'
                              when 'credit_placed' then 'Your credit order is placed.'
                              when 'pending' then 'Waiting for the payment provider to confirm your payment.'
                              when 'created' then 'Payment not completed yet.'
                              when 'failed' then 'The payment did not go through. No order was placed and you were not charged by EFZ.'
                              when 'cancelled' then 'The payment was cancelled. No order was placed.'
                              when 'expired' then 'The payment window expired. No order was placed.'
                              when 'needs_review' then 'Your payment was received but EFZ must check your order. EFZ will contact you.'
                              when 'reversed' then 'This payment was reversed. EFZ will contact you.'
                              else 'Handled by EFZ.' end);
end;
$fn$;
revoke all on function public.my_checkout_status(uuid) from public, anon;
grant execute on function public.my_checkout_status(uuid) to authenticated;

create or replace function public.customer_cancel_checkout(p_checkout_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_customer text := public.require_approved_customer();
begin
  update public.customer_checkouts set status = 'cancelled', updated_at = now(), failure_reason = 'Cancelled by the customer before paying'
   where id = p_checkout_id and customer_id = v_customer and status = 'created';
end;
$fn$;
revoke all on function public.customer_cancel_checkout(uuid) from public, anon;
grant execute on function public.customer_cancel_checkout(uuid) to authenticated;

-- Buy on credit: only for an authorized credit account of a customer who still meets the policy, within the available limit. The order carries
-- payment_terms = credit and no payment; the terms and due date are recorded in customer_credit_orders.
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
  perform pg_advisory_xact_lock(hashtext('checkout:' || v_customer));

  select * into v_existing from public.customer_checkouts c where c.customer_id = v_customer and c.submission_key = v_key;
  if found then
    return jsonb_build_object('checkoutId', v_existing.id, 'status', v_existing.status, 'orderId', v_existing.order_id, 'amount', v_existing.amount, 'repeat', true);
  end if;

  if char_length(v_location) < 3 or char_length(v_location) > 300 then raise exception 'Enter a delivery location (3 to 300 characters)' using errcode = '22023'; end if;
  if char_length(v_notes) > 1000 then raise exception 'Notes are too long' using errcode = '22023'; end if;

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
  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'FINANCIAL',
          format('Credit order %s placed by the customer ($%s, limit $%s, %s days)', v_order, v_total, cr.credit_limit, cr.terms_days), null,
          'Customer app (' || coalesce(v_name, v_customer) || ')', v_order,
          jsonb_build_object('source', 'db', 'event', 'credit_order_placed', 'customerId', v_customer, 'total', v_total, 'limit', cr.credit_limit,
                             'termsDays', cr.terms_days, 'availableBefore', v_avail));
  return jsonb_build_object('checkoutId', v_id, 'status', 'credit_placed', 'orderId', v_order, 'amount', v_total, 'repeat', false);
end;
$fn$;
revoke all on function public.customer_place_credit_order(jsonb) from public, anon;
grant execute on function public.customer_place_credit_order(jsonb) to authenticated;

-- The customer's finance dashboard. Everything is computed from the customer's own non-cancelled orders and their payments.
create or replace function public.my_finance()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_customer text := public.require_approved_customer();
  v_today    date := public.efz_today();
begin
  return jsonb_build_object(
    'asOf', v_today,
    'summary', (select jsonb_build_object(
        'confirmedOrders', count(*), 'confirmedPurchases', coalesce(sum(o.total), 0), 'totalPaid', coalesce(sum(o.amount_paid), 0),
        'outstanding', coalesce(sum(o.outstanding_balance), 0),
        'unpaidInvoices', count(*) filter (where o.payment_terms = 'credit' and o.total > 0 and o.amount_paid = 0 and o.outstanding_balance > 0),
        'partialInvoices', count(*) filter (where o.payment_terms = 'credit' and o.total > 0 and o.amount_paid > 0 and o.outstanding_balance > 0),
        'paidInvoices', count(*) filter (where o.payment_terms = 'credit' and o.total > 0 and o.outstanding_balance = 0),
        'overdueInvoices', count(*) filter (where o.payment_terms = 'credit' and o.outstanding_balance > 0 and cc.due_date is not null and cc.due_date < v_today))
       from public.orders o left join public.customer_credit_orders cc on cc.order_id = o.id
      where o.customer_id = v_customer and o.status <> 'cancelled'),
    'pendingPayments', (select jsonb_build_object('count', count(*), 'amount', coalesce(sum(c.amount), 0))
                          from public.customer_checkouts c where c.customer_id = v_customer and c.status in ('created', 'pending')),
    'underReview', (select count(*) from public.customer_checkouts c where c.customer_id = v_customer and c.status in ('needs_review', 'reversed')),
    'invoices', coalesce((
      select jsonb_agg(jsonb_build_object(
               'number', 'INV-' || o.id, 'orderId', o.id, 'date', o.order_date, 'dueDate', cc.due_date, 'termsDays', cc.terms_days,
               'total', o.total, 'paid', o.amount_paid, 'outstanding', o.outstanding_balance,
               'status', case when o.outstanding_balance <= 0 then 'PAID' when o.amount_paid > 0 then 'PARTIALLY PAID' else 'UNPAID' end,
               'overdue', (o.outstanding_balance > 0 and cc.due_date is not null and cc.due_date < v_today),
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
revoke all on function public.my_finance() from public, anon;
grant execute on function public.my_finance() to authenticated;

-- =============================================================================
-- Provider verification (service_role only: the server that checked the provider's own result)
-- =============================================================================
create or replace function public.finalize_customer_checkout(
  p_checkout_id uuid, p_method_code text, p_provider_event_id text, p_kind text, p_amount numeric, p_provider_ref text, p_payload_hash text,
  p_allow_test boolean default false)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  c        public.customer_checkouts%rowtype;
  m        public.payment_methods%rowtype;
  v_ev     bigint;
  v_priced jsonb;
  v_in     jsonb;
  v_order  text;
  v_name   text;
  v_actor  text;
  v_msg    text;
begin
  select * into c from public.customer_checkouts where id = p_checkout_id for update;
  if not found then raise exception 'Unknown checkout' using errcode = '22023'; end if;
  if c.method_code = 'credit' then raise exception 'A credit checkout has no provider payment' using errcode = '22023'; end if;
  if c.method_code is distinct from p_method_code then raise exception 'The event is for a different payment method' using errcode = '22023'; end if;
  select * into m from public.payment_methods where code = p_method_code;
  if not found then raise exception 'Unknown payment method' using errcode = '22023'; end if;
  if m.kind = 'staging_test' and not coalesce(p_allow_test, false) then
    raise exception 'The test payment method may only be finalized by the Staging test function' using errcode = '42501';
  end if;
  if p_kind not in ('pending', 'succeeded', 'failed', 'cancelled', 'expired', 'reversed') then raise exception 'Unknown event kind' using errcode = '22023'; end if;

  insert into public.payment_checkout_events (checkout_id, method_code, provider_event_id, kind, amount, provider_ref, payload_hash)
  values (c.id, p_method_code, p_provider_event_id, p_kind, p_amount, p_provider_ref, p_payload_hash)
  on conflict (method_code, provider_event_id) do nothing returning id into v_ev;
  if v_ev is null then
    return jsonb_build_object('duplicate', true, 'status', c.status, 'orderId', c.order_id);
  end if;

  select name into v_name from public.customers where id = c.customer_id;
  v_actor := 'Customer app (' || coalesce(v_name, c.customer_id) || ')';

  if p_kind = 'pending' then
    if c.status = 'created' then update public.customer_checkouts set status = 'pending', updated_at = now() where id = c.id; c.status := 'pending'; end if;

  elsif p_kind in ('failed', 'cancelled', 'expired') then
    if c.status in ('created', 'pending') then
      update public.customer_checkouts set status = p_kind, updated_at = now(), failure_reason = 'Provider reported: ' || p_kind where id = c.id;
      c.status := p_kind;
    else
      insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
      values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'WARNING', 'FINANCIAL',
              format('A %s event arrived for checkout %s that is already %s; ignored', p_kind, c.id, c.status), null, v_actor, c.order_id,
              jsonb_build_object('source', 'db', 'event', 'late_payment_event_ignored', 'checkoutId', c.id, 'kind', p_kind, 'status', c.status));
    end if;

  elsif p_kind = 'succeeded' then
    if c.status in ('paid', 'credit_placed') then
      null;   -- already settled; the event is recorded and nothing else changes
    elsif p_amount is distinct from c.amount then
      update public.customer_checkouts set status = 'needs_review', updated_at = now(),
             failure_reason = format('Provider confirmed %s but the checkout is for %s', p_amount, c.amount) where id = c.id;
      c.status := 'needs_review';
    else
      begin
        select coalesce(jsonb_agg(jsonb_build_object('productId', l ->> 'productId', 'designId', l ->> 'designId', 'quantity', (l ->> 'quantity')::integer)), '[]'::jsonb)
          into v_in from jsonb_array_elements(c.lines) l;
        v_priced := public._customer_price_cart(v_in);
        if (v_priced ->> 'total')::numeric <> c.amount then
          raise exception 'Prices changed since checkout (now %, checkout %)', v_priced ->> 'total', c.amount;
        end if;
        v_order := public._customer_create_order(c.customer_id, v_priced, 'paid_at_sale', c.delivery_location, c.notes, v_actor);
        perform public._record_online_payment(v_order, c.amount, m.label, p_provider_ref, v_actor);
        update public.customer_checkouts set status = 'paid', order_id = v_order, provider_ref = p_provider_ref, verified_at = now(), updated_at = now(), failure_reason = '' where id = c.id;
        c.status := 'paid'; c.order_id := v_order;
      exception when others then
        v_msg := left(sqlerrm, 300);
        update public.customer_checkouts set status = 'needs_review', updated_at = now(), failure_reason = v_msg where id = c.id;   -- the provider reference stays on the event row
        c.status := 'needs_review';
      end;
    end if;
    if c.status = 'needs_review' then
      insert into public.notifications (id, title, message, type, user_id)
      values ('ntf-' || replace(gen_random_uuid()::text, '-', ''), 'Customer payment needs review',
              format('A verified payment of $%s for checkout %s could not be turned into an order. Check Credit & Payments.', c.amount, c.id), 'system', null);
      insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
      values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'CRITICAL', 'FINANCIAL',
              format('Verified payment of $%s for checkout %s needs review: %s', c.amount, c.id, coalesce(v_msg, 'amount differs')), null, v_actor, c.id::text,
              jsonb_build_object('source', 'db', 'event', 'checkout_needs_review', 'checkoutId', c.id, 'customerId', c.customer_id, 'amount', c.amount, 'providerRef', p_provider_ref));
    end if;

  elsif p_kind = 'reversed' then
    update public.customer_checkouts set status = 'reversed', updated_at = now(), failure_reason = 'Provider reported a reversal' where id = c.id;
    c.status := 'reversed';
    insert into public.notifications (id, title, message, type, user_id)
    values ('ntf-' || replace(gen_random_uuid()::text, '-', ''), 'Customer payment reversed',
            format('The provider reversed a payment of $%s (checkout %s, order %s). Handle the order and the books manually.', c.amount, c.id, coalesce(c.order_id, 'none')), 'system', null);
    insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
    values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'CRITICAL', 'FINANCIAL',
            format('Payment reversal reported for checkout %s (order %s); financial records are NOT changed automatically', c.id, coalesce(c.order_id, 'none')), null, v_actor, coalesce(c.order_id, c.id::text),
            jsonb_build_object('source', 'db', 'event', 'payment_reversed', 'checkoutId', c.id, 'orderId', c.order_id, 'amount', c.amount));
  end if;

  update public.payment_checkout_events set outcome = c.status where id = v_ev;
  return jsonb_build_object('duplicate', false, 'status', c.status, 'orderId', c.order_id);
end;
$fn$;
revoke all on function public.finalize_customer_checkout(uuid, text, text, text, numeric, text, text, boolean) from public, anon, authenticated;
grant execute on function public.finalize_customer_checkout(uuid, text, text, text, numeric, text, text, boolean) to service_role;

-- Provider plumbing (service_role only): what the server needs in order to talk to a payment provider about ONE checkout. None of this is
-- readable or callable by a customer, a staff user or anonymous; the provider result still becomes real only through finalize_customer_checkout().
create or replace function public.checkout_for_provider(p_checkout_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  c public.customer_checkouts%rowtype;
  m public.payment_methods%rowtype;
begin
  select * into c from public.customer_checkouts where id = p_checkout_id;
  if not found then return null; end if;
  select * into m from public.payment_methods where code = c.method_code;
  return jsonb_build_object('checkoutId', c.id, 'customerId', c.customer_id, 'methodCode', c.method_code, 'methodKind', m.kind, 'methodEnabled', coalesce(m.enabled, false),
                            'status', c.status, 'amount', c.amount, 'currency', 'USD', 'orderId', c.order_id, 'providerRef', c.provider_ref, 'createdAt', c.created_at);
end;
$fn$;
revoke all on function public.checkout_for_provider(uuid) from public, anon, authenticated;
grant execute on function public.checkout_for_provider(uuid) to service_role;

-- Records the provider's own reference for a checkout (an invoice id, an order id) and marks the checkout as waiting for the provider.
-- Only an unpaid, unsettled checkout of an ENABLED provider method can take a reference, and only one reference ever.
create or replace function public.set_checkout_provider_ref(p_checkout_id uuid, p_method_code text, p_ref text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  c public.customer_checkouts%rowtype;
  m public.payment_methods%rowtype;
begin
  if p_ref is null or char_length(btrim(p_ref)) not between 1 and 200 then raise exception 'A provider reference is required' using errcode = '22023'; end if;
  select * into c from public.customer_checkouts where id = p_checkout_id for update;
  if not found or c.method_code is distinct from p_method_code then raise exception 'Unknown checkout for that method' using errcode = '22023'; end if;
  select * into m from public.payment_methods where code = p_method_code;
  if not found or not m.enabled or m.kind <> 'provider' then raise exception 'That payment method is not an enabled provider method' using errcode = '22023'; end if;
  if c.status not in ('created', 'pending') then raise exception 'The checkout is already %', c.status using errcode = '22023'; end if;
  if c.provider_ref is not null and c.provider_ref <> p_ref then raise exception 'The checkout already has a different provider reference' using errcode = '22023'; end if;
  update public.customer_checkouts set provider_ref = p_ref, status = 'pending', updated_at = now() where id = c.id;
  insert into public.payment_checkout_events (checkout_id, method_code, provider_event_id, kind, amount, provider_ref, payload_hash, outcome)
  values (c.id, p_method_code, 'start:' || p_ref, 'pending', null, p_ref, null, 'pending') on conflict (method_code, provider_event_id) do nothing;
end;
$fn$;
revoke all on function public.set_checkout_provider_ref(uuid, text, text) from public, anon, authenticated;
grant execute on function public.set_checkout_provider_ref(uuid, text, text) to service_role;

-- The checkouts a reconciliation job should ask the provider about: waiting on a provider for at least p_older_than_seconds.
create or replace function public.checkouts_to_reconcile(p_older_than_seconds integer default 30, p_limit integer default 50)
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object('checkoutId', x.id, 'methodCode', x.method_code, 'providerRef', x.provider_ref, 'amount', x.amount) order by x.updated_at), '[]'::jsonb)
    from (select c.id, c.method_code, c.provider_ref, c.amount, c.updated_at from public.customer_checkouts c
           where c.status = 'pending' and c.provider_ref is not null and c.updated_at <= now() - make_interval(secs => greatest(coalesce(p_older_than_seconds, 30), 0))
           order by c.updated_at limit least(greatest(coalesce(p_limit, 50), 1), 200)) x;
$fn$;
revoke all on function public.checkouts_to_reconcile(integer, integer) from public, anon, authenticated;
grant execute on function public.checkouts_to_reconcile(integer, integer) to service_role;

-- Checkouts that were never paid are closed after their window (service_role, run on a schedule or by hand).
create or replace function public.expire_stale_checkouts()
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare v_n integer;
begin
  update public.customer_checkouts set status = 'expired', updated_at = now(), failure_reason = 'The payment window expired'
   where status in ('created', 'pending') and expires_at is not null and expires_at < now();
  get diagnostics v_n = row_count;
  return v_n;
end;
$fn$;
revoke all on function public.expire_stale_checkouts() from public, anon, authenticated;
grant execute on function public.expire_stale_checkouts() to service_role;

-- =============================================================================
-- Staff functions (Super Admin only; every change is audited)
-- =============================================================================
create or replace function public._require_finance_admin()
returns void
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not public.is_super_admin() then
    raise exception 'Only a Super Admin can manage customer payments and credit' using errcode = '42501';
  end if;
end;
$fn$;
revoke all on function public._require_finance_admin() from public, anon, authenticated;

create or replace function public.finance_audit(p_message text, p_target text, p_meta jsonb)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare v_actor text := public.current_profile_id();
begin
  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'FINANCIAL', p_message, v_actor, coalesce(public.current_profile_name(), ''), p_target,
          coalesce(p_meta, '{}'::jsonb) || jsonb_build_object('source', 'db'));
end;
$fn$;
revoke all on function public.finance_audit(text, text, jsonb) from public, anon, authenticated;

create or replace function public.list_payment_methods()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  perform public._require_finance_admin();
  return coalesce((select jsonb_agg(to_jsonb(m) order by m.sort_order, m.code) from public.payment_methods m), '[]'::jsonb);
end;
$fn$;
revoke all on function public.list_payment_methods() from public, anon;
grant execute on function public.list_payment_methods() to authenticated;

create or replace function public.set_payment_method(p_code text, p_label text, p_kind text, p_enabled boolean, p_reason text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare v_before jsonb;
begin
  perform public._require_finance_admin();
  if p_reason is null or char_length(btrim(p_reason)) < 5 then raise exception 'Give a reason (at least 5 characters)' using errcode = '22023'; end if;
  select to_jsonb(m) into v_before from public.payment_methods m where m.code = p_code;
  insert into public.payment_methods (code, label, kind, enabled, updated_by, updated_at)
  values (p_code, p_label, p_kind, coalesce(p_enabled, false), public.current_profile_id(), now())
  on conflict (code) do update set label = excluded.label, kind = excluded.kind, enabled = excluded.enabled, updated_by = excluded.updated_by, updated_at = now();
  perform public.finance_audit(format('Payment method %s %s', p_code, case when p_enabled then 'enabled' else 'disabled' end), p_code,
    jsonb_build_object('event', 'payment_method_set', 'before', v_before, 'label', p_label, 'kind', p_kind, 'enabled', p_enabled, 'reason', btrim(p_reason)));
end;
$fn$;
revoke all on function public.set_payment_method(text, text, text, boolean, text) from public, anon;
grant execute on function public.set_payment_method(text, text, text, boolean, text) to authenticated;

create or replace function public.get_credit_policy()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  perform public._require_finance_admin();
  return (select to_jsonb(p) from public.credit_policy p where p.id);
end;
$fn$;
revoke all on function public.get_credit_policy() from public, anon;
grant execute on function public.get_credit_policy() to authenticated;

create or replace function public.set_credit_policy(p_enabled boolean, p_min_purchases integer, p_min_value numeric, p_require_no_unpaid boolean, p_default_terms_days integer, p_reason text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare v_before jsonb;
begin
  perform public._require_finance_admin();
  if p_reason is null or char_length(btrim(p_reason)) < 5 then raise exception 'Give a reason (at least 5 characters)' using errcode = '22023'; end if;
  if p_enabled and p_min_purchases is null and p_min_value is null then
    raise exception 'Define at least one purchase requirement (a number of completed purchases or a total value) before credit can be enabled' using errcode = '22023';
  end if;
  if p_enabled and p_default_terms_days is null then
    raise exception 'Define the default repayment period before credit can be enabled' using errcode = '22023';
  end if;
  select to_jsonb(p) into v_before from public.credit_policy p where p.id;
  update public.credit_policy set enabled = coalesce(p_enabled, false), min_completed_purchases = p_min_purchases, min_total_value = p_min_value,
         require_no_unpaid_delivered = coalesce(p_require_no_unpaid, true), default_terms_days = p_default_terms_days,
         updated_by = public.current_profile_id(), updated_at = now(), note = btrim(p_reason) where id;
  perform public.finance_audit(format('Credit policy %s', case when p_enabled then 'enabled' else 'saved (credit off)' end), 'credit_policy',
    jsonb_build_object('event', 'credit_policy_set', 'before', v_before, 'enabled', p_enabled, 'minPurchases', p_min_purchases, 'minValue', p_min_value,
                       'requireNoUnpaid', p_require_no_unpaid, 'defaultTermsDays', p_default_terms_days, 'reason', btrim(p_reason)));
end;
$fn$;
revoke all on function public.set_credit_policy(boolean, integer, numeric, boolean, integer, text) from public, anon;
grant execute on function public.set_credit_policy(boolean, integer, numeric, boolean, integer, text) to authenticated;

create or replace function public.credit_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  perform public._require_finance_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'customerId', c.id, 'name', c.name, 'eligibility', public._customer_credit_eligibility(c.id),
             'outstanding', (select coalesce(sum(o.outstanding_balance), 0) from public.orders o where o.customer_id = c.id and o.status <> 'cancelled'),
             'account', (select to_jsonb(a) - 'set_by' from public.customer_credit_accounts a where a.customer_id = c.id))
           order by c.name, c.id)
      from public.customers c
     where exists (select 1 from public.customer_accounts ca where ca.customer_id = c.id and ca.status = 'approved')), '[]'::jsonb);
end;
$fn$;
revoke all on function public.credit_overview() from public, anon;
grant execute on function public.credit_overview() to authenticated;

create or replace function public.set_customer_credit(p_customer_id text, p_limit numeric, p_terms_days integer, p_reason text, p_override_reason text default null)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  pol      public.credit_policy%rowtype;
  v_elig   jsonb;
  v_before jsonb;
  v_over   text := nullif(btrim(coalesce(p_override_reason, '')), '');
begin
  perform public._require_finance_admin();
  select * into pol from public.credit_policy where id;
  if not pol.enabled then raise exception 'Credit purchasing is not enabled in the credit policy' using errcode = '22023'; end if;
  if not exists (select 1 from public.customer_accounts a where a.customer_id = p_customer_id and a.status = 'approved' and a.deletion_requested_at is null) then
    raise exception 'The customer has no approved app account' using errcode = '22023';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) < 5 then raise exception 'Give a reason (at least 5 characters)' using errcode = '22023'; end if;
  if p_limit is null or p_limit < 0 or p_limit > 1000000 or p_limit <> round(p_limit, 2) then raise exception 'The credit limit must be between 0 and 1,000,000, in whole cents' using errcode = '22023'; end if;
  if p_terms_days is null or p_terms_days not between 1 and 365 then raise exception 'The repayment period must be 1 to 365 days' using errcode = '22023'; end if;
  v_elig := public._customer_credit_eligibility(p_customer_id);
  if not (v_elig ->> 'eligible')::boolean and (v_over is null or char_length(v_over) < 10) then
    raise exception 'The customer does not meet the credit policy (%). A recorded override reason of at least 10 characters is required.', v_elig -> 'reasons' using errcode = '22023';
  end if;
  select to_jsonb(a) into v_before from public.customer_credit_accounts a where a.customer_id = p_customer_id;
  insert into public.customer_credit_accounts (customer_id, status, credit_limit, terms_days, reason, override_used, set_by, set_at)
  values (p_customer_id, 'approved', p_limit, p_terms_days, btrim(p_reason), not (v_elig ->> 'eligible')::boolean, public.current_profile_id(), now())
  on conflict (customer_id) do update set status = 'approved', credit_limit = excluded.credit_limit, terms_days = excluded.terms_days, reason = excluded.reason,
         override_used = excluded.override_used, set_by = excluded.set_by, set_at = now();
  perform public.finance_audit(format('Credit limit of $%s (%s days) set for customer %s', p_limit, p_terms_days, p_customer_id), p_customer_id,
    jsonb_build_object('event', 'customer_credit_set', 'before', v_before, 'limit', p_limit, 'termsDays', p_terms_days, 'reason', btrim(p_reason),
                       'eligibility', v_elig, 'overrideReason', v_over));
end;
$fn$;
revoke all on function public.set_customer_credit(text, numeric, integer, text, text) from public, anon;
grant execute on function public.set_customer_credit(text, numeric, integer, text, text) to authenticated;

create or replace function public.suspend_customer_credit(p_customer_id text, p_reason text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
begin
  perform public._require_finance_admin();
  if p_reason is null or char_length(btrim(p_reason)) < 5 then raise exception 'Give a reason (at least 5 characters)' using errcode = '22023'; end if;
  update public.customer_credit_accounts set status = 'suspended', reason = btrim(p_reason), set_by = public.current_profile_id(), set_at = now() where customer_id = p_customer_id and status = 'approved';
  if not found then raise exception 'The customer has no active credit account' using errcode = '22023'; end if;
  perform public.finance_audit(format('Credit suspended for customer %s', p_customer_id), p_customer_id, jsonb_build_object('event', 'customer_credit_suspended', 'reason', btrim(p_reason)));
end;
$fn$;
revoke all on function public.suspend_customer_credit(text, text) from public, anon;
grant execute on function public.suspend_customer_credit(text, text) to authenticated;

create or replace function public.list_checkouts_for_review()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  perform public._require_finance_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'customerId', c.customer_id, 'customerName', (select name from public.customers where id = c.customer_id),
                                                       'status', c.status, 'amount', c.amount, 'method', c.method_code, 'providerRef', c.provider_ref, 'orderId', c.order_id,
                                                       'reason', c.failure_reason, 'createdAt', c.created_at, 'lines', c.lines) order by c.created_at desc)
                     from public.customer_checkouts c where c.status in ('needs_review', 'reversed')), '[]'::jsonb);
end;
$fn$;
revoke all on function public.list_checkouts_for_review() from public, anon;
grant execute on function public.list_checkouts_for_review() to authenticated;

create or replace function public.resolve_customer_checkout(p_checkout_id uuid, p_note text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
begin
  perform public._require_finance_admin();
  if p_note is null or char_length(btrim(p_note)) < 10 then raise exception 'Describe how it was resolved (at least 10 characters)' using errcode = '22023'; end if;
  update public.customer_checkouts set status = 'resolved', updated_at = now(), failure_reason = left(failure_reason || ' | Resolved: ' || btrim(p_note), 600)
   where id = p_checkout_id and status in ('needs_review', 'reversed');
  if not found then raise exception 'Only a checkout waiting for review can be resolved' using errcode = '22023'; end if;
  perform public.finance_audit(format('Checkout %s resolved by staff', p_checkout_id), p_checkout_id::text, jsonb_build_object('event', 'checkout_resolved', 'note', btrim(p_note)));
end;
$fn$;
revoke all on function public.resolve_customer_checkout(uuid, text) from public, anon;
grant execute on function public.resolve_customer_checkout(uuid, text) to authenticated;

commit;
