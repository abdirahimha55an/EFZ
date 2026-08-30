import { DatabaseConnectionManager } from "../db/connection";
import { Product } from "../../lib/types";

export const backendProductService = {
  getProducts: async (): Promise<Product[]> => {
    const db = await DatabaseConnectionManager.getConnectionPool();
    // In the future:
    // const res = await db.query("SELECT * FROM uv_InventorySummary");
    // return res.recordset;
    return [];
  },

  adjustInventory: async (productId: string, quantityChange: number, reason: string, updatedBy: string): Promise<{ success: boolean }> => {
    const db = await DatabaseConnectionManager.getConnectionPool();
    // In the future:
    // await db.execute("sp_AdjustInventory", {
    //   ProductId: productId,
    //   QuantityChange: quantityChange,
    //   Reason: reason,
    //   UpdatedBy: updatedBy
    // });
    return { success: true };
  }
};
