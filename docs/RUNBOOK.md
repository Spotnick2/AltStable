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
stops half-way, and the symptom you see is missing data rather than a stack trace. It is a CVar,
and CVars are memory-only on this build (see **#23**), so it has to be set again after a restart.

Better still, install **BugGrabber + BugSack**: they catch the error with its locals, which is how
the secret-value bug was diagnosed (the character record in the log showed `stat_str=<secret
number>`, which named the cause outright).

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

## #23: nothing persists, and what that costs you

This client **writes** SavedVariables correctly and **never reads them back**. Account-wide and
per-character both. So on every launch the addon starts empty, rescans the current character, and
forgets everything else.

Consequences for testing, in order of how often they bite:

1. **`/reload` proves nothing about persistence.** The process stays alive, so values survive in
   memory and look persisted. Every false "it persists" result on this project came from a
   `/reload`. A persistence claim needs a **full client exit**, a relaunch, and the value
   **observed inside the relaunched client** — printed by the addon, or reported by the probe.
   Finding it in the file on disk proves only that the client *wrote* it, which it has always done
   correctly; the broken half is the read.
2. Cross-session features (an alt's data surviving a restart) cannot be verified at all yet.
   Cross-*account* sync works within a session, because it goes over the addon channel.
3. Config changes do not survive either, including `AltStableConfig.accountNumber`, the
   whitelist and the hidden-character list — set them again after each launch when testing
   sync, and expect a hidden character to be back on the sheet after a restart.

To check the state of the bug after a client update:

```
pwsh Tools/deploy-probe.ps1     # deploys AltStableProbe, AltStableDevConfig, ForeverAPIDump
```

The probe keeps a counter in each store and reports at `PLAYER_LOGIN` what it found there:

```
SavedVariables (account) first ever run - not loaded
SavedVariablesPerCharacter first ever run - not loaded
account #1 / per-character #1 / machine #1 - only a FULL EXIT and relaunch counts; /reload proves nothing
```

That is the broken state: every launch is "first ever run", and every counter sits at 1.

Fixed looks like `SavedVariables (account) LOADED - previous loadCount=3`, with the counters
climbing launch over launch.

**The procedure is the point, not the line.** A counter that rises after a `/reload` proves
nothing — the process stayed alive, so the in-memory table was never re-read. It has to be:

1. log in (this writes the file on logout),
2. **exit the client completely**,
3. relaunch and log in again,
4. read the line: `LOADED - previous loadCount=` is a real fix; `first ever run` is the bug
   intact.

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
   Expected on 69977: `60`, a positive number, `nil` unless rested, `-1`, your faction count,
   `table`.
4. **Check #23** with the probe, above.
5. **Bump `MEASURED_ON_BUILD`** and the test stub's `GetBuildInfo`, and record what was compared in
   `docs/forever-api-notes.md`. Old dump files are kept, not deleted — deleting is a human call.

---

## Testing sync between two accounts

Both accounts run on this machine, from the same AddOns folder, so both always have the same
version.

1. Log in account 1, `/alts account 1`, `/alts whitelist <the other character>`.
2. Log in account 2 (a second client), `/alts account 2`, whitelist account 1's character.
3. `/alts sync <name>` from either side, or just `/alts`, which pings whitelisted peers.

There is **no `add` keyword**: `/alts whitelist <name>` adds, and anything typed after
`whitelist` becomes the name verbatim — `/alts whitelist add Karuzo` whitelists a peer called
"add Karuzo". Bare `/alts whitelist` lists, `remove <name>` drops. Names go in as typed: a Forever
character is two words ("Karuzo Elegia"), and a cross-realm peer keeps its `-Realm` suffix.

Set the account number and whitelist on **each** launch until #23 is fixed.

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
