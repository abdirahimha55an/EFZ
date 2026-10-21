<#
.SYNOPSIS
  EFZ release window for the migrations 19-29e. Run by the OWNER in a separate PowerShell window. Phase A = 19, 19b, 21-28, 29a, 29b*, 29c, 29d (before the Hub deploy).
  Phase C = 29e* (only after the matching Hub release is live and smoke-tested). Order and files come from release_manifest.json (SHA-256 pinned).
.DESCRIPTION
  -DryRun            local checks only: manifest hashes, release commit, backup folder. No connection, no password.
  (default)          the real window against PRODUCTION: password is prompted by psql/Read-Host, never stored; TLS verify-full with the pinned CA;
                     per file: not-yet-applied marker -> psql --single-transaction (lock_timeout 30s, ON_ERROR_STOP) -> applied marker -> attempt marker. Stops at the first problem.
  -Target Local      REHEARSAL on a throw-away local database whose name starts with m29_ (127.0.0.1, any -LocalPort). Never reaches Production.
  Gates for a Production run: -ReleaseCommit <full sha> must equal HEAD of this clean checkout; -BackupDir C:\EFZ-backups\<ts> must be sealed, BRACKET OK and <= 24 h old;
  -Phase C additionally needs -HubConfirmed "HUB <first 7 of ReleaseCommit> IS LIVE AND SMOKE TESTED".
  Exit codes: 0 done; 1 guard failed before any change; 2 a step failed (nothing from that step is committed).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [ValidateSet('A', 'C')] [string] $Phase,
  [string] $ReleaseCommit = '',
  [string] $BackupDir = '',
  [string] $HubConfirmed = '',
  [ValidateSet('Production', 'Local')] [string] $Target = 'Production',
  [int] $LocalPort = 54451, [string] $LocalDb = 'm29_rel',
  [switch] $DryRun,
  [string] $PgBin = 'C:\pgsql17\pgsql\bin', [string] $OutRoot = 'C:\EFZ-checks\M29_release'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Stop-Guard([string] $m) { Write-Host "STOP: $m" -ForegroundColor Red; exit 1 }
function Say([string] $m) { Write-Host $m; if ($script:logFile) { $m | Out-File $script:logFile -Append -Encoding utf8 } }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here '..\..')).Path
$sup = Join-Path $repo 'supabase'
$manifest = Get-Content (Join-Path $here 'release_manifest.json') -Raw | ConvertFrom-Json
$steps = @($manifest.phases.$Phase)
$psql = Join-Path $PgBin 'psql.exe'
if (-not (Test-Path $psql)) { Stop-Guard "psql not found at $psql" }

# 1. every file is the pinned one (bytes as stored; LF only)
foreach ($s in $steps) {
  $p = Join-Path $sup ($s.file -replace '/', '\')
  if (-not (Test-Path $p)) { Stop-Guard "missing file $($s.file)" }
  if ((Get-FileHash $p -Algorithm SHA256).Hash.ToLower() -ne $s.sha256) { Stop-Guard "$($s.file) differs from release_manifest.json (hash pin)" }
}
Write-Host "OK  $($steps.Count) file hashes match release_manifest.json (phase $Phase)"

if ($Target -eq 'Production') {
  # 2. release commit
  $head = (git -C $repo rev-parse HEAD).Trim(); $dirty = @(git -C $repo status --porcelain).Count
  if ($ReleaseCommit.Length -ne 40 -or $head -ne $ReleaseCommit) { Stop-Guard "-ReleaseCommit must be the full 40-char HEAD of this checkout (HEAD is $head)" }
  if ($dirty -ne 0) { Stop-Guard "the release checkout is not clean ($dirty changes)" }
  Write-Host "OK  release commit $($head.Substring(0,7)), tree clean"
  # 3. sealed, fresh backup
  if ($BackupDir -notmatch '\\EFZ-backups\\\d{8}-\d{6}Z$' -or -not (Test-Path $BackupDir)) { Stop-Guard '-BackupDir C:\EFZ-backups\<timestamp> is required' }
  $ts = Split-Path $BackupDir -Leaf
  $t = [datetime]::ParseExact($ts, 'yyyyMMdd-HHmmss"Z"', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
  if (((Get-Date).ToUniversalTime() - $t).TotalHours -gt 24) { Stop-Guard "backup $ts is older than 24 h; take a fresh one (run_backup_and_seal.ps1)" }
  $sums = Join-Path $BackupDir 'SHA256SUMS.txt'; if (-not (Test-Path $sums)) { Stop-Guard 'backup is not sealed (no SHA256SUMS.txt)' }
  $bad = @(); $listed = @{}
  foreach ($l in Get-Content $sums) { $h, $f = $l -split '  ', 2; $listed[$f] = 1; $q = Join-Path $BackupDir $f
    if (-not (Test-Path $q)) { $bad += "missing $f" } elseif ((Get-FileHash $q -Algorithm SHA256).Hash.ToLower() -ne $h) { $bad += "mismatch $f" } }
  foreach ($f in Get-ChildItem $BackupDir -File) { if ($f.Name -ne 'SHA256SUMS.txt' -and -not $listed.ContainsKey($f.Name)) { $bad += "unlisted $($f.Name)" } }
  if ($bad.Count) { Stop-Guard ('backup seal problem: ' + ($bad -join ', ')) }
  if (-not (Select-String (Join-Path $BackupDir 'run_manifest.txt') -Pattern '^BRACKET OK' -Quiet)) { Stop-Guard 'backup has no BRACKET OK' }
  Write-Host "OK  backup $ts sealed ($($listed.Count) files), BRACKET OK, fresh"
  if ($Phase -eq 'C' -and $HubConfirmed -ne "HUB $($head.Substring(0,7)) IS LIVE AND SMOKE TESTED") { Stop-Guard "phase C needs -HubConfirmed ""HUB $($head.Substring(0,7)) IS LIVE AND SMOKE TESTED"" (after the Hub deploy and smoke test)" }
  $ca = 'C:\EFZ-certs\production-ca.crt'
  if ((Get-FileHash $ca -Algorithm SHA256).Hash.ToLower() -ne '700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7') { Stop-Guard 'CA certificate differs from the confirmed Supabase Root 2021 CA' }
  $conn = "host=aws-1-eu-west-1.pooler.supabase.com port=5432 dbname=postgres user=postgres.rodmdvfjashiohgwople sslmode=verify-full sslrootcert='C:/EFZ-certs/production-ca.crt'"
} else {
  if ($LocalDb -notmatch '^m29_') { Stop-Guard 'a Local rehearsal database name must start with m29_' }
  $conn = "host=127.0.0.1 port=$LocalPort dbname=$LocalDb user=postgres"
}
if ($DryRun) { Write-Host "DRY RUN COMPLETE ($Target, phase $Phase): all local guards passed. No connection, no password, nothing written."; exit 0 }

$out = Join-Path $OutRoot ("{0}_{1}_{2}Z" -f $Target, $Phase, (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $out | Out-Null
$script:logFile = Join-Path $out 'status.txt'
$ErrorActionPreference = 'Continue'
try {
  if ($Target -eq 'Production') {
    $env:PGPASSFILE = 'C:\nonexistent-pgpass'; Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    $sec = Read-Host -AsSecureString 'PRODUCTION database password'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr); [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $id = (& $psql -X -qAt -d $conn -c 'select current_database()||''|''||current_user' 2> "$out\identity.err")
    if ($LASTEXITCODE -ne 0 -or ([string]$id).Trim() -ne 'postgres|postgres') { throw "identity check failed: $id" }
    $mk = (& $psql -X -qAt -d $conn -c "select exists(select 1 from information_schema.columns where table_schema='public' and table_name='orders' and column_name='payment_terms') and to_regclass('public.order_deliveries') is not null")
    if (([string]$mk).Trim() -ne 't') { throw 'this is not the expected EFZ Production schema (migration 20 markers missing)' }
    Say "connected (verify-full), identity postgres, Production schema markers OK"
  }
  foreach ($s in $steps) {
    $file = Join-Path $sup ($s.file -replace '/', '\'); $name = Split-Path $s.file -Leaf
    $attempt = Join-Path $OutRoot "ATTEMPT_${Target}_$name.txt"
    if (Test-Path $attempt) { throw "an attempt marker exists for $name ($attempt): review it; never re-run blindly" }
    if ($s.post_is_unique) {
      $already = (& $psql -X -qAt -d $conn -c "select ($($s.post))" 2>> "$out\markers.err"); if (([string]$already).Trim() -eq 't') { throw "$name already looks applied (post marker true); stopping" }
    }
    "attempt $(Get-Date -Format o) $name" | Out-File $attempt -Encoding ascii
    Say "APPLYING $name (single transaction, lock_timeout 30s)"
    & $psql -X -q -d $conn -v ON_ERROR_STOP=1 --single-transaction -c "set local lock_timeout='30s'" -f $file > "$out\apply_$name.out" 2> "$out\apply_$name.err"
    if ($LASTEXITCODE -ne 0) { Say "FAILED $name (exit $LASTEXITCODE): $(Select-String -Path "$out\apply_$name.err" -Pattern 'ERROR' -List | ForEach-Object { $_.Line })"; throw "step $name failed; the transaction was rolled back" }
    if ($s.post_is_unique) {
      $now = (& $psql -X -qAt -d $conn -c "select ($($s.post))" 2>> "$out\markers.err"); if (([string]$now).Trim() -ne 't') { throw "$name ran but its post marker is not true" }
    }
    Say "DONE     $name (post marker $(if ($s.post_is_unique) { 'true' } else { 'n/a' }))"
  }
  $pre = Join-Path $here '..\checks\production_preflight_21_29_READONLY.sql'
  & $psql -X -qAt -d $conn -v ON_ERROR_STOP=1 -f $pre -o "$out\post_preflight.txt" 2> "$out\post_preflight.err"
  Say "post-phase read-only preflight exit $LASTEXITCODE -> $out\post_preflight.txt"
  Say "PHASE $Phase COMPLETE"
  exit 0
} catch {
  Say "ABORTED: $($_.Exception.Message)"; exit 2
} finally {
  Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue; Remove-Item Env:PGPASSFILE -ErrorAction SilentlyContinue
}
