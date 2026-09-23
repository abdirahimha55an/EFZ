"use client";

import { useCallback, useEffect, useState } from "react";
import { Search, Eye, Trash2, ShoppingBag, Clock, CheckCircle2, XCircle, Filter, Plus, User, Package, AlertCircle, X, Loader2, Truck, RefreshCcw } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { cn } from "@/lib/utils";
import { AdminUser, Customer, Order, Product, ORDER_STATUS_TRANSITIONS, OrderStatus } from "@/lib/types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";

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
  const [currentUser, setCurrentUser] = useState<AdminUser | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [isSaving, setIsSaving] = useState(false);

  const [searchTerm, setSearchTerm] = useState("");
  const [statusFilter, setStatusFilter] = useState("all");
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [notification, setNotification] = useState<{type: 'success' | 'error', message: string} | null>(null);

  const [formData, setFormData] = useState({
    customerId: "",
    orderType: "regular" as "regular" | "trial",
    amountPaid: 0,
    status: "pending",
    notes: ""
  });
  const [orderItems, setOrderItems] = useState<OrderLineDraft[]>([blankOrderLine("first")]);

  // The whole page in one read. Orders arrive from the order_details view with
  // their items and payments already nested, so there is no N+1 fan-out here.
  const refresh = useCallback(async () => {
    const db = getDb();
    const [nextOrders, nextCustomers, nextProducts, nextProfile] = await Promise.all([
      db.orders.list(),
      db.customers.list(),
      db.products.list(),
      db.auth.getProfile(),
    ]);
    setOrders(nextOrders);
    setCustomers(nextCustomers);
    setProducts(nextProducts);
    setCurrentUser(nextProfile);
  }, []);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        setIsLoading(true);
        const db = getDb();
        const [nextOrders, nextCustomers, nextProducts, nextProfile] = await Promise.all([
          db.orders.list(),
          db.customers.list(),
          db.products.list(),
          db.auth.getProfile(),
        ]);
        if (cancelled) return;
        setOrders(nextOrders);
        setCustomers(nextCustomers);
        setProducts(nextProducts);
        setCurrentUser(nextProfile);
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
  }, []);

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

  /**
   * The prompts and confirmations below are the operator's safety net. The
   * actual rules live in update_order_status(): it validates the transition,
   * demands Super Admin for anything illegal, and moves the stock. If this
   * function's checks and the database ever disagree, the database wins.
   */
  const handleStatusChange = async (id: string, newStatus: string) => {
    const order = orders.find(o => o.id === id);
    if (!order) return;

    if (!perms.editOrders) {
      showNotification('error', 'Permission denied: You are not allowed to update order status.');
      return;
    }

    const oldStatus = order.status as OrderStatus;
    const targetStatus = newStatus as OrderStatus;

    if (oldStatus === targetStatus) return;

    const hasOverridePermission = perms.overrideOrderStatus;

    // Same table the database enforces, so the UI never offers a move the
    // server will reject without warning.
    const isNormalTransition = (ORDER_STATUS_TRANSITIONS[oldStatus] || []).includes(targetStatus);

    let requiresOverride = !isNormalTransition;
    let warningMsg = "";

    // 1. Cancelled Order Protection
    if (oldStatus === 'cancelled') {
      requiresOverride = true;
      warningMsg = "Cancelled orders are locked. Override required.";
    }

    // 2. Delivered Order Protection
    if (oldStatus === 'delivered') {
      requiresOverride = true;
      warningMsg = "Delivered orders are finalized.";
    }

    // 3. Paid Order Protection
    if (order.paymentStatus === 'paid') {
      requiresOverride = true;
      warningMsg = "Paid orders require admin override to change.";
    }

    // 3b. Commission Paid Protection
    const isCommissionPaid = order.commissionPaid === true;
    if (isCommissionPaid) {
      requiresOverride = true;
      warningMsg = "Commission has already been paid out. Only Super Admin override can change this.";
    }

    // Enforce Permission Check
    if (requiresOverride) {
      if (!hasOverridePermission) {
        showNotification('error', `Forbidden: ${warningMsg || "Override permission required."}`);
        return;
      }
    }

    // 5. Determine if reason is required
    const needsReason = 
      targetStatus === 'cancelled' ||
      oldStatus === 'cancelled' ||
      oldStatus === 'delivered' ||
      order.paymentStatus === 'paid' ||
      isCommissionPaid;

    let reason = "";
    if (needsReason) {
      const promptTitle = isCommissionPaid 
        ? `CRITICAL OVERRIDE: Changing commission-locked order #${id}.\nEnter explanation:`
        : `Risky status change from "${oldStatus}" to "${targetStatus}".\nPlease enter a reason/comment:`;

      const defaultReason = targetStatus === 'cancelled' ? 'Customer request' : 'Administrative adjustment';
      const userInput = prompt(promptTitle, defaultReason);
      
      if (userInput === null) {
        // User clicked cancel on prompt
        return; 
      }
      
      reason = userInput.trim() || defaultReason;
    }

    // Confirmation for risky overrides
    if (requiresOverride) {
      const confirmMsg = `Are you sure you want to perform this override?\n\n` +
        `Order: #${id}\n` +
        `Transition: ${oldStatus} → ${targetStatus}\n` +
        `Reason: "${reason || 'N/A'}"\n\n` +
        `This action will be audited.`;
      
      if (!confirm(confirmMsg)) return;
    }

    // Stock is not touched here. update_order_status() restores it on cancel,
    // takes it back on reactivation, and refuses the reactivation outright if
    // the units are no longer on the shelf - all in one transaction, so the
    // half-moved-stock state the old client-side version could produce is gone.
    try {
      setIsSaving(true);
      const db = getDb();

      await db.orders.setStatus(id, targetStatus, reason);

      const severity = requiresOverride ? 'WARNING' : 'INFO';
      const auditMessage = requiresOverride
        ? `OVERRIDE: Order #${id} status changed from ${oldStatus} to ${targetStatus}. Reason: ${reason}`
        : `Order #${id} status changed from ${oldStatus} to ${targetStatus}`;

      await db.logs.write({
        category: 'FINANCIAL',
        severity,
        message: auditMessage,
        targetId: id,
        metadata: {
          oldValue: oldStatus,
          newValue: targetStatus,
          isOverride: requiresOverride,
          reason: reason || undefined,
          changedBy: currentUser?.name || 'system',
          userId: currentUser?.id,
          source: 'Order Tracking',
        },
      });

      await refresh();
      showNotification('success', `Order #${id} updated: ${oldStatus} → ${targetStatus}`);
    } catch (error) {
      showNotification('error', describeDbError(error));
    } finally {
      setIsSaving(false);
    }
  };

  const canCreateOrders = perms.createOrders;
  const canViewInventory = perms.viewInventory;
  const canDeleteOrders = perms.deleteOrders;

  const addOrderItem = () => {
    setOrderItems(prev => [...prev, blankOrderLine()]);
  };

  const updateOrderItem = (id: string, patch: Partial<{ productId: string; quantity: number; actualUnitPrice: number }>) => {
    setOrderItems(prev => prev.map(item => item.id === id ? { ...item, ...patch } : item));
  };

  const removeOrderItem = (id: string) => {
    setOrderItems(prev => prev.length > 1 ? prev.filter(item => item.id !== id) : prev);
  };

  const itemCalculations = orderItems.map(item => {
    const product = products.find(p => p.id === item.productId);
    const actualUnitPrice = Number(item.actualUnitPrice || 0);
    const quantity = Math.max(1, Number(item.quantity || 1));
    const standardUnitPrice = Number(product?.sellingPrice ?? product?.price ?? 0);
    const costPrice = Number(product?.costPrice ?? 0);
    const lineRevenue = actualUnitPrice * quantity;
    const lineCost = costPrice * quantity;
    const lineProfit = lineRevenue - lineCost;
    return { product, quantity, actualUnitPrice, standardUnitPrice, costPrice, lineRevenue, lineCost, lineProfit };
  });

  const subtotal = itemCalculations.reduce((sum, item) => sum + item.lineRevenue, 0);
  const totalCost = itemCalculations.reduce((sum, item) => sum + item.lineCost, 0);
  const grossProfit = subtotal - totalCost;
  const totalOutstanding = Math.max(0, subtotal - formData.amountPaid);
  const computedPaymentStatus = formData.amountPaid <= 0 ? 'unpaid' : formData.amountPaid >= subtotal ? 'paid' : 'partial';

  const handleCreateOrder = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!canCreateOrders) {
      showNotification('error', 'Permission denied: You are not allowed to create new orders.');
      return;
    }

    const customer = customers.find(c => c.id === formData.customerId);
    if (!customer) {
      showNotification('error', 'Please select a customer.');
      return;
    }

    const validItems = orderItems
      .map(item => ({ ...item, quantity: Math.max(1, Number(item.quantity || 1)), actualUnitPrice: Number(item.actualUnitPrice || 0) }))
      .filter(item => item.productId && item.quantity > 0);

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
      if (!Number.isFinite(item.actualUnitPrice) || item.actualUnitPrice < 0) {
        showNotification('error', 'Each item must have a valid selling price greater than or equal to 0.');
        return;
      }
      if (product.stock < item.quantity) {
        showNotification('error', `Insufficient stock for ${product.name}! Only ${product.stock} units available.`);
        return;
      }
    }

    const paymentAmount = Math.max(0, Number(formData.amountPaid || 0));

    try {
      setIsSaving(true);
      const db = getDb();

      // One transaction: the order, its lines with their frozen cost snapshots,
      // the stock deductions and the movement ledger. If any line is short on
      // stock the whole thing is rejected and nothing is written.
      const created = await db.orders.create({
        customerId: customer.id,
        customerName: customer.name,
        phone: customer.phone,
        marketingOfficerId: customer.marketingOfficerId || customer.registeredBy,
        orderType: formData.orderType,
        status: formData.status as OrderStatus,
        orderDate: new Date().toISOString().split('T')[0],
        deliveryNotes: formData.notes,
        items: validItems.map(item => ({
          productId: item.productId,
          quantity: item.quantity,
          actualUnitPrice: item.actualUnitPrice,
        })),
      });

      // A separate call, because the payment is its own audited event. If it
      // fails the order still stands - just unpaid - and the message says so.
      if (paymentAmount > 0) {
        try {
          await db.orders.addPayment({
            orderId: created.id,
            amount: paymentAmount,
            paymentDate: new Date().toISOString().split('T')[0],
            notes: 'Initial payment',
          });
        } catch (paymentError) {
          await refresh();
          setIsModalOpen(false);
          showNotification(
            'error',
            `Order ${created.id} was created, but the initial payment failed: ${describeDbError(paymentError)}. Record it from the order list.`
          );
          return;
        }
      }

      await db.logs.write({
        category: 'FINANCIAL',
        severity: 'INFO',
        message: `New order created: ${created.id} for ${customer.name} ($${created.total})`,
        targetId: created.id,
        metadata: {
          total: created.total,
          grossProfit: created.grossProfit,
          items: created.items.length,
          orderType: formData.orderType,
          source: 'Order Tracking',
        },
      });

      await refresh();
      setIsModalOpen(false);
      setOrderItems([blankOrderLine("first")]);
      setFormData({ customerId: "", orderType: "regular", amountPaid: 0, status: "pending", notes: "" });
      showNotification('success', `Order ${created.id} created successfully for ${customer.name}`);
    } catch (error) {
      showNotification('error', describeDbError(error));
    } finally {
      setIsSaving(false);
    }
  };

  const handleDelete = async (id: string) => {
    const order = orders.find(o => o.id === id);
    if (!order) return;

    if (!canDeleteOrders) {
      showNotification('error', 'Permission denied: You are not allowed to delete orders.');
      return;
    }

    if (order.commissionPaid && currentUser?.role !== 'Super Admin') {
      showNotification('error', 'Only Super Admin can delete commission-locked orders.');
      return;
    }

    const needsRestock = order.status !== 'cancelled';
    const confirmed = confirm(
      needsRestock
        ? `Delete order ${id}?\n\nIt will be cancelled first so its ${order.items.length} line(s) go back into stock, then removed along with its items and payments. This cannot be undone.`
        : `Delete order ${id}? Its items and payments go with it. This cannot be undone.`
    );
    if (!confirmed) return;

    try {
      setIsSaving(true);
      const db = getDb();

      // Cancel before deleting so the stock returns through the ledger rather
      // than vanishing with the row. Deleting outright would leave the units
      // permanently deducted with nothing left to explain why.
      if (needsRestock) {
        await db.orders.setStatus(id, 'cancelled', `Cancelled ahead of deletion of order ${id}`);
      }

      await db.logs.write({
        category: 'FINANCIAL',
        severity: 'WARNING',
        message: `Order deleted: ${id}`,
        targetId: id,
        metadata: { restocked: needsRestock, total: order.total },
      });

      await db.orders.remove(id);
      await refresh();
      showNotification('success', 'Order deleted');
    } catch (error) {
      showNotification('error', describeDbError(error));
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
                      </td>
                      <td className="px-6 py-3">
                        <p className="font-bold text-slate-900 group-hover:text-brand-blue transition-colors truncate">{order.customer}</p>
                        <p className="text-slate-500 text-[10px] mt-0.5 flex items-center gap-1 font-medium">
                          <span className="h-1 w-1 rounded-full bg-slate-300" /> {order.phone}
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
                          {canViewInventory ? (
                            <span className="text-[9px] font-bold text-blue-500 uppercase mt-0.5">Profit: ${(order.grossProfit || (order.total - (order.cost || 0))).toFixed(0)}</span>
                          ) : (
                            <span className="text-[9px] font-bold text-slate-400 uppercase mt-0.5">Profit hidden</span>
                          )}
                        </div>
                      </td>
                      <td className="px-6 py-3">
                        <div className="relative inline-block w-full max-w-[140px]">
                          {canChangeStatus ? (
                        <select 
                          className={cn(
                            "w-full h-7 rounded px-2 pl-7 text-[9px] font-bold uppercase tracking-wider appearance-none border border-transparent transition-all cursor-pointer",
                            config.color
                          )}
                          value={order.status}
                          disabled={isSaving}
                          onChange={(e) => handleStatusChange(order.id, e.target.value)}
                        >
                          <option value="pending">Pending</option>
                          <option value="confirmed">Confirmed</option>
                          <option value="processing">Processing</option>
                          <option value="delivered">Delivered</option>
                          <option value="cancelled">Cancelled</option>
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
                          <Button variant="ghost" size="sm" className="h-7 w-7 p-0 text-slate-400 hover:text-brand-blue hover:bg-blue-50 rounded-md">
                            <Eye className="h-3.5 w-3.5" />
                          </Button>
                          {perms.deleteOrders && (
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
                  </div>

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
                      const lineTotal = (Number(item.actualUnitPrice || 0) * Number(item.quantity || 1));

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
                              value={item.quantity}
                              onChange={e => updateOrderItem(item.id, { quantity: Math.max(1, Number(e.target.value || 1)) })}
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
                            <span>{product ? product.name : 'No product selected'}</span>
                            <span className="font-bold text-slate-900">Total: ${lineTotal.toFixed(2)}</span>
                          </div>
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
                      <div className="flex justify-between">
                        <span className="text-slate-400">Cost</span>
                        <span className="font-bold text-white">${totalCost.toFixed(2)}</span>
                      </div>
                      <div className="flex justify-between border-t border-white/10 pt-2">
                        <span className="text-slate-400 font-bold uppercase">Gross Profit</span>
                        <span className="font-bold text-brand-blue">${grossProfit.toFixed(2)}</span>
                      </div>
                    </div>
                  </div>

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
