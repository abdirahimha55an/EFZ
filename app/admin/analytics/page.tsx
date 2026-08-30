"use client";

import { useEffect, useState } from "react";
import { BarChart3, Calendar, CircleDollarSign, Package, ShoppingBag, TrendingDown, TrendingUp, Users } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { cn } from "@/lib/utils";
import { storage, AdminProfile, Customer, Order, Product } from "@/lib/storage";

type RangeKey = "today" | "week" | "month" | "lastMonth" | "year" | "custom";
type Point = { label: string; revenue: number; orders: number };

const STATUS_NAMES = ["pending", "confirmed", "processing", "delivered", "cancelled"] as const;
const money = (value: number) => `$${value.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const dateValue = (value: string) => new Date(`${value}T00:00:00`);
const startOfDay = (value: Date) => new Date(value.getFullYear(), value.getMonth(), value.getDate());
const addDays = (value: Date, days: number) => new Date(value.getFullYear(), value.getMonth(), value.getDate() + days);

function rangeDates(range: RangeKey, customStart: string, customEnd: string) {
  const today = startOfDay(new Date());
  if (range === "custom") return { start: dateValue(customStart), end: dateValue(customEnd) };
  if (range === "today") return { start: today, end: today };
  if (range === "week") {
    const day = today.getDay();
    const monday = addDays(today, day === 0 ? -6 : 1 - day);
    return { start: monday, end: today };
  }
  if (range === "lastMonth") {
    return { start: new Date(today.getFullYear(), today.getMonth() - 1, 1), end: new Date(today.getFullYear(), today.getMonth(), 0) };
  }
  if (range === "year") return { start: new Date(today.getFullYear(), 0, 1), end: today };
  return { start: new Date(today.getFullYear(), today.getMonth(), 1), end: today };
}

function inRange(order: Order, start: Date, end: Date) {
  const date = dateValue(order.date);
  return date >= start && date <= end;
}

function periodPoints(orders: Order[], start: Date, end: Date): Point[] {
  const span = Math.max(1, Math.round((end.getTime() - start.getTime()) / 86400000) + 1);
  const grouping = span > 90 ? "month" : span > 14 ? "week" : "day";
  const points: Point[] = [];
  const cursor = new Date(start);
  while (cursor <= end) {
    const pointStart = new Date(cursor);
    const pointEnd = grouping === "month"
      ? new Date(cursor.getFullYear(), cursor.getMonth() + 1, 0)
      : grouping === "week" ? addDays(cursor, 6) : pointStart;
    const boundedEnd = pointEnd > end ? end : pointEnd;
    const matching = orders.filter(order => inRange(order, pointStart, boundedEnd) && order.status !== "cancelled");
    points.push({
      label: grouping === "month" ? cursor.toLocaleDateString(undefined, { month: "short", year: "2-digit" }) : grouping === "week" ? cursor.toLocaleDateString(undefined, { month: "short", day: "numeric" }) : cursor.toLocaleDateString(undefined, { month: "short", day: "numeric" }),
      revenue: matching.reduce((sum, order) => sum + order.total, 0),
      orders: matching.length,
    });
    cursor.setTime(addDays(boundedEnd, 1).getTime());
  }
  return points;
}

function compareValue(value: number, previous: number) {
  if (previous === 0) return null;
  return ((value - previous) / previous) * 100;
}

export default function AnalyticsPage() {
  const [mounted, setMounted] = useState(false);
  const [orders, setOrders] = useState<Order[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [profile, setProfile] = useState<AdminProfile | null>(null);
  const [range, setRange] = useState<RangeKey>("month");
  const [customStart, setCustomStart] = useState(new Date(new Date().getFullYear(), new Date().getMonth(), 1).toISOString().slice(0, 10));
  const [customEnd, setCustomEnd] = useState(new Date().toISOString().slice(0, 10));

  useEffect(() => {
    setOrders(storage.getOrders());
    setProducts(storage.getProducts());
    setCustomers(storage.getCustomers());
    setProfile(storage.getProfile());
    setMounted(true);
  }, []);

  if (!mounted || !profile) return null;

  const { start, end } = rangeDates(range, customStart, customEnd);
  const visibleOrders = orders.filter(order => !storage.canViewOwnCustomersOnly(profile) || String(order.marketingOfficerId) === String(profile.id));
  const selectedOrders = visibleOrders.filter(order => inRange(order, start, end));
  const salesOrders = selectedOrders.filter(order => order.status !== "cancelled");
  const revenue = salesOrders.reduce((sum, order) => sum + order.total, 0);
  const productMap = new Map(products.map(product => [product.id, product]));
  const productStats = new Map<string, { name: string; units: number; revenue: number; profit: number; profitAvailable: boolean; standardPrice: number }>();
  let cost = 0;
  let grossProfit = 0;
  let unavailableProfitOrders = 0;
  let units = 0;

  salesOrders.forEach(order => {
    let orderProfitAvailable = true;
    order.items.forEach(item => {
      const quantity = Number(item.quantity) || 0;
      const itemRevenue = (Number(item.price) || 0) * quantity;
      const hasCost = Number.isFinite(Number(item.costPrice));
      const itemCost = hasCost ? Number(item.costPrice) * quantity : 0;
      const product = productMap.get(item.productId);
      const current = productStats.get(item.productId) || { name: item.productName, units: 0, revenue: 0, profit: 0, profitAvailable: true, standardPrice: product?.sellingPrice ?? product?.price ?? 0 };
      current.units += quantity;
      current.revenue += itemRevenue;
      current.profitAvailable = current.profitAvailable && hasCost;
      if (hasCost) { current.profit += itemRevenue - itemCost; cost += itemCost; grossProfit += itemRevenue - itemCost; }
      else orderProfitAvailable = false;
      productStats.set(item.productId, current);
      units += quantity;
    });
    if (!orderProfitAvailable) unavailableProfitOrders += 1;
  });

  const statusCounts = STATUS_NAMES.map(status => ({ status, count: selectedOrders.filter(order => order.status === status).length }));
  const points = periodPoints(selectedOrders, start, end);
  const previousStart = addDays(start, -Math.max(1, Math.round((end.getTime() - start.getTime()) / 86400000) + 1));
  const previousEnd = addDays(start, -1);
  const previousOrders = visibleOrders.filter(order => inRange(order, previousStart, previousEnd) && order.status !== "cancelled");
  const previousRevenue = previousOrders.reduce((sum, order) => sum + order.total, 0);
  const averageOrderValue = salesOrders.length ? revenue / salesOrders.length : 0;
  const margin = revenue ? (grossProfit / revenue) * 100 : 0;
  const canSeeCustomers = storage.canViewCustomers(profile) || storage.canViewOwnCustomersOnly(profile);
  const customerMap = new Map<string, { name: string; revenue: number; orders: number }>();
  salesOrders.forEach(order => {
    const customer = customers.find(item => String(item.id) === String(order.customerId));
    const key = order.customerId || order.customer;
    const current = customerMap.get(key) || { name: customer?.name || order.customer, revenue: 0, orders: 0 };
    current.revenue += order.total;
    current.orders += 1;
    customerMap.set(key, current);
  });
  const topCustomers = [...customerMap.values()].sort((a, b) => b.revenue - a.revenue).slice(0, 5);
  const topProducts = [...productStats.values()].sort((a, b) => b.revenue - a.revenue);
  const maxRevenue = Math.max(...points.map(point => point.revenue), 1);
  const maxStatus = Math.max(...statusCounts.map(item => item.count), 1);
  const linePoints = points.map((point, index) => {
    const x = points.length === 1 ? 50 : (index / (points.length - 1)) * 100;
    const y = 100 - (point.revenue / maxRevenue) * 88;
    return `${x},${y}`;
  }).join(" ");
  const forecastPeriods = [1, 2, 3].map(index => {
    const periodEnd = addDays(start, -((index - 1) * Math.max(1, Math.round((end.getTime() - start.getTime()) / 86400000) + 1)) - 1);
    const periodStart = addDays(periodEnd, -Math.max(1, Math.round((end.getTime() - start.getTime()) / 86400000) + 1) + 1);
    const periodOrders = visibleOrders.filter(order => inRange(order, periodStart, periodEnd) && order.status !== "cancelled");
    return { revenue: periodOrders.reduce((sum, order) => sum + order.total, 0), orders: periodOrders.length, units: periodOrders.reduce((sum, order) => sum + order.items.reduce((itemSum, item) => itemSum + item.quantity, 0), 0), hasData: periodOrders.length > 0 };
  }).filter(period => period.hasData);
  const forecast = forecastPeriods.length >= 2 ? {
    revenue: forecastPeriods.reduce((sum, period) => sum + period.revenue, 0) / forecastPeriods.length,
    orders: forecastPeriods.reduce((sum, period) => sum + period.orders, 0) / forecastPeriods.length,
    units: forecastPeriods.reduce((sum, period) => sum + period.units, 0) / forecastPeriods.length,
  } : null;
  const revenueChange = compareValue(revenue, previousRevenue);
  const dateLabel = `${start.toLocaleDateString()} - ${end.toLocaleDateString()}`;
  const insights = [
    revenueChange !== null ? `Revenue ${revenueChange >= 0 ? "increased" : "decreased"} ${Math.abs(revenueChange).toFixed(1)}% compared with the previous period.` : null,
    topProducts[0] ? `${topProducts[0].name} is the highest-revenue product.` : null,
    topProducts.some(product => product.standardPrice > 0 && product.revenue / product.units < product.standardPrice) ? "Average actual selling price is below the standard price for at least one product." : null,
    margin < 0 ? "Gross margin is negative in this period." : null,
  ].filter(Boolean) as string[];

  const kpis = [
    ["Total Revenue", money(revenue), CircleDollarSign, "text-emerald-600 bg-emerald-50"],
    ["Gross Profit", money(grossProfit), TrendingUp, "text-blue-600 bg-blue-50"],
    ["Total Orders", salesOrders.length.toLocaleString(), ShoppingBag, "text-violet-600 bg-violet-50"],
    ["Units Sold", units.toLocaleString(), Package, "text-amber-600 bg-amber-50"],
    ["Average Order Value", money(averageOrderValue), BarChart3, "text-cyan-600 bg-cyan-50"],
    ["Gross Margin", `${margin.toFixed(1)}%`, margin >= 0 ? TrendingUp : TrendingDown, margin >= 0 ? "text-teal-600 bg-teal-50" : "text-red-600 bg-red-50"],
  ] as const;

  return (
    <div className="space-y-8 animate-in fade-in duration-500">
      <div className="flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <h1 className="font-heading text-2xl font-bold text-slate-900 tracking-tight">Sales &amp; Analytics</h1>
          <p className="text-slate-500 text-xs mt-1">Sales performance, profitability and business outlook.</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Calendar className="h-4 w-4 text-slate-400" />
          {(["today", "week", "month", "lastMonth", "year", "custom"] as RangeKey[]).map(key => (
            <button key={key} onClick={() => setRange(key)} className={cn("rounded-lg px-3 py-2 text-[10px] font-bold capitalize transition-colors", range === key ? "bg-brand-blue text-white" : "bg-white text-slate-500 border border-slate-200 hover:border-brand-blue/40")}>
              {key === "lastMonth" ? "Last Month" : key === "custom" ? "Custom Range" : key === "week" ? "This Week" : key === "month" ? "This Month" : key === "year" ? "This Year" : "Today"}
            </button>
          ))}
          {range === "custom" && <><input aria-label="Custom start date" type="date" value={customStart} onChange={event => setCustomStart(event.target.value)} className="h-9 rounded-lg border border-slate-200 bg-white px-2 text-[10px]" /><input aria-label="Custom end date" type="date" value={customEnd} onChange={event => setCustomEnd(event.target.value)} className="h-9 rounded-lg border border-slate-200 bg-white px-2 text-[10px]" /></>}
        </div>
      </div>
      <p className="text-[10px] font-bold uppercase tracking-widest text-slate-400">Showing {dateLabel}</p>

      <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
        {kpis.map(([title, value, Icon, color]) => <Card key={title} className="border-none shadow-sm"><CardContent className="p-4"><div className="flex items-start justify-between gap-2"><div><p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">{title}</p><p className="mt-1 text-lg font-bold text-slate-900">{value}</p></div><div className={cn("flex h-8 w-8 shrink-0 items-center justify-center rounded-lg", color)}><Icon className="h-4 w-4" /></div></div></CardContent></Card>)}
      </div>

      {selectedOrders.length === 0 ? <Card className="border-dashed shadow-none"><CardContent className="py-16 text-center"><BarChart3 className="mx-auto h-10 w-10 text-slate-300" /><p className="mt-3 text-sm font-bold text-slate-500">No sales data available for this period.</p></CardContent></Card> : <>
        <div className="grid gap-6 lg:grid-cols-[1.5fr_1fr]">
          <Card><CardHeader><CardTitle className="text-sm">Revenue Trend</CardTitle><p className="text-[10px] text-slate-400">Revenue and order volume for the selected period</p></CardHeader><CardContent><div className="relative h-56 border-b border-l border-slate-100"><svg viewBox="0 0 100 100" preserveAspectRatio="none" className="absolute inset-0 h-[calc(100%-24px)] w-full overflow-visible" role="img" aria-label="Revenue trend line chart"><polyline points={linePoints} fill="none" stroke="var(--brand-blue)" strokeWidth="1.5" vectorEffect="non-scaling-stroke" />{points.map((point, index) => { const x = points.length === 1 ? 50 : (index / (points.length - 1)) * 100; const y = 100 - (point.revenue / maxRevenue) * 88; return <circle key={`${point.label}-${index}`} cx={x} cy={y} r="1.5" fill="var(--brand-green)" vectorEffect="non-scaling-stroke"><title>{`${point.label}: ${money(point.revenue)}`}</title></circle>; })}</svg><div className="absolute inset-x-0 bottom-0 flex justify-between gap-2 px-1">{points.map((point, index) => <span key={`${point.label}-label-${index}`} className="max-w-16 truncate text-[9px] text-slate-400">{point.label}</span>)}</div></div><div className="mt-3 flex justify-between text-[10px] font-bold text-slate-400"><span>{money(revenue)} revenue</span><span>{salesOrders.length} orders</span></div></CardContent></Card>
          <Card><CardHeader><CardTitle className="text-sm">Order Status Breakdown</CardTitle></CardHeader><CardContent className="space-y-4">{statusCounts.map(({ status, count }) => <div key={status}><div className="mb-1 flex justify-between text-[10px] font-bold capitalize text-slate-600"><span>{status}</span><span>{count}</span></div><div className="h-2 rounded-full bg-slate-100"><div className={cn("h-2 rounded-full", status === "cancelled" ? "bg-red-400" : "bg-brand-green")} style={{ width: `${(count / maxStatus) * 100}%` }} /></div></div>)}</CardContent></Card>
        </div>

        <Card><CardHeader><CardTitle className="text-sm">Product Performance</CardTitle><p className="text-[10px] text-slate-400">Ranked by actual transaction revenue. Standard price is current reference pricing only.</p></CardHeader><CardContent className="p-0"><div className="overflow-x-auto"><table className="w-full text-left text-xs"><thead className="bg-slate-50 text-[9px] uppercase tracking-widest text-slate-400"><tr><th className="px-5 py-3">Product</th><th className="px-5 py-3 text-right">Units Sold</th><th className="px-5 py-3 text-right">Revenue</th><th className="px-5 py-3 text-right">Gross Profit</th><th className="px-5 py-3 text-right">Avg Actual Price</th><th className="px-5 py-3 text-right">Standard Price</th></tr></thead><tbody className="divide-y divide-slate-50">{topProducts.map(product => <tr key={product.name}><td className="px-5 py-3 font-bold text-slate-800">{product.name}</td><td className="px-5 py-3 text-right text-slate-500">{product.units}</td><td className="px-5 py-3 text-right font-bold text-brand-green">{money(product.revenue)}</td><td className="px-5 py-3 text-right">{product.profitAvailable ? money(product.profit) : <span className="text-slate-400">Unavailable</span>}</td><td className="px-5 py-3 text-right font-semibold">{money(product.revenue / product.units)}</td><td className="px-5 py-3 text-right text-slate-500">{money(product.standardPrice)}</td></tr>)}</tbody></table></div></CardContent></Card>

        <div className="grid gap-6 lg:grid-cols-2">
          <Card><CardHeader><CardTitle className="text-sm">Profitability</CardTitle></CardHeader><CardContent className="grid grid-cols-2 gap-3 md:grid-cols-4">{[["Revenue", money(revenue)], ["Cost", money(cost)], ["Gross Profit", money(grossProfit)], ["Gross Margin", `${margin.toFixed(1)}%`]].map(([label, value]) => <div key={label} className="rounded-lg bg-slate-50 p-3"><p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">{label}</p><p className="mt-1 text-sm font-bold text-slate-800">{value}</p></div>)}<p className="col-span-full text-[10px] text-slate-400">{unavailableProfitOrders > 0 ? `${unavailableProfitOrders} order${unavailableProfitOrders === 1 ? "" : "s"} excluded from profit and cost totals because historical item costs are unavailable.` : "All selected sales have item-level historical cost data."}</p></CardContent></Card>
          {canSeeCustomers && <Card><CardHeader><CardTitle className="flex items-center gap-2 text-sm"><Users className="h-4 w-4 text-brand-blue" />Top Customers by Revenue</CardTitle></CardHeader><CardContent className="space-y-3">{topCustomers.map((customer, index) => <div key={customer.name} className="flex items-center justify-between border-b border-slate-50 pb-2 text-xs last:border-0"><div><span className="mr-2 text-slate-400">{index + 1}</span><span className="font-bold text-slate-800">{customer.name}</span><span className="ml-2 text-[10px] text-slate-400">{customer.orders} orders</span></div><span className="font-bold text-brand-green">{money(customer.revenue)}</span></div>)}{topCustomers.length === 0 && <p className="text-xs text-slate-400">No customer sales data available.</p>}</CardContent></Card>}
        </div>
      </>}

      <div className="grid gap-6 lg:grid-cols-2">
        <Card><CardHeader><CardTitle className="text-sm">Sales Forecast <span className="ml-2 rounded bg-amber-100 px-2 py-1 text-[9px] text-amber-700">ESTIMATE</span></CardTitle><p className="text-[10px] text-slate-400">Average of the three preceding comparable periods with sales data.</p></CardHeader><CardContent>{forecast ? <div className="grid grid-cols-3 gap-3"><div><p className="text-[9px] uppercase tracking-widest text-slate-400">Revenue</p><p className="mt-1 font-bold text-slate-800">{money(forecast.revenue)}</p></div><div><p className="text-[9px] uppercase tracking-widest text-slate-400">Orders</p><p className="mt-1 font-bold text-slate-800">{forecast.orders.toFixed(1)}</p></div><div><p className="text-[9px] uppercase tracking-widest text-slate-400">Units</p><p className="mt-1 font-bold text-slate-800">{forecast.units.toFixed(1)}</p></div></div> : <p className="text-xs text-slate-500">More historical sales data is needed for forecasting.</p>}</CardContent></Card>
        <Card><CardHeader><CardTitle className="text-sm">Key Insights</CardTitle></CardHeader><CardContent>{insights.length ? <ul className="space-y-3">{insights.map(insight => <li key={insight} className="flex gap-2 text-xs text-slate-600"><span className="mt-1 h-1.5 w-1.5 shrink-0 rounded-full bg-brand-green" />{insight}</li>)}</ul> : <p className="text-xs text-slate-400">No comparable insights available for this period.</p>}</CardContent></Card>
      </div>
    </div>
  );
}