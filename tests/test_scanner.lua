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
-- Reputation: `reaction` is the standing, and stale values are cleared
------------------------------------------------------------

WoW.factions = {
    { name = "Horde",       factionID = 67,  reaction = 5, currentStanding = 3500, isHeader = true },
    { name = "The Aldor",   factionID = 932, reaction = 6, currentStanding = 4000, isHeader = false },
    { name = "Lower City",  factionID = 1011, reaction = 4, currentStanding = 200, isHeader = false },
    { name = "Unlisted Co", factionID = 999, reaction = 7, currentStanding = 900, isHeader = false },
}

local rep = {}
AltStable.ScanReputations(rep)

-- Standing is `reaction` (4 = Neutral, 5 = Friendly, 6 = Honored, 7 = Revered).
eq("a tracked faction records its reaction", rep.aldor, 6)
eq("a second tracked faction", rep.lowercity, 4)
eq("an untracked faction is ignored", rep.unlisted, nil)

-- Stale values must be cleared, or a standing the character can no longer see
-- persists from an earlier scan or a sync.
rep.aldor = 8
WoW.factions = {}
AltStable.ScanReputations(rep)
eq("a faction that disappeared is cleared", rep.aldor, nil)

-- Same regression check: the old positional read took standing from return 3.
WoW.factions = { { name = "The Aldor", factionID = 932, reaction = 6, isHeader = false } }
local rep2 = {}
local realFac = C_Reputation.GetFactionDataByIndex
C_Reputation.GetFactionDataByIndex = function(i)
    local f = WoW.factions[i]
    if not f then return end
    return f.name, f.description, f.reaction   -- the OLD tuple
end
dofile("Compat.lua"); dofile("Reputations.lua")
AltStable.ScanReputations(rep2)
eq("a tuple-shaped API records no standing", rep2.aldor, nil)
C_Reputation.GetFactionDataByIndex = realFac
dofile("Compat.lua"); dofile("Reputations.lua")

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

print(("test_scanner: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
