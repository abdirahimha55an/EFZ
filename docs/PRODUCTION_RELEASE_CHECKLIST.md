# EFZ Production release checklist (single source; updated 2026-10-21)
Production today: Hub `c1e873b`, database at migration 20 (verified read-only 2026-10-21, evidence `C:\EFZ-checks\M29_preflight_*`, `M29_defs_*`).

## Done (verified)
- [x] Read-only Production preflights run (21-29 markers all absent; order_details view matches 29c; all 7 migration-19 preconditions MATCH).
- [x] Cause of 29b guard refusal: Staging baseline text had CRLF, Production has LF (same code). Original 29b refuses on Production (reproduced locally: md5 c48f233d...).
- [x] CR-tolerant guard variants generated (`scripts/make_cr_tolerant_guards.mjs`, `supabase/production/*.crtolerant.sql`; originals untouched; `--check` proves only guard lines differ).
- [x] Local rehearsal on a Production-LF-shaped clone with migration 19 present: 21..28, 29a, 29b*, 29c, 29d, 29e* all apply (exit 0); 29 dispatch suite 35/35; rollback 29e and full 29 return the expected function md5s, drop dispatched columns/triggers, view md5 restored. Scripts in `supabase/production/rehearsal/`.
## Not done / blockers
- [ ] **Migration 19 + 19b on Production** (prerequisite of 27/28; passes its own guard). Not rehearsed from a pre-19 Production copy (the local copy already has 19). 19b guard on set_user_permissions is CR-sensitive and unverified on Production.
- [ ] Merge phase19 UI (`3d7959c`, `21f6100`) into the release line: conflicts in app/admin/layout.tsx, app/admin/requests/page.tsx, lib/types/index.ts.
- [ ] Fresh sealed Production backup + full restore-based rehearsal (needs your approval and password).
- [ ] Customer-account / registration: Edge Functions deployment, Auth sign-up/email (SMTP + sender domain), secrets.
- [ ] Privacy policy URL + account-deletion page URL (owner content), EAS production variables.
- [ ] Android: final package id, Play Console, Production keystore, version reconcile (0.1.0 vs 1.0.0), Production OTA path.
- [ ] Payments (EVC Plus/eDahab) and credit: keep DISABLED (no merchant credentials). Staging `stg_test` must not exist in Production.
## Next required action
Approve: (1) fresh Production backup + restore rehearsal incl. migration 19/19b, then (2) the Production window. Order: backup -> 19, 19b -> 21..28 -> 29a -> 29b*..29d -> Hub deploy (android branch merged with phase19 UI) -> 29e* -> smoke test.
