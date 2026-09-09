import { storageCore } from "../storage/core";
import { CUSTOMERS_KEY } from "../storage/keys";
import { Customer } from "../types";
import { validateCustomer } from "../validators";
import { backupService } from "./backup.service";

export const customerService = {
  getCustomers: (): Customer[] => {
    const stored = storageCore.get(CUSTOMERS_KEY);
    if (!stored && typeof window !== "undefined") {
      backupService.activateApprovedHistoricalMigration();
    }
    const rawCustomers: Customer[] = stored ? JSON.parse(stored) : [];

    const normalized: Customer[] = rawCustomers.map((customer) => {
      const name = customer.name?.trim() || '';
      const isGoobe = name.toLowerCase() === 'goobe stadium';
      const phone = isGoobe && (!customer.phone || customer.phone === 'N/A') ? '614612860' : customer.phone || '';

      return {
        ...customer,
        name,
        phone,
        marketingOfficerId: customer.marketingOfficerId || customer.registeredBy,
        notes: customer.notes ?? '',
        isArchived: Boolean(customer.isArchived || customer.status === 'archived'),
        status: customer.status === 'archived' ? 'archived' : (customer.isArchived ? 'archived' : 'active'),
      } as Customer;
    });

    const deduped = normalized.filter((customer, index, list) => {
      const first = list.findIndex((item) => item.id === customer.id || (item.name.toLowerCase() === customer.name.toLowerCase() && item.phone === customer.phone));
      return first === index;
    });

    if (JSON.stringify(deduped) !== JSON.stringify(rawCustomers)) {
      customerService.saveCustomers(deduped);
    }
    return deduped;
  },

  saveCustomers: (customers: Customer[]) => {
    storageCore.set(CUSTOMERS_KEY, JSON.stringify(customers));
  }
};
