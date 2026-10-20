#!/bin/bash
# STAGING ONLY (ref hard-coded). Applies the migration(s) inside ONE transaction, runs the tests, and ends by raising 'T28RESULT:<json>' so NOTHING is committed.
#   ./run.sh         -> for a database that already has 29a..29c: applies 29d, then tests
#   ./run.sh --full  -> for a database that has only 29a: applies 29b, 29c, 29d, then tests
# 29a_dispatch_enum.sql must already be committed (a new enum label cannot be used in the transaction that adds it).
REF=adjjamiqwboawqedaapi
cd "$(dirname "$0")"
FILES="29d_live_orders_topic_by_user"
[ "$1" = "--full" ] && FILES="29b_dispatch_and_live_orders 29c_order_details_dispatched 29d_live_orders_topic_by_user"
{ cat ../28_integration/prelude.sql ../28_integration/prelude2.sql
  for f in $FILES; do sed -e '/^begin;$/d' -e '/^commit;$/d' ../../$f.sql; done
  cat body.sql; } > _run.sql
supabase db query --linked --project-ref "$REF" --output-format json -f _run.sql 2>&1 | grep -v Initialising > _run.out
node ../28_integration/parse.cjs _run.out
rm -f _run.sql
