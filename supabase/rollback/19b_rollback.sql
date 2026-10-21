-- ============================================================================
-- EFZ 19b ROLLBACK - removes the permission-change audit triggers
-- ============================================================================
-- Drops the 3 triggers on user_permissions and log_permission_changes(), and
-- restores guard_system_logs_insert() to the exact post-18 definition (md5
-- eb5333b566dc8770c6845dea03fb82ab, verified below). Audit lines already
-- written stay in system_logs (history is never deleted). After this, client
-- "User privileges updated:" lines are accepted again and permission changes
-- are no longer recorded by the database.
-- ============================================================================
begin;
set local lock_timeout = '30s';

do $pre$
begin
  if to_regprocedure('public.log_permission_changes()') is null then
    raise exception '19b rollback: 19b is not installed - nothing to do';
  end if;
  if md5(pg_get_functiondef('public.guard_system_logs_insert()'::regprocedure)) <> '3158f3b914e2298b13162bba681dbea8' then
    raise exception '19b rollback: guard_system_logs_insert is not the 19b definition - refusing';
  end if;
end
$pre$;

drop trigger if exists trg_user_permissions_audit_ins on public.user_permissions;
drop trigger if exists trg_user_permissions_audit_del on public.user_permissions;
drop trigger if exists trg_user_permissions_audit_upd on public.user_permissions;
drop function public.log_permission_changes();

-- exact post-18 definition
CREATE OR REPLACE FUNCTION public.guard_system_logs_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if public.is_client_request() then
    if (new.category = 'ORDER'     and new.message like 'New order created: %')
       or (new.category = 'FINANCIAL' and new.message like 'Payment of $%')
       or (new.category = 'CUSTOMER'  and new.message like 'New customer registered: %')
       or (new.category = 'INVENTORY' and new.message ~ '^Stock (increased|decreased) for ') then
      return null;  -- recorded by the database in the same transaction as the event
    end if;

    -- 18: website-request lifecycle lines are written by the database only.
    if new.message ~ '^(Website request REQ-|Customer \S+ created from REQ-|Order \S+ status changed from |Below-cost sale approved |Customer .+ transferred from |Order \S+ created with a past date |Order \S+: requested marketing officer |Payment of \S+ on order |Commission created for order |Commission for order |Delivery recorded on order |Delivered quantity corrected |Commission model activated|First-order bonus |Commission review required|Commission eligibility |Commission not earned )' then
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


do $post$
begin
  if md5(pg_get_functiondef('public.guard_system_logs_insert()'::regprocedure)) <> 'eb5333b566dc8770c6845dea03fb82ab' then
    raise exception '19b rollback post-check: guard_system_logs_insert is not the post-18 definition';
  end if;
  if exists (select 1 from pg_trigger where tgrelid = 'public.user_permissions'::regclass and not tgisinternal) then
    raise exception '19b rollback post-check: a trigger is still on user_permissions';
  end if;
  raise notice '19b rollback: done (audit lines kept)';
end
$post$;

commit;
