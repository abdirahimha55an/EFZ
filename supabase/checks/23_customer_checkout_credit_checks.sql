-- =============================================================================
-- 23 - CHECKS for customer checkout, finance and credit (migrations 21 + 22 + 23). Run with psql AFTER migration 23:
--   psql -X -v ON_ERROR_STOP=1 -d <db> -f supabase/checks/23_customer_checkout_credit_checks.sql
-- One transaction, ROLLED BACK at the end (nothing persists). Calls are made as the real Postgres roles (anon / authenticated / service_role)
-- with a simulated Supabase JWT, so the actual grants, guards and ownership rules are tested. Provider confirmations are SIMULATED through the
-- service_role function (no real payment provider exists yet); these checks prove what happens when a verified result arrives.
-- =============================================================================
\set ON_ERROR_STOP on
\pset footer off
\pset tuples_only on

begin;

create temp table r23 (n serial, ok boolean, name text, detail text);

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
begin insert into r23 (ok, name, detail) values (coalesce(p_ok, false), p_name, left(coalesce(p_detail, ''), 300)); end $f$;
create function pg_temp.err(t text) returns boolean language sql immutable as $f$ select coalesce(t::jsonb @> '{"err": true}'::jsonb, false) $f$;
create function pg_temp.code(t text) returns text language sql immutable as $f$ select t::jsonb ->> 'code' $f$;
create function pg_temp.denied(t text) returns boolean language sql immutable as $f$ select pg_temp.err(t) and pg_temp.code(t) = '42501' $f$;
create function pg_temp.none(t text) returns boolean language sql immutable as $f$ select t = '[]' or pg_temp.denied(t) $f$;
create function pg_temp.jv(t text) returns jsonb language sql immutable as $f$ select case when pg_temp.err(t) then null else t::jsonb -> 0 -> 'v' end $f$;
create function pg_temp.msg(t text) returns text language sql immutable as $f$ select t::jsonb ->> 'msg' $f$;
-- Migration 25 replaced the credit policy (complete policy needed to enable it, fixed term, initial limit, company cap, no override unless allowed). This suite tests the checkout and
-- credit MECHANICS and runs on a database at migration 23, 24 or 25: when migration 25 is present a test configuration is set up inside this rolled-back transaction (below).
create function pg_temp.m25() returns boolean language sql stable as $f$ select exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'credit_policy' and column_name = 'purchase_window_days') $f$;

do $t$
declare
  sa_u  uuid := 'a3000000-0000-4000-8000-000000000001';   -- Super Admin
  mgr_u uuid := 'a3000000-0000-4000-8000-000000000002';   -- Manager (no finance administration)
  ca uuid := 'c3000000-0000-4000-8000-00000000000a'; cb uuid := 'c3000000-0000-4000-8000-00000000000b';
  cc uuid := 'c3000000-0000-4000-8000-00000000000c'; cp uuid := 'c3000000-0000-4000-8000-00000000000d';
  cs uuid := 'c3000000-0000-4000-8000-00000000000e'; cx uuid := 'c3000000-0000-4000-8000-00000000000f';
  acc record; t text; j jsonb; v_a text; v_b text; v_c text;
  d1 uuid := 'd2300000-0000-4000-8000-000000000001'; d2 uuid := 'd2300000-0000-4000-8000-000000000002';
  k uuid; v_co jsonb; v_co2 jsonb; v_id uuid; v_id2 uuid; v_order text; v_n int; v_n2 int; v_cost numeric; v_stock int; v_committed int; v_commissions int;
  v_pay jsonb; v_lines jsonb; v_closing numeric; v_sum numeric;
begin
  -- ---------------------------------------------------------------- fixtures
  insert into public.profiles (id, name, email, role, status) values
    ('u-t23-sa', 'T23 Super Admin', 't23-sa@example.test', 'Super Admin', 'active'),
    ('u-t23-mgr', 'T23 Manager', 't23-mgr@example.test', 'Manager', 'active'),
    ('u-t23-mo', 'T23 Officer', 't23-mo@example.test', 'Marketing Officer', 'active');
  insert into public.user_permissions (user_id, permission_code) values ('u-t23-mgr', 'manage_customer_accounts'), ('u-t23-mgr', 'edit_products'), ('u-t23-mgr', 'view_all_customers'), ('u-t23-mgr', 'view_orders'), ('u-t23-mgr', 'create_orders'), ('u-t23-mgr', 'edit_orders');
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
    (sa_u, 'authenticated', 'authenticated', 't23-sa@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
    (mgr_u, 'authenticated', 'authenticated', 't23-mgr@example.test', now(), '{"provider":"email"}', '{}', now(), now());
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  select u, 'authenticated', 'authenticated', e, now(), '{"provider":"email","efz_kind":"customer"}', '{}', now(), now()
    from (values (ca, 't23-a@example.test'), (cb, 't23-b@example.test'), (cc, 't23-c@example.test'), (cp, 't23-p@example.test'), (cs, 't23-s@example.test')) v(u, e);
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (cx, 'authenticated', 'authenticated', 't23-x@example.test', now(), '{"provider":"email"}', '{}', now(), now());

  insert into public.products (id, name, selling_price, cost_price, stock, is_active) values
    ('p23-designs', 'T23 Ball With Designs', 12.50, 6, 100, true), ('p23-plain', 'T23 Ball Plain', 10, 5, 100, true),
    ('p23-scarce', 'T23 Ball Scarce', 8, 4, 5, true), ('p23-off', 'T23 Ball Inactive', 9, 4, 100, false), ('p23-free', 'T23 No Price', 0, 0, 100, true);
  insert into public.product_designs (id, product_id, name, sort_order, is_active) values
    (d1, 'p23-designs', 'Red', 1, true), (d2, 'p23-designs', 'Blue', 2, true);

  for acc in select * from (values (ca, 't23-a@example.test', 'T23 Buyer A', '069 823 0001'), (cb, 't23-b@example.test', 'T23 Buyer B', '069 823 0002'),
                                   (cc, 't23-c@example.test', 'T23 Buyer C', '069 823 0003'), (cp, 't23-p@example.test', 'T23 Pending P', '069 823 0004'),
                                   (cs, 't23-s@example.test', 'T23 Suspended S', '069 823 0005')) v(u, e, n, ph) loop
    perform pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, %L, %L, '''', null)', acc.u, acc.e, acc.n, acc.ph));
  end loop;
  for acc in select id from public.customer_accounts where email in ('t23-a@example.test', 't23-b@example.test', 't23-c@example.test', 't23-s@example.test') loop
    perform pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, null, true, false, ''Verified by phone call (T23)'')', acc.id));
  end loop;
  perform pg_temp.q(mgr_u, 'authenticated', format('select public.suspend_customer_account(%L, ''Suspended for T23'')', (select id from public.customer_accounts where email = 't23-s@example.test')));
  select customer_id into v_a from public.customer_accounts where email = 't23-a@example.test';
  select customer_id into v_b from public.customer_accounts where email = 't23-b@example.test';
  select customer_id into v_c from public.customer_accounts where email = 't23-c@example.test';
  update public.customers set marketing_officer_id = 'u-t23-mo' where id = v_a;      -- customer A belongs to an officer (commission ownership)

  if pg_temp.m25() then
    -- test configuration for the migration-25 policy (rolled back with everything else): no proposal values, a complete test policy, overrides allowed (this suite tests them),
    -- long-standing approvals, and a sales history big enough for the company-wide cap not to matter.
    update public.credit_policy set min_completed_purchases = null, min_total_value = null, min_approved_days = null, max_outstanding = null, default_terms_days = null,
           purchase_window_days = 90, initial_credit_limit = 1000, company_cap_percent = 100, cap_basis_months = 3, allow_requirement_override = true where id;
    insert into public.customers (id, name, email, phone, notes, status) values ('cust-t23-hist', 'T23 History', 'hist23@example.test', '069 823 9999', 'sales history fixture', 'active');
    insert into public.products (id, name, selling_price, cost_price, stock, is_active) values ('p23-hist', 'T23 History Ball', 10, 5, 1000000, true);
    for acc in select d from (values ((date_trunc('month', public.efz_today()) - interval '3 month' - interval '40 days')::date), ((date_trunc('month', public.efz_today()) - interval '3 month')::date + 5),
                                       ((date_trunc('month', public.efz_today()) - interval '2 month')::date + 5), ((date_trunc('month', public.efz_today()) - interval '1 month')::date + 5)) x(d) loop
      insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) values ('ORD-T23-H' || to_char(acc.d, 'YYYYMMDD'), 'cust-t23-hist', 'T23', '', 'delivered', 'regular', acc.d, '');
      insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost) values ('itm-t23-h' || to_char(acc.d, 'YYYYMMDD'), 'ORD-T23-H' || to_char(acc.d, 'YYYYMMDD'), 'p23-hist', 'P', 'P', 300, 10, 10, 5);
    end loop;
    alter table public.customer_account_events disable trigger trg_customer_account_events_guard;
    update public.customer_account_events set created_at = now() - interval '400 days' where event = 'approved';
    alter table public.customer_account_events enable trigger trg_customer_account_events_guard;
  end if;

  -- ---------------------------------------------------------------- A. access: only approved customers; everyone else denied
  perform pg_temp.chk('A1 every customer function refuses pending, suspended, unregistered and anonymous callers (42501)',
    (select bool_and(pg_temp.denied(pg_temp.q(u, r, sql)))
       from (values (cp, 'authenticated'), (cs, 'authenticated'), (cx, 'authenticated'), (null::uuid, 'anon')) c(u, r),
            (values ('select public.customer_payment_methods() as v'), ('select public.my_finance() as v'), ('select public.customer_credit_status() as v'),
                    ('select public.my_checkout_status(gen_random_uuid()) as v'),
                    ('select public.customer_start_checkout(''{}''::jsonb) as v'), ('select public.customer_place_credit_order(''{}''::jsonb) as v'),
                    ('select public.customer_price_preview(''[]''::jsonb) as v')) f(sql)));
  perform pg_temp.chk('A2 customers and anonymous cannot read or write any of the six new tables directly',
    (select bool_and(pg_temp.none(pg_temp.q(u, r, 'select 1 as v from public.' || tb)))
       from (values (ca, 'authenticated'), (null::uuid, 'anon')) c(u, r),
            (values ('payment_methods'), ('customer_checkouts'), ('payment_checkout_events'), ('credit_policy'), ('customer_credit_accounts'), ('customer_credit_orders')) x(tb))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', 'insert into public.payment_methods (code, label, kind, enabled) values (''evil'', ''Evil'', ''provider'', true) returning 1 as v'))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', 'update public.credit_policy set enabled = true returning 1 as v'))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', 'insert into public.customer_credit_accounts (customer_id, status, credit_limit, terms_days) values (''' || v_a || ''', ''approved'', 99999, 30) returning 1 as v')));
  perform pg_temp.chk('A3 the provider-verification and expiry functions are service_role only: customers, staff and anonymous are refused',
    pg_temp.denied(pg_temp.q(ca, 'authenticated', 'select public.finalize_customer_checkout(gen_random_uuid(), ''x'', ''e1'', ''succeeded'', 1, ''r'', ''h'', false) as v'))
    and pg_temp.denied(pg_temp.q(sa_u, 'authenticated', 'select public.finalize_customer_checkout(gen_random_uuid(), ''x'', ''e1'', ''succeeded'', 1, ''r'', ''h'', false) as v'))
    and pg_temp.denied(pg_temp.q(null, 'anon', 'select public.finalize_customer_checkout(gen_random_uuid(), ''x'', ''e1'', ''succeeded'', 1, ''r'', ''h'', false) as v'))
    and pg_temp.denied(pg_temp.q(ca, 'authenticated', 'select public.expire_stale_checkouts() as v'))
    and (select bool_and(pg_temp.denied(pg_temp.q(u, r, sql))) from (values (ca, 'authenticated'), (sa_u, 'authenticated'), (null::uuid, 'anon')) c(u, r),
         (values ('select public.checkout_for_provider(gen_random_uuid()) as v'), ('select public.set_checkout_provider_ref(gen_random_uuid(), ''x'', ''ref'') as v'), ('select public.checkouts_to_reconcile(0, 10) as v')) f(sql)));
  perform pg_temp.chk('A4 the internal helpers cannot be called by any client role',
    (select bool_and(pg_temp.denied(pg_temp.q(u, r, sql)))
       from (values (ca, 'authenticated'), (sa_u, 'authenticated'), (null::uuid, 'anon')) c(u, r),
            (values ((case when to_regprocedure('public._customer_price_cart(jsonb,text)') is not null then 'select public._customer_price_cart(''[]''::jsonb, ''x'') as v' else 'select public._customer_price_cart(''[]''::jsonb) as v' end)), ('select public._customer_credit_eligibility(''x'') as v'),
                    ('select public._record_online_payment(''ORD-1'', 1, ''x'', ''r'', ''a'') as v')) f(sql)));
  perform pg_temp.chk('A5 staff administration is Super Admin only (a Manager with account and order permissions is refused)',
    pg_temp.denied(pg_temp.q(mgr_u, 'authenticated', 'select public.list_payment_methods() as v'))
    and pg_temp.denied(pg_temp.q(mgr_u, 'authenticated', 'select public.set_payment_method(''m'', ''Method'', ''provider'', true, ''reason here'') as v'))
    and pg_temp.denied(pg_temp.q(mgr_u, 'authenticated', 'select public.get_credit_policy() as v'))
    and pg_temp.denied(pg_temp.q(mgr_u, 'authenticated', 'select public.set_credit_policy(false, null, null, true, null, ''reason here'') as v'))
    and pg_temp.denied(pg_temp.q(mgr_u, 'authenticated', 'select public.credit_overview() as v'))
    and pg_temp.denied(pg_temp.q(mgr_u, 'authenticated', 'select public.list_checkouts_for_review() as v'))
    and pg_temp.denied(pg_temp.q(ca, 'authenticated', 'select public.credit_overview() as v')));
  perform pg_temp.chk('A7 no client role and not even service_role holds ANY privilege (SELECT, INSERT, UPDATE, DELETE, TRUNCATE) on the six tables; only the definer functions touch them',
    (select count(*) from (values ('payment_methods'), ('customer_checkouts'), ('payment_checkout_events'), ('credit_policy'), ('customer_credit_accounts'), ('customer_credit_orders')) x(tb),
                          (values ('anon'), ('authenticated'), ('service_role')) r(rl),
                          (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) p(pv)
       where has_table_privilege(r.rl, 'public.' || x.tb, p.pv)) = 0);
  perform pg_temp.chk('A6 no table of this migration has a column for a PIN, password, secret or card number',
    (select count(*) from information_schema.columns where table_schema = 'public' and table_name in ('payment_methods', 'customer_checkouts', 'payment_checkout_events', 'credit_policy', 'customer_credit_accounts', 'customer_credit_orders')
        and column_name ~* '(pin|passw|secret|card|cvv|token|otp)') = 0);

  -- ---------------------------------------------------------------- B. payment methods: none configured by default
  t := pg_temp.q(ca, 'authenticated', 'select public.customer_payment_methods() as v');
  perform pg_temp.chk('B1 by default NO payment method is available and credit is not available', jsonb_array_length(pg_temp.jv(t) -> 'methods') = 0 and (pg_temp.jv(t) -> 'credit' ->> 'available') = 'false', t);
  k := 'b1000000-0000-4000-8000-000000000001';
  t := pg_temp.q(ca, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', k,
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1)))::text));
  perform pg_temp.chk('B2 a checkout with a method EFZ has not enabled is refused and nothing is created', pg_temp.err(t) and (select count(*) from public.customer_checkouts where customer_id = v_a) = 0, t);
  t := pg_temp.q(sa_u, 'authenticated', 'select public.set_payment_method(''test_pay'', ''Test Pay'', ''provider'', true, ''enable for T23'') as v');
  perform pg_temp.chk('B3 a Super Admin enables a method (audited)', not pg_temp.err(t) and exists (select 1 from public.system_logs where message like 'Payment method test_pay enabled%'), t);
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_payment_method(''stg_test'', ''Staging Test'', ''staging_test'', true, ''Staging test method'') as v');
  perform pg_temp.chk('B4 the customer now sees exactly the enabled methods (code, label, kind) and nothing else',
    (select string_agg(x ->> 'code', ',' order by x ->> 'code') from jsonb_array_elements(pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_payment_methods() as v')) -> 'methods') x) = 'stg_test,test_pay');
  perform pg_temp.chk('B5 a method needs a reason to change', pg_temp.err(pg_temp.q(sa_u, 'authenticated', 'select public.set_payment_method(''test_pay'', ''Test Pay'', ''provider'', true, ''x'') as v')));

  -- ---------------------------------------------------------------- C. server pricing and validation
  k := 'c1000000-0000-4000-8000-000000000001';
  t := pg_temp.q(ca, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Mogadishu, Hodan', 'notes', 'Call first', 'submissionKey', k,
        'lines', jsonb_build_array(
            jsonb_build_object('productId', 'p23-designs', 'designId', d1, 'quantity', 3, 'unitPrice', 0.01, 'price', 0.01),
            jsonb_build_object('productId', 'p23-designs', 'designId', d2, 'quantity', 2),
            jsonb_build_object('productId', 'p23-plain', 'quantity', 4)),
        'amount', 0.01, 'total', 0.01)::text));
  v_co := pg_temp.jv(t);
  perform pg_temp.chk('C1 the total is computed by the server (5 x 12.50 + 4 x 10.00 = 102.50), ignoring any price or total the app sends', (v_co ->> 'amount')::numeric = 102.50 and (v_co ->> 'status') = 'created' and jsonb_array_length(v_co -> 'lines') = 3, t);
  perform pg_temp.chk('C2 the snapshot keeps product, design and the list price per line', (select bool_and((l ->> 'unitPrice')::numeric in (12.50, 10)) from jsonb_array_elements(v_co -> 'lines') l)
     and (select count(*) from jsonb_array_elements(v_co -> 'lines') l where l ->> 'designName' in ('Red', 'Blue')) = 2);
  t := pg_temp.q(ca, 'authenticated', format('select public.customer_price_preview(%L::jsonb) as v', jsonb_build_array(jsonb_build_object('productId', 'p23-designs', 'designId', d1, 'quantity', 2, 'unitPrice', 0.01), jsonb_build_object('productId', 'p23-plain', 'quantity', 1))::text));
  perform pg_temp.chk('C2b the price preview returns the SERVER total (2 x 12.50 + 10.00 = 35.00) and changes nothing', (pg_temp.jv(t) ->> 'total')::numeric = 35.00 and (select count(*) from public.customer_checkouts where customer_id = v_a) = 1 and (select count(*) from public.orders where customer_id = v_a) = 0, t);
  perform pg_temp.chk('C2c the preview refuses what a checkout would refuse (scarce stock, unknown product) with the database sentence',
    pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.customer_price_preview(%L::jsonb) as v', jsonb_build_array(jsonb_build_object('productId', 'p23-scarce', 'quantity', 6))::text)))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.customer_price_preview(%L::jsonb) as v', jsonb_build_array(jsonb_build_object('productId', 'nope', 'quantity', 1))::text))));
  perform pg_temp.chk('C3 starting a checkout creates NO order and NO payment', (select count(*) from public.orders where customer_id = v_a) = 0 and (select count(*) from public.payments p join public.orders o on o.id = p.order_id where o.customer_id = v_a) = 0);
  v_id := (v_co ->> 'checkoutId')::uuid;
  t := pg_temp.q(ca, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Another place', 'submissionKey', k,
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 99)))::text));
  perform pg_temp.chk('C4 repeating the same submission key returns the SAME checkout (idempotent retry; the new payload is ignored)', (pg_temp.jv(t) ->> 'checkoutId')::uuid = v_id and (pg_temp.jv(t) ->> 'repeat') = 'true' and (select count(*) from public.customer_checkouts where customer_id = v_a) = 1, t);
  t := pg_temp.q(cb, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Somewhere', 'submissionKey', k,
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1)))::text));
  perform pg_temp.chk('C5 another customer using the same key gets their own checkout (keys are per customer)', not pg_temp.err(t) and (pg_temp.jv(t) ->> 'checkoutId')::uuid <> v_id, t);
  perform pg_temp.chk('C6 validation: empty cart, unknown/inactive product, no-price product, bad quantity, missing design, foreign design, duplicate line, too many lines, missing location, missing key are all refused and create nothing',
    (select bool_and(pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', p::text)))) from (values
      (jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'c2000000-0000-4000-8000-000000000001', 'lines', '[]'::jsonb)),
      (jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'c2000000-0000-4000-8000-000000000002', 'lines', jsonb_build_array(jsonb_build_object('productId', 'nope', 'quantity', 1)))),
      (jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'c2000000-0000-4000-8000-000000000003', 'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-off', 'quantity', 1)))),
      (jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'c2000000-0000-4000-8000-000000000004', 'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-free', 'quantity', 1)))),
      (jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'c2000000-0000-4000-8000-000000000005', 'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 0)))),
      (jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'c2000000-0000-4000-8000-000000000006', 'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1.5)))),
      (jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'c2000000-0000-4000-8000-000000000007', 'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-designs', 'quantity', 1)))),
      (jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'c2000000-0000-4000-8000-000000000008', 'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'designId', d1, 'quantity', 1)))),
      (jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'c2000000-0000-4000-8000-000000000009', 'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1), jsonb_build_object('productId', 'p23-plain', 'quantity', 2)))),
      (jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', '', 'submissionKey', 'c2000000-0000-4000-8000-00000000000a', 'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1)))),
      (jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1))))) v(p))
    and (select count(*) from public.customer_checkouts where customer_id = v_a) = 1);
  perform pg_temp.chk('C7 stock is checked per PRODUCT across designs (scarce product: 5 in stock, 3 + 3 over two lines is refused; 5 is accepted)',
    pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'c3000000-0000-4000-8000-000000000001',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-scarce', 'quantity', 6)))::text)))
    and not pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'c3000000-0000-4000-8000-000000000002',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-scarce', 'quantity', 5)))::text))));
  v_id2 := (select id from public.customer_checkouts where submission_key = 'c3000000-0000-4000-8000-000000000002');
  perform pg_temp.q(ca, 'authenticated', format('select public.customer_cancel_checkout(%L) as v', v_id2));
  perform pg_temp.chk('C8 an unpaid checkout can be cancelled by its owner; the cancelled row stays (never deleted)', (select status from public.customer_checkouts where id = v_id2) = 'cancelled'
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('delete from public.customer_checkouts where id = %L returning 1 as v', v_id2))));
  perform pg_temp.chk('C9 a customer cannot see or cancel another customer''s checkout',
    pg_temp.jv(pg_temp.q(cb, 'authenticated', format('select public.my_checkout_status(%L) as v', v_id))) = 'null'::jsonb
    and (select pg_temp.q(cb, 'authenticated', format('select public.customer_cancel_checkout(%L) as v', v_id)) is not null)
    and (select status from public.customer_checkouts where id = v_id) = 'created');

  -- ---------------------------------------------------------------- D. verified payment: the only way an order is created and paid
  select count(*) into v_n from public.orders;
  v_stock := (select stock from public.products where id = 'p23-designs');
  v_committed := public.product_committed_quantity('p23-designs');
  t := pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''test_pay'', ''evt-1'', ''succeeded'', 102.50, ''PROV-REF-1'', ''hash1'', false) as v', v_id));
  j := pg_temp.jv(t);
  v_order := j ->> 'orderId';
  perform pg_temp.chk('D1 a verified payment for the exact amount creates exactly one order and marks the checkout paid', (j ->> 'status') = 'paid' and v_order is not null and (select count(*) from public.orders) = v_n + 1, t);
  perform pg_temp.chk('D2 the order is shaped like every EFZ order: pending, regular, today, at_delivery stock, payment terms paid_at_sale, the customer''s officer, no staff creator, total 102.50',
    (select status::text || '|' || order_type::text || '|' || coalesce(payment_terms, '?') || '|' || stock_mode || '|' || coalesce(marketing_officer_id, '-') || '|' || coalesce(created_by, '-') || '|' || total from public.orders where id = v_order)
      = 'pending|regular|paid_at_sale|at_delivery|u-t23-mo|-|102.50'
    and (select order_date from public.orders where id = v_order) = public.efz_today());
  perform pg_temp.chk('D3 the lines carry the LIST price and the frozen cost, with the design names, for every line',
    (select count(*) from public.order_items where order_id = v_order) = 3
    and (select bool_and(standard_unit_price = actual_unit_price and historical_unit_cost > 0) from public.order_items where order_id = v_order)
    and (select string_agg(design_name, ',' order by design_name) from public.order_items where order_id = v_order) = 'Blue,Red,T23 Ball Plain');
  perform pg_temp.chk('D4 exactly one payment of the full amount, with the method label and the provider reference; the balance is 0 and the order is paid',
    (select count(*) from public.payments where order_id = v_order) = 1
    and (select amount || '|' || payment_method || '|' || reference || '|' || coalesce(recorded_by, '-') from public.payments where order_id = v_order) = '102.50|Test Pay|PROV-REF-1|-'
    and (select outstanding_balance || '|' || amount_paid || '|' || payment_status::text from public.orders where id = v_order) = '0.00|102.50|paid');
  perform pg_temp.chk('D5 no invoice is implied: the order is paid_at_sale, so it is NOT in the customer''s invoices, but its payment is in the receipts list with an RCT number',
    jsonb_array_length(pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.my_finance() as v')) -> 'invoices') = 0
    and (select count(*) from jsonb_array_elements(pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.my_finance() as v')) -> 'payments') x where x ->> 'receiptNumber' like 'RCT-%' and x ->> 'terms' = 'paid_at_sale' and x -> 'invoiceNumber' = 'null'::jsonb) = 1);
  perform pg_temp.chk('D6 inventory follows the existing workflow: stock is unchanged, the quantity is promised to the open order, and no stock movement was written',
    (select stock from public.products where id = 'p23-designs') = v_stock and public.product_committed_quantity('p23-designs') = v_committed + 5
    and (select count(*) from public.stock_movements where product_id in ('p23-designs', 'p23-plain')) = 0);
  select count(*) into v_commissions from public.commissions where order_id = v_order;
  perform pg_temp.chk('D7 commission is untouched at order creation (it is created only by the existing delivery rules)', v_commissions = 0);
  perform pg_temp.chk('D8 audit: the order and the verified payment each wrote one audit line (customer-app channel, no staff user)',
    (select count(*) from public.system_logs where target_id = v_order and metadata ->> 'event' = 'order_created' and metadata ->> 'channel' = 'customer_app' and user_id is null) = 1
    and (select count(*) from public.system_logs where target_id = v_order and metadata ->> 'event' = 'payment_recorded' and metadata ->> 'channel' = 'customer_app_verified') = 1);
  t := pg_temp.q(ca, 'authenticated', format('select public.my_checkout_status(%L) as v', v_id));
  perform pg_temp.chk('D9 the customer sees the paid status and the order id', (pg_temp.jv(t) ->> 'status') = 'paid' and (pg_temp.jv(t) ->> 'orderId') = v_order, t);
  perform pg_temp.chk('D10 the order is in My Orders with the payment', exists (select 1 from jsonb_array_elements(pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.my_orders() as v'))) o where o ->> 'id' = v_order and jsonb_array_length(o -> 'payments') = 1));

  -- duplicates, retries and late events
  t := pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''test_pay'', ''evt-1'', ''succeeded'', 102.50, ''PROV-REF-1'', ''hash1'', false) as v', v_id));
  perform pg_temp.chk('D11 the SAME provider event delivered again changes nothing (duplicate flagged)', (pg_temp.jv(t) ->> 'duplicate') = 'true' and (select count(*) from public.orders) = v_n + 1 and (select count(*) from public.payments where order_id = v_order) = 1, t);
  t := pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''test_pay'', ''evt-1b'', ''succeeded'', 102.50, ''PROV-REF-1'', ''hash1b'', false) as v', v_id));
  perform pg_temp.chk('D12 a DIFFERENT event confirming the same checkout again still creates no second order or payment', (select count(*) from public.orders) = v_n + 1 and (select count(*) from public.payments where order_id = v_order) = 1 and (pg_temp.jv(t) ->> 'status') = 'paid', t);
  t := pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''test_pay'', ''evt-late-fail'', ''failed'', null, null, ''h'', false) as v', v_id));
  perform pg_temp.chk('D13 a failure event arriving AFTER a verified payment is ignored (the order stays paid) and is logged as a warning',
    (select status from public.customer_checkouts where id = v_id) = 'paid' and exists (select 1 from public.system_logs where metadata ->> 'event' = 'late_payment_event_ignored' and metadata ->> 'checkoutId' = v_id::text), t);

  -- failed / cancelled / pending / delayed
  v_co := pg_temp.jv(pg_temp.q(cb, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'd1000000-0000-4000-8000-000000000001',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 2)))::text)));
  v_id2 := (v_co ->> 'checkoutId')::uuid;
  perform pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''test_pay'', ''evt-b-pending'', ''pending'', null, null, ''h'', false) as v', v_id2));
  perform pg_temp.chk('D14 a delayed confirmation leaves the checkout PENDING: no order, no payment, and the customer sees the pending message',
    (select status from public.customer_checkouts where id = v_id2) = 'pending' and (select count(*) from public.orders where customer_id = v_b) = 0
    and (pg_temp.jv(pg_temp.q(cb, 'authenticated', format('select public.my_checkout_status(%L) as v', v_id2))) ->> 'message') like 'Waiting for the payment provider%'
    and (pg_temp.jv(pg_temp.q(cb, 'authenticated', 'select public.my_finance() as v')) -> 'pendingPayments' ->> 'amount')::numeric = 30.00);   -- 20.00 now + the 10.00 checkout from C5
  perform pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''test_pay'', ''evt-b-fail'', ''failed'', null, null, ''h'', false) as v', v_id2));
  perform pg_temp.chk('D15 a failed payment leaves NO order, NO payment and no receipt', (select status from public.customer_checkouts where id = v_id2) = 'failed' and (select count(*) from public.orders where customer_id = v_b) = 0
    and (pg_temp.jv(pg_temp.q(cb, 'authenticated', 'select public.my_finance() as v')) -> 'pendingPayments' ->> 'count')::int = 1);   -- only the C5 checkout is still waiting
  t := pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''test_pay'', ''evt-b-late-ok'', ''succeeded'', 20.00, ''PROV-REF-2'', ''h'', false) as v', v_id2));
  perform pg_temp.chk('D16 a verified success that arrives AFTER an earlier failure report still produces the order (the money was really received)', (pg_temp.jv(t) ->> 'status') = 'paid' and (select count(*) from public.orders where customer_id = v_b) = 1, t);
  v_co := pg_temp.jv(pg_temp.q(cb, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'd1000000-0000-4000-8000-000000000002',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1)))::text)));
  perform pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''test_pay'', ''evt-b2-cancel'', ''cancelled'', null, null, ''h'', false) as v', (v_co ->> 'checkoutId')::uuid));
  perform pg_temp.chk('D17 a cancelled payment leaves no order', (select status from public.customer_checkouts where id = (v_co ->> 'checkoutId')::uuid) = 'cancelled' and (select count(*) from public.orders where customer_id = v_b) = 1);

  -- amount mismatch, price change, stock gone, unique provider reference: never a falsely paid order
  v_co := pg_temp.jv(pg_temp.q(cb, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'd1000000-0000-4000-8000-000000000003',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 3)))::text)));
  v_id2 := (v_co ->> 'checkoutId')::uuid; select count(*) into v_n2 from public.orders; select count(*) into v_n from public.payments;
  t := pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''test_pay'', ''evt-short'', ''succeeded'', 29.00, ''PROV-REF-3'', ''h'', false) as v', v_id2));
  perform pg_temp.chk('D18 a provider amount that differs from the checkout (29.00 vs 30.00) creates NO order and NO payment; it is parked for review with a notification and a CRITICAL audit line',
    (pg_temp.jv(t) ->> 'status') = 'needs_review' and (select count(*) from public.orders) = v_n2 and (select count(*) from public.payments) = v_n
    and exists (select 1 from public.notifications where title = 'Customer payment needs review' and message like '%' || v_id2::text || '%')
    and exists (select 1 from public.system_logs where severity = 'CRITICAL' and metadata ->> 'event' = 'checkout_needs_review' and metadata ->> 'checkoutId' = v_id2::text), t);
  perform pg_temp.chk('D19 the customer is told EFZ will check, and it counts as "under review", not as a purchase or a payment',
    (pg_temp.jv(pg_temp.q(cb, 'authenticated', format('select public.my_checkout_status(%L) as v', v_id2))) ->> 'message') like 'Your payment was received but EFZ must check%'
    and (pg_temp.jv(pg_temp.q(cb, 'authenticated', 'select public.my_finance() as v')) ->> 'underReview')::int = 1);
  v_co := pg_temp.jv(pg_temp.q(cb, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'd1000000-0000-4000-8000-000000000004',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1)))::text)));
  update public.products set selling_price = 11 where id = 'p23-plain';      -- the price changes between checkout and confirmation
  select count(*) into v_n2 from public.orders;
  t := pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''test_pay'', ''evt-price'', ''succeeded'', 10.00, ''PROV-REF-4'', ''h'', false) as v', (v_co ->> 'checkoutId')::uuid));
  perform pg_temp.chk('D20 a price change after checkout cannot create an order at the old price: it is parked for review', (pg_temp.jv(t) ->> 'status') = 'needs_review' and (select count(*) from public.orders) = v_n2
    and (select failure_reason from public.customer_checkouts where id = (v_co ->> 'checkoutId')::uuid) like 'Prices changed%', t);
  update public.products set selling_price = 10 where id = 'p23-plain';
  v_co := pg_temp.jv(pg_temp.q(cb, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'd1000000-0000-4000-8000-000000000005',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-scarce', 'quantity', 5)))::text)));
  update public.products set stock = 1 where id = 'p23-scarce';                -- the stock disappears before the confirmation arrives
  select count(*) into v_n2 from public.orders;
  t := pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''test_pay'', ''evt-stock'', ''succeeded'', 40.00, ''PROV-REF-5'', ''h'', false) as v', (v_co ->> 'checkoutId')::uuid));
  perform pg_temp.chk('D21 stock that is gone after payment cannot be oversold: no order, parked for review', (pg_temp.jv(t) ->> 'status') = 'needs_review' and (select count(*) from public.orders) = v_n2
    and (select failure_reason from public.customer_checkouts where id = (v_co ->> 'checkoutId')::uuid) like 'Not enough stock%', t);
  update public.products set stock = 5 where id = 'p23-scarce';
  v_co := pg_temp.jv(pg_temp.q(cc, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'd1000000-0000-4000-8000-000000000006',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1)))::text)));
  select count(*) into v_n2 from public.orders;
  t := pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''test_pay'', ''evt-reuse'', ''succeeded'', 10.00, ''PROV-REF-1'', ''h'', false) as v', (v_co ->> 'checkoutId')::uuid));
  perform pg_temp.chk('D22 a provider reference that already paid another checkout cannot pay a second one: no order, parked for review', (pg_temp.jv(t) ->> 'status') = 'needs_review' and (select count(*) from public.orders) = v_n2
    and (select count(*) from public.customer_checkouts where method_code = 'test_pay' and provider_ref = 'PROV-REF-1') = 1, t);
  v_co := pg_temp.jv(pg_temp.q(cc, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'stg_test', 'deliveryLocation', 'Hodan', 'submissionKey', 'd1000000-0000-4000-8000-000000000007',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1)))::text)));
  t := pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''stg_test'', ''evt-x'', ''succeeded'', 10.00, ''STG-1'', ''h'', false) as v', (v_co ->> 'checkoutId')::uuid));
  perform pg_temp.chk('D23 the test method can only be finalized with the explicit Staging test flag (refused without it; accepted with it)', pg_temp.denied(t)
    and (select count(*) from public.orders where id in (select order_id from public.customer_checkouts where id = (v_co ->> 'checkoutId')::uuid)) = 0
    and (pg_temp.jv(pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''stg_test'', ''evt-y'', ''succeeded'', 10.00, ''STG-1'', ''h'', true) as v', (v_co ->> 'checkoutId')::uuid))) ->> 'status') = 'paid', t);
  -- reversal after payment: records are NOT changed automatically
  select count(*) into v_n from public.payments where order_id = v_order;
  t := pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''test_pay'', ''evt-rev'', ''reversed'', 102.50, ''PROV-REF-1'', ''h'', false) as v', v_id));
  perform pg_temp.chk('D24 a provider reversal flags the checkout, notifies staff and logs CRITICAL, but does NOT silently change the order or its payment',
    (pg_temp.jv(t) ->> 'status') = 'reversed' and (select count(*) from public.payments where order_id = v_order) = v_n and (select outstanding_balance from public.orders where id = v_order) = 0
    and exists (select 1 from public.notifications where title = 'Customer payment reversed') and exists (select 1 from public.system_logs where metadata ->> 'event' = 'payment_reversed' and severity = 'CRITICAL'), t);
  -- expiry
  v_co := pg_temp.jv(pg_temp.q(cc, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'e1000000-0000-4000-8000-000000000001',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1)))::text)));
  update public.customer_checkouts set expires_at = now() - interval '1 minute' where id = (v_co ->> 'checkoutId')::uuid;
  t := pg_temp.q(null, 'service_role', 'select public.expire_stale_checkouts() as v');
  perform pg_temp.chk('D25 unpaid checkouts expire after their window', pg_temp.jv(t) = '1'::jsonb
    and (select status from public.customer_checkouts where id = (v_co ->> 'checkoutId')::uuid) = 'expired', t || ' / ' || (select status from public.customer_checkouts where id = (v_co ->> 'checkoutId')::uuid));
  perform pg_temp.chk('D26 provider events and checkouts are never deleted or rewritten', pg_temp.err(pg_temp.q(sa_u, 'authenticated', 'delete from public.payment_checkout_events returning 1 as v'))
    and (select count(*) from public.payment_checkout_events) >= 10);
  t := pg_temp.q(sa_u, 'authenticated', 'select public.list_checkouts_for_review() as v');
  perform pg_temp.chk('D27a staff see the checkouts that need review or were reversed', jsonb_array_length(pg_temp.jv(t)) >= 4, left(t, 120));
  t := pg_temp.q(sa_u, 'authenticated', format('select public.resolve_customer_checkout(%L, ''Refunded outside the app and order not needed'') as v', v_id2));
  perform pg_temp.chk('D27b staff can resolve one with a recorded note', not pg_temp.err(t) and (select status from public.customer_checkouts where id = v_id2) = 'resolved', t || ' / ' || coalesce((select status from public.customer_checkouts where id = v_id2), '?'));

  -- ---------------------------------------------------------------- E. credit
  t := pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v');
  perform pg_temp.chk('E1 credit is OFF by default: not available, with the plain message and no invented threshold', (pg_temp.jv(t) ->> 'canBuyOnCredit') = 'false' and (pg_temp.jv(t) ->> 'message') = 'Credit purchasing is not currently available.'
    and (pg_temp.jv(t) -> 'eligibility' -> 'requirements' ->> 'minCompletedPurchases') is null, t);
  perform pg_temp.chk('E2 buying on credit is refused while credit is off', pg_temp.denied(pg_temp.q(ca, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f1000000-0000-4000-8000-000000000001',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1)))::text))));
  perform pg_temp.chk('E3 enabling credit without a purchase requirement or repayment period is refused', pg_temp.err(pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, null, null, true, 30, ''enable for T23'') as v'))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 2, null, true, null, ''enable for T23'') as v')));
  perform pg_temp.chk('E4 a credit limit cannot be set while credit is disabled', pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 500, 30, ''Trusted customer for T23'') as v', v_a))));
  t := pg_temp.q(sa_u, 'authenticated', format('select public.set_credit_policy(true, 2, 20, true, %s, ''T23 test policy: 2 completed purchases worth at least 20''%s) as v', case when pg_temp.m25() then 14 else 30 end, case when pg_temp.m25() then ', 1' else '' end));
  perform pg_temp.chk('E5 a Super Admin sets the policy (audited, with the old values recorded)', not pg_temp.err(t) and exists (select 1 from public.system_logs where metadata ->> 'event' = 'credit_policy_set' and metadata -> 'before' is not null), t);
  t := pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v');
  perform pg_temp.chk('E6 an ordinary customer is shown the requirements and accurate progress, and no credit',
    (pg_temp.jv(t) -> 'eligibility' ->> 'eligible') = 'false' and (pg_temp.jv(t) -> 'eligibility' ->> 'completedPurchases')::int = 0 and (pg_temp.jv(t) -> 'eligibility' -> 'requirements' ->> 'minCompletedPurchases')::int = 2
    and (pg_temp.jv(t) ->> 'canBuyOnCredit') = 'false' and (pg_temp.jv(t) -> 'account') = 'null'::jsonb, t);
  -- completed purchases (fixtures as the database owner): delivered and fully paid, regular
  insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) values
    ('ORD-T23-D1', v_a, 'T23 Buyer A', '', 'delivered', 'regular', current_date, ''), ('ORD-T23-D2', v_a, 'T23 Buyer A', '', 'delivered', 'regular', current_date, ''),
    ('ORD-T23-X1', v_c, 'T23 Buyer C', '', 'cancelled', 'regular', current_date, ''), ('ORD-T23-X2', v_c, 'T23 Buyer C', '', 'pending', 'regular', current_date, ''),
    ('ORD-T23-X3', v_c, 'T23 Buyer C', '', 'delivered', 'trial', current_date, ''), ('ORD-T23-X4', v_c, 'T23 Buyer C', '', 'delivered', 'regular', current_date, '');
  insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost)
  select 'itm-' || o, o, 'p23-plain', 'T23 Ball Plain', 'T23 Ball Plain', 2, 10, 10, 5 from (values ('ORD-T23-D1'), ('ORD-T23-D2'), ('ORD-T23-X1'), ('ORD-T23-X2'), ('ORD-T23-X3'), ('ORD-T23-X4')) v(o);
  insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes) values
    ('pay-t23-d1', 'ORD-T23-D1', 20, current_date, 'Cash', '', ''), ('pay-t23-d2', 'ORD-T23-D2', 20, current_date, 'Cash', '', ''),
    ('pay-t23-x1', 'ORD-T23-X1', 20, current_date, 'Cash', '', ''), ('pay-t23-x2', 'ORD-T23-X2', 20, current_date, 'Cash', '', ''),
    ('pay-t23-x3', 'ORD-T23-X3', 20, current_date, 'Cash', '', ''), ('pay-t23-x4', 'ORD-T23-X4', 5, current_date, 'Cash', '', '');
  t := pg_temp.q(cc, 'authenticated', 'select public.customer_credit_status() as v');
  perform pg_temp.chk('E7 only completed purchases count: a cancelled, an undelivered, a trial and a delivered-but-partly-paid order are NOT counted (0 of 2), and the unpaid delivered balance is flagged',
    (pg_temp.jv(t) -> 'eligibility' ->> 'completedPurchases')::int = 0 and (pg_temp.jv(t) -> 'eligibility' ->> 'unpaidDeliveredOrders')::int = 1 and (pg_temp.jv(t) -> 'eligibility' ->> 'eligible') = 'false', t);
  t := pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v');
  perform pg_temp.chk('E8 two delivered, fully paid regular orders worth 40 make customer A eligible (2 of 2, 40 >= 20) - and the paid-online order (still pending delivery) is not counted',
    (pg_temp.jv(t) -> 'eligibility' ->> 'completedPurchases')::int = 2 and (pg_temp.jv(t) -> 'eligibility' ->> 'completedValue')::numeric = 40 and (pg_temp.jv(t) -> 'eligibility' ->> 'eligible') = 'true', t);
  insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) values ('ORD-T23-D3', v_b, 'T23 Buyer B', '', 'delivered', 'regular', current_date, '');
  insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost) values ('itm-d3', 'ORD-T23-D3', 'p23-plain', 'P', 'P', 4, 10, 10, 5);
  insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes) values ('pay-t23-d3a', 'ORD-T23-D3', 15, current_date, 'Cash', '', ''), ('pay-t23-d3b', 'ORD-T23-D3', 25, current_date, 'EVC', '', '');
  perform pg_temp.chk('E9 multiple payments on one order do not double count it (an order paid in two instalments counts once)',
    (pg_temp.jv(pg_temp.q(cb, 'authenticated', 'select public.customer_credit_status() as v')) -> 'eligibility' ->> 'completedPurchases')::int = 1);
  perform pg_temp.chk('E10 eligibility alone grants nothing: customer A is eligible but has no credit account and cannot buy on credit ("never silently granted")',
    (select count(*) from public.customer_credit_accounts where customer_id = v_a) = 0 and (pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v')) ->> 'canBuyOnCredit') = 'false'
    and pg_temp.denied(pg_temp.q(ca, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f1000000-0000-4000-8000-000000000002',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1)))::text))));
  perform pg_temp.chk('E11 an ineligible customer (B has 1 of 2 purchases) cannot be given credit without a recorded override reason (10+ characters)',
    pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 100, 30, ''Trusted customer for T23'') as v', v_b)))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 100, 30, ''Trusted customer for T23'', ''short'') as v', v_b)))
    and (select count(*) from public.customer_credit_accounts where customer_id = v_b) = 0);
  perform pg_temp.chk('E12 limits and terms are validated (negative, absurd, fractions of a cent, 0 or 400 days)',
    pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, -1, 30, ''Trusted customer for T23'') as v', v_a)))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 2000000, 30, ''Trusted customer for T23'') as v', v_a)))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 100.005, 30, ''Trusted customer for T23'') as v', v_a)))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 100, 0, ''Trusted customer for T23'') as v', v_a)))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 100, 400, ''Trusted customer for T23'') as v', v_a))));
  t := pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 150, 14, ''Eligible, limit agreed by management for T23'') as v', v_a));
  perform pg_temp.chk('E13 a Super Admin sets customer A''s limit (150) and terms (14 days) with a reason; audited with the eligibility evidence', not pg_temp.err(t)
    and (select credit_limit || '|' || terms_days || '|' || override_used from public.customer_credit_accounts where customer_id = v_a) = '150.00|14|false'
    and exists (select 1 from public.system_logs where metadata ->> 'event' = 'customer_credit_set' and target_id = v_a and metadata -> 'eligibility' is not null), t);
  t := pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v');
  perform pg_temp.chk('E14 customer A now sees the authorized limit, terms and available credit (150 minus the 0 outstanding)', (pg_temp.jv(t) ->> 'canBuyOnCredit') = 'true' and (pg_temp.jv(t) -> 'account' ->> 'available')::numeric = 150
    and (pg_temp.jv(t) -> 'account' ->> 'termsDays')::int = 14 and (pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_payment_methods() as v')) -> 'credit' ->> 'available') = 'true', t);
  -- an order above the limit, then within it
  select count(*) into v_n from public.orders where customer_id = v_a;
  t := pg_temp.q(ca, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f1000000-0000-4000-8000-000000000003',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-designs', 'designId', d1, 'quantity', 13)))::text));       -- 13 x 12.50 = 162.50 > 150
  perform pg_temp.chk('E15 an order above the available credit is refused and creates nothing', pg_temp.err(t) and pg_temp.msg(t) like '%above your available credit%' and (select count(*) from public.orders where customer_id = v_a) = v_n, t);
  t := pg_temp.q(ca, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan market', 'notes', 'Credit test', 'submissionKey', 'f1000000-0000-4000-8000-000000000004',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-designs', 'designId', d1, 'quantity', 4), jsonb_build_object('productId', 'p23-plain', 'quantity', 5)), 'amount', 1, 'termsDays', 999)::text));   -- 50 + 50 = 100
  j := pg_temp.jv(t); v_order := j ->> 'orderId';
  perform pg_temp.chk('E16 an order within the limit creates ONE credit order: terms credit, total 100, no payment, balance 100, same shape as other orders', not pg_temp.err(t) and v_order is not null
    and (select payment_terms || '|' || total || '|' || outstanding_balance || '|' || amount_paid || '|' || stock_mode from public.orders where id = v_order) = 'credit|100.00|100.00|0.00|at_delivery'
    and (select count(*) from public.payments where order_id = v_order) = 0, t);
  perform pg_temp.chk('E17 the credit terms are recorded on the order from the AUTHORIZED account (14 days; a client-sent termsDays is ignored) with the limit at that time',
    (select terms_days || '|' || due_date || '|' || credit_limit_at_time from public.customer_credit_orders where order_id = v_order) = '14|' || (public.efz_today() + 14)::text || '|150.00');
  t := pg_temp.q(ca, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Elsewhere', 'submissionKey', 'f1000000-0000-4000-8000-000000000004',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1)))::text));
  perform pg_temp.chk('E18 retrying the same credit checkout returns the same order (no duplicate)', (pg_temp.jv(t) ->> 'orderId') = v_order and (pg_temp.jv(t) ->> 'repeat') = 'true' and (select count(*) from public.orders where customer_id = v_a and payment_terms = 'credit') = 1, t);
  t := pg_temp.q(ca, 'authenticated', 'select public.my_finance() as v'); j := pg_temp.jv(t);
  perform pg_temp.chk('E19 the credit order appears as an UNPAID INVOICE with number, due date, items and no payments; the available credit drops to 50',
    jsonb_array_length(j -> 'invoices') = 1 and (j -> 'invoices' -> 0 ->> 'number') = 'INV-' || v_order and (j -> 'invoices' -> 0 ->> 'status') = 'UNPAID' and (j -> 'invoices' -> 0 ->> 'dueDate') = (public.efz_today() + 14)::text
    and jsonb_array_length(j -> 'invoices' -> 0 -> 'items') = 2 and jsonb_array_length(j -> 'invoices' -> 0 -> 'payments') = 0 and (j -> 'summary' ->> 'unpaidInvoices')::int = 1
    and (j -> 'credit' -> 'account' ->> 'available')::numeric = 50 and (j -> 'credit' -> 'account' ->> 'outstanding')::numeric = 100, t);
  perform pg_temp.chk('E20 a further order that would exceed the remaining 50 is refused (60 > 50), one of 50 is accepted',
    pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f1000000-0000-4000-8000-000000000005',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 6)))::text)))
    and not pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f1000000-0000-4000-8000-000000000006',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 5)))::text))));
  -- partial payment through the existing staff function
  perform pg_temp.q(sa_u, 'authenticated', format('select public.record_payment(%L, 30, ''Cash'', null, ''INST-1'', ''first instalment'') as v', v_order));
  t := pg_temp.q(ca, 'authenticated', 'select public.my_finance() as v'); j := pg_temp.jv(t);
  perform pg_temp.chk('E21 a partial payment of 30 recorded by staff leaves the invoice PARTIALLY PAID with balance 70; the receipt is listed with paid-to-date 30 and balance-after 70',
    (select x ->> 'status' || '|' || (x ->> 'paid') || '|' || (x ->> 'outstanding') from jsonb_array_elements(j -> 'invoices') x where x ->> 'orderId' = v_order) = 'PARTIALLY PAID|30.00|70.00'
    and (select x ->> 'paidToDate' || '|' || (x ->> 'balanceAfter') || '|' || (x ->> 'invoiceNumber') from jsonb_array_elements(j -> 'payments') x where x ->> 'orderId' = v_order) = '30.00|70.00|INV-' || v_order
    and (j -> 'summary' ->> 'partialInvoices')::int = 1, t);
  -- statement reconciliation
  select (j -> 'statement' ->> 'closingBalance')::numeric into v_closing;
  select coalesce(sum(outstanding_balance), 0) into v_sum from public.orders where customer_id = v_a and status <> 'cancelled';
  perform pg_temp.chk('E22 the statement reconciles: the closing balance equals the sum of the outstanding balances in the authoritative orders, and equals the running balance of its last entry',
    v_closing = v_sum and (j -> 'statement' -> 'entries' -> -1 ->> 'balance')::numeric = v_sum and (j -> 'summary' ->> 'outstanding')::numeric = v_sum, v_closing::text || ' vs ' || v_sum::text);
  perform pg_temp.chk('E23 statement entries: orders and invoices are debits, payments are credits, each with a reference and date; the paid-online order nets to zero',
    (select count(*) from jsonb_array_elements(j -> 'statement' -> 'entries') e where e ->> 'kind' = 'invoice' and (e ->> 'debit')::numeric > 0 and (e ->> 'credit')::numeric = 0) >= 1
    and (select count(*) from jsonb_array_elements(j -> 'statement' -> 'entries') e where e ->> 'kind' = 'payment' and (e ->> 'credit')::numeric > 0 and (e ->> 'debit')::numeric = 0) >= 2
    and (select bool_and((e ->> 'reference') is not null and (e ->> 'date') is not null) from jsonb_array_elements(j -> 'statement' -> 'entries') e));
  -- pay the rest: invoice becomes PAID but stays available
  perform pg_temp.q(sa_u, 'authenticated', format('select public.record_payment(%L, 70, ''EVC'', null, ''INST-2'', ''final'') as v', v_order));
  j := pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.my_finance() as v'));
  perform pg_temp.chk('E24 once fully paid the invoice shows PAID with balance 0 and is still listed; paid invoices are counted',
    (select x ->> 'status' || '|' || (x ->> 'outstanding') from jsonb_array_elements(j -> 'invoices') x where x ->> 'orderId' = v_order) = 'PAID|0.00' and (j -> 'summary' ->> 'paidInvoices')::int >= 1);
  -- standing: an unpaid delivered balance makes a customer ineligible again; suspension stops credit
  insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) values ('ORD-T23-U1', v_a, 'T23 Buyer A', '', 'delivered', 'regular', current_date, '');
  insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost) values ('itm-u1', 'ORD-T23-U1', 'p23-plain', 'P', 'P', 1, 10, 10, 5);
  t := pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v');
  perform pg_temp.chk('E25 account standing: a delivered order with an unpaid balance makes the customer ineligible again, and credit purchasing is refused on the server',
    (pg_temp.jv(t) -> 'eligibility' ->> 'eligible') = 'false' and (pg_temp.jv(t) ->> 'canBuyOnCredit') = 'false'
    and pg_temp.denied(pg_temp.q(ca, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f1000000-0000-4000-8000-000000000007',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1)))::text))), t);
  perform pg_temp.q(sa_u, 'authenticated', format('select public.suspend_customer_credit(%L, ''Paused for T23'') as v', v_a));
  perform pg_temp.chk('E26 a Super Admin can suspend credit (audited); the status then reads suspended', (select status from public.customer_credit_accounts where customer_id = v_a) = 'suspended'
    and exists (select 1 from public.system_logs where metadata ->> 'event' = 'customer_credit_suspended'));
  t := pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 80, 14, ''Long-standing wholesale partner'', ''Known partner, policy exception approved by the owner'') as v', v_b));
  perform pg_temp.chk('E27 an override (with a 10+ character reason) can authorize a customer who does not meet the policy; it is flagged in the account and the audit line',
    not pg_temp.err(t) and (select override_used from public.customer_credit_accounts where customer_id = v_b) = true
    and exists (select 1 from public.system_logs where metadata ->> 'event' = 'customer_credit_set' and target_id = v_b and metadata ->> 'overrideReason' is not null), t);
  perform pg_temp.chk('E28 staff overview lists approved customers with eligibility, outstanding and credit account (Super Admin only)', jsonb_array_length(pg_temp.jv(pg_temp.q(sa_u, 'authenticated', 'select public.credit_overview() as v'))) >= 3);

  -- ---------------------------------------------------------------- H. provider plumbing (service_role only)
  v_co := pg_temp.jv(pg_temp.q(cc, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'e1000000-0000-4000-8000-000000000009',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1)))::text)));
  v_id2 := (v_co ->> 'checkoutId')::uuid;
  t := pg_temp.q(null, 'service_role', format('select public.checkout_for_provider(%L) as v', v_id2));
  perform pg_temp.chk('H1 the server can read what it needs about one checkout (method, kind, amount, status) and nothing about the customer beyond an id',
    (pg_temp.jv(t) ->> 'methodKind') = 'provider' and (pg_temp.jv(t) ->> 'amount')::numeric = 10.00 and (pg_temp.jv(t) ->> 'status') = 'created' and (pg_temp.jv(t) ->> 'currency') = 'USD'
    and not (pg_temp.jv(t)::text ~* '(phone|email|name|password|pin)') and pg_temp.jv(pg_temp.q(null, 'service_role', 'select public.checkout_for_provider(gen_random_uuid()) as v')) = 'null'::jsonb, t);
  t := pg_temp.q(null, 'service_role', format('select public.set_checkout_provider_ref(%L, ''test_pay'', ''INV-777'') as v', v_id2));
  perform pg_temp.chk('H2 a provider reference moves a created checkout to pending and logs the start; the same reference again is harmless',
    not pg_temp.err(t) and (select status || '|' || provider_ref from public.customer_checkouts where id = v_id2) = 'pending|INV-777'
    and (select count(*) from public.payment_checkout_events where checkout_id = v_id2 and provider_event_id = 'start:INV-777') = 1
    and not pg_temp.err(pg_temp.q(null, 'service_role', format('select public.set_checkout_provider_ref(%L, ''test_pay'', ''INV-777'') as v', v_id2))), t);
  perform pg_temp.chk('H3 a checkout takes only ONE provider reference, only for its own method, and a reference cannot be empty',
    pg_temp.err(pg_temp.q(null, 'service_role', format('select public.set_checkout_provider_ref(%L, ''test_pay'', ''INV-OTHER'') as v', v_id2)))
    and pg_temp.err(pg_temp.q(null, 'service_role', format('select public.set_checkout_provider_ref(%L, ''stg_test'', ''INV-777'') as v', v_id2)))
    and pg_temp.err(pg_temp.q(null, 'service_role', format('select public.set_checkout_provider_ref(%L, ''test_pay'', '''') as v', v_id2)))
    and pg_temp.err(pg_temp.q(null, 'service_role', 'select public.set_checkout_provider_ref(gen_random_uuid(), ''test_pay'', ''X'') as v')));
  v_co2 := pg_temp.jv(pg_temp.q(cc, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'test_pay', 'deliveryLocation', 'Hodan', 'submissionKey', 'e1000000-0000-4000-8000-00000000000a',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 2)))::text)));
  perform pg_temp.chk('H4 one provider reference can belong to only one checkout of a method (a replayed reference cannot be attached to another checkout)',
    pg_temp.err(pg_temp.q(null, 'service_role', format('select public.set_checkout_provider_ref(%L, ''test_pay'', ''INV-777'') as v', (v_co2 ->> 'checkoutId')::uuid)))
    and (select status from public.customer_checkouts where id = (v_co2 ->> 'checkoutId')::uuid) = 'created');
  perform pg_temp.chk('H5 a provider reference cannot be attached to a settled checkout or to a disabled method',
    pg_temp.err(pg_temp.q(null, 'service_role', format('select public.set_checkout_provider_ref(%L, ''test_pay'', ''INV-888'') as v', (select id from public.customer_checkouts where status = 'cancelled' and provider_ref is null limit 1)))));
  update public.payment_methods set enabled = false where code = 'test_pay';
  perform pg_temp.chk('H5b ... and a disabled method cannot start a provider payment', pg_temp.err(pg_temp.q(null, 'service_role', format('select public.set_checkout_provider_ref(%L, ''test_pay'', ''INV-999'') as v', (v_co2 ->> 'checkoutId')::uuid))));
  update public.payment_methods set enabled = true where code = 'test_pay';
  t := pg_temp.q(null, 'service_role', 'select public.checkouts_to_reconcile(0, 50) as v');
  perform pg_temp.chk('H6 the reconciliation list holds exactly the pending checkouts that have a provider reference', jsonb_array_length(pg_temp.jv(t)) = (select count(*) from public.customer_checkouts where status = 'pending' and provider_ref is not null)
    and exists (select 1 from jsonb_array_elements(pg_temp.jv(t)) x where x ->> 'providerRef' = 'INV-777'), t);
  perform pg_temp.chk('H7 a recently started checkout is not listed until it is older than the requested age', not exists (select 1 from jsonb_array_elements(pg_temp.jv(pg_temp.q(null, 'service_role', 'select public.checkouts_to_reconcile(3600, 50) as v'))) x where x ->> 'providerRef' = 'INV-777'));
  -- a verified success on the reference-bearing checkout still goes through finalize and creates exactly one order
  select count(*) into v_n2 from public.orders;
  t := pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''test_pay'', ''evt-h1'', ''succeeded'', 10.00, ''INV-777'', ''h'', false) as v', v_id2));
  perform pg_temp.chk('H8 a verified success for the checkout that carries a provider reference creates one order and is no longer listed for reconciliation',
    (pg_temp.jv(t) ->> 'status') = 'paid' and (select count(*) from public.orders) = v_n2 + 1
    and not exists (select 1 from jsonb_array_elements(pg_temp.jv(pg_temp.q(null, 'service_role', 'select public.checkouts_to_reconcile(0, 50) as v'))) x where x ->> 'providerRef' = 'INV-777'), t);

  -- ---------------------------------------------------------------- F. isolation between customers
  j := pg_temp.jv(pg_temp.q(cb, 'authenticated', 'select public.my_finance() as v'));
  perform pg_temp.chk('F1 customer B never sees customer A''s orders, invoices, payments, receipts or statement entries',
    not (j::text like '%' || v_order || '%') and not (j::text like '%ORD-T23-D1%') and not (j::text like '%pay-t23-d1%')
    and (select count(*) from jsonb_array_elements(j -> 'payments') x where x ->> 'orderId' in (select id from public.orders where customer_id = v_a)) = 0
    and (select count(*) from jsonb_array_elements(j -> 'statement' -> 'entries') x where x ->> 'orderId' in (select id from public.orders where customer_id = v_a)) = 0
    and (select count(*) from jsonb_array_elements(j -> 'invoices') x where x ->> 'orderId' in (select id from public.orders where customer_id = v_a)) = 0);
  j := pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.my_finance() as v'));
  perform pg_temp.chk('F2 customer A never sees customer B''s data', not (j::text like '%ORD-T23-D3%') and not (j::text like '%pay-t23-d3%')
    and (select count(*) from jsonb_array_elements(j -> 'payments') x where x ->> 'orderId' in (select id from public.orders where customer_id = v_b)) = 0);
  perform pg_temp.chk('F3 each customer''s outstanding figure equals the authoritative sum for THAT customer only',
    (select bool_and((pg_temp.jv(pg_temp.q(u, 'authenticated', 'select public.my_finance() as v')) -> 'summary' ->> 'outstanding')::numeric = (select coalesce(sum(outstanding_balance), 0) from public.orders where customer_id = cid and status <> 'cancelled'))
       from (values (ca, v_a), (cb, v_b), (cc, v_c)) x(u, cid)));
  perform pg_temp.chk('F4 payment-method, credit and checkout answers are per customer (B has credit by override; C has none)',
    (pg_temp.jv(pg_temp.q(cc, 'authenticated', 'select public.customer_credit_status() as v')) -> 'account') = 'null'::jsonb
    and (pg_temp.jv(pg_temp.q(cb, 'authenticated', 'select public.customer_credit_status() as v')) -> 'account' ->> 'creditLimit')::numeric = 80);
  perform pg_temp.chk('F5 a customer can never select a staff-only or foreign financial table (orders, payments, customer credit accounts, system logs)',
    (select bool_and(pg_temp.none(pg_temp.q(ca, 'authenticated', 'select 1 as v from public.' || tb))) from (values ('orders'), ('payments'), ('customer_credit_accounts'), ('system_logs'), ('order_items')) x(tb)));

  perform pg_temp.chk('F6 with rows present in all six tables, customers and anonymous still read NONE of them (not their own checkouts either), and cannot write',
    (select bool_and(pg_temp.none(pg_temp.q(u, r, 'select 1 as v from public.' || tb)))
           from (values (ca, 'authenticated'), (cb, 'authenticated'), (null::uuid, 'anon')) c(u, r),
                (values ('payment_methods'), ('customer_checkouts'), ('payment_checkout_events'), ('credit_policy'), ('customer_credit_accounts'), ('customer_credit_orders')) x(tb))
    and (select count(*) from public.payment_methods) > 0 and (select count(*) from public.customer_checkouts where customer_id = v_a) > 0
    and (select count(*) from public.payment_checkout_events) > 0 and (select count(*) from public.credit_policy) > 0
    and (select count(*) from public.customer_credit_accounts) > 0 and (select count(*) from public.customer_credit_orders) > 0
    and pg_temp.err(pg_temp.q(ca, 'authenticated', 'update public.customer_checkouts set status = ''paid'' returning 1 as v'))
    and (select count(*) from public.customer_checkouts where status = 'paid' and customer_id = v_a) = 0);   -- A's only checkout was reversed; nothing was marked paid by the customer

  -- ---------------------------------------------------------------- G. nothing else changed
  perform pg_temp.chk('G1 create_order and record_payment still refuse customers (they are staff-only; the customer channel does not weaken them)',
    pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.create_order(%L::jsonb) as v', jsonb_build_object('customerId', v_a, 'items', jsonb_build_array(jsonb_build_object('productId', 'p23-plain', 'quantity', 1)))::text)))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.record_payment(%L, 1, ''Cash'') as v', 'ORD-T23-U1'))));
  perform pg_temp.chk('G2 every credit and paid-online order has a matching audit line (no order without one)',
    (select count(*) from public.orders o where o.id in (select order_id from public.customer_credit_orders union select order_id from public.customer_checkouts where order_id is not null)
        and not exists (select 1 from public.system_logs l where l.target_id = o.id and l.metadata ->> 'event' = 'order_created')) = 0);
  perform pg_temp.chk('G3 the financial invariants hold on every order created by the customer channel (total = sum of lines, paid + balance = total, no negative values)',
    (select count(*) from public.orders o where o.id in (select order_id from public.customer_checkouts where order_id is not null)
        and (o.total <> (select sum(line_revenue) from public.order_items where order_id = o.id) or o.amount_paid + o.outstanding_balance <> o.total or o.outstanding_balance < 0)) = 0);
end
$t$;

select case when ok then 'PASS' else 'FAIL' end || ' ' || lpad(n::text, 3) || ' ' || name || case when ok then '' else '   [' || detail || ']' end from r23 order by n;
select 'TOTAL: ' || count(*) || ' checks, ' || count(*) filter (where not ok) || ' failure(s)' from r23;

rollback;
