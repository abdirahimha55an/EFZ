-- =============================================================================
-- CUSTOMER DATA EXPOSURE (regression). Every function the customer app can call is run as a real approved customer, and the JSON it returns is scanned
-- at EVERY depth for field NAMES that belong to EFZ internally: cost, margin, profit, commission, supplier, officer, buying/historical prices, internal
-- notes. A customer must also be unable to read the underlying tables and staff views. Runs at migration 23 and later (functions that do not exist yet
-- are skipped and counted). One transaction, rolled back.
--   psql -X -v ON_ERROR_STOP=1 -d <db> -f supabase/checks/customer_data_exposure_checks.sql
-- =============================================================================
\set ON_ERROR_STOP on
\pset footer off
\pset tuples_only on

begin;

create temp table rx (n serial, ok boolean, name text, detail text);

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
begin insert into rx (ok, name, detail) values (coalesce(p_ok, false), p_name, left(coalesce(p_detail, ''), 400)); end $f$;
create function pg_temp.err(t text) returns boolean language sql immutable as $f$ select coalesce(t::jsonb @> '{"err": true}'::jsonb, false) $f$;
-- every key name at every depth of a JSON document
create function pg_temp.jkeys(j jsonb) returns setof text language plpgsql as $f$
declare k text; v jsonb; e jsonb;
begin
  if jsonb_typeof(j) = 'object' then
    for k, v in select * from jsonb_each(j) loop return next k; return query select * from pg_temp.jkeys(v); end loop;
  elsif jsonb_typeof(j) = 'array' then
    for e in select * from jsonb_array_elements(j) loop return query select * from pg_temp.jkeys(e); end loop;
  end if;
end $f$;
create function pg_temp.banned(j jsonb) returns text language sql as $f$
  select string_agg(distinct k, ',') from pg_temp.jkeys(j) k where k ~* '(cost|margin|profit|commission|supplier|officer|buying|wholesale_price|markup|staff_note|internal)'
$f$;

do $t$
declare
  ca uuid := 'c9000000-0000-4000-8000-00000000000a'; mgr_u uuid := 'a9000000-0000-4000-8000-000000000002';
  acc record; fn record; t text; j jsonb; v_a text; v_skipped int := 0; v_checked int := 0; v_bad text := ''; v_order text; v_empty int := 0;
begin
  insert into public.profiles (id, name, email, role, status) values ('u-tx-mgr', 'TX Manager', 'tx-mgr@example.test', 'Manager', 'active');
  insert into public.user_permissions (user_id, permission_code) values ('u-tx-mgr', 'manage_customer_accounts'), ('u-tx-mgr', 'edit_products'), ('u-tx-mgr', 'view_all_customers'), ('u-tx-mgr', 'view_orders'), ('u-tx-mgr', 'create_orders'), ('u-tx-mgr', 'edit_orders');
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
    (mgr_u, 'authenticated', 'authenticated', 'tx-mgr@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
    (ca, 'authenticated', 'authenticated', 'tx-a@example.test', now(), '{"provider":"email","efz_kind":"customer"}', '{}', now(), now());
  insert into public.products (id, name, selling_price, cost_price, stock, is_active) values ('p-tx', 'TX Ball', 12.50, 6.25, 1000, true);
  insert into public.product_designs (id, product_id, name, sort_order, is_active) values ('d9000000-0000-4000-8000-000000000001', 'p-tx', 'Red', 1, true);
  perform pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, %L, %L, '''', null)', ca, 'tx-a@example.test', 'TX Buyer', '069 899 0001'));
  perform pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, null, true, false, ''Verified (TX)'')', (select id from public.customer_accounts where email = 'tx-a@example.test')));
  select customer_id into v_a from public.customer_accounts where email = 'tx-a@example.test';
  -- an order for the customer, with cost recorded on its lines (the internal data that must stay internal)
  insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes, payment_terms) values ('ORD-TX-1', v_a, 'TX Buyer', '', 'delivered', 'regular', current_date, 'internal: ask the officer', 'credit');
  insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost) values ('itm-tx-1', 'ORD-TX-1', 'p-tx', 'TX Ball', 'TX Ball', 2, 12.50, 12.50, 6.25);
  insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes) values ('pay-tx-1', 'ORD-TX-1', 25, current_date, 'Cash', '', 'internal note');

  -- the scanner itself must work (a self-test, so this suite cannot pass by finding nothing)
  perform pg_temp.chk('X0 the key scanner finds a nested banned field and ignores harmless ones',
    pg_temp.banned('{"a": [{"b": {"historical_unit_cost": 1}}], "c": {"price": 2}}'::jsonb) = 'historical_unit_cost' and pg_temp.banned('{"unitPrice": 1, "lineTotal": 2, "quantity": 3}'::jsonb) is null
    and pg_temp.banned('{"x": {"grossProfit": 1}, "y": [{"commissionRate": 2}]}'::jsonb) = 'commissionRate,grossProfit');
  perform pg_temp.chk('X0b the fixture really holds internal data (cost 6.25 on the line, an internal note on the order), so a leak would be visible',
    (select historical_unit_cost from public.order_items where id = 'itm-tx-1') = 6.25 and (select cost_price from public.products where id = 'p-tx') = 6.25);

  -- every customer-facing function that exists at this migration level
  for fn in select * from (values
      ('customer_catalog', 'select public.customer_catalog() as v'), ('customer_designs', 'select public.customer_designs() as v'),
      ('customer_price_preview', 'select public.customer_price_preview(''[{"productId":"p-tx","designId":"d9000000-0000-4000-8000-000000000001","quantity":1}]''::jsonb) as v'),
      ('customer_payment_methods', 'select public.customer_payment_methods() as v'), ('customer_credit_status', 'select public.customer_credit_status() as v'),
      ('my_finance', 'select public.my_finance() as v'), ('my_orders', 'select public.my_orders() as v'), ('my_order_requests', 'select public.my_order_requests() as v'),
      ('my_customer_account', 'select public.my_customer_account() as v'), ('my_notifications', 'select public.my_notifications() as v')) f(name, sql) loop
    if (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = fn.name) = 0 then v_skipped := v_skipped + 1; continue; end if;
    t := pg_temp.q(ca, 'authenticated', fn.sql);
    if pg_temp.err(t) then perform pg_temp.chk('X1 ' || fn.name || ' answers an approved customer', false, t); continue; end if;
    j := t::jsonb -> 0 -> 'v'; v_checked := v_checked + 1;
    if j is null or j in ('[]'::jsonb, '{}'::jsonb, 'null'::jsonb) then v_empty := v_empty + 1; end if;
    perform pg_temp.chk('X1 ' || fn.name || ': no field named cost, margin, profit, commission, supplier, officer, buying price or internal note at any depth', pg_temp.banned(j) is null, pg_temp.banned(j));
  end loop;
  perform pg_temp.chk('X2 the scan covered the customer functions that exist here (at least 8), and most of them returned real content (not empty answers)', v_checked >= 8 and v_empty <= 4, v_checked || ' checked, ' || v_empty || ' empty, ' || v_skipped || ' not present at this migration level');
  -- positive control: the catalogue really carries prices the customer is MEANT to see
  perform pg_temp.chk('X2b the invoice path is really exercised: my_finance lists the credit invoice with its lines, so a cost field added there would be seen', (pg_temp.q(ca, 'authenticated', 'select public.my_finance() as v')) like '%INV-ORD-TX-1%' and (pg_temp.q(ca, 'authenticated', 'select public.my_finance() as v')) like '%lineTotal%');
  perform pg_temp.chk('X3 the catalogue shows the selling price (12.50) and no cost, the invoice view shows the unit price and no historical cost',
    (pg_temp.q(ca, 'authenticated', 'select public.customer_catalog() as v')) like '%12.5%' and (pg_temp.q(ca, 'authenticated', 'select public.customer_catalog() as v')) not like '%6.25%'
    and (pg_temp.q(ca, 'authenticated', 'select public.my_finance() as v')) not like '%6.25%' and (pg_temp.q(ca, 'authenticated', 'select public.my_orders() as v')) not like '%6.25%');
  -- the customer cannot read the tables or staff views that hold it
  perform pg_temp.chk('X4 a customer reading the underlying tables and staff views directly gets no rows (or is refused): products, order items, payments, orders, customers, commissions, the cost-bearing views',
    (select bool_and(res = '[]' or (res::jsonb @> '{"err": true}'::jsonb)) from (select pg_temp.q(ca, 'authenticated', 'select * from public.' || tb || ' limit 1') res from unnest(array['products', 'order_items', 'payments', 'orders', 'customers', 'commissions', 'system_logs', 'daily_sales', 'product_sales', 'customer_financials', 'officer_commission_summary', 'staff_products', 'order_details']) tb) s));
  -- financial_summary is an aggregate view: a customer can select it, and gets ONE row that carries no information (nothing is visible to them, so counts and sums are zero and cost, profit and margin are null)
  perform pg_temp.chk('X4b the aggregate view financial_summary, selectable by a customer, returns a row with no data: zero counts and sums, and null cost, profit and margin',
    (select (r ->> 'total_orders') = '0' and (r ->> 'revenue_generated') = '0' and (r ->> 'cash_collected') = '0' and (r ->> 'outstanding_receivables') = '0' and (r ->> 'total_cost') is null and (r ->> 'gross_profit') is null and (r ->> 'gross_margin') is null
       from jsonb_array_elements(pg_temp.q(ca, 'authenticated', 'select * from public.financial_summary') ::jsonb) r limit 1));
  perform pg_temp.chk('X5 an anonymous caller gets nothing from any customer function', (select bool_and(pg_temp.err(pg_temp.q(null, 'anon', f.sql))) from (values ('select public.customer_catalog() as v'), ('select public.my_finance() as v'), ('select public.customer_credit_status() as v')) f(sql)));
end
$t$;

select case when ok then 'PASS' else 'FAIL' end || ' ' || lpad(n::text, 3) || ' ' || name || case when ok then '' else '   [' || detail || ']' end from rx order by n;
select 'TOTAL: ' || count(*) || ' checks, ' || count(*) filter (where not ok) || ' failure(s)' from rx;

rollback;
