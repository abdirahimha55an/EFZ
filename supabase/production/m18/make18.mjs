// Builds Migration 18b and the 18b/18c rollbacks from the reviewed templates in this folder and the DEPLOYED
// definitions in the sealed Production backup schema (20261008-144503Z). Every edit to a deployed definition is an
// exact, single-match replacement, asserted here; the rollbacks receive the untouched originals. 18a and 18c are
// hand-written and not generated.
//   node make18.mjs --dump <efz_prod_20261008-144503Z_public_schema.sql> --fingerprints <fingerprints.json> --out <supabase dir>
// Fails closed: nothing is written unless every input is present and matches (dump sha256, fingerprint shape,
// templates, single-match edits, no unfilled placeholder).
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// sha256 of the sealed public-schema dump, as recorded in that backup's SHA256SUMS.txt.
const DUMP_SHA256 = "291de5728456fcf65531f7e142c1a17127646e4d1806e010abbf267528d7e468";
const HERE = path.dirname(fileURLToPath(import.meta.url));

function fail(msg) {
  console.error(`make18: ${msg} - nothing written`);
  process.exit(1);
}

const args = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i += 2) {
  const k = argv[i];
  if (!["--dump", "--fingerprints", "--out"].includes(k) || argv[i + 1] === undefined || k in args) {
    fail("usage: node make18.mjs --dump <public_schema.sql> --fingerprints <fingerprints.json> --out <supabase dir>");
  }
  args[k] = argv[i + 1];
}
for (const k of ["--dump", "--fingerprints", "--out"]) if (!args[k]) fail(`missing ${k}`);

const readFile = (f, what) => {
  try {
    return fs.readFileSync(f);
  } catch {
    return fail(`${what} not readable: ${f}`);
  }
};

const dumpBytes = readFile(args["--dump"], "dump");
const dumpSha = crypto.createHash("sha256").update(dumpBytes).digest("hex");
if (dumpSha !== DUMP_SHA256) fail(`dump sha256 ${dumpSha} is not the sealed ${DUMP_SHA256}`);
const dump = dumpBytes.toString("utf8").replace(/\r/g, "");

let fp;
try {
  fp = JSON.parse(readFile(args["--fingerprints"], "fingerprints").toString("utf8"));
} catch {
  fail("fingerprints file is not valid JSON");
}
const MD5_KEYS = ["convert", "cols_pre", "preset_pre", "logs_pre", "cols_post", "preset_post", "logs_post"];
const POLICY_KEYS = ["policies_pre", "policies_post"];
const keys = Object.keys(fp).sort();
if (keys.join() !== [...MD5_KEYS, ...POLICY_KEYS].sort().join()) fail(`fingerprints keys ${keys.join()} are not the expected set`);
for (const k of MD5_KEYS) if (!/^[0-9a-f]{32}$/.test(fp[k])) fail(`fingerprints ${k} is not an md5`);
for (const k of POLICY_KEYS) {
  if (!/^[a-z_]+:[0-9a-f]{32}(;[a-z_]+:[0-9a-f]{32})*$/.test(fp[k])) fail(`fingerprints ${k} is not a policy list`);
}

const outDir = args["--out"];
if (!fs.existsSync(path.join(outDir, "rollback"))) fail(`output dir has no rollback folder: ${outDir}`);

const read = (f) => readFile(path.join(HERE, f), "template").toString("utf8").replace(/\r/g, "");

function once(text, find, repl, what) {
  const n = text.split(find).length - 1;
  if (n !== 1) fail(`${what}: expected exactly 1 match, found ${n}`);
  return text.replace(find, () => repl);
}

// A function as pg_dump wrote it, from "CREATE FUNCTION public.<name>(" to its closing dollar-quote line.
function deployedFunction(name) {
  const start = dump.indexOf(`CREATE FUNCTION public.${name}(`);
  if (start < 0 || dump.indexOf(`CREATE FUNCTION public.${name}(`, start + 1) >= 0) fail(`${name}: not found exactly once`);
  const m = dump.slice(start).match(/\n    AS (\$[A-Za-z_]*\$)\n/);
  if (!m) fail(`${name}: body start not found`);
  const tag = m[1];
  const end = dump.indexOf(`\n${tag};\n`, start);
  if (end < 0) fail(`${name}: end not found`);
  return dump.slice(start, end + tag.length + 2).replace(/^CREATE FUNCTION/, "CREATE OR REPLACE FUNCTION");
}
const deployedPolicy = (name) => {
  const lines = dump.split("\n").filter((l) => l.startsWith(`CREATE POLICY ${name} ON public.order_requests `));
  if (lines.length !== 1) fail(`policy ${name}: found ${lines.length}`);
  return lines[0];
};

const presetOrig = deployedFunction("grant_role_preset");
const logsOrig = deployedFunction("guard_system_logs_insert");

const presetNew = once(presetOrig,
  "      'view_audit_trail'\n    ]\n\n    when 'Marketing Officer'",
  "      'view_audit_trail',\n      'manage_website_requests'   -- 18: Manager handles website requests\n    ]\n\n    when 'Marketing Officer'",
  "grant_role_preset Manager list");

const logsNew = once(logsOrig,
  "    if new.message ~ '^(Order \\S+ status changed from |",
  "    -- 18: website-request lifecycle lines are written by the database only.\n" +
  "    if new.message ~ '^(Website request REQ-|Customer \\S+ created from REQ-|Order \\S+ status changed from |",
  "guard_system_logs_insert database-only prefixes");

const fill = (t) => t
  .replaceAll("@@MD5_CONVERT@@", fp.convert)
  .replaceAll("@@MD5_COLS_PRE@@", fp.cols_pre).replaceAll("@@POLICIES_PRE@@", fp.policies_pre)
  .replaceAll("@@MD5_PRESET_PRE@@", fp.preset_pre).replaceAll("@@MD5_LOGS_PRE@@", fp.logs_pre)
  .replaceAll("@@MD5_COLS_POST@@", fp.cols_post).replaceAll("@@POLICIES_POST@@", fp.policies_post)
  .replaceAll("@@MD5_PRESET_POST@@", fp.preset_post).replaceAll("@@MD5_LOGS_POST@@", fp.logs_post);

let m18b = read("18b.template.sql");
m18b = once(m18b, "-- @@GRANT_ROLE_PRESET@@", presetNew, "18b preset slot");
m18b = once(m18b, "-- @@GUARD_SYSTEM_LOGS_INSERT@@", logsNew, "18b logs slot");
m18b = fill(m18b);

const legacyFn = (() => {
  const s = m18b.indexOf("create or replace function public.order_requests_legacy_admission()");
  const e = m18b.indexOf("\n$fn$;\n", s);
  if (s < 0 || e < 0) fail("legacy function not found in 18b");
  return m18b.slice(s, e + 7);
})();

let rb18b = read("18b_rollback.template.sql");
rb18b = once(rb18b, "-- @@SELECT_POLICY_ORIGINAL@@", deployedPolicy("order_requests_select"), "rb select policy");
rb18b = once(rb18b, "-- @@UPDATE_POLICY_ORIGINAL@@", deployedPolicy("order_requests_update"), "rb update policy");
rb18b = once(rb18b, "-- @@GRANT_ROLE_PRESET_ORIGINAL@@", presetOrig, "rb preset");
rb18b = once(rb18b, "-- @@GUARD_SYSTEM_LOGS_INSERT_ORIGINAL@@", logsOrig, "rb logs");
rb18b = fill(rb18b);

let rb18c = read("18c_rollback.template.sql");
rb18c = once(rb18c, "-- @@LEGACY_ADMISSION_FUNCTION@@", legacyFn, "rb18c legacy fn");
// pg_dump prints this policy's roles as "authenticated, anon"; Production stores them as {anon, authenticated}
// (created that way by 08). Re-create it in the stored order so the restore is byte-exact, not just equivalent.
rb18c = once(rb18c, "-- @@INSERT_POLICY_ORIGINAL@@",
  once(deployedPolicy("order_requests_insert_public"), "TO authenticated, anon", "TO anon, authenticated", "insert policy role order"),
  "rb18c insert policy");

for (const [t, name] of [[m18b, "18b"], [rb18b, "rb18b"], [rb18c, "rb18c"]]) {
  const left = t.match(/@@[A-Z0-9_]+@@/);
  if (left) fail(`${name}: unfilled placeholder ${left[0]}`);
  if (t.includes("\r")) fail(`${name}: carriage return in output`);
}

fs.writeFileSync(path.join(outDir, "18b_website_request_inbox.sql"), m18b);
fs.writeFileSync(path.join(outDir, "rollback", "18b_rollback.sql"), rb18b);
fs.writeFileSync(path.join(outDir, "rollback", "18c_rollback.sql"), rb18c);
console.log("make18: written 18b_website_request_inbox.sql, rollback/18b_rollback.sql, rollback/18c_rollback.sql");
