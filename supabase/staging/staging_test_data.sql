-- ============================================================================
-- EFZ - STAGING TEST DATA  (synthetic - STAGING ONLY - NEVER RUN IN PRODUCTION)
-- ----------------------------------------------------------------------------
-- Run in EFZ-Staging after 01, 02, 03, 04, 05 and 07, BEFORE 08 and 09, so
-- the hardening migrations are applied to a database that already holds
-- data, exactly as they will be in production.
--
-- Everything here is invented: names, emails (example.com is a reserved
-- domain that never receives mail), phone numbers (+000 ...), customers.
-- No row comes from 06_data_import.sql or any backup.
--
-- Safety:
--   * Refuses to run unless profiles, customers, products, orders and
--     order_requests are ALL empty. Production is not empty, so this script
--     aborts there before writing anything.
--   * One DO block = one transaction: it either loads everything or nothing.
--   * No DELETE, UPDATE-of-existing-rows, TRUNCATE or DROP. Every row is
--     created through the same RPCs the app uses (create_order,
--     record_payment, update_order_status, adjust_stock, pay_commissions),
--     so totals, stock, the stock ledger and commissions are computed by the
--     database's own triggers.
--   * Not re-runnable by design: the emptiness check stops a second run.
--
-- What it creates
--   Staff (9)       Super Admin, user manager (manage_users), ops manager
--                   (view_diagnostics), 2 marketing officers, inventory,
--                   delivery, a SUSPENDED officer, and an active profile with
--                   no login (for the "staff without sign-in" diagnostic).
--   Customers (7)   5 that own the baseline orders, 1 extra, 1 with no officer.
--   Products (5)    Nexus, Fire Ball, a low-stock ball, an out-of-stock ball,
--                   and a ball priced below cost.
--   Orders (11)     STG-BASE-01..07: 7 synthetic orders that reproduce the
--                   approved historical baseline's signed-off totals (7
--                   orders, 11 units, $119.00, $73.70 cost, $45.30 profit,
--                   38.07%) under neutral ids and dates - no real order id,
--                   customer or date is used. Plus: partially paid,
--                   delivered-but-unpaid, pending, and cancelled.
--                   Validate with staging_validate_financials.sql, which is
--                   keyed to these ids.
--   Payments        full, partial and none.
--   Commissions     pending and paid (one payout).
--   Order request   1 website request with status 'new'.
-- ============================================================================

do $staging$
declare
  v_commissions uuid[];
begin
  -- ---------------------------------------------------------------------
  -- Safety gate
  -- ---------------------------------------------------------------------
  if exists (select 1 from public.profiles)
     or exists (select 1 from public.customers)
     or exists (select 1 from public.products)
     or exists (select 1 from public.orders)
     or exists (select 1 from public.order_requests) then
    raise exception 'STAGING TEST DATA ABORTED: this database already contains business rows. This script only runs on an empty EFZ-Staging database.';
  end if;

  if not exists (select 1 from public.permissions where code = 'manage_users') then
    raise exception 'STAGING TEST DATA ABORTED: run 05_seed.sql first (permission catalog missing).';
  end if;

  -- ---------------------------------------------------------------------
  -- Staff. Auth accounts are created afterwards in the dashboard with the
  -- same emails; the link trigger attaches them.
  -- ---------------------------------------------------------------------
  insert into public.profiles (id, name, email, phone, role, status, commission_percentage) values
    ('u-stg-admin',     'Test Super Admin',        'efz.superadmin@example.com', '+000 000 0001', 'Super Admin',       'active',    0),
    ('u-stg-manager',   'Test User Manager',       'efz.manager@example.com',    '+000 000 0002', 'Manager',           'active',    0),
    ('u-stg-ops',       'Test Ops Manager',        'efz.ops@example.com',        '+000 000 0003', 'Manager',           'active',    0),
    ('u-stg-officer1',  'Test Officer One',        'efz.officer1@example.com',   '+000 000 0004', 'Marketing Officer', 'active',    5),
    ('u-stg-officer2',  'Test Officer Two',        'efz.officer2@example.com',   '+000 000 0005', 'Marketing Officer', 'active',   10),
    ('u-stg-inventory', 'Test Inventory Staff',    'efz.inventory@example.com',  '+000 000 0006', 'Inventory Staff',   'active',    0),
    ('u-stg-delivery',  'Test Delivery Staff',     'efz.delivery@example.com',   '+000 000 0007', 'Delivery Staff',    'active',    0),
    ('u-stg-suspended', 'Test Suspended Officer',  'efz.suspended@example.com',  '+000 000 0008', 'Marketing Officer', 'inactive',  5),
    ('u-stg-nologin',   'Test Staff Without Login','efz.nologin@example.com',    '+000 000 0009', 'Inventory Staff',   'active',    0);

  perform public.grant_role_preset('u-stg-manager',   'Manager');
  perform public.grant_role_preset('u-stg-ops',       'Manager');
  perform public.grant_role_preset('u-stg-officer1',  'Marketing Officer');
  perform public.grant_role_preset('u-stg-officer2',  'Marketing Officer');
  perform public.grant_role_preset('u-stg-inventory', 'Inventory Staff');
  perform public.grant_role_preset('u-stg-delivery',  'Delivery Staff');
  perform public.grant_role_preset('u-stg-suspended', 'Marketing Officer');
  perform public.grant_role_preset('u-stg-nologin',   'Inventory Staff');

  -- The user manager: Manager preset + manage_users (a non-Super-Admin admin).
  perform public.set_user_permissions('u-stg-manager',
    array(select permission_code from public.user_permissions where user_id = 'u-stg-manager')
    || array['manage_users']);

  -- The ops manager: Manager preset + view_diagnostics, but NOT manage_users.
  perform public.set_user_permissions('u-stg-ops',
    array(select permission_code from public.user_permissions where user_id = 'u-stg-ops')
    || array['view_diagnostics']);

  -- ---------------------------------------------------------------------
  -- Customers
  -- ---------------------------------------------------------------------
  insert into public.customers (id, name, email, phone, registered_by, marketing_officer_id, registered_on, notes) values
    ('cust-stg-alpha',   'Test Club Alpha',    'alpha@example.com',   '+000 100 0001', 'u-stg-officer1', 'u-stg-officer1', '2026-08-01', 'Synthetic'),
    ('cust-stg-bravo',   'Test Club Bravo',    'bravo@example.com',   '+000 100 0002', 'u-stg-officer1', 'u-stg-officer1', '2026-08-01', 'Synthetic'),
    ('cust-stg-charlie', 'Test Arena Charlie', 'charlie@example.com', '+000 100 0003', 'u-stg-officer2', 'u-stg-officer2', '2026-08-02', 'Synthetic'),
    ('cust-stg-delta',   'Test Academy Delta', 'delta@example.com',   '+000 100 0004', 'u-stg-officer2', 'u-stg-officer2', '2026-08-02', 'Synthetic'),
    ('cust-stg-echo',    'Test Buyer Echo',    'echo@example.com',    '+000 100 0005', 'u-stg-officer1', 'u-stg-officer1', '2026-08-03', 'Synthetic'),
    ('cust-stg-foxtrot', 'Test Club Foxtrot',  'foxtrot@example.com', '+000 100 0006', 'u-stg-officer2', 'u-stg-officer2', '2026-09-01', 'Synthetic'),
    -- No officer and no registrar (create_order falls back to registered_by):
    -- raises the "customers without officer" diagnostic.
    ('cust-stg-golf',    'Test Walk-in Golf',  'golf@example.com',    '+000 100 0007', null,             null,             '2026-09-02', 'Synthetic');

  -- ---------------------------------------------------------------------
  -- Products. Created with stock 0 and stocked through adjust_stock(), so
  -- the movement ledger reconciles with products.stock.
  -- ---------------------------------------------------------------------
  insert into public.products (id, name, description, category, cost_price, selling_price, stock, low_stock_threshold) values
    ('prod-stg-nexus',     'EFZ - Nexus',             'Synthetic staging product', 'Football',    6.70, 12.00, 0,  5),
    ('prod-stg-fireball',  'EFZ - Fire Ball',         'Synthetic staging product', 'Futsal',      6.70, 12.00, 0,  5),
    ('prod-stg-training',  'EFZ - Training Ball',     'Synthetic: low stock',      'Football',    4.00,  8.00, 0, 10),
    ('prod-stg-pro',       'EFZ - Futsal Pro',        'Synthetic: out of stock',   'Futsal',      9.00, 18.00, 0,  5),
    ('prod-stg-clearance', 'EFZ - Clearance Ball',    'Synthetic: priced below cost', 'Accessories', 9.00, 8.00, 0, 5);

  perform public.adjust_stock('prod-stg-nexus',     100, 'Staging opening stock', 'import');
  perform public.adjust_stock('prod-stg-fireball',  100, 'Staging opening stock', 'import');
  perform public.adjust_stock('prod-stg-training',    6, 'Staging opening stock', 'import');
  perform public.adjust_stock('prod-stg-clearance',  20, 'Staging opening stock', 'import');
  -- prod-stg-pro stays at 0: raises the "out of stock" diagnostic.

  -- ---------------------------------------------------------------------
  -- Orders 1-7: STG-BASE-01..07, the baseline totals under neutral ids.
  -- Line prices are invented but sum to the signed-off figures:
  --   Nexus 6 units $65.50, Fire Ball 5 units $53.50, cost 11 x $6.70.
  -- ---------------------------------------------------------------------
  perform public.create_order('{"id":"STG-BASE-01","customerId":"cust-stg-alpha","marketingOfficerId":"u-stg-officer1","orderDate":"2026-08-01",
    "items":[{"productId":"prod-stg-nexus","quantity":1,"actualUnitPrice":10},{"productId":"prod-stg-fireball","quantity":1,"actualUnitPrice":10}]}');
  perform public.create_order('{"id":"STG-BASE-02","customerId":"cust-stg-alpha","marketingOfficerId":"u-stg-officer1","orderDate":"2026-08-02",
    "items":[{"productId":"prod-stg-nexus","quantity":1,"actualUnitPrice":10},{"productId":"prod-stg-fireball","quantity":1,"actualUnitPrice":10}]}');
  perform public.create_order('{"id":"STG-BASE-03","customerId":"cust-stg-bravo","marketingOfficerId":"u-stg-officer1","orderDate":"2026-08-03","orderType":"trial",
    "items":[{"productId":"prod-stg-fireball","quantity":1,"actualUnitPrice":10}]}');
  perform public.create_order('{"id":"STG-BASE-04","customerId":"cust-stg-bravo","marketingOfficerId":"u-stg-officer1","orderDate":"2026-08-04",
    "items":[{"productId":"prod-stg-fireball","quantity":1,"actualUnitPrice":12.5},{"productId":"prod-stg-nexus","quantity":1,"actualUnitPrice":9.5}]}');
  perform public.create_order('{"id":"STG-BASE-05","customerId":"cust-stg-charlie","marketingOfficerId":"u-stg-officer2","orderDate":"2026-08-05",
    "items":[{"productId":"prod-stg-nexus","quantity":2,"actualUnitPrice":11.5}]}');
  perform public.create_order('{"id":"STG-BASE-06","customerId":"cust-stg-delta","marketingOfficerId":"u-stg-officer2","orderDate":"2026-08-06",
    "items":[{"productId":"prod-stg-fireball","quantity":1,"actualUnitPrice":11}]}');
  perform public.create_order('{"id":"STG-BASE-07","customerId":"cust-stg-echo","marketingOfficerId":"u-stg-officer1","orderDate":"2026-08-07",
    "items":[{"productId":"prod-stg-nexus","quantity":1,"actualUnitPrice":13}]}');

  -- Walk every baseline order through the real status machine and pay it in full.
  perform public.update_order_status(o, 'confirmed',  'Staging') from unnest(array[
    'STG-BASE-01','STG-BASE-02','STG-BASE-03','STG-BASE-04','STG-BASE-05','STG-BASE-06','STG-BASE-07']) as o;
  perform public.update_order_status(o, 'processing', 'Staging') from unnest(array[
    'STG-BASE-01','STG-BASE-02','STG-BASE-03','STG-BASE-04','STG-BASE-05','STG-BASE-06','STG-BASE-07']) as o;
  perform public.update_order_status(o, 'delivered',  'Staging') from unnest(array[
    'STG-BASE-01','STG-BASE-02','STG-BASE-03','STG-BASE-04','STG-BASE-05','STG-BASE-06','STG-BASE-07']) as o;
  perform public.record_payment(id, total, 'Cash', '2026-09-01', 'STG-' || id, 'Synthetic payment')
     from public.orders
    where id in ('STG-BASE-01','STG-BASE-02','STG-BASE-03','STG-BASE-04','STG-BASE-05','STG-BASE-06','STG-BASE-07');

  -- ---------------------------------------------------------------------
  -- Orders 8-11: the other states the app has to handle
  -- ---------------------------------------------------------------------
  -- Partially paid: confirmed, 3 x Nexus @ 12 = 36.00, paid 20.00, owes 16.00.
  perform public.create_order('{"id":"ORD-STG-1001","customerId":"cust-stg-foxtrot","orderDate":"2026-09-10",
    "items":[{"productId":"prod-stg-nexus","quantity":3}]}');
  perform public.update_order_status('ORD-STG-1001', 'confirmed', 'Staging');
  perform public.record_payment('ORD-STG-1001', 20, 'Cash', '2026-09-11', 'STG-PARTIAL', 'Synthetic partial payment');

  -- Delivered but unpaid: 2 x Fire Ball @ 12 = 24.00 outstanding.
  perform public.create_order('{"id":"ORD-STG-1002","customerId":"cust-stg-charlie","orderDate":"2026-09-12",
    "items":[{"productId":"prod-stg-fireball","quantity":2}]}');
  perform public.update_order_status('ORD-STG-1002', 'confirmed',  'Staging');
  perform public.update_order_status('ORD-STG-1002', 'processing', 'Staging');
  perform public.update_order_status('ORD-STG-1002', 'delivered',  'Staging');

  -- Pending, no officer (walk-in customer), no payment: 1 x Training Ball.
  perform public.create_order('{"id":"ORD-STG-1003","customerId":"cust-stg-golf","orderDate":"2026-09-15",
    "items":[{"productId":"prod-stg-training","quantity":1}]}');

  -- Cancelled: stock goes back to the shelf, its commission is voided.
  perform public.create_order('{"id":"ORD-STG-1004","customerId":"cust-stg-alpha","orderDate":"2026-09-16",
    "items":[{"productId":"prod-stg-nexus","quantity":1}]}');
  perform public.update_order_status('ORD-STG-1004', 'confirmed', 'Staging');
  perform public.update_order_status('ORD-STG-1004', 'cancelled', 'Staging');

  -- ---------------------------------------------------------------------
  -- Commissions: pay Officer One for STG-BASE-01 and -02; everything else stays
  -- pending, so both states exist.
  -- ---------------------------------------------------------------------
  select array_agg(id) into v_commissions
    from public.commissions
   where user_id = 'u-stg-officer1'
     and order_id in ('STG-BASE-01', 'STG-BASE-02')
     and status = 'pending';

  perform public.pay_commissions('u-stg-officer1', v_commissions, 'Cash', 'STG-PAYOUT-1', 'Synthetic payout');

  -- ---------------------------------------------------------------------
  -- One website order request, as if submitted from /order.
  -- ---------------------------------------------------------------------
  insert into public.order_requests (id, customer_name, phone, organization, product_id, product_name,
                                     quantity, delivery_location, notes)
  values ('00000000-0000-4000-8000-000000000001', 'Test Website Visitor', '+000 200 0001',
          'Test Futsal Club', 'prod-stg-nexus', 'EFZ - Nexus', 4, 'Test City', 'Synthetic request');

  raise notice 'EFZ staging test data loaded.';
end
$staging$;

-- Summary of what was loaded (read-only).
select 'profiles' as table_name, count(*) as rows from public.profiles
union all select 'user_permissions', count(*) from public.user_permissions
union all select 'customers',        count(*) from public.customers
union all select 'products',         count(*) from public.products
union all select 'stock_movements',  count(*) from public.stock_movements
union all select 'orders',           count(*) from public.orders
union all select 'order_items',      count(*) from public.order_items
union all select 'payments',         count(*) from public.payments
union all select 'commissions',      count(*) from public.commissions
union all select 'commission_payouts', count(*) from public.commission_payouts
union all select 'order_requests',   count(*) from public.order_requests
union all select 'system_logs',      count(*) from public.system_logs;
