# ConvertRequestDialog DOM test (local only)

Renders the REAL `components/admin/requests/ConvertRequestDialog.tsx` in jsdom against a stubbed database (`stubdb.js` replaces only `@/lib/supabase/db`) and drives it like a user: list price, product and design agreement, failed / malformed price lookup and Retry, review blocking, override summary and reason validation, several designs of one product, customer switch, duplicate-conversion refusal. 32 checks. No network, no Supabase, nothing in the repo is modified.

The tools are NOT repo dependencies. Copy this folder to a scratch directory, install them there, and point the build at the repo:

    mkdir %TEMP%\dom-test && copy scripts\dialog-dom-test\* %TEMP%\dom-test
    cd %TEMP%\dom-test && npm init -y && npm i esbuild@0.25.9 jsdom@26.1.0
    node build.mjs <absolute path to this repo>
    node scenarios.mjs

(`scenarios.mjs` / `build.mjs` expect `entry.jsx`, `stubdb.js` and the generated `bundle.js` beside them.) It is not a substitute for a run in a real browser against the preview; see docs/MIGRATION_28_BROWSER_RUN_SHEET.md.
