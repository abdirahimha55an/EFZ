-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 7 of 7 : Integrity scanner and operational metrics
-- ----------------------------------------------------------------------------
-- The old diagnostics page scanned localStorage for duplicate IDs, orphaned
-- foreign keys and negative stock. None of those can happen any more - primary
-- keys, foreign keys and CHECK constraints refuse them at write time.
--
-- What remains worth scanning for is data that is structurally valid but
-- operationally wrong: an order with no lines, stock below its threshold, a
-- customer nobody owns, a trigger-maintained total that has drifted.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- upsert_issue() - used only by run_diagnostics().
-- A zero count resolves the finding instead of raising it.
-- ---------------------------------------------------------------------------
create or replace function public.upsert_issue(
  p_id                 text,
  p_count              integer,
  p_title              text,
  p_severity           public.log_severity,
  p_source             text,
  p_entity_type        text,
  p_entity_id          text,
  p_explanation        text,
  p_recommended_action text,
  p_repairable         boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if coalesce(p_count, 0) = 0 then
    update public.system_issues
       set resolved_at = coalesce(resolved_at, now())
     where id = p_id;
    return;
  end if;

  insert into public.system_issues (
    id, title, severity, source, affected_entity_type, affected_entity_id,
    affected_count, explanation, recommended_action, repairable,
    resolved_at, last_detected_at
  )
  values (
    p_id, p_title, p_severity, p_source, p_entity_type, p_entity_id,
    p_count, p_explanation, p_recommended_action, p_repairable,
    null, now()
  )
  on conflict (id) do update
     set title               = excluded.title,
         severity            = excluded.severity,
         affected_entity_id  = excluded.affected_entity_id,
         affected_count      = excluded.affected_count,
         explanation         = excluded.explanation,
         recommended_action  = excluded.recommended_action,
         repairable          = excluded.repairable,
         resolved_at         = null,
         last_detected_at    = now();
end;
$fn$;

-- ============================================================================
-- 1. run_diagnostics()
-- ----------------------------------------------------------------------------
-- Refreshes public.system_issues. Findings that still apply are updated;
-- findings that no longer apply are marked resolved rather than deleted, so the
-- history of what was once wrong survives.
--
-- Returns the number of open issues.
-- ============================================================================

create or replace function public.run_diagnostics()
returns integer
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_open integer := 0;
  v_seen text[] := array[]::text[];
begin
  perform public.require_permission('view_diagnostics');

  -- ---------------------------------------------------------------------
  -- Each block computes a count and a sample entity, then upserts.
  -- ---------------------------------------------------------------------

  -- 1. Orders with no line items. Their total is necessarily zero, which is
  --    almost always a half-finished write rather than a real free order.
  declare
    v_count integer;
    v_sample text;
  begin
    select count(*), min(o.id) into v_count, v_sample
      from public.orders o
     where not exists (select 1 from public.order_items oi where oi.order_id = o.id);

    perform public.upsert_issue(
      'orders-without-items', v_count,
      'Orders with no line items',
      'ERROR', 'orders', 'order', v_sample,
      format('%s order(s) have no items, so their total is $0.', v_count),
      'Open each order and add the missing lines, or delete the order.',
      false
    );
    v_seen := v_seen || 'orders-without-items';
  end;

  -- 2. Order totals that disagree with their own lines. This should be
  --    impossible while the triggers are installed, so a hit here means a
  --    trigger was dropped or bypassed - the most important check on the page.
  declare
    v_count integer;
    v_sample text;
  begin
    select count(*), min(t.id) into v_count, v_sample
      from (
        select o.id, o.total, coalesce(sum(oi.line_revenue), 0) as computed
          from public.orders o
          left join public.order_items oi on oi.order_id = o.id
         group by o.id, o.total
        having abs(o.total - coalesce(sum(oi.line_revenue), 0)) > 0.01
      ) t;

    perform public.upsert_issue(
      'orders-total-drift', v_count,
      'Order totals do not match their line items',
      'CRITICAL', 'orders', 'order', v_sample,
      format('%s order(s) have a stored total that differs from the sum of their lines.', v_count),
      'Repairable: recomputes every affected order from its line items.',
      true
    );
    v_seen := v_seen || 'orders-total-drift';
  end;

  -- 3. Commission totals on profiles drifting from the ledger.
  declare
    v_count integer;
    v_sample text;
  begin
    select count(*), min(t.id) into v_count, v_sample
      from (
        select p.id
          from public.profiles p
          left join public.commissions c
            on c.user_id = p.id and c.status in ('pending', 'approved', 'paid')
         group by p.id, p.earned_commission_total
        having abs(p.earned_commission_total - coalesce(sum(c.amount), 0)) > 0.01
      ) t;

    perform public.upsert_issue(
      'commission-totals-drift', v_count,
      'Commission totals do not match the ledger',
      'ERROR', 'commissions', 'profile', v_sample,
      format('%s staff profile(s) show a commission total that the ledger does not support.', v_count),
      'Repairable: recomputes each profile total from its commission rows.',
      true
    );
    v_seen := v_seen || 'commission-totals-drift';
  end;

  -- 4. Products out of stock.
  declare
    v_count integer;
    v_sample text;
  begin
    select count(*), min(id) into v_count, v_sample
      from public.products where is_active and stock = 0;

    perform public.upsert_issue(
      'products-out-of-stock', v_count,
      'Products out of stock',
      'WARNING', 'inventory', 'product', v_sample,
      format('%s active product(s) cannot be sold right now.', v_count),
      'Restock from Inventory Control, or deactivate the product.',
      false
    );
    v_seen := v_seen || 'products-out-of-stock';
  end;

  -- 5. Products at or below their own low-stock threshold.
  declare
    v_count integer;
    v_sample text;
  begin
    select count(*), min(id) into v_count, v_sample
      from public.products
     where is_active and stock > 0 and stock <= low_stock_threshold;

    perform public.upsert_issue(
      'products-low-stock', v_count,
      'Products below their stock threshold',
      'WARNING', 'inventory', 'product', v_sample,
      format('%s product(s) are running low.', v_count),
      'Reorder before they run out.',
      false
    );
    v_seen := v_seen || 'products-low-stock';
  end;

  -- 6. Products sold at a loss.
  declare
    v_count integer;
    v_sample text;
  begin
    select count(*), min(id) into v_count, v_sample
      from public.products
     where is_active and selling_price < cost_price;

    perform public.upsert_issue(
      'products-negative-margin', v_count,
      'Products priced below cost',
      'ERROR', 'inventory', 'product', v_sample,
      format('%s product(s) lose money on every unit sold.', v_count),
      'Raise the selling price or correct the cost price.',
      false
    );
    v_seen := v_seen || 'products-negative-margin';
  end;

  -- 7. Customers with no marketing officer. Their orders earn nobody a
  --    commission, which usually means the assignment was missed.
  declare
    v_count integer;
    v_sample text;
  begin
    select count(*), min(id) into v_count, v_sample
      from public.customers
     where status = 'active' and marketing_officer_id is null;

    perform public.upsert_issue(
      'customers-without-officer', v_count,
      'Customers with no marketing officer',
      'WARNING', 'customers', 'customer', v_sample,
      format('%s active customer(s) are unassigned, so their orders earn no commission.', v_count),
      'Assign an officer from the Customer Database.',
      false
    );
    v_seen := v_seen || 'customers-without-officer';
  end;

  -- 8. Delivered orders that were never fully paid.
  declare
    v_count integer;
    v_sample text;
    v_amount numeric(14,2);
  begin
    select count(*), min(id), coalesce(sum(outstanding_balance), 0)
      into v_count, v_sample, v_amount
      from public.orders
     where status = 'delivered' and outstanding_balance > 0;

    perform public.upsert_issue(
      'orders-delivered-unpaid', v_count,
      'Delivered orders with an outstanding balance',
      'WARNING', 'finance', 'order', v_sample,
      format('%s delivered order(s) still owe $%s.', v_count, v_amount),
      'Chase payment, or record it from the Customer Database.',
      false
    );
    v_seen := v_seen || 'orders-delivered-unpaid';
  end;

  -- 9. Staff who cannot sign in because no auth user is linked to them.
  declare
    v_count integer;
    v_sample text;
  begin
    select count(*), min(id) into v_count, v_sample
      from public.profiles
     where status = 'active' and auth_user_id is null;

    perform public.upsert_issue(
      'profiles-without-auth', v_count,
      'Active staff with no sign-in account',
      'ERROR', 'security', 'profile', v_sample,
      format('%s active staff profile(s) have no Supabase Auth account, so they cannot sign in.', v_count),
      'Invite them in Authentication > Users using the same email as their profile.',
      false
    );
    v_seen := v_seen || 'profiles-without-auth';
  end;

  -- Anything this scanner owns but did not raise this run is now resolved.
  update public.system_issues
     set resolved_at = now()
   where source in ('orders', 'inventory', 'customers', 'finance', 'security', 'commissions')
     and resolved_at is null
     and id <> all(v_seen);

  select count(*) into v_open from public.system_issues where resolved_at is null;
  return v_open;
end;
$fn$;

-- ============================================================================
-- 2. repair_issue()
-- ----------------------------------------------------------------------------
-- Only the findings that a machine can safely fix are repairable. Everything
-- else needs a person to decide what the right value is, and the page says so.
-- ============================================================================

create or replace function public.repair_issue(p_issue_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_actor   text := public.current_profile_id();
  v_fixed   integer := 0;
  v_row     record;
begin
  perform public.require_permission('manage_system');

  if p_issue_id = 'orders-total-drift' then
    for v_row in
      select o.id
        from public.orders o
        left join public.order_items oi on oi.order_id = o.id
       group by o.id, o.total
      having abs(o.total - coalesce(sum(oi.line_revenue), 0)) > 0.01
    loop
      perform public.recalc_order_financials(v_row.id);
      v_fixed := v_fixed + 1;
    end loop;

  elsif p_issue_id = 'commission-totals-drift' then
    for v_row in select id from public.profiles loop
      perform public.refresh_profile_commission_totals(v_row.id);
      v_fixed := v_fixed + 1;
    end loop;

  else
    raise exception 'Issue % is not automatically repairable', p_issue_id
      using errcode = 'P0001';
  end if;

  insert into public.system_logs (id, severity, category, message, user_id, target_id, metadata)
  values (
    'log-' || replace(gen_random_uuid()::text, '-', ''),
    'CRITICAL', 'SYSTEM',
    format('Diagnostics repair executed for "%s": %s record(s) recomputed', p_issue_id, v_fixed),
    v_actor, p_issue_id,
    jsonb_build_object('issueId', p_issue_id, 'recordsFixed', v_fixed)
  );

  perform public.run_diagnostics();

  return jsonb_build_object('success', true, 'issueId', p_issue_id, 'recordsFixed', v_fixed);
end;
$fn$;

-- ============================================================================
-- 3. operational_metrics()
-- ----------------------------------------------------------------------------
-- Replaces the localStorage quota/latency readings with figures that mean
-- something against a real database.
-- ============================================================================

create or replace function public.operational_metrics()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_open      integer;
  v_critical  integer;
  v_errors    integer;
  v_score     integer;
  v_status    text;
  v_backup    timestamptz;
  v_backups   integer;
begin
  perform public.require_permission('view_diagnostics');

  select count(*) filter (where resolved_at is null),
         count(*) filter (where resolved_at is null and severity in ('CRITICAL', 'ERROR'))
    into v_open, v_critical
    from public.system_issues;

  select count(*) into v_errors
    from public.system_logs
   where severity in ('ERROR', 'CRITICAL')
     and occurred_at > now() - interval '24 hours';

  select max(created_at), count(*) into v_backup, v_backups from public.backups;

  -- A critical finding costs more than a warning, and the score floors at zero.
  v_score := greatest(0, 100 - (v_critical * 15) - ((v_open - v_critical) * 5));
  v_status := case
    when v_score >= 90 then 'Healthy'
    when v_score >= 70 then 'Degraded'
    when v_score >= 40 then 'At Risk'
    else 'Critical'
  end;

  return jsonb_build_object(
    'health', jsonb_build_object('score', v_score, 'status', v_status),
    'issues', jsonb_build_object('open', v_open, 'critical', v_critical),
    'runtime', jsonb_build_object(
      'engine', 'PostgreSQL ' || split_part(current_setting('server_version'), ' ', 1),
      'exceptions24h', v_errors,
      'serverTime', now()
    ),
    'records', jsonb_build_object(
      'products',  (select count(*) from public.products),
      'orders',    (select count(*) from public.orders),
      'orderItems',(select count(*) from public.order_items),
      'payments',  (select count(*) from public.payments),
      'customers', (select count(*) from public.customers),
      'profiles',  (select count(*) from public.profiles),
      'logs',      (select count(*) from public.system_logs)
    ),
    'backups', jsonb_build_object(
      'lastSnapshot', v_backup,
      'count', v_backups,
      'frequency', 'Manual'
    )
  );
end;
$fn$;

-- ============================================================================
-- 4. Grants
-- ============================================================================

revoke all on function public.run_diagnostics()             from public, anon;
revoke all on function public.repair_issue(text)            from public, anon;
revoke all on function public.operational_metrics()          from public, anon;
revoke all on function public.upsert_issue(text, integer, text, public.log_severity, text, text, text, text, text, boolean) from public, anon;

grant execute on function public.run_diagnostics()            to authenticated;
grant execute on function public.repair_issue(text)           to authenticated;
grant execute on function public.operational_metrics()        to authenticated;
