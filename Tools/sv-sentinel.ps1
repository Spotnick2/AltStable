<#
    sv-sentinel.ps1 — Settle whether the client reads SavedVariables back.

    Plants a value no addon would ever write into AltStableProbe's SavedVariables
    file. If the next session reports that value, the load works. If it reports
    "first ever run", the client is not reading the file.

    This is immune to the usual objections: it does not rely on comparing a file
    to its .bak (which proves determinism, not a round-trip), and it does not
    depend on any third-party addon's behaviour or version.

    TIMING MATTERS. WoW writes SavedVariables on logout, exit and /reload, and
    reads them when a character loads. So:

        1. Log out to the character-select screen (or exit the game).
        2. Run this script.
        3. Log back in.
        4. Read the [probe] line.

    Running it while a character is logged in achieves nothing: the client holds
    the table in memory and will overwrite the file on the way out.

    Usage:
        pwsh Tools/sv-sentinel.ps1
        pwsh Tools/sv-sentinel.ps1 -Account "50284074#1"
#>

param(
    [string]$WtfAccountRoot = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\WTF\Account",
    [string]$Account = "",
    [int]$Sentinel = 99
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $WtfAccountRoot)) { throw "WTF account root not found: $WtfAccountRoot" }

$accounts = if ($Account) { @($Account) } else {
    Get-ChildItem $WtfAccountRoot -Directory |
        Where-Object { $_.Name -ne "SavedVariables" } | ForEach-Object { $_.Name }
}

$touched = 0
foreach ($a in $accounts) {
    $f = Join-Path $WtfAccountRoot "$a\SavedVariables\AltStableProbe.lua"
    if (-not (Test-Path $f)) {
        Write-Host "  $a : no AltStableProbe.lua yet (log in once with the probe loaded)" -ForegroundColor DarkGray
        continue
    }

    $body = @"
AltStableProbeDB = {
["loadCount"] = $Sentinel,
["lastLoadStamp"] = "SENTINEL planted $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
}
"@
    Set-Content -Path $f -Value $body -NoNewline
    Write-Host "  $a : planted loadCount = $Sentinel" -ForegroundColor Green
    $touched++
}

if ($touched -eq 0) { throw "No AltStableProbe.lua found under $WtfAccountRoot" }

Write-Host ""
Write-Host "Now log IN (you must already be at character select)." -ForegroundColor Yellow
Write-Host ""
Write-Host "  SV LOADED - previous loadCount=$Sentinel   -> SavedVariables DO load" -ForegroundColor Green
Write-Host "  SV: first ever run                         -> the client does not read them back" -ForegroundColor Red
