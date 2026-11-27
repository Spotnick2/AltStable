<#
    deploy-probe.ps1 — Deploy the throwaway AltStableProbe addon to the Forever client, on demand.

    The probe answers the open API-contract questions for the port (see
    Tools/AltStableProbe/Probe.lua). It is never packaged — it lives under
    Tools/, which .pkgmeta ignores.

    AltStableProbe is a ForeverProbe module (#240): it has
    ## Dependencies: ForeverProbe. ForeverProbe's own deploy.ps1 -Module (#549,
    ForeverProbe#47) deploys the host first, then the module: it refuses a
    module whose TOC doesn't depend on ForeverProbe, a listed file missing or
    outside the folder, or a luac -p failure, and then copies nothing, the host
    included. It stamps the copy's TOC with the commit (## X-FP-Commit), lints
    the module's globals (warnings only) and removes files it no longer lists.
    The checkout is $env:FOREVERPROBE, else ..\ForeverProbe.

    Usage:
        pwsh Tools/deploy-probe.ps1
        pwsh Tools/deploy-probe.ps1 -AddOnsPath "D:\Games\WoW\_forever_\Interface\AddOns"
        pwsh Tools/deploy-probe.ps1 -Remove

    The client is the live one now (_forever_, the owner's own install), so the
    dev tools go in only when a question needs them and come out after:
    -Remove deletes AltStableProbe, and the ForeverProbe host too unless another
    project's probe still depends on it. Their saved logs in WTF\ stay.
    restore-release.ps1 runs -Remove as well.

    The API dump addon is not ours any more: it is shared, in
    C:\Projects\WoW\References\Tools\ForeverAPIDump, with its own deploy.ps1
    (the forever-api-dump skill). -Remove still deletes a ForeverAPIDump folder,
    so one that an older run of this script installed comes out too.
#>

param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns",
    [switch]$Remove
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ForeverProbe = if ($env:FOREVERPROBE) { $env:FOREVERPROBE } else { Join-Path (Split-Path -Parent $RepoRoot) "ForeverProbe" }

if (-not (Test-Path $AddOnsPath)) {
    Write-Error "AddOns path not found: $AddOnsPath"
    exit 1
}

if ($Remove) {
    foreach ($name in @("AltStableProbe", "ForeverAPIDump")) {
        $old = Join-Path $AddOnsPath $name
        if (Test-Path -LiteralPath $old) {
            Remove-Item -LiteralPath $old -Recurse -Force
            Write-Host "Removed $name from AddOns" -ForegroundColor DarkYellow
        }
    }
    $hostDir = Join-Path $AddOnsPath "ForeverProbe"
    if (Test-Path -LiteralPath $hostDir) {
        $users = @(Get-ChildItem -LiteralPath $AddOnsPath -Directory | Where-Object {
            $_.Name -ne "ForeverProbe" -and
            # -Quiet answers once per .toc: an addon with several (Gargul, Questie) gives
            # an array of $false, which is truthy. Ask whether any of them is $true.
            (@(Get-ChildItem -LiteralPath $_.FullName -Filter *.toc | Select-String -Quiet -Pattern '^## (Dependencies|RequiredDeps):.*\bForeverProbe\b') -contains $true)
        } | ForEach-Object { $_.Name })
        if ($users.Count -gt 0) {
            Write-Host "Kept ForeverProbe: $($users -join ', ') still depend on it" -ForegroundColor DarkGray
        } else {
            Remove-Item -LiteralPath $hostDir -Recurse -Force
            Write-Host "Removed ForeverProbe from AddOns" -ForegroundColor DarkYellow
        }
    }
    exit 0
}

# The host, then the module, through ForeverProbe's own deploy (#549): it checks
# both first and copies nothing when either is refused. It copies the TOC and the
# files it lists, and removes the ones it no longer lists, so a stale file goes
# as /MIR's did. (read-wirelog.py stays in the repo: it reads WTF\, not this
# copy.) SavedVariables live in WTF\, not here.
# (AltStableDevConfig is retired: it seeded a whitelist from code while #23 kept
# settings from loading, and after the fix only overwrote the player's own.)
$fpDeploy = Join-Path $ForeverProbe "Tools\deploy.ps1"
if (-not (Test-Path -LiteralPath $fpDeploy)) {
    Write-Error "ForeverProbe checkout not found at $ForeverProbe (clone github.com/Spotnick2/ForeverProbe there, or set `$env:FOREVERPROBE)"
    exit 1
}
# A checkout from before ForeverProbe#47 has no -Module: pwsh -File leaves the
# argument unbound, deploys the host alone and exits 0 (review of #555). Ask the
# script for the parameter before running it.
if (-not (Get-Command -Name $fpDeploy).Parameters.ContainsKey("Module")) {
    Write-Error "The ForeverProbe checkout at $ForeverProbe is too old: its Tools\deploy.ps1 has no -Module (ForeverProbe#47). Pull its main, then run this again. Nothing was copied."
    exit 1
}
$dest = Join-Path $AddOnsPath "AltStableProbe"
& pwsh -NoProfile -File $fpDeploy -AddOnsPath $AddOnsPath -Module (Join-Path $RepoRoot "Tools\AltStableProbe")
# Its own error says what failed. A refusal at its checks copies nothing, but a
# copy that fails after them (a locked file) can leave the host updated and the
# probe partial, so this doesn't claim either.
if ($LASTEXITCODE -ne 0) { Write-Error "the probe deploy did not complete (ForeverProbe's deploy.ps1 exited $LASTEXITCODE; its error is above). Run this again once it's fixed."; exit 1 }

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
Write-Host "In-game (a new or changed addon needs only /reload):" -ForegroundColor Yellow
Write-Host "  /console scriptErrors 1   (errors are OFF by default on this client)"
Write-Host "  /reload"
Write-Host "  /fp as                    the probe's commands; its lines are in the /fp console"
Write-Host "  /fp as all                run every section"
Write-Host "  /fp as bank               containers + bank tabs, with the BANK WINDOW OPEN"
Write-Host "  /fp as whisper <Name>     cross-account ping (log the other account in first)"
Write-Host ""
Write-Host "Results are written to AltStableProbeDB on logout or /reload:"
Write-Host "  ...\_forever_\WTF\Account\<id>\SavedVariables\AltStableProbe.lua   (log, wireLog, ...)"
Write-Host ""
Write-Host "When the question is answered, take them out again: pwsh Tools/deploy-probe.ps1 -Remove" -ForegroundColor DarkGray
