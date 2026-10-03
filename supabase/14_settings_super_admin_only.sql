-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 14 : Global company settings are Super Admin only (2026-10-03)
-- ----------------------------------------------------------------------------
-- Run AFTER 01..05, 07..13. Idempotent: safe to re-run. Apply to EFZ-Staging first.
--
-- WHY
--   The single-row public.settings table holds the company-wide configuration
--   (business name, short name, WhatsApp order phone, contact email, logo,
--   favicon, brand colours, theme, stock threshold, currency). Until now its
--   write policies used has_permission('change_settings'), which is true for the
--   Super Admin OR for any user the Super Admin grants change_settings to.
--   Requirement: ONLY a Super Admin may change company settings - a grant of
--   change_settings must not open them to anyone else.
--
-- WHAT
--   Replaces exactly two RLS policies on public.settings:
--     settings_update  USING / WITH CHECK  has_permission('change_settings')  ->  is_super_admin()
--     settings_insert  WITH CHECK          has_permission('change_settings')  ->  is_super_admin()
--   Nothing else changes: settings_select (everyone may read - the public site
--   needs the brand), no delete policy (deletes stay refused), the change_settings
--   permission itself, testimonials_write and every other policy/function.
--
-- WHY IT IS SAFE
--   * is_super_admin() already exists (SECURITY DEFINER, STABLE, fixed search_path)
--     and already guards order deletion: the caller's own JWT (auth.uid()) must
--     map to an ACTIVE profile whose role is 'Super Admin'.
--   * Nobody can make themselves a Super Admin: guard_profiles_write lets only a
--     Super Admin create/promote/modify a Super Admin, and auth_user_id cannot be
--     set or changed by a client.
--   * The Super Admin already passed has_permission() for every permission, so the
--     Super Admin keeps exactly the access it had; only non-Super-Admin holders of
--     change_settings lose write access to company settings.
--
-- Rollback: supabase/rollback/14_rollback.sql (restores the two previous policies).
-- ============================================================================

begin;

drop policy if exists settings_update on public.settings;
create policy settings_update on public.settings
  for update to authenticated
  using (public.is_super_admin())
  with check (public.is_super_admin());

drop policy if exists settings_insert on public.settings;
create policy settings_insert on public.settings
  for insert to authenticated
  with check (public.is_super_admin());

commit;
