#!/bin/bash
# LOCAL ONLY. Proves the rollback chain on a disposable copy of a populated migration-27 database:
#   1. the 26 and 25 rollbacks REFUSE to run while later migrations depend on them (and change nothing);
#   2. rollback 27, then 26, then 25 each succeed in that order;
#   3. orders, lines, payments, payment terms and credit orders are identical before and after every step;
#   4. every function definition equals the reference (migration-24) database, carriage returns ignored.
# usage: PSQL=<psql> 27_rollback_chain_check.sh <populated_db_with_27> <reference_db_at_24> [host] [port] [user]
# It refuses to run against anything but localhost. It creates and drops its own database "rb_chain_tmp".
set -u
SRC="${1:?populated database}"; REF="${2:?reference database at migration 24}"; HOST="${3:-127.0.0.1}"; PORT="${4:-54399}"; USER_="${5:-postgres}"
case "$HOST" in 127.0.0.1|localhost) ;; *) echo "refusing: local disposable databases only"; exit 2;; esac
P="${PSQL:-psql}"; H="-X -q -h $HOST -p $PORT -U $USER_"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
INT="select (select count(*)||'/'||coalesce(sum(total),0) from orders)||' | '||(select count(*)||'/'||coalesce(sum(quantity*actual_unit_price),0)||'/'||coalesce(sum(quantity*standard_unit_price),0) from order_items)||' | '||(select count(*)||'/'||coalesce(sum(amount),0) from payments)||' | terms '||(select count(*) from order_payment_terms)||' | credit '||(select count(*) from customer_credit_orders)"
FP="select p.proname||'('||pg_get_function_identity_arguments(p.oid)||') '||md5(replace(pg_get_functiondef(p.oid), chr(13), '')) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname not like 't2%c\_active' order by 1"
$P $H -d postgres -c "drop database if exists rb_chain_tmp" -c "create database rb_chain_tmp template $SRC" >/dev/null 2>&1 || { echo "cannot create the scratch database"; exit 2; }
D="-d rb_chain_tmp"
BASE="$($P $H $D -At -c "$INT")"; echo "baseline: $BASE"
run() { $P $H $D -v ON_ERROR_STOP=1 -q -f "$DIR/rollback/$1" 2>&1; }
# 1. guards
out="$(run 26_customer_price_agreements_rollback.sql)"; echo "$out" | grep -q "Roll back migration 27 first" && ok "rollback 26 refuses while migration 27 is applied" || bad "rollback 26 did not refuse: $out"
out="$(run 25_credit_policy_v2_rollback.sql)"; echo "$out" | grep -q "Roll back migration 27, then 26" && ok "rollback 25 refuses while migrations 26/27 are applied" || bad "rollback 25 did not refuse: $out"
[ "$($P $H $D -At -c "$INT")" = "$BASE" ] && [ "$($P $H $D -At -c "select to_regclass('public.price_agreement_notices') is not null and to_regclass('public.customer_price_agreements') is not null and to_regclass('public.customer_credit_defaults') is not null")" = "t" ] && ok "the refused rollbacks changed nothing" || bad "a refused rollback changed something"
# 2. the chain, step by step
step() { out="$(run "$1")"; if echo "$out" | grep -q ERROR; then bad "$2 failed: $(echo "$out" | grep ERROR | head -1)"; else ok "$2"; fi; [ "$($P $H $D -At -c "$INT")" = "$BASE" ] && ok "financial figures unchanged after $2" || bad "financial figures CHANGED after $2"; }
step 27_price_policy_no_expiry_rollback.sql "rollback 27"
out="$(run 25_credit_policy_v2_rollback.sql)"; echo "$out" | grep -q "Roll back migration 27, then 26" && ok "rollback 25 still refuses while migration 26 is applied" || bad "rollback 25 did not refuse after 27: $out"
step 26_customer_price_agreements_rollback.sql "rollback 26"
step 25_credit_policy_v2_rollback.sql "rollback 25"
# 3. definitions equal the migration-24 reference
$P $H $D -At -c "$FP" > /tmp/rb_chain_a.txt; $P $H -d "$REF" -At -c "$FP" > /tmp/rb_chain_b.txt
diff -q /tmp/rb_chain_a.txt /tmp/rb_chain_b.txt >/dev/null && ok "every function definition equals migration 24 (carriage returns ignored)" || { bad "function definitions differ from migration 24"; diff /tmp/rb_chain_a.txt /tmp/rb_chain_b.txt | head -5; }
$P $H -d postgres -c "drop database if exists rb_chain_tmp" >/dev/null 2>&1
[ $fail -eq 0 ] && echo "ROLLBACK CHAIN: all checks passed" || echo "ROLLBACK CHAIN: FAILED"; exit $fail
