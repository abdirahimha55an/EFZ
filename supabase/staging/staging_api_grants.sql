-- ============================================================================
-- EFZ - STAGING API GRANTS  (STAGING ONLY - NEVER RUN IN PRODUCTION)
-- ----------------------------------------------------------------------------
-- Why this exists
--   Migrations 01-09 never GRANT table privileges to the API roles. They rely
--   on Supabase granting every new table and view to anon, authenticated and
--   service_role automatically, as older projects (including EFZ production)
--   did. EFZ-Staging was created without those automatic grants, so every
--   request as anon or a signed-in user fails with
--       permission denied for table ...
--   before RLS is even consulted - for legitimate actions too.
--
-- What it does
--   Gives EFZ-Staging the table-level privileges production gets by default,
--   so that RLS - not a missing GRANT - is what decides each request, exactly
--   as in production. It grants SELECT/INSERT/UPDATE/DELETE on the existing
--   public tables and views; Row Level Security still filters every row.
--
-- What it does NOT do
--   * No function grants. Function access stays exactly as 02/03/05/07 left
--     it, so no revoke made by those files is undone.
--   * No TRUNCATE/REFERENCES/TRIGGER privileges, which the API never uses.
--   * No data changes of any kind.
--
-- Safety
--   Refuses to run unless every profile is a synthetic @example.com account,
--   so it aborts in production before granting anything.
--   Idempotent: granting an existing privilege again is a no-op.
--
-- Order: run after 07 and before the security checks / 08. 08 then REVOKEs
-- anon's access to products and the reporting views, as it will in production.
-- ============================================================================

do $guard$
begin
  if not exists (select 1 from public.profiles) then
    raise exception 'STAGING API GRANTS ABORTED: no profiles found. Load staging_test_data.sql first.';
  end if;

  if exists (select 1 from public.profiles where email not like '%@example.com') then
    raise exception 'STAGING API GRANTS ABORTED: non-synthetic profiles found. This script only runs in EFZ-Staging.';
  end if;
end
$guard$;

grant usage on schema public to anon, authenticated, service_role;

-- ON ALL TABLES covers views as well as tables.
grant select, insert, update, delete on all tables in schema public
  to anon, authenticated, service_role;

-- Read-back: how many public tables/views each role can now select from.
select r.role,
       count(*) filter (where c.relkind = 'r') as tables_selectable,
       count(*) filter (where c.relkind = 'v') as views_selectable
  from (values ('anon'), ('authenticated'), ('service_role')) as r(role)
  cross join pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relkind in ('r', 'v')
   and has_table_privilege(r.role, c.oid, 'select')
 group by r.role
 order by r.role;
