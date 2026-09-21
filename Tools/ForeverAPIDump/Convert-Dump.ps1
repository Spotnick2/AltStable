<#
    Convert-Dump.ps1 — turn ForeverAPIDump's SavedVariable into the shared
    reference artifact.

    RE-RUN THIS WHENEVER THE CLIENT BUILD CHANGES. The artifact is a snapshot
    of one build; a stale one is worse than none, because it reads exactly as
    authoritatively as a current one. The filename carries the build for that
    reason, so a new build writes a new file and leaves the old one in place -
    the script says so when it notices, and deleting the stale one is yours.

    Note the staleness check cannot live in the addon: SavedVariables are never
    read back on this client (issue #23), so the addon cannot compare the
    build it ran on against the build it recorded last time. That makes this a
    process discipline rather than something the tool can enforce.

    Usage:
        pwsh Tools/ForeverAPIDump/Convert-Dump.ps1
        pwsh Tools/ForeverAPIDump/Convert-Dump.ps1 -OutDir "D:\Refs"

    In-game first:
        /apidump    build the dump
        /reload     flush it to SavedVariables
#>

param(
    [string]$WtfAccountPath = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\WTF\Account",
    [string]$OutDir = "C:\Projects\References"
)

$ErrorActionPreference = "Stop"

# Newest wins: the dump is per-account, and whichever account ran it last is
# the one that matches the client we care about.
$sv = Get-ChildItem -Path $WtfAccountPath -Recurse -Filter "ForeverAPIDump.lua" -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1

if (-not $sv) {
    throw "No ForeverAPIDump.lua found under $WtfAccountPath. Run /apidump then /reload in game."
}

Write-Host "Reading $($sv.FullName)" -ForegroundColor Cyan
$raw = Get-Content -Raw -Path $sv.FullName

function Get-LuaField {
    param([string]$Name)
    $m = [regex]::Match($raw, "\[""$Name""\]\s*=\s*""?([^"",`r`n]+)""?,")
    if ($m.Success) { return $m.Groups[1].Value } else { return "?" }
}

# Each section is a flat array of quoted strings, one per line.
function Get-LuaArray {
    param([string]$Name)
    $m = [regex]::Match($raw, "\[""$Name""\]\s*=\s*\{\r?\n(.*?)\r?\n\s*\},", 'Singleline')
    if (-not $m.Success) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $m.Groups[1].Value -split "`n") {
        $t = $line.Trim().TrimEnd(',')
        if ($t.StartsWith('"') -and $t.EndsWith('"')) {
            $out.Add($t.Substring(1, $t.Length - 2).Replace('\"', '"').Replace('\\', '\'))
        }
    }
    return $out
}

$version   = Get-LuaField "version"
$build     = Get-LuaField "build"
$buildDate = Get-LuaField "buildDate"
$toc       = Get-LuaField "tocVersion"
$projectID = Get-LuaField "projectID"
$generated = Get-LuaField "generated"

$sections = [ordered]@{
    "Documented functions"                     = Get-LuaArray "documented"
    "Documented events"                        = Get-LuaArray "events"
    "Documented tables (enums and structures)" = Get-LuaArray "tables"
    "Widget methods"                           = Get-LuaArray "widgets"
    "Global functions"                         = Get-LuaArray "globals"
    "Namespace functions"                      = Get-LuaArray "namespaces"
    "Namespace candidates (names only)"        = Get-LuaArray "namespaceCandidates"
}

foreach ($k in $sections.Keys) {
    Write-Host ("  {0,-42} {1,6}" -f $k, $sections[$k].Count)
}
if ($sections["Documented functions"].Count -eq 0) {
    Write-Warning "0 documented functions - the APIDocumentation pass failed. Check APIDocumentation_LoadUI."
}

$stamp = "$version.$build"
$out = Join-Path $OutDir "forever-api-$stamp.md"

$existing = Get-ChildItem -Path $OutDir -Filter "forever-api-*.md" -ErrorAction SilentlyContinue
if ($existing -and -not ($existing.Name -contains "forever-api-$stamp.md")) {
    Write-Host ""
    Write-Host "Build changed: existing artifact(s) $($existing.Name -join ', ') -> new $stamp" -ForegroundColor Yellow
    Write-Host "The old one is a different build. Delete it once nothing references it." -ForegroundColor Yellow
}

$sb = New-Object System.Text.StringBuilder
function Add-Line { param([string]$s = "") ; [void]$sb.AppendLine($s) }

Add-Line "# WoW: Forever — complete API surface, build $stamp"
Add-Line ""
Add-Line "Generated $generated from the live client by ``AltStable/Tools/ForeverAPIDump`` (``/apidump``)."
Add-Line "Interface $toc, WOW_PROJECT_ID $projectID, client built $buildDate."
Add-Line ""
Add-Line "**Regenerate this whenever the client build changes.** A stale dump reads exactly as"
Add-Line "authoritatively as a current one, which is the whole danger. Re-run ``/apidump`` in game, then"
Add-Line "``Tools/ForeverAPIDump/Convert-Dump.ps1``."
Add-Line ""
Add-Line "Measured on the client, not copied from a wiki. Four passes, because none is complete alone:"
Add-Line ""
Add-Line "| section | count | what it is |"
Add-Line "|---|---:|---|"
Add-Line "| Documented functions | $($sections['Documented functions'].Count) | ``APIDocumentation``: full signatures, argument order, ``optional`` markers, return types |"
Add-Line "| Documented events | $($sections['Documented events'].Count) | ``RegisterEvent`` name, documented name, payload |"
Add-Line "| Documented tables | $($sections['Documented tables (enums and structures)'].Count) | enumerations with values, structures with fields |"
Add-Line "| Global functions | $($sections['Global functions'].Count) | ``_G`` walk — the legacy surface the docs omit (``GetCVar``, ``CreateFrame``, …) |"
Add-Line "| Namespace functions | $($sections['Namespace functions'].Count) | every ``C_*`` table's members |"
Add-Line "| Widget methods | $($sections['Widget methods'].Count) | methods off each widget type's metatable — the surface no ``_G`` walk can see |"
Add-Line "| Namespace candidates | $($sections['Namespace candidates (names only)'].Count) | other global tables with callable members — names only, since loaded addons live here too |"
Add-Line ""
Add-Line "**Presence is not a contract.** This says a name exists and what shape it declares. It does not"
Add-Line "say the underlying system is wired up on a Vanilla-content client: ``test_cameraOverShoulder``"
Add-Line "accepts a write, reads back, and moves the camera not at all. Probe behaviour before building on it."
Add-Line ""

foreach ($k in $sections.Keys) {
    Add-Line "---"
    Add-Line ""
    Add-Line "## $k ($($sections[$k].Count))"
    Add-Line ""
    Add-Line '```'
    foreach ($line in $sections[$k]) { Add-Line $line }
    Add-Line '```'
    Add-Line ""
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }
Set-Content -Path $out -Value $sb.ToString() -Encoding UTF8 -NoNewline

$size = (Get-Item $out).Length / 1MB
Write-Host ""
Write-Host ("Wrote {0} ({1:N1} MB)" -f $out, $size) -ForegroundColor Green
