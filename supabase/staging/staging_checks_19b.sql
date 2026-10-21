-- ============================================================================
-- EFZ - STAGING CHECKS FOR MIGRATION 19b   (EFZ-STAGING ONLY - rollback-only)
-- ----------------------------------------------------------------------------
-- psql only. Run in the guarded Staging window as the project's postgres role,
-- after 19b. ONE transaction that ends in ROLLBACK: every grant and every audit
-- line it creates disappears again.
-- Actors (PostgREST-style role + JWT claims, as in staging_checks_19):
--   SA = u-stg-admin (Super Admin)    UM = u-stg-manager (Manager WITH manage_users)
--   M  = u-stg-ops (Manager, no manage_users)    D = u-stg-delivery (target)
-- Exit status: 0 = every check PASSED; non-zero = a guard refused or a check FAILED.
-- ============================================================================
\set ON_ERROR_STOP on
\pset pager off
begin;
set local lock_timeout = '10s';
set local statement_timeout = '180s';
set local search_path = public, extensions;

-- 0. ENVIRONMENT GUARD (fail closed) -----------------------------------------
do $guard$
begin
  if not exists (select 1 from public.products where id like 'prod-stg-%')
     or not exists (select 1 from public.profiles where id = 'u-stg-admin' and role = 'Super Admin')
     or exists (select 1 from public.products where id = 'prod-1787244881309')
     or exists (select 1 from public.profiles where id = 'u-1') then
    raise exception 'REFUSED: not EFZ-Staging (synthetic markers missing or Production markers present)';
  end if;
  if to_regprocedure('public.log_permission_changes()') is null then
    raise exception 'REFUSED: Migration 19b not applied';
  end if;
  if exists (select 1 from public.user_permissions where user_id = 'u-stg-delivery'
              and permission_code in ('manage_website_requests', 'view_website_requests', 'manage_system')) then
    raise exception 'REFUSED: the Delivery test account already holds a code this script grants';
  end if;
end
$guard$;

-- 1. HELPERS (inside the transaction; rolled back) ----------------------------
create schema m19bcheck;
grant usage on schema m19bcheck to anon, authenticated, service_role;
create table m19bcheck.r (n serial primary key, section text, id text, name text, result text, info text);
grant all on m19bcheck.r to anon, authenticated, service_role;
grant usage on sequence m19bcheck.r_n_seq to anon, authenticated, service_role;
create table m19bcheck.seen (id text primary key);
insert into m19bcheck.seen select id from public.system_logs;

create function m19bcheck.as_(p_who text) returns void language plpgsql as $f$
begin
  perform set_config('role', 'none', true);
  if p_who = 'owner' then
    perform set_config('request.jwt.claims', '', true);
  else
    if not exists (select 1 from public.profiles where id = p_who and auth_user_id is not null) then
      raise exception 'STOPPED: staff user % is missing or has no sign-in', p_who;
    end if;
    perform set_config('request.jwt.claims',
      json_build_object('sub', (select auth_user_id from public.profiles where id = p_who), 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);
  end if;
end $f$;

create function m19bcheck.try(p_sql text) returns text language plpgsql as $f$
declare v text;
begin
  execute p_sql into v;
  return 'OK|' || coalesce(v, '');
exception when others then
  return sqlstate || '|' || sqlerrm;
end $f$;

create function m19bcheck.ok(p_section text, p_id text, p_name text, p_got text, p_want text) returns void language sql as $f$
  insert into m19bcheck.r (section, id, name, result, info)
  values (p_section, p_id, p_name,
          case when coalesce(p_got, '<null>') = p_want then 'PASS' else 'FAIL' end,
          left(coalesce(p_got, '<null>'), 300) || case when coalesce(p_got, '<null>') = p_want then '' else '  | expected: ' || p_want end);
$f$;

-- New system_logs lines since the last call (as the owner), oldest message first; marks them seen.
create function m19bcheck.newlines() returns text language plpgsql as $f$
declare v text;
begin
  select coalesce(string_agg(l.severity::text || '|' || coalesce(l.user_id, '-') || '|' || coalesce(l.origin, '-') || '|' || l.message, ' || ' order by l.message), '')
    into v from public.system_logs l where l.id not in (select id from m19bcheck.seen);
  insert into m19bcheck.seen select id from public.system_logs on conflict do nothing;
  return v;
end $f$;

create function m19bcheck.codes(p_user text) returns text language sql as $f$
  select coalesce(string_agg(permission_code, ',' order by permission_code), '') from public.user_permissions where user_id = p_user;
$f$;

select m19bcheck.codes('u-stg-delivery') as d0 \gset
-- a non-reserved code the target does not hold (for the UPDATE path)
select code as spare from public.permissions
 where code <> all(string_to_array(:'d0', ',') || public.reserved_permissions() || array['view_website_requests', 'manage_website_requests'])
 order by sort_order, code limit 1 \gset

-- 2. INSTALLATION ----------------------------------------------------------------
select m19bcheck.ok('install', 'I1', '3 enabled statement triggers on user_permissions',
  (select count(*)::text from pg_trigger where tgrelid = 'public.user_permissions'::regclass and not tgisinternal and tgenabled = 'O'
     and tgname like 'trg_user_permissions_audit_%' and (tgtype & 1) = 0), '3');
select m19bcheck.ok('install', 'I2', 'log_permission_changes() not executable by anon/authenticated',
  has_function_privilege('anon', 'public.log_permission_changes()', 'EXECUTE')::text || '/' ||
  has_function_privilege('authenticated', 'public.log_permission_changes()', 'EXECUTE')::text, 'false/false');
select m19bcheck.ok('install', 'I3', 'set_user_permissions unchanged',
  md5(pg_get_functiondef('public.set_user_permissions(text,text[])'::regprocedure)), 'ca619ff06ed78a224708855b937256b0');
select m19bcheck.ok('install', 'I4', 'system_logs has no UPDATE/DELETE policy (append-only)',
  (select count(*)::text from pg_policies where schemaname = 'public' and tablename = 'system_logs' and cmd in ('UPDATE', 'DELETE', 'ALL')), '0');

-- 3. RECORDED CHANGES (set_user_permissions as the Super Admin) --------------------
select m19bcheck.as_('u-stg-admin');
select m19bcheck.ok('audit', 'A1a', 'SA grants D view + manage: the call succeeds',
  split_part(m19bcheck.try(format('select public.set_user_permissions(%L, string_to_array(%L, '','') || array[''view_website_requests'',''manage_website_requests''])::text', 'u-stg-delivery', :'d0')), '|', 1), 'OK');
select m19bcheck.as_('owner');
select m19bcheck.ok('audit', 'A1b', 'exactly one database line: granted, both codes, actor SA, INFO',
  m19bcheck.newlines(), 'INFO|u-stg-admin|database|Permissions granted to Test Delivery Staff (u-stg-delivery): manage_website_requests, view_website_requests');
select m19bcheck.ok('audit', 'A1c', 'metadata: event, target, codes, reserved=false, actor',
  (select (metadata ->> 'event') || '|' || target_id || '|' || (metadata -> 'codes')::text || '|' || (metadata ->> 'reserved') || '|' || (metadata ->> 'actor') || '|' || category::text
     from public.system_logs where message like 'Permissions granted to Test Delivery Staff%' order by occurred_at desc limit 1),
  'permissions_granted|u-stg-delivery|["manage_website_requests", "view_website_requests"]|false|u-stg-admin|SECURITY');

select m19bcheck.as_('u-stg-admin');
select public.set_user_permissions('u-stg-delivery', string_to_array(:'d0', ',') || array['view_website_requests']);
select m19bcheck.as_('owner');
select m19bcheck.ok('audit', 'A2', 'revoking one code: exactly one revoked line, nothing granted',
  m19bcheck.newlines(), 'INFO|u-stg-admin|database|Permissions revoked from Test Delivery Staff (u-stg-delivery): manage_website_requests');

select m19bcheck.as_('u-stg-admin');
select public.set_user_permissions('u-stg-delivery', string_to_array(:'d0', ',') || array['view_website_requests']);
select m19bcheck.as_('owner');
select m19bcheck.ok('audit', 'A3', 'no-op save (same set): no line', m19bcheck.newlines(), '');

select m19bcheck.as_('u-stg-admin');
select public.set_user_permissions('u-stg-delivery', string_to_array(:'d0', ',') || array['view_website_requests', 'not_a_real_code']);
select m19bcheck.as_('owner');
select m19bcheck.ok('audit', 'A4', 'unknown code (skipped by the function) is not reported; nothing changed, no line',
  m19bcheck.newlines() || '#' || (m19bcheck.codes('u-stg-delivery') like '%not_a_real_code%')::text, '#false');

select m19bcheck.as_('u-stg-admin');
select public.set_user_permissions('u-stg-delivery', string_to_array(:'d0', ',') || array['view_website_requests', 'manage_system']);
select m19bcheck.as_('owner');
select m19bcheck.ok('audit', 'A5', 'a reserved permission is logged as WARNING with reserved=true',
  m19bcheck.newlines() || '#' || (select metadata ->> 'reserved' from public.system_logs where message like 'Permissions granted to Test Delivery Staff (u-stg-delivery): manage_system' limit 1),
  'WARNING|u-stg-admin|database|Permissions granted to Test Delivery Staff (u-stg-delivery): manage_system#true');
select m19bcheck.as_('u-stg-admin');
select public.set_user_permissions('u-stg-delivery', string_to_array(:'d0', ',') || array['view_website_requests']);
select m19bcheck.as_('owner');
select m19bcheck.ok('audit', 'A5b', 'revoking the reserved permission is WARNING too',
  m19bcheck.newlines(), 'WARNING|u-stg-admin|database|Permissions revoked from Test Delivery Staff (u-stg-delivery): manage_system');

-- 4. FAILED CHANGES LEAVE NO LINE ------------------------------------------------------
select m19bcheck.as_('u-stg-ops');
select m19bcheck.ok('fail', 'F1a', 'Manager without manage_users is refused',
  split_part(m19bcheck.try($q$select public.set_user_permissions('u-stg-delivery', array['view_dashboard'])::text$q$), '|', 1), '42501');
select m19bcheck.as_('u-stg-manager');
select m19bcheck.ok('fail', 'F1b', 'user manager granting a code they do not hold (manage_system, reserved) is refused',
  split_part(m19bcheck.try(format('select public.set_user_permissions(%L, string_to_array(%L, '','') || array[''view_website_requests'',''manage_system''])::text', 'u-stg-delivery', :'d0')), '|', 1), '42501');
select m19bcheck.as_('owner');
select m19bcheck.ok('fail', 'F1c', 'refused changes: no line, grants unchanged',
  m19bcheck.newlines() || '#' || m19bcheck.codes('u-stg-delivery'),
  '#' || array_to_string(array(select x from unnest(string_to_array(:'d0', ',') || array['view_website_requests']) x where x <> '' order by x), ','));

-- a change that is rolled back takes its line with it
select m19bcheck.as_('u-stg-admin');
do $rb$
begin
  perform public.set_user_permissions('u-stg-delivery', array['view_dashboard']);
  raise exception 'forced rollback';
exception when others then null;
end
$rb$;
select m19bcheck.as_('owner');
select m19bcheck.ok('fail', 'F2', 'rolled-back change: no line and grants unchanged',
  m19bcheck.newlines() || '#' || (m19bcheck.codes('u-stg-delivery') like '%view_website_requests%')::text, '#true');

-- the audit write failing aborts the change (temporary constraint, inside this rolled-back transaction)
alter table public.system_logs add constraint m19b_tmp_refuse check (message not like 'Permissions granted to Test Delivery Staff%') not valid;
select m19bcheck.as_('u-stg-admin');
select m19bcheck.ok('fail', 'F3a', 'grant whose audit line cannot be written fails',
  split_part(m19bcheck.try(format('select public.set_user_permissions(%L, string_to_array(%L, '','') || array[''view_website_requests'',''manage_website_requests''])::text', 'u-stg-delivery', :'d0')), '|', 1), '23514');
select m19bcheck.as_('owner');
select m19bcheck.ok('fail', 'F3b', '... and the grant did not happen',
  (m19bcheck.codes('u-stg-delivery') like '%manage_website_requests%')::text || '#' || m19bcheck.newlines(), 'false#');
alter table public.system_logs drop constraint m19b_tmp_refuse;

-- 5. OTHER PATHS ------------------------------------------------------------------------
select m19bcheck.as_('u-stg-admin');
insert into public.user_permissions (user_id, permission_code) values ('u-stg-delivery', 'manage_website_requests');
delete from public.user_permissions where user_id = 'u-stg-delivery' and permission_code = 'manage_website_requests';
select m19bcheck.as_('owner');
select m19bcheck.ok('paths', 'X1', 'Super Admin direct insert + delete (user_permissions_write policy): both logged with the actor',
  m19bcheck.newlines(),
  'INFO|u-stg-admin|database|Permissions granted to Test Delivery Staff (u-stg-delivery): manage_website_requests || INFO|u-stg-admin|database|Permissions revoked from Test Delivery Staff (u-stg-delivery): manage_website_requests');

insert into public.user_permissions (user_id, permission_code) values ('u-stg-delivery', 'manage_website_requests');
select m19bcheck.ok('paths', 'X2', 'database session without a signed-in user (migration/service): logged, actor marked',
  m19bcheck.newlines() || '#' || (select metadata ->> 'actor' from public.system_logs where message like 'Permissions granted to Test Delivery Staff (u-stg-delivery): manage_website_requests' and user_id is null limit 1),
  'INFO|-|database|Permissions granted to Test Delivery Staff (u-stg-delivery): manage_website_requests#database session (no signed-in user)');
update public.user_permissions set permission_code = :'spare' where user_id = 'u-stg-delivery' and permission_code = 'manage_website_requests';
select m19bcheck.ok('paths', 'X3', 'UPDATE of a grant row: reported as revoke + grant',
  m19bcheck.newlines(),
  'INFO|-|database|Permissions granted to Test Delivery Staff (u-stg-delivery): ' || :'spare' || ' || INFO|-|database|Permissions revoked from Test Delivery Staff (u-stg-delivery): manage_website_requests');
delete from public.user_permissions where user_id = 'u-stg-delivery' and permission_code = :'spare';
select m19bcheck.newlines();

select m19bcheck.codes('u-stg-delivery') as before_preset \gset
select m19bcheck.as_('u-stg-admin');
select public.grant_role_preset('u-stg-delivery', 'Delivery Staff');
select m19bcheck.as_('owner');
select m19bcheck.codes('u-stg-delivery') as after_preset \gset
select m19bcheck.ok('paths', 'X4', 'grant_role_preset is audited: one line per direction that changed, actor SA, origin database',
  (select count(*)::text from public.system_logs l where l.id not in (select id from m19bcheck.seen)
     and l.message like 'Permissions % Test Delivery Staff (u-stg-delivery): %' and l.user_id = 'u-stg-admin' and l.origin = 'database')
  || '/' || (select count(*)::text from public.system_logs l where l.id not in (select id from m19bcheck.seen)),
  ((exists (select 1 from unnest(string_to_array(:'after_preset', ',')) x where x <> all(string_to_array(:'before_preset', ','))))::int
   + (exists (select 1 from unnest(string_to_array(:'before_preset', ',')) x where x <> all(string_to_array(:'after_preset', ','))))::int)::text
  || '/' ||
  ((exists (select 1 from unnest(string_to_array(:'after_preset', ',')) x where x <> all(string_to_array(:'before_preset', ','))))::int
   + (exists (select 1 from unnest(string_to_array(:'before_preset', ',')) x where x <> all(string_to_array(:'after_preset', ','))))::int)::text);
select m19bcheck.newlines();

-- 6. FORGERY AND TAMPERING -----------------------------------------------------------------
select m19bcheck.as_('u-stg-admin');   -- a client session; the Super Admin can read lines back (RETURNING), so a refusal below is the guard's
select m19bcheck.ok('forge', 'G1', 'client (even Super Admin) cannot write a permission-change line',
  split_part(m19bcheck.try($q$insert into public.system_logs (id, severity, category, message) values ('log-forge1', 'INFO', 'SECURITY', 'Permissions granted to Someone (u-x): manage_users') returning id$q$), 'OK|', 1), '42501|This kind of audit line is written by the database only');
select m19bcheck.ok('forge', 'G2', 'client cannot write a revoked line either',
  split_part(m19bcheck.try($q$insert into public.system_logs (id, severity, category, message) values ('log-forge2', 'INFO', 'SECURITY', 'Permissions revoked from Someone (u-x): view_dashboard') returning id$q$), 'OK|', 1), '42501|This kind of audit line is written by the database only');
select m19bcheck.ok('forge', 'G3', 'browser privileges line is dropped silently (database records the real change)',
  m19bcheck.try($q$insert into public.system_logs (id, severity, category, message) values ('log-forge3', 'INFO', 'SECURITY', 'User privileges updated: X (Manager)') returning id$q$), 'OK|');
select m19bcheck.ok('forge', 'G4', 'client cannot call the audit writer',
  split_part(m19bcheck.try($q$select public.log_permission_changes()::text$q$), '|', 1), '42501');
select m19bcheck.ok('forge', 'G5', 'ordinary client lines still work (origin client)',
  m19bcheck.try($q$insert into public.system_logs (id, severity, category, message) values ('log-m19b-ordinary', 'INFO', 'SYSTEM', 'm19b ordinary client line') returning id$q$), 'OK|log-m19b-ordinary');
select m19bcheck.as_('u-stg-admin');
select m19bcheck.ok('forge', 'G6', 'even a Super Admin cannot edit or delete an audit line (0 rows)',
  (select count(*)::text from public.system_logs where message like 'Permissions % Test Delivery Staff%') || '>' ||
  m19bcheck.try($q$with u as (update public.system_logs set message = 'tampered' where message like 'Permissions % Test Delivery Staff%' returning 1) select count(*)::text from u$q$) || '/' ||
  m19bcheck.try($q$with d as (delete from public.system_logs where message like 'Permissions % Test Delivery Staff%' returning 1) select count(*)::text from d$q$),
  (select count(*)::text from public.system_logs where message like 'Permissions % Test Delivery Staff%') || '>OK|0/OK|0');
select m19bcheck.as_('owner');
select m19bcheck.ok('forge', 'G7', 'nothing forged landed; the ordinary line is origin client',
  (select count(*)::text from public.system_logs where id in ('log-forge1', 'log-forge2', 'log-forge3')) || '/' ||
  (select origin from public.system_logs where id = 'log-m19b-ordinary'), '0/client');
select m19bcheck.ok('forge', 'G8', 'no line in this run is origin client except G5',
  (select count(*)::text from public.system_logs where message like 'Permissions %' and origin <> 'database'), '0');

-- 7. RESULTS, then ROLLBACK ------------------------------------------------------------------
select m19bcheck.as_('owner');
\pset tuples_only off
select n, section, id, result, name, info from m19bcheck.r order by n;
select result, count(*) from m19bcheck.r group by result order by result;
do $result$
declare v_fail integer := (select count(*) from m19bcheck.r where result <> 'PASS');
begin
  if v_fail > 0 then
    raise exception 'staging_checks_19b: % check(s) FAILED - see the table above (everything is rolled back)', v_fail;
  end if;
  raise notice 'staging_checks_19b: all % checks PASSED (rolling back)', (select count(*) from m19bcheck.r);
end
$result$;
rollback;
