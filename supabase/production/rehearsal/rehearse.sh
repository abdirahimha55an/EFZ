#!/bin/bash
# LOCAL rehearsal of 21..29e (CR-tolerant 29b/29e) on a clone of the local Prod-shaped copy. Never touches Production.
B=/c/pgsql17/pgsql/bin; P="$B/psql.exe -h 127.0.0.1 -p 54411 -U postgres -X -q"; O=/c/EFZ-checks/M29_rehearsal
W="/c/Users/Abdirahim/AppData/Local/Temp/claude/C--Users-Abdirahim-Desktop-EFZ/d5153f40-9bfb-4986-9112-ca67a4283c80/scratchpad/efz-android/supabase"
DB=${1:-m29_rh}
$P -d postgres -c "drop database if exists $DB" -c "create database $DB template efz_restore_drill" 2>&1 | grep -v NOTICE
$P -d $DB -v ON_ERROR_STOP=1 -f $O/realtime_stub.sql || exit 1
$P -d $DB -v ON_ERROR_STOP=1 -f $O/prod_lf_functions_lf.sql || exit 1     # Production-identical LF text of the three functions
for f in 21_customer_accounts 22_customer_ordering 23_customer_checkout_credit 24_credit_policy_refinement 25_credit_policy_v2 26_customer_price_agreements 27_price_policy_no_expiry 28_convert_request_designs 29a_dispatch_enum production/29b_dispatch_and_live_orders.crtolerant 29c_order_details_dispatched 29d_live_orders_topic_by_user production/29e_enforce_dispatch.crtolerant; do
  n=$(basename $f); $P -d $DB -v ON_ERROR_STOP=1 -f $W/$f.sql > $O/apply_$n.out 2> $O/apply_$n.err; rc=$?; echo "$n exit=$rc $(grep -m1 ERROR $O/apply_$n.err | sed 's/.*ERROR/ERROR/' | cut -c1-200)"; [ $rc -ne 0 ] && exit 1; done
echo CHAIN_OK
