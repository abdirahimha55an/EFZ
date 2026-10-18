// Hub pre-checks for customer price agreements (they mirror rules the database enforces). Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import { agreementProblem, importSummary, manualConfirmationCsv, noteProblem, statusLabel, type ImportItem, type ImportReport } from "./customerPrices.ts";

const ok = { customerId: "c1", productId: "p1", price: "8.00", from: "2026-10-01", to: "", reason: "Agreed with the owner in 2025", belowCost: false, belowCostReason: "", isSuperAdmin: false };

test("an agreement needs a customer, a product, a price in whole cents, a start date and a documented authorization", () => {
  assert.equal(agreementProblem(ok), null);
  assert.match(agreementProblem({ ...ok, customerId: "" }) as string, /customer/);
  assert.match(agreementProblem({ ...ok, productId: "" }) as string, /product/);
  for (const price of ["", "0", "-1", "7.005", "abc", "1000001"]) assert.match(agreementProblem({ ...ok, price }) as string, /whole cents/, price);
  assert.match(agreementProblem({ ...ok, from: "" }) as string, /starts/);
  assert.match(agreementProblem({ ...ok, to: "2026-09-01" }) as string, /before the start/);
  assert.match(agreementProblem({ ...ok, to: "soon" }) as string, /not valid/);
  assert.match(agreementProblem({ ...ok, reason: "short" }) as string, /authorization or evidence/);
  assert.equal(agreementProblem({ ...ok, to: "2026-12-31" }), null);
});
test("a below-cost price is refused for a Manager and needs a reason from a Super Admin (the same rule as create_order)", () => {
  assert.match(agreementProblem({ ...ok, belowCost: true }) as string, /Only a Super Admin/);
  assert.match(agreementProblem({ ...ok, belowCost: true, isSuperAdmin: true }) as string, /reason of at least/);
  assert.equal(agreementProblem({ ...ok, belowCost: true, isSuperAdmin: true, belowCostReason: "Clearing old stock with the owner" }), null);
});
test("notes and reasons need at least 10 characters", () => { assert.ok(noteProblem("short")); assert.equal(noteProblem("a documented reason"), null); });
test("status labels say what the app does with an agreement", () => {
  const base = { status: "active" as const, inEffect: true, expired: false, expiresSoon: false, effectiveFrom: "2026-10-01" };
  assert.equal(statusLabel(base, "2026-10-18"), "Active");
  assert.equal(statusLabel({ ...base, expiresSoon: true }, "2026-10-18"), "Active, ends soon");
  assert.equal(statusLabel({ ...base, inEffect: false, expired: true }, "2026-10-18"), "Expired");
  assert.equal(statusLabel({ ...base, inEffect: false, effectiveFrom: "2026-11-01" }, "2026-10-18"), "Starts 2026-11-01");
  assert.match(statusLabel({ ...base, status: "pending_review" }, "2026-10-18"), /not used/);
  assert.equal(statusLabel({ ...base, status: "revoked" }, "2026-10-18"), "Revoked");
  assert.equal(statusLabel({ ...base, status: "rejected" }, "2026-10-18"), "Rejected");
});
test("the manual-confirmation list becomes CSV with quotes escaped and one row per item", () => {
  const item: ImportItem = { customerId: "c1", customerName: 'Ali "Big" Trading', productId: "p1", productName: "Ball", designName: "Red", orders: 3, prices: [9, 8.5], latestPrice: 9, listPriceNow: 10, firstOrder: "2026-08-01", lastOrder: "2026-10-01", reason: "the price varies between $8.50 and $9.00" };
  const csv = manualConfirmationCsv([item]).split("\r\n");
  assert.equal(csv.length, 2);
  assert.match(csv[0], /^"Customer","Customer id","Product"/);
  assert.match(csv[1], /"Ali ""Big"" Trading","c1","Ball","Red","3","9 \/ 8.5"/);
  assert.match(csv[1], /the price varies between/);
});
test("the import summary says whether anything was saved, and never claims candidates are usable", () => {
  const r: ImportReport = { dryRun: true, since: "2025-10-18", minOrders: 2, candidates: [], needsConfirmation: [], alreadyCovered: 1, created: 0 };
  assert.match(importSummary(r), /^Preview only: nothing was saved\./);
  assert.match(importSummary({ ...r, dryRun: false, created: 2 }), /2 candidate\(s\) were saved as pending \(not used until verified\)/);
});
