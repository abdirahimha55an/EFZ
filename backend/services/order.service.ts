import { DatabaseConnectionManager } from "../db/connection";
import { Order } from "../../lib/types";

export const backendOrderService = {
  getOrders: async (): Promise<Order[]> => {
    const db = await DatabaseConnectionManager.getConnectionPool();
    // In the future:
    // const res = await db.query("SELECT * FROM uv_OrderSummary");
    // return res.recordset;
    return [];
  },

  createOrder: async (order: Omit<Order, 'id'>): Promise<{ success: boolean; orderId?: string }> => {
    const db = await DatabaseConnectionManager.getConnectionPool();
    // In the future:
    // const res = await db.execute("sp_CreateOrder", {
    //   CustomerId: order.customerId,
    //   MarketingOfficerId: order.marketingOfficerId,
    //   Status: order.status,
    //   Notes: order.deliveryNotes
    //   -- Plus details inside a JSON parameter or XML
    // });
    return { success: true };
  },

  updateOrderStatus: async (orderId: string, newStatus: string): Promise<{ success: boolean }> => {
    const db = await DatabaseConnectionManager.getConnectionPool();
    // In the future:
    // await db.execute("sp_UpdateOrderStatus", { OrderId: orderId, Status: newStatus });
    return { success: true };
  }
};
