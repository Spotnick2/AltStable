---
name: client-update
description: Handle a new WoW Forever client build for AltStable - convert the owner's /apidump into C:\Projects\References, diff it against the previous build, verify behaviour and SavedVariables persistence, and prepare the MEASURED_ON_BUILD bump PR. Use when the owner says there is a new build/API bump, "apidump done", "new api build", or the addon's login warning names a build other than MEASURED_ON_BUILD.
version: 1.0.0
allowed-tools: [Bash, Read, Edit, Write, Grep, Glob]
---

# A new Forever client build

The checklist of record is `docs/RUNBOOK.md` → "When the client updates". This skill is how a
session runs it: which parts are the owner's (in game), which are yours, and the traps that have
already caught a session. If the two ever disagree, fix the RUNBOOK and this file together.

## Who does what

| Step | Who | What |
|---|---|---|
| 1. Dump | **owner**, in game | `/apidump`, then `/reload` (the reload flushes it to SavedVariables) |
| 1. Convert | you | `pwsh Tools/ForeverAPIDump/Convert-Dump.ps1` |
| 2. Diff | you | `pwsh Tools/ForeverAPIDump/Compare-Dumps.ps1` |
| 3. Behaviour | **owner** pastes one `/run` line; you judge it | expected values below |
| 4. Persistence | **owner** does a full exit + relaunch; you verify | the probe counters |
| 5. Bump PR | you | four edits, tests, branch, PR (commit/push only when asked) |

## 1. Convert

```
pwsh Tools/ForeverAPIDump/Convert-Dump.ps1
```

It picks the newest `ForeverAPIDump.lua` under `_classic_beta_\WTF\Account\*\SavedVariables`
(whichever account the owner dumped from), prints the section counts and writes
`C:\Projects\References\forever-api-<version>.<build>.md`. "Build changed: … is a different build"
is expected - it lists every older dump. **Never delete old dumps**; that is the owner's call.

If it wrote the *same* build as the newest existing file, the owner has not dumped since the
update (or dumped before `/reload`): say so and stop.

## 2. Diff

```
pwsh Tools/ForeverAPIDump/Compare-Dumps.ps1          # newest two dumps; -Old/-New to choose, -Max 0 for all
```

- Five documented sections are listed line by line: documented functions, events, tables, widget
  methods, namespace functions. **These are the client.**
- "Global functions" and "Namespace candidates" walk `_G` and pick up whatever addons were loaded
  (Attune, RXPGuides, Priestly, the probes). Counted, never listed, never a finding on their own.
- For every documented change, grep the repo (`*.lua`, `tests/wow_stubs.lua`,
  `docs/forever-api-notes.md`) for the affected names. A removed or re-signatured function we call
  is a bug to fix before the bump, not a note.

## 3. Behaviour (the dump proves shape, not behaviour)

The owner pastes the output of the line in RUNBOOK step 3 (currently
`/run print(GetMaxPlayerLevel(), UnitXPMax("player"), GetXPExhaustion(), Enum.BagIndex.Keyring, C_Reputation.GetNumFactions(), type(TooltipDataProcessor))`).
Expected: `60`, a positive number, a number while rested / `nil` when not, `-1`, the character's
faction count, `table`. Anything else: stop and investigate before bumping.

**Chat lines are capped at 255 characters.** Anything longer than one `/run` line does not belong in
chat - add a slash command to `Tools/AltStableProbe` and have the owner run
`pwsh Tools/deploy-probe.ps1` instead.

## 4. Persistence - read it from disk, and read the TIMESTAMPS

The owner runs the probe (deployed by `pwsh Tools/deploy-probe.ps1`). You verify from the files:

```
WTF\Account\<acct>\SavedVariables\AltStableProbe.lua            (+ .bak)   account scope
WTF\Account\<acct>\<Realm>\<Char>\SavedVariables\AltStableProbe.lua        per-character scope
```

Each holds a `loadCount`. It is bumped in memory at load and written at logout/reload.

**The trap (it caught a session on 70058):** a counter going up proves nothing if the client never
exited - a `/reload` keeps the process and the Lua state, so the counter climbs from memory even
with persistence broken. Before believing a rise:

1. Compare the `.bak` mtime (previous write) with the file mtime (this write), and the gap between
   a write and the next load. A write followed by a load **seconds** later is a `/reload`.
2. A full exit shows as a write, then a gap of however long the owner took to relaunch, then the
   next login - and the in-game line `[probe] SavedVariables (account) LOADED - previous
   loadCount=N` where N is the value you last saw on disk. `first ever run - not loaded` means it
   is broken - stop, this is #23 again.

Ask for the owner's `[probe] …` lines from the login after a **full client exit** (Exit Game, wait
for the process to go, relaunch). Lines tagged `[Probe]` with a capital P and "launch #n" are
**PriestlyProbe**, another project's probe - not evidence about AltStable.

## 5. The bump PR

Only after 3 and 4 pass on the new build. Skipped builds need nothing special: bump straight to
the newest measured one and record the intermediate ones as "not measured" if they were never
dumped.

Edits (branch `build-<build>` from `main`):

1. `Config.lua` - `local MEASURED_ON_BUILD = "<build>"`. This is what silences the login warning.
2. `tests/wow_stubs.lua` - `function GetBuildInfo() return "<version>", "<build>", "<client date from the dump header, e.g. Sep 29 2026>", 16001 end`.
3. `docs/RUNBOOK.md` step 3 - the "Expected on <build>" sentence names the new build.
4. `docs/forever-api-notes.md` - a `## Build <version>.<build> (<date>) - <one-line verdict>` section
   next to the other build sections (see `## Build 1.60.1.70009` for the shape): what the diff
   showed (quote Compare-Dumps' summary), the behaviour line as pasted, and the persistence
   evidence (store, `.bak` → file counters, timestamps, that it was a full exit).

Then: `luac -p` on the touched `.lua`, `pwsh tests/run.ps1` green, `pwsh Tools/deploy.ps1`
(pre-approved), and tell the owner it needs a `/reload` (no new files) to drop the warning. Commit,
push and open the PR **only when the owner asks** - and the owner runs every review.

Also update the memory note on SavedVariables persistence if the build changed its status.
