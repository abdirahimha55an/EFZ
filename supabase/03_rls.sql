-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 3 of 5 : Row Level Security
-- ----------------------------------------------------------------------------
-- Every table is deny-by-default. Access is granted through the permission
-- codes in public.permissions, checked by public.has_permission().
--
-- Three Postgres roles matter here:
--   anon          - the public website visitor (not signed in)
--   authenticated - a signed-in staff member
--   service_role  - server-side key; bypasses RLS entirely, never ship to a browser
--
-- The RPCs in 02_functions.sql are SECURITY DEFINER, so they intentionally run
-- past these policies. Their own permission checks are what gate them.
-- ============================================================================

alter table public.profiles           enable row level security;
alter table public.permissions        enable row level security;
alter table public.user_permissions   enable row level security;
alter table public.customers          enable row level security;
alter table public.products           enable row level security;
alter table public.stock_movements    enable row level security;
alter table public.orders             enable row level security;
alter table public.order_items        enable row level security;
alter table public.payments           enable row level security;
alter table public.order_requests     enable row level security;
alter table public.commissions        enable row level security;
alter table public.commission_payouts enable row level security;
alter table public.system_logs        enable row level security;
alter table public.system_issues      enable row level security;
alter table public.notifications      enable row level security;
alter table public.settings           enable row level security;
alter table public.backups            enable row level security;
alter table public.testimonials       enable row level security;

-- ============================================================================
-- PROFILES
-- ----------------------------------------------------------------------------
-- This is an internal staff tool, so any signed-in staff member can read the
-- staff directory (order lists show officer names). Writes need manage_users.
-- ============================================================================

drop policy if exists profiles_select   on public.profiles;
drop policy if exists profiles_insert   on public.profiles;
drop policy if exists profiles_update   on public.profiles;
drop policy if exists profiles_delete   on public.profiles;

create policy profiles_select on public.profiles
  for select to authenticated
  using (true);

create policy profiles_insert on public.profiles
  for insert to authenticated
  with check (public.has_permission('manage_users'));

-- A user may always edit their own row; editing anyone else needs manage_users.
create policy profiles_update on public.profiles
  for update to authenticated
  using (auth_user_id = auth.uid() or public.has_permission('manage_users'))
  with check (auth_user_id = auth.uid() or public.has_permission('manage_users'));

create policy profiles_delete on public.profiles
  for delete to authenticated
  using (public.has_permission('manage_users') and auth_user_id is distinct from auth.uid());

-- ============================================================================
-- PERMISSIONS CATALOG
-- ============================================================================

drop policy if exists permissions_select on public.permissions;
drop policy if exists permissions_write  on public.permissions;

create policy permissions_select on public.permissions
  for select to authenticated using (true);

create policy permissions_write on public.permissions
  for all to authenticated
  using (public.is_super_admin())
  with check (public.is_super_admin());

drop policy if exists user_permissions_select on public.user_permissions;
drop policy if exists user_permissions_write  on public.user_permissions;

create policy user_permissions_select on public.user_permissions
  for select to authenticated using (true);

create policy user_permissions_write on public.user_permissions
  for all to authenticated
  using (public.has_permission('manage_users'))
  with check (public.has_permission('manage_users'));

-- ============================================================================
-- CUSTOMERS
-- ----------------------------------------------------------------------------
-- view_all_customers / view_customers see everyone.
-- view_own_customers_only sees only the customers they own.
-- ============================================================================

drop policy if exists customers_select on public.customers;
drop policy if exists customers_insert on public.customers;
drop policy if exists customers_update on public.customers;
drop policy if exists customers_delete on public.customers;

create policy customers_select on public.customers
  for select to authenticated
  using (
    public.has_permission('view_all_customers')
    or public.has_permission('view_customers')
    or (
      public.has_permission('view_own_customers_only')
      and (
        marketing_officer_id = public.current_profile_id()
        or registered_by     = public.current_profile_id()
      )
    )
  );

create policy customers_insert on public.customers
  for insert to authenticated
  with check (public.has_permission('add_customers'));

create policy customers_update on public.customers
  for update to authenticated
  using (
    public.has_permission('edit_customers')
    and (
      public.has_permission('view_all_customers')
      or public.has_permission('view_customers')
      or marketing_officer_id = public.current_profile_id()
      or registered_by       = public.current_profile_id()
    )
  )
  with check (public.has_permission('edit_customers'));

create policy customers_delete on public.customers
  for delete to authenticated
  using (public.has_permission('delete_customers'));

-- ============================================================================
-- PRODUCTS
-- ----------------------------------------------------------------------------
-- The public site reads active products. Cost price is hidden from anon by the
-- public_products view in 04_views.sql - never select * as anon.
-- ============================================================================

drop policy if exists products_select_public on public.products;
drop policy if exists products_select_staff  on public.products;
drop policy if exists products_insert        on public.products;
drop policy if exists products_update        on public.products;
drop policy if exists products_delete        on public.products;

create policy products_select_public on public.products
  for select to anon
  using (is_active);

create policy products_select_staff on public.products
  for select to authenticated
  using (true);

create policy products_insert on public.products
  for insert to authenticated
  with check (public.has_permission('add_products'));

create policy products_update on public.products
  for update to authenticated
  using (public.has_permission('edit_products') or public.has_permission('adjust_stock'))
  with check (public.has_permission('edit_products') or public.has_permission('adjust_stock'));

create policy products_delete on public.products
  for delete to authenticated
  using (public.has_permission('delete_products'));

-- ============================================================================
-- STOCK MOVEMENTS - append-only ledger
-- ============================================================================

drop policy if exists stock_movements_select on public.stock_movements;
drop policy if exists stock_movements_insert on public.stock_movements;

create policy stock_movements_select on public.stock_movements
  for select to authenticated
  using (public.has_any_permission(array['view_inventory', 'view_products', 'view_reports']));

create policy stock_movements_insert on public.stock_movements
  for insert to authenticated
  with check (public.has_permission('adjust_stock'));

-- No update or delete policy: the inventory ledger is immutable.

-- ============================================================================
-- ORDERS
-- ============================================================================

drop policy if exists orders_select on public.orders;
drop policy if exists orders_insert on public.orders;
drop policy if exists orders_update on public.orders;
drop policy if exists orders_delete on public.orders;

create policy orders_select on public.orders
  for select to authenticated
  using (
    public.has_permission('view_orders')
    or marketing_officer_id = public.current_profile_id()
  );

create policy orders_insert on public.orders
  for insert to authenticated
  with check (public.has_permission('create_orders'));

create policy orders_update on public.orders
  for update to authenticated
  using (
    public.has_permission('edit_orders')
    and (commission_paid = false or public.has_permission('override_order_status'))
  )
  with check (public.has_permission('edit_orders'));

create policy orders_delete on public.orders
  for delete to authenticated
  using (
    public.has_permission('delete_orders')
    and (commission_paid = false or public.is_super_admin())
  );

-- ============================================================================
-- ORDER ITEMS and PAYMENTS - visibility follows the parent order
-- ============================================================================

drop policy if exists order_items_select on public.order_items;
drop policy if exists order_items_write  on public.order_items;

create policy order_items_select on public.order_items
  for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id));

create policy order_items_write on public.order_items
  for all to authenticated
  using (
    public.has_permission('edit_orders')
    and exists (select 1 from public.orders o where o.id = order_id)
  )
  with check (
    public.has_any_permission(array['create_orders', 'edit_orders'])
    and exists (select 1 from public.orders o where o.id = order_id)
  );

drop policy if exists payments_select on public.payments;
drop policy if exists payments_insert on public.payments;
drop policy if exists payments_update on public.payments;
drop policy if exists payments_delete on public.payments;

create policy payments_select on public.payments
  for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id));

create policy payments_insert on public.payments
  for insert to authenticated
  with check (public.has_any_permission(array['create_orders', 'edit_orders']));

-- A recorded payment can only be corrected by a Super Admin.
create policy payments_update on public.payments
  for update to authenticated
  using (public.is_super_admin())
  with check (public.is_super_admin());

create policy payments_delete on public.payments
  for delete to authenticated
  using (public.is_super_admin());

-- ============================================================================
-- ORDER REQUESTS - the public order form writes here
-- ============================================================================

drop policy if exists order_requests_insert_public on public.order_requests;
drop policy if exists order_requests_select        on public.order_requests;
drop policy if exists order_requests_update        on public.order_requests;

-- Anyone may submit. They may never read back what anyone else submitted.
create policy order_requests_insert_public on public.order_requests
  for insert to anon, authenticated
  with check (true);

create policy order_requests_select on public.order_requests
  for select to authenticated
  using (public.has_permission('view_orders'));

create policy order_requests_update on public.order_requests
  for update to authenticated
  using (public.has_permission('edit_orders'))
  with check (public.has_permission('edit_orders'));

-- ============================================================================
-- COMMISSIONS - an officer can always see their own
-- ============================================================================

drop policy if exists commissions_select on public.commissions;
drop policy if exists commissions_update on public.commissions;

create policy commissions_select on public.commissions
  for select to authenticated
  using (
    public.has_permission('view_commissions')
    or user_id = public.current_profile_id()
  );

create policy commissions_update on public.commissions
  for update to authenticated
  using (public.has_permission('mark_commissions_paid'))
  with check (public.has_permission('mark_commissions_paid'));

drop policy if exists commission_payouts_select on public.commission_payouts;
drop policy if exists commission_payouts_insert on public.commission_payouts;

create policy commission_payouts_select on public.commission_payouts
  for select to authenticated
  using (
    public.has_permission('view_commissions')
    or user_id = public.current_profile_id()
  );

create policy commission_payouts_insert on public.commission_payouts
  for insert to authenticated
  with check (public.has_permission('mark_commissions_paid'));

-- ============================================================================
-- SYSTEM LOGS - append-only audit trail
-- ============================================================================

drop policy if exists system_logs_select on public.system_logs;
drop policy if exists system_logs_insert on public.system_logs;

create policy system_logs_select on public.system_logs
  for select to authenticated
  using (public.has_permission('view_audit_trail'));

-- Any signed-in staff member may write a log line; nobody may edit or erase one.
create policy system_logs_insert on public.system_logs
  for insert to authenticated
  with check (true);

-- ============================================================================
-- SYSTEM ISSUES
-- ============================================================================

drop policy if exists system_issues_select on public.system_issues;
drop policy if exists system_issues_write  on public.system_issues;

create policy system_issues_select on public.system_issues
  for select to authenticated
  using (public.has_permission('view_diagnostics'));

create policy system_issues_write on public.system_issues
  for all to authenticated
  using (public.has_permission('manage_system'))
  with check (public.has_permission('manage_system'));

-- ============================================================================
-- NOTIFICATIONS - own inbox plus broadcasts (user_id is null)
-- ============================================================================

drop policy if exists notifications_select on public.notifications;
drop policy if exists notifications_insert on public.notifications;
drop policy if exists notifications_update on public.notifications;
drop policy if exists notifications_delete on public.notifications;

create policy notifications_select on public.notifications
  for select to authenticated
  using (user_id is null or user_id = public.current_profile_id());

create policy notifications_insert on public.notifications
  for insert to authenticated
  with check (true);

create policy notifications_update on public.notifications
  for update to authenticated
  using (user_id is null or user_id = public.current_profile_id())
  with check (user_id is null or user_id = public.current_profile_id());

create policy notifications_delete on public.notifications
  for delete to authenticated
  using (user_id = public.current_profile_id() or public.has_permission('manage_system'));

-- ============================================================================
-- SETTINGS - the public site needs the business name, logo and WhatsApp number
-- ============================================================================

drop policy if exists settings_select on public.settings;
drop policy if exists settings_update on public.settings;
drop policy if exists settings_insert on public.settings;

create policy settings_select on public.settings
  for select to anon, authenticated
  using (true);

create policy settings_update on public.settings
  for update to authenticated
  using (public.has_permission('change_settings'))
  with check (public.has_permission('change_settings'));

create policy settings_insert on public.settings
  for insert to authenticated
  with check (public.has_permission('change_settings'));

-- ============================================================================
-- BACKUPS
-- ============================================================================

drop policy if exists backups_all on public.backups;

create policy backups_all on public.backups
  for all to authenticated
  using (public.has_permission('manage_system'))
  with check (public.has_permission('manage_system'));

-- ============================================================================
-- TESTIMONIALS - public marketing content
-- ============================================================================

drop policy if exists testimonials_select_public on public.testimonials;
drop policy if exists testimonials_select_staff  on public.testimonials;
drop policy if exists testimonials_write         on public.testimonials;

create policy testimonials_select_public on public.testimonials
  for select to anon
  using (is_published);

create policy testimonials_select_staff on public.testimonials
  for select to authenticated
  using (true);

create policy testimonials_write on public.testimonials
  for all to authenticated
  using (public.has_permission('change_settings'))
  with check (public.has_permission('change_settings'));

-- ============================================================================
-- EXECUTE GRANTS on the RPCs
-- ============================================================================

revoke all on function public.create_order(jsonb)                              from public, anon;
revoke all on function public.record_payment(text, numeric, text, date, text, text) from public, anon;
revoke all on function public.update_order_status(text, public.order_status, text)  from public, anon;
revoke all on function public.adjust_stock(text, integer, text, public.stock_movement_type) from public, anon;
revoke all on function public.pay_commissions(text, uuid[], text, text, text)  from public, anon;
revoke all on function public.set_user_permissions(text, text[])               from public, anon;
revoke all on function public.convert_order_request(uuid, text)                from public, anon;

grant execute on function public.create_order(jsonb)                              to authenticated;
grant execute on function public.record_payment(text, numeric, text, date, text, text) to authenticated;
grant execute on function public.update_order_status(text, public.order_status, text)  to authenticated;
grant execute on function public.adjust_stock(text, integer, text, public.stock_movement_type) to authenticated;
grant execute on function public.pay_commissions(text, uuid[], text, text, text)  to authenticated;
grant execute on function public.set_user_permissions(text, text[])               to authenticated;
grant execute on function public.convert_order_request(uuid, text)                to authenticated;

grant execute on function public.current_profile_id()          to authenticated;
grant execute on function public.current_profile_role()        to authenticated;
grant execute on function public.is_super_admin()              to authenticated;
grant execute on function public.has_permission(text)          to authenticated;
grant execute on function public.has_any_permission(text[])    to authenticated;
