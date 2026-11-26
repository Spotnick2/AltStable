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
-- Nothing read: the fields hold the reset values (the list was there, so the
-- reset ran), and no profession field at all was written.
check("a tuple-shaped API records nothing (proves the assertions bite)",
      char2.fishing == 0 and char2.prof1 == "" and char2.prof_Alchemy == nil,
      "fishing=" .. tostring(char2.fishing) .. " prof1=" .. tostring(char2.prof1))
C_SkillInfo.GetSkillLineInfo = realGet
dofile("Compat.lua"); dofile("Scanner.lua")

------------------------------------------------------------
-- Skills by ID (#177): twin lines, other clients' names
------------------------------------------------------------
-- Measured on 1.60.1.70205 (owner, three characters): every profession is listed
-- TWICE under one name - its base line and a 29xx line - in either order, with
-- the same rank and max. By name, prof1 and prof2 were one profession and the
-- second was lost; on a French client nothing matched at all.
local function line(name, id, rank, max)
    return { name = name, isHeader = false, rank = rank, maxRank = max, skillID = id }
end
-- Headers carry a skillID on Forever too (Class Skills is 7, measured above).
local function header(name, id) return { name = name, isHeader = true, rank = 0, maxRank = 0, skillID = id } end

-- The first character, as measured.
WoW.skillLines = {
    header("Class Skills", 7), line("Discipline", 613, 1, 1),
    header("Professions", 11),
    line("Enchanting", 333, 3, 75), line("Enchanting", 2940, 3, 75),
    line("Tailoring", 2948, 32, 75), line("Tailoring", 197, 32, 75),
    header("Secondary Skills", 9),
    line("Cooking", 2939, 3, 75), line("Cooking", 185, 3, 75),
    line("First Aid", 129, 1, 75), line("First Aid", 2942, 1, 75),
    line("Fishing", 356, 1, 75), line("Fishing", 2943, 1, 75),
    header("Weapon Skills", 6), line("Defense", 95, 33, 45),
}
local twins = {}
AltStable.ScanSkills(twins)
eq("twin lines: the first profession", twins.prof1, "Enchanting")
eq("  and the SECOND is the other one, not its twin", twins.prof2, "Tailoring")
eq("  with its rank", twins.prof2Skill, 32)
eq("  both flat fields", tostring(twins.prof_Enchanting) .. "/" .. tostring(twins.prof_Tailoring), "3/32")
eq("  the secondaries", twins.cooking .. "/" .. twins.firstAid .. "/" .. twins.fishing, "3/1/1")

-- A French client: the same IDs, other names - and the 29xx twin first, as on
-- the second character. The fields stay keyed by the English names.
WoW.skillLines = {
    header("Métiers", 11),
    line("Enchantement", 2940, 5, 75), line("Enchantement", 333, 5, 75),
    line("Herboristerie", 182, 27, 75), line("Herboristerie", 2944, 27, 75),
    line("Compréhension", 3012, 7, 45),
    header("Compétences secondaires", 9),
    line("Cuisine", 2939, 6, 75), line("Cuisine", 185, 6, 75),
    line("Secourisme", 129, 1, 75), line("Pêche", 356, 1, 75),
    line("Monte", 762, 75, 75),
}
local fr = {}
AltStable.ScanSkills(fr)
eq("frFR: professions by ID, under the English names", tostring(fr.prof1) .. "+" .. tostring(fr.prof2), "Enchanting+Herbalism")
eq("  flat fields", tostring(fr.prof_Enchanting) .. "/" .. tostring(fr.prof_Herbalism), "5/27")
eq("  secondaries and riding", tostring(fr.cooking) .. "/" .. tostring(fr.firstAid) .. "/"
   .. tostring(fr.fishing) .. "/" .. tostring(fr.riding), "6/1/1/75")
check("  a line that is no profession makes no field", fr["prof_Compréhension"] == nil and fr.prof_Comprehension == nil)

-- Not every ID was measured on this list (Alchemy, Blacksmithing, Engineering,
-- Mining, Riding). On an English client a line whose ID is not in the table
-- still counts by its name, as it did before (#181 review), and its 29xx twin
-- is not counted again. A header named like a skill marks nothing as seen.
WoW.skillLines = {
    header("Riding", 9),                                      -- a header, not the skill
    line("Riding", 9999, 75, 75),
    line("Mining", 8888, 10, 75), line("Mining", 2950, 10, 75),
    line("Alchemy", 7777, 20, 75),
}
local odd = {}
AltStable.ScanSkills(odd)
eq("Riding under an unexpected ID is still Riding, past a header of that name", odd.riding, 75)
eq("an English profession under an unexpected ID still counts", odd.prof1, "Mining")
eq("  its twin is not counted again", odd.prof2, "Alchemy")
eq("  and the next profession is the second", odd.prof_Alchemy, 20)

-- A collapsed header hides its lines from the list (Codex on #383). The
-- record scanned above as "twins" (Enchanting 3, Tailoring 32, Cooking 3)
-- is rescanned with Professions collapsed: the professions stay, and the
-- lines still listed update.
local function collapsed(h) h.isCollapsed = true return h end
WoW.skillLines = {
    header("Class Skills", 7), line("Discipline", 613, 1, 1),
    collapsed(header("Professions", 11)),
    header("Secondary Skills", 9),
    line("Cooking", 185, 9, 75), line("First Aid", 129, 1, 75), line("Fishing", 356, 1, 75),
}
AltStable.ScanSkills(twins)
eq("collapsed Professions: the professions stay", tostring(twins.prof_Enchanting) .. "/" .. tostring(twins.prof_Tailoring), "3/32")
eq("  their maxima", twins.profmax_Tailoring, 75)
eq("  and the two slots", tostring(twins.prof1) .. "+" .. tostring(twins.prof2) .. " " .. twins.prof2Skill, "Enchanting+Tailoring 32")
eq("  a listed line still updates", twins.cooking, 9)
-- Secondary Skills collapsed instead: the secondaries stay, a profession updates.
WoW.skillLines = {
    header("Professions", 11), line("Enchanting", 333, 4, 75), line("Tailoring", 197, 33, 75),
    collapsed(header("Secondary Skills", 9)),
}
AltStable.ScanSkills(twins)
eq("collapsed Secondary Skills: the secondaries stay",
   twins.cooking .. "/" .. twins.firstAid .. "/" .. twins.fishing .. "/" .. twins.cookingMax, "9/1/1/75")
eq("  the professions update", tostring(twins.prof_Enchanting) .. "/" .. tostring(twins.prof_Tailoring), "4/33")
-- Still Secondary Skills collapsed, Tailoring unlearned for Alchemy (Codex on
-- #383): the expanded Professions header is read as it is.
WoW.skillLines = {
    header("Professions", 11), line("Enchanting", 333, 4, 75), line("Alchemy", 171, 1, 75),
    collapsed(header("Secondary Skills", 9)),
}
AltStable.ScanSkills(twins)
check("an unlearned profession under an expanded header clears",
      twins.prof_Tailoring == nil and twins.profmax_Tailoring == nil)
eq("  the slots are the two listed", twins.prof1 .. "+" .. twins.prof2, "Enchanting+Alchemy")
eq("  the hidden secondaries still stay", twins.cooking .. "/" .. twins.fishing, "9/1")
-- A collapsed header that holds none of these (Weapon Skills) restores nothing.
WoW.skillLines = { header("Professions", 11), line("Enchanting", 333, 4, 75),
                   collapsed(header("Weapon Skills", 6)) }
AltStable.ScanSkills(twins)
check("a collapsed Weapon Skills header: Alchemy, gone, clears", twins.prof_Alchemy == nil and twins.prof2 == "")
eq("  and the secondaries, unlisted, reset as before", twins.cooking, 0)
-- Nothing collapsed: a profession that is gone is cleared, as before.
WoW.skillLines = { header("Professions", 11), line("Enchanting", 333, 4, 75) }
AltStable.ScanSkills(twins)
check("nothing collapsed: an unlearned profession is cleared", twins.prof_Tailoring == nil and twins.prof2 == "")

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

-- The progress within the standing (#396), from the struct's thresholds
-- (measured: Neutral Orgrimmar, 2000 between 0 and 3000).
do
    local function fac(id, reaction, cur, lo, hi)
        return { name = "F" .. id, factionID = id, reaction = reaction, isHeader = false,
                 currentStanding = cur, currentReactionThreshold = lo, nextReactionThreshold = hi }
    end
    WoW.factions = { fac(76, 4, 2000, 0, 3000), fac(81, 6, 10234, 9000, 21000),
                     fac(530, 8, 42500, 42000, 42999), fac(2758, 5, 3000, 3000, 9000),
                     fac(2778, 5, WoW.secret(4000), 3000, 9000), fac(68, 4, 100, 3000, 3000) }
    local r = { rep_72_v = 9, rep_72_max = 9 }   -- left from a faction no longer listed
    AltStable.ScanReputations(r)
    eq("progress: the value within the standing", r.rep_76_v, 2000)
    eq("  and its size", r.rep_76_max, 3000)
    eq("  measured from the standing's own threshold (Honored)", r.rep_81_v .. "/" .. r.rep_81_max, "1234/12000")
    eq("  a standing just reached is 0, not unknown", r.rep_2758_v, 0)
    check("Exalted: the standing, no progress", r.rep_530 == 8 and r.rep_530_v == nil and r.rep_530_max == nil)
    check("an unreadable value: the standing, no progress", r.rep_2778 == 5 and r.rep_2778_v == nil
          and r.rep_2778_max == nil)
    WoW.secretBlocked = nil
    check("thresholds with no range: no progress", r.rep_68 == 4 and r.rep_68_v == nil)
    check("a faction no longer listed takes its progress with it", r.rep_72_v == nil and r.rep_72_max == nil)
    local inUse = table.concat(AltStable.RepFieldsInUse({ a = r }), ",")
    check("the progress fields are never taken for factions", not inUse:find("_v", 1, true)
          and not inUse:find("_max", 1, true), inUse)
    eq("RepProgressFields names them", table.concat({ AltStable.RepProgressFields(76) }, ","), "rep_76_v,rep_76_max")

    -- Between full scans (UpdateReputations): the same, and a progress that
    -- can't be read any more goes rather than staying beside a new standing.
    r = { rep_76 = 4, rep_76_v = 2000, rep_76_max = 3000, rep_47 = 4, rep_47_v = 5, rep_47_max = 3000 }
    WoW.factions = { fac(76, 5, 3500, 3000, 9000), { name = "Other", isHeader = true, isCollapsed = true,
                                                     factionID = 0 },
                     fac(47, 5, 3000, 3000, 9000) }
    WoW.factionByID = { [47] = { factionID = 47, reaction = 5, currentStanding = 3600,
                                 currentReactionThreshold = 3000, nextReactionThreshold = 9000 } }
    AltStable.UpdateReputations(r)
    eq("an update writes the new progress", r.rep_76_v .. "/" .. r.rep_76_max, "500/6000")
    eq("  and by ID under a collapsed header", r.rep_47_v .. "/" .. r.rep_47_max, "600/6000")
    WoW.factions[1].currentStanding = nil
    AltStable.UpdateReputations(r)
    check("  an unreadable one is cleared, the standing kept", r.rep_76 == 5 and r.rep_76_v == nil
          and r.rep_76_max == nil)
    WoW.factions, WoW.factionByID = {}, {}
end

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
-- The material and the skin seam, in .toc order: CharacterMenu below asks the
-- skin whether it is glass, so a harness without them is a load order that
-- cannot happen in game.
dofile("tests/libglass.lua"); LoadGlass("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")
dofile("RowRenderer.lua")
dofile("CharacterMenu.lua")
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

-- "Not rested" is the client's plain nil, and is 0, not unknown (#425); the
-- XP % is written whatever the rested read.
do
    local function scanWith(restXP, secret)
        WoW.reset()
        local realExh = GetXPExhaustion
        if secret then GetXPExhaustion = function() return WoW.secret(120) end end
        WoW.level, WoW.xp, WoW.xpMax, WoW.restXP = 20, 100, 400, restXP
        AltStableDB = { [UnitGUID("player")] = { guid = UnitGUID("player"), restPercent = 40, restXP = 160,
                                                 xpPercent = 5, restTimestamp = 111 } }
        pcall(AltStable.ScanCharacter)
        GetXPExhaustion = realExh
        return AltStableDB[UnitGUID("player")]
    end
    local c = scanWith(nil)
    eq("#425: not rested (a plain nil): the rested % goes to 0", c.restPercent, 0)
    eq("  and the amount", c.restXP, 0)
    eq("  and the XP % is written", c.xpPercent, 25)
    check("  with a new snapshot time", c.restTimestamp ~= 111)
    c = scanWith(200)
    eq("a rested bonus: its %", c.restPercent, 50)
    eq("  and the XP %", c.xpPercent, 25)
    c = scanWith(nil, true)
    eq("a secret: the rested % kept", c.restPercent, 40)
    eq("  but the XP % still written", c.xpPercent, 25)
    local realExh = GetXPExhaustion
    GetXPExhaustion = nil
    local okR, r = pcall(AltStable.API.RestedXP)
    check("  no GetXPExhaustion at all: unknown, not 0", okR and r == nil, tostring(r))
    GetXPExhaustion = realExh
    WoW.reset()
end

------------------------------------------------------------
-- A realm the client could not give keeps the stored one (live, 2026-11-20:
-- GetRealmName() returned "" and the character fell under "Unknown").
------------------------------------------------------------
do
    WoW.reset()
    local me = UnitGUID("player")
    AltStableDB = { [me] = { guid = me, realm = "CAMWOW US2 Realm 7 PvE" } }
    local realRealm = GetRealmName
    GetRealmName = function() return "" end
    pcall(AltStable.ScanCharacter)
    eq("an empty realm keeps the stored one", AltStableDB[me].realm, "CAMWOW US2 Realm 7 PvE")
    GetRealmName = function() return nil end
    pcall(AltStable.ScanCharacter)
    eq("  so does none at all", AltStableDB[me].realm, "CAMWOW US2 Realm 7 PvE")
    GetRealmName = realRealm
    pcall(AltStable.ScanCharacter)
    eq("a real one is stored", AltStableDB[me].realm, WoW.player.realm)

    -- #412: the ruleset, from the game's rules, stored with the record (and so
    -- synced); a client that can't read them keeps what is stored. The rules
    -- are read by Config.lua's LiveRuleset, loaded before any scan in game.
    dofile("Config.lua")
    WoW.gameRules = { [Enum.GameRule.PvPRuleset] = true, [Enum.GameRule.RPRuleset] = true }
    GetRealmName = function() return "" end
    pcall(AltStable.ScanCharacter)
    eq("the scan stores the ruleset the game says", AltStableDB[me].ruleset, "RPPvP")
    eq("  which is the record's ruleset, its realm hidden", AltStable.RulesetOf(AltStableDB[me]), "RPPvP")
    local realRules = Enum.GameRule
    Enum.GameRule = nil
    AltStable._test.ResetLiveRuleset()   -- a new session: the reading is kept (#435)
    pcall(AltStable.ScanCharacter)
    eq("  a client that can't read the rules keeps it", AltStableDB[me].ruleset, "RPPvP")
    Enum.GameRule = realRules
    -- #413 review: a query that throws keeps it too, never stores Normal.
    local realActive = C_GameRules.IsGameRuleActive
    C_GameRules.IsGameRuleActive = function() error("not ready") end
    AltStable._test.ResetLiveRuleset()
    pcall(AltStable.ScanCharacter)
    eq("  a rule query that throws keeps it", AltStableDB[me].ruleset, "RPPvP")
    C_GameRules.IsGameRuleActive = realActive
    GetRealmName = realRealm
    WoW.gameRules = {}
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

    -- Well Rested (#352): 20% faster, and a cap of 180% (assumed) instead of 150%.
    -- 80h in an inn: 50% base, 60% with the talent.
    local function wr(pct, talent, hours)
        return { guid = "Player-Alt-1", level = 30, restPercent = pct, wellRested = talent,
                 restTimestamp = now - hours * 3600, restedArea = true }
    end
    eq("without the talent, 80h in an inn adds 50%", (rested(wr(0, 0, 80))), 50)
    eq("with it, 20% faster: 60%", (rested(wr(0, 1, 80))), 60)
    eq("  also as synced (the string \"1\")", (rested(wr(0, "1", 80))), 60)
    eq("without it, the cap is 150%", (rested(wr(140, 0, 400))), 150)
    eq("with it, the cap is 180%", (rested(wr(140, 1, 400))), 180)
    -- #526: the game reported 221% on an alt without the talent. Held at the
    -- cap, and not taken for Well Rested.
    eq("a stored value above 150% without the talent: held at 150%", (rested(wr(221, 0, 0))), 150)
    eq("  nor does it make the talent", AltStable.RestedCap(wr(221, 0, 0)), 150)
    eq("  accruing at the base rate", (rested(wr(0, 0, 80))), 50)
    eq("a value above 180% with it: held at 180%", (rested(wr(221, 1, 0))), 180)
    eq("RestedCap: 150 without the talent", AltStable.RestedCap(wr(0, 0, 0)), 150)
    eq("RestedCap: 180 with it", AltStable.RestedCap(wr(0, 1, 0)), 180)
    -- The rank read from the alt's Legacy talents (#500), node 110301: 4% a
    -- rank (unmeasured below 5/5; GlassPanel's reading of the 5/5 text).
    if not AltStable.LegacyTalents then dofile("LegacyTalents.lua") end
    if AltStable.LegacyTalents then
        local withLT = wr(0, 1, 80)   -- the scan's flag says yes, the reading says rank 1
        withLT.legacyTalents = "v1;c4;1187:0:;1188:1:110301.1.5.136855.1.1225478;1189:0:"
        eq("Well Rested 1/5 in the alt's Legacy talents: the cap is 156%, not 180%", AltStable.RestedCap(withLT), 156)
        eq("  and it accrues 4% faster: 52%", (rested(withLT)), 52)
        withLT.legacyTalents = "v1;c4;1187:0:;1188:5:110301.5.5.136855.5.1225478;1189:0:"
        eq("  at 5/5: 180%", AltStable.RestedCap(withLT), 180)
        eq("  and 20% faster", (rested(withLT)), 60)
        withLT.legacyTalents = "v1;c4;1187:3:110291.3.5.136848.3.1225435;1188:0:;1189:0:"
        eq("  a reading without it: 150%, whatever the flag", AltStable.RestedCap(withLT), 150)
        eq("  at the base rate", (rested(withLT)), 50)
        withLT.legacyTalents = "v1;c4;1187:0:;1188:0:110301.0.5.136855.0.1225478;1189:0:"
        eq("  Well Rested at rank 0: 150%", AltStable.RestedCap(withLT), 150)
        withLT.legacyTalents = "v1;c4;1187:0:;1188:9:110301.9.5.136855.9.1225478;1189:0:"
        eq("  a rank past 5 counts as 5", AltStable.RestedCap(withLT), 180)
    else
        check("LegacyTalents is loaded for the rested tests", false)
    end

    -- The played character: the live bonus (100 of 400 is 25%), and not rested
    -- (a plain nil) is 0% rather than the stored 40% (#425); a secret falls
    -- back to the stored value.
    WoW.level, WoW.xpMax, WoW.restXP = 20, 400, 100
    local me = { guid = UnitGUID("player"), level = 20, restPercent = 40, restTimestamp = WoW.now }
    eq("#425: the played character's live bonus", (rested(me)), 25)
    WoW.restXP = 884   -- 221% of 400, as the game reported on an alt (#526)
    eq("#526: the played character's live value above the cap: held at it", (rested(me)), 150)
    WoW.restXP = 100
    WoW.restXP = nil
    eq("  not rested: 0%, not the stored 40%", (rested(me)), 0)
    local realExh = GetXPExhaustion
    GetXPExhaustion = function() return WoW.secret(120) end
    eq("  a secret: the stored value", (rested(me)), 40)
    GetXPExhaustion = realExh

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
-- data, and any column can be hidden (#378), so when they change the pool sets
-- its rows up again for the new columns: rendering a row against columns it
-- wasn't set up for indexes a cell that doesn't exist. The widgets are reused,
-- since frames are never freed.
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

    eq("the same columns keep the pool's rows", #AltStable.RowPoolFor(pools, "rep", colsA).rows, 1)
    local thunderCell = oldRow.byField.rep_81.cell
    local frames = 0
    local realCF = CreateFrame
    CreateFrame = function(...) frames = frames + 1; return realCF(...) end
    pool = AltStable.RowPoolFor(pools, "rep", colsB)
    eq("new columns: the pool keeps its rows (#378: frames are never freed)", pool.rows[1], oldRow)
    local ok, err = pcall(AltStable.RenderRow, oldRow, char, 1, colsB)
    check("  set up again, the row renders the new faction", ok, tostring(err))
    eq("  in a cell of its own", oldRow.cells[3], oldRow.byField.rep_576.cell)
    eq("  the columns it had keep their cells", oldRow.cells[2], thunderCell)
    eq("  two dividers for three columns", #oldRow.dividers, 2)
    local timberCell = oldRow.byField.rep_576.cell
    local made = frames
    pool = AltStable.RowPoolFor(pools, "rep", colsA)
    check("back to the old columns: the one it no longer shows is hidden and blank",
          not timberCell:IsShown() and (timberCell:GetText() or "") == "")
    eq("  one divider again", #oldRow.dividers, 1)
    AltStable.RowPoolFor(pools, "rep", colsB)
    eq("  and shown again, the same cell", oldRow.cells[3], timberCell)
    check("  shown", timberCell:IsShown())
    for _ = 1, 5 do
        AltStable.RowPoolFor(pools, "rep", colsB)
        AltStable.RowPoolFor(pools, "rep", colsA)
    end
    eq("  toggling again and again makes no new frame", frames, made)
    CreateFrame = realCF
    AltStable.RowPoolFor(pools, "rep", { colsA[1] })
    eq("one column: no divider in use", #oldRow.dividers, 0)
    check("  the pool's are hidden", not oldRow.dividerPool[1]:IsShown())

    -- Hover buttons only on a character's row, once it is rendered (Codex
    -- review of #494): a pooled row turned filler or group band must not
    -- keep the last character's under a blank cell.
    AltStable.RowPoolFor(pools, "rep", colsB)
    local tip = oldRow.repTips[3]
    check("set up for new columns, a hover button waits for the render", tip and not tip:IsShown())
    check("  a column it already showed too", oldRow.repTips[1] and not oldRow.repTips[1]:IsShown())
    AltStable.RenderRow(oldRow, char, 1, colsB)
    check("  rendered for a character, it is on", tip:IsShown())
    AltStable.RenderFillerRow(oldRow, 2)
    check("  a filler row's are off", not tip:IsShown())
    AltStable.RenderRow(oldRow, char, 1, colsB)
    AltStable.RenderGroupRow(oldRow, { kind = "group", realm = "R", count = 1 })
    check("  and a group row's", not tip:IsShown())
    AltStable.RenderRow(oldRow, char, 1, colsB)
    check("  back to a character, on again", tip:IsShown())
    check("another section's pool is untouched",
          AltStable.RowPoolFor(pools, "gear", colsA) ~= pool)
end

-- A reputation cell's tooltip (#396): the standing, then the progress within
-- it when the record has it.
do
    local col = { label = "Orgrimmar", field = "rep_76", type = "rep", width = 22 }
    local row = AltStable.CreateRow(nil, 20, { col })
    local tip = row.repTips[1]
    local function Hover(char)
        AltStable.RenderRow(row, char, 1, { col })
        WoW.tooltipLines = {}
        tip:GetScript("OnEnter")(tip)
        return table.concat(WoW.tooltipLines, "|")
    end
    eq("the tooltip gives the progress within the standing",
       Hover({ guid = "g", name = "N", rep_76 = 6, rep_76_v = 1234, rep_76_max = 12000 }),
       "Orgrimmar|Honored  1234 / 12000")
    eq("  the standing alone without it (an older peer, Exalted)",
       Hover({ guid = "g", name = "N", rep_76 = 8 }), "Orgrimmar|Exalted")
    eq("  nor half of it", Hover({ guid = "g", name = "N", rep_76 = 4, rep_76_v = 5 }), "Orgrimmar|Neutral")
    GameTooltip:Hide()
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
    -- "An icon header keeps the sort tint when the cursor leaves" was a text
    -- search here; it is a behaviour test in test_sheetui.lua now (#160).
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

-- The export window comes up ABOVE the sheet. Both are DIALOG and toplevel, so
-- whichever was raised last wins, and clicking the sheet raises it - survivable
-- while the sheet let clicks through to what was under it, dead in the overlap
-- since it takes the mouse (#74).
do
    local raised = 0
    local held = AltStable._test and AltStable._test.ExportFrame
    AltStableDB = AltStableDB or {}
    local ok = pcall(AltStable.ShowExport)
    check("the export window opens", ok == true)
    local f = _G["AltStableExport"]
    check("  and is a real frame", f ~= nil)
    if f then
        f.Raise = function(self) raised = raised + 1; return self end
        pcall(AltStable.ShowExport)
        check("  raised above whatever was over it", raised > 0, tostring(raised))
        f:Hide()
    end
end

-- #470: the window draws no raw text - the game's fonts draw a tab, which
-- makes Sheets split a paste into columns, as a box. The TSV sits in an
-- invisible box, selected and focused, for the player's Ctrl+C (addons can't
-- write the clipboard on Forever).
do
    local held = AltStableDB
    AltStableDB = {
        a = { name = "Ann", realm = "R", class = "MAGE", race = "Human", level = 60 },
        b = { name = "Bob", realm = "R", class = "MAGE", race = "Orc", level = 50 },
    }
    AltStable.ShowExport()
    local f = _G["AltStableExport"]
    local box = f.editBox
    local text = box:GetText() or ""
    check("#470: the box holds the TSV, tabs and all", text:find("\t", 1, true) ~= nil, text:sub(1, 40))
    eq("  the header and a line per character", select(2, text:gsub("\n", "")) + 1, 3)
    eq("  and is never drawn", box:GetAlpha(), 0)
    -- Alpha didn't hide the selection in game: grey bars up the screen.
    eq("  its selection is transparent", box._highlightColor and box._highlightColor[4], 0)
    eq("  so is its text", box:GetTextColor() and select(4, box:GetTextColor()), 0)
    check("  and it sits in a frame that clips it", box:GetParent():DoesClipChildren())
    local hw, hh = box:GetParent():GetWidth(), box:GetParent():GetHeight()
    check("  one pixel at most", hw <= 1 and hh <= 1, hw .. "x" .. hh)
    check("  nor takes the mouse", not box:IsMouseEnabled())
    check("  selected", box._highlighted == true)
    check("  and focused, for Ctrl+C", box:HasFocus())
    local cols = 1
    for _ in AltStable._test.ExportHeader():gmatch("\t") do cols = cols + 1 end
    eq("the window says what is ready", f.status:GetText(),
       ("Ready to copy: 2 characters, %d columns."):format(cols))
    check("  and what to do", (f.how:GetText() or ""):find("Ctrl+C", 1, true) ~= nil, f.how:GetText())
    -- Typing can't change it.
    box:SetText("x")
    box:GetScript("OnTextChanged")(box, true)
    eq("typing doesn't change the text", box:GetText(), text)
    box:SetText(text)
    box:GetScript("OnTextChanged")(box, false)
    eq("  our own SetText stands", box:GetText(), text)
    -- Focus lost, then Select again.
    box:ClearFocus()
    box:GetScript("OnEditFocusLost")(box)
    check("losing the selection says so", (f.how:GetText() or ""):find("Select again", 1, true) ~= nil, f.how:GetText())
    box._highlighted = nil
    f.again:GetScript("OnClick")(f.again)
    check("Select again selects it", box._highlighted == true)
    check("  and focuses it", box:HasFocus())
    -- A caret key collapses the selection with the box still focused: the
    -- key's release selects it all again, and the line still holds.
    box._highlighted = nil
    box:GetScript("OnKeyUp")(box, "END")
    check("a caret key's release selects the whole text again", box._highlighted == true)
    check("  and the line says it is selected", (f.how:GetText() or ""):find("Ctrl+C now", 1, true) ~= nil, f.how:GetText())
    box._highlighted = nil
    box:GetScript("OnEditFocusGained")(box)
    check("focus regained selects all", box._highlighted == true)
    check("  and says so", (f.how:GetText() or ""):find("Ctrl+C now", 1, true) ~= nil, f.how:GetText())
    -- The companion's Google Sheet, beside the close button.
    WoW.tooltipLines = {}
    f.info:GetScript("OnEnter")(f.info)
    local tip = table.concat(WoW.tooltipLines, "|")
    check("the info icon names the companion", tip:find("AltStable Companion", 1, true) ~= nil, tip)
    check("  and the Google Sheet", tip:find("Google", 1, true) ~= nil, tip)
    local copied
    local realCopy, realURL = AltStable.ShowCopyText, AltStable.COMPANION_URL
    AltStable.COMPANION_URL = realURL or "https://example.invalid/releases"
    AltStable.ShowCopyText = function(_, t) copied = t end
    f.info:GetScript("OnClick")(f.info)
    eq("  a click offers the download link", copied, AltStable.COMPANION_URL)
    AltStable.ShowCopyText, AltStable.COMPANION_URL = realCopy, realURL
    -- Only what the fonts draw: no tab, no arrow, in anything on screen.
    for _, s in ipairs({ f.status:GetText() or "", f.how:GetText() or "", tip, "Select again" }) do
        check("no tab or arrow on screen: " .. s:sub(1, 30),
              not s:find("\t", 1, true) and not s:find("\226\134\146", 1, true))
    end
    box:GetScript("OnEditFocusLost")(box)
    check("  nor in the lost-selection line", not (f.how:GetText() or ""):find("\226\134\146", 1, true))
    f:Hide()
    AltStableDB = { a = { name = "Solo", realm = "R", class = "MAGE", race = "Human", level = 1 } }
    AltStable.ShowExport()
    eq("one character is one character", f.status:GetText(), ("Ready to copy: 1 character, %d columns."):format(cols))
    f:Hide()
    AltStableDB = held
end

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
    -- Skyborne is on both sides: no stored faction, no guess (#433).
    local sky = firstCols(row({ name = "D", realm = "R", class = "MAGE", race = "Skyborne", level = 60 }))
    eq("a Skyborne record with no faction exports a blank faction", sky[5], "")
    eq("  in its own column: the race is still the fourth", sky[4], "Skyborne")
    local human = firstCols(row({ name = "E", realm = "R", class = "MAGE", race = "Human", level = 60 }))
    eq("a Human with no faction is still Alliance", human[5], "A")
    local none = firstCols(row({ name = "F", realm = "R", class = "MAGE", level = 60 }))
    eq("a record with neither faction nor race exports a blank faction", none[5], "")
    local unknown = firstCols(row({ name = "G", realm = "R", class = "MAGE", race = "Pandaren", level = 60 }))
    eq("  as does a race the export doesn't know", unknown[5], "")
end
-- A record scanned before #177, or synced from a peer still on that build,
-- holds ONE profession in both prof1 and prof2. The export reads each
-- profession's own field, so the second is not lost.
do
    local header, row = AltStable._test.ExportHeader, AltStable._test.ExportRow
    local function cols(line)
        local out = {}
        for field in (line .. "\t"):gmatch("([^\t]*)\t") do out[#out + 1] = field end
        return out
    end
    local names = cols(header())
    local function at(label)
        for i, n in ipairs(names) do if n == label then return i end end
    end
    local stale = cols(row({ name = "D", realm = "R", class = "MAGE", race = "Human", level = 20,
        prof1 = "Enchanting", prof1Skill = 3, prof2 = "Enchanting", prof2Skill = 3,
        prof_Enchanting = 3, prof_Tailoring = 32, cooking = 3 }))
    check("the export has a Tailoring column", at("Tailoring") ~= nil)
    eq("a stale prof1 = prof2 record still exports its second profession", stale[at("Tailoring") or 0], "32")
    eq("  and the first", stale[at("Enchanting") or 0], "3")
    eq("  a profession it does not have stays blank", stale[at("Alchemy") or 0], "")
    eq("  secondaries as before", stale[at("Cooking") or 0], "3")
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

------------------------------------------------------------
-- /alts account
------------------------------------------------------------

AltStableConfig = { whitelist = {} }
AltStableDB = {}

local acct = Slash("account")
check("bare /alts account reports that none is set",
      acct:find("No account number set", 1, true) ~= nil, acct)

acct = Slash("account 2")
eq("setting one stores it", AltStableConfig.accountNumber, 2)
check("  and confirms", acct:find("set to 2", 1, true) ~= nil, acct)

acct = Slash("account")
check("bare /alts account now reports the value",
      acct:find("is 2", 1, true) ~= nil, acct)

-- A typo must not read as success. This printed a cheerful status line once.
acct = Slash("account one")
eq("a non-number leaves the value alone", AltStableConfig.accountNumber, 2)
check("  and says what it wants", acct:find("whole number", 1, true) ~= nil, acct)

for _, bad in ipairs({ "2.5", "-3", "0" }) do
    acct = Slash("account " .. bad)
    eq("'" .. bad .. "' is refused", AltStableConfig.accountNumber, 2)
end
-- Compared as a STRING on the wire, so hex would be stored as 16 and mean
-- nothing to a peer that wrote "0x10".
acct = Slash("account 0x10")
eq("hex is refused too", AltStableConfig.accountNumber, 2)

-- Characters scanned on THIS client carry the number; without re-tagging they
-- keep the old one and drop out of account-scoped syncs until each is played.
AltStableDB = {
    mine  = { guid = "mine",  name = "Mine",  scannedHere = true,  account = 2 },
    also  = { guid = "also",  name = "Also",  scannedHere = true,  account = 2 },
    peers = { guid = "peers", name = "Peer",  account = 7 },
}
acct = Slash("account 3")
eq("our own characters are re-tagged", AltStableDB.mine.account, 3)
eq("  all of them", AltStableDB.also.account, 3)
eq("  but never a peer's", AltStableDB.peers.account, 7)
check("  and it says how many", acct:find("re-tagged", 1, true) ~= nil, acct)

acct = Slash("account clear")
eq("clearing empties it", AltStableConfig.accountNumber, "")
check("  and says so", acct:find("cleared", 1, true) ~= nil, acct)
-- Clearing must untag our own records too, or this client presents MIXED
-- identities: alts scanned earlier still claim account 3 and are still sent to
-- peers under it, while the next one scanned carries none.
eq("  and untags our characters", AltStableDB.mine.account, "")
eq("  all of them", AltStableDB.also.account, "")
eq("  but still never a peer's", AltStableDB.peers.account, 7)
check("  and says how many", acct:find("untagged", 1, true) ~= nil, acct)
acct = Slash("account clear")
check("clearing twice is not an error", acct:find("was set", 1, true) ~= nil, acct)

AltStableConfig = { whitelist = {} }
AltStableDB = {}

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
-- First: a synced setting's change also stamps its group (prefsStamps).
eq("  and reports the key", changed[1], "toastsEnabled")

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
-- The box no longer writes the config itself: both it and /alts account go
-- through AltStable.SetAccountNumber, which is the one place that writes. A
-- grep for the old call site would now fail while the behaviour is correct,
-- which is the trouble with grepping for implementations.
check("one seam owns the account number", type(AltStable.SetAccountNumber) == "function")
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
                        "RowRenderer.lua", "Export.lua", "Capture.lua", "AutoCapture.lua",
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
check("  naming the build that wrote it", AltStableConfig.svLoadCheck.build == select(2, GetBuildInfo()),
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

-- Only on a development copy. A released addon carries its tag as its version,
-- and a player has nothing to do with "re-run /apidump".
local realMeta = AltStable.API.GetAddOnMetadata
for _, case in ipairs({
    { "v0.7.0-beta",        false, "a release" },
    { "v0.11.0",            false, "a release tagged without -beta (from v0.10.0 on)" },
    { "dev-9ea1f00",        true,  "a deploy.ps1 copy" },
    { "dev",                true,  "a copy deployed outside git" },
    { "@project-version@",  true,  "a checkout run as-is" },
}) do
    AltStable.API.GetAddOnMetadata = function(_, field) return field == "Version" and case[1] or nil end
    WoW.chatOut = {}
    AltStable.CheckClientBuild()
    if case[2] then
        check("a different build is announced on " .. case[3], #WoW.chatOut > 0, case[1])
    else
        check("a different build is NOT announced on " .. case[3], #WoW.chatOut == 0, WoW.chatOut[1] or "")
    end
end
AltStable.API.GetAddOnMetadata = function() error("no metadata") end
WoW.chatOut = {}
AltStable.CheckClientBuild()
check("an unreadable version counts as a development copy", #WoW.chatOut > 0)
AltStable.API.GetAddOnMetadata = realMeta

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
-- And stamps its provenance (#281): "self", with the time it was established.
check("  with provenance self", scanned ~= nil and scanned.provKind == "self")
check("  stamped with a time", scanned ~= nil and type(scanned.provAt) == "number")
do
    -- A record a peer had marked as its own account's: our scan is the truth.
    AltStableDB[UnitGUID("player")] = { guid = UnitGUID("player"), name = "Was",
        provKind = "own-account", provAt = 5, provVia = "Bee Surname" }
    pcall(AltStable.ScanCharacter)
    local again = AltStableDB[UnitGUID("player")]
    check("  a scan turns an own-account mark into self", again.provKind == "self" and again.provVia == nil)
end

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
-- The Well Rested Legacy talent (#352) is recorded as a number, so it syncs as one.
eq("no Well Rested talent scans as 0", c and c.wellRested, 0)
do
    WoW.reset()
    WoW.playerSpells[1225478] = true
    AltStableDB = {}
    pcall(AltStable.ScanCharacter)
    local w = AltStableDB[UnitGUID("player")]
    eq("the Well Rested talent (spell 1225478) scans as 1", w and w.wellRested, 1)
    WoW.playerSpells[1225478] = nil
    w.wellRested = 1
    pcall(AltStable.ScanCharacter)
    eq("  and unlearning it scans back to 0", w.wellRested, 0)
end
WoW.reset()

-- The gem audit's quality setting is RETIRED, and a profile that already has it
-- must come back without it. It was written to real profiles on disk, and a key
-- nothing reads is one the next reader has to work out the meaning of - so it is
-- cleared rather than merely no longer defaulted.
--
-- auditMinLevel is the one that must NOT go with it. Both were cleared at first,
-- on the argument that enchants need no threshold - but that argument is about
-- QUALITY, and a level gate is a different setting. The pair is asserted
-- together because that is the mistake: they look alike and are not.
if AltStable.EnsureConfigDefaults then
    AltStableConfig = {}
    AltStable.EnsureConfigDefaults()
    eq("a fresh profile has no gem-quality setting", AltStableConfig.minGemQuality, nil)
    local cap = AltStable.API.LevelCap()
    eq("  but it does have an audit level, defaulted to the cap",
       AltStableConfig.auditMinLevel, cap)

    -- The case that matters: an existing profile carrying both.
    AltStableConfig = { minGemQuality = 3, auditMinLevel = 42 }
    AltStable.EnsureConfigDefaults()
    eq("an existing profile has the gem setting cleared", AltStableConfig.minGemQuality, nil)
    eq("  and its audit level left alone, not overwritten with the default",
       AltStableConfig.auditMinLevel, 42)

    -- And nothing else went with them.
    check("the settings around them survive",
          AltStableConfig.syncMode ~= nil and AltStableConfig.hiddenCharacters ~= nil)
else
    check("EnsureConfigDefaults is exposed", false)
end

------------------------------------------------------------
-- Melee crit, for the detail pane's Combat section (#91)
------------------------------------------------------------
-- Both exist in Vanilla and are read straight off the player. The two stats
-- beside them in AltTracker's table are deliberately NOT collected: there is
-- no haste rating pre-TBC and resilience is a TBC PvP stat, so scanning them
-- as zero would have the pane report a real 0% for something the game does
-- not have.

do
    WoW.critChance, WoW.hitModifier = 17.25, 4
    WoW.items[5001] = { name = "A Shield", quality = 2, ilvl = 40,
                        itemType = "Armor", subType = "Shields",
                        equipLoc = "INVTYPE_SHIELD" }
    WoW.equipped[17] = "|Hitem:5001|h[A Shield]|h"
    AltStableDB = {}
    AltStable.ScanCharacter()

    local me = AltStableDB[UnitGUID("player")]
    check("the scan stored a character", type(me) == "table")
    if me then
        eq("melee crit is scanned", me.stat_crit, 17.25)
        eq("haste is not scanned", me.stat_haste, nil)
        eq("  nor resilience", me.stat_resilience, nil)

        -- Bonus hit IS scanned now. MEASURED on 1.60.1.70009: GetHitModifier
        -- printed 0, not ABSENT and not nil, so the function works and Core has
        -- taken stat_hitpct off RETIRED_FIELDS.
        --
        -- Asserted as the stubbed VALUE, not merely non-nil: the field reads
        -- non-nil from a producer that wrote a constant, and the point is that it
        -- carries what the client answered.
        eq("bonus hit is scanned", me.stat_hitpct, 4)

        check("the stats around them are still there",
              me.stat_ap ~= nil and me.stat_defense ~= nil and me.stat_armor ~= nil)

        -- The equip location is NOT stored. It is resolved on demand from
        -- gearid_, which is synced, so storing it would be seventeen keys per
        -- character carrying a fact already on the wire - and one that the
        -- sync boundary then had to strip, leaving every remote character
        -- unable to answer it at all.
        eq("the equip location is not stored", me.gearloc_offhand, nil)
        check("  because the id it is derived from is",
              (tonumber(me.gearid_offhand) or 0) == 5001, tostring(me.gearid_offhand))
    end

    -- A client without them must not crash the scan. Neither is guaranteed on
    -- every build, and the scan runs on login before anything else works - so an
    -- unguarded call there takes the whole login path down, not one stat.
    --
    -- Both are cleared, and each is cleared ALONE as well: a single test with
    -- both missing passes for a scanner that guards one of them and calls the
    -- other, because the first guard returns before the second line runs.
    local realCrit, realHit = GetCritChance, GetHitModifier
    for _, case in ipairs({ { crit = false, hit = false, what = "neither" },
                            { crit = true,  hit = false, what = "no GetHitModifier" },
                            { crit = false, hit = true,  what = "no GetCritChance" } }) do
        GetCritChance = case.crit and realCrit or nil
        GetHitModifier = case.hit and realHit or nil
        AltStableDB = {}
        check(("a client with %s still scans"):format(case.what),
              pcall(AltStable.ScanCharacter))
        local bare = AltStableDB[UnitGUID("player")]
        if not case.crit then
            check("  and simply has no crit", bare == nil or bare.stat_crit == nil)
        end
        if not case.hit then
            check("  nor bonus hit", bare == nil or bare.stat_hitpct == nil)
        end
    end
    GetCritChance, GetHitModifier = realCrit, realHit
    WoW.critChance, WoW.hitModifier = 12.5, 3
end

------------------------------------------------------------
-- The enchant in words (#94), off the typed tooltip lines
------------------------------------------------------------
-- Measured on 1.60.1.70291: the permanent enchant is line type 15, and an
-- ordinary green "Equip:" line is type 0 - so the type is the discriminator,
-- and a green Equip line must never be read as an enchant.
do
    local LT = Enum.TooltipDataLineType
    local function L(t, text) return { type = t, leftText = text } end
    WoW.reset()
    WoW.items[5101] = { name = "Gown", quality = 2, ilvl = 20, itemType = "Armor", subType = "Cloth" }
    WoW.items[5102] = { name = "Bracers", quality = 1, ilvl = 15, itemType = "Armor", subType = "Cloth" }
    WoW.items[5103] = { name = "Gloves", quality = 2, ilvl = 12, itemType = "Armor", subType = "Cloth" }
    WoW.equipped[5]  = "|Hitem:5101:41::::::::|h[Gown]|h"
    WoW.equipped[9]  = "|Hitem:5102:41::::::::|h[Bracers]|h"
    WoW.equipped[10] = "|Hitem:5103|h[Gloves]|h"
    WoW.slotTooltip[5] = {
        L(LT.ItemName, "Gown"),
        L(LT.None, "Equip: Increases damage and healing done by magical spells and effects by up to 2."),
        L(LT.ItemEnchantmentPermanent, "Enchanted: Stamina +2"),
        L(LT.SellPrice, ""),
    }
    -- Colour codes and a line break: the field rides the wire as one line.
    WoW.slotTooltip[9] = { L(LT.ItemEnchantmentPermanent, "Enchanted: |cff00ff00Minor\nStamina|r") }
    WoW.slotTooltip[10] = {
        L(LT.ItemName, "Gloves"),
        L(LT.None, "Equip: Increases damage and healing done by magical spells and effects by up to 1."),
    }
    AltStableDB = {}
    AltStable.ScanCharacter()
    local me = AltStableDB[UnitGUID("player")] or {}
    eq("an enchant is stored in words, without the client's label", me.gearench_chest, "Stamina +2")
    eq("  colour codes and line breaks are stripped", me.gearench_wrist, "Minor Stamina")
    eq("a green Equip line is not an enchant", AltStable._testScanner.EnchantText(10), nil)
    eq("  an unenchanted slot stores nothing", me.gearench_hands, nil)
    eq("an empty slot has none", me.gearench_feet, nil)
    -- Only read when the link carries an enchant id: a tooltip per slot per
    -- scan is waste for the many slots that have none.
    do
        local realTip, reads = C_TooltipInfo, {}
        C_TooltipInfo = { GetInventoryItem = function(u, slot)
            reads[#reads + 1] = slot; return realTip.GetInventoryItem(u, slot) end }
        AltStable.ScanCharacter()
        table.sort(reads)
        eq("  the tooltip is read only for slots whose link has an enchant",
           table.concat(reads, ","), "5,9")
        C_TooltipInfo = realTip
    end
    -- A label with nothing after it is no words.
    WoW.slotTooltip[10] = { L(LT.ItemEnchantmentPermanent, "Enchanted: ") }
    eq("  an enchant line with no words reads as none", AltStable._testScanner.EnchantText(10), nil)
    WoW.slotTooltip[10] = nil

    -- Taking the item OFF clears its words: the scan resets the field, and an
    -- emptied slot is never read, so nothing else would.
    do
        local chest = WoW.equipped[5]
        WoW.equipped[5] = nil
        AltStable.ScanCharacter()
        eq("an item taken off takes its enchant's words with it",
           (AltStableDB[UnitGUID("player")] or {}).gearench_chest, nil)
        WoW.equipped[5] = chest
        AltStable.ScanCharacter()
        me = AltStableDB[UnitGUID("player")] or {}
    end

    -- The client's label is the localised global, not an English literal.
    local realLabel = ENCHANTED_TOOLTIP_LINE
    ENCHANTED_TOOLTIP_LINE = "Verzaubert: %s"
    WoW.slotTooltip[5] = { L(LT.ItemEnchantmentPermanent, "Verzaubert: Ausdauer +2") }
    eq("  the label is read from the client's own string",
       AltStable._testScanner.EnchantText(5), "Ausdauer +2")
    ENCHANTED_TOOLTIP_LINE = nil
    WoW.slotTooltip[5] = { L(LT.ItemEnchantmentPermanent, "Enchanted: Stamina +2") }
    eq("  and falls back to the English one", AltStable._testScanner.EnchantText(5), "Stamina +2")
    ENCHANTED_TOOLTIP_LINE = realLabel

    -- No API (or a tooltip with no lines yet): the scan does not die, and the
    -- words go rather than outliving the item they described - the Roster
    -- says "enchanted" off gearmod_ instead.
    local realTip = C_TooltipInfo
    C_TooltipInfo = nil
    check("a client without C_TooltipInfo still scans", pcall(AltStable.ScanCharacter))
    me = AltStableDB[UnitGUID("player")] or {}
    eq("  and stores no words", me.gearench_chest, nil)
    check("  while the enchant id is still there", (me.gearmod_chest or ""):find("^41:") ~= nil,
          tostring(me.gearmod_chest))
    C_TooltipInfo = realTip
    WoW.slotTooltip[5] = {}
    eq("a tooltip with no lines yet says nothing", AltStable._testScanner.EnchantText(5), nil)
    WoW.slotTooltip[5] = nil
    eq("an empty slot's tooltip says nothing", AltStable._testScanner.EnchantText(3), nil)
    C_TooltipInfo = { GetInventoryItem = function() error("boom") end }
    eq("  nor does one whose tooltip read throws", AltStable._testScanner.EnchantText(5), nil)
    C_TooltipInfo = realTip

    -- A cached-late item: the retry re-reads the words for the logged-in character.
    WoW.slotTooltip[9] = { L(LT.ItemEnchantmentPermanent, "Enchanted: Stamina +3") }
    eq("the cache retry re-reads a slot by key", AltStable.RereadEnchantText("wrist"), "Stamina +3")
    eq("  and an unknown key reads nothing", AltStable.RereadEnchantText("nope"), nil)
    eq("  nor a slot whose link has no enchant", AltStable.RereadEnchantText("hands"), nil)
    WoW.reset()
end

------------------------------------------------------------
-- The pet (#75), in the shapes measured on 70124
------------------------------------------------------------
do
    local guid = UnitGUID("player")
    local function scanAs(class)
        WoW.player.class = class
        pcall(AltStable.ScanCharacter)
        return AltStableDB[guid]
    end
    local CAT  = { slotID = 2, name = "Tarthosuk", familyName = "Cat",  displayID = 143626,
                   creatureID = 251245, petNumber = 1976870 }
    local BEAR = { slotID = 1, name = "Tarthosuk", familyName = "Bear", displayID = 136605,
                   creatureID = 250927, petNumber = 1806743 }
    local savedClass = WoW.player.class

    -- The owner's two pets SHARE A NAME. The cat is out, in slot 2; its GUID's
    -- last six hex digits are its petNumber (0x1E2A26 = 1976870).
    WoW.reset()
    AltStableDB = {}
    WoW.stable = { BEAR, CAT }
    WoW.pet = { guid = "Pet-0-4615-1-86241-165189-02001E2A26", name = "Tarthosuk" }
    local c = scanAs("HUNTER")
    eq("a hunter's pet is found by its petNumber", c.pet_display, 143626)
    eq("  its creature", c.pet_npc, 251245)
    eq("  its name", c.pet_name, "Tarthosuk")

    -- No petNumber match: the current Call Pet spell is the second witness.
    WoW.pet = { guid = "Pet-0-4615-1-86241-165189-zz", name = "Tarthosuk" }
    WoW.currentSpells = { [83242] = true }          -- Call Pet 2
    AltStableDB = {}
    c = scanAs("HUNTER")
    eq("without a petNumber, the Call Pet spell picks the slot", c.pet_display, 143626)

    -- Neither: NOT the name, which would pick whichever Tarthosuk came first.
    WoW.currentSpells = {}
    AltStableDB = {}
    c = scanAs("HUNTER")
    eq("with neither witness nothing is recorded, not a namesake", c.pet_display, nil)

    -- A demon: the GUID's npc, resolved to its display id.
    WoW.reset()
    AltStableDB = {}
    WoW.pet = { guid = "Pet-0-4621-0-208652-1860-010023C79D", name = "Hathnos" }
    WoW.creatureDisplays = { [1860] = 1132 }
    c = scanAs("WARLOCK")
    eq("a warlock's demon is its npc's display", c.pet_display, 1132)
    eq("  and its npc", c.pet_npc, 1860)

    -- Dismissed: the last pet seen stays. Everyone the Roster draws is logged
    -- out, often with the pet put away.
    WoW.pet = nil
    c = scanAs("WARLOCK")
    eq("a dismissed pet is remembered", c.pet_display, 1132)

    -- Another class with a pet out (a priest's mind control, say) records none.
    WoW.reset()
    AltStableDB = {}
    WoW.pet = { guid = "Creature-0-1-0-1-1860-0", name = "Thrall" }
    WoW.creatureDisplays = { [1860] = 1132 }
    c = scanAs("PRIEST")
    eq("only hunters and warlocks have a pet", c.pet_display, nil)

    WoW.player.class = savedClass
    WoW.reset()
    AltStableDB = {}
end

------------------------------------------------------------
-- A1 (docs/AUDIT.md): an uncached slot keeps the previous scan's values
------------------------------------------------------------
-- ResetCharacter zeroes every gear field before the gear loop, so an uncached
-- slot used to "keep" those zeros, and a Warband bag update stamped them as
-- fact a second later. The previous scan's level, quality, name and subtype
-- stay while the same item is in the slot; a different uncached item is
-- unknown and reads 0/"" until the cache answers (declared).
do
    WoW.reset()
    WoW.items[5002] = { name = "A Helm", quality = 3, ilvl = 55,
                        itemType = "Armor", subType = "Mail", equipLoc = "INVTYPE_HEAD" }
    WoW.equipped[1] = "|Hitem:5002|h[A Helm]|h"
    AltStableDB = {}
    AltStable.PendingGearSlots = nil
    AltStable.ScanCharacter()
    local me = AltStableDB[UnitGUID("player")] or {}
    eq("a cached helm scans its level", me.gear_head, 55)
    local stamped = me.lastUpdate

    -- A fresh login: the link is known, the item is not in the cache yet.
    WoW.items[5002] = nil
    AltStable.ScanCharacter()
    me = AltStableDB[UnitGUID("player")] or {}
    eq("A1: an uncached slot keeps the previous scan's level", me.gear_head, 55)
    eq("  its quality", me.gearq_head, 3)
    eq("  its name", me.gearname_head, "A Helm")
    eq("  and its subtype", me.gearsubtype_head, "Mail")
    eq("  the id is still written", me.gearid_head, 5002)
    check("  and the slot waits for the cache event",
          AltStable.PendingGearSlots ~= nil and AltStable.PendingGearSlots.head ~= nil)
    eq("  lastUpdate is withheld while a slot is pending", me.lastUpdate, stamped)

    -- The same item id under another link (a suffixed variant has another
    -- name): not the same item, so nothing is kept (Codex, PR #280).
    WoW.equipped[1] = "|Hitem:5002:0:0:0:0:0:123|h[A Helm of the Monkey]|h"
    AltStable.ScanCharacter()
    me = AltStableDB[UnitGUID("player")] or {}
    eq("  the same id under another link is unknown: no level", me.gear_head, 0)
    eq("  and no name", me.gearname_head, "")
    eq("  with the id still written", me.gearid_head, 5002)

    -- A different item, also uncached: unknown, not the old item's values.
    WoW.equipped[1] = "|Hitem:5003|h[Other Helm]|h"
    AltStable.ScanCharacter()
    me = AltStableDB[UnitGUID("player")] or {}
    eq("  a different uncached item reads 0 until the cache answers", me.gear_head, 0)
    eq("  and no name", me.gearname_head, "")
    eq("  with the new id", me.gearid_head, 5003)

    WoW.equipped[1] = nil
    AltStable.PendingGearSlots = nil
    WoW.reset()
    AltStableDB = {}
end

------------------------------------------------------------
-- A2 (docs/AUDIT.md): an empty skill list leaves the stored professions
------------------------------------------------------------
-- A character always has header lines, so zero lines is "not readable", not
-- "no skills": the stored values stay, as reputations already do. A list
-- that is there still clears a profession it no longer lists.
do
    local savedLines = WoW.skillLines
    local c = { prof1 = "Alchemy", prof1Skill = 120, prof1Max = 300, prof_Alchemy = 120, profmax_Alchemy = 300,
                prof2 = "Herbalism", prof_Herbalism = 47, fishing = 42, fishingMax = 150, cooking = 77 }
    WoW.skillLines = {}
    AltStable.ScanSkills(c)
    eq("A2: an empty skill list leaves the stored professions alone", c.prof1, "Alchemy")
    eq("  and their ranks", c.prof_Alchemy, 120)
    eq("  and the secondaries", c.fishing, 42)
    WoW.skillLines = {
        { name = "Class Skills", isHeader = true,  rank = 0,   maxRank = 0,   skillID = 7 },
        { name = "Alchemy",      isHeader = false, rank = 125, maxRank = 300, skillID = 171 },
    }
    AltStable.ScanSkills(c)
    eq("  a list that is there clears a profession it no longer lists", c.prof_Herbalism, nil)
    eq("  and prof2 with it", c.prof2, "")
    eq("  while the listed one updates", c.prof_Alchemy, 125)
    eq("  and a secondary no longer listed reads 0", c.fishing, 0)

    -- The real path: a login whose skill list is empty keeps the professions
    -- the last scan stored (the reset used to run before the list was read).
    AltStableDB = {}
    AltStable.ScanCharacter()
    local me = AltStableDB[UnitGUID("player")] or {}
    eq("a full scan records the profession", me.prof_Alchemy, 125)
    WoW.skillLines = {}
    AltStable.ScanCharacter()
    me = AltStableDB[UnitGUID("player")] or {}
    eq("  and a rescan with an empty list keeps it", me.prof_Alchemy, 125)
    eq("  and prof1", me.prof1, "Alchemy")

    WoW.skillLines = savedLines
    WoW.reset()
    AltStableDB = {}
end

------------------------------------------------------------
-- A3 (docs/AUDIT.md): a failed identity read keeps the stored value
------------------------------------------------------------
-- The name and the display id are the two reads with a known failure value
-- (nil and 0). A record that loses its name is an orphan to the Warband
-- store, and a 0 display id syncs as fact. Both keep the old value, as the
-- faction already does.
do
    WoW.reset()
    AltStableDB = {}
    AltStable.ScanCharacter()
    local me = AltStableDB[UnitGUID("player")] or {}
    eq("a scan stores the name", me.name, "Example Surname")
    eq("  and the display id", me.displayid, 56658)

    local savedName, savedDisplay = WoW.player.name, WoW.displayID
    WoW.player.name = ""          -- UnitName gives nothing: PlayerFullName is nil
    WoW.displayID = nil           -- no display id from the client: the read is 0
    AltStable.ScanCharacter()
    me = AltStableDB[UnitGUID("player")] or {}
    eq("A3: a scan that cannot read the name keeps the stored one", me.name, "Example Surname")
    eq("  and one that cannot read the display id keeps the stored one", me.displayid, 56658)

    WoW.player.name, WoW.displayID = savedName, savedDisplay
    AltStable.ScanCharacter()
    me = AltStableDB[UnitGUID("player")] or {}
    eq("  a readable name is written", me.name, "Example Surname")
    WoW.reset()
    AltStableDB = {}
end


------------------------------------------------------------
-- Helm and cloak (#485): never from ShowingHelm, never reset by a scan; the
-- scan hands the record to Drawn.lua for a reading that came before it.
do
    WoW.reset()
    AltStableDB = {}
    local realDrawn, handed = AltStable.Drawn, nil
    AltStable.Drawn = { OnScanned = function(char) handed = char end }
    local realHelm, realCloak = ShowingHelm, ShowingCloak
    ShowingHelm = function() return false end
    ShowingCloak = function() return false end
    pcall(AltStable.ScanCharacter)
    local me = AltStableDB[UnitGUID("player")]
    check("a scan hands its record to the drawn reader", me ~= nil and handed == me)
    eq("  and writes no helm flag of its own (ShowingHelm says hidden for everything)", me and me.hidehelm, nil)
    eq("  nor a cloak flag", me and me.hidecloak, nil)
    me.hidehelm, me.hidecloak, me.drawnAt = 1, 0, 5
    pcall(AltStable.ScanCharacter)
    check("  a flag the reader wrote survives the next scan", me.hidehelm == 1 and me.hidecloak == 0)
    ShowingHelm, ShowingCloak = realHelm, realCloak
    AltStable.Drawn = realDrawn
    AltStableDB = {}
    WoW.reset()
end
-- The Legacy talents (#500): the scan hands its record over the same way, for
-- a reading that came before the record existed.
do
    WoW.reset()
    AltStableDB = {}
    local realLegacy, handed = AltStable.LegacyTalents, nil
    AltStable.LegacyTalents = { OnScanned = function(char) handed = char end }
    pcall(AltStable.ScanCharacter)
    local me = AltStableDB[UnitGUID("player")]
    check("a scan hands its record to the Legacy talents reader", me ~= nil and handed == me)
    AltStable.LegacyTalents = realLegacy
    AltStableDB = {}
    WoW.reset()
end

------------------------------------------------------------
-- Hearthstone (#371)
------------------------------------------------------------
-- GetBindLocation() names the inn. The scan stores it as `bind`, and keeps
-- the last one while the client has no answer (early login).
do
    WoW.reset()
    WoW.bindLocation = "Thunderbrew Distillery"
    local API = AltStable.API
    eq("the inn is read", API.BindLocation(), "Thunderbrew Distillery")
    WoW.bindLocation = nil
    eq("  an empty answer is unknown", API.BindLocation(), nil)
    WoW.bindLocation = WoW.secret("Somewhere")
    eq("  so is a secret one", API.BindLocation(), nil)
    WoW.bindLocation = "Two\nLines"
    eq("  a line break can't split the wire line", API.BindLocation(), "Two Lines")
    local real = GetBindLocation
    GetBindLocation = function() error("boom") end
    eq("  a call that throws is unknown", API.BindLocation(), nil)
    GetBindLocation = real

    AltStableDB = {}
    WoW.bindLocation = "Gallows' End Tavern"
    pcall(AltStable.ScanCharacter)
    local c = AltStableDB[UnitGUID("player")]
    eq("the scan stores the inn", c and c.bind, "Gallows' End Tavern")
    WoW.bindLocation = nil
    pcall(AltStable.ScanCharacter)
    eq("  and keeps it when the client has no answer yet", c and c.bind, "Gallows' End Tavern")

    -- The column: on Account Summary, before Last Online, sorted as text.
    local col
    for _, x in ipairs(AltStable.Columns) do if x.field == "bind" then col = x end end
    check("a Hearthstone column exists", col ~= nil)
    check("  sorted as text", col and col.sortText)
    check("  on Account Summary, after Bags",
          io.open("SheetUI.lua"):read("*a"):find('"bags_free","bind","lastUpdate"', 1, true) ~= nil)
    if col then
        local row = AltStable.CreateRow(nil, 20, { col })
        AltStable.RenderRow(row, { guid = "Player-Hs-1", name = "H", bind = "The Crossroads" }, 1, { col })
        eq("  it shows the inn", row.cells[1]:GetText(), "The Crossroads")
        AltStable.RenderRow(row, { guid = "Player-Hs-1", name = "H" }, 1, { col })
        eq("  and is blank before the first read", row.cells[1]:GetText(), "")
    end
    AltStableDB = {}
    WoW.reset()
end

------------------------------------------------------------
-- Time played (#378): the column and its cell
------------------------------------------------------------
do
    dofile("Played.lua")
    AltStable._test.ResetPlayed()
    -- A reply before the first scan made the record: the scan writes it
    -- (Codex review of #496).
    WoW.reset()
    AltStableDB = {}
    AltStable.Played.OnReply(500, 50)
    pcall(AltStable.ScanCharacter)
    local me = AltStableDB[UnitGUID("player")]
    eq("a reply before the record is written by the first scan", me and me.played, 500)
    eq("  with the level's time", me and me.playedLevel, 50)
    AltStable._test.ResetPlayed()
    AltStableDB = {}
    local col
    for _, x in ipairs(AltStable.Columns) do if x.field == "played" then col = x end end
    check("a Played column exists", col ~= nil)
    check("  on Account Summary, after Last Online",
          io.open("SheetUI.lua"):read("*a"):find('"bind","lastUpdate","played"', 1, true) ~= nil)
    if col then
        eq("  sorted by the time played", col.sortValue({ played = 50 }), 50)
        eq("  unknown sorts as nothing (last)", col.sortValue({}), nil)
        local row = AltStable.CreateRow(nil, 20, { col })
        local char = { guid = "Player-Pl-1", name = "P", played = 212 * 86400 + 4 * 3600, playedLevel = 3600 }
        AltStable.RenderRow(row, char, 1, { col })
        eq("  the cell is compact", row.cells[1]:GetText(), "212d 4h")
        local tip = row.cellTips[1]
        check("  it has a tooltip", tip ~= nil)
        eq("  in words", tip and tip.line1, "Played: 7 months, 2 days, 4 hours")
        eq("  with the time at this level", tip and tip.line2, "At this level: 1 hour")
        eq("  as of the last time played, months explained", tip and tip.line3,
           "As of when it was last played (a month is 30 days, a year 365)")
        char.played = 5 * 3600
        AltStable.RenderRow(row, char, 1, { col })
        eq("  no months, nothing to explain", tip and tip.line3, "As of when it was last played")
        AltStable.RenderRow(row, { guid = "Player-Pl-2", name = "Q" }, 1, { col })
        eq("  unknown: a dim dash, not a 0", row.cells[1]:GetText(), "|cff888888\226\128\148|r")
        eq("  and the tooltip says so", tip and tip.line1, "Played: not known yet")
        eq("  and when it will be", tip and tip.line2, "Read the next time this character logs in.")
    end
    AltStableDB = {}
    WoW.reset()
end

------------------------------------------------------------
-- Merchant's Favor (#270)
------------------------------------------------------------
-- C_CurrencyInfo.GetCurrencyInfo returns a struct, the amount in `quantity`
-- (measured on 70938). Per character: the scan stores it as `favor`.
do
    WoW.reset()
    local API = AltStable.API
    eq("the currency is Wowhead's 3402", AltStable.FAVOR_CURRENCY, 3402)
    WoW.currencies[3402] = 12
    eq("the quantity is read from the struct", API.CurrencyQuantity(3402), 12)
    eq("  a currency the character never earned reads as 0", API.CurrencyQuantity(9999), 0)
    WoW.currencies[3402] = WoW.secret(7)
    eq("  a secret quantity reads as unknown, not as a number", API.CurrencyQuantity(3402), nil)
    local realGet = API.GetCurrencyInfo
    API.GetCurrencyInfo = function() error("boom") end
    eq("  a call that throws reads as unknown", API.CurrencyQuantity(3402), nil)
    API.GetCurrencyInfo = function() return nil end
    eq("  and so does no struct", API.CurrencyQuantity(3402), nil)
    API.GetCurrencyInfo = nil
    eq("  and a client without the call", API.CurrencyQuantity(3402), nil)
    API.GetCurrencyInfo = realGet

    WoW.currencies[3402] = 40
    AltStableDB = {}
    pcall(AltStable.ScanCharacter)
    local c = AltStableDB[UnitGUID("player")]
    eq("the scan stores the character's Favor", c and c.favor, 40)

    -- The column: on the Skills tab, after Riding, blank at none.
    local col
    for _, x in ipairs(AltStable.Columns) do if x.field == "favor" then col = x end end
    check("a Merchant's Favor column exists", col ~= nil)
    check("  in the professions' group, with the currency's icon",
          col and col.group == "prof" and col.profIcon == 135725)
    check("  on the Skills tab, after Riding",
          io.open("SheetUI.lua"):read("*a"):find('"riding","favor"', 1, true) ~= nil)
    if col then
        local row = AltStable.CreateRow(nil, 20, { col })
        AltStable.RenderRow(row, { guid = "Player-Fav-1", name = "F", favor = 25 }, 1, { col })
        eq("  a character with Favor shows the amount", row.cells[1]:GetText(), "25")
        AltStable.RenderRow(row, { guid = "Player-Fav-1", name = "F", favor = 0 }, 1, { col })
        eq("  none is blank, not a column of zeros", row.cells[1]:GetText(), "")
        AltStable.RenderRow(row, { guid = "Player-Fav-1", name = "F" }, 1, { col })
        eq("  and so is never read", row.cells[1]:GetText(), "")
    end
    AltStableDB = {}
    WoW.reset()
end


------------------------------------------------------------
-- Bag space (#346)
------------------------------------------------------------
-- The carried bags (backpack + the four slots) that take anything are counted;
-- a special bag (a family, or the reagent bag) is listed but not counted. The
-- bank is read only while it is open. Every field is flat, so it syncs.
do
    WoW.reset()
    local function full(n) local b = { size = n }; for i = 1, n do b[i] = { itemID = 1 } end; return b end
    local function setBags()
        WoW.containers = {
            [0] = { size = 16, [1] = { itemID = 1 }, [2] = { itemID = 2 } },   -- 14 free
            [1] = { size = 6 },                                                -- Linen Bag, 6 free
            [3] = { size = 8, family = 1 },                                    -- a quiver: not counted
            [4] = full(6),                                                     -- Linen Bag, full
        }
        WoW.equipped[31] = "item:4245"; WoW.equipped[33] = "item:2101"; WoW.equipped[34] = "item:4245"
        WoW.equipped[32] = nil; WoW.equipped[35] = nil
    end
    setBags()
    local s = AltStable.ReadBagSpace()
    check("the bags are read", s ~= nil)
    if s then
        eq("  the counted slots: backpack and the ordinary bags", s.slots, 28)
        eq("  and their free slots", s.free, 20)
        eq("  the backpack has no item", s.bags[0], "0,16,0")
        eq("  a bag: its item, slots and family", s.bags[1], "4245,6,0")
        eq("  an empty bag slot", s.bags[2], "0,0,0")
        eq("  a special bag keeps its family", s.bags[3], "2101,8,1")
        eq("  no reagent bag: nothing for it", s.bags[5], nil)
    end
    WoW.containers[5] = { size = 12, family = 0 }; WoW.equipped[35] = "item:9000"
    s = AltStable.ReadBagSpace()
    eq("a reagent bag is listed", s and s.bags[5], "9000,12,0")
    eq("  and not counted", s and s.slots, 28)
    WoW.containers[5] = nil; WoW.equipped[35] = nil

    WoW.containers[1] = nil
    eq("a bag whose size has not arrived: the read is unknown", AltStable.ReadBagSpace(), nil)
    setBags(); WoW.containers[0].size = 0
    eq("  and so is a backpack of no slots", AltStable.ReadBagSpace(), nil)
    setBags()

    local char = { bag_5 = "9000,12,0" }
    check("a first read changes the record", AltStable.ScanBagSpace(char))
    eq("  the counted slots", char.bags_slots, 28)
    eq("  the free ones", char.bags_free, 20)
    eq("  each bag", char.bag_1, "4245,6,0")
    eq("  a bag taken off goes", char.bag_5, nil)
    check("  a second read of the same bags changes nothing", not AltStable.ScanBagSpace(char))
    WoW.containers[1][1] = { itemID = 7 }
    check("  a looted item changes it", AltStable.ScanBagSpace(char))
    eq("  one free slot fewer", char.bags_free, 19)
    WoW.containers[1] = nil
    check("an unknown read writes nothing", not AltStable.ScanBagSpace(char))
    eq("  and keeps the last", char.bags_free, 19)
    setBags()

    -- The bank: its purchased tabs, each with its slots.
    WoW.bankTabs = { 6, 7 }
    WoW.containers[6] = { size = 48, [1] = { itemID = 1 } }
    WoW.containers[7] = { size = 48 }
    local b = {}
    check("the bank is read", AltStable.ScanBankSpace(b))
    eq("  its tabs", b.bank_tabs, 2)
    eq("  their slots", b.bank_slots, 96)
    eq("  and the free ones", b.bank_free, 95)
    eq("  as of now", b.bank_at, time())
    -- Container 7 is purchased bag slot 2 (#439): with a bag in it, 0 slots
    -- means its slots haven't arrived.
    WoW.containers[7] = { size = 0 }
    WoW.bankBags = { [2] = true }
    local b2 = {}
    check("a tab whose slots have not arrived: nothing is written", not AltStable.ScanBankSpace(b2))
    eq("  no tabs", b2.bank_tabs, nil)
    -- With no bag in it, 0 slots is an empty bag slot: the bank reads (#439).
    WoW.bankBags = {}
    local b3 = {}
    check("#439: an empty purchased bag slot doesn't stop the read", AltStable.ScanBankSpace(b3))
    eq("  its tabs are still both purchased ones", b3.bank_tabs, 2)
    eq("  its slots are the main bank's", b3.bank_slots, 48)
    eq("  and the free ones", b3.bank_free, 47)
    -- The main bank at 0 is never "empty": not loaded yet.
    WoW.containers[6] = { size = 0 }
    check("  the main bank at 0 slots: nothing is written", not AltStable.ScanBankSpace({}))
    WoW.containers[6] = { size = 48, [1] = { itemID = 1 } }
    -- Without the API to tell, a 0 is not trusted.
    local realExists = C_Item.DoesItemExist
    C_Item.DoesItemExist = nil
    check("  no C_Item.DoesItemExist: a 0 aborts", not AltStable.ScanBankSpace({}))
    C_Item.DoesItemExist = realExists
    WoW.containers[7] = { size = 48 }

    -- The scan writes the bags (not the bank: it waits for a visit).
    AltStableDB = {}
    pcall(AltStable.ScanCharacter)
    local c = AltStableDB[UnitGUID("player")]
    eq("the scan stores the bag space", c and c.bags_free, 20)
    eq("  not the bank", c and c.bank_tabs, nil)

    -- The column: on the Account Summary tab, after Gold.
    local col
    for _, x in ipairs(AltStable.Columns) do if x.field == "bags_free" then col = x end end
    check("a Bags column exists", col ~= nil and col.type == "bags")
    check("  on the Account Summary tab, after Gold",
          io.open("SheetUI.lua"):read("*a"):find('"money","bags_free",', 1, true) ~= nil)
    eq("the cell: free of total", AltStable.FormatBagSpace({ bags_slots = 72, bags_free = 14 }), "14/72")
    eq("  orange with a tenth or less left", AltStable.FormatBagSpace({ bags_slots = 72, bags_free = 7 }),
       "|cffff88007/72|r")
    eq("  red when full", AltStable.FormatBagSpace({ bags_slots = 72, bags_free = 0 }), "|cffff20200/72|r")
    eq("  blank before it is read", AltStable.FormatBagSpace({}), "")
    if col then
        local row = AltStable.CreateRow(nil, 20, { col })
        AltStable.RenderRow(row, c, 1, { col })
        eq("  a row shows it", row.cells[1]:GetText(), "20/28")
        local t = row.cellTips[1]
        if t then t:GetScript("OnEnter")(t) end
        check("  with a tooltip", t ~= nil and t.line1 == "Bags: 20 free of 28")
    end

    -- The tooltip: the bags in slot order, the bank, the spare bags.
    WoW.items[4245] = { name = "Linen Bag", classID = 1, subType = "Bag" }
    WoW.items[2101] = { name = "Light Quiver", classID = 11, subType = "Quiver" }
    WoW.items[2589] = { name = "Linen Cloth", classID = 7, subType = "Cloth" }
    WoW.items[856]  = { classID = 1, subType = "Bag" }   -- known class, name not cached
    c.bank_tabs, c.bank_slots, c.bank_free, c.bank_at = 2, 96, 95, time() - 120
    local heldMaps = AltStable.ItemMapsFor
    AltStable.ItemMapsFor = function(guid)
        if guid ~= c.guid then return nil end
        return { bags = { [4245] = 2, [2589] = 5 }, bank = { [4245] = 1, [856] = 1 } }
    end
    WoW.itemLoadRequests = {}
    local title, lines = AltStable.BagSpaceTooltip(c)
    eq("the tooltip's title", title, "Bags: 20 free of 28")
    local text = table.concat(lines, "|")
    eq("  the bags in slot order", table.concat({ lines[1], lines[2], lines[3], lines[4], lines[5] }, "|"),
       "Backpack: 16 slots|Linen Bag: 6 slots||cff888888Empty bag slot|r"
       .. "|Light Quiver: 8 slots |cff888888(Quiver, not counted)|r|Linen Bag: 6 slots")
    check("  the bank: tabs of the most, free of its slots",
          text:find("Bank: 2 of 9 tabs, 95 free of 96", 1, true) ~= nil, text)
    check("  and when it was seen", text:find("Last visit:|r |cff88ff882m ago|r", 1, true) ~= nil, text)
    check("  the spare bags, carried", text:find("  Linen Bag x2 |cff888888(carried)|r", 1, true) ~= nil, text)
    check("  and in the bank", text:find("  Linen Bag |cff888888(in the bank)|r", 1, true) ~= nil, text)
    check("  a bag not cached yet by its id", text:find("  item 856 |cff888888(in the bank)|r", 1, true) ~= nil, text)
    eq("  whose name is asked for", WoW.itemLoadRequests[1], 856)
    check("  cloth is not a bag", not text:find("Linen Cloth", 1, true))
    -- Built on hover, from the data as it is then (Codex review of #347): the
    -- plugin's map and a bag's name can arrive after the row was drawn.
    local bcol
    for _, x in ipairs(AltStable.Columns) do if x.field == "bags_free" then bcol = x end end
    local brow = AltStable.CreateRow(nil, 20, { bcol })
    AltStable.RenderRow(brow, c, 1, { bcol })
    local btip = brow.cellTips[1]
    local function Hover()
        btip:GetScript("OnEnter")(btip)
        return table.concat(btip.cdLines or {}, "|")
    end
    check("a hover shows the spare bags", Hover():find("  item 856 |cff888888(in the bank)|r", 1, true) ~= nil)
    WoW.items[856].name = "Small Brown Pouch"
    AltStable.ItemMapsFor = function() return { bags = { [4245] = 3 } } end
    local after = Hover()
    check("  a name loaded since is shown at the next hover", not after:find("item 856", 1, true), after)
    check("  and the plugin's newer map", after:find("  Linen Bag x3 |cff888888(carried)|r", 1, true) ~= nil, after)
    c.bags_free = 5
    btip:GetScript("OnEnter")(btip)
    eq("  and the record as it is", btip.line1, "Bags: 5 free of 28")
    c.bags_free = 20

    AltStable.ItemMapsFor = nil
    _, lines = AltStable.BagSpaceTooltip(c)
    check("without the Warband plugin, no spare bags", not table.concat(lines, "|"):find("Spare", 1, true))
    _, lines = AltStable.BagSpaceTooltip({ bags_slots = 20, bags_free = 3 })
    check("a bank never visited says so",
          table.concat(lines, "|"):find("Bank: not visited with this version yet", 1, true) ~= nil)
    AltStable.ItemMapsFor = heldMaps

    -- A profession's cooldowns show on its column's tooltip also when the core
    -- has no rank for it (#460): the Professions plugin can know a leatherworker,
    -- and its Salt Shaker, before the core's scan does.
    do
        local lcol
        for _, x in ipairs(AltStable.Columns) do
            if x.type == "profSkill" and x.label == "Leatherworking" then lcol = x end
        end
        local lw = { guid = "Player-LW-1", name = "Tanner", class = "ROGUE",
                     ["cd_Leatherworking@Salt Shaker"] = time() + 2 * 86400 + 3 * 3600 }
        local lrow = AltStable.CreateRow(nil, 20, { lcol })
        AltStable.RenderRow(lrow, lw, 1, { lcol })
        local ltip = lrow.cellTips[1]
        local text = table.concat(ltip and ltip.cdLines or {}, "|")
        check("#460: the Leatherworking tooltip lists the Shaker with no rank recorded",
              text:find("Salt Shaker: 2d 3h", 1, true) ~= nil, text)
        lw["cd_Leatherworking@Salt Shaker"] = time() - 60
        AltStable.RenderRow(lrow, lw, 1, { lcol })
        text = table.concat(ltip and ltip.cdLines or {}, "|")
        check("  and Ready! once it is over", text:find("Salt Shaker: Ready!", 1, true) ~= nil, text)
    end

    -- Live: after each batch of bag updates, and the bank while it is open.
    local frame = AltStable._test.frame
    local onEvent = frame:GetScript("OnEvent")
    for _, e in ipairs({ "BAG_UPDATE_DELAYED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "BANK_TABS_CHANGED" }) do
        check("the core listens for " .. e, frame:IsEventRegistered(e))
    end
    c.lastUpdate = 1
    WoW.containers[0][3] = { itemID = 3 }
    onEvent(frame, "BAG_UPDATE_DELAYED")
    eq("a bag update is read at once", c.bags_free, 19)
    check("  and stamps the record", c.lastUpdate > 1)
    c.lastUpdate = 1
    onEvent(frame, "BAG_UPDATE_DELAYED")
    eq("  nothing changed: no stamp", c.lastUpdate, 1)
    c.bank_tabs, c.bank_at = nil, nil
    onEvent(frame, "BAG_UPDATE_DELAYED")
    eq("  the bank shut: it is not read", c.bank_tabs, nil)
    onEvent(frame, "BANKFRAME_OPENED")
    eq("opening the bank reads it", c.bank_tabs, 2)
    WoW.bankTabs = { 6, 7, 8 }; WoW.containers[8] = { size = 48 }
    onEvent(frame, "BANK_TABS_CHANGED", Enum.BankType.Account)
    eq("  the account bank's tabs are not ours", c.bank_tabs, 2)
    onEvent(frame, "BANK_TABS_CHANGED", Enum.BankType.Character)
    eq("  a tab bought is", c.bank_tabs, 3)
    WoW.containers[6][2] = { itemID = 2 }
    onEvent(frame, "BAG_UPDATE_DELAYED")
    eq("  an item put in the bank", c.bank_free, 142)
    onEvent(frame, "BANKFRAME_CLOSED")
    WoW.containers[6][3] = { itemID = 3 }
    onEvent(frame, "BAG_UPDATE_DELAYED")
    eq("  shut again, it keeps the last visit", c.bank_free, 142)

    AltStableDB = {}
    WoW.reset()
end

WoW.finish("test_scanner", passed, failed)
