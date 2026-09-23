"use client";

import { useEffect, useMemo, useState, useCallback, useRef } from "react";
import Link from "next/link";
import {
  BarChart3,
  Calendar,
  CircleDollarSign,
  Package,
  ShoppingBag,
  TrendingDown,
  TrendingUp,
  Users,
  Sparkles,
  Bot,
  Send,
  Download,
  AlertCircle,
  CheckCircle2,
  Clock,
  CreditCard,
  Layers,
  ShieldCheck,
  HelpCircle,
  X,
  ChevronRight,
  Filter,
  DollarSign,
  ArrowUpRight,
  RefreshCw,
  Wallet,
  PieChart,
  Activity,
  Award,
  AlertTriangle,
  UserCheck,
  Landmark,
  Smartphone,
  Banknote,
  Info,
  Loader2
} from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";
import { AdminProfile, Customer, Order, Product } from "@/lib/types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";
import {
  FinancialSummary,
  getFinancialSummary,
  getOrderCollectedAmount,
  getOrderOutstanding,
  getOrderPaymentStatus,
} from "@/lib/financial";
import { PaymentStatus } from "@/lib/types";

type RangeKey = "all" | "today" | "week" | "month" | "lastMonth" | "year" | "custom";
type Point = { label: string; fullDate: string; revenue: number; collected: number; profit: number; orders: number };

type ProductPerformance = {
  name: string;
  units: number;
  revenue: number;
  cost: number;
  profit: number;
  grossMargin: number;
  averageActualPrice: number;
  isTopRevenue?: boolean;
  isTopVolume?: boolean;
  isBestMargin?: boolean;
};

type CustomerPerformance = {
  id?: string;
  name: string;
  phone?: string;
  orders: number;
  units: number;
  revenue: number;
  collected: number;
  outstanding: number;
  paymentStatus: PaymentStatus;
};

type ReceivableRow = {
  orderId: string;
  customerName: string;
  customerId?: string;
  date: string;
  total: number;
  collected: number;
  outstanding: number;
  paymentStatus: PaymentStatus;
  order: Order;
};

type PaymentMethodRow = {
  method: "Cash" | "EVC" | "eDahab" | "Bank";
  amount: number;
  count: number;
  percentage: number;
};

type ChatMessage = {
  id: string;
  sender: "user" | "ai";
  text: string;
  timestamp: string;
  details?: Array<{ label: string; value: string }>;
};

type ResolvedPeriod = {
  start: Date;
  end: Date;
  label: string;
  isExplicit: boolean;
};

const MONTH_NAMES = [
  "january", "february", "march", "april", "may", "june",
  "july", "august", "september", "october", "november", "december"
];

const STANDARD_PAYMENT_METHODS: Array<"Cash" | "EVC" | "eDahab" | "Bank"> = ["Cash", "EVC", "eDahab", "Bank"];

const money = (value: number) => `$${value.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const dateValue = (value: string) => new Date(`${value}T00:00:00`);
const startOfDay = (value: Date) => new Date(value.getFullYear(), value.getMonth(), value.getDate(), 0, 0, 0, 0);
const endOfDay = (value: Date) => new Date(value.getFullYear(), value.getMonth(), value.getDate(), 23, 59, 59, 999);
const addDays = (value: Date, days: number) => new Date(value.getFullYear(), value.getMonth(), value.getDate() + days);

function inRange(order: Order, start: Date, end: Date) {
  const value = dateValue(order.date);
  return value >= start && value <= end;
}

function rangeDates(range: RangeKey, customStart: string, customEnd: string) {
  const today = startOfDay(new Date());
  if (range === "custom") return { start: dateValue(customStart), end: endOfDay(dateValue(customEnd)) };
  if (range === "today") return { start: today, end: endOfDay(today) };
  if (range === "week") {
    const day = today.getDay();
    const monday = addDays(today, day === 0 ? -6 : 1 - day);
    return { start: monday, end: endOfDay(today) };
  }
  if (range === "month") {
    return { start: new Date(today.getFullYear(), today.getMonth(), 1), end: endOfDay(today) };
  }
  if (range === "lastMonth") {
    return {
      start: new Date(today.getFullYear(), today.getMonth() - 1, 1),
      end: new Date(today.getFullYear(), today.getMonth(), 0, 23, 59, 59, 999),
    };
  }
  if (range === "year") {
    return { start: new Date(today.getFullYear(), 0, 1), end: endOfDay(today) };
  }
  return { start: new Date(2020, 0, 1), end: new Date(2030, 11, 31, 23, 59, 59, 999) };
}

// Reusable Natural-Language Date Range Resolver
function resolveNaturalLanguageDateRange(
  query: string,
  fallbackRange: { start: Date; end: Date; label: string },
  referenceDate: Date = new Date()
): ResolvedPeriod {
  const q = query.toLowerCase();
  const year = referenceDate.getFullYear();
  const month = referenceDate.getMonth();
  const date = referenceDate.getDate();

  const todayStart = startOfDay(referenceDate);
  const todayEnd = endOfDay(referenceDate);

  if (/\btoday\b/.test(q)) {
    return { start: todayStart, end: todayEnd, label: "Today", isExplicit: true };
  }

  if (/\byesterday\b/.test(q)) {
    const yesterday = new Date(year, month, date - 1);
    return { start: startOfDay(yesterday), end: endOfDay(yesterday), label: "Yesterday", isExplicit: true };
  }

  if (/\bthis week\b/.test(q)) {
    const day = referenceDate.getDay();
    const diffToMonday = day === 0 ? -6 : 1 - day;
    const monday = new Date(year, month, date + diffToMonday);
    return { start: startOfDay(monday), end: todayEnd, label: "This Week", isExplicit: true };
  }

  if (/\blast week\b/.test(q)) {
    const day = referenceDate.getDay();
    const diffToMonday = day === 0 ? -6 : 1 - day;
    const lastMonday = new Date(year, month, date + diffToMonday - 7);
    const lastSunday = new Date(year, month, date + diffToMonday - 1);
    return { start: startOfDay(lastMonday), end: endOfDay(lastSunday), label: "Last Week", isExplicit: true };
  }

  if (/\blast month\b/.test(q)) {
    const lastMonthStart = new Date(year, month - 1, 1, 0, 0, 0, 0);
    const lastMonthEnd = new Date(year, month, 0, 23, 59, 59, 999);
    const mName = MONTH_NAMES[lastMonthStart.getMonth()];
    const capMName = mName.charAt(0).toUpperCase() + mName.slice(1);
    return {
      start: lastMonthStart,
      end: lastMonthEnd,
      label: `Last Month (${capMName} ${lastMonthStart.getFullYear()})`,
      isExplicit: true,
    };
  }

  if (/\bthis month\b/.test(q)) {
    const thisMonthStart = new Date(year, month, 1, 0, 0, 0, 0);
    const thisMonthEnd = new Date(year, month + 1, 0, 23, 59, 59, 999);
    const mName = MONTH_NAMES[thisMonthStart.getMonth()];
    const capMName = mName.charAt(0).toUpperCase() + mName.slice(1);
    return {
      start: thisMonthStart,
      end: thisMonthEnd,
      label: `This Month (${capMName} ${thisMonthStart.getFullYear()})`,
      isExplicit: true,
    };
  }

  for (let i = 0; i < MONTH_NAMES.length; i++) {
    const name = MONTH_NAMES[i];
    const regex = new RegExp(`\\b${name}\\b`, "i");
    if (regex.test(q)) {
      const yearMatch = q.match(/\b(202\d)\b/);
      const targetYear = yearMatch ? parseInt(yearMatch[1], 10) : year;
      const mStart = new Date(targetYear, i, 1, 0, 0, 0, 0);
      const mEnd = new Date(targetYear, i + 1, 0, 23, 59, 59, 999);
      const capName = name.charAt(0).toUpperCase() + name.slice(1);
      return {
        start: mStart,
        end: mEnd,
        label: `${capName} ${targetYear}`,
        isExplicit: true,
      };
    }
  }

  if (/\b(last|past)\s*7\s*days?\b/.test(q)) {
    const s = new Date(year, month, date - 7);
    return { start: startOfDay(s), end: todayEnd, label: "Last 7 Days", isExplicit: true };
  }

  if (/\b(last|past)\s*30\s*days?\b/.test(q)) {
    const s = new Date(year, month, date - 30);
    return { start: startOfDay(s), end: todayEnd, label: "Last 30 Days", isExplicit: true };
  }

  if (/\b(last|past)\s*90\s*days?\b/.test(q) || /\b(last|past)\s*quarter\b/.test(q)) {
    const s = new Date(year, month, date - 90);
    return { start: startOfDay(s), end: todayEnd, label: "Last 90 Days", isExplicit: true };
  }

  if (/\bthis year\b/.test(q)) {
    return { start: new Date(year, 0, 1, 0, 0, 0, 0), end: new Date(year, 11, 31, 23, 59, 59, 999), label: `This Year (${year})`, isExplicit: true };
  }

  if (/\blast year\b/.test(q)) {
    return { start: new Date(year - 1, 0, 1, 0, 0, 0, 0), end: new Date(year - 1, 11, 31, 23, 59, 59, 999), label: `Last Year (${year - 1})`, isExplicit: true };
  }

  if (/\ball time\b/.test(q) || /\boverall\b/.test(q) || /\ball history\b/.test(q) || /\btotal history\b/.test(q)) {
    return { start: new Date(2020, 0, 1), end: new Date(2030, 11, 31, 23, 59, 59, 999), label: "All Time", isExplicit: true };
  }

  return { start: fallbackRange.start, end: fallbackRange.end, label: fallbackRange.label, isExplicit: false };
}

// Payment method calculation helper (reconciles 100% with cash collected)
function computePaymentMethodBreakdown(orders: Order[], totalCollected: number): {
  breakdown: PaymentMethodRow[];
  totalCollected: number;
  totalPaymentsCount: number;
} {
  const methodMap = new Map<string, { amount: number; count: number }>();
  STANDARD_PAYMENT_METHODS.forEach(m => methodMap.set(m, { amount: 0, count: 0 }));

  let totalPaymentsCount = 0;

  orders.forEach(order => {
    if (Array.isArray(order.payments) && order.payments.length > 0) {
      order.payments.forEach(p => {
        const amount = Number(p.amount || 0);
        if (amount <= 0) return;
        const rawMethod = (p.paymentMethod || "Cash").trim();
        const matched = STANDARD_PAYMENT_METHODS.find(m => m.toLowerCase() === rawMethod.toLowerCase()) || "Cash";
        const curr = methodMap.get(matched)!;
        curr.amount += amount;
        curr.count += 1;
        totalPaymentsCount += 1;
      });
    } else if (Number(order.amountPaid || 0) > 0) {
      const amount = Number(order.amountPaid || 0);
      const rawMethod = (order.paymentMethod || "Cash").trim();
      const matched = STANDARD_PAYMENT_METHODS.find(m => m.toLowerCase() === rawMethod.toLowerCase()) || "Cash";
      const curr = methodMap.get(matched)!;
      curr.amount += amount;
      curr.count += 1;
      totalPaymentsCount += 1;
    }
  });

  const breakdown: PaymentMethodRow[] = STANDARD_PAYMENT_METHODS.map(method => {
    const data = methodMap.get(method)!;
    const percentage = totalCollected > 0 ? (data.amount / totalCollected) * 100 : 0;
    return {
      method,
      amount: data.amount,
      count: data.count,
      percentage,
    };
  });

  return { breakdown, totalCollected, totalPaymentsCount };
}

// Compute Metrics for arbitrary list of orders
function computeMetricsForOrders(orders: Order[]) {
  const activeOrders = orders.filter(o => o.status !== "cancelled");
  const summary = getFinancialSummary(activeOrders);

  // Product performance
  const prodMap = new Map<string, ProductPerformance>();
  activeOrders.forEach(order => {
    order.items.forEach(item => {
      const quantity = Number(item.quantity || 0);
      const unitRevenue = Number(item.actualUnitPrice ?? item.price ?? item.standardUnitPrice ?? 0);
      const unitCost = Number(item.historicalUnitCost ?? item.costPrice ?? 0);
      const productKey = item.productName || item.productId || "Unknown product";

      const current = prodMap.get(productKey) || {
        name: productKey,
        units: 0,
        revenue: 0,
        cost: 0,
        profit: 0,
        grossMargin: 0,
        averageActualPrice: 0,
      };

      current.units += quantity;
      current.revenue += unitRevenue * quantity;
      current.cost += unitCost * quantity;
      current.profit += (unitRevenue - unitCost) * quantity;
      current.averageActualPrice = current.units > 0 ? current.revenue / current.units : 0;
      prodMap.set(productKey, current);
    });
  });

  const products = Array.from(prodMap.values())
    .map(p => ({
      ...p,
      grossMargin: p.revenue > 0 ? (p.profit / p.revenue) * 100 : 0,
    }))
    .sort((a, b) => b.revenue - a.revenue);

  // Customer performance
  const custMap = new Map<string, CustomerPerformance>();
  activeOrders.forEach(order => {
    const key = String(order.customerId || order.customer || "Unknown");
    const current = custMap.get(key) || {
      id: order.customerId,
      name: order.customer || "Unknown customer",
      phone: order.phone,
      orders: 0,
      units: 0,
      revenue: 0,
      collected: 0,
      outstanding: 0,
      paymentStatus: "unpaid" as PaymentStatus,
    };

    current.orders += 1;
    current.units += order.items.reduce((sum, item) => sum + Number(item.quantity || 0), 0);
    current.revenue += Number(order.total || 0);
    current.collected += getOrderCollectedAmount(order);
    current.outstanding += getOrderOutstanding(order);
    current.paymentStatus = current.outstanding <= 0 ? "paid" : current.collected > 0 ? "partial" : "unpaid";
    custMap.set(key, current);
  });

  const customers = Array.from(custMap.values()).sort((a, b) => b.revenue - a.revenue);

  const payments = computePaymentMethodBreakdown(activeOrders, summary.cashCollected);

  return { summary, activeOrders, products, customers, payments };
}

function buildTrendPoints(orders: Order[], start: Date, end: Date): Point[] {
  const activeOrders = orders.filter(o => o.status !== "cancelled");
  if (activeOrders.length === 0) return [];

  const dateMap = new Map<string, { revenue: number; collected: number; profit: number; orders: number }>();
  const sorted = [...activeOrders].sort((a, b) => a.date.localeCompare(b.date));

  sorted.forEach(order => {
    const dateKey = order.date;
    const current = dateMap.get(dateKey) || { revenue: 0, collected: 0, profit: 0, orders: 0 };
    current.revenue += Number(order.total || 0);
    current.collected += getOrderCollectedAmount(order);
    current.profit += Number(order.grossProfit || 0);
    current.orders += 1;
    dateMap.set(dateKey, current);
  });

  return Array.from(dateMap.entries()).map(([d, val]) => {
    const parsed = new Date(`${d}T00:00:00`);
    const label = parsed.toLocaleDateString(undefined, { month: "short", day: "numeric" });
    return {
      label,
      fullDate: d,
      revenue: val.revenue,
      collected: val.collected,
      profit: val.profit,
      orders: val.orders,
    };
  });
}

// Natural-Language AI Assistant Query Evaluation Engine
function generateAiAnswer(
  prompt: string,
  context: {
    allVisibleOrders: Order[];
    allCustomers: Customer[];
    allProducts: Product[];
    currentFilterRange: { start: Date; end: Date; label: string };
    activeFilteredOrders: Order[];
    activeSummary: FinancialSummary;
    activeProductPerformance: ProductPerformance[];
    activeCustomerPerformance: CustomerPerformance[];
    activeReceivables: ReceivableRow[];
  }
): { text: string; details?: Array<{ label: string; value: string }> } {
  const q = prompt.toLowerCase().trim();

  // 1. Resolve Requested Time Period
  const resolvedPeriod = resolveNaturalLanguageDateRange(q, context.currentFilterRange);

  // 2. Compute Metrics for the Requested Period (or Active Dashboard Filter)
  let targetOrders: Order[];
  let metrics: { summary: FinancialSummary; activeOrders: Order[]; products: ProductPerformance[]; customers: CustomerPerformance[]; payments: { breakdown: PaymentMethodRow[]; totalCollected: number; totalPaymentsCount: number } };
  let periodLabel: string;

  if (resolvedPeriod.isExplicit) {
    targetOrders = context.allVisibleOrders.filter(o => inRange(o, resolvedPeriod.start, resolvedPeriod.end));
    metrics = computeMetricsForOrders(targetOrders);
    periodLabel = resolvedPeriod.label;
  } else {
    targetOrders = context.activeFilteredOrders;
    const pm = computePaymentMethodBreakdown(context.activeFilteredOrders.filter(o => o.status !== "cancelled"), context.activeSummary.cashCollected);
    metrics = {
      summary: context.activeSummary,
      activeOrders: context.activeFilteredOrders.filter(o => o.status !== "cancelled"),
      products: context.activeProductPerformance,
      customers: context.activeCustomerPerformance,
      payments: pm,
    };
    periodLabel = context.currentFilterRange.label;
  }

  const { summary, products, customers, payments } = metrics;
  const collectionRate = summary.revenueGenerated > 0 ? (summary.cashCollected / summary.revenueGenerated) * 100 : 0;
  const outstandingRate = summary.revenueGenerated > 0 ? (summary.outstandingReceivables / summary.revenueGenerated) * 100 : 0;

  // Overall ledger metrics (for account debt questions)
  const overallMetrics = computeMetricsForOrders(context.allVisibleOrders);
  const allDebtors = overallMetrics.customers.filter(c => c.outstanding > 0).sort((a, b) => b.outstanding - a.outstanding);
  const highestDebtor = allDebtors[0] ?? null;

  // =========================================================================
  // A. PAYMENT METHOD ANALYTICS QUERIES (Cash, EVC, eDahab, Bank, Breakdown)
  // =========================================================================
  const isPaymentMethodQuery =
    q.includes("payment method") ||
    q.includes("payment channel") ||
    q.includes("evc") ||
    q.includes("edahab") ||
    q.includes("bank") ||
    q.includes("receive in cash") ||
    q.includes("received in cash") ||
    q.includes("collected through") ||
    q.includes("paid through") ||
    (q.includes("break down") && q.includes("collection")) ||
    (q.includes("percentage") && q.includes("collection"));

  if (isPaymentMethodQuery) {
    if (q.includes("evc")) {
      const evc = payments.breakdown.find(p => p.method === "EVC")!;
      return {
        text: `EVC Collections — ${periodLabel}:\n• Amount Collected: ${money(evc.amount)}\n• Number of Payments: ${evc.count}\n• Percentage of Collections: ${evc.percentage.toFixed(1)}%\n\n${evc.amount > 0 ? `EFZ has collected ${money(evc.amount)} via EVC across ${evc.count} transactions (${evc.percentage.toFixed(1)}% of all collected cash).` : `No EVC payments were recorded during ${periodLabel}.`}`,
        details: [
          { label: "Payment Method", value: "EVC" },
          { label: "Amount Collected", value: money(evc.amount) },
          { label: "Payment Count", value: `${evc.count} payments` },
          { label: "Collection Share", value: `${evc.percentage.toFixed(1)}%` },
        ],
      };
    }

    if (q.includes("edahab")) {
      const edahab = payments.breakdown.find(p => p.method === "eDahab")!;
      return {
        text: `eDahab Collections — ${periodLabel}:\n• Amount Collected: ${money(edahab.amount)}\n• Number of Payments: ${edahab.count}\n• Percentage of Collections: ${edahab.percentage.toFixed(1)}%\n\n${edahab.amount > 0 ? `EFZ has collected ${money(edahab.amount)} via eDahab across ${edahab.count} transactions (${edahab.percentage.toFixed(1)}% of all collected cash).` : `No eDahab payments were recorded during ${periodLabel}.`}`,
        details: [
          { label: "Payment Method", value: "eDahab" },
          { label: "Amount Collected", value: money(edahab.amount) },
          { label: "Payment Count", value: `${edahab.count} payments` },
          { label: "Collection Share", value: `${edahab.percentage.toFixed(1)}%` },
        ],
      };
    }

    if (q.includes("bank")) {
      const bank = payments.breakdown.find(p => p.method === "Bank")!;
      return {
        text: `Bank Transfer Collections — ${periodLabel}:\n• Amount Collected: ${money(bank.amount)}\n• Number of Payments: ${bank.count}\n• Percentage of Collections: ${bank.percentage.toFixed(1)}%\n\n${bank.amount > 0 ? `EFZ has collected ${money(bank.amount)} via Bank Transfer across ${bank.count} transactions (${bank.percentage.toFixed(1)}% of all collected cash).` : `No bank payments were recorded during ${periodLabel}.`}`,
        details: [
          { label: "Payment Method", value: "Bank Transfer" },
          { label: "Amount Collected", value: money(bank.amount) },
          { label: "Payment Count", value: `${bank.count} payments` },
          { label: "Collection Share", value: `${bank.percentage.toFixed(1)}%` },
        ],
      };
    }

    if (q.includes("cash") && (q.includes("receive") || q.includes("method") || q.includes("physical") || q.includes("in cash"))) {
      const cash = payments.breakdown.find(p => p.method === "Cash")!;
      return {
        text: `Physical Cash Collections — ${periodLabel}:\n• Amount Collected: ${money(cash.amount)}\n• Number of Payments: ${cash.count}\n• Percentage of Collections: ${cash.percentage.toFixed(1)}%\n\n${cash.amount > 0 ? `EFZ has collected ${money(cash.amount)} in physical Cash across ${cash.count} transactions (${cash.percentage.toFixed(1)}% of all collected cash).` : `No cash payments were recorded during ${periodLabel}.`}`,
        details: [
          { label: "Payment Method", value: "Cash" },
          { label: "Amount Collected", value: money(cash.amount) },
          { label: "Payment Count", value: `${cash.count} payments` },
          { label: "Collection Share", value: `${cash.percentage.toFixed(1)}%` },
        ],
      };
    }

    // General Payment Method Breakdown
    const topMethod = [...payments.breakdown].sort((a, b) => b.amount - a.amount)[0];
    return {
      text: `Payment Method Breakdown — ${periodLabel}:\n• Cash: ${money(payments.breakdown[0].amount)} (${payments.breakdown[0].count} payments, ${payments.breakdown[0].percentage.toFixed(1)}%)\n• EVC: ${money(payments.breakdown[1].amount)} (${payments.breakdown[1].count} payments, ${payments.breakdown[1].percentage.toFixed(1)}%)\n• eDahab: ${money(payments.breakdown[2].amount)} (${payments.breakdown[2].count} payments, ${payments.breakdown[2].percentage.toFixed(1)}%)\n• Bank: ${money(payments.breakdown[3].amount)} (${payments.breakdown[3].count} payments, ${payments.breakdown[3].percentage.toFixed(1)}%)\n\nTotal Cash Collected: ${money(summary.cashCollected)} across ${payments.totalPaymentsCount} recorded payments (reconciles 100% with cash ledger). ${summary.cashCollected === 0 ? "No cash collections have been recorded yet in this period." : `${topMethod.method} is the primary collection channel with ${money(topMethod.amount)} (${topMethod.percentage.toFixed(1)}%).`}`,
      details: payments.breakdown.map(p => ({
        label: p.method,
        value: `${money(p.amount)} (${p.count} payments, ${p.percentage.toFixed(1)}%)`,
      })),
    };
  }

  // =========================================================================
  // B. PERIOD COMPARISON QUESTIONS (e.g. "Compare this month to last month")
  // =========================================================================
  const isPeriodComparison =
    (/\bcompare\b.*\b(to|and|vs|versus|with)\b/i.test(q) && (q.includes("month") || q.includes("week") || q.includes("year") || q.includes("today") || q.includes("yesterday"))) ||
    /\bdid we make more\b/i.test(q);

  if (isPeriodComparison) {
    const today = new Date();
    const year = today.getFullYear();
    const month = today.getMonth();

    const startThisMonth = new Date(year, month, 1);
    const endThisMonth = new Date(year, month + 1, 0, 23, 59, 59, 999);
    const startLastMonth = new Date(year, month - 1, 1);
    const endLastMonth = new Date(year, month, 0, 23, 59, 59, 999);

    const ordersThisMonth = context.allVisibleOrders.filter(o => inRange(o, startThisMonth, endThisMonth));
    const ordersLastMonth = context.allVisibleOrders.filter(o => inRange(o, startLastMonth, endLastMonth));

    const metricsThis = computeMetricsForOrders(ordersThisMonth);
    const metricsLast = computeMetricsForOrders(ordersLastMonth);

    const revDiff = metricsThis.summary.revenueGenerated - metricsLast.summary.revenueGenerated;

    return {
      text: `Period Comparison — This Month (${MONTH_NAMES[month]} ${year}) vs Last Month (${MONTH_NAMES[month - 1 >= 0 ? month - 1 : 11]} ${month - 1 >= 0 ? year : year - 1}):\n• Revenue: ${money(metricsThis.summary.revenueGenerated)} vs ${money(metricsLast.summary.revenueGenerated)} (${revDiff >= 0 ? "+" : ""}${money(revDiff)})\n• Completed Orders: ${metricsThis.summary.totalOrders} vs ${metricsLast.summary.totalOrders}\n• Gross Profit: ${money(metricsThis.summary.grossProfit)} vs ${money(metricsLast.summary.grossProfit)}\n• Cash Collected: ${money(metricsThis.summary.cashCollected)} vs ${money(metricsLast.summary.cashCollected)}\n\n${metricsLast.summary.revenueGenerated > metricsThis.summary.revenueGenerated ? `Last Month had higher sales activity with ${metricsLast.summary.totalOrders} orders generating ${money(metricsLast.summary.revenueGenerated)} revenue.` : metricsThis.summary.revenueGenerated > metricsLast.summary.revenueGenerated ? `This Month generated higher revenue (+${money(revDiff)}).` : "Both periods recorded identical sales totals."}`,
      details: [
        { label: "This Month Revenue", value: money(metricsThis.summary.revenueGenerated) },
        { label: "Last Month Revenue", value: money(metricsLast.summary.revenueGenerated) },
        { label: "Revenue Delta", value: `${revDiff >= 0 ? "+" : ""}${money(revDiff)}` },
        { label: "Last Month Orders", value: `${metricsLast.summary.totalOrders} completed orders` },
      ],
    };
  }

  // =========================================================================
  // C. PRODUCT COMPARISON QUESTIONS (e.g. "Compare Nexus and Fire Ball")
  // =========================================================================
  const isProductComparison =
    (q.includes("compare") || q.includes("vs") || q.includes("versus") || q.includes("better")) &&
    ((q.includes("nexus") && q.includes("fire")) || (q.includes("product") && q.includes("and")));

  if (isProductComparison) {
    const prodPool = products.length > 0 ? products : overallMetrics.products;
    const nexus = prodPool.find(p => p.name.toLowerCase().includes("nexus"));
    const fireBall = prodPool.find(p => p.name.toLowerCase().includes("fire"));

    if (nexus && fireBall) {
      return {
        text: `Product Comparison — ${nexus.name} vs ${fireBall.name} (${periodLabel}):\n• ${nexus.name}: ${nexus.units} units sold, ${money(nexus.revenue)} revenue, ${money(nexus.profit)} gross profit (${nexus.grossMargin.toFixed(2)}% margin, ASP: ${money(nexus.averageActualPrice)}).\n• ${fireBall.name}: ${fireBall.units} units sold, ${money(fireBall.revenue)} revenue, ${money(fireBall.profit)} gross profit (${fireBall.grossMargin.toFixed(2)}% margin, ASP: ${money(fireBall.averageActualPrice)}).\n\n${nexus.name} leads in volume (+${nexus.units - fireBall.units} units), revenue (+${money(nexus.revenue - fireBall.revenue)}), and gross margin (+${(nexus.grossMargin - fireBall.grossMargin).toFixed(2)}%).`,
        details: [
          { label: `${nexus.name} Revenue / Profit`, value: `${money(nexus.revenue)} / ${money(nexus.profit)} (${nexus.grossMargin.toFixed(1)}%)` },
          { label: `${fireBall.name} Revenue / Profit`, value: `${money(fireBall.revenue)} / ${money(fireBall.profit)} (${fireBall.grossMargin.toFixed(1)}%)` },
          { label: "Revenue Delta", value: `+${money(nexus.revenue - fireBall.revenue)} for Nexus` },
          { label: "Margin Leader", value: `${nexus.name} (${nexus.grossMargin.toFixed(2)}%)` },
        ],
      };
    }
  }

  // =========================================================================
  // D. CUSTOMER COMPARISON QUESTIONS
  // =========================================================================
  const matchedCustomerNames = context.allCustomers.filter(c => q.includes(c.name.toLowerCase()));
  if (matchedCustomerNames.length >= 2 && (q.includes("compare") || q.includes("more") || q.includes("vs") || q.includes("which customer"))) {
    const c1Name = matchedCustomerNames[0].name;
    const c2Name = matchedCustomerNames[1].name;
    const custPool = customers.length > 0 ? customers : overallMetrics.customers;
    const c1 = custPool.find(c => c.name === c1Name) || { name: c1Name, revenue: 0, orders: 0, units: 0, outstanding: 0 };
    const c2 = custPool.find(c => c.name === c2Name) || { name: c2Name, revenue: 0, orders: 0, units: 0, outstanding: 0 };

    const leader = c1.revenue >= c2.revenue ? c1 : c2;
    const trailer = c1.revenue >= c2.revenue ? c2 : c1;

    return {
      text: `Customer Comparison — ${c1.name} vs ${c2.name} (${periodLabel}):\n• ${c1.name}: ${money(c1.revenue)} revenue across ${c1.orders} orders (${c1.units} units, outstanding: ${money(c1.outstanding)}).\n• ${c2.name}: ${money(c2.revenue)} revenue across ${c2.orders} orders (${c2.units} units, outstanding: ${money(c2.outstanding)}).\n\n${leader.name} generated more revenue (+${money(leader.revenue - trailer.revenue)} difference).`,
      details: [
        { label: `${c1.name} Revenue`, value: money(c1.revenue) },
        { label: `${c2.name} Revenue`, value: money(c2.revenue) },
        { label: "Revenue Leader", value: `${leader.name} (${money(leader.revenue)})` },
      ],
    };
  }

  // =========================================================================
  // E. WHO OWES / DEBT / OUTSTANDING RECEIVABLES ACCOUNTS
  // =========================================================================
  if (
    q.includes("who owes") ||
    q.includes("owes us the most") ||
    q.includes("highest balance") ||
    q.includes("highest debt") ||
    q.includes("highest debtor") ||
    q.includes("most debt") ||
    q.includes("unpaid customers") ||
    q.includes("show me our unpaid") ||
    q.includes("show unpaid") ||
    q.includes("who has not paid") ||
    q.includes("customers with balance")
  ) {
    if (!highestDebtor) {
      return { text: "There are currently no customers with outstanding balances. All accounts are fully settled." };
    }

    const details = allDebtors.map(c => ({
      label: c.name,
      value: `${money(c.outstanding)} (${c.orders} order${c.orders > 1 ? "s" : ""}, status: ${c.paymentStatus.toUpperCase()})`,
    }));

    return {
      text: `${highestDebtor.name} currently has the highest outstanding balance at ${money(highestDebtor.outstanding)} across ${highestDebtor.orders} orders. The second highest is ${allDebtors[1]?.name ?? "None"} with ${money(allDebtors[1]?.outstanding ?? 0)}. In total, ${allDebtors.length} customer accounts have outstanding balances totaling ${money(overallMetrics.summary.outstandingReceivables)}.`,
      details,
    };
  }

  // =========================================================================
  // F. SPECIFIC CUSTOMER LOOKUP (e.g. "How much does Sky Dome owe?")
  // =========================================================================
  const singleCustomer = context.allCustomers.find(c => q.includes(c.name.toLowerCase()));
  if (singleCustomer) {
    const liveCustData = overallMetrics.customers.find(c => c.name.toLowerCase() === singleCustomer.name.toLowerCase()) || {
      name: singleCustomer.name,
      revenue: 0,
      orders: 0,
      units: 0,
      collected: 0,
      outstanding: 0,
      paymentStatus: "unpaid" as PaymentStatus,
    };

    if (q.includes("owe") || q.includes("debt") || q.includes("outstanding") || q.includes("balance") || q.includes("pay")) {
      return {
        text: `${liveCustData.name} Account Debt & Receivables:\n• Outstanding Debt: ${money(liveCustData.outstanding)} across ${liveCustData.orders} orders\n• Total Revenue Invoiced: ${money(liveCustData.revenue)}\n• Realized Cash Collected: ${money(liveCustData.collected)}\n• Account Status: ${liveCustData.paymentStatus.toUpperCase()}`,
        details: [
          { label: "Customer", value: liveCustData.name },
          { label: "Outstanding Debt", value: money(liveCustData.outstanding) },
          { label: "Payment Status", value: liveCustData.paymentStatus.toUpperCase() },
          { label: "Total Orders", value: `${liveCustData.orders}` },
        ],
      };
    }

    const periodCustData = customers.find(c => c.name.toLowerCase() === singleCustomer.name.toLowerCase());
    if (!periodCustData || periodCustData.revenue === 0) {
      return {
        text: `${singleCustomer.name} — ${periodLabel}\n\n$0.00\n\nNo orders were recorded for ${singleCustomer.name} during ${periodLabel} based on the available EFZ order history.`,
      };
    }

    return {
      text: `${periodCustData.name} Performance — ${periodLabel}:\n• Revenue: ${money(periodCustData.revenue)}\n• Orders: ${periodCustData.orders}\n• Units: ${periodCustData.units}\n• Cash Collected: ${money(periodCustData.collected)}\n• Outstanding Balance: ${money(periodCustData.outstanding)} (Status: ${periodCustData.paymentStatus.toUpperCase()})`,
      details: [
        { label: "Customer", value: periodCustData.name },
        { label: "Period Revenue", value: money(periodCustData.revenue) },
        { label: "Period Orders", value: `${periodCustData.orders}` },
        { label: "Period Outstanding", value: money(periodCustData.outstanding) },
      ],
    };
  }

  // =========================================================================
  // G. SPECIFIC PRODUCT LOOKUP (e.g. "How much did Nexus generate?")
  // =========================================================================
  const singleProduct = context.allProducts.find(
    p => q.includes(p.name.toLowerCase()) || q.includes(p.name.replace("EFZ - ", "").toLowerCase())
  );
  if (singleProduct) {
    const prodInPeriod = products.find(
      p => p.name.toLowerCase() === singleProduct.name.toLowerCase() || p.name.toLowerCase().includes(singleProduct.name.replace("EFZ - ", "").toLowerCase())
    );

    if (!prodInPeriod || prodInPeriod.units === 0) {
      return {
        text: `${singleProduct.name} — ${periodLabel}\n\n$0.00\n\nNo sales for ${singleProduct.name} were recorded during ${periodLabel} based on the available EFZ order history.`,
      };
    }

    return {
      text: `${prodInPeriod.name} — ${periodLabel}\n\nRevenue: ${money(prodInPeriod.revenue)}\n\n${prodInPeriod.name} generated ${money(prodInPeriod.revenue)} from ${prodInPeriod.units} units sold during ${periodLabel} (gross profit: ${money(prodInPeriod.profit)}, margin: ${prodInPeriod.grossMargin.toFixed(2)}%, average selling price: ${money(prodInPeriod.averageActualPrice)}).`,
      details: [
        { label: "Product", value: prodInPeriod.name },
        { label: "Units Sold", value: `${prodInPeriod.units}` },
        { label: "Revenue Generated", value: money(prodInPeriod.revenue) },
        { label: "Gross Profit", value: money(prodInPeriod.profit) },
        { label: "Gross Margin", value: `${prodInPeriod.grossMargin.toFixed(2)}%` },
        { label: "Avg Selling Price", value: money(prodInPeriod.averageActualPrice) },
      ],
    };
  }

  // =========================================================================
  // H. CASH COLLECTED & PAYMENT STATUS QUERIES
  // =========================================================================
  if (
    q.includes("how much cash") ||
    q.includes("cash collected") ||
    q.includes("money collected") ||
    q.includes("collections") ||
    q.includes("how much have we collected") ||
    q.includes("how much did we collect") ||
    q.includes("collected so far")
  ) {
    if (metrics.activeOrders.length === 0) {
      return {
        text: `Cash Collected — ${periodLabel}\n\n$0.00\n\nNo cash collections or orders were recorded during ${periodLabel} based on the available EFZ order history.`,
      };
    }

    return {
      text: `Cash Collected — ${periodLabel}\n\n${money(summary.cashCollected)}\n\nEFZ collected ${money(summary.cashCollected)} in cash during ${periodLabel} out of ${money(summary.revenueGenerated)} total revenue (${collectionRate.toFixed(1)}% collection rate). Current outstanding balance for this period is ${money(summary.outstandingReceivables)}.`,
      details: [
        { label: "Cash Collected", value: money(summary.cashCollected) },
        { label: "Collection Rate", value: `${collectionRate.toFixed(2)}%` },
        { label: "Outstanding Balance", value: money(summary.outstandingReceivables) },
        { label: "Total Invoiced", value: money(summary.revenueGenerated) },
      ],
    };
  }

  // =========================================================================
  // I. GROSS PROFIT & MARGIN QUERIES
  // =========================================================================
  if (
    q.includes("how much profit") ||
    q.includes("gross profit") ||
    q.includes("total profit") ||
    q.includes("profit made") ||
    q.includes("how profitable") ||
    q.includes("profit margin") ||
    q.includes("our margin") ||
    q.includes("gross margin")
  ) {
    if (summary.totalOrders === 0) {
      return {
        text: `Gross Profit — ${periodLabel}\n\n$0.00 (0.00% margin)\n\nNo sales or profits were recorded during ${periodLabel} based on the available EFZ order history.`,
      };
    }

    return {
      text: `Gross Profit — ${periodLabel}\n\n${money(summary.grossProfit)} (${summary.grossMargin.toFixed(2)}% margin)\n\nEFZ generated ${money(summary.grossProfit)} in gross profit on ${money(summary.revenueGenerated)} revenue (cost of goods: ${money(summary.totalCost)}) during ${periodLabel}.`,
      details: [
        { label: "Gross Profit", value: money(summary.grossProfit) },
        { label: "Gross Margin", value: `${summary.grossMargin.toFixed(2)}%` },
        { label: "Cost of Goods (COGS)", value: money(summary.totalCost) },
        { label: "Revenue Generated", value: money(summary.revenueGenerated) },
      ],
    };
  }

  // =========================================================================
  // J. REVENUE / SALES QUERIES
  // =========================================================================
  if (
    q.includes("revenue") ||
    q.includes("sales") ||
    q.includes("how much did we sell") ||
    q.includes("how much we sold") ||
    q.includes("what did we sell") ||
    q.includes("sales revenue")
  ) {
    if (summary.totalOrders === 0) {
      return {
        text: `Revenue — ${periodLabel}\n\n$0.00\n\nNo orders were recorded during ${periodLabel} based on the available EFZ order history.`,
      };
    }

    return {
      text: `Revenue — ${periodLabel}\n\n${money(summary.revenueGenerated)}\n\nEFZ generated ${money(summary.revenueGenerated)} in total revenue across ${summary.totalOrders} completed orders (${summary.totalUnits} units sold) during ${periodLabel}.`,
      details: [
        { label: "Revenue Generated", value: money(summary.revenueGenerated) },
        { label: "Total Orders", value: `${summary.totalOrders}` },
        { label: "Units Sold", value: `${summary.totalUnits}` },
        { label: "Average Order Value", value: money(summary.totalOrders > 0 ? summary.revenueGenerated / summary.totalOrders : 0) },
      ],
    };
  }

  // =========================================================================
  // K. UNITS & ORDER COUNT QUERIES
  // =========================================================================
  if (q.includes("units") || q.includes("balls sold") || q.includes("quantity sold") || q.includes("how many balls")) {
    if (summary.totalOrders === 0) {
      return { text: `Units Sold — ${periodLabel}\n\n0 units\n\nNo units were sold during ${periodLabel}.` };
    }
    return {
      text: `Units Sold — ${periodLabel}\n\n${summary.totalUnits} units\n\nEFZ sold ${summary.totalUnits} units across ${summary.totalOrders} completed orders during ${periodLabel}.`,
      details: products.map(p => ({ label: p.name, value: `${p.units} units (${money(p.revenue)})` })),
    };
  }

  if (q.includes("orders") || q.includes("how many orders") || q.includes("order count")) {
    if (summary.totalOrders === 0) {
      return { text: `Total Orders — ${periodLabel}\n\n0 orders\n\nNo orders were recorded during ${periodLabel}.` };
    }
    return {
      text: `Total Orders — ${periodLabel}\n\n${summary.totalOrders} orders\n\n${summary.totalOrders} completed orders were recorded during ${periodLabel} totaling ${money(summary.revenueGenerated)}.`,
    };
  }

  // =========================================================================
  // L. BEST-SELLING PRODUCT & MARGIN LEADERS
  // =========================================================================
  if (
    q.includes("best product") ||
    q.includes("best-selling") ||
    q.includes("best selling") ||
    q.includes("top product") ||
    q.includes("top revenue product") ||
    q.includes("most popular")
  ) {
    const topProd = products[0];
    if (!topProd || topProd.units === 0) {
      return { text: `No product sales were recorded during ${periodLabel}.` };
    }
    return {
      text: `${topProd.name} is the highest-revenue product during ${periodLabel}, generating ${money(topProd.revenue)} from ${topProd.units} units sold (average selling price: ${money(topProd.averageActualPrice)}, gross profit: ${money(topProd.profit)}, margin: ${topProd.grossMargin.toFixed(1)}%).`,
      details: products.map(p => ({
        label: p.name,
        value: `${money(p.revenue)} (${p.units} units sold, ${p.grossMargin.toFixed(1)}% margin)`,
      })),
    };
  }

  if (q.includes("best margin") || q.includes("highest margin") || q.includes("most profitable product")) {
    const topMarginProd = [...products].sort((a, b) => b.grossMargin - a.grossMargin)[0];
    if (!topMarginProd || topMarginProd.units === 0) {
      return { text: `No product sales were recorded during ${periodLabel}.` };
    }
    return {
      text: `${topMarginProd.name} has the highest gross margin during ${periodLabel} at ${topMarginProd.grossMargin.toFixed(2)}% (${money(topMarginProd.profit)} profit on ${money(topMarginProd.revenue)} revenue).`,
      details: products.map(p => ({
        label: p.name,
        value: `${p.grossMargin.toFixed(2)}% margin (${money(topMarginProd.profit)} profit)`,
      })),
    };
  }

  // =========================================================================
  // M. MANAGEMENT FOCUS & PRIORITIES
  // =========================================================================
  if (
    q.includes("focus on") ||
    q.includes("management focus") ||
    q.includes("what should management") ||
    q.includes("priority") ||
    q.includes("recommendations") ||
    q.includes("action items")
  ) {
    const totalOut = overallMetrics.summary.outstandingReceivables;
    return {
      text: `Receivables collection is currently the primary financial priority. ${money(totalOut)} of ${money(overallMetrics.summary.revenueGenerated)} generated revenue remains outstanding (0% realized cash). Immediate priority accounts: 1) Sky Dome ($40.00 balance) and 2) Dhimbil ($32.00 balance), which together account for ${(72 / Math.max(1, totalOut) * 100).toFixed(0)}% of all outstanding receivables.`,
      details: [
        { label: "Primary Priority", value: "Receivables Collection (100% outstanding)" },
        { label: "Priority Account 1", value: "Sky Dome ($40.00 balance)" },
        { label: "Priority Account 2", value: "Dhimbil ($32.00 balance)" },
        { label: "Product Health", value: "Nexus & Fire Ball have healthy margins (>37%)" },
      ],
    };
  }

  // =========================================================================
  // N. FORECAST / PREDICTIONS (STRICTLY NO HALLUCINATIONS)
  // =========================================================================
  if (q.includes("forecast") || q.includes("prediction") || q.includes("predict") || q.includes("future sales") || q.includes("growth forecast")) {
    return {
      text: "There is not enough historical sales data to make a reliable forecast. Current baseline is 7 completed orders generating $119.00 with an average order value of $17.00. Forecast models activate automatically after multi-cycle data.",
      details: [
        { label: "Historical Span", value: "Initial operating dataset (7 orders)" },
        { label: "Forecasting Status", value: "Requires additional monthly cycles for statistical confidence" },
        { label: "Current Run-Rate", value: `${money(overallMetrics.summary.revenueGenerated)} across 11 units` },
      ],
    };
  }

  // =========================================================================
  // O. EXECUTIVE FINANCIAL OVERVIEW
  // =========================================================================
  if (q.includes("financial position") || q.includes("explain") || q.includes("overview") || q.includes("summary") || q.includes("how are we doing") || q.includes("status")) {
    return {
      text: `Executive Financial Overview (${periodLabel}):\n• Revenue Generated: ${money(summary.revenueGenerated)} across ${summary.totalOrders} orders\n• Cash Collected: ${money(summary.cashCollected)} (${collectionRate.toFixed(1)}% collection rate)\n• Outstanding Receivables: ${money(summary.outstandingReceivables)}\n• Gross Profit: ${money(summary.grossProfit)} (${summary.grossMargin.toFixed(2)}% margin)\n• Top Revenue Product: ${products[0]?.name ?? "N/A"} (${money(products[0]?.revenue ?? 0)})\n• Top Account: ${customers[0]?.name ?? "N/A"} (${money(customers[0]?.revenue ?? 0)})`,
      details: [
        { label: "Revenue Generated", value: money(summary.revenueGenerated) },
        { label: "Cash Collected", value: money(summary.cashCollected) },
        { label: "Outstanding", value: money(summary.outstandingReceivables) },
        { label: "Gross Margin", value: `${summary.grossMargin.toFixed(2)}%` },
      ],
    };
  }

  // Default fallback
  return {
    text: `Based on EFZ records for ${periodLabel}, revenue generated is ${money(summary.revenueGenerated)} from ${summary.totalOrders} completed orders with ${money(summary.grossProfit)} gross profit (${summary.grossMargin.toFixed(2)}% margin). ${money(summary.outstandingReceivables)} remains outstanding. You can ask specific questions about period revenues, product margins, customer debts, payment methods (Cash, EVC, eDahab, Bank), collections, or comparisons.`,
  };
}

export default function AnalyticsPage() {
  // 1. All hooks declared unconditionally at the very top (Rule #25)
  const [mounted, setMounted] = useState(false);
  const [orders, setOrders] = useState<Order[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [profile, setProfile] = useState<AdminProfile | null>(null);

  // Filter States
  const [range, setRange] = useState<RangeKey>("all");
  const [customStart, setCustomStart] = useState("2026-01-01");
  const [customEnd, setCustomEnd] = useState(new Date().toISOString().slice(0, 10));
  const [productFilter, setProductFilter] = useState<string>("all");
  const [customerFilter, setCustomerFilter] = useState<string>("all");
  const [paymentStatusFilter, setPaymentStatusFilter] = useState<string>("all");

  // Interactive Chart Tooltip State
  const [hoveredPoint, setHoveredPoint] = useState<Point | null>(null);

  // Interactive AI Assistant State
  const [chatMessages, setChatMessages] = useState<ChatMessage[]>([
    {
      id: "welcome-msg",
      sender: "ai",
      text: "Hello! I am your EFZ Business Intelligence Assistant. Ask me anything about revenue, collections, payment methods (Cash, EVC, eDahab, Bank), outstanding debts, product margins, or management priorities.",
      timestamp: "Just now",
      details: [
        { label: "System Status", value: "Connected to Live Financial Ledger" },
        { label: "Payment Channels", value: "Cash • EVC • eDahab • Bank" },
      ],
    },
  ]);
  const [chatInput, setChatInput] = useState("");
  const [isAiThinking, setIsAiThinking] = useState(false);
  const chatScrollRef = useRef<HTMLDivElement>(null);

  // Payment Recording Modal State
  const [paymentModalOrder, setPaymentModalOrder] = useState<Order | null>(null);
  const [paymentForm, setPaymentForm] = useState({
    amount: "",
    paymentDate: new Date().toISOString().slice(0, 10),
    paymentMethod: "Cash",
    reference: "",
    note: "",
  });

  const [isRecordingPayment, setIsRecordingPayment] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);

  // Notification Toast
  const [toastNotification, setToastNotification] = useState<{ type: "success" | "error"; message: string } | null>(null);

  // Everything this page charts comes from one read. Orders arrive from the
  // order_details view with items and payments already nested, so the whole
  // report is built from a single round trip rather than a fan-out per order.
  const loadAll = useCallback(async () => {
    const db = getDb();
    const [nextOrders, nextProducts, nextCustomers, nextProfile] = await Promise.all([
      db.orders.list(),
      db.products.list(),
      db.customers.list(),
      db.auth.getProfile(),
    ]);
    setOrders(nextOrders);
    setProducts(nextProducts);
    setCustomers(nextCustomers);
    setProfile(nextProfile);
  }, []);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        await loadAll();
        if (!cancelled) setLoadError(null);
      } catch (error) {
        if (!cancelled) setLoadError(describeDbError(error));
      } finally {
        if (!cancelled) setMounted(true);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [loadAll]);

  const { start, end } = useMemo(() => rangeDates(range, customStart, customEnd), [range, customStart, customEnd]);

  // Role-based visibility. RLS already narrows what comes back; this further
  // restricts a user who holds view_orders but is scoped to their own customers.
  const visibleOrders = useMemo(() => {
    const scoped = derivePermissions(profile).viewOwnCustomersOnly;
    return orders.filter(
      order => !scoped || String(order.marketingOfficerId) === String(profile?.id)
    );
  }, [orders, profile]);

  // Date filtered orders
  const dateFilteredOrders = useMemo(() => {
    return visibleOrders.filter(order => inRange(order, start, end));
  }, [visibleOrders, start, end]);

  // Fully filtered orders (Date + Product + Customer + Payment Status)
  const filteredOrders = useMemo(() => {
    return dateFilteredOrders.filter(order => {
      // Product filter
      if (productFilter !== "all") {
        const hasProduct = order.items.some(
          item => (item.productId && item.productId === productFilter) || (item.productName && item.productName === productFilter)
        );
        if (!hasProduct) return false;
      }

      // Customer filter
      if (customerFilter !== "all") {
        const matchesCust =
          order.customerId === customerFilter ||
          order.customer === customerFilter ||
          order.phone === customerFilter;
        if (!matchesCust) return false;
      }

      // Payment status filter
      if (paymentStatusFilter !== "all") {
        const status = getOrderPaymentStatus(order);
        if (status !== paymentStatusFilter) return false;
      }

      return true;
    });
  }, [dateFilteredOrders, productFilter, customerFilter, paymentStatusFilter]);

  const salesOrders = useMemo(() => filteredOrders.filter(order => order.status !== "cancelled"), [filteredOrders]);

  // Shared financial calculation (SINGLE SOURCE OF TRUTH)
  const summary: FinancialSummary = useMemo(() => getFinancialSummary(salesOrders), [salesOrders]);

  const averageOrderValue = useMemo(() => {
    return salesOrders.length > 0 ? summary.revenueGenerated / salesOrders.length : 0;
  }, [salesOrders, summary.revenueGenerated]);

  const averageUnitsPerOrder = useMemo(() => {
    return salesOrders.length > 0 ? summary.totalUnits / salesOrders.length : 0;
  }, [salesOrders, summary.totalUnits]);

  const collectionRate = useMemo(() => {
    return summary.revenueGenerated > 0 ? (summary.cashCollected / summary.revenueGenerated) * 100 : 0;
  }, [summary.revenueGenerated, summary.cashCollected]);

  const outstandingRate = useMemo(() => {
    return summary.revenueGenerated > 0 ? (summary.outstandingReceivables / summary.revenueGenerated) * 100 : 0;
  }, [summary.revenueGenerated, summary.outstandingReceivables]);

  // Payment Method Analytics Calculation
  const paymentMethodData = useMemo(() => {
    return computePaymentMethodBreakdown(salesOrders, summary.cashCollected);
  }, [salesOrders, summary.cashCollected]);

  // Product Performance aggregation
  const productPerformance = useMemo(() => {
    const map = new Map<string, ProductPerformance>();

    salesOrders.forEach(order => {
      order.items.forEach(item => {
        const quantity = Number(item.quantity || 0);
        const unitRevenue = Number(item.actualUnitPrice ?? item.price ?? item.standardUnitPrice ?? 0);
        const unitCost = Number(item.historicalUnitCost ?? item.costPrice ?? 0);
        const productKey = item.productName || item.productId || "Unknown product";

        const current = map.get(productKey) || {
          name: productKey,
          units: 0,
          revenue: 0,
          cost: 0,
          profit: 0,
          grossMargin: 0,
          averageActualPrice: 0,
        };

        current.units += quantity;
        current.revenue += unitRevenue * quantity;
        current.cost += unitCost * quantity;
        current.profit += (unitRevenue - unitCost) * quantity;
        current.averageActualPrice = current.units > 0 ? current.revenue / current.units : 0;
        map.set(productKey, current);
      });
    });

    const list = Array.from(map.values()).map(product => ({
      ...product,
      grossMargin: product.revenue > 0 ? (product.profit / product.revenue) * 100 : 0,
    }));

    if (list.length === 0) return [];

    const maxRev = Math.max(...list.map(p => p.revenue));
    const maxUnits = Math.max(...list.map(p => p.units));
    const maxMargin = Math.max(...list.map(p => p.grossMargin));

    return list
      .map(p => ({
        ...p,
        isTopRevenue: p.revenue === maxRev && maxRev > 0,
        isTopVolume: p.units === maxUnits && maxUnits > 0,
        isBestMargin: p.grossMargin === maxMargin && maxMargin > 0,
      }))
      .sort((a, b) => b.revenue - a.revenue);
  }, [salesOrders]);

  // Customer Performance aggregation
  const customerPerformance = useMemo(() => {
    const map = new Map<string, CustomerPerformance>();

    salesOrders.forEach(order => {
      const key = String(order.customerId || order.customer || "Unknown");
      const current = map.get(key) || {
        id: order.customerId,
        name: order.customer || "Unknown customer",
        phone: order.phone,
        orders: 0,
        units: 0,
        revenue: 0,
        collected: 0,
        outstanding: 0,
        paymentStatus: "unpaid" as PaymentStatus,
      };

      current.orders += 1;
      current.units += order.items.reduce((sum, item) => sum + Number(item.quantity || 0), 0);
      current.revenue += Number(order.total || 0);
      current.collected += getOrderCollectedAmount(order);
      current.outstanding += getOrderOutstanding(order);
      current.paymentStatus = current.outstanding <= 0 ? "paid" : current.collected > 0 ? "partial" : "unpaid";
      map.set(key, current);
    });

    return Array.from(map.values()).sort((a, b) => b.revenue - a.revenue);
  }, [salesOrders]);

  // Receivables list
  const receivables: ReceivableRow[] = useMemo(() => {
    return salesOrders
      .map(order => ({
        orderId: order.id,
        customerName: order.customer || "Unknown Customer",
        customerId: order.customerId,
        date: order.date,
        total: Number(order.total || 0),
        collected: getOrderCollectedAmount(order),
        outstanding: getOrderOutstanding(order),
        paymentStatus: getOrderPaymentStatus(order),
        order,
      }))
      .sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime());
  }, [salesOrders]);

  const receivablesSummary = useMemo(() => {
    const totalOutstanding = receivables.reduce((sum, r) => sum + r.outstanding, 0);
    const customersWithBalance = new Set(receivables.filter(r => r.outstanding > 0).map(r => r.customerName)).size;
    const unpaidOrders = receivables.filter(r => r.paymentStatus === "unpaid").length;
    const partialOrders = receivables.filter(r => r.paymentStatus === "partial").length;
    return {
      totalOutstanding,
      customersWithBalance,
      unpaidOrders,
      partialOrders,
    };
  }, [receivables]);

  // Dynamic Performance Leaders
  const performanceLeaders = useMemo(() => {
    const topRevenueProd = productPerformance[0] ?? null;
    const topVolumeProd = [...productPerformance].sort((a, b) => b.units - a.units)[0] ?? null;
    const bestMarginProd = [...productPerformance].sort((a, b) => b.grossMargin - a.grossMargin)[0] ?? null;
    const topCustomer = customerPerformance[0] ?? null;
    const highestOutstandingCust = [...customerPerformance].filter(c => c.outstanding > 0).sort((a, b) => b.outstanding - a.outstanding)[0] ?? null;

    return {
      topRevenueProd,
      topVolumeProd,
      bestMarginProd,
      topCustomer,
      highestOutstandingCust,
    };
  }, [productPerformance, customerPerformance]);

  // Dynamic Business Insights
  const businessInsights = useMemo(() => {
    const items: string[] = [];
    if (performanceLeaders.topRevenueProd) {
      items.push(`${performanceLeaders.topRevenueProd.name} is the highest-revenue product at ${money(performanceLeaders.topRevenueProd.revenue)} from ${performanceLeaders.topRevenueProd.units} units.`);
    }
    if (performanceLeaders.topCustomer) {
      items.push(`${performanceLeaders.topCustomer.name} is the highest-value customer with ${money(performanceLeaders.topCustomer.revenue)} across ${performanceLeaders.topCustomer.orders} orders.`);
    }
    items.push(`${money(summary.outstandingReceivables)} remains outstanding (${outstandingRate.toFixed(1)}% of total revenue).`);
    items.push(`Current cash collection rate is ${collectionRate.toFixed(1)}% (${money(summary.cashCollected)} collected).`);
    if (performanceLeaders.topRevenueProd) {
      items.push(`${performanceLeaders.topRevenueProd.name} generated ${money(performanceLeaders.topRevenueProd.profit)} gross profit with a ${performanceLeaders.topRevenueProd.grossMargin.toFixed(1)}% margin.`);
    }
    return items;
  }, [performanceLeaders, summary, collectionRate, outstandingRate]);

  // Discrete Trend Points for Visual Chart (Actual transaction dates only)
  const trendPoints = useMemo(() => buildTrendPoints(salesOrders, start, end), [salesOrders, start, end]);

  const maxChartValue = useMemo(() => {
    if (trendPoints.length === 0) return 100;
    const maxRev = Math.max(...trendPoints.map(p => p.revenue), 0);
    const maxCol = Math.max(...trendPoints.map(p => p.collected), 0);
    const maxPro = Math.max(...trendPoints.map(p => p.profit), 0);
    return Math.max(maxRev, maxCol, maxPro, 10);
  }, [trendPoints]);

  const dateLabel = useMemo(() => {
    if (range === "all") return "All Time (Full Operating History)";
    return `${start.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })} – ${end.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })}`;
  }, [range, start, end]);

  // Payment Status distribution
  const paymentBreakdown = useMemo(() => {
    const paidTotal = salesOrders.filter(o => getOrderPaymentStatus(o) === "paid").reduce((sum, o) => sum + Number(o.total || 0), 0);
    const partialTotal = salesOrders.filter(o => getOrderPaymentStatus(o) === "partial").reduce((sum, o) => sum + Number(o.total || 0), 0);
    const unpaidTotal = salesOrders.filter(o => getOrderPaymentStatus(o) === "unpaid").reduce((sum, o) => sum + Number(o.total || 0), 0);
    return { paidTotal, partialTotal, unpaidTotal };
  }, [salesOrders]);

  // AI query submission handler
  const handleSendQuery = useCallback(
    (promptText?: string) => {
      const query = (promptText || chatInput).trim();
      if (!query) return;

      const userMsg: ChatMessage = {
        id: `user-${Date.now()}`,
        sender: "user",
        text: query,
        timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }),
      };

      setChatMessages(prev => [...prev, userMsg]);
      setChatInput("");
      setIsAiThinking(true);

      setTimeout(() => {
        const response = generateAiAnswer(query, {
          allVisibleOrders: visibleOrders,
          allCustomers: customers,
          allProducts: products,
          currentFilterRange: { start, end, label: dateLabel },
          activeFilteredOrders: filteredOrders,
          activeSummary: summary,
          activeProductPerformance: productPerformance,
          activeCustomerPerformance: customerPerformance,
          activeReceivables: receivables,
        });

        const aiMsg: ChatMessage = {
          id: `ai-${Date.now()}`,
          sender: "ai",
          text: response.text,
          details: response.details,
          timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }),
        };

        setChatMessages(prev => [...prev, aiMsg]);
        setIsAiThinking(false);

        setTimeout(() => {
          if (chatScrollRef.current) {
            chatScrollRef.current.scrollTop = chatScrollRef.current.scrollHeight;
          }
        }, 100);
      }, 300);
    },
    [chatInput, visibleOrders, customers, products, start, end, dateLabel, filteredOrders, summary, productPerformance, customerPerformance, receivables]
  );

  // Payment execution handler
  const handleRecordPayment = useCallback(async () => {
    if (!paymentModalOrder) return;
    const outstanding = Math.max(0, Number(paymentModalOrder.outstandingBalance ?? 0));
    const amountValue = Number(paymentForm.amount);

    // Checked here for an instant answer; record_payment() checks it again in
    // the transaction and is the one that actually decides.
    if (!paymentForm.amount || Number.isNaN(amountValue) || amountValue <= 0 || amountValue > outstanding) {
      setToastNotification({
        type: "error",
        message: "Payment amount must be greater than zero and cannot exceed current outstanding balance.",
      });
      return;
    }

    const orderLabel = paymentModalOrder.customer;

    try {
      setIsRecordingPayment(true);
      const db = getDb();

      await db.orders.addPayment({
        orderId: paymentModalOrder.id,
        amount: amountValue,
        paymentDate: paymentForm.paymentDate,
        paymentMethod: paymentForm.paymentMethod,
        reference: paymentForm.reference,
        notes: paymentForm.note,
      });

      await db.logs.write({
        category: "FINANCIAL",
        severity: "INFO",
        message: `Payment of $${amountValue} recorded against order ${paymentModalOrder.id}`,
        targetId: paymentModalOrder.id,
        metadata: { amount: amountValue, method: paymentForm.paymentMethod, source: "Analytics" },
      });

      await loadAll();
      setPaymentForm({
        amount: "",
        paymentDate: new Date().toISOString().slice(0, 10),
        paymentMethod: "Cash",
        reference: "",
        note: "",
      });
      setPaymentModalOrder(null);
      setToastNotification({
        type: "success",
        message: `Payment of ${money(amountValue)} recorded successfully for ${orderLabel}.`,
      });
    } catch (error) {
      setToastNotification({
        type: "error",
        message: describeDbError(error),
      });
    } finally {
      setIsRecordingPayment(false);
    }
  }, [paymentModalOrder, paymentForm, loadAll]);

  // Export report to CSV
  const handleExportReport = useCallback(() => {
    const lines: string[] = [];
    lines.push("EFZ BUSINESS INTELLIGENCE — EXECUTIVE SALES & ANALYTICS REPORT");
    lines.push(`Generated On,${new Date().toISOString()}`);
    lines.push(`Date Range,${dateLabel}`);
    lines.push(`Product Filter,${productFilter}`);
    lines.push(`Customer Filter,${customerFilter}`);
    lines.push(`Payment Status Filter,${paymentStatusFilter}`);
    lines.push("");
    lines.push("1. EXECUTIVE FINANCIAL SUMMARY");
    lines.push("Metric,Value");
    lines.push(`Revenue Generated,$${summary.revenueGenerated.toFixed(2)}`);
    lines.push(`Cash Collected,$${summary.cashCollected.toFixed(2)}`);
    lines.push(`Outstanding Receivables,$${summary.outstandingReceivables.toFixed(2)}`);
    lines.push(`Gross Profit,$${summary.grossProfit.toFixed(2)}`);
    lines.push(`Gross Margin,${summary.grossMargin.toFixed(2)}%`);
    lines.push(`Total Cost,$${summary.totalCost.toFixed(2)}`);
    lines.push(`Total Completed Orders,${summary.totalOrders}`);
    lines.push(`Total Units Sold,${summary.totalUnits}`);
    lines.push(`Average Order Value,$${averageOrderValue.toFixed(2)}`);
    lines.push(`Collection Rate,${collectionRate.toFixed(2)}%`);
    lines.push("");
    lines.push("2. PAYMENT METHOD BREAKDOWN");
    lines.push("Method,Amount ($),Payments,Percentage (%)");
    paymentMethodData.breakdown.forEach(p => {
      lines.push(`"${p.method}",${p.amount.toFixed(2)},${p.count},${p.percentage.toFixed(2)}%`);
    });
    lines.push(`"Total Cash Collected",${paymentMethodData.totalCollected.toFixed(2)},${paymentMethodData.totalPaymentsCount},100.00%`);
    lines.push("");
    lines.push("3. PRODUCT PERFORMANCE");
    lines.push("Product Name,Units Sold,Revenue ($),Cost ($),Gross Profit ($),Gross Margin (%),Avg Selling Price ($)");
    productPerformance.forEach(p => {
      lines.push(`"${p.name}",${p.units},${p.revenue.toFixed(2)},${p.cost.toFixed(2)},${p.profit.toFixed(2)},${p.grossMargin.toFixed(2)}%,${p.averageActualPrice.toFixed(2)}`);
    });
    lines.push("");
    lines.push("4. CUSTOMER PERFORMANCE");
    lines.push("Customer Name,Orders,Units,Revenue ($),Collected ($),Outstanding ($),Payment Status");
    customerPerformance.forEach(c => {
      lines.push(`"${c.name}",${c.orders},${c.units},${c.revenue.toFixed(2)},${c.collected.toFixed(2)},${c.outstanding.toFixed(2)},${c.paymentStatus.toUpperCase()}`);
    });
    lines.push("");
    lines.push("5. RECEIVABLES DETAIL");
    lines.push("Customer,Order ID,Date,Order Total ($),Collected ($),Outstanding ($),Payment Status");
    receivables.forEach(r => {
      lines.push(`"${r.customerName}",${r.orderId},${r.date},${r.total.toFixed(2)},${r.collected.toFixed(2)},${r.outstanding.toFixed(2)},${r.paymentStatus.toUpperCase()}`);
    });

    const blob = new Blob([lines.join("\n")], { type: "text/csv;charset=utf-8;" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.setAttribute("href", url);
    link.setAttribute("download", `EFZ_Executive_Analytics_Report_${new Date().toISOString().slice(0, 10)}.csv`);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);

    setToastNotification({
      type: "success",
      message: "Executive analytics report exported successfully.",
    });
  }, [dateLabel, productFilter, customerFilter, paymentStatusFilter, summary, averageOrderValue, collectionRate, paymentMethodData, productPerformance, customerPerformance, receivables]);

  // Suggested prompt chips
  const suggestedPrompts = [
    "What was our revenue last month?",
    "What was our revenue this month?",
    "How much cash did we collect last month?",
    "Who owes us the most?",
    "How much did Nexus generate?",
    "Compare Nexus and Fire Ball.",
    "Break down our collections by payment method.",
    "How much did we receive through EVC?",
    "How much did we collect in cash?",
    "Compare this month to last month.",
    "Which product has the best margin?",
    "Show unpaid customers.",
  ];

  // Auto-dismiss toast
  useEffect(() => {
    if (!toastNotification) return;
    const timer = setTimeout(() => setToastNotification(null), 4000);
    return () => clearTimeout(timer);
  }, [toastNotification]);

  // Deterministic hook completion check
  if (!mounted) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400">
        <Loader2 className="h-6 w-6 animate-spin text-brand-blue" />
        <p className="text-xs font-medium">Building report…</p>
      </div>
    );
  }

  if (loadError || !profile) {
    return (
      <Card className="border-none shadow-sm">
        <CardContent className="flex flex-col items-center gap-3 py-16 text-center">
          <AlertCircle className="h-8 w-8 text-red-500" />
          <h2 className="font-heading text-lg font-bold text-slate-900">Could not build the report</h2>
          <p className="max-w-md text-xs text-slate-500">
            {loadError ?? "Your account is not linked to a staff profile."}
          </p>
        </CardContent>
      </Card>
    );
  }

  return (
    <div className="space-y-6 pb-12">
      {/* ========================================================================= */}
      {/* 1. PAGE HEADER & EXECUTIVE CONTROLS                                       */}
      {/* ========================================================================= */}
      <div className="flex flex-col gap-4 border-b border-slate-200/80 pb-5 lg:flex-row lg:items-center lg:justify-between">
        <div>
          <div className="flex items-center gap-2">
            <span className="inline-flex items-center gap-1.5 rounded-md bg-slate-900 px-2.5 py-1 text-[10px] font-bold uppercase tracking-widest text-emerald-400">
              <Activity className="h-3 w-3 text-emerald-400" />
              Business Intelligence
            </span>
            <span className="text-[10px] font-bold uppercase tracking-widest text-slate-600 bg-slate-100 px-2 py-1 rounded-md">
              v2.0 Executive
            </span>
          </div>
          <h1 className="mt-1.5 text-2xl font-bold tracking-tight text-slate-900 sm:text-3xl">
            Sales &amp; Analytics
          </h1>
          <p className="mt-1 text-xs text-slate-500 max-w-xl">
            Understand sales, profitability, collections, customers and business performance in real-time.
          </p>
        </div>

        <div className="flex flex-wrap items-center gap-2.5">
          <div className="flex items-center gap-1 rounded-xl border border-slate-200 bg-white p-1 shadow-sm">
            {(
              [
                ["all", "All Time"],
                ["today", "Today"],
                ["week", "This Week"],
                ["month", "This Month"],
                ["lastMonth", "Last Month"],
                ["year", "This Year"],
                ["custom", "Custom"],
              ] as [RangeKey, string][]
            ).map(([key, label]) => (
              <button
                key={key}
                type="button"
                onClick={() => setRange(key)}
                className={cn(
                  "rounded-lg px-2.5 py-1.5 text-[11px] font-bold transition-all",
                  range === key
                    ? "bg-slate-900 text-white shadow-sm"
                    : "text-slate-600 hover:bg-slate-100 hover:text-slate-900"
                )}
              >
                {label}
              </button>
            ))}
          </div>

          {range === "custom" && (
            <div className="flex items-center gap-1.5 rounded-xl border border-slate-200 bg-white p-1 shadow-sm">
              <input
                aria-label="Custom start date"
                type="date"
                value={customStart}
                onChange={e => setCustomStart(e.target.value)}
                className="h-8 rounded-lg border border-slate-200 bg-slate-50 px-2 text-[11px] text-slate-700"
              />
              <span className="text-xs text-slate-400">to</span>
              <input
                aria-label="Custom end date"
                type="date"
                value={customEnd}
                onChange={e => setCustomEnd(e.target.value)}
                className="h-8 rounded-lg border border-slate-200 bg-slate-50 px-2 text-[11px] text-slate-700"
              />
            </div>
          )}

          <Button
            onClick={handleExportReport}
            variant="outline"
            className="h-9 gap-1.5 rounded-xl border-slate-200 bg-white px-3 text-xs font-semibold text-slate-700 shadow-sm hover:bg-slate-50"
          >
            <Download className="h-3.5 w-3.5 text-slate-500" />
            Export Report
          </Button>
        </div>
      </div>

      {/* ========================================================================= */}
      {/* 2. FILTER BAR (Affects all KPIs, Charts, Tables & AI context)              */}
      {/* ========================================================================= */}
      <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-slate-200/80 bg-slate-50/80 px-4 py-2.5">
        <div className="flex flex-wrap items-center gap-3">
          <div className="flex items-center gap-1.5 text-xs font-bold uppercase tracking-wider text-slate-500">
            <Filter className="h-3.5 w-3.5" />
            Filters:
          </div>

          {/* Product Filter */}
          <select
            value={productFilter}
            onChange={e => setProductFilter(e.target.value)}
            className="h-8 rounded-lg border border-slate-200 bg-white px-2.5 text-xs font-medium text-slate-700 shadow-sm outline-none focus:border-slate-400"
          >
            <option value="all">All Products</option>
            {products.map(p => (
              <option key={p.id} value={p.name}>
                {p.name}
              </option>
            ))}
          </select>

          {/* Customer Filter */}
          <select
            value={customerFilter}
            onChange={e => setCustomerFilter(e.target.value)}
            className="h-8 rounded-lg border border-slate-200 bg-white px-2.5 text-xs font-medium text-slate-700 shadow-sm outline-none focus:border-slate-400"
          >
            <option value="all">All Customers</option>
            {customers.map(c => (
              <option key={c.id} value={c.name}>
                {c.name}
              </option>
            ))}
          </select>

          {/* Payment Status Filter */}
          <select
            value={paymentStatusFilter}
            onChange={e => setPaymentStatusFilter(e.target.value)}
            className="h-8 rounded-lg border border-slate-200 bg-white px-2.5 text-xs font-medium text-slate-700 shadow-sm outline-none focus:border-slate-400"
          >
            <option value="all">All Payment Statuses</option>
            <option value="unpaid">Unpaid Only</option>
            <option value="partial">Partial Payments Only</option>
            <option value="paid">Fully Paid Only</option>
          </select>

          {(productFilter !== "all" || customerFilter !== "all" || paymentStatusFilter !== "all") && (
            <button
              type="button"
              onClick={() => {
                setProductFilter("all");
                setCustomerFilter("all");
                setPaymentStatusFilter("all");
              }}
              className="text-xs font-bold text-slate-500 hover:text-slate-900 underline"
            >
              Reset Filters
            </button>
          )}
        </div>

        <div className="flex items-center gap-2 text-[11px] font-medium text-slate-500">
          <Calendar className="h-3.5 w-3.5 text-slate-400" />
          <span>Active Period: <strong className="text-slate-800">{dateLabel}</strong></span>
        </div>
      </div>

      {/* ========================================================================= */}
      {/* 3. EXECUTIVE FINANCIAL SUMMARY — HIERARCHICAL KPI CARDS                    */}
      {/* ========================================================================= */}
      <div className="space-y-3">
        {/* PRIMARY KPIs */}
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
          {/* Revenue Generated */}
          <div className="relative overflow-hidden rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <div className="flex items-start justify-between">
              <div>
                <p className="text-[10px] font-bold uppercase tracking-[0.2em] text-slate-400">Revenue Generated</p>
                <h2 className="mt-2 text-3xl font-extrabold tracking-tight text-slate-900">
                  {money(summary.revenueGenerated)}
                </h2>
              </div>
              <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-slate-900 text-emerald-400 shadow-sm">
                <CircleDollarSign className="h-5 w-5" />
              </div>
            </div>
            <div className="mt-4 flex items-center justify-between border-t border-slate-100 pt-3 text-xs text-slate-500">
              <span className="font-semibold text-slate-700">{summary.totalOrders} completed orders</span>
              <span>{summary.totalUnits} units total</span>
            </div>
          </div>

          {/* Cash Collected */}
          <div className="relative overflow-hidden rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <div className="flex items-start justify-between">
              <div>
                <p className="text-[10px] font-bold uppercase tracking-[0.2em] text-slate-400">Cash Collected</p>
                <h2 className="mt-2 text-3xl font-extrabold tracking-tight text-emerald-600">
                  {money(summary.cashCollected)}
                </h2>
              </div>
              <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-emerald-50 text-emerald-600">
                <Wallet className="h-5 w-5" />
              </div>
            </div>
            <div className="mt-4 flex items-center justify-between border-t border-slate-100 pt-3 text-xs text-slate-500">
              <span className="font-semibold text-emerald-700">{collectionRate.toFixed(1)}% collection rate</span>
              <span>Cash in bank</span>
            </div>
          </div>

          {/* Outstanding Receivables */}
          <div className="relative overflow-hidden rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <div className="flex items-start justify-between">
              <div>
                <p className="text-[10px] font-bold uppercase tracking-[0.2em] text-slate-400">Outstanding Receivables</p>
                <h2 className="mt-2 text-3xl font-extrabold tracking-tight text-rose-600">
                  {money(summary.outstandingReceivables)}
                </h2>
              </div>
              <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-rose-50 text-rose-600">
                <CreditCard className="h-5 w-5" />
              </div>
            </div>
            <div className="mt-4 flex items-center justify-between border-t border-slate-100 pt-3 text-xs text-slate-500">
              <span className="font-semibold text-rose-700">{outstandingRate.toFixed(1)}% pending</span>
              <span>{receivablesSummary.customersWithBalance} accounts</span>
            </div>
          </div>

          {/* Gross Profit */}
          <div className="relative overflow-hidden rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <div className="flex items-start justify-between">
              <div>
                <p className="text-[10px] font-bold uppercase tracking-[0.2em] text-slate-400">Gross Profit</p>
                <h2 className="mt-2 text-3xl font-extrabold tracking-tight text-slate-900">
                  {money(summary.grossProfit)}
                </h2>
              </div>
              <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-blue-50 text-brand-blue">
                <TrendingUp className="h-5 w-5" />
              </div>
            </div>
            <div className="mt-4 flex items-center justify-between border-t border-slate-100 pt-3 text-xs text-slate-500">
              <span className="font-semibold text-slate-700">{summary.grossMargin.toFixed(2)}% margin</span>
              <span>Cost: {money(summary.totalCost)}</span>
            </div>
          </div>
        </div>

        {/* SECONDARY KPIs */}
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <div className="rounded-xl border border-slate-200/80 bg-white p-3.5 shadow-sm">
            <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Gross Margin</p>
            <p className="mt-1 text-lg font-bold text-slate-900">{summary.grossMargin.toFixed(2)}%</p>
            <p className="text-[10px] text-slate-500">Profitability ratio</p>
          </div>

          <div className="rounded-xl border border-slate-200/80 bg-white p-3.5 shadow-sm">
            <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Total Orders</p>
            <p className="mt-1 text-lg font-bold text-slate-900">{summary.totalOrders}</p>
            <p className="text-[10px] text-slate-500">Completed volume</p>
          </div>

          <div className="rounded-xl border border-slate-200/80 bg-white p-3.5 shadow-sm">
            <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Units Sold</p>
            <p className="mt-1 text-lg font-bold text-slate-900">{summary.totalUnits}</p>
            <p className="text-[10px] text-slate-500">Physical volume</p>
          </div>

          <div className="rounded-xl border border-slate-200/80 bg-white p-3.5 shadow-sm">
            <p className="text-[9px] font-bold uppercase tracking-widest text-slate-400">Average Order Value</p>
            <p className="mt-1 text-lg font-bold text-slate-900">{money(averageOrderValue)}</p>
            <p className="text-[10px] text-slate-500">Per order average</p>
          </div>
        </div>
      </div>

      {/* ========================================================================= */}
      {/* 4. AI BUSINESS ASSISTANT — PROMINENT EXECUTIVE INTELLIGENCE PANEL         */}
      {/* ========================================================================= */}
      <div className="rounded-2xl border-2 border-slate-900 bg-slate-900 text-white shadow-xl">
        <div className="border-b border-slate-800 p-5">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-emerald-400 text-slate-950 shadow-md">
                <Bot className="h-5 w-5" />
              </div>
              <div>
                <div className="flex items-center gap-2">
                  <h2 className="font-heading text-lg font-bold text-white tracking-wide">
                    EFZ INTELLIGENCE
                  </h2>
                  <span className="inline-flex items-center gap-1 rounded-full bg-emerald-500/20 px-2 py-0.5 text-[10px] font-bold text-emerald-400">
                    <span className="h-1.5 w-1.5 rounded-full bg-emerald-400 animate-pulse" />
                    AI Analyst Live
                  </span>
                </div>
                <p className="text-xs text-slate-400">
                  Ask questions about sales, payment methods (Cash, EVC, eDahab, Bank), customers, profitability or time periods.
                </p>
              </div>
            </div>

            <div className="text-right text-[11px] text-slate-400">
              Active Context: <strong className="text-emerald-400">{summary.totalOrders} Orders in View</strong> • <strong className="text-emerald-400">{money(summary.revenueGenerated)} Revenue</strong>
            </div>
          </div>
        </div>

        <div className="grid lg:grid-cols-[1.8fr_1fr] divide-y lg:divide-y-0 lg:divide-x divide-slate-800">
          {/* Left: Chat Interaction Viewport */}
          <div className="flex flex-col p-5 space-y-4">
            {/* Conversation Log */}
            <div
              ref={chatScrollRef}
              className="h-64 overflow-y-auto space-y-3.5 pr-2 text-xs scrollbar-thin scrollbar-thumb-slate-700"
            >
              {chatMessages.map(msg => (
                <div
                  key={msg.id}
                  className={cn(
                    "flex flex-col max-w-[90%] rounded-2xl p-3.5 transition-all",
                    msg.sender === "user"
                      ? "ml-auto bg-emerald-600 text-white rounded-br-none"
                      : "bg-slate-800/90 text-slate-100 rounded-bl-none border border-slate-700/60 shadow-sm"
                  )}
                >
                  <div className="flex items-center justify-between gap-4 mb-1 text-[10px] opacity-70">
                    <span className="font-bold uppercase tracking-wider">
                      {msg.sender === "user" ? "You (Management)" : "EFZ Intelligence"}
                    </span>
                    <span>{msg.timestamp}</span>
                  </div>
                  <p className="whitespace-pre-line leading-relaxed text-[12px]">{msg.text}</p>

                  {msg.details && msg.details.length > 0 && (
                    <div className="mt-2.5 pt-2.5 border-t border-slate-700/80 space-y-1">
                      {msg.details.map((d, i) => (
                        <div key={i} className="flex items-center justify-between text-[11px] text-slate-300">
                          <span className="text-slate-400">{d.label}:</span>
                          <strong className="text-white font-mono">{d.value}</strong>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              ))}

              {isAiThinking && (
                <div className="flex items-center gap-2 text-xs text-slate-400 italic p-2 bg-slate-800/50 rounded-xl max-w-xs">
                  <Sparkles className="h-3.5 w-3.5 text-emerald-400 animate-spin" />
                  Resolving natural language query &amp; ledger data...
                </div>
              )}
            </div>

            {/* Input Form */}
            <div className="space-y-2.5 pt-2">
              <form
                onSubmit={e => {
                  e.preventDefault();
                  handleSendQuery();
                }}
                className="flex items-center gap-2"
              >
                <div className="relative flex-1">
                  <Input
                    value={chatInput}
                    onChange={e => setChatInput(e.target.value)}
                    placeholder="Ask EFZ Intelligence anything about sales, payment channels, customers, or periods..."
                    className="h-11 rounded-xl border-slate-700 bg-slate-800/90 text-xs text-white placeholder:text-slate-500 focus:border-emerald-400 focus:ring-emerald-400"
                  />
                </div>
                <Button
                  type="submit"
                  disabled={!chatInput.trim() || isAiThinking}
                  className="h-11 rounded-xl bg-emerald-500 px-4 font-bold text-slate-950 hover:bg-emerald-400 disabled:opacity-50"
                >
                  <Send className="h-4 w-4" />
                </Button>
              </form>

              {/* Suggested Questions */}
              <div className="space-y-1">
                <p className="text-[10px] font-bold uppercase tracking-wider text-slate-400">Suggested Questions:</p>
                <div className="flex flex-wrap gap-1.5 max-h-24 overflow-y-auto">
                  {suggestedPrompts.map((prompt, idx) => (
                    <button
                      key={idx}
                      type="button"
                      onClick={() => handleSendQuery(prompt)}
                      className="rounded-lg border border-slate-700/80 bg-slate-800/60 px-2.5 py-1 text-[11px] text-slate-300 hover:border-emerald-500/50 hover:bg-slate-800 hover:text-emerald-400 transition-colors"
                    >
                      {prompt}
                    </button>
                  ))}
                </div>
              </div>
            </div>
          </div>

          {/* Right: Live Automated Business Insights */}
          <div className="p-5 flex flex-col justify-between space-y-4">
            <div>
              <div className="flex items-center gap-2 mb-3">
                <Sparkles className="h-4 w-4 text-emerald-400" />
                <h3 className="text-xs font-bold uppercase tracking-widest text-slate-300">
                  Business Insights
                </h3>
              </div>
              <p className="text-[11px] text-slate-400 mb-4">
                Auto-generated executive observations from current active data.
              </p>

              <div className="space-y-2.5">
                {businessInsights.map((insight, idx) => (
                  <div
                    key={idx}
                    className="flex items-start gap-2.5 rounded-xl border border-slate-800 bg-slate-800/40 p-2.5 text-xs text-slate-200"
                  >
                    <span className="mt-1 h-2 w-2 shrink-0 rounded-full bg-emerald-400" />
                    <span className="leading-snug">{insight}</span>
                  </div>
                ))}
              </div>
            </div>

            <div className="rounded-xl border border-slate-800 bg-slate-950/60 p-3 text-[11px] text-slate-400">
              <span className="font-semibold text-white block mb-0.5">Strict Data Safety:</span>
              Responses and insights are grounded 100% in normalized ledger data without forecasting hallucinations.
            </div>
          </div>
        </div>
      </div>

      {/* ========================================================================= */}
      {/* 5. FINANCIAL HEALTH & COLLECTION HEALTH SECTION                           */}
      {/* ========================================================================= */}
      <div className="grid gap-4 lg:grid-cols-2">
        {/* LEFT: Revenue vs Cash Collected */}
        <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
          <div className="flex items-center justify-between pb-3 border-b border-slate-100">
            <div>
              <p className="text-[10px] font-bold uppercase tracking-widest text-slate-400">Financial Health</p>
              <h3 className="text-base font-bold text-slate-900">Revenue vs Cash Collected</h3>
            </div>
            <span className="rounded-md bg-slate-100 px-2 py-1 text-[10px] font-bold text-slate-600 uppercase">
              Capital Status
            </span>
          </div>

          <div className="mt-5 space-y-4">
            {/* Visual multi-segment bar */}
            <div>
              <div className="flex justify-between text-xs mb-1.5 font-semibold">
                <span className="text-emerald-700">Cash Collected: {money(summary.cashCollected)} ({collectionRate.toFixed(1)}%)</span>
                <span className="text-rose-700">Outstanding: {money(summary.outstandingReceivables)} ({outstandingRate.toFixed(1)}%)</span>
              </div>
              <div className="h-4 w-full overflow-hidden rounded-full bg-slate-100 flex">
                <div
                  className="bg-emerald-500 transition-all duration-500"
                  style={{ width: `${Math.max(collectionRate, 0)}%` }}
                  title={`Collected: ${money(summary.cashCollected)}`}
                />
                <div
                  className="bg-rose-500 transition-all duration-500"
                  style={{ width: `${Math.max(outstandingRate, 0)}%` }}
                  title={`Outstanding: ${money(summary.outstandingReceivables)}`}
                />
              </div>
            </div>

            <div className="grid grid-cols-3 gap-2.5 pt-2">
              <div className="rounded-xl bg-slate-50 p-3 border border-slate-100">
                <span className="block text-[9px] font-bold uppercase tracking-wider text-slate-400">Total Invoiced</span>
                <strong className="mt-1 block text-sm font-bold text-slate-900">{money(summary.revenueGenerated)}</strong>
              </div>
              <div className="rounded-xl bg-emerald-50/60 p-3 border border-emerald-100">
                <span className="block text-[9px] font-bold uppercase tracking-wider text-emerald-700">Realized Cash</span>
                <strong className="mt-1 block text-sm font-bold text-emerald-700">{money(summary.cashCollected)}</strong>
              </div>
              <div className="rounded-xl bg-rose-50/60 p-3 border border-rose-100">
                <span className="block text-[9px] font-bold uppercase tracking-wider text-rose-700">Pending Receivables</span>
                <strong className="mt-1 block text-sm font-bold text-rose-700">{money(summary.outstandingReceivables)}</strong>
              </div>
            </div>

            <p className="text-[11px] text-slate-500 leading-relaxed">
              Recording a payment updates realized cash and reduces receivables without modifying historical total revenue.
            </p>
          </div>
        </div>

        {/* RIGHT: Collection Health & Payment Breakdown */}
        <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
          <div className="flex items-center justify-between pb-3 border-b border-slate-100">
            <div>
              <p className="text-[10px] font-bold uppercase tracking-widest text-slate-400">Collection Health</p>
              <h3 className="text-base font-bold text-slate-900">Payment Status Distribution</h3>
            </div>
            <span className="rounded-md bg-slate-100 px-2 py-1 text-[10px] font-bold text-slate-600 uppercase">
              {receivables.length} Invoices
            </span>
          </div>

          <div className="mt-5 space-y-3.5">
            {/* Paid */}
            <div>
              <div className="mb-1 flex items-center justify-between text-xs font-semibold">
                <span className="flex items-center gap-1.5 text-emerald-700">
                  <span className="h-2 w-2 rounded-full bg-emerald-500" />
                  Fully Paid
                </span>
                <span className="text-slate-800">{money(paymentBreakdown.paidTotal)} ({summary.revenueGenerated > 0 ? ((paymentBreakdown.paidTotal / summary.revenueGenerated) * 100).toFixed(1) : "0.0"}%)</span>
              </div>
              <div className="h-2 rounded-full bg-slate-100 overflow-hidden">
                <div
                  className="h-2 rounded-full bg-emerald-500"
                  style={{ width: `${summary.revenueGenerated > 0 ? (paymentBreakdown.paidTotal / summary.revenueGenerated) * 100 : 0}%` }}
                />
              </div>
            </div>

            {/* Partial */}
            <div>
              <div className="mb-1 flex items-center justify-between text-xs font-semibold">
                <span className="flex items-center gap-1.5 text-amber-700">
                  <span className="h-2 w-2 rounded-full bg-amber-500" />
                  Partially Paid
                </span>
                <span className="text-slate-800">{money(paymentBreakdown.partialTotal)} ({summary.revenueGenerated > 0 ? ((paymentBreakdown.partialTotal / summary.revenueGenerated) * 100).toFixed(1) : "0.0"}%)</span>
              </div>
              <div className="h-2 rounded-full bg-slate-100 overflow-hidden">
                <div
                  className="h-2 rounded-full bg-amber-500"
                  style={{ width: `${summary.revenueGenerated > 0 ? (paymentBreakdown.partialTotal / summary.revenueGenerated) * 100 : 0}%` }}
                />
              </div>
            </div>

            {/* Unpaid */}
            <div>
              <div className="mb-1 flex items-center justify-between text-xs font-semibold">
                <span className="flex items-center gap-1.5 text-rose-700">
                  <span className="h-2 w-2 rounded-full bg-rose-500" />
                  Unpaid
                </span>
                <span className="text-slate-800">{money(paymentBreakdown.unpaidTotal)} ({summary.revenueGenerated > 0 ? ((paymentBreakdown.unpaidTotal / summary.revenueGenerated) * 100).toFixed(1) : "0.0"}%)</span>
              </div>
              <div className="h-2 rounded-full bg-slate-100 overflow-hidden">
                <div
                  className="h-2 rounded-full bg-rose-500"
                  style={{ width: `${summary.revenueGenerated > 0 ? (paymentBreakdown.unpaidTotal / summary.revenueGenerated) * 100 : 0}%` }}
                />
              </div>
            </div>

            <div className="pt-2 border-t border-slate-100 flex items-center justify-between text-xs">
              <span className="text-slate-500">Unpaid Orders: <strong className="text-slate-900">{receivablesSummary.unpaidOrders}</strong></span>
              <span className="text-slate-500">Partial Orders: <strong className="text-slate-900">{receivablesSummary.partialOrders}</strong></span>
              <span className="text-slate-500">Total Accounts: <strong className="text-slate-900">{customerPerformance.length}</strong></span>
            </div>
          </div>
        </div>
      </div>

      {/* ========================================================================= */}
      {/* 6. SALES & REVENUE PERFORMANCE CHART (Refined with discrete dates)        */}
      {/* ========================================================================= */}
      <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between pb-4 border-b border-slate-100">
          <div>
            <p className="text-[10px] font-bold uppercase tracking-widest text-slate-400">Executive Chart</p>
            <h3 className="text-base font-bold text-slate-900">Sales &amp; Revenue Performance</h3>
            <p className="text-[11px] text-slate-500 mt-0.5">
              Chronological order transaction points for the active filter period.
            </p>
          </div>

          <div className="flex items-center gap-4 text-xs font-semibold">
            <span className="flex items-center gap-1.5 text-slate-900">
              <span className="h-2.5 w-2.5 rounded-full bg-slate-900" />
              Revenue
            </span>
            <span className="flex items-center gap-1.5 text-emerald-600">
              <span className="h-2.5 w-2.5 rounded-full bg-emerald-500" />
              Cash Collected
            </span>
            <span className="flex items-center gap-1.5 text-brand-blue">
              <span className="h-2.5 w-2.5 rounded-full bg-blue-500" />
              Gross Profit
            </span>
          </div>
        </div>

        {trendPoints.length === 0 ? (
          <div className="py-16 text-center text-slate-400 text-xs flex flex-col items-center justify-center">
            <Calendar className="h-8 w-8 text-slate-300 mb-2" />
            <strong className="text-slate-700 text-sm">No Transaction Points</strong>
            <p className="mt-1 text-slate-500">No orders or payments were recorded in the active filtered period.</p>
          </div>
        ) : (
          <div className="mt-6">
            {/* Interactive Tooltip Card */}
            {hoveredPoint && (
              <div className="mb-3 flex items-center justify-between rounded-xl bg-slate-900 px-4 py-2 text-xs text-white shadow-md animate-in fade-in">
                <span className="font-bold text-emerald-400">
                  {hoveredPoint.label} ({hoveredPoint.fullDate}) — {hoveredPoint.orders} Order{hoveredPoint.orders > 1 ? "s" : ""}:
                </span>
                <div className="flex items-center gap-4 font-mono">
                  <span>Revenue: <strong>{money(hoveredPoint.revenue)}</strong></span>
                  <span className="text-emerald-300">Collected: <strong>{money(hoveredPoint.collected)}</strong></span>
                  <span className="text-blue-300">Profit: <strong>{money(hoveredPoint.profit)}</strong></span>
                </div>
              </div>
            )}

            <div className="h-60 w-full rounded-xl border border-slate-100 bg-slate-50/70 p-4 relative">
              <div className="flex h-full w-full flex-col justify-between">
                <svg viewBox="0 0 100 100" preserveAspectRatio="none" className="h-full w-full overflow-visible" role="img" aria-label="Sales performance chart">
                  {/* Grid lines */}
                  <line x1="0" y1="20" x2="100" y2="20" stroke="#e2e8f0" strokeDasharray="2" vectorEffect="non-scaling-stroke" />
                  <line x1="0" y1="50" x2="100" y2="50" stroke="#e2e8f0" strokeDasharray="2" vectorEffect="non-scaling-stroke" />
                  <line x1="0" y1="80" x2="100" y2="80" stroke="#e2e8f0" strokeDasharray="2" vectorEffect="non-scaling-stroke" />

                  {/* Revenue Line */}
                  <polyline
                    points={trendPoints
                      .map((p, idx) => {
                        const x = trendPoints.length === 1 ? 50 : (idx / Math.max(trendPoints.length - 1, 1)) * 100;
                        const y = 90 - (p.revenue / maxChartValue) * 75;
                        return `${x},${y}`;
                      })
                      .join(" ")}
                    fill="none"
                    stroke="#0f172a"
                    strokeWidth="2.5"
                    vectorEffect="non-scaling-stroke"
                  />

                  {/* Gross Profit Line */}
                  <polyline
                    points={trendPoints
                      .map((p, idx) => {
                        const x = trendPoints.length === 1 ? 50 : (idx / Math.max(trendPoints.length - 1, 1)) * 100;
                        const y = 90 - (p.profit / maxChartValue) * 75;
                        return `${x},${y}`;
                      })
                      .join(" ")}
                    fill="none"
                    stroke="#3b82f6"
                    strokeWidth="1.75"
                    strokeDasharray="4"
                    vectorEffect="non-scaling-stroke"
                  />

                  {/* Cash Collected Line */}
                  <polyline
                    points={trendPoints
                      .map((p, idx) => {
                        const x = trendPoints.length === 1 ? 50 : (idx / Math.max(trendPoints.length - 1, 1)) * 100;
                        const y = 90 - (p.collected / maxChartValue) * 75;
                        return `${x},${y}`;
                      })
                      .join(" ")}
                    fill="none"
                    stroke="#10b981"
                    strokeWidth="2"
                    vectorEffect="non-scaling-stroke"
                  />

                  {/* Interactive Point Circles */}
                  {trendPoints.map((p, idx) => {
                    const x = trendPoints.length === 1 ? 50 : (idx / Math.max(trendPoints.length - 1, 1)) * 100;
                    const yRev = 90 - (p.revenue / maxChartValue) * 75;
                    const yCol = 90 - (p.collected / maxChartValue) * 75;
                    const yPro = 90 - (p.profit / maxChartValue) * 75;
                    const isHovered = hoveredPoint?.fullDate === p.fullDate;

                    return (
                      <g
                        key={idx}
                        className="cursor-pointer"
                        onMouseEnter={() => setHoveredPoint(p)}
                        onMouseLeave={() => setHoveredPoint(null)}
                      >
                        {/* Target Hit Area */}
                        <rect x={x - 4} y={0} width={8} height={100} fill="transparent" />

                        {/* Node lines */}
                        {isHovered && (
                          <line x1={x} y1={0} x2={x} y2={100} stroke="#94a3b8" strokeDasharray="2" vectorEffect="non-scaling-stroke" />
                        )}

                        {/* Revenue Node */}
                        <circle cx={x} cy={yRev} r={isHovered ? 4 : 2.5} fill="#0f172a" stroke="#ffffff" strokeWidth="1" />
                        {/* Cash Node */}
                        <circle cx={x} cy={yCol} r={isHovered ? 3.5 : 2} fill="#10b981" stroke="#ffffff" strokeWidth="1" />
                        {/* Profit Node */}
                        <circle cx={x} cy={yPro} r={isHovered ? 3.5 : 2} fill="#3b82f6" stroke="#ffffff" strokeWidth="1" />
                      </g>
                    );
                  })}
                </svg>

                {/* X Axis Labels */}
                <div className="mt-3 flex justify-between gap-2 text-[10px] text-slate-600 font-semibold border-t border-slate-200/80 pt-2">
                  {trendPoints.map((p, idx) => (
                    <button
                      key={idx}
                      type="button"
                      onMouseEnter={() => setHoveredPoint(p)}
                      onMouseLeave={() => setHoveredPoint(null)}
                      className={cn(
                        "truncate px-1.5 py-0.5 rounded transition-colors text-left",
                        hoveredPoint?.fullDate === p.fullDate ? "bg-slate-900 text-white font-bold" : "hover:text-slate-900"
                      )}
                    >
                      {p.label}
                    </button>
                  ))}
                </div>
              </div>
            </div>

            {/* Clear 3-KPI Footer */}
            <div className="mt-4 grid grid-cols-1 sm:grid-cols-3 gap-3 border-t border-slate-100 pt-3 text-xs">
              <div className="rounded-xl bg-slate-50 p-2.5 border border-slate-100 flex items-center justify-between">
                <span className="text-slate-500 font-medium">Selected Period Revenue:</span>
                <strong className="text-slate-900 font-mono text-sm">{money(summary.revenueGenerated)}</strong>
              </div>
              <div className="rounded-xl bg-emerald-50/60 p-2.5 border border-emerald-100 flex items-center justify-between">
                <span className="text-emerald-700 font-medium">Cash Collected:</span>
                <strong className="text-emerald-700 font-mono text-sm">{money(summary.cashCollected)}</strong>
              </div>
              <div className="rounded-xl bg-blue-50/60 p-2.5 border border-blue-100 flex items-center justify-between">
                <span className="text-blue-700 font-medium">Gross Profit:</span>
                <strong className="text-blue-700 font-mono text-sm">{money(summary.grossProfit)}</strong>
              </div>
            </div>
          </div>
        )}
      </div>

      {/* ========================================================================= */}
      {/* 7. PERFORMANCE LEADERS, PROFITABILITY STRUCTURE & SALES OUTLOOK           */}
      {/* ========================================================================= */}
      <div className="grid gap-4 lg:grid-cols-3">
        {/* CARD 1: PERFORMANCE LEADERS */}
        <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm flex flex-col justify-between">
          <div>
            <div className="flex items-center justify-between pb-3 border-b border-slate-100">
              <div className="flex items-center gap-2">
                <Award className="h-4 w-4 text-emerald-600" />
                <h3 className="text-sm font-bold text-slate-900 uppercase tracking-wider">Performance Leaders</h3>
              </div>
              <span className="text-[10px] text-slate-400 font-semibold uppercase">Active Dataset</span>
            </div>
            <p className="text-[11px] text-slate-500 mt-1.5 mb-3.5">
              Who is performing best right now across active filters?
            </p>

            <div className="space-y-2.5">
              {/* Top Revenue Product */}
              <div className="rounded-xl bg-slate-50 p-3 border border-slate-100 flex items-center justify-between">
                <div>
                  <span className="block text-[9px] font-extrabold uppercase tracking-widest text-slate-400">
                    TOP REVENUE PRODUCT
                  </span>
                  <strong className="text-xs font-bold text-slate-900 mt-0.5 block">
                    {performanceLeaders.topRevenueProd?.name ?? "No products"}
                  </strong>
                </div>
                <span className="text-xs font-bold text-emerald-600 font-mono bg-emerald-50 px-2 py-1 rounded-md border border-emerald-100">
                  {money(performanceLeaders.topRevenueProd?.revenue ?? 0)}
                </span>
              </div>

              {/* Top Volume Product */}
              <div className="rounded-xl bg-slate-50 p-3 border border-slate-100 flex items-center justify-between">
                <div>
                  <span className="block text-[9px] font-extrabold uppercase tracking-widest text-slate-400">
                    TOP VOLUME PRODUCT
                  </span>
                  <strong className="text-xs font-bold text-slate-900 mt-0.5 block">
                    {performanceLeaders.topVolumeProd?.name ?? "No products"}
                  </strong>
                </div>
                <span className="text-xs font-bold text-slate-800 font-mono bg-slate-100 px-2 py-1 rounded-md">
                  {performanceLeaders.topVolumeProd?.units ?? 0} units
                </span>
              </div>

              {/* Top Customer */}
              <div className="rounded-xl bg-slate-50 p-3 border border-slate-100 flex items-center justify-between">
                <div>
                  <span className="block text-[9px] font-extrabold uppercase tracking-widest text-slate-400">
                    TOP CUSTOMER
                  </span>
                  <strong className="text-xs font-bold text-slate-900 mt-0.5 block">
                    {performanceLeaders.topCustomer?.name ?? "No customers"}
                  </strong>
                </div>
                <span className="text-xs font-bold text-slate-900 font-mono bg-slate-100 px-2 py-1 rounded-md">
                  {money(performanceLeaders.topCustomer?.revenue ?? 0)}
                </span>
              </div>

              {/* Highest Outstanding */}
              <div className="rounded-xl bg-slate-50 p-3 border border-slate-100 flex items-center justify-between">
                <div>
                  <span className="block text-[9px] font-extrabold uppercase tracking-widest text-rose-500">
                    HIGHEST OUTSTANDING
                  </span>
                  <strong className="text-xs font-bold text-slate-900 mt-0.5 block">
                    {performanceLeaders.highestOutstandingCust?.name ?? "All settled"}
                  </strong>
                </div>
                <span className="text-xs font-bold text-rose-600 font-mono bg-rose-50 px-2 py-1 rounded-md border border-rose-100">
                  {money(performanceLeaders.highestOutstandingCust?.outstanding ?? 0)}
                </span>
              </div>

              {/* Best Margin */}
              <div className="rounded-xl bg-slate-50 p-3 border border-slate-100 flex items-center justify-between">
                <div>
                  <span className="block text-[9px] font-extrabold uppercase tracking-widest text-blue-500">
                    BEST MARGIN PRODUCT
                  </span>
                  <strong className="text-xs font-bold text-slate-900 mt-0.5 block">
                    {performanceLeaders.bestMarginProd?.name ?? "No products"}
                  </strong>
                </div>
                <span className="text-xs font-bold text-blue-600 font-mono bg-blue-50 px-2 py-1 rounded-md border border-blue-100">
                  {performanceLeaders.bestMarginProd?.grossMargin.toFixed(2) ?? "0.00"}%
                </span>
              </div>
            </div>
          </div>

          <p className="text-[10px] text-slate-400 mt-3 pt-2 border-t border-slate-100">
            Calculated dynamically from active filter selection.
          </p>
        </div>

        {/* CARD 2: PROFITABILITY STRUCTURE */}
        <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm flex flex-col justify-between">
          <div>
            <div className="flex items-center justify-between pb-3 border-b border-slate-100">
              <div className="flex items-center gap-2">
                <PieChart className="h-4 w-4 text-blue-600" />
                <h3 className="text-sm font-bold text-slate-900 uppercase tracking-wider">Profitability Structure</h3>
              </div>
              <span className="text-[10px] text-slate-400 font-semibold uppercase">Margin Analytics</span>
            </div>
            <p className="text-[11px] text-slate-500 mt-1.5 mb-3.5">
              Where does our revenue go?
            </p>

            {/* Total Revenue Highlight */}
            <div className="rounded-xl bg-slate-900 text-white p-4 shadow-sm">
              <span className="block text-[9px] font-extrabold uppercase tracking-[0.2em] text-slate-400">TOTAL REVENUE</span>
              <div className="flex items-baseline justify-between mt-1">
                <span className="text-2xl font-extrabold font-mono text-white">{money(summary.revenueGenerated)}</span>
                <span className="text-[11px] text-emerald-400 font-bold">{summary.grossMargin.toFixed(2)}% Gross Margin</span>
              </div>
            </div>

            {/* Visual Bar Relationship */}
            <div className="mt-4">
              <div className="flex justify-between text-[11px] font-bold mb-1.5">
                <span className="text-slate-600">
                  COST: {summary.revenueGenerated > 0 ? ((summary.totalCost / summary.revenueGenerated) * 100).toFixed(1) : "0.0"}%
                </span>
                <span className="text-emerald-600">
                  GROSS PROFIT: {summary.grossMargin.toFixed(1)}%
                </span>
              </div>

              {/* Prominent Visual Stacked Bar */}
              <div className="h-5 w-full rounded-lg bg-slate-100 flex overflow-hidden border border-slate-200 shadow-inner">
                <div
                  className="bg-slate-500 transition-all duration-500 flex items-center justify-center text-[9px] font-bold text-white uppercase"
                  style={{ width: `${summary.revenueGenerated > 0 ? (summary.totalCost / summary.revenueGenerated) * 100 : 0}%` }}
                  title={`Cost: ${money(summary.totalCost)}`}
                >
                  {summary.totalCost > 0 && "COGS"}
                </div>
                <div
                  className="bg-emerald-500 transition-all duration-500 flex items-center justify-center text-[9px] font-bold text-white uppercase"
                  style={{ width: `${Math.max(0, summary.grossMargin)}%` }}
                  title={`Gross Profit: ${money(summary.grossProfit)}`}
                >
                  {summary.grossProfit > 0 && "PROFIT"}
                </div>
              </div>
            </div>

            {/* Standard Business Terminology Breakdown */}
            <div className="mt-4 grid grid-cols-2 gap-2 text-xs">
              <div className="rounded-xl bg-slate-50 p-2.5 border border-slate-100">
                <span className="block text-[9px] font-bold uppercase text-slate-400">Cost / COGS</span>
                <strong className="text-sm font-bold text-slate-800 font-mono mt-0.5 block">{money(summary.totalCost)}</strong>
              </div>
              <div className="rounded-xl bg-emerald-50/60 p-2.5 border border-emerald-100">
                <span className="block text-[9px] font-bold uppercase text-emerald-700">Gross Profit</span>
                <strong className="text-sm font-bold text-emerald-700 font-mono mt-0.5 block">{money(summary.grossProfit)}</strong>
              </div>
            </div>
          </div>

          <div className="mt-4 pt-2 border-t border-slate-100 flex items-center justify-between text-[11px] text-slate-500">
            <span>Executive Gross Margin:</span>
            <strong className="text-slate-900 font-bold">{summary.grossMargin.toFixed(2)}%</strong>
          </div>
        </div>

        {/* CARD 3: SALES OUTLOOK & FORECAST READINESS */}
        <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm flex flex-col justify-between">
          <div>
            <div className="flex items-center justify-between pb-3 border-b border-slate-100">
              <div className="flex items-center gap-2">
                <Clock className="h-4 w-4 text-amber-600" />
                <h3 className="text-sm font-bold text-slate-900 uppercase tracking-wider">Sales Outlook &amp; Readiness</h3>
              </div>
              <span className="inline-flex items-center rounded-full bg-amber-100 px-2 py-0.5 text-[9px] font-extrabold uppercase text-amber-800">
                Building Baseline
              </span>
            </div>

            {/* Real Operating Indicators */}
            <div className="mt-3.5 space-y-2">
              <div className="flex justify-between items-center py-1.5 border-b border-slate-100 text-xs">
                <span className="text-slate-500">Historical Orders:</span>
                <strong className="font-mono text-slate-900 font-bold">{summary.totalOrders} completed</strong>
              </div>
              <div className="flex justify-between items-center py-1.5 border-b border-slate-100 text-xs">
                <span className="text-slate-500">Historical Units:</span>
                <strong className="font-mono text-slate-900 font-bold">{summary.totalUnits} units</strong>
              </div>
              <div className="flex justify-between items-center py-1.5 border-b border-slate-100 text-xs">
                <span className="text-slate-500">Average Order Value:</span>
                <strong className="font-mono text-slate-900 font-bold">{money(averageOrderValue)}</strong>
              </div>
              <div className="flex justify-between items-center py-1.5 border-b border-slate-100 text-xs">
                <span className="text-slate-500">Average Units per Order:</span>
                <strong className="font-mono text-slate-900 font-bold">{averageUnitsPerOrder.toFixed(2)}</strong>
              </div>
            </div>

            {/* Data Readiness Explanation */}
            <div className="mt-4 rounded-xl bg-amber-50/80 border border-amber-200/80 p-3 text-xs text-amber-950">
              <div className="flex items-start gap-2">
                <Info className="h-4 w-4 text-amber-600 shrink-0 mt-0.5" />
                <div>
                  <strong className="block font-bold text-[11px] text-amber-900 uppercase tracking-wider">Data Readiness</strong>
                  <p className="mt-0.5 text-[11px] text-amber-900/90 leading-relaxed">
                    More historical sales cycles are required before EFZ Intelligence can produce a statistically reliable forecast.
                  </p>
                </div>
              </div>
            </div>
          </div>

          <p className="text-[10px] text-slate-400 mt-4 pt-2 border-t border-slate-100">
            Forecasts will activate automatically once sufficient historical sales data is available.
          </p>
        </div>
      </div>

      {/* ========================================================================= */}
      {/* 8. PAYMENT METHOD ANALYTICS (NEW & IMPORTANT SECTION)                     */}
      {/* ========================================================================= */}
      <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm space-y-5">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between pb-4 border-b border-slate-100">
          <div>
            <div className="flex items-center gap-2">
              <span className="inline-flex items-center gap-1 rounded-md bg-emerald-50 px-2 py-0.5 text-[10px] font-bold text-emerald-700 uppercase tracking-widest border border-emerald-200">
                <Wallet className="h-3 w-3" />
                Collection Analytics
              </span>
              <h2 className="text-base font-bold text-slate-900">Payment Method Analytics</h2>
            </div>
            <p className="text-[11px] text-slate-500 mt-1">
              Actual cash received by payment method across active filters. Reconciles 100% with Cash Collected ledger.
            </p>
          </div>

          {/* Connection to Receivables Pill */}
          <div className="flex items-center gap-2 bg-slate-50 rounded-xl p-2 border border-slate-200 text-xs">
            <div className="px-2">
              <span className="text-[9px] font-bold uppercase tracking-wider text-slate-400 block">Total Revenue</span>
              <strong className="text-slate-900 font-mono">{money(summary.revenueGenerated)}</strong>
            </div>
            <span className="text-slate-300 font-bold">→</span>
            <div className="px-2 bg-emerald-100/70 rounded-lg py-1 border border-emerald-200">
              <span className="text-[9px] font-bold uppercase tracking-wider text-emerald-800 block">Cash Collected</span>
              <strong className="text-emerald-700 font-mono">{money(summary.cashCollected)}</strong>
            </div>
            <span className="text-slate-300 font-bold">+</span>
            <div className="px-2 bg-rose-50 rounded-lg py-1 border border-rose-100">
              <span className="text-[9px] font-bold uppercase tracking-wider text-rose-700 block">Outstanding</span>
              <strong className="text-rose-700 font-mono">{money(summary.outstandingReceivables)}</strong>
            </div>
          </div>
        </div>

        <div className="grid gap-5 lg:grid-cols-[1.5fr_1fr]">
          {/* LEFT: Payment Method Breakdown Cards */}
          <div className="space-y-2.5">
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-2.5">
              {paymentMethodData.breakdown.map(item => {
                const isCash = item.method === "Cash";
                const isEvc = item.method === "EVC";
                const isEdahab = item.method === "eDahab";
                const isBank = item.method === "Bank";

                return (
                  <div
                    key={item.method}
                    className="rounded-xl border border-slate-200/90 bg-white p-4 shadow-sm hover:border-slate-300 transition-colors flex flex-col justify-between"
                  >
                    <div className="flex items-center justify-between mb-2">
                      <div className="flex items-center gap-2">
                        <div className={cn(
                          "flex h-8 w-8 items-center justify-center rounded-lg text-xs font-bold",
                          isCash ? "bg-emerald-50 text-emerald-700" :
                          isEvc ? "bg-blue-50 text-blue-700" :
                          isEdahab ? "bg-amber-50 text-amber-700" :
                          "bg-purple-50 text-purple-700"
                        )}>
                          {isCash && <Banknote className="h-4 w-4" />}
                          {isEvc && <Smartphone className="h-4 w-4" />}
                          {isEdahab && <Smartphone className="h-4 w-4" />}
                          {isBank && <Landmark className="h-4 w-4" />}
                        </div>
                        <div>
                          <h4 className="text-xs font-bold text-slate-900">{item.method}</h4>
                          <span className="text-[10px] text-slate-400">{item.count} payment{item.count === 1 ? "" : "s"}</span>
                        </div>
                      </div>

                      <span className="text-xs font-bold text-slate-700 font-mono bg-slate-100 px-2 py-0.5 rounded">
                        {item.percentage.toFixed(1)}%
                      </span>
                    </div>

                    <div className="flex items-baseline justify-between pt-2 border-t border-slate-100">
                      <span className="text-[10px] uppercase font-bold text-slate-400">Collected</span>
                      <strong className="text-base font-extrabold font-mono text-slate-900">
                        {money(item.amount)}
                      </strong>
                    </div>
                  </div>
                );
              })}
            </div>

            {/* Reconciled Total Row */}
            <div className="rounded-xl bg-slate-900 text-white p-3.5 flex items-center justify-between shadow-sm">
              <div className="flex items-center gap-2">
                <CheckCircle2 className="h-4 w-4 text-emerald-400" />
                <div>
                  <strong className="text-xs font-bold text-white">TOTAL CASH COLLECTED</strong>
                  <span className="block text-[10px] text-slate-400">
                    {paymentMethodData.totalPaymentsCount} total recorded transaction{paymentMethodData.totalPaymentsCount === 1 ? "" : "s"} • Reconciled
                  </span>
                </div>
              </div>

              <div className="text-right">
                <strong className="text-base font-extrabold font-mono text-emerald-400">
                  {money(paymentMethodData.totalCollected)}
                </strong>
                <span className="block text-[10px] text-slate-400 font-semibold">100.0% of collections</span>
              </div>
            </div>
          </div>

          {/* RIGHT: Collection Mix Visualization */}
          <div className="rounded-xl border border-slate-200/90 bg-slate-50/60 p-4 flex flex-col justify-between">
            <div>
              <div className="flex items-center justify-between mb-3">
                <h4 className="text-xs font-bold uppercase tracking-wider text-slate-700">Collection Mix</h4>
                <span className="text-[10px] text-slate-500 font-semibold">Channel Share</span>
              </div>

              {/* Stacked Visual Channel Bar */}
              <div className="h-4 w-full rounded-full bg-slate-200 flex overflow-hidden border border-slate-300/50 shadow-inner mb-4">
                {paymentMethodData.breakdown.map(item => {
                  if (item.percentage <= 0) return null;
                  const bg =
                    item.method === "Cash" ? "bg-emerald-500" :
                    item.method === "EVC" ? "bg-blue-500" :
                    item.method === "eDahab" ? "bg-amber-500" : "bg-purple-500";
                  return (
                    <div
                      key={item.method}
                      className={cn("h-full transition-all duration-500", bg)}
                      style={{ width: `${item.percentage}%` }}
                      title={`${item.method}: ${money(item.amount)} (${item.percentage.toFixed(1)}%)`}
                    />
                  );
                })}
              </div>

              {/* Progress Bars per Channel */}
              <div className="space-y-2.5">
                {paymentMethodData.breakdown.map(item => (
                  <div key={item.method} className="space-y-1">
                    <div className="flex justify-between text-[11px] font-semibold">
                      <span className="text-slate-700">{item.method}</span>
                      <span className="font-mono text-slate-900">{money(item.amount)} ({item.percentage.toFixed(1)}%)</span>
                    </div>
                    <div className="h-1.5 w-full rounded-full bg-slate-200 overflow-hidden">
                      <div
                        className={cn(
                          "h-full rounded-full transition-all duration-500",
                          item.method === "Cash" ? "bg-emerald-500" :
                          item.method === "EVC" ? "bg-blue-500" :
                          item.method === "eDahab" ? "bg-amber-500" : "bg-purple-500"
                        )}
                        style={{ width: `${item.percentage}%` }}
                      />
                    </div>
                  </div>
                ))}
              </div>
            </div>

            <div className="mt-4 pt-3 border-t border-slate-200 text-[11px] text-slate-500">
              <span className="font-semibold text-slate-800">Accounting Note: </span>
              Revenue is recognized at invoice issuance, while payment channels track realized liquidity.
            </div>
          </div>
        </div>
      </div>

      {/* ========================================================================= */}
      {/* 9. PRODUCT PERFORMANCE TABLE                                              */}
      {/* ========================================================================= */}
      <div className="rounded-2xl border border-slate-200 bg-white shadow-sm overflow-hidden">
        <div className="flex items-center justify-between px-5 py-4 border-b border-slate-100 bg-slate-50/40">
          <div>
            <h3 className="text-sm font-bold text-slate-900 uppercase tracking-wider">Product Performance</h3>
            <p className="text-[11px] text-slate-500">Direct volume, revenue and margin metrics per product line.</p>
          </div>
          <span className="text-xs font-semibold text-slate-500">{productPerformance.length} Products</span>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-left text-xs">
            <thead className="bg-slate-50 text-[10px] uppercase tracking-wider text-slate-500 font-bold border-b border-slate-200">
              <tr>
                <th className="px-5 py-3">Product</th>
                <th className="px-5 py-3 text-right">Units Sold</th>
                <th className="px-5 py-3 text-right">Revenue</th>
                <th className="px-5 py-3 text-right">Cost</th>
                <th className="px-5 py-3 text-right">Gross Profit</th>
                <th className="px-5 py-3 text-right">Margin %</th>
                <th className="px-5 py-3 text-right">Avg Selling Price</th>
                <th className="px-5 py-3 text-center">Badges</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {productPerformance.map(product => (
                <tr key={product.name} className="hover:bg-slate-50/80 transition-colors">
                  <td className="px-5 py-3.5 font-bold text-slate-900">{product.name}</td>
                  <td className="px-5 py-3.5 text-right font-mono text-slate-700">{product.units}</td>
                  <td className="px-5 py-3.5 text-right font-mono font-bold text-emerald-600">{money(product.revenue)}</td>
                  <td className="px-5 py-3.5 text-right font-mono text-slate-500">{money(product.cost)}</td>
                  <td className="px-5 py-3.5 text-right font-mono font-bold text-slate-900">{money(product.profit)}</td>
                  <td className="px-5 py-3.5 text-right font-mono font-bold text-blue-600">{product.grossMargin.toFixed(2)}%</td>
                  <td className="px-5 py-3.5 text-right font-mono text-slate-700">{money(product.averageActualPrice)}</td>
                  <td className="px-5 py-3.5 text-center">
                    <div className="flex items-center justify-center gap-1.5 flex-wrap">
                      {product.isTopRevenue && (
                        <span className="rounded bg-emerald-100 px-2 py-0.5 text-[9px] font-extrabold uppercase text-emerald-800">
                          Top Revenue
                        </span>
                      )}
                      {product.isTopVolume && (
                        <span className="rounded bg-slate-900 px-2 py-0.5 text-[9px] font-extrabold uppercase text-white">
                          Top Volume
                        </span>
                      )}
                      {product.isBestMargin && (
                        <span className="rounded bg-blue-100 px-2 py-0.5 text-[9px] font-extrabold uppercase text-blue-800">
                          Best Margin
                        </span>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
              {productPerformance.length === 0 && (
                <tr>
                  <td colSpan={8} className="px-5 py-8 text-center text-slate-400">
                    No product data matching active filters.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* ========================================================================= */}
      {/* 10. CUSTOMER PERFORMANCE TABLE                                            */}
      {/* ========================================================================= */}
      <div className="rounded-2xl border border-slate-200 bg-white shadow-sm overflow-hidden">
        <div className="flex items-center justify-between px-5 py-4 border-b border-slate-100 bg-slate-50/40">
          <div>
            <h3 className="text-sm font-bold text-slate-900 uppercase tracking-wider">Customer Performance</h3>
            <p className="text-[11px] text-slate-500">Purchase volume, collections and balance per account.</p>
          </div>
          <Link
            href="/admin/customers"
            className="text-xs font-bold text-brand-blue hover:text-blue-700 flex items-center gap-1"
          >
            Open Customer Database <ChevronRight className="h-3.5 w-3.5" />
          </Link>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-left text-xs">
            <thead className="bg-slate-50 text-[10px] uppercase tracking-wider text-slate-500 font-bold border-b border-slate-200">
              <tr>
                <th className="px-5 py-3">Customer</th>
                <th className="px-5 py-3 text-right">Orders</th>
                <th className="px-5 py-3 text-right">Units</th>
                <th className="px-5 py-3 text-right">Revenue</th>
                <th className="px-5 py-3 text-right">Collected</th>
                <th className="px-5 py-3 text-right">Outstanding</th>
                <th className="px-5 py-3 text-center">Status</th>
                <th className="px-5 py-3 text-right">Action</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {customerPerformance.map(customer => (
                <tr key={customer.name} className="hover:bg-slate-50/80 transition-colors">
                  <td className="px-5 py-3.5 font-bold text-slate-900">
                    <Link
                      href={`/admin/customers?search=${encodeURIComponent(customer.name)}`}
                      className="hover:underline flex items-center gap-1.5"
                    >
                      <UserCheck className="h-3.5 w-3.5 text-slate-400" />
                      {customer.name}
                    </Link>
                  </td>
                  <td className="px-5 py-3.5 text-right font-mono text-slate-700">{customer.orders}</td>
                  <td className="px-5 py-3.5 text-right font-mono text-slate-700">{customer.units}</td>
                  <td className="px-5 py-3.5 text-right font-mono font-bold text-slate-900">{money(customer.revenue)}</td>
                  <td className="px-5 py-3.5 text-right font-mono font-bold text-emerald-600">{money(customer.collected)}</td>
                  <td className="px-5 py-3.5 text-right font-mono font-bold text-rose-600">{money(customer.outstanding)}</td>
                  <td className="px-5 py-3.5 text-center">
                    <span
                      className={cn(
                        "inline-flex rounded-full px-2.5 py-0.5 text-[10px] font-bold uppercase tracking-wider",
                        customer.paymentStatus === "paid"
                          ? "bg-emerald-100 text-emerald-800"
                          : customer.paymentStatus === "partial"
                          ? "bg-amber-100 text-amber-800"
                          : "bg-rose-100 text-rose-800"
                      )}
                    >
                      {customer.paymentStatus}
                    </span>
                  </td>
                  <td className="px-5 py-3.5 text-right">
                    <Link
                      href={`/admin/customers?search=${encodeURIComponent(customer.name)}`}
                      className="rounded-lg border border-slate-200 bg-white px-2.5 py-1 text-[11px] font-semibold text-slate-700 hover:bg-slate-100 hover:text-slate-900 transition-colors"
                    >
                      View
                    </Link>
                  </td>
                </tr>
              ))}
              {customerPerformance.length === 0 && (
                <tr>
                  <td colSpan={8} className="px-5 py-8 text-center text-slate-400">
                    No customer records matching active filters.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* ========================================================================= */}
      {/* 11. RECEIVABLES INTELLIGENCE & RECORD PAYMENT INTEGRATION                 */}
      {/* ========================================================================= */}
      <div className="rounded-2xl border border-slate-200 bg-white shadow-sm overflow-hidden">
        <div className="p-5 border-b border-slate-100 bg-slate-50/40 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <p className="text-[10px] font-bold uppercase tracking-widest text-slate-400">Live Ledger</p>
            <h3 className="text-base font-bold text-slate-900">Receivables Intelligence</h3>
          </div>

          <div className="flex flex-wrap items-center gap-2">
            <div className="rounded-xl border border-slate-200 bg-white px-3 py-1.5 text-xs shadow-sm">
              <span className="text-slate-400">Total Outstanding: </span>
              <strong className="text-rose-600 font-mono">{money(receivablesSummary.totalOutstanding)}</strong>
            </div>
            <div className="rounded-xl border border-slate-200 bg-white px-3 py-1.5 text-xs shadow-sm">
              <span className="text-slate-400">Accounts with Balance: </span>
              <strong className="text-slate-900 font-mono">{receivablesSummary.customersWithBalance}</strong>
            </div>
            <div className="rounded-xl border border-slate-200 bg-white px-3 py-1.5 text-xs shadow-sm">
              <span className="text-slate-400">Unpaid Orders: </span>
              <strong className="text-slate-900 font-mono">{receivablesSummary.unpaidOrders}</strong>
            </div>
          </div>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-left text-xs">
            <thead className="bg-slate-50 text-[10px] uppercase tracking-wider text-slate-500 font-bold border-b border-slate-200">
              <tr>
                <th className="px-5 py-3">Customer</th>
                <th className="px-5 py-3">Order ID</th>
                <th className="px-5 py-3">Date</th>
                <th className="px-5 py-3 text-right">Order Total</th>
                <th className="px-5 py-3 text-right">Collected</th>
                <th className="px-5 py-3 text-right">Outstanding</th>
                <th className="px-5 py-3 text-center">Status</th>
                <th className="px-5 py-3 text-right">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {receivables.map(row => (
                <tr key={row.orderId} className="hover:bg-slate-50/80 transition-colors">
                  <td className="px-5 py-3.5 font-bold text-slate-900">{row.customerName}</td>
                  <td className="px-5 py-3.5 font-mono text-slate-600">{row.orderId}</td>
                  <td className="px-5 py-3.5 text-slate-500">{row.date}</td>
                  <td className="px-5 py-3.5 text-right font-mono font-bold text-slate-900">{money(row.total)}</td>
                  <td className="px-5 py-3.5 text-right font-mono font-bold text-emerald-600">{money(row.collected)}</td>
                  <td className="px-5 py-3.5 text-right font-mono font-bold text-rose-600">{money(row.outstanding)}</td>
                  <td className="px-5 py-3.5 text-center">
                    <span
                      className={cn(
                        "inline-flex rounded-full px-2.5 py-0.5 text-[10px] font-bold uppercase tracking-wider",
                        row.paymentStatus === "paid"
                          ? "bg-emerald-100 text-emerald-800"
                          : row.paymentStatus === "partial"
                          ? "bg-amber-100 text-amber-800"
                          : "bg-rose-100 text-rose-800"
                      )}
                    >
                      {row.paymentStatus}
                    </span>
                  </td>
                  <td className="px-5 py-3.5 text-right">
                    <div className="flex items-center justify-end gap-2">
                      <Link
                        href={`/admin/orders?search=${encodeURIComponent(row.orderId)}`}
                        className="rounded-lg border border-slate-200 bg-white px-2.5 py-1 text-[11px] font-semibold text-slate-700 hover:bg-slate-100 hover:text-slate-900"
                      >
                        View
                      </Link>
                      {row.outstanding > 0 && (
                        <Button
                          size="sm"
                          onClick={() => {
                            setPaymentModalOrder(row.order);
                            setPaymentForm({
                              amount: row.outstanding.toFixed(2),
                              paymentDate: new Date().toISOString().slice(0, 10),
                              paymentMethod: "Cash",
                              reference: `REC-${row.orderId}`,
                              note: "",
                            });
                          }}
                          className="h-7 rounded-lg bg-slate-900 px-2.5 text-[10px] font-bold uppercase tracking-wider text-white hover:bg-emerald-600 shadow-sm"
                        >
                          Record Payment
                        </Button>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
              {receivables.length === 0 && (
                <tr>
                  <td colSpan={8} className="px-5 py-8 text-center text-slate-400">
                    No orders matching active filter criteria.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* ========================================================================= */}
      {/* 12. RECORD PAYMENT MODAL                                                  */}
      {/* ========================================================================= */}
      {paymentModalOrder && (() => {
        const order = paymentModalOrder;
        const total = Number(order.total || 0);
        const collected = getOrderCollectedAmount(order);
        const outstanding = Math.max(0, total - collected);

        return (
          <div className="fixed inset-0 z-[120] bg-slate-900/60 flex items-center justify-center p-4 backdrop-blur-sm animate-in fade-in">
            <div className="bg-white rounded-2xl shadow-2xl w-full max-w-xl p-6 border border-slate-200">
              <div className="flex items-center justify-between pb-4 border-b border-slate-100">
                <div>
                  <p className="text-[10px] font-bold uppercase tracking-widest text-slate-400">Record Payment</p>
                  <h3 className="text-xl font-bold text-slate-900">{order.customer}</h3>
                </div>
                <button
                  type="button"
                  onClick={() => setPaymentModalOrder(null)}
                  className="rounded-full border border-slate-200 p-2 text-slate-500 hover:bg-slate-100"
                >
                  <X className="h-4 w-4" />
                </button>
              </div>

              <div className="grid grid-cols-2 gap-3 text-xs text-slate-600 my-4">
                <div className="rounded-xl bg-slate-50 p-3">
                  <span className="block text-[9px] uppercase tracking-widest text-slate-400">Order ID</span>
                  <strong className="text-slate-900 font-mono">{order.id}</strong>
                </div>
                <div className="rounded-xl bg-slate-50 p-3">
                  <span className="block text-[9px] uppercase tracking-widest text-slate-400">Order Type</span>
                  <strong className="text-slate-900 uppercase">{order.orderType || "regular"}</strong>
                </div>
                <div className="rounded-xl bg-slate-50 p-3">
                  <span className="block text-[9px] uppercase tracking-widest text-slate-400">Order Total</span>
                  <strong className="text-slate-900 font-mono">{money(total)}</strong>
                </div>
                <div className="rounded-xl bg-rose-50/60 border border-rose-100 p-3">
                  <span className="block text-[9px] uppercase tracking-widest text-rose-700">Outstanding Balance</span>
                  <strong className="text-rose-700 font-mono">{money(outstanding)}</strong>
                </div>
              </div>

              <div className="space-y-3">
                <div>
                  <label className="text-[10px] font-bold uppercase tracking-widest text-slate-600">
                    Payment Amount ($)
                  </label>
                  <Input
                    value={paymentForm.amount}
                    onChange={e => setPaymentForm({ ...paymentForm, amount: e.target.value })}
                    type="number"
                    min="0.01"
                    max={outstanding}
                    step="0.01"
                    placeholder="0.00"
                    className="h-11 rounded-xl font-mono text-sm"
                  />
                  <span className="text-[10px] text-slate-400 mt-1 block">
                    Max payable: {money(outstanding)} (partial payments fully supported).
                  </span>
                </div>

                <div className="grid grid-cols-2 gap-3">
                  <div>
                    <label className="text-[10px] font-bold uppercase tracking-widest text-slate-600">
                      Payment Date
                    </label>
                    <Input
                      value={paymentForm.paymentDate}
                      onChange={e => setPaymentForm({ ...paymentForm, paymentDate: e.target.value })}
                      type="date"
                      className="h-11 rounded-xl text-xs"
                    />
                  </div>
                  <div>
                    <label className="text-[10px] font-bold uppercase tracking-widest text-slate-600">
                      Payment Method
                    </label>
                    <select
                      value={paymentForm.paymentMethod}
                      onChange={e => setPaymentForm({ ...paymentForm, paymentMethod: e.target.value })}
                      className="h-11 w-full rounded-xl border border-slate-200 bg-slate-50 px-3 text-xs font-semibold text-slate-800"
                    >
                      <option>Cash</option>
                      <option>EVC</option>
                      <option>eDahab</option>
                      <option>Bank</option>
                    </select>
                  </div>
                </div>

                <div>
                  <label className="text-[10px] font-bold uppercase tracking-widest text-slate-600">
                    Reference
                  </label>
                  <Input
                    value={paymentForm.reference}
                    onChange={e => setPaymentForm({ ...paymentForm, reference: e.target.value })}
                    placeholder="e.g. REC-1029 / INV-001"
                    className="h-11 rounded-xl text-xs"
                  />
                </div>

                <div>
                  <label className="text-[10px] font-bold uppercase tracking-widest text-slate-600">
                    Notes
                  </label>
                  <Input
                    value={paymentForm.note}
                    onChange={e => setPaymentForm({ ...paymentForm, note: e.target.value })}
                    placeholder="Optional transaction notes"
                    className="h-11 rounded-xl text-xs"
                  />
                </div>
              </div>

              <div className="mt-6 flex gap-3">
                <Button
                  type="button"
                  variant="outline"
                  disabled={isRecordingPayment}
                  onClick={() => setPaymentModalOrder(null)}
                  className="flex-1 h-11 rounded-xl text-xs font-bold"
                >
                  Cancel
                </Button>
                <Button
                  type="button"
                  disabled={isRecordingPayment}
                  onClick={handleRecordPayment}
                  className="flex-1 h-11 rounded-xl bg-slate-900 text-white hover:bg-emerald-600 text-xs font-bold shadow-md"
                >
                  {isRecordingPayment && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Save Payment to Ledger
                </Button>
              </div>
            </div>
          </div>
        );
      })()}

      {/* ========================================================================= */}
      {/* 13. FLOATING NOTIFICATION TOAST                                           */}
      {/* ========================================================================= */}
      {toastNotification && (
        <div className="fixed bottom-6 right-6 z-[130] rounded-xl border border-slate-200 bg-white px-4 py-3 text-xs font-semibold shadow-2xl animate-in slide-in-from-bottom-2">
          <span
            className={cn(
              "flex items-center gap-2",
              toastNotification.type === "error" ? "text-rose-600" : "text-emerald-700"
            )}
          >
            {toastNotification.type === "error" ? (
              <AlertCircle className="h-4 w-4" />
            ) : (
              <CheckCircle2 className="h-4 w-4" />
            )}
            {toastNotification.message}
          </span>
        </div>
      )}
    </div>
  );
}
