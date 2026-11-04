-- ============================================================================
-- EFZ - ROLLBACK of 30_public_inquiries.sql
-- ----------------------------------------------------------------------------
-- Removes the inquiry tables, the seven inquiry functions, the four inquiry
-- permissions (and any grant of them) and the realtime publication entry.
-- Touches nothing else: no order, request, customer, product or payment object.
--
-- REFUSES (changes nothing) when inquiries exist: they are visitor-submitted
-- records. From then on the safe path is an app rollback (the forms then fail
-- with a friendly message) plus a forward fix, not dropping the data.
-- To discard test inquiries on EFZ-Staging deliberately, delete them first
-- as the table owner (the append-only triggers allow row deletion only
-- together with the inquiry).
-- ============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
begin
  if to_regclass('public.public_inquiries') is null then
    raise exception '30 rollback: 30 is not applied - nothing to roll back';
  end if;
  if exists (select 1 from public.public_inquiries) then
    raise exception '30 rollback REFUSED: inquiries exist - use an app rollback plus a forward fix';
  end if;
end
$pre$;

do $rt$
begin
  if exists (select 1 from pg_publication_tables
              where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'public_inquiries') then
    alter publication supabase_realtime drop table public.public_inquiries;
  end if;
end
$rt$;

drop function if exists public.submit_public_inquiry(jsonb);
drop function if exists public.set_public_inquiry_status(uuid, text, text);
drop function if exists public.add_public_inquiry_note(uuid, text);
drop function if exists public.edit_public_inquiry_note(uuid, text);
drop function if exists public.assign_public_inquiry(uuid, text);
drop function if exists public.public_inquiry_assignees();

drop table if exists public.public_inquiry_events;
drop table if exists public.public_inquiry_notes;
drop table if exists public.public_inquiries;

drop function if exists public.can_access_public_inquiry(text);
drop function if exists public.guard_public_inquiry_child();

delete from public.user_permissions
 where permission_code in ('view_inquiries', 'view_all_inquiries', 'manage_inquiries', 'assign_inquiries');
delete from public.permissions
 where code in ('view_inquiries', 'view_all_inquiries', 'manage_inquiries', 'assign_inquiries');

do $post$
declare
  v_problem text;
begin
  select string_agg(x, ', ') into v_problem from (
    select 'table ' || t as x from unnest(array['public_inquiries', 'public_inquiry_notes', 'public_inquiry_events']) t
     where to_regclass('public.' || t) is not null
    union all
    select 'function ' || p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('submit_public_inquiry', 'set_public_inquiry_status', 'add_public_inquiry_note',
                                                  'edit_public_inquiry_note', 'assign_public_inquiry', 'public_inquiry_assignees',
                                                  'can_access_public_inquiry', 'guard_public_inquiry_child')
    union all
    select 'permission ' || code from public.permissions
     where code in ('view_inquiries', 'view_all_inquiries', 'manage_inquiries', 'assign_inquiries')
    union all
    select 'the website request pipeline is gone' where to_regprocedure('public.submit_order_request(jsonb)') is null
  ) q;
  if v_problem is not null then
    raise exception '30 rollback post-check failed: % - aborting', v_problem;
  end if;
  raise notice '30 rollback: public inquiries removed';
end
$post$;

commit;
