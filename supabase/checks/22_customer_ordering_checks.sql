-- =============================================================================
-- 22 - CHECKS for customer ordering and deletion requests (migrations 21 + 22). Run with psql AFTER migration 22:
--   psql -X -v ON_ERROR_STOP=1 -d <db> -f supabase/checks/22_customer_ordering_checks.sql
-- One transaction, ROLLED BACK at the end (nothing persists). Requests are made as the real Postgres roles
-- (anon / authenticated / service_role) with a simulated Supabase JWT, so the actual RLS, grants and guards are tested.
-- =============================================================================
\set ON_ERROR_STOP on
\pset footer off
\pset tuples_only on

begin;

create temp table r22 (n serial, ok boolean, name text, detail text);

create function pg_temp.q(p_sub uuid, p_role text, p_sql text) returns text
language plpgsql as $f$
declare v_out text;
begin
  perform set_config('request.jwt.claims', case when p_sub is null then json_build_object('role', p_role)::text else json_build_object('sub', p_sub, 'role', p_role)::text end, true);
  execute 'set local role ' || quote_ident(p_role);
  begin
    execute 'with t as (' || p_sql || ') select coalesce(jsonb_agg(t), ''[]''::jsonb)::text from t' into v_out;
  exception when others then
    v_out := jsonb_build_object('err', true, 'code', sqlstate, 'msg', sqlerrm)::text;
  end;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  return v_out;
end
$f$;
create function pg_temp.chk(p_name text, p_ok boolean, p_detail text default '') returns void language plpgsql as $f$
begin insert into r22 (ok, name, detail) values (coalesce(p_ok, false), p_name, left(coalesce(p_detail, ''), 240)); end $f$;
create function pg_temp.err(t text) returns boolean language sql immutable as $f$ select coalesce(t::jsonb @> '{"err": true}'::jsonb, false) $f$;
create function pg_temp.code(t text) returns text language sql immutable as $f$ select t::jsonb ->> 'code' $f$;
create function pg_temp.denied(t text) returns boolean language sql immutable as $f$ select pg_temp.err(t) and pg_temp.code(t) = '42501' $f$;
create function pg_temp.none(t text) returns boolean language sql immutable as $f$ select t = '[]' or pg_temp.denied(t) $f$;
create function pg_temp.n_ok(t text) returns boolean language sql immutable as $f$ select not pg_temp.err(t) $f$;
create function pg_temp.val(t text) returns text language sql immutable as $f$ select case when pg_temp.err(t) then null else t::jsonb -> 0 ->> 'v' end $f$;

do $t$
declare
  mgr_u uuid := 'a2000000-0000-4000-8000-000000000001';   -- reviews accounts, edits products
  req_u uuid := 'a2000000-0000-4000-8000-000000000002';   -- handles website requests and converts them
  plain_u uuid := 'a2000000-0000-4000-8000-000000000003'; -- officer with no relevant permission
  ca uuid := 'c2000000-0000-4000-8000-00000000000a'; cb uuid := 'c2000000-0000-4000-8000-00000000000b';
  cp uuid := 'c2000000-0000-4000-8000-00000000000c'; cs uuid := 'c2000000-0000-4000-8000-00000000000d';
  cd uuid := 'c2000000-0000-4000-8000-00000000000e'; cx uuid := 'c2000000-0000-4000-8000-00000000000f';
  acc record; t text; j jsonb; v_req uuid; v_req2 uuid; v_order text; v_cust_a text; v_cust_b text;
  d1 uuid; d2 uuid; d3 uuid; v_before int; v_ev int;
begin
  -- ---------------------------------------------------------------- fixtures
  insert into public.profiles (id, name, email, role, status) values
    ('u-t22-mgr', 'T22 Reviewer', 't22-mgr@example.test', 'Manager', 'active'),
    ('u-t22-req', 'T22 Handler', 't22-req@example.test', 'Manager', 'active'),
    ('u-t22-plain', 'T22 Officer', 't22-plain@example.test', 'Marketing Officer', 'active');
  insert into public.user_permissions (user_id, permission_code) values
    ('u-t22-mgr', 'manage_customer_accounts'), ('u-t22-mgr', 'edit_products'),
    ('u-t22-req', 'create_orders'), ('u-t22-req', 'view_orders'), ('u-t22-req', 'view_customers'), ('u-t22-req', 'view_all_customers');
  insert into public.user_permissions (user_id, permission_code) select 'u-t22-req', p.code from public.permissions p where p.code like '%website_request%' on conflict do nothing;
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
    (mgr_u, 'authenticated', 'authenticated', 't22-mgr@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
    (req_u, 'authenticated', 'authenticated', 't22-req@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
    (plain_u, 'authenticated', 'authenticated', 't22-plain@example.test', now(), '{"provider":"email"}', '{}', now(), now());
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  select u, 'authenticated', 'authenticated', e, now(), '{"provider":"email","efz_kind":"customer"}', '{}', now(), now()
    from (values (ca, 't22-a@example.test'), (cb, 't22-b@example.test'), (cp, 't22-p@example.test'), (cs, 't22-s@example.test'), (cd, 't22-d@example.test')) v(u, e);
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (cx, 'authenticated', 'authenticated', 't22-x@example.test', now(), '{"provider":"email"}', '{}', now(), now());   -- signed in, never registered as a customer

  insert into public.products (id, name, selling_price, cost_price, stock, is_active) values
    ('p22-designs', 'T22 Ball With Designs', 12, 6, 500, true), ('p22-plain', 'T22 Ball Plain', 10, 5, 500, true), ('p22-off', 'T22 Ball Inactive', 9, 4, 500, false);
  insert into public.product_designs (id, product_id, name, sort_order, is_active) values
    ('d2200000-0000-4000-8000-000000000001', 'p22-designs', 'Red', 1, true), ('d2200000-0000-4000-8000-000000000002', 'p22-designs', 'Blue', 2, true),
    ('d2200000-0000-4000-8000-000000000003', 'p22-designs', 'Retired', 3, false), ('d2200000-0000-4000-8000-000000000004', 'p22-off', 'Ghost', 1, true);
  d1 := 'd2200000-0000-4000-8000-000000000001'; d2 := 'd2200000-0000-4000-8000-000000000002'; d3 := 'd2200000-0000-4000-8000-000000000003';

  perform pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, %L, %L, '''', null)', ca, 't22-a@example.test', 'T22 Buyer A', '069 811 0001'));
  perform pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, %L, %L, '''', null)', cb, 't22-b@example.test', 'T22 Buyer B', '069 811 0002'));
  perform pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, %L, %L, '''', null)', cp, 't22-p@example.test', 'T22 Pending P', '069 811 0003'));
  perform pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, %L, %L, '''', null)', cs, 't22-s@example.test', 'T22 Suspended S', '069 811 0004'));
  perform pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, %L, %L, '''', null)', cd, 't22-d@example.test', 'T22 Deleter D', '069 811 0005'));
  for acc in select id, auth_user_id from public.customer_accounts where email in ('t22-a@example.test', 't22-b@example.test', 't22-s@example.test', 't22-d@example.test') loop
    perform pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, null, true, false, ''Verified by phone call (T22)'')', acc.id));
  end loop;
  perform pg_temp.q(mgr_u, 'authenticated', format('select public.suspend_customer_account(%L, ''Suspended for T22'')', (select id from public.customer_accounts where email = 't22-s@example.test')));
  select customer_id into v_cust_a from public.customer_accounts where email = 't22-a@example.test';
  select customer_id into v_cust_b from public.customer_accounts where email = 't22-b@example.test';

  -- ---------------------------------------------------------------- A. designs
  t := pg_temp.q(ca, 'authenticated', 'select count(*)::text as v from public.customer_designs()');
  perform pg_temp.chk('A1 approved customer reads the active designs of active products only (Red, Blue; not Retired, not Ghost of an inactive product)',
    (select string_agg(x ->> 'name', ',' order by x ->> 'name') from jsonb_array_elements(pg_temp.q(ca, 'authenticated', 'select name from public.customer_designs() where product_id like ''p22-%''')::jsonb) x) = 'Blue,Red', t);
  perform pg_temp.chk('A2 pending, suspended, deletion-requested and unregistered sign-ins get no designs (42501)',
    pg_temp.denied(pg_temp.q(cp, 'authenticated', 'select * from public.customer_designs()')) and pg_temp.denied(pg_temp.q(cs, 'authenticated', 'select * from public.customer_designs()'))
    and pg_temp.denied(pg_temp.q(cx, 'authenticated', 'select * from public.customer_designs()')) and pg_temp.denied(pg_temp.q(null, 'anon', 'select * from public.customer_designs()')));
  perform pg_temp.chk('A3 customers cannot read or change the design table directly',
    pg_temp.none(pg_temp.q(ca, 'authenticated', 'select 1 as v from public.product_designs'))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', 'insert into public.product_designs (product_id, name) values (''p22-plain'', ''Hacked'') returning 1 as v'))
    and pg_temp.none(pg_temp.q(ca, 'authenticated', 'update public.product_designs set is_active = false returning 1 as v'))   -- RLS hides every row from an UPDATE: nothing is changed
    and (select count(*) from public.product_designs where product_id = 'p22-designs' and is_active) = 2
    and pg_temp.denied(pg_temp.q(null, 'anon', 'select 1 as v from public.product_designs')));
  t := pg_temp.q(plain_u, 'authenticated', 'select count(*) as v from public.product_designs');
  perform pg_temp.chk('A4a active staff without edit_products can read the design catalog', not pg_temp.err(t), t);
  t := pg_temp.q(plain_u, 'authenticated', 'insert into public.product_designs (product_id, name) values (''p22-plain'', ''X'') returning 1 as v');
  perform pg_temp.chk('A4b staff without edit_products cannot add a design', pg_temp.err(t), t);
  t := pg_temp.q(mgr_u, 'authenticated', 'insert into public.product_designs (product_id, name) values (''p22-plain'', ''Staff added'') returning 1 as v');
  perform pg_temp.chk('A4c staff WITH edit_products can add a design', not pg_temp.err(t), t);
  update public.product_designs set is_active = false where product_id = 'p22-plain';   -- keep p22-plain design-free for the rest of the checks

  -- ---------------------------------------------------------------- B. submitting a request
  v_before := (select count(*) from public.order_requests);
  t := pg_temp.q(ca, 'authenticated', format('select public.submit_customer_order_request(%L::jsonb) as v', jsonb_build_object(
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p22-designs', 'designId', d1, 'quantity', 3), jsonb_build_object('productId', 'p22-designs', 'designId', d2, 'quantity', 2), jsonb_build_object('productId', 'p22-plain', 'quantity', 5)),
        'deliveryLocation', 'Mogadishu, Hodan', 'notes', 'Call before delivery', 'submissionKey', 'aaaaaaaa-0000-4000-8000-000000000001')::text));
  v_req := pg_temp.val(t)::uuid;
  perform pg_temp.chk('B1 approved customer submits a request with several designs of one product and a plain product', v_req is not null, t);
  perform pg_temp.chk('B2 it is an ordinary website request: status new, header mirrors line 1, customer details come from the ACCOUNT, no price anywhere',
    (select status::text from public.order_requests where id = v_req) = 'new'
    and (select customer_name || '|' || phone_canonical || '|' || product_id || '|' || quantity from public.order_requests where id = v_req) = 'T22 Buyer A|+252698110001|p22-designs|3'
    and (select count(*) from public.order_request_items where request_id = v_req) = 3
    and (select string_agg(design_name, ',' order by line_no) from public.customer_order_request_lines where request_id = v_req) = 'Red,Blue,'
    and (select count(*) from public.order_requests) = v_before + 1);
  perform pg_temp.chk('B3 the request is linked to the customer account and its verified customer; an event and a database-origin audit line exist',
    (select customer_id from public.customer_order_requests where request_id = v_req) = v_cust_a
    and (select count(*) from public.order_request_events where request_id = v_req and event = 'submitted' and details ->> 'channel' = 'customer_app') = 1
    and (select count(*) from public.system_logs where target_id = v_req::text and origin = 'database' and metadata ->> 'event' = 'customer_request_submitted') = 1);
  t := pg_temp.q(ca, 'authenticated', format('select public.submit_customer_order_request(%L::jsonb) as v', jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('productId', 'p22-plain', 'quantity', 99)), 'submissionKey', 'aaaaaaaa-0000-4000-8000-000000000001')::text));
  perform pg_temp.chk('B4 resubmitting the same submission key returns the same request and creates nothing new', pg_temp.val(t)::uuid = v_req and (select count(*) from public.order_requests) = v_before + 1, t);
  perform pg_temp.chk('B5 another customer cannot reuse that key', pg_temp.err(pg_temp.q(cb, 'authenticated', format('select public.submit_customer_order_request(%L::jsonb) as v', jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('productId', 'p22-plain', 'quantity', 1)), 'submissionKey', 'aaaaaaaa-0000-4000-8000-000000000001')::text))));
  t := pg_temp.q(cb, 'authenticated', format('select public.submit_customer_order_request(%L::jsonb) as v', jsonb_build_object(
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p22-plain', 'quantity', 1, 'unitPrice', 0.01, 'actualUnitPrice', 0.01, 'status', 'converted', 'customerId', v_cust_a)),
        'status', 'converted', 'customerId', v_cust_a, 'marketingOfficerId', 'u-t22-plain', 'total', 0)::text));
  v_req2 := pg_temp.val(t)::uuid;
  perform pg_temp.chk('B6 client-supplied price, status, customer id and owner are ignored: the request is new, linked to the CALLER''s customer, unassigned',
    v_req2 is not null and (select status::text from public.order_requests where id = v_req2) = 'new'
    and (select customer_id from public.customer_order_requests where request_id = v_req2) = v_cust_b
    and (select assigned_to from public.order_requests where id = v_req2) is null, t);

  perform pg_temp.chk('B7 pending, suspended and unregistered sign-ins cannot submit; nothing is written',
    pg_temp.denied(pg_temp.q(cp, 'authenticated', 'select public.submit_customer_order_request(''{"lines":[{"productId":"p22-plain","quantity":1}]}''::jsonb)'))
    and pg_temp.denied(pg_temp.q(cs, 'authenticated', 'select public.submit_customer_order_request(''{"lines":[{"productId":"p22-plain","quantity":1}]}''::jsonb)'))
    and pg_temp.denied(pg_temp.q(cx, 'authenticated', 'select public.submit_customer_order_request(''{"lines":[{"productId":"p22-plain","quantity":1}]}''::jsonb)'))
    and pg_temp.denied(pg_temp.q(null, 'anon', 'select public.submit_customer_order_request(''{"lines":[{"productId":"p22-plain","quantity":1}]}''::jsonb)')));
  perform pg_temp.chk('B8 invalid input is refused: unknown/inactive product, design of another product, retired design, missing required design, duplicate product+design, bad quantities, 0 or 21 lines',
    pg_temp.err(pg_temp.q(ca, 'authenticated', 'select public.submit_customer_order_request(''{"lines":[{"productId":"nope","quantity":1}]}''::jsonb)'))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', 'select public.submit_customer_order_request(''{"lines":[{"productId":"p22-off","quantity":1}]}''::jsonb)'))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.submit_customer_order_request(%L::jsonb)', jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('productId', 'p22-plain', 'designId', d1, 'quantity', 1)))::text)))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.submit_customer_order_request(%L::jsonb)', jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('productId', 'p22-designs', 'designId', d3, 'quantity', 1)))::text)))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', 'select public.submit_customer_order_request(''{"lines":[{"productId":"p22-designs","quantity":1}]}''::jsonb)'))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.submit_customer_order_request(%L::jsonb)', jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('productId', 'p22-designs', 'designId', d1, 'quantity', 1), jsonb_build_object('productId', 'p22-designs', 'designId', d1, 'quantity', 2)))::text)))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', 'select public.submit_customer_order_request(''{"lines":[{"productId":"p22-plain","quantity":0}]}''::jsonb)'))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', 'select public.submit_customer_order_request(''{"lines":[{"productId":"p22-plain","quantity":1.5}]}''::jsonb)'))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', 'select public.submit_customer_order_request(''{"lines":[{"productId":"p22-plain","quantity":100001}]}''::jsonb)'))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', 'select public.submit_customer_order_request(''{"lines":[]}''::jsonb)'))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.submit_customer_order_request(%L::jsonb)', jsonb_build_object('lines', (select jsonb_agg(jsonb_build_object('productId', 'p22-plain', 'quantity', 1)) from generate_series(1, 21)))::text)))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', 'select public.submit_customer_order_request(''[]''::jsonb)')));
  perform pg_temp.chk('B9 a product with designs may be ordered in several designs, and the same design twice is refused (done in B1/B8); the request count only grew by the accepted ones',
    (select count(*) from public.order_requests) = v_before + 2);

  -- ---------------------------------------------------------------- C. who can see the request
  perform pg_temp.chk('C1 the request handler sees the request and its lines; an officer without the permission sees nothing',
    pg_temp.n_ok(pg_temp.q(req_u, 'authenticated', format('select count(*) as v from public.customer_order_requests where request_id = %L', v_req))) is not false
    and (pg_temp.q(req_u, 'authenticated', format('select count(*) as v from public.customer_order_request_lines where request_id = %L', v_req))::jsonb -> 0 ->> 'v') = '3'
    and pg_temp.none(pg_temp.q(plain_u, 'authenticated', 'select 1 as v from public.customer_order_requests'))
    and pg_temp.none(pg_temp.q(plain_u, 'authenticated', 'select 1 as v from public.customer_order_request_lines')));
  perform pg_temp.chk('C2 no customer reads the link or line tables directly; nobody writes them from a client',
    pg_temp.none(pg_temp.q(ca, 'authenticated', 'select 1 as v from public.customer_order_requests')) and pg_temp.none(pg_temp.q(ca, 'authenticated', 'select 1 as v from public.customer_order_request_lines'))
    and pg_temp.none(pg_temp.q(ca, 'authenticated', 'select 1 as v from public.order_requests')) and pg_temp.none(pg_temp.q(ca, 'authenticated', 'select 1 as v from public.order_request_items'))
    and pg_temp.err(pg_temp.q(req_u, 'authenticated', 'delete from public.customer_order_requests returning 1 as v'))
    and pg_temp.err(pg_temp.q(req_u, 'authenticated', 'insert into public.customer_order_request_lines (request_id, line_no) values (gen_random_uuid(), 1) returning 1 as v')));
  begin delete from public.customer_order_requests where request_id = v_req; perform pg_temp.chk('C3 even the owner role cannot delete a customer request link while the request exists', false);
  exception when others then perform pg_temp.chk('C3 even the owner role cannot delete a customer request link while the request exists', sqlstate = '42501', sqlerrm); end;

  -- ---------------------------------------------------------------- D. my_order_requests
  t := pg_temp.q(ca, 'authenticated', 'select public.my_order_requests() as v');
  j := t::jsonb -> 0 -> 'v';
  perform pg_temp.chk('D1 customer A sees only A''s requests, with lines and designs, status new, and nothing internal', jsonb_array_length(j) = 1 and j -> 0 ->> 'id' = v_req::text and j -> 0 ->> 'status' = 'new'
    and j -> 0 -> 'lines' -> 0 ->> 'designName' = 'Red' and jsonb_array_length(j -> 0 -> 'lines') = 3
    and not (t ~* '(handled_by|assigned_to|rejected_reason|note_|internal|accountId|customerId|account_id)'), left(t, 160));
  perform pg_temp.chk('D2 customer B sees only B''s request (never A''s); a pending customer and an unregistered sign-in are refused',
    jsonb_array_length(pg_temp.q(cb, 'authenticated', 'select public.my_order_requests() as v')::jsonb -> 0 -> 'v') = 1
    and not (pg_temp.q(cb, 'authenticated', 'select public.my_order_requests() as v') like '%' || v_req::text || '%')
    and pg_temp.denied(pg_temp.q(cp, 'authenticated', 'select public.my_order_requests() as v')) and pg_temp.denied(pg_temp.q(cx, 'authenticated', 'select public.my_order_requests() as v')));

  -- ---------------------------------------------------------------- E. the EXISTING pipeline converts it
  t := pg_temp.q(req_u, 'authenticated', format('select public.set_order_request_status(%L, ''confirmed'', null) as v', v_req));
  perform pg_temp.chk('E1 staff confirm the customer request with the existing status function', not pg_temp.err(t), t);
  t := pg_temp.q(req_u, 'authenticated', format('select public.convert_website_request(%L, %L::jsonb) as v', v_req, jsonb_build_object(
        'customerId', v_cust_a, 'deliveryNotes', 'From the customer app',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p22-designs', 'quantity', 5, 'actualUnitPrice', 12), jsonb_build_object('productId', 'p22-plain', 'quantity', 5, 'actualUnitPrice', 10)))::text));
  v_order := pg_temp.val(t);
  perform pg_temp.chk('E2 the EXISTING convert_website_request turns it into a real order for the verified customer (price confirmed by staff, stock/audit rules intact)',
    v_order is not null and (select customer_id from public.orders where id = v_order) = v_cust_a and (select total from public.orders where id = v_order) = 110
    and (select status::text from public.order_requests where id = v_req) = 'converted', t);
  j := pg_temp.q(ca, 'authenticated', 'select public.my_order_requests() as v')::jsonb -> 0 -> 'v';
  perform pg_temp.chk('E3 the customer now sees the request as converted with the order id, and the order in my_orders; customer B does not',
    j -> 0 ->> 'status' = 'converted' and j -> 0 ->> 'orderId' = v_order
    and (select count(*) from jsonb_array_elements(pg_temp.q(ca, 'authenticated', 'select public.my_orders() as v')::jsonb -> 0 -> 'v') o where o ->> 'id' = v_order) = 1
    and (select count(*) from jsonb_array_elements(pg_temp.q(cb, 'authenticated', 'select public.my_orders() as v')::jsonb -> 0 -> 'v') o where o ->> 'id' = v_order) = 0);

  -- ---------------------------------------------------------------- F. deletion requests
  perform pg_temp.chk('F1 a customer cannot reach any customer function after asking to be deleted, and sees the flag in their own status',
    not pg_temp.err(pg_temp.q(cd, 'authenticated', 'select * from public.customer_catalog()'))
    and not pg_temp.err(pg_temp.q(cd, 'authenticated', 'select public.request_account_deletion(''Please delete my account'')'))
    and pg_temp.denied(pg_temp.q(cd, 'authenticated', 'select * from public.customer_catalog()')) and pg_temp.denied(pg_temp.q(cd, 'authenticated', 'select public.my_orders() as v'))
    and pg_temp.denied(pg_temp.q(cd, 'authenticated', 'select public.my_order_requests() as v')) and pg_temp.denied(pg_temp.q(cd, 'authenticated', 'select * from public.customer_designs()'))
    and pg_temp.denied(pg_temp.q(cd, 'authenticated', 'select public.submit_customer_order_request(''{"lines":[{"productId":"p22-plain","quantity":1}]}''::jsonb)'))
    and (pg_temp.q(cd, 'authenticated', 'select public.my_customer_account() as v')::jsonb -> 0 -> 'v' ->> 'deletionRequested') = 'true');
  v_ev := (select count(*) from public.customer_account_events e join public.customer_accounts a on a.id = e.account_id where a.email = 't22-d@example.test' and e.event = 'deletion_requested');
  t := pg_temp.q(cd, 'authenticated', 'select public.request_account_deletion(''again'')');
  perform pg_temp.chk('F2 the request is recorded once (event + database-origin audit line + reason); repeating it changes nothing',
    v_ev = 1 and not pg_temp.err(t)
    and (select count(*) from public.customer_account_events e join public.customer_accounts a on a.id = e.account_id where a.email = 't22-d@example.test' and e.event = 'deletion_requested') = 1
    and (select deletion_reason from public.customer_accounts where email = 't22-d@example.test') = 'Please delete my account'
    and (select count(*) from public.system_logs where origin = 'database' and metadata ->> 'event' = 'customer_account_deletion_requested') = 1);
  perform pg_temp.chk('F3 a pending, rejected or suspended customer may also ask to be deleted; an unregistered sign-in and anon cannot',
    not pg_temp.err(pg_temp.q(cp, 'authenticated', 'select public.request_account_deletion('''')')) and not pg_temp.err(pg_temp.q(cs, 'authenticated', 'select public.request_account_deletion(''bye'')'))
    and pg_temp.denied(pg_temp.q(cx, 'authenticated', 'select public.request_account_deletion(''x'')')) and pg_temp.denied(pg_temp.q(null, 'anon', 'select public.request_account_deletion(''x'')')));
  perform pg_temp.chk('F4 staff with manage_customer_accounts can see which accounts asked for deletion; an officer cannot',
    pg_temp.n_ok(pg_temp.q(mgr_u, 'authenticated', 'select count(*) as v from public.customer_accounts where deletion_requested_at is not null')) is not false
    and (pg_temp.q(mgr_u, 'authenticated', 'select count(*) as v from public.customer_accounts where deletion_requested_at is not null')::jsonb -> 0 ->> 'v')::int >= 3
    and pg_temp.none(pg_temp.q(plain_u, 'authenticated', 'select 1 as v from public.customer_accounts where deletion_requested_at is not null')));
  perform pg_temp.chk('F5 the customer cannot undo or edit a deletion request, and cannot touch the columns directly',
    pg_temp.err(pg_temp.q(cd, 'authenticated', 'update public.customer_accounts set deletion_requested_at = null returning 1 as v')));

  -- ---------------------------------------------------------------- G. privileges and unchanged behaviour
  perform pg_temp.chk('G1 new tables: anon has no privilege; authenticated cannot insert/update/delete/truncate the request link and line tables',
    not has_table_privilege('anon', 'public.product_designs', 'select') and not has_table_privilege('anon', 'public.customer_order_requests', 'select') and not has_table_privilege('anon', 'public.customer_order_request_lines', 'select')
    and not has_table_privilege('authenticated', 'public.customer_order_requests', 'insert') and not has_table_privilege('authenticated', 'public.customer_order_requests', 'update')
    and not has_table_privilege('authenticated', 'public.customer_order_requests', 'delete') and not has_table_privilege('authenticated', 'public.customer_order_request_lines', 'insert')
    and not has_table_privilege('authenticated', 'public.product_designs', 'truncate') and not has_table_privilege('authenticated', 'public.customer_order_requests', 'truncate'));
  perform pg_temp.chk('G2 customer functions are not executable by anon',
    not has_function_privilege('anon', 'public.submit_customer_order_request(jsonb)', 'execute') and not has_function_privilege('anon', 'public.my_order_requests()', 'execute')
    and not has_function_privilege('anon', 'public.customer_designs()', 'execute') and not has_function_privilege('anon', 'public.request_account_deletion(text)', 'execute'));
  t := pg_temp.q(null, 'anon', format('select public.submit_order_request(%L::jsonb) as v', json_build_object('customerName', 'T22 Visitor', 'phone', '0699977777', 'lines', json_build_array(json_build_object('productId', 'p22-plain', 'quantity', 1)), 'submissionKey', gen_random_uuid())::text));
  perform pg_temp.chk('G3 the existing public website request still works for anonymous visitors, and a staff request list still shows both kinds', not pg_temp.err(t)
    and (pg_temp.q(req_u, 'authenticated', 'select count(*) as v from public.order_requests where customer_name in (''T22 Visitor'', ''T22 Buyer A'', ''T22 Buyer B'')')::jsonb -> 0 ->> 'v')::int >= 3, t);
  perform pg_temp.chk('G4 an unregistered sign-in and an officer see no customer data through any new function or table',
    pg_temp.denied(pg_temp.q(cx, 'authenticated', 'select public.my_order_requests() as v')) and pg_temp.none(pg_temp.q(plain_u, 'authenticated', 'select 1 as v from public.customer_order_requests')));
  -- open-request cap: a customer may have at most 10 requests still waiting for EFZ
  for v_ev in 1 .. 10 loop
    t := pg_temp.q(ca, 'authenticated', format('select public.submit_customer_order_request(%L::jsonb) as v', jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('productId', 'p22-plain', 'quantity', v_ev)))::text));
    exit when pg_temp.err(t);
  end loop;
  t := pg_temp.q(ca, 'authenticated', format('select public.submit_customer_order_request(%L::jsonb) as v', jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('productId', 'p22-plain', 'quantity', 99)))::text));
  perform pg_temp.chk('B10 the 11th request still waiting for EFZ is refused (WR429); another customer is not affected',
    pg_temp.code(t) = 'WR429' and (select count(*) from public.customer_order_requests c join public.order_requests r on r.id = c.request_id where c.account_id = (select id from public.customer_accounts where email = 't22-a@example.test') and r.status in ('new', 'contacted', 'confirmed')) = 10
    and not pg_temp.err(pg_temp.q(cb, 'authenticated', format('select public.submit_customer_order_request(%L::jsonb) as v', jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('productId', 'p22-plain', 'quantity', 2)))::text))), t);
end
$t$;

select case when ok then 'PASS' else 'FAIL' end || '  ' || lpad(n::text, 3) || '  ' || name || case when detail <> '' and not ok then '  | ' || detail else '' end from r22 order by n;
select 'TOTAL: ' || count(*) || ' checks, ' || count(*) filter (where not ok) || ' failure(s)' from r22;
select count(*) filter (where not ok) = 0 as all_pass from r22 \gset

rollback;

\if :all_pass
\echo ALL CUSTOMER-ORDERING CHECKS PASS (transaction rolled back, nothing persists)
\else
\echo CUSTOMER-ORDERING CHECKS FAILED
select 1 / 0;
\endif
