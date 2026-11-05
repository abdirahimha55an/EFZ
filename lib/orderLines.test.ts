// The public order form's line rules (design selection per line). Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  designAvailable, designsOf, formProblem, formatCents, lineProblem, lineTotalCents, newLine, orderTotalCents, pairTaken, parseQuantity,
  productAvailable, toRequestLines, withProduct, type OrderLine,
} from "./orderLines.ts";
import type { Product, PublicDesign } from "./types/index.ts";

const prod = (id: string, name: string, price: number) => ({ id, name, price, sellingPrice: price } as unknown as Product);
const FIRE = prod("fire", "EFZ - Fire Ball", 12.5);
const NEXUS = prod("nexus", "EFZ - Nexus", 10);
const PHANTOM = prod("phantom", "Phantom Blue", 14);
const PRODUCTS = [FIRE, NEXUS, PHANTOM];
const D_RED: PublicDesign = { id: "d-red", productId: "fire", name: "Red", imageUrl: "" };
const D_BLUE: PublicDesign = { id: "d-blue", productId: "fire", name: "Blue", imageUrl: "" };
const D_GOLD: PublicDesign = { id: "d-gold", productId: "nexus", name: "Gold", imageUrl: "" };
const DESIGNS = [D_RED, D_BLUE, D_GOLD];
const line = (key: number, productId: string, designId: string, quantity: string): OrderLine => ({ key, productId, designId, quantity });

test("quantity: only whole numbers from 1 to 100000", () => {
  for (const ok of ["1", "7", " 12 ", "100000"]) assert.ok(parseQuantity(ok) !== null, ok);
  for (const bad of ["", "0", "-1", "2.5", "1e3", "12abc", "100001", "0007x", "٣"]) assert.equal(parseQuantity(bad), null, bad);
  assert.equal(parseQuantity("007"), 7);
});

test("a product with designs needs one chosen; a product without needs none", () => {
  assert.equal(lineProblem(line(1, "fire", "", "3"), PRODUCTS, DESIGNS), "Choose a design");
  assert.equal(lineProblem(line(1, "fire", "d-red", "3"), PRODUCTS, DESIGNS), null);
  assert.equal(lineProblem(line(1, "phantom", "", "3"), PRODUCTS, DESIGNS), null, "no designs -> no choice");
  assert.equal(lineProblem(line(1, "", "", "3"), PRODUCTS, DESIGNS), "Choose a product");
});

test("a design of another product, or a vanished design/product, is refused", () => {
  assert.equal(lineProblem(line(1, "fire", "d-gold", "1"), PRODUCTS, DESIGNS), "This design is no longer available");
  assert.equal(lineProblem(line(1, "fire", "d-red", "1"), PRODUCTS, []), "This design is no longer available", "design list emptied after a design was chosen");
  assert.equal(lineProblem(line(1, "gone", "", "1"), PRODUCTS, DESIGNS), "This product is no longer available");
});

test("without any designs (older database, fetch failed) the form behaves exactly like before", () => {
  assert.equal(lineProblem(line(1, "fire", "", "2"), PRODUCTS, []), null);
  assert.deepEqual(toRequestLines([line(1, "fire", "", "2")]), [{ productId: "fire", quantity: 2 }]);
  assert.equal(productAvailable([line(1, "fire", "", "1")], 2, "fire", []), false, "the same product cannot be chosen twice when it has no designs");
});

test("several designs of one product on several lines, each with its own quantity", () => {
  const lines = [line(1, "fire", "d-red", "3"), line(2, "fire", "d-blue", "7"), line(3, "nexus", "d-gold", "1")];
  assert.equal(formProblem(lines, PRODUCTS, DESIGNS), null);
  assert.deepEqual(toRequestLines(lines), [
    { productId: "fire", designId: "d-red", quantity: 3 },
    { productId: "fire", designId: "d-blue", quantity: 7 },
    { productId: "nexus", designId: "d-gold", quantity: 1 },
  ]);
});

test("the same product + design on two lines is refused, and its option is disabled on the second line", () => {
  const lines = [line(1, "fire", "d-red", "3"), line(2, "fire", "d-red", "1")];
  assert.match(formProblem(lines, PRODUCTS, DESIGNS) ?? "", /^Line 2: .*already on another line/);
  assert.equal(pairTaken(lines, 2, "fire", "d-red"), true);
  assert.equal(designAvailable([line(1, "fire", "d-red", "3"), line(2, "fire", "", "1")], 2, "fire", "d-red"), false);
  assert.equal(designAvailable([line(1, "fire", "d-red", "3"), line(2, "fire", "", "1")], 2, "fire", "d-blue"), true);
});

test("a product stays pickable while any of its designs is free, and is disabled when all are taken", () => {
  const one = [line(1, "fire", "d-red", "1"), line(2, "", "", "1")];
  assert.equal(productAvailable(one, 2, "fire", DESIGNS), true, "Blue is still free");
  const both = [line(1, "fire", "d-red", "1"), line(2, "fire", "d-blue", "1"), line(3, "", "", "1")];
  assert.equal(productAvailable(both, 3, "fire", DESIGNS), false, "Red and Blue both used");
  assert.equal(productAvailable(both, 1, "fire", DESIGNS), true, "line 1 may keep its own choice or switch");
  assert.equal(productAvailable([line(1, "nexus", "d-gold", "1"), line(2, "", "", "1")], 2, "nexus", DESIGNS), false, "its only design is used");
});

test("changing the product clears the design (a design belongs to one product)", () => {
  assert.deepEqual(withProduct(line(1, "fire", "d-red", "5"), "nexus"), { key: 1, productId: "nexus", designId: "", quantity: "5" });
});

test("pricing: each line = its product's price x its own quantity; designs carry no price of their own", () => {
  const a = line(1, "fire", "d-red", "3");   // 12.50 x 3 = 37.50
  const b = line(2, "fire", "d-blue", "7");  // 12.50 x 7 = 87.50
  const c = line(3, "phantom", "", "2");     // 14.00 x 2 = 28.00
  assert.equal(lineTotalCents(a, PRODUCTS), 3750);
  assert.equal(lineTotalCents(b, PRODUCTS), 8750);
  assert.equal(lineTotalCents(c, PRODUCTS), 2800);
  assert.equal(orderTotalCents([a, b, c], PRODUCTS), 15300);
  assert.equal(formatCents(15300), "$153.00");
  assert.equal(lineTotalCents(line(4, "fire", "d-red", "abc"), PRODUCTS), 0, "an invalid quantity contributes nothing");
  assert.equal(lineTotalCents(newLine(5), PRODUCTS), 0);
});

test("pricing is exact in cents (no floating-point drift)", () => {
  const p = prod("x", "X", 0.1);
  assert.equal(lineTotalCents(line(1, "x", "", "3"), [p]), 30);
  assert.equal(orderTotalCents([line(1, "x", "", "3"), line(2, "x", "", "4")], [p]), 70);
  const q = prod("y", "Y", 19.99);
  assert.equal(lineTotalCents(line(1, "y", "", "100000"), [q]), 199900000);
});

test("form problems are numbered only when there is more than one line", () => {
  assert.equal(formProblem([line(1, "fire", "", "1")], PRODUCTS, DESIGNS), "Choose a design");
  assert.equal(formProblem([line(1, "fire", "d-red", "1"), line(2, "nexus", "", "1")], PRODUCTS, DESIGNS), "Line 2: Choose a design");
});

test("form problems use the on-screen row numbers when blank rows were left out", () => {
  const chosen = [line(1, "fire", "d-red", "1"), line(3, "nexus", "", "1")];
  assert.equal(formProblem(chosen, PRODUCTS, DESIGNS, { numbers: [1, 3], numbered: true }), "Line 3: Choose a design");
  assert.equal(formProblem([line(2, "fire", "", "1")], PRODUCTS, DESIGNS, { numbers: [2], numbered: true }), "Line 2: Choose a design");
  assert.equal(formProblem([line(1, "fire", "", "1")], PRODUCTS, DESIGNS, { numbered: false }), "Choose a design");
});

test("designsOf returns only that product's designs", () => {
  assert.deepEqual(designsOf(DESIGNS, "fire").map((d) => d.id), ["d-red", "d-blue"]);
  assert.deepEqual(designsOf(DESIGNS, "phantom"), []);
});
