-- =============================================================================
-- 28 - Request conversion keeps the design and the agreed price. Follows migration 27. NOT APPLIED to any database until the owner approves the reviewed SQL.
-- -----------------------------------------------------------------------------
-- WHAT CHANGES: exactly one function, convert_website_request(uuid, jsonb). Nothing else: no table, column, index, policy, grant or permission, and create_order() is NOT touched.
--   1. Each line may carry designId (a catalogue design) and/or designName (the name recorded on the request line); both are forwarded to create_order(), which validates the
--      design against the product and stores design_name on the order line and the design id in order_price_resolutions.
--   2. actualUnitPrice becomes OPTIONAL. Left out, create_order() prices the line with _price_resolve(): the customer's design agreement, else the product agreement, else the list
--      price; a price still waiting to be confirmed blocks the line. A price that IS sent behaves exactly as before (a different price for a customer with an agreement needs
--      priceOverrideReason of 10+ characters, becomes 'staff_override', and is audited by create_order()).
--   3. A product and design pair may appear once per request (a product on two lines needs two different designs).
--   Everything else (permission, locking, status, customer handling, ownership, the converted link, the request event and the system log) is the migration-27 text, unchanged.
-- Existing orders, the five already-converted requests, stock, commissions, revenue and payments are never touched; the change applies to future conversions only.
-- Rollback: rollback/28_convert_request_designs_rollback.sql. Verification: checks/28_preflight.sql (before) and checks/28_post_deploy.sql (after).
-- =============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
declare
  v_md5 text;
begin
  if to_regprocedure('public.convert_website_request(uuid, jsonb)') is null or to_regprocedure('public.create_order(jsonb)') is null
     or to_regprocedure('public._price_resolve(text, text, uuid, date)') is null or to_regclass('public.order_price_resolutions') is null then
    raise exception 'migration 27 must be applied first';
  end if;
  -- create_order() must be the migration-27 text this file relies on (it is not changed here).
  if md5(replace(pg_get_functiondef('public.create_order(jsonb)'::regprocedure), chr(13), '')) <> '265e9745acb9418787e6d8cebfb450af' then
    raise exception 'create_order is not the migration-27 definition this migration relies on; refusing to continue (run supabase/checks/28_preflight.sql)';
  end if;
  -- Replace convert_website_request only when it is exactly the migration-27 text, or already this migration's own text (safe retry).
  v_md5 := md5(replace(pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure), chr(13), ''));
  if v_md5 <> 'fe992c8ab3edc37522d08e3e6eb41c9c'
     and position('migration 28 marker' in pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure)) = 0 then
    raise exception 'convert_website_request is not the migration-27 definition (md5 %); refusing to replace it (run supabase/checks/28_preflight.sql)', v_md5;
  end if;
end
$pre$;

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
  v_line_price  jsonb;
  v_item        jsonb;
  v_design_id   text;
  v_design_name text;
  v_pairs       text[] := '{}';
  v_pair        text;
begin
  -- migration 28 marker (the stored text carries it, so a re-run and the rollback can recognise this definition)
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
    if jsonb_typeof(v_line) is distinct from 'object' or nullif(v_line ->> 'productId', '') is null then
      raise exception 'Every line needs a product' using errcode = '22023';
    end if;

    -- 28: the price is optional. Left out, create_order() applies the customer's agreed price (design agreement, then product agreement), else the list price.
    -- A price that is sent must be a number; whether it differs from an agreed price, and so needs priceOverrideReason, is decided by create_order() alone.
    v_line_price := v_line -> 'actualUnitPrice';
    if v_line_price is not null and jsonb_typeof(v_line_price) not in ('number', 'null') then
      raise exception 'A unit price must be a number' using errcode = '22023';
    end if;

    -- 28: the design travels with the line (id from the catalogue, or the recorded name when the design has since been removed). create_order() validates it.
    v_design_id   := nullif(btrim(coalesce(v_line ->> 'designId', '')), '');
    v_design_name := nullif(btrim(coalesce(v_line ->> 'designName', '')), '');
    if v_design_id is not null then
      begin
        perform v_design_id::uuid;
      exception when invalid_text_representation then
        raise exception 'Invalid design' using errcode = '22023';
      end;
    end if;
    if v_design_name is not null and char_length(v_design_name) > 120 then
      raise exception 'A design name is at most 120 characters' using errcode = '22023';
    end if;

    -- 28: a product may appear on several lines only with different designs.
    v_pair := (v_line ->> 'productId') || '|' || coalesce(lower(v_design_id), 'n:' || lower(coalesce(v_design_name, '')));
    if v_pair = any (v_pairs) then
      raise exception 'Each product and design can be listed once; change its quantity instead' using errcode = '22023';
    end if;
    v_pairs := v_pairs || v_pair;

    v_item := jsonb_build_object('productId', v_line ->> 'productId', 'quantity', v_line -> 'quantity');
    if jsonb_typeof(v_line_price) = 'number' then
      v_item := v_item || jsonb_build_object('actualUnitPrice', v_line_price);
    end if;
    if v_design_id is not null then
      v_item := v_item || jsonb_build_object('designId', v_design_id);
    end if;
    if v_design_name is not null then
      v_item := v_item || jsonb_build_object('designName', v_design_name);
    end if;
    v_items := v_items || jsonb_build_array(v_item);
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
    'priceOverrideReason', p_payload ->> 'priceOverrideReason',   -- 27: the reason create_order needs when the confirmed price differs from an agreed price
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

-- Same signature, so the existing grants (authenticated only) are kept; restated for clarity.
revoke all on function public.convert_website_request(uuid, jsonb) from public, anon;
grant execute on function public.convert_website_request(uuid, jsonb) to authenticated;

commit;
