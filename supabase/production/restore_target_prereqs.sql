-- ============================================================================
-- EFZ - RESTORE DRILL TARGET PREREQUISITES
-- RUN ONLY AGAINST THE DISPOSABLE LOCAL DRILL DATABASE (localhost:54331,
-- database efz_restore_drill). NEVER against Production or EFZ-Staging.
-- ----------------------------------------------------------------------------
-- Creates the Supabase role names the dump's GRANT / DEFAULT PRIVILEGES
-- statements refer to (as plain NOLOGIN roles with no rights of their own), the
-- extensions schema, and the auth helper the dump expects. Owners are not
-- restored (pg_restore --no-owner), so nothing here grants any real access.
-- ============================================================================
\set ON_ERROR_STOP on

-- Hard guard: refuse anything that is not the local drill database.
do $guard$
begin
  if current_database() <> 'efz_restore_drill'
     or coalesce(host(inet_server_addr()), 'local') not in ('127.0.0.1', '::1', 'local') then
    raise exception 'REFUSED: this is not the local efz_restore_drill database';
  end if;
end
$guard$;

do $roles$
declare
  r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'authenticator', 'supabase_admin',
                           'supabase_auth_admin', 'supabase_storage_admin', 'dashboard_user', 'pgbouncer',
                           'supabase_realtime_admin', 'supabase_replication_admin', 'supabase_read_only_user']
  loop
    if not exists (select 1 from pg_roles where rolname = r) then
      execute format('create role %I nologin', r);
    end if;
  end loop;
end
$roles$;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
