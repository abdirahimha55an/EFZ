# Migration 18 generator

`18b_website_request_inbox.sql`, `rollback/18b_rollback.sql` and `rollback/18c_rollback.sql` are generated.
`18a_order_request_confirmed.sql` and `18c_remove_legacy_request_insert.sql` are hand-written.

## Inputs

| File | Role |
|---|---|
| `18b.template.sql`, `18b_rollback.template.sql`, `18c_rollback.template.sql` | reviewed source templates |
| `fingerprints.json` | the md5 values the 18b pre-guard and the 18b rollback post-check compare against |
| `fingerprint18.sql` | read-only query that prints those values for a database |
| sealed dump (not in the repository) | `efz_prod_20261008-144503Z_public_schema.sql` from the 2026-10-08 14:45:03Z Production backup, sha256 `291de5728456fcf65531f7e142c1a17127646e4d1806e010abbf267528d7e468` |

The generator copies `grant_role_preset()`, `guard_system_logs_insert()` and three `order_requests` policies
from the dump, applies single-match edits, and refuses to write anything if the dump's sha256, the fingerprint
file, a template or an edit does not match.

## Regenerate and verify

From a clean checkout (all files in this folder and the migrations are LF, enforced by `.gitattributes`):

```sh
mkdir -p /tmp/m18gen/rollback
node supabase/production/m18/make18.mjs --dump <path to the sealed dump> \
  --fingerprints supabase/production/m18/fingerprints.json --out /tmp/m18gen
for f in 18b_website_request_inbox.sql rollback/18b_rollback.sql rollback/18c_rollback.sql; do
  [ "$(git hash-object /tmp/m18gen/$f)" = "$(git rev-parse HEAD:supabase/$f)" ] && echo "same $f" || echo "DIFFERENT $f"
done
```

Every line must print `same`. The migration hashes used in the Staging and Production windows are
`sha256` of the committed files, which equal the checked-out files because of the LF rule.
