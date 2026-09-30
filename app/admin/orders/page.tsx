"use client";

import { useCallback, useEffect, useState } from "react";
import { Search, Trash2, ShoppingBag, Clock, CheckCircle2, XCircle, Filter, Plus, User, Package, AlertCircle, X, Loader2, Truck, RefreshCcw } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { cn } from "@/lib/utils";
import { AdminUser, Customer, Order, Product, ORDER_STATUS_TRANSITIONS, ORDER_STATUSES, OrderStatus } from "@/lib/types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";
import { efzToday } from "@/lib/dates";

/** Payments or paid commission: cancelling needs a Super Admin and a reason. */
const isFinanciallyLocked = (order: Order) =>
  Number(order.amountPaid ?? 0) > 0 || (order.payments?.length ?? 0) > 0 || order.commissionPaid === true;

/** One editable row in the create-order form. Not persisted as-is. */
type OrderLineDraft = {
  id: string;
  productId: string;
  quantity: number;
  actualUnitPrice: number;
};

/**
 * `suffix` keeps the initial row's key deterministic. Generating it from
 * Date.now() during render is impure, and React's lint rule is right to object:
 * a re-render would hand the row a new key and blow away what was typed in it.
 */
const blankOrderLine = (suffix?: string): OrderLineDraft => ({
  id: `item-${suffix ?? `${Date.now()}-${Math.random().toString(36).slice(2, 7)}`}`,
  productId: "",
  quantity: 1,
  actualUnitPrice: 0,
});

export default function OrdersPage() {
  const [orders, setOrders] = useState<Order[]>([]);
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [staff, setStaff] = useState<AdminUser[]>([]);
  const [currentUser, setCurrentUser] = useState<AdminUser | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [isSaving, setIsSaving] = useState(false);

  const [searchTerm, setSearchTerm] = useState("");
  const [statusFilter, setStatusFilter] = useState("all");
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [notification, setNotification] = useState<{type: 'success' | 'error', message: string} | null>(null);

  // No status and no officer here: create_order() always starts an order as
  // pending and takes the Marketing Officer from the customer.
  const blankForm = () => ({
    customerId: "",
    orderType: "regular" as "regular" | "trial",
    amountPaid: 0,
    notes: "",
    /** Super Admin only; today (Mogadishu) for everyone else. */
    orderDate: efzToday(),
    /** Super Admin only, when a line is priced below cost. */
    belowCostReason: "",
  });
  const [formData, setFormData] = useState(blankForm);
  const [orderItems, setOrderItems] = useState<OrderLineDraft[]>([blankOrderLine("first")]);

  // The whole page in one read. Orders arrive from the order_details view with
  // their items and payments already nested, so there is no N+1 fan-out here.
  // Products come from staff_products: cost is null unless this user may see it.
  const loadPage = useCallback(async () => {
    const db = getDb();
    const [nextOrders, nextCustomers, nextProducts, nextStaff, nextProfile] = await Promise.all([
      db.orders.list(),
      db.customers.list(),
      db.products.list(),
      db.users.list(),
      db.auth.getProfile(),
    ]);
    return { nextOrders, nextCustomers, nextProducts, nextStaff, nextProfile };
  }, []);

  const refresh = useCallback(async () => {
    const next = await loadPage();
    setOrders(next.nextOrders);
    setCustomers(next.nextCustomers);
    setProducts(next.nextProducts);
    setStaff(next.nextStaff);
    setCurrentUser(next.nextProfile);
  }, [loadPage]);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        setIsLoading(true);
        const next = await loadPage();
        if (cancelled) return;
        setOrders(next.nextOrders);
        setCustomers(next.nextCustomers);
        setProducts(next.nextProducts);
        setStaff(next.nextStaff);
        setCurrentUser(next.nextProfile);
        setLoadError(null);
      } catch (error) {
        if (!cancelled) setLoadError(describeDbError(error));
      } finally {
        if (!cancelled) setIsLoading(false);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [loadPage]);

  useEffect(() => {
    if (notification) {
      const timer = setTimeout(() => setNotification(null), 3000);
      return () => clearTimeout(timer);
    }
  }, [notification]);

  const perms = derivePermissions(currentUser);

  const showNotification = (type: 'success' | 'error', message: string) => {
    setNotification({ type, message });
  };

  const handleRefresh = async () => {
    try {
      setIsSaving(true);
      await refresh();
      showNotification('success', 'Orders refreshed');
    } catch (error) {
      showNotification('error', describeDbError(error));
    } finally {
      setIsSaving(false);
    }
  };

  // Everything below mirrors update_order_status() / create_order() in
  // supabase/10_rpc_hardening.sql so the page only offers what the database
  // will accept. The database is still the one that decides.
  const hideCost = !perms.viewCost;
  const describe = (error: unknown) => describeDbError(error, { hideCost });

  /** Statuses this user may move an order to, including overrides for a Super Admin. */
  const statusOptionsFor = (order: Order): OrderStatus[] => {
    if (!perms.editOrders) return [order.status];
    const normal = ORDER_STATUS_TRANSITIONS[order.status] ?? [];
    const allowed = ORDER_STATUSES.filter(status => {
      if (status === order.status) return true;
      if (perms.overrideOrders) return true;
      if (!normal.includes(status)) return false;
      // Cancelling an order with payments or paid commission is Super Admin only.
      return !(status === 'cancelled' && isFinanciallyLocked(order));
    });
    return allowed;
  };

  const handleStatusChange = async (id: string, newStatus: string) => {
    const order = orders.find(o => o.id === id);
    if (!order) return;

    if (!perms.editOrders) {
      showNotification('error', 'Permission denied: you are not allowed to update order status.');
      return;
    }

    const oldStatus = order.status;
    const targetStatus = newStatus as OrderStatus;
    if (oldStatus === targetStatus) return;

    const isNormal = (ORDER_STATUS_TRANSITIONS[oldStatus] ?? []).includes(targetStatus);
    const cancellingLocked = targetStatus === 'cancelled' && isFinanciallyLocked(order);

    if ((!isNormal || cancellingLocked) && !perms.overrideOrders) {
      showNotification(
        'error',
        cancellingLocked
          ? `Order #${id} has payments or paid commission. Only a Super Admin can cancel it.`
          : `${oldStatus} → ${targetStatus} is not a normal step. Only a Super Admin can override it.`
      );
      return;
    }

    // The database requires a reason for every override and for cancelling a
    // paid / commission-locked order. A normal cancellation gets one too, so
    // the audit line says why.
    const reasonRequired = !isNormal || cancellingLocked;
    let reason = "";
    if (reasonRequired || targetStatus === 'cancelled') {
      const title = reasonRequired
        ? `Super Admin ${isNormal ? 'cancellation' : 'override'}: order #${id}, ${oldStatus} → ${targetStatus}.\n` +
          `${cancellingLocked ? 'This order has payments or paid commission. ' : ''}A reason is required and will be recorded:`
        : `Cancel order #${id}? Its stock returns to the shelf.\nReason:`;
      const input = prompt(title, reasonRequired ? "" : "Customer request");
      if (input === null) return;
      reason = input.trim();
      if (reasonRequired && !reason) {
        showNotification('error', 'A reason is required for this change.');
        return;
      }
    }

    try {
      setIsSaving(true);
      // update_order_status() moves the stock, stamps delivered_at on first
      // delivery and writes the audit line itself, all in one transaction.
      await getDb().orders.setStatus(id, targetStatus, reason);
      await refresh();
      showNotification('success', `Order #${id} updated: ${oldStatus} → ${targetStatus}`);
    } catch (error) {
      showNotification('error', describe(error));
    } finally {
      setIsSaving(false);
    }
  };

  const canCreateOrders = perms.createOrders;

  const addOrderItem = () => {
    setOrderItems(prev => [...prev, blankOrderLine()]);
  };

  const updateOrderItem = (id: string, patch: Partial<{ productId: string; quantity: number; actualUnitPrice: number }>) => {
    setOrderItems(prev => prev.map(item => item.id === id ? { ...item, ...patch } : item));
  };

  const removeOrderItem = (id: string) => {
    setOrderItems(prev => prev.length > 1 ? prev.filter(item => item.id !== id) : prev);
  };

  // Cost is known only to users the database shows it to; for everyone else
  // costPrice is null and the preview shows revenue only.
  const itemCalculations = orderItems.map(item => {
    const product = products.find(p => p.id === item.productId);
    const actualUnitPrice = Number(item.actualUnitPrice || 0);
    const quantity = Number(item.quantity || 0);
    const costPrice = product?.costPrice ?? null;
    const lineRevenue = actualUnitPrice * quantity;
    const lineCost = costPrice === null ? null : costPrice * quantity;
    const belowCost = costPrice !== null && Boolean(product) && actualUnitPrice < costPrice;
    return { product, quantity, actualUnitPrice, costPrice, lineRevenue, lineCost, belowCost };
  });

  const subtotal = itemCalculations.reduce((sum, item) => sum + item.lineRevenue, 0);
  const totalCost = itemCalculations.every(item => !item.product || item.lineCost !== null)
    ? itemCalculations.reduce((sum, item) => sum + (item.lineCost ?? 0), 0)
    : null;
  const grossProfit = totalCost === null ? null : subtotal - totalCost;
  const hasBelowCostLine = itemCalculations.some(item => item.belowCost);
  const totalOutstanding = Math.max(0, subtotal - formData.amountPaid);
  const computedPaymentStatus = formData.amountPaid <= 0 ? 'unpaid' : formData.amountPaid >= subtotal ? 'paid' : 'partial';
  const today = efzToday();

  const officerName = (officerId?: string | null) =>
    officerId ? staff.find(u => u.id === officerId)?.name ?? 'Unknown officer' : null;

  const handleCreateOrder = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!canCreateOrders) {
      showNotification('error', 'Permission denied: you are not allowed to create orders.');
      return;
    }

    const customer = customers.find(c => c.id === formData.customerId);
    if (!customer) {
      showNotification('error', 'Every order needs a customer. Please select one.');
      return;
    }

    const validItems = orderItems.filter(item => item.productId);
    if (!validItems.length) {
      showNotification('error', 'Please add at least one product to the order.');
      return;
    }

    for (const item of validItems) {
      const product = products.find(p => p.id === item.productId);
      if (!product) {
        showNotification('error', 'One or more selected items are invalid.');
        return;
      }
      if (!Number.isInteger(item.quantity) || item.quantity < 1) {
        showNotification('error', `Quantity for ${product.name} must be a whole number of at least 1.`);
        return;
      }
      if (!Number.isFinite(item.actualUnitPrice) || item.actualUnitPrice < 0) {
        showNotification('error', `Price for ${product.name} must be 0 or more.`);
        return;
      }
      if (product.stock < item.quantity) {
        showNotification('error', `Insufficient stock for ${product.name}: only ${product.stock} available.`);
        return;
      }
      if (product.costPrice !== null && item.actualUnitPrice < product.costPrice && !perms.approveBelowCost) {
        showNotification('error', `Price for ${product.name} is below its cost. Only a Super Admin can approve a below-cost sale.`);
        return;
      }
    }

    if (hasBelowCostLine && perms.approveBelowCost && !formData.belowCostReason.trim()) {
      showNotification('error', 'A below-cost sale needs an approval reason.');
      return;
    }

    let orderDate: string | undefined;
    if (perms.backdate && formData.orderDate && formData.orderDate !== today) {
      if (formData.orderDate > today) {
        showNotification('error', 'An order cannot be dated in the future.');
        return;
      }
      orderDate = formData.orderDate;
    }

    const paymentAmount = Math.max(0, Number(formData.amountPaid || 0));

    try {
      setIsSaving(true);
      const db = getDb();

      // One transaction: the order (always pending, officer taken from the
      // customer), its lines with the list price and frozen cost snapshot, the
      // stock deductions and the movement ledger. Any refusal writes nothing.
      const created = await db.orders.create({
        customerId: customer.id,
        customerName: customer.name,
        phone: customer.phone,
        orderType: formData.orderType,
        orderDate,
        deliveryNotes: formData.notes,
        belowCostReason: hasBelowCostLine ? formData.belowCostReason.trim() : undefined,
        items: validItems.map(item => ({
          productId: item.productId,
          quantity: item.quantity,
          actualUnitPrice: item.actualUnitPrice,
        })),
      });

      // A separate call, because the payment is its own audited event. It is
      // dated today (Mogadishu) by the database. If it fails the order still
      // stands - just unpaid - and the message says so.
      if (paymentAmount > 0) {
        try {
          await db.orders.addPayment({
            orderId: created.id,
            amount: paymentAmount,
            notes: 'Initial payment',
          });
        } catch (paymentError) {
          await refresh();
          setIsModalOpen(false);
          showNotification(
            'error',
            `Order ${created.id} was created, but the initial payment failed: ${describe(paymentError)}. Record it from the Customer Database.`
          );
          return;
        }
      }

      await db.logs.write({
        category: 'ORDER',
        severity: 'INFO',
        message: `New order created: ${created.id} for ${customer.name} ($${created.total})`,
        targetId: created.id,
        metadata: {
          total: created.total,
          items: created.items.length,
          orderType: formData.orderType,
          source: 'Order Tracking',
        },
      });

      await refresh();
      setIsModalOpen(false);
      setOrderItems([blankOrderLine("first")]);
      setFormData(blankForm());
      showNotification('success', `Order ${created.id} created for ${customer.name}`);
    } catch (error) {
      showNotification('error', describe(error));
    } finally {
      setIsSaving(false);
    }
  };

  /** orders_delete: Super Admin, cancelled, no payments, no paid commission. */
  const canDelete = (order: Order) =>
    perms.deleteCancelledOrders && order.status === 'cancelled' && !isFinanciallyLocked(order);

  const handleDelete = async (id: string) => {
    const order = orders.find(o => o.id === id);
    if (!order) return;

    if (!canDelete(order)) {
      showNotification('error', 'Only a Super Admin can delete an order, and only a cancelled order with no payments. Cancel it instead.');
      return;
    }

    if (!confirm(`Delete cancelled order ${id}? Its stock was already returned when it was cancelled. This cannot be undone.`)) return;

    try {
      setIsSaving(true);
      const db = getDb();

      await db.logs.write({
        category: 'ORDER',
        severity: 'WARNING',
        message: `Order deleted: ${id}`,
        targetId: id,
        metadata: { total: order.total, status: order.status },
      });

      await db.orders.remove(id);
      await refresh();
      showNotification('success', `Order ${id} deleted`);
    } catch (error) {
      showNotification('error', describe(error));
    } finally {
      setIsSaving(false);
    }
  };

  const filteredOrders = orders.filter(order => {
    // RLS already limits what comes back; this narrows it further for a user who
    // holds view_orders but is scoped to their own customers.
    if (perms.viewOwnCustomersOnly) {
      const isOwner = currentUser ? String(order.marketingOfficerId) === String(currentUser.id) : false;
      if (!isOwner) return false;
    }

    const legacyMatches = [order.legacyReferenceId, ...(order.legacyOrderIds || [])]
      .filter((value): value is string => Boolean(value))
      .some((value) => value.toLowerCase().includes(searchTerm.toLowerCase()));
    const matchesSearch = 
      order.customer.toLowerCase().includes(searchTerm.toLowerCase()) || 
      order.id.toLowerCase().includes(searchTerm.toLowerCase()) ||
      legacyMatches;
    const matchesStatus = statusFilter === "all" || order.status === statusFilter;
    return matchesSearch && matchesStatus;
  }).sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime());

  const canChangeStatus = perms.editOrders;

  const getStatusConfig = (status: string) => {
    switch (status) {
      case 'pending': return { label: 'Pending', color: "bg-orange-100 text-orange-700 border-orange-200", icon: <Clock className="h-3 w-3" /> };
      case 'confirmed': return { label: 'Confirmed', color: "bg-blue-100 text-blue-700 border-blue-200", icon: <CheckCircle2 className="h-3 w-3" /> };
      case 'processing': return { label: 'Processing', color: "bg-purple-100 text-purple-700 border-purple-200", icon: <Loader2 className="h-3 w-3" /> };
      case 'delivered': return { label: 'Delivered', color: "bg-green-100 text-green-700 border-green-200", icon: <Truck className="h-3 w-3" /> };
      case 'cancelled': return { label: 'Cancelled', color: "bg-red-100 text-red-700 border-red-200", icon: <XCircle className="h-3 w-3" /> };
      default: return { label: status, color: "bg-slate-100 text-slate-700 border-slate-200", icon: <Clock className="h-3 w-3" /> };
    }
  };

  if (isLoading) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400">
        <Loader2 className="h-6 w-6 animate-spin text-brand-blue" />
        <p className="text-xs font-medium">Loading orders…</p>
      </div>
    );
  }

  if (loadError) {
    return (
      <Card className="border-none shadow-sm">
        <CardContent className="flex flex-col items-center gap-4 py-16 text-center">
          <AlertCircle className="h-8 w-8 text-red-500" />
          <div>
            <h2 className="font-heading text-lg font-bold text-slate-900">Could not load orders</h2>
            <p className="mt-1 max-w-md text-xs text-slate-500">{loadError}</p>
          </div>
          <Button onClick={handleRefresh} variant="outline" size="sm" className="rounded-lg text-xs">
            <RefreshCcw className="mr-1.5 h-3.5 w-3.5" /> Try again
          </Button>
        </CardContent>
      </Card>
    );
  }

  return (
    <div className="space-y-10 animate-in fade-in duration-500">
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div>
          <h1 className="font-heading text-2xl font-bold text-slate-900 tracking-tight">Order Tracking</h1>
          <p className="text-slate-400 mt-0.5 flex items-center gap-2 text-xs font-medium">
            <ShoppingBag className="h-3.5 w-3.5 text-brand-blue" /> 
            Manage customer requests and track payment fulfillment.
          </p>
        </div>
        <div className="flex gap-2">
          <Button onClick={handleRefresh} disabled={isSaving} variant="outline" size="sm" className="text-slate-500 border-slate-200 rounded-lg h-10 px-4 text-xs">
            <RefreshCcw className={cn("h-4 w-4 mr-1.5", isSaving && "animate-spin")} /> Refresh
          </Button>
          {perms.createOrders && (
            <Button onClick={() => setIsModalOpen(true)} disabled={isSaving} className="bg-slate-900 text-white rounded-lg h-10 px-4 text-xs shadow-lg shadow-slate-200">
              <Plus className="h-4 w-4 mr-1" /> Create New Order
            </Button>
          )}
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-4 gap-3">
        {['all', 'pending', 'confirmed', 'processing', 'delivered', 'cancelled'].map((status) => (
          <button 
            key={status}
            onClick={() => setStatusFilter(status)}
            className={cn(
              "p-4 rounded-2xl text-left transition-all border-2",
              statusFilter === status 
                ? "bg-white border-brand-blue shadow-lg shadow-blue-100 ring-2 ring-blue-50/50" 
                : "bg-slate-50/50 border-transparent hover:bg-slate-100/80"
            )}
          >
            <p className="text-[9px] font-bold text-slate-400 uppercase tracking-widest">{status === 'all' ? 'Total Volume' : status}</p>
            <h3 className="text-xl font-bold text-slate-900 mt-0.5 capitalize">
              {status === 'all' ? orders.length : orders.filter(o => o.status === status).length}
            </h3>
          </button>
        ))}
      </div>

      <Card className="border-none shadow-xl shadow-slate-100 overflow-hidden bg-white">
        <CardContent className="p-0">
          <div className="p-4 border-b border-slate-100 flex flex-col md:flex-row gap-3 justify-between items-center">
            <div className="relative w-full md:w-80">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-slate-400" />
              <Input 
                placeholder="Search orders, customers, or products..." 
                className="pl-9 h-9 bg-slate-50 border-none rounded-lg text-xs"
                value={searchTerm}
                onChange={(e) => setSearchTerm(e.target.value)}
              />
            </div>
            
            <div className="flex items-center gap-2 w-full md:w-auto">
              <select 
                className="h-9 w-full md:w-40 rounded-lg border-none bg-slate-50 px-3 text-xs font-bold text-slate-600 outline-none transition-all cursor-pointer"
                value={statusFilter}
                onChange={(e) => setStatusFilter(e.target.value)}
              >
                <option value="all">All Channels</option>
                <option value="pending">Pending</option>
                <option value="confirmed">Confirmed</option>
                <option value="processing">Processing</option>
                <option value="delivered">Delivered</option>
                <option value="cancelled">Cancelled</option>
              </select>
            </div>
          </div>

          <div className="overflow-x-auto">
            <table className="w-full text-xs text-left">
              <thead className="bg-slate-50/50 text-slate-400 uppercase text-[9px] font-bold tracking-widest border-b border-slate-100">
                <tr>
                  <th className="px-6 py-3 w-[120px]">Order ID</th>
                  <th className="px-6 py-3">Customer Details</th>
                  <th className="px-6 py-3">Product Allocation</th>
                  <th className="px-6 py-3 w-[120px]">Value / Profit</th>
                  <th className="px-6 py-3 w-[160px]">Fulfillment</th>
                  <th className="px-6 py-3 w-[80px] text-right">Actions</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-50">
                {filteredOrders.map((order) => {
                  const config = getStatusConfig(order.status);
                  return (
                    <tr key={order.id} className="hover:bg-slate-50/50 transition-colors group border-b border-slate-50 last:border-0">
                      <td className="px-6 py-3">
                        <div className="flex items-center gap-1.5">
                          <span className="font-mono text-[10px] font-bold text-slate-400">#{order.id}</span>
                          {order.commissionPaid && (
                            <div className="bg-orange-50 text-orange-600 p-0.5 rounded shadow-sm" title="Commission Processed & Locked">
                              <AlertCircle className="h-2.5 w-2.5" />
                            </div>
                          )}
                        </div>
                        <p className="text-[9px] text-slate-400 mt-0.5">{order.date}</p>
                        {order.deliveredAt && (
                          <p className="text-[9px] text-green-600 mt-0.5 font-bold" title={new Date(order.deliveredAt).toLocaleString()}>
                            Delivered {new Date(order.deliveredAt).toLocaleDateString()}
                          </p>
                        )}
                      </td>
                      <td className="px-6 py-3">
                        <p className="font-bold text-slate-900 group-hover:text-brand-blue transition-colors truncate">{order.customer}</p>
                        <p className="text-slate-500 text-[10px] mt-0.5 flex items-center gap-1 font-medium">
                          <span className="h-1 w-1 rounded-full bg-slate-300" /> {order.phone}
                        </p>
                        <p className="text-[9px] mt-0.5 font-medium text-slate-400">
                          Officer: {order.marketingOfficerName
                            ? <span className="font-bold text-slate-600">{order.marketingOfficerName}</span>
                            : <span className="italic">unassigned</span>}
                        </p>
                      </td>
                      <td className="px-6 py-3">
                        {order.items.map((item, index) => (
                          <div key={`${order.id}-${item.productId}-${index}`}>
                            <p className="text-slate-900 font-bold truncate">{item.productName}</p>
                            <p className="text-slate-500 text-[10px] mt-0.5 font-medium italic">Qty: {item.quantity} · Unit: ${(Number(item.actualUnitPrice ?? item.price ?? item.standardUnitPrice ?? 0)).toFixed(2)}</p>
                          </div>
                        ))}
                      </td>
                      <td className="px-6 py-3">
                        <div className="flex flex-col">
                          <span className="text-brand-green font-bold text-xs">${order.total.toFixed(0)}</span>
                          {/* grossProfit is null when the database withholds cost from this user. */}
                          {order.grossProfit !== null ? (
                            <span className="text-[9px] font-bold text-blue-500 uppercase mt-0.5">Profit: ${order.grossProfit.toFixed(0)}</span>
                          ) : (
                            <span className="text-[9px] font-bold text-slate-400 uppercase mt-0.5">Profit hidden</span>
                          )}
                        </div>
                      </td>
                      <td className="px-6 py-3">
                        <div className="relative inline-block w-full max-w-[140px]">
                          {canChangeStatus && statusOptionsFor(order).length > 1 ? (
                        <select
                          className={cn(
                            "w-full h-7 rounded px-2 pl-7 text-[9px] font-bold uppercase tracking-wider appearance-none border border-transparent transition-all cursor-pointer",
                            config.color
                          )}
                          value={order.status}
                          disabled={isSaving}
                          onChange={(e) => handleStatusChange(order.id, e.target.value)}
                        >
                          {statusOptionsFor(order).map(status => {
                            const isOverride = status !== order.status
                              && !(ORDER_STATUS_TRANSITIONS[order.status] ?? []).includes(status);
                            return (
                              <option key={status} value={status}>
                                {getStatusConfig(status).label}{isOverride ? ' (override)' : ''}
                              </option>
                            );
                          })}
                        </select>
                      ) : (
                        <div className={cn(
                            "w-full h-7 rounded px-2 pl-7 text-[9px] font-bold uppercase tracking-wider border border-transparent flex items-center",
                            config.color
                          )}
                        >
                          <span>{config.label}</span>
                        </div>
                      )}
                          <div className="absolute left-2 top-1/2 -translate-y-1/2 pointer-events-none">
                            {config.icon}
                          </div>
                        </div>
                      </td>
                      <td className="px-6 py-3 text-right">
                        <div className="flex justify-end gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                          {canDelete(order) && (
                            <Button onClick={() => handleDelete(order.id)} disabled={isSaving} variant="ghost" size="sm" className="h-7 w-7 p-0 text-slate-400 hover:text-red-600 hover:bg-red-50 rounded-md">
                              <Trash2 className="h-3.5 w-3.5" />
                            </Button>
                          )}
                        </div>
                      </td>
                    </tr>
                  );
                })}
                {filteredOrders.length === 0 && (
                  <tr>
                    <td colSpan={6} className="px-8 py-24 text-center">
                      <div className="flex flex-col items-center gap-4 text-slate-300">
                        <ShoppingBag className="h-16 w-16 opacity-20" />
                        <p className="font-bold uppercase tracking-[0.2em] text-xs">No orders detected</p>
                        <Button variant="ghost" onClick={() => {setSearchTerm(""); setStatusFilter("all")}} className="text-brand-blue text-xs font-bold">Clear Global Filters</Button>
                      </div>
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </CardContent>
      </Card>

      {/* Create Order Modal */}
      {isModalOpen && (
        <div className="fixed inset-0 z-[100] bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-[1.5rem] shadow-2xl w-full max-w-2xl animate-in zoom-in duration-300 overflow-hidden flex flex-col">
            <div className="p-6 border-b flex justify-between items-center bg-white sticky top-0 z-10 shrink-0">
              <div className="flex items-center gap-3">
                <div className="h-10 w-10 bg-brand-blue/10 rounded-xl flex items-center justify-center text-brand-blue shadow-inner">
                  <Plus className="h-5 w-5" />
                </div>
                <div>
                  <h2 className="text-lg font-bold text-slate-900 tracking-tight">Create New Order</h2>
                  <p className="text-slate-500 text-[11px] font-medium">Provision new customer fulfillment.</p>
                </div>
              </div>
              <button onClick={() => setIsModalOpen(false)} className="h-8 w-8 hover:bg-slate-100 rounded-full transition-colors flex items-center justify-center border border-slate-100">
                <X className="h-4 w-4 text-slate-400" />
              </button>
            </div>

            <form onSubmit={handleCreateOrder} className="flex-1 overflow-y-auto p-6 space-y-6 custom-scrollbar">
              <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                <div className="space-y-4">
                  <div className="space-y-1">
                    <label className="text-[10px] font-bold text-slate-700 ml-1 flex items-center gap-2">
                      <User className="h-3 w-3 text-slate-400" /> Select Customer
                    </label>
                    <select 
                      required
                      className="w-full h-9 rounded-lg border border-slate-200 bg-slate-50 px-3 text-xs font-medium outline-none focus:ring-2 focus:ring-brand-blue/20 transition-all cursor-pointer"
                      value={formData.customerId}
                      onChange={e => setFormData({...formData, customerId: e.target.value})}
                    >
                      <option value="">-- Choose registered customer --</option>
                      {customers
                        .filter(c => {
                          if (perms.viewOwnCustomersOnly) {
                            return currentUser ? String(c.marketingOfficerId || c.registeredBy) === String(currentUser.id) : false;
                          }
                          return true;
                        })
                        .map(c => <option key={c.id} value={c.id}>{c.name} ({c.phone})</option>)
                      }
                    </select>
                    {(() => {
                      const selected = customers.find(c => c.id === formData.customerId);
                      if (!selected) return null;
                      const owner = officerName(selected.marketingOfficerId);
                      return (
                        <p className="ml-1 text-[10px] text-slate-500">
                          Commission owner (from the customer):{" "}
                          {owner
                            ? <span className="font-bold text-slate-700">{owner}</span>
                            : <span className="italic">unassigned - no officer earns on this order</span>}
                        </p>
                      );
                    })()}
                  </div>

                  {perms.backdate && (
                    <div className="space-y-1">
                      <label className="text-[10px] font-bold text-slate-700 ml-1">Order Date (Super Admin)</label>
                      <Input
                        type="date"
                        max={today}
                        value={formData.orderDate}
                        onChange={e => setFormData({ ...formData, orderDate: e.target.value })}
                        className="h-9 rounded-lg bg-slate-50 border-slate-200 text-xs"
                      />
                      {formData.orderDate && formData.orderDate < today && (
                        <p className="ml-1 text-[10px] font-bold text-amber-600">Backdated order - it will be recorded in the audit log.</p>
                      )}
                    </div>
                  )}

                  <div className="space-y-1">
                    <label className="text-[10px] font-bold text-slate-700 ml-1">Order Type</label>
                    <div className="flex gap-2">
                      {(['regular', 'trial'] as const).map(type => (
                        <button
                          key={type}
                          type="button"
                          onClick={() => setFormData({ ...formData, orderType: type })}
                          className={cn(
                            "flex-1 h-9 rounded-lg border text-[11px] font-bold uppercase tracking-wide transition-all",
                            formData.orderType === type
                              ? "border-slate-900 bg-slate-900 text-white"
                              : "border-slate-200 bg-slate-50 text-slate-600"
                          )}
                        >
                          {type}
                        </button>
                      ))}
                    </div>
                  </div>

                  <div className="space-y-3">
                    <div className="flex items-center justify-between">
                      <label className="text-[10px] font-bold text-slate-700 ml-1 flex items-center gap-2">
                        <Package className="h-3 w-3 text-slate-400" /> Order Items
                      </label>
                      <button type="button" onClick={addOrderItem} className="text-[10px] font-bold text-brand-blue">+ Add Item</button>
                    </div>

                    {orderItems.map((item, index) => {
                      const product = products.find(p => p.id === item.productId);
                      const lineTotal = (Number(item.actualUnitPrice || 0) * Number(item.quantity || 0));
                      const belowCost = itemCalculations[index]?.belowCost ?? false;

                      return (
                        <div key={item.id} className="rounded-xl border border-slate-200 bg-slate-50 p-3 space-y-3">
                          <div className="flex items-center justify-between gap-2">
                            <span className="text-[9px] font-bold uppercase tracking-[0.2em] text-slate-400">Item {index + 1}</span>
                            {orderItems.length > 1 && (
                              <button type="button" onClick={() => removeOrderItem(item.id)} className="text-[10px] font-bold text-red-500">Remove</button>
                            )}
                          </div>

                          <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
                            <select
                              className="h-9 rounded-lg border border-slate-200 bg-white px-2 text-xs font-medium outline-none focus:ring-2 focus:ring-brand-blue/20"
                              value={item.productId}
                              onChange={e => updateOrderItem(item.id, { productId: e.target.value, actualUnitPrice: Number(products.find(p => p.id === e.target.value)?.sellingPrice ?? products.find(p => p.id === e.target.value)?.price ?? 0) })}
                            >
                              <option value="">Select product</option>
                              {products.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
                            </select>

                            <Input
                              type="number"
                              min="1"
                              step="1"
                              value={item.quantity}
                              onChange={e => updateOrderItem(item.id, { quantity: Math.max(1, Math.floor(Number(e.target.value || 1))) })}
                              className="h-9 rounded-lg bg-white border-slate-200 text-xs"
                              placeholder="Qty"
                            />

                            <Input
                              type="number"
                              min="0"
                              step="0.01"
                              value={item.actualUnitPrice}
                              onChange={e => updateOrderItem(item.id, { actualUnitPrice: Number(e.target.value || 0) })}
                              className="h-9 rounded-lg bg-white border-slate-200 text-xs"
                              placeholder="Actual price"
                            />
                          </div>

                          <div className="flex items-center justify-between text-[10px] text-slate-500">
                            <span>
                              {product ? `${product.name} · list $${product.sellingPrice.toFixed(2)}` : 'No product selected'}
                            </span>
                            <span className="font-bold text-slate-900">Total: ${lineTotal.toFixed(2)}</span>
                          </div>
                          {belowCost && (
                            <p className="text-[10px] font-bold text-red-600">
                              {perms.approveBelowCost
                                ? 'Below cost - needs your approval reason below.'
                                : 'Below cost - only a Super Admin can approve this price.'}
                            </p>
                          )}
                        </div>
                      );
                    })}
                  </div>
                </div>

                <div className="space-y-4">
                  <div className="bg-slate-900 rounded-2xl p-4 text-slate-300 shadow-xl border border-slate-800">
                    <h3 className="text-[9px] font-bold text-slate-500 uppercase tracking-widest mb-3">Order Summary</h3>
                    <div className="space-y-2 text-[10px]">
                      <div className="flex justify-between">
                        <span className="text-slate-400">Subtotal</span>
                        <span className="font-bold text-white">${subtotal.toFixed(2)}</span>
                      </div>
                      {totalCost !== null && grossProfit !== null && (
                        <>
                          <div className="flex justify-between">
                            <span className="text-slate-400">Cost</span>
                            <span className="font-bold text-white">${totalCost.toFixed(2)}</span>
                          </div>
                          <div className="flex justify-between border-t border-white/10 pt-2">
                            <span className="text-slate-400 font-bold uppercase">Gross Profit</span>
                            <span className="font-bold text-brand-blue">${grossProfit.toFixed(2)}</span>
                          </div>
                        </>
                      )}
                    </div>
                  </div>

                  {hasBelowCostLine && perms.approveBelowCost && (
                    <div className="space-y-1 rounded-xl border border-red-200 bg-red-50 p-3">
                      <label className="text-[10px] font-bold text-red-700 ml-1">Below-cost approval reason (required)</label>
                      <textarea
                        required
                        className="w-full h-16 rounded-lg border border-red-200 bg-white p-2 text-xs outline-none"
                        placeholder="e.g., Damaged stock clearance"
                        value={formData.belowCostReason}
                        onChange={e => setFormData({ ...formData, belowCostReason: e.target.value })}
                      />
                      <p className="text-[10px] text-red-600">
                        Recorded with your name, the price, the cost and the margin for each below-cost line.
                      </p>
                    </div>
                  )}

                  <div className="space-y-3">
                    <div className="space-y-1">
                      <label className="text-[10px] font-bold text-slate-700 ml-1">Amount Paid</label>
                      <Input
                        type="number"
                        min="0"
                        step="0.01"
                        value={formData.amountPaid}
                        onChange={e => setFormData({ ...formData, amountPaid: Number(e.target.value || 0) })}
                        className="h-9 rounded-lg bg-slate-50 border-slate-200 text-xs"
                      />
                    </div>
                    <div className="rounded-xl border border-slate-200 bg-slate-50 p-3 space-y-2 text-[10px]">
                      <div className="flex justify-between"><span className="text-slate-500">Payment Status</span><span className="font-bold uppercase text-slate-900">{computedPaymentStatus}</span></div>
                      <div className="flex justify-between"><span className="text-slate-500">Outstanding</span><span className="font-bold text-slate-900">${totalOutstanding.toFixed(2)}</span></div>
                    </div>
                  </div>

                  <div className="space-y-1">
                    <label className="text-[10px] font-bold text-slate-700 ml-1">Delivery Notes (Optional)</label>
                    <textarea 
                      className="w-full h-20 rounded-lg border border-slate-200 bg-slate-50 p-3 text-xs font-medium outline-none focus:ring-2 focus:ring-brand-blue/20 transition-all resize-none"
                      placeholder="e.g., Gate code 1234..."
                      value={formData.notes}
                      onChange={e => setFormData({...formData, notes: e.target.value})}
                    />
                  </div>
                </div>
              </div>
 
              <div className="pt-2 flex gap-3">
                <Button type="submit" disabled={isSaving} className="flex-1 bg-slate-900 text-white h-11 rounded-xl font-bold text-sm hover:bg-slate-800 shadow-lg shadow-slate-200 transition-all">
                  {isSaving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Create Order
                </Button>
                <Button type="button" variant="outline" disabled={isSaving} onClick={() => setIsModalOpen(false)} className="px-8 h-11 rounded-xl font-bold text-xs text-slate-400 hover:bg-slate-50 border-slate-200">
                  Cancel
                </Button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Global Notification Toast */}
      {notification && (
        <div className={cn(
          "fixed bottom-8 right-8 z-[200] flex items-center gap-3 px-6 py-4 rounded-2xl shadow-2xl border animate-in slide-in-from-right-10 duration-300",
          notification.type === 'success' ? "bg-white border-green-100 text-slate-900" : "bg-red-50 border-red-100 text-red-900"
        )}>
          <div className={cn(
            "h-8 w-8 rounded-full flex items-center justify-center shrink-0",
            notification.type === 'success' ? "bg-green-100 text-green-600" : "bg-red-100 text-red-600"
          )}>
            {notification.type === 'success' ? <CheckCircle2 className="h-4 w-4" /> : <AlertCircle className="h-4 w-4" />}
          </div>
          <p className="text-sm font-bold pr-2">{notification.message}</p>
        </div>
      )}
    </div>
  );
}
