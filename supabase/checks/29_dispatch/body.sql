select pg_temp.t28_guard();
-- helper: what a signed-in user can read from a private Realtime topic, as that user (everything here is rolled back)
create function pg_temp.t29_visible(p_topic text) returns bigint language plpgsql as $f$
begin
  perform set_config('realtime.topic', p_topic, true);
  return (select count(*) from realtime.messages);
end $f$;
create function pg_temp.t29_write(p_order text) returns int language plpgsql as $f$
begin
  update public.orders set dispatched_at = null where id = p_order;
  return 1;
end $f$;
do $t$
declare
  res jsonb := '[]'::jsonb; a jsonb; o1 text; o2 text; o3 text; o4 text; o5 text; o6 text; x record; n bigint; cs_auth uuid; b_auth uuid; accb uuid; acc uuid; lines jsonb; pl text;
begin
  perform pg_temp.t28_cust('cust-t29-a', 'Dispatch A', '+0002900001');
  perform pg_temp.t28_cust('cust-t29-b', 'Dispatch B', '+0002900002');
  -- an approved customer-app account for cust-t29-a (it borrows a staff login's auth user only to have a JWT subject)
  select auth_user_id into cs_auth from public.profiles where id = 'u-stg-cs';
  insert into public.customer_accounts (auth_user_id, email, full_name, phone, phone_canonical) values (cs_auth, 'test29@example.invalid', 'TEST-29', '+0002900001', '+0002900001') returning id into acc;
  a := pg_temp.t28_try('u-stg-admin', format('public.approve_customer_account(%L::uuid, %L, false, true, %L)', acc, 'cust-t29-a', 'TEST-29 verified by phone call'));
  res := pg_temp.t28_j(res, 'fixture: customer app account approved through the real RPC', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', a ->> 'val'));

  select auth_user_id into b_auth from public.profiles where id = 'u-stg-inventory';
  insert into public.customer_accounts (auth_user_id, email, full_name, phone, phone_canonical) values (b_auth, 'test29b@example.invalid', 'TEST-29B', '+0002900002', '+0002900002') returning id into accb;
  a := pg_temp.t28_try('u-stg-admin', format('public.approve_customer_account(%L::uuid, %L, false, true, %L)', accb, 'cust-t29-b', 'TEST-29B verified by phone call'));
  a := pg_temp.t28_try('u-stg-manager', format('public.create_order(%L::jsonb)', jsonb_build_object('customerId', 'cust-t29-a', 'deliveryNotes', 'TEST-29 o1', 'items', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 3)))::text)); o1 := a ->> 'val';
  a := pg_temp.t28_try('u-stg-manager', format('public.create_order(%L::jsonb)', jsonb_build_object('customerId', 'cust-t29-a', 'deliveryNotes', 'TEST-29 o2', 'items', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1)))::text)); o2 := a ->> 'val';
  a := pg_temp.t28_try('u-stg-manager', format('public.create_order(%L::jsonb)', jsonb_build_object('customerId', 'cust-t29-a', 'deliveryNotes', 'TEST-29 o3', 'items', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1)))::text)); o3 := a ->> 'val';
  a := pg_temp.t28_try('u-stg-manager', format('public.create_order(%L::jsonb)', jsonb_build_object('customerId', 'cust-t29-a', 'deliveryNotes', 'TEST-29 o4', 'items', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1)))::text)); o4 := a ->> 'val';
  a := pg_temp.t28_try('u-stg-manager', format('public.create_order(%L::jsonb)', jsonb_build_object('customerId', 'cust-t29-b', 'deliveryNotes', 'TEST-29 other customer', 'items', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 1)))::text)); o5 := a ->> 'val';
  res := pg_temp.t28_j(res, 'fixtures: five orders created', o1 is not null and o2 is not null and o3 is not null and o4 is not null and o5 is not null, concat_ws(',', o1, o2, o3, o4, o5));

  -- T1 a Manager cannot jump pending -> dispatched, nor confirmed -> dispatched
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''dispatched'', '''')', o1));
  res := pg_temp.t28_j(res, 'T1 pending -> dispatched is refused for a Manager', not (a ->> 'ok')::boolean and (a ->> 'msg') like 'Illegal status transition%', coalesce(a ->> 'msg', 'allowed?'));
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''confirmed'', '''')', o1));
  res := pg_temp.t28_j(res, 'T1b pending -> confirmed is allowed', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', 'ok'));
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''dispatched'', '''')', o1));
  res := pg_temp.t28_j(res, 'T1c confirmed -> dispatched is refused (it must be prepared first)', not (a ->> 'ok')::boolean, coalesce(a ->> 'msg', 'allowed?'));

  -- T2 processing -> dispatched, with the real timestamp, the actor and the audit line
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''processing'', '''')', o1));
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''dispatched'', %L)', o1, 'Driver Ali, van 3'));
  select status::text as st, dispatched_at, dispatched_by into x from public.orders where id = o1;
  res := pg_temp.t28_j(res, 'T2 processing -> dispatched sets status, dispatched_at (now) and dispatched_by', (a ->> 'ok')::boolean and x.st = 'dispatched' and x.dispatched_at is not null and abs(extract(epoch from now() - x.dispatched_at)) < 60 and x.dispatched_by = 'u-stg-manager', to_jsonb(x)::text || coalesce(a ->> 'msg', ''));
  select count(*) into n from public.system_logs where target_id = o1 and message like '%processing to dispatched%' and metadata ->> 'reason' = 'Driver Ali, van 3' and user_id = 'u-stg-manager';
  res := pg_temp.t28_j(res, 'T2b the audit line records who, from -> to and the dispatch details', n = 1, n::text);

  -- T3 no way back for a Manager; dispatched_at cannot be written directly
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''processing'', '''')', o1));
  res := pg_temp.t28_j(res, 'T3 dispatched -> processing is refused for a Manager', not (a ->> 'ok')::boolean and (a ->> 'msg') like 'Illegal status transition%', coalesce(a ->> 'msg', 'allowed?'));
  a := pg_temp.t28_try('u-stg-manager', format('pg_temp.t29_write(%L)', o1));
  res := pg_temp.t28_j(res, 'T3b dispatched_at cannot be written directly by a client', not (a ->> 'ok')::boolean, coalesce(a ->> 'msg', 'allowed?'));

  -- T4 a partial delivery from dispatched keeps the dispatch time; the rest delivers; the dispatch time survives
  select jsonb_agg(jsonb_build_object('orderItemId', id, 'quantity', 1)) into lines from public.order_items where order_id = o1;
  a := pg_temp.t28_try('u-stg-manager', format('public.record_delivery(%L, %L::jsonb, ''TEST-29'', null)', o1, lines::text));
  select status::text as st, dispatched_at into x from public.orders where id = o1;
  res := pg_temp.t28_j(res, 'T4 a partial delivery from dispatched -> partially_delivered, dispatch time kept', (a ->> 'ok')::boolean and x.st = 'partially_delivered' and x.dispatched_at is not null, to_jsonb(x)::text || coalesce(a ->> 'msg', ''));
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''dispatched'', '''')', o1));
  res := pg_temp.t28_j(res, 'T4b partially_delivered -> dispatched is refused', not (a ->> 'ok')::boolean, coalesce(a ->> 'msg', 'allowed?'));
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''delivered'', '''')', o1));
  select status::text as st, dispatched_at, delivered_at into x from public.orders where id = o1;
  res := pg_temp.t28_j(res, 'T4c the rest delivers: delivered, delivered_at set, dispatched_at kept and not after it', (a ->> 'ok')::boolean and x.st = 'delivered' and x.delivered_at is not null and x.dispatched_at is not null and x.dispatched_at <= x.delivered_at, to_jsonb(x)::text || coalesce(a ->> 'msg', ''));
  select count(*) into n from public.commissions where order_id = o1;
  res := pg_temp.t28_j(res, 'T4d delivery commission is still created for an order that was dispatched', n >= 1, n::text);

  -- T5 dispatch is enforced: a prepared (processing) order cannot be delivered by any ordinary path
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''confirmed'', '''')', o2));
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''processing'', '''')', o2));
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''delivered'', '''')', o2));
  select status::text as st, dispatched_at, delivered_at into x from public.orders where id = o2;
  res := pg_temp.t28_j(res, 'T5 processing -> delivered is REFUSED for a Manager, with the dispatch message', not (a ->> 'ok')::boolean and (a ->> 'msg') like '%record it as dispatched before it can be delivered%' and x.st = 'processing' and x.delivered_at is null, coalesce(a ->> 'msg', 'allowed?'));
  select jsonb_agg(jsonb_build_object('orderItemId', id, 'quantity', 1)) into lines from public.order_items where order_id = o2;
  a := pg_temp.t28_try('u-stg-manager', format('public.record_delivery(%L, %L::jsonb, ''TEST-29'', null)', o2, lines::text));
  select status::text as st, delivered_at into x from public.orders where id = o2;
  res := pg_temp.t28_j(res, 'T5b record_delivery on a processing order is REFUSED too (the second bypass), nothing is recorded', not (a ->> 'ok')::boolean and (a ->> 'msg') like '%record it as dispatched before recording deliveries%' and x.st = 'processing' and not exists (select 1 from public.order_deliveries d where d.order_id = o2), coalesce(a ->> 'msg', 'allowed?'));
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''delivered'', %L)', o2, 'trying with a reason'));
  res := pg_temp.t28_j(res, 'T5c a Manager cannot bypass it even by giving a reason', not (a ->> 'ok')::boolean, coalesce(a ->> 'msg', 'allowed?'));
  a := pg_temp.t28_try('u-stg-admin', format('public.update_order_status(%L, ''delivered'', '''')', o2));
  res := pg_temp.t28_j(res, 'T5d a Super Admin override to delivered needs a written reason', not (a ->> 'ok')::boolean and (a ->> 'msg') like 'A reason is required%', coalesce(a ->> 'msg', 'allowed?'));
  a := pg_temp.t28_try('u-stg-admin', format('public.update_order_status(%L, ''delivered'', %L)', o2, 'Delivered by hand before dispatch was recorded; owner approved'));
  select status::text as st, dispatched_at, delivered_at into x from public.orders where id = o2;
  res := pg_temp.t28_j(res, 'T5e ...with a reason the override works, delivered_at is set and dispatched_at stays null (never invented)', (a ->> 'ok')::boolean and x.st = 'delivered' and x.delivered_at is not null and x.dispatched_at is null, to_jsonb(x)::text || coalesce(a ->> 'msg', ''));
  select count(*) into n from public.system_logs where target_id = o2 and severity::text = 'WARNING' and message like '%processing to delivered (Super Admin override)%' and metadata ->> 'reason' like 'Delivered by hand%' and metadata ->> 'override' = 'true';
  res := pg_temp.t28_j(res, 'T5f the override is audited at WARNING level with its reason', n = 1, n::text);

  -- T5g the full normal path, including finishing a partial delivery with record_delivery
  a := pg_temp.t28_try('u-stg-manager', format('public.create_order(%L::jsonb)', jsonb_build_object('customerId', 'cust-t29-a', 'deliveryNotes', 'TEST-29 o6', 'items', jsonb_build_array(jsonb_build_object('productId', 'prod-stg-nexus', 'quantity', 2)))::text)); o6 := a ->> 'val';
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''confirmed'', '''')', o6));
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''processing'', '''')', o6));
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''dispatched'', '''')', o6));
  select jsonb_agg(jsonb_build_object('orderItemId', id, 'quantity', 1)) into lines from public.order_items where order_id = o6;
  a := pg_temp.t28_try('u-stg-manager', format('public.record_delivery(%L, %L::jsonb, ''TEST-29'', null)', o6, lines::text));
  a := pg_temp.t28_try('u-stg-manager', format('public.record_delivery(%L, %L::jsonb, ''TEST-29'', null)', o6, lines::text));
  select status::text as st, dispatched_at, delivered_at into x from public.orders where id = o6;
  res := pg_temp.t28_j(res, 'T5g pending -> confirmed -> processing -> dispatched -> (partial) -> delivered through record_delivery works end to end', (a ->> 'ok')::boolean and x.st = 'delivered' and x.dispatched_at is not null and x.delivered_at is not null, to_jsonb(x)::text || coalesce(a ->> 'msg', ''));

  -- T6 cancelled orders: cancel from dispatched; a cancelled order can never be dispatched
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''confirmed'', '''')', o3));
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''processing'', '''')', o3));
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''dispatched'', '''')', o3));
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''cancelled'', %L)', o3, 'Customer refused at the door'));
  select status::text as st, dispatched_at into x from public.orders where id = o3;
  res := pg_temp.t28_j(res, 'T6 dispatched -> cancelled works (the dispatch time is kept as history)', (a ->> 'ok')::boolean and x.st = 'cancelled' and x.dispatched_at is not null, to_jsonb(x)::text || coalesce(a ->> 'msg', ''));
  a := pg_temp.t28_try('u-stg-manager', format('public.update_order_status(%L, ''dispatched'', '''')', o3));
  res := pg_temp.t28_j(res, 'T6b a cancelled order cannot be dispatched by a Manager', not (a ->> 'ok')::boolean, coalesce(a ->> 'msg', 'allowed?'));

  -- T7 Super Admin override: needs a reason; moving back before dispatch clears dispatched_at
  a := pg_temp.t28_try('u-stg-admin', format('public.update_order_status(%L, ''dispatched'', '''')', o4));
  res := pg_temp.t28_j(res, 'T7 a Super Admin override pending -> dispatched needs a reason', not (a ->> 'ok')::boolean and (a ->> 'msg') like 'A reason is required%', coalesce(a ->> 'msg', 'allowed?'));
  a := pg_temp.t28_try('u-stg-admin', format('public.update_order_status(%L, ''dispatched'', %L)', o4, 'Collected in person, recorded late'));
  select status::text as st, dispatched_at into x from public.orders where id = o4;
  res := pg_temp.t28_j(res, 'T7b with a reason the override works and stamps dispatched_at', (a ->> 'ok')::boolean and x.st = 'dispatched' and x.dispatched_at is not null, to_jsonb(x)::text || coalesce(a ->> 'msg', ''));
  a := pg_temp.t28_try('u-stg-admin', format('public.update_order_status(%L, ''processing'', %L)', o4, 'Dispatched by mistake'));
  select status::text as st, dispatched_at, dispatched_by into x from public.orders where id = o4;
  res := pg_temp.t28_j(res, 'T7c an override back to processing clears the dispatch time (the audit log keeps the history)', (a ->> 'ok')::boolean and x.st = 'processing' and x.dispatched_at is null and x.dispatched_by is null, to_jsonb(x)::text || coalesce(a ->> 'msg', ''));
  a := pg_temp.t28_try('u-stg-admin', format('public.update_order_status(%L, ''dispatched'', '''')', o4));
  res := pg_temp.t28_j(res, 'T7d processing -> dispatched needs no reason again', (a ->> 'ok')::boolean, coalesce(a ->> 'msg', 'ok'));

  -- T8 the customer's own data path
  a := pg_temp.t28_try('u-stg-cs', 'public.my_orders()');
  res := pg_temp.t28_j(res, 'T9 my_orders returns only this customer''s 5 orders, dispatchedAt set on the dispatched one, null on the delivered-without-dispatch one, cancelled shown as cancelled',
    (a ->> 'ok')::boolean
    and jsonb_array_length((a ->> 'val')::jsonb) = 5
    and not exists (select 1 from jsonb_array_elements((a ->> 'val')::jsonb) e where e ->> 'id' = o5)
    and (select (e ->> 'dispatchedAt') is not null from jsonb_array_elements((a ->> 'val')::jsonb) e where e ->> 'id' = o4)
    and (select (e ->> 'dispatchedAt') is null from jsonb_array_elements((a ->> 'val')::jsonb) e where e ->> 'id' = o2)
    and (select e ->> 'status' = 'cancelled' from jsonb_array_elements((a ->> 'val')::jsonb) e where e ->> 'id' = o3),
    coalesce(left(a ->> 'val', 300), a ->> 'msg'));

  -- T10 live updates: private broadcasts exist for the owner, carry no money, and only the owner can read them
  select count(*) into n from realtime.messages where topic = 'customer-orders:' || cs_auth::text and event = 'order_changed';
  res := pg_temp.t28_j(res, 'T10 status changes produced Realtime messages on the customer''s own topic', n >= 8, n::text);
  select payload::text into pl from realtime.messages where topic = 'customer-orders:' || cs_auth::text order by inserted_at desc limit 1;
  res := pg_temp.t28_j(res, 'T10b a message carries only orderId, status and timestamps (no totals, cost, profit or price)', pl ~ 'orderId' and pl !~ '(total|cost|profit|amount|price)', coalesce(pl, 'none'));
  select count(*) into n from realtime.messages where topic = 'customer-orders:' || b_auth::text;
  res := pg_temp.t28_j(res, 'T10c messages also exist for the other customer''s topic (so the next checks prove isolation)', n >= 1, n::text);
  a := pg_temp.t28_try('u-stg-cs', format('pg_temp.t29_visible(%L)', 'customer-orders:' || cs_auth::text));
  res := pg_temp.t28_j(res, 'T10d the customer can receive their own topic', (a ->> 'ok')::boolean and (a ->> 'val')::bigint >= 8, coalesce(a ->> 'val', a ->> 'msg'));
  a := pg_temp.t28_try('u-stg-cs', format('pg_temp.t29_visible(%L)', 'customer-orders:' || b_auth::text));
  res := pg_temp.t28_j(res, 'T10e ...but not another customer''s topic', (a ->> 'ok')::boolean and (a ->> 'val')::bigint = 0, coalesce(a ->> 'val', a ->> 'msg'));
  a := pg_temp.t28_try('u-stg-delivery', format('pg_temp.t29_visible(%L)', 'customer-orders:' || cs_auth::text));
  res := pg_temp.t28_j(res, 'T10f a signed-in user without an approved customer account receives nothing', (a ->> 'ok')::boolean and (a ->> 'val')::bigint = 0, coalesce(a ->> 'val', a ->> 'msg'));
  a := pg_temp.t28_try(null, format('pg_temp.t29_visible(%L)', 'customer-orders:' || cs_auth::text));
  res := pg_temp.t28_j(res, 'T10g an anonymous visitor receives nothing', (not (a ->> 'ok')::boolean) or (a ->> 'val')::bigint = 0, coalesce(a ->> 'val', a ->> 'msg'));
  select count(*) into n from pg_trigger where tgname in ('trg_orders_notify_customer_ins', 'trg_orders_notify_customer_upd') and not tgisinternal;
  res := pg_temp.t28_j(res, 'T11 both notify triggers exist', n = 2, n::text);

  raise exception 'T28RESULT:%', res::text;
end
$t$;
