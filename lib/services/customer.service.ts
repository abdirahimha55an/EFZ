import { storageCore } from "../storage/core";
import { CUSTOMERS_KEY } from "../storage/keys";
import { Customer } from "../types";
import { validateCustomer } from "../validators";

export const customerService = {
  getCustomers: (): Customer[] => {
    const stored = storageCore.get(CUSTOMERS_KEY);
    const customers: Customer[] = stored ? JSON.parse(stored) : [];
    
    // Repair: Ensure all customers have marketingOfficerId
    const repaired = customers.map(c => ({
      ...c,
      marketingOfficerId: c.marketingOfficerId || c.registeredBy
    }));

    if (JSON.stringify(repaired) !== JSON.stringify(customers)) {
      customerService.saveCustomers(repaired);
    }
    return repaired;
  },

  saveCustomers: (customers: Customer[]) => {
    storageCore.set(CUSTOMERS_KEY, JSON.stringify(customers));
  }
};
