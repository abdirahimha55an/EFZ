#!/bin/bash
# T12 concurrent conversion - STAGING ONLY. THIS TEST COMMITS: it leaves exactly 1 customer (cust-t28-conc), 1 request and 1 order, all marked TEST-28.
# Never run it twice without deciding what to do with those rows (orders cannot be deleted; they stay on Staging).
#   usage: ./concurrency.sh
# Session A converts and holds its transaction open 8 s; session C starts 2 s later on the SAME request and must wait for A's row lock,
# then be refused with WR409 'already converted'. Afterwards the script prints what the database holds.
set -u
REF=adjjamiqwboawqedaapi   # EFZ-Staging (pinned)
cd "$(dirname "$0")" || exit 2
T="${TMPDIR:-/tmp}"
q() { supabase db query --linked --project-ref "$REF" --output-format json "$1" 2>&1 | grep -v Initialising | tr -s ' \n' ' ' | sed 's/.*"rows"/rows/; s/, "warning".*//'; echo; }
if [ "$(q "select count(*) as n from public.customers where id = 'cust-t28-conc'" | grep -o '"n": [0-9]*' | grep -o '[0-9]*')" != "0" ]; then echo "cust-t28-conc already exists: a concurrency run has already been committed. Stop."; exit 3; fi
{ echo "begin;"; cat prelude.sql prelude2.sql; cat <<'EOS'
select pg_temp.t28_guard();
do $t$ declare r uuid; begin
  perform pg_temp.t28_cust('cust-t28-conc', 'Concurrency customer', '+0002800061');
  r := pg_temp.t28_req('0612800061', '[{"productId":"prod-stg-nexus","quantity":1}]'::jsonb);
end $t$;
commit;
EOS
} > "$T/28_conc_fixture.sql"
supabase db query --linked --project-ref "$REF" --output-format json -f "$T/28_conc_fixture.sql" 2>&1 | grep -v Initialising | head -c 300; echo
RID=$(q "select id as rid from public.order_requests where customer_name = 'TEST-28 Visitor' and status = 'confirmed' order by created_at desc limit 1" | grep -o '"rid": "[^"]*"' | cut -d'"' -f4)
echo "request: $RID"
PAY='{"customerId":"cust-t28-conc","deliveryNotes":"TEST-28 concurrency","lines":[{"productId":"prod-stg-nexus","quantity":1}]}'
mk() { cat > "$T/28_conc_$1.sql" <<EOS
begin;
select set_config('request.jwt.claims', (select json_build_object('sub', auth_user_id, 'role', 'authenticated')::text from public.profiles where id = '$2'), true);
set local role authenticated;
select public.convert_website_request('$RID'::uuid, '$PAY'::jsonb) as order_id;
$3
commit;
EOS
}
mk A u-stg-manager "select pg_sleep(8);"
mk C u-stg-admin ""
( supabase db query --linked --project-ref "$REF" --output-format json -f "$T/28_conc_A.sql" 2>&1 | grep -v Initialising > "$T/28_conc_A.out" ) &
sleep 2
( supabase db query --linked --project-ref "$REF" --output-format json -f "$T/28_conc_C.sql" 2>&1 | grep -v Initialising > "$T/28_conc_C.out" ) &
wait
echo "== A (winner):"; head -c 300 "$T/28_conc_A.out" | tr -s ' \n' ' '; echo
echo "== C (must be refused: already converted):"; head -c 400 "$T/28_conc_C.out" | tr -s ' \n' ' '; echo
q "select (select count(*) from public.orders where customer_id = 'cust-t28-conc') as orders, (select status from public.order_requests where id = '$RID') as request_status, (select count(*) from public.order_request_events where request_id = '$RID' and event = 'converted') as converted_events"
