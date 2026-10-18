-- =============================================================================
-- 26 - Customer price agreements (negotiated prices for existing customers). Follows migration 25. NOT APPLIED to any database until the owner approves it.
-- -----------------------------------------------------------------------------
-- EFZ's customers negotiated prices before the app existed. Today a negotiated price lives only on individual order lines (order_items.actual_unit_price, set by staff
-- in create_order, with the list price kept in standard_unit_price). The customer app, however, always charged the list price. This migration lets the app honour the
-- agreements WITHOUT a second pricing system:
--   * customer_price_agreements: a verified, dated price for one customer and one product (optionally one design). Active, pending_review (an unverified
--     candidate, for example imported from order history), revoked or rejected. Overlapping agreements for the same key cannot exist. Every change is an event.
--   * _price_resolve(): the ONE place a price is decided: the active design agreement, else the active product agreement, else the list price. A pending or
--     conflicting agreement, or an agreed price below the current cost that nobody approved, makes that line "needs review": it cannot be bought online until an
--     authorized person confirms it. An established customer's price is never silently replaced by the list price.
--   * the customer app's pricing (preview, checkout, credit order, payment confirmation) all call it with the customer's own id; the client sends no price.
--   * order lines keep the list price and the price charged as before (a frozen snapshot), and order_price_resolutions records which agreement produced each
--     line. Changing or ending an agreement never touches an existing order, invoice, payment or revenue figure.
--   * authorized staff (Super Admin or Manager, as can_manage_pricing) create, verify, reject, revoke and end agreements; below-cost prices need a Super Admin and a
--     reason, exactly as create_order requires. import_price_candidates() reads the order history, reports what it found and, only when asked, records
--     consistent negotiated prices as PENDING candidates; anything ambiguous is reported for manual confirmation and nothing is invented.
--   * customers see only their own price (catalogue, designs, my_price_agreements); never another customer's agreement, nor cost or margin.
-- Redefines: _customer_create_order, customer_price_preview, customer_start_checkout, finalize_customer_checkout, customer_place_credit_order, customer_catalog,
--   customer_designs; replaces _customer_price_cart(jsonb) with _customer_price_cart(jsonb, text). create_order, record_payment and every view are untouched.
-- Rollback: rollback/26_customer_price_agreements_rollback.sql.
-- =============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
begin
  if to_regprocedure('public.credit_company_cap()') is null or to_regprocedure('public._customer_price_cart(jsonb)') is null or to_regprocedure('public.can_manage_pricing()') is null then
    raise exception 'Migration 26 cannot run: migration 25 (and the earlier migrations) must be applied first';
  end if;
end
$pre$;

-- -----------------------------------------------------------------------------
-- 1. Tables
-- -----------------------------------------------------------------------------
create table if not exists public.customer_price_agreements (
  id                   uuid primary key default gen_random_uuid(),
  customer_id          text not null references public.customers(id),
  product_id           text not null references public.products(id),
  design_id            uuid references public.product_designs(id),
  unit_price           numeric(12,2) not null check (unit_price > 0),
  effective_from       date not null,
  effective_to         date,
  status               text not null check (status in ('pending_review', 'active', 'revoked', 'rejected')),
  source               text not null check (source in ('manual', 'import')),
  below_cost_approved  boolean not null default false,
  below_cost_reason    text,
  reason               text not null default '',
  candidate_evidence   jsonb,
  created_by           text,
  created_at           timestamptz not null default now(),
  verified_by          text,
  verified_at          timestamptz,
  verify_note          text,
  closed_by            text,
  closed_at            timestamptz,
  closed_reason        text,
  check (effective_to is null or effective_to >= effective_from)
);
create index if not exists customer_price_agreements_key_idx on public.customer_price_agreements (customer_id, product_id, design_id, status);
create index if not exists customer_price_agreements_status_idx on public.customer_price_agreements (status, effective_to);

create table if not exists public.price_agreement_events (
  id           bigserial primary key,
  agreement_id uuid not null references public.customer_price_agreements(id),
  customer_id  text not null,
  at           timestamptz not null default now(),
  kind         text not null check (kind in ('created', 'candidate_imported', 'verified', 'rejected', 'revoked', 'ended')),
  actor        text not null default 'system',
  details      jsonb not null default '{}'::jsonb
);
create index if not exists price_agreement_events_customer_idx on public.price_agreement_events (customer_id, id desc);

-- Which agreement produced each customer-app order line (traceability; the line itself holds the frozen prices). No foreign key on purpose: the record outlives the order.
create table if not exists public.order_price_resolutions (
  order_item_id text primary key,
  order_id      text not null,
  customer_id   text not null,
  product_id    text not null,
  design_id     uuid,
  source        text not null check (source in ('list', 'agreement')),
  agreement_id  uuid,
  list_price    numeric(12,2) not null,
  applied_price numeric(12,2) not null,
  at            timestamptz not null default now()
);
create index if not exists order_price_resolutions_order_idx on public.order_price_resolutions (order_id);
create index if not exists order_price_resolutions_agreement_idx on public.order_price_resolutions (agreement_id);

do $$
declare t text;
begin
  foreach t in array array['customer_price_agreements', 'price_agreement_events', 'order_price_resolutions'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);
  end loop;
end $$;
revoke all on sequence public.price_agreement_events_id_seq from public, anon, authenticated, service_role;

drop trigger if exists trg_price_events_guard on public.price_agreement_events;
create trigger trg_price_events_guard before update or delete on public.price_agreement_events for each row execute function public.guard_credit_history();
drop trigger if exists trg_price_resolutions_guard on public.order_price_resolutions;
create trigger trg_price_resolutions_guard before update or delete on public.order_price_resolutions for each row execute function public.guard_credit_history();

-- An agreement is never edited into something else and never deleted. Overlapping agreements for the same customer, product and design cannot exist.
create or replace function public.guard_price_agreement()
returns trigger language plpgsql set search_path = public as $fn$
declare v_from date; v_to date;
begin
  if tg_op = 'DELETE' then raise exception 'price agreements are never deleted' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' then
    if (new.customer_id, new.product_id, new.design_id, new.source, new.created_by, new.created_at, new.candidate_evidence) is distinct from
       (old.customer_id, old.product_id, old.design_id, old.source, old.created_by, old.created_at, old.candidate_evidence) then
      raise exception 'an agreement''s customer, product, design and origin cannot be changed' using errcode = '42501';
    end if;
    if old.status in ('revoked', 'rejected') then raise exception 'a closed agreement cannot be changed' using errcode = '42501'; end if;
    if old.status = 'active' and new.status = 'active' then
      if (new.unit_price, new.effective_from) is distinct from (old.unit_price, old.effective_from) then raise exception 'an active agreement''s price and start date cannot be changed; end it and agree a new one' using errcode = '42501'; end if;
      if new.effective_to is not null and old.effective_to is not null and new.effective_to > old.effective_to then raise exception 'an agreement can be shortened, not extended; agree a new one' using errcode = '42501'; end if;
      if new.effective_to is null and old.effective_to is not null then raise exception 'an agreement can be shortened, not extended; agree a new one' using errcode = '42501'; end if;
    elsif old.status = 'active' and new.status not in ('revoked') then raise exception 'an active agreement can only be revoked or end-dated' using errcode = '42501';
    elsif old.status = 'pending_review' and new.status not in ('active', 'rejected', 'pending_review') then raise exception 'invalid agreement status change' using errcode = '42501';
    end if;
  end if;
  if new.status in ('active', 'pending_review') then
    perform pg_advisory_xact_lock(hashtext('price:' || new.customer_id || ':' || new.product_id));   -- two simultaneous agreements for one customer and product are decided one after the other
    v_from := new.effective_from; v_to := coalesce(new.effective_to, date 'infinity');
    if exists (select 1 from public.customer_price_agreements x
                where x.id <> new.id and x.customer_id = new.customer_id and x.product_id = new.product_id and x.design_id is not distinct from new.design_id
                  and x.status in ('active', 'pending_review') and x.effective_from <= v_to and coalesce(x.effective_to, date 'infinity') >= v_from) then
      raise exception 'This customer already has an active or pending agreement for that product and design in an overlapping period' using errcode = '22023';
    end if;
  end if;
  return new;
end;
$fn$;
drop trigger if exists trg_price_agreement_guard on public.customer_price_agreements;
create trigger trg_price_agreement_guard before insert or update or delete on public.customer_price_agreements for each row execute function public.guard_price_agreement();

-- -----------------------------------------------------------------------------
-- 2. Internal helpers
-- -----------------------------------------------------------------------------
create or replace function public._require_pricing_admin()
returns void language plpgsql stable security definer set search_path = public
as $fn$
begin
  if not public.can_manage_pricing() then raise exception 'Only a Super Admin or a Manager can manage customer prices' using errcode = '42501'; end if;
end;
$fn$;

create or replace function public._price_event(p_agreement uuid, p_customer text, p_kind text, p_details jsonb)
returns void language plpgsql volatile security definer set search_path = public
as $fn$
begin
  insert into public.price_agreement_events (agreement_id, customer_id, kind, actor, details)
  values (p_agreement, p_customer, p_kind, coalesce(public.current_profile_name(), public.current_profile_id(), 'system'), coalesce(p_details, '{}'::jsonb));
  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), case when p_kind in ('revoked', 'rejected') or (p_details ->> 'belowCost') = 'true' then 'WARNING' else 'INFO' end::public.log_severity, 'FINANCIAL',
          format('Price agreement %s (%s)', p_kind, p_agreement), public.current_profile_id(), coalesce(public.current_profile_name(), 'system'), p_customer,
          coalesce(p_details, '{}'::jsonb) || jsonb_build_object('source', 'db', 'event', 'price_agreement_' || p_kind, 'agreementId', p_agreement));
end;
$fn$;

-- THE price decision. source: agreement | list | review. 'review' means: do not sell this line online until an authorized person has confirmed the price.
create or replace function public._price_resolve(p_customer_id text, p_product_id text, p_design_id uuid, p_on date)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare
  v_on date := coalesce(p_on, public.efz_today()); p public.products%rowtype; scope integer; n_active integer; n_pending integer; a public.customer_price_agreements%rowtype;
begin
  select * into p from public.products where id = p_product_id;
  if not found then return jsonb_build_object('source', 'none', 'price', null, 'listPrice', null, 'reason', 'unknown product'); end if;
  -- most specific first: the design's own agreement, then the product-wide one
  for scope in 1..2 loop
    if scope = 1 and p_design_id is null then continue; end if;
    select count(*) filter (where status = 'active'), count(*) filter (where status = 'pending_review') into n_active, n_pending
      from public.customer_price_agreements g
     where g.customer_id = p_customer_id and g.product_id = p_product_id and v_on between g.effective_from and coalesce(g.effective_to, date 'infinity')
       and g.design_id is not distinct from (case when scope = 1 then p_design_id else null end) and g.status in ('active', 'pending_review');
    if n_active > 1 then return jsonb_build_object('source', 'review', 'price', null, 'listPrice', p.selling_price, 'reason', 'conflicting agreements'); end if;
    if n_active = 1 then
      select * into a from public.customer_price_agreements g
       where g.customer_id = p_customer_id and g.product_id = p_product_id and g.status = 'active' and v_on between g.effective_from and coalesce(g.effective_to, date 'infinity')
         and g.design_id is not distinct from (case when scope = 1 then p_design_id else null end);
      if a.unit_price < p.cost_price and not a.below_cost_approved then
        return jsonb_build_object('source', 'review', 'price', null, 'listPrice', p.selling_price, 'reason', 'the agreed price is below the current cost and was never approved');
      end if;
      return jsonb_build_object('source', 'agreement', 'price', a.unit_price, 'listPrice', p.selling_price, 'agreementId', a.id);
    end if;
    if n_pending > 0 then return jsonb_build_object('source', 'review', 'price', null, 'listPrice', p.selling_price, 'reason', 'an agreement is waiting to be verified'); end if;
  end loop;
  return jsonb_build_object('source', 'list', 'price', p.selling_price, 'listPrice', p.selling_price);
end;
$fn$;

revoke all on function public.guard_price_agreement() from public, anon, authenticated;
revoke all on function public._require_pricing_admin() from public, anon, authenticated;
revoke all on function public._price_event(uuid, text, text, jsonb) from public, anon, authenticated;
revoke all on function public._price_resolve(text, text, uuid, date) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. The customer pricing path: every price comes from _price_resolve with the CUSTOMER'S OWN id
-- -----------------------------------------------------------------------------
create or replace function public._customer_price_cart(p_lines jsonb, p_customer_id text)
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
  v_res      jsonb;
  v_key      text;
  r          record;
begin
  if p_customer_id is null then raise exception 'A customer is required to price a cart' using errcode = '22023'; end if;
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
    -- the ONE place a customer's price is decided: the verified agreement for this customer, product and design, else the list price. Nothing the client sends is used.
    v_res := public._price_resolve(p_customer_id, v_product.id, v_design_id, null);
    if v_res ->> 'source' = 'review' then
      raise exception 'The price of % needs to be confirmed by EFZ before you can order it online. Please contact EFZ.', v_product.name using errcode = '22023';
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'productId', v_product.id, 'productName', v_product.name,
      'designId', v_design_id, 'designName', case when v_design_id is null then '' else v_design.name end,
      'quantity', v_qty, 'unitPrice', (v_res ->> 'price')::numeric, 'lineTotal', (v_res ->> 'price')::numeric * v_qty,
      'listPrice', v_product.selling_price, 'priceSource', v_res ->> 'source', 'agreementId', v_res -> 'agreementId'));
    v_total := v_total + (v_res ->> 'price')::numeric * v_qty;
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
revoke all on function public._customer_price_cart(jsonb, text) from public, anon, authenticated;

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
  v_item_id  text;
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
    v_item_id := 'itm-' || replace(gen_random_uuid()::text, '-', '') || '-' || v_seq;
    -- the line keeps the list price AND the price actually charged (the verified agreement's, if one applied): a frozen snapshot, never recomputed
    insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost)
    values (v_item_id, v_order_id, v_product.id, v_product.name,
            coalesce(nullif(v_line ->> 'designName', ''), v_product.name), (v_line ->> 'quantity')::integer,
            coalesce((v_line ->> 'listPrice')::numeric, v_product.selling_price), coalesce((v_line ->> 'unitPrice')::numeric, v_product.selling_price), v_product.cost_price);
    insert into public.order_price_resolutions (order_item_id, order_id, customer_id, product_id, design_id, source, agreement_id, list_price, applied_price)
    values (v_item_id, v_order_id, v_customer.id, v_product.id, nullif(v_line ->> 'designId', '')::uuid, coalesce(v_line ->> 'priceSource', 'list'), nullif(v_line ->> 'agreementId', '')::uuid,
            coalesce((v_line ->> 'listPrice')::numeric, v_product.selling_price), coalesce((v_line ->> 'unitPrice')::numeric, v_product.selling_price));
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

create or replace function public.customer_price_preview(p_lines jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  return public._customer_price_cart(p_lines, public.require_approved_customer());
end;
$fn$;

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

  v_priced := public._customer_price_cart(p_payload -> 'lines', v_customer);
  insert into public.customer_checkouts (customer_id, account_id, submission_key, method_code, status, lines, amount, delivery_location, notes, expires_at)
  values (v_customer, v_acc, v_key, v_method, 'created', v_priced -> 'lines', (v_priced ->> 'total')::numeric, v_location, v_notes, now() + interval '30 minutes')
  returning id into v_id;
  return jsonb_build_object('checkoutId', v_id, 'status', 'created', 'amount', (v_priced ->> 'total')::numeric, 'methodCode', v_method, 'lines', v_priced -> 'lines', 'orderId', null, 'repeat', false);
end;
$fn$;

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
  v_priced := public._customer_price_cart(p_payload -> 'lines', v_customer);
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
        v_priced := public._customer_price_cart(v_in, c.customer_id);
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

drop function if exists public._customer_price_cart(jsonb);

-- -----------------------------------------------------------------------------
-- 4. What the customer sees: their own price only
-- -----------------------------------------------------------------------------
drop function if exists public.customer_catalog();
create function public.customer_catalog()
returns table (id text, name text, description text, category text, size text, durability text, surface_type text,
               is_wholesale boolean, selling_price numeric, image_url text, in_stock boolean, list_price numeric, price_status text)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v_customer text := public.require_approved_customer();
begin
  return query
    select p.id, p.name, p.description, p.category::text, p.size, p.durability, p.surface_type,
           p.is_wholesale, (r.res ->> 'price')::numeric, p.image_url, (p.stock > 0), p.selling_price,
           case r.res ->> 'source' when 'agreement' then 'agreement' when 'review' then 'review' else 'list' end
      from public.products p
      cross join lateral (select public._price_resolve(v_customer, p.id, null, null) as res) r
     where p.is_active
     order by p.name, p.id;
end;
$fn$;
revoke all on function public.customer_catalog() from public, anon;
grant execute on function public.customer_catalog() to authenticated;

drop function if exists public.customer_designs();
create function public.customer_designs()
returns table (id uuid, product_id text, name text, image_url text, sort_order integer, price numeric, list_price numeric, price_status text)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare v_customer text := public.require_approved_customer();
begin
  return query
    select d.id, d.product_id, d.name, d.image_url, d.sort_order, (r.res ->> 'price')::numeric, p.selling_price,
           case r.res ->> 'source' when 'agreement' then 'agreement' when 'review' then 'review' else 'list' end
      from public.product_designs d join public.products p on p.id = d.product_id
      cross join lateral (select public._price_resolve(v_customer, p.id, d.id, null) as res) r
     where d.is_active and p.is_active
     order by d.product_id, d.sort_order, d.name;
end;
$fn$;
revoke all on function public.customer_designs() from public, anon;
grant execute on function public.customer_designs() to authenticated;

-- The customer's own current agreed prices, nothing else (no ids of other customers, no cost, no evidence, no pending candidates).
create or replace function public.my_price_agreements()
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare v_customer text := public.require_approved_customer(); v_today date := public.efz_today();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('productId', g.product_id, 'productName', p.name, 'designId', g.design_id, 'designName', coalesce(d.name, ''), 'price', g.unit_price,
                                                       'listPrice', p.selling_price, 'validFrom', g.effective_from, 'validUntil', g.effective_to) order by p.name, d.name nulls first)
                     from public.customer_price_agreements g join public.products p on p.id = g.product_id left join public.product_designs d on d.id = g.design_id
                    where g.customer_id = v_customer and g.status = 'active' and v_today between g.effective_from and coalesce(g.effective_to, date 'infinity')), '[]'::jsonb);
end;
$fn$;
revoke all on function public.my_price_agreements() from public, anon;
grant execute on function public.my_price_agreements() to authenticated;

-- -----------------------------------------------------------------------------
-- 5. Administration (Super Admin or Manager; a below-cost price needs a Super Admin and a reason, as create_order requires)
-- -----------------------------------------------------------------------------
create or replace function public._price_validate(p_customer_id text, p_product_id text, p_design_id uuid, p_unit_price numeric, p_from date, p_to date, p_reason text, p_below_cost_reason text)
returns boolean   -- true when the price is below cost and has been approved
language plpgsql stable security definer set search_path = public
as $fn$
declare p public.products%rowtype; v_below boolean;
begin
  if not exists (select 1 from public.customers c where c.id = p_customer_id and c.status = 'active') then raise exception 'Unknown or inactive customer' using errcode = '22023'; end if;
  select * into p from public.products where id = p_product_id;
  if not found then raise exception 'Unknown product' using errcode = '22023'; end if;
  if p_design_id is not null and not exists (select 1 from public.product_designs d where d.id = p_design_id and d.product_id = p_product_id) then raise exception 'That design does not belong to the product' using errcode = '22023'; end if;
  if p_unit_price is null or p_unit_price <= 0 or p_unit_price > 1000000 or p_unit_price <> round(p_unit_price, 2) then raise exception 'The agreed price must be more than 0, in whole cents' using errcode = '22023'; end if;
  if p_from is null or p_from < date '2000-01-01' or p_from > public.efz_today() + 366 then raise exception 'Give a start date (not more than a year ahead)' using errcode = '22023'; end if;
  if p_to is not null and p_to < p_from then raise exception 'The end date cannot be before the start date' using errcode = '22023'; end if;
  if p_reason is null or char_length(btrim(p_reason)) < 10 then raise exception 'Record the authorization or evidence for this price (at least 10 characters)' using errcode = '22023'; end if;
  v_below := p_unit_price < p.cost_price;
  if v_below then
    if not public.is_super_admin() then raise exception 'This price is below the product''s cost. Only a Super Admin can approve a below-cost price.' using errcode = '42501'; end if;
    if p_below_cost_reason is null or char_length(btrim(p_below_cost_reason)) < 10 then raise exception 'This price is below the product''s cost. A below-cost price needs a reason of at least 10 characters.' using errcode = '22023'; end if;
  end if;
  return v_below;
end;
$fn$;
revoke all on function public._price_validate(text, text, uuid, numeric, date, date, text, text) from public, anon, authenticated;

create or replace function public.create_price_agreement(p_customer_id text, p_product_id text, p_design_id uuid, p_unit_price numeric, p_effective_from date, p_effective_to date, p_reason text, p_below_cost_reason text default null)
returns uuid
language plpgsql volatile security definer set search_path = public
as $fn$
declare v_below boolean; v_id uuid;
begin
  perform public._require_pricing_admin();
  v_below := public._price_validate(p_customer_id, p_product_id, p_design_id, p_unit_price, p_effective_from, p_effective_to, p_reason, p_below_cost_reason);
  insert into public.customer_price_agreements (customer_id, product_id, design_id, unit_price, effective_from, effective_to, status, source, below_cost_approved, below_cost_reason, reason, created_by, verified_by, verified_at, verify_note)
  values (p_customer_id, p_product_id, p_design_id, p_unit_price, p_effective_from, p_effective_to, 'active', 'manual', v_below, case when v_below then btrim(p_below_cost_reason) end, btrim(p_reason),
          public.current_profile_id(), public.current_profile_id(), now(), 'Recorded by an authorized person')
  returning id into v_id;
  perform public._price_event(v_id, p_customer_id, 'created', jsonb_build_object('productId', p_product_id, 'designId', p_design_id, 'unitPrice', p_unit_price, 'from', p_effective_from, 'to', p_effective_to, 'reason', btrim(p_reason), 'belowCost', v_below));
  return v_id;
end;
$fn$;

-- Changing an agreed price: the old agreement is closed (kept, revoked with the reason) and the new one is recorded in the SAME transaction, so no customer ever sees a moment
-- without a price in between. The new price needs the same authorization, reason and below-cost approval as a new agreement.
create or replace function public.replace_price_agreement(p_id uuid, p_unit_price numeric, p_effective_from date, p_effective_to date, p_reason text, p_below_cost_reason text default null)
returns uuid
language plpgsql volatile security definer set search_path = public
as $fn$
declare g public.customer_price_agreements%rowtype; v_below boolean; v_id uuid;
begin
  perform public._require_pricing_admin();
  select * into g from public.customer_price_agreements where id = p_id for update;
  if not found or g.status <> 'active' then raise exception 'Only an active agreement can be replaced' using errcode = '22023'; end if;
  v_below := public._price_validate(g.customer_id, g.product_id, g.design_id, p_unit_price, p_effective_from, p_effective_to, p_reason, p_below_cost_reason);
  update public.customer_price_agreements set status = 'revoked', closed_by = public.current_profile_id(), closed_at = now(), closed_reason = 'Replaced by a new price: ' || btrim(p_reason) where id = p_id;
  insert into public.customer_price_agreements (customer_id, product_id, design_id, unit_price, effective_from, effective_to, status, source, below_cost_approved, below_cost_reason, reason, created_by, verified_by, verified_at, verify_note)
  values (g.customer_id, g.product_id, g.design_id, p_unit_price, p_effective_from, p_effective_to, 'active', 'manual', v_below, case when v_below then btrim(p_below_cost_reason) end, btrim(p_reason),
          public.current_profile_id(), public.current_profile_id(), now(), 'Replaces agreement ' || p_id) returning id into v_id;
  perform public._price_event(p_id, g.customer_id, 'revoked', jsonb_build_object('reason', 'Replaced by a new price: ' || btrim(p_reason), 'replacedBy', v_id));
  perform public._price_event(v_id, g.customer_id, 'created', jsonb_build_object('productId', g.product_id, 'designId', g.design_id, 'unitPrice', p_unit_price, 'previousPrice', g.unit_price, 'replaces', p_id, 'from', p_effective_from, 'to', p_effective_to, 'reason', btrim(p_reason), 'belowCost', v_below));
  return v_id;
end;
$fn$;

create or replace function public.verify_price_agreement(p_id uuid, p_unit_price numeric, p_effective_from date, p_effective_to date, p_note text, p_below_cost_reason text default null)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
declare g public.customer_price_agreements%rowtype; v_below boolean;
begin
  perform public._require_pricing_admin();
  select * into g from public.customer_price_agreements where id = p_id for update;
  if not found or g.status <> 'pending_review' then raise exception 'Only a pending agreement can be verified' using errcode = '22023'; end if;
  v_below := public._price_validate(g.customer_id, g.product_id, g.design_id, p_unit_price, p_effective_from, p_effective_to, p_note, p_below_cost_reason);
  update public.customer_price_agreements set status = 'active', unit_price = p_unit_price, effective_from = p_effective_from, effective_to = p_effective_to, below_cost_approved = v_below,
         below_cost_reason = case when v_below then btrim(p_below_cost_reason) end, verified_by = public.current_profile_id(), verified_at = now(), verify_note = btrim(p_note) where id = p_id;
  perform public._price_event(p_id, g.customer_id, 'verified', jsonb_build_object('candidatePrice', g.unit_price, 'confirmedPrice', p_unit_price, 'changed', g.unit_price <> p_unit_price, 'from', p_effective_from, 'to', p_effective_to, 'note', btrim(p_note), 'belowCost', v_below));
end;
$fn$;

create or replace function public.reject_price_agreement(p_id uuid, p_reason text)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
declare g public.customer_price_agreements%rowtype;
begin
  perform public._require_pricing_admin();
  if p_reason is null or char_length(btrim(p_reason)) < 10 then raise exception 'Give a reason (at least 10 characters)' using errcode = '22023'; end if;
  select * into g from public.customer_price_agreements where id = p_id for update;
  if not found or g.status <> 'pending_review' then raise exception 'Only a pending agreement can be rejected' using errcode = '22023'; end if;
  update public.customer_price_agreements set status = 'rejected', closed_by = public.current_profile_id(), closed_at = now(), closed_reason = btrim(p_reason) where id = p_id;
  perform public._price_event(p_id, g.customer_id, 'rejected', jsonb_build_object('reason', btrim(p_reason)));
end;
$fn$;

create or replace function public.revoke_price_agreement(p_id uuid, p_reason text)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
declare g public.customer_price_agreements%rowtype;
begin
  perform public._require_pricing_admin();
  if p_reason is null or char_length(btrim(p_reason)) < 10 then raise exception 'Give a reason (at least 10 characters)' using errcode = '22023'; end if;
  select * into g from public.customer_price_agreements where id = p_id for update;
  if not found or g.status <> 'active' then raise exception 'Only an active agreement can be revoked' using errcode = '22023'; end if;
  update public.customer_price_agreements set status = 'revoked', closed_by = public.current_profile_id(), closed_at = now(), closed_reason = btrim(p_reason) where id = p_id;
  perform public._price_event(p_id, g.customer_id, 'revoked', jsonb_build_object('reason', btrim(p_reason)));
end;
$fn$;

create or replace function public.end_price_agreement(p_id uuid, p_effective_to date, p_reason text)
returns void
language plpgsql volatile security definer set search_path = public
as $fn$
declare g public.customer_price_agreements%rowtype;
begin
  perform public._require_pricing_admin();
  if p_reason is null or char_length(btrim(p_reason)) < 10 then raise exception 'Give a reason (at least 10 characters)' using errcode = '22023'; end if;
  select * into g from public.customer_price_agreements where id = p_id for update;
  if not found or g.status <> 'active' then raise exception 'Only an active agreement can be end-dated' using errcode = '22023'; end if;
  if p_effective_to is null or p_effective_to < g.effective_from then raise exception 'The end date cannot be before the start date' using errcode = '22023'; end if;
  if g.effective_to is not null and p_effective_to >= g.effective_to then raise exception 'The agreement already ends on % ; an end date can only be brought forward', g.effective_to using errcode = '22023'; end if;
  update public.customer_price_agreements set effective_to = p_effective_to where id = p_id;
  perform public._price_event(p_id, g.customer_id, 'ended', jsonb_build_object('previousEnd', g.effective_to, 'newEnd', p_effective_to, 'reason', btrim(p_reason)));
end;
$fn$;

create or replace function public.list_price_agreements(p_customer_id text default null, p_status text default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare v_today date := public.efz_today();
begin
  perform public._require_pricing_admin();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', g.id, 'customerId', g.customer_id, 'customerName', c.name, 'productId', g.product_id, 'productName', p.name, 'designId', g.design_id, 'designName', coalesce(d.name, ''),
      'unitPrice', g.unit_price, 'listPrice', p.selling_price, 'effectiveFrom', g.effective_from, 'effectiveTo', g.effective_to, 'status', g.status, 'source', g.source,
      'inEffect', g.status = 'active' and v_today between g.effective_from and coalesce(g.effective_to, date 'infinity'),
      'expired', g.status = 'active' and g.effective_to is not null and g.effective_to < v_today,
      'expiresSoon', g.status = 'active' and g.effective_to is not null and g.effective_to between v_today and v_today + 14,
      'belowCurrentCost', g.unit_price < p.cost_price, 'belowCostApproved', g.below_cost_approved, 'reason', g.reason, 'evidence', g.candidate_evidence,
      'createdAt', g.created_at, 'verifiedAt', g.verified_at, 'verifyNote', g.verify_note, 'closedAt', g.closed_at, 'closedReason', g.closed_reason)
      order by c.name, p.name, d.name nulls first, g.effective_from desc)
    from public.customer_price_agreements g join public.customers c on c.id = g.customer_id join public.products p on p.id = g.product_id left join public.product_designs d on d.id = g.design_id
   where (p_customer_id is null or g.customer_id = p_customer_id) and (p_status is null or g.status = p_status)), '[]'::jsonb);
end;
$fn$;

create or replace function public.price_agreement_history(p_customer_id text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
begin
  perform public._require_pricing_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'by', e.actor, 'kind', e.kind, 'agreementId', e.agreement_id, 'details', e.details) order by e.id desc)
                     from public.price_agreement_events e where e.customer_id = p_customer_id), '[]'::jsonb);
end;
$fn$;

create or replace function public.price_agreement_alerts()
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare v_today date := public.efz_today();
begin
  perform public._require_pricing_admin();
  return jsonb_build_object('asOf', v_today,
    'pending', (select count(*) from public.customer_price_agreements where status = 'pending_review'),
    'expiringSoon', (select count(*) from public.customer_price_agreements where status = 'active' and effective_to between v_today and v_today + 14),
    'expiredLast30Days', (select count(*) from public.customer_price_agreements where status = 'active' and effective_to between v_today - 30 and v_today - 1),
    'belowCurrentCost', (select count(*) from public.customer_price_agreements g join public.products p on p.id = g.product_id where g.status = 'active' and g.unit_price < p.cost_price and not g.below_cost_approved));
end;
$fn$;

-- What price would this customer get? For staff screens (the same decision the app uses).
create or replace function public.resolve_customer_price(p_customer_id text, p_product_id text, p_design_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
begin
  perform public._require_pricing_admin();
  return public._price_resolve(p_customer_id, p_product_id, p_design_id, null);
end;
$fn$;

-- Reads the order history and reports the negotiated prices it finds. Dry run by default (writes nothing). With p_dry_run = false it records ONLY the consistent ones as
-- PENDING candidates (not usable until an authorized person verifies each); everything ambiguous is reported for manual confirmation. No price is ever invented.
create or replace function public.import_price_candidates(p_dry_run boolean default true, p_since date default null, p_min_orders integer default 2)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $fn$
declare
  v_since date := coalesce(p_since, public.efz_today() - 365); r record; v_design uuid; v_reason text; v_cands jsonb := '[]'::jsonb; v_manual jsonb := '[]'::jsonb; v_created integer := 0; v_skipped integer := 0; v_item jsonb; v_id uuid;
begin
  perform public._require_pricing_admin();
  if p_min_orders is null or p_min_orders < 1 then raise exception 'The minimum number of orders must be at least 1' using errcode = '22023'; end if;
  for r in
    select o.customer_id, c.name as customer_name, oi.product_id, p.name as product_name, p.selling_price as list_now, p.cost_price as cost_now, oi.design_name,
           count(distinct o.id) as orders, array_agg(distinct oi.actual_unit_price order by oi.actual_unit_price) as prices, bool_and(oi.actual_unit_price <> oi.standard_unit_price) as all_negotiated,
           min(o.order_date) as first_date, max(o.order_date) as last_date, (array_agg(oi.actual_unit_price order by o.order_date desc, o.created_at desc))[1] as latest_price
      from public.order_items oi join public.orders o on o.id = oi.order_id join public.customers c on c.id = o.customer_id left join public.products p on p.id = oi.product_id
     where o.status <> 'cancelled' and o.order_type = 'regular' and o.order_date >= v_since and oi.product_id is not null and c.status = 'active'
     group by o.customer_id, c.name, oi.product_id, p.name, p.selling_price, p.cost_price, oi.design_name
    having bool_or(oi.actual_unit_price <> oi.standard_unit_price)
     order by c.name, p.name, oi.design_name
  loop
    v_design := null; v_reason := null;
    v_item := jsonb_build_object('customerId', r.customer_id, 'customerName', r.customer_name, 'productId', r.product_id, 'productName', r.product_name, 'designName', r.design_name, 'orders', r.orders,
                                 'prices', to_jsonb(r.prices), 'latestPrice', r.latest_price, 'firstOrder', r.first_date, 'lastOrder', r.last_date, 'listPriceNow', r.list_now);
    if r.product_name is null then v_reason := 'the product no longer exists';
    elsif r.design_name is distinct from r.product_name then
      select d.id into v_design from public.product_designs d where d.product_id = r.product_id and d.name = r.design_name and d.is_active limit 1;
      if v_design is null then v_reason := format('the design "%s" does not match an active design', r.design_name); end if;
    end if;
    if v_reason is null and exists (select 1 from public.customer_price_agreements g where g.customer_id = r.customer_id and g.product_id = r.product_id and g.design_id is not distinct from v_design
                                      and g.status in ('active', 'pending_review') and coalesce(g.effective_to, date 'infinity') >= public.efz_today()) then
      v_skipped := v_skipped + 1; continue;   -- already covered by an agreement or a pending candidate
    end if;
    if v_reason is null then
      if r.orders < p_min_orders then v_reason := format('only %s order(s) with a negotiated price (at least %s needed)', r.orders, p_min_orders);
      elsif array_length(r.prices, 1) > 1 then v_reason := format('the price varies between $%s and $%s (latest $%s)', r.prices[1], r.prices[array_length(r.prices, 1)], r.latest_price);
      elsif not r.all_negotiated then v_reason := 'some of the orders were sold at the list price';
      elsif r.prices[1] < r.cost_now then v_reason := 'the price is below the current cost: a Super Admin must approve it';
      end if;
    end if;
    if v_reason is not null then
      v_manual := v_manual || jsonb_build_array(v_item || jsonb_build_object('reason', v_reason));
    else
      v_cands := v_cands || jsonb_build_array(v_item || jsonb_build_object('proposedPrice', r.prices[1], 'proposedFrom', r.first_date, 'designId', v_design));
      if not p_dry_run then
        begin
          insert into public.customer_price_agreements (customer_id, product_id, design_id, unit_price, effective_from, status, source, reason, candidate_evidence, created_by)
          values (r.customer_id, r.product_id, v_design, r.prices[1], r.first_date, 'pending_review', 'import', 'Imported candidate from order history; not usable until verified',
                  v_item || jsonb_build_object('since', v_since), public.current_profile_id()) returning id into v_id;
          perform public._price_event(v_id, r.customer_id, 'candidate_imported', v_item);
          v_created := v_created + 1;
        exception when others then
          v_manual := v_manual || jsonb_build_array(v_item || jsonb_build_object('reason', 'could not be recorded: ' || sqlerrm));
          v_cands := v_cands - (jsonb_array_length(v_cands) - 1);
        end;
      end if;
    end if;
  end loop;
  return jsonb_build_object('dryRun', p_dry_run, 'since', v_since, 'minOrders', p_min_orders, 'candidates', v_cands, 'needsConfirmation', v_manual, 'alreadyCovered', v_skipped, 'created', v_created);
end;
$fn$;

do $$
declare f text;
begin
  foreach f in array array['create_price_agreement(text, text, uuid, numeric, date, date, text, text)', 'replace_price_agreement(uuid, numeric, date, date, text, text)', 'verify_price_agreement(uuid, numeric, date, date, text, text)', 'reject_price_agreement(uuid, text)',
                           'revoke_price_agreement(uuid, text)', 'end_price_agreement(uuid, date, text)', 'list_price_agreements(text, text)', 'price_agreement_history(text)', 'price_agreement_alerts()',
                           'resolve_customer_price(text, text, uuid)', 'import_price_candidates(boolean, date, integer)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

commit;
