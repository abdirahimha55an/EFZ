// EFZ-STAGING ONLY. End-to-end check of migration 32 through the Hub's real data layer (lib/supabase/queries.ts) over PostgREST, signed in as real Staging staff:
// design management and its permissions, what a visitor sees, an order with several designs of one product, the admin request screen's data, conversion to an order
// (design, quantity, price), and that stock, payments and commissions do not move.
//
//   E2E_ENV=<path to .env.e2e> node --import ./scripts/register-test-loader.mjs supabase/checks/32_order_designs_e2e.mjs
//
// Reads .env.local (must be EFZ-Staging) and the staff passwords from the file named by E2E_ENV (the git-ignored .env.e2e). Prints PASS/FAIL lines; never prints a key or a password.
// Leaves behind (Staging only, synthetic): one converted-then-cancelled test order and request named "E2E32 ...", and the test designs, switched off.
import fs from "node:fs";
import { createClient } from "@supabase/supabase-js";
import { createDb, describeDbError } from "../../lib/supabase/queries.ts";

const STAGING_REF = "adjjamiqwboawqedaapi";
const PROD_REF = "rodmdvfjashiohgwople";

const readEnv = (file) => {
  const out = {};
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (m) out[m[1]] = m[2].replace(/^"|"$/g, "");
  }
  return out;
};

const env = { ...readEnv(".env.local"), ...(process.env.E2E_ENV ? readEnv(process.env.E2E_ENV) : {}) };
const url = env.NEXT_PUBLIC_SUPABASE_URL;
const anonKey = env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
if (!url || !anonKey || !url.includes(STAGING_REF) || url.includes(PROD_REF)) {
  console.error("REFUSED: .env.local is not the EFZ-Staging project");
  process.exit(2);
}

const results = [];
const check = (id, name, ok, info = "") => {
  results.push(ok);
  console.log(`${ok ? "PASS" : "FAIL"} ${id} ${name}${ok ? "" : info ? `  [${info}]` : ""}`);
};
const fresh = () => createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
const errOf = async (fn) => {
  try { await fn(); return null; } catch (e) { return describeDbError(e); }
};
async function staff(email, passwordKey) {
  const client = fresh();
  const { error } = await client.auth.signInWithPassword({ email, password: env[passwordKey] ?? "" });
  if (error) throw new Error(`sign-in failed for ${email}: ${error.message}`);
  return { client, db: createDb(client) };
}
const money = (n) => Math.round(Number(n) * 100);

const RUN = Date.now().toString(36);
const P_NEXUS = "prod-stg-nexus";       // no designs before this run
const P_FIRE = "prod-stg-fireball";     // gets a same-named design in M11 (Staging's Fire Ball is over-promised, so it is not ordered)
const P_CLEAR = "prod-stg-clearance";   // already has "E2E Red Design" (active): the design-of-another-product line
const P_PLAIN = "prod-stg-training";    // no designs: ordered by product alone
const phone = "061" + String(Math.floor(1000000 + Math.random() * 8999999));
const made = [];                        // design ids created by this run (switched off at the end)

try {
  const anon = createDb(fresh());
  const sa = await staff("efz.superadmin@example.com", "E2E_SUPERADMIN_PASSWORD");
  const inv = await staff("efz.inventory@example.com", "E2E_INVENTORY_PASSWORD");   // edit_products
  const cs = await staff("efz.cs@example.com", "E2E_CS_PASSWORD");                  // no edit_products

  // ---- 0. leftovers of an earlier, aborted run (idempotent): switch off stray test designs and reject stray open test requests ----------
  for (const d of (await sa.db.designs.list()).filter((x) => x.name.startsWith("E2E32 ") && x.isActive)) await sa.db.designs.setActive(d.id, false);
  for (const r of (await sa.db.orderRequests.list()).filter((x) => x.customerName.startsWith("E2E32 Probe") && ["new", "contacted", "confirmed"].includes(x.status))) await sa.db.orderRequests.setStatus(r.id, "rejected", "E2E32 leftover from an earlier run");

  for (const o of (await sa.db.orders.listAll()).filter((x) => x.deliveryNotes === "E2E32 conversion probe" && x.status !== "cancelled")) await sa.db.orders.setStatus(o.id, "cancelled", "E2E32 leftover from an earlier run");

  // ---- 1. staff create designs ---------------------------------------------------------------------------------------------------
  const red = await inv.db.designs.create({ productId: P_NEXUS, name: `  E2E32 Red ${RUN}  `, imageUrl: "https://example.com/e2e32-red.png", sortOrder: 2 });
  const blue = await inv.db.designs.create({ productId: P_NEXUS, name: `E2E32 Blue ${RUN}`, sortOrder: 1 });
  const hidden = await inv.db.designs.create({ productId: P_NEXUS, name: `E2E32 Hidden ${RUN}`, sortOrder: 3, isActive: false });
  made.push(red.id, blue.id, hidden.id);
  check("M1", "staff with edit_products create designs; the name comes back trimmed", red.name === `E2E32 Red ${RUN}` && blue.isActive && !hidden.isActive, JSON.stringify(red));

  const csTry = await errOf(() => cs.db.designs.create({ productId: P_NEXUS, name: `E2E32 CS ${RUN}` }));
  check("M2", "Customer Service (no edit_products) is refused when creating a design", Boolean(csTry) && /(row-level security|Permission denied|permission)/i.test(csTry), csTry ?? "no error");
  const csList = await cs.db.designs.list();
  check("M3", "...but can read the designs", csList.some((d) => d.id === red.id));
  const csSwitch = await errOf(() => cs.db.designs.setActive(red.id, false));
  check("M4", "Customer Service cannot switch a design off (refused, design unchanged)", Boolean(csSwitch) && (await sa.db.designs.list()).find((d) => d.id === red.id)?.isActive === true, csSwitch ?? "no error");
  const anonDirect = await fresh().from("product_designs").select("id").limit(1);
  check("M5", "a visitor cannot read the design table directly", Boolean(anonDirect.error) || (anonDirect.data ?? []).length === 0, JSON.stringify(anonDirect.data));

  // ---- 2. what a visitor sees --------------------------------------------------------------------------------------------------
  let pub = await anon.products.listPublicDesigns();
  const mineIds = (list) => list.filter((d) => made.includes(d.id)).map((d) => d.name).sort().join("|");
  check("V1", "visitors see the active designs and not the switched-off one", mineIds(pub) === `E2E32 Blue ${RUN}|E2E32 Red ${RUN}`, mineIds(pub));
  check("V2", "...in display order within the product (Blue 1 before Red 2)", pub.filter((d) => d.productId === P_NEXUS && made.includes(d.id)).map((d) => d.name.split(" ")[1]).join() === "Blue,Red");
  check("V3", "...with their picture link and product", pub.find((d) => d.id === red.id)?.imageUrl === "https://example.com/e2e32-red.png" && pub.find((d) => d.id === red.id)?.productId === P_NEXUS);

  // ---- 3. managing: change, switch off/on, refusals ---------------------------------------------------------------------------
  const renamed = await inv.db.designs.update(red.id, { name: `E2E32 Crimson ${RUN}`, sortOrder: 5 });
  check("M6", "staff rename a design and change its display order", renamed.name === `E2E32 Crimson ${RUN}` && renamed.sortOrder === 5);
  await inv.db.designs.setActive(blue.id, false);
  pub = await anon.products.listPublicDesigns();
  check("M7", "switching a design off hides it from visitors immediately", !pub.some((d) => d.id === blue.id));
  await inv.db.designs.setActive(blue.id, true);
  pub = await anon.products.listPublicDesigns();
  check("M8", "switching it on again brings it back", pub.some((d) => d.id === blue.id));
  const httpErr = await errOf(() => inv.db.designs.update(blue.id, { imageUrl: "http://example.com/x.png" }));
  check("M9", "the database refuses a non-https picture link, with its sentence", /https/i.test(httpErr ?? ""), httpErr ?? "no error");
  const dupErr = await errOf(() => inv.db.designs.create({ productId: P_NEXUS, name: `e2e32 blue ${RUN}` }));
  check("M10", "the database refuses a duplicate name on the same product (any case)", Boolean(dupErr) && /(duplicate|already|unique)/i.test(dupErr), dupErr ?? "no error");
  const ok2 = await inv.db.designs.create({ productId: P_FIRE, name: `E2E32 Blue ${RUN}`, sortOrder: 9 });
  made.push(ok2.id);
  check("M11", "the same name on another product is fine", Boolean(ok2.id));

  // ---- 4. a visitor orders several designs of ONE product, plus a plain product, with different quantities ----------------------------
  const fireDesign = (await anon.products.listPublicDesigns()).find((d) => d.productId === P_CLEAR && !made.includes(d.id));
  const before = {};
  for (const id of [P_NEXUS, P_CLEAR, P_PLAIN]) before[id] = (await sa.db.products.get(id))?.stock;
  const requestLines = [
    { productId: P_NEXUS, designId: red.id, quantity: 4 },
    { productId: P_NEXUS, designId: blue.id, quantity: 6 },
    ...(fireDesign ? [{ productId: P_CLEAR, designId: fireDesign.id, quantity: 2 }] : []),
    { productId: P_PLAIN, quantity: 3 },
  ];
  const customerName = `E2E32 Probe ${RUN}`;
  const requestId = await anon.orderRequests.submit({ customerName, phone, deliveryLocation: "Mogadishu", lines: requestLines, submissionKey: globalThis.crypto.randomUUID() });
  check("O1", "a visitor submits an order with two designs of one product, another product's design and a plain product", /^[0-9a-f-]{36}$/.test(requestId), String(requestId));
  const dupPair = await errOf(() => anon.orderRequests.submit({ customerName, phone, lines: [{ productId: P_NEXUS, designId: red.id, quantity: 1 }, { productId: P_NEXUS, designId: red.id, quantity: 2 }], submissionKey: globalThis.crypto.randomUUID() }));
  check("O2", "the same product + design twice is refused", /Each design of a product can be listed once/.test(dupPair ?? ""), dupPair ?? "no error");
  const wrongDesign = await errOf(() => anon.orderRequests.submit({ customerName, phone, lines: [{ productId: P_PLAIN, designId: red.id, quantity: 1 }], submissionKey: globalThis.crypto.randomUUID() }));
  check("O3", "a design of another product is refused", /A selected design is not available/.test(wrongDesign ?? ""), wrongDesign ?? "no error");
  const offDesign = await errOf(() => anon.orderRequests.submit({ customerName, phone, lines: [{ productId: P_NEXUS, designId: hidden.id, quantity: 1 }], submissionKey: globalThis.crypto.randomUUID() }));
  check("O4", "a switched-off design is refused", /A selected design is not available/.test(offDesign ?? ""), offDesign ?? "no error");

  // ---- 5. what the admin sees on the request -----------------------------------------------------------------------------------
  const reqs = await sa.db.orderRequests.list();
  const req = reqs.find((r) => r.id === requestId);
  const L = req?.lines ?? [];
  const sig = (l) => `${l.productId}:${l.designName || "-"}:${l.quantity}`;
  const expected = [`${P_NEXUS}:E2E32 Crimson ${RUN}:4`, `${P_NEXUS}:E2E32 Blue ${RUN}:6`, ...(fireDesign ? [`${P_CLEAR}:${fireDesign.name}:2`] : []), `${P_PLAIN}:-:3`];
  check("A1", "the Hub's request data lists every line with its own product, design and quantity", JSON.stringify(L.map(sig)) === JSON.stringify(expected), JSON.stringify(L.map(sig)));
  check("A2", "each designed line carries the design id (so conversion can keep it); the plain line has none", L.filter((l) => l.designId).length === requestLines.filter((l) => l.designId).length && !L.at(-1)?.designId);
  check("A3", "the request is new and no order exists for it yet", req?.status === "new" && !req?.convertedOrderId);
  check("A4", "the stored name is the design's name at the time of the order (Crimson, renamed before ordering)", L[0]?.designName === `E2E32 Crimson ${RUN}`);
  check("A7", "a website request that carries designs is NOT marked as a customer-app request", req?.app === undefined);
  const appReq = reqs.find((r) => r.app);
  check("A8", "genuine customer-app requests keep their app marker and their designs (regression)", !appReq || (Boolean(appReq.app.customerId) && appReq.lines.every((l) => typeof l.designName === "string")), appReq ? JSON.stringify(appReq.app) : "no app request on Staging");
  const manager = await staff("efz.ops@example.com", "E2E_MANAGER_PASSWORD");
  const mreq = (await manager.db.orderRequests.list()).find((r) => r.id === requestId);
  check("A5", "a Manager sees the same designs on the request", JSON.stringify((mreq?.lines ?? []).map(sig)) === JSON.stringify(expected));
  const csReqs = await cs.db.orderRequests.list().catch(() => []);
  check("A6", "Customer Service (no website-request privilege) sees no requests", !csReqs.some((r) => r.id === requestId), String(csReqs.length));

  // ---- 6. conversion: design, quantity and price per line; stock, payments, commissions do not move ------------------------------
  const customer = (await sa.db.customers.list()).find((c) => c.status === "active");
  const priced = [];
  for (const l of L) {
    const info = await sa.db.orders.resolvePrice(customer.id, l.productId, l.designName || undefined);
    priced.push({ l, info, product: await sa.db.products.get(l.productId) });
  }
  check("P1", "every line has a resolvable price for the customer (list or agreement), none withheld for review", priced.every((p) => p.info.source !== "review" && p.info.price !== null), JSON.stringify(priced.map((p) => p.info.source)));
  // staff work the request first: contacted, then confirmed (only a confirmed request can be converted)
  await sa.db.orderRequests.setStatus(requestId, "contacted");
  await sa.db.orderRequests.setStatus(requestId, "confirmed");
  check("P2", "the request moves new -> contacted -> confirmed and keeps its designs", (await sa.db.orderRequests.list()).find((r) => r.id === requestId)?.status === "confirmed");
  const orderId = await sa.db.orderRequests.convert(requestId, {
    customer: { kind: "existing", customerId: customer.id },
    lines: L.map((l) => ({ productId: l.productId, quantity: l.quantity, ...(l.designId ? { designId: l.designId } : l.designName ? { designName: l.designName } : {}) })),
    deliveryNotes: "E2E32 conversion probe",
  });
  const order = await sa.db.orders.get(orderId);
  const items = order?.items ?? [];
  // create_order labels a line that has no design with the product's own name (coalesce(nullif(designName,''), product name)); a designed line keeps its design name.
  const nameOfProduct = Object.fromEntries(priced.map((p) => [p.l.productId, p.product.name]));
  const labelOf = (l) => l.designName || nameOfProduct[l.productId];
  const isig = (i) => `${i.productId}:${i.designName}:${i.quantity}`;
  const wantItems = L.map((l) => `${l.productId}:${labelOf(l)}:${l.quantity}`);
  check("C1", "conversion creates an order whose lines keep product, design and quantity (a plain line is labelled with its product)", JSON.stringify(items.map(isig).sort()) === JSON.stringify(wantItems.sort()), JSON.stringify(items.map(isig)));
  const priceOk = priced.every(({ l, info }) => {
    const item = items.find((i) => i.productId === l.productId && i.designName === labelOf(l));
    return item && money(item.actualUnitPrice) === money(info.price);
  });
  check("C2", "each line is charged exactly the price the resolver gave for that design (agreement, else list)", priceOk, JSON.stringify(items.map((i) => [i.designName, i.actualUnitPrice])));
  const listOk = priced.filter((p) => p.info.source === "list").every(({ l, product }) => money(items.find((i) => i.productId === l.productId && i.designName === labelOf(l)).actualUnitPrice) === money(product.sellingPrice));
  check("C3", "...and where no agreement applies that is the product's list price (a design has no price of its own)", listOk);
  const expectedTotal = items.reduce((s, i) => s + money(i.actualUnitPrice) * i.quantity, 0);
  check("C4", "the order total is the sum of the lines (quantity x price), with no extra charge", money(order.total) === expectedTotal, `${order.total} vs ${expectedTotal / 100}`);
  check("C5", "the order is the customer's, unpaid, with no payment and nothing delivered", order.customerId === customer.id && money(order.amountPaid) === 0 && order.status !== "delivered");
  const after = {};
  for (const id of [P_NEXUS, P_CLEAR, P_PLAIN]) after[id] = (await sa.db.products.get(id))?.stock;
  check("C6", "stock did not move on conversion (it moves on delivery only)", JSON.stringify(after) === JSON.stringify(before), JSON.stringify({ before, after }));
  const reqAfter = (await sa.db.orderRequests.list()).find((r) => r.id === requestId);
  check("C7", "the request is marked converted and points at the order", reqAfter?.status === "converted" && reqAfter?.convertedOrderId === orderId, JSON.stringify([reqAfter?.status, reqAfter?.convertedOrderId]));
  const again = await errOf(() => sa.db.orderRequests.convert(requestId, { customer: { kind: "existing", customerId: customer.id }, lines: [{ productId: P_PLAIN, quantity: 1 }] }));
  check("C8", "converting the same request twice is refused (no duplicate order or charge)", Boolean(again), again ?? "no error");

  // ---- 7. clean up what this run made (nothing is deleted) ---------------------------------------------------------------------
  await sa.db.orders.setStatus(orderId, "cancelled", "E2E32 probe - cancelled after verification");
  const cancelled = await sa.db.orders.get(orderId);
  check("Z1", "the test order is cancelled", cancelled?.status === "cancelled");
  const end = {};
  for (const id of [P_NEXUS, P_CLEAR, P_PLAIN]) end[id] = (await sa.db.products.get(id))?.stock;
  check("Z2", "stock is still untouched after cancelling", JSON.stringify(end) === JSON.stringify(before));
  for (const id of made) await sa.db.designs.setActive(id, false);
  pub = await anon.products.listPublicDesigns();
  check("Z3", "the test designs are switched off and no longer visible to visitors", !pub.some((d) => made.includes(d.id)));

  console.log(`\n     request ${requestId}  order ${orderId}  customer ${customer.id}`);
  console.log(`     lines: ${items.map((i) => `${i.designName} x${i.quantity} @ $${Number(i.actualUnitPrice).toFixed(2)}`).join(" | ")}  total $${Number(order.total).toFixed(2)}`);
} catch (e) {
  results.push(false);
  console.log(`FAIL E2E stopped: ${e instanceof Error ? e.message : String(e)}`);
} finally {
  // Even when a check threw: never leave this run's test designs switched on for visitors.
  try {
    const sa2 = await staff("efz.superadmin@example.com", "E2E_SUPERADMIN_PASSWORD");
    for (const id of made) await sa2.db.designs.setActive(id, false);
  } catch { /* nothing more to do */ }
}

const failed = results.filter((r) => !r).length;
console.log(`\nE2E32: ${results.length - failed} PASS, ${failed} FAIL`);
process.exit(failed ? 1 : 0);
