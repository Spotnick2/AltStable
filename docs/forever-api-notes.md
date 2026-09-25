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
- **Written is not read.** `test_cameraOverShoulder` accepts a write, reads the value straight back
  through both the global and `C_CVar`, reports unlocked and non-readonly - and the camera ignores
  it entirely (#25). A round-trip through the store proves only that the store works.

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

## Identity — surnames are real, and they are space-separated

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

Findings that matter:

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
393 Skinning). The `29xx` block is Retail-era. Needs a re-run on a character *with* professions
before the Professions plugin is designed — deferred anyway.

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

## CVars — the namespace moved halfway, and a writable CVar is not a read one

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

**Writable is not the same as read.** `test_cameraOverShoulder` reports unlocked, non-readonly and
non-secure, accepts a write, and reads the value straight back — and moves the camera not at all,
at `2.043` or at `12`. The value also reverts to `0` on its own without the confirmation popup's
"Disable" ever being clicked. Whatever the camera subsystem consults on this client, it is not this
CVar. Same write-but-never-read shape as the SavedVariables blocker (#23), in a different store.

**The surviving globals are not shims.** Since `GetCVarInfo` moved to `C_CVar`, the obvious theory
is that `GetCVar`/`SetCVar` survive as compatibility wrappers over a shadow store that the engine
never reads. They do not: `SetCVar(name, 12)` then reading both ways returns `12, 12`. The value is
consistent everywhere. The camera simply does not consult it.

**It is the whole family, not one CVar.** `test_cameraDynamicPitch` set to `1` and confirmed
changes nothing either - no tilt while moving, where a working one is unmistakable.

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

Both applied together, and the character still does not move. So this is not a matter of driving
it wrong.

**Treat it as a beta bug, not a permanent client limitation.** Forever is Mainline-derived and this
is a working Mainline feature, so the likeliest explanation is that it is broken on this build
rather than absent by design. Reported to Blizzard 2026-09-20 against 1.60.1.69913. Re-test on
every new build before designing around it (#25).

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

## Frame geometry — the minimap is 198, not 140

```
Minimap:GetWidth(), Minimap:GetHeight()  ->  197.99984741211, 197.99998474121
```

Classic's minimap is 140 across, so addons that hardcode a radius of ~80 to sit "just outside the
ring" land their buttons 29px INSIDE it here - the ring is at 109. Measure the frame; it is a child
coordinate space, so no scale conversion is involved. Fixed for our own button in #26.

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
6. ~~**Does the camera subsystem read *any* `test_*` CVar on this client?**~~ — **answered**, and
   the answer is no. Both `test_cameraOverShoulder` and `test_cameraDynamicPitch` are written,
   read back, confirmed through the experimental-CVar dialog, and ignored. See above and #25.
