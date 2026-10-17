-- =============================================================================
-- 22 ROLLBACK - customer ordering foundation and deletion requests
-- -----------------------------------------------------------------------------
-- REFUSES while any of the new tables holds data (customer order requests, designs) or any account has asked to be
-- deleted: rolling back would destroy customer requests / deletion requests that cannot be recreated.
-- Restores require_approved_customer() and my_customer_account() exactly as migration 21 defined them.
-- Does not touch order_requests, order_request_items, orders or customers.
-- =============================================================================
begin;
set local lock_timeout = '30s';

do $guard$
begin
  if to_regclass('public.customer_order_requests') is not null and exists (select 1 from public.customer_order_requests) then
    raise exception 'ROLLBACK REFUSED: customer_order_requests holds % row(s)', (select count(*) from public.customer_order_requests);
  end if;
  if to_regclass('public.product_designs') is not null and exists (select 1 from public.product_designs) then
    raise exception 'ROLLBACK REFUSED: product_designs holds % row(s)', (select count(*) from public.product_designs);
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customer_accounts' and column_name = 'deletion_requested_at')
     and exists (select 1 from public.customer_accounts where deletion_requested_at is not null) then
    raise exception 'ROLLBACK REFUSED: % account(s) have requested deletion', (select count(*) from public.customer_accounts where deletion_requested_at is not null);
  end if;
end
$guard$;

drop function if exists public.my_order_requests();
drop function if exists public.submit_customer_order_request(jsonb);
drop function if exists public.customer_designs();
drop function if exists public.request_account_deletion(text);

drop table if exists public.customer_order_request_lines;
drop table if exists public.customer_order_requests;
drop function if exists public.guard_customer_order_requests_rows();
drop function if exists public.guard_customer_order_request_lines_rows();
drop table if exists public.product_designs;

alter table public.customer_account_events drop constraint if exists customer_account_events_event_check;
alter table public.customer_account_events add constraint customer_account_events_event_check
  check (event in ('registered', 'approved', 'rejected', 'suspended', 'reinstated'));
alter table public.customer_accounts drop column if exists deletion_reason;
alter table public.customer_accounts drop column if exists deletion_requested_at;

-- Restored exactly as defined in 21_customer_accounts.sql
create or replace function public.require_approved_customer()
returns text
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_customer text;
begin
  select a.customer_id into v_customer
    from public.customer_accounts a
   where a.auth_user_id = auth.uid() and a.status = 'approved' and a.customer_id is not null;
  if v_customer is null then
    raise exception 'This account is not approved for customer access' using errcode = '42501';
  end if;
  return v_customer;
end;
$fn$;
revoke all on function public.require_approved_customer() from public, anon, authenticated;

create or replace function public.my_customer_account()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select jsonb_build_object('status', a.status, 'fullName', a.full_name, 'requestedAt', a.requested_at, 'reviewedAt', a.reviewed_at)
    from public.customer_accounts a
   where a.auth_user_id = auth.uid();
$fn$;
revoke all on function public.my_customer_account() from public, anon;
grant execute on function public.my_customer_account() to authenticated;

commit;
