-- Read-only: the values 18b's pre-guard and 18b's rollback compare against. Prints key|value.
\pset tuples_only on
\pset format unaligned
select 'cols|' || md5(string_agg(attname || ':' || format_type(atttypid, atttypmod), ',' order by attnum))
  from pg_attribute where attrelid = 'public.order_requests'::regclass and attnum > 0 and not attisdropped;
select 'policies|' || string_agg(polname || ':' || md5(polcmd::text
         || (select string_agg(r::text, ',' order by r::text) from unnest(polroles::regrole[]) r)
         || coalesce(pg_get_expr(polqual, polrelid), '') || coalesce(pg_get_expr(polwithcheck, polrelid), '')),
       ';' order by polname)
  from pg_policy where polrelid = 'public.order_requests'::regclass;
select 'convert|' || md5(pg_get_functiondef('public.convert_order_request(uuid, text)'::regprocedure));
select 'preset|' || md5(pg_get_functiondef('public.grant_role_preset(text, public.user_role)'::regprocedure));
select 'logs|' || md5(pg_get_functiondef('public.guard_system_logs_insert()'::regprocedure));
