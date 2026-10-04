/**
 * The Sales & Analytics model: every number the page, the charts, the export
 * and the Business Assistant show comes from buildAnalyticsModel(). Nothing is
 * computed a second way anywhere else.
 */

import { type Dataset, type SalesFilters } from "./dataset";
import { concentration, customerPerformance, newVsReturning, newVsReturningSeries, trialConversion, type Concentration, type CustomerRow, type NewReturning, type NewReturningPoint, type TrialConversion } from "./customers";
import { STOCK_OUT_ALERT_DAYS, stockCover, type StockRow } from "./inventory";
import { officerBreakdown, type OfficerRow } from "./officers";
import { dataSufficiency, runRate, velocity, type RunRate, type Sufficiency, type Velocity } from "./outlook";
import { autoGranularity, comparisonRange, formatRange, resolvePeriod, type DateRange, type Granularity, type Period, type PeriodPreset } from "./period";
import { pipeline, type Pipeline } from "./pipeline";
import { overallRealization, productPerformance, type ProductRow } from "./products";
import { change, computeKpis, cumulativeMonth, salesSeries, type CumulativePoint, type Kpis, type SeriesPoint } from "./sales";

export type AnalyticsInput = {
  ds: Dataset;
  filters: SalesFilters;
  preset: PeriodPreset;
  custom?: { from?: string; to?: string };
  compare: boolean;
  today: string;
  granularity?: Granularity | "auto";
};

export type AttentionItem = { id: string; severity: "high" | "medium"; title: string; detail: string; section: string };

export type AnalyticsModel = {
  today: string;
  period: Period;
  periodText: string;
  comparison: (DateRange & { label: string; text: string }) | null;
  filters: SalesFilters;
  granularity: Granularity;
  kpis: Kpis;
  comparisonKpis: Kpis | null;
  series: SeriesPoint[];
  cumulative: CumulativePoint[];
  products: ProductRow[];
  realization: { realizationPct: number | null; discountCents: number };
  customers: CustomerRow[];
  concentration: Concentration;
  newReturning: NewReturning;
  newReturningSeries: NewReturningPoint[];
  trials: TrialConversion;
  officers: OfficerRow[];
  pipeline: Pipeline;
  velocity: Velocity;
  runRate: RunRate;
  sufficiency: Sufficiency;
  stock: StockRow[];
  attention: AttentionItem[];
};

export const ATTENTION_RULES = {
  openOrderAgeDays: 14,
  concentrationPct: 50,
  trialFollowUpDays: 30,
  revenueDropPct: 25,
  stockOutDays: STOCK_OUT_ALERT_DAYS,
} as const;

export function buildAnalyticsModel(input: AnalyticsInput): AnalyticsModel {
  const { ds, filters: f, today } = input;
  const period = resolvePeriod(input.preset, today, { custom: input.custom, firstSaleDate: ds.firstSaleDate });
  const cmp = input.compare ? comparisonRange(period) : null;
  const granularity = !input.granularity || input.granularity === "auto" ? autoGranularity(period) : input.granularity;
  // A comparison window entirely before the first sale has nothing to compare with.
  const comparisonUsable = cmp !== null && ds.firstSaleDate !== null && cmp.to >= ds.firstSaleDate;
  const kpis = computeKpis(ds, f, period);
  const comparisonKpis = comparisonUsable ? computeKpis(ds, f, cmp!) : null;
  const products = productPerformance(ds, f, period);
  const customers = customerPerformance(ds, f, period);
  const rr = runRate(ds, f, today);
  const model: AnalyticsModel = {
    today,
    period,
    periodText: formatRange(period),
    comparison: comparisonUsable ? { ...cmp!, text: formatRange(cmp!) } : null,
    filters: f,
    granularity,
    kpis,
    comparisonKpis,
    series: salesSeries(ds, f, period, granularity),
    cumulative: cumulativeMonth(ds, f, today, rr.available ? rr.paceDailyCents : null),
    products,
    realization: overallRealization(products),
    customers,
    concentration: concentration(customers),
    newReturning: newVsReturning(customers),
    newReturningSeries: newVsReturningSeries(ds, f, period, granularity),
    trials: trialConversion(ds, f, today),
    officers: officerBreakdown(ds, f, period),
    pipeline: pipeline(ds, f, today),
    velocity: velocity(ds, f, today),
    runRate: rr,
    sufficiency: dataSufficiency(ds, today),
    stock: stockCover(ds, today, f.productKey),
    attention: [],
  };
  model.attention = attentionItems(model);
  return model;
}

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;

/** Deterministic rules; the thresholds are ATTENTION_RULES. At most five items. */
export function attentionItems(m: AnalyticsModel): AttentionItem[] {
  const items: AttentionItem[] = [];
  // Sales attention only: a product with no open orders and no booked sales in
  // 28 days is an Inventory matter, not a sales one.
  const inDemand = m.stock.filter((s) => s.commitments > 0 || s.unitsLast28 > 0);
  const short = inDemand.filter((s) => s.state === "shortfall");
  if (short.length) {
    items.push({ id: "stock-short", severity: "high", section: "inventory",
      title: `${plural(short.length, "product")} cannot cover open orders`,
      detail: short.slice(0, 3).map((s) => `${s.name}: short by ${-s.available}`).join("; ") });
  }
  const out = inDemand.filter((s) => s.state === "out");
  if (out.length) {
    items.push({ id: "stock-out", severity: "high", section: "inventory",
      title: `${plural(out.length, "product")} with recent demand ${out.length === 1 ? "has" : "have"} nothing available`,
      detail: out.slice(0, 3).map((s) => `${s.name}: ${s.unitsLast28} booked in 28 days, 0 available`).join("; ") });
  }
  const risk = inDemand.filter((s) => s.state === "at_risk" || s.state === "low");
  if (risk.length) {
    items.push({ id: "stock-risk", severity: "medium", section: "inventory",
      title: `${plural(risk.length, "product")} at or near the low-stock threshold`,
      detail: risk.slice(0, 3).map((s) => (s.stockOutDate && s.state === "at_risk" ? `${s.name}: indicative stock-out ${s.stockOutDate}` : `${s.name}: ${s.available} available, threshold ${s.threshold}`)).join("; ") });
  }
  const aged = m.pipeline.orders.filter((o) => o.ageDays > ATTENTION_RULES.openOrderAgeDays);
  if (aged.length) {
    items.push({ id: "aged-orders", severity: "medium", section: "pipeline",
      title: `${plural(aged.length, "open order")} older than ${ATTENTION_RULES.openOrderAgeDays} days`,
      detail: `Oldest: ${aged[0].orderId} (${aged[0].customerName}), ${aged[0].ageDays} days, ${aged[0].remainingUnits} ball(s) still to deliver.` });
  }
  const named = m.customers.filter((c) => c.customerId !== null);
  if (named.length >= 2 && m.concentration.top1Pct > ATTENTION_RULES.concentrationPct) {
    items.push({ id: "concentration", severity: "medium", section: "customers",
      title: `One customer holds ${m.concentration.top1Pct.toFixed(0)}% of booked revenue`,
      detail: `${named[0].name} in ${m.periodText}.` });
  }
  const followUp = m.trials.notConverted.filter((t) => t.daysSinceTrial > ATTENTION_RULES.trialFollowUpDays);
  if (followUp.length) {
    items.push({ id: "trials", severity: "medium", section: "customers",
      title: `${plural(followUp.length, "trial customer")} with no regular order after ${ATTENTION_RULES.trialFollowUpDays} days`,
      detail: followUp.slice(0, 3).map((t) => `${t.name} (trial ${t.trialDate})`).join("; ") });
  }
  if (m.sufficiency.level !== "limited" && m.sufficiency.level !== "none" && m.comparisonKpis && m.comparison) {
    const c = change(m.kpis.bookedCents, m.comparisonKpis.bookedCents);
    if (c && c.pct !== null && c.pct <= -ATTENTION_RULES.revenueDropPct) {
      items.push({ id: "revenue-drop", severity: "medium", section: "trends",
        title: `Booked revenue ${Math.abs(c.pct).toFixed(0)}% below the comparison period`,
        detail: `${m.periodText} vs ${m.comparison.text}.` });
    }
  }
  return items.slice(0, 5);
}
