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
-- The scan expands collapsed headers to see every faction, then restores them.
API.ExpandAllFactionHeaders = need(C_Reputation, "C_Reputation", "ExpandAllFactionHeaders")
API.CollapseFactionHeader   = need(C_Reputation, "C_Reputation", "CollapseFactionHeader")

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
--
-- Returns `ids` on success, or `nil, reason` if the enum is unusable. No
-- permissive fallback on purpose: a hardcoded {0,1,2,3,4,5} would be right for
-- today's client but would silently reassert Classic numbering exactly when
-- the enum tells us it changed, and an incomplete list reads to a caller as a
-- successful scan of a smaller inventory. Refusing is recoverable; quietly
-- scanning the wrong bags is not.
function API.GetCarriedBagIDs()
    local E = Enum and Enum.BagIndex
    if type(E) ~= "table" then return nil, "Enum.BagIndex unavailable" end
    local ids = {}
    for _, key in ipairs({ "Backpack", "Bag_1", "Bag_2", "Bag_3", "Bag_4", "ReagentBag" }) do
        local id = E[key]
        if type(id) ~= "number" then return nil, "Enum.BagIndex." .. key .. " missing" end
        ids[#ids + 1] = id
    end
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
--
-- Returns `ids` on success — `{}` genuinely meaning "no tabs purchased" — or
-- `nil, reason` on failure. Keeping those distinct matters downstream: Warband
-- must tell "enumeration failed, keep the last good snapshot" apart from
-- "enumeration succeeded, the bank is empty". Collapsing both to `{}` would
-- let a transient failure quietly wipe a character's stored bank contents.
function API.GetCharacterBankTabIDs()
    if not (Enum and Enum.BankType and type(Enum.BankType.Character) == "number") then
        return nil, "Enum.BankType.Character unavailable"
    end
    if type(C_Bank) ~= "table" then return nil, "C_Bank unavailable" end
    local fetch = C_Bank.FetchPurchasedBankTabIDs
    if type(fetch) ~= "function" then return nil, "C_Bank.FetchPurchasedBankTabIDs unavailable" end

    local ok, ids = pcall(fetch, Enum.BankType.Character)
    if not ok then return nil, "FetchPurchasedBankTabIDs errored: " .. tostring(ids) end
    if type(ids) ~= "table" then return nil, "expected a table, got " .. type(ids) end

    local out = {}
    for i, id in ipairs(ids) do
        -- Reject a malformed response whole rather than filtering it into a
        -- plausible-looking partial inventory.
        if type(id) ~= "number" then
            return nil, "malformed tab id at index " .. i .. " (" .. type(id) .. ")"
        end
        out[#out + 1] = id
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

-- MAX_PLAYER_LEVEL is nil here; GetMaxPlayerLevel() returns 60. Reading it
-- rather than hardcoding means the level cap follows the client through
-- content patches instead of needing a code change.
--
-- No MAX_PLAYER_LEVEL fallback: it is measured nil on this client, and a
-- truthy-test on it would happily accept a string or 0 from some future build.
-- Missing is reported through the capability check like any other required API.
local getMaxPlayerLevel = needGlobal("GetMaxPlayerLevel")

function API.GetMaxPlayerLevel()
    if not getMaxPlayerLevel then return nil, "GetMaxPlayerLevel unavailable" end
    local ok, v = pcall(getMaxPlayerLevel)
    if ok and type(v) == "number" and v > 0 then return v end
    return nil, "GetMaxPlayerLevel returned " .. tostring(v)
end

-- The level cap every display and rested-XP rule compares against. 60 is the
-- value measured on 1.60.1.69913, used only when the client can't be read -
-- the capability check reports that case separately.
function API.LevelCap()
    return API.GetMaxPlayerLevel() or 60
end

----------------------------------------------------------------------------
-- Frames registered for an event
--
-- GetFramesRegisteredForEvent returns VARARGS - frame1, frame2, ... - not a
-- table. The tempting `local ok, frames = pcall(GetFramesRegisteredForEvent,
-- ev)` binds `frames` to the FIRST frame; a frame is a Lua table, so a
-- type() check passes, but it has no array part, so #frames is 0 and the
-- caller reads "nobody is registered" and silently does nothing. That is a
-- return-shape question, so it belongs here with the other ones - and with a
-- test behind it.
--
-- Read out of _G at call time rather than captured at load: callers degrade
-- when it is absent, so it is not a required contract and has no business in
-- `missing`.
----------------------------------------------------------------------------

function API.FramesRegisteredForEvent(event)
    local fn = _G and _G.GetFramesRegisteredForEvent
    if type(fn) ~= "function" then return {} end
    local function collect(ok, ...)
        if not ok then return {} end
        local frames = {}
        for i = 1, select("#", ...) do
            local f = select(i, ...)
            if f ~= nil then frames[#frames + 1] = f end
        end
        return frames
    end
    return collect(pcall(fn, event))
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
