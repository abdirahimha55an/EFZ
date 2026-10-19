-- act as a CUSTOMER-APP account (an auth user that is not staff)
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

select pg_temp.t28_guard();
do $t$
declare
  rid1 uuid;
  red constant uuid := '141c080e-50b6-4c0c-b3da-c22f993925fd';
  acct constant uuid := 'ee0ab777-db74-4e3a-a42e-daf74f5f1e86';   -- an existing APPROVED customer account (only a new request is written, inside this rolled-back transaction)
  total jsonb := '[]'::jsonb; res jsonb; uid uuid; acust text; a jsonb; rid uuid; o text; o2 text; x record; n int; ag uuid; pay text;
begin
  select auth_user_id, customer_id into uid, acust from public.customer_accounts where id = acct and status = 'approved';
  total := pg_temp.t28_j(total, 'setup: the customer account is approved, linked to a customer and has a login', uid is not null and acust is not null, coalesce(acust, 'missing'));
  perform pg_temp.t28_cust('cust-t28-b', 'Design agreement B', '+0002800002');
  ag := pg_temp.t28_agree('u-stg-manager', 'cust-t28-b', 'prod-stg-fireball', red, 9.50);

  pay := jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'designId', red, 'quantity', 1)), 'deliveryLocation', 'TEST-28 Hodan', 'notes', 'TEST-28 app request', 'submissionKey', gen_random_uuid())::text;
  a := pg_temp.t28_try_as(uid, format('public.submit_customer_order_request(%L::jsonb)', pay));
  total := pg_temp.t28_j(total, 'E2E the customer app submits a request with a design (real RPC, as the account)', (a ->> 'ok')::boolean, a::text);
  select c.request_id into rid from public.customer_order_requests c where c.account_id = acct order by c.created_at desc limit 1;
  rid1 := rid;
  total := pg_temp.t28_j(total, 'E2E the request exists and is linked to the account', rid is not null, coalesce(rid::text, 'none'));

  select l.design_id did, l.design_name dn into x from public.customer_order_request_lines l where l.request_id = rid and l.line_no = 1;
  total := pg_temp.t28_j(total, 'E2E the request line stores the design id and name', found and x.did = red and x.dn = 'E2E Red Design', to_jsonb(x)::text);

  a := pg_temp.t28_try('u-stg-manager', format('public.set_order_request_status(%L::uuid, ''confirmed'', null)', rid));
  total := pg_temp.t28_j(total, 'E2E a Manager confirms the app request', (a ->> 'ok')::boolean, a::text);

  -- what the Hub reads (orderRequests.list -> withAppInfo): the staff user's own RLS view of the design columns
  a := pg_temp.t28_try('u-stg-manager', format('(select to_jsonb(l) from public.customer_order_request_lines l where l.request_id = %L::uuid and l.line_no = 1)', rid));
  total := pg_temp.t28_j(total, 'E2E the Hub''s query (design_id, design_name of the request line) is readable by a Manager', (a ->> 'ok')::boolean and (a ->> 'val')::jsonb ->> 'design_id' = red::text, a::text);
  a := pg_temp.t28_try('u-stg-manager', format('(select to_jsonb(c) from public.customer_order_requests c where c.request_id = %L::uuid)', rid));
  total := pg_temp.t28_j(total, 'E2E the Hub can see which customer the app request belongs to', (a ->> 'ok')::boolean and (a ->> 'val')::jsonb ->> 'customer_id' = acust, a::text);

  -- convert with the design id carried from the request line, price left out; for the synthetic customer that has the design agreement
  a := pg_temp.t28_convert('u-stg-manager', rid, jsonb_build_object('customerId', 'cust-t28-b', 'deliveryNotes', 'TEST-28 app', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1, 'designId', red))));
  o := a ->> 'val';
  total := pg_temp.t28_j(total, 'E2E the app request converts', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', o));
  select i.design_name dn, i.actual_unit_price ap, i.standard_unit_price sp, v.design_id did, v.source src, v.agreement_id agr into x
    from public.order_items i left join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
  total := pg_temp.t28_j(total, 'E2E the order line keeps the design name and id from the app request, with the design agreement price 9.50', found and x.dn = 'E2E Red Design' and x.did = red and x.ap = 9.50 and x.sp = 12 and x.src = 'agreement' and x.agr = ag, to_jsonb(x)::text);
  select count(*) into n from public.order_request_events e where e.request_id = rid and e.event = 'converted' and e.details -> 'lines' -> 0 ->> 'designId' = red::text;
  total := pg_temp.t28_j(total, 'E2E the conversion event records the design on the line (audit)', n = 1, n::text);
  select d.delivery_notes dnotes into x from public.orders d where d.id = o;
  total := pg_temp.t28_j(total, 'E2E the design is no longer copied into the delivery notes (it is structured data now)', x.dnotes = 'TEST-28 app', x.dnotes);

  -- the same app request flow for the account''s OWN customer (no agreement: list price) - what the Hub preselects
  a := pg_temp.t28_try_as(uid, format('public.submit_customer_order_request(%L::jsonb)', jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'designId', red, 'quantity', 1)), 'deliveryLocation', 'TEST-28 Hodan', 'notes', 'TEST-28 app 2', 'submissionKey', gen_random_uuid())::text));
  total := pg_temp.t28_j(total, 'E2E a second app request from the same account is accepted', (a ->> 'ok')::boolean, a::text);
  select c.request_id into rid from public.customer_order_requests c where c.account_id = acct and c.request_id <> rid1 limit 1;
  a := pg_temp.t28_try('u-stg-manager', format('public.set_order_request_status(%L::uuid, ''confirmed'', null)', rid));
  a := pg_temp.t28_convert('u-stg-manager', rid, jsonb_build_object('customerId', acust, 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1, 'designId', red))));
  o2 := a ->> 'val';
  select i.design_name dn, i.actual_unit_price ap, v.design_id did, v.source src into x from public.order_items i left join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o2;
  total := pg_temp.t28_j(total, 'E2E for the account''s own customer: converts with the design kept, at the list price 12.00 (no agreement)', (a ->> 'ok')::boolean and x.dn = 'E2E Red Design' and x.did = red and x.ap = 12 and x.src = 'list', coalesce(a ->> 'msg', to_jsonb(x)::text));

  raise exception 'T28RESULT:%', total::text;
end
$t$;
