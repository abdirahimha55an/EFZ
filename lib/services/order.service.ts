import { storageCore } from "../storage/core";
import { ORDERS_KEY, INITIALIZED_KEY } from "../storage/keys";
import { Order, OrderStatus } from "../types";
import { customerService } from "./customer.service";

// Migrate legacy statuses to the new 5-stage fulfillment model
const VALID_STATUSES: OrderStatus[] = ['pending', 'confirmed', 'processing', 'delivered', 'cancelled'];
const migrateStatus = (status: string): OrderStatus => {
  const s = (status || 'pending').toLowerCase();
  if (VALID_STATUSES.includes(s as OrderStatus)) return s as OrderStatus;
  // Legacy mappings
  if (s === 'paid') return 'confirmed';
  if (s === 'successfully delivered' || s === 'completed') return 'delivered';
  return 'pending';
};

// Defense-in-depth: sanitize a single order's numeric fields
const sanitizeOrder = (o: any): Order => {
  const items = (o.items || []).map((item: any) => ({
    ...item,
    quantity: Math.max(1, Math.round(Number(item.quantity) || 1)),
    price: Math.max(0, Number(item.price) || 0),
  }));
  const total = Math.max(0, Number(o.total) || items.reduce((s: number, i: any) => s + i.price * i.quantity, 0));
  const cost = Math.max(0, Number(o.cost) || 0);
  return {
    ...o,
    items,
    total,
    cost,
    grossProfit: Number(o.grossProfit) || (total - cost),
  } as Order;
};

export const orderService = {
  getOrders: (): Order[] => {
    const stored = storageCore.get(ORDERS_KEY);
    const customers = customerService.getCustomers();
    let orders: Order[] = [];

    if (!stored) {
      if (typeof window !== "undefined" && localStorage.getItem(INITIALIZED_KEY) !== "true") {
        orders = [
          { id: "ORD-1005", customer: "Mogadishu Futsal Center", phone: "+252 61 123 4567", items: [{productId: "1", productName: "EFZ Elite Futsal", quantity: 20, price: 40}], total: 800, cost: 480, grossProfit: 320, status: "pending" as OrderStatus, paymentStatus: 'unpaid' as const, date: "2023-10-25" },
          { id: "ORD-1004", customer: "Ahmed Ali", phone: "+252 61 987 6543", items: [{productId: "2", productName: "EFZ Pro Match Football", quantity: 5, price: 45}], total: 225, cost: 140, grossProfit: 85, status: "confirmed" as OrderStatus, paymentStatus: 'paid' as const, date: "2023-10-24" },
          { id: "ORD-1003", customer: "Banadir Academy", phone: "+252 61 555 1234", items: [{productId: "3", productName: "EFZ Training Standard", quantity: 50, price: 25}], total: 1250, cost: 750, grossProfit: 500, status: "delivered" as OrderStatus, paymentStatus: 'paid' as const, date: "2023-10-22" },
        ];
        orderService.saveOrders(orders);
      } else {
        orders = [];
      }
    } else {
      orders = JSON.parse(stored);
    }
    
    // Repair/Migration + sanitization
    const repaired = orders.map(o => {
      const status = o.status?.toLowerCase() || 'pending';
      let total = Number(o.total) || 0;
      
      if (total === 0 && o.items && o.items.length > 0) {
        total = o.items.reduce((sum, item) => sum + (Number(item.price) * Number(item.quantity)), 0);
      }

      const customer = customers.find(c => 
        (o.customerId && String(c.id) === String(o.customerId)) || 
        (o.customer === c.name) || 
        (o.phone === c.phone)
      );

      const marketingOfficerId = o.marketingOfficerId || customer?.marketingOfficerId || customer?.registeredBy;
      const cost = Math.max(0, Number(o.cost) || 0);
      const grossProfit = Number(o.grossProfit) || (total - cost);

      return sanitizeOrder({
        ...o,
        status: migrateStatus(o.status),
        paymentStatus: o.paymentStatus || 'unpaid',
        total,
        cost,
        grossProfit,
        customerId: o.customerId || customer?.id,
        marketingOfficerId
      });
    });

    if (JSON.stringify(repaired) !== JSON.stringify(orders)) {
      orderService.saveOrders(repaired);
    }
    return repaired;
  },

  saveOrders: (orders: Order[]) => {
    // Sanitize before persisting
    const sanitized = orders.map(sanitizeOrder);
    storageCore.set(ORDERS_KEY, JSON.stringify(sanitized));
  }
};
