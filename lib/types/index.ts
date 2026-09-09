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

export type UserRole = 'Super Admin' | 'Manager' | 'Marketing Officer' | 'Inventory Staff' | 'Delivery Staff';

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
  registeredBy: string; // User ID who registered them
  marketingOfficerId?: string; // Explicit link to Marketing Officer
  date: string;
  notes?: string;
  isArchived?: boolean;
  status?: 'active' | 'archived';
};

export type OrderStatus = 'pending' | 'confirmed' | 'processing' | 'delivered' | 'cancelled';
export type OrderType = 'regular' | 'trial';
export type PaymentStatus = 'unpaid' | 'partial' | 'paid' | 'refunded' | 'credit';

// Valid fulfillment status transitions
export const ORDER_STATUS_TRANSITIONS: Record<OrderStatus, OrderStatus[]> = {
  pending: ['confirmed', 'cancelled'],
  confirmed: ['processing', 'cancelled'],
  processing: ['delivered', 'cancelled'],
  delivered: [], // Terminal — Super Admin can override
  cancelled: ['pending'], // Reactivate — requires stock check + Super Admin
};

export type OrderItem = {
  id?: string;
  productId: string;
  productName: string;
  designName?: string;
  quantity: number;
  standardUnitPrice: number;
  actualUnitPrice: number; // Actual negotiated unit selling price
  historicalUnitCost?: number; // Historical unit cost snapshot
  costPrice?: number;
  price?: number; // Back-compat alias for actual negotiated unit price
  lineRevenue?: number;
  lineCost?: number;
  lineProfit?: number;
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
  cost: number;
  grossProfit: number;
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
  costPrice: number;
  sellingPrice: number;
  stock: number;
  lowStockThreshold: number;
  imageUrl: string;
  category: "Football" | "Futsal" | "Accessories";
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
