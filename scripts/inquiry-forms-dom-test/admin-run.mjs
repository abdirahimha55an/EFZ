// Drives the real admin InquiriesInbox / InquiryDetail in jsdom with a stubbed data layer: list, tabs, filters, search, detail, and which
// actions each permission set is offered. Plain JS (tsc ignores it). Needs jsdom and esbuild, which are not project dependencies:
//   npm i --no-save jsdom esbuild && node scripts/inquiry-forms-dom-test/admin-run.mjs
import { build } from "esbuild";
import { JSDOM } from "jsdom";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const out = path.join(here, ".admin-bundle.cjs");

await build({
  entryPoints: [path.join(here, "admin-entry.js")],
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
        b.onResolve({ filter: /^(@\/lib\/supabase\/db|next\/navigation)$/ }, () => ({ path: path.join(here, "admin-stubs.js") }));
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

const dom = new JSDOM("<!doctype html><html><body><div id='app'></div></body></html>", { url: "http://localhost/admin/inquiries", pretendToBeVisual: true });
for (const k of ["window", "document", "navigator", "HTMLElement", "HTMLInputElement", "HTMLTextAreaElement", "HTMLSelectElement", "Node", "Event", "MouseEvent", "getComputedStyle"]) {
  Object.defineProperty(globalThis, k, { value: dom.window[k] ?? undefined, configurable: true, writable: true });
}
globalThis.IS_REACT_ACT_ENVIRONMENT = true;
Object.defineProperty(globalThis, "requestAnimationFrame", { value: (f) => setTimeout(f, 0), configurable: true });

const { mount, act } = createRequire(import.meta.url)(out);
const doc = dom.window.document;

let pass = 0;
let fail = 0;
const check = (id, name, ok, info = "") => {
  if (ok) pass++; else fail++;
  console.log(`${ok ? "PASS" : "FAIL"} ${id} ${name}${ok ? "" : info ? `  [${info}]` : ""}`);
};

const hoursAgo = (h) => new Date(Date.now() - h * 3600_000).toISOString();
const inquiry = (o) => ({ id: "", reference: "", kind: "contact", name: "", organization: "", businessType: "", phone: "", phoneCanonical: null, email: "", subject: "", message: "", status: "new", assignedTo: null, handledBy: null, closedReason: null, statusChangedAt: null, createdAt: hoursAgo(1), ...o });
const baseInquiries = () => [
  inquiry({ id: "aaaaaaaa-0000-4000-8000-000000000001", reference: "INQ-AAAAAAAA", kind: "contact", name: "Hodan Ali", phone: "0612345678", phoneCanonical: "+252612345678", email: "", subject: "Prices", message: "How much is a futsal ball?", createdAt: hoursAgo(30) }),
  inquiry({ id: "bbbbbbbb-0000-4000-8000-000000000002", reference: "INQ-BBBBBBBB", kind: "wholesale", name: "Ali Nur", organization: "Mogadishu Arena", businessType: "Futsal Arena", phone: "0619998888", phoneCanonical: "+252619998888", message: "50 balls a month", createdAt: hoursAgo(2) }),
  inquiry({ id: "cccccccc-0000-4000-8000-000000000003", reference: "INQ-CCCCCCCC", kind: "contact", name: "Old Closed", email: "old@example.com", subject: "Old", message: "done", status: "closed", closedReason: "Answered by phone", createdAt: hoursAgo(100) }),
];
const profile = (role, permissions) => ({ id: "u1", name: "Tester", email: "t@example.com", phone: "", avatar: "", role, status: "active", commissionPercentage: 0, earnedCommissionTotal: 0, pendingCommissionTotal: 0, paidCommissionTotal: 0, permissions });

const tick = () => act(async () => { await new Promise((r) => setTimeout(r, 0)); });
const click = async (el) => { await act(async () => { el.click(); }); await tick(); };
const rows = () => [...doc.querySelectorAll("[data-testid=inquiry-row]")];
const buttonByText = (re) => [...doc.querySelectorAll("button")].find((b) => re.test(b.textContent));

async function run(role, permissions, body, world = {}, url = "/admin/inquiries") {
  dom.window.history.replaceState(null, "", url);
  globalThis.__world = { profile: profile(role, permissions), staff: [{ id: "u2", name: "Delegate Dee", role: "Manager" }], inquiries: baseInquiries(), notes: [], events: [{ seq: 1, event: "submitted", fromStatus: null, toStatus: "new", actorName: "", note: null, assignedToName: null, occurredAt: hoursAgo(1) }], assignees: [{ id: "u2", name: "Delegate Dee", role: "Manager" }], calls: [], ...world };
  const container = doc.getElementById("app");
  container.innerHTML = "";
  const unmount = mount(container);
  await tick();
  try { await body(globalThis.__world); } finally { unmount(); }
}

// ---- Super Admin: sees and can do everything ----
await run("Super Admin", [], async (w) => {
  check("I1", "the page title and an Open tab with the 2 open inquiries (closed hidden)", /Contact & Wholesale/.test(doc.querySelector("[data-testid=inquiries-title]").textContent) && rows().length === 2, `${rows().length}`);
  check("I2", "counters show new / contacted / closed", doc.querySelector("[data-testid=inquiry-counter-new]").textContent.includes("2") && doc.querySelector("[data-testid=inquiry-counter-closed]").textContent.includes("1"));
  check("I3", "rows carry type and status for both kinds", rows().some((r) => r.dataset.kind === "wholesale") && rows().some((r) => r.dataset.kind === "contact"));
  check("I4", "a waiting inquiry older than 24 h is flagged red", rows().find((r) => /Hodan/.test(r.textContent)).querySelector("td:nth-child(2)").className.includes("text-red-600"));
  await click([...doc.querySelectorAll("button")].find((b) => b.textContent === "All"));
  check("I5", "the All tab includes the closed inquiry", rows().length === 3);
  await click([...doc.querySelectorAll("button")].find((b) => b.textContent === "Open"));
  const kind = doc.querySelector("select[aria-label=Type]");
  await act(async () => { Object.getOwnPropertyDescriptor(dom.window.HTMLSelectElement.prototype, "value").set.call(kind, "wholesale"); kind.dispatchEvent(new dom.window.Event("change", { bubbles: true })); });
  check("I6", "the type filter narrows to wholesale", rows().length === 1 && /Mogadishu Arena/.test(rows()[0].textContent));
  await act(async () => { Object.getOwnPropertyDescriptor(dom.window.HTMLSelectElement.prototype, "value").set.call(kind, "all"); kind.dispatchEvent(new dom.window.Event("change", { bubbles: true })); });
  const search = doc.querySelector("input[aria-label='Search inquiries']");
  await act(async () => { Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value").set.call(search, "futsal ball"); search.dispatchEvent(new dom.window.Event("input", { bubbles: true })); });
  check("I7", "search matches message text", rows().length === 1 && /Hodan/.test(rows()[0].textContent));
  await act(async () => { Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value").set.call(search, "9998888"); search.dispatchEvent(new dom.window.Event("input", { bubbles: true })); });
  check("I9", "search by phone digits finds the wholesale inquiry", rows().length === 1 && /Mogadishu/.test(rows()[0].textContent), `${rows().length}`);
  await act(async () => { Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value").set.call(search, ""); search.dispatchEvent(new dom.window.Event("input", { bubbles: true })); });

  await click(rows().find((r) => /Hodan/.test(r.textContent)));
  const detail = doc.querySelector("[data-testid=inquiry-detail]");
  check("I10", "clicking a row opens its detail with the visitor's message", Boolean(detail) && /How much is a futsal ball\?/.test(detail.textContent) && /INQ-AAAAAAAA/.test(detail.textContent));
  check("I11", "phone gets Call and WhatsApp links", Boolean(detail.querySelector("a[href='tel:+252612345678']")) && Boolean(detail.querySelector("a[href^='https://wa.me/252612345678']")));
  check("I12", "Super Admin is offered Mark Contacted, Close, assignment and notes", Boolean(buttonByText(/Mark Contacted/)) && Boolean(buttonByText(/^\s*Close\s*$/)) && Boolean(detail.querySelector("#inquiry-assignee")) && Boolean(detail.querySelector("textarea[aria-label='New note']")));
  await click(buttonByText(/Mark Contacted/));
  check("I13", "Mark Contacted calls setStatus and refreshes the shared signal", w.calls.some((c) => c[0] === "setStatus" && c[2] === "contacted") && (globalThis.__refreshed ?? 0) > 0);
  await click(buttonByText(/^\s*Close\s*$/));
  const reason = doc.getElementById("close-reason");
  await act(async () => { Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value").set.call(reason, "Quote sent"); reason.dispatchEvent(new dom.window.Event("input", { bubbles: true })); });
  await click(buttonByText(/Close inquiry/));
  check("I14", "Close sends the optional outcome", w.calls.some((c) => c[0] === "setStatus" && c[2] === "closed" && c[3] === "Quote sent"), JSON.stringify(w.calls));
  check("I15", "a closed inquiry offers Reopen, not Close", Boolean(buttonByText(/Reopen/)) && !buttonByText(/^\s*Close\s*$/));
  const sel = doc.getElementById("inquiry-assignee");
  check("I16", "a closed inquiry cannot be (re)assigned in the UI", !sel);
});

// ---- Delegate who may only view: no action buttons ----
await run("Manager", ["view_inquiries"], async () => {
  await click(rows()[0]);
  const detail = doc.querySelector("[data-testid=inquiry-detail]");
  check("P1", "view-only: the inquiry is readable", Boolean(detail));
  check("P2", "view-only: no status buttons, no assignment, no note box", !buttonByText(/Mark Contacted/) && !buttonByText(/^\s*Close\s*$/) && !detail.querySelector("#inquiry-assignee") && !detail.querySelector("textarea[aria-label='New note']"));
});

// ---- Delegate who may work but not assign ----
await run("Manager", ["view_inquiries", "manage_inquiries"], async () => {
  await click(rows()[0]);
  const detail = doc.querySelector("[data-testid=inquiry-detail]");
  check("M1", "manage: status buttons and note box shown", Boolean(buttonByText(/Mark Contacted/)) && Boolean(detail.querySelector("textarea[aria-label='New note']")));
  check("M2", "manage without assign: no assignment picker", !detail.querySelector("#inquiry-assignee"));
});

// ---- Assigner ----
await run("Manager", ["view_inquiries", "view_all_inquiries", "assign_inquiries"], async (w) => {
  await click(rows()[0]);
  const sel = doc.getElementById("inquiry-assignee");
  check("A1", "assign: the picker lists the assignable staff", Boolean(sel) && [...sel.options].some((o) => /Delegate Dee/.test(o.textContent)));
  await act(async () => { Object.getOwnPropertyDescriptor(dom.window.HTMLSelectElement.prototype, "value").set.call(sel, "u2"); sel.dispatchEvent(new dom.window.Event("change", { bubbles: true })); });
  await click(buttonByText(/^\s*Assign\s*$/));
  check("A2", "Assign calls assign() with the chosen user", w.calls.some((c) => c[0] === "assign" && c[2] === "u2"), JSON.stringify(w.calls));
  check("A3", "assign-only: no status buttons", !buttonByText(/Mark Contacted/));
});

// ---- Empty state and deep link to an inquiry the user cannot see ----
await run("Super Admin", [], async () => {
  check("E1", "no inquiries -> an empty state", rows().length === 0 && /No inquiries here/.test(doc.body.textContent));
}, { inquiries: [] });
await run("Super Admin", [], async () => {
  check("E2", "a deep link to an unavailable inquiry says so instead of showing a blank", /not available to you|no longer exists/.test(doc.body.textContent));
}, {}, "/admin/inquiries?id=nope");

console.log(`\nADMIN DOM: ${pass} PASS, ${fail} FAIL`);
process.exit(fail ? 1 : 0);
