import { storageCore } from "../storage/core";
import { USERS_KEY, INITIALIZED_KEY } from "../storage/keys";
import { AdminUser, UserRole, Permission } from "../types";
import { loggerService } from "../diagnostics/logger";
import { validateUser } from "../validators";

const generateId = (prefix: string = "id"): string => {
  try {
    if (typeof window !== "undefined" && window.crypto && window.crypto.randomUUID) {
      return `${prefix}-${window.crypto.randomUUID()}`;
    }
  } catch (e) {}
  return `${prefix}-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
};

export const userService = {
  getUsers: (): AdminUser[] => {
    const stored = storageCore.get(USERS_KEY);
    
    if (stored) {
      let users: AdminUser[] = JSON.parse(stored);
      users = userService.repairUserIds(users);

      const repaired = users.map(u => {
        let perms = u.permissions || [];
        if (u.role === 'Super Admin' && !perms.includes('override_order_status')) {
          perms = [...perms, 'override_order_status'];
        }
        return {
          ...u,
          earnedCommissionTotal: u.earnedCommissionTotal ?? 0,
          pendingCommissionTotal: u.pendingCommissionTotal ?? 0,
          paidCommissionTotal: u.paidCommissionTotal ?? 0,
          commissionPercentage: u.commissionPercentage ?? 0,
          permissions: perms
        };
      });

      if (JSON.stringify(repaired) !== JSON.stringify(users)) {
        userService.saveUsers(repaired);
      }
      return repaired;
    }
    
    // Fallback seed if uninitialized
    if (typeof window !== "undefined" && localStorage.getItem(INITIALIZED_KEY) !== "true") {
      const defaultUsers: AdminUser[] = [{
        id: "u-1",
        name: "Super Admin",
        email: "admin@efz.so",
        phone: "+252 611223344",
        password: "admin123",
        avatar: "",
        role: "Super Admin",
        status: 'active',
        commissionPercentage: 0,
        earnedCommissionTotal: 0,
        pendingCommissionTotal: 0,
        paidCommissionTotal: 0,
        permissions: [
          'view_dashboard', 'view_orders', 'create_orders', 'edit_orders', 'delete_orders',
          'view_products', 'add_products', 'edit_products', 'delete_products',
          'view_inventory', 'adjust_stock', 'view_customers', 'add_customers',
          'edit_customers', 'delete_customers', 'view_reports', 'view_commissions',
          'mark_commissions_paid', 'manage_users', 'change_settings', 'view_all_customers',
          'view_diagnostics', 'view_audit_trail', 'manage_system', 'override_order_status'
        ]
      }];
      localStorage.setItem(INITIALIZED_KEY, "true");
      userService.saveUsers(defaultUsers);
      return defaultUsers;
    }
    
    return [];
  },

  repairUserIds: (users: AdminUser[]): AdminUser[] => {
    const seenIds = new Set<string>();
    const repairedUsers: AdminUser[] = [];
    let repairedCount = 0;

    users.forEach((user) => {
      let currentId = user.id;
      
      if (!currentId) {
        currentId = generateId('u');
        repairedCount++;
      }

      if (seenIds.has(currentId)) {
        const newId = generateId('u');
        repairedUsers.push({ ...user, id: newId });
        repairedCount++;
      } else {
        seenIds.add(currentId);
        repairedUsers.push({ ...user, id: currentId });
      }
    });

    if (repairedCount > 0) {
      loggerService.log('SYSTEM', 'WARNING', `Repaired ${repairedCount} duplicate/missing user IDs`);
    }

    return repairedUsers;
  },

  saveUsers: (users: AdminUser[]) => {
    storageCore.set(USERS_KEY, JSON.stringify(users));
  }
};
