// Drives the REAL /admin/product-designs page in jsdom. No network, no Supabase: lib/supabase/db is stubbed with an in-memory store that applies the database's rules.
// Plain JS (tsc ignores it). Needs jsdom and esbuild, which are not project dependencies:
//   npm i --no-save jsdom esbuild && node scripts/product-designs-dom-test/run.mjs
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

// ---- fixtures ------------------------------------------------------------------------------------------------------------------
const P = (id, name, isActive = true) => ({ id, name, isActive, price: 10, sellingPrice: 10, costPrice: null });
const PRODUCTS = [P("fire", "EFZ - Fire Ball"), P("nexus", "EFZ - Nexus"), P("old", "Retired Ball", false)];
const D = (id, productId, name, sortOrder, isActive = true, imageUrl = "") => ({ id, productId, name, imageUrl, sortOrder, isActive, createdAt: "2026-10-01T00:00:00Z", updatedAt: "2026-10-01T00:00:00Z" });
const manager = { id: "u-m", role: "Manager", status: "active", permissions: ["edit_products", "view_products"] };
const cs = { id: "u-cs", role: "Customer Service", status: "active", permissions: ["view_products"] };

// ---- helpers ------------------------------------------------------------------------------------------------------------------
const setValue = (el, value) => {
  const proto = el.tagName === "SELECT" ? dom.window.HTMLSelectElement.prototype : dom.window.HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, "value").set.call(el, value);
  el.dispatchEvent(new dom.window.Event(el.tagName === "SELECT" ? "change" : "input", { bubbles: true }));
};
const tick = () => act(async () => { await new Promise((r) => setTimeout(r, 0)); });
const set = async (el, v) => { await act(async () => { setValue(el, v); }); };
const click = async (el) => { await act(async () => { el.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true })); }); await tick(); await tick(); };
const q = (s) => doc.querySelector(s);
const qa = (s) => [...doc.querySelectorAll(s)];
const names = () => qa('[data-testid="design-name"]').map((n) => n.textContent);
const rowOf = (name) => qa('[data-testid="design-row"]').find((r) => r.querySelector('[data-testid="design-name"]')?.textContent === name);

async function scenario({ me = manager, designs = [], canWrite = true }, body) {
  const container = doc.getElementById("app");
  container.innerHTML = "";
  globalThis.__world = { me, products: PRODUCTS, designs: designs.map((d) => ({ ...d })), canWrite, calls: [] };
  const unmount = mount(container);
  await tick(); await tick();
  try { await body(globalThis.__world); } finally { unmount(); }
}

// ===================== who sees it =====================
await scenario({ me: cs }, async (w) => {
  check("A1", "staff without edit_products see an explanation, not the screen", Boolean(q('[data-testid="designs-denied"]')) && !q('[data-testid="design-create"]'));
});

// ===================== empty =====================
await scenario({}, async () => {
  check("E1", "with no designs the screen explains what that means for the order form", /exactly as before/.test(q('[data-testid="designs-empty"]')?.textContent ?? ""));
  const opts = [...doc.getElementById("nd-product").options].map((o) => o.textContent);
  check("E2", "only active products can receive a new design (the retired ball is not offered)", opts.includes("EFZ - Fire Ball") && !opts.includes("Retired Ball"), opts.join("|"));
});

// ===================== create =====================
await scenario({}, async (w) => {
  await click(q('[data-testid="design-create"]'));
  check("C1", "adding with nothing filled in shows what is missing and calls nothing", w.calls.length === 0 && /Choose the product/.test(doc.body.textContent) && /Enter the design name/.test(doc.body.textContent));

  await set(doc.getElementById("nd-product"), "fire");
  await set(doc.getElementById("nd-name"), "  Red  ");
  await set(doc.getElementById("nd-image"), "http://example.com/red.png");
  await click(q('[data-testid="design-create"]'));
  check("C2", "an http:// picture link is refused before anything is sent", w.calls.length === 0 && /must start with https/.test(doc.body.textContent));

  await set(doc.getElementById("nd-image"), "https://example.com/red.png");
  await set(doc.getElementById("nd-order"), "2");
  await click(q('[data-testid="design-create"]'));
  check("C3", "a valid design is created once, with trimmed name and numeric order", w.calls.length === 1 && w.calls[0][0] === "create" && w.calls[0][1].name === "Red" && w.calls[0][1].sortOrder === 2 && w.calls[0][1].productId === "fire", JSON.stringify(w.calls));
  check("C4", "it appears under its product and the screen says it is on the order form", names().join() === "Red" && /on the order form now/.test(q('[data-testid="designs-done"]')?.textContent ?? ""));
  check("C5", "the product stays chosen for the next design and the name is cleared", doc.getElementById("nd-product").value === "fire" && doc.getElementById("nd-name").value === "");
  check("C6", "the group header counts what visitors see (1)", /1 on the order form/.test(q('[data-testid="design-group"]')?.textContent ?? ""));

  await set(doc.getElementById("nd-name"), "red");
  await click(q('[data-testid="design-create"]'));
  check("C7", "the same name on the same product (any case) is refused with a sentence", w.calls.length === 1 && /already has a design with that name/.test(doc.body.textContent));

  await set(doc.getElementById("nd-product"), "nexus");
  await click(q('[data-testid="design-create"]'));
  check("C8", "the same name on ANOTHER product is accepted", w.calls.length === 2 && names().length === 2, JSON.stringify(names()));
});

// ===================== edit =====================
await scenario({ designs: [D("d1", "fire", "Red", 2, true, "https://example.com/red.png"), D("d2", "fire", "Blue", 1)] }, async (w) => {
  check("D1", "designs are listed in display order within their product (Blue 1 before Red 2)", names().join() === "Blue,Red", names().join());
  check("D2", "a design's picture has a text alternative", q('img[alt="Red design"]') !== null);
  await click(rowOf("Red").querySelector('button[aria-label="Edit Red"]'));
  check("D3", "Edit opens the fields with the current values", doc.getElementById("e-name-d1").value === "Red" && doc.getElementById("e-img-d1").value === "https://example.com/red.png" && doc.getElementById("e-ord-d1").value === "2");
  await set(doc.getElementById("e-name-d1"), "Blue");
  await click(q('[data-testid="design-save"]'));
  check("D4", "renaming to a name the product already has is refused, before anything is sent", w.calls.length === 0 && /already has a design with that name/.test(doc.body.textContent));
  await set(doc.getElementById("e-name-d1"), "Crimson");
  await set(doc.getElementById("e-img-d1"), "javascript:alert(1)");
  await click(q('[data-testid="design-save"]'));
  check("D5", "a javascript: picture link is refused", w.calls.length === 0 && /must start with https/.test(doc.body.textContent));
  await set(doc.getElementById("e-img-d1"), "https://example.com/crimson.png");
  await set(doc.getElementById("e-ord-d1"), "abc");
  await click(q('[data-testid="design-save"]'));
  check("D6", "a non-numeric display order is refused", w.calls.length === 0 && /display order must be a whole number/.test(doc.body.textContent));
  await set(doc.getElementById("e-ord-d1"), "0");
  await click(q('[data-testid="design-save"]'));
  check("D7", "a valid save sends only name, picture and order", w.calls.length === 1 && JSON.stringify(w.calls[0]) === JSON.stringify(["update", "d1", { name: "Crimson", imageUrl: "https://example.com/crimson.png", sortOrder: 0 }]), JSON.stringify(w.calls));
  check("D8", "the list reflects the change and re-sorts (Crimson 0 before Blue 1)", names().join() === "Crimson,Blue", names().join());
  check("D9", "editing closes after a save", !q('[data-testid="design-save"]'));
});

// ===================== switch on / off =====================
await scenario({ designs: [D("d1", "fire", "Red", 1), D("d2", "fire", "Blue", 2)] }, async (w) => {
  const header = () => q('[data-testid="design-group"] span.text-xs')?.textContent ?? "";
  check("S1", "both designs start active (2 on the order form)", /2 on the order form/.test(header()), header());
  await click(rowOf("Red").querySelector('[data-testid="design-toggle"]'));
  check("S2", "switching off calls setActive(false) and the row shows 'Switched off'", w.calls.at(-1)?.join() === "setActive,d1,false" && /Switched off/.test(rowOf("Red").textContent));
  check("S3", "the count drops to 1 and the message says requests that use it are unchanged", /1 on the order form/.test(header()) && /already use it are unchanged/.test(q('[data-testid="designs-done"]')?.textContent ?? ""));
  await click(rowOf("Red").querySelector('[data-testid="design-toggle"]'));
  check("S4", "switching on again restores it (2) with a message", w.calls.at(-1)?.join() === "setActive,d1,true" && /2 on the order form/.test(header()) && /appears on the order form/.test(q('[data-testid="designs-done"]')?.textContent ?? ""));
  check("S5", "there is no delete button anywhere", !qa("button").some((b) => /delete|remove/i.test(b.textContent + (b.getAttribute("aria-label") ?? ""))));
});

// ===================== filters =====================
await scenario({ designs: [D("d1", "fire", "Red", 1), D("d2", "fire", "Blue", 2, false), D("d3", "nexus", "Gold", 1)] }, async () => {
  await set(doc.getElementById("f-status"), "inactive");
  check("L1", "the status filter shows only switched-off designs", names().join() === "Blue", names().join());
  await set(doc.getElementById("f-status"), "all"); await set(doc.getElementById("f-product"), "nexus");
  check("L2", "the product filter shows only that product's designs", names().join() === "Gold", names().join());
  await set(doc.getElementById("f-product"), ""); await set(doc.getElementById("f-search"), "RE");
  check("L3", "the search matches names regardless of case", names().join() === "Red", names().join());
  await set(doc.getElementById("f-search"), "zzz");
  check("L4", "no match says so", /No design matches/.test(doc.body.textContent));
});

// ===================== the database refuses =====================
await scenario({ canWrite: false, designs: [D("d1", "fire", "Red", 1)] }, async (w) => {
  await click(rowOf("Red").querySelector('[data-testid="design-toggle"]'));
  check("R1", "when the database refuses a change, its sentence is shown and nothing changes on screen", /Permission denied/.test(q('[data-testid="designs-problem"]')?.textContent ?? "") && /Active/.test(rowOf("Red").textContent) && !q('[data-testid="designs-done"]'));
  await set(doc.getElementById("nd-product"), "nexus"); await set(doc.getElementById("nd-name"), "Gold");
  await click(q('[data-testid="design-create"]'));
  check("R2", "a refused create shows the database's sentence and adds nothing", /Permission denied/.test(q('[data-testid="designs-problem"]')?.textContent ?? "") && names().join() === "Red");
});

console.log(`\nPRODUCT DESIGNS DOM: ${pass} PASS, ${fail} FAIL`);
process.exit(fail ? 1 : 0);
