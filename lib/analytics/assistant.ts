/**
 * The EFZ Business Assistant: rule-based, in the browser, no external service.
 *
 * Every answer is built from buildAnalyticsModel() (the same model the page
 * shows) or from lib/finance/facts.ts over the same dataset. This file must
 * never contain a business figure, customer name or product name of its own:
 * the Phase 13 tests scan it for money literals.
 *
 * Financial questions are answered here (owner decision D3) even though the
 * page itself keeps detailed finance for the future Financial page. When the
 * data needed does not exist or is not available to the user, the answer says
 * so instead of estimating.
 */

import { addDaysYmd } from "@/lib/dates";
import { money } from "@/lib/commission";
import { fromCents, hasNarrowingFilter, productKeyOf, type Dataset, type SalesFilters } from "./dataset";
import { buildAnalyticsModel, type AnalyticsModel } from "./model";
import { MONTH_NAMES, comparisonRange, daysInMonth, formatRange, monthEnd, shiftMonth, weekStart, ymd, type PeriodPreset } from "./period";
import { STATUS_LABEL } from "./pipeline";
import { STOCK_STATE_LABEL } from "./inventory";
import { change, computeKpis } from "./sales";
import { grossProfit, outstandingBalances, outstandingByAge, paymentsReceived } from "@/lib/finance/facts";

export type AssistantDetail = { label: string; value: string };
export type AssistantAnswer = { intent: string; text: string; details?: AssistantDetail[] };

export type AssistantContext = {
  ds: Dataset;
  filters: SalesFilters;
  preset: PeriodPreset;
  custom?: { from?: string; to?: string };
  today: string;
  /** The model currently on screen (same inputs as the page). */
  model: AnalyticsModel;
  /** Mirrors has_all_order_scope(): the officer breakdown is shown. */
  canSeeOfficers: boolean;
};

export const SUGGESTED_QUESTIONS = [
  "What are our sales this month?",
  "How much revenue is delivered vs booked?",
  "What is our best-selling product?",
  "Which customers are driving revenue?",
  "Which products are moving fastest?",
  "What is our current sales pipeline?",
  "What might month-end sales look like?",
  "Which products are at risk based on current sales velocity?",
  "Which Marketing Officer generated the most sales?",
  "Who owes us the most?",
  "How much cash did we receive this month?",
  "What should management pay attention to?",
];

const $ = (cents: number) => money(fromCents(cents));
const pct = (v: number | null, digits = 1) => (v === null ? "n/a" : `${v.toFixed(digits)}%`);
const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? "" : "s"}`;
const has = (q: string, ...words: string[]) => words.some((w) => q.includes(w));

// ---------------------------------------------------------------------------
// Period in the question (EAT business dates)
// ---------------------------------------------------------------------------

export type QuestionPeriod = { from: string; to: string; label: string; preset?: PeriodPreset };

export function periodFromQuestion(q: string, today: string): QuestionPeriod | null {
  const y = Number(today.slice(0, 4));
  if (/\btoday\b/.test(q)) return { from: today, to: today, label: "today", preset: "today" };
  if (/\byesterday\b/.test(q)) { const d = addDaysYmd(today, -1); return { from: d, to: d, label: "yesterday" }; }
  if (/\bthis week\b/.test(q)) return { from: weekStart(today), to: today, label: "this week", preset: "week" };
  if (/\blast week\b/.test(q)) { const s = addDaysYmd(weekStart(today), -7); return { from: s, to: addDaysYmd(s, 6), label: "last week" }; }
  if (/\b(this month|month to date|mtd)\b/.test(q)) return { from: `${today.slice(0, 8)}01`, to: today, label: "this month", preset: "month" };
  if (/\blast month\b/.test(q)) { const s = shiftMonth(today, -1); return { from: s, to: monthEnd(s), label: "last month", preset: "lastMonth" }; }
  if (/\b(this year|year to date|ytd)\b/.test(q)) return { from: `${y}-01-01`, to: today, label: "this year", preset: "year" };
  if (/\blast year\b/.test(q)) return { from: `${y - 1}-01-01`, to: `${y - 1}-12-31`, label: `${y - 1}` };
  const lastN = q.match(/\b(?:last|past) (\d{1,3}) days?\b/);
  if (lastN) { const n = Math.max(1, Number(lastN[1])); return { from: addDaysYmd(today, -(n - 1)), to: today, label: `the last ${n} days` }; }
  if (/\b(all time|ever|overall|since (we )?start(ed)?)\b/.test(q)) return { from: "0000-01-01", to: today, label: "all time", preset: "all" };
  for (let i = 0; i < 12; i++) {
    const name = MONTH_NAMES[i];
    // "may" is also an ordinary word: only "in/for/during may" or "may 2026".
    const re = name === "may" ? /\b(?:in|for|during) may\b|\bmay \d{4}\b/ : new RegExp(`\\b${name}\\b`);
    if (!re.test(q)) continue;
    const yearMatch = q.match(new RegExp(`${name} (\\d{4})`));
    let year = yearMatch ? Number(yearMatch[1]) : y;
    if (!yearMatch && ymd(year, i + 1, 1) > today) year -= 1; // a month still ahead means last year's
    const from = ymd(year, i + 1, 1);
    const to = ymd(year, i + 1, daysInMonth(year, i + 1));
    return { from, to: to > today ? today : to, label: `${name[0].toUpperCase()}${name.slice(1)} ${year}` };
  }
  return null;
}

// ---------------------------------------------------------------------------
// Entity matching (always resolved to an id)
// ---------------------------------------------------------------------------

function matchCustomers(q: string, ds: Dataset): { id: string; name: string }[] {
  const hits = ds.customers.filter((c) => c.name && c.name.trim().length >= 3 && q.includes(c.name.trim().toLowerCase()));
  if (hits.length === 0) return [];
  const longest = Math.max(...hits.map((c) => c.name.trim().length));
  return hits.filter((c) => c.name.trim().length === longest).map((c) => ({ id: c.id, name: c.name.trim() }));
}

function matchProduct(q: string, ds: Dataset): { key: string; name: string } | null {
  const names = new Map<string, string>();
  for (const p of ds.products) names.set(productKeyOf(p.id, p.name), p.name);
  for (const o of ds.orders) for (const l of o.lines) if (!names.has(l.productKey)) names.set(l.productKey, l.productName);
  let best: { key: string; name: string; len: number } | null = null;
  for (const [key, name] of names) {
    const full = name.toLowerCase().trim();
    const short = full.replace(/^efz\s*-\s*/, "");
    for (const candidate of [full, short]) {
      if (candidate.length >= 3 && q.includes(candidate) && (!best || candidate.length > best.len)) best = { key, name, len: candidate.length };
    }
  }
  return best ? { key: best.key, name: best.name } : null;
}

// ---------------------------------------------------------------------------
// Answers
// ---------------------------------------------------------------------------

function scopeNote(ctx: AssistantContext): string {
  return hasNarrowingFilter(ctx.filters) ? " (with the page filters applied)" : "";
}

function modelFor(ctx: AssistantContext, explicit: QuestionPeriod | null): { m: AnalyticsModel; label: string } {
  if (!explicit) return { m: ctx.model, label: `${ctx.model.period.label.toLowerCase()} (${ctx.model.periodText})` };
  const m = buildAnalyticsModel({ ds: ctx.ds, filters: ctx.filters, preset: explicit.preset ?? "custom", custom: { from: explicit.from, to: explicit.to }, compare: false, today: ctx.today });
  return { m, label: `${explicit.label} (${m.periodText})` };
}

function salesSummary(m: AnalyticsModel, label: string, note: string): AssistantAnswer {
  const k = m.kpis;
  if (k.orders === 0) return { intent: "sales", text: `No sales were booked in ${label}${note}.` };
  return {
    intent: "sales",
    text: `Sales for ${label}${note}: delivered revenue (actual) ${$(k.deliveredCents)} and booked revenue ${$(k.bookedCents)} across ${plural(k.orders, "order")}. ${k.undeliveredCents > 0 ? `${$(k.undeliveredCents)} of the booked value is still to be delivered.` : "Everything booked has been delivered."}`,
    details: [
      { label: "Delivered revenue (actual)", value: $(k.deliveredCents) },
      { label: "Booked revenue", value: $(k.bookedCents) },
      { label: "Orders", value: `${k.orders} (${k.fullyDeliveredOrders} fully delivered)` },
      { label: "Units delivered / booked", value: `${k.deliveredUnits} / ${k.bookedUnits}` },
      { label: "Average order value (booked)", value: k.aovCents === null ? "n/a" : $(k.aovCents) },
      { label: "Buying customers", value: `${k.buyingCustomers}` },
    ],
  };
}

export function answerQuestion(question: string, ctx: AssistantContext): AssistantAnswer {
  const q = question.toLowerCase().replace(/\s+/g, " ").trim();
  if (!q) return help();
  const explicit = periodFromQuestion(q, ctx.today);
  const { m, label } = modelFor(ctx, explicit);
  const note = scopeNote(ctx);
  const customers = matchCustomers(q, ctx.ds);
  const product = matchProduct(q, ctx.ds);

  if (/^(help|\?|what can you (do|answer)|what can i ask)/.test(q)) return help();

  // --- Data sufficiency ------------------------------------------------------
  if (has(q, "sufficien", "how much history", "enough data", "enough history", "how reliable", "data quality")) {
    const s = ctx.model.sufficiency;
    return {
      intent: "sufficiency",
      text: `${s.label}: ${s.historyDays} days of history and ${plural(s.orders, "order")} (${s.completeMonths} complete month${s.completeMonths === 1 ? "" : "s"}). ${s.explanation} ${s.next ?? ""} This is an operational indicator of how much history exists, not a measure of statistical reliability.`.trim(),
    };
  }

  // --- Stock risk ------------------------------------------------------------
  if (has(q, "run out", "running out", "stock-out", "stockout", "out of stock", "at risk", "days of cover", "stock", "inventory", "reorder")) {
    const rows = product ? ctx.model.stock.filter((s) => s.productKey === product.key) : ctx.model.stock;
    if (rows.length === 0) return { intent: "stock", text: product ? `${product.name} is not an active product with stock records.` : "There are no active products to assess." };
    const risky = rows.filter((s) => s.state !== "ok" && s.state !== "slow");
    const list = (product ? rows : risky.length ? risky : rows).slice(0, 6);
    return {
      intent: "stock",
      text: product
        ? `${rows[0].name}: ${rows[0].available} available after open-order commitments (${rows[0].stock} on hand, ${rows[0].commitments} committed). ${rows[0].daysOfCover === null ? "No booked sales in the last 28 days, so no stock-out date can be projected." : `At ${rows[0].velocity28.toFixed(2)} balls/day (28-day pace) that is about ${Math.floor(rows[0].daysOfCover)} days of cover, indicative stock-out ${rows[0].stockOutDate}.`}`
        : risky.length
          ? `${plural(risky.length, "product")} need attention based on the 28-day sales pace (indicative): ${risky.slice(0, 3).map((s) => `${s.name} (${STOCK_STATE_LABEL[s.state].toLowerCase()})`).join(", ")}.`
          : "No product is projected to run out within 14 days at the current 28-day pace (indicative).",
      details: list.map((s) => ({ label: s.name, value: `${s.available} available · ${s.velocity28.toFixed(2)}/day · ${s.daysOfCover === null ? "no recent demand" : `${Math.floor(s.daysOfCover)} days cover`} · ${STOCK_STATE_LABEL[s.state]}` })),
    };
  }

  // --- Outlook / forecast ----------------------------------------------------
  if (has(q, "forecast", "month-end", "month end", "end of the month", "end of month", "project", "predict", "expect", "run rate", "run-rate", "outlook", "might")) {
    if (has(q, "next year", "12 months", "6 months", "six months", "next quarter", "long term", "long-term", "season")) {
      const s = ctx.model.sufficiency;
      return { intent: "forecast-long", text: `I can't give a longer-range forecast. EFZ has ${s.historyDays} days of sales history (${s.label.toLowerCase()}), which is not enough to model trends or seasonality, and I won't invent one. I can show the current pace and an indicative month-end range.` };
    }
    const r = ctx.model.runRate;
    const s = ctx.model.sufficiency;
    if (!r.available) return { intent: "forecast", text: `No month-end projection yet: ${r.reason} Booked so far this month: ${$(r.monthToDateCents)} (day ${r.daysElapsed} of ${r.daysInMonth})${note}.` };
    return {
      intent: "forecast",
      text: `Indicative month-end booked sales${note}: ${$(r.lowCents)} to ${$(r.highCents)}. Booked so far (actual): ${$(r.monthToDateCents)} by day ${r.daysElapsed} of ${r.daysInMonth}. This extends the current pace; it is not a statistical forecast. Data: ${s.label.toLowerCase()}.`,
      details: [
        { label: "Booked month to date (actual)", value: $(r.monthToDateCents) },
        { label: "Delivered month to date (actual)", value: $(r.deliveredToDateCents) },
        { label: "Month-to-date pace projection (indicative)", value: $(r.paceProjectionCents) },
        { label: "28-day pace projection (indicative)", value: $(r.trailingProjectionCents) },
        { label: "Method", value: "R + daily pace × days left; range = the lower and higher of the two paces" },
      ],
    };
  }

  // --- Pipeline --------------------------------------------------------------
  if (has(q, "pipeline", "open order", "undelivered", "not delivered", "not yet delivered", "still to deliver", "pending order", "backlog", "awaiting delivery")) {
    const p = ctx.model.pipeline;
    if (p.totalOrders === 0) return { intent: "pipeline", text: `There are no open orders${note}: everything booked has been delivered or cancelled.` };
    return {
      intent: "pipeline",
      text: `Current pipeline (committed)${note}: ${plural(p.totalOrders, "open order")} with ${p.remainingUnits} ball(s) still to deliver, worth ${$(p.remainingCents)}. ${p.oldest ? `Oldest: ${p.oldest.orderId} for ${p.oldest.customerName}, ${p.oldest.ageDays} days old.` : ""}`.trim(),
      details: p.byStatus.filter((s) => s.orders > 0).map((s) => ({ label: STATUS_LABEL[s.status], value: `${plural(s.orders, "order")} · ${s.remainingUnits} balls · ${$(s.remainingCents)}` })),
    };
  }

  // --- Financial (assistant only) ----------------------------------------------
  if (has(q, "aging", "ageing", "overdue")) {
    const rows = outstandingByAge(ctx.ds, ctx.filters, ctx.today);
    const total = rows.reduce((s, r) => s + r.cents, 0);
    return {
      intent: "aging",
      text: total === 0 ? "No order has an outstanding balance." : `Outstanding balances by age of the order${note}: total ${$(total)}. EFZ orders have no due dates, so this is age since the sale, not days overdue.`,
      details: rows.map((r) => ({ label: r.label, value: `${$(r.cents)} (${plural(r.orders, "order")})` })),
    };
  }
  if (has(q, "cash flow", "cashflow", "reconcil", "expense", "net profit")) {
    return { intent: "finance-unavailable", text: "EFZ does not record expenses or bank statements, so cash flow, net profit and reconciliation cannot be answered from the available data." };
  }
  if (/\b(owes?|owed|owing)\b/.test(q) || has(q, "outstanding", "debt", "receivable", "balance", "unpaid", "not paid")) {
    const b = outstandingBalances(ctx.ds, ctx.filters);
    if (customers.length > 1) return ambiguous(customers);
    if (customers.length === 1) {
      const c = b.customers.find((x) => x.customerId === customers[0].id);
      return { intent: "balance-customer", text: c ? `${customers[0].name} owes ${$(c.outstandingCents)} across ${plural(c.ordersWithBalance, "order")} (current balance).` : `${customers[0].name} has no outstanding balance.` };
    }
    if (b.totalCents === 0) return { intent: "balances", text: `No customer has an outstanding balance${note}.` };
    const top = b.customers[0];
    return {
      intent: "balances",
      text: `${top.name} owes the most: ${$(top.outstandingCents)}. In total ${$(b.totalCents)} is outstanding across ${plural(b.customers.length, "customer")}${note} (current balances).`,
      details: b.customers.slice(0, 8).map((c) => ({ label: c.name, value: `${$(c.outstandingCents)} (${plural(c.ordersWithBalance, "order")})` })),
    };
  }
  const methodQuestion = has(q, "payment method", "payment channel", "evc", "edahab", "e-dahab", "bank", "method") || (has(q, "cash") && has(q, "through", "via", "in cash", "by cash"));
  if (methodQuestion || has(q, "collect", "cash received", "payments received", "received", "how much cash", "payments")) {
    const range = explicit ? m.period : ctx.model.period;
    const c = paymentsReceived(ctx.ds, ctx.filters, range);
    if (c.payments === 0) return { intent: "collections", text: `No payments were received in ${label}${note}.` };
    const named = (["evc", "edahab", "bank", "cash"] as const).find((w) => q.includes(w));
    const row = named ? c.byMethod.find((r) => r.method.toLowerCase().replace(/[^a-z]/g, "").startsWith(named)) : undefined;
    if (named && methodQuestion) {
      return { intent: "collections-method", text: row ? `${row.method}: ${$(row.cents)} from ${plural(row.payments, "payment")} in ${label} (${pct(row.sharePct)} of ${$(c.totalCents)} received)${note}.` : `No payments recorded as ${named.toUpperCase()} in ${label}. Methods recorded: ${c.byMethod.map((r) => r.method).join(", ")}.` };
    }
    return {
      intent: "collections",
      text: `Cash received (by payment date) in ${label}${note}: ${$(c.totalCents)} from ${plural(c.payments, "payment")}.`,
      details: c.byMethod.map((r) => ({ label: r.method, value: `${$(r.cents)} (${plural(r.payments, "payment")}, ${pct(r.sharePct)})` })),
    };
  }
  if (has(q, "profit", "margin", "cost")) {
    const g = grossProfit(ctx.ds, ctx.filters, m.period);
    if (!g.available) return { intent: "profit", text: g.reason };
    if (g.orders === 0) return { intent: "profit", text: `No sales were booked in ${label}${note}.` };
    return { intent: "profit", text: `Gross profit on orders booked in ${label}${note}: ${$(g.grossProfitCents)} on ${$(g.bookedCents)} booked (${pct(g.marginPct)} margin), from frozen historical unit costs.` };
  }

  // --- Delivered vs booked ---------------------------------------------------------
  if ((has(q, "delivered") && has(q, "booked")) || has(q, "delivered vs", "delivered versus")) {
    const k = m.kpis;
    return {
      intent: "delivered-vs-booked",
      text: `In ${label}${note}: delivered revenue (actual) ${$(k.deliveredCents)} of ${$(k.bookedCents)} booked; ${$(k.undeliveredCents)} is still to be delivered (committed). Units: ${k.deliveredUnits} delivered of ${k.bookedUnits} booked.`,
    };
  }

  // --- Marketing Officers ----------------------------------------------------------
  if (has(q, "officer", "who sold", "salesperson", "sales rep", "marketing")) {
    if (!ctx.canSeeOfficers) return { intent: "officers", text: "The Marketing Officer breakdown is not available for your account." };
    const rows = m.officers;
    if (rows.length === 0) return { intent: "officers", text: `No sales were booked in ${label}${note}.` };
    const top = rows[0];
    return {
      intent: "officers",
      text: `${top.name} generated the most delivered revenue in ${label}${note}: ${$(top.deliveredCents)} (booked ${$(top.bookedCents)}, ${plural(top.orders, "order")}). This is a breakdown of sales, not a target comparison.`,
      details: rows.map((r) => ({ label: r.name, value: `delivered ${$(r.deliveredCents)} · booked ${$(r.bookedCents)} · ${plural(r.orders, "order")} · ${plural(r.customers, "customer")}` })),
    };
  }

  // --- Customers ---------------------------------------------------------------
  if (has(q, "new customer", "returning", "repeat customer", "repeat buyer")) {
    const n = m.newReturning;
    return { intent: "new-returning", text: `In ${label}${note}: ${plural(n.buyingCustomers, "buying customer")}, ${n.newCustomers} new (first order in this period) and ${n.returningCustomers} returning.` };
  }
  if (has(q, "trial", "conversion", "convert")) {
    const t = ctx.model.trials;
    if (t.trialCustomers === 0) return { intent: "trials", text: "No customer has a (non-cancelled) trial order yet." };
    return {
      intent: "trials",
      text: `${t.converted} of ${plural(t.trialCustomers, "trial customer")} went on to place a regular order (all time)${note}.${t.notConverted.length ? ` Not yet converted: ${t.notConverted.slice(0, 3).map((x) => `${x.name} (trial ${x.trialDate})`).join(", ")}.` : ""}`,
    };
  }
  if (has(q, "realization", "realisation", "discount", "list price", "price")) {
    const r = m.realization;
    if (r.realizationPct === null) return { intent: "price", text: `No lines with a list price were booked in ${label}${note}.` };
    return {
      intent: "price",
      text: `Price realisation in ${label}${note}: customers paid ${pct(r.realizationPct)} of list price on average, ${$(r.discountCents)} below list in total.`,
      details: m.products.filter((p) => p.realizationPct !== null).map((p) => ({ label: p.name, value: `${pct(p.realizationPct)} of list · avg ${p.avgPriceCents === null ? "n/a" : $(p.avgPriceCents)} vs list ${p.avgListPriceCents === null ? "n/a" : $(p.avgListPriceCents)}` })),
    };
  }
  if (has(q, "fastest", "moving", "velocity", "selling fast", "sell fastest")) {
    const rows = [...ctx.model.stock].filter((s) => s.unitsLast28 > 0).sort((a, b) => b.velocity28 - a.velocity28);
    if (rows.length === 0) return { intent: "velocity", text: "No product has booked sales in the last 28 days." };
    return {
      intent: "velocity",
      text: `${rows[0].name} is moving fastest: ${rows[0].unitsLast28} balls booked in the last 28 days (${rows[0].velocity28.toFixed(2)}/day).`,
      details: rows.map((s) => ({ label: s.name, value: `${s.unitsLast28} in 28 days (${s.velocity28.toFixed(2)}/day) · ${s.unitsLast7} in 7 days` })),
    };
  }

  // --- Comparison ----------------------------------------------------------------
  if (has(q, "compare", "growth", " vs ", "versus", "grew", "increase", "decrease", "better than", "worse than")) {
    const cmp = comparisonRange(m.period);
    if (!cmp || (ctx.ds.firstSaleDate !== null && cmp.to < ctx.ds.firstSaleDate)) return { intent: "compare", text: `There is no comparable earlier period with sales for ${label}.` };
    const cur = m.kpis, prev = computeKpis(ctx.ds, ctx.filters, cmp);
    const dc = change(cur.deliveredCents, prev.deliveredCents)!, bc = change(cur.bookedCents, prev.bookedCents)!;
    const fmt = (c: { delta: number; pct: number | null }) => `${c.delta >= 0 ? "+" : "-"}${$(Math.abs(c.delta))}${c.pct === null ? "" : ` (${c.pct >= 0 ? "+" : ""}${c.pct.toFixed(1)}%)`}`;
    return {
      intent: "compare",
      text: `${label} vs ${cmp.label.toLowerCase()} (${formatRange(cmp)})${note}: delivered revenue ${$(cur.deliveredCents)} vs ${$(prev.deliveredCents)} ${fmt(dc)}; booked ${$(cur.bookedCents)} vs ${$(prev.bookedCents)} ${fmt(bc)}; orders ${cur.orders} vs ${prev.orders}.`,
    };
  }
  if (customers.length > 1) return ambiguous(customers);
  if (has(q, "top customer", "best customer", "biggest customer", "driving", "concentration", "which customers", "largest customer", "most valuable")) {
    const rows = m.customers;
    if (rows.length === 0) return { intent: "customers", text: `No sales were booked in ${label}${note}.` };
    return {
      intent: "customers",
      text: `${rows[0].name} drove the most booked revenue in ${label}${note}: ${$(rows[0].bookedCents)} (${pct(rows[0].sharePct)}). The top 3 customers hold ${pct(m.concentration.top3Pct)} of booked revenue.`,
      details: rows.slice(0, 8).map((r) => ({ label: r.name, value: `${$(r.bookedCents)} booked · ${pct(r.sharePct)} · ${plural(r.orders, "order")}` })),
    };
  }
  if (customers.length === 1) {
    const row = m.customers.find((r) => r.customerId === customers[0].id);
    const bal = outstandingBalances(ctx.ds, { ...ctx.filters, customerId: customers[0].id });
    if (!row) return { intent: "customer", text: `${customers[0].name} has no booked orders in ${label}${note}. Current outstanding balance: ${$(bal.totalCents)}.` };
    return {
      intent: "customer",
      text: `${row.name} in ${label}${note}: ${$(row.bookedCents)} booked and ${$(row.deliveredCents)} delivered across ${plural(row.orders, "order")} (${row.bookedUnits} balls). Current outstanding balance: ${$(bal.totalCents)}.`,
      details: [
        { label: "First order", value: row.firstOrderDate ?? "n/a" },
        { label: "Share of booked revenue", value: pct(row.sharePct) },
        { label: "Average days between orders (all time)", value: row.avgDaysBetweenOrders === null ? "n/a (fewer than 2 orders)" : row.avgDaysBetweenOrders.toFixed(1) },
      ],
    };
  }
  if (product && !has(q, "best", "top", "most")) {
    const row = m.products.find((p) => p.productKey === product.key);
    if (!row) return { intent: "product", text: `${product.name} had no booked sales in ${label}${note}.` };
    return {
      intent: "product",
      text: `${row.name} in ${label}${note}: ${row.bookedUnits} balls booked (${row.deliveredUnits} delivered), ${$(row.bookedCents)} booked revenue (${pct(row.sharePct)} of the total), average price ${row.avgPriceCents === null ? "n/a" : $(row.avgPriceCents)}.`,
    };
  }
  if (has(q, "best-selling", "best selling", "bestseller", "best seller", "top product", "best product", "most popular", "sells the most", "selling the most", "sold the most")) {
    const rows = m.products;
    if (rows.length === 0) return { intent: "best-product", text: `No product sales were booked in ${label}${note}.` };
    const byUnits = [...rows].sort((a, b) => b.bookedUnits - a.bookedUnits)[0];
    return {
      intent: "best-product",
      text: `${rows[0].name} is the best seller by booked revenue in ${label}${note}: ${$(rows[0].bookedCents)} from ${rows[0].bookedUnits} balls.${byUnits.productKey !== rows[0].productKey ? ` By units, ${byUnits.name} leads with ${byUnits.bookedUnits}.` : ""}`,
      details: rows.map((p) => ({ label: p.name, value: `${p.bookedUnits} balls · ${$(p.bookedCents)} · ${pct(p.sharePct)}` })),
    };
  }
  if (has(q, "attention", "focus", "priorit", "concern", "what should", "worry", "issues")) {
    const items = ctx.model.attention;
    if (items.length === 0) return { intent: "attention", text: "Nothing currently meets the attention rules (stock cover, aged open orders, customer concentration, unconverted trials, revenue drop)." };
    return { intent: "attention", text: `${plural(items.length, "item")} need attention:`, details: items.map((i) => ({ label: i.title, value: i.detail })) };
  }
  if (has(q, "units", "balls", "quantity")) {
    const k = m.kpis;
    return { intent: "units", text: `${label}${note}: ${k.bookedUnits} balls booked, ${k.deliveredUnits} delivered.` };
  }
  if (has(q, "how many orders", "order count", "number of orders", "orders")) {
    const k = m.kpis;
    return { intent: "orders", text: `${label}${note}: ${plural(k.orders, "order")} booked (cancelled excluded), ${k.fullyDeliveredOrders} fully delivered.` };
  }
  if (has(q, "revenue", "sales", "sell", "sold", "how are we doing", "performance", "summary", "overview", "how much")) {
    return salesSummary(m, label, note);
  }
  const s = salesSummary(m, label, note);
  return { ...s, intent: "fallback", text: `${s.text} Ask about sales, products, customers, officers, the pipeline, the month-end outlook, stock cover, balances or payments.` };
}

function help(): AssistantAnswer {
  return {
    intent: "help",
    text: "I answer from the same figures as this page (and the order, payment and balance records behind it). Try:",
    details: SUGGESTED_QUESTIONS.map((q, i) => ({ label: `${i + 1}`, value: q })),
  };
}

function ambiguous(list: { id: string; name: string }[]): AssistantAnswer {
  return { intent: "ambiguous", text: `More than one customer is called "${list[0].name}". Use the Customer filter to pick one, then ask again.`, details: list.map((c) => ({ label: c.name, value: `Customer ID ${c.id}` })) };
}
