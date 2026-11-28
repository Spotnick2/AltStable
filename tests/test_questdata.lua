-- tests/test_questdata.lua - the Loremaster plugin's quest table (#374)
--
-- Plugins/Loremaster/QuestData.lua is generated from QuestieDB by
-- Tools/QuestData/gen-quests.lua. What has to hold, whatever QuestieDB changes:
--   * every counted quest points at a row that exists; reference-only rows point nowhere;
--   * masks are whole numbers in range (race bits 32/33 are Forever's new races);
--   * the rules of the plan, on quests that show them: the zone of a subzone and of an
--     instance alias, the Class row, a missed level window, signed pre-quests, breadcrumbs,
--     exclusive links kept per quest, repeatables left out.

dofile("tests/wow_stubs.lua")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. name .. (detail and ("  -- " .. detail) or "")) end
end
local function eq(name, got, want)
    check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

AltStable = {}
dofile("Plugins/Loremaster/QuestData.lua")
local D = AltStable.LoremasterData
check("the table is published on AltStable", D ~= nil and D.ZONES ~= nil and D.QUESTS ~= nil)

-- Field positions, as the header documents them.
local KEY, HKEY, REQ, RACES, CLASSES, FLAGS, NAME, MAXLVL, EXCL, PRESINGLE, PREGROUP, BREAD, NEXT, PARENT, UNTIL, HORDE =
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16

------------------------------------------------------------
-- Invariants
------------------------------------------------------------
local GROUPS = { zone = true, dungeon = true, raid = true, battleground = true, class = true,
                 profession = true, other = true }
local CONTINENTS = { EK = true, KAL = true, FOREVER = true }
local badRow, badGroup, badContinent, orders = 0, 0, 0, {}
for key, z in pairs(D.ZONES) do
    if type(key) ~= "number" or type(z[4]) ~= "string" or type(z[5]) ~= "number" then badRow = badRow + 1 end
    if not GROUPS[z[1]] then badGroup = badGroup + 1 end
    if (z[1] == "zone") ~= (z[2] ~= nil) or (z[2] and not CONTINENTS[z[2]]) then badContinent = badContinent + 1 end
    orders[#orders + 1] = z[5]
end
eq("every row has a number key, a name and an order", badRow, 0)
eq("every row is in a known group", badGroup, 0)
eq("zones, and only zones, have a continent", badContinent, 0)
table.sort(orders)
local orderOk = true
for i, o in ipairs(orders) do if o ~= i then orderOk = false end end
check("the row orders are 1..n", orderOk)

local counted, refOnly, dangling, badMask, badFlag, wide, hordeRows, badHorde = 0, 0, 0, 0, 0, 0, 0, 0
for id, q in pairs(D.QUESTS) do
    local isRef = q[FLAGS] % 4 >= 2
    if isRef then
        refOnly = refOnly + 1
        if q[KEY] ~= nil then dangling = dangling + 1 end
    else
        counted = counted + 1
        if not D.ZONES[q[KEY]] then dangling = dangling + 1 end
        if q[HKEY] ~= nil and not D.ZONES[q[HKEY]] then dangling = dangling + 1 end
    end
    if q[RACES] < 0 or q[RACES] >= 2 ^ 40 or q[RACES] % 1 ~= 0 or q[CLASSES] < 0 or q[CLASSES] >= 2 ^ 16 then
        badMask = badMask + 1
    end
    if q[RACES] >= 2 ^ 32 then wide = wide + 1 end
    if q[FLAGS] < 0 or q[FLAGS] > 3 then badFlag = badFlag + 1 end
    -- Horde links: fields 9-15 again, numbers where those are numbers.
    local h = q[HORDE]
    if h ~= nil then
        hordeRows = hordeRows + 1
        for i = 4, 7 do if type(h[i]) ~= "number" then badHorde = badHorde + 1 end end
    end
end
eq("Horde links have the shape of fields 9-15", badHorde, 0)
check("  some quests carry them", hordeRows > 0)
check("thousands of quests counted", counted > 4000, tostring(counted))
check("some reference-only rows", refOnly > 0)
eq("every counted quest points at a row, reference-only ones at none", dangling, 0)
eq("masks are whole and in range", badMask, 0)
check("  race masks wider than 32 bits are kept (Forever's new races)", wide > 0)
eq("flags are 0-3", badFlag, 0)
-- Race bits are QuestieDB's, not 2^(raceID-1): Forever's Skyborne are bits 32 and 33, and the
-- probe measured race 95 on an Alliance character (forever-api-notes.md).
eq("race 1 is bit 0", D.RACE_MASK and D.RACE_MASK[1], 1)
eq("race 95 (High Order Skyborne) is bit 32", D.RACE_MASK and D.RACE_MASK[95], 2 ^ 32)
eq("race 96 (Windshaper Skyborne) is bit 33", D.RACE_MASK and D.RACE_MASK[96], 2 ^ 33)
check("  95 is in the Alliance mask", D.FACTION_MASK and math.floor(D.FACTION_MASK.Alliance / 2 ^ 32) % 2 == 1)
check("  96 is in the Horde mask", D.FACTION_MASK and math.floor(D.FACTION_MASK.Horde / 2 ^ 33) % 2 == 1)
-- The version snapshots were counted against. Characters' quest lists show only
-- for a snapshot of this version, so a change hides every local alt's lists
-- until it logs in again (Codex on #399). If this fails because the COUNTING
-- data changed (quests, masks, rows), update the pin. If only a display field
-- changed (pinMap and the like), the generator must leave the version alone.
-- 9f8a2191: QuestieDB 1.1.6 and Questie's lists of 2026-11-27 (#552); cabf3cd3 was
-- QuestieDB 1.1.3 and Questie 12.11.1 (#472), 9b0a9380 1.1.1.
eq("the version is the one the counted snapshots carry", D.VERSION, "9f8a2191")
check("the version is the body's hash", type(D.VERSION) == "string" and #D.VERSION == 8)
check("the source is recorded", D.SOURCE and D.SOURCE.questiedb and D.SOURCE.commit and D.SOURCE.build)

-- The map panel's entrance: map and point from one entrance record. Naxxramas's
-- parent area (65) has no map; its entrance is in Eastern Plaguelands (Codex on #400).
local naxx = D.ZONES[3456]
eq("Naxxramas pins its entrance zone, Eastern Plaguelands", naxx and naxx[6], 1423)
check("  at the entrance", naxx and naxx[7] == 34.25 and naxx[8] == 19.45)

------------------------------------------------------------
-- The plan's rules, on quests that show them
------------------------------------------------------------
local Q = D.QUESTS
-- A Northshire quest (subzone 9) counts in Elwynn Forest (12).
eq("Kobold Camp Cleanup is an Elwynn Forest quest", Q[7] and Q[7][KEY], 12)
eq("  Elwynn Forest is an Eastern Kingdoms zone", D.ZONES[12] and D.ZONES[12][2], "EK")
-- Zul'Farrak's quests (area 978 in QuestieDB) count in the instance (1176), not Tanaris.
eq("Divino-matic Rod is a Zul'Farrak quest", Q[2768] and Q[2768][KEY], 1176)
eq("  Zul'Farrak is a dungeon", D.ZONES[1176] and D.ZONES[1176][1], "dungeon")
-- Bit 2 of specialFlags is not an event: The Forgotten Pools counts (Codex r2).
eq("The Forgotten Pools counts in the Barrens", Q[870] and Q[870][KEY], 17)
-- Single-class quests go to the Class row, wherever QuestieDB files them (Codex r6).
eq("Call of Earth (Skyborne shaman, Zephras Isle) is in the Class row", Q[92466] and Q[92466][KEY], D.CLASS_KEY)
eq("Devourer of Souls (warlock sort) is in the Class row", Q[1472] and Q[1472][KEY], D.CLASS_KEY)
eq("  the Class row is a class group", D.ZONES[D.CLASS_KEY] and D.ZONES[D.CLASS_KEY][1], "class")
-- Exclusive links are kept per quest, not grouped (Codex r2).
check("the Ashenvale Hunt copies each keep their own row",
      Q[235] and Q[742] and Q[6382] and Q[235][KEY] ~= Q[742][KEY] and Q[742][KEY] ~= Q[6382][KEY])
check("  and their exclusive partners", Q[235] and Q[235][EXCL] and #Q[235][EXCL] == 2)
-- Missed windows: the override's level cap, and the data's own.
eq("Darkspear Islands Clash 30-39 is capped at 39 (override)", Q[98895] and Q[98895][MAXLVL], 39)
-- Darkspear Islands is a PvP instance: its quests are Battlegrounds quests (Codex on #394).
eq("  and counts in Battlegrounds", Q[98895] and Q[98895][KEY], -25)
check("  Darkspear Islands has no zone row", D.ZONES[16606] == nil)
-- Faction-dependent links (Codex on #394): In Search of Thaelrid leads to 1200 for the
-- Alliance only.
eq("In Search of Thaelrid: Alliance breadcrumb 1200", Q[1198] and Q[1198][BREAD], 1200)
eq("  Alliance follow-up 1200", Q[1198] and Q[1198][NEXT], 1200)
check("  Horde has its own links", Q[1198] and type(Q[1198][HORDE]) == "table")
eq("  Horde: no breadcrumb", Q[1198] and Q[1198][HORDE] and Q[1198][HORDE][4], 0)
eq("  Horde: no follow-up", Q[1198] and Q[1198][HORDE] and Q[1198][HORDE][5], 0)
check("a quest whose links match carries no Horde copy", Q[7] and Q[7][HORDE] == nil)
eq("The Battle for Arathi Basin! caps at 29", Q[8168] and Q[8168][MAXLVL], 29)
-- Signed pre-quests stay signed.
local signed = false
for _, v in ipairs(Q[4964] and Q[4964][PREGROUP] or {}) do if v == -4962 then signed = true end end
check("a negative pre-quest stays negative (4964 needs exactly 4962)", signed)
-- Breadcrumbs and parents.
eq("Regthar Deathgate is a breadcrumb for 1362", Q[1361] and Q[1361][BREAD], 1362)
eq("An Easy Pickup's parent is Arcane Runes", Q[3450] and Q[3450][PARENT], 3449)
-- Left out: repeatables.
for _, id in ipairs({ 16, 117, 254 }) do
    check("repeatable quest " .. id .. " is not in the table", Q[id] == nil)
end
-- Reference-only rows exist for what the rules look at.
check("The Captain's Chest is reference-only (an exclusive partner, blacklisted itself)",
      Q[614] and Q[614][FLAGS] % 4 >= 2 and Q[614][KEY] == nil)

WoW.finish("test_questdata", passed, failed)
