<#
    deploy.ps1 — Deploy AltStable to the WoW: Forever AddOns folder.

    Usage:
        pwsh Tools/deploy.ps1
        pwsh Tools/deploy.ps1 -AddOnsPath "D:\Games\WoW\_classic_beta_\Interface\AddOns"

    Plugins fan out into sibling top-level folders: WoW only discovers addons
    as top-level folders under Interface\AddOns, so Plugins\Warband deploys to
    AddOns\AltStableWarband rather than inside AltStable.

    The glass material is the embedded LibGlass-1.0 (#184), and the camera
    showcase the embedded LibShowcase-1.0. The packager fetches them into
    Libs\ (.pkgmeta externals); for a dev copy this script hands that job to
    each checkout's own deploy.ps1, FIRST, which checks the checkout and may
    refuse. The checkouts are $env:LIBGLASS, else ..\LibGlass, and
    $env:LIBSHOWCASE, else ..\LibShowcase.
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

$pkgmeta = Get-Content -LiteralPath (Join-Path $RepoRoot ".pkgmeta")
$libs = @(@{ Name = "LibGlass"; Major = "LibGlass-1.0"; Env = $env:LIBGLASS; EnvName = "LIBGLASS" },
          @{ Name = "LibShowcase"; Major = "LibShowcase-1.0"; Env = $env:LIBSHOWCASE; EnvName = "LIBSHOWCASE" })
foreach ($lib in $libs) {
    $lib.Root = if ($lib.Env) { $lib.Env } else { Join-Path (Split-Path -Parent $RepoRoot) $lib.Name }
    if (-not (Test-Path -LiteralPath (Join-Path $lib.Root "Tools\deploy.ps1"))) {
        throw "$($lib.Name) checkout not found at $($lib.Root) (clone github.com/Spotnick2/$($lib.Name) there, or set `$env:$($lib.EnvName))"
    }

    # The commit or tag .pkgmeta pins is what the packager will ship. A checkout
    # elsewhere is legitimate (trying a library change before a pin bump), but an
    # in-game check then tests something the release won't carry: say so. Each
    # library's own external block, not the first pin in the file.
    $pin = $null; $inBlock = $false
    foreach ($line in $pkgmeta) {
        if ($line -match '^  (\S+):\s*$') { $inBlock = ($Matches[1] -eq "Libs/$($lib.Major)"); continue }
        if ($line -match '^\S') { $inBlock = $false }
        if ($inBlock -and $line -match '^\s+(commit|tag):\s*(\S+)\s*$') { $pin = $Matches[2]; break }
    }
    if ($pin) {
        $want = $null; $head = $null; $dirty = $null
        try {
            $want = (git -C $lib.Root rev-parse --verify --quiet "$pin^{commit}" 2>$null)
            $head = (git -C $lib.Root rev-parse HEAD 2>$null)
            $dirty = (git -C $lib.Root status --porcelain 2>$null)
        } catch { }
        if (-not $want -or $want -ne $head -or $dirty) {
            Write-Host "  WARNING: the $($lib.Name) checkout is not at the .pkgmeta pin ($pin)$(if ($dirty) { ', or has uncommitted changes' }):" -ForegroundColor Yellow
            Write-Host "  this deploy tests a library the release won't ship." -ForegroundColor Yellow
        }
    }
}

# The libraries first: a refusal must leave the deployed addon as it was (a new
# TOC naming a library that never arrived loads nothing at all).
foreach ($lib in $libs) {
    & pwsh -NoProfile -File (Join-Path $lib.Root "Tools\deploy.ps1") -Addon AltStable -AddOnsPath $AddOnsPath
    if ($LASTEXITCODE -ne 0) { throw "$($lib.Name) deploy refused; AltStable was not touched" }
}

Write-Host "Deploying AltStable ..." -ForegroundColor Cyan

# /E copies without purging, so unrelated files already sitting in the target
# (zips, stray captures) are left alone. robocopy exit codes 0-7 are success.
$excludeDirs = @(
    (Join-Path $RepoRoot "Tools"),
    (Join-Path $RepoRoot "tests"),
    (Join-Path $RepoRoot "docs"),
    # Every dot-entry, by name: .git, .github, .claude, .vscode, .idea - and the
    # ones nobody listed. A worktree's .git is a FILE, and tool scratch folders
    # (.playwright-mcp, .skill-staging) appear and vanish; listing them one by
    # one is how all three ended up in the deployed folder.
    ".*",
    # Mirror .gitignore: these are local-only and have no business in the
    # deployed tree. dist/ in particular can be tens of MB and makes it
    # misleading to diagnose what the client actually loaded.
    (Join-Path $RepoRoot ".claude"),
    (Join-Path $RepoRoot ".vscode"),
    # Scene REFERENCE screenshots: ~79 MB of source material the client never
    # reads. Excluded like dist/ and for the same reason - a deployed tree that
    # carries the sources makes it harder to see what the game actually loaded.
    # (The PNG masters beside them are already covered by the *.png file rule.)
    # Backslashes, matching every other entry. A review flagged the forward-
    # slash form as silently matching nothing; that did NOT reproduce here -
    # robocopy excluded the directory either way, splatted exactly as below.
    # Kept in the native separator regardless: this is the only multi-segment
    # entry in the list, so it is the only one where the question can arise.
    (Join-Path $RepoRoot "Media\Scene\References"),
    (Join-Path $RepoRoot ".idea"),
    (Join-Path $RepoRoot "dist"),
    (Join-Path $RepoRoot "__pycache__"),
    # Deployed from the library checkouts above; a stray local copy must not
    # overwrite them.
    (Join-Path $RepoRoot "Libs\LibGlass-1.0"),
    (Join-Path $RepoRoot "Libs\LibShowcase-1.0"),
    # Plugins are separate addons; they are deployed below, not nested here.
    (Join-Path $RepoRoot "Plugins")
)
# *.png is source art only - WoW loads TGA/BLP, never PNG.
$excludeFiles = @("*.log", "*.zip", "*.md", "*.png", ".*")

$roboArgs = @($RepoRoot, $dest, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP",
              "/XD") + $excludeDirs + @("/XF") + $excludeFiles
robocopy @roboArgs | Out-Null
$deployedTocs = @((Join-Path $dest "AltStable.toc"))
if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed (code $LASTEXITCODE)"
}

# /E never purges, so what an older deploy copied stays. A dot-entry at the top
# of a deployed addon folder is never something we ship (.pkgmeta, a worktree's
# .git file, tool scratch folders): remove those, and only those, and say so.
function Remove-DevLeftovers([string]$folder) {
    if (-not (Test-Path $folder)) { return }
    foreach ($item in Get-ChildItem -LiteralPath $folder -Force -Filter ".*") {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
        Write-Host "  removed leftover $($item.Name) from $(Split-Path $folder -Leaf)" -ForegroundColor DarkYellow
    }
}
Remove-DevLeftovers $dest

# The material's textures ship inside Libs\LibGlass-1.0\Media now (#184); the
# old copy an earlier deploy left is dead weight. /E never purges, so say so.
$staleGlass = Join-Path $dest "Media\Glass"
if (Test-Path -LiteralPath $staleGlass) {
    Remove-Item -LiteralPath $staleGlass -Recurse -Force
    Write-Host "  removed stale Media\Glass (textures now come from LibGlass)" -ForegroundColor DarkYellow
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
                        "/NJS", "/NP", "/XD", ".*", "/XF") + $excludeFiles
        robocopy @pluginArgs | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $name (code $LASTEXITCODE)" }
        Remove-DevLeftovers $pluginDest
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
