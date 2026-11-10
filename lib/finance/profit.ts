/**
 * Profit chain (Phase 14, expenses). One pure function over the same sales dataset and the same gross-profit figures as the
 * Financial page (lib/finance/model periodFigures), so nothing is computed twice and nothing can disagree.
 *
 *   Gross profit        = Delivered revenue - COGS                          (unchanged; COGS = delivered balls x order_items.historical_unit_cost)
 *   Contribution profit = Gross profit - Direct order expenses - Direct expenses on cancelled orders - Commissions
 *   Net operating profit = Contribution profit - Operating expenses (approved, by expense date)
 *
 * Rules (also in docs/EXPENSE_MANAGEMENT.md):
 *  - COGS comes only from the frozen unit cost. Inventory purchases are NOT expenses (no such category exists), so stock is never costed twice.
 *  - Only APPROVED, non-void expenses count. Payment status is irrelevant to profit (approval = the cost; payment = cash).
 *  - Direct order expenses belong to the period of their order's sales date (order_date), like the order's revenue.
 *  - A direct expense on a CANCELLED order earned no revenue: it is its own line, dated by its expense date, never dropped.
 *  - Commissions come from the commission records (never from manual expenses): non-void, earned, dated by earned_at (legacy rows
 *    without it: the order's delivery date, then its order date) in the period. Not-yet-earned rows are counted but not deducted.
 *  - Operating expenses are company-level. Under a filter (product, customer, officer...) they are ALLOCATED by the filtered share of the
 *    period's delivered revenue; the result is labelled "allocated" and never stored.
 *  - Per order / per product: direct expenses are exact (per product: split by delivered-revenue share within the order); commissions
 *    on the order (per product: per-ball kinds by delivered units, others by delivered revenue); operating expenses allocated by delivered
 *    revenue share of the period. Nothing is persisted, so a later expense never rewrites a past allocation.
 *  - Cost withheld from the user (can_view_cost) -> every profit figure is null, never zero.
 * Money is in cents.
 */

import type { CommissionCost, ExpenseCost } from "@/lib/types";
import { efzToday } from "@/lib/dates";
import { isSale, select, toCents, type Dataset, type SalesFilters, type SalesLine } from "@/lib/analytics/dataset";
import { inRange, type DateRange } from "@/lib/analytics/period";
import { lineDeliveredCents, lineDeliveredCostCents, lineRevenueCents } from "./model";

const efzDateOf = (timestamp: string): string => efzToday(new Date(timestamp));
const PER_BALL_KINDS = new Set(["delivery", "correction"]);

export type ProfitChain = {
  deliveredRevenueCents: number;
  cogsCents: number | null;
  grossProfitCents: number | null;
  directExpensesCents: number;
  cancelledOrderExpensesCents: number;
  commissionsCents: number;
  contributionProfitCents: number | null;
  operatingExpensesCents: number;
  /** 1 without filters; the filtered share of the period's delivered revenue otherwise (the operating expenses are then allocated). */
  operatingShare: number;
  allocated: boolean;
  netOperatingProfitCents: number | null;
  /** Information, never deducted: earned = false commissions in the period's orders, and commission rows flagged for review. */
  commissionsNotYetEarnedCents: number;
  commissionsUnderReviewCents: number;
  /** Margins on delivered revenue (null when revenue or cost is missing). */
  contributionMarginPct: number | null;
  netMarginPct: number | null;
};

export type OrderProfitRow = {
  orderId: string;
  customerName: string;
  date: string;
  deliveredRevenueCents: number;
  cogsCents: number | null;
  grossProfitCents: number | null;
  directExpensesCents: number;
  commissionsCents: number;
  contributionProfitCents: number | null;
  allocatedOperatingCents: number;
  netProfitCents: number | null;
};

export type ProductProfitChainRow = {
  productKey: string;
  productName: string;
  deliveredUnits: number;
  deliveredRevenueCents: number;
  cogsCents: number | null;
  grossProfitCents: number | null;
  directExpensesCents: number;
  commissionsCents: number;
  contributionProfitCents: number | null;
  allocatedOperatingCents: number;
  netProfitCents: number | null;
};

export type ProfitModel = { chain: ProfitChain; orders: OrderProfitRow[]; products: ProductProfitChainRow[] };

export type ProfitInput = {
  ds: Dataset;
  filters: SalesFilters;
  range: DateRange;
  expenses: ExpenseCost[];
  commissions: CommissionCost[];
};

const sum = (xs: number[]) => xs.reduce((a, b) => a + b, 0);
/** Splits `total` cents over `weights` so the parts add up to the total exactly (largest remainder). */
export function splitCents(total: number, weights: number[]): number[] {
  const w = weights.map((x) => (x > 0 ? x : 0));
  const denominator = sum(w);
  if (total === 0 || w.length === 0) return w.map(() => 0);
  if (denominator === 0) {
    const even = Math.floor(total / w.length);
    const out = w.map(() => even);
    out[0] += total - even * w.length;
    return out;
  }
  const raw = w.map((x) => (total * x) / denominator);
  const parts = raw.map((r) => Math.floor(r));
  let left = total - sum(parts);
  const order = raw.map((r, i) => ({ i, frac: r - Math.floor(r) })).sort((a, b) => b.frac - a.frac || a.i - b.i);
  for (const { i } of order) { if (left <= 0) break; parts[i] += 1; left -= 1; }
  return parts;
}

const pct = (n: number | null, d: number): number | null => (n === null || d <= 0 ? null : (n / d) * 100);

export function profitModel({ ds, filters, range, expenses, commissions }: ProfitInput): ProfitModel {
  const selected = select(ds, filters, range);
  const selectedIds = new Set(selected.map((s) => s.order.id));
  const productFiltered = filters.productKey !== null;

  // Orders passing the non-date filters (for commissions dated by earned_at and for cancelled-order expenses).
  const orderIdsAnyDate = new Set(select(ds, filters, null).map((s) => s.order.id));
  const orderById = new Map(ds.orders.map((o) => [o.id, o]));
  const hasFilter = filters.productKey !== null || filters.customerId !== null || filters.officerId !== null || filters.orderType !== "all" || filters.status !== "all";

  // ---- revenue and cost (the same bases as periodFigures) ----
  let delivered = 0, cost = 0, costKnown = true;
  for (const { lines } of selected) {
    for (const l of lines) {
      delivered += lineDeliveredCents(l);
      const c = lineDeliveredCostCents(l);
      if (c === null) costKnown = false; else cost += c;
    }
  }
  const gross = costKnown ? delivered - cost : null;

  // ---- period delivered revenue, unfiltered, for the allocation share ----
  let periodDelivered = 0;
  for (const { lines } of select(ds, { ...filters, productKey: null, customerId: null, officerId: null, orderType: "all", status: "all" }, range)) {
    for (const l of lines) periodDelivered += lineDeliveredCents(l);
  }
  const share = !hasFilter ? 1 : periodDelivered > 0 ? delivered / periodDelivered : 0;

  // ---- expenses ----
  const direct = expenses.filter((e) => e.kind === "direct_order" && e.orderId);
  const operating = expenses.filter((e) => e.kind === "operating");
  // order-level revenue basis for splitting an order's direct expense across product lines
  const orderBasis = (orderId: string, lines: SalesLine[]) => {
    const o = orderById.get(orderId);
    const full = o ? o.lines : lines;
    const dRev = sum(full.map(lineDeliveredCents));
    return dRev > 0 ? { total: dRev, of: lineDeliveredCents } : { total: sum(full.map(lineRevenueCents)), of: lineRevenueCents };
  };
  let directCents = 0;
  const directByOrder = new Map<string, number>();
  for (const e of direct) {
    if (!e.orderId || !selectedIds.has(e.orderId)) continue;
    const sel = selected.find((s) => s.order.id === e.orderId);
    let part = toCents(e.amount);
    if (productFiltered && sel) {
      const basis = orderBasis(e.orderId, sel.lines);
      const mine = sum(sel.lines.map(basis.of));
      part = basis.total > 0 ? Math.round((part * mine) / basis.total) : 0;
    }
    directCents += part;
    directByOrder.set(e.orderId, (directByOrder.get(e.orderId) ?? 0) + part);
  }
  // direct expenses on cancelled orders: their own line, by expense date, under the same non-date filters (a product filter cannot apply)
  let cancelledCents = 0;
  for (const e of direct) {
    if (!e.orderId) continue;
    const o = orderById.get(e.orderId);
    const cancelled = (o ? !isSale(o) : e.orderStatus === "cancelled");
    if (!cancelled || !inRange(e.expenseDate, range)) continue;
    if (hasFilter) {
      if (productFiltered) continue;
      if (filters.customerId !== null && o?.customerId !== filters.customerId) continue;
      if (filters.officerId !== null && (filters.officerId === "__unassigned__" ? o?.officerId !== null : o?.officerId !== filters.officerId)) continue;
      if (filters.orderType !== "all" && o?.orderType !== filters.orderType) continue;
      if (filters.status !== "all") continue;
    }
    cancelledCents += toCents(e.amount);
  }
  const operatingTotal = sum(operating.filter((e) => inRange(e.expenseDate, range)).map((e) => toCents(e.amount)));
  const operatingCents = Math.round(operatingTotal * share);

  // ---- commissions (dated by earned_at; counted once, from the commission records) ----
  let commissionCents = 0, notEarned = 0, underReview = 0;
  const commissionByOrder = new Map<string, CommissionCost[]>();
  for (const c of commissions) {
    if (!orderIdsAnyDate.has(c.orderId)) continue;
    const list = commissionByOrder.get(c.orderId) ?? [];
    list.push(c);
    commissionByOrder.set(c.orderId, list);
    if (!c.earned) { if (selectedIds.has(c.orderId)) notEarned += toCents(c.amount); continue; }
    if (!inRange(efzDateOf(c.attributedAt), range)) continue;
    let amount = toCents(c.amount);
    if (productFiltered) {
      const o = orderById.get(c.orderId);
      const mine = o ? o.lines.filter((l) => l.productKey === filters.productKey) : [];
      const all = o ? o.lines : [];
      const unitsMine = sum(mine.map((l) => l.delivered)), unitsAll = sum(all.map((l) => l.delivered));
      const revMine = sum(mine.map(lineDeliveredCents)), revAll = sum(all.map(lineDeliveredCents));
      amount = PER_BALL_KINDS.has(c.kind) ? (unitsAll > 0 ? Math.round((amount * unitsMine) / unitsAll) : 0) : (revAll > 0 ? Math.round((amount * revMine) / revAll) : 0);
    }
    commissionCents += amount;
    if (c.reviewRequired) underReview += amount;
  }

  const contribution = gross === null ? null : gross - directCents - cancelledCents - commissionCents;
  const net = contribution === null ? null : contribution - operatingCents;
  const chain: ProfitChain = {
    deliveredRevenueCents: delivered, cogsCents: costKnown ? cost : null, grossProfitCents: gross,
    directExpensesCents: directCents, cancelledOrderExpensesCents: cancelledCents, commissionsCents: commissionCents,
    contributionProfitCents: contribution, operatingExpensesCents: operatingCents, operatingShare: share, allocated: hasFilter && operatingTotal > 0,
    netOperatingProfitCents: net, commissionsNotYetEarnedCents: notEarned, commissionsUnderReviewCents: underReview,
    contributionMarginPct: pct(contribution, delivered), netMarginPct: pct(net, delivered),
  };

  // ---- per order ----
  const orderRevenues = selected.map((s) => sum(s.lines.map(lineDeliveredCents)));
  const allocOp = splitCents(operatingCents, orderRevenues);
  const orders: OrderProfitRow[] = selected.map((s, i) => {
    const dRev = orderRevenues[i];
    const cogs = s.lines.every((l) => lineDeliveredCostCents(l) !== null) ? sum(s.lines.map((l) => lineDeliveredCostCents(l) as number)) : null;
    const gp = cogs === null ? null : dRev - cogs;
    const dir = directByOrder.get(s.order.id) ?? 0;
    const comm = sum((commissionByOrder.get(s.order.id) ?? []).filter((c) => c.earned).map((c) => toCents(c.amount)));
    const contributionRow = gp === null ? null : gp - dir - comm;
    return {
      orderId: s.order.id, customerName: s.order.customerName, date: s.order.date, deliveredRevenueCents: dRev, cogsCents: cogs, grossProfitCents: gp,
      directExpensesCents: dir, commissionsCents: comm, contributionProfitCents: contributionRow, allocatedOperatingCents: allocOp[i],
      netProfitCents: contributionRow === null ? null : contributionRow - allocOp[i],
    };
  });

  // ---- per product ----
  type Acc = { name: string; units: number; rev: number; cogs: number; costKnown: boolean; direct: number; comm: number };
  const acc = new Map<string, Acc>();
  for (const s of selected) {
    const basis = orderBasis(s.order.id, s.lines);
    const orderDirect = directByOrder.get(s.order.id) ?? 0;
    const orderComm = (commissionByOrder.get(s.order.id) ?? []).filter((c) => c.earned);
    const lineDirect = splitCents(orderDirect, s.lines.map(basis.of));
    const unitW = s.lines.map((l) => l.delivered), revW = s.lines.map(lineDeliveredCents);
    const perBall = sum(orderComm.filter((c) => PER_BALL_KINDS.has(c.kind)).map((c) => toCents(c.amount)));
    const other = sum(orderComm.filter((c) => !PER_BALL_KINDS.has(c.kind)).map((c) => toCents(c.amount)));
    const lineComm = splitCents(perBall, unitW).map((v, k) => v + splitCents(other, revW)[k]);
    s.lines.forEach((l, k) => {
      const a = acc.get(l.productKey) ?? { name: l.productName, units: 0, rev: 0, cogs: 0, costKnown: true, direct: 0, comm: 0 };
      a.units += l.delivered; a.rev += lineDeliveredCents(l);
      const c = lineDeliveredCostCents(l);
      if (c === null) a.costKnown = false; else a.cogs += c;
      a.direct += lineDirect[k]; a.comm += lineComm[k];
      acc.set(l.productKey, a);
    });
  }
  const keys = [...acc.keys()];
  const prodOp = splitCents(operatingCents, keys.map((k) => acc.get(k)!.rev));
  const products: ProductProfitChainRow[] = keys.map((k, i) => {
    const a = acc.get(k)!;
    const gp = a.costKnown ? a.rev - a.cogs : null;
    const contributionRow = gp === null ? null : gp - a.direct - a.comm;
    return {
      productKey: k, productName: a.name, deliveredUnits: a.units, deliveredRevenueCents: a.rev, cogsCents: a.costKnown ? a.cogs : null,
      grossProfitCents: gp, directExpensesCents: a.direct, commissionsCents: a.comm, contributionProfitCents: contributionRow,
      allocatedOperatingCents: prodOp[i], netProfitCents: contributionRow === null ? null : contributionRow - prodOp[i],
    };
  }).sort((x, y) => y.deliveredRevenueCents - x.deliveredRevenueCents || x.productName.localeCompare(y.productName));

  return { chain, orders, products };
}
