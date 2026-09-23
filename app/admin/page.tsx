"use client";

import { useCallback, useEffect, useState } from "react";
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
  Sparkles,
  Loader2
} from "lucide-react";
import { AdminUser, Customer, Order, Product } from "@/lib/types";
import type { FinancialSummaryRow, InventoryStatusRow } from "@/lib/supabase/database.types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";
import { cn } from "@/lib/utils";
import { getFinancialSummary } from "@/lib/financial";

export default function AdminDashboard() {
  const [products, setProducts] = useState<Product[]>([]);
  const [orders, setOrders] = useState<Order[]>([]);
  const [profile, setProfile] = useState<AdminUser | null>(null);
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [inventory, setInventory] = useState<InventoryStatusRow[]>([]);
  const [summaryRow, setSummaryRow] = useState<FinancialSummaryRow | null>(null);
  const [pendingPayouts, setPendingPayouts] = useState(0);
  const [activeIssues, setActiveIssues] = useState(0);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const loadAll = useCallback(async () => {
    const db = getDb();

    // Profile first: what this dashboard is even allowed to ask for depends on
    // the permissions attached to it.
    const nextProfile = await db.auth.getProfile();
    setProfile(nextProfile);
    if (!nextProfile) return;

    const scoped = derivePermissions(nextProfile);

    const [nextProducts, nextOrders, nextCustomers, nextInventory, nextCommissions] =
      await Promise.all([
        db.products.list(),
        db.orders.list(),
        db.customers.list(),
        db.inventory.status(),
        db.commissions.summary(),
      ]);

    setProducts(nextProducts);
    setOrders(nextOrders);
    setCustomers(nextCustomers);
    setInventory(nextInventory);
    setPendingPayouts(
      nextCommissions.reduce((sum, row) => sum + Number(row.pending_commission ?? 0), 0)
    );

    // financial_summary aggregates every order the caller can select, which is
    // the whole business. An officer scoped to their own customers is asking a
    // different question, so their figures are summed from their own rows below.
    if (scoped.viewOwnCustomersOnly) {
      setSummaryRow(null);
    } else {
      setSummaryRow(await db.analytics.financialSummary());
    }

    // Diagnostics is permission-gated; asking without it is an RLS refusal.
    if (scoped.viewDiagnostics) {
      setActiveIssues((await db.issues.list()).length);
    } else {
      setActiveIssues(0);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        setIsLoading(true);
        await loadAll();
        if (!cancelled) setLoadError(null);
      } catch (error) {
        if (!cancelled) setLoadError(describeDbError(error));
      } finally {
        if (!cancelled) setIsLoading(false);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [loadAll]);

  const perms = derivePermissions(profile);

  if (isLoading) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400">
        <Loader2 className="h-6 w-6 animate-spin text-brand-blue" />
        <p className="text-xs font-medium">Loading dashboard…</p>
      </div>
    );
  }

  if (loadError || !profile) {
    return (
      <Card className="border-none shadow-sm">
        <CardContent className="flex flex-col items-center gap-3 py-16 text-center">
          <AlertCircle className="h-8 w-8 text-red-500" />
          <h2 className="font-heading text-lg font-bold text-slate-900">Could not load the dashboard</h2>
          <p className="max-w-md text-xs text-slate-500">
            {loadError ?? "Your account is not linked to a staff profile."}
          </p>
        </CardContent>
      </Card>
    );
  }

  // Filter orders based on permissions
  const filteredOrders = orders.filter(o => {
    if (perms.viewOwnCustomersOnly) {
      return String(o.marketingOfficerId) === String(profile.id);
    }
    return true;
  });

  // Cancelled orders are excluded everywhere on this page - they were previously
  // counted in revenue while being skipped by the top-seller lists below, so the
  // headline and the breakdown disagreed.
  const activeOrders = filteredOrders.filter(o => o.status !== 'cancelled');

  const clientSummary = getFinancialSummary(activeOrders);
  const totalRevenue = Number(summaryRow?.revenue_generated ?? clientSummary.revenueGenerated);
  const totalProfit = Number(summaryRow?.gross_profit ?? clientSummary.grossProfit);
  const totalCollected = Number(summaryRow?.cash_collected ?? clientSummary.cashCollected);
  const outstandingReceivables = Number(summaryRow?.outstanding_receivables ?? clientSummary.outstandingReceivables);
  const totalOrdersCount = Number(summaryRow?.total_orders ?? clientSummary.totalOrders);

  const totalOrdersLabel = `${totalOrdersCount} ${totalOrdersCount === 1 ? 'order' : 'orders'}`;

  // 4. Inventory value, low stock and out of stock, all from inventory_status.
  // One definition of "low", applied by the database against each product's own
  // threshold - the cards and the alert table below can no longer disagree.
  const inventoryValue = inventory.reduce((sum, row) => sum + Number(row.stock_value_at_cost ?? 0), 0);
  const lowStockCount = inventory.filter(row => row.stock_state === 'low_stock').length;
  const outOfStockCount = inventory.filter(row => row.stock_state === 'out_of_stock').length;
  const stockAlerts = inventory.filter(row => row.stock_state !== 'healthy');

  // 5. Monthly Sales (total value of orders from the current month)
  const currentMonth = new Date().toISOString().slice(0, 7); // "YYYY-MM"
  const monthlySales = activeOrders
    .filter(o => o.date?.startsWith(currentMonth))
    .reduce((sum, o) => sum + o.total, 0);

  // 9. Total Customers
  const totalCustomers = customers.filter(c => {
    if (perms.viewOwnCustomersOnly) {
      return String(c.marketingOfficerId || c.registeredBy) === String(profile.id);
    }
    return true;
  }).length;

  // Top sellers and top customers stay client-side: the product_sales view is
  // global, and these lists have to honour the same scoping as the cards above.
  const productSalesMap: Record<string, { name: string; quantity: number; revenue: number }> = {};
  activeOrders.forEach(o => {

    if (o.items && o.items.length > 0) {
      o.items.forEach(item => {
        if (!productSalesMap[item.productId]) {
          productSalesMap[item.productId] = { 
            name: item.productName || 'Unknown Product', 
            quantity: 0, 
            revenue: 0 
          };
        }
        const unitPrice = Number(item.actualUnitPrice ?? item.price ?? item.standardUnitPrice ?? 0);
        const quantity = Number(item.quantity || 0);
        productSalesMap[item.productId].quantity += quantity;
        productSalesMap[item.productId].revenue += Number((unitPrice * quantity).toFixed(2));
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
  activeOrders.forEach(o => {
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

  const orderText = totalOrdersLabel;

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
    { title: "Revenue Generated", value: `$${totalRevenue.toLocaleString(undefined, { maximumFractionDigits: 2 })}`, icon: DollarSign, color: "text-emerald-600", bg: "bg-emerald-50" },
    { title: "Cash Collected", value: `$${totalCollected.toLocaleString(undefined, { maximumFractionDigits: 2 })}`, icon: CheckCircle2, color: "text-blue-600", bg: "bg-blue-50" },
    { title: "Outstanding Receivables", value: `$${outstandingReceivables.toLocaleString(undefined, { maximumFractionDigits: 2 })}`, icon: Clock, color: "text-orange-600", bg: "bg-orange-50" },
    { title: "Gross Profit", value: `$${totalProfit.toLocaleString(undefined, { maximumFractionDigits: 2 })}`, icon: TrendingUp, color: "text-indigo-600", bg: "bg-indigo-50" },
    { title: "Total Orders", value: `${totalOrdersCount}`, icon: ShoppingBag, color: "text-slate-600", bg: "bg-slate-50" },
    { title: "Pending Payouts", value: `$${pendingPayouts.toLocaleString(undefined, { maximumFractionDigits: 0 })}`, icon: Clock, color: "text-orange-600", bg: "bg-orange-50" },
    { title: "Inventory Value", value: `$${inventoryValue.toLocaleString(undefined, { maximumFractionDigits: 0 })}`, icon: Layers, color: "text-indigo-600", bg: "bg-indigo-50" },
    { title: "Monthly Sales Volume", value: `$${monthlySales.toLocaleString(undefined, { maximumFractionDigits: 0 })}`, icon: BarChart3, color: "text-purple-600", bg: "bg-purple-50" },
    { title: "Active System Issues", value: activeIssues, icon: Activity, color: activeIssues > 0 ? "text-red-600 animate-pulse" : "text-slate-500", bg: activeIssues > 0 ? "bg-red-50" : "bg-slate-50" },
    { title: "Low Stock Products", value: lowStockCount, icon: AlertCircle, color: lowStockCount > 0 ? "text-amber-600" : "text-slate-500", bg: lowStockCount > 0 ? "bg-amber-50" : "bg-slate-50" },
    { title: "Out of Stock Products", value: outOfStockCount, icon: Ban, color: outOfStockCount > 0 ? "text-red-600" : "text-slate-500", bg: outOfStockCount > 0 ? "bg-red-50" : "bg-slate-50" },
    { title: "Active Accounts", value: totalCustomers, icon: Users, color: "text-cyan-600", bg: "bg-cyan-50" },
    { title: "Top Selling Product", value: topSellingProduct, icon: Star, color: "text-teal-600", bg: "bg-teal-50", isString: true },
    { title: "Top Spending Customer", value: topCustomer, icon: Sparkles, color: "text-violet-600", bg: "bg-violet-50", isString: true },
    { title: "Total Booked Orders", value: orderText, icon: ShoppingBag, color: "text-slate-600", bg: "bg-slate-50", isString: true }
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
                  {stockAlerts.slice(0, 5).map((product) => (
                    <tr key={product.id} className="hover:bg-slate-50/30 transition-colors">
                      <td className="px-5 py-2.5 font-bold text-slate-900">{product.name}</td>
                      <td className="px-5 py-2.5 text-slate-500">{product.category}</td>
                      <td className="px-5 py-2.5 text-right">
                        <span className={cn(
                          "inline-block px-1.5 py-0.5 rounded text-[9px] font-bold uppercase",
                          product.stock_state === 'out_of_stock' ? "bg-red-50 text-red-600 animate-pulse" : "bg-amber-50 text-amber-600"
                        )}>
                          {product.stock_state === 'out_of_stock' ? "Out of Stock" : `Stock: ${product.stock}`}
                        </span>
                      </td>
                    </tr>
                  ))}
                  {stockAlerts.length === 0 && (
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
