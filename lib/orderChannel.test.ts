// Order Tracking: which orders came from the customer app. Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import { isCustomerAppOrder, matchesChannel } from "./orderChannel.ts";

test("the app's checkout sentence marks an order; staff-written notes do not", () => {
  assert.equal(isCustomerAppOrder({ deliveryNotes: "Placed in the customer app. Deliver to: Hodan" }), true);
  assert.equal(isCustomerAppOrder({ deliveryNotes: "  Placed in the customer app. Deliver to: x" }), true);
  assert.equal(isCustomerAppOrder({ deliveryNotes: "Call before delivery" }), false);
  assert.equal(isCustomerAppOrder({ deliveryNotes: "Customer said: Placed in the customer app." }), false);
  assert.equal(isCustomerAppOrder({}), false);
  assert.equal(isCustomerAppOrder({ deliveryNotes: null }), false);
});

test("the channel filter keeps everything for 'all' and only app orders otherwise", () => {
  const app = { deliveryNotes: "Placed in the customer app. Deliver to: a" }; const other = { deliveryNotes: "" };
  assert.deepEqual([app, other].filter((o) => matchesChannel(o, "all")), [app, other]);
  assert.deepEqual([app, other].filter((o) => matchesChannel(o, "customer_app")), [app]);
});
