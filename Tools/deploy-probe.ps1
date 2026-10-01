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

# /MIR: we own these folders wholesale, so stale files get purged.
# SavedVariables live in WTF\, not here, so purging is safe.
# robocopy exit codes 0-7 are success; 8+ is an error.
# (AltStableDevConfig is retired: it seeded a whitelist from code while #23 kept
# settings from loading, and after the fix only overwrote the player's own.)
foreach ($name in @("AltStableProbe", "ForeverAPIDump")) {
    $from = Join-Path $RepoRoot "Tools\$name"
    if (-not (Test-Path $from)) { continue }
    $to = Join-Path $AddOnsPath $name
    Write-Host "Deploying $name ..." -ForegroundColor Cyan
    robocopy $from $to /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $name (code $LASTEXITCODE)" }
    $dest = $to
}

# Retired tools: remove what an older run installed, or it keeps loading - the
# retired AltStableDevConfig re-seeded a whitelist the player had emptied
# (review of #141). Only these exact folders, and it says so.
foreach ($retired in @("AltStableDevConfig")) {
    $old = Join-Path $AddOnsPath $retired
    if (Test-Path -LiteralPath $old) {
        Remove-Item -LiteralPath $old -Recurse -Force
        Write-Host "Removed retired $retired from AddOns" -ForegroundColor DarkYellow
    }
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
