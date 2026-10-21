# EFZ PRODUCTION - Part A backup (READS Production only; the script runs read-only transactions) + Part B seal. Password is typed at the prompt by Part A.
$ErrorActionPreference = 'Stop'
$PG = 'C:\pgsql17\pgsql\bin'; $root = 'C:\EFZ-backups'
$before = @(Get-ChildItem $root -Directory | Select -Expand Name)
Write-Host 'EFZ PRODUCTION backup (read-only on Production). Enter the Production database password when asked.' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'partA_backup.ps1') -PoolerHost aws-1-eu-west-1.pooler.supabase.com -CaCertPath C:\EFZ-certs\production-ca.crt -ConfirmCaSha256 700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7
$code = $LASTEXITCODE; Write-Host "partA exit=$code"
if ($code -ne 0) { Read-Host 'Part A did not complete. Press Enter to close'; exit $code }
$BK = (Get-ChildItem $root -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}Z$' -and $before -notcontains $_.Name } | Sort-Object Name | Select -Last 1).FullName
$TS = Split-Path $BK -Leaf
if (-not (Test-Path "$BK\efz_prod_${TS}_public_auth.dump")) { throw 'wrong folder' }
if (-not (Select-String "$BK\run_manifest.txt" -Pattern '^BRACKET OK' -Quiet)) { throw 'no BRACKET OK' }
& "$PG\pg_restore.exe" --list "$BK\efz_prod_${TS}_public_auth.dump" > "$BK\dump_toc.txt"
$sums = Join-Path $BK 'SHA256SUMS.txt'
if (Test-Path -LiteralPath $sums) { throw 'already sealed' }
Get-ChildItem -LiteralPath $BK -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | Sort-Object Name |
  ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name } | Set-Content -LiteralPath $sums
$listed=@{}; $bad=@(Get-Content -LiteralPath $sums | ForEach-Object { $h,$f = $_ -split '  ',2; $listed[$f]=$true; if ((Get-FileHash -LiteralPath (Join-Path $BK $f) -Algorithm SHA256).Hash.ToLower() -ne $h) { "MISMATCH: $f" } })
if ($bad.Count) { $bad } else { "SEALED: all $($listed.Count) checksums OK" }
$BK | Out-File 'C:\EFZ-backups\_last_backup_path.txt' -Encoding ascii
Write-Host "BACKUP FOLDER: $BK"; Read-Host 'Done. Press Enter to close'
