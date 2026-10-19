#!/bin/bash
# Migration 28 integration tests - STAGING ONLY.
#   usage: ./run.sh g1_pricing | g2_designs | g3_overrides | g4_protections | g5_app_e2e | g6_rollback
#
# The Supabase project ref is PINNED below to EFZ-Staging; there is no option to change it, and every SQL file also starts by
# asserting that the synthetic Staging staff (u-stg-admin, u-stg-manager) exist, so it refuses to run anywhere else.
# Every group is one statement batch that ends by raising an exception carrying the results, so the whole transaction
# (fixtures, requests, orders, agreements, payments) is ROLLED BACK. Nothing persists; only sequence counters advance.
# The ONLY test that commits is concurrency.sh (it needs committed rows), and it is a separate script.
set -u
REF=adjjamiqwboawqedaapi   # EFZ-Staging. Production is rodmdvfjashiohgwople and must never appear here.
cd "$(dirname "$0")" || exit 2
G="${1:?group name, e.g. g1_pricing}"
[ "$G" = g6_rollback ] && node gen_g6.cjs ../../..      # builds g6_rollback.sql from the real migration + rollback files
T="${TMPDIR:-/tmp}"
cat prelude.sql prelude2.sql "$G.sql" > "$T/28_$G.sql"
supabase db query --linked --project-ref "$REF" --output-format json -f "$T/28_$G.sql" 2>&1 | grep -v Initialising > "$T/28_$G.out"
node parse.cjs "$T/28_$G.out"
