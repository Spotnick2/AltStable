<#
    Checkouts.ps1 - where a sibling checkout (a library) is (#477).

    Dot-sourced by tests/run.ps1 and Tools/deploy.ps1. In order:
      1. the environment variable (LIBGLASS, ...);
      2. the folder next to this repo (..\LibGlass);
      3. the folder next to the MAIN checkout, for a git worktree kept
         elsewhere (a scratch folder has no ..\LibGlass).
    None found: the neighbour path, so the caller's "not found" message names
    it as before. tests/checkouts.lua is the same rule for the Lua loaders.
#>

function Get-CheckoutRoot {
    param([string]$RepoRoot, [string]$Name, [string]$EnvValue)
    if ($EnvValue) { return $EnvValue }
    $beside = Join-Path (Split-Path -Parent $RepoRoot) $Name
    if (Test-Path -LiteralPath $beside) { return $beside }
    $common = $null
    try { $common = git -C $RepoRoot rev-parse --path-format=absolute --git-common-dir 2>$null } catch { }
    if ($common) {
        $main = Split-Path -Parent $common
        $there = Join-Path (Split-Path -Parent $main) $Name
        if (Test-Path -LiteralPath $there) { return $there }
    }
    return $beside
}
