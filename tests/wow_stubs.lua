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
    tooltipPostCalls = {},  -- [Enum.TooltipDataType.X] = { fn, ... }
    loaded      = {},
    loadCalls   = {},
    timers      = {},
    sent        = {},
    maxLevel    = 60,
    level = 1, xp = 0, xpMax = 400, resting = false,   -- restXP nil: measured "not rested"
    defense     = { 1, 0 },
    chatOut     = {},   -- captured DEFAULT_CHAT_FRAME output
    now         = 1700000000,  -- the clock time() reads; tests pin their own values
    eventFrames = {},   -- [event] = { frame, ... } for GetFramesRegisteredForEvent
}

function WoW.reset()
    WoW.items, WoW.skillLines, WoW.factions, WoW.factionByID = {}, {}, {}, {}
    WoW.containers, WoW.bankTabs, WoW.accountTabs = {}, {}, {}
    WoW.tooltipPostCalls = {}
    WoW.loaded, WoW.loadCalls, WoW.timers, WoW.sent = {}, {}, {}, {}
    WoW.maxLevel = 60
    WoW.level, WoW.xp, WoW.xpMax, WoW.restXP, WoW.resting = 1, 0, 400, nil, false
    WoW.defense = { 1, 0 }
    WoW.chatOut = {}
    WoW.eventFrames = {}
    WoW.now = 1700000000
    WoW.pendingPrio = nil
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
    -- Any unknown METHOD chains (widget methods are all capitalised). A plain
    -- field reads nil, as on a real frame - `row.dividers or {}` must see nil.
    setmetatable(f, { __index = function(_, k)
        if type(k) == "string" and k:find("^%u") then return chain end
    end })
    return f
end
WoW.makeFrame = makeFrame

function CreateFrame() return makeFrame() end

-- Pending timers land in WoW.timers as { delay = <seconds>, fn = <callback> }, so
-- a test can assert WHEN something was scheduled, not just that it ran. A
-- NewTimer handle that is cancelled drops out of the queue, the way the client
-- stops it firing - the old stub returned an inert handle and recorded nothing,
-- so a scheduled-for-later callback was invisible to every test.
C_Timer = {
    After = function(delay, fn)
        table.insert(WoW.timers, { delay = delay, fn = fn })
    end,
    NewTimer = function(delay, fn)
        local entry = { delay = delay, fn = fn }
        table.insert(WoW.timers, entry)
        entry.Cancel = function()
            for i, e in ipairs(WoW.timers) do
                if e == entry then table.remove(WoW.timers, i); return end
            end
        end
        return entry
    end,
    NewTicker = function(_, fn) return { Cancel = function() end } end,
}

function WoW.flushTimers()
    local t = WoW.timers
    WoW.timers = {}
    for _, e in ipairs(t) do e.fn() end
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

-- WoW.factions is the full list in order. As on the client, a collapsed
-- header hides the rows under it (up to the next header) from the indexed
-- calls; Expand/Collapse change what those calls see. One level of nesting.
local function VisibleFactions()
    local out, hiding = {}, false
    for _, f in ipairs(WoW.factions) do
        if f.isHeader then out[#out + 1] = f; hiding = f.isCollapsed
        elseif not hiding then out[#out + 1] = f end
    end
    return out
end

C_Reputation = {
    GetNumFactions        = function() return #VisibleFactions() end,
    GetFactionDataByIndex = function(i) return VisibleFactions()[i] end,
    ExpandAllFactionHeaders = function()
        for _, f in ipairs(WoW.factions) do if f.isHeader then f.isCollapsed = false end end
    end,
    CollapseFactionHeader = function(i)
        local f = VisibleFactions()[i]
        if f and f.isHeader then f.isCollapsed = true end
    end,
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

-- TooltipDataProcessor: the Retail replacement for the OnTooltipSetItem script
-- hook, which THROWS on this client (see HookScript above). Registered
-- post-calls land in WoW.tooltipPostCalls[dataType] so a test can fire one.
TooltipDataProcessor = {
    AddTooltipPostCall = function(dataType, fn)
        WoW.tooltipPostCalls[dataType] = WoW.tooltipPostCalls[dataType] or {}
        table.insert(WoW.tooltipPostCalls[dataType], fn)
    end,
}

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
        -- prio is set only when the send came through ChatThrottleLib, so a
        -- raw send is distinguishable from a paced one.
        table.insert(WoW.sent, { prefix = prefix, text = text, channel = channel,
                                 target = target, prio = WoW.pendingPrio })
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
-- Like the bundled ChatThrottleLib v24 in the two ways that matter here: an
-- unknown priority or an over-255-byte message RAISES, which is what
-- QueueWire's raw fallback exists for - a stub that accepted anything left that
-- fallback untested. The priority is recorded on the captured send, so a paced
-- send is distinguishable from a raw one, and it is cleared even if the inner
-- send fails so it can never leak onto the next raw send.
local CTL_PRIORITIES = { BULK = true, NORMAL = true, ALERT = true }
ChatThrottleLib = {
    SendAddonMessage = function(_, prio, prefix, text, channel, target)
        if not CTL_PRIORITIES[prio] then
            error("ChatThrottleLib:SendAddonMessage(): unknown priority " .. tostring(prio), 2)
        end
        if #tostring(text) > 255 then
            error("ChatThrottleLib:SendAddonMessage(): message length cannot exceed 255 bytes", 2)
        end
        WoW.pendingPrio = prio
        local ok, r = pcall(C_ChatInfo.SendAddonMessage, prefix, text, channel, target)
        WoW.pendingPrio = nil
        if not ok then error(r, 2) end
        return r
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
function GetBuildInfo() return "1.60.1", "69977", "Sep 22 2026", 16001 end

-- Measured: nil when the character is not rested (docs/forever-api-notes.md).
function GetXPExhaustion() return WoW.restXP end
-- UnitXPMax at the level cap is unmeasured on Forever; Retail returns 0 there,
-- which is why callers must not divide by it unguarded. Tests set WoW.xpMax = 0.
function UnitXPMax() return WoW.xpMax end
function UnitXP() return WoW.xp end
function IsResting() return WoW.resting end

-- nil for a path the client doesn't have. WoW.textures: set of known paths;
-- nil (the default) means every path resolves.
function GetFileIDFromPath(path)
    if WoW.textures == nil then return 1 end
    return WoW.textures[path] and 1 or nil
end

function GetMaxPlayerLevel() return WoW.maxLevel end
function UnitLevel() return WoW.level end
function GetTime() return 0 end
-- A fixed clock, never the wall clock. Sync watermarks, the merge's 60-second
-- window and the stall deadlines are all time comparisons: a clock stuck at 0
-- made them untestable, and the wall clock made the suite depend on the date it
-- ran - sections on real time and sections pinned to 1000 stamped and read the
-- same state with different clocks, and one assertion quietly stopped testing
-- anything because every seeded expiry had become "the past". Tests pin their
-- own WoW.now where a value matters.
function time() return WoW.now end

-- WoW exposes `date` as a global (Lua 5.1 only has os.date), and anything
-- formatting a reset time calls it. Pinned to UTC so a test asserting a weekday
-- does not depend on the machine's timezone.
function date(fmt, t) return os.date("!" .. (fmt or "%c"), t or WoW.now) end

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
-- pieces). This stub used to ignore it. Core.lua reads every wire message as
-- strsplit("|", message, 2) and then parses the rest, and the rest has more "|"
-- in its HEADER: "CHUNK5|<sid>|<seq>/<total>|<body>", "DONE8|<sid>|<checksum>".
-- Without the limit the payload was only the next field, so every CHUNK and
-- DONE failed to parse and the receive path was untestable. (A chunk body can
-- contain "|" too, but that is not what broke: an all-printable body fails the
-- same way - so a "|"-free body encoding would NOT make the limit unnecessary.)
--
-- A nil string is an error, as it is for the client's C string functions,
-- rather than quietly becoming the text "nil" and letting a nil message fall
-- through as an unknown command.
function strsplit(sep, str, limit)
    if str == nil then
        error("bad argument #2 to 'strsplit' (string expected, got nil)", 2)
    end
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
