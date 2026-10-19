-- =============================================================================
-- ROLLBACK of migration 28. Staging first; Production only with the owner's explicit approval.
-- Restores convert_website_request(uuid, jsonb) to the migration-27 text (md5 fe992c8ab3edc37522d08e3e6eb41c9c once CR-stripped). Changes nothing else.
-- WHAT YOU LOSE: nothing stored. Orders converted while migration 28 was live keep their design_name, design id (order_price_resolutions) and prices; they are never rewritten.
-- AFTER ROLLBACK a conversion again needs a price on every line and drops the design (the old behaviour).
-- =============================================================================
begin;

set local lock_timeout = '30s';

do $guard$
begin
  if position('migration 28 marker' in pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure)) = 0
     and md5(replace(pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure), chr(13), '')) <> 'fe992c8ab3edc37522d08e3e6eb41c9c' then
    raise exception 'convert_website_request is neither the migration-28 nor the migration-27 definition; refusing to touch it';
  end if;
end
$guard$;

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

revoke all on function public.convert_website_request(uuid, jsonb) from public, anon;
grant execute on function public.convert_website_request(uuid, jsonb) to authenticated;

commit;
