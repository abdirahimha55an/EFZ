/**
 * Row <-> app-type translation.
 *
 * The database speaks snake_case; every component in this repo already speaks
 * the camelCase types in lib/types. These functions are the only place the two
 * meet, so the UI never has to learn the column names.
 */

import type {
  AdminSettings,
  AdminUser,
  Customer,
  Notification,
  Order,
  OrderItem,
  PaymentRecord,
  Permission,
  Product,
  StockMovement,
  SystemIssue,
  SystemLog,
} from "@/lib/types";

import type {
  CustomerRow,
  CustomerUpdate,
  NotificationRow,
  OrderDetailsRow,
  ProductRow,
  ProductUpdate,
  ProfileRow,
  ProfileUpdate,
  PublicProductRow,
  SettingsRow,
  SettingsUpdate,
  StockMovementRow,
  SystemIssueRow,
  SystemLogRow,
  TestimonialRow,
} from "./database.types";

const num = (value: unknown, fallback = 0): number => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
};

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------

export function toAdminUser(row: ProfileRow, permissions: string[] = []): AdminUser {
  return {
    id: row.id,
    name: row.name,
    email: row.email,
    phone: row.phone,
    avatar: row.avatar,
    role: row.role,
    status: row.status,
    commissionPercentage: num(row.commission_percentage),
    earnedCommissionTotal: num(row.earned_commission_total),
    pendingCommissionTotal: num(row.pending_commission_total),
    paidCommissionTotal: num(row.paid_commission_total),
    permissions: permissions as Permission[],
  };
}

export function fromAdminUser(user: Partial<AdminUser>): ProfileUpdate {
  const row: ProfileUpdate = {};
  if (user.id !== undefined) row.id = user.id;
  if (user.name !== undefined) row.name = user.name;
  if (user.email !== undefined) row.email = user.email;
  if (user.phone !== undefined) row.phone = user.phone;
  if (user.avatar !== undefined) row.avatar = user.avatar;
  if (user.role !== undefined) row.role = user.role;
  if (user.status !== undefined) row.status = user.status;
  if (user.commissionPercentage !== undefined) {
    row.commission_percentage = num(user.commissionPercentage);
  }
  // Commission totals are maintained by the ledger triggers, never by clients.
  return row;
}

// ---------------------------------------------------------------------------
// Customers
// ---------------------------------------------------------------------------

export function toCustomer(row: CustomerRow): Customer {
  const archived = row.status === "archived";
  return {
    id: row.id,
    name: row.name,
    email: row.email,
    phone: row.phone,
    registeredBy: row.registered_by ?? "",
    marketingOfficerId: row.marketing_officer_id ?? undefined,
    date: row.registered_on,
    notes: row.notes,
    isArchived: archived,
    status: archived ? "archived" : "active",
  };
}

export function fromCustomer(customer: Partial<Customer>): CustomerUpdate {
  const row: CustomerUpdate = {};
  if (customer.id !== undefined) row.id = customer.id;
  if (customer.name !== undefined) row.name = customer.name;
  if (customer.email !== undefined) row.email = customer.email ?? "";
  if (customer.phone !== undefined) row.phone = customer.phone;
  if (customer.registeredBy !== undefined) row.registered_by = customer.registeredBy || null;
  if (customer.marketingOfficerId !== undefined) {
    row.marketing_officer_id = customer.marketingOfficerId || null;
  }
  if (customer.date !== undefined) row.registered_on = customer.date;
  if (customer.notes !== undefined) row.notes = customer.notes ?? "";
  if (customer.status !== undefined || customer.isArchived !== undefined) {
    row.status = customer.status === "archived" || customer.isArchived ? "archived" : "active";
  }
  return row;
}

// ---------------------------------------------------------------------------
// Products
// ---------------------------------------------------------------------------

export function toProduct(row: ProductRow): Product {
  const selling = num(row.selling_price);
  return {
    id: row.id,
    name: row.name,
    description: row.description,
    size: row.size,
    durability: row.durability,
    surfaceType: row.surface_type,
    isWholesale: row.is_wholesale,
    price: selling,
    costPrice: num(row.cost_price),
    sellingPrice: selling,
    stock: num(row.stock),
    lowStockThreshold: num(row.low_stock_threshold),
    imageUrl: row.image_url,
    category: row.category,
  };
}

export function fromProduct(product: Partial<Product>): ProductUpdate {
  const row: ProductUpdate = {};
  if (product.id !== undefined) row.id = product.id;
  if (product.name !== undefined) row.name = product.name;
  if (product.description !== undefined) row.description = product.description ?? "";
  if (product.category !== undefined) row.category = product.category;
  if (product.size !== undefined) row.size = product.size ?? "";
  if (product.durability !== undefined) row.durability = product.durability ?? "";
  if (product.surfaceType !== undefined) row.surface_type = product.surfaceType ?? "";
  if (product.isWholesale !== undefined) row.is_wholesale = Boolean(product.isWholesale);
  if (product.costPrice !== undefined) row.cost_price = Math.max(0, num(product.costPrice));
  if (product.sellingPrice !== undefined || product.price !== undefined) {
    row.selling_price = Math.max(0, num(product.sellingPrice ?? product.price));
  }
  if (product.stock !== undefined) row.stock = Math.max(0, Math.round(num(product.stock)));
  if (product.lowStockThreshold !== undefined) {
    row.low_stock_threshold = Math.max(0, Math.round(num(product.lowStockThreshold)));
  }
  if (product.imageUrl !== undefined) row.image_url = product.imageUrl ?? "";
  // `price` is a generated column - writing it would be rejected.
  return row;
}

// ---------------------------------------------------------------------------
// Orders
// ---------------------------------------------------------------------------

export function toOrder(row: OrderDetailsRow): Order {
  const items: OrderItem[] = (row.items ?? []).map((item) => ({
    id: item.id,
    productId: item.productId ?? "",
    productName: item.productName,
    designName: item.designName,
    quantity: num(item.quantity),
    standardUnitPrice: num(item.standardUnitPrice),
    actualUnitPrice: num(item.actualUnitPrice),
    price: num(item.price),
    historicalUnitCost: num(item.historicalUnitCost),
    costPrice: num(item.costPrice),
    lineRevenue: num(item.lineRevenue),
    lineCost: num(item.lineCost),
    lineProfit: num(item.lineProfit),
  }));

  const payments: PaymentRecord[] = (row.payments ?? []).map((payment) => ({
    id: payment.id,
    orderId: payment.orderId,
    amount: num(payment.amount),
    paymentDate: payment.paymentDate,
    paymentMethod: payment.paymentMethod,
    reference: payment.reference,
    notes: payment.notes,
    note: payment.notes,
    recordedBy: payment.recordedBy ?? undefined,
    createdAt: payment.createdAt,
  }));

  const total = num(row.total);

  return {
    id: row.id,
    customer: row.customer_name,
    customerId: row.customer_id ?? undefined,
    customerName: row.customer_name,
    customerPhone: row.phone,
    marketingOfficerId: row.marketing_officer_id ?? undefined,
    phone: row.phone,
    items,
    total,
    totalAmount: total,
    status: row.status,
    paymentStatus: row.payment_status,
    orderType: row.order_type,
    date: row.order_date,
    deliveryNotes: row.delivery_notes,
    cost: num(row.cost),
    grossProfit: num(row.gross_profit),
    amountPaid: num(row.amount_paid),
    outstandingBalance: num(row.outstanding_balance),
    commissionPaid: row.commission_paid,
    legacyOrderIds: row.legacy_order_ids ?? [],
    legacyReferenceId: row.legacy_reference_id ?? undefined,
    createdAt: row.created_at,
    payments,
  };
}

// ---------------------------------------------------------------------------
// Inventory, logs, diagnostics
// ---------------------------------------------------------------------------

export function toStockMovement(row: StockMovementRow): StockMovement {
  return {
    id: row.id,
    productId: row.product_id,
    productName: row.product_name,
    type: row.type,
    quantityChange: num(row.quantity_change),
    reason: row.reason,
    createdBy: row.created_by ?? "",
    timestamp: row.created_at,
  };
}

export function toSystemLog(row: SystemLogRow): SystemLog {
  return {
    id: row.id,
    timestamp: row.occurred_at,
    severity: row.severity,
    category: row.category,
    message: row.message,
    userId: row.user_id ?? undefined,
    username: row.username || undefined,
    targetId: row.target_id ?? undefined,
    metadata: (row.metadata ?? {}) as Record<string, unknown>,
  };
}

export function toSystemIssue(row: SystemIssueRow): SystemIssue {
  return {
    id: row.id,
    title: row.title,
    severity: row.severity,
    source: row.source,
    affectedEntityType: row.affected_entity_type ?? undefined,
    affectedEntityId: row.affected_entity_id ?? undefined,
    linkedSystem: row.linked_system ?? undefined,
    impact: row.impact ?? undefined,
    affectedCount: row.affected_count,
    explanation: row.explanation,
    recommendedAction: row.recommended_action,
    repairable: row.repairable,
    createdAt: row.created_at,
    lastDetectedAt: row.last_detected_at,
  };
}

export function toNotification(row: NotificationRow): Notification {
  return {
    id: row.id,
    title: row.title,
    message: row.message,
    type: row.type,
    date: row.created_at,
    read: row.read,
  };
}

// ---------------------------------------------------------------------------
// Settings and marketing content
// ---------------------------------------------------------------------------

export function toSettings(row: SettingsRow): AdminSettings {
  return {
    businessName: row.business_name,
    shortName: row.short_name,
    logo: row.logo,
    favicon: row.favicon,
    whatsappNumber: row.whatsapp_number,
    contactEmail: row.contact_email,
    defaultLowStockThreshold: num(row.default_low_stock_threshold, 50),
    currencySymbol: row.currency_symbol,
    theme: row.theme,
    primaryColor: row.primary_color,
    secondaryColor: row.secondary_color,
  };
}

export function fromSettings(settings: Partial<AdminSettings>): SettingsUpdate {
  const row: SettingsUpdate = {};
  if (settings.businessName !== undefined) row.business_name = settings.businessName;
  if (settings.shortName !== undefined) row.short_name = settings.shortName;
  if (settings.logo !== undefined) row.logo = settings.logo;
  if (settings.favicon !== undefined) row.favicon = settings.favicon;
  if (settings.whatsappNumber !== undefined) row.whatsapp_number = settings.whatsappNumber;
  if (settings.contactEmail !== undefined) row.contact_email = settings.contactEmail;
  if (settings.defaultLowStockThreshold !== undefined) {
    row.default_low_stock_threshold = num(settings.defaultLowStockThreshold, 50);
  }
  if (settings.currencySymbol !== undefined) row.currency_symbol = settings.currencySymbol;
  if (settings.theme !== undefined) row.theme = settings.theme;
  if (settings.primaryColor !== undefined) row.primary_color = settings.primaryColor;
  if (settings.secondaryColor !== undefined) row.secondary_color = settings.secondaryColor;
  return row;
}

/**
 * Maps the anon-safe product feed onto the same Product shape the public pages
 * already render. cost_price and the exact stock number are absent from the
 * view, so they land as zero here - the public site never displays either.
 */
export function toPublicProduct(row: PublicProductRow): Product {
  const selling = num(row.selling_price);
  return {
    id: row.id,
    name: row.name,
    description: row.description,
    size: row.size,
    durability: row.durability,
    surfaceType: row.surface_type,
    isWholesale: row.is_wholesale,
    price: selling,
    costPrice: 0,
    sellingPrice: selling,
    stock: row.in_stock ? 1 : 0,
    lowStockThreshold: 0,
    imageUrl: row.image_url,
    category: row.category,
  };
}

export type Testimonial = {
  id: string;
  name: string;
  role: string;
  content: string;
};

export function toTestimonial(row: TestimonialRow): Testimonial {
  return {
    id: row.id,
    name: row.name,
    role: row.role,
    content: row.content,
  };
}
