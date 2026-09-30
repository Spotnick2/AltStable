# Forever API contracts — measured, not guessed

Probe runs 2026-09-20 on build **1.60.1.69913**, against two low-level characters on the
"Classic Beta PvE" realm. Character names and GUIDs below are placeholders; the values are as
measured. Produced by `Tools/AltStableProbe`.

Everything below is an observed return value. Where it contradicts an assumption in the migration
plan, that's called out.

---

## How to check whether an API survived

Read this before concluding that anything below is "gone". Three separate wrong conclusions in one
evening came from probing the wrong surface, two of which shipped - one as code, one as a deferred
issue.

**A name can live in four different places.** `type(Name)` only ever asks about one of them:

| where | example | probe |
|---|---|---|
| a global | `GetCVar` | `type(GetCVar)` |
| a `C_*` namespace | `C_CVar.GetCVarInfo` | `type(C_CVar) == "table" and type(C_CVar.GetCVarInfo)` |
| a widget method | `model:TryOn(...)` | create the widget, then `type(widget.TryOn)` |
| an internal event system | `GameEvent.UnregisterInternalEvent` | `type(GameEvent)` and the member |

A global check returning `nil` for a widget method reads exactly like a deleted API, on a client
where the feature works perfectly.

**And a present function can still be read wrongly.** Getting the name right is not the end of it:

- **Return shape.** `GetFramesRegisteredForEvent` returns varargs. Bound as one value it yields the
  first *frame*, which is a table, so a `type()` check passes while `#` is 0 - "nobody registered",
  silently, forever. Collect with `{ ... }` and `select("#", ...)` when the shape is not certain.
- **Struct vs tuple.** The skills and reputation ports (#4). A positionally-destructured struct
  records nothing and raises no error.
- **Written is not read.** A round-trip through the store proves only that the store works.
  `SavedVariablesMachine` is the clean example: it accepts everything written to it and reports
  "first ever run" on every load, even on 70009 where the other two scopes were fixed.

  > **CORRECTED, 2026-09-25.** This bullet used to cite `test_cameraOverShoulder` as a CVar the
  > camera "ignores entirely", and that was its only example. It does not ignore it. The write
  > lands and the camera honours it - and then `CameraKeepCharacterCentered` re-centres the
  > character and undoes it. Applied-then-cancelled, not ignored (#25, and the camera section
  > below, which carries the same banner). The observable was identical, which is exactly why the
  > conclusion deserved a second probe rather than trust.

**The three that cost us:**

| API | probed as | read as | actually |
|---|---|---|---|
| `GetFramesRegisteredForEvent` | one return value | empty list | varargs |
| `GetCVarInfo` | global | deleted | moved to `C_CVar` |
| `TryOn` | global | absent | a `DressUpModel` widget method |

**A negative result deserves a second probe.** "It is missing" is a conclusion with consequences -
a rewrite, a deferral, a feature dropped. Before accepting one, check the other surfaces, and
check how a *working* client would answer the same probe. If the probe would print the same thing
on a healthy client, it has told you nothing.

Reference implementations settle it faster than reasoning does. Narcissus 1.8.6 (Retail, Interface
120100) answered both the `TryOn` and the `CameraZoomIn(0)` questions in about a minute of grep,
without being installed.

---

## Client

```
GetBuildInfo()  ->  "1.60.1", "69913", "Sep 17 2026", 16001, "", " "
WOW_PROJECT_ID  ->  1  (== WOW_PROJECT_MAINLINE)
```

`## Interface: 16001` confirmed from the client itself.

**Level cap: use `GetMaxPlayerLevel()` — it returns `60`. `MAX_PLAYER_LEVEL` is `nil`.**
Every hardcoded `70` in the port becomes `GetMaxPlayerLevel()`, not a literal `60`.

`GetAverageItemLevel()` returns **three** values (total, equipped, pvp), and they are
**fractional** — Second returned `0.3125, 0.3125, 0.3125`. Anything formatting item level must
round; Classic's values were effectively integral.

---

## SavedVariables are WRITTEN but never READ BACK — *history, builds 69913 and 69977*

> **Fixed in 1.60.1.70009.** Both stores load again; see the 70009 section below for the
> measurement. Everything under this heading describes the two builds before it and is kept
> because the reasoning — and the way it was originally got wrong — is the useful part. Do not
> plan around it, and do not follow its re-test instruction: a `/reload` cannot answer this
> question. The procedure is a full client exit, in `docs/RUNBOOK.md`.

**Blocking client bug, confirmed on build 69913.** This reverses what the porting guide originally
claimed, and the earlier reasoning is worth recording because it was a plausible mistake.

Measured with a load counter in `Tools/AltStableProbe`: read `AltStableProbeDB.loadCount` at
`PLAYER_LOGIN`, report it, then increment.

```
session 1  ->  "first ever run (no loadCount in the table)"    ... writes loadCount = 1
/reload
session 2  ->  "first ever run (no loadCount in the table)"    <- read back as NIL
```

The file on disk at that moment:

```lua
AltStableProbeDB = {
  ["lastLoadStamp"] = "2026-09-20 20:13:22",
  ["loadCount"] = 1,
}
```

The write side is perfect. The client never executes the SavedVariables file on load.

**Why this was missed.** The original check diffed a third-party addon's SV file against its `.bak`
and found 232 identical key/value pairs. That proves the addon is deterministic, not that the data
round-tripped — an addon writing its full default table every session produces two identical files
either way. The settings cited as "non-default" were never verified as such.

**Why it stayed hidden in this addon specifically.** `AltStableDB` looks like it persists, because
`ScanCharacter` rewrites the current character on every login. Only `AltStableConfig` exposed it —
the whitelist and account number are set once and never regenerated, so they appeared to "vanish".
Anything that rebuilds its state on login will mask this.

Re-test on every build — but with a **full client exit and relaunch**, never the two reloads
this section originally prescribed. A reload keeps the process alive, so the in-memory table is
handed back untouched and a broken client reads as a working one; that is how the bug survived
being "checked" more than once. 70009 was measured the right way.

---

## Rendering a character who is not logged in — measured, 1.60.1.70009

The short version: **you can render an offline character's body, and you cannot texture it.**
Every path that produces a textured character needs a live unit token.

Measured with `Tools/AltStableProbe` (`/asmodel`, `/asscene`) on 70009, rendering saved data from
one character while logged in as another — a test that only became possible once #23 was fixed.

| What | Result |
|---|---|
| `DressUpModel:SetUnit("player")` | **Fully textured**, and with `SetAutoDress(true)` wearing the character's own gear. The live character is perfect. |
| `DressUpModel:SetDisplayInfo(savedDisplayID)` | Correct **geometry** — right race, right gender, distinct per character (different `GetModelFileID`) — and **no texture at all**: a white body. |
| `DressUpModel:TryOn(link)` on that model | Every call succeeds (11/11), and **weapons render in full colour**. Armour appears as untextured geometry. |
| `ModelSceneActor:SetPlayerModelFromGlues(1..4)` | **`false`** for every index. The character-select cache is not reachable in-game. |
| `ModelSceneActor:SetModelByCreatureDisplayID(id, useActivePlayerCustomizations=true)` | `true` — but the flag composites the **active player**, so it can only ever be you. |
| `SetUseTransmogSkin(true)` / `SetUseTransmogChoices(true)` | Blackens the face. Not the missing ingredient; their own bug. |

### Why

Skin, face, hair and armour are baked into **one composite texture** built from a character's
customization choices. A display ID does not carry those choices, so the client builds the mesh
and has nothing to paint it with. Weapons are separate models carrying their own textures, which
is why they come out perfect on an otherwise white body — that contrast is what localises the
failure, and it is worth reproducing before concluding anything about "models not working".

`GetDisplayInfo()` returns **0** after `SetUnit`, confirming the unit path does not go through a
display ID at all.

### What this means for an alt-tracker UI

- The **currently played** character can be rendered live and looks perfect.
- Any **other** character can be rendered as an untextured figure, optionally holding its real
  weapons, or not at all.
- An exact offline likeness needs pre-rendered images. On TBC that came from scraping the
  Battle.net armory; Forever has no armory, so the only source is an in-game screenshot converted
  to TGA by hand and shipped with the addon.

This is the same wall the TBC-era port hit. The difference is that it is now measured rather than
assumed, and the boundary is precise: geometry yes, weapons yes, composite no.

---

## Identity — surnames are real, and WHERE they live changed in 70009

> **This section was measured on 69913/69977 and the shapes below changed in 1.60.1.70009.**
> `AGENTS.md` names this file as the arbiter when a stub shape is in question, so read the 70009
> block first — `tests/wow_stubs.lua` models the new shapes, and they contradict the old ones.

### On 1.60.1.70009 (measured in game, `/run` on Kaleid Sumner)

```
UnitName("player")          ->  "Kaleid", "Sumner"     -- TWO returns now
UnitNameUnmodified("player")->  "Kaleid", "Sumner"
UnitFullName("player")      ->  "Kaleid", "Sumner"     -- second return is the SURNAME, not the realm
GetUnitName("player", true) ->  "Kaleid Sumner"        -- joined, one string
UnitPVPName("player")       ->  "Kaleid Sumner"        -- joined, one string
```

The surname moved out of the first return and into the second — the slot documented as
`unitServer`. Code that read only the first return silently began storing half a name: see #56,
where the scan stored `"Kaleid Sumner"` on 69977 and `"Kaleid"` on 70009 from the same line. This
is also what the build's new `C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator` is about.

Consequences worth carrying into any addon:

- **Read names through one adapter.** Ours is `AltStable.API.PlayerFullName()` (`Compat.lua`),
  which joins both shapes so a record written on either build reads the same. It is **player-only
  on purpose**: for any other unit that second return really is a realm, and gluing a realm on
  with a space invents a character.
- **`UnitFullName` no longer yields the realm.** Use `GetRealmName()` / `GetNormalizedRealmName()`.
- **A name comparison is now a version check in disguise.** Anything asserting a stored name still
  equals a freshly read one will fire across the 69977/70009 boundary — for us it was the sync
  rule that refuses a record whose name changed, which rejected each character's own updates.

### On 1.60.1.69913 and .69977 (history)

```
UnitName("player")          ->  "Example Surname",  nil
UnitFullName("player")      ->  "Example Surname",  "ClassicBetaPvE"
UnitNameUnmodified("player")->  "Example Surname",  nil
GetUnitName("player", true) ->  "Example Surname"
UnitGUID("player")          ->  "Player-1234-0000AAAA"
GetRealmName()              ->  "Classic Beta PvE"
GetNormalizedRealmName()    ->  "ClassicBetaPvE"
C_PlayerInfo.ShouldDisplaySurname()  ->  true
```

Findings that matter (all still true on 70009 — only where the surname *lives* changed):

1. **The surname is part of the name string, separated by a SPACE** — `"Example Surname"`, not
   `Example-Surname`. The hyphenated form only appears in WTF folder names on disk.
2. **`GetPlayerInfoByGUID` returns the FIRST NAME ONLY** at position 6:
   ```
   GetPlayerInfoByGUID(guid) -> "Paladin","PALADIN","Undead","Scourge",3,"Example","",1
   ```
   So the two identity sources disagree. Anything displaying names from a GUID silently drops the
   surname.
3. **`C_PlayerInfo.GetName` takes a PlayerLocation, not a unit token** — `GetName("player")` errors.
   Another false friend.

Confirmed on a second character:
```
UnitName("player")        ->  "Second Surname"
UnitGUID("player")        ->  "Player-1234-0000BBBB"
GetPlayerInfoByGUID(guid) ->  ..., [6]="Second", [7]="", ...
```
Same realm ID (`1234`) for both characters, and the same split: full name with surname from
`UnitName`, first name only from `GetPlayerInfoByGUID`.

### UnitName on OTHER units splits the surname into the second return

Measured from a party member:

```
UnitName("player")   ->  "Karuzo Elegia",  nil        full name, nothing in slot 2
UnitName("party1")   ->  "Zoruka",         "Mortalis" first name, SURNAME in slot 2
UnitFullName("party1") -> "Zoruka",        "Mortalis"
```

Slot 2 is classically the **realm**. Here it carries the surname — and the
party member is on the same realm ("Classic Beta PvE"), so this is not a realm
value at all. The idiom

```lua
local name, realm = UnitName(unit)
if realm and realm ~= "" then name = name .. "-" .. realm end
```

therefore produces `"Zoruka-Mortalis"`, which reads as a realm-qualified name
and will be mangled by anything that later strips a realm by splitting on `-`.

Our code is unaffected — every `UnitName` call site is `"player"` — but any new
code reading another unit's name must not assume slot 2 is a realm.

### New race: Skyborne

Forever adds a playable race the Classic clients do not have:

```
GetPlayerInfoByGUID(guid)            ->  ..., [3]="Windshaper Skyborne", [4]="Skyborne", ...
C_PlayerInfo.GetPlayerCharacterData() ->  { fileName="Skyborne",
                                            name="Windshaper Skyborne",
                                            createScreenIconAtlas="raceicon-skyborne-female" }
```

**One race key, two faction-dependent display names.** "High Order Skyborne"
and "Windshaper Skyborne" both report `fileName = "Skyborne"`, so no
key-to-name table can render them correctly — the localized name has to be
captured per character at scan time.

The atlas slug is the lowercased key (`raceicon-skyborne-female`), which holds
for every race measured. `Scourge -> undead` remains the only exception, so the
icon is better derived than looked up: an allowlist returns `""` for anything
it has not heard of, which is how a new race silently renders nothing.

### What this means for sync

Better than feared. `PeerShort()` splits on `-` to strip the realm, and a Forever name contains a
space rather than a hyphen — so `"Example Surname"` passes through intact and `"Example Surname-Realm"`
still splits correctly. **The existing realm-stripping logic is not broken by surnames.**

**But 70009 broke the other side of that comparison.** The sender on `CHAT_MSG_ADDON` is still the
whole joined name (`Receiving data from Kaleid Sumner`, live) — while `UnitName("player")` read
naively is now only the first half, so the self-echo check stopped matching and a client processed
its own broadcasts. Our own name has to come from the adapter, not from `UnitName` directly.

Still **unverified**: what `sender` contains for a *cross-realm* whisper. And note that
`Core.lua:1343` strips any realm suffix and `Core.lua:1363` then uses that stripped value as the
reply target — correct for the self-echo comparison, wrong as a routing address. See
`docs/SYNC-DISCOVERY.md`.

The residual risk is narrower than the plan assumed: two characters can share a *first* name, but
the full name including surname still looks unique. Names are keys only for peer watermarks and
whitelist matching, and those use the full string.

### RESOLVED — cross-account whisper test, two accounts online

```
sender side:    whisper PING -> "Example Surname"          sent
                RECV prefix=ASPROBE channel=WHISPER
                     sender="Example Surname"  text="PONG|Example Surname"

receiver side:  RECV prefix=ASPROBE channel=WHISPER
                     sender="Second Surname"   text="PING|Second Surname"
                replied PONG to sender string exactly as received
```

Three answers, all favourable:

1. **A whisper target containing a space routes.**
   `C_ChatInfo.SendAddonMessage(prefix, msg, "WHISPER", "Example Surname")` was delivered.
2. **`CHAT_MSG_ADDON` `sender` is the FULL name including the surname, space-separated, with no
   realm suffix** (same-realm): `sender="Second Surname"`. Not the first name, not hyphenated.
3. **The round trip works** — replying to the `sender` string verbatim also routed, so the string
   the event hands you is directly usable as a whisper target.

**The sync design survives unmodified.** `PeerShort()` splits on `-` to strip a realm; the sender
string contains a space and no hyphen, so it passes through intact, and the resulting watermark /
whitelist key is the *full* name — which is unique even when two characters share a first name.
No redesign needed.

Cross-realm (`"Name Surname-RealmName"`) is untested, but `PeerShort` would strip the suffix
correctly by inspection.

### But two-word names DO break the slash parser

`Core.lua:1845`:
```lua
local cmd, target = args:match("^(%S+)%s+(%S+)$")
if not cmd then cmd = args:match("^(%S+)$") end
```
`(%S+)` captures a single whitespace-free token, and the pattern is anchored at both ends. So
`/alts sync Second Surname` is three tokens, matches **neither** pattern, leaves `cmd = ""` and the
command **silently does nothing**. Same for `/alts whitelist <name>`.

Fix: capture the rest of the line and trim —
```lua
local cmd, target = args:match("^(%S+)%s+(.+)$")
```
Every place that accepts a character name from user input needs the same treatment.

---

## Skills — a STRUCT, not a tuple

**This contradicts the plan.** The plan said to verify tuple positions 1/2/4/7. There is no tuple:

```
C_SkillInfo.GetNumSkillLines()  ->  15
C_SkillInfo.GetSkillLineInfo(2) ->  {
    name="Holy", isHeader=false, rank=1, maxRank=1, skillID=594,
    skillLineCategoryID=7, parentSkillLineID=0, description="",
    modifier=0, minLevel=0, isCollapsed=false, isAbandonable=false,
    costType=0, rankCost=0, stepCost=0, tempPoints=0
}
```

`Scanner.lua:578` —
`local skillName, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)` — must become struct
field access. A same-name alias would have yielded **empty professions with no error**, exactly the
failure the probe existed to catch.

The list includes headers (`isHeader=true`) interleaved with entries, same as Classic. Languages
carry `rank=300, maxRank=300`.

**Weapon/defense `maxRank` scales with level** (5 x level): at level 1 it was `5`, at level 3 `15`.
So a profession/skill column must read `maxRank` per row rather than assuming a cap — and the
TBC-era hardcoded `375` in `RowRenderer.lua:1053,1064` is wrong twice over (Vanilla caps at 300,
and skill maxima are dynamic).

---

## Professions

```
GetProfessions()  ->  nil × 7        (character has no professions)
C_TradeSkillUI.GetAllProfessionTradeSkillLines()
   ->  {164, 165, 171, 182, 186, 197, 202, 333, 393, 2933, 2934, 2937, 2938,
        2940, 2941, 2944, 2945, 2946, 2947, 2948}
```

The low IDs are the familiar Vanilla skill lines (164 Blacksmithing, 165 Leatherworking,
171 Alchemy, 182 Herbalism, 186 Mining, 197 Tailoring, 202 Engineering, 333 Enchanting,
393 Skinning). The `29xx` block is Retail-era.

---

## Build 1.60.1.69977 (2026-09-22) — API unchanged, #23 still broken (fixed two builds later, in 70009)

The client bumped from 69913 (built Sep 17) to 69977 (built Sep 22). The dump was regenerated
(`forever-api-1.60.1.69977.md`) and compared section by section against 69913:

**No change to the documented API.** Documented functions, documented events, enums and
structures, widget methods and namespace functions are byte-identical sets. The only differences
in the artifact are other addons' globals picked up by the `_G` walk (whatever was loaded when the
dump ran), which is why those two sections are not comparable between runs.

Re-measured in game on 69977, all unchanged:

```
GetMaxPlayerLevel()            -> 60
UnitXPMax("player")            -> 14400      (positive below the cap)
GetXPExhaustion()              -> 2020       (a number while rested; nil when not)
Enum.BagIndex.Keyring          -> -1
C_Reputation.GetNumFactions()  -> 9
type(TooltipDataProcessor)     -> "table"
```

**SavedVariables still do not load (#23).** The probe on a fresh launch: account-wide table
arrived NO, per-character NO, launches recorded before this one 0 — after previous sessions had
written the file. So the blocker survives this build; nothing an addon writes is read back.

---

## Build 1.60.1.70009 (2026-09-24) — **SavedVariables load. #23 is fixed.**

The blocker that shaped every testing assumption in this repo is gone. First login on the new
build, with the previous session's files untouched on disk:

```
[probe] SavedVariables (account) LOADED - previous loadCount=1
[probe] SavedVariablesPerCharacter LOADED - previous loadCount=1
[probe] SavedVariablesMachine first ever run - not loaded
[probe] account #2 / per-character #2 / machine #1
[AltStable dev] kept 2 saved sync peer(s) for Morphisto - the whitelist loaded from disk
```

A real test, not a `/reload`: the client was **shut down for the patch** and relaunched, and the
files on disk were written at 10:56 that morning by build 69977. Both scopes an addon actually
uses — `SavedVariables` and `SavedVariablesPerCharacter` — came back, and the whitelist inside
`AltStableConfig` was live in the session.

`SavedVariablesMachine` still reports "first ever run". It is Blizzard-only scope and AltStable
does not use it; the probe watches it for completeness. Not worth chasing.

What this unblocks: cross-session data (the whole point of the addon), `accountNumber` and the
whitelist staying set, delta sync against a watermark that survives, and every deferred item that
was waiting on "we cannot verify this until data persists".

### API diff, 69977 → 70009

Nothing AltStable uses changed. Widget methods are identical (7530). The rest:

**Namespace functions 5401 → 5417 (+18 / −2)** — the artifact's own counts. Three of those lines
are `Constants`, `Enum` and `MathUtil` placeholders ("no function members"), present in both
builds, so a script that counts only `Namespace.Member` lines sees 5398 → 5414 and the same delta.
All eighteen, since a partial list is how a "nothing to see here" becomes wrong later:

- `C_Flyout.FlyoutHasSpell` / `GetFlyoutID` / `GetFlyoutInfo` / `GetFlyoutSlotInfo` /
  `GetFlyoutTexture` / `GetNumFlyouts`
- `C_SocialRestrictions.AcknowledgeAgeVerificationRestriction` / `IsAgeVerificationRestricted` /
  `IsAgeVerificationRestrictedMinor`
- `C_GameRules.GetForeverExperiencePreset` / `SetForeverExperiencePreset` — these **replace**
  `SelectClassicExperiencePreset` / `SelectModernExperiencePreset`, the only two removals
- `C_Trainer.GetCategorizeTrainerUI` / `SetCategorizeTrainerUI`,
  `C_UnitAuras.GetRefreshCarryOverDuration`, `C_BattleNet.SetBlocked`,
  `C_FriendList.GetWhoRaceFilters`, `C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator`,
  `GameEvent.HandleAlertAgeVerificationRestricted`

**Enums and structures 792 → 797.** Five new: `Enumeration ForeverExperiencePreset`,
`Structure FlyoutInfo`, `Structure FlyoutSlotInfo`, `Structure SendWhoFilters`,
`Structure WhoFilter`. Three gained a field in place, which a name-only diff misses entirely:
`FrameTutorialAccount` (+`Reserved1`), `VoiceChatStatusCode`
(+`PlayerVoiceChatAgeVerificationRestricted`), `EditModeLayoutInfo`
(+`optional interfaceStyle:InputDeviceInterfaceType`).

**Events 1802 → 1805**: `ALERT_AGE_VERIFICATION_RESTRICTED`, `GLOBAL_REGION_MOUSE_DOWN`,
`GLOBAL_REGION_MOUSE_UP`. `LFG_LIST_SHOW_SEARCH` also gained a `showAllLevelRanges:bool` payload
field — same trap as the structures, so diff the section BODIES, not just the names.

The 22 `C_LocaleContext.*` entries now document as bare globals (`CompareStrings`, `FormatDate`,
`ToLower`, …). A documentation reshuffle, not a removal — nothing here calls them. Two other
apparent newcomers are the same effect: `C_AdventureMap`'s member set is byte-identical between
the builds, and `C_PvP.GetArenaOpponentSpec` existed on 69977 as a global. Both merely entered the
*documented* section.

`C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator` is the one to remember: Forever surnames are
this project's recurring edge (whitelist entries are two words, `strsplit` on names, peer keys), so
there is now a client function for the separator instead of guessing at it.

Re-measured in game on 70009, all unchanged:

```
GetMaxPlayerLevel()            -> 60
UnitXPMax("player")            -> 5400       (positive below the cap)
GetXPExhaustion()              -> 764        (a number while rested; nil when not)
Enum.BagIndex.Keyring          -> -1
C_Reputation.GetNumFactions()  -> 5
type(TooltipDataProcessor)     -> "table"
```

**Still unverified on this build:** whether CVars persist (they did not through 69977 — see the
camera CVars, #25) and whether secret values behave the same on a PvP realm. Neither was
re-measured here.

---

## Builds 1.60.1.70058 (2026-09-25) and 70124 (2026-09-29) — API unchanged, persistence holds

Both were dumped (`forever-api-1.60.1.70058.md`, `forever-api-1.60.1.70124.md`) and compared with
`Tools/ForeverAPIDump/Compare-Dumps.ps1`:

```
70009 -> 70058   documented functions, events, tables, widget methods, namespace functions: no change
70058 -> 70124   no change in any of the five (6596 / 1805 / 797 / 7530 / 5417)
```

The `_G`-walk sections moved only by other addons' globals (Attune, Priestly, RaidProbe,
RXPGuides), as on every previous build.

**Behaviour**, the RUNBOOK step-3 line: `60 19400 6966 -1 7 table` on 70058 and
`60 16000 16540 -1 9 table` on 70124 (a different character), all as expected.

**Persistence on 70124**, checked from disk and from the process rather than from chat:
`WowB.exe` started at 22:13:46. The old process last wrote AltStableProbe's account store at 22:13:42
with `loadCount = 333`. The first login of the new process (22:14:18) wrote 334, so it read 333 back
after a genuine full exit. The per-character store (Kaleid-Sumner) was at 51 in the new process,
where an unloaded store would restart at 1.

The 70058 persistence attempt did not count: both of its "relaunches" were `/reload`s, four seconds
between the write and the next load. Tell them apart by the game process's start time
(`Get-Process WowB`), with the timestamps only as a hint - never by a counter going up. A `[Probe] … launch #1` line is **PriestlyProbe**, another project's
probe, and says nothing about AltStable.

`MEASURED_ON_BUILD` went from 70009 straight to 70124. 70058 was measured but never bumped to.

---

## Secret values — some unit numbers cannot be read, only passed along

Hit live on 1.60.1.69977, on a **PvP realm**, mid-scan:

```
AltStable/Scanner.lua:596: attempt to perform arithmetic on a secret number value
                           (execution tainted by 'AltStable')
```

This client carries Retail's **secret values**. A secret is a value an addon may receive, hold and
hand back to the client, but must not inspect: arithmetic, comparison, `tostring` and concatenation
all throw. The error is not a nil-check failure and no `or 0` guard helps — the value is there, it
just cannot be touched.

Measured: `UnitStat`, `UnitArmor`, `UnitAttackPower`, `UnitHealthMax` and `GetMoney` all returned
secrets for the **player's own character** on that realm, while `UnitXPMax`, `UnitXP`,
`GetXPExhaustion`, `UnitLevel` and `UnitDefenseSkill` returned plain numbers in the same scan. So it
is per-API (and evidently per-realm-type), not a blanket switch: assume any unit number can be
secret and check the ones you do maths on.

The client's own predicate:

```lua
issecretvalue(v)        -- true for a secret value          [FrameScript]
issecrettable(t)        -- true if a table holds any
hasanysecretvalues(...)
scrubsecretvalues(...)  -- strips them out of a value list
canaccesssecrets()
```
`C_Secrets.*` holds the policy queries (`ShouldAurasBeSecret`, `ShouldUnitHealthMaxBeSecret`, …) —
useful for asking *whether* a category is secret, but `issecretvalue` is the value test.

What this costs an addon that stores and syncs numbers:

- **Arithmetic aborts the whole function.** The scan above died half-way, leaving the character
  record without professions, reputations or lockouts. One unguarded sum takes everything after it.
- **A stored secret is worse than a missing one.** It survives in the table (the error log shows
  `stat_str=<secret number>`), and then every later reader — a sort, a total, a `tostring` on the
  sync wire — throws in turn, far from the cause.
- **`nil`, not `0`.** A secret stat is *unknown*. Writing 0 renders as a real zero and, in AltStable,
  syncs that lie to every other account.

The shape that works: one adapter, and every unit read goes through it.

```lua
function API.IsSecretValue(v)
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, v)
        if ok then return secret and true or false end
    end
    -- Fallback for a build without the predicate. Strings and booleans FIRST:
    -- "Thrall" + 0 throws, and calling that secret drops every name and id from
    -- anything that filters on it. Numbers are probed rather than trusted,
    -- because what type() reports for a secret number is unmeasured.
    local t = type(v)
    if t == "string" or t == "boolean" then return false end
    local ok = pcall(function() return v + 0 end)
    return not ok
end

function API.PlainNumber(v)   -- a number you can store, compare and serialize, or nil
    if v == nil or API.IsSecretValue(v) then return nil end
    local ok, n = pcall(tonumber, v)
    return ok and n or nil
end
```

The two mistakes in that fallback are both ones this project actually made. The
string case dropped `guid`, `name` and `class` from every synced record on a
build without the predicate, which turned sync into a silent no-op; and trusting
`type(v) == "number"` would report the one case the fallback exists for as safe.

A third, further out: **a value that becomes unreadable has to propagate.** A
field stored as nil is simply absent from the wire, so a peer merging "only the
keys present" keeps the last number it saw and goes on displaying it as current.
Clear the fields an accepted snapshot owns before applying it.

**Still unmeasured: what `type()` reports for a secret.** A run on the character that produced the
error returned `number false` for
`local _, s = UnitStat("player", 1) print(type(s), issecretvalue(s))` - so `issecretvalue` is
callable and answers, but that read was NOT secret at the time, and the question stands. Until a
secret is caught in the act, the adapter probes numbers with arithmetic instead of trusting
`type()`: if a secret number reports as `"number"`, trusting the type would wave through the one
case the check exists for.

That run also shows the flag is not sticky - the same API on the same character returned a plain
number later. Whatever turns it on (realm type, group state, something else) can turn it off, so
"it worked when I tested" proves nothing here.

Two details that are easy to miss:

- **Comparisons throw too.** A "largest of" loop (`if sp > best`) is as fatal as a sum, and it hides
  behind a short-circuit on the first iteration.
- **A sum of parts is all-or-nothing.** `UnitAttackPower` returns base, positive and negative; if one
  is secret, the total is unknown, not smaller.

And for tests: a stub secret must NOT be a table, or any `type(v) == "table"` filter skips it and the
guard that matters never runs. Lua 5.1 cannot create userdata from script; a coroutine is a workable
stand-in, since arithmetic and comparison on one throw by themselves.

## Reputation — also a struct, and ByID reaches beyond the visible list

```
C_Reputation.GetNumFactions()  ->  5
C_Reputation.GetFactionDataByIndex(3) -> {
    name="Orgrimmar", factionID=76, reaction=4, currentStanding=2000,
    currentReactionThreshold=0, nextReactionThreshold=3000,
    isHeader=false, isCollapsed=false, isWatched=false, atWarWith=false, ...
}
```

Standing is `reaction` (4 = Neutral, 5 = Friendly). Again a struct, so the plan's "standing is
return 3" concern is moot — but so is any same-name alias.

**The important result: `GetFactionDataByID` returns factions that are not in the visible list.**
`GetNumFactions()` was 5, yet Argent Dawn (529), Cenarion Circle (609) and Thorium Brotherhood (59)
all returned full data. This **validates Codex's recommendation** to key reputations off a static
faction-ID map instead of walking the indexed UI list — no collapsed-header blind spots, and no
English-name matching.

`GetFactionDataByID(72)` (Stormwind) → `nil` on a Horde character, as expected.
`GetFactionDataByID(270)` (Zandalar Tribe) → `nil` — that content may simply not be in yet. Re-check
before building the faction map.

**ByID does not mean "met" (1.60.1.69913, both sides).** A fresh level-1 Alliance character's list
held only the Alliance header (469, `isHeader`, reaction 5) and the four capitals, yet ByID returned
every Forever faction on its side at a starting standing — Kirin Tor and Darkspear Raiders read 1
(Hated), Barkskin Burrow 2. Showing ByID results would fill the sheet with red cells for factions
nobody has seen. AltStable counts a faction as met only when it appears in the (fully expanded) list.

Kaleid (Horde, level 14): Horde header (67, reaction 5), Darkspear Trolls, Orgrimmar, Thunder Bluff,
Undercity, then an **`Other` header with `factionID` 0** holding Nightclaw Druids (2758) and
Windshapers (2778). `0` is truthy in Lua — test IDs with `> 0`.

Forever-only faction IDs, confirmed by name on this build:

| ID | Faction | Side (nil from the other) |
|---:|---|---|
| 2719 | Cenarion Scouts | both |
| 2740 | Kirin Tor | both |
| 2747 | Barkskin Burrow | both |
| 2758 | Nightclaw Druids | both |
| 2765 | Guardians of Hyjal | both |
| 2778 | Windshapers | Horde |
| 2779 | High Order | Alliance |
| 2782 | Bolder'ok Clan | Horde |
| 2787 | Earthen Ring | Horde |
| 2798 | Darkspear Raiders | both (Hated for Alliance) |
| 2799 | Theramore Expeditionary Force | both (Hated for Horde) |
| 2819 | The Watchers | both |
| 2826 | Brotherhood of the Horse | Alliance |
| 2827 | Powderfuse | both |
| 2586 | Azeroth Commerce Authority | Alliance |
| 2587 | Durotar Supply and Logistics | Horde |

---

## Items

```
C_Item.GetItemInfo(6948) -> 18 returns, classic layout:
  "Hearthstone", "[Hearthstone]", 1, 1, 0, "Miscellaneous", "Junk", 1,
  "INVTYPE_NON_EQUIP_IGNORE", 134414, 0, 15, 0, 1, 0, nil, false, ""

C_Item.GetItemInfoInstant(6948) -> 6948, "Miscellaneous", "Junk",
                                   "INVTYPE_NON_EQUIP_IGNORE", 134414, 15, 0
```

Both keep the Classic return order, so these two **are** safe direct aliases.

**Confirmed false friend:**
```
C_Item.GetItemIconByID(6948) ->  134414          OK
C_Item.GetItemIcon(6948)     ->  ERROR: bad argument #1 (Usage: C_Item.GetItemIcon(itemLocation))
```
The plan's fix was right, and is now proven rather than inferred.

**Cache miss returns NO values at all** — not `nil`:
```
C_Item.GetItemInfo(21877)  ->  (no returns)
```
The adapter must preserve that. `select(n, ...)` is safe; `{...}` yields an empty table.

**The two runs proved this is per-client-cache, not per-item.** The identical call returned full
data on one character and nothing on the other:

| Call | Character A | Character B |
|---|---|---|
| `C_Item.GetItemInfo(19019)` | 18 returns | **(no returns)** |
| `C_Item.GetItemQualityByID(19019)` | `5` | **`nil`** |
| `C_Item.GetItemStats("item:19019")` | full table | **(no returns)** |

One character's client happened to have Thunderfury cached; the other's did not. So **any item lookup can
come back empty at any time**, and a gear scan that runs before the cache warms will silently
record nothing. `Scanner.lua`'s existing `PendingGearSlots` retry driven by
`GET_ITEM_INFO_RECEIVED` is therefore load-bearing, not belt-and-braces — keep it, and make sure
the unguarded call sites (`Scanner.lua:655`, `Core.lua:1639`) go through it.

### Item levels confirm the colour-gradient bug

```
Thunderfury (19019): quality=5 (epic), itemLevel=80, reqLevel=60
```

`RowRenderer.lua:517-522` breakpoints are `ILVL_POOR=60, ILVL_COMMON=80, ILVL_UNCOMMON=100,
ILVL_RARE=115, ILVL_EPIC=125`. **A Vanilla legendary at ilvl 80 lands on the grey→white boundary.**
Every Vanilla raid epic would render as junk. Codex flagged this from the code; the probe confirms
the numbers. Colour by `quality`, not by item level.

`IlvlCeiling()` (`RowRenderer.lua:515`) also reads from `AltStable.GetBisTier()`, which does not
exist once BiS is dropped — so this code path must be replaced, not just re-tuned.

---

## Containers — bag `-1` is the KEYRING, not the bank

**This is a real bug the plan would have shipped.**

```
bag -1   slots=32   name="Keyring"
bag  0   slots=20   name="Backpack"
NUM_BAG_SLOTS = 4        NUM_BANKGENERIC_SLOTS = nil     NUM_BANKBAGSLOTS = nil
```

`AltStableWarband.lua:29-31` has:
```lua
local BAG_IDS   = { 0, 1, 2, 3, 4, -2 }        -- -2 assumed to be the keyring
local BANK_IDS  = { -1, 5, 6, 7, 8, 9, 10, 11 } -- -1 assumed to be the main bank
local MAIN_BANK = -1
```
On Forever, **-1 is the keyring**. Warband would scan the keyring as the main bank, and `-2`
(its assumed keyring) does not report slots at all. Both constants are wrong.

`GetContainerItemInfo` returns a **struct** — Warband's existing dual-shape `ReadSlot` at `:79`
already handles this, which is why that plugin was the safe one to port first:
```
{ itemID=4604, itemName="Forest Mushroom Cap", hyperlink="[…]", stackCount=4,
  quality=1, iconFileID=134534, isBound=false, isLocked=false, hasLoot=false, … }
```

### Bank — RESOLVED, and the container IDs all moved

`Enum.BagIndex` is the authoritative map, and Forever uses the modern Retail bank-tab layout:

```
Keyring          = -1        <- was -2 on Classic
Characterbanktab = -2        <- bank-type pseudo-ids, not readable containers
Accountbanktab   = -3
Backpack         =  0
Bag_1 .. Bag_4   =  1 .. 4
ReagentBag       =  5
CharacterBankTab_1 .. _9 =  6 .. 14
AccountBankTab_1   .. _9 = 15 .. 23
```

**Every one of Classic's bank constants is wrong here.** `MAIN_BANK = -1` is the *keyring*, and
`BANK_IDS = { -1, 5..11 }` mixes the keyring, the carried reagent bag, and six bank tabs.

The good news: **bank tabs are ordinary containers.** No special API needed to read them —

```
bag 6   slots=48   name="Bank"
C_Container.GetContainerNumSlots(6)      ->  48
C_Container.GetContainerItemInfo(6, 1)   ->  { itemID=3282, itemName="Battle Chain Pants", ... }
```

Tabs are purchased individually, so the set is **dynamic** and must be queried, not hardcoded:

```
C_Bank.FetchNumPurchasedBankTabs(Enum.BankType.Character)  ->  1
C_Bank.FetchPurchasedBankTabIDs(Enum.BankType.Character)   ->  { 6 }
C_Bank.FetchMaxNumBankTabs(Enum.BankType.Character)        ->  9
C_Bank.FetchPurchasedBankTabData(Enum.BankType.Character)
   ->  { { ID=6, bankType=0, name="Tab 1", icon=134400, depositFlags=0 } }
```

(The 8 padlocked "Bag Slots" in the bank UI are the 8 *unpurchased* tabs — 9 max minus 1 owned.
Next one costs 1000 copper.)

### Account bank: exists in the API, not enabled — exclude it

```
Enum.BankType                                 ->  { Character=0, Guild=1, Account=2 }
C_Bank.CanViewBank(Character=0)               ->  true
C_Bank.CanViewBank(Guild=1)                   ->  false
C_Bank.CanViewBank(Account=2)                 ->  false
C_Bank.FetchViewableBankTypes()               ->  { 0 }          (Character only)
C_Bank.FetchNumPurchasedBankTabs(Account=2)   ->  0
C_Bank.FetchMaxNumBankTabs(Account=2)         ->  9              <- but the capacity is defined
```

So there is no account-wide bank *today*, but the client is plumbed for one (tab cost 100, with a
purchase prompt reading "storage that is shared with all members in your Account").

**This is the trap Codex flagged.** If account tabs (ids 15–23) are ever enabled and get folded
into each character's bank map, the same shared items are counted once per alt and every cross-alt
total inflates. Warband must filter by `bankType`, taking only `Enum.BankType.Character`, rather
than sweeping a numeric range.

### What Warband needs

```lua
-- carried
BAG_IDS = { 0, 1, 2, 3, 4, 5 }          -- backpack, 4 bags, reagent bag (-1 keyring if wanted)

-- bank: query, never hardcode
C_Bank.FetchPurchasedBankTabIDs(Enum.BankType.Character)   -- currently { 6 }
```
`MAIN_BANK` as a concept goes away — there is no single main bank container, just tab 1.
`AltStableWarband.lua:182`, which classifies bags 5–11 as bank bags, is wrong in both directions:
5 is a carried reagent bag, and the bank starts at 6.

---

## Tooltips — the predicted load-blocker is real

```
GameTooltip:HookScript("OnTooltipSetItem", fn)
   ->  ERROR: bad argument #2 (Usage: self:HookScript(scriptTypeName, script [, bindingType]))

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, fn)  ->  installed
GameTooltip:SetHyperlink("item:6948")                                   ->  ok
   fired:  OnTooltipSetItem = false        TooltipDataProcessor = true
```

The script type doesn't exist, so **`HookScript` itself throws** — it isn't merely a hook that never
fires. `AltStableWarband.lua:434` calls exactly this inside `EnsureTooltipHook()`, reached during
bootstrap, so it would **abort Warband's plugin registration**. Confirmed, as predicted.

Fix: `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, …)`. `C_TooltipInfo` is
also present and `C_TooltipInfo.GetHyperlink("item:6948")` returns structured tooltip data.

---

## Events — 2 of 23 rejected

Rejected (throw on `RegisterEvent`):
- `PLAYERBANKBAGSLOTS_CHANGED`
- `TRADE_SKILL_UPDATE`

Accepted, including all of Core.lua's: `PLAYER_LOGIN`, `CHAT_MSG_ADDON`,
`PLAYER_EQUIPMENT_CHANGED`, `GET_ITEM_INFO_RECEIVED`, `PLAYER_MONEY`, `PLAYER_UPDATE_RESTING`,
`PLAYER_XP_UPDATE`, `UPDATE_INSTANCE_INFO`, `MAIL_INBOX_UPDATE`, `CHAT_MSG_SYSTEM`, `BAG_UPDATE`,
`BAG_UPDATE_DELAYED`, `BANKFRAME_OPENED`, `BANKFRAME_CLOSED`, `PLAYERBANKSLOTS_CHANGED`,
`SKILL_LINES_CHANGED`, `UPDATE_FACTION`, `PLAYER_LEVEL_UP`, `TRADE_SKILL_SHOW`,
`TRADE_SKILL_LIST_UPDATE`, `TRADE_SKILL_DATA_SOURCE_CHANGED`.

### `GetFramesRegisteredForEvent` returns VARARGS — read from the API reference, not probed

The one entry on this page that is **not** a probe measurement. It is here because the wrong read
is silent and it shipped twice; item 5 under "Still to measure" is the probe line that settles it.

```
GetFramesRegisteredForEvent(event)  ->  frame1, frame2, ...        (varargs)
                                   NOT  { frame1, frame2, ... }    (a table)
```

Why the wrong read costs a whole feature rather than throwing:

```lua
local ok, frames = pcall(GetFramesRegisteredForEvent, ev)
if ok and type(frames) == "table" then    -- passes: `frames` is the FIRST FRAME
    for _, f in ipairs(frames) do         -- never runs: a frame has no array part
```

A frame **is** a Lua table, so `type()` says "table". It has no array part, so `#frames` is `0`,
the loop body never executes, and the caller concludes that nobody is registered for the event.
No error, no stack trace, and any "how many did I find?" counter reads back a confident zero.

Two consecutive attempts at the experimental-CVar popup suppression in `SheetUI.lua` shipped that
way before a review caught it (#24). Use `AltStable.API.FramesRegisteredForEvent(event)`, which
collects the varargs into a real list. `tests/wow_stubs.lua` models the vararg return, so a
table-shaped stub cannot let this ship a third time.

**Confirmed live 2026-09-20.** `AltStable.SuppressExperimentalCVarPopup()` returns the number of
frames it successfully unregistered, and on this client it returns `1` where every table-shaped
read returned `0`. That count only increments after `f:UnregisterEvent(ev)` succeeds, so a `1`
means the first returned value was itself a frame — a *table of* frames has no `UnregisterEvent`
and would have scored `0`. Varargs confirmed.

---

---

## CVars — the namespace moved halfway, and one conclusion here was wrong

> **CORRECTED, 2026-09-25 (build 1.60.1.70009).** Everything below about `GetCVarInfo` moving to
> `C_CVar` stands. The conclusion that the camera **ignores** `test_cameraOverShoulder` does not:
> the camera honours it, and `CameraKeepCharacterCentered` then re-centres the character and
> cancels the effect. Clear that CVar (and `CameraReduceUnexpectedMovement`) and the offset works -
> that is what #25 ships. Read the "writable is not read", "not shims" and "Narcissus" paragraphs
> below as a record of how a *cancelled* effect looked identical to an ignored one, not as current
> guidance. The one claim below that is **not** retracted is the `test_cameraDynamicPitch`
> measurement: nothing has re-tested it (see the note on it).

Measured 2026-09-20 on 1.60.1.69913, chasing #25.

```
GetCVar("test_cameraOverShoulder")        ->  "0.000000"     -- global, still works
SetCVar("test_cameraOverShoulder", 12)    ->  writes; GetCVar reads back 12
GetCVarInfo("test_cameraOverShoulder")    ->  ERROR: attempt to call a nil value

C_CVar.GetCVarInfo("test_cameraOverShoulder")
    ->  "0.000000", "0.000000", false, false, false, false, false
        value, default, storedServerAccount, storedServerCharacter,
        lockedFromUser, secure, readonly
```

`GetCVar` and `SetCVar` survive as bare globals. `GetCVarInfo` does **not** — it lives in `C_CVar`.
Assume nothing about the rest of the family; check each one before use.

**Writable is not the same as read — *retracted*.** `test_cameraOverShoulder` reports unlocked,
non-readonly and non-secure, accepts a write, and reads the value straight back — and appeared to
move the camera not at all, at `2.043` or at `12`. That appearance was `CameraKeepCharacterCentered`
cancelling it, not the camera declining to read it; the "same write-but-never-read shape as #23"
analogy drawn here was wrong in kind, not just in degree.

One observation from this paragraph is **unresolved**: the value also reverted to `0` on its own,
on 69913, without the confirmation popup's "Disable" ever being clicked. That has not been
re-measured on 70009, and the #25 fix would hide it if it still happens — `SheetUI` re-writes the
CVar on every Enter, so a revert between presentations is invisible. If the offset ever stops
working mid-session, look here first.

**The surviving globals are not shims.** Since `GetCVarInfo` moved to `C_CVar`, the obvious theory
is that `GetCVar`/`SetCVar` survive as compatibility wrappers over a shadow store that the engine
never reads. They do not: `SetCVar(name, 12)` then reading both ways returns `12, 12`. The value is
consistent everywhere. *(This paragraph's conclusion stands — the store is real and shared. Its
closing line, "the camera simply does not consult it", is the retracted claim: it does.)*

**`test_cameraDynamicPitch` — measured inert, and *not* re-tested.** Set to `1` and confirmed, it
changed nothing on 69913: no tilt while moving, where a working one is unmistakable. The heading
here used to read "it is the whole family, not one CVar", and that generalisation is withdrawn -
the shoulder offset turned out to work. But the reverse generalisation is not established either.
Nothing in #25 touches pitch: `CENTRING_CVARS` in `SheetUI.lua` lists only the two centring CVars,
no test exercises pitch, and nobody has re-run this on 70009. Treat it as an open measurement.
`CameraKeepCharacterCentered` is the obvious first thing to clear before concluding anything.

**And it is inert even when driven exactly as Narcissus drives it.** Narcissus 1.8.6 (Retail,
Interface 120100) still uses this CVar through the plain global `SetCVar`, with two steps we were
missing:

```lua
-- Narcissus/API/Camera.lua:198 - the engine does not recompute the offset
-- until the camera is nudged
CameraZoomIn(0);            --Incur shoulder update

-- Narcissus/API/Camera.lua:600 - the popup is an INTERNAL event in 12.1.0,
-- not a frame-registered one
GameEvent.UnregisterInternalEvent("EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED")
```

Both applied together, and the character still did not move — because `CameraKeepCharacterCentered`
was still set. Narcissus was being copied faithfully and the missing step was not in Narcissus at
all. Both of its steps are still required and both are in the shipped fix; they were simply not
sufficient on their own.

**~~Treat it as a beta bug~~ — withdrawn.** This was read as a client bug and reported to Blizzard
on 2026-09-20 against 1.60.1.69913. It is not a client bug: the CVar works, and a second setting
was undoing it. Nothing needs re-testing on each build, and nothing needs waiting for. See #25 for
the fix.

The `GameEvent` finding stands on its own merit: it is the correct way to suppress that popup on a
Mainline client, and it works here, where walking the frames registered for the event does not -
even though the frame walk reports success.

---

## Model widgets — present, including TryOn

```
CreateFrame("DressUpModel", nil, UIParent)  ->  created; TryOn, SetUnit, Undress all functions
CreateFrame("PlayerModel",  nil, UIParent)  ->  created; SetUnit, SetCamera present
```

`TryOn` is a widget method, never a global - `type(TryOn)` is `nil` here and on live Retail alike,
which is how the Roster plugin (#15) came to be deferred on an API blocker that did not exist. The
model panel is viable on this client; what remains in #15 is content, not API.

---

## Draw order inside one layer — sublevel first, then creation order

`CreateTexture` takes **four** arguments and the third is the TEMPLATE, not the sublevel:

```lua
frame:CreateTexture(name, drawLayer, templateName, subLevel)
```

Which matters because dropping the template slot silently shifts the sublevel into it and the
texture ends up with none. Between two textures the client resolves who is in front in this order:

1. draw layer (`BACKGROUND` < `BORDER` < `ARTWORK` < `OVERLAY` < `HIGHLIGHT`)
2. **sublevel** within that layer
3. **creation order** — later wins

So two textures in the same layer with no sublevel are ordered by which line of code ran first.
This bit us twice in the same commit: an inset with a border drawn after it is not a border, it is
a **lid** — the edge covers the whole inset and the result reads as one flat rectangle. Same for a
quality border created after the icon it frames. Both look like a subtlety problem and are not.

`SetDrawLayer(layer[, sublevel])` **resets the sublevel to 0** when the second argument is
omitted, rather than leaving the previous one in place — so a later `SetDrawLayer` undoes a
sublevel set at creation.

There is **no `GetColorTexture`**, and `GetVertexColor` is a different thing: it returns the vertex
tint, which `SetColorTexture` does not touch. A solid colour is write-only as far as the API is
concerned, so a test suite has to record it at the stub.

---

## Two conflicting anchors beat an explicit SetHeight

Anchoring `TOPLEFT` and `RIGHT` to the same y is a request for a height of zero: `TOPLEFT` pins the
top there and `RIGHT` pins the vertical centre there. The widget vanishes, and a `SetHeight` after
it does not rescue it. For a wrapping FontString that needs a left and a right edge, both points
have to be on the same horizontal — `TOPLEFT` + `TOPRIGHT`.

---

## UIPanelButtonTemplate overrules SetTextColor when disabled

A disabled `UIPanelButtonTemplate` button swaps in its **disabled font object**, which reapplies
that object's colour and discards a `SetTextColor` set on the current font string. So "the active
tab is the disabled one, tinted with the accent colour" loses its tint and reads as *unavailable*
rather than *you are here*. State a button owns has to be a texture the addon creates, not a colour
the template is entitled to reset.

---

## GetItemInfoInstant needs no cache — derive, do not store

`GetItemInfoInstant(itemID)` takes a bare id and answers from the client's own item table, so it
resolves on the first call with no `GET_ITEM_INFO_RECEIVED` round trip. Its fourth return is the
**locale-independent** `equipLoc` token (`INVTYPE_SHIELD`, `INVTYPE_HOLDABLE`,
`INVTYPE_WEAPONOFFHAND`); `itemSubType`, two positions earlier, is the **localised display string**
and must never be compared against.

The porting consequence is about SavedVariables and sync, not about items: a field derived from an
id you already store is a field you should not store. We had `gearloc_<slot>` for seventeen slots
per character, which then had to be excluded from the wire for size — which meant every
peer-synced character could never answer the one question it existed for. Deriving it fixed the
remote case and removed seventeen keys and two sync-boundary special cases at once.

An id the client has genuinely never seen still returns nothing, and that resolves later as
`GET_ITEM_INFO_RECEIVED` — so "cannot tell" should queue a retry rather than stand as a verdict.

---

## Frame geometry — the minimap is 198, not 140

```
Minimap:GetWidth(), Minimap:GetHeight()  ->  197.99984741211, 197.99998474121
```

Classic's minimap is 140 across, so addons that hardcode a radius of ~80 to sit "just outside the
ring" land their buttons 29px INSIDE it here - the ring is at 109. Measure the frame; it is a child
coordinate space, so no scale conversion is involved. Fixed for our own button in #26.

---

## GetCritChance and GetHitModifier both work — MEASURED

```
GetCritChance()    ->  1.66      level 18 gnome warlock
GetHitModifier()   ->  0         a character with no +hit gear
```

Both MEASURED on 1.60.1.70009. Both therefore have build-verified producers and are scanned;
neither is on `RETIRED_FIELDS` any more.

`GetHitModifier` was the doubtful one, and it was measured twice — first with a two-state probe
that happened to be conclusive, then with the four-state one below, which agreed:

```
/run print(GetHitModifier and GetHitModifier() or "ABSENT")
0

/run local f=GetHitModifier if not f then ... end
RETURNED 0
```

The second reading is the one that settles it, because it is the one that *could* have said
something else. Four outcomes matter and they lead to four different decisions:

| printed | meaning | what you do |
|---|---|---|
| `ABSENT` | the global does not exist | drop the feature, or find its replacement |
| `THREW ...` | it exists and errors when called this way | wrong arguments, or wrong API - see `C_Item.GetItemIcon` |
| `RETURNED nil` | it exists and answers nothing useful | do not persist it |
| `RETURNED 0` | it exists and answers | persist it; decide separately whether to DISPLAY a zero |

> **Do not use `print(f and f() or "ABSENT")`.** It reads well and it cannot tell two of those cases
> apart: `nil or "ABSENT"` is `"ABSENT"`, so a function that exists and returns nil reports as
> missing. `GetProfessions` on this client returns `nil x7` and would print `ABSENT` under it. That
> is the exact misdiagnosis this section exists to correct, and the line above was briefly
> prescribed here as the recipe for avoiding it.
>
> It was the first thing run for `GetHitModifier`, and its answer did stand — `0` can only come
> from a call that returned `0`, because both failure cases print `ABSENT`. A truthy answer is
> conclusive under the bad probe; that is the only thing it is good for, and it is luck rather than
> method: the same line would have reported `ABSENT` for a function that exists.

```
/run local f=GetHitModifier if not f then print("ABSENT") else local ok,v=pcall(f) print(ok and "RETURNED "..tostring(v) or "THREW "..tostring(v)) end
```

ONE `/run`, deliberately: a `local` does not survive between chunks, so splitting it over two lines
leaves `f` nil on the second and the probe reports `ABSENT` for everything. 150 characters with the
slash command, inside the edit box's 255 limit.

**VERIFIED IN GAME on 1.60.1.70009**, not merely reasoned about: pasted into the chat box as one
line, it printed `RETURNED 0`. So the length, the quoting, the `pcall` on a bare global and the
single-chunk `local` all work on this client, and the four branches were checked against all four
outcomes locally first. Copy it as-is.

Before this, "the Combat row did not render in game" was being read as evidence the function was
gone. It was evidence of a zero. Two rounds of comments in this repo asserted it was "a pre-WoD
global removed when hit rating was" — it is in the dump at line 4912 with a full signature, and it
runs.

**What is still unobserved is a NONZERO reading.** It reports the hit percent your GEAR adds, so
zero is the correct answer for a character with none, and no character with +hit has been measured.
That is handled in the display rather than by withholding the field: the Roster's row has no
`allowZero`, so it appears only for a character that actually has some. And the row is labelled
**"Bonus Hit"**, not "Hit Chance" — "Hit Chance 0%" would be telling the player they always miss,
which is the label being wrong rather than the number.

The general rule, which cuts both ways: presence in the dump says nothing about behaviour, and
absence of a rendered row says nothing about presence. For a value you intend to PERSIST, get one
live reading that separates all four cases above before you write a producer for it — and check that
the probe you wrote can actually express them, which the first one here could not.

---

## Other stats

```
UnitDefenseSkill("player")  ->  1, 0           (base, modifier — same contract as UnitDefense)
UnitStat("player", 1)       ->  24, 24, 0, 0
UnitAttackPower("player")   ->  31, 0, 0
GetXPExhaustion()           ->  nil            (not rested)
UnitXPMax("player")         ->  400
```

---

## Still to measure

1. ~~Bank~~ — **answered**, see above.
2. **Saved instances — DEFERRED TO POST-LAUNCH.** `GetNumSavedInstances()` was 0 and a raid lockout
   isn't obtainable on the beta, so `GetSavedInstanceEncounterInfo` ordering can't be confirmed.

   Consequence is limited to one feature, not the whole plugin. `GetSavedInstanceInfo` returns
   `encounterProgress` and `numEncounters` directly, so the **lockout grid and "X/Y bosses" progress
   need no ordering assumption**. Only a *named* per-boss kill list would: `ScanSavedInstances` in
   `Core.lua` encodes kills as a positional bitmask by encounter index, and reading it back as names
   means mapping those indices onto a static boss list. If Forever's ordering differs, that renders
   confidently wrong names.

   **The Raids plugin therefore ships aggregate progress only** (#11): it does not read the mask at
   all, and carries no boss-name lists - `tests/test_instances.lua` asserts both, so re-adding one
   without verifying the order fails the suite. The mask is still captured and synced, so the data
   is there the day a real lockout can confirm the ordering (#17).
3. **Professions** — re-run on a character that has some. Both probed characters returned
   `GetProfessions() -> nil x7`.
4. **Gear slot 18** (ranged/relic) — needs a character with something equipped there.
5. ~~**`GetFramesRegisteredForEvent`'s return shape**~~ — **answered live**, see above. The
   unregister count came back `1` where a table read scored `0`, which can only happen if the
   first return value is a frame. A probe line would still be tidier than inference if one is
   ever added.
6. **Does the camera subsystem read *any* `test_*` CVar on this client?** — **partly answered.**
   `test_cameraOverShoulder`: **yes**, it is read and honoured (below). `test_cameraDynamicPitch`:
   **unknown** — measured inert on 69913, never re-measured, and the thing that explained the
   shoulder offset was never ruled out for pitch. This item stays open until someone clears
   `CameraKeepCharacterCentered` and tries pitch again.

   > **CORRECTED, 2026-09-25 (build 1.60.1.70009).** This item used to read "answered, and the
   > answer is no", struck through as closed. It was neither. `CameraKeepCharacterCentered`
   > re-centres the character regardless of the shoulder offset, so the offset was being applied
   > and then immediately cancelled. Set that CVar to 0, as DialogueUI 1.0.5-f does (it comments
   > the line "11.0.2 Fix"), and the offset visibly shifts the character. Confirmed in game on
   > 70009.
   >
   > Set `CameraKeepCharacterCentered` and `CameraReduceUnexpectedMovement` to 0 alongside
   > `test_cameraOverShoulder`, and restore all three afterwards. Neither of those two is a `test_`
   > CVar, so neither needs the experimental-confirmation suppression the offset write requires.
   >
   > *Provenance, inferred not measured:* DialogueUI's "11.0.2 Fix" comment is the only evidence
   > for when `CameraKeepCharacterCentered` arrived upstream. Nothing here pins this client's
   > Mainline base to a particular release — the `.toc` says `Interface: 16001` and the nearest
   > comparison in this file is against a 12.1.0 addon. What is *measured* is that the CVar exists
   > on 70009, reads non-nil, and does what the fix depends on; the version story is a guess and
   > the fix does not rest on it.
   >
   > The lesson is not about CVars. "The client ignores this" and "the client obeys this and a
   > second setting undoes it" produce the SAME observable, and only one of them is a dead end.
   > A working addon doing the same thing was the cheapest way to tell them apart.
7. **A NONZERO `GetHitModifier`.** The function works — measured twice, `0` and `RETURNED 0`, the
   second under a probe that could have said otherwise — but it returns
   the hit percent your GEAR adds, and the character measured had none, so no nonzero reading has
   ever been seen on this client. Nothing incorrect is displayed either way: the Roster's Bonus Hit
   row has no `allowZero` and hides at zero. If you equip something with +hit and the row stays
   away, that is the case to report.

## What is under the cursor: GetMouseFoci, and it is a list

`GetMouseFocus` is **gone**. It was removed in 11.0 and this client is
Mainline-derived, so the call every older addon uses is simply absent — one more
false friend, and a silent one, because `GetMouseFocus()` on a nil global is a
"attempt to call a nil value" at the moment a player hovers something rather
than at load.

```
GetMouseFoci() -> region:table      [Input]      -- 1.60.1.70009 dump, line 5029
```

Plural, and it returns a **list**: more than one frame can be under the pointer,
and the one you want is often not the first. Read it as a list.

**Telling a list from a tuple needs care.** A widget IS a table with no array
part, so `type(foci) ~= "table"` cannot distinguish "a list of frames" from "one
frame, returned as the first of several values". Ask the first value whether it
answers `GetObjectType` — a frame does, a list does not. Guessing wrong here
reports "nothing under the cursor" while the thing is plainly hovered, which
sends you looking in the wrong place entirely.

`Tools/AltStableProbe/WhatIcon.lua` (`/asicon`) is the working example.
## A file id cannot be validated; a path can

Measured 2026-09-26 on 1.60.1.70009:

```
/run local t=UIParent:CreateTexture() t:SetTexture(999999999)
     print(t:GetTexture(), t:GetTextureFileID())
999999999   999999999
```

A **file id is stored, not resolved**. A nonsense one is echoed straight back by
both `GetTexture` and `GetTextureFileID`, so nothing you can ask a texture will
tell you the art is missing — the only symptom is that it draws nothing.

**A path is believed to be different — NOT MEASURED.** The plausible story is
that the client resolves a path to a file id and can fail to, making
`not tex:GetTexture()` after `SetTexture(path)` a real check. Nothing here has
tested it. To settle it:

```
/run local t=UIParent:CreateTexture() t:SetTexture("Interface\Nope\Nope")
     print(t:GetTexture(), t:GetTextureFileID())
```

Two reasons to doubt it rather than assume:

- `Plugins/Instances/AltStableInstances.lua`'s `LoadTexture` is cited as proof
  that paths are checkable, but it is only ever called on **addon** TGAs — and
  this repo already recorded, at `Plugins/Roster/AltStableRoster.lua`, that the
  client has **no FileDataID for an addon's own files**. So the one exemplar may
  be vacuous for the only paths it is used on. Delete a
  `Media\Raids\scene-raid-*.tga` and see whether `LoadTexture` still returns
  true.
- `GetFileIDFromPath` is a different function with a different caller
  (`API.TextureExists` in `Compat.lua`), and it has that same addon-file caveat:
  it returns nil for art the addon ships, so guarding on it **rejects real
  textures**. Roster removed exactly such a guard for that reason. Do not reach
  for it on the strength of this note.

**The trap, which is the measured part.** "Set it and check whether it took"
reads as prudent and, for a file id, can never fire. A fallback behind that
check is worse than none, because it claims the case is handled: a build that
renames the id gives a blank frame, no error, and a green suite saying
otherwise.

**What to do instead when there is no path.** Draw the fallback rather than
deciding it: put the known-good art on a lower layer and the file id over it.
An id that does not resolve draws nothing, so the layer beneath shows through —
no check, no branch, nothing to be wrong about. `SheetUI.lua`'s
`ApplyRosterIcon` is the worked example.

**With one condition: the top texture has to be opaque.** The measurement above
says a *missing* id draws nothing; it says nothing about how much of the frame a
*valid* one covers. Transparent pixels in the upper art reveal the backup at all
times, which trades a hypothetical future defect for a visible present one — so
look at it before shipping the pair. Checked for the Who-tab icon on 2026-09-26:
opaque, no bleed-through.

Finding the file-id half took a reviewer to doubt the check and one line in game
to settle it. The stub had been written to the same assumption as the code, so
the suite agreed with the mistake — and then the first correction asserted the
PATH half just as confidently, with no measurement behind it either. Hence the
caveat above rather than a second confident claim.

## A model frame auto-frames, so a render tells you nothing about size

Measured 2026-09-26 on 1.60.1.70009, building the Roster's scene view (#15).

`DressUpModel:SetUnit("player")` fits the model to the frame. That is the useful
behaviour almost everywhere and the wrong one here: it means the rendered image
is the same size for every race, so a screenshot of the stage carries **no
information about how tall the character is**.

Nine characters captured on one stage, as a fraction of screen height:

```
karuzo-morphisto   0.609      karuzo-komakino    0.641
morphisto-ruskador 0.614      karuzo-kashmere    0.643
karuzo-donstab     0.635      karuzo-macphisto   0.649
karuzo-spotnick    0.635      karuzo-sumner      0.649
karuzo-memphisto   0.640
```

A 6.6% spread, across a set including a gnome and several elves - races that
differ by roughly 40%. The 0.609 is the gnome; it is not meaningfully shorter
than anyone else.

**The trap is that a plausible wrong explanation fits.** The cutout pipeline
supersamples every image to a common height, so "the resampling flattened it"
looks like the answer, and recovering the pre-resample size looks like the fix.
It is not, and it does not: the flattening happened in the model frame, before
the screenshot. Two rounds of work went into recovering a number that was never
there.

**What to use instead.** `UnitRace()`'s fileName and `UnitSex()` are recorded per
character already, and a race-to-height table is exact, needs no capture, and
cannot drift with resolution or UI scale. To measure it from a render instead,
the stage has to stop auto-framing - a fixed camera distance and position via
`SetCamDistanceScale` / `SetPosition`, identical for every capture - and every
existing cutout has to be retaken against it.


---

## A menu of our own, and why MenuUtil went unused — UNMEASURED

`MenuUtil` is present on this client (32 functions), and it is the modern Retail
route. `AltStable`'s character menu (`CharacterMenu.lua`, #69) does not use it.

**What is actually known:** that the table exists and how many functions it has.
Nothing here has called `MenuUtil.CreateContextMenu` on this client. The decision
is a judgement, not a measurement, and it should be read as one. To settle the
first half of it:

```
/run MenuUtil.CreateContextMenu(UIParent, function(_, root) root:CreateButton("hi") end)
```

**The judgement.** Two of the reasons are about this client and one is about this
addon:

- *Present is not behaves.* That has been wrong repeatedly on this port, and a
  menu is not something Lua can interrogate the way it can a return value — you
  find out by looking at the screen.
- *The showcase problem is not hypothetical.* While the sheet is open the addon
  hides the game UI with `SetUIVisibility(false)`, and **no strata makes the
  child of a hidden parent draw**. The cure is to reparent out from under
  `UIParent` (`AltStable.LiftAboveHiddenUI`), which needs a handle to the frame.
  A menu built by somebody else does not reliably hand one over. This already bit
  the hide confirmation once, where a `StaticPopup` is likewise a child of
  `UIParent`.
- *The addon has its own dark theme*, so a Blizzard-styled menu over it is the
  inconsistent choice rather than the consistent one.

**What hand-rolling costs**, listed because it is the honest price and because
each item is a real bug somebody will otherwise rediscover:

| Concern | What goes wrong | What was done |
|---|---|---|
| Dismissal | nothing closes the menu, or the catcher eats the menu's own clicks | full-screen catcher as a **sibling below** the panel under one root; the panel takes the mouse itself so its padding does not fall through |
| Escape | `UISpecialFrames` closes the **sheet** instead — the sheet is registered too and comes first, and only one frame closes per Escape | the menu handles `OnKeyDown` itself and propagates every other key, or it is a menu you cannot walk away from |
| Cursor | `GetCursorPosition()` is in **physical pixels**, an anchor offset is in the frame's own units | divide by `GetEffectiveScale()`, then clamp to the screen |
| Lifetime | the menu outlives the window that raised it | the sheet's `OnHide` closes it — otherwise a full-screen click-catcher stays over the game, eating every click |
| Ordering | the action runs while the menu is still up, and the catcher swallows the first click at the confirmation it just raised | close first, then dispatch |

**Reparenting is idempotent now.** `_TakeOut` in `SheetUI.lua` previously saved
the frame's strata and scale on every lift, so lifting twice saved the *lifted*
values and the restore afterwards left the frame permanently at
`FULLSCREEN_DIALOG`. The two callers that existed each guarded at their own end,
which put the trap one careless caller away. The flag lives on the frame now.

### `SetPropagateKeyboardInput` in combat — UNMEASURED

Mainline's API documentation marks this method **restricted**, and Forever's own
`DialogueUI` guards it with `not InCombatLockdown()`. The build-matched dump
proves the method *exists* on 1.60.1.70009; it says nothing about whether
calling it in combat throws here.

That matters for anything that grabs the keyboard, because the grab and the
release are the same mechanism: `EnableKeyboard(true)` routes **every** key to
your frame, and `SetPropagateKeyboardInput(true)` is how each one is handed back.
If the release is unavailable, a frame that grabbed the keyboard swallows the
movement keys with no way to let go.

`CharacterMenu.lua` is written to be correct under either answer rather than
betting on one:

- the keyboard is taken **out of combat only** — not grabbing it costs Escape,
  which the sheet's own `UISpecialFrames` entry still answers; grabbing it and
  failing costs walking;
- **propagation is reset to true when the menu opens.** It is frame state that
  outlives the menu, and the last key of the previous opening is usually Escape,
  which set it to *false*. Inheriting that is how the first key of the next
  opening gets eaten;
- **the keyboard is released on `PLAYER_REGEN_DISABLED`.** The guard above only
  sees combat that was already running when the menu opened; this is the menu
  that was already open when the pull started;
- **and released again if the propagation call ever fails.** A `pcall` on its
  own preserves the handler and leaves the frame keyboard-enabled with its last
  propagation state — which swallows the key just as completely as an error
  would. Releasing the keyboard is the only thing that actually restores
  movement, because it stops the keys arriving at the frame at all;
- Escape closes the menu whether or not the propagation call took.

**The trap here is worth stating on its own**, because catching the exception
looks like handling it: *surviving is not working*. The first version of this
guard `pcall`ed the call and tested that pressing W did not throw. It did not
throw, and W still did not reach the game. The reachable sequence is open →
Escape → open again → enter combat → press W.

**To settle it**, with the character in combat:

```
/run local f=CreateFrame("Frame") f:EnableKeyboard(true)
     print(pcall(f.SetPropagateKeyboardInput, f, true))
```

`false` plus an `ADDON_ACTION_BLOCKED`-shaped message means the restriction is
live on this client and the guards above are load-bearing rather than cautious.

### `C_PlayerInfo.GetDisplayID()` does NOT change when you die — MEASURED

```
/run print(C_PlayerInfo.GetDisplayID(), UnitIsDeadOrGhost("player"))
56658   false        -- alive
56658   true         -- a ghost, mid corpse run
```

Same character, same session, 1.60.1.70009. **The display id is identical in
both states.** A ghost is a different *model* on screen and the same display id
to the API.

**This disproves a theory that was briefly in the code.** The portrait
pipeline's look fingerprint (`LookFingerprint` in the probe's `Render.lua`, removed
in #89 when capture moved into the addon without auto-capture — see git history) includes the display id, and a live corpse run produced three
captures in as many minutes, each announced as "gear changed since your last
portrait" on a character that had picked nothing up. Two events per death is the
shape a value flipping and flipping back produces, the gear half could not
explain it because equipment stays equipped while dead — so the display id was
blamed, and a substitution was written to keep the "ghost display" out of the
fingerprint.

There is no ghost display. The substitution was removed; it guarded against
something that does not happen.

**The symptom is real and the cause is still unknown.** It is one of the
nineteen equipment slots, since that is all the fingerprint has left.
`LookFingerprint` now reports *which field* changed rather than only that
something did, so the next occurrence names the slot instead of prompting
another round of reasoning.

**The lesson is the one this file already carries twice.** The theory was
plausible, fitted every observed fact, and was wrong. It had been written down
as "REASONED, NOT MEASURED" with the `/run` that would settle it — and settling
it took one line and thirty seconds. Cheap to check, expensive to assume; check
first next time.

Separately: `UnitIsDeadOrGhost("player")` does what it says, covering both
face-down and ghost, and the capture guards that use it stand on their own
merits — a portrait of a wisp is not a portrait, and hiding the interface for
three seconds during a corpse run is its own bad idea. Those are not affected by
any of the above.

---

## `## SavedVariablesMachine` is never written — MEASURED

`AltStableProbe.toc` declares all three scopes:

```
## SavedVariables: AltStableProbeDB
## SavedVariablesPerCharacter: AltStableProbeCharDB
## SavedVariablesMachine: AltStableProbeMachineDB
```

The first two round-trip since 1.60.1.70009 (#23). The third produces **no file
anywhere under `WTF`** — checked with a recursive search of the whole tree, not
just the expected folder. The in-game symptom is the probe's own
`SV never loaded` line naming `machine` thirty seconds after login, every login.

This is the distinction that line exists to force: *not loaded* covers both "the
client wrote a file and did not read it back" and "the client never wrote a file
at all", and **nothing in Lua can tell them apart** — the global is nil either
way. Only the disk can, and here it says the second.

So machine scope is simply unsupported on this client. Do not store anything in
it, and do not read a nil `AltStableProbeMachineDB` as a bug.

The probe no longer watches machine scope at all, and no longer reports the two
that work. A status line saying "still fine" at every login is one nobody reads,
which is how the day it says something else gets missed — so the login report is
silent while the stores load and loud when they do not, and the counts moved to
`/asprobe savedvariables` where somebody investigating persistence will look for
them.

## Translucent surfaces: what an addon can and cannot do about legibility

There is **no blur**. An addon has no shader access and no API that hands it the
rendered scene, so anything translucent shows the world through it *sharp* — and
moving, because the world moves and the frame does not. This is a fixed property
of the client, not a thing to tune around.

Two consequences worth writing down, because both were discovered the expensive
way while glassing this addon:

**A translucent reading surface fails while the camera moves, not while it is
still.** A screenshot of small text over a 0.86-alpha panel looks fine. The same
panel with the camera turning behind it does not, because 14% of a moving scene
reaches the glyphs. Judge any body alpha during movement or do not judge it.
`SetShadowOffset(1, -1)` sharpens letter edges and does nothing about this — it
is for text over a surface that is *already* readable, not a fix for one that is
not.

**Overlay alpha is not additive, and the step shrinks as the surface brightens.**
A white overlay at `s` over a composited surface at `C` lands at:

```
C + s * (1 - C)
```

So the same overlay that lifts a 0.05 surface by 0.033 lifts a 0.20 surface by
only 0.028. Replacing absolute row colours with overlays therefore preserves the
old spacing only over a dark, *consistent* surface. Over a translucent one the
contrast varies with whatever is behind the window, which is a second reason a
reading surface wants to be opaque.

## GameTooltip is shared state, and the risk is the restore

`GameTooltip` is one frame the client reuses for everything: our rows, a quest
giver, another addon's item counts. Two consequences for anything that restyles
it.

**It changes hands without hiding.** `SetOwner` can be called on a tooltip that
is already visible, so an `OnShow` hook alone never sees the moment it stops
being yours. Post-hook `SetOwner` as well — `hooksecurefunc(GameTooltip,
"SetOwner", ...)`, the table-method form — and route both to one idempotent
reconcile that asks "is this ours right now" rather than tracking transitions.

**Hiding the stock border is a debt.** If it is suppressed while your material
is up, every failure to restore leaves the game's own tooltips and every other
addon's borderless until a `/reload`. Record the restore *before* the change
that needs it, restore the value you found rather than an assumed `1`, and only
if it is still the value you set — another addon that has moved it since has an
opinion more recent than yours.

The border lives in `GameTooltip.NineSlice` on an 11.x client. **Unverified on
Forever**, so check for it **before building anything**, not at the point of
hiding it: guarding only the hide gives an unrecognised client the worst of both
— your material drawn over a stock border that is still fully there. Require it
to be *readable* as well as writable, because an alpha you cannot read is one
you cannot give back.

Check the **type**, not the truthiness. A frame that answers every unknown field
with something callable — which is what a chaining test harness does, and the
same shape as "a function in the dump is not a working function" — makes
`if tt.NineSlice then` true for a tooltip that has no border container at all,
and the next index errors on a frame every addon shares. Comparison tooltips (`ShoppingTooltip1/2`)
are separate frames and are not covered by anything done to `GameTooltip`.

Related, and already recorded above: `GameTooltip:HookScript("OnTooltipSetItem",
...)` is gone here — `TooltipDataProcessor.AddTooltipPostCall` is the
replacement. `OnShow`/`OnHide` are ordinary frame scripts and still work.

## UIPanelScrollFrameTemplate works here, measured

The probe avoids it on purpose — "that template still exists on Mainline but its
scrollbar internals changed in 10.1, and this is the one piece of UI that has to
work on an unfamiliar client" — and that caution was never tested against the
addon, which uses it in three places: the Options panel, the export window and
`AltStableBodyScroll`, the main table.

**Measured on 1.60.1.70009 with `scriptErrors` on**: opening the sheet, switching
sections and scrolling the table produces no error from any of them. So the
template is fine for this usage and the probe's caution does not need porting.

What prompted the check is worth keeping too: another addon was erroring in
`Blizzard_SharedXML/SecureScrollTemplates.lua:76`, inside
`ScrollFrame_OnScrollRangeChanged` — a handler our own scroll frames also run.
Somebody else's error is a reasonable prompt to check your own use of the same
template; it is not evidence that yours is broken.
