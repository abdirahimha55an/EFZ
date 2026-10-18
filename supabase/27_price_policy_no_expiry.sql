-- =============================================================================
-- 27 - Price policy: agreements without an end date, expiry notices, one pricing function for staff orders. Follows migration 26. NOT APPLIED to any database
-- until the owner approves it.
-- -----------------------------------------------------------------------------
-- Owner-approved rules this implements:
--   1. A verified agreement with NO end date stays in force until an authorized staff member changes, revokes or ends it. Nothing here (or anywhere) expires an
--      agreement because it is old: only an explicit effective_to date does.
--   2. An agreement with an end date follows that date. The customer is told in the app (a customer notice, once per stage: within 30 days, within 7 days, and after it
--      ended) so the return to the list price is never a surprise. Staff see the same agreements in the Customer Prices alerts.
--   3. Staff-created orders (create_order, and create_order_with_terms through it) now get the price from the SAME function as the customer app, _price_resolve, as of the
--      order date. Without a price in the request the agreed price (else the list price) is used. A different price for a customer who has an agreement needs a
--      documented priceOverrideReason (10+ characters), is recorded as a staff override and audited; a price that is still waiting for confirmation (pending, conflicting,
--      unapproved below cost) blocks the line instead of silently using the list price. Customers without an agreement behave exactly as before.
--   3b. replace_price_agreement: a change that starts in the future leaves the current price in force until the day before it starts (the old agreement is end-dated, not
--      revoked), so a customer is never dropped to the list price in between. A change that starts today or earlier replaces it at once, as before.
--   4. Every audit event of an agreement now also carries the agreement's price, product and design at that moment (with the previous price on a change).
-- Existing orders, invoices, payments and revenue are never touched; prices apply prospectively only.
-- Adds: price_agreement_notices (insert-only), _price_expiry_notices, price_daily_run (service role), run_price_checks (pricing admins), resolve_order_price (the Hub
-- order form asks it what price create_order will apply).
-- Redefines: create_order, replace_price_agreement, _price_event, customer_catalog (now volatile: it records the notices). Widens order_price_resolutions.source with 'staff_override'.
-- Rollback: rollback/27_price_policy_no_expiry_rollback.sql (run it BEFORE the migration 26 rollback).
-- =============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
begin
  if to_regclass('public.customer_price_agreements') is null or to_regprocedure('public._price_resolve(text, text, uuid, date)') is null or to_regclass('public.customer_notifications') is null then
    raise exception 'migration 26 (and 25) must be applied first';
  end if;
end
$pre$;

-- 1. The record that a notice was sent (one row per agreement and stage): makes the notices idempotent, however many times and from wherever they are triggered.
create table if not exists public.price_agreement_notices (
  agreement_id uuid not null,
  stage        text not null check (stage in ('expiry_30', 'expiry_7', 'expired')),
  customer_id  text not null,
  notified_at  timestamptz not null default now(),
  primary key (agreement_id, stage)
);
alter table public.price_agreement_notices enable row level security;
revoke all on public.price_agreement_notices from public, anon, authenticated, service_role;
drop trigger if exists trg_price_notices_guard on public.price_agreement_notices;
create trigger trg_price_notices_guard before update or delete on public.price_agreement_notices for each row execute function public.guard_credit_history();

-- 2. Staff orders may record that an agreed price was overridden
alter table public.order_price_resolutions drop constraint if exists order_price_resolutions_source_check;
alter table public.order_price_resolutions add constraint order_price_resolutions_source_check check (source in ('list', 'agreement', 'staff_override'));

-- 3. Expiry notices
create or replace function public._price_expiry_notices(p_customer text default null)
returns integer
language plpgsql volatile security definer set search_path = public
as $fn$
declare
  r record; v_today date := public.efz_today(); v_stage text; v_rows integer; v_cnt integer := 0; v_what text;
begin
  for r in
    select g.id, g.customer_id, g.unit_price, g.effective_to, p.name as pname, p.selling_price as list_price, coalesce(d.name, '') as dname
      from public.customer_price_agreements g join public.products p on p.id = g.product_id left join public.product_designs d on d.id = g.design_id
     where g.status = 'active' and g.effective_to is not null and g.effective_from <= v_today
       and g.effective_to between v_today - 30 and v_today + 30
       and (p_customer is null or g.customer_id = p_customer)
  loop
    v_stage := case when r.effective_to < v_today then 'expired' when r.effective_to - v_today <= 7 then 'expiry_7' else 'expiry_30' end;
    insert into public.price_agreement_notices (agreement_id, stage, customer_id) values (r.id, v_stage, r.customer_id) on conflict do nothing;
    get diagnostics v_rows = row_count;
    if v_rows = 1 then
      v_cnt := v_cnt + 1;
      v_what := r.pname || case when r.dname <> '' then ' (' || r.dname || ')' else '' end;
      insert into public.customer_notifications (customer_id, kind, title, body)
      values (r.customer_id, 'price_agreement',
              case v_stage when 'expired' then 'Your agreed price has ended' else 'Your agreed price is ending soon' end,
              case v_stage when 'expired'
                then format('Your agreed price of $%s for %s ended on %s. The list price ($%s) applies now unless EFZ agrees a new price with you. Please contact EFZ to renew it.', r.unit_price, v_what, r.effective_to, r.list_price)
                else format('Your agreed price of $%s for %s ends on %s. After that date the list price ($%s) applies unless EFZ agrees a new price with you. Please contact EFZ if you would like to renew it.', r.unit_price, v_what, r.effective_to, r.list_price) end);
    end if;
  end loop;
  return v_cnt;
end;
$fn$;
revoke all on function public._price_expiry_notices(text) from public, anon, authenticated;

create or replace function public.price_daily_run()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $fn$
declare v_n integer;
begin
  v_n := public._price_expiry_notices(null);
  return jsonb_build_object('asOf', public.efz_today(), 'noticesSent', v_n);
end;
$fn$;
revoke all on function public.price_daily_run() from public, anon, authenticated;
grant execute on function public.price_daily_run() to service_role;

create or replace function public.run_price_checks()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $fn$
begin
  perform public._require_pricing_admin();
  return public.price_daily_run();
end;
$fn$;
revoke all on function public.run_price_checks() from public, anon;
grant execute on function public.run_price_checks() to authenticated;

-- 4. Audit events carry the agreement's price
create or replace function public._price_event(p_agreement uuid, p_customer text, p_kind text, p_details jsonb)
returns void language plpgsql volatile security definer set search_path = public
as $fn$
declare v_details jsonb;
begin
  -- 27: every event carries the agreement's price, product and design as they are at that moment, so each line of the history shows the price it concerns
  select coalesce((select jsonb_build_object('agreementPrice', g.unit_price, 'productId', g.product_id, 'designId', g.design_id) from public.customer_price_agreements g where g.id = p_agreement), '{}'::jsonb) || coalesce(p_details, '{}'::jsonb) into v_details;
  insert into public.price_agreement_events (agreement_id, customer_id, kind, actor, details)
  values (p_agreement, p_customer, p_kind, coalesce(public.current_profile_name(), public.current_profile_id(), 'system'), v_details);
  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), case when p_kind in ('revoked', 'rejected') or (v_details ->> 'belowCost') = 'true' then 'WARNING' else 'INFO' end::public.log_severity, 'FINANCIAL',
          format('Price agreement %s (%s)', p_kind, p_agreement), public.current_profile_id(), coalesce(public.current_profile_name(), 'system'), p_customer,
          v_details || jsonb_build_object('source', 'db', 'event', 'price_agreement_' || p_kind, 'agreementId', p_agreement));
end;
$fn$;
revoke all on function public._price_event(uuid, text, text, jsonb) from public, anon, authenticated;

-- 4b. A change that starts later keeps the current price until then
create or replace function public.replace_price_agreement(p_id uuid, p_unit_price numeric, p_effective_from date, p_effective_to date, p_reason text, p_below_cost_reason text default null)
returns uuid
language plpgsql volatile security definer set search_path = public
as $fn$
declare g public.customer_price_agreements%rowtype; v_below boolean; v_id uuid; v_today date := public.efz_today(); v_future boolean;
begin
  perform public._require_pricing_admin();
  select * into g from public.customer_price_agreements where id = p_id for update;
  if not found or g.status <> 'active' then raise exception 'Only an active agreement can be replaced' using errcode = '22023'; end if;
  v_below := public._price_validate(g.customer_id, g.product_id, g.design_id, p_unit_price, p_effective_from, p_effective_to, p_reason, p_below_cost_reason);
  -- 27: a change that starts in the future leaves the current price in force until the day before it starts (the customer is never dropped to the list price in between).
  v_future := p_effective_from > v_today and p_effective_from - 1 >= g.effective_from;
  if v_future then
    if g.effective_to is null or g.effective_to >= p_effective_from then
      update public.customer_price_agreements set effective_to = p_effective_from - 1 where id = p_id;
      perform public._price_event(p_id, g.customer_id, 'ended', jsonb_build_object('previousEnd', g.effective_to, 'newEnd', p_effective_from - 1, 'reason', 'Replaced from ' || p_effective_from || ' by a new price: ' || btrim(p_reason)));
    end if;
  else
    update public.customer_price_agreements set status = 'revoked', closed_by = public.current_profile_id(), closed_at = now(), closed_reason = 'Replaced by a new price: ' || btrim(p_reason) where id = p_id;
  end if;
  insert into public.customer_price_agreements (customer_id, product_id, design_id, unit_price, effective_from, effective_to, status, source, below_cost_approved, below_cost_reason, reason, created_by, verified_by, verified_at, verify_note)
  values (g.customer_id, g.product_id, g.design_id, p_unit_price, p_effective_from, p_effective_to, 'active', 'manual', v_below, case when v_below then btrim(p_below_cost_reason) end, btrim(p_reason),
          public.current_profile_id(), public.current_profile_id(), now(), 'Replaces agreement ' || p_id) returning id into v_id;
  if not v_future then
    perform public._price_event(p_id, g.customer_id, 'revoked', jsonb_build_object('reason', 'Replaced by a new price: ' || btrim(p_reason), 'replacedBy', v_id));
  end if;
  perform public._price_event(v_id, g.customer_id, 'created', jsonb_build_object('productId', g.product_id, 'designId', g.design_id, 'unitPrice', p_unit_price, 'previousPrice', g.unit_price, 'replaces', p_id, 'from', p_effective_from, 'to', p_effective_to, 'reason', btrim(p_reason), 'belowCost', v_below));
  return v_id;
end;
$fn$;

-- 5. The catalogue records the notices (a look is enough; no scheduler is needed for the customer to be told)
create or replace function public.customer_catalog()
returns table (id text, name text, description text, category text, size text, durability text, surface_type text,
               is_wholesale boolean, selling_price numeric, image_url text, in_stock boolean, list_price numeric, price_status text)
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare v_customer text := public.require_approved_customer();
begin
  -- 27: the customer is told, once per stage, when an agreed price with an end date is about to end (or has just ended)
  perform public._price_expiry_notices(v_customer);
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

-- 5b. What price will this customer get on a staff order? For the Hub order form (create_orders), the same decision create_order makes. No agreement ids or evidence.
create or replace function public.resolve_order_price(p_customer_id text, p_product_id text, p_design_name text default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare v_customer public.customers%rowtype; v_design uuid; v_res jsonb; v_actor text := public.current_profile_id();
begin
  perform public.require_permission('create_orders');
  select * into v_customer from public.customers where id = p_customer_id;
  if not found
     or (auth.uid() is not null and not public.has_permission('view_all_customers') and not public.has_permission('view_customers')
         and v_customer.marketing_officer_id is distinct from v_actor and v_customer.registered_by is distinct from v_actor) then
    raise exception 'Unknown customer: %', p_customer_id;
  end if;
  if nullif(btrim(coalesce(p_design_name, '')), '') is not null then
    select d.id into v_design from public.product_designs d where d.product_id = p_product_id and d.is_active and lower(d.name) = lower(btrim(p_design_name)) order by d.sort_order limit 1;
  end if;
  v_res := public._price_resolve(p_customer_id, p_product_id, v_design, public.efz_today());
  return jsonb_build_object('source', v_res ->> 'source', 'price', v_res -> 'price', 'listPrice', v_res -> 'listPrice', 'reason', v_res ->> 'reason');
end;
$fn$;
revoke all on function public.resolve_order_price(text, text, text) from public, anon;
grant execute on function public.resolve_order_price(text, text, text) to authenticated;

-- 6. Staff orders use the same pricing function
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
  v_design_id    uuid;
  v_res          jsonb;
  v_src          text;
  v_typed        numeric;
  v_price_reason text;
  v_agreed_ok    boolean;
  v_line_reason  text;
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
  v_price_reason := nullif(btrim(coalesce(payload ->> 'priceOverrideReason', '')), '');

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

    -- 27: the customer's price is decided by the same function the app uses (_price_resolve), as of the order date. With no price in the request the
    -- agreed (or list) price is used. A different price for a customer who HAS an agreement needs a documented reason; a price that is still waiting to be
    -- confirmed (pending, conflicting, unapproved below cost) blocks the line: an agreement is never silently replaced by the list price.
    v_design_id := null;
    if nullif(v_item ->> 'designId', '') is not null then
      begin v_design_id := (v_item ->> 'designId')::uuid; exception when invalid_text_representation then
        raise exception 'Invalid design' using errcode = '22023'; end;
      if not exists (select 1 from public.product_designs d where d.id = v_design_id and d.product_id = v_product.id) then
        raise exception 'That design does not belong to %', v_product.name using errcode = '22023';
      end if;
    elsif nullif(v_item ->> 'designName', '') is not null then
      select d.id into v_design_id from public.product_designs d
       where d.product_id = v_product.id and d.is_active and lower(d.name) = lower(btrim(v_item ->> 'designName'))
       order by d.sort_order limit 1;
    end if;
    v_res := public._price_resolve(v_customer.id, v_product.id, v_design_id, v_date);
    v_src := v_res ->> 'source';
    if v_src = 'review' then
      raise exception 'The price of % for this customer needs to be confirmed before an order can be created (%). Resolve it in Customer Prices.', v_product.name, v_res ->> 'reason'
        using errcode = '22023';
    end if;
    v_typed := nullif(v_item ->> 'actualUnitPrice', '')::numeric;
    v_actual := coalesce(v_typed, (v_res ->> 'price')::numeric);
    v_agreed_ok := false;
    if v_src = 'agreement' then
      if v_typed is not null and v_typed <> (v_res ->> 'price')::numeric then
        if v_price_reason is null or char_length(v_price_reason) < 10 then
          raise exception 'This customer has an agreed price of % for %. To charge a different price give a priceOverrideReason (at least 10 characters).', v_res ->> 'price', v_product.name
            using errcode = '22023';
        end if;
        v_src := 'staff_override';
        insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
        values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'WARNING', 'FINANCIAL',
                format('Agreed price overridden on order %s: %s charged %s instead of the agreed %s', v_order_id, v_product.name, v_actual, v_res ->> 'price'),
                v_actor, v_actor_name, v_order_id,
                jsonb_build_object('source', 'db', 'event', 'agreed_price_overridden', 'productId', v_product.id, 'agreementId', v_res -> 'agreementId',
                                   'agreedPrice', (v_res ->> 'price')::numeric, 'chargedPrice', v_actual, 'reason', v_price_reason));
      else
        v_agreed_ok := true;   -- the agreed price itself (any below-cost approval was given when the agreement was verified)
      end if;
    end if;
    v_line_reason := case when v_agreed_ok then 'Approved price agreement ' || (v_res ->> 'agreementId') else v_reason end;
    if v_actual < 0 then
      raise exception 'Price for % cannot be negative', v_product.name;
    end if;

    if v_actual < v_product.cost_price and not v_agreed_ok then
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
      coalesce(nullif(v_item ->> 'designName', ''), (select d.name from public.product_designs d where d.id = v_design_id), v_product.name),
      v_qty,
      v_product.selling_price,   -- list price at the time of sale, never caller-supplied
      v_actual,
      v_product.cost_price       -- frozen cost snapshot
    );

    -- 27: which price rule produced this line (traceability; the line itself holds the frozen prices)
    insert into public.order_price_resolutions (order_item_id, order_id, customer_id, product_id, design_id, source, agreement_id, list_price, applied_price)
    values (v_item_id, v_order_id, v_customer.id, v_product.id, v_design_id, case v_src when 'agreement' then 'agreement' when 'staff_override' then 'staff_override' else 'list' end,
            nullif(v_res ->> 'agreementId', '')::uuid, v_product.selling_price, v_actual);

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
        v_line_reason, v_actor, v_actor_name
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
          'reason', v_line_reason)
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

commit;
