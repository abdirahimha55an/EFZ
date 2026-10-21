# EFZ PRODUCTION - READ-ONLY preflight launcher. The SQL runs inside BEGIN READ ONLY ... ROLLBACK and writes nothing.
# The password is typed by you at psql's own prompt. It is never stored in a variable, file or command line.
$ErrorActionPreference = 'Stop'
$ref  = 'rodmdvfjashiohgwople'
$sql  = Join-Path $PSScriptRoot '..\checks\production_preflight_21_29_READONLY.sql'
Write-Host 'EFZ PRODUCTION - READ-ONLY preflight (changes nothing)' -ForegroundColor Cyan
Write-Host ("SQL sha256: " + (Get-FileHash $sql -Algorithm SHA256).Hash)
$out = 'C:\EFZ-checks\M29_preflight_' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + 'Z'
New-Item -ItemType Directory -Force $out | Out-Null
Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
$env:PGPASSFILE = 'C:\nonexistent-pgpass'   # forces the interactive prompt
$ErrorActionPreference = 'Continue'
Write-Host 'Enter the PRODUCTION database password at the prompt below (nothing is echoed):' -ForegroundColor Yellow
& 'C:\pgsql17\pgsql\bin\psql.exe' "host=aws-1-eu-west-1.pooler.supabase.com port=5432 dbname=postgres user=postgres.$ref sslmode=verify-full sslrootcert=C:/EFZ-certs/production-ca.crt" -W -qAt -v ON_ERROR_STOP=1 -f $sql -o "$out\preflight.txt" 2> "$out\stderr.txt"
$code = $LASTEXITCODE
Remove-Item Env:PGPASSFILE -ErrorAction SilentlyContinue
"exit=$code" | Out-File "$out\exit.txt" -Encoding ascii
Write-Host "exit=$code"
Write-Host "Output folder: $out"
if (Test-Path "$out\preflight.txt") { Get-Content "$out\preflight.txt" | Select-Object -First 1; Get-Content "$out\preflight.txt" | Select-Object -Last 1 }
if ((Get-Item "$out\stderr.txt").Length -gt 0) { Write-Host '--- stderr ---'; Get-Content "$out\stderr.txt" }
Read-Host 'Done. Press Enter to close this window'
