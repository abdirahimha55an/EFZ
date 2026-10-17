# EFZ-STAGING ONLY - guarded deploy of the register-customer Edge Function. Run by the OWNER in their own signed-in terminal.
# It never prints, logs or stores a token, password, service-role key or the salt, and it refuses anything that is not the Staging project.
#
#   .\deploy-staging.ps1                 preflight only: checks everything below, changes NOTHING
#   .\deploy-staging.ps1 -Deploy         preflight, then sets the salt secret if missing, then deploys (--no-verify-jwt)
#   .\deploy-staging.ps1 -Smoke          smoke tests against the deployed Staging function (creates synthetic @example.test accounts on Staging)
#
# Preflight (every item must pass, otherwise it stops before any change):
#   1. Supabase CLI installed;  2. signed in (supabase login) with access to project adjjamiqwboawqedaapi;  3. the project is Staging, never Production;
#   4. Staging Auth sign-up is DISABLED (public settings endpoint);  5. the function files are the tested ones (handler.test.ts passes under Node, if Node is present).
param([switch]$Deploy, [switch]$Smoke, [string]$PublishableKey = $env:EFZ_STAGING_PUBLISHABLE_KEY)
$ErrorActionPreference = 'Stop'
$STAGING = 'adjjamiqwboawqedaapi'; $PRODUCTION = 'rodmdvfjashiohgwople'; $FN = 'register-customer'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here '..\..\..')).Path
function Fail([string]$m) { Write-Host "STOP: $m" -ForegroundColor Red; exit 1 }
function Ok([string]$m) { Write-Host "  OK  $m" -ForegroundColor Green }

if ($PSBoundParameters.Values -contains $PRODUCTION -or ($env:SUPABASE_PROJECT_ID -eq $PRODUCTION)) { Fail 'the Production project ref was supplied. This script is Staging only.' }
$linked = Join-Path $repo 'supabase\.temp\project-ref'
if ((Test-Path $linked) -and ((Get-Content $linked -Raw).Trim() -eq $PRODUCTION)) { Fail 'this checkout is linked to PRODUCTION. Run: supabase unlink, then link Staging.' }

Write-Host "EFZ STAGING - register-customer preflight (project $STAGING)" -ForegroundColor Cyan
$cli = Get-Command supabase -ErrorAction SilentlyContinue
if (-not $cli) { Fail 'Supabase CLI not found. Install it (for example: npm i -g supabase@2.121.0, or the Windows release binary) and run: supabase login' }
Ok ("CLI " + (& supabase --version))

# signed in + access to the Staging project (lists project refs only; the token is never read or printed)
$projects = & supabase projects list 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail 'not signed in to Supabase. Run: supabase login   (interactive; do not paste any token anywhere else)' }
if ($projects -notmatch [regex]::Escape($STAGING)) { Fail "the signed-in account cannot see project $STAGING" }
Ok 'signed in, Staging project visible'

# Staging Auth sign-up must stay disabled
if (-not $PublishableKey) { Fail 'set $env:EFZ_STAGING_PUBLISHABLE_KEY (the PUBLIC publishable key of Staging; it is not a secret) or pass -PublishableKey' }
$s = Invoke-RestMethod -Uri "https://$STAGING.supabase.co/auth/v1/settings" -Headers @{ apikey = $PublishableKey }
if ($s.disable_signup -ne $true) { Fail 'Staging Auth sign-up is ENABLED. Disable it in the Dashboard (Authentication > Sign In / Providers) first. This design needs sign-up OFF.' }
Ok 'Staging Auth sign-up is disabled'

# the tested code
foreach ($f in 'handler.ts', 'index.ts', 'handler.test.ts') { if (-not (Test-Path (Join-Path $here $f))) { Fail "missing $f" } }
if (Get-Command node -ErrorAction SilentlyContinue) {
  Push-Location $repo; try { & node --test (Join-Path $here 'handler.test.ts') *> $null; if ($LASTEXITCODE -ne 0) { Fail 'handler.test.ts fails; not deploying untested code' } } finally { Pop-Location }
  Ok 'handler unit tests pass'
} else { Write-Host '  --  Node not found: unit tests not re-run' -ForegroundColor Yellow }

$names = & supabase secrets list --project-ref $STAGING 2>&1 | Out-String
$hasSalt = $names -match 'REGISTRATION_HINT_SALT'
Write-Host ("  --  secret REGISTRATION_HINT_SALT: " + $(if ($hasSalt) { 'already set' } else { 'NOT set (-Deploy will create it)' }))

if (-not $Deploy -and -not $Smoke) { Write-Host 'Preflight complete. Nothing was changed.' -ForegroundColor Cyan; exit 0 }

if ($Deploy) {
  if (-not $hasSalt) {
    # 32 random bytes, written to a throw-away file readable only by you, handed to the CLI, then deleted. Never printed.
    $bytes = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("efz-salt-" + [guid]::NewGuid().ToString('N') + '.env')
    try {
      Set-Content -LiteralPath $tmp -Value ("REGISTRATION_HINT_SALT=" + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')) -NoNewline
      $acl = Get-Acl $tmp; $acl.SetAccessRuleProtection($true, $false); $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
      $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($env:USERNAME, 'FullControl', 'Allow'))); Set-Acl $tmp $acl
      & supabase secrets set --env-file $tmp --project-ref $STAGING; if ($LASTEXITCODE -ne 0) { Fail 'setting the secret failed' }
    } finally { if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force }; $bytes = $null }
    Ok 'REGISTRATION_HINT_SALT created (value never shown; temp file deleted)'
  }
  Push-Location $repo
  try { & supabase functions deploy $FN --project-ref $STAGING --no-verify-jwt; if ($LASTEXITCODE -ne 0) { Fail 'deploy failed' } } finally { Pop-Location }
  Ok "deployed $FN to Staging"
}

if ($Smoke) {
  $u = "https://$STAGING.supabase.co/functions/v1/$FN"; $tag = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
  function Call([string]$label, [string]$method, $body, [int]$expect) {
    try { $r = Invoke-WebRequest -Uri $u -Method $method -ContentType 'application/json' -Body $body -UseBasicParsing -ErrorAction Stop; $code = [int]$r.StatusCode; $text = $r.Content }
    catch { $code = [int]$_.Exception.Response.StatusCode; $text = '' }
    $mark = if ($code -eq $expect) { 'PASS' } else { 'FAIL' }; Write-Host ("  {0}  {1} -> HTTP {2} (expected {3})" -f $mark, $label, $code, $expect) -ForegroundColor $(if ($code -eq $expect) { 'Green' } else { 'Red' }); return $text
  }
  $good = @{ email = "e2e-reg-$tag@example.test"; password = 'a long enough pass'; fullName = 'E2E Reg One'; phone = '069 700 0001' } | ConvertTo-Json
  $a = Call 'valid registration' 'POST' $good 202
  $b = Call 'same request again' 'POST' $good 202
  Write-Host ("  {0}  second response is identical to the first" -f $(if ($a -eq $b) { 'PASS' } else { 'FAIL' }))
  Call 'invalid phone' 'POST' (@{ email = "e2e-bad-$tag@example.test"; password = 'a long enough pass'; fullName = 'E2E Bad'; phone = '12345' } | ConvertTo-Json) 422 | Out-Null
  Call 'short password' 'POST' (@{ email = "e2e-pw-$tag@example.test"; password = 'short'; fullName = 'E2E Pw'; phone = '069 700 0002' } | ConvertTo-Json) 422 | Out-Null
  Call 'GET is refused' 'GET' $null 405 | Out-Null
  Write-Host 'Now verify in the database (read-only): one pending customer_accounts row for the email above, one registered event, and NO profiles row for it.' -ForegroundColor Cyan
}
