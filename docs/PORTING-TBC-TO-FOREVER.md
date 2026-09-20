# Porting a TBC-Anniversary addon to WoW: Forever

Field notes from porting AltTracker (TBC Classic, Interface 20505) to World of Warcraft: Forever
1.60.1. Standalone — hand this file to any session working on any addon; nothing here is
AltTracker-specific.

**The one-line summary:** Forever is *Vanilla content running on Blizzard's Retail (Mainline)
codebase*. Your content assumptions become Vanilla; your API assumptions become Retail. Those are
two separate migrations, and conflating them will cost you a day.

Verified against client build **1.60.1.69913** on 2026-09-20.

---

## 1. The facts

| | |
|---|---|
| **`## Interface:`** | **`16001`** |
| Client version / build | `1.60.1` / `69913` |
| `WOW_PROJECT_ID` | `WOW_PROJECT_MAINLINE` (`1`) |
| Install folder | `_classic_beta_` |
| AddOns path | `C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns` |
| `.flavor.info` | `wow_classic_beta` |
| API surface | 269 `C_*` namespaces, 6,045 globals — full Retail |

### Interface number: 16001, not 11601

`1.60.1` → `1*10000 + 60*100 + 1` = **16001**. The format is `%d%02d%02d`.

You will see **`11601`** in the wild (the AtlasLoot family ships it). It is a transposed-digit
bug — someone read 1.60.1 as 1.16.1. Don't copy it.

Independent confirmation, in order of authority:

1. **`_classic_beta_\WTF\Config.wtf` → `SET engineSurveyPatch "16001"`.** The client writes its own
   patch ID here. This is the single best trick in this document: it works for **every** flavor.
   Cross-checked on one machine: `_retail_` = 120100, `_anniversary_` = 20506, `_classic_` = 50504,
   `_classic_era_` = 11509. All correct.
2. Third-party addons that load without an out-of-date flag: Leatrix_Plus, Leatrix_Maps, Prat-3.0,
   DBM, Scrap, WhatsTraining all carry `16001`.

**Stock `Blizzard_*` addons live inside CASC, not on disk** — in `_classic_beta_` or any other
modern flavor. There is no `Interface\FrameXML` either; `Interface\` contains only `AddOns\`. Use
the Retail (Mainline) branch of `Gethe/wow-ui-source` as your reference, not a Classic branch.

### TOC filename: no suffix

Ship a plain `YourAddon.toc`. The base-name TOC is always read, so it cannot miss.

- **`_Forever.toc` is NOT recognised by the client.** Proven: AtlasLoot ships both
  `AtlasLootClassic_DungeonsAndRaids.toc` (`## Version: BCC 2.5.4`) and `..._Forever.toc`
  (`## Version: Forever 1.60.1`). The crash log's loaded-addon list shows **`BCC 2.5.4`** — the
  client read the base TOC and ignored the `_Forever` one.
- `_Camelot.toc` is the **packager's** suffix (Camelot is the internal codename), not something the
  client needs. Only relevant if one repo serves several flavors.
- If you do want one source tree for several clients, prefer a multi-value list —
  `## Interface: 16001, 11509, 120100` — over suffixed files.

**This client does not hard-block mismatched interface numbers.** Addons with `11508` and `120100`
load fine. So "it loaded" does not prove your number is right — check the **out-of-date flag** in
the AddOns list specifically.

### SavedVariables work

There is a widely-circulated report that the Forever client writes SavedVariables on logout but
never reads them back. **It does not reproduce on build 69913.** Verified by diffing a SavedVariables
file against its `.bak` (the previous session's copy): 232 identical key/value pairs including five
non-default user settings. The data round-trips.

That report was filed against build **69893**. If you're on an older build, re-check before
designing around it. To check yourself: find any configured addon's SV file in
`WTF\Account\<id>\SavedVariables\`, compare it to the `.bak` beside it, and look for a setting you
know you changed.

---

## 2. API migration

### False friends — read this first

Several removed globals have a **same-named member of some namespace that is a different function**.
A mechanical `GetFoo` → `C_Something.GetFoo` rewrite will compile, run, and be silently wrong.

| Global | Looks like | Actually |
|---|---|---|
| `GetFactionInfo` | `C_CreatureInfo.GetFactionInfo` | Different function — returns a creature's *faction group* (Alliance/Horde). Reputation lives in **`C_Reputation.GetFactionDataByIndex`**, which returns a **struct**, not the old tuple. |
| `GetItemInfo` | `C_TransmogCollection.GetItemInfo`, `C_MerchantFrame.GetItemInfo`, `C_AccountStore.GetItemInfo` | Three decoys. You want **`C_Item.GetItemInfo`**. |
| `GetItemIcon` | `C_Item.GetItemIcon` | Same name, different signature — takes an **ItemLocation**. If your call sites pass an item ID, you want **`C_Item.GetItemIconByID`**. |
| `GetTalentInfo` | `C_Garrison.GetTalentInfo` | Garrison decoy. Class talents are `C_SpecializationInfo.GetTalentInfo`. |
| `SendAddonMessage` | `C_Commentator.SendAddonMessage` | Decoy. Use `C_ChatInfo.SendAddonMessage`. |

**Several replacements return a STRUCT where the old global returned a tuple.** Measured on 1.60.1:

| Old global (tuple) | Replacement | Returns |
|---|---|---|
| `GetSkillLineInfo(i)` | `C_SkillInfo.GetSkillLineInfo(i)` | one table: `name`, `isHeader`, `rank`, `maxRank`, `skillID`, … |
| `GetFactionInfo(i)` | `C_Reputation.GetFactionDataByIndex(i)` | one table: `name`, `reaction`, `currentStanding`, `factionID`, … |
| `GetContainerItemInfo(b,s)` | `C_Container.GetContainerItemInfo(b,s)` | one table: `itemID`, `itemName`, `hyperlink`, `stackCount`, `quality`, … |

`C_Item.GetItemInfo` and `C_Item.GetItemInfoInstant`, by contrast, **keep the Classic tuple order**
(18 and 7 returns) and are safe direct aliases.

**Namespace existence does not prove function existence, arity, or return order.** Probe the real
return shape on the live client before writing an adapter against it. A tuple that shifts by one
position yields empty data with no error — the worst failure mode there is.

**`GetItemInfo` returns ZERO values on a cache miss**, not `nil` — and the cache is per client, so
the same call succeeds on one character and returns nothing on another. Any gear/item scan needs a
`GET_ITEM_INFO_RECEIVED` retry path, not just a nil check.

### Clean same-name moves

Safe to alias, subject to a return-shape check:

| Was | Now |
|---|---|
| `GetItemInfo`, `GetItemInfoInstant`, `GetItemCount`, `GetItemStats`, `GetItemQualityColor`, `GetItemSpell`, `GetDetailedItemLevelInfo`, `GetItemUniqueness`, `IsEquippableItem`, `GetItemFamily` | `C_Item.*` |
| `GetContainerNumSlots`, `GetContainerItemInfo`, `GetContainerItemLink`, `GetContainerItemID`, `GetContainerNumFreeSlots`, `GetContainerItemCooldown`, `UseContainerItem`, `PickupContainerItem`, `SplitContainerItem`, `GetBagName` | `C_Container.*` — note `GetContainerItemInfo` returns a **struct**, not positional values |
| `GetNumSkillLines`, `GetSkillLineInfo`, `ExpandSkillHeader`, `CollapseSkillHeader` | `C_SkillInfo.*` |
| `GetNumFactions`, `ExpandFactionHeader`, `CollapseFactionHeader` | `C_Reputation.*` |
| `GetSpellInfo`, `GetSpellCooldown`, `GetSpellLink`, `GetSpellTexture` | `C_Spell.*` |
| `GetSpellBookItemInfo`, `GetSpellBookItemName` | `C_SpellBook.*` |
| `GetAddOnMetadata`, `GetAddOnInfo`, `IsAddOnLoaded`, `LoadAddOn`, `GetNumAddOns`, `EnableAddOn`, `DisableAddOn` | `C_AddOns.*` |
| `SendAddonMessage`, `RegisterAddonMessagePrefix`, `IsAddonMessagePrefixRegistered` | `C_ChatInfo.*` |
| `GetCoinTextureString`, `GetCurrencyInfo`, `GetBackpackCurrencyInfo` | `C_CurrencyInfo.*` |
| `GetNumQuestLogEntries`, `IsQuestFlaggedCompleted` | `C_QuestLog.*` |
| `UnitDefense` | `UnitDefenseSkill` (still a global) |

### Gone with no same-name replacement

Needs real rework, not aliasing:

- **All Classic tradeskill APIs** — `GetTradeSkillLine`, `GetNumTradeSkills`, `GetTradeSkillInfo`,
  `GetTradeSkill{ItemLink,RecipeLink,Icon,NumMade,NumReagents,Cooldown}`, `GetTradeSkillReagentInfo`,
  `DoTradeSkill`, plus the Vanilla `GetCraftInfo`/`GetNumCrafts` (Enchanting) pair. Replacement is
  the Retail **`C_TradeSkillUI`** model: `GetAllProfessionTradeSkillLines`, `GetFilteredRecipeIDs`,
  `GetRecipeInfo`, `GetRecipeSchematic`, `GetRecipeCooldown`. Events change too —
  `TRADE_SKILL_LIST_UPDATE` / `TRADE_SKILL_DATA_SOURCE_CHANGED` rather than `TRADE_SKILL_UPDATE`.
- **Talent trees** — `GetNumTalentTabs`, `GetTalentTabInfo`, `GetNumTalents` are gone. The client
  exposes `C_SpecializationInfo`, `C_ClassTalents`, `C_Traits`. **Which of these actually returns
  Vanilla talent-tree data is unresolved** — probe it; don't assume.
- **Auras** — `UnitAura`, `UnitBuff`, `UnitDebuff`, `AuraUtil` all gone → `C_UnitAuras`. Note
  **player auras are unreadable while tainted in combat** (`C_Secrets.ShouldAurasBeSecret()`).
- `CombatLogGetCurrentEventInfo` → `C_CombatLog`.
- `TryOn` — gone. Matters for any dressing-room / model-preview feature.
- `GetQuestLogTitle`, `SelectQuestLogEntry`, `GetMerchantItemInfo`, the auction APIs,
  `IsUsableSpell`, `GetNumSpellTabs` / `GetSpellTabInfo`.

### Survivors — don't touch these

`GetInventoryItemLink`, `GetInventoryItemTexture`, `GetInventorySlotInfo`, `GetAverageItemLevel`,
`UnitXP`, `UnitXPMax`, `GetXPExhaustion`, `IsResting`, `GetNumSavedInstances`,
`GetSavedInstanceInfo`, `RequestRaidInfo`, `GetInboxNumItems`, `GetInboxHeaderInfo`, `IsInGuild`,
`GetNumGuildMembers`, `GetGuildRosterInfo`, `GetGuildInfo`, `UnitStat`, `UnitAttackPower`,
`GetSpellBonusDamage`, `GetCombatRatingBonus`, `IsSpellKnown`, `GetMoney`, `SendChatMessage`,
`ReloadUI`, `GetBuildInfo`, `GetTime`, `GetServerTime`, `UnitGUID`, `SetPortraitTexture`,
`ShowingHelm`, `ShowingCloak`, `GetMerchantItemLink`, `GetQuestLogRewardInfo`, `LearnTalent`,
`GetTalentLink`.

Notably `ShowingHelm` / `ShowingCloak` survive here even though they're gone on true Retail.

### Adapter pattern

Don't inject globals — defining a real `_G.GetItemInfo` changes capability detection for every
other addon, makes you load-order dependent, and puts an addon-owned global where Blizzard code may
find it. Put adapters in your own namespace and take file-local aliases, which keeps call sites
unchanged for a handful of lines per file:

```lua
-- Compat.lua, loaded first
MyAddon.API = {}
MyAddon.API.GetItemInfo     = C_Item.GetItemInfo
MyAddon.API.GetItemIconByID = C_Item.GetItemIconByID   -- NOT C_Item.GetItemIcon
```
```lua
-- top of each consuming file; every call below stays as it was
local GetItemInfo = MyAddon.API.GetItemInfo
```

Implement only the contracts your code actually consumes. Don't build a historical-API emulator.

---

## 3. Client gotchas

- **`ReloadUI()` is protected.** Use the `/reload` slash command.
- **Unknown event names throw on `RegisterEvent`.** Wrap registration in `pcall` — but **log the
  failures**, or you'll silently ship a missing handler.
- **Error delivery stops after 100 Lua errors in a session.** Everything after that is invisible
  until `/reload`. If errors mysteriously dry up, that's why.
- **Errors are off by default.** `Config.wtf` has no `scriptErrors` line. Run
  `/console scriptErrors 1` before debugging anything.
- **Secure snippets are broken.** `loadstring_untainted` is missing from the restricted environment,
  so `SecureHandlerWrapScript`, `_onstate-*` attributes and state drivers all throw. Action-bar and
  click-casting addons do not work.
- **Player auras are unreadable in combat** when secret — check `C_Secrets.GetSpellAuraSecrecy(id)`.
- **Edit Mode is live**, so anything anchored to a `UIParent` child can be moved out from under you.
- **Retail's Settings framework**, not `InterfaceOptions_AddCategory`. Use
  `Settings.RegisterAddOnCategory`.
- **Tooltips use `TooltipDataProcessor`** on Mainline. A
  `GameTooltip:HookScript("OnTooltipSetItem", …)` installed during addon bootstrap can abort your
  whole registration. Check this early — it's a load-blocker, not a cosmetic issue.
- **Professions and Housing subsystems are compiled in but inert** (`Logs\Professions.log` and
  `Logs\Housing.log` exist and are 0 bytes). Don't call into the Retail profession UI.
- **`UIDropDownMenu` / `EasyMenu`** are the usual Retail-migration killers. If your addon uses them,
  budget for that separately.

### Characters have surnames — first names are not unique

Forever gives characters a **surname** in addition to a first name. `C_PlayerInfo.ShouldDisplaySurname`
exists in the API, and the WTF layout shows it plainly: one realm folder held both
`Second-Surname` and `Second-Othername` — same first name, two different characters — while the
Classic-style `<RealmName>\<Char>\` path collapsed both into a single `Second` folder.

**The API returns the surname space-separated, as part of the name string:**

```
UnitName("player")           ->  "Example Surname",  nil
UnitFullName("player")       ->  "Example Surname",  "ClassicBetaPvE"
UnitNameUnmodified("player") ->  "Example Surname",  nil
GetUnitName("player", true)  ->  "Example Surname"
C_PlayerInfo.ShouldDisplaySurname()  ->  true
```

The hyphenated `Name-Surname` form appears **only in WTF folder names on disk**, where it is
indistinguishable from Retail's `Name-Realm`. Don't infer the API format from the folder layout.

Good news for realm-stripping: since the separator is a space, existing code that splits on `-` to
remove a realm suffix still works and leaves the surname intact.

**The two identity sources disagree**, which is the trap:

```
UnitName(unit)              ->  "Example Surname"      full name
GetPlayerInfoByGUID(guid)   ->  ..., [6]="Example", ... FIRST NAME ONLY
```

So anything rendering a name from a GUID silently drops the surname, while anything rendering from
`UnitName` keeps it — and the two will disagree about whether two characters are the same person.

This breaks anything that treats a character name as a unique key:

- per-character maps keyed by name
- whisper targeting and addon-message routing
- whitelists and friend/peer matching
- any `name`-based identity check (e.g. "reject this record if the name changed for this GUID")

**Key on GUID for storage.** `UnitGUID` is stable and unique; a first name is neither.

**For addon messaging, measured with two accounts online, the news is good:**

```
SendAddonMessage(prefix, msg, "WHISPER", "Example Surname")   -> delivered
CHAT_MSG_ADDON  ->  sender = "Example Surname"                (full name, space-separated,
                                                               no realm suffix, same realm)
```

- A whisper target **containing a space routes fine**.
- `CHAT_MSG_ADDON`'s `sender` carries the **full name including the surname** — not the first name,
  not hyphenated — and replying to that string verbatim routes back.
- So code that strips a realm by splitting on `-` still works, and the resulting key is unique.

**The thing that actually breaks: slash-command argument parsing.** The near-universal idiom

```lua
local cmd, target = args:match("^(%S+)%s+(%S+)$")   -- BROKEN: target is one token
```

silently fails on `/mycmd sync Example Surname` — three tokens match neither the two-token pattern
nor the one-token fallback, so the handler falls through and does nothing at all. Use:

```lua
local cmd, target = args:match("^(%S+)%s+(.+)$")    -- rest of line, then trim
```

Audit every place a character name arrives from user input, a saved config list, or a parsed system
message.

### Bag IDs all moved — read `Enum.BagIndex`

Forever uses the modern Retail bank-tab container layout, so **every Classic bank constant is
wrong**. Measured on 1.60.1:

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

Classic's `BANK_IDS = { -1, 5..11 }` therefore scans the **keyring**, the **carried reagent bag**,
and only some bank tabs. `MAIN_BANK = -1` is the keyring.

**Bank tabs are ordinary containers** — no special API to read them:
```lua
C_Container.GetContainerNumSlots(6)     --> 48      (name: "Bank")
C_Container.GetContainerItemInfo(6, 1)  --> { itemID=..., stackCount=..., ... }
```

But tabs are **purchased individually**, so the set is dynamic. Query it:
```lua
C_Bank.FetchPurchasedBankTabIDs(Enum.BankType.Character)  --> { 6 }
C_Bank.FetchMaxNumBankTabs(Enum.BankType.Character)       --> 9
```
`NUM_BANKGENERIC_SLOTS` and `NUM_BANKBAGSLOTS` are `nil`; `NUM_BAG_SLOTS` is `4`.

**Account bank: plumbed but not enabled.** `Enum.BankType = { Character=0, Guild=1, Account=2 }`;
only Character is viewable today, but `FetchMaxNumBankTabs(Account)` is already `9` with a purchase
prompt describing storage "shared with all members in your Account". If you aggregate inventory
across alts, filter by `bankType == Enum.BankType.Character` — otherwise, the day account tabs turn
on, shared items get counted once per character and every total inflates.

### Tooltips: OnTooltipSetItem throws

Not merely "doesn't fire" — `GameTooltip:HookScript("OnTooltipSetItem", fn)` **raises an error**
(`bad argument #2`), because the script type no longer exists. If that call sits in your addon's
bootstrap it will abort registration entirely.

```lua
-- works, and fires:
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data) ... end)
```
`C_TooltipInfo.GetHyperlink("item:6948")` also returns structured tooltip data.

### Events that no longer exist

Confirmed rejected by `RegisterEvent` (they throw): `PLAYERBANKBAGSLOTS_CHANGED`,
`TRADE_SKILL_UPDATE`. Still valid: `BANKFRAME_OPENED`/`CLOSED`, `PLAYERBANKSLOTS_CHANGED`,
`BAG_UPDATE`, `BAG_UPDATE_DELAYED`, `SKILL_LINES_CHANGED`, `UPDATE_FACTION`,
`TRADE_SKILL_SHOW`, `TRADE_SKILL_LIST_UPDATE`, `TRADE_SKILL_DATA_SOURCE_CHANGED`,
`GET_ITEM_INFO_RECEIVED`, `CHAT_MSG_ADDON`.

### Version-check traps

Any code doing `select(4, GetBuildInfo()) >= 100000` treats Forever as Classic. And the reverse:
`tocVersion >= 30000 and … or …` ladders written for TBC/WotLK pick a branch based on `16001`, which
lands in the "Vanilla" bucket — sometimes right **by accident**. Rewrite these as explicit
predicates rather than leaving them correct by luck; the next reader will assume they were reasoned
about.

### Content-side constants that fail silently

Forever is Vanilla content. These produce plausible-but-wrong output rather than errors, so nothing
alerts you:

- **Level cap is 60**, not 70/80. Use `GetMaxPlayerLevel()` (returns 60) — **`MAX_PLAYER_LEVEL` is
  `nil` on this client**. Grep for every hardcoded cap, not just the obvious one.
- **Item-level colour/quality gradients** scaled for TBC ilvls will render Vanilla raid epics as
  junk. Colour by item quality instead.
- **Profession cap is 300**, not 375 — and weapon/defense skill `maxRank` is dynamic (5 x level),
  so read it per skill line rather than assuming any cap.
- **No Jewelcrafting**, no sockets/gems, no meta gems.
- **No combat rating system** — `GetCombatRatingBonus` exists but returns 0. No resilience.
- **Vanilla item levels are small** — Thunderfury is ilvl **80**. Any colour ramp or threshold
  tuned for TBC/WotLK ilvls will render raid epics as junk. Colour by `quality` instead.
- **`GetAverageItemLevel()` returns three fractional values** (total, equipped, pvp) — round them.
- Outland factions, TBC recipes and TBC enchant IDs are all dead content.
- `UnitXPMax(…) or 1` does **not** guard against zero — **zero is truthy in Lua**. At level cap this
  divides by zero. The same trap applies to any `x or default` guard on a numeric that can be 0, and
  to booleans serialized as `0`/`1`.

---

## 4. Packaging and publishing

CurseForge **does** have a Forever flavor. `BigWigsMods/packager` gained support in PR #202, merged
2026-09-17 (commit `7391c8de`).

| | |
|---|---|
| Packager flavor | `forever` (alias `camelot`) |
| Interface pattern | `16???` → `forever` |
| TOC suffix | `_Camelot` |
| CurseForge `gameVersionTypeID` | **`88568`** |

A single plain TOC with `## Interface: 16001` is enough — the packager derives the flavor from the
interface number and needs no suffixed file.

**Verify the `v2` moving tag of `BigWigsMods/packager` actually contains `7391c8de`** before relying
on it; pin to the SHA otherwise. Forever support is days old at time of writing.

For dry runs use the packager's **`-d` flag** to suppress uploads and publish the zip as a CI
artifact. Merely omitting `CF_API_KEY` is not a complete no-upload policy — the packager also does
GitHub releases.

CurseForge derives the release type from the **tag name**: a tag containing `alpha` uploads as
Alpha, `beta` as Beta, anything else as Release. So a beta stream is `v0.1.0-beta`, `v0.1.0-beta2`, …

Wowhead's Forever database (`wowhead.com/forever`) launches **Nov 4** — if you need recipe or item
data from it, that's your blocker.

---

## 5. Local test loop

```
Deploy:  copy addon folders into _classic_beta_\Interface\AddOns\
In-game: /console scriptErrors 1
         /reload
Check:   AddOn list — enabled AND not flagged out of date
```

Syntax-check outside the game (WoW is Lua 5.1, so use a 5.1 toolchain):

```
"C:\Program Files (x86)\Lua\5.1\luac" -p YourFile.lua
```

SavedVariables land in:

```
_classic_beta_\WTF\Account\<accountID>\SavedVariables\<Addon>.lua            (account-wide)
_classic_beta_\WTF\Account\<accountID>\<RealmName>\<Char>\SavedVariables\    (per-character)
```

This client writes **both** the Classic-style `<RealmName>\<Char>\` layout and a Retail-style
`<realmID>\<Name>-<Realm>\` layout. SavedVariables land in the Classic-style path.

The `.bak` file beside each SV file is the previous session's copy — diffing the two is the fastest
way to confirm persistence is working.

### Testing cross-account addon sync

`Config.wtf` lists the available accounts, e.g. `SET accountList "!WoW12|WoW1|"`, and each gets its
own folder under `WTF\Account\`. Two accounts logged in **simultaneously** is the only way to
exercise an addon-message sync path — logging a second character on the *same* account shares
SavedVariables and will appear to work without a single message being sent. Test with both.

---

## 6. Capturing your own API baseline

The fastest way to answer "does X exist on this client" is to dump the environment from inside the
game rather than guessing from documentation: walk `_G` for functions and each `C_*` table for
members, write it to a SavedVariable, read it off disk.

A prebuilt dump for build 69913 lives in `Thunderz96/forever-addon-kit` at `data/forever_api.json`
(keys: `functions`, `frames`, `namespaces`, `client`). That repo also carries porting tools and a
bug watchlist. Treat its bug reports as build-specific and re-verify — its SavedVariables claim is
already stale.

**Existence is not a contract.** The dump tells you a function is there. It does not tell you the
argument shape, the return order, or whether the underlying system is wired up on a Vanilla-content
client. Probe in-game before writing an adapter against it.
