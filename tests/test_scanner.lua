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
-- CVar-backed settings store
--
-- SavedVariables are written and never read back on this client (#23), so the
-- settings that cannot be regenerated live in a CVar instead. These assert the
-- round-trip, the delimiters, and the two traps that make a working store look
-- broken: registering before reading, and a write that silently truncates.
------------------------------------------------------------

WoW.cvars = {}
WoW.cvarLimit = nil
AltStableConfig = { whitelist = {} }

Slash("whitelist Karuzo Elegia")
Slash("whitelist Second Surname-RealmName")
AltStableConfig.accountNumber = "2"
check("saving reports success", AltStable.SaveConfigToCVar() == true)
check("  and something reached the cvar",
      type(WoW.cvars["altstable_config"]) == "string" and #WoW.cvars["altstable_config"] > 0,
      tostring(WoW.cvars["altstable_config"]))

-- A fresh session: the table is empty, exactly as #23 leaves it.
AltStableConfig = {}
AltStable.EnsureConfigDefaults()
eq("the whitelist survives a session", #AltStableConfig.whitelist, 2)
eq("  two-word name intact", AltStableConfig.whitelist[1], "Karuzo Elegia")
eq("  realm suffix intact", AltStableConfig.whitelist[2], "Second Surname-RealmName")
eq("  account number intact", AltStableConfig.accountNumber, "2")

-- Delimiters in a value must not split it. Forever names are space-separated
-- and cross-realm peers carry a suffix; neither is worth trusting to luck.
AltStableConfig = { whitelist = { "Semi;Colon", "Com,ma", "Equals=Sign", "Per%cent" } }
check("awkward names save", AltStable.SaveConfigToCVar() == true)
AltStableConfig = {}
AltStable.EnsureConfigDefaults()
eq("a semicolon survives", AltStableConfig.whitelist[1], "Semi;Colon")
eq("a comma survives", AltStableConfig.whitelist[2], "Com,ma")
eq("an equals survives", AltStableConfig.whitelist[3], "Equals=Sign")
eq("a percent survives", AltStableConfig.whitelist[4], "Per%cent")
eq("  and the list is not split by them", #AltStableConfig.whitelist, 4)

-- Booleans round-trip as themselves, not as truthy strings.
AltStableConfig = { whitelist = {}, sendAllAccounts = true, toastsEnabled = false }
AltStable.SaveConfigToCVar()
AltStableConfig = {}
AltStable.EnsureConfigDefaults()
eq("a true boolean survives", AltStableConfig.sendAllAccounts, true)
eq("a false boolean survives, rather than reverting to its default",
   AltStableConfig.toastsEnabled, false)

-- The dangerous failure: a write that is accepted but truncated. It reads back
-- as success unless someone checks, and takes half a whitelist with it.
WoW.cvars = {}
AltStableConfig = { whitelist = { "Aaaaaaaa Aaaaaaaa", "Bbbbbbbb Bbbbbbbb", "Cccccccc Cccccccc" } }
WoW.cvarLimit = 30
WoW.chatOut = {}
local saved, why = AltStable.SaveConfigToCVar()
eq("a truncated write is reported as failure", saved, false)
eq("  with a reason", why, "round-trip mismatch")
check("  and says so in chat",
      #WoW.chatOut > 0 and WoW.chatOut[#WoW.chatOut]:find("did not survive", 1, true) ~= nil,
      WoW.chatOut[#WoW.chatOut] or "(nothing printed)")
WoW.cvarLimit = nil

-- Registering an existing cvar overwrites it with the default, so a store that
-- registers before reading destroys the value it came for. The stub models
-- that, so this test fails loudly if the order is ever reversed.
WoW.cvars = {}
AltStableConfig = { whitelist = { "Karuzo Elegia" } }
AltStable.SaveConfigToCVar()
local stored = WoW.cvars["altstable_config"]
AltStableConfig = {}
AltStable.EnsureConfigDefaults()
eq("loading does not register over the stored value", WoW.cvars["altstable_config"], stored)
eq("  so the whitelist is still there", AltStableConfig.whitelist[1], "Karuzo Elegia")

-- A client with no CVar API at all degrades quietly rather than erroring.
local realGet, realSet, realRegister = GetCVar, SetCVar, RegisterCVar
GetCVar, SetCVar, RegisterCVar = nil, nil, nil
AltStableConfig = {}
local okNoCVar = pcall(AltStable.EnsureConfigDefaults)
check("a client without CVars still loads defaults", okNoCVar)
eq("  with an empty whitelist rather than an error", #AltStableConfig.whitelist, 0)
local okSave, saveErr = AltStable.SaveConfigToCVar()
eq("  and saving reports failure instead of throwing", okSave, false)
eq("  with a reason", saveErr, "no SetCVar")
GetCVar, SetCVar, RegisterCVar = realGet, realSet, realRegister

------------------------------------------------------------
-- Did the client update?
--
-- Every measured finding belongs to one build, and nobody watches the
-- launcher. The build rides in the store - the only thing that persists on
-- this client - so a mismatch at login can say so.
------------------------------------------------------------

WoW.cvars = {}
AltStableConfig = {}
WoW.chatOut = {}
AltStable.EnsureConfigDefaults()
AltStable.CheckClientBuild()
check("a first run says nothing about the build", #WoW.chatOut == 0, WoW.chatOut[1] or "")
eq("  but records the build it ran on", AltStableConfig.clientBuild, "69913")

-- Same build again: silence. This runs at every login, so a chatty version
-- would be worse than no check at all.
WoW.chatOut = {}
AltStableConfig = {}
AltStable.EnsureConfigDefaults()
AltStable.CheckClientBuild()
eq("the stored build survives a session", AltStableConfig.clientBuild, "69913")
check("  and an unchanged build stays quiet", #WoW.chatOut == 0, WoW.chatOut[1] or "")

-- The client updates underneath us.
local realBuildInfo = GetBuildInfo
GetBuildInfo = function() return "1.60.2", "70001", "Oct 01 2026", 16001 end
WoW.chatOut = {}
AltStableConfig = {}
AltStable.EnsureConfigDefaults()
AltStable.CheckClientBuild()
check("a changed build is announced",
      #WoW.chatOut > 0 and WoW.chatOut[1]:find("build changed", 1, true) ~= nil,
      WoW.chatOut[1] or "(nothing printed)")
check("  naming both builds",
      #WoW.chatOut > 0 and WoW.chatOut[1]:find("69913", 1, true) ~= nil
      and WoW.chatOut[1]:find("70001", 1, true) ~= nil, WoW.chatOut[1] or "")
check("  and what to re-check",
      #WoW.chatOut > 0 and WoW.chatOut[1]:find("/apidump", 1, true) ~= nil
      and WoW.chatOut[1]:find("#23", 1, true) ~= nil, WoW.chatOut[1] or "")
eq("  then records the new build", AltStableConfig.clientBuild, "70001")

-- And stops announcing it once recorded.
WoW.chatOut = {}
AltStableConfig = {}
AltStable.EnsureConfigDefaults()
AltStable.CheckClientBuild()
check("the new build is then quiet too", #WoW.chatOut == 0, WoW.chatOut[1] or "")
GetBuildInfo = realBuildInfo

------------------------------------------------------------
-- Has the client been fixed?
--
-- The store is a workaround, and workarounds outlive their cause silently.
-- svLoadCheck can only come back if the client actually read the file.
------------------------------------------------------------

AltStableConfig = {}
WoW.chatOut = {}
AltStable.CheckSavedVariablesLoad()
check("a first run says nothing", #WoW.chatOut == 0, WoW.chatOut[1] or "")
check("  but leaves a marker for next time",
      type(AltStableConfig.svLoadCheck) == "table" and AltStableConfig.svLoadCheck.stamp ~= nil)

-- Simulate the client starting to load SavedVariables again: the marker is
-- present at login because the file came back.
WoW.chatOut = {}
AltStable.CheckSavedVariablesLoad()
check("a marker that survived is announced",
      #WoW.chatOut > 0 and WoW.chatOut[1]:find("SavedVariables loaded", 1, true) ~= nil,
      WoW.chatOut[1] or "(nothing printed)")
check("  and names the issue to retire",
      #WoW.chatOut > 0 and WoW.chatOut[1]:find("#23", 1, true) ~= nil,
      WoW.chatOut[1] or "")

------------------------------------------------------------

print(("test_scanner: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
