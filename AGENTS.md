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
- **SavedVariables:** `AltStableDB` (character records keyed by GUID), `AltStableConfig`
  (user settings) and `AltStablePortraits` (portrait capture records — a contract a converter
  parses, see `docs/PORTRAIT-CONTRACT.md`). Declared in `AltStable.toc`. They persist again as of client 1.60.1.70009
  (#23 is fixed), so the shape on disk now holds real data across sessions — and a load failure
  would still be invisible in `AltStableDB`, because `ScanCharacter` rewrites the current
  character every login. Verify persistence with a full client exit, never a `/reload`.

## Layout

Lua files at the repo root, loaded in the order listed in `AltStable.toc` (order matters; a new
`.lua` file must be added there in the right position):

`Libs\LibGlass-1.0\LibGlass-1.0.xml` → `Libs\LibShowcase-1.0\LibShowcase-1.0.xml` →
`Libs\LibAccountSync-1.0\LibAccountSync-1.0.xml` → `Libs/` (LibStub, LibDeflate, ChatThrottleLib) →
`Compat.lua` → `Glass.lua` → `Theme.lua` → `Skin.lua` → `Prompt.lua` → `Core.lua` →
`Scanner.lua` → `Reputations.lua` → `Config.lua` → `Toasts.lua` → `Columns.lua` →
`RowRenderer.lua` → `SheetUI.lua` → `Capture.lua` → `PublicAPI.lua` → `Export.lua`.

`PublicAPI.lua` is what OTHER addons build on (`docs/PUBLIC-API.md`): copies of a fixed set
of fields, never live tables. Changing what a field means, or removing one, bumps
`AltStable.PUBLIC_API_VERSION`; adding one does not.

- `Compat.lua` is the **Retail-API adapter layer** (`AltStable.API`). Consuming files take a
  file-local alias (`local GetItemInfo = AltStable.API.GetItemInfo`); nothing is injected into
  `_G` on purpose. Read its header comment before adding a mapping.
- `Core.lua` holds the addon-message sync engine — the most protocol-sensitive code.
  `PROTOCOL_VERSION` must be bumped if the serialization format changes. Addon messages are
  capped at 255 bytes; the sync path chunks payloads (`MAX_CHUNK = 220`) with an inter-packet
  delay, base64 + checksum over the reassembled stream.
- `tests/` — Lua 5.1 unit tests (see below).
- `Tools/deploy.ps1` — deploy script. `Tools/AltStableProbe/` — in-game API probe addon (portrait
  capture used to live there; it ships in `Capture.lua` now).
  `Tools/` is ignored by `.pkgmeta` and never ships.
- `docs/` — the porting guide, the measured API notes, and `docs/WORKFLOW.md` (issue → branch →
  PR → Codex review → merge).

The in-repo plugins are Warband, Instances (Raids), Roster and Professions (#14). There is no
`BisData.lua` — it exists upstream in AltTracker but has not been ported.

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
  non-zero on failure. The tests need a **LibGlass checkout** (`$env:LIBGLASS`, else
  `..\LibGlass`), a **LibShowcase checkout** (`$env:LIBSHOWCASE`, else `..\LibShowcase`) and a
  **LibAccountSync checkout** (`$env:LIBACCOUNTSYNC`, else `..\LibAccountSync`), and fail loudly
  without them; `run.ps1` warns when one is not at its `.pkgmeta`
  pin. Lua only — no Python tests here, unlike upstream.
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
`tests/`, `docs/`, `.git`, `.claude`, `.vscode`, and `Plugins/`. Each folder under `Plugins/` is
deployed as its own top-level addon folder named after its `.toc` (`AltStableWarband`,
`AltStableInstances`) — WoW only discovers addons as top-level folders. Then `/reload` in-game.
Deploy is a file copy — low-stakes, no build.

`@project-version@` is substituted in every deployed `.toc`, in the **deployed copy only**. Never
commit a literal version over that keyword: the packager needs it, and it has been overwritten by
hand twice on sibling projects.

See `docs/RUNBOOK.md` for the operational side: the in-game loop, where the client keeps
SavedVariables, how to verify persistence on a new build, the client-update procedure, two-account sync
testing, and the errors you will actually see.

See `docs/SYNC-DISCOVERY.md` before touching how peers find each other (#58): which transports this
client offers, which routes are already closed and why, how Altoholic solves the same problem, and
the measurements that decide the design. Parked until the port is done.

## Releasing

One CurseForge project publishes all three folders. CurseForge's own packager builds the release
from the tag webhook, reading `.pkgmeta`; nothing here uploads, and no API key lives in this repo.

```
git tag -a vX.Y.Z -m "..." && git push origin vX.Y.Z
```

The tag name sets the release type: a bare `vX.Y.Z` publishes as a release, `-beta` as a beta.
Releases are bare tags from v0.10.0 on (the addon is public; see RUNBOOK "Releasing"). `CHANGELOG.md` is the release
notes (`manual-changelog`), and is itself ignored so it does not ship inside the addon.

`.github/workflows/package-check.yml` dry-runs the BigWigs packager (`-d`) on pull requests, on
pushes to `main` and on `v*` tags — a push to a feature branch with no PR open runs nothing — and
on a tag **publishes** a GitHub Release (below). Its `check` job asserts the
built zip's shape: the three folders present, `Tools/`, `tests/` and
`docs/` absent, and every `.toc` version substituted. `-d` is the real no-upload switch — merely
omitting the API key still cuts a GitHub release, with the whole changelog as its notes. On a `v*`
tag its `release` job (the only one with `contents: write`) publishes the GitHub Release instead:
the checked zip plus the tag's `CHANGELOG.md` section (#209). `tests/test_packaging.lua` checks the
inputs that feed it (the TOCs, `.pkgmeta`, the deploy script) and runs in the normal suite.

After a release, check the published files on CurseForge by hand: CI runs the BigWigs packager, and
CurseForge runs its own, so the zip players get is not the zip CI inspected. Checked on
v0.1.0-beta: three folders, the version substituted in all three `.toc` files, no `Tools`/`tests`/
`docs`, and every library, icon and raid image present. One known difference between the two
packagers — CurseForge leaves an empty `AltStable/Plugins/` entry where BigWigs removes it. The
client ignores it.

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
- **`hidehelm` / `hidecloak` are NUMBERS, 1 or 0 — never booleans.** Everything on a character
  record rides the wire as `tostring(v)`, and `DeserializeChar` coerces with `tonumber`, so a
  boolean arrives at the peer as the STRING `"false"` — which is truthy in Lua, making a shown
  cloak read as hidden. `1`/`0` round-trip as numbers. They are named for the HIDDEN state so an
  absent field (an older record) reads as `0` = shown, which is the safe direction to fail.
  `restedArea` is the one boolean that predates this rule, and readers compare it explicitly
  (`== true or == "true"`) for exactly that reason.
- **Unit numbers can be unreadable.** Some APIs return Retail "secret values": storable, but
  arithmetic, comparison or `tostring` on one throws and aborts the whole function. Read every
  unit number through `AltStable.API.PlainNumber` / `PlainSum`, store `nil` rather than `0` for
  one (unknown is not zero, and a 0 syncs as fact), and clear the field on the peer when it goes
  unknown. See "Secret values" in `docs/forever-api-notes.md`.
- **Sync protocol** uses prefix `"ALTSTABLE"`, `"CMD|payload"` messages; records serialize as
  `key:value` lines separated by `==END==`. Read `Core.lua` before touching it, and keep the
  corresponding tests green. A format change means a `PROTOCOL_VERSION` bump — old clients must
  cleanly ignore, not misparse.

## The glass material

The material is **LibGlass-1.0**, an embedded LibStub library (`..\LibGlass`,
github.com/Spotnick2/LibGlass, public, MIT) that every glass addon embeds (#184). Its repo owns
the code, the textures, the generator and the write-up (`docs/GLASS-MATERIAL.md`), and its
`CLAUDE.md` holds the contract (the API, region fields and texture names only grow; instances;
upgrade rules).

- **Material changes are LibGlass PRs**, never edits here. A bug or a need found here goes on a
  LibGlass issue; never edit `..\LibGlass` from this repo's session.
- **How it's embedded:** `.pkgmeta` externals put it in `Libs\LibGlass-1.0\` (the only supported
  path: `MEDIA` is derived from it), and the TOC loads its XML first. Only `Libs/LibGlass-1.0/`
  is gitignored; the other libraries stay vendored. A dev copy comes from the LibGlass checkout
  (`$env:LIBGLASS`, default `..\LibGlass`) through its own `Tools\deploy.ps1`, which
  `Tools\deploy.ps1` here calls first. The tests load the same checkout (`tests/libglass.lua`).
- **The pin:** `.pkgmeta` pins a tag (`tag: r4`), **never `tag: latest`**, and no comment on a
  value line. Bump it only in a release made anyway: players get library fixes earlier through
  whichever glass addon ships the newest copy. CI fetches the pin (`tests/fetch_libglass.sh`),
  tests against it, and asserts the zip's `Libs/LibGlass-1.0/` is exactly that commit's shipped
  files.
- **`AltStable.Glass` is an instance**, built with `rimAlpha = 1` (the rim as it always drew
  here). `Skin.lua` pushes the chosen preset into its `STYLE` before each `Apply`; that STYLE is
  this addon's own. `Glass.MEDIA` is for the library's textures only; the addon's art keeps its
  own paths (`AltStable.MEDIA_PATH`).

## The camera showcase

The showcase (camera swing, shoulder offset, orbit, Alt+Z-style UI hide with the sheet lifted) is
**LibShowcase-1.0** (`..\LibShowcase`, embedded exactly like LibGlass: `.pkgmeta` external
`tag: r3`, its non-dot ignores repeated, `Libs/LibShowcase-1.0/` gitignored, its XML loaded right
after LibGlass's, deployed through its own `Tools\deploy.ps1`, tests load it through
`tests/libshowcase.lua`). It was extracted from this file's `AltStableCameraPresentation`; its
`docs/DESIGN.md` holds the guarantees and its `CLAUDE.md` the contract.

- **Camera behaviour changes are LibShowcase changes**, never edits here.
- `SheetUI.lua` keeps a thin adapter with the old names: `AltStable.AltStableCameraPresentation`
  (`Enter`/`Exit`/`ForceRestore`, and read-only `active`/`mode`/`capture`/`uiHidden`),
  `AltStable.IsGameUIHidden`, `AltStable.LiftAboveHiddenUI` and
  `AltStable.SuppressExperimentalCVarPopup`. The options still live in `AltStableConfig` and are
  pushed into the instance's `opts` at every open.
- **r3 or nothing.** The adapter needs MINOR 3+, fully loaded (`lib.ready == minor`). Anything less
  means no showcase (`IsSupported()` false), never a load error.
- **Never a StaticPopup.** Showing one from addon code, or reparenting, raising or hooking one,
  taints Blizzard's shared dialog pool (MEASURED 70205: Quit then failed with
  `ADDON_ACTION_FORBIDDEN ... ForceQuit()`). Our prompts are our own frames: `Prompt.lua`
  (`AltStable.ShowPrompt(kind, opts)` / `HidePrompt(kind)`), one frame per kind, parented to
  nothing, and `onClose(choice)` runs once on every way out.
- **The UI may stay up.** With a Blizzard dialog or prompt open (an invite, a ready check, a loot
  roll), `Enter`/`HideGameUI` keep the UI shown, and one appearing mid-showcase brings it back
  (`onGameUIShown`). The sheet and camera stay; we don't re-hide. Read `IsGameUIHidden()`, never
  assume. `onForcedExit` (Escape/Alt+Z, combat, logout, loading) closes the sheet.
- **One owner.** The camera is global, so the library refuses a second addon while one presents;
  the sheet then opens without a showcase. The crash self-heal capture rides in
  `AltStableConfig.LibShowcaseCapture` while a presentation is up. The experimental-CVar popup,
  once suppressed, stays off until `/reload` (re-registering it was measured to taint).

## Own-account sync (LibAccountSync)

The owner's own other accounts sync over **LibAccountSync-1.0** (`..\LibAccountSync`, embedded
like the other two: `.pkgmeta` external `tag: r5`, its non-dot ignores repeated, gitignored, its
XML loaded before our files, deployed through its own `Tools\deploy.ps1`, tests load it through
`tests/libaccountsync.lua`). It was extracted from this repo's #58 channel (#198).

- **The library only.** The legacy Battle.net channel (`HI8` hello, `CHUNK5`/`DONE8` over
  `BNSendGameData`) was removed in #206, so a v0.10 client no longer syncs with us over Battle.net.
  The library lists every own account that runs *any* addon on it (GlassChat alone, say), so a peer
  counts as running AltStable only after an **AltStable message came from it over the library**
  (`CAP8` handshake, `LibSync.peers` in `Core.lua`). Keep `CAP8`: it is the only discovery left,
  and v0.11 relies on it.
- **Per peer, never broadcast.** Requests and replies go with `SendTo(guid, …)`. The library's
  `Send` (to every account) is never used. A refused `SendTo` falls back to a whisper for that one
  message when it was one, still to that one peer; a refused `"BNET"` send goes nowhere.
- **Independent messages, detected when used.** The instance is made with `messages = true`, and
  the library route is taken only while `inst.messages == true` and `inst.SendTo` exists: an older
  copy's snapshot floor drops an older message that completes after a newer one
  (LibAccountSync#18). Never cache the check at load.
- **The store is `AltStableConfig.accountSync`** (account-wide, written once through
  `SetConfigValue`, then by the library). Built on first use with the legacy keys: `bnetKey` at
  `keyAt = 1`, `bnetTrusted` `true` entries as timestamps, 32-hex keys only. Since #206 nothing
  writes `bnetKey`, `bnetTrusted`, `bnetSelfProject` or `bnetSelfRegion`; they stay on disk for a
  release (a downgrade still reads them) and are then retired deliberately.
- **Library changes are LibAccountSync PRs**, never edits here.

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
  `Tools/ForeverAPIDump/Convert-Dump.ps1`. `MEASURED_ON_BUILD` in `Config.lua` is the record of
  which build the notes describe, and the addon says so at login when the two differ.

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
