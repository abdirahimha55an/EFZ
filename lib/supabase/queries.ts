/**
 * Every Supabase read and write the EFZ app makes.
 *
 * `createDb(client)` builds the whole query surface against any client, so the
 * same functions work in a Client Component (browser client), a Server
 * Component (server client), or a script (admin client).
 *
 * All of it is async - that is the one real difference from the synchronous
 * localStorage facade it replaces. Return shapes are the existing types in
 * lib/types, so components keep their current props.
 */

import type { PostgrestError } from "@supabase/supabase-js";

import type {
  AdminSettings,
  AdminUser,
  Customer,
  Notification,
  Order,
  OrderStatus,
  Product,
  StockMovement,
  SystemIssue,
  SystemLog,
  LogCategory,
  LogSeverity,
  UserRole,
} from "@/lib/types";

import type {
  CommissionRow,
  CustomerFinancialsRow,
  DailySalesRow,
  DbStockMovementType,
  FinancialSummaryRow,
  InventoryStatusRow,
  Json,
  OfficerCommissionSummaryRow,
  OperationalMetrics,
  OrderRequestRow,
  OrderUpdate,
  ProductSalesRow,
  PublicProductRow,
  RepairResult,
} from "./database.types";

import type { EfzSupabaseClient } from "./client";

import {
  fromAdminUser,
  fromCustomer,
  fromProduct,
  fromSettings,
  toAdminUser,
  toCustomer,
  toNotification,
  toOrder,
  toProduct,
  toSettings,
  toStockMovement,
  toSystemIssue,
  toSystemLog,
  toTestimonial,
  type Testimonial,
} from "./mappers";

// ---------------------------------------------------------------------------
// Error handling
// ---------------------------------------------------------------------------

/**
 * A failed query carries the Postgres error so callers can tell an RLS refusal
 * (`code === "42501"`) apart from a constraint violation.
 */
export class EfzDbError extends Error {
  readonly code: string;
  readonly details: string;
  readonly hint: string;

  constructor(context: string, error: PostgrestError) {
    super(`${context}: ${error.message}`);
    this.name = "EfzDbError";
    this.code = error.code ?? "";
    this.details = error.details ?? "";
    this.hint = error.hint ?? "";
  }
}

/**
 * Turns anything thrown by this layer into a sentence worth showing a user.
 *
 * `42501` is Postgres for "insufficient privilege" - what both an RLS refusal
 * and a `require_permission()` failure surface as. `P0001` is a plain
 * `raise exception`, and those messages are already written for humans
 * ("Insufficient stock for EFZ - Nexus: 3 in stock, 5 requested").
 */
export function describeDbError(error: unknown): string {
  if (error instanceof EfzDbError) {
    if (error.code === "42501") {
      return "Permission denied: your account is not allowed to do that.";
    }
    if (error.code === "23505") return "That record already exists.";
    if (error.code === "23503") return "That record is still referenced by something else.";
    if (error.code === "P0001") return error.message.replace(/^[^:]+:\s*/, "");
    return error.message;
  }
  if (error instanceof Error) return error.message;
  return "Something went wrong.";
}

type Result<T> = { data: T | null; error: PostgrestError | null };

const unwrap = <T>(context: string, result: Result<T>): NonNullable<T> => {
  if (result.error) throw new EfzDbError(context, result.error);
  if (result.data === null || result.data === undefined) {
    throw new Error(`${context}: the database returned no row`);
  }
  return result.data as NonNullable<T>;
};

const unwrapList = <T>(context: string, result: Result<T[]>): T[] => {
  if (result.error) throw new EfzDbError(context, result.error);
  return result.data ?? [];
};

const newId = (prefix: string): string =>
  `${prefix}-${globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2, 9)}`}`;

// ---------------------------------------------------------------------------
// Public inputs
// ---------------------------------------------------------------------------

export type CreateOrderInput = {
  id?: string;
  customerId?: string;
  customerName?: string;
  phone?: string;
  marketingOfficerId?: string;
  orderType?: "regular" | "trial";
  orderDate?: string;
  deliveryNotes?: string;
  status?: OrderStatus;
  items: Array<{
    productId: string;
    quantity: number;
    actualUnitPrice?: number;
    standardUnitPrice?: number;
    designName?: string;
  }>;
};

export type RecordPaymentInput = {
  orderId: string;
  amount: number;
  paymentMethod?: string;
  paymentDate?: string;
  reference?: string;
  notes?: string;
};

export type OrderRequestInput = {
  customerName: string;
  phone: string;
  organization?: string;
  productId?: string;
  productName?: string;
  quantity: number;
  deliveryLocation?: string;
  notes?: string;
};

// ---------------------------------------------------------------------------
// The query surface
// ---------------------------------------------------------------------------

export function createDb(client: EfzSupabaseClient) {
  // -------------------------------------------------------------------------
  // Auth and the current profile
  // -------------------------------------------------------------------------
  const auth = {
    /** Signs in with email and password. The proxy then keeps the session fresh. */
    async login(email: string, password: string) {
      const { data, error } = await client.auth.signInWithPassword({ email, password });
      if (error) throw new Error(error.message);
      return data.user;
    },

    async logout() {
      const { error } = await client.auth.signOut();
      if (error) throw new Error(error.message);
    },

    /** The auth user, or null. Verified against the Auth server, not just the cookie. */
    async getAuthUser() {
      const { data } = await client.auth.getUser();
      return data.user ?? null;
    },

    /**
     * The signed-in staff member, permissions included.
     * Returns null when signed out, or when an auth user has no linked profile.
     */
    async getProfile(): Promise<AdminUser | null> {
      const { data: authData } = await client.auth.getUser();
      const authUser = authData.user;
      if (!authUser) return null;

      const { data, error } = await client
        .from("profiles")
        .select("*, user_permissions(permission_code)")
        .eq("auth_user_id", authUser.id)
        .maybeSingle();

      if (error) throw new EfzDbError("getProfile", error);
      if (!data) return null;

      const { user_permissions: permissionRows, ...profile } = data as typeof data & {
        user_permissions: Array<{ permission_code: string }>;
      };

      return toAdminUser(profile, (permissionRows ?? []).map((row) => row.permission_code));
    },

    async updateOwnProfile(patch: Partial<AdminUser>) {
      const profile = await auth.getProfile();
      if (!profile) throw new Error("Not signed in");
      return users.update(profile.id, patch);
    },

    /** Asks the database whether the current user holds a permission. */
    async hasPermission(permission: string): Promise<boolean> {
      const { data, error } = await client.rpc("has_permission", { perm: permission });
      if (error) throw new EfzDbError("hasPermission", error);
      return Boolean(data);
    },

    /** Fires whenever the user signs in or out. Returns an unsubscribe function. */
    onAuthStateChange(callback: (signedIn: boolean) => void) {
      const { data } = client.auth.onAuthStateChange((_event, session) => {
        callback(Boolean(session));
      });
      return () => data.subscription.unsubscribe();
    },
  };

  // -------------------------------------------------------------------------
  // Users
  // -------------------------------------------------------------------------
  const users = {
    async list(): Promise<AdminUser[]> {
      const { data, error } = await client
        .from("profiles")
        .select("*, user_permissions(permission_code)")
        .order("name");

      if (error) throw new EfzDbError("users.list", error);

      return (data ?? []).map((row) => {
        const { user_permissions: permissionRows, ...profile } = row as typeof row & {
          user_permissions: Array<{ permission_code: string }>;
        };
        return toAdminUser(profile, (permissionRows ?? []).map((p) => p.permission_code));
      });
    },

    async get(id: string): Promise<AdminUser | null> {
      const { data, error } = await client
        .from("profiles")
        .select("*, user_permissions(permission_code)")
        .eq("id", id)
        .maybeSingle();

      if (error) throw new EfzDbError("users.get", error);
      if (!data) return null;

      const { user_permissions: permissionRows, ...profile } = data as typeof data & {
        user_permissions: Array<{ permission_code: string }>;
      };
      return toAdminUser(profile, (permissionRows ?? []).map((p) => p.permission_code));
    },

    /**
     * Creates the profile row only. The person still needs a Supabase Auth
     * account with the same email - invite them from the Supabase dashboard,
     * and the trigger in 02_functions.sql links the two.
     */
    async create(user: Omit<AdminUser, "id"> & { id?: string }): Promise<AdminUser> {
      const id = user.id ?? newId("u");
      const row = { ...fromAdminUser({ ...user, id }), id, name: user.name, email: user.email };

      const created = unwrap(
        "users.create",
        await client.from("profiles").insert(row).select().single()
      );

      if (user.permissions?.length) {
        await users.setPermissions(id, user.permissions);
      }

      return toAdminUser(created, user.permissions ?? []);
    },

    async update(id: string, patch: Partial<AdminUser>): Promise<AdminUser> {
      const row = fromAdminUser(patch);

      if (Object.keys(row).length > 0) {
        unwrap("users.update", await client.from("profiles").update(row).eq("id", id).select().single());
      }

      if (patch.permissions) {
        await users.setPermissions(id, patch.permissions);
      }

      const updated = await users.get(id);
      if (!updated) throw new Error(`User ${id} disappeared during update`);
      return updated;
    },

    async remove(id: string): Promise<void> {
      const { error } = await client.from("profiles").delete().eq("id", id);
      if (error) throw new EfzDbError("users.remove", error);
    },

    /** Replaces the user's whole permission set in one transaction. */
    async setPermissions(id: string, permissions: string[]): Promise<void> {
      const { error } = await client.rpc("set_user_permissions", {
        p_user_id: id,
        p_codes: permissions,
      });
      if (error) throw new EfzDbError("users.setPermissions", error);
    },

    /** Applies the default permission set for a role (see 05_seed.sql). */
    async applyRolePreset(id: string, role: UserRole): Promise<void> {
      const { error } = await client.rpc("grant_role_preset", { p_user_id: id, p_role: role });
      if (error) throw new EfzDbError("users.applyRolePreset", error);
    },

    /** The permission catalog, for building the checkbox grid. */
    async permissionCatalog() {
      return unwrapList(
        "users.permissionCatalog",
        await client.from("permissions").select("*").order("sort_order")
      );
    },
  };

  // -------------------------------------------------------------------------
  // Customers
  // -------------------------------------------------------------------------
  const customers = {
    /** RLS already narrows this to what the caller may see. */
    async list(options: { includeArchived?: boolean } = {}): Promise<Customer[]> {
      let query = client.from("customers").select("*").order("registered_on", { ascending: false });
      if (!options.includeArchived) query = query.eq("status", "active");

      return unwrapList("customers.list", await query).map(toCustomer);
    },

    async get(id: string): Promise<Customer | null> {
      const { data, error } = await client.from("customers").select("*").eq("id", id).maybeSingle();
      if (error) throw new EfzDbError("customers.get", error);
      return data ? toCustomer(data) : null;
    },

    async create(customer: Omit<Customer, "id"> & { id?: string }): Promise<Customer> {
      const id = customer.id ?? newId("cust");
      const row = {
        ...fromCustomer({ ...customer, id }),
        id,
        name: customer.name,
        registered_on: customer.date || new Date().toISOString().slice(0, 10),
      };

      return toCustomer(
        unwrap("customers.create", await client.from("customers").insert(row).select().single())
      );
    },

    async update(id: string, patch: Partial<Customer>): Promise<Customer> {
      return toCustomer(
        unwrap(
          "customers.update",
          await client.from("customers").update(fromCustomer(patch)).eq("id", id).select().single()
        )
      );
    },

    /** Archiving is preferred over deleting: it keeps the order history intact. */
    async archive(id: string): Promise<Customer> {
      return customers.update(id, { status: "archived", isArchived: true });
    },

    async remove(id: string): Promise<void> {
      const { error } = await client.from("customers").delete().eq("id", id);
      if (error) throw new EfzDbError("customers.remove", error);
    },

    /** Revenue, cash collected and outstanding balance per customer. */
    async financials(): Promise<CustomerFinancialsRow[]> {
      return unwrapList(
        "customers.financials",
        await client.from("customer_financials").select("*").order("revenue_generated", { ascending: false })
      );
    },
  };

  // -------------------------------------------------------------------------
  // Products
  // -------------------------------------------------------------------------
  const products = {
    async list(options: { includeInactive?: boolean } = {}): Promise<Product[]> {
      let query = client.from("products").select("*").order("name");
      if (!options.includeInactive) query = query.eq("is_active", true);

      return unwrapList("products.list", await query).map(toProduct);
    },

    async get(id: string): Promise<Product | null> {
      const { data, error } = await client.from("products").select("*").eq("id", id).maybeSingle();
      if (error) throw new EfzDbError("products.get", error);
      return data ? toProduct(data) : null;
    },

    async create(product: Omit<Product, "id"> & { id?: string }): Promise<Product> {
      const id = product.id ?? newId("prod");
      const row = { ...fromProduct({ ...product, id }), id, name: product.name };

      return toProduct(
        unwrap("products.create", await client.from("products").insert(row).select().single())
      );
    },

    /**
     * Updates product fields. Stock is deliberately not writable here - use
     * inventory.adjust() so every change lands in the movement ledger.
     */
    async update(id: string, patch: Partial<Product>): Promise<Product> {
      const row = fromProduct(patch);
      delete row.stock;

      return toProduct(
        unwrap("products.update", await client.from("products").update(row).eq("id", id).select().single())
      );
    },

    /** Soft delete. Keeps the product on historical orders. */
    async deactivate(id: string): Promise<void> {
      const { error } = await client.from("products").update({ is_active: false }).eq("id", id);
      if (error) throw new EfzDbError("products.deactivate", error);
    },

    async remove(id: string): Promise<void> {
      const { error } = await client.from("products").delete().eq("id", id);
      if (error) throw new EfzDbError("products.remove", error);
    },

    /** The anon-safe feed for the public site. Excludes cost price. */
    async listPublic(): Promise<PublicProductRow[]> {
      return unwrapList(
        "products.listPublic",
        await client.from("public_products").select("*").order("name")
      );
    },
  };

  // -------------------------------------------------------------------------
  // Inventory
  // -------------------------------------------------------------------------
  const inventory = {
    /** Stock health, margin and units sold per product. */
    async status(): Promise<InventoryStatusRow[]> {
      return unwrapList(
        "inventory.status",
        await client.from("inventory_status").select("*").order("stock")
      );
    },

    async lowStock(): Promise<InventoryStatusRow[]> {
      return unwrapList(
        "inventory.lowStock",
        await client.from("inventory_status").select("*").neq("stock_state", "healthy").order("stock")
      );
    },

    async movements(options: { productId?: string; limit?: number } = {}): Promise<StockMovement[]> {
      let query = client
        .from("stock_movements")
        .select("*")
        .order("created_at", { ascending: false })
        .limit(options.limit ?? 200);

      if (options.productId) query = query.eq("product_id", options.productId);

      return unwrapList("inventory.movements", await query).map(toStockMovement);
    },

    /**
     * The only supported way to change stock outside an order. Updates the
     * product and writes the ledger entry in one transaction, and refuses to
     * drive stock below zero.
     */
    async adjust(
      productId: string,
      quantityChange: number,
      reason: string,
      type: DbStockMovementType = "manual_adjustment"
    ): Promise<string> {
      const { data, error } = await client.rpc("adjust_stock", {
        p_product_id: productId,
        p_quantity_change: Math.round(quantityChange),
        p_reason: reason,
        p_type: type,
      });
      if (error) throw new EfzDbError("inventory.adjust", error);
      return data as string;
    },
  };

  // -------------------------------------------------------------------------
  // Orders
  // -------------------------------------------------------------------------
  const orders = {
    /** Orders with items and payments already nested, ready for the UI. */
    async list(
      options: {
        status?: OrderStatus;
        customerId?: string;
        marketingOfficerId?: string;
        from?: string;
        to?: string;
        limit?: number;
      } = {}
    ): Promise<Order[]> {
      let query = client
        .from("order_details")
        .select("*")
        .order("order_date", { ascending: false })
        .order("created_at", { ascending: false });

      if (options.status) query = query.eq("status", options.status);
      if (options.customerId) query = query.eq("customer_id", options.customerId);
      if (options.marketingOfficerId) {
        query = query.eq("marketing_officer_id", options.marketingOfficerId);
      }
      if (options.from) query = query.gte("order_date", options.from);
      if (options.to) query = query.lte("order_date", options.to);
      if (options.limit) query = query.limit(options.limit);

      return unwrapList("orders.list", await query).map(toOrder);
    },

    async get(id: string): Promise<Order | null> {
      const { data, error } = await client
        .from("order_details")
        .select("*")
        .eq("id", id)
        .maybeSingle();

      if (error) throw new EfzDbError("orders.get", error);
      return data ? toOrder(data) : null;
    },

    /**
     * Creates the order, its items and the stock deductions atomically.
     * Throws if any product is short on stock - nothing is written in that case.
     */
    async create(input: CreateOrderInput): Promise<Order> {
      const { data, error } = await client.rpc("create_order", {
        payload: input as unknown as Json,
      });
      if (error) throw new EfzDbError("orders.create", error);

      const created = await orders.get(data as string);
      if (!created) throw new Error("Order was created but could not be read back");
      return created;
    },

    /**
     * Moves an order through the fulfilment pipeline. Illegal transitions are
     * refused unless the caller is a Super Admin. Cancelling restores stock.
     */
    async setStatus(id: string, status: OrderStatus, reason = ""): Promise<void> {
      const { error } = await client.rpc("update_order_status", {
        p_order_id: id,
        p_status: status,
        p_reason: reason,
      });
      if (error) throw new EfzDbError("orders.setStatus", error);
    },

    /** Editable metadata only. Financial columns are trigger-maintained. */
    async update(
      id: string,
      patch: { deliveryNotes?: string; customerId?: string; marketingOfficerId?: string; phone?: string }
    ): Promise<void> {
      const row: OrderUpdate = {};
      if (patch.deliveryNotes !== undefined) row.delivery_notes = patch.deliveryNotes;
      if (patch.customerId !== undefined) row.customer_id = patch.customerId || null;
      if (patch.marketingOfficerId !== undefined) {
        row.marketing_officer_id = patch.marketingOfficerId || null;
      }
      if (patch.phone !== undefined) row.phone = patch.phone;
      if (Object.keys(row).length === 0) return;

      const { error } = await client.from("orders").update(row).eq("id", id);
      if (error) throw new EfzDbError("orders.update", error);
    },

    async remove(id: string): Promise<void> {
      const { error } = await client.from("orders").delete().eq("id", id);
      if (error) throw new EfzDbError("orders.remove", error);
    },

    /** Records a payment. Overpayment is refused by the database. */
    async addPayment(input: RecordPaymentInput): Promise<Order> {
      const { error } = await client.rpc("record_payment", {
        p_order_id: input.orderId,
        p_amount: input.amount,
        p_method: input.paymentMethod ?? "Cash",
        p_date: input.paymentDate ?? new Date().toISOString().slice(0, 10),
        p_reference: input.reference ?? "",
        p_notes: input.notes ?? "",
      });
      if (error) throw new EfzDbError("orders.addPayment", error);

      const updated = await orders.get(input.orderId);
      if (!updated) throw new Error("Payment recorded but the order could not be read back");
      return updated;
    },
  };

  // -------------------------------------------------------------------------
  // Public order requests
  // -------------------------------------------------------------------------
  const orderRequests = {
    /** Called from the public order form. Works for signed-out visitors. */
    async submit(input: OrderRequestInput): Promise<string> {
      const { data, error } = await client
        .from("order_requests")
        .insert({
          customer_name: input.customerName,
          phone: input.phone,
          organization: input.organization ?? "",
          product_id: input.productId ?? null,
          product_name: input.productName ?? "",
          quantity: Math.max(1, Math.round(input.quantity)),
          delivery_location: input.deliveryLocation ?? "",
          notes: input.notes ?? "",
        })
        .select()
        .single();

      if (error) throw new EfzDbError("orderRequests.submit", error);
      return data.id;
    },

    async list(status?: OrderRequestRow["status"]): Promise<OrderRequestRow[]> {
      let query = client.from("order_requests").select("*").order("created_at", { ascending: false });
      if (status) query = query.eq("status", status);
      return unwrapList("orderRequests.list", await query);
    },

    async setStatus(id: string, status: OrderRequestRow["status"]): Promise<void> {
      const { error } = await client.from("order_requests").update({ status }).eq("id", id);
      if (error) throw new EfzDbError("orderRequests.setStatus", error);
    },

    /** Turns a website submission into a real order in one transaction. */
    async convert(requestId: string, customerId: string): Promise<string> {
      const { data, error } = await client.rpc("convert_order_request", {
        p_request_id: requestId,
        p_customer_id: customerId,
      });
      if (error) throw new EfzDbError("orderRequests.convert", error);
      return data as string;
    },
  };

  // -------------------------------------------------------------------------
  // Commissions
  // -------------------------------------------------------------------------
  const commissions = {
    /** An officer always sees their own, regardless of permissions. */
    async list(options: { userId?: string; status?: CommissionRow["status"] } = {}) {
      let query = client
        .from("commissions")
        .select("*, orders(id, customer_name, order_date, status)")
        .order("created_at", { ascending: false });

      if (options.userId) query = query.eq("user_id", options.userId);
      if (options.status) query = query.eq("status", options.status);

      return unwrapList("commissions.list", await query);
    },

    /** The payout board: earned, paid and pending per officer. */
    async summary(): Promise<OfficerCommissionSummaryRow[]> {
      return unwrapList(
        "commissions.summary",
        await client
          .from("officer_commission_summary")
          .select("*")
          .order("pending_commission", { ascending: false })
      );
    },

    /** Settles a set of commissions as one payout and locks those orders. */
    async pay(
      userId: string,
      commissionIds: string[],
      options: { method?: string; reference?: string; notes?: string } = {}
    ): Promise<string> {
      const { data, error } = await client.rpc("pay_commissions", {
        p_user_id: userId,
        p_commission_ids: commissionIds,
        p_method: options.method ?? "Cash",
        p_reference: options.reference ?? "",
        p_notes: options.notes ?? "",
      });
      if (error) throw new EfzDbError("commissions.pay", error);
      return data as string;
    },

    async payouts(userId?: string) {
      let query = client
        .from("commission_payouts")
        .select("*")
        .order("paid_at", { ascending: false });
      if (userId) query = query.eq("user_id", userId);
      return unwrapList("commissions.payouts", await query);
    },
  };

  // -------------------------------------------------------------------------
  // Analytics
  // -------------------------------------------------------------------------
  const analytics = {
    /** The dashboard KPI strip, computed in Postgres rather than the browser. */
    async financialSummary(): Promise<FinancialSummaryRow> {
      const { data, error } = await client.from("financial_summary").select("*").single();
      if (error) throw new EfzDbError("analytics.financialSummary", error);
      return data;
    },

    async dailySales(options: { from?: string; to?: string; limit?: number } = {}): Promise<DailySalesRow[]> {
      let query = client.from("daily_sales").select("*");
      if (options.from) query = query.gte("order_date", options.from);
      if (options.to) query = query.lte("order_date", options.to);
      return unwrapList("analytics.dailySales", await query.limit(options.limit ?? 365));
    },

    async productSales(): Promise<ProductSalesRow[]> {
      return unwrapList("analytics.productSales", await client.from("product_sales").select("*"));
    },

    /** Row counts for the diagnostics page. */
    async dataCounts() {
      const tables = ["products", "orders", "customers", "profiles"] as const;
      const counts = await Promise.all(
        tables.map(async (table) => {
          const { count, error } = await client
            .from(table)
            .select("*", { count: "exact", head: true });
          if (error) throw new EfzDbError(`analytics.dataCounts(${table})`, error);
          return [table, count ?? 0] as const;
        })
      );

      const lookup = Object.fromEntries(counts) as Record<(typeof tables)[number], number>;
      return {
        products: lookup.products,
        orders: lookup.orders,
        customers: lookup.customers,
        users: lookup.profiles,
      };
    },
  };

  // -------------------------------------------------------------------------
  // Audit log
  // -------------------------------------------------------------------------
  const logs = {
    async list(
      options: { category?: LogCategory; severity?: LogSeverity; limit?: number } = {}
    ): Promise<SystemLog[]> {
      let query = client
        .from("system_logs")
        .select("*")
        .order("occurred_at", { ascending: false })
        .limit(options.limit ?? 200);

      if (options.category) query = query.eq("category", options.category);
      if (options.severity) query = query.eq("severity", options.severity);

      return unwrapList("logs.list", await query).map(toSystemLog);
    },

    /**
     * Total rows, not the number loaded. `list()` is capped, so a page showing
     * "total events" must ask for this rather than counting what it fetched.
     */
    async count(): Promise<number> {
      const { count, error } = await client
        .from("system_logs")
        .select("*", { count: "exact", head: true });
      if (error) throw new EfzDbError("logs.count", error);
      return count ?? 0;
    },

    /** Append-only. Nothing in the app can edit or erase an existing line. */
    async write(entry: {
      category: LogCategory;
      severity: LogSeverity;
      message: string;
      targetId?: string;
      metadata?: Record<string, unknown>;
    }): Promise<void> {
      const { data: authData } = await client.auth.getUser();
      const authUser = authData.user;

      let userId: string | null = null;
      let username = "";
      if (authUser) {
        const { data: profile } = await client
          .from("profiles")
          .select("id, name")
          .eq("auth_user_id", authUser.id)
          .maybeSingle();
        userId = profile?.id ?? null;
        username = profile?.name ?? "";
      }

      const { error } = await client.from("system_logs").insert({
        id: newId("log"),
        occurred_at: new Date().toISOString(),
        severity: entry.severity,
        category: entry.category,
        message: entry.message,
        user_id: userId,
        username,
        target_id: entry.targetId ?? null,
        metadata: (entry.metadata ?? {}) as Json,
      });

      if (error) throw new EfzDbError("logs.write", error);
    },

    async recentActivity(limit = 10): Promise<SystemLog[]> {
      return logs.list({ limit });
    },
  };

  // -------------------------------------------------------------------------
  // Diagnostics
  // -------------------------------------------------------------------------
  const issues = {
    async list(options: { includeResolved?: boolean } = {}): Promise<SystemIssue[]> {
      let query = client
        .from("system_issues")
        .select("*")
        .order("last_detected_at", { ascending: false });
      if (!options.includeResolved) query = query.is("resolved_at", null);

      return unwrapList("issues.list", await query).map(toSystemIssue);
    },

    async upsert(issue: SystemIssue): Promise<void> {
      const { error } = await client.from("system_issues").upsert({
        id: issue.id,
        title: issue.title,
        severity: issue.severity,
        source: issue.source,
        affected_entity_type: issue.affectedEntityType ?? null,
        affected_entity_id: issue.affectedEntityId ?? null,
        linked_system: issue.linkedSystem ?? null,
        impact: issue.impact ?? null,
        affected_count: issue.affectedCount ?? 1,
        explanation: issue.explanation,
        recommended_action: issue.recommendedAction,
        repairable: issue.repairable,
        last_detected_at: new Date().toISOString(),
      });
      if (error) throw new EfzDbError("issues.upsert", error);
    },

    async resolve(id: string): Promise<void> {
      const { error } = await client
        .from("system_issues")
        .update({ resolved_at: new Date().toISOString() })
        .eq("id", id);
      if (error) throw new EfzDbError("issues.resolve", error);
    },

    /**
     * Runs the integrity scan inside the database and refreshes system_issues.
     * Returns the number of open findings.
     *
     * The scan looks for data that is structurally valid but operationally
     * wrong. Duplicate ids, orphaned references and negative stock are not
     * checked because constraints already make them impossible.
     */
    async scan(): Promise<number> {
      const { data, error } = await client.rpc("run_diagnostics");
      if (error) throw new EfzDbError("issues.scan", error);
      return Number(data ?? 0);
    },

    /** Only findings marked `repairable` can be fixed automatically. */
    async repair(issueId: string): Promise<RepairResult> {
      const { data, error } = await client.rpc("repair_issue", { p_issue_id: issueId });
      if (error) throw new EfzDbError("issues.repair", error);
      return data as unknown as RepairResult;
    },

    /** Health score, row counts and runtime facts about the database itself. */
    async metrics(): Promise<OperationalMetrics> {
      const { data, error } = await client.rpc("operational_metrics");
      if (error) throw new EfzDbError("issues.metrics", error);
      return data as unknown as OperationalMetrics;
    },
  };

  // -------------------------------------------------------------------------
  // Notifications
  // -------------------------------------------------------------------------
  const notifications = {
    async list(): Promise<Notification[]> {
      return unwrapList(
        "notifications.list",
        await client.from("notifications").select("*").order("created_at", { ascending: false }).limit(100)
      ).map(toNotification);
    },

    async create(notification: Omit<Notification, "id" | "date" | "read">): Promise<void> {
      const { error } = await client.from("notifications").insert({
        id: newId("ntf"),
        title: notification.title,
        message: notification.message,
        type: notification.type,
      });
      if (error) throw new EfzDbError("notifications.create", error);
    },

    /**
     * Writes the derived low-stock and pending-order alerts.
     *
     * Ids are deterministic (`low-prod-123`, `order-ORD-456`) and duplicates are
     * ignored, so re-running this on every page load never piles up copies and
     * an alert someone already read stays read.
     */
    async upsertAlerts(
      alerts: Array<Pick<Notification, "id" | "title" | "message" | "type">>
    ): Promise<void> {
      if (alerts.length === 0) return;

      const { error } = await client.from("notifications").upsert(
        alerts.map((alert) => ({
          id: alert.id,
          title: alert.title,
          message: alert.message,
          type: alert.type,
        })),
        { onConflict: "id", ignoreDuplicates: true }
      );

      if (error) throw new EfzDbError("notifications.upsertAlerts", error);
    },

    async markRead(id: string): Promise<void> {
      const { error } = await client.from("notifications").update({ read: true }).eq("id", id);
      if (error) throw new EfzDbError("notifications.markRead", error);
    },

    /** Broadcast alerts are one shared row, so this marks them read for everyone. */
    async markAllRead(): Promise<void> {
      const { error } = await client.from("notifications").update({ read: true }).eq("read", false);
      if (error) throw new EfzDbError("notifications.markAllRead", error);
    },

    async remove(id: string): Promise<void> {
      const { error } = await client.from("notifications").delete().eq("id", id);
      if (error) throw new EfzDbError("notifications.remove", error);
    },

    /** Needs manage_system for broadcast rows - RLS refuses otherwise. */
    async clearAll(): Promise<void> {
      const { error } = await client.from("notifications").delete().neq("id", "");
      if (error) throw new EfzDbError("notifications.clearAll", error);
    },
  };

  // -------------------------------------------------------------------------
  // Settings
  // -------------------------------------------------------------------------
  const settings = {
    async get(): Promise<AdminSettings> {
      const { data, error } = await client.from("settings").select("*").eq("id", true).single();
      if (error) throw new EfzDbError("settings.get", error);
      return toSettings(data);
    },

    async update(patch: Partial<AdminSettings>): Promise<AdminSettings> {
      return toSettings(
        unwrap(
          "settings.update",
          await client.from("settings").update(fromSettings(patch)).eq("id", true).select().single()
        )
      );
    },
  };

  // -------------------------------------------------------------------------
  // Marketing content
  // -------------------------------------------------------------------------
  const testimonials = {
    async list(): Promise<Testimonial[]> {
      return unwrapList(
        "testimonials.list",
        await client.from("testimonials").select("*").eq("is_published", true).order("sort_order")
      ).map(toTestimonial);
    },
  };

  // -------------------------------------------------------------------------
  // Backups
  // -------------------------------------------------------------------------
  const backups = {
    async list() {
      return unwrapList(
        "backups.list",
        await client
          .from("backups")
          .select("id, label, record_counts, size_bytes, created_at, created_by")
          .order("created_at", { ascending: false })
          .limit(50)
      );
    },

    /** Snapshots the core tables into one backup row. */
    async create(label: string) {
      const [profileRows, customerRows, productRows, orderRows, movementRows, settingsRow] =
        await Promise.all([
          client.from("profiles").select("*"),
          client.from("customers").select("*"),
          client.from("products").select("*"),
          client.from("order_details").select("*"),
          client.from("stock_movements").select("*"),
          client.from("settings").select("*").eq("id", true).single(),
        ]);

      const payload = {
        profiles: profileRows.data ?? [],
        customers: customerRows.data ?? [],
        products: productRows.data ?? [],
        orders: orderRows.data ?? [],
        stock_movements: movementRows.data ?? [],
        settings: settingsRow.data ?? null,
      };

      const serialized = JSON.stringify(payload);

      // Selects the whole row, payload included: callers download this object
      // as the backup file, and a row without its payload is not a backup.
      const { data, error } = await client
        .from("backups")
        .insert({
          label,
          payload: payload as unknown as Json,
          record_counts: {
            profiles: payload.profiles.length,
            customers: payload.customers.length,
            products: payload.products.length,
            orders: payload.orders.length,
            stock_movements: payload.stock_movements.length,
          } as unknown as Json,
          size_bytes: serialized.length,
        })
        .select()
        .single();

      if (error) throw new EfzDbError("backups.create", error);
      return data;
    },
  };

  return {
    client,
    auth,
    users,
    customers,
    products,
    inventory,
    orders,
    orderRequests,
    commissions,
    analytics,
    logs,
    issues,
    notifications,
    settings,
    testimonials,
    backups,
  };
}

export type EfzDb = ReturnType<typeof createDb>;
