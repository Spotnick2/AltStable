# AGENTS.md — Shared Context for Agents

Shared baseline for any agent working in this repo (Claude Code, Codex, Copilot all read
`AGENTS.md`). Keep durable project rules here. `CLAUDE.md` is a Claude-specific overlay —
this file is the source of truth; where the two overlap, this one wins.

## Review policy

Use `$wow-addon-review` as the shared source of truth for review routing, committed-diff scope,
client/API evidence handling, validation, finding format, and merge-readiness verdicts.

Repository-specific additions:

- Post every pull-request review and follow-up review on the PR, then link the posted review in the
  final response.
- Match `MEASURED_ON_BUILD` in `Config.lua` to
  `C:\Projects\References\forever-api-<version>.<build>.md`. Runtime measurements live in
  `docs/forever-api-notes.md`; addon-agnostic Forever findings live in the canonical
  `C:\Projects\References\PORTING-TBC-TO-FOREVER.md`.

## What this project is

AltStable is a **World of Warcraft: Forever addon** (interface `16001`) written entirely in
**Lua 5.1** — the version WoW's client uses. It tracks alt characters across multiple WoW
accounts, syncs data over WoW's addon-message protocol, and shows a spreadsheet-style in-game
UI of gear, professions, reputations and cooldowns.

It is a port of AltTracker (TBC Anniversary) — see `..\AltTracker` for the upstream. The port
is the active work; `docs/PORTING-TBC-TO-FOREVER.md` and `docs/forever-api-notes.md` are
measured against the live client and should be treated as fact rather than re-derived.

**The addon-agnostic porting guide is canonical at `C:\Projects\References\PORTING-TBC-TO-FOREVER.md`**,
not at `docs/PORTING-TBC-TO-FOREVER.md`. That copy is shared across every Forever addon project and
is edited by other sessions; the one in this repo is an older snapshot. Read the canonical one, and
write new addon-agnostic findings there. `docs/forever-api-notes.md` stays here — it is
AltStable-specific.

- **Language:** Lua 5.1. No external runtime, no build toolchain, no package manager.
- **Target:** WoW: Forever only. Forever runs Vanilla content on Blizzard's **Mainline (Retail)
  codebase**, so bare Classic globals are mostly gone — use the adapter, not TBC-era APIs.
- **Namespace:** one global table `AltStable`; every file starts `AltStable = AltStable or {}`.
- **SavedVariables:** `AltStableDB` (character records keyed by GUID) and `AltStableConfig`
  (user settings). Declared in `AltStable.toc`. **Known blocker: the client writes them and
  never reads them back** (issue #23) — a failed load is invisible in `AltStableDB` because
  `ScanCharacter` rewrites it every login.

## Layout

Lua files at the repo root, loaded in the order listed in `AltStable.toc` (order matters; a new
`.lua` file must be added there in the right position):

`Libs/` (LibStub, LibDeflate, ChatThrottleLib) → `Compat.lua` → `Theme.lua` → `Core.lua` →
`Scanner.lua` → `Reputations.lua` → `Config.lua` → `Toasts.lua` → `Columns.lua` →
`RowRenderer.lua` → `SheetUI.lua` → `Export.lua`.

- `Compat.lua` is the **Retail-API adapter layer** (`AltStable.API`). Consuming files take a
  file-local alias (`local GetItemInfo = AltStable.API.GetItemInfo`); nothing is injected into
  `_G` on purpose. Read its header comment before adding a mapping.
- `Core.lua` holds the addon-message sync engine — the most protocol-sensitive code.
  `PROTOCOL_VERSION` must be bumped if the serialization format changes. Addon messages are
  capped at 255 bytes; the sync path chunks payloads (`MAX_CHUNK = 220`) with an inter-packet
  delay, base64 + checksum over the reassembled stream.
- `tests/` — Lua 5.1 unit tests (see below).
- `Tools/deploy.ps1` — deploy script. `Tools/AltStableProbe/` — in-game API probe addon.
  `Tools/` is ignored by `.pkgmeta` and never ships.
- `docs/` — the porting guide, the measured API notes, and `docs/WORKFLOW.md` (issue → branch →
  PR → Codex review → merge).

There are **no in-repo plugins yet** (Recipes/Roster are issues #9 and #11) and no `BisData.lua`
— both exist upstream in AltTracker but have not been ported.

## Build & validate

There is no build step — WoW interprets the Lua directly. The Lua 5.1 toolchain lives at
`C:\Program Files (x86)\Lua\5.1\` (`lua.exe`, `luac.exe`).

- **Syntax-check every changed file** before committing — a clean run prints nothing:
  ```
  luac -p <file>.lua
  ```
- **Run the tests** before committing.

## Testing

A dependency-free unit harness lives in `tests/`, running under **Lua 5.1** (not whatever newer
Lua is first on `PATH`).

- **Run all tests:** `pwsh tests/run.ps1` (override the interpreter with `-Lua <path>`; it
  defaults to the path above). It runs every `tests/test_*.lua` from the repo root and exits
  non-zero on failure. Lua only — no Python tests here, unlike upstream.
- **How it works:** `tests/wow_stubs.lua` is a minimal WoW API mock driven via the exported
  `WoW` table (`WoW.reset()`, `WoW.flushTimers()`, `WoW.sentMessages()`, …). A test `dofile`s
  the stubs, sets up SavedVariable globals, `loadfile`s the module under test, and asserts.
- **The stubs must model Forever, not Classic.** A stub that returns the old tuple where the
  live client returns a struct makes a broken port pass. When a stub shape is in question,
  check it against `docs/forever-api-notes.md` — that file is measured on the live client — and
  against the API dump in `C:\Projects\References` for the declared shape.
- File-local internals are reached through the **`AltStable._test = { … }` seam** at the bottom
  of `Core.lua` (harmless in-game) — extend that seam rather than promoting internals to
  real globals.
- **Add a test** as `tests/test_<area>.lua`; `run.ps1` picks it up automatically.
- **Mutation-test claims.** A test that passes both with and against the change proves nothing;
  break the behaviour deliberately and confirm the suite goes red before trusting it.

## Deploying for in-game testing

```
pwsh Tools/deploy.ps1
# or target a specific client:
pwsh Tools/deploy.ps1 -AddOnsPath "D:\...\Interface\AddOns"
```

Copies the addon to `Interface\AddOns\AltStable` additively (`robocopy /E`), excluding `Tools/`,
`tests/`, `docs/`, `.git`, `.claude`, `.vscode`. Then `/reload` in-game. Deploy is a file copy —
low-stakes, no build.

## Key architectural patterns

- **Struct vs tuple is the porting trap.** `C_Item.GetItemInfo` / `GetItemInfoInstant` kept the
  Classic return order and alias directly; skills, reputation and containers now return **one
  table**. A call site that destructures those positionally records empty data **with no error**
  — indistinguishable from a character that genuinely has none. Read the "false friends"
  section of `docs/PORTING-TBC-TO-FOREVER.md` before aliasing anything.
- **Characters have surnames.** Every Forever character name is two words; anything parsing a
  name out of slash args or a whisper target must handle that (`AltStable.ParseSlashArgs`).
- **Bag IDs moved** — read `Enum.BagIndex` rather than hardcoding Classic numbers.
- **Columns** (`Columns.lua` + `RowRenderer.lua`): each column has a typed renderer. Add one by
  appending to `AltStable.Columns` and implementing its type in `RowRenderer.lua`.
- **Character record fields:** gear as `gear_<slot>` (ilvl) / `gearq_<slot>` / `gearid_<slot>` /
  `gearname_<slot>` / `gearmod_<slot>`; `gearlink_*` and `gearsubtype_*` are local-only, not
  synced. Professions as `prof_<Name>` / `profmax_<Name>`; cooldowns as `cd_<Name>` Unix
  timestamps. `maxRank` is **dynamic** for weapon/defense skills — read it, don't assume it.
- **`gearmod_<slot>`** packs enchant, socket count and gems as `"<ench>:<sockets>:<g1>:<g2>:<g3>"`.
  Four states are distinct and must stay that way: absent (record predates the field), `""`
  (empty slot), `?` in the sockets position (uncached at scan time → gem checks suppressed),
  and `0` (confirmed no sockets). A `?` must never be flattened to `0`. Adding any new `gear*_`
  field means touching three places: the reset in `Scanner.lua`, the denylist in
  `SerializeChar`, and the wipe list in `ClearSyncedStateFields` (note `^gear_` does **not**
  match `gearmod_`).
- **Sync protocol** uses prefix `"ALTSTABLE"`, `"CMD|payload"` messages; records serialize as
  `key:value` lines separated by `==END==`. Read `Core.lua` before touching it, and keep the
  corresponding tests green. A format change means a `PROTOCOL_VERSION` bump — old clients must
  cleanly ignore, not misparse.

## Conventions

- **Right-size for a single maintainer.** This is a personal addon with one owner — prefer the
  simplest thing that works. Don't add enterprise-grade abstraction, config, or edge-case
  handling nobody asked for.
- **Match the surrounding code.** Follow the existing file's style (locals, `AltStable.*`
  attachment, table-driven definitions) rather than introducing a second idiom.
- **Boy-Scout, bounded.** Small cleanups in files you're already editing are fine; keep pure
  refactors in their own commit, separate from behavioural change. No drive-by reorgs.
- **Propose, don't expand.** If you spot worthwhile out-of-scope work, mention it — don't
  balloon the current change to do it.
- **Measured beats reasoned.** When a claim about the client can be checked in-game, check it.
  `docs/` has already had to reverse a wrong conclusion that was reasoned rather than measured.

## Git conventions

- Work on a branch off `main`, named for the issue (`phase2/api-adapters`). Never commit
  directly to `main`. Commit or push only when asked.
- **Commit messages:** short imperative subject; body only if it adds something. End with the
  `Co-Authored-By:` trailer for the model that did the work.
- Open the PR with `Closes #N`, then run the Codex review per `docs/WORKFLOW.md`.
- Before committing: `luac -p` clean on changed files, and `pwsh tests/run.ps1` green.

## Agent workflow tips

- **Prefer inline tools** (Read, Grep, Glob, Bash) over spawning subagents for a codebase this
  small — a few searches usually beat the coordination overhead. Reserve agents for genuinely
  broad surveys or parallel independent research.
- **Verify before asserting.** Paths, load order and API usage drift; confirm against the repo
  rather than trusting stale notes — including notes in this file.
- **Don't re-derive the API notes.** `docs/forever-api-notes.md` is measured on the live client.
  For a live declaration check, use `/api search <name>`, `/api system list`, or
  `/api <system> list`; the Battle.net developer portal documents REST APIs, not the Lua API.
- **The API dump is build-stamped — regenerate it when the client bumps.**
  When `GetBuildInfo()` changes: deploy, `/apidump`, `/reload`, then
  `Tools/ForeverAPIDump/Convert-Dump.ps1`. The addon cannot detect staleness itself because
  SavedVariables are never read back here (#23).

## Cost control & model usage

Right-sizing applies to spend too — keep token and context use lean.

- **Prefer inline tools over subagents.** Only spawn one for a genuinely broad survey or
  parallel independent research; each agent starts cold and the coordination overhead often
  exceeds the benefit for a repo this size.
- **Cap parallelism.** Don't spawn more than ~2 subagents in one turn.
- **Compact / start fresh after heavy work.** Compact after a large exploration phase, big diff,
  or repeated syntax-check/test loops; start a clean session when switching tasks.
- **Match the model to the work — cheap for mechanical, strong for tricky:**
  - *Cheap/fast (Haiku):* file-finding and symbol/usage searches, small rote edits, deploy and
    file-copy tasks.
  - *Mid (Sonnet):* routine implementation — new columns, renderers, config plumbing,
    straightforward test additions.
  - *Strong (Opus):* tricky reasoning — the `Core.lua` sync/serialization engine,
    protocol-version and chunking changes, adapter-layer semantics, difficult debugging.
