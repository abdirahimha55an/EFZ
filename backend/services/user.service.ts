import { DatabaseConnectionManager } from "../db/connection";
import { AdminUser, Permission } from "../../lib/types";

export const backendUserService = {
  getUsers: async (): Promise<AdminUser[]> => {
    const db = await DatabaseConnectionManager.getConnectionPool();
    // In the future:
    // const res = await db.query("SELECT * FROM uv_UserPermissionSummary");
    // return res.recordset;
    return [];
  },

  createUser: async (user: Omit<AdminUser, 'id'>): Promise<{ success: boolean; userId?: string }> => {
    const db = await DatabaseConnectionManager.getConnectionPool();
    // In the future:
    // const res = await db.execute("sp_CreateUser", {
    //   Name: user.name,
    //   Email: user.email,
    //   Phone: user.phone,
    //   Role: user.role,
    //   Status: user.status,
    //   CommissionPercentage: user.commissionPercentage
    // });
    // return { success: true, userId: res.returnValue };
    return { success: true };
  },

  updateUserPermissions: async (userId: string, permissions: Permission[]): Promise<{ success: boolean }> => {
    const db = await DatabaseConnectionManager.getConnectionPool();
    // In the future:
    // Send comma-separated or bulk insert
    // await db.execute("sp_UpdateUserPermissions", { UserId: userId, Permissions: permissions.join(",") });
    return { success: true };
  }
};
