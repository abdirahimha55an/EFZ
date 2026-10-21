-- ============================================================================
-- EFZ - ENUM ORDER CHECK v1 (read-only; NOT a migration; creates and writes nothing)
-- ----------------------------------------------------------------------------
-- One row per public enum label, in the enum's ACTUAL order (pg_enum.enumsortorder,
-- a float4 compared numerically):   typname | enumlabel | enumsortorder::text | rank
-- Run with:  psql -X -q -A -t -F '|' -v ON_ERROR_STOP=1 -f enum_order_check_v1.sql
-- Why this exists: the pinned baseline (prod_backup_baseline.sql, sha256 6c454b4a...)
-- orders labels by lpad(enumsortorder::text, 6, '0') as TEXT, so a fractional sort order
-- written by ALTER TYPE ... ADD VALUE ('0002.5') sorts after '000004'. A restore renumbers
-- sort orders to 1..n, so that checksum differs while labels and order are identical.
-- This check compares labels in true enum order instead, and records the sort-order
-- numbers so the legacy checksum can be recomputed and explained, not just ignored.
-- ============================================================================
select t.typname, e.enumlabel, e.enumsortorder::text,
       row_number() over (partition by t.typname order by e.enumsortorder)
  from pg_type t
  join pg_namespace n on n.oid = t.typnamespace
  join pg_enum e on e.enumtypid = t.oid
 where n.nspname = 'public'
 order by t.typname, e.enumsortorder;
