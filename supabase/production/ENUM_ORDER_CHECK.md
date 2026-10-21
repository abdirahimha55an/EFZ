# Enum order check v1 (supplements the pinned baseline; does not replace it)

Files
- `enum_order_check_v1.sql` - read-only; one row per public enum label in true enum order:
  `typname | enumlabel | enumsortorder::text | rank`. sha256 `f0783091d1b4d7879e4b145f535c75ee65576a1de56d060e0d1b962206811fa2`.
- `prod_backup_baseline.sql` is UNCHANGED (sha256 `6c454b4aca11b034222347650d5d3bfb629dc4b80987f6b655e0e6ac38b55f1e`). Its legacy enum
  checksum row stays in every baseline and every comparison; nothing historical is rewritten.
- Scripts (outside the repo): `C:\EFZ-checks\P14\m20_staging\staging_backup.ps1` (sha256 `b718c182...d4c0`) and
  `staging_restore_verify.ps1` (sha256 `a0b65443...540d`). Previous versions are kept in `_superseded_20261016\`.

## Why it exists
The baseline's enum row hashes labels ordered by `lpad(enumsortorder::text, 6, '0')` compared as TEXT. `ALTER TYPE ... ADD VALUE ... AFTER/BEFORE`
stores a fractional sort order (e.g. 3.5, 2.5); as text `0003.5` sorts after `000004`, so that label moves to the end of the hashed string.
`pg_restore` recreates each enum from its label list (sort orders 1..n), so the restored copy hashes differently with identical labels and order.
That is why every Staging restore (and every Production restore taken since Migration 18) shows a different enum checksum.

## What changed for Staging backups and restore verification
- Backup: runs the check read-only before and after the dump; the two snapshots must be identical line for line (labels, order AND sort-order
  numbers) or the bracket fails (exit 3, no seal). After BRACKET OK it writes an `ENUM-SNAPSHOT:` provenance line into `run_manifest.txt`
  (hashes of both snapshots, the enum SQL and the backup script).
- Restore verification compares each enum type's label sequence (as arrays) between Staging and the restored copy: any missing, extra,
  duplicate, malformed or reordered label is exit 2. The legacy checksum row is still shown as DIFFERENT when it differs.
  - Exit 0 "EXPLAINED" only if the sealed backup holds a provenance-verified Staging snapshot AND the legacy checksum recomputes exactly
    (PostgreSQL `lpad` pad/truncate and `COLLATE "C"` byte order) for both Staging and the restored copy.
  - No snapshot, missing provenance or an unreviewed backup script: label comparison against the schema dump, exit 3 (open exception) at best.
  - Exactly one snapshot file, before != after, snapshot disagreeing with the dump, malformed or inconsistent provenance: exit 2.
- Limitation: the provenance line is a manifest of hashes, NOT a cryptographic signature. Forged files plus a forged line would qualify.

## Status of the 2026-10-15 Staging backup (`C:\EFZ-backups\staging\20261015-180251Z`)
Sealed, unchanged. It predates this check, so it has no sort-order snapshot: its restore verification ended at exit 3. 50 of 51 fingerprints identical, all 13
enums identical in labels and order. The explanation of the enum checksum (fractional sort orders 3.5 and 2.5 from Migrations 12 and 18a) is a
LOCAL REPRODUCTION from the schema dump, not a direct query of Staging; Staging's original `enumsortorder` values were never observed.
