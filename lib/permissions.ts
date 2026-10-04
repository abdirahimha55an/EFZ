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
  const active = profile?.status === "active";
  const isSuperAdmin = active && profile?.role === "Super Admin";
  const isManager = active && profile?.role === "Manager";

  return {
    isSignedIn: Boolean(profile),
    isSuperAdmin,
    isMarketingOfficer: active && profile?.role === "Marketing Officer",
    isCustomerService: active && profile?.role === "Customer Service",

    // --- Rules the database enforces since 10_rpc_hardening.sql -----------
    // Mirrors of the SQL, so the UI only offers what will be accepted.

    /** can_view_cost(): cost, margin and profit are delivered at all. */
    viewCost: can("view_inventory") || can("view_reports"),
    /** can_manage_pricing(): selling price and cost (plus edit_products for the UPDATE policy). */
    managePricing: (isSuperAdmin || isManager) && can("edit_products"),
    /** transfer_customer_owner(): assign or move a customer's Marketing Officer. */
    transferCustomers: isSuperAdmin,
    /** create_order / record_payment dated before today, overrides, custom ids. */
    backdate: isSuperAdmin,
    /** Leaving delivered, reactivating a cancelled order, cancelling a paid one. */
    overrideOrders: isSuperAdmin,
    /** orders_delete: Super Admin, and only cancelled orders without payments. */
    deleteCancelledOrders: isSuperAdmin,
    /** Below-cost lines need a Super Admin and a reason. */
    approveBelowCost: isSuperAdmin,

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
    /**
     * has_all_order_scope() in supabase/11_order_scope_and_audit.sql: every
     * order is visible (Super Admin, or view_orders without
     * view_own_customers_only). Sales & Analytics shows the Marketing Officer
     * breakdown only then; the database scopes the rows either way.
     */
    allOrderScope: isSuperAdmin || (can("view_orders") && !can("view_own_customers_only")),
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
