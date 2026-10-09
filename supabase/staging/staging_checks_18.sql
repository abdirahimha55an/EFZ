-- ============================================================================
-- EFZ - STAGING CHECKS FOR MIGRATION 18   (EFZ-STAGING ONLY - rollback-only)
-- ----------------------------------------------------------------------------
-- psql only (uses \gset). Run in the guarded Staging window as the project's
-- postgres role, after 18a+18b, and again after 18c. ONE transaction that ends
-- in ROLLBACK: nothing it creates or changes persists (helper schema, test
-- requests, notes, the converted order, the new customer, settings changes).
-- Quiet window: K1 compares stock, stock movements and payments across the run.
-- Exit status: 0 = every check PASSED; non-zero = a guard refused, a required id
-- was not produced, or at least one check FAILED (the result table is printed
-- first).
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
  if to_regprocedure('public.convert_website_request(uuid,jsonb)') is null
     or (select array_agg(enumlabel::text order by enumsortorder) from pg_enum where enumtypid = 'public.order_request_status'::regtype)
        is distinct from array['new', 'contacted', 'confirmed', 'converted', 'rejected'] then
    raise exception 'REFUSED: Migration 18a/18b not applied';
  end if;
end
$guard$;

-- 1. HELPERS (inside the transaction; rolled back) ----------------------------
create schema m18check;
grant usage on schema m18check to anon, authenticated, service_role;
create table m18check.r (n serial primary key, section text, id text, name text, result text, info text);
grant all on m18check.r to anon, authenticated, service_role;
grant usage on sequence m18check.r_n_seq to anon, authenticated, service_role;

-- Acts like PostgREST: role GUC + JWT claims. 'owner' = back to the session role (the project's postgres).
create function m18check.as_(p_who text) returns void language plpgsql as $f$
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

-- Runs SQL as the CURRENT role: 'OK|<first value>' or '<SQLSTATE>|<message>'.
create function m18check.try(p_sql text) returns text language plpgsql as $f$
declare v text;
begin
  execute p_sql into v;
  return 'OK|' || coalesce(v, '');
exception when others then
  return sqlstate || '|' || sqlerrm;
end $f$;

-- One result row; PASS when the value starts with the expectation.
create function m18check.ok(p_section text, p_id text, p_name text, p_got text, p_want text) returns void language sql as $f$
  insert into m18check.r (section, id, name, result, info)
  values (p_section, p_id, p_name,
          case when starts_with(coalesce(p_got, '<null>'), p_want) then 'PASS' else 'FAIL' end,
          left(coalesce(p_got, '<null>'), 240) || case when starts_with(coalesce(p_got, '<null>'), p_want) then '' else '  | expected: ' || p_want end);
$f$;

-- Stops the whole script (fail closed) when an id the later checks depend on was not produced; the message lists
-- every check that had already FAILED, since the result table is not printed after a stop.
create function m18check.need(p_value text, p_label text) returns void language plpgsql as $f$
begin
  if p_value is null or p_value !~ '^[0-9A-Za-z-]+$' then
    raise exception 'STOPPED: % was not produced (got %). Checks failed before the stop: %', p_label, coalesce(p_value, 'null'),
      coalesce((select string_agg(id || ' [' || info || ']', '; ' order by n) from m18check.r where result <> 'PASS'), 'none');
  end if;
end $f$;

grant execute on all functions in schema m18check to anon, authenticated, service_role;

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
  if not exists (select 1 from public.order_requests where id = '00000000-0000-4000-8000-000000000001') then
    raise exception 'PREREQUISITE: the existing Staging request 00000000-0000-4000-8000-000000000001 is missing';
  end if;
  if not exists (select 1 from public.customers where id = 'cust-stg-alpha') then
    raise exception 'PREREQUISITE: customer cust-stg-alpha is missing';
  end if;
  if (select count(*) from public.products p where p.is_active and p.stock - public.product_committed_quantity(p.id) >= 3) < 2 then
    raise exception 'PREREQUISITE: need 2 active products with 3+ available units';
  end if;
  if exists (select 1 from public.customers c where public.customer_phone_canonical(c.phone) in ('+252619918001', '+252619918002'))
     or exists (select 1 from public.order_requests r where r.phone_canonical = '+252619918001') then
    raise exception 'PREREQUISITE: the test phone numbers 0619918001/0619918002 are already in use';
  end if;
end
$pre$;

select (select id from public.products p where p.is_active and p.stock - public.product_committed_quantity(p.id) >= 3 order by id limit 1) as p1,
       (select id from public.products p where p.is_active and p.stock - public.product_committed_quantity(p.id) >= 3 order by id offset 1 limit 1) as p2,
       (exists (select 1 from pg_policy where polrelid = 'public.order_requests'::regclass and polname = 'order_requests_insert_public'))::text as legacy_open,
       (select string_agg(id || ':' || stock, ',' order by id) from public.products)
         || '|' || (select count(*) from public.stock_movements)
         || '|' || (select count(*) || ':' || coalesce(sum(amount), 0) from public.payments) as biz_before
\gset
select m18check.need(:'p1', 'product 1'), m18check.need(:'p2', 'product 2');
select (p.stock - public.product_committed_quantity(p.id) + 1)::text as p1_short from public.products p where p.id = :'p1'
\gset

-- 3. MIGRATION IDENTITY (read-only) -------------------------------------------
select m18check.ok('identity', 'A1', 'order_requests columns = 18b post-state',
  (select md5(string_agg(attname || ':' || format_type(atttypid, atttypmod), ',' order by attnum))
     from pg_attribute where attrelid = 'public.order_requests'::regclass and attnum > 0 and not attisdropped),
  '5b8a3abde3a195af76ce3ab5a35bdd3a');
select m18check.ok('identity', 'A2', 'order_requests policies (roles sorted) = 18b, or 18c once the old path is closed',
  (select string_agg(polname || ':' || md5(polcmd::text
            || (select string_agg(x::text, ',' order by x::text) from unnest(polroles::regrole[]) x)
            || coalesce(pg_get_expr(polqual, polrelid), '') || coalesce(pg_get_expr(polwithcheck, polrelid), '')), ';' order by polname)
     from pg_policy where polrelid = 'public.order_requests'::regclass),
  case when :'legacy_open' = 'true'
       then 'order_requests_insert_public:97d377d51864d7166f9d82a79488d9d4;order_requests_select:a8bcd23b6fe267919bff7e2c51bc8bc7'
       else 'order_requests_select:a8bcd23b6fe267919bff7e2c51bc8bc7' end);
select m18check.ok('identity', 'A3-' || f, 'function text = reviewed 18b (exact md5): ' || f,
  coalesce(md5(pg_get_functiondef(to_regprocedure('public.' || f))), 'MISSING'), h)
  from (values
    ('can_access_order_request(text)',           '891b2f42140fdf411480fdca81eb0c77'),
    ('normalize_phone(text,text)',               '33460f1d25c0f8752d600ad244c0962e'),
    ('customer_phone_canonical(text)',           '0093cf7e1365ada9b5e81a30059329a7'),
    ('validate_request_phone(text)',             'f6e6548db7fef226d41b1695a7f2ce41'),
    ('website_request_lock_key(text)',           'f4070e3bea631c9dcfa90e1a716122b7'),
    ('website_request_admission(text,uuid)',     'e780acb67dfbd6f812439ecffc990df3'),
    ('submit_order_request(jsonb)',              'c819251209a3ae536b731340daaa3a4b'),
    ('set_order_request_status(uuid,text,text)', 'f0310e94707f5637e45d993ac0fd2348'),
    ('add_order_request_note(uuid,text)',        '0c243d9f7ffbef9c21f1edf72336c748'),
    ('edit_order_request_note(uuid,text)',       'eb4a8808459277a09e6dcd6b9a7cdf5b'),
    ('find_customers_by_phone(uuid,text)',       'eaa6360b371b42ec2c8bd855aabb3f78'),
    ('convert_website_request(uuid,jsonb)',      '6e6949ce3e712803fcf80781000b50a6'),
    ('guard_order_request_child()',              'cb3366bfd28178943cd476c590eb0c9e'),
    ('website_request_settings_stamp()',         '72b37464b350b800cf4d08c2e2249caa'),
    ('grant_role_preset(text,user_role)',        'c3386f22afe953c7436f54c50f015773'),
    ('guard_system_logs_insert()',               'eb5333b566dc8770c6845dea03fb82ab'),
    ('convert_order_request(uuid,text)',         '4e67acd859ea07fbd35069d871613dda')) t(f, h);
select m18check.ok('identity', 'A4', 'temporary old-page function present exactly while the old path is open',
  (to_regprocedure('public.order_requests_legacy_admission()') is not null)::text
  || '/' || (select count(*) from pg_trigger where tgrelid = 'public.order_requests'::regclass and tgname like 'trg_order_requests_legacy_admission%'),
  case when :'legacy_open' = 'true' then 'true/2' else 'false/0' end);
select m18check.ok('identity', 'A5', 'view order_request_lines = reviewed 18b',
  (select md5(definition) from pg_views where schemaname = 'public' and viewname = 'order_request_lines'),
  '35cf97de67f562d556c72502b8e506c1');
select m18check.ok('identity', 'A6', 'admission and submit are VOLATILE',
  (select string_agg(provolatile::text, '' order by proname) from pg_proc
    where oid in ('public.submit_order_request(jsonb)'::regprocedure, 'public.website_request_admission(text,uuid)'::regprocedure)), 'vv');
select m18check.ok('identity', 'A7', 'realtime publication carries orders and order_requests',
  (select string_agg(tablename, ',' order by tablename) from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename in ('orders', 'order_requests')), 'order_requests,orders');
select m18check.ok('identity', 'A8', 'exactly one settings row (key true)',
  (select count(*) || '/' || bool_and(id)::text from public.website_request_settings), '1/true');
select m18check.ok('identity', 'A9', 'no website-request function carries a carriage return',
  (select coalesce(sum(length(pg_get_functiondef(p.oid)) - length(replace(pg_get_functiondef(p.oid), chr(13), ''))), 0)::text
     from pg_proc p where p.pronamespace = 'public'::regnamespace
      and p.proname in ('can_access_order_request', 'normalize_phone', 'customer_phone_canonical', 'validate_request_phone',
                        'website_request_lock_key', 'website_request_admission', 'submit_order_request', 'order_requests_legacy_admission',
                        'set_order_request_status', 'add_order_request_note', 'edit_order_request_note', 'find_customers_by_phone',
                        'convert_website_request', 'guard_order_request_child', 'website_request_settings_stamp',
                        'grant_role_preset', 'guard_system_logs_insert')), '0');

-- 4. PERMISSIONS, GRANTS, RLS --------------------------------------------------
select m18check.ok('rls', 'B1', 'anon may execute only submit_order_request among the website-request functions',
  (select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE')
      and p.proname in ('can_access_order_request', 'normalize_phone', 'customer_phone_canonical', 'validate_request_phone',
                        'website_request_lock_key', 'website_request_admission', 'submit_order_request', 'order_requests_legacy_admission',
                        'set_order_request_status', 'add_order_request_note', 'edit_order_request_note', 'find_customers_by_phone',
                        'convert_website_request', 'guard_order_request_child', 'website_request_settings_stamp', 'convert_order_request')),
  'submit_order_request');
select m18check.ok('rls', 'B2', 'signed-in users cannot call admission, validation or the retired convert',
  (has_function_privilege('authenticated', 'public.website_request_admission(text,uuid)', 'EXECUTE')
   or has_function_privilege('authenticated', 'public.validate_request_phone(text)', 'EXECUTE')
   or has_function_privilege('authenticated', 'public.convert_order_request(uuid,text)', 'EXECUTE'))::text, 'false');
select m18check.ok('rls', 'B3', 'anon table privileges on order_requests: INSERT only before 18c, none after',
  coalesce((select string_agg(privilege_type, ',' order by privilege_type) from information_schema.role_table_grants
             where grantee = 'anon' and table_schema = 'public' and table_name = 'order_requests'), 'none'),
  case when :'legacy_open' = 'true' then 'INSERT' else 'none' end);
select m18check.ok('rls', 'B4', 'both Staging Managers hold manage_website_requests; no other role does',
  (select string_agg(up.user_id, ',' order by up.user_id) from public.user_permissions up
    where up.permission_code = 'manage_website_requests'), 'u-stg-manager,u-stg-ops');
select m18check.as_('anon');
select m18check.ok('rls', 'B5', 'anon cannot read requests, lines or settings',
  split_part(m18check.try('select count(*)::text from public.order_requests'), '|', 1) || ',' ||
  split_part(m18check.try('select count(*)::text from public.order_request_lines'), '|', 1) || ',' ||
  split_part(m18check.try('select count(*)::text from public.website_request_settings'), '|', 1), '42501,42501,42501');
select m18check.ok('rls', 'B6', 'anon cannot change status',
  split_part(m18check.try($q$select public.set_order_request_status('00000000-0000-4000-8000-000000000001', 'contacted')::text$q$), '|', 1), '42501');
select m18check.as_('u-stg-officer1');
select m18check.ok('rls', 'B7', 'Marketing Officer reads 0 requests, 0 lines, 0 settings',
  m18check.try($q$select (select count(*) from public.order_requests) || '/' || (select count(*) from public.order_request_lines) || '/' || (select count(*) from public.website_request_settings)$q$),
  'OK|0/0/0');
select m18check.as_('u-stg-inventory');
select m18check.ok('rls', 'B8', 'Inventory Staff (has view_orders) reads 0 requests', m18check.try('select count(*)::text from public.order_requests'), 'OK|0');
select m18check.as_('u-stg-delivery');
select m18check.ok('rls', 'B9', 'Delivery Staff (has edit_orders) reads 0 requests and cannot change status',
  m18check.try('select count(*)::text from public.order_requests') || ' ' ||
  split_part(m18check.try($q$select public.set_order_request_status('00000000-0000-4000-8000-000000000001', 'contacted')::text$q$), '|', 1),
  'OK|0 42501');
select m18check.as_('u-stg-manager');
select m18check.ok('rls', 'B10', 'Manager reads the existing Staging request (shown as one legacy line)',
  m18check.try($q$select count(*) || '/' || (select string_agg(line_no || ':' || legacy, ',') from public.order_request_lines
                    where request_id = '00000000-0000-4000-8000-000000000001')
                  from public.order_requests where id = '00000000-0000-4000-8000-000000000001'$q$), 'OK|1/1:true');

-- 5. MULTI-PRODUCT SUBMISSION + 6. DUPLICATE SUBMISSION -----------------------
select m18check.as_('anon');
select split_part(m18check.try(format(
  $q$select public.submit_order_request(jsonb_build_object('customerName', 'STG-WR multi', 'phone', '0619918001',
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 2), jsonb_build_object('productId', %L, 'quantity', 1)),
       'submissionKey', '11111111-0018-4000-8000-000000000001'))::text$q$, :'p1', :'p2')), '|', 2) as rq
\gset
select m18check.need(:'rq', 'multi-product request');
select m18check.ok('dup', 'D1', 'same submission key returns the first request',
  m18check.try(format($q$select public.submit_order_request(jsonb_build_object('customerName', 'STG-WR multi', 'phone', '0619918001',
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 2)),
       'submissionKey', '11111111-0018-4000-8000-000000000001'))::text$q$, :'p1')), 'OK|' || :'rq');
select m18check.as_('owner');
select m18check.ok('submit', 'C1', '2 lines in order; header mirrors line 1; canonical phone; new; key stored',
  (select string_agg(line_no || ':' || (product_id = case line_no when 1 then :'p1' else :'p2' end)::text || ':' || quantity, ',' order by line_no)
     from public.order_request_items where request_id = :'rq')
  || ' ' || (select (product_id = :'p1')::text || ':' || quantity || ':' || phone_canonical || ':' || status || ':' || (submission_key is not null)::text
               from public.order_requests where id = :'rq'),
  '1:true:2,2:true:1 true:2:+252619918001:new:true');
select m18check.ok('submit', 'C2', 'one submitted event (rpc, 3 units) and one database audit line',
  (select count(*) || ':' || string_agg(source || '/' || (details ->> 'units'), '') from public.order_request_events
    where request_id = :'rq' and event = 'submitted')
  || ' ' || (select count(*) from public.system_logs where target_id = :'rq'
               and message like 'Website request REQ-% received: 2 item(s), 3 unit(s)' and origin = 'database'),
  '1:rpc/3 1');
select m18check.ok('dup', 'D2', 'the repeated key wrote nothing extra',
  (select count(*) || '/' || (select count(*) from public.order_request_items where request_id = :'rq')
     from public.order_requests where submission_key = '11111111-0018-4000-8000-000000000001'), '1/2');

-- 7. RATE LIMIT AND PHONE VALIDATION ------------------------------------------
select m18check.as_('anon');
select split_part(m18check.try(format($q$select public.submit_order_request(jsonb_build_object('customerName', 'STG-WR 2', 'phone', '+252 61 991 8001',
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 1))))::text$q$, :'p1')), '|', 2) as rq2
\gset
select split_part(m18check.try(format($q$select public.submit_order_request(jsonb_build_object('customerName', 'STG-WR 3', 'phone', '252619918001',
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 1))))::text$q$, :'p1')), '|', 2) as rq3
\gset
select m18check.need(:'rq2', 'request 2'), m18check.need(:'rq3', 'request 3');
select m18check.ok('limit', 'E1', '4th new request for one canonical phone within 24 h refused',
  split_part(m18check.try(format($q$select public.submit_order_request(jsonb_build_object('customerName', 'STG-WR 4', 'phone', '00252619918001',
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 1))))::text$q$, :'p1')), '|', 1), 'WR429');
select m18check.ok('limit', 'E2', 'invalid and (by default) international phones refused',
  split_part(m18check.try(format($q$select public.submit_order_request(jsonb_build_object('customerName', 'x', 'phone', '12345',
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 1))))::text$q$, :'p1')), '|', 1) || ',' ||
  split_part(m18check.try(format($q$select public.submit_order_request(jsonb_build_object('customerName', 'x', 'phone', '+447700900123',
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 1))))::text$q$, :'p1')), '|', 1), 'WR422,WR422');
select m18check.as_('u-stg-manager');
select m18check.ok('limit', 'E3', 'marking one contacted frees a slot',
  m18check.try(format($q$select public.set_order_request_status(%L, 'contacted')::text$q$, :'rq2')), 'OK|');
select m18check.as_('anon');
select m18check.ok('limit', 'E4', 'accepted after one is contacted',
  left(m18check.try(format($q$select public.submit_order_request(jsonb_build_object('customerName', 'STG-WR 5', 'phone', '0619918001',
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 1))))::text$q$, :'p1')), 3), 'OK|');

-- 8. LIFECYCLE AND NOTES --------------------------------------------------------
select m18check.as_('u-stg-manager');
select m18check.ok('lifecycle', 'F1', 'new -> confirmed allowed', m18check.try(format($q$select public.set_order_request_status(%L, 'confirmed')::text$q$, :'rq')), 'OK|');
select m18check.ok('lifecycle', 'F2', 'confirmed -> contacted refused',
  split_part(m18check.try(format($q$select public.set_order_request_status(%L, 'contacted')::text$q$, :'rq')), '|', 1), 'WR409');
select m18check.ok('lifecycle', 'F3', 'converted cannot be set by a status change',
  split_part(m18check.try(format($q$select public.set_order_request_status(%L, 'converted')::text$q$, :'rq3')), '|', 1), 'WR409');
select m18check.ok('lifecycle', 'F4', 'reject needs a reason',
  split_part(m18check.try(format($q$select public.set_order_request_status(%L, 'rejected')::text$q$, :'rq3')), '|', 1) || ' ' ||
  m18check.try(format($q$select public.set_order_request_status(%L, 'rejected', 'STG-WR duplicate')::text$q$, :'rq3')), '22023 OK|');
select split_part(m18check.try(format($q$select public.add_order_request_note(%L, 'STG-WR called')::text$q$, :'rq')), '|', 2) as note1
\gset
select m18check.need(:'note1', 'note');
select m18check.as_('u-stg-ops');
select m18check.ok('lifecycle', 'F5', 'another handler cannot edit the note',
  split_part(m18check.try(format($q$select public.edit_order_request_note(%L, 'x')::text$q$, :'note1')), '|', 1), '42501');
select m18check.as_('u-stg-admin');
select m18check.ok('lifecycle', 'F6', 'Super Admin can edit any note', m18check.try(format($q$select public.edit_order_request_note(%L, 'STG-WR edited')::text$q$, :'note1')), 'OK|');
select m18check.as_('owner');
select m18check.ok('lifecycle', 'F7', 'timeline: submitted, status_changed, note_added, note_edited (previous text kept)',
  (select string_agg(event, ',' order by seq) from public.order_request_events where request_id = :'rq') || ' ' ||
  (select details ->> 'previous' from public.order_request_events where request_id = :'rq' and event = 'note_edited'),
  'submitted,status_changed,note_added,note_edited STG-WR called');

-- 9. CONVERSION: atomicity, success, ownership, double conversion, officer access
select m18check.as_('owner');
select (select count(*) from public.customers) || '/' || (select count(*) from public.orders) || '/' ||
       (select count(*) from public.order_items) || '/' || (select count(*) from public.customer_ownership_changes) as counts_before
\gset
select m18check.as_('u-stg-manager');
select m18check.ok('convert', 'G1', 'short stock with new customer + owner: refused (P0001 Insufficient stock)',
  m18check.try(format($q$select public.convert_website_request(%L, jsonb_build_object(
       'newCustomer', jsonb_build_object('name', 'STG-WR conv', 'phone', '0619918002', 'ownerOfficerId', 'u-stg-officer1'),
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', %s, 'actualUnitPrice', 99))))::text$q$, :'rq', :'p1', :'p1_short')),
  'P0001|Insufficient stock');
select m18check.as_('owner');
select m18check.ok('convert', 'G2', 'failed conversion wrote nothing; request still confirmed',
  (select count(*) from public.customers) || '/' || (select count(*) from public.orders) || '/' ||
  (select count(*) from public.order_items) || '/' || (select count(*) from public.customer_ownership_changes) || ' ' ||
  (select status::text from public.order_requests where id = :'rq'), :'counts_before' || ' confirmed');
select m18check.as_('u-stg-manager');
select split_part(m18check.try(format($q$select public.convert_website_request(%L, jsonb_build_object(
       'newCustomer', jsonb_build_object('name', 'STG-WR conv', 'phone', '0619918002', 'ownerOfficerId', 'u-stg-officer1'),
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 1, 'actualUnitPrice', 99),
                                  jsonb_build_object('productId', %L, 'quantity', 1, 'actualUnitPrice', 99))))::text$q$, :'rq', :'p1', :'p2')), '|', 2) as ord
\gset
select m18check.need(:'ord', 'converted order');
select m18check.as_('owner');
select m18check.ok('convert', 'G3', 'one pending order with 2 items, linked; customer + order owned by officer1; ownership row; converted event',
  (select count(*) from public.order_items where order_id = :'ord') || ' ' ||
  (select status::text || '/' || coalesce(marketing_officer_id, '-') from public.orders where id = :'ord') || ' ' ||
  (select status::text || '/' || (converted_order_id = :'ord')::text from public.order_requests where id = :'rq') || ' ' ||
  (select c.marketing_officer_id || '/' || c.phone || '/' || (select count(*) from public.customer_ownership_changes h where h.customer_id = c.id)
     from public.customers c join public.orders o on o.customer_id = c.id where o.id = :'ord') || ' ' ||
  (select count(*) from public.order_request_events where request_id = :'rq' and event = 'converted' and order_id = :'ord'),
  '2 pending/u-stg-officer1 converted/true u-stg-officer1/619918002/1 1');
select m18check.as_('u-stg-manager');
select m18check.ok('convert', 'G4', 'second conversion refused',
  split_part(m18check.try(format($q$select public.convert_website_request(%L, jsonb_build_object('customerId', 'cust-stg-alpha',
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 1, 'actualUnitPrice', 99))))::text$q$, :'rq', :'p1')), '|', 1), 'WR409');
select m18check.ok('convert', 'G5', 'a new customer with an existing customer''s phone needs explicit confirmation',
  split_part(m18check.try(format($q$select public.set_order_request_status(%L, 'confirmed')::text$q$, :'rq2')), '|', 1) || ' ' ||
  split_part(m18check.try(format($q$select public.convert_website_request(%L, jsonb_build_object(
       'newCustomer', jsonb_build_object('name', 'STG-WR dup', 'phone', '+252619918002'),
       'lines', jsonb_build_array(jsonb_build_object('productId', %L, 'quantity', 1, 'actualUnitPrice', 99))))::text$q$, :'rq2', :'p1')), '|', 1),
  'OK WR410');
select m18check.ok('convert', 'G6', 'find_customers_by_phone finds the new customer, masked',
  m18check.try(format($q$select string_agg(phone_masked || '/' || officer_id, ',') from public.find_customers_by_phone(%L, '0619918002')$q$, :'rq2')),
  'OK|******002/u-stg-officer1');
select m18check.as_('u-stg-officer1');
select m18check.ok('convert', 'G7', 'owner officer sees the order but not the request, and cannot act on requests',
  m18check.try(format($q$select count(*)::text from public.order_details where id = %L$q$, :'ord')) || ' ' ||
  m18check.try(format($q$select count(*)::text from public.order_requests where id = %L$q$, :'rq')) || ' ' ||
  split_part(m18check.try(format($q$select public.add_order_request_note(%L, 'x')::text$q$, :'rq')), '|', 1) || ' ' ||
  split_part(m18check.try(format($q$select public.convert_website_request(%L, '{}'::jsonb)::text$q$, :'rq2')), '|', 1) || ' ' ||
  split_part(m18check.try(format($q$select count(*)::text from public.find_customers_by_phone(%L)$q$, :'rq2')), '|', 1),
  'OK|1 OK|0 42501 42501 42501');

-- 10. OLD PAGE: held to the rules before 18c, rejected after; trusted inserts bypass
select m18check.as_('anon');
select m18check.ok('oldpage', 'H1',
  case when :'legacy_open' = 'true' then 'old-page insert with an invalid phone refused' else 'old-page insert rejected after 18c' end,
  split_part(m18check.try($q$with x as (insert into public.order_requests (customer_name, phone, product_name, quantity)
       values ('STG-WR old', '12345', 'x', 1) returning 1) select count(*)::text from x$q$), '|', 1),
  case when :'legacy_open' = 'true' then 'WR422' else '42501' end);
select m18check.as_('owner');
select m18check.try($q$with x as (insert into public.order_requests (id, customer_name, phone, product_name, quantity)
       values ('bbbbbbbb-0000-4000-8000-000000000018', 'STG-WR trusted', 'not-a-phone', 'x', 1) returning 1) select count(*)::text from x$q$) as trusted_ins
\gset
select m18check.ok('oldpage', 'H2', 'trusted (owner) insert does not go through the old-page admission: accepted, no canonical phone, no event',
  :'trusted_ins'
  || ' ' || (select coalesce(phone_canonical, 'null') from public.order_requests where id = 'bbbbbbbb-0000-4000-8000-000000000018')
  || ' ' || (select count(*) from public.order_request_events where request_id = 'bbbbbbbb-0000-4000-8000-000000000018'),
  'OK|1 null 0');

-- 11. AUDIT INTEGRITY -----------------------------------------------------------
select m18check.ok('audit', 'I1', 'submit/confirm/convert lines written by the database; no name or phone in them',
  (select count(*) || '/' || bool_and(origin = 'database')::text || '/' ||
          bool_and(message not like '%619918001%' and message not like '%STG-WR multi%')::text
     from public.system_logs where target_id = :'rq' and message like 'Website request REQ-%'), '3/true/true');
select m18check.as_('u-stg-manager');
select m18check.ok('audit', 'I2', 'client cannot forge website-request audit lines (both prefixes)',
  split_part(m18check.try($q$with x as (insert into public.system_logs (id, message, category)
       values ('log-m18-forge1', 'Website request REQ-DEADBEEF converted to order ORD-0000000 (new customer)', 'ORDER') returning 1)
       select count(*)::text from x$q$), '|', 1) || ',' ||
  split_part(m18check.try($q$with x as (insert into public.system_logs (id, message, category)
       values ('log-m18-forge2', 'Customer cust-x created from REQ-DEADBEEF and assigned to X', 'CUSTOMER') returning 1)
       select count(*)::text from x$q$), '|', 1), '42501,42501');
select m18check.ok('audit', 'I3', 'an ordinary client audit line is still accepted (origin client)',
  m18check.try($q$with x as (insert into public.system_logs (id, message, category)
       values ('log-m18-client', 'STG-WR client line', 'SYSTEM') returning origin) select string_agg(origin, ',') from x$q$), 'OK|client');
select m18check.as_('owner');
select m18check.ok('audit', 'I4', 'no forged line was stored',
  (select count(*)::text from public.system_logs where id in ('log-m18-forge1', 'log-m18-forge2')), '0');

-- 12. NOTIFICATIONS (derived in the browser; the database writes none) --------
select m18check.ok('notify', 'J1', 'no notification row exists for any test request',
  (select count(*)::text from public.notifications
    where id like 'req-' || :'rq' || '%' or id like 'req-' || :'rq2' || '%' or id like 'req-' || :'rq3' || '%'), '0');

-- 13. SETTINGS STAMP AND KEY ----------------------------------------------------
select m18check.as_('u-stg-manager');
select m18check.ok('settings', 'M1', 'Manager cannot change settings (0 rows)',
  m18check.try($q$with x as (update public.website_request_settings set max_new_per_phone = 9 returning 1) select count(*)::text from x$q$), 'OK|0');
select m18check.as_('u-stg-admin');
select m18check.ok('settings', 'M2', 'Super Admin change is stamped (updated_by, updated_at = now); key forced true',
  m18check.try($q$with x as (update public.website_request_settings set max_new_per_phone = 4, id = false, updated_by = 'u-stg-manager'
       returning updated_by, (updated_at = now()) as ts, id) select string_agg(updated_by || '/' || ts || '/' || id, ',') from x$q$),
  'OK|u-stg-admin/true/true');

-- 14. CHILD-ROW GUARDS AND CASCADE ----------------------------------------------
select m18check.as_('owner');
select m18check.ok('child', 'N1', 'lines/events/notes of a live request cannot be changed or deleted, even by the owner',
  split_part(m18check.try(format($q$with x as (update public.order_request_items set quantity = 9 where request_id = %L returning 1) select count(*)::text from x$q$, :'rq')), '|', 1) || ',' ||
  split_part(m18check.try(format($q$with x as (delete from public.order_request_events where request_id = %L returning 1) select count(*)::text from x$q$, :'rq')), '|', 1) || ',' ||
  split_part(m18check.try(format($q$with x as (delete from public.order_request_notes where request_id = %L returning 1) select count(*)::text from x$q$, :'rq')), '|', 1),
  '42501,42501,42501');
select m18check.try(format($q$with x as (delete from public.order_requests where id = %L returning 1) select count(*)::text from x$q$, :'rq3')) as del_rq3
\gset
select m18check.ok('child', 'N2', 'deleting a request (owner) cascades its lines and events',
  :'del_rq3' || ' ' || (select count(*) from public.order_request_items where request_id = :'rq3')
  || '/' || (select count(*) from public.order_request_events where request_id = :'rq3'),
  'OK|1 0/0');

-- 15. BUSINESS BOUNDARY ---------------------------------------------------------
select m18check.ok('boundary', 'K1', 'stock, stock movements and payments unchanged by the whole run (incl. conversion)',
  (select string_agg(id || ':' || stock, ',' order by id) from public.products)
  || '|' || (select count(*) from public.stock_movements)
  || '|' || (select count(*) || ':' || coalesce(sum(amount), 0) from public.payments), :'biz_before');
select m18check.ok('boundary', 'K2', 'no payment or commission for the converted order',
  (select count(*) from public.payments where order_id = :'ord') || '/' ||
  (select count(*) from public.commissions where order_id = :'ord' and status <> 'pending'), '0/0');

-- 16. PRE-EXISTING REQUEST PRESERVED --------------------------------------------
select m18check.ok('legacy', 'L1', 'existing Staging request: original columns as created, new columns empty, no lines, one legacy line, never confirmed',
  (select customer_name || '/' || phone || '/' || product_id || 'x' || quantity || '/' ||
          (status <> 'confirmed')::text || '/' ||
          coalesce(phone_canonical, 'null') || '/' || coalesce(submission_key::text, 'null') || '/' ||
          coalesce(assigned_to, 'null') || '/' || coalesce(rejected_reason, 'null')
     from public.order_requests where id = '00000000-0000-4000-8000-000000000001')
  || ' items=' || (select count(*) from public.order_request_items where request_id = '00000000-0000-4000-8000-000000000001')
  || ' view=' || (select string_agg(line_no || ':' || legacy, ',') from public.order_request_lines
                   where request_id = '00000000-0000-4000-8000-000000000001'),
  'Test Website Visitor/+000 200 0001/prod-stg-nexusx4/true/null/null/null/null items=0 view=1:true');

-- 17. RESULTS, then ROLLBACK ----------------------------------------------------
select m18check.as_('owner');
\pset tuples_only off
select n, section, id, result, name, info from m18check.r order by n;
select result, count(*) from m18check.r group by result order by result;
do $result$
declare v_fail integer := (select count(*) from m18check.r where result <> 'PASS');
begin
  if v_fail > 0 then
    raise exception 'staging_checks_18: % check(s) FAILED - see the table above (everything is rolled back)', v_fail;
  end if;
  raise notice 'staging_checks_18: all % checks PASSED (rolling back)', (select count(*) from m18check.r);
end
$result$;
rollback;
