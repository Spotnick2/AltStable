<#
    restore-release.ps1 - Put the published AltStable back over a dev copy.

    deploy.ps1 keeps the release it overwrites (CurseForge's, normally) in
    Interface\AddOns-release\AltStable, beside AddOns where the client does not
    look. This puts those folders back exactly as they were, so the CurseForge
    app recognises them again, removes the dev-only plugin folders the release
    did not have, and takes the dev tools out (deploy-probe.ps1 -Remove).

    -Tag fetches that release's zip from GitHub instead (the file CurseForge
    serves; needs gh): for when nothing was kept, because no release was
    installed before the first dev deploy. -Tag latest is the newest release.

    Usage:
        pwsh Tools/restore-release.ps1
        pwsh Tools/restore-release.ps1 -Tag v0.16.0
        pwsh Tools/restore-release.ps1 -AddOnsPath "D:\Games\WoW\_forever_\Interface\AddOns"
#>

param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns",
    [string]$Tag
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path $AddOnsPath)) {
    throw "AddOns path not found: $AddOnsPath"
}

function Get-TocVersion([string]$toc) {
    if (-not (Test-Path -LiteralPath $toc)) { return $null }
    $m = Select-String -LiteralPath $toc -Pattern '^## Version:\s*(\S+)' | Select-Object -First 1
    if ($m) { $m.Matches[0].Groups[1].Value } else { $null }
}

if ($Tag) {
    $source = Join-Path ([IO.Path]::GetTempPath()) "AltStable-release-$PID"
    $zipDir = Join-Path $source "zip"
    New-Item -ItemType Directory -Force $zipDir | Out-Null
    $tagArg = if ($Tag -eq "latest") { @() } else { @($Tag) }
    Push-Location $RepoRoot
    try { gh release download @tagArg --pattern "*-forever.zip" --dir $zipDir } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "gh could not download the $Tag release zip" }
    $zip = Get-ChildItem $zipDir -Filter *.zip | Select-Object -First 1
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $source
    $version = if ($Tag -eq "latest") { $zip.BaseName -replace '^AltStable-|-forever$', '' } else { $Tag }
} else {
    $source = Join-Path (Split-Path -Parent $AddOnsPath) "AddOns-release\AltStable"
    if (-not (Test-Path -LiteralPath (Join-Path $source "AltStable"))) {
        throw "No release was kept at $source (none was installed before the first dev deploy). Use -Tag latest, or reinstall AltStable in the CurseForge app."
    }
    $version = (Get-Content -LiteralPath (Join-Path $source "VERSION") -ErrorAction SilentlyContinue | Select-Object -First 1)
}

# Every folder a dev deploy writes, and every folder the release has.
$names = @("AltStable") +
    @(Get-ChildItem (Join-Path $RepoRoot "Plugins") -Filter *.toc -Recurse -Depth 1 | ForEach-Object { $_.BaseName }) +
    @(Get-ChildItem -LiteralPath $source -Directory | Where-Object Name -ne "zip" | ForEach-Object { $_.Name })

# The client reads a TOC's file list at start only, so a /reload is enough
# only while every TOC lists the same files (the version line aside).
function Get-TocBody([string]$toc) {
    if (-not (Test-Path -LiteralPath $toc)) { return "" }
    (Get-Content -LiteralPath $toc | Where-Object { $_ -notmatch '^## Version:' }) -join "`n"
}
$restart = $false

Write-Host "Restoring AltStable $version ..." -ForegroundColor Cyan
foreach ($name in $names | Sort-Object -Unique) {
    $from = Join-Path $source $name
    $to = Join-Path $AddOnsPath $name
    if (Test-Path -LiteralPath $from) {
        if ((Get-TocBody (Join-Path $from "$name.toc")) -ne (Get-TocBody (Join-Path $to "$name.toc"))) { $restart = $true }
        robocopy $from $to /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $name (code $LASTEXITCODE)" }
        Write-Host "  $name -> $(Get-TocVersion (Join-Path $to "$name.toc"))" -ForegroundColor DarkGray
    } elseif ((Get-TocVersion (Join-Path $to "$name.toc")) -like "dev*") {
        # A plugin the release does not have yet. Only a dev copy is removed.
        Remove-Item -LiteralPath $to -Recurse -Force
        $restart = $true
        Write-Host "  removed dev-only $name" -ForegroundColor DarkYellow
    }
}

if ($Tag) { Remove-Item -LiteralPath $source -Recurse -Force }

# The probe and the API dump are dev tools, deployed only on demand.
& pwsh -NoProfile -File (Join-Path $PSScriptRoot "deploy-probe.ps1") -AddOnsPath $AddOnsPath -Remove
if ($LASTEXITCODE -ne 0) { throw "removing the dev tools failed" }

Write-Host "Done -> AltStable $version" -ForegroundColor Green
if ($restart) {
    Write-Host "Exit and relaunch the client: a TOC changed, and /reload keeps the old file list." -ForegroundColor Yellow
} else {
    Write-Host "In-game: /reload" -ForegroundColor Yellow
}
