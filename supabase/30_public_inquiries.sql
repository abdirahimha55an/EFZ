-- ============================================================================
-- EFZ - Supabase / PostgreSQL Schema
-- File 30 : public Contact and Wholesale inquiries
-- ----------------------------------------------------------------------------
-- Needs only the 18b website-request objects (submit_order_request,
-- validate_request_phone, website_request_settings) plus the base helpers; it
-- does NOT depend on 19 or later, so it applies wherever 18b is present.
-- Apply to EFZ-Staging first. Idempotent: safe to re-run. Forward only: no earlier file is touched,
-- no existing table, function or row is changed.
--
-- WHAT
--  The public /contact and /wholesale forms had no backend. This adds one:
--   tables     public_inquiries (one row per submission, kind contact|wholesale),
--              public_inquiry_notes, public_inquiry_events (append-only timeline)
--   write      submit_public_inquiry(jsonb)  - the ONLY way a visitor writes.
--                validation, honeypot, per-visitor limit (reuses the 18b
--                website_request_settings window), global flood backstop,
--                idempotent on submissionKey and on identical repeat content,
--                per-network limit (hashed client address, never stored raw),
--                audit line in system_logs.
--   staff      set_public_inquiry_status, add/edit_public_inquiry_note,
--              assign_public_inquiry, public_inquiry_assignees (all
--              SECURITY DEFINER, all check the caller; same shape as 18b/19).
--   access     four NEW flat permissions, granted explicitly and never by role
--              (Super Admin has all), mirroring the website-request model:
--                view_inquiries       see inquiries assigned to you, unless
--                view_all_inquiries   ... this scope code is held too
--                manage_inquiries     notes and status moves
--                assign_inquiries     assign / reassign / unassign
--              Nobody is granted them here: until the Super Admin delegates,
--              only the Super Admin can see inquiries (launch decision).
--   rls        anon can read and write NOTHING on the tables; authenticated
--              can only SELECT what can_access_public_inquiry() allows; no
--              client INSERT/UPDATE/DELETE exists anywhere.
--   realtime   public_inquiries joins supabase_realtime (events reach only
--              users passing the SELECT policy).
--
-- HARD BOUNDARIES: no function here reads or writes orders, order_requests,
-- products, stock, payments, commissions or customers.
--
-- Rollback: supabase/rollback/30_public_inquiries_rollback.sql.
-- ============================================================================

begin;

set local lock_timeout = '30s';

-- ============================================================================
-- 0. PRE-GUARD: the chain this file builds on is present
-- ============================================================================

do $pre$
begin
  if to_regprocedure('public.submit_order_request(jsonb)') is null
     or to_regprocedure('public.validate_request_phone(text)') is null
     or to_regprocedure('public.has_permission(text)') is null
     or to_regprocedure('public.current_profile_id()') is null
     or to_regclass('public.website_request_settings') is null
     or to_regclass('public.notifications') is null
     or to_regclass('public.permissions') is null then
    raise exception '30: the 18b website-request objects (or the base helpers) are missing - refusing';
  end if;
end
$pre$;

-- ============================================================================
-- 1. TABLES
-- ============================================================================

create table if not exists public.public_inquiries (
  id                uuid primary key default gen_random_uuid(),
  kind              text not null check (kind in ('contact', 'wholesale')),
  name              text not null check (char_length(btrim(name)) between 1 and 200),
  organization      text not null default '' check (char_length(organization) <= 200),
  business_type     text not null default '' check (char_length(business_type) <= 60),
  phone             text not null default '' check (char_length(phone) <= 50),
  phone_canonical   text,
  email             text not null default '' check (char_length(email) <= 254),
  subject           text not null default '' check (char_length(subject) <= 200),
  message           text not null default '' check (char_length(message) <= 3000),
  -- who is asking, for the per-visitor limit: the canonical phone, else 'email:<lower>'
  contact_key       text not null check (char_length(contact_key) between 1 and 300),
  content_hash      text not null,
  -- md5 of the client address PostgREST saw (x-forwarded-for) for the per-network limit; the address itself is never stored
  ip_hash           text,
  submission_key    uuid,
  status            text not null default 'new' check (status in ('new', 'contacted', 'closed')),
  assigned_to       text references public.profiles(id) on delete set null,
  handled_by        text references public.profiles(id) on delete set null,
  status_changed_at timestamptz,
  closed_reason     text check (closed_reason is null or char_length(btrim(closed_reason)) between 1 and 500),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  -- a reply needs somewhere to go
  constraint public_inquiries_reachable_check check (phone <> '' or email <> ''),
  constraint public_inquiries_wholesale_check check (kind <> 'wholesale' or (phone <> '' and organization <> '' and business_type <> ''))
);

create unique index if not exists public_inquiries_submission_key_uq
  on public.public_inquiries (submission_key) where submission_key is not null;
create index if not exists public_inquiries_visitor_idx
  on public.public_inquiries (contact_key, kind, created_at);
-- re-apply on a database that already has the table from the first version of this file
alter table public.public_inquiries add column if not exists ip_hash text;
create index if not exists public_inquiries_ip_idx
  on public.public_inquiries (ip_hash, created_at) where ip_hash is not null;
create index if not exists public_inquiries_status_idx
  on public.public_inquiries (status, created_at desc);
create index if not exists public_inquiries_created_idx
  on public.public_inquiries (created_at desc);

create table if not exists public.public_inquiry_notes (
  id          uuid primary key default gen_random_uuid(),
  inquiry_id  uuid not null references public.public_inquiries(id) on delete cascade,
  body        text not null check (char_length(btrim(body)) between 1 and 2000),
  author_id   text references public.profiles(id) on delete set null,
  author_name text not null default '',
  edited_by   text references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists public_inquiry_notes_inquiry_idx on public.public_inquiry_notes (inquiry_id, created_at);

create table if not exists public.public_inquiry_events (
  id          uuid primary key default gen_random_uuid(),
  seq         bigint generated always as identity,
  inquiry_id  uuid not null references public.public_inquiries(id) on delete cascade,
  event       text not null check (event in ('submitted', 'status_changed', 'note_added', 'note_edited', 'assigned')),
  from_status text,
  to_status   text,
  actor_id    text references public.profiles(id) on delete set null,
  actor_name  text not null default '',
  note        text,
  details     jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);
create index if not exists public_inquiry_events_inquiry_idx on public.public_inquiry_events (inquiry_id, seq);

-- Events are append-only; notes can be edited (through the RPC) but not deleted.
-- A row may only disappear with its inquiry (FK cascade).
create or replace function public.guard_public_inquiry_child()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if tg_op = 'UPDATE' then
    raise exception '% rows are append-only and cannot be changed', tg_table_name using errcode = '42501';
  end if;
  if exists (select 1 from public.public_inquiries i where i.id = old.inquiry_id) then
    raise exception '% rows cannot be deleted', tg_table_name using errcode = '42501';
  end if;
  return old;
end;
$fn$;

drop trigger if exists trg_public_inquiry_events_guard on public.public_inquiry_events;
create trigger trg_public_inquiry_events_guard
  before update or delete on public.public_inquiry_events
  for each row execute function public.guard_public_inquiry_child();

drop trigger if exists trg_public_inquiry_notes_guard on public.public_inquiry_notes;
create trigger trg_public_inquiry_notes_guard
  before delete on public.public_inquiry_notes
  for each row execute function public.guard_public_inquiry_child();

-- ============================================================================
-- 2. PERMISSIONS (existing flat model) - granted to nobody here
-- ============================================================================

insert into public.permissions (code, label, category, sort_order) values
  ('view_inquiries',     'View inquiries (assigned to me)', 'Inquiries', 31),
  ('view_all_inquiries', 'View all inquiries',              'Inquiries', 32),
  ('manage_inquiries',   'Work inquiries (notes, contacted, closed)', 'Inquiries', 33),
  ('assign_inquiries',   'Assign inquiries',                'Inquiries', 34)
on conflict (code) do nothing;

-- ============================================================================
-- 3. THE ACCESS RULE (behind the SELECT policies, realtime delivery and every RPC)
-- ============================================================================

create or replace function public.can_access_public_inquiry(p_assigned_to text)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select public.has_permission('view_inquiries')
     and (public.has_permission('view_all_inquiries')
          or (p_assigned_to is not null and p_assigned_to = public.current_profile_id()));
$fn$;

-- ============================================================================
-- 4. PUBLIC SUBMISSION
-- ============================================================================

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

-- ============================================================================
-- 5. STAFF WORKFLOW
-- ============================================================================

create or replace function public.set_public_inquiry_status(p_inquiry_id uuid, p_to text, p_reason text default null)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_row    public.public_inquiries%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_label  text := 'INQ-' || upper(left(replace(p_inquiry_id::text, '-', ''), 8));
begin
  select * into v_row from public.public_inquiries where id = p_inquiry_id for update;
  if not found or not public.can_access_public_inquiry(v_row.assigned_to)
     or not public.has_permission('manage_inquiries') then
    raise exception 'Permission denied or unknown inquiry' using errcode = '42501';
  end if;
  if (v_row.status, p_to) not in (('new', 'contacted'), ('new', 'closed'), ('contacted', 'closed'), ('closed', 'contacted')) then
    raise exception 'A % inquiry cannot be marked %', v_row.status, p_to using errcode = 'WR409';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'A reason can be up to 500 characters' using errcode = '22023';
  end if;

  update public.public_inquiries
     set status            = p_to,
         status_changed_at = now(),
         handled_by        = public.current_profile_id(),
         closed_reason     = case when p_to = 'closed' then v_reason else null end,
         updated_at        = now()
   where id = p_inquiry_id;

  insert into public.public_inquiry_events (inquiry_id, event, from_status, to_status, actor_id, actor_name, note)
  values (p_inquiry_id, 'status_changed', v_row.status, p_to, public.current_profile_id(),
          coalesce(public.current_profile_name(), ''), v_reason);

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'SYSTEM',
          format('Inquiry %s marked %s (from %s)', v_label, p_to, v_row.status),
          public.current_profile_id(), coalesce(public.current_profile_name(), ''), p_inquiry_id::text,
          jsonb_build_object('source', 'db', 'event', 'public_inquiry_status', 'inquiryId', p_inquiry_id,
                             'fromStatus', v_row.status, 'toStatus', p_to));
end;
$fn$;

create or replace function public.add_public_inquiry_note(p_inquiry_id uuid, p_body text)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_row  public.public_inquiries%rowtype;
  v_body text := btrim(coalesce(p_body, ''));
  v_id   uuid;
begin
  select * into v_row from public.public_inquiries where id = p_inquiry_id;
  if not found or not public.can_access_public_inquiry(v_row.assigned_to)
     or not public.has_permission('manage_inquiries') then
    raise exception 'Permission denied or unknown inquiry' using errcode = '42501';
  end if;
  if char_length(v_body) not between 1 and 2000 then
    raise exception 'A note must be 1 to 2000 characters' using errcode = '22023';
  end if;

  insert into public.public_inquiry_notes (inquiry_id, body, author_id, author_name)
  values (p_inquiry_id, v_body, public.current_profile_id(), coalesce(public.current_profile_name(), ''))
  returning id into v_id;

  insert into public.public_inquiry_events (inquiry_id, event, actor_id, actor_name, details)
  values (p_inquiry_id, 'note_added', public.current_profile_id(), coalesce(public.current_profile_name(), ''),
          jsonb_build_object('noteId', v_id));
  return v_id;
end;
$fn$;

-- Author (while they can still access the inquiry) or the Super Admin. The
-- previous text is kept in the timeline.
create or replace function public.edit_public_inquiry_note(p_note_id uuid, p_body text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_note public.public_inquiry_notes%rowtype;
  v_row  public.public_inquiries%rowtype;
  v_body text := btrim(coalesce(p_body, ''));
begin
  select * into v_note from public.public_inquiry_notes where id = p_note_id for update;
  if found then
    select * into v_row from public.public_inquiries where id = v_note.inquiry_id;
  end if;
  if not found
     or not public.can_access_public_inquiry(v_row.assigned_to)
     or not public.has_permission('manage_inquiries')
     or not (public.is_super_admin() or v_note.author_id = public.current_profile_id()) then
    raise exception 'Permission denied or unknown note' using errcode = '42501';
  end if;
  if char_length(v_body) not between 1 and 2000 then
    raise exception 'A note must be 1 to 2000 characters' using errcode = '22023';
  end if;
  if v_body = v_note.body then
    return;
  end if;

  update public.public_inquiry_notes
     set body = v_body, edited_by = public.current_profile_id(), updated_at = now()
   where id = p_note_id;

  insert into public.public_inquiry_events (inquiry_id, event, actor_id, actor_name, note, details)
  values (v_note.inquiry_id, 'note_edited', public.current_profile_id(), coalesce(public.current_profile_name(), ''),
          v_note.body, jsonb_build_object('noteId', p_note_id));
end;
$fn$;

create or replace function public.public_inquiry_assignees()
returns table (id text, name text, role text)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not public.has_permission('assign_inquiries') then
    raise exception 'Permission denied: assign_inquiries is required' using errcode = '42501';
  end if;
  return query
    select p.id, p.name, p.role::text
      from public.profiles p
     where p.status = 'active'
       and (p.role = 'Super Admin'
            or exists (select 1 from public.user_permissions up
                        where up.user_id = p.id and up.permission_code = 'view_inquiries'))
     order by p.name, p.id;
end;
$fn$;

create or replace function public.assign_public_inquiry(p_inquiry_id uuid, p_assignee text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_row        public.public_inquiries%rowtype;
  v_to         text := nullif(btrim(coalesce(p_assignee, '')), '');
  v_to_name    text;
  v_from_name  text;
  v_actor      text := public.current_profile_id();
  v_actor_name text := coalesce(public.current_profile_name(), '');
  v_label      text := 'INQ-' || upper(left(replace(p_inquiry_id::text, '-', ''), 8));
begin
  select * into v_row from public.public_inquiries where id = p_inquiry_id for update;
  if not found or not public.can_access_public_inquiry(v_row.assigned_to)
     or not public.has_permission('assign_inquiries') then
    raise exception 'Permission denied or unknown inquiry' using errcode = '42501';
  end if;
  if v_row.status = 'closed' then
    raise exception 'A closed inquiry can no longer be assigned' using errcode = 'WR409';
  end if;

  if v_to is not null then
    select p.name into v_to_name
      from public.profiles p
     where p.id = v_to and p.status = 'active'
       and (p.role = 'Super Admin'
            or exists (select 1 from public.user_permissions up
                        where up.user_id = p.id and up.permission_code = 'view_inquiries'));
    if not found then
      raise exception 'The assignee must be an active staff member allowed to view inquiries'
        using errcode = '22023';
    end if;
  end if;

  if v_to is not distinct from v_row.assigned_to then
    return;   -- nothing changes, nothing is recorded
  end if;
  select name into v_from_name from public.profiles where id = v_row.assigned_to;

  update public.public_inquiries set assigned_to = v_to, updated_at = now() where id = p_inquiry_id;

  insert into public.public_inquiry_events (inquiry_id, event, actor_id, actor_name, details)
  values (p_inquiry_id, 'assigned', v_actor, v_actor_name,
          jsonb_build_object('from', v_row.assigned_to, 'fromName', coalesce(v_from_name, ''),
                             'to', v_to, 'toName', coalesce(v_to_name, '')));

  insert into public.system_logs (id, severity, category, message, user_id, username, target_id, metadata)
  values ('log-' || replace(gen_random_uuid()::text, '-', ''), 'INFO', 'SYSTEM',
          case when v_to is null then format('Inquiry %s unassigned', v_label)
               when v_row.assigned_to is null then format('Inquiry %s assigned to %s', v_label, v_to_name)
               else format('Inquiry %s reassigned from %s to %s', v_label, coalesce(v_from_name, v_row.assigned_to), v_to_name) end,
          v_actor, v_actor_name, p_inquiry_id::text,
          jsonb_build_object('source', 'db', 'event', 'public_inquiry_assigned', 'inquiryId', p_inquiry_id,
                             'from', v_row.assigned_to, 'to', v_to));

  -- The assignee's own notification (reference only - no visitor details).
  if v_to is not null and v_to is distinct from v_actor then
    insert into public.notifications (id, title, message, type, user_id)
    values ('inqasg-' || replace(gen_random_uuid()::text, '-', ''), 'Inquiry assigned to you',
            format('%s was assigned to you by %s.', v_label, coalesce(nullif(v_actor_name, ''), 'a Super Admin')),
            'order', v_to);
  end if;
end;
$fn$;

-- ============================================================================
-- 6. RLS AND GRANTS
-- ============================================================================

alter table public.public_inquiries       enable row level security;
alter table public.public_inquiry_notes   enable row level security;
alter table public.public_inquiry_events  enable row level security;

drop policy if exists public_inquiries_select on public.public_inquiries;
create policy public_inquiries_select on public.public_inquiries
  for select to authenticated using (public.can_access_public_inquiry(assigned_to));

drop policy if exists public_inquiry_notes_select on public.public_inquiry_notes;
create policy public_inquiry_notes_select on public.public_inquiry_notes
  for select to authenticated
  using (exists (select 1 from public.public_inquiries i where i.id = public_inquiry_notes.inquiry_id));

drop policy if exists public_inquiry_events_select on public.public_inquiry_events;
create policy public_inquiry_events_select on public.public_inquiry_events
  for select to authenticated
  using (exists (select 1 from public.public_inquiries i where i.id = public_inquiry_events.inquiry_id));

-- No INSERT/UPDATE/DELETE policy exists for anyone: the RPCs above are the only writers.
revoke all on public.public_inquiries, public.public_inquiry_notes, public.public_inquiry_events from public, anon, authenticated;
grant select on public.public_inquiries, public.public_inquiry_notes, public.public_inquiry_events to authenticated;

revoke all on function public.guard_public_inquiry_child()                       from public, anon, authenticated;
revoke all on function public.can_access_public_inquiry(text)                    from public, anon, authenticated;
revoke all on function public.submit_public_inquiry(jsonb)                       from public, anon, authenticated;
revoke all on function public.set_public_inquiry_status(uuid, text, text)        from public, anon, authenticated;
revoke all on function public.add_public_inquiry_note(uuid, text)                from public, anon, authenticated;
revoke all on function public.edit_public_inquiry_note(uuid, text)               from public, anon, authenticated;
revoke all on function public.public_inquiry_assignees()                         from public, anon, authenticated;
revoke all on function public.assign_public_inquiry(uuid, text)                  from public, anon, authenticated;

grant execute on function public.can_access_public_inquiry(text)                 to authenticated;   -- evaluated by RLS
grant execute on function public.submit_public_inquiry(jsonb)                    to anon, authenticated;
grant execute on function public.set_public_inquiry_status(uuid, text, text)     to authenticated;
grant execute on function public.add_public_inquiry_note(uuid, text)             to authenticated;
grant execute on function public.edit_public_inquiry_note(uuid, text)            to authenticated;
grant execute on function public.public_inquiry_assignees()                      to authenticated;
grant execute on function public.assign_public_inquiry(uuid, text)               to authenticated;

-- ============================================================================
-- 7. REALTIME
-- ============================================================================

do $rt$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    raise exception '30: supabase_realtime publication is missing';
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'public_inquiries') then
    alter publication supabase_realtime add table public.public_inquiries;
  end if;
end
$rt$;

-- ============================================================================
-- 8. POST-CHECK
-- ============================================================================

do $post$
declare
  v_problem text;
begin
  select string_agg(x, ', ') into v_problem from (
    select 'permission ' || c || ' missing' as x
      from unnest(array['view_inquiries', 'view_all_inquiries', 'manage_inquiries', 'assign_inquiries']) c
     where not exists (select 1 from public.permissions p where p.code = c)
    union all
    select 'rls off on ' || t from unnest(array['public_inquiries', 'public_inquiry_notes', 'public_inquiry_events']) t
     where not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass)
    union all
    select 'anon can ' || priv || ' ' || t
      from unnest(array['public_inquiries', 'public_inquiry_notes', 'public_inquiry_events']) t
     cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) priv
     where has_table_privilege('anon', 'public.' || t, priv)
    union all
    select 'authenticated can ' || priv || ' ' || t
      from unnest(array['public_inquiries', 'public_inquiry_notes', 'public_inquiry_events']) t
     cross join unnest(array['INSERT', 'UPDATE', 'DELETE']) priv
     where has_table_privilege('authenticated', 'public.' || t, priv)
    union all
    select 'anon cannot submit' where not has_function_privilege('anon', 'public.submit_public_inquiry(jsonb)', 'EXECUTE')
    union all
    select 'anon can execute ' || f
      from unnest(array['public.set_public_inquiry_status(uuid,text,text)', 'public.add_public_inquiry_note(uuid,text)',
                        'public.edit_public_inquiry_note(uuid,text)', 'public.assign_public_inquiry(uuid,text)',
                        'public.public_inquiry_assignees()', 'public.can_access_public_inquiry(text)']) f
     where has_function_privilege('anon', f, 'EXECUTE')
    union all
    select 'realtime publication' where not exists (
      select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'public_inquiries')
  ) q;
  if v_problem is not null then
    raise exception '30 post-check failed: % - aborting', v_problem;
  end if;
  raise notice '30: public inquiries installed';
end
$post$;

commit;
