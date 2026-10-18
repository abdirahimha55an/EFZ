-- =============================================================================
-- 25 - CHECKS for the customer credit policy v2 (migration 25, on top of 21 .. 24). Run with psql AFTER migration 25, on a database where the
-- credit policy row still holds the values migration 25 loaded (the first check reads them):
--   psql -X -v ON_ERROR_STOP=1 -d <db> -f supabase/checks/25_credit_policy_v2_checks.sql
-- One transaction, ROLLED BACK at the end (nothing persists). Calls are made as the real Postgres roles with a simulated Supabase JWT.
-- Time is simulated the only way a database test can: fixture dates (orders, due dates, settlement and approval times) are moved by the owner inside
-- this transaction, with the append-only guards temporarily disabled; the rules themselves always read the real server clock (efz_today()).
-- Concurrent credit orders are tested separately (supabase/checks/25_credit_concurrency.mjs: real parallel sessions).
-- =============================================================================
\set ON_ERROR_STOP on
\pset footer off
\pset tuples_only on

begin;

create temp table r25 (n serial, ok boolean, name text, detail text);

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
begin insert into r25 (ok, name, detail) values (coalesce(p_ok, false), p_name, left(coalesce(p_detail, ''), 500)); end $f$;
create function pg_temp.err(t text) returns boolean language sql immutable as $f$ select coalesce(t::jsonb @> '{"err": true}'::jsonb, false) $f$;
create function pg_temp.code(t text) returns text language sql immutable as $f$ select t::jsonb ->> 'code' $f$;
create function pg_temp.denied(t text) returns boolean language sql immutable as $f$ select pg_temp.err(t) and pg_temp.code(t) = '42501' $f$;
create function pg_temp.none(t text) returns boolean language sql immutable as $f$ select t = '[]' or pg_temp.denied(t) $f$;
create function pg_temp.jv(t text) returns jsonb language sql immutable as $f$ select case when pg_temp.err(t) then null else t::jsonb -> 0 -> 'v' end $f$;
create function pg_temp.msg(t text) returns text language sql immutable as $f$ select t::jsonb ->> 'msg' $f$;

-- fixtures helpers (the suite runs as the database owner)
create function pg_temp.mkdone(p_id text, p_customer text, p_days_ago integer, p_qty integer default 2) returns void language plpgsql as $f$
begin
  insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) values (p_id, p_customer, 'T25', '', 'delivered', 'regular', public.efz_today() - p_days_ago, '');
  insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost) values ('itm-' || p_id, p_id, 'p25-plain', 'P', 'P', p_qty, 10, 10, 5);
  insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes) values ('pay-' || lower(p_id), p_id, p_qty * 10, public.efz_today() - p_days_ago, 'Cash', '', '');
end $f$;
create function pg_temp.mkorder(p_id text, p_customer text, p_status text, p_date date, p_total integer, p_paid boolean default false) returns void language plpgsql as $f$
begin
  insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) values (p_id, p_customer, 'T25', '', p_status::public.order_status, 'regular', p_date, '');
  insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost) values ('itm-' || p_id, p_id, 'p25-plain', 'P', 'P', p_total / 10, 10, 10, 5);
  if p_paid then insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes) values ('pay-' || lower(p_id), p_id, p_total, p_date, 'Cash', '', ''); end if;
end $f$;
create function pg_temp.age_approval(p_customer text, p_days integer) returns void language plpgsql as $f$
begin
  alter table public.customer_account_events disable trigger trg_customer_account_events_guard;
  update public.customer_account_events set created_at = now() - make_interval(days => p_days) where event = 'approved' and account_id in (select id from public.customer_accounts where customer_id = p_customer);
  alter table public.customer_account_events enable trigger trg_customer_account_events_guard;
end $f$;
create function pg_temp.set_ext(p_order text, p_new_due date) returns void language plpgsql as $f$
begin
  alter table public.credit_due_extensions disable trigger trg_credit_extensions_guard;
  update public.credit_due_extensions set previous_due = p_new_due - 10, new_due = p_new_due where order_id = p_order;
  alter table public.credit_due_extensions enable trigger trg_credit_extensions_guard;
end $f$;
create function pg_temp.set_due(p_order text, p_due date) returns void language plpgsql as $f$
begin
  alter table public.customer_credit_orders disable trigger trg_credit_orders_nodelete;
  update public.customer_credit_orders set due_date = p_due where order_id = p_order;
  alter table public.customer_credit_orders enable trigger trg_credit_orders_nodelete;
end $f$;
create function pg_temp.move_settlement(p_customer text, p_days_ago integer) returns void language plpgsql as $f$
begin
  alter table public.customer_credit_defaults disable trigger trg_credit_defaults_guard;
  update public.customer_credit_defaults set settled_at = now() - make_interval(days => p_days_ago) where customer_id = p_customer and settled_at is not null;
  alter table public.customer_credit_defaults enable trigger trg_credit_defaults_guard;
end $f$;
create function pg_temp.place(p_user uuid, p_qty integer, p_key text) returns text language plpgsql as $f$
begin
  return pg_temp.q(p_user, 'authenticated', format('select public.customer_place_credit_order(%L::jsonb) as v', jsonb_build_object('deliveryLocation', 'Hodan', 'submissionKey', p_key,
           'lines', jsonb_build_array(jsonb_build_object('productId', 'p25-plain', 'quantity', p_qty)))::text));
end $f$;
create function pg_temp.cs(p_user uuid) returns jsonb language sql as $f$ select pg_temp.jv(pg_temp.q(p_user, 'authenticated', 'select public.customer_credit_status() as v')) $f$;
create function pg_temp.key(n integer) returns text language sql immutable as $f$ select 'f2500000-0000-4000-8000-' || lpad(n::text, 12, '0') $f$;

do $t$
declare
  sa_u  uuid := 'a5000000-0000-4000-8000-000000000001';   -- Super Admin
  mgr_u uuid := 'a5000000-0000-4000-8000-000000000002';   -- Manager (holds manage_customer_accounts, NOT a finance administrator)
  off_u uuid := 'a5000000-0000-4000-8000-000000000003';   -- Marketing Officer (holds neither)
  ca uuid := 'c5000000-0000-4000-8000-00000000000a';      -- clean qualifier
  cb uuid := 'c5000000-0000-4000-8000-00000000000b';      -- second customer (company cap, other customer's data)
  cc uuid := 'c5000000-0000-4000-8000-00000000000c';      -- default and requalification
  cd uuid := 'c5000000-0000-4000-8000-00000000000d';      -- reminders, escalation, extension
  ce uuid := 'c5000000-0000-4000-8000-00000000000e';      -- disputes and void
  cf uuid := 'c5000000-0000-4000-8000-00000000000f';      -- duplicate customer record (same phone as C)
  ch uuid := 'c5000000-0000-4000-8000-000000000011';      -- per-customer outstanding ceiling
  ci uuid := 'c5000000-0000-4000-8000-000000000012';      -- override rules, suspension, policy switched off
  cg uuid := 'c5000000-0000-4000-8000-000000000010';      -- same phone as C, left pending (duplicate-phone approval check)
  cx uuid := 'c5000000-0000-4000-8000-0000000000fa';      -- signed in, not a customer
  acc record; t text; j jsonb; k int := 0; v_n int; v_n2 int; v_id uuid; v_id2 uuid; v_order text; v_o2 text; v_o3 text; v_d uuid;
  v_a text; v_b text; v_c text; v_dd text; v_e text; v_f text; v_today date := public.efz_today(); v_first date := date_trunc('month', public.efz_today())::date;
  pol_before jsonb; cap jsonb; v_rev numeric; v_d2 uuid; v_h text; v_i text; v_av numeric; v_rem int; v_ntf int;
begin
  -- ---------------------------------------------------------------- fixtures
  select to_jsonb(p) into pol_before from public.credit_policy p where p.id;
  alter table public.orders disable trigger user;
  update public.orders set status = 'cancelled' where status <> 'cancelled';     -- (fixture, rolled back) whatever the database already holds must not change the arithmetic below
  alter table public.orders enable trigger user;
  insert into public.profiles (id, name, email, role, status) values
    ('u-t25-sa', 'T25 Super Admin', 't25-sa@example.test', 'Super Admin', 'active'),
    ('u-t25-mgr', 'T25 Manager', 't25-mgr@example.test', 'Manager', 'active'),
    ('u-t25-off', 'T25 Officer', 't25-off@example.test', 'Marketing Officer', 'active');
  insert into public.user_permissions (user_id, permission_code) values ('u-t25-mgr', 'manage_customer_accounts'), ('u-t25-mgr', 'edit_products'), ('u-t25-mgr', 'view_all_customers'), ('u-t25-mgr', 'view_orders'), ('u-t25-mgr', 'create_orders'), ('u-t25-mgr', 'edit_orders');
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
    (sa_u, 'authenticated', 'authenticated', 't25-sa@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
    (mgr_u, 'authenticated', 'authenticated', 't25-mgr@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
    (off_u, 'authenticated', 'authenticated', 't25-off@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
    (cx, 'authenticated', 'authenticated', 't25-x@example.test', now(), '{"provider":"email"}', '{}', now(), now());
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  select u, 'authenticated', 'authenticated', e, now(), '{"provider":"email","efz_kind":"customer"}', '{}', now(), now()
    from (values (ca, 't25-a@example.test'), (cb, 't25-b@example.test'), (cc, 't25-c@example.test'), (cd, 't25-d@example.test'), (ce, 't25-e@example.test'), (cf, 't25-f@example.test'), (cg, 't25-g@example.test'), (ch, 't25-h@example.test'), (ci, 't25-i@example.test')) v(u, e);
  insert into public.products (id, name, selling_price, cost_price, stock, is_active) values ('p25-plain', 'T25 Ball Plain', 10, 5, 1000000, true);
  for acc in select * from (values (ca, 't25-a@example.test', 'T25 Buyer A', '069 825 0001'), (cb, 't25-b@example.test', 'T25 Buyer B', '069 825 0002'), (cc, 't25-c@example.test', 'T25 Buyer C', '069 825 0003'),
                                   (cd, 't25-d@example.test', 'T25 Buyer D', '069 825 0004'), (ce, 't25-e@example.test', 'T25 Buyer E', '069 825 0005'), (cf, 't25-f@example.test', 'T25 Buyer F', '069 825 0003'), (cg, 't25-g@example.test', 'T25 Buyer G', '069 825 0003'), (ch, 't25-h@example.test', 'T25 Buyer H', '069 825 0006'), (ci, 't25-i@example.test', 'T25 Buyer I', '069 825 0007')) v(u, e, n, ph) loop
    perform pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, %L, %L, '''', null)', acc.u, acc.e, acc.n, acc.ph));
  end loop;
  for acc in select id from public.customer_accounts where email in ('t25-a@example.test', 't25-b@example.test', 't25-c@example.test', 't25-d@example.test', 't25-e@example.test', 't25-h@example.test', 't25-i@example.test') loop
    perform pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, null, true, false, ''Verified by phone call (T25)'')', acc.id));
  end loop;
  select customer_id into v_a from public.customer_accounts where email = 't25-a@example.test';
  select customer_id into v_b from public.customer_accounts where email = 't25-b@example.test';
  select customer_id into v_c from public.customer_accounts where email = 't25-c@example.test';
  select customer_id into v_dd from public.customer_accounts where email = 't25-d@example.test';
  select customer_id into v_e from public.customer_accounts where email = 't25-e@example.test';
  select customer_id into v_h from public.customer_accounts where email = 't25-h@example.test';
  select customer_id into v_i from public.customer_accounts where email = 't25-i@example.test';
  -- a customer record that only carries the company's sales history (no app account)
  insert into public.customers (id, name, email, phone, notes, status) values ('cust-t25-hist', 'T25 History', 'hist@example.test', '069 825 9999', 'sales history fixture', 'active');

  -- ---------------------------------------------------------------- A. configuration: the approved proposal, nothing activated
  perform pg_temp.chk('A1 migration 25 left the approved proposal in the policy row and credit OFF: 3 purchases, 90-day window, 60-day approved age, $40 initial limit, 30-day term, 25% cap over 3 complete months; no minimum purchase value; override, automatic increase and late fees off',
    pol_before ->> 'enabled' = 'false' and (pol_before ->> 'min_completed_purchases')::int = 3 and (pol_before ->> 'purchase_window_days')::int = 90 and (pol_before ->> 'min_approved_days')::int = 60
    and (pol_before ->> 'initial_credit_limit')::numeric = 40 and (pol_before ->> 'default_terms_days')::int = 30 and (pol_before ->> 'company_cap_percent')::numeric = 25 and (pol_before ->> 'cap_basis_months')::int = 3
    and pol_before -> 'min_total_value' = 'null'::jsonb and pol_before -> 'max_outstanding' = 'null'::jsonb and (pol_before ->> 'require_no_unpaid_delivered')::boolean
    and not (pol_before ->> 'allow_requirement_override')::boolean and not (pol_before ->> 'auto_limit_increase_enabled')::boolean and not (pol_before ->> 'late_fees_enabled')::boolean, pol_before::text);
  perform pg_temp.chk('A2 automatic limit increases and late fees cannot be switched on (a constraint holds them off)',
    exists (select 1 from pg_constraint where conrelid = 'public.credit_policy'::regclass and pg_get_constraintdef(oid) like '%NOT auto_limit_increase_enabled%')
    and exists (select 1 from pg_constraint where conrelid = 'public.credit_policy'::regclass and pg_get_constraintdef(oid) like '%NOT late_fees_enabled%'));
  begin update public.credit_policy set late_fees_enabled = true where id; perform pg_temp.chk('A2b late fees cannot be enabled by an update', false); exception when check_violation then perform pg_temp.chk('A2b late fees cannot be enabled by an update', true); end;
  begin update public.credit_policy set auto_limit_increase_enabled = true where id; perform pg_temp.chk('A2c automatic increases cannot be enabled by an update', false); exception when check_violation then perform pg_temp.chk('A2c automatic increases cannot be enabled by an update', true); end;
  perform pg_temp.chk('A3 customers, managers and anonymous callers cannot reach the six new tables, and no client can read or write them',
    (select bool_and(pg_temp.none(pg_temp.q(u, r, 'select 1 as v from public.' || tb)))
       from (values (ca, 'authenticated'), (cx, 'authenticated'), (null::uuid, 'anon'), (null::uuid, 'service_role')) c(u, r),
            (values ('customer_credit_defaults'), ('customer_credit_events'), ('credit_due_extensions'), ('credit_disputes'), ('credit_reminders'), ('customer_notifications')) x(tb)));
  perform pg_temp.chk('A4 every new admin function refuses a Manager (even one who reviews customer accounts), an Officer, a customer and anonymous callers (42501)',
    (select bool_and(pg_temp.denied(pg_temp.q(u, r, sql)))
       from (values (mgr_u, 'authenticated'), (off_u, 'authenticated'), (ca, 'authenticated'), (null::uuid, 'anon')) c(u, r),
            (values ('select public.set_credit_policy_rules(90, 40, 25, 3, false, ''reason here'') as v'), ('select public.credit_company_cap() as v'),
                    ('select public.increase_customer_credit_limit(''x'', 50, ''reason is long enough'') as v'), ('select public.extend_credit_due_date(''x'', current_date + 5, ''reason is long enough'') as v'),
                    ('select public.record_credit_risk_review(gen_random_uuid(), ''note is long enough'') as v'), ('select public.list_credit_disputes() as v'),
                    ('select public.update_credit_dispute(gen_random_uuid(), null, ''a note'') as v'), ('select public.resolve_credit_dispute(gen_random_uuid(), ''rejected'', ''resolution is long enough'') as v'),
                    ('select public.void_credit_default(gen_random_uuid(), gen_random_uuid(), ''reason is long enough'') as v'), ('select public.run_credit_checks() as v'),
                    ('select public.credit_operations() as v'), ('select public.credit_history(''x'') as v')) f(sql)));
  perform pg_temp.chk('A5 the scheduler entry point credit_daily_run is for service_role only; customers, staff, anonymous and the internal helpers cannot call it',
    pg_temp.denied(pg_temp.q(sa_u, 'authenticated', 'select public.credit_daily_run() as v')) and pg_temp.denied(pg_temp.q(ca, 'authenticated', 'select public.credit_daily_run() as v'))
    and pg_temp.denied(pg_temp.q(null, 'anon', 'select public.credit_daily_run() as v')) and not pg_temp.err(pg_temp.q(null, 'service_role', 'select public.credit_daily_run() as v'))
    and (select bool_and(pg_temp.denied(pg_temp.q(sa_u, 'authenticated', sql)))
           from (values ('select public._credit_run() as v'), ('select public._credit_sync_defaults(''x'') as v'), ('select public._credit_company_cap() as v'), ('select public._credit_effective_due(''x'') as v'),
                        ('select public._credit_send(''x'', ''x'', ''due_7'', ''customer'', ''t'', ''b'') as v'), ('select public._credit_notify_staff(''staff'', ''t'', ''b'') as v')) h(sql)));

  perform pg_temp.chk('A5b the database owner (the role a pg_cron job runs as) can run the daily run directly, and it answers with its counts', (select (public.credit_daily_run() ->> 'asOf') = public.efz_today()::text));
  -- ---------------------------------------------------------------- B. the company-wide cap and its revenue definition
  -- Sales history: an old order, three complete calendar months (100 + 200 + 280 plus one order on the FIRST and one on the LAST day of the window = 600), and orders that must NOT count.
  perform pg_temp.mkorder('ORD-T25-H0', 'cust-t25-hist', 'delivered', (v_first - interval '3 month' - interval '40 days')::date, 50, true);
  perform pg_temp.mkorder('ORD-T25-H1', 'cust-t25-hist', 'delivered', (v_first - interval '3 month')::date + 5, 100, true);
  perform pg_temp.mkorder('ORD-T25-H2', 'cust-t25-hist', 'delivered', (v_first - interval '2 month')::date + 5, 200, true);
  perform pg_temp.mkorder('ORD-T25-H3', 'cust-t25-hist', 'pending', (v_first - interval '1 month')::date + 5, 280, false);       -- booked sales count even before delivery or payment
  perform pg_temp.mkorder('ORD-T25-HFIRST', 'cust-t25-hist', 'delivered', (v_first - interval '3 month')::date, 10, true);            -- first day of the window: counts
  perform pg_temp.mkorder('ORD-T25-HLAST', 'cust-t25-hist', 'delivered', v_first - 1, 10, true);                                      -- last day of the window: counts
  perform pg_temp.mkorder('ORD-T25-HBEFORE', 'cust-t25-hist', 'delivered', (v_first - interval '3 month')::date - 1, 1000, true);       -- the day before: does not count
  perform pg_temp.mkorder('ORD-T25-HNOW', 'cust-t25-hist', 'delivered', v_first, 1000, true);                                         -- this month: does not count
  perform pg_temp.mkorder('ORD-T25-HCAN', 'cust-t25-hist', 'cancelled', (v_first - interval '2 month')::date + 9, 1000, false);        -- cancelled: does not count
  t := pg_temp.q(sa_u, 'authenticated', 'select public.credit_company_cap() as v'); cap := pg_temp.jv(t);
  perform pg_temp.chk('B1 the cap = 25% x the average monthly sales over the previous 3 COMPLETE calendar months: revenue 600, average 200, cap 50.00',
    (cap ->> 'sufficient') = 'true' and (cap ->> 'revenue')::numeric = 600 and (cap ->> 'averageMonthly')::numeric = 200 and (cap ->> 'cap')::numeric = 50 and (cap ->> 'percent')::numeric = 25 and (cap ->> 'months')::int = 3
    and (cap ->> 'windowStart')::date = (v_first - interval '3 month')::date and (cap ->> 'windowEnd')::date = v_first - 1, t);
  perform pg_temp.chk('B2 revenue is the existing definition (non-cancelled orders by order date, booked sales: an unpaid pending order counts; cancelled, the day before the window and the current month do not) and equals the figure the existing daily_sales view reports for the same days (one definition of revenue)',
    (select coalesce(sum(o.total), 0) from public.orders o where o.status <> 'cancelled' and o.order_date between (v_first - interval '3 month')::date and v_first - 1) = 600
    and (select coalesce(sum(revenue), 0) from public.daily_sales where order_date between (v_first - interval '3 month')::date and v_first - 1) = 600);
  perform pg_temp.chk('B3 the cap figures are never sent to a customer: no customer response mentions revenue, an average or a company cap',
    (select bool_and(body !~* '"(cap|averageMonthly|revenue|companyCap|windowStart)"') from (values (pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v')), (pg_temp.q(ca, 'authenticated', 'select public.my_finance() as v')),
                                                                                                           (pg_temp.q(ca, 'authenticated', 'select public.customer_payment_methods() as v'))) x(body)));
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy_rules(90, 40, 25, 24, false, ''T25 test: a 24-month basis'') as v');
  t := pg_temp.q(sa_u, 'authenticated', 'select public.credit_company_cap() as v');
  perform pg_temp.chk('B4 insufficient history: a 24-month basis is longer than EFZ''s sales history, so the cap is NOT computable (no invented number) and says why',
    (pg_temp.jv(t) ->> 'sufficient') = 'false' and (pg_temp.jv(t) ->> 'cap') is null and (pg_temp.jv(t) ->> 'reason') like '%Sales history starts on%', t);
  perform pg_temp.chk('B5 credit cannot be enabled while the cap is not computable, and the refusal says an administrator must review it',
    pg_temp.err(pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 3, null, true, 30, ''enable now'', 60, null, true) as v'))
    and pg_temp.msg(pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 3, null, true, 30, ''enable now'', 60, null, true) as v')) like '%cannot be computed reliably%'
    and (select enabled from public.credit_policy where id) = false);
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy_rules(90, 40, 25, 3, false, ''T25 test: back to the approved 3 months'') as v');
  alter table public.orders disable trigger user;   -- (fixture) make the history empty for the zero-revenue case
  update public.orders set status = 'cancelled' where id like 'ORD-T25-H%' and id not in ('ORD-T25-H0');
  alter table public.orders enable trigger user;
  t := pg_temp.q(sa_u, 'authenticated', 'select public.credit_company_cap() as v');
  perform pg_temp.chk('B6 no sales in the window (history exists but is cancelled): not computable, reason given', (pg_temp.jv(t) ->> 'sufficient') = 'false' and (pg_temp.jv(t) ->> 'reason') like '%no sales revenue%', t);
  alter table public.orders disable trigger user;
  update public.orders set status = case id when 'ORD-T25-H3' then 'pending'::public.order_status else 'delivered'::public.order_status end where id like 'ORD-T25-H%' and id not in ('ORD-T25-H0', 'ORD-T25-HCAN');
  alter table public.orders enable trigger user;
  perform pg_temp.chk('B7 with the history restored the cap is computable again (50.00)', (pg_temp.jv(pg_temp.q(sa_u, 'authenticated', 'select public.credit_company_cap() as v')) ->> 'cap')::numeric = 50);
  perform pg_temp.chk('B8 clearing a required setting stops credit from being enabled and names what is missing (purchase window)',
    not pg_temp.err(pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy_rules(null, 40, 25, 3, false, ''T25 test: clear the window'') as v'))
    and pg_temp.msg(pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 3, null, true, 30, ''enable now'', 60, null, true) as v')) like '%purchase-history window%');
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy_rules(90, 40, 25, 3, false, ''T25 test: window restored'') as v');
  perform pg_temp.chk('B9 the overdue rule cannot be switched off (a missed due date always revokes credit; there is no grace period)',
    pg_temp.err(pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(false, 3, null, true, 30, ''relax overdue'', 60, null, false) as v'))
    and pg_temp.msg(pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(false, 3, null, true, 30, ''relax overdue'', 60, null, false) as v')) like '%no grace period%');
  -- enable the policy (test run; the real Staging policy stays OFF because everything here is rolled back)
  t := pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 3, null, true, 30, ''T25 test: enable the approved proposal'', 60, null, true) as v');
  perform pg_temp.chk('B10 the approved proposal can be enabled once the policy is complete and the cap is computable; the change is audited with the old values',
    not pg_temp.err(t) and (select enabled from public.credit_policy where id) and exists (select 1 from public.system_logs where metadata ->> 'event' = 'credit_policy_set' and metadata ->> 'enabled' = 'true' and metadata -> 'before' ->> 'enabled' = 'false'), t);

  -- ---------------------------------------------------------------- C. standard eligibility (3 qualifying paid orders within 90 days, approved at least 60 days)
  perform pg_temp.age_approval(v_a, 70);
  perform pg_temp.mkdone('ORD-T25-A1', v_a, 10); perform pg_temp.mkdone('ORD-T25-A2', v_a, 40);
  insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost) values ('itm-a1b', 'ORD-T25-A1', 'p25-plain', 'P', 'P', 1, 10, 10, 5), ('itm-a1c', 'ORD-T25-A1', 'p25-plain', 'P', 'P', 1, 10, 10, 5);
  insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes) values ('pay-t25-a1b', 'ORD-T25-A1', 20, public.efz_today() - 10, 'Cash', '', '');
  j := pg_temp.cs(ca);
  perform pg_temp.chk('C1 two qualifying paid orders (not 3): not eligible, the shortfall is stated with the window',
    (j -> 'eligibility' ->> 'completedPurchases') = '2' and (j -> 'eligibility' ->> 'eligible') = 'false' and (j -> 'eligibility' ->> 'reasons') like '%1 more completed purchase(s) needed (2 of 3 in the last 90 days)%', j::text);
  perform pg_temp.mkdone('ORD-T25-A3', v_a, 90);
  j := pg_temp.cs(ca);
  perform pg_temp.chk('C2 an order exactly 90 days old counts (window boundary): exactly 3 qualifying orders, approved 70 days: eligible', (j -> 'eligibility' ->> 'completedPurchases') = '3' and (j -> 'eligibility' ->> 'eligible') = 'true', (select string_agg(id || ':' || status || ':' || order_date || ':' || total || '/' || amount_paid, ', ') from public.orders where customer_id = v_a));
  alter table public.orders disable trigger user; update public.orders set order_date = public.efz_today() - 91 where id = 'ORD-T25-A3'; alter table public.orders enable trigger user;
  j := pg_temp.cs(ca);
  perform pg_temp.chk('C3 the same order at 91 days is outside the window: 2 of 3, not eligible', (j -> 'eligibility' ->> 'completedPurchases') = '2' and (j -> 'eligibility' ->> 'eligible') = 'false');
  alter table public.orders disable trigger user; update public.orders set order_date = public.efz_today() - 90 where id = 'ORD-T25-A3'; alter table public.orders enable trigger user;
  -- orders that must not count
  perform pg_temp.mkorder('ORD-T25-AX1', v_a, 'cancelled', v_today - 5, 20, true);
  perform pg_temp.mkorder('ORD-T25-AX2', v_a, 'pending', v_today - 5, 20, true);
  perform pg_temp.mkorder('ORD-T25-AX3', v_a, 'delivered', v_today - 5, 40, false);
  insert into public.orders (id, customer_id, customer_name, phone, status, order_type, order_date, delivery_notes) values ('ORD-T25-AX4', v_a, 'T25', '', 'delivered', 'trial', v_today - 5, '');
  insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity, standard_unit_price, actual_unit_price, historical_unit_cost) values ('itm-ax4', 'ORD-T25-AX4', 'p25-plain', 'P', 'P', 2, 10, 10, 5);
  insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes) values ('pay-t25-ax4', 'ORD-T25-AX4', 20, v_today - 5, 'Cash', '', '');
  perform pg_temp.mkdone('ORD-T25-AX5', v_a, 5, 2);
  insert into public.customer_checkouts (customer_id, account_id, submission_key, method_code, status, lines, amount, delivery_location, order_id) values (v_a, (select id from public.customer_accounts where customer_id = v_a), gen_random_uuid(), 'stg_test', 'reversed', '[]', 20, 'x', 'ORD-T25-AX5');
  perform pg_temp.mkdone('ORD-T25-AX6', v_a, 4, 2);
  insert into public.customer_checkouts (customer_id, account_id, submission_key, method_code, status, lines, amount, delivery_location, order_id) values (v_a, (select id from public.customer_accounts where customer_id = v_a), gen_random_uuid(), 'stg_test', 'needs_review', '[]', 20, 'x', 'ORD-T25-AX6');
  j := pg_temp.cs(ca);
  perform pg_temp.chk('C4 not counted: cancelled, undelivered, delivered-but-unpaid, trial orders, and orders whose online payment was reversed or is under review; the unpaid delivered order is flagged (3 of 3 still, from the 3 genuine ones)',
    (j -> 'eligibility' ->> 'completedPurchases') = '3' and (j -> 'eligibility' -> 'standingReasons' ->> 0) like '%unpaid balance%' and (j -> 'eligibility' ->> 'eligible') = 'false', j::text);
  alter table public.orders disable trigger user; update public.orders set status = 'cancelled' where id = 'ORD-T25-AX3'; alter table public.orders enable trigger user;
  perform pg_temp.chk('C5 an order with three lines counts ONCE (distinct orders, not lines): A1 has 3 lines and A is still at 3 qualifying orders', (select count(*) from public.order_items where order_id = 'ORD-T25-A1') = 3 and (pg_temp.cs(ca) -> 'eligibility' ->> 'completedPurchases') = '3');
  perform pg_temp.age_approval(v_a, 59);
  j := pg_temp.cs(ca);
  perform pg_temp.chk('C6 approved for 59 days: not eligible (59 of 60)', (j -> 'eligibility' ->> 'daysApproved') = '59' and (j -> 'eligibility' ->> 'eligible') = 'false' and (j -> 'eligibility' ->> 'reasons') like '%59 of the 60 days%', j::text);
  perform pg_temp.age_approval(v_a, 60);
  j := pg_temp.cs(ca);
  perform pg_temp.chk('C7 approved for 60 days: eligible (60 of 60); eligibility alone grants nothing (no credit account, cannot buy)', (j -> 'eligibility' ->> 'daysApproved') = '60' and (j -> 'eligibility' ->> 'eligible') = 'true' and (j ->> 'canBuyOnCredit') = 'false' and (j -> 'account') = 'null'::jsonb, j::text);
  update public.credit_policy set min_total_value = 100 where id;
  j := pg_temp.cs(ca);
  perform pg_temp.chk('C8 a minimum purchase value, if EFZ sets one, is enforced (3 orders worth $80 < $100) and shown as its own reason; with none (the approved proposal) nothing is invented',
    (j -> 'eligibility' ->> 'eligible') = 'false' and (j -> 'eligibility' ->> 'reasons') like '%total $80.00; $100.00 is required%', j::text);
  update public.credit_policy set min_total_value = null where id;
  perform pg_temp.chk('C9 with no minimum value the requirement is ignored and A is eligible again', (pg_temp.cs(ca) -> 'eligibility' ->> 'eligible') = 'true');

  -- ---------------------------------------------------------------- D. limits, the term, the initial limit, repayment, the company cap
  perform pg_temp.chk('D1 authorizing credit refuses a term other than the policy''s 30 days, and a first limit above the $40 initial limit',
    pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 40, 14, ''Eligible, agreed (T25)'') as v', v_a))) and pg_temp.msg(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 40, 14, ''Eligible, agreed (T25)'') as v', v_a))) like '%fixed by the credit policy (30 days)%'
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 41, 30, ''Eligible, agreed (T25)'') as v', v_a))) and pg_temp.msg(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 41, 30, ''Eligible, agreed (T25)'') as v', v_a))) like '%cannot exceed the initial limit ($40.00)%'
    and not exists (select 1 from public.customer_credit_accounts where customer_id = v_a));
  t := pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 40, 30, ''Eligible, initial limit agreed (T25)'') as v', v_a));
  perform pg_temp.chk('D2 a Super Admin authorizes A at the $40 initial limit and 30 days; audited with the eligibility evidence; a history event is written', not pg_temp.err(t)
    and exists (select 1 from public.system_logs where metadata ->> 'event' = 'customer_credit_set' and target_id = v_a and metadata -> 'eligibility' is not null) and exists (select 1 from public.customer_credit_events where customer_id = v_a and kind = 'credit_approved'), t);
  j := pg_temp.cs(ca);
  perform pg_temp.chk('D3 A sees limit $40, available $40, outstanding 0, 30 days', (j ->> 'canBuyOnCredit') = 'true' and (j -> 'account' ->> 'creditLimit') = '40.00' and (j -> 'account' ->> 'available') = '40.00' and (j -> 'account' ->> 'termsDays') = '30', j::text);
  t := pg_temp.place(ca, 5, pg_temp.key(1)); v_order := pg_temp.jv(t) ->> 'orderId';
  perform pg_temp.chk('D4 an order of $50 exceeds the $40 limit: refused, nothing created', pg_temp.err(t) and pg_temp.msg(t) like '%above your available credit ($40.00)%' and (select count(*) from public.orders where customer_id = v_a and payment_terms = 'credit') = 0, t);
  t := pg_temp.place(ca, 2, pg_temp.key(2)); v_order := pg_temp.jv(t) ->> 'orderId';
  perform pg_temp.chk('D5 a $20 credit order is accepted: a normal order with credit terms, due in 30 days from today, issue date today', not pg_temp.err(t) and v_order is not null
    and (select payment_terms || '|' || total || '|' || outstanding_balance from public.orders where id = v_order) = 'credit|20.00|20.00'
    and (select due_date from public.customer_credit_orders where order_id = v_order) = v_today + 30 and (select terms_days from public.customer_credit_orders where order_id = v_order) = 30, t);
  perform pg_temp.chk('D6 the limit is the maximum OUTSTANDING balance, not a per-order allowance: a second $20 order exactly fills the $40 (accepted), a third $10 is refused',
    not pg_temp.err(pg_temp.place(ca, 2, pg_temp.key(3))) and pg_temp.err(pg_temp.place(ca, 1, pg_temp.key(4))) and (pg_temp.cs(ca) -> 'account' ->> 'available') = '0.00');
  select o.id into v_o2 from public.orders o where o.customer_id = v_a and o.payment_terms = 'credit' order by o.created_at, o.id limit 1;
  perform pg_temp.q(sa_u, 'authenticated', format('select public.record_payment(%L, 10, ''Cash'', null, ''R1'', ''repayment'') as v', v_o2));
  perform pg_temp.chk('D7 a recorded repayment of $10 frees exactly $10 of credit (outstanding $30, available $10); the limit itself did not move', (pg_temp.cs(ca) -> 'account' ->> 'available') = '10.00' and (pg_temp.cs(ca) -> 'account' ->> 'outstanding') = '30.00' and (pg_temp.cs(ca) -> 'account' ->> 'creditLimit') = '40.00');
  perform pg_temp.chk('D8 an unrecorded or customer-claimed payment changes nothing: customers cannot record payments, and credit only frees up through the payment table',
    pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.record_payment(%L, 25, ''Cash'') as v', v_o2))) and (pg_temp.cs(ca) -> 'account' ->> 'available') = '10.00');
  perform pg_temp.chk('D9 an overpayment is refused (cannot pay more than is owed), so a balance cannot be driven negative to create credit',
    pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.record_payment(%L, 500, ''Cash'', null, ''R2'', ''too much'') as v', v_o2))) and (select outstanding_balance from public.orders where id = v_o2) = 10);
  perform pg_temp.chk('D10 there is no automatic increase: after repayments the limit is still $40; raising it is a separate, audited Super Admin action that needs a reason, a higher figure and a customer in good standing',
    (select credit_limit from public.customer_credit_accounts where customer_id = v_a) = 40
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.increase_customer_credit_limit(%L, 40, ''Not actually higher than now'') as v', v_a)))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.increase_customer_credit_limit(%L, 60, ''short'') as v', v_a)))
    and pg_temp.denied(pg_temp.q(mgr_u, 'authenticated', format('select public.increase_customer_credit_limit(%L, 60, ''Manager is not allowed'') as v', v_a))));
  perform pg_temp.chk('D11 a lower figure through set_customer_credit is allowed, a higher one is refused there (use the audited increase)',
    pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 41, 30, ''Trying to raise it (T25)'') as v', v_a))) is true);

  -- calibration: the fixture orders of A and B fall inside the cap window as well, so the three monthly history orders are replaced by one top-up
  -- that makes the window hold exactly 600 of booked revenue again (cap 50.00)
  perform pg_temp.age_approval(v_b, 70);
  perform pg_temp.mkdone('ORD-T25-B1', v_b, 10); perform pg_temp.mkdone('ORD-T25-B2', v_b, 20); perform pg_temp.mkdone('ORD-T25-B3', v_b, 30);
  alter table public.orders disable trigger user; update public.orders set status = 'cancelled' where id in ('ORD-T25-H1', 'ORD-T25-H2', 'ORD-T25-H3'); alter table public.orders enable trigger user;
  select (pg_temp.jv(pg_temp.q(sa_u, 'authenticated', 'select public.credit_company_cap() as v')) ->> 'revenue')::numeric into v_rev;
  if v_rev <= 590 and mod(600 - v_rev, 10) = 0 then perform pg_temp.mkorder('ORD-T25-HTOP', 'cust-t25-hist', 'delivered', (v_first - interval '2 month')::date + 3, (600 - v_rev)::integer, true); end if;
  perform pg_temp.chk('D11b calibration: the cap window holds exactly 600 of booked sales again, so the cap is 50.00', (pg_temp.jv(pg_temp.q(sa_u, 'authenticated', 'select public.credit_company_cap() as v')) ->> 'cap')::numeric = 50, v_rev::text);
  perform pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 40, 30, ''Eligible, initial limit agreed (T25 B)'') as v', v_b));
  j := pg_temp.jv(pg_temp.q(sa_u, 'authenticated', 'select public.credit_company_cap() as v'));
  perform pg_temp.chk('D12 the company-wide credit outstanding is counted: $30 outstanding of the $50 cap leaves $20', (j ->> 'outstanding')::numeric = 30 and (j ->> 'available')::numeric = 20, j::text);
  perform pg_temp.chk('D13 B has $40 of personal credit but the company has only $20 of cap left: B''s available credit is $20 (the cap binds, no cap figure is shown)', (pg_temp.cs(cb) -> 'account' ->> 'available') = '20.00');
  t := pg_temp.place(cb, 3, pg_temp.key(5));
  perform pg_temp.chk('D14 an order above the company cap room ($30 > $20) is refused with the ordinary credit message (the cap itself is not revealed)', pg_temp.err(t) and pg_temp.msg(t) like '%above your available credit ($20.00)%' and pg_temp.msg(t) !~* 'cap', t);
  t := pg_temp.place(cb, 1, pg_temp.key(6));
  perform pg_temp.chk('D15 an order below the cap room ($10 < $20) is accepted; the company outstanding is then $40 of $50', not pg_temp.err(t) and (pg_temp.jv(pg_temp.q(sa_u, 'authenticated', 'select public.credit_company_cap() as v')) ->> 'outstanding')::numeric = 40, t);
  t := pg_temp.place(cb, 1, pg_temp.key(7));
  perform pg_temp.chk('D16 an order of exactly the room that remains ($10) is accepted (boundary): the company outstanding now EQUALS the cap ($50)', not pg_temp.err(t) and (pg_temp.jv(pg_temp.q(sa_u, 'authenticated', 'select public.credit_company_cap() as v')) ->> 'outstanding')::numeric = 50
    and (pg_temp.jv(pg_temp.q(sa_u, 'authenticated', 'select public.credit_company_cap() as v')) ->> 'available')::numeric = 0, t);
  t := pg_temp.place(cb, 1, pg_temp.key(8));
  perform pg_temp.chk('D17 at the cap ($50 of $50) nothing more is accepted for anyone (B refused, and A refused although A has personal room)', pg_temp.err(t) and pg_temp.err(pg_temp.place(ca, 1, pg_temp.key(10))), t);
  perform pg_temp.chk('D18 above the cap (the cap falls to $20 with a 10% share while $50 is owed): new credit orders stay refused and the existing balances are untouched',
    not pg_temp.err(pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy_rules(90, 40, 10, 3, false, ''T25 test: a lower percentage'') as v'))
    and (pg_temp.jv(pg_temp.q(sa_u, 'authenticated', 'select public.credit_company_cap() as v')) ->> 'available')::numeric = 0 and pg_temp.err(pg_temp.place(cb, 1, pg_temp.key(9))));
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy_rules(90, 40, 25, 3, false, ''T25 test: the approved 25% again'') as v');
  perform pg_temp.chk('D19 existing orders and balances were never touched by the cap changing (B and A still owe what they owed)', (select coalesce(sum(outstanding_balance), 0) from public.orders where customer_id in (v_a, v_b) and payment_terms = 'credit' and status <> 'cancelled') = 50);

  -- ---------------------------------------------------------------- E. default, no grace period, no automatic restoration, requalification at the initial limit
  perform pg_temp.age_approval(v_c, 70);
  perform pg_temp.mkdone('ORD-T25-C1', v_c, 10); perform pg_temp.mkdone('ORD-T25-C2', v_c, 20); perform pg_temp.mkdone('ORD-T25-C3', v_c, 30);
  perform pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 40, 30, ''Eligible, initial limit agreed (T25 C)'') as v', v_c));
  -- free the company cap for C: A and B repay in full (their invoices are paid, not defaulted)
  for acc in select o.id from public.orders o where o.customer_id in (v_a, v_b) and o.payment_terms = 'credit' and o.status <> 'cancelled' and o.outstanding_balance > 0 loop
    perform pg_temp.q(sa_u, 'authenticated', format('select public.record_payment(%L, %s, ''Cash'', null, ''CLR'', ''clear'') as v', acc.id, (select outstanding_balance from public.orders where id = acc.id)));
  end loop;
  t := pg_temp.place(cc, 3, pg_temp.key(20)); v_order := pg_temp.jv(t) ->> 'orderId';
  perform pg_temp.chk('E1 C buys $30 on credit (due in 30 days)', not pg_temp.err(t) and v_order is not null, t);
  perform pg_temp.set_due(v_order, v_today);
  j := pg_temp.cs(cc);
  perform pg_temp.chk('E2 on the due date itself the invoice is NOT overdue: no default, credit still open (available $10)', (j ->> 'canBuyOnCredit') = 'true' and (j -> 'account' ->> 'available') = '10.00' and (j -> 'default' ->> 'inDefault') = 'false'
    and not exists (select 1 from public.customer_credit_defaults where customer_id = v_c), j::text);
  perform pg_temp.set_due(v_order, v_today - 1);
  t := pg_temp.place(cc, 1, pg_temp.key(21));
  perform pg_temp.chk('E3 ONE DAY after the due date, with no job having run: a credit order is refused at once on the server (no grace period), and the refusal is the generic one', pg_temp.denied(t), t);
  j := pg_temp.cs(cc);
  perform pg_temp.chk('E4 the default was recorded the moment anyone looked: defaulted_on = the first overdue day, amount, original due date; the account is revoked; the customer is told credit is switched off and that paying does not restore it',
    exists (select 1 from public.customer_credit_defaults where customer_id = v_c and order_id = v_order and defaulted_on = v_today and due_date = v_today - 1 and amount_at_default = 30 and limit_at_default = 40)
    and (select status from public.customer_credit_accounts where customer_id = v_c) = 'revoked' and (j ->> 'canBuyOnCredit') = 'false' and (j -> 'default' ->> 'inDefault') = 'true'
    and (j ->> 'message') like '%overdue%does not restore credit%' and (j -> 'account' ->> 'overdue') = '30.00', j::text);
  perform pg_temp.chk('E5 the default is in the credit history and audit log, the customer has an in-app notice, and authorized staff have been notified (Super Admin and the Manager who reviews accounts, NOT the officer)',
    exists (select 1 from public.customer_credit_events where customer_id = v_c and kind = 'default_recorded') and exists (select 1 from public.customer_credit_events where customer_id = v_c and kind = 'credit_revoked')
    and exists (select 1 from public.system_logs where metadata ->> 'event' = 'credit_default_recorded' and target_id = v_c) and exists (select 1 from public.customer_notifications where customer_id = v_c and kind = 'overdue_1')
    and exists (select 1 from public.notifications where user_id = 'u-t25-sa' and title = 'Customer credit revoked') and exists (select 1 from public.notifications where user_id = 'u-t25-mgr' and title = 'Customer credit revoked')
    and not exists (select 1 from public.notifications where user_id = 'u-t25-off' and title = 'Customer credit revoked'));
  -- account duplication guard: another customer record with the same phone number inherits the default history
  perform pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, null, true, true, ''Different person, confirmed (T25 duplicate)'')', (select id from public.customer_accounts where email = 't25-f@example.test')));
  select customer_id into v_f from public.customer_accounts where email = 't25-f@example.test';
  perform pg_temp.age_approval(v_f, 70);
  perform pg_temp.mkdone('ORD-T25-F1', v_f, 10); perform pg_temp.mkdone('ORD-T25-F2', v_f, 20); perform pg_temp.mkdone('ORD-T25-F3', v_f, 30);
  perform pg_temp.chk('E5b a second customer record with the same phone number (approved only with explicit staff confirmation) is a different record, but C''s unsettled default applies to it: not eligible, standing reason shown, and staff cannot authorize it (no override covers it)',
    v_f is not null and v_f <> v_c and (pg_temp.cs(cf) -> 'eligibility' ->> 'eligible') = 'false' and (pg_temp.cs(cf) -> 'eligibility' -> 'standingReasons' ->> 0) like '%revoked after a missed due date%'
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 40, 30, ''Duplicate record (T25)'', ''Override for the duplicate'') as v', v_f))));
  perform pg_temp.chk('E5c creating a customer with a phone number that already belongs to a customer needs explicit human confirmation, and one customer can have only one app account',
    pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, null, false, false, ''no confirmation'')', (select id from public.customer_accounts where email = 't25-g@example.test'))))
    and exists (select 1 from pg_indexes where indexname = 'customer_accounts_customer_key'));
  select count(*) into v_n from public.customer_credit_defaults where customer_id = v_c; select count(*) into v_n2 from public.credit_reminders where order_id = v_order and kind = 'overdue_1';
  perform pg_temp.cs(cc); perform pg_temp.cs(cc); perform pg_temp.q(null, 'service_role', 'select public.credit_daily_run() as v');
  perform pg_temp.chk('E6 looking again or running the job any number of times records the default once and sends each notice once', (select count(*) from public.customer_credit_defaults where customer_id = v_c) = v_n
    and (select count(*) from public.credit_reminders where order_id = v_order and kind = 'overdue_1') = v_n2 and (select count(*) from public.customer_notifications where customer_id = v_c and kind = 'overdue_1') = 1);
  perform pg_temp.q(sa_u, 'authenticated', format('select public.record_payment(%L, 10, ''Cash'', null, ''PART'', ''partial after default'') as v', v_order));
  j := pg_temp.cs(cc);
  perform pg_temp.chk('E7 a PARTIAL repayment after default ($10 of $30): still in default, still blocked, nothing restored', (j ->> 'canBuyOnCredit') = 'false' and (j -> 'default' ->> 'inDefault') = 'true' and (j -> 'account' ->> 'overdue') = '20.00'
    and (select settled_at from public.customer_credit_defaults where customer_id = v_c) is null and pg_temp.denied(pg_temp.place(cc, 1, pg_temp.key(22))), j::text);
  perform pg_temp.q(sa_u, 'authenticated', format('select public.record_payment(%L, 20, ''EVC'', null, ''FULL'', ''settled'') as v', v_order));
  j := pg_temp.cs(cc);
  perform pg_temp.chk('E8 FULL repayment settles the debt (outstanding 0, default marked settled) but does NOT restore credit: cannot buy, the account stays revoked, the message separates "debt settled" from "credit restored" and tells the customer to qualify again',
    (select outstanding_balance from public.orders where id = v_order) = 0 and (select settled_at from public.customer_credit_defaults where customer_id = v_c) is not null
    and (j ->> 'canBuyOnCredit') = 'false' and (select status from public.customer_credit_accounts where customer_id = v_c) = 'revoked' and (j -> 'default' ->> 'inDefault') = 'false' and (j -> 'default' ->> 'everDefaulted') = 'true'
    and (j ->> 'message') like '%debt is settled, but credit stays switched off%qualify again%' and pg_temp.denied(pg_temp.place(cc, 1, pg_temp.key(23))), j::text);
  j := pg_temp.cs(cf);
  perform pg_temp.chk('E8b after C settles, the duplicate record is still not eligible: its requalification also starts at that settlement (0 of 3 orders, 0 of 60 days) although it has 3 older paid orders and a 70-day approval', (j -> 'eligibility' ->> 'eligible') = 'false' and (j -> 'eligibility' ->> 'completedPurchases') = '0' and (j -> 'eligibility' ->> 'daysApproved') = '0', j::text);
  perform pg_temp.chk('E9 the default history is intact after settlement: the same row with its original due date, amount and default date, plus the settlement; the event history shows default, revocation and settlement; and the history cannot be edited or deleted',
    exists (select 1 from public.customer_credit_defaults where customer_id = v_c and due_date = v_today - 1 and defaulted_on = v_today and amount_at_default = 30 and settled_at is not null and voided_at is null)
    and (select count(*) from public.customer_credit_events where customer_id = v_c and kind in ('default_recorded', 'credit_revoked', 'default_settled')) = 3);
  begin update public.customer_credit_defaults set due_date = v_today + 5 where customer_id = v_c; perform pg_temp.chk('E9b a recorded default cannot be rewritten (not even by the owner while the guard is on)', false);
  exception when others then perform pg_temp.chk('E9b a recorded default cannot be rewritten (not even by the owner while the guard is on)', sqlstate = '42501'); end;
  begin delete from public.customer_credit_defaults where customer_id = v_c; perform pg_temp.chk('E9c a recorded default cannot be deleted', false);
  exception when others then perform pg_temp.chk('E9c a recorded default cannot be deleted', sqlstate = '42501'); end;
  begin delete from public.customer_credit_events where customer_id = v_c; perform pg_temp.chk('E9d credit history events cannot be deleted', false);
  exception when others then perform pg_temp.chk('E9d credit history events cannot be deleted', sqlstate = '42501'); end;
  perform pg_temp.chk('E10 ordinary upfront purchases still work for a customer who defaulted (credit is the only thing revoked): the customer can price a cart and use the normal checkout',
    not pg_temp.err(pg_temp.q(cc, 'authenticated', format('select public.customer_price_preview(%L::jsonb) as v', jsonb_build_array(jsonb_build_object('productId', 'p25-plain', 'quantity', 1))::text)))
    and not pg_temp.err(pg_temp.q(cc, 'authenticated', 'select public.customer_payment_methods() as v')));
  -- requalification: starts at the settlement; the old orders and the old approval do not count
  j := pg_temp.cs(cc);
  perform pg_temp.chk('E11 right after settlement the requalification starts again from zero: 0 of 3 purchases since settlement, 0 of 60 days; the three older paid orders and the old approval do NOT count',
    (j -> 'eligibility' ->> 'completedPurchases') = '0' and (j -> 'eligibility' ->> 'daysApproved') = '0' and (j -> 'eligibility' ->> 'eligible') = 'false' and (j -> 'eligibility' ->> 'reasons') like '%3 more completed purchase(s) needed (0 of 3%'
    and (j -> 'eligibility' ->> 'reasons') like '%0 of the 60 days%', j::text);
  alter table public.orders disable trigger user; update public.orders set order_date = public.efz_today() - 200 where id in ('ORD-T25-C1', 'ORD-T25-C2', 'ORD-T25-C3'); alter table public.orders enable trigger user;   -- time has passed: the pre-default orders are old
  perform pg_temp.move_settlement(v_c, 70);
  perform pg_temp.mkdone('ORD-T25-C4', v_c, 30); perform pg_temp.mkdone('ORD-T25-C5', v_c, 15);
  j := pg_temp.cs(cc);
  perform pg_temp.chk('E12 requalification with only 2 qualifying paid orders since the settlement (settled 70 days ago): not eligible (2 of 3)', (j -> 'eligibility' ->> 'completedPurchases') = '2' and (j -> 'eligibility' ->> 'eligible') = 'false' and (j -> 'eligibility' ->> 'daysApproved') = '70', j::text);
  perform pg_temp.mkdone('ORD-T25-C6', v_c, 5);
  perform pg_temp.move_settlement(v_c, 59);
  j := pg_temp.cs(cc);
  perform pg_temp.chk('E13 3 qualifying orders since the settlement but only 59 days since it: not eligible (59 of 60): insufficient account age', (j -> 'eligibility' ->> 'completedPurchases') = '3' and (j -> 'eligibility' ->> 'daysApproved') = '59' and (j -> 'eligibility' ->> 'eligible') = 'false', j::text);
  perform pg_temp.chk('E14 staff cannot authorize credit again while the customer has not completed requalification, and no override covers a default (even with a reason and even if overrides were allowed)',
    pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 40, 30, ''Trying again (T25)'', ''Owner insists on this exception'') as v', v_c)))
    and pg_temp.msg(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 40, 30, ''Trying again (T25)'', ''Owner insists on this exception'') as v', v_c))) like '%defaulted and has not completed requalification%No override applies to a default%'
    and (select status from public.customer_credit_accounts where customer_id = v_c) = 'revoked');
  perform pg_temp.move_settlement(v_c, 60);
  j := pg_temp.cs(cc);
  perform pg_temp.chk('E15 requalified: 3 qualifying paid orders since the settlement and exactly 60 days: ELIGIBLE again - but still cannot buy until a Super Admin approves credit', (j -> 'eligibility' ->> 'eligible') = 'true' and (j ->> 'canBuyOnCredit') = 'false' and pg_temp.denied(pg_temp.place(cc, 1, pg_temp.key(24))), j::text);
  perform pg_temp.chk('E16 the renewed limit cannot exceed the INITIAL limit whatever the former limit was: $41 is refused, and a former limit of $100 cannot be restored',
    pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 41, 30, ''Renewing credit (T25)'') as v', v_c))) and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 100, 30, ''Renewing credit (T25)'') as v', v_c))));
  t := pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 40, 30, ''Requalified, credit approved again at the initial limit (T25)'') as v', v_c));
  j := pg_temp.cs(cc);
  perform pg_temp.chk('E17 a Super Admin approves credit again: the limit is $40 (the initial limit), status approved, the event history says "requalified" and the default is marked requalified (and still on record)',
    not pg_temp.err(t) and (j -> 'account' ->> 'creditLimit') = '40.00' and (j ->> 'canBuyOnCredit') = 'true' and exists (select 1 from public.customer_credit_events where customer_id = v_c and kind = 'requalified')
    and exists (select 1 from public.customer_credit_defaults where customer_id = v_c and requalified_at is not null and settled_at is not null), t || ' ' || j::text);
  perform pg_temp.chk('E18 a customer cannot requalify by themselves or change their own status: no customer function or table write reaches the credit account, the default or the policy',
    pg_temp.err(pg_temp.q(cc, 'authenticated', format('update public.customer_credit_accounts set status = ''approved'', credit_limit = 9999 where customer_id = %L returning 1 as v', v_c)))
    and pg_temp.err(pg_temp.q(cc, 'authenticated', format('update public.customer_credit_defaults set settled_at = now(), voided_at = now() where customer_id = %L returning 1 as v', v_c)))
    and pg_temp.denied(pg_temp.q(cc, 'authenticated', format('select public.set_customer_credit(%L, 40, 30, ''self approval'') as v', v_c))));
  perform pg_temp.chk('E19 after requalification the customer buys on credit again ($40 limit): a $30 order is accepted, a second $20 order is refused', not pg_temp.err(pg_temp.place(cc, 3, pg_temp.key(25))) and pg_temp.err(pg_temp.place(cc, 2, pg_temp.key(26))));
  -- a customer who defaulted keeps the initial limit: no increase path
  perform pg_temp.chk('E20 a customer who has defaulted cannot have the limit raised (needs a separately approved policy)',
    pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.increase_customer_credit_limit(%L, 60, ''Wanted a higher limit for C'') as v', v_c))) and pg_temp.msg(pg_temp.q(sa_u, 'authenticated', format('select public.increase_customer_credit_limit(%L, 60, ''Wanted a higher limit for C'') as v', v_c))) like '%keeps the initial limit%');
  -- ---------------------------------------------------------------- F. reminders and escalation (idempotent, failures recorded, only the right people notified)
  perform pg_temp.age_approval(v_dd, 70);
  perform pg_temp.mkdone('ORD-T25-D1', v_dd, 10); perform pg_temp.mkdone('ORD-T25-D2', v_dd, 20); perform pg_temp.mkdone('ORD-T25-D3', v_dd, 30);
  perform pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 40, 30, ''Eligible, initial limit agreed (T25 D)'') as v', v_dd));
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy_rules(90, 40, 100, 3, false, ''T25 test: widen the cap for the reminder scenarios'') as v');
  t := pg_temp.place(cd, 2, pg_temp.key(40)); v_order := pg_temp.jv(t) ->> 'orderId';
  perform pg_temp.chk('F0 setup: D has a $20 credit invoice', not pg_temp.err(t) and v_order is not null, t);
  perform pg_temp.set_due(v_order, v_today + 8);
  perform pg_temp.q(null, 'service_role', 'select public.credit_daily_run() as v');
  perform pg_temp.chk('F1 8 days before the due date: no reminder yet', (select count(*) from public.credit_reminders where order_id = v_order) = 0);
  perform pg_temp.set_due(v_order, v_today + 7);
  perform pg_temp.q(null, 'service_role', 'select public.credit_daily_run() as v');
  perform pg_temp.chk('F2 7 days before the due date: ONE payment reminder to the customer (in-app), recorded as sent', (select count(*) from public.credit_reminders where order_id = v_order and kind = 'due_7' and audience = 'customer' and status = 'sent' and attempts = 1) = 1
    and (select count(*) from public.customer_notifications where customer_id = v_dd and kind = 'due_7') = 1);
  perform pg_temp.q(null, 'service_role', 'select public.credit_daily_run() as v'); perform pg_temp.q(sa_u, 'authenticated', 'select public.run_credit_checks() as v'); perform pg_temp.q(null, 'service_role', 'select public.credit_daily_run() as v');
  perform pg_temp.chk('F3 repeated and parallel-style runs (job retries, a manual run, a restart) never duplicate the reminder', (select count(*) from public.credit_reminders where order_id = v_order and kind = 'due_7') = 1 and (select count(*) from public.customer_notifications where customer_id = v_dd and kind = 'due_7') = 1);
  perform pg_temp.set_due(v_order, v_today);
  perform pg_temp.q(null, 'service_role', 'select public.credit_daily_run() as v');
  perform pg_temp.chk('F4 on the due date: a due-date reminder (and still no default)', (select count(*) from public.credit_reminders where order_id = v_order and kind = 'due_0' and status = 'sent') = 1 and not exists (select 1 from public.customer_credit_defaults where order_id = v_order));
  perform pg_temp.set_due(v_order, v_today - 1);
  perform pg_temp.q(null, 'service_role', 'select public.credit_daily_run() as v');
  perform pg_temp.chk('F5 first day overdue: credit revoked, customer and staff notified, nothing sent twice',
    (select status from public.customer_credit_accounts where customer_id = v_dd) = 'revoked' and (select count(*) from public.credit_reminders where order_id = v_order and kind = 'overdue_1' and status = 'sent') = 2
    and (select count(*) from public.notifications where user_id = 'u-t25-sa' and message like '%' || v_order || '%' and title = 'Customer credit revoked') = 1);
  perform pg_temp.set_due(v_order, v_today - 7);
  perform pg_temp.q(null, 'service_role', 'select public.credit_daily_run() as v');
  perform pg_temp.chk('F6 7 days overdue: an overdue reminder to the customer and a staff follow-up flag (the account is listed as needing follow-up)',
    (select count(*) from public.credit_reminders where order_id = v_order and kind = 'overdue_7' and status = 'sent') = 2
    and (select (x ->> 'followUpDue')::boolean from jsonb_array_elements(pg_temp.jv(pg_temp.q(sa_u, 'authenticated', 'select public.credit_operations() as v')) -> 'defaults') x where x ->> 'orderId' = v_order));
  perform pg_temp.chk('F7 before 30 days there is no Super Admin escalation and no review requirement', not exists (select 1 from public.credit_reminders where order_id = v_order and kind = 'overdue_30') and (select review_required_at from public.customer_credit_defaults where order_id = v_order) is null);
  perform pg_temp.set_due(v_order, v_today - 30);
  perform pg_temp.q(null, 'service_role', 'select public.credit_daily_run() as v'); perform pg_temp.q(null, 'service_role', 'select public.credit_daily_run() as v');
  perform pg_temp.chk('F8 30 days overdue: escalated ONCE to Super Admins only (not the Manager, not the officer), and a documented credit-risk review is required',
    (select count(*) from public.credit_reminders where order_id = v_order and kind = 'overdue_30' and audience = 'super_admin' and status = 'sent') = 1
    and exists (select 1 from public.notifications where user_id = 'u-t25-sa' and title = 'Overdue 30 days: credit-risk review') and not exists (select 1 from public.notifications where user_id in ('u-t25-mgr', 'u-t25-off') and title = 'Overdue 30 days: credit-risk review')
    and (select review_required_at from public.customer_credit_defaults where order_id = v_order) is not null);
  select id into v_d from public.customer_credit_defaults where order_id = v_order;
  t := pg_temp.q(sa_u, 'authenticated', format('select public.record_credit_risk_review(%L, ''short'') as v', v_d));
  perform pg_temp.chk('F9a a review needs a documented note of 10+ characters', pg_temp.err(t), t);
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.record_credit_risk_review(%L, ''A manager may not record the review'') as v', v_d));
  perform pg_temp.chk('F9b only a Super Admin can record the review', pg_temp.denied(t), t);
  t := pg_temp.q(sa_u, 'authenticated', format('select public.record_credit_risk_review(%L, ''Called the customer; payment plan agreed outside the system'') as v', v_d));
  perform pg_temp.chk('F9c the Super Admin records the documented review (who, when, note), audited and in the history', not pg_temp.err(t) and (select reviewed_at is not null and review_note like 'Called the customer%' from public.customer_credit_defaults where id = v_d)
    and exists (select 1 from public.customer_credit_events where kind = 'risk_review' and metadata ->> 'orderId' = v_order), t);
  t := pg_temp.q(sa_u, 'authenticated', format('select public.record_credit_risk_review(%L, ''A second review attempt for the same default'') as v', v_d));
  perform pg_temp.chk('F9d a review is recorded once and cannot be overwritten', pg_temp.err(t) and pg_temp.msg(t) like '%already recorded%', t);
  -- a failing delivery
  create function pg_temp.fail_notify() returns trigger language plpgsql as $f$ begin if new.customer_id = (select customer_id from public.customer_accounts where email = 't25-e@example.test') then raise exception 'simulated delivery failure'; end if; return new; end $f$;
  perform pg_temp.mkdone('ORD-T25-E1', v_e, 10); perform pg_temp.mkdone('ORD-T25-E2', v_e, 20); perform pg_temp.mkdone('ORD-T25-E3', v_e, 30); perform pg_temp.age_approval(v_e, 70);
  perform pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 40, 30, ''Eligible, initial limit agreed (T25 E)'') as v', v_e));
  v_o3 := pg_temp.jv(pg_temp.place(ce, 2, pg_temp.key(60))) ->> 'orderId';
  perform pg_temp.set_due(v_o3, v_today + 3);
  create trigger trg_t25_fail before insert on public.customer_notifications for each row execute function pg_temp.fail_notify();
  perform pg_temp.q(null, 'service_role', 'select public.credit_daily_run() as v');
  perform pg_temp.chk('F10 a failed delivery is recorded on the reminder (status failed, 1 attempt, a short error) and does not stop the other reminders or the run (the notice for the failing customer is not stored, the rest of the run completed)',
    (select status || '|' || attempts from public.credit_reminders where order_id = v_o3 and kind = 'due_7') = 'failed|1' and (select last_error from public.credit_reminders where order_id = v_o3 and kind = 'due_7') like '%simulated delivery failure%'
    and not exists (select 1 from public.customer_notifications where customer_id = v_e and kind = 'due_7'));
  perform pg_temp.chk('F11 the failure is visible to Super Admins in the operations panel (failedReminders)', exists (select 1 from jsonb_array_elements(pg_temp.jv(pg_temp.q(sa_u, 'authenticated', 'select public.credit_operations() as v')) -> 'failedReminders') f where f ->> 'orderId' = v_o3));
  drop trigger trg_t25_fail on public.customer_notifications;
  perform pg_temp.q(null, 'service_role', 'select public.credit_daily_run() as v'); perform pg_temp.q(null, 'service_role', 'select public.credit_daily_run() as v');
  perform pg_temp.chk('F12 the next run retries it: delivered (status sent, 2 attempts) exactly once, the customer has one notice',
    (select status || '|' || attempts from public.credit_reminders where order_id = v_o3 and kind = 'due_7') = 'sent|2' and (select count(*) from public.customer_notifications where customer_id = v_e and kind = 'due_7') = 1);
  perform pg_temp.chk('F13 a customer reads only their own notices: E has theirs, A has none of D''s or E''s', jsonb_array_length(pg_temp.jv(pg_temp.q(ce, 'authenticated', 'select public.my_notifications() as v'))) >= 1
    and not exists (select 1 from jsonb_array_elements(pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.my_notifications() as v'))) n where n ->> 'orderId' in (v_order, v_o3)));
  perform pg_temp.q(ce, 'authenticated', format('select public.customer_mark_notification_read(%L) as v', (select id from public.customer_notifications where customer_id = v_e limit 1)));
  perform pg_temp.q(ca, 'authenticated', format('select public.customer_mark_notification_read(%L) as v', (select id from public.customer_notifications where customer_id = v_dd limit 1)));
  perform pg_temp.chk('F14 a customer can mark their own notice read; another customer''s attempt changes nothing', (select read_at is not null from public.customer_notifications where customer_id = v_e limit 1) and (select read_at is null from public.customer_notifications where customer_id = v_dd limit 1));

  -- ---------------------------------------------------------------- G. authorized due-date extensions
  select o.id into v_o2 from public.orders o join public.customer_credit_orders c on c.order_id = o.id where o.customer_id = v_e and o.status <> 'cancelled' limit 1;
  perform pg_temp.chk('G1 an extension needs a Super Admin, a reason of 10+ characters, a later date, and an unpaid invoice that has not defaulted',
    pg_temp.denied(pg_temp.q(mgr_u, 'authenticated', format('select public.extend_credit_due_date(%L, %L, ''A manager may not extend'') as v', v_o2, v_today + 20)))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.extend_credit_due_date(%L, %L, ''short'') as v', v_o2, v_today + 20)))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.extend_credit_due_date(%L, %L, ''Date is not later than now'') as v', v_o2, v_today)))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.extend_credit_due_date(%L, %L, ''This invoice is already defaulted'') as v', v_order, v_today + 20))));
  t := pg_temp.q(sa_u, 'authenticated', format('select public.extend_credit_due_date(%L, %L, ''Customer travelling; agreed with the owner'') as v', v_o2, v_today + 20));
  perform pg_temp.chk('G2 an approved extension is recorded with the previous and new date, who authorized it, why and when; the audit log and credit history show it',
    not pg_temp.err(t) and exists (select 1 from public.credit_due_extensions where order_id = v_o2 and previous_due = v_today + 3 and new_due = v_today + 20 and authorized_by <> '' and char_length(reason) >= 10)
    and exists (select 1 from public.customer_credit_events where customer_id = v_e and kind = 'due_date_extended') and exists (select 1 from public.system_logs where metadata ->> 'event' = 'credit_due_extended' and metadata ->> 'orderId' = v_o2), t);
  j := pg_temp.jv(pg_temp.q(ce, 'authenticated', 'select public.my_finance() as v')) -> 'invoices' -> 0;
  perform pg_temp.chk('G3 the customer sees issue date, the ORIGINAL due date, the current due date and the extension; the original is never overwritten',
    (j ->> 'issueDate') = v_today::text and (j ->> 'originalDueDate') = (v_today + 3)::text and (j ->> 'dueDate') = (v_today + 20)::text and jsonb_array_length(j -> 'extensions') = 1
    and (select due_date from public.customer_credit_orders where order_id = v_o2) = v_today + 3, j::text);
  perform pg_temp.set_due(v_o2, v_today - 5);
  perform pg_temp.chk('G4 the default clock follows the extended date: the original date has passed but the invoice is not overdue and no default is recorded',
    (pg_temp.cs(ce) -> 'default' ->> 'inDefault') = 'false' and not exists (select 1 from public.customer_credit_defaults where order_id = v_o2));
  perform pg_temp.chk('G5 history shows both dates and the extension to staff', (select (o ->> 'originalDueDate') || '|' || (o ->> 'dueDate') || '|' || jsonb_array_length(o -> 'extensions') from jsonb_array_elements(pg_temp.jv(pg_temp.q(sa_u, 'authenticated', format('select public.credit_history(%L) as v', v_e))) -> 'orders') o where o ->> 'orderId' = v_o2) = (v_today - 5)::text || '|' || (v_today + 20)::text || '|1');

  -- ---------------------------------------------------------------- H. disputes
  perform pg_temp.chk('H1 a customer cannot open a dispute on someone else''s invoice, with a short reason, or for more than the invoice total',
    pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.customer_open_credit_dispute(%L, ''This is not my invoice at all'') as v', v_o2)))
    and pg_temp.err(pg_temp.q(ce, 'authenticated', format('select public.customer_open_credit_dispute(%L, ''short'') as v', v_o2))) and pg_temp.err(pg_temp.q(ce, 'authenticated', format('select public.customer_open_credit_dispute(%L, ''The amount looks wrong to me'', 9999) as v', v_o2))));
  t := pg_temp.q(ce, 'authenticated', format('select public.customer_open_credit_dispute(%L, ''The invoice shows two balls I never received'', 10) as v', v_o2)); v_id := (pg_temp.jv(t) #>> '{}')::uuid;
  perform pg_temp.chk('H2 the customer opens a dispute on their own invoice (open, amount noted); staff are notified, the history and audit log record it', not pg_temp.err(t) and (select status from public.credit_disputes where id = v_id) = 'open'
    and exists (select 1 from public.customer_credit_events where customer_id = v_e and kind = 'dispute_opened') and exists (select 1 from public.notifications where user_id = 'u-t25-sa' and title = 'Credit invoice disputed'), t);
  perform pg_temp.chk('H3 only one unresolved dispute per invoice', pg_temp.err(pg_temp.q(ce, 'authenticated', format('select public.customer_open_credit_dispute(%L, ''Opening it a second time on purpose'') as v', v_o2))));
  j := pg_temp.cs(ce);
  perform pg_temp.chk('H4 an open dispute blocks NEW credit orders (an account restriction) with the standing message; it does not erase or pause anything else', (j ->> 'canBuyOnCredit') = 'false' and (j -> 'eligibility' -> 'standingReasons' ->> 0) like '%billing dispute is open%' and pg_temp.denied(pg_temp.place(ce, 1, pg_temp.key(61))), j::text);
  perform pg_temp.chk('H5 a customer cannot change the status of their dispute or read staff notes: no update path, no table access, no staff notes in the customer''s data',
    pg_temp.err(pg_temp.q(ce, 'authenticated', format('update public.credit_disputes set status = ''resolved_billing_error'' where id = %L returning 1 as v', v_id)))
    and pg_temp.denied(pg_temp.q(ce, 'authenticated', format('select public.resolve_credit_dispute(%L, ''billing_error'', ''I resolve my own dispute'') as v', v_id)))
    and pg_temp.q(ce, 'authenticated', 'select public.my_finance() as v') !~* 'staffNotes|staff_notes|assignedTo');
  perform pg_temp.q(sa_u, 'authenticated', format('select public.update_credit_dispute(%L, ''T25 Super Admin'', ''Checked the delivery note; reviewing the lines'') as v', v_id));
  perform pg_temp.chk('H6 staff investigate: status investigating, an assignee and a private note; the customer-visible invoice shows the status only', (select status || '|' || assigned_to from public.credit_disputes where id = v_id) = 'investigating|T25 Super Admin'
    and (pg_temp.jv(pg_temp.q(ce, 'authenticated', 'select public.my_finance() as v')) -> 'invoices' -> 0 -> 'dispute' ->> 'status') = 'investigating');
  perform pg_temp.set_ext(v_o2, v_today - 1); perform pg_temp.cs(ce);
  perform pg_temp.chk('H7 a dispute does not stop the invoice from defaulting: the (extended) due date passes while the dispute is open and the default is recorded; nothing is removed because a dispute exists', exists (select 1 from public.customer_credit_defaults where order_id = v_o2 and voided_at is null and defaulted_on = v_today)
    and (select status from public.credit_disputes where id = v_id) = 'investigating');
  select id into v_d2 from public.customer_credit_defaults where order_id = v_o2;
  perform pg_temp.chk('H8 a default cannot be voided without a dispute resolved as a billing error on that invoice: not while open, not with the wrong dispute',
    pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.void_credit_default(%L, %L, ''Billing error confirmed by staff'') as v', v_d2, v_id))));
  perform pg_temp.q(sa_u, 'authenticated', format('select public.resolve_credit_dispute(%L, ''billing_error'', ''Two lines were invoiced twice; corrected the invoice and agreed to void the default'') as v', v_id));
  perform pg_temp.chk('H9 resolved as a billing error: the dispute is closed, the customer gets a notice with the resolution, the audit log has it - and the default is STILL on record (resolution alone erases nothing)',
    (select status from public.credit_disputes where id = v_id) = 'resolved_billing_error' and exists (select 1 from public.customer_notifications where customer_id = v_e and kind = 'dispute_resolved')
    and exists (select 1 from public.customer_credit_defaults where order_id = v_o2 and voided_at is null) and exists (select 1 from public.system_logs where metadata ->> 'event' = 'credit_dispute_resolved' and metadata ->> 'disputeId' = v_id::text));
  perform pg_temp.chk('H10 only a Super Admin may void: a Manager, a customer or anonymous cannot', pg_temp.denied(pg_temp.q(mgr_u, 'authenticated', format('select public.void_credit_default(%L, %L, ''Manager voiding a default'') as v', v_d2, v_id)))
    and pg_temp.denied(pg_temp.q(ce, 'authenticated', format('select public.void_credit_default(%L, %L, ''Customer voiding a default'') as v', v_d2, v_id))));
  t := pg_temp.q(sa_u, 'authenticated', format('select public.void_credit_default(%L, %L, ''Billing error confirmed through the resolved dispute (T25)'') as v', v_d2, v_id));
  perform pg_temp.chk('H11 the documented correction: the default is VOIDED (kept, with who, why and which dispute), never deleted; the event history and a WARNING audit line record it',
    not pg_temp.err(t) and exists (select 1 from public.customer_credit_defaults where order_id = v_o2 and voided_at is not null and void_dispute_id = v_id and void_reason like 'Billing error%') and exists (select 1 from public.customer_credit_events where customer_id = v_e and kind = 'default_voided')
    and exists (select 1 from public.system_logs where metadata ->> 'event' = 'credit_default_voided' and severity = 'WARNING'), t);
  perform pg_temp.chk('H12 voiding does not silently restore credit: the account is still revoked until a Super Admin approves it again, and a second void is refused',
    (select status from public.customer_credit_accounts where customer_id = v_e) = 'revoked' and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.void_credit_default(%L, %L, ''Voiding it a second time'') as v', v_d2, v_id))));

  j := pg_temp.cs(ce);
  perform pg_temp.chk('H13 a VOIDED default no longer counts as a default (no default history, no requalification clock) while the record itself stays; the invoice itself is still unpaid and past due, so the live overdue rule keeps restricting credit until staff correct or settle the invoice',
    (j -> 'eligibility' -> 'defaultHistory' ->> 'count') = '0' and (j -> 'default' ->> 'everDefaulted') = 'false' and (j -> 'account' ->> 'overdue') = '20.00' and (j ->> 'canBuyOnCredit') = 'false'
    and exists (select 1 from public.customer_credit_defaults where order_id = v_o2 and voided_at is not null), j::text);

  -- ---------------------------------------------------------------- J. the optional per-customer ceiling on TOTAL outstanding (migration 24, kept)
  perform pg_temp.age_approval(v_h, 70);
  perform pg_temp.mkdone('ORD-T25-J1', v_h, 10); perform pg_temp.mkdone('ORD-T25-J2', v_h, 20); perform pg_temp.mkdone('ORD-T25-J3', v_h, 30);
  perform pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 40, 30, ''Eligible, initial limit agreed (T25 H)'') as v', v_h));
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 3, null, true, 30, ''T25 test: a ceiling of 25 per customer'', 60, 25, true) as v');
  j := pg_temp.cs(ch);
  perform pg_temp.chk('J1 a per-customer ceiling of $25 caps the available credit below the $40 limit (available $25)', (j ->> 'canBuyOnCredit') = 'true' and (j -> 'account' ->> 'available') = '25.00' and (j -> 'account' ->> 'creditLimit') = '40.00', j::text);
  t := pg_temp.place(ch, 3, pg_temp.key(80));
  perform pg_temp.chk('J2 an order of $30 is refused although the limit is $40 (the ceiling is $25); nothing is created', pg_temp.err(t) and pg_temp.msg(t) like '%above your available credit ($25.00)%' and (select count(*) from public.orders where customer_id = v_h and payment_terms = 'credit') = 0, t);
  t := pg_temp.place(ch, 2, pg_temp.key(81));
  perform pg_temp.chk('J3 an order of $20 is accepted; $5 remain under the ceiling', not pg_temp.err(t) and (pg_temp.cs(ch) -> 'account' ->> 'available') = '5.00', t);
  perform pg_temp.mkorder('ORD-T25-JX', v_h, 'pending', v_today, 10, false);
  j := pg_temp.cs(ch);
  perform pg_temp.chk('J4 the ceiling counts ALL the customer''s outstanding balances, not only credit invoices: an unpaid $10 staff order takes the total to $30 >= $25, so credit pauses with the ceiling reason and the server refuses',
    (j ->> 'canBuyOnCredit') = 'false' and (j -> 'eligibility' -> 'standingReasons' ->> 0) like '%reached the maximum ($25.00)%' and pg_temp.denied(pg_temp.place(ch, 1, pg_temp.key(82))), j::text);
  perform pg_temp.q(sa_u, 'authenticated', format('select public.record_payment(%L, 10, ''Cash'', null, ''JX'', ''pay the staff order'') as v', 'ORD-T25-JX'));
  perform pg_temp.chk('J5 paying that order brings the total back to $20: credit reopens with $5 available', (pg_temp.cs(ch) ->> 'canBuyOnCredit') = 'true' and (pg_temp.cs(ch) -> 'account' ->> 'available') = '5.00');
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 3, null, true, 30, ''T25 test: no ceiling'', 60, null, true) as v');
  perform pg_temp.chk('J6 clearing the ceiling returns to the personal limit only ($40 minus $20 owed = $20 available)', (pg_temp.cs(ch) -> 'account' ->> 'available') = '20.00');

  -- an invoice paid one day AFTER its due date, with nobody having looked at the account in between, is still a default (no grace period; the late payment is the evidence)
  select o.id into v_o2 from public.orders o where o.customer_id = v_h and o.payment_terms = 'credit' and o.status <> 'cancelled' and o.outstanding_balance > 0 limit 1;
  perform pg_temp.set_due(v_o2, v_today - 3);
  perform pg_temp.q(sa_u, 'authenticated', format('select public.record_payment(%L, %s, ''Cash'', null, ''LATE'', ''paid late'') as v', v_o2, (select outstanding_balance from public.orders where id = v_o2)));
  perform pg_temp.chk('J7 before anyone looks, no default is recorded yet (the late payment is only a payment)', not exists (select 1 from public.customer_credit_defaults where order_id = v_o2));
  j := pg_temp.cs(ch);
  perform pg_temp.chk('J8 the first look records it as a default although the invoice is now fully paid: defaulted on the first overdue day, the amount that was unpaid on the due date, already settled, the account revoked and credit off',
    exists (select 1 from public.customer_credit_defaults where order_id = v_o2 and defaulted_on = v_today - 2 and due_date = v_today - 3 and amount_at_default = 20 and settled_at is not null)
    and (select status from public.customer_credit_accounts where customer_id = v_h) = 'revoked' and (j ->> 'canBuyOnCredit') = 'false' and (j -> 'default' ->> 'everDefaulted') = 'true', j::text);

  -- ---------------------------------------------------------------- K. overrides (only when the policy allows them), suspension, and the master switch
  perform pg_temp.chk('K1 with overrides NOT enabled (the approved proposal) an unqualified customer cannot be authorized, with or without an override reason',
    pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 30, 30, ''Wholesale partner (T25 I)'', ''Owner approved the exception on a call'') as v', v_i)))
    and pg_temp.msg(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 30, 30, ''Wholesale partner (T25 I)'', ''Owner approved the exception on a call'') as v', v_i))) like '%Requirement overrides are not enabled%'
    and not exists (select 1 from public.customer_credit_accounts where customer_id = v_i));
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy_rules(90, 40, 100, 3, true, ''T25 test: allow requirement overrides'') as v');
  perform pg_temp.chk('K2 once the policy allows overrides, one needs a recorded reason of 10+ characters, and only a Super Admin can make it',
    pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 30, 30, ''Wholesale partner (T25 I)'') as v', v_i)))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 30, 30, ''Wholesale partner (T25 I)'', ''too short'') as v', v_i)))
    and pg_temp.denied(pg_temp.q(mgr_u, 'authenticated', format('select public.set_customer_credit(%L, 30, 30, ''Wholesale partner (T25 I)'', ''Manager may not override'') as v', v_i))));
  t := pg_temp.q(sa_u, 'authenticated', format('select public.set_customer_credit(%L, 30, 30, ''Wholesale partner (T25 I)'', ''Owner approved the exception on a call'') as v', v_i));
  perform pg_temp.chk('K3 with the recorded override I is authorized ($30): flagged override_used, and the audit line keeps the reason and the unmet requirements', not pg_temp.err(t) and (select override_used from public.customer_credit_accounts where customer_id = v_i)
    and exists (select 1 from public.system_logs where metadata ->> 'event' = 'customer_credit_set' and target_id = v_i and metadata ->> 'overrideReason' = 'Owner approved the exception on a call' and jsonb_array_length(metadata -> 'eligibility' -> 'reasons') > 0), t);
  j := pg_temp.cs(ci);
  perform pg_temp.chk('K4 an authorized override customer CAN buy on credit within the limit (and not beyond it)', (j ->> 'canBuyOnCredit') = 'true' and (j -> 'account' ->> 'override') = 'true' and (j -> 'account' ->> 'available') = '30.00'
    and not pg_temp.err(pg_temp.place(ci, 2, pg_temp.key(90))) and pg_temp.err(pg_temp.place(ci, 2, pg_temp.key(91))), j::text);
  perform pg_temp.mkorder('ORD-T25-IU', v_i, 'delivered', v_today, 10, false);
  j := pg_temp.cs(ci);
  perform pg_temp.chk('K5 an override never covers account standing: a delivered order with an unpaid balance blocks the override customer, and the server refuses', (j ->> 'canBuyOnCredit') = 'false' and (j -> 'eligibility' -> 'standingReasons' ->> 0) like '%unpaid balance%' and pg_temp.denied(pg_temp.place(ci, 1, pg_temp.key(92))), j::text);
  perform pg_temp.q(sa_u, 'authenticated', format('select public.record_payment(%L, 10, ''Cash'', null, ''IU'', ''pay it'') as v', 'ORD-T25-IU'));
  perform pg_temp.chk('K6 paying it lifts that restriction for a customer who never defaulted ($10 of $30 left)', (pg_temp.cs(ci) ->> 'canBuyOnCredit') = 'true' and (pg_temp.cs(ci) -> 'account' ->> 'available') = '10.00');
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(false, 3, null, true, 30, ''T25 test: credit switched off'', 60, null, true) as v');
  perform pg_temp.chk('K7 switching the whole policy OFF stops every credit purchase, including an authorized override account and an ordinary authorized account (A)', (pg_temp.cs(ci) ->> 'canBuyOnCredit') = 'false' and (pg_temp.cs(ci) ->> 'message') = 'Credit purchasing is not currently available.'
    and pg_temp.denied(pg_temp.place(ci, 1, pg_temp.key(93))) and (pg_temp.cs(ca) ->> 'canBuyOnCredit') = 'false');
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy(true, 3, null, true, 30, ''T25 test: credit back on'', 60, null, true) as v');
  perform pg_temp.q(sa_u, 'authenticated', format('select public.suspend_customer_credit(%L, ''T25 paused for review'') as v', v_i));
  perform pg_temp.chk('K8 a Super Admin can suspend credit (audited): the customer is stopped at once with the paused message; suspension is not a default and records none',
    (select status from public.customer_credit_accounts where customer_id = v_i) = 'suspended' and (pg_temp.cs(ci) ->> 'canBuyOnCredit') = 'false' and (pg_temp.cs(ci) ->> 'message') like '%paused%' and pg_temp.denied(pg_temp.place(ci, 1, pg_temp.key(94)))
    and exists (select 1 from public.system_logs where metadata ->> 'event' = 'customer_credit_suspended' and target_id = v_i) and not exists (select 1 from public.customer_credit_defaults where customer_id = v_i));
  perform pg_temp.chk('K9 only a Super Admin can suspend; a revoked account (after a default) cannot be "suspended" and a manager cannot suspend',
    pg_temp.denied(pg_temp.q(mgr_u, 'authenticated', format('select public.suspend_customer_credit(%L, ''Manager suspending'') as v', v_i)))
    and pg_temp.err(pg_temp.q(sa_u, 'authenticated', format('select public.suspend_customer_credit(%L, ''Suspend a revoked account'') as v', v_dd))));
  perform pg_temp.q(sa_u, 'authenticated', 'select public.set_credit_policy_rules(90, 40, 100, 3, false, ''T25 test: overrides off again'') as v');

  -- ---------------------------------------------------------------- I. financial integrity, isolation and exposure
  perform pg_temp.chk('I0 with rows PRESENT in all six new tables, customers and anonymous still read NONE of them (not their own rows either) and cannot write',
    (select count(*) from public.customer_credit_defaults) > 0 and (select count(*) from public.customer_credit_events) > 0 and (select count(*) from public.credit_due_extensions) > 0
    and (select count(*) from public.credit_disputes) > 0 and (select count(*) from public.credit_reminders) > 0 and (select count(*) from public.customer_notifications) > 0
    and (select bool_and(pg_temp.none(pg_temp.q(u, r, 'select 1 as v from public.' || tb))) from (values (ce, 'authenticated'), (cc, 'authenticated'), (null::uuid, 'anon')) c(u, r),
          (values ('customer_credit_defaults'), ('customer_credit_events'), ('credit_due_extensions'), ('credit_disputes'), ('credit_reminders'), ('customer_notifications')) x(tb))
    and pg_temp.err(pg_temp.q(cc, 'authenticated', 'insert into public.credit_disputes (customer_id, order_id, reason) values (''x'', ''x'', ''a long enough reason'') returning 1 as v'))
    and pg_temp.err(pg_temp.q(cc, 'authenticated', 'update public.customer_notifications set read_at = now() returning 1 as v')));
  perform pg_temp.chk('I1 every credit order of this suite is a normal order: total = sum of lines, paid + balance = total, no negative values',
    (select count(*) from public.orders o join public.customer_credit_orders cc on cc.order_id = o.id where o.total <> (select sum(line_revenue) from public.order_items where order_id = o.id) or o.amount_paid + o.outstanding_balance <> o.total or o.outstanding_balance < 0) = 0);
  perform pg_temp.chk('I2 every credit order has its order_created and credit_order_placed audit lines and a history event', (select count(*) from public.customer_credit_orders cc where cc.customer_id in (select customer_id from public.customer_accounts where email like 't25-%@example.test') and (not exists (select 1 from public.system_logs l where l.target_id = cc.order_id and l.metadata ->> 'event' = 'order_created')
      or not exists (select 1 from public.system_logs l where l.target_id = cc.order_id and l.metadata ->> 'event' = 'credit_order_placed') or not exists (select 1 from public.customer_credit_events e where e.metadata ->> 'orderId' = cc.order_id and e.kind = 'credit_order_placed'))) = 0);   -- only this suite's own orders: credit orders that predate migration 25 have no migration-25 history event by design
  j := pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.my_finance() as v'));
  perform pg_temp.chk('I3 a customer''s statement reconciles to the authoritative orders (closing balance = sum of outstanding balances)', (j -> 'statement' ->> 'closingBalance')::numeric = (select coalesce(sum(outstanding_balance), 0) from public.orders where customer_id = v_a and status <> 'cancelled'));
  perform pg_temp.chk('I4 customers see only their own invoices, notices and disputes (A sees none of E''s or D''s)',
    not exists (select 1 from jsonb_array_elements(pg_temp.jv(pg_temp.q(ca, 'authenticated', 'select public.my_finance() as v')) -> 'invoices') i where i ->> 'orderId' in (v_order, v_o2, v_o3)) and pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.customer_open_credit_dispute(%L, ''Trying to dispute E''''s invoice'') as v', v_o3))));
  perform pg_temp.chk('I5 no customer response carries a field named cost, margin, profit, commission, officer or supplier (key names scanned in the JSON text)',
    (select bool_and(body !~* '"[a-z_]*(cost|margin|profit|commission|supplier|officer)[a-z_]*"[ ]*:') from (values (pg_temp.q(ca, 'authenticated', 'select public.my_finance() as v')), (pg_temp.q(ca, 'authenticated', 'select public.customer_credit_status() as v')),
        (pg_temp.q(ca, 'authenticated', 'select public.my_notifications() as v')), (pg_temp.q(cc, 'authenticated', 'select public.my_finance() as v'))) x(body)));
  perform pg_temp.chk('I6 create_order and record_payment still refuse customers (the credit channel does not weaken them)',
    pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.create_order(%L::jsonb) as v', jsonb_build_object('customerId', v_a, 'items', jsonb_build_array(jsonb_build_object('productId', 'p25-plain', 'quantity', 1)))::text)))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.record_payment(%L, 1, ''Cash'') as v', v_o2))));
  perform pg_temp.chk('I7 a customer cannot start, finish or read another customer''s credit state through any parameter: the credit functions take no customer id and the staff ones refuse customers',
    pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.credit_history(%L) as v', v_c))) and pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.set_customer_credit(%L, 40, 30, ''self'') as v', v_a))));
  perform pg_temp.chk('I8 staff overview, history and operations answer a Super Admin completely (defaults, disputes, reminders, events, the cap)',
    jsonb_array_length(pg_temp.jv(pg_temp.q(sa_u, 'authenticated', 'select public.credit_overview() as v'))) >= 4
    and (pg_temp.jv(pg_temp.q(sa_u, 'authenticated', format('select public.credit_history(%L) as v', v_c))) ? 'defaults') and jsonb_array_length(pg_temp.jv(pg_temp.q(sa_u, 'authenticated', format('select public.credit_history(%L) as v', v_c))) -> 'defaults') >= 1
    and (pg_temp.jv(pg_temp.q(sa_u, 'authenticated', 'select public.credit_operations() as v')) -> 'companyCap' ->> 'cap') is not null
    and jsonb_array_length(pg_temp.jv(pg_temp.q(sa_u, 'authenticated', 'select public.list_credit_disputes() as v'))) >= 1);
end
$t$;

select case when ok then 'PASS' else 'FAIL' end || ' ' || lpad(n::text, 3) || ' ' || name || case when ok then '' else '   [' || detail || ']' end from r25 order by n;
select 'TOTAL: ' || count(*) || ' checks, ' || count(*) filter (where not ok) || ' failure(s)' from r25;

rollback;
