// 28: the Convert-to-Order rules (price left to the database unless deliberately changed, documented overrides, designs kept). Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  type ConversionLine,
  type PriceInfo,
  hasDuplicateLines,
  isAgreedPrice,
  isAgreementOverride,
  isPriceChanged,
  linePrice,
  PRICE_LOOKUP_FAILED,
  lineBlock,
  overrideReasonMissing,
  overrideSummary,
  parsePriceInfo,
  toPayloadLine,
} from "./requestConversion.ts";

const agreement = (price: number, list = 20): PriceInfo => ({ source: "agreement", price, listPrice: list, reason: null });
const list = (price = 20): PriceInfo => ({ source: "list", price, listPrice: price, reason: null });
const line = (over: Partial<ConversionLine> = {}): ConversionLine => ({ productId: "p1", quantity: "5", price: "15", priceEdited: false, info: agreement(15), ...over });

test("an untouched line is sent without a price: the database applies the agreed (else list) price", () => {
  assert.deepEqual(toPayloadLine(line()), { productId: "p1", quantity: 5 });
  assert.deepEqual(toPayloadLine(line({ info: list(), price: "20" })), { productId: "p1", quantity: 5 });
});

test("typing the very same price is not an override and is not sent", () => {
  const l = line({ priceEdited: true, price: "15.00" });
  assert.equal(isPriceChanged(l), false);
  assert.equal(isAgreementOverride(l), false);
  assert.deepEqual(toPayloadLine(l), { productId: "p1", quantity: 5 });
});

test("a different price for a customer with an agreement is an override and needs a reason of at least 10 characters", () => {
  const l = line({ priceEdited: true, price: "18" });
  assert.equal(isPriceChanged(l), true);
  assert.equal(isAgreementOverride(l), true);
  assert.deepEqual(toPayloadLine(l), { productId: "p1", quantity: 5, actualUnitPrice: 18 });
  assert.equal(overrideReasonMissing([l], ""), true);
  assert.equal(overrideReasonMissing([l], "too short"), true);
  assert.equal(overrideReasonMissing([l], "  9 chars!  "), true);
  assert.equal(overrideReasonMissing([l], "Owner approved a one-off price"), false);
  assert.equal(overrideReasonMissing([line()], ""), false);
});

test("a changed price where only the list price applies is sent but needs no override reason (as before)", () => {
  const l = line({ info: list(), price: "17", priceEdited: true });
  assert.equal(isPriceChanged(l), true);
  assert.equal(isAgreementOverride(l), false);
  assert.deepEqual(toPayloadLine(l), { productId: "p1", quantity: 5, actualUnitPrice: 17 });
  assert.equal(overrideReasonMissing([l], ""), false);
});

test("a price waiting to be confirmed blocks the line and cannot be typed over", () => {
  const l = line({ info: { source: "review", price: null, listPrice: 20, reason: "an agreement is waiting to be verified" }, price: "" });
  assert.match(lineBlock(l) ?? "", /needs to be confirmed first/);
  assert.equal(lineBlock(line()), null);
});

test("a failed price lookup BLOCKS the line; the displayed price is never sent as a fallback", () => {
  const failed = line({ info: null, price: "" });
  assert.equal(lineBlock(failed), PRICE_LOOKUP_FAILED);
  // even if a price were somehow on screen (or typed), a line without a usable lookup is not an override and sends no price
  const typed = line({ info: null, price: "20", priceEdited: true });
  assert.equal(lineBlock(typed), PRICE_LOOKUP_FAILED);
  assert.equal(isPriceChanged(typed), false);
  assert.equal(isAgreementOverride(typed), false);
  assert.deepEqual(toPayloadLine(typed), { productId: "p1", quantity: 5 });
  // not asked yet is not a block (the dialog keeps Create disabled until the answer arrives), and never sends a price either
  assert.equal(lineBlock(line({ info: undefined, price: "" })), null);
  assert.deepEqual(toPayloadLine(line({ info: undefined, price: "20", priceEdited: true })), { productId: "p1", quantity: 5 });
});

test("an invalid lookup answer is treated as no answer (null), never guessed", () => {
  assert.deepEqual(parsePriceInfo({ source: "agreement", price: 15, listPrice: 20, reason: null }), { source: "agreement", price: 15, listPrice: 20, reason: null });
  assert.deepEqual(parsePriceInfo({ source: "list", price: 20, listPrice: 20 }), { source: "list", price: 20, listPrice: 20, reason: null });
  assert.deepEqual(parsePriceInfo({ source: "review", price: null, listPrice: 20, reason: "pending" }), { source: "review", price: null, listPrice: 20, reason: "pending" });
  assert.deepEqual(parsePriceInfo({ source: "review", price: 5, listPrice: 20, reason: "pending" }), { source: "review", price: null, listPrice: 20, reason: "pending" }, "a review answer never carries a price");
  for (const bad of [null, undefined, "x", 3, [], {}, { source: "none", price: null }, { source: "agreement", price: null, listPrice: 20 }, { source: "list", price: "20", listPrice: 20 }, { source: "list", price: -1, listPrice: 20 }, { source: "list", price: Number.NaN, listPrice: 20 }, { source: "agreement", price: 15, listPrice: "20" }]) {
    assert.equal(parsePriceInfo(bad), null, JSON.stringify(bad));
  }
});

test("the override summary shows the agreed price, the proposed price and what the difference comes to, per line and per unit", () => {
  const over = line({ productId: "p1", designName: "Blue", quantity: "4", priceEdited: true, price: "18.50", info: agreement(15) });
  const same = line({ productId: "p2", info: agreement(10), price: "10" });
  const lower = line({ productId: "p3", quantity: "10", priceEdited: true, price: "9", info: agreement(10) });
  const rows = overrideSummary([over, same, lower]);
  assert.deepEqual(rows, [
    { productId: "p1", designName: "Blue", quantity: 4, agreed: 15, proposed: 18.5, perUnit: 3.5, total: 14 },
    { productId: "p3", designName: "", quantity: 10, agreed: 10, proposed: 9, perUnit: -1, total: -10 },
  ]);
  assert.deepEqual(overrideSummary([same]), []);
});

test("the design travels with the line: by id when known, by recorded name when the design was removed", () => {
  assert.deepEqual(toPayloadLine(line({ designId: "11111111-1111-1111-1111-111111111111", designName: "Blue" })), { productId: "p1", quantity: 5, designId: "11111111-1111-1111-1111-111111111111" });
  assert.deepEqual(toPayloadLine(line({ designName: "  Red  " })), { productId: "p1", quantity: 5, designName: "Red" });
  assert.deepEqual(toPayloadLine(line({ designName: "" })), { productId: "p1", quantity: 5 });
});

test("one product may repeat only with different designs; the same product and design twice is refused", () => {
  const blue = line({ designId: "d-blue", designName: "Blue" });
  const red = line({ designId: "d-red", designName: "Red", quantity: "2" });
  assert.equal(hasDuplicateLines([blue, red]), false);
  assert.equal(hasDuplicateLines([blue, { ...blue }]), true);
  assert.equal(hasDuplicateLines([line(), line()]), true);
  assert.equal(hasDuplicateLines([line(), line({ productId: "p2" })]), false);
  assert.equal(hasDuplicateLines([line({ designName: "Blue" }), line({ designName: "blue " })]), true);
});

test("a line charged exactly its agreed price is not a below-cost approval case", () => {
  assert.equal(isAgreedPrice(line()), true);
  assert.equal(isAgreedPrice(line({ priceEdited: true, price: "14" })), false);
  assert.equal(isAgreedPrice(line({ info: list(), price: "20" })), false);
});

test("an emptied or non-numeric price box is not a change; the line then has no price and cannot be submitted", () => {
  for (const price of ["", "  ", "abc"]) {
    const l = line({ priceEdited: true, price });
    assert.equal(isPriceChanged(l), false);
    assert.equal(isAgreementOverride(l), false);
    assert.deepEqual(toPayloadLine(l), { productId: "p1", quantity: 5 });
  }
  // the dialog's own validity rule is linePrice() !== null; an emptied box fails it
  assert.equal(linePrice(line({ priceEdited: true, price: "" })), null);
  assert.equal(linePrice(line({ priceEdited: true, price: "abc" })), null);
});
