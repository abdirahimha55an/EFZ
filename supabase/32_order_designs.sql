-- =============================================================================
-- 32 - Ball designs on the public order form, and their management. Follows migration 31 (and 28, which already carries a request line's design into an order).
-- STATUS: written 2026-11-05. Applied to EFZ-Staging ONLY (see docs/ORDER_DESIGNS.md). NOT applied to Production: that needs the owner's separate approval.
-- -----------------------------------------------------------------------------
-- WHAT CHANGES (no table, column, policy or grant on an existing object is added, changed or removed):
--   1. NEW public.public_product_designs(): the active designs of active products, readable by visitors (anon) so the order form can offer them.
--      Nothing else about product_designs becomes visible to anyone: the table keeps its row-level security (staff read; edit_products writes).
--   2. REPLACED public.submit_order_request(jsonb): everything it does today (validation, phone rules, per-phone limit, double-submit key, header mirror, timeline,
--      audit line) plus
--        - an optional "designId" per line, checked: the design must exist, be active and belong to that line's product, else "A selected design is not available";
--        - a product may appear on several lines when the DESIGNS differ (a product + design pair may appear once); a repeated product without a design is refused
--          exactly as before; a payload without designId behaves exactly as it does today;
--        - for each line that has a design, one row in customer_order_request_lines (design_id, design_name), the table the Android app already uses and the Hub
--          request screen and the Convert-to-Order dialog already read, so nothing downstream changes.
--   3. NEW trigger functions on product_designs (staff management, enforced in the database whichever screen is used):
--        guard_product_design()       before insert/update: trims the name, accepts an image link only as https:// (<= 500 characters), forbids moving a design
--                                     to another product (lines, price agreements and orders point at it).
--        log_product_design_changes() after insert/update/delete: one system_logs line per change in the same transaction (created, renamed/changed, activated,
--                                     deactivated, deleted), category INVENTORY, origin 'database'.
-- WHO MAY MANAGE DESIGNS: unchanged and already enforced by migration 22's policies: signed-in staff may read; only holders of edit_products may insert/update/delete.
-- Existing orders, requests, payments, stock, commissions, customers and designs are never touched; the change applies to future submissions only.
-- Requires 22 (product_designs, customer_order_request_lines) and 18b (submit_order_request). Idempotent. Forward only.
-- Rollback: supabase/rollback/32_order_designs_rollback.sql (restores the 18b function; design rows already recorded on requests are kept).
-- Checks: supabase/checks/32_order_designs_checks.sql (Staging only).
-- =============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
declare
  v_def text;
begin
  if to_regprocedure('public.submit_order_request(jsonb)') is null
     or to_regprocedure('public.website_request_admission(text, uuid)') is null
     or to_regprocedure('public.validate_request_phone(text)') is null
     or to_regprocedure('public.current_profile_id()') is null
     or to_regprocedure('public.current_profile_name()') is null
     or to_regclass('public.product_designs') is null
     or to_regclass('public.customer_order_request_lines') is null then
    raise exception '32: migrations 18b and 22 must be applied first - refusing';
  end if;
  v_def := replace(pg_get_functiondef('public.submit_order_request(jsonb)'::regprocedure), chr(13), '');
  -- Either the known 18b text (Staging and Production both carried exactly this) or this file's own text (a re-run). Anything else: do not overwrite it.
  if md5(v_def) <> 'c819251209a3ae536b731340daaa3a4b' and position('designId' in v_def) = 0 then
    raise exception '32: submit_order_request is not the migration-18b definition this file replaces (md5 %) - refusing', md5(v_def);
  end if;
end
$pre$;

-- -----------------------------------------------------------------------------
-- 1. What a visitor may see of the design catalog
-- -----------------------------------------------------------------------------
create or replace function public.public_product_designs()
returns table (id uuid, product_id text, name text, image_url text)
language sql
stable
security definer
set search_path = public
as $fn$
  select d.id, d.product_id, d.name, d.image_url
    from public.product_designs d
    join public.products p on p.id = d.product_id
   where d.is_active and p.is_active
   order by p.name, d.sort_order, d.name, d.id;
$fn$;

revoke all on function public.public_product_designs() from public, anon, authenticated;
grant execute on function public.public_product_designs() to anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. The public submission, now design-aware
-- -----------------------------------------------------------------------------
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
  v_design   public.product_designs%rowtype;
  v_design_id uuid;
  v_design_raw text;
  v_pair     text;
  v_pairs    text[] := '{}';
  v_seen     text[] := '{}';
  v_names    text[] := '{}';
  v_qtys     integer[] := '{}';
  v_dids     uuid[] := '{}';
  v_dnames   text[] := '{}';
  v_designed integer := 0;
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
    if jsonb_typeof(v_line) is distinct from 'object' then
      raise exception 'A selected product is not available' using errcode = '22023';
    end if;
    select * into v_product from public.products p
     where p.id = v_line ->> 'productId' and p.is_active;
    if not found then
      raise exception 'A selected product is not available' using errcode = '22023';
    end if;

    -- The design is optional; when given it must be an active design of THIS line's product.
    v_design_id := null;
    v_design_raw := nullif(btrim(coalesce(v_line ->> 'designId', '')), '');
    if v_design_raw is not null then
      begin
        v_design_id := v_design_raw::uuid;
      exception when invalid_text_representation then
        raise exception 'A selected design is not available' using errcode = '22023';
      end;
      select * into v_design from public.product_designs d
       where d.id = v_design_id and d.product_id = v_product.id and d.is_active;
      if not found then
        raise exception 'A selected design is not available' using errcode = '22023';
      end if;
    end if;

    -- A product may appear again only with a different design.
    v_pair := v_product.id || '|' || coalesce(v_design_id::text, '');
    if v_pair = any (v_pairs) then
      if v_design_id is null then
        raise exception 'Each product can be listed once; change its quantity instead' using errcode = '22023';
      else
        raise exception 'Each design of a product can be listed once; change its quantity instead' using errcode = '22023';
      end if;
    end if;

    begin
      v_qty_raw := (v_line ->> 'quantity')::numeric;
    exception when invalid_text_representation then
      v_qty_raw := null;
    end;
    if v_qty_raw is null or v_qty_raw <> trunc(v_qty_raw) or v_qty_raw not between 1 and 100000 then
      raise exception 'Quantity must be a whole number between 1 and 100000' using errcode = '22023';
    end if;
    v_pairs  := v_pairs || v_pair;
    v_seen   := v_seen || v_product.id;
    v_names  := v_names || v_product.name;
    v_qtys   := v_qtys || v_qty_raw::integer;
    v_dids   := v_dids || v_design_id;
    v_dnames := v_dnames || case when v_design_id is null then '' else v_design.name end;
    v_units  := v_units + v_qty_raw::integer;
    if v_design_id is not null then v_designed := v_designed + 1; end if;
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
    -- Only a line that HAS a design gets a row, exactly like the app's requests; a request without designs writes what it always wrote.
    if v_dids[v_seq] is not null then
      insert into public.customer_order_request_lines (request_id, line_no, design_id, design_name)
      values (v_id, v_seq, v_dids[v_seq], v_dnames[v_seq]);
    end if;
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
                             'path', 'rpc', 'lines', v_seq, 'units', v_units, 'designLines', v_designed));
  return v_id;
end;
$fn$;

revoke all on function public.submit_order_request(jsonb) from public, anon, authenticated;
grant execute on function public.submit_order_request(jsonb) to anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. Managing designs: validation and audit, in the database
-- -----------------------------------------------------------------------------
create or replace function public.guard_product_design()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  new.name := btrim(new.name);
  new.image_url := btrim(coalesce(new.image_url, ''));
  if new.image_url <> '' and (new.image_url !~ '^https://[^[:space:]]+$' or char_length(new.image_url) > 500) then
    raise exception 'The image link must start with https:// and be at most 500 characters' using errcode = '22023';
  end if;
  if new.sort_order not between 0 and 100000 then
    raise exception 'The display order must be between 0 and 100000' using errcode = '22023';
  end if;
  if tg_op = 'UPDATE' and new.product_id is distinct from old.product_id then
    raise exception 'A design cannot be moved to another product; deactivate it and create a new one' using errcode = '22023';
  end if;
  return new;
end;
$fn$;

revoke all on function public.guard_product_design() from public, anon, authenticated;

drop trigger if exists trg_product_designs_guard on public.product_designs;
create trigger trg_product_designs_guard
  before insert or update on public.product_designs
  for each row execute function public.guard_product_design();

create or replace function public.log_product_design_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  d        public.product_designs%rowtype := case when tg_op = 'DELETE' then old else new end;
  v_actor  text := public.current_profile_id();
  v_nm     text := coalesce(public.current_profile_name(), '');
  v_prod   text;
  v_event  text;
  v_msg    text;
  v_what   text[] := '{}';
begin
  select p.name into v_prod from public.products p where p.id = d.product_id;
  v_prod := coalesce(v_prod, d.product_id);

  if tg_op = 'INSERT' then
    v_event := 'design_created';
    v_msg := format('Design created: %s - %s%s', v_prod, d.name, case when d.is_active then '' else ' (inactive)' end);
  elsif tg_op = 'DELETE' then
    v_event := 'design_deleted';
    v_msg := format('Design deleted: %s - %s', v_prod, d.name);
  else
    if old.is_active is distinct from new.is_active then
      v_event := case when new.is_active then 'design_activated' else 'design_deactivated' end;
      v_msg := format('Design %s: %s - %s', case when new.is_active then 'activated' else 'deactivated' end, v_prod, new.name);
    else
      if old.name is distinct from new.name then v_what := array_append(v_what, 'name'::text); end if;
      if old.image_url is distinct from new.image_url then v_what := array_append(v_what, 'image'::text); end if;
      if old.sort_order is distinct from new.sort_order then v_what := array_append(v_what, 'display order'::text); end if;
      if cardinality(v_what) = 0 then
        return null;   -- nothing that matters changed (for example only updated_at)
      end if;
      v_event := 'design_updated';
      v_msg := format('Design updated: %s - %s (%s changed%s)', v_prod, new.name, array_to_string(v_what, ', '),
                      case when old.name is distinct from new.name then '; was "' || old.name || '"' else '' end);
    end if;
  end if;

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'INVENTORY', v_msg, v_actor, v_nm, d.id::text,
          jsonb_build_object('source', 'db', 'event', v_event, 'designId', d.id, 'productId', d.product_id,
                             'actor', coalesce(v_actor, 'database session (no signed-in user)')));
  return null;
end;
$fn$;

revoke all on function public.log_product_design_changes() from public, anon, authenticated;

drop trigger if exists trg_product_designs_audit on public.product_designs;
create trigger trg_product_designs_audit
  after insert or update or delete on public.product_designs
  for each row execute function public.log_product_design_changes();

-- -----------------------------------------------------------------------------
-- 4. Post-checks: refuse to commit a half-installed change
-- -----------------------------------------------------------------------------
do $post$
begin
  if position('designId' in pg_get_functiondef('public.submit_order_request(jsonb)'::regprocedure)) = 0 then
    raise exception '32 post-check failed: submit_order_request not updated - aborting';
  end if;
  if not has_function_privilege('anon', 'public.submit_order_request(jsonb)', 'EXECUTE')
     or not has_function_privilege('anon', 'public.public_product_designs()', 'EXECUTE') then
    raise exception '32 post-check failed: visitors cannot use the order form functions - aborting';
  end if;
  if has_table_privilege('anon', 'public.product_designs', 'SELECT') or has_table_privilege('anon', 'public.customer_order_request_lines', 'SELECT') then
    raise exception '32 post-check failed: a visitor can read a design table directly - aborting';
  end if;
  if has_function_privilege('anon', 'public.guard_product_design()', 'EXECUTE') or has_function_privilege('authenticated', 'public.log_product_design_changes()', 'EXECUTE') then
    raise exception '32 post-check failed: a trigger function is callable by clients - aborting';
  end if;
  if (select count(*) from pg_trigger where tgrelid = 'public.product_designs'::regclass and tgname in ('trg_product_designs_guard', 'trg_product_designs_audit') and not tgisinternal) <> 2 then
    raise exception '32 post-check failed: design triggers missing - aborting';
  end if;
  raise notice '32: order designs installed';
end
$post$;

commit;
