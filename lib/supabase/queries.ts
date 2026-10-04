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
  CustomerOwnershipChange,
  CustomerTransferNotice,
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
  CommissionEligibilityChangeRow,
  CommissionEligibilityStatusRow,
  CommissionRow,
  CustomerFinancialsRow,
  DailySalesRow,
  DbStockMovementType,
  FinancialSummaryRow,
  InventoryStatusRow,
  Json,
  OfficerCommissionSummaryRow,
  OperationalMetrics,
  OrderDeliveryLineRow,
  OrderDeliveryRow,
  OrderRequestRow,
  OrderUpdate,
  ProductSalesRow,
  PublicProductRow,
  RepairResult,
} from "./database.types";

import type { CommissionEvent } from "@/lib/commission";

import type { EfzSupabaseClient } from "./client";
import { efzRangeBounds, isYmd } from "@/lib/dates";

import {
  fromAdminUser,
  fromCustomer,
  fromProduct,
  fromSettings,
  toAdminUser,
  toCustomer,
  toCustomerOwnershipChange,
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

/** The database's own sentence, without the "orders.create: " context prefix. */
const dbSentence = (error: EfzDbError) => error.message.replace(/^[^:]+:\s*/, "");

/**
 * Turns anything thrown by this layer into a sentence worth showing a user.
 *
 * `42501` is Postgres for "insufficient privilege". Two kinds arrive with it:
 *   * the generic ones Postgres writes itself ("new row violates row-level
 *     security policy", "permission denied for table ...") - replaced here
 *     with a plain sentence, since they mean nothing to staff;
 *   * the business rules raised by 08/10 ("Only a Super Admin can ...",
 *     "Order X has payments or paid commission ...") - written for people, so
 *     they are shown as they are.
 * `P0001` is a plain `raise exception`, also already written for humans
 * ("Insufficient stock for EFZ - Nexus: 3 in stock, 5 requested").
 *
 * `hideCost`: before migration 11, create_order() quoted the product's cost
 * when it refused a below-cost price; since 11 it says "below the product's
 * cost" to anyone who may not see cost. Either way, someone who may not see
 * cost gets one fixed sentence (no figures).
 */
export function describeDbError(error: unknown, options: { hideCost?: boolean } = {}): string {
  if (error instanceof EfzDbError) {
    let sentence = dbSentence(error);

    if (options.hideCost && /below (its|the product's) cost/i.test(sentence)) {
      return "That price is below the product's cost. Only a Super Admin can approve a below-cost sale.";
    }

    if (error.code === "42501") {
      if (/row-level security|permission denied for/i.test(sentence)) {
        return "Permission denied: your account is not allowed to do that.";
      }
      sentence = sentence.replace(/^Permission denied: (\S+) is required$/, "Permission denied: this needs the $1 permission.");
      return sentence;
    }
    if (error.code === "23505") return "That record already exists.";
    if (error.code === "23503") return "That record is still referenced by something else.";
    if (error.code === "23514") return `That value is not allowed: ${sentence}`;
    return sentence;
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
// Audit trail filters (applied in the database, never to a loaded page)
// ---------------------------------------------------------------------------

/** What the Audit Trail is filtered by. Every field is optional; empty = no restriction. */
export type AuditLogFilter = {
  /** Free text matched (case-insensitive) against message, username, user id and target id. */
  search?: string;
  category?: LogCategory;
  severity?: LogSeverity;
  severities?: LogSeverity[];
  /** A profile id; NO_AUDIT_USER selects lines written without a signed-in user. */
  userId?: string;
  /** Inclusive Mogadishu calendar dates (YYYY-MM-DD). */
  range?: { from: string; to: string };
};

/** userId value meaning "written by the system / no user". */
export const NO_AUDIT_USER = "__none__";

/**
 * A PostgREST-quoted ILIKE pattern that matches `text` literally anywhere:
 * LIKE wildcards in the text are escaped, then the value is quoted so commas,
 * parentheses and dots cannot break out of the or=(...) filter.
 */
const quoteLike = (text: string): string => {
  const like = `%${text.replace(/[\\%_]/g, (m) => `\\${m}`)}%`;
  return `"${like.replace(/[\\"]/g, (m) => `\\${m}`)}"`;
};

type AuditFilterable<Q> = {
  eq(column: string, value: string): Q;
  is(column: string, value: null): Q;
  in(column: string, values: string[]): Q;
  gte(column: string, value: string): Q;
  lt(column: string, value: string): Q;
  or(filters: string): Q;
};

function applyAuditFilter<Q extends AuditFilterable<Q>>(query: Q, filter: AuditLogFilter): Q {
  let q = query;
  const search = filter.search?.trim();
  if (search) {
    const p = quoteLike(search);
    q = q.or(`message.ilike.${p},username.ilike.${p},user_id.ilike.${p},target_id.ilike.${p}`);
  }
  if (filter.category) q = q.eq("category", filter.category);
  if (filter.severity) q = q.eq("severity", filter.severity);
  if (filter.userId === NO_AUDIT_USER) q = q.is("user_id", null);
  else if (filter.userId) q = q.eq("user_id", filter.userId);
  if (filter.range && isYmd(filter.range.from) && isYmd(filter.range.to)) {
    const bounds = efzRangeBounds(filter.range);
    q = q.gte("occurred_at", bounds.gte).lt("occurred_at", bounds.lt);
  }
  return q;
}

// ---------------------------------------------------------------------------
// Column lists
// ---------------------------------------------------------------------------
// Explicit, so a query never asks for more than the screen needs. The cost
// columns of products / orders / order_items are not selectable at all since
// 10_rpc_hardening.sql; those reads go through staff_products and the views.

// Single literals (no concatenation) so supabase-js can type the rows.
// profiles.*_commission_total are not selectable since 11_order_scope_and_audit.sql;
// commission totals come from commissions.summary() (officer_commission_summary).
const PROFILE_COLUMNS = "id, auth_user_id, name, email, phone, avatar, role, status, commission_percentage, created_at, updated_at";

const CUSTOMER_COLUMNS = "id, name, email, phone, registered_by, marketing_officer_id, registered_on, notes, status, created_at, updated_at";

const STAFF_PRODUCT_COLUMNS = "id, name, description, category, size, durability, surface_type, is_wholesale, cost_price, selling_price, stock, low_stock_threshold, image_url, is_active, price, created_at, updated_at";

// ---------------------------------------------------------------------------
// Public inputs
// ---------------------------------------------------------------------------

/**
 * What create_order() accepts from the app. The database decides everything
 * else: status (always pending), the Marketing Officer (the customer's
 * owner), the list price and cost snapshot, totals and payment status.
 */
export type CreateOrderInput = {
  customerId: string;
  customerName?: string;
  phone?: string;
  orderType?: "regular" | "trial";
  /** Omit for today (Mogadishu). A past date is accepted from a Super Admin only. */
  orderDate?: string;
  deliveryNotes?: string;
  /** Required by the database when a Super Admin approves a line below cost. */
  belowCostReason?: string;
  items: Array<{
    productId: string;
    /** Whole number, at least 1. */
    quantity: number;
    /** Negotiated price; omit for the product's selling price. */
    actualUnitPrice?: number;
    designName?: string;
  }>;
};

export type RecordPaymentInput = {
  orderId: string;
  amount: number;
  paymentMethod?: string;
  /**
   * Omit for today (Mogadishu). A past date is accepted from a Super Admin
   * only; a future date from nobody.
   */
  paymentDate?: string;
  reference?: string;
  notes?: string;
};

/** Staff-editable customer fields. Ownership is set by the database and transfer_customer_owner(). */
export type CustomerInput = {
  name: string;
  phone: string;
  email?: string;
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

/** PostgREST / PostgreSQL "no such table or view": the database predates migration 12. */
const isMissingRelation = (error: PostgrestError | null) =>
  Boolean(error && (error.code === "PGRST205" || error.code === "42P01"));

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
        .select(`${PROFILE_COLUMNS}, user_permissions(permission_code)`)
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
        .select(`${PROFILE_COLUMNS}, user_permissions(permission_code)`)
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
        .select(`${PROFILE_COLUMNS}, user_permissions(permission_code)`)
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
        await client.from("profiles").insert(row).select(PROFILE_COLUMNS).single()
      );

      if (user.permissions?.length) {
        await users.setPermissions(id, user.permissions);
      }

      return toAdminUser(created, user.permissions ?? []);
    },

    async update(id: string, patch: Partial<AdminUser>): Promise<AdminUser> {
      const row = fromAdminUser(patch);

      if (Object.keys(row).length > 0) {
        unwrap("users.update", await client.from("profiles").update(row).eq("id", id).select("id").single());
      }

      if (patch.permissions) {
        await users.setPermissions(id, patch.permissions);
      }

      const updated = await users.get(id);
      if (!updated) throw new Error(`User ${id} disappeared during update`);
      return updated;
    },

    /**
     * Asks for the deleted id back so a refusal cannot pass as success: RLS
     * (profiles_delete needs manage_users) removes zero rows without an error.
     */
    async remove(id: string): Promise<void> {
      const { data, error } = await client.from("profiles").delete().eq("id", id).select("id");
      if (error) throw new EfzDbError("users.remove", error);
      if (!data || data.length === 0) {
        throw new Error(`User ${id} was not deleted: you may not delete this account.`);
      }
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
      let query = client.from("customers").select(CUSTOMER_COLUMNS).order("registered_on", { ascending: false });
      if (!options.includeArchived) query = query.eq("status", "active");

      return unwrapList("customers.list", await query).map(toCustomer);
    },

    async get(id: string): Promise<Customer | null> {
      const { data, error } = await client.from("customers").select(CUSTOMER_COLUMNS).eq("id", id).maybeSingle();
      if (error) throw new EfzDbError("customers.get", error);
      return data ? toCustomer(data) : null;
    },

    /**
     * Registers a customer. Ownership is not sent: the database makes a
     * Marketing Officer the owner of their own registration and leaves
     * everyone else's unassigned; it also stamps registered_by and the
     * (Mogadishu) registration date.
     */
    async create(customer: CustomerInput): Promise<Customer> {
      const id = newId("cust");
      const row = { ...fromCustomer(customer), id, name: customer.name };

      return toCustomer(
        unwrap("customers.create", await client.from("customers").insert(row).select(CUSTOMER_COLUMNS).single())
      );
    },

    /** Contact fields and status only. The owner moves with transferOwner(). */
    async update(id: string, patch: Partial<CustomerInput & { status: "active" | "archived" }>): Promise<Customer> {
      return toCustomer(
        unwrap(
          "customers.update",
          await client.from("customers").update(fromCustomer(patch)).eq("id", id).select(CUSTOMER_COLUMNS).single()
        )
      );
    },

    /** Archiving is preferred over deleting: it keeps the order history intact. */
    async archive(id: string): Promise<Customer> {
      return customers.update(id, { status: "archived" });
    },

    /**
     * Refused by the database for a customer with orders - archive those.
     * Asks for the deleted id back so a refusal cannot pass as success: RLS
     * (customers_delete needs delete_customers) removes zero rows without an error.
     */
    async remove(id: string): Promise<void> {
      const { data, error } = await client.from("customers").delete().eq("id", id).select("id");
      if (error) throw new EfzDbError("customers.remove", error);
      if (!data || data.length === 0) {
        throw new Error(`Customer ${id} was not deleted: you may not delete customers, or it no longer exists.`);
      }
    },

    /**
     * Assigns an unassigned customer to a Marketing Officer, or moves one to
     * another. Super Admin only, reason required, recorded in
     * customer_ownership_changes. Undelivered orders follow the customer;
     * delivered orders keep the officer who earned them.
     */
    async transferOwner(customerId: string, newOfficerId: string, reason: string): Promise<void> {
      const { error } = await client.rpc("transfer_customer_owner", {
        p_customer_id: customerId,
        p_new_officer_id: newOfficerId,
        p_reason: reason,
      });
      if (error) throw new EfzDbError("customers.transferOwner", error);
    },

    /**
     * Transfers involving the signed-in officer: which customer, when and in
     * which direction - never the reason (that stays with management).
     */
    async transferNotices(): Promise<CustomerTransferNotice[]> {
      const result = await client
        .from("customer_transfer_notices")
        .select("id, customer_id, customer_name, changed_at, direction")
        .order("changed_at", { ascending: false });
      if (isMissingRelation(result.error)) return [];
      const rows = unwrapList("customers.transferNotices", result);
      return rows.map((row) => ({
        id: row.id,
        customerId: row.customer_id,
        customerName: row.customer_name,
        changedAt: row.changed_at,
        direction: row.direction,
      }));
    },

    /** The audited assignment / transfer history of one customer, newest first. */
    async ownershipHistory(customerId: string): Promise<CustomerOwnershipChange[]> {
      return unwrapList(
        "customers.ownershipHistory",
        await client
          .from("customer_ownership_changes")
          .select("id, customer_id, customer_name, old_officer_id, old_officer_name, new_officer_id, new_officer_name, reason, orders_moved, changed_by, changed_by_name, changed_at")
          .eq("customer_id", customerId)
          .order("changed_at", { ascending: false })
      ).map(toCustomerOwnershipChange);
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
  // Reads go through staff_products: the same rows, with cost_price null for
  // anyone who may not see cost. products.cost_price itself is not
  // selectable, so writes never ask for the row back - they re-read it here.
  const products = {
    async list(options: { includeInactive?: boolean } = {}): Promise<Product[]> {
      let query = client.from("staff_products").select(STAFF_PRODUCT_COLUMNS).order("name");
      if (!options.includeInactive) query = query.eq("is_active", true);

      return unwrapList("products.list", await query).map(toProduct);
    },

    async get(id: string): Promise<Product | null> {
      const { data, error } = await client.from("staff_products").select(STAFF_PRODUCT_COLUMNS).eq("id", id).maybeSingle();
      if (error) throw new EfzDbError("products.get", error);
      return data ? toProduct(data) : null;
    },

    /**
     * Creates the product with stock 0 (stock arrives through inventory.adjust).
     * Selling price and cost are only sent when the caller may price - a
     * Super Admin or Manager; anyone else creates it unpriced for a manager.
     */
    async create(product: Omit<Product, "id" | "costPrice" | "price"> & { costPrice?: number | null }): Promise<Product> {
      const id = newId("prod");
      const row = { ...fromProduct({ ...product, stock: 0 }), id, name: product.name };

      const { error } = await client.from("products").insert(row);
      if (error) throw new EfzDbError("products.create", error);

      const created = await products.get(id);
      if (!created) throw new Error("products.create: the product was created but could not be read back");
      return created;
    },

    /**
     * Updates product fields. Stock is deliberately not writable here - use
     * inventory.adjust() so every change lands in the movement ledger.
     * Leave sellingPrice / costPrice out of the patch unless the caller may
     * price; the database refuses a price change from anyone else.
     */
    async update(id: string, patch: Partial<Product>): Promise<Product> {
      const row = fromProduct(patch);
      delete row.stock;

      const { error } = await client.from("products").update(row).eq("id", id);
      if (error) throw new EfzDbError("products.update", error);

      const updated = await products.get(id);
      if (!updated) throw new Error(`products.update: product ${id} could not be read back`);
      return updated;
    },

    /** Soft delete. Keeps the product on historical orders. Zero rows changed (RLS) is a refusal, not success. */
    async deactivate(id: string): Promise<void> {
      const { data, error } = await client.from("products").update({ is_active: false }).eq("id", id).select("id");
      if (error) throw new EfzDbError("products.deactivate", error);
      if (!data || data.length === 0) {
        throw new Error(`Product ${id} was not removed from the catalog: you may not edit products, or it no longer exists.`);
      }
    },

    /** Zero rows deleted (RLS) is a refusal, not success. */
    async remove(id: string): Promise<void> {
      const { data, error } = await client.from("products").delete().eq("id", id).select("id");
      if (error) throw new EfzDbError("products.remove", error);
      if (!data || data.length === 0) {
        throw new Error(`Product ${id} was not deleted: you may not delete products, or it no longer exists.`);
      }
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
     * Throws if any product is short on stock, or any rule in create_order()
     * refuses it - nothing is written in that case.
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
     * Moves an order through the fulfilment pipeline (update_order_status()).
     * Overrides - leaving delivered, reactivating a cancelled order - and
     * cancelling an order with payments or paid commission need a Super Admin
     * and a reason. Cancelling restores stock; first delivery stamps
     * delivered_at.
     */
    async setStatus(id: string, status: OrderStatus, reason = ""): Promise<void> {
      const { error } = await client.rpc("update_order_status", {
        p_order_id: id,
        p_status: status,
        p_reason: reason,
      });
      if (error) throw new EfzDbError("orders.setStatus", error);
    },

    /**
     * Records one (partial) delivery: record_delivery() moves stock for the
     * delivered balls, earns per-ball commission on per-ball orders and sets
     * partially_delivered / delivered. requestId makes a retry safe: the same
     * id never records a second delivery.
     */
    async recordDelivery(
      orderId: string,
      lines: { orderItemId: string; quantity: number }[],
      options: { note?: string; requestId?: string } = {}
    ): Promise<string> {
      const { data, error } = await client.rpc("record_delivery", {
        p_order_id: orderId,
        p_lines: lines,
        p_note: options.note ?? "",
        p_request_id: options.requestId,
      });
      if (error) throw new EfzDbError("orders.recordDelivery", error);
      return data as string;
    },

    /**
     * The recorded deliveries of the given orders, each with its lines. Read
     * only. RLS returns a delivery only while its order is visible to the
     * caller, so an order this user may not see simply has none here.
     */
    async deliveries(orderIds: string[]): Promise<(OrderDeliveryRow & { lines: OrderDeliveryLineRow[] })[]> {
      if (orderIds.length === 0) return [];
      const deliveries = unwrapList(
        "orders.deliveries",
        await client.from("order_deliveries").select("*").in("order_id", orderIds).order("created_at")
      );
      if (deliveries.length === 0) return [];
      const lines = unwrapList(
        "orders.deliveryLines",
        await client.from("order_delivery_lines").select("*").in("delivery_id", deliveries.map((d) => d.id))
      );
      return deliveries.map((d) => ({ ...d, lines: lines.filter((l) => l.delivery_id === d.id) }));
    },

    /**
     * Super Admin only - NOT part of normal delivery (that is recordDelivery,
     * which never changes the invoice). Corrects a wrong delivered count on one
     * order line, with a written reason. 'keep_invoice': invoice unchanged, the
     * rest stays owed. 'reduce_invoice': line and invoice reduced to the
     * corrected count. Stock, commission and status follow; paid commission is
     * flagged for review. Recorded permanently with before/after values.
     */
    async correctDelivered(
      orderItemId: string,
      newDelivered: number,
      mode: "keep_invoice" | "reduce_invoice",
      reason: string
    ): Promise<string> {
      const { data, error } = await client.rpc("correct_delivered_quantity", {
        p_order_item_id: orderItemId,
        p_new_delivered: newDelivered,
        p_mode: mode,
        p_reason: reason,
      });
      if (error) throw new EfzDbError("orders.correctDelivered", error);
      return data as string;
    },

    /**
     * Delivery notes and the contact phone - the only order fields staff edit
     * directly. Totals, status, dates, customer and officer belong to the
     * database and the RPCs.
     */
    async update(id: string, patch: { deliveryNotes?: string; phone?: string }): Promise<void> {
      const row: OrderUpdate = {};
      if (patch.deliveryNotes !== undefined) row.delivery_notes = patch.deliveryNotes;
      if (patch.phone !== undefined) row.phone = patch.phone;
      if (Object.keys(row).length === 0) return;

      const { error } = await client.from("orders").update(row).eq("id", id);
      if (error) throw new EfzDbError("orders.update", error);
    },

    /**
     * Super Admin only, and only a cancelled order (so its stock is back) with
     * no payments and no paid commission. Anything else is cancelled instead.
     * Asks for the deleted id back so a refusal cannot pass as success.
     */
    async remove(id: string): Promise<void> {
      const { data, error } = await client.from("orders").delete().eq("id", id).select("id");
      if (error) throw new EfzDbError("orders.remove", error);
      if (!data || data.length === 0) {
        throw new Error(`Order ${id} was not deleted: only a Super Admin can delete, and only a cancelled order.`);
      }
    },

    /** Records a payment. Overpayment is refused by the database. */
    async addPayment(input: RecordPaymentInput): Promise<Order> {
      const { error } = await client.rpc("record_payment", {
        p_order_id: input.orderId,
        p_amount: input.amount,
        p_method: input.paymentMethod ?? "Cash",
        // Omitted: the database uses today in Mogadishu.
        ...(input.paymentDate ? { p_date: input.paymentDate } : {}),
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
    /**
     * Called from the public order form. Works for signed-out visitors.
     *
     * No `.select()` after the insert: anon may write a request but never read
     * one back, and RETURNING would be checked against the (absent) anon
     * select policy and fail. The id is generated here instead.
     */
    async submit(input: OrderRequestInput): Promise<string> {
      const id = globalThis.crypto?.randomUUID?.();
      const { error } = await client
        .from("order_requests")
        .insert({
          ...(id ? { id } : {}),
          customer_name: input.customerName,
          phone: input.phone,
          organization: input.organization ?? "",
          product_id: input.productId ?? null,
          product_name: input.productName ?? "",
          quantity: Math.max(1, Math.round(input.quantity)),
          delivery_location: input.deliveryLocation ?? "",
          notes: input.notes ?? "",
        });

      if (error) throw new EfzDbError("orderRequests.submit", error);
      return id ?? "";
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
    /**
     * The commission rules: $ per delivered football, the first-order bonus and
     * the cut-over moment (null until activated). Null before migration 12.
     */
    async policy(): Promise<{ perBallRate: number; firstOrderBonus: number; bonusMinBalls: number; cutoverAt: string | null } | null> {
      const { data, error } = await client
        .from("commission_policy")
        .select("per_ball_rate, first_order_bonus, bonus_min_balls, cutover_at")
        .maybeSingle();
      if (isMissingRelation(error)) return null;
      if (error) throw new EfzDbError("commissions.policy", error);
      if (!data) return null;
      return {
        perBallRate: Number(data.per_ball_rate),
        firstOrderBonus: Number(data.first_order_bonus),
        bonusMinBalls: Number(data.bonus_min_balls),
        cutoverAt: data.cutover_at,
      };
    },

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

    /**
     * The commission events of one officer, exactly as the database recorded
     * them (one row per legacy order, delivery, correction or bonus). Read
     * only. The embedded order is null when the officer may no longer see that
     * order (customer transferred away) - the commission itself stays theirs.
     */
    async mine(userId: string): Promise<CommissionEvent[]> {
      const rows = unwrapList(
        "commissions.mine",
        await client
          .from("commissions")
          .select("*, orders(id, customer_name, order_date, status)")
          .eq("user_id", userId)
          .order("created_at", { ascending: false })
      );
      // The typed schema has no relationship metadata for the embed; the shape is checked by the query itself.
      return rows as unknown as CommissionEvent[];
    },

    /**
     * The commission events recorded on one order that this user may see:
     * their own (an officer) or every officer's (view_all commissions). Read only.
     */
    async forOrder(orderId: string): Promise<CommissionEvent[]> {
      const rows = unwrapList(
        "commissions.forOrder",
        await client
          .from("commissions")
          .select("*, orders(id, customer_name, order_date, status)")
          .eq("order_id", orderId)
          .order("created_at", { ascending: true })
      );
      // The typed schema has no relationship metadata for the embed; the shape is checked by the query itself.
      return rows as unknown as CommissionEvent[];
    },

    /**
     * The rows pay_commissions() will accept for this officer: unpaid
     * (pending / approved), above $0, not flagged for review, and earned -
     * per-ball delivery commission once delivered (also on a partially
     * delivered order); legacy and bonus commission on a delivered order. The
     * database checks every one of these again, under lock, all or nothing.
     */
    async payable(userId: string) {
      const rows = await commissions.list({ userId });
      return rows.filter((row) => {
        const order = (row as typeof row & { orders: { status: OrderStatus } | null }).orders;
        const perBallDelivery = row.kind === "delivery" || row.kind === "correction";
        return (
          (row.status === "pending" || row.status === "approved") &&
          Number(row.amount) > 0 &&
          !row.review_required &&
          (order?.status === "delivered" || (perBallDelivery && order?.status === "partially_delivered"))
        );
      });
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

    /**
     * Commission eligibility (migration 16), current state per Marketing Officer:
     * an officer gets only their own row, the Super Admin and commission
     * management every officer. Empty before migration 16 (everyone earns).
     */
    async eligibility(): Promise<CommissionEligibilityStatusRow[]> {
      const { data, error } = await client.from("commission_eligibility_status").select("*");
      if (isMissingRelation(error)) return [];
      if (error) throw new EfzDbError("commissions.eligibility", error);
      return data ?? [];
    },

    /** Every ON/OFF change of one officer, newest first (Super Admin / commission management only). */
    async eligibilityHistory(officerId: string): Promise<CommissionEligibilityChangeRow[]> {
      const { data, error } = await client
        .from("commission_eligibility_changes")
        .select("*")
        .eq("officer_id", officerId)
        .order("seq", { ascending: false });
      if (isMissingRelation(error)) return [];
      if (error) throw new EfzDbError("commissions.eligibilityHistory", error);
      return data ?? [];
    },

    /**
     * Super Admin only: switch a Marketing Officer's commission eligibility, with a
     * written reason. Affects future commission events only; the database refuses
     * everyone else, a missing reason and a no-op change.
     */
    async setEligibility(officerId: string, eligible: boolean, reason: string): Promise<string> {
      const { data, error } = await client.rpc("set_commission_eligibility", {
        p_officer_id: officerId,
        p_eligible: eligible,
        p_reason: reason,
      });
      if (error) throw new EfzDbError("commissions.setEligibility", error);
      return data as string;
    },
  };

  // -------------------------------------------------------------------------
  // Analytics
  // -------------------------------------------------------------------------
  const analytics = {
    /**
     * "Collected by Me": payments the signed-in Marketing Officer personally
     * recorded (payments.recorded_by), including ones on orders they can no
     * longer see. Aggregates only, from my_collected_payments() (migration 13),
     * which takes no parameters and refuses anyone but an active officer.
     * Null when the function is not installed yet - never a guessed number.
     */
    async collectedByMe(): Promise<{ total: number; thisMonth: number; payments: number } | null> {
      const { data, error } = await client.rpc("my_collected_payments");
      if (error && (error.code === "PGRST202" || error.code === "42883")) return null;
      if (error) throw new EfzDbError("analytics.collectedByMe", error);
      const row = Array.isArray(data) ? data[0] : null;
      if (!row) return null;
      return { total: Number(row.total_amount), thisMonth: Number(row.this_month_amount), payments: Number(row.payment_count) };
    },

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
            .select("id", { count: "exact", head: true });
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
        .select("id", { count: "exact", head: true });
      if (error) throw new EfzDbError("logs.count", error);
      return count ?? 0;
    },

    /**
     * One page of the audit trail with every filter applied in the database,
     * newest first, plus the total number of matching rows. Runs as the signed-in
     * user, so RLS (system_logs_select: view_audit_trail) decides what exists.
     */
    async search(filter: AuditLogFilter, page: { offset: number; limit: number }): Promise<{ rows: SystemLog[]; total: number }> {
      const result = await applyAuditFilter(client.from("system_logs").select("*", { count: "exact" }), filter)
        .order("occurred_at", { ascending: false })
        .order("id", { ascending: false })
        .range(page.offset, page.offset + page.limit - 1);
      if (result.error) throw new EfzDbError("logs.search", result.error);
      return { rows: (result.data ?? []).map(toSystemLog), total: result.count ?? 0 };
    },

    /** How many rows match the filter, optionally narrowed further (summary cards). */
    async countWhere(filter: AuditLogFilter, extra: Partial<AuditLogFilter> & { messageLike?: string[] } = {}): Promise<number> {
      let query = applyAuditFilter(client.from("system_logs").select("id", { count: "exact", head: true }), filter);
      if (extra.category) query = query.eq("category", extra.category);
      if (extra.severities?.length) query = query.in("severity", extra.severities);
      if (extra.messageLike?.length) query = query.or(extra.messageLike.map((m) => `message.ilike.${quoteLike(m)}`).join(","));
      const { count, error } = await query;
      if (error) throw new EfzDbError("logs.countWhere", error);
      return count ?? 0;
    },

    /**
     * EVERY row matching the filter (not just the page on screen), for export.
     * Same query and RLS as search(); fetched in batches in a stable order.
     * Refuses rather than truncating silently above `max`.
     */
    async exportAll(filter: AuditLogFilter, max = 50_000): Promise<SystemLog[]> {
      const BATCH = 1000;
      const out: SystemLog[] = [];
      for (let offset = 0; ; offset += BATCH) {
        const result = await applyAuditFilter(client.from("system_logs").select("*", { count: offset === 0 ? "exact" : undefined }), filter)
          .order("occurred_at", { ascending: false })
          .order("id", { ascending: false })
          .range(offset, offset + BATCH - 1);
        if (result.error) throw new EfzDbError("logs.exportAll", result.error);
        if (offset === 0 && (result.count ?? 0) > max) {
          throw new Error(`${result.count} audit events match these filters; narrow them (for example by date) to export at most ${max} at a time.`);
        }
        const rows = result.data ?? [];
        out.push(...rows.map(toSystemLog));
        if (rows.length < BATCH) return out;
      }
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
     * Ids are deterministic (`low-prod-123`, `order-ORD-456@u-1`) and duplicates
     * are ignored, so re-running this on every refresh never piles up copies and
     * an alert someone already read stays read. `userId` makes an alert personal
     * (RLS shows it to that user only); without it the alert is shared by all staff.
     */
    async upsertAlerts(
      alerts: Array<Pick<Notification, "id" | "title" | "message" | "type"> & { userId?: string | null }>
    ): Promise<void> {
      if (alerts.length === 0) return;

      const { error } = await client.from("notifications").upsert(
        alerts.map((alert) => ({
          id: alert.id,
          title: alert.title,
          message: alert.message,
          type: alert.type,
          user_id: alert.userId ?? null,
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

    /**
     * Global company settings: business name, brand, contact, colours, theme.
     * Only an active Super Admin may write them (RLS settings_update and
     * settings_insert = is_super_admin(), migration 14; a change_settings grant
     * does not open them to anyone else). RLS refuses by updating zero rows without
     * an error, so that is reported as a refusal here. One UPDATE statement:
     * either every field in the patch is saved or none is.
     */
    async update(patch: Partial<AdminSettings>): Promise<AdminSettings> {
      const { data, error } = await client.from("settings").update(fromSettings(patch)).eq("id", true).select();
      if (error) throw new EfzDbError("settings.update", error);
      if (!data || data.length === 0) {
        throw new Error("Company settings were not changed: only a Super Admin can change them.");
      }
      return toSettings(data[0]);
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
          client.from("profiles").select(PROFILE_COLUMNS),
          client.from("customers").select(CUSTOMER_COLUMNS),
          // products.cost_price is not selectable; the view carries it for a
          // user who may see cost (manage_system holders normally can).
          client.from("staff_products").select(STAFF_PRODUCT_COLUMNS),
          client.from("order_details").select("*"),
          client.from("stock_movements").select("*"),
          client.from("settings").select("*").eq("id", true).single(),
        ]);

      // A table that failed to read must fail the backup, not become an
      // empty array in a file that looks complete.
      const failed = (
        [
          ["profiles", profileRows.error],
          ["customers", customerRows.error],
          ["products", productRows.error],
          ["orders", orderRows.error],
          ["stock_movements", movementRows.error],
          ["settings", settingsRow.error],
        ] as const
      ).find(([, err]) => err);
      if (failed) throw new EfzDbError(`backups.create(${failed[0]})`, failed[1]!);

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
