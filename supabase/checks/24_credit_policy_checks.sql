-- =============================================================================
-- 24 - CHECKS for the credit policy refinement (migration 24, on top of 21 + 22 + 23). Run with psql AFTER migration 24:
--   psql -X -v ON_ERROR_STOP=1 -d <db> -f supabase/checks/24_credit_policy_checks.sql
-- One transaction, ROLLED BACK at the end (nothing persists). Calls are made as the real Postgres roles with a simulated Supabase JWT.
-- Every threshold used here is a TEST value set inside the transaction; nothing here is an EFZ policy. Concurrent reservations are tested
-- separately (supabase/checks/24_credit_concurrency.mjs) because they need several real database sessions.
-- =============================================================================
\set ON_ERROR_STOP on
\pset footer off
\pset tuples_only on

begin;

create temp table r24 (n serial, ok boolean, name text, detail text);

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
begin insert into r24 (ok, name, detail) values (coalesce(p_ok, false), p_name, left(coalesce(p_detail, ''), 400)); end $f$;
create function pg_temp.err(t text) returns boolean language sql immutable as $f$ select coalesce(t::jsonb @> '{"err": true}'::jsonb, false) $f$;
create function pg_temp.code(t text) returns text language sql immutable as $f$ select t::jsonb ->> 'code' $f$;
create function pg_temp.denied(t text) returns boolean language sql immutable as $f$ select pg_temp.err(t) and pg_temp.code(t) = '42501' $f$;
create function pg_temp.jv(t text) returns jsonb language sql immutable as $f$ select case when pg_temp.err(t) then null else t::jsonb -> 0 -> 'v' end $f$;
create function pg_temp.msg(t text) returns text language sql immutable as $f$ select t::jsonb ->> 'msg' $f$;

do $t$
declare
  sa_u  uuid := 'a4000000-0000-4000-8000-000000000001';   -- Super Admin
  mgr_u uuid := 'a4000000-0000-4000-8000-000000000002';   -- Manager (no finance administration)
  ca uuid := 'c4000000-0000-4000-8000-00000000000a';      -- age / purchase-requirement scenarios
  cb uuid := 'c4000000-0000-4000-8000-00000000000b';      -- override scenarios
  cc uuid := 'c4000000-0000-4000-8000-00000000000c';      -- standing / overdue scenarios
  cd uuid := 'c4000000-0000-4000-8000-00000000000d';      -- outstanding-ceiling scenarios
  cx uuid := 'c4000000-0000-4000-8000-00000000000f';      -- signed in, not a customer
  acc record; t text; j jsonb; v_a text; v_b text; v_c text; v_d text; v_order text; v_o2 text; v_n int; v_av numeric; k int := 0;
  v_ev bigint;

begin
  -- ---------------------------------------------------------------- fixtures
  insert into public.profiles (id, name, email, role, status) values
    ('u-t24-sa', 'T24 Super Admin', 't24-sa@example.test', 'Super Admin', 'active'),
    ('u-t24-mgr', 'T24 Manager', 't24-mgr@example.test', 'Manager', 'active');
  insert into public.user_permissions (user_id, permission_code) values ('u-t24-mgr', 'manage_customer_accounts'), ('u-t24-mgr', 'edit_products'), ('u-t24-mgr', 'view_all_customers'), ('u-t24-mgr', 'view_orders'), ('u-t24-mgr', 'create_orders'), ('u-t24-mgr', 'edit_orders');
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
    (sa_u, 'authenticated', 'authenticated', 't24-sa@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
    (mgr_u, 'authenticated', 'authenticated', 't24-mgr@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
    (cx, 'authenticated', 'authenticated', 't24-x@example.test', now(), '{"provider":"email"}', '{}', now(), now());
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  select u, 'authenticated', 'authenticated', e, now(), '{"provider":"email","efz_kind":"customer"}', '{}', now(), now()
    from (values (ca, 't24-a@example.test'), (cb, 't24-b@example.test'), (cc, 't24-c@example.test'), (cd, 't24-d@example.test')) v(u, e);
  insert into public.products (id, name, selling_price, cost_price, stock, is_active) values ('p24-plain', 'T24 Ball Plain', 10, 5, 1000, true);
  for acc in select * from (values (ca, 't24-a@example.test', 'T24 Buyer A', '069 824 0001'), (cb, 't24-b@example.test', 'T24 Buyer B', '069 824 0002'),
                                   (cc, 't24-c@example.test', 'T24 Buyer C', '069 824 0003'), (cd, 't24-d@example.test', 'T24 Buyer D', '069 824 0004')) v(u, e, n, ph) loop
    perform pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, %L, %L, '''', null)', acc.u, acc.e, acc.n, acc.ph));
  end loop;
  for acc in select id from public.customer_accounts where email like 't24-%@example.test' loop
    perform pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, null, true, false, ''Verified by phone call (T24)'')', acc.id));
  end loop;
  select customer_id into v_a from public.customer_accounts where email = 't24-a@example.test';
  select customer_id into v_b from public.customer_accounts where email = 't24-b@example.test';
  select customer_id into v_c from public.customer_accounts where email = 't24-c@example.test';
  select customer_id into v_d from public.customer_accounts where email = 't24-d@example.test';

  -- ---------------------------------------------------------------- A. defaults: nothing is invented, credit is off
  t := pg_temp.q(sa_u, 'authenticated', 'select public.get_credit_policy() as v'); j := pg_temp.jv(t);
  perform pg_temp.chk('A1 after the migration the policy is OFF and the three new rules are EMPTY (no invented threshold); only the safety rule "no overdue" defaults on',
    (select enabled = false and min_approved_days is null and max_outstanding is null and require_no_overdue = true and min_completed_purchases is null and min_total_value is null
       from public.credit_policy where id), t);
  perform pg_temp.chk('A2 with credit off nobody can buy on credit and the plain reason is shown (no threshold quoted)',
    (pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v')) ->> 'canBuyOnCredit') = 'false'
    and (pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v')) -> 'eligibility' -> 'reasons' ->> 0) = 'Credit purchasing is not active yet.'
    and (pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v')) -> 'eligibility' ->> 'eligible') = 'false');

  -- ---------------------------------------------------------------- B. authorization and input validation
  perform pg_temp.chk('B1 only a Super Admin may change the policy or read a customer''s credit history: manager, customers and anonymous are refused (42501)',
    (select bool_and(pg_temp.denied(pg_temp.q(u, r, sql)))
       from (values (mgr_u, 'authenticated'), (ca, 'authenticated'), (cx, 'authenticated'), (null::uuid, 'anon')) c(u, r),
            (values ('select public.set_credit_policy(false, null, null, true, null, ''reason here'', 10, 500, true) as v'),
                    (format('select public.credit_history(%L) as v', v_a))) f(sql)));
  perform pg_temp.chk('B2 the old six-argument set_credit_policy no longer exists (one definition only); the new one is not executable by anon or PUBLIC',
    to_regprocedure('public.set_credit_policy(boolean,integer,numeric,boolean,integer,text)') is null
    and to_regprocedure('public.set_credit_policy(boolean,integer,numeric,boolean,integer,text,integer,numeric,boolean)') is not null
    and not has_function_privilege('anon', 'public.set_credit_policy(boolean,integer,numeric,boolean,integer,text,integer,numeric,boolean)', 'execute')
    and not has_function_privilege('anon', 'public.credit_history(text)', 'execute'));
  perform pg_temp.chk('B3 invalid values are refused: approved-days below 1, a ceiling of 0 or below, a short reason; enabling with no requirement or no repayment period',
    pg_temp.err(pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(false, null, null, true, null, ''reason here'', 0, null, true) as v'))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(false, null, null, true, null, ''reason here'', null, 0, true) as v'))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(false, null, null, true, null, ''reason here'', null, -5, true) as v'))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(false, null, null, true, null, ''no'', null, null, true) as v'))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, null, null, true, 30, ''enable it now'', null, 500, true) as v'))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, null, null, true, null, ''enable it now'', 30, null, true) as v'))
    and (select enabled = false and min_approved_days is null and max_outstanding is null from public.credit_policy where id));
  t := pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(false, 3, null, true, 30, ''Save old-style values, credit off'') as v');
  perform pg_temp.chk('B4 saving with only the six original arguments still works through the defaults, keeps the safety rule on, and is audited with the new fields',
    not pg_temp.err(t)
    and (select min_completed_purchases = 3 and min_approved_days is null and require_no_overdue from public.credit_policy where id)
    and exists (select 1 from public.system_logs where metadata ->> 'event' = 'credit_policy_set' and metadata ? 'minApprovedDays' and metadata ? 'maxOutstanding' and metadata ? 'requireNoOverdue'));

  -- ---------------------------------------------------------------- C. minimum period as an approved customer
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, null, null, true, 30, ''T24 test: approved for 30 days only'', 30, null, true) as v');
  t := pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v'); j := pg_temp.jv(t);
  perform pg_temp.chk('C1 a customer approved today does not meet a 30-day period: 0 of 30 days, the exact shortfall is shown, not eligible',
    (j -> 'eligibility' ->> 'daysApproved') = '0' and (j -> 'eligibility' ->> 'eligible') = 'false' and (j -> 'eligibility' ->> 'reasons') like '%0 of the 30 days%'
    and (j -> 'eligibility' -> 'requirements' ->> 'minApprovedDays') = '30', t);
  alter table public.customer_account_events disable trigger trg_customer_account_events_guard;   -- test fixture only (rolled back): age the first approval
  update public.customer_account_events set created_at = now() - interval '29 days' where event = 'approved' and account_id = (select id from public.customer_accounts where customer_id = v_a);
  j := pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('C2 29 days is still short of 30 (boundary): not eligible', (j -> 'eligibility' ->> 'daysApproved') = '29' and (j -> 'eligibility' ->> 'eligible') = 'false');
  update public.customer_account_events set created_at = now() - interval '30 days' where event = 'approved' and account_id = (select id from public.customer_accounts where customer_id = v_a);
  j := pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('C3 exactly 30 days meets it (boundary): eligible, but eligibility alone grants nothing (no credit account, cannot buy)',
    (j -> 'eligibility' ->> 'daysApproved') = '30' and (j -> 'eligibility' ->> 'eligible') = 'true' and (j ->> 'canBuyOnCredit') = 'false' and (j -> 'account') = 'null'::jsonb, j::text);
  insert into public.customer_account_events (account_id, event, from_status, to_status, actor_name, customer_id) select id, 'approved', 'suspended', 'approved', 'T24', v_a from public.customer_accounts where customer_id = v_a;
  j := pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('C4 a later re-approval does not restart the clock: the FIRST approval counts', (j -> 'eligibility' ->> 'daysApproved') = '30');
  update public.customer_account_events set created_at = now() - interval '400 days' where event = 'registered' and account_id = (select id from public.customer_accounts where customer_id = v_b);
  j := pg_temp.jv(pg_temp.q(cb, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('C5 the registration date does not count, only approval does (B registered long ago, approved today: 0 days)', (j -> 'eligibility' ->> 'daysApproved') = '0');
  alter table public.customer_account_events enable trigger trg_customer_account_events_guard;
  perform pg_temp.chk('C6 the event history is append-only again after the fixture (guard re-enabled)',
    pg_temp.denied(pg_temp.q(null, 'service_role', 'update public.customer_account_events set note = ''x'' returning 1 as v')) or pg_temp.err(pg_temp.q(null, 'service_role', 'update public.customer_account_events set note = ''x'' returning 1 as v')));

  -- ---------------------------------------------------------------- D. minimum qualifying purchases (all configured requirements must hold together)
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 2, 25, true, 30, ''T24 test: 2 purchases worth 25, 30 days'', 30, null, true) as v');
  insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) values
    ('ORD-T24-A1', v_a, 'T24 Buyer A', '', 'delivered', 'regular', current_date, ''), ('ORD-T24-A2', v_a, 'T24 Buyer A', '', 'delivered', 'regular', current_date, ''),
    ('ORD-T24-A3', v_a, 'T24 Buyer A', '', 'cancelled', 'regular', current_date, ''), ('ORD-T24-A4', v_a, 'T24 Buyer A', '', 'delivered', 'trial', current_date, ''),
    ('ORD-T24-A5', v_a, 'T24 Buyer A', '', 'pending', 'regular', current_date, '');
  insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost)
  select 'itm-' || o, o, 'p24-plain', 'T24 Ball Plain', 'T24 Ball Plain', 1, 10, 10, 5 from (values ('ORD-T24-A1'), ('ORD-T24-A2'), ('ORD-T24-A3'), ('ORD-T24-A4'), ('ORD-T24-A5')) v(o);
  insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes) values
    ('pay-t24-a1', 'ORD-T24-A1', 10, current_date, 'Cash', '', ''), ('pay-t24-a3', 'ORD-T24-A3', 10, current_date, 'Cash', '', ''),
    ('pay-t24-a4', 'ORD-T24-A4', 10, current_date, 'Cash', '', ''), ('pay-t24-a5', 'ORD-T24-A5', 10, current_date, 'Cash', '', '');
  j := pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('D1 one qualifying purchase of two: cancelled, trial, undelivered and unpaid orders are not counted; the unpaid delivered order is flagged as a standing problem',
    (j -> 'eligibility' ->> 'completedPurchases') = '1' and (j -> 'eligibility' ->> 'completedValue') = '10.00' and (j -> 'eligibility' ->> 'eligible') = 'false'
    and (j -> 'eligibility' ->> 'reasons') like '%1 more completed purchase%'
    and (j -> 'eligibility' -> 'standingReasons' ->> 0) like '%unpaid balance%', j::text);
  insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes) values ('pay-t24-a2', 'ORD-T24-A2', 10, current_date, 'Cash', '', '');
  j := pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('D2 two qualifying purchases but only $20 of the required $25: the value requirement is reported on its own (purchases met, value not)',
    (j -> 'eligibility' ->> 'completedPurchases') = '2' and (j -> 'eligibility' ->> 'eligible') = 'false' and (j -> 'eligibility' ->> 'reasons') like '%total $20.00; $25.00 is required%'
    and (j -> 'eligibility' ->> 'reasons') not like '%more completed purchase%', j::text);
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 2, 20, true, 30, ''T24 test: value of exactly 20'', 30, null, true) as v');
  j := pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('D2b a purchase value exactly equal to the requirement ($20 of $20) meets it (boundary)', (j -> 'eligibility' ->> 'completedValue') = '20.00' and (j -> 'eligibility' ->> 'eligible') = 'true', j::text);
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 2, 25, true, 30, ''T24 test: back to 25'', 30, null, true) as v');
  insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) values ('ORD-T24-A6', v_a, 'T24 Buyer A', '', 'delivered', 'regular', current_date, '');
  insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost) values ('itm-a6', 'ORD-T24-A6', 'p24-plain', 'P', 'P', 1, 10, 10, 5);
  insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes) values ('pay-t24-a6', 'ORD-T24-A6', 10, current_date, 'Cash', '', '');
  j := pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('D3 three qualifying purchases worth $30 and 30 days approved: all three requirements hold, no standing problem, eligible',
    (j -> 'eligibility' ->> 'completedPurchases') = '3' and (j -> 'eligibility' ->> 'completedValue') = '30.00' and (j -> 'eligibility' ->> 'eligible') = 'true'
    and jsonb_array_length(j -> 'eligibility' -> 'reasons') = 0 and jsonb_array_length(j -> 'eligibility' -> 'standingReasons') = 0, j::text);
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 2, 25, true, 31, ''T24 test: a 31-day period now'', 31, null, true) as v');
  j := pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('D4 the requirements are ANDed: purchases and value are met but the period (31 days, A has 30) is not, so A is not eligible',
    (j -> 'eligibility' ->> 'eligible') = 'false' and (j -> 'eligibility' ->> 'reasons') like '%30 of the 31 days%' and (j -> 'eligibility' ->> 'reasons') not like '%total $%', j::text);
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 2, 25, true, 30, ''T24 test: back to 30 days'', 30, null, true) as v');
  perform pg_temp.chk('D5 the requirements shown to the customer are exactly the configured ones (nothing hard-coded)',
    (pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v')) -> 'eligibility' -> 'requirements')
      = '{"minTotalValue":25.00,"maxOutstanding":null,"requireNoOverdue":true,"minApprovedDays":30,"minCompletedPurchases":2,"requireNoUnpaidDelivered":true}'::jsonb);

  -- ---------------------------------------------------------------- E. authorizing credit and overrides
  t := pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 100, 14, ''Eligible customer, limit agreed (T24)'') as v', v_a));
  perform pg_temp.chk('E1 an eligible customer is authorized without an override (override_used false)', not pg_temp.err(t) and (select override_used = false and credit_limit = 100 from public.customer_credit_accounts where customer_id = v_a), t);
  j := pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('E2 the customer now sees limit 100, available 100, no overdue, no next due date yet', (j ->> 'canBuyOnCredit') = 'true' and (j -> 'account' ->> 'available') = '100.00'
    and (j -> 'account' ->> 'nextDueDate') is null and (j -> 'account' ->> 'overdue') = '0', j::text);
  perform pg_temp.chk('E3 B (approved today, no purchases) is NOT eligible: staff cannot authorize without a recorded override reason of 10+ characters; the refusal names the unmet requirements',
    pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 60, 14, ''Wholesale partner (T24)'') as v', v_b)))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 60, 14, ''Wholesale partner (T24)'', ''too short'') as v', v_b)))
    and pg_temp.msg(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 60, 14, ''Wholesale partner (T24)'') as v', v_b))) like '%override reason%'
    and not exists (select 1 from public.customer_credit_accounts where customer_id = v_b));
  perform pg_temp.chk('E4 a Manager (no finance administration) cannot authorize credit, even with an override reason',
    pg_temp.denied(pg_temp.q(mgr_u, 'authenticated', format('select public.set_customer_credit(%L, 60, 14, ''Wholesale partner (T24)'', ''Owner approved the exception'') as v', v_b))));
  t := pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 60, 14, ''Wholesale partner (T24)'', ''Owner approved the exception on a call'') as v', v_b));
  perform pg_temp.chk('E5 with a recorded override B is authorized; the account is flagged override_used and the audit line keeps the override reason and the unmet requirements',
    not pg_temp.err(t) and (select override_used from public.customer_credit_accounts where customer_id = v_b)
    and exists (select 1 from public.system_logs where metadata ->> 'event' = 'customer_credit_set' and target_id = v_b and metadata ->> 'overrideReason' = 'Owner approved the exception on a call'
                and jsonb_array_length(metadata -> 'eligibility' -> 'reasons') > 0), t);
  j := pg_temp.jv(pg_temp.q(cb, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('E6 an authorized override CAN buy on credit (M23 let the override account never buy): status says so, limit 60', (j ->> 'canBuyOnCredit') = 'true' and (j -> 'account' ->> 'override') = 'true'
    and (j -> 'account' ->> 'available') = '60.00', j::text);
  t := pg_temp.q(cb, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f2400000-0000-4000-8000-000000000001',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p24-plain', 'quantity', 4)))::text));
  v_order := pg_temp.jv(t) ->> 'orderId';
  perform pg_temp.chk('E7 the override customer places a credit order within the limit (40 of 60): ONE order, terms from the account, due date set', not pg_temp.err(t) and v_order is not null
    and (select payment_terms || '|' || total || '|' || outstanding_balance from public.orders where id = v_order) = 'credit|40.00|40.00'
    and (select due_date from public.customer_credit_orders where order_id = v_order) = public.efz_today() + 14, t);
  t := pg_temp.q(cb, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f2400000-0000-4000-8000-000000000002',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p24-plain', 'quantity', 3)))::text));
  perform pg_temp.chk('E8 an override does NOT lift the limit: 30 more is refused because only 20 of the 60 remain', pg_temp.err(t) and pg_temp.msg(t) like '%above your available credit%'
    and (select count(*) from public.orders where customer_id = v_b and payment_terms = 'credit') = 1, t);
  perform pg_temp.chk('E9 the audit trail of B lists the authorization with the override reason (credit_history, Super Admin only), and the customer''s own order with its due date',
    (pg_temp.jv(pg_temp.q(sa_u, 'authenticated', format('select public.credit_history(%L) as v', v_b))) -> 'events' -> 0 ->> 'event') = 'customer_credit_set'
    and (pg_temp.jv(pg_temp.q(sa_u, 'authenticated', format('select public.credit_history(%L) as v', v_b))) -> 'orders' -> 0 ->> 'orderId') = v_order
    and (pg_temp.jv(pg_temp.q(sa_u, 'authenticated', format('select public.credit_history(%L) as v', v_b))) -> 'orders' -> 0 ->> 'overdue') = 'false');
  perform pg_temp.chk('E10 credit_history shows only the requested customer (A''s history has none of B''s orders) and never exposes who set it by internal id',
    (select count(*) from jsonb_array_elements(pg_temp.jv(pg_temp.q(sa_u, 'authenticated', format('select public.credit_history(%L) as v', v_a))) -> 'orders')) = 0
    and not ((pg_temp.jv(pg_temp.q(sa_u, 'authenticated', format('select public.credit_history(%L) as v', v_b))) -> 'account') ? 'set_by'));
  perform pg_temp.q(sa_u, 'authenticated', format('select public.suspend_customer_credit(%L, ''T24 paused'') as v', v_b));
  j := pg_temp.jv(pg_temp.q(cb, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('E11 suspending credit stops the override customer at once, with the paused message', (j ->> 'canBuyOnCredit') = 'false' and (j ->> 'message') like '%paused%'
    and pg_temp.denied(pg_temp.q(cb, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f2400000-0000-4000-8000-000000000003',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p24-plain', 'quantity', 1)))::text))), j::text);
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(false, 2, 25, true, 30, ''T24 test: credit switched off'', 30, null, true) as v');
  perform pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 60, 14, ''x'') as v', v_b));
  perform pg_temp.chk('E12 switching the policy OFF stops every credit purchase, including an authorized account (A is eligible and authorized but cannot buy)',
    (pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v')) ->> 'canBuyOnCredit') = 'false'
    and pg_temp.denied(pg_temp.q(ca, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f2400000-0000-4000-8000-000000000004',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p24-plain', 'quantity', 1)))::text))));
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 2, 25, true, 30, ''T24 test: credit back on'', 30, null, true) as v');
  perform pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 60, 14, ''Reinstated within policy exception (T24)'', ''Owner approved the exception again'') as v', v_b));

  -- an override account is also stopped when the whole policy is switched off
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(false, 2, 25, true, 30, ''T24 test: credit off with an override account'', 30, null, true) as v');
  j := pg_temp.jv(pg_temp.q(cb, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('E13 switching the policy OFF also stops an authorized OVERRIDE account (status says unavailable, the server refuses)', (j ->> 'canBuyOnCredit') = 'false' and (j ->> 'message') like '%not currently available%'
    and pg_temp.denied(pg_temp.q(cb, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f2400000-0000-4000-8000-000000000005',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p24-plain', 'quantity', 1)))::text))), j::text);
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 2, 25, true, 30, ''T24 test: credit back on'', 30, null, true) as v');

  -- ---------------------------------------------------------------- F. standing: unpaid delivered balance and overdue credit (never overridable)
  -- customer C: qualifies by two small purchases and 30 days, then is given a $100 limit
  alter table public.customer_account_events disable trigger trg_customer_account_events_guard;
  update public.customer_account_events set created_at = now() - interval '40 days' where event = 'approved' and account_id in (select id from public.customer_accounts where customer_id in (v_c, v_d));
  alter table public.customer_account_events enable trigger trg_customer_account_events_guard;
  insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) values
    ('ORD-T24-C1', v_c, 'T24 Buyer C', '', 'delivered', 'regular', current_date, ''), ('ORD-T24-C2', v_c, 'T24 Buyer C', '', 'delivered', 'regular', current_date, ''),
    ('ORD-T24-D1', v_d, 'T24 Buyer D', '', 'delivered', 'regular', current_date, ''), ('ORD-T24-D2', v_d, 'T24 Buyer D', '', 'delivered', 'regular', current_date, '');
  insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost)
  select 'itm-' || o, o, 'p24-plain', 'P', 'P', 2, 10, 10, 5 from (values ('ORD-T24-C1'), ('ORD-T24-C2'), ('ORD-T24-D1'), ('ORD-T24-D2')) v(o);
  insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes)
  select 'pay-' || lower(o), o, 20, current_date, 'Cash', '', '' from (values ('ORD-T24-C1'), ('ORD-T24-C2'), ('ORD-T24-D1'), ('ORD-T24-D2')) v(o);
  perform pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 100, 10, ''Eligible, limit agreed (T24 C)'') as v', v_c));
  perform pg_temp.chk('F1 C qualifies (2 purchases worth 40, approved 40 days) and is authorized without an override', (select override_used = false from public.customer_credit_accounts where customer_id = v_c)
    and (pg_temp.jv(pg_temp.q(cc, 'authenticated', 'select public.customer_credit_status() as v')) ->> 'canBuyOnCredit') = 'true');
  t := pg_temp.q(cc, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f2400000-0000-4000-8000-000000000011',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p24-plain', 'quantity', 3)))::text));
  v_order := pg_temp.jv(t) ->> 'orderId';
  j := pg_temp.jv(pg_temp.q(cc, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('F2 a credit order of 30 is placed; the summary shows outstanding 30, available 70 and the next due date (10 days)', not pg_temp.err(t)
    and (j -> 'account' ->> 'outstanding') = '30.00' and (j -> 'account' ->> 'available') = '70.00' and (j -> 'account' ->> 'nextDueDate') = (public.efz_today() + 10)::text, j::text);
  -- the invoice becomes overdue (fixture: move the due date back; real time does this by itself)
  alter table public.customer_credit_orders disable trigger trg_credit_orders_nodelete;
  update public.customer_credit_orders set due_date = public.efz_today() - 1 where order_id = v_order;
  j := pg_temp.jv(pg_temp.q(cc, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('F3 an overdue credit invoice with a balance restricts the account automatically: standing reason with the overdue amount, cannot buy, paused message',
    (j ->> 'canBuyOnCredit') = 'false' and (j -> 'eligibility' ->> 'eligible') = 'false' and (j -> 'eligibility' -> 'standingReasons' ->> 0) like '%overdue ($30.00)%'
    and (j -> 'account' ->> 'overdue') = '30.00' and (j ->> 'message') like '%paused until%', j::text);
  perform pg_temp.chk('F4 the server refuses the overdue customer''s credit order (not only the app)',
    pg_temp.denied(pg_temp.q(cc, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f2400000-0000-4000-8000-000000000012',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p24-plain', 'quantity', 1)))::text))));
  perform pg_temp.chk('F5 staff see the overdue flag per order in the credit history, and the customer''s invoice list shows overdue',
    (pg_temp.jv(pg_temp.q(sa_u, 'authenticated', format('select public.credit_history(%L) as v', v_c))) -> 'orders' -> 0 ->> 'overdue') = 'true'
    and (pg_temp.jv(pg_temp.q(cc, 'authenticated', 'select public.my_finance() as v')) -> 'summary' ->> 'overdueInvoices') = '1');
  perform pg_temp.chk('F6 an overdue balance cannot be overridden: re-authorizing C with an override reason is refused and names the standing problem',
    pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 500, 30, ''Raise the limit please (T24)'', ''Owner insists on this exception'') as v', v_c)))
    and pg_temp.msg(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 500, 30, ''Raise the limit please (T24)'', ''Owner insists on this exception'') as v', v_c))) like '%does not allow credit%'
    and (select credit_limit from public.customer_credit_accounts where customer_id = v_c) = 100);
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 2, 25, true, 30, ''T24 test: overdue rule off'', 30, null, false) as v');
  j := pg_temp.jv(pg_temp.q(cc, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('F7 with the overdue rule switched off by the Super Admin (audited) the overdue invoice no longer blocks credit; the limit still applies (70 available)',
    (j ->> 'canBuyOnCredit') = 'true' and jsonb_array_length(j -> 'eligibility' -> 'standingReasons') = 0 and (j -> 'account' ->> 'available') = '70.00'
    and exists (select 1 from public.system_logs where metadata ->> 'event' = 'credit_policy_set' and metadata ->> 'requireNoOverdue' = 'false'), j::text);
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 2, 25, true, 30, ''T24 test: overdue rule on'', 30, null, true) as v');
  -- partial then full repayment of the overdue invoice through the existing staff function
  perform pg_temp.q(sa_u, 'authenticated', format('select public.record_payment(%L, 10, ''Cash'', null, ''T24-1'', ''part'') as v', v_order));
  j := pg_temp.jv(pg_temp.q(cc, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('F8 a partial repayment of the overdue invoice reduces the overdue amount to 20 but the account stays restricted until it is cleared',
    (j ->> 'canBuyOnCredit') = 'false' and (j -> 'account' ->> 'overdue') = '20.00' and (j -> 'account' ->> 'outstanding') = '20.00', j::text);
  perform pg_temp.q(sa_u, 'authenticated', format('select public.record_payment(%L, 20, ''EVC'', null, ''T24-2'', ''rest'') as v', v_order));
  j := pg_temp.jv(pg_temp.q(cc, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('F9 paying the invoice in full lifts the restriction automatically: can buy again, full limit available, no overdue, no next due date',
    (j ->> 'canBuyOnCredit') = 'true' and (j -> 'account' ->> 'available') = '100.00' and (j -> 'account' ->> 'overdue') = '0' and (j -> 'account' ->> 'nextDueDate') is null, j::text);
  -- an unpaid delivered balance (standing) also blocks an override account
  insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) values ('ORD-T24-B1', v_b, 'T24 Buyer B', '', 'delivered', 'regular', current_date, '');
  insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost) values ('itm-b1', 'ORD-T24-B1', 'p24-plain', 'P', 'P', 1, 10, 10, 5);
  j := pg_temp.jv(pg_temp.q(cb, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('F10 a delivered order with an unpaid balance blocks even an override account (standing is never overridable)', (j ->> 'canBuyOnCredit') = 'false'
    and (j -> 'eligibility' -> 'standingReasons' ->> 0) like '%unpaid balance%'
    and pg_temp.denied(pg_temp.q(cb, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f2400000-0000-4000-8000-000000000013',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p24-plain', 'quantity', 1)))::text))), j::text);
  insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes) values ('pay-t24-b1', 'ORD-T24-B1', 10, current_date, 'Cash', '', '');
  perform pg_temp.chk('F11 paying that delivered order lifts the restriction for the override account (B: 40 of 60 outstanding, 20 available)',
    (pg_temp.jv(pg_temp.q(cb, 'authenticated', 'select public.customer_credit_status() as v')) ->> 'canBuyOnCredit') = 'true'
    and (pg_temp.jv(pg_temp.q(cb, 'authenticated', 'select public.customer_credit_status() as v')) -> 'account' ->> 'available') = '20.00');
  t := pg_temp.q(cc, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f2400000-0000-4000-8000-000000000014',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p24-plain', 'quantity', 5)))::text));
  v_o2 := pg_temp.jv(t) ->> 'orderId';
  v_av := (pg_temp.jv(pg_temp.q(cc, 'authenticated', 'select public.customer_credit_status() as v')) -> 'account' ->> 'available')::numeric;
  perform pg_temp.q(sa_u, 'authenticated', format('select public.update_order_status(%L, ''cancelled'', ''T24 cancel'') as v', v_o2));
  perform pg_temp.chk('F12 a credit order of 50 uses the credit (available 50); cancelling it through the existing staff workflow releases it (available 100 again)',
    v_av = 50 and (pg_temp.jv(pg_temp.q(cc, 'authenticated', 'select public.customer_credit_status() as v')) -> 'account' ->> 'available') = '100.00', v_av::text);

  -- an invoice that is due TODAY is not overdue yet; a cancelled invoice never counts as overdue
  t := pg_temp.q(cc, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f2400000-0000-4000-8000-000000000015',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p24-plain', 'quantity', 2)))::text));
  v_o2 := pg_temp.jv(t) ->> 'orderId';
  update public.customer_credit_orders set due_date = public.efz_today() where order_id = v_o2;
  j := pg_temp.jv(pg_temp.q(cc, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('F13 an invoice due TODAY is not overdue yet (boundary): the customer can still buy, overdue amount 0, and the invoice list does not flag it',
    (j ->> 'canBuyOnCredit') = 'true' and (j -> 'account' ->> 'overdue') = '0' and (pg_temp.jv(pg_temp.q(cc, 'authenticated', 'select public.my_finance() as v')) -> 'summary' ->> 'overdueInvoices') = '0', j::text);
  update public.customer_credit_orders set due_date = public.efz_today() - 3 where order_id = v_o2;
  perform pg_temp.chk('F14 the same invoice one day later is overdue and restricts the account', (pg_temp.jv(pg_temp.q(cc, 'authenticated', 'select public.customer_credit_status() as v')) ->> 'canBuyOnCredit') = 'false');
  perform pg_temp.q(sa_u, 'authenticated', format('select public.update_order_status(%L, ''cancelled'', ''T24 cancel overdue'') as v', v_o2));
  j := pg_temp.jv(pg_temp.q(cc, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('F15 cancelling the overdue invoice lifts the restriction: a cancelled order is never overdue and uses no credit', (j ->> 'canBuyOnCredit') = 'true' and (j -> 'account' ->> 'overdue') = '0' and (j -> 'account' ->> 'outstanding') = '0.00', j::text);
  alter table public.customer_credit_orders enable trigger trg_credit_orders_nodelete;

  -- ---------------------------------------------------------------- G. outstanding-balance ceiling (applies to everyone, override or not)
  perform pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 500, 30, ''Eligible, large limit (T24 D)'') as v', v_d));
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 2, 25, true, 30, ''T24 test: ceiling of 100'', 30, 100, true) as v');
  j := pg_temp.jv(pg_temp.q(cd, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('G1 a ceiling of 100 caps the available credit below the personal limit of 500: available 100', (j ->> 'canBuyOnCredit') = 'true' and (j -> 'account' ->> 'available') = '100.00'
    and (j -> 'account' ->> 'creditLimit') = '500.00' and (j -> 'eligibility' -> 'requirements' ->> 'maxOutstanding') = '100.00', j::text);
  t := pg_temp.q(cd, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f2400000-0000-4000-8000-000000000021',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p24-plain', 'quantity', 11)))::text));
  perform pg_temp.chk('G2 an order of 110 is refused although the personal limit is 500 (the ceiling is 100); nothing is created', pg_temp.err(t) and pg_temp.msg(t) like '%above your available credit ($100.00)%'
    and (select count(*) from public.orders where customer_id = v_d and payment_terms = 'credit') = 0, t);
  t := pg_temp.q(cd, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f2400000-0000-4000-8000-000000000022',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p24-plain', 'quantity', 6)))::text));
  v_o2 := pg_temp.jv(t) ->> 'orderId';
  j := pg_temp.jv(pg_temp.q(cd, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('G3 an order of 60 is accepted; 40 remain under the ceiling', not pg_temp.err(t) and (j -> 'account' ->> 'available') = '40.00' and (j -> 'account' ->> 'outstanding') = '60.00', t);
  t := pg_temp.q(cd, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f2400000-0000-4000-8000-000000000023',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p24-plain', 'quantity', 4)))::text));
  j := pg_temp.jv(pg_temp.q(cd, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('G4 an order of exactly the 40 that remain is accepted (boundary); outstanding then equals the ceiling, which blocks further credit with the ceiling reason',
    not pg_temp.err(t) and (j ->> 'canBuyOnCredit') = 'false' and (j -> 'eligibility' -> 'standingReasons' ->> 0) like '%reached the maximum ($100.00)%'
    and (j -> 'account' ->> 'available') = '0.00', t || ' ' || j::text);
  perform pg_temp.chk('G5 at the ceiling a one-unit order is refused by the server',
    pg_temp.denied(pg_temp.q(cd, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', 'f2400000-0000-4000-8000-000000000024',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'p24-plain', 'quantity', 1)))::text))));
  insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) values ('ORD-T24-DX', v_d, 'T24 Buyer D', '', 'pending', 'regular', current_date, '');
  insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost) values ('itm-dx', 'ORD-T24-DX', 'p24-plain', 'P', 'P', 1, 10, 10, 5);
  perform pg_temp.chk('G6 the ceiling counts ALL outstanding balances of the customer, not only credit invoices: an unpaid pending staff order also uses it (100 + 10)',
    (pg_temp.jv(pg_temp.q(cd, 'authenticated', 'select public.customer_credit_status() as v')) -> 'account' ->> 'outstanding') = '110.00');
  perform pg_temp.q(sa_u, 'authenticated', format('select public.record_payment(%L, 60, ''Cash'', null, ''T24-D'', ''paying down'') as v', v_o2));
  perform pg_temp.chk('G7 repaying 60 of the credit invoices brings the outstanding back under the ceiling and credit reopens (50 outstanding, 50 available)',
    (select outstanding_balance from public.orders where id = v_o2) = 0
    and (pg_temp.jv(pg_temp.q(cd, 'authenticated', 'select public.customer_credit_status() as v')) ->> 'canBuyOnCredit') = 'true'
    and (pg_temp.jv(pg_temp.q(cd, 'authenticated', 'select public.customer_credit_status() as v')) -> 'account' ->> 'available') = '50.00',
    pg_temp.jv(pg_temp.q(cd, 'authenticated', 'select public.customer_credit_status() as v'))::text);
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 2, 25, true, 30, ''T24 test: ceiling of 50'', 30, 50, true) as v');
  j := pg_temp.jv(pg_temp.q(cd, 'authenticated', 'select public.customer_credit_status() as v'));
  perform pg_temp.chk('G7b the ceiling is reached by the customers TOTAL outstanding (40 credit + 10 unpaid staff order = 50 >= 50), although credit invoices alone are 40',
    (j ->> 'canBuyOnCredit') = 'false' and (j -> 'eligibility' -> 'standingReasons' ->> 0) like '%reached the maximum ($50.00)%', j::text);
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 2, 25, true, 30, ''T24 test: ceiling of 51'', 30, 51, true) as v');
  perform pg_temp.chk('G7c one dollar under the ceiling (50 of 51) credit is open again with exactly 1 available',
    (pg_temp.jv(pg_temp.q(cd, 'authenticated', 'select public.customer_credit_status() as v')) ->> 'canBuyOnCredit') = 'true'
    and (pg_temp.jv(pg_temp.q(cd, 'authenticated', 'select public.customer_credit_status() as v')) -> 'account' ->> 'available') = '1.00');
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 2, 25, true, 30, ''T24 test: no ceiling'', 30, null, true) as v');
  perform pg_temp.chk('G8 clearing the ceiling returns to the personal limit only (500 minus 50 outstanding = 450 available)',
    (pg_temp.jv(pg_temp.q(cd, 'authenticated', 'select public.customer_credit_status() as v')) -> 'account' ->> 'available') = '450.00');
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 2, 25, true, 30, ''T24 test: ceiling of 20'', 30, 20, true) as v');
  perform pg_temp.chk('G9 lowering the ceiling below what a customer already owes pauses them (50 outstanding >= 20) without touching their existing orders',
    (pg_temp.jv(pg_temp.q(cd, 'authenticated', 'select public.customer_credit_status() as v')) ->> 'canBuyOnCredit') = 'false'
    and (select count(*) from public.orders where customer_id = v_d and payment_terms = 'credit' and status <> 'cancelled') >= 1);
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(false, 2, 25, true, 30, ''T24 test: credit off again'', 30, null, true) as v');

  -- ---------------------------------------------------------------- H. isolation and consistency
  perform pg_temp.chk('H1 each customer sees only their own credit account (A 100, B 60, C 100, D 500), and a signed-in non-customer sees nothing',
    (select bool_and((pg_temp.jv(pg_temp.q(u, 'authenticated', 'select public.customer_credit_status() as v')) -> 'account' ->> 'creditLimit')::numeric = lim)
       from (values (ca, 100), (cb, 60), (cc, 100), (cd, 500)) c(u, lim))
    and pg_temp.denied(pg_temp.q(cx, 'authenticated', 'select public.customer_credit_status() as v')));
  perform pg_temp.chk('H2 customers cannot read or write the policy or accounts directly, and cannot call the eligibility helper',
    pg_temp.err(pg_temp.q(ca, 'authenticated', 'update public.credit_policy set max_outstanding = 1 returning 1 as v'))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', format('update public.customer_credit_accounts set credit_limit = 99999 where customer_id = %L returning 1 as v', v_a)))
    and pg_temp.denied(pg_temp.q(ca, 'authenticated', format('select public._customer_credit_eligibility(%L) as v', v_a)))
    and pg_temp.denied(pg_temp.q(ca, 'authenticated', format('select public._customer_credit_summary(%L) as v', v_a))));
  perform pg_temp.chk('H3 the financial invariants hold on every credit order of this suite (total = sum of lines, paid + balance = total, no negative values, no payment without staff)',
    (select count(*) from public.orders o join public.customer_credit_orders cc on cc.order_id = o.id
      where o.total <> (select sum(line_revenue) from public.order_items where order_id = o.id) or o.amount_paid + o.outstanding_balance <> o.total or o.outstanding_balance < 0) = 0);
  perform pg_temp.chk('H4 every credit order has its order_created audit line and credit_order_placed line',
    (select count(*) from public.customer_credit_orders cc where not exists (select 1 from public.system_logs l where l.target_id = cc.order_id and l.metadata ->> 'event' = 'order_created')
                                                              or not exists (select 1 from public.system_logs l where l.target_id = cc.order_id and l.metadata ->> 'event' = 'credit_order_placed')) = 0);
  perform pg_temp.chk('H5 create_order and record_payment still refuse customers (the customer channel does not weaken them)',
    pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.create_order(%L::jsonb) as v', jsonb_build_object('customerId', v_a, 'items', jsonb_build_array(jsonb_build_object('productId', 'p24-plain', 'quantity', 1)))::text)))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.record_payment(%L, 1, ''Cash'') as v', 'ORD-T24-A1'))));
end
$t$;

select case when ok then 'PASS' else 'FAIL' end || ' ' || lpad(n::text, 3) || ' ' || name || case when ok then '' else '   [' || detail || ']' end from r24 order by n;
select 'TOTAL: ' || count(*) || ' checks, ' || count(*) filter (where not ok) || ' failure(s)' from r24;

rollback;
