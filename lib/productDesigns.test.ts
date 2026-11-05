// Product Designs screen rules (admin). Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import { EMPTY_DRAFT, activeCount, filterDesigns, groupByProduct, imageProblem, nameTaken, validateDraft, type DesignDraft } from "./productDesigns.ts";
import type { ProductDesign } from "./types/index.ts";

const d = (id: string, productId: string, name: string, sortOrder = 0, isActive = true): ProductDesign =>
  ({ id, productId, name, imageUrl: "", sortOrder, isActive, createdAt: "2026-11-05T00:00:00Z", updatedAt: "2026-11-05T00:00:00Z" });
const DESIGNS = [d("1", "fire", "Red", 2), d("2", "fire", "Blue", 1), d("3", "nexus", "Gold", 0, false), d("4", "fire", "Hidden", 3, false)];
const draft = (over: Partial<DesignDraft>): DesignDraft => ({ ...EMPTY_DRAFT, productId: "fire", name: "Green", ...over });

test("a complete draft is valid and the values are trimmed and numeric", () => {
  const r = validateDraft(draft({ name: "  Green  ", imageUrl: " https://example.com/g.png ", sortOrder: " 4 " }), DESIGNS);
  assert.deepEqual(r, { ok: true, value: { productId: "fire", name: "Green", imageUrl: "https://example.com/g.png", sortOrder: 4 } });
});

test("product and name are required; a blank order means 0", () => {
  const r = validateDraft({ ...EMPTY_DRAFT }, DESIGNS);
  assert.ok(!r.ok && r.errors.productId && r.errors.name);
  const ok = validateDraft(draft({ sortOrder: "" }), DESIGNS);
  assert.ok(ok.ok && ok.value.sortOrder === 0);
});

test("name length: 120 is the limit", () => {
  assert.ok(validateDraft(draft({ name: "x".repeat(120) }), DESIGNS).ok);
  const r = validateDraft(draft({ name: "x".repeat(121) }), DESIGNS);
  assert.ok(!r.ok && /too long/.test(r.errors.name ?? ""));
});

test("duplicate names on one product are refused whatever the case or spaces; on another product they are fine", () => {
  assert.ok(nameTaken(DESIGNS, "fire", "  red "));
  assert.ok(!nameTaken(DESIGNS, "nexus", "red"));
  const r = validateDraft(draft({ name: "BLUE" }), DESIGNS);
  assert.ok(!r.ok && /already has a design/.test(r.errors.name ?? ""));
  assert.ok(validateDraft(draft({ productId: "nexus", name: "Blue" }), DESIGNS).ok);
});

test("editing a design may keep its own name", () => {
  assert.ok(validateDraft(draft({ name: "Red" }), DESIGNS, { editingId: "1" }).ok);
  assert.ok(!validateDraft(draft({ name: "Red" }), DESIGNS, { editingId: "2" }).ok, "design 2 may not take design 1's name");
});

test("image link: empty or https only, no spaces, at most 500 characters", () => {
  for (const ok of ["", "   ", "https://example.com/a.png", "https://cdn.example.com/x/y.jpg?w=200"]) assert.equal(imageProblem(ok), null, ok);
  for (const bad of ["http://example.com/a.png", "javascript:alert(1)", "ftp://x/y", "https://a b.png", "//example.com/a.png", "example.com/a.png", "data:image/png;base64,AAAA"]) {
    assert.ok(imageProblem(bad), bad);
  }
  assert.equal(imageProblem("https://e.com/" + "a".repeat(486)), null, "exactly 500");
  assert.ok(imageProblem("https://e.com/" + "a".repeat(487)), "501 refused");
});

test("display order: a whole number from 0 to 100000", () => {
  for (const ok of ["0", "7", "100000"]) assert.ok(validateDraft(draft({ sortOrder: ok }), DESIGNS).ok, ok);
  for (const bad of ["-1", "2.5", "100001", "abc", "1e3"]) {
    const r = validateDraft(draft({ sortOrder: bad }), DESIGNS);
    assert.ok(!r.ok && r.errors.sortOrder, bad);
  }
});

test("filters: by product, status and name", () => {
  assert.deepEqual(filterDesigns(DESIGNS, { productId: "fire", status: "all", search: "" }).map((x) => x.id), ["1", "2", "4"]);
  assert.deepEqual(filterDesigns(DESIGNS, { productId: "", status: "inactive", search: "" }).map((x) => x.id), ["3", "4"]);
  assert.deepEqual(filterDesigns(DESIGNS, { productId: "", status: "active", search: "BL" }).map((x) => x.id), ["2"]);
});

test("grouping: by product name, designs in display order", () => {
  const g = groupByProduct(DESIGNS, [{ id: "fire", name: "EFZ - Fire Ball" }, { id: "nexus", name: "EFZ - Nexus" }]);
  assert.deepEqual(g.map((x) => x.productName), ["EFZ - Fire Ball", "EFZ - Nexus"]);
  assert.deepEqual(g[0].designs.map((x) => x.name), ["Blue", "Red", "Hidden"]);
  assert.equal(groupByProduct(DESIGNS, [])[0].productName, "fire", "an unknown product falls back to its id");
});

test("active count is what the order form will show", () => {
  assert.equal(activeCount(DESIGNS, "fire"), 2);
  assert.equal(activeCount(DESIGNS, "nexus"), 0);
});
