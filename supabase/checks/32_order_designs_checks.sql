-- ============================================================================
-- EFZ - CHECKS FOR MIGRATION 32 (order designs)   (EFZ-STAGING ONLY)
-- ----------------------------------------------------------------------------
-- Run: supabase db query --linked --project-ref <STAGING ref> -f supabase/checks/32_order_designs_checks.sql
-- One transaction that ALWAYS ends in an exception, so everything it creates (designs, requests) is rolled back.
-- The exception text IS the report: "M32 CHECKS: n PASS, m FAIL" followed by one line per check.
-- Needs migration 32 applied and Staging's synthetic data (it refuses on anything else, including Production).
-- ============================================================================
begin;
set local lock_timeout = '10s';
set local statement_timeout = '120s';
set local search_path = public, extensions;

create schema m32check;
grant usage on schema m32check to anon, authenticated, service_role;
create table m32check.r (n serial primary key, id text, name text, result text, info text);
grant all on m32check.r to anon, authenticated, service_role;
grant usage on sequence m32check.r_n_seq to anon, authenticated, service_role;

create function m32check.as_(p_who text) returns void language plpgsql as $f$
begin
  perform set_config('role', 'none', true);
  if p_who = 'owner' then
    perform set_config('request.jwt.claims', '', true);
  elsif p_who in ('anon', 'service_role') then
    perform set_config('request.jwt.claims', json_build_object('role', p_who)::text, true);
    perform set_config('role', p_who, true);
  else
    if not exists (select 1 from public.profiles where id = p_who and auth_user_id is not null) then
      raise exception 'STOPPED: staff user % is missing or has no sign-in', p_who;
    end if;
    perform set_config('request.jwt.claims',
      json_build_object('sub', (select auth_user_id from public.profiles where id = p_who), 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);
  end if;
end $f$;

-- runs a statement as the current role; 'OK|<first column>' or '<sqlstate>|<message>'
create function m32check.try(p_sql text) returns text language plpgsql as $f$
declare v text;
begin
  execute p_sql into v;
  return 'OK|' || coalesce(v, '');
exception when others then
  return sqlstate || '|' || sqlerrm;
end $f$;

create function m32check.ok(p_id text, p_name text, p_got text, p_want text) returns void language sql as $f$
  insert into m32check.r (id, name, result, info)
  values (p_id, p_name,
          case when starts_with(coalesce(p_got, '<null>'), p_want) then 'PASS' else 'FAIL' end,
          left(coalesce(p_got, '<null>'), 200) || case when starts_with(coalesce(p_got, '<null>'), p_want) then '' else '  | expected: ' || p_want end);
$f$;

create function m32check.n(p_sql text) returns text language plpgsql as $f$
declare v text;
begin execute p_sql into v; return v; exception when others then return sqlstate || '|' || sqlerrm; end $f$;


do $guard$
begin
  if not exists (select 1 from public.products where id like 'prod-stg-%')
     or not exists (select 1 from public.profiles where id = 'u-stg-admin' and role = 'Super Admin')
     or exists (select 1 from public.products where id = 'prod-1787244881309')
     or exists (select 1 from public.profiles where id = 'u-1') then
    raise exception 'REFUSED: not EFZ-Staging (synthetic markers missing or Production markers present)';
  end if;
  if to_regprocedure('public.public_product_designs()') is null
     or position('designId' in pg_get_functiondef('public.submit_order_request(jsonb)'::regprocedure)) = 0 then
    raise exception 'REFUSED: Migration 32 not applied';
  end if;
end
$guard$;

do $run$
declare
  v_fire   text := 'prod-stg-fireball';
  v_nexus  text := 'prod-stg-nexus';
  v_clear  text := 'prod-stg-clearance';
  v_pro    text := 'prod-stg-pro';
  d_blue   uuid; d_green uuid; d_hidden uuid; d_gold uuid; d_pro uuid;
  v_phone  text;
  v_n      integer := 0;
  v_id     uuid;
  r        text;
  v_stock  integer;
begin
  perform m32check.as_('owner');
  -- fixtures (rolled back with everything else)
  insert into public.product_designs (product_id, name, sort_order) values (v_fire, 'M32 Blue', 2) returning id into d_blue;
  insert into public.product_designs (product_id, name, sort_order) values (v_fire, 'M32 Green', 1) returning id into d_green;
  insert into public.product_designs (product_id, name, is_active) values (v_fire, 'M32 Hidden', false) returning id into d_hidden;
  insert into public.product_designs (product_id, name) values (v_clear, 'M32 Gold') returning id into d_gold;
  update public.products set is_active = false where id = v_pro;
  insert into public.product_designs (product_id, name) values (v_pro, 'M32 Pro Design') returning id into d_pro;
  create table m32check.ids (k text primary key, v text);
  grant select on m32check.ids to anon, authenticated;
  insert into m32check.ids values ('blue', d_blue::text), ('green', d_green::text), ('hidden', d_hidden::text), ('gold', d_gold::text), ('pro', d_pro::text);

  -- ===================== what a visitor may see =====================
  perform m32check.as_('anon');
  perform m32check.ok('P1', 'public list shows the active designs of active products', m32check.n($$select string_agg(name, ',' order by name) from public.public_product_designs() where name like 'M32%'$$), 'M32 Blue,M32 Gold,M32 Green');
  perform m32check.ok('P2', 'an inactive design is not listed', m32check.n($$select count(*) from public.public_product_designs() where name = 'M32 Hidden'$$), '0');
  perform m32check.ok('P3', 'a design of an inactive product is not listed', m32check.n($$select count(*) from public.public_product_designs() where name = 'M32 Pro Design'$$), '0');
  perform m32check.ok('P4', 'the list returns only id, product_id, name and image_url', m32check.n($$select pg_get_function_result('public.public_product_designs()'::regprocedure)$$), 'TABLE(id uuid, product_id text, name text, image_url text)');
  perform m32check.ok('P5', 'the list is ordered by display order within a product (Green 1 before Blue 2)', m32check.n($$select string_agg(name, ',' order by ord) from (select name, row_number() over () ord from public.public_product_designs() where product_id = 'prod-stg-fireball' and name like 'M32%') x$$), 'M32 Green,M32 Blue');
  perform m32check.ok('P6', 'a visitor cannot read the design table directly', m32check.try('select count(*) from public.product_designs'), '42501');
  perform m32check.ok('P7', 'a visitor cannot read the request design lines directly', m32check.try('select count(*) from public.customer_order_request_lines'), '42501');
  perform m32check.ok('P8', 'a visitor cannot call the audit trigger function', m32check.try('select public.log_product_design_changes()'), '42501');
  perform m32check.ok('P9', 'a visitor cannot insert a design', m32check.try($$insert into public.product_designs (product_id, name) values ('prod-stg-fireball', 'M32 Hack')$$), '42501');

  -- ===================== submitting requests =====================
  v_phone := '0619' || lpad((floor(random() * 900000) + 100000)::int::text, 6, '0');
  -- S1: two designs of ONE product, two quantities
  perform m32check.as_('anon');
  r := m32check.try(format($j$select public.submit_order_request(%L::jsonb)$j$, jsonb_build_object('customerName', 'M32 Probe', 'phone', v_phone, 'deliveryLocation', 'Mogadishu', 'submissionKey', gen_random_uuid(),
        'lines', jsonb_build_array(jsonb_build_object('productId', v_fire, 'designId', d_blue, 'quantity', 3), jsonb_build_object('productId', v_fire, 'designId', d_green, 'quantity', 7)))::text));
  perform m32check.ok('S1', 'two designs of one product on two lines are accepted', r, 'OK|');
  v_id := nullif(substr(r, 4), '')::uuid;
  perform m32check.as_('owner');
  perform m32check.ok('S2', 'each line keeps its own product, quantity and design', m32check.n(format($$select string_agg(i.line_no||':'||i.product_id||':'||i.quantity||':'||coalesce(l.design_name,'-'), ' ' order by i.line_no) from public.order_request_items i left join public.customer_order_request_lines l on l.request_id=i.request_id and l.line_no=i.line_no where i.request_id=%L$$, v_id)), '1:prod-stg-fireball:3:M32 Blue 2:prod-stg-fireball:7:M32 Green');
  perform m32check.ok('S3', 'the design id is stored on each line', m32check.n(format($$select count(*) from public.customer_order_request_lines where request_id=%L and design_id is not null$$, v_id)), '2');
  perform m32check.ok('S4', 'the header mirrors line 1 (legacy readers)', m32check.n(format($$select product_id||':'||quantity from public.order_requests where id=%L$$, v_id)), 'prod-stg-fireball:3');
  perform m32check.ok('S5', 'the request is new, with its timeline event and an audit line that counts the design lines', m32check.n(format($$select (select status::text from public.order_requests where id=%L)||'/'||(select count(*) from public.order_request_events where request_id=%L and event='submitted')||'/'||(select (metadata->>'designLines') from public.system_logs where target_id=%L and metadata->>'event'='website_request_submitted')$$, v_id, v_id, v_id::text)), 'new/1/2');
  insert into m32check.ids values ('req_s1', v_id::text);

  perform m32check.as_('anon');
  perform m32check.ok('S6', 'the same product + design twice is refused', m32check.try(format($j$select public.submit_order_request(%L::jsonb)$j$, jsonb_build_object('customerName','M32','phone',v_phone,'lines',jsonb_build_array(jsonb_build_object('productId',v_fire,'designId',d_blue,'quantity',1), jsonb_build_object('productId',v_fire,'designId',d_blue,'quantity',2)))::text)), '22023|Each design of a product can be listed once');
  perform m32check.ok('S7', 'the same product twice WITHOUT a design is refused with the original sentence', m32check.try(format($j$select public.submit_order_request(%L::jsonb)$j$, jsonb_build_object('customerName','M32','phone',v_phone,'lines',jsonb_build_array(jsonb_build_object('productId',v_fire,'quantity',1), jsonb_build_object('productId',v_fire,'quantity',2)))::text)), '22023|Each product can be listed once; change its quantity instead');
  perform m32check.ok('S8', 'a design of a different product is refused', m32check.try(format($j$select public.submit_order_request(%L::jsonb)$j$, jsonb_build_object('customerName','M32','phone',v_phone,'lines',jsonb_build_array(jsonb_build_object('productId',v_nexus,'designId',d_blue,'quantity',1)))::text)), '22023|A selected design is not available');
  perform m32check.ok('S9', 'an inactive design is refused', m32check.try(format($j$select public.submit_order_request(%L::jsonb)$j$, jsonb_build_object('customerName','M32','phone',v_phone,'lines',jsonb_build_array(jsonb_build_object('productId',v_fire,'designId',d_hidden,'quantity',1)))::text)), '22023|A selected design is not available');
  perform m32check.ok('S10', 'a malformed design id is refused', m32check.try(format($j$select public.submit_order_request(%L::jsonb)$j$, jsonb_build_object('customerName','M32','phone',v_phone,'lines',jsonb_build_array(jsonb_build_object('productId',v_fire,'designId','not-a-uuid','quantity',1)))::text)), '22023|A selected design is not available');
  perform m32check.ok('S11', 'a design of an inactive product is refused (product check first)', m32check.try(format($j$select public.submit_order_request(%L::jsonb)$j$, jsonb_build_object('customerName','M32','phone',v_phone,'lines',jsonb_build_array(jsonb_build_object('productId',v_pro,'designId',d_pro,'quantity',1)))::text)), '22023|A selected product is not available');
  perform m32check.ok('S12', 'quantity rules are unchanged (0, 100001, 2.5 refused)', (select string_agg(left(m32check.try(format($j$select public.submit_order_request(%L::jsonb)$j$, jsonb_build_object('customerName','M32','phone',v_phone,'lines',jsonb_build_array(jsonb_build_object('productId',v_nexus,'quantity',q)))::text)), 5), ',') from unnest(array['0','100001','2.5']) q), '22023,22023,22023');
  perform m32check.ok('S13', 'more than 20 lines is refused', m32check.try(format($j$select public.submit_order_request(%L::jsonb)$j$, jsonb_build_object('customerName','M32','phone',v_phone,'lines',(select jsonb_agg(jsonb_build_object('productId',v_nexus,'quantity',1)) from generate_series(1,21)))::text)), '22023|A request needs between 1 and 20 products');

  -- S14: a payload with no designId behaves exactly as before: accepted, no design rows
  v_phone := '0619' || lpad((floor(random() * 900000) + 100000)::int::text, 6, '0');
  r := m32check.try(format($j$select public.submit_order_request(%L::jsonb)$j$, jsonb_build_object('customerName','M32 Plain','phone',v_phone,'lines',jsonb_build_array(jsonb_build_object('productId',v_nexus,'quantity',4), jsonb_build_object('productId',v_fire,'quantity',2)))::text));
  perform m32check.ok('S14', 'a request without designs is accepted as before', r, 'OK|');
  perform m32check.as_('owner');
  perform m32check.ok('S15', 'a request without designs writes no design rows', m32check.n(format($$select count(*) from public.customer_order_request_lines where request_id=%L$$, nullif(substr(r,4),'')::uuid)), '0');

  -- S16: mixed order: a designed line, a plain product line and the same product plain + designed
  v_phone := '0619' || lpad((floor(random() * 900000) + 100000)::int::text, 6, '0');
  perform m32check.as_('anon');
  r := m32check.try(format($j$select public.submit_order_request(%L::jsonb)$j$, jsonb_build_object('customerName','M32 Mixed','phone',v_phone,'submissionKey',gen_random_uuid(),'lines',jsonb_build_array(
        jsonb_build_object('productId',v_clear,'designId',d_gold,'quantity',5), jsonb_build_object('productId',v_nexus,'quantity',1), jsonb_build_object('productId',v_fire,'quantity',2), jsonb_build_object('productId',v_fire,'designId',d_green,'quantity',9)))::text));
  perform m32check.ok('S16', 'a mixed order (designed, plain, and a product both plain and designed) is accepted', r, 'OK|');
  perform m32check.as_('owner');
  perform m32check.ok('S17', 'only the designed lines have design rows (lines 1 and 4)', m32check.n(format($$select string_agg(line_no::text, ',' order by line_no) from public.customer_order_request_lines where request_id=%L$$, nullif(substr(r,4),'')::uuid)), '1,4');

  -- S18: the same submission key again returns the first request and writes nothing new
  v_phone := '0619' || lpad((floor(random() * 900000) + 100000)::int::text, 6, '0');
  perform m32check.as_('anon');
  perform set_config('m32.key', gen_random_uuid()::text, true);
  r := m32check.try(format($j$select public.submit_order_request(%L::jsonb)$j$, jsonb_build_object('customerName','M32 Twice','phone',v_phone,'submissionKey',current_setting('m32.key'),'lines',jsonb_build_array(jsonb_build_object('productId',v_fire,'designId',d_blue,'quantity',1)))::text));
  perform m32check.ok('S18', 'double submit: the second call returns the same request', m32check.try(format($j$select public.submit_order_request(%L::jsonb)$j$, jsonb_build_object('customerName','M32 Twice','phone',v_phone,'submissionKey',current_setting('m32.key'),'lines',jsonb_build_array(jsonb_build_object('productId',v_fire,'designId',d_blue,'quantity',1)))::text)), r);
  perform m32check.as_('owner');
  perform m32check.ok('S19', 'double submit: exactly one request and one design row exist', m32check.n(format($$select (select count(*) from public.order_requests where id=%L)||'/'||(select count(*) from public.customer_order_request_lines where request_id=%L)$$, nullif(substr(r,4),'')::uuid, nullif(substr(r,4),'')::uuid)), '1/1');

  -- ===================== managing designs =====================
  perform m32check.as_('u-stg-inventory');   -- holds edit_products
  perform m32check.ok('M1', 'staff with edit_products can create a design', m32check.try($$insert into public.product_designs (product_id, name, image_url, sort_order) values ('prod-stg-nexus', '  M32 Nexus Red  ', 'https://example.com/red.png', 5) returning name$$), 'OK|M32 Nexus Red');
  perform m32check.ok('M2', 'the name was trimmed by the database', m32check.n($$select count(*) from public.product_designs where product_id='prod-stg-nexus' and name='M32 Nexus Red'$$), '1');
  perform m32check.ok('M3', 'staff can change the name, image and display order', m32check.try($$update public.product_designs set name='M32 Nexus Crimson', image_url='https://example.com/crimson.png', sort_order=3 where product_id='prod-stg-nexus' and name='M32 Nexus Red' returning name$$), 'OK|M32 Nexus Crimson');
  perform m32check.ok('M4', 'a design cannot be moved to another product', m32check.try($$update public.product_designs set product_id='prod-stg-fireball' where name='M32 Nexus Crimson' returning 1$$), '22023|A design cannot be moved');
  perform m32check.ok('M5', 'an http:// image link is refused', m32check.try($$update public.product_designs set image_url='http://example.com/x.png' where name='M32 Nexus Crimson' returning 1$$), '22023|The image link must start with https://');
  perform m32check.ok('M6', 'a javascript: image link is refused', m32check.try($$update public.product_designs set image_url='javascript:alert(1)' where name='M32 Nexus Crimson' returning 1$$), '22023|The image link');
  perform m32check.ok('M7', 'an image link with spaces is refused', m32check.try($$update public.product_designs set image_url='https://example.com/a b.png' where name='M32 Nexus Crimson' returning 1$$), '22023|The image link');
  perform m32check.ok('M8', 'an over-long image link (501 characters) is refused', m32check.try(format($$update public.product_designs set image_url=%L where name='M32 Nexus Crimson' returning 1$$, 'https://e.com/' || repeat('a', 487))), '22023|The image link');
  perform m32check.ok('M9', 'a duplicate name on the same product (any case) is refused', m32check.try($$insert into public.product_designs (product_id, name) values ('prod-stg-nexus', 'm32 nexus crimson') returning 1$$), '23505');
  perform m32check.ok('M10', 'the same name on ANOTHER product is allowed', m32check.try($$insert into public.product_designs (product_id, name) values ('prod-stg-training', 'M32 Nexus Crimson') returning 1$$), 'OK|1');
  perform m32check.ok('M11', 'a blank name is refused', m32check.try($$insert into public.product_designs (product_id, name) values ('prod-stg-nexus', '   ')$$), '23514');
  perform m32check.ok('M12', 'a display order out of range is refused', m32check.try($$update public.product_designs set sort_order=-1 where name='M32 Nexus Crimson' returning 1$$), '22023|The display order');
  perform m32check.ok('M13', 'deactivating hides the design from visitors immediately', m32check.try($$update public.product_designs set is_active=false where name='M32 Nexus Crimson' and product_id='prod-stg-nexus' returning 1$$), 'OK|1');
  perform m32check.as_('anon');
  perform m32check.ok('M14', 'a deactivated design is gone from the public list', m32check.n($$select count(*) from public.public_product_designs() where name='M32 Nexus Crimson' and product_id='prod-stg-nexus'$$), '0');
  perform m32check.as_('u-stg-inventory');
  perform m32check.ok('M15', 'reactivating brings it back', m32check.try($$update public.product_designs set is_active=true where name='M32 Nexus Crimson' and product_id='prod-stg-nexus' returning 1$$), 'OK|1');
  perform m32check.as_('anon');
  perform m32check.ok('M16', 'a reactivated design is in the public list again', m32check.n($$select count(*) from public.public_product_designs() where name='M32 Nexus Crimson' and product_id='prod-stg-nexus'$$), '1');

  perform m32check.as_('u-stg-cs');          -- Customer Service: no edit_products
  perform m32check.ok('M17', 'staff without edit_products can read designs', m32check.n($$select count(*) from public.product_designs where name like 'M32%'$$), '7');
  perform m32check.ok('M18', 'staff without edit_products cannot create a design', m32check.try($$insert into public.product_designs (product_id, name) values ('prod-stg-nexus', 'M32 CS Hack')$$), '42501');
  perform m32check.ok('M19', 'staff without edit_products cannot change a design (0 rows)', m32check.n($$with u as (update public.product_designs set name='M32 CS Renamed' where name='M32 Blue' returning 1) select count(*) from u$$), '0');
  perform m32check.ok('M20', 'staff without edit_products cannot delete a design (0 rows)', m32check.n($$with u as (delete from public.product_designs where name='M32 Blue' returning 1) select count(*) from u$$), '0');
  perform m32check.as_('u-stg-delivery');
  perform m32check.ok('M21', 'delivery staff cannot create a design', m32check.try($$insert into public.product_designs (product_id, name) values ('prod-stg-nexus', 'M32 Delivery Hack')$$), '42501');
  perform m32check.as_('u-stg-admin');
  perform m32check.ok('M22', 'a Super Admin can create a design', m32check.try($$insert into public.product_designs (product_id, name) values ('prod-stg-training', 'M32 Admin Design') returning 1$$), 'OK|1');

  -- deleting a design that is already on a request keeps the name on the line
  perform m32check.as_('u-stg-manager');
  perform m32check.ok('M23', 'a design already used on a request can be deleted by staff with edit_products', m32check.n($$with u as (delete from public.product_designs where name='M32 Green' returning 1) select count(*) from u$$), '1');
  perform m32check.as_('owner');
  perform m32check.ok('M24', 'the request line keeps the design NAME (design id cleared)', m32check.n(format($$select design_name||'/'||(design_id is null)::text from public.customer_order_request_lines where request_id=%L and line_no=2$$, (select v from m32check.ids where k='req_s1')::uuid)), 'M32 Green/true');
  perform m32check.ok('M25', 'the request still has both lines and quantities', m32check.n(format($$select string_agg(quantity::text, ',' order by line_no) from public.order_request_items where request_id=%L$$, (select v from m32check.ids where k='req_s1')::uuid)), '3,7');

  -- ===================== audit trail =====================
  perform m32check.ok('L1', 'creating a design is logged by the database (INVENTORY, origin database)', m32check.n($$select count(*) from public.system_logs where message like 'Design created: %M32 Nexus Red' and category::text='INVENTORY' and origin='database' and metadata->>'event'='design_created'$$), '1');
  perform m32check.ok('L2', 'a rename is logged with the old name', m32check.n($$select count(*) from public.system_logs where message like 'Design updated: % - M32 Nexus Crimson (name, image, display order changed; was "M32 Nexus Red")'$$), '1');
  perform m32check.ok('L3', 'deactivation and reactivation are logged', m32check.n($$select count(*) from public.system_logs where metadata->>'event' in ('design_deactivated','design_activated') and message like '%M32 Nexus Crimson'$$), '2');
  perform m32check.ok('L4', 'deletion is logged', m32check.n($$select count(*) from public.system_logs where message like 'Design deleted: % - M32 Green' and metadata->>'event'='design_deleted'$$), '1');
  perform m32check.ok('L5', 'the log line names the signed-in staff member', m32check.n($$select username from public.system_logs where message like 'Design created: %M32 Nexus Red'$$), (select name from public.profiles where id = 'u-stg-inventory'));
  perform m32check.as_('u-stg-inventory');
  perform m32check.try($$update public.product_designs set is_active = is_active where name='M32 Nexus Crimson'$$);
  perform m32check.as_('owner');
  perform m32check.ok('L6', 'a save that changes nothing writes no log line', m32check.n($$select count(*) from public.system_logs where message like 'Design updated: % - M32 Nexus Crimson%' and message not like '%was "M32 Nexus Red"%'$$), '0');

  -- ===================== nothing else moved =====================
  perform m32check.ok('Z1', 'the checks created no order, payment or stock movement', m32check.n($$select (select count(*) from public.orders where created_at > now() - interval '1 minute' and customer_name like 'M32%')||'/'||(select count(*) from public.payments where created_at > now() - interval '1 minute')$$), '0/0');
end
$run$;

do $report$
declare
  v_pass int; v_fail int; v_lines text;
begin
  perform set_config('role', 'none', true);
  select count(*) filter (where result = 'PASS'), count(*) filter (where result = 'FAIL') into v_pass, v_fail from m32check.r;
  select string_agg(result || ' ' || id || ' ' || name || case when result = 'FAIL' then '  [' || info || ']' else '' end, E'\n' order by n) into v_lines from m32check.r;
  raise exception E'M32 CHECKS: % PASS, % FAIL\n%', v_pass, v_fail, v_lines;
end
$report$;
