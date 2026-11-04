-- ============================================================================
-- EFZ - ROLLBACK of 31_inquiry_rate_limits.sql
-- Restores the migration 30 submit_public_inquiry() and removes the signing secret. The ip_verified column and the two
-- indexes are additive and harmless, so they are left in place (no data is dropped).
-- ============================================================================

begin;

set local lock_timeout = '30s';

do $pre$
begin
  if to_regclass('public.inquiry_signing_secret') is null then
    raise exception '31 rollback: 31 is not applied - nothing to roll back';
  end if;
end
$pre$;

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

  -- The client address as PostgREST saw it (first x-forwarded-for hop). Missing or malformed headers just skip the per-network limit.
  begin
    v_ip := nullif(btrim(split_part(coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''), ',', 1)), '');
  exception when others then
    v_ip := null;
  end;
  v_ip_hash := case when v_ip is null then null else md5('efz-inquiry-ip|' || v_ip) end;

  v_contact := coalesce(v_canon, 'email:' || lower(v_email));
  v_hash := md5(v_kind || '|' || lower(v_name) || '|' || lower(v_org) || '|' || lower(v_btype) || '|'
                || lower(v_subject) || '|' || lower(v_message));

  -- One visitor at a time: two tabs or a double click cannot both pass the limit.
  perform pg_advisory_xact_lock(1819, hashtext('efz-inquiry:' || v_contact));

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

  -- One network (shared mobile connections are common, so the number is generous) cannot fill the inbox with many identities.
  if v_ip_hash is not null and coalesce(s.limit_enabled, true) then
    select count(*) into v_count from public.public_inquiries i
     where i.ip_hash = v_ip_hash and i.created_at > now() - interval '1 hour';
    if v_count >= 30 then
      raise exception 'Too many messages were sent from your connection. Please try again later or contact us on WhatsApp.'
        using errcode = 'WR429';
    end if;
  end if;

  -- Backstop against a flood from many identities.
  select count(*) into v_count from public.public_inquiries i where i.created_at > now() - interval '1 hour';
  if v_count >= 300 then
    raise exception 'We are receiving a lot of messages right now. Please try again later or contact us on WhatsApp.'
      using errcode = 'WR429';
  end if;

  insert into public.public_inquiries (id, kind, name, organization, business_type, phone, phone_canonical, email,
                                       subject, message, contact_key, content_hash, ip_hash, submission_key, status)
  values (v_id, v_kind, v_name, v_org, v_btype, v_phone, v_canon, v_email,
          v_subject, v_message, v_contact, v_hash, v_ip_hash, v_key, 'new');

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

drop table public.inquiry_signing_secret;

commit;
