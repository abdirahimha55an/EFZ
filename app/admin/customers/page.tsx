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
  X
} from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { cn } from "@/lib/utils";
import { storage, AdminUser, Customer, Order } from "@/lib/storage";

export default function CustomersPage() {
  const [isMounted, setIsMounted] = useState(false);
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [orders, setOrders] = useState<Order[]>([]);
  const [profile, setProfile] = useState<AdminUser | null>(null);
  const [searchTerm, setSearchTerm] = useState("");
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [notification, setNotification] = useState<{type: 'success' | 'error', message: string} | null>(null);
  
  const [formData, setFormData] = useState({
    name: "",
    email: "",
    phone: "",
    marketingOfficerId: ""
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

  const handleRegister = (e: React.FormEvent) => {
    e.preventDefault();
    if (!canAddCustomers) {
      showNotification('error', 'Permission denied: You are not allowed to register new customers.');
      return;
    }
    console.log(`[CUSTOMER] Registering new customer. Active Admin: ${profile.name} (${profile.id})`);
    const newCustomer: Customer = {
      id: "cust-" + Date.now(),
      ...formData,
      registeredBy: profile.id,
      marketingOfficerId: profile.role === 'Marketing Officer' ? profile.id : formData.marketingOfficerId,
      date: new Date().toISOString().split('T')[0]
    };
    console.log(`[CUSTOMER] Data saved with registeredBy: ${newCustomer.registeredBy}`);
    const updated = [...customers, newCustomer];
    storage.saveCustomers(updated);
    storage.logger.log('CUSTOMER', 'INFO', `New customer registered: ${newCustomer.name}`, { targetId: newCustomer.id });
    setCustomers(updated);
    setIsModalOpen(false);
    setFormData({ name: "", email: "", phone: "", marketingOfficerId: "" });
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

  const filteredCustomers = customers.filter(c => {
    // Permission-based filtering
    if (storage.canViewOwnCustomersOnly(profile)) {
      if (String(c.marketingOfficerId || c.registeredBy) !== String(profile.id)) return false;
    }
    
    // Search filtering
    const matchesSearch = 
      c.name.toLowerCase().includes(searchTerm.toLowerCase()) || 
      c.phone.includes(searchTerm) ||
      c.email?.toLowerCase().includes(searchTerm.toLowerCase());
      
    return matchesSearch;
  });

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
          <Button onClick={() => setIsModalOpen(true)} className="bg-slate-900 text-white rounded-lg h-10 px-4 text-xs shadow-lg shadow-slate-200">
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
                          {customerOrders.length}
                        </span>
                      </td>
                      <td className="px-6 py-3 text-right">
                        <span className="font-bold text-brand-green">${totalSpend.toFixed(0)}</span>
                      </td>
                      <td className="px-6 py-3 text-right">
                        <span className="text-[10px] font-bold text-slate-500">{lastOrderDate}</span>
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
                  <h2 className="text-xl font-bold text-slate-900 tracking-tight">Register Customer</h2>
                  <p className="text-slate-500 text-xs font-medium">Add to your managed database.</p>
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
                  Confirm Registration
                </Button>
                <Button type="button" variant="outline" onClick={() => setIsModalOpen(false)} className="flex-1 h-12 rounded-xl">
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
