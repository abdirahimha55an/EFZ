// End-to-end test of the registration handler against a REAL local PostgreSQL that has migration 21 applied
// (a throw-away clone - never Staging or Production). Auth user creation is simulated by inserting into auth.users
// exactly as the Admin API would (confirmed email, app_metadata.efz_kind = customer), so the real trigger, rate limits,
// pre-flight and registration functions run. Skipped unless EFZ_TEST_PG is set, e.g.
//   EFZ_TEST_PG="C:/pgsql17/pgsql/bin/psql.exe|127.0.0.1|54399|postgres|<database>" npm run test:registration
// Every run happens inside a database the caller created for the purpose; the test cleans up what it creates.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { handleRegistration, type RegistrationDeps } from "./handler.ts";

const cfg = process.env.EFZ_TEST_PG?.split("|");
const skip = !cfg || cfg.length !== 5;

function sql(text: string): { out: string; err: string; ok: boolean } {
  const [psql, host, port, user, db] = cfg as string[];
  if (/supabase\.co|pooler/i.test(host)) throw new Error("refusing: not a local database");
  const r = spawnSync(psql, ["-X", "-q", "-A", "-t", "-h", host, "-p", port, "-U", user, "-d", db, "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose"], { input: text, encoding: "utf8" });
  return { out: r.stdout.trim(), err: r.stderr.trim(), ok: r.status === 0 };
}
const lit = (v: unknown) => `'${String(v).replace(/'/g, "''")}'`;

function deps(): RegistrationDeps {
  return {
    rpc: async (fn, args) => {
      const names = Object.keys(args), vals = names.map((k) => (args[k] === null ? "null" : lit(args[k])));
      const r = sql(`begin; set local role service_role; select coalesce(jsonb_agg(t), '[]'::jsonb) from (select * from public.${fn}(${names.map((n, i) => `${n} => ${vals[i]}`).join(", ")})) t; commit;`);
      if (!r.ok) {
        const m = r.err.match(/ERROR:\s+(.*)/); const code = (r.err.match(/WR\d{3}/) ?? [])[0] ?? (/permission denied/.test(r.err) ? "42501" : "XX000");
        return { data: null, error: { code, message: m?.[1] } };
      }
      const rows = JSON.parse(r.out.split("\n").filter((l) => l.startsWith("[")).pop() ?? "[]");
      return { data: fn === "register_customer_account" ? (Object.values(rows[0] ?? {})[0] ?? null) : rows, error: null };
    },
    createUser: async (a) => {
      const id = randomUUID();
      const r = sql(`insert into auth.users (id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
                     values (${lit(id)}, 'authenticated', 'authenticated', ${lit(a.email)}, now(), ${lit(JSON.stringify({ provider: "email", ...a.app_metadata }))}::jsonb, ${lit(JSON.stringify(a.user_metadata))}::jsonb, now(), now());`);
      return r.ok ? { data: { user: { id } }, error: null } : { data: { user: null }, error: { status: 422, code: "email_exists", message: "already registered" } };
    },
    deleteUser: async (id) => { sql(`delete from auth.users where id = ${lit(id)}`); },
    sha256: async (s) => createHash("sha256").update(s).digest("hex"),
    hintSalt: "integration-salt",
  };
}
const req = (b: Record<string, unknown>, ip = "198.51.100.7") =>
  new Request("https://f.example/x", { method: "POST", headers: { "content-type": "application/json", "x-forwarded-for": ip }, body: JSON.stringify(b) });
const tag = randomUUID().slice(0, 8);
const good = (n: string, phone: string) => ({ email: `it-${tag}-${n}@example.test`, password: "a long enough pass", fullName: `IT ${n}`, phone, organization: "" });

test("integration: register -> pending account, auth user marked customer, NO staff profile", { skip }, async () => {
  const body = good("one", "061 900 0001");
  const res = await handleRegistration(req(body), deps());
  assert.equal(res.status, 202);
  const acc = sql(`select status || '|' || coalesce(customer_id, 'none') || '|' || phone_canonical from public.customer_accounts where email = ${lit(body.email)}`).out;
  assert.equal(acc, "pending|none|+252619000001");
  assert.equal(sql(`select count(*) from public.profiles where lower(email) = ${lit(body.email)}`).out, "0");
  assert.equal(sql(`select raw_app_meta_data ->> 'efz_kind' from auth.users where email = ${lit(body.email)}`).out, "customer");
  assert.equal(sql(`select count(*) from public.customer_account_events e join public.customer_accounts a on a.id = e.account_id where a.email = ${lit(body.email)} and e.event = 'registered'`).out, "1");
});

test("integration: a staff email and a repeat registration both return success without creating anything", { skip }, async () => {
  const staff = sql(`select email from public.profiles where role = 'Super Admin' limit 1`).out;
  assert.ok(staff, "a staff profile exists in the test database");
  const before = sql(`select (select count(*) from public.customer_accounts) || '|' || (select count(*) from auth.users) || '|' || (select count(*) from public.profiles)`).out;
  const r1 = await handleRegistration(req({ ...good("staffmail", "061 900 0002"), email: staff }), deps());
  const dup = good("one", "061 900 0003");
  const r2 = await handleRegistration(req({ ...dup, email: `it-${tag}-one@example.test` }), deps());
  assert.equal(r1.status, 202); assert.equal(r2.status, 202);
  assert.equal(await r1.text(), await r2.text());
  assert.equal(sql(`select (select count(*) from public.customer_accounts) || '|' || (select count(*) from auth.users) || '|' || (select count(*) from public.profiles)`).out, before);
});

test("integration: rate limit per phone (3 / 24 h) answers 429 and creates no auth user", { skip }, async () => {
  const phone = "061 900 0009";
  for (const n of ["r1", "r2", "r3"]) assert.equal((await handleRegistration(req(good(n, phone), `198.51.100.${n.charCodeAt(1)}`), deps())).status, 202);
  const before = sql(`select count(*) from auth.users`).out;
  const res = await handleRegistration(req(good("r4", phone), "198.51.100.99"), deps());
  assert.equal(res.status, 429);
  assert.equal(sql(`select count(*) from auth.users`).out, before);
});

test("integration: invalid phone -> 422 and nothing created", { skip }, async () => {
  const before = sql(`select count(*) from auth.users`).out;
  const res = await handleRegistration(req(good("badphone", "12345")), deps());
  assert.equal(res.status, 422);
  assert.equal(sql(`select count(*) from auth.users`).out, before);
});

test("integration cleanup: remove the rows this test created", { skip }, () => {
  const r = sql(`begin;
    set local session_replication_role = replica;
    delete from public.customer_account_events where account_id in (select id from public.customer_accounts where email like ${lit(`it-${tag}-%`)});
    delete from public.customer_accounts where email like ${lit(`it-${tag}-%`)};
    delete from auth.users where email like ${lit(`it-${tag}-%`)};
    commit;`);
  assert.ok(r.ok, r.err);
});
