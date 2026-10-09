-- ============================================================================
-- EFZ - ROLLBACK of 18c_remove_legacy_request_insert.sql
-- ----------------------------------------------------------------------------
-- Restores the legacy direct-insert path exactly as 18b left it: the original
-- order_requests_insert_public policy, INSERT for anon and authenticated, and the
-- temporary legacy-admission triggers (same phone rules, limit and lock).
-- Deletes nothing. Run BEFORE rolling back the app or 18b. Idempotent.
-- ============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
begin
  if to_regprocedure('public.website_request_admission(text,uuid)') is null then
    raise exception '18c rollback: 18b objects are missing - nothing to restore onto';
  end if;
end
$pre$;

create or replace function public.order_requests_legacy_admission()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_canon text;
begin
  if coalesce(current_setting('role', true), 'none') not in ('anon', 'authenticated')
     or coalesce(current_setting('efz.website_request_rpc', true), '') = 'on' then
    return case when tg_when = 'BEFORE' then new else null end;
  end if;

  if tg_when = 'BEFORE' then
    v_canon := public.validate_request_phone(new.phone);
    perform public.website_request_admission(v_canon, null);
    new.phone_canonical   := v_canon;
    new.submission_key    := null;   -- a direct insert never sets the new columns
    new.assigned_to       := null;
    new.status_changed_at := null;
    new.rejected_reason   := null;
    return new;
  end if;

  insert into public.order_request_events (request_id, event, source, to_status, actor_id, actor_name, details)
  values (new.id, 'submitted', 'legacy_direct', 'new', public.current_profile_id(),
          coalesce(public.current_profile_name(), ''), jsonb_build_object('lines', 1, 'units', new.quantity));

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'ORDER',
          format('Website request REQ-%s received: 1 item(s), %s unit(s)',
                 upper(left(replace(new.id::text, '-', ''), 8)), new.quantity),
          public.current_profile_id(), coalesce(public.current_profile_name(), ''), new.id::text,
          jsonb_build_object('source', 'db', 'event', 'website_request_submitted', 'requestId', new.id,
                             'path', 'legacy_direct', 'lines', 1, 'units', new.quantity));
  return null;
end;
$fn$;


drop trigger if exists trg_order_requests_legacy_admission on public.order_requests;
create trigger trg_order_requests_legacy_admission
  before insert on public.order_requests
  for each row execute function public.order_requests_legacy_admission();

drop trigger if exists trg_order_requests_legacy_admission_after on public.order_requests;
create trigger trg_order_requests_legacy_admission_after
  after insert on public.order_requests
  for each row execute function public.order_requests_legacy_admission();

revoke all on function public.order_requests_legacy_admission() from public, anon, authenticated;

drop policy if exists order_requests_insert_public on public.order_requests;
CREATE POLICY order_requests_insert_public ON public.order_requests FOR INSERT TO anon, authenticated WITH CHECK (((status = 'new'::public.order_request_status) AND (converted_order_id IS NULL) AND (handled_by IS NULL) AND ((char_length(btrim(customer_name)) >= 1) AND (char_length(btrim(customer_name)) <= 200)) AND ((char_length(btrim(phone)) >= 1) AND (char_length(btrim(phone)) <= 50)) AND (char_length(organization) <= 200) AND (char_length(product_name) <= 200) AND (char_length(delivery_location) <= 500) AND (char_length(notes) <= 2000) AND ((quantity >= 1) AND (quantity <= 100000))));

grant insert on public.order_requests to anon, authenticated;

do $post$
begin
  if not has_table_privilege('anon', 'public.order_requests', 'INSERT')
     or not exists (select 1 from pg_policy where polrelid = 'public.order_requests'::regclass and polname = 'order_requests_insert_public')
     or (select count(*) from pg_trigger where tgrelid = 'public.order_requests'::regclass
          and tgname like 'trg_order_requests_legacy_admission%') <> 2 then
    raise exception '18c rollback post-check failed - aborting';
  end if;
  raise notice '18c rollback: legacy direct-insert path restored (held to the 18b rules)';
end
$post$;

commit;
