import { storageCore } from "../storage/core";
import { ORDERS_KEY, INITIALIZED_KEY } from "../storage/keys";
import { Order, OrderStatus, OrderType } from "../types";
import { customerService } from "./customer.service";
import { backupService } from "./backup.service";

const VALID_STATUSES: OrderStatus[] = ['pending', 'confirmed', 'processing', 'delivered', 'cancelled'];
const VALID_PAYMENT_STATUSES = ['unpaid', 'partial', 'paid', 'refunded', 'credit'] as const;
const LEGACY_MIGRATION_KEY = 'efz_parent_order_migration_v1';

const asNumber = (value: any, fallback = 0) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
};

const migrateStatus = (status: string): OrderStatus => {
  const s = (status || 'pending').toLowerCase();
  if (VALID_STATUSES.includes(s as OrderStatus)) return s as OrderStatus;
  if (s === 'paid') return 'confirmed';
  if (s === 'successfully delivered' || s === 'completed') return 'delivered';
  return 'pending';
};

const computeItemMetrics = (item: any) => {
  const quantity = Math.max(1, Math.round(asNumber(item.quantity, 1)));
  const actualUnitPrice = Math.max(0, asNumber(item.actualUnitPrice ?? item.price ?? item.standardUnitPrice ?? 0, 0));
  const standardUnitPrice = Math.max(0, asNumber(item.standardUnitPrice ?? item.price ?? item.actualUnitPrice ?? 0, 0));
  const historicalUnitCost = Math.max(0, asNumber(item.historicalUnitCost ?? item.costPrice ?? 0, 0));
  const costPrice = Math.max(0, asNumber(item.costPrice ?? item.historicalUnitCost ?? historicalUnitCost, 0));
  const lineRevenue = actualUnitPrice * quantity;
  const lineCost = historicalUnitCost * quantity || costPrice * quantity;
  const lineProfit = lineRevenue - lineCost;

  return {
    ...item,
    id: item.id ?? `itm-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    productId: item.productId ?? '',
    productName: item.productName ?? 'Unknown Product',
    designName: item.designName ?? item.productName ?? '',
    quantity,
    standardUnitPrice,
    actualUnitPrice,
    price: actualUnitPrice,
    historicalUnitCost,
    costPrice,
    lineRevenue,
    lineCost,
    lineProfit,
  };
};

const computeOrderTotals = (items: any[]) => {
  const normalizedItems = (items || []).map(computeItemMetrics);
  const total = normalizedItems.reduce((sum, item) => sum + Number(item.actualUnitPrice || item.price || 0) * Number(item.quantity || 0), 0);
  const cost = normalizedItems.reduce((sum, item) => sum + Number(item.historicalUnitCost ?? item.costPrice ?? 0) * Number(item.quantity || 0), 0);
  const grossProfit = total - cost;
  return { items: normalizedItems, total, cost, grossProfit };
};

const sanitizeOrder = (o: any): Order => {
  const fallbackItems = Array.isArray(o.items) ? o.items : [];
  const computed = computeOrderTotals(fallbackItems);
  const normalizedTotal = Math.max(0, asNumber(o.total, computed.total));
  const paymentEntries = Array.isArray(o.payments) ? o.payments : [];
  const sumPaid = paymentEntries.reduce((sum: number, entry: any) => sum + asNumber(entry.amount, 0), 0) || asNumber(o.amountPaid, 0);
  const normalizedPaymentStatus = !paymentEntries.length && asNumber(o.amountPaid, 0) === 0
    ? 'unpaid'
    : !paymentEntries.length && asNumber(o.amountPaid, 0) > 0 && asNumber(o.amountPaid, 0) < normalizedTotal
      ? 'partial'
      : !paymentEntries.length && asNumber(o.amountPaid, 0) >= normalizedTotal
        ? 'paid'
        : sumPaid <= 0
          ? 'unpaid'
          : sumPaid >= normalizedTotal
            ? 'paid'
            : 'partial';

  return {
    ...o,
    items: computed.items,
    total: normalizedTotal,
    cost: Math.max(0, asNumber(o.cost, computed.cost)),
    grossProfit: asNumber(o.grossProfit, computed.grossProfit),
    status: migrateStatus(o.status || 'pending'),
    paymentStatus: VALID_PAYMENT_STATUSES.includes((normalizedPaymentStatus || 'unpaid').toLowerCase() as any)
      ? (normalizedPaymentStatus || 'unpaid').toLowerCase()
      : 'unpaid',
    orderType: o.orderType === 'trial' ? 'trial' : 'regular',
    legacyOrderIds: Array.isArray(o.legacyOrderIds) ? o.legacyOrderIds : (o.legacyReferenceId ? [o.legacyReferenceId] : []),
    legacyReferenceId: o.legacyReferenceId || o.id,
    amountPaid: Math.min(sumPaid, normalizedTotal),
    outstandingBalance: Math.max(0, normalizedTotal - Math.min(sumPaid, normalizedTotal)),
    customerId: o.customerId || o.customerName || o.customer || undefined,
    payments: paymentEntries,
  } as Order;
};

const buildMigratedOrder = (sourceOrders: any[], customer: string, customerId: string | undefined, phone: string, marketingOfficerId: string | undefined, date: string, orderType: OrderType, legacyOrderIds: string[]) => {
  const mergedItems: any[] = sourceOrders.flatMap(order => (order.items || []).map((item: any) => ({
    ...item,
    productId: item.productId || '',
    productName: item.productName || 'Unknown Product',
    quantity: asNumber(item.quantity, 1),
    actualUnitPrice: asNumber(item.actualUnitPrice ?? item.price ?? 0, 0),
    standardUnitPrice: asNumber(item.standardUnitPrice ?? item.price ?? item.actualUnitPrice ?? 0, 0),
    historicalUnitCost: asNumber(item.historicalUnitCost ?? item.costPrice ?? 0, 0),
    costPrice: asNumber(item.costPrice ?? item.historicalUnitCost ?? 0, 0),
    designName: item.designName ?? item.productName ?? '',
    price: asNumber(item.actualUnitPrice ?? item.price ?? item.standardUnitPrice ?? 0, 0),
  })));

  const { items, total, cost, grossProfit } = computeOrderTotals(mergedItems);

  const parentOrder: Order = {
    id: `EFZ-${legacyOrderIds.join('-') || `legacy-${Date.now()}`}`.replace(/[^a-zA-Z0-9-]/g, '-').slice(0, 40) || `EFZ-${Date.now()}`,
    customer,
    customerId,
    marketingOfficerId,
    phone,
    items,
    total,
    status: sourceOrders.some((o) => String(o.status).toLowerCase() === 'cancelled') ? 'cancelled' : 
      sourceOrders.some((o) => String(o.status).toLowerCase() === 'processing') ? 'processing' :
      sourceOrders.some((o) => String(o.status).toLowerCase() === 'confirmed') ? 'confirmed' :
      sourceOrders.some((o) => String(o.status).toLowerCase() === 'delivered') ? 'delivered' : 'pending',
    paymentStatus: (sourceOrders[0]?.paymentStatus || 'unpaid').toLowerCase() as any,
    date: date || sourceOrders[0]?.date || '',
    cost,
    grossProfit,
    orderType,
    legacyOrderIds,
    legacyReferenceId: legacyOrderIds[0] || `${customer}-${date}`,
    amountPaid: 0,
    outstandingBalance: Math.max(0, total),
    createdAt: sourceOrders[0]?.createdAt,
  };

  return sanitizeOrder(parentOrder);
};

const migrateHistoricalOrdersToParentOrders = (orders: any[]): Order[] => {
  if (!Array.isArray(orders) || orders.length === 0) return [];

  const alreadyMigrated = orders.some((order) => Array.isArray(order.legacyOrderIds) && order.legacyOrderIds.length > 0);
  if (alreadyMigrated) {
    return orders.map(sanitizeOrder);
  }

  const groups: Array<{ customer: string; customerId?: string; phone: string; marketingOfficerId?: string; date: string; groupKey: string; orderType: OrderType; ids: string[] }> = [
    { customer: 'Dhimbil', customerId: 'cust-1787686150099', phone: '613900520', marketingOfficerId: 'u-db5f39ee-b67d-4832-83f5-a54ce4bba0d4', date: '2026-08-25', groupKey: 'dhimbil-trial', orderType: 'trial', ids: ['ORD-9126100'] },
    { customer: 'Dhimbil', customerId: 'cust-1787686150099', phone: '613900520', marketingOfficerId: 'u-db5f39ee-b67d-4832-83f5-a54ce4bba0d4', date: '2026-08-25', groupKey: 'dhimbil-normal', orderType: 'regular', ids: ['ORD-5530967', 'ORD-6001219'] },
    { customer: 'Sky Dome', customerId: 'cust-1787416286614', phone: '615934772', marketingOfficerId: 'u-db5f39ee-b67d-4832-83f5-a54ce4bba0d4', date: '2026-08-24', groupKey: 'sky-occasion-1', orderType: 'regular', ids: ['ORD-4523995', 'ORD-9370151'] },
    { customer: 'Sky Dome', customerId: 'cust-1787416286614', phone: '615934772', marketingOfficerId: 'u-db5f39ee-b67d-4832-83f5-a54ce4bba0d4', date: '2026-08-26', groupKey: 'sky-occasion-2', orderType: 'regular', ids: ['ORD-2052863', 'ORD-7186157'] },
    { customer: 'Goobe Stadium', customerId: undefined, phone: '', marketingOfficerId: undefined, date: '', groupKey: 'goobe-stadium', orderType: 'regular', ids: ['ORD-9645475', 'ORD-6010721'] },
  ];

  const groupMap = new Map<string, any[]>();
  for (const group of groups) {
    groupMap.set(group.groupKey, orders.filter((order) => group.ids.includes(String(order.id))));
  }

  const remainingLegacyOrders = orders.filter((order) => !groups.some((group) => group.ids.includes(String(order.id))));
  const migrated: Order[] = groups
    .filter((group) => groupMap.get(group.groupKey)?.length)
    .map((group) => buildMigratedOrder(groupMap.get(group.groupKey) || [], group.customer, group.customerId, group.phone, group.marketingOfficerId, group.date, group.orderType, group.ids))
    .concat(
      remainingLegacyOrders.map((order) => sanitizeOrder({
        ...order,
        id: order.id,
        legacyOrderIds: [order.id],
        legacyReferenceId: order.id,
        orderType: 'regular',
        amountPaid: 0,
        outstandingBalance: Math.max(0, Number(order.total) || 0),
      }))
    );

  return migrated.sort((a, b) => {
    const timeA = a.date ? new Date(a.date).getTime() : 0;
    const timeB = b.date ? new Date(b.date).getTime() : 0;
    return (Number.isFinite(timeB) ? timeB : 0) - (Number.isFinite(timeA) ? timeA : 0);
  });
};

export const orderService = {
  getOrders: (): Order[] => {
    const stored = storageCore.get(ORDERS_KEY);
    const customers = customerService.getCustomers();
    let orders: Order[] = [];

    if (!stored) {
      if (typeof window !== "undefined") {
        const approvedMigrationLoaded = backupService.activateApprovedHistoricalMigration();
        if (approvedMigrationLoaded) {
          orders = JSON.parse(storageCore.get(ORDERS_KEY) || '[]');
        } else if (localStorage.getItem(INITIALIZED_KEY) !== "true") {
          orders = [
            { id: "ORD-1005", customer: "Mogadishu Futsal Center", phone: "+252 61 123 4567", items: [{productId: "1", productName: "EFZ Elite Futsal", quantity: 20, standardUnitPrice: 40, actualUnitPrice: 40, historicalUnitCost: 24, price: 40, costPrice: 24}], total: 800, cost: 480, grossProfit: 320, status: "pending" as OrderStatus, paymentStatus: 'unpaid' as const, date: "2023-10-25" },
            { id: "ORD-1004", customer: "Ahmed Ali", phone: "+252 61 987 6543", items: [{productId: "2", productName: "EFZ Pro Match Football", quantity: 5, standardUnitPrice: 45, actualUnitPrice: 45, historicalUnitCost: 28, price: 45, costPrice: 28}], total: 225, cost: 140, grossProfit: 85, status: "confirmed" as OrderStatus, paymentStatus: 'paid' as const, date: "2023-10-24" },
            { id: "ORD-1003", customer: "Banadir Academy", phone: "+252 61 555 1234", items: [{productId: "3", productName: "EFZ Training Standard", quantity: 50, standardUnitPrice: 25, actualUnitPrice: 25, historicalUnitCost: 15, price: 25, costPrice: 15}], total: 1250, cost: 750, grossProfit: 500, status: "delivered" as OrderStatus, paymentStatus: 'paid' as const, date: "2023-10-22" },
          ];
          orderService.saveOrders(orders);
        } else {
          orders = [];
        }
      } else {
        orders = [];
      }
    } else {
      orders = JSON.parse(stored);
    }

    const migrated = migrateHistoricalOrdersToParentOrders(orders);
    const repaired = migrated.map((o: any) => {
      const status = o.status?.toLowerCase() || 'pending';
      let total = Number(o.total) || 0;

      if (total === 0 && o.items && o.items.length > 0) {
        total = o.items.reduce((sum: number, item: any) => sum + (Number(item.actualUnitPrice ?? item.price ?? 0) * Number(item.quantity || 0)), 0);
      }

      const customer = customers.find((c: any) => 
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
        marketingOfficerId,
        orderType: o.orderType || 'regular',
      });
    });

    const shouldPersist = JSON.stringify(repaired) !== JSON.stringify(orders);
    if (shouldPersist) {
      orderService.saveOrders(repaired);
    }

    return repaired;
  },

  saveOrders: (orders: Order[]) => {
    const sanitized = orders.map(sanitizeOrder);
    storageCore.set(ORDERS_KEY, JSON.stringify(sanitized));
    storageCore.set(LEGACY_MIGRATION_KEY, 'true');
  }
};
