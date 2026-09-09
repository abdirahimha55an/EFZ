import { Order, PaymentRecord, PaymentStatus } from "./types";

export type FinancialSummary = {
  revenueGenerated: number;
  totalCost: number;
  grossProfit: number;
  cashCollected: number;
  outstandingReceivables: number;
  totalOrders: number;
  totalUnits: number;
  grossMargin: number;
};

export const getOrderCollectedAmount = (order: Order): number => {
  const paymentTotal = Array.isArray(order.payments)
    ? order.payments.reduce((sum, payment) => sum + Number(payment.amount || 0), 0)
    : 0;
  const legacyAmount = Number(order.amountPaid ?? 0);
  return Math.max(0, paymentTotal > 0 ? paymentTotal : legacyAmount, legacyAmount > 0 ? legacyAmount : paymentTotal);
};

export const getOrderPaymentStatus = (order: Order): PaymentStatus => {
  const total = Number(order.total || 0);
  const collected = getOrderCollectedAmount(order);

  if (total <= 0) return 'paid';
  if (collected <= 0) return 'unpaid';
  if (collected >= total) return 'paid';
  return 'partial';
};

export const getOrderOutstanding = (order: Order): number => {
  const total = Number(order.total || 0);
  const collected = getOrderCollectedAmount(order);
  return Math.max(0, total - collected);
};

export const getOrderCollectionSummary = (order: Order) => ({
  collected: getOrderCollectedAmount(order),
  outstanding: getOrderOutstanding(order),
  status: getOrderPaymentStatus(order),
});

export const getFinancialSummary = (orders: Order[]): FinancialSummary => {
  const validOrders = Array.isArray(orders) ? orders : [];
  const revenueGenerated = validOrders.reduce((sum, order) => sum + Number(order.total || 0), 0);
  const totalCost = validOrders.reduce((sum, order) => sum + Number(order.cost || 0), 0);
  const cashCollected = validOrders.reduce((sum, order) => sum + getOrderCollectedAmount(order), 0);
  const outstandingReceivables = Math.max(0, revenueGenerated - cashCollected);
  const totalUnits = validOrders.reduce((sum, order) => {
    return sum + order.items.reduce((itemSum, item) => itemSum + Number(item.quantity || 0), 0);
  }, 0);

  const grossProfit = revenueGenerated - totalCost;
  const grossMargin = revenueGenerated > 0 ? (grossProfit / revenueGenerated) * 100 : 0;

  return {
    revenueGenerated,
    totalCost,
    grossProfit,
    cashCollected,
    outstandingReceivables,
    totalOrders: validOrders.length,
    totalUnits,
    grossMargin,
  };
};

export const getCustomerFinancialSummary = (customer: { id: string; name: string; phone: string }, orders: Order[]) => {
  const customerOrders = orders.filter((order) => {
    return order.customerId === customer.id || order.customer === customer.name || order.phone === customer.phone;
  });

  const revenueGenerated = customerOrders.reduce((sum, order) => sum + Number(order.total || 0), 0);
  const cashCollected = customerOrders.reduce((sum, order) => sum + getOrderCollectedAmount(order), 0);
  const outstanding = Math.max(0, revenueGenerated - cashCollected);
  const totalUnits = customerOrders.reduce((sum, order) => sum + order.items.reduce((itemSum, item) => itemSum + Number(item.quantity || 0), 0), 0);
  const status: PaymentStatus = outstanding <= 0 ? 'paid' : cashCollected > 0 ? 'partial' : 'unpaid';

  return {
    orders: customerOrders,
    totalOrders: customerOrders.length,
    totalUnits,
    revenueGenerated,
    cashCollected,
    outstanding,
    paymentStatus: status,
  };
};

export const addPaymentToOrder = (order: Order, payment: Omit<PaymentRecord, 'id' | 'orderId' | 'createdAt'> & { amount: number; recordedBy?: string; createdAt?: string }) => {
  const amount = Number(payment.amount || 0);
  const currentPaid = getOrderCollectedAmount(order);
  const total = Number(order.total || 0);
  const outstanding = Math.max(0, total - currentPaid);

  if (!Number.isFinite(amount) || amount <= 0 || amount > outstanding) {
    throw new Error('Invalid payment amount');
  }

  const paymentRecord: PaymentRecord = {
    id: `pay-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    orderId: order.id,
    amount,
    paymentDate: payment.paymentDate || new Date().toISOString().slice(0, 10),
    paymentMethod: payment.paymentMethod || 'Cash',
    notes: payment.notes || payment.reference || '',
    reference: payment.reference || '',
    recordedBy: payment.recordedBy || 'System',
    createdAt: payment.createdAt || new Date().toISOString(),
  };

  const nextPayments = Array.isArray(order.payments) ? [...order.payments, paymentRecord] : [paymentRecord];
  const nextCollected = nextPayments.reduce((sum, entry) => sum + Number(entry.amount || 0), 0);

  return {
    ...order,
    payments: nextPayments,
    amountPaid: Math.min(nextCollected, total),
    outstandingBalance: Math.max(0, total - nextCollected),
    paymentStatus: getOrderPaymentStatus({ ...order, payments: nextPayments, amountPaid: Math.min(nextCollected, total), outstandingBalance: Math.max(0, total - nextCollected) }),
  };
};
