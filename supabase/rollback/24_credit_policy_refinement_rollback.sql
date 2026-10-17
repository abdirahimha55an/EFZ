-- =============================================================================
-- ROLLBACK of migration 24 (credit policy refinement). Staging first; Production only with the owner's explicit approval.
-- Restores the migration-23 definitions of the four functions it changed (generated from the exact text of 23_customer_checkout_credit.sql),
-- removes the two objects it added (credit_history, the nine-argument set_credit_policy) and drops its three policy columns.
-- Effects to know before running it:
--   * The values saved in the three dropped columns (min_approved_days, max_outstanding, require_no_overdue) are lost. They are also recorded in
--     the audit log (credit_policy_set) at the time they were saved.
--   * Customers who were authorized by an override can no longer buy on credit again (the migration-23 behaviour); no order or account row changes.
--   * Orders, payments, credit accounts and credit orders are NOT touched. Nothing else is changed.
-- =============================================================================
begin;
set local lock_timeout = '30s';

drop function if exists public.credit_history(text);
drop function if exists public.set_credit_policy(boolean, integer, numeric, boolean, integer, text, integer, numeric, boolean);

-- _customer_credit_eligibility as defined by migration 23
create or replace function public._customer_credit_eligibility(p_customer_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  pol       public.credit_policy%rowtype;
  v_count   integer;
  v_value   numeric;
  v_unpaid  integer;
  v_reasons text[] := '{}';
begin
  select * into pol from public.credit_policy where id;
  select count(*), coalesce(sum(o.total), 0) into v_count, v_value
    from public.orders o
   where o.customer_id = p_customer_id and o.status = 'delivered' and o.order_type = 'regular' and o.total > 0 and o.amount_paid >= o.total;
  select count(*) into v_unpaid from public.orders o
   where o.customer_id = p_customer_id and o.status = 'delivered' and o.outstanding_balance > 0;
  if not pol.enabled then
    v_reasons := array_append(v_reasons, ('Credit purchasing is not active yet.')::text);
  else
    if pol.min_completed_purchases is not null and v_count < pol.min_completed_purchases then
      v_reasons := array_append(v_reasons, (format('%s more completed purchase(s) needed (%s of %s).', pol.min_completed_purchases - v_count, v_count, pol.min_completed_purchases))::text);
    end if;
    if pol.min_total_value is not null and v_value < pol.min_total_value then
      v_reasons := array_append(v_reasons, format('Completed purchases total $%s; $%s is required.', v_value, pol.min_total_value));
    end if;
    if pol.require_no_unpaid_delivered and v_unpaid > 0 then
      v_reasons := array_append(v_reasons, ('A delivered order still has an unpaid balance.')::text);
    end if;
    if pol.min_completed_purchases is null and pol.min_total_value is null then
      v_reasons := array_append(v_reasons, ('EFZ has not defined the purchase requirement yet.')::text);
    end if;
  end if;
  return jsonb_build_object(
    'eligible', pol.enabled and cardinality(v_reasons) = 0,
    'completedPurchases', v_count, 'completedValue', v_value, 'unpaidDeliveredOrders', v_unpaid,
    'requirements', jsonb_build_object('minCompletedPurchases', pol.min_completed_purchases, 'minTotalValue', pol.min_total_value, 'requireNoUnpaidDelivered', pol.require_no_unpaid_delivered),
    'reasons', to_jsonb(v_reasons));
end;
$fn$;
revoke all on function public._customer_credit_eligibility(text) from public, anon, authenticated;

-- _customer_credit_summary as defined by migration 23
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
  v_available numeric := 0;
  v_can       boolean;
begin
  select * into pol from public.credit_policy where id;
  select * into acc from public.customer_credit_accounts where customer_id = p_customer_id;
  select coalesce(sum(o.outstanding_balance), 0) into v_out from public.orders o where o.customer_id = p_customer_id and o.status <> 'cancelled';
  if acc.customer_id is not null then v_available := greatest(acc.credit_limit - v_out, 0); end if;
  v_can := pol.enabled and acc.customer_id is not null and acc.status = 'approved' and (v_elig ->> 'eligible')::boolean and v_available > 0;
  return jsonb_build_object(
    'policyEnabled', pol.enabled, 'eligibility', v_elig, 'canBuyOnCredit', coalesce(v_can, false),
    'account', case when acc.customer_id is null then null else jsonb_build_object('status', acc.status, 'creditLimit', acc.credit_limit, 'termsDays', acc.terms_days,
                                                                                     'outstanding', v_out, 'available', v_available) end,
    'message', case
      when not pol.enabled then 'Credit purchasing is not currently available.'
      when acc.customer_id is null and (v_elig ->> 'eligible')::boolean then 'You meet the requirements. EFZ will confirm your credit limit and terms.'
      when acc.customer_id is null then 'Credit purchasing is not available on your account yet.'
      when acc.status <> 'approved' then 'Credit purchasing is paused on your account. Please contact EFZ.'
      when not (v_elig ->> 'eligible')::boolean then 'Credit purchasing is not available on your account at the moment.'
      else 'You can buy on credit within your limit.' end);
end;
$fn$;
revoke all on function public._customer_credit_summary(text) from public, anon, authenticated;

-- set_customer_credit as defined by migration 23
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
  if not (v_elig ->> 'eligible')::boolean and (v_over is null or char_length(v_over) < 10) then
    raise exception 'The customer does not meet the credit policy (%). A recorded override reason of at least 10 characters is required.', v_elig -> 'reasons' using errcode = '22023';
  end if;
  select to_jsonb(a) into v_before from public.customer_credit_accounts a where a.customer_id = p_customer_id;
  insert into public.customer_credit_accounts (customer_id, status, credit_limit, terms_days, reason, override_used, set_by, set_at)
  values (p_customer_id, 'approved', p_limit, p_terms_days, btrim(p_reason), not (v_elig ->> 'eligible')::boolean, public.current_profile_id(), now())
  on conflict (customer_id) do update set status = 'approved', credit_limit = excluded.credit_limit, terms_days = excluded.terms_days, reason = excluded.reason,
         override_used = excluded.override_used, set_by = excluded.set_by, set_at = now();
  perform public.finance_audit(format('Credit limit of $%s (%s days) set for customer %s', p_limit, p_terms_days, p_customer_id), p_customer_id,
    jsonb_build_object('event', 'customer_credit_set', 'before', v_before, 'limit', p_limit, 'termsDays', p_terms_days, 'reason', btrim(p_reason),
                       'eligibility', v_elig, 'overrideReason', v_over));
end;
$fn$;
revoke all on function public.set_customer_credit(text, numeric, integer, text, text) from public, anon;
grant execute on function public.set_customer_credit(text, numeric, integer, text, text) to authenticated;

-- set_credit_policy as defined by migration 23
create or replace function public.set_credit_policy(p_enabled boolean, p_min_purchases integer, p_min_value numeric, p_require_no_unpaid boolean, p_default_terms_days integer, p_reason text)
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
  if p_enabled and p_min_purchases is null and p_min_value is null then
    raise exception 'Define at least one purchase requirement (a number of completed purchases or a total value) before credit can be enabled' using errcode = '22023';
  end if;
  if p_enabled and p_default_terms_days is null then
    raise exception 'Define the default repayment period before credit can be enabled' using errcode = '22023';
  end if;
  select to_jsonb(p) into v_before from public.credit_policy p where p.id;
  update public.credit_policy set enabled = coalesce(p_enabled, false), min_completed_purchases = p_min_purchases, min_total_value = p_min_value,
         require_no_unpaid_delivered = coalesce(p_require_no_unpaid, true), default_terms_days = p_default_terms_days,
         updated_by = public.current_profile_id(), updated_at = now(), note = btrim(p_reason) where id;
  perform public.finance_audit(format('Credit policy %s', case when p_enabled then 'enabled' else 'saved (credit off)' end), 'credit_policy',
    jsonb_build_object('event', 'credit_policy_set', 'before', v_before, 'enabled', p_enabled, 'minPurchases', p_min_purchases, 'minValue', p_min_value,
                       'requireNoUnpaid', p_require_no_unpaid, 'defaultTermsDays', p_default_terms_days, 'reason', btrim(p_reason)));
end;
$fn$;
revoke all on function public.set_credit_policy(boolean, integer, numeric, boolean, integer, text) from public, anon;
grant execute on function public.set_credit_policy(boolean, integer, numeric, boolean, integer, text) to authenticated;

alter table public.credit_policy drop column if exists min_approved_days;
alter table public.credit_policy drop column if exists max_outstanding;
alter table public.credit_policy drop column if exists require_no_overdue;

commit;
