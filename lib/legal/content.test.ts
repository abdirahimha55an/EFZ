import test from "node:test";
import assert from "node:assert/strict";
import { LEGAL, legalStatus, openPlaceholders } from "./content.ts";

test("the shipped content still has open placeholders, so Production hides the pages", () => {
  assert.ok(openPlaceholders().length > 0);
  assert.equal(legalStatus(LEGAL, undefined), "hidden");
  assert.equal(legalStatus(LEGAL, "false"), "hidden");
});

test("preview flag shows a draft only while placeholders remain", () => {
  assert.equal(legalStatus(LEGAL, "true"), "draft");
});

test("a complete set is published whatever the preview flag", () => {
  const done = Object.fromEntries(Object.keys(LEGAL).map((k) => [k, "filled"]));
  assert.equal(openPlaceholders(done).length, 0);
  assert.equal(legalStatus(done, undefined), "published");
  assert.equal(legalStatus(done, "true"), "published");
});

test("a single leftover placeholder blocks publication", () => {
  const almost = { ...Object.fromEntries(Object.keys(LEGAL).map((k) => [k, "filled"])), governingLaw: "[[REQUIRED: x]]" };
  assert.deepEqual(openPlaceholders(almost), ["governingLaw"]);
  assert.equal(legalStatus(almost, undefined), "hidden");
});
