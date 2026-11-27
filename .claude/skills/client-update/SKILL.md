---
name: client-update
description: Handle a new WoW Forever client build for AltStable. A build with the same Interface is a diff, checked centrally - verify only the names it removed or changed. An Interface bump is the full re-check - verify behaviour and prepare the bump PR. Use when the owner says there is a new build/API bump, "apidump done", "new api build", an Interface bump, or an upstream issue names an API the diff changed.
version: 2.0.0
allowed-tools: [Bash, Read, Edit, Write, Grep, Glob]
---

# A new Forever client build

The checklist of record is `docs/RUNBOOK.md` → "When the client updates". This skill is how a
session runs it: which parts are the owner's (in game), which are yours, and the traps that have
already caught a session. If the two ever disagree, fix the RUNBOOK and this file together.

## First: which case is it? (#541)

The shared rule is the root `C:\Projects\WoW\CLAUDE.md`, "Forever API reference and new client
builds": **a new build is a diff; only an Interface bump is a full re-check.** Blizzard ships a
build twice a week or more (22 from 69977 to 71139, all Interface 16001).

- **Same Interface** (the fourth value of `GetBuildInfo()` didn't change): the root session dumps,
  converts and diffs it with the shared `forever-api-dump` skill. This repo is touched only when it
  uses a name the diff removed or changed: that arrives as an upstream issue. Verify **that name**
  (grep `*.lua`, `tests/wow_stubs.lua` and `docs/forever-api-notes.md`; a `/run` line or the probe
  if it needs the client), fix what it breaks, and record the finding with its build in
  `docs/forever-api-notes.md`. No behaviour line, no bump PR. `tests/kit.pin` moves only when
  verifying that name needs the build's kit data.
- **Interface bump** (a new `## Interface:` for the TOCs): the full routine below, even when the
  diff is empty.

Nothing in the addon records or announces the build it was checked on: there is no build
constant and no login warning. `svLoadCheck.build` is a diagnostic stamp, and `/alts status`
shows the running build for bug reports.

## The full routine (Interface bump)

| Step | Who | What |
|---|---|---|
| 1-2. Dump, convert, diff | owner + you | the shared `forever-api-dump` skill (`C:\Projects\WoW\.claude\skills\forever-api-dump\SKILL.md`) |
| 3. Behaviour | **owner** pastes one `/run` line; you judge it | expected values below |
| 4. Persistence | **only if saved data looks lost** - no longer per build | the probe counters |
| 5. Bump PR | you | the edits, tests, branch, PR (commit/push only when asked) |

## 1-2. Dump, convert, diff

Run the shared `forever-api-dump` skill first. It owns the dump, the conversion, the diff and
their traps. The tooling is shared, in `C:\Projects\WoW\References\Tools\ForeverAPIDump\` (run
by full path, never copied here), and serves every project, so a change to it is a change for all
of them. When it reaches its impact step, grep `*.lua`,
`tests/wow_stubs.lua` and `docs/forever-api-notes.md`.

## 3. Behaviour (the dump proves shape, not behaviour)

The owner pastes the output of the line in RUNBOOK step 3 (currently
`/run print(GetMaxPlayerLevel(), UnitXPMax("player"), GetXPExhaustion(), Enum.BagIndex.Keyring, C_Reputation.GetNumFactions(), type(TooltipDataProcessor))`).
Expected: `60`, a positive number, a number while rested / `nil` when not, `-1`, the character's
faction count, `table`. Anything else: stop and investigate before bumping.

**Chat lines are capped at 255 characters.** Anything longer than one `/run` line does not belong in
chat - add a command to `Tools/AltStableProbe` (a ForeverProbe module, `/fp as`; read
`C:\Projects\WoW\References\Docs\PROBES.md` first) and have the owner run
`pwsh Tools/deploy-probe.ps1` instead. Read its results from `AltStableProbe.lua`'s `log` after
the owner's `/reload`; nothing needs pasting. The probe is on demand only: once the results are
read, `pwsh Tools/deploy-probe.ps1 -Remove` takes it out of the live client again.

## 4. Persistence - only when something looks lost

**Not a per-build step any more** (owner, 2026-10-01): #23 was fixed in 70009 and held on 70124
and 70170. Run this only if saved data looks lost after an update. When you do, the method below
still holds - and if the owner has already restarted the client, the files may already prove it
without asking (70170 was proven that way: process start time vs. the `.bak` -> file counters).


The owner runs the probe (deployed by `pwsh Tools/deploy-probe.ps1`). You verify from the files:

```
WTF\Account\<acct>\SavedVariables\AltStableProbe.lua            (+ .bak)   account scope
WTF\Account\<acct>\<Realm>\<Char>\SavedVariables\AltStableProbe.lua        per-character scope
```

Each holds a `loadCount`. It is bumped in memory at load and written at logout/reload.

**The trap (it caught a session on 70058):** a counter going up proves nothing if the client never
exited - a `/reload` keeps the process and the Lua state, so the counter climbs from memory even
with persistence broken. Before believing a rise:

1. **Prove the process restarted.** Read the game's start time:
   ```
   Get-Process WowB | Select-Object Id, StartTime        # PowerShell
   ```
   The last write before the restart (the `.bak`, or the file as you last read it) must be
   **older** than `StartTime`, and the load you are judging must come **after** it. If the owner
   has already quit, their explicit "I exited the game fully" stands in for this. The gap between a
   write and the next load is only a hint - a quick relaunch can be seconds, a slow `/reload` can
   be long - never the proof on its own.
2. **Then compare the counters.** The first write in the new process must hold the last
   pre-restart value + 1. A store that did not load restarts at 1, and the probe's saved `log`
   then holds `SavedVariables (account) did not load - first ever run, or #23 has come back` (or
   the per-character line): that means it is broken - stop, this is #23 again. Check the
   per-character store the same way.

The login check is silent while the stores load, so there is no line to ask the owner for. After
a **full client exit** (Exit Game, wait for the process to go, relaunch) and a `/reload` to write
the files, read the counters and the `log` yourself. Lines from other modules in ForeverProbe's
console (e.g. **PriestlyProbe**) are another project's probe - not evidence about AltStable.

## 5. The bump PR (Interface bump only)

Only after 3 passes on the new Interface's build (and 4, if it was run).

Edits (branch `interface-<interface>` from `main`):

1. Every TOC's `## Interface:` (`AltStable.toc` and each plugin's under `Plugins/`).
2. `tests/wow_stubs.lua` - `function GetBuildInfo() return "<version>", "<build>", "<client date from the dump header, verbatim: a single-digit day keeps its padding, e.g. Oct  5 2026>", <interface> end`.
   No test hard-codes the build: they read it from this stub.
   And `tests/kit.pin`: `build=` the new build and `sha=` a WowTestKit `main` commit that has its
   `data/forever-<build>/` (the forever-api-dump skill's step 4 makes it; until it's merged on
   the kit, keep the older pin and say so in the PR).
3. `docs/RUNBOOK.md` step 3 - the "Expected on <build>" sentence names the build step 3 ran on.
4. `docs/forever-api-notes.md` - a `## Build <version>.<build> (<date>) - <one-line verdict>` section
   after the newest build section (they run oldest first; see `## Build 1.60.1.70009` for the
   shape): what the diff
   showed (quote Compare-Dumps' summary), the behaviour line as pasted, and the persistence
   evidence if step 4 was run.

Then: `luac -p` on the touched `.lua`, `pwsh tests/run.ps1` green, `pwsh Tools/deploy.ps1`
(pre-approved), and tell the owner what needs a `/reload`. Commit, push and open the PR **only
when the owner asks** - and the owner runs every review.

Also update the memory note on SavedVariables persistence if the build changed its status.
