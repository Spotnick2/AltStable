<#
    Convert-Dump.ps1 — turn ForeverAPIDump's SavedVariable into the shared
    reference artifact.

    RE-RUN THIS WHENEVER THE CLIENT BUILD CHANGES. The artifact is a snapshot
    of one build; a stale one is worse than none, because it reads exactly as
    authoritatively as a current one. The filename carries the build for that
    reason, so a new build writes a new file and leaves the old one in place -
    the script says so when it notices, and deleting the stale one is yours.

    The staleness check lives here rather than in the addon because the dump
    addon keeps no state between runs - not, any longer, because the client
    cannot read SavedVariables back (#23 was fixed in 1.60.1.70009). Process
    discipline for now; a self-checking dump is possible if it earns its keep.

    Usage:
        pwsh Tools/ForeverAPIDump/Convert-Dump.ps1
        pwsh Tools/ForeverAPIDump/Convert-Dump.ps1 -OutDir "D:\Refs"
        pwsh Tools/ForeverAPIDump/Convert-Dump.ps1 -SelfTest

    In-game first:
        /apidump    build the dump
        /reload     flush it to SavedVariables
#>

param(
    [string]$WtfAccountPath = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\WTF\Account",
    [string]$OutDir = "C:\Projects\References",
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

# Each section is a flat array of quoted strings, one per line.
#
# The closing delimiter is matched WITHOUT requiring a newline inside the
# array. An empty section is written as "{\n}," - one newline, not two - so a
# pattern demanding a newline before `},` runs straight past the closing brace
# and swallows whatever follows. That failure is silent and it lies in the
# worst possible direction: an empty documentation pass would be reported as a
# populated one carrying the next section's contents.
function Get-LuaArray {
    param([string]$Raw, [string]$Name)
    $m = [regex]::Match($Raw, "\[""$Name""\]\s*=\s*\{(.*?)\r?\n\s*\},", 'Singleline')
    if (-not $m.Success) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $m.Groups[1].Value -split "`n") {
        $t = $line.Trim().TrimEnd(',')
        if ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"')) {
            $out.Add($t.Substring(1, $t.Length - 2).Replace('\"', '"').Replace('\\', '\'))
        }
    }
    return , $out.ToArray()
}

function Get-LuaField {
    param([string]$Raw, [string]$Name)
    $m = [regex]::Match($Raw, "\[""$Name""\]\s*=\s*""?([^"",`r`n]+)""?,")
    if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}

$SECTION_KEYS = [ordered]@{
    "Documented functions"                     = "documented"
    "Documented events"                        = "events"
    "Documented tables (enums and structures)" = "tables"
    "Widget methods"                           = "widgets"
    "Global functions"                         = "globals"
    "Namespace functions"                      = "namespaces"
    "Namespace candidates (names only)"        = "namespaceCandidates"
}

# A dump is only a candidate if it carries client metadata AND content. The
# addon initialises ForeverAPIDumpDB to {} at load, and SavedVariables never
# load back on this client, so ANY session that reloads without running
# /apidump overwrites that account's file with an empty table. Newest-by-mtime
# alone would then pick that empty file over another account's real dump.
function Test-DumpValid {
    param([string]$Raw)
    if (-not (Get-LuaField -Raw $Raw -Name "build")) { return $false }
    foreach ($key in $SECTION_KEYS.Values) {
        if ((Get-LuaArray -Raw $Raw -Name $key).Count -gt 0) { return $true }
    }
    return $false
}

if ($SelfTest) {
    # Fixtures for the two parsing traps, both reproduced from real failures.
    $empty = @"
ForeverAPIDumpDB = {
["client"] = {
["build"] = "69913",
},
["events"] = {
},
["tables"] = {
"Structure Example { field:string }",
},
}
"@
    $ok = $true

    $ev = Get-LuaArray -Raw $empty -Name "events"
    if ($ev.Count -ne 0) {
        Write-Host "FAIL empty section leaked $($ev.Count): $($ev -join '|')" -ForegroundColor Red; $ok = $false
    } else { Write-Host "  ok  an empty section stops at its own closing brace" }

    $tb = Get-LuaArray -Raw $empty -Name "tables"
    if ($tb.Count -ne 1) {
        Write-Host "FAIL the section after an empty one lost content ($($tb.Count))" -ForegroundColor Red; $ok = $false
    } else { Write-Host "  ok  the section after an empty one still parses" }

    $blank = 'ForeverAPIDumpDB = {' + "`n" + '}'
    if (Test-DumpValid -Raw $blank) {
        Write-Host "FAIL an empty dump passed validation" -ForegroundColor Red; $ok = $false
    } else { Write-Host "  ok  an empty dump is rejected" }

    if (-not (Test-DumpValid -Raw $empty)) {
        Write-Host "FAIL a dump with content was rejected" -ForegroundColor Red; $ok = $false
    } else { Write-Host "  ok  a dump with content is accepted" }

    if (-not $ok) { exit 1 }
    Write-Host "Self-test passed." -ForegroundColor Green
    exit 0
}

# Newest first, but validity decides. mtime reflects the last reload or
# logout, not the last /apidump.
$candidates = @(Get-ChildItem -Path $WtfAccountPath -Recurse -Filter "ForeverAPIDump.lua" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)

if ($candidates.Count -eq 0) {
    throw "No ForeverAPIDump.lua under $WtfAccountPath. Deploy the addon, then run /apidump and /reload in game."
}

$sv = $null
$raw = $null
foreach ($c in $candidates) {
    $text = Get-Content -Raw -Path $c.FullName
    if (Test-DumpValid -Raw $text) { $sv = $c; $raw = $text; break }
    Write-Host "Skipping $($c.FullName)" -ForegroundColor DarkYellow
    Write-Host "  written $($c.LastWriteTime) but holds no dump - that session reloaded without /apidump." -ForegroundColor DarkYellow
}

if (-not $sv) {
    throw ("Found $($candidates.Count) ForeverAPIDump.lua file(s), none containing a dump. " +
           "In game: /apidump then /reload, and convert before the next plain reload overwrites it.")
}

Write-Host "Reading $($sv.FullName)" -ForegroundColor Cyan

$version   = Get-LuaField -Raw $raw -Name "version"
$build     = Get-LuaField -Raw $raw -Name "build"
$buildDate = Get-LuaField -Raw $raw -Name "buildDate"
$toc       = Get-LuaField -Raw $raw -Name "tocVersion"
$projectID = Get-LuaField -Raw $raw -Name "projectID"
$generated = Get-LuaField -Raw $raw -Name "generated"

if (-not $version -or -not $build) {
    throw "Dump has no client version/build block; refusing to write an artifact that cannot be dated."
}

$sections = [ordered]@{}
foreach ($title in $SECTION_KEYS.Keys) {
    $sections[$title] = Get-LuaArray -Raw $raw -Name $SECTION_KEYS[$title]
    Write-Host ("  {0,-42} {1,6}" -f $title, $sections[$title].Count)
}
if ($sections["Documented functions"].Count -eq 0) {
    Write-Warning "0 documented functions - the APIDocumentation pass failed. Check APIDocumentation_LoadUI."
}

$stamp = "$version.$build"
$out = Join-Path $OutDir "forever-api-$stamp.md"

$existing = @(Get-ChildItem -Path $OutDir -Filter "forever-api-*.md" -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -ne "forever-api-$stamp.md" })
if ($existing.Count -gt 0) {
    Write-Host ""
    Write-Host "Build changed: $($existing.Name -join ', ') is a different build than $stamp." -ForegroundColor Yellow
    Write-Host "Delete the old artifact once nothing references it." -ForegroundColor Yellow
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
Add-Line "Measured on the client, not copied from a wiki. Several passes, because none is complete alone:"
Add-Line ""
Add-Line "| section | count | what it is |"
Add-Line "|---|---:|---|"
Add-Line "| Documented functions | $($sections['Documented functions'].Count) | ``APIDocumentation``: full signatures, argument order, ``optional`` markers, return types. A trailing ``[System]`` marks a method of that script object rather than a global. |"
Add-Line "| Documented events | $($sections['Documented events'].Count) | ``RegisterEvent`` name, documented name, payload |"
Add-Line "| Documented tables | $($sections['Documented tables (enums and structures)'].Count) | enumerations with values, structures with fields |"
Add-Line "| Widget methods | $($sections['Widget methods'].Count) | methods off each widget type's metatable — the surface no ``_G`` walk can see |"
Add-Line "| Global functions | $($sections['Global functions'].Count) | ``_G`` walk — the legacy surface the docs omit (``GetCVar``, ``CreateFrame``, …) |"
Add-Line "| Namespace functions | $($sections['Namespace functions'].Count) | every ``C_*`` table's members, plus the prefix-less ones like ``GameEvent`` |"
Add-Line "| Namespace candidates | $($sections['Namespace candidates (names only)'].Count) | other global tables with callable members — names only, since loaded addons live here too |"
Add-Line ""
Add-Line "**Presence is not a contract.** This says a name exists and what shape it declares. It does not"
Add-Line "say the underlying system is wired up on a Vanilla-content client: ``test_cameraOverShoulder``"
Add-Line "accepts a write, reads back, and moves the camera not at all. Probe behaviour before building on it."
Add-Line ""

foreach ($title in $sections.Keys) {
    Add-Line "---"
    Add-Line ""
    Add-Line "## $title ($($sections[$title].Count))"
    Add-Line ""
    Add-Line '```'
    foreach ($line in $sections[$title]) { Add-Line $line }
    Add-Line '```'
    Add-Line ""
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }
Set-Content -Path $out -Value $sb.ToString() -Encoding UTF8 -NoNewline

$size = (Get-Item $out).Length / 1MB
Write-Host ""
Write-Host ("Wrote {0} ({1:N1} MB)" -f $out, $size) -ForegroundColor Green
