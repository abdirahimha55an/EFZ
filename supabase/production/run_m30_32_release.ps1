<#
.SYNOPSIS
  EFZ PRODUCTION - owner-run launcher for migrations 30, 31, 32 and the inquiry signing secret. NOT run by Claude. Prepared 2026-11-10, never executed.
.DESCRIPTION
  -Step Preflight   read-only (m30_32_preflight_READONLY.sql). No change.
  -Step Apply       applies 30, then 31, then 32, one file per transaction (ON_ERROR_STOP, lock_timeout is inside each file). Gates: -ReleaseCommit equals HEAD of a
                    clean checkout, -BackupDir is a sealed backup (SHA256SUMS.txt, BRACKET OK) made <= 24 h ago, every file's bytes (CR removed) match the pinned SHA-256.
                    Stops at the first failure; a failed file is rolled back as a whole.
  -Step Secret      generates a 64-hex-character secret in memory, stores it in public.inquiry_signing_secret (only if the table is empty) and copies it to the
                    CLIPBOARD for Vercel (Production scope, Sensitive). It is never printed, never written to a file, never on a command line.
  -Step PostCheck   read-only (m30_32_postcheck_READONLY.sql). Every verdict must be OK.
  The Production database password is typed at psql's own prompt each time (nothing is stored). Close every other EFZ tab/client first.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [ValidateSet('Preflight', 'Apply', 'Secret', 'PostCheck')] [string] $Step,
  [string] $ReleaseCommit = '',
  [string] $BackupDir = '',
  [string] $PgBin = 'C:\pgsql17\pgsql\bin',
  [string] $OutRoot = 'C:\EFZ-checks\M30_32_release'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Stop-Guard([string] $m) { Write-Host "STOP: $m" -ForegroundColor Red; exit 1 }

$ref  = 'rodmdvfjashiohgwople'                       # PRODUCTION (Staging is adjjamiqwboawqedaapi and is refused by the preflight)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sup  = (Resolve-Path (Join-Path $here '..')).Path
$psql = Join-Path $PgBin 'psql.exe'
if (-not (Test-Path $psql)) { Stop-Guard "psql not found at $psql" }
$conn = "host=aws-1-eu-west-1.pooler.supabase.com port=5432 dbname=postgres user=postgres.$ref sslmode=verify-full sslrootcert=C:/EFZ-certs/production-ca.crt"
$out  = Join-Path $OutRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + "Z_$Step")
New-Item -ItemType Directory -Force $out | Out-Null

# SHA-256 of each file with carriage returns removed (the committed LF form). Computed from `git show <commit>:<path> | sha256sum`.
$pinned = [ordered]@{
  '30_public_inquiries.sql'      = '1b69bd0f46bb2f89b479a65d7fd478c455d5fbc0dfd06cb6eebec66d45cba498'
  '31_inquiry_rate_limits.sql'   = '1024fb5dd8aecd8f40dfc18521c8cc6e4dce55b7821a6b63b9a1ac35d06f115c'
  '32_order_designs.sql'         = '335d314069554a4768ceb6e79915091cbdf959fe78d25caa2aa9d819f1260afb'
}
function Get-LfBytes([string] $path) { $b = [IO.File]::ReadAllBytes($path); $l = New-Object 'System.Collections.Generic.List[byte]'; foreach ($x in $b) { if ($x -ne 13) { $l.Add($x) } }; ,$l.ToArray() }
function Get-Sha([byte[]] $bytes) { ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', '').ToLower() }

function Invoke-Psql([string[]] $extra) {
  Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
  $env:PGPASSFILE = 'C:\nonexistent-pgpass'              # forces the interactive password prompt
  Write-Host 'Enter the PRODUCTION database password at the prompt (nothing is echoed):' -ForegroundColor Yellow
  $ErrorActionPreference = 'Continue'
  & $psql $conn -W -v ON_ERROR_STOP=1 @extra
  $code = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  Remove-Item Env:PGPASSFILE -ErrorAction SilentlyContinue
  return $code
}

switch ($Step) {
  'Preflight' {
    $f = Join-Path $here 'm30_32_preflight_READONLY.sql'
    $code = Invoke-Psql @('-q', '-f', $f, '-o', "$out\preflight.txt")
    Write-Host "exit=$code  output: $out\preflight.txt"; if (Test-Path "$out\preflight.txt") { Get-Content "$out\preflight.txt" }
    Write-Host 'Every verdict must say OK. Anything else: STOP and send the output.' -ForegroundColor Cyan
  }
  'PostCheck' {
    $f = Join-Path $here 'm30_32_postcheck_READONLY.sql'
    $code = Invoke-Psql @('-q', '-f', $f, '-o', "$out\postcheck.txt")
    Write-Host "exit=$code  output: $out\postcheck.txt"; if (Test-Path "$out\postcheck.txt") { Get-Content "$out\postcheck.txt" }
  }
  'Apply' {
    if ($ReleaseCommit -notmatch '^[0-9a-f]{40}$') { Stop-Guard '-ReleaseCommit must be the full 40-character sha' }
    $head = (& git -C $sup rev-parse HEAD).Trim()
    if ($head -ne $ReleaseCommit) { Stop-Guard "HEAD is $head, not the release commit" }
    if (& git -C $sup status --porcelain) { Stop-Guard 'working tree is not clean' }
    if (-not $BackupDir -or -not (Test-Path (Join-Path $BackupDir 'SHA256SUMS.txt'))) { Stop-Guard 'BackupDir is missing or not sealed (no SHA256SUMS.txt)' }
    if (-not (Select-String (Join-Path $BackupDir 'run_manifest.txt') -Pattern '^BRACKET OK' -Quiet)) { Stop-Guard 'backup has no BRACKET OK' }
    if (((Get-Date) - (Get-Item (Join-Path $BackupDir 'SHA256SUMS.txt')).LastWriteTime).TotalHours -gt 24) { Stop-Guard 'backup is older than 24 hours' }
    $ready = @()
    foreach ($name in $pinned.Keys) {
      $bytes = Get-LfBytes (Join-Path $sup $name)
      if ((Get-Sha $bytes) -ne $pinned[$name]) { Stop-Guard "$name does not match the pinned SHA-256" }
      $tmp = Join-Path $out $name; [IO.File]::WriteAllBytes($tmp, $bytes); $ready += $tmp   # exactly the verified bytes are what psql runs
    }
    Write-Host "Gates passed. Applying 30, 31, 32 to PRODUCTION ($ref). Last chance: Ctrl+C now." -ForegroundColor Yellow
    Read-Host 'Press Enter to continue'
    foreach ($f in $ready) {
      Write-Host "--- applying $(Split-Path $f -Leaf)" -ForegroundColor Cyan
      $code = Invoke-Psql @('--single-transaction', '-f', $f, '-o', "$f.out.txt")
      Get-Content "$f.out.txt" -ErrorAction SilentlyContinue
      if ($code -ne 0) { Write-Host "STOPPED at $(Split-Path $f -Leaf), exit=$code. That file was rolled back as a whole; earlier files stay applied." -ForegroundColor Red; exit 2 }
    }
    Write-Host "Applied 30, 31, 32. Next: -Step Secret, set INQUIRY_HMAC_SECRET in Vercel, then -Step PostCheck. Logs: $out" -ForegroundColor Green
  }
  'Secret' {
    $bytes = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $secret = ([BitConverter]::ToString($bytes) -replace '-', '').ToLower()
    $sql = "do `$d`$ begin if exists (select 1 from public.inquiry_signing_secret) then raise exception 'a secret is already stored - refusing'; end if; insert into public.inquiry_signing_secret (secret) values ('$secret'); end `$d`$;"
    $sql | & $psql $conn -W -q -v ON_ERROR_STOP=1 -f - 2> "$out\stderr.txt"
    if ($LASTEXITCODE -ne 0) { Get-Content "$out\stderr.txt"; Stop-Guard 'the secret was NOT stored (see message); the clipboard was not touched' }
    Set-Clipboard -Value $secret
    Remove-Variable secret, sql, bytes
    Write-Host 'Secret stored in the Production database and copied to the clipboard (not shown).' -ForegroundColor Green
    Write-Host 'Now: Vercel > efz > Settings > Environment Variables > add INQUIRY_HMAC_SECRET, scope PRODUCTION only, Sensitive ON, paste (Ctrl+V). Then run: Set-Clipboard -Value $null' -ForegroundColor Yellow
  }
}
Read-Host 'Done. Press Enter to close'
