-- ============================================================================
-- EFZ - ROLLBACK of 19_website_request_delegation.sql
-- ----------------------------------------------------------------------------
-- Restores the exact post-18c definitions (copied from 18b) of every function 19
-- replaced, the 18 settings-read policy and timeline constraint, removes the two
-- 19 functions and the five 19 permissions (and their grants), and restores the
-- 18 label of manage_website_requests. Existing holders of manage_website_requests
-- keep it. assigned_to values stay (an 18 column; under the 18 rule an assignee
-- may read their request).
-- REFUSES (changes nothing) when assignment history exists ('assigned' events):
-- from then on the safe path is an app rollback plus a forward fix.
-- ============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
begin
  if to_regprocedure('public.assign_order_request(uuid,text)') is null then
    raise exception '19 rollback: 19 is not applied - nothing to roll back';
  end if;
  if exists (select 1 from public.order_request_events where event = 'assigned') then
    raise exception '19 rollback REFUSED: assignment history exists - use an app rollback plus a forward fix';
  end if;
end
$pre$;

drop function if exists public.assign_order_request(uuid, text);
drop function if exists public.website_request_assignees();

alter table public.order_request_events drop constraint if exists order_request_events_event_check;
alter table public.order_request_events add constraint order_request_events_event_check
  check (event = any (array['submitted', 'status_changed', 'converted', 'note_added', 'note_edited']));

create or replace function public.can_access_order_request(p_assigned_to text)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select public.has_permission('manage_website_requests')
      or (p_assigned_to is not null and p_assigned_to = public.current_profile_id());
$fn$;

create or replace function public.set_order_request_status(p_request_id uuid, p_to text, p_reason text default null)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_req    public.order_requests%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_label  text;
  v_msg    text;
begin
  select * into v_req from public.order_requests where id = p_request_id for update;
  if not found or not public.can_access_order_request(v_req.assigned_to) then
    raise exception 'Permission denied or unknown website request' using errcode = '42501';
  end if;

  if p_to = 'converted' then
    raise exception 'A request is converted only with Convert to Order' using errcode = 'WR409';
  end if;
  if (v_req.status::text, p_to) not in (('new', 'contacted'), ('new', 'confirmed'), ('new', 'rejected'),
                                        ('contacted', 'confirmed'), ('contacted', 'rejected'),
                                        ('confirmed', 'rejected')) then
    raise exception 'A % request cannot be marked %', v_req.status, p_to using errcode = 'WR409';
  end if;
  if p_to = 'rejected' and (v_reason is null or char_length(v_reason) > 500) then
    raise exception 'A reason (up to 500 characters) is required to reject a request' using errcode = '22023';
  end if;

  update public.order_requests
     set status            = p_to::public.order_request_status,
         status_changed_at = now(),
         handled_by        = public.current_profile_id(),
         rejected_reason   = case when p_to = 'rejected' then v_reason else rejected_reason end,
         updated_at        = now()
   where id = p_request_id;

  insert into public.order_request_events (request_id, event, from_status, to_status, actor_id, actor_name, note)
  values (p_request_id, 'status_changed', v_req.status::text, p_to, public.current_profile_id(),
          coalesce(public.current_profile_name(), ''), v_reason);

  v_label := 'REQ-' || upper(left(replace(p_request_id::text, '-', ''), 8));
  v_msg := case p_to
             when 'contacted' then format('Website request %s marked contacted', v_label)
             when 'confirmed' then format('Website request %s confirmed (from %s)', v_label, v_req.status)
             else format('Website request %s rejected (reason recorded on the request)', v_label)
           end;
  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'ORDER', v_msg,
          public.current_profile_id(), coalesce(public.current_profile_name(), ''), p_request_id::text,
          jsonb_build_object('source', 'db', 'event', 'website_request_status', 'requestId', p_request_id,
                             'fromStatus', v_req.status, 'toStatus', p_to));
end;
$fn$;

create or replace function public.add_order_request_note(p_request_id uuid, p_body text)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_req  public.order_requests%rowtype;
  v_body text := btrim(coalesce(p_body, ''));
  v_id   uuid;
begin
  select * into v_req from public.order_requests where id = p_request_id;
  if not found or not public.can_access_order_request(v_req.assigned_to) then
    raise exception 'Permission denied or unknown website request' using errcode = '42501';
  end if;
  if char_length(v_body) not between 1 and 2000 then
    raise exception 'A note must be 1 to 2000 characters' using errcode = '22023';
  end if;

  insert into public.order_request_notes (request_id, body, author_id, author_name)
  values (p_request_id, v_body, public.current_profile_id(), coalesce(public.current_profile_name(), ''))
  returning id into v_id;

  insert into public.order_request_events (request_id, event, actor_id, actor_name, details)
  values (p_request_id, 'note_added', public.current_profile_id(), coalesce(public.current_profile_name(), ''),
          jsonb_build_object('noteId', v_id));
  return v_id;
end;
$fn$;

create or replace function public.edit_order_request_note(p_note_id uuid, p_body text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_note public.order_request_notes%rowtype;
  v_req  public.order_requests%rowtype;
  v_body text := btrim(coalesce(p_body, ''));
begin
  select * into v_note from public.order_request_notes where id = p_note_id for update;
  if found then
    select * into v_req from public.order_requests where id = v_note.request_id;
  end if;
  if not found
     or not public.can_access_order_request(v_req.assigned_to)
     or not (public.is_super_admin() or v_note.author_id = public.current_profile_id()) then
    raise exception 'Permission denied or unknown note' using errcode = '42501';
  end if;
  if char_length(v_body) not between 1 and 2000 then
    raise exception 'A note must be 1 to 2000 characters' using errcode = '22023';
  end if;
  if v_body = v_note.body then
    return;
  end if;

  update public.order_request_notes
     set body = v_body, edited_by = public.current_profile_id(), updated_at = now()
   where id = p_note_id;

  insert into public.order_request_events (request_id, event, actor_id, actor_name, details)
  values (v_note.request_id, 'note_edited', public.current_profile_id(), coalesce(public.current_profile_name(), ''),
          jsonb_build_object('noteId', p_note_id, 'previous', v_note.body));
end;
$fn$;

create or replace function public.find_customers_by_phone(p_request_id uuid, p_phone text default null)
returns table (customer_id text, name text, phone_masked text, officer_id text, officer_name text, status text)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_req   public.order_requests%rowtype;
  v_canon text;
begin
  if not public.has_permission('manage_website_requests') then
    raise exception 'Permission denied: website requests' using errcode = '42501';
  end if;
  select * into v_req from public.order_requests where id = p_request_id;
  if not found then
    raise exception 'Permission denied or unknown website request' using errcode = '42501';
  end if;

  v_canon := case
               when nullif(btrim(coalesce(p_phone, '')), '') is not null
                 then public.normalize_phone(p_phone,
                        coalesce((select default_phone_country from public.website_request_settings where id), 'SO'))
               else coalesce(v_req.phone_canonical, public.normalize_phone(v_req.phone, 'SO'))
             end;
  if v_canon is null then
    return;
  end if;

  return query
    select c.id, c.name,
           case when char_length(c.phone) > 3 then repeat('*', char_length(c.phone) - 3) || right(c.phone, 3) else '***' end,
           c.marketing_officer_id, coalesce(p.name, ''), c.status::text
      from public.customers c
      left join public.profiles p on p.id = c.marketing_officer_id
     where public.customer_phone_canonical(c.phone) = v_canon
     order by (c.status = 'active') desc, c.name;
end;
$fn$;

create or replace function public.convert_website_request(p_request_id uuid, p_payload jsonb)
returns text
language plpgsql
volatile
security definer
set search_path = public
as $fn$
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
      if not public.has_permission('manage_website_requests') then
        raise exception 'Permission denied: only a request handler can set the initial owner' using errcode = '42501';
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

CREATE OR REPLACE FUNCTION public.grant_role_preset(p_user_id text, p_role public.user_role) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_codes text[];
begin
  v_codes := case p_role::text
    when 'Super Admin' then array[]::text[]   -- bypasses permission checks entirely

    when 'Manager' then array[
      'view_dashboard',
      'view_orders', 'create_orders', 'edit_orders',
      'view_products', 'add_products', 'edit_products',
      'view_inventory', 'adjust_stock',
      'view_customers', 'add_customers', 'edit_customers', 'view_all_customers',
      'view_reports', 'view_commissions', 'mark_commissions_paid',
      'view_audit_trail',
      'manage_website_requests'   -- 18: Manager handles website requests
    ]

    when 'Marketing Officer' then array[
      'view_dashboard',
      'view_orders', 'create_orders',
      'view_products',
      'add_customers', 'edit_customers', 'view_own_customers_only',
      'view_commissions'
    ]

    when 'Customer Service' then array[
      'view_dashboard',
      'view_orders', 'create_orders', 'edit_orders',
      'view_products',
      'view_customers', 'view_all_customers', 'add_customers', 'edit_customers'
    ]

    when 'Inventory Staff' then array[
      'view_dashboard',
      'view_orders',
      'view_products', 'add_products', 'edit_products',
      'view_inventory', 'adjust_stock'
    ]

    when 'Delivery Staff' then array[
      'view_dashboard',
      'view_orders', 'edit_orders',
      'view_customers'
    ]
  end;

  perform public.set_user_permissions(p_user_id, v_codes);
end;
$$;

drop policy if exists website_request_settings_select on public.website_request_settings;
create policy website_request_settings_select on public.website_request_settings
  for select to authenticated using (public.has_permission('manage_website_requests'));

delete from public.user_permissions
 where permission_code in ('view_website_requests', 'view_all_website_requests', 'assign_website_requests',
                           'reject_website_requests', 'convert_website_requests');
delete from public.permissions
 where code in ('view_website_requests', 'view_all_website_requests', 'assign_website_requests',
                'reject_website_requests', 'convert_website_requests');
update public.permissions set label = 'Handle website requests', category = 'Orders' where code = 'manage_website_requests';

do $post$
declare
  v_state text;
begin
  select string_agg(f || '=' || md5(pg_get_functiondef(to_regprocedure('public.' || f))), ',' order by f) into v_state
    from unnest(array['can_access_order_request(text)', 'set_order_request_status(uuid,text,text)',
                      'add_order_request_note(uuid,text)', 'edit_order_request_note(uuid,text)',
                      'find_customers_by_phone(uuid,text)', 'convert_website_request(uuid,jsonb)',
                      'grant_role_preset(text,user_role)']) f;
  if v_state <> 'add_order_request_note(uuid,text)=0c243d9f7ffbef9c21f1edf72336c748,'
              || 'can_access_order_request(text)=891b2f42140fdf411480fdca81eb0c77,'
              || 'convert_website_request(uuid,jsonb)=6e6949ce3e712803fcf80781000b50a6,'
              || 'edit_order_request_note(uuid,text)=eb4a8808459277a09e6dcd6b9a7cdf5b,'
              || 'find_customers_by_phone(uuid,text)=eaa6360b371b42ec2c8bd855aabb3f78,'
              || 'grant_role_preset(text,user_role)=c3386f22afe953c7436f54c50f015773,'
              || 'set_order_request_status(uuid,text,text)=f0310e94707f5637e45d993ac0fd2348' then
    raise exception '19 rollback post-check: functions are not the exact 18 definitions: % - aborting', v_state;
  end if;
  raise notice '19 rollback: exact post-18c definitions restored';
end
$post$;

commit;
