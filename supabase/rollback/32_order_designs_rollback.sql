-- =============================================================================
-- ROLLBACK of 32_order_designs.sql
-- Restores the migration-18b submit_order_request (which ignores designs and refuses a repeated product) and removes everything 32 added:
-- public_product_designs(), the two product_designs triggers and their functions.
-- NOT touched: product_designs rows (designs stay in the catalog), customer_order_request_lines rows already written for website requests (the design a
-- visitor chose stays on that request), orders, stock, payments. After this, the order form falls back to "no designs" by itself.
-- Refuses unless 32 is applied. One transaction.
-- =============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
begin
  if to_regprocedure('public.submit_order_request(jsonb)') is null
     or position('designId' in pg_get_functiondef('public.submit_order_request(jsonb)'::regprocedure)) = 0 then
    raise exception '32 rollback: migration 32 is not applied - nothing to roll back';
  end if;
end
$pre$;

drop trigger if exists trg_product_designs_audit on public.product_designs;
drop trigger if exists trg_product_designs_guard on public.product_designs;
drop function if exists public.log_product_design_changes();
drop function if exists public.guard_product_design();
drop function if exists public.public_product_designs();

create or replace function public.submit_order_request(p_payload jsonb)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_name     text := btrim(coalesce(p_payload ->> 'customerName', ''));
  v_phone    text := btrim(coalesce(p_payload ->> 'phone', ''));
  v_org      text := btrim(coalesce(p_payload ->> 'organization', ''));
  v_location text := btrim(coalesce(p_payload ->> 'deliveryLocation', ''));
  v_notes    text := btrim(coalesce(p_payload ->> 'notes', ''));
  v_lines    jsonb := p_payload -> 'lines';
  v_key      uuid;
  v_canon    text;
  v_existing uuid;
  v_id       uuid := gen_random_uuid();
  v_line     jsonb;
  v_seq      integer := 0;
  v_units    integer := 0;
  v_qty_raw  numeric;
  v_product  public.products%rowtype;
  v_seen     text[] := '{}';
  v_names    text[] := '{}';
  v_qtys     integer[] := '{}';
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'Invalid request' using errcode = '22023';
  end if;
  if char_length(v_name) not between 1 and 200 then
    raise exception 'Please enter your name (up to 200 characters)' using errcode = '22023';
  end if;
  if char_length(v_phone) not between 1 and 50 then
    raise exception 'Please enter a valid Somali phone number, e.g. 061 234 5678' using errcode = 'WR422';
  end if;
  if char_length(v_org) > 200 or char_length(v_location) > 500 or char_length(v_notes) > 2000 then
    raise exception 'A field is too long' using errcode = '22023';
  end if;
  if jsonb_typeof(v_lines) is distinct from 'array' or jsonb_array_length(v_lines) not between 1 and 20 then
    raise exception 'A request needs between 1 and 20 products' using errcode = '22023';
  end if;
  begin
    v_key := nullif(p_payload ->> 'submissionKey', '')::uuid;
  exception when invalid_text_representation then
    raise exception 'Invalid submission key' using errcode = '22023';
  end;

  v_canon := public.validate_request_phone(v_phone);
  v_existing := public.website_request_admission(v_canon, v_key);
  if v_existing is not null then
    return v_existing;   -- the same form submitted again: nothing new is written
  end if;

  -- Validate every line before anything is written.
  for v_line in select * from jsonb_array_elements(v_lines)
  loop
    select * into v_product from public.products p
     where p.id = v_line ->> 'productId' and p.is_active;
    if not found then
      raise exception 'A selected product is not available' using errcode = '22023';
    end if;
    if v_product.id = any (v_seen) then
      raise exception 'Each product can be listed once; change its quantity instead' using errcode = '22023';
    end if;
    begin
      v_qty_raw := (v_line ->> 'quantity')::numeric;
    exception when invalid_text_representation then
      v_qty_raw := null;
    end;
    if v_qty_raw is null or v_qty_raw <> trunc(v_qty_raw) or v_qty_raw not between 1 and 100000 then
      raise exception 'Quantity must be a whole number between 1 and 100000' using errcode = '22023';
    end if;
    v_seen  := v_seen || v_product.id;
    v_names := v_names || v_product.name;
    v_qtys  := v_qtys || v_qty_raw::integer;
    v_units := v_units + v_qty_raw::integer;
  end loop;

  -- Marks THIS insert for the temporary legacy-path trigger, and only this one:
  -- cleared straight after, so no later direct insert in the same transaction
  -- can pass as an RPC insert.
  perform set_config('efz.website_request_rpc', 'on', true);

  -- The header mirrors line 1 in the legacy columns, for old exports and readers.
  insert into public.order_requests (id, customer_name, phone, organization, product_id, product_name, quantity,
                                     delivery_location, notes, status, submission_key, phone_canonical)
  values (v_id, v_name, v_phone, v_org, v_seen[1], v_names[1], v_qtys[1], v_location, v_notes, 'new', v_key, v_canon);

  perform set_config('efz.website_request_rpc', '', true);

  for v_seq in 1 .. cardinality(v_seen)
  loop
    insert into public.order_request_items (request_id, line_no, product_id, product_name, quantity)
    values (v_id, v_seq, v_seen[v_seq], v_names[v_seq], v_qtys[v_seq]);
  end loop;
  v_seq := cardinality(v_seen);

  insert into public.order_request_events (request_id, event, source, to_status, actor_id, actor_name, details)
  values (v_id, 'submitted', 'rpc', 'new', public.current_profile_id(), coalesce(public.current_profile_name(), ''),
          jsonb_build_object('lines', v_seq, 'units', v_units));

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'ORDER',
          format('Website request REQ-%s received: %s item(s), %s unit(s)',
                 upper(left(replace(v_id::text, '-', ''), 8)), v_seq, v_units),
          public.current_profile_id(), coalesce(public.current_profile_name(), ''), v_id::text,
          jsonb_build_object('source', 'db', 'event', 'website_request_submitted', 'requestId', v_id,
                             'path', 'rpc', 'lines', v_seq, 'units', v_units));
  return v_id;
end;
$fn$;

revoke all on function public.submit_order_request(jsonb) from public, anon, authenticated;
grant execute on function public.submit_order_request(jsonb) to anon, authenticated;

do $post$
begin
  if md5(replace(pg_get_functiondef('public.submit_order_request(jsonb)'::regprocedure), chr(13), '')) <> 'c819251209a3ae536b731340daaa3a4b' then
    raise exception '32 rollback post-check failed: the restored function is not the migration-18b text - aborting';
  end if;
  raise notice '32 rolled back: submit_order_request restored to the migration-18b definition';
end
$post$;

commit;
