-- EFZ - rollback of 15_realtime_orders.sql: removes public.orders from the supabase_realtime publication.
-- Only needed if 15 must be undone. Open admin tabs fall back to the 30 s alert refresh.
begin;

do $$
begin
  if exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'orders'
  ) then
    alter publication supabase_realtime drop table public.orders;
  end if;
end
$$;

commit;
