<#
.SYNOPSIS
  EFZ Production backup - Part A of BACKUP_AND_RESTORE_DRILL.md (READS Production only).

.DESCRIPTION
  Takes a read-only baseline of EFZ Production, a pg_dump of the public and auth schemas,
  a readable schema-only copy, a second baseline, and checks that both baselines match
  (the "bracket"). It never writes to any database:
    * pg_dump runs inside a REPEATABLE READ, READ ONLY transaction;
    * prod_backup_baseline.sql runs inside BEGIN READ ONLY ... ROLLBACK.

  Fail-closed rules:
    * any failed guard or check stops the whole script (no step after it runs);
    * the connection must be the Production session pooler as postgres.rodmdvfjashiohgwople;
    * TLS is sslmode=verify-full against the Supabase CA certificate you downloaded from the
      Dashboard. There is NO fallback to a weaker mode: if the certificate is missing, invalid,
      not the one you confirmed, or the server cannot be verified, the script stops and reports
      certificate verification as UNAVAILABLE;
    * the password is typed at a prompt, never written to disk, and removed from the
      environment in a finally block on every exit path; the temporary BSTR is zeroed.

  Run it as a script (not pasted line by line):
    Dry run - local checks only, NO database connection, NO password prompt, writes nothing:
      powershell -NoProfile -ExecutionPolicy Bypass -File .\partA_backup.ps1 -DryRun `
        -PoolerHost aws-0-<region>.pooler.supabase.com -CaCertPath C:\EFZ-certs\prod-ca-2021.crt
    Real run (only with the owner's explicit approval to read Production):
      powershell -NoProfile -ExecutionPolicy Bypass -File .\partA_backup.ps1 `
        -PoolerHost aws-0-<region>.pooler.supabase.com -CaCertPath C:\EFZ-certs\prod-ca-2021.crt `
        -ConfirmCaSha256 <the CA sha256 printed by the dry run>

  Exit codes: 0 = backup taken and bracket OK; 1 = a local guard failed (no connection was made);
              2 = a Production read step failed; 3 = bracket failed (Production changed during the dump).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $PoolerHost,
  [Parameter(Mandatory = $true)] [string] $CaCertPath,
  [string] $ConfirmCaSha256 = '',
  [switch] $DryRun,
  [string] $PgBin      = 'C:\pgsql17\pgsql\bin',
  [string] $Repo       = 'C:\Users\Abdirahim\Desktop\EFZ',
  [string] $BackupRoot = 'C:\EFZ-backups'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------
# Constants: the Production identity. Never edited at run time.
# ---------------------------------------------------------------------------------------------
$PROD_REF    = 'rodmdvfjashiohgwople'
$STAGING_REF = 'adjjamiqwboawqedaapi'
$PROD_USER   = "postgres.$PROD_REF"

function Stop-Guard([string] $Message) {
  Write-Host "STOP (no database connection was made): $Message" -ForegroundColor Red
  exit 1
}
# Inside the Production section: throw, so the catch/finally below always run (credential cleanup)
# before the script exits with code 2.
function Stop-Production([string] $Message) {
  throw "EFZ-STOP: $Message"
}

# Quote one argument for the Windows command line (MSVC rules) so values with spaces survive intact.
function ConvertTo-NativeArg([string] $Arg) {
  if ($Arg -eq '') { return '""' }
  if ($Arg -notmatch '[\s"]') { return $Arg }
  $escaped = [regex]::Replace($Arg, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
  $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
  return '"' + $escaped + '"'
}

# Runs a native program WITHOUT PowerShell touching its stderr: stdout and stderr are captured
# by .NET and written to log files, so pg_dump --verbose progress (stderr) is never treated as an
# error. Success is decided only by the exit code. The child inherits this process's environment.
function Invoke-Native([string] $Exe, [string[]] $ArgList, [string] $StdOutLog, [string] $StdErrLog) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = $Exe
  $psi.Arguments              = (($ArgList | ForEach-Object { ConvertTo-NativeArg $_ }) -join ' ')
  $psi.UseShellExecute        = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow         = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $outTask = $proc.StandardOutput.ReadToEndAsync()
  $errTask = $proc.StandardError.ReadToEndAsync()
  $proc.WaitForExit()
  if ($StdOutLog) { [System.IO.File]::WriteAllText($StdOutLog, $outTask.Result) }
  if ($StdErrLog) { [System.IO.File]::WriteAllText($StdErrLog, $errTask.Result) }
  return $proc.ExitCode
}

function Get-MatchRows([string] $Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  return @(Get-Content -LiteralPath $Path | Where-Object { $_ -match '\|MATCH\|' })
}

# =============================================================================================
# 1. LOCAL GUARDS (dry run and real run). No database connection in this section.
# =============================================================================================
Write-Host '== EFZ Part A - local guards' -ForegroundColor Cyan

# 1.1 Production identity guard: host shape, user, port, never staging.
if ($PoolerHost -notmatch '^aws-\d+-[a-z0-9-]+\.pooler\.supabase\.com$') {
  Stop-Guard "PoolerHost '$PoolerHost' is not a Supabase session-pooler host (aws-N-<region>.pooler.supabase.com)."
}
if (($PoolerHost + $CaCertPath) -match $STAGING_REF) { Stop-Guard 'the EFZ-Staging project reference appears in the inputs.' }

# 1.2 libpq environment overrides that could redirect or alter the connection must be absent.
$pgVars = @('PGHOST','PGHOSTADDR','PGPORT','PGDATABASE','PGUSER','PGPASSWORD','PGPASSFILE','PGSERVICE',
            'PGSERVICEFILE','PGSSLMODE','PGSSLROOTCERT','PGSSLCERT','PGSSLKEY','PGOPTIONS','PGCONNECT_TIMEOUT','PGTARGETSESSIONATTRS')
$setVars = @($pgVars | Where-Object { Test-Path -LiteralPath "Env:$_" })
if ($setVars.Count -gt 0) { Stop-Guard ("these libpq environment variables are set and must be cleared first: " + ($setVars -join ', ')) }

# 1.3 TLS certificate: required, valid, a CA, issued by/for Supabase. No fallback.
if (-not (Test-Path -LiteralPath $CaCertPath -PathType Leaf)) {
  Stop-Guard "CERTIFICATE VERIFICATION UNAVAILABLE: CA file '$CaCertPath' not found. Download it from Supabase Dashboard -> Production project -> Project Settings -> Database -> SSL configuration."
}
if ($CaCertPath -match "'") { Stop-Guard 'CERTIFICATE VERIFICATION UNAVAILABLE: the CA path must not contain a single quote.' }
try {
  $caCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (Resolve-Path -LiteralPath $CaCertPath).Path
} catch {
  Stop-Guard "CERTIFICATE VERIFICATION UNAVAILABLE: '$CaCertPath' is not a readable X.509 certificate ($($_.Exception.Message))."
}
$caSha256 = (Get-FileHash -LiteralPath $CaCertPath -Algorithm SHA256).Hash.ToLower()
$isCa = $false
foreach ($ext in $caCert.Extensions) {
  if ($ext -is [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]) { $isCa = $ext.CertificateAuthority }
}
$now = Get-Date
Write-Host ("   CA subject    : {0}" -f $caCert.Subject)
Write-Host ("   CA issuer     : {0}" -f $caCert.Issuer)
Write-Host ("   CA valid      : {0:u} .. {1:u}" -f $caCert.NotBefore.ToUniversalTime(), $caCert.NotAfter.ToUniversalTime())
Write-Host ("   CA file sha256: {0}" -f $caSha256)
if (-not $isCa)                                             { Stop-Guard 'CERTIFICATE VERIFICATION UNAVAILABLE: the file is not a CA certificate.' }
if ($now -lt $caCert.NotBefore -or $now -gt $caCert.NotAfter) { Stop-Guard 'CERTIFICATE VERIFICATION UNAVAILABLE: the CA certificate is outside its validity period.' }
if ($caCert.Subject -notmatch 'Supabase')                  { Stop-Guard 'CERTIFICATE VERIFICATION UNAVAILABLE: the certificate subject does not name Supabase.' }

# 1.4 Tools and inputs.
$psql   = Join-Path $PgBin 'psql.exe'
$pgDump = Join-Path $PgBin 'pg_dump.exe'
foreach ($exe in @($psql, $pgDump)) { if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { Stop-Guard "tool not found: $exe" } }
$baselineSql = Join-Path $Repo 'supabase\production\prod_backup_baseline.sql'
if (-not (Test-Path -LiteralPath $baselineSql -PathType Leaf)) { Stop-Guard "baseline file not found: $baselineSql" }
$tmpVer = [System.IO.Path]::GetTempFileName()
try {
  [void](Invoke-Native $pgDump @('--version') $tmpVer $null); $pgDumpVersion = (Get-Content -LiteralPath $tmpVer -Raw).Trim()
  [void](Invoke-Native $psql   @('--version') $tmpVer $null); $psqlVersion   = (Get-Content -LiteralPath $tmpVer -Raw).Trim()
} finally { Remove-Item -LiteralPath $tmpVer -Force -ErrorAction SilentlyContinue }
if ($pgDumpVersion -notmatch '\b(1[7-9]|[2-9]\d)\.\d+') { Stop-Guard "pg_dump 17 or newer is required (found: $pgDumpVersion)." }
Write-Host "   pg_dump       : $pgDumpVersion"
Write-Host "   psql          : $psqlVersion"
Write-Host ("   baseline sql  : sha256 {0}" -f (Get-FileHash -LiteralPath $baselineSql -Algorithm SHA256).Hash.ToLower())
Write-Host ("   this script   : sha256 {0}" -f (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLower())

# 1.5 Backup location: outside the repository and outside OneDrive; a new folder per run.
$repoFull = [System.IO.Path]::GetFullPath($Repo).TrimEnd('\') + '\'
$rootFull = [System.IO.Path]::GetFullPath($BackupRoot).TrimEnd('\') + '\'
if ($rootFull.StartsWith($repoFull, [System.StringComparison]::OrdinalIgnoreCase)) { Stop-Guard "BackupRoot must be outside the repository ($Repo)." }
foreach ($od in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
  if ($od -and $rootFull.StartsWith(([System.IO.Path]::GetFullPath($od).TrimEnd('\') + '\'), [System.StringComparison]::OrdinalIgnoreCase)) { Stop-Guard 'BackupRoot must be outside OneDrive.' }
}
$TS = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + 'Z'
$BK = Join-Path $BackupRoot $TS
if (Test-Path -LiteralPath $BK) { Stop-Guard "backup folder already exists: $BK" }

# 1.6 The connection string, built only from validated parts, then the preserved identity guard.
$caForLibpq = ((Resolve-Path -LiteralPath $CaCertPath).Path) -replace '\\', '/'
$PROD = "host=$PoolerHost port=5432 dbname=postgres user=$PROD_USER sslmode=verify-full sslrootcert='$caForLibpq'"
if ($PROD -notmatch 'user=postgres\.rodmdvfjashiohgwople' -or $PROD -notmatch 'pooler\.supabase\.com' -or
    $PROD -match $STAGING_REF -or $PROD -match '<REGION-HOST>' -or $PROD -notmatch 'sslmode=verify-full') {
  Stop-Guard 'the connection string failed the Production identity guard.'
}
Write-Host "   connection    : $PROD   (password not shown; prompted at run time)"
Write-Host "   backup folder : $BK"

if ($DryRun) {
  Write-Host ''
  Write-Host 'DRY RUN COMPLETE: all local guards passed. No database connection was made, no password was requested, nothing was written.' -ForegroundColor Green
  Write-Host "For the real run, pass -ConfirmCaSha256 $caSha256 after checking the CA details above."
  exit 0
}

# Real run: the owner must confirm the exact CA reviewed in the dry run.
if ($ConfirmCaSha256.ToLower() -ne $caSha256) {
  Stop-Guard "CERTIFICATE VERIFICATION UNAVAILABLE: -ConfirmCaSha256 must equal the CA file's sha256 ($caSha256) shown by the dry run."
}

# =============================================================================================
# 2. PRODUCTION READS (real run only). Every failure stops the script; credentials are always
#    removed in the finally block.
# =============================================================================================
New-Item -ItemType Directory -Path $BK | Out-Null
$manifest = Join-Path $BK 'run_manifest.txt'
@(
  "EFZ Part A backup run $TS",
  "connection: $PROD",
  "CA subject: $($caCert.Subject) | CA sha256: $caSha256",
  "pg_dump: $pgDumpVersion",
  "psql: $psqlVersion",
  ("baseline sql sha256: " + (Get-FileHash -LiteralPath $baselineSql -Algorithm SHA256).Hash.ToLower()),
  ("script sha256: " + (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLower())
) | Set-Content -LiteralPath $manifest

$exitCode = 0
$sec  = $null
$bstr = [IntPtr]::Zero
try {
  # 2.0 Credential: typed, held only in this process's environment for the duration of the run.
  $sec = Read-Host 'Production database password' -AsSecureString
  if ($sec.Length -eq 0) { Stop-Production 'empty password.' }
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try {
    $env:PGPASSWORD = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $bstr = [IntPtr]::Zero
  }

  # 2.1 Baseline BEFORE the dump (A.2).
  Write-Host '== A.2 baseline before the dump (read-only)' -ForegroundColor Cyan
  $beforeTxt = Join-Path $BK 'baseline_before.txt'
  $rc = Invoke-Native $psql @('-X', '-q', '-A', '-F', '|', '-v', 'ON_ERROR_STOP=1', '-d', $PROD, '-f', $baselineSql, '-o', $beforeTxt) `
          (Join-Path $BK 'baseline_before.stdout.log') (Join-Path $BK 'baseline_before.stderr.log')
  $before = Get-MatchRows $beforeTxt
  if ($rc -ne 0)          { Stop-Production "baseline (before) failed with exit $rc - see baseline_before.stderr.log. If it mentions SSL/certificate, certificate verification is UNAVAILABLE on this path; nothing was read." }
  if ($before.Count -eq 0) { Stop-Production 'baseline (before) produced no MATCH rows.' }
  Write-Host "   OK: $($before.Count) MATCH rows"

  # 2.2 Backup of public + auth (A.3).
  Write-Host '== A.3 pg_dump public + auth (read-only snapshot)' -ForegroundColor Cyan
  $dumpFile = Join-Path $BK "efz_prod_${TS}_public_auth.dump"
  $rc = Invoke-Native $pgDump @('-d', $PROD, '--format=custom', '--compress=9', '--schema=public', '--schema=auth', '--verbose', '--file', $dumpFile) `
          (Join-Path $BK 'pg_dump_full.stdout.log') (Join-Path $BK 'pg_dump_full.log')
  if ($rc -ne 0) { Stop-Production "pg_dump failed with exit $rc - see pg_dump_full.log." }
  if (-not (Test-Path -LiteralPath $dumpFile) -or (Get-Item -LiteralPath $dumpFile).Length -eq 0) { Stop-Production 'pg_dump reported success but the dump file is missing or empty.' }
  Write-Host ("   OK: {0:N0} bytes" -f (Get-Item -LiteralPath $dumpFile).Length)

  # 2.3 Readable schema-only copy (A.4).
  Write-Host '== A.4 pg_dump schema-only copy of public' -ForegroundColor Cyan
  $schemaFile = Join-Path $BK "efz_prod_${TS}_public_schema.sql"
  $rc = Invoke-Native $pgDump @('-d', $PROD, '--schema-only', '--schema=public', '--file', $schemaFile) `
          (Join-Path $BK 'pg_dump_schema.stdout.log') (Join-Path $BK 'pg_dump_schema.log')
  if ($rc -ne 0) { Stop-Production "schema dump failed with exit $rc - see pg_dump_schema.log." }
  if (-not (Test-Path -LiteralPath $schemaFile) -or (Get-Item -LiteralPath $schemaFile).Length -eq 0) { Stop-Production 'schema dump file is missing or empty.' }
  Write-Host '   OK'

  # 2.4 Baseline AFTER the dump (A.5) and the bracket check.
  Write-Host '== A.5 baseline after the dump (read-only) and bracket check' -ForegroundColor Cyan
  $afterTxt = Join-Path $BK 'baseline_after.txt'
  $rc = Invoke-Native $psql @('-X', '-q', '-A', '-F', '|', '-v', 'ON_ERROR_STOP=1', '-d', $PROD, '-f', $baselineSql, '-o', $afterTxt) `
          (Join-Path $BK 'baseline_after.stdout.log') (Join-Path $BK 'baseline_after.stderr.log')
  $after = Get-MatchRows $afterTxt
  if ($rc -ne 0)         { Stop-Production "baseline (after) failed with exit $rc - see baseline_after.stderr.log. The dump cannot be bracketed; treat it as UNVERIFIED." }
  if ($after.Count -eq 0) { Stop-Production 'baseline (after) produced no MATCH rows. The dump cannot be bracketed; treat it as UNVERIFIED.' }

  $diff = @(Compare-Object -ReferenceObject $before -DifferenceObject $after)
  if ($before.Count -eq $after.Count -and $diff.Count -eq 0) {
    $msg = "BRACKET OK: $($after.Count) MATCH rows identical before and after the dump."
    Write-Host $msg -ForegroundColor Green
    Add-Content -LiteralPath $manifest $msg
  } else {
    $msg = "BRACKET FAILED: before $($before.Count) / after $($after.Count) MATCH rows, $($diff.Count) differing line(s). Production changed during the dump - repeat Part A in a quiet period. This dump is UNVERIFIED."
    Write-Host $msg -ForegroundColor Red
    Add-Content -LiteralPath $manifest $msg
    $diff | Out-File -LiteralPath (Join-Path $BK 'BRACKET_FAILED_diff.txt')
    $exitCode = 3
  }
}
catch {
  $exitCode = 2
  $text = $_.Exception.Message -replace "^EFZ-STOP: ", ""
  Write-Host "STOP: $text" -ForegroundColor Red
  if ($manifest -and (Test-Path -LiteralPath $manifest)) { Add-Content -LiteralPath $manifest "STOPPED: $text" }
}
finally {
  # Guaranteed credential cleanup on every path (success, failure, Ctrl+C).
  Remove-Item -LiteralPath Env:PGPASSWORD -ErrorAction SilentlyContinue
  if ($bstr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  if ($sec) { $sec.Dispose() }
  $sec = $null
  Write-Host 'Credentials removed from this process.'
}

Write-Host ''
if ($exitCode -eq 0) {
  Write-Host "PART A COMPLETE: backup in $BK. Next: Part B (SHA-256 seal) - local files only." -ForegroundColor Green
}
exit $exitCode
