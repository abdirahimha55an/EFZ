-- EFZ - rollback of 14_settings_super_admin_only.sql: restores the two previous settings write policies
-- (has_permission('change_settings')). Only needed if 14 must be undone.
begin;

drop policy if exists settings_update on public.settings;
create policy settings_update on public.settings
  for update to authenticated
  using (public.has_permission('change_settings'::text))
  with check (public.has_permission('change_settings'::text));

drop policy if exists settings_insert on public.settings;
create policy settings_insert on public.settings
  for insert to authenticated
  with check (public.has_permission('change_settings'::text));

commit;
