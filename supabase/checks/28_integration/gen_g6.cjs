// builds g6_rollback.sql from the REAL migration / rollback files in the repo
const fs = require('fs');
const repo = process.argv[2] || '../../..';
const rd = (f) => fs.readFileSync(repo + '/' + f, 'utf8').replace(/\r\n/g, '\n');
const mig = rd('supabase/28_convert_request_designs.sql');
const rb = rd('supabase/rollback/28_convert_request_designs_rollback.sql');
const cut = (s, from, to) => { const i = s.indexOf(from); if (i < 0) throw new Error('missing ' + from); const j = s.indexOf(to, i); return s.slice(i, j + to.length); };
const fn28 = cut(mig, 'create or replace function public.convert_website_request', '$fn$;');
const fn27 = cut(rb, 'create or replace function public.convert_website_request', '$fn$;');
const guard28 = cut(mig, 'do $pre$', '$pre$;');
const guardRb = cut(rb, 'do $guard$', '$guard$;');
for (const [n, t] of [['fn28', fn28], ['fn27', fn27], ['guard28', guard28], ['guardRb', guardRb]]) for (const tag of ['$q1$', '$q2$', '$q3$', '$q4$', '$t$']) if (t.includes(tag)) throw new Error(n + ' contains ' + tag);

const sql = `select pg_temp.t28_guard();
do $t$
declare
  fn28 constant text := $q1$${fn28}$q1$;
  fn27 constant text := $q2$${fn27}$q2$;
  guard28 constant text := $q3$${guard28}$q3$;
  guardrb constant text := $q4$${guardRb}$q4$;
  md5now text; total jsonb := '[]'::jsonb; res jsonb; r uuid; a jsonb; o text; x record; n int; e text; cur text;
  m28 constant text := '507ea7250e0967ab16ef195c21f29bb2'; m27 constant text := 'fe992c8ab3edc37522d08e3e6eb41c9c';
begin
  perform pg_temp.t28_cust('cust-t28-c', 'List C', '+0002800003');
  select md5(replace(pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure), chr(13), '')) into md5now;
  total := pg_temp.t28_j(total, 'T17 start: Staging has the migration-28 function installed', md5now = m28, md5now);
  select md5(replace(pg_get_functiondef('public.create_order(jsonb)'::regprocedure), chr(13), '')) into cur;
  total := pg_temp.t28_j(total, 'T17 create_order is the migration-27 text and is never touched by this test', cur = '265e9745acb9418787e6d8cebfb450af', cur);

  -- the migration''s own guard accepts its own (already applied) text: a re-run is safe
  begin execute guard28; total := pg_temp.t28_j(total, 'T17 migration-28 guard passes on the installed migration-28 text (retry-safe)', true, 'no exception');
  exception when others then total := pg_temp.t28_j(total, 'T17 migration-28 guard passes on the installed migration-28 text (retry-safe)', false, sqlerrm); end;

  -- 1. the ROLLBACK: guard, then the migration-27 function text
  begin execute guardrb; total := pg_temp.t28_j(total, 'T17 rollback guard accepts the installed migration-28 function', true, 'no exception');
  exception when others then total := pg_temp.t28_j(total, 'T17 rollback guard accepts the installed migration-28 function', false, sqlerrm); end;
  execute fn27;
  select md5(replace(pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure), chr(13), '')) into md5now;
  total := pg_temp.t28_j(total, 'T17 after the rollback text the function md5 is exactly the migration-27 value fe992c8a...', md5now = m27, md5now);
  total := pg_temp.t28_j(total, 'T17 the marker is gone after the rollback', position('migration 28 marker' in pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure)) = 0, '');

  -- behaviour with the rolled-back (old) function
  r := pg_temp.t28_req('0612800051', '[{"productId":"prod-stg-fireball","quantity":1}]'::jsonb);
  a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-c', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1))));
  total := pg_temp.t28_j(total, 'T17 old function: a price-less line is refused again', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%confirmed unit price%', a::text);
  a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-c', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1, 'actualUnitPrice', 12.00, 'designId', '141c080e-50b6-4c0c-b3da-c22f993925fd'))));
  o := a ->> 'val';
  select i.design_name dn, v.design_id did into x from public.order_items i left join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
  total := pg_temp.t28_j(total, 'T17 old function (the old Hub payload with a price) still converts, and the design is DROPPED (the original behaviour)', (a ->> 'ok')::boolean and x.did is null and x.dn = 'EFZ - Fire Ball', coalesce(a ->> 'msg', to_jsonb(x)::text));

  -- 2. RE-APPLY migration 28: its guard must accept the migration-27 text, then the new function goes in
  begin execute guard28; total := pg_temp.t28_j(total, 'T17 migration-28 guard accepts the rolled-back (migration-27) function', true, 'no exception');
  exception when others then total := pg_temp.t28_j(total, 'T17 migration-28 guard accepts the rolled-back (migration-27) function', false, sqlerrm); end;
  execute fn28;
  select md5(replace(pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure), chr(13), '')) into md5now;
  total := pg_temp.t28_j(total, 'T17 after re-applying, the function md5 is the migration-28 value again', md5now = m28, md5now);
  select string_agg(grantee, ',' order by grantee) into e from information_schema.routine_privileges where routine_schema = 'public' and routine_name = 'convert_website_request' and grantee in ('anon', 'authenticated', 'PUBLIC', 'service_role');
  total := pg_temp.t28_j(total, 'T17 grants after rollback + re-apply: authenticated only', e = 'authenticated', coalesce(e, 'none'));
  r := pg_temp.t28_req('0612800052', '[{"productId":"prod-stg-fireball","quantity":1}]'::jsonb);
  a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-c', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1, 'designId', '141c080e-50b6-4c0c-b3da-c22f993925fd'))));
  o := a ->> 'val';
  select i.design_name dn, v.design_id did into x from public.order_items i left join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
  total := pg_temp.t28_j(total, 'T17 migration-28 function works again after the cycle: price left out, design kept', (a ->> 'ok')::boolean and x.did = '141c080e-50b6-4c0c-b3da-c22f993925fd'::uuid and x.dn = 'E2E Red Design', coalesce(a ->> 'msg', to_jsonb(x)::text));

  -- 3. the migration guard REFUSES a function it was not written against (a one-word change to the stored text)
  execute replace(fn27, 'Choose an existing customer or a new one', 'Choose an EXISTING customer or a new one');
  begin execute guard28; total := pg_temp.t28_j(total, 'T17 guard refuses a drifted convert_website_request', false, 'guard did not raise');
  exception when others then total := pg_temp.t28_j(total, 'T17 guard refuses a drifted convert_website_request', sqlerrm ilike '%is not the migration-27 definition%', sqlerrm); end;
  begin execute guardrb; total := pg_temp.t28_j(total, 'T17 rollback guard refuses a drifted function too', false, 'guard did not raise');
  exception when others then total := pg_temp.t28_j(total, 'T17 rollback guard refuses a drifted function too', sqlerrm ilike '%neither the migration-28 nor the migration-27%', sqlerrm); end;

  raise exception 'T28RESULT:%', total::text;
end
$t$;
`;
fs.writeFileSync('g6_rollback.sql', sql);
console.log('generated', sql.length, 'bytes');
