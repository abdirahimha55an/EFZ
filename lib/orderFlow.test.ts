// 29: the order status flow with the Dispatched step. Mirrors update_order_status() (supabase/29b_dispatch_and_live_orders.sql). Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import { ORDER_STATUSES, ORDER_STATUS_TRANSITIONS, SELECTABLE_ORDER_STATUSES, type OrderStatus } from "./types/index.ts";

test("the statuses are exactly the database enum, with dispatched between processing and partially_delivered", () => {
  assert.deepEqual(ORDER_STATUSES, ["pending", "confirmed", "processing", "dispatched", "partially_delivered", "delivered", "cancelled"]);
});

test("every normal transition", () => {
  const t = ORDER_STATUS_TRANSITIONS;
  assert.deepEqual(t.pending, ["confirmed", "cancelled"]);
  assert.deepEqual(t.confirmed, ["processing", "cancelled"]);
  assert.deepEqual(t.processing, ["dispatched", "cancelled"]);   // 29e: no direct processing -> delivered
  assert.deepEqual(t.dispatched, ["delivered", "cancelled"]);
  assert.deepEqual(t.partially_delivered, ["delivered"]);
  assert.deepEqual(t.delivered, []);
  assert.deepEqual(t.cancelled, []);
});

test("delivered is reachable only from dispatched or partially_delivered, never straight from processing", () => {
  const from = ORDER_STATUSES.filter((s) => ORDER_STATUS_TRANSITIONS[s].includes("delivered"));
  assert.deepEqual(from, ["dispatched", "partially_delivered"]);
  assert.ok(!ORDER_STATUS_TRANSITIONS.processing.includes("delivered")); assert.ok(!ORDER_STATUS_TRANSITIONS.confirmed.includes("delivered")); assert.ok(!ORDER_STATUS_TRANSITIONS.pending.includes("delivered"));
});

test("dispatch is reachable only from processing, and a cancelled or delivered order can never be dispatched", () => {
  const into = (s: OrderStatus) => ORDER_STATUSES.filter((from) => ORDER_STATUS_TRANSITIONS[from].includes(s));
  assert.deepEqual(into("dispatched"), ["processing"]);
  assert.ok(!ORDER_STATUS_TRANSITIONS.cancelled.includes("dispatched")); assert.ok(!ORDER_STATUS_TRANSITIONS.delivered.includes("dispatched"));
  assert.ok(!ORDER_STATUS_TRANSITIONS.partially_delivered.includes("dispatched"));
});

test("dispatched is a status staff can pick; partially_delivered still follows deliveries only", () => {
  assert.ok(SELECTABLE_ORDER_STATUSES.includes("dispatched"));
  assert.ok(!SELECTABLE_ORDER_STATUSES.includes("partially_delivered"));
});
