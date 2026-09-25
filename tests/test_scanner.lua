------------------------------------------------------------
-- test_scanner.lua — the struct-returning API ports.
--
-- These are the two conversions that fail SILENTLY if they are wrong.
-- `C_SkillInfo.GetSkillLineInfo` and `C_Reputation.GetFactionDataByIndex` each
-- return one struct where the Classic globals returned a tuple, so
-- destructuring positionally records nothing at all — indistinguishable from a
-- character that genuinely has no professions and no faction standings.
--
-- So these assert that data ARRIVES, not merely that nothing threw.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_scanner.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. name .. (detail and ("  -- " .. detail) or "")) end
end
local function eq(name, got, want)
    check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

WoW.reset()
AltStable = AltStable or {}
dofile("Compat.lua")

-- Scanner.lua and Reputations.lua capture their aliases at load time, so
-- AltStable.API must exist before they are loaded.
dofile("Scanner.lua")
dofile("Reputations.lua")

------------------------------------------------------------
-- Skills: struct fields, headers skipped, dynamic maxRank
------------------------------------------------------------

WoW.skillLines = {
    { name = "Class Skills",  isHeader = true,  rank = 0,   maxRank = 0,   skillID = 7 },
    { name = "Discipline",    isHeader = false, rank = 1,   maxRank = 1,   skillID = 613 },
    { name = "Weapon Skills", isHeader = true,  rank = 0,   maxRank = 0,   skillID = 6 },
    { name = "Defense",       isHeader = false, rank = 8,   maxRank = 15,  skillID = 95 },
    { name = "Fishing",       isHeader = false, rank = 42,  maxRank = 150, skillID = 356 },
    { name = "Cooking",       isHeader = false, rank = 77,  maxRank = 150, skillID = 185 },
    { name = "First Aid",     isHeader = false, rank = 91,  maxRank = 150, skillID = 129 },
    { name = "Riding",        isHeader = false, rank = 75,  maxRank = 75,  skillID = 762 },
    { name = "Herbalism",     isHeader = false, rank = 47,  maxRank = 300, skillID = 182 },
    { name = "Alchemy",       isHeader = false, rank = 120, maxRank = 300, skillID = 171 },
}

local char = {}
AltStable.ScanSkills(char)

eq("fishing rank", char.fishing, 42)
eq("fishing max", char.fishingMax, 150)
eq("cooking rank", char.cooking, 77)
eq("first aid rank", char.firstAid, 91)
eq("riding rank", char.riding, 75)

eq("primary profession 1 name", char.prof1, "Herbalism")
eq("  its rank", char.prof1Skill, 47)
eq("  its max", char.prof1Max, 300)
eq("primary profession 2 name", char.prof2, "Alchemy")
eq("  its rank", char.prof2Skill, 120)

eq("flat prof_ field", char.prof_Herbalism, 47)
eq("flat profmax_ field", char.profmax_Alchemy, 300)

-- Headers carry rank 0 and would overwrite real values if not skipped.
eq("header rows are skipped", char.prof_ClassSkills, nil)
check("no field named for a header", char["prof_Class Skills"] == nil)

-- maxRank is dynamic for weapon/defense skills (5 x level), so it must be read
-- per line rather than assumed to be a cap.
eq("defense maxRank read per line, not assumed", char.prof_Defense, nil,
   "Defense is not a primary profession, so it must not create a prof_ field")

-- The regression this replaces: a positional read yields nil for every field,
-- so nothing is recorded and it looks like a character with no skills.
local char2 = {}
local realGet = C_SkillInfo.GetSkillLineInfo
C_SkillInfo.GetSkillLineInfo = function(i)
    -- Simulate the OLD tuple contract to prove the test would catch a revert.
    local s = WoW.skillLines[i]
    if not s then return end
    return s.name, s.isHeader, nil, s.rank, nil, nil, s.maxRank
end
-- Scanner captured the alias at load, so reload it against the tuple stub.
dofile("Compat.lua"); dofile("Scanner.lua")
AltStable.ScanSkills(char2)
check("a tuple-shaped API records nothing (proves the assertions bite)",
      char2.fishing == nil and char2.prof1 == nil,
      "fishing=" .. tostring(char2.fishing) .. " prof1=" .. tostring(char2.prof1))
C_SkillInfo.GetSkillLineInfo = realGet
dofile("Compat.lua"); dofile("Scanner.lua")

------------------------------------------------------------
-- Reputations (#8): keyed by faction ID, "met" = in the character's list
------------------------------------------------------------

-- The table: IDs unique, labels short enough to stack in a 64px header.
do
    local seen, dup, long = {}, nil, nil
    for _, r in ipairs(AltStable.REPUTATIONS or {}) do
        if seen[r.id] then dup = r.id end
        seen[r.id] = true
        if #r.short > 6 then long = r.label end
    end
    check("the reputation table is populated", #(AltStable.REPUTATIONS or {}) >= 40)
    check("faction IDs are unique", dup == nil, tostring(dup))
    check("every header label fits six characters", long == nil, tostring(long))
    check("all 16 Forever factions are tracked",
          seen[2719] and seen[2740] and seen[2747] and seen[2758] and seen[2765] and seen[2778]
          and seen[2779] and seen[2782] and seen[2787] and seen[2798] and seen[2799] and seen[2819]
          and seen[2826] and seen[2827] and seen[2586] and seen[2587])
end

-- Header icons: a faction's tabard icon is used only when the texture exists on
-- this client; otherwise the stacked text label stays.
do
    local byID = {}
    for _, r in ipairs(AltStable.REPUTATIONS) do byID[r.id] = r end
    eq("Earthen Ring has its tabard icon", byID[2787].icon, "inv_misc_tabard_earthenring")
    eq("a battleground faction has none (its tabard icon is the generic one)", byID[730].icon, nil)

    local dir = "Interface" .. string.char(92) .. "Icons" .. string.char(92)
    WoW.textures = { [dir .. "inv_misc_tabard_earthenring"] = true }
    dofile("Columns.lua")
    local colByField = {}
    for _, c in ipairs(AltStable.Columns) do colByField[c.field] = c end
    eq("an icon that exists is drawn", colByField.rep_2787.repIcon, dir .. "inv_misc_tabard_earthenring")
    eq("an icon the client lacks falls back to the text label", colByField.rep_72.repIcon, nil)
    eq("  which keeps its short label", colByField.rep_72.verticalLabel, "Stormw")
    eq("a faction with no icon keeps the text label", colByField.rep_730.repIcon, nil)

    eq("a text-label faction needs the tall header",
       AltStable.HeaderHeightFor({ colByField.rep_72, colByField.rep_2787 }, 32), 64)
    eq("all icons fit the normal header",
       AltStable.HeaderHeightFor({ colByField.rep_2787 }, 32), 32)
    eq("non-rep columns use the section's own height",
       AltStable.HeaderHeightFor({ { field = "level" } }, 28), 28)

    WoW.textures = nil   -- every path resolves
    dofile("Columns.lua")
    colByField = {}
    for _, c in ipairs(AltStable.Columns) do colByField[c.field] = c end
    eq("with the texture present, Stormwind gets its tabard", colByField.rep_72.repIcon,
       dir .. "inv_misc_tournaments_tabard_human")
end

-- Measured on Kaleid (Horde, level 14): a "Horde" header that is a faction in
-- its own right, an "Other" grouping header with factionID 0, and two Forever
-- factions under it.
local function kaleidList()
    return {
        { name = "Horde", factionID = 67, reaction = 5, isHeader = true, isHeaderWithRep = true },
        { name = "Darkspear Trolls", factionID = 530, reaction = 4, isHeader = false },
        { name = "Orgrimmar", factionID = 76, reaction = 4, isHeader = false },
        { name = "Thunder Bluff", factionID = 81, reaction = 5, isHeader = false },
        { name = "Other", factionID = 0, reaction = 2, isHeader = true },
        { name = "Nightclaw Druids", factionID = 2758, reaction = 5, isHeader = false },
        { name = "Windshapers", factionID = 2778, reaction = 5, isHeader = false },
        { name = "Unlisted Co", factionID = 999, reaction = 7, isHeader = false },
    }
end

WoW.reset()
WoW.factions = kaleidList()
-- GetFactionDataByID answers for factions never met, at a starting standing.
WoW.factionByID = { [2740] = { name = "Kirin Tor", factionID = 2740, reaction = 1 } }
local rep = {}
AltStable.ScanReputations(rep)
eq("a met faction records its reaction", rep.rep_76, 4)
eq("a Forever faction under a grouping header", rep.rep_2758, 5)
eq("an untracked faction is ignored", rep.rep_999, nil)
eq("a header that is not a faction records nothing", rep.rep_0, nil)
eq("a faction known only by ID (never met) is not recorded", rep.rep_2740, nil)

-- A collapsed header hides its factions from the list; the scan must still
-- see them, and leave the header collapsed as the player had it.
WoW.factions = kaleidList()
WoW.factions[5].isCollapsed = true
rep = {}
AltStable.ScanReputations(rep)
eq("a faction under a collapsed header is still recorded", rep.rep_2778, 5)
check("the collapsed header is collapsed again afterwards", WoW.factions[5].isCollapsed == true)
check("  and an expanded one stays expanded", not WoW.factions[1].isCollapsed)

-- A standing that disappears from the list is cleared, but an empty list (not
-- loaded yet) must not wipe everything.
rep = { rep_76 = 4, rep_530 = 8 }
WoW.factions = { kaleidList()[1], kaleidList()[3] }
AltStable.ScanReputations(rep)
eq("a faction no longer listed is cleared", rep.rep_530, nil)
eq("  one still listed is kept", rep.rep_76, 4)
WoW.factions = {}
AltStable.ScanReputations(rep)
eq("an empty list leaves the stored standings alone", rep.rep_76, 4)

-- A faction can also be a header with a standing of its own (the Retail list
-- nests some that way); that row is the faction, not a grouping.
WoW.factions = { { name = "Argent Dawn", factionID = 529, reaction = 6, isHeader = true,
                   isHeaderWithRep = true },
                 { name = "Group", factionID = 0, isHeader = true } }
rep = {}
AltStable.ScanReputations(rep)
eq("a tracked faction listed as a header-with-rep is recorded", rep.rep_529, 6)

-- Old TBC slug fields are not written any more.
WoW.factions = kaleidList()
rep = {}
AltStable.ScanReputations(rep)
check("no TBC slug fields are written", rep.aldor == nil and rep.thrallmar == nil)

-- A tuple-shaped API (the old GetFactionInfo) records no standing.
WoW.factions = { { name = "Orgrimmar", factionID = 76, reaction = 4, isHeader = false } }
local rep2 = {}
local realFac = C_Reputation.GetFactionDataByIndex
C_Reputation.GetFactionDataByIndex = function(i)
    local f = WoW.factions[i]
    if not f then return end
    return f.name, f.description, f.reaction   -- the OLD tuple
end
dofile("Compat.lua"); dofile("Reputations.lua")
AltStable.ScanReputations(rep2)
eq("a tuple-shaped API records no standing", rep2.rep_76, nil)
C_Reputation.GetFactionDataByIndex = realFac
dofile("Compat.lua"); dofile("Reputations.lua")

-- The sheet shows only factions some character has met, in table order.
local inUse = AltStable.RepFieldsInUse({
    a = { rep_2758 = 5, rep_76 = 4 },
    b = { rep_72 = 5, name = "x" },
    c = "not a record",
})
eq("factions in use: count", #inUse, 3)
eq("  in table order (Stormwind first)", inUse[1], "rep_72")
eq("  then Orgrimmar", inUse[2], "rep_76")
eq("  then the Forever faction", inUse[3], "rep_2758")
WoW.reset()

------------------------------------------------------------
-- Race icons must not be an allowlist
--
-- Forever added Skyborne, and the old RACE_ATLAS table returned "" for any
-- race it did not list - so a new race rendered no icon at all, silently.
------------------------------------------------------------

-- RowRenderer needs the palette from Theme.lua at load.
dofile("Theme.lua")
dofile("RowRenderer.lua")
local iconOf = AltStable._test and AltStable._test.RaceIconText

if iconOf then
    check("a Classic race renders", iconOf("Human", "Male"):find("raceicon%-human%-male") ~= nil,
          iconOf("Human", "Male"))
    check("Scourge maps to the undead atlas", iconOf("Scourge", "Female"):find("raceicon%-undead%-female") ~= nil,
          iconOf("Scourge", "Female"))
    check("Skyborne renders without being in any table",
          iconOf("Skyborne", "Female"):find("raceicon%-skyborne%-female") ~= nil,
          iconOf("Skyborne", "Female"))
    check("a race invented tomorrow still renders",
          iconOf("Furbolg", "Male"):find("raceicon%-furbolg%-male") ~= nil,
          iconOf("Furbolg", "Male"))
    eq("an empty race renders nothing", iconOf("", "Male"), "")
    eq("a nil race renders nothing", iconOf(nil, "Male"), "")
else
    check("RaceIconText is exposed for testing", false,
          "add it to the AltStable._test seam")
end

------------------------------------------------------------
-- A secret rested value must not be stored as zero
------------------------------------------------------------
-- The scan has no suspicious-zero guard (the live event path does), so a 0
-- written here overwrites a good snapshot and syncs that zero to the peer.
do
    WoW.reset()
    local realExh = GetXPExhaustion
    GetXPExhaustion = function() return WoW.secret(120) end
    WoW.xpMax = 400
    AltStableDB = { [UnitGUID("player")] = { guid = UnitGUID("player"), restPercent = 40,
                                             restXP = 160, restTimestamp = 111 } }
    pcall(AltStable.ScanCharacter)
    local c = AltStableDB[UnitGUID("player")]
    eq("an unreadable rested value leaves the stored %", c.restPercent, 40)
    eq("  and the stored amount", c.restXP, 160)
    eq("  and the snapshot time it extrapolates from", c.restTimestamp, 111)
    GetXPExhaustion = realExh
    WoW.reset()
end

------------------------------------------------------------
-- The scan stores the WHOLE name, surname included (#56)
--
-- Live symptom on 1.60.1.70009: the sheet listed "Kaleid" where every other
-- client, the whitelist and the sync sender all say "Kaleid Sumner", because
-- the surname arrives in UnitName's second return now and the scan read only
-- the first. The stub models the split, so this fails without the fix.
------------------------------------------------------------

do
    WoW.reset()
    AltStableDB = {}
    pcall(AltStable.ScanCharacter)
    local c = AltStableDB[UnitGUID("player")]
    eq("the scan keeps the surname", c and c.name, WoW.player.name)
    check("  which is more than the first name",
          c and c.name and c.name:find(" ") ~= nil, tostring(c and c.name))

    -- A character with no surname stores exactly its name.
    WoW.player.name = "Solo"
    AltStableDB = {}
    pcall(AltStable.ScanCharacter)
    c = AltStableDB[UnitGUID("player")]
    eq("a character without a surname is stored as-is", c and c.name, "Solo")
    WoW.reset()
end

------------------------------------------------------------
-- Secret unit stats must not abort the scan
--
-- Live error: "Scanner.lua:596: attempt to perform arithmetic on a secret
-- number value (execution tainted by 'AltStable')" - UnitAttackPower returned
-- secrets on a PvP realm, the sum threw, and ScanCharacter died half-way
-- through, leaving the character record incomplete.
------------------------------------------------------------

do
    WoW.reset()
    local realStat, realArmor, realAP = UnitStat, UnitArmor, UnitAttackPower
    local realHealth, realMoney = UnitHealthMax, GetMoney
    UnitStat = function() return WoW.secret(10), WoW.secret(10) end
    UnitArmor = function() return WoW.secret(1), WoW.secret(29) end
    UnitAttackPower = function() return WoW.secret(9), WoW.secret(0), WoW.secret(0) end
    UnitHealthMax = function() return WoW.secret(163) end
    GetMoney = function() return WoW.secret(67) end
    -- Spell power COMPARES the values, which throws on a secret just as the sum did.
    local realBonus = GetSpellBonusDamage
    GetSpellBonusDamage = function() return WoW.secret(12) end

    -- The scan runs until a stub gap stops it, as elsewhere in this file; what
    -- matters is that a SECRET value is no longer what stops it. The stub models
    -- secrets as coroutines (see wow_stubs.lua), so its errors say "thread"
    -- where the client says "secret number" - both count as this failure.
    AltStableDB = {}
    local ok, err = pcall(AltStable.ScanCharacter)
    local msg = tostring(err)
    check("no secret value aborts the scan",
          ok or not (msg:find("secret", 1, true) or msg:find("thread", 1, true)), msg)
    local c = AltStableDB[UnitGUID("player")]
    check("  and still writes the character", c ~= nil)
    if c then
        -- Every sanitized field, not a sample: a raw store doesn't throw, it
        -- just puts a value in the database that can never be read back.
        for _, field in ipairs({ "stat_str", "stat_agi", "stat_sta", "stat_int", "stat_spi",
                                 "stat_hp", "stat_armor", "stat_ap", "stat_sp", "money" }) do
            eq("  " .. field .. " is stored as nil, not a value nothing can read", c[field], nil)
        end
        -- The point of not aborting: the fields written AFTER the stats are
        -- reached. Defense comes after the attack-power sum that threw in game.
        check("  the scan reaches the fields that follow the stats",
              c.stat_defense ~= nil or c.prof1 ~= nil, tostring(c.stat_defense))
        check("  including the reputations, near the end of the scan",
              c.rep_76 ~= nil or c.rep_72 ~= nil or next(WoW.factions or {}) == nil)
    end

    UnitStat, UnitArmor, UnitAttackPower = realStat, realArmor, realAP
    UnitHealthMax, GetMoney, GetSpellBonusDamage = realHealth, realMoney, realBonus
    WoW.reset()
end

------------------------------------------------------------
-- Vanilla display (#7, #6)
--
-- Gear cells take the item's own quality colour: the old ramp coloured by
-- item level against TBC raid tiers, so every Vanilla epic rendered grey or
-- white. The average is shown plain and rounded. The level cap comes from
-- the client, not a TBC 70. restedArea arrives from sync as a STRING.
------------------------------------------------------------

local TT = AltStable._test
local gear, avg, rested = TT.FormatGearIlvl, TT.FormatItemLevel, TT.ComputeLiveRestedPercent
check("render helpers are exposed for testing", gear and avg and rested)
if gear and avg and rested then
    eq("a level-40 epic is purple, whatever its item level", gear(40, 4), "|cffa335ee40|r")
    eq("an uncommon is green", gear(66, 2), "|cff1eff0066|r")
    eq("a legendary stays orange", gear(80, 5), "|cffff800080|r")
    eq("an unknown quality falls back to white", gear(50, 99), "|cffffffff50|r")
    eq("an empty slot is a dim dash", gear(0, 4), "|cff444444--|r")
    eq("the average is rounded and uncoloured", avg(57.6), "58")
    eq("  and rounds down below the half", avg(57.4), "57")

    WoW.reset()
    local now = WoW.now
    local function alt(level, area)
        return { guid = "Player-Alt-1", level = level, restPercent = 0,
                 restTimestamp = now - 8 * 3600, restedArea = area }
    end
    -- 8h: 5% in a rested area, 1.25% (rounds to 1) in the open world.
    eq("a level-60 character is at the cap: no rested XP", (rested(alt(60, true))), 0)
    WoW.maxLevel = 70
    eq("  and the cap follows the client", (rested(alt(60, true))), 5)
    WoW.maxLevel = 60
    eq("rested area, as scanned (boolean)", (rested(alt(59, true))), 5)
    eq("rested area, as synced (string)", (rested(alt(59, "true"))), 5)
    eq("open world, as synced: the string \"false\" is not rested", (rested(alt(59, "false"))), 1)
    eq("open world, as scanned", (rested(alt(59, false))), 1)

    -- The current character reads the live API; UnitXPMax 0 must not divide.
    WoW.xpMax, WoW.restXP = 0, 100
    local live = rested({ guid = UnitGUID("player"), level = 59 })
    check("a zero UnitXPMax gives a finite rested %", live == live and live ~= math.huge, tostring(live))
    WoW.reset()
end


-- The footer's totals (gold, the unknown-money marker, the rounded average) are
-- covered by tests/test_sheetui.lua, which BUILDS the sheet and reads the text
-- it sets. Source greps for those were deleted: one of them could not see a
-- variable scoped to the wrong function, which errored on every sheet build.

-- #8: TBC leftovers removed. Source checks - SheetUI doesn't load under the
-- stubs, and these are absences. A missing file fails a check, not the run.
do
    local function src(f)
        local h = io.open(f, "r")
        if not h then check(f .. " is readable", false); return "" end
        local s = h:read("*a"); h:close(); return s
    end
    for _, f in ipairs({ "Scanner.lua", "Columns.lua", "SheetUI.lua", "Config.lua",
                         "Export.lua", "Toasts.lua", "RowRenderer.lua" }) do
        local s = src(f)
        check(f .. " no longer uses Jewelcrafting",
              not s:find('"Jewelcrafting"', 1, true) and not s:find("prof_Jewelcrafting", 1, true))
    end
    local export = src("Export.lua")
    check("Export keeps a blank column where Jewelcrafting was, so the sheet doesn't shift",
          export:find('"Engineering",%s*"",') ~= nil)
    check("the scanner captures no combat ratings",
          not src("Scanner.lua"):find("CombatRating", 1, true))
    check("the scanner no longer runs the dead talent-tab scan",
          not src("Scanner.lua"):find("GetTalentTabInfo(", 1, true))
    check("no BiS column", not src("Columns.lua"):find("bisCount", 1, true)
                           and not src("SheetUI.lua"):find("bisCount", 1, true))
    check("no BiS matching left in the renderer", not src("RowRenderer.lua"):find("[Bb]is[TNC]"))
    check("no Spec column", not src("Columns.lua"):find("specIcon", 1, true))
end

-- A row is built with one cell per column. The Reputations columns follow the
-- data, so when a faction is met the pool must hand out rows built for the new
-- columns: rendering an old row against them indexes a cell that doesn't exist.
do
    local colsA = { { label = "Orgrimmar", field = "rep_76", type = "rep", width = 22 },
                    { label = "Thunder Bluff", field = "rep_81", type = "rep", width = 22 } }
    local colsB = { colsA[1], colsA[2],
                    { label = "Timbermaw Hold", field = "rep_576", type = "rep", width = 22 } }
    local char = { guid = "Player-Rows-1", name = "Kaleid", rep_76 = 4, rep_81 = 5, rep_576 = 3 }
    local pools = {}

    local pool = AltStable.RowPoolFor(pools, "rep", colsA)
    local oldRow = AltStable.CreateRow(nil, 20, colsA)
    pool.rows[1] = oldRow
    check("a row renders against the columns it was built for",
          pcall(AltStable.RenderRow, oldRow, char, 1, colsA))
    check("  (the hazard: an old row rendered against more columns errors)",
          not pcall(AltStable.RenderRow, oldRow, char, 1, colsB))

    local hidden = false
    oldRow.Hide = function() hidden = true end
    eq("the same columns keep the pool's rows", #AltStable.RowPoolFor(pools, "rep", colsA).rows, 1)
    pool = AltStable.RowPoolFor(pools, "rep", colsB)
    eq("new columns: the pool drops the rows built for the old ones", #pool.rows, 0)
    check("  and hides them", hidden)
    local newRow = AltStable.CreateRow(nil, 20, colsB)
    pool.rows[1] = newRow
    local ok, err = pcall(AltStable.RenderRow, newRow, char, 1, colsB)
    check("  a fresh row renders the new faction", ok, tostring(err))
    check("another section's pool is untouched",
          AltStable.RowPoolFor(pools, "gear", colsA) ~= pool)
end

-- SheetUI doesn't load under the stubs: check that a data refresh rebuilds the
-- Reputations columns, so a faction met or synced while the tab is open shows,
-- and that rows come from the column-aware pool.
do
    local h = io.open("SheetUI.lua", "r")
    local sheet = h and h:read("*a") or ""
    if h then h:close() end
    local refreshBody = sheet:match("local function Refresh%(%)(.-)\nend")
    check("a sheet refresh rebuilds the data-driven Reputations columns",
          refreshBody ~= nil and refreshBody:find("RebuildDataDrivenColumns()", 1, true) ~= nil)
    check("an icon header keeps the sort tint when the cursor leaves",
          sheet:find("if sortColumn~=col.field then tex:SetVertexColor(1,1,1) end", 1, true) ~= nil)
    check("the sheet takes its rows from the column-aware pool",
          sheet:find("AltStable.RowPoolFor(rowPools, activeSection.id, scrollableCols)", 1, true) ~= nil)
end

-- Faction comes from the client, not from the race (#22). Forever's Skyborne is
-- ONE race key on both sides, so a race-to-faction table gets one of them wrong
-- - silently, in a file the user pastes into a spreadsheet.
do
    WoW.reset()
    WoW.faction = "Alliance"
    AltStableDB = {}
    pcall(AltStable.ScanCharacter)
    local c = AltStableDB[UnitGUID("player")]
    eq("the scan records the faction the client reports", c and c.faction, "Alliance")
    WoW.faction = "Horde"
    pcall(AltStable.ScanCharacter)
    eq("  and follows it on the other side", AltStableDB[UnitGUID("player")].faction, "Horde")
    WoW.reset()
end

-- Export: one column per tracked faction, all of them, in table order - the
-- layout can't depend on which factions anyone has met.
dofile("Export.lua")

do
    local row = AltStable._test.ExportRow
    local function firstCols(line)
        local out = {}
        for field in (line .. "	"):gmatch("([^	]*)	") do out[#out + 1] = field end
        return out
    end
    -- Column 5 is Faction (Name, Realm, Class, Race, Faction, ...).
    local horde = firstCols(row({ name = "A", realm = "R", class = "MAGE", race = "Skyborne",
                                  faction = "Horde", level = 60 }))
    local ally  = firstCols(row({ name = "B", realm = "R", class = "MAGE", race = "Skyborne",
                                  faction = "Alliance", level = 60 }))
    eq("a Horde Skyborne exports as H", horde[5], "H")
    eq("  and an Alliance one as A - the same race key", ally[5], "A")
    local old = firstCols(row({ name = "C", realm = "R", class = "WARRIOR", race = "Orc", level = 60 }))
    eq("a record with no faction falls back to the race guess", old[5], "H")
end
do
    local header, row = AltStable._test.ExportHeader, AltStable._test.ExportRow
    local function cols(line)
        local out = {}
        for c in (line .. "\t"):gmatch("([^\t]*)\t") do out[#out + 1] = c end
        return out
    end
    local h = cols(header())
    local nReps = #AltStable.REPUTATIONS
    eq("the last export column is the last tracked faction", h[#h], AltStable.REPUTATIONS[nReps].label)
    local orgCol
    for i, c in ipairs(h) do if c == "Orgrimmar" then orgCol = i end end
    check("Orgrimmar has an export column", orgCol ~= nil)
    local r = cols(row({ name = "Kaleid", realm = "Elegia", class = "MAGE", level = 14,
                         rep_76 = 4, rep_2778 = 5 }))
    eq("a row has a cell for every header column", #r, #h)
    eq("  and the standing lands in its faction's column", orgCol and r[orgCol], "N")
    check("no TBC reputation columns remain",
          not header():find("Aldor", 1, true) and not header():find("Thrallmar", 1, true))
end

-- The renderer reads the live rested values for the player's own row and
-- DIVIDES them: a secret there would throw while drawing, taking out the row.
do
    local realExh, realMax = GetXPExhaustion, UnitXPMax
    GetXPExhaustion = function() return WoW.secret(120) end
    UnitXPMax = function() return 400 end
    local me = { guid = UnitGUID("player"), level = 20, restPercent = 40,
                 restTimestamp = WoW.now, restedArea = false }
    local ok, pct = pcall(rested, me)
    check("a secret rested value does not throw while rendering", ok, tostring(pct))
    eq("  and the row falls back to the stored snapshot", ok and pct, 40)
    GetXPExhaustion, UnitXPMax = realExh, realMax
end

-- No TBC level cap left in the code: the cap is AltStable.API.LevelCap().
for _, f in ipairs({ "RowRenderer.lua", "Core.lua", "Scanner.lua", "Config.lua",
                     "Plugins/Warband/AltStableWarband.lua" }) do
    local src = io.open(f):read("*a")
    check(f .. " has no hard-coded level cap",
          not src:find("%f[%w_]lvl%s*[<>]=?%s*[1-9]") and not src:find("char%.level,%s*%d")
          and not src:find("[cC]ap%s*=%s*%d") and not src:find("Level%s*=%s*[1-9]%d"))
end

------------------------------------------------------------
-- Slash arguments: names contain a space now
------------------------------------------------------------

dofile("Core.lua")

local cmd, target = AltStable.ParseSlashArgs("sync Karuzo Elegia")
eq("two-word name: command parses", cmd, "sync")
eq("  and the whole name survives", target, "Karuzo Elegia")

cmd, target = AltStable.ParseSlashArgs("sync Karuzo")
eq("one-word name still works", cmd, "sync")
eq("  target", target, "Karuzo")

cmd, target = AltStable.ParseSlashArgs("sync")
eq("bare command", cmd, "sync")
eq("  no target", target, nil)

cmd, target = AltStable.ParseSlashArgs("")
eq("empty input yields empty command", cmd, "")
eq("  and no target", target, nil)

cmd, target = AltStable.ParseSlashArgs("  SYNC   Karuzo Elegia  ")
eq("command is lowercased", cmd, "sync")
eq("  surrounding space is trimmed", target, "Karuzo Elegia")

cmd, target = AltStable.ParseSlashArgs("whitelist Second Surname-RealmName")
eq("cross-realm target keeps its realm suffix", target, "Second Surname-RealmName")

-- The exact regression: the old pattern was anchored at both ends with a
-- single-token target, so three tokens matched neither it nor the fallback.
local function oldParse(args)
    local c, t = args:match("^(%S+)%s+(%S+)$")
    if not c then c = args:match("^(%S+)$") end
    return c and c:lower() or "", t
end
eq("the old pattern returned an empty command (silent no-op)",
   (oldParse("sync Karuzo Elegia")), "")

------------------------------------------------------------
-- /alts whitelist
--
-- "No whitelisted peers configured. Add some with /alts whitelist <name>."
-- pointed at a branch that did not exist: the command fell through to the
-- bare-/alts default and silently opened the sheet instead. These assert the
-- branch exists and mutates the list GetSyncTargets actually whispers.
------------------------------------------------------------

dofile("Config.lua")

AltStableConfig = { whitelist = {} }

local function Slash(args)
    SlashCmdList["ALTSTABLE"](args)
    return WoW.chatOut[#WoW.chatOut] or ""
end

local msg = Slash("whitelist Karuzo Elegia")
eq("whitelist add stores the two-word name", AltStableConfig.whitelist[1], "Karuzo Elegia")
check("  and says so", msg:find("Added", 1, true) ~= nil, msg)

msg = Slash("whitelist Karuzo Elegia")
eq("a duplicate does not grow the list", #AltStableConfig.whitelist, 1)
check("  and says it is already there", msg:find("already", 1, true) ~= nil, msg)

Slash("whitelist Second Surname-RealmName")
eq("a cross-realm peer keeps its realm suffix",
   AltStableConfig.whitelist[2], "Second Surname-RealmName")

msg = Slash("whitelist")
check("bare whitelist lists every peer",
      msg:find("Karuzo Elegia", 1, true) ~= nil
      and msg:find("Second Surname-RealmName", 1, true) ~= nil, msg)

msg = Slash("whitelist remove")
eq("a nameless remove does not add \"remove\" as a peer", #AltStableConfig.whitelist, 2)
check("  and prints usage", msg:find("Usage", 1, true) ~= nil, msg)

msg = Slash("whitelist remove Karuzo Elegia")
eq("remove drops the named entry", #AltStableConfig.whitelist, 1)
eq("  and leaves the other one", AltStableConfig.whitelist[1], "Second Surname-RealmName")

msg = Slash("whitelist remove Nobody Here")
check("removing an absent peer says so",
      msg:find("not on the whitelist", 1, true) ~= nil, msg)

Slash("whitelist remove Second Surname-RealmName")
msg = Slash("whitelist")
check("an empty whitelist points at the add form",
      msg:find("/alts whitelist <name>", 1, true) ~= nil, msg)

------------------------------------------------------------
-- Adapted APIs must be taken as file-locals
--
-- Compat.lua deliberately does not inject into _G, so a call site that kept
-- the bare global name throws only when that exact path runs - RowRenderer's
-- BiS comparison shipped that way and blew up on a tooltip hover, long after
-- the two obvious crashes were fixed. Scan the shipped files instead of
-- waiting for the hover.
--
-- Nil-guarded calls (`X and X(...)`) are exempt: they cannot throw, and the
-- LOD-plugin wrappers in Core.lua use that form deliberately.
------------------------------------------------------------

local function ReadFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- Line comments go first, so prose naming an API cannot trip the scan.
local function CodeLines(src)
    local out = {}
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line:match("^(.-)%-%-") or line
    end
    return out
end

local function BareCall(code, name)
    local init = 1
    while true do
        local a, b = code:find(name .. "%s*%(", init)
        if not a then return false end
        local prev = (a > 1) and code:sub(a - 1, a - 1) or " "
        if not prev:find("[%w_.:]") then return true end
        init = b + 1
    end
end

local compatSrc = ReadFile("Compat.lua")
check("Compat.lua is readable from the test cwd", compatSrc ~= nil)

local adapted = {}
for name in (compatSrc or ""):gmatch("API%.([%w_]+)%s*=") do
    if name ~= "missing" then adapted[#adapted + 1] = name end
end
check("the adapter exposes functions to scan for", #adapted > 5, tostring(#adapted))

local scanned = 0
for line in ((ReadFile("AltStable.toc") or "") .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
    local fname = line:match("^%s*(%S+%.lua)%s*$")
    if fname and not fname:find("Libs") and fname ~= "Compat.lua" then
        local src = ReadFile(fname)
        if not src then
            check(fname .. " (listed in the .toc) is readable", false)
        else
            scanned = scanned + 1
            local lines = CodeLines(src)
            local whole = table.concat(lines, "\n")
            for _, name in ipairs(adapted) do
                local offender
                for i, code in ipairs(lines) do
                    if BareCall(code, name)
                       and not code:find(name .. "%s+and%s+" .. name .. "%s*%(") then
                        offender = i
                        break
                    end
                end
                if offender then
                    local bound = whole:find("local%s+" .. name .. "%s*=")
                        or whole:find("local%s+function%s+" .. name .. "%s*%(")
                    check(fname .. " takes a file-local alias for " .. name,
                          bound ~= nil,
                          "line " .. offender .. " calls bare " .. name
                          .. "() - Compat.lua does not inject globals")
                end
            end
        end
    end
end
check("the .toc scan reached the shipped files", scanned >= 8, tostring(scanned))

------------------------------------------------------------
-- One write path for AltStableConfig
--
-- What is worth pinning is that every mutation converges on one seam. That
-- mattered doubly while nothing survived a restart (#23); now that it does,
-- the seam is what makes a write reach disk at all.
------------------------------------------------------------

local changed = {}
local realOnChanged = AltStable.OnConfigChanged
AltStable.OnConfigChanged = function(key) changed[#changed + 1] = key end

AltStableConfig = { whitelist = {} }
AltStable.SetConfigValue("toastsEnabled", false)
eq("SetConfigValue assigns", AltStableConfig.toastsEnabled, false)
eq("  and reports the key", changed[#changed], "toastsEnabled")

changed = {}
Slash("whitelist Hook Target")
eq("adding a peer reports through the same hook", changed[#changed], "whitelist")
changed = {}
Slash("whitelist remove Hook Target")
eq("  and so does removing one", changed[#changed], "whitelist")

AltStable.OnConfigChanged = realOnChanged

-- SheetUI.lua is not loadable under wow_stubs.lua, so no behavioural test can
-- reach its handlers - reverting the checkbox to a bare assignment passes
-- every test above. Scan the source for the wiring instead, the same way the
-- adapted globals are scanned.
local function SourceHas(path, needle)
    local src = ReadFile(path)
    if not src then return false end
    for _, line in ipairs(CodeLines(src)) do
        if line:find(needle, 1, true) then return true end
    end
    return false
end

check("the Options checkboxes write through SetConfigValue",
      SourceHas("SheetUI.lua", "AltStable.SetConfigValue(savedKey"),
      "MakeOptCheckRow must not assign AltStableConfig[savedKey] directly")
check("the Options account box writes through SetConfigValue",
      SourceHas("SheetUI.lua", 'SetConfigValue("accountNumber"'))
check("/alts account writes through SetConfigValue",
      SourceHas("Core.lua", 'SetConfigValue("accountNumber"'))

-- The whole seam, not a sample. Every file that ships is scanned for writes to
-- AltStableConfig; Config.lua is exempt because it owns the table. An
-- assignment must go through SetConfigValue, an in-place edit of a nested
-- table must be followed by OnConfigChanged within a few lines, and the only
-- exception is an idempotent `X = X or {}` initialiser. The first version of
-- this seam routed four writes and claimed to route all of them.
local function ConfigWriteViolations(path)
    local src = ReadFile(path)
    if not src then return { path .. " unreadable" } end
    local lines = CodeLines(src)
    local bad = {}
    -- Every assignment on the line, wherever it sits: the first version was
    -- anchored at line start, so `if x then AltStableConfig.theme = "dark" end`
    -- passed, and it skipped any line containing `==`, so
    -- `AltStableConfig.foo = (a == b)` passed too. `=[^=]` after the target
    -- rejects comparisons without discarding the rest of the line, and the
    -- target cannot contain `~ < >`, so `~=` `<=` `>=` never match.
    for i, code in ipairs(lines) do
        for lhs in code:gmatch("(AltStableConfig[%.%[][%w_%.%[%]\"']*)%s*=[^=]") do
            -- Initialisers are written `X = X or {}` throughout; anything else is
            -- a real write.
            if not code:find(lhs .. " = " .. lhs .. " or {}", 1, true) then
                local nested = lhs:find("^AltStableConfig%.[%w_]+[%.%[]")
                if nested then
                    local reported = false
                    for j = i, math.min(i + 3, #lines) do
                        if lines[j]:find("OnConfigChanged(", 1, true) then reported = true; break end
                    end
                    if not reported then bad[#bad + 1] = path .. ":" .. i .. "  " .. code end
                else
                    bad[#bad + 1] = path .. ":" .. i .. "  " .. code
                end
            end
        end
    end
    return bad
end

-- The lint must see writes it used to miss. Checked against synthetic lines
-- rather than by mutating a shipped file.
do
    local realRead = ReadFile
    local cases = {
        { src = 'if x then AltStableConfig.theme = "dark" end', want = 1,
          name = "an inline write mid-line" },
        { src = 'AltStableConfig.flag = (a == b)', want = 1,
          name = "a write whose value contains ==" },
        { src = 'if AltStableConfig.theme == "dark" then end', want = 0,
          name = "a comparison, which is not a write" },
        { src = 'if AltStableConfig.scale ~= 1 then end', want = 0,
          name = "a ~= comparison" },
        { src = 'AltStableConfig.plugins = AltStableConfig.plugins or {}', want = 0,
          name = "an idempotent initialiser" },
    }
    for _, c in ipairs(cases) do
        ReadFile = function() return c.src end
        local got = #ConfigWriteViolations("synthetic.lua")
        eq("the config lint flags " .. c.name, got, c.want)
    end
    ReadFile = realRead
end

for _, path in ipairs({ "Core.lua", "SheetUI.lua", "Theme.lua", "Toasts.lua",
                        "Scanner.lua", "Reputations.lua", "Columns.lua",
                        "RowRenderer.lua", "Export.lua",
                        "Plugins/Warband/AltStableWarband.lua" }) do
    local bad = ConfigWriteViolations(path)
    check(path .. " writes AltStableConfig only through the seam", #bad == 0,
          table.concat(bad, " | "))
end

------------------------------------------------------------
-- The write stamp
--
-- Since 1.60.1.70009 this file comes back, so the marker records when it was
-- last written and by which build - the first thing worth knowing when a store
-- looks stale. It never announces anything: the sheet being full of alts is
-- the user-visible proof that the load worked.
------------------------------------------------------------

AltStableConfig = {}
WoW.chatOut = {}
AltStable.CheckSavedVariablesLoad()
check("stamping says nothing in chat", #WoW.chatOut == 0, WoW.chatOut[1] or "")
check("  and leaves a stamp", type(AltStableConfig.svLoadCheck) == "table"
      and AltStableConfig.svLoadCheck.stamp ~= nil)
check("  naming the build that wrote it", AltStableConfig.svLoadCheck.build == "70009",
      tostring(AltStableConfig.svLoadCheck.build))

-- Identity, not type: svLoadCheck is already a table from the call above, so
-- "it is a table" passes whether or not the reload branch ran at all.
local beforeReload = AltStableConfig.svLoadCheck
WoW.chatOut = {}
AltStable.HandleEnteringWorld(false, true)
check("a /reload is a write, so it re-stamps",
      AltStableConfig.svLoadCheck ~= beforeReload)
check("  still silently", #WoW.chatOut == 0, WoW.chatOut[1] or "")

-- Zoning fires the same event with both flags false: ignore it entirely.
local markerBefore = AltStableConfig.svLoadCheck
WoW.chatOut = {}
AltStable.HandleEnteringWorld(false, false)
check("a zone change says nothing", #WoW.chatOut == 0, WoW.chatOut[1] or "")
check("  and does not rewrite the marker", AltStableConfig.svLoadCheck == markerBefore)

-- A real login re-stamps, and still says nothing. The #23 announcement lived
-- here until 1.60.1.70009 fixed the client; a green line at every login saying
-- the file loaded would now be noise beside a sheet full of alts.
WoW.chatOut = {}
AltStable.HandleEnteringWorld(true, false)
check("a real login re-stamps", AltStableConfig.svLoadCheck ~= markerBefore)
check("  and announces nothing", #WoW.chatOut == 0, WoW.chatOut[1] or "")

------------------------------------------------------------
-- Which build were the findings measured on?
--
-- A constant in the source: a human bumps it after re-measuring, which is the
-- point - a value the addon could compute would just agree with itself.
------------------------------------------------------------

WoW.chatOut = {}
AltStable.CheckClientBuild()
check("the measured build stays quiet", #WoW.chatOut == 0, WoW.chatOut[1] or "")

local realBuildInfo = GetBuildInfo
GetBuildInfo = function() return "1.60.2", "70001", "Oct 01 2026", 16001 end
WoW.chatOut = {}
AltStable.CheckClientBuild()
check("a different build is announced",
      #WoW.chatOut > 0 and WoW.chatOut[1]:find("70001", 1, true) ~= nil
      and WoW.chatOut[1]:find(AltStable.MEASURED_ON_BUILD, 1, true) ~= nil,
      WoW.chatOut[1] or "(nothing printed)")
check("  saying what to re-check and what to bump",
      #WoW.chatOut > 0 and WoW.chatOut[1]:find("/apidump", 1, true) ~= nil
      and WoW.chatOut[1]:find("MEASURED_ON_BUILD", 1, true) ~= nil,
      WoW.chatOut[1] or "")

-- It keeps saying so until someone re-measures and bumps the constant.
WoW.chatOut = {}
AltStable.CheckClientBuild()
check("  and keeps saying so on the next login", #WoW.chatOut > 0)

GetBuildInfo = function() return nil end
WoW.chatOut = {}
AltStable.CheckClientBuild()
check("an unreadable build is not treated as a new one", #WoW.chatOut == 0, WoW.chatOut[1] or "")
GetBuildInfo = realBuildInfo

------------------------------------------------------------
-- A scan marks the character as this client's own
--
-- scannedHere is what stops a peer's echo of our character from being merged
-- over our own scan (#20). The merge tests seed it by hand, so without this a
-- scanner that stopped setting it would leave ownership silently dead in game
-- while every merge test still passed. Only the marker is under test: it is set
-- as the scan starts, before the stat reads a later stub gap stops, so the
-- partial scan still proves it - and moving it to the end would fail here.
------------------------------------------------------------

AltStableDB = AltStableDB or {}
pcall(AltStable.ScanCharacter)
local scanned = AltStableDB[UnitGUID("player")]
check("scanning a character marks it as ours", scanned ~= nil and scanned.scannedHere == true)

-- UnitXPMax 0 (Retail's value at the cap; unmeasured on Forever). At the cap the
-- zero is real; below it the read is bad, and must not become a 1-XP level
-- (10000% rested) that displays, sorts and syncs.
local function scanXP(level, xpMax, prior)
    WoW.reset()
    WoW.level, WoW.xpMax, WoW.restXP, WoW.xp = level, xpMax, 100, 50
    AltStableDB = { [UnitGUID("player")] = prior }
    pcall(AltStable.ScanCharacter)
    return AltStableDB[UnitGUID("player")]
end
local c = scanXP(60, 0, nil)
eq("at the cap, a zero maximum scans as no rested XP", c and c.restPercent, 0)
eq("  and no XP progress", c and c.xpPercent, 0)
c = scanXP(59, 0, { guid = UnitGUID("player"), restPercent = 40, xpPercent = 25, xpMax = 400, restTimestamp = 123 })
eq("below the cap, a zero maximum keeps the last rested %", c and c.restPercent, 40)
eq("  and XP %", c and c.xpPercent, 25)
eq("  and the snapshot time it extrapolates from", c and c.restTimestamp, 123)
c = scanXP(59, 400, nil)
eq("a real maximum still scans: 100 of 400 rested", c and c.restPercent, 25)
eq("  and 50 of 400 through the level", c and c.xpPercent, 12)
WoW.reset()

-- auditMinLevel defaulted to TBC's 70: unreachable here. It follows the cap,
-- and a stored value above the cap is pulled down.
if AltStable.EnsureConfigDefaults then
    AltStableConfig = {}
    AltStable.EnsureConfigDefaults()
    eq("auditMinLevel defaults to the client cap", AltStableConfig.auditMinLevel, 60)
    AltStableConfig = { auditMinLevel = 70 }
    AltStable.EnsureConfigDefaults()
    eq("  a stored 70 comes down to it", AltStableConfig.auditMinLevel, 60)
    AltStableConfig = { auditMinLevel = 20 }
    AltStable.EnsureConfigDefaults()
    eq("  a lower choice is kept", AltStableConfig.auditMinLevel, 20)
else
    check("EnsureConfigDefaults is exposed", false)
end

------------------------------------------------------------

print(("test_scanner: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
