-- ============================================================================
-- ROLLBACK for migration 33 (Expense Management)
-- Removes everything 33 added. REFUSES once any expense exists: expenses are financial records and are never deleted
-- (use an app rollback plus a forward fix instead). Nothing outside 33 is touched.
-- ============================================================================
begin;
set local lock_timeout = '30s';

do $guard$
begin
  if to_regclass('public.expenses') is null then
    raise exception '33 rollback: 33 is not applied - nothing to roll back';
  end if;
  if exists (select 1 from public.expenses) or exists (select 1 from public.expense_payments) or exists (select 1 from public.expense_events) then
    raise exception '33 rollback REFUSED: expense records exist - use an app rollback plus a forward fix';
  end if;
end
$guard$;

drop function if exists public.finance_commission_costs();
drop function if exists public.finance_expense_costs();
drop view     if exists public.expense_overview;
drop function if exists public.void_expense_payment(uuid, text);
drop function if exists public.record_expense_payment(uuid, numeric, date, text, text);
drop function if exists public.void_expense(uuid, text);
drop function if exists public.decide_expense(uuid, text, text);
drop function if exists public.edit_expense(uuid, jsonb);
drop function if exists public.submit_expense(jsonb);
drop function if exists public.expense_clean(jsonb);
drop function if exists public.expense_record(uuid, text, text, text, text, jsonb, text);
drop table    if exists public.expense_events;
drop table    if exists public.expense_payments;
drop table    if exists public.expenses;
drop table    if exists public.expense_categories;
drop function if exists public.guard_expense_child();
drop function if exists public.guard_expense_row();
drop sequence if exists public.expense_reference_seq;

-- grants of the four permissions (none are made by 33 itself; a Super Admin may have delegated them since)
delete from public.user_permissions where permission_code in ('view_expenses', 'submit_expenses', 'approve_expenses', 'pay_expenses');
delete from public.permissions       where code            in ('view_expenses', 'submit_expenses', 'approve_expenses', 'pay_expenses');

do $post$
begin
  if to_regclass('public.expenses') is not null or to_regprocedure('public.submit_expense(jsonb)') is not null
     or exists (select 1 from public.permissions where code like '%\_expenses') then
    raise exception '33 rollback post-check failed - aborting';
  end if;
  raise notice '33 rolled back';
end
$post$;
commit;
