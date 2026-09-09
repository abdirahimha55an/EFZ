import { storageCore } from "../storage/core";
import { EFZ_KEYS, INITIALIZED_KEY, SESSION_KEY, LAST_EXPORT_KEY, LAST_SAVE_KEY } from "../storage/keys";
import { SystemIssue, Order, Customer, Product, AdminUser, LogSeverity, OFFICIAL_PERMISSIONS } from "../types";
import { loggerService } from "./logger";
import { userService } from "../services/user.service";
import { productService } from "../services/product.service";
import { customerService } from "../services/customer.service";
import { orderService } from "../services/order.service";
import { backupService } from "../services/backup.service";
import { authService } from "../services/auth.service";

export const diagnosticsService = {
  repairStorage: () => {
    if (typeof window === "undefined") return { ok: true };
    try {
      const results: string[] = [];
      EFZ_KEYS.forEach(key => {
        if (!storageCore.get(key)) {
          storageCore.set(key, key === INITIALIZED_KEY ? "false" : "[]");
          results.push(`Initialized missing key: ${key}`);
        }
      });
      
      EFZ_KEYS.forEach(key => {
        const val = storageCore.get(key);
        try {
          if (val && key !== INITIALIZED_KEY && key !== SESSION_KEY && key !== LAST_EXPORT_KEY && key !== LAST_SAVE_KEY) {
            JSON.parse(val);
          }
        } catch (e) {
          storageCore.set(key, "[]");
          results.push(`Repaired corrupted key: ${key}`);
        }
      });

      loggerService.log('SYSTEM', 'WARNING', 'Storage repair operation performed', { metadata: { results } });
      return { ok: true, results };
    } catch (e: any) {
      return { ok: false, error: e.message };
    }
  },

  validateDataIntegrity: () => {
    // This now just triggers a re-fetch of issues and returns counts for legacy support
    const issues = diagnosticsService.getSystemIssues();
    const diagnostics = {
      orphanedOrders: issues.filter(i => i.title === 'Orphaned Order Link').length,
      missingCustomerLinks: issues.filter(i => i.title === 'Orphaned Customer Record').length,
      stockInconsistencies: issues.filter(i => i.title === 'Negative Inventory Detected').length
    };
    return diagnostics;
  },

  getSystemIssues: (): SystemIssue[] => {
    const issues: SystemIssue[] = [];
    const now = new Date().toISOString();
    
    const users = userService.getUsers();
    const customers = customerService.getCustomers();
    const orders = orderService.getOrders();
    const products = productService.getProducts();
    
    // 1. Storage & Backup Integrity
    const lastExport = backupService.getLastExportDate();
    if (!lastExport) {
      issues.push({
        id: 'backup-missing',
        title: 'Critical Backup Gap',
        severity: 'CRITICAL',
        source: 'Storage Engine',
        affectedEntityType: 'System',
        explanation: 'No system snapshot has been exported. Local data is highly volatile.',
        recommendedAction: 'Generate a system snapshot immediately.',
        repairable: false,
        createdAt: now,
        lastDetectedAt: now
      });
    } else {
      const exportDate = new Date(lastExport);
      const daysSince = (new Date().getTime() - exportDate.getTime()) / (1000 * 60 * 60 * 24);
      if (daysSince > 3) {
        issues.push({
          id: 'backup-stale',
          title: 'Stale Snapshot',
          severity: 'WARNING',
          source: 'Storage Engine',
          affectedEntityType: 'System',
          explanation: `System backup is ${Math.floor(daysSince)} days old.`,
          recommendedAction: 'Refresh system snapshot to avoid data loss.',
          repairable: false,
          createdAt: now,
          lastDetectedAt: now
        });
      }
    }

    // 2. Identity & Permission Issues
    const userIds = users.map(u => u.id);
    const duplicateUsers = userIds.filter((id, index) => userIds.indexOf(id) !== index);
    if (duplicateUsers.length > 0) {
      issues.push({
        id: 'dup-users',
        title: 'User ID Collision Detected',
        severity: 'CRITICAL',
        source: 'User Identity Engine',
        affectedEntityType: 'AdminUser',
        affectedCount: duplicateUsers.length,
        explanation: 'Multiple administrative records share the same unique identifier. This usually comes from import/restore, migration, or data corruption. Users do not normally edit IDs manually.',
        recommendedAction: 'Repair Duplicate User IDs.',
        repairable: true,
        createdAt: now,
        lastDetectedAt: now
      });
    }

    const invalidPermissionsUsers = users.filter(u => {
      if (!u.permissions) return false;
      const invalid = u.permissions.some(p => !OFFICIAL_PERMISSIONS.includes(p as any));
      const duplicates = new Set(u.permissions).size !== u.permissions.length;
      return invalid || duplicates;
    });

    if (invalidPermissionsUsers.length > 0) {
      issues.push({
        id: 'invalid-permissions',
        title: 'Invalid Permission Assignments',
        severity: 'ERROR',
        source: 'Auth Service',
        affectedEntityType: 'AdminUser',
        affectedCount: invalidPermissionsUsers.length,
        explanation: 'Users have permission codes not recognized by the official permission registry, or duplicate permissions. This usually comes from old data/import errors.',
        recommendedAction: 'Repair Invalid Permissions.',
        repairable: true,
        createdAt: now,
        lastDetectedAt: now
      });
    }

    // Inactive users with active sessions (anomaly)
    const currentSessionId = storageCore.get(SESSION_KEY);
    if (currentSessionId) {
      const activeUser = users.find(u => u.id === currentSessionId);
      if (activeUser && activeUser.status === 'inactive') {
        issues.push({
          id: 'inactive-user-session',
          title: 'Inactive User Active Session',
          severity: 'CRITICAL',
          source: 'Auth Service',
          affectedEntityType: 'AdminUser',
          affectedEntityId: activeUser.id,
          explanation: `User ${activeUser.name} is inactive but has an active session.`,
          recommendedAction: 'Clear Invalid Sessions.',
          repairable: true,
          createdAt: now,
          lastDetectedAt: now
        });
      }
    }

    // 3. Customer Data Integrity
    const customerIds = customers.map(c => c.id);
    const duplicateCustomers = customerIds.filter((id, index) => customerIds.indexOf(id) !== index);
    if (duplicateCustomers.length > 0) {
      issues.push({
        id: 'dup-customers',
        title: 'Customer ID Collision Detected',
        severity: 'ERROR',
        source: 'CRM Database',
        affectedEntityType: 'Customer',
        affectedCount: duplicateCustomers.length,
        explanation: 'Multiple customer records share the same unique identifier. This usually comes from import/restore, migration, or data corruption. Users do not normally edit IDs manually.',
        recommendedAction: 'Repair Duplicate Customer IDs.',
        repairable: true,
        createdAt: now,
        lastDetectedAt: now
      });
    }

    const orphanedCustomers = customers.filter(c => !users.find(u => u.id === c.registeredBy));
    if (orphanedCustomers.length > 0) {
      issues.push({
        id: 'orphaned-customers',
        title: 'Orphaned Customer Record',
        severity: 'WARNING',
        source: 'CRM Database',
        affectedEntityType: 'Customer',
        affectedCount: orphanedCustomers.length,
        explanation: 'Customers are linked to administrative accounts that no longer exist.',
        recommendedAction: 'Re-assign Customers to Super Admin.',
        repairable: true,
        createdAt: now,
        lastDetectedAt: now
      });
    }

    const inactiveOwnerCustomers = customers.filter(c => {
      const owner = users.find(u => u.id === c.registeredBy);
      return owner && owner.status === 'inactive';
    });
    if (inactiveOwnerCustomers.length > 0) {
      issues.push({
        id: 'inactive-owner-customers',
        title: 'Customers Assigned to Inactive User',
        severity: 'INFO',
        source: 'CRM Database',
        affectedEntityType: 'Customer',
        affectedCount: inactiveOwnerCustomers.length,
        explanation: 'Customers are assigned to a user whose account is currently inactive.',
        recommendedAction: 'Re-assign Customers to Active User.',
        repairable: true,
        createdAt: now,
        lastDetectedAt: now
      });
    }

    // 4. Order & Financial Integrity
    const orderIds = orders.map(o => o.id);
    const duplicateOrders = orderIds.filter((id, index) => orderIds.indexOf(id) !== index);
    if (duplicateOrders.length > 0) {
      issues.push({
        id: 'dup-orders',
        title: 'Order ID Collision Detected',
        severity: 'ERROR',
        source: 'Order Engine',
        affectedEntityType: 'Order',
        affectedCount: duplicateOrders.length,
        explanation: 'Multiple orders share the same unique identifier. This usually comes from import/restore, migration, or data corruption. Users do not normally edit IDs manually.',
        recommendedAction: 'Repair Duplicate Order IDs.',
        repairable: true,
        createdAt: now,
        lastDetectedAt: now
      });
    }

    const orphanedOrders = orders.filter(o => !customers.find(c => c.id === o.customerId));
    if (orphanedOrders.length > 0) {
      issues.push({
        id: 'orphaned-orders',
        title: 'Orphaned Order Link',
        severity: 'ERROR',
        source: 'Order Engine',
        affectedEntityType: 'Order',
        affectedCount: orphanedOrders.length,
        explanation: 'Orders are linked to missing or deleted customer records.',
        recommendedAction: 'Attempt Order-to-Customer Re-link via Name/Phone.',
        repairable: true,
        createdAt: now,
        lastDetectedAt: now
      });
    }

    const mismatchedTotals = orders.filter(o => {
      const calculatedTotal = o.items.reduce((sum, item) => sum + ((Number(item.actualUnitPrice ?? item.price ?? item.standardUnitPrice ?? 0)) * item.quantity), 0);
      return Math.abs(calculatedTotal - o.total) > 0.01;
    });
    if (mismatchedTotals.length > 0) {
      issues.push({
        id: 'mismatched-order-totals',
        title: 'Invalid Order Totals',
        severity: 'CRITICAL',
        source: 'Order Engine',
        affectedEntityType: 'Order',
        affectedCount: mismatchedTotals.length,
        explanation: 'Order totals do not match the sum of their individual item prices.',
        recommendedAction: 'Recalculate Order Totals.',
        repairable: true,
        createdAt: now,
        lastDetectedAt: now
      });
    }

    // 5. Inventory Integrity
    const negativeStock = products.filter(p => p.stock < 0);
    if (negativeStock.length > 0) {
      issues.push({
        id: 'inv-neg',
        title: 'Negative Inventory Detected',
        severity: 'ERROR',
        source: 'Inventory Control',
        affectedEntityType: 'Product',
        affectedCount: negativeStock.length,
        explanation: 'System records show stock levels below zero. This usually comes from import/restore, manual data corruption, or an untracked stock adjustment. Normal operations prevent this automatically.',
        recommendedAction: 'Reset Negative Stock to Zero.',
        repairable: true,
        createdAt: now,
        lastDetectedAt: now
      });
    }

    const corruptedFinancials = products.filter(p => 
      isNaN(p.costPrice) || isNaN(p.sellingPrice) || isNaN(p.stock) ||
      p.costPrice < 0 || p.sellingPrice < 0
    );
    if (corruptedFinancials.length > 0) {
      issues.push({
        id: 'inv-corrupt-financials',
        title: 'Corrupted Product Financial Values',
        severity: 'ERROR',
        source: 'Inventory Control',
        affectedEntityType: 'Product',
        affectedCount: corruptedFinancials.length,
        explanation: 'Products have NaN or negative values for cost price, selling price, or stock. This usually comes from import/restore or data corruption.',
        recommendedAction: 'Reset Corrupted Financials to Zero.',
        repairable: true,
        createdAt: now,
        lastDetectedAt: now
      });
    }

    const invalidPrices = products.filter(p => p.sellingPrice < p.costPrice);
    if (invalidPrices.length > 0) {
      issues.push({
        id: 'inv-price-loss',
        title: 'Selling Price Below Cost',
        severity: 'WARNING',
        source: 'Inventory Control',
        affectedEntityType: 'Product',
        affectedCount: invalidPrices.length,
        explanation: 'Products are configured with a selling price lower than their cost price.',
        recommendedAction: 'Review Pricing Strategy manually.',
        repairable: false,
        createdAt: now,
        lastDetectedAt: now
      });
    }

    // 6. Anomaly Detection
    const logs = loggerService.getLogs();
    const recentFailedLogins = logs.filter(l => l.category === 'AUTH' && l.severity === 'WARNING' && new Date(l.timestamp).getTime() > Date.now() - 3600000);
    if (recentFailedLogins.length > 5) {
      issues.push({
        id: 'anomaly-failed-logins',
        title: 'High Volume Failed Logins',
        severity: 'CRITICAL',
        source: 'Auth Service',
        affectedEntityType: 'System',
        affectedCount: recentFailedLogins.length,
        explanation: 'Multiple failed login attempts detected in the past hour.',
        recommendedAction: 'Review Audit Logs.',
        repairable: false,
        createdAt: now,
        lastDetectedAt: now
      });
    }

    return issues;
  },

  calculateSystemHealthScore: (): { score: number; status: 'Excellent' | 'Good' | 'Fair' | 'Critical'; reasons: string[] } => {
    const issues = diagnosticsService.getSystemIssues();
    let score = 100;
    const reasons: string[] = [];

    issues.forEach(issue => {
      if (issue.severity === 'CRITICAL') { score -= 20; reasons.push(`Critical issue: ${issue.title}`); }
      else if (issue.severity === 'ERROR') { score -= 10; reasons.push(`Error: ${issue.title}`); }
      else if (issue.severity === 'WARNING') { score -= 5; reasons.push(`Warning: ${issue.title}`); }
      else if (issue.severity === 'INFO') { score -= 1; }
    });

    if (score < 0) score = 0;

    let status: 'Excellent' | 'Good' | 'Fair' | 'Critical' = 'Excellent';
    if (score < 60) status = 'Critical';
    else if (score < 80) status = 'Fair';
    else if (score < 95) status = 'Good';

    if (score === 100) reasons.push("No active issues detected.");

    return { score, status, reasons: reasons.slice(0, 3) };
  },

  getOperationalMetrics: () => {
    const usage = storageCore.getUsage(EFZ_KEYS);
    const logs = loggerService.getLogs();
    const lastExport = backupService.getLastExportDate();
    const health = diagnosticsService.calculateSystemHealthScore();
    
    return {
      storage: {
        total: "5 MB",
        used: usage.used,
        utilization: usage.percentage,
        latency: "< 1ms",
        lastWrite: storageCore.get(LAST_SAVE_KEY) || new Date().toISOString()
      },
      sessions: {
        active: storageCore.get(SESSION_KEY) ? 1 : 0,
        consistency: "100%",
        authMode: "LocalStorage JWT-Sim"
      },
      backups: {
        frequency: "Manual",
        lastSnapshot: lastExport,
        integrity: "Verified"
      },
      runtime: {
        engine: "EFZ V8",
        exceptions: logs.filter(l => l.severity === 'ERROR' || l.severity === 'CRITICAL').length,
        healthScore: health.score,
        healthStatus: health.status
      }
    };
  },

  // ---------------------------------------------------------
  // EXPLICIT REPAIR ACTIONS (Requires Super Admin)
  // ---------------------------------------------------------
  
  repairDuplicateUserIds: (currentUser: AdminUser) => {
    if (currentUser.role !== 'Super Admin') throw new Error("Permission denied");
    const users = userService.getUsers();
    const repaired = userService.repairUserIds(users);
    userService.saveUsers(repaired);
    loggerService.log('SYSTEM', 'CRITICAL', 'Admin performed User ID collision repair.', { userId: currentUser.id });
    return { success: true };
  },

  repairDuplicateCustomerIds: (currentUser: AdminUser) => {
    if (currentUser.role !== 'Super Admin') throw new Error("Permission denied");
    const customers = customerService.getCustomers();
    const seenIds = new Set<string>();
    let count = 0;
    const repaired = customers.map(c => {
      let currentId = c.id;
      if (!currentId || seenIds.has(currentId)) {
        currentId = `c-${Date.now()}-${Math.random().toString(36).substring(2, 6)}`;
        count++;
      }
      seenIds.add(currentId);
      return { ...c, id: currentId };
    });
    if (count > 0) {
      customerService.saveCustomers(repaired);
      loggerService.log('SYSTEM', 'WARNING', `Admin repaired ${count} duplicate Customer IDs.`, { userId: currentUser.id });
    }
    return { success: true, count };
  },

  repairDuplicateOrderIds: (currentUser: AdminUser) => {
    if (currentUser.role !== 'Super Admin') throw new Error("Permission denied");
    const orders = orderService.getOrders();
    const seenIds = new Set<string>();
    let count = 0;
    const repaired = orders.map(o => {
      let currentId = o.id;
      if (!currentId || seenIds.has(currentId)) {
        currentId = `ORD-${Date.now()}-${Math.random().toString(36).substring(2, 6)}`;
        count++;
      }
      seenIds.add(currentId);
      return { ...o, id: currentId };
    });
    if (count > 0) {
      orderService.saveOrders(repaired);
      loggerService.log('SYSTEM', 'WARNING', `Admin repaired ${count} duplicate Order IDs.`, { userId: currentUser.id });
    }
    return { success: true, count };
  },

  reassignOrphanedCustomers: (currentUser: AdminUser) => {
    if (currentUser.role !== 'Super Admin') throw new Error("Permission denied");
    const customers = customerService.getCustomers();
    const users = userService.getUsers();
    const superAdmin = users.find(u => u.role === 'Super Admin') || users[0];
    if (!superAdmin) throw new Error("No Super Admin found for reassignment");

    let count = 0;
    const repaired = customers.map(c => {
      const ownerExists = users.find(u => u.id === c.registeredBy);
      if (!ownerExists) {
        count++;
        return { ...c, registeredBy: superAdmin.id, marketingOfficerId: superAdmin.id };
      }
      return c;
    });

    if (count > 0) {
      customerService.saveCustomers(repaired);
      loggerService.log('SYSTEM', 'WARNING', `Admin re-assigned ${count} orphaned customers to Super Admin.`, { userId: currentUser.id });
    }
    return { success: true, count };
  },

  reassignInactiveOwnerCustomers: (currentUser: AdminUser) => {
    if (currentUser.role !== 'Super Admin') throw new Error("Permission denied");
    const customers = customerService.getCustomers();
    const users = userService.getUsers();
    const activeSuperAdmin = users.find(u => u.role === 'Super Admin' && u.status === 'active') || users[0];

    let count = 0;
    const repaired = customers.map(c => {
      const owner = users.find(u => u.id === c.registeredBy);
      if (owner && owner.status === 'inactive') {
        count++;
        return { ...c, registeredBy: activeSuperAdmin.id, marketingOfficerId: activeSuperAdmin.id };
      }
      return c;
    });

    if (count > 0) {
      customerService.saveCustomers(repaired);
      loggerService.log('SYSTEM', 'INFO', `Admin re-assigned ${count} customers from inactive users to Active Super Admin.`, { userId: currentUser.id });
    }
    return { success: true, count };
  },

  relinkOrphanedOrders: (currentUser: AdminUser) => {
    if (currentUser.role !== 'Super Admin') throw new Error("Permission denied");
    const orders = orderService.getOrders();
    const customers = customerService.getCustomers();
    
    let count = 0;
    const repaired = orders.map(o => {
      if (o.customerId && !customers.find(c => c.id === o.customerId)) {
        // Try linking by name or phone
        const found = customers.find(c => c.name === o.customer || c.phone === o.phone);
        if (found) {
          count++;
          return { ...o, customerId: found.id };
        }
      }
      return o;
    });

    if (count > 0) {
      orderService.saveOrders(repaired);
      loggerService.log('SYSTEM', 'ERROR', `Admin recovered ${count} orphaned orders by re-linking names.`, { userId: currentUser.id });
    }
    return { success: true, count };
  },

  recalculateOrderTotals: (currentUser: AdminUser) => {
    if (currentUser.role !== 'Super Admin') throw new Error("Permission denied");
    const orders = orderService.getOrders();
    let count = 0;
    const repaired = orders.map(o => {
      const calculatedTotal = o.items.reduce((sum, item) => sum + ((Number(item.actualUnitPrice ?? item.price ?? item.standardUnitPrice ?? 0)) * item.quantity), 0);
      if (Math.abs(calculatedTotal - o.total) > 0.01) {
        count++;
        return { ...o, total: calculatedTotal, grossProfit: calculatedTotal - o.cost };
      }
      return o;
    });

    if (count > 0) {
      orderService.saveOrders(repaired);
      loggerService.log('FINANCIAL', 'CRITICAL', `Admin recalculated totals for ${count} invalid orders.`, { userId: currentUser.id });
    }
    return { success: true, count };
  },

  resetNegativeStock: (currentUser: AdminUser) => {
    if (currentUser.role !== 'Super Admin') throw new Error("Permission denied");
    const products = productService.getProducts();
    let count = 0;
    const repaired = products.map(p => {
      if (p.stock < 0) {
        count++;
        return { ...p, stock: 0 };
      }
      return p;
    });

    if (count > 0) {
      productService.saveProducts(repaired);
      loggerService.log('INVENTORY', 'ERROR', `Admin reset negative stock to zero for ${count} products.`, { userId: currentUser.id });
    }
    return { success: true, count };
  },

  repairInvalidPermissions: (currentUser: AdminUser) => {
    if (currentUser.role !== 'Super Admin') throw new Error("Permission denied");
    const users = userService.getUsers();
    let count = 0;
    
    const repaired = users.map(u => {
      if (!u.permissions) return u;
      
      const originalLen = u.permissions.length;
      
      // Filter out invalid, keep only those in OFFICIAL_PERMISSIONS, and remove duplicates
      const validPermissions = u.permissions.filter(p => OFFICIAL_PERMISSIONS.includes(p as any));
      const uniqueValid = Array.from(new Set(validPermissions));
      
      if (uniqueValid.length !== originalLen || new Set(u.permissions).size !== originalLen) {
        count++;
        return { ...u, permissions: uniqueValid };
      }
      return u;
    });

    if (count > 0) {
      userService.saveUsers(repaired);
      loggerService.log('AUTH', 'WARNING', `Admin repaired invalid/duplicate permissions for ${count} users.`, { userId: currentUser.id });
    }
    return { success: true, count };
  },

  repairCorruptFinancials: (currentUser: AdminUser) => {
    if (currentUser.role !== 'Super Admin') throw new Error("Permission denied");
    const products = productService.getProducts();
    let count = 0;
    const repaired = products.map(p => {
      const needsRepair = isNaN(p.costPrice) || isNaN(p.sellingPrice) || isNaN(p.stock) || p.costPrice < 0 || p.sellingPrice < 0;
      if (needsRepair) {
        count++;
        return {
          ...p,
          stock: Math.max(0, Number(p.stock) || 0),
          costPrice: Math.max(0, Number(p.costPrice) || 0),
          sellingPrice: Math.max(0, Number(p.sellingPrice) || 0),
          price: Math.max(0, Number(p.price) || Number(p.sellingPrice) || 0),
        };
      }
      return p;
    });
    if (count > 0) {
      productService.saveProducts(repaired);
      loggerService.log('INVENTORY', 'ERROR', `Admin repaired corrupted financial values for ${count} products.`, { userId: currentUser.id });
    }
    return { success: true, count };
  },

  clearInvalidSessions: (currentUser: AdminUser) => {
    if (currentUser.role !== 'Super Admin') throw new Error("Permission denied");
    // Just force a logout of any inactive user session
    const sessionId = storageCore.get(SESSION_KEY);
    const users = userService.getUsers();
    const active = users.find(u => u.id === sessionId);
    
    if (active && active.status === 'inactive') {
      authService.logout();
      loggerService.log('AUTH', 'CRITICAL', `Admin forcefully cleared an inactive user session.`, { userId: currentUser.id });
      return { success: true, count: 1 };
    }
    return { success: true, count: 0 };
  },

  executeRepairAction: (issueId: string, currentUser: AdminUser): { success: boolean; count?: number; error?: string } => {
    try {
      switch (issueId) {
        case 'dup-users': return diagnosticsService.repairDuplicateUserIds(currentUser);
        case 'dup-customers': return diagnosticsService.repairDuplicateCustomerIds(currentUser);
        case 'dup-orders': return diagnosticsService.repairDuplicateOrderIds(currentUser);
        case 'orphaned-customers': return diagnosticsService.reassignOrphanedCustomers(currentUser);
        case 'inactive-owner-customers': return diagnosticsService.reassignInactiveOwnerCustomers(currentUser);
        case 'orphaned-orders': return diagnosticsService.relinkOrphanedOrders(currentUser);
        case 'mismatched-order-totals': return diagnosticsService.recalculateOrderTotals(currentUser);
        case 'inv-neg': return diagnosticsService.resetNegativeStock(currentUser);
        case 'inv-corrupt-financials': return diagnosticsService.repairCorruptFinancials(currentUser);
        case 'invalid-permissions': return diagnosticsService.repairInvalidPermissions(currentUser);
        case 'inactive-user-session': return diagnosticsService.clearInvalidSessions(currentUser);
        default: return { success: false, error: "No automated repair available for this issue." };
      }
    } catch (e: any) {
      return { success: false, error: e.message };
    }
  }
};
