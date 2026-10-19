
-- append a result entry to a jsonb array (used by tests that isolate each case in its own nested block, so one case's stock use cannot affect another)
create function pg_temp.t28_j(res jsonb, p_id text, p_ok boolean, p_detail text) returns jsonb language sql as $f$
  select res || jsonb_build_array(jsonb_build_object('id', p_id, 'ok', p_ok, 'detail', left(coalesce(p_detail, ''), 420)));
$f$;

-- a request submitted through the public form and left NEW (not confirmed). Returns the request id.
create function pg_temp.t28_submit(p_phone text, p_lines jsonb) returns uuid language plpgsql as $f$
declare a jsonb;
begin
  a := pg_temp.t28_try(null, format('public.submit_order_request(%L::jsonb)', jsonb_build_object('customerName', 'TEST-28 Visitor', 'phone', p_phone, 'organization', 'TEST-28', 'deliveryLocation', 'TEST-28 Hodan', 'notes', 'TEST-28', 'lines', p_lines, 'submissionKey', gen_random_uuid())::text));
  if not (a ->> 'ok')::boolean then raise exception 'fixture: submit_order_request failed: %', a ->> 'msg'; end if;
  return (a ->> 'val')::uuid;
end $f$;

-- product_sales is gated by the caller's rights (can_see_products / can_see_customer_order), so it is read AS the Manager
create function pg_temp.t28_sales(p_id text) returns jsonb language plpgsql as $f$
declare a jsonb;
begin
  a := pg_temp.t28_try('u-stg-manager', format('(select to_jsonb(ps) from public.product_sales ps where ps.id = %L)', p_id));
  return (a ->> 'val')::jsonb;
end $f$;
