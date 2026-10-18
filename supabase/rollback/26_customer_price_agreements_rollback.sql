-- =============================================================================
-- ROLLBACK of migration 26 (customer price agreements). Staging first; Production only with the owner's explicit approval. TEST IT ON A DISPOSABLE COPY FIRST.
-- Restores the exact pre-26 definitions (generated from the text of migrations 21, 22, 23 and 25) of the pricing path, the catalogue and the designs list, drops everything
-- migration 26 added, and leaves every order, order line, payment and invoice exactly as it is.
-- WHAT YOU LOSE (irreversible): the three tables are DROPPED with their rows:
--   * customer_price_agreements (every agreement, pending candidate and closed agreement),
--   * price_agreement_events (the agreement history),
--   * order_price_resolutions (the record of which agreement produced each customer-app order line).
--   The order lines themselves keep the list price and the price actually charged, so history, invoices and revenue are unaffected. EXPORT the three tables first if any real
--   agreement exists. The audit lines already written to system_logs stay.
-- AFTER ROLLBACK the customer app prices every line at the LIST price again: customers with negotiated prices would pay more online. Do not run this while the app is in use.
-- =============================================================================
begin;
set local lock_timeout = '30s';

-- the one-argument cart first, so that the restored callers have something to call
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

drop function if exists public._customer_price_cart(jsonb, text);

drop function if exists public.customer_catalog();
create or replace function public.customer_catalog()
returns table (id text, name text, description text, category text, size text, durability text, surface_type text,
               is_wholesale boolean, selling_price numeric, image_url text, in_stock boolean)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  perform public.require_approved_customer();
  return query
    select p.id, p.name, p.description, p.category::text, p.size, p.durability, p.surface_type,
           p.is_wholesale, p.selling_price, p.image_url, (p.stock > 0)
      from public.products p
     where p.is_active
     order by p.name, p.id;
end;
$fn$;
revoke all on function public.customer_catalog() from public, anon;
grant execute on function public.customer_catalog() to authenticated;

drop function if exists public.customer_designs();
create or replace function public.customer_designs()
returns table (id uuid, product_id text, name text, image_url text, sort_order integer)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  perform public.require_approved_customer();
  return query
    select d.id, d.product_id, d.name, d.image_url, d.sort_order
      from public.product_designs d join public.products p on p.id = d.product_id
     where d.is_active and p.is_active
     order by d.product_id, d.sort_order, d.name;
end;
$fn$;
revoke all on function public.customer_designs() from public, anon;
grant execute on function public.customer_designs() to authenticated;

drop function if exists public.my_price_agreements();
drop function if exists public.import_price_candidates(boolean, date, integer);
drop function if exists public.resolve_customer_price(text, text, uuid);
drop function if exists public.price_agreement_alerts();
drop function if exists public.price_agreement_history(text);
drop function if exists public.list_price_agreements(text, text);
drop function if exists public.end_price_agreement(uuid, date, text);
drop function if exists public.revoke_price_agreement(uuid, text);
drop function if exists public.reject_price_agreement(uuid, text);
drop function if exists public.verify_price_agreement(uuid, numeric, date, date, text, text);
drop function if exists public.replace_price_agreement(uuid, numeric, date, date, text, text);
drop function if exists public.create_price_agreement(text, text, uuid, numeric, date, date, text, text);
drop function if exists public._price_validate(text, text, uuid, numeric, date, date, text, text);
drop function if exists public._price_resolve(text, text, uuid, date);
drop function if exists public._price_event(uuid, text, text, jsonb);
drop function if exists public._require_pricing_admin();

drop table if exists public.order_price_resolutions;
drop table if exists public.price_agreement_events;
drop table if exists public.customer_price_agreements;
drop function if exists public.guard_price_agreement();

commit;
