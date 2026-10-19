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
  lineBlock,
  overrideReasonMissing,
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

test("when the price could not be looked up the shown price is sent, exactly as before migration 28", () => {
  const l = line({ info: null, price: "20" });
  assert.deepEqual(toPayloadLine(l), { productId: "p1", quantity: 5, actualUnitPrice: 20 });
  assert.equal(lineBlock(l), null);
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
