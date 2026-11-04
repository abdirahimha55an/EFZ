// The footer shows a social icon only for a verified https URL. Run: npm run test:hub
import { test } from "node:test";
import assert from "node:assert/strict";
import { SOCIAL_LINKS, visibleSocialLinks } from "./socialLinks.ts";

test("shipped config: only the owner-supplied Facebook and TikTok accounts, exact URLs", () => {
  assert.deepEqual(visibleSocialLinks(SOCIAL_LINKS), [
    { network: "facebook", url: "https://www.facebook.com/profile.php?id=61596258383654" },
    { network: "tiktok", url: "https://www.tiktok.com/@elite.football.zone?is_from_webapp=1&sender_device=pc" },
  ]);
});

test("empty config shows nothing", () => {
  assert.deepEqual(visibleSocialLinks({ facebook: "", instagram: "", x: "", tiktok: "" }), []);
});

test("only https URLs are shown, in a fixed order", () => {
  const shown = visibleSocialLinks({ facebook: " https://www.facebook.com/example ", instagram: "", x: "https://x.com/example", tiktok: "" });
  assert.deepEqual(shown.map((s) => s.network), ["facebook", "x"]);
  assert.equal(shown[0].url, "https://www.facebook.com/example");
});

test("unsafe or malformed values are ignored", () => {
  for (const bad of ["http://facebook.com/x", "javascript:alert(1)", "facebook.com/x", "@efz", "https://localhost/x", "data:text/html,hi"]) {
    assert.deepEqual(visibleSocialLinks({ facebook: bad, instagram: "", x: "", tiktok: "" }), [], bad);
  }
});
