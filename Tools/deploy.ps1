<#
    deploy.ps1 — Deploy AltStable to the WoW: Forever AddOns folder.

    Usage:
        pwsh Tools/deploy.ps1
        pwsh Tools/deploy.ps1 -AddOnsPath "D:\Games\WoW\_classic_beta_\Interface\AddOns"

    Plugins fan out into sibling top-level folders: WoW only discovers addons
    as top-level folders under Interface\AddOns, so Plugins\Warband deploys to
    AddOns\AltStableWarband rather than inside AltStable.
#>

param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path $AddOnsPath)) {
    throw "AddOns path not found: $AddOnsPath"
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
    # Mirror .gitignore: these are local-only and have no business in the
    # deployed tree. dist/ in particular can be tens of MB and makes it
    # misleading to diagnose what the client actually loaded.
    (Join-Path $RepoRoot ".claude"),
    (Join-Path $RepoRoot ".vscode"),
    # Scene REFERENCE screenshots: ~79 MB of source material the client never
    # reads. Excluded like dist/ and for the same reason - a deployed tree that
    # carries the sources makes it harder to see what the game actually loaded.
    # (The PNG masters beside them are already covered by the *.png file rule.)
    (Join-Path $RepoRoot "Media/Scene/References"),
    (Join-Path $RepoRoot ".idea"),
    (Join-Path $RepoRoot "dist"),
    (Join-Path $RepoRoot "__pycache__"),
    # Plugins are separate addons; they are deployed below, not nested here.
    (Join-Path $RepoRoot "Plugins")
)
# *.png is source art only - WoW loads TGA/BLP, never PNG.
$excludeFiles = @("*.log", "*.zip", "*.md", "*.png", ".gitignore")

$roboArgs = @($RepoRoot, $dest, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP",
              "/XD") + $excludeDirs + @("/XF") + $excludeFiles
robocopy @roboArgs | Out-Null
$deployedTocs = @((Join-Path $dest "AltStable.toc"))
if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed (code $LASTEXITCODE)"
}

# Plugins: each folder under Plugins\ becomes its own top-level addon folder,
# named after the .toc inside it (WoW requires folder name == toc name).
$pluginRoot = Join-Path $RepoRoot "Plugins"
if (Test-Path $pluginRoot) {
    foreach ($dir in Get-ChildItem $pluginRoot -Directory) {
        $toc = Get-ChildItem $dir.FullName -Filter *.toc | Select-Object -First 1
        if (-not $toc) {
            Write-Host "  skipping $($dir.Name): no .toc" -ForegroundColor DarkYellow
            continue
        }
        $name = [IO.Path]::GetFileNameWithoutExtension($toc.Name)
        $pluginDest = Join-Path $AddOnsPath $name
        $pluginArgs = @($dir.FullName, $pluginDest, "/E", "/NFL", "/NDL", "/NJH",
                        "/NJS", "/NP", "/XF") + $excludeFiles
        robocopy @pluginArgs | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $name (code $LASTEXITCODE)" }
        $deployedTocs += (Join-Path $pluginDest $toc.Name)
        Write-Host "  plugin -> $name" -ForegroundColor DarkGray
    }
}

# The packager substitutes @project-version@ at release time. Left as-is, the
# raw token shows in the in-game AddOns list — and worse, editing the repo copy
# to avoid that is how a literal version gets committed over the token, which
# happened twice in Priestly and Apotheca. Substitute in the DEPLOYED copies
# only, and in EVERY deployed .toc: the plugins carry the keyword too, so
# patching just the main one leaves them showing the raw token.
$rev = $null
if (Get-Command git -ErrorAction SilentlyContinue) {
    try { $rev = (git -C $RepoRoot rev-parse --short HEAD 2>$null) } catch { $rev = $null }
}
$label = if ($rev) { "dev-$rev" } else { "dev" }
foreach ($toc in $deployedTocs) {
    if (Test-Path $toc) {
        (Get-Content $toc -Raw).Replace('@project-version@', $label) |
            Set-Content $toc -NoNewline
    }
}
Write-Host "  version -> $label (deployed copies only)" -ForegroundColor DarkGray

Write-Host "Done -> $dest" -ForegroundColor Green
Write-Host ""
Write-Host "In-game:" -ForegroundColor Yellow
Write-Host "  /console scriptErrors 1   (errors are OFF by default on this client)"
Write-Host "  /reload"
Write-Host "  /alts                     open the sheet"
