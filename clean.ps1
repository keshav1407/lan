# ==============================================================================
# clean.ps1 - LAN Dynamic Wallpaper Reset & Cleanup Utility
# ==============================================================================
[CmdletBinding()]
param()

$root = $PSScriptRoot

Write-Host "Cleaning LAN Dynamic Wallpaper temporary cache and logs..." -ForegroundColor Cyan

# 1. Stop any running background client/host powershell processes if running
Get-Process powershell, pwsh -ErrorAction SilentlyContinue | Where-Object {
    $_.MainWindowTitle -like "*LAN Dynamic Wallpaper*"
} | Stop-Process -Force -ErrorAction SilentlyContinue

# 2. Clear client image cache
$cacheDir = Join-Path $root "Cache"
if (Test-Path -LiteralPath $cacheDir) {
    Remove-Item (Join-Path $cacheDir "*") -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  [OK] Client Cache cleared." -ForegroundColor Green
}

# 3. Clear logs
$logsDir = Join-Path $root "Logs"
if (Test-Path -LiteralPath $logsDir) {
    Remove-Item (Join-Path $logsDir "*") -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  [OK] Logs cleared." -ForegroundColor Green
}

Write-Host "Cleanup completed successfully." -ForegroundColor Green
