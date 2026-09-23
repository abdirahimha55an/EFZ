/**
 * Hand-written mirror of the schema in supabase/01_schema.sql.
 *
 * Once the project is linked you can regenerate this file instead of editing it:
 *   npx supabase gen types typescript --project-id <ref> > lib/supabase/database.types.ts
 */

export type Json = string | number | boolean | null | { [key: string]: Json } | Json[];

export type DbUserRole =
  | "Super Admin"
  | "Manager"
  | "Marketing Officer"
  | "Inventory Staff"
  | "Delivery Staff";

export type DbUserStatus = "active" | "inactive";
export type DbCustomerStatus = "active" | "archived";
export type DbProductCategory = "Football" | "Futsal" | "Accessories";
export type DbOrderStatus = "pending" | "confirmed" | "processing" | "delivered" | "cancelled";
export type DbOrderType = "regular" | "trial";
export type DbPaymentStatus = "unpaid" | "partial" | "paid" | "refunded" | "credit";
export type DbStockMovementType =
  | "sale"
  | "manual_adjustment"
  | "correction"
  | "return"
  | "import";
export type DbLogSeverity = "INFO" | "WARNING" | "ERROR" | "CRITICAL";
export type DbLogCategory =
  | "SECURITY"
  | "FINANCIAL"
  | "INVENTORY"
  | "CUSTOMER"
  | "SYSTEM"
  | "AUTH"
  | "STORAGE"
  | "ORDER"
  | "PRODUCT";
export type DbCommissionStatus = "pending" | "approved" | "paid" | "void";
export type DbNotificationType = "stock" | "order" | "system";
export type DbOrderRequestStatus = "new" | "contacted" | "converted" | "rejected";

export type ProfileRow = {
  id: string;
  auth_user_id: string | null;
  name: string;
  email: string;
  phone: string;
  avatar: string;
  role: DbUserRole;
  status: DbUserStatus;
  commission_percentage: number;
  earned_commission_total: number;
  pending_commission_total: number;
  paid_commission_total: number;
  created_at: string;
  updated_at: string;
};

export type PermissionRow = {
  code: string;
  label: string;
  category: string;
  sort_order: number;
};

export type UserPermissionRow = {
  user_id: string;
  permission_code: string;
  granted_at: string;
};

export type CustomerRow = {
  id: string;
  name: string;
  email: string;
  phone: string;
  registered_by: string | null;
  marketing_officer_id: string | null;
  registered_on: string;
  notes: string;
  status: DbCustomerStatus;
  created_at: string;
  updated_at: string;
};

export type ProductRow = {
  id: string;
  name: string;
  description: string;
  category: DbProductCategory;
  size: string;
  durability: string;
  surface_type: string;
  is_wholesale: boolean;
  cost_price: number;
  selling_price: number;
  stock: number;
  low_stock_threshold: number;
  image_url: string;
  is_active: boolean;
  /** Generated column, always mirrors selling_price. Never write to it. */
  price: number;
  created_at: string;
  updated_at: string;
};

export type StockMovementRow = {
  id: string;
  product_id: string;
  product_name: string;
  type: DbStockMovementType;
  quantity_change: number;
  reason: string;
  created_by: string | null;
  created_at: string;
};

export type OrderRow = {
  id: string;
  customer_id: string | null;
  customer_name: string;
  phone: string;
  marketing_officer_id: string | null;
  status: DbOrderStatus;
  payment_status: DbPaymentStatus;
  order_type: DbOrderType;
  order_date: string;
  delivery_notes: string;
  total: number;
  cost: number;
  gross_profit: number;
  amount_paid: number;
  outstanding_balance: number;
  commission_paid: boolean;
  legacy_order_ids: string[];
  legacy_reference_id: string | null;
  created_by: string | null;
  created_at: string;
  updated_at: string;
};

export type OrderItemRow = {
  id: string;
  order_id: string;
  product_id: string | null;
  product_name: string;
  design_name: string;
  quantity: number;
  standard_unit_price: number;
  actual_unit_price: number;
  historical_unit_cost: number;
  /** Generated columns. Never write to them. */
  line_revenue: number;
  line_cost: number;
  line_profit: number;
  created_at: string;
};

export type PaymentRow = {
  id: string;
  order_id: string;
  amount: number;
  payment_date: string;
  payment_method: string;
  reference: string;
  notes: string;
  recorded_by: string | null;
  created_at: string;
};

export type OrderRequestRow = {
  id: string;
  customer_name: string;
  phone: string;
  organization: string;
  product_id: string | null;
  product_name: string;
  quantity: number;
  delivery_location: string;
  notes: string;
  status: DbOrderRequestStatus;
  converted_order_id: string | null;
  handled_by: string | null;
  created_at: string;
  updated_at: string;
};

export type CommissionRow = {
  id: string;
  order_id: string;
  user_id: string;
  rate: number;
  base_amount: number;
  amount: number;
  status: DbCommissionStatus;
  payout_id: string | null;
  note: string;
  created_at: string;
  updated_at: string;
};

export type CommissionPayoutRow = {
  id: string;
  user_id: string;
  amount: number;
  method: string;
  reference: string;
  notes: string;
  paid_by: string | null;
  paid_at: string;
  created_at: string;
};

export type SystemLogRow = {
  id: string;
  occurred_at: string;
  severity: DbLogSeverity;
  category: DbLogCategory;
  message: string;
  user_id: string | null;
  username: string;
  target_id: string | null;
  metadata: Json;
};

export type SystemIssueRow = {
  id: string;
  title: string;
  severity: DbLogSeverity;
  source: string;
  affected_entity_type: string | null;
  affected_entity_id: string | null;
  linked_system: string | null;
  impact: string | null;
  affected_count: number;
  explanation: string;
  recommended_action: string;
  repairable: boolean;
  resolved_at: string | null;
  created_at: string;
  last_detected_at: string;
};

export type NotificationRow = {
  id: string;
  title: string;
  message: string;
  type: DbNotificationType;
  user_id: string | null;
  read: boolean;
  created_at: string;
};

export type SettingsRow = {
  id: boolean;
  business_name: string;
  short_name: string;
  logo: string;
  favicon: string;
  whatsapp_number: string;
  contact_email: string;
  default_low_stock_threshold: number;
  currency_symbol: string;
  theme: "light" | "dark";
  primary_color: string;
  secondary_color: string;
  updated_by: string | null;
  updated_at: string;
};

export type BackupRow = {
  id: string;
  label: string;
  storage_path: string | null;
  payload: Json | null;
  record_counts: Json;
  size_bytes: number;
  created_by: string | null;
  created_at: string;
};

export type TestimonialRow = {
  id: string;
  name: string;
  role: string;
  content: string;
  is_published: boolean;
  sort_order: number;
  created_at: string;
};

/** Nested JSON shapes produced by the order_details view. */
export type OrderDetailItem = {
  id: string;
  productId: string | null;
  productName: string;
  designName: string;
  quantity: number;
  standardUnitPrice: number;
  actualUnitPrice: number;
  price: number;
  historicalUnitCost: number;
  costPrice: number;
  lineRevenue: number;
  lineCost: number;
  lineProfit: number;
};

export type OrderDetailPayment = {
  id: string;
  orderId: string;
  amount: number;
  paymentDate: string;
  paymentMethod: string;
  reference: string;
  notes: string;
  recordedBy: string | null;
  createdAt: string;
};

export type OrderDetailsRow = Omit<
  OrderRow,
  "created_by" | "legacy_order_ids"
> & {
  marketing_officer_name: string | null;
  legacy_order_ids: string[];
  items: OrderDetailItem[];
  payments: OrderDetailPayment[];
  unit_count: number;
};

export type PublicProductRow = {
  id: string;
  name: string;
  description: string;
  category: DbProductCategory;
  size: string;
  durability: string;
  surface_type: string;
  is_wholesale: boolean;
  selling_price: number;
  price: number;
  image_url: string;
  in_stock: boolean;
};

export type InventoryStatusRow = {
  id: string;
  name: string;
  category: DbProductCategory;
  stock: number;
  low_stock_threshold: number;
  cost_price: number;
  selling_price: number;
  unit_margin: number;
  margin_percentage: number;
  stock_value_at_cost: number;
  stock_state: "out_of_stock" | "low_stock" | "healthy";
  units_sold: number;
  is_active: boolean;
};

export type CustomerFinancialsRow = {
  id: string;
  name: string;
  phone: string;
  email: string;
  status: DbCustomerStatus;
  marketing_officer_id: string | null;
  marketing_officer_name: string | null;
  registered_on: string;
  total_orders: number;
  total_units: number;
  revenue_generated: number;
  cash_collected: number;
  outstanding: number;
  last_order_date: string | null;
  payment_status: "paid" | "partial" | "unpaid";
};

export type OfficerCommissionSummaryRow = {
  user_id: string;
  name: string;
  role: DbUserRole;
  status: DbUserStatus;
  commission_percentage: number;
  earned_commission: number;
  paid_commission: number;
  pending_commission: number;
  commissionable_orders: number;
  customers_registered: number;
};

export type FinancialSummaryRow = {
  total_orders: number;
  revenue_generated: number;
  total_cost: number;
  gross_profit: number;
  cash_collected: number;
  outstanding_receivables: number;
  total_units: number;
  gross_margin: number;
};

export type DailySalesRow = {
  order_date: string;
  order_count: number;
  revenue: number;
  cost: number;
  gross_profit: number;
  collected: number;
  units_sold: number;
};

/** Shape returned by the operational_metrics() RPC. */
export type OperationalMetrics = {
  health: { score: number; status: "Healthy" | "Degraded" | "At Risk" | "Critical" };
  issues: { open: number; critical: number };
  runtime: { engine: string; exceptions24h: number; serverTime: string };
  records: {
    products: number;
    orders: number;
    orderItems: number;
    payments: number;
    customers: number;
    profiles: number;
    logs: number;
  };
  backups: { lastSnapshot: string | null; count: number; frequency: string };
};

export type RepairResult = {
  success: boolean;
  issueId: string;
  recordsFixed: number;
};

export type ProductSalesRow = {
  id: string;
  name: string;
  category: DbProductCategory;
  units_sold: number;
  revenue: number;
  cost: number;
  profit: number;
  order_count: number;
};

/**
 * Columns the database maintains itself. Trigger-derived totals, generated
 * columns and timestamps are stripped from every Insert and Update type, so a
 * client that tries to write one fails at compile time instead of at runtime.
 */
type Derived =
  | "created_at"
  | "updated_at"
  | "total"
  | "cost"
  | "gross_profit"
  | "amount_paid"
  | "outstanding_balance"
  | "price"
  | "line_revenue"
  | "line_cost"
  | "line_profit"
  | "earned_commission_total"
  | "pending_commission_total"
  | "paid_commission_total";

type Writable<Row> = Omit<Row, Extract<keyof Row, Derived>>;

/** Every writable column optional except the ones the table genuinely requires. */
type Insertable<Row, RequiredKeys extends keyof Writable<Row>> = Pick<Writable<Row>, RequiredKeys> &
  Partial<Omit<Writable<Row>, RequiredKeys>>;

type Updatable<Row> = Partial<Writable<Row>>;

type Table<Row, Insert, Update = Updatable<Row>> = {
  Row: Row;
  Insert: Insert;
  Update: Update;
  Relationships: [];
};

type View<Row> = { Row: Row; Relationships: [] };

export type ProfileUpdate = Updatable<ProfileRow>;
export type CustomerUpdate = Updatable<CustomerRow>;
export type ProductUpdate = Updatable<ProductRow>;
export type OrderUpdate = Updatable<OrderRow>;
export type SettingsUpdate = Updatable<SettingsRow>;

export type Database = {
  public: {
    Tables: {
      profiles: Table<ProfileRow, Insertable<ProfileRow, "id" | "name" | "email">>;
      permissions: Table<PermissionRow, Insertable<PermissionRow, "code" | "label">>;
      user_permissions: Table<
        UserPermissionRow,
        Insertable<UserPermissionRow, "user_id" | "permission_code">
      >;
      customers: Table<CustomerRow, Insertable<CustomerRow, "id" | "name">>;
      products: Table<ProductRow, Insertable<ProductRow, "id" | "name">>;
      stock_movements: Table<
        StockMovementRow,
        Insertable<StockMovementRow, "id" | "product_id" | "type" | "quantity_change">
      >;
      orders: Table<OrderRow, Insertable<OrderRow, "id">>;
      order_items: Table<OrderItemRow, Insertable<OrderItemRow, "id" | "order_id" | "quantity">>;
      payments: Table<PaymentRow, Insertable<PaymentRow, "id" | "order_id" | "amount">>;
      order_requests: Table<
        OrderRequestRow,
        Insertable<OrderRequestRow, "customer_name" | "phone">
      >;
      commissions: Table<CommissionRow, Insertable<CommissionRow, "order_id" | "user_id">>;
      commission_payouts: Table<
        CommissionPayoutRow,
        Insertable<CommissionPayoutRow, "user_id" | "amount">
      >;
      system_logs: Table<SystemLogRow, Insertable<SystemLogRow, "id" | "message">>;
      system_issues: Table<SystemIssueRow, Insertable<SystemIssueRow, "id" | "title">>;
      notifications: Table<NotificationRow, Insertable<NotificationRow, "id" | "title">>;
      settings: Table<SettingsRow, Insertable<SettingsRow, never>>;
      backups: Table<BackupRow, Insertable<BackupRow, never>>;
      testimonials: Table<TestimonialRow, Insertable<TestimonialRow, "id" | "name" | "content">>;
    };
    Views: {
      public_products: View<PublicProductRow>;
      order_details: View<OrderDetailsRow>;
      inventory_status: View<InventoryStatusRow>;
      customer_financials: View<CustomerFinancialsRow>;
      officer_commission_summary: View<OfficerCommissionSummaryRow>;
      financial_summary: View<FinancialSummaryRow>;
      daily_sales: View<DailySalesRow>;
      product_sales: View<ProductSalesRow>;
    };
    Functions: {
      create_order: { Args: { payload: Json }; Returns: string };
      record_payment: {
        Args: {
          p_order_id: string;
          p_amount: number;
          p_method?: string;
          p_date?: string;
          p_reference?: string;
          p_notes?: string;
        };
        Returns: string;
      };
      update_order_status: {
        Args: { p_order_id: string; p_status: DbOrderStatus; p_reason?: string };
        Returns: undefined;
      };
      adjust_stock: {
        Args: {
          p_product_id: string;
          p_quantity_change: number;
          p_reason: string;
          p_type?: DbStockMovementType;
        };
        Returns: string;
      };
      pay_commissions: {
        Args: {
          p_user_id: string;
          p_commission_ids: string[];
          p_method?: string;
          p_reference?: string;
          p_notes?: string;
        };
        Returns: string;
      };
      set_user_permissions: { Args: { p_user_id: string; p_codes: string[] }; Returns: undefined };
      grant_role_preset: { Args: { p_user_id: string; p_role: DbUserRole }; Returns: undefined };
      convert_order_request: { Args: { p_request_id: string; p_customer_id: string }; Returns: string };
      run_diagnostics: { Args: Record<string, never>; Returns: number };
      repair_issue: { Args: { p_issue_id: string }; Returns: Json };
      operational_metrics: { Args: Record<string, never>; Returns: Json };
      current_profile_id: { Args: Record<string, never>; Returns: string | null };
      has_permission: { Args: { perm: string }; Returns: boolean };
      is_super_admin: { Args: Record<string, never>; Returns: boolean };
    };
    Enums: {
      user_role: DbUserRole;
      user_status: DbUserStatus;
      customer_status: DbCustomerStatus;
      product_category: DbProductCategory;
      order_status: DbOrderStatus;
      order_type: DbOrderType;
      payment_status: DbPaymentStatus;
      stock_movement_type: DbStockMovementType;
      log_severity: DbLogSeverity;
      log_category: DbLogCategory;
      commission_status: DbCommissionStatus;
      notification_type: DbNotificationType;
      order_request_status: DbOrderRequestStatus;
    };
    CompositeTypes: Record<string, never>;
  };
};
