-- REHEARSAL (rolled back): the normal Manager cancellation of the Migration 28 concurrency-test order. Nothing is committed: the batch ends with an exception.
create function pg_temp.r_snap() returns jsonb language plpgsql as $f$
declare s jsonb; sales jsonb; daily jsonb; ids jsonb;
begin
  select jsonb_build_object(
    'order', (select jsonb_build_object('status', status::text, 'cancelled_at_set', cancelled_at is not null, 'total', total, 'amount_paid', amount_paid, 'payment_status', payment_status::text, 'stock_mode', stock_mode) from public.orders where id = 'ORD-4877625'),
    'order_log_rows', (select count(*) from public.system_logs where target_id = 'ORD-4877625'),
    'request_log_rows', (select count(*) from public.system_logs where target_id = 'ebba9830-923b-4659-8ce7-07cff8d267a6'),
    'entitlement_rows', (select count(*) from public.customer_bonus_entitlements where customer_id = 'cust-t28-conc'),
    'entitlement', (select to_jsonb(e) - 'updated_at' - 'determined_at' from public.customer_bonus_entitlements e where e.customer_id = 'cust-t28-conc'),
    'bonus_events', (select count(*) from public.commission_bonus_events where customer_id = 'cust-t28-conc'),
    'commissions_for_order', (select count(*) from public.commissions where order_id = 'ORD-4877625'),
    'payments_for_order', (select count(*) from public.payments where order_id = 'ORD-4877625'),
    'stock_movements_nexus', (select count(*) from public.stock_movements where product_id = 'prod-stg-nexus'),
    'nexus_stock', (select stock from public.products where id = 'prod-stg-nexus'),
    'nexus_committed', public.product_committed_quantity('prod-stg-nexus'),
    'items_hash', (select md5(coalesce(string_agg(i::text, '|' order by i.id), '')) from public.order_items i where i.order_id = 'ORD-4877625'),
    'resolutions_hash', (select md5(coalesce(string_agg(v::text, '|' order by v.order_item_id), '')) from public.order_price_resolutions v where v.order_id = 'ORD-4877625'),
    'request_hash', (select md5(r::text) from public.order_requests r where r.id = 'ebba9830-923b-4659-8ce7-07cff8d267a6'),
    'request_events', (select count(*) from public.order_request_events where request_id = 'ebba9830-923b-4659-8ce7-07cff8d267a6'),
    'customer_hash', (select md5(c::text) from public.customers c where c.id = 'cust-t28-conc'),
    'all_pending_orders', (select count(*) from public.orders where status = 'pending'),
    'all_cancelled_orders', (select count(*) from public.orders where status = 'cancelled')
  ) into s;
  -- the reporting views are gated by the caller's rights, so they are read AS the Manager
  sales := pg_temp.t28_sales('prod-stg-nexus');
  daily := (pg_temp.t28_try('u-stg-manager', '(select to_jsonb(d) from public.daily_sales d where d.order_date = date ''2026-10-19'')') ->> 'val')::jsonb;
  select coalesce(jsonb_agg(id order by id), '[]'::jsonb) into ids from public.system_logs where target_id = 'ORD-4877625';
  return s || jsonb_build_object('sales_nexus', sales - 'name' - 'category' - 'id', 'daily_sales_2026_10_19', daily, 'order_log_ids', ids);
end $f$;

select pg_temp.t28_guard();
do $t$
declare
  b jsonb; a jsonb; c jsonb; newev jsonb; total jsonb := '[]'::jsonb; k text; newlog record; ent jsonb;
  unchanged text[] := array['payments_for_order','commissions_for_order','stock_movements_nexus','nexus_stock','items_hash','resolutions_hash','request_hash','request_events','customer_hash','request_log_rows','bonus_events','all_pending_orders_minus_one'];
begin
  if not exists (select 1 from public.orders where id = 'ORD-4877625' and customer_id = 'cust-t28-conc' and status = 'pending') then
    raise exception 'REHEARSAL REFUSED: ORD-4877625 is not the pending test order of cust-t28-conc';
  end if;
  b := pg_temp.r_snap();
  c := pg_temp.t28_try('u-stg-manager', $q$public.update_order_status('ORD-4877625', 'cancelled', 'TEST-28 concurrency test order: synthetic, cancelled after the Migration 28 integration run')$q$);
  total := pg_temp.t28_j(total, 'R1 the Manager (permission edit_orders) can cancel the pending order through the normal workflow', (c ->> 'ok')::boolean, c::text);
  a := pg_temp.r_snap();

  total := pg_temp.t28_j(total, 'R2 status transition pending -> cancelled and cancelled_at is set', b -> 'order' ->> 'status' = 'pending' and a -> 'order' ->> 'status' = 'cancelled' and (a -> 'order' ->> 'cancelled_at_set')::boolean and not (b -> 'order' ->> 'cancelled_at_set')::boolean, (b -> 'order')::text || ' -> ' || (a -> 'order')::text);
  total := pg_temp.t28_j(total, 'R3 total, payment fields and stock_mode of the order are untouched', b -> 'order' ->> 'total' = a -> 'order' ->> 'total' and b -> 'order' ->> 'amount_paid' = a -> 'order' ->> 'amount_paid' and b -> 'order' ->> 'payment_status' = a -> 'order' ->> 'payment_status' and b -> 'order' ->> 'stock_mode' = a -> 'order' ->> 'stock_mode', '');

  -- inventory reservation
  total := pg_temp.t28_j(total, 'R4 inventory: Nexus units promised to open orders drop by 1 (reservation released)', (b ->> 'nexus_committed')::int - (a ->> 'nexus_committed')::int = 1, (b ->> 'nexus_committed') || ' -> ' || (a ->> 'nexus_committed'));
  total := pg_temp.t28_j(total, 'R5 inventory: Nexus stock itself is unchanged and no stock movement is written', b ->> 'nexus_stock' = a ->> 'nexus_stock' and b ->> 'stock_movements_nexus' = a ->> 'stock_movements_nexus', 'stock ' || (b ->> 'nexus_stock') || ' -> ' || (a ->> 'nexus_stock') || '; movements ' || (b ->> 'stock_movements_nexus') || ' -> ' || (a ->> 'stock_movements_nexus'));

  -- sales reporting
  total := pg_temp.t28_j(total, 'R6 product_sales (Nexus): -1 unit, -12.00 revenue, -6.70 cost, -1 order',
    (b -> 'sales_nexus' ->> 'units_sold')::numeric - (a -> 'sales_nexus' ->> 'units_sold')::numeric = 1 and (b -> 'sales_nexus' ->> 'revenue')::numeric - (a -> 'sales_nexus' ->> 'revenue')::numeric = 12
    and (b -> 'sales_nexus' ->> 'cost')::numeric - (a -> 'sales_nexus' ->> 'cost')::numeric = 6.70 and (b -> 'sales_nexus' ->> 'order_count')::int - (a -> 'sales_nexus' ->> 'order_count')::int = 1,
    (b -> 'sales_nexus')::text || ' -> ' || (a -> 'sales_nexus')::text);
  total := pg_temp.t28_j(total, 'R7 daily_sales 2026-10-19: the test order was the ONLY active order of that day (1 order, 12.00, 1 unit), so after cancelling the day has no row (0 orders, 0.00, 0 units)',
    (b -> 'daily_sales_2026_10_19' ->> 'order_count')::int = 1 and (b -> 'daily_sales_2026_10_19' ->> 'revenue')::numeric = 12 and (b -> 'daily_sales_2026_10_19' ->> 'units_sold')::numeric = 1 and (a -> 'daily_sales_2026_10_19') = 'null'::jsonb,
    coalesce((b -> 'daily_sales_2026_10_19')::text, 'null') || ' -> ' || (a -> 'daily_sales_2026_10_19')::text);
  total := pg_temp.t28_j(total, 'R8 order counts: one fewer pending, one more cancelled', (b ->> 'all_pending_orders')::int - (a ->> 'all_pending_orders')::int = 1 and (a ->> 'all_cancelled_orders')::int - (b ->> 'all_cancelled_orders')::int = 1, 'pending ' || (b ->> 'all_pending_orders') || ' -> ' || (a ->> 'all_pending_orders') || '; cancelled ' || (b ->> 'all_cancelled_orders') || ' -> ' || (a ->> 'all_cancelled_orders'));

  -- audit
  select l.severity::text sev, l.category::text cat, l.message, l.user_id uid, l.target_id tid, l.metadata into newlog from public.system_logs l where l.target_id = 'ORD-4877625' and not (b -> 'order_log_ids') ? l.id;
  total := pg_temp.t28_j(total, 'R9 audit: exactly one new log row, INFO / ORDER, by the Manager, naming the transition and carrying the reason',
    (a ->> 'order_log_rows')::int - (b ->> 'order_log_rows')::int = 1 and newlog.sev = 'INFO' and newlog.cat = 'ORDER' and newlog.uid = 'u-stg-manager' and newlog.message = 'Order ORD-4877625 status changed from pending to cancelled'
    and newlog.metadata ->> 'reason' like 'TEST-28 concurrency test order%' and newlog.metadata ->> 'from' = 'pending' and newlog.metadata ->> 'to' = 'cancelled', to_jsonb(newlog)::text);

  -- bonus entitlement
  ent := a -> 'entitlement';
  total := pg_temp.t28_j(total, 'R10 bonus entitlement: ONE new row for the test customer, decided as not_eligible (a 1-ball, never-confirmed order): no holder order, no commission, nothing awarded',
    (b ->> 'entitlement_rows')::int = 0 and (a ->> 'entitlement_rows')::int = 1 and ent ->> 'status' = 'not_eligible' and ent ->> 'holder_order_id' is null and ent ->> 'holder_commission_id' is null and ent ->> 'deciding_order_id' = 'ORD-4877625',
    'rows ' || (b ->> 'entitlement_rows') || ' -> ' || (a ->> 'entitlement_rows') || ' ' || ent::text);
  select to_jsonb(ev) - 'id' into newev from public.commission_bonus_events ev where ev.customer_id = 'cust-t28-conc' limit 1;
  total := pg_temp.t28_j(total, 'R11 exactly one bonus event (a "determined" record, no money) is written; no commission and no payment is created',
    (b ->> 'bonus_events')::int = 0 and (a ->> 'bonus_events')::int = 1 and b ->> 'commissions_for_order' = a ->> 'commissions_for_order' and b ->> 'payments_for_order' = a ->> 'payments_for_order',
    'bonus_events ' || (b ->> 'bonus_events') || ' -> ' || (a ->> 'bonus_events') || ' event=' || coalesce(newev::text, 'none'));

  -- history preserved
  total := pg_temp.t28_j(total, 'R12 the order line, its price-resolution row, the converted request (with its events and log) and the customer are byte-for-byte unchanged',
    b ->> 'items_hash' = a ->> 'items_hash' and b ->> 'resolutions_hash' = a ->> 'resolutions_hash' and b ->> 'request_hash' = a ->> 'request_hash' and b ->> 'request_events' = a ->> 'request_events' and b ->> 'customer_hash' = a ->> 'customer_hash' and b ->> 'request_log_rows' = a ->> 'request_log_rows', '');

  -- a second cancel is a no-op (idempotent), and a cancelled order cannot be silently reactivated by a Manager
  c := pg_temp.t28_try('u-stg-manager', $q$public.update_order_status('ORD-4877625', 'cancelled', 'again')$q$);
  total := pg_temp.t28_j(total, 'R13 cancelling again is a harmless no-op', (c ->> 'ok')::boolean and (pg_temp.r_snap() ->> 'order_log_rows') = (a ->> 'order_log_rows'), c::text);
  c := pg_temp.t28_try('u-stg-manager', $q$public.update_order_status('ORD-4877625', 'pending', 'undo')$q$);
  total := pg_temp.t28_j(total, 'R14 a Manager cannot reactivate the cancelled order (illegal transition; Super Admin override only)', not (c ->> 'ok')::boolean and c ->> 'msg' ilike '%Illegal status transition%', c::text);

  raise exception 'T28RESULT:%', total::text;
end
$t$;
