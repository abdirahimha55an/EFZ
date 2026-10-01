export const OFFICIAL_PERMISSIONS = [
  'view_dashboard', 'view_orders', 'create_orders', 'edit_orders', 'delete_orders',
  'view_products', 'add_products', 'edit_products', 'delete_products',
  'view_inventory', 'adjust_stock', 'view_customers', 'add_customers', 
  'edit_customers', 'delete_customers', 'view_reports', 'view_commissions', 
  'mark_commissions_paid', 'manage_users', 'change_settings',
  'view_all_customers', 'view_own_customers_only',
  'view_diagnostics', 'view_audit_trail', 'manage_system',
  'override_order_status'
] as const;

export type Permission = typeof OFFICIAL_PERMISSIONS[number];

export const USER_ROLES = [
  'Super Admin', 'Manager', 'Marketing Officer', 'Customer Service', 'Inventory Staff', 'Delivery Staff',
] as const;

export type UserRole = typeof USER_ROLES[number];

export type AdminUser = {
  id: string;
  name: string;
  email: string;
  phone: string;
  password?: string;
  avatar: string;
  role: UserRole;
  status: 'active' | 'inactive';
  commissionPercentage: number;
  earnedCommissionTotal: number;
  pendingCommissionTotal: number;
  paidCommissionTotal: number;
  permissions: Permission[];
};

export type AdminProfile = AdminUser;

export type Customer = {
  id: string;
  name: string;
  email?: string;
  phone: string;
  /** Staff member who typed the record in. Set by the database, never by the app. */
  registeredBy: string;
  /**
   * The acquiring Marketing Officer - the commission owner. Undefined means the
   * customer is unassigned. Changes only through transfer_customer_owner().
   */
  marketingOfficerId?: string;
  date: string;
  notes?: string;
  isArchived?: boolean;
  status?: 'active' | 'archived';
};

/** One row of customer_ownership_changes: an audited officer assignment or transfer. */
export type CustomerOwnershipChange = {
  id: string;
  customerId: string;
  customerName: string;
  oldOfficerId: string | null;
  oldOfficerName: string;
  newOfficerId: string | null;
  newOfficerName: string;
  reason: string;
  ordersMoved: string[];
  changedBy: string | null;
  changedByName: string;
  changedAt: string;
};

export type OrderStatus = 'pending' | 'confirmed' | 'processing' | 'delivered' | 'cancelled';
export type OrderType = 'regular' | 'trial';
export type PaymentStatus = 'unpaid' | 'partial' | 'paid' | 'refunded' | 'credit';

/**
 * The normal fulfilment pipeline, identical to update_order_status() in
 * supabase/10_rpc_hardening.sql. Anything not listed - leaving delivered,
 * reactivating a cancelled order - is a Super Admin override with a reason.
 */
export const ORDER_STATUS_TRANSITIONS: Record<OrderStatus, OrderStatus[]> = {
  pending: ['confirmed', 'cancelled'],
  confirmed: ['processing', 'cancelled'],
  processing: ['delivered', 'cancelled'],
  delivered: [],
  cancelled: [],
};

export const ORDER_STATUSES: OrderStatus[] = ['pending', 'confirmed', 'processing', 'delivered', 'cancelled'];

export type OrderItem = {
  id?: string;
  productId: string;
  productName: string;
  designName?: string;
  quantity: number;
  standardUnitPrice: number;
  actualUnitPrice: number; // Actual negotiated unit selling price
  // Cost fields are null when the database withholds cost from this user
  // (no view_inventory / view_reports). Never treat null as zero.
  historicalUnitCost?: number | null; // Historical unit cost snapshot
  costPrice?: number | null;
  price?: number; // Back-compat alias for actual negotiated unit price
  lineRevenue?: number;
  lineCost?: number | null;
  lineProfit?: number | null;
};

export type PaymentRecord = {
  id: string;
  orderId: string;
  amount: number;
  paymentDate: string;
  paymentMethod?: string;
  notes?: string;
  note?: string;
  reference?: string;
  recordedBy?: string;
  createdAt?: string;
};

export type Order = {
  id: string;
  customer: string;
  customerId?: string;
  marketingOfficerId?: string;
  phone: string;
  items: OrderItem[];
  total: number;
  status: OrderStatus;
  paymentStatus: PaymentStatus;
  date: string;
  deliveryNotes?: string;
  /** Null when the database withholds cost from this user. */
  cost: number | null;
  /** Null when the database withholds cost from this user. */
  grossProfit: number | null;
  /** Set by update_order_status() on first delivery; null for undelivered and pre-2026-09-29 orders. */
  deliveredAt: string | null;
  /** Follows the customer's owner; display only. */
  marketingOfficerName: string | null;
  commissionPaid?: boolean;
  product?: string;
  qty?: number;
  customerName?: string;
  customerPhone?: string;
  totalAmount?: number;
  orderType?: OrderType;
  legacyOrderIds?: string[];
  legacyReferenceId?: string;
  amountPaid?: number;
  outstandingBalance?: number;
  paymentMethod?: string;
  createdAt?: string;
  payments?: PaymentRecord[];
};

export type StockMovement = {
  id: string;
  productId: string;
  productName: string;
  type: 'sale' | 'manual_adjustment' | 'correction' | 'return' | 'import';
  quantityChange: number;
  reason: string;
  createdBy: string;
  timestamp: string;
};

export type Product = {
  id: string;
  name: string;
  description: string;
  size: string;
  durability: string;
  surfaceType: string;
  isWholesale: boolean;
  price: number; // Legacy alias for sellingPrice
  /** Null when the database withholds cost from this user. */
  costPrice: number | null;
  sellingPrice: number;
  stock: number;
  lowStockThreshold: number;
  imageUrl: string;
  category: "Football" | "Futsal" | "Accessories";
  isActive?: boolean;
};

export type LogSeverity = 'INFO' | 'WARNING' | 'ERROR' | 'CRITICAL';
export type LogCategory = 'SECURITY' | 'FINANCIAL' | 'INVENTORY' | 'CUSTOMER' | 'SYSTEM' | 'AUTH' | 'STORAGE' | 'ORDER' | 'PRODUCT';

export type SystemLog = {
  id: string;
  timestamp: string;
  severity: LogSeverity;
  category: LogCategory;
  message: string;
  userId?: string;
  username?: string;
  targetId?: string;
  metadata?: Record<string, any>;
  /** Who wrote the line: the database, a browser, or unknown (null: written before migration 11). */
  origin?: 'database' | 'client' | null;
};

export type SystemIssue = {
  id: string;
  title: string;
  severity: LogSeverity;
  source: string;
  affectedEntityType?: string;
  affectedEntityId?: string;
  linkedSystem?: string;
  impact?: string;
  affectedCount?: number;
  explanation: string;
  recommendedAction: string;
  repairable: boolean;
  createdAt: string;
  lastDetectedAt: string;
};

export type Notification = {
  id: string;
  title: string;
  message: string;
  type: 'stock' | 'order' | 'system';
  date: string;
  read: boolean;
};

export type AdminSettings = {
  businessName: string;
  shortName: string;
  logo: string;
  favicon: string;
  whatsappNumber: string;
  contactEmail: string;
  defaultLowStockThreshold: number;
  currencySymbol: string;
  theme: 'light' | 'dark';
  primaryColor: string;
  secondaryColor: string;
};
