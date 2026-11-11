<#
    tests/kit.ps1: puts WowTestKit at the commit tests/kit.pin names into the
    local cache and returns its folder. Dot-source it from tests/run.ps1.
    Copied from WowTestKit's bootstrap/kit.ps1: never edit a consumer's copy;
    change the kit's and copy it again.

    The cache is %LOCALAPPDATA%\WowTestKit\<sha>, outside the repo. A valid
    cache (HEAD is the pin) is used as it is, offline too; otherwise it is
    fetched (git, depth 1) and checked to BE the pinned commit.
    -KitDev uses the sibling ..\WowTestKit working copy instead (or
    $env:WOWTESTKIT_DEV), and says so: for testing a kit change.
#>

function Get-WowTestKit {
    param([Parameter(Mandatory)][string]$RepoRoot, [switch]$KitDev)

    $pin = @{}
    Get-Content (Join-Path $RepoRoot "tests\kit.pin") | ForEach-Object {
        if ($_ -match '^\s*(\w+)\s*=\s*(\S+)') { $pin[$Matches[1]] = $Matches[2] }
    }
    if (-not $pin.sha -or -not $pin.build) { throw "tests\kit.pin needs sha= and build=" }

    if ($KitDev) {
        $dir = if ($env:WOWTESTKIT_DEV) { $env:WOWTESTKIT_DEV } else { Join-Path (Split-Path -Parent $RepoRoot) "WowTestKit" }
        if (-not (Test-Path (Join-Path $dir "kit.lua"))) { throw "-KitDev: no WowTestKit working copy at $dir" }
        Write-Host "WowTestKit: DEV working copy $dir, NOT the pin $($pin.sha.Substring(0, 7))" -ForegroundColor Yellow
    } else {
        $dir = Join-Path $env:LOCALAPPDATA "WowTestKit\$($pin.sha)"
        $head = $null
        if (Test-Path (Join-Path $dir ".git")) { $head = (git -C $dir rev-parse HEAD 2>$null) }
        if ($head -ne $pin.sha) {
            # Only this cache folder, named after the pin, is ever replaced.
            if (Test-Path $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
            New-Item -ItemType Directory -Force $dir | Out-Null
            git -C $dir init --quiet
            git -C $dir fetch --quiet --depth 1 https://github.com/Spotnick2/WowTestKit.git $pin.sha
            if ($LASTEXITCODE -ne 0) { throw "could not fetch WowTestKit $($pin.sha) (offline, or not pushed?)" }
            git -C $dir checkout --quiet FETCH_HEAD
            $head = (git -C $dir rev-parse HEAD)
            if ($head -ne $pin.sha) { throw "WowTestKit at $dir is $head, not the pin $($pin.sha)" }
        }
        Write-Host "WowTestKit: $($pin.sha.Substring(0, 7)), build $($pin.build)" -ForegroundColor DarkGray
    }
    $env:WOWTESTKIT = $dir
    return $dir
}
