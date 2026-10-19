// LOCAL ONLY - never connects to Staging or Production. Runs the migration-28 convert_website_request (and the rollback text) in an in-memory Postgres (PGlite) with a stubbed create_order.
// usage: install the dependency OUTSIDE the repo (npm i @electric-sql/pglite@0.2.17 in a scratch folder), then:  node 28_local_pglite_test.mjs <path to this repo>
import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';

const REPO = process.argv[2];
const read = (p) => fs.readFileSync(`${REPO}/${p}`, 'utf8').replace(/\r\n/g, '\n');
const fnOf = (sql) => sql.slice(sql.indexOf('create or replace function public.convert_website_request'), sql.indexOf('$fn$;', sql.indexOf('create or replace function public.convert_website_request')) + 5);
const m27 = fnOf(read('supabase/27_price_policy_no_expiry.sql').split('\n').slice(610).join('\n'));
const m28 = fnOf(read('supabase/28_convert_request_designs.sql'));
const rb = fnOf(read('supabase/rollback/28_convert_request_designs_rollback.sql'));

let pass = 0, fail = 0;
const ok = (c, name, extra = '') => { if (c) { pass++; console.log('PASS', name); } else { fail++; console.log('FAIL', name, extra); } };

async function fresh(fnSql) {
  const db = new PGlite();
  await db.exec(`
    create table profiles (id text primary key, name text, role text, status text);
    create table customers (id text primary key, name text, email text, phone text, notes text, marketing_officer_id text, registered_by text, status text);
    create table customer_ownership_changes (customer_id text, customer_name text, old_officer_id text, old_officer_name text, new_officer_id text, new_officer_name text, reason text, orders_moved text, changed_by text, changed_by_name text);
    create table system_logs (id text, severity text, category text, message text, user_id text, username text, target_id text, metadata jsonb);
    create table order_requests (id uuid primary key, status text, assigned_to text, converted_order_id text, handled_by text, status_changed_at timestamptz, updated_at timestamptz);
    create table order_request_events (request_id uuid, event text, from_status text, to_status text, actor_id text, actor_name text, order_id text, details jsonb);
    create table perms (code text primary key);
    create table captured (n serial, payload jsonb);
    create function current_profile_id() returns text language sql as $$ select 'u-test' $$;
    create function current_profile_name() returns text language sql as $$ select 'Tester' $$;
    create function can_access_order_request(a text) returns boolean language sql as $$ select true $$;
    create function has_permission(c text) returns boolean language sql as $$ select exists (select 1 from perms where code = c) $$;
    create function validate_request_phone(p text) returns text language sql as $$ select p $$;
    create function customer_phone_canonical(p text) returns text language sql as $$ select p $$;
    -- STUB create_order: records exactly what the converter hands it (create_order itself is not part of migration 28 and is not exercised here)
    create function create_order(payload jsonb) returns text language plpgsql as $$ begin insert into captured(payload) values (payload); return 'ORD-TEST'; end $$;
    insert into perms values ('convert_website_requests');
    insert into customers values ('cust-1','Existing','','111','', null, null, 'active');
  `);
  await db.exec(fnSql);
  return db;
}
const newReq = (db, status = 'confirmed') => db.query(`insert into order_requests(id,status) values (gen_random_uuid(), $1) returning id`, [status]).then((r) => r.rows[0].id);
const convert = (db, id, payload) => db.query(`select convert_website_request($1::uuid, $2::jsonb) as o`, [id, JSON.stringify(payload)]);
const lastPayload = async (db) => (await db.query(`select payload from captured order by n desc limit 1`)).rows[0]?.payload;
const rejects = async (p, re) => { try { await p; return false; } catch (e) { return re.test(String(e.message)); } };

// ---- 1. md5 fingerprint of the migration-27 text (the value both migration 28 and Staging use)
{
  const db = await fresh(m27);
  const md5 = (await db.query(`select md5(replace(pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure), chr(13), '')) m`)).rows[0].m;
  console.log('INFO local md5 of the migration-27 text:', md5, '(Staging live: fe992c8ab3edc37522d08e3e6eb41c9c)');
  ok(md5 === 'fe992c8ab3edc37522d08e3e6eb41c9c', 'M27 text fingerprints to the Staging md5 (guard value is right)');
}

// ---- 2. migration 28 function: creates, and behaves
{
  const db = await fresh(m28);
  ok(true, 'migration-28 function compiles');
  const base = { customerId: 'cust-1', deliveryNotes: 'n', lines: [] };

  let id = await newReq(db);
  await convert(db, id, { ...base, lines: [{ productId: 'p1', quantity: 2 }] });
  let p = await lastPayload(db);
  ok(p.items.length === 1 && !('actualUnitPrice' in p.items[0]), 'price omitted -> not forwarded (create_order decides the agreed/list price)', JSON.stringify(p));
  ok(!('designId' in p.items[0]) && !('designName' in p.items[0]), 'no design -> none forwarded');
  ok((await db.query(`select status, converted_order_id from order_requests where id=$1`, [id])).rows[0].status === 'converted', 'request marked converted');

  id = await newReq(db);
  await convert(db, id, { ...base, priceOverrideReason: 'Agreed with the owner today', lines: [{ productId: 'p1', quantity: 1, actualUnitPrice: 12.5, designId: '11111111-1111-1111-1111-111111111111', designName: 'Blue' }] });
  p = await lastPayload(db);
  ok(p.items[0].actualUnitPrice === 12.5 && p.items[0].designId === '11111111-1111-1111-1111-111111111111' && p.items[0].designName === 'Blue', 'price + design forwarded unchanged', JSON.stringify(p));
  ok(p.priceOverrideReason === 'Agreed with the owner today', 'priceOverrideReason passed through');

  id = await newReq(db);
  await convert(db, id, { ...base, lines: [{ productId: 'p1', quantity: 1, designId: '11111111-1111-1111-1111-111111111111' }, { productId: 'p1', quantity: 3, designId: '22222222-2222-2222-2222-222222222222' }] });
  p = await lastPayload(db);
  ok(p.items.length === 2 && p.items[0].designId !== p.items[1].designId, 'same product on two lines with two designs is accepted');

  id = await newReq(db);
  ok(await rejects(convert(db, id, { ...base, lines: [{ productId: 'p1', quantity: 1, designId: '11111111-1111-1111-1111-111111111111' }, { productId: 'p1', quantity: 1, designId: '11111111-1111-1111-1111-111111111111' }] }), /listed once/), 'same product+design twice is refused');
  ok(await rejects(convert(db, id, { ...base, lines: [{ productId: 'p1', quantity: 1 }, { productId: 'p1', quantity: 1 }] }), /listed once/), 'same product twice without designs is refused');
  ok(await rejects(convert(db, id, { ...base, lines: [{ productId: 'p1', quantity: 1, designId: 'not-a-uuid' }] }), /Invalid design/), 'a malformed design id is refused');
  ok(await rejects(convert(db, id, { ...base, lines: [{ productId: 'p1', quantity: 1, actualUnitPrice: 'free' }] }), /must be a number/), 'a non-numeric price is refused');
  ok(await rejects(convert(db, id, { ...base, lines: [{ quantity: 1 }] }), /needs a product/), 'a line without a product is refused');
  ok(await rejects(convert(db, id, { ...base, lines: [] }), /between 1 and 20/), 'no lines is refused');
  ok((await db.query(`select status from order_requests where id=$1`, [id])).rows[0].status === 'confirmed', 'refused conversions leave the request confirmed');

  const done = await newReq(db, 'converted');
  ok(await rejects(convert(db, done, { ...base, lines: [{ productId: 'p1', quantity: 1 }] }), /already converted/), 'an already converted request is refused');
  const neu = await newReq(db, 'new');
  ok(await rejects(convert(db, neu, { ...base, lines: [{ productId: 'p1', quantity: 1 }] }), /Only a confirmed request/), 'a non-confirmed request is refused');

  await db.exec(`delete from perms`);
  id = await newReq(db);
  ok(await rejects(convert(db, id, { ...base, lines: [{ productId: 'p1', quantity: 1 }] }), /convert_website_requests is required/), 'without convert_website_requests the call is refused');
  await db.exec(`insert into perms values ('convert_website_requests')`);

  const evt = await db.query(`select details from order_request_events where event='converted' order by request_id limit 1`);
  ok(Array.isArray(evt.rows[0].details.lines), 'the conversion event records the lines (now with design and price when sent)');
  ok(m28.includes('migration 28 marker'), 'the migration-28 marker is in the function body');
  const stored = (await db.query(`select pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure) d`)).rows[0].d;
  ok(stored.includes('migration 28 marker'), 'the marker survives in the STORED definition (re-run / rollback recognise it)');
}

// ---- 3. rollback text is the migration-27 text byte for byte
ok(rb === m27, 'rollback function text == migration-27 function text');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
