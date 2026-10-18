-- =============================================================================
-- ROLLBACK of migration 27 (price policy). Staging first; Production only with the owner's explicit approval. TEST IT ON A DISPOSABLE COPY FIRST.
-- Run it BEFORE the migration 26 rollback. Restores create_order, _price_event and customer_catalog to their pre-27 text and drops what 27 added.
-- WHAT YOU LOSE (irreversible): price_agreement_notices (the record of which expiry notices were sent; the notices already placed in customer_notifications stay).
--   Order lines that a staff order resolved as 'staff_override' are relabelled 'agreement' in order_price_resolutions (the lines themselves, with their prices, are not touched;
--   the override reason stays in system_logs).
-- AFTER ROLLBACK staff orders again take whatever price is typed (the list price when none), and the audit events no longer add the agreement's price.
-- =============================================================================
begin;
set local lock_timeout = '30s';
-- DEPENDENCY GUARD: this script restores the migration-26 text of several functions, which needs the migration-26 objects. Rolling back 26 first is not allowed (the 26 rollback refuses too).
do $guard$
begin
  if to_regclass('public.customer_price_agreements') is null or to_regclass('public.order_price_resolutions') is null or to_regprocedure('public._price_resolve(text, text, uuid, date)') is null then
    raise exception 'Migration 26 objects are missing; migration 27 cannot be rolled back on top of that state (the order is 27, then 26, then 25). Nothing was changed.' using errcode = '55000';
  end if;
end
$guard$;
update public.order_price_resolutions set source = 'agreement' where source = 'staff_override';
alter table public.order_price_resolutions drop constraint if exists order_price_resolutions_source_check;
alter table public.order_price_resolutions add constraint order_price_resolutions_source_check check (source in ('list', 'agreement'));
create or replace function public.create_order(payload jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
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
revoke all on function public._price_event(uuid, text, text, jsonb) from public, anon, authenticated;
create or replace function public.customer_catalog()
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
revoke all on function public._price_resolve(text, text, uuid, date) from public, anon, authenticated;
create or replace function public.convert_website_request(p_request_id uuid, p_payload jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare
  v_req         public.order_requests%rowtype;
  v_actor       text := public.current_profile_id();
  v_actor_name  text := coalesce(public.current_profile_name(), '');
  v_label       text := 'REQ-' || upper(left(replace(p_request_id::text, '-', ''), 8));
  v_lines       jsonb := p_payload -> 'lines';
  v_new         jsonb := p_payload -> 'newCustomer';
  v_customer_id text := nullif(btrim(coalesce(p_payload ->> 'customerId', '')), '');
  v_owner_id    text;
  v_owner       public.profiles%rowtype;
  v_items       jsonb := '[]'::jsonb;
  v_line        jsonb;
  v_name        text;
  v_phone_raw   text;
  v_canon       text;
  v_stored      text;
  v_new_cust    boolean := false;
  v_order_id    text;
begin
  select * into v_req from public.order_requests where id = p_request_id for update;
  if not found or not public.can_access_order_request(v_req.assigned_to) then
    raise exception 'Permission denied or unknown website request' using errcode = '42501';
  end if;

  if not public.has_permission('convert_website_requests') then   -- 19
    raise exception 'Permission denied: convert_website_requests is required' using errcode = '42501';
  end if;

  if v_req.status = 'converted' then
    raise exception 'Website request % was already converted to order %', v_label, v_req.converted_order_id
      using errcode = 'WR409';
  end if;
  if v_req.status <> 'confirmed' then
    raise exception 'Only a confirmed request can be converted (this one is %)', v_req.status using errcode = 'WR409';
  end if;

  if jsonb_typeof(v_lines) is distinct from 'array' or jsonb_array_length(v_lines) not between 1 and 20 then
    raise exception 'A conversion needs between 1 and 20 lines' using errcode = '22023';
  end if;
  for v_line in select * from jsonb_array_elements(v_lines)
  loop
    if nullif(v_line ->> 'productId', '') is null or (v_line -> 'actualUnitPrice') is null
       or jsonb_typeof(v_line -> 'actualUnitPrice') <> 'number' then
      raise exception 'Every line needs a product and a confirmed unit price' using errcode = '22023';
    end if;
    v_items := v_items || jsonb_build_array(jsonb_build_object(
                 'productId', v_line ->> 'productId',
                 'quantity', v_line -> 'quantity',
                 'actualUnitPrice', v_line -> 'actualUnitPrice'));
  end loop;

  if (v_customer_id is null) = (v_new is null or jsonb_typeof(v_new) <> 'object') then
    raise exception 'Choose an existing customer or a new one' using errcode = '22023';
  end if;

  if v_customer_id is not null then
    if nullif(btrim(coalesce(p_payload ->> 'ownerOfficerId', v_new ->> 'ownerOfficerId', '')), '') is not null then
      raise exception 'An existing customer keeps its owner; ownership changes only with a customer transfer'
        using errcode = '22023';
    end if;
  else
    v_new_cust := true;
    if not public.has_permission('add_customers') then
      raise exception 'Permission denied: add_customers is required to create a customer' using errcode = '42501';
    end if;
    v_name := btrim(coalesce(v_new ->> 'name', ''));
    if char_length(v_name) not between 1 and 200 then
      raise exception 'The new customer needs a name (up to 200 characters)' using errcode = '22023';
    end if;
    v_phone_raw := btrim(coalesce(v_new ->> 'phone', ''));
    v_canon := public.validate_request_phone(v_phone_raw);

    if exists (select 1 from public.customers c where public.customer_phone_canonical(c.phone) = v_canon)
       and coalesce((p_payload ->> 'confirmNoDuplicate')::boolean, false) is not true then
      raise exception 'A customer with this phone already exists: pick it, or confirm a separate customer'
        using errcode = 'WR410';
    end if;

    v_owner_id := nullif(btrim(coalesce(v_new ->> 'ownerOfficerId', '')), '');
    if v_owner_id is not null then
      if not public.has_permission('assign_website_requests') then   -- 19: a supervisory capability
        raise exception 'Permission denied: only a request assigner can set the initial owner' using errcode = '42501';
      end if;
      select * into v_owner from public.profiles where id = v_owner_id;
      if not found or v_owner.role <> 'Marketing Officer' or v_owner.status <> 'active' then
        raise exception 'The initial owner must be an active Marketing Officer' using errcode = '22023';
      end if;
    end if;

    -- Stored in the existing customer convention: 9-digit national number for Somali.
    v_stored := case when v_canon like '+252%' then substr(v_canon, 5) else v_canon end;
    v_customer_id := 'cust-' || replace(gen_random_uuid()::text, '-', '');

    insert into public.customers (id, name, email, phone, notes, marketing_officer_id, registered_by, status)
    values (v_customer_id, v_name, btrim(coalesce(v_new ->> 'email', '')), v_stored,
            btrim(coalesce(v_new ->> 'notes', '')), v_owner_id, v_actor, 'active');

    if v_owner_id is not null then
      insert into public.customer_ownership_changes (customer_id, customer_name, old_officer_id, old_officer_name,
                                                     new_officer_id, new_officer_name, reason, orders_moved,
                                                     changed_by, changed_by_name)
      values (v_customer_id, v_name, null, '', v_owner_id, v_owner.name,
              'Initial owner set at website-request conversion', '{}', v_actor, v_actor_name);

      insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
      values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'CUSTOMER',
              format('Customer %s created from %s and assigned to %s', v_customer_id, v_label, v_owner.name),
              v_actor, v_actor_name, v_customer_id,
              jsonb_build_object('source', 'db', 'event', 'website_request_initial_owner', 'requestId', p_request_id,
                                 'customerId', v_customer_id, 'officerId', v_owner_id));
    end if;
  end if;

  -- The only path to orders: the unchanged create_order() with all its rules.
  v_order_id := public.create_order(jsonb_build_object(
    'customerId',      v_customer_id,
    'deliveryNotes',   btrim(coalesce(p_payload ->> 'deliveryNotes', '')),
    'belowCostReason', p_payload ->> 'belowCostReason',
    'items',           v_items));

  update public.order_requests
     set status             = 'converted',
         converted_order_id = v_order_id,
         handled_by         = v_actor,
         status_changed_at  = now(),
         updated_at         = now()
   where id = p_request_id;

  insert into public.order_request_events (request_id, event, from_status, to_status, actor_id, actor_name, order_id, details)
  values (p_request_id, 'converted', 'confirmed', 'converted', v_actor, v_actor_name, v_order_id,
          jsonb_build_object('customerId', v_customer_id, 'newCustomer', v_new_cust,
                             'ownerOfficerId', v_owner_id, 'lines', v_items));

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'ORDER',
          format('Website request %s converted to order %s (%s customer)', v_label, v_order_id,
                 case when v_new_cust then 'new' else 'existing' end),
          v_actor, v_actor_name, p_request_id::text,
          jsonb_build_object('source', 'db', 'event', 'website_request_converted', 'requestId', p_request_id,
                             'orderId', v_order_id, 'customerId', v_customer_id, 'newCustomer', v_new_cust));
  return v_order_id;
end;
$fn$;
drop function if exists public.resolve_order_price(text, text, text);
drop function if exists public.run_price_checks();
drop function if exists public.price_daily_run();
drop function if exists public._price_expiry_notices(text);
drop table if exists public.price_agreement_notices;
commit;
