-- ============================================================================
-- EFZ - CHECKS FOR MIGRATION 30 (public inquiries)   (EFZ-STAGING ONLY)
-- ----------------------------------------------------------------------------
-- Plain SQL, no psql meta-commands: run with
--   supabase db query --linked --project-ref <STAGING ref> -f supabase/checks/30_public_inquiries_checks.sql
-- ONE transaction that ALWAYS ends in an exception, so every row, grant and
-- notification it creates is rolled back. The exception text IS the report:
--   "M30 CHECKS: n PASS, m FAIL" followed by one line per check.
-- Actors (PostgREST-style role + JWT claims, as staging_checks_19):
--   SA = u-stg-admin (Super Admin)   M = u-stg-ops (Manager, no inquiry permission)
--   C  = u-stg-inventory  granted here: view + view_all + manage + assign
--   D  = u-stg-delivery   granted here: view (+ manage later)   -> assigned-only delegate
--   O  = u-stg-officer1   Marketing Officer, never granted anything
-- ============================================================================
begin;
set local lock_timeout = '10s';
set local statement_timeout = '120s';
set local search_path = public, extensions;

create schema m30check;
grant usage on schema m30check to anon, authenticated, service_role;
create table m30check.r (n serial primary key, id text, name text, result text, info text);
grant all on m30check.r to anon, authenticated, service_role;
grant usage on sequence m30check.r_n_seq to anon, authenticated, service_role;

create function m30check.as_(p_who text) returns void language plpgsql as $f$
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

-- runs a statement as the current role; 'OK|<first column>' or '<sqlstate>|<message>'
create function m30check.try(p_sql text) returns text language plpgsql as $f$
declare v text;
begin
  execute p_sql into v;
  return 'OK|' || coalesce(v, '');
exception when others then
  return sqlstate || '|' || sqlerrm;
end $f$;

create function m30check.ok(p_id text, p_name text, p_got text, p_want text) returns void language sql as $f$
  insert into m30check.r (id, name, result, info)
  values (p_id, p_name,
          case when starts_with(coalesce(p_got, '<null>'), p_want) then 'PASS' else 'FAIL' end,
          left(coalesce(p_got, '<null>'), 200) || case when starts_with(coalesce(p_got, '<null>'), p_want) then '' else '  | expected: ' || p_want end);
$f$;

create function m30check.n(p_sql text) returns text language plpgsql as $f$
declare v text;
begin execute p_sql into v; return v; exception when others then return sqlstate || '|' || sqlerrm; end $f$;

do $guard$
begin
  if not exists (select 1 from public.products where id like 'prod-stg-%')
     or not exists (select 1 from public.profiles where id = 'u-stg-admin' and role = 'Super Admin')
     or exists (select 1 from public.products where id = 'prod-1787244881309')
     or exists (select 1 from public.profiles where id = 'u-1') then
    raise exception 'REFUSED: not EFZ-Staging (synthetic markers missing or Production markers present)';
  end if;
  if to_regprocedure('public.submit_public_inquiry(jsonb)') is null then
    raise exception 'REFUSED: Migration 30 not applied';
  end if;
  if (select count(*) from public.public_inquiries) <> 0 then
    raise exception 'REFUSED: public_inquiries is not empty on this database - checks assume a clean table';
  end if;
end
$guard$;

do $run$
declare
  rid text; id_a uuid; id_b uuid; id_c uuid; id_w uuid; v text; n0 bigint;
  mid text;
begin
  -- grants for this run only (rolled back)
  perform m30check.as_('owner');
  insert into public.user_permissions (user_id, permission_code) values
    ('u-stg-inventory', 'view_inquiries'), ('u-stg-inventory', 'view_all_inquiries'),
    ('u-stg-inventory', 'manage_inquiries'), ('u-stg-inventory', 'assign_inquiries'),
    ('u-stg-delivery',  'view_inquiries');

  -- ============================ ANONYMOUS ===================================
  perform m30check.as_('anon');
  perform m30check.ok('A1', 'anon cannot read the table', m30check.try('select count(*) from public.public_inquiries'), '42501');
  perform m30check.ok('A2', 'anon cannot insert directly', m30check.try($$insert into public.public_inquiries (kind,name,phone,contact_key,content_hash) values ('contact','x','0612223333','k','h')$$), '42501');
  perform m30check.ok('A3', 'anon cannot read notes', m30check.try('select count(*) from public.public_inquiry_notes'), '42501');
  perform m30check.ok('A4', 'anon cannot read events', m30check.try('select count(*) from public.public_inquiry_events'), '42501');
  perform m30check.ok('A5', 'anon cannot change status', m30check.try($$select public.set_public_inquiry_status(gen_random_uuid(),'closed',null)$$), '42501');
  perform m30check.ok('A6', 'anon cannot add a note', m30check.try($$select public.add_public_inquiry_note(gen_random_uuid(),'x')$$), '42501');
  perform m30check.ok('A7', 'anon cannot assign', m30check.try($$select public.assign_public_inquiry(gen_random_uuid(),null)$$), '42501');
  perform m30check.ok('A8', 'anon cannot list assignees', m30check.try('select count(*) from public.public_inquiry_assignees()'), '42501');

  -- ============================ SUBMISSION ==================================
  v := m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"Chk One","phone":"061 900 0001","subject":"Hello","message":"First message","submissionKey":"11111111-1111-4111-8111-111111111111"}'::jsonb)$$);
  perform m30check.ok('B1', 'valid contact accepted', v, 'OK|');
  id_a := nullif(split_part(v, '|', 2), '')::uuid;
  perform m30check.ok('B2', 'same submissionKey returns the same id', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"Chk One","phone":"061 900 0001","subject":"Hello","message":"First message","submissionKey":"11111111-1111-4111-8111-111111111111"}'::jsonb)$$), 'OK|' || id_a);
  perform m30check.ok('B3', 'identical content with a NEW key returns the same id', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"chk one","phone":"0619000001","subject":"hello","message":"first message","submissionKey":"22222222-2222-4222-8222-222222222222"}'::jsonb)$$), 'OK|' || id_a);
  perform m30check.as_('owner');
  perform m30check.ok('B4', 'exactly one row for those three submissions', m30check.n($$select count(*) from public.public_inquiries where contact_key = '+252619000001'$$), '1');
  perform m30check.ok('B5', 'phone stored canonical', m30check.n($$select phone_canonical from public.public_inquiries where id = '$$ || id_a || $$'$$), '+252619000001');
  perform m30check.ok('B6', 'submitted event written', m30check.n($$select count(*) from public.public_inquiry_events where inquiry_id = '$$ || id_a || $$' and event = 'submitted'$$), '1');
  perform m30check.ok('B7', 'audit line written by the database', m30check.n($$select origin::text from public.system_logs where target_id = '$$ || id_a || $$' and message like 'Inquiry INQ-%received%'$$), 'database');

  n0 := (select count(*) from public.public_inquiries);
  perform m30check.as_('anon');
  perform m30check.ok('B8', 'honeypot returns success', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"Bot","email":"bot@example.com","subject":"s","message":"buy now","hp":"http://spam"}'::jsonb)$$), 'OK|');
  perform m30check.as_('owner');
  perform m30check.ok('B9', 'honeypot stores nothing', m30check.n('select count(*) from public.public_inquiries')::text, n0::text);

  perform m30check.as_('anon');
  perform m30check.ok('V1', 'unknown kind refused', m30check.try($$select public.submit_public_inquiry('{"kind":"other","name":"x","phone":"0619000002","subject":"s","message":"m"}'::jsonb)$$), '22023');
  perform m30check.ok('V2', 'empty name refused', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"  ","phone":"0619000002","subject":"s","message":"m"}'::jsonb)$$), '22023');
  perform m30check.ok('V3', 'bad email refused', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"x","email":"not-an-email","subject":"s","message":"m"}'::jsonb)$$), '22023');
  perform m30check.ok('V4', 'contact needs a phone or an email', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"x","subject":"s","message":"m"}'::jsonb)$$), '22023');
  perform m30check.ok('V5', 'contact needs a subject', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"x","email":"a@b.co","message":"m"}'::jsonb)$$), '22023');
  perform m30check.ok('V6', 'contact needs a message', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"x","email":"a@b.co","subject":"s"}'::jsonb)$$), '22023');
  perform m30check.ok('V7', 'contact with only an email is accepted', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"Email Only","email":"email.only@example.com","subject":"s","message":"m"}'::jsonb)$$), 'OK|');
  perform m30check.ok('V8', 'bad phone refused with WR422', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"x","phone":"12345","subject":"s","message":"m"}'::jsonb)$$), 'WR422');
  perform m30check.ok('V9', 'overlong message refused', m30check.try('select public.submit_public_inquiry(jsonb_build_object(''kind'',''contact'',''name'',''x'',''email'',''a@b.co'',''subject'',''s'',''message'',repeat(''x'',3001)))'), '22023');
  perform m30check.ok('V10', 'bad submissionKey refused', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"x","email":"a@b.co","subject":"s","message":"m","submissionKey":"nope"}'::jsonb)$$), '22023');
  perform m30check.ok('V11', 'wholesale needs a phone', m30check.try($$select public.submit_public_inquiry('{"kind":"wholesale","name":"x","organization":"Org","businessType":"Futsal Arena"}'::jsonb)$$), 'WR422');
  perform m30check.ok('V12', 'wholesale needs an organization', m30check.try($$select public.submit_public_inquiry('{"kind":"wholesale","name":"x","phone":"0619000003","businessType":"Futsal Arena"}'::jsonb)$$), '22023');
  perform m30check.ok('V13', 'wholesale needs a listed business type', m30check.try($$select public.submit_public_inquiry('{"kind":"wholesale","name":"x","phone":"0619000003","organization":"Org","businessType":"Hacker"}'::jsonb)$$), '22023');
  perform m30check.ok('V14', 'null payload refused', m30check.try($$select public.submit_public_inquiry(null)$$), '22023');
  perform m30check.ok('V15', 'array payload refused', m30check.try($$select public.submit_public_inquiry('[]'::jsonb)$$), '22023');

  v := m30check.try($$select public.submit_public_inquiry('{"kind":"wholesale","name":"Chk Wholesale","phone":"+252 61 900 0004","organization":"Chk Arena","businessType":"Futsal Arena","message":"50 balls a month"}'::jsonb)$$);
  perform m30check.ok('W1', 'valid wholesale accepted', v, 'OK|');
  id_w := nullif(split_part(v, '|', 2), '')::uuid;
  perform m30check.ok('W2', 'wholesale with empty product text accepted', m30check.try($$select public.submit_public_inquiry('{"kind":"wholesale","name":"Chk W2","phone":"0619000005","organization":"Org2","businessType":"Other"}'::jsonb)$$), 'OK|');

  -- per-visitor limit: 3 per kind per window, then WR429
  perform m30check.ok('L1', 'limit: message 1/3', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"Lim","phone":"0619000006","subject":"a","message":"one"}'::jsonb)$$), 'OK|');
  perform m30check.ok('L2', 'limit: message 2/3', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"Lim","phone":"0619000006","subject":"a","message":"two"}'::jsonb)$$), 'OK|');
  perform m30check.ok('L3', 'limit: message 3/3', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"Lim","phone":"0619000006","subject":"a","message":"three"}'::jsonb)$$), 'OK|');
  perform m30check.ok('L4', 'limit: 4th different message refused WR429', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"Lim","phone":"0619000006","subject":"a","message":"four"}'::jsonb)$$), 'WR429');
  perform m30check.ok('L5', 'limit: re-sending an accepted message is still idempotent', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"Lim","phone":"0619000006","subject":"a","message":"one"}'::jsonb)$$), 'OK|');
  perform m30check.ok('L6', 'limit is per kind: wholesale from the same phone is allowed', m30check.try($$select public.submit_public_inquiry('{"kind":"wholesale","name":"Lim","phone":"0619000006","organization":"Lim Org","businessType":"Other"}'::jsonb)$$), 'OK|');
  perform m30check.ok('L7', 'limit by email when there is no phone', (select string_agg(r, ',') from (
      select left(m30check.try(format($j$select public.submit_public_inquiry('{"kind":"contact","name":"E","email":"Lim.Mail@Example.com","subject":"s","message":"m%s"}'::jsonb)$j$, g)), 3) r from generate_series(1,4) g) q), 'OK|,OK|,OK|,WR4');

  perform m30check.as_('owner');
  -- per-network limit: 30 distinct visitors behind one address, then the 31st is refused; another address is unaffected
  perform set_config('request.headers', '{"x-forwarded-for":"203.0.113.9, 10.0.0.1"}', true);
  perform m30check.as_('anon');
  perform m30check.ok('N1', 'network limit: 30 different visitors from one address are accepted', (select count(*) filter (where r like 'OK|%') from (
      select m30check.try(format($j$select public.submit_public_inquiry('{"kind":"contact","name":"Net","email":"net%s@example.com","subject":"s","message":"m"}'::jsonb)$j$, g)) r
        from generate_series(1, 30) g) q)::text, '30');
  perform m30check.ok('N2', 'network limit: the 31st from the same address is refused WR429', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"Net","email":"net31@example.com","subject":"s","message":"m"}'::jsonb)$$), 'WR429');
  perform set_config('request.headers', '{"x-forwarded-for":"203.0.113.77"}', true);
  perform m30check.ok('N3', 'network limit: a different address is unaffected', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"Net","email":"other@example.com","subject":"s","message":"m"}'::jsonb)$$), 'OK|');
  perform set_config('request.headers', '', true);
  perform m30check.ok('N4', 'a missing or empty header skips the network limit (still validated)', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"Net","email":"noheader@example.com","subject":"s","message":"m"}'::jsonb)$$), 'OK|');
  perform m30check.as_('owner');
  perform m30check.ok('N5', 'the raw address is never stored (only a hash)', m30check.n($$select count(*) from public.public_inquiries where ip_hash is not null and ip_hash like '%203.0.113%'$$), '0');
  perform m30check.ok('N6', 'the hash is stored for the limit', m30check.n($$select count(*) from public.public_inquiries where ip_hash = md5('efz-inquiry-ip|203.0.113.9')$$), '30');
  perform m30check.ok('L8', 'rows after limit tests = 3 for the limited phone', m30check.n($$select count(*) from public.public_inquiries where contact_key = '+252619000006' and kind = 'contact'$$), '3');

  v := m30check.n($$select id from public.public_inquiries where contact_key = '+252619000006' and kind = 'contact' order by created_at limit 1$$);
  id_b := v::uuid;
  v := m30check.n($$select id from public.public_inquiries where contact_key = 'email:email.only@example.com' limit 1$$);
  id_c := v::uuid;

  -- ============================ STAFF: ACCESS ===============================
  perform m30check.as_('u-stg-ops');
  perform m30check.ok('S1', 'Manager without inquiry permission sees none', m30check.n('select count(*) from public.public_inquiries'), '0');
  perform m30check.ok('S2', 'Manager cannot set status', m30check.try(format($$select public.set_public_inquiry_status(%L,'contacted',null)$$, id_a)), '42501');
  perform m30check.as_('u-stg-officer1');
  perform m30check.ok('S3', 'Marketing Officer sees none', m30check.n('select count(*) from public.public_inquiries'), '0');
  perform m30check.as_('u-stg-admin');
  perform m30check.ok('S4', 'Super Admin sees all', m30check.n('select count(*) >= 8 from public.public_inquiries'), 'true');
  perform m30check.ok('S5', 'Super Admin sees notes/events tables', m30check.n('select count(*) > 0 from public.public_inquiry_events'), 'true');
  perform m30check.as_('u-stg-delivery');
  perform m30check.ok('S6', 'view-only delegate sees none until assigned', m30check.n('select count(*) from public.public_inquiries'), '0');
  perform m30check.ok('S7', 'delegate cannot add a note without manage_inquiries', m30check.try(format($$select public.add_public_inquiry_note(%L,'x')$$, id_a)), '42501');

  -- direct writes never possible, even for the Super Admin
  perform m30check.as_('u-stg-admin');
  perform m30check.ok('D1', 'Super Admin cannot UPDATE directly', m30check.try(format($$update public.public_inquiries set status='closed' where id=%L$$, id_a)), '42501');
  perform m30check.ok('D2', 'Super Admin cannot DELETE directly', m30check.try(format($$delete from public.public_inquiries where id=%L$$, id_a)), '42501');
  perform m30check.ok('D3', 'Super Admin cannot INSERT directly', m30check.try($$insert into public.public_inquiries (kind,name,phone,contact_key,content_hash) values ('contact','x','0612223333','k','h')$$), '42501');
  perform m30check.ok('D4', 'Super Admin cannot write events directly', m30check.try(format($$insert into public.public_inquiry_events (inquiry_id,event) values (%L,'submitted')$$, id_a)), '42501');

  -- ============================ STAFF: WORKFLOW =============================
  perform m30check.as_('u-stg-inventory');   -- C: view + view_all + manage + assign
  perform m30check.ok('F1', 'C sees all inquiries', m30check.n('select count(*) >= 8 from public.public_inquiries'), 'true');
  perform m30check.ok('F2', 'new -> contacted', m30check.try(format($$select public.set_public_inquiry_status(%L,'contacted',null)$$, id_a)), 'OK|');
  perform m30check.ok('F3', 'contacted -> new refused', m30check.try(format($$select public.set_public_inquiry_status(%L,'new',null)$$, id_a)), 'WR409');
  perform m30check.ok('F4', 'contacted -> closed with a reason', m30check.try(format($$select public.set_public_inquiry_status(%L,'closed','Answered by phone')$$, id_a)), 'OK|');
  perform m30check.ok('F5', 'closed reason stored', m30check.n(format($$select closed_reason from public.public_inquiries where id=%L$$, id_a)), 'Answered by phone');
  perform m30check.ok('F6', 'closed -> contacted (reopen) clears the reason', m30check.try(format($$select public.set_public_inquiry_status(%L,'contacted',null)$$, id_a)), 'OK|');
  perform m30check.ok('F7', 'reason cleared on reopen', coalesce(m30check.n(format($$select closed_reason from public.public_inquiries where id=%L$$, id_a)), '<null>'), '<null>');
  perform m30check.ok('F8', 'over-long reason refused', m30check.try(format($$select public.set_public_inquiry_status(%L,'closed',repeat('x',501))$$, id_a)), '22023');
  perform m30check.ok('F9', 'unknown status refused', m30check.try(format($$select public.set_public_inquiry_status(%L,'converted',null)$$, id_a)), 'WR409');
  perform m30check.ok('F10', 'unknown inquiry refused', m30check.try($$select public.set_public_inquiry_status(gen_random_uuid(),'closed',null)$$), '42501');
  perform m30check.ok('F11', 'add note', m30check.try(format($$select public.add_public_inquiry_note(%L,'Called the visitor')$$, id_a)), 'OK|');
  perform m30check.ok('F12', 'empty note refused', m30check.try(format($$select public.add_public_inquiry_note(%L,'   ')$$, id_a)), '22023');
  perform m30check.ok('F13', 'assignees list works for an assigner', m30check.n('select count(*) >= 2 from public.public_inquiry_assignees()'), 'true');
  perform m30check.ok('F14', 'assign to D (D holds view_inquiries)', m30check.try(format($$select public.assign_public_inquiry(%L,'u-stg-delivery')$$, id_a)), 'OK|');
  perform m30check.ok('F15', 'assign to a user without view_inquiries refused', m30check.try(format($$select public.assign_public_inquiry(%L,'u-stg-officer1')$$, id_a)), '22023');
  perform m30check.ok('F16', 'assign to an unknown user refused', m30check.try(format($$select public.assign_public_inquiry(%L,'nobody')$$, id_a)), '22023');

  perform m30check.as_('owner');
  perform m30check.ok('F17', 'assignee got a notification', m30check.n($$select count(*) from public.notifications where user_id='u-stg-delivery' and id like 'inqasg-%'$$), '1');
  perform m30check.ok('F18', 'status/assign/note events recorded', m30check.n(format($$select count(distinct event) from public.public_inquiry_events where inquiry_id=%L$$, id_a)), '4');
  perform m30check.ok('F19', 'audit lines for status and assignment', (m30check.n(format($$select count(*) from public.system_logs where target_id=%L and message like 'Inquiry INQ-%%'$$, id_a))::int >= 5)::text, 'true');

  perform m30check.as_('u-stg-delivery');   -- D: view only, assigned id_a
  perform m30check.ok('G1', 'assignee sees ONLY the assigned inquiry', m30check.n('select count(*)::text || id from public.public_inquiries group by id'), '1' || id_a::text);
  perform m30check.ok('G2', 'assignee still cannot add a note without manage', m30check.try(format($$select public.add_public_inquiry_note(%L,'x')$$, id_a)), '42501');
  perform m30check.ok('G3', 'assignee cannot see another inquiry (status call refused)', m30check.try(format($$select public.set_public_inquiry_status(%L,'contacted',null)$$, id_b)), '42501');
  perform m30check.ok('G4', 'assignee cannot assign without assign_inquiries', m30check.try(format($$select public.assign_public_inquiry(%L,null)$$, id_a)), '42501');
  perform m30check.ok('G5', 'assignee cannot list assignees', m30check.try('select count(*) from public.public_inquiry_assignees()'), '42501');
  perform m30check.ok('G6', 'assignee sees the notes of the assigned inquiry only', m30check.n('select count(distinct inquiry_id)::text from public.public_inquiry_notes'), '1');

  perform m30check.as_('owner');
  insert into public.user_permissions (user_id, permission_code) values ('u-stg-delivery', 'manage_inquiries');
  perform m30check.as_('u-stg-delivery');
  perform m30check.ok('G7', 'with manage_inquiries the assignee can add a note', m30check.try(format($$select public.add_public_inquiry_note(%L,'Assignee note')$$, id_a)), 'OK|');
  perform m30check.ok('G8', 'assignee can edit their own note', m30check.try(format($$select public.edit_public_inquiry_note((select id from public.public_inquiry_notes where inquiry_id=%L and author_id='u-stg-delivery' limit 1),'Assignee note (edited)')$$, id_a)), 'OK|');
  perform m30check.as_('u-stg-inventory');
  perform m30check.ok('G9', 'another handler cannot edit that note', m30check.try(format($$select public.edit_public_inquiry_note((select id from public.public_inquiry_notes where inquiry_id=%L and author_id='u-stg-delivery' limit 1),'hijack')$$, id_a)), '42501');
  perform m30check.as_('u-stg-admin');
  perform m30check.ok('G10', 'Super Admin can edit any note', m30check.try(format($$select public.edit_public_inquiry_note((select id from public.public_inquiry_notes where inquiry_id=%L and author_id='u-stg-delivery' limit 1),'Edited by admin')$$, id_a)), 'OK|');

  perform m30check.as_('u-stg-inventory');
  perform m30check.ok('G11', 'unassign works', m30check.try(format($$select public.assign_public_inquiry(%L,null)$$, id_a)), 'OK|');
  perform m30check.as_('u-stg-delivery');
  perform m30check.ok('G12', 'after unassign the delegate sees nothing (immediate)', m30check.n('select count(*) from public.public_inquiries'), '0');

  perform m30check.as_('u-stg-inventory');
  perform m30check.ok('G13', 'close an inquiry', m30check.try(format($$select public.set_public_inquiry_status(%L,'closed',null)$$, id_c)), 'OK|');
  perform m30check.ok('G14', 'assigning a closed inquiry refused', m30check.try(format($$select public.assign_public_inquiry(%L,'u-stg-delivery')$$, id_c)), 'WR409');

  -- revocation is immediate
  perform m30check.as_('owner');
  delete from public.user_permissions where user_id = 'u-stg-inventory' and permission_code = 'view_inquiries';
  perform m30check.as_('u-stg-inventory');
  perform m30check.ok('R1', 'revoked view_inquiries -> sees nothing at once', m30check.n('select count(*) from public.public_inquiries'), '0');
  perform m30check.ok('R2', 'revoked view_inquiries -> status refused', m30check.try(format($$select public.set_public_inquiry_status(%L,'contacted',null)$$, id_b)), '42501');

  -- append-only history, even for the table owner
  perform m30check.as_('owner');
  perform m30check.ok('H1', 'events cannot be updated', m30check.try($$update public.public_inquiry_events set actor_name='x'$$), '42501');
  perform m30check.ok('H2', 'events cannot be deleted', m30check.try($$delete from public.public_inquiry_events where event='submitted'$$), '42501');
  perform m30check.ok('H3', 'notes cannot be deleted while the inquiry exists', m30check.try($$delete from public.public_inquiry_notes$$), '42501');

  perform m30check.ok('X1', 'no inquiry permission was ever granted by the migration', m30check.n($$select count(*) from public.user_permissions where permission_code in ('view_inquiries','view_all_inquiries','manage_inquiries','assign_inquiries') and user_id not in ('u-stg-inventory','u-stg-delivery')$$), '0');
  perform m30check.ok('X2', 'no order, request or customer row was written by any inquiry call', m30check.n($$select count(*) from public.order_requests where customer_name like 'Chk%' or customer_name = 'Lim'$$), '0');
  -- global backstop: 300 inquiries in the last hour close the forms for everyone until the hour passes
  insert into public.public_inquiries (kind, name, email, contact_key, content_hash)
  select 'contact', 'Flood', 'flood' || g || '@example.com', 'email:flood' || g || '@example.com', 'h' || g from generate_series(1, 300) g;
  perform m30check.as_('anon');
  perform m30check.ok('N7', 'flood backstop: with 300 in the last hour a new visitor is told to try later', m30check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"Late","email":"late@example.com","subject":"s","message":"m"}'::jsonb)$$), 'WR429');
  perform m30check.as_('owner');
end
$run$;

do $report$
declare
  v_pass int; v_fail int; v_lines text;
begin
  perform set_config('role', 'none', true);
  select count(*) filter (where result = 'PASS'), count(*) filter (where result = 'FAIL') into v_pass, v_fail from m30check.r;
  select string_agg(result || ' ' || id || ' ' || name || case when result = 'FAIL' then '  [' || info || ']' else '' end, E'\n' order by n) into v_lines from m30check.r;
  raise exception E'M30 CHECKS: % PASS, % FAIL\n%', v_pass, v_fail, v_lines;
end
$report$;
