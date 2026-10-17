-- =============================================================================
-- 24 - Credit policy refinement (follows migration 23)
-- -----------------------------------------------------------------------------
-- Migration 23 gave EFZ a configurable credit eligibility policy. This migration completes the rule set the owner asked for and fixes one design flaw:
--   * new policy rules (all OFF/empty until EFZ decides them):
--       min_approved_days   a minimum period as an approved customer (counted from the first approval of the app account)
--       max_outstanding     a ceiling on a customer's TOTAL outstanding balance, whatever their individual limit
--       require_no_overdue  no credit invoice past its due date with a balance (default ON)
--   * two kinds of reasons, so an override means what it says:
--       reasons          unmet REQUIREMENTS (purchases, purchase value, period). Staff may authorize credit anyway with a recorded override.
--       standingReasons  account STANDING (an unpaid delivered balance, an overdue credit invoice, the outstanding ceiling reached). Never overridable:
--                        credit stops until the balance is paid. This is the automatic restriction when an account becomes overdue.
--     A customer with an override can buy on credit only while their standing is clear. (In migration 23 an override account could never buy, because
--     the purchase check demanded full eligibility; that made the override useless.)
--   * the credit summary shows the next due date and the overdue amount; the available credit respects the ceiling.
--   * credit_history(customer): the audit trail and credit orders of one customer, for staff.
--   * set_credit_policy gains the three new settings (the old six-argument version is replaced).
-- Redefines six migration-23 functions and replaces one; adds one function and three policy columns. Orders, payments, create_order, record_payment and
-- every earlier object are untouched. Idempotent. Rollback: rollback/24_credit_policy_refinement_rollback.sql (restores the migration-23 definitions).
-- =============================================================================

begin;

set local lock_timeout = '30s';

alter table public.credit_policy add column if not exists min_approved_days integer check (min_approved_days is null or min_approved_days >= 1);
alter table public.credit_policy add column if not exists max_outstanding numeric(14,2) check (max_outstanding is null or max_outstanding > 0);
alter table public.credit_policy add column if not exists require_no_overdue boolean not null default true;

create or replace function public._customer_credit_eligibility(p_customer_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  pol         public.credit_policy%rowtype;
  v_count     integer;
  v_value     numeric;
  v_unpaid    integer;
  v_od_n      integer;
  v_od_amt    numeric;
  v_out       numeric;
  v_first     timestamptz;
  v_days      integer;
  v_reasons   text[] := '{}';
  v_standing  text[] := '{}';
begin
  select * into pol from public.credit_policy where id;
  select count(*), coalesce(sum(o.total), 0) into v_count, v_value
    from public.orders o
   where o.customer_id = p_customer_id and o.status = 'delivered' and o.order_type = 'regular' and o.total > 0 and o.amount_paid >= o.total;
  select count(*) into v_unpaid from public.orders o where o.customer_id = p_customer_id and o.status = 'delivered' and o.outstanding_balance > 0;
  select count(*), coalesce(sum(o.outstanding_balance), 0) into v_od_n, v_od_amt
    from public.orders o join public.customer_credit_orders cc on cc.order_id = o.id
   where o.customer_id = p_customer_id and o.status <> 'cancelled' and o.outstanding_balance > 0 and cc.due_date < public.efz_today();
  select coalesce(sum(o.outstanding_balance), 0) into v_out from public.orders o where o.customer_id = p_customer_id and o.status <> 'cancelled';
  select min(e.created_at) into v_first from public.customer_account_events e join public.customer_accounts a on a.id = e.account_id
   where a.customer_id = p_customer_id and e.event = 'approved';
  -- whole days since the first approval, counted on the same (Mogadishu) calendar as every other EFZ date
  v_days := case when v_first is null then 0 else greatest(public.efz_today() - (v_first at time zone 'Africa/Mogadishu')::date, 0) end;

  if not pol.enabled then
    v_reasons := array_append(v_reasons, 'Credit purchasing is not active yet.');
  else
    if pol.min_completed_purchases is not null and v_count < pol.min_completed_purchases then
      v_reasons := array_append(v_reasons, format('%s more completed purchase(s) needed (%s of %s).', pol.min_completed_purchases - v_count, v_count, pol.min_completed_purchases));
    end if;
    if pol.min_total_value is not null and v_value < pol.min_total_value then
      v_reasons := array_append(v_reasons, format('Completed purchases total $%s; $%s is required.', v_value, pol.min_total_value));
    end if;
    if pol.min_approved_days is not null and v_days < pol.min_approved_days then
      v_reasons := array_append(v_reasons, format('Approved for %s of the %s days required.', v_days, pol.min_approved_days));
    end if;
    if pol.min_completed_purchases is null and pol.min_total_value is null and pol.min_approved_days is null then
      v_reasons := array_append(v_reasons, 'EFZ has not defined the purchase requirement yet.');
    end if;
    if pol.require_no_unpaid_delivered and v_unpaid > 0 then
      v_standing := array_append(v_standing, 'A delivered order still has an unpaid balance.');
    end if;
    if pol.require_no_overdue and v_od_n > 0 then
      v_standing := array_append(v_standing, format('A credit invoice is overdue ($%s).', v_od_amt));
    end if;
    if pol.max_outstanding is not null and v_out >= pol.max_outstanding then
      v_standing := array_append(v_standing, format('The outstanding balance ($%s) has reached the maximum ($%s).', v_out, pol.max_outstanding));
    end if;
  end if;
  return jsonb_build_object(
    'eligible', pol.enabled and cardinality(v_reasons) = 0 and cardinality(v_standing) = 0,
    'completedPurchases', v_count, 'completedValue', v_value, 'unpaidDeliveredOrders', v_unpaid, 'daysApproved', v_days, 'overdueAmount', v_od_amt,
    'requirements', jsonb_build_object('minCompletedPurchases', pol.min_completed_purchases, 'minTotalValue', pol.min_total_value, 'minApprovedDays', pol.min_approved_days,
                                        'maxOutstanding', pol.max_outstanding, 'requireNoUnpaidDelivered', pol.require_no_unpaid_delivered, 'requireNoOverdue', pol.require_no_overdue),
    'reasons', to_jsonb(v_reasons), 'standingReasons', to_jsonb(v_standing));
end;
$fn$;

create or replace function public._customer_credit_summary(p_customer_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  pol         public.credit_policy%rowtype;
  acc         public.customer_credit_accounts%rowtype;
  v_elig      jsonb := public._customer_credit_eligibility(p_customer_id);
  v_out       numeric;
  v_ceiling   numeric;
  v_available numeric := 0;
  v_next_due  date;
  v_can       boolean;
  v_standing  boolean := jsonb_array_length(v_elig -> 'standingReasons') > 0;
  v_unmet     boolean := jsonb_array_length(v_elig -> 'reasons') > 0;
begin
  select * into pol from public.credit_policy where id;
  select * into acc from public.customer_credit_accounts where customer_id = p_customer_id;
  select coalesce(sum(o.outstanding_balance), 0) into v_out from public.orders o where o.customer_id = p_customer_id and o.status <> 'cancelled';
  select min(cc.due_date) into v_next_due from public.customer_credit_orders cc join public.orders o on o.id = cc.order_id
   where cc.customer_id = p_customer_id and o.status <> 'cancelled' and o.outstanding_balance > 0;
  if acc.customer_id is not null then
    v_ceiling := least(acc.credit_limit, coalesce(pol.max_outstanding, acc.credit_limit));
    v_available := greatest(v_ceiling - v_out, 0);
  end if;
  -- An override covers unmet REQUIREMENTS only. Standing (unpaid, overdue, ceiling) always stops credit.
  v_can := pol.enabled and acc.customer_id is not null and acc.status = 'approved' and not v_standing and (not v_unmet or acc.override_used) and v_available > 0;
  return jsonb_build_object(
    'policyEnabled', pol.enabled, 'eligibility', v_elig, 'canBuyOnCredit', coalesce(v_can, false),
    'account', case when acc.customer_id is null then null else jsonb_build_object('status', acc.status, 'creditLimit', acc.credit_limit, 'termsDays', acc.terms_days,
                                                                                     'outstanding', v_out, 'available', v_available, 'nextDueDate', v_next_due,
                                                                                     'overdue', v_elig -> 'overdueAmount', 'override', acc.override_used) end,
    'message', case
      when not pol.enabled then 'Credit purchasing is not currently available.'
      when acc.customer_id is null and (v_elig ->> 'eligible')::boolean then 'You meet the requirements. EFZ will confirm your credit limit and terms.'
      when acc.customer_id is null then 'Credit purchasing is not available on your account yet.'
      when acc.status <> 'approved' then 'Credit purchasing is paused on your account. Please contact EFZ.'
      when v_standing then 'Credit purchasing is paused until your unpaid or overdue balance is paid.'
      when v_unmet and not acc.override_used then 'Credit purchasing is not available on your account at the moment.'
      when v_available <= 0 then 'You have used all of your available credit.'
      else 'You can buy on credit within your limit.' end);
end;
$fn$;

-- Authorizing credit: unmet requirements need a recorded override reason; a standing problem can never be overridden.
create or replace function public.set_customer_credit(p_customer_id text, p_limit numeric, p_terms_days integer, p_reason text, p_override_reason text default null)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  pol      public.credit_policy%rowtype;
  v_elig   jsonb;
  v_before jsonb;
  v_over   text := nullif(btrim(coalesce(p_override_reason, '')), '');
  v_unmet  boolean;
begin
  perform public._require_finance_admin();
  select * into pol from public.credit_policy where id;
  if not pol.enabled then raise exception 'Credit purchasing is not enabled in the credit policy' using errcode = '22023'; end if;
  if not exists (select 1 from public.customer_accounts a where a.customer_id = p_customer_id and a.status = 'approved' and a.deletion_requested_at is null) then
    raise exception 'The customer has no approved app account' using errcode = '22023';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) < 5 then raise exception 'Give a reason (at least 5 characters)' using errcode = '22023'; end if;
  if p_limit is null or p_limit < 0 or p_limit > 1000000 or p_limit <> round(p_limit, 2) then raise exception 'The credit limit must be between 0 and 1,000,000, in whole cents' using errcode = '22023'; end if;
  if p_terms_days is null or p_terms_days not between 1 and 365 then raise exception 'The repayment period must be 1 to 365 days' using errcode = '22023'; end if;
  v_elig := public._customer_credit_eligibility(p_customer_id);
  if jsonb_array_length(v_elig -> 'standingReasons') > 0 then
    raise exception 'The customer''s account standing does not allow credit (%). Credit cannot be authorized until it is resolved; an override does not apply.', v_elig -> 'standingReasons' using errcode = '22023';
  end if;
  v_unmet := jsonb_array_length(v_elig -> 'reasons') > 0;
  if v_unmet and (v_over is null or char_length(v_over) < 10) then
    raise exception 'The customer does not meet the credit policy (%). A recorded override reason of at least 10 characters is required.', v_elig -> 'reasons' using errcode = '22023';
  end if;
  select to_jsonb(a) into v_before from public.customer_credit_accounts a where a.customer_id = p_customer_id;
  insert into public.customer_credit_accounts (customer_id, status, credit_limit, terms_days, reason, override_used, set_by, set_at)
  values (p_customer_id, 'approved', p_limit, p_terms_days, btrim(p_reason), v_unmet, public.current_profile_id(), now())
  on conflict (customer_id) do update set status = 'approved', credit_limit = excluded.credit_limit, terms_days = excluded.terms_days, reason = excluded.reason,
         override_used = excluded.override_used, set_by = excluded.set_by, set_at = now();
  perform public.finance_audit(format('Credit limit of $%s (%s days) set for customer %s', p_limit, p_terms_days, p_customer_id), p_customer_id,
    jsonb_build_object('event', 'customer_credit_set', 'before', v_before, 'limit', p_limit, 'termsDays', p_terms_days, 'reason', btrim(p_reason),
                       'eligibility', v_elig, 'overrideReason', v_over));
end;
$fn$;

drop function if exists public.set_credit_policy(boolean, integer, numeric, boolean, integer, text);
create or replace function public.set_credit_policy(
  p_enabled boolean, p_min_purchases integer, p_min_value numeric, p_require_no_unpaid boolean, p_default_terms_days integer, p_reason text,
  p_min_approved_days integer default null, p_max_outstanding numeric default null, p_require_no_overdue boolean default true)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare v_before jsonb;
begin
  perform public._require_finance_admin();
  if p_reason is null or char_length(btrim(p_reason)) < 5 then raise exception 'Give a reason (at least 5 characters)' using errcode = '22023'; end if;
  if p_enabled and p_min_purchases is null and p_min_value is null and p_min_approved_days is null then
    raise exception 'Define at least one requirement (completed purchases, a purchase value, or a period as an approved customer) before credit can be enabled' using errcode = '22023';
  end if;
  if p_enabled and p_default_terms_days is null then
    raise exception 'Define the default repayment period before credit can be enabled' using errcode = '22023';
  end if;
  select to_jsonb(p) into v_before from public.credit_policy p where p.id;
  update public.credit_policy set enabled = coalesce(p_enabled, false), min_completed_purchases = p_min_purchases, min_total_value = p_min_value,
         min_approved_days = p_min_approved_days, max_outstanding = p_max_outstanding, require_no_overdue = coalesce(p_require_no_overdue, true),
         require_no_unpaid_delivered = coalesce(p_require_no_unpaid, true), default_terms_days = p_default_terms_days,
         updated_by = public.current_profile_id(), updated_at = now(), note = btrim(p_reason) where id;
  perform public.finance_audit(format('Credit policy %s', case when p_enabled then 'enabled' else 'saved (credit off)' end), 'credit_policy',
    jsonb_build_object('event', 'credit_policy_set', 'before', v_before, 'enabled', p_enabled, 'minPurchases', p_min_purchases, 'minValue', p_min_value,
                       'minApprovedDays', p_min_approved_days, 'maxOutstanding', p_max_outstanding, 'requireNoOverdue', p_require_no_overdue,
                       'requireNoUnpaid', p_require_no_unpaid, 'defaultTermsDays', p_default_terms_days, 'reason', btrim(p_reason)));
end;
$fn$;
revoke all on function public.set_credit_policy(boolean, integer, numeric, boolean, integer, text, integer, numeric, boolean) from public, anon;
grant execute on function public.set_credit_policy(boolean, integer, numeric, boolean, integer, text, integer, numeric, boolean) to authenticated;

-- One customer's credit story for staff: the audit lines and every credit order with its terms, due date and balance.
create or replace function public.credit_history(p_customer_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  perform public._require_finance_admin();
  return jsonb_build_object(
    'account', (select to_jsonb(a) - 'set_by' from public.customer_credit_accounts a where a.customer_id = p_customer_id),
    'events', coalesce((select jsonb_agg(jsonb_build_object('at', l.occurred_at, 'by', l.username, 'message', l.message, 'event', l.metadata ->> 'event') order by l.occurred_at desc)
                          from public.system_logs l where l.target_id = p_customer_id and l.metadata ->> 'event' in ('customer_credit_set', 'customer_credit_suspended')), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(jsonb_build_object('orderId', cc.order_id, 'date', o.order_date, 'dueDate', cc.due_date, 'termsDays', cc.terms_days, 'limitAtTime', cc.credit_limit_at_time,
                                                              'total', o.total, 'paid', o.amount_paid, 'outstanding', o.outstanding_balance, 'status', o.status::text,
                                                              'overdue', (o.status <> 'cancelled' and o.outstanding_balance > 0 and cc.due_date < public.efz_today())) order by o.order_date desc, cc.order_id)
                          from public.customer_credit_orders cc join public.orders o on o.id = cc.order_id where cc.customer_id = p_customer_id), '[]'::jsonb));
end;
$fn$;
revoke all on function public.credit_history(text) from public, anon;
grant execute on function public.credit_history(text) to authenticated;

commit;
