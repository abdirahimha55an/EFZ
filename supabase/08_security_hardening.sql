-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 8 : Security hardening (2026-09-26)
-- ----------------------------------------------------------------------------
-- Run AFTER 01..05 and 07. Idempotent: safe to re-run. It adds guards, it does
-- not touch a single existing row - no UPDATE, DELETE or TRUNCATE of business
-- data appears anywhere below.
--
-- It redefines objects created by 02, 03 and 04. If any earlier file is ever
-- re-run, re-run every later file too, in order.
--
-- What it fixes:
--   1. A signed-in user could rewrite their own role/status/commission rate
--      and become Super Admin (profiles_update had no column restriction).
--   2. A manage_users holder who was not a Super Admin could grant themselves
--      any permission, and edit or delete a Super Admin.
--   3. anon could read products.cost_price and exact stock straight from the
--      products table, because public_products was a security_invoker view
--      that needed a permissive anon policy underneath it.
--   4. Staff with edit_orders could write orders.total, amount_paid,
--      commission_paid, status ... directly, bypassing the triggers and RPCs.
--      Direct writes to order_items, payments, stock_movements and the
--      commission ledger were side doors to the same numbers.
--   5. Any user could write audit lines in someone else's name, and edit or
--      target notifications at will. settings.updated_by and
--      backups.created_by were caller-supplied too.
--   6. The public order form accepted status, handled_by, converted_order_id.
--   7. A self-signup was linked to a staff profile by email before anyone had
--      proved they own that mailbox.
--   8. A suspended (inactive) account still saw its own orders, commissions
--      and every broadcast notification.
--   9. upsert_issue() and two recalculation helpers are SECURITY DEFINER with
--      no permission check, and Supabase grants new functions to
--      authenticated by default - any account could forge diagnostics.
--
-- How "trusted" is decided
-- ------------------------
-- Browsers reach Postgres through PostgREST as the `anon` or `authenticated`
-- role. Inside a SECURITY DEFINER function (every RPC and ledger trigger in
-- 02_functions.sql) current_user is the function owner instead. So the guards
-- below only restrict statements issued as a client role; the RPCs, the
-- triggers, service_role and the SQL editor keep working exactly as before.
--
-- Every SECURITY DEFINER function here pins search_path and schema-qualifies
-- every table it touches.
-- ============================================================================

-- ============================================================================
-- 0. HELPERS
-- ============================================================================

-- SECURITY INVOKER on purpose: a definer function would always see its owner.
create or replace function public.is_client_request()
returns boolean
language sql
stable
set search_path = public
as $fn$
  select current_user in ('anon', 'authenticated', 'authenticator');
$fn$;

-- True only for a signed-in user with an active staff profile. A self-signup
-- gets an inactive profile, so this is what separates "staff" from "anyone
-- who created an Auth account".
create or replace function public.is_active_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1 from public.profiles p
     where p.auth_user_id = auth.uid()
       and p.status = 'active'
  );
$fn$;

-- Redefined from 02_functions.sql: a suspended account no longer has a
-- profile id as far as RLS is concerned, so every "own row" policy
-- (orders, commissions, payouts, notifications) stops matching for it.
-- Every RPC that uses this for attribution already requires an active user.
create or replace function public.current_profile_id()
returns text
language sql
stable
security definer
set search_path = public
as $fn$
  select p.id
    from public.profiles p
   where p.auth_user_id = auth.uid()
     and p.status = 'active'
   limit 1;
$fn$;

create or replace function public.current_profile_name()
returns text
language sql
stable
security definer
set search_path = public
as $fn$
  select p.name from public.profiles p
   where p.auth_user_id = auth.uid() and p.status = 'active'
   limit 1;
$fn$;

-- Whether a given profile holds a permission. A Super Admin holds them all.
create or replace function public.user_holds_permission(p_user_id text, p_perm text)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1 from public.profiles p
     where p.id = p_user_id
       and (
         p.role = 'Super Admin'
         or exists (
           select 1 from public.user_permissions up
            where up.user_id = p.id and up.permission_code = p_perm
         )
       )
  );
$fn$;

-- Permissions that amount to administering the system itself. Only a Super
-- Admin may grant or revoke them:
--   manage_users    - creates accounts and hands out permissions
--   manage_system   - backups (a copy of every table), repairs, notifications
--   change_settings - the public site's branding, WhatsApp number and email
create or replace function public.reserved_permissions()
returns text[]
language sql
immutable
set search_path = public
as $fn$
  select array['manage_users', 'manage_system', 'change_settings'];
$fn$;

-- The subset of p_cols whose value differs between two row images.
create or replace function public.changed_columns(p_old jsonb, p_new jsonb, p_cols text[])
returns text[]
language sql
immutable
set search_path = public
as $fn$
  select coalesce(array_agg(c order by c), array[]::text[])
    from unnest(p_cols) as c
   where p_old -> c is distinct from p_new -> c;
$fn$;

-- is_client_request() and changed_columns() stay executable by anon: the
-- guard triggers call them while running as whoever issued the statement,
-- and anon inserts order_requests. Neither reveals anything.
revoke all on function public.is_active_staff()                   from public, anon;
revoke all on function public.current_profile_id()                from public, anon;
revoke all on function public.current_profile_name()              from public, anon;
revoke all on function public.user_holds_permission(text, text)   from public, anon;
revoke all on function public.reserved_permissions()              from public, anon;
grant execute on function public.is_active_staff()                   to authenticated;
grant execute on function public.current_profile_id()                to authenticated;
grant execute on function public.current_profile_name()              to authenticated;
grant execute on function public.user_holds_permission(text, text)   to authenticated;
grant execute on function public.reserved_permissions()              to authenticated;

-- Internal SECURITY DEFINER helpers with no permission check of their own.
-- They are only ever meant to be called by the triggers and RPCs (which run
-- as the owner and so keep their access). Supabase grants every new function
-- to anon and authenticated, so take that away.
revoke all on function public.recalc_order_financials(text)           from public, anon, authenticated;
revoke all on function public.refresh_profile_commission_totals(text) from public, anon, authenticated;
revoke all on function public.upsert_issue(
  text, integer, text, public.log_severity, text, text, text, text, text, boolean
) from public, anon, authenticated;

-- ============================================================================
-- 1. PROFILES - a role hierarchy with Super Admin at the top
-- ----------------------------------------------------------------------------
-- profiles_update still lets a user edit their own name, email, phone and
-- avatar. This trigger decides everything else a client may change:
--   * id, auth_user_id, *_commission_total      -> never (link trigger/ledger)
--   * a Super Admin's row                        -> Super Admin only
--   * role, status, commission_percentage        -> manage_users, and for a
--                                                   non-Super-Admin never on
--                                                   their own row or on another
--                                                   user manager's row
--   * granting the Super Admin role              -> Super Admin only
--   * removing the last active Super Admin       -> nobody
-- ============================================================================

create or replace function public.guard_profiles_write()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_is_super   boolean;
  v_locked     text[];
  v_privileged text[];
begin
  if not public.is_client_request() then
    return new;
  end if;

  v_is_super := public.is_super_admin();

  if tg_op = 'INSERT' then
    if new.auth_user_id is not null
       or new.earned_commission_total  <> 0
       or new.pending_commission_total <> 0
       or new.paid_commission_total    <> 0 then
      raise exception 'auth_user_id and commission totals cannot be set by a client'
        using errcode = '42501';
    end if;

    if new.role = 'Super Admin' and not v_is_super then
      raise exception 'Only a Super Admin can create a Super Admin'
        using errcode = '42501';
    end if;

    return new;
  end if;

  if old.role = 'Super Admin' and not v_is_super then
    raise exception 'Only a Super Admin can modify a Super Admin account'
      using errcode = '42501';
  end if;

  v_locked := public.changed_columns(to_jsonb(old), to_jsonb(new), array[
    'id', 'auth_user_id',
    'earned_commission_total', 'pending_commission_total', 'paid_commission_total'
  ]);

  if cardinality(v_locked) > 0 then
    raise exception 'Profile field(s) % cannot be changed directly', v_locked
      using errcode = '42501';
  end if;

  v_privileged := public.changed_columns(to_jsonb(old), to_jsonb(new), array[
    'role', 'status', 'commission_percentage'
  ]);

  if cardinality(v_privileged) = 0 then
    return new;
  end if;

  if not public.has_permission('manage_users') then
    raise exception 'Changing % requires the manage_users permission', v_privileged
      using errcode = '42501';
  end if;

  if not v_is_super then
    if new.role = 'Super Admin' then
      raise exception 'Only a Super Admin can grant the Super Admin role'
        using errcode = '42501';
    end if;

    if old.id = public.current_profile_id() then
      raise exception 'You cannot change your own role, status or commission rate'
        using errcode = '42501';
    end if;

    if public.user_holds_permission(old.id, 'manage_users') then
      raise exception 'Only a Super Admin can change the role, status or commission rate of another user manager'
        using errcode = '42501';
    end if;
  end if;

  if old.role = 'Super Admin' and old.status = 'active'
     and (new.role <> 'Super Admin' or new.status <> 'active')
     and not exists (
       select 1 from public.profiles p
        where p.id <> old.id and p.role = 'Super Admin' and p.status = 'active'
     ) then
    raise exception 'This is the last active Super Admin. Promote someone else first.'
      using errcode = '42501';
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_profiles_guard on public.profiles;
create trigger trg_profiles_guard
  before insert or update on public.profiles
  for each row execute function public.guard_profiles_write();

-- profiles_delete already needs manage_users and forbids deleting yourself.
create or replace function public.guard_profiles_delete()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if not public.is_client_request() then
    return old;
  end if;

  if not public.is_super_admin() then
    if old.role = 'Super Admin' then
      raise exception 'Only a Super Admin can delete a Super Admin account'
        using errcode = '42501';
    end if;

    if public.user_holds_permission(old.id, 'manage_users') then
      raise exception 'Only a Super Admin can delete another user manager'
        using errcode = '42501';
    end if;
  end if;

  if old.role = 'Super Admin' and old.status = 'active'
     and not exists (
       select 1 from public.profiles p
        where p.id <> old.id and p.role = 'Super Admin' and p.status = 'active'
     ) then
    raise exception 'This is the last active Super Admin and cannot be deleted'
      using errcode = '42501';
  end if;

  return old;
end;
$fn$;

drop trigger if exists trg_profiles_guard_delete on public.profiles;
create trigger trg_profiles_guard_delete
  before delete on public.profiles
  for each row execute function public.guard_profiles_delete();

-- A self-signup is authenticated but inactive. It may read its own row (the
-- login page needs that to say "suspended"), not the whole staff directory.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (auth_user_id = auth.uid() or public.is_active_staff());

drop policy if exists user_permissions_select on public.user_permissions;
create policy user_permissions_select on public.user_permissions
  for select to authenticated
  using (user_id = public.current_profile_id() or public.is_active_staff());

-- ============================================================================
-- 2. PERMISSIONS - you can only hand out what you hold
-- ----------------------------------------------------------------------------
-- set_user_permissions() is redefined with the same signature and the same
-- replace-the-whole-set behaviour. For a caller who is not a Super Admin, the
-- codes it would ADD or REMOVE (resending unchanged codes is always fine, so
-- the user-edit form keeps working) must satisfy all of:
--   * the target is not a Super Admin
--   * the target is not the caller
--   * the target does not hold manage_users (only a Super Admin manages
--     the people who manage users)
--   * no reserved permission is involved (see reserved_permissions())
--   * the caller holds every one of those codes themselves
-- grant_role_preset() calls this function, so it inherits every rule.
--
-- Direct writes to user_permissions become Super Admin only; the app already
-- goes through the RPC.
-- ============================================================================

create or replace function public.set_user_permissions(
  p_user_id text,
  p_codes   text[]
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_codes    text[] := coalesce(p_codes, array[]::text[]);
  v_role     public.user_role;
  v_current  text[];
  v_delta    text[];
  v_reserved text[];
  v_not_held text[];
begin
  perform public.require_permission('manage_users');

  select role into v_role from public.profiles where id = p_user_id;
  if not found then
    raise exception 'Unknown user: %', p_user_id;
  end if;

  -- auth.uid() is null for service_role and the SQL editor: already trusted.
  if auth.uid() is not null and not public.is_super_admin() then
    select coalesce(array_agg(permission_code), array[]::text[])
      into v_current
      from public.user_permissions
     where user_id = p_user_id;

    select coalesce(array_agg(distinct c), array[]::text[])
      into v_delta
      from (
        select c from unnest(v_codes) as c
         where c <> all(v_current)
           and exists (select 1 from public.permissions where code = c)
        union
        select c from unnest(v_current) as c
         where c <> all(v_codes)
      ) changes;

    if cardinality(v_delta) > 0 then
      if v_role = 'Super Admin' then
        raise exception 'Only a Super Admin can change a Super Admin''s permissions'
          using errcode = '42501';
      end if;

      if p_user_id = public.current_profile_id() then
        raise exception 'You cannot change your own permissions'
          using errcode = '42501';
      end if;

      if 'manage_users' = any(v_current) then
        raise exception 'Only a Super Admin can change the permissions of another user manager'
          using errcode = '42501';
      end if;

      select coalesce(array_agg(c), array[]::text[]) into v_reserved
        from unnest(v_delta) as c
       where c = any(public.reserved_permissions());

      if cardinality(v_reserved) > 0 then
        raise exception '% can only be granted or revoked by a Super Admin', v_reserved
          using errcode = '42501';
      end if;

      select coalesce(array_agg(c), array[]::text[]) into v_not_held
        from unnest(v_delta) as c
       where not public.has_permission(c);

      if cardinality(v_not_held) > 0 then
        raise exception 'You cannot grant or revoke permissions you do not hold yourself: %', v_not_held
          using errcode = '42501';
      end if;
    end if;
  end if;

  delete from public.user_permissions
   where user_id = p_user_id
     and permission_code <> all(v_codes);

  insert into public.user_permissions (user_id, permission_code)
  select p_user_id, code
    from public.permissions
   where code = any(v_codes)
  on conflict do nothing;
end;
$fn$;

revoke all on function public.set_user_permissions(text, text[]) from public, anon;
grant execute on function public.set_user_permissions(text, text[]) to authenticated;

drop policy if exists user_permissions_write on public.user_permissions;
create policy user_permissions_write on public.user_permissions
  for all to authenticated
  using (public.is_super_admin())
  with check (public.is_super_admin());

-- ============================================================================
-- 3. AUTH LINKING - only a proven mailbox may claim a staff profile
-- ----------------------------------------------------------------------------
-- The old trigger linked on INSERT into auth.users, i.e. at sign-up, before
-- the email was confirmed. Anyone could sign up with a staff member's email
-- and squat their profile. Now a link happens only when the account was
-- created by an admin (dashboard "Add user" with auto-confirm, or an invite)
-- or once the owner confirms the address.
-- ============================================================================

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

  select id, auth_user_id into v_profile_id, v_linked_to
    from public.profiles
   where lower(email) = lower(p_email)
   limit 1;

  if v_profile_id is not null then
    -- Never move a profile that already belongs to another auth account.
    if v_linked_to is null then
      update public.profiles
         set auth_user_id = p_auth_id,
             updated_at   = now()
       where id = v_profile_id;
    end if;
  else
    insert into public.profiles (id, auth_user_id, name, email, role, status)
    values (
      'u-' || replace(p_auth_id::text, '-', ''),
      p_auth_id,
      coalesce(nullif(p_meta ->> 'name', ''), split_part(p_email, '@', 1)),
      p_email,
      'Marketing Officer',
      'inactive'
    )
    on conflict do nothing;
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
  perform public.link_auth_user_to_profile(new.id, new.email, new.raw_user_meta_data);
  return new;
end;
$fn$;

drop trigger if exists trg_on_auth_user_created on auth.users;
create trigger trg_on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

drop trigger if exists trg_on_auth_user_confirmed on auth.users;
create trigger trg_on_auth_user_confirmed
  after update of email_confirmed_at on auth.users
  for each row
  when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
  execute function public.handle_auth_user_confirmed();

-- ============================================================================
-- 4. PRODUCTS - the public sees the catalogue, never the cost sheet
-- ----------------------------------------------------------------------------
-- public_products becomes an owner-rights view: it reads products as its
-- owner, so anon needs no access to the table at all. Its column list (no
-- cost_price, stock reduced to in_stock) is then the whole public surface.
-- Supabase's security advisor will flag it as a "security definer view";
-- that is intended here and is the reason for the revokes that follow.
--
-- Because the view is simple enough to be auto-updatable and now runs with
-- the owner's rights, every privilege except SELECT is revoked from it -
-- otherwise anon could UPDATE products through the view.
-- ============================================================================

alter view public.public_products set (security_invoker = false);

revoke all    on public.public_products from public, anon, authenticated;
grant  select on public.public_products to anon, authenticated;

drop policy if exists products_select_public on public.products;
revoke all on table public.products from anon;

-- Reporting views run with the caller's rights, and anon now has nothing
-- underneath them - but Supabase grants anon every new view by default, so
-- take them away explicitly rather than relying on that.
revoke all on public.order_details,
              public.inventory_status,
              public.customer_financials,
              public.officer_commission_summary,
              public.financial_summary,
              public.daily_sales,
              public.product_sales
  from anon;

-- cost_price was also visible to any authenticated account, including an
-- inactive self-signup.
drop policy if exists products_select_staff on public.products;
create policy products_select_staff on public.products
  for select to authenticated
  using (public.is_active_staff());

-- Stock moves only through create_order / update_order_status / adjust_stock,
-- each of which writes the stock_movements ledger. The app already creates
-- products with stock 0 and never writes stock in products.update().
create or replace function public.guard_products_write()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if not public.is_client_request() then
    return new;
  end if;

  if tg_op = 'INSERT' and new.stock <> 0 then
    raise exception 'Create products with stock 0, then use adjust_stock()'
      using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' and new.stock is distinct from old.stock then
    raise exception 'Stock changes must go through adjust_stock()'
      using errcode = '42501';
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_products_guard on public.products;
create trigger trg_products_guard
  before insert or update on public.products
  for each row execute function public.guard_products_write();

-- The ledger is written by the RPCs above. A direct insert could record a
-- movement that never happened. Kept open to a Super Admin for corrections.
drop policy if exists stock_movements_insert on public.stock_movements;
create policy stock_movements_insert on public.stock_movements
  for insert to authenticated
  with check (public.is_super_admin());

-- ============================================================================
-- 5. ORDERS - money columns belong to the triggers and RPCs
-- ----------------------------------------------------------------------------
-- A client may still edit an order's metadata (delivery_notes, phone,
-- customer_name, customer_id, order_type, order_date). Everything derived or
-- workflow-controlled is refused. Reassigning the marketing officer moves
-- commission, so it needs a Super Admin.
-- ============================================================================

create or replace function public.guard_orders_write()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_locked text[];
begin
  if not public.is_client_request() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.total <> 0 or new.cost <> 0 or new.gross_profit <> 0
       or new.amount_paid <> 0 or new.outstanding_balance <> 0
       or new.commission_paid
       or new.payment_status <> 'unpaid'
       or new.status <> 'pending' then
      raise exception 'Orders are created through create_order()'
        using errcode = '42501';
    end if;

    new.created_by := public.current_profile_id();
    return new;
  end if;

  v_locked := public.changed_columns(to_jsonb(old), to_jsonb(new), array[
    'id', 'status', 'payment_status',
    'total', 'cost', 'gross_profit', 'amount_paid', 'outstanding_balance',
    'commission_paid', 'created_by', 'created_at',
    'legacy_order_ids', 'legacy_reference_id'
  ]);

  if cardinality(v_locked) > 0 then
    raise exception 'Order field(s) % are maintained by the database and cannot be written directly', v_locked
      using errcode = '42501';
  end if;

  if new.marketing_officer_id is distinct from old.marketing_officer_id
     and not public.is_super_admin() then
    raise exception 'Only a Super Admin can reassign an order''s marketing officer'
      using errcode = '42501';
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_orders_guard on public.orders;
create trigger trg_orders_guard
  before insert or update on public.orders
  for each row execute function public.guard_orders_write();

-- Order lines drive total/cost/profit and stock. create_order() is the normal
-- path; direct edits stay available to a Super Admin for corrections, as
-- payments already were.
drop policy if exists order_items_write on public.order_items;
create policy order_items_write on public.order_items
  for all to authenticated
  using (public.is_super_admin())
  with check (public.is_super_admin());

-- record_payment() is the path that refuses overpayment. A direct insert
-- skipped that check and let the caller choose recorded_by.
drop policy if exists payments_insert on public.payments;
create policy payments_insert on public.payments
  for insert to authenticated
  with check (public.is_super_admin());

-- commission_paid mirrors the ledger, so the ledger itself must be guarded.
-- pay_commissions() is the path; it creates the payout and marks rows paid in
-- one transaction.
drop policy if exists commissions_update on public.commissions;
create policy commissions_update on public.commissions
  for update to authenticated
  using (public.is_super_admin())
  with check (public.is_super_admin());

drop policy if exists commission_payouts_insert on public.commission_payouts;
create policy commission_payouts_insert on public.commission_payouts
  for insert to authenticated
  with check (public.is_super_admin());

-- ============================================================================
-- 6. AUDIT IDENTITY - who did it comes from the session, not the request
-- ============================================================================

create or replace function public.guard_system_logs_insert()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if public.is_client_request() then
    new.user_id     := public.current_profile_id();
    new.username    := coalesce(public.current_profile_name(), '');
    new.occurred_at := now();
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_system_logs_guard on public.system_logs;
create trigger trg_system_logs_guard
  before insert on public.system_logs
  for each row execute function public.guard_system_logs_insert();

drop policy if exists system_logs_insert on public.system_logs;
create policy system_logs_insert on public.system_logs
  for insert to authenticated
  with check (public.is_active_staff());

create or replace function public.stamp_settings_actor()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if public.is_client_request() then
    new.updated_by := public.current_profile_id();
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_settings_actor on public.settings;
create trigger trg_settings_actor
  before insert or update on public.settings
  for each row execute function public.stamp_settings_actor();

create or replace function public.stamp_backups_actor()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if public.is_client_request() then
    new.created_by := public.current_profile_id();
    new.created_at := now();
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_backups_actor on public.backups;
create trigger trg_backups_actor
  before insert on public.backups
  for each row execute function public.stamp_backups_actor();

-- ============================================================================
-- 7. NOTIFICATIONS - active staff only; recipients may only mark them read
-- ============================================================================

drop policy if exists notifications_select on public.notifications;
create policy notifications_select on public.notifications
  for select to authenticated
  using (
    public.is_active_staff()
    and (user_id is null or user_id = public.current_profile_id())
  );

drop policy if exists notifications_update on public.notifications;
create policy notifications_update on public.notifications
  for update to authenticated
  using (
    public.is_active_staff()
    and (user_id is null or user_id = public.current_profile_id())
  )
  with check (
    public.is_active_staff()
    and (user_id is null or user_id = public.current_profile_id())
  );

-- Anyone may raise a broadcast (the admin layout writes derived stock/order
-- alerts); only manage_system may address one to another person.
drop policy if exists notifications_insert on public.notifications;
create policy notifications_insert on public.notifications
  for insert to authenticated
  with check (
    public.is_active_staff()
    and (
      user_id is null
      or user_id = public.current_profile_id()
      or public.has_permission('manage_system')
    )
  );

-- Marking read is the only edit a recipient makes. Rewriting the title or
-- message of a broadcast everyone sees needs manage_system.
create or replace function public.guard_notifications_update()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v_changed text[];
begin
  if not public.is_client_request() then
    return new;
  end if;

  v_changed := public.changed_columns(to_jsonb(old), to_jsonb(new), array[
    'id', 'title', 'message', 'type', 'user_id', 'created_at'
  ]);

  if cardinality(v_changed) > 0 and not public.has_permission('manage_system') then
    raise exception 'Only the read flag of a notification can be changed'
      using errcode = '42501';
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_notifications_guard on public.notifications;
create trigger trg_notifications_guard
  before update on public.notifications
  for each row execute function public.guard_notifications_update();

-- ============================================================================
-- 8. PUBLIC ORDER REQUESTS - a new request with public fields, nothing else
-- ============================================================================

drop policy if exists order_requests_insert_public on public.order_requests;
create policy order_requests_insert_public on public.order_requests
  for insert to anon, authenticated
  with check (
    status = 'new'
    and converted_order_id is null
    and handled_by is null
    and char_length(btrim(customer_name)) between 1 and 200
    and char_length(btrim(phone))         between 1 and 50
    and char_length(organization)      <= 200
    and char_length(product_name)      <= 200
    and char_length(delivery_location) <= 500
    and char_length(notes)             <= 2000
    and quantity between 1 and 100000
  );

-- Staff triage requests (new -> contacted / rejected). Conversion is
-- convert_order_request()'s job: it creates the order and links it. A client
-- may not fake that link, move a request into or out of 'converted', or
-- choose who handled it.
create or replace function public.guard_order_requests_write()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if not public.is_client_request() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.created_at := now();
    new.updated_at := now();
    return new;
  end if;

  if new.converted_order_id is distinct from old.converted_order_id
     or (new.status is distinct from old.status
         and 'converted' in (old.status, new.status)) then
    raise exception 'Requests are converted through convert_order_request()'
      using errcode = '42501';
  end if;

  new.handled_by := case
    when new.status is distinct from old.status then public.current_profile_id()
    else old.handled_by
  end;

  return new;
end;
$fn$;

drop trigger if exists trg_order_requests_guard on public.order_requests;
create trigger trg_order_requests_guard
  before insert or update on public.order_requests
  for each row execute function public.guard_order_requests_write();
