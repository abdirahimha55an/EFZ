-- =============================================================================
-- 27 - CHECKS for the price policy (migration 27, on top of 21 .. 26). Run with psql AFTER migration 27:
--   psql -X -v ON_ERROR_STOP=1 -d <db> -f supabase/checks/27_price_policy_checks.sql
-- One transaction, ROLLED BACK at the end (nothing persists). Real Postgres roles with a simulated Supabase JWT. Simultaneous checkout / agreement changes:
-- supabase/checks/27_price_policy_concurrency.mjs (real parallel sessions).
-- =============================================================================
\set ON_ERROR_STOP on
\pset footer off
\pset tuples_only on

begin;

create temp table r27 (n serial, ok boolean, name text, detail text);

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
begin insert into r27 (ok, name, detail) values (coalesce(p_ok, false), p_name, left(coalesce(p_detail, ''), 500)); end $f$;
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
create function pg_temp.co(p_user uuid, p_cust text, p_items jsonb, p_extra jsonb default '{}'::jsonb) returns text language sql as $f$
  select pg_temp.q(p_user, 'authenticated', format('select public.create_order(%L::jsonb) as v', (jsonb_build_object('customerId', p_cust, 'items', p_items) || p_extra)::text)) $f$;
create function pg_temp.line(p_order text) returns text language sql as $f$
  select string_agg(i.standard_unit_price || ':' || i.actual_unit_price || ':' || i.quantity, ',' order by i.id) from public.order_items i where i.order_id = p_order $f$;
create function pg_temp.notes(p_user uuid) returns jsonb language sql as $f$
  select coalesce(pg_temp.q(p_user, 'authenticated', 'select public.my_notifications() as v')::jsonb -> 0 -> 'v', '[]'::jsonb) $f$;
create function pg_temp.price_notes(p_user uuid) returns integer language sql as $f$
  select count(*)::integer from jsonb_array_elements(pg_temp.notes(p_user)) e where e ->> 'kind' = 'price_agreement' $f$;

do $t$
declare
  sa_u  uuid := 'a7000000-0000-4000-8000-000000000001';   -- Super Admin
  mgr_u uuid := 'a7000000-0000-4000-8000-000000000002';   -- Manager: manages prices and creates orders; not elevated
  off_u uuid := 'a7000000-0000-4000-8000-000000000003';   -- Marketing Officer with create_orders (no pricing rights)
  ca uuid := 'c7000000-0000-4000-8000-00000000000a';      -- customer A (app account)
  cb uuid := 'c7000000-0000-4000-8000-00000000000b';      -- customer B (app account)
  dA1 uuid := 'd2700000-0000-4000-8000-000000000001'; dA2 uuid := 'd2700000-0000-4000-8000-000000000002';
  acc record; t text; j jsonb; v_a text; v_b text; v_today date := public.efz_today(); v_ag uuid; v_ag2 uuid; v_ag3 uuid; v_id uuid; v_o text; v_o2 text; v_n int; v_rev0 numeric; v_rev1 numeric; v_tot0 numeric; v_tot1 numeric; v_res jsonb; v_succ uuid; v_cont uuid;
begin
  -- ---------------------------------------------------------------- fixtures
  alter table public.orders disable trigger user;
  update public.orders set status = 'cancelled' where status <> 'cancelled';
  alter table public.orders enable trigger user;
  insert into public.profiles (id, name, email, role, status) values
    ('u-t27-sa', 'T27 Super Admin', 't27-sa@example.test', 'Super Admin', 'active'), ('u-t27-mgr', 'T27 Manager', 't27-mgr@example.test', 'Manager', 'active'),
    ('u-t27-off', 'T27 Officer', 't27-off@example.test', 'Marketing Officer', 'active');
  insert into public.user_permissions (user_id, permission_code) values ('u-t27-mgr', 'manage_customer_accounts'), ('u-t27-mgr', 'edit_products'), ('u-t27-mgr', 'view_all_customers'), ('u-t27-mgr', 'view_orders'), ('u-t27-mgr', 'create_orders'), ('u-t27-mgr', 'edit_orders'),
    ('u-t27-off', 'create_orders'), ('u-t27-off', 'view_customers'), ('u-t27-off', 'view_all_customers');
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
    (sa_u, 'authenticated', 'authenticated', 't27-sa@example.test', now(), '{"provider":"email"}', '{}', now(), now()), (mgr_u, 'authenticated', 'authenticated', 't27-mgr@example.test', now(), '{"provider":"email"}', '{}', now(), now()),
    (off_u, 'authenticated', 'authenticated', 't27-off@example.test', now(), '{"provider":"email"}', '{}', now(), now());
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  select u, 'authenticated', 'authenticated', e, now(), '{"provider":"email","efz_kind":"customer"}', '{}', now(), now() from (values (ca, 't27-a@example.test'), (cb, 't27-b@example.test')) v(u, e);
  insert into public.products (id, name, selling_price, cost_price, stock, is_active) values
    ('p27-a', 'T27 Ball A', 10.00, 6.00, 1000000, true), ('p27-b', 'T27 Ball B', 20.00, 12.00, 1000000, true), ('p27-c', 'T27 Ball C', 8.00, 5.00, 1000000, true), ('p27-d', 'T27 Ball D', 15.00, 9.00, 1000000, true), ('p27-e', 'T27 Ball E', 12.00, 7.00, 1000000, true);
  insert into public.product_designs (id, product_id, name, sort_order, is_active) values (dA1, 'p27-a', 'Red', 1, true), (dA2, 'p27-a', 'Blue', 2, true);
  for acc in select * from (values (ca, 't27-a@example.test', 'T27 Buyer A', '069 827 0001'), (cb, 't27-b@example.test', 'T27 Buyer B', '069 827 0002')) v(u, e, n, ph) loop
    perform pg_temp.q(null, 'service_role', format('select public.register_customer_account(%L, %L, %L, %L, '''', null)', acc.u, acc.e, acc.n, acc.ph));
  end loop;
  for acc in select id from public.customer_accounts where email in ('t27-a@example.test', 't27-b@example.test') loop
    perform pg_temp.q(mgr_u, 'authenticated', format('select public.approve_customer_account(%L, null, true, false, ''Verified (T27)'')', acc.id));
  end loop;
  select customer_id into v_a from public.customer_accounts where email = 't27-a@example.test'; select customer_id into v_b from public.customer_accounts where email = 't27-b@example.test';
  insert into public.customers (id, name, email, phone, notes, status) values ('cust-t27-s', 'T27 Staff-only Customer', 's@example.test', '069 827 0009', 'staff', 'active');

  -- ---------------------------------------------------------------- A. agreements without an end date
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p27-a'', null, 8.00, %L, null, ''Agreed with the owner in 2025 (T27)'') as v', v_a, v_today - 400)); v_ag := (pg_temp.jv(t) #>> '{}')::uuid;
  perform pg_temp.chk('A1 an agreement with no end date, started 400 days ago, is still in force: customer A pays 8.00 (list 10.00), marked "agreement"; customer B pays the list price',
    not pg_temp.err(t) and (pg_temp.catrow(ca, 'p27-a') ->> 'selling_price')::numeric = 8 and (pg_temp.catrow(ca, 'p27-a') ->> 'price_status') = 'agreement' and (pg_temp.catrow(cb, 'p27-a') ->> 'selling_price')::numeric = 10, t);
  perform pg_temp.chk('A2 it is still the agreed price 10 years from now (nothing expires it because it is old or has no end date)',
    (public._price_resolve(v_a, 'p27-a', null, v_today + 3650) ->> 'source') = 'agreement' and (public._price_resolve(v_a, 'p27-a', null, v_today + 3650) ->> 'price')::numeric = 8);
  v_res := public.price_daily_run();
  perform pg_temp.chk('A3 the daily run does not touch it: still active, still no end date, no notice sent, no alert about it',
    (select status || ':' || coalesce(effective_to::text, 'none') from public.customer_price_agreements where id = v_ag) = 'active:none' and (v_res ->> 'noticesSent')::int = 0 and pg_temp.price_notes(ca) = 0
    and (pg_temp.jv(pg_temp.q(mgr_u, 'authenticated', 'select public.price_agreement_alerts() as v')) ->> 'expiringSoon')::int = 0);

  -- ---------------------------------------------------------------- B. agreements with an explicit end date
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p27-b'', null, 17.00, %L, %L, ''Seasonal price until the end of the month (T27)'') as v', v_a, v_today - 5, v_today + 20)); v_ag2 := (pg_temp.jv(t) #>> '{}')::uuid;
  perform pg_temp.chk('B1 an agreement with an end date applies up to and including that date and then the list price: 17.00 today and on the last day, 20.00 the day after',
    (public._price_resolve(v_a, 'p27-b', null, v_today) ->> 'price')::numeric = 17 and (public._price_resolve(v_a, 'p27-b', null, v_today + 20) ->> 'price')::numeric = 17
    and (public._price_resolve(v_a, 'p27-b', null, v_today + 21) ->> 'source') = 'list' and (public._price_resolve(v_a, 'p27-b', null, v_today + 21) ->> 'price')::numeric = 20);
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.end_price_agreement(%L, %L, ''Customer asked to stop the open-ended price (T27)'') as v', v_ag, v_today + 40));
  perform pg_temp.chk('B2 staff can end an open-ended agreement on a chosen date; it then follows that date (8.00 until then, list price after); the end is audited',
    not pg_temp.err(t) and (public._price_resolve(v_a, 'p27-a', null, v_today + 40) ->> 'price')::numeric = 8 and (public._price_resolve(v_a, 'p27-a', null, v_today + 41) ->> 'source') = 'list'
    and exists (select 1 from public.price_agreement_events where agreement_id = v_ag and kind = 'ended' and details ->> 'newEnd' = (v_today + 40)::text), t);
  perform pg_temp.chk('B3 an end date can only be brought forward, never pushed later or removed (the agreement must be replaced instead)',
    pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.end_price_agreement(%L, %L, ''Trying to extend the end date (T27)'') as v', v_ag, v_today + 90)))
    and (select effective_to from public.customer_price_agreements where id = v_ag) = v_today + 40);

  -- ---------------------------------------------------------------- C. the customer is told before an agreement ends
  perform pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p27-c'', null, 6.80, %L, %L, ''Short promotion for B (T27)'') as v', v_b, v_today - 2, v_today + 10));
  v_n := pg_temp.price_notes(ca);
  perform pg_temp.chk('C1 an agreement ending in 20 days: customer A is told once (opening the catalogue is enough); repeated looks add nothing',
    (select count(*) from jsonb_array_elements(pg_temp.q(ca, 'authenticated', 'select * from public.customer_catalog()')::jsonb)) > 0 and pg_temp.price_notes(ca) = v_n + 1
    and (select count(*) from jsonb_array_elements(pg_temp.q(ca, 'authenticated', 'select * from public.customer_catalog()')::jsonb)) > 0 and pg_temp.price_notes(ca) = v_n + 1,
    pg_temp.notes(ca)::text);
  j := (select e from jsonb_array_elements(pg_temp.notes(ca)) e where e ->> 'kind' = 'price_agreement' and e ->> 'body' like '%T27 Ball B%' limit 1);
  perform pg_temp.chk('C2 the notice names the product, the agreed price, the end date and the list price that applies afterwards, and tells the customer to contact EFZ',
    j ->> 'title' = 'Your agreed price is ending soon' and j ->> 'body' like '%$17.00%' and j ->> 'body' like '%' || (v_today + 20)::text || '%' and j ->> 'body' like '%list price ($20.00)%' and j ->> 'body' like '%contact EFZ%', j::text);
  perform pg_temp.chk('C3 another customer (B, whose own agreement ends in 10 days) is not told about the agreement of A by A looking, and the notice carries no cost, margin or other private field',
    pg_temp.price_notes(cb) = 0 and pg_temp.banned(pg_temp.notes(ca)) is null, coalesce(pg_temp.banned(pg_temp.notes(ca)), ''));
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p27-c'', null, 6.50, %L, %L, ''Short promotion (T27)'') as v', v_a, v_today - 2, v_today + 5)); v_ag3 := (pg_temp.jv(t) #>> '{}')::uuid;
  v_res := public.price_daily_run();
  perform pg_temp.chk('C4 an agreement ending within 7 days gets the 7-day notice (one more for A) and the agreement of B ending in 10 days gets its own 30-day notice; the earlier 20-day agreement is not repeated; running the daily run again sends nothing',
    (v_res ->> 'noticesSent')::int = 2 and (select string_agg(g.effective_to - v_today || ':' || n.stage, ',' order by g.effective_to) from public.price_agreement_notices n join public.customer_price_agreements g on g.id = n.agreement_id where g.customer_id = v_a) = '5:expiry_7,20:expiry_30' and pg_temp.price_notes(cb) = 1 and pg_temp.price_notes(ca) = v_n + 2 and (public.price_daily_run() ->> 'noticesSent')::int = 0 and pg_temp.price_notes(ca) = v_n + 2, v_res::text);
  insert into public.customer_price_agreements (customer_id, product_id, design_id, unit_price, effective_from, effective_to, status, source, reason, created_by, verified_by, verified_at, below_cost_approved)
  select v_b, 'p27-d', null, 12.00, v_today - 30, v_today - 1, 'active', 'manual', 'Ended yesterday (fixture)', 'u-t27-mgr', 'u-t27-mgr', now(), false;
  v_res := public.price_daily_run();
  perform pg_temp.chk('C5 an agreement that ended yesterday gets one "has ended" notice stating that the list price applies now; the price really is the list price now',
    exists (select 1 from jsonb_array_elements(pg_temp.notes(cb)) e where e ->> 'title' = 'Your agreed price has ended' and e ->> 'body' like '%list price ($15.00) applies now%')
    and (pg_temp.catrow(cb, 'p27-d') ->> 'price_status') = 'list' and (pg_temp.catrow(cb, 'p27-d') ->> 'selling_price')::numeric = 15, pg_temp.notes(cb)::text);
  perform pg_temp.chk('C6 the daily run is for the service role only; customers, Officers and anonymous callers are refused; pricing admins use run_price_checks (a Manager may, an Officer may not)',
    pg_temp.denied(pg_temp.q(ca, 'authenticated', 'select public.price_daily_run() as v')) and pg_temp.denied(pg_temp.q(off_u, 'authenticated', 'select public.price_daily_run() as v')) and pg_temp.denied(pg_temp.q(null, 'anon', 'select public.price_daily_run() as v'))
    and not pg_temp.err(pg_temp.q(null, 'service_role', 'select public.price_daily_run() as v')) and not pg_temp.err(pg_temp.q(mgr_u, 'authenticated', 'select public.run_price_checks() as v'))
    and pg_temp.denied(pg_temp.q(off_u, 'authenticated', 'select public.run_price_checks() as v')) and pg_temp.denied(pg_temp.q(ca, 'authenticated', 'select public.run_price_checks() as v')));
  perform pg_temp.chk('C7 the record of sent notices is closed to every client role and cannot be changed or deleted even by the owner',
    pg_temp.none(pg_temp.q(ca, 'authenticated', 'select 1 as v from public.price_agreement_notices')) and pg_temp.none(pg_temp.q(null, 'service_role', 'select 1 as v from public.price_agreement_notices'))
    and (select count(*) from public.price_agreement_notices) >= 3
    and (select count(*) from (select 1 where false) x) = 0 and exists (select 1 from public.price_agreement_notices));
  begin delete from public.price_agreement_notices; perform pg_temp.chk('C7b notices cannot be deleted', false); exception when others then perform pg_temp.chk('C7b notices cannot be deleted', true); end;

  -- ---------------------------------------------------------------- D. changes are authorized and audited
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.replace_price_agreement(%L, 7.00, %L, null, ''Renegotiated after the Eid order (T27)'') as v', v_ag, v_today));
  perform pg_temp.chk('D1 a change records the previous price, the new price, the reason, the staff member and the time: the new agreement''s "created" event has previousPrice 8 and unitPrice 7; the old one''s "revoked" event shows its own price 8',
    not pg_temp.err(t) and exists (select 1 from public.price_agreement_events e where e.kind = 'created' and e.details ->> 'previousPrice' = '8.00' and e.details ->> 'unitPrice' = '7.00' and e.details ->> 'reason' like '%Eid%' and e.actor = 'T27 Manager' and e.at > now() - interval '1 minute')
    and exists (select 1 from public.price_agreement_events e where e.agreement_id = v_ag and e.kind = 'revoked' and e.details ->> 'agreementPrice' = '8.00' and e.details ->> 'reason' like '%Renegotiated%' and e.actor = 'T27 Manager'), t);
  perform pg_temp.chk('D2 the same facts are in the audit log (who, what, the prices) and in the customer history view for staff',
    exists (select 1 from public.system_logs l where l.metadata ->> 'event' = 'price_agreement_created' and l.metadata ->> 'previousPrice' = '8.00' and l.metadata ->> 'unitPrice' = '7.00' and l.username = 'T27 Manager')
    and (select count(*) from jsonb_array_elements(pg_temp.jv(pg_temp.q(mgr_u, 'authenticated', format('select public.price_agreement_history(%L) as v', v_a))))) >= 5);
  perform pg_temp.chk('D3 an Officer, a customer and anonymous callers cannot change an agreement (42501)',
    (select bool_and(pg_temp.denied(pg_temp.q(u, r, format('select public.replace_price_agreement(%L, 1, current_date, null, ''Trying to change a price (T27)'') as v', v_ag)))) from (values (off_u, 'authenticated'), (ca, 'authenticated'), (null::uuid, 'anon')) c(u, r)));

  -- a change that starts later: the current price stays in force until the day before (no drop to the list price in between)
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p27-e'', null, 11.00, %L, null, ''Established price (T27)'') as v', v_a, v_today - 3)); v_id := (pg_temp.jv(t) #>> '{}')::uuid;
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.replace_price_agreement(%L, 10.00, %L, null, ''Lower price from the start of next week (T27)'') as v', v_id, v_today + 3));
  perform pg_temp.chk('D4 a change starting in 3 days leaves 11.00 in force until then and 10.00 from the start date, with no day at the list price (12.00) in between; the old agreement stays active and is end-dated, the new one is active',
    not pg_temp.err(t) and (select string_agg((public._price_resolve(v_a, 'p27-e', null, v_today + d) ->> 'price') || ':' || (public._price_resolve(v_a, 'p27-e', null, v_today + d) ->> 'source'), ',' order by d) from generate_series(0, 5) d)
      = '11.00:agreement,11.00:agreement,11.00:agreement,10.00:agreement,10.00:agreement,10.00:agreement'
    and (select status || ':' || effective_to from public.customer_price_agreements where id = v_id) = 'active:' || (v_today + 2)
    and exists (select 1 from public.price_agreement_events where agreement_id = v_id and kind = 'ended' and details ->> 'newEnd' = (v_today + 2)::text and details ->> 'reason' like '%Lower price%'), t);
  -- ---------------------------------------------------------------- R. revoking a replacement that has not started continues the predecessor's price; N. no misleading notice
  v_res := public.price_daily_run();
  perform pg_temp.chk('N1 a replacement takes over seamlessly: the predecessor (ending in 2 days, successor starting in 3) gets NO "your price ends" notice and no notice row',
    (v_res ->> 'noticesSent')::int = 0 and not exists (select 1 from public.price_agreement_notices where agreement_id = v_id), v_res::text);
  select id into v_succ from public.customer_price_agreements where customer_id = v_a and product_id = 'p27-e' and unit_price = 10.00 and status = 'active';
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.revoke_price_agreement(%L, ''Scheduled change cancelled before it started (T27)'') as v', v_succ));
  perform pg_temp.chk('R1 revoking the scheduled change before it starts keeps the customer on the previous price: 11.00 on every day, never the list price (12.00); the predecessor stays active and ended, a continuation (same terms, open-ended as before) starts on the day the change would have started',
    not pg_temp.err(t)
    and (select string_agg((public._price_resolve(v_a, 'p27-e', null, v_today + d) ->> 'price') || ':' || (public._price_resolve(v_a, 'p27-e', null, v_today + d) ->> 'source'), ',' order by d) from generate_series(0, 6) d)
        = '11.00:agreement,11.00:agreement,11.00:agreement,11.00:agreement,11.00:agreement,11.00:agreement,11.00:agreement'
    and (select status from public.customer_price_agreements where id = v_id) = 'active' and (select status from public.customer_price_agreements where id = v_succ) = 'revoked'
    and (select count(*) from public.customer_price_agreements c where c.customer_id = v_a and c.product_id = 'p27-e' and c.status = 'active' and c.unit_price = 11.00 and c.effective_from = v_today + 3 and c.effective_to is null) = 1, t);
  perform pg_temp.chk('R2 the continuation is audited: a "created" event that names the agreement it continues and the reason; the revoked change keeps its own "revoked" event; nothing was deleted or rewritten',
    exists (select 1 from public.price_agreement_events e where e.kind = 'created' and e.details ->> 'continues' = v_id::text and e.details ->> 'reason' like '%scheduled change was revoked%' and e.actor = 'T27 Manager')
    and exists (select 1 from public.price_agreement_events e where e.agreement_id = v_succ and e.kind = 'revoked')
    and (select effective_to from public.customer_price_agreements where id = v_id) = v_today + 2);
  v_res := public.price_daily_run();
  perform pg_temp.chk('R3 still no "price ends" notice after the continuation exists (the predecessor is continued, not ended)', (v_res ->> 'noticesSent')::int = 0 and not exists (select 1 from public.price_agreement_notices where agreement_id = v_id));
  -- a predecessor that had its own end date: the continuation keeps that end date
  select id into v_ag from public.customer_price_agreements where customer_id = v_a and product_id = 'p27-b' and status = 'active' and unit_price = 17.00;
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.replace_price_agreement(%L, 15.00, %L, null, ''Lower price from next week (T27 end-dated predecessor)'') as v', v_ag, v_today + 4)); v_succ := (pg_temp.jv(t) #>> '{}')::uuid;
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.revoke_price_agreement(%L, ''Cancelled the scheduled change (T27)'') as v', v_succ));
  perform pg_temp.chk('R4 a predecessor that had an end date (in 20 days) is continued up to that same date: 17.00 on day 4 and on its original last day, the list price (20.00) after it',
    not pg_temp.err(t) and (public._price_resolve(v_a, 'p27-b', null, v_today + 3) ->> 'price')::numeric = 17 and (public._price_resolve(v_a, 'p27-b', null, v_today + 4) ->> 'price')::numeric = 17
    and (public._price_resolve(v_a, 'p27-b', null, v_today + 20) ->> 'price')::numeric = 17 and (public._price_resolve(v_a, 'p27-b', null, v_today + 21) ->> 'source') = 'list', t);
  -- a future agreement that replaces nothing has no predecessor
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p27-c'', null, 6.40, %L, null, ''Promotion for B from today (T27)'') as v', v_b, v_today + 11)); v_succ := (pg_temp.jv(t) #>> '{}')::uuid;
  select count(*) into v_n from public.customer_price_agreements where customer_id = v_b and product_id = 'p27-c';
  perform pg_temp.q(mgr_u, 'authenticated', format('select public.revoke_price_agreement(%L, ''Withdrawn again (T27)'') as v', v_succ));
  perform pg_temp.chk('R5 revoking a future agreement that REPLACES nothing creates no continuation (only a replacement has a predecessor to continue)',
    (select count(*) from public.customer_price_agreements where customer_id = v_b and product_id = 'p27-c') = v_n, v_n::text);
  -- the authorization of the revoke is unchanged
  perform pg_temp.chk('R6 an Officer or a customer still cannot revoke (42501)', pg_temp.denied(pg_temp.q(off_u, 'authenticated', format('select public.revoke_price_agreement(%L, ''Trying to revoke a price (T27)'') as v', v_id)))
    and pg_temp.denied(pg_temp.q(ca, 'authenticated', format('select public.revoke_price_agreement(%L, ''Trying to revoke a price (T27)'') as v', v_id))));

  -- ---------------------------------------------------------------- E. changes apply to the future only
  select coalesce((x ->> 'revenue_generated')::numeric, 0) into v_rev0 from jsonb_array_elements(pg_temp.q(sa_u, 'authenticated', 'select * from public.financial_summary')::jsonb) x limit 1;
  v_o := pg_temp.jv(pg_temp.co(mgr_u, v_a, jsonb_build_array(jsonb_build_object('productId', 'p27-c', 'quantity', 4)))) #>> '{}';
  select o.total into v_tot0 from public.orders o where o.id = v_o;
  perform pg_temp.chk('E0 (setup) a staff order for A for ball C with no price typed takes the 6.50 agreed price (list 8.00)', v_o is not null and pg_temp.line(v_o) = '8.00:6.50:4' and v_tot0 = 26, coalesce(v_o, '') || ' ' || coalesce(pg_temp.line(v_o), ''));
  perform pg_temp.q(mgr_u, 'authenticated', format('select public.revoke_price_agreement(%L, ''Promotion withdrawn after the order (T27)'') as v', v_ag3));
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p27-c'', null, 6.00, %L, null, ''New lower price from today (T27)'') as v', v_a, v_today));
  select o.total into v_tot1 from public.orders o where o.id = v_o;
  select coalesce((x ->> 'revenue_generated')::numeric, 0) into v_rev1 from jsonb_array_elements(pg_temp.q(sa_u, 'authenticated', 'select * from public.financial_summary')::jsonb) x limit 1;
  perform pg_temp.chk('E1 after the agreement was revoked and replaced, the confirmed order keeps its price and total (6.50 x 4 = 26.00), its resolution still points to the old agreement, and booked revenue only moved by that order',
    pg_temp.line(v_o) = '8.00:6.50:4' and v_tot1 = 26 and v_rev1 - v_rev0 = 26 and (select agreement_id from public.order_price_resolutions where order_id = v_o) = v_ag3
    and (public._price_resolve(v_a, 'p27-c', null, null) ->> 'price')::numeric = 6, v_rev0 || ' ' || v_rev1);
  v_o2 := pg_temp.jv(pg_temp.co(mgr_u, v_a, jsonb_build_array(jsonb_build_object('productId', 'p27-c', 'quantity', 1)))) #>> '{}';
  perform pg_temp.chk('E2 a new order gets the new price 6.00, the old one is untouched', pg_temp.line(v_o2) = '8.00:6.00:1' and pg_temp.line(v_o) = '8.00:6.50:4', pg_temp.line(v_o2));

  -- ---------------------------------------------------------------- F. staff orders use the same authoritative function
  v_o := pg_temp.jv(pg_temp.co(off_u, v_a, jsonb_build_array(jsonb_build_object('productId', 'p27-a', 'designName', 'Red', 'quantity', 2)))) #>> '{}';
  perform pg_temp.chk('F1 an Officer''s order with no price typed takes the agreed price (the open-ended 7.00 for ball A) and records which agreement produced it',
    v_o is not null and pg_temp.line(v_o) = '10.00:7.00:2' and (select source from public.order_price_resolutions where order_id = v_o) = 'agreement'
    and (select agreement_id from public.order_price_resolutions where order_id = v_o) in (select id from public.customer_price_agreements where customer_id = v_a and product_id = 'p27-a' and status = 'active'), coalesce(v_o, ''));
  v_o := pg_temp.jv(pg_temp.co(off_u, v_a, jsonb_build_array(jsonb_build_object('productId', 'p27-a', 'designName', 'Blue', 'quantity', 1, 'actualUnitPrice', 7.00)))) #>> '{}';
  perform pg_temp.chk('F2 typing exactly the agreed price needs no reason', v_o is not null and pg_temp.line(v_o) = '10.00:7.00:1', coalesce(v_o, ''));
  t := pg_temp.co(off_u, v_a, jsonb_build_array(jsonb_build_object('productId', 'p27-a', 'quantity', 1, 'actualUnitPrice', 9.00)));
  perform pg_temp.chk('F3 typing a different price for a customer with an agreement is refused without a priceOverrideReason (22023), and nothing is created',
    pg_temp.err(t) and pg_temp.code(t) = '22023' and pg_temp.msg(t) like '%priceOverrideReason%' and pg_temp.msg(t) like '%agreed price of 7.00%', t);
  t := pg_temp.co(off_u, v_a, jsonb_build_array(jsonb_build_object('productId', 'p27-a', 'quantity', 1, 'actualUnitPrice', 9.00)), jsonb_build_object('priceOverrideReason', 'Customer paid cash up front, owner agreed by phone'));
  v_o := pg_temp.jv(t) #>> '{}';
  perform pg_temp.chk('F4 with a documented reason the different price is allowed, recorded as a staff override (the agreement is shown in the record) and written to the audit log as a warning',
    not pg_temp.err(t) and pg_temp.line(v_o) = '10.00:9.00:1' and (select source from public.order_price_resolutions where order_id = v_o) = 'staff_override'
    and exists (select 1 from public.system_logs l where l.target_id = v_o and l.metadata ->> 'event' = 'agreed_price_overridden' and l.metadata ->> 'agreedPrice' = '7.00' and l.metadata ->> 'chargedPrice' = '9.00' and l.metadata ->> 'reason' like '%owner agreed%' and l.severity = 'WARNING'), t);
  t := pg_temp.co(off_u, v_a, jsonb_build_array(jsonb_build_object('productId', 'p27-a', 'quantity', 1, 'actualUnitPrice', 9.00)), jsonb_build_object('priceOverrideReason', 'short'));
  perform pg_temp.chk('F5 a too-short reason is refused', pg_temp.err(t) and pg_temp.code(t) = '22023', t);
  v_o := pg_temp.jv(pg_temp.co(off_u, 'cust-t27-s', jsonb_build_array(jsonb_build_object('productId', 'p27-a', 'quantity', 1, 'actualUnitPrice', 9.00)))) #>> '{}';
  v_o2 := pg_temp.jv(pg_temp.co(off_u, 'cust-t27-s', jsonb_build_array(jsonb_build_object('productId', 'p27-a', 'quantity', 1)))) #>> '{}';
  perform pg_temp.chk('F6 a customer with no agreement behaves exactly as before: a typed price is accepted as it always was (9.00), no price means the list price (10.00)',
    pg_temp.line(v_o) = '10.00:9.00:1' and pg_temp.line(v_o2) = '10.00:10.00:1' and (select source from public.order_price_resolutions where order_id = v_o) = 'list', coalesce(v_o, '') || coalesce(v_o2, ''));
  -- an agreement still waiting for verification blocks the line for the staff path too (it is never silently replaced by the list price)
  select id into v_id from public.customer_price_agreements limit 0;
  insert into public.customer_price_agreements (customer_id, product_id, design_id, unit_price, effective_from, effective_to, status, source, reason, created_by, below_cost_approved, candidate_evidence)
  select 'cust-t27-s', 'p27-e', null, 10.00, v_today - 60, null, 'pending_review', 'import', 'Imported candidate (fixture)', 'u-t27-mgr', false, '{"orders": 3}'::jsonb;
  t := pg_temp.co(off_u, 'cust-t27-s', jsonb_build_array(jsonb_build_object('productId', 'p27-e', 'quantity', 1)));
  perform pg_temp.chk('F7 an unverified (pending) agreement blocks the staff order line, with or without a typed price, and the message sends staff to Customer Prices; no order is created',
    pg_temp.err(t) and pg_temp.code(t) = '22023' and pg_temp.msg(t) like '%needs to be confirmed%'
    and pg_temp.err(pg_temp.co(off_u, 'cust-t27-s', jsonb_build_array(jsonb_build_object('productId', 'p27-e', 'quantity', 1, 'actualUnitPrice', 12))))
    and not exists (select 1 from public.order_items i join public.orders o on o.id = i.order_id where o.customer_id = 'cust-t27-s' and i.product_id = 'p27-e'), t);
  perform pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p27-a'', %L, 6.00, %L, null, ''Red agreed lower than Blue (T27)'') as v', v_a, dA1, v_today));
  v_o := pg_temp.jv(pg_temp.co(off_u, v_a, jsonb_build_array(jsonb_build_object('productId', 'p27-a', 'designName', 'Red', 'quantity', 1), jsonb_build_object('productId', 'p27-a', 'designId', dA2, 'quantity', 1)))) #>> '{}';
  perform pg_temp.chk('F6b a design-specific agreement is honoured for staff orders, by design name or design id: Red 6.00 (design agreement) and Blue 7.00 (the product agreement)',
    v_o is not null and (select string_agg(i.design_name || ':' || i.actual_unit_price, ',' order by i.design_name) from public.order_items i where i.order_id = v_o) = 'Blue:7.00,Red:6.00'
    and (select count(*) from public.order_price_resolutions r where r.order_id = v_o and r.design_id in (dA1, dA2)) = 2, coalesce(v_o, ''));
  -- below-cost agreement approved by a Super Admin
  t := pg_temp.q(sa_u, 'authenticated', format('select public.create_price_agreement(%L, ''p27-d'', null, 5.00, %L, null, ''Clearance price agreed with the owner (T27)'', ''Clearing old stock with the owner'') as v', v_a, v_today - 10));
  v_o := pg_temp.jv(pg_temp.co(off_u, v_a, jsonb_build_array(jsonb_build_object('productId', 'p27-d', 'quantity', 2)))) #>> '{}';
  perform pg_temp.chk('F8 an approved below-cost agreement is honoured by staff orders without another approval (the cost was 9.00; the sale is recorded as a below-cost sale citing the agreement); an Officer still cannot type a below-cost price for anyone else',
    not pg_temp.err(t) and v_o is not null and pg_temp.line(v_o) = '15.00:5.00:2'
    and exists (select 1 from public.below_cost_overrides b where b.order_id = v_o and b.reason like 'Approved price agreement%')
    and pg_temp.denied(pg_temp.co(off_u, 'cust-t27-s', jsonb_build_array(jsonb_build_object('productId', 'p27-d', 'quantity', 1, 'actualUnitPrice', 5)))), t || ' ' || coalesce(v_o, ''));
  -- dates
    v_o := pg_temp.jv(pg_temp.co(sa_u, v_a, jsonb_build_array(jsonb_build_object('productId', 'p27-d', 'quantity', 1)), jsonb_build_object('orderDate', (v_today - 20)::text))) #>> '{}';
  v_o2 := pg_temp.jv(pg_temp.co(sa_u, v_a, jsonb_build_array(jsonb_build_object('productId', 'p27-d', 'quantity', 1)), jsonb_build_object('orderDate', (v_today - 5)::text))) #>> '{}';
  perform pg_temp.chk('F9 a back-dated order is priced as of its own date: before the agreement began the list price (15.00), after it the agreed price (5.00)', pg_temp.line(v_o) = '15.00:15.00:1' and pg_temp.line(v_o2) = '15.00:5.00:1', coalesce(pg_temp.line(v_o), '') || ' ' || coalesce(pg_temp.line(v_o2), ''));
  -- parity with the app
  j := pg_temp.jv(pg_temp.preview(ca, jsonb_build_array(jsonb_build_object('productId', 'p27-a', 'designId', dA1, 'quantity', 1), jsonb_build_object('productId', 'p27-a', 'designId', dA2, 'quantity', 1), jsonb_build_object('productId', 'p27-c', 'quantity', 1))));
  v_o := pg_temp.jv(pg_temp.co(mgr_u, v_a, jsonb_build_array(jsonb_build_object('productId', 'p27-a', 'designId', dA1, 'quantity', 1), jsonb_build_object('productId', 'p27-a', 'designId', dA2, 'quantity', 1), jsonb_build_object('productId', 'p27-c', 'quantity', 1)))) #>> '{}';
  perform pg_temp.chk('F10 the app and a staff order get the identical price for the same customer, product and design (Red 6.00, Blue 7.00, ball C 6.00)',
    (select string_agg(l ->> 'unitPrice', ',' order by ord) from jsonb_array_elements(j -> 'lines') with ordinality l(l, ord)) = '6.00,7.00,6.00' and pg_temp.line(v_o) is not null
    and (select string_agg(i.actual_unit_price::text, ',' order by i.actual_unit_price desc, i.id) from public.order_items i where i.order_id = v_o) = '7.00,6.00,6.00', j::text || ' ' || coalesce(pg_temp.line(v_o), ''));
  -- terms wrapper
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.create_order_with_terms(%L::jsonb, ''paid_at_sale'') as v', jsonb_build_object('customerId', v_a, 'initialPayment', 12.00, 'items', jsonb_build_array(jsonb_build_object('productId', 'p27-c', 'quantity', 2)))::text));
  perform pg_temp.chk('F11 the paid-at-sale wrapper goes through the same pricing: 2 x 6.00 = 12.00 is exactly the total, so a payment of 12.00 settles it', not pg_temp.err(t), t);
  t := pg_temp.co(off_u, v_a, jsonb_build_array(jsonb_build_object('productId', 'p27-b', 'designId', dA1, 'quantity', 1)));
  perform pg_temp.chk('F12 a design that belongs to another product is refused', pg_temp.err(t) and pg_temp.code(t) = '22023', t);
  perform pg_temp.chk('F13 a customer still cannot create staff orders, and the old behaviour for unauthorised callers is unchanged (an Officer without create_orders is refused)',
    pg_temp.err(pg_temp.co(ca, v_a, jsonb_build_array(jsonb_build_object('productId', 'p27-a', 'quantity', 1)))) and pg_temp.denied(pg_temp.q(null, 'anon', 'select public.create_order(''{}''::jsonb) as v')));

  t := pg_temp.q(off_u, 'authenticated', format('select public.resolve_order_price(%L, ''p27-a'', ''Red'') as v', v_a));
  perform pg_temp.chk('F14 the Hub order form can ask what price an order will get (an Officer with create_orders): the agreed price with its source and the list price, no agreement id or evidence; a customer without an agreement gets the list price; a customer-app user and anonymous callers are refused',
    not pg_temp.err(t) and (pg_temp.jv(t) ->> 'source') = 'agreement' and (pg_temp.jv(t) ->> 'price')::numeric = 6 and (pg_temp.jv(t) ->> 'listPrice')::numeric = 10 and pg_temp.banned(pg_temp.jv(t)) is null and not (pg_temp.jv(t) ? 'agreementId')
    and (pg_temp.jv(pg_temp.q(off_u, 'authenticated', 'select public.resolve_order_price(''cust-t27-s'', ''p27-b'', null) as v')) ->> 'source') = 'list'
    and pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.resolve_order_price(%L, ''p27-a'', null) as v', v_a))) and pg_temp.denied(pg_temp.q(null, 'anon', 'select public.resolve_order_price(''x'', ''p27-a'', null) as v')), t);
  -- ---------------------------------------------------------------- I. request conversion goes through the same pricing rules; M4. no cost information for staff who cannot see cost
  insert into public.user_permissions (user_id, permission_code) values ('u-t27-mgr', 'view_website_requests'), ('u-t27-mgr', 'view_all_website_requests'), ('u-t27-mgr', 'convert_website_requests'), ('u-t27-mgr', 'view_all_customers'), ('u-t27-mgr', 'view_customers')
    on conflict do nothing;
  insert into public.order_requests (id, customer_name, phone, product_id, product_name, quantity, delivery_location, status) values
    ('e2700000-0000-4000-8000-000000000001', 'T27 Req 1', '069 827 7001', 'p27-a', 'T27 Ball A', 2, 'Hodan', 'new'),
    ('e2700000-0000-4000-8000-000000000002', 'T27 Req 2', '069 827 7002', 'p27-b', 'T27 Ball B', 1, 'Hodan', 'new'),
    ('e2700000-0000-4000-8000-000000000003', 'T27 Req 3', '069 827 7003', 'p27-e', 'T27 Ball E', 1, 'Hodan', 'new');
  alter table public.order_requests disable trigger user;
  insert into public.order_requests (id, customer_name, phone, product_id, product_name, quantity, delivery_location, status)
  select ('e27000' || lpad(n::text, 2, '0') || '-0000-4000-8000-000000000009')::uuid, 'T27 Web ' || n, '069 827 78' || lpad(n::text, 2, '0'), 'p27-a', 'T27 Ball A', 2, 'Hodan', 'confirmed' from generate_series(1, 6) n;
  alter table public.order_requests enable trigger user;
  -- convert_order_request is the legacy path: it is NOT granted to any client role on this schema. It is tested here with a grant that exists only inside this rolled-back transaction.
  perform pg_temp.chk('I0 convert_order_request is not callable by any client role (a legacy path); only convert_website_request is exposed', not has_function_privilege('authenticated', 'public.convert_order_request(uuid, text)', 'execute') and not has_function_privilege('anon', 'public.convert_order_request(uuid, text)', 'execute') and has_function_privilege('authenticated', 'public.convert_website_request(uuid, jsonb)', 'execute'));
  grant execute on function public.convert_order_request(uuid, text) to authenticated;
  -- convert_order_request: no price is sent, so the agreed (else list) price applies
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.convert_order_request(%L, %L) as v', 'e2700000-0000-4000-8000-000000000001', v_a)); v_o := pg_temp.jv(t) #>> '{}';
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.convert_order_request(%L, %L) as v', 'e2700000-0000-4000-8000-000000000002', 'cust-t27-s')); v_o2 := pg_temp.jv(t) #>> '{}';
  perform pg_temp.chk('I1 convert_order_request: for a customer with an agreement the order gets the agreed price (7.00, list 10.00) with an "agreement" resolution; for a customer without one the list price exactly as before (20.00); both requests are marked converted',
    v_o is not null and pg_temp.line(v_o) = '10.00:7.00:2' and (select source from public.order_price_resolutions where order_id = v_o) = 'agreement'
    and v_o2 is not null and pg_temp.line(v_o2) = '20.00:20.00:1' and (select source from public.order_price_resolutions where order_id = v_o2) = 'list'
    and (select count(*) from public.order_requests where status = 'converted' and converted_order_id in (v_o, v_o2)) = 2, coalesce(v_o, '') || coalesce(v_o2, ''));
  -- convert_website_request
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.convert_website_request(%L, %L::jsonb) as v', 'e2700001-0000-4000-8000-000000000009', jsonb_build_object('customerId', v_a, 'lines', jsonb_build_array(jsonb_build_object('productId', 'p27-a', 'quantity', 2, 'actualUnitPrice', 7.00)))::text));
  v_o := pg_temp.jv(t) #>> '{}';
  perform pg_temp.chk('I2 convert_website_request: confirming exactly the agreed price needs no reason', v_o is not null and pg_temp.line(v_o) = '10.00:7.00:2' and (select source from public.order_price_resolutions where order_id = v_o) = 'agreement', t);
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.convert_website_request(%L, %L::jsonb) as v', 'e2700002-0000-4000-8000-000000000009', jsonb_build_object('customerId', v_a, 'lines', jsonb_build_array(jsonb_build_object('productId', 'p27-a', 'quantity', 2, 'actualUnitPrice', 9.00)))::text));
  perform pg_temp.chk('I3 a different confirmed price for a customer with an agreement is refused WITHOUT a reason (22023, the message names priceOverrideReason); the request stays confirmed and no order was created',
    pg_temp.err(t) and pg_temp.code(t) = '22023' and pg_temp.msg(t) like '%priceOverrideReason%'
    and (select status::text from public.order_requests where id = 'e2700002-0000-4000-8000-000000000009') = 'confirmed' and (select converted_order_id from public.order_requests where id = 'e2700002-0000-4000-8000-000000000009') is null, t);
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.convert_website_request(%L, %L::jsonb) as v', 'e2700002-0000-4000-8000-000000000009', jsonb_build_object('customerId', v_a, 'priceOverrideReason', 'Customer confirmed 9.00 by phone, owner agreed', 'lines', jsonb_build_array(jsonb_build_object('productId', 'p27-a', 'quantity', 2, 'actualUnitPrice', 9.00)))::text));
  v_o := pg_temp.jv(t) #>> '{}';
  perform pg_temp.chk('I4 with priceOverrideReason in the payload the conversion succeeds, the line is recorded as a staff override and the audit log has the warning',
    not pg_temp.err(t) and pg_temp.line(v_o) = '10.00:9.00:2' and (select source from public.order_price_resolutions where order_id = v_o) = 'staff_override'
    and exists (select 1 from public.system_logs l where l.target_id = v_o and l.metadata ->> 'event' = 'agreed_price_overridden' and l.metadata ->> 'reason' like '%owner agreed%'), t);
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.convert_website_request(%L, %L::jsonb) as v', 'e2700003-0000-4000-8000-000000000009', jsonb_build_object('customerId', 'cust-t27-s', 'lines', jsonb_build_array(jsonb_build_object('productId', 'p27-a', 'quantity', 2, 'actualUnitPrice', 9.00)))::text));
  v_o := pg_temp.jv(t) #>> '{}';
  perform pg_temp.chk('I5 for a customer without an agreement the confirmed price is accepted exactly as before (9.00, no reason needed), recorded with the "list" rule', not pg_temp.err(t) and pg_temp.line(v_o) = '10.00:9.00:2' and (select source from public.order_price_resolutions where order_id = v_o) = 'list', t);
  -- review state: cust-t27-s has a pending (unverified) agreement for p27-e
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.convert_order_request(%L, %L) as v', 'e2700000-0000-4000-8000-000000000003', 'cust-t27-s'));
  perform pg_temp.chk('I6 a line whose price is waiting for confirmation (pending agreement) blocks BOTH conversions (22023, "needs to be confirmed"); the requests stay unconverted and no order exists',
    pg_temp.err(t) and pg_temp.code(t) = '22023' and pg_temp.msg(t) like '%needs to be confirmed%'
    and (select status::text from public.order_requests where id = 'e2700000-0000-4000-8000-000000000003') = 'new'
    and pg_temp.err(pg_temp.q(mgr_u, 'authenticated', format('select public.convert_website_request(%L, %L::jsonb) as v', 'e2700004-0000-4000-8000-000000000009', jsonb_build_object('customerId', 'cust-t27-s', 'lines', jsonb_build_array(jsonb_build_object('productId', 'p27-e', 'quantity', 1, 'actualUnitPrice', 12.00)))::text)))
    and (select status::text from public.order_requests where id = 'e2700004-0000-4000-8000-000000000009') = 'confirmed'
    and not exists (select 1 from public.order_items i join public.orders o on o.id = i.order_id where o.customer_id = 'cust-t27-s' and i.product_id = 'p27-e'), t);
  perform pg_temp.chk('I7 the conversions keep their authorization: an Officer without convert_website_requests is refused (42501) and a customer-app user cannot call either',
    pg_temp.denied(pg_temp.q(off_u, 'authenticated', format('select public.convert_website_request(%L, ''{}''::jsonb) as v', 'e2700005-0000-4000-8000-000000000009')))
    and pg_temp.err(pg_temp.q(ca, 'authenticated', format('select public.convert_order_request(%L, %L) as v', 'e2700000-0000-4000-8000-000000000003', v_a))));
  -- M4: a price that became below cost and was never approved: staff who cannot see cost learn nothing about cost
  t := pg_temp.q(mgr_u, 'authenticated', format('select public.create_price_agreement(%L, ''p27-b'', null, 15.00, %L, null, ''Agreed before the cost rose (T27)'') as v', 'cust-t27-s', v_today)); v_ag3 := (pg_temp.jv(t) #>> '{}')::uuid;
  update public.products set cost_price = 16.00 where id = 'p27-b';
  t := pg_temp.co(off_u, 'cust-t27-s', jsonb_build_array(jsonb_build_object('productId', 'p27-b', 'quantity', 1)));
  j := pg_temp.jv(pg_temp.q(off_u, 'authenticated', 'select public.resolve_order_price(''cust-t27-s'', ''p27-b'', null) as v'));
  perform pg_temp.chk('M4a the order error and resolve_order_price for an Officer without cost permissions say the price needs review, and neither contains the word "cost" or any cost figure',
    pg_temp.err(t) and pg_temp.code(t) = '22023' and pg_temp.msg(t) not ilike '%cost%' and pg_temp.msg(t) not like '%16%' and (j ->> 'source') = 'review' and (j ->> 'reason') not ilike '%cost%' and pg_temp.banned(j) is null, t || ' ' || j::text);
  perform pg_temp.chk('M4b the order stays blocked (no bypass, even for a Super Admin) and the pricing administrators still see the problem on the Customer Prices list (belowCurrentCost)',
    pg_temp.err(pg_temp.co(sa_u, 'cust-t27-s', jsonb_build_array(jsonb_build_object('productId', 'p27-b', 'quantity', 1)))) and pg_temp.err(pg_temp.co(sa_u, 'cust-t27-s', jsonb_build_array(jsonb_build_object('productId', 'p27-b', 'quantity', 1, 'actualUnitPrice', 15.00)), jsonb_build_object('belowCostReason', 'Trying to bypass the review (T27)')))
    and exists (select 1 from jsonb_array_elements(pg_temp.jv(pg_temp.q(mgr_u, 'authenticated', 'select public.list_price_agreements(''cust-t27-s'') as v'))) e where (e ->> 'belowCurrentCost')::boolean and not (e ->> 'belowCostApproved')::boolean));
  update public.products set cost_price = 12.00 where id = 'p27-b';

  -- ---------------------------------------------------------------- G. the customer app is unchanged by the new policy
  perform pg_temp.chk('G1 the app still prices from the server alone: a client price in the cart is ignored (A: Red 6.00 whatever is sent)',
    (pg_temp.jv(pg_temp.preview(ca, jsonb_build_array(jsonb_build_object('productId', 'p27-a', 'designId', dA1, 'quantity', 1, 'unitPrice', 0.01, 'price', 0.01)))) -> 'lines' -> 0 ->> 'unitPrice')::numeric = 6);
  perform pg_temp.chk('G2 a customer sees no cost, margin or other customer''s agreement in the catalogue, designs or notices',
    pg_temp.banned(pg_temp.q(ca, 'authenticated', 'select * from public.customer_catalog()')::jsonb) is null and pg_temp.banned(pg_temp.q(ca, 'authenticated', 'select * from public.customer_designs()')::jsonb) is null and pg_temp.banned(pg_temp.notes(ca)) is null);
end
$t$;

select case when ok then 'PASS' else 'FAIL' end || ' ' || lpad(n::text, 3) || ' ' || name || case when ok then '' else '   [' || detail || ']' end from r27 order by n;
select 'TOTAL: ' || count(*) || ' checks, ' || count(*) filter (where not ok) || ' failure(s)' from r27;

rollback;
