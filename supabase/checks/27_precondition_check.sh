#!/bin/bash
# LOCAL ONLY. Proves migration 27 refuses to replace a create_order / convert_website_request it was not written against, and that a clean run and a retry succeed.
# usage: PSQL=<psql> 27_precondition_check.sh <database_at_migration_26> [host] [port] [user]
set -u
SRC="${1:?a database at migration 26}"; HOST="${2:-127.0.0.1}"; PORT="${3:-54399}"; USER_="${4:-postgres}"
case "$HOST" in 127.0.0.1|localhost) ;; *) echo "refusing: local disposable databases only"; exit 2;; esac
P="${PSQL:-psql}"; H="-X -q -h $HOST -p $PORT -U $USER_"; DIR="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
fresh() { $P $H -d postgres -c "drop database if exists pre27_tmp" -c "create database pre27_tmp template $SRC" >/dev/null 2>&1; }
apply() { $P $H -d pre27_tmp -v ON_ERROR_STOP=1 -f "$DIR/27_price_policy_no_expiry.sql" 2>&1 | grep -v NOTICE; }
state() { $P $H -d pre27_tmp -At -c "select coalesce(to_regclass('public.price_agreement_notices')::text, 'not applied')"; }
tweak() { # $1 function signature, $2 sed expression: re-create the function with a one-word change
  $P $H -d pre27_tmp -At -c "select pg_get_functiondef('$1'::regprocedure)" | tr -d '\r' | sed "$2" > /tmp/pre27_tweak.sql; $P $H -d pre27_tmp -q -v ON_ERROR_STOP=1 -f /tmp/pre27_tweak.sql 2>&1; }
fresh; out="$(apply)"; [ -z "$out" ] && [ "$(state)" != "not applied" ] && ok "a clean migration-26 database accepts migration 27" || bad "clean apply failed: $out"
out="$(apply)"; [ -z "$out" ] && ok "re-applying migration 27 is safe (the definitions are already migration 27's own)" || bad "retry failed: $out"
fresh; tweak "public.create_order(jsonb)" 's/Orders are always created as pending/Orders are ALWAYS created as pending/' >/dev/null
out="$(apply)"; echo "$out" | grep -q "create_order is not the definition migration 27 was written against" && [ "$(state)" = "not applied" ] && ok "a changed create_order is refused and nothing is applied" || bad "drifted create_order not refused: $out"
fresh; tweak "public.convert_website_request(uuid, jsonb)" 's/Only a confirmed request can be converted/Only a CONFIRMED request can be converted/' >/dev/null
out="$(apply)"; echo "$out" | grep -q "convert_website_request is not the definition migration 27 was written against" && [ "$(state)" = "not applied" ] && ok "a changed convert_website_request is refused and nothing is applied" || bad "drifted convert_website_request not refused: $out"
$P $H -d postgres -c "drop database if exists pre27_tmp" >/dev/null 2>&1
[ $fail -eq 0 ] && echo "PRECONDITION: all checks passed" || echo "PRECONDITION: FAILED"; exit $fail
