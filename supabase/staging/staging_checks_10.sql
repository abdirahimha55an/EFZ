-- ============================================================================
-- EFZ - STAGING CHECKS FOR 10_rpc_hardening.sql  (rollback-only - STAGING ONLY)
-- ----------------------------------------------------------------------------
-- Same method as staging_security_checks.sql: every check runs as the real
-- `anon` / `authenticated` role, impersonating the synthetic staff from
-- staging_test_data.sql, inside a sub-transaction that is ALWAYS rolled back.
-- Nothing persists; the only object created is a TEMPORARY results table.
--
-- Each check has up to three parts:
--   setup   runs first, as the SQL editor (trusted), e.g. to move an order
--   action  runs as the actor; this is what is being allowed or denied
--   verify  runs afterwards, as the SQL editor, and must return > 0 for an
--           'allow' check to PASS (proves the action had the right effect)
--
-- Synthetic actors derived inside the rolled-back sub-transaction:
--   cs              u-stg-inventory turned into a Customer Service user
--   stockonly       u-stg-delivery holding only view_products/view_inventory/adjust_stock
--   officer_noview  u-stg-officer1 holding only create_orders/view_own_customers_only
--   manager_del     u-stg-manager plus delete_orders
--
-- Prerequisites: staging_test_data.sql, the Auth users, 08, 09 and 10.
-- Expected: every row PASS.
-- ============================================================================

create temp table if not exists efz_checks_10 (
  run_at timestamptz, n integer, area text, check_name text, actor text,
  expected text, outcome text, result text, detail text
);

do $checks$
declare
  v_run      timestamptz := clock_timestamp();
  v_uid      uuid;
  v_profile  text;
  v_count    bigint;
  v_verify   bigint;
  v_outcome  text;
  v_detail   text;
  v_result   text;
  t          record;
begin
  for t in
    select * from (values
      -- ---- Customer Service and customer ownership (tests 9, 10) ------------
      (100, 'ownership', 'CS creates an order and names another officer: officer comes from the customer', 'cs', 'allow', null,
       null,
       $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-alpha","marketingOfficerId":"u-stg-officer2","items":[{"productId":"prod-stg-nexus","quantity":2}]}')) s $q$,
       $q$ select count(*) from public.orders o where o.customer_id = 'cust-stg-alpha' and o.created_by = 'u-stg-inventory' and o.marketing_officer_id = 'u-stg-officer1' and o.status = 'pending'
             and exists (select 1 from public.system_logs l where l.target_id = o.id and l.metadata->>'event' = 'officer_override_ignored') $q$),
      (101, 'ownership', 'CS changes a customer''s Marketing Officer', 'cs', 'deny', '%transfer_customer_owner%',
       null, $q$ with x as (update public.customers set marketing_officer_id = 'u-stg-officer2' where id = 'cust-stg-alpha' returning 1) select count(*) from x $q$, null),
      (102, 'ownership', 'Manager changes a customer''s Marketing Officer', 'u-stg-manager', 'deny', '%transfer_customer_owner%',
       null, $q$ with x as (update public.customers set marketing_officer_id = 'u-stg-officer2' where id = 'cust-stg-alpha' returning 1) select count(*) from x $q$, null),
      (103, 'ownership', 'Super Admin edits the officer column directly', 'u-stg-admin', 'deny', '%transfer_customer_owner%',
       null, $q$ with x as (update public.customers set marketing_officer_id = 'u-stg-officer2' where id = 'cust-stg-alpha' returning 1) select count(*) from x $q$, null),
      (104, 'ownership', 'Officer hands own customer to another officer', 'u-stg-officer1', 'deny', '%transfer_customer_owner%',
       null, $q$ with x as (update public.customers set marketing_officer_id = 'u-stg-officer2' where id = 'cust-stg-alpha' returning 1) select count(*) from x $q$, null),
      (105, 'ownership', 'CS registers a customer to an officer', 'cs', 'deny', '%Only a Marketing Officer registering%',
       null, $q$ with x as (insert into public.customers (id, name, phone, marketing_officer_id) values ('cust-stg-chk1', 'Check Customer', '+000 400 0001', 'u-stg-officer1') returning 1) select count(*) from x $q$, null),
      (106, 'ownership', 'CS registers a customer with no officer', 'cs', 'allow', null,
       null, $q$ with x as (insert into public.customers (id, name, phone) values ('cust-stg-chk1', 'Check Customer', '+000 400 0001') returning 1) select count(*) from x $q$,
       $q$ select count(*) from public.customers where id = 'cust-stg-chk1' and registered_by = 'u-stg-inventory' and marketing_officer_id is null $q$),
      (107, 'ownership', 'Officer registers a customer to another officer', 'u-stg-officer1', 'deny', '%only register customers to themselves%',
       null, $q$ with x as (insert into public.customers (id, name, phone, marketing_officer_id) values ('cust-stg-chk2', 'Check Customer', '+000 400 0002', 'u-stg-officer2') returning 1) select count(*) from x $q$, null),
      (108, 'ownership', 'Officer registers a customer: owner is the officer', 'u-stg-officer1', 'allow', null,
       null, $q$ with x as (insert into public.customers (id, name, phone) values ('cust-stg-chk2', 'Check Customer', '+000 400 0002') returning 1) select count(*) from x $q$,
       $q$ select count(*) from public.customers where id = 'cust-stg-chk2' and marketing_officer_id = 'u-stg-officer1' and registered_by = 'u-stg-officer1' $q$),
      (109, 'ownership', 'CS edits a customer''s phone and notes', 'cs', 'allow', null,
       null, $q$ with x as (update public.customers set phone = '+000 100 9999', notes = 'Called back' where id = 'cust-stg-alpha' returning 1) select count(*) from x $q$, null),
      (110, 'ownership', 'CS calls transfer_customer_owner()', 'cs', 'deny', '%Only a Super Admin%',
       null, $q$ select count(*) from (select public.transfer_customer_owner('cust-stg-alpha', 'u-stg-officer2', 'Check')) s $q$, null),
      (111, 'ownership', 'Super Admin transfers without a reason', 'u-stg-admin', 'deny', '%reason is required%',
       null, $q$ select count(*) from (select public.transfer_customer_owner('cust-stg-foxtrot', 'u-stg-officer1', '  ')) s $q$, null),
      (112, 'ownership', 'Super Admin transfers Foxtrot: undelivered order moves, recorded', 'u-stg-admin', 'allow', null,
       null, $q$ select count(*) from (select public.transfer_customer_owner('cust-stg-foxtrot', 'u-stg-officer1', 'Officer Two left the Foxtrot account')) s $q$,
       $q$ select count(*) from public.customers c
            where c.id = 'cust-stg-foxtrot' and c.marketing_officer_id = 'u-stg-officer1'
              and exists (select 1 from public.orders where id = 'ORD-STG-1001' and marketing_officer_id = 'u-stg-officer1')
              and exists (select 1 from public.customer_ownership_changes x where x.customer_id = c.id
                            and x.old_officer_id = 'u-stg-officer2' and x.new_officer_id = 'u-stg-officer1'
                            and x.changed_by = 'u-stg-admin' and 'ORD-STG-1001' = any(x.orders_moved)
                            and x.reason = 'Officer Two left the Foxtrot account')
              and exists (select 1 from public.system_logs l where l.target_id = c.id and l.user_id = 'u-stg-admin'
                            and l.metadata->>'event' = 'customer_ownership_transfer')
              and not exists (select 1 from public.commissions where order_id = 'ORD-STG-1001' and user_id = 'u-stg-officer2' and status <> 'void') $q$),
      (113, 'ownership', 'Transfer keeps delivered orders and their commission with the old officer', 'u-stg-admin', 'allow', null,
       null, $q$ select count(*) from (select public.transfer_customer_owner('cust-stg-charlie', 'u-stg-officer1', 'Account moved')) s $q$,
       $q$ select count(*) from public.customers c
            where c.id = 'cust-stg-charlie' and c.marketing_officer_id = 'u-stg-officer1'
              and (select count(*) from public.orders where customer_id = 'cust-stg-charlie' and marketing_officer_id = 'u-stg-officer2') = 2
              and not exists (select 1 from public.commissions k join public.orders o on o.id = k.order_id
                                where o.customer_id = 'cust-stg-charlie' and k.user_id = 'u-stg-officer1') $q$),
      (114, 'ownership', 'Super Admin transfers to someone who is not a Marketing Officer', 'u-stg-admin', 'deny', '%active Marketing Officer%',
       null, $q$ select count(*) from (select public.transfer_customer_owner('cust-stg-alpha', 'u-stg-delivery', 'Check')) s $q$, null),
      (115, 'ownership', 'Anon calls transfer_customer_owner()', 'anon', 'deny', '%permission denied%',
       null, $q$ select count(*) from (select public.transfer_customer_owner('cust-stg-alpha', 'u-stg-officer2', 'Check')) s $q$, null),
      (116, 'role', 'Customer Service preset holds no commission, cost or admin permission', 'cs', 'deny', null,
       null, $q$ select count(*) from public.user_permissions where user_id = 'u-stg-inventory' and permission_code = any(array['view_commissions','mark_commissions_paid','edit_products','add_products','adjust_stock','delete_orders','delete_customers','override_order_status','view_reports','manage_users','manage_system','change_settings']) $q$, null),
      (117, 'role', 'Customer Service preset holds the order and customer permissions', 'cs', 'allow', null,
       null, $q$ select count(*) from public.user_permissions where user_id = 'u-stg-inventory' having count(*) filter (where permission_code = any(array['view_orders','create_orders','edit_orders','view_customers','view_all_customers','add_customers','edit_customers'])) = 7 $q$, null),
      (118, 'role', 'CS reads officers'' commission ledger', 'cs', 'deny', null,
       null, $q$ select count(*) from public.commissions $q$, null),
      (119, 'ownership', 'Super Admin registers a customer straight to an officer (app path)', 'u-stg-admin', 'deny', '%Only a Marketing Officer registering%',
       null, $q$ with x as (insert into public.customers (id, name, phone, marketing_officer_id) values ('cust-stg-chk3', 'Check Customer', '+000 400 0003', 'u-stg-officer1') returning 1) select count(*) from x $q$, null),
      (98,  'ownership', 'Manager registers a customer: it stays unassigned', 'u-stg-manager', 'allow', null,
       null, $q$ with x as (insert into public.customers (id, name, phone) values ('cust-stg-chk4', 'Check Customer', '+000 400 0004') returning 1) select count(*) from x $q$,
       $q$ select count(*) from public.customers where id = 'cust-stg-chk4' and marketing_officer_id is null and registered_by = 'u-stg-manager' $q$),
      (99,  'ownership', 'Super Admin assigns an unassigned customer to an officer: recorded', 'u-stg-admin', 'allow', null,
       null, $q$ select count(*) from (select public.transfer_customer_owner('cust-stg-golf', 'u-stg-officer2', 'Walk-in customer acquired by Officer Two')) s $q$,
       $q$ select count(*) from public.customer_ownership_changes x
            where x.customer_id = 'cust-stg-golf' and x.old_officer_id is null and x.new_officer_id = 'u-stg-officer2'
              and 'ORD-STG-1003' = any(x.orders_moved)
              and exists (select 1 from public.orders where id = 'ORD-STG-1003' and marketing_officer_id = 'u-stg-officer2') $q$),

      -- ---- create_order (tests 15-18) --------------------------------------
      (120, 'cost floor', 'CS sells an item at its below-cost list price', 'cs', 'deny', '%below its cost%',
       null, $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-alpha","items":[{"productId":"prod-stg-clearance","quantity":1}]}')) s $q$, null),
      (121, 'cost floor', 'CS negotiates a price below cost', 'cs', 'deny', '%below its cost%',
       null, $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-alpha","items":[{"productId":"prod-stg-nexus","quantity":1,"actualUnitPrice":5}]}')) s $q$, null),
      (122, 'cost floor', 'Officer negotiates a price below cost, with a reason', 'u-stg-officer1', 'deny', '%Only a Super Admin can approve%',
       null, $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-alpha","belowCostReason":"friend","items":[{"productId":"prod-stg-nexus","quantity":1,"actualUnitPrice":5}]}')) s $q$, null),
      (123, 'cost floor', 'Super Admin sells below cost without a reason', 'u-stg-admin', 'deny', '%belowCostReason%',
       null, $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-alpha","items":[{"productId":"prod-stg-nexus","quantity":2,"actualUnitPrice":5}]}')) s $q$, null),
      (124, 'cost floor', 'Super Admin approves a below-cost sale with a reason: recorded', 'u-stg-admin', 'allow', null,
       null, $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-alpha","belowCostReason":"Damaged stock clearance","items":[{"productId":"prod-stg-nexus","quantity":2,"actualUnitPrice":5}]}')) s $q$,
       $q$ select count(*) from public.below_cost_overrides b
            where b.approved_by = 'u-stg-admin' and b.product_id = 'prod-stg-nexus' and b.quantity = 2
              and b.selling_price = 5 and b.unit_cost = 6.70 and b.line_margin = -3.40 and b.margin_percentage = -34.00
              and b.reason = 'Damaged stock clearance'
              and exists (select 1 from public.order_items i where i.id = b.order_item_id and i.actual_unit_price = 5 and i.historical_unit_cost = 6.70)
              and exists (select 1 from public.system_logs l where l.target_id = b.order_id and l.user_id = 'u-stg-admin' and l.metadata->>'event' = 'below_cost_override') $q$),
      (125, 'backdating', 'CS creates a backdated order', 'cs', 'deny', '%dated before today%',
       null, $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-alpha","orderDate":"2026-01-15","items":[{"productId":"prod-stg-nexus","quantity":1}]}')) s $q$, null),
      (126, 'backdating', 'Officer creates a backdated order', 'u-stg-officer1', 'deny', '%dated before today%',
       null, $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-alpha","orderDate":"2026-01-15","items":[{"productId":"prod-stg-nexus","quantity":1}]}')) s $q$, null),
      (127, 'backdating', 'Super Admin creates a backdated order: recorded', 'u-stg-admin', 'allow', null,
       null, $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-alpha","orderDate":"2026-01-15","items":[{"productId":"prod-stg-nexus","quantity":1}]}')) s $q$,
       $q$ select count(*) from public.orders o where o.customer_id = 'cust-stg-alpha' and o.order_date = '2026-01-15' and o.created_by = 'u-stg-admin'
             and exists (select 1 from public.system_logs l where l.target_id = o.id and l.user_id = 'u-stg-admin' and l.metadata->>'event' = 'backdated_order') $q$),
      (128, 'backdating', 'Super Admin dates an order in the future', 'u-stg-admin', 'deny', '%future%',
       null, $q$ select count(*) from (select public.create_order(jsonb_build_object('customerId','cust-stg-alpha','orderDate',(public.efz_today() + 1)::text,'items',jsonb_build_array(jsonb_build_object('productId','prod-stg-nexus','quantity',1))))) s $q$, null),
      (129, 'create_order', 'CS creates an order already delivered', 'cs', 'deny', '%always created as pending%',
       null, $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-alpha","status":"delivered","items":[{"productId":"prod-stg-nexus","quantity":1}]}')) s $q$, null),
      (130, 'create_order', 'CS chooses the order id', 'cs', 'deny', '%order id%',
       null, $q$ select count(*) from (select public.create_order('{"id":"EFZ-FAKE-01","customerId":"cust-stg-alpha","items":[{"productId":"prod-stg-nexus","quantity":1}]}')) s $q$, null),
      (131, 'create_order', 'CS creates an order with no customer', 'cs', 'deny', '%must belong to a customer%',
       null, $q$ select count(*) from (select public.create_order('{"items":[{"productId":"prod-stg-nexus","quantity":1}]}')) s $q$, null),
      (132, 'create_order', 'CS orders zero units', 'cs', 'deny', '%whole number%',
       null, $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-alpha","items":[{"productId":"prod-stg-nexus","quantity":0}]}')) s $q$, null),
      (133, 'create_order', 'CS orders 1.5 units', 'cs', 'deny', '%whole number%',
       null, $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-alpha","items":[{"productId":"prod-stg-nexus","quantity":1.5}]}')) s $q$, null),
      (134, 'create_order', 'CS supplies a fake list price: the product''s price is used', 'cs', 'allow', null,
       null, $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-bravo","items":[{"productId":"prod-stg-nexus","quantity":1,"standardUnitPrice":999,"actualUnitPrice":12}]}')) s $q$,
       $q$ select count(*) from public.order_items i join public.orders o on o.id = i.order_id
            where o.customer_id = 'cust-stg-bravo' and o.created_by = 'u-stg-inventory' and i.standard_unit_price = 12 $q$),
      (135, 'create_order', 'Own-customers officer orders for another officer''s customer', 'u-stg-officer1', 'deny', '%Unknown customer%',
       null, $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-charlie","items":[{"productId":"prod-stg-nexus","quantity":1}]}')) s $q$, null),
      (136, 'create_order', 'Officer inserts an order row directly', 'u-stg-officer1', 'deny', '%row-level security%',
       null, $q$ with x as (insert into public.orders (id, customer_id) values ('ORD-STG-CHK', 'cust-stg-alpha') returning 1) select count(*) from x $q$, null),
      (137, 'create_order', 'Anon calls create_order()', 'anon', 'deny', '%permission denied%',
       null, $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-alpha","items":[{"productId":"prod-stg-nexus","quantity":1}]}')) s $q$, null),

      -- ---- update_order_status ---------------------------------------------
      (140, 'status', 'Delivery staff cancels an order that has a payment', 'u-stg-delivery', 'deny', '%Only a Super Admin can cancel%',
       null, $q$ select count(*) from (select public.update_order_status('ORD-STG-1001', 'cancelled', 'Customer changed mind')) s $q$, null),
      (141, 'status', 'Super Admin cancels a paid order without a reason', 'u-stg-admin', 'deny', '%reason is required%',
       null, $q$ select count(*) from (select public.update_order_status('ORD-STG-1001', 'cancelled', '')) s $q$, null),
      (142, 'status', 'Super Admin cancels a paid order with a reason: stock returns', 'u-stg-admin', 'allow', null,
       null, $q$ select count(*) from (select public.update_order_status('ORD-STG-1001', 'cancelled', 'Customer returned the goods')) s $q$,
       $q$ select count(*) from public.orders o where o.id = 'ORD-STG-1001' and o.status = 'cancelled'
             and exists (select 1 from public.stock_movements m where m.reason = 'Order ORD-STG-1001 cancelled' and m.quantity_change = 3) $q$),
      (143, 'status', 'Delivery staff reactivates a cancelled order', 'u-stg-delivery', 'deny', '%Super Admin override required%',
       null, $q$ select count(*) from (select public.update_order_status('ORD-STG-1004', 'pending', 'Reopen')) s $q$, null),
      (144, 'status', 'Super Admin reactivates without a reason', 'u-stg-admin', 'deny', '%reason is required%',
       null, $q$ select count(*) from (select public.update_order_status('ORD-STG-1004', 'pending', null)) s $q$, null),
      (145, 'status', 'Super Admin reactivates with a reason', 'u-stg-admin', 'allow', null,
       null, $q$ select count(*) from (select public.update_order_status('ORD-STG-1004', 'pending', 'Customer re-ordered')) s $q$,
       $q$ select count(*) from public.orders where id = 'ORD-STG-1004' and status = 'pending' $q$),
      (146, 'status', 'Delivery staff delivers an order: delivered_at is stamped', 'u-stg-delivery', 'allow', null,
       $q$ select public.update_order_status('ORD-STG-1001', 'processing', 'Staging check setup') $q$,
       $q$ select count(*) from (select public.update_order_status('ORD-STG-1001', 'delivered', 'Delivered to gate 3')) s $q$,
       $q$ select count(*) from public.orders where id = 'ORD-STG-1001' and status = 'delivered' and delivered_at is not null $q$),
      (147, 'status', 'Delivery staff writes delivered_at directly', 'u-stg-delivery', 'deny', '%maintained by the database%',
       null, $q$ with x as (update public.orders set delivered_at = now() where id = 'ORD-STG-1001' returning 1) select count(*) from x $q$, null),
      (148, 'status', 'Delivery staff skips straight to delivered', 'u-stg-delivery', 'deny', '%Super Admin override required%',
       null, $q$ select count(*) from (select public.update_order_status('ORD-STG-1003', 'delivered', 'x')) s $q$, null),
      (149, 'order edit', 'Delivery staff moves an order to another month', 'u-stg-delivery', 'deny', '%needs a Super Admin%',
       null, $q$ with x as (update public.orders set order_date = '2026-08-01' where id = 'ORD-STG-1001' returning 1) select count(*) from x $q$, null),
      (150, 'order edit', 'Delivery staff moves an order to another customer', 'u-stg-delivery', 'deny', '%needs a Super Admin%',
       null, $q$ with x as (update public.orders set customer_id = 'cust-stg-alpha' where id = 'ORD-STG-1001' returning 1) select count(*) from x $q$, null),
      (151, 'order edit', 'Delivery staff turns an order into a trial', 'u-stg-delivery', 'deny', '%needs a Super Admin%',
       null, $q$ with x as (update public.orders set order_type = 'trial' where id = 'ORD-STG-1001' returning 1) select count(*) from x $q$, null),
      (152, 'order edit', 'Super Admin moves a pending order to another customer: officer follows', 'u-stg-admin', 'allow', null,
       null, $q$ with x as (update public.orders set customer_id = 'cust-stg-alpha' where id = 'ORD-STG-1003' returning 1) select count(*) from x $q$,
       $q$ select count(*) from public.orders where id = 'ORD-STG-1003' and customer_id = 'cust-stg-alpha' and marketing_officer_id = 'u-stg-officer1' $q$),

      -- ---- record_payment ---------------------------------------------------
      (160, 'payments', 'Delivery staff pays against a cancelled order', 'u-stg-delivery', 'deny', '%cancelled%',
       null, $q$ select count(*) from (select public.record_payment('ORD-STG-1004', 1)) s $q$, null),
      (161, 'payments', 'Officer without view_orders pays against someone else''s order', 'officer_noview', 'deny', '%Unknown order%',
       null, $q$ select count(*) from (select public.record_payment('ORD-STG-1002', 1)) s $q$, null),
      (162, 'payments', 'Delivery staff overpays', 'u-stg-delivery', 'deny', '%exceeds the outstanding balance%',
       null, $q$ select count(*) from (select public.record_payment('ORD-STG-1002', 1000)) s $q$, null),
      (163, 'payments', 'Delivery staff records a valid payment', 'u-stg-delivery', 'allow', null,
       null, $q$ select count(*) from (select public.record_payment('ORD-STG-1002', 4)) s $q$,
       $q$ select count(*) from public.orders o where o.id = 'ORD-STG-1002' and o.amount_paid = 4 and o.outstanding_balance = 20
             and exists (select 1 from public.payments p where p.order_id = o.id and p.amount = 4 and p.payment_date = public.efz_today()) $q$),
      (164, 'payments', 'Delivery staff records a payment dated yesterday', 'u-stg-delivery', 'deny', '%dated before today%',
       null, $q$ select count(*) from (select public.record_payment('ORD-STG-1002', 4, 'Cash', public.efz_today() - 1)) s $q$, null),
      (165, 'payments', 'Delivery staff records a payment dated today (Mogadishu)', 'u-stg-delivery', 'allow', null,
       null, $q$ select count(*) from (select public.record_payment('ORD-STG-1002', 4, 'EVC', public.efz_today())) s $q$, null),
      (166, 'payments', 'Super Admin records a backdated payment: recorded', 'u-stg-admin', 'allow', null,
       null, $q$ select count(*) from (select public.record_payment('ORD-STG-1002', 4, 'Cash', date '2026-09-20', 'RCPT-9', 'Cash received on the 20th')) s $q$,
       $q$ select count(*) from public.payments p where p.order_id = 'ORD-STG-1002' and p.payment_date = '2026-09-20' and p.recorded_by = 'u-stg-admin'
             and exists (select 1 from public.system_logs l where l.target_id = 'ORD-STG-1002' and l.user_id = 'u-stg-admin' and l.metadata->>'event' = 'backdated_payment') $q$),
      (167, 'payments', 'Super Admin records a future-dated payment', 'u-stg-admin', 'deny', '%future%',
       null, $q$ select count(*) from (select public.record_payment('ORD-STG-1002', 4, 'Cash', public.efz_today() + 1)) s $q$, null),

      -- ---- pay_commissions --------------------------------------------------
      (170, 'payout', 'Pay a commission that is already paid', 'u-stg-manager', 'deny', '%not payable%',
       null, $q$ select count(*) from (select public.pay_commissions('u-stg-officer1', array(select id from public.commissions where order_id = 'STG-BASE-01'))) s $q$, null),
      (171, 'payout', 'Pay commission on an order that is not delivered', 'u-stg-manager', 'deny', '%not payable%',
       null, $q$ select count(*) from (select public.pay_commissions('u-stg-officer2', array(select id from public.commissions where order_id = 'ORD-STG-1001'))) s $q$, null),
      (172, 'payout', 'Pay a void commission', 'u-stg-manager', 'deny', '%not payable%',
       null, $q$ select count(*) from (select public.pay_commissions('u-stg-officer1', array(select id from public.commissions where order_id = 'ORD-STG-1004'))) s $q$, null),
      (173, 'payout', 'Pay one officer''s commission under another officer''s name', 'u-stg-manager', 'deny', '%not payable%',
       null, $q$ select count(*) from (select public.pay_commissions('u-stg-officer1', array(select id from public.commissions where order_id = 'STG-BASE-05'))) s $q$, null),
      (174, 'payout', 'Pay an empty selection', 'u-stg-manager', 'deny', '%No commissions selected%',
       null, $q$ select count(*) from (select public.pay_commissions('u-stg-officer2', array[]::uuid[])) s $q$, null),
      (175, 'payout', 'Mixed eligible and ineligible selection pays nothing', 'u-stg-manager', 'deny', '%not payable%',
       null, $q$ select count(*) from (select public.pay_commissions('u-stg-officer2', array(select id from public.commissions where order_id in ('STG-BASE-05', 'ORD-STG-1001')))) s $q$, null),
      (176, 'payout', 'Pay delivered, unpaid commission', 'u-stg-manager', 'allow', null,
       null, $q$ select count(*) from (select public.pay_commissions('u-stg-officer2', array(select id from public.commissions where order_id in ('STG-BASE-05', 'ORD-STG-1002')))) s $q$,
       $q$ select count(*) from public.commission_payouts p
            where p.user_id = 'u-stg-officer2' and p.paid_by = 'u-stg-manager'
              and p.amount = (select sum(amount) from public.commissions where payout_id = p.id)
              and (select count(*) from public.commissions where payout_id = p.id and status = 'paid') = 2 $q$),
      (177, 'payout', 'Pay the same commission twice (test 13)', 'u-stg-manager', 'deny', '%not payable%',
       $q$ select public.pay_commissions('u-stg-officer2', array(select id from public.commissions where order_id = 'STG-BASE-05')) $q$,
       $q$ select count(*) from (select public.pay_commissions('u-stg-officer2', array(select id from public.commissions where order_id = 'STG-BASE-05'))) s $q$, null),
      (178, 'payout', 'Same commission id listed twice pays it once', 'u-stg-manager', 'allow', null,
       null, $q$ select count(*) from (select public.pay_commissions('u-stg-officer2', array(select id from public.commissions where order_id = 'STG-BASE-06') || array(select id from public.commissions where order_id = 'STG-BASE-06'))) s $q$,
       $q$ select count(*) from public.commission_payouts p where p.user_id = 'u-stg-officer2' and p.amount = (select amount from public.commissions where order_id = 'STG-BASE-06') $q$),

      -- ---- products ---------------------------------------------------------
      (180, 'products', 'Stock-only user changes cost price', 'stockonly', 'deny', null,
       null, $q$ with x as (update public.products set cost_price = 1 where id = 'prod-stg-nexus' returning 1) select count(*) from x $q$, null),
      (181, 'products', 'Stock-only user changes selling price', 'stockonly', 'deny', null,
       null, $q$ with x as (update public.products set selling_price = 1 where id = 'prod-stg-nexus' returning 1) select count(*) from x $q$, null),
      (182, 'products', 'Stock-only user still adjusts stock', 'stockonly', 'allow', null,
       null, $q$ select count(*) from (select public.adjust_stock('prod-stg-nexus', 3, 'Staging check')) s $q$, null),
      (183, 'products', 'CS changes product cost', 'cs', 'deny', null,
       null, $q$ with x as (update public.products set cost_price = 1 where id = 'prod-stg-nexus' returning 1) select count(*) from x $q$, null),
      (184, 'pricing', 'Inventory Staff changes a selling price', 'u-stg-inventory', 'deny', '%Super Admin or Manager%',
       null, $q$ with x as (update public.products set selling_price = 12.50 where id = 'prod-stg-nexus' returning 1) select count(*) from x $q$, null),
      (185, 'pricing', 'Inventory Staff changes a cost price', 'u-stg-inventory', 'deny', '%Super Admin or Manager%',
       null, $q$ with x as (update public.products set cost_price = 5 where id = 'prod-stg-nexus' returning 1) select count(*) from x $q$, null),
      (186, 'pricing', 'Inventory Staff edits catalogue fields', 'u-stg-inventory', 'allow', null,
       null, $q$ with x as (update public.products set description = 'Updated', low_stock_threshold = 8 where id = 'prod-stg-nexus' returning 1) select count(*) from x $q$, null),
      (187, 'pricing', 'Inventory Staff creates a priced product', 'u-stg-inventory', 'deny', '%Super Admin or Manager%',
       null, $q$ with x as (insert into public.products (id, name, category, cost_price, selling_price) values ('prod-stg-chk', 'Check Ball', 'Football', 5, 10) returning 1) select count(*) from x $q$, null),
      (188, 'pricing', 'Inventory Staff creates an unpriced product', 'u-stg-inventory', 'allow', null,
       null, $q$ with x as (insert into public.products (id, name, category) values ('prod-stg-chk', 'Check Ball', 'Football') returning 1) select count(*) from x $q$, null),
      (189, 'pricing', 'Manager changes selling price and cost', 'u-stg-ops', 'allow', null,
       null, $q$ with x as (update public.products set selling_price = 12.50, cost_price = 6.90 where id = 'prod-stg-nexus' returning 1) select count(*) from x $q$,
       $q$ select count(*) from public.products where id = 'prod-stg-nexus' and selling_price = 12.50 and cost_price = 6.90 $q$),
      (197, 'pricing', 'Super Admin changes a price', 'u-stg-admin', 'allow', null,
       null, $q$ with x as (update public.products set selling_price = 13 where id = 'prod-stg-nexus' returning 1) select count(*) from x $q$, null),
      (198, 'pricing', 'Officer changes a price', 'u-stg-officer1', 'deny', null,
       null, $q$ with x as (update public.products set selling_price = 1 where id = 'prod-stg-nexus' returning 1) select count(*) from x $q$, null),

      -- ---- deletion ---------------------------------------------------------
      (190, 'delete', 'Manager with delete_orders deletes a cancelled order', 'manager_del', 'deny', null,
       null, $q$ with x as (delete from public.orders where id = 'ORD-STG-1004' returning 1) select count(*) from x $q$, null),
      (191, 'delete', 'Super Admin deletes a delivered order', 'u-stg-admin', 'deny', '%Cancel order%',
       null, $q$ with x as (delete from public.orders where id = 'ORD-STG-1002' returning 1) select count(*) from x $q$, null),
      (192, 'delete', 'Super Admin deletes a cancelled order with payments', 'u-stg-admin', 'deny', '%recorded payments%',
       $q$ select public.update_order_status('ORD-STG-1001', 'cancelled', 'Staging check setup') $q$,
       $q$ with x as (delete from public.orders where id = 'ORD-STG-1001' returning 1) select count(*) from x $q$, null),
      (193, 'delete', 'Super Admin deletes a cancelled, unpaid order', 'u-stg-admin', 'allow', null,
       null, $q$ with x as (delete from public.orders where id = 'ORD-STG-1004' returning 1) select count(*) from x $q$,
       $q$ select case when exists (select 1 from public.orders where id = 'ORD-STG-1004') then 0 else 1 end $q$),
      (194, 'delete', 'Super Admin deletes a customer that has orders', 'u-stg-admin', 'deny', '%archive it instead%',
       null, $q$ with x as (delete from public.customers where id = 'cust-stg-alpha' returning 1) select count(*) from x $q$, null),
      (195, 'delete', 'Manager archives a customer that has orders', 'u-stg-manager', 'allow', null,
       null, $q$ with x as (update public.customers set status = 'archived' where id = 'cust-stg-alpha' returning 1) select count(*) from x $q$, null),

      -- ---- time zone: "today" is Mogadishu ----------------------------------
      (200, 'timezone', 'efz_today() is the Africa/Mogadishu date', 'u-stg-admin', 'allow', null,
       null, $q$ select count(*) where public.efz_today() = (now() at time zone 'Africa/Mogadishu')::date
                    and (timestamptz '2026-09-29 22:30:00+00' at time zone 'Africa/Mogadishu')::date = date '2026-09-30' $q$, null),
      (201, 'timezone', 'An order with no date gets today''s Mogadishu date', 'cs', 'allow', null,
       null, $q$ select count(*) from (select public.create_order('{"customerId":"cust-stg-delta","items":[{"productId":"prod-stg-fireball","quantity":1}]}')) s $q$,
       $q$ select count(*) from public.orders where customer_id = 'cust-stg-delta' and created_by = 'u-stg-inventory' and order_date = public.efz_today() $q$),
      (202, 'timezone', 'CS dates an order with today''s Mogadishu date', 'cs', 'allow', null,
       null, $q$ select count(*) from (select public.create_order(jsonb_build_object('customerId','cust-stg-delta','orderDate',public.efz_today()::text,'items',jsonb_build_array(jsonb_build_object('productId','prod-stg-fireball','quantity',1))))) s $q$, null),

      -- ---- cost visibility --------------------------------------------------
      (210, 'cost', 'CS reads products.cost_price', 'cs', 'deny', '%permission denied%',
       null, $q$ select count(cost_price) from public.products $q$, null),
      (211, 'cost', 'Officer reads orders.cost', 'u-stg-officer1', 'deny', '%permission denied%',
       null, $q$ select count(cost) from public.orders $q$, null),
      (212, 'cost', 'Officer reads order_items.historical_unit_cost', 'u-stg-officer1', 'deny', '%permission denied%',
       null, $q$ select count(historical_unit_cost) from public.order_items $q$, null),
      (213, 'cost', 'Delivery staff reads orders.gross_profit', 'u-stg-delivery', 'deny', '%permission denied%',
       null, $q$ select count(gross_profit) from public.orders $q$, null),
      (214, 'cost', 'CS reads order_details: rows yes, cost and profit NULL', 'cs', 'allow', null,
       null, $q$ select case when count(*) filter (where cost is not null or gross_profit is not null
                   or exists (select 1 from jsonb_array_elements(items) e
                               where e->'costPrice' <> 'null' or e->'historicalUnitCost' <> 'null' or e->'lineCost' <> 'null' or e->'lineProfit' <> 'null')) = 0
                 then count(*) end from public.order_details $q$, null),
      (215, 'cost', 'Officer reads order_details: cost and profit NULL', 'u-stg-officer1', 'allow', null,
       null, $q$ select case when count(*) filter (where cost is not null or gross_profit is not null) = 0 then count(*) end from public.order_details $q$, null),
      (216, 'cost', 'Manager reads order_details with cost', 'u-stg-ops', 'allow', null,
       null, $q$ select count(*) from public.order_details where cost is not null and gross_profit is not null and items->0->>'costPrice' is not null $q$, null),
      (217, 'cost', 'CS reads inventory_status: stock yes, cost and margin NULL', 'cs', 'allow', null,
       null, $q$ select case when count(*) filter (where cost_price is not null or unit_margin is not null or margin_percentage is not null or stock_value_at_cost is not null) = 0
                 then count(*) end from public.inventory_status $q$, null),
      (218, 'cost', 'Inventory Staff reads inventory_status with cost', 'u-stg-inventory', 'allow', null,
       null, $q$ select count(*) from public.inventory_status where cost_price is not null and margin_percentage is not null $q$, null),
      (219, 'cost', 'CS reads financial_summary: revenue yes, cost/profit/margin NULL', 'cs', 'allow', null,
       null, $q$ select count(*) from public.financial_summary where revenue_generated > 0 and total_cost is null and gross_profit is null and gross_margin is null $q$, null),
      (220, 'cost', 'Manager reads financial_summary with cost and margin', 'u-stg-ops', 'allow', null,
       null, $q$ select count(*) from public.financial_summary where total_cost > 0 and gross_profit is not null and gross_margin is not null $q$, null),
      (221, 'cost', 'CS reads staff_products: cost NULL', 'cs', 'allow', null,
       null, $q$ select case when count(*) filter (where cost_price is not null) = 0 then count(*) end from public.staff_products $q$, null),
      (222, 'cost', 'Inventory Staff reads staff_products with cost', 'u-stg-inventory', 'allow', null,
       null, $q$ select count(*) from public.staff_products where cost_price is not null $q$, null),
      (223, 'cost', 'Officer reads product_sales: cost and profit NULL', 'u-stg-officer1', 'allow', null,
       null, $q$ select case when count(*) filter (where cost is not null or profit is not null) = 0 then count(*) end from public.product_sales $q$, null),
      (224, 'cost', 'Officer reads daily_sales: cost and profit NULL', 'u-stg-officer1', 'allow', null,
       null, $q$ select case when count(*) filter (where cost is not null or gross_profit is not null) = 0 then count(*) end from public.daily_sales $q$, null),
      (225, 'cost', 'Officer reads below-cost approvals', 'u-stg-officer1', 'deny', null,
       $q$ select public.create_order('{"customerId":"cust-stg-alpha","belowCostReason":"Staging check setup","items":[{"productId":"prod-stg-nexus","quantity":1,"actualUnitPrice":5}]}') $q$,
       $q$ select count(*) from public.below_cost_overrides $q$, null),

      -- ---- the owner-rights views still honour row visibility ---------------
      (230, 'rows', 'Officer without view_orders sees exactly their own orders in order_details', 'officer_noview', 'allow', null,
       null, $q$ select case when (select count(*) from public.order_details) = (select count(*) from public.orders)
                            and (select count(*) from public.order_details where marketing_officer_id <> 'u-stg-officer1') = 0
                 then (select count(*) from public.order_details) end $q$, null),
      (231, 'rows', 'Officer without view_orders: financial_summary covers only their orders', 'officer_noview', 'allow', null,
       null, $q$ select count(*) from public.financial_summary
            where total_orders = (select count(*) from public.orders where status <> 'cancelled') $q$, null),
      (232, 'rows', 'CS sees every order in order_details', 'cs', 'allow', null,
       null, $q$ select case when (select count(*) from public.order_details) = (select count(*) from public.orders) then (select count(*) from public.orders) end $q$, null),
      (233, 'rows', 'Suspended officer reads order_details', 'u-stg-suspended', 'deny', null,
       null, $q$ select count(*) from public.order_details $q$, null),
      (234, 'rows', 'Suspended officer reads staff_products', 'u-stg-suspended', 'deny', null,
       null, $q$ select count(*) from public.staff_products $q$, null),
      (235, 'rows', 'Anon reads order_details', 'anon', 'deny', '%permission denied%',
       null, $q$ select count(*) from public.order_details $q$, null),
      (236, 'rows', 'Anon reads staff_products', 'anon', 'deny', '%permission denied%',
       null, $q$ select count(*) from public.staff_products $q$, null),
      (237, 'rows', 'Anon reads financial_summary', 'anon', 'deny', '%permission denied%',
       null, $q$ select count(*) from public.financial_summary $q$, null)
    ) as v(n, area, check_name, actor, expected, error_like, setup_sql, sql, verify_sql)
  loop
    v_count := null; v_verify := null; v_uid := null;
    v_outcome := null; v_detail := null;

    begin
      -- Setup runs as the SQL editor: no JWT, so the RPCs treat it as trusted.
      perform set_config('request.jwt.claim.sub', '', true);
      perform set_config('request.jwt.claims', '', true);

      v_profile := case t.actor
        when 'cs'             then 'u-stg-inventory'
        when 'stockonly'      then 'u-stg-delivery'
        when 'officer_noview' then 'u-stg-officer1'
        when 'manager_del'    then 'u-stg-manager'
        else t.actor
      end;

      if t.actor = 'cs' then
        update public.profiles set role = 'Customer Service' where id = 'u-stg-inventory';
        perform public.grant_role_preset('u-stg-inventory', 'Customer Service');
      elsif t.actor = 'stockonly' then
        perform public.set_user_permissions('u-stg-delivery', array['view_dashboard', 'view_products', 'view_inventory', 'adjust_stock']);
      elsif t.actor = 'officer_noview' then
        perform public.set_user_permissions('u-stg-officer1', array['create_orders', 'view_own_customers_only']);
      elsif t.actor = 'manager_del' then
        perform public.set_user_permissions('u-stg-manager',
          array(select permission_code from public.user_permissions where user_id = 'u-stg-manager') || array['delete_orders']);
      end if;

      if t.setup_sql is not null then
        execute t.setup_sql;
      end if;

      if t.actor <> 'anon' then
        select auth_user_id into v_uid from public.profiles where id = v_profile;
        if v_uid is null then
          v_outcome := 'skipped';
          v_detail  := 'No Auth user linked to ' || v_profile;
          raise exception using errcode = 'EZ000', message = 'efz staging check rollback';
        end if;
      end if;

      -- Act as the actor.
      if t.actor = 'anon' then
        perform set_config('request.jwt.claims', '{"role":"anon"}', true);
        perform set_config('role', 'anon', true);
      else
        perform set_config('request.jwt.claim.sub', v_uid::text, true);
        perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
        perform set_config('role', 'authenticated', true);
      end if;

      begin
        execute t.sql into v_count;
        v_outcome := case when coalesce(v_count, 0) > 0 then 'allowed' else 'no rows' end;
        v_detail  := 'rows: ' || coalesce(v_count, 0);
      exception when others then
        v_outcome := 'error';
        v_detail  := sqlerrm;
      end;

      -- Back to the SQL editor to check the effect.
      execute 'reset role';
      perform set_config('request.jwt.claim.sub', '', true);
      perform set_config('request.jwt.claims', '', true);

      if t.verify_sql is not null and v_outcome = 'allowed' then
        execute t.verify_sql into v_verify;
        v_detail := v_detail || ', verify: ' || coalesce(v_verify, 0);
      end if;

      raise exception using errcode = 'EZ000', message = 'efz staging check rollback';
    exception
      when sqlstate 'EZ000' then null;
      when others then
        v_outcome := 'harness error';
        v_detail  := sqlerrm;
    end;

    v_result := case
      when v_outcome = 'skipped' then 'SKIP'
      when t.expected = 'allow' and v_outcome = 'allowed'
           and (t.verify_sql is null or coalesce(v_verify, 0) > 0) then 'PASS'
      when t.expected = 'deny' and v_outcome = 'no rows' and t.error_like is null then 'PASS'
      when t.expected = 'deny' and v_outcome = 'error'
           and (t.error_like is null or v_detail ilike t.error_like) then 'PASS'
      else 'FAIL'
    end;

    insert into efz_checks_10
    values (v_run, t.n, t.area, t.check_name, t.actor, t.expected, v_outcome, v_result, v_detail);
  end loop;
end
$checks$;

select n, result, area, check_name, actor, expected, outcome, detail
  from efz_checks_10
 where run_at = (select max(run_at) from efz_checks_10)
 order by n;
