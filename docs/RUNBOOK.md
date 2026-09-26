# Runbook

Operational notes for working on AltStable against a live WoW: Forever client. The *why* of
design decisions lives in `AGENTS.md` and `docs/forever-api-notes.md`; this is the *how*.

Paths below assume the default install:
`C:\Program Files (x86)\World of Warcraft\_classic_beta_`. Each script takes its own override,
and they are not the same flag:

| Script | Override |
|---|---|
| `Tools/deploy.ps1`, `Tools/deploy-probe.ps1` | `-AddOnsPath "<...>\Interface\AddOns"` |
| `Tools/ForeverAPIDump/Convert-Dump.ps1` | `-WtfAccountPath "<...>\WTF\Account"`, and `-OutDir` for where the artifact lands |
| `tests/run.ps1` | `-Lua "<path to lua5.1.exe>"` (no client involved) |

---

## The loop

```
pwsh tests/run.ps1          # 937 checks, ~2s, no client needed
pwsh Tools/deploy.ps1       # copy to the client (three addon folders)
```
then in game:
```
/console scriptErrors 1     # errors are OFF by default on this client - turn them on FIRST
/reload
/alts                       # open the sheet
```

`scriptErrors 1` matters more here than on retail: without it a Lua error is silent, the scan
stops half-way, and the symptom you see is missing data rather than a stack trace. Through 69977
CVars were memory-only and it had to be set again after every restart; whether 70009 fixed CVar
**persistence** along with SavedVariables has **not** been measured, so assume it did not until
someone checks. (#25 is a different question and no longer supports this one: the camera CVars
turned out to be read correctly within a session - see the correction in
`docs/forever-api-notes.md`. Nothing there says anything about surviving a restart.)

Better still, install **BugGrabber + BugSack**: they catch the error with its locals, which is how
the secret-value bug was diagnosed (the character record in the log showed `stat_str=<secret
number>`, which named the cause outright).

### Character portraits: when a re-capture is needed

`pwsh Tools/RenderCutout/Update-Cutouts.ps1` converts staged captures, recovers
what it can, and rebuilds the manifest. It deletes the screenshots it consumed,
so anything it cannot work out from a sidecar is gone for good and the only
remedy is `/asrender` on that character again. Three cases it reports:

- **"sidecar predates unit normalisation"** - the cutout was filed before
  heights were recorded as a fraction of screen height. Usually recovered
  automatically from the probe store's `screenH`; if the store no longer has
  that character's capture, re-capture.
- **"cutout is full-screen height"** - the matte caught the whole window rather
  than the character, normally because a tooltip or another frame was on screen.
  Re-capture. The converter refuses these now, but any already filed are
  excluded from the manifest: heights are *relative*, so one bogus entry draws
  every other character at half size.
- **"no screenshots for <name>"** - the pair was already converted, or was taken
  on another machine. Harmless if that character already has a cutout.

A character with no measured height still appears; it is drawn at the common
height, which is what every portrait did before heights existed. Only the
gnome-beside-a-tauren proportions are lost.

### Forgetting a character

`/alts forget <name>` removes a character that no longer exists. Deleting the
record is the easy half: a peer still holds it and re-sends it on the next
sync, so forgetting also writes a **tombstone** that drops the record whenever
a peer offers it back.

- **Per account, and not on the wire.** Each account forgets independently.
  Account A deciding a character is gone is not evidence for account B, which
  may still be playing it — and it needs no protocol change.
- **Tombstones do not expire by age.** They were going to, and that was wrong:
  a dead character's `lastUpdate` is frozen, so it never passes a delta's filter
  and rides only *full* replies. In the ordinary login-delta steady state the
  stamp never moves, the tombstone would drop on day 31, and the next full sync
  — a `/alts cleanup`, a scope change, or the Warband plugin resetting
  watermarks at login — would bring the character straight back. The list is
  bounded by **count** instead (200, oldest evicted), which is what "do not grow
  without bound" actually needed.
- **Not the character you are playing.** The next scan would rewrite the record
  seconds later.
- `/alts unforget <name>` undoes it. Dropping the tombstone is not enough on
  its own — every peer's watermark is already past the dead record, so it would
  never be offered again — so unforgetting also **resets the watermarks**, and
  the next reply from each peer is a full one.
- `/alts forgotten` lists them. Forgetting also drops the character's hidden and
  favourite entries, since the record will not be coming back to need them.

Hiding (#21) is a different thing and still the right one for "I do not want to
look at my bank alt": the record stays and keeps syncing.

### What deploy does

- `AltStable/` gets the core addon (`robocopy /E`, additive), minus `Tools/`, `tests/`, `docs/`,
  `.git`, `.claude`, `.vscode`, `Plugins/`.
- Each folder under `Plugins/` becomes its own top-level addon folder named after its `.toc`:
  `AltStableWarband`, `AltStableInstances`. WoW only discovers top-level folders.
- `@project-version@` is substituted with `dev-<sha>` in every **deployed** `.toc`. Never commit a
  literal version over that keyword; it has been done by hand twice on sibling projects.

Deploy is a file copy. There is no build step, and nothing in the repo changes.

---

## Where the client keeps things

```
_classic_beta_\WTF\Account\<id>\SavedVariables\AltStable.lua            account-wide
_classic_beta_\WTF\Account\<id>\<Realm>\<Character>\SavedVariables\...  per-character
_classic_beta_\WTF\SavedVariables\                                      machine scope (Blizzard only)
_classic_beta_\Screenshots\                                             /alts update-reference output
_classic_beta_\Logs\                                                    client logs
```

`<id>` looks like `50284074#12`. Two accounts on one machine are two `<id>` folders, which is what
makes local two-account sync testing possible.

**Files are only written on a clean logout or `/reload`.** Killing the client loses the session.

---

## Persistence (#23, fixed in 1.60.1.70009)

SavedVariables load. Both scopes an addon uses — account-wide and per-character — came back on the
first launch of 70009, reading files written by 69977. `AltStableConfig` (account number,
whitelist, hidden characters) and `AltStableDB` (every alt) now survive a restart, which is the
addon's whole point.

Through 69977 they did not: the client wrote them correctly and never read them back. That shaped
a lot of this repo's history, and two habits from it are worth keeping:

1. **`/reload` still proves nothing about persistence.** The process stays alive, so values
   survive in memory whether or not the disk was touched. Every false "it persists" result on this
   project came from a reload. A persistence claim needs a **full client exit**, a relaunch, and
   the value **observed inside the relaunched client**. Finding it in the file on disk only proves
   the client wrote it — which it always did.
2. **Re-check it after every client update**, with the probe, the same way. It is one launch, and
   a regression here would be invisible in the code.

`SavedVariablesMachine` still does not load. It is Blizzard-only scope, AltStable does not use it,
and the probe reports it only for completeness.

To check persistence on a new build:

```
pwsh Tools/deploy-probe.ps1     # deploys AltStableProbe, AltStableDevConfig, ForeverAPIDump
```

The probe keeps a counter in each store and reports at `PLAYER_LOGIN` what it found there.
Healthy, as of 70009:

```
[probe] SavedVariables (account) LOADED - previous loadCount=1
[probe] SavedVariablesPerCharacter LOADED - previous loadCount=1
[probe] SavedVariablesMachine first ever run - not loaded
[probe] account #2 / per-character #2 / machine #1 - only a FULL EXIT and relaunch counts; /reload proves nothing
```

Broken looks like `first ever run - not loaded`, with every counter stuck at 1 launch after
launch.

**The procedure is the point, not the line:**

1. log in (this writes the file on logout),
2. **exit the client completely**,
3. relaunch and log in again,
4. read the line. A counter that rises after a `/reload` proves nothing — the process stayed
   alive, so the in-memory table was never re-read.

The probe prints that caveat itself, on the counter line, because three separate tests on this
project concluded a store persisted when it had not.

---

## When the client updates

The build number is in the launcher under the Play button. AltStable warns at login on any build
other than `MEASURED_ON_BUILD` in `Config.lua`, because a stale API dump reads exactly as
authoritatively as a current one.

1. **Regenerate the dump.** `/apidump`, then `/reload`, then
   `pwsh Tools/ForeverAPIDump/Convert-Dump.ps1`. It writes
   `C:\Projects\References\forever-api-<version>.<build>.md` and says so when the build changed.
2. **Diff the documented surfaces** against the previous file: documented functions, events, enums
   and structures, widget methods, namespace functions. Ignore the global-functions and
   namespace-candidates sections — those pick up whatever addons were loaded when the dump ran.
3. **Re-measure the behaviours**, because the dump proves shape, not behaviour:
   ```
   /run print(GetMaxPlayerLevel(), UnitXPMax("player"), GetXPExhaustion(), Enum.BagIndex.Keyring, C_Reputation.GetNumFactions(), type(TooltipDataProcessor))
   ```
   Expected on 70009: `60`, a positive number, a number while rested (`nil` when not), `-1`,
   your faction count, `table`. Update this line with the build when you bump
   `MEASURED_ON_BUILD` below — an expectation pinned to an older build is the staleness this
   checklist exists to prevent.
4. **Check persistence** with the probe, above — it is fixed, and a regression would be silent.
5. **Bump `MEASURED_ON_BUILD`** and the test stub's `GetBuildInfo`, and record what was compared in
   `docs/forever-api-notes.md`. Old dump files are kept, not deleted — deleting is a human call.

---

## Testing sync between two accounts

Both accounts run on this machine, from the same AddOns folder, so both always have the same
version.

1. Log in account 1, `/alts account 1`, `/alts whitelist <the other character>`.
2. Log in account 2 (a second client), `/alts account 2`, whitelist account 1's character.
3. `/alts sync <name>` from either side, or just `/alts`, which pings whitelisted peers.

Since 70009 steps 1 and 2 are a one-off: the account number and the whitelist come back on their
own.

There is **no `add` keyword**: `/alts whitelist <name>` adds, and anything typed after
`whitelist` becomes the name verbatim — `/alts whitelist add Karuzo` whitelists a peer called
"add Karuzo". Bare `/alts whitelist` lists, `remove <name>` drops. Names go in as typed: a Forever
character is two words ("Karuzo Elegia"), and a cross-realm peer keeps its `-Realm` suffix.

What `/alts sync <name>` actually does, in both directions: it sends **our** database to that peer
in full, then three seconds later asks for theirs **from our watermark for them** — a delta, not a
full pull. So it is the way to force a complete *outbound* transfer. To force a full *inbound* one,
the watermark has to go: `/alts cleanup` resets every peer watermark (it wipes the local database,
so the next reply has to be complete), and a peer that sends no clock is reset to 0 automatically.

---

## Slash commands

| Command | What it does |
|---|---|
| `/alts` | Open the sheet and ping whitelisted peers (throttled) |
| `/alts sync` | Ping every whitelisted peer, ignoring the throttle |
| `/alts sync <name>` | Send our database to that peer in full, then request a delta back |
| `/alts whitelist` | List the whitelisted peers |
| `/alts whitelist <name>` | Add one — no `add` keyword; the rest of the line is the name |
| `/alts whitelist remove <name>` | Drop one |
| `/alts forget <name>` | Remove a character that no longer exists, for good |
| `/alts unforget <name>` | Undo that — it returns on the next sync |
| `/alts forgotten` | What has been forgotten on this account |
| `/alts account <n>` | This account's number, shown in the sheet |
| `/alts export` | TSV of every character, for the spreadsheet |
| `/alts cleanup` | Wipe every character but this one, then re-pull in full |
| `/alts config` | Options panel |
| `/alts update-reference` | Screenshot the character for the render pipeline |
| `/asprobe`, `/asprobe bank`, `/asprobe whisper <name>` | The dev probe (needs `deploy-probe.ps1`) |
| `/apidump` | Dump the client's API surface to SavedVariables |

---

## Releasing

CurseForge builds releases from the tag webhook, reading `.pkgmeta`. Nothing here uploads.

1. Update `CHANGELOG.md` — it is the release notes.
2. `git tag -a vX.Y.Z-beta -m "..."` and `git push origin vX.Y.Z-beta`, with a version that has
   not been used before (`v0.1.0-beta` is taken; `git tag -l` lists them).
3. The tag name sets the release type: `-beta` publishes as a beta, a bare `v0.1.0` as a release.
4. **Check the published zip by hand.** CI dry-runs the BigWigs packager; CurseForge runs its own,
   so the file players download is not the file CI inspected.

What to look for in the zip (verified on `v0.1.0-beta`, the first release):

- three sibling folders: `AltStable`, `AltStableWarband`, `AltStableInstances`;
- `## Version: v0.1.0-beta` in all three `.toc` files, not the raw keyword;
- no `Tools/`, `tests/`, `docs/`, `.github/` or agent files;
- the libraries, the icons and the raid art present.

Known difference between the packagers: CurseForge leaves an empty `AltStable/Plugins/` entry where
BigWigs deletes it. The client ignores it.

If the webhook does not fire, the project's GitHub link was not saved. Re-link and push a **new**
tag rather than reusing the failed one — CurseForge builds per tag, and tags are cheap.

---

## Character portraits (the Roster lineup)

An offline character cannot be textured on this client — only geometry and
weapons come back (see `docs/forever-api-notes.md`). So the lineup is drawn from
pictures taken earlier, of the **live** character, by this machine. No armory is
involved and none is needed.

```
in game:   /asrender                  (or let it happen at login when gear changed)
outside:   pwsh Tools/RenderCutout/Update-Cutouts.ps1
           pwsh Tools/RenderCutout/Update-Cutouts.ps1 -Watch     # and forget about it
```

**How it works.** The addon poses the live character on a flat stage and takes
**two** screenshots of the identical frozen pose, one on black and one on white.
From that pair the converter recovers exact alpha — `α = 1 − (white − black)` —
which a chroma key cannot do: hair and blended edges come out right with no
colour fringing. It then trims to content, supersamples down (the client emits
**no partial alpha**, so edges are aliased until they are resampled), pads to a
power of two, and writes the manifest.

**Where things end up.**

```
Screenshots\WoWScrnShot_*.tga                       staged pairs, deleted once converted
Tools\RenderCutout\out\<character>.tga              the build output (gitignored)
Interface\AddOns\AltStableCutouts\Cutouts\*.tga     what the game loads
Interface\AddOns\AltStableCutouts\CutoutManifest.lua
```

`AltStableCutouts` is a **generated addon folder**, not part of the repo. It has
to be separate: a Lua file dropped into `AltStable/` is never loaded unless the
`.toc` lists it — and a generated file cannot be listed — and `deploy.ps1` would
overwrite it on the next deploy anyway. Delete the whole folder to start over.

### Things that will catch you

- **A new portrait shows "0 of N" after `/reload`.** The client only discovers a
  new ADDON FOLDER at startup. The first time `AltStableCutouts` is created you
  need a full exit and relaunch; after that `/reload` is enough, because only the
  files inside it change.
- **A cutout comes out nearly square.** Something other than the character was on
  screen and got matted in — a tooltip draws above the stage. The converter says
  so; re-capture that one. The stage hides `UIParent` now, so this should be
  historical.
- **Screenshots must be TGA.** The addon switches the CVar for the capture and
  restores it. JPEG makes the matte read compression noise as coverage.
- **Nothing is deleted that was not matched** to a capture the addon recorded, so
  screenshots taken by hand are never touched. The flip side: an unpaired shot
  lingers, and has to go by hand.
- **A spoiled capture still counts as done.** The addon records that a LOOK was
  photographed; only the converter can see whether the picture was any good. Use
  `/asrender forget` to put that character back in the automatic queue.

### The commands

| Command | What it does |
|---|---|
| `/asrender` | Capture now |
| `/asrender preview` | Show the stage without shooting, to judge the framing |
| `/asrender facing <deg>` | Turn the character; 0 faces you straight on |
| `/asrender cancel` | Stop a capture that is counting down |
| `/asrender auto` | Turn automatic capture off or back on |
| `/asrender status` | What it thinks your look is, and whether auto is on |
| `/asrender forget` | Re-capture this character at the next login (`forget all` for everyone) |

Automatic capture fires at login when the equipped-item fingerprint changed, never
in combat, and announces itself the first time. An independent watchdog restores
the interface after 12 seconds whatever happens, because the capture hides it.

---

## Errors you will actually see

**`attempt to perform arithmetic on a secret number value`** — a unit API returned a value this
client will not let an addon inspect. Never read one directly; go through
`AltStable.API.PlainNumber` / `PlainSum`. Measured returning secrets: `UnitStat`, `UnitArmor`,
`UnitAttackPower`, `UnitHealthMax`, `GetMoney`, on a PvP realm. The flag is **not** sticky — the
same call returned a plain number later, so "it worked when I tested" proves nothing.

**`AddOn 'AltStable' tried to call the protected function ...`** — read the stack before believing
the name. The addon named is the one that *tainted* the path, not necessarily the one that called
the function. Two such reports on this project were other addons' bugs; one arrived through a
shared `LibStub` global, where whichever addon loads it first owns the taint. AltStable's own UI
guards every resize and move with `InCombatLockdown()`.

**A scan that stops half-way** (professions missing, reputations empty) — an error aborted
`ScanCharacter`. With `scriptErrors 1` on, the stack names the line. Everything written after that
line is simply absent, so "the reputations are empty" usually means "something above them threw".

**A sync that stalls** — after 45 seconds the addon says so, and after 120 seconds it sweeps the
buffer. A peer on another protocol version now reports "outdated/newer addon version" instead;
if you see a stall with no reason, the stream really was lost.

---

## Cleaning up

- **`/alts cleanup`** keeps only the current character and re-pulls the rest in full. Plugins clear
  their own stores with it.
- **Deleting SavedVariables by hand:** close the client first (it rewrites them on exit), then
  delete `WTF\Account\<id>\SavedVariables\AltStable*.lua`. Back them up if there is any chance the
  contents matter — they contain real character names and realms.
- **Removing the dev tools** from the client: delete the `AltStableProbe`, `AltStableDevConfig` and
  `ForeverAPIDump` folders from `Interface\AddOns`. They are never packaged.
