-- Tools/QuestData/gen-quests.lua - build Plugins/Loremaster/QuestData.lua from QuestieDB (#374)
--
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Never ships. Run from the repo root with Lua 5.1:
--   lua Tools/QuestData/gen-quests.lua            write the file, print the report
--   lua Tools/QuestData/gen-quests.lua --check    fail if the file would change
--
-- Inputs, read in place (nothing copied into this repo):
--   * QuestieDB, Forever edition: References/Addons/QuestsLeveling/QuestieDB (its own reader,
--     through questiedb-loader.lua), once per faction and class, since its Dynamic
--     Corrections branch on them;
--   * Questie: its quest blacklist and holiday quest lists;
--   * wago.tools tables in References/Forever/db: AreaTable (English zone names) and UiMap
--     (continent of each zone map);
--   * overrides.lua, the hand-kept fixes.
-- The rules are the approved plan's (#374): see the header the output gets.

local REFS = "C:/Projects/WoW/References"
local QDB = REFS .. "/Addons/QuestsLeveling/QuestieDB/QuestieDB"
local QUESTIE = REFS .. "/Addons/QuestsLeveling/Questie/Questie"
local DBDIR = REFS .. "/Forever/db"
local AREATABLE = DBDIR .. "/forever-areatable-1.60.1.70790.csv"
local UIMAP = DBDIR .. "/forever-uimap-1.60.1.70790.csv"
local FOREVER_BUILD = "1.60.1.70959"
local OUT = "Plugins/Loremaster/QuestData.lua"

local CHECK = false
for _, a in ipairs(arg or {}) do if a == "--check" then CHECK = true end end

local Loader = dofile("Tools/QuestData/questiedb-loader.lua")
local OVR = dofile("Tools/QuestData/overrides.lua")

local floor = math.floor
local function HasBit(mask, bitValue) return floor(mask / bitValue) % 2 == 1 end

----------------------------------------------------------------------------
-- Groups, sorts, classes
----------------------------------------------------------------------------

-- QuestSort IDs (negative zoneOrSort) by what they become.
local CLASS_SORTS = { [-61] = true, [-81] = true, [-82] = true, [-141] = true, [-161] = true,
                      [-162] = true, [-261] = true, [-262] = true, [-263] = true }
local PROFESSION_SORTS = { [-24] = true, [-101] = true, [-121] = true, [-181] = true, [-182] = true,
                           [-201] = true, [-264] = true, [-304] = true, [-324] = true }
-- Holidays and one-time world events: never counted.
local EXCLUDED_SORTS = { [-21] = true, [-22] = true, [-41] = true, [-364] = true, [-365] = true,
                         [-366] = true, [-368] = true, [-369] = true, [-370] = true, [-374] = true,
                         [-375] = true, [-376] = true, [-378] = true, [-402] = true, [-404] = true,
                         [-641] = true, [-644] = true }
local BG_SORT = -25
local CLASS_KEY = -9999          -- the one Class quests row
local OTHER_ZONE = 0             -- zoneOrSort 0

-- Forever's classes (file, ID); the class mask bit is 2^(ID-1).
local CLASSES = { { "WARRIOR", 1 }, { "PALADIN", 2 }, { "HUNTER", 3 }, { "ROGUE", 4 }, { "PRIEST", 5 },
                  { "SHAMAN", 7 }, { "MAGE", 8 }, { "WARLOCK", 9 }, { "DRUID", 11 } }
local SINGLE_CLASS = {}
for _, c in ipairs(CLASSES) do SINGLE_CLASS[2 ^ (c[2] - 1)] = c[1] end

----------------------------------------------------------------------------
-- CSV (wago.tools exports: quoted fields may hold commas)
----------------------------------------------------------------------------

local function CsvLine(line)
    local out, i, n = {}, 1, #line
    while i <= n + 1 do
        if line:sub(i, i) == '"' then
            local j, buf = i + 1, {}
            while j <= n do
                local ch = line:sub(j, j)
                if ch == '"' then
                    if line:sub(j + 1, j + 1) == '"' then buf[#buf + 1] = '"'; j = j + 2
                    else j = j + 1; break end
                else buf[#buf + 1] = ch; j = j + 1 end
            end
            out[#out + 1] = table.concat(buf)
            i = j + 1
        else
            local j = line:find(",", i, true) or (n + 1)
            out[#out + 1] = line:sub(i, j - 1)
            i = j + 1
        end
    end
    return out
end

local function ReadCsv(path)
    local f = assert(io.open(path, "rb"), "missing " .. path)
    local header, rows = nil, {}
    for line in f:read("*a"):gmatch("[^\r\n]+") do
        local cells = CsvLine(line)
        if not header then
            header = {}
            for i, h in ipairs(cells) do header[h] = i end
        else
            rows[#rows + 1] = cells
        end
    end
    f:close()
    return header, rows
end

local AREA_NAME, AREA_CONTINENT = {}, {}
do
    local h, rows = ReadCsv(AREATABLE)
    for _, r in ipairs(rows) do
        local id = tonumber(r[h.ID])
        AREA_NAME[id] = r[h.AreaName_lang]
        AREA_CONTINENT[id] = tonumber(r[h.ContinentID])
    end
end

local MAP_PARENT = {}
do
    local h, rows = ReadCsv(UIMAP)
    for _, r in ipairs(rows) do MAP_PARENT[tonumber(r[h.ID])] = tonumber(r[h.ParentUiMapID]) end
end

local function Continent(uiMapID)
    local m, guard = uiMapID, 0
    while m and m ~= 0 and guard < 10 do
        if m == 1415 then return "EK" end
        if m == 1414 then return "KAL" end
        m = MAP_PARENT[m]
        guard = guard + 1
    end
    return "FOREVER"
end

----------------------------------------------------------------------------
-- Questie: the blacklist and the holiday quests
----------------------------------------------------------------------------

local function LoadQuestieLists()
    local modules = {}
    QuestieLoader = {
        CreateModule = function(_, name) modules[name] = modules[name] or {}; return modules[name] end,
        ImportModule = function(_, name) modules[name] = modules[name] or {}; return modules[name] end,
    }
    Questie = { IsForever = true, IsSoD = false, IsTBC = false, IsSoM = false, IsMoP = false,
                IsAnniversaryEra = false, IsAnniversaryHardcore = false, IsTitanReforged = false,
                IsChinaRegion = false, IsEURegion = false, Debug = function() end, DEBUG_DEVELOP = 1 }
    local exp = QuestieLoader:CreateModule("Expansions")
    exp.Era, exp.Tbc, exp.Wotlk, exp.Cata, exp.MoP, exp.Current = 1, 2, 3, 4, 5, 1
    QuestieLoader:CreateModule("ContentPhases").activePhases = { TBC = 1, SoD = 1, Anniversary = 1, SoM = 1, MoP = 1 }
    local event = QuestieLoader:CreateModule("QuestieEvent")
    event.eventQuests = {}

    assert(loadfile(QUESTIE .. "/Database/Corrections/QuestieQuestBlacklist.lua"))()
    local list = modules.QuestieQuestBlacklist:Load()
    local blacklisted = {}
    for id, v in pairs(list) do if v == true then blacklisted[id] = true end end

    local holiday = {}
    local dir = QUESTIE .. "/Database/Corrections/Holidays/quests/"
    for _, name in ipairs({ "Brewfest", "ChildrensWeek", "DarkmoonFaire", "DayOfTheDead", "HallowsEnd",
                            "HarvestFestival", "LoveIsInTheAir", "LunarFestival", "Midsummer", "Noblegarden",
                            "PilgrimsBounty", "WinterVeil" }) do
        assert(loadfile(dir .. name .. ".lua"))()
    end
    for _, e in ipairs(event.eventQuests) do if e[2] then holiday[e[2]] = true end end
    QuestieLoader, Questie = nil, nil
    return blacklisted, holiday
end

----------------------------------------------------------------------------
-- QuestieDB: one read per faction and class
----------------------------------------------------------------------------

local FIELDS = { "name", "requiredLevel", "requiredRaces", "requiredClasses", "zoneOrSort", "specialFlags",
                 "preQuestSingle", "preQuestGroup", "exclusiveTo", "breadcrumbForQuestId", "nextQuestInChain",
                 "parentQuest", "requiredMaxLevel", "availableUntilCompleted", "startedBy" }

-- The fields a runtime rule follows; for a quest both factions take, a Horde read that
-- differs in any of them ships its own copy.
local LINKS = { "exclusiveTo", "preQuestSingle", "preQuestGroup", "breadcrumbForQuestId", "nextQuestInChain",
                "parentQuest", "availableUntilCompleted" }
local LINK_SET = {}
for _, f in ipairs(LINKS) do LINK_SET[f] = true end

local function Serialize(v)
    if type(v) ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. Serialize(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

local zoneTables, qdbVersion, qdbCommit, factionMasks, raceMasks

local function ReadProfile(faction, class)
    local ns = Loader.Load(QDB, "Libs/LibDeflate/LibDeflate.lua",
        { faction = faction, classFile = class[1], classID = class[2] })
    local Q = ns.Quest
    local ids = Q.GetAllIds()
    local out = {}
    for _, id in ipairs(ids) do
        local q = {}
        for _, f in ipairs(FIELDS) do q[f] = Q.Get(id, f) end
        out[id] = q
    end
    if not zoneTables then
        local Z = ns.Support.modules.ZoneDB
        local function decode(s) return assert(loadstring(s))() end
        local p = Z.private
        local sub = decode(p.subZoneToParentZone)
        for k, v in pairs(decode(p.subZoneToParentZoneOverride)) do sub[k] = v end
        local a2m = decode(p.areaIdToUiMapId)
        for k, v in pairs(decode(p.areaIdToUiMapIdOverride)) do a2m[k] = v end
        local alt = {}
        for dungeonId, d in pairs(p.dungeons) do
            for _, altId in ipairs(d[2] or {}) do alt[altId] = dungeonId end
        end
        zoneTables = { sub = sub, a2m = a2m, dungeons = p.dungeons, alt = alt }
        qdbVersion, qdbCommit = ns.tocMeta.Version, ns.tocMeta["X-BUILD-COMMIT"]
        factionMasks = { Alliance = ns.Enum.factionRaceMasks.Alliance, Horde = ns.Enum.factionRaceMasks.Horde }
        raceMasks = {}
        for raceID, mask in pairs(ns.Enum.raceMaskById) do raceMasks[raceID] = mask end
    end
    return out, ids
end

----------------------------------------------------------------------------
-- Zones: instance aliases first, then outdoor parents
----------------------------------------------------------------------------

local function Resolve(area)
    local Z = zoneTables
    local a, guard = area, 0
    while guard < 12 do
        guard = guard + 1
        if Z.alt[a] then return Z.alt[a], "instance" end
        if Z.dungeons[a] then return a, "instance" end
        local parent = Z.sub[a]
        if not parent or parent == a or parent == 0 then return a, "area" end
        a = parent
    end
    return a, "area"
end

----------------------------------------------------------------------------
-- The build
----------------------------------------------------------------------------

local report = {}
local function Report(fmt, ...) report[#report + 1] = fmt:format(...) end

local blacklisted, holiday = LoadQuestieLists()

-- Every profile's read.
local profiles, allIds = {}, nil
for _, faction in ipairs({ "Alliance", "Horde" }) do
    for _, class in ipairs(CLASSES) do
        local key = faction .. "/" .. class[1]
        local data, ids = ReadProfile(faction, class)
        profiles[key] = data
        allIds = allIds or ids
    end
end
local BASE = profiles["Alliance/WARRIOR"]

local function FactionOf(raceMask)
    if raceMask == 0 then return nil end
    local a = factionMasks.Alliance
    local h = factionMasks.Horde
    local inA, inH = true, true
    -- every set bit of the quest's mask must be in the faction's
    local m, bitValue = raceMask, 1
    while m > 0 do
        if m % 2 == 1 then
            if not HasBit(a, bitValue) then inA = false end
            if not HasBit(h, bitValue) then inH = false end
        end
        m = floor(m / 2)
        bitValue = bitValue * 2
    end
    if inA and not inH then return "Alliance" end
    if inH and not inA then return "Horde" end
    return nil
end

-- The profile whose view of quest id counts: its faction and its class, where it has one.
local function ViewOf(id)
    local b = BASE[id]
    local faction = FactionOf(b.requiredRaces or 0) or "Alliance"
    local class = SINGLE_CLASS[b.requiredClasses or 0] or "WARRIOR"
    return profiles[faction .. "/" .. class][id], faction, class
end

local function Ids(list)
    if type(list) ~= "table" then return nil end
    local out = {}
    for _, v in ipairs(list) do if tonumber(v) and v ~= 0 then out[#out + 1] = v end end
    table.sort(out)
    return #out > 0 and out or nil
end

local function HasStarter(startedBy)
    if type(startedBy) ~= "table" then return false end
    for i = 1, 3 do
        if type(startedBy[i]) == "table" and next(startedBy[i]) then return true end
    end
    return false
end

-- Pass 1: which quests count, and their row.
local quests, rows = {}, {}
local counts = { total = #allIds, repeatable = 0, holiday = 0, blacklisted = 0, override = 0 }
local unmapped = {}

local function RowFor(zoneOrSort, classMask)
    if SINGLE_CLASS[classMask or 0] then return CLASS_KEY, "class" end
    if zoneOrSort == nil or zoneOrSort == 0 then return OTHER_ZONE, "other" end
    if zoneOrSort < 0 then
        if CLASS_SORTS[zoneOrSort] then return CLASS_KEY, "class" end
        if PROFESSION_SORTS[zoneOrSort] then return zoneOrSort, "profession" end
        if zoneOrSort == BG_SORT then return BG_SORT, "battleground" end
        return zoneOrSort, "other"
    end
    if OVR.professionAreas[zoneOrSort] then return zoneOrSort, "profession" end
    local area, kind = Resolve(zoneOrSort)
    if OVR.battlegrounds[area] then return BG_SORT, "battleground" end
    if kind == "instance" and not OVR.asZone[area] then return area, OVR.raids[area] and "raid" or "dungeon" end
    return area, "zone"
end

for _, id in ipairs(allIds) do
    local q, faction, class = ViewOf(id)
    local excluded
    if (q.specialFlags or 0) % 2 == 1 then excluded = "repeatable"
    elseif holiday[id] then excluded = "holiday"
    elseif blacklisted[id] then excluded = "blacklisted"
    elseif OVR.exclude[id] then excluded = "override"
    elseif q.zoneOrSort and EXCLUDED_SORTS[q.zoneOrSort] then excluded = "holiday" end
    if excluded then
        counts[excluded] = counts[excluded] + 1
    else
        local key, group = RowFor(q.zoneOrSort, q.requiredClasses)
        -- Faction-dependent zone (a Dynamic Correction moved it for one faction).
        local hordeKey
        if not FactionOf(q.requiredRaces or 0) then
            local h = profiles["Horde/" .. class][id]
            if h.zoneOrSort ~= q.zoneOrSort then
                hordeKey = RowFor(h.zoneOrSort, h.requiredClasses)
                if hordeKey == key then hordeKey = nil end
            end
        end
        -- Faction-dependent links (Codex on #394: 1198's breadcrumb and follow-up are 1200 for
        -- Alliance, none for Horde): the Horde read's links ship as their own field.
        local horde
        if not FactionOf(q.requiredRaces or 0) then
            local h = profiles["Horde/" .. class][id]
            for _, f in ipairs(LINKS) do
                if Serialize(h[f]) ~= Serialize(q[f]) then horde = h end
            end
        end
        -- Differences between profiles in anything else are reported, not guessed at.
        for pkey, data in pairs(profiles) do
            local other = data[id]
            local sameFaction = pkey:sub(1, #faction) == faction
            for _, f in ipairs({ "requiredLevel", "requiredRaces", "requiredClasses", "exclusiveTo",
                                 "preQuestSingle", "preQuestGroup", "breadcrumbForQuestId", "parentQuest",
                                 "nextQuestInChain", "availableUntilCompleted" }) do
                local handled = (horde and LINK_SET[f] and not sameFaction) or OVR.knownDifferences[id] == f
                if not handled and Serialize(other[f]) ~= Serialize((not sameFaction and horde or q)[f]) then
                    Report("profile difference: quest %d field %s in %s (%s vs %s)", id, f, pkey,
                        Serialize(other[f]), Serialize(q[f]))
                end
            end
        end
        quests[id] = { q = q, key = key, hordeKey = hordeKey, group = group, horde = horde }
        rows[key] = rows[key] or { group = group, n = 0, area = q.zoneOrSort }
        rows[key].n = rows[key].n + 1
        if hordeKey then
            rows[hordeKey] = rows[hordeKey] or { group = group, n = 0 }
            rows[hordeKey].n = rows[hordeKey].n + 1
        end
    end
end

-- Pass 2: quests the closure and prerequisite rules point at, kept as reference-only rows
-- when they are not counted themselves.
local refs = {}
local function Ref(id)
    id = id and math.abs(id)
    if id and id ~= 0 and not quests[id] and BASE[id] then refs[id] = true end
end
for _, e in pairs(quests) do
    for _, q in ipairs({ e.q, e.horde or e.q }) do
        for _, x in ipairs(Ids(q.exclusiveTo) or {}) do Ref(x) end
        for _, x in ipairs(Ids(q.preQuestSingle) or {}) do Ref(x) end
        for _, x in ipairs(q.preQuestGroup or {}) do Ref(x) end
        Ref(q.breadcrumbForQuestId); Ref(q.nextQuestInChain); Ref(q.parentQuest); Ref(q.availableUntilCompleted)
    end
end

-- Row metadata.
local zoneRows = {}
for key, r in pairs(rows) do
    local name, uiMapID, continent
    if key == CLASS_KEY then name = "Class quests"
    elseif key == BG_SORT then name = "Battlegrounds"
    elseif key == OTHER_ZONE then name = "Other"
    elseif key < 0 then
        name = nil
    else
        uiMapID = zoneTables.a2m[key]
        if uiMapID == 0 then uiMapID = nil end
        name = OVR.names[key] or (zoneTables.dungeons[key] and zoneTables.dungeons[key][1]) or AREA_NAME[key]
        if r.group == "zone" then
            -- The zone map's continent; without a map, the area's own (0 EK, 1 Kalimdor).
            local c = AREA_CONTINENT[key]
            if type(OVR.asZone[key]) == "string" then continent = OVR.asZone[key]
            elseif uiMapID then continent = Continent(uiMapID)
            elseif c == 0 then continent = "EK"
            elseif c == 1 then continent = "KAL"
            else continent = "FOREVER" end
        end
        if not name then unmapped[#unmapped + 1] = key end
    end
    -- Where the map panel pins the row: its own zone map, or an instance's parent zone
    -- (QuestieDB's dungeon table holds the entrance zone).
    local pinMap = uiMapID
    local dungeon = key > 0 and zoneTables.dungeons[key]
    if (r.group == "dungeon" or r.group == "raid") and dungeon and dungeon[3] then
        local m = zoneTables.a2m[dungeon[3]]
        if m and m ~= 0 then pinMap = m end
    end
    zoneRows[key] = { group = r.group, continent = continent, uiMapID = uiMapID, name = name, n = r.n,
                      pinMap = pinMap }
end

-- Sort names for the negative keys (Professions, Other).
do
    local ns = Loader.Load(QDB, "Libs/LibDeflate/LibDeflate.lua",
        { faction = "Alliance", classFile = "WARRIOR", classID = 1 })
    local SORT_NAMES = {}
    for name, v in pairs(ns.Enum.sortKeys) do SORT_NAMES[v] = name end
    for key, r in pairs(zoneRows) do
        if not r.name and key < 0 then
            local raw = SORT_NAMES[key] or ("Sort " .. key)
            r.name = raw:lower():gsub("_", " "):gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end)
        end
    end
end

----------------------------------------------------------------------------
-- Output
----------------------------------------------------------------------------

local function List(t)
    if not t then return "nil" end
    local parts = {}
    for _, v in ipairs(t) do parts[#parts + 1] = tostring(v) end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Flags: 1 unsure (counts only once done), 2 reference-only (never counted).
local lines = {}
-- A quest's links, fields 9-15 (and the Horde ones, field 16): exclusiveTo, preSingle,
-- preGroup (signed), breadcrumbFor, next, parent, until.
local function Links(q)
    local preGroup = nil
    if type(q.preQuestGroup) == "table" then
        preGroup = {}
        for _, v in ipairs(q.preQuestGroup) do preGroup[#preGroup + 1] = v end
        if #preGroup == 0 then preGroup = nil end
    end
    return ("%s,%s,%s,%d,%d,%d,%d"):format(List(Ids(q.exclusiveTo)), List(Ids(q.preQuestSingle)), List(preGroup),
        q.breadcrumbForQuestId or 0, q.nextQuestInChain or 0, q.parentQuest or 0, q.availableUntilCompleted or 0)
end

local function Row(id, e, flags)
    local q = e and e.q or BASE[id]
    local maxLevel = OVR.maxLevel[id] or q.requiredMaxLevel or 0
    -- { key, hordeKey, reqLevel, races, classes, flags, name, maxLevel, exclusiveTo,
    --   preSingle, preGroup, breadcrumbFor, next, parent, until, hordeLinks? }
    lines[#lines + 1] = ("[%d]={%s,%s,%d,%.0f,%d,%d,%q,%d,%s%s},"):format(
        id, e and tostring(e.key) or "nil", e and e.hordeKey and tostring(e.hordeKey) or "nil",
        q.requiredLevel or 0, q.requiredRaces or 0, q.requiredClasses or 0, flags, q.name or "",
        maxLevel, Links(q), e and e.horde and (",{" .. Links(e.horde) .. "}") or "")
end

local ids = {}
for id in pairs(quests) do ids[#ids + 1] = id end
for id in pairs(refs) do ids[#ids + 1] = id end
table.sort(ids)
local unsure = 0
for _, id in ipairs(ids) do
    local e = quests[id]
    local flags = 0
    if e then
        -- Unsure: no known starter, or QuestieDB knows no zone for it (mostly Forever's new
        -- quests, without level or race either), or an area of quests nobody can be sure of.
        if not HasStarter(e.q.startedBy) or e.key == OTHER_ZONE or OVR.unsureAreas[e.q.zoneOrSort or 0] then
            flags = 1
            unsure = unsure + 1
        end
        Row(id, e, flags)
    else
        Row(id, nil, 2)
    end
end

local GROUP_ORDER = { zone = 1, dungeon = 2, raid = 3, battleground = 4, class = 5, profession = 6, other = 7 }
local CONT_ORDER = { EK = 1, KAL = 2, FOREVER = 3 }
local keys = {}
for k in pairs(zoneRows) do keys[#keys + 1] = k end
table.sort(keys, function(a, b)
    local x, y = zoneRows[a], zoneRows[b]
    if GROUP_ORDER[x.group] ~= GROUP_ORDER[y.group] then return GROUP_ORDER[x.group] < GROUP_ORDER[y.group] end
    local cx, cy = CONT_ORDER[x.continent or ""] or 9, CONT_ORDER[y.continent or ""] or 9
    if cx ~= cy then return cx < cy end
    if (x.name or "") ~= (y.name or "") then return (x.name or "") < (y.name or "") end
    return a < b
end)
local zoneLines = {}
for i, k in ipairs(keys) do
    local r = zoneRows[k]
    zoneLines[#zoneLines + 1] = ("[%d]={%q,%s,%s,%q,%d,%s},"):format(k, r.group,
        r.continent and ("%q"):format(r.continent) or "nil", r.uiMapID and tostring(r.uiMapID) or "nil",
        r.name or ("Area " .. k), i, r.pinMap and tostring(r.pinMap) or "nil")
end

local body = "D.ZONES={\n" .. table.concat(zoneLines, "\n") .. "\n}\nD.QUESTS={\n" .. table.concat(lines, "\n") .. "\n}\n"

-- A small, stable hash of the body (sync tells two tables apart by it).
local function Hash(s)
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + s:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return ("%08x"):format(b * 65536 + a)
end

local header = ([[
-- Plugins/Loremaster/QuestData.lua - GENERATED by Tools/QuestData/gen-quests.lua. Do not edit.
--
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Derived from QuestieDB %s (Forever edition, build commit %s), with Questie's quest blacklist and
-- holiday lists; zone names and continents from the WoW Forever client tables (wago.tools, %s).
-- QuestieDB and Questie are GPLv3 (see NOTICE.md); so is this file and the Loremaster plugin.
--
-- D.ZONES[key] = { group, continent, uiMapID, englishName, order, pinMap }
--   pinMap: the zone map the map panel pins this row on (an instance's entrance zone).
--   key: an area ID (zone, dungeon, raid), a QuestSort ID (< 0: professions, other), -25 the
--   Battlegrounds row, -9999 the Class quests row, 0 quests QuestieDB files nowhere.
-- D.QUESTS[questID] = { key, hordeKey, reqLevel, raceMask, classMask, flags, name, maxLevel,
--   exclusiveTo, preQuestSingle, preQuestGroup, breadcrumbFor, nextQuestInChain, parentQuest,
--   availableUntilCompleted, hordeLinks }
--   hordeLinks (only where the Horde read differs, for a quest both factions take): a table of
--   fields 9-15 as Horde sees them, which a Horde character uses instead.
--   flags: 1 unsure (no known starter: counts only once done), 2 reference-only (a quest the
--   rules look at, never counted). Masks: 0 = any. A race's bit is D.RACE_MASK[raceID] (NOT
--   2^(raceID-1): Forever's Skyborne, races 95 and 96, are bits 32 and 33); a class's bit is
--   2^(classID-1). D.FACTION_MASK is every race of a faction.
--   preQuestGroup entries are signed: a negative ID means exactly that quest is required.

local D = {}
AltStable.LoremasterData = D
D.SOURCE = { questiedb = %q, commit = %q, build = %q }
D.CLASS_KEY = -9999
]]):format(qdbVersion, qdbCommit, FOREVER_BUILD, qdbVersion, qdbCommit, FOREVER_BUILD)

-- QuestieDB's race bits and faction masks, as the masks above use them.
local raceIds = {}
for id in pairs(raceMasks) do raceIds[#raceIds + 1] = id end
table.sort(raceIds)
local raceParts = {}
for _, id in ipairs(raceIds) do raceParts[#raceParts + 1] = ("[%d]=%.0f"):format(id, raceMasks[id]) end
body = ("D.RACE_MASK={%s}\nD.FACTION_MASK={Alliance=%.0f,Horde=%.0f}\n"):format(table.concat(raceParts, ","),
    factionMasks.Alliance, factionMasks.Horde) .. body

local text = header .. ("D.VERSION = %q\n"):format(Hash(body)) .. body

-- The report.
Report("quests in QuestieDB: %d; counted %d (unsure %d), reference-only %d", counts.total,
    (function() local n = 0 for _ in pairs(quests) do n = n + 1 end return n end)(), unsure,
    (function() local n = 0 for _ in pairs(refs) do n = n + 1 end return n end)())
Report("excluded: repeatable %d, holiday/event %d, blacklisted %d, overrides %d", counts.repeatable,
    counts.holiday, counts.blacklisted, counts.override)
for _, k in ipairs(keys) do
    local r = zoneRows[k]
    Report("  %-12s %-8s %6d  %-32s %d quests", r.group, r.continent or "", k, r.name or "?", r.n)
end
for _, k in ipairs(unmapped) do Report("UNMAPPED area %d", k) end
Report("size: %d bytes, version %s", #text, Hash(body))

if CHECK then
    local f = io.open(OUT, "rb")
    local old = f and f:read("*a")
    if f then f:close() end
    -- A Windows checkout (core.autocrlf) has CRLF line ends; the content is what counts.
    if old then old = old:gsub("\r\n", "\n") end
    if old ~= text then
        io.stderr:write(OUT .. " is out of date: run lua Tools/QuestData/gen-quests.lua\n")
        os.exit(1)
    end
    print(OUT .. " is up to date")
else
    local f = assert(io.open(OUT, "wb"))
    f:write(text)
    f:close()
    print(table.concat(report, "\n"))
end
