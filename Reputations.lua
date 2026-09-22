-- Retail-API adapters; see Compat.lua.
local API = AltStable.API
local GetNumFactions        = API.GetNumFactions
local GetFactionDataByIndex = API.GetFactionDataByIndex

------------------------------------------------------------
-- The reputations AltStable tracks - one table, and every consumer (the sheet's
-- columns, the Reputations section, Export, sync clearing) derives from it.
--
-- Keyed by faction ID, never by name. A standing is stored on the character as
-- rep_<factionID> = reaction (1 Hated .. 4 Neutral .. 8 Exalted).
--
-- IDs: the Vanilla set from warcraft.wiki.gg's FactionID table; the Forever-only
-- set measured with GetFactionDataByID on 1.60.1.69913 from both sides. Hidden
-- from Alliance (nil there): Windshapers, Bolder'ok Clan, Earthen Ring, Durotar
-- Supply and Logistics. Hidden from Horde: High Order, Brotherhood of the Horse,
-- Azeroth Commerce Authority.
--
-- `short` is the stacked header label; keep it to about six characters.
------------------------------------------------------------

AltStable.REPUTATIONS = {
    -- Capitals (and Forever's Skyborne, one faction per side)
    { id = 72,   label = "Stormwind",            short = "Stormw" },
    { id = 47,   label = "Ironforge",            short = "Ironfg" },
    { id = 69,   label = "Darnassus",            short = "Darnas" },
    { id = 54,   label = "Gnomeregan Exiles",    short = "Gnome"  },
    { id = 2779, label = "High Order",           short = "HiOrdr" },
    { id = 76,   label = "Orgrimmar",            short = "Orgrim" },
    { id = 81,   label = "Thunder Bluff",        short = "ThBluf" },
    { id = 68,   label = "Undercity",            short = "UndCty" },
    { id = 530,  label = "Darkspear Trolls",     short = "Dkspr"  },
    { id = 2778, label = "Windshapers",          short = "Windsh" },

    -- Azeroth
    { id = 529,  label = "Argent Dawn",          short = "ArgDwn" },
    { id = 609,  label = "Cenarion Circle",      short = "CenCir" },
    { id = 59,   label = "Thorium Brotherhood",  short = "Thorim" },
    { id = 576,  label = "Timbermaw Hold",       short = "Timbmw" },
    { id = 749,  label = "Hydraxian Waterlords", short = "Hydrax" },
    { id = 270,  label = "Zandalar Tribe",       short = "Zandlr" },
    { id = 910,  label = "Brood of Nozdormu",    short = "Nozdor" },
    { id = 589,  label = "Wintersaber Trainers", short = "Wntsbr" },
    { id = 21,   label = "Booty Bay",            short = "BtyBay" },
    { id = 369,  label = "Gadgetzan",            short = "Gadgtz" },
    { id = 470,  label = "Ratchet",              short = "Ratcht" },
    { id = 577,  label = "Everlook",             short = "Evrlk"  },
    { id = 87,   label = "Bloodsail Buccaneers", short = "Bldsl"  },
    { id = 349,  label = "Ravenholdt",           short = "Ravnhd" },
    { id = 809,  label = "Shen'dralar",          short = "Shndrl" },
    { id = 909,  label = "Darkmoon Faire",       short = "Dkmoon" },
    { id = 92,   label = "Gelkis Clan Centaur",  short = "Gelkis" },
    { id = 93,   label = "Magram Clan Centaur",  short = "Magram" },

    -- Battlegrounds (and Forever's Darkspear Islands pair)
    { id = 730,  label = "Stormpike Guard",      short = "Stmpke" },
    { id = 729,  label = "Frostwolf Clan",       short = "Frstwf" },
    { id = 890,  label = "Silverwing Sentinels", short = "Slvwng" },
    { id = 889,  label = "Warsong Outriders",    short = "Warsng" },
    { id = 509,  label = "League of Arathor",    short = "LgArth" },
    { id = 510,  label = "The Defilers",         short = "Defilr" },
    { id = 2799, label = "Theramore Expeditionary Force", short = "Thrmor" },
    { id = 2798, label = "Darkspear Raiders",    short = "DkRaid" },

    -- Forever
    { id = 2719, label = "Cenarion Scouts",      short = "CenSct" },
    { id = 2740, label = "Kirin Tor",            short = "KirTor" },
    { id = 2747, label = "Barkskin Burrow",      short = "Barksk" },
    { id = 2758, label = "Nightclaw Druids",     short = "Nghtcl" },
    { id = 2765, label = "Guardians of Hyjal",   short = "GdHyjl" },
    { id = 2782, label = "Bolder'ok Clan",       short = "Bldrok" },
    { id = 2787, label = "Earthen Ring",         short = "ErthRg" },
    { id = 2819, label = "The Watchers",         short = "Watchr" },
    { id = 2826, label = "Brotherhood of the Horse", short = "BroHrs" },
    { id = 2827, label = "Powderfuse",           short = "Pwdrfs" },
    { id = 2586, label = "Azeroth Commerce Authority", short = "AzCmAu" },
    { id = 2587, label = "Durotar Supply and Logistics", short = "DuSupL" },
}

function AltStable.RepField(id)
    return "rep_" .. id
end

-- The rep fields at least one character holds, in table order. The sheet shows
-- only these: a fresh alt has met four or five factions, not forty-eight, and a
-- column no character has would only ever be blank.
function AltStable.RepFieldsInUse(db)
    local used = {}
    for _, c in pairs(db or {}) do
        if type(c) == "table" then
            for k in pairs(c) do
                if type(k) == "string" and k:find("^rep_%d+$") then used[k] = true end
            end
        end
    end
    local out = {}
    for _, r in ipairs(AltStable.REPUTATIONS) do
        local f = AltStable.RepField(r.id)
        if used[f] then out[#out + 1] = f end
    end
    return out
end

------------------------------------------------------------
-- Scan
--
-- "Met" means present in the character's reputation list. GetFactionDataByID
-- cannot answer that: it returns factions the character has never seen, at a
-- starting standing - a fresh Alliance character reads Kirin Tor and Darkspear
-- Raiders as Hated - while its list holds only the Alliance header and the four
-- capitals.
--
-- The list hides the children of collapsed headers, so the scan expands them
-- all and afterwards re-collapses the ones that were collapsed, walking back to
-- front so earlier indices stay valid. A header nested inside a collapsed
-- header isn't visible to record and comes back expanded; that only changes how
-- the player's reputation window looks.
--
-- Nothing on the character changes unless the list read succeeds: an empty
-- list (not loaded yet) would otherwise erase every standing.
------------------------------------------------------------

local tracked
local function TrackedIDs()
    if not tracked then
        tracked = {}
        for _, r in ipairs(AltStable.REPUTATIONS) do tracked[r.id] = true end
    end
    return tracked
end

-- Plain grouping headers have factionID 0 (measured: "Other"), and 0 is truthy
-- in Lua - so headers are remembered by name when they have no ID.
local function HeaderKey(d)
    return (d.factionID and d.factionID ~= 0) and d.factionID or d.name
end

local function ReadReputationList()
    local collapsed = {}
    for i = 1, GetNumFactions() do
        local d = GetFactionDataByIndex(i)
        if d and d.isHeader and d.isCollapsed then
            collapsed[HeaderKey(d)] = true
        end
    end
    if next(collapsed) then API.ExpandAllFactionHeaders() end

    local met, rows = {}, GetNumFactions()
    for i = 1, rows do
        local d = GetFactionDataByIndex(i)
        -- A header carries a standing only when it is a faction in its own
        -- right (isHeaderWithRep); a plain grouping header is not one.
        if d and (d.factionID or 0) > 0 and (not d.isHeader or d.isHeaderWithRep) then
            met[d.factionID] = d.reaction
        end
    end

    if next(collapsed) then
        for i = GetNumFactions(), 1, -1 do
            local d = GetFactionDataByIndex(i)
            if d and d.isHeader and collapsed[HeaderKey(d)] then
                API.CollapseFactionHeader(i)
            end
        end
    end
    return met, rows
end

function AltStable.ScanReputations(char)
    local met, rows = ReadReputationList()
    if rows == 0 then return end

    for k in pairs(char) do
        if type(k) == "string" and k:find("^rep_") then char[k] = nil end
    end
    local ids = TrackedIDs()
    for id, reaction in pairs(met) do
        if ids[id] and type(reaction) == "number" then
            char[AltStable.RepField(id)] = reaction
        end
    end
end
