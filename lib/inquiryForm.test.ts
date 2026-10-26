// Public Contact and Wholesale forms: the browser-side checks that mirror submit_public_inquiry(). Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  BUSINESS_TYPES,
  INQUIRY_LIMITS,
  firstInvalid,
  isPlausibleEmail,
  validateContact,
  validateWholesale,
  visitorFriendlyError,
} from "./inquiryForm.ts";

const contact = { name: "Hodan", phone: "061 234 5678", email: "", subject: "Prices", message: "How much is a futsal ball?" };
const wholesale = { organization: "Mogadishu Arena", name: "Ali", phone: "0612345678", businessType: "Futsal Arena", message: "" };

test("a complete contact message passes, with a phone or an email alone", () => {
  assert.deepEqual(validateContact(contact), {});
  assert.deepEqual(validateContact({ ...contact, phone: "", email: "hodan@example.com" }), {});
});

test("contact needs a way to reply, a subject and a message", () => {
  const none = validateContact({ ...contact, phone: "", email: "" });
  assert.ok(none.phone && none.email, "both contact fields explain the rule");
  assert.ok(validateContact({ ...contact, subject: "  " }).subject);
  assert.ok(validateContact({ ...contact, message: "" }).message);
  assert.ok(validateContact({ ...contact, name: " " }).name);
});

test("contact: a given phone must be a Somali number, a given email must look like one", () => {
  assert.ok(validateContact({ ...contact, phone: "12345" }).phone);
  assert.ok(validateContact({ ...contact, phone: "", email: "not-an-email" }).email);
  assert.equal(validateContact({ ...contact, phone: "+252612345678" }).phone, undefined);
});

test("contact: limits match the database", () => {
  assert.ok(validateContact({ ...contact, name: "x".repeat(INQUIRY_LIMITS.name + 1) }).name);
  assert.ok(validateContact({ ...contact, subject: "x".repeat(INQUIRY_LIMITS.subject + 1) }).subject);
  assert.ok(validateContact({ ...contact, message: "x".repeat(INQUIRY_LIMITS.message + 1) }).message);
  assert.deepEqual(validateContact({ ...contact, message: "x".repeat(INQUIRY_LIMITS.message) }), {});
});

test("a complete wholesale inquiry passes; the products text is optional", () => {
  assert.deepEqual(validateWholesale(wholesale), {});
  assert.deepEqual(validateWholesale({ ...wholesale, message: "50 balls a month" }), {});
});

test("wholesale needs organization, contact person, a Somali phone and a listed business type", () => {
  assert.ok(validateWholesale({ ...wholesale, organization: "" }).organization);
  assert.ok(validateWholesale({ ...wholesale, name: " " }).name);
  assert.ok(validateWholesale({ ...wholesale, phone: "" }).phone);
  assert.ok(validateWholesale({ ...wholesale, phone: "999" }).phone);
  assert.ok(validateWholesale({ ...wholesale, businessType: "" }).businessType);
  assert.ok(validateWholesale({ ...wholesale, businessType: "Hacker" }).businessType);
  for (const t of BUSINESS_TYPES) assert.equal(validateWholesale({ ...wholesale, businessType: t }).businessType, undefined);
});

test("firstInvalid follows the order the form shows", () => {
  const errors = validateWholesale({ organization: "", name: "", phone: "", businessType: "", message: "" });
  assert.equal(firstInvalid(errors, ["organization", "name", "phone", "businessType", "message"] as const), "organization");
  assert.equal(firstInvalid(errors, ["phone", "organization"] as const), "phone");
  assert.equal(firstInvalid({}, ["organization"] as const), null);
});

test("email check agrees with the database pattern", () => {
  assert.equal(isPlausibleEmail("a@b.co"), true);
  assert.equal(isPlausibleEmail(" a@b.co "), true);
  for (const bad of ["a@b", "a b@c.de", "@b.co", "a@.co", "plain"]) assert.equal(isPlausibleEmail(bad), false, bad);
});

test("visitor-facing errors: database sentences pass through, technical ones are replaced", () => {
  const limit = "We already have your recent messages and will get back to you. Please contact us on WhatsApp if it is urgent.";
  assert.equal(visitorFriendlyError(limit), limit);
  assert.equal(visitorFriendlyError("Please enter a valid Somali phone number, e.g. 061 234 5678"), "Please enter a valid Somali phone number, e.g. 061 234 5678");
  assert.match(visitorFriendlyError("TypeError: Failed to fetch"), /could not reach the server/);
  assert.match(visitorFriendlyError("Permission denied: your account is not allowed to do that."), /temporarily unavailable/);
  assert.match(visitorFriendlyError("Could not find the function public.submit_public_inquiry in the schema cache"), /temporarily unavailable/);
  assert.match(visitorFriendlyError(""), /Something went wrong/);
});
