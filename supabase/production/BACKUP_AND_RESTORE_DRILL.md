# EFZ Production — external backup and isolated restore drill

**Status: procedure for review. Nothing in it has been run** — no dry run, no
backup, no restore drill. Part A is performed by the script
`partA_backup.ps1`, which READS Production. The script has two separately
approved checkpoints (dry run, then real run; see A.3 and A.4). Part C
modifies only a throwaway local database. Production is never modified by
anything in this document.

| Part | What it touches | Can it change data? |
|---|---|---|
| **A — Backup** (`partA_backup.ps1`) | Dry run: **local files only, no connection**. Real run: **READS Production** (`rodmdvfjashiohgwople`) | No. `pg_dump` runs in a read-only snapshot; the baseline runs in `BEGIN READ ONLY … ROLLBACK` |
| **B — Seal** (manual) | Local backup files only | No database is contacted |
| **C — Restore drill** (manual) | **MODIFIES only the disposable local database** `efz_restore_drill` on `localhost:54331` | Only that throwaway database |
| **D — Recovery procedure** | Reference for a real incident | Every step needs separate owner approval |

Files used. The hashes are full SHA-256 values, computed locally on 2026-10-02
from the files in the working tree. Each file is untracked in git, so
re-verify its hash before approving or running anything. If a hash no longer
matches, the file changed after this review and must be reviewed again.

| File | Purpose | sha256 |
|---|---|---|
| `partA_backup.ps1` | Part A: local guards, dry run, read-only Production backup and bracket check | `fde6f9b88bd3b5167fcaf5bd49a9af0bde9f9cf8be2ce8ec6e3b9089de94f0a6` |
| `prod_backup_baseline.sql` | Read-only fingerprint: migration state, objects, every table's rows and md5, money totals. Run identically on Production and on the restored copy | `6c454b4aca11b034222347650d5d3bfb629dc4b80987f6b655e0e6ac38b55f1e` |
| `restore_target_prereqs.sql` | Creates Supabase role names / `extensions` schema on the drill database only; refuses any other database | `31de1315a153b25ad76214daa4226b17fddc8a39c3b0eb5f7032d0f862fbb66e` |
| `../checks/validate_financials.sql` | Existing read-only financial integrity check | `6646465acf0d355f5f73f06cd6a5177dc729f350e4829e65a760b9f496df125d` |

To verify the hashes locally (this reads files only; it contacts no database).
Run it from the folder **`C:\Users\Abdirahim\Desktop\EFZ\supabase\production`**,
because the paths are relative to it:
```powershell
Set-Location 'C:\Users\Abdirahim\Desktop\EFZ\supabase\production'
Get-FileHash -Algorithm SHA256 .\partA_backup.ps1, .\prod_backup_baseline.sql, .\restore_target_prereqs.sql, ..\checks\validate_financials.sql
```
At run time the script also prints its own sha256 and the baseline's, and
records both in `run_manifest.txt`. They must equal the values above.

---

## 0. Before starting

### 0.1 Tools (local machine, no installation into Windows)
Download the **PostgreSQL 17 Windows x64 binaries ZIP** from EnterpriseDB
("zip archive", not the installer) and extract to `C:\pgsql17`, giving
`C:\pgsql17\pgsql\bin\{pg_dump,pg_restore,psql,initdb,pg_ctl}.exe`.
The script refuses a `pg_dump` older than 17. Version 17 can dump a Supabase
server running PostgreSQL 15 or 17. If Production is newer than 17, `pg_dump`
stops with a version-mismatch error before reading any data; in that case,
get the matching newer binaries and pass `-PgBin`.
*Status 2026-10-02: `C:\pgsql17` does not exist yet.*

### 0.2 Production CA certificate
Supabase Dashboard → **Production** project → Project Settings → Database →
*SSL configuration* → download the CA certificate (`prod-ca-2021.crt`). Save it
outside the repository, e.g. `C:\EFZ-certs\prod-ca-2021.crt`. The script checks
that the file:
- is a readable X.509 certificate;
- is a CA (basic constraints);
- is inside its validity period;
- names Supabase in its subject.

The dry run prints the certificate's subject, issuer, validity and **file
SHA-256**. The owner checks those details. That SHA-256 is then pinned for the
real run (A.4).
*Status 2026-10-02: `C:\EFZ-certs` does not exist yet.*

### 0.3 Where backups live
`C:\EFZ-backups\<timestamp>\`, a new folder for each run, created by the
script. Never commit a dump: it holds customer data and Auth password hashes.
The script refuses a backup root inside the repository or inside OneDrive.
Desktop folders synced by other tools are not detected, so do not use them.
Use an encrypted drive (BitLocker) or the 7-Zip step in B.4.

### 0.4 Inputs the owner must supply (never pasted into chat, files or git)
| Input | Where to find it | Notes |
|---|---|---|
| Session-pooler host (`-PoolerHost`) | Supabase Dashboard → **Production** project → **Connect** → *Session pooler* | Must look like `aws-N-<region>.pooler.supabase.com`; the script uses port **5432** (session mode, not 6543). The direct host `db.<ref>.supabase.co` is IPv6-only on the Free plan. The script has no separate check for it: it is refused because it does not match the session-pooler host pattern (A.2 item 1). Confirm it is taken from the **Production** project, not EFZ-Staging: the pooler host is shared by projects in the same region, so the project is identified by the user below |
| Database user | fixed in the script | `postgres.rodmdvfjashiohgwople`; it cannot be changed from the command line |
| CA certificate (`-CaCertPath`) | 0.2 | Path must not contain a single quote |
| Database password | the password set when the project was created | Typed at the script's prompt during the real run only. **Do not reset it**: a reset is a Production change. If it is unknown, stop and decide separately |

### 0.5 Timing
Run the real Part A in a quiet period (no staff using the app). The baseline
is taken before and after the dump. If anything is written in between, the
bracket fails (exit 3) and Part A is simply repeated.

### 0.6 Certificate verification through the pooler: NOT YET TESTED
The script connects with `sslmode=verify-full` against the pinned Production CA.
**Nobody has yet tested whether the Production session pooler presents a
certificate chain that verifies against that CA with `verify-full`.** The dry run
cannot test it, because it never connects.

If verification fails, the first Production step (A.4.1, baseline before)
fails, the script stops with exit 2, and no data is read. **That failure ends
the process.** Do not weaken the TLS mode: do not edit the script to use
`sslmode=require`, `prefer` or `verify-ca`, and do not run the old hand-pasted
commands. Report the error text (from `baseline_before.stderr.log`) to the
owner. Any change to the connection method needs a new review and a new
approval.

---

## Part A — Backup with `partA_backup.ps1`

Part A is run **only** through the script. Do not paste its steps by hand. Run it
as a script file (not pasted line by line), from the folder
`C:\Users\Abdirahim\Desktop\EFZ\supabase\production`. The commands below call
`.\partA_backup.ps1` by a relative path.
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\partA_backup.ps1 <arguments>
```
Optional parameters (defaults shown): `-PgBin C:\pgsql17\pgsql\bin`,
`-Repo C:\Users\Abdirahim\Desktop\EFZ`, `-BackupRoot C:\EFZ-backups`.

### A.1 Approval checkpoints
| # | Step | Touches | Approval needed |
|---|---|---|---|
| 1 | Prerequisites (section 0) installed / downloaded; file hashes verified against the table above | Local only | Owner reviews |
| 2 | **Dry run** (A.3) | Local only: **no database connection, no password prompt, no backup folder or other persistent output** (it only runs local version checks and uses a temporary file, which it deletes; see A.3) | **Approval 1**: the first checkpoint |
| 3 | Owner reviews the dry-run output: CA subject/issuer/validity/SHA-256, `pg_dump`/`psql` versions, script and baseline hashes, connection string, backup folder | — | Owner reviews |
| 4 | **Real run** (A.4) | **READS Production** | **Approval 2: separate, explicit**, given only after steps 1–3. Approval 1 does not cover it |

### A.2 What the script checks before any connection (dry run and real run)
Any failed check prints `STOP (no database connection was made): …` and exits
with code **1**. Nothing after it runs.

1. **Production identity guard.**
   - `-PoolerHost` must match `aws-N-<region>.pooler.supabase.com` (regex
     `^aws-\d+-[a-z0-9-]+\.pooler\.supabase\.com$`). This single pattern check
     is also what refuses the direct host `db.<ref>.supabase.co` and any other
     host; there is no separate direct-host check.
   - The EFZ-Staging project ref `adjjamiqwboawqedaapi` must not appear in the
     inputs.
   - The connection string is built only from these checked parts plus the
     fixed user `postgres.rodmdvfjashiohgwople`. It is then checked again: it
     must have the Production user, a pooler host, `sslmode=verify-full`, no
     Staging ref and no `<REGION-HOST>` placeholder.

   **What it protects against:** pointing the backup at EFZ-Staging (whose
   test data would then pass as the "Production backup"), at the IPv6-only
   direct host, at a mistyped or placeholder host, or at any other server. The
   database user carries the project ref, so the pooler routes to Production
   or to no project at all.
2. **libpq environment overrides.** The script stops if any of these
   variables is set: `PGHOST`, `PGHOSTADDR`, `PGPORT`, `PGDATABASE`, `PGUSER`,
   `PGPASSWORD`, `PGPASSFILE`, `PGSERVICE`, `PGSERVICEFILE`, `PGSSLMODE`,
   `PGSSLROOTCERT`, `PGSSLCERT`, `PGSSLKEY`, `PGOPTIONS`, `PGCONNECT_TIMEOUT`
   or `PGTARGETSESSIONATTRS`. Any of them could silently redirect the
   connection or alter its TLS settings.
3. **TLS certificate** (section 0.2): it must exist and be readable X.509, a
   CA, in date, and issued for Supabase. **There is no fallback to a weaker
   SSL mode.** Every certificate failure is reported as
   `CERTIFICATE VERIFICATION UNAVAILABLE`.
4. **Tools and inputs.**
   - `psql.exe` and `pg_dump.exe` must exist, and `pg_dump` must be 17 or
     newer. To read the versions, the script runs `pg_dump --version` and
     `psql --version` locally. It captures their output in a temporary file
     (`[System.IO.Path]::GetTempFileName()`, in `%TEMP%`) and deletes that file
     in a `finally` block. Neither command contacts a database. `psql`'s
     version is printed but not checked.
   - `prod_backup_baseline.sql` must exist.
   - The versions, the baseline's sha256 and the script's own sha256 are
     printed.
5. **Backup location.** It must be outside the repository and outside
   OneDrive, and the new `<UTC timestamp>Z` folder must not already exist.

### A.3 Dry run: checkpoint 1 (no connection)
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\partA_backup.ps1 -DryRun `
  -PoolerHost aws-0-<region>.pooler.supabase.com -CaCertPath C:\EFZ-certs\prod-ca-2021.crt
```
The dry run runs only the A.2 checks. It prints the CA details, versions,
hashes, the connection string (without a password) and the folder it *would*
use. Then it ends with exit **0** and the message `DRY RUN COMPLETE … No
database connection was made, no password was requested, nothing was
written.`, and prints the CA SHA-256 to pin for the real run.

What "nothing was written" means precisely:
- **No database connection** and no password prompt.
- **No persistent output**: no backup folder, no manifest, no logs, no dump.
  `C:\EFZ-backups` is not created.

Two things do happen locally:
- `pg_dump.exe --version` and `psql.exe --version` are executed.
- A temporary file in `%TEMP%` is created to hold their output, then deleted
  (A.2 item 4).

Owner review before Approval 2:
- The CA subject, issuer and validity are the Supabase CA from the
  **Production** project's Dashboard.
- The script and baseline hashes equal the table at the top.
- `pg_dump` is 17 or newer.
- The host is the Production session pooler.

### A.4 Real run: checkpoint 2 (READS Production, separate approval)
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\partA_backup.ps1 `
  -PoolerHost aws-0-<region>.pooler.supabase.com -CaCertPath C:\EFZ-certs\prod-ca-2021.crt `
  -ConfirmCaSha256 <the CA sha256 printed by the dry run and checked by the owner>
```
The script repeats every A.2 check, then requires `-ConfirmCaSha256` to equal
the CA file's SHA-256. This **pins** the exact certificate reviewed in the
dry run. If it doesn't match, the script stops with exit 1 before any
connection.

TLS is `sslmode=verify-full` with `sslrootcert` = that pinned CA. libpq checks
two things: that the server certificate chains to that CA, and that the
certificate's name matches the pooler host. There is no weaker fallback; see
0.6.

The script then:
1. creates `C:\EFZ-backups\<TS>\`, where `<TS>` is the UTC timestamp
   `yyyyMMdd-HHmmssZ`;
2. writes `run_manifest.txt`, which holds the connection string without a
   password, the CA subject and sha256, the tool versions, and the baseline
   and script sha256;
3. prompts for the password;
4. runs the steps below, in this exact order.

`<conn>` below is the checked connection string
`host=<PoolerHost> port=5432 dbname=postgres user=postgres.rodmdvfjashiohgwople sslmode=verify-full sslrootcert='<CA path>'`.

| Step | Exact program and arguments (from the script) | Read-only how | Files written in the backup folder |
|---|---|---|---|
| A.4.1 | **Baseline before**: `psql.exe -X -q -A -F \| -v ON_ERROR_STOP=1 -d <conn> -f <Repo>\supabase\production\prod_backup_baseline.sql -o baseline_before.txt` | `BEGIN READ ONLY … ROLLBACK` inside the file | `baseline_before.txt` (query results, via `-o`); `baseline_before.stdout.log` (psql stdout; normally empty because results go to `-o`); `baseline_before.stderr.log` (psql stderr, e.g. connection/TLS errors) |
| A.4.2 | **Backup**: `pg_dump.exe -d <conn> --format=custom --compress=9 --schema=public --schema=auth --verbose --file efz_prod_<TS>_public_auth.dump` | `pg_dump` reads in a single REPEATABLE READ, READ ONLY snapshot | `efz_prod_<TS>_public_auth.dump`; `pg_dump_full.stdout.log` (stdout; normally empty because output goes to `--file`); `pg_dump_full.log` (stderr: `--verbose` progress and any errors) |
| A.4.3 | **Schema-only dump**: `pg_dump.exe -d <conn> --schema-only --schema=public --file efz_prod_<TS>_public_schema.sql` (readable SQL) | same as A.4.2 | `efz_prod_<TS>_public_schema.sql`; `pg_dump_schema.stdout.log` (stdout; normally empty); `pg_dump_schema.log` (stderr) |
| A.4.4 | **Baseline after**: same arguments as A.4.1 with `-o baseline_after.txt` | same as A.4.1 | `baseline_after.txt`; `baseline_after.stdout.log`; `baseline_after.stderr.log` |
| A.4.5 | **Bracket comparison**: only lines containing `\|MATCH\|` are taken from each baseline file. Before and after must have the same count and `Compare-Object` must find no differing line | local comparison, no connection | `BRACKET OK: …` or `BRACKET FAILED: …` appended to `run_manifest.txt`; on failure also `BRACKET_FAILED_diff.txt` |

How each step is run and checked:
- The script starts each program directly, not through the PowerShell
  pipeline. It captures that program's stdout and stderr in memory and writes
  them to the two log files **after the program exits**, so a log is empty or
  missing while its step is still running.
- Each step after A.4.1 runs only if the previous one succeeded.
- Success is decided only by the program's exit code, so `pg_dump --verbose`
  progress on stderr is not treated as an error.
- On top of the exit codes, the script checks that:
  - each baseline produced at least one `|MATCH|` row;
  - each dump file exists and is non-empty.

`public` holds all business data, functions, triggers, RLS policies and
grants. `auth` holds the staff login accounts (`auth.users`,
`auth.identities`) and the `trg_on_auth_user_created` trigger that links them
to profiles.

Not included on purpose: the Supabase-managed schemas (`storage`, `realtime`,
`extensions`, `vault`, …). EFZ stores no files in Supabase Storage, because
product images are external URLs. The baseline's `storage.objects` row records
the count, so this is verified, not assumed.

A passing bracket means the dump holds exactly the state described by
`baseline_after.txt`. That file is the reference the restore is checked
against (C.5).

### A.5 Exit codes and failure behaviour
| Exit | Meaning | What was touched | What to do |
|---|---|---|---|
| **0** | `BRACKET OK` and `PART A COMPLETE` | Production read only | Continue with Part B |
| **1** | A local check failed (A.2), or `-ConfirmCaSha256` didn't match. **Also:** an unexpected PowerShell error while creating the backup folder or writing `run_manifest.txt` (script lines 194–204, which run before the password prompt and outside the `try` block). Such an error stops the script as an uncaught error, and PowerShell `-File` reports exit 1 | **No connection was made and no password was requested.** For a check failure, no backup folder was created. For a folder or manifest error, `C:\EFZ-backups\<TS>\` may exist, empty or with a partial `run_manifest.txt` that has no `BRACKET OK` line. B.0 refuses such a folder | Read the red message. Fix the input or the local problem (disk, permissions). Re-review if a file or hash changed. A partial folder holds no data; it can be left or deleted |
| **2** | A Production read step failed: empty password, a psql/pg_dump error (TLS/certificate failure included), no MATCH rows, or a missing or empty dump file | Production read only; the backup folder may hold partial files and `STOPPED: …` in `run_manifest.txt` | **Stop.** Report the message and the step's `.log`/`.stderr.log`. If it mentions SSL or certificates, see 0.6 and do not weaken TLS. Treat partial files as unusable |
| **3** | `BRACKET FAILED`: Production changed during the dump | Production read only | The dump is **UNVERIFIED** and must not be used for Part C. Repeat Part A in a quieter period |

Any exit other than 0 means there is **no verified backup**.

### A.6 Credential handling and cleanup
- The password is typed at a `Read-Host -AsSecureString` prompt and never
  written to disk, to the manifest or to the logs.
- The password is placed in this process's `PGPASSWORD`, and only after all
  local checks have passed. The child `psql` and `pg_dump` processes inherit
  it from there. The temporary unmanaged copy (BSTR) is zeroed and freed at
  once.
- **Normal end, error, or Ctrl+C:** a `finally` block removes `PGPASSWORD` from
  the environment, disposes of the secure string, and prints `Credentials
  removed from this process.`
- **Ctrl+C while `psql` or `pg_dump` is running:** the script is then waiting
  in a .NET `WaitForExit()` call, which PowerShell cannot interrupt. The stop
  may therefore only take effect when the running program finishes. The
  `finally` block then runs as above.
- **Forced termination** (closing the window, Task Manager / `Stop-Process`, a
  crash or power loss): the `finally` block does **not** run.
  - The password was only ever in memory, in that process's environment, and
    never on disk, so it disappears with the process.
  - Windows does not end child processes with their parent. A `psql` or
    `pg_dump` that was running keeps its own inherited copy of `PGPASSWORD`
    and may continue its read-only work until it finishes.
  - After a forced termination, check Task Manager for remaining `pg_dump.exe`
    or `psql.exe` processes and end them.
  - What the backup folder is worth depends on when the termination happened.
    Check `run_manifest.txt`:
    - **No `BRACKET OK` line:** the termination came before the run was
      fully verified. The folder must be treated as **unverified** and is not
      a backup; B.0 refuses it.
    - **A complete `BRACKET OK: …` line:** both baselines, both dumps and the
      bracket comparison had already succeeded. The termination then only
      prevented the credential cleanup and the final `PART A COMPLETE`
      message, so the backup may already be complete and verified. It is
      accepted only through B.0, followed by the seal (B.1–B.3).
- While the run lasts, the password is in that process's environment.
  Processes running under the same Windows account could read it. Run Part A
  in a dedicated window with nothing else running, and close the window
  afterwards.
- The script makes no Production connection after the real run ends.

**Production is not contacted again in Parts B and C.** Part D (a real
incident) lists its own Production steps, each with a separate approval.

---

## Part B — Seal the backup (local files only)

Parts B and C are manual (not scripted). Run them only after Part A exited with 0.

### B.0 Variables (new PowerShell window; Part A's window is closed)
```powershell
$PG   = 'C:\pgsql17\pgsql\bin'
$REPO = 'C:\Users\Abdirahim\Desktop\EFZ'
$BK   = 'C:\EFZ-backups\<timestamp printed by PART A COMPLETE>'
$TS   = Split-Path $BK -Leaf          # the dump files are named efz_prod_${TS}_...
if (-not (Test-Path "$BK\efz_prod_${TS}_public_auth.dump")) { throw 'STOP: wrong backup folder' }
if (-not (Select-String "$BK\run_manifest.txt" -Pattern '^BRACKET OK' -Quiet)) { throw 'STOP: this backup has no BRACKET OK - it is not verified' }
```

### B.1 Contents of the archive
```powershell
& "$PG\pg_restore.exe" --list "$BK\efz_prod_${TS}_public_auth.dump" > "$BK\dump_toc.txt"
"TABLE DATA entries: public $((Select-String "$BK\dump_toc.txt" -Pattern ' TABLE DATA public ').Count), auth $((Select-String "$BK\dump_toc.txt" -Pattern ' TABLE DATA auth ').Count)"
```
Expected: one `TABLE DATA public` entry per public table listed in section
`3 tables` of the baseline; `auth` includes `users` and `identities`.

### B.2 SHA-256 of every file (once per backup)
`SHA256SUMS.txt` is never listed in itself. B.2 refuses to run if
`SHA256SUMS.txt` already exists, because the seal is made once and never
overwritten. Run B.1 first, so that `dump_toc.txt` is covered.
```powershell
$sums = Join-Path $BK 'SHA256SUMS.txt'
if (Test-Path -LiteralPath $sums) { throw 'STOP: SHA256SUMS.txt already exists - this backup is already sealed; use B.3' }
$lines = Get-ChildItem -LiteralPath $BK -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | Sort-Object Name |
  ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name }
$lines | Set-Content -LiteralPath $sums
Get-Content -LiteralPath $sums
```

### B.3 Verify the checksums (repeat before any restore, and on any copy)
This checks every listed file. It also reports any file in the folder that is
not listed, other than `SHA256SUMS.txt` itself, and any listed file that is
missing.
```powershell
$sums   = Join-Path $BK 'SHA256SUMS.txt'
$listed = @{}
$bad = @(Get-Content -LiteralPath $sums | ForEach-Object {
  $h, $f = $_ -split '  ', 2
  $listed[$f] = $true
  $p = Join-Path $BK $f
  if (-not (Test-Path -LiteralPath $p)) { "MISSING: $f" }
  elseif ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() -ne $h) { "MISMATCH: $f" } })
$bad += @(Get-ChildItem -LiteralPath $BK -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' -and -not $listed.ContainsKey($_.Name) } |
  ForEach-Object { "NOT LISTED: $($_.Name)" })
if ($bad.Count -gt 0) { 'CHECKSUM PROBLEM:'; $bad } else { "all $($listed.Count) checksums OK" }
```

### B.4 Off-machine encrypted copy (recommended)
With 7-Zip: `7z a -t7z -mhe=on -p "C:\EFZ-backups\$TS.7z" "$BK\*"` (it asks for an
archive password; keep it apart from the archive). Copy the `.7z` and
`SHA256SUMS.txt` to a second location. Record where.

---

## Part C — Restore drill (MODIFIES ONLY the disposable local database)

Target: a brand-new PostgreSQL 17 cluster in `C:\EFZ-restore-drill`, listening
on **localhost:54331 only**, database **`efz_restore_drill`**. Not EFZ-Staging
(it holds test data) and never Production. It contains a copy of Production data
while it exists — delete it at C.8.

### C.1 Verify the backup first
Run B.3. Do not restore from a file whose checksum does not match.

### C.2 Create and start the throwaway cluster
```powershell
$DR = 'C:\EFZ-restore-drill'
if (Test-Path $DR) { throw "STOP: $DR exists - remove the previous drill first" }
New-Item -ItemType Directory -Path $DR | Out-Null
$drillPw = [guid]::NewGuid().ToString('N'); Set-Content "$DR\pw.txt" $drillPw   # throwaway, local only
& "$PG\initdb.exe" -D "$DR\data" -U postgres -E UTF8 --locale=C -A scram-sha-256 --pwfile="$DR\pw.txt"
& "$PG\pg_ctl.exe" -D "$DR\data" -l "$DR\server.log" -o "-p 54331 -c listen_addresses=localhost" start
$env:PGPASSWORD = $drillPw
$DRILLADM = 'host=localhost port=54331 dbname=postgres user=postgres'
$DRILL    = 'host=localhost port=54331 dbname=efz_restore_drill user=postgres'
if ($DRILL -notmatch '^host=localhost port=54331 ') { throw 'STOP: drill target must be localhost:54331' }
```

### C.3 Prepare the drill database
```powershell
& "$PG\psql.exe" -X -d $DRILLADM -c "create database efz_restore_drill"
& "$PG\psql.exe" -X -d $DRILL -f "$REPO\supabase\production\restore_target_prereqs.sql"
if ($LASTEXITCODE -ne 0) { throw 'STOP: prerequisites failed' }
```

### C.4 Restore (timed — this is the measured recovery time)
```powershell
$t0 = Get-Date
& "$PG\pg_restore.exe" --no-owner --dbname $DRILL --verbose "$BK\efz_prod_${TS}_public_auth.dump" 2> "$DR\pg_restore.log"
$exit = $LASTEXITCODE; $t1 = Get-Date
"pg_restore exit $exit, $([int]($t1 - $t0).TotalSeconds) s" | Tee-Object "$DR\restore_summary.txt"
Select-String "$DR\pg_restore.log" -Pattern 'error' | Tee-Object "$DR\restore_errors.txt"
```
Every error line must be classified in the report. Expected and harmless:
`schema "public" already exists`. Anything that fails to create a table, load
table data, or create a function/trigger/policy is a **drill failure** — C.5
will show it as a MATCH difference.

### C.5 Verify the restored copy against Production's baseline
```powershell
& "$PG\psql.exe" -X -q -A -F '|' -d $DRILL -f "$REPO\supabase\production\prod_backup_baseline.sql" -o "$DR\baseline_restored.txt"
$p = Get-Content "$BK\baseline_after.txt"    | Where-Object { $_ -match '\|MATCH\|' }
$r = Get-Content "$DR\baseline_restored.txt" | Where-Object { $_ -match '\|MATCH\|' }
$d = Compare-Object $p $r
if ($d) { 'RESTORE VERIFICATION FAILED:'; $d } else { "RESTORE VERIFIED: all $($r.Count) MATCH rows identical to Production" }
```
The MATCH rows cover:
- migration state (08 present; 10, 11, 12 absent on Production today);
- objects: tables, views, functions (count + md5 of every definition),
  triggers incl. `auth.users` (count + md5), RLS policies (count + md5),
  RLS-enabled tables, enum types;
- **every public table and `auth.users` / `auth.identities`: row count and
  md5 of every row's full content**;
- order totals by status, payments, commissions by status, stock per product,
  audit-line count.

### C.6 Financial integrity on the restored copy
```powershell
& "$PG\psql.exe" -X -d $DRILL -f "$REPO\supabase\checks\validate_financials.sql" -o "$DR\validate_financials_restored.txt"
Select-String "$DR\validate_financials_restored.txt" -Pattern '\bFAIL\b'
```
This runs on the **drill database only** (`$DRILL`, localhost:54331).

**There is no Production `validate_financials.sql` reference result.** Part A
does not run this check on Production, and this procedure never does either.
The C.6 result is therefore judged on its own:
- **Pass:** no `FAIL` rows.
- `WARN` and `INFO` rows are copied into the drill record (E), not compared.

Equality with Production is proven by C.5 instead: every table's row count
and row md5 match `baseline_after.txt`, which Part A captured from Production
inside the bracket. A run of this check on Production for comparison would be
a separate Production read. It is not part of this procedure and would need
its own review and approval.

What is captured, and when:

| When | File | Source |
|---|---|---|
| Before the restore | `$BK\baseline_after.txt` | Part A (Production, read-only, inside the bracket) |
| Before the restore | B.3 `all … checksums OK` | Local files |
| After the restore | `$DR\restore_summary.txt`, `$DR\restore_errors.txt` | C.4, drill database |
| After the restore | `$DR\baseline_restored.txt` | C.5, drill database |
| After the restore | `$DR\validate_financials_restored.txt` | C.6, drill database |

Before C.8 deletes `$DR`, copy the C.5 and C.6 results into section E (counts
and verdicts only, no data).

### C.7 Record the drill
Fill in section E and keep it with `SHA256SUMS.txt` (no data in it).

### C.8 Discard the drill database
```powershell
& "$PG\pg_ctl.exe" -D "$DR\data" stop
Remove-Item Env:PGPASSWORD
Remove-Item -Recurse -Force $DR      # removes the local copy of Production data
```

### Pass criteria
1. Part A exit 0 with A.4.5 `BRACKET OK`.
2. B.3 checksums OK.
3. C.4 every error line classified as harmless.
4. **C.5 all MATCH rows identical.**
5. C.6 no FAIL.
Only then is the backup a **verified external backup** and the drill a
**successful restore drill**.

---

## Part D — Recovery procedure (for a real incident)

Each step needs explicit owner approval at the time. Prefer the least
destructive option that fixes the problem.

| Situation | Action | Data restore? |
|---|---|---|
| A migration **fails while applying** | Nothing: each migration is one transaction, so a failure leaves nothing behind. In the SQL Editor run `rollback;` once, stop, report | No |
| A migration applied but is **wrong; data intact; new features unused** | Its rollback file (`rollback/1x_rollback.sql`) restores the previous definitions; it refuses once the migration's data exists | No |
| Migration applied, **in use**, defect found | Fix forward with a new migration | No |
| **Data lost or corrupted** | Steps below | Yes |

Data recovery:
1. **Stop writes**: tell staff to stop using the app (and, if needed, take the
   site offline in Vercel). Note the time.
2. **Preserve evidence**: take a new Part A backup of the damaged Production
   with `partA_backup.ps1`. This is a **Production read**: it needs its own
   dry run and approvals (A.1). Never overwrite the only copy of what
   happened. Its bracket may fail if writes have not fully stopped. Record
   that, and keep the dump as evidence even so.
3. **Restore the last verified backup into a NEW Supabase project** (or the
   Part C local target to inspect it first). Run `prod_backup_baseline.sql`
   **against that restore target, not Production**. Its MATCH rows must equal
   that backup's `baseline_after.txt`.
4. Choose, with the owner:
   - **(a) Switch over** — point the app at the new project (Vercel
     `NEXT_PUBLIC_SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_ANON_KEY`), verify
     sign-in and pages; old Production stays untouched for analysis; or
   - **(b) Repair in place** — copy only the damaged rows back into Production
     from the restored copy. This writes to Production: separate reviewed
     script, separate approval.
5. **Re-enter what happened after the backup**: orders, payments and deliveries
   recorded between the backup time and the incident, from the audit log, the
   damaged dump and paper records.
6. **Validate the database the app now uses.** Both checks are read-only, and
   running them is a separate approved step:
   - **(a)** after a switch-over: the **new project**;
   - **(b)** after a repair in place: **Production**.

   The two checks:
   - `validate_financials.sql`: pass means no `FAIL` rows.
   - `prod_backup_baseline.sql`: its MATCH rows will differ from the backup's
     `baseline_after.txt` by exactly the re-entered records from step 5. Any
     other difference must be explained.

   Record both results. Do not run either check on the old damaged
   Production after a switch-over; step 2's dump is the evidence for it.

Recovery point = time of the last verified backup (take one immediately before
every Production migration). Recovery time = the C.4 duration plus switch-over
and re-entry.

---

## What the drill does not prove
- It restores into plain PostgreSQL, not a running Supabase stack: it does not
  exercise the API layer, Auth sign-in or the website. Restoring into a
  disposable Supabase project (a separate exercise) would.
- Passwords themselves are never checked — only that every `auth.users` row,
  hash included, is byte-identical.
- Supabase-managed schemas are excluded by design; `storage.objects` is
  recorded so its emptiness is verified.

---

## E. Drill record (fill in; contains no data)

| Item | Value |
|---|---|
| Backup timestamp (UTC) / folder | |
| `pg_dump` / `psql` versions | |
| Production server version (baseline) | |
| Part A exit code / bracket A.4.5 result | |
| Dry run date / approved by (checkpoint 1) | |
| Real run approved by (checkpoint 2) | |
| CA sha256 pinned (`-ConfirmCaSha256`) | |
| Script / baseline sha256 (from `run_manifest.txt`) | |
| Dump file size / sha256 | |
| Schema file sha256 | |
| Encrypted copy location | |
| Drill target | local PostgreSQL 17, localhost:54331, `efz_restore_drill` |
| `pg_restore` exit / duration (recovery time) | |
| Error lines and classification | |
| C.5 result (MATCH rows identical: n / n) | |
| C.6 result | |
| Drill database deleted (time) | |
| Performed by / reviewed by | |

---

**Addendum 2026-10-16 - enum checksum:** the baseline's enum row orders labels by the text of a padded sort order, so restores of databases whose enums were extended with ADD VALUE ... AFTER/BEFORE (order_status, order_request_status; Production since Migration 18) legitimately show a different enum checksum. Do not treat that row alone as data loss: compare enum labels in true order with enum_order_check_v1.sql. See ENUM_ORDER_CHECK.md.

