import { AdminUser, AdminProfile, Customer, Order, Product, Notification, AdminSettings, SystemLog, LogSeverity, LogCategory, SystemIssue, Permission, UserRole, OFFICIAL_PERMISSIONS, OrderStatus, PaymentStatus, ORDER_STATUS_TRANSITIONS, StockMovement, PaymentRecord } from "./types";
import { storageCore } from "./storage/core";
import { EFZ_KEYS, PRODUCTS_KEY, ORDERS_KEY, SETTINGS_KEY, NOTIFICATIONS_KEY, SESSION_KEY, LOGS_KEY, USERS_KEY, CUSTOMERS_KEY, INITIALIZED_KEY, AUTO_BACKUP_KEY, LAST_EXPORT_KEY, LAST_SAVE_KEY, STOCK_MOVEMENTS_KEY } from "./storage/keys";
import { authService } from "./services/auth.service";
import { userService } from "./services/user.service";
import { customerService } from "./services/customer.service";
import { productService } from "./services/product.service";
import { orderService } from "./services/order.service";
import { settingsService } from "./services/settings.service";
import { backupService } from "./services/backup.service";
import { loggerService } from "./diagnostics/logger";
import { diagnosticsService } from "./diagnostics/diagnostics.service";
import { MOCK_PRODUCTS } from "./data";

export {
  PRODUCTS_KEY, ORDERS_KEY, SETTINGS_KEY, NOTIFICATIONS_KEY, SESSION_KEY, LOGS_KEY, USERS_KEY, CUSTOMERS_KEY, INITIALIZED_KEY, AUTO_BACKUP_KEY, LAST_EXPORT_KEY, LAST_SAVE_KEY, STOCK_MOVEMENTS_KEY, EFZ_KEYS,
  MOCK_PRODUCTS,
  OFFICIAL_PERMISSIONS,
  ORDER_STATUS_TRANSITIONS
};

export type {
  AdminUser, AdminProfile, Customer, Order, Product, Notification, AdminSettings, SystemLog, LogSeverity, LogCategory, SystemIssue, Permission, UserRole, OrderStatus, PaymentStatus, StockMovement
};

export const storage = {
  // Initialization
  isInitialized: (): boolean => {
    return storageCore.get(INITIALIZED_KEY) === "true";
  },
  setInitialized: () => {
    storageCore.set(INITIALIZED_KEY, "true");
    storage.updateLastSaveTime();
  },
  updateLastSaveTime: () => {
    storageCore.set(LAST_SAVE_KEY, new Date().toISOString());
  },
  getLastSaveTime: (): string | null => {
    return storageCore.get(LAST_SAVE_KEY);
  },
  getStorageUsage: () => {
    return storageCore.getUsage(EFZ_KEYS);
  },
  generateId: (prefix: string = "id"): string => {
    try {
      if (typeof window !== "undefined" && window.crypto && window.crypto.randomUUID) {
        return `${prefix}-${window.crypto.randomUUID()}`;
      }
    } catch (e) {}
    return `${prefix}-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
  },

  // Auth & Profile
  getProfile: authService.getProfile,
  saveProfile: authService.saveProfile,
  login: authService.login,
  logout: authService.logout,
  isLoggedIn: authService.isLoggedIn,

  // Users
  getUsers: userService.getUsers,
  saveUsers: (users: AdminUser[]) => {
    userService.saveUsers(users);
    storage.createAutoBackup();
    storage.updateLastSaveTime();
  },
  repairUserIds: userService.repairUserIds,
  hasPermission: (profile: AdminProfile | null | undefined, permission: Permission): boolean => {
    if (!profile) return false;
    if (profile.role === 'Super Admin') return true;
    return profile.permissions?.includes(permission) || false;
  },
  hasAnyPermission: (profile: AdminProfile | null | undefined, permissions: Permission[]): boolean => {
    return permissions.some(permission => storage.hasPermission(profile, permission));
  },
  canAccessCustomerModule: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasAnyPermission(profile, ['view_customers', 'view_own_customers_only']);
  },
  canAccessOrdersModule: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasAnyPermission(profile, ['view_orders', 'create_orders']);
  },
  canViewInventory: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'view_inventory');
  },
  canCreateOrders: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'create_orders');
  },
  canEditOrders: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'edit_orders');
  },
  canDeleteOrders: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'delete_orders');
  },
  canOverrideOrderStatus: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'override_order_status');
  },
  canViewAllCustomers: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'view_all_customers');
  },
  canViewOwnCustomersOnly: (profile: AdminProfile | null | undefined): boolean => {
    return !storage.canViewAllCustomers(profile) && storage.hasPermission(profile, 'view_own_customers_only');
  },
  canViewCustomers: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'view_customers');
  },
  canAddCustomers: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'add_customers');
  },
  canEditCustomers: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'edit_customers');
  },
  canDeleteCustomers: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'delete_customers');
  },
  canViewProducts: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'view_products');
  },
  canAddProducts: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'add_products');
  },
  canEditProducts: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'edit_products');
  },
  canDeleteProducts: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'delete_products');
  },
  canAdjustStock: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'adjust_stock');
  },
  canManageUsers: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'manage_users');
  },
  canChangeSettings: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'change_settings');
  },
  canViewReports: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'view_reports');
  },
  canViewCommissions: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'view_commissions');
  },
  canMarkCommissionsPaid: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'mark_commissions_paid');
  },
  canViewDiagnostics: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'view_diagnostics');
  },
  canViewAuditTrail: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'view_audit_trail');
  },
  canManageSystem: (profile: AdminProfile | null | undefined): boolean => {
    return storage.hasPermission(profile, 'manage_system');
  },

  // Customers
  getCustomers: customerService.getCustomers,
  saveCustomers: (customers: Customer[]) => {
    customerService.saveCustomers(customers);
    storage.createAutoBackup();
    storage.updateLastSaveTime();
  },

  // Products
  getProducts: productService.getProducts,
  saveProducts: (products: Product[]) => {
    productService.saveProducts(products);
    storage.createAutoBackup();
    storage.updateLastSaveTime();
  },

  // Orders
  getOrders: orderService.getOrders,
  saveOrders: (orders: Order[]) => {
    orderService.saveOrders(orders);
    storage.createAutoBackup();
    storage.updateLastSaveTime();
  },
  addPaymentToOrder: (order: Order, payment: Omit<PaymentRecord, 'id' | 'orderId' | 'createdAt'> & { amount: number, recordedBy?: string, createdAt?: string }) => {
    const payments = Array.isArray(order.payments) ? [...order.payments] : [];
    const amount = Number(payment.amount || 0);
    const total = Number(order.total || 0);
    const currentCollected = payments.reduce((sum, entry) => sum + Number(entry.amount || 0), 0);
    const outstanding = Math.max(0, total - currentCollected);

    if (!Number.isFinite(amount) || amount <= 0 || amount > outstanding) {
      throw new Error('Invalid payment amount');
    }

    const record: PaymentRecord = {
      id: `pay-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      orderId: order.id,
      amount,
      paymentDate: payment.paymentDate || new Date().toISOString().slice(0, 10),
      paymentMethod: payment.paymentMethod || 'Cash',
      notes: payment.notes || payment.note || '',
      note: payment.note || payment.notes || '',
      reference: payment.reference || '',
      recordedBy: payment.recordedBy || 'System',
      createdAt: payment.createdAt || new Date().toISOString(),
    };

    const nextPayments = [...payments, record];
    const nextCollected = nextPayments.reduce((sum, entry) => sum + Number(entry.amount || 0), 0);
    const updatedOrder: Order = {
      ...order,
      payments: nextPayments,
      amountPaid: Math.min(nextCollected, total),
      outstandingBalance: Math.max(0, total - nextCollected),
      paymentStatus: nextCollected <= 0 ? 'unpaid' : nextCollected >= total ? 'paid' : 'partial',
    };

    const orders = storage.getOrders().map(item => item.id === order.id ? updatedOrder : item);
    storage.saveOrders(orders);
    return updatedOrder;
  },

  // Settings & Notifications
  getSettings: settingsService.getSettings,
  saveSettings: settingsService.saveSettings,
  getTheme: settingsService.getTheme,
  setTheme: settingsService.setTheme,
  getNotifications: settingsService.getNotifications,
  saveNotifications: (notifications: Notification[]) => {
    settingsService.saveNotifications(notifications);
    storage.createAutoBackup();
    storage.updateLastSaveTime();
  },

  // Backups
  exportBackup: backupService.exportBackup,
  importBackup: backupService.importBackup,
  activateApprovedHistoricalMigration: backupService.activateApprovedHistoricalMigration,
  validateBackup: backupService.validateBackup,
  createAutoBackup: backupService.createAutoBackup,
  restoreAutoBackup: backupService.restoreAutoBackup,
  getLastExportDate: backupService.getLastExportDate,
  updateLastExportDate: backupService.updateLastExportDate,

  // Diagnostics & Logs
  logger: loggerService,
  repairStorage: diagnosticsService.repairStorage,
  validateDataIntegrity: diagnosticsService.validateDataIntegrity,
  getSystemIssues: diagnosticsService.getSystemIssues,
  getOperationalMetrics: diagnosticsService.getOperationalMetrics,
  executeRepairAction: diagnosticsService.executeRepairAction,

  // Stock Movements
  getStockMovements: (): StockMovement[] => {
    const stored = storageCore.get(STOCK_MOVEMENTS_KEY);
    if (!stored) return [];
    try { return JSON.parse(stored); } catch { return []; }
  },
  addStockMovement: (movement: Omit<StockMovement, 'id' | 'timestamp'>) => {
    const movements = storage.getStockMovements();
    const newMovement: StockMovement = {
      ...movement,
      id: `mv-${Date.now()}-${Math.random().toString(36).substring(2, 6)}`,
      timestamp: new Date().toISOString()
    };
    const updated = [newMovement, ...movements].slice(0, 500);
    storageCore.set(STOCK_MOVEMENTS_KEY, JSON.stringify(updated));
    return newMovement;
  },
  
  // Previously missed
  getRecentActivity: () => loggerService.getLogs().slice(0, 10),
  getDataCounts: () => ({
    products: productService.getProducts().length,
    orders: orderService.getOrders().length,
    customers: customerService.getCustomers().length,
    users: userService.getUsers().length,
  }),
  resetDemoData: () => {
    storageCore.clear();
    storage.setInitialized();
  },
  checkStorageHealth: storageCore.checkHealth
};
