// Drives the REAL public /order page in jsdom. No network, no Supabase: lib/supabase/db is stubbed; each scenario decides the catalog, the designs and what submit() does.
// Plain JS (tsc ignores it). Needs jsdom and esbuild, which are not project dependencies:
//   npm i --no-save jsdom esbuild && node scripts/order-form-dom-test/run.mjs
import { build } from "esbuild";
import { JSDOM } from "jsdom";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const out = path.join(here, ".bundle.cjs");

await build({
  entryPoints: [path.join(here, "entry.js")],
  outfile: out,
  bundle: true,
  platform: "node",
  format: "cjs",
  jsx: "automatic",
  define: { "process.env.NODE_ENV": '"development"' },
  loader: { ".js": "jsx" },
  plugins: [
    {
      name: "efz-alias",
      setup(b) {
        b.onResolve({ filter: /^@\/lib\/supabase\/db$/ }, () => ({ path: path.join(here, "db-stub.js") }));
        b.onResolve({ filter: /^@\// }, (args) => {
          const base = path.join(root, args.path.slice(2));
          for (const ext of [".tsx", ".ts", "/index.ts", "/index.tsx"]) {
            try {
              if (fs.statSync(base + ext).isFile()) return { path: base + ext };
            } catch { /* try the next */ }
          }
          return undefined;
        });
      },
    },
  ],
  logLevel: "error",
});

const dom = new JSDOM("<!doctype html><html><body><div id='app'></div></body></html>", { url: "http://localhost/", pretendToBeVisual: true });
for (const k of ["window", "document", "navigator", "HTMLElement", "HTMLInputElement", "HTMLTextAreaElement", "HTMLSelectElement", "Node", "Event", "MouseEvent", "KeyboardEvent", "getComputedStyle"]) {
  Object.defineProperty(globalThis, k, { value: dom.window[k] ?? undefined, configurable: true, writable: true });
}
globalThis.IS_REACT_ACT_ENVIRONMENT = true;
Object.defineProperty(globalThis, "requestAnimationFrame", { value: (f) => setTimeout(f, 0), configurable: true });

const require2 = createRequire(import.meta.url);
const { mount, act } = require2(out);
const doc = dom.window.document;

let pass = 0;
let fail = 0;
const check = (id, name, ok, info = "") => {
  if (ok) pass++; else fail++;
  console.log(`${ok ? "PASS" : "FAIL"} ${id} ${name}${ok ? "" : info ? `  [${info}]` : ""}`);
};

// ---- fixtures: the same shape the real mapper receives (public_products rows) -------------------------------------------------
const row = (id, name, price, extra = {}) => ({ id, name, description: "", size: "5", durability: "", surface_type: "", is_wholesale: false, selling_price: price, image_url: "", in_stock: true, category: "Football", ...extra });
const PRODUCTS = [row("fire", "EFZ - Fire Ball", 12.5), row("nexus", "EFZ - Nexus", 10), row("phantom", "Phantom Blue", 14)];
const DESIGNS = [
  { id: "d-red", productId: "fire", name: "Red", imageUrl: "https://example.com/red.png" },
  { id: "d-blue", productId: "fire", name: "Blue", imageUrl: "" },
  { id: "d-gold", productId: "nexus", name: "Gold", imageUrl: "" },
];

// ---- helpers ------------------------------------------------------------------------------------------------------------------
const setValue = (el, value) => {
  const proto = el.tagName === "TEXTAREA" ? dom.window.HTMLTextAreaElement.prototype : el.tagName === "SELECT" ? dom.window.HTMLSelectElement.prototype : dom.window.HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, "value").set.call(el, value);
  el.dispatchEvent(new dom.window.Event(el.tagName === "SELECT" ? "change" : "input", { bubbles: true }));
};
const tick = () => act(async () => { await new Promise((r) => setTimeout(r, 0)); });
const set = async (el, value) => { await act(async () => { setValue(el, value); }); };
const q = (sel) => doc.querySelector(sel);
const byLabel = (label) => doc.querySelector(`[aria-label="${label}"]`);
const byPlaceholder = (p) => doc.querySelector(`input[placeholder="${p}"]`);
const lines = () => [...doc.querySelectorAll('[data-testid="order-line"]')];
const optionState = (select) => Object.fromEntries([...select.options].filter((o) => o.value).map((o) => [o.textContent.replace(/ - \$.*/, ""), o.disabled ? "disabled" : "enabled"]));
const click = async (el) => { await act(async () => { el.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true })); }); };
const addLine = async () => { await click([...doc.querySelectorAll("button")].find((b) => /Add another product/.test(b.textContent))); };
const submit = async () => { await act(async () => { q("form").dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); }); await tick(); };
const errorText = () => [...doc.querySelectorAll("p")].map((p) => p.textContent).find((t) => /Line \d|Choose|Please choose|already|no longer|Quantity/.test(t)) ?? "";
const fillCustomer = async () => { await set(byPlaceholder("Full Name"), "Hodan Ali"); await set(byPlaceholder("061 234 5678"), "061 234 5678"); };

async function scenario({ designs = DESIGNS, products = PRODUCTS, submitMode = "ok" }, body) {
  const container = doc.getElementById("app");
  container.innerHTML = "";
  const calls = [];
  globalThis.__products = products;
  globalThis.__designs = designs;
  globalThis.__submit = (input) => {
    calls.push(input);
    return submitMode === "fail" ? Promise.reject(new Error("The database said no")) : Promise.resolve("11111111-1111-4111-8111-111111111111");
  };
  const unmount = mount(container);
  await tick(); await tick();
  try { await body({ calls }); } finally { unmount(); }
}

// ===================== with designs =====================
await scenario({}, async ({ calls }) => {
  check("O1", "the page loads with one line: a product select and a quantity, no design select yet", lines().length === 1 && Boolean(byLabel("Product 1")) && Boolean(byLabel("Quantity 1")) && !byLabel("Design 1"));
  check("O2", "all three products are offered", Object.keys(optionState(byLabel("Product 1"))).join("|") === "EFZ - Fire Ball|EFZ - Nexus|Phantom Blue");

  await set(byLabel("Product 1"), "fire");
  check("O3", "choosing a product that has designs shows its own Design select, with exactly its designs", Boolean(byLabel("Design 1")) && Object.keys(optionState(byLabel("Design 1"))).join("|") === "Red|Blue");
  check("O4", "the design is required", byLabel("Design 1").required === true);

  await fillCustomer();
  await submit();
  check("O5", "sending without a design is stopped with a clear sentence and nothing is submitted", calls.length === 0 && /Choose a design/.test(errorText()), errorText());

  await set(byLabel("Design 1"), "d-red");
  await set(byLabel("Quantity 1"), "3");
  check("O6", "the line shows its own price: $12.5 x 3 = $37.50", /\$12\.5 × 3 = \$37\.50/.test(q('[data-testid="order-line-total"]')?.textContent ?? ""), q('[data-testid="order-line-summary"]')?.textContent);
  check("O7", "the chosen design's picture is shown with a text alternative", q('[data-testid="order-line-summary"] img')?.getAttribute("alt") === "Red design");

  await addLine();
  check("O8", "'Add another product' adds an independent second line", lines().length === 2 && Boolean(byLabel("Product 2")) && !byLabel("Design 2"));
  check("O9", "the same product is still offered on line 2 because one of its designs is free", optionState(byLabel("Product 2"))["EFZ - Fire Ball"] === "enabled");
  await set(byLabel("Product 2"), "fire");
  check("O10", "on line 2 the design already used on line 1 is disabled and the other is free", JSON.stringify(optionState(byLabel("Design 2"))) === JSON.stringify({ Red: "disabled", Blue: "enabled" }), JSON.stringify(optionState(byLabel("Design 2"))));
  await set(byLabel("Design 2"), "d-blue");
  await set(byLabel("Quantity 2"), "7");
  const totals = [...doc.querySelectorAll('[data-testid="order-line-total"]')].map((n) => n.textContent);
  check("O11", "each line keeps its own quantity and price (37.50 and 87.50)", totals.length === 2 && /3 = \$37\.50/.test(totals[0]) && /7 = \$87\.50/.test(totals[1]), JSON.stringify(totals));
  check("O12", "the estimated total is the sum ($125.00) and says EFZ confirms the final price", /\$125\.00/.test(q('[data-testid="order-total"]')?.textContent ?? "") && /confirms the final price/.test(q('[data-testid="order-total"]')?.textContent ?? ""));

  await addLine();
  check("O13", "with both Fire Ball designs used, the product is disabled on line 3", optionState(byLabel("Product 3"))["EFZ - Fire Ball"] === "disabled" && optionState(byLabel("Product 3"))["EFZ - Nexus"] === "enabled", JSON.stringify(optionState(byLabel("Product 3"))));
  await set(byLabel("Product 3"), "phantom");
  check("O14", "a product without designs gets no design select", !byLabel("Design 3"));
  await set(byLabel("Quantity 3"), "2");
  check("O15", "the total now includes line 3 ($153.00)", /\$153\.00/.test(q('[data-testid="order-total"]')?.textContent ?? ""), q('[data-testid="order-total"]')?.textContent);

  await set(byLabel("Product 1"), "nexus");
  check("O16", "changing a line's product clears its design and offers the new product's designs", byLabel("Design 1").value === "" && Object.keys(optionState(byLabel("Design 1"))).join("|") === "Gold");
  check("O17", "…and frees the design it used, so line 2's Red... is unaffected and line 1's choice is open again", optionState(byLabel("Design 2")).Blue === "enabled");
  await submit();
  check("O18", "sending with line 1's new design unchosen is stopped, naming the line", calls.length === 0 && /Line 1: Choose a design/.test(errorText()), errorText());
  await set(byLabel("Design 1"), "d-gold");
  await set(byLabel("Quantity 1"), "1");
  await submit();
  check("O19", "a complete order is submitted once, with every line's product, design and quantity", calls.length === 1);
  check("O20", "the payload: Nexus/Gold x1, Fire Ball/Blue x7, Phantom (no design) x2", JSON.stringify(calls[0]?.lines) === JSON.stringify([
    { productId: "nexus", designId: "d-gold", quantity: 1 },
    { productId: "fire", designId: "d-blue", quantity: 7 },
    { productId: "phantom", quantity: 2 },
  ]), JSON.stringify(calls[0]?.lines));
  check("O21", "customer details and the submission key are sent", calls[0]?.customerName === "Hodan Ali" && calls[0]?.phone === "061 234 5678" && typeof calls[0]?.submissionKey === "string");
  check("O22", "after sending, the success message replaces the form", /Order Request Received/.test(doc.body.textContent));
});

// ===================== two designs of one product, nothing else =====================
await scenario({}, async ({ calls }) => {
  await fillCustomer();
  await set(byLabel("Product 1"), "fire"); await set(byLabel("Design 1"), "d-red"); await set(byLabel("Quantity 1"), "10");
  await addLine();
  await set(byLabel("Product 2"), "fire"); await set(byLabel("Design 2"), "d-blue"); await set(byLabel("Quantity 2"), "20");
  await submit();
  check("T1", "two designs of the same product, quantities 10 and 20, are sent as two lines", JSON.stringify(calls[0]?.lines) === JSON.stringify([{ productId: "fire", designId: "d-red", quantity: 10 }, { productId: "fire", designId: "d-blue", quantity: 20 }]), JSON.stringify(calls[0]?.lines));
});

// ===================== a blank row between filled rows keeps the on-screen numbering =====================
await scenario({}, async ({ calls }) => {
  await fillCustomer();
  await set(byLabel("Product 1"), "nexus"); await set(byLabel("Design 1"), "d-gold");
  await addLine();                          // line 2 left blank
  await addLine();
  await set(byLabel("Product 3"), "fire");  // line 3: no design chosen
  await submit();
  check("B1", "the message names the real row (Line 3), not a position in a filtered list", calls.length === 0 && /Line 3: Choose a design/.test(errorText()), errorText());
});

// ===================== no designs at all (older database, or none created): exactly the old behaviour =====================
await scenario({ designs: [] }, async ({ calls }) => {
  await fillCustomer();
  await set(byLabel("Product 1"), "fire");
  check("N1", "with no designs there is no design select", !byLabel("Design 1"));
  await set(byLabel("Quantity 1"), "4");
  await addLine();
  check("N2", "a product already chosen is disabled on the next line, as before", optionState(byLabel("Product 2"))["EFZ - Fire Ball"] === "disabled");
  await set(byLabel("Product 2"), "nexus"); await set(byLabel("Quantity 2"), "5");
  await submit();
  check("N3", "the payload carries no designId", JSON.stringify(calls[0]?.lines) === JSON.stringify([{ productId: "fire", quantity: 4 }, { productId: "nexus", quantity: 5 }]), JSON.stringify(calls[0]?.lines));
});

// ===================== failure keeps the customer's work =====================
await scenario({ submitMode: "fail" }, async ({ calls }) => {
  await fillCustomer();
  await set(byLabel("Product 1"), "fire"); await set(byLabel("Design 1"), "d-blue"); await set(byLabel("Quantity 1"), "6");
  await submit();
  check("F1", "a refused submission shows the database's sentence", calls.length === 1 && /The database said no/.test(doc.body.textContent));
  check("F2", "…and keeps the form filled in (product, design, quantity)", byLabel("Product 1")?.value === "fire" && byLabel("Design 1")?.value === "d-blue" && byLabel("Quantity 1")?.value === "6");
});

// ===================== quantity rules =====================
await scenario({}, async ({ calls }) => {
  await fillCustomer();
  await set(byLabel("Product 1"), "phantom");
  for (const bad of ["0", "2.5", "100001", ""]) {
    await set(byLabel("Quantity 1"), bad);
    await submit();
    check(`Q-${bad || "blank"}`, `quantity "${bad}" is refused before anything is sent`, calls.length === 0 && /Quantity must be a whole number/.test(errorText()), errorText());
  }
});

console.log(`\nORDER FORM DOM: ${pass} PASS, ${fail} FAIL`);
process.exit(fail ? 1 : 0);
