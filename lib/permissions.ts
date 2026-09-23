/**
 * Pure permission helpers.
 *
 * These decide what the UI *shows*. They are not a security boundary - the RLS
 * policies in supabase/03_rls.sql are, and they are evaluated again in the
 * database on every single request. Hiding a button here is a courtesy, not a
 * lock.
 *
 * Kept free of any storage import so every page can use it without dragging in
 * the legacy localStorage facade.
 */

import type { AdminProfile, Permission } from "@/lib/types";

export function hasPermission(
  profile: AdminProfile | null | undefined,
  permission: Permission
): boolean {
  if (!profile) return false;
  if (profile.status === "inactive") return false;
  if (profile.role === "Super Admin") return true;
  return profile.permissions?.includes(permission) ?? false;
}

export function hasAnyPermission(
  profile: AdminProfile | null | undefined,
  permissions: Permission[]
): boolean {
  return permissions.some((permission) => hasPermission(profile, permission));
}

export type PermissionFlags = ReturnType<typeof derivePermissions>;

/**
 * Every flag the admin pages need, from one profile.
 *
 *   const perms = derivePermissions(profile);
 *   {perms.addProducts && <Button>Add</Button>}
 */
export function derivePermissions(profile: AdminProfile | null | undefined) {
  const can = (permission: Permission) => hasPermission(profile, permission);

  const viewAllCustomers = can("view_all_customers");

  return {
    isSignedIn: Boolean(profile),
    isSuperAdmin: profile?.role === "Super Admin",

    viewDashboard: can("view_dashboard"),

    viewOrders: can("view_orders"),
    createOrders: can("create_orders"),
    editOrders: can("edit_orders"),
    deleteOrders: can("delete_orders"),
    overrideOrderStatus: can("override_order_status"),

    viewProducts: can("view_products"),
    addProducts: can("add_products"),
    editProducts: can("edit_products"),
    deleteProducts: can("delete_products"),

    viewInventory: can("view_inventory"),
    adjustStock: can("adjust_stock"),

    viewCustomers: can("view_customers"),
    addCustomers: can("add_customers"),
    editCustomers: can("edit_customers"),
    deleteCustomers: can("delete_customers"),
    viewAllCustomers,
    /** True only when the user is restricted to the customers they own. */
    viewOwnCustomersOnly: !viewAllCustomers && can("view_own_customers_only"),

    viewReports: can("view_reports"),
    viewCommissions: can("view_commissions"),
    markCommissionsPaid: can("mark_commissions_paid"),

    manageUsers: can("manage_users"),
    changeSettings: can("change_settings"),
    viewDiagnostics: can("view_diagnostics"),
    viewAuditTrail: can("view_audit_trail"),
    manageSystem: can("manage_system"),

    accessCustomerModule: hasAnyPermission(profile, ["view_customers", "view_own_customers_only"]),
    accessOrdersModule: hasAnyPermission(profile, ["view_orders", "create_orders"]),
  };
}
