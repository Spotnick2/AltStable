------------------------------------------------------------
-- wow_stubs.lua
--
-- A WoW: Forever (1.60.1) API surface, minimal but SHAPED CORRECTLY, so
-- AltStable's files load and run under stock Lua 5.1 with no game client.
--
-- Two rules this file exists to enforce:
--
--   1. The removed Classic globals are NOT defined here. GetItemInfo,
--      GetSkillLineInfo, GetFactionInfo, GetContainerItemInfo and friends are
--      absent on the real client, so code that reaches for one must fail in
--      tests too. Defining them "for convenience" would hide exactly the bug
--      this port is about.
--
--   2. Return SHAPES match what was measured in-game, not what Classic did.
--      Skills, reputation and containers return a STRUCT. Items return the
--      Classic tuple. A cache miss returns NOTHING - not nil.
--
-- Load this FIRST in every test file:  dofile("tests/wow_stubs.lua")
-- Drive it through the exported `WoW` table; reset with WoW.reset().
------------------------------------------------------------

local WoW = {
    items       = {},   -- [itemID] = { name=, quality=, ilvl=, ... }; absent = cache miss
    skillLines  = {},   -- array of skill structs
    factions    = {},   -- array of faction structs
    factionByID = {},   -- [factionID] = struct (may hold ids not in `factions`)
    containers  = {},   -- [bagID] = { name=, size=, [slot] = itemStruct }
    bankTabs    = {},   -- purchased CHARACTER bank tab ids
    accountTabs = {},   -- purchased ACCOUNT bank tab ids (should never be scanned)
    loaded      = {},
    loadCalls   = {},
    timers      = {},
    sent        = {},
    maxLevel    = 60,
    defense     = { 1, 0 },
    chatOut     = {},   -- captured DEFAULT_CHAT_FRAME output
    now         = nil,  -- pinned clock for time(); nil means real os.time()
    eventFrames = {},   -- [event] = { frame, ... } for GetFramesRegisteredForEvent
}

function WoW.reset()
    WoW.items, WoW.skillLines, WoW.factions, WoW.factionByID = {}, {}, {}, {}
    WoW.containers, WoW.bankTabs, WoW.accountTabs = {}, {}, {}
    WoW.loaded, WoW.loadCalls, WoW.timers, WoW.sent = {}, {}, {}, {}
    WoW.maxLevel = 60
    WoW.defense = { 1, 0 }
    WoW.chatOut = {}
    WoW.eventFrames = {}
    WoW.now = nil
end

------------------------------------------------------------
-- Frames / timers
------------------------------------------------------------

-- Events the live client REJECTS. Measured: RegisterEvent throws on these.
-- A stub that accepted every event would contradict our own notes and let a
-- dead handler ship.
local INVALID_EVENTS = {
    PLAYERBANKBAGSLOTS_CHANGED = true,
    TRADE_SKILL_UPDATE         = true,
}
WoW.INVALID_EVENTS = INVALID_EVENTS

local function makeFrame()
    local f = {}
    local function chain() return f end
    f.RegisterEvent = function(self, ev)
        if INVALID_EVENTS[ev] then
            error('Frame:RegisterEvent(): Attempt to register unknown event "' .. tostring(ev) .. '"', 2)
        end
        self["_ev_" .. tostring(ev)] = true
        return self
    end
    f.IsEventRegistered = function(self, ev) return self["_ev_" .. tostring(ev)] == true end
    f.SetScript = function(self, ev, fn) self["_script_" .. tostring(ev)] = fn; return self end
    f.GetScript = function(self, ev) return self["_script_" .. tostring(ev)] end
    -- Unlike the AltStable stubs, HookScript REJECTS unknown script types the
    -- way the live client does. OnTooltipSetItem throws there, and a stub that
    -- accepted everything is precisely why the old Warband tests could not
    -- catch that (issue #10).
    f.HookScript = function(self, ev, fn)
        if ev == "OnTooltipSetItem" or ev == "OnTooltipSetUnit" then
            error("bad argument #2 to 'HookScript' (Usage: self:HookScript(scriptTypeName, script))", 2)
        end
        self["_hook_" .. tostring(ev)] = fn
        return self
    end
    f.CreateTexture    = function() return makeFrame() end
    f.CreateFontString = function() return makeFrame() end
    setmetatable(f, { __index = function() return chain end })
    return f
end
WoW.makeFrame = makeFrame

function CreateFrame() return makeFrame() end

C_Timer = {
    After     = function(_, fn) table.insert(WoW.timers, fn) end,
    NewTimer  = function(_, fn) return { Cancel = function() end } end,
    NewTicker = function(_, fn) return { Cancel = function() end } end,
}

function WoW.flushTimers()
    local t = WoW.timers
    WoW.timers = {}
    for _, fn in ipairs(t) do fn() end
end

DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(WoW.chatOut, m) end }

------------------------------------------------------------
-- Enums, measured from the live client
------------------------------------------------------------

Enum = {
    BagIndex = {
        Keyring = -1, Characterbanktab = -2, Accountbanktab = -3,
        Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4,
        ReagentBag = 5,
        CharacterBankTab_1 = 6,  CharacterBankTab_2 = 7,  CharacterBankTab_3 = 8,
        CharacterBankTab_4 = 9,  CharacterBankTab_5 = 10, CharacterBankTab_6 = 11,
        CharacterBankTab_7 = 12, CharacterBankTab_8 = 13, CharacterBankTab_9 = 14,
        AccountBankTab_1 = 15, AccountBankTab_2 = 16, AccountBankTab_3 = 17,
        AccountBankTab_4 = 18, AccountBankTab_5 = 19, AccountBankTab_6 = 20,
        AccountBankTab_7 = 21, AccountBankTab_8 = 22, AccountBankTab_9 = 23,
    },
    BankType = { Character = 0, Guild = 1, Account = 2 },
    TooltipDataType = { Item = 0 },
}

------------------------------------------------------------
-- C_Item  (tuple returns, Classic order)
------------------------------------------------------------

local function itemID(v)
    if type(v) == "number" then return v end
    if type(v) ~= "string" then return nil end
    return tonumber(v:match("item:(%d+)")) or tonumber(v)
end

C_Item = {
    -- A cache miss returns NOTHING. `return` with no values, not `return nil`:
    -- select("#", ...) must be 0, which is what the live client does and what
    -- the adapter has to preserve.
    GetItemInfo = function(v)
        local it = WoW.items[itemID(v) or -1]
        if not it then return end
        local id = itemID(v)
        return it.name, "|Hitem:" .. id .. "|h[" .. (it.name or "") .. "]|h",
               it.quality, it.ilvl, it.minLevel or 0,
               it.itemType, it.subType, it.stackCount or 1,
               it.equipLoc, it.icon, it.sellPrice or 0,
               it.classID, it.subClassID, it.bindType or 0,
               it.expacID or 0, it.setID, it.isReagent or false, ""
    end,
    GetItemInfoInstant = function(v)
        local id = itemID(v)
        local it = WoW.items[id or -1]
        if not it then return end
        return id, it.itemType, it.subType, it.equipLoc, it.icon, it.classID, it.subClassID
    end,
    GetItemIconByID = function(v)
        local it = WoW.items[itemID(v) or -1]
        return it and it.icon or nil
    end,
    -- Present, and takes an ItemLocation - calling it with an item id errors,
    -- exactly as measured. Kept so a test can prove we never call it.
    GetItemIcon = function(loc)
        if type(loc) ~= "table" then
            error("bad argument #1 to 'GetItemIcon' (Usage: local icon = C_Item.GetItemIcon(itemLocation))", 2)
        end
        return nil
    end,
    GetItemCount = function(v) local it = WoW.items[itemID(v) or -1]; return it and (it.count or 0) or 0 end,
    GetItemStats = function(v) local it = WoW.items[itemID(v) or -1]; if not it then return end; return it.stats or {} end,
    GetItemQualityByID = function(v) local it = WoW.items[itemID(v) or -1]; return it and it.quality or nil end,
}

------------------------------------------------------------
-- C_SkillInfo  (STRUCT)
------------------------------------------------------------

C_SkillInfo = {
    GetNumSkillLines = function() return #WoW.skillLines end,
    GetSkillLineInfo = function(i) return WoW.skillLines[i] end,
}

------------------------------------------------------------
-- C_Reputation  (STRUCT)
------------------------------------------------------------

C_Reputation = {
    GetNumFactions        = function() return #WoW.factions end,
    GetFactionDataByIndex = function(i) return WoW.factions[i] end,
    -- Deliberately backed by a SEPARATE table: the live client returns
    -- factions that are not in the indexed list, which is the whole reason we
    -- key reputations off ids instead of walking the UI list.
    GetFactionDataByID    = function(id) return WoW.factionByID[id] end,
}

------------------------------------------------------------
-- C_Container  (STRUCT)
------------------------------------------------------------

C_Container = {
    GetContainerNumSlots = function(bag) local b = WoW.containers[bag]; return b and b.size or 0 end,
    GetBagName           = function(bag) local b = WoW.containers[bag]; return b and b.name or nil end,
    GetContainerItemInfo = function(bag, slot)
        local b = WoW.containers[bag]
        return b and b[slot] or nil
    end,
    GetContainerItemLink = function(bag, slot)
        local b = WoW.containers[bag]
        return b and b[slot] and b[slot].hyperlink or nil
    end,
    GetContainerItemID = function(bag, slot)
        local b = WoW.containers[bag]
        return b and b[slot] and b[slot].itemID or nil
    end,
}

------------------------------------------------------------
-- C_Bank
------------------------------------------------------------

C_Bank = {
    FetchPurchasedBankTabIDs = function(bankType)
        if bankType == Enum.BankType.Character then return WoW.bankTabs end
        if bankType == Enum.BankType.Account   then return WoW.accountTabs end
        return {}
    end,
    FetchNumPurchasedBankTabs = function(bankType)
        return #(C_Bank.FetchPurchasedBankTabIDs(bankType))
    end,
    CanViewBank = function(bankType) return bankType == Enum.BankType.Character end,
    FetchViewableBankTypes = function() return { Enum.BankType.Character } end,
}

------------------------------------------------------------
-- C_AddOns / C_ChatInfo
------------------------------------------------------------

C_AddOns = {
    IsAddOnLoaded    = function(a) return WoW.loaded[a] == true end,
    LoadAddOn        = function(a) table.insert(WoW.loadCalls, a); WoW.loaded[a] = true; return true end,
    GetAddOnMetadata = function(_, field) return field == "Version" and "dev" or nil end,
}

C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendAddonMessage = function(prefix, text, channel, target)
        table.insert(WoW.sent, { prefix = prefix, text = text, channel = channel, target = target })
        return true
    end,
}

------------------------------------------------------------
-- Plain globals that survived
------------------------------------------------------------

-- Identity, in the measured Forever shape: the surname is part of the name
-- string and SPACE-separated, and UnitName's second return is the realm only
-- for a cross-realm unit. GetPlayerInfoByGUID deliberately returns the FIRST
-- NAME ONLY at position 6, because the live client does and the two sources
-- disagreeing is a real trap.
WoW.player = { name = "Example Surname", realm = "Classic Beta PvE",
               normalizedRealm = "ClassicBetaPvE", guid = "Player-1234-0000AAAA",
               class = "PRIEST", classLocalized = "Priest", race = "Scourge" }

function UnitName(unit) if unit == "player" then return WoW.player.name, nil end end
function UnitFullName(unit) if unit == "player" then return WoW.player.name, WoW.player.normalizedRealm end end
function UnitNameUnmodified(unit) return UnitName(unit) end
function GetUnitName(unit) return (UnitName(unit)) end
function UnitGUID(unit) if unit == "player" then return WoW.player.guid end end
function UnitNameFromGUID() return WoW.player.name end
function GetPlayerInfoByGUID()
    local first = WoW.player.name:match("^(%S+)")
    return WoW.player.classLocalized, WoW.player.class, "Undead", WoW.player.race, 1, first, ""
end
function GetRealmName() return WoW.player.realm end
function GetNormalizedRealmName() return WoW.player.normalizedRealm end
function UnitClass(unit) if unit == "player" then return WoW.player.classLocalized, WoW.player.class end end
function UnitRace(unit) if unit == "player" then return "Undead", WoW.player.race end end
function UnitSex() return 3 end
function UnitFactionGroup() return "Horde", "Horde" end
function IsLoggedIn() return WoW.loggedIn ~= false end
function GetMoney() return 0 end
function IsInGuild() return false end

SlashCmdList = {}
UISpecialFrames = {}
function ChatFrame_AddMessageEventFilter() end
ChatThrottleLib = {
    SendAddonMessage = function(_, _, prefix, text, channel, target)
        return C_ChatInfo.SendAddonMessage(prefix, text, channel, target)
    end,
}
function GetGuildInfo() return nil end

-- Frames registered for an event come back as VARARGS (frame1, frame2, ...),
-- never as a table. A stub that returned a table would let the exact bug this
-- models ship again: one return value binds the first FRAME, which is itself a
-- table, so a type() check passes and the list reads as empty.
function GetFramesRegisteredForEvent(event)
    return unpack(WoW.eventFrames[event] or {})
end

function UnitDefenseSkill() return WoW.defense[1], WoW.defense[2] end
-- Four returns, in this order. Config.lua reads the build from the second.
function GetBuildInfo() return "1.60.1", "69913", "Sep 17 2026", 16001 end

function GetMaxPlayerLevel() return WoW.maxLevel end
function UnitLevel() return 1 end
function GetTime() return 0 end
-- Real os.time() by default; a test pins it with WoW.now = <epoch>. The sync
-- watermarks, the merge's 60-second window and the stall deadlines are all
-- time comparisons, so a clock stuck at 0 would make them untestable.
function time() return WoW.now or os.time() end

-- The payload of every captured SendAddonMessage, in send order.
function WoW.sentMessages()
    local msgs = {}
    for _, m in ipairs(WoW.sent) do msgs[#msgs + 1] = m.text end
    return msgs
end

-- WoW's strsplit takes a SET of delimiter characters and returns the fields
-- between them, preserving genuinely empty fields (adjacent or trailing
-- delimiters) but inventing none.
--
-- The obvious `gmatch("[^sep]*")` implementation is wrong: the `*` matches an
-- empty string at each delimiter AND again at end-of-string, so every field
-- after the first is shifted. Measured with that version:
--
--   strsplit("-", "Name Surname-Realm")   -> "Name Surname", "", "Realm", ""
--   strsplit("|", "CHUNK5|sid|1/3|body")  -> 8 fields instead of 4
--
-- That would have quietly corrupted both the realm-stripping in PeerShort and
-- every wire-format assertion in the eventual test_comm port.
-- `sep` is a LITERAL set of characters, not a Lua pattern, so every
-- non-alphanumeric is escaped before it goes into a character class.
-- Interpolating it raw breaks on the class metacharacters: `sep = "^"` builds
-- "[^]", which throws "malformed pattern (missing ']')" rather than splitting.
-- `]`, `%` and `-` are the same hazard. Escaping keeps the search in C, which
-- matters once test_comm starts splitting multi-KB serialized records.
-- `limit` caps the number of pieces, and the last one keeps the rest of the
-- string untouched, delimiters included - the client's strsplit(delim, str,
-- pieces). This stub used to ignore it, which let a real dependency go
-- unmodelled: Core.lua reads every wire message as strsplit("|", message, 2),
-- and a sync chunk's body is raw compressed bytes that can contain "|". Without
-- the limit, every chunk parsed as malformed and the whole receive path was
-- untestable.
function strsplit(sep, str, limit)
    str = tostring(str)
    local escaped = tostring(sep):gsub("(%W)", "%%%1")
    local pattern = "[" .. escaped .. "]"
    local out, start = {}, 1
    while true do
        if limit and #out == limit - 1 then break end
        local s, e = str:find(pattern, start)
        if not s then break end
        out[#out + 1] = str:sub(start, s - 1)
        start = e + 1
    end
    out[#out + 1] = str:sub(start)
    return unpack(out)
end

_G.WoW = WoW
return WoW
