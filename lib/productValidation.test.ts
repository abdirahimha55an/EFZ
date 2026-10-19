// Product edit: the image URL is OPTIONAL. Editing a price must not need one, must never clear a stored one, and a URL that IS given must be http(s). Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveImageUrlForSave, validateProduct } from "./validators/index.ts";
import { fromProduct } from "./supabase/mappers.ts";

// what the product form hands to validateProduct (numbers already parsed), for a product that has NO image, after changing only the selling price
const editedPriceOnly = (over: Record<string, unknown> = {}) => ({
  id: "prod-stg-nexus", name: "EFZ - Nexus", imageUrl: "", stock: 62, costPrice: 6.7, sellingPrice: 14, lowStockThreshold: 50, ...over,
});

test("REGRESSION: changing only the selling price of a product with an empty image URL validates", () => {
  const v = validateProduct(editedPriceOnly());
  assert.equal(v.ok, true);
  assert.equal(v.error, undefined);
});

test("a missing, empty or blank image URL is accepted (the image is optional)", () => {
  for (const imageUrl of [undefined, null, "", "   ", "\t"]) {
    assert.equal(validateProduct(editedPriceOnly({ imageUrl })).ok, true, JSON.stringify(imageUrl));
  }
});

test("an image URL that IS given must be http or https", () => {
  for (const imageUrl of ["https://images.unsplash.com/photo-1543152507", "http://example.com/ball.png", "  https://cdn.example.com/a.jpg  "]) {
    assert.equal(validateProduct(editedPriceOnly({ imageUrl })).ok, true, imageUrl);
  }
  for (const imageUrl of ["ftp://example.com/a.png", "javascript:alert(1)", "data:image/png;base64,AAAA", "example.com/a.png", "not a url", "https://", "//cdn.example.com/a.png"]) {
    const v = validateProduct(editedPriceOnly({ imageUrl }));
    assert.equal(v.ok, false, imageUrl);
    assert.match(v.error ?? "", /HTTP or HTTPS/);
  }
});

test("the other product rules still apply when the image is empty", () => {
  assert.equal(validateProduct(editedPriceOnly({ name: "" })).ok, false);
  assert.equal(validateProduct(editedPriceOnly({ id: "" })).ok, false);
  assert.match(validateProduct(editedPriceOnly({ sellingPrice: -1 })).error ?? "", /Selling price cannot be negative/);
  assert.match(validateProduct(editedPriceOnly({ sellingPrice: Number.NaN })).error ?? "", /Selling price must be a valid number/);
  assert.match(validateProduct(editedPriceOnly({ stock: -3 })).error ?? "", /Stock cannot be negative/);
  assert.match(validateProduct(editedPriceOnly({ costPrice: -1 })).error ?? "", /Cost price cannot be negative/);
  assert.equal(validateProduct(editedPriceOnly({ costPrice: null })).ok, true, "cost withheld from this user is fine");
  assert.equal(validateProduct(editedPriceOnly({ sellingPrice: 5 })).warning, "Selling price is lower than cost price.");
});

test("a typed URL is saved trimmed", () => {
  assert.deepEqual(resolveImageUrlForSave("  https://cdn.example.com/a.jpg \n", "https://old.example.com/o.jpg", "update"), { imageUrl: "https://cdn.example.com/a.jpg", keptExisting: false });
  assert.deepEqual(resolveImageUrlForSave("https://cdn.example.com/a.jpg", undefined, "create"), { imageUrl: "https://cdn.example.com/a.jpg", keptExisting: false });
});

test("a blank box on an EDIT sends no image at all, and says when an existing image is kept", () => {
  assert.deepEqual(resolveImageUrlForSave("", "https://old.example.com/o.jpg", "update"), { imageUrl: undefined, keptExisting: true });
  assert.deepEqual(resolveImageUrlForSave("   ", "https://old.example.com/o.jpg", "update"), { imageUrl: undefined, keptExisting: true });
  assert.deepEqual(resolveImageUrlForSave("", "", "update"), { imageUrl: undefined, keptExisting: false });
  assert.deepEqual(resolveImageUrlForSave(undefined, undefined, "update"), { imageUrl: undefined, keptExisting: false });
});

test("a blank box on a NEW product sends no image (the database default applies) and keeps nothing", () => {
  assert.deepEqual(resolveImageUrlForSave("", undefined, "create"), { imageUrl: undefined, keptExisting: false });
});

test("NEVER CLEARS: the database patch built for a blank-image edit has no image_url key; a typed URL has", () => {
  const blank = resolveImageUrlForSave("", "https://old.example.com/o.jpg", "update");
  // exactly how the product page builds the update patch
  const patch = { name: "EFZ - Nexus", sellingPrice: 14, ...(blank.imageUrl !== undefined ? { imageUrl: blank.imageUrl } : {}) };
  const row = fromProduct(patch);
  assert.equal("image_url" in row, false, "a save with a blank image box must not touch image_url");
  assert.equal(row.selling_price, 14);

  const typed = resolveImageUrlForSave("https://new.example.com/n.jpg", "https://old.example.com/o.jpg", "update");
  assert.equal(fromProduct({ sellingPrice: 14, ...(typed.imageUrl !== undefined ? { imageUrl: typed.imageUrl } : {}) }).image_url, "https://new.example.com/n.jpg");

  // creating without an image writes the empty default explicitly, which the not-null column accepts
  assert.equal(fromProduct({ name: "X", imageUrl: "" }).image_url, "");
});
