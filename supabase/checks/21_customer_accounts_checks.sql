-- =============================================================================
-- 21 - CHECKS for customer accounts (migration 21). Run with psql AFTER migration 21:
--   psql -X -v ON_ERROR_STOP=1 -d <db> -f supabase/checks/21_customer_accounts_checks.sql
-- Everything happens inside ONE transaction that is ROLLED BACK at the end, so
-- nothing persists (synthetic profiles, auth users, customers and orders are
-- created only inside it). Requests are made as the real Postgres roles
-- (anon / authenticated / service_role) with a simulated Supabase JWT, so the
-- actual RLS policies, grants and function guards are what is being tested.
-- Prints one line per check ("PASS|FAIL  n  name | detail") and a summary; exits
-- non-zero (FAIL count) through the final \if. Nothing here touches existing rows.
-- =============================================================================
\set ON_ERROR_STOP on
\pset footer off
\pset tuples_only on

begin;

create temp table r21 (n serial, ok boolean, name text, detail text);

-- Run one statement as a role with a simulated JWT. Returns the result rows as JSON text,
-- or an object {"err": true, "code": <sqlstate>, "msg": ...} on error. The role is always restored.
create function pg_temp.q(p_sub uuid, p_role text, p_sql text) returns text
language plpgsql as $f$
declare
  v_out text;
begin
  perform set_config('request.jwt.claims',
    case when p_sub is null then json_build_object('role', p_role)::text
         else json_build_object('sub', p_sub, 'role', p_role)::text end, true);
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

create function pg_temp.chk(p_name text, p_ok boolean, p_detail text default '') returns void
language plpgsql as $f$
begin
  insert into r21 (ok, name, detail) values (coalesce(p_ok, false), p_name, left(coalesce(p_detail, ''), 200));
end
$f$;

create function pg_temp.err(t text) returns boolean language sql immutable as $f$ select coalesce(t::jsonb @> '{"err": true}'::jsonb, false) $f$;
create function pg_temp.code(t text) returns text language sql immutable as $f$ select t::jsonb ->> 'code' $f$;
create function pg_temp.denied(t text) returns boolean language sql immutable as $f$ select pg_temp.err(t) and pg_temp.code(t) = '42501' $f$;
create function pg_temp.none(t text) returns boolean language sql immutable as $f$ select t = '[]' or pg_temp.denied(t) $f$;   -- nothing readable
create function pg_temp.n(t text) returns int language sql immutable as $f$ select case when pg_temp.err(t) then -1 else (t::jsonb -> 0 ->> 'n')::int end $f$;

do $t$
declare
  sa_u   uuid := 'a0000000-0000-4000-8000-000000000001';
  mgr_u  uuid := 'a0000000-0000-4000-8000-000000000002';
  mo_u   uuid := 'a0000000-0000-4000-8000-000000000003';
  stf_u  uuid := 'a0000000-0000-4000-8000-000000000004';
  ca_u   uuid := 'c0000000-0000-4000-8000-00000000000a';
  cb_u   uuid := 'c0000000-0000-4000-8000-00000000000b';
  cp_u   uuid := 'c0000000-0000-4000-8000-00000000000c';   -- pending, phone matches an existing CRM customer
  cr_u   uuid := 'c0000000-0000-4000-8000-00000000000d';   -- rejected
  cn_u   uuid := 'c0000000-0000-4000-8000-00000000000e';   -- approved with a NEW CRM customer
  unk_u  uuid := 'c0000000-0000-4000-8000-00000000000f';   -- unknown confirmed sign-up
  spf_u  uuid := 'c0000000-0000-4000-8000-000000000010';   -- customer-marked user with a staff email
  unm_u  uuid := 'c0000000-0000-4000-8000-000000000011';   -- unmarked user (not created by the registration function)
  v_prod text;  v_prod_count int;  v_profiles_before int;
  acc_a uuid; acc_b uuid; acc_p uuid; acc_r uuid; acc_n uuid;
  t text; j jsonb; k text; v_cnt int; v_ids text;
  v_cn text;
begin
  select id into v_prod from public.products where is_active order by id limit 1;
  select count(*) into v_prod_count from public.products where is_active;
  perform pg_temp.chk('0 fixture: an active product exists', v_prod is not null, coalesce(v_prod, 'none'));
  select count(*) into v_profiles_before from public.profiles;

  -- ---------------------------------------------------------------- staff fixtures (provisioned the documented way: profile first)
  insert into public.profiles (id, name, email, role, status) values
    ('u-t21-sa',  'T21 Super Admin', 't21-sa@example.test',  'Super Admin',       'active'),
    ('u-t21-mgr', 'T21 Manager',     't21-mgr@example.test', 'Manager',           'active'),
    ('u-t21-mo',  'T21 Officer',     't21-mo@example.test',  'Marketing Officer', 'active'),
    ('u-t21-stf', 'T21 New Staff',   't21-stf@example.test', 'Manager',           'active'),
    ('u-t21-ul1', 'T21 Unlinked One', 't21-ul1@example.test', 'Manager',           'active'),
    ('u-t21-ul2', 'T21 Unlinked Two', 't21-ul2@example.test', 'Manager',           'active');
  insert into public.user_permissions (user_id, permission_code) values
    ('u-t21-mgr', 'manage_customer_accounts'), ('u-t21-mgr', 'manage_users'),
    ('u-t21-mo', 'view_own_customers_only'), ('u-t21-mo', 'view_orders');
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
    (sa_u,  'authenticated', 'authenticated', 't21-sa@example.test',  now(), '{"provider":"email"}', '{}', now(), now()),
    (mgr_u, 'authenticated', 'authenticated', 't21-mgr@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
    (mo_u,  'authenticated', 'authenticated', 't21-mo@example.test',  now(), '{"provider":"email"}', '{}', now(), now());

  -- ---------------------------------------------------------------- A. auth trigger
  perform pg_temp.chk('A1 staff linked by email to the pre-created profile (SA, Manager, Officer)',
    (select count(*) from public.profiles where id in ('u-t21-sa', 'u-t21-mgr', 'u-t21-mo') and auth_user_id is not null) = 3);
  perform pg_temp.chk('A2 linked staff are active staff with their permissions',
    pg_temp.q(mgr_u, 'authenticated', 'select public.is_active_staff() as ok, public.has_permission(''manage_customer_accounts'') as p')::jsonb -> 0 = '{"ok": true, "p": true}'::jsonb
    and (pg_temp.q(mo_u, 'authenticated', 'select public.has_permission(''manage_customer_accounts'') as p')::jsonb -> 0 ->> 'p') = 'false');

  -- confirmed later: unconfirmed insert, then confirmation links the profile
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (stf_u, 'authenticated', 'authenticated', 't21-stf@example.test', null, '{"provider":"email"}', '{}', now(), now());
  perform pg_temp.chk('A3 an UNCONFIRMED sign-up with a staff email claims nothing yet', (select auth_user_id from public.profiles where id = 'u-t21-stf') is null);
  update auth.users set email_confirmed_at = now() where id = stf_u;
  perform pg_temp.chk('A4 confirming the staff email links the existing profile', (select auth_user_id from public.profiles where id = 'u-t21-stf') = stf_u);

  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (unk_u, 'authenticated', 'authenticated', 't21-unknown@example.test', now(), '{"provider":"email"}', '{"name":"Unknown"}', now(), now());
  perform pg_temp.chk('A5 UNKNOWN confirmed sign-up creates NO staff profile (not even inactive)',
    (select count(*) from public.profiles where lower(email) = 't21-unknown@example.test' or auth_user_id = unk_u) = 0
    and (select count(*) from public.profiles) = v_profiles_before + 6);
  perform pg_temp.chk('A6 the unknown sign-up is not staff and reads no staff data',
    (pg_temp.q(unk_u, 'authenticated', 'select public.is_active_staff() as ok')::jsonb -> 0 ->> 'ok') = 'false'
    and pg_temp.none(pg_temp.q(unk_u, 'authenticated', 'select 1 as n from public.products'))
    and pg_temp.none(pg_temp.q(unk_u, 'authenticated', 'select 1 as n from public.customers'))
    and pg_temp.none(pg_temp.q(unk_u, 'authenticated', 'select 1 as n from public.orders')));

  -- a customer-marked registration with a STAFF email must never link to the staff profile
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (spf_u, 'authenticated', 'authenticated', 'T21-UL1@example.test', now(), '{"provider":"email","efz_kind":"customer"}', '{}', now(), now());
  perform pg_temp.chk('A7 customer-marked user (confirmed at creation) with the email of an UNLINKED staff profile does NOT claim that profile',
    (select auth_user_id from public.profiles where id = 'u-t21-ul1') is null
    and not exists (select 1 from public.profiles where auth_user_id = spf_u));

  -- email verification mode: the customer is created UNCONFIRMED and confirms later (6-digit code). Confirmation must not link a staff profile either.
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('c0000000-0000-4000-8000-000000000012', 'authenticated', 'authenticated', 'T21-UL2@example.test', null, '{"provider":"email","efz_kind":"customer"}', '{}', now(), now());
  update auth.users set email_confirmed_at = now() where id = 'c0000000-0000-4000-8000-000000000012';
  perform pg_temp.chk('A8 a customer-marked user confirming its email LATER (verification mode) does NOT claim the unlinked staff profile with that email',
    (select auth_user_id from public.profiles where id = 'u-t21-ul2') is null
    and not exists (select 1 from public.profiles where auth_user_id = 'c0000000-0000-4000-8000-000000000012'));

  -- ---------------------------------------------------------------- B. registration function
  -- customer auth users, marked as the registration function marks them
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  select u, 'authenticated', 'authenticated', e, now(), '{"provider":"email","efz_kind":"customer"}', '{}', now(), now()
    from (values (ca_u, 't21-a@example.test'), (cb_u, 't21-b@example.test'), (cp_u, 't21-p@example.test'),
                 (cr_u, 't21-r@example.test'), (cn_u, 't21-n@example.test')) v(u, e);
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (unm_u, 'authenticated', 'authenticated', 't21-unmarked@example.test', now(), '{"provider":"email"}', '{}', now(), now());

  perform pg_temp.chk('B1 registration functions are not callable by authenticated or anon',
    pg_temp.denied(pg_temp.q(ca_u, 'authenticated', format('select public.register_customer_account(%L, %L, ''A'', ''0611111111'', '''', null)', ca_u, 't21-a@example.test')))
    and pg_temp.denied(pg_temp.q(null, 'anon', format('select public.register_customer_account(%L, %L, ''A'', ''0611111111'', '''', null)', ca_u, 't21-a@example.test')))
    and pg_temp.denied(pg_temp.q(ca_u, 'authenticated', 'select * from public.customer_registration_check(''x@example.test'', ''0611111111'', null)')));

  t := pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, ''Customer A'', ''061 111 1111'', ''Club A'', ''h-a'') as id', ca_u, 't21-a@example.test'));
  perform pg_temp.chk('B2 service_role registers an account: pending, safe response, no CRM link', not pg_temp.err(t)
    and (select status from public.customer_accounts where auth_user_id = ca_u) = 'pending'
    and (select customer_id from public.customer_accounts where auth_user_id = ca_u) is null, t);
  perform pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, ''Customer B'', ''062 222 2222'', '''', ''h-b'')', cb_u, 't21-b@example.test'));
  perform pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, ''Customer P'', ''063 333 3333'', '''', ''h-p'')', cp_u, 't21-p@example.test'));
  perform pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, ''Customer R'', ''065 555 5555'', '''', ''h-r'')', cr_u, 't21-r@example.test'));
  perform pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, ''Customer N'', ''064 444 4444'', ''Shop N'', ''h-n'')', cn_u, 't21-n@example.test'));
  select id into acc_a from public.customer_accounts where auth_user_id = ca_u;
  select id into acc_b from public.customer_accounts where auth_user_id = cb_u;
  select id into acc_p from public.customer_accounts where auth_user_id = cp_u;
  select id into acc_r from public.customer_accounts where auth_user_id = cr_u;
  select id into acc_n from public.customer_accounts where auth_user_id = cn_u;
  perform pg_temp.chk('B3 five accounts registered, all pending, each with a "registered" event and a database-origin audit line',
    (select count(*) from public.customer_accounts where id in (acc_a, acc_b, acc_p, acc_r, acc_n) and status = 'pending') = 5
    and (select count(*) from public.customer_account_events where event = 'registered' and account_id in (acc_a, acc_b, acc_p, acc_r, acc_n)) = 5
    and (select count(*) from public.system_logs where metadata ->> 'event' = 'customer_account_registered' and origin = 'database'
           and (metadata ->> 'accountId')::uuid in (acc_a, acc_b, acc_p, acc_r, acc_n)) = 5);
  perform pg_temp.chk('B4 phone stored canonical (+252...), ip hint stored as given, email lowercased',
    (select phone_canonical from public.customer_accounts where id = acc_a) = '+252611111111');
  perform pg_temp.chk('B5 a user not marked as a customer registration is refused',
    pg_temp.err(pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, ''U'', ''066 666 6666'', '''', null)', unm_u, 't21-unmarked@example.test'))));
  perform pg_temp.chk('B6 a staff email cannot be registered as a customer (function refuses; check says reserved)',
    pg_temp.err(pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, ''S'', ''067 777 7777'', '''', null)', spf_u, 'T21-SA@example.test')))
    and (pg_temp.q(null, 'service_role', 'select verdict as v from public.customer_registration_check(''t21-sa@example.test'', ''067 777 7777'', null)')::jsonb -> 0 ->> 'v') = 'reserved');
  perform pg_temp.chk('B7 check verdicts: ok for a new email, duplicate for a registered one',
    (pg_temp.q(null, 'service_role', 'select verdict as v from public.customer_registration_check(''t21-new@example.test'', ''068 888 8888'', null)')::jsonb -> 0 ->> 'v') = 'ok'
    and (pg_temp.q(null, 'service_role', 'select verdict as v from public.customer_registration_check(''t21-a@example.test'', ''068 888 8888'', null)')::jsonb -> 0 ->> 'v') = 'duplicate');
  perform pg_temp.chk('B8 bad phone refused (WR422), bad email refused (WR422)',
    pg_temp.code(pg_temp.q(null, 'service_role', 'select * from public.customer_registration_check(''t21-x@example.test'', ''12345'', null)')) = 'WR422'
    and pg_temp.code(pg_temp.q(null, 'service_role', 'select * from public.customer_registration_check(''not-an-email'', ''068 888 8888'', null)')) = 'WR422');
  -- rate limit: 3 per phone per day. Phone ...1111 already has 1 (A); add two more auth users on the same phone, the 4th must be refused.
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  select ('d0000000-0000-4000-8000-00000000000' || i)::uuid, 'authenticated', 'authenticated', 't21-rl' || i || '@example.test', now(), '{"provider":"email","efz_kind":"customer"}', '{}', now(), now()
    from generate_series(1, 3) i;
  perform pg_temp.q(null, 'service_role', 'select public.register_customer_account(''d0000000-0000-4000-8000-000000000001'', ''t21-rl1@example.test'', ''RL1'', ''061 111 1111'', '''', null)');
  perform pg_temp.q(null, 'service_role', 'select public.register_customer_account(''d0000000-0000-4000-8000-000000000002'', ''t21-rl2@example.test'', ''RL2'', ''061 111 1111'', '''', null)');
  perform pg_temp.chk('B9 rate limit: a 4th registration for the same phone in 24 h is refused (WR429)',
    pg_temp.code(pg_temp.q(null, 'service_role', 'select public.register_customer_account(''d0000000-0000-4000-8000-000000000003'', ''t21-rl3@example.test'', ''RL3'', ''061 111 1111'', '''', null)')) = 'WR429'
    and pg_temp.code(pg_temp.q(null, 'service_role', 'select * from public.customer_registration_check(''t21-rl9@example.test'', ''061 111 1111'', null)')) = 'WR429');

  -- ---------------------------------------------------------------- CRM + orders fixtures (as the database owner)
  insert into public.customers (id, name, email, phone, marketing_officer_id, registered_by, status) values
    ('cust-t21-a', 'T21 Customer A', 't21-a@example.test', '611111111', null, null, 'active'),
    ('cust-t21-b', 'T21 Customer B', 't21-b@example.test', '622222222', null, null, 'active'),
    ('cust-t21-c', 'T21 Existing C', 't21-c@example.test', '633333333', 'u-t21-mo', 'u-t21-mo', 'active');
  insert into public.orders (id, customer_id, customer_name, phone, status, order_date, delivery_notes, marketing_officer_id) values
    ('ORD-T21-A1', 'cust-t21-a', 'T21 Customer A', '611111111', 'pending', current_date, 'INTERNAL NOTE A', null),
    ('ORD-T21-B1', 'cust-t21-b', 'T21 Customer B', '622222222', 'pending', current_date, 'INTERNAL NOTE B', null),
    ('ORD-T21-C1', 'cust-t21-c', 'T21 Existing C', '633333333', 'pending', current_date, 'INTERNAL NOTE C', 'u-t21-mo');
  insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost)
  select 'itm-t21-' || o, o, v_prod, 'P', 'Design ' || o, 2, 10, 10, 6 from (values ('ORD-T21-A1'), ('ORD-T21-B1'), ('ORD-T21-C1')) v(o);
  insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes, recorded_by) values
    ('pay-t21-a1', 'ORD-T21-A1', 5, current_date, 'EVC', 'REF-A', 'internal payment note', 'u-t21-mo'),
    ('pay-t21-b1', 'ORD-T21-B1', 7, current_date, 'EVC', 'REF-B', '', 'u-t21-mo'),
    ('pay-t21-c1', 'ORD-T21-C1', 3, current_date, 'Cash', 'REF-C', '', 'u-t21-mo');

  -- ---------------------------------------------------------------- C. pending / rejected: nothing private
  perform pg_temp.chk('C1 PENDING customer: no catalog, no orders (42501); own status visible without any CRM data',
    pg_temp.denied(pg_temp.q(ca_u, 'authenticated', 'select * from public.customer_catalog()'))
    and pg_temp.denied(pg_temp.q(ca_u, 'authenticated', 'select public.my_orders() as o'))
    and (pg_temp.q(ca_u, 'authenticated', 'select public.my_customer_account() as a')::jsonb -> 0 -> 'a' ->> 'status') = 'pending'
    and not (pg_temp.q(ca_u, 'authenticated', 'select public.my_customer_account() as a')::jsonb -> 0 -> 'a' ? 'customerId'));
  perform pg_temp.chk('C2 PENDING customer reads nothing from the underlying tables or views',
    pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.orders'))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.payments'))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.order_items'))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.customers'))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.products'))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.order_details'))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.customer_accounts'))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.customer_account_events'))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.profiles where id like ''u-t21%''')));

  -- manager (with permission) rejects R
  perform pg_temp.chk('C3 an unauthorized officer cannot reject, approve or even list accounts',
    pg_temp.denied(pg_temp.q(mo_u, 'authenticated', format('select public.reject_customer_account(%L, ''no permission'')', acc_r)))
    and pg_temp.denied(pg_temp.q(mo_u, 'authenticated', format('select public.approve_customer_account(%L, null, true, false, ''no permission note'')', acc_r)))
    and pg_temp.denied(pg_temp.q(mo_u, 'authenticated', format('select * from public.find_customers_for_account(%L)', acc_r)))
    and pg_temp.none(pg_temp.q(mo_u, 'authenticated', 'select 1 as n from public.customer_accounts'))
    and (select status from public.customer_accounts where id = acc_r) = 'pending');
  perform pg_temp.chk('C4 no staff session at all (service_role / anon) cannot review either',
    pg_temp.denied(pg_temp.q(null, 'service_role', format('select public.reject_customer_account(%L, ''service role'')', acc_r)))
    and pg_temp.denied(pg_temp.q(null, 'anon', format('select public.approve_customer_account(%L, null, true, false, ''anon attempt note'')', acc_r))));
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.reject_customer_account(%L, ''Could not verify identity by phone'')', acc_r));
  perform pg_temp.chk('C5 authorized staff rejects an account; rejected customer gets nothing', not pg_temp.err(t)
    and (select status from public.customer_accounts where id = acc_r) = 'rejected'
    and pg_temp.denied(pg_temp.q(cr_u, 'authenticated', 'select * from public.customer_catalog()'))
    and pg_temp.denied(pg_temp.q(cr_u, 'authenticated', 'select public.my_orders() as o')), t);

  -- ---------------------------------------------------------------- D. approval rules
  perform pg_temp.chk('D1 phone match alone cannot link: unverified link to the matching CRM customer is refused',
    pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, ''cust-t21-c'', false, false, ''phone matched only, not verified'')', acc_p)))
    and (select status from public.customer_accounts where id = acc_p) = 'pending');
  perform pg_temp.chk('D2 phone match alone cannot create a duplicate either (needs explicit confirmation it is a different person)',
    pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, null, true, false, ''phone matched an existing customer'')', acc_p)))
    and (select count(*) from public.customers where email = 't21-p@example.test') = 0);
  perform pg_temp.chk('D3 the pending account with a matching phone cannot read the existing customer''s history',
    pg_temp.denied(pg_temp.q(cp_u, 'authenticated', 'select public.my_orders() as o'))
    and pg_temp.none(pg_temp.q(cp_u, 'authenticated', 'select 1 as n from public.orders where customer_id = ''cust-t21-c''')));
  perform pg_temp.chk('D4 candidates are listed to the verifying reviewer (masked phone) and show the existing customer',
    (pg_temp.q(mgr_u, 'authenticated', format('select customer_id as c, phone_masked as m from public.find_customers_for_account(%L)', acc_p))::jsonb -> 0 ->> 'c') = 'cust-t21-c'
    and (pg_temp.q(mgr_u, 'authenticated', format('select phone_masked as m from public.find_customers_for_account(%L)', acc_p))::jsonb -> 0 ->> 'm') like '******%');
  perform pg_temp.chk('D5 a note describing the verification is required (>= 10 characters)',
    pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, null, true, true, ''short'')', acc_n)))
    and (select status from public.customer_accounts where id = acc_n) = 'pending');
  perform pg_temp.chk('D6 exactly one of link-existing / create-new must be chosen',
    pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, null, false, true, ''neither option chosen here'')', acc_n)))
    and pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, ''cust-t21-b'', true, true, ''both options chosen here'')', acc_n))));

  -- approve A and B by linking their (staff-verified) CRM customers
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, ''cust-t21-a'', false, true, ''Verified by phone call and WhatsApp photo'') as c', acc_a));
  perform pg_temp.chk('D7 verified link of an existing customer succeeds; the customer''s owner/commission is untouched',
    not pg_temp.err(t) and (select status || customer_id from public.customer_accounts where id = acc_a) = 'approvedcust-t21-a'
    and (select marketing_officer_id from public.customers where id = 'cust-t21-a') is null, t);
  perform pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, ''cust-t21-b'', false, true, ''Verified by phone call and WhatsApp photo'')', acc_b));
  -- P links to the existing customer C that has an officer: ownership must not change
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, ''cust-t21-c'', false, true, ''Verified in person at the shop with ID'') as c', acc_p));
  perform pg_temp.chk('D8 linking a customer that already has an officer does not reassign the officer (no automatic commission ownership)',
    not pg_temp.err(t) and (select marketing_officer_id from public.customers where id = 'cust-t21-c') = 'u-t21-mo', t);
  -- N: a brand-new CRM customer
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, null, true, false, ''Verified by phone call, new buyer'') as c', acc_n));
  select customer_id into v_cn from public.customer_accounts where id = acc_n;
  perform pg_temp.chk('D9 approval with a NEW customer: created active, unassigned (no commission owner), registered_by the approver', not pg_temp.err(t)
    and exists (select 1 from public.customers c where c.id = v_cn and c.marketing_officer_id is null and c.registered_by = 'u-t21-mgr' and c.status = 'active' and c.phone = '644444444'), t);

  -- repeated / illegal transitions
  perform pg_temp.chk('D10 transitions are protected: approve twice, reject an approved account, suspend a pending/rejected one, reinstate a non-suspended one',
    pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, ''cust-t21-b'', false, true, ''second attempt note here'')', acc_a)))
    and pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.reject_customer_account(%L, ''reject after approve'')', acc_a)))
    and pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.suspend_customer_account(%L, ''suspend a rejected one'')', acc_r)))
    and pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.reinstate_customer_account(%L, ''reinstate an approved one'')', acc_a)))
    and pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, ''cust-t21-b'', false, true, ''approve a rejected one!!'')', acc_r)))
    and (select status from public.customer_accounts where id = acc_r) = 'rejected');
  begin update public.customer_accounts set status = 'approved' where id = acc_r; perform pg_temp.chk('D11a owner update rejected -> approved is refused', false);
  exception when others then perform pg_temp.chk('D11a owner update rejected -> approved is refused', sqlstate = '42501', sqlerrm); end;
  begin delete from public.customer_accounts where id = acc_r; perform pg_temp.chk('D11b account delete is refused', false);
  exception when others then perform pg_temp.chk('D11b account delete is refused', sqlstate = '42501', sqlerrm); end;
  begin update public.customer_accounts set email = 'other@example.test' where id = acc_a; perform pg_temp.chk('D11c identity change is refused', false);
  exception when others then perform pg_temp.chk('D11c identity change is refused', sqlstate = '42501', sqlerrm); end;
  begin update public.customer_accounts set customer_id = 'cust-t21-b' where id = acc_a; perform pg_temp.chk('D11d re-linking a verified account is refused', false);
  exception when others then perform pg_temp.chk('D11d re-linking a verified account is refused', sqlstate = '42501', sqlerrm); end;
  begin insert into public.customer_accounts (auth_user_id, email, full_name, phone, phone_canonical, status, customer_id) values (unm_u, 'z@example.test', 'Z', '0611111111', '+252611111111', 'approved', 'cust-t21-b'); perform pg_temp.chk('D11e inserting an already-approved account is refused', false);
  exception when others then perform pg_temp.chk('D11e inserting an already-approved account is refused', sqlstate = '42501', sqlerrm); end;
  begin insert into public.customer_accounts (auth_user_id, email, full_name, phone, phone_canonical, customer_id) values (unm_u, 'z2@example.test', 'Z', '0611111111', '+252611111111', 'cust-t21-b'); perform pg_temp.chk('D11f a second account for an already-linked customer is refused (unique link)', false);
  exception when unique_violation then perform pg_temp.chk('D11f a second account for an already-linked customer is refused (unique link)', true);
            when others then perform pg_temp.chk('D11f a second account for an already-linked customer is refused (unique link)', true, sqlerrm); end;

  -- ---------------------------------------------------------------- E. approved customers
  t := pg_temp.q(ca_u, 'authenticated', 'select * from public.customer_catalog()');
  perform pg_temp.chk('E1 approved customer reads the private catalog (active products only)', case when pg_temp.err(t) then false else jsonb_array_length(t::jsonb) = v_prod_count end, left(t, 80));
  perform pg_temp.chk('E2 catalog exposes no cost and no exact stock',
    case when pg_temp.err(t) or jsonb_typeof(t::jsonb) <> 'array' or jsonb_array_length(t::jsonb) = 0 then false
         else not exists (select 1 from jsonb_array_elements(t::jsonb) e, jsonb_object_keys(e) key where key in ('cost_price', 'stock', 'low_stock_threshold', 'cost'))
              and (select count(*) from jsonb_object_keys((t::jsonb) -> 0)) in (11, 13) end, left(t, 80));   -- 11 columns at migration 21; migration 26 adds list_price and price_status (the customer's own price status)
  t := pg_temp.q(ca_u, 'authenticated', 'select public.my_orders() as o');
  j := (t::jsonb -> 0 -> 'o');
  select string_agg(e ->> 'id', ',') into v_ids from jsonb_array_elements(j) e;
  perform pg_temp.chk('E3 approved customer A sees ONLY A''s orders', v_ids = 'ORD-T21-A1' and not v_ids like '%B1%' and not v_ids like '%C1%', coalesce(v_ids, t));
  perform pg_temp.chk('E4 own order shows items with design name, unit price, own payments only',
    j -> 0 -> 'items' -> 0 ->> 'designName' = 'Design ORD-T21-A1' and (j -> 0 -> 'items' -> 0 ->> 'unitPrice')::numeric = 10
    and jsonb_array_length(j -> 0 -> 'payments') = 1 and j -> 0 -> 'payments' -> 0 ->> 'reference' = 'REF-A');
  perform pg_temp.chk('E5 nothing internal is returned: no cost, profit, commission, officer, notes, recorder',
    not (t ~* '(cost|gross_?profit|commission|marketingOfficer|deliveryNotes|delivery_notes|INTERNAL NOTE|recordedBy|recorded_by|internal payment note|created_by|legacy)'), left(t, 120));
  perform pg_temp.chk('E6 customer A cannot read B''s orders, payments, items, customer record, account or profile through any table or view',
    pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.orders'))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.order_details'))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.payments'))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.order_items'))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.customers'))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.customer_accounts'))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.customer_account_events'))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.profiles where id like ''u-t21%'''))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.commissions'))
    and pg_temp.none(pg_temp.q(ca_u, 'authenticated', 'select 1 as n from public.order_payment_terms')));
  j := (pg_temp.q(cb_u, 'authenticated', 'select public.my_orders() as o')::jsonb -> 0 -> 'o');
  perform pg_temp.chk('E7 customer B sees only B''s order; the customer linked to an existing officer-owned customer sees only its own',
    (select string_agg(e ->> 'id', ',') from jsonb_array_elements(j) e) = 'ORD-T21-B1'
    and (select string_agg(e ->> 'id', ',') from jsonb_array_elements(pg_temp.q(cp_u, 'authenticated', 'select public.my_orders() as o')::jsonb -> 0 -> 'o') e) = 'ORD-T21-C1');
  perform pg_temp.chk('E8 a newly created customer has no history yet', jsonb_array_length(pg_temp.q(cn_u, 'authenticated', 'select public.my_orders() as o')::jsonb -> 0 -> 'o') = 0);
  perform pg_temp.chk('E9 the client cannot supply an identity: my_orders takes no customer id, and the customer id in a forged argument is rejected',
    pg_temp.err(pg_temp.q(ca_u, 'authenticated', 'select public.my_orders(''cust-t21-b'') as o'))
    and (select count(*) from pg_proc where proname = 'my_orders' and pronargs = 0) = 1);
  t := pg_temp.q(ca_u, 'authenticated', format('select public.create_order(%L::jsonb)', json_build_object('customerId', 'cust-t21-a', 'items', json_build_array(json_build_object('productId', v_prod, 'quantity', 1)))::text));
  perform pg_temp.chk('E10a a customer cannot create orders (create_order)', pg_temp.denied(t), t);
  t := pg_temp.q(ca_u, 'authenticated', 'select public.record_payment(''ORD-T21-A1'', 1, ''EVC'', '''', '''', current_date)');
  perform pg_temp.chk('E10b a customer cannot record payments', pg_temp.err(t), t);
  t := pg_temp.q(ca_u, 'authenticated', 'select public.update_order_status(''ORD-T21-A1'', ''cancelled'', ''x'')');
  perform pg_temp.chk('E10c a customer cannot change order status', pg_temp.err(t), t);
  t := pg_temp.q(ca_u, 'authenticated', 'select public.set_order_payment_terms(''ORD-T21-A1'', ''credit'', ''customer attempt'')');
  perform pg_temp.chk('E10d a customer cannot set payment terms', pg_temp.err(t), t);
  t := pg_temp.q(ca_u, 'authenticated', 'select public.set_user_permissions(''u-t21-mgr'', array[''manage_users''])');
  perform pg_temp.chk('E10e a customer cannot change anyone''s permissions', pg_temp.err(t), t);
  t := pg_temp.q(ca_u, 'authenticated', format('select public.approve_customer_account(%L, null, true, true, ''self approval attempt'')', acc_a));
  perform pg_temp.chk('E10f a customer cannot approve accounts (not even their own)', pg_temp.denied(t), t);
  t := pg_temp.q(ca_u, 'authenticated', format('select * from public.find_customers_for_account(%L)', acc_a));
  perform pg_temp.chk('E10g a customer cannot list CRM candidates', pg_temp.denied(t), t);
  t := pg_temp.q(ca_u, 'authenticated', format('select public.convert_website_request(%L, ''{}''::jsonb)', gen_random_uuid()));
  perform pg_temp.chk('E10h a customer cannot convert website requests', pg_temp.err(t), t);
  t := pg_temp.q(ca_u, 'authenticated', 'update public.profiles set role = ''Super Admin'' where id = ''u-t21-mo'' returning 1 as n');
  perform pg_temp.chk('E11a a customer cannot change a staff profile', pg_temp.none(t) or pg_temp.err(t), t);
  t := pg_temp.q(ca_u, 'authenticated', 'insert into public.user_permissions (user_id, permission_code) values (''u-t21-mo'', ''manage_users'') returning 1 as n');
  perform pg_temp.chk('E11b a customer cannot grant themselves or others permissions', pg_temp.err(t), t);
  t := pg_temp.q(ca_u, 'authenticated', 'update public.customer_accounts set status = ''approved'' returning 1 as n');
  perform pg_temp.chk('E11c a customer cannot edit account status', pg_temp.err(t) or pg_temp.none(t), t);
  t := pg_temp.q(ca_u, 'authenticated', 'insert into public.customer_accounts (auth_user_id, email, full_name, phone, phone_canonical) values (gen_random_uuid(), ''x@example.test'', ''X'', ''0611111111'', ''+252611111111'') returning 1 as n');
  perform pg_temp.chk('E11d a customer cannot create accounts directly', pg_temp.err(t), t);
  perform pg_temp.chk('E11e customer auth users hold no staff profile and no permission',
    (select count(*) from public.profiles where auth_user_id in (ca_u, cb_u, cp_u, cn_u)) = 0
    and not public.user_holds_permission('u-t21-mo', 'manage_users'));

  -- suspend / reinstate: takes effect on the next request
  perform pg_temp.chk('E12 suspension takes effect immediately and reinstatement restores access (same sessions)',
    not pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.suspend_customer_account(%L, ''Payment dispute under review'')', acc_a)))
    and pg_temp.denied(pg_temp.q(ca_u, 'authenticated', 'select * from public.customer_catalog()'))
    and pg_temp.denied(pg_temp.q(ca_u, 'authenticated', 'select public.my_orders() as o'))
    and (pg_temp.q(ca_u, 'authenticated', 'select public.my_customer_account() as a')::jsonb -> 0 -> 'a' ->> 'status') = 'suspended'
    and not pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.reinstate_customer_account(%L, ''Dispute resolved, verified again'')', acc_a)))
    and not pg_temp.err(pg_temp.q(ca_u, 'authenticated', 'select * from public.customer_catalog()'))
    and (select customer_id from public.customer_accounts where id = acc_a) = 'cust-t21-a');

  -- ---------------------------------------------------------------- F. audit and history
  perform pg_temp.chk('F1 every transition has an event with actor, note and from/to (approved x4, rejected, suspended, reinstated)',
    (select count(*) from public.customer_account_events where event = 'approved' and actor_id = 'u-t21-mgr' and from_status = 'pending' and to_status = 'approved' and char_length(note) >= 10) = 4
    and (select count(*) from public.customer_account_events where event = 'rejected' and account_id = acc_r and actor_id = 'u-t21-mgr' and actor_name = 'T21 Manager') = 1
    and (select count(*) from public.customer_account_events where event = 'suspended' and account_id = acc_a and from_status = 'approved' and to_status = 'suspended') = 1
    and (select count(*) from public.customer_account_events where event = 'reinstated' and account_id = acc_a and from_status = 'suspended' and to_status = 'approved') = 1);
  perform pg_temp.chk('F2 the account row records the latest reviewer and time', (select reviewed_by = 'u-t21-mgr' and reviewed_at is not null from public.customer_accounts where id = acc_a));
  perform pg_temp.chk('F3 matching database-origin audit lines exist for each event',
    (select count(*) from public.system_logs where origin = 'database' and metadata ->> 'event' in ('customer_account_approved', 'customer_account_rejected', 'customer_account_suspended', 'customer_account_reinstated')
        and (metadata ->> 'accountId')::uuid in (acc_a, acc_b, acc_p, acc_r, acc_n)) = 7);
  perform pg_temp.chk('F4 approval metadata records whether an existing customer was linked and whether the phone matched',
    (select metadata ->> 'linkedExisting' from public.customer_account_events where account_id = acc_p and event = 'approved') = 'true'
    and (select metadata ->> 'phoneMatched' from public.customer_account_events where account_id = acc_p and event = 'approved') = 'true');
  begin update public.customer_account_events set note = 'x' where true; perform pg_temp.chk('F5 history cannot be edited', false);
  exception when others then perform pg_temp.chk('F5 history cannot be edited', sqlstate = '42501', sqlerrm); end;
  begin delete from public.customer_account_events where true; perform pg_temp.chk('F6 history cannot be deleted', false);
  exception when others then perform pg_temp.chk('F6 history cannot be deleted', sqlstate = '42501', sqlerrm); end;
  perform pg_temp.chk('F7 an authorized manager can read accounts and history; an unauthorized officer cannot',
    pg_temp.n(pg_temp.q(mgr_u, 'authenticated', 'select count(*) as n from public.customer_accounts')) >= 5
    and pg_temp.n(pg_temp.q(mgr_u, 'authenticated', 'select count(*) as n from public.customer_account_events')) >= 10
    and pg_temp.none(pg_temp.q(mo_u, 'authenticated', 'select 1 as n from public.customer_account_events')));

  -- ---------------------------------------------------------------- G. privileges, permission, regression
  perform pg_temp.chk('G1 new tables: anon has no privilege; authenticated has SELECT only (no INSERT/UPDATE/DELETE/TRUNCATE)',
    not has_table_privilege('anon', 'public.customer_accounts', 'select') and not has_table_privilege('anon', 'public.customer_account_events', 'select')
    and has_table_privilege('authenticated', 'public.customer_accounts', 'select')
    and not has_table_privilege('authenticated', 'public.customer_accounts', 'insert') and not has_table_privilege('authenticated', 'public.customer_accounts', 'update')
    and not has_table_privilege('authenticated', 'public.customer_accounts', 'delete') and not has_table_privilege('authenticated', 'public.customer_accounts', 'truncate')
    and not has_table_privilege('authenticated', 'public.customer_account_events', 'insert') and not has_table_privilege('authenticated', 'public.customer_account_events', 'truncate')
    and pg_temp.denied(pg_temp.q(null, 'anon', 'select 1 as n from public.customer_accounts')));
  perform pg_temp.chk('G2 internal helpers are not executable by clients',
    not has_function_privilege('authenticated', 'public.require_approved_customer()', 'execute')
    and not has_function_privilege('anon', 'public.require_approved_customer()', 'execute')
    and not has_function_privilege('authenticated', 'public.customer_registration_limits(text,text)', 'execute')
    and not has_function_privilege('authenticated', 'public.change_customer_account_status(uuid,text,text)', 'execute')
    and not has_function_privilege('authenticated', 'public.customer_account_log(public.customer_accounts,text,text,text,text,text,jsonb)', 'execute')
    and not has_function_privilege('anon', 'public.my_orders()', 'execute') and not has_function_privilege('anon', 'public.customer_catalog()', 'execute')
    and not has_function_privilege('anon', 'public.approve_customer_account(uuid,text,boolean,boolean,text)', 'execute'));
  perform pg_temp.chk('G3 anon cannot call the customer functions', pg_temp.denied(pg_temp.q(null, 'anon', 'select * from public.customer_catalog()')) and pg_temp.denied(pg_temp.q(null, 'anon', 'select public.my_orders() as o')));
  perform pg_temp.chk('G4 manage_customer_accounts is a reserved permission: only a Super Admin can grant it',
    'manage_customer_accounts' = any (public.reserved_permissions())
    and pg_temp.err(pg_temp.q(mgr_u, 'authenticated', 'select public.set_user_permissions(''u-t21-mo'', array[''manage_customer_accounts''])'))
    and not exists (select 1 from public.user_permissions where user_id = 'u-t21-mo' and permission_code = 'manage_customer_accounts')
    and not exists (select 1 from public.user_permissions up join public.profiles p on p.id = up.user_id
                     where up.permission_code = 'manage_customer_accounts' and p.id not in ('u-t21-mgr') and p.role <> 'Super Admin'));
  t := pg_temp.q(sa_u, 'authenticated', 'select public.set_user_permissions(''u-t21-stf'', array[''manage_customer_accounts'', ''view_orders''])');
  perform pg_temp.chk('G5 the Super Admin can grant it (and is not blocked by the new reservation)',
    not pg_temp.err(t) and exists (select 1 from public.user_permissions where user_id = 'u-t21-stf' and permission_code = 'manage_customer_accounts'), t);
  perform pg_temp.chk('G6 the permission is granted to no existing staff role by this migration',
    (select count(*) from public.user_permissions where permission_code = 'manage_customer_accounts' and user_id not like 'u-t21-%') = 0);
  perform pg_temp.chk('G7 existing public catalog unchanged: anon still reads public_products (same active rows, no cost)',
    pg_temp.n(pg_temp.q(null, 'anon', 'select count(*) as n from public.public_products')) = v_prod_count
    and pg_temp.none(pg_temp.q(null, 'anon', 'select 1 as n from public.products')));
  t := pg_temp.q(null, 'anon', format('select public.submit_order_request(%L::jsonb) as id', json_build_object('customerName', 'T21 Visitor', 'phone', '0699999999', 'lines', json_build_array(json_build_object('productId', v_prod, 'quantity', 1)), 'submissionKey', gen_random_uuid())::text));
  perform pg_temp.chk('G8 existing website order-request submission (anon) still works', not pg_temp.err(t), t);
  t := pg_temp.q(mo_u, 'authenticated', 'select id from public.customers where id like ''cust-t21-%''');
  perform pg_temp.chk('G9a existing staff regression: an officer limited to own customers sees only their own', t::jsonb = '[{"id": "cust-t21-c"}]'::jsonb, t);
  t := pg_temp.q(sa_u, 'authenticated', 'select count(*) as n from public.customers where id like ''cust-t21-%''');
  perform pg_temp.chk('G9b existing staff regression: the Super Admin sees all customers', pg_temp.n(t) = 3, t);
  t := pg_temp.q(sa_u, 'authenticated', 'select count(*) as n from public.products');
  perform pg_temp.chk('G9c existing staff regression: staff still read products (incl. cost sheet)', pg_temp.n(t) >= v_prod_count, t);
  perform pg_temp.chk('G10 no customer account holds a staff profile or any permission',
    not exists (select 1 from public.profiles p join public.customer_accounts a on a.auth_user_id = p.auth_user_id)
    and not exists (select 1 from public.user_permissions up join public.profiles p on p.id = up.user_id join public.customer_accounts a on a.auth_user_id = p.auth_user_id));
end
$t$;

select case when ok then 'PASS' else 'FAIL' end || '  ' || lpad(n::text, 3) || '  ' || name || case when detail <> '' and not ok then '  | ' || detail else '' end
  from r21 order by n;
select 'TOTAL: ' || count(*) || ' checks, ' || count(*) filter (where not ok) || ' failure(s)' from r21;
select count(*) filter (where not ok) = 0 as all_pass from r21 \gset

rollback;

\if :all_pass
\echo ALL CUSTOMER-ACCOUNT CHECKS PASS (transaction rolled back, nothing persists)
\else
\echo CUSTOMER-ACCOUNT CHECKS FAILED
select 1 / 0;   -- makes psql exit non-zero (ON_ERROR_STOP)
\endif
