<#
    Compare-Dumps.ps1 — what changed between two builds' API dumps.

    Step 2 of "When the client updates" (docs/RUNBOOK.md). Compares the sections
    the client itself documents, line by line, and prints what was added and
    removed in each.

    Two sections are counted but not listed: "Global functions" and
    "Namespace candidates". Both come from walking _G, so they pick up whatever
    addons happened to be loaded when /apidump ran - a diff there is mostly
    Attune, RXPGuides and our own probes coming and going, not the client.

    Usage:
        pwsh Tools/ForeverAPIDump/Compare-Dumps.ps1              # the two newest dumps
        pwsh Tools/ForeverAPIDump/Compare-Dumps.ps1 -Old <file> -New <file>
        pwsh Tools/ForeverAPIDump/Compare-Dumps.ps1 -Max 0        # list every change

    Exit code 0 either way; "no change" is printed per section so a summary can
    be quoted in docs/forever-api-notes.md as is.
#>

param(
    [string]$Old,
    [string]$New,
    [string]$Dir = "C:\Projects\References",
    [int]$Max = 60
)

$ErrorActionPreference = "Stop"

$Listed   = @("Documented functions", "Documented events", "Documented tables", "Widget methods", "Namespace functions")
$Volatile = @("Global functions", "Namespace candidates")

function Get-Build([string]$path) {
    # forever-api-1.60.1.70124.md -> [version] 1.60.1.70124, for a numeric sort
    if ((Split-Path $path -Leaf) -match 'forever-api-(\d+\.\d+\.\d+\.\d+)\.md$') { return [version]$Matches[1] }
    return $null
}

if (-not $Old -or -not $New) {
    $dumps = Get-ChildItem -Path $Dir -Filter "forever-api-*.md" |
        Where-Object { Get-Build $_.FullName } |
        Sort-Object { Get-Build $_.FullName }
    if ($dumps.Count -lt 2) { throw "Need two forever-api-<build>.md files in $Dir, found $($dumps.Count)." }
    if (-not $New) { $New = $dumps[-1].FullName }
    if (-not $Old) { $Old = $dumps[-2].FullName }
}

# Section name (without its "(count)") -> the lines inside its code fence.
function Read-Sections([string]$path) {
    $sections = @{}
    $name = $null; $inFence = $false; $lines = $null
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match '^## (.+?) \(\d+\)\s*$') {
            # "Documented tables (enums and structures)" -> "Documented tables"
            $name = $Matches[1] -replace ' \([^)]*\)$', ''
            $lines = New-Object System.Collections.Generic.List[string]
            $sections[$name] = $lines
            $inFence = $false
            continue
        }
        if (-not $name) { continue }
        if ($line.StartsWith('```')) { $inFence = -not $inFence; continue }
        if ($inFence -and $line.Trim()) { $lines.Add($line) }
    }
    return $sections
}

$a = Read-Sections $Old
$b = Read-Sections $New
"Old: $(Split-Path $Old -Leaf)"
"New: $(Split-Path $New -Leaf)"
""

$changed = $false
foreach ($section in $Listed + $Volatile) {
    $oldSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($a[$section]), [StringComparer]::Ordinal)
    $newSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($b[$section]), [StringComparer]::Ordinal)
    if (-not $a.ContainsKey($section) -or -not $b.ContainsKey($section)) {
        "## $section - MISSING in $(if (-not $a.ContainsKey($section)) { 'old' } else { 'new' }) dump"
        $changed = $true
        continue
    }
    $added   = @($b[$section] | Where-Object { -not $oldSet.Contains($_) } | Sort-Object -Unique)
    $removed = @($a[$section] | Where-Object { -not $newSet.Contains($_) } | Sort-Object -Unique)
    $tag = if ($Volatile -contains $section) { " (walks _G: addon noise, not listed)" } else { "" }
    if ($added.Count -eq 0 -and $removed.Count -eq 0) {
        "## $section - no change ($($newSet.Count))$tag"
        continue
    }
    "## $section - +$($added.Count) -$($removed.Count)$tag"
    if ($Volatile -contains $section) { continue }
    $changed = $true
    foreach ($pair in @(@('+', $added), @('-', $removed))) {
        $sign = $pair[0]; $items = $pair[1]
        $shown = if ($Max -gt 0) { $items | Select-Object -First $Max } else { $items }
        foreach ($i in $shown) { "  $sign $i" }
        if ($Max -gt 0 -and $items.Count -gt $Max) { "  $sign ... $($items.Count - $Max) more (-Max 0 lists all)" }
    }
}
""
if ($changed) { "Documented surface CHANGED - read the lists above against docs/forever-api-notes.md." }
else { "Documented surface identical." }
