select pg_temp.t28_guard();
do $t$
declare
  r uuid; a jsonb; o text; agr uuid; x record; n int; st text; stock0 int; stock1 int; ev jsonb;
begin
  perform pg_temp.t28_cust('cust-t28-a', 'Agreement A', '+0002800001');
  perform pg_temp.t28_cust('cust-t28-c', 'List C', '+0002800003');
  perform pg_temp.t28_cust('cust-t28-d', 'Pending D', '+0002800004');
  select stock into stock0 from public.products where id = 'prod-stg-nexus';

  -- T1: customer without an agreement, price left out -> list price, source 'list'
  r := pg_temp.t28_req('0612800001', '[{"productId":"prod-stg-nexus","quantity":2}]'::jsonb);
  a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-c', 'deliveryNotes', 'TEST-28', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 2))));
  o := a ->> 'val';
  perform pg_temp.t28_rec('T1 conversion succeeds', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', o));
  select i.actual_unit_price ap, i.standard_unit_price sp, i.historical_unit_cost hc, i.design_name dn, i.quantity q, v.source src, v.applied_price vap, v.list_price vlp, v.agreement_id agr, v.design_id did
    into x from public.order_items i left join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
  perform pg_temp.t28_rec('T1 list price applied and frozen', found and x.ap = 12 and x.sp = 12 and x.hc = 6.70 and x.q = 2 and x.src = 'list' and x.vap = 12 and x.vlp = 12 and x.agr is null and x.did is null, to_jsonb(x)::text);
  select status::text into st from public.orders where id = o;
  perform pg_temp.t28_rec('T1 order is pending (stock not taken at order time)', st = 'pending', st);
  select stock into stock1 from public.products where id = 'prod-stg-nexus';
  perform pg_temp.t28_rec('T1 stock unchanged by the order', stock1 = stock0, stock0 || ' -> ' || stock1);
  select status, converted_order_id into x from public.order_requests where id = r;
  perform pg_temp.t28_rec('T1 request converted and linked', x.status = 'converted' and x.converted_order_id = o, to_jsonb(x)::text);
  select details into ev from public.order_request_events where request_id = r and event = 'converted';
  perform pg_temp.t28_rec('T1 the conversion event records the lines, with no price sent', ev is not null and jsonb_array_length(ev -> 'lines') = 1 and not (ev -> 'lines' -> 0 ? 'actualUnitPrice'), ev::text);

  -- T1b: two products and a NEW customer created by the conversion, no prices
  r := pg_temp.t28_req('0612800002', '[{"productId":"prod-stg-nexus","quantity":1},{"productId":"prod-stg-training","quantity":1}]'::jsonb);
  a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('newCustomer', jsonb_build_object('name', 'TEST-28 New Customer', 'phone', '0612800002'), 'confirmNoDuplicate', true, 'deliveryNotes', 'TEST-28',
        'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1), jsonb_build_object('productId', 'prod-stg-training', 'quantity', 1))));
  o := a ->> 'val';
  perform pg_temp.t28_rec('T1b new-customer conversion succeeds', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', o));
  select count(*) as n, sum(i.actual_unit_price) as s, count(v.order_item_id) as res into x from public.order_items i left join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
  perform pg_temp.t28_rec('T1b two lines at list prices (12 + 8), each with a resolution row', x.n = 2 and x.s = 20 and x.res = 2, to_jsonb(x)::text);
  select count(*) into n from public.customers c join public.orders od on od.customer_id = c.id where od.id = o and c.name = 'TEST-28 New Customer';
  perform pg_temp.t28_rec('T1b the new customer was created and owns the order', n = 1, n::text);

  -- T2: product agreement, price left out -> the agreed price
  agr := pg_temp.t28_agree('u-stg-manager', 'cust-t28-a', 'prod-stg-nexus', null, 10.00);
  r := pg_temp.t28_req('0612800003', '[{"productId":"prod-stg-nexus","quantity":3}]'::jsonb);
  a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-a', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 3))));
  o := a ->> 'val';
  perform pg_temp.t28_rec('T2 conversion succeeds', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', o));
  select i.actual_unit_price ap, i.standard_unit_price sp, v.source src, v.agreement_id agr, v.applied_price vap, v.list_price vlp
    into x from public.order_items i left join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
  perform pg_temp.t28_rec('T2 agreed price 10.00 charged, list 12.00 kept as the standard price, traced to the agreement', found and x.ap = 10 and x.sp = 12 and x.src = 'agreement' and x.agr = agr and x.vap = 10 and x.vlp = 12, to_jsonb(x)::text);

  -- T5: a pending (waiting-to-be-verified) agreement blocks the line; nothing is written
  insert into public.customer_price_agreements (customer_id, product_id, design_id, unit_price, effective_from, effective_to, status, source, reason, candidate_evidence, created_by)
  values ('cust-t28-d', 'prod-stg-nexus', null, 9.00, public.efz_today(), null, 'pending_review', 'import', 'TEST-28 pending fixture', '{}'::jsonb, 'u-stg-admin') returning id into agr;
  r := pg_temp.t28_req('0612800004', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);
  a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-d', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1))));
  perform pg_temp.t28_rec('T5 pending agreement refuses the conversion with the review message', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%needs to be confirmed%', a::text);
  select count(*) into n from public.orders where customer_id = 'cust-t28-d';
  select status into st from public.order_requests where id = r;
  perform pg_temp.t28_rec('T5 no order written and the request is still confirmed', n = 0 and st = 'confirmed', 'orders=' || n || ' status=' || st);
  -- T5b: the manager verifies it; the same request now converts at the verified price
  a := pg_temp.t28_try('u-stg-manager', format('public.verify_price_agreement(%L::uuid, 9.00, public.efz_today(), null, %L, null)', agr, 'TEST-28 verified by the manager against the signed note'));
  perform pg_temp.t28_rec('T5b manager verifies the pending agreement', (a ->> 'ok')::boolean, a::text);
  a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-d', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1))));
  o := a ->> 'val';
  select i.actual_unit_price ap, v.source src, v.agreement_id agr into x from public.order_items i left join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
  perform pg_temp.t28_rec('T5b after verification the same request converts at 9.00 (agreement)', (a ->> 'ok')::boolean and x.ap = 9 and x.src = 'agreement', coalesce(a ->> 'msg', to_jsonb(x)::text));

  raise exception 'T28RESULT:%', pg_temp.t28_out();
end
$t$;
