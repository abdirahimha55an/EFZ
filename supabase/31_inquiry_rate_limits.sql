-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 31 : stronger rate limits for the public inquiry forms
-- ----------------------------------------------------------------------------
-- STATUS: written 2026-11-04, NOT YET APPLIED ANYWHERE and NOT YET TESTED (Staging was paused). Apply to
-- EFZ-Staging first and run supabase/checks/31_inquiry_rate_limits_checks.sql. Never to Production without owner approval.
-- Needs file 30. Idempotent. Forward only: changes only submit_public_inquiry() and adds one column, indexes and one table.
--
-- WHAT
--  Migration 30 took the client address from the first x-forwarded-for hop, which a caller can forge, and kept one global
--  bucket that a single flooder could fill. This file:
--   secret      public.inquiry_signing_secret (one row, readable only by the function owner). Until the owner stores a
--               secret the function behaves exactly as in migration 30 (legacy mode), so applying this file changes nothing
--               by itself. Set it with:
--                 insert into public.inquiry_signing_secret (secret) values ('<32+ random chars>')
--                 on conflict (id) do update set secret = excluded.secret, updated_at = now();
--               and put the same value in Vercel as INQUIRY_HMAC_SECRET.
--   strict mode (secret stored): the /api/inquiries route sends _ip, _ts, _sig = HMAC-SHA256(secret, ip|ts|submissionKey).
--               A valid signature (within 5 minutes) makes the address trusted for the per-network limit (30/h) and the
--               verified global bucket (300/h). Anything else is accepted into a separate unverified bucket (20/h) and
--               its address is ignored. x-forwarded-for is no longer read.
--   email       the same email address is limited on its own (same window and count as the per-phone limit).
--   column      public_inquiries.ip_verified (which bucket a row belongs to).
-- Rollback: supabase/rollback/31_inquiry_rate_limits_rollback.sql (restores the migration 30 function).
-- ============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
begin
  if to_regprocedure('public.submit_public_inquiry(jsonb)') is null or to_regclass('public.public_inquiries') is null then
    raise exception '31: migration 30 is not applied - refusing';
  end if;
end
$pre$;

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.inquiry_signing_secret (
  id         boolean primary key default true check (id),
  secret     text not null check (char_length(secret) >= 32),
  updated_at timestamptz not null default now()
);
alter table public.inquiry_signing_secret enable row level security;
revoke all on public.inquiry_signing_secret from public, anon, authenticated;

alter table public.public_inquiries add column if not exists ip_verified boolean not null default false;
create index if not exists public_inquiries_bucket_idx on public.public_inquiries (ip_verified, created_at);
create index if not exists public_inquiries_email_idx on public.public_inquiries (lower(email), kind, created_at) where email <> '';

create or replace function public.submit_public_inquiry(p_payload jsonb)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_kind     text := btrim(coalesce(p_payload ->> 'kind', ''));
  v_name     text := btrim(coalesce(p_payload ->> 'name', ''));
  v_org      text := btrim(coalesce(p_payload ->> 'organization', ''));
  v_btype    text := btrim(coalesce(p_payload ->> 'businessType', ''));
  v_phone    text := btrim(coalesce(p_payload ->> 'phone', ''));
  v_email    text := btrim(coalesce(p_payload ->> 'email', ''));
  v_subject  text := btrim(coalesce(p_payload ->> 'subject', ''));
  v_message  text := btrim(coalesce(p_payload ->> 'message', ''));
  v_canon    text;
  v_contact  text;
  v_hash     text;
  v_key      uuid;
  v_existing uuid;
  v_count    integer;
  v_ip       text;
  v_ip_hash  text;
  v_secret   text;
  v_verified boolean := false;
  v_pip      text;
  v_ts       bigint;
  v_sig      text;
  v_salt     bytea;
  v_limit    integer;
  v_id       uuid := gen_random_uuid();
  s          public.website_request_settings%rowtype;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'Invalid request' using errcode = '22023';
  end if;
  if current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'Inquiry admission requires READ COMMITTED isolation (got %)',
      current_setting('transaction_isolation') using errcode = 'WR500';
  end if;

  -- Honeypot: a real visitor never fills the hidden field. Pretend it worked,
  -- store nothing, so the bot learns nothing.
  if btrim(coalesce(p_payload ->> 'hp', '')) <> '' then
    return v_id;
  end if;

  if v_kind not in ('contact', 'wholesale') then
    raise exception 'Invalid request' using errcode = '22023';
  end if;
  if char_length(v_name) not between 1 and 200 then
    raise exception 'Please enter your name (up to 200 characters)' using errcode = '22023';
  end if;
  if char_length(v_org) > 200 or char_length(v_btype) > 60 or char_length(v_subject) > 200
     or char_length(v_message) > 3000 or char_length(v_phone) > 50 or char_length(v_email) > 254 then
    raise exception 'A field is too long' using errcode = '22023';
  end if;
  if v_email <> '' and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Please enter a valid email address' using errcode = '22023';
  end if;

  if v_phone <> '' then
    v_canon := public.validate_request_phone(v_phone);   -- refuses with WR422 and the standard sentence
  end if;

  if v_kind = 'contact' then
    if v_phone = '' and v_email = '' then
      raise exception 'Please give a phone number or an email address so we can reply' using errcode = '22023';
    end if;
    if char_length(v_subject) < 1 then
      raise exception 'Please enter a subject' using errcode = '22023';
    end if;
    if char_length(v_message) < 1 then
      raise exception 'Please enter your message' using errcode = '22023';
    end if;
    v_org := '';
    v_btype := '';
  else
    if v_phone = '' then
      raise exception 'Please enter a valid Somali phone number, e.g. 061 234 5678' using errcode = 'WR422';
    end if;
    if char_length(v_org) < 1 then
      raise exception 'Please enter your organization or arena name' using errcode = '22023';
    end if;
    if v_btype not in ('Futsal Arena', 'Football Academy/School', 'Sports Retailer', 'Tournament Organizer', 'Other') then
      raise exception 'Please choose your business type' using errcode = '22023';
    end if;
    v_subject := '';
  end if;

  begin
    v_key := nullif(p_payload ->> 'submissionKey', '')::uuid;
  exception when invalid_text_representation then
    raise exception 'Invalid submission key' using errcode = '22023';
  end;

  -- Which network is this? Strict mode (a signing secret is stored): only an address signed by the /api/inquiries route is
  -- trusted; x-forwarded-for is never read, because a caller can forge it. Legacy mode (no secret stored): migration 30 behaviour.
  select q.secret into v_secret from public.inquiry_signing_secret q where q.id;
  if v_secret is not null then
    begin
      v_pip := nullif(btrim(coalesce(p_payload ->> '_ip', '')), '');
      v_ts  := (p_payload ->> '_ts')::bigint;
      v_sig := lower(btrim(coalesce(p_payload ->> '_sig', '')));
    exception when others then
      v_pip := null; v_ts := null; v_sig := '';
    end;
    if v_pip is not null and v_ts is not null and v_key is not null and v_sig ~ '^[0-9a-f]{64}$'
       and extract(epoch from now())::bigint - v_ts between -30 and 300 then
      -- compare the two signatures through a throwaway random key so the comparison time does not depend on how many characters match
      v_salt := extensions.gen_random_bytes(16);
      v_verified := extensions.hmac(convert_to(v_sig, 'utf8'), v_salt, 'sha256')
                  = extensions.hmac(convert_to(encode(extensions.hmac(convert_to(v_pip || '|' || v_ts::text || '|' || v_key::text, 'utf8'),
                                                                      convert_to(v_secret, 'utf8'), 'sha256'), 'hex'), 'utf8'), v_salt, 'sha256');
    end if;
    v_ip := case when v_verified then v_pip else null end;
  else
    -- The client address as PostgREST saw it (first x-forwarded-for hop). Missing or malformed headers just skip the per-network limit.
    begin
      v_ip := nullif(btrim(split_part(coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''), ',', 1)), '');
    exception when others then
      v_ip := null;
    end;
  end if;
  v_ip_hash := case when v_ip is null then null else md5('efz-inquiry-ip|' || v_ip) end;

  v_contact := coalesce(v_canon, 'email:' || lower(v_email));
  v_hash := md5(v_kind || '|' || lower(v_name) || '|' || lower(v_org) || '|' || lower(v_btype) || '|'
                || lower(v_subject) || '|' || lower(v_message));

  -- One visitor at a time: two tabs or a double click cannot both pass the limit.
  perform pg_advisory_xact_lock(1819, hashtext('efz-inquiry:' || v_contact));
  if v_email <> '' then   -- second lock, always taken after the first, so changing the phone cannot dodge the email limit
    perform pg_advisory_xact_lock(1819, hashtext('efz-inquiry-email:' || lower(v_email)));
  end if;

  if v_key is not null then
    select i.id into v_existing from public.public_inquiries i where i.submission_key = v_key;
    if found then
      return v_existing;   -- the same form submitted again: nothing new is written
    end if;
  end if;

  select * into s from public.website_request_settings where id;

  -- The same message sent again (page refresh, second device) is not stored twice.
  select i.id into v_existing
    from public.public_inquiries i
   where i.contact_key = v_contact and i.kind = v_kind and i.content_hash = v_hash
     and i.created_at > now() - make_interval(hours => coalesce(s.window_hours, 24))
   order by i.created_at desc limit 1;
  if found then
    return v_existing;
  end if;

  if coalesce(s.limit_enabled, true) then
    select count(*) into v_count
      from public.public_inquiries i
     where i.contact_key = v_contact and i.kind = v_kind
       and i.created_at > now() - make_interval(hours => coalesce(s.window_hours, 24));
    if v_count >= coalesce(s.max_new_per_phone, 3) then
      raise exception 'We already have your recent messages and will get back to you. Please contact us on WhatsApp if it is urgent.'
        using errcode = 'WR429';
    end if;
  end if;

  -- The same email address is limited on its own, so a visitor cannot dodge the limit by changing the phone number.
  if v_email <> '' and coalesce(s.limit_enabled, true) then
    select count(*) into v_count
      from public.public_inquiries i
     where lower(i.email) = lower(v_email) and i.kind = v_kind
       and i.created_at > now() - make_interval(hours => coalesce(s.window_hours, 24));
    if v_count >= coalesce(s.max_new_per_phone, 3) then
      raise exception 'We already have your recent messages and will get back to you. Please contact us on WhatsApp if it is urgent.'
        using errcode = 'WR429';
    end if;
  end if;

  -- One network (shared mobile connections are common, so the number is generous) cannot fill the inbox with many identities.
  if v_ip_hash is not null and coalesce(s.limit_enabled, true) then
    select count(*) into v_count from public.public_inquiries i
     where i.ip_hash = v_ip_hash and i.created_at > now() - interval '1 hour';
    if v_count >= 30 then
      raise exception 'Too many messages were sent from your connection. Please try again later or contact us on WhatsApp.'
        using errcode = 'WR429';
    end if;
  end if;

  -- Backstop against a flood from many identities. Strict mode keeps two separate buckets, so a flood sent straight at the
  -- database (unsigned) cannot use up the room for visitors who came through the website.
  v_limit := case when v_secret is null then 300 when v_verified then 300 else 20 end;
  select count(*) into v_count from public.public_inquiries i
   where i.created_at > now() - interval '1 hour'
     and (v_secret is null or i.ip_verified = v_verified);
  if v_count >= v_limit then
    raise exception 'We are receiving a lot of messages right now. Please try again later or contact us on WhatsApp.'
      using errcode = 'WR429';
  end if;

  insert into public.public_inquiries (id, kind, name, organization, business_type, phone, phone_canonical, email,
                                       subject, message, contact_key, content_hash, ip_hash, submission_key, status, ip_verified)
  values (v_id, v_kind, v_name, v_org, v_btype, v_phone, v_canon, v_email,
          v_subject, v_message, v_contact, v_hash, v_ip_hash, v_key, 'new', v_verified);

  insert into public.public_inquiry_events (inquiry_id, event, to_status, actor_id, actor_name, details)
  values (v_id, 'submitted', 'new', public.current_profile_id(), coalesce(public.current_profile_name(), ''),
          jsonb_build_object('kind', v_kind));

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'SYSTEM',
          format('Inquiry INQ-%s received (%s)', upper(left(replace(v_id::text, '-', ''), 8)), v_kind),
          public.current_profile_id(), coalesce(public.current_profile_name(), ''), v_id::text,
          jsonb_build_object('source', 'db', 'event', 'public_inquiry_submitted', 'inquiryId', v_id, 'kind', v_kind));
  return v_id;
end;
$fn$;

revoke all on function public.submit_public_inquiry(jsonb) from public, anon, authenticated;
grant execute on function public.submit_public_inquiry(jsonb) to anon, authenticated;

do $post$
begin
  if position('ip_verified' in pg_get_functiondef('public.submit_public_inquiry(jsonb)'::regprocedure)) = 0 then
    raise exception '31 post-check failed: function not updated - aborting';
  end if;
  if has_table_privilege('anon', 'public.inquiry_signing_secret', 'SELECT')
     or has_table_privilege('authenticated', 'public.inquiry_signing_secret', 'SELECT') then
    raise exception '31 post-check failed: the signing secret is readable by clients - aborting';
  end if;
  if not has_function_privilege('anon', 'public.submit_public_inquiry(jsonb)', 'EXECUTE') then
    raise exception '31 post-check failed: visitors cannot submit - aborting';
  end if;
  raise notice '31: inquiry rate limits installed (%)',
    case when exists (select 1 from public.inquiry_signing_secret) then 'strict mode' else 'legacy mode: no secret stored yet' end;
end
$post$;

commit;
