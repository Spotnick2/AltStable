<#
    deploy-probe.ps1 — Deploy the throwaway AltStableProbe addon to the Forever beta client.

    The probe answers the open API-contract questions for the port (see
    Tools/AltStableProbe/Probe.lua). It is never packaged — it lives under
    Tools/, which .pkgmeta ignores.

    Usage:
        pwsh Tools/deploy-probe.ps1
        pwsh Tools/deploy-probe.ps1 -AddOnsPath "D:\Games\WoW\_classic_beta_\Interface\AddOns"
#>

param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$src = Join-Path $RepoRoot "Tools\AltStableProbe"

if (-not (Test-Path $AddOnsPath)) {
    Write-Error "AddOns path not found: $AddOnsPath"
    exit 1
}

$dest = Join-Path $AddOnsPath "AltStableProbe"
Write-Host "Deploying AltStableProbe ..." -ForegroundColor Cyan

# /MIR: we own this folder wholesale, so stale files get purged.
# SavedVariables live in WTF\, not here, so purging is safe.
# robocopy exit codes 0-7 are success; 8+ is an error.
robocopy $src $dest /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) {
    Write-Error "robocopy failed (code $LASTEXITCODE)"
    exit 1
}

Write-Host "Done -> $dest" -ForegroundColor Green
Write-Host ""
Write-Host "In-game:" -ForegroundColor Yellow
Write-Host "  /console scriptErrors 1   (errors are OFF by default on this client)"
Write-Host "  /reload"
Write-Host "  /asprobe                  run every section"
Write-Host "  /asprobe bank             re-run containers with the BANK WINDOW OPEN"
Write-Host "  /asprobe whisper <Name>   cross-account ping (log the other account in first)"
Write-Host ""
Write-Host "Results are written to AltStableProbeDB on logout or /reload:"
Write-Host "  ...\_classic_beta_\WTF\Account\<id>\SavedVariables\AltStableProbe.lua"
