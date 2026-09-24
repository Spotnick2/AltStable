------------------------------------------------------------
-- test_compat.lua — the AltStable.API adapter layer.
--
-- Tests the failure semantics, not just that each mapping is non-nil. The
-- whole point of the adapter is that a wrong mapping is SILENT: a shifted
-- tuple or a swallowed cache miss yields empty data with no error, which is
-- indistinguishable from "the character has nothing".
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_compat.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("  FAIL: " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end
local function eq(name, got, want)
    check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

WoW.reset()
WoW.items[6948] = {
    name = "Hearthstone", quality = 1, ilvl = 1, itemType = "Miscellaneous",
    subType = "Junk", equipLoc = "INVTYPE_NON_EQUIP_IGNORE", icon = 134414,
    classID = 15, subClassID = 0, count = 1,
}
WoW.items[19019] = {
    name = "Thunderfury", quality = 5, ilvl = 80, minLevel = 60,
    itemType = "Weapon", subType = "One-Handed Swords", equipLoc = "INVTYPE_WEAPON",
    icon = 135349, classID = 2, subClassID = 7, stats = { ITEM_MOD_AGILITY_SHORT = 5 },
}

local API = dofile("Compat.lua")  -- reassigned later by the negative-path sections

------------------------------------------------------------
-- Every mapping resolved
------------------------------------------------------------

check("no missing capabilities", #API.missing == 0, table.concat(API.missing, ", "))
check("AssertCapabilities passes", API.AssertCapabilities() == true)

------------------------------------------------------------
-- The GetItemIcon trap must stay shut
--
-- C_Item.GetItemIcon exists but takes an ItemLocation, and every call site
-- passes an item id. The name is deliberately absent from the adapter so it
-- cannot quietly come back.
------------------------------------------------------------

check("API.GetItemIcon is NOT exposed", API.GetItemIcon == nil)
eq("GetItemIconByID returns the icon", API.GetItemIconByID(6948), 134414)

local ok = pcall(C_Item.GetItemIcon, 6948)
check("C_Item.GetItemIcon(itemID) still errors", ok == false,
      "the stub must reproduce the live client's ItemLocation requirement")

------------------------------------------------------------
-- Tuple preservation: positions, arity, and trailing values
------------------------------------------------------------

local n = select("#", API.GetItemInfo(19019))
eq("GetItemInfo returns 18 values", n, 18)

local name, link, quality, ilvl, reqLevel, itemType, subType = API.GetItemInfo(19019)
eq("  [1] name", name, "Thunderfury")
eq("  [3] quality", quality, 5)
eq("  [4] itemLevel", ilvl, 80)
eq("  [5] requiredLevel", reqLevel, 60)
eq("  [7] subType", subType, "One-Handed Swords")
check("  [2] link is a hyperlink", type(link) == "string" and link:find("|Hitem:") ~= nil)
eq("  [6] itemType", itemType, "Weapon")

local iid, iType, iSub, iLoc, iIcon = API.GetItemInfoInstant(6948)
eq("GetItemInfoInstant [1] itemID", iid, 6948)
eq("GetItemInfoInstant [4] equipLoc", iLoc, "INVTYPE_NON_EQUIP_IGNORE")
eq("GetItemInfoInstant [5] icon", iIcon, 134414)

------------------------------------------------------------
-- Tuple-preserving mappings must be DIRECT aliases
--
-- A plain forwarding wrapper - `function(...) return fn(...) end` - would be
-- perfectly arity-safe. The dangerous shape is the one that round-trips
-- through a table: `local r = {fn(...)} return unpack(r)` silently changes
-- arity, because `#` on a table containing nil holes is undefined in Lua 5.1.
-- That is invisible in a spot check and corrupts every trailing return.
--
-- So identity is a policy ("this layer only forwards"), not a law of nature.
-- It is the cheapest way to make the dangerous shape impossible to add by
-- accident. If real instrumentation is ever wanted here, replace these with
-- behavioural arity tests rather than weakening them.
------------------------------------------------------------

check("GetItemInfo is a direct alias", API.GetItemInfo == C_Item.GetItemInfo)
check("GetItemInfoInstant is a direct alias", API.GetItemInfoInstant == C_Item.GetItemInfoInstant)
check("GetItemStats is a direct alias", API.GetItemStats == C_Item.GetItemStats)
check("GetItemCount is a direct alias", API.GetItemCount == C_Item.GetItemCount)
check("GetItemIconByID is a direct alias", API.GetItemIconByID == C_Item.GetItemIconByID)
check("GetSkillLineInfo is a direct alias", API.GetSkillLineInfo == C_SkillInfo.GetSkillLineInfo)
check("GetFactionDataByIndex is a direct alias", API.GetFactionDataByIndex == C_Reputation.GetFactionDataByIndex)
check("GetContainerItemInfo is a direct alias", API.GetContainerItemInfo == C_Container.GetContainerItemInfo)

------------------------------------------------------------
-- Cache miss returns ZERO values, not nil
--
-- Measured: the same call gave 18 returns on one character and none on
-- another, because the item cache is per client. Code doing {GetItemInfo(id)}
-- gets an empty table; code doing `local n = GetItemInfo(id)` gets nil. Both
-- must keep working, so the adapter must not "helpfully" normalise this.
------------------------------------------------------------

eq("cache miss returns 0 values", select("#", API.GetItemInfo(99999)), 0)
eq("cache miss via single assignment is nil", (API.GetItemInfo(99999)), nil)
eq("cache miss GetItemInfoInstant returns 0 values", select("#", API.GetItemInfoInstant(99999)), 0)
eq("cache miss GetItemStats returns 0 values", select("#", API.GetItemStats(99999)), 0)

------------------------------------------------------------
-- Skills are a STRUCT, and maxRank is dynamic
------------------------------------------------------------

WoW.skillLines = {
    { name = "Class Skills", isHeader = true,  rank = 0, maxRank = 0,   skillID = 7 },
    { name = "Defense",      isHeader = false, rank = 8, maxRank = 15,  skillID = 95 },
    { name = "Herbalism",    isHeader = false, rank = 47, maxRank = 300, skillID = 182 },
}

eq("GetNumSkillLines", API.GetNumSkillLines(), 3)

local sk = API.GetSkillLineInfo(2)
check("GetSkillLineInfo returns a table", type(sk) == "table")
eq("  .name", sk.name, "Defense")
eq("  .isHeader", sk.isHeader, false)
eq("  .rank", sk.rank, 8)
eq("  .maxRank is per-line, not a fixed cap", sk.maxRank, 15)
eq("headers are flagged", API.GetSkillLineInfo(1).isHeader, true)

-- The bug this replaces: destructuring the old tuple off a struct yields nils.
local a, b, c = API.GetSkillLineInfo(2)
check("destructuring a struct gives no usable fields", b == nil and c == nil,
      "a tuple-style read must not silently appear to work")

------------------------------------------------------------
-- Reputation is a STRUCT, and ByID reaches past the visible list
------------------------------------------------------------

WoW.factions = {
    { name = "Horde",      factionID = 67, reaction = 5, currentStanding = 3500, isHeader = true },
    { name = "Orgrimmar",  factionID = 76, reaction = 4, currentStanding = 2000, isHeader = false },
}
WoW.factionByID = {
    [76]  = WoW.factions[2],
    -- Not in the indexed list at all - exactly the case that makes a UI-list
    -- scan lose factions behind collapsed headers.
    [529] = { name = "Argent Dawn", factionID = 529, reaction = 4, currentStanding = 200 },
}

eq("GetNumFactions", API.GetNumFactions(), 2)

local f = API.GetFactionDataByIndex(2)
check("GetFactionDataByIndex returns a table", type(f) == "table")
eq("  .name", f.name, "Orgrimmar")
eq("  .reaction is the standing", f.reaction, 4)
eq("  .currentStanding", f.currentStanding, 2000)

local ad = API.GetFactionDataByID(529)
check("GetFactionDataByID reaches a faction absent from the index", ad ~= nil)
eq("  .name", ad and ad.name, "Argent Dawn")
eq("unknown faction id is nil", API.GetFactionDataByID(270), nil)

------------------------------------------------------------
-- Container identity derives from Enum.BagIndex
------------------------------------------------------------

local carried = API.GetCarriedBagIDs()
eq("carried bags: backpack + 4 bags + reagent bag", #carried, 6)
eq("  first is the backpack", carried[1], 0)
eq("  last is the reagent bag", carried[6], 5)

local function contains(t, v)
    for _, x in ipairs(t) do if x == v then return true end end
    return false
end
check("keyring is NOT a carried bag", not contains(carried, -1))
check("no bank tab leaks into carried bags", not contains(carried, 6))
eq("keyring is -1 on Forever, not -2", API.GetKeyringBagID(), -1)

------------------------------------------------------------
-- Bank tabs are dynamic, and account tabs must never appear
------------------------------------------------------------

WoW.bankTabs = { 6 }
local tabs = API.GetCharacterBankTabIDs()
eq("one purchased character bank tab", #tabs, 1)
eq("  and it is CharacterBankTab_1 = 6", tabs[1], 6)

WoW.bankTabs = { 6, 7, 8 }
eq("purchasing more tabs is picked up", #API.GetCharacterBankTabIDs(), 3)

-- The inflation trap: if account tabs were ever folded into a character's bank
-- map, shared items would be counted once per alt.
WoW.accountTabs = { 15, 16 }
local afterAccount = API.GetCharacterBankTabIDs()
eq("account tabs do not appear in the character bank", #afterAccount, 3)
check("no account tab id present", not contains(afterAccount, 15) and not contains(afterAccount, 16))

WoW.bankTabs = {}
eq("no purchased tabs yields an empty list, not nil", #API.GetCharacterBankTabIDs(), 0)

------------------------------------------------------------
-- Level cap comes from the client
------------------------------------------------------------

eq("GetMaxPlayerLevel reads the client", API.GetMaxPlayerLevel(), 60)
WoW.maxLevel = 70
eq("  and follows it when content changes", API.GetMaxPlayerLevel(), 70)
WoW.maxLevel = 60

------------------------------------------------------------
-- Survivors
------------------------------------------------------------

local base, modifier = API.UnitDefenseSkill("player")
eq("UnitDefenseSkill [1] base", base, 1)
eq("UnitDefenseSkill [2] modifier", modifier, 0)

------------------------------------------------------------
-- Removed globals must stay absent
--
-- If one of these ever becomes non-nil in the test environment, a stub is
-- lying about the client and a real bug can hide behind it.
------------------------------------------------------------

for _, g in ipairs({
    "GetItemInfo", "GetItemInfoInstant", "GetItemCount", "GetItemStats",
    "GetNumSkillLines", "GetSkillLineInfo", "GetNumFactions", "GetFactionInfo",
    "GetContainerNumSlots", "GetContainerItemInfo", "GetContainerItemLink",
    "UnitDefense", "SendAddonMessage", "RegisterAddonMessagePrefix",
    "IsAddOnLoaded", "LoadAddOn", "GetAddOnMetadata",
    -- The global GetItemIcon is gone; only C_Item.GetItemIcon exists, and it
    -- takes an ItemLocation.
    "GetItemIcon",
}) do
    check("global " .. g .. " is absent, as on the live client", _G[g] == nil)
end

check("MAX_PLAYER_LEVEL is nil; GetMaxPlayerLevel() is the source", _G.MAX_PLAYER_LEVEL == nil)

------------------------------------------------------------
-- Secret values
--
-- Measured in game: on a PvP realm UnitStat, UnitArmor and UnitAttackPower all
-- returned secret numbers, and the arithmetic on them aborted the character
-- scan mid-way. A secret is storable but not inspectable.
------------------------------------------------------------

local secret = WoW.secret(42)
check("a plain number is not secret", API.IsSecretValue(7) == false)
check("nil is not secret", API.IsSecretValue(nil) == false)
check("a secret number is", API.IsSecretValue(secret) == true)

eq("a plain number passes through", API.PlainNumber(7), 7)
eq("a numeric string is converted", API.PlainNumber("7"), 7)
eq("nil stays nil", API.PlainNumber(nil), nil)
eq("a secret becomes nil, not 0 - unknown is not zero", API.PlainNumber(secret), nil)

eq("a sum of plain numbers", API.PlainSum(1, 2, 3), 6)
eq("  with nothing to add", API.PlainSum(), 0)
eq("one secret component makes the whole sum unknown", API.PlainSum(1, secret, 3), nil)
eq("  in any position", API.PlainSum(secret), nil)

-- The fallback matters: not every build need have the predicate, and the real
-- question is "can I do arithmetic on this".
do
    local realPredicate = issecretvalue
    issecretvalue = nil
    dofile("Compat.lua")
    local API2 = AltStable.API
    check("without the predicate, a secret is still caught", API2.IsSecretValue(secret) == true)
    eq("  and still becomes nil", API2.PlainNumber(secret), nil)
    eq("  while plain numbers are unaffected", API2.PlainNumber(5), 5)
    issecretvalue = realPredicate
    dofile("Compat.lua")
end

------------------------------------------------------------
-- Full tuple shape, not just the early positions
--
-- A wrapper that truncates trailing returns passes an early-positions-only
-- check. Pin the tail, including the nil at 16.
------------------------------------------------------------

eq("GetItemInfoInstant returns 7 values", select("#", API.GetItemInfoInstant(6948)), 7)

local r = { n = select("#", API.GetItemInfo(19019)) }
for i = 1, r.n do r[i] = (select(i, API.GetItemInfo(19019))) end
eq("  [8] stackCount", r[8], 1)
eq("  [9] equipLoc", r[9], "INVTYPE_WEAPON")
eq("  [10] icon", r[10], 135349)
eq("  [12] classID", r[12], 2)
eq("  [13] subClassID", r[13], 7)
eq("  [16] setID is nil, mid-tuple", r[16], nil)
eq("  [17] isCraftingReagent is false, not nil", r[17], false)
eq("  [18] trailing value survives", r[18], "")

------------------------------------------------------------
-- Struct APIs return exactly ONE value
--
-- "the second assignment is nil" cannot tell a single return from a padded
-- tuple. Arity is the real contract.
------------------------------------------------------------

eq("GetSkillLineInfo returns exactly 1 value", select("#", API.GetSkillLineInfo(2)), 1)
eq("GetFactionDataByIndex returns exactly 1 value", select("#", API.GetFactionDataByIndex(2)), 1)

WoW.containers[0] = {
    name = "Backpack", size = 20,
    [1] = { itemID = 4604, itemName = "Forest Mushroom Cap", stackCount = 8, quality = 1,
            hyperlink = "|Hitem:4604|h[Forest Mushroom Cap]|h", iconFileID = 134534 },
}
eq("GetContainerNumSlots", API.GetContainerNumSlots(0), 20)
eq("GetContainerItemInfo returns exactly 1 value", select("#", API.GetContainerItemInfo(0, 1)), 1)
local ci = API.GetContainerItemInfo(0, 1)
eq("  .itemID", ci.itemID, 4604)
eq("  .stackCount", ci.stackCount, 8)
eq("empty slot is nil", API.GetContainerItemInfo(0, 2), nil)

------------------------------------------------------------
-- Bag ids must actually derive from the enum
--
-- The happy-path values are identical to Classic's 0..5, so a hardcoded list
-- would pass. Move the enum and require the output to move with it.
------------------------------------------------------------

local realBagIndex = Enum.BagIndex
Enum.BagIndex = {
    Keyring = -7, Backpack = 100, Bag_1 = 101, Bag_2 = 102,
    Bag_3 = 103, Bag_4 = 104, ReagentBag = 105,
}
local moved = dofile("Compat.lua")
local mb = moved.GetCarriedBagIDs()
check("carried bags follow a renumbered enum",
      mb and #mb == 6 and mb[1] == 100 and mb[6] == 105,
      "got " .. (mb and table.concat(mb, ",") or "nil"))
eq("keyring follows the enum too", moved.GetKeyringBagID(), -7)

-- A missing key must refuse, not quietly return a shorter list.
Enum.BagIndex = { Keyring = -1, Backpack = 0, Bag_1 = 1, Bag_3 = 3, Bag_4 = 4, ReagentBag = 5 }
local partial = dofile("Compat.lua")
local pb, pReason = partial.GetCarriedBagIDs()
eq("a missing bag key returns nil, not a short list", pb, nil)
check("  and says which key", type(pReason) == "string" and pReason:find("Bag_2") ~= nil, tostring(pReason))

Enum.BagIndex = nil
local noEnum = dofile("Compat.lua")
eq("no Enum.BagIndex refuses rather than assuming Classic ids", (noEnum.GetCarriedBagIDs()), nil)
eq("  keyring is nil too", noEnum.GetKeyringBagID(), nil)

Enum.BagIndex = realBagIndex

------------------------------------------------------------
-- Bank: failure must stay distinguishable from "no tabs purchased"
--
-- Collapsing both to {} would let a transient failure read as an empty bank
-- and wipe a stored snapshot.
------------------------------------------------------------

API = dofile("Compat.lua")
WoW.bankTabs = {}
local okEmpty, okReason = API.GetCharacterBankTabIDs()
check("success with no tabs returns a table", type(okEmpty) == "table" and #okEmpty == 0)
eq("  and no reason", okReason, nil)

local realFetch = C_Bank.FetchPurchasedBankTabIDs

C_Bank.FetchPurchasedBankTabIDs = nil
local v, why = API.GetCharacterBankTabIDs()
eq("missing fetch function returns nil", v, nil)
check("  with a reason", type(why) == "string" and why:find("FetchPurchasedBankTabIDs") ~= nil, tostring(why))

C_Bank.FetchPurchasedBankTabIDs = function() error("boom") end
v, why = API.GetCharacterBankTabIDs()
eq("a thrown error returns nil", v, nil)
check("  with a reason", type(why) == "string" and why:find("errored") ~= nil, tostring(why))

C_Bank.FetchPurchasedBankTabIDs = function() return 42 end
v, why = API.GetCharacterBankTabIDs()
eq("a non-table result returns nil", v, nil)

C_Bank.FetchPurchasedBankTabIDs = function() return { 6, "seven", 8 } end
v, why = API.GetCharacterBankTabIDs()
eq("a malformed list is rejected whole, not filtered", v, nil)
check("  naming the bad index", type(why) == "string" and why:find("index 2") ~= nil, tostring(why))

C_Bank.FetchPurchasedBankTabIDs = realFetch

local realBankType = Enum.BankType
Enum.BankType = nil
eq("missing Enum.BankType returns nil", (API.GetCharacterBankTabIDs()), nil)
Enum.BankType = realBankType

------------------------------------------------------------
-- Events the client rejects must be rejected in tests too
------------------------------------------------------------

local frame = CreateFrame("Frame")
check("a valid event registers", pcall(frame.RegisterEvent, frame, "BAG_UPDATE"))
check("PLAYERBANKBAGSLOTS_CHANGED is rejected, as measured",
      not pcall(frame.RegisterEvent, frame, "PLAYERBANKBAGSLOTS_CHANGED"))
check("TRADE_SKILL_UPDATE is rejected, as measured",
      not pcall(frame.RegisterEvent, frame, "TRADE_SKILL_UPDATE"))
check("OnTooltipSetItem hook throws, as measured",
      not pcall(frame.HookScript, frame, "OnTooltipSetItem", function() end))

------------------------------------------------------------
-- Capability reporting on a client that is missing something
------------------------------------------------------------

local realGetItemInfo = C_Item.GetItemInfo
C_Item.GetItemInfo = nil
WoW.chatOut = {}
local degraded = dofile("Compat.lua")

eq("the missing API is reported", #degraded.missing, 1)
eq("  by exact name", degraded.missing[1], "C_Item.GetItemInfo")
eq("  and the member is nil, not a stub", degraded.GetItemInfo, nil)
check("AssertCapabilities returns false", degraded.AssertCapabilities() == false)
check("  and says so loudly", #WoW.chatOut > 0 and WoW.chatOut[1]:find("C_Item.GetItemInfo") ~= nil,
      "expected a chat diagnostic naming the missing API")

C_Item.GetItemInfo = realGetItemInfo
API = dofile("Compat.lua")
eq("restored client reports nothing missing", #API.missing, 0)

------------------------------------------------------------
-- strsplit stub fidelity
--
-- Not adapter code, but the harness has to parse the way the client does.
-- PeerShort strips a realm by splitting on "-", and the sync wire format is
-- "CMD|payload" - so a stub that invents empty fields would make consumer
-- tests validate parsing that does not match reality.
------------------------------------------------------------

local function splitCount(sep, s) return select("#", strsplit(sep, s)) end

eq("no delimiter yields one field", splitCount("-", "NoDelimiter"), 1)
eq("  and it is the whole string", (strsplit("-", "NoDelimiter")), "NoDelimiter")

eq("a surname plus realm splits into two", splitCount("-", "Example Surname-RealmName"), 2)
local nameField, realmField = strsplit("-", "Example Surname-RealmName")
eq("  [1] keeps the space-separated surname", nameField, "Example Surname")
eq("  [2] is the realm", realmField, "RealmName")

eq("wire format keeps its 4 fields", splitCount("|", "CHUNK5|sid|1/3|body"), 4)
local c1, c2, c3, c4 = strsplit("|", "CHUNK5|sid|1/3|body")
eq("  [1]", c1, "CHUNK5")
eq("  [3]", c3, "1/3")
eq("  [4]", c4, "body")

-- Genuine empties must survive; only invented ones are the bug.
eq("adjacent delimiters keep a real empty field", splitCount("|", "a||b"), 3)
eq("  and it is empty", (select(2, strsplit("|", "a||b"))), "")
eq("a trailing delimiter keeps its empty field", splitCount("|", "a|"), 2)
eq("a leading delimiter keeps its empty field", splitCount("|", "|a"), 2)

-- The delimiter is a literal character set, not a pattern. Interpolating it
-- raw builds "[^]" for a caret and throws "malformed pattern".
for _, d in ipairs({ "^", "]", "%", "-", "." }) do
    local okSplit, a2, b2 = pcall(strsplit, d, "a" .. d .. "b")
    check("delimiter " .. string.format("%q", d) .. " does not throw", okSplit, tostring(a2))
    if okSplit then
        eq("  " .. string.format("%q", d) .. " [1]", a2, "a")
        eq("  " .. string.format("%q", d) .. " [2]", b2, "b")
    end
end

-- The piece limit keeps the remainder whole. Core.lua reads every wire message
-- as strsplit("|", message, 2), and the CHUNK and DONE headers carry more "|"
-- after the command; the stub used to ignore the limit, so every one of them
-- failed to parse under test.
local head, rest = strsplit("|", "CHUNK5|1|1/1|body|with|pipes", 2)
eq("a piece limit splits only once", head, "CHUNK5")
eq("  and keeps the remainder whole, delimiters included", rest, "1|1/1|body|with|pipes")
eq("a limit returns no more pieces than asked", select("#", strsplit("|", "a|b|c", 2)), 2)
eq("a limit of 1 returns the whole string", (strsplit("|", "a|b", 1)), "a|b")
eq("no limit still splits everywhere", select("#", strsplit("|", "a|b|c")), 3)
check("a nil string is an error, not the text \"nil\"", not pcall(strsplit, "|", nil))

-- A metacharacter delimiter must not match anything else either: "." is a
-- literal dot here, not "any character".
eq("a literal dot splits only on dots", splitCount(".", "a.b"), 2)
eq("  and leaves other characters alone", splitCount(".", "axb"), 1)

------------------------------------------------------------
-- Frames registered for an event: a vararg return, not a table
--
-- The experimental-CVar popup suppression in SheetUI unregisters the event
-- from whichever frames own it, and read this API's return as a table. It is
-- varargs, so the read bound the FIRST frame; a frame is a table, so the
-- type() check passed, #frames was 0, nothing was unregistered, and the popup
-- kept firing with no error to show for it.
------------------------------------------------------------

local framesAPI = dofile("Compat.lua")
local EV = "EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED"

local f1 = { UnregisterEvent = function() end }
local f2 = { UnregisterEvent = function() end }
local f3 = { UnregisterEvent = function() end }
WoW.eventFrames[EV] = { f1, f2, f3 }

local owners = framesAPI.FramesRegisteredForEvent(EV)
eq("every registered frame comes back", #owners, 3)
eq("  in order [1]", owners[1], f1)
eq("  in order [3]", owners[3], f3)

-- The broken shape, kept as a live demonstration rather than a comment.
local _, firstOnly = pcall(GetFramesRegisteredForEvent, EV)
eq("one return value binds a frame, not a list", firstOnly, f1)
check("  and a frame passes a type() check", type(firstOnly) == "table")
eq("  while having no array part - hence the silent no-op", #firstOnly, 0)

eq("an event nobody registered for yields an empty list",
   #framesAPI.FramesRegisteredForEvent("NOBODY_LISTENS_TO_THIS"), 0)

-- A client without the lookup, or one that throws, degrades to an empty list
-- so the caller can fall back rather than error out.
local realLookup = GetFramesRegisteredForEvent
GetFramesRegisteredForEvent = nil
eq("a client missing the lookup yields an empty list",
   #framesAPI.FramesRegisteredForEvent(EV), 0)
GetFramesRegisteredForEvent = function() error("boom") end
eq("a lookup that throws yields an empty list",
   #framesAPI.FramesRegisteredForEvent(EV), 0)
GetFramesRegisteredForEvent = realLookup

check("the lookup is optional, not a required capability",
      framesAPI.AssertCapabilities() == true)

------------------------------------------------------------

print(("test_compat: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
