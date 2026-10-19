-- moves an order through the normal back-office flow as the Manager: processing -> full delivery -> full payment; returns what happened
create function pg_temp.t28_flow(p_order text) returns jsonb language plpgsql as $f$
declare a jsonb; lines jsonb; stock_before jsonb; stock_after jsonb; o jsonb; tot numeric; out jsonb := '{}'::jsonb;
begin
  select jsonb_object_agg(p.id, p.stock) into stock_before from public.products p where p.id in (select product_id from public.order_items where order_id = p_order);
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''processing'', ''TEST-28'')', p_order));
  if not (a ->> 'ok')::boolean then
    a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''confirmed'', ''TEST-28'')', p_order));
    a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''processing'', ''TEST-28'')', p_order));
  end if;
  out := out || jsonb_build_object('processing', a);
  select jsonb_agg(jsonb_build_object('orderItemId', id, 'quantity', quantity) order by id) into lines from public.order_items where order_id = p_order;
  a := pg_temp.t28_try('u-stg-manager', format('public.record_delivery(%L, %L::jsonb, ''TEST-28'', null)', p_order, lines::text));
  out := out || jsonb_build_object('delivery', a);
  select total into tot from public.orders where id = p_order;
  a := pg_temp.t28_try('u-stg-manager', format('public.record_payment(%L, %s, ''Cash'', public.efz_today(), ''TEST-28'', ''TEST-28'')', p_order, tot));
  out := out || jsonb_build_object('payment', a);
  select jsonb_object_agg(p.id, p.stock) into stock_after from public.products p where p.id in (select product_id from public.order_items where order_id = p_order);
  select jsonb_build_object('status', status::text, 'payment_status', payment_status::text, 'total', total, 'cost', cost, 'gross_profit', gross_profit, 'amount_paid', amount_paid, 'outstanding', outstanding_balance) into o from public.orders where id = p_order;
  out := out || jsonb_build_object('order', o, 'stock_before', stock_before, 'stock_after', stock_after,
     'commission_rows', (select count(*) from public.commissions where order_id = p_order), 'commission_amount', (select coalesce(sum(amount), 0) from public.commissions where order_id = p_order),
     'payments', (select count(*) from public.payments where order_id = p_order));
  return out;
end $f$;

select pg_temp.t28_guard();
do $t$
declare
  total jsonb := '[]'::jsonb; res jsonb; r uuid; r2 uuid; a jsonb; o text; o2 text; x record; sbn jsonb; sbt jsonb; zn jsonb; wt jsonb; n int; st text; agr uuid; f1 jsonb; f2 jsonb; who text;
begin
  perform pg_temp.t28_cust('cust-t28-a', 'Agreement A', '+0002800001');
  perform pg_temp.t28_cust('cust-t28-c', 'List C', '+0002800003');
  agr := pg_temp.t28_agree('u-stg-manager', 'cust-t28-a', 'prod-stg-nexus', null, 10.00);
  perform pg_temp.t28_cust('cust-t28-i', 'Control I', '+0002800009');
  perform pg_temp.t28_agree('u-stg-manager', 'cust-t28-i', 'prod-stg-nexus', null, 10.00);

  -- T12: duplicate / out-of-state conversions
  begin
    res := '[]'::jsonb;
    r := pg_temp.t28_req('0612800031', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-c', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1))));
    o := a ->> 'val';
    res := pg_temp.t28_j(res, 'T12 first conversion succeeds', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', o));
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-c', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1))));
    res := pg_temp.t28_j(res, 'T12 converting the same request again is refused (WR409 already converted)', not (a ->> 'ok')::boolean and a ->> 'state' = 'WR409' and a ->> 'msg' ilike '%already converted to order ' || o || '%', a::text);
    a := pg_temp.t28_convert('u-stg-admin', r, jsonb_build_object('customerId', 'cust-t28-c', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1))));
    res := pg_temp.t28_j(res, 'T12 even the Super Admin cannot convert it a second time', not (a ->> 'ok')::boolean and a ->> 'state' = 'WR409', a::text);
    select count(*) into n from public.orders where customer_id = 'cust-t28-c';
    res := pg_temp.t28_j(res, 'T12 exactly one order exists for the request', n = 1, n::text);
    r2 := pg_temp.t28_req('0612800032', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);
    begin
      update public.order_requests set converted_order_id = o, status = 'converted' where id = r2;
      res := pg_temp.t28_j(res, 'T12 database refuses a second request linking to the same order (unique index)', false, 'update unexpectedly succeeded');
    exception when unique_violation then
      res := pg_temp.t28_j(res, 'T12 database refuses a second request linking to the same order (unique index)', true, 'unique_violation order_requests_converted_order_uq');
    end;
    -- not-confirmed requests
    r := pg_temp.t28_submit('0612800033', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-c', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1))));
    res := pg_temp.t28_j(res, 'T12 a NEW (not yet confirmed) request is refused', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%Only a confirmed request%', a::text);
    a := pg_temp.t28_try('u-stg-manager', format('public.set_order_request_status(%L::uuid, ''rejected'', ''TEST-28 rejected'')', r));
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-c', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1))));
    res := pg_temp.t28_j(res, 'T12 a REJECTED request is refused', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%Only a confirmed request%', a::text);
    a := pg_temp.t28_convert('u-stg-manager', gen_random_uuid(), jsonb_build_object('customerId', 'cust-t28-c', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1))));
    res := pg_temp.t28_j(res, 'T12 an unknown request id is refused', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%unknown website request%', a::text);
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T12 unexpected error', false, sqlerrm); end if;
  end;

  -- T13: who may convert
  begin
    res := '[]'::jsonb;
    r := pg_temp.t28_req('0612800034', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);
    for who in select unnest(array['u-stg-officer1', 'u-stg-officer2', 'u-stg-cs', 'u-stg-inventory', 'u-stg-delivery', 'u-stg-suspended']) loop
      a := pg_temp.t28_convert(who, r, jsonb_build_object('customerId', 'cust-t28-c', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1))));
      res := pg_temp.t28_j(res, 'T13 ' || who || ' cannot convert', not (a ->> 'ok')::boolean and a ->> 'state' = '42501', a::text);
    end loop;
    a := pg_temp.t28_convert(null, r, jsonb_build_object('customerId', 'cust-t28-c', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1))));
    res := pg_temp.t28_j(res, 'T13 an anonymous visitor cannot call the converter', not (a ->> 'ok')::boolean and a ->> 'state' = '42501', a::text);
    a := pg_temp.t28_convert('u-stg-nologin', r, jsonb_build_object('customerId', 'cust-t28-c', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1))));
    res := pg_temp.t28_j(res, 'T13 u-stg-nologin: COULD NOT BE TESTED (this profile has no login/auth user, so it cannot make a call at all)', true, a::text);
    select count(*) into n from public.orders where customer_id = 'cust-t28-c'; select status into st from public.order_requests where id = r;
    res := pg_temp.t28_j(res, 'T13 none of the refusals wrote anything; request still confirmed', n = 0 and st = 'confirmed', 'orders=' || n || ' status=' || st);
    a := pg_temp.t28_convert('u-stg-ops', r, jsonb_build_object('customerId', 'cust-t28-c', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1))));
    res := pg_temp.t28_j(res, 'T13 the second Manager (u-stg-ops) can convert', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', a ->> 'val'));
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T13 unexpected error', false, sqlerrm); end if;
  end;

  -- T14: the OLD payload shape (an explicit price on every line, as the Hub sent before migration 28) still behaves exactly as before
  begin
    res := '[]'::jsonb;
    r := pg_temp.t28_req('0612800035', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-c', 'deliveryNotes', 'x', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1, 'actualUnitPrice', 12.00))));
    o := a ->> 'val';
    res := pg_temp.t28_j(res, 'T14 old payload, list-price customer, list price sent: converts', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', o));
    r := pg_temp.t28_req('0612800036', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-a', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1, 'actualUnitPrice', 12.00))));
    res := pg_temp.t28_j(res, 'T14 old payload, agreement customer, LIST price sent without a reason: refused exactly as before (the case the new dialog avoids)', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%priceOverrideReason%', a::text);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-a', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1, 'actualUnitPrice', 10.00))));
    res := pg_temp.t28_j(res, 'T14 old payload, agreement customer, the agreed price sent: converts', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', a ->> 'val'));
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T14 unexpected error', false, sqlerrm); end if;
  end;

  -- T15: a CONVERTED order and the SAME order made directly with create_order must behave identically through delivery, payment, stock and commission
  begin
    res := '[]'::jsonb;
    -- the sales view counts every non-cancelled order (pending included), so its "before" is taken before the two orders exist
    sbn := pg_temp.t28_sales('prod-stg-nexus'); sbt := pg_temp.t28_sales('prod-stg-training');
    r := pg_temp.t28_req('0612800037', '[{"productId":"prod-stg-nexus","quantity":3},{"productId":"prod-stg-training","quantity":2}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-a', 'deliveryNotes', 'TEST-28', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 3), jsonb_build_object('productId', 'prod-stg-training', 'quantity', 2))));
    o := a ->> 'val';
    res := pg_temp.t28_j(res, 'T15 converted order created', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', o));
    a := pg_temp.t28_try('u-stg-manager', format('public.create_order(%L::jsonb)', jsonb_build_object('customerId', 'cust-t28-i', 'deliveryNotes', 'TEST-28 direct', 'items', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 3), jsonb_build_object('productId', 'prod-stg-training', 'quantity', 2)))::text));
    o2 := a ->> 'val';
    res := pg_temp.t28_j(res, 'T15 control order created directly with create_order', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', o2));
    select count(*) as n, sum(i.quantity * i.actual_unit_price) as tot, sum(i.quantity * i.historical_unit_cost) as cst into x from public.order_items i where i.order_id = o;
    res := pg_temp.t28_j(res, 'T15 hand calculation: 3 x 10.00 (agreed) + 2 x 8.00 (list) = 46.00; cost 3 x 6.70 + 2 x 4.00 = 28.10', x.n = 2 and x.tot = 46 and x.cst = 28.10, to_jsonb(x)::text);
    f1 := pg_temp.t28_flow(o);
    f2 := pg_temp.t28_flow(o2);
    res := pg_temp.t28_j(res, 'T15 converted order: processing, delivery and payment all succeeded', (f1 -> 'processing' ->> 'ok')::boolean and (f1 -> 'delivery' ->> 'ok')::boolean and (f1 -> 'payment' ->> 'ok')::boolean, f1::text);
    res := pg_temp.t28_j(res, 'T15 control order: processing, delivery and payment all succeeded', (f2 -> 'processing' ->> 'ok')::boolean and (f2 -> 'delivery' ->> 'ok')::boolean and (f2 -> 'payment' ->> 'ok')::boolean, f2::text);
    res := pg_temp.t28_j(res, 'T15 totals match the hand calculation and are fully paid: total 46, cost 28.10, gross profit 17.90, outstanding 0',
      (f1 -> 'order' ->> 'total')::numeric = 46 and (f1 -> 'order' ->> 'cost')::numeric = 28.10 and (f1 -> 'order' ->> 'gross_profit')::numeric = 17.90 and (f1 -> 'order' ->> 'amount_paid')::numeric = 46 and (f1 -> 'order' ->> 'outstanding')::numeric = 0 and f1 -> 'order' ->> 'status' = 'delivered' and f1 -> 'order' ->> 'payment_status' = 'paid', (f1 -> 'order')::text);
    res := pg_temp.t28_j(res, 'T15 converted and directly created orders are financially identical (totals, status, payment)', f1 -> 'order' = f2 -> 'order', (f1 -> 'order')::text || ' VS ' || (f2 -> 'order')::text);
    res := pg_temp.t28_j(res, 'T15 commission rows and amount are identical for both (each customer''s first order: 5 balls x 0.30 = 1.50 + 3.00 first-order bonus = 4.50)', f1 -> 'commission_rows' = f2 -> 'commission_rows' and f1 -> 'commission_amount' = f2 -> 'commission_amount' and (f1 ->> 'commission_amount')::numeric = 4.50, 'converted rows=' || (f1 ->> 'commission_rows') || ' amount=' || (f1 ->> 'commission_amount') || ' | control rows=' || (f2 ->> 'commission_rows') || ' amount=' || (f2 ->> 'commission_amount'));
    res := pg_temp.t28_j(res, 'T15 each delivery took exactly the delivered balls from stock (3 Nexus + 2 Training per order, two orders)',
      (f1 -> 'stock_before' ->> 'prod-stg-nexus')::int - (f1 -> 'stock_after' ->> 'prod-stg-nexus')::int = 3 and (f1 -> 'stock_before' ->> 'prod-stg-training')::int - (f1 -> 'stock_after' ->> 'prod-stg-training')::int = 2
      and (f2 -> 'stock_before' ->> 'prod-stg-nexus')::int - (f2 -> 'stock_after' ->> 'prod-stg-nexus')::int = 3 and (f2 -> 'stock_before' ->> 'prod-stg-training')::int - (f2 -> 'stock_after' ->> 'prod-stg-training')::int = 2, (f1 -> 'stock_before')::text || ' -> ' || (f1 -> 'stock_after')::text);
    select d.total, d.unit_count, jsonb_array_length(d.items) as nitems into x from public.order_details d where d.id = o;
    res := pg_temp.t28_j(res, 'T15 the order_details view shows the converted order (total 46, 5 units, 2 items)', found and x.total = 46 and x.unit_count = 5 and x.nitems = 2, to_jsonb(x)::text);
    zn := pg_temp.t28_sales('prod-stg-nexus'); wt := pg_temp.t28_sales('prod-stg-training');
    res := pg_temp.t28_j(res, 'T15 product_sales moved by exactly the two orders: Nexus +6 units / +60.00 revenue / +40.20 cost; Training +4 / +32.00 / +16.00',
      (zn ->> 'units_sold')::numeric - (sbn ->> 'units_sold')::numeric = 6 and (zn ->> 'revenue')::numeric - (sbn ->> 'revenue')::numeric = 60 and (zn ->> 'cost')::numeric - (sbn ->> 'cost')::numeric = 40.20
      and (wt ->> 'units_sold')::numeric - (sbt ->> 'units_sold')::numeric = 4 and (wt ->> 'revenue')::numeric - (sbt ->> 'revenue')::numeric = 32 and (wt ->> 'cost')::numeric - (sbt ->> 'cost')::numeric = 16,
      'nexus before ' || sbn::text || ' after ' || zn::text);
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T15 unexpected error', false, sqlerrm); end if;
  end;

  raise exception 'T28RESULT:%', total::text;
end
$t$;
