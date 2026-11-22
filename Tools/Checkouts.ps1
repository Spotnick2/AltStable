<#
    Checkouts.ps1 - where a sibling checkout (a library) is (#477).

    Dot-sourced by tests/run.ps1 and Tools/deploy.ps1. In order:
      1. the environment variable (LIBGLASS, ...);
      2. the folder next to this repo (..\LibGlass);
      3. the folder next to the MAIN checkout, for a git worktree kept
         elsewhere (a scratch folder has no ..\LibGlass).
    A candidate counts only if it holds -Marker (the library's own XML): an
    empty folder of that name is not a checkout (Codex review of #478).
    None found: the neighbour path, so the caller's "not found" message names
    it as before. tests/checkouts.lua is the same rule for the Lua loaders.
#>

function Get-CheckoutRoot {
    param([string]$RepoRoot, [string]$Name, [string]$EnvValue, [string]$Marker)
    if ($EnvValue) { return $EnvValue }
    $beside = Join-Path (Split-Path -Parent $RepoRoot) $Name
    if (Test-Path -LiteralPath (Join-Path $beside $Marker)) { return $beside }
    $common = $null
    try { $common = git -C $RepoRoot rev-parse --path-format=absolute --git-common-dir 2>$null } catch { }
    if ($common) {
        $main = Split-Path -Parent $common
        $there = Join-Path (Split-Path -Parent $main) $Name
        if (Test-Path -LiteralPath (Join-Path $there $Marker)) { return $there }
    }
    return $beside
}
