-- ============================================================================
-- EFZ - CHECKS FOR MIGRATION 31 (inquiry rate limits)   (EFZ-STAGING ONLY)
-- ----------------------------------------------------------------------------
-- STATUS: written 2026-11-04, NEVER RUN (Staging was paused). Expect to fix typos in the first run; the first run is the test.
-- Run: supabase db query --linked --project-ref <STAGING ref> -f supabase/checks/31_inquiry_rate_limits_checks.sql
-- One transaction that ALWAYS ends in an exception, so everything it creates (including the signing secret) is rolled back.
-- The exception text IS the report: "M31 CHECKS: n PASS, m FAIL" followed by one line per check.
-- ============================================================================
begin;
set local lock_timeout = '10s';
set local statement_timeout = '120s';
set local search_path = public, extensions;

create schema m31check;
grant usage on schema m31check to anon, authenticated, service_role;
create table m31check.r (n serial primary key, id text, name text, result text, info text);
grant all on m31check.r to anon, authenticated, service_role;
grant usage on sequence m31check.r_n_seq to anon, authenticated, service_role;

create function m31check.as_(p_who text) returns void language plpgsql as $f$
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
create function m31check.try(p_sql text) returns text language plpgsql as $f$
declare v text;
begin
  execute p_sql into v;
  return 'OK|' || coalesce(v, '');
exception when others then
  return sqlstate || '|' || sqlerrm;
end $f$;

create function m31check.ok(p_id text, p_name text, p_got text, p_want text) returns void language sql as $f$
  insert into m31check.r (id, name, result, info)
  values (p_id, p_name,
          case when starts_with(coalesce(p_got, '<null>'), p_want) then 'PASS' else 'FAIL' end,
          left(coalesce(p_got, '<null>'), 200) || case when starts_with(coalesce(p_got, '<null>'), p_want) then '' else '  | expected: ' || p_want end);
$f$;

create function m31check.n(p_sql text) returns text language plpgsql as $f$
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
  if to_regclass('public.inquiry_signing_secret') is null then
    raise exception 'REFUSED: Migration 31 not applied';
  end if;
  if (select count(*) from public.public_inquiries) <> 0 then
    raise exception 'REFUSED: public_inquiries is not empty on this database - checks assume a clean table';
  end if;
end
$guard$;

do $run$
declare
  v_secret text := repeat('k', 40);
  v_now bigint := extract(epoch from now())::bigint;
  k uuid;
begin
  perform m31check.as_('owner');
  create table m31check.p (name text primary key, payload jsonb);
  grant select on m31check.p to anon, authenticated;

  -- builds a payload signed the way lib/inquirySignature.ts does: HMAC-SHA256(secret, ip|ts|submissionKey) as hex
  create function m31check.signed(p_ip text, p_ts bigint, p_key uuid, p_secret text, p_extra jsonb)
  returns jsonb language sql as $f$
    select jsonb_build_object('kind', 'contact', 'name', 'Sig', 'subject', 's', 'message', 'm', 'submissionKey', p_key::text,
             '_ip', p_ip, '_ts', p_ts,
             '_sig', encode(extensions.hmac(convert_to(p_ip || '|' || p_ts::text || '|' || p_key::text, 'utf8'), convert_to(p_secret, 'utf8'), 'sha256'), 'hex'))
           || p_extra
  $f$;

  -- ===================== LEGACY MODE (no secret stored) =====================
  perform m31check.as_('anon');
  perform m31check.ok('G1', 'legacy mode: a submission still works with no secret stored', m31check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"Leg","email":"leg@example.com","subject":"s","message":"m"}'::jsonb)$$), 'OK|');
  perform m31check.as_('owner');
  perform m31check.ok('G2', 'legacy rows are not marked verified', m31check.n($$select count(*) from public.public_inquiries where ip_verified$$), '0');

  -- ===================== STRICT MODE ========================================
  insert into public.inquiry_signing_secret (secret) values (v_secret);
  perform m31check.as_('anon');
  perform m31check.ok('S0b', 'anon cannot read the signing secret', m31check.try('select count(*) from public.inquiry_signing_secret'), '42501');

  perform m31check.as_('owner');
  k := gen_random_uuid();
  insert into m31check.p values ('good', m31check.signed('198.51.100.7', v_now, k, v_secret, '{"email":"good@example.com"}'));
  insert into m31check.p values ('wrongsig', (m31check.signed('198.51.100.8', v_now, gen_random_uuid(), v_secret, '{"email":"ws@example.com"}')) || '{"_sig":"0000000000000000000000000000000000000000000000000000000000000000"}');
  insert into m31check.p values ('expired', m31check.signed('198.51.100.9', v_now - 400, gen_random_uuid(), v_secret, '{"email":"exp@example.com"}'));
  insert into m31check.p values ('otherkey', (m31check.signed('198.51.100.10', v_now, gen_random_uuid(), v_secret, '{"email":"ok2@example.com"}')) || jsonb_build_object('submissionKey', gen_random_uuid()::text));
  insert into m31check.p values ('wrongsecret', m31check.signed('198.51.100.11', v_now, gen_random_uuid(), repeat('z', 40), '{"email":"wsec@example.com"}'));
  perform set_config('request.headers', '{"x-forwarded-for":"203.0.113.9"}', true);
  perform m31check.as_('anon');
  perform m31check.ok('S1', 'a valid signature is accepted', m31check.try($$select public.submit_public_inquiry(payload) from m31check.p where name = 'good'$$), 'OK|');
  perform m31check.ok('S2', 'replaying the same signed request returns the same inquiry (idempotent)', m31check.try($$select (select public.submit_public_inquiry(payload)) = (select public.submit_public_inquiry(payload)) from m31check.p where name = 'good'$$), 'OK|true');
  perform m31check.ok('S3', 'a wrong signature is still accepted, as unverified', m31check.try($$select public.submit_public_inquiry(payload) from m31check.p where name = 'wrongsig'$$), 'OK|');
  perform m31check.ok('S4', 'an expired signature is accepted, as unverified', m31check.try($$select public.submit_public_inquiry(payload) from m31check.p where name = 'expired'$$), 'OK|');
  perform m31check.ok('S5', 'a signature for a different submission key is unverified', m31check.try($$select public.submit_public_inquiry(payload) from m31check.p where name = 'otherkey'$$), 'OK|');
  perform m31check.ok('S6', 'a signature made with another secret is unverified', m31check.try($$select public.submit_public_inquiry(payload) from m31check.p where name = 'wrongsecret'$$), 'OK|');
  perform m31check.ok('S7', 'an unsigned submission with a forged x-forwarded-for is accepted, as unverified', m31check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"Raw","email":"raw@example.com","subject":"s","message":"m"}'::jsonb)$$), 'OK|');
  perform set_config('request.headers', '', true);
  perform m31check.as_('owner');
  perform m31check.ok('V1', 'exactly one row is verified (the valid signature)', m31check.n($$select count(*) from public.public_inquiries where ip_verified$$), '1');
  perform m31check.ok('V2', 'the verified row stores the hash of the SIGNED address', m31check.n($$select count(*) from public.public_inquiries where ip_verified and ip_hash = md5('efz-inquiry-ip|198.51.100.7')$$), '1');
  perform m31check.ok('V3', 'no unverified row stores any address hash (x-forwarded-for is ignored)', m31check.n($$select count(*) from public.public_inquiries where not ip_verified and ip_hash is not null and created_at > now() - interval '1 minute' and email <> 'leg@example.com'$$), '0');

  -- verified per-network limit: 30 signed visitors behind one address, then the 31st is refused; another address is unaffected
  insert into m31check.p select 'net' || g, m31check.signed('198.51.100.50', v_now, gen_random_uuid(), v_secret, jsonb_build_object('email', 'net' || g || '@example.com')) from generate_series(1, 31) g;
  insert into m31check.p values ('netother', m31check.signed('198.51.100.51', v_now, gen_random_uuid(), v_secret, '{"email":"netother@example.com"}'));
  perform m31check.as_('anon');
  perform m31check.ok('N1', 'verified network limit: 30 different visitors from one signed address are accepted', (select count(*) filter (where r like 'OK|%') from (
      select m31check.try(format($j$select public.submit_public_inquiry(payload) from m31check.p where name = 'net%s'$j$, g)) r from generate_series(1, 30) g) q)::text, '30');
  perform m31check.ok('N2', 'verified network limit: the 31st is refused WR429', m31check.try($$select public.submit_public_inquiry(payload) from m31check.p where name = 'net31'$$), 'WR429');
  perform m31check.ok('N3', 'verified network limit: another signed address is unaffected', m31check.try($$select public.submit_public_inquiry(payload) from m31check.p where name = 'netother'$$), 'OK|');

  -- unverified bucket: capped at 20 an hour, and it does not use up the verified bucket
  perform m31check.as_('owner');
  insert into public.public_inquiries (kind, name, email, contact_key, content_hash, ip_verified)
  select 'contact', 'Unv', 'unv' || g || '@example.com', 'email:unv' || g || '@example.com', 'u' || g, false from generate_series(1, 20 - (select count(*) from public.public_inquiries where not ip_verified and created_at > now() - interval '1 hour')) g;
  insert into m31check.p values ('late', m31check.signed('198.51.100.60', v_now, gen_random_uuid(), v_secret, '{"email":"late@example.com"}'));
  perform m31check.as_('anon');
  perform m31check.ok('B1', 'unverified bucket: at 20 an hour an unsigned submission is refused WR429', m31check.try($$select public.submit_public_inquiry('{"kind":"contact","name":"Raw","email":"raw2@example.com","subject":"s","message":"m"}'::jsonb)$$), 'WR429');
  perform m31check.ok('B2', 'bucket isolation: a signed visitor is still accepted while the unverified bucket is full', m31check.try($$select public.submit_public_inquiry(payload) from m31check.p where name = 'late'$$), 'OK|');

  -- the same email is limited even when the phone changes
  perform m31check.as_('owner');
  -- B1 filled the unverified bucket on purpose; free those filler rows so E1 exercises the EMAIL rule and not the bucket limit
  delete from public.public_inquiries where name = 'Unv';
  perform set_config('request.headers', '', true);
  perform m31check.as_('anon');
  perform m31check.ok('E1', 'email limit: the same email with four different phones, the first three are accepted and the fourth is refused WR429', (select string_agg(case when starts_with(res, 'OK|') then 'OK|' else left(res, 5) end, ',' order by g) from (
      select g, m31check.try(format($j$select public.submit_public_inquiry('{"kind":"wholesale","name":"E","phone":"06190001%s","organization":"O","businessType":"Other","email":"Same@Example.com"}'::jsonb)$j$, lpad(g::text, 2, '0'))) res from generate_series(1, 4) g) q), 'OK|,OK|,OK|,WR429');
  perform m31check.as_('owner');
end
$run$;

do $report$
declare
  v_pass int; v_fail int; v_lines text;
begin
  perform set_config('role', 'none', true);
  select count(*) filter (where result = 'PASS'), count(*) filter (where result = 'FAIL') into v_pass, v_fail from m31check.r;
  select string_agg(result || ' ' || id || ' ' || name || case when result = 'FAIL' then '  [' || info || ']' else '' end, E'\n' order by n) into v_lines from m31check.r;
  raise exception E'M31 CHECKS: % PASS, % FAIL\n%', v_pass, v_fail, v_lines;
end
$report$;
