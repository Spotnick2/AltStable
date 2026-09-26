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
    $failed = 0
    Get-ChildItem (Join-Path $PSScriptRoot "test_*.lua") | Sort-Object Name | ForEach-Object {
        Write-Host "── $($_.Name) ──────────────────────────────" -ForegroundColor Cyan
        & $Lua $_.FullName
        if ($LASTEXITCODE -ne 0) { $failed++ }
        Write-Host ""
    }
    Get-ChildItem (Join-Path $PSScriptRoot "test_*.py") | Sort-Object Name | ForEach-Object {
        Write-Host "── $($_.Name) ──────────────────────────────" -ForegroundColor Cyan
        & python $_.FullName
        if ($LASTEXITCODE -ne 0) { $failed++ }
        Write-Host ""
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
