-- Synthetic BROWSER-TEST dataset for the Migration 28 checklist (committed). STAGING ONLY. Everything is named TEST-28 B... / cust-t28b-*.
create function pg_temp.t28_try_as(p_uid uuid, p_sql text) returns jsonb language plpgsql as $f$
declare r text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute 'select (' || p_sql || ')::text' into r;
    execute 'reset role'; perform set_config('request.jwt.claims', '', true);
    return jsonb_build_object('ok', true, 'val', r);
  exception when others then
    execute 'reset role'; perform set_config('request.jwt.claims', '', true);
    return jsonb_build_object('ok', false, 'state', sqlstate, 'msg', sqlerrm);
  end;
end $f$;
create temp table ds (n serial, kind text, ref text, purpose text);

select pg_temp.t28_guard();
do $t$
declare
  red constant uuid := '141c080e-50b6-4c0c-b3da-c22f993925fd';   -- existing "E2E Red Design" on Fire Ball
  acct constant uuid := 'ee0ab777-db74-4e3a-a42e-daf74f5f1e86';  -- an existing APPROVED E2E test customer account (only NEW requests are added in its name)
  blue uuid; uid uuid; rid uuid; a jsonb; i int; ag uuid;
begin
  if exists (select 1 from public.customers where id like 'cust-t28b-%') then raise exception 'REFUSED: the browser-test dataset already exists'; end if;
  select auth_user_id into uid from public.customer_accounts where id = acct and status = 'approved';
  if uid is null then raise exception 'REFUSED: the E2E customer account is not approved'; end if;

  perform pg_temp.t28_cust('cust-t28b-a', 'B Agreement A (Nexus 10.00)', '+0002800101');
  perform pg_temp.t28_cust('cust-t28b-b', 'B Design B (Fire Ball: Red 9.50, product 11.00)', '+0002800102');
  perform pg_temp.t28_cust('cust-t28b-c', 'B List price C', '+0002800103');
  perform pg_temp.t28_cust('cust-t28b-d', 'B Pending agreement D (review required)', '+0002800104');
  insert into ds(kind, ref, purpose) values ('customer', 'cust-t28b-a', 'TEST-28 B Agreement A: agreed Nexus price 10.00'), ('customer', 'cust-t28b-b', 'TEST-28 B Design B: Fire Ball Red design 9.50, Fire Ball product-wide 11.00'),
         ('customer', 'cust-t28b-c', 'TEST-28 B List price C: no agreements'), ('customer', 'cust-t28b-d', 'TEST-28 B Pending agreement D: Nexus agreement waiting to be verified (review required)');

  insert into public.product_designs (product_id, name, image_url, sort_order, is_active) values ('prod-stg-fireball', 'TEST-28B Blue', '', 90, true) returning id into blue;
  insert into ds(kind, ref, purpose) values ('design', blue::text, 'TEST-28B Blue on Fire Ball (active; deactivate after the browser run)');

  ag := pg_temp.t28_agree('u-stg-manager', 'cust-t28b-a', 'prod-stg-nexus', null, 10.00);
  ag := pg_temp.t28_agree('u-stg-manager', 'cust-t28b-b', 'prod-stg-fireball', red, 9.50);
  ag := pg_temp.t28_agree('u-stg-manager', 'cust-t28b-b', 'prod-stg-fireball', null, 11.00);
  insert into public.customer_price_agreements (customer_id, product_id, design_id, unit_price, effective_from, effective_to, status, source, reason, candidate_evidence, created_by)
  values ('cust-t28b-d', 'prod-stg-nexus', null, 9.00, public.efz_today(), null, 'pending_review', 'import', 'TEST-28B pending fixture', '{}'::jsonb, 'u-stg-admin');

  -- website requests (public form, then confirmed by a Manager)
  rid := pg_temp.t28_req('0612800201', '[{"productId":"prod-stg-nexus","quantity":2}]'::jsonb);  insert into ds(kind, ref, purpose) values ('request', 'REQ-' || upper(left(replace(rid::text, '-', ''), 8)) || '  ' || rid, 'S1 LIST PRICE: Nexus x2 -> pick customer C');
  rid := pg_temp.t28_req('0612800202', '[{"productId":"prod-stg-nexus","quantity":3}]'::jsonb);  insert into ds(kind, ref, purpose) values ('request', 'REQ-' || upper(left(replace(rid::text, '-', ''), 8)) || '  ' || rid, 'S2a PRODUCT AGREEMENT: Nexus x3 -> pick customer A (agreed 10.00); leave the price alone');
  rid := pg_temp.t28_req('0612800203', '[{"productId":"prod-stg-nexus","quantity":3}]'::jsonb);  insert into ds(kind, ref, purpose) values ('request', 'REQ-' || upper(left(replace(rid::text, '-', ''), 8)) || '  ' || rid, 'S5 OVERRIDE: Nexus x3 -> customer A, type 8.00, check the summary, reason validation, then convert');
  rid := pg_temp.t28_req('0612800204', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);  insert into ds(kind, ref, purpose) values ('request', 'REQ-' || upper(left(replace(rid::text, '-', ''), 8)) || '  ' || rid, 'S4 REVIEW BLOCKING: Nexus x1 -> customer D (pending agreement) must be blocked');
  rid := pg_temp.t28_req('0612800205', '[{"productId":"prod-stg-nexus","quantity":3}]'::jsonb);  insert into ds(kind, ref, purpose) values ('request', 'REQ-' || upper(left(replace(rid::text, '-', ''), 8)) || '  ' || rid, 'S7 CUSTOMER SWITCH: customer A, type 8.00, then switch to customer C (price must reset); do NOT convert');
  rid := pg_temp.t28_req('0612800206', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);  insert into ds(kind, ref, purpose) values ('request', 'REQ-' || upper(left(replace(rid::text, '-', ''), 8)) || '  ' || rid, 'S3 FAILED LOOKUP + RETRY: block resolve_order_price in DevTools (or go offline), pick customer C, Retry; then convert');
  rid := pg_temp.t28_req('0612800207', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);  insert into ds(kind, ref, purpose) values ('request', 'REQ-' || upper(left(replace(rid::text, '-', ''), 8)) || '  ' || rid, 'S8 DUPLICATE: convert for customer C, then try to convert the same request again (second tab / reload)');
  rid := pg_temp.t28_req('0612800208', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);  insert into ds(kind, ref, purpose) values ('request', 'REQ-' || upper(left(replace(rid::text, '-', ''), 8)) || '  ' || rid, 'SPARE: a confirmed website request');

  -- customer-app requests with designs (submitted through the real app RPC by the E2E test account, then confirmed by a Manager)
  a := pg_temp.t28_try_as(uid, format('public.submit_customer_order_request(%L::jsonb)', jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'designId', red, 'quantity', 1)), 'deliveryLocation', 'TEST-28B Hodan', 'notes', 'TEST-28B design request', 'submissionKey', gen_random_uuid())::text));
  if not (a ->> 'ok')::boolean then raise exception 'app request 1 failed: %', a ->> 'msg'; end if;
  rid := (a ->> 'val')::uuid;
  a := pg_temp.t28_try('u-stg-manager', format('public.set_order_request_status(%L::uuid, ''confirmed'', null)', rid));
  insert into ds(kind, ref, purpose) values ('request', 'REQ-' || upper(left(replace(rid::text, '-', ''), 8)) || '  ' || rid, 'S2b DESIGN AGREEMENT (customer-app request): Fire Ball, Red design -> pick customer B (design agreed 9.50)');
  a := pg_temp.t28_try_as(uid, format('public.submit_customer_order_request(%L::jsonb)', jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'designId', red, 'quantity', 1), jsonb_build_object('productId', 'prod-stg-fireball', 'designId', blue, 'quantity', 1)), 'deliveryLocation', 'TEST-28B Hodan', 'notes', 'TEST-28B two designs request', 'submissionKey', gen_random_uuid())::text));
  if not (a ->> 'ok')::boolean then raise exception 'app request 2 failed: %', a ->> 'msg'; end if;
  rid := (a ->> 'val')::uuid;
  a := pg_temp.t28_try('u-stg-manager', format('public.set_order_request_status(%L::uuid, ''confirmed'', null)', rid));
  insert into ds(kind, ref, purpose) values ('request', 'REQ-' || upper(left(replace(rid::text, '-', ''), 8)) || '  ' || rid, 'S6 MULTIPLE DESIGNS (customer-app request): Fire Ball Red + Fire Ball Blue -> customer B (Red 9.50 design agreement, Blue falls back to 11.00)');
end
$t$;
select kind, ref, purpose from ds order by n;
commit;
