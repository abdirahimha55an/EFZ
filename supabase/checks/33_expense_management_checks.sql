-- ============================================================================
-- EFZ - CHECKS FOR MIGRATION 33 (expense management)   (EFZ-STAGING ONLY)
-- ----------------------------------------------------------------------------
-- Run: supabase db query --linked --project-ref <STAGING ref> -f supabase/checks/33_expense_management_checks.sql
-- One transaction that ALWAYS ends in an exception, so everything it creates (grants, expenses, events, logs) is rolled back.
-- The exception text IS the report: "M33 CHECKS: n PASS, m FAIL" followed by one line per check.
-- Needs migration 33 applied and Staging's synthetic data (it refuses on anything else, including Production).
-- ============================================================================
begin;
set local lock_timeout = '10s';
set local statement_timeout = '120s';
set local search_path = public, extensions;

create schema m33check;
grant usage on schema m33check to anon, authenticated, service_role;
create table m33check.r (n serial primary key, id text, name text, result text, info text);
create table m33check.v (k text primary key, val text);
grant all on m33check.r, m33check.v to anon, authenticated, service_role;
grant usage on sequence m33check.r_n_seq to anon, authenticated, service_role;

create function m33check.as_(p_who text) returns void language plpgsql as $f$
begin
  perform set_config('role', 'none', true);
  if p_who = 'owner' then
    perform set_config('request.jwt.claims', '', true);
  elsif p_who in ('anon', 'service_role') then
    perform set_config('request.jwt.claims', json_build_object('role', p_who)::text, true);
    perform set_config('role', p_who, true);
  else
    if not exists (select 1 from public.profiles where id = p_who and auth_user_id is not null) then
      raise exception 'STOPPED: staff user % is missing or has no sign-in', p_who;
    end if;
    perform set_config('request.jwt.claims',
      json_build_object('sub', (select auth_user_id from public.profiles where id = p_who), 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);
  end if;
end $f$;

create function m33check.try(p_sql text) returns text language plpgsql as $f$
declare v text;
begin
  execute p_sql into v;
  return 'OK|' || coalesce(v, '');
exception when others then
  return sqlstate || '|' || sqlerrm;
end $f$;

create function m33check.ok(p_id text, p_name text, p_got text, p_want text) returns void language sql as $f$
  insert into m33check.r (id, name, result, info)
  values (p_id, p_name,
          case when starts_with(coalesce(p_got, '<null>'), p_want) then 'PASS' else 'FAIL' end,
          left(coalesce(p_got, '<null>'), 200) || case when starts_with(coalesce(p_got, '<null>'), p_want) then '' else '  | expected: ' || p_want end);
$f$;

create function m33check.n(p_sql text) returns text language plpgsql as $f$
declare v text;
begin execute p_sql into v; return v; exception when others then return sqlstate || '|' || sqlerrm; end $f$;

create function m33check.setv(p_k text, p_val text) returns void language sql as $f$
  insert into m33check.v values (p_k, p_val) on conflict (k) do update set val = excluded.val;
$f$;
create function m33check.getv(p_k text) returns text language sql as $f$ select val from m33check.v where k = p_k; $f$;

-- submit as someone; returns try() text: 'OK|<uuid>' or '<sqlstate>|<message>'
create function m33check.sub(p_who text, p_cat text, p_amount text, p_date text, p_order text default '') returns text language plpgsql as $f$
begin
  perform m33check.as_(p_who);
  return m33check.try(format($q$select public.submit_expense(jsonb_build_object('categoryId', %L, 'description', 'M33 test', 'amount', %L, 'expenseDate', %L, 'orderId', %L, 'vendor', 'M33 vendor'))$q$,
                             p_cat, p_amount, p_date, p_order));
end $f$;
create function m33check.uid(p_try text) returns text language sql as $f$ select case when starts_with(p_try, 'OK|') then substr(p_try, 4) end; $f$;

do $guard$
begin
  if not exists (select 1 from public.products where id like 'prod-stg-%')
     or not exists (select 1 from public.profiles where id = 'u-stg-admin' and role = 'Super Admin')
     or exists (select 1 from public.products where id = 'prod-1787244881309')
     or exists (select 1 from public.profiles where id = 'u-1') then
    raise exception 'REFUSED: not EFZ-Staging (synthetic markers missing or Production markers present)';
  end if;
  if to_regprocedure('public.submit_expense(jsonb)') is null or to_regclass('public.expenses') is null then
    raise exception 'REFUSED: Migration 33 not applied';
  end if;
  if exists (select 1 from public.expenses) then
    raise exception 'REFUSED: expenses already exist on this database (the checks expect none)';
  end if;
end
$guard$;

do $run$
declare
  v_today text := public.efz_today()::text;
  v_fut   text := (public.efz_today() + 3)::text;
  v_o1 text; v_o2 text; v_fp0 text; v_fp1 text;
  r text; a text; b text; c text; d text; e text; f text;
  v_cs_cnt text;
begin
  perform m33check.setv('today', v_today);
  -- order of officer 1 and officer 2 (the helper decides what each can see)
  select o.id into v_o1 from public.orders o where o.marketing_officer_id = 'u-stg-officer1' and o.status <> 'cancelled' order by o.id limit 1;
  select o.id into v_o2 from public.orders o where o.marketing_officer_id = 'u-stg-officer2' and o.status <> 'cancelled' order by o.id limit 1;
  v_fp0 := (select md5(concat((select count(*) from orders), '/', (select coalesce(sum(total),0) from orders), '/', (select coalesce(sum(amount_paid),0) from orders), '/',
            (select count(*) from payments), '/', (select count(*) from commissions), '/', (select coalesce(sum(amount),0) from commissions), '/', (select count(*) from stock_movements), '/',
            (select coalesce(sum(stock),0) from products), '/', (select count(*) from customers))));

  -- ===================== A. seed =====================
  perform m33check.ok('A1', 'four expense permissions exist', m33check.n($$select count(*) from public.permissions where code in ('view_expenses','submit_expenses','approve_expenses','pay_expenses')$$), '4');
  perform m33check.ok('A2', 'thirteen categories', m33check.n($$select count(*) from public.expense_categories$$), '13');
  perform m33check.ok('A3', 'five direct and eight operating', m33check.n($$select count(*) filter (where kind='direct_order') || '/' || count(*) filter (where kind='operating') from public.expense_categories$$), '5/8');
  perform m33check.ok('A4', 'no inventory-purchase / cost-of-goods category', m33check.n($$select count(*) from public.expense_categories where id ~ '(purchase|stock|inventory|cogs|goods)'$$), '0');
  perform m33check.ok('A5', 'nobody holds the new permissions yet', m33check.n($$select count(*) from public.user_permissions where permission_code in ('view_expenses','submit_expenses','approve_expenses','pay_expenses')$$), '0');

  -- grants for the scenario (rolled back with everything else)
  insert into public.user_permissions (user_id, permission_code) values
    ('u-stg-cs', 'submit_expenses'), ('u-stg-officer1', 'submit_expenses'), ('u-stg-delivery', 'submit_expenses'),
    ('u-stg-manager', 'approve_expenses'), ('u-stg-manager', 'view_expenses'),
    ('u-stg-ops', 'pay_expenses'), ('u-stg-ops', 'view_expenses');

  -- ===================== B. access =====================
  perform m33check.as_('u-stg-inventory');
  perform m33check.ok('B1', 'staff without submit_expenses cannot submit', m33check.sub('u-stg-inventory', 'rent', '10.00', v_today), '42501');
  perform m33check.ok('B2', '... and see no categories', m33check.n($$select count(*) from public.expense_categories$$), '0');
  perform m33check.as_('anon');
  perform m33check.ok('B3', 'anon cannot read expenses', m33check.try($$select count(*) from public.expenses$$), '42501');
  perform m33check.ok('B4', 'anon cannot call submit_expense', m33check.try($$select public.submit_expense('{}'::jsonb)$$), '42501');
  perform m33check.as_('u-stg-cs');
  perform m33check.ok('B5', 'a signed-in client cannot insert directly', m33check.try($$insert into public.expenses (kind, category_id, description, amount, expense_date, submitted_by) values ('operating','rent','x',1,current_date,'u-stg-cs')$$), '42501');
  perform m33check.ok('B6', 'cannot update directly', m33check.try($$update public.expenses set amount = 1$$), '42501');
  perform m33check.ok('B7', 'cannot delete directly', m33check.try($$delete from public.expenses$$), '42501');
  perform m33check.ok('B8', 'cannot touch events or payments directly', m33check.try($$insert into public.expense_events (expense_id, event) values (gen_random_uuid(), 'approved')$$), '42501');
  perform m33check.ok('B9', 'internal helper expense_record is not callable', m33check.try($$select public.expense_record(gen_random_uuid(), 'approved', null, null, null, '{}'::jsonb, 'x')$$), '42501');

  -- ===================== C. submit =====================
  a := m33check.sub('u-stg-cs', 'rent', '120.00', v_today);                                  perform m33check.setv('e_rent', m33check.uid(a));
  perform m33check.ok('C1', 'Customer Service (with submit) submits an operating expense', a, 'OK|');
  perform m33check.as_('owner');
  perform m33check.ok('C2', 'it is pending, USD, reference EXP-yyyy-nnnnnn, names the submitter', m33check.n(format($$select approval_status||'/'||currency||'/'||(reference ~ '^EXP-[0-9]{4}-[0-9]{6}$')||'/'||submitted_by from public.expenses where id=%L$$, m33check.getv('e_rent'))), 'pending/USD/true/u-stg-cs');
  perform m33check.ok('C3', 'three decimals refused', m33check.sub('u-stg-cs', 'rent', '12.345', v_today), '22023');
  perform m33check.ok('C4', 'zero refused', m33check.sub('u-stg-cs', 'rent', '0', v_today), '22023');
  perform m33check.ok('C5', 'non-number refused', m33check.sub('u-stg-cs', 'rent', 'abc', v_today), '22023');
  perform m33check.ok('C6', 'future date refused', m33check.sub('u-stg-cs', 'rent', '10', v_fut), '22023');
  perform m33check.ok('C7', 'an operating expense with an order refused', m33check.sub('u-stg-cs', 'rent', '10', v_today, coalesce(v_o1, 'x')), '22023');
  perform m33check.ok('C8', 'a direct expense without an order refused', m33check.sub('u-stg-cs', 'delivery', '10', v_today), '22023');
  perform m33check.ok('C9', 'a direct expense on an unknown order refused', m33check.sub('u-stg-cs', 'delivery', '10', v_today, 'ORD-NOPE'), '22023');
  perform m33check.ok('C10', 'an unknown category refused', m33check.sub('u-stg-cs', 'purchases', '10', v_today), '22023');
  a := m33check.sub('u-stg-officer1', 'delivery', '15.50', v_today, v_o1);                    perform m33check.setv('e_d1', m33check.uid(a));
  perform m33check.ok('C11', 'an officer submits a direct expense on their own order', a, 'OK|');
  perform m33check.ok('C12', 'an officer cannot attach one to another officer''s order', m33check.sub('u-stg-officer1', 'delivery', '15.50', v_today, v_o2), '22023');
  perform m33check.as_('owner');
  update public.expense_categories set is_active = false where id = 'internet';
  perform m33check.ok('C13', 'an inactive category refused', m33check.sub('u-stg-cs', 'internet', '10', v_today), '22023');
  perform m33check.as_('owner');
  update public.expense_categories set is_active = true where id = 'internet';
  perform m33check.as_('owner');
  perform m33check.ok('C14', 'a non-USD currency is impossible', m33check.try($$insert into public.expenses (kind, category_id, description, amount, currency, expense_date, submitted_by) values ('operating','rent','x',1,'EUR',current_date,'u-stg-cs')$$), '23514');
  perform m33check.ok('C15', 'a direct expense without an order is impossible at table level', m33check.try($$insert into public.expenses (kind, category_id, description, amount, expense_date, submitted_by) values ('direct_order','delivery','x',1,current_date,'u-stg-cs')$$), '23514');

  -- ===================== D. visibility =====================
  perform m33check.as_('u-stg-cs');      perform m33check.ok('D1', 'a submitter sees only their own expenses', m33check.n($$select count(*) from public.expenses$$), '1');
  perform m33check.as_('u-stg-officer1'); perform m33check.ok('D2', 'another submitter sees only theirs', m33check.n($$select count(*) from public.expenses$$), '1');
  perform m33check.as_('u-stg-delivery'); perform m33check.ok('D3', 'a submitter with no expenses sees none', m33check.n($$select count(*) from public.expenses$$), '0');
  perform m33check.as_('u-stg-manager');  perform m33check.ok('D4', 'a holder of approve/view sees all', m33check.n($$select count(*) from public.expenses$$), '2');
  perform m33check.as_('u-stg-ops');      perform m33check.ok('D5', 'a holder of pay/view sees all', m33check.n($$select count(*) from public.expenses$$), '2');
  perform m33check.as_('u-stg-inventory'); perform m33check.ok('D6', 'staff with no expense permission see none', m33check.n($$select count(*) from public.expense_overview$$), '0');
  perform m33check.as_('u-stg-cs');      perform m33check.ok('D7', 'events follow the same scope', m33check.n($$select count(*) from public.expense_events$$), '1');

  -- ===================== E. edit =====================
  perform m33check.as_('u-stg-delivery');
  perform m33check.ok('E1', 'only the submitter can edit', m33check.try(format($$select public.edit_expense(%L, jsonb_build_object('categoryId','rent','description','M33 test','amount','130.00','expenseDate',%L))$$, m33check.getv('e_rent'), v_today)), '42501');
  perform m33check.as_('u-stg-cs');
  perform m33check.ok('E2', 'the submitter edits their pending expense', m33check.try(format($$select public.edit_expense(%L, jsonb_build_object('categoryId','rent','description','M33 test','amount','130.00','expenseDate',%L,'vendor','M33 vendor'))$$, m33check.getv('e_rent'), v_today)), 'OK|');
  perform m33check.as_('owner');
  perform m33check.ok('E3', 'the edit is an event naming what changed', m33check.n(format($$select event||'/'||(details->'changed')::text from public.expense_events where expense_id=%L and event='edited'$$, m33check.getv('e_rent'))), 'edited/["amount"]');
  perform m33check.as_('u-stg-cs');
  perform m33check.try(format($$select public.edit_expense(%L, jsonb_build_object('categoryId','rent','description','M33 test','amount','130.00','expenseDate',%L,'vendor','M33 vendor'))$$, m33check.getv('e_rent'), v_today));
  perform m33check.as_('owner');
  perform m33check.ok('E4', 'a save that changes nothing writes no event', m33check.n(format($$select count(*) from public.expense_events where expense_id=%L and event='edited'$$, m33check.getv('e_rent'))), '1');

  -- ===================== F. decisions =====================
  perform m33check.as_('u-stg-cs');
  perform m33check.ok('F1', 'a submitter without approve_expenses cannot decide', m33check.try(format($$select public.decide_expense(%L,'approve')$$, m33check.getv('e_rent'))), '42501');
  a := m33check.sub('u-stg-admin', 'administration', '40.00', v_today);                       perform m33check.setv('e_adm', m33check.uid(a));
  perform m33check.ok('F2', 'Super Admin can submit', a, 'OK|');
  perform m33check.as_('u-stg-admin');
  perform m33check.ok('F3', 'Super Admin cannot approve their own expense', m33check.try(format($$select public.decide_expense(%L,'approve')$$, m33check.getv('e_adm'))), '42501|You cannot approve or reject your own');
  perform m33check.as_('owner');
  perform m33check.ok('F4', 'the table itself refuses a self-decision', m33check.try(format($$update public.expenses set approval_status='approved', decided_by=submitted_by, decided_at=now() where id=%L$$, m33check.getv('e_adm'))), '23514');
  perform m33check.as_('u-stg-manager');
  perform m33check.ok('F5', 'a rejection needs a reason', m33check.try(format($$select public.decide_expense(%L,'reject','')$$, m33check.getv('e_rent'))), '22023');
  perform m33check.ok('F6', 'a rejection with a reason works', m33check.try(format($$select public.decide_expense(%L,'reject','Receipt missing')$$, m33check.getv('e_rent'))), 'OK|');
  perform m33check.as_('owner');
  perform m33check.ok('F7', 'it is rejected and keeps the reason', m33check.n(format($$select approval_status||'/'||rejection_reason||'/'||decided_by from public.expenses where id=%L$$, m33check.getv('e_rent'))), 'rejected/Receipt missing/u-stg-manager');
  perform m33check.as_('u-stg-cs');
  perform m33check.ok('F8', 'the submitter resubmits (edits a rejected one)', m33check.try(format($$select public.edit_expense(%L, jsonb_build_object('categoryId','rent','description','M33 test','amount','130.00','expenseDate',%L,'vendor','M33 vendor','notes','receipt kept on file'))$$, m33check.getv('e_rent'), v_today)), 'OK|');
  perform m33check.as_('owner');
  perform m33check.ok('F9', 'back to pending, decision cleared, event resubmitted', m33check.n(format($$select approval_status||'/'||coalesce(rejection_reason,'-')||'/'||coalesce(decided_by,'-')||'/'||(select count(*) from public.expense_events where expense_id=%L and event='resubmitted') from public.expenses where id=%L$$, m33check.getv('e_rent'), m33check.getv('e_rent'))), 'pending/-/-/1');
  perform m33check.as_('u-stg-manager');
  perform m33check.ok('F10', 'an approver approves another person''s expense', m33check.try(format($$select public.decide_expense(%L,'approve')$$, m33check.getv('e_rent'))), 'OK|');
  perform m33check.ok('F11', 'deciding twice is refused', m33check.try(format($$select public.decide_expense(%L,'approve')$$, m33check.getv('e_rent'))), 'WR409');
  perform m33check.as_('u-stg-admin');
  perform m33check.ok('F12', 'Super Admin approves someone else''s expense', m33check.try(format($$select public.decide_expense(%L,'approve')$$, m33check.getv('e_d1'))), 'OK|');
  perform m33check.as_('u-stg-cs');
  perform m33check.ok('F13', 'an approved expense cannot be edited by its submitter', m33check.try(format($$select public.edit_expense(%L, jsonb_build_object('categoryId','rent','description','x','amount','1.00','expenseDate',%L))$$, m33check.getv('e_rent'), v_today)), 'WR409');

  -- ===================== G. immutability (even for the table owner) =====================
  perform m33check.as_('owner');
  perform m33check.ok('G1', 'an approved expense''s amount cannot change', m33check.try(format($$update public.expenses set amount = 1 where id=%L$$, m33check.getv('e_rent'))), '42501');
  perform m33check.ok('G2', '... nor its order, date or category', m33check.try(format($$update public.expenses set category_id='internet', expense_date=current_date - 1 where id=%L$$, m33check.getv('e_rent'))), '42501');
  perform m33check.ok('G3', 'an expense cannot be deleted', m33check.try(format($$delete from public.expenses where id=%L$$, m33check.getv('e_rent'))), '42501');
  perform m33check.ok('G4', 'events cannot be changed', m33check.try($$update public.expense_events set note = 'x'$$), '42501');
  perform m33check.ok('G5', 'events cannot be deleted', m33check.try($$delete from public.expense_events$$), '42501');
  perform m33check.ok('G6', 'the reference never changes', m33check.try(format($$update public.expenses set reference='EXP-HACK' where id=%L$$, m33check.getv('e_rent'))), '42501');

  -- ===================== H. payments (separate from approval) =====================
  perform m33check.as_('u-stg-ops');
  perform m33check.ok('H1', 'a pending expense cannot be paid', m33check.try(format($$select public.record_expense_payment(%L, 10, %L::date, 'Cash')$$, m33check.getv('e_adm'), v_today)), 'WR409');
  perform m33check.as_('u-stg-manager');
  perform m33check.ok('H2', 'an approver without pay_expenses cannot pay', m33check.try(format($$select public.record_expense_payment(%L, 10, %L::date, 'Cash')$$, m33check.getv('e_rent'), v_today)), '42501');
  perform m33check.as_('u-stg-ops');
  a := m33check.try(format($$select public.record_expense_payment(%L, 50, %L::date, 'EVC Plus', 'EVC-1')$$, m33check.getv('e_rent'), v_today));
  perform m33check.ok('H3', 'a payer records a partial payment', a, 'OK|');   perform m33check.setv('p1', m33check.uid(a));
  perform m33check.ok('H4', 'status partial, paid 50, outstanding 80', m33check.n(format($$select payment_status||'/'||paid_amount||'/'||outstanding_amount from public.expense_overview where id=%L$$, m33check.getv('e_rent'))), 'partial/50.00/80.00');
  perform m33check.ok('H5', 'overpaying is refused', m33check.try(format($$select public.record_expense_payment(%L, 80.01, %L::date, 'Cash')$$, m33check.getv('e_rent'), v_today)), 'WR409');
  perform m33check.ok('H6', 'a future payment date is refused', m33check.try(format($$select public.record_expense_payment(%L, 10, %L::date, 'Cash')$$, m33check.getv('e_rent'), v_fut)), '22023');
  perform m33check.ok('H7', 'three decimals refused', m33check.try(format($$select public.record_expense_payment(%L, 10.005, %L::date, 'Cash')$$, m33check.getv('e_rent'), v_today)), '22023');
  a := m33check.try(format($$select public.record_expense_payment(%L, 80, %L::date, 'Cash')$$, m33check.getv('e_rent'), v_today));  perform m33check.setv('p2', m33check.uid(a));
  perform m33check.ok('H8', 'the remainder pays it in full', m33check.n(format($$select payment_status||'/'||outstanding_amount from public.expense_overview where id=%L$$, m33check.getv('e_rent'))), 'paid/0.00');
  perform m33check.as_('u-stg-manager');
  perform m33check.ok('H9', 'an approved expense with active payments cannot be voided', m33check.try(format($$select public.void_expense(%L,'entered twice')$$, m33check.getv('e_rent'))), 'WR409');
  perform m33check.as_('owner');
  perform m33check.ok('H10', 'a payment cannot be deleted', m33check.try(format($$delete from public.expense_payments where id=%L$$, m33check.getv('p1'))), '42501');
  perform m33check.ok('H11', 'a payment''s amount cannot be edited', m33check.try(format($$update public.expense_payments set amount = 1 where id=%L$$, m33check.getv('p1'))), '42501');
  perform m33check.as_('u-stg-ops');
  perform m33check.ok('H12', 'voiding a payment needs a reason', m33check.try(format($$select public.void_expense_payment(%L,'')$$, m33check.getv('p2'))), '22023');
  perform m33check.ok('H13', 'a payer voids a payment', m33check.try(format($$select public.void_expense_payment(%L,'Wrong amount')$$, m33check.getv('p2'))), 'OK|');
  perform m33check.ok('H14', 'status returns to partial; a void payment cannot be voided again', m33check.n(format($$select payment_status||'/'||paid_amount from public.expense_overview where id=%L$$, m33check.getv('e_rent'))) || '|' ||
       m33check.try(format($$select public.void_expense_payment(%L,'again')$$, m33check.getv('p2'))), 'partial/50.00|WR409');

  -- ===================== I. void =====================
  perform m33check.as_('u-stg-ops'); perform m33check.try(format($$select public.void_expense_payment(%L,'Wrong method')$$, m33check.getv('p1')));
  perform m33check.as_('u-stg-manager');
  perform m33check.ok('I1', 'voiding needs a reason', m33check.try(format($$select public.void_expense(%L,'')$$, m33check.getv('e_rent'))), '22023');
  perform m33check.as_('u-stg-cs');
  perform m33check.ok('I2', 'a submitter cannot void their own approved expense', m33check.try(format($$select public.void_expense(%L,'changed my mind')$$, m33check.getv('e_rent'))), '42501');
  perform m33check.as_('u-stg-manager');
  perform m33check.ok('I3', 'an approver voids an approved expense (no active payments left)', m33check.try(format($$select public.void_expense(%L,'Entered twice')$$, m33check.getv('e_rent'))), 'OK|');
  perform m33check.as_('owner');
  perform m33check.ok('I4', 'the void is recorded with who and why', m33check.n(format($$select approval_status||'/'||void_reason||'/'||voided_by from public.expenses where id=%L$$, m33check.getv('e_rent'))), 'void/Entered twice/u-stg-manager');
  perform m33check.ok('I5', 'a void expense cannot be changed at all', m33check.try(format($$update public.expenses set notes='x' where id=%L$$, m33check.getv('e_rent'))), '42501');
  perform m33check.as_('u-stg-ops');
  perform m33check.ok('I6', 'a void expense cannot be paid', m33check.try(format($$select public.record_expense_payment(%L, 10, %L::date, 'Cash')$$, m33check.getv('e_rent'), v_today)), 'WR409');
  a := m33check.sub('u-stg-delivery', 'transport_allowance', '9.00', v_today);               perform m33check.setv('e_w', m33check.uid(a));
  perform m33check.as_('u-stg-delivery');
  perform m33check.ok('I7', 'a submitter withdraws their own pending expense', m33check.try(format($$select public.void_expense(%L,'Entered by mistake')$$, m33check.getv('e_w'))), 'OK|');
  a := m33check.sub('u-stg-admin', 'utilities', '25.00', v_today);                          perform m33check.setv('e_adm2', m33check.uid(a));
  perform m33check.as_('u-stg-manager'); perform m33check.try(format($$select public.decide_expense(%L,'approve')$$, m33check.getv('e_adm2')));
  perform m33check.as_('u-stg-admin');
  perform m33check.ok('I8', 'Super Admin cannot void their own approved expense either', m33check.try(format($$select public.void_expense(%L,'x do over')$$, m33check.getv('e_adm2'))), '42501|You cannot void your own approved');

  -- ===================== J. audit completeness =====================
  perform m33check.as_('owner');
  perform m33check.ok('J1', 'the rent expense has the full timeline in order', m33check.n(format($$select string_agg(event, ',' order by seq) from public.expense_events where expense_id=%L$$, m33check.getv('e_rent'))),
       'submitted,edited,rejected,resubmitted,approved,payment_recorded,payment_recorded,payment_voided,payment_voided,voided');
  perform m33check.ok('J2', 'every event has one FINANCIAL audit line', m33check.n(format($$select (select count(*) from public.expense_events where expense_id=%L)||'/'||(select count(*) from public.system_logs where category='FINANCIAL' and target_id=%L and metadata->>'source'='db')$$, m33check.getv('e_rent'), m33check.getv('e_rent'))), '10/10');
  perform m33check.ok('J3', 'audit lines name the signed-in staff member', m33check.n(format($$select username from public.system_logs where category='FINANCIAL' and target_id=%L and message like '%%rejected%%'$$, m33check.getv('e_rent'))), (select name from public.profiles where id = 'u-stg-manager'));
  perform m33check.ok('J4', 'events carry before/after on edits', m33check.n(format($$select (details->'before'->>'amount')||'>'||(details->'after'->>'amount') from public.expense_events where expense_id=%L and event='edited'$$, m33check.getv('e_rent'))), '120.00>130');

  -- ===================== K. profit-chain reads =====================
  perform m33check.as_('owner');
  perform m33check.ok('K1', 'owner baseline: approved non-void expenses', m33check.n($$select count(*) from public.expenses where approval_status='approved'$$), '2');
  insert into public.user_permissions (user_id, permission_code) values ('u-stg-inventory', 'view_reports') on conflict do nothing;
  perform m33check.as_('u-stg-manager');
  perform m33check.ok('K2', 'a manager with reports + approve sees the approved ones only', m33check.n($$select count(*) from public.finance_expense_costs()$$), '2');
  perform m33check.ok('K3', 'no vendor / description / notes leave the function', m33check.n($$select count(*) from information_schema.parameters where specific_schema='public' and specific_name like 'finance_expense_costs%' and parameter_mode='OUT' and parameter_name in ('description','vendor','notes','submitted_by')$$), '0');
  perform m33check.as_('u-stg-inventory');
  perform m33check.ok('K4', 'reports without expense access is refused (no partial figure)', m33check.try($$select count(*) from public.finance_expense_costs()$$), '42501');
  perform m33check.as_('u-stg-cs');
  perform m33check.ok('K5', 'a submitter without reports is refused', m33check.try($$select count(*) from public.finance_expense_costs()$$), '42501');
  perform m33check.as_('u-stg-manager');
  a := m33check.n($$select count(*) from public.finance_commission_costs()$$);
  perform m33check.as_('owner');
  b := m33check.n($$select count(*) from public.commissions c join public.orders o on o.id=c.order_id where c.status <> 'void' and c.amount > 0$$);
  perform m33check.ok('K6', 'commission costs = every non-void positive commission', a, b);
  perform m33check.as_('u-stg-manager');
  perform m33check.ok('K7', 'void commissions never appear', m33check.n($$select count(*) from public.finance_commission_costs() where status = 'void'$$), '0');
  perform m33check.ok('K8', 'every cost row is dated', m33check.n($$select count(*) from public.finance_commission_costs() where attributed_at is null$$), '0');
  perform m33check.as_('u-stg-officer1');
  perform m33check.ok('K9', 'an officer without reports cannot read commission costs', m33check.try($$select count(*) from public.finance_commission_costs()$$), '42501');
  perform m33check.as_('anon');
  perform m33check.ok('K10', 'anon cannot call the finance reads', m33check.try($$select count(*) from public.finance_commission_costs()$$), '42501');

  -- ===================== Z. nothing else moved =====================
  perform m33check.as_('owner');
  v_fp1 := (select md5(concat((select count(*) from orders), '/', (select coalesce(sum(total),0) from orders), '/', (select coalesce(sum(amount_paid),0) from orders), '/',
            (select count(*) from payments), '/', (select count(*) from commissions), '/', (select coalesce(sum(amount),0) from commissions), '/', (select count(*) from stock_movements), '/',
            (select coalesce(sum(stock),0) from products), '/', (select count(*) from customers))));
  perform m33check.ok('Z1', 'orders, payments, commissions, stock and customers are unchanged', v_fp1, v_fp0);
end
$run$;

do $report$
declare
  v_pass int; v_fail int; v_lines text;
begin
  perform set_config('role', 'none', true);
  select count(*) filter (where result = 'PASS'), count(*) filter (where result = 'FAIL') into v_pass, v_fail from m33check.r;
  select string_agg(result || ' ' || id || ' ' || name || case when result = 'FAIL' then '  [' || info || ']' else '' end, E'\n' order by n) into v_lines from m33check.r;
  raise exception E'M33 CHECKS: % PASS, % FAIL\n%', v_pass, v_fail, v_lines;
end
$report$;
