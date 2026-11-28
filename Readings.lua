------------------------------------------------------------
-- Readings.lua: durability, location and guild rank on the character's
-- record (#508, #395, #515), read at each scan and on their own events.
--
-- The synced-fields plan (agreed with Codex, owner's choices made):
-- https://github.com/Spotnick2/AltStable/issues/508#issuecomment-7237014013
-- What the client gives was measured on 1.60.1.71139 (docs/forever-api-notes.md,
-- "Guild, zone, durability, mail at expiry, XP lock").
--
-- Each is a field of the synced record, so it rides the sync as is, and
-- ClearSyncedStateFields clears it: a newer record without it (an older build)
-- reads unknown, never a stale value. Unknown is nil, never 0, 100 or "".
-- Written in place; TouchCharacter only when the value changed, so a delta
-- carries it.
------------------------------------------------------------

AltStable = AltStable or {}
local R = {}
AltStable.Readings = R

local function Secret(v)
    local isSecret = rawget(_G, "issecretvalue")
    return isSecret ~= nil and isSecret(v) == true
end

-- A string worth storing: not secret, not empty.
local function Text(v)
    if Secret(v) or type(v) ~= "string" or v == "" then return nil end
    return v
end

------------------------------------------------------------
-- Durability (#508): durMin, the lowest worn item's whole percent, and
-- dur_<slot> for each slot below 100 (the Roster tints those).
--
-- A read is a snapshot or nothing. An empty slot, or an item that answers
-- nil (rings, cloaks: no durability, measured), doesn't count. A readable 0 is
-- a broken item: 0 %. A secret answer makes the whole read unreadable: the
-- last snapshot stands while the gear is the same, and is dropped when it
-- changed, so a new item never inherits the old one's percent. Never measured
-- secret (not even in combat), but a wrong 100 % must not be possible.
------------------------------------------------------------

local function SetDurability(char, low, below)
    local changed = char.durMin ~= low
    for k in pairs(char) do
        if type(k) == "string" and k:find("^dur_") then
            local slot = k:sub(5)
            if below[slot] == nil then char[k] = nil; changed = true end
        end
    end
    for slot, pct in pairs(below) do
        if char["dur_" .. slot] ~= pct then char["dur_" .. slot] = pct; changed = true end
    end
    char.durMin = low
    return changed
end

-- gearChanged: whether an item changed since the last read (the scan knows).
function R.Durability(char, gearChanged)
    local low, below, unreadable = nil, {}, false
    for _, slot in ipairs(AltStable.GEAR_SLOTS or {}) do
        local cur, max = GetInventoryItemDurability(slot.id)
        if Secret(cur) or Secret(max) then
            unreadable = true
        elseif type(cur) == "number" and type(max) == "number" and max > 0 then
            local pct = math.floor(math.max(0, cur) / max * 100)
            if pct < 100 then below[slot.key] = pct end
            if not low or pct < low then low = pct end
        end
    end
    if unreadable then
        if gearChanged then return SetDurability(char, nil, {}) end
        return false
    end
    return SetDurability(char, low, below)
end

------------------------------------------------------------
-- Location (#395): zone, and subzone when there is one. At login the zone
-- reads nil until ZONE_CHANGED_NEW_AREA (measured): an empty zone keeps what
-- is stored. In a city's centre the subzone is the zone itself ("Orgrimmar"):
-- stored once. Inside an instance the zone names it and there is no subzone.
------------------------------------------------------------

function R.Location(char)
    local zone = Text(GetRealZoneText())
    if not zone then return false end
    local sub = Text(GetSubZoneText())
    if sub == zone then sub = nil end
    if char.zone == zone and char.subzone == sub then return false end
    char.zone, char.subzone = zone, sub
    return true
end

------------------------------------------------------------
-- Guild and rank (#515): guildRank (its name) and guildRankIndex (0 = the
-- guild master). Measured: before PLAYER_LOGIN a guilded character can read
-- "not in a guild", so nothing is read then. After it, IsInGuild() is right,
-- but the name and rank can still be missing for a second or so: not in a
-- guild clears the guild ("") and the rank; in one with no name yet keeps
-- what is stored. The rank index is 0 without a guild too, so it counts only
-- with a guild name.
------------------------------------------------------------

function R.Guild(char)
    if not IsLoggedIn() then return false end
    local inGuild = IsInGuild()
    if Secret(inGuild) then return false end
    local guild, rank, index
    if inGuild then
        local name, rankName, rankIndex = GetGuildInfo("player")
        guild = Text(name)
        if not guild then return false end
        rank = Text(rankName)
        index = not Secret(rankIndex) and tonumber(rankIndex) or nil
    else
        guild = ""
    end
    if char.guild == guild and char.guildRank == rank and char.guildRankIndex == index then return false end
    char.guild, char.guildRank, char.guildRankIndex = guild, rank, index
    return true
end

------------------------------------------------------------
-- Between scans: each on its own events, on our record. The durability event
-- fires dozens of times a minute with nothing changed (measured), hence the
-- debounce and the comparison; the guild events come in bursts.
------------------------------------------------------------

local function Ours()
    local guid = UnitGUID("player")
    local char = guid and AltStableDB and AltStableDB[guid]
    return guid, type(char) == "table" and char or nil
end

local function Changed(guid)
    if AltStable.TouchCharacter then AltStable.TouchCharacter(guid) end
    if AltStable.RefreshSheet then AltStable.RefreshSheet() end
end

R.DELAY = { durability = 1, guild = 2 }
local armed = {}

local function Later(kind, read)
    if armed[kind] then return end
    armed[kind] = true
    C_Timer.After(R.DELAY[kind], function()
        armed[kind] = nil
        local guid, char = Ours()
        if char and read(char) then Changed(guid) end
    end)
end

local frame = CreateFrame("Frame")
R.EVENTS = { "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA",
             "UPDATE_INVENTORY_DURABILITY",
             "PLAYER_GUILD_UPDATE", "GUILD_RANKS_UPDATE", "GUILD_RANKS_UPDATE_ACTIVE_PLAYER" }
for _, ev in ipairs(R.EVENTS) do frame:RegisterEvent(ev) end

function R.OnEvent(event, unit)
    if event:find("^ZONE_CHANGED") then
        -- At once: a delay would lose the last inn before a logout, and a
        -- touch only stamps the record (nothing is sent).
        local guid, char = Ours()
        if char and R.Location(char) then Changed(guid) end
    elseif event == "UPDATE_INVENTORY_DURABILITY" then
        Later("durability", function(char) return R.Durability(char, false) end)
    elseif event == "PLAYER_GUILD_UPDATE" and unit ~= nil and unit ~= "player" then
        return
    else
        Later("guild", R.Guild)
    end
end
frame:SetScript("OnEvent", function(_, event, unit) R.OnEvent(event, unit) end)
