<#
.SYNOPSIS
    Turn staged screenshots into addon-ready cutouts, and write the manifest.

.DESCRIPTION
    An addon cannot write image files, so the matte has to happen outside the
    game. This is that step, reduced to one command: it runs the converter,
    files the TGA under the addon's Media\Cutouts, and regenerates the Lua
    manifest the Roster scene reads.

    With -Watch it sits on the Screenshots folder and does all of that the
    moment a new pair appears, so the in-game flow is just:

        log in on an alt  ->  /asrender  ->  done

    The heavy per-pixel work stays in Python (Pillow): the same loop written in
    PowerShell takes minutes per image rather than seconds.

.PARAMETER Watch
    Keep running and convert each new pair as it is captured. Ctrl-C to stop.

.PARAMETER Shots
    The client's Screenshots folder. Defaults to the standard beta install.

.PARAMETER AddOnsPath
    Where to file the finished TGA. Defaults to the standard beta install.

.EXAMPLE
    pwsh Tools/RenderCutout/Update-Cutouts.ps1
    pwsh Tools/RenderCutout/Update-Cutouts.ps1 -Watch
#>
[CmdletBinding()]
param(
    [switch] $Watch,
    [string] $Shots = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Screenshots",
    [string] $AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns"
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$converter = Join-Path $here 'make-cutout.py'
$outDir = Join-Path $here 'out'
# The cutouts and their manifest live in their OWN addon folder, generated
# entirely by this script. Two reasons, both learned the hard way:
#
#   * A Lua file dropped into AltStable/ is never loaded - it has to be listed
#     in the .toc, and a generated file cannot be, because it does not exist in
#     the repo. That is why every portrait was missing on the first run.
#   * deploy.ps1 copies the repo over the client, so anything generated that
#     lives inside AltStable/ is destroyed on the next deploy.
#
# A separate folder is loaded by the client on its own, survives every deploy,
# and can be deleted wholesale to start over.
$cutoutAddon = Join-Path $AddOnsPath 'AltStableCutouts'
$mediaDir = Join-Path $cutoutAddon 'Cutouts'
$manifest = Join-Path $cutoutAddon 'CutoutManifest.lua'
$cutoutToc = Join-Path $cutoutAddon 'AltStableCutouts.toc'

function Test-Prereqs {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { throw "python is not on PATH - the matte needs it (with Pillow)" }
    & python -c "import PIL" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Pillow is missing:  python -m pip install pillow" }
    if (-not (Test-Path $converter)) { throw "converter not found at $converter" }
}

# Convert everything outstanding and file each cutout where the addon can load
# it. Deliberately not "the newest one": a watcher can miss a pair while it was
# not running, and a character whose portrait never appears is a worse failure
# than a few seconds of extra work.
function Convert-Newest {
    $before = @(Get-ChildItem $outDir -Filter *.tga -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Name)

    & python $converter --shots $Shots --all
    if ($LASTEXITCODE -ne 0) { Write-Warning "converter failed"; return }

    New-Item -ItemType Directory -Force -Path $mediaDir | Out-Null
    Write-Toc
    $made = @(Get-ChildItem $outDir -Filter *.tga -ErrorAction SilentlyContinue)
    if (-not $made) { Write-Warning "no TGA produced"; return }

    foreach ($tga in $made) {
        Copy-Item $tga.FullName (Join-Path $mediaDir $tga.Name) -Force
        $tag = if ($before -notcontains $tga.Name) { "  (new)" } else { "" }
        Write-Host ("  filed -> {0}{1}" -f $tga.Name, $tag) -ForegroundColor Green
    }
    Write-Manifest
}

# The .toc that makes the folder an addon. Written once and left alone.
function Write-Toc {
    if (Test-Path $cutoutToc) { return }
    $toc = @"
## Interface: 16001
## Title: AltStable Cutouts
## Notes: Character portraits captured locally by AltStable. GENERATED - regenerate with Tools/RenderCutout/Update-Cutouts.ps1, or delete this folder to start over.
## Author: generated
## Version: 1

CutoutManifest.lua
"@
    Set-Content -Path $cutoutToc -Value $toc -Encoding UTF8
    Write-Host ("  created addon -> {0}" -f $cutoutAddon) -ForegroundColor Cyan
    Write-Host "  (new addon folder: /reload will not pick it up, restart the client once)" -ForegroundColor DarkGray
}

# The manifest is regenerated wholesale from what is on disk, so deleting a TGA
# is all it takes to retire a character - no second place to edit.
function Write-Manifest {
    $entries = foreach ($tga in (Get-ChildItem $mediaDir -Filter *.tga -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $slug = [IO.Path]::GetFileNameWithoutExtension($tga.Name)
        $dims = & python -c @"
import sys
from PIL import Image
im = Image.open(r'$($tga.FullName)')
bbox = im.convert('RGBA').getbbox()
print(bbox[2]-bbox[0], bbox[3]-bbox[1], im.size[0], im.size[1])
"@
        $w, $h, $tw, $th = $dims -split '\s+'
        "    ['$slug'] = { file = [[Interface\AddOns\AltStableCutouts\Cutouts\$($tga.Name)]], w = $w, h = $h, texw = $tw, texh = $th },"
    }

    $lua = @"
-- CutoutManifest.lua - GENERATED by Tools/RenderCutout/Update-Cutouts.ps1
-- Part of the AltStableCutouts addon, which exists only on this machine.
--
-- One entry per character cutout on disk. w/h are the CONTENT size; texw/texh
-- are the power-of-two canvas the image sits in the top-left of, so the UI can
-- crop back to the figure. Regenerated wholesale: delete a TGA to retire a
-- character, do not hand-edit this file.
--
-- Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

AltStableCutoutManifest = {
$($entries -join "`n")
}
"@
    Set-Content -Path $manifest -Value $lua -Encoding UTF8
    Write-Host ("  manifest -> {0}" -f $manifest) -ForegroundColor Green
}

Test-Prereqs

if (-not $Watch) {
    Convert-Newest
    return
}

Write-Host "Watching $Shots - capture with /asrender in game. Ctrl-C to stop." -ForegroundColor Cyan
Write-Host "A new pair converts once the game writes its record (on /reload or logout)." -ForegroundColor DarkGray

# Deliberately NOT a "seen" list.
#
# A screenshot pair appears the moment it is taken, but the addon's record of
# WHICH CHARACTER it shows is only written when the client flushes
# SavedVariables - on /reload or logout. Marking files as seen on sight meant a
# fresh pair was converted once, skipped for want of metadata, and never
# retried: the later flush creates no new screenshot, so nothing woke the
# watcher again. The promised capture-to-portrait path quietly did not happen.
#
# So the trigger is "anything changed", and the converter is left to decide what
# it can do. It deletes what it converts, so an unconvertible pair simply stays
# on disk and is retried the next time something moves - which the flush itself
# now counts as.
function Get-State {
    $shots = @(Get-ChildItem $Shots -Filter *.tga -ErrorAction SilentlyContinue |
               ForEach-Object { "$($_.Name):$($_.Length)" })
    $stores = @(Get-ChildItem (Split-Path $Shots -Parent) -Recurse -Filter AltStableProbe.lua -ErrorAction SilentlyContinue |
                ForEach-Object { "$($_.FullName):$($_.LastWriteTimeUtc.Ticks)" })
    return (($shots + $stores) -join "|")
}

$last = Get-State
while ($true) {
    Start-Sleep -Seconds 2
    $now = Get-State
    if ($now -eq $last) { continue }
    $last = $now

    # A capture is a PAIR, and both halves must have landed.
    $pending = @(Get-ChildItem $Shots -Filter *.tga -ErrorAction SilentlyContinue)
    if ($pending.Count -lt 2) { continue }

    Write-Host ("{0} staged screenshot(s) - converting what has a record" -f $pending.Count)
    Convert-Newest
    $last = Get-State        # the converter deletes what it used
}
