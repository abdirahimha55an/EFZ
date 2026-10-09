-- ============================================================================
-- EFZ - ROLLBACK of 18b_website_request_inbox.sql
-- ----------------------------------------------------------------------------
-- Restores the exact pre-18 state of everything 18b changed and removes
-- everything it added. Run AFTER 18c's rollback (if 18c ran) and after the app
-- was rolled back. The 18a enum value 'confirmed' stays (PostgreSQL cannot drop
-- an enum value); this script verifies no row uses it.
--
-- REFUSES (changes nothing) when real website-request data would be lost:
--   any request in status confirmed or converted; any line, note or event row;
--   any initial owner set by a conversion. From then on the safe path is an app
--   rollback plus a forward-fix migration.
--
-- Updates no request row: existing requests are verified unchanged by their
-- original columns. Dropping the 5 new columns removes only their values.
-- ============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
declare
  v_blockers text;
begin
  if to_regprocedure('public.submit_order_request(jsonb)') is null then
    raise exception '18b rollback: 18b is not applied - nothing to roll back';
  end if;
  if not exists (select 1 from pg_policy where polrelid = 'public.order_requests'::regclass and polname = 'order_requests_insert_public') then
    raise exception '18b rollback: 18c is applied - run rollback/18c_rollback.sql first';
  end if;

  select string_agg(x, ', ') into v_blockers from (
    select count(*) || ' request(s) in status ' || status as x from public.order_requests
     where status in ('confirmed', 'converted') group by status
    union all select count(*) || ' line row(s)'  from public.order_request_items  having count(*) > 0
    union all select count(*) || ' note row(s)'  from public.order_request_notes  having count(*) > 0
    union all select count(*) || ' event row(s)' from public.order_request_events having count(*) > 0
    union all select count(*) || ' initial owner(s) set by conversion' from public.customer_ownership_changes
               where reason = 'Initial owner set at website-request conversion' having count(*) > 0
  ) q;
  if v_blockers is not null then
    raise exception '18b rollback REFUSED: website-request data exists (%) - use an app rollback plus a forward fix', v_blockers;
  end if;
end
$pre$;

create temp table m18_rb_requests_before on commit drop as
  select r.id,
         md5(row(r.id, r.customer_name, r.phone, r.organization, r.product_id, r.product_name, r.quantity,
                 r.delivery_location, r.notes, r.status, r.converted_order_id, r.handled_by,
                 r.created_at, r.updated_at)::text) as row_md5
    from public.order_requests r;

-- Realtime
do $rt$
begin
  if exists (select 1 from pg_publication_tables
              where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'order_requests') then
    alter publication supabase_realtime drop table public.order_requests;
  end if;
end
$rt$;

-- Policies on order_requests: the deployed originals
drop policy if exists order_requests_select on public.order_requests;
-- @@SELECT_POLICY_ORIGINAL@@
drop policy if exists order_requests_update on public.order_requests;
-- @@UPDATE_POLICY_ORIGINAL@@

-- Changed functions: the deployed originals, byte for byte
-- @@GRANT_ROLE_PRESET_ORIGINAL@@

-- @@GUARD_SYSTEM_LOGS_INSERT_ORIGINAL@@

-- Permission (its user_permissions rows go with it: FK ON DELETE CASCADE)
delete from public.permissions where code = 'manage_website_requests';

-- Added objects
drop trigger if exists trg_order_requests_legacy_admission on public.order_requests;
drop trigger if exists trg_order_requests_legacy_admission_after on public.order_requests;
drop view if exists public.order_request_lines;
drop table if exists public.order_request_items;
drop table if exists public.order_request_notes;
drop table if exists public.order_request_events;
drop table if exists public.website_request_settings;
drop index if exists public.idx_customers_phone_canonical;
drop index if exists public.idx_order_requests_new_by_phone;
drop index if exists public.order_requests_submission_key_uq;
drop index if exists public.order_requests_converted_order_uq;

drop function if exists public.order_requests_legacy_admission();
drop function if exists public.convert_website_request(uuid, jsonb);
drop function if exists public.find_customers_by_phone(uuid, text);
drop function if exists public.edit_order_request_note(uuid, text);
drop function if exists public.add_order_request_note(uuid, text);
drop function if exists public.set_order_request_status(uuid, text, text);
drop function if exists public.submit_order_request(jsonb);
drop function if exists public.website_request_admission(text, uuid);
drop function if exists public.website_request_lock_key(text);
drop function if exists public.validate_request_phone(text);
drop function if exists public.customer_phone_canonical(text);
drop function if exists public.normalize_phone(text, text);
drop function if exists public.can_access_order_request(text);
drop function if exists public.website_request_settings_stamp();
drop function if exists public.guard_order_request_child();

alter table public.order_requests drop constraint if exists order_requests_rejected_reason_check;
alter table public.order_requests drop column if exists assigned_to;
alter table public.order_requests drop column if exists status_changed_at;
alter table public.order_requests drop column if exists rejected_reason;
alter table public.order_requests drop column if exists submission_key;
alter table public.order_requests drop column if exists phone_canonical;

-- Grants: the deployed originals
grant all on public.order_requests to anon;
grant execute on function public.convert_order_request(uuid, text) to authenticated;

do $post$
declare
  v_cols     text;
  v_policies text;
  v_changed  integer;
begin
  select string_agg(attname || ':' || format_type(atttypid, atttypmod), ',' order by attnum) into v_cols
    from pg_attribute where attrelid = 'public.order_requests'::regclass and attnum > 0 and not attisdropped;
  select string_agg(polname || ':' || md5(polcmd::text
           || (select string_agg(r::text, ',' order by r::text) from unnest(polroles::regrole[]) r)
           || coalesce(pg_get_expr(polqual, polrelid), '') || coalesce(pg_get_expr(polwithcheck, polrelid), '')),
         ';' order by polname) into v_policies
    from pg_policy where polrelid = 'public.order_requests'::regclass;

  if md5(v_cols) <> '@@MD5_COLS_PRE@@' or v_policies <> '@@POLICIES_PRE@@'
     or md5(pg_get_functiondef('public.grant_role_preset(text, public.user_role)'::regprocedure)) <> '@@MD5_PRESET_PRE@@'
     or md5(pg_get_functiondef('public.guard_system_logs_insert()'::regprocedure)) <> '@@MD5_LOGS_PRE@@' then
    raise exception '18b rollback post-check: pre-18 state not restored - aborting';
  end if;

  select count(*) into v_changed
    from m18_rb_requests_before b left join public.order_requests r on r.id = b.id
   where r.id is null
      or md5(row(r.id, r.customer_name, r.phone, r.organization, r.product_id, r.product_name, r.quantity,
                 r.delivery_location, r.notes, r.status, r.converted_order_id, r.handled_by,
                 r.created_at, r.updated_at)::text) <> b.row_md5;
  if v_changed > 0 then
    raise exception '18b rollback post-check: % request(s) changed - aborting', v_changed;
  end if;
  if exists (select 1 from public.order_requests where status = 'confirmed') then
    raise exception '18b rollback post-check: a request uses confirmed - aborting';
  end if;
  raise notice '18b rollback: pre-18 state restored; % request(s) verified unchanged', (select count(*) from m18_rb_requests_before);
end
$post$;

commit;
