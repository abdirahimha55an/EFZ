// The public site must not link to pages that do not exist, or to "#". Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";

const FILES = ["components/Footer.tsx", "components/Navbar.tsx", "components/FloatingWhatsApp.tsx", "app/page.tsx", "app/products/page.tsx", "app/order/page.tsx", "app/contact/page.tsx", "app/wholesale/page.tsx"];

const routeExists = (path: string) => (path === "/" ? existsSync("app/page.tsx") : existsSync(`app${path}/page.tsx`));

test("no public link points at '#'", () => {
  for (const f of FILES.filter(existsSync)) {
    assert.ok(!/href=["']#["']/.test(readFileSync(f, "utf8")), `${f} has a link to "#"`);
  }
});

test("every internal link on the public site resolves to a page", () => {
  for (const f of FILES.filter(existsSync)) {
    const hrefs = [...readFileSync(f, "utf8").matchAll(/href=["'](\/[^"'?#]*)[^"']*["']/g)].map((m) => m[1].replace(/\/$/, "") || "/");
    for (const h of hrefs) assert.ok(routeExists(h), `${f} links to ${h}, which has no page`);
  }
});
