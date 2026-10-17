// Hub side of customer-app requests: orderRequests.list() marks requests placed in the app and attaches each line's design. Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import { createDb } from "./supabase/queries.ts";

type Rows = Record<string, { data?: unknown[]; error?: { code: string; message: string } }>;
function fake(rows: Rows) {
  const client = {
    from(table: string) {
      const res = rows[table] ?? { data: [] };
      const chain: Record<string, unknown> = {};
      for (const m of ["select", "order", "limit", "eq"]) chain[m] = () => chain;
      (chain as { then: unknown }).then = (ok: (v: unknown) => unknown) => ok({ data: res.error ? null : res.data ?? [], error: res.error ?? null });
      return chain;
    },
  };
  return createDb(client as never);
}
const request = (id: string) => ({ id, customer_name: "N", phone: "061", organization: "", product_id: "p1", product_name: "Ball", quantity: 3, delivery_location: "Hodan", notes: "", status: "new", converted_order_id: null, handled_by: null, assigned_to: null, rejected_reason: null, status_changed_at: null, created_at: "2026-10-01T00:00:00Z", updated_at: "2026-10-01T00:00:00Z", phone_canonical: "+252611111111", submission_key: null });
const line = (request_id: string, line_no: number, name: string) => ({ request_id, line_no, product_id: "p1", product_name: name, quantity: 1, legacy: false });

test("a request placed in the customer app is marked, with its verified customer and the design of each line", async () => {
  const db = fake({
    order_requests: { data: [request("r1"), request("r2")] },
    order_request_lines: { data: [line("r1", 1, "Ball"), line("r1", 2, "Ball"), line("r2", 1, "Ball")] },
    customer_order_requests: { data: [{ request_id: "r1", customer_id: "cust-1" }] },
    customer_order_request_lines: { data: [{ request_id: "r1", line_no: 1, design_name: "Red" }, { request_id: "r1", line_no: 2, design_name: "Blue" }] },
  });
  const list = await db.orderRequests.list();
  const r1 = list.find((r) => r.id === "r1")!, r2 = list.find((r) => r.id === "r2")!;
  assert.deepEqual(r1.app, { customerId: "cust-1" });
  assert.deepEqual(r1.lines.map((l) => l.designName), ["Red", "Blue"]);
  assert.equal(r2.app, undefined, "a website request is untouched");
  assert.equal(r2.lines[0].designName, undefined);
});
test("before migration 22 (tables missing) the requests are returned unchanged", async () => {
  const db = fake({ order_requests: { data: [request("r1")] }, order_request_lines: { data: [line("r1", 1, "Ball")] }, customer_order_requests: { error: { code: "42P01", message: "relation does not exist" } } });
  const [r] = await db.orderRequests.list();
  assert.equal(r.app, undefined); assert.equal(r.lines.length, 1);
});
test("another database error is not hidden", async () => {
  const db = fake({ order_requests: { data: [request("r1")] }, order_request_lines: { data: [line("r1", 1, "Ball")] }, customer_order_requests: { error: { code: "XX000", message: "boom" } } });
  await assert.rejects(db.orderRequests.list(), /orderRequests.appInfo/);
});
test("no request from the app means no extra query for lines and nothing changes", async () => {
  const db = fake({ order_requests: { data: [request("r1")] }, order_request_lines: { data: [line("r1", 1, "Ball")] }, customer_order_requests: { data: [] } });
  assert.equal((await db.orderRequests.list())[0].app, undefined);
});
