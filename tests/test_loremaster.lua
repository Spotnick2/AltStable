------------------------------------------------------------
-- test_loremaster.lua - the Loremaster plugin (#374, #372)
--
-- The stubs model what 1.60.1.70959 measured (forever-api-notes.md,
-- "Completed quests: per character, ready at login"): the completed list is
-- the character's own and complete at login; a turn-in is recorded only
-- after QUEST_TURNED_IN, so the plugin scans later; UnitRace's third return
-- is the race ID (Skyborne: 95 Alliance, 96 Horde). What has to hold:
--   * a quest counts for a character its masks allow (race bits are
--     QuestieDB's, not 2^(raceID-1)); a pre-quest it can never take keeps it
--     out; a done quest always counts; an unsure one only once done;
--   * a missed quest leaves the total, from completions and level only, along
--     breadcrumb links only, and a follow-up closes its predecessor only when
--     done, never when merely closed (Codex on the plan);
--   * Horde reads its own links where the table has them;
--   * a scan keeps a new snapshot only when something moved, with a strictly
--     newer stamp, and touches the character; the sync line round-trips,
--     newer replaces wholesale, malformed and older are ignored;
--   * the tab draws only characters with a snapshot, never a hidden one, and
--     lists open quests only from the local done set of the same snapshot.
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
local function near(name, got, want)
    check(name, type(got) == "number" and math.abs(got - want) < 1e-9, "got " .. tostring(got) .. ", want " .. tostring(want))
end

AltStable = {}
AltStableDB = {}
AltStableConfig = {}
dofile("Compat.lua")
assert(loadfile("Core.lua"))()
dofile("Config.lua")
dofile("tests/libglass.lua"); LoadGlass("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")

-- The client's completed list, per character (the measured shape: an array).
local completed = {}
rawset(_G, "C_QuestLog", {
    GetAllCompletedQuestIDs = function()
        local out = {}
        for id in pairs(completed) do out[#out + 1] = id end
        return out
    end,
    GetNumQuestLogEntries = function() return 9, 7 end,
    GetTitleForQuestID = function() return nil end,   -- not cached (measured)
})

local ME = WoW.player.guid
AltStableDB[ME] = { name = "Example Surname", class = "PRIEST", level = 30, scannedHere = true }

AltStable.plugins = {}
dofile("Plugins/Loremaster/QuestData.lua")
dofile("Plugins/Loremaster/Loremaster.lua")
dofile("Plugins/Loremaster/AltStableLoremaster.lua")
WoW.flushTimers()

local plugin
for _, p in ipairs(AltStable.plugins or {}) do if p.id == "loremaster" then plugin = p end end
check("the plugin registers itself with the core", plugin ~= nil)
if not plugin then
    print(("test_loremaster: %d passed, %d failed"):format(passed, failed + 1)); os.exit(1)
end
local L = plugin._test
local M = AltStable.Loremaster
local D = AltStable.LoremasterData

local listed = false
for _, p in ipairs(AltStable.LOD_PLUGINS) do
    if p.key == "loremaster" and p.addon == "AltStableLoremaster" then listed = true end
end
check("the core lists it among the load-on-demand plugins", listed)
check("it syncs on its own stamp", plugin.independentStamp == true)
check("  and has every sync hook", plugin.OnSerialize and plugin.OnDeserialize and plugin.OnCleanup
      and plugin.OnForget and true or false)

local function P(faction, race, class, level) return { faction = faction, race = race, class = class, level = level } end
local function Set(...) local s = {} for _, id in ipairs({ ... }) do s[id] = true end return s end
local Q = D.QUESTS

------------------------------------------------------------
-- Who can take a quest
------------------------------------------------------------

-- Call of Earth (92466): Horde races, shamans (class 7, bit 64).
check("a Windshaper Skyborne shaman (96, Horde) takes Call of Earth", M.CanTake(Q[92466], P("Horde", 96, 7)))
check("  an Orc shaman too", M.CanTake(Q[92466], P("Horde", 2, 7)))
check("  a High Order Skyborne shaman (95, Alliance) does not", not M.CanTake(Q[92466], P("Alliance", 95, 7)))
check("  nor a Windshaper mage", not M.CanTake(Q[92466], P("Horde", 96, 8)))
-- Race 95 is bit 32, not 2^94: an Alliance quest open to every Alliance race.
check("High Order Skyborne takes Kobold Camp Cleanup (Alliance races)", M.CanTake(Q[7], P("Alliance", 95, 8)))
check("  an Orc does not", not M.CanTake(Q[7], P("Horde", 2, 8)))
-- A race the table doesn't know: only quests open to its whole faction.
check("an unknown Alliance race takes a whole-Alliance quest", M.CanTake(Q[7], P("Alliance", 99, 8)))
local narrow = { 12, nil, 1, 1, 0, 0, "Human only", 0 }
check("  but not a Human-only one", not M.CanTake(narrow, P("Alliance", 99, 8)))
check("a Human takes the Human-only one", M.CanTake(narrow, P("Alliance", 1, 8)))

------------------------------------------------------------
-- Missed quests: closed from completions and level only
------------------------------------------------------------

local H30, A30 = P("Horde", 2, 8, 30), P("Alliance", 1, 8, 30)
-- Breadcrumbs, transitively: 1361 -> 1362 -> 1365.
eq("doing 1365 closes its breadcrumb 1362", (M.ClosedWhy(1362, H30, Set(1365))), "bread")
eq("  and 1362's breadcrumb 1361", (M.ClosedWhy(1361, H30, Set(1365))), "bread")
eq("  nothing done: 1361 open", (M.ClosedWhy(1361, H30, {})), nil)
-- Exclusive partners, and a follow-up only when DONE: 4023 closes 4022, and
-- 3481 (whose follow-up is the closed 4022) stays open (Codex r5).
eq("doing 4023 closes its alternative 4022", (M.ClosedWhy(4022, A30, Set(4023))), "excl")
eq("  but not 3481, whose follow-up 4022 is only closed", (M.ClosedWhy(3481, A30, Set(4023))), nil)
eq("a done follow-up closes its predecessor (7 -> 15)", (M.ClosedWhy(7, A30, Set(15))), "next")
-- availableUntilCompleted and parentQuest.
eq("doing 3481 ends 4023's window", (M.ClosedWhy(4023, A30, Set(3481))), "until")
eq("doing the parent 3449 closes 3450 (needs it active)", (M.ClosedWhy(3450, A30, Set(3449))), "parent")
-- Level caps (the override's 39 for Darkspear Islands Clash).
eq("past the cap: 98895 missed at 40", (M.ClosedWhy(98895, P("Alliance", 1, 8, 40), {})), "level")
eq("  at 39 still open", (M.ClosedWhy(98895, P("Alliance", 1, 8, 39), {})), nil)
eq("a done quest is never closed", (M.ClosedWhy(4022, A30, Set(4022, 4023))), nil)
-- Horde's own links: 1198 leads to 1200 for the Alliance only (Codex on #394).
check("Alliance: doing 1200 closes 1198 (its breadcrumb and follow-up)", M.ClosedWhy(1198, A30, Set(1200)) ~= nil)
eq("  Horde: it does not", (M.ClosedWhy(1198, H30, Set(1200))), nil)

------------------------------------------------------------
-- Counting, on rows made for the test
------------------------------------------------------------

local FAKE = { 9100001, 9100002, 9100003, 9100004, 9100005, 9100006, 9100007 }
local HORDE_MASK = D.FACTION_MASK.Horde
Q[9100001] = { 12, nil, 1, 0, 0, 0, "Open", 0 }
Q[9100002] = { 12, nil, 1, HORDE_MASK, 0, 0, "Horde only", 0 }
Q[9100003] = { 12, nil, 1, 0, 0, 1, "Unsure", 0 }
Q[9100004] = { 12, nil, 1, 0, 0, 0, "Needs the Horde one", 0, nil, { 9100002 } }
Q[9100005] = { 12, nil, 1, 0, 0, 0, "Missed", 5 }
Q[9100006] = { D.CLASS_KEY, nil, 40, 0, 2 ^ 7, 0, "Mage, level 40", 0 }
Q[9100007] = { D.CLASS_KEY, nil, 10, 0, 2 ^ 7, 0, "Mage, level 10", 0 }
local function Only(p, done)
    -- Count with only the fake rows in the table.
    local real = {}
    for id, q in pairs(Q) do if id < 9100000 then real[id] = q; Q[id] = nil end end
    local r = M.Count(p, done or {}, true)
    for id, q in pairs(real) do Q[id] = q end
    return r
end
local r = Only(P("Alliance", 1, 8, 30))
local elwynn = r.c[12]
eq("Alliance mage: Open counts, Horde only and its follow-up do not, Missed left out", elwynn and elwynn[2], 1)
eq("  none done", elwynn and elwynn[1], 0)
eq("  the missed one is listed apart", r.lists[12] and #r.lists[12].missed, 1)
r = Only(P("Alliance", 1, 8, 30), Set(9100003, 9100002))
eq("an unsure quest done counts, and a done one whatever its masks", r.c[12] and r.c[12][1], 2)
-- ...and with the Horde-only pre-quest done, its follow-up is possible again: 4.
eq("  in the total too, with the follow-up the done pre-quest opens", r.c[12] and r.c[12][2], 4)
r = Only(P("Horde", 2, 8, 30))
eq("Horde mage: Open, Horde only and its follow-up", r.c[12] and r.c[12][2], 3)
eq("Class quests: both mage quests in the total", r.cls.total, 2)
eq("  one available at level 30", r.cls.now, 1)
r = Only(P("Horde", 2, 5, 30))
eq("a priest has no Class row from mage quests", r.c[D.CLASS_KEY], nil)
for _, id in ipairs(FAKE) do Q[id] = nil end

------------------------------------------------------------
-- Scanning
------------------------------------------------------------

WoW.faction = "Horde"
WoW.player.raceID, WoW.player.classID, WoW.level = 2, 8, 30
AltStableDB[ME].lastUpdate = 0
completed = Set(1361, 1362, 870, 123456789)   -- the last one is not in the table
check("a first scan keeps a snapshot", M.Scan())
local snap = M.DB().chars[ME]
check("  with the measured shape", snap and snap.faction == "Horde" and snap.race == 2 and snap.class == 8
      and snap.level == 30 and snap.ver == D.VERSION)
eq("  every completed quest counted in all", snap and snap.completed, 4)
eq("  the quest log's quests", snap and snap.log, 7)
eq("  Desolace 2 done", snap and snap.c[405] and snap.c[405][1], 2)
check("  the character is touched, so the delta carries it", AltStableDB[ME].lastUpdate > 0)
check("  the local done set has the same stamp", M.DB().done[ME].stamp == snap.stamp)
local stamp = snap.stamp
AltStableDB[ME].lastUpdate = 0
check("nothing moved: no new snapshot", not M.Scan())
eq("  the stamp stays", M.DB().chars[ME].stamp, stamp)
eq("  nor a touch", AltStableDB[ME].lastUpdate, 0)
completed[1365] = true
check("a turn-in moves it", M.Scan())
check("  with a strictly newer stamp, in the same second", M.DB().chars[ME].stamp > stamp)
eq("  Desolace 3 done", M.DB().chars[ME].c[405][1], 3)
-- The completion lands after QUEST_TURNED_IN: the scan is scheduled, later.
M.ResetPending()
completed[1366] = true
local before = M.DB().chars[ME].stamp
M.ScheduleScan()
eq("  a scheduled scan does not read at once", M.DB().chars[ME].stamp, before)
WoW.flushTimers()
check("  it reads after its delay", M.DB().chars[ME].stamp > before)
check("the scan waits longer than the measured 0.5 s", M.SCAN_DELAY > 0.5)
-- A turn-in while a scan is pending (Codex on #397): accepting a quest arms the
-- scan, and a turn-in just before it fires must push it back, or the only scan
-- reads the list before the completion lands.
M.ResetPending()
local first = M.ScheduleScan()
local second = M.ScheduleScan()
local stillFirst, hasSecond = false, false
for _, e in ipairs(WoW.timers) do
    if e == first then stillFirst = true end
    if e == second then hasSecond = true end
end
check("  a second event cancels the pending scan", not stillFirst)
check("  and arms a new one, the full delay from now", hasSecond and second.delay == M.SCAN_DELAY)
completed[1367] = true                         -- the turn-in's completion lands
before = M.DB().chars[ME].stamp
WoW.flushTimers()
check("  the one scan sees it", M.DB().chars[ME].stamp > before)
local hasEvent = {}
for _, ev in ipairs(M.EVENTS) do hasEvent[ev] = true end
check("turn-ins and level-ups schedule a scan", hasEvent.QUEST_TURNED_IN and hasEvent.PLAYER_LEVEL_UP)

-- The export contract (AltStableCompanion#82): plain numbers per GUID, names.
snap = M.DB().chars[ME]
check("export: log, completed, level, cls", type(snap.log) == "number" and type(snap.completed) == "number"
      and type(snap.level) == "number" and type(snap.cls) == "table" and type(snap.cls.now) == "number")
check("export: the rows' English names", M.DB().zones[12] and M.DB().zones[12].name == "Elwynn Forest")

------------------------------------------------------------
-- Sync
------------------------------------------------------------

local blob = M.Serialize(ME)
check("the line has no newline", not blob:find("\n"))
local back = M.Parse(blob)
check("it parses back", back ~= nil)
if back then
    eq("  stamp", back.stamp, snap.stamp)
    eq("  faction", back.faction, "Horde")
    eq("  race", back.race, 2)
    eq("  level", back.level, 30)
    eq("  log", back.log, 7)
    eq("  completed", back.completed, snap.completed)
    eq("  Desolace", back.c[405] and back.c[405][1], snap.c[405][1])
    eq("  the class row's level count", back.cls.now, snap.cls.now)
end
eq("nothing for a character never scanned", M.Serialize("Player-0-NONE"), "")
check("malformed: nil", M.Parse("v1|s=12|garbage") == nil and M.Parse("v2|s=1|d=x|f=H|lv=1|c=") == nil)
check("a bad zone item: nil", M.Parse("v1|s=5|d=abc|f=H|lv=3|c=12.1.x") == nil)
local later = M.Parse("v1|s=5|d=abc|f=A|r=1|k=8|lv=3|q=99|l=2|t=4|n=0|c=12.1.3")
check("a field this version doesn't know is skipped", later ~= nil and later.c[12] and later.c[12][2] == 3)

local OTHER = "Player-9999-0000BBBB"
AltStableDB[OTHER] = { name = "Other Name", class = "MAGE", level = 12 }
eq("a received snapshot says it stored something newer (#422)",
   M.Deserialize(OTHER, "v1|s=100|d=abc|f=A|r=95|k=8|lv=12|l=3|t=40|n=1|c=12.5.10,-9999.1.4"), true)
eq("a received snapshot is kept", M.DB().chars[OTHER] and M.DB().chars[OTHER].c[12][1], 5)
eq("  with its class row", M.DB().chars[OTHER].cls.done, 1)
M.Deserialize(OTHER, "v1|s=90|d=abc|f=A|r=95|k=8|lv=12|l=3|t=40|n=0|c=12.9.10")
eq("an older one is ignored", M.DB().chars[OTHER].c[12][1], 5)
AltStableDB["Player-9999-0000CCCC"] = { name = "Third Name", class = "MAGE", level = 12 }
eq("  through the plugin the core calls, too",
   plugin.OnDeserialize("Player-9999-0000CCCC", "v1|s=100|d=abc|f=A|r=95|k=8|lv=12|l=3|t=40|n=1|c=12.5.10,-9999.1.4"), true)
M.DB().chars["Player-9999-0000CCCC"], AltStableDB["Player-9999-0000CCCC"] = nil, nil
check("  the same stamp says nothing new",
      not M.Deserialize(OTHER, "v1|s=100|d=abc|f=A|r=95|k=8|lv=12|l=3|t=40|n=0|c=12.7.10"))
eq("  so is one with the same stamp (our own echo)", M.DB().chars[OTHER].c[12][1], 5)
-- Counts that can't be true leave the snapshot we hold (Codex on #397).
M.Deserialize(OTHER, "v1|s=150|d=abc|f=A|r=95|k=8|lv=12|l=3|t=40|n=1|c=12.11.10,-9999.1.4")
eq("a newer line with done above total is refused", M.DB().chars[OTHER].stamp, 100)
M.Deserialize(OTHER, "v1|s=151|d=abc|f=A|r=95|k=8|lv=12|l=3|t=40|n=9|c=12.5.10,-9999.1.4")
eq("  so is one whose class 'now' is above its total", M.DB().chars[OTHER].stamp, 100)
M.Deserialize(OTHER, "v1|s=152|d=abc|f=A|r=95|k=8|lv=12|l=3|t=40|n=0|c=12.5.10,-9999.1.4")
eq("  or below its done", M.DB().chars[OTHER].stamp, 100)
eq("  the counts held are untouched", M.DB().chars[OTHER].c[12][1], 5)
M.Deserialize(OTHER, "v1|s=101|d=abc|f=A|r=95|k=8|lv=13|l=3|t=40|n=0|c=")
check("a newer one replaces it wholesale, an empty c= included", next(M.DB().chars[OTHER].c) == nil)
M.Deserialize(OTHER, "v1|s=200|garbage")
eq("  a malformed one keeps what we hold", M.DB().chars[OTHER].stamp, 101)

------------------------------------------------------------
-- The tab
------------------------------------------------------------

M.Deserialize(OTHER, "v1|s=102|d=" .. D.VERSION .. "|f=A|r=95|k=8|lv=13|l=3|t=40|n=0|c=12.5.10")
local HIDDEN = "Player-9999-0000CCCC"
AltStableDB[HIDDEN] = { name = "Hidden One", class = "ROGUE", level = 60 }
M.Deserialize(HIDDEN, "v1|s=5|d=abc|f=A|r=1|k=4|lv=60|l=0|t=1|n=0|c=12.1.1")
local realHidden = AltStable.IsCharacterHidden
AltStable.IsCharacterHidden = function(guid) return guid == HIDDEN end

local main = CreateFrame("Frame", nil, UIParent)
main.totalsBar = CreateFrame("Frame", nil, main)
main.totalsBar.core = CreateFrame("Frame", nil, main.totalsBar)
main.bodyScroll = CreateFrame("Frame", nil, main)
local ok, err = pcall(plugin.OnActivate, main)
check("the tab opens", ok, tostring(err))
check("  the grid it replaces is hidden", not main.bodyScroll:IsShown())
check("  the core's totals hidden, ours shown", not main.totalsBar.core:IsShown() and L.foot and L.foot:IsShown())
local foot = L.foot and L.foot.left:GetText() or ""
-- The selected character (the one playing, first) and its total, as in the owner's mockup.
check("  the footer names the selected character", foot:find("Example", 1, true) ~= nil, foot)
check("  with its quests done out of its total", foot:find("quests", 1, true) ~= nil and foot:find("/", 1, true) ~= nil, foot)

local cols = L.Columns()
eq("two columns: the hidden one is left out", #cols, 2)
eq("  the one playing first", cols[1] and cols[1].guid, ME)
local rows = L.DisplayRows(cols)
local hasGroup, hasDesolace = false, false
for _, row in ipairs(rows) do
    if row.isGroup and row.key == "KAL" then hasGroup = true end
    if row.key == 405 then hasDesolace = true end
end
check("  Kalimdor's group and Desolace's row", hasGroup and hasDesolace)
M.DB().collapsed.KAL = true
rows = L.DisplayRows(cols)
hasDesolace = false
for _, row in ipairs(rows) do if row.key == 405 then hasDesolace = true end end
check("  collapsed, Desolace's row goes, the header stays", not hasDesolace)
M.DB().collapsed.KAL = nil

-- The lists: only from this install's done set of the same snapshot.
local mineCol, otherCol = cols[1], cols[2]
local lists = L.ListsFor(mineCol)
check("the character playing has its lists", lists ~= nil and lists[405] ~= nil)
check("  Desolace's done ones include 1365", lists and lists[405] and (function()
    for _, id in ipairs(lists[405].done) do if id == 1365 then return true end end end)())
check("another account's character has none", L.ListsFor(otherCol) == nil)
M.DB().done[ME].stamp = M.DB().done[ME].stamp - 1
check("a done set from another snapshot is not used", L.ListsFor({ guid = ME, snap = M.DB().chars[ME] }) == nil)

M.DB().thisChar = true
eq("This character: one column", #L.Columns(), 1)
M.DB().thisChar = nil
AltStable.IsCharacterHidden = realHidden

-- Forget, cleanup, orphans.
M.Forget(OTHER)
check("forgetting drops the snapshot", M.DB().chars[OTHER] == nil)
local hiddenRec = AltStableDB[HIDDEN]
M.DB().done[HIDDEN] = M.DB().done[HIDDEN] or { [92850] = true }
local hiddenFn = AltStable.IsCharacterHidden
AltStable.IsCharacterHidden = realHidden          -- shown, for the columns below
local function hasCol(guid)
    for _, c in ipairs(L.Columns()) do if c.guid == guid then return true end end
    return false
end
AltStableDB[HIDDEN] = nil
M.DropForgottenOrphans()
check("a snapshot whose core record is missing is kept (#418)", M.DB().chars[HIDDEN] ~= nil)
check("  its quest history too", M.DB().done[HIDDEN] ~= nil)
check("  and it is not a column", not hasCol(HIDDEN))
AltStableDB[HIDDEN] = hiddenRec
check("  it is a column again once the record is restored", hasCol(HIDDEN))
check("  with its quest history", M.DB().done[HIDDEN] ~= nil)
AltStable.IsCharacterHidden = hiddenFn
AltStableDB[HIDDEN] = nil
AltStableConfig.forgottenCharacters = { [HIDDEN] = { at = 1000, forgottenAt = 1000, name = "Hidden" } }
M.DropForgottenOrphans()
check("a forgotten character's orphan snapshot goes", M.DB().chars[HIDDEN] == nil)
check("  from both stores", M.DB().done[HIDDEN] == nil)
check("  ours stays", M.DB().chars[ME] ~= nil)
-- A store of orphans is nothing to build on: the bootstrap asks for a full pull.
do
    local resets, realReset = 0, AltStable.ResetPeerWatermarks
    AltStable.ResetPeerWatermarks = function() resets = resets + 1 end
    local heldChars = M.DB().chars
    M.DB().chars = { ["Player-orphan-1"] = { s = 1 } }
    M.Start()
    eq("a store of orphans asks for a full pull", resets, 1)
    M.DB().chars = heldChars
    M.Start()
    eq("  one attached snapshot doesn't", resets, 1)
    AltStable.ResetPeerWatermarks = realReset
end
AltStableConfig.forgottenCharacters = { [ME] = { at = 1e10, forgottenAt = 1e10, name = "Me" } }
local meRec = AltStableDB[ME]
AltStableDB[ME] = nil
M.DropForgottenOrphans()
check("  never the character being played, even forgotten and unrecorded", M.DB().chars[ME] ~= nil)
-- The footer's fallback (no column selected) reads through the core record too.
local savedSel, savedCols, savedOthers = L.selGuid, L.cols, {}
L.selGuid, L.cols = nil, {}
for guid, rec in pairs(AltStableDB) do savedOthers[guid] = rec end
for guid in pairs(savedOthers) do AltStableDB[guid] = nil end
L.RenderFooter()
check("  the footer doesn't show the orphan snapshot of the character playing",
      (L.foot.left:GetText() or ""):find("not counted yet") ~= nil, L.foot.left:GetText())
for guid, rec in pairs(savedOthers) do AltStableDB[guid] = rec end
L.selGuid, L.cols = savedSel, savedCols
AltStableDB[ME] = meRec
AltStableConfig.forgottenCharacters = nil
M.Cleanup(ME)
check("cleanup keeps only the one asked", M.DB().chars[ME] ~= nil and M.DB().done[ME] ~= nil)

------------------------------------------------------------
-- #398: the toolbar, the selection, the map and the card
------------------------------------------------------------

-- The ME snapshot has Desolace (405, Kalimdor) at least; give it a dungeon too.
local mySnap = M.DB().chars[ME]
mySnap.c[1176] = { 2, 12 }            -- Zul'Farrak
L.SetFilter("dungeon")
local onlyDungeons = true
for _, row in ipairs(L.DisplayRows(L.Columns())) do
    if row.isGroup and row.key ~= "dungeon" then onlyDungeons = false end
end
check("the Dungeons filter shows only the dungeon group", onlyDungeons)
L.SetFilter("all")
eq("  All clears it", M.DB().filter, nil)
L.SetFilter("nonsense")
eq("  an unknown filter changes nothing", M.DB().filter, nil)

M.DB().collapsed.KAL = true
L.search = "desol"
local found, others = false, 0
for _, row in ipairs(L.DisplayRows(L.Columns())) do
    if row.key == 405 then found = true elseif not row.isGroup then others = others + 1 end
end
check("a search finds Desolace, its collapsed group opened", found)
eq("  and nothing else", others, 0)
L.search = nil
M.DB().collapsed.KAL = nil

-- Selection: a row, a character. (The local done set back on the snapshot's
-- stamp: a check above moved it off on purpose.)
M.DB().done[ME].stamp = M.DB().chars[ME].stamp
L.Select(405, ME)
eq("selecting a row", L.selKey, 405)
eq("  and a character", L.selGuid, ME)
local lines = L.ListLines(L.SelectedColumn(), 405)
check("the card's quest list for the character playing", lines ~= nil and #lines > 0)
local hasDone = false
for _, line in ipairs(lines or {}) do if line.text:find("^Done") then hasDone = true end end
check("  with a Done section (1361, 1362, 1365 ... are done)", hasDone)
check("another account's character has no list", L.ListLines({ guid = OTHER, snap = { stamp = 1, c = {} } }, 405) == nil)

-- The map (#398, the owner: zoom to the zone): a zone shows its own map; an
-- instance its entrance zone with the entrance pinned; the Class row Azeroth,
-- dimmed; the player pinned where it stands in the zone shown.
local place = L.Placement(12)
eq("Elwynn shows its own map", place and place.map, 1429)
check("  with no pin of its own", place and place.pin == nil)
place = L.Placement(1176)
eq("Zul'Farrak shows Tanaris, its entrance zone", place and place.map, 1446)
near("  the entrance pinned (x)", place and place.pin and place.pin.x, 0.387)
near("  (y)", place and place.pin and place.pin.y, 0.201)
place = L.Placement(D.CLASS_KEY)
check("the Class row shows Azeroth, dimmed", place and place.map == 947 and place.dim)

-- Elwynn (1429) sits in the Eastern Kingdoms (1415), at x 0.40-0.50, y 0.70-0.80.
local MAPINFO = {
    [1429] = { mapID = 1429, name = "Elwynn Forest", mapType = 3, parentMapID = 1415 },
    [1415] = { mapID = 1415, name = "Eastern Kingdoms", mapType = 2, parentMapID = 947 },
    [947]  = { mapID = 947, name = "Azeroth", mapType = 1, parentMapID = 946 },
}
rawset(_G, "C_Map", {
    GetMapArtLayers = function(map)
        if map == 1429 or map == 947 or map == 1415 then
            return { { layerWidth = 1000, layerHeight = 600, tileWidth = 256, tileHeight = 256 } }
        end
    end,
    GetMapArtLayerTextures = function(map)
        if map ~= 1429 and map ~= 947 and map ~= 1415 then return nil end
        local t = {} for i = 1, 12 do t[i] = 9000 + i end return t
    end,
    GetMapInfo = function(map) return MAPINFO[map] end,
    GetMapRectOnMap = function(map, top)
        if map == 1429 and top == 1415 then return 0.40, 0.50, 0.70, 0.80 end
    end,
    GetBestMapForUnit = function() return 1429 end,
    GetPlayerMapPosition = function(map)
        if map == 1429 then return { GetXY = function() return 0.42, 0.66 end } end
    end,
})
L.ResetMapCache()
check("a zone's art reads", L.MapArt(1429) ~= nil and L.MapArt(1429).w == 1000)
local me = L.PlayerPin(1429)
check("the player is pinned in the zone it stands in", me ~= nil and me.x == 0.42 and me.y == 0.66)
eq("  not in another", L.PlayerPin(1446), nil)
L.Select(1176)
eq("a zone without art falls back to Azeroth", L.shownMap, 947)
L.Select(12)
eq("  a zone with art shows itself", L.shownMap, 1429)

-- The zoom (#398, the owner: "like if we actually zoomed the map", with the
-- world map's open/close sounds): from the whole continent into the zone.
local mf = L.mapFrame
mf.clip:SetSize(600, 186)
L.ResetMapCache()
L.Select(1176)                                  -- Azeroth, still
WoW.sounds = {}
L.Select(12)
check("a zone zooms in from its continent", L.cam and L.cam.zoom and L.cam.zoom.cont == 1415)
eq("  starting on the whole continent", L.cam and L.cam.t, 0)
eq("  with the map's open sound", WoW.sounds[#WoW.sounds], 844)
check("  the camera runs", mf._scripts.OnUpdate ~= nil)
eq("  the zone faded out at first", mf.zone:GetAlpha(), 0)
L.MapTick(0.2)
check("  partway in, the zone shows", L.cam.t > 0 and L.cam.t < 1 and mf.zone:GetAlpha() > 0)
for _ = 1, 20 do if not L.MapTick(0.1) then break end end
eq("  the zoom ends", L.cam.t, 1)
eq("  the zone whole", mf.zone:GetAlpha(), 1)
-- At rest the zone is fitted and centred: 1000x600 in 600x186, scale 0.31.
local _, _, _, tx, ty = mf.tiles[1]:GetPoint(1)
near("  its first tile centred (x)", tx, (600 - 310) / 2)
near("  (y)", ty, 0)
-- The continent behind is zoomed so Elwynn's rect lands on the zone:
-- 310 px for a tenth of the continent, its tiles 256 * 3.1.
near("  the continent zoomed with it", mf.back[1]:GetWidth(), 256 * 3.1)
local _, _, _, bx = mf.back[1]:GetPoint(1)
near("  and aligned (Elwynn's left edge on the zone's)", bx + 0.40 * 1000 * 3.1, (600 - 310) / 2)
mf._scripts.OnUpdate(mf, 0.1)
check("  the camera stops", mf._scripts.OnUpdate == nil)
-- Another place zooms out first, with the close sound.
WoW.sounds = {}
L.Select(1176)
eq("another place zooms out first", L.cam.next and L.cam.next.map, 947)
eq("  with the map's close sound", WoW.sounds[1], 845)
eq("  the old zone still drawn", L.cam.place.map, 1429)
for _ = 1, 20 do if not L.MapTick(0.1) then break end end
check("  then shows the new place", L.cam.place.map == 947 and L.cam.next == nil and L.cam.zoom == nil)
-- Back to the zone mid-zoom-out: the camera turns round.
L.Select(12)
for _ = 1, 20 do if not L.MapTick(0.1) then break end end
L.Select(1176); L.MapTick(0.1)
WoW.sounds = {}
L.Select(12)
check("back mid-zoom-out: it turns round", L.cam.next == nil and L.cam.place.map == 1429 and L.cam.t > 0)
eq("  opening again", WoW.sounds[1], 844)
-- A redraw of the same zone does not zoom again.
for _ = 1, 20 do if not L.MapTick(0.1) then break end end
WoW.sounds = {}
L.Render()
check("a redraw keeps the camera still", L.cam.t == 1 and #WoW.sounds == 0)
-- The player's pin follows the player while the map shows (Codex on #400).
local function mePoint() local _, _, _, x, y = mf.me:GetPoint(1); return x, y end
check("the player is pinned at rest", mf.me:IsShown())
local x1 = mePoint()
C_Map.GetPlayerMapPosition = function() return { GetXY = function() return 0.9, 0.66 end } end
mf.top._scripts.OnUpdate(mf.top, 0.1)
eq("  not re-read every frame", (mePoint()), x1)
mf.top._scripts.OnUpdate(mf.top, 0.2)
near("  re-read a few times a second: it moves", (mePoint()), x1 + (0.9 - 0.42) * 310)
C_Map.GetBestMapForUnit = function() return 1415 end
mf.top._scripts.OnUpdate(mf.top, 0.3)
check("  and goes once the player leaves the zone shown", not mf.me:IsShown())
C_Map.GetBestMapForUnit = function() return 1429 end
-- No character counted: the empty-state message takes the header row (Codex on #400).
local heldChars = M.DB().chars
M.DB().chars = {}
L.Render()
check("no character: the Zone heading hides", not L.zoneHdr:IsShown())
M.DB().chars = heldChars
L.Render()
check("  and shows again with characters", L.zoneHdr:IsShown())
C_Map.GetPlayerMapPosition = function() return { GetXY = function() error("secret") end } end
eq("a position the client keeps secret is no pin", L.PlayerPin(1429), nil)
rawset(_G, "C_Map", nil)
L.ResetMapCache()
eq("no map API: no art, and no error", L.MapArt(1429), nil)
local okR = pcall(L.Render)
check("  the tab still draws", okR)
eq("  and shows no map", L.shownMap, nil)

-- Hide map, and the jump to Class quests.
M.DB().hideMap = true
L.Render()
eq("Hide map is remembered", M.DB().hideMap, true)
M.DB().hideMap = nil
-- The jump from a search and a filter that both hide the Class row (Codex on
-- #399): they give way, the row is drawn, and the grid scrolls to it.
check("the character playing has a Class row", M.DB().chars[ME].c[D.CLASS_KEY] ~= nil)
M.DB().collapsed.class = true
L.SetFilter("dungeon")
L.search = "desol"
L.JumpToClass()
eq("Class quests: the Class row selected", L.selKey, D.CLASS_KEY)
check("  its group opened", M.DB().collapsed.class == nil)
eq("  the search cleared", L.search, nil)
eq("  the filter that hid it cleared", M.DB().filter, nil)
check("  the row is drawn", L.rowY and L.rowY[D.CLASS_KEY] ~= nil)
local vb = L.Bars()
if vb and vb:IsShown() then
    local _, maxV = vb:GetMinMaxValues()
    eq("  and scrolled to, not to the end", vb:GetValue(), math.min(maxV, L.rowY[D.CLASS_KEY]))
end
L.SetFilter("class")
L.JumpToClass()
eq("  a Class filter stays", M.DB().filter, "class")
L.SetFilter("all")

-- Seen in game (#398): the font has no triangle glyphs, so the arrows are drawn;
-- the columns share the width; the buttons are the mockup's, not the game's red.
L.Render()
local foot = L.foot.class.text:GetText() or ""
check("the footer's jump has no glyph the font lacks", not foot:find("\226\150", 1, true), foot)
check("  its arrow is drawn", L.foot.class.arrow ~= nil)

check("the columns are at least the narrowest width", (L.colW or 0) >= 64)
check("  and at most the widest", (L.colW or 0) <= 160)
local btn = L.Button(UIParent, 80, 24, "Try")
eq("a Loremaster button carries its text", btn:GetText(), "Try")
btn:Disable()
btn:Paint(false)
local r = btn.label:GetTextColor()
check("  dimmed when disabled", r < 0.5)
check("the Zone header is there", L.zoneHdr ~= nil and L.zoneHdr:GetText() == "Zone")

-- A snapshot counted before this update keeps its quest list (Codex on #399:
-- the version is what the counting reads, not display fields).
M.DB().chars[ME].ver = "9b0a9380"
M.DB().done[ME].stamp = M.DB().chars[ME].stamp
check("a pre-update snapshot with its done set still lists its quests",
      L.ListsFor({ guid = ME, snap = M.DB().chars[ME] }) ~= nil)

local okD = pcall(plugin.OnDeactivate, main)
check("the tab closes", okD)
check("  the core's totals are back", main.totalsBar.core:IsShown())
check("  the grid is back", main.bodyScroll:IsShown())

rawset(_G, "C_QuestLog", nil)
WoW.finish("test_loremaster", passed, failed)
