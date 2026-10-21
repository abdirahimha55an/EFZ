-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 19 : delegated website-request permissions and assignment
-- ----------------------------------------------------------------------------
-- Run AFTER 18a, 18b and 18c. Apply to EFZ-Staging first. Idempotent: safe to
-- re-run. Forward only: 18a/18b/18c are not touched.
--
-- WHAT
--  permissions (flat codes, the existing model; Super Admin bypasses all):
--    view_website_requests       see requests - only those assigned to you, unless
--    view_all_website_requests   ... this scope code is held too (like view_all_customers)
--    manage_website_requests     (existing) notes and contacted/confirmed moves
--    assign_website_requests     assign / reassign / unassign; set a new customer's initial owner
--    reject_website_requests     reject with a recorded reason
--    convert_website_requests    convert through the unchanged create_order() (+ create_orders,
--                                + add_customers for a new customer, as before)
--  existing holders of manage_website_requests keep everything they had: they are
--  granted the five new codes. Nobody else gains anything.
--  can_access_order_request() (the one rule behind order_requests_select, the
--  child-table policies, realtime delivery and every request RPC) becomes:
--    view_website_requests AND (view_all_website_requests OR assigned to me).
--  new: assign_order_request(), website_request_assignees(); event 'assigned'.
--  grant_role_preset(): Manager no longer receives request access automatically.
--  find_customers_by_phone(): needs convert_website_requests and returns only
--  customers the caller may already see.
--  rows: 5 permissions rows, the label of manage_website_requests, the backfill
--  grants. No request, order, payment, stock or customer row is changed.
--
-- Rollback: supabase/rollback/19_rollback.sql.
-- ============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
declare
  v_state text;
begin
  if to_regprocedure('public.submit_order_request(jsonb)') is null
     or to_regprocedure('public.order_requests_legacy_admission()') is not null
     or exists (select 1 from pg_policy where polrelid = 'public.order_requests'::regclass and polname = 'order_requests_insert_public') then
    raise exception '19: 18a/18b/18c are not all applied - refusing';
  end if;

  select string_agg(f || '=' || md5(pg_get_functiondef(to_regprocedure('public.' || f))), ',' order by f) into v_state
    from unnest(array['can_access_order_request(text)', 'set_order_request_status(uuid,text,text)',
                      'add_order_request_note(uuid,text)', 'edit_order_request_note(uuid,text)',
                      'find_customers_by_phone(uuid,text)', 'convert_website_request(uuid,jsonb)',
                      'grant_role_preset(text,user_role)']) f;

  if v_state = 'add_order_request_note(uuid,text)=0c243d9f7ffbef9c21f1edf72336c748,'
              || 'can_access_order_request(text)=891b2f42140fdf411480fdca81eb0c77,'
              || 'convert_website_request(uuid,jsonb)=6e6949ce3e712803fcf80781000b50a6,'
              || 'edit_order_request_note(uuid,text)=eb4a8808459277a09e6dcd6b9a7cdf5b,'
              || 'find_customers_by_phone(uuid,text)=eaa6360b371b42ec2c8bd855aabb3f78,'
              || 'grant_role_preset(text,user_role)=c3386f22afe953c7436f54c50f015773,'
              || 'set_order_request_status(uuid,text,text)=f0310e94707f5637e45d993ac0fd2348' then
    raise notice '19: reviewed post-18c state - applying';
  elsif to_regprocedure('public.assign_order_request(uuid,text)') is not null then
    raise notice '19: already applied - re-applying (idempotent)';
  else
    raise exception '19: unexpected function state - refusing: %', v_state;
  end if;
end
$pre$;

-- ============================================================================
-- 1. PERMISSIONS (existing model) + backfill for existing request handlers
-- ============================================================================

insert into public.permissions (code, label, category, sort_order) values
  ('view_website_requests',     'View website requests (assigned to me)', 'Website Requests', 26),
  ('view_all_website_requests', 'View all website requests',              'Website Requests', 27),
  ('assign_website_requests',   'Assign website requests',                'Website Requests', 28),
  ('reject_website_requests',   'Reject website requests',                'Website Requests', 29),
  ('convert_website_requests',  'Convert website requests to orders',     'Website Requests', 30)
on conflict (code) do nothing;

update public.permissions
   set label = 'Work website requests (notes, contacted, confirmed)', category = 'Website Requests'
 where code = 'manage_website_requests';

-- Whoever could handle requests before 19 keeps exactly that access.
insert into public.user_permissions (user_id, permission_code)
select up.user_id, c.code
  from public.user_permissions up
 cross join unnest(array['view_website_requests', 'view_all_website_requests', 'assign_website_requests',
                         'reject_website_requests', 'convert_website_requests']) as c(code)
 where up.permission_code = 'manage_website_requests'
on conflict do nothing;

-- ============================================================================
-- 2. TIMELINE: assignment events
-- ============================================================================

alter table public.order_request_events drop constraint if exists order_request_events_event_check;
alter table public.order_request_events add constraint order_request_events_event_check
  check (event = any (array['submitted', 'status_changed', 'converted', 'note_added', 'note_edited', 'assigned']));

-- ============================================================================
-- 3. THE ACCESS RULE (behind order_requests_select, the child-table policies,
--    realtime delivery and every request RPC). Revocation is immediate: it is
--    evaluated on every statement.
-- ============================================================================

create or replace function public.can_access_order_request(p_assigned_to text)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select public.has_permission('view_website_requests')
     and (public.has_permission('view_all_website_requests')
          or (p_assigned_to is not null and p_assigned_to = public.current_profile_id()));
$fn$;

-- ============================================================================
-- 4. REQUEST FUNCTIONS (deployed 18b text; 19 edits marked)
-- ============================================================================

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
  -- 19: rejecting and the other status moves are separate capabilities.
  if p_to = 'rejected' then
    if not public.has_permission('reject_website_requests') then
    raise exception 'Permission denied: reject_website_requests is required' using errcode = '42501';
    end if;
  elsif not public.has_permission('manage_website_requests') then
    raise exception 'Permission denied: manage_website_requests is required' using errcode = '42501';
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
  if not public.has_permission('manage_website_requests') then   -- 19
    raise exception 'Permission denied: manage_website_requests is required' using errcode = '42501';
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
     or not (public.is_super_admin() or v_note.author_id = public.current_profile_id())
     or not public.has_permission('manage_website_requests') then   -- 19
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
  if not public.has_permission('convert_website_requests') then
    raise exception 'Permission denied: website requests' using errcode = '42501';
  end if;
  select * into v_req from public.order_requests where id = p_request_id;
  if not found or not public.can_access_order_request(v_req.assigned_to) then
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
       and (public.has_permission('view_all_customers') or public.has_permission('view_customers')
            or (public.has_permission('view_own_customers_only') and c.marketing_officer_id = public.current_profile_id()))
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
-- ============================================================================
-- 5. ASSIGNMENT
-- ============================================================================

-- Staff a request can be assigned to: active, and allowed to see website requests.
create or replace function public.website_request_assignees()
returns table (id text, name text, role text)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not public.has_permission('assign_website_requests') then
    raise exception 'Permission denied: assign_website_requests is required' using errcode = '42501';
  end if;
  return query
    select p.id, p.name, p.role::text
      from public.profiles p
     where p.status = 'active'
       and (p.role = 'Super Admin'
            or exists (select 1 from public.user_permissions up
                        where up.user_id = p.id and up.permission_code = 'view_website_requests'))
     order by p.name, p.id;
end;
$fn$;

-- Assign, reassign (p_assignee = another id) or unassign (NULL). Recorded on the
-- timeline and in the audit log; the new assignee gets a notification.
create or replace function public.assign_order_request(p_request_id uuid, p_assignee text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_req        public.order_requests%rowtype;
  v_to         text := nullif(btrim(coalesce(p_assignee, '')), '');
  v_to_name    text;
  v_from_name  text;
  v_actor      text := public.current_profile_id();
  v_actor_name text := coalesce(public.current_profile_name(), '');
  v_label      text := 'REQ-' || upper(left(replace(p_request_id::text, '-', ''), 8));
begin
  select * into v_req from public.order_requests where id = p_request_id for update;
  if not found or not public.can_access_order_request(v_req.assigned_to)
     or not public.has_permission('assign_website_requests') then
    raise exception 'Permission denied or unknown website request' using errcode = '42501';
  end if;
  if v_req.status in ('converted', 'rejected') then
    raise exception 'A % request can no longer be assigned', v_req.status using errcode = 'WR409';
  end if;

  if v_to is not null then
    select p.name into v_to_name
      from public.profiles p
     where p.id = v_to and p.status = 'active'
       and (p.role = 'Super Admin'
            or exists (select 1 from public.user_permissions up
                        where up.user_id = p.id and up.permission_code = 'view_website_requests'));
    if not found then
      raise exception 'The assignee must be an active staff member allowed to view website requests'
        using errcode = '22023';
    end if;
  end if;

  if v_to is not distinct from v_req.assigned_to then
    return;   -- nothing changes, nothing is recorded
  end if;
  select name into v_from_name from public.profiles where id = v_req.assigned_to;

  update public.order_requests set assigned_to = v_to, updated_at = now() where id = p_request_id;

  insert into public.order_request_events (request_id, event, actor_id, actor_name, details)
  values (p_request_id, 'assigned', v_actor, v_actor_name,
          jsonb_build_object('from', v_req.assigned_to, 'fromName', coalesce(v_from_name, ''),
                             'to', v_to, 'toName', coalesce(v_to_name, '')));

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'ORDER',
          case when v_to is null then format('Website request %s unassigned', v_label)
               when v_req.assigned_to is null then format('Website request %s assigned to %s', v_label, v_to_name)
               else format('Website request %s reassigned from %s to %s', v_label, coalesce(v_from_name, v_req.assigned_to), v_to_name) end,
          v_actor, v_actor_name, p_request_id::text,
          jsonb_build_object('source', 'db', 'event', 'website_request_assigned', 'requestId', p_request_id,
                             'from', v_req.assigned_to, 'to', v_to));

  -- The assignee's own notification (reference only - no visitor details).
  if v_to is not null and v_to is distinct from v_actor then
    insert into public.notifications (id, title, message, type, user_id)
    values ('reqasg-' || replace(gen_random_uuid()::text, '-', ''), 'Website request assigned to you',
            format('%s was assigned to you by %s.', v_label, coalesce(nullif(v_actor_name, ''), 'a Super Admin')),
            'order', v_to);
  end if;
end;
$fn$;

-- ============================================================================
-- 6. ROLE PRESET: no automatic request access (deployed text; 19 edit marked)
-- ============================================================================

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
      'view_audit_trail'
      -- 19: website-request capabilities are granted explicitly, never by role.
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
-- ============================================================================
-- 7. SETTINGS READ: anyone who may view requests (updates stay Super Admin only)
-- ============================================================================

drop policy if exists website_request_settings_select on public.website_request_settings;
create policy website_request_settings_select on public.website_request_settings
  for select to authenticated using (public.has_permission('view_website_requests'));

-- ============================================================================
-- 8. GRANTS
-- ============================================================================

revoke all on function public.website_request_assignees()        from public, anon, authenticated;
revoke all on function public.assign_order_request(uuid, text)    from public, anon, authenticated;
grant execute on function public.website_request_assignees()      to authenticated;
grant execute on function public.assign_order_request(uuid, text) to authenticated;

-- ============================================================================
-- 9. POST-CHECK
-- ============================================================================

do $post$
declare
  v_problem text;
begin
  select string_agg(x, ', ') into v_problem from (
    select 'permission ' || c || ' missing' as x
      from unnest(array['view_website_requests', 'view_all_website_requests', 'manage_website_requests',
                        'assign_website_requests', 'reject_website_requests', 'convert_website_requests']) c
     where not exists (select 1 from public.permissions p where p.code = c)
    union all
    select 'holder ' || up.user_id || ' lacks ' || c
      from public.user_permissions up
     cross join unnest(array['view_website_requests', 'view_all_website_requests', 'assign_website_requests',
                             'reject_website_requests', 'convert_website_requests']) c
     where up.permission_code = 'manage_website_requests'
       and not exists (select 1 from public.user_permissions u2 where u2.user_id = up.user_id and u2.permission_code = c)
    union all
    select 'anon can execute ' || f
      from unnest(array['public.assign_order_request(uuid,text)', 'public.website_request_assignees()',
                        'public.set_order_request_status(uuid,text,text)', 'public.convert_website_request(uuid,jsonb)']) f
     where has_function_privilege('anon', f, 'EXECUTE')
    union all
    select 'anon cannot execute submit_order_request'
     where not has_function_privilege('anon', 'public.submit_order_request(jsonb)', 'EXECUTE')
    union all
    select 'legacy insert path is back'
     where exists (select 1 from pg_policy where polrelid = 'public.order_requests'::regclass and polname = 'order_requests_insert_public')
        or has_table_privilege('anon', 'public.order_requests', 'INSERT')
  ) q;
  if v_problem is not null then
    raise exception '19 post-check failed: % - aborting', v_problem;
  end if;
  raise notice '19: delegated website-request permissions installed';
end
$post$;

commit;
