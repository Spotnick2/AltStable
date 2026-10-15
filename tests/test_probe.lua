------------------------------------------------------------
-- test_probe.lua — Tools/AltStableProbe as a ForeverProbe module (#240)
--
-- The probe never ships, so nothing in game catches it breaking until the day
-- a measurement is needed. What has to hold:
--   * it is one module, /fp as, and every file's command is on it - a file
--     that loads before the namespace handle it needs fails at load, silently
--     to the owner, who just sees a command missing;
--   * no line reaches chat (GUIDE.md: the console and the saved log only);
--   * the saved data other tools read keeps its shape: wireLog for
--     read-wirelog.py, models, pets, prof*, the load counters;
--   * the saved tables are adopted at ADDON_LOADED, not made at file scope.
-- Local only: ForeverProbe is private, so CI skips this file.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
dofile("tests/foreverprobe.lua")
local FP = loadForeverProbe()

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. name .. (detail and ("  -- " .. detail) or "")) end
end
local function eq(name, got, want)
    check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

AltStable, AltStableDB, AltStableConfig = {}, {}, {}
dofile("Compat.lua")

-- Chat, both ways a line gets there.
local printed = {}
local realPrint = print
print = function(...) printed[#printed + 1] = table.concat({ tostring((...)) }, " ") end
WoW.chatOut = {}

-- What a session left on disk: data other tools read, and the lines the copy
-- window used to show.
local wire, models, pets = { "2026-10-01 10:00:00  [Old]  an old line" }, { g = { name = "A" } }, { k = { name = "P" } }
local ns = loadAltStableProbe(function()
    AltStableProbeDB = {
        wireLog = wire, models = models, pets = pets, prof = { { at = "x" } }, loadCount = 7,
        lines = { "stale sweep" }, lastRun = "2026-09-01", build = { "1.60.1" }, enchants = { "old" },
    }
    AltStableProbeCharDB = nil      -- a character's first run
end)
print = realPrint

local P = FP.byCmd.as
local function run(cmd) SlashCmdList.FOREVERPROBE("as " .. cmd) end
local function logText()
    local out = {}
    for _, l in ipairs(AltStableProbeDB.log or {}) do out[#out + 1] = l end
    return table.concat(out, "\n")
end

------------------------------------------------------------
-- One module, every command
------------------------------------------------------------

check("the probe is /fp as", P ~= nil and P.name == "AltStableProbe")
eq("  the namespace holds the same module", ns.Probe, P)
for _, cmd in ipairs({ "all", "client", "savedvariables", "identity", "skills", "prof", "rep", "items",
                       "containers", "bank", "tooltip", "instances", "events", "clear", "whisper",
                       "channel", "bnet", "pet", "enchant", "model", "recipes", "scene", "icon" }) do
    check("  /fp as " .. cmd .. " exists", P and P.commands[cmd] ~= nil)
end
-- The old commands are gone, and with them the global the files shared.
for _, slash in ipairs({ "ASPROBE", "ASMODEL", "ASPROF", "ASSCENE", "ASICON" }) do
    check("no /" .. slash:lower() .. " any more", rawget(_G, "SLASH_" .. slash .. "1") == nil
        and SlashCmdList[slash] == nil)
end
check("no AltStableProbe global: the files share the addon namespace", rawget(_G, "AltStableProbe") == nil)

------------------------------------------------------------
-- The saved tables
------------------------------------------------------------

local db = AltStableProbeDB
check("the saved log is bound to the module", P.log ~= nil and P.log == db.log)
eq("the wire log is the saved one, kept", db.wireLog, wire)
eq("  and so are the model captures", db.models, models)
eq("  the pet records", db.pets, pets)
check("  the trade-skill snapshots", type(db.prof) == "table" and db.prof[1].at == "x")
check("the copy window's leftovers are gone, so an old run cannot read as fresh",
      db.lines == nil and db.lastRun == nil and db.build == nil and db.enchants == nil)
check("a store that did not load is made at ADDON_LOADED", type(AltStableProbeCharDB) == "table"
    and type(AltStableProbeMachineDB) == "table")

fireProbeEvent("PLAYER_LOGIN")
eq("the account counter climbs from what loaded", db.loadCount, 8)
eq("the per-character one starts", AltStableProbeCharDB.loadCount, 1)
local text = logText()
check("  and the store that did not load says so", text:find("SavedVariablesPerCharacter", 1, true) ~= nil, text)
check("  the one that did stays quiet", text:find("SavedVariables (account)", 1, true) == nil, text)

------------------------------------------------------------
-- Every command runs, and nothing reaches chat
------------------------------------------------------------

-- Not the viewers (bare model, pet, scene): they build template frames
-- (BasicFrameTemplateWithInset's TitleText) the stubs don't model.
print = function(...) printed[#printed + 1] = table.concat({ tostring((...)) }, " ") end
for _, cmd in ipairs({ "all", "bank", "enchant", "recipes", "recipes cd", "bnet me", "channel status",
                       "model list", "model caps", "pet list", "icon cancel" }) do
    run(cmd)
end
WoW.flushTimers()
print = realPrint

text = logText()
-- A command that throws is the host's "ERROR|r /fp as <cmd>" line. A plain
-- "ERROR:" is a measurement (C_Item.GetItemIcon(6948) throws on this client).
check("no command throws", text:find("ERROR|r /fp", 1, true) == nil, text:match("[^\n]*ERROR|r /fp[^\n]*"))
check("the sweep wrote its sections", text:find("== client ==", 1, true) ~= nil
    and text:find("== events", 1, true) ~= nil)
for _, tag in ipairs({ "[enchant]", "[prof]", "[model]", "[pet]", "[icon]" }) do
    check("  and " .. tag .. " lines", text:find(tag, 1, true) ~= nil)
end
eq("nothing was printed", #printed, 0)
eq("nothing went to a chat frame", #WoW.chatOut, 0)

------------------------------------------------------------
-- The wire log, in the shape read-wirelog.py reads
------------------------------------------------------------

local before = #db.wireLog
run("whisper Other Person")
local added = #db.wireLog - before
check("a whisper test writes the wire log", added > 0)
local last = db.wireLog[#db.wireLog] or ""
check("  each line dated and signed", last:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d  %[.-%]  ") ~= nil, last)
check("  and it is in the module log too", logText():find("PONG line naming a form", 1, true) ~= nil)

------------------------------------------------------------
-- Clearing empties the bound log in place
------------------------------------------------------------

local log = db.log
run("clear")
check("clear keeps the same table (the host holds it)", db.log == log and P.log == log)
run("client")
check("  and the next line lands in it", #log > 0 and log[#log]:find("done", 1, true) ~= nil, log[#log])
local inConsole = false
for _, l in ipairs(FP.lines) do if l.m == "AltStableProbe" and l.text:find("== client ==", 1, true) then inConsole = true end end
check("  and in the console", inConsole)

print(("test_probe: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
