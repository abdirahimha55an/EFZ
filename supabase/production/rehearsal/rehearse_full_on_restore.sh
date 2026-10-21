#!/bin/bash
# Full rehearsal on the restore of the FRESH Production backup 20261021-062637Z (local cluster port 54451). Production is never contacted.
B=/c/pgsql17/pgsql/bin; PS="$B/psql.exe"; H="-h 127.0.0.1 -p 54451 -U postgres -X -q"; O=/c/EFZ-checks/M29_rehearsal2; mkdir -p $O
W="/c/Users/Abdirahim/AppData/Local/Temp/claude/C--Users-Abdirahim-Desktop-EFZ/d5153f40-9bfb-4986-9112-ca67a4283c80/scratchpad/efz-android/supabase"
STUB=/c/EFZ-checks/M29_rehearsal/realtime_stub.sql
DB=m29_full
$PS $H -d postgres -c "drop database if exists $DB" -c "create database $DB template efz_restore_drill" 2>&1 | grep -v NOTICE
$PS $H -d $DB -v ON_ERROR_STOP=1 -f $STUB || exit 1
$PS $H -d $DB -At -f $W/checks/21_function_fingerprint.sql 2>/dev/null | tr -d '\r' | sort > $O/fp_pre.txt
for f in 19_website_request_delegation 19b_permission_change_audit 21_customer_accounts 22_customer_ordering 23_customer_checkout_credit 24_credit_policy_refinement 25_credit_policy_v2 26_customer_price_agreements 27_price_policy_no_expiry 28_convert_request_designs 29a_dispatch_enum production/29b_dispatch_and_live_orders.crtolerant 29c_order_details_dispatched 29d_live_orders_topic_by_user production/29e_enforce_dispatch.crtolerant; do
  n=$(basename $f); s=$(date +%s); $PS $H -d $DB -v ON_ERROR_STOP=1 -f $W/$f.sql > $O/apply_$n.out 2> $O/apply_$n.err; rc=$?
  echo "$n exit=$rc $(( $(date +%s)-s ))s $(grep -m1 -E 'ERROR|refus' $O/apply_$n.err | sed 's/.*ERROR/ERROR/' | cut -c1-220)"; [ $rc -ne 0 ] && { echo CHAIN_FAILED; exit 1; }; done
echo CHAIN_OK
$PS $H -d $DB -At -f $W/checks/21_function_fingerprint.sql 2>/dev/null | tr -d '\r' | sort > $O/fp_post.txt; echo "fingerprint rows pre/post: $(wc -l < $O/fp_pre.txt)/$(wc -l < $O/fp_post.txt); changed or added: $(diff $O/fp_pre.txt $O/fp_post.txt | grep -c '^>')"
echo "== staging checks 19 / 19b"; for s in staging_checks_19 staging_checks_19b; do echo -n "$s: "; $PS $H -d $DB -f $W/staging/$s.sql 2>&1 | grep -ciE "fail" ; done
echo "== suites (rolled-back SQL suites) on the post-29e database"
for s in 21_customer_accounts 22_customer_ordering 23_customer_checkout_credit 24_credit_policy 25_credit_policy_v2 26_price_agreements 27_price_policy customer_data_exposure; do echo -n "$s: "; $PS $H -d $DB -f $W/checks/${s}_checks.sql 2>&1 | grep -E "TOTAL|^psql|ERROR" | head -2 | tr '\n' ' ' | cut -c1-240; echo; done
echo "== 29 dispatch suite"; T=$W/checks; cat $T/28_integration/prelude.sql $T/28_integration/prelude2.sql $T/29_dispatch/body.sql > $O/_run29.sql; $PS $H -d $DB -f $O/_run29.sql > $O/run29.out 2> $O/run29.err
node -e 'const raw=require("fs").readFileSync(process.argv[1],"utf8");const i=raw.indexOf("T28RESULT:");if(i<0){console.log("NO RESULT");process.exit()}let b=raw.slice(i+10);const c=b.indexOf("\nCONTEXT:");if(c>=0)b=b.slice(0,c);const rows=JSON.parse(b);const bad=rows.filter(r=>!r.ok);console.log("checks",rows.length,"failed",bad.length);bad.forEach(r=>console.log(JSON.stringify(r).slice(0,250)))' $O/run29.err
echo "== validate_financials"; $PS $H -d $DB -f $W/checks/validate_financials.sql -o $O/validate_post.txt 2>/dev/null; echo "FAIL=$(grep -cw FAIL $O/validate_post.txt) PASS=$(grep -cw PASS $O/validate_post.txt) WARN=$(grep -cw WARN $O/validate_post.txt)"
echo "== business baseline unchanged (counts)"; $PS $H -d $DB -At -c "select 'orders '||count(*) from public.orders union all select 'payments '||count(*) from public.payments union all select 'commissions '||count(*) from public.commissions union all select 'customers '||count(*) from public.customers union all select 'order_items '||count(*) from public.order_items" | tr '\n' ';'; echo
echo "== concurrency (committed throwaway copies)"
for c in 25_credit_concurrency 26_price_concurrency 27_price_policy_concurrency; do d=m29_conc; $PS $H -d postgres -c "drop database if exists $d" -c "create database $d template $DB" 2>&1 | grep -v NOTICE; echo -n "$c: "; PSQL=$PS node $W/checks/$c.mjs $d 127.0.0.1 54451 postgres 2>&1 | tail -3 | tr '\n' ' ' | cut -c1-260; echo; done
sed 's/54399/54451/' $W/checks/24_credit_concurrency.mjs > $W/checks/_c24.mjs; $PS $H -d postgres -c "drop database if exists m29_conc" -c "create database m29_conc template $DB" 2>&1 | grep -v NOTICE; echo -n "24_credit_concurrency: "; PSQL=$PS node $W/checks/_c24.mjs m29_conc 127.0.0.1 54451 postgres 2>&1 | tail -3 | tr '\n' ' ' | cut -c1-260; rm -f $W/checks/_c24.mjs; echo
echo "== rollback of 29e then 29, then re-apply chain tail"
$PS $H -d postgres -c "drop database if exists m29_rb" -c "create database m29_rb template $DB" 2>&1 | grep -v NOTICE
Q="select proname||' '||md5(prosrc) from pg_proc where pronamespace='public'::regnamespace and proname in ('update_order_status','deliver_order_internal','guard_orders_write','transfer_customer_owner') order by 1"
$PS $H -d m29_rb -v ON_ERROR_STOP=1 -f $W/rollback/29e_enforce_dispatch_rollback.sql >/dev/null 2>$O/rb29e.err; echo "rollback 29e exit=$?"
$PS $H -d m29_rb -v ON_ERROR_STOP=1 -f $W/rollback/29_dispatch_rollback.sql >/dev/null 2>$O/rb29.err; echo "rollback 29 exit=$?"
$PS $H -d m29_rb -At -c "select (select count(*) from information_schema.columns where table_name='orders' and column_name='dispatched_at')||' dispatched cols; view '||md5(pg_get_viewdef('public.order_details'::regclass,true))"
for f in production/29b_dispatch_and_live_orders.crtolerant 29c_order_details_dispatched 29d_live_orders_topic_by_user production/29e_enforce_dispatch.crtolerant; do $PS $H -d m29_rb -v ON_ERROR_STOP=1 -f $W/$f.sql >/dev/null 2>$O/reapply.err; echo "re-apply $(basename $f) exit=$? $(grep -m1 ERROR $O/reapply.err | sed 's/.*ERROR/ERROR/' | cut -c1-160)"; done
echo "DONE"
