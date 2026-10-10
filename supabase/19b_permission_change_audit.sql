-- ============================================================================
-- EFZ 19b - permission-change audit trail
-- ============================================================================
-- Every change to public.user_permissions is recorded in public.system_logs by
-- the database, in the same transaction as the change:
--   "Permissions granted to <name> (<user id>): a, b"
--   "Permissions revoked from <name> (<user id>): c"
-- category SECURITY; WARNING when a reserved permission (reserved_permissions())
-- is involved, INFO otherwise; metadata.event = permissions_granted / _revoked.
--
-- Why triggers (statement level, transition tables) and not a line inside
-- set_user_permissions():
--   * every path is covered: set_user_permissions(), grant_role_preset() (which
--     calls it), a Super Admin's direct write (user_permissions_write policy),
--     migrations/backfills and service-role sessions;
--   * the lines list the rows that ACTUALLY changed (unknown codes, which
--     set_user_permissions() silently skips, and no-op saves leave no line);
--   * same transaction: if the change fails or is rolled back, so is its line;
--     an audit insert failure aborts the change.
-- Forgery: system_logs has no UPDATE/DELETE policy (append-only); a client line
-- imitating these messages is refused by guard_system_logs_insert(); the
-- browser's own "User privileges updated:" line (written after a save, listing
-- the REQUESTED codes) is now skipped because the database records the real
-- change. Lines written here carry origin 'database'.
--
-- Changes: new function log_permission_changes(); 3 triggers on
-- user_permissions; guard_system_logs_insert() = the post-18 definition plus
-- one skip rule and one prefix. Nothing else; no data row is changed.
-- Independent of 19 (can run before or after it).
-- Rollback: supabase/rollback/19b_rollback.sql.
-- ============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
declare
  v_guard text := md5(pg_get_functiondef('public.guard_system_logs_insert()'::regprocedure));
  v_set   text := md5(pg_get_functiondef('public.set_user_permissions(text,text[])'::regprocedure));
begin
  if v_set <> 'ca619ff06ed78a224708855b937256b0' then
    raise exception '19b: unexpected set_user_permissions (%) - refusing', v_set;
  end if;
  if v_guard = 'eb5333b566dc8770c6845dea03fb82ab'
     and to_regprocedure('public.log_permission_changes()') is null then
    raise notice '19b: reviewed post-18 state - applying';
  elsif to_regprocedure('public.log_permission_changes()') is not null then
    raise notice '19b: already applied - re-applying (idempotent)';
  else
    raise exception '19b: unexpected guard_system_logs_insert (%) - refusing', v_guard;
  end if;
end
$pre$;

-- ----------------------------------------------------------------------------
-- 1. The audit writer (SECURITY DEFINER: the insert is a database line)
-- ----------------------------------------------------------------------------
create or replace function public.log_permission_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r          record;
  v_actor    text := public.current_profile_id();          -- null outside a signed-in session
  v_actor_nm text := coalesce(public.current_profile_name(), '');
  v_reserved text[] := public.reserved_permissions();
  v_granted  boolean;
  v_changes  jsonb;   -- [{kind, user_id, code}] - each branch reads only the transition tables its trigger has
begin
  if tg_op = 'INSERT' then
    select coalesce(jsonb_agg(jsonb_build_object('kind', 'granted', 'user_id', n.user_id, 'code', n.permission_code)), '[]')
      into v_changes from new_rows n;
  elsif tg_op = 'DELETE' then
    select coalesce(jsonb_agg(jsonb_build_object('kind', 'revoked', 'user_id', o.user_id, 'code', o.permission_code)), '[]')
      into v_changes from old_rows o;
  else
    select coalesce(jsonb_agg(x), '[]') into v_changes from (
      select jsonb_build_object('kind', 'granted', 'user_id', n.user_id, 'code', n.permission_code) as x
        from (select user_id, permission_code from new_rows except select user_id, permission_code from old_rows) n
      union all
      select jsonb_build_object('kind', 'revoked', 'user_id', o.user_id, 'code', o.permission_code)
        from (select user_id, permission_code from old_rows except select user_id, permission_code from new_rows) o) s;
  end if;

  for r in
    select c ->> 'kind' as kind, c ->> 'user_id' as user_id,
           array_agg(c ->> 'code' order by c ->> 'code') as codes, p.name
      from jsonb_array_elements(v_changes) c left join public.profiles p on p.id = c ->> 'user_id'
     group by c ->> 'kind', c ->> 'user_id', p.name
     order by 2, 1
  loop
    v_granted := r.kind = 'granted';
    insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
    values ('log-' || replace(gen_random_uuid()::text, '-', ''),
            case when r.codes && v_reserved then 'WARNING' else 'INFO' end::public.log_severity,
            'SECURITY',
            format('Permissions %s %s (%s): %s',
                   case when v_granted then 'granted to' else 'revoked from' end,
                   coalesce(r.name, 'deleted user'), r.user_id, array_to_string(r.codes, ', ')),
            v_actor, v_actor_nm, r.user_id,
            jsonb_build_object('source', 'db',
                               'event', case when v_granted then 'permissions_granted' else 'permissions_revoked' end,
                               'userId', r.user_id, 'codes', to_jsonb(r.codes),
                               'reserved', r.codes && v_reserved,
                               'actor', coalesce(v_actor, 'database session (no signed-in user)')));
  end loop;
  return null;
end;
$fn$;

-- Trigger function only: nobody calls it directly.
revoke all on function public.log_permission_changes() from public, anon, authenticated;

-- PostgreSQL allows transition tables only on single-event triggers.
drop trigger if exists trg_user_permissions_audit_ins on public.user_permissions;
drop trigger if exists trg_user_permissions_audit_del on public.user_permissions;
drop trigger if exists trg_user_permissions_audit_upd on public.user_permissions;
create trigger trg_user_permissions_audit_ins after insert on public.user_permissions
  referencing new table as new_rows for each statement execute function public.log_permission_changes();
create trigger trg_user_permissions_audit_del after delete on public.user_permissions
  referencing old table as old_rows for each statement execute function public.log_permission_changes();
create trigger trg_user_permissions_audit_upd after update on public.user_permissions
  referencing old table as old_rows new table as new_rows for each statement execute function public.log_permission_changes();

-- ----------------------------------------------------------------------------
-- 2. Client lines: skip the browser's privileges copy, refuse imitations
--    (the post-18 definition; changed lines marked 19b)
-- ----------------------------------------------------------------------------
create or replace function public.guard_system_logs_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if public.is_client_request() then
    if (new.category = 'ORDER'     and new.message like 'New order created: %')
       or (new.category = 'FINANCIAL' and new.message like 'Payment of $%')
       or (new.category = 'CUSTOMER'  and new.message like 'New customer registered: %')
       or (new.category = 'INVENTORY' and new.message ~ '^Stock (increased|decreased) for ')
       or (new.category = 'SECURITY'  and new.message like 'User privileges updated: %') then   -- 19b
      return null;  -- recorded by the database in the same transaction as the event
    end if;

    -- 18: website-request lifecycle lines are written by the database only.
    -- 19b: so are permission changes.
    if new.message ~ '^(Permissions (granted to|revoked from) |Website request REQ-|Customer \S+ created from REQ-|Order \S+ status changed from |Below-cost sale approved |Customer .+ transferred from |Order \S+ created with a past date |Order \S+: requested marketing officer |Payment of \S+ on order |Commission created for order |Commission for order |Delivery recorded on order |Delivered quantity corrected |Commission model activated|First-order bonus |Commission review required|Commission eligibility |Commission not earned )' then
      raise exception 'This kind of audit line is written by the database only'
        using errcode = '42501';
    end if;

    new.user_id     := public.current_profile_id();
    new.username    := coalesce(public.current_profile_name(), '');
    new.occurred_at := now();
    new.origin      := 'client';
  else
    new.origin      := 'database';
  end if;
  return new;
end;
$function$;

-- ----------------------------------------------------------------------------
-- 3. Post-check
-- ----------------------------------------------------------------------------
do $post$
declare
  v_trg int;
begin
  select count(*) into v_trg from pg_trigger
   where tgrelid = 'public.user_permissions'::regclass and not tgisinternal
     and tgname in ('trg_user_permissions_audit_ins', 'trg_user_permissions_audit_del', 'trg_user_permissions_audit_upd')
     and tgenabled = 'O';
  if v_trg <> 3 then raise exception '19b post-check: % of 3 audit triggers enabled', v_trg; end if;
  if has_function_privilege('authenticated', 'public.log_permission_changes()', 'EXECUTE')
     or has_function_privilege('anon', 'public.log_permission_changes()', 'EXECUTE') then
    raise exception '19b post-check: log_permission_changes is executable by clients';
  end if;
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'system_logs' and cmd in ('UPDATE', 'DELETE', 'ALL')) then
    raise exception '19b post-check: system_logs is not append-only';
  end if;
  if md5(pg_get_functiondef('public.set_user_permissions(text,text[])'::regprocedure)) <> 'ca619ff06ed78a224708855b937256b0' then
    raise exception '19b post-check: set_user_permissions changed';
  end if;
  raise notice '19b: permission-change audit installed (guard md5 %)',
    md5(pg_get_functiondef('public.guard_system_logs_insert()'::regprocedure));
end
$post$;

commit;
