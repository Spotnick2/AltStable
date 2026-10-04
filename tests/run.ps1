<#
    run.ps1 - Run all AltStable unit tests.

    Lua tests are plain Lua 5.1 scripts (no dependencies) that load addon files
    against tests/wow_stubs.lua. WoW uses Lua 5.1, so the tests do too — not
    the newer Lua that may be first on PATH.

    Lua, plus test_*.py for the cutout converter. This runner was Lua-only
    because AltTracker's Python tests pulled in deferred tooling; these use the
    standard library only and skip themselves if the converter's own
    dependencies (numpy, Pillow) are absent.

    Usage:
        pwsh tests/run.ps1
        pwsh tests/run.ps1 -Lua "C:\path\to\lua5.1.exe"
#>

param(
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Lua)) {
    Write-Error "Lua 5.1 interpreter not found at: $Lua  (pass -Lua <path>)"
    exit 1
}

# Run from the repo root so tests can `dofile('tests/wow_stubs.lua')` and
# `loadfile('Core.lua')` with paths relative to the project.
$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot
try {
    # The tests load LibGlass-1.0 from a checkout (#184): $env:LIBGLASS, else
    # ..\LibGlass (tests/libglass.lua). They take it as it is; CI loads the
    # .pkgmeta pin. Running against something else is fine (a library change
    # before a pin bump) but must not pass for a check of what ships.
    $libGlass = if ($env:LIBGLASS) { $env:LIBGLASS } else { Join-Path (Split-Path -Parent $RepoRoot) "LibGlass" }
    $pin = (Get-Content ".pkgmeta") | Where-Object { $_ -match '^\s+(commit|tag):\s*(\S+)\s*$' } |
        ForEach-Object { $Matches[2] } | Select-Object -First 1
    if ($pin -and (Test-Path -LiteralPath $libGlass)) {
        $want = git -C $libGlass rev-parse --verify --quiet "$pin^{commit}" 2>$null
        $head = git -C $libGlass rev-parse HEAD 2>$null
        $dirty = git -C $libGlass status --porcelain 2>$null
        if (-not $want -or $want -ne $head -or $dirty) {
            Write-Host "WARNING: LibGlass at $libGlass is not the .pkgmeta pin ($pin)$(if ($dirty) { ', or has uncommitted changes' }); CI tests the pin" -ForegroundColor Yellow
        } else {
            Write-Host "LibGlass: $libGlass at the pin ($pin)" -ForegroundColor DarkGray
        }
    }

    $failed = 0
    Get-ChildItem (Join-Path $PSScriptRoot "test_*.lua") | Sort-Object Name | ForEach-Object {
        Write-Host "── $($_.Name) ──────────────────────────────" -ForegroundColor Cyan
        & $Lua $_.FullName
        if ($LASTEXITCODE -ne 0) { $failed++ }
        Write-Host ""
    }
    # The manifest writer's enhanced-texture attachment rule
    # (PORTRAIT-CONTRACT.md section 3). Pure PowerShell on temp files: no
    # Python, no client.
    Write-Host "── Update-Cutouts.ps1 -SelfTest ──────────────" -ForegroundColor Cyan
    # An install path on a drive that does not exist: the script must not need
    # one to self-test (the Linux CI runner has no C:, and that broke it once).
    & pwsh -NoProfile -File (Join-Path $RepoRoot "Tools/RenderCutout/Update-Cutouts.ps1") -SelfTest -AddOnsPath "Q:\no-such-install\AddOns"
    if ($LASTEXITCODE -ne 0) { $failed++ }
    Write-Host ""

    # Same reasoning as the tests' own Pillow check: the Python suites cover an
    # optional local tool, so a machine without Python should skip them, not
    # fail the addon's tests. This runner was Lua-only until now and nobody
    # needed Python to run it.
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) {
        Write-Host "── test_*.py ── SKIPPED: python is not on PATH" -ForegroundColor DarkYellow
        Write-Host ""
    } else {
        Get-ChildItem (Join-Path $PSScriptRoot "test_*.py") | Sort-Object Name | ForEach-Object {
            Write-Host "── $($_.Name) ──────────────────────────────" -ForegroundColor Cyan
            & $py.Source $_.FullName
            if ($LASTEXITCODE -ne 0) { $failed++ }
            Write-Host ""
        }
    }

    if ($failed -gt 0) {
        Write-Host "$failed test file(s) FAILED" -ForegroundColor Red
        exit 1
    }
    Write-Host "All test files passed." -ForegroundColor Green
}
finally {
    Pop-Location
}
