"use client";

import { useState, useEffect } from "react";
import { Search, Eye, Trash2, ShoppingBag, Clock, CheckCircle2, XCircle, Filter, Calendar, Plus, User, DollarSign, Package, AlertCircle, X, Loader2, Truck } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { cn } from "@/lib/utils";
import { storage, AdminUser, Customer, Order, ORDER_STATUS_TRANSITIONS, OrderStatus } from "@/lib/storage";
import { Product } from "@/lib/data";

export default function OrdersPage() {
  const [isMounted, setIsMounted] = useState(false);
  const [orders, setOrders] = useState<Order[]>([]);
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [currentUser, setCurrentUser] = useState<AdminUser | null>(null);
  
  const [searchTerm, setSearchTerm] = useState("");
  const [statusFilter, setStatusFilter] = useState("all");
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [notification, setNotification] = useState<{type: 'success' | 'error', message: string} | null>(null);

  const [formData, setFormData] = useState({
    customerId: "",
    productId: "",
    actualUnitPrice: 0,
    qty: 1,
    status: "pending",
    notes: ""
  });

  useEffect(() => {
    setIsMounted(true);
    const storedOrders = storage.getOrders();
    
    // Repair duplicate IDs if any exist in storage
    const seenIds = new Set();
    const repairedOrders = storedOrders.map(order => {
      let uniqueId = order.id;
      let counter = 1;
      while (seenIds.has(uniqueId)) {
        uniqueId = `${order.id.split('-')[0] || 'ORD'}-${Math.floor(Math.random() * 9000) + 1000}`;
      }
      seenIds.add(uniqueId);
      return { ...order, id: uniqueId };
    });

    if (JSON.stringify(repairedOrders) !== JSON.stringify(storedOrders)) {
      storage.saveOrders(repairedOrders);
    }

    setOrders(repairedOrders);
    setCustomers(storage.getCustomers());
    setProducts(storage.getProducts());
    setCurrentUser(storage.getProfile());
  }, []);

  useEffect(() => {
    if (notification) {
      const timer = setTimeout(() => setNotification(null), 3000);
      return () => clearTimeout(timer);
    }
  }, [notification]);

  if (!isMounted) return null;

  const saveOrders = (newOrders: any[]) => {
    setOrders(newOrders);
    storage.saveOrders(newOrders);
  };

  const handleStatusChange = (id: string, newStatus: string) => {
    const order = orders.find(o => o.id === id);
    if (!order) return;

    const canUpdateStatus = storage.canEditOrders(currentUser);
    if (!canUpdateStatus) {
      showNotification('error', 'Permission denied: You are not allowed to update order status.');
      return;
    }

    const oldStatus = order.status as OrderStatus;
    const targetStatus = newStatus as OrderStatus;

    if (oldStatus === targetStatus) return;

    const hasOverridePermission = storage.canOverrideOrderStatus(currentUser);

    // Normal transitions definition
    const normalTransitions: Record<OrderStatus, OrderStatus[]> = {
      pending: ['confirmed', 'cancelled'],
      confirmed: ['processing', 'cancelled'],
      processing: ['delivered', 'cancelled'],
      delivered: [],
      cancelled: [],
    };

    const isNormalTransition = (normalTransitions[oldStatus] || []).includes(targetStatus);
    
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

    // 7. Stock Safety
    const currentProducts = storage.getProducts();

    // Reopening cancelled order -> deduct stock again
    if (oldStatus === 'cancelled' && targetStatus !== 'cancelled') {
      let hasSufficientStock = true;
      const updatedProducts = currentProducts.map(p => {
        const item = order.items.find(i => i.productId === p.id);
        if (item) {
          if (p.stock < item.quantity) {
            hasSufficientStock = false;
          }
          return { ...p, stock: p.stock - item.quantity };
        }
        return p;
      });

      if (!hasSufficientStock) {
        showNotification('error', "Insufficient stock to reopen this order.");
        return;
      }

      storage.saveProducts(updatedProducts);
      setProducts(updatedProducts);
      order.items.forEach(item => {
        storage.addStockMovement({
          productId: item.productId,
          productName: item.productName,
          type: 'sale',
          quantityChange: -item.quantity,
          reason: `Order #${id} reopened override: ${reason}`,
          createdBy: currentUser?.id || 'system'
        });
      });
    } 
    // Cancelling order -> restore stock
    else if (oldStatus !== 'cancelled' && targetStatus === 'cancelled') {
      const updatedProducts = currentProducts.map(p => {
        const item = order.items.find(i => i.productId === p.id);
        if (item) {
          return { ...p, stock: p.stock + item.quantity };
        }
        return p;
      });

      storage.saveProducts(updatedProducts);
      setProducts(updatedProducts);
      order.items.forEach(item => {
        storage.addStockMovement({
          productId: item.productId,
          productName: item.productName,
          type: 'return',
          quantityChange: item.quantity,
          reason: `Order #${id} cancelled: ${reason}`,
          createdBy: currentUser?.id || 'system'
        });
      });
    }

    // 6. Audit & Save
    saveOrders(orders.map(o => o.id === id ? { ...o, status: targetStatus } : o));
    
    const severity = requiresOverride ? 'WARNING' : 'INFO';
    const auditMessage = requiresOverride 
      ? `OVERRIDE: Order #${id} status changed from ${oldStatus} to ${targetStatus}. Reason: ${reason}`
      : `Order #${id} status changed from ${oldStatus} to ${targetStatus}`;

    storage.logger.log('FINANCIAL', severity, auditMessage, {
      targetId: id,
      metadata: {
        oldValue: oldStatus,
        newValue: targetStatus,
        isOverride: requiresOverride,
        reason: reason || undefined,
        changedBy: currentUser?.name || 'system',
        userId: currentUser?.id,
        timestamp: new Date().toISOString(),
        source: 'Order Tracking'
      }
    });

    showNotification('success', `Order #${id} updated: ${oldStatus} → ${targetStatus}`);
  };

  const canCreateOrders = storage.canCreateOrders(currentUser);
  const canViewInventory = storage.canViewInventory(currentUser);
  const canEditOrders = storage.canEditOrders(currentUser);
  const canDeleteOrders = storage.canDeleteOrders(currentUser);

  const showNotification = (type: 'success' | 'error', message: string) => {
    setNotification({ type, message });
  };

  const handleCreateOrder = (e: React.FormEvent) => {
    e.preventDefault();
    if (!canCreateOrders) {
      showNotification('error', 'Permission denied: You are not allowed to create new orders.');
      return;
    }

    const customer = customers.find(c => c.id === formData.customerId);
    const product = products.find(p => p.id === formData.productId);
    
    if (!customer || !product) {
      showNotification('error', 'Please select both a customer and a product.');
      return;
    }

    const qty = Number(formData.qty);
    if (isNaN(qty) || qty <= 0) {
      showNotification('error', 'Quantity must be a valid number greater than 0.');
      return;
    }

    if (product.stock < qty) {
      showNotification('error', `Insufficient stock available! Only ${product.stock} units available.`);
      return;
    }

    const actualUnitPrice = Number(formData.actualUnitPrice);
    if (!Number.isFinite(actualUnitPrice) || actualUnitPrice < 0) {
      showNotification('error', 'Final selling price must be a valid number greater than or equal to 0.');
      return;
    }

    const historicalUnitCost = Number(product.costPrice) || 0;
    const total = actualUnitPrice * qty;
    const cost = historicalUnitCost * qty;
    const grossProfit = total - cost;

    const timestamp = Date.now().toString().slice(-4);
    const random = Math.floor(Math.random() * 900) + 100;
    const newOrder: Order & { customerName?: string, customerPhone?: string, totalAmount?: number } = {
      id: `ORD-${timestamp}${random}`,
      customer: customer.name,
      customerName: customer.name, // Alias for verbose matching
      customerId: customer.id,
      marketingOfficerId: customer.marketingOfficerId || customer.registeredBy,
      phone: customer.phone,
      customerPhone: customer.phone, // Alias for verbose matching
      items: [{
        productId: product.id,
        productName: product.name,
        quantity: qty,
        price: actualUnitPrice,
        costPrice: historicalUnitCost
      }],
      total: total,
      cost: cost,
      grossProfit: grossProfit,
      totalAmount: total, // Alias for verbose matching
      status: formData.status as any,
      paymentStatus: formData.status === 'paid' ? 'paid' : 'unpaid',
      date: new Date().toISOString().split('T')[0],
      deliveryNotes: formData.notes
    };

    // Update Inventory
    const updatedProducts = products.map(p => 
      p.id === product.id ? { ...p, stock: p.stock - qty } : p
    );
    storage.saveProducts(updatedProducts);
    setProducts(updatedProducts);

    // Record stock movement
    storage.addStockMovement({ productId: product.id, productName: product.name, type: 'sale', quantityChange: -qty, reason: `Order ${newOrder.id} created`, createdBy: currentUser?.id || 'system' });

    // Save Order
    const newOrders = [newOrder, ...orders];
    saveOrders(newOrders);
    storage.logger.log('FINANCIAL', 'INFO', `New order created: ${newOrder.id} for ${customer.name} ($${total})`, { targetId: newOrder.id, metadata: { total, grossProfit, qty, product: product.name, source: 'Order Tracking' } });
    
    setIsModalOpen(false);
    setFormData({ customerId: "", productId: "", actualUnitPrice: 0, qty: 1, status: "pending", notes: "" });
    showNotification('success', `Order ${newOrder.id} created successfully for ${customer.name}`);
  };

  const handleDelete = (id: string) => {
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

    if (confirm("Are you sure you want to delete this order? This will remove it from all records.")) {
      // Restore stock if the deleted order is not cancelled
      if (order.status.toLowerCase() !== 'cancelled') {
        const currentProducts = storage.getProducts();
        const updatedProducts = currentProducts.map(p => {
          const item = order.items.find(i => i.productId === p.id);
          if (item) {
            return { ...p, stock: p.stock + item.quantity };
          }
          return p;
        });
        storage.saveProducts(updatedProducts);
        setProducts(updatedProducts);
      }

      saveOrders(orders.filter(o => o.id !== id));
      storage.logger.log('FINANCIAL', 'WARNING', `Order deleted: ${id}`, { targetId: id });
      showNotification('success', 'Order deleted');
    }
  };

  const filteredOrders = orders.filter(order => {
    // Visibility Filtering
    if (storage.canViewOwnCustomersOnly(currentUser)) {
      const isOwner = currentUser ? String(order.marketingOfficerId) === String(currentUser.id) : false;
      if (!isOwner) return false;
    }

    const matchesSearch = 
      order.customer.toLowerCase().includes(searchTerm.toLowerCase()) || 
      order.id.toLowerCase().includes(searchTerm.toLowerCase());
    const matchesStatus = statusFilter === "all" || order.status === statusFilter;
    return matchesSearch && matchesStatus;
  }).sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime());

  const canChangeStatus = storage.canEditOrders(currentUser);

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

  const canViewStock = storage.canViewInventory(currentUser);
  const selectedProduct = products.find(p => p.id === formData.productId);

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
          <Button variant="outline" size="sm" className="text-slate-500 border-slate-200 rounded-lg h-10 px-4 text-xs">
            <Calendar className="h-4 w-4 mr-1.5" /> Export History
          </Button>
          {storage.canCreateOrders(currentUser) && (
            <Button onClick={() => setIsModalOpen(true)} className="bg-slate-900 text-white rounded-lg h-10 px-4 text-xs shadow-lg shadow-slate-200">
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
                            <p className="text-slate-500 text-[10px] mt-0.5 font-medium italic">Qty: {item.quantity} · Unit: ${item.price.toFixed(2)}</p>
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
                          {storage.canDeleteOrders(currentUser) && (
                            <Button onClick={() => handleDelete(order.id)} variant="ghost" size="sm" className="h-7 w-7 p-0 text-slate-400 hover:text-red-600 hover:bg-red-50 rounded-md">
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
                          if (storage.canViewOwnCustomersOnly(currentUser)) {
                            return currentUser ? String(c.marketingOfficerId || c.registeredBy) === String(currentUser.id) : false;
                          }
                          return true;
                        })
                        .map(c => <option key={c.id} value={c.id}>{c.name} ({c.phone})</option>)
                      }
                    </select>
                  </div>
 
                  <div className="space-y-1">
                    <label className="text-[10px] font-bold text-slate-700 ml-1 flex items-center gap-2">
                      <Package className="h-3 w-3 text-slate-400" /> Select Product
                    </label>
                    <select 
                      required
                      className="w-full h-9 rounded-lg border border-slate-200 bg-slate-50 px-3 text-xs font-medium outline-none focus:ring-2 focus:ring-brand-blue/20 transition-all cursor-pointer"
                      value={formData.productId}
                      onChange={e => {
                        const product = products.find(p => p.id === e.target.value);
                        setFormData({
                          ...formData,
                          productId: e.target.value,
                          actualUnitPrice: product?.sellingPrice || product?.price || 0
                        });
                      }}
                    >
                      <option value="">-- Choose product --</option>
                      {products.map(p => {
                        const stockText = canViewStock ? ` - ${p.stock} in stock` : "";
                        return <option key={p.id} value={p.id}>{p.name} (${p.sellingPrice || p.price}${stockText})</option>;
                      })}
                    </select>
                  </div>

                  <div className="grid grid-cols-2 gap-3">
                    <div className="space-y-1">
                      <label className="text-[10px] font-bold text-slate-700 ml-1">Final Selling Price</label>
                      <Input
                        type="number"
                        min="0"
                        step="0.01"
                        required
                        value={formData.actualUnitPrice}
                        onChange={e => setFormData({...formData, actualUnitPrice: parseFloat(e.target.value) || 0})}
                        className="h-9 rounded-lg bg-slate-50 border-slate-200 text-xs"
                      />
                    </div>
                    <div className="space-y-1">
                      <label className="text-[10px] font-bold text-slate-700 ml-1">Quantity</label>
                      <Input 
                        type="number" 
                        min="1" 
                        required 
                        value={formData.qty} 
                        onChange={e => setFormData({...formData, qty: parseInt(e.target.value) || 1})}
                        className="h-9 rounded-lg bg-slate-50 border-slate-200 text-xs" 
                      />
                    </div>
                    <div className="space-y-1">
                      <label className="text-[10px] font-bold text-slate-700 ml-1">Status</label>
                      <select 
                        className="w-full h-9 rounded-lg border border-slate-200 bg-slate-50 px-3 text-xs font-medium outline-none focus:ring-2 focus:ring-brand-blue/20 transition-all"
                        value={formData.status}
                        onChange={e => setFormData({...formData, status: e.target.value})}
                      >
                        <option value="pending">Pending</option>
                        <option value="confirmed">Confirmed</option>
                      </select>
                    </div>
                  </div>
                </div>

                <div className="space-y-4">
                  <div className="bg-slate-900 rounded-2xl p-4 text-slate-300 shadow-xl border border-slate-800">
                    <h3 className="text-[9px] font-bold text-slate-500 uppercase tracking-widest mb-3">Financial Summary</h3>
                    <div className="space-y-2">
                      <div className="flex justify-between text-[10px]">
                        <span className="text-slate-400">Standard Price</span>
                        <span className="font-bold text-white">${(selectedProduct?.sellingPrice || selectedProduct?.price || 0).toFixed(2)}</span>
                      </div>
                      <div className="flex justify-between text-[10px]">
                        <span className="text-slate-400">Final Unit Price</span>
                        <span className="font-bold text-white">${formData.actualUnitPrice.toFixed(2)}</span>
                      </div>
                      {canViewStock && (
                        <div className="flex justify-between text-[10px]">
                          <span className="text-slate-400">Estimated/Actual Cost</span>
                          <span className="font-bold text-slate-400">${((selectedProduct?.costPrice || 0) * formData.qty).toFixed(2)}</span>
                        </div>
                      )}
                      <div className="flex justify-between text-[10px]">
                        <span className="text-slate-400">Quantity</span>
                        <span className="font-bold text-white">{formData.qty}</span>
                      </div>
                      {canViewStock && (
                        <div className="flex justify-between text-[10px] border-t border-white/5 pt-2">
                          <span className="text-slate-400 font-bold uppercase tracking-tighter">Actual Gross Profit</span>
                          <span className="font-bold text-brand-blue">${((formData.actualUnitPrice - (selectedProduct?.costPrice || 0)) * formData.qty).toFixed(2)}</span>
                        </div>
                      )}
                      <div className="h-[1px] bg-slate-800 my-1" />
                      <div className="flex justify-between text-sm">
                        <span className="font-bold text-white uppercase text-[10px] tracking-widest">Actual Revenue</span>
                        <span className="font-bold text-brand-green">${(formData.actualUnitPrice * formData.qty).toFixed(2)}</span>
                      </div>
                    </div>
                    {selectedProduct && formData.actualUnitPrice < (selectedProduct.costPrice || 0) && (
                      <div className="mt-3 p-2 bg-amber-500/10 border border-amber-500/20 rounded-lg text-amber-300 text-[9px] leading-tight">
                        Warning: Final selling price is below product cost.
                      </div>
                    )}
                    {selectedProduct && selectedProduct.stock < formData.qty && (
                      <div className="mt-3 p-2 bg-red-500/10 border border-red-500/20 rounded-lg flex items-start gap-1.5 text-red-400 text-[9px] leading-tight">
                        <AlertCircle className="h-3 w-3 shrink-0" />
                        <span>Insufficient stock: {selectedProduct.stock} left.</span>
                      </div>
                    )}
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
                <Button type="submit" className="flex-1 bg-slate-900 text-white h-11 rounded-xl font-bold text-sm hover:bg-slate-800 shadow-lg shadow-slate-200 transition-all">
                  Confirm Order
                </Button>
                <Button type="button" variant="outline" onClick={() => setIsModalOpen(false)} className="px-8 h-11 rounded-xl font-bold text-xs text-slate-400 hover:bg-slate-50 border-slate-200">
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
