--[[
    Compat.lua — the Retail-API adapter layer.

    WoW: Forever runs Vanilla content on Blizzard's Mainline (Retail) codebase,
    so most bare Classic globals are gone. Rather than rewrite every call site,
    each consuming file takes a file-local alias off this table:

        local GetItemInfo = AltStable.API.GetItemInfo

    Deliberately NOT injected into _G. Defining a real global named GetItemInfo
    would change capability detection for every other addon loaded, make us
    load-order dependent, and put an addon-owned global where Blizzard code can
    reach it. Nothing here is worth that.

    This is an adapter for the contracts this addon actually consumes, not a
    historical-API emulator. Every mapping below is measured against a live
    client — see docs/forever-api-notes.md. Two shapes to keep straight:

      * TUPLE-preserving: C_Item.GetItemInfo and GetItemInfoInstant kept the
        Classic return order, so they alias directly.
      * STRUCT-returning: skills, reputation and containers now return ONE
        table. Their old call sites destructure a tuple, so they must be
        rewritten (issue #4) - aliasing alone is not enough, and a shifted
        tuple yields empty data with no error.
]]

AltStable = AltStable or {}

local API = {}
AltStable.API = API

-- Collected rather than thrown: one loud report beats a stack trace per call,
-- and on this client error delivery stops after 100 errors per session.
local missing = {}

local function need(namespace, nsName, fnName)
    local fn = namespace and namespace[fnName]
    if type(fn) ~= "function" then
        missing[#missing + 1] = nsName .. "." .. fnName
        return nil
    end
    return fn
end

local function needGlobal(fnName)
    local fn = _G[fnName]
    if type(fn) ~= "function" then
        missing[#missing + 1] = fnName
        return nil
    end
    return fn
end

----------------------------------------------------------------------------
-- Items
--
-- GetItemInfo / GetItemInfoInstant keep the Classic tuple order (18 and 7
-- returns respectively), so these are honest aliases.
--
-- Cache misses return NO values at all - not nil. Measured: the identical call
-- returned 18 values on one character and zero on another, because the item
-- cache is per client. Aliasing preserves that; callers must handle it, and a
-- gear scan needs the GET_ITEM_INFO_RECEIVED retry path rather than a nil
-- check (issue #5).
----------------------------------------------------------------------------

API.GetItemInfo        = need(C_Item, "C_Item", "GetItemInfo")
API.GetItemInfoInstant = need(C_Item, "C_Item", "GetItemInfoInstant")
API.GetItemCount       = need(C_Item, "C_Item", "GetItemCount")
API.GetItemStats       = need(C_Item, "C_Item", "GetItemStats")
API.GetItemQualityByID = need(C_Item, "C_Item", "GetItemQualityByID")

-- NOT GetItemIcon. C_Item.GetItemIcon exists but takes an ItemLocation, and
-- every call site here passes an item ID - so a same-name alias compiles, runs,
-- and errors at runtime with "bad argument #1 ... Usage: GetItemIcon(itemLocation)".
-- Confirmed in-game. The name is deliberately not carried over so the trap
-- cannot quietly reappear; tests/test_compat.lua asserts API.GetItemIcon is nil.
API.GetItemIconByID    = need(C_Item, "C_Item", "GetItemIconByID")

----------------------------------------------------------------------------
-- Skills  (STRUCT)
--
-- C_SkillInfo.GetSkillLineInfo(i) returns one table:
--   { name, isHeader, rank, maxRank, skillID, skillLineCategoryID,
--     parentSkillLineID, description, modifier, minLevel, isCollapsed, ... }
--
-- The old Scanner.lua:578 read name/isHeader/rank/max from tuple positions
-- 1/2/4/7. maxRank is also dynamic for weapon and defense skills (5 x level:
-- measured 5 at level 1, 15 at level 3), so read it per line rather than
-- assuming a cap.
----------------------------------------------------------------------------

API.GetNumSkillLines = need(C_SkillInfo, "C_SkillInfo", "GetNumSkillLines")
API.GetSkillLineInfo = need(C_SkillInfo, "C_SkillInfo", "GetSkillLineInfo")

----------------------------------------------------------------------------
-- Reputation  (STRUCT)
--
-- C_Reputation.GetFactionDataByIndex(i) returns one table:
--   { name, factionID, reaction, currentStanding, currentReactionThreshold,
--     nextReactionThreshold, isHeader, isCollapsed, isWatched, atWarWith, ... }
-- Standing is `reaction` (4 = Neutral, 5 = Friendly).
--
-- GetFactionDataByID reaches factions that are NOT in the visible indexed list
-- - measured: GetNumFactions() was 5, yet Argent Dawn, Cenarion Circle and
-- Thorium Brotherhood all returned full data. So prefer a static faction-ID map
-- over walking the UI list: no collapsed-header blind spots, no English-name
-- matching. Returns nil for a faction the character cannot have.
----------------------------------------------------------------------------

API.GetNumFactions         = need(C_Reputation, "C_Reputation", "GetNumFactions")
API.GetFactionDataByIndex  = need(C_Reputation, "C_Reputation", "GetFactionDataByIndex")
API.GetFactionDataByID     = need(C_Reputation, "C_Reputation", "GetFactionDataByID")

----------------------------------------------------------------------------
-- Containers  (STRUCT)
--
-- GetContainerItemInfo returns one table:
--   { itemID, itemName, hyperlink, stackCount, quality, iconFileID,
--     isBound, isLocked, isFiltered, isReadable, hasLoot, hasNoValue }
----------------------------------------------------------------------------

API.GetContainerNumSlots  = need(C_Container, "C_Container", "GetContainerNumSlots")
API.GetContainerItemInfo  = need(C_Container, "C_Container", "GetContainerItemInfo")
API.GetContainerItemLink  = need(C_Container, "C_Container", "GetContainerItemLink")
API.GetContainerItemID    = need(C_Container, "C_Container", "GetContainerItemID")
API.GetBagName            = need(C_Container, "C_Container", "GetBagName")

----------------------------------------------------------------------------
-- Container identity
--
-- Every Classic bank constant is wrong here. Measured Enum.BagIndex:
--
--   Keyring          = -1     <- was -2 on Classic
--   Characterbanktab = -2     <- bank-TYPE pseudo-ids, not readable containers
--   Accountbanktab   = -3
--   Backpack         =  0
--   Bag_1 .. Bag_4   =  1 .. 4
--   ReagentBag       =  5
--   CharacterBankTab_1 .. _9 =  6 .. 14
--   AccountBankTab_1   .. _9 = 15 .. 23
--
-- These derive the ids from the enum rather than hardcoding them, so a client
-- update that renumbers containers is picked up rather than silently scanning
-- the wrong bags. What a given plugin chooses to scan stays that plugin's
-- decision (issue #9); this only answers "which id is what".
----------------------------------------------------------------------------

-- Bags the character carries: backpack, the four bag slots, and the reagent
-- bag. The keyring is excluded deliberately - it is a separate concern and
-- callers that want keys should ask for it by name.
function API.GetCarriedBagIDs()
    local E = Enum and Enum.BagIndex
    if not E then return { 0, 1, 2, 3, 4, 5 } end
    local ids = { E.Backpack }
    for i = 1, 4 do ids[#ids + 1] = E["Bag_" .. i] end
    if E.ReagentBag then ids[#ids + 1] = E.ReagentBag end
    return ids
end

function API.GetKeyringBagID()
    return Enum and Enum.BagIndex and Enum.BagIndex.Keyring or nil
end

-- Bank tabs are ordinary containers (GetContainerNumSlots(6) -> 48), but they
-- are PURCHASED INDIVIDUALLY, so the set is dynamic and must be queried - a
-- hardcoded range reports phantom empty tabs.
--
-- Filtered to the Character bank on purpose. An account bank exists in the API
-- but is not viewable yet, with capacity already defined at 9 tabs (ids 15-23)
-- and a prompt describing storage "shared with all members in your Account".
-- If those are ever enabled and folded into each character's bank map, shared
-- items get counted once per alt and every cross-alt total inflates.
function API.GetCharacterBankTabIDs()
    if not (C_Bank and Enum and Enum.BankType) then return {} end
    local fetch = C_Bank.FetchPurchasedBankTabIDs
    if type(fetch) ~= "function" then return {} end
    local ok, ids = pcall(fetch, Enum.BankType.Character)
    if not ok or type(ids) ~= "table" then return {} end
    local out = {}
    for _, id in ipairs(ids) do
        if type(id) == "number" then out[#out + 1] = id end
    end
    return out
end

----------------------------------------------------------------------------
-- Addon loading
----------------------------------------------------------------------------

API.IsAddOnLoaded    = need(C_AddOns, "C_AddOns", "IsAddOnLoaded")
API.LoadAddOn        = need(C_AddOns, "C_AddOns", "LoadAddOn")
API.GetAddOnMetadata = need(C_AddOns, "C_AddOns", "GetAddOnMetadata")

----------------------------------------------------------------------------
-- Units and world
----------------------------------------------------------------------------

-- UnitDefense is gone; UnitDefenseSkill keeps the same (base, modifier) pair.
-- Vanilla defense skill genuinely exists on this client.
API.UnitDefenseSkill = needGlobal("UnitDefenseSkill")

-- MAX_PLAYER_LEVEL is nil here. GetMaxPlayerLevel() returns 60. Reading it
-- rather than hardcoding means the level cap follows the client through
-- content patches instead of needing a code change.
function API.GetMaxPlayerLevel()
    if type(_G.GetMaxPlayerLevel) == "function" then
        local ok, v = pcall(_G.GetMaxPlayerLevel)
        if ok and type(v) == "number" and v > 0 then return v end
    end
    return _G.MAX_PLAYER_LEVEL or 60
end

----------------------------------------------------------------------------
-- Capability report
--
-- Fail visibly during development rather than degrading into fabricated
-- zeroes. Absent optional features should read as unavailable; absent REQUIRED
-- ones should be impossible to miss.
----------------------------------------------------------------------------

API.missing = missing

function API.AssertCapabilities()
    if #missing == 0 then return true end
    local msg = "|cffff5555AltStable: " .. #missing
        .. " required API(s) missing on this client:|r " .. table.concat(missing, ", ")
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(msg) end
    return false, missing
end

return API
