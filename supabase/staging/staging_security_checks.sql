-- ============================================================================
-- EFZ - STAGING SECURITY CHECKS  (rollback-only - STAGING ONLY)
-- ----------------------------------------------------------------------------
-- Replays ~40 attacks and legitimate actions as the real `anon` and
-- `authenticated` roles, impersonating the synthetic staff from
-- staging_test_data.sql, and reports PASS / FAIL for each.
--
-- Nothing it does persists. Every attempt runs in its own sub-transaction
-- that is always rolled back (it ends by raising a private error code), so
-- even the actions that are allowed leave no trace. The only object created
-- is a TEMPORARY results table, which disappears when the session ends.
--
-- Prerequisites
--   * staging_test_data.sql loaded.
--   * Auth users created in the dashboard for the staff emails, so profiles
--     have auth_user_id. A check whose actor has no login is reported SKIP.
--
-- Expected results
--   * Before 08/09: many FAILs - that is the point, they are the holes.
--   * After 08 and 09: every row PASS (or SKIP for an unlinked actor).
-- ============================================================================

create temp table if not exists efz_staging_checks (
  run_at     timestamptz,
  n          integer,
  area       text,
  check_name text,
  actor      text,
  expected   text,
  outcome    text,
  result     text,
  detail     text
);

do $checks$
declare
  v_run     timestamptz := clock_timestamp();
  v_uid     uuid;
  v_count   bigint;
  v_outcome text;
  v_detail  text;
  v_result  text;
  t         record;
begin
  for t in
    select * from (values
      -- ---- profiles & hierarchy -------------------------------------------
      (1,  'profiles', 'Officer promotes self to Super Admin', 'u-stg-officer1', 'deny', '%manage_users%',
       $q$ with x as (update public.profiles set role = 'Super Admin', status = 'active' where id = 'u-stg-officer1' returning 1) select count(*) from x $q$),
      (2,  'profiles', 'Officer edits own phone (safe field)', 'u-stg-officer1', 'allow', null,
       $q$ with x as (update public.profiles set phone = '+000 999 0000' where id = 'u-stg-officer1' returning 1) select count(*) from x $q$),
      (3,  'profiles', 'Officer raises own commission rate', 'u-stg-officer1', 'deny', '%manage_users%',
       $q$ with x as (update public.profiles set commission_percentage = 50 where id = 'u-stg-officer1' returning 1) select count(*) from x $q$),
      (4,  'profiles', 'Officer writes own commission total', 'u-stg-officer1', 'deny', '%cannot be changed directly%',
       $q$ with x as (update public.profiles set paid_commission_total = 999 where id = 'u-stg-officer1' returning 1) select count(*) from x $q$),
      (5,  'hierarchy', 'User manager grants self a permission', 'u-stg-manager', 'deny', '%own permissions%',
       $q$ select count(*) from (select public.set_user_permissions('u-stg-manager', array(select permission_code from public.user_permissions where user_id = 'u-stg-manager') || array['delete_orders'])) s $q$),
      (6,  'hierarchy', 'User manager grants manage_users to officer', 'u-stg-manager', 'deny', '%only be granted or revoked by a Super Admin%',
       $q$ select count(*) from (select public.set_user_permissions('u-stg-officer1', array(select permission_code from public.user_permissions where user_id = 'u-stg-officer1') || array['manage_users'])) s $q$),
      (7,  'hierarchy', 'User manager grants a permission they lack', 'u-stg-manager', 'deny', '%do not hold%',
       $q$ select count(*) from (select public.set_user_permissions('u-stg-officer1', array(select permission_code from public.user_permissions where user_id = 'u-stg-officer1') || array['delete_orders'])) s $q$),
      (8,  'hierarchy', 'User manager grants a permission they hold', 'u-stg-manager', 'allow', null,
       $q$ select count(*) from (select public.set_user_permissions('u-stg-officer1', array(select permission_code from public.user_permissions where user_id = 'u-stg-officer1') || array['view_reports'])) s $q$),
      (9,  'hierarchy', 'User manager sets an officer''s commission', 'u-stg-manager', 'allow', null,
       $q$ with x as (update public.profiles set commission_percentage = 7 where id = 'u-stg-officer1' returning 1) select count(*) from x $q$),
      (10, 'hierarchy', 'User manager renames the Super Admin', 'u-stg-manager', 'deny', '%Super Admin%',
       $q$ with x as (update public.profiles set name = 'pwned' where id = 'u-stg-admin' returning 1) select count(*) from x $q$),
      (11, 'hierarchy', 'User manager deletes the Super Admin', 'u-stg-manager', 'deny', '%Super Admin%',
       $q$ with x as (delete from public.profiles where id = 'u-stg-admin' returning 1) select count(*) from x $q$),
      (12, 'hierarchy', 'User manager writes user_permissions directly', 'u-stg-manager', 'deny', '%row-level security%',
       $q$ with x as (insert into public.user_permissions (user_id, permission_code) values ('u-stg-manager', 'delete_orders') returning 1) select count(*) from x $q$),
      (13, 'hierarchy', 'Super Admin grants manage_users', 'u-stg-admin', 'allow', null,
       $q$ select count(*) from (select public.set_user_permissions('u-stg-officer1', array(select permission_code from public.user_permissions where user_id = 'u-stg-officer1') || array['manage_users'])) s $q$),
      (14, 'hierarchy', 'Only Super Admin demotes self', 'u-stg-admin', 'deny', '%last active Super Admin%',
       $q$ with x as (update public.profiles set role = 'Manager' where id = 'u-stg-admin' returning 1) select count(*) from x $q$),
      (15, 'suspended', 'Suspended officer reads the staff directory', 'u-stg-suspended', 'deny', null,
       $q$ select count(*) from public.profiles where id <> 'u-stg-suspended' $q$),
      (16, 'suspended', 'Suspended officer reads products (cost price)', 'u-stg-suspended', 'deny', null,
       $q$ select count(*) from public.products $q$),

      -- ---- products & inventory ------------------------------------------
      (20, 'products', 'Anon reads products.cost_price', 'anon', 'deny', '%permission denied%',
       $q$ select count(cost_price) from public.products $q$),
      (21, 'products', 'Anon reads public_products', 'anon', 'allow', null,
       $q$ select count(*) from public.public_products $q$),
      (22, 'products', 'Anon updates through public_products', 'anon', 'deny', '%permission denied%',
       $q$ with x as (update public.public_products set name = 'pwned' returning 1) select count(*) from x $q$),
      (23, 'products', 'Anon reads inventory_status', 'anon', 'deny', '%permission denied%',
       $q$ select count(*) from public.inventory_status $q$),
      (24, 'inventory', 'Inventory staff sets stock directly', 'u-stg-inventory', 'deny', '%adjust_stock%',
       $q$ with x as (update public.products set stock = 999 where id = 'prod-stg-nexus' returning 1) select count(*) from x $q$),
      (25, 'inventory', 'Inventory staff uses adjust_stock()', 'u-stg-inventory', 'allow', null,
       $q$ select count(*) from (select public.adjust_stock('prod-stg-nexus', 5, 'Staging check')) s $q$),
      (26, 'inventory', 'Inventory staff writes the stock ledger directly', 'u-stg-inventory', 'deny', '%row-level security%',
       $q$ with x as (insert into public.stock_movements (id, product_id, type, quantity_change) values ('mv-stg-check', 'prod-stg-nexus', 'import', 500) returning 1) select count(*) from x $q$),

      -- ---- orders, payments, commissions -----------------------------------
      (30, 'orders', 'Delivery staff writes orders.total', 'u-stg-delivery', 'deny', '%maintained by the database%',
       $q$ with x as (update public.orders set total = 1 where id = 'ORD-STG-1001' returning 1) select count(*) from x $q$),
      (31, 'orders', 'Delivery staff writes orders.status directly', 'u-stg-delivery', 'deny', '%maintained by the database%',
       $q$ with x as (update public.orders set status = 'delivered' where id = 'ORD-STG-1001' returning 1) select count(*) from x $q$),
      (32, 'orders', 'Delivery staff reassigns the officer', 'u-stg-delivery', 'deny', '%Super Admin%',
       $q$ with x as (update public.orders set marketing_officer_id = 'u-stg-officer1' where id = 'ORD-STG-1001' returning 1) select count(*) from x $q$),
      (33, 'orders', 'Delivery staff edits delivery notes', 'u-stg-delivery', 'allow', null,
       $q$ with x as (update public.orders set delivery_notes = 'Gate 3' where id = 'ORD-STG-1001' returning 1) select count(*) from x $q$),
      (34, 'orders', 'Delivery staff uses update_order_status()', 'u-stg-delivery', 'allow', null,
       $q$ select count(*) from (select public.update_order_status('ORD-STG-1001', 'processing', 'Staging check')) s $q$),
      (35, 'orders', 'Officer creates an order with create_order()', 'u-stg-officer1', 'allow', null,
       $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-alpha","items":[{"productId":"prod-stg-nexus","quantity":1}]}')) s $q$),
      (36, 'orders', 'Officer writes order_items directly', 'u-stg-officer1', 'deny', '%row-level security%',
       $q$ with x as (insert into public.order_items (id, order_id, product_id, quantity, actual_unit_price) values ('itm-stg-check', 'ORD-STG-1001', 'prod-stg-nexus', 1, 1000) returning 1) select count(*) from x $q$),
      (37, 'payments', 'Delivery staff inserts a payment directly', 'u-stg-delivery', 'deny', '%row-level security%',
       $q$ with x as (insert into public.payments (id, order_id, amount) values ('pay-stg-check', 'ORD-STG-1001', 16) returning 1) select count(*) from x $q$),
      (38, 'payments', 'Delivery staff uses record_payment()', 'u-stg-delivery', 'allow', null,
       $q$ select count(*) from (select public.record_payment('ORD-STG-1001', 5)) s $q$),
      (39, 'commissions', 'User manager marks a commission paid directly', 'u-stg-manager', 'deny', null,
       $q$ with x as (update public.commissions set status = 'paid' where status = 'pending' returning 1) select count(*) from x $q$),

      -- ---- audit, notifications, website requests ---------------------------
      (40, 'audit', 'Log line claiming to be the Super Admin is re-stamped', 'u-stg-manager', 'allow', null,
       $q$ with x as (insert into public.system_logs (id, message, user_id, username, occurred_at) values ('log-stg-check', 'Staging check', 'u-stg-admin', 'Test Super Admin', '2000-01-01') returning user_id, occurred_at) select count(*) from x where user_id = 'u-stg-manager' and occurred_at > now() - interval '1 hour' $q$),
      (41, 'notifications', 'Officer sends a notification to the Super Admin', 'u-stg-officer1', 'deny', '%row-level security%',
       $q$ with x as (insert into public.notifications (id, title, user_id) values ('ntf-stg-check', 'Fake', 'u-stg-admin') returning 1) select count(*) from x $q$),
      (42, 'requests', 'Anon submits a pre-converted request', 'anon', 'deny', '%row-level security%',
       $q$ with x as (insert into public.order_requests (customer_name, phone, status, handled_by) values ('Check Visitor', '+000 300 0001', 'converted', 'u-stg-admin')) select 1 $q$),
      (43, 'requests', 'Anon submits a valid request (app path)', 'anon', 'allow', null,
       $q$ with x as (insert into public.order_requests (customer_name, phone, quantity) values ('Check Visitor', '+000 300 0001', 1)) select 1 $q$),
      (44, 'requests', 'Delivery staff marks a request converted directly', 'u-stg-delivery', 'deny', '%convert_order_request%',
       $q$ with x as (update public.order_requests set status = 'converted' where id = '00000000-0000-4000-8000-000000000001' returning 1) select count(*) from x $q$),

      -- ---- diagnostics -------------------------------------------------------
      (50, 'diagnostics', 'Anon runs run_diagnostics()', 'anon', 'deny', '%permission denied%',
       $q$ select count(*) from (select public.run_diagnostics()) s $q$),
      (51, 'diagnostics', 'Officer (no view_diagnostics) runs run_diagnostics()', 'u-stg-officer1', 'deny', '%view_diagnostics%',
       $q$ select count(*) from (select public.run_diagnostics()) s $q$),
      (52, 'diagnostics', 'Ops manager (view_diagnostics) runs run_diagnostics()', 'u-stg-ops', 'allow', null,
       $q$ select count(*) from (select public.run_diagnostics()) s $q$),
      (53, 'diagnostics', 'Officer forges a finding with upsert_issue()', 'u-stg-officer1', 'deny', '%permission denied%',
       $q$ select count(*) from (select public.upsert_issue('fake', 1, 'Fake', 'INFO', 'x', 'x', 'x', 'x', 'x', false)) s $q$),
      (54, 'diagnostics', 'Officer calls recalc_order_financials()', 'u-stg-officer1', 'deny', '%permission denied%',
       $q$ select count(*) from (select public.recalc_order_financials('ORD-STG-1001')) s $q$)
    ) as v(n, area, check_name, actor, expected, error_like, sql)
  loop
    v_count := null;
    v_uid   := null;

    if t.actor <> 'anon' then
      select auth_user_id into v_uid from public.profiles where id = t.actor;
      if v_uid is null then
        insert into efz_staging_checks
        values (v_run, t.n, t.area, t.check_name, t.actor, t.expected, 'skipped', 'SKIP',
                'No Auth user linked to ' || t.actor || ' - create it in the dashboard');
        continue;
      end if;
    end if;

    begin
      if t.actor = 'anon' then
        perform set_config('request.jwt.claim.sub', '', true);
        perform set_config('request.jwt.claims', '{"role":"anon"}', true);
        perform set_config('role', 'anon', true);
      else
        perform set_config('request.jwt.claim.sub', v_uid::text, true);
        perform set_config('request.jwt.claims',
          json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
        perform set_config('role', 'authenticated', true);
      end if;

      execute t.sql into v_count;

      -- Always undo: this private error rolls the sub-transaction back.
      raise exception using errcode = 'EZ000', message = 'efz staging check rollback';
    exception
      when sqlstate 'EZ000' then
        v_outcome := case when coalesce(v_count, 0) > 0 then 'allowed' else 'no rows' end;
        v_detail  := 'rows: ' || coalesce(v_count, 0);
      when others then
        v_outcome := 'error';
        v_detail  := sqlerrm;
    end;

    v_result := case
      when t.expected = 'allow' and v_outcome = 'allowed' then 'PASS'
      when t.expected = 'deny'  and v_outcome = 'no rows' and t.error_like is null then 'PASS'
      when t.expected = 'deny'  and v_outcome = 'error'
           and (t.error_like is null or v_detail ilike t.error_like) then 'PASS'
      else 'FAIL'
    end;

    insert into efz_staging_checks
    values (v_run, t.n, t.area, t.check_name, t.actor, t.expected, v_outcome, v_result, v_detail);
  end loop;
end
$checks$;

select n, result, area, check_name, actor, expected, outcome, detail
  from efz_staging_checks
 where run_at = (select max(run_at) from efz_staging_checks)
 order by n;
