<#
    deploy.ps1 — Deploy AltStable to the WoW: Forever AddOns folder.

    Usage:
        pwsh Tools/deploy.ps1
        pwsh Tools/deploy.ps1 -AddOnsPath "D:\Games\WoW\_classic_beta_\Interface\AddOns"

    Plugins fan out into sibling top-level folders (WoW only discovers addons
    as top-level folders under Interface\AddOns) once they are ported — see
    issues #9 and #11. For now this deploys the core addon only.
#>

param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path $AddOnsPath)) {
    Write-Error "AddOns path not found: $AddOnsPath"
    exit 1
}

$dest = Join-Path $AddOnsPath "AltStable"
Write-Host "Deploying AltStable ..." -ForegroundColor Cyan

# /E copies without purging, so unrelated files already sitting in the target
# (zips, stray captures) are left alone. robocopy exit codes 0-7 are success.
$excludeDirs = @(
    (Join-Path $RepoRoot "Tools"),
    (Join-Path $RepoRoot "tests"),
    (Join-Path $RepoRoot "docs"),
    (Join-Path $RepoRoot ".git"),
    (Join-Path $RepoRoot ".github"),
    (Join-Path $RepoRoot ".claude")
)
# *.png is source art only - WoW loads TGA/BLP, never PNG.
$excludeFiles = @("*.log", "*.zip", "*.md", "*.png", ".gitignore")

$roboArgs = @($RepoRoot, $dest, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP",
              "/XD") + $excludeDirs + @("/XF") + $excludeFiles
robocopy @roboArgs | Out-Null
if ($LASTEXITCODE -ge 8) {
    Write-Error "robocopy failed (code $LASTEXITCODE)"
    exit 1
}

# The packager substitutes @project-version@ at release time. Left as-is, the
# raw token shows in the in-game AddOns list — and worse, editing the repo copy
# to avoid that is how a literal version gets committed over the token, which
# happened twice in Priestly and Apotheca. Substitute in the DEPLOYED copy only.
$deployedToc = Join-Path $dest "AltStable.toc"
if (Test-Path $deployedToc) {
    $rev = (git -C $RepoRoot rev-parse --short HEAD 2>$null)
    $label = if ($rev) { "dev-$rev" } else { "dev" }
    (Get-Content $deployedToc -Raw).Replace('@project-version@', $label) |
        Set-Content $deployedToc -NoNewline
    Write-Host "  version -> $label (deployed copy only)" -ForegroundColor DarkGray
}

Write-Host "Done -> $dest" -ForegroundColor Green
Write-Host ""
Write-Host "In-game:" -ForegroundColor Yellow
Write-Host "  /console scriptErrors 1   (errors are OFF by default on this client)"
Write-Host "  /reload"
Write-Host "  /alts                     open the sheet"
