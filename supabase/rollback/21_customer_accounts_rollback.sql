-- =============================================================================
-- 21 ROLLBACK - customer accounts
-- -----------------------------------------------------------------------------
-- REFUSES while any customer account exists (rolling back would destroy the
-- registrations and their approval history, which cannot be recreated).
-- Restores the auth-linking functions and reserved_permissions() exactly as 08
-- defined them. NOTE: that restores the old rule that a confirmed sign-up with no
-- matching profile gets an INACTIVE staff profile - the reason migration 21 exists.
-- Does not touch customers or orders. Only the permission row for this feature is
-- removed (its user_permissions rows go with it).
-- =============================================================================
begin;
set local lock_timeout = '30s';

do $guard$
begin
  if to_regclass('public.customer_accounts') is not null and exists (select 1 from public.customer_accounts) then
    raise exception 'ROLLBACK REFUSED: customer_accounts holds % row(s). Suspend or reject them and export the history first.',
      (select count(*) from public.customer_accounts);
  end if;
end
$guard$;

drop function if exists public.my_orders();
drop function if exists public.customer_catalog();
drop function if exists public.my_customer_account();
drop function if exists public.reinstate_customer_account(uuid, text);
drop function if exists public.suspend_customer_account(uuid, text);
drop function if exists public.reject_customer_account(uuid, text);
drop function if exists public.change_customer_account_status(uuid, text, text);
drop function if exists public.approve_customer_account(uuid, text, boolean, boolean, text);
drop function if exists public.find_customers_for_account(uuid);
drop function if exists public.register_customer_account(uuid, text, text, text, text, text);
drop function if exists public.customer_registration_check(text, text, text);
drop function if exists public.customer_registration_limits(text, text);
drop function if exists public.require_approved_customer();
drop function if exists public.customer_account_log(public.customer_accounts, text, text, text, text, text, jsonb);

drop table if exists public.customer_account_events;
drop table if exists public.customer_accounts;
drop function if exists public.guard_customer_accounts_write();
drop function if exists public.guard_customer_account_events();

delete from public.permissions where code = 'manage_customer_accounts';

-- Restored exactly as defined in 08_security_hardening.sql
create or replace function public.reserved_permissions()
returns text[]
language sql
immutable
set search_path = public
as $fn$
  select array['manage_users', 'manage_system', 'change_settings'];
$fn$;

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

commit;
