-- =============================================================================
-- 22 - Customer ordering foundation for the Android app, and account-deletion requests
-- -----------------------------------------------------------------------------
-- Builds on migration 21 (customer accounts). Adds, without touching any financial function:
--
--   * product_designs                 the design catalog (a product can have several designs)
--   * customer_designs()              the designs an APPROVED customer may see
--   * customer_order_requests (+ _lines)  links a website request to the customer account that
--                                     placed it, with one design per line
--   * submit_customer_order_request() approved accounts only: stores a normal website request
--                                     (order_requests + order_request_items) for EFZ to confirm and
--                                     convert with the EXISTING pipeline. No price, customer id, status
--                                     or owner is ever taken from the client.
--   * my_order_requests()             the customer's own requests and their status
--   * request_account_deletion()      Google Play requires an in-app way to ask for deletion: records the
--                                     request, ends app access immediately, queues it for staff
--
-- Redefined (customer-facing only): require_approved_customer() and my_customer_account() (21) now also
-- honour a deletion request. NOT changed: create_order, create_order_with_terms, record_payment,
-- update_order_status, set_order_payment_terms, submit_order_request, convert_website_request, the
-- order_requests / order_request_items tables and every existing RLS policy.
--
-- A request stays a REQUEST: stock is not reserved and nothing is priced until EFZ staff confirm it and
-- convert it (convert_website_request -> create_order), so pricing, inventory, payment, audit and
-- commission rules all run exactly as for website requests.
--
-- Idempotent. Rollback: supabase/rollback/22_customer_ordering_rollback.sql (refuses while it holds data).
-- =============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
declare
  v_missing text[] := '{}';
  f text;
begin
  foreach f in array array['public.require_approved_customer()', 'public.my_customer_account()', 'public.customer_account_log(public.customer_accounts,text,text,text,text,text,jsonb)',
                           'public.set_updated_at()', 'public.has_permission(text)', 'public.is_active_staff()', 'public.can_access_order_request(text)'] loop
    if to_regprocedure(f) is null then v_missing := v_missing || f; end if;
  end loop;
  foreach f in array array['public.customer_accounts', 'public.customer_account_events', 'public.order_requests', 'public.order_request_items', 'public.order_request_events', 'public.products', 'public.customers'] loop
    if to_regclass(f) is null then v_missing := v_missing || f; end if;
  end loop;
  if cardinality(v_missing) > 0 then
    raise exception 'Migration 22 cannot run: missing prerequisite object(s) (is migration 21 applied?): %', array_to_string(v_missing, ', ');
  end if;
end
$pre$;

-- -----------------------------------------------------------------------------
-- 1. Design catalog
-- -----------------------------------------------------------------------------
create table if not exists public.product_designs (
  id          uuid primary key default gen_random_uuid(),
  product_id  text not null references public.products(id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 1 and 120),
  image_url   text not null default '',
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index if not exists product_designs_name_key on public.product_designs (product_id, lower(btrim(name)));
create index if not exists product_designs_product_idx on public.product_designs (product_id, sort_order) where is_active;

drop trigger if exists trg_product_designs_updated_at on public.product_designs;
create trigger trg_product_designs_updated_at before update on public.product_designs for each row execute function public.set_updated_at();

alter table public.product_designs enable row level security;
revoke all on public.product_designs from public, anon, authenticated;
grant select, insert, update, delete on public.product_designs to authenticated;

-- Staff read the catalog; changing it needs the same permission as editing a product. Customers have no direct access at all.
drop policy if exists product_designs_select_staff on public.product_designs;
create policy product_designs_select_staff on public.product_designs for select to authenticated using (public.is_active_staff());
drop policy if exists product_designs_insert on public.product_designs;
create policy product_designs_insert on public.product_designs for insert to authenticated with check (public.has_permission('edit_products'));
drop policy if exists product_designs_update on public.product_designs;
create policy product_designs_update on public.product_designs for update to authenticated using (public.has_permission('edit_products')) with check (public.has_permission('edit_products'));
drop policy if exists product_designs_delete on public.product_designs;
create policy product_designs_delete on public.product_designs for delete to authenticated using (public.has_permission('edit_products'));

-- -----------------------------------------------------------------------------
-- 2. Deletion requests (columns on the 21 table) and the customer-facing redefinitions
-- -----------------------------------------------------------------------------
alter table public.customer_accounts add column if not exists deletion_requested_at timestamptz;
alter table public.customer_accounts add column if not exists deletion_reason text not null default '' check (char_length(deletion_reason) <= 500);

alter table public.customer_account_events drop constraint if exists customer_account_events_event_check;
alter table public.customer_account_events add constraint customer_account_events_event_check
  check (event in ('registered', 'approved', 'rejected', 'suspended', 'reinstated', 'deletion_requested'));

-- Approved, linked and NOT asking to be deleted.
create or replace function public.require_approved_customer()
returns text
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_customer text;
begin
  select a.customer_id into v_customer
    from public.customer_accounts a
   where a.auth_user_id = auth.uid() and a.status = 'approved' and a.customer_id is not null and a.deletion_requested_at is null;
  if v_customer is null then
    raise exception 'This account is not approved for customer access' using errcode = '42501';
  end if;
  return v_customer;
end;
$fn$;
revoke all on function public.require_approved_customer() from public, anon, authenticated;

create or replace function public.my_customer_account()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select jsonb_build_object('status', a.status, 'fullName', a.full_name, 'requestedAt', a.requested_at, 'reviewedAt', a.reviewed_at,
                            'deletionRequested', a.deletion_requested_at is not null)
    from public.customer_accounts a
   where a.auth_user_id = auth.uid();
$fn$;
revoke all on function public.my_customer_account() from public, anon;
grant execute on function public.my_customer_account() to authenticated;

-- Any customer account (pending, approved, rejected, suspended) may ask to be deleted. Access ends immediately; staff process it.
create or replace function public.request_account_deletion(p_reason text default '')
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_acc public.customer_accounts%rowtype;
  v_reason text := left(btrim(coalesce(p_reason, '')), 500);
begin
  select * into v_acc from public.customer_accounts where auth_user_id = auth.uid() for update;
  if not found then
    raise exception 'No customer account for this sign-in' using errcode = '42501';
  end if;
  if v_acc.deletion_requested_at is not null then
    return;   -- already requested: nothing new is recorded
  end if;
  update public.customer_accounts set deletion_requested_at = now(), deletion_reason = v_reason where id = v_acc.id returning * into v_acc;
  perform public.customer_account_log(v_acc, 'deletion_requested', v_acc.status, v_reason, null, '', '{}'::jsonb);
end;
$fn$;
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- -----------------------------------------------------------------------------
-- 3. Designs visible to customers
-- -----------------------------------------------------------------------------
create or replace function public.customer_designs()
returns table (id uuid, product_id text, name text, image_url text, sort_order integer)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  perform public.require_approved_customer();
  return query
    select d.id, d.product_id, d.name, d.image_url, d.sort_order
      from public.product_designs d join public.products p on p.id = d.product_id
     where d.is_active and p.is_active
     order by d.product_id, d.sort_order, d.name;
end;
$fn$;
revoke all on function public.customer_designs() from public, anon;
grant execute on function public.customer_designs() to authenticated;

-- -----------------------------------------------------------------------------
-- 4. Customer order requests
-- -----------------------------------------------------------------------------
create table if not exists public.customer_order_requests (
  request_id  uuid primary key references public.order_requests(id) on delete cascade,
  account_id  uuid not null references public.customer_accounts(id) on delete restrict,
  customer_id text not null references public.customers(id) on delete restrict,
  created_at  timestamptz not null default now()
);
create index if not exists customer_order_requests_account_idx on public.customer_order_requests (account_id, created_at desc);

create table if not exists public.customer_order_request_lines (
  request_id  uuid not null references public.order_requests(id) on delete cascade,
  line_no     integer not null check (line_no between 1 and 20),
  design_id   uuid references public.product_designs(id) on delete set null,
  design_name text not null default '' check (char_length(design_name) <= 120),
  primary key (request_id, line_no)
);

-- Append-only. A row disappears only together with its request (FK cascade); the one allowed UPDATE is the design FK being
-- cleared when a design is removed from the catalog (the recorded design NAME stays on the line).
create or replace function public.guard_customer_order_requests_rows()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if tg_op = 'UPDATE' then
    raise exception 'customer_order_requests rows are append-only and cannot be changed' using errcode = '42501';
  end if;
  if exists (select 1 from public.order_requests r where r.id = old.request_id) then
    raise exception 'customer_order_requests rows cannot be deleted' using errcode = '42501';
  end if;
  return old;
end;
$fn$;
create or replace function public.guard_customer_order_request_lines_rows()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if tg_op = 'UPDATE' then
    if new.request_id = old.request_id and new.line_no = old.line_no and new.design_id is null and old.design_id is not null and new.design_name = old.design_name then
      return new;
    end if;
    raise exception 'customer_order_request_lines rows are append-only and cannot be changed' using errcode = '42501';
  end if;
  if exists (select 1 from public.order_requests r where r.id = old.request_id) then
    raise exception 'customer_order_request_lines rows cannot be deleted' using errcode = '42501';
  end if;
  return old;
end;
$fn$;
drop trigger if exists trg_customer_order_requests_guard on public.customer_order_requests;
create trigger trg_customer_order_requests_guard before update or delete on public.customer_order_requests for each row execute function public.guard_customer_order_requests_rows();
drop trigger if exists trg_customer_order_request_lines_guard on public.customer_order_request_lines;
create trigger trg_customer_order_request_lines_guard before update or delete on public.customer_order_request_lines for each row execute function public.guard_customer_order_request_lines_rows();

alter table public.customer_order_requests enable row level security;
alter table public.customer_order_request_lines enable row level security;
revoke all on public.customer_order_requests, public.customer_order_request_lines from public, anon, authenticated;
grant select on public.customer_order_requests, public.customer_order_request_lines to authenticated;

-- Staff see these rows exactly when they can see the request itself.
drop policy if exists customer_order_requests_select_staff on public.customer_order_requests;
create policy customer_order_requests_select_staff on public.customer_order_requests for select to authenticated
  using (exists (select 1 from public.order_requests r where r.id = request_id and public.can_access_order_request(r.assigned_to)));
drop policy if exists customer_order_request_lines_select_staff on public.customer_order_request_lines;
create policy customer_order_request_lines_select_staff on public.customer_order_request_lines for select to authenticated
  using (exists (select 1 from public.order_requests r where r.id = request_id and public.can_access_order_request(r.assigned_to)));

create or replace function public.submit_customer_order_request(p_payload jsonb)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_customer  text := public.require_approved_customer();
  v_acc       public.customer_accounts%rowtype;
  v_lines     jsonb := p_payload -> 'lines';
  v_location  text := btrim(coalesce(p_payload ->> 'deliveryLocation', ''));
  v_notes     text := btrim(coalesce(p_payload ->> 'notes', ''));
  v_key       uuid;
  v_existing  uuid;
  v_id        uuid := gen_random_uuid();
  v_line      jsonb;
  v_product   public.products%rowtype;
  v_design    public.product_designs%rowtype;
  v_design_id uuid;
  v_qty_raw   numeric;
  v_seq       integer := 0;
  v_units     integer := 0;
  v_pids      text[] := '{}';
  v_pnames    text[] := '{}';
  v_qtys      integer[] := '{}';
  v_dids      uuid[] := '{}';
  v_dnames    text[] := '{}';
  v_pairs     text[] := '{}';
  v_pair      text;
  c_per_day   constant integer := 20;     -- requests per account per 24 h
  c_open      constant integer := 10;     -- requests still waiting for EFZ (new / contacted / confirmed)
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'Invalid request' using errcode = '22023';
  end if;
  select * into v_acc from public.customer_accounts where auth_user_id = auth.uid();
  if char_length(v_location) > 500 or char_length(v_notes) > 2000 then
    raise exception 'A field is too long' using errcode = '22023';
  end if;
  if jsonb_typeof(v_lines) is distinct from 'array' or jsonb_array_length(v_lines) not between 1 and 20 then
    raise exception 'A request needs between 1 and 20 lines' using errcode = '22023';
  end if;
  begin
    v_key := nullif(p_payload ->> 'submissionKey', '')::uuid;
  exception when invalid_text_representation then
    raise exception 'Invalid submission key' using errcode = '22023';
  end;

  -- The same submission sent twice (a retry after a dropped connection) returns the same request.
  if v_key is not null then
    select r.id into v_existing from public.order_requests r join public.customer_order_requests c on c.request_id = r.id
     where r.submission_key = v_key and c.account_id = v_acc.id;
    if v_existing is not null then return v_existing; end if;
    if exists (select 1 from public.order_requests r where r.submission_key = v_key) then
      raise exception 'Invalid submission key' using errcode = '22023';
    end if;
  end if;

  if (select count(*) from public.customer_order_requests c where c.account_id = v_acc.id and c.created_at > now() - interval '24 hours') >= c_per_day then
    raise exception 'Too many requests today. Please try again later.' using errcode = 'WR429';
  end if;
  if (select count(*) from public.customer_order_requests c join public.order_requests r on r.id = c.request_id
       where c.account_id = v_acc.id and r.status in ('new', 'contacted', 'confirmed')) >= c_open then
    raise exception 'You already have several requests waiting for EFZ. Please wait for them to be handled.' using errcode = 'WR429';
  end if;

  -- Validate every line before anything is written. Only product, design and quantity are read from the client.
  for v_line in select * from jsonb_array_elements(v_lines)
  loop
    if jsonb_typeof(v_line) <> 'object' then raise exception 'Invalid line' using errcode = '22023'; end if;
    select * into v_product from public.products p where p.id = v_line ->> 'productId' and p.is_active;
    if not found then raise exception 'A selected product is not available' using errcode = '22023'; end if;
    begin v_qty_raw := (v_line ->> 'quantity')::numeric; exception when invalid_text_representation then v_qty_raw := null; end;
    if v_qty_raw is null or v_qty_raw <> trunc(v_qty_raw) or v_qty_raw not between 1 and 100000 then
      raise exception 'Quantity must be a whole number between 1 and 100000' using errcode = '22023';
    end if;

    v_design_id := null;
    begin v_design_id := nullif(v_line ->> 'designId', '')::uuid; exception when invalid_text_representation then
      raise exception 'Invalid design' using errcode = '22023'; end;
    if v_design_id is not null then
      select * into v_design from public.product_designs d where d.id = v_design_id and d.product_id = v_product.id and d.is_active;
      if not found then raise exception 'A selected design is not available for that product' using errcode = '22023'; end if;
    elsif exists (select 1 from public.product_designs d where d.product_id = v_product.id and d.is_active) then
      raise exception 'Choose a design for %', v_product.name using errcode = '22023';
    end if;

    v_pair := v_product.id || '|' || coalesce(v_design_id::text, '');
    if v_pair = any (v_pairs) then
      raise exception 'Each product and design can be listed once; change its quantity instead' using errcode = '22023';
    end if;
    v_pairs  := v_pairs  || v_pair;
    v_pids   := v_pids   || v_product.id;
    v_pnames := v_pnames || v_product.name;
    v_qtys   := v_qtys   || v_qty_raw::integer;
    v_dids   := v_dids   || v_design_id;
    v_dnames := v_dnames || case when v_design_id is null then '' else v_design.name end;
    v_units  := v_units  + v_qty_raw::integer;
  end loop;

  insert into public.order_requests (id, customer_name, phone, organization, product_id, product_name, quantity,
                                     delivery_location, notes, status, submission_key, phone_canonical)
  values (v_id, v_acc.full_name, v_acc.phone, v_acc.organization, v_pids[1], v_pnames[1], v_qtys[1], v_location, v_notes, 'new', v_key, v_acc.phone_canonical);

  for v_seq in 1 .. cardinality(v_pids)
  loop
    insert into public.order_request_items (request_id, line_no, product_id, product_name, quantity)
    values (v_id, v_seq, v_pids[v_seq], v_pnames[v_seq], v_qtys[v_seq]);
    insert into public.customer_order_request_lines (request_id, line_no, design_id, design_name)
    values (v_id, v_seq, v_dids[v_seq], v_dnames[v_seq]);
  end loop;
  v_seq := cardinality(v_pids);

  insert into public.customer_order_requests (request_id, account_id, customer_id) values (v_id, v_acc.id, v_customer);

  insert into public.order_request_events (request_id, event, source, to_status, actor_id, actor_name, details)
  values (v_id, 'submitted', 'rpc', 'new', null, v_acc.full_name,
          jsonb_build_object('lines', v_seq, 'units', v_units, 'channel', 'customer_app', 'accountId', v_acc.id, 'customerId', v_customer));

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'ORDER',
          format('Website request REQ-%s received from the customer app: %s item(s), %s unit(s)', upper(left(replace(v_id::text, '-', ''), 8)), v_seq, v_units),
          null, v_acc.full_name, v_id::text,
          jsonb_build_object('source', 'db', 'event', 'customer_request_submitted', 'requestId', v_id, 'accountId', v_acc.id,
                             'customerId', v_customer, 'lines', v_seq, 'units', v_units));
  return v_id;
end;
$fn$;
revoke all on function public.submit_customer_order_request(jsonb) from public, anon;
grant execute on function public.submit_customer_order_request(jsonb) to authenticated;

-- The customer's own requests. Withheld: internal notes, who handled it, why it was rejected, other customers' requests.
create or replace function public.my_order_requests()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_acc uuid;
begin
  perform public.require_approved_customer();
  select a.id into v_acc from public.customer_accounts a where a.auth_user_id = auth.uid();
  return coalesce((
    select jsonb_agg(x.obj order by x.created_at desc, x.id)
      from (
        select r.id, r.created_at,
               jsonb_build_object(
                 'id', r.id, 'status', r.status::text, 'createdAt', r.created_at, 'deliveryLocation', r.delivery_location, 'notes', r.notes,
                 'orderId', r.converted_order_id,
                 'lines', coalesce((select jsonb_agg(jsonb_build_object('productName', i.product_name, 'designName', coalesce(l.design_name, ''), 'quantity', i.quantity) order by i.line_no)
                                      from public.order_request_items i
                                      left join public.customer_order_request_lines l on l.request_id = i.request_id and l.line_no = i.line_no
                                     where i.request_id = r.id), '[]'::jsonb)
               ) as obj
          from public.customer_order_requests c join public.order_requests r on r.id = c.request_id
         where c.account_id = v_acc
      ) x
  ), '[]'::jsonb);
end;
$fn$;
revoke all on function public.my_order_requests() from public, anon;
grant execute on function public.my_order_requests() to authenticated;

commit;
