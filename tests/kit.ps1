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

    Run directly, it compares two pins (a pin bump, WowTestKit's
    docs/ADOPTING.md section 3):

        pwsh tests/kit.ps1 -Compare HEAD                 # the pin HEAD committed
        pwsh tests/kit.ps1 -Compare <old kit sha>        # this pin, another sha=
        pwsh tests/kit.ps1 -Compare main -Snapshot <script.lua> [-Lua <lua.exe>]

    It runs tests/run.ps1 with the old pin, then with tests/kit.pin as it is,
    and prints the test files whose result line differs, then whether the load
    snapshot (the -Snapshot script's output) is identical. -Compare <commit of
    this repo> takes that commit's whole tests/kit.pin (sha, build, api); a
    40-hex sha that is no commit here replaces only sha=. The old pin is
    written into tests/kit.pin for its run and the file is put back byte for
    byte after it; an edit made to it meanwhile is kept, the pin as it was
    saved in the logs, and the comparison stops (exit 2). tests/kit.pin.compare-lock, created atomically before the
    pin is read and removed after both runs, makes a second -Compare refuse
    to start: it says whether the first is still running, or stopped, and
    then what to do. tests/kit.pin.compare-backup holds the pin while it is
    changed, and exists only once complete. Each side's full output
    is kept in a WowTestKit-compare-<time>-<pid> folder in %TEMP%. Exit 0: nothing
    differs and every run passed; 1: something differs, or a run failed (its
    identical lines prove nothing); 2: the comparison could not run.
#>

# A pin's name=value pairs. A trailing " # comment" is dropped; the last line
# for a name counts.
function ConvertFrom-WowTestKitPin {
    param([string[]]$Lines)
    $pin = @{}
    $Lines | ForEach-Object {
        $line = $_ -replace '\s+#.*$', ''
        if ($line -match '^\s*(\w+)\s*=\s*(.*?)\s*$') { $pin[$Matches[1]] = $Matches[2] }
    }
    return $pin
}

function Get-WowTestKit {
    param([Parameter(Mandatory)][string]$RepoRoot, [switch]$KitDev)

    $pin = ConvertFrom-WowTestKitPin (Get-Content (Join-Path $RepoRoot "tests\kit.pin"))
    if (-not $pin.sha -or -not $pin.build) { throw "tests\kit.pin needs sha= and build=" }
    if ($pin.sha -cnotmatch '^[0-9a-f]{40}$') { throw "tests\kit.pin needs a 40-hex sha=" }

    if ($KitDev) {
        $dir = if ($env:WOWTESTKIT_DEV) { $env:WOWTESTKIT_DEV } else { Join-Path (Split-Path -Parent $RepoRoot) "WowTestKit" }
        if (-not (Test-Path (Join-Path $dir "kit.lua"))) { throw "-KitDev: no WowTestKit working copy at $dir" }
        Write-Host "WowTestKit: DEV working copy $dir, NOT the pin $($pin.sha.Substring(0, 7))" -ForegroundColor Yellow
    } else {
        $cacheRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "WowTestKit"))
        $dir = [IO.Path]::GetFullPath((Join-Path $cacheRoot $pin.sha))
        if ([IO.Path]::GetDirectoryName($dir) -ne $cacheRoot) { throw "Invalid WowTestKit cache path: $dir" }
        foreach ($path in $cacheRoot, $dir) {
            $item = Get-Item -Force -LiteralPath $path -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Refusing a linked WowTestKit cache path: $path"
            }
        }
        $head = $null
        if (Test-Path (Join-Path $dir ".git")) { $head = (git -C $dir rev-parse HEAD 2>$null) }
        if ($head -ne $pin.sha) {
            # Only this cache folder, named after the pin, is ever replaced.
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop }
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

# Each test file's result line in the kit runner's output (scripts/run.ps1):
# "-- test_x.lua " opens a file's output, and the runner's summary closes the
# last one. The result is the file's last non-blank line, as the runner reads
# it, when that is a result line ("<name>: N passed, M failed", a SKIPPED
# line). Otherwise, for a file Lua stopped with an error (its last line is the
# traceback's), it is "error: <message>", from Lua's own "lua: " line, not
# one a test printed. Returns @{ Files = ordered
# name -> line; Summary = line; Ran = the file count the summary gives }.
function Get-WowTestKitResults {
    param([string[]]$Lines)
    $errorRx = '^(.*[\\/])?lua(5\.1)?(\.exe)?: (.+)$'
    $resultRx = '^(.+: [0-9]+ passed, [0-9]+ failed|.+: SKIPPED \(.+\)|SKIPPED: .+)$'
    $summaryRx = '^(All [0-9]+ test files passed|[0-9]+ of [0-9]+ test file\(s\) FAILED|No tests/test_\*\.lua files found)'
    $files = [ordered]@{}
    $summary = $null
    $file = $null
    $body = [Collections.Generic.List[string]]::new()
    $close = {
        if (-not $file) { return }
        $last = $body | Where-Object { $_.Trim() } | Select-Object -Last 1
        $last = if ($last) { $last.Trim() }
        # Lua's own error line starts with the interpreter's path, as the runner
        # passes it (C:\...\lua.exe, /usr/bin/lua5.1): a test's own "lua: ..."
        # print doesn't, and stdout and stderr arrive in no fixed order. Failing
        # that (a bare "lua"), the last "lua: " line.
        $errors = @($body | Where-Object { $_ -cmatch $errorRx })
        $e = $errors | Where-Object { $_ -cmatch '^(.*[\\/]lua|lua5\.1|lua\.exe)' } | Select-Object -Last 1
        if (-not $e) { $e = $errors | Select-Object -Last 1 }
        $files[$file] = if ($last -cmatch $resultRx) { $last }
            elseif ($e) { "error: " + ($e -creplace $errorRx, '$4').Trim() }
            elseif ($last) { $last }
            else { "(no output)" }
    }
    foreach ($line in $Lines) {
        # A file that printed nothing leaves the next "-- test_y.lua " on its line.
        # A name may hold spaces ("test_a b.lua"): it ends at the first ".lua ".
        while ($line -cmatch '^-- (test_.*?\.lua)(?: (.*))?$') {
            $next, $line = $Matches[1], "$($Matches[2])"   # before $close's own -cmatch resets $Matches
            . $close
            $file = $next
            $body.Clear()
        }
        if ($line -cmatch $summaryRx) { . $close; $file = $null; $summary = $line.Trim(); continue }
        if ($file) { $body.Add($line) }
    }
    . $close
    # How many files the runner says it ran, to check none was missed.
    $ran = if ($summary -cmatch '^All ([0-9]+) test files' -or $summary -cmatch '^[0-9]+ of ([0-9]+) test file') { [int]$Matches[1] }
    return @{ Files = $files; Summary = $summary; Ran = $ran }
}

# -Compare's lock, holding $Content: created with CreateNew, atomic on every
# system (O_EXCL off Windows), so only one -Compare makes it. $false: it
# exists already. Not shared until written (on Windows, a reader meanwhile
# can't open it); a reader that sees it still empty finds no process named,
# and asks the user to check rather than calling it stopped.
function New-WowTestKitLock {
    param([string]$Path, [byte[]]$Content)
    try { $s = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
    catch [IO.IOException] {
        if (Test-Path -LiteralPath $Path) { return $false }
        throw
    }
    try { $s.Write($Content, 0, $Content.Length) } finally { $s.Dispose() }
    return $true
}

# A comparison's own log folder in $Root: the time, this process's id, and a
# number if that's taken. Created without -Force, so two comparisons never
# share one, even started in the same second (#121).
function New-WowTestKitLogDir {
    param([string]$Stamp = (Get-Date -Format "yyyyMMdd-HHmmss"), [string]$Root = [IO.Path]::GetTempPath())
    for ($n = 1; ; $n++) {
        $dir = Join-Path $Root ("WowTestKit-compare-$Stamp-$PID" + $(if ($n -gt 1) { "-$n" }))
        try { New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null; return $dir }
        catch { if (-not (Test-Path -LiteralPath $dir)) { throw } }
    }
}

# Replaces the pin's bytes $From with $To, the check and the write through one
# handle no other writer can open meanwhile (#121): a save can't land between
# them. On Windows such a save fails instead of being overwritten; elsewhere
# the share mode is advisory, and an editor or git that replaces the file
# writes a new one, which the later checks see. $false, with nothing written:
# the pin doesn't hold $From (or is gone).
function Switch-WowTestKitPin {
    param([string]$Path, [byte[]]$From, [byte[]]$To)
    try { $s = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.FileNotFoundException] { return $false }
    try {
        $ms = [IO.MemoryStream]::new()
        $s.CopyTo($ms)
        if ([Convert]::ToBase64String($ms.ToArray()) -cne [Convert]::ToBase64String($From)) { return $false }
        $s.Position = 0
        $s.SetLength(0)
        $s.Write($To, 0, $To.Length)
        $s.Flush($true)
        return $true
    } finally { $s.Dispose() }
}

function Compare-WowTestKit {
    param(
        [Parameter(Mandatory)][string]$Compare,
        [string]$Snapshot,
        [string]$Lua,
        [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
    )
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    # Forward slashes: [IO.File] doesn't read "\" as a separator off Windows.
    $pinPath = Join-Path $RepoRoot "tests/kit.pin"
    $backup = "$pinPath.compare-backup"
    $lockPath = "$pinPath.compare-lock"
    $runPs1 = Join-Path $RepoRoot "tests/run.ps1"
    if (-not (Test-Path -LiteralPath $runPs1)) { Write-Host "no tests\run.ps1 in $RepoRoot" -ForegroundColor Red; return 2 }
    $luaExe = if ($Lua) { $Lua } else { "C:\Program Files (x86)\Lua\5.1\lua.exe" }
    if ($Snapshot) {
        $Snapshot = (Resolve-Path -LiteralPath $Snapshot -ErrorAction SilentlyContinue).Path
        if (-not $Snapshot) { Write-Host "-Snapshot: no such file" -ForegroundColor Red; return 2 }
        if (-not (Get-Command $luaExe -ErrorAction SilentlyContinue)) { Write-Host "Lua 5.1 not found at $luaExe (pass -Lua <path>)" -ForegroundColor Red; return 2 }
    }
    if ($Compare -cmatch '^-') { Write-Host "-Compare takes a commit or a sha, not '$Compare'" -ForegroundColor Red; return 2 }

    # The lock: created atomically before the pin is read, and kept until both
    # runs are done, so a second -Compare can neither read this one's old pin
    # as "the current pin" nor swap the pin under its runs. It names its
    # process, so a refusal can tell a running -Compare from one that stopped.
    # The backup is written whole, then renamed into place, before the pin is
    # changed: when it exists, it is the complete pin as it was.
    $bytesOf = { param($p) if (Test-Path -LiteralPath $p) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) } }
    $backupAdvice = {
        if (-not (Test-Path -LiteralPath $backup)) { return "it stopped before it changed tests\kit.pin" }
        if ((& $bytesOf $backup) -ceq (& $bytesOf $pinPath)) { return "tests\kit.pin is as it was: delete $backup" }
        "it stopped with its old pin in tests\kit.pin, and $backup holds the pin as it was: move it over tests\kit.pin"
    }
    $mine = [Text.Encoding]::ASCII.GetBytes("pid=$PID start=$((Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks)`n")
    if (-not (New-WowTestKitLock $lockPath $mine)) {
        # Unreadable: taken as running. Naming no process (no -Compare writes
        # one so, but a hand or another tool might): nothing to check, so
        # whether one runs is the user's to confirm.
        $holder = try {
            $r = [IO.StreamReader]::new([IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try { $r.ReadToEnd() } finally { $r.Dispose() }
        } catch { $null }
        $running, $p, $named = ($null -eq $holder), $null, $false
        if ($holder -cmatch '^pid=([0-9]+) start=([0-9]+)') {
            $named = $true
            $p = Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue
            $start = [long]$Matches[2]
            if ($p) { $running = try { [Math]::Abs($p.StartTime.ToUniversalTime().Ticks - $start) -lt 10000000 } catch { $true } }
        }
        if ($running) {
            Write-Host "Another -Compare is running in this repo$(if ($p) { " (process $($p.Id))" }): wait for it to finish, then run again." -ForegroundColor Red
        } elseif (-not $named) {
            Write-Host "$lockPath names no process to check. Make sure no -Compare is running in this repo; if none is, $(& $backupAdvice). Then delete $lockPath and run again." -ForegroundColor Red
        } else {
            Write-Host "An earlier -Compare left $lockPath and is no longer running: $(& $backupAdvice). Then delete $lockPath and run again." -ForegroundColor Red
        }
        return 2
    }
    # $ours: tests/kit.pin holds the old pin this run wrote, not yet put back.
    # $edited: the switch back found the pin edited.
    $newBytes, $oldBytes, $madeBackup, $logDir, $ours, $edited, $code = $null, $null, $false, $null, $false, $false, $null
    $b64 = { param($b) if ($b -is [byte[]]) { [Convert]::ToBase64String($b) } }
    # The exit code is decided after the cleanup below, which can find an edit.
    try { $code = . {
        if (Test-Path -LiteralPath $backup) {
            Write-Host "$backup is left from an earlier -Compare: $(& $backupAdvice). Then run again." -ForegroundColor Red
            return 2
        }
        $newBytes = [IO.File]::ReadAllBytes($pinPath)
        $partial = "$backup.partial"
        [IO.File]::WriteAllBytes($partial, $newBytes)
        [IO.File]::Move($partial, $backup)
        $madeBackup = $true
        # The old pin: a commit of this repo gives its whole tests/kit.pin; a kit
        # sha replaces sha= in the current one.
        $newLines = @(Get-Content -LiteralPath $pinPath)
        $oldLines, $from, $shaForm = $null, $null, $false
        git -C $RepoRoot rev-parse --verify --quiet "$Compare^{commit}" *> $null
        if ($LASTEXITCODE -eq 0) {
            $shown = @(git -C $RepoRoot show "${Compare}:tests/kit.pin" 2>$null)
            if ($LASTEXITCODE -eq 0) { $oldLines, $from = $shown, "${Compare}:tests/kit.pin" }
        }
        if ($null -eq $oldLines) {
            if ($Compare -cnotmatch '^[0-9a-f]{40}$') {
                Write-Host "-Compare takes a commit of this repo with a tests/kit.pin (HEAD, main, ...) or the old kit sha (40 hex): '$Compare' is neither" -ForegroundColor Red
                return 2
            }
            $oldLines = @("sha=$Compare") + @($newLines | Where-Object { $_ -notmatch '^\s*sha\s*=' })
            $from = "tests/kit.pin with sha=$($Compare.Substring(0, 7))"
            $shaForm = $true
        }
        $old = ConvertFrom-WowTestKitPin $oldLines
        $new = ConvertFrom-WowTestKitPin $newLines
        $describe = { param($p) "sha $(if ($p.sha) { $p.sha.Substring(0, [Math]::Min(7, $p.sha.Length)) } else { '?' }), build $($p.build), api $($p.api)" }
        Write-Host "old pin: $(& $describe $old) ($from)"
        Write-Host "new pin: $(& $describe $new) (tests/kit.pin)"
        if ($old.sha -ceq $new.sha -and $old.build -ceq $new.build -and $old.api -ceq $new.api) {
            Write-Host "The two pins are the same: nothing to compare." -ForegroundColor Red
            return 2
        }

        $pwsh = (Get-Process -Id $PID).Path
        $logDir = New-WowTestKitLogDir
        $savedKit = $env:WOWTESTKIT
        # One side: tests/run.ps1 as the owner runs it, then the snapshot script
        # against the same kit.
        $runSide = {
            param($name)
            Write-Host "-- $name pin: tests\run.ps1" -ForegroundColor Cyan
            $kit = Get-WowTestKit -RepoRoot $RepoRoot
            $build = (ConvertFrom-WowTestKitPin (Get-Content -LiteralPath $pinPath)).build
            if ($shaForm -and $name -eq 'old' -and -not (Test-Path -LiteralPath (Join-Path $kit "data/forever-$build"))) {
                Write-Host "   the kit at this sha has no data for build ${build}: -Compare <a commit of this repo> takes that commit's build too" -ForegroundColor Yellow
            }
            $runArgs = @('-NoProfile', '-File', $runPs1)
            if ($Lua) { $runArgs += '-Lua', $Lua }
            Push-Location $RepoRoot
            try {
                $out = @(& $pwsh @runArgs 2>&1 | ForEach-Object { "$_" -replace "\x1b\[[0-9;?]*[A-Za-z]", '' })
                $code = $LASTEXITCODE
                $snap, $snapCode = $null, $null
                if ($Snapshot) {
                    $env:WOWTESTKIT = $kit
                    $snap = @(& $luaExe $Snapshot 2>&1 | ForEach-Object { "$_" })
                    $snapCode = $LASTEXITCODE
                    $snap | Set-Content -LiteralPath (Join-Path $logDir "$name-snapshot.txt")
                }
            } finally { Pop-Location }
            $out | Set-Content -LiteralPath (Join-Path $logDir "$name-tests.txt")
            $r = Get-WowTestKitResults $out
            Write-Host "   exit $code, $($r.Files.Count) test files: $($r.Summary)"
            @{ Results = $r; Code = $code; Snapshot = $snap; SnapshotCode = $snapCode }
        }

        # The old pin goes in only over the pin read at the start, and is put
        # back only while it still holds the old pin this run wrote: anything
        # else is an edit made meanwhile (an editor, a branch switch, even to
        # those same bytes), kept, and the comparison stops (#121). The cleanup
        # below says so.
        $oldBytes = [Text.UTF8Encoding]::new($false).GetBytes(($oldLines -join "`n") + "`n")
        try {
            try {
                if (-not (Switch-WowTestKitPin $pinPath $newBytes $oldBytes)) { return 2 }
                $ours = $true
                $oldSide = & $runSide "old"
            } finally {
                # $ours stays set only if the switch back fails. A refused one
                # is an edit, even when the pin now holds the startup bytes
                # again (a git restore): the old run may have read them.
                if ($ours) { $edited = -not (Switch-WowTestKitPin $pinPath $oldBytes $newBytes); $ours = $false }
            }
            # A later edit is the check after the new run's, or the cleanup's.
            if ($edited) { return 2 }
            $newSide = & $runSide "new"
            if ((& $bytesOf $pinPath) -cne (& $b64 $newBytes)) { return 2 }
        } finally { $env:WOWTESTKIT = $savedKit }

        # The result lines that differ, in the old run's order.
        $o, $n = $oldSide.Results, $newSide.Results
        $names = @($o.Files.Keys) + @($n.Files.Keys | Where-Object { -not $o.Files.Contains($_) })
        $differ = 0
        Write-Host ""
        foreach ($f in $names) {
            $a = if ($o.Files.Contains($f)) { $o.Files[$f] } else { "(not run)" }
            $b = if ($n.Files.Contains($f)) { $n.Files[$f] } else { "(not run)" }
            if ($a -cne $b) {
                $differ++
                Write-Host $f -ForegroundColor Yellow
                Write-Host "  old: $a"
                Write-Host "  new: $b"
            }
        }
        if ($oldSide.Code -ne $newSide.Code -or $o.Summary -cne $n.Summary) {
            $differ++
            Write-Host "summary" -ForegroundColor Yellow
            Write-Host "  old: $($o.Summary) (exit $($oldSide.Code))"
            Write-Host "  new: $($n.Summary) (exit $($newSide.Code))"
        }
        $same = $names.Count - @($names | Where-Object { ($o.Files[$_]) -cne ($n.Files[$_]) }).Count
        $color = if ($differ) { "Yellow" } else { "Green" }
        Write-Host "result lines: $same of $($names.Count) test files identical" -ForegroundColor $color

        if (-not $Snapshot) {
            Write-Host "load snapshot: not compared (pass -Snapshot <script.lua>: docs/ADOPTING.md, section 1)" -ForegroundColor Yellow
        } else {
            $sa, $sb = @($oldSide.Snapshot), @($newSide.Snapshot)
            $sameSnap = $oldSide.SnapshotCode -eq $newSide.SnapshotCode -and $sa.Count -eq $sb.Count
            for ($i = 0; $sameSnap -and $i -lt $sa.Count; $i++) { if ($sa[$i] -cne $sb[$i]) { $sameSnap = $false } }
            if ($sameSnap) {
                Write-Host "load snapshot: identical ($($sa.Count) lines, exit $($newSide.SnapshotCode))" -ForegroundColor Green
            } else {
                $differ++
                Write-Host "load snapshot: DIFFERS (old exit $($oldSide.SnapshotCode), $($sa.Count) lines; new exit $($newSide.SnapshotCode), $($sb.Count) lines)" -ForegroundColor Yellow
                # In order: the lines between the common start and the common end.
                $pre = 0
                while ($pre -lt $sa.Count -and $pre -lt $sb.Count -and $sa[$pre] -ceq $sb[$pre]) { $pre++ }
                $post = 0
                while ($post -lt ($sa.Count - $pre) -and $post -lt ($sb.Count - $pre) -and
                    $sa[$sa.Count - 1 - $post] -ceq $sb[$sb.Count - 1 - $post]) { $post++ }
                if ($pre -lt $sa.Count -or $pre -lt $sb.Count) { Write-Host "  from line $($pre + 1):" }
                foreach ($side in @(@('old', $sa), @('new', $sb))) {
                    $lines = @($side[1] | Select-Object -Skip $pre -First ($side[1].Count - $pre - $post))
                    $lines | Select-Object -First 20 | ForEach-Object { Write-Host "  $($side[0]): $_" }
                    if ($lines.Count -gt 20) { Write-Host "  $($side[0]): ... and $($lines.Count - 20) more" }
                }
            }
        }
        # Identical lines from a run that failed prove nothing about the bump.
        $broken = @()
        foreach ($s in @(@('old', $oldSide), @('new', $newSide))) {
            if ($s[1].Code -ne 0) { $broken += "$($s[0]) tests (exit $($s[1].Code))" }
            if ($Snapshot -and $s[1].SnapshotCode -ne 0) { $broken += "$($s[0]) snapshot (exit $($s[1].SnapshotCode))" }
        # A result the parser missed must not read as "identical".
        $r = $s[1].Results
        if ($null -eq $r.Ran) { $broken += "$($s[0]) tests (no runner summary in the output)" }
        elseif ($r.Files.Count -ne $r.Ran) { $broken += "$($s[0]) tests (read $($r.Files.Count) of the $($r.Ran) files' results)" }
        }
        if ($broken) {
            Write-Host "FAILED: $($broken -join ', '). The comparison means little until both pass: see the full outputs." -ForegroundColor Red
        }
        Write-Host "full outputs: $logDir" -ForegroundColor DarkGray
        if ($differ -or $broken) { return 1 } else { return 0 }
    } } finally {
        # Released only once the pin is back: until then the lock and the backup
        # stay, and the next -Compare says what to do.
        $now = if ($madeBackup) { & $bytesOf $pinPath }
        if (-not $madeBackup) {
            Remove-Item -LiteralPath $lockPath   # the pin was never changed
        } elseif ($ours -and $now -ceq (& $b64 $oldBytes)) {
            Write-Host "tests\kit.pin could not be put back: move $backup over it, then delete $lockPath" -ForegroundColor Red
        } elseif (-not $edited -and $now -ceq (& $b64 $newBytes)) {
            Remove-Item -LiteralPath $backup
            Remove-Item -LiteralPath $lockPath
        } else {
            # Someone else's edit (or a restore it refused), kept. The pin as it
            # was goes to this comparison's logs, so nothing is lost.
            if (-not $logDir) { $logDir = New-WowTestKitLogDir }
            $was = Join-Path $logDir "kit.pin.before"
            [IO.File]::WriteAllBytes($was, $newBytes)
            Remove-Item -LiteralPath $backup
            Remove-Item -LiteralPath $lockPath
            Write-Host "tests\kit.pin was changed while -Compare ran: it is left as it is, and the comparison stopped. tests\kit.pin as it was before is in $was" -ForegroundColor Red
            $code = 2   # even if both runs finished: they may have read the edit
        }
    }
    return $code
}

# Run directly (not dot-sourced): the comparison.
if ($MyInvocation.InvocationName -ne '.') {
    if ($args.Count -eq 0) {
        Write-Host "usage: pwsh tests/kit.ps1 -Compare <commit of this repo | old kit sha> [-Snapshot <script.lua>] [-Lua <lua.exe>]"
        exit 2
    }
    try { $code = Compare-WowTestKit @args } catch { Write-Host "-Compare: $_" -ForegroundColor Red; $code = 2 }
    exit $code
}
