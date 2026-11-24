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
                       "channel", "bnet", "pet", "enchant", "model", "recipes", "scene", "icon", "ping" }) do
    check("  /fp as " .. cmd .. " exists", P and P.commands[cmd] ~= nil)
end
-- The old commands are gone, and with them the global the files shared.
for _, slash in ipairs({ "ASPROBE", "ASMODEL", "ASPROF", "ASSCENE", "ASICON" }) do
    check("no /" .. slash:lower() .. " any more", rawget(_G, "SLASH_" .. slash .. "1") == nil
        and SlashCmdList[slash] == nil)
end
check("no AltStableProbe global: the files share the addon namespace", rawget(_G, "AltStableProbe") == nil)
-- The in-game check is a procedure (CLAUDE.md: never a checklist in chat).
local proc = FP.procedures and FP.procedures["AltStableProbe/check"]
check("/fp steps as check is defined", proc ~= nil and #proc.steps >= 2)
check("  and ends with a /reload, so its answers reach the disk",
      proc ~= nil and proc.steps[#proc.steps].reload == true)
-- The icon reading's own, on the sheet: one question per thing to see.
local iconProc = FP.procedures and FP.procedures["AltStableProbe/icon"]
check("/fp steps as icon is defined", iconProc ~= nil)
if iconProc then
    local asks = 0
    for _, st in ipairs(iconProc.steps) do
        if st.ask then asks = asks + 1 end
    end
    eq("  one question each: the panel over the sheet, the countdown, the console", asks, 3)
    check("  and ends with a /reload", iconProc.steps[#iconProc.steps].reload == true)
end
-- The audit's in-game part (#279): the login reading, a two-account round
-- trip, and one full exit, the only test of persistence.
local auditProc = FP.procedures and FP.procedures["AltStableProbe/audit"]
check("/fp steps as audit is defined", auditProc ~= nil)
if auditProc then
    local exits, asks = 0, 0
    for _, st in ipairs(auditProc.steps) do
        if st.reload == "exit" then exits = exits + 1 end
        if st.ask then asks = asks + 1 end
    end
    eq("  one full exit", exits, 1)
    eq("  four questions only the owner can answer", asks, 4)
    check("  the first step shows the login reading and checks it", auditProc.steps[1].auto and auditProc.steps[1].check ~= nil)
    check("  and ends with a /reload", auditProc.steps[#auditProc.steps].reload == true)
end
-- The Glass Gear API in game (#281): measured by run, wait and check, with
-- the other account acting; no full exit, and no question only the owner
-- can answer.
local gearProc = FP.procedures and FP.procedures["AltStableProbe/gear"]
check("/fp steps as gear is defined", gearProc ~= nil)
if gearProc then
    local waits, checks, asks, exits = 0, 0, 0, 0
    for _, st in ipairs(gearProc.steps) do
        if st.wait then waits = waits + 1 end
        if st.check then checks = checks + 1 end
        if st.ask then asks = asks + 1 end
        if st.reload == "exit" then exits = exits + 1 end
    end
    eq("  three waits: the swap, the ping, the refusal", waits, 3)
    eq("  five checks", checks, 5)
    eq("  no question and no full exit", asks + exits, 0)
    check("  and ends with a /reload", gearProc.steps[#gearProc.steps].reload == true)
end

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
-- The audit's login reading (#279): what the scan reads, 2 s after login.
WoW.skillLines = { { name = "Defense", isHeader = false, rank = 1, maxRank = 5, skillID = 95 } }
WoW.flushTimers()
local reading = db.audit and db.audit.login
check("the login reading is taken 2 s after PLAYER_LOGIN", type(reading) == "table")
if reading then
    eq("  the name", reading.name, "Example")
    eq("  and the surname", reading.surname, "Surname")
    eq("  the skill lines", reading.skillLines, 1)
    eq("  the display id", reading.displayID, 56658)
    check("  the guild, nil as the stub has none", reading.guild == nil)
    check("  and it says so in the log", logText():find("[audit] login+2s", 1, true) ~= nil)
end

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

------------------------------------------------------------
-- The icon procedure keeps its panel through a bare /fp (Codex on #244)
------------------------------------------------------------
-- The reading puts the console and the steps panel away (Probe:HideWindows).
-- A bare /fp typed mid-countdown used to clear the host's record and bring
-- back only the console, so the procedure went on with no panel to answer in
-- (ForeverProbe#10, fixed in its #12). Through the real procedure, both ways
-- the countdown can end.
_G.GetMouseFoci = function() return {} end
local function runToRead(finish)
    WoW.timers = {}
    SlashCmdList.FOREVERPROBE("steps as icon")
    check("the icon procedure's panel is up", FP.Steps.IsShown())
    FP.Steps.Answer(true)                           -- 1: the panel over the sheet
    FP.Steps.Run()                                  -- 2: Run -> /fp as icon
    check("  the countdown puts it away", not FP.Steps.IsShown())
    SlashCmdList.FOREVERPROBE("")                   -- a bare /fp mid-countdown
    finish()
    check("  and it is back when the reading ends", FP.Steps.IsShown(),
          "the procedure would go on with no panel to answer in")
    SlashCmdList.FOREVERPROBE("steps stop")
end
runToRead(function() for _ = 1, 5 do WoW.flushTimers() end end)
runToRead(function() run("icon cancel") end)

------------------------------------------------------------
-- /fp steps as gear: each observation counts only what follows its baseline
-- (Codex on #299)
------------------------------------------------------------
-- The steps' own functions, against a stand-in for AltStable's public API.
-- What has to hold: a GearChanged from before Record (the login's first sync)
-- can't end the swap wait; one more GearChanged for that character after the
-- swap reading fails the bag-move check; a ping delivered while refused fails,
-- however soon after the refusal it lands.
if gearProc then
    local SELF, OTHER = "Player-1-0000000A", "Player-2-0000000B"
    local cb, handler = {}, nil
    local peers = { { guid = OTHER, name = "Other" } }
    local gear = { capturedAt = 100, gearAt = 90, provenance = "own-account",
                   slots = { [1] = { state = "occupied", itemString = "item:6:0:0:0:0:0:0:0:60:0:0:0:1:1234" },
                             [2] = { state = "empty" } } }
    AltStable.RegisterCallback = function(name, fn) cb[name] = fn end
    AltStable.RegisterOwnAccountHandler = function(_, fn) handler = fn end
    AltStable.GetCharacterProvenance = function(guid) return guid == SELF and "self" or "own-account" end
    AltStable.GetCharacters = function()
        return { { guid = SELF, provenance = "self" }, { guid = OTHER, provenance = "own-account", provenanceVia = OTHER } }
    end
    AltStable.GetOwnAccountPeers = function() return peers end
    AltStable.GetCharacterGear = function(guid) return guid == OTHER and gear or nil end
    fireProbeEvent("PLAYER_LOGIN")                  -- GearListen, now with the API there
    check("the gear listener registered", cb.GearChanged ~= nil and handler ~= nil)

    local S = gearProc.steps
    local RECORD, SWAP, READ, BAGCHECK, PING, REFUSE, BASELINE, REFUSEDCHECK = 1, 2, 3, 5, 6, 7, 8, 10
    check("  the steps are where this test reads them", S[SWAP].wait and S[READ].auto and S[BAGCHECK].check
          and S[PING].wait and S[REFUSE].wait and S[BASELINE].auto and S[REFUSEDCHECK].check, "renumber the test")
    local function ok(i) return (S[i].check()) end

    cb.GearChanged(nil, { OTHER })                  -- the first sync, before Record
    handler("ping 0", { name = "Other", guid = OTHER })  -- and a ping from an earlier try
    S[RECORD].run()
    check("  Record passes with a peer and both kinds of character", ok(RECORD))
    check("a GearChanged from before Record doesn't end the swap wait", not S[SWAP].wait())
    cb.GearChanged(nil, { SELF })
    check("  nor one naming only this account's character", not S[SWAP].wait())
    cb.GearChanged(nil, { OTHER })                  -- the swap
    check("  the swap after Record does", S[SWAP].wait())

    S[READ].run()
    check("the swap reading finds the suffix", ok(READ))
    check("a bag move with no callback and gearAt unchanged passes", ok(BAGCHECK))
    cb.GearChanged(nil, { OTHER })                  -- a bag move that fired GearChanged
    check("  one more GearChanged for it after the swap reading fails", not ok(BAGCHECK))

    check("no ping yet: the ping wait holds", not S[PING].wait())
    handler("ping 1", { name = "Other", guid = OTHER })
    check("  the ping ends it", S[PING].wait())
    check("  and it is from a listed peer", ok(PING))

    peers = {}
    cb.OwnAccountPeersChanged()
    check("the refusal ends its wait", S[REFUSE].wait())
    S[BASELINE].run()
    check("nothing arrived while refused: passes", ok(REFUSEDCHECK))
    handler("ping 2", { name = "Other", guid = OTHER })  -- the refusal let it through
    check("  a ping delivered while refused fails", not ok(REFUSEDCHECK))
end

------------------------------------------------------------
-- /fp steps as legacy (#373): the readings and the comparison of two
-- characters, against a stand-in for the achievement API
------------------------------------------------------------
-- What has to hold: with no achievement API (the sweep above, the login
-- reading) nothing throws; with one, the reading finds the 65 challenges of
-- one set and says which; two characters' readings are compared on completed,
-- earned-by-me and criteria; the procedure ends with a /reload.
local legacyProc = FP.procedures and FP.procedures["AltStableProbe/legacy"]
check("/fp steps as legacy is defined", legacyProc ~= nil)
check("  and ends with a /reload", legacyProc ~= nil and legacyProc.steps[#legacyProc.steps].reload == true)
check("/fp as legacy and legacytime exist", P.commands.legacy ~= nil and P.commands.legacytime ~= nil)
local L = ns.legacy
check("the legacy seam is on the namespace", L ~= nil and rawget(_G, "legacy") == nil)
if legacyProc and L then
    -- Each character's view: what is completed, earned by it, and its
    -- Spelunker criteria (6 dungeons).
    local view
    local SPELUNKER = 62031
    local function info(id)
        local done = view.completed[id] or false
        return id, "Challenge " .. id, 0, done, done and 11 or nil, done and 19 or nil, done and 26 or nil,
               "desc", 0x08020400, 1, "Earn 1 Legacy Point.", false, view.mine[id] or false, nil, false
    end
    rawset(_G, "GetCategoryList", function() return { 15585, 92 } end)
    rawset(_G, "GetCategoryInfo", function(cat) return "Cat " .. cat, -1, 0 end)
    rawset(_G, "GetCategoryNumAchievements", function(cat) return cat == 15585 and #L.SET_A or 1, 0, 0 end)
    rawset(_G, "GetAchievementInfo", function(a, b)
        if b then return info(a == 15585 and L.SET_A[b] or 6) end
        return info(a)
    end)
    rawset(_G, "GetAchievementNumCriteria", function(id) return id == SPELUNKER and 6 or 0 end)
    rawset(_G, "GetAchievementCriteriaInfo", function(id, i)
        return "Dungeon " .. i, 0, i <= view.dungeons, 0, 1, "", 0, 1000 + i, "", 2000 + i, true, 0, 0
    end)
    local traits = rawget(_G, "C_Traits") or {}
    rawset(_G, "C_Traits", traits)
    local IN_SET_A = {}
    for _, id in ipairs(L.SET_A) do IN_SET_A[id] = true end
    traits.GetTraitCurrencyForAchievement = function(_, id) return IN_SET_A[id] and 1 or 0 end
    traits.GetMaxAvailableTraitCurrency = function() return 65 end
    rawset(_G, "C_MajorFactions", {
        GetCurrentRenownLevel = function() return 1 end,
        GetMajorFactionData = function() return { renownLevel = 1 } end,
        GetRenownLevels = function() return { { level = 1 }, { level = 15 } } end,
        GetRenownRewardsForLevel = function(_, level) return level == 15 and { { itemID = 276236 } } or {} end,
    })

    local S = legacyProc.steps
    local READ, SEARCH, COMPARE = 1, 3, 5
    check("  the steps are where this test reads them", S[READ].auto and S[SEARCH].run and S[COMPARE].wait,
          "renumber the test")
    local savedName = WoW.player.name

    view = { completed = { [61499] = true }, mine = { [61499] = true }, dungeons = 3 }
    WoW.player.name = "First"
    S[READ].run()
    check("one set listed, all 65: the first step passes", (S[READ].check()))
    local first = L.Mine()
    eq("  65 challenges listed", first and #first.enum.order, 65)
    eq("  all from set A", first and first.enum.inA, 65)
    eq("  the other category's achievement is not a challenge", first and first.enum.other, 0)
    eq("  renown read", first and first.renown.level, 1)
    eq("  max read", first and first.renown.max, 65)
    eq("  the reward on the track", first and first.renown.rewards[1] and first.renown.rewards[1].itemID, 276236)
    eq("  set B read by ID too", first and first.byId[63969] and first.byId[63969].set, "B")
    check("  a search that changes nothing passes", (S[SEARCH].check()))
    first.enum.inB = 3                              -- both sets listed at once
    check("  both sets listed fails the first step", not (S[READ].check()))
    first.enum.inB = 0

    -- The second character: the same account-level completed set, not its
    -- earner, one more dungeon.
    view = { completed = { [61499] = true }, mine = {}, dungeons = 4 }
    WoW.player.name = "Second"
    -- The procedure resumes at PLAYER_LOGIN, before the +10 s reading: the
    -- compare waits for it instead of throwing (Bugsy, 2026-11-19).
    check("  the compare waits while this character has no reading", not (S[COMPARE].wait()))
    L.Read("login+10s")
    local ready, diffCompleted, diffCriteria = S[COMPARE].wait()
    check("  and runs once it has one", ready == true)
    eq("the completed sets match", diffCompleted, 0)
    eq("  one challenge's criteria differ", diffCriteria, 1)
    check("  the comparison names both characters", (S[COMPARE].check()))
    local cmp = AltStableProbeDB.legacy.lastCompare
    check("  and is saved", cmp ~= nil and cmp.first == "First" and cmp.second == "Second")
    check("  earned by me differs: 1 vs 0", logText():find("earned by me: 1 on the first, 0 on the second", 1, true) ~= nil)

    -- Criteria compared by ID and quantity, not by how many are done (Codex
    -- on #380): two different 2/10 lists, and two crafts at 48 and 78 of
    -- 150, are differences.
    local function list(doneSet, q)
        local out = {}
        for i = 1, 10 do out[i] = { id = 100 + i, text = "D" .. i, done = doneSet[i] or false, q = q or 0, req = 1 } end
        return out
    end
    check("two 2/10 lists with different dungeons differ",
          L.CritDiff(list({ true, true }), list({ [3] = true, [4] = true })) ~= nil)
    check("  the same list does not", L.CritDiff(list({ true, true }), list({ true, true })) == nil)
    local function craft(q) return { { id = 111540, text = "150 Alchemy Skill", done = false, q = q, req = 150 } } end
    check("two crafts at 48 and 78 of 150 differ", L.CritDiff(craft(48), craft(78)) ~= nil)
    -- A successful false is kept, not dropped (Codex on #380).
    eq("a challenge read as not completed keeps false", first and first.byId[61500] and first.byId[61500].completed, false)

    -- The count is there before the rows (Codex on #380): every row call
    -- throws. The timeline must show failures, not six criteria all open.
    local realRow = GetAchievementCriteriaInfo
    rawset(_G, "GetAchievementCriteriaInfo", function() error("not ready") end)
    local early = L.Quick()
    eq("rows that throw are not counted as read", early.crit, 0)
    eq("  they are counted as failed", early.critFailed, 6)
    rawset(_G, "GetAchievementCriteriaInfo", realRow)
    local later = L.Quick()
    eq("once they read, they count", later.crit, 6)
    eq("  and none failed", later.critFailed, 0)

    -- The login timeline.
    fireProbeEvent("PLAYER_LOGIN")
    for _ = 1, 3 do WoW.flushTimers() end
    check("the login timeline reaches +30 s", L.session.login.plus30s ~= nil)
    check("  and +10 s found the 65", L.session.login.plus10s and L.session.login.plus10s.reading.found == 65)
    WoW.player.name = savedName
end

------------------------------------------------------------
-- /fp steps as quests (#374): the completed list, a turn-in, and two
-- characters compared, against a stand-in for C_QuestLog
------------------------------------------------------------
-- What has to hold: the reading counts the completed list and saves its IDs
-- under the character; a turn-in is looked at in the handler and later; two
-- characters' lists are compared and the first one's own IDs are asked about
-- here; the procedure ends with a /reload.
local questsProc = FP.procedures and FP.procedures["AltStableProbe/quests"]
check("/fp steps as quests is defined", questsProc ~= nil)
check("  and ends with a /reload", questsProc ~= nil and questsProc.steps[#questsProc.steps].reload == true)
for _, cmd in ipairs({ "quests", "queststime", "questnames", "questmaps" }) do
    check("  /fp as " .. cmd .. " exists", P.commands[cmd] ~= nil)
end
local Q = ns.quests
check("the quests seam is on the namespace", Q ~= nil and rawget(_G, "quests") == nil)
if questsProc and Q then
    -- The Legacy block above fired PLAYER_LOGIN, which took a quests reading
    -- too: start from an empty store so "the other character" is ours.
    AltStableProbeDB.quests = nil
    local done, account = {}, {}
    rawset(_G, "C_QuestLog", {
        GetAllCompletedQuestIDs = function()
            local out = {}
            for id in pairs(done) do out[#out + 1] = id end
            return out
        end,
        IsQuestFlaggedCompleted = function(id) return done[id] == true end,
        IsQuestFlaggedCompletedOnAccount = function(id) return account[id] == true end,
        GetTitleForQuestID = function(id) return (id == 7 or id == 870) and ("Quest " .. id) or nil end,
    })
    local S = questsProc.steps
    local READ, TURNIN, COMPARE = 1, 4, 6
    check("  the steps are where this test reads them", S[READ].auto and S[TURNIN].wait and S[COMPARE].wait,
          "renumber the test")
    local savedName = WoW.player.name

    done = { [7] = true, [783] = true, [870] = true }
    account = { [7] = true, [783] = true, [870] = true }
    WoW.player.name = "Questfirst"
    S[READ].run()
    check("a non-empty list passes the first step", (S[READ].check()))
    local first = Q.Mine()
    eq("  3 completed", first and first.completed.count, 3)
    eq("  their IDs saved, sorted", first and first.ids, "7,783,870")
    check("  the samples say which are flagged", first and first.samples:find("7:L/true/true", 1, true) ~= nil)
    done = {}
    S[READ].run()
    check("  an empty list fails it", not (S[READ].check()))
    done = { [7] = true, [783] = true, [870] = true }
    S[READ].run()                                   -- the first character's reading back

    -- A turn-in, completed only after the handler. An earlier run's turn-in,
    -- left in the account-wide SavedVariables, must not pass the step (Codex
    -- on #392): only one made after the step came up, by this character, in
    -- this session.
    Q.session.uptimeAtLogin = Q.session.uptimeAtLogin or 0
    local turnIns = AltStableProbeDB.quests.turnIns
    turnIns[#turnIns + 1] = { id = 1, plus2s = "list yes, flagged true", char = "Questfirst",
                              session = "an earlier session", seq = 99 }
    check("  an earlier run's turn-in does not complete the step", not (S[TURNIN].wait()))
    check("  nor pass it", not (S[TURNIN].check()))
    S[TURNIN].leave("back")
    Q.session.turnSeq = nil                         -- a new session's numbering
    check("  a fresh step still waits", not (S[TURNIN].wait()))
    WoW.player.name = "Somebodyelse"
    Q.TurnIn(4)
    WoW.flushTimers()
    WoW.player.name = "Questfirst"
    check("  another character's turn-in does not complete it", not (S[TURNIN].wait()))
    local r = Q.TurnIn(1361)
    eq("  the handler sees it not done yet", r.handler, "list no, flagged false")
    done[1361] = true
    check("  the step waits for the +2 s look", not (S[TURNIN].wait()))
    WoW.flushTimers()
    eq("  +2 s sees it done", r.plus2s, "list yes, flagged true")
    check("  the step completes", (S[TURNIN].wait()))
    check("  and passes", (S[TURNIN].check()))
    S[TURNIN].leave("done")
    -- A turn-in between the step's entry and its first poll (Codex on #392):
    -- the step before sets the baseline as the host leaves it, before the
    -- turn-in step is entered, so that turn-in still counts.
    S[TURNIN - 1].leave("done")
    Q.TurnIn(3450)
    done[3450] = true
    WoW.flushTimers()
    check("  a turn-in before the first poll still completes the step", (S[TURNIN].wait()))
    S[TURNIN].leave("done")

    -- The second character: fewer quests; the first one's own are on the
    -- account but not flagged here.
    done = { [7] = true }
    WoW.player.name = "Questsecond"
    check("  the compare waits while this character has no reading", not (S[COMPARE].wait()))
    Q.Read("login+10s")
    local ready, both, onlyFirst, flaggedHere, accountHere = S[COMPARE].wait()
    check("  and runs once it has one", ready == true)
    eq("one quest shared", both, 1)
    eq("  two only on the first", onlyFirst, 2)
    eq("  neither flagged here", flaggedHere, 0)
    eq("  both on the account", accountHere, 2)
    check("  the step passes", (S[COMPARE].check()))

    -- A read that failed is not an empty list (Codex on #392): the step ends,
    -- and fails, instead of counting every first-character quest as exclusive.
    local api = C_QuestLog.GetAllCompletedQuestIDs
    C_QuestLog.GetAllCompletedQuestIDs = function() error("not ready") end
    Q.Read("login+10s")
    check("  a failed reading is saved as an error", not Q.ReadOk(Q.Mine()))
    check("  the compare still ends", (S[COMPARE].wait()))
    check("  but fails", not (S[COMPARE].check()))
    C_QuestLog.GetAllCompletedQuestIDs = function() return {} end
    Q.Read("login+10s")
    check("  an empty list is a good reading", Q.ReadOk(Q.Mine()))
    C_QuestLog.GetAllCompletedQuestIDs = api

    -- Names: only what the client holds, counted over the whole scan.
    local t = Q.Titles()
    eq("two titles held", t.cached, 2)
    check("  the samples name them", t.samples:find("870=", 1, true) ~= nil)

    -- The login timeline.
    fireProbeEvent("PLAYER_LOGIN")
    for _ = 1, 3 do WoW.flushTimers() end
    check("the login timeline reaches +10 s", Q.session.login.plus10s ~= nil)
    eq("  and read the list there", Q.session.login.plus10s and Q.session.login.plus10s.reading.count, 1)
    rawset(_G, "C_QuestLog", nil)
    WoW.player.name = savedName
end

------------------------------------------------------------
-- /fp steps as bankclose (#419): a bank move's events against the close, and
-- every read of the bank against the open's
------------------------------------------------------------
do
    local proc = FP.procedures and FP.procedures["AltStableProbe/bankclose"]
    check("/fp steps as bankclose is defined", proc ~= nil and #proc.steps >= 15)
    check("  and ends with a /reload", proc ~= nil and proc.steps[#proc.steps].reload == true)
    check("  /fp as bankclose exists", P and P.commands.bankclose ~= nil)
    local B = ns.BankClose
    check("  its readers are reachable for the tests", B ~= nil and B.Read ~= nil)

    local function slot(id, n) return { itemID = id, stackCount = n, hyperlink = "|Hitem:" .. id .. "|h" } end
    local function bank(...) WoW.containers[6] = { size = 3, ... } end
    local function visit(fire)
        AltStableProbeDB.bankclose = nil
        WoW.bankTabs = { 6 }
        WoW.containers = { [0] = { size = 3 } }
        bank(slot(2318, 20), slot(2589, 4))            -- 2589 is the control, never touched
        fireProbeEvent("BANKFRAME_OPENED")
        B.Arm()                                        -- the owner leaves the Open step
        fire()
        for _ = 1, 4 do WoW.flushTimers() end
        local ok, line = B.VisitDone()
        return AltStableProbeDB.bankclose and AltStableProbeDB.bankclose[1], ok, line
    end
    local function readOf(s, kind)
        for _, l in ipairs(s and s.reads or {}) do if l:find(" " .. kind .. ": ", 1, true) then return l end end
        return ""
    end

    -- A. Part of a stack, the batch ends before the close: a healthy close read.
    local s, ok, line = visit(function()
        bank(slot(2318, 5), slot(2589, 4))
        WoW.containers[0] = { size = 3, slot(2318, 15) }
        fireProbeEvent("BAG_UPDATE", 6)
        fireProbeEvent("BAG_UPDATE", 0)
        fireProbeEvent("BAG_UPDATE_DELAYED")
        fireProbeEvent("BANKFRAME_CLOSED")
    end)
    check("a visit is saved once its window ends", s ~= nil)
    eq("  the batch ended before the close", s and s.delayedBeforeClose, true)
    check("  the close read keeps the untouched slot, changes the moved one",
          readOf(s, "CLOSED"):find("kept=1/2", 1, true) ~= nil
          and readOf(s, "CLOSED"):find("6:1 2318x20->2318x5", 1, true) ~= nil, readOf(s, "CLOSED"))
    check("  the item totals say what moved", readOf(s, "CLOSED"):find("2318:20->5", 1, true) ~= nil)
    check("  the bank-tab update is read too", readOf(s, "BAG_UPDATE"):find("kept=1/2", 1, true) ~= nil)
    check("  and the order names the carried bag", s and s.order:find("BAG_UPDATE(0 carried)", 1, true) ~= nil,
          s and s.order)
    check("  After(0)'s frame delta is recorded", s and s.nextFrameDelta ~= nil)
    check("  the wait step completes once, with the line", ok == true and line:find("visit", 1, true) ~= nil)
    check("  and not again for the same visit", (B.VisitDone()) == false)

    -- An unreadable close: slots reported, contents gone. The control slot
    -- reads empty too: kept=0.
    s = visit(function()
        fireProbeEvent("BAG_UPDATE", 6)
        bank()
        fireProbeEvent("BANKFRAME_CLOSED")
        fireProbeEvent("BAG_UPDATE_DELAYED")
    end)
    eq("a close before the batch ended says so", s and s.delayedBeforeClose, false)
    check("  a read that lost the bank keeps none, the control included",
          readOf(s, "CLOSED"):find("kept=0/2", 1, true) ~= nil, readOf(s, "CLOSED"))
    check("  the DELAYED after the close is read", readOf(s, "DELAYED"):find("kept=0/2", 1, true) ~= nil)

    -- A whole stack withdrawn, read healthily: its slot is empty, the control
    -- stays (kept=1/2), unlike the unreadable close above.
    s = visit(function()
        bank(nil, slot(2589, 4))
        WoW.containers[6] = { size = 3, [2] = slot(2589, 4) }
        fireProbeEvent("BAG_UPDATE", 6)
        fireProbeEvent("BAG_UPDATE_DELAYED")
        fireProbeEvent("BANKFRAME_CLOSED")
    end)
    check("a whole stack withdrawn reads apart from an unreadable bank",
          readOf(s, "CLOSED"):find("kept=1/2", 1, true) ~= nil
          and readOf(s, "CLOSED"):find("2318x20->empty", 1, true) ~= nil, readOf(s, "CLOSED"))

    -- In one frame, DELAYED then a new bank-tab update then the close: the
    -- update's batch did not end before the close.
    s = visit(function()
        fireProbeEvent("BAG_UPDATE", 6)
        fireProbeEvent("BAG_UPDATE_DELAYED")
        fireProbeEvent("BAG_UPDATE", 6)
        fireProbeEvent("BANKFRAME_CLOSED")
    end)
    eq("DELAYED, then a new bank update, then the close: not before the close", s and s.delayedBeforeClose, false)
    s = visit(function()
        fireProbeEvent("BAG_UPDATE", 6)
        fireProbeEvent("BAG_UPDATE_DELAYED")
        fireProbeEvent("BANKFRAME_CLOSED")
    end)
    eq("  the update, DELAYED, the close in one frame: before the close", s and s.delayedBeforeClose, true)
    s = visit(function()
        fireProbeEvent("BAG_UPDATE", 0)
        fireProbeEvent("BAG_UPDATE_DELAYED")
        fireProbeEvent("BANKFRAME_CLOSED")
    end)
    eq("  no bank-tab update at all is said as such", s and s.delayedBeforeClose, "no bank-tab update after the trial was armed")

    -- A slot whose reads throw is counted, never taken as empty.
    s = visit(function()
        local real = AltStable.API.GetContainerItemID
        AltStable.API.GetContainerItemID = function() error("withheld") end
        fireProbeEvent("BANKFRAME_CLOSED")
        AltStable.API.GetContainerItemID = real
    end)
    check("a read that throws counts errors", readOf(s, "CLOSED"):find("errors=3", 1, true) ~= nil, readOf(s, "CLOSED"))
    check("  its slots read as unknown, never as withdrawn",
          readOf(s, "CLOSED"):find("->?", 1, true) ~= nil and not readOf(s, "CLOSED"):find("->empty", 1, true),
          readOf(s, "CLOSED"))
    check("  and its totals are marked incomplete", readOf(s, "CLOSED"):find("items(INCOMPLETE)", 1, true) ~= nil)
    check("  the close's absolute totals say so too", s and tostring(s.closeTotals):find("unknown slots", 1, true) ~= nil,
          s and s.closeTotals)

    -- Absolute totals and elapsed time are saved (the final reopen is checked
    -- against the trials by them).
    s = visit(function() fireProbeEvent("BANKFRAME_CLOSED") end)
    eq("the open's absolute totals are saved", s and s.openTotals, "2318:20 2589:4")
    check("  the order carries elapsed time", s and s.order:find("+0.000s OPENED", 1, true) ~= nil, s and s.order)

    -- Reopened inside the window, before the report polls: the report answers
    -- for the visit the trial closed, cut short, and its late reads are skipped.
    AltStableProbeDB.bankclose = nil
    WoW.bankTabs = { 6 }
    bank(slot(2318, 20), slot(2589, 4))
    fireProbeEvent("BANKFRAME_OPENED")
    B.Arm()
    fireProbeEvent("BANKFRAME_CLOSED")
    local first = B.Recent()
    fireProbeEvent("BANKFRAME_OPENED")              -- before any timer ran
    local okR, lineR = B.VisitDone()
    check("a reopen inside the window: the report is the closed visit's",
          okR == true and lineR:find("visit " .. first.id .. " (INTERRUPTED", 1, true) ~= nil, lineR)
    for _ = 1, 4 do WoW.flushTimers() end
    local late = false
    for _, e in ipairs(first.events) do if e.kind == "CLOSED+0" or e.kind == "CLOSED+1s" then late = true end end
    check("  and its pending reads were skipped", not late)
    check("  the new visit is not reported for it", (B.VisitDone()) == false)
    fireProbeEvent("BANKFRAME_CLOSED")
    for _ = 1, 4 do WoW.flushTimers() end
    check("  and the unarmed visit after it reports nothing", (B.VisitDone()) == false)

    -- Ordinary banking before the trial never answers for it: an earlier
    -- visit, then the armed one; the report is the armed one's.
    fireProbeEvent("BANKFRAME_OPENED"); local X = B.Recent(); fireProbeEvent("BANKFRAME_CLOSED")
    for _ = 1, 4 do WoW.flushTimers() end
    fireProbeEvent("BANKFRAME_OPENED"); B.Arm(); local Tv = B.Recent(); fireProbeEvent("BANKFRAME_CLOSED")
    for _ = 1, 4 do WoW.flushTimers() end
    local _, l1 = B.VisitDone()
    check("an earlier visit does not answer for the trial",
          tostring(l1):find("visit " .. Tv.id .. ":", 1, true) == 1 and Tv.id ~= X.id, l1)
    -- Armed before the bank's own OPENED arrives (the panel's event first):
    -- the next visit is the trial's.
    B.Arm()
    fireProbeEvent("BANKFRAME_OPENED"); local Nv = B.Recent(); fireProbeEvent("BANKFRAME_CLOSED")
    for _ = 1, 4 do WoW.flushTimers() end
    local _, l2 = B.VisitDone()
    check("  armed before the bank's OPENED: the next visit is the trial's",
          tostring(l2):find("visit " .. Nv.id .. ":", 1, true) == 1, l2)

    -- The verdict counts only the trial's move: an update and its batch from
    -- before arming, then the move's tab update arriving after the close.
    s = (function()
        AltStableProbeDB.bankclose = nil
        fireProbeEvent("BANKFRAME_OPENED")
        fireProbeEvent("BAG_UPDATE", 6)
        fireProbeEvent("BAG_UPDATE_DELAYED")
        B.Arm()
        fireProbeEvent("BANKFRAME_CLOSED")
        fireProbeEvent("BAG_UPDATE", 6)
        for _ = 1, 4 do WoW.flushTimers() end
        B.VisitDone()
        return AltStableProbeDB.bankclose[1]
    end)()
    eq("a batch from before the trial is not the move's", s and s.delayedBeforeClose,
       "no bank-tab update after the trial was armed")

    -- Codex round 6: the baseline is the settled read at Ready, and each
    -- trial's reads are checked against the NEXT visit's baseline. Here the
    -- DELAYED before the close still reads the old counts; the move shows only
    -- after the close.
    AltStableProbeDB.bankclose = nil
    WoW.bankTabs = { 6 }
    bank(slot(2318, 20), slot(2589, 4))
    fireProbeEvent("BANKFRAME_OPENED"); B.Arm()
    fireProbeEvent("BAG_UPDATE", 6)
    fireProbeEvent("BAG_UPDATE_DELAYED")              -- still 20: stale
    fireProbeEvent("BANKFRAME_CLOSED")                -- still 20 inside the close
    bank(slot(2318, 5), slot(2589, 4))                -- the move lands after it
    for _ = 1, 4 do WoW.flushTimers() end
    local first = AltStableProbeDB.bankclose[#AltStableProbeDB.bankclose]
    eq("  the order alone says the batch ended before the close", first.delayedBeforeClose, true)
    B.VisitDone()
    -- The next visit opens unready (no slots), then settles by Ready.
    WoW.containers[6] = { size = 0 }
    fireProbeEvent("BANKFRAME_OPENED")
    bank(slot(2318, 5), slot(2589, 4))
    B.Arm()
    eq("the next visit's settled baseline judges it: the DELAYED read was wrong", first.delayedRight, false)
    eq("  so was the read inside the close", first.closeRight, false)
    eq("  the read a second later was right", first.lastRight, true)
    check("  the reference's own move is saved, slot by slot, to check the grade against",
          tostring(first.referenceMove):find("6:1 2318x20->2318x5", 1, true) ~= nil, tostring(first.referenceMove))
    fireProbeEvent("BANKFRAME_CLOSED")
    for _ = 1, 4 do WoW.flushTimers() end
    local second = AltStableProbeDB.bankclose[#AltStableProbeDB.bankclose]
    eq("an unready open is not the baseline: the Ready read is", second.baselineTotals, "2318:5 2589:4")
    B.VisitDone()

    -- Codex round 7. A trial whose move never landed is inconclusive, not right.
    local function trial(fire, nextBank)
        AltStableProbeDB.bankclose = nil
        bank(slot(2318, 20), slot(2589, 4))
        fireProbeEvent("BANKFRAME_OPENED"); B.Arm()
        fire()
        for _ = 1, 4 do WoW.flushTimers() end
        local v = AltStableProbeDB.bankclose[#AltStableProbeDB.bankclose]
        B.VisitDone()
        nextBank()
        fireProbeEvent("BANKFRAME_OPENED"); B.Arm()
        fireProbeEvent("BANKFRAME_CLOSED")
        for _ = 1, 4 do WoW.flushTimers() end
        B.VisitDone()
        return v
    end
    local v = trial(function() fireProbeEvent("BANKFRAME_CLOSED") end,
                    function() bank(slot(2318, 20), slot(2589, 4)) end)
    check("no move landed: inconclusive", tostring(v.closeRight):find("inconclusive", 1, true) ~= nil,
          tostring(v.closeRight))
    -- An incomplete next baseline: inconclusive too.
    v = trial(function() bank(slot(2318, 5), slot(2589, 4)); fireProbeEvent("BANKFRAME_CLOSED") end,
              function()
                  local real = AltStable.API.GetContainerNumSlots
                  AltStable.API.GetContainerNumSlots = function() return 0 end
                  fireProbeEvent("BANKFRAME_OPENED"); B.Arm()
                  AltStable.API.GetContainerNumSlots = real
                  fireProbeEvent("BANKFRAME_CLOSED"); for _ = 1, 4 do WoW.flushTimers() end; B.VisitDone()
              end)
    -- (that unready visit graded v; the trial helper's own visit after it doesn't re-grade it)
    check("an unreadable next baseline: inconclusive", tostring(v.closeRight):find("inconclusive", 1, true) ~= nil,
          tostring(v.closeRight))
    -- The pre-close DELAYED is graded whatever the order, and the 1 s grade is
    -- the CLOSED+1s sample, not a later read.
    v = trial(function()
        bank(slot(2318, 5), slot(2589, 4))
        fireProbeEvent("BAG_UPDATE_DELAYED")             -- no bank-tab update before it
        fireProbeEvent("BANKFRAME_CLOSED")
        fireProbeEvent("BAG_UPDATE", 0)
        WoW.flushTimers(); WoW.flushTimers()           -- +0 and +1 s read 5
        bank(slot(2318, 99), slot(2589, 4))
        fireProbeEvent("BAG_UPDATE_DELAYED")             -- a later read in the window: 99
    end, function() bank(slot(2318, 5), slot(2589, 4)) end)
    eq("a pre-close DELAYED read is graded whatever the order", v.delayedRight, true)
    eq("  the 1 s grade is the 1 s sample's", v.lastRight, true)
    -- Codex round 8: a reference with slots but no items (the control gone)
    -- is inconclusive, even against an equally blank close read.
    v = trial(function() bank(); fireProbeEvent("BANKFRAME_CLOSED") end,
              function() bank() end)
    check("a blank reference that lost the control: inconclusive",
          tostring(v.closeRight):find("lost the control", 1, true) ~= nil, tostring(v.closeRight))
    bank(slot(2318, 20), slot(2589, 4))

    -- A reopen after the window is not an interruption.
    local realGetTime = GetTime
    local clock = 100
    rawset(_G, "GetTime", function() return clock end)
    fireProbeEvent("BANKFRAME_OPENED"); B.Arm(); local W = B.Recent()
    fireProbeEvent("BANKFRAME_CLOSED")
    clock = 103.05                                   -- past the 3 s window, before the 3.1 s timer
    fireProbeEvent("BANKFRAME_OPENED")
    check("a reopen after the window does not mark the visit interrupted", W.done and not W.interrupted)
    fireProbeEvent("BANKFRAME_CLOSED")
    for _ = 1, 4 do WoW.flushTimers() end
    B.VisitDone()
    rawset(_G, "GetTime", realGetTime)

    -- Unknown is never empty: a tab whose slot count fails, an opening slot
    -- that failed, a tab list that failed.
    local open = B.Read({ 6 })
    local realSlots = AltStable.API.GetContainerNumSlots
    AltStable.API.GetContainerNumSlots = function() error("withheld") end
    local blind = B.Read({ 6 })
    AltStable.API.GetContainerNumSlots = realSlots
    local line = B.Summarise(open, blind)
    check("a tab whose slot count failed: its slots are unknown, not withdrawn",
          line:find("->?", 1, true) ~= nil and not line:find("->empty", 1, true), line)
    line = B.Summarise(blind, open)
    check("  an opening read that failed: later items are ?->, not empty->",
          line:find("?->", 1, true) ~= nil and not line:find("empty->", 1, true), line)
    eq("  a failed tab list is never totals of an empty bank", B.Totals(B.Read(nil)), "ERR no tab list")
    AltStable.API.GetContainerNumSlots = function() return 0 end
    local zero = B.Read({ 6 })
    AltStable.API.GetContainerNumSlots = realSlots
    line = B.Summarise(open, zero)
    check("  a slot count of 0 is unreadable, not an empty tab",
          line:find("->?", 1, true) ~= nil and not line:find("->empty", 1, true), line)
    -- #439: a purchased bag slot (7) with no bag reads 0 slots and is whole.
    local savedBags = WoW.bankBags
    WoW.bankBags = {}
    WoW.containers[7] = { size = 0 }
    local withEmpty = B.Read({ 6, 7 })
    check("  an empty purchased bag slot is read whole, not unknown", withEmpty.unknownTabs == 0,
          tostring(withEmpty.slots))
    WoW.bankBags = { [2] = true }
    check("  a bag in it at 0 slots is unknown", B.Read({ 6, 7 }).unknownTabs == 1)
    WoW.containers[7], WoW.bankBags = nil, savedBags
    WoW.bankTabs, WoW.containers = nil, nil
end

------------------------------------------------------------
-- /fp steps as transmog (#485): what a slot shows, three states
------------------------------------------------------------
-- What has to hold: without any transmog API the reading still saves
-- ShowingHelm and the equipped items, and throws nothing; with one, it saves
-- the slot's applied source and isHideVisual; the procedure ends with a
-- /reload.
do
    local proc = FP.procedures and FP.procedures["AltStableProbe/transmog"]
    check("/fp steps as transmog is defined", proc ~= nil)
    check("  and ends with a /reload", proc ~= nil and proc.steps[#proc.steps].reload == true)
    check("/fp as transmog exists", P.commands.transmog ~= nil)

    local T = ns.transmog
    local realHelm = rawget(_G, "ShowingHelm")
    ShowingHelm = function() return false end
    local okBare, bare = pcall(T.Read, "bare")
    check("with no transmog API the reading throws nothing", okBare, tostring(bare))
    eq("  and keeps ShowingHelm", okBare and bare.showingHelm, false)
    WoW.flushTimers()

    -- A stand-in for the transmog API: the head hidden by transmog.
    local realUtil, realT, realTC = rawget(_G, "TransmogUtil"), rawget(_G, "C_Transmog"), rawget(_G, "C_TransmogCollection")
    rawset(_G, "TransmogUtil", nil)
    TransmogUtil = { GetTransmogLocation = function(name) return { name = name } end }
    C_Transmog = { GetSlotVisualInfo = function(loc)
        local head = loc.name == "HEADSLOT"
        return { baseSourceID = 11, baseVisualID = 21, appliedSourceID = head and 99 or 0,
                 appliedVisualID = head and 77 or 0, isHideVisual = head }
    end }
    C_TransmogCollection = {
        GetSourceInfo = function(src) return { itemID = src * 10, visualID = src == 99 and 77 or 21, name = "S" .. src } end,
        IsAppearanceHiddenVisual = function(id) return id == 77 end,
    }
    local okT, rec = pcall(T.Read, "transmogged")
    check("with a transmog API the reading throws nothing", okT, tostring(rec))
    local head = okT and rec.slots["1"] or {}
    eq("  the head's applied source is saved", type(head.slotVisual) == "table" and head.slotVisual.appliedSourceID, 99)
    eq("  and its isHideVisual", type(head.slotVisual) == "table" and head.slotVisual.isHideVisual, true)
    eq("  the shown source is the applied one", head.shownSource, 99)
    eq("  and IsAppearanceHiddenVisual on it", head.isHiddenVisual, true)
    eq("the latest reading of a label is found", T.Latest("transmogged"), rec)
    check("  and summed up", T.Summary(rec):find("hide true", 1, true) ~= nil, T.Summary(rec))
    WoW.flushTimers()
    rawset(_G, "TransmogUtil", realUtil); rawset(_G, "C_Transmog", realT)
    rawset(_G, "C_TransmogCollection", realTC)
    ShowingHelm = realHelm
end

WoW.finish("test_probe", passed, failed)
