"use client";

import { useState, useEffect } from "react";
import { 
  UserCheck, 
  Plus, 
  Search, 
  Phone, 
  Mail, 
  Calendar, 
  DollarSign, 
  TrendingUp, 
  ShoppingBag,
  Award,
  CheckCircle2,
  Clock,
  ChevronRight,
  Filter,
  UserPlus,
  X,
  Pencil,
  Trash2,
  Eye,
  Archive,
  ShieldAlert
} from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { cn } from "@/lib/utils";
import { storage, AdminUser, Customer, Order } from "@/lib/storage";
import { getOrderCollectionSummary, getOrderPaymentStatus } from "@/lib/financial";

export default function CustomersPage() {
  const [isMounted, setIsMounted] = useState(false);
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [orders, setOrders] = useState<Order[]>([]);
  const [profile, setProfile] = useState<AdminUser | null>(null);
  const [searchTerm, setSearchTerm] = useState("");
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [isEditMode, setIsEditMode] = useState(false);
  const [editingCustomerId, setEditingCustomerId] = useState<string | null>(null);
  const [selectedCustomerId, setSelectedCustomerId] = useState<string | null>(null);
  const [receivableFilter, setReceivableFilter] = useState<'all' | 'unpaid' | 'partial' | 'paid'>('all');
  const [paymentModalOrderId, setPaymentModalOrderId] = useState<string | null>(null);
  const [paymentForm, setPaymentForm] = useState({
    amount: "",
    paymentDate: new Date().toISOString().slice(0, 10),
    paymentMethod: "Cash",
    reference: "",
    note: "",
  });
  const [notification, setNotification] = useState<{type: 'success' | 'error', message: string} | null>(null);
  
  const [formData, setFormData] = useState({
    name: "",
    email: "",
    phone: "",
    marketingOfficerId: "",
    notes: ""
  });

  useEffect(() => {
    setIsMounted(true);
    setCustomers(storage.getCustomers());
    setOrders(storage.getOrders());
    
    const updateProfile = () => setProfile(storage.getProfile());
    updateProfile();

    window.addEventListener('profileUpdated', updateProfile);
    return () => window.removeEventListener('profileUpdated', updateProfile);
  }, []);

  if (!isMounted || !profile) return null;

  const canAddCustomers = storage.canAddCustomers(profile);

  const showNotification = (type: 'success' | 'error', message: string) => {
    setNotification({ type, message });
  };

  const openCreateModal = () => {
    setIsEditMode(false);
    setEditingCustomerId(null);
    setFormData({ name: "", email: "", phone: "", marketingOfficerId: "", notes: "" });
    setIsModalOpen(true);
  };

  const openEditModal = (customer: Customer) => {
    setIsEditMode(true);
    setEditingCustomerId(customer.id);
    setFormData({
      name: customer.name,
      email: customer.email || "",
      phone: customer.phone || "",
      marketingOfficerId: customer.marketingOfficerId || customer.registeredBy || "",
      notes: customer.notes || ""
    });
    setIsModalOpen(true);
  };

  const handleRegister = (e: React.FormEvent) => {
    e.preventDefault();
    if (!canAddCustomers) {
      showNotification('error', 'Permission denied: You are not allowed to register new customers.');
      return;
    }
    if (isEditMode && editingCustomerId) {
      const updated = customers.map((customer) => {
        if (customer.id !== editingCustomerId) return customer;
        return {
          ...customer,
          name: formData.name.trim(),
          email: formData.email.trim(),
          phone: formData.phone.trim(),
          marketingOfficerId: profile.role === 'Marketing Officer' ? profile.id : (formData.marketingOfficerId || customer.marketingOfficerId || customer.registeredBy),
          notes: formData.notes.trim(),
        };
      });
      storage.saveCustomers(updated);
      setCustomers(updated);
      storage.logger.log('CUSTOMER', 'INFO', `Customer updated: ${formData.name.trim()}`, { targetId: editingCustomerId });
      showNotification('success', 'Customer updated successfully.');
      setIsModalOpen(false);
      setFormData({ name: "", email: "", phone: "", marketingOfficerId: "", notes: "" });
      setEditingCustomerId(null);
      setIsEditMode(false);
      return;
    }

    const newCustomer: Customer = {
      id: "cust-" + Date.now(),
      ...formData,
      name: formData.name.trim(),
      email: formData.email.trim(),
      phone: formData.phone.trim(),
      registeredBy: profile.id,
      marketingOfficerId: profile.role === 'Marketing Officer' ? profile.id : formData.marketingOfficerId,
      date: new Date().toISOString().split('T')[0],
      notes: formData.notes.trim(),
      status: 'active',
      isArchived: false,
    };
    const updated = [...customers, newCustomer];
    storage.saveCustomers(updated);
    storage.logger.log('CUSTOMER', 'INFO', `New customer registered: ${newCustomer.name}`, { targetId: newCustomer.id });
    setCustomers(updated);
    setIsModalOpen(false);
    setFormData({ name: "", email: "", phone: "", marketingOfficerId: "", notes: "" });
    showNotification('success', 'Customer created successfully.');
  };

  const handleDeleteCustomer = (customer: Customer) => {
    const customerOrders = orders.filter(o => o.customerId === customer.id || o.customer === customer.name || o.phone === customer.phone);

    if (customerOrders.length > 0) {
      const shouldArchive = window.confirm('This customer has historical orders and cannot be permanently deleted. Archive this customer instead?');
      if (!shouldArchive) return;
      const updated: Customer[] = customers.map(item => item.id === customer.id ? { ...item, isArchived: true, status: 'archived' } as Customer : item);
      storage.saveCustomers(updated);
      setCustomers(updated);
      storage.logger.log('CUSTOMER', 'WARNING', `Customer archived due to historical orders: ${customer.name}`, { targetId: customer.id });
      showNotification('success', 'Customer archived. Historical orders were preserved.');
      return;
    }

    const shouldDelete = window.confirm('Are you sure you want to delete this customer?');
    if (!shouldDelete) return;
    const updated = customers.filter(item => item.id !== customer.id);
    storage.saveCustomers(updated);
    setCustomers(updated);
    storage.logger.log('CUSTOMER', 'WARNING', `Customer deleted: ${customer.name}`, { targetId: customer.id });
    showNotification('success', 'Customer deleted.');
  };

  // Commission Calculations
  const myCustomers = customers.filter(c => c.registeredBy === profile.id);
  
  const myOrders = orders.filter(o => 
    o.marketingOfficerId === profile.id || 
    myCustomers.some(c => c.name === o.customer || c.phone === o.phone)
  );

  const ELIGIBLE_STATUSES = ['confirmed', 'processing', 'delivered'];
  const eligibleOrders = myOrders.filter(o => 
    o.commissionPaid || ELIGIBLE_STATUSES.includes(o.status?.toLowerCase())
  );
  
  const earnedCommissionTotal = eligibleOrders.reduce((sum, o) => sum + (o.total * profile.commissionPercentage / 100), 0);
  
  const paidCommission = profile.paidCommissionTotal || 0;
  const pendingPayout = Math.max(0, earnedCommissionTotal - paidCommission);
  
  const inProgressCommission = myOrders.filter(o => 
    !o.commissionPaid && o.status === 'pending'
  ).reduce((sum, o) => sum + (o.total * profile.commissionPercentage / 100), 0);
  const totalCommission = earnedCommissionTotal + inProgressCommission;

  const getCustomerFinancialSummaryData = (customer: Customer) => {
    const customerOrders = orders.filter(order =>
      order.customerId === customer.id ||
      order.customer === customer.name ||
      order.phone === customer.phone
    );

    const totalUnits = customerOrders.reduce((sum, order) => sum + order.items.reduce((itemSum, item) => itemSum + Number(item.quantity || 0), 0), 0);
    const revenueGenerated = customerOrders.reduce((sum, order) => sum + Number(order.total || 0), 0);
    const amountCollected = customerOrders.reduce((sum, order) => sum + Number(order.amountPaid ?? order.payments?.reduce((paymentSum, payment) => paymentSum + Number(payment.amount || 0), 0) ?? 0), 0);
    const outstandingBalance = Math.max(0, revenueGenerated - amountCollected);
    const paymentStatus = outstandingBalance <= 0 ? 'Paid' : amountCollected > 0 ? 'Partial' : 'Unpaid';

    return {
      customerOrders,
      totalOrders: customerOrders.length,
      totalUnits,
      revenueGenerated,
      amountCollected,
      outstandingBalance,
      paymentStatus,
    };
  };

  const recordPayment = (order: Order) => {
    const total = Number(order.total || 0);
    const collected = Number(order.amountPaid ?? order.payments?.reduce((sum, payment) => sum + Number(payment.amount || 0), 0) ?? 0);
    const outstanding = Math.max(0, total - collected);
    const amountValue = Number(paymentForm.amount);

    if (!paymentForm.amount || Number.isNaN(amountValue) || amountValue <= 0 || amountValue > outstanding) {
      showNotification('error', 'Payment amount must be greater than zero and cannot exceed the current outstanding balance.');
      return;
    }

    const nextOrder = storage.addPaymentToOrder(order, {
      amount: amountValue,
      paymentDate: paymentForm.paymentDate,
      paymentMethod: paymentForm.paymentMethod,
      reference: paymentForm.reference,
      note: paymentForm.note,
      recordedBy: profile?.name || 'System',
    });

    const updatedOrders = orders.map(item => item.id === nextOrder.id ? nextOrder : item);
    setOrders(updatedOrders);
    setPaymentForm({ amount: '', paymentDate: new Date().toISOString().slice(0, 10), paymentMethod: 'Cash', reference: '', note: '' });
    setPaymentModalOrderId(null);
    showNotification('success', 'Payment recorded successfully.');
  };

  const filteredCustomers = customers.filter(c => {
    if (storage.canViewOwnCustomersOnly(profile)) {
      if (String(c.marketingOfficerId || c.registeredBy) !== String(profile.id)) return false;
    }
    
    const matchesSearch = 
      c.name.toLowerCase().includes(searchTerm.toLowerCase()) || 
      c.phone.includes(searchTerm) ||
      c.email?.toLowerCase().includes(searchTerm.toLowerCase());
      
    return matchesSearch;
  });

  const selectedCustomer = selectedCustomerId ? customers.find(c => c.id === selectedCustomerId) ?? null : null;
  const selectedCustomerSummary = selectedCustomer ? getCustomerFinancialSummaryData(selectedCustomer) : null;

  const receivables = orders
    .map(order => {
      const customer = customers.find(c => c.id === order.customerId || c.name === order.customer || c.phone === order.phone) ?? null;
      const total = Number(order.total || 0);
      const collected = Number(order.amountPaid ?? order.payments?.reduce((sum, payment) => sum + Number(payment.amount || 0), 0) ?? 0);
      const outstanding = Math.max(0, total - collected);
      const paymentStatus = getOrderPaymentStatus(order);
      return { customer, order, total, collected, outstanding, paymentStatus };
    })
    .filter(row => row.outstanding > 0 || receivableFilter === 'all' || row.paymentStatus === receivableFilter)
    .filter(row => receivableFilter === 'all' ? true : row.paymentStatus === receivableFilter)
    .sort((a, b) => new Date(b.order.date).getTime() - new Date(a.order.date).getTime());

  const receivablesSummary = {
    totalRevenueGenerated: receivables.reduce((sum, row) => sum + row.total, 0),
    totalCollected: receivables.reduce((sum, row) => sum + row.collected, 0),
    totalOutstanding: receivables.reduce((sum, row) => sum + row.outstanding, 0),
  };

  return (
    <div className="space-y-8 animate-in fade-in duration-500">
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div>
          <h1 className="font-heading text-2xl font-bold text-slate-900 tracking-tight">Customer Database</h1>
          <p className="text-slate-400 mt-0.5 flex items-center gap-2 text-xs font-medium">
            <UserCheck className="h-3.5 w-3.5 text-brand-green" /> 
            Track registrations and monitor purchase-based commissions.
          </p>
        </div>
        {canAddCustomers && (
          <Button onClick={openCreateModal} className="bg-slate-900 text-white rounded-lg h-10 px-4 text-xs shadow-lg shadow-slate-200">
            <UserPlus className="h-4 w-4 mr-1.5" /> Register New Customer
          </Button>
        )}
      </div>

      {/* Commission Stats Dashboard (For Marketing Officers) */}
      {profile.role === 'Marketing Officer' && (
        <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
          <Card className="border-none shadow-lg shadow-blue-50 bg-brand-blue text-white overflow-hidden relative group">
            <div className="absolute top-0 right-0 p-3 opacity-10 group-hover:scale-110 transition-transform">
              <Award className="h-14 w-14" />
            </div>
            <CardContent className="p-4 relative z-10">
              <p className="text-[9px] font-bold uppercase tracking-[0.2em] opacity-70">Lifetime Commission</p>
              <h3 className="text-2xl font-bold mt-0.5">${totalCommission.toFixed(0)}</h3>
              <div className="mt-3 flex items-center gap-1.5 text-[9px] font-bold bg-white/10 w-fit px-2 py-0.5 rounded-full">
                <TrendingUp className="h-2.5 w-2.5" /> {profile.commissionPercentage}% Rate
              </div>
            </CardContent>
          </Card>
          
          <Card className="border-none shadow-sm bg-white ring-1 ring-green-100">
            <CardContent className="p-4">
              <p className="text-[9px] font-bold text-slate-400 uppercase tracking-widest mb-0.5">Available Payout</p>
              <h3 className="text-xl font-bold text-slate-900">${pendingPayout.toFixed(0)}</h3>
              <p className="text-[9px] text-green-600 font-bold mt-1.5 flex items-center gap-1">
                <CheckCircle2 className="h-2.5 w-2.5" /> Ready for withdrawal
              </p>
            </CardContent>
          </Card>
 
          <Card className="border-none shadow-sm bg-white">
            <CardContent className="p-4">
              <p className="text-[9px] font-bold text-slate-400 uppercase tracking-widest mb-0.5">Pending Orders</p>
              <h3 className="text-xl font-bold text-slate-900">${inProgressCommission.toFixed(0)}</h3>
              <p className="text-[9px] text-orange-600 font-bold mt-1.5 flex items-center gap-1">
                <Clock className="h-2.5 w-2.5" /> Waiting for fulfillment
              </p>
            </CardContent>
          </Card>
 
          <Card className="border-none shadow-sm bg-white">
            <CardContent className="p-4">
              <p className="text-[9px] font-bold text-slate-400 uppercase tracking-widest mb-0.5">Paid to Date</p>
              <h3 className="text-xl font-bold text-slate-900">${paidCommission.toFixed(0)}</h3>
              <p className="text-[9px] text-blue-600 font-bold mt-1.5 flex items-center gap-1">
                <DollarSign className="h-2.5 w-2.5" /> Successfully processed
              </p>
            </CardContent>
          </Card>
        </div>
      )}

      <Card className="border-none shadow-xl shadow-slate-100 overflow-hidden">
        <div className="p-4 border-b flex flex-col md:flex-row gap-3 items-center justify-between bg-white">
          <div className="relative w-full md:w-80">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-slate-400" />
            <Input 
              placeholder="Search by name or phone..." 
              className="pl-9 h-9 bg-slate-50 border-none rounded-lg text-xs"
              value={searchTerm}
              onChange={e => setSearchTerm(e.target.value)}
            />
          </div>
          <Button variant="outline" size="sm" className="rounded-lg border-slate-200 text-xs text-slate-500 h-9 px-4">
            <Filter className="h-3.5 w-3.5 mr-1.5" /> All Customers
          </Button>
        </div>
        <CardContent className="p-0">
          <div className="overflow-x-auto">
            <table className="w-full text-xs text-left">
              <thead className="text-[9px] text-slate-400 uppercase font-bold tracking-widest bg-slate-50/50 border-b border-slate-100">
                <tr>
                  <th className="px-6 py-3">Customer Identity</th>
                  <th className="px-6 py-3">Contact Details</th>
                  <th className="px-6 py-3">Managed By</th>
                  <th className="px-6 py-3 text-center">Orders</th>
                  <th className="px-6 py-3 text-right">Total Invested</th>
                  <th className="px-6 py-3 text-right">Last Purchase</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-50">
                {filteredCustomers.map((customer) => {
                  const regBy = storage.getUsers().find(u => u.id === customer.registeredBy);
                  const customerOrders = orders.filter(o => o.customerId === customer.id || o.customer === customer.name || o.phone === customer.phone);
                  const totalSpend = customerOrders.reduce((sum, o) => sum + o.total, 0);
                  const lastOrder = [...customerOrders].sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime())[0];
                  const lastOrderDate = lastOrder ? lastOrder.date : 'No Purchases';
                  const orderLabel = `${customerOrders.length} ${customerOrders.length === 1 ? 'order' : 'orders'}`;
                  
                  return (
                    <tr key={customer.id} className="hover:bg-slate-50/30 transition-colors group border-b border-slate-50 last:border-0">
                      <td className="px-6 py-3">
                        <div className="flex items-center gap-2.5">
                          <div className="h-8 w-8 rounded-full bg-slate-100 flex items-center justify-center text-slate-400 font-bold text-[10px]">
                            {customer.name.charAt(0)}
                          </div>
                          <div>
                            <p className="font-bold text-slate-900 group-hover:text-brand-blue transition-colors">{customer.name}</p>
                            <p className="text-[9px] text-slate-400 uppercase tracking-tighter">ID: {customer.id}</p>
                          </div>
                        </div>
                      </td>
                      <td className="px-6 py-3">
                        <div className="flex items-center gap-1.5 text-slate-600">
                          <Phone className="h-3 w-3 opacity-60" /> <span className="text-[11px] font-medium">{customer.phone}</span>
                        </div>
                        {customer.email && (
                          <div className="flex items-center gap-1.5 text-slate-400 mt-0.5">
                            <Mail className="h-2.5 w-2.5 opacity-60" /> <span className="text-[9px]">{customer.email}</span>
                          </div>
                        )}
                      </td>
                      <td className="px-6 py-3">
                        <div className="flex items-center gap-2">
                          <div className={cn(
                            "h-5 w-5 rounded bg-slate-100 flex items-center justify-center text-[9px] font-bold",
                            regBy?.id === profile.id ? "bg-brand-blue/10 text-brand-blue" : "text-slate-400"
                          )}>
                            {regBy?.name.charAt(0)}
                          </div>
                          <div>
                            <span className="text-[10px] font-bold text-slate-600">{regBy?.name || "System"}</span>
                            <p className="text-[8px] text-slate-400 flex items-center gap-1 mt-0.5">Reg: {customer.date}</p>
                          </div>
                        </div>
                      </td>
                      <td className="px-6 py-3 text-center">
                        <span className="inline-flex items-center gap-1 px-2 py-0.5 bg-slate-50 border border-slate-100 rounded text-[9px] font-bold text-slate-600">
                          {orderLabel}
                        </span>
                      </td>
                      <td className="px-6 py-3 text-right">
                        <span className="font-bold text-brand-green">${totalSpend.toFixed(0)}</span>
                      </td>
                      <td className="px-6 py-3 text-right">
                        <span className="text-[10px] font-bold text-slate-500">{lastOrderDate}</span>
                      </td>
                      <td className="px-6 py-3 text-right">
                        <div className="flex justify-end gap-2">
                          <button type="button" onClick={() => openEditModal(customer)} className="rounded-md border border-slate-200 bg-white p-1.5 text-slate-600 hover:bg-blue-50 hover:text-blue-600" title="Edit customer">
                            <Pencil className="h-3.5 w-3.5" />
                          </button>
                          <button type="button" onClick={() => handleDeleteCustomer(customer)} className="rounded-md border border-slate-200 bg-white p-1.5 text-slate-600 hover:bg-red-50 hover:text-red-600" title={customerOrders.length > 0 ? 'Archive customer' : 'Delete customer'}>
                            {customerOrders.length > 0 ? <Archive className="h-3.5 w-3.5" /> : <Trash2 className="h-3.5 w-3.5" />}
                          </button>
                        </div>
                      </td>
                    </tr>
                  );
                })}
                {filteredCustomers.length === 0 && (
                  <tr>
                    <td colSpan={5} className="px-8 py-20 text-center">
                      <div className="flex flex-col items-center gap-2 text-slate-400">
                        <UserCheck className="h-10 w-10 opacity-20" />
                        <p className="text-sm font-medium">No customers found</p>
                      </div>
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </CardContent>
      </Card>

      {selectedCustomer && selectedCustomerSummary && (
        <Card className="border-none shadow-xl shadow-slate-100 overflow-hidden">
          <div className="p-4 border-b bg-white flex flex-col md:flex-row md:items-center justify-between gap-3">
            <div>
              <h2 className="text-lg font-bold text-slate-900 tracking-tight">{selectedCustomer.name} — Financial View</h2>
              <p className="text-[10px] text-slate-400 uppercase tracking-widest">Customer → Orders → Payments</p>
            </div>
            <button type="button" onClick={() => setSelectedCustomerId(null)} className="rounded-lg border border-slate-200 bg-slate-50 px-3 py-1.5 text-[10px] font-bold uppercase text-slate-600">
              Close
            </button>
          </div>
          <CardContent className="p-4 space-y-6">
            <div className="grid grid-cols-1 md:grid-cols-5 gap-4">
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Total Orders</p>
                <h3 className="mt-2 text-2xl font-bold text-slate-900">{selectedCustomerSummary.totalOrders}</h3>
              </div>
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Total Units</p>
                <h3 className="mt-2 text-2xl font-bold text-slate-900">{selectedCustomerSummary.totalUnits}</h3>
              </div>
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Revenue</p>
                <h3 className="mt-2 text-2xl font-bold text-brand-green">${selectedCustomerSummary.revenueGenerated.toFixed(0)}</h3>
              </div>
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Collected</p>
                <h3 className="mt-2 text-2xl font-bold text-brand-blue">${selectedCustomerSummary.amountCollected.toFixed(0)}</h3>
              </div>
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Outstanding</p>
                <h3 className="mt-2 text-2xl font-bold text-slate-900">${selectedCustomerSummary.outstandingBalance.toFixed(0)}</h3>
              </div>
            </div>

            <div className="space-y-4">
              {selectedCustomerSummary.customerOrders.map(order => {
                const collected = Number(order.amountPaid ?? order.payments?.reduce((sum, payment) => sum + Number(payment.amount || 0), 0) ?? 0);
                const outstanding = Math.max(0, Number(order.total || 0) - collected);
                const paymentStatus = getOrderPaymentStatus(order);

                return (
                  <div key={order.id} className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
                    <div className="flex flex-col md:flex-row md:items-center md:justify-between gap-2 border-b border-slate-100 pb-3 mb-3">
                      <div>
                        <p className="text-[10px] font-bold uppercase tracking-widest text-slate-400">Order ID</p>
                        <h3 className="text-lg font-bold text-slate-900">{order.id}</h3>
                      </div>
                      <div className="flex items-center gap-2">
                        <span className="rounded-full bg-slate-100 px-2 py-1 text-[9px] font-bold uppercase text-slate-700">{order.orderType || 'regular'}</span>
                        <span className={cn(
                          "rounded-full px-2 py-1 text-[9px] font-bold uppercase",
                          paymentStatus === 'paid' ? 'bg-green-100 text-green-700' : paymentStatus === 'partial' ? 'bg-amber-100 text-amber-700' : 'bg-red-100 text-red-700'
                        )}>{paymentStatus}</span>
                      </div>
                    </div>

                    <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                      <div className="space-y-2">
                        <div className="flex justify-between text-[10px] text-slate-500">
                          <span>Order Date</span>
                          <span className="font-bold text-slate-900">{order.date}</span>
                        </div>
                        <div className="flex justify-between text-[10px] text-slate-500">
                          <span>Order Type</span>
                          <span className="font-bold text-slate-900 uppercase">{order.orderType || 'regular'}</span>
                        </div>
                        <div className="flex justify-between text-[10px] text-slate-500">
                          <span>Status</span>
                          <span className="font-bold text-slate-900 uppercase">{order.status}</span>
                        </div>
                        <div className="pt-2">
                          <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400 mb-2">Items</p>
                          <div className="space-y-2 text-[10px]">
                            {order.items.map((item, index) => (
                              <div key={`${order.id}-${item.productId}-${index}`} className="flex items-center justify-between border-b border-slate-100 pb-1 last:border-0">
                                <div>
                                  <p className="font-bold text-slate-900">{item.productName}</p>
                                  <p className="text-slate-500">Qty {item.quantity} × ${Number(item.actualUnitPrice ?? item.price ?? item.standardUnitPrice ?? 0).toFixed(2)}</p>
                                </div>
                                <span className="font-bold text-brand-green">${(Number(item.actualUnitPrice ?? item.price ?? item.standardUnitPrice ?? 0) * Number(item.quantity || 0)).toFixed(2)}</span>
                              </div>
                            ))}
                          </div>
                        </div>
                      </div>

                      <div className="space-y-2">
                        <div className="flex justify-between text-[10px] text-slate-500">
                          <span>Order Total</span>
                          <span className="font-bold text-slate-900">${Number(order.total || 0).toFixed(2)}</span>
                        </div>
                        <div className="flex justify-between text-[10px] text-slate-500">
                          <span>Amount Paid</span>
                          <span className="font-bold text-brand-blue">${collected.toFixed(2)}</span>
                        </div>
                        <div className="flex justify-between text-[10px] text-slate-500">
                          <span>Outstanding</span>
                          <span className="font-bold text-slate-900">${outstanding.toFixed(2)}</span>
                        </div>
                        <div className="flex justify-between text-[10px] text-slate-500">
                          <span>Gross Profit</span>
                          <span className="font-bold text-brand-green">${Number(order.grossProfit || 0).toFixed(2)}</span>
                        </div>
                        <div className="pt-2">
                          <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400 mb-2">Payments</p>
                          <div className="space-y-2 text-[10px]">
                            {(order.payments && order.payments.length > 0) ? order.payments.map(payment => (
                              <div key={payment.id} className="flex items-center justify-between border-b border-slate-100 pb-1 last:border-0">
                                <div>
                                  <p className="font-bold text-slate-900">{payment.paymentDate}</p>
                                  <p className="text-slate-500">{payment.paymentMethod || 'Cash'}</p>
                                </div>
                                <span className="font-bold text-brand-blue">${Number(payment.amount || 0).toFixed(2)}</span>
                              </div>
                            )) : (
                              <p className="text-slate-400">No payment history recorded.</p>
                            )}
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          </CardContent>
        </Card>
      )}

      <Card className="border-none shadow-xl shadow-slate-100 overflow-hidden">
        <div className="p-4 border-b bg-white flex flex-col md:flex-row md:items-center justify-between gap-3">
          <div>
            <h2 className="text-lg font-bold text-slate-900 tracking-tight">Outstanding / Receivables</h2>
            <p className="text-[10px] text-slate-400 uppercase tracking-widest">Revenue Generated vs Cash Collected</p>
          </div>
          <div className="flex gap-2">
            {(['all', 'unpaid', 'partial', 'paid'] as const).map(filter => (
              <button
                key={filter}
                type="button"
                onClick={() => setReceivableFilter(filter)}
                className={cn(
                  "h-8 rounded-lg px-3 text-[10px] font-bold uppercase tracking-wide",
                  receivableFilter === filter ? 'bg-slate-900 text-white' : 'bg-slate-100 text-slate-600'
                )}
              >
                {filter}
              </button>
            ))}
          </div>
        </div>
        <CardContent className="p-4">
          <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
              <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Total Revenue Generated</p>
              <h3 className="mt-2 text-2xl font-bold text-slate-900">${receivablesSummary.totalRevenueGenerated.toFixed(0)}</h3>
            </div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
              <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Total Collected</p>
              <h3 className="mt-2 text-2xl font-bold text-brand-blue">${receivablesSummary.totalCollected.toFixed(0)}</h3>
            </div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
              <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Total Outstanding</p>
              <h3 className="mt-2 text-2xl font-bold text-slate-900">${receivablesSummary.totalOutstanding.toFixed(0)}</h3>
            </div>
          </div>

          <div className="overflow-x-auto">
            <table className="w-full text-xs text-left">
              <thead className="bg-slate-50 text-[9px] uppercase tracking-widest text-slate-400">
                <tr>
                  <th className="px-4 py-3">Customer</th>
                  <th className="px-4 py-3">Order</th>
                  <th className="px-4 py-3">Order Date</th>
                  <th className="px-4 py-3 text-right">Order Total</th>
                  <th className="px-4 py-3 text-right">Amount Collected</th>
                  <th className="px-4 py-3 text-right">Outstanding</th>
                  <th className="px-4 py-3 text-center">Status</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {receivables.map(({ customer, order, total, collected, outstanding, paymentStatus }) => (
                  <tr key={order.id} className="hover:bg-slate-50/80">
                    <td className="px-4 py-3 font-bold text-slate-900">{customer?.name ?? order.customer}</td>
                    <td className="px-4 py-3">{order.id}</td>
                    <td className="px-4 py-3 text-slate-600">{order.date}</td>
                    <td className="px-4 py-3 text-right font-bold text-slate-900">${total.toFixed(0)}</td>
                    <td className="px-4 py-3 text-right font-bold text-brand-blue">${collected.toFixed(0)}</td>
                    <td className="px-4 py-3 text-right font-bold text-slate-900">${outstanding.toFixed(0)}</td>
                    <td className="px-4 py-3 text-center">
                      <span className={cn(
                        "inline-flex rounded-full px-2 py-1 text-[9px] font-bold uppercase",
                        paymentStatus === 'paid' ? 'bg-green-100 text-green-700' : paymentStatus === 'partial' ? 'bg-amber-100 text-amber-700' : 'bg-red-100 text-red-700'
                      )}>{paymentStatus}</span>
                    </td>
                    <td className="px-4 py-3 text-right">
                      <button type="button" onClick={() => setPaymentModalOrderId(order.id)} className="rounded-md border border-slate-200 bg-white px-2 py-1.5 text-[9px] font-bold uppercase tracking-wide text-slate-700 hover:bg-blue-50 hover:text-blue-700">
                        Record Payment
                      </button>
                    </td>
                  </tr>
                ))}
                {receivables.length === 0 && (
                  <tr>
                    <td colSpan={7} className="px-4 py-10 text-center text-slate-400">No receivables match this filter.</td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </CardContent>
      </Card>

      {paymentModalOrderId && (() => {
        const order = orders.find(item => item.id === paymentModalOrderId);
        if (!order) return null;
        const total = Number(order.total || 0);
        const collected = Number(order.amountPaid ?? order.payments?.reduce((sum, payment) => sum + Number(payment.amount || 0), 0) ?? 0);
        const outstanding = Math.max(0, total - collected);

        return (
          <div className="fixed inset-0 z-[120] bg-slate-900/60 flex items-center justify-center p-4">
            <div className="bg-white rounded-2xl shadow-2xl w-full max-w-xl p-6">
              <div className="flex items-center justify-between mb-4">
                <div>
                  <p className="text-[10px] font-bold uppercase tracking-widest text-slate-400">Record payment</p>
                  <h3 className="text-xl font-bold text-slate-900">{order.customer}</h3>
                </div>
                <button type="button" onClick={() => setPaymentModalOrderId(null)} className="rounded-full border border-slate-200 p-2 text-slate-500">
                  <X className="h-4 w-4" />
                </button>
              </div>

              <div className="grid grid-cols-2 gap-3 text-xs text-slate-600 mb-4">
                <div className="rounded-xl bg-slate-50 p-3"><span className="block text-[9px] uppercase tracking-widest text-slate-400">Order ID</span><strong className="text-slate-900">{order.id}</strong></div>
                <div className="rounded-xl bg-slate-50 p-3"><span className="block text-[9px] uppercase tracking-widest text-slate-400">Order Type</span><strong className="text-slate-900 uppercase">{order.orderType || 'regular'}</strong></div>
                <div className="rounded-xl bg-slate-50 p-3"><span className="block text-[9px] uppercase tracking-widest text-slate-400">Order Total</span><strong className="text-slate-900">${total.toFixed(2)}</strong></div>
                <div className="rounded-xl bg-slate-50 p-3"><span className="block text-[9px] uppercase tracking-widest text-slate-400">Outstanding</span><strong className="text-slate-900">${outstanding.toFixed(2)}</strong></div>
              </div>

              <div className="space-y-3">
                <div>
                  <label className="text-[10px] font-bold uppercase tracking-widest text-slate-600">Payment Amount</label>
                  <Input value={paymentForm.amount} onChange={e => setPaymentForm({ ...paymentForm, amount: e.target.value })} type="number" min="0" step="0.01" placeholder="0.00" className="h-11 rounded-xl" />
                </div>
                <div className="grid grid-cols-2 gap-3">
                  <div>
                    <label className="text-[10px] font-bold uppercase tracking-widest text-slate-600">Payment Date</label>
                    <Input value={paymentForm.paymentDate} onChange={e => setPaymentForm({ ...paymentForm, paymentDate: e.target.value })} type="date" className="h-11 rounded-xl" />
                  </div>
                  <div>
                    <label className="text-[10px] font-bold uppercase tracking-widest text-slate-600">Payment Method</label>
                    <select value={paymentForm.paymentMethod} onChange={e => setPaymentForm({ ...paymentForm, paymentMethod: e.target.value })} className="h-11 w-full rounded-xl border border-slate-200 bg-slate-50 px-3 text-sm">
                      <option>Cash</option>
                      <option>EVC</option>
                      <option>eDahab</option>
                      <option>Bank</option>
                    </select>
                  </div>
                </div>
                <div>
                  <label className="text-[10px] font-bold uppercase tracking-widest text-slate-600">Reference / Note</label>
                  <Input value={paymentForm.reference} onChange={e => setPaymentForm({ ...paymentForm, reference: e.target.value })} placeholder="INV-001" className="h-11 rounded-xl" />
                </div>
                <div>
                  <label className="text-[10px] font-bold uppercase tracking-widest text-slate-600">Note</label>
                  <Input value={paymentForm.note} onChange={e => setPaymentForm({ ...paymentForm, note: e.target.value })} placeholder="Optional note" className="h-11 rounded-xl" />
                </div>
              </div>

              <div className="mt-6 flex gap-3">
                <Button type="button" variant="outline" onClick={() => setPaymentModalOrderId(null)} className="flex-1 h-11 rounded-xl">Cancel</Button>
                <Button type="button" onClick={() => recordPayment(order)} className="flex-1 h-11 rounded-xl bg-slate-900 text-white">Record Payment</Button>
              </div>
            </div>
          </div>
        );
      })()}

      {notification && (
        <div className="fixed bottom-6 right-6 z-[130] rounded-xl border border-slate-200 bg-white px-4 py-3 text-xs font-semibold shadow-lg">
          <span className={notification.type === 'error' ? 'text-red-600' : 'text-green-600'}>{notification.message}</span>
        </div>
      )}

      {/* Registration Modal */}
      {isModalOpen && (
        <div className="fixed inset-0 z-[100] bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-[2rem] shadow-2xl w-full max-w-lg animate-in zoom-in duration-300 overflow-hidden">
            <div className="p-8 border-b flex justify-between items-center bg-white shrink-0">
              <div className="flex items-center gap-4">
                <div className="h-12 w-12 bg-green-50 rounded-2xl flex items-center justify-center text-brand-green shadow-inner">
                  <UserPlus className="h-6 w-6" />
                </div>
                <div>
                  <h2 className="text-xl font-bold text-slate-900 tracking-tight">{isEditMode ? 'Edit Customer' : 'Register Customer'}</h2>
                  <p className="text-slate-500 text-xs font-medium">{isEditMode ? 'Update customer details without changing historical transactions.' : 'Add to your managed database.'}</p>
                </div>
              </div>
              <button onClick={() => setIsModalOpen(false)} className="h-8 w-8 hover:bg-slate-100 rounded-full transition-colors flex items-center justify-center border border-slate-100">
                <X className="h-4 w-4 text-slate-400" />
              </button>
            </div>

            <form onSubmit={handleRegister} className="p-8 space-y-6">
              <div className="space-y-4">
                <div className="space-y-1.5">
                  <label className="text-xs font-bold text-slate-700 ml-1">Full Name</label>
                  <Input required value={formData.name} onChange={e => setFormData({...formData, name: e.target.value})} className="h-12 rounded-xl" placeholder="e.g., Mohamed Hassan" />
                </div>
                <div className="space-y-1.5">
                  <label className="text-xs font-bold text-slate-700 ml-1">Phone Number</label>
                  <Input required value={formData.phone} onChange={e => setFormData({...formData, phone: e.target.value})} className="h-12 rounded-xl" placeholder="+252 61..." />
                </div>
                <div className="space-y-1.5">
                  <label className="text-xs font-bold text-slate-700 ml-1">Email Address (Optional)</label>
                  <Input type="email" value={formData.email} onChange={e => setFormData({...formData, email: e.target.value})} className="h-12 rounded-xl" placeholder="customer@example.com" />
                </div>
                <div className="space-y-1.5">
                  <label className="text-xs font-bold text-slate-700 ml-1">Customer Notes</label>
                  <textarea value={formData.notes} onChange={e => setFormData({...formData, notes: e.target.value})} className="w-full min-h-[96px] rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-xs outline-none focus:ring-2 focus:ring-brand-blue/20 transition-all" placeholder="Optional notes or details" />
                </div>
                {profile.role === 'Super Admin' && (
                  <div className="space-y-1.5">
                    <label className="text-xs font-bold text-slate-700 ml-1">Assign Marketing Officer</label>
                    <select 
                      value={formData.marketingOfficerId} 
                      onChange={e => setFormData({...formData, marketingOfficerId: e.target.value})}
                      className="w-full h-12 rounded-xl border border-slate-200 px-4 text-sm bg-white focus:ring-2 focus:ring-brand-blue/20 outline-none"
                    >
                      <option value="">No Marketing Officer</option>
                      {storage.getUsers().filter(u => u.role === 'Marketing Officer').map(u => (
                        <option key={u.id} value={u.id}>{u.name}</option>
                      ))}
                    </select>
                  </div>
                )}
              </div>

              <div className="pt-4 flex gap-3">
                <Button type="submit" className="flex-1 bg-slate-900 text-white h-12 rounded-xl font-bold">
                  {isEditMode ? 'Save Changes' : 'Confirm Registration'}
                </Button>
                <Button type="button" variant="outline" onClick={() => { setIsModalOpen(false); setIsEditMode(false); setEditingCustomerId(null); setFormData({ name: "", email: "", phone: "", marketingOfficerId: "", notes: "" }); }} className="flex-1 h-12 rounded-xl">
                  Discard
                </Button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
}
