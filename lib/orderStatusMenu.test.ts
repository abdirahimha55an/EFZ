// The Orders status menu: a Manager sees only valid next steps (never labelled override); only a Super Admin sees overrides. Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import { statusMenu, type MenuInput } from "./orderStatusMenu.ts";
import type { OrderStatus } from "./types/index.ts";

const base = { deliveredBalls: 0, canEdit: true, canOverride: false, financiallyLocked: false };
const menu = (status: OrderStatus, extra: Partial<MenuInput> = {}) => statusMenu({ status, ...base, ...extra });
const labels = (status: OrderStatus, extra: Partial<MenuInput> = {}) => menu(status, extra).map((o) => `${o.status}${o.override ? "*" : ""}`);

test("a Manager sees the current status plus only the valid next steps, none labelled override", () => {
  assert.deepEqual(labels("pending"), ["pending", "confirmed", "cancelled"]);
  assert.deepEqual(labels("confirmed"), ["confirmed", "processing", "cancelled"]);
  assert.deepEqual(labels("processing"), ["processing", "dispatched", "cancelled"]);   // Dispatched is offered, Delivered is not
  assert.deepEqual(labels("dispatched"), ["dispatched", "delivered", "cancelled"]);
  for (const s of ["pending", "confirmed", "processing", "dispatched"] as OrderStatus[]) assert.ok(menu(s).every((o) => !o.override), s);
});

test("a processing order can never be delivered from a normal menu", () => {
  assert.ok(!menu("processing").some((o) => o.status === "delivered"));
  assert.ok(!menu("confirmed").some((o) => o.status === "delivered")); assert.ok(!menu("pending").some((o) => o.status === "delivered"));
});

test("an order with payments or paid commission cannot be cancelled by a Manager (Super Admin only)", () => {
  assert.deepEqual(labels("processing", { financiallyLocked: true }), ["processing", "dispatched"]);
  assert.deepEqual(labels("dispatched", { financiallyLocked: true }), ["dispatched", "delivered"]);
});

test("delivered and cancelled orders offer a Manager nothing else; partly delivered orders only offer finishing the delivery", () => {
  assert.deepEqual(labels("delivered"), ["delivered"]); assert.deepEqual(labels("cancelled"), ["cancelled"]);
  assert.deepEqual(labels("partially_delivered", { deliveredBalls: 1 }), ["partially_delivered", "delivered"]);
  assert.deepEqual(labels("dispatched", { deliveredBalls: 1 }), ["dispatched", "delivered"]);
});

test("a user who may not edit orders sees only the current status", () => {
  assert.deepEqual(labels("processing", { canEdit: false }), ["processing"]);
});

test("a Super Admin also sees every other status, and exactly those are labelled override", () => {
  assert.deepEqual(labels("processing", { canOverride: true }), ["pending*", "confirmed*", "processing", "dispatched", "delivered*", "cancelled"]);
  assert.deepEqual(labels("dispatched", { canOverride: true }), ["pending*", "confirmed*", "processing*", "dispatched", "delivered", "cancelled"]);
  // the screenshot case: on a DELIVERED order there are no normal next steps, so every other status is an override
  assert.deepEqual(labels("delivered", { canOverride: true }), ["pending*", "confirmed*", "processing*", "dispatched*", "delivered", "cancelled*"]);
});
