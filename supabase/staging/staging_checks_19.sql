-- ============================================================================
-- EFZ - STAGING CHECKS FOR MIGRATION 19   (EFZ-STAGING ONLY - rollback-only)
-- ----------------------------------------------------------------------------
-- psql only (uses \gset). Run in the guarded Staging window as the project's
-- postgres role, after 19. ONE transaction that ends in ROLLBACK: every grant,
-- request, assignment, note, status change, notification and the converted
-- order it creates disappears again.
-- Actors (PostgREST-style role + JWT claims, as in staging_checks_18):
--   SA = u-stg-admin (Super Admin)            M = u-stg-ops (Manager, pre-19 holder)
--   C  = u-stg-inventory  granted here: view + view_all + reject       (all-request delegate)
--   D  = u-stg-delivery   granted here: view + manage (+ convert later)  (assigned-only delegate)
--   O  = u-stg-officer1   Marketing Officer, no request capability (granted view + convert only in F)
-- Exit status: 0 = every check PASSED; non-zero = a guard refused or a check FAILED.
-- ============================================================================
\set ON_ERROR_STOP on
\pset pager off
begin;
set local lock_timeout = '10s';
set local statement_timeout = '180s';
set local search_path = public, extensions;

-- 0. ENVIRONMENT GUARD (fail closed) -----------------------------------------
do $guard$
begin
  if current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'REFUSED: READ COMMITTED required (got %)', current_setting('transaction_isolation');
  end if;
  if not exists (select 1 from public.products where id like 'prod-stg-%')
     or not exists (select 1 from public.profiles where id = 'u-stg-admin' and role = 'Super Admin')
     or exists (select 1 from public.products where id = 'prod-1787244881309')
     or exists (select 1 from public.profiles where id = 'u-1') then
    raise exception 'REFUSED: not EFZ-Staging (synthetic markers missing or Production markers present)';
  end if;
  if to_regprocedure('public.assign_order_request(uuid,text)') is null then
    raise exception 'REFUSED: Migration 19 not applied';
  end if;
end
$guard$;

-- 1. HELPERS (inside the transaction; rolled back) ----------------------------
create schema m19check;
grant usage on schema m19check to anon, authenticated, service_role;
create table m19check.r (n serial primary key, section text, id text, name text, result text, info text);
grant all on m19check.r to anon, authenticated, service_role;
grant usage on sequence m19check.r_n_seq to anon, authenticated, service_role;

create function m19check.as_(p_who text) returns void language plpgsql as $f$
begin
  perform set_config('role', 'none', true);
  if p_who = 'owner' then
    perform set_config('request.jwt.claims', '', true);
  elsif p_who in ('anon', 'service_role') then
    perform set_config('request.jwt.claims', json_build_object('role', p_who)::text, true);
    perform set_config('role', p_who, true);
  else
    if not exists (select 1 from public.profiles where id = p_who and auth_user_id is not null) then
      raise exception 'STOPPED: staff user % is missing or has no sign-in', p_who;
    end if;
    perform set_config('request.jwt.claims',
      json_build_object('sub', (select auth_user_id from public.profiles where id = p_who), 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);
  end if;
end $f$;

create function m19check.try(p_sql text) returns text language plpgsql as $f$
declare v text;
begin
  execute p_sql into v;
  return 'OK|' || coalesce(v, '');
exception when others then
  return sqlstate || '|' || sqlerrm;
end $f$;

create function m19check.ok(p_section text, p_id text, p_name text, p_got text, p_want text) returns void language sql as $f$
  insert into m19check.r (section, id, name, result, info)
  values (p_section, p_id, p_name,
          case when starts_with(coalesce(p_got, '<null>'), p_want) then 'PASS' else 'FAIL' end,
          left(coalesce(p_got, '<null>'), 240) || case when starts_with(coalesce(p_got, '<null>'), p_want) then '' else '  | expected: ' || p_want end);
$f$;

create function m19check.need(p_value text, p_label text) returns void language plpgsql as $f$
begin
  if p_value is null or p_value !~ '^[0-9A-Za-z-]+$' then
    raise exception 'STOPPED: % was not produced (got %). Checks failed before the stop: %', p_label, coalesce(p_value, 'null'),
      coalesce((select string_agg(id || ' [' || info || ']', '; ' order by n) from m19check.r where result <> 'PASS'), 'none');
  end if;
end $f$;

-- count of requests visible to the CURRENT role among the given ids
create function m19check.seen(p_ids uuid[]) returns text language sql as $f$
  select count(*)::text from public.order_requests where id = any(p_ids);
$f$;

grant execute on all functions in schema m19check to anon, authenticated, service_role;

-- 2. PREREQUISITES (fail closed) ----------------------------------------------
do $pre$
declare v_missing text;
begin
  select string_agg(a, ', ') into v_missing
    from unnest(array['u-stg-admin', 'u-stg-manager', 'u-stg-ops', 'u-stg-officer1', 'u-stg-inventory', 'u-stg-delivery']) a
   where not exists (select 1 from public.profiles p where p.id = a and p.status = 'active' and p.auth_user_id is not null);
  if v_missing is not null then
    raise exception 'PREREQUISITE: staging users missing, inactive or without sign-in: %', v_missing;
  end if;
  if exists (select 1 from public.user_permissions where user_id in ('u-stg-inventory', 'u-stg-delivery', 'u-stg-officer1')
              and permission_code like '%website_requests') then
    raise exception 'PREREQUISITE: C, D or O already hold a website-request permission';
  end if;
  if exists (select 1 from public.order_requests r where r.phone_canonical in ('+252619919001', '+252619919002', '+252619919003')) then
    raise exception 'PREREQUISITE: the test phone numbers 061991900x are already in use';
  end if;
  if not exists (select 1 from public.customers where id = 'cust-stg-alpha') then
    raise exception 'PREREQUISITE: customer cust-stg-alpha is missing';
  end if;
  if exists (select 1 from public.customers c where c.id in ('cust-stg19-own', 'cust-stg19-other')
              or public.customer_phone_canonical(c.phone) in ('+252619919011', '+252619919012'))
     or not exists (select 1 from public.profiles where id = 'u-stg-officer2') then
    raise exception 'PREREQUISITE: STG-19 customer ids/phones in use, or u-stg-officer2 missing';
  end if;
end
$pre$;

select (select id from public.products p where p.is_active and p.stock - public.product_committed_quantity(p.id) >= 3 order by id limit 1) as p1,
       (select string_agg(id || ':' || stock, ',' order by id) from public.products)
         || '|' || (select count(*) from public.stock_movements)
         || '|' || (select count(*) || ':' || coalesce(sum(amount), 0) from public.payments) as biz_before,
       (select string_agg(id::text || ':' || md5(row(r.*)::text), ',' order by id) from public.order_requests r) as requests_before,
       (select count(*) from public.notifications) as notif_before,
       (select array_to_string(array_agg(permission_code order by permission_code), ',') from public.user_permissions where user_id = 'u-stg-delivery') as d_codes,
       (select array_to_string(array_agg(permission_code order by permission_code), ',') from public.user_permissions where user_id = 'u-stg-inventory') as c_codes,
       (select array_to_string(array_agg(permission_code order by permission_code), ',') from public.user_permissions where user_id = 'u-stg-officer1') as o_codes,
       '0619919011' as o_phone, '0619919012' as other_phone
\gset
-- Two synthetic customers with valid phones for the scope check (F1/F2): one owned by O, one by another officer.
-- The Staging seed customers carry placeholder phones that do not canonicalize. Rolled back with everything else.
insert into public.customers (id, name, email, phone, notes, marketing_officer_id, registered_by, status) values
  ('cust-stg19-own',   'STG-19 own',   '', '619919011', '', 'u-stg-officer1', 'u-stg-admin', 'active'),
  ('cust-stg19-other', 'STG-19 other', '', '619919012', '', 'u-stg-officer2', 'u-stg-admin', 'active');
select m19check.need(:'p1', 'product 1');

-- 3. MIGRATION RESULT (read-only) -------------------------------------------
select m19check.ok('model', 'P1', 'pre-19 holders (both Managers) were granted the five new codes',
  (select string_agg(user_id || ':' || n, ',' order by user_id) from (
     select up.user_id, count(*) n from public.user_permissions up
      where up.permission_code in ('view_website_requests', 'view_all_website_requests', 'assign_website_requests', 'reject_website_requests', 'convert_website_requests')
        and up.user_id in ('u-stg-manager', 'u-stg-ops') group by up.user_id) x), 'u-stg-manager:5,u-stg-ops:5');
select m19check.ok('model', 'P2', 'nobody else holds a new code (no role-based grant)',
  (select count(distinct user_id)::text from public.user_permissions
    where permission_code in ('view_website_requests', 'view_all_website_requests', 'assign_website_requests', 'reject_website_requests', 'convert_website_requests')
      and user_id not in (select user_id from public.user_permissions where permission_code = 'manage_website_requests')), '0');
select m19check.ok('model', 'P3', 'Manager role preset no longer grants request access',
  (pg_get_functiondef('public.grant_role_preset(text, public.user_role)'::regprocedure) like '%''manage_website_requests''%')::text, 'false');
select m19check.ok('model', 'P4', 'six permission rows, category Website Requests',
  (select count(*)::text from public.permissions where category = 'Website Requests'), '6');

-- 4. DELEGATION THROUGH THE EXISTING API -------------------------------------
select m19check.as_('u-stg-ops');
select m19check.ok('grant', 'G1', 'a Manager (no manage_users) cannot delegate',
  split_part(m19check.try($q$select public.set_user_permissions('u-stg-delivery', array['view_website_requests'])::text$q$), '|', 1), '42501');
select m19check.as_('u-stg-admin');
select m19check.ok('grant', 'G2', 'Super Admin delegates: D = view + manage, C = view + view_all + reject',
  split_part(m19check.try(format($q$select public.set_user_permissions('u-stg-delivery', string_to_array(%L, ',') || array['view_website_requests', 'manage_website_requests'])::text$q$, :'d_codes')), '|', 1)
  || ',' || split_part(m19check.try(format($q$select public.set_user_permissions('u-stg-inventory', string_to_array(%L, ',') || array['view_website_requests', 'view_all_website_requests', 'reject_website_requests'])::text$q$, :'c_codes')), '|', 1),
  'OK,OK');

-- three fresh requests from the public path
select m19check.as_('anon');
select split_part(m19check.try(format($q$select public.submit_order_request(jsonb_build_object('customerName', 'STG-19 A', 'phone', '0619919001',
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 1))))::text$q$, :'p1')), '|', 2) as ra,
       split_part(m19check.try(format($q$select public.submit_order_request(jsonb_build_object('customerName', 'STG-19 B', 'phone', '0619919002',
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 1))))::text$q$, :'p1')), '|', 2) as rb,
       split_part(m19check.try(format($q$select public.submit_order_request(jsonb_build_object('customerName', 'STG-19 C', 'phone', '0619919003',
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 1))))::text$q$, :'p1')), '|', 2) as rc
\gset
select m19check.need(:'ra', 'request A'), m19check.need(:'rb', 'request B'), m19check.need(:'rc', 'request C');
select m19check.ok('rpc', 'X1', 'anon cannot assign or list assignees',
  split_part(m19check.try(format($q$select public.assign_order_request(%L, 'u-stg-delivery')::text$q$, :'ra')), '|', 1) || ','
  || split_part(m19check.try($q$select count(*)::text from public.website_request_assignees()$q$), '|', 1), '42501,42501');

-- 5. VISIBILITY ----------------------------------------------------------------
select m19check.as_('u-stg-admin');
select m19check.ok('view', 'V1', 'Super Admin sees A, B, C', m19check.seen(array[:'ra', :'rb', :'rc']::uuid[]), '3');
select m19check.as_('u-stg-ops');
select m19check.ok('view', 'V2', 'Manager (view_all) sees A, B, C', m19check.seen(array[:'ra', :'rb', :'rc']::uuid[]), '3');
select m19check.as_('u-stg-inventory');
select m19check.ok('view', 'V3', 'C (view_all) sees A, B, C', m19check.seen(array[:'ra', :'rb', :'rc']::uuid[]), '3');
select m19check.as_('u-stg-delivery');
select m19check.ok('view', 'V4', 'D (assigned-only, nothing assigned) sees none; settings readable',
  m19check.seen(array[:'ra', :'rb', :'rc']::uuid[]) || ' ' || m19check.try('select count(*)::text from public.website_request_settings'), '0 OK|1');
select m19check.ok('view', 'V5', 'D (unassigned) cannot act on A',
  split_part(m19check.try(format($q$select public.set_order_request_status(%L, 'contacted')::text$q$, :'ra')), '|', 1), '42501');
select m19check.as_('u-stg-officer1');
select m19check.ok('view', 'V6', 'Marketing Officer: no requests, lines, events, settings',
  m19check.seen(array[:'ra', :'rb', :'rc']::uuid[])
  || '/' || (select count(*) from public.order_request_lines where request_id in (:'ra', :'rb', :'rc'))
  || '/' || (select count(*) from public.order_request_events where request_id in (:'ra', :'rb', :'rc'))
  || '/' || (select count(*) from public.website_request_settings), '0/0/0/0');
select m19check.ok('view', 'V7', 'Marketing Officer: status, note, assign, assignees, customer search, convert all denied',
  split_part(m19check.try(format($q$select public.set_order_request_status(%L, 'contacted')::text$q$, :'ra')), '|', 1) || ','
  || split_part(m19check.try(format($q$select public.add_order_request_note(%L, 'x')::text$q$, :'ra')), '|', 1) || ','
  || split_part(m19check.try(format($q$select public.assign_order_request(%L, 'u-stg-officer1')::text$q$, :'ra')), '|', 1) || ','
  || split_part(m19check.try($q$select count(*)::text from public.website_request_assignees()$q$), '|', 1) || ','
  || split_part(m19check.try(format($q$select count(*)::text from public.find_customers_by_phone(%L)$q$, :'ra')), '|', 1) || ','
  || split_part(m19check.try(format($q$select public.convert_website_request(%L, '{}'::jsonb)::text$q$, :'ra')), '|', 1),
  '42501,42501,42501,42501,42501,42501');

-- 6. ASSIGNMENT ------------------------------------------------------------------
select m19check.as_('u-stg-ops');
select m19check.ok('assign', 'A0', 'assignees = active staff allowed to view requests (D, C, Managers, SA; not O)',
  m19check.try($q$select string_agg(id, ',' order by id) from public.website_request_assignees() where id like 'u-stg-%'$q$),
  'OK|u-stg-admin,u-stg-delivery,u-stg-inventory,u-stg-manager,u-stg-ops');
select m19check.as_('u-stg-admin');
select m19check.ok('assign', 'A1', 'Super Admin assigns A to D',
  m19check.try(format($q$select public.assign_order_request(%L, 'u-stg-delivery')::text$q$, :'ra')), 'OK|');
select m19check.as_('owner');
select m19check.ok('assign', 'A2', 'A: assigned_to D; event assigned (to D, by SA); audit line; D notified once, reference only',
  (select coalesce(assigned_to, 'null') from public.order_requests where id = :'ra')
  || ' ' || (select count(*) || ':' || max(details ->> 'to') || ':' || max(actor_id) from public.order_request_events where request_id = :'ra' and event = 'assigned')
  || ' ' || (select count(*) from public.system_logs where target_id = :'ra' and message like 'Website request REQ-% assigned to %' and origin = 'database')
  || ' ' || (select count(*) || ':' || bool_and(message ~ '^REQ-[0-9A-F]{8} was assigned to you by ') from public.notifications
              where user_id = 'u-stg-delivery' and title = 'Website request assigned to you'),
  'u-stg-delivery 1:u-stg-delivery:u-stg-admin 1 1:true');
select m19check.as_('u-stg-delivery');
select m19check.ok('assign', 'A3', 'D now sees A only, with its lines and timeline',
  m19check.seen(array[:'ra', :'rb', :'rc']::uuid[])
  || '/' || (select count(*) from public.order_request_lines where request_id = :'ra')
  || '/' || (select count(*) from public.order_request_events where request_id = :'ra'), '1/1/2');
select m19check.ok('assign', 'A4', 'D (no assign capability) cannot reassign',
  split_part(m19check.try(format($q$select public.assign_order_request(%L, 'u-stg-inventory')::text$q$, :'ra')), '|', 1), '42501');
select m19check.as_('u-stg-officer1');
select m19check.ok('assign', 'A5', 'the assignment notification is D''s alone',
  (select count(*)::text from public.notifications where title = 'Website request assigned to you'), '0');
select m19check.as_('u-stg-ops');
select m19check.ok('assign', 'A6', 'assigning to someone without view_website_requests is refused',
  split_part(m19check.try(format($q$select public.assign_order_request(%L, 'u-stg-officer1')::text$q$, :'ra')), '|', 1), '22023');
select m19check.ok('assign', 'A7', 'Manager reassigns A from D to C',
  m19check.try(format($q$select public.assign_order_request(%L, 'u-stg-inventory')::text$q$, :'ra')), 'OK|');
select m19check.as_('u-stg-delivery');
select m19check.ok('assign', 'A8', 'D loses A immediately after the reassignment', m19check.seen(array[:'ra']::uuid[]), '0');
select m19check.as_('u-stg-inventory');
select m19check.ok('assign', 'A9', 'C (view_all, no assign capability) cannot unassign',
  split_part(m19check.try(format($q$select public.assign_order_request(%L, null)::text$q$, :'ra')), '|', 1), '42501');
select m19check.as_('u-stg-ops');
select m19check.ok('assign', 'A10', 'Manager unassigns A; same assignee twice is a no-op',
  m19check.try(format($q$select public.assign_order_request(%L, null)::text$q$, :'ra')) || ' '
  || m19check.try(format($q$select public.assign_order_request(%L, null)::text$q$, :'ra')), 'OK| OK|');
select m19check.as_('owner');
select m19check.ok('assign', 'A11', 'A timeline: submitted, assigned D, assigned C, unassigned; audit: assigned, reassigned, unassigned',
  (select string_agg(event || ':' || coalesce(details ->> 'to', '-'), ',' order by seq) from public.order_request_events where request_id = :'ra')
  -- one transaction = one timestamp, so the audit verbs are compared as a sorted set
  || ' ' || (select string_agg(regexp_replace(message, '^Website request REQ-[0-9A-F]{8} (\w+).*$', '\1'), ',' order by 1)
               from public.system_logs where target_id = :'ra' and message like 'Website request REQ-%' and message not like '%received%'),
  'submitted:-,assigned:u-stg-delivery,assigned:u-stg-inventory,assigned:- assigned,reassigned,unassigned');

-- 7. STATUS, REJECTION, NOTES ----------------------------------------------------
select m19check.as_('u-stg-admin');
select m19check.try(format($q$select public.assign_order_request(%L, 'u-stg-delivery')::text$q$, :'rb')) as asg_b \gset
select m19check.as_('u-stg-delivery');
select m19check.ok('status', 'S1', 'D (manage) marks its request contacted; cannot reject (no reject capability)',
  m19check.try(format($q$select public.set_order_request_status(%L, 'contacted')::text$q$, :'rb')) || ' '
  || split_part(m19check.try(format($q$select public.set_order_request_status(%L, 'rejected', 'test')::text$q$, :'rb')), '|', 1), 'OK| 42501');
select m19check.ok('notes', 'N1', 'D adds a note on its request',
  left(m19check.try(format($q$select public.add_order_request_note(%L, 'STG-19 called')::text$q$, :'rb')), 3), 'OK|');
select m19check.as_('u-stg-inventory');
select m19check.ok('status', 'S2', 'C (no manage) cannot mark contacted or add notes; C rejects B with a reason',
  split_part(m19check.try(format($q$select public.set_order_request_status(%L, 'contacted')::text$q$, :'rc')), '|', 1) || ' '
  || split_part(m19check.try(format($q$select public.add_order_request_note(%L, 'x')::text$q$, :'rc')), '|', 1) || ' '
  || m19check.try(format($q$select public.set_order_request_status(%L, 'rejected', 'STG-19 duplicate')::text$q$, :'rb')),
  '42501 42501 OK|');
select m19check.ok('status', 'S3', 'reject without a reason is refused',
  split_part(m19check.try(format($q$select public.set_order_request_status(%L, 'rejected')::text$q$, :'rc')), '|', 1), '22023');
select m19check.as_('u-stg-ops');
select m19check.ok('status', 'S4', 'a rejected request can no longer be assigned',
  split_part(m19check.try(format($q$select public.assign_order_request(%L, 'u-stg-inventory')::text$q$, :'rb')), '|', 1), 'WR409');
select m19check.as_('owner');
select m19check.ok('status', 'S5', 'B: rejected by C with the reason; timeline submitted, assigned, contacted, note, rejected',
  (select status || ':' || rejected_reason || ':' || handled_by from public.order_requests where id = :'rb')
  || ' ' || (select string_agg(event || coalesce(':' || to_status, ''), ',' order by seq) from public.order_request_events where request_id = :'rb'),
  'rejected:STG-19 duplicate:u-stg-inventory submitted:new,assigned,status_changed:contacted,note_added,status_changed:rejected');
select m19check.as_('u-stg-delivery');
select m19check.ok('notes', 'N2', 'D sees B''s note but nothing of C',
  (select count(*) from public.order_request_notes where request_id = :'rb') || '/' || m19check.seen(array[:'rc']::uuid[]), '1/0');

-- 8. CONVERSION --------------------------------------------------------------------
select m19check.as_('u-stg-admin');
select m19check.try(format($q$select public.assign_order_request(%L, 'u-stg-delivery')::text$q$, :'rc')) as asg_c,
       m19check.try(format($q$select public.set_order_request_status(%L, 'confirmed')::text$q$, :'rc')) as conf_c \gset
select m19check.as_('u-stg-delivery');
select m19check.ok('convert', 'C1', 'D without convert capability: no customer search, no conversion',
  split_part(m19check.try(format($q$select count(*)::text from public.find_customers_by_phone(%L)$q$, :'rc')), '|', 1) || ' '
  || split_part(m19check.try(format($q$select public.convert_website_request(%L, jsonb_build_object('customerId', 'cust-stg-alpha',
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 1, 'actualUnitPrice', 15))))::text$q$, :'rc', :'p1')), '|', 1),
  '42501 42501');
select m19check.as_('u-stg-admin');
select m19check.try(format($q$select public.set_user_permissions('u-stg-delivery', string_to_array(%L, ',') || array['view_website_requests', 'manage_website_requests', 'convert_website_requests'])::text$q$, :'d_codes')) as g3 \gset
select m19check.as_('u-stg-delivery');
select m19check.ok('convert', 'C2', 'D with convert but without create_orders: refused by create_order() itself',
  split_part(m19check.try(format($q$select public.convert_website_request(%L, jsonb_build_object('customerId', 'cust-stg-alpha',
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 1, 'actualUnitPrice', 15))))::text$q$, :'rc', :'p1')), '|', 1),
  '42501');
select m19check.ok('convert', 'C3', 'D cannot set a new customer''s initial owner (needs assign capability)',
  split_part(m19check.try(format($q$select public.convert_website_request(%L, jsonb_build_object('newCustomer', jsonb_build_object('name', 'STG-19 new', 'phone', '0619919003', 'ownerOfficerId', 'u-stg-officer1'),
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 1, 'actualUnitPrice', 15))))::text$q$, :'rc', :'p1')), '|', 1),
  '42501');
select m19check.as_('u-stg-admin');
select m19check.try(format($q$select public.set_user_permissions('u-stg-delivery', string_to_array(%L, ',') || array['view_website_requests', 'manage_website_requests', 'convert_website_requests', 'create_orders'])::text$q$, :'d_codes')) as g4 \gset
select m19check.as_('u-stg-delivery');
select split_part(m19check.try(format($q$select public.convert_website_request(%L, jsonb_build_object('customerId', 'cust-stg-alpha',
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 1, 'actualUnitPrice', 15))))::text$q$, :'rc', :'p1')), '|', 2) as ord
\gset
select m19check.need(:'ord', 'converted order');
select m19check.as_('owner');
select m19check.ok('convert', 'C4', 'C converted by D through create_order(): pending order, 1 item, request linked, event converted',
  (select status || ':' || customer_id from public.orders where id = :'ord')
  || ' ' || (select count(*) from public.order_items where order_id = :'ord')
  || ' ' || (select status || ':' || converted_order_id from public.order_requests where id = :'rc')
  || ' ' || (select count(*) from public.order_request_events where request_id = :'rc' and event = 'converted' and actor_id = 'u-stg-delivery'),
  'pending:cust-stg-alpha 1 converted:' || :'ord' || ' 1');

-- 9. CUSTOMER SEARCH IS LIMITED TO THE CALLER'S OWN CUSTOMER SCOPE -----------
select m19check.as_('u-stg-admin');
select m19check.try(format($q$select public.set_user_permissions('u-stg-officer1', string_to_array(%L, ',') || array['view_website_requests', 'convert_website_requests'])::text$q$, :'o_codes')) as g5,
       m19check.try(format($q$select public.assign_order_request(%L, 'u-stg-officer1')::text$q$, :'ra')) as asg_o \gset
select m19check.as_('u-stg-officer1');
select m19check.ok('scope', 'F1', 'officer (own customers only) finds their own customer, not another officer''s',
  m19check.try(format($q$select count(*)::text from public.find_customers_by_phone(%L, %L)$q$, :'ra', :'o_phone')) || ' '
  || m19check.try(format($q$select count(*)::text from public.find_customers_by_phone(%L, %L)$q$, :'ra', :'other_phone')),
  'OK|1 OK|0');
select m19check.as_('u-stg-admin');
select m19check.ok('scope', 'F2', 'control: Super Admin finds that other customer',
  m19check.try(format($q$select count(*)::text from public.find_customers_by_phone(%L, %L)$q$, :'ra', :'other_phone')), 'OK|1');

-- 10. REVOCATION IS IMMEDIATE ---------------------------------------------------
select m19check.try(format($q$select public.set_user_permissions('u-stg-officer1', string_to_array(%L, ','))::text$q$, :'o_codes')) as rv1 \gset
select m19check.as_('u-stg-officer1');
select m19check.ok('revoke', 'R1', 'officer still assigned to A, permission revoked: sees nothing, can do nothing',
  m19check.seen(array[:'ra']::uuid[]) || ' '
  || split_part(m19check.try(format($q$select count(*)::text from public.find_customers_by_phone(%L)$q$, :'ra')), '|', 1), '0 42501');
select m19check.as_('u-stg-admin');
select m19check.try(format($q$select public.set_user_permissions('u-stg-delivery', string_to_array(%L, ','))::text$q$, :'d_codes')) as rv2 \gset
select m19check.as_('u-stg-delivery');
select m19check.ok('revoke', 'R2', 'D revoked: its notes/timeline/settings are no longer readable',
  m19check.seen(array[:'rb', :'rc']::uuid[]) || '/' || (select count(*) from public.order_request_notes where request_id = :'rb')
  || '/' || (select count(*) from public.website_request_settings), '0/0/0');

-- 11. BOUNDARIES ------------------------------------------------------------------
select m19check.as_('owner');
select m19check.ok('boundary', 'K1', 'stock, stock movements and payments unchanged by the whole run (incl. the conversion)',
  (select string_agg(id || ':' || stock, ',' order by id) from public.products)
  || '|' || (select count(*) from public.stock_movements)
  || '|' || (select count(*) || ':' || coalesce(sum(amount), 0) from public.payments), :'biz_before');
select m19check.ok('boundary', 'K2', 'no payment or earned commission for the converted order',
  (select count(*) from public.payments where order_id = :'ord') || '/' ||
  (select count(*) from public.commissions where order_id = :'ord' and status <> 'pending'), '0/0');
select m19check.ok('boundary', 'K3', 'pre-existing requests byte-identical',
  (select string_agg(id::text || ':' || md5(row(r.*)::text), ',' order by id) from public.order_requests r
    where id not in (:'ra', :'rb', :'rc')), :'requests_before');
select m19check.ok('boundary', 'K4', 'notifications: only the assignment notifications were added (A1 D, A7 C, B D, C D, A officer)',
  ((select count(*) from public.notifications) - :notif_before)::text, '5');

-- 12. RESULTS, then ROLLBACK ----------------------------------------------------
select m19check.as_('owner');
\pset tuples_only off
select n, section, id, result, name, info from m19check.r order by n;
select result, count(*) from m19check.r group by result order by result;
do $result$
declare v_fail integer := (select count(*) from m19check.r where result <> 'PASS');
begin
  if v_fail > 0 then
    raise exception 'staging_checks_19: % check(s) FAILED - see the table above (everything is rolled back)', v_fail;
  end if;
  raise notice 'staging_checks_19: all % checks PASSED (rolling back)', (select count(*) from m19check.r);
end
$result$;
rollback;
