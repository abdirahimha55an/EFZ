"use client";

import { useState, useEffect } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { 
  ShoppingBag, 
  Package, 
  TrendingUp, 
  AlertCircle, 
  DollarSign, 
  CheckCircle2, 
  Clock, 
  Ban, 
  Users, 
  Activity, 
  BarChart3, 
  Star,
  Layers,
  Sparkles
} from "lucide-react";
import { Product } from "@/lib/data";
import { storage, AdminUser, Order, Customer } from "@/lib/storage";
import { cn } from "@/lib/utils";

export default function AdminDashboard() {
  const [isMounted, setIsMounted] = useState(false);
  const [products, setProducts] = useState<Product[]>([]);
  const [orders, setOrders] = useState<Order[]>([]);
  const [profile, setProfile] = useState<AdminUser | null>(null);
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [users, setUsers] = useState<AdminUser[]>([]);

  useEffect(() => {
    setIsMounted(true);
    setProducts(storage.getProducts());
    setOrders(storage.getOrders());
    setCustomers(storage.getCustomers());
    setUsers(storage.getUsers());
    setProfile(storage.getProfile());
  }, []);

  if (!isMounted || !profile) return null;

  // Filter orders based on permissions
  const filteredOrders = orders.filter(o => {
    if (storage.canViewOwnCustomersOnly(profile)) {
      return String(o.marketingOfficerId) === String(profile.id);
    }
    return true;
  });

  // Calculate 12 detailed metrics

  // 1. Total Revenue (realized sales: paid/delivered orders)
  const totalRevenue = filteredOrders
    .filter(o => o.status === 'delivered' || o.paymentStatus === 'paid')
    .reduce((sum, o) => sum + o.total, 0);

  // 2. Total Profit (paid/delivered orders profit)
  const totalProfit = filteredOrders
    .filter(o => o.status === 'delivered' || o.paymentStatus === 'paid')
    .reduce((sum, o) => sum + (o.grossProfit !== undefined ? o.grossProfit : (o.total - (o.cost || 0))), 0);

  // 3. Pending Payouts (sum of pending commissions for all Marketing Officers)
  const pendingPayouts = users.reduce((sum, u) => {
    if (u.role !== 'Marketing Officer') return sum;
    // Calculate pending payouts based on eligible unpaid orders
    const myCustomers = customers.filter(c => String(c.marketingOfficerId || c.registeredBy) === String(u.id));
    const officerOrders = orders.filter(o => 
      String(o.marketingOfficerId) === String(u.id) || 
      myCustomers.some(c => String(c.id) === String(o.customerId) || c.name === o.customer)
    );
    const ELIGIBLE_STATUSES = ['confirmed', 'processing', 'delivered'];
    const eligibleOrders = officerOrders.filter(o => 
      !o.commissionPaid && ELIGIBLE_STATUSES.includes(o.status?.toLowerCase())
    );
    const amount = eligibleOrders.reduce((total, o) => total + (o.total * u.commissionPercentage / 100), 0);
    return sum + amount;
  }, 0);

  // 4. Inventory Value (cost price of all items in stock)
  const inventoryValue = products.reduce((sum, p) => sum + ((p.stock || 0) * (p.costPrice || 0)), 0);

  // 5. Monthly Sales (total value of orders from the current month)
  const currentMonth = new Date().toISOString().slice(0, 7); // "YYYY-MM"
  const monthlySales = filteredOrders
    .filter(o => o.date?.startsWith(currentMonth))
    .reduce((sum, o) => sum + o.total, 0);

  // 6. Active System Issues
  const activeIssues = storage.canViewDiagnostics(profile) ? storage.getSystemIssues().length : 0;

  // 7. Low Stock Products count
  const lowStockCount = products.filter(p => (p.stock || 0) > 0 && (p.stock || 0) <= (p.lowStockThreshold || 50)).length;

  // 8. Out of Stock count
  const outOfStockCount = products.filter(p => (p.stock || 0) === 0).length;

  // 9. Total Customers
  const totalCustomers = customers.filter(c => {
    if (storage.canViewOwnCustomersOnly(profile)) {
      return String(c.marketingOfficerId || c.registeredBy) === String(profile.id);
    }
    return true;
  }).length;

  // Compute product sales mapping for top sellers
  const productSalesMap: Record<string, { name: string; quantity: number; revenue: number }> = {};
  filteredOrders.forEach(o => {
    if (o.status === 'cancelled') return;
    
    if (o.items && o.items.length > 0) {
      o.items.forEach(item => {
        if (!productSalesMap[item.productId]) {
          productSalesMap[item.productId] = { 
            name: item.productName || 'Unknown Product', 
            quantity: 0, 
            revenue: 0 
          };
        }
        productSalesMap[item.productId].quantity += (item.quantity || 0);
        productSalesMap[item.productId].revenue += (item.quantity * item.price);
      });
    } else if (o.product) {
      // Fallback for flat structure
      const mockId = products.find(p => p.name === o.product)?.id || 'unknown';
      if (!productSalesMap[mockId]) {
        productSalesMap[mockId] = { 
          name: o.product, 
          quantity: 0, 
          revenue: 0 
        };
      }
      productSalesMap[mockId].quantity += (o.qty || 1);
      productSalesMap[mockId].revenue += o.total;
    }
  });

  // 10. Top Selling Product (single)
  const topSellingProductEntry = Object.values(productSalesMap).sort((a, b) => b.quantity - a.quantity)[0];
  const topSellingProduct = topSellingProductEntry 
    ? `${topSellingProductEntry.name} (${topSellingProductEntry.quantity} sold)` 
    : 'No Sales Yet';

  // Compute customer spends
  const customerSpendMap: Record<string, { name: string; phone: string; spend: number; orderCount: number }> = {};
  filteredOrders.forEach(o => {
    if (o.status === 'cancelled') return;
    const key = o.customerId || o.customer;
    if (!customerSpendMap[key]) {
      customerSpendMap[key] = { 
        name: o.customer, 
        phone: o.phone || 'N/A', 
        spend: 0, 
        orderCount: 0 
      };
    }
    customerSpendMap[key].spend += o.total;
    customerSpendMap[key].orderCount += 1;
  });

  // 11. Top Customer (single)
  const topCustomerEntry = Object.values(customerSpendMap).sort((a, b) => b.spend - a.spend)[0];
  const topCustomer = topCustomerEntry 
    ? `${topCustomerEntry.name} ($${topCustomerEntry.spend.toFixed(0)})` 
    : 'No Customers Yet';

  // 12. Total Orders count
  const totalOrdersCount = filteredOrders.length;

  // List of top 5 products by quantity sold
  const topProductsList = Object.entries(productSalesMap)
    .map(([id, data]) => ({ id, ...data }))
    .sort((a, b) => b.quantity - a.quantity)
    .slice(0, 5);

  // List of top 5 customers by total spend
  const topCustomersList = Object.values(customerSpendMap)
    .sort((a, b) => b.spend - a.spend)
    .slice(0, 5);

  // Stats cards configuration
  const statCards = [
    { title: "Realized Revenue", value: `$${totalRevenue.toLocaleString(undefined, { maximumFractionDigits: 0 })}`, icon: DollarSign, color: "text-emerald-600", bg: "bg-emerald-50" },
    { title: "Net Realized Profit", value: `$${totalProfit.toLocaleString(undefined, { maximumFractionDigits: 0 })}`, icon: TrendingUp, color: "text-blue-600", bg: "bg-blue-50" },
    { title: "Pending Payouts", value: `$${pendingPayouts.toLocaleString(undefined, { maximumFractionDigits: 0 })}`, icon: Clock, color: "text-orange-600", bg: "bg-orange-50" },
    { title: "Inventory Value", value: `$${inventoryValue.toLocaleString(undefined, { maximumFractionDigits: 0 })}`, icon: Layers, color: "text-indigo-600", bg: "bg-indigo-50" },
    { title: "Monthly Sales Volume", value: `$${monthlySales.toLocaleString(undefined, { maximumFractionDigits: 0 })}`, icon: BarChart3, color: "text-purple-600", bg: "bg-purple-50" },
    { title: "Active System Issues", value: activeIssues, icon: Activity, color: activeIssues > 0 ? "text-red-600 animate-pulse" : "text-slate-500", bg: activeIssues > 0 ? "bg-red-50" : "bg-slate-50" },
    { title: "Low Stock Products", value: lowStockCount, icon: AlertCircle, color: lowStockCount > 0 ? "text-amber-600" : "text-slate-500", bg: lowStockCount > 0 ? "bg-amber-50" : "bg-slate-50" },
    { title: "Out of Stock Products", value: outOfStockCount, icon: Ban, color: outOfStockCount > 0 ? "text-red-600" : "text-slate-500", bg: outOfStockCount > 0 ? "bg-red-50" : "bg-slate-50" },
    { title: "Active Accounts", value: totalCustomers, icon: Users, color: "text-cyan-600", bg: "bg-cyan-50" },
    { title: "Top Selling Product", value: topSellingProduct, icon: Star, color: "text-teal-600", bg: "bg-teal-50", isString: true },
    { title: "Top Spending Customer", value: topCustomer, icon: Sparkles, color: "text-violet-600", bg: "bg-violet-50", isString: true },
    { title: "Total Booked Orders", value: totalOrdersCount, icon: ShoppingBag, color: "text-slate-600", bg: "bg-slate-50" }
  ];

  return (
    <div className="space-y-10 animate-in fade-in duration-500">
      <div>
        <h1 className="font-heading text-2xl font-bold text-slate-900 tracking-tight">Executive Dashboard</h1>
        <p className="text-slate-500 text-xs mt-0.5">Comprehensive real-time insight into sales, fulfillment, stock, and agent networks.</p>
      </div>

      {/* Grid of 12 Metrics */}
      <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
        {statCards.map((stat, i) => (
          <Card key={i} className="border-none shadow-sm hover:shadow-md transition-all group overflow-hidden bg-white">
            <CardContent className="p-4">
              <div className="flex items-center justify-between gap-3">
                <div className="min-w-0 flex-1">
                  <p className="text-[9px] font-bold text-slate-400 uppercase tracking-widest mb-0.5 truncate">{stat.title}</p>
                  <h3 className={cn(
                    "font-bold text-slate-900 truncate",
                    stat.isString ? "text-xs font-semibold text-slate-700 leading-tight mt-1" : "text-lg md:text-xl"
                  )}>
                    {stat.value}
                  </h3>
                </div>
                <div className={`h-9 w-9 rounded-xl flex items-center justify-center shrink-0 transition-transform group-hover:scale-110 ${stat.bg} ${stat.color}`}>
                  <stat.icon className="h-4.5 w-4.5" />
                </div>
              </div>
            </CardContent>
          </Card>
        ))}
      </div>

      {/* Lists & Analysis Tables */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
        
        {/* Top Selling Products List */}
        <Card className="border-none shadow-sm overflow-hidden bg-white">
          <CardHeader className="p-4 border-b border-slate-50 flex flex-row items-center justify-between">
            <CardTitle className="text-xs font-bold uppercase tracking-widest text-slate-500 flex items-center gap-2">
              <Star className="h-4 w-4 text-teal-500" /> Top Selling Products
            </CardTitle>
            <span className="text-[9px] font-bold bg-teal-50 text-teal-600 px-2 py-0.5 rounded-full uppercase">Top 5</span>
          </CardHeader>
          <CardContent className="p-0">
            <div className="overflow-x-auto">
              <table className="w-full text-xs text-left">
                <thead className="bg-slate-50/50 text-slate-400 uppercase text-[9px] font-bold tracking-widest border-b border-slate-100">
                  <tr>
                    <th className="px-5 py-3">Product Name</th>
                    <th className="px-5 py-3 text-center">Qty Sold</th>
                    <th className="px-5 py-3 text-right">Revenue Generated</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {topProductsList.map((prod) => (
                    <tr key={prod.id} className="hover:bg-slate-50/30 transition-colors">
                      <td className="px-5 py-3 font-bold text-slate-900">{prod.name}</td>
                      <td className="px-5 py-3 text-center text-slate-600 font-medium">{prod.quantity} units</td>
                      <td className="px-5 py-3 text-right font-bold text-brand-green">${prod.revenue.toLocaleString(undefined, { maximumFractionDigits: 0 })}</td>
                    </tr>
                  ))}
                  {topProductsList.length === 0 && (
                    <tr>
                      <td colSpan={3} className="px-6 py-8 text-center text-slate-400">No product sales data recorded.</td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          </CardContent>
        </Card>

        {/* Top Spending Customers List */}
        <Card className="border-none shadow-sm overflow-hidden bg-white">
          <CardHeader className="p-4 border-b border-slate-50 flex flex-row items-center justify-between">
            <CardTitle className="text-xs font-bold uppercase tracking-widest text-slate-500 flex items-center gap-2">
              <Sparkles className="h-4 w-4 text-violet-500" /> Top Spending Customers
            </CardTitle>
            <span className="text-[9px] font-bold bg-violet-50 text-violet-600 px-2 py-0.5 rounded-full uppercase">Top 5</span>
          </CardHeader>
          <CardContent className="p-0">
            <div className="overflow-x-auto">
              <table className="w-full text-xs text-left">
                <thead className="bg-slate-50/50 text-slate-400 uppercase text-[9px] font-bold tracking-widest border-b border-slate-100">
                  <tr>
                    <th className="px-5 py-3">Customer Details</th>
                    <th className="px-5 py-3 text-center">Orders Placed</th>
                    <th className="px-5 py-3 text-right">Total Invested</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {topCustomersList.map((cust, idx) => (
                    <tr key={idx} className="hover:bg-slate-50/30 transition-colors">
                      <td className="px-5 py-3">
                        <p className="font-bold text-slate-900">{cust.name}</p>
                        <p className="text-[10px] text-slate-400 font-medium">{cust.phone}</p>
                      </td>
                      <td className="px-5 py-3 text-center text-slate-600 font-medium">{cust.orderCount} orders</td>
                      <td className="px-5 py-3 text-right font-bold text-brand-green">${cust.spend.toLocaleString(undefined, { maximumFractionDigits: 0 })}</td>
                    </tr>
                  ))}
                  {topCustomersList.length === 0 && (
                    <tr>
                      <td colSpan={3} className="px-6 py-8 text-center text-slate-400">No customer spend records detected.</td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          </CardContent>
        </Card>

      </div>

      {/* Critical System Alert Monitoring & Recents */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <Card className="border-none shadow-sm overflow-hidden bg-white">
          <CardHeader className="p-4 border-b border-slate-50">
            <CardTitle className="text-xs font-bold uppercase tracking-widest text-slate-500 flex items-center gap-2">
              <Clock className="h-4 w-4 text-orange-500" /> Recent Booking Activities
            </CardTitle>
          </CardHeader>
          <CardContent className="p-0">
            <div className="overflow-x-auto">
              <table className="w-full text-xs text-left">
                <thead className="bg-slate-50/50 text-slate-400 uppercase text-[9px] font-bold tracking-widest border-b border-slate-100">
                  <tr>
                    <th className="px-5 py-3">Order ID</th>
                    <th className="px-5 py-3">Customer</th>
                    <th className="px-5 py-3">Fulfillment</th>
                    <th className="px-5 py-3 text-right">Value</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {filteredOrders.slice(0, 5).map((order) => (
                    <tr key={order.id} className="hover:bg-slate-50/30 transition-colors">
                      <td className="px-5 py-2.5 font-mono font-bold text-slate-400">#{order.id}</td>
                      <td className="px-5 py-2.5 font-semibold text-slate-800">{order.customer}</td>
                      <td className="px-5 py-2.5">
                        <span className={cn(
                          "inline-block px-1.5 py-0.5 rounded text-[8px] font-bold uppercase tracking-wider",
                          order.status === 'delivered' ? "bg-green-50 text-green-600" :
                          order.status === 'cancelled' ? "bg-red-50 text-red-600" :
                          order.status === 'processing' ? "bg-purple-50 text-purple-600" :
                          order.status === 'confirmed' ? "bg-blue-50 text-blue-600" : "bg-orange-50 text-orange-600"
                        )}>
                          {order.status}
                        </span>
                      </td>
                      <td className="px-5 py-2.5 text-right font-bold text-slate-900">${order.total}</td>
                    </tr>
                  ))}
                  {filteredOrders.length === 0 && (
                    <tr>
                      <td colSpan={4} className="px-6 py-8 text-center text-slate-400">No orders recorded</td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          </CardContent>
        </Card>

        <Card className="border-none shadow-sm overflow-hidden bg-white">
          <CardHeader className="p-4 border-b border-slate-50">
            <CardTitle className="text-xs font-bold uppercase tracking-widest text-slate-500 flex items-center gap-2">
              <AlertCircle className="h-4 w-4 text-amber-500" /> Low Stock Warning System
            </CardTitle>
          </CardHeader>
          <CardContent className="p-0">
            <div className="overflow-x-auto">
              <table className="w-full text-xs text-left">
                <thead className="bg-slate-50/50 text-slate-400 uppercase text-[9px] font-bold tracking-widest border-b border-slate-100">
                  <tr>
                    <th className="px-5 py-3">Product Name</th>
                    <th className="px-5 py-3">Category</th>
                    <th className="px-5 py-3 text-right">Available Stock</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {products.filter(p => (p.stock || 0) <= (p.lowStockThreshold || 50)).slice(0, 5).map((product) => (
                    <tr key={product.id} className="hover:bg-slate-50/30 transition-colors">
                      <td className="px-5 py-2.5 font-bold text-slate-900">{product.name}</td>
                      <td className="px-5 py-2.5 text-slate-500">{product.category}</td>
                      <td className="px-5 py-2.5 text-right">
                        <span className={cn(
                          "inline-block px-1.5 py-0.5 rounded text-[9px] font-bold uppercase",
                          (product.stock || 0) === 0 ? "bg-red-50 text-red-600 animate-pulse" : "bg-amber-50 text-amber-600"
                        )}>
                          {(product.stock || 0) === 0 ? "Out of Stock" : `Stock: ${product.stock}`}
                        </span>
                      </td>
                    </tr>
                  ))}
                  {products.filter(p => (p.stock || 0) <= (p.lowStockThreshold || 50)).length === 0 && (
                    <tr>
                      <td colSpan={3} className="px-6 py-8 text-center text-slate-400">All inventory levels are secure.</td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
