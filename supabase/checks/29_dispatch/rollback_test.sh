#!/bin/bash
# STAGING ONLY. Runs the rollback inside a transaction that is aborted at the end (nothing persists) and reports whether the pre-29 state is restored.
REF=adjjamiqwboawqedaapi
cd "$(dirname "$0")"
{ sed -e '/^begin;$/d' -e '/^commit;$/d' ../../rollback/29_dispatch_rollback.sql;
  cat <<'SQL'
do $t$
declare r jsonb := '{}'::jsonb; m text;
begin
  select jsonb_object_agg(p.proname, md5(p.prosrc)) into r from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('update_order_status','guard_orders_write','deliver_order_internal','sync_order_commission','correct_delivered_quantity','transfer_customer_owner','my_orders');
  r := r || jsonb_build_object('triggers', (select count(*) from pg_trigger where tgname like 'trg_orders_notify_customer%'),
    'policy', (select count(*) from pg_policy where polname = 'customer_orders_receive'),
    'view_md5', md5(pg_get_viewdef('public.order_details'::regclass, true)), 'view_acl', (select relacl::text from pg_class where oid = 'public.order_details'::regclass),
    'columns', (select count(*) from information_schema.columns where table_name = 'orders' and column_name in ('dispatched_at','dispatched_by')));
  raise exception 'T29RB:%', r::text;
end
$t$;
SQL
} > _rb.sql
supabase db query --linked --project-ref "$REF" -f _rb.sql 2>&1 | grep -o 'T29RB:.*' | head -1 | cut -c1-1400
rm -f _rb.sql
