import { storageCore } from "../storage/core";
import { EFZ_KEYS, LAST_EXPORT_KEY, AUTO_BACKUP_KEY } from "../storage/keys";
import { loggerService } from "../diagnostics/logger";
import { validateProduct, validateCustomer, validateOrder, validateUser } from "../validators";
import approvedHistoricalBackup from "../../Backup/efz_approved_historical_parent_orders_2026-09-01.json";

const APPROVED_MIGRATION_KEY = 'efz_approved_historical_migration_v1';

const safeParse = (val: string | null) => {
  if (!val) return null;
  try {
    return JSON.parse(val);
  } catch (e) {
    return val;
  }
};

export const loadApprovedHistoricalDataIfNeeded = () => {
  if (typeof window === "undefined") return false;

  const migrationFlag = storageCore.get(APPROVED_MIGRATION_KEY) === 'true';
  const hasStoredData = EFZ_KEYS.some((key) => !!storageCore.get(key));

  if (migrationFlag && hasStoredData) return false;

  const result = backupService.activateApprovedHistoricalMigration();
  return result;
};

export const backupService = {
  exportBackup: () => {
    const backup: Record<string, any> = {};
    EFZ_KEYS.forEach(key => {
      const val = storageCore.get(key);
      if (val) backup[key] = safeParse(val);
    });
    
    backupService.updateLastExportDate();
    loggerService.log('SYSTEM', 'INFO', 'System snapshot exported successfully');
    
    return JSON.stringify({
      version: "1.0",
      timestamp: new Date().toISOString(),
      data: backup
    }, null, 2);
  },

  validateBackup: (jsonData: string): { ok: boolean; errors: string[]; warnings: string[] } => {
    const errors: string[] = [];
    const warnings: string[] = [];
    
    try {
      const parsed = JSON.parse(jsonData);
      if (!parsed || typeof parsed !== 'object') {
        return { ok: false, errors: ["Backup is not a valid JSON object."], warnings };
      }
      if (!parsed.data || typeof parsed.data !== 'object') {
        return { ok: false, errors: ["Backup data container ('data' key) is missing or invalid."], warnings };
      }

      const data = parsed.data;

      // Validate Products
      if (data.efz_mock_products) {
        let productsArray: any[] = [];
        try {
          productsArray = typeof data.efz_mock_products === 'string' ? JSON.parse(data.efz_mock_products) : data.efz_mock_products;
        } catch(e) {
          errors.push("Products data is corrupted (invalid JSON).");
        }

        if (Array.isArray(productsArray)) {
          const productIds = new Set<string>();
          productsArray.forEach((p: any, idx: number) => {
            if (p.id) {
              if (productIds.has(p.id)) {
                errors.push(`Duplicate Product ID detected in backup: ${p.id}`);
              }
              productIds.add(p.id);
            }
            const res = validateProduct(p);
            if (!res.ok) {
              errors.push(`Product #${idx + 1} (${p.name || 'unnamed'}): ${res.error}`);
            }
            if (res.warning) {
              warnings.push(`Product #${idx + 1} (${p.name || 'unnamed'}): ${res.warning}`);
            }
          });
        } else {
          errors.push("Products must be represented as a JSON array.");
        }
      }

      // Validate Users
      if (data.efz_mock_users) {
        let usersArray: any[] = [];
        try {
          usersArray = typeof data.efz_mock_users === 'string' ? JSON.parse(data.efz_mock_users) : data.efz_mock_users;
        } catch(e) {
          errors.push("Users data is corrupted (invalid JSON).");
        }

        if (Array.isArray(usersArray)) {
          const userIds = new Set<string>();
          usersArray.forEach((u: any, idx: number) => {
            if (u.id) {
              if (userIds.has(u.id)) {
                errors.push(`Duplicate User ID detected in backup: ${u.id}`);
              }
              userIds.add(u.id);
            }
            const res = validateUser(u);
            if (!res.ok) {
              errors.push(`User #${idx + 1} (${u.name || 'unnamed'}): ${res.error}`);
            }
          });
        } else {
          errors.push("Users must be represented as a JSON array.");
        }
      }

      // Validate Customers
      if (data.efz_mock_customers) {
        let customersArray: any[] = [];
        try {
          customersArray = typeof data.efz_mock_customers === 'string' ? JSON.parse(data.efz_mock_customers) : data.efz_mock_customers;
        } catch(e) {
          errors.push("Customers data is corrupted (invalid JSON).");
        }

        if (Array.isArray(customersArray)) {
          const customerIds = new Set<string>();
          customersArray.forEach((c: any, idx: number) => {
            if (c.id) {
              if (customerIds.has(c.id)) {
                errors.push(`Duplicate Customer ID detected in backup: ${c.id}`);
              }
              customerIds.add(c.id);
            }
            const res = validateCustomer(c);
            if (!res.ok) {
              errors.push(`Customer #${idx + 1} (${c.name || 'unnamed'}): ${res.error}`);
            }
          });
        } else {
          errors.push("Customers must be represented as a JSON array.");
        }
      }

      // Validate Orders
      if (data.efz_mock_orders) {
        let ordersArray: any[] = [];
        try {
          ordersArray = typeof data.efz_mock_orders === 'string' ? JSON.parse(data.efz_mock_orders) : data.efz_mock_orders;
        } catch(e) {
          errors.push("Orders data is corrupted (invalid JSON).");
        }

        if (Array.isArray(ordersArray)) {
          const orderIds = new Set<string>();
          ordersArray.forEach((o: any, idx: number) => {
            if (o.id) {
              if (orderIds.has(o.id)) {
                errors.push(`Duplicate Order ID detected in backup: ${o.id}`);
              }
              orderIds.add(o.id);
            }
            const res = validateOrder(o);
            if (!res.ok) {
              errors.push(`Order #${idx + 1} (${o.id || 'unnamed'}): ${res.error}`);
            }
          });
        } else {
          errors.push("Orders must be represented as a JSON array.");
        }
      }

      return {
        ok: errors.length === 0,
        errors,
        warnings
      };
    } catch(e: any) {
      return {
        ok: false,
        errors: ["Parsing failed: " + e.message],
        warnings
      };
    }
  },

  importBackup: (jsonData: string) => {
    try {
      const parsed = JSON.parse(jsonData);
      if (!parsed.data) throw new Error("Invalid backup format");
      
      Object.entries(parsed.data).forEach(([key, value]) => {
        if (EFZ_KEYS.includes(key)) {
          storageCore.set(key, typeof value === 'string' ? value : JSON.stringify(value));
        }
      });
      
      loggerService.log('SYSTEM', 'WARNING', 'System snapshot restored from external file');
      return { ok: true };
    } catch (e: any) {
      loggerService.log('SYSTEM', 'ERROR', `Failed to restore snapshot: ${e.message}`);
      return { ok: false, error: e.message };
    }
  },

  activateApprovedHistoricalMigration: () => {
    if (typeof window === "undefined") return false;

    const hasMigrationFlag = storageCore.get(APPROVED_MIGRATION_KEY) === 'true';
    const hasStoredData = EFZ_KEYS.some((key) => !!storageCore.get(key));

    if (hasMigrationFlag && hasStoredData) return false;

    const orders = approvedHistoricalBackup.data.efz_mock_orders as any[];
    const customers = approvedHistoricalBackup.data.efz_mock_customers as any[];
    const units = orders.reduce((sum, order) => sum + order.items.reduce((itemSum: number, item: any) => itemSum + Number(item.quantity || 0), 0), 0);
    const revenue = orders.reduce((sum, order) => sum + Number(order.total || 0), 0);
    const cost = orders.reduce((sum, order) => sum + Number(order.cost || 0), 0);
    const profit = orders.reduce((sum, order) => sum + Number(order.grossProfit || 0), 0);

    if (orders.length !== 7 || customers.length !== 5 || units !== 11 || revenue !== 119 || cost !== 73.7 || profit !== 45.3) {
      throw new Error('Approved historical migration payload failed reconciliation.');
    }

    if (!hasMigrationFlag) {
      backupService.createAutoBackup();
    }

    const result = backupService.importBackup(JSON.stringify(approvedHistoricalBackup));
    if (!result.ok) throw new Error(result.error || 'Approved historical migration failed.');

    storageCore.set(APPROVED_MIGRATION_KEY, 'true');
    storageCore.set('efz_initialized', 'true');
    storageCore.set('efz_last_save_time', new Date().toISOString());
    return true;
  },

  createAutoBackup: () => {
    try {
      const backup: Record<string, any> = {};
      EFZ_KEYS.forEach(key => {
        if (key !== AUTO_BACKUP_KEY) {
          const val = storageCore.get(key);
          if (val) backup[key] = safeParse(val);
        }
      });
      storageCore.set(AUTO_BACKUP_KEY, JSON.stringify({
        timestamp: new Date().toISOString(),
        data: backup
      }));
    } catch (e) {
      loggerService.log('STORAGE', 'ERROR', 'Auto-backup creation failed due to quota/memory limits');
    }
  },

  restoreAutoBackup: () => {
    try {
      const stored = storageCore.get(AUTO_BACKUP_KEY);
      if (!stored) return false;
      
      const backup = JSON.parse(stored);
      if (!backup.data) return false;

      Object.entries(backup.data).forEach(([key, value]) => {
        if (EFZ_KEYS.includes(key) && key !== AUTO_BACKUP_KEY) {
          storageCore.set(key, typeof value === 'string' ? value : JSON.stringify(value));
        }
      });
      loggerService.log('SYSTEM', 'WARNING', 'System snapshot restored from auto-backup');
      return true;
    } catch (e) {
      return false;
    }
  },

  getLastExportDate: (): string | null => {
    return storageCore.get(LAST_EXPORT_KEY);
  },

  updateLastExportDate: () => {
    storageCore.set(LAST_EXPORT_KEY, new Date().toISOString());
  }
};
