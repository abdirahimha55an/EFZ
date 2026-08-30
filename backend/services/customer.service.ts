import { DatabaseConnectionManager } from "../db/connection";
import { Customer } from "../../lib/types";

export const backendCustomerService = {
  getCustomers: async (): Promise<Customer[]> => {
    const db = await DatabaseConnectionManager.getConnectionPool();
    // In the future:
    // const res = await db.query("SELECT * FROM uv_CustomerOwnershipSummary");
    // return res.recordset;
    return [];
  },

  createCustomer: async (customer: Omit<Customer, 'id'>): Promise<{ success: boolean; customerId?: string }> => {
    const db = await DatabaseConnectionManager.getConnectionPool();
    // In the future:
    // const res = await db.execute("sp_CreateCustomer", {
    //   Name: customer.name,
    //   Phone: customer.phone,
    //   RegisteredBy: customer.registeredBy,
    //   MarketingOfficerId: customer.marketingOfficerId
    // });
    return { success: true };
  }
};
