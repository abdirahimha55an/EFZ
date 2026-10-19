select pg_temp.t28_guard();
do $t$
declare
  total jsonb := '[]'::jsonb; res jsonb; r uuid; a jsonb; o text; x record; n int; st text; agr uuid; agr_f uuid; lg record;
begin
  perform pg_temp.t28_cust('cust-t28-a', 'Agreement A', '+0002800001');
  perform pg_temp.t28_cust('cust-t28-c', 'List C', '+0002800003');
  perform pg_temp.t28_cust('cust-t28-f', 'Below-cost agreement F', '+0002800006');
  agr := pg_temp.t28_agree('u-stg-manager', 'cust-t28-a', 'prod-stg-nexus', null, 10.00);

  -- T9: a different price for a customer WITH an agreement needs a documented reason of 10+ characters
  begin
    res := '[]'::jsonb;
    r := pg_temp.t28_req('0612800021', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-a', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1, 'actualUnitPrice', 8.00))));
    res := pg_temp.t28_j(res, 'T9 override without a reason is refused', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%agreed price%priceOverrideReason%', a::text);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-a', 'priceOverrideReason', 'too short', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1, 'actualUnitPrice', 8.00))));
    res := pg_temp.t28_j(res, 'T9 a 9-character reason is refused', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%priceOverrideReason%', a::text);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-a', 'priceOverrideReason', '            ', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1, 'actualUnitPrice', 8.00))));
    res := pg_temp.t28_j(res, 'T9 a whitespace-only reason is refused', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%priceOverrideReason%', a::text);
    select count(*) into n from public.orders where customer_id = 'cust-t28-a'; select status into st from public.order_requests where id = r;
    res := pg_temp.t28_j(res, 'T9 nothing written by the refused attempts; request still confirmed', n = 0 and st = 'confirmed', 'orders=' || n || ' status=' || st);
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T9 unexpected error', false, sqlerrm); end if;
  end;

  -- T10: a valid reason -> the override is allowed, recorded as staff_override, and audited
  begin
    res := '[]'::jsonb;
    r := pg_temp.t28_req('0612800022', '[{"productId":"prod-stg-nexus","quantity":2}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-a', 'priceOverrideReason', 'Owner approved a one-off price for this order', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 2, 'actualUnitPrice', 8.00))));
    o := a ->> 'val';
    res := pg_temp.t28_j(res, 'T10 override with a 10+ character reason converts', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', o));
    select i.actual_unit_price ap, i.standard_unit_price sp, v.source src, v.agreement_id agr, v.applied_price vap, v.list_price vlp into x
      from public.order_items i left join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
    res := pg_temp.t28_j(res, 'T10 line charged 8.00, list 12.00 frozen, resolution = staff_override tied to the agreement', found and x.ap = 8 and x.sp = 12 and x.src = 'staff_override' and x.agr = agr and x.vap = 8 and x.vlp = 12, to_jsonb(x)::text);
    select severity::text sev, category::text cat, user_id uid, target_id tid, metadata ->> 'event' ev, (metadata ->> 'agreedPrice')::numeric agreed, (metadata ->> 'chargedPrice')::numeric charged, metadata ->> 'reason' reason, metadata ->> 'agreementId' aid
      into lg from public.system_logs where metadata ->> 'event' = 'agreed_price_overridden' and target_id = o;
    res := pg_temp.t28_j(res, 'T10 audit: WARNING / FINANCIAL log with agreed 10, charged 8, the reason, the actor and the order', found and lg.sev = 'WARNING' and lg.cat = 'FINANCIAL' and lg.uid = 'u-stg-manager' and lg.agreed = 10 and lg.charged = 8 and lg.reason = 'Owner approved a one-off price for this order' and lg.aid = agr::text, to_jsonb(lg)::text);
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T10 unexpected error', false, sqlerrm); end if;
  end;

  -- T10b: sending exactly the agreed price needs no reason; a higher price with a reason is also an override; a list-price customer may change a price without a reason
  begin
    res := '[]'::jsonb;
    r := pg_temp.t28_req('0612800023', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-a', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1, 'actualUnitPrice', 10.00))));
    o := a ->> 'val';
    select v.source src into x from public.order_items i join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
    res := pg_temp.t28_j(res, 'T10b the agreed price sent explicitly needs no reason and stays source = agreement', (a ->> 'ok')::boolean and x.src = 'agreement', coalesce(a ->> 'msg', x.src));
    select count(*) into n from public.system_logs where metadata ->> 'event' = 'agreed_price_overridden' and target_id = o;
    res := pg_temp.t28_j(res, 'T10b no override audit row for the exact agreed price', n = 0, n::text);
    r := pg_temp.t28_req('0612800024', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-a', 'priceOverrideReason', 'Customer agreed to pay a premium today', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1, 'actualUnitPrice', 15.00))));
    o := a ->> 'val';
    select v.source src, i.actual_unit_price ap into x from public.order_items i join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
    res := pg_temp.t28_j(res, 'T10b a HIGHER price than agreed is an override too (needs and records the reason)', (a ->> 'ok')::boolean and x.src = 'staff_override' and x.ap = 15, coalesce(a ->> 'msg', to_jsonb(x)::text));
    r := pg_temp.t28_req('0612800025', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-c', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1, 'actualUnitPrice', 9.00))));
    o := a ->> 'val';
    select v.source src, i.actual_unit_price ap, i.standard_unit_price sp into x from public.order_items i join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
    res := pg_temp.t28_j(res, 'T10b a customer WITHOUT an agreement may be charged a typed price (9.00 over cost) with no reason, as before', (a ->> 'ok')::boolean and x.src = 'list' and x.ap = 9 and x.sp = 12, coalesce(a ->> 'msg', to_jsonb(x)::text));
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T10b unexpected error', false, sqlerrm); end if;
  end;

  -- T11: below-cost rules (Nexus cost 6.70)
  begin
    res := '[]'::jsonb;
    r := pg_temp.t28_req('0612800026', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-c', 'belowCostReason', 'TEST-28 clearance', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1, 'actualUnitPrice', 5.00))));
    res := pg_temp.t28_j(res, 'T11 a Manager cannot approve a below-cost sale', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%Only a Super Admin can approve a below-cost sale%', a::text);
    a := pg_temp.t28_convert('u-stg-admin', r, jsonb_build_object('customerId', 'cust-t28-c', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1, 'actualUnitPrice', 5.00))));
    res := pg_temp.t28_j(res, 'T11 the Super Admin without a below-cost reason is refused', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%belowCostReason%', a::text);
    a := pg_temp.t28_convert('u-stg-admin', r, jsonb_build_object('customerId', 'cust-t28-c', 'belowCostReason', 'TEST-28 approved clearance sale', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1, 'actualUnitPrice', 5.00))));
    o := a ->> 'val';
    res := pg_temp.t28_j(res, 'T11 the Super Admin with a below-cost reason converts', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', o));
    select b.selling_price sp, b.unit_cost uc, b.reason rs, b.approved_by ab into x from public.below_cost_overrides b where b.order_id = o;
    res := pg_temp.t28_j(res, 'T11 below-cost audit row: sold 5.00, cost 6.70, reason and approver recorded', found and x.sp = 5 and x.uc = 6.70 and x.rs = 'TEST-28 approved clearance sale' and x.ab = 'u-stg-admin', to_jsonb(x)::text);
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T11 unexpected error', false, sqlerrm); end if;
  end;

  -- T11b: an agreed price BELOW cost is approved once, when the Super Admin records it; converting at that price then needs no below-cost reason
  begin
    res := '[]'::jsonb;
    a := pg_temp.t28_try('u-stg-manager', format('public.create_price_agreement(%L, %L, null, 6.00, public.efz_today(), null, %L, %L)', 'cust-t28-f', 'prod-stg-nexus', 'TEST-28 authorised by the owner', 'TEST-28 approved below-cost price'));
    res := pg_temp.t28_j(res, 'T11b a Manager cannot record a below-cost agreement', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%Only a Super Admin can approve a below-cost price%', a::text);
    agr_f := pg_temp.t28_agree('u-stg-admin', 'cust-t28-f', 'prod-stg-nexus', null, 6.00, 'TEST-28 approved below-cost price');
    r := pg_temp.t28_req('0612800027', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-f', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1))));
    o := a ->> 'val';
    res := pg_temp.t28_j(res, 'T11b the Manager converts at the approved below-cost agreement, price left out', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', o));
    select i.actual_unit_price ap, v.source src, v.agreement_id agr into x from public.order_items i join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
    res := pg_temp.t28_j(res, 'T11b charged 6.00 as source = agreement', found and x.ap = 6 and x.src = 'agreement' and x.agr = agr_f, to_jsonb(x)::text);
    select b.reason rs into x from public.below_cost_overrides b where b.order_id = o;
    res := pg_temp.t28_j(res, 'T11b its below-cost audit row cites the approved agreement', found and x.rs ilike 'Approved price agreement %', to_jsonb(x)::text);
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T11b unexpected error', false, sqlerrm); end if;
  end;

  -- T11c: observation on existing data: Clearance Ball lists at 8.00 but costs 9.00, so even its LIST price is below cost
  begin
    res := '[]'::jsonb;
    r := pg_temp.t28_req('0612800028', '[{"productId":"prod-stg-clearance","quantity":1}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-c', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-clearance', 'quantity', 1))));
    res := pg_temp.t28_j(res, 'T11c Clearance Ball (list 8.00 < cost 9.00): a Manager converting at the list price is refused as below cost', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%below%cost%', a::text);
    a := pg_temp.t28_convert('u-stg-admin', r, jsonb_build_object('customerId', 'cust-t28-c', 'belowCostReason', 'TEST-28 list price is below cost', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-clearance', 'quantity', 1))));
    res := pg_temp.t28_j(res, 'T11c the Super Admin with a reason converts it at the list price 8.00', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', a ->> 'val'));
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T11c unexpected error', false, sqlerrm); end if;
  end;

  raise exception 'T28RESULT:%', total::text;
end
$t$;
