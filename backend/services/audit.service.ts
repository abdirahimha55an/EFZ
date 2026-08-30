import { DatabaseConnectionManager } from "../db/connection";
import { SystemLog } from "../../lib/types";

export const backendAuditService = {
  getLogs: async (): Promise<SystemLog[]> => {
    const db = await DatabaseConnectionManager.getConnectionPool();
    // In the future:
    // const res = await db.query("SELECT * FROM uv_AuditLogSummary");
    // return res.recordset;
    return [];
  },

  logEvent: async (log: Omit<SystemLog, 'id' | 'timestamp'>): Promise<{ success: boolean }> => {
    const db = await DatabaseConnectionManager.getConnectionPool();
    // In the future:
    // await db.execute("sp_WriteAuditLog", {
    //   Category: log.category,
    //   Severity: log.severity,
    //   Message: log.message,
    //   UserId: log.userId || null,
    //   TargetId: log.targetId || null,
    //   Metadata: log.metadata ? JSON.stringify(log.metadata) : null
    // });
    return { success: true };
  }
};
