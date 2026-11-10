// Hand-computed fixtures for the profit chain (gross -> contribution -> net) and the expense helpers. Run with `npm run test:hub`.
import test from "node:test";
import assert from "node:assert/strict";
import { profitModel, splitCents } from "./profit.ts";
import { NO_FILTERS, type Dataset, type SalesLine, type SalesOrder } from "../analytics/dataset.ts";
import { actionsFor, monthlyTrend, summarizeExpenses, totalsByCategory, validateExpense } from "./expenses.ts";
import type { CommissionCost, Expense, ExpenseCategory, ExpenseCost } from "../types/index.ts";

const line = (orderId: string, productKey: string, name: string, quantity: number, delivered: number, price: number, cost: number | null): SalesLine => ({
  orderId, productKey, productId: productKey, productName: name, quantity, delivered, remaining: quantity - delivered,
  unitPriceCents: price * 100, listPriceCents: price * 100, costCents: cost === null ? null : cost * 100 * quantity, unitCostCents: cost === null ? null : cost * 100,
});
const order = (id: string, date: string, status: SalesOrder["status"], lines: SalesLine[], officer: string | null = null): SalesOrder => ({
  id, date, createdAt: `${date}T08:00:00Z`, status, orderType: "regular", customerId: `c-${id}`, customerName: `Customer ${id}`, officerId: officer, officerName: officer ?? "",
  stockMode: "at_delivery", lines, payments: [], totalCents: lines.reduce((a, l) => a + l.unitPriceCents * l.quantity, 0), paymentStatus: "unpaid", paymentTerms: null,
  outstandingCents: 0, amountPaidCents: 0, grossProfitCents: null, costCents: null,
});
const ds = (orders: SalesOrder[]): Dataset => ({ orders, products: [], customers: [], firstSaleDate: null, firstOrderByCustomer: new Map() });

// November 2026. Nexus $10 (cost $6), Fire $20 (cost $12).
//  O1 Nov 2: Nexus 10/10 delivered, Fire 5/5 delivered           -> revenue 200, COGS 120, GP 80
//  O2 Nov 5: Nexus 10 ordered, 4 delivered                       -> revenue 40, COGS 24, GP 16
//  O3 Nov 7: CANCELLED                                           -> no revenue
//  O4 Oct 30: Nexus 3/3 delivered (outside the period)           -> revenue 30, COGS 18
const O1 = order("O1", "2026-11-02", "delivered", [line("O1", "nexus", "Nexus", 10, 10, 10, 6), line("O1", "fire", "Fire", 5, 5, 20, 12)]);
const O2 = order("O2", "2026-11-05", "partially_delivered", [line("O2", "nexus", "Nexus", 10, 4, 10, 6)]);
const O3 = order("O3", "2026-11-07", "cancelled", [line("O3", "nexus", "Nexus", 5, 0, 10, 6)]);
const O4 = order("O4", "2026-10-30", "delivered", [line("O4", "nexus", "Nexus", 3, 3, 10, 6)]);
const DS = ds([O4, O1, O2, O3]);
const NOV = { from: "2026-11-01", to: "2026-11-30" };

const exp = (id: string, kind: "direct_order" | "operating", cat: string, amount: number, date: string, orderId: string | null = null, orderStatus: string | null = null): ExpenseCost =>
  ({ expenseId: id, reference: id, kind, categoryId: cat, amount, expenseDate: date, orderId, orderStatus, paymentStatus: "unpaid", paidAmount: 0 });
const EXPENSES: ExpenseCost[] = [
  exp("X1", "direct_order", "delivery", 12, "2026-11-02", "O1", "delivered"),
  exp("X2", "direct_order", "packaging", 4, "2026-11-05", "O2", "partially_delivered"),
  exp("X3", "direct_order", "delivery", 5, "2026-11-07", "O3", "cancelled"),   // cancelled order: its own line
  exp("X4", "direct_order", "delivery", 3, "2026-10-31", "O4", "delivered"),   // order outside the period
  exp("X5", "operating", "rent", 48, "2026-11-01"),
  exp("X6", "operating", "internet", 12, "2026-10-15"),                          // outside the period
];
const com = (id: string, orderId: string, kind: string, amount: number, at: string, earned = true, review = false): CommissionCost =>
  ({ commissionId: id, orderId, kind, status: "approved", amount, attributedAt: at, earned, reviewRequired: review });
const COMMISSIONS: CommissionCost[] = [
  com("C1", "O1", "delivery", 4.5, "2026-11-02T10:00:00Z"),
  com("C2", "O2", "delivery", 1.2, "2026-11-06T10:00:00Z"),
  com("C3", "O1", "first_order_bonus", 3, "2026-11-02T10:00:00Z"),
  com("C4", "O4", "delivery", 0.9, "2026-11-01T10:00:00Z"),                       // Oct order, EARNED in November: counts in November
  com("C5", "O2", "delivery", 0.6, "2026-11-08T10:00:00Z", false),               // not earned yet: shown, not deducted
];

test("splitCents adds up exactly and handles empty weights", () => {
  assert.deepEqual(splitCents(100, [1, 1, 1]), [34, 33, 33]);
  assert.deepEqual(splitCents(1000, [140, 100]), [583, 417]);
  assert.deepEqual(splitCents(7, [0, 0]), [4, 3]);
  assert.deepEqual(splitCents(0, [5, 5]), [0, 0]);
  assert.equal(splitCents(99999, [3, 7, 11, 13]).reduce((a, b) => a + b, 0), 99999);
});

test("period chain: gross = delivered revenue - COGS; contribution; net (hand computed)", () => {
  const { chain } = profitModel({ ds: DS, filters: NO_FILTERS, range: NOV, expenses: EXPENSES, commissions: COMMISSIONS });
  assert.equal(chain.deliveredRevenueCents, 24000);               // 200 + 40
  assert.equal(chain.cogsCents, 14400);                            // 120 + 24: COGS from the frozen unit cost only
  assert.equal(chain.grossProfitCents, 9600);
  assert.equal(chain.directExpensesCents, 1600);                   // X1 12 + X2 4 (X3 cancelled, X4 other period)
  assert.equal(chain.cancelledOrderExpensesCents, 500);            // X3, its own line
  assert.equal(chain.commissionsCents, 960);                       // C1 4.50 + C2 1.20 + C3 3.00 + C4 0.90 by earned_at; C5 not earned
  assert.equal(chain.contributionProfitCents, 6540);               // 96.00 - 16.00 - 5.00 - 9.60
  assert.equal(chain.operatingExpensesCents, 4800);                // X5 only
  assert.equal(chain.operatingShare, 1);
  assert.equal(chain.allocated, false);
  assert.equal(chain.netOperatingProfitCents, 1740);               // 65.40 - 48.00
  assert.equal(chain.commissionsNotYetEarnedCents, 60);
  assert.equal(Math.round((chain.contributionMarginPct ?? 0) * 100) / 100, 27.25);
  assert.equal(Math.round((chain.netMarginPct ?? 0) * 100) / 100, 7.25);
});

test("COGS is never deducted twice: expenses do not change it, and no purchase category exists in the model", () => {
  const without = profitModel({ ds: DS, filters: NO_FILTERS, range: NOV, expenses: [], commissions: [] }).chain;
  const withAll = profitModel({ ds: DS, filters: NO_FILTERS, range: NOV, expenses: EXPENSES, commissions: COMMISSIONS }).chain;
  assert.equal(without.cogsCents, withAll.cogsCents);
  assert.equal(without.grossProfitCents, withAll.grossProfitCents);
  assert.equal(without.netOperatingProfitCents, without.grossProfitCents);   // nothing approved -> net = gross, nothing invented
});

test("per order: exact direct expenses, order commissions, revenue-share operating allocation", () => {
  const { orders } = profitModel({ ds: DS, filters: NO_FILTERS, range: NOV, expenses: EXPENSES, commissions: COMMISSIONS });
  const o1 = orders.find((o) => o.orderId === "O1")!, o2 = orders.find((o) => o.orderId === "O2")!;
  assert.equal(orders.length, 2);                                  // the cancelled order and the October order are not rows
  assert.deepEqual([o1.deliveredRevenueCents, o1.cogsCents, o1.grossProfitCents, o1.directExpensesCents, o1.commissionsCents], [20000, 12000, 8000, 1200, 750]);
  assert.equal(o1.contributionProfitCents, 6050);
  assert.equal(o1.allocatedOperatingCents, 4000);                  // 48.00 x 200/240
  assert.equal(o1.netProfitCents, 2050);
  assert.deepEqual([o2.deliveredRevenueCents, o2.directExpensesCents, o2.commissionsCents, o2.contributionProfitCents, o2.allocatedOperatingCents, o2.netProfitCents], [4000, 400, 120, 1080, 800, 280]);
  // the rows reconcile to the period: rows' net + cancelled-order expenses + commissions earned in the period on other orders = chain net
  const rowsNet = orders.reduce((a, o) => a + (o.netProfitCents ?? 0), 0);
  assert.equal(rowsNet - 500 - 90, 1740);
});

test("per product: direct expenses by revenue share, per-ball commission by units, bonus by revenue; operating by revenue share", () => {
  const { products } = profitModel({ ds: DS, filters: NO_FILTERS, range: NOV, expenses: EXPENSES, commissions: COMMISSIONS });
  const nexus = products.find((p) => p.productKey === "nexus")!, fire = products.find((p) => p.productKey === "fire")!;
  assert.deepEqual([nexus.deliveredUnits, nexus.deliveredRevenueCents, nexus.cogsCents, nexus.grossProfitCents], [14, 14000, 8400, 5600]);
  assert.deepEqual([nexus.directExpensesCents, nexus.commissionsCents, nexus.contributionProfitCents, nexus.allocatedOperatingCents, nexus.netProfitCents], [1000, 570, 4030, 2800, 1230]);
  assert.deepEqual([fire.deliveredRevenueCents, fire.directExpensesCents, fire.commissionsCents, fire.contributionProfitCents, fire.allocatedOperatingCents, fire.netProfitCents], [10000, 600, 300, 3100, 2000, 1100]);
  assert.equal(nexus.contributionProfitCents! + fire.contributionProfitCents!, 7130);   // = O1 + O2 contribution
});

test("a product filter allocates operating expenses by the filtered share and labels it allocated", () => {
  const { chain } = profitModel({ ds: DS, filters: { ...NO_FILTERS, productKey: "fire" }, range: NOV, expenses: EXPENSES, commissions: COMMISSIONS });
  assert.equal(chain.deliveredRevenueCents, 10000);
  assert.equal(chain.directExpensesCents, 600);                    // O1's $12 x 100/200
  assert.equal(chain.cancelledOrderExpensesCents, 0);              // cannot be attributed to a product
  assert.equal(chain.commissionsCents, 300);                       // 4.50 x 5/15 + 3.00 x 100/200
  assert.equal(chain.contributionProfitCents, 3100);
  assert.equal(chain.allocated, true);
  assert.equal(chain.operatingExpensesCents, 2000);                // 48.00 x 100/240
  assert.equal(chain.netOperatingProfitCents, 1100);
});

test("cost withheld: every profit figure is null, never zero", () => {
  const hidden = ds([order("H1", "2026-11-03", "delivered", [line("H1", "nexus", "Nexus", 2, 2, 10, null)])]);
  const { chain, orders, products } = profitModel({ ds: hidden, filters: NO_FILTERS, range: NOV, expenses: EXPENSES.slice(4, 5), commissions: [] });
  assert.equal(chain.deliveredRevenueCents, 2000);
  assert.equal(chain.grossProfitCents, null);
  assert.equal(chain.contributionProfitCents, null);
  assert.equal(chain.netOperatingProfitCents, null);
  assert.equal(orders[0].netProfitCents, null);
  assert.equal(products[0].netProfitCents, null);
});

test("void and unapproved expenses never reach the model (only approved ones are ever passed in)", () => {
  const { chain } = profitModel({ ds: DS, filters: NO_FILTERS, range: NOV, expenses: [], commissions: COMMISSIONS });
  assert.equal(chain.directExpensesCents, 0);
  assert.equal(chain.operatingExpensesCents, 0);
});

// ------------------------------------------------------------------ expense helpers
const CATS: ExpenseCategory[] = [
  { id: "delivery", name: "Delivery", kind: "direct_order", isActive: true, sortOrder: 10 },
  { id: "rent", name: "Rent", kind: "operating", isActive: true, sortOrder: 110 },
  { id: "old", name: "Old", kind: "operating", isActive: false, sortOrder: 999 },
];
const TODAY = "2026-11-10";
const base = { categoryId: "rent", description: "November rent", amount: "120.00", expenseDate: "2026-11-01" };

test("validateExpense mirrors the database rules", () => {
  assert.deepEqual(validateExpense(base, CATS, TODAY), {});
  assert.ok(validateExpense({ ...base, amount: "12.345" }, CATS, TODAY).amount);
  assert.ok(validateExpense({ ...base, amount: "0" }, CATS, TODAY).amount);
  assert.ok(validateExpense({ ...base, amount: "abc" }, CATS, TODAY).amount);
  assert.ok(validateExpense({ ...base, amount: "1000000.01" }, CATS, TODAY).amount);
  assert.ok(validateExpense({ ...base, expenseDate: "2026-11-11" }, CATS, TODAY).expenseDate);
  assert.ok(validateExpense({ ...base, categoryId: "old" }, CATS, TODAY).categoryId);
  assert.ok(validateExpense({ ...base, categoryId: "nope" }, CATS, TODAY).categoryId);
  assert.ok(validateExpense({ ...base, description: "  " }, CATS, TODAY).description);
  assert.ok(validateExpense({ ...base, orderId: "ORD-1" }, CATS, TODAY).orderId);                       // operating + order
  assert.ok(validateExpense({ ...base, categoryId: "delivery" }, CATS, TODAY).orderId);                  // direct without order
  assert.deepEqual(validateExpense({ ...base, categoryId: "delivery", orderId: "ORD-1" }, CATS, TODAY), {});
});

const row = (over: Partial<Expense>): Expense => ({
  id: "e1", reference: "EXP-2026-000001", kind: "operating", categoryId: "rent", description: "x", amount: 100, expenseDate: "2026-11-01", paymentMethod: "", vendor: "", orderId: null, notes: "",
  receiptPath: null, submittedBy: "u-sub", submittedByName: "Sub", submittedAt: "2026-11-01T08:00:00Z", status: "pending", decidedBy: null, decidedByName: "", decidedAt: null, rejectionReason: null,
  voidReason: null, voidedByName: "", voidedAt: null, paidAmount: 0, outstandingAmount: 0, paymentStatus: null, ...over,
});

test("actionsFor: nobody approves their own, only the submitter edits, payment is separate", () => {
  const sub = { id: "u-sub", submit: true, approve: true, pay: false };
  const pending = row({});
  assert.equal(actionsFor(pending, sub).approve, false);                                                // own expense, even with approve
  assert.equal(actionsFor(pending, sub).edit, true);
  assert.equal(actionsFor(pending, { id: "u-mgr", submit: false, approve: true, pay: false }).approve, true);
  assert.equal(actionsFor(pending, { id: "u-mgr", submit: false, approve: true, pay: false }).edit, false);
  const approved = row({ status: "approved", outstandingAmount: 100 });
  assert.equal(actionsFor(approved, { id: "u-pay", submit: false, approve: false, pay: true }).pay, true);
  assert.equal(actionsFor(approved, { id: "u-mgr", submit: false, approve: true, pay: false }).pay, false);
  assert.equal(actionsFor(approved, { id: "u-mgr", submit: false, approve: true, pay: false }).voidApproved, true);
  assert.equal(actionsFor(approved, sub).voidApproved, false);                                          // not your own
  assert.equal(actionsFor(row({ status: "approved", paidAmount: 40, outstandingAmount: 60 }), { id: "u-mgr", submit: false, approve: true, pay: true }).voidApproved, false); // void payments first
  assert.equal(actionsFor(row({ status: "void" }), { id: "u-mgr", submit: true, approve: true, pay: true }).edit, false);
});

test("dashboard figures: pending, approved, paid, outstanding; monthly trend; category totals", () => {
  const rows = [
    row({ id: "a", status: "pending", amount: 50 }),
    row({ id: "b", status: "approved", amount: 200, paidAmount: 80, outstandingAmount: 120 }),
    row({ id: "c", status: "approved", amount: 30.5, paidAmount: 30.5, outstandingAmount: 0, kind: "direct_order", categoryId: "delivery", expenseDate: "2026-10-20" }),
    row({ id: "d", status: "rejected", amount: 999 }),
    row({ id: "e", status: "void", amount: 888 }),
  ];
  assert.deepEqual(summarizeExpenses(rows), { pendingCount: 1, pendingCents: 5000, approvedCount: 2, approvedCents: 23050, paidCents: 11050, outstandingCents: 12000, rejectedCount: 1, voidCount: 1, totalCents: 28050 });
  const approved = rows.filter((r) => r.status === "approved");
  assert.deepEqual(monthlyTrend(approved, 3, "2026-11-10"), [
    { month: "2026-09", directCents: 0, operatingCents: 0, totalCents: 0 },
    { month: "2026-10", directCents: 3050, operatingCents: 0, totalCents: 3050 },
    { month: "2026-11", directCents: 0, operatingCents: 20000, totalCents: 20000 },
  ]);
  assert.deepEqual(totalsByCategory(approved, CATS).map((c) => [c.categoryId, c.cents]), [["rent", 20000], ["delivery", 3050]]);
  assert.equal(monthlyTrend([], 14, "2027-01-15").length, 14);
});
