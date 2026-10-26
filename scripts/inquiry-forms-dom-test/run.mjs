// Drives the real public Contact and Wholesale form components in jsdom. No network, no Supabase: lib/supabase/db is stubbed and each test
// decides what submit() does. Plain JS (tsc ignores it). Needs jsdom and esbuild, which are not project dependencies:
//   npm i --no-save jsdom esbuild && node scripts/inquiry-forms-dom-test/run.mjs
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

// ---- helpers: React-aware input changes and clicks, always inside act() -----------------------------------------------------
const setValue = (el, value) => {
  const proto = el.tagName === "TEXTAREA" ? dom.window.HTMLTextAreaElement.prototype : el.tagName === "SELECT" ? dom.window.HTMLSelectElement.prototype : dom.window.HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, "value").set.call(el, value);
  el.dispatchEvent(new dom.window.Event(el.tagName === "SELECT" ? "change" : "input", { bubbles: true }));
};
const type = async (id, value) => { await act(async () => { setValue(doc.getElementById(id), value); }); };
const blur = async (id) => { await act(async () => { const el = doc.getElementById(id); el.focus(); el.blur(); el.dispatchEvent(new dom.window.FocusEvent("focusout", { bubbles: true })); }); };
const submit = async () => { await act(async () => { doc.querySelector("form").dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })); }); };
const tick = () => act(async () => { await new Promise((r) => setTimeout(r, 0)); });
const text = (sel) => doc.querySelector(sel)?.textContent ?? "";
const button = () => doc.querySelector("form button[type=submit]");

async function run(kind, body) {
  const container = doc.getElementById("app");
  container.innerHTML = "";
  const calls = [];
  let release;
  let mode = "ok";
  let failWith = new Error("x");
  globalThis.__submit = (input) => {
    calls.push(input);
    if (mode === "pending") return new Promise((res) => { release = () => res("11111111-1111-4111-8111-111111111111"); });
    if (mode === "fail") return Promise.reject(failWith);
    return Promise.resolve("11111111-1111-4111-8111-111111111111");
  };
  const unmount = mount(kind, container);
  try {
    await body({ calls, setMode: (m, e) => { mode = m; if (e) failWith = e; }, finish: async () => { release(); await tick(); } });
  } finally {
    unmount();
  }
}

// ================================ CONTACT ================================
await run("contact", async ({ calls }) => {
  const labelled = ["contact-name", "contact-phone", "contact-email", "contact-subject", "contact-message"].every((id) => doc.querySelector(`label[for="${id}"]`) && doc.getElementById(id));
  check("C1", "every contact field has a real <label for>", labelled);
  check("C2", "required fields are announced as required", ["contact-name", "contact-subject", "contact-message"].every((id) => doc.getElementById(id).getAttribute("aria-required") === "true"));
  check("C3", "the form disables browser validation (custom messages) and has a name", doc.querySelector("form").noValidate && Boolean(doc.querySelector("form").getAttribute("aria-label")));
  check("C4", "the honeypot is hidden from assistive tech and the tab order", (() => { const h = doc.getElementById("inquiry-website"); return h.tabIndex === -1 && h.closest("[aria-hidden=true]") !== null; })());

  await submit();
  check("C5", "submitting an empty form calls nothing", calls.length === 0);
  const alerts = [...doc.querySelectorAll("form [role=alert]")].map((n) => n.textContent);
  check("C6", "errors appear for name, subject, message and the reply method", alerts.length >= 4, JSON.stringify(alerts));
  check("C7", "focus moves to the first invalid field", doc.activeElement?.id === "contact-name", doc.activeElement?.id);
  check("C8", "invalid fields are marked aria-invalid and described by their message", (() => { const n = doc.getElementById("contact-name"); return n.getAttribute("aria-invalid") === "true" && doc.getElementById(n.getAttribute("aria-describedby"))?.textContent.length > 0; })());

  await type("contact-name", "Hodan Ali");
  check("C9", "typing clears that field's error", !doc.getElementById("contact-name").hasAttribute("aria-invalid"));
  await type("contact-phone", "12345");
  await blur("contact-phone");
  check("C10", "a bad phone is explained on blur", /valid Somali phone number/.test(text("#contact-phone-error")), text("#contact-phone-error"));
  await type("contact-phone", "061 234 5678");
  await type("contact-subject", "  Prices  ");
  await type("contact-message", "  How much is a futsal ball?  ");
  await submit();
  check("C11", "a valid form is sent once with trimmed values", calls.length === 1 && calls[0].kind === "contact" && calls[0].name === "Hodan Ali" && calls[0].subject === "Prices" && calls[0].message === "How much is a futsal ball?" && calls[0].phone === "061 234 5678", JSON.stringify(calls));
  check("C12", "the honeypot value and a submission key are sent", calls[0].hp === "" && /^[0-9a-f-]{36}$/.test(calls[0].submissionKey ?? ""));
  check("C13", "success replaces the form and is announced", Boolean(doc.querySelector("[data-testid=inquiry-success][role=status]")) && !doc.querySelector("form"));
  check("C14", "keyboard focus lands on the success heading", doc.activeElement?.tagName === "H3");
  check("C15", "the success text makes no response-time promise", !/24|hour|within/i.test(text("[data-testid=inquiry-success]")), text("[data-testid=inquiry-success]"));
  check("C16", "the success panel offers WhatsApp", Boolean(doc.querySelector("[data-testid=inquiry-success] a[href^='https://wa.me/']")));
  await act(async () => { [...doc.querySelectorAll("button")].find((b) => /another/i.test(b.textContent)).click(); });
  check("C17", "'Send another message' returns an empty form", doc.getElementById("contact-name")?.value === "" && doc.getElementById("contact-message")?.value === "");
});

await run("contact", async ({ calls, setMode, finish }) => {
  setMode("pending");
  await type("contact-name", "A B");
  await type("contact-email", "a@b.co");
  await type("contact-subject", "S");
  await type("contact-message", "M");
  await submit();
  check("C18", "while sending, the button shows a busy state and is disabled", button().disabled && /sending/i.test(button().textContent) && button().getAttribute("aria-busy") === "true", button().textContent);
  await submit();
  await submit();
  check("C19", "double / triple submit while sending calls the server once", calls.length === 1, `${calls.length}`);
  await finish();
  check("C20", "after the server answers, success is shown", Boolean(doc.querySelector("[data-testid=inquiry-success]")));
});

await run("contact", async ({ calls, setMode }) => {
  setMode("fail", new Error("We already have your recent messages and will get back to you. Please contact us on WhatsApp if it is urgent."));
  await type("contact-name", "A B");
  await type("contact-email", "a@b.co");
  await type("contact-subject", "S");
  await type("contact-message", "M");
  await submit();
  check("C21", "a rejected submit shows the server's visitor-friendly sentence in an alert and keeps the form", /recent messages/.test(text("[data-testid=inquiry-error]")) && doc.getElementById("contact-message").value === "M");
  check("C22", "the button is usable again after a failure", !button().disabled && /send message/i.test(button().textContent));
  const firstKey = calls[0].submissionKey;
  await submit();
  check("C23", "a retry without edits reuses the submission key (double-submit safe)", calls.length === 2 && calls[1].submissionKey === firstKey);
  await type("contact-message", "M edited");
  await submit();
  check("C24", "editing after a failure makes a new submission key", calls.length === 3 && calls[2].submissionKey !== firstKey);
  setMode("fail", new TypeError("Failed to fetch"));
  await submit();
  check("C25", "a network failure is shown as a connection message, not a stack trace", /could not reach the server/i.test(text("[data-testid=inquiry-error]")), text("[data-testid=inquiry-error]"));
  setMode("fail", new Error("Could not find the function public.submit_public_inquiry in the schema cache"));
  await submit();
  check("C26", "a missing/forbidden backend is shown as 'temporarily unavailable' with a WhatsApp pointer", /temporarily unavailable/i.test(text("[data-testid=inquiry-error]")), text("[data-testid=inquiry-error]"));
});

await run("contact", async ({ calls }) => {
  await type("contact-name", "Bot");
  await type("contact-email", "bot@example.com");
  await type("contact-subject", "S");
  await type("contact-message", "M");
  await type("inquiry-website", "http://spam.example");
  await submit();
  check("C27", "a filled honeypot is passed to the server (which stores nothing)", calls.length === 1 && calls[0].hp === "http://spam.example");
});

// ================================ WHOLESALE ================================
await run("wholesale", async ({ calls }) => {
  const ids = ["wholesale-organization", "wholesale-name", "wholesale-phone", "wholesale-business-type", "wholesale-message"];
  check("W1", "every wholesale field has a real <label for>", ids.every((id) => doc.querySelector(`label[for="${id}"]`) && doc.getElementById(id)));
  check("W2", "business type starts unselected and lists all five types", (() => { const s = doc.getElementById("wholesale-business-type"); return s.value === "" && s.options.length === 6; })());
  check("W3", "phone is a tel input with a keypad hint", doc.getElementById("wholesale-phone").type === "tel" && doc.getElementById("wholesale-phone").getAttribute("inputmode") === "tel");
  await submit();
  check("W4", "submitting empty shows organization, name, phone and business type errors and sends nothing", calls.length === 0 && ["organization", "name", "phone", "business-type"].every((k) => text(`#wholesale-${k}-error`).length > 0));
  check("W5", "focus goes to the first invalid field (organization)", doc.activeElement?.id === "wholesale-organization");
  await type("wholesale-organization", "Mogadishu Arena");
  await type("wholesale-name", "Ali");
  await type("wholesale-phone", "0612345678");
  await type("wholesale-business-type", "Futsal Arena");
  await submit();
  check("W6", "products text is optional; a valid wholesale form is sent with kind 'wholesale'", calls.length === 1 && calls[0].kind === "wholesale" && calls[0].organization === "Mogadishu Arena" && calls[0].businessType === "Futsal Arena" && calls[0].message === "", JSON.stringify(calls));
  check("W7", "success is shown without a 24-hour promise", Boolean(doc.querySelector("[data-testid=inquiry-success]")) && !/24|hour/i.test(text("[data-testid=inquiry-success]")));
});

console.log(`\nDOM: ${pass} PASS, ${fail} FAIL`);
process.exit(fail ? 1 : 0);
