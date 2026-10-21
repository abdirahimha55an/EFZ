-- LOCAL REHEARSAL ONLY: minimal stand-in for Supabase Realtime (the real project has these)
create schema if not exists realtime;
create table if not exists realtime.messages (id bigserial primary key, topic text, extension text, payload jsonb, event text, private boolean, inserted_at timestamptz default now());
alter table realtime.messages enable row level security;
create or replace function realtime.send(payload jsonb, event text, topic text, private boolean default true) returns void language sql as $$ insert into realtime.messages(topic, extension, payload, event, private) values (topic, 'broadcast', payload, event, private) $$;
create or replace function realtime.topic() returns text language sql stable as $$ select nullif(current_setting('realtime.topic', true), '') $$;
grant usage on schema realtime to anon, authenticated, service_role;
grant select, insert on realtime.messages to authenticated, service_role;
grant execute on function realtime.topic() to anon, authenticated, service_role;
