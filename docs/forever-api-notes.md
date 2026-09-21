# Forever API contracts — measured, not guessed

Probe runs 2026-09-20 on build **1.60.1.69913**, against two low-level characters on the
"Classic Beta PvE" realm. Character names and GUIDs below are placeholders; the values are as
measured. Produced by `Tools/AltStableProbe`.

Everything below is an observed return value. Where it contradicts an assumption in the migration
plan, that's called out.

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

## SavedVariables are WRITTEN but never READ BACK

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

Re-test on every build; the counter answers it in two reloads.

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
   need no ordering assumption**. Only the *named* per-boss kill list does: `Core.lua:1063` encodes
   kills as a positional bitmask by encounter index, and `AltStableInstances.lua:518` maps those
   indices onto a static boss-name list. If Forever's ordering differs, that renders confidently
   wrong names.

   **First beta therefore ships aggregate progress only.** The named-boss mask is written but not
   displayed until a real lockout confirms ordering. The logic stays covered offline by
   `tests/test_instances.lua` with stubbed returns; it's the live data assumption that's unverified,
   not the code.
3. **Professions** — re-run on a character that has some. Both probed characters returned
   `GetProfessions() -> nil x7`.
4. **Gear slot 18** (ranged/relic) — needs a character with something equipped there.
