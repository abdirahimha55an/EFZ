#!/bin/bash
# STAGING ONLY. Applies 29e and then its rollback inside one aborted transaction, and prints the restored checksums (they must equal the pre-29e values).
REF=adjjamiqwboawqedaapi
cd "$(dirname "$0")"
{ for f in ../../29e_enforce_dispatch.sql ../../rollback/29e_enforce_dispatch_rollback.sql; do sed -e '/^begin;$/d' -e '/^commit;$/d' "$f"; done
  cat <<'SQL'
do $t$
declare r jsonb;
begin
  select jsonb_object_agg(p.proname, md5(p.prosrc)) into r from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname in ('update_order_status','deliver_order_internal');
  raise exception 'T29RB:%', r::text;
end
$t$;
SQL
} > _rb.sql
supabase db query --linked --project-ref "$REF" -f _rb.sql 2>&1 | grep -o 'T29RB:.*' | head -1 | cut -c1-300
rm -f _rb.sql
