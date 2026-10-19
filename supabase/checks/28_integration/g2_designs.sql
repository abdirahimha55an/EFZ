select pg_temp.t28_guard();
do $t$
declare
  red constant uuid := '141c080e-50b6-4c0c-b3da-c22f993925fd';    -- existing "E2E Red Design" on Fire Ball
  clr constant uuid := 'a0fb9448-a103-4729-9bdd-e734ac0c745a';    -- existing "E2E Red Design" on Clearance Ball
  blue uuid; total jsonb := '[]'::jsonb; res jsonb; r uuid; a jsonb; o text; x record; n int; st text; ag_red uuid; ag_e_prod uuid; ag_e_red uuid;
begin
  perform pg_temp.t28_cust('cust-t28-b', 'Design agreement B', '+0002800002');
  perform pg_temp.t28_cust('cust-t28-e', 'Product + design agreement E', '+0002800005');
  insert into public.product_designs (product_id, name, image_url, sort_order, is_active) values ('prod-stg-fireball', 'TEST-28 Blue', '', 9, true) returning id into blue;
  ag_red := pg_temp.t28_agree('u-stg-manager', 'cust-t28-b', 'prod-stg-fireball', red, 9.50);
  ag_e_prod := pg_temp.t28_agree('u-stg-manager', 'cust-t28-e', 'prod-stg-fireball', null, 11.00);
  ag_e_red := pg_temp.t28_agree('u-stg-manager', 'cust-t28-e', 'prod-stg-fireball', red, 9.00);
  select count(*) into n from public.product_designs where product_id = 'prod-stg-fireball' and is_active;
  total := pg_temp.t28_j(total, 'setup: Fire Ball has two active designs (existing Red + TEST-28 Blue)', n = 2, n::text);

  -- T3: app-style line with the design id, price left out -> the design's own agreement
  begin
    res := '[]'::jsonb;
    r := pg_temp.t28_req('0612800011', '[{"productId":"prod-stg-fireball","quantity":1}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-b', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1, 'designId', red))));
    o := a ->> 'val';
    res := pg_temp.t28_j(res, 'T3 design-id line converts', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', o));
    select i.design_name dn, i.actual_unit_price ap, i.standard_unit_price sp, v.design_id did, v.source src, v.agreement_id agr into x
      from public.order_items i left join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
    res := pg_temp.t28_j(res, 'T3 design name + design id stored; the design agreement price 9.50 applied', found and x.dn = 'E2E Red Design' and x.did = red and x.ap = 9.50 and x.sp = 12 and x.src = 'agreement' and x.agr = ag_red, to_jsonb(x)::text);
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T3 unexpected error', false, sqlerrm); end if;
  end;

  -- T3n: only the design NAME is sent -> resolved to the catalogue design by name
  begin
    res := '[]'::jsonb;
    r := pg_temp.t28_req('0612800012', '[{"productId":"prod-stg-fireball","quantity":1}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-b', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1, 'designName', 'E2E Red Design'))));
    o := a ->> 'val';
    res := pg_temp.t28_j(res, 'T3n design-name line converts', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', o));
    select i.design_name dn, i.actual_unit_price ap, v.design_id did, v.source src into x from public.order_items i left join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
    res := pg_temp.t28_j(res, 'T3n name resolved to the catalogue design (id recorded) and the design agreement applied', found and x.dn = 'E2E Red Design' and x.did = red and x.ap = 9.50 and x.src = 'agreement', to_jsonb(x)::text);
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T3n unexpected error', false, sqlerrm); end if;
  end;

  -- T3x: a recorded design name that no longer exists in the catalogue -> the NAME is kept on the line, no design agreement, list price
  begin
    res := '[]'::jsonb;
    r := pg_temp.t28_req('0612800013', '[{"productId":"prod-stg-fireball","quantity":1}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-b', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1, 'designName', 'TEST-28 Removed Design'))));
    o := a ->> 'val';
    res := pg_temp.t28_j(res, 'T3x removed-design line converts', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', o));
    select i.design_name dn, i.actual_unit_price ap, v.design_id did, v.source src into x from public.order_items i left join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
    res := pg_temp.t28_j(res, 'T3x recorded name kept, no design id, list price 12.00 (customer B has no product-wide agreement)', found and x.dn = 'TEST-28 Removed Design' and x.did is null and x.ap = 12 and x.src = 'list', to_jsonb(x)::text);
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T3x unexpected error', false, sqlerrm); end if;
  end;

  -- T4 + T6: one request, the same product on two lines with two different designs
  begin
    res := '[]'::jsonb;
    r := pg_temp.t28_req('0612800014', '[{"productId":"prod-stg-fireball","quantity":2}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-e', 'lines', jsonb_build_array(
          jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1, 'designId', red), jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1, 'designId', blue))));
    o := a ->> 'val';
    res := pg_temp.t28_j(res, 'T6 two designs of one product convert in one order', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', o));
    select count(*) as n, bool_or(i.design_name = 'E2E Red Design' and i.actual_unit_price = 9.00 and v.design_id = red and v.agreement_id = ag_e_red) as red_ok,
           bool_or(i.design_name = 'TEST-28 Blue' and i.actual_unit_price = 11.00 and v.design_id = blue and v.agreement_id = ag_e_prod) as blue_ok, sum(i.actual_unit_price * i.quantity) as tot
      into x from public.order_items i join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
    res := pg_temp.t28_j(res, 'T4 Red -> design agreement 9.00; Blue -> falls back to the product agreement 11.00; each line has its own resolution row; total 20.00', x.n = 2 and x.red_ok and x.blue_ok and x.tot = 20, to_jsonb(x)::text);
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T4/T6 unexpected error', false, sqlerrm); end if;
  end;

  -- T4b: the same product with NO design on one line and a design on the other
  begin
    res := '[]'::jsonb;
    r := pg_temp.t28_req('0612800015', '[{"productId":"prod-stg-fireball","quantity":2}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-e', 'lines', jsonb_build_array(
          jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1), jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1, 'designId', red))));
    o := a ->> 'val';
    res := pg_temp.t28_j(res, 'T4b design + no-design lines of one product convert', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', o));
    select count(*) as n, bool_or(v.design_id is null and i.actual_unit_price = 11.00) as plain_ok, bool_or(v.design_id = red and i.actual_unit_price = 9.00) as red_ok into x
      from public.order_items i join public.order_price_resolutions v on v.order_item_id = i.id where i.order_id = o;
    res := pg_temp.t28_j(res, 'T4b no-design line 11.00 (product agreement), Red line 9.00 (design agreement)', x.n = 2 and x.plain_ok and x.red_ok, to_jsonb(x)::text);
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T4b unexpected error', false, sqlerrm); end if;
  end;

  -- T7: stock is per PRODUCT and checked jointly across the lines: 3 available; 2 alone fits, 2 + 2 across two designs does not
  begin
    res := '[]'::jsonb;
    select stock - public.product_committed_quantity(id) into n from public.products where id = 'prod-stg-fireball';
    res := pg_temp.t28_j(res, 'T7 precondition: Fire Ball has 3 available (stock minus promised to open orders)', n = 3, n::text);
    r := pg_temp.t28_req('0612800016', '[{"productId":"prod-stg-fireball","quantity":4}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-e', 'lines', jsonb_build_array(
          jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 2, 'designId', red), jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 2, 'designId', blue))));
    res := pg_temp.t28_j(res, 'T7 2 + 2 (two designs, one product) is refused as insufficient stock', not (a ->> 'ok')::boolean and a ->> 'msg' ilike 'Insufficient stock%', a::text);
    select count(*) into n from public.orders where customer_id = 'cust-t28-e'; select status into st from public.order_requests where id = r;
    res := pg_temp.t28_j(res, 'T7 the refused conversion wrote nothing (no order, request still confirmed)', n = 0 and st = 'confirmed', 'orders=' || n || ' status=' || st);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-e', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 2, 'designId', red))));
    res := pg_temp.t28_j(res, 'T7 2 alone fits and converts', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', a ->> 'val'));
    r := pg_temp.t28_req('0612800017', '[{"productId":"prod-stg-fireball","quantity":2}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-e', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 2, 'designId', blue))));
    res := pg_temp.t28_j(res, 'T7 a second order for 2 more (only 1 left after the first order promise) is refused', not (a ->> 'ok')::boolean and a ->> 'msg' ilike 'Insufficient stock%', a::text);
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T7 unexpected error', false, sqlerrm); end if;
  end;

  -- T8: invalid / duplicate design lines are refused and write nothing
  begin
    res := '[]'::jsonb;
    r := pg_temp.t28_req('0612800018', '[{"productId":"prod-stg-fireball","quantity":1}]'::jsonb);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-e', 'lines', jsonb_build_array(
          jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1, 'designId', red), jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1, 'designId', red))));
    res := pg_temp.t28_j(res, 'T8 same product + same design twice is refused', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%listed once%', a::text);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-e', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1), jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1))));
    res := pg_temp.t28_j(res, 'T8 same product twice without designs is refused', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%listed once%', a::text);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-e', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1, 'designId', clr))));
    res := pg_temp.t28_j(res, 'T8 a design that belongs to another product is refused by create_order', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%does not belong%', a::text);
    a := pg_temp.t28_convert('u-stg-manager', r, jsonb_build_object('customerId', 'cust-t28-e', 'lines', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-fireball', 'quantity', 1, 'designId', 'not-a-uuid'))));
    res := pg_temp.t28_j(res, 'T8 a malformed design id is refused', not (a ->> 'ok')::boolean and a ->> 'msg' ilike '%Invalid design%', a::text);
    select count(*) into n from public.orders where customer_id = 'cust-t28-e'; select status into st from public.order_requests where id = r;
    res := pg_temp.t28_j(res, 'T8 none of these wrote anything; the request is still confirmed', n = 0 and st = 'confirmed', 'orders=' || n || ' status=' || st);
    raise exception 'T28SUB:%', res::text;
  exception when others then
    if sqlerrm like 'T28SUB:%' then total := total || substr(sqlerrm, 8)::jsonb; else total := pg_temp.t28_j(total, 'T8 unexpected error', false, sqlerrm); end if;
  end;

  raise exception 'T28RESULT:%', total::text;
end
$t$;
