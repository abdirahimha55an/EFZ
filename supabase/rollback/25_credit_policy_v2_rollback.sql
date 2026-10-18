-- =============================================================================
-- ROLLBACK of migration 25 (credit policy v2). Staging first; Production only with the owner's explicit approval. TEST IT ON A DISPOSABLE COPY FIRST.
-- Restores the migration-23/24 definitions of the ten functions it redefined (generated from the exact text of those files), drops everything migration 25 added,
-- and puts back the narrower credit-account status rule.
-- DATA-LOSS / IRREVERSIBLE EFFECTS - read before running:
--   * The six tables this migration added are DROPPED with their rows: customer_credit_defaults (the default history), customer_credit_events (the credit history),
--     credit_due_extensions, credit_disputes, credit_reminders, customer_notifications. Their facts are also in system_logs (audit) for the events that wrote an audit line,
--     but the tables themselves are not recoverable: EXPORT THEM FIRST if any real default, dispute or extension exists.
--   * The seven new policy columns are dropped (values lost; they were also audited when saved). The proposal values migration 25 put into the shared columns
--     (3 purchases, 60 days, 30-day term) are cleared again if the policy row is still the untouched proposal; an edited policy keeps its values.
--   * Accounts with status 'revoked' (credit revoked after a default) become 'suspended' so the older status rule holds. Their former limit is unchanged.
--     After rollback the migration-24 behaviour applies again: in particular, paying an overdue invoice WOULD restore credit, and a default is no longer remembered.
--   * Orders, order lines, payments, credit accounts and credit orders are not touched.
-- =============================================================================
begin;
set local lock_timeout = '30s';

-- DEPENDENCY GUARD: refuse to run while a later migration still depends on what this script removes (the required order is 27, then 26, then 25).
do $guard$
begin
  if to_regclass('public.customer_price_agreements') is not null or to_regclass('public.price_agreement_notices') is not null or to_regprocedure('public._price_resolve(text, text, uuid, date)') is not null
     or pg_get_functiondef('public.create_order(jsonb)'::regprocedure) like '%_price_resolve%' then
    raise exception 'Migrations 26/27 are still applied and depend on objects this rollback drops (credit notices, events). Roll back migration 27, then 26, first. Nothing was changed.' using errcode = '55000';
  end if;
end
$guard$;


update public.customer_credit_accounts set status = 'suspended', reason = left('Rolled back from revoked: ' || reason, 500) where status = 'revoked';
alter table public.customer_credit_accounts drop constraint if exists customer_credit_accounts_status_check;
alter table public.customer_credit_accounts add constraint customer_credit_accounts_status_check check (status in ('approved', 'suspended'));

drop function if exists public.customer_open_credit_dispute(text, text, numeric);
drop function if exists public.customer_mark_notification_read(uuid);
drop function if exists public.my_notifications();
drop function if exists public.run_credit_checks();
drop function if exists public.credit_daily_run();
drop function if exists public.credit_operations();
drop function if exists public.void_credit_default(uuid, uuid, text);
drop function if exists public.resolve_credit_dispute(uuid, text, text);
drop function if exists public.update_credit_dispute(uuid, text, text);
drop function if exists public.list_credit_disputes(text);
drop function if exists public.record_credit_risk_review(uuid, text);
drop function if exists public.extend_credit_due_date(text, date, text);
drop function if exists public.increase_customer_credit_limit(text, numeric, text);
drop function if exists public.credit_company_cap();
drop function if exists public.set_credit_policy_rules(integer, numeric, numeric, integer, boolean, text);
drop function if exists public._credit_run();
drop function if exists public._credit_sync_defaults(text);
drop function if exists public._credit_company_cap();
drop function if exists public._credit_send(text, text, text, text, text, text);
drop function if exists public._credit_deliver(bigint);
drop function if exists public._credit_notify_staff(text, text, text);
drop function if exists public._credit_event(text, text, text, jsonb);
drop function if exists public._credit_audit(text, text, text, jsonb);
drop function if exists public._credit_effective_due(text);
drop function if exists public._credit_related_customers(text);

-- _customer_credit_eligibility as defined before migration 25
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

-- _customer_credit_summary as defined before migration 25
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

-- customer_credit_status as defined before migration 25
create or replace function public.customer_credit_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  return public._customer_credit_summary(public.require_approved_customer());
end;
$fn$;

-- customer_payment_methods as defined before migration 25
create or replace function public.customer_payment_methods()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_customer text := public.require_approved_customer();
  v_credit   jsonb := public._customer_credit_summary(v_customer);
begin
  return jsonb_build_object(
    'methods', coalesce((select jsonb_agg(jsonb_build_object('code', m.code, 'label', m.label, 'kind', m.kind) order by m.sort_order, m.code)
                           from public.payment_methods m where m.enabled), '[]'::jsonb),
    'credit', jsonb_build_object('available', (v_credit ->> 'canBuyOnCredit')::boolean, 'message', v_credit ->> 'message',
                                 'account', v_credit -> 'account'));
end;
$fn$;

-- customer_place_credit_order as defined before migration 25
create or replace function public.customer_place_credit_order(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_customer text := public.require_approved_customer();
  v_acc      uuid;
  v_key      uuid;
  v_location text := btrim(coalesce(p_payload ->> 'deliveryLocation', ''));
  v_notes    text := btrim(coalesce(p_payload ->> 'notes', ''));
  v_existing public.customer_checkouts%rowtype;
  v_summary  jsonb;
  v_priced   jsonb;
  v_total    numeric;
  v_avail    numeric;
  cr         public.customer_credit_accounts%rowtype;
  v_order    text;
  v_id       uuid;
  v_name     text;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then raise exception 'Invalid checkout' using errcode = '22023'; end if;
  begin v_key := (p_payload ->> 'submissionKey')::uuid; exception when others then v_key := null; end;
  if v_key is null then raise exception 'A submission key is required' using errcode = '22023'; end if;
  select id into v_acc from public.customer_accounts a where a.auth_user_id = auth.uid();
  perform pg_advisory_xact_lock(hashtext('checkout:' || v_customer));

  select * into v_existing from public.customer_checkouts c where c.customer_id = v_customer and c.submission_key = v_key;
  if found then
    return jsonb_build_object('checkoutId', v_existing.id, 'status', v_existing.status, 'orderId', v_existing.order_id, 'amount', v_existing.amount, 'repeat', true);
  end if;

  if char_length(v_location) < 3 or char_length(v_location) > 300 then raise exception 'Enter a delivery location (3 to 300 characters)' using errcode = '22023'; end if;
  if char_length(v_notes) > 1000 then raise exception 'Notes are too long' using errcode = '22023'; end if;

  v_summary := public._customer_credit_summary(v_customer);
  if not (v_summary ->> 'canBuyOnCredit')::boolean then
    raise exception 'Credit purchasing is not available on this account' using errcode = '42501';
  end if;
  select * into cr from public.customer_credit_accounts where customer_id = v_customer;
  v_priced := public._customer_price_cart(p_payload -> 'lines');
  v_total := (v_priced ->> 'total')::numeric;
  v_avail := (v_summary -> 'account' ->> 'available')::numeric;
  if v_total > v_avail then
    raise exception 'This order ($%) is above your available credit ($%)', v_total, v_avail using errcode = '22023';
  end if;
  if (select count(*) from public.customer_checkouts c where c.customer_id = v_customer and c.created_at > now() - interval '24 hours') >= 30 then
    raise exception 'Too many checkouts today. Please try again later.' using errcode = 'WR429';
  end if;

  select name into v_name from public.customers where id = v_customer;
  v_order := public._customer_create_order(v_customer, v_priced, 'credit', v_location, v_notes, 'Customer app (' || coalesce(v_name, v_customer) || ')');
  insert into public.customer_credit_orders (order_id, customer_id, terms_days, due_date, credit_limit_at_time)
  values (v_order, v_customer, cr.terms_days, public.efz_today() + cr.terms_days, cr.credit_limit);
  insert into public.customer_checkouts (customer_id, account_id, submission_key, method_code, status, lines, amount, delivery_location, notes, order_id, verified_at)
  values (v_customer, v_acc, v_key, 'credit', 'credit_placed', v_priced -> 'lines', v_total, v_location, v_notes, v_order, now())
  returning id into v_id;
  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'FINANCIAL',
          format('Credit order %s placed by the customer ($%s, limit $%s, %s days)', v_order, v_total, cr.credit_limit, cr.terms_days), null,
          'Customer app (' || coalesce(v_name, v_customer) || ')', v_order,
          jsonb_build_object('source', 'db', 'event', 'credit_order_placed', 'customerId', v_customer, 'total', v_total, 'limit', cr.credit_limit,
                             'termsDays', cr.terms_days, 'availableBefore', v_avail));
  return jsonb_build_object('checkoutId', v_id, 'status', 'credit_placed', 'orderId', v_order, 'amount', v_total, 'repeat', false);
end;
$fn$;

-- my_finance as defined before migration 25
create or replace function public.my_finance()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_customer text := public.require_approved_customer();
  v_today    date := public.efz_today();
begin
  return jsonb_build_object(
    'asOf', v_today,
    'summary', (select jsonb_build_object(
        'confirmedOrders', count(*), 'confirmedPurchases', coalesce(sum(o.total), 0), 'totalPaid', coalesce(sum(o.amount_paid), 0),
        'outstanding', coalesce(sum(o.outstanding_balance), 0),
        'unpaidInvoices', count(*) filter (where o.payment_terms = 'credit' and o.total > 0 and o.amount_paid = 0 and o.outstanding_balance > 0),
        'partialInvoices', count(*) filter (where o.payment_terms = 'credit' and o.total > 0 and o.amount_paid > 0 and o.outstanding_balance > 0),
        'paidInvoices', count(*) filter (where o.payment_terms = 'credit' and o.total > 0 and o.outstanding_balance = 0),
        'overdueInvoices', count(*) filter (where o.payment_terms = 'credit' and o.outstanding_balance > 0 and cc.due_date is not null and cc.due_date < v_today))
       from public.orders o left join public.customer_credit_orders cc on cc.order_id = o.id
      where o.customer_id = v_customer and o.status <> 'cancelled'),
    'pendingPayments', (select jsonb_build_object('count', count(*), 'amount', coalesce(sum(c.amount), 0))
                          from public.customer_checkouts c where c.customer_id = v_customer and c.status in ('created', 'pending')),
    'underReview', (select count(*) from public.customer_checkouts c where c.customer_id = v_customer and c.status in ('needs_review', 'reversed')),
    'invoices', coalesce((
      select jsonb_agg(jsonb_build_object(
               'number', 'INV-' || o.id, 'orderId', o.id, 'date', o.order_date, 'dueDate', cc.due_date, 'termsDays', cc.terms_days,
               'total', o.total, 'paid', o.amount_paid, 'outstanding', o.outstanding_balance,
               'status', case when o.outstanding_balance <= 0 then 'PAID' when o.amount_paid > 0 then 'PARTIALLY PAID' else 'UNPAID' end,
               'overdue', (o.outstanding_balance > 0 and cc.due_date is not null and cc.due_date < v_today),
               'items', coalesce((select jsonb_agg(jsonb_build_object('productName', i.product_name, 'designName', i.design_name, 'quantity', i.quantity,
                                                                        'unitPrice', i.actual_unit_price, 'lineTotal', i.line_revenue) order by i.created_at, i.id)
                                    from public.order_items i where i.order_id = o.id), '[]'::jsonb),
               'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'receiptNumber', case when p.id like 'pay-%' and p.id not like 'pay-\_%' then 'RCT-' || substr(p.id, 5) else 'RCT-_' || p.id end,
                                                                           'date', p.payment_date, 'amount', p.amount, 'method', p.payment_method, 'reference', p.reference)
                                                       order by p.payment_date, p.created_at, p.id)
                                       from public.payments p where p.order_id = o.id), '[]'::jsonb))
             order by o.order_date desc, o.created_at desc, o.id)
        from public.orders o left join public.customer_credit_orders cc on cc.order_id = o.id
       where o.customer_id = v_customer and o.status <> 'cancelled' and o.payment_terms = 'credit' and o.total > 0), '[]'::jsonb),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', x.id, 'receiptNumber', x.receipt_no, 'orderId', x.order_id, 'date', x.payment_date, 'amount', x.amount, 'method', x.payment_method,
               'reference', x.reference, 'terms', x.payment_terms, 'invoiceNumber', case when x.payment_terms = 'credit' then 'INV-' || x.order_id end,
               'orderTotal', x.total, 'paidToDate', x.paid_to_date, 'balanceAfter', greatest(x.total - x.paid_to_date, 0))
             order by x.payment_date desc, x.created_at desc, x.id)
        from (select p.id, p.order_id, p.payment_date, p.created_at, p.amount, p.payment_method, p.reference, o.payment_terms, o.total,
                     case when p.id like 'pay-%' and p.id not like 'pay-\_%' then 'RCT-' || substr(p.id, 5) else 'RCT-_' || p.id end as receipt_no,
                     sum(p.amount) over (partition by p.order_id order by p.payment_date, p.created_at, p.id) as paid_to_date
                from public.payments p join public.orders o on o.id = p.order_id
               where o.customer_id = v_customer and o.status <> 'cancelled' and p.amount > 0) x), '[]'::jsonb),
    'statement', jsonb_build_object(
      'openingBalance', 0,
      'entries', coalesce((
        select jsonb_agg(jsonb_build_object('date', s.d, 'kind', s.kind, 'reference', s.ref, 'orderId', s.order_id, 'description', s.descr, 'debit', s.debit, 'credit', s.credit, 'balance', s.balance)
                         order by s.d, s.ts, s.ord, s.ref)
          from (select e.*, sum(e.debit - e.credit) over (order by e.d, e.ts, e.ord, e.ref) as balance
                  from (select o.order_date as d, o.created_at as ts, 0 as ord,
                               case when o.payment_terms = 'credit' then 'invoice' else 'order' end as kind,
                               case when o.payment_terms = 'credit' then 'INV-' || o.id else o.id end as ref, o.id as order_id,
                               case when o.payment_terms = 'credit' then 'Invoice for order ' || o.id else 'Order ' || o.id end as descr,
                               o.total as debit, 0::numeric as credit
                          from public.orders o where o.customer_id = v_customer and o.status <> 'cancelled' and o.total > 0
                        union all
                        select p.payment_date, p.created_at, 1, 'payment',
                               case when p.id like 'pay-%' and p.id not like 'pay-\_%' then 'RCT-' || substr(p.id, 5) else 'RCT-_' || p.id end, p.order_id,
                               'Payment (' || p.payment_method || ') for order ' || p.order_id, 0::numeric, p.amount
                          from public.payments p join public.orders o on o.id = p.order_id
                         where o.customer_id = v_customer and o.status <> 'cancelled' and p.amount > 0) e) s), '[]'::jsonb),
      'closingBalance', (select coalesce(sum(o.outstanding_balance), 0) from public.orders o where o.customer_id = v_customer and o.status <> 'cancelled')),
    'credit', public._customer_credit_summary(v_customer));
end;
$fn$;

-- set_credit_policy as defined before migration 25
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

-- set_customer_credit as defined before migration 25
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

-- credit_overview as defined before migration 25
create or replace function public.credit_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  perform public._require_finance_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'customerId', c.id, 'name', c.name, 'eligibility', public._customer_credit_eligibility(c.id),
             'outstanding', (select coalesce(sum(o.outstanding_balance), 0) from public.orders o where o.customer_id = c.id and o.status <> 'cancelled'),
             'account', (select to_jsonb(a) - 'set_by' from public.customer_credit_accounts a where a.customer_id = c.id))
           order by c.name, c.id)
      from public.customers c
     where exists (select 1 from public.customer_accounts ca where ca.customer_id = c.id and ca.status = 'approved')), '[]'::jsonb);
end;
$fn$;

-- credit_history as defined before migration 25
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

drop table if exists public.customer_notifications;
drop table if exists public.credit_reminders;
drop table if exists public.credit_disputes;
drop table if exists public.credit_due_extensions;
drop table if exists public.customer_credit_events;
drop table if exists public.customer_credit_defaults;
drop function if exists public.guard_credit_history();

-- the proposal values migration 25 loaded into the shared columns are removed again ONLY while the row is still that untouched proposal (credit off, note unchanged);
-- a policy the owner has edited since is left exactly as it is
update public.credit_policy set min_completed_purchases = null, min_approved_days = null, default_terms_days = null, note = ''
 where id and enabled = false and note like 'Approved proposal loaded by migration 25%';

alter table public.credit_policy drop column if exists purchase_window_days;
alter table public.credit_policy drop column if exists initial_credit_limit;
alter table public.credit_policy drop column if exists company_cap_percent;
alter table public.credit_policy drop column if exists cap_basis_months;
alter table public.credit_policy drop column if exists allow_requirement_override;
alter table public.credit_policy drop column if exists auto_limit_increase_enabled;
alter table public.credit_policy drop column if exists late_fees_enabled;

commit;
