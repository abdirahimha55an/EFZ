-- =============================================================================
-- 26 - CHECKS for customer price agreements (migration 26, on top of 21 .. 25). Run with psql AFTER migration 26:
--   psql -X -v ON_ERROR_STOP=1 -d <db> -f supabase/checks/26_price_agreements_checks.sql
-- One transaction, ROLLED BACK at the end (nothing persists). Calls are made as the real Postgres roles with a simulated Supabase JWT. Time-dependent cases
-- (expiry, future start) use real dates relative to today (efz_today()); history fixtures are inserted as the database owner. Simultaneous checkout and
-- agreement changes are tested separately (supabase/checks/26_price_concurrency.mjs: real parallel sessions).
-- =============================================================================
\set ON_ERROR_STOP on
\pset footer off
\pset tuples_only on

begin;

create temp table r26 (n serial, ok boolean, name text, detail text);

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
begin insert into r26 (ok, name, detail) values (coalesce(p_ok, false), p_name, left(coalesce(p_detail, ''), 500)); end $f$;
create function pg_temp.err(t text) returns boolean language sql immutable as $f$ select coalesce(t::jsonb @> '{"err": true}'::jsonb, false) $f$;
create function pg_temp.code(t text) returns text language sql immutable as $f$ select t::jsonb ->> 'code' $f$;
create function pg_temp.denied(t text) returns boolean language sql immutable as $f$ select pg_temp.err(t) and pg_temp.code(t) = '42501' $f$;
create function pg_temp.none(t text) returns boolean language sql immutable as $f$ select t = '[]' or pg_temp.denied(t) $f$;
create function pg_temp.jv(t text) returns jsonb language sql immutable as $f$ select case when pg_temp.err(t) then null else t::jsonb -> 0 -> 'v' end $f$;
create function pg_temp.msg(t text) returns text language sql immutable as $f$ select t::jsonb ->> 'msg' $f$;
create function pg_temp.jkeys(j jsonb) returns setof text language plpgsql as $f$
declare k text; v jsonb; e jsonb;
begin
  if jsonb_typeof(j) = 'object' then for k, v in select * from jsonb_each(j) loop return next k; return query select * from pg_temp.jkeys(v); end loop;
  elsif jsonb_typeof(j) = 'array' then for e in select * from jsonb_array_elements(j) loop return query select * from pg_temp.jkeys(e); end loop; end if;
end $f$;
create function pg_temp.banned(j jsonb) returns text language sql as $f$
  select string_agg(distinct k, ',') from pg_temp.jkeys(j) k where k ~* '(cost|margin|profit|commission|supplier|officer|buying|wholesale_price|markup|evidence|candidate|staff_note|internal)'
$f$;
-- a catalogue row / design row as the customer sees it
create function pg_temp.catrow(p_user uuid, p_product text) returns jsonb language sql as $f$
  select e from jsonb_array_elements(pg_temp.q(p_user, 'authenticated', 'select * from public.customer_catalog()')::jsonb) e where e ->> 'id' = p_product $f$;
create function pg_temp.desrow(p_user uuid, p_design uuid) returns jsonb language sql as $f$
  select e from jsonb_array_elements(pg_temp.q(p_user, 'authenticated', 'select * from public.customer_designs()')::jsonb) e where e ->> 'id' = p_design::text $f$;
create function pg_temp.preview(p_user uuid, p_lines jsonb) returns text language sql as $f$
  select pg_temp.q(p_user, 'authenticated', format('select public.customer_price_preview(%L::jsonb) as v', p_lines::text)) $f$;
create function pg_temp.hist(p_order text, p_customer text, p_days_ago integer, p_product text, p_design_name text, p_qty integer, p_standard numeric, p_actual numeric, p_status text default 'delivered', p_type text default 'regular') returns void language plpgsql as $f$
begin
  insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) values (p_order, p_customer, 'T26', '', p_status::public.order_status, p_type::public.order_type, public.efz_today() - p_days_ago, '');
  insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost)
  values ('itm-' || p_order, p_order, p_product, 'H', p_design_name, p_qty, p_standard, p_actual, 1);
end $f$;

do $t$
declare
  sa_u  uuid := 'a6000000-0000-4000-8000-000000000001';   -- Super Admin
  mgr_u uuid := 'a6000000-0000-4000-8000-000000000002';   -- Manager: can manage prices (can_manage_pricing), reviews accounts, is NOT a Super Admin
  off_u uuid := 'a6000000-0000-4000-8000-000000000003';   -- Marketing Officer: no pricing rights
  ca uuid := 'c6000000-0000-4000-8000-00000000000a';      -- customer A (app account)
  cb uuid := 'c6000000-0000-4000-8000-00000000000b';      -- customer B (app account)
  cx uuid := 'c6000000-0000-4000-8000-0000000000fa';      -- signed in, not a customer
  dA1 uuid := 'd2600000-0000-4000-8000-000000000001'; dA2 uuid := 'd2600000-0000-4000-8000-000000000002';
  acc record; t text; j jsonb; v_a text; v_b text; v_today date := public.efz_today(); v_ag uuid; v_ag2 uuid; v_ag3 uuid; v_n int; v_n2 int; v_co jsonb; v_id uuid; v_order text; v_rev0 numeric; v_rev1 numeric;
  rep jsonb; v_res jsonb; v_cand1 uuid; v_cand2 uuid; v_before int;
begin
  -- ---------------------------------------------------------------- fixtures
  alter table public.orders disable trigger user;
  update public.orders set status = 'cancelled' where status <> 'cancelled';     -- (fixture, rolled back) existing orders must not influence the import report or the revenue
  alter table public.orders enable trigger user;
  insert into public.profiles (id, name, email, role, status) values
    ('u-t26-sa', 'T26 Super Admin', 't26-sa@example.test', 'Super Admin', 'active'), ('u-t26-mgr', 'T26 Manager', 't26-mgr@example.test', 'Manager', 'active'),
    ('u-t26-off', 'T26 Officer', 't26-off@example.test', 'Marketing Officer', 'active');
  insert into public.user_permissions (user_id, permission_code) values ('u-t26-mgr', 'manage_customer_accounts'), ('u-t26-mgr', 'edit_products'), ('u-t26-mgr', 'view_all_customers'), ('u-t26-mgr', 'view_orders'), ('u-t26-mgr', 'create_orders'), ('u-t26-mgr', 'edit_orders');
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
    (sa_u, 'authenticated', 'authenticated', 't26-sa@example.test', now(), '{"provider":"email"}', '{}', now(), now()), (mgr_u, 'authenticated', 'authenticated', 't26-mgr@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
    (off_u, 'authenticated', 'authenticated', 't26-off@example.test', now(), '{"provider":"email"}', '{}', now(), now()), (cx, 'authenticated', 'authenticated', 't26-x@example.test', now(), '{"provider":"email"}', '{}', now(), now());
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  select u, 'authenticated', 'authenticated', e, now(), '{"provider":"email","efz_kind":"customer"}', '{}', now(), now() from (values (ca, 't26-a@example.test'), (cb, 't26-b@example.test')) v(u, e);
  insert into public.products (id, name, selling_price, cost_price, stock, is_active) values
    ('p26-a', 'T26 Ball A', 10.00, 6.00, 1000000, true), ('p26-b', 'T26 Ball B', 20.00, 12.00, 1000000, true), ('p26-c', 'T26 Ball C', 8.00, 5.00, 1000000, true), ('p26-d', 'T26 Ball D', 15.00, 9.00, 1000000, true);
  insert into public.product_designs (id, product_id, name, sort_order, is_active) values (dA1, 'p26-a', 'Red', 1, true), (dA2, 'p26-a', 'Blue', 2, true);
  for acc in select * from (values (ca, 't26-a@example.test', 'T26 Buyer A', '069 826 0001'), (cb, 't26-b@example.test', 'T26 Buyer B', '069 826 0002')) v(u, e, n, ph) loop
    perform pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, %L, %L, '''', null)', acc.u, acc.e, acc.n, acc.ph));
  end loop;
  for acc in select id from public.customer_accounts where email in ('t26-a@example.test', 't26-b@example.test') loop
    perform pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, null, true, false, ''Verified (T26)'')', acc.id));
  end loop;
  select customer_id into v_a from public.customer_accounts where email = 't26-a@example.test'; select customer_id into v_b from public.customer_accounts where email = 't26-b@example.test';
  insert into public.customers (id, name, email, phone, notes, status) values ('cust-t26-c', 'T26 History C', 'c@example.test', '069 826 0003', 'history', 'active'), ('cust-t26-d', 'T26 History D', 'd@example.test', '069 826 0004', 'history', 'active'),
    ('cust-t26-e', 'T26 History E', 'e@example.test', '069 826 0005', 'history', 'active'), ('cust-t26-f', 'T26 History F', 'f@example.test', '069 826 0006', 'history', 'active');
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_payment_method(''stg_test'', ''Staging Test'', ''staging_test'', true, ''Staging test method (T26)'') as v');

  -- ---------------------------------------------------------------- A. authorization and exposure of the new objects
  perform pg_temp.chk('A1 every price-agreement admin function refuses an Officer, a customer and anonymous callers (42501)',
    (select bool_and(pg_temp.denied(pg_temp.q(u, r, sql))) from (values (off_u, 'authenticated'), (ca, 'authenticated'), (cx, 'authenticated'), (null::uuid, 'anon')) c(u, r),
       (values (format('select public.create_price_agreement(%L, ''p26-a'', null, 8, current_date, null, ''Agreed with the owner (T26)'') as v', v_a)),
               ('select public.verify_price_agreement(gen_random_uuid(), 8, current_date, null, ''Confirmed by the owner (T26)'') as v'), ('select public.replace_price_agreement(gen_random_uuid(), 8, current_date, null, ''Changing the price (T26 reason)'') as v'), ('select public.reject_price_agreement(gen_random_uuid(), ''Not a real agreement (T26)'') as v'),
               ('select public.revoke_price_agreement(gen_random_uuid(), ''Agreement withdrawn (T26)'') as v'), ('select public.end_price_agreement(gen_random_uuid(), current_date, ''Agreement ends (T26)'') as v'),
               ('select public.list_price_agreements() as v'), ('select public.price_agreement_history(''x'') as v'), ('select public.price_agreement_alerts() as v'),
               (format('select public.resolve_customer_price(%L, ''p26-a'', null) as v', v_a)), ('select public.import_price_candidates(true) as v')) f(sql)));
  perform pg_temp.chk('A2 customers, Officers, anonymous callers and even service_role cannot read or write the three new tables; the internal helpers cannot be called',
    (select bool_and(pg_temp.none(pg_temp.q(u, r, 'select 1 as v from public.' || tb))) from (values (ca, 'authenticated'), (off_u, 'authenticated'), (null::uuid, 'anon'), (null::uuid, 'service_role')) c(u, r),
       (values ('customer_price_agreements'), ('price_agreement_events'), ('order_price_resolutions')) x(tb))
    and (select bool_and(pg_temp.denied(pg_temp.q(u, 'authenticated', sql))) from (values (sa_u), (mgr_u), (ca)) c(u),
       (values ('select public._price_resolve(''x'', ''p26-a'', null, null) as v'), ('select public._customer_price_cart(''[]''::jsonb, ''x'') as v'), ('select public._price_event(gen_random_uuid(), ''x'', ''created'', ''{}''::jsonb) as v'), ('select public._require_pricing_admin() as v')) h(sql)));
  perform pg_temp.chk('A3 a Manager (not a Super Admin) is allowed to manage prices, and an Officer is not: pricing rights are exactly can_manage_pricing',
    not pg_temp.err(pg_temp.q(mgr_u, 'authenticated', 'select public.price_agreement_alerts() as v')) and not pg_temp.err(pg_temp.q(sa_u, 'authenticated', 'select public.price_agreement_alerts() as v')) and pg_temp.denied(pg_temp.q(off_u, 'authenticated', 'select public.price_agreement_alerts() as v')));

  -- ---------------------------------------------------------------- B. resolution: standard price, per-customer, per-design, dates
  perform pg_temp.chk('B1 without any agreement every customer sees the list price, marked as such (A and B: ball A 10.00, ball B 20.00)',
    (pg_temp.catrow(ca, 'p26-a') ->> 'selling_price')::numeric = 10 and (pg_temp.catrow(ca, 'p26-a') ->> 'price_status') = 'list' and (pg_temp.catrow(cb, 'p26-b') ->> 'selling_price')::numeric = 20);
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p26-a'', null, 8.00, %L, null, ''Agreed with the owner in 2025 (T26)'') as v', v_a, v_today - 1)); v_ag := (pg_temp.jv(t) #>> '{}')::uuid;
  perform pg_temp.chk('B2 a Manager records an agreement: customer A pays 8.00 for ball A (list 10.00), marked "agreement"; customer B still pays 10.00; ball B is unchanged for both',
    not pg_temp.err(t) and (pg_temp.catrow(ca, 'p26-a') ->> 'selling_price')::numeric = 8 and (pg_temp.catrow(ca, 'p26-a') ->> 'price_status') = 'agreement' and (pg_temp.catrow(ca, 'p26-a') ->> 'list_price')::numeric = 10
    and (pg_temp.catrow(cb, 'p26-a') ->> 'selling_price')::numeric = 10 and (pg_temp.catrow(cb, 'p26-a') ->> 'price_status') = 'list' and (pg_temp.catrow(ca, 'p26-b') ->> 'selling_price')::numeric = 20, t);
  perform pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p26-a'', %L, 7.00, %L, null, ''Special Red price agreed (T26)'') as v', v_a, dA1, v_today));
  perform pg_temp.chk('B3 a design-specific agreement beats the product-wide one for that design only: A pays 7.00 for Red and 8.00 for Blue (the product agreement); B pays 10.00 for both',
    (pg_temp.desrow(ca, dA1) ->> 'price')::numeric = 7 and (pg_temp.desrow(ca, dA2) ->> 'price')::numeric = 8 and (pg_temp.desrow(ca, dA1) ->> 'price_status') = 'agreement' and (pg_temp.desrow(cb, dA1) ->> 'price')::numeric = 10 and (pg_temp.desrow(cb, dA2) ->> 'price')::numeric = 10);
  t := pg_temp.preview(ca, jsonb_build_array(jsonb_build_object('productId', 'p26-a', 'designId', dA1, 'quantity', 2), jsonb_build_object('productId', 'p26-a', 'designId', dA2, 'quantity', 3), jsonb_build_object('productId', 'p26-b', 'quantity', 1))); j := pg_temp.jv(t);
  perform pg_temp.chk('B4 a multi-design cart is priced line by line by the server: 2 x 7.00 (Red) + 3 x 8.00 (Blue) + 1 x 20.00 (list) = 58.00, with the source of every price and the list price shown',
    (j ->> 'total')::numeric = 58 and (select string_agg((l ->> 'unitPrice') || ':' || (l ->> 'priceSource') || ':' || (l ->> 'listPrice'), ',' order by ord) from jsonb_array_elements(j -> 'lines') with ordinality l(l, ord)) = '7.00:agreement:10.00,8.00:agreement:10.00,20.00:list:20.00', t);
  perform pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p26-a'', %L, 9.00, %L, null, ''Blue agreed for B only (T26)'') as v', v_b, dA2, v_today));
  j := pg_temp.jv(pg_temp.preview(cb, jsonb_build_array(jsonb_build_object('productId', 'p26-a', 'designId', dA1, 'quantity', 1), jsonb_build_object('productId', 'p26-a', 'designId', dA2, 'quantity', 1))));
  perform pg_temp.chk('B5 different customers, different prices: B pays 10.00 (Red, list) + 9.00 (Blue, agreed) = 19.00 while A still pays 7.00 + 8.00 for the same two designs', (j ->> 'total')::numeric = 19
    and (pg_temp.jv(pg_temp.preview(ca, jsonb_build_array(jsonb_build_object('productId', 'p26-a', 'designId', dA1, 'quantity', 1), jsonb_build_object('productId', 'p26-a', 'designId', dA2, 'quantity', 1)))) ->> 'total')::numeric = 15, j::text);
  -- dates: expired, boundary and future
  perform pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p26-c'', null, 6.50, %L, %L, ''Seasonal price that has ended (T26)'') as v', v_a, v_today - 10, v_today - 1));
  perform pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p26-d'', null, 12.00, %L, %L, ''Price valid until today (T26)'') as v', v_a, v_today - 10, v_today));
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p26-d'', null, 11.00, %L, null, ''Next price after today (T26)'') as v', v_a, v_today + 1));
  perform pg_temp.chk('B6 expiry and start dates: an agreement that ended YESTERDAY no longer applies (ball C back to the list price 8.00, marked list); one that ends TODAY still applies (ball D 12.00); one that starts tomorrow is accepted without overlap and does not apply yet',
    (pg_temp.catrow(ca, 'p26-c') ->> 'selling_price')::numeric = 8 and (pg_temp.catrow(ca, 'p26-c') ->> 'price_status') = 'list' and (pg_temp.catrow(ca, 'p26-d') ->> 'selling_price')::numeric = 12 and not pg_temp.err(t), t);
  perform pg_temp.chk('B7 an agreement cannot overlap another one for the same customer, product and design (but a different design, a different customer or an adjacent period is fine)',
    pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p26-a'', null, 8.50, %L, null, ''A second product-wide price (T26)'') as v', v_a, v_today)))
    and pg_temp.msg(pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p26-a'', null, 8.50, %L, null, ''A second product-wide price (T26)'') as v', v_a, v_today))) like '%overlapping%'
    and not pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p26-c'', null, 7.00, %L, null, ''Another period, same customer (T26)'') as v', v_a, v_today))));
  perform pg_temp.chk('B8 validation: a Manager cannot record a price without a reason, with a bad price, an unknown customer or product, a design of another product, or an end before the start',
    (select bool_and(pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format(sql, v_a)))) from (values
      ('select public.create_price_agreement(%L, ''p26-c'', null, 7, current_date, null, ''short'') as v'), ('select public.create_price_agreement(%L, ''p26-c'', null, 0, current_date, null, ''A valid reason is long enough'') as v'),
      ('select public.create_price_agreement(%L, ''p26-c'', null, 7.005, current_date, null, ''A valid reason is long enough'') as v'), ('select public.create_price_agreement(''nope'', ''p26-c'', null, 7, current_date, null, ''A valid reason is long enough'') as v'),
      ('select public.create_price_agreement(%L, ''nope'', null, 7, current_date, null, ''A valid reason is long enough'') as v'), ('select public.create_price_agreement(%L, ''p26-c'', ''d2600000-0000-4000-8000-000000000001'', 7, current_date, null, ''A valid reason is long enough'') as v'),
      ('select public.create_price_agreement(%L, ''p26-c'', null, 7, current_date, current_date - 5, ''A valid reason is long enough'') as v')) f(sql)));
  -- below cost: needs a Super Admin and a reason, exactly as create_order
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p26-c'', null, 4.00, %L, null, ''Below cost clearance (T26)'', ''Clearing old stock with the owner'') as v', v_b, v_today));
  perform pg_temp.chk('B9a a price BELOW COST by a Manager is refused (42501): only a Super Admin can approve it, as create_order requires', pg_temp.denied(t), t);
  t := pg_temp.q(sa_u, 'authenticated', format('select public.create_price_agreement(%L, ''p26-c'', null, 4.00, %L, null, ''Below cost clearance (T26)'') as v', v_b, v_today));
  perform pg_temp.chk('B9b a Super Admin without a below-cost reason is refused too', pg_temp.err(t) and pg_temp.msg(t) like '%below-cost price needs a reason%', t);
  t := pg_temp.q(sa_u, 'authenticated', format('select public.create_price_agreement(%L, ''p26-c'', null, 4.00, %L, null, ''Below cost clearance (T26)'', ''Clearing old stock with the owner'') as v', v_b, v_today));
  perform pg_temp.chk('B9c with a reason the Super Admin records it: flagged approved, and customer B then pays 4.00 although the cost is 5.00 (audited as a WARNING)',
    not pg_temp.err(t) and (pg_temp.catrow(cb, 'p26-c') ->> 'selling_price')::numeric = 4 and (select below_cost_approved from public.customer_price_agreements where customer_id = v_b and product_id = 'p26-c')
    and exists (select 1 from public.system_logs where metadata ->> 'event' = 'price_agreement_created' and metadata ->> 'belowCost' = 'true' and severity = 'WARNING'), t);
  update public.products set cost_price = 9 where id = 'p26-a';
  j := pg_temp.catrow(ca, 'p26-a');
  perform pg_temp.chk('B10 an agreement that BECOMES below cost later (the cost rose to 9.00 against the agreed 8.00) and was never approved is not used silently: the line needs review (status review, no price) and cannot be bought online',
    (j ->> 'price_status') = 'review' and j -> 'selling_price' = 'null'::jsonb and pg_temp.err(pg_temp.preview(ca, jsonb_build_array(jsonb_build_object('productId', 'p26-a', 'designId', dA2, 'quantity', 1)))), j::text);
  update public.products set cost_price = 6 where id = 'p26-a';
  -- pending (unverified) candidate
  insert into public.customer_price_agreements (customer_id, product_id, design_id, unit_price, effective_from, status, source, reason, candidate_evidence, created_by)
  values (v_a, 'p26-b', null, 18.00, v_today - 5, 'pending_review', 'import', 'candidate', '{"orders": 3}'::jsonb, null);
  select id into v_ag3 from public.customer_price_agreements where customer_id = v_a and product_id = 'p26-b' and status = 'pending_review';
  j := pg_temp.catrow(ca, 'p26-b');
  perform pg_temp.chk('B11 an UNVERIFIED agreement is never used and never ignored: while a candidate for ball B waits for verification the line needs review (no price, cannot be bought online, the message says EFZ must confirm it), other lines and other customers are unaffected',
    (j ->> 'price_status') = 'review' and pg_temp.msg(pg_temp.preview(ca, jsonb_build_array(jsonb_build_object('productId', 'p26-b', 'quantity', 1)))) like '%needs to be confirmed by EFZ%'
    and not pg_temp.err(pg_temp.preview(ca, jsonb_build_array(jsonb_build_object('productId', 'p26-c', 'quantity', 1)))) and (pg_temp.catrow(cb, 'p26-b') ->> 'price_status') = 'list', j::text);
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.verify_price_agreement(%L, 18.00, %L, null, ''Confirmed with the customer and the owner (T26)'') as v', v_ag3, v_today - 5));
  perform pg_temp.chk('B12 verification by an authorized person makes it active: ball B is now 18.00 for A (agreement); verifying again is refused; the event history records candidate price and confirmed price',
    not pg_temp.err(t) and (pg_temp.catrow(ca, 'p26-b') ->> 'selling_price')::numeric = 18 and pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.verify_price_agreement(%L, 18.00, %L, null, ''Confirmed twice by mistake (T26)'') as v', v_ag3, v_today - 5)))
    and exists (select 1 from public.price_agreement_events where agreement_id = v_ag3 and kind = 'verified' and (details ->> 'candidatePrice')::numeric = 18 and (details ->> 'confirmedPrice')::numeric = 18), t);
  -- conflicting data (the guard normally prevents it): the resolver must not guess
  alter table public.customer_price_agreements disable trigger trg_price_agreement_guard;
  insert into public.customer_price_agreements (customer_id, product_id, design_id, unit_price, effective_from, status, source, reason, created_by) values (v_a, 'p26-b', null, 17.00, v_today - 2, 'active', 'manual', 'conflicting row', null) returning id into v_ag2;
  alter table public.customer_price_agreements enable trigger trg_price_agreement_guard;
  j := pg_temp.catrow(ca, 'p26-b');
  perform pg_temp.chk('B13 two active agreements for the same key (impossible through the functions; forced here) are never resolved by guessing: the line needs review', (j ->> 'price_status') = 'review' and pg_temp.msg(pg_temp.preview(ca, jsonb_build_array(jsonb_build_object('productId', 'p26-b', 'quantity', 1)))) like '%needs to be confirmed%', j::text);
  alter table public.customer_price_agreements disable trigger trg_price_agreement_guard; delete from public.customer_price_agreements where id = v_ag2; alter table public.customer_price_agreements enable trigger trg_price_agreement_guard;
  perform pg_temp.chk('B14 the staff view of the same decision (resolve_customer_price) agrees with what the customer sees', (pg_temp.jv(pg_temp.q(mgr_u, 'authenticated', format('select public.resolve_customer_price(%L, ''p26-a'', %L) as v', v_a, dA1))) ->> 'price')::numeric = 7
    and (pg_temp.jv(pg_temp.q(mgr_u, 'authenticated', format('select public.resolve_customer_price(%L, ''p26-a'', %L) as v', v_b, dA1))) ->> 'source') = 'list');

  -- ---------------------------------------------------------------- C. the client can never choose the price
  t := pg_temp.q(ca, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'stg_test', 'deliveryLocation', 'Hodan', 'submissionKey', 'f2600000-0000-4000-8000-000000000001', 'customerId', v_b, 'priceListId', 'x',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p26-a', 'designId', dA1, 'quantity', 2, 'unitPrice', 0.01, 'price', 0.01, 'listPrice', 0.01, 'agreementId', v_ag, 'priceSource', 'agreement'), jsonb_build_object('productId', 'p26-a', 'designId', dA2, 'quantity', 3, 'unitPrice', 0.01)),
        'amount', 0.01, 'total', 0.01)::text)); v_co := pg_temp.jv(t);
  perform pg_temp.chk('C1 price manipulation: prices, totals, list prices, agreement ids, a customer id and a price source sent by the app are all ignored; the checkout is 2 x 7.00 + 3 x 8.00 = 38.00 for A',
    not pg_temp.err(t) and (v_co ->> 'amount')::numeric = 38 and (select string_agg(l ->> 'unitPrice', ',' order by l ->> 'designName') from jsonb_array_elements(v_co -> 'lines') l) = '8.00,7.00', t);
  t := pg_temp.q(cb, 'authenticated', format('select public.customer_start_checkout(%L::jsonb) as v', jsonb_build_object('methodCode', 'stg_test', 'deliveryLocation', 'Hodan', 'submissionKey', 'f2600000-0000-4000-8000-000000000002',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p26-a', 'designId', dA1, 'quantity', 2), jsonb_build_object('productId', 'p26-a', 'designId', dA2, 'quantity', 3)))::text));
  perform pg_temp.chk('C2 the same cart for customer B is priced as B: 2 x 10.00 + 3 x 9.00 = 47.00 (no sharing of A''s agreement through the cart)', not pg_temp.err(t) and (pg_temp.jv(t) ->> 'amount')::numeric = 47, t);
  perform pg_temp.chk('C3 a customer cannot read agreements, cannot call any admin function and cannot name another customer: my_price_agreements takes no customer and shows only the caller''s own agreements',
    (select count(*) from jsonb_array_elements(pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.my_price_agreements() as v'))) e where e ->> 'productId' in ('p26-a', 'p26-b', 'p26-d')) = 4
    and (select count(*) from jsonb_array_elements(pg_temp.jv(pg_temp.q(cb, 'authenticated', 'select public.my_price_agreements() as v'))) e) = 2
    and pg_temp.denied(pg_temp.q(ca, 'authenticated', format('select public.list_price_agreements(%L) as v', v_b))));

  -- ---------------------------------------------------------------- D. the paid path, immutable snapshots, revenue
  v_id := (v_co ->> 'checkoutId')::uuid;
  select coalesce((x ->> 'revenue_generated')::numeric, 0) into v_rev0 from jsonb_array_elements(pg_temp.q(sa_u, 'authenticated', 'select * from public.financial_summary')::jsonb) x limit 1;
  t := pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''stg_test'', ''evt-26-1'', ''succeeded'', 38.00, ''PROV-26-1'', ''hash26'', true) as v', v_id));
  v_order := (select order_id from public.customer_checkouts where id = v_id);
  perform pg_temp.chk('D1 the verified payment becomes ONE order at the agreed prices: Red 2 x 7.00 and Blue 3 x 8.00, each line keeping the list price (10.00) as its standard price; the total is 38.00 and fully paid',
    not pg_temp.err(t) and v_order is not null and (select string_agg(design_name || ':' || quantity || ':' || standard_unit_price || ':' || actual_unit_price, ',' order by design_name) from public.order_items where order_id = v_order) = 'Blue:3:10.00:8.00,Red:2:10.00:7.00'
    and (select total || '|' || amount_paid from public.orders where id = v_order) = '38.00|38.00', t);
  perform pg_temp.chk('D2 every line records which agreement produced it (order_price_resolutions: source, agreement, list and applied price) and the record cannot be edited or deleted',
    (select count(*) from public.order_price_resolutions where order_id = v_order and source = 'agreement' and agreement_id in (v_ag, (select id from public.customer_price_agreements where customer_id = v_a and design_id = dA1)) and list_price = 10) = 2
    and (select count(*) from public.order_price_resolutions where order_id = v_order and applied_price in (7, 8)) = 2);
  begin update public.order_price_resolutions set applied_price = 1 where order_id = v_order; perform pg_temp.chk('D2b a price resolution record cannot be rewritten', false); exception when others then perform pg_temp.chk('D2b a price resolution record cannot be rewritten', sqlstate = '42501'); end;
  j := pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.my_orders() as v'));
  perform pg_temp.chk('D3 the customer''s order history shows the agreed unit prices (7.00 for Red, 8.00 for Blue) and the 38.00 total',
    (select (o ->> 'total')::numeric = 38 and exists (select 1 from jsonb_array_elements(o -> 'items') i where i ->> 'designName' = 'Red' and (i ->> 'unitPrice')::numeric = 7) and exists (select 1 from jsonb_array_elements(o -> 'items') i where i ->> 'designName' = 'Blue' and (i ->> 'unitPrice')::numeric = 8)
       from jsonb_array_elements(j) o where o ->> 'id' = v_order), j::text);
  select coalesce((x ->> 'revenue_generated')::numeric, 0) into v_rev1 from jsonb_array_elements(pg_temp.q(sa_u, 'authenticated', 'select * from public.financial_summary')::jsonb) x limit 1;
  perform pg_temp.chk('D4 revenue reporting follows the price actually charged: EFZ''s existing revenue figure (financial_summary) rose by exactly the order total, 38.00', v_rev1 - v_rev0 = 38, v_rev0::text || ' -> ' || v_rev1::text);
  -- change everything afterwards
  perform pg_temp.q(mgr_u, 'authenticated', format('select public.revoke_price_agreement(%L, ''Agreement withdrawn by the owner (T26)'') as v', v_ag));
  perform pg_temp.q(mgr_u, 'authenticated', format('select public.revoke_price_agreement(%L, ''Red price withdrawn by the owner (T26)'') as v', (select id from public.customer_price_agreements where customer_id = v_a and design_id = dA1)));
  update public.products set selling_price = 11 where id = 'p26-a';
  select coalesce((x ->> 'revenue_generated')::numeric, 0) into v_rev0 from jsonb_array_elements(pg_temp.q(sa_u, 'authenticated', 'select * from public.financial_summary')::jsonb) x limit 1;
  perform pg_temp.chk('D5 HISTORY IS FROZEN: after the agreements were revoked and the list price changed, the old order, its lines (standard 10.00, actual 7.00 / 8.00), its total, its payment, its resolution records and the revenue figure are exactly as they were',
    (select string_agg(design_name || ':' || quantity || ':' || standard_unit_price || ':' || actual_unit_price, ',' order by design_name) from public.order_items where order_id = v_order) = 'Blue:3:10.00:8.00,Red:2:10.00:7.00'
    and (select total || '|' || amount_paid from public.orders where id = v_order) = '38.00|38.00' and (select count(*) from public.order_price_resolutions where order_id = v_order and agreement_id is not null) = 2 and v_rev0 = v_rev1);
  j := pg_temp.jv(pg_temp.preview(ca, jsonb_build_array(jsonb_build_object('productId', 'p26-a', 'designId', dA1, 'quantity', 1))));
  perform pg_temp.chk('D6 new orders after the revocation use the new situation (list price 11.00, source list), so a revoked agreement is gone for new orders but not for history', (j ->> 'total')::numeric = 11 and (j -> 'lines' -> 0 ->> 'priceSource') = 'list', j::text);
  update public.products set selling_price = 10 where id = 'p26-a';
  -- start before, change, confirm after: the payment is parked for review, never silently re-priced
  v_id := (select id from public.customer_checkouts where customer_id = v_b and submission_key = 'f2600000-0000-4000-8000-000000000002');
  perform pg_temp.q(mgr_u, 'authenticated', format('select public.revoke_price_agreement(%L, ''B Blue price withdrawn before payment (T26)'') as v', (select id from public.customer_price_agreements where customer_id = v_b and design_id = dA2)));
  t := pg_temp.q(null, 'service_role', format('select public.finalize_customer_checkout(%L, ''stg_test'', ''evt-26-2'', ''succeeded'', 47.00, ''PROV-26-2'', ''hash26b'', true) as v', v_id));
  perform pg_temp.chk('D7 an agreement withdrawn between the start of a checkout and the provider''s confirmation: the verified payment is NOT turned into an order at a different price; it is parked as needs_review for staff, with no order and no payment record',
    (select status from public.customer_checkouts where id = v_id) = 'needs_review' and (select count(*) from public.orders where customer_id = v_b and payment_terms = 'paid_at_sale') = 0 and (select failure_reason from public.customer_checkouts where id = v_id) like '%Prices changed%', t);

  -- ---------------------------------------------------------------- E. importing verified agreements from order history (nothing invented)
  perform pg_temp.hist('H-C1', 'cust-t26-c', 60, 'p26-a', 'Red', 1, 10, 7); perform pg_temp.hist('H-C2', 'cust-t26-c', 40, 'p26-a', 'Red', 2, 10, 7); perform pg_temp.hist('H-C3', 'cust-t26-c', 20, 'p26-a', 'Red', 1, 10, 7);
  perform pg_temp.hist('H-C4', 'cust-t26-c', 50, 'p26-b', 'T26 Ball B', 2, 20, 18); perform pg_temp.hist('H-C5', 'cust-t26-c', 30, 'p26-b', 'T26 Ball B', 1, 20, 18);
  perform pg_temp.hist('H-D1', 'cust-t26-d', 50, 'p26-a', 'Blue', 1, 10, 9); perform pg_temp.hist('H-D2', 'cust-t26-d', 40, 'p26-a', 'Blue', 1, 10, 8.5); perform pg_temp.hist('H-D3', 'cust-t26-d', 30, 'p26-a', 'Blue', 1, 10, 9);
  perform pg_temp.hist('H-D4', 'cust-t26-d', 30, 'p26-d', 'T26 Ball D', 1, 15, 12);
  perform pg_temp.hist('H-E1', 'cust-t26-e', 50, 'p26-b', 'T26 Ball B', 1, 20, 18); perform pg_temp.hist('H-E2', 'cust-t26-e', 30, 'p26-b', 'T26 Ball B', 1, 18, 18);
  perform pg_temp.hist('H-E3', 'cust-t26-e', 50, 'p26-c', 'T26 Ball C', 1, 8, 4); perform pg_temp.hist('H-E4', 'cust-t26-e', 40, 'p26-c', 'T26 Ball C', 1, 8, 4); perform pg_temp.hist('H-E5', 'cust-t26-e', 30, 'p26-c', 'T26 Ball C', 1, 8, 4);
  perform pg_temp.hist('H-E6', 'cust-t26-e', 50, 'p26-a', 'Purple', 1, 10, 7); perform pg_temp.hist('H-E7', 'cust-t26-e', 30, 'p26-a', 'Purple', 1, 10, 7);
  perform pg_temp.hist('H-F1', 'cust-t26-f', 50, 'p26-b', 'T26 Ball B', 1, 20, 20); perform pg_temp.hist('H-F2', 'cust-t26-f', 40, 'p26-d', 'T26 Ball D', 1, 15, 12, 'cancelled'); perform pg_temp.hist('H-F3', 'cust-t26-f', 30, 'p26-d', 'T26 Ball D', 1, 15, 12, 'delivered', 'trial');
  perform pg_temp.hist('H-F4', 'cust-t26-f', 400, 'p26-d', 'T26 Ball D', 1, 15, 12); perform pg_temp.hist('H-F5', 'cust-t26-f', 399, 'p26-d', 'T26 Ball D', 1, 15, 12);
  select count(*) into v_before from public.customer_price_agreements;
  t := pg_temp.q(mgr_u, 'authenticated', 'select public.import_price_candidates(true) as v'); rep := pg_temp.jv(t);
  perform pg_temp.chk('E1 the import is a DRY RUN by default: it reports what it found and writes NOTHING',
    not pg_temp.err(t) and (rep ->> 'dryRun') = 'true' and (select count(*) from public.customer_price_agreements) = v_before and (rep ->> 'created')::int = 0, left(t, 200));
  perform pg_temp.chk('E2 consistent history becomes a candidate (customer C: Red at 7.00 in 3 orders; ball B at 18.00 in 2 orders); the proposal carries the price, the first order date and the evidence, nothing else',
    jsonb_array_length(rep -> 'candidates') = 2 and exists (select 1 from jsonb_array_elements(rep -> 'candidates') c where c ->> 'customerId' = 'cust-t26-c' and c ->> 'designName' = 'Red' and (c ->> 'proposedPrice')::numeric = 7 and (c ->> 'orders')::int = 3 and c ->> 'proposedFrom' = (v_today - 60)::text and c ->> 'designId' = dA1::text)
    and exists (select 1 from jsonb_array_elements(rep -> 'candidates') c where c ->> 'customerId' = 'cust-t26-c' and c ->> 'productId' = 'p26-b' and (c ->> 'proposedPrice')::numeric = 18 and c -> 'designId' = 'null'::jsonb), left(rep::text, 300));
  perform pg_temp.chk('E3 everything ambiguous is reported for MANUAL CONFIRMATION with the reason and the evidence, and is never proposed: varying prices (D: 9.00 / 8.50 / 9.00), a single order, some orders at list price, a price below cost, an unknown design',
    (select count(*) from jsonb_array_elements(rep -> 'needsConfirmation') c where c ->> 'customerId' like 'cust-t26-%') = 5
    and exists (select 1 from jsonb_array_elements(rep -> 'needsConfirmation') c where c ->> 'customerId' = 'cust-t26-d' and c ->> 'designName' = 'Blue' and c ->> 'reason' like 'the price varies between $8.50 and $9.00%')
    and exists (select 1 from jsonb_array_elements(rep -> 'needsConfirmation') c where c ->> 'customerId' = 'cust-t26-d' and c ->> 'productId' = 'p26-d' and c ->> 'reason' like 'only 1 order(s)%')
    and exists (select 1 from jsonb_array_elements(rep -> 'needsConfirmation') c where c ->> 'customerId' = 'cust-t26-e' and c ->> 'productId' = 'p26-b' and c ->> 'reason' = 'some of the orders were sold at the list price')
    and exists (select 1 from jsonb_array_elements(rep -> 'needsConfirmation') c where c ->> 'customerId' = 'cust-t26-e' and c ->> 'productId' = 'p26-c' and c ->> 'reason' like 'the price is below the current cost%')
    and exists (select 1 from jsonb_array_elements(rep -> 'needsConfirmation') c where c ->> 'customerId' = 'cust-t26-e' and c ->> 'designName' = 'Purple' and c ->> 'reason' like 'the design "Purple" does not match%'), left((rep -> 'needsConfirmation')::text, 300));
  perform pg_temp.chk('E4 history that is not a negotiated price is never reported: orders at the list price, cancelled orders, trial orders and orders older than the look-back period (customer F)',
    not exists (select 1 from jsonb_array_elements((rep -> 'candidates') || (rep -> 'needsConfirmation')) c where c ->> 'customerId' = 'cust-t26-f'));
  perform pg_temp.chk('E5 only authorized staff can run the import: an Officer, a customer and anonymous callers are refused; a Manager and a Super Admin may', pg_temp.denied(pg_temp.q(off_u, 'authenticated', 'select public.import_price_candidates(true) as v')) and pg_temp.denied(pg_temp.q(ca, 'authenticated', 'select public.import_price_candidates(false) as v'))
    and not pg_temp.err(pg_temp.q(sa_u, 'authenticated', 'select public.import_price_candidates(true) as v')));
  t := pg_temp.q(mgr_u, 'authenticated', 'select public.import_price_candidates(false) as v'); rep := pg_temp.jv(t);
  perform pg_temp.chk('E6 the real run records ONLY the two consistent candidates, as PENDING (not usable): source import, the price from the history, the evidence and an audit event each; the five ambiguous ones create nothing',
    (rep ->> 'created')::int = 2 and (select count(*) from public.customer_price_agreements where source = 'import' and status = 'pending_review' and customer_id like 'cust-t26-%') = 2
    and not exists (select 1 from public.customer_price_agreements where customer_id in ('cust-t26-d', 'cust-t26-e', 'cust-t26-f')) and (select count(*) from public.price_agreement_events where kind = 'candidate_imported' and customer_id = 'cust-t26-c') = 2
    and (select bool_and(candidate_evidence ->> 'orders' is not null) from public.customer_price_agreements where source = 'import' and customer_id = 'cust-t26-c'), left(t, 200));
  t := pg_temp.q(mgr_u, 'authenticated', 'select public.import_price_candidates(false) as v');
  perform pg_temp.chk('E7 running the import again creates nothing new (the candidates already exist) and reports them as already covered', (pg_temp.jv(t) ->> 'created')::int = 0 and (pg_temp.jv(t) ->> 'alreadyCovered')::int = 2 and jsonb_array_length(pg_temp.jv(t) -> 'candidates') = 0, left(t, 200));
  select id into v_cand1 from public.customer_price_agreements where customer_id = 'cust-t26-c' and design_id = dA1; select id into v_cand2 from public.customer_price_agreements where customer_id = 'cust-t26-c' and product_id = 'p26-b';
  perform pg_temp.chk('E8 a pending candidate is not used: the price decision for that customer says review, not the historical price and not the list price', (pg_temp.jv(pg_temp.q(mgr_u, 'authenticated', format('select public.resolve_customer_price(%L, ''p26-a'', %L) as v', 'cust-t26-c', dA1))) ->> 'source') = 'review');
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.verify_price_agreement(%L, 7.50, %L, null, ''Customer says 7.50, owner confirmed by phone (T26)'') as v', v_cand1, v_today - 60));
  perform pg_temp.chk('E9 verifying may CORRECT the price (7.50 instead of the historical 7.00): the confirmed price is what applies, and the event keeps both', not pg_temp.err(t) and (pg_temp.jv(pg_temp.q(mgr_u, 'authenticated', format('select public.resolve_customer_price(%L, ''p26-a'', %L) as v', 'cust-t26-c', dA1))) ->> 'price')::numeric = 7.5
    and exists (select 1 from public.price_agreement_events where agreement_id = v_cand1 and kind = 'verified' and (details ->> 'candidatePrice')::numeric = 7 and (details ->> 'confirmedPrice')::numeric = 7.5 and (details ->> 'changed') = 'true'), t);
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.reject_price_agreement(%L, ''The owner says this was a one-off discount (T26)'') as v', v_cand2));
  perform pg_temp.chk('E10 rejecting a candidate closes it with a reason, and the customer then pays the list price for that product (an explicit decision, recorded); a rejected agreement cannot be revived',
    not pg_temp.err(t) and (select status from public.customer_price_agreements where id = v_cand2) = 'rejected' and (pg_temp.jv(pg_temp.q(mgr_u, 'authenticated', format('select public.resolve_customer_price(%L, ''p26-b'', null) as v', 'cust-t26-c'))) ->> 'source') = 'list'
    and pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.verify_price_agreement(%L, 18, %L, null, ''Trying to revive a rejected one (T26)'') as v', v_cand2, v_today - 50))), t);

  -- ---------------------------------------------------------------- F. expiry reporting, ending, revoking, history
  j := pg_temp.jv(pg_temp.q(mgr_u, 'authenticated', 'select public.price_agreement_alerts() as v'));
  perform pg_temp.chk('F1 the review queue counts what needs attention: expiring within 14 days (A''s ball D ends today), expired in the last 30 days (A''s ball C), and unapproved below-cost agreements', (j ->> 'expiringSoon')::int >= 1 and (j ->> 'expiredLast30Days')::int >= 1, j::text);
  j := pg_temp.jv(pg_temp.q(mgr_u, 'authenticated', format('select public.list_price_agreements(%L) as v', v_a)));
  perform pg_temp.chk('F2 the staff list shows for each agreement whether it is in effect, expired or expires soon, with the list price beside the agreed one and the status',
    (select (e ->> 'expired')::boolean and not (e ->> 'inEffect')::boolean from jsonb_array_elements(j) e where e ->> 'productId' = 'p26-c' and e ->> 'status' = 'active' and (e ->> 'unitPrice')::numeric = 6.5)
    and (select (e ->> 'expiresSoon')::boolean and (e ->> 'inEffect')::boolean from jsonb_array_elements(j) e where e ->> 'productId' = 'p26-d' and (e ->> 'unitPrice')::numeric = 12)
    and (select (e ->> 'status') = 'revoked' from jsonb_array_elements(j) e where e ->> 'productId' = 'p26-a' and e ->> 'designId' is null) and not exists (select 1 from jsonb_array_elements(j) e where e ->> 'customerId' <> v_a));
  select id into v_ag2 from public.customer_price_agreements where customer_id = v_b and product_id = 'p26-c' and status = 'active';
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.end_price_agreement(%L, %L, ''Clearance finished, price ends today (T26)'') as v', v_ag2, v_today));
  perform pg_temp.chk('F3 an agreement can be END-DATED (brought forward) with a reason, never extended: ending today keeps today''s price, and the end date can only move earlier',
    not pg_temp.err(t) and (select effective_to from public.customer_price_agreements where id = v_ag2) = v_today and pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.end_price_agreement(%L, %L, ''Trying to extend it later (T26)'') as v', v_ag2, v_today + 30))), t);
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.replace_price_agreement(%L, 17.50, %L, null, ''Price renegotiated with the customer (T26)'') as v', v_ag3, v_today));
  perform pg_temp.chk('F3b changing an agreed price is ONE atomic action: the old agreement is closed (kept, revoked, "Replaced by a new price") and the new one is active in the same transaction; the customer now pays 17.50; both are in the history',
    not pg_temp.err(t) and (select status from public.customer_price_agreements where id = v_ag3) = 'revoked' and (select closed_reason from public.customer_price_agreements where id = v_ag3) like 'Replaced by a new price%'
    and (pg_temp.catrow(ca, 'p26-b') ->> 'selling_price')::numeric = 17.5 and (select count(*) from public.customer_price_agreements where customer_id = v_a and product_id = 'p26-b' and status = 'active') = 1
    and exists (select 1 from public.price_agreement_events where kind = 'created' and (details ->> 'replaces') = v_ag3::text and (details ->> 'previousPrice')::numeric = 18), t);
  perform pg_temp.chk('F3c replacing needs the same authority as creating: an Officer is refused, a revoked agreement cannot be replaced, a Manager cannot replace it with a below-cost price, and the reason is required',
    pg_temp.denied(pg_temp.q(off_u, 'authenticated', format('select public.replace_price_agreement(%L, 17.00, %L, null, ''Officer trying to change a price (T26)'') as v', (pg_temp.jv(t) #>> '{}')::uuid, v_today)))
    and pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.replace_price_agreement(%L, 17.00, %L, null, ''Replacing an already closed one (T26)'') as v', v_ag3, v_today)))
    and pg_temp.denied(pg_temp.q(mgr_u, 'authenticated', format('select public.replace_price_agreement(%L, 5.00, %L, null, ''Below cost needs a Super Admin (T26)'', ''Clearing stock'') as v', (pg_temp.jv(t) #>> '{}')::uuid, v_today)))
    and pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.replace_price_agreement(%L, 17.00, %L, null, ''short'') as v', (pg_temp.jv(t) #>> '{}')::uuid, v_today))));
  perform pg_temp.chk('F4 every change left an audit trail: the event history of customer A lists created, verified, revoked in order with who and why, and the system log has them', (select count(*) from public.price_agreement_events where customer_id = v_a and kind = 'created') >= 5
    and (select count(*) from public.price_agreement_events where customer_id = v_a and kind = 'revoked') = 3 and exists (select 1 from public.system_logs where metadata ->> 'event' = 'price_agreement_revoked' and target_id = v_a)
    and jsonb_array_length(pg_temp.jv(pg_temp.q(mgr_u, 'authenticated', format('select public.price_agreement_history(%L) as v', v_a)))) >= 8);
  begin update public.customer_price_agreements set unit_price = 1 where id = (select id from public.customer_price_agreements where customer_id = v_b and product_id = 'p26-c' and status = 'active'); perform pg_temp.chk('F5a an active agreement''s price cannot be rewritten', false); exception when others then perform pg_temp.chk('F5a an active agreement''s price cannot be rewritten', sqlstate = '42501'); end;
  begin update public.customer_price_agreements set status = 'active' where id = v_ag; perform pg_temp.chk('F5b a revoked agreement cannot be reopened', false); exception when others then perform pg_temp.chk('F5b a revoked agreement cannot be reopened', sqlstate = '42501'); end;
  begin update public.customer_price_agreements set customer_id = v_a where id = v_ag2; perform pg_temp.chk('F5c an agreement cannot be moved to another customer', false); exception when others then perform pg_temp.chk('F5c an agreement cannot be moved to another customer', sqlstate = '42501'); end;
  begin delete from public.customer_price_agreements where id = v_ag2; perform pg_temp.chk('F5d an agreement cannot be deleted', false); exception when others then perform pg_temp.chk('F5d an agreement cannot be deleted', sqlstate = '42501'); end;
  begin update public.price_agreement_events set kind = 'created' where agreement_id = v_ag; perform pg_temp.chk('F5e price history events cannot be rewritten', false); exception when others then perform pg_temp.chk('F5e price history events cannot be rewritten', sqlstate = '42501'); end;

  -- ---------------------------------------------------------------- G. exposure and isolation
  perform pg_temp.chk('G1 no customer-facing answer carries a cost, margin, profit, commission, supplier, officer, evidence or internal field (key names at every depth): catalogue, designs, previews, checkout, my_price_agreements, orders, finance',
    (select bool_and(pg_temp.banned(body::jsonb) is null) from (values (pg_temp.q(ca, 'authenticated', 'select * from public.customer_catalog()')), (pg_temp.q(ca, 'authenticated', 'select * from public.customer_designs()')),
        (pg_temp.preview(ca, jsonb_build_array(jsonb_build_object('productId', 'p26-a', 'designId', dA2, 'quantity', 1)))), (pg_temp.q(ca, 'authenticated', 'select public.my_price_agreements() as v')), (pg_temp.q(ca, 'authenticated', 'select public.my_orders() as v')),
        (pg_temp.q(ca, 'authenticated', 'select public.my_finance() as v')), (pg_temp.q(cb, 'authenticated', 'select * from public.customer_catalog()')), (pg_temp.q(cb, 'authenticated', 'select public.my_price_agreements() as v'))) x(body)
      where body !~ '"err"'));
  perform pg_temp.chk('G2 customer B never receives customer A''s agreement: none of A''s agreement ids or A-only prices appear in anything B can call (catalogue, designs, my_price_agreements)',
    not exists (select 1 from public.customer_price_agreements g where g.customer_id = v_a and (pg_temp.q(cb, 'authenticated', 'select public.my_price_agreements() as v') like '%' || g.id::text || '%' or pg_temp.q(cb, 'authenticated', 'select * from public.customer_designs()') like '%' || g.id::text || '%'))
    and (pg_temp.desrow(cb, dA1) ->> 'price')::numeric = 10);
  perform pg_temp.chk('G3 the catalogue contract the app relies on is unchanged except for two added columns, and a customer without an approved account (signed in as a stranger) and anonymous callers get nothing',
    (select count(*) from jsonb_object_keys(pg_temp.catrow(ca, 'p26-a'))) = 13 and pg_temp.denied(pg_temp.q(cx, 'authenticated', 'select * from public.customer_catalog()')) and pg_temp.denied(pg_temp.q(null, 'anon', 'select * from public.customer_catalog()'))
    and pg_temp.denied(pg_temp.q(cx, 'authenticated', 'select public.my_price_agreements() as v')));

  -- ---------------------------------------------------------------- H. staff ordering is unchanged
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.create_order(%L::jsonb) as v', json_build_object('customerId', v_a, 'items', json_build_array(json_build_object('productId', 'p26-a', 'quantity', 1, 'actualUnitPrice', 9)))::text));
  perform pg_temp.chk('H1 staff ordering is untouched: create_order still takes the negotiated price the staff member enters (9.00 against the list 10.00 kept as the standard price)',
    not pg_temp.err(t) and (select standard_unit_price || ':' || actual_unit_price from public.order_items where order_id = (pg_temp.jv(t) #>> '{}')) = '10.00:9.00', t);
  perform pg_temp.chk('H2 and its below-cost rule is untouched: a Manager still cannot sell below cost (42501)', pg_temp.denied(pg_temp.q(mgr_u, 'authenticated', format('select public.create_order(%L::jsonb) as v', json_build_object('customerId', v_a, 'items', json_build_array(json_build_object('productId', 'p26-a', 'quantity', 1, 'actualUnitPrice', 5)))::text))));
  perform pg_temp.chk('H3 a customer still cannot create orders or record payments directly', pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.create_order(%L::jsonb) as v', json_build_object('customerId', v_a, 'items', json_build_array(json_build_object('productId', 'p26-a', 'quantity', 1)))::text)))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.record_payment(%L, 1, ''Cash'') as v', v_order))));
end
$t$;

select case when ok then 'PASS' else 'FAIL' end || ' ' || lpad(n::text, 3) || ' ' || name || case when ok then '' else '   [' || detail || ']' end from r26 order by n;
select 'TOTAL: ' || count(*) || ' checks, ' || count(*) filter (where not ok) || ' failure(s)' from r26;

rollback;
