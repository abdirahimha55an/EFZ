# PRODUCTION deploy of the register-customer Edge Function. DEFAULT = read-only preflight (changes nothing). -Deploy needs -ConfirmProduction with the exact phrase and the owner's explicit approval.
# Derived from deploy-staging.ps1 (secrets are generated locally and never printed). Refuses Staging. No smoke test here: run it by hand with an invented address, then clean up per the release checklist.
# Usage (owner terminal): .deploy-production.ps1  = preflight only;  .deploy-production.ps1 -Deploy -ConfirmProduction "DEPLOY register-customer TO PRODUCTION"  = set the salt secret if missing, then deploy (--no-verify-jwt).
# Preflight: CLI installed, signed in with access to the Production project, checkout not linked to Staging, Production Auth sign-up DISABLED, tested function files.
param([switch]$Deploy, [string]$ConfirmProduction = "", [string]$PublishableKey = $env:EFZ_PRODUCTION_PUBLISHABLE_KEY)
$ErrorActionPreference = 'Stop'
$TARGET = 'rodmdvfjashiohgwople'; $STAGING = 'adjjamiqwboawqedaapi'; $FN = 'register-customer'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here '..\..\..')).Path
function Fail([string]$m) { Write-Host "STOP: $m" -ForegroundColor Red; exit 1 }
function Ok([string]$m) { Write-Host "  OK  $m" -ForegroundColor Green }

if ($env:SUPABASE_PROJECT_ID -eq $STAGING) { Fail 'SUPABASE_PROJECT_ID is Staging. This script is Production only.' }
if ($Deploy -and $ConfirmProduction -ne 'DEPLOY register-customer TO PRODUCTION') { Fail '-Deploy needs -ConfirmProduction "DEPLOY register-customer TO PRODUCTION" (explicit owner approval).' }
$linked = Join-Path $repo 'supabase.tempproject-ref'
if ((Test-Path $linked) -and ((Get-Content $linked -Raw).Trim() -eq $STAGING)) { Fail 'this checkout is linked to STAGING. Run: supabase unlink, then link Production deliberately.' }

Write-Host "EFZ PRODUCTION - register-customer preflight (project $TARGET)" -ForegroundColor Cyan
$cli = Get-Command supabase -ErrorAction SilentlyContinue
if (-not $cli) { Fail 'Supabase CLI not found. Install it (for example: npm i -g supabase@2.121.0, or the Windows release binary) and run: supabase login' }
Ok ("CLI " + (& supabase --version))

# signed in + access to the Production project (lists project refs only; the token is never read or printed)
$ErrorActionPreference = 'Continue'   # the CLI writes harmless notes to stderr; Windows PowerShell 5.1 would turn them into errors
$projects = & supabase projects list --agent no --output-format text 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail 'not signed in to Supabase. Run: supabase login   (interactive; do not paste any token anywhere else)' }
if ($projects -notmatch [regex]::Escape($TARGET)) { Fail "the signed-in account cannot see project $TARGET" }
Ok 'signed in, Production project visible'

# Production Auth sign-up must stay disabled
if (-not $PublishableKey) { Fail 'set $env:EFZ_PRODUCTION_PUBLISHABLE_KEY (the PUBLIC publishable key of Production; not a secret) or pass -PublishableKey' }
$s = Invoke-RestMethod -Uri "https://$TARGET.supabase.co/auth/v1/settings" -Headers @{ apikey = $PublishableKey }
if ($s.disable_signup -ne $true) { Fail 'Production Auth sign-up is ENABLED. Disable it in the Dashboard (Authentication > Sign In / Providers) first. This design needs sign-up OFF.' }
Ok 'Production Auth sign-up is disabled'

# the tested code
foreach ($f in 'handler.ts', 'index.ts', 'handler.test.ts') { if (-not (Test-Path (Join-Path $here $f))) { Fail "missing $f" } }
if (Get-Command node -ErrorAction SilentlyContinue) {
  Push-Location $repo; try { & node --test (Join-Path $here 'handler.test.ts') *> $null; if ($LASTEXITCODE -ne 0) { Fail 'handler.test.ts fails; not deploying untested code' } } finally { Pop-Location }
  Ok 'handler unit tests pass'
} else { Write-Host '  --  Node not found: unit tests not re-run' -ForegroundColor Yellow }

$names = & supabase secrets list --project-ref $TARGET --agent no --output-format text 2>&1 | Out-String; $secretsExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($secretsExit -ne 0) { Fail 'could not list secrets (names only) on Production' }
$hasSalt = $names -match 'REGISTRATION_HINT_SALT'
Write-Host ("  --  secret REGISTRATION_HINT_SALT: " + $(if ($hasSalt) { 'already set' } else { 'NOT set (-Deploy will create it)' }))

if (-not $Deploy) { Write-Host 'Preflight complete. Nothing was changed.' -ForegroundColor Cyan; exit 0 }

if ($Deploy) {
  if (-not $hasSalt) {
    # 32 random bytes, written to a throw-away file readable only by you, handed to the CLI, then deleted. Never printed.
    $bytes = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("efz-salt-" + [guid]::NewGuid().ToString('N') + '.env')
    try {
      Set-Content -LiteralPath $tmp -Value ("REGISTRATION_HINT_SALT=" + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')) -NoNewline
      $acl = Get-Acl $tmp; $acl.SetAccessRuleProtection($true, $false); $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
      $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'Allow'))); Set-Acl $tmp $acl
      $ErrorActionPreference = 'Continue'; & supabase secrets set --env-file $tmp --project-ref $TARGET --agent no --output-format text; $ErrorActionPreference = 'Stop'; if ($LASTEXITCODE -ne 0) { Fail 'setting the secret failed' }
    } finally { if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force }; $bytes = $null }
    Ok 'REGISTRATION_HINT_SALT created (value never shown; temp file deleted)'
  }
  Push-Location $repo
  try { $ErrorActionPreference = 'Continue'; & supabase functions deploy $FN --project-ref $TARGET --no-verify-jwt --agent no --output-format text; $ErrorActionPreference = 'Stop'; if ($LASTEXITCODE -ne 0) { Fail 'deploy failed' } } finally { Pop-Location }
  Ok "deployed $FN to Production"
}

