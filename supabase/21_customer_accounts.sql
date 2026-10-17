-- =============================================================================
-- 21 - Customer accounts for the Android customer app (foundation)
-- -----------------------------------------------------------------------------
-- Customers register, EFZ approves, and only then may an account use the private
-- catalog or read its own orders. This migration adds the DATABASE side only:
--
--   * customer_accounts            one row per registered auth user (pending ->
--                                  approved | rejected, approved <-> suspended)
--   * customer_account_events      append-only history of every transition
--   * permission manage_customer_accounts (Super Admin grants only: reserved)
--   * register_customer_account()  service_role only (called by the registration
--                                  Edge Function, never by a client)
--   * approve / reject / suspend / reinstate_customer_account()   staff RPCs
--   * find_customers_for_account() candidate CRM matches for a verifying human
--   * my_customer_account(), customer_catalog(), my_orders()      customer reads,
--                                  every one enforcing status = 'approved'
--
-- AUTH TRIGGER CORRECTION (the reason this is a security change):
--   08 created an INACTIVE 'Marketing Officer' profile for any confirmed sign-up
--   whose email matched no profile. Customer sign-ups must never become staff,
--   even inactive ones (an admin flipping status would hand out a staff role).
--   After this migration an auth user is linked to a staff profile ONLY when a
--   profile with the same email already exists (Admin -> Users first, then
--   dashboard Add user / invite - the documented provisioning order). Unknown
--   sign-ups get NO profile. Accounts created by the registration function carry
--   app_metadata.efz_kind = 'customer' (set server-side; a user cannot set it) and
--   are never linked to a profile, whatever their email.
--
-- NOT changed: create_order, create_order_with_terms, record_payment,
--   update_order_status, set_order_payment_terms, submit_order_request,
--   convert_website_request, any RLS policy on an existing table, the public
--   website catalog (public_products). Customers get no staff permission and no
--   direct SELECT on any existing table.
--
-- Only changed functions: link_auth_user_to_profile, handle_new_auth_user,
--   handle_auth_user_confirmed (trigger rule above), reserved_permissions (+1).
--
-- Idempotent. Additive apart from the changed functions above.
-- Rollback: supabase/rollback/21_customer_accounts_rollback.sql (refuses while any
-- customer account exists).
-- =============================================================================

begin;

set local lock_timeout = '30s';

-- Preflight: everything this migration relies on must already exist.
do $pre$
declare
  v_missing text[] := '{}';
  f text;
begin
  foreach f in array array[
    'public.has_permission(text)', 'public.current_profile_id()', 'public.is_super_admin()',
    'public.is_client_request()', 'public.validate_request_phone(text)', 'public.normalize_phone(text,text)',
    'public.customer_phone_canonical(text)', 'public.set_updated_at()', 'public.reserved_permissions()',
    'public.link_auth_user_to_profile(uuid,text,jsonb)', 'public.handle_new_auth_user()', 'public.handle_auth_user_confirmed()'
  ] loop
    if to_regprocedure(f) is null then v_missing := v_missing || f; end if;
  end loop;
  foreach f in array array['public.profiles', 'public.customers', 'public.products', 'public.orders', 'public.order_items', 'public.payments', 'public.system_logs', 'public.permissions', 'auth.users'] loop
    if to_regclass(f) is null then v_missing := v_missing || f; end if;
  end loop;
  if cardinality(v_missing) > 0 then
    raise exception 'Migration 21 cannot run: missing prerequisite object(s): %', array_to_string(v_missing, ', ');
  end if;
end
$pre$;

-- -----------------------------------------------------------------------------
-- 1. Permission (reserved: only a Super Admin can grant or revoke it)
-- -----------------------------------------------------------------------------
insert into public.permissions (code, label, category, sort_order)
values ('manage_customer_accounts', 'Review customer app accounts', 'Customers', 56)
on conflict (code) do nothing;

create or replace function public.reserved_permissions()
returns text[]
language sql
immutable
set search_path = public
as $fn$
  select array['manage_users', 'manage_system', 'change_settings', 'manage_customer_accounts'];
$fn$;

-- -----------------------------------------------------------------------------
-- 2. Tables
-- -----------------------------------------------------------------------------
create table if not exists public.customer_accounts (
  id               uuid primary key default gen_random_uuid(),
  auth_user_id     uuid not null unique references auth.users(id) on delete restrict,
  customer_id      text references public.customers(id) on delete restrict,
  email            text not null check (email = lower(btrim(email)) and char_length(email) between 3 and 254),
  full_name        text not null check (char_length(btrim(full_name)) between 1 and 200),
  organization     text not null default '' check (char_length(organization) <= 200),
  phone            text not null check (char_length(btrim(phone)) between 1 and 50),
  phone_canonical  text not null,
  status           text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'suspended')),
  requested_at     timestamptz not null default now(),
  reviewed_by      text references public.profiles(id) on delete set null,
  reviewed_by_name text not null default '',
  reviewed_at      timestamptz,
  review_note      text not null default '',
  ip_hash          text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  -- an approved or suspended account is always tied to a verified CRM customer
  constraint customer_accounts_link_check check (status in ('pending', 'rejected') or customer_id is not null)
);

comment on table public.customer_accounts is
  'Android customer app accounts. Not staff: no profile, no staff permission. Access is granted only while status = approved and customer_id is a staff-verified CRM customer.';
comment on column public.customer_accounts.ip_hash is 'Salted hash of the registering client address, for rate limiting only. Never the address itself.';

create unique index if not exists customer_accounts_email_key on public.customer_accounts (email);
create unique index if not exists customer_accounts_customer_key on public.customer_accounts (customer_id) where customer_id is not null;
create index if not exists customer_accounts_status_idx on public.customer_accounts (status, requested_at);
create index if not exists customer_accounts_phone_idx on public.customer_accounts (phone_canonical, created_at);
create index if not exists customer_accounts_ip_idx on public.customer_accounts (ip_hash, created_at) where ip_hash is not null;

create table if not exists public.customer_account_events (
  id          bigint generated always as identity primary key,
  account_id  uuid not null references public.customer_accounts(id) on delete restrict,
  event       text not null check (event in ('registered', 'approved', 'rejected', 'suspended', 'reinstated')),
  from_status text,
  to_status   text not null,
  actor_id    text references public.profiles(id) on delete set null,
  actor_name  text not null default '',
  customer_id text,
  note        text not null default '',
  metadata    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists customer_account_events_account_idx on public.customer_account_events (account_id, id);

comment on table public.customer_account_events is 'Append-only history of customer account transitions (who, what, when, why). No client can write or change it.';

-- History is never edited or removed.
create or replace function public.guard_customer_account_events()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  raise exception 'customer_account_events is append-only' using errcode = '42501';
end;
$fn$;
drop trigger if exists trg_customer_account_events_guard on public.customer_account_events;
create trigger trg_customer_account_events_guard
  before update or delete on public.customer_account_events
  for each row execute function public.guard_customer_account_events();

drop trigger if exists trg_customer_accounts_updated_at on public.customer_accounts;
create trigger trg_customer_accounts_updated_at
  before update on public.customer_accounts
  for each row execute function public.set_updated_at();

-- Transitions are enforced in the database for every writer, not only in the RPCs.
create or replace function public.guard_customer_accounts_write()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if tg_op = 'DELETE' then
    raise exception 'Customer accounts are never deleted; suspend or reject them' using errcode = '42501';
  end if;
  if public.is_client_request() then
    raise exception 'Customer accounts change only through the review functions' using errcode = '42501';
  end if;
  if tg_op = 'INSERT' then
    if new.status <> 'pending' then
      raise exception 'A customer account starts as pending' using errcode = '42501';
    end if;
    return new;
  end if;
  -- UPDATE
  if new.id is distinct from old.id or new.auth_user_id is distinct from old.auth_user_id
     or new.email is distinct from old.email or new.requested_at is distinct from old.requested_at then
    raise exception 'Identity fields of a customer account cannot be changed' using errcode = '42501';
  end if;
  if old.customer_id is not null and new.customer_id is distinct from old.customer_id then
    raise exception 'A verified customer link cannot be changed' using errcode = '42501';
  end if;
  if new.status is distinct from old.status then
    if not ((old.status = 'pending'   and new.status in ('approved', 'rejected'))
         or (old.status = 'approved'  and new.status = 'suspended')
         or (old.status = 'suspended' and new.status = 'approved')) then
      raise exception 'Customer account cannot move from % to %', old.status, new.status using errcode = '42501';
    end if;
  end if;
  return new;
end;
$fn$;
drop trigger if exists trg_customer_accounts_guard on public.customer_accounts;
create trigger trg_customer_accounts_guard
  before insert or update or delete on public.customer_accounts
  for each row execute function public.guard_customer_accounts_write();

-- -----------------------------------------------------------------------------
-- 3. Privileges and RLS: staff with the permission may read; nobody writes directly.
--    (Supabase grants every new table to anon/authenticated by default, TRUNCATE
--    included, so everything is revoked explicitly first.)
-- -----------------------------------------------------------------------------
alter table public.customer_accounts enable row level security;
alter table public.customer_account_events enable row level security;

revoke all on public.customer_accounts from public, anon, authenticated;
revoke all on public.customer_account_events from public, anon, authenticated;
grant select on public.customer_accounts to authenticated;
grant select on public.customer_account_events to authenticated;

drop policy if exists customer_accounts_select_staff on public.customer_accounts;
create policy customer_accounts_select_staff on public.customer_accounts
  for select to authenticated using (public.has_permission('manage_customer_accounts'));
drop policy if exists customer_account_events_select_staff on public.customer_account_events;
create policy customer_account_events_select_staff on public.customer_account_events
  for select to authenticated using (public.has_permission('manage_customer_accounts'));

-- -----------------------------------------------------------------------------
-- 4. Auth trigger correction
-- -----------------------------------------------------------------------------
create or replace function public.link_auth_user_to_profile(
  p_auth_id uuid,
  p_email   text,
  p_meta    jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_profile_id text;
  v_linked_to  uuid;
begin
  if exists (select 1 from public.profiles where auth_user_id = p_auth_id) then
    return;
  end if;

  -- A customer account is never staff, whatever its email says.
  if exists (select 1 from public.customer_accounts where auth_user_id = p_auth_id) then
    return;
  end if;

  select id, auth_user_id into v_profile_id, v_linked_to
    from public.profiles
   where lower(email) = lower(p_email)
   limit 1;

  -- Only an EXISTING profile (created in Admin -> Users) can be claimed. Unknown
  -- emails get no profile at all - not even an inactive one.
  if v_profile_id is not null and v_linked_to is null then
    update public.profiles
       set auth_user_id = p_auth_id,
           updated_at   = now()
     where id = v_profile_id;
  end if;
end;
$fn$;

revoke all on function public.link_auth_user_to_profile(uuid, text, jsonb) from public, anon, authenticated;

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if coalesce(new.raw_app_meta_data ->> 'efz_kind', '') = 'customer' then
    return new;   -- customer registrations never touch staff profiles
  end if;
  if new.email_confirmed_at is not null or new.invited_at is not null then
    perform public.link_auth_user_to_profile(new.id, new.email, new.raw_user_meta_data);
  end if;
  return new;
end;
$fn$;

create or replace function public.handle_auth_user_confirmed()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if coalesce(new.raw_app_meta_data ->> 'efz_kind', '') = 'customer' then
    return new;
  end if;
  perform public.link_auth_user_to_profile(new.id, new.email, new.raw_user_meta_data);
  return new;
end;
$fn$;

-- -----------------------------------------------------------------------------
-- 5. Internal helpers (no client may call them)
-- -----------------------------------------------------------------------------
create or replace function public.customer_account_log(
  p_account public.customer_accounts, p_event text, p_from text, p_note text, p_actor text, p_actor_name text, p_meta jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  insert into public.customer_account_events (account_id, event, from_status, to_status, actor_id, actor_name, customer_id, note, metadata)
  values (p_account.id, p_event, p_from, p_account.status, p_actor, coalesce(p_actor_name, ''), p_account.customer_id, coalesce(p_note, ''), coalesce(p_meta, '{}'::jsonb));

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values (
    'log-' || replace(gen_random_uuid()::text, '-', ''),
    case when p_event in ('suspended', 'rejected') then 'WARNING' else 'INFO' end::public.log_severity,
    case when p_event = 'registered' then 'AUTH' else 'CUSTOMER' end::public.log_category,
    format('Customer app account %s: %s', p_event, p_account.id),
    p_actor, coalesce(p_actor_name, ''), p_account.id::text,
    jsonb_build_object('source', 'db', 'event', 'customer_account_' || p_event, 'accountId', p_account.id,
                       'from', p_from, 'to', p_account.status, 'customerId', p_account.customer_id) || coalesce(p_meta, '{}'::jsonb)
  );
end;
$fn$;
revoke all on function public.customer_account_log(public.customer_accounts, text, text, text, text, text, jsonb) from public, anon, authenticated;

-- The caller's account when (and only when) it is approved and tied to a customer.
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
   where a.auth_user_id = auth.uid() and a.status = 'approved' and a.customer_id is not null;
  if v_customer is null then
    raise exception 'This account is not approved for customer access' using errcode = '42501';
  end if;
  return v_customer;
end;
$fn$;
revoke all on function public.require_approved_customer() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 6. Registration (service_role only - the Edge Function). Never callable by a client.
-- -----------------------------------------------------------------------------
-- Shared by the check and the registration: validates the phone (WR422) and applies the
-- rate limits (WR429). Returns the canonical phone.
create or replace function public.customer_registration_limits(p_phone text, p_client_hint text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_canon text;
  c_per_phone constant integer := 3;     -- registrations per phone number per 24 h
  c_per_hint  constant integer := 10;    -- per client hint (hashed address) per 24 h
  c_global    constant integer := 300;   -- all registrations per 24 h
begin
  v_canon := public.validate_request_phone(p_phone);   -- WR422 for a bad number
  if (select count(*) from public.customer_accounts a where a.phone_canonical = v_canon and a.created_at > now() - interval '24 hours') >= c_per_phone
     or (nullif(p_client_hint, '') is not null and (select count(*) from public.customer_accounts a where a.ip_hash = p_client_hint and a.created_at > now() - interval '24 hours') >= c_per_hint)
     or (select count(*) from public.customer_accounts a where a.created_at > now() - interval '24 hours') >= c_global then
    raise exception 'Too many registrations. Please try again later.' using errcode = 'WR429';
  end if;
  return v_canon;
end;
$fn$;
revoke all on function public.customer_registration_limits(text, text) from public, anon, authenticated;

-- Pre-flight for the Edge Function, BEFORE any auth user is created. Writes nothing.
--   ok        free to register
--   reserved  the email belongs to a staff profile (never registrable as a customer)
--   duplicate an account (or auth user) already exists for this email
create or replace function public.customer_registration_check(p_email text, p_phone text, p_client_hint text)
returns table (verdict text, phone_canonical text)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_canon text;
begin
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_email) > 254 then
    raise exception 'Please enter a valid email address' using errcode = 'WR422';
  end if;
  v_canon := public.customer_registration_limits(p_phone, p_client_hint);
  if exists (select 1 from public.profiles p where lower(p.email) = v_email) then
    return query select 'reserved'::text, v_canon; return;
  end if;
  if exists (select 1 from public.customer_accounts a where a.email = v_email)
     or exists (select 1 from auth.users u where lower(u.email) = v_email) then
    return query select 'duplicate'::text, v_canon; return;
  end if;
  return query select 'ok'::text, v_canon;
end;
$fn$;
revoke all on function public.customer_registration_check(text, text, text) from public, anon, authenticated;
grant execute on function public.customer_registration_check(text, text, text) to service_role;

-- Creates the PENDING account for an auth user the Edge Function has just created.
create or replace function public.register_customer_account(
  p_auth_user_id uuid, p_email text, p_full_name text, p_phone text, p_organization text, p_client_hint text
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_email   text := lower(btrim(coalesce(p_email, '')));
  v_name    text := btrim(coalesce(p_full_name, ''));
  v_org     text := btrim(coalesce(p_organization, ''));
  v_canon   text;
  v_account public.customer_accounts%rowtype;
begin
  if char_length(v_name) not between 1 and 200 or char_length(v_org) > 200 then
    raise exception 'Please check the name fields' using errcode = 'WR422';
  end if;
  -- the auth user must exist, carry this email and be marked as a customer registration
  if not exists (select 1 from auth.users u
                  where u.id = p_auth_user_id and lower(u.email) = v_email
                    and coalesce(u.raw_app_meta_data ->> 'efz_kind', '') = 'customer') then
    raise exception 'Unknown or unmarked auth user' using errcode = '42501';
  end if;
  if exists (select 1 from public.profiles p where p.auth_user_id = p_auth_user_id or lower(p.email) = v_email) then
    raise exception 'A staff account cannot be a customer account' using errcode = '42501';
  end if;
  v_canon := public.customer_registration_limits(p_phone, p_client_hint);

  insert into public.customer_accounts (auth_user_id, email, full_name, organization, phone, phone_canonical, ip_hash)
  values (p_auth_user_id, v_email, v_name, v_org, btrim(p_phone), v_canon, nullif(p_client_hint, ''))
  returning * into v_account;

  perform public.customer_account_log(v_account, 'registered', null, '', null, '', '{}'::jsonb);
  return v_account.id;
end;
$fn$;
revoke all on function public.register_customer_account(uuid, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.register_customer_account(uuid, text, text, text, text, text) to service_role;

-- -----------------------------------------------------------------------------
-- 7. Staff review (manage_customer_accounts; stricter than require_permission: a
--    caller without an authenticated staff session is refused, never waved through)
-- -----------------------------------------------------------------------------
create or replace function public.find_customers_for_account(p_account_id uuid)
returns table (customer_id text, name text, phone_masked text, status text, linked boolean, orders bigint)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_acc public.customer_accounts%rowtype;
begin
  if not public.has_permission('manage_customer_accounts') then
    raise exception 'Permission denied: manage_customer_accounts is required' using errcode = '42501';
  end if;
  select * into v_acc from public.customer_accounts where id = p_account_id;
  if not found then
    raise exception 'Unknown customer account' using errcode = '42501';
  end if;
  return query
    select c.id, c.name,
           case when char_length(c.phone) > 3 then repeat('*', char_length(c.phone) - 3) || right(c.phone, 3) else '***' end,
           c.status::text,
           exists (select 1 from public.customer_accounts x where x.customer_id = c.id),
           (select count(*) from public.orders o where o.customer_id = c.id)
      from public.customers c
     where public.customer_phone_canonical(c.phone) = v_acc.phone_canonical
     order by (c.status = 'active') desc, c.name;
end;
$fn$;
revoke all on function public.find_customers_for_account(uuid) from public, anon;
grant execute on function public.find_customers_for_account(uuid) to authenticated;

create or replace function public.approve_customer_account(
  p_account_id uuid, p_customer_id text, p_create_customer boolean, p_verified boolean, p_note text
)
returns text
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_actor    text := public.current_profile_id();
  v_actor_nm text;
  v_acc      public.customer_accounts%rowtype;
  v_cust     public.customers%rowtype;
  v_cust_id  text;
  v_phone_hit boolean;
  v_note     text := btrim(coalesce(p_note, ''));
  v_stored   text;
begin
  if not public.has_permission('manage_customer_accounts') then
    raise exception 'Permission denied: manage_customer_accounts is required' using errcode = '42501';
  end if;
  if (p_customer_id is null) = (coalesce(p_create_customer, false) = false) then
    raise exception 'Choose exactly one: link an existing customer, or create a new one' using errcode = '22023';
  end if;
  if char_length(v_note) < 10 then
    raise exception 'Describe how you verified this person (at least 10 characters)' using errcode = '22023';
  end if;

  select * into v_acc from public.customer_accounts where id = p_account_id for update;
  if not found then
    raise exception 'Unknown customer account' using errcode = '42501';
  end if;
  if v_acc.auth_user_id = auth.uid() then
    raise exception 'You cannot review your own account' using errcode = '42501';
  end if;
  if v_acc.status <> 'pending' then
    raise exception 'Only a pending account can be approved (this one is %)', v_acc.status using errcode = '42501';
  end if;

  select p.name into v_actor_nm from public.profiles p where p.id = v_actor;

  if p_customer_id is not null then
    -- Linking an existing CRM customer: never automatic, never from a phone match alone.
    if p_verified is not true then
      raise exception 'Linking an existing customer needs your explicit confirmation that you verified this person' using errcode = '22023';
    end if;
    select * into v_cust from public.customers where id = p_customer_id for update;
    if not found or v_cust.status <> 'active' then
      raise exception 'Unknown or inactive customer' using errcode = '22023';
    end if;
    if exists (select 1 from public.customer_accounts x where x.customer_id = v_cust.id) then
      raise exception 'That customer is already linked to an app account' using errcode = '22023';
    end if;
    v_cust_id := v_cust.id;
    v_phone_hit := public.customer_phone_canonical(v_cust.phone) = v_acc.phone_canonical;
  else
    -- New CRM customer. If the phone number already belongs to a customer, a human must
    -- confirm this is a different person (otherwise: link the existing one).
    if exists (select 1 from public.customers c where public.customer_phone_canonical(c.phone) = v_acc.phone_canonical)
       and p_verified is not true then
      raise exception 'A customer with this phone number already exists. Link that customer after verifying identity, or confirm this is a different person' using errcode = '22023';
    end if;
    v_stored := case when v_acc.phone_canonical like '+252%' then substr(v_acc.phone_canonical, 5) else v_acc.phone_canonical end;
    v_cust_id := 'cust-' || replace(gen_random_uuid()::text, '-', '');
    -- No commission owner is assigned (marketing_officer_id stays NULL).
    insert into public.customers (id, name, email, phone, notes, marketing_officer_id, registered_by, status)
    values (v_cust_id, case when v_acc.organization <> '' then v_acc.full_name || ' (' || v_acc.organization || ')' else v_acc.full_name end,
            v_acc.email, v_stored, 'Created from a customer app account', null, v_actor, 'active');
    v_phone_hit := true;
  end if;

  update public.customer_accounts
     set status = 'approved', customer_id = v_cust_id, reviewed_by = v_actor, reviewed_by_name = coalesce(v_actor_nm, ''),
         reviewed_at = now(), review_note = v_note
   where id = v_acc.id
   returning * into v_acc;

  perform public.customer_account_log(v_acc, 'approved', 'pending', v_note, v_actor, v_actor_nm,
    jsonb_build_object('linkedExisting', p_customer_id is not null, 'phoneMatched', v_phone_hit, 'verifiedFlag', p_verified is true));
  return v_cust_id;
end;
$fn$;
revoke all on function public.approve_customer_account(uuid, text, boolean, boolean, text) from public, anon;
grant execute on function public.approve_customer_account(uuid, text, boolean, boolean, text) to authenticated;

-- reject / suspend / reinstate share one body
create or replace function public.change_customer_account_status(p_account_id uuid, p_to text, p_reason text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_actor    text := public.current_profile_id();
  v_actor_nm text;
  v_acc      public.customer_accounts%rowtype;
  v_from     text;
  v_event    text;
  v_reason   text := btrim(coalesce(p_reason, ''));
begin
  if not public.has_permission('manage_customer_accounts') then
    raise exception 'Permission denied: manage_customer_accounts is required' using errcode = '42501';
  end if;
  if p_to not in ('rejected', 'suspended', 'approved') then
    raise exception 'Unsupported status' using errcode = '22023';
  end if;
  if char_length(v_reason) < 5 then
    raise exception 'Give a reason (at least 5 characters)' using errcode = '22023';
  end if;
  select * into v_acc from public.customer_accounts where id = p_account_id for update;
  if not found then
    raise exception 'Unknown customer account' using errcode = '42501';
  end if;
  if v_acc.auth_user_id = auth.uid() then
    raise exception 'You cannot review your own account' using errcode = '42501';
  end if;
  v_from := v_acc.status;
  if not ((p_to = 'rejected' and v_from = 'pending') or (p_to = 'suspended' and v_from = 'approved') or (p_to = 'approved' and v_from = 'suspended')) then
    raise exception 'A % account cannot become %', v_from, p_to using errcode = '42501';
  end if;
  v_event := case p_to when 'rejected' then 'rejected' when 'suspended' then 'suspended' else 'reinstated' end;

  select p.name into v_actor_nm from public.profiles p where p.id = v_actor;
  update public.customer_accounts
     set status = p_to, reviewed_by = v_actor, reviewed_by_name = coalesce(v_actor_nm, ''), reviewed_at = now(), review_note = v_reason
   where id = v_acc.id
   returning * into v_acc;
  perform public.customer_account_log(v_acc, v_event, v_from, v_reason, v_actor, v_actor_nm, '{}'::jsonb);
end;
$fn$;
revoke all on function public.change_customer_account_status(uuid, text, text) from public, anon, authenticated;

create or replace function public.reject_customer_account(p_account_id uuid, p_reason text)
returns void language sql volatile security definer set search_path = public
as $fn$ select public.change_customer_account_status(p_account_id, 'rejected', p_reason); $fn$;
create or replace function public.suspend_customer_account(p_account_id uuid, p_reason text)
returns void language sql volatile security definer set search_path = public
as $fn$ select public.change_customer_account_status(p_account_id, 'suspended', p_reason); $fn$;
create or replace function public.reinstate_customer_account(p_account_id uuid, p_reason text)
returns void language sql volatile security definer set search_path = public
as $fn$ select public.change_customer_account_status(p_account_id, 'approved', p_reason); $fn$;

revoke all on function public.reject_customer_account(uuid, text), public.suspend_customer_account(uuid, text), public.reinstate_customer_account(uuid, text) from public, anon;
grant execute on function public.reject_customer_account(uuid, text), public.suspend_customer_account(uuid, text), public.reinstate_customer_account(uuid, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 8. What a customer can read. Every function re-checks the account on every call,
--    so a suspension or rejection takes effect on the very next request. Ownership
--    comes from the verified link, never from anything the client sends.
-- -----------------------------------------------------------------------------
create or replace function public.my_customer_account()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select jsonb_build_object('status', a.status, 'fullName', a.full_name, 'requestedAt', a.requested_at, 'reviewedAt', a.reviewed_at)
    from public.customer_accounts a
   where a.auth_user_id = auth.uid();
$fn$;
revoke all on function public.my_customer_account() from public, anon;
grant execute on function public.my_customer_account() to authenticated;

-- Private catalog: approved accounts only. No cost, no exact stock.
create or replace function public.customer_catalog()
returns table (id text, name text, description text, category text, size text, durability text, surface_type text,
               is_wholesale boolean, selling_price numeric, image_url text, in_stock boolean)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  perform public.require_approved_customer();
  return query
    select p.id, p.name, p.description, p.category::text, p.size, p.durability, p.surface_type,
           p.is_wholesale, p.selling_price, p.image_url, (p.stock > 0)
      from public.products p
     where p.is_active
     order by p.name, p.id;
end;
$fn$;
revoke all on function public.customer_catalog() from public, anon;
grant execute on function public.customer_catalog() to authenticated;

-- Own orders only (matched through the verified customer link). Withheld: cost, profit,
-- commission, the marketing officer, delivery/internal notes, who recorded a payment.
create or replace function public.my_orders()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_customer text := public.require_approved_customer();
begin
  return coalesce((
    select jsonb_agg(x.obj order by x.order_date desc, x.created_at desc, x.id)
      from (
        select o.order_date, o.created_at, o.id,
               jsonb_build_object(
                 'id', o.id, 'status', o.status::text, 'paymentStatus', o.payment_status::text, 'orderType', o.order_type::text,
                 'date', o.order_date, 'total', o.total, 'amountPaid', o.amount_paid, 'outstandingBalance', o.outstanding_balance,
                 'deliveredAt', o.delivered_at,
                 'items', coalesce((select jsonb_agg(jsonb_build_object('productName', i.product_name, 'designName', i.design_name,
                                                                         'quantity', i.quantity, 'unitPrice', i.actual_unit_price, 'lineTotal', i.line_revenue)
                                                     order by i.created_at, i.id)
                                      from public.order_items i where i.order_id = o.id), '[]'::jsonb),
                 'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'paymentDate', p.payment_date, 'amount', p.amount,
                                                                            'paymentMethod', p.payment_method, 'reference', p.reference)
                                                        order by p.payment_date, p.created_at, p.id)
                                         from public.payments p where p.order_id = o.id), '[]'::jsonb)
               ) as obj
          from public.orders o
         where o.customer_id = v_customer
      ) x
  ), '[]'::jsonb);
end;
$fn$;
revoke all on function public.my_orders() from public, anon;
grant execute on function public.my_orders() to authenticated;

commit;
