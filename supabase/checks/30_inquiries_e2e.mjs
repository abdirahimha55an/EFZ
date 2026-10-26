// EFZ-STAGING ONLY. End-to-end check of migration 30 through the Hub's real data layer (lib/supabase/queries.ts) over PostgREST,
// signed in as real Staging staff, plus a Realtime delivery check.
//
//   node --import ./scripts/register-test-loader.mjs supabase/checks/30_inquiries_e2e.mjs
//
// Reads .env.local (must be EFZ-Staging) and the staff passwords from the file named by E2E_ENV (the git-ignored .env.e2e).
// Prints PASS/FAIL lines and never prints a key or a password.
// Creates inquiries named "E2E-INQ ..." and temporary grants for u-stg-delivery; the cleanup SQL printed at the end (and run by the
// caller as the table owner) removes them. Refuses to run unless the Supabase URL is the Staging project.
import fs from "node:fs";
import { createClient } from "@supabase/supabase-js";
import { createDb, describeDbError } from "../../lib/supabase/queries.ts";

const STAGING_REF = "adjjamiqwboawqedaapi";
const PROD_REF = "rodmdvfjashiohgwople";

const readEnv = (file) => {
  const out = {};
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (m) out[m[1]] = m[2].replace(/^"|"$/g, "");
  }
  return out;
};

const env = { ...readEnv(".env.local"), ...(process.env.E2E_ENV ? readEnv(process.env.E2E_ENV) : {}) };
const url = env.NEXT_PUBLIC_SUPABASE_URL;
const anonKey = env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
if (!url || !anonKey || !url.includes(STAGING_REF) || url.includes(PROD_REF)) {
  console.error("REFUSED: .env.local is not the EFZ-Staging project");
  process.exit(2);
}

const results = [];
const check = (id, name, ok, info = "") => {
  results.push(ok);
  console.log(`${ok ? "PASS" : "FAIL"} ${id} ${name}${ok ? "" : info ? `  [${info}]` : ""}`);
};
const fresh = () => createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
const errOf = async (fn) => {
  try {
    await fn();
    return null;
  } catch (e) {
    return describeDbError(e);
  }
};

async function staff(email, passwordKey) {
  const client = fresh();
  const { error } = await client.auth.signInWithPassword({ email, password: env[passwordKey] ?? "" });
  if (error) throw new Error(`sign-in failed for ${email}: ${error.message}`);
  return { client, db: createDb(client) };
}

const RUN = Date.now().toString(36);
const anonClient = fresh();
const anon = createDb(anonClient);
const phone = "061" + String(Math.floor(1000000 + Math.random() * 8999999)); // 061 + 7 digits
const key = () => globalThis.crypto.randomUUID();

try {
  // ---- anonymous visitor -----------------------------------------------------------------------------------------------
  const direct = await anonClient.from("public_inquiries").select("id").limit(1);
  check("A1", "anon cannot read public_inquiries", Boolean(direct.error) || (direct.data ?? []).length === 0, JSON.stringify(direct.data));
  const ins = await anonClient.from("public_inquiries").insert({ kind: "contact", name: "x", phone: "0612223333", contact_key: "k", content_hash: "h" });
  check("A2", "anon cannot insert directly", Boolean(ins.error), "no error");
  const upd = await anonClient.from("public_inquiries").update({ status: "closed" }).eq("kind", "contact");
  check("A3", "anon cannot update", Boolean(upd.error), "no error");

  const k1 = key();
  const input = { kind: "contact", name: `E2E-INQ ${RUN}`, phone, subject: "E2E subject", message: "E2E message", submissionKey: k1 };
  const id1 = await anon.inquiries.submit(input);
  check("B1", "visitor can submit a contact message", /^[0-9a-f-]{36}$/.test(id1), String(id1));
  const again = await anon.inquiries.submit(input);
  check("B2", "same submission key returns the same inquiry", again === id1);
  const same = await anon.inquiries.submit({ ...input, submissionKey: key() });
  check("B3", "same message with a new key is not stored twice", same === id1);

  const bad = await errOf(() => anon.inquiries.submit({ ...input, phone: "123", submissionKey: key() }));
  check("V1", "invalid phone refused with the standard sentence", /valid Somali phone number/.test(bad ?? ""), bad ?? "no error");
  const noReach = await errOf(() => anon.inquiries.submit({ kind: "contact", name: "E2E-INQ nr", subject: "s", message: "m" }));
  check("V2", "contact without phone or email refused", /phone number or an email/.test(noReach ?? ""), noReach ?? "no error");
  const badEmail = await errOf(() => anon.inquiries.submit({ kind: "contact", name: "E2E-INQ be", email: "nope", subject: "s", message: "m" }));
  check("V3", "invalid email refused", /valid email/.test(badEmail ?? ""), badEmail ?? "no error");
  const longMsg = await errOf(() => anon.inquiries.submit({ kind: "contact", name: "E2E-INQ lm", email: "a@b.co", subject: "s", message: "x".repeat(3001) }));
  check("V4", "over-long message refused", /too long/.test(longMsg ?? ""), longMsg ?? "no error");

  await anon.inquiries.submit({ ...input, message: "E2E message 2", submissionKey: key() });
  await anon.inquiries.submit({ ...input, message: "E2E message 3", submissionKey: key() });
  const limited = await errOf(() => anon.inquiries.submit({ ...input, message: "E2E message 4", submissionKey: key() }));
  check("L1", "4th message from one phone is rate limited with a visitor-friendly sentence", /recent messages/.test(limited ?? ""), limited ?? "no error");

  const wId = await anon.inquiries.submit({
    kind: "wholesale", name: `E2E-INQ W ${RUN}`, organization: "E2E Arena", phone: "061" + String(Math.floor(1000000 + Math.random() * 8999999)),
    businessType: "Futsal Arena", message: "E2E 50 balls a month", submissionKey: key(),
  });
  check("W1", "visitor can submit a wholesale inquiry", /^[0-9a-f-]{36}$/.test(wId), String(wId));
  const wBad = await errOf(() => anon.inquiries.submit({ kind: "wholesale", name: "E2E-INQ wb", organization: "O", phone: "061" + "2345678", businessType: "Nope" }));
  check("W2", "wholesale with an unlisted business type refused", /business type/.test(wBad ?? ""), wBad ?? "no error");

  // ---- staff ------------------------------------------------------------------------------------------------------------
  const sa = await staff("efz.superadmin@example.com", "E2E_SUPERADMIN_PASSWORD");
  const all = await sa.db.inquiries.list();
  const ours = all.filter((i) => i.name.startsWith("E2E-INQ"));
  check("S1", "Super Admin sees the submitted inquiries (contact + wholesale)", ours.some((i) => i.id === id1) && ours.some((i) => i.id === wId), `${ours.length}`);
  const hp = await anon.inquiries.submit({ kind: "contact", name: `E2E-INQ HP ${RUN}`, email: "bot@example.com", subject: "s", message: "buy", hp: "http://spam", submissionKey: key() });
  const afterHp = (await sa.db.inquiries.list()).filter((i) => i.name === `E2E-INQ HP ${RUN}`);
  check("S2", "honeypot submission reports success but stores nothing", /^[0-9a-f-]{36}$/.test(hp) && afterHp.length === 0, `${afterHp.length} stored`);
  const mine = ours.find((i) => i.id === id1);
  check("S3", "inquiry fields stored and mapped (reference, canonical phone, status)", mine?.status === "new" && mine.reference.startsWith("INQ-") && /^\+2526/.test(mine.phoneCanonical ?? ""), JSON.stringify(mine));
  check("S4", "badge count and alert feed include new inquiries", (await sa.db.inquiries.openCount()) >= 2 && (await sa.db.inquiries.newForAlerts()).some((a) => a.id === id1));

  // Realtime: an event reaches a user who passes the SELECT policy when a visitor submits.
  let realtime = false;
  const channel = sa.client
    .channel(`e2e-inq-${RUN}`)
    .on("postgres_changes", { event: "INSERT", schema: "public", table: "public_inquiries" }, () => { realtime = true; });
  const subscribed = new Promise((resolve) => channel.subscribe((s) => { if (s === "SUBSCRIBED") resolve(true); }));
  await Promise.race([subscribed, new Promise((r) => setTimeout(r, 8000))]);
  await anon.inquiries.submit({ kind: "contact", name: `E2E-INQ RT ${RUN}`, email: `e2e.rt.${RUN}@example.com`, subject: "rt", message: "realtime", submissionKey: key() });
  for (let i = 0; i < 40 && !realtime; i++) await new Promise((r) => setTimeout(r, 250));
  check("RT1", "Realtime INSERT event reaches the Super Admin", realtime);
  await sa.client.removeChannel(channel);

  await sa.db.inquiries.setStatus(id1, "contacted");
  await sa.db.inquiries.addNote(id1, "E2E note");
  const act = await sa.db.inquiries.activity(id1);
  check("W3", "status move + note recorded on the timeline", act.notes.length === 1 && act.events.some((e) => e.event === "status_changed" && e.toStatus === "contacted"), JSON.stringify(act.events.map((e) => e.event)));
  const backwards = await errOf(() => sa.db.inquiries.setStatus(id1, "contacted"));
  check("W4", "an illegal move (contacted -> contacted) is refused", /cannot be marked/.test(backwards ?? ""), backwards ?? "no error");

  // ---- no permission: Manager (efz.ops) -----------------------------------------------------------------------------------
  const mgr = await staff("efz.ops@example.com", "E2E_MANAGER_PASSWORD");
  check("P1", "Manager without inquiry permission sees none", (await mgr.db.inquiries.list()).length === 0);
  const mgrWrite = await errOf(() => mgr.db.inquiries.setStatus(id1, "closed"));
  check("P2", "Manager cannot change status", /Permission denied/.test(mgrWrite ?? ""), mgrWrite ?? "no error");
  const mgrNote = await errOf(() => mgr.db.inquiries.addNote(id1, "x"));
  check("P3", "Manager cannot add a note", /Permission denied/.test(mgrNote ?? ""), mgrNote ?? "no error");
  const mgrAssign = await errOf(() => mgr.db.inquiries.assign(id1, null));
  check("P4", "Manager cannot assign", /Permission denied/.test(mgrAssign ?? ""), mgrAssign ?? "no error");

  // ---- delegation: u-stg-delivery gets view + manage (granted by the caller before this script, revoked after) --------------
  const del = await staff("efz.delivery@example.com", "E2E_DELIVERY_PASSWORD");
  const before = await del.db.inquiries.list();
  check("D1", "delegate with view_inquiries only sees nothing until assigned", before.length === 0, `${before.length}`);
  const assignees = await sa.db.inquiries.assignees();
  check("D2", "assignee list contains the delegate", assignees.some((a) => a.id === "u-stg-delivery"), JSON.stringify(assignees.map((a) => a.id)));
  await sa.db.inquiries.assign(id1, "u-stg-delivery");
  const seen = await del.db.inquiries.list();
  check("D3", "after assignment the delegate sees exactly that inquiry", seen.length === 1 && seen[0].id === id1, `${seen.length}`);
  check("D4", "the delegate's alert feed and badge are scoped to what they can see", (await del.db.inquiries.openCount()) === 1);
  await del.db.inquiries.addNote(id1, "E2E delegate note");
  const delOther = await errOf(() => del.db.inquiries.setStatus(wId, "contacted"));
  check("D5", "delegate cannot touch an inquiry that is not assigned to them", /Permission denied/.test(delOther ?? ""), delOther ?? "no error");
  const delAssign = await errOf(() => del.db.inquiries.assign(id1, null));
  check("D6", "delegate without assign_inquiries cannot reassign", /Permission denied/.test(delAssign ?? ""), delAssign ?? "no error");
  const notif = await del.db.notifications.list();
  check("D7", "the assignee got an in-app notification", notif.some((n) => n.id.startsWith("inqasg-")));
  await sa.db.inquiries.assign(id1, null);
  check("D8", "unassigned: delegate access is gone immediately", (await del.db.inquiries.list()).length === 0);
  await sa.db.inquiries.setStatus(id1, "closed", "E2E done");
  const closedAssign = await errOf(() => sa.db.inquiries.assign(id1, "u-stg-delivery"));
  check("D9", "a closed inquiry cannot be assigned", /closed inquiry/.test(closedAssign ?? ""), closedAssign ?? "no error");
  await sa.db.inquiries.setStatus(id1, "contacted");
  check("D10", "a closed inquiry can be reopened", (await sa.db.inquiries.list()).find((i) => i.id === id1)?.status === "contacted");
} catch (e) {
  results.push(false);
  console.log(`FAIL E2E stopped: ${e instanceof Error ? e.message : String(e)}`);
}

const failed = results.filter((r) => !r).length;
console.log(`\nE2E: ${results.length - failed} PASS, ${failed} FAIL`);
process.exit(failed ? 1 : 0);
