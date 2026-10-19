-- Migration 28 integration tests - shared helpers. STAGING ONLY. Every test file is ONE statement batch that ends by raising 'T28RESULT:<json>', so the whole
-- transaction (fixtures, requests, orders, agreements) is rolled back; nothing persists. Helpers live in pg_temp (this session only).
create temp table t28r (n serial, id text, ok boolean, detail text);

-- act as a staff member (profile id), as an anonymous visitor (null), or back as the owner role
create function pg_temp.t28_try(p_profile text, p_sql text) returns jsonb language plpgsql as $f$
declare v uuid; r text;
begin
  if p_profile is not null then
    select auth_user_id into v from public.profiles where id = p_profile;
    if v is null then return jsonb_build_object('ok', false, 'state', 'T28', 'msg', 'no auth user for ' || p_profile); end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
  else
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
    execute 'set local role anon';
  end if;
  begin
    execute 'select (' || p_sql || ')::text' into r;
    execute 'reset role'; perform set_config('request.jwt.claims', '', true);
    return jsonb_build_object('ok', true, 'val', r);
  exception when others then
    execute 'reset role'; perform set_config('request.jwt.claims', '', true);
    return jsonb_build_object('ok', false, 'state', sqlstate, 'msg', sqlerrm);
  end;
end $f$;

create function pg_temp.t28_rec(p_id text, p_ok boolean, p_detail text) returns void language sql as $f$
  insert into t28r (id, ok, detail) values (p_id, p_ok, p_detail);
$f$;

-- a synthetic customer owned by officer1
create function pg_temp.t28_cust(p_id text, p_name text, p_phone text) returns void language sql as $f$
  insert into public.customers (id, name, email, phone, notes, marketing_officer_id, registered_by, status)
  values (p_id, 'TEST-28 ' || p_name, '', p_phone, 'TEST-28 synthetic', 'u-stg-officer1', 'u-stg-admin', 'active');
$f$;

-- a CONFIRMED website request made the real way: the public form (anon) then a Manager confirms it. Returns the request id.
create function pg_temp.t28_req(p_phone text, p_lines jsonb) returns uuid language plpgsql as $f$
declare a jsonb; id uuid; c jsonb;
begin
  a := pg_temp.t28_try(null, format('public.submit_order_request(%L::jsonb)', jsonb_build_object('customerName', 'TEST-28 Visitor', 'phone', p_phone, 'organization', 'TEST-28', 'deliveryLocation', 'TEST-28 Hodan', 'notes', 'TEST-28', 'lines', p_lines, 'submissionKey', gen_random_uuid())::text));
  if not (a ->> 'ok')::boolean then raise exception 'fixture: submit_order_request failed: %', a ->> 'msg'; end if;
  id := (a ->> 'val')::uuid;
  c := pg_temp.t28_try('u-stg-manager', format('public.set_order_request_status(%L::uuid, ''confirmed'', null)', id));
  if not (c ->> 'ok')::boolean then raise exception 'fixture: confirm failed: %', c ->> 'msg'; end if;
  return id;
end $f$;

-- an agreement recorded by a Manager / Super Admin through the real RPC. Returns the agreement id.
create function pg_temp.t28_agree(p_by text, p_customer text, p_product text, p_design uuid, p_price numeric, p_below_reason text default null) returns uuid language plpgsql as $f$
declare a jsonb;
begin
  a := pg_temp.t28_try(p_by, format('public.create_price_agreement(%L, %L, %L::uuid, %s, public.efz_today(), null, %L, %L)', p_customer, p_product, p_design, p_price, 'TEST-28 authorised by the owner', p_below_reason));
  if not (a ->> 'ok')::boolean then raise exception 'fixture: create_price_agreement failed: %', a ->> 'msg'; end if;
  return (a ->> 'val')::uuid;
end $f$;

-- convert as a given staff member; p_payload is the converter payload (jsonb text)
create function pg_temp.t28_convert(p_by text, p_req uuid, p_payload jsonb) returns jsonb language sql as $f$
  select pg_temp.t28_try(p_by, format('public.convert_website_request(%L::uuid, %L::jsonb)', p_req, p_payload::text));
$f$;

create function pg_temp.t28_guard() returns void language plpgsql as $f$
begin
  if not exists (select 1 from public.profiles where id = 'u-stg-admin') or not exists (select 1 from public.profiles where id = 'u-stg-manager') then
    raise exception 'NOT STAGING: the synthetic Staging staff were not found - refusing to run';
  end if;
end $f$;

create function pg_temp.t28_out() returns text language sql as $f$
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'ok', t.ok, 'detail', left(t.detail, 420)) order by t.n), '[]'::jsonb)::text from t28r t;
$f$;
