-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 5 of 5 : Reference data seed
-- ----------------------------------------------------------------------------
-- Safe to re-run. Everything here is an upsert.
-- This file seeds reference data only. Your real business records come from
-- scripts/generate-supabase-import.mjs (see supabase/README.md).
-- ============================================================================

-- ============================================================================
-- 1. PERMISSION CATALOG
-- ----------------------------------------------------------------------------
-- These 26 codes are the exact contents of OFFICIAL_PERMISSIONS in
-- lib/types/index.ts. Adding a code here and to that array is all it takes to
-- introduce a new permission.
-- ============================================================================

insert into public.permissions (code, label, category, sort_order) values
  ('view_dashboard',          'View dashboard',              'Dashboard',  10),

  ('view_orders',             'View orders',                 'Orders',     20),
  ('create_orders',           'Create orders',               'Orders',     21),
  ('edit_orders',             'Edit orders',                 'Orders',     22),
  ('delete_orders',           'Delete orders',               'Orders',     23),
  ('override_order_status',   'Override order status',       'Orders',     24),

  ('view_products',           'View products',               'Products',   30),
  ('add_products',            'Add products',                'Products',   31),
  ('edit_products',           'Edit products',               'Products',   32),
  ('delete_products',         'Delete products',             'Products',   33),

  ('view_inventory',          'View inventory',              'Inventory',  40),
  ('adjust_stock',            'Adjust stock',                'Inventory',  41),

  ('view_customers',          'View customers',              'Customers',  50),
  ('add_customers',           'Add customers',               'Customers',  51),
  ('edit_customers',          'Edit customers',              'Customers',  52),
  ('delete_customers',        'Delete customers',            'Customers',  53),
  ('view_all_customers',      'View all customers',          'Customers',  54),
  ('view_own_customers_only', 'View own customers only',     'Customers',  55),

  ('view_reports',            'View reports',                'Finance',    60),
  ('view_commissions',        'View commissions',            'Finance',    61),
  ('mark_commissions_paid',   'Mark commissions paid',       'Finance',    62),

  ('manage_users',            'Manage users',                'System',     70),
  ('change_settings',         'Change settings',             'System',     71),
  ('view_diagnostics',        'View diagnostics',            'System',     72),
  ('view_audit_trail',        'View audit trail',            'System',     73),
  ('manage_system',           'Manage system',               'System',     74)
on conflict (code) do update
  set label      = excluded.label,
      category   = excluded.category,
      sort_order = excluded.sort_order;

-- ============================================================================
-- 2. SETTINGS - the single settings row
-- ----------------------------------------------------------------------------
-- Values carried over from efz_mock_settings in the 2026-09-09 backup.
-- ============================================================================

insert into public.settings (
  id, business_name, short_name, logo, favicon,
  whatsapp_number, contact_email, default_low_stock_threshold,
  currency_symbol, theme, primary_color, secondary_color
) values (
  true, 'Elite Football Zone', 'EFZ', '', '',
  '+252 61 2829989', 'sales@efz.so', 50,
  '$', 'light', '#0F172A', '#00E676'
)
on conflict (id) do nothing;

-- ============================================================================
-- 3. TESTIMONIALS - replaces MOCK_TESTIMONIALS in lib/data.ts
-- ============================================================================

insert into public.testimonials (id, name, role, content, sort_order) values
  ('t1', 'Ahmed Ali', 'Arena Manager, Mogadishu',
   'EFZ futsal balls have significantly reduced our replacement costs. They withstand daily heavy use perfectly.', 1),
  ('t2', 'Hassan Sports Academy', 'Football School',
   'The quality of the Pro Match footballs is unmatched. Our players love the feel and precision.', 2),
  ('t3', 'Somali Futsal League', 'Tournament Organizer',
   'We use EFZ for all our official matches. The low bounce and durability are exactly what we need.', 3)
on conflict (id) do update
  set name       = excluded.name,
      role       = excluded.role,
      content    = excluded.content,
      sort_order = excluded.sort_order;

-- ============================================================================
-- 4. ROLE PERMISSION PRESETS
-- ----------------------------------------------------------------------------
-- grant_role_preset() applies a sensible default permission set for a role.
-- Super Admin is not listed: has_permission() short-circuits for that role, so
-- a Super Admin needs no rows in user_permissions at all.
-- ============================================================================

create or replace function public.grant_role_preset(p_user_id text, p_role public.user_role)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_codes text[];
begin
  v_codes := case p_role
    when 'Super Admin' then array[]::text[]   -- bypasses permission checks entirely

    when 'Manager' then array[
      'view_dashboard',
      'view_orders', 'create_orders', 'edit_orders',
      'view_products', 'add_products', 'edit_products',
      'view_inventory', 'adjust_stock',
      'view_customers', 'add_customers', 'edit_customers', 'view_all_customers',
      'view_reports', 'view_commissions', 'mark_commissions_paid',
      'view_audit_trail'
    ]

    when 'Marketing Officer' then array[
      'view_dashboard',
      'view_orders', 'create_orders',
      'view_products',
      'add_customers', 'edit_customers', 'view_own_customers_only',
      'view_commissions'
    ]

    when 'Inventory Staff' then array[
      'view_dashboard',
      'view_orders',
      'view_products', 'add_products', 'edit_products',
      'view_inventory', 'adjust_stock'
    ]

    when 'Delivery Staff' then array[
      'view_dashboard',
      'view_orders', 'edit_orders',
      'view_customers'
    ]
  end;

  perform public.set_user_permissions(p_user_id, v_codes);
end;
$fn$;

revoke all on function public.grant_role_preset(text, public.user_role) from public, anon;
grant execute on function public.grant_role_preset(text, public.user_role) to authenticated;
