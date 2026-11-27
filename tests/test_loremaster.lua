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

-- The data from QuestieDB 1.1.3 and Questie 12.11.1 (#472).
eq("#472: the data is QuestieDB 1.1.3's", D.SOURCE.questiedb, "1.1.3")
check("  the old Khan quests Questie blacklists on Forever are gone", Q[1374] == nil and Q[1380] == nil)
check("  1381 stays only as a row the rules look at", Q[1381] ~= nil and Q[1381][6] == 2)
check("  their Forever replacements count", Q[93128] ~= nil and Q[93128][6] == 0
      and Q[96222] ~= nil and Q[96222][6] == 0)
check("  the other newly blacklisted quests are gone",
      Q[78917] == nil and Q[87318] == nil and Q[88757] == nil and Q[88758] == nil)
-- Darkspear Islands' level brackets now exclude each other: one per character.
eq("doing the 40 bracket closes the 30 one", (M.ClosedWhy(98887, P("Horde", 2, 8, 35), Set(98889))), "excl")
eq("  nothing done: open", (M.ClosedWhy(98887, P("Horde", 2, 8, 35), {})), nil)
-- Counted as the rules count any alternatives (#374): each bracket in the
-- total until one is done, then that one alone (Codex review of #476).
do
    local function bgState(done)
        local l = M.Count(P("Horde", 2, 8, 35), done, true).lists[-25] or {}
        local state = {}
        for _, st in ipairs({ "open", "missed", "done" }) do
            for _, id in ipairs(l[st] or {}) do
                if id >= 98887 and id <= 98893 then state[#state + 1] = id .. "=" .. st end
            end
        end
        table.sort(state)
        return table.concat(state, " ")
    end
    eq("a level-35 Horde character with no bracket done counts all four",
       bgState({}), "98887=open 98889=open 98891=open 98893=open")
    eq("  one done: that one, the others missed and out of the total",
       bgState(Set(98887)), "98887=done 98889=missed 98891=missed 98893=missed")
end
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

-- Prerequisites through the whole chain (#429), on the shipped data: 92849 is
-- race 95 only, 92850 (Alliance) needs it, 99260 (Alliance) needs 92850.
do
    local human, skyborne = P("Alliance", 1, 8, 30), P("Alliance", 95, 8, 30)
    check("#429: a Human can't take 92849", not M.Eligible(Q[92849], human, {}))
    check("  nor 92850 after it", not M.Eligible(Q[92850], human, {}))
    check("  nor 99260 two steps on", not M.Eligible(Q[99260], human, {}))
    check("  a race-95 character can take all three", M.Eligible(Q[92849], skyborne, Set(92727))
          and M.Eligible(Q[92850], skyborne, {}) and M.Eligible(Q[99260], skyborne, {}))
    check("  a done 92849 counts as met through the chain",
          M.Eligible(Q[92850], human, Set(92849)) and M.Eligible(Q[99260], human, Set(92849)))
    -- A cycle (A needs B and a Horde-only one, B needs A, C needs B, Z needs
    -- A): for a Human A is impossible, so B, C and Z are too, whichever is
    -- asked first. Asking Z first walks Z, A, B, back to A: B leans on A while
    -- A is still open, and must not be remembered as possible.
    Q[9100101] = { 12, nil, 1, 0, 0, 0, "A", 0, nil, nil, { 9100102, 9100002 } }
    Q[9100102] = { 12, nil, 1, 0, 0, 0, "B", 0, nil, { 9100101 } }
    Q[9100103] = { 12, nil, 1, 0, 0, 0, "C", 0, nil, { 9100102 } }
    Q[9100104] = { 12, nil, 1, 0, 0, 0, "D", 0, nil, { 9100105 } }
    Q[9100105] = { 12, nil, 1, 0, 0, 0, "E", 0, nil, { 9100104 } }
    Q[9100106] = { 12, nil, 1, 0, 0, 0, "Z", 0, nil, { 9100101 } }
    Q[9100107] = { 12, nil, 1, 0, 0, 0, "Unknown pre-quest", 0, nil, { 9199999 } }
    local memo = {}
    local z1, c1 = M.Eligible(Q[9100106], human, {}, memo), M.Eligible(Q[9100103], human, {}, memo)
    memo = {}
    local c2, z2 = M.Eligible(Q[9100103], human, {}, memo), M.Eligible(Q[9100106], human, {}, memo)
    check("  a cycle with an impossible link: Z then C, both impossible", not z1 and not c1)
    check("  C then Z, the same", not c2 and not z2)
    check("  and A itself", not M.Eligible(Q[9100101], human, {}))
    memo = {}
    check("  a cycle with nothing impossible: both possible, no loop",
          M.Eligible(Q[9100104], human, {}, memo) and M.Eligible(Q[9100105], human, {}, memo))
    check("  a pre-quest the table doesn't hold is possible", M.Eligible(Q[9100107], human, {}))
    for id = 9100101, 9100107 do Q[id] = nil end
end
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
      and snap.level == 30 and snap.ver == M.SNAP_VERSION)
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

-- #538 (a CurseForge report: Deadmines, Stockade and Alchemy "missing"). Every
-- quest under the three is Alliance's: an Alliance character has the rows at
-- any level, a Horde one never does.
local DEADMINES, STOCKADE, ALCHEMY, RFC = 1581, 717, -181, 2437
local ally = M.Count({ faction = "Alliance", race = 1, class = 1, level = 5 }, {})
check("an Alliance level-5 human counts The Deadmines", ally.c[DEADMINES] ~= nil)
check("  The Stockade", ally.c[STOCKADE] ~= nil)
check("  and Alchemy", ally.c[ALCHEMY] ~= nil)
local horde = M.Count({ faction = "Horde", race = 2, class = 1, level = 5 }, {})
check("a Horde orc counts none of them",
    horde.c[DEADMINES] == nil and horde.c[STOCKADE] == nil and horde.c[ALCHEMY] == nil)
check("  but Ragefire Chasm", horde.c[RFC] ~= nil)

-- Those rows are not listed for a Horde roster, and its headers say so.
local hordeCol = { guid = "Player-1-H", snap = { faction = "Horde", race = 2, class = 1, level = 20,
    c = { [RFC] = { 0, 3 }, [-24] = { 0, 1 } } } }
local function findGroup(rows, key)
    for _, row in ipairs(rows) do if row.isGroup and row.key == key then return row end end
end
local function holds(list, key)
    for _, k in ipairs(list or {}) do if k == key then return true end end
    return false
end
L.SetFilter("dungeon")
local dg = findGroup(L.DisplayRows({ hordeCol }), "dungeon")
check("Horde roster, Dungeons: the header carries the rows not listed",
    dg and holds(dg.hidden, DEADMINES) and holds(dg.hidden, STOCKADE))
check("  never a row it lists", dg and not holds(dg.hidden, RFC))
check("  in the table's order", dg and dg.hidden[1] and D.ZONES[dg.hidden[1]][5] <= D.ZONES[dg.hidden[#dg.hidden]][5])
local text = L.GroupText(dg, false)
check("  its text says how many", text:find(#dg.hidden .. " not listed", 1, true) ~= nil, text)
check("  a group with nothing hidden says nothing",
    not L.GroupText({ label = "Raids", n = 2 }, false):find("not listed", 1, true))
L.cols = { hordeCol }
WoW.tooltipLines = {}
L.GroupOnEnter({ key = "dungeon", hidden = dg.hidden })
local tip = table.concat(WoW.tooltipLines, "\n")
check("  hovered, it names The Deadmines", tip:find("The Deadmines", 1, true) ~= nil, tip)
check("  and why, for one character: nothing counted", tip:find("no quests counted for this character", 1, true) ~= nil, tip)
L.cols = { hordeCol, hordeCol }
WoW.tooltipLines = {}
L.GroupOnEnter({ key = "dungeon", hidden = dg.hidden })
tip = table.concat(WoW.tooltipLines, "\n")
check("  or for several", tip:find("no quests counted for any of these characters", 1, true) ~= nil, tip)
WoW.tooltipLines = {}
L.GroupOnEnter({ key = "raid" })
eq("  a header with nothing hidden has no tooltip", #WoW.tooltipLines, 0)

-- A group whose every row is hidden still gets its header, to say so.
L.SetFilter("profession")
local pg = findGroup(L.DisplayRows({ hordeCol }), "profession")
check("Professions: Herbalism listed, Alchemy not", pg and pg.n == 1 and holds(pg.hidden, ALCHEMY))
hordeCol.snap.c[-24] = nil
pg = findGroup(L.DisplayRows({ hordeCol }), "profession")
check("  with no profession row at all, the header stays, n = 0", pg and pg.n == 0 and holds(pg.hidden, ALCHEMY))
L.SetFilter("all")

-- A row whose quests count only once done (Codex review of #539): a level-60
-- human can take Craftsman's Writ: Runecloth Bag (94353), yet the row is not
-- counted, so not listed, until a writ is done - hence "counted", not "can take".
local WRITS = 16941
local human60 = { faction = "Alliance", race = 1, class = 1, level = 60 }
check("a level-60 human may take a writ", M.Eligible(D.QUESTS[94353], human60, {}))
check("  yet Craftsman's Writs is not counted before one is done", M.Count(human60, {}).c[WRITS] == nil)
check("  and is once one is", M.Count(human60, { [94353] = true }).c[WRITS] ~= nil)
local writCol = { guid = "Player-1-W", snap = { faction = "Alliance", race = 1, class = 1, level = 60,
    c = { [ALCHEMY] = { 0, 1 } } } }
L.SetFilter("profession")
local wg = findGroup(L.DisplayRows({ writCol }), "profession")
check("  so the Professions header lists it as not listed", wg and holds(wg.hidden, WRITS))
L.SetFilter("all")

-- A search narrows what's "not listed" too.
L.search = "deadmines"
local srows = L.DisplayRows({ hordeCol })
local sg = findGroup(srows, "dungeon")
check("a search for Deadmines: Dungeons' header says it's not listed",
    sg and #sg.hidden == 1 and sg.hidden[1] == DEADMINES)
eq("  and no other header", #srows, 1)
L.search = nil

-- No column: no header claims anything (the empty-state message speaks).
eq("no columns, no rows", #L.DisplayRows({}), 0)

-- "Not listed" means some other character would have the row, or will once
-- one of its quests is done (an unsure quest counts only then): every row of
-- the table holds a quest that isn't reference-only. A regenerated table that
-- breaks this fails here, and the header would then need to skip such rows.
do
    local rowHasQuest = {}
    for _, q in pairs(D.QUESTS) do
        -- Upper Blackrock Spire's quests count under its own row (#537).
        if q[6] % 4 < 2 and q[1] then rowHasQuest[M.UPPER_Q[q] and M.UBRS_KEY or q[1]] = true end
    end
    local empty = {}
    for key in pairs(D.ZONES) do if not rowHasQuest[key] then empty[#empty + 1] = tostring(key) end end
    eq("every row of the table has a quest to count", table.concat(empty, ","), "")
end

-- Blackrock Spire, Lower and Upper (#537).
do
    local LOWER, UPPER = 1583, M.UBRS_KEY
    local ok, bad = true, {}
    for _, id in ipairs(M.UPPER_BRS) do
        local q = D.QUESTS[id]
        if not (q and q[1] == LOWER and q[2] == nil) then ok = false; bad[#bad + 1] = tostring(id) end
    end
    check("every Upper quest is a Blackrock Spire quest of the table", ok, table.concat(bad, ","))
    eq("  twelve of them", #M.UPPER_BRS, 12)
    eq("1583 is Lower Blackrock Spire", L.ZoneName(LOWER), "Lower Blackrock Spire")
    eq("Upper Blackrock Spire's row", L.ZoneName(UPPER), "Upper Blackrock Spire")
    eq("  a dungeon", D.ZONES[UPPER][1], "dungeon")
    eq("  right after Lower", D.ZONES[UPPER][5], D.ZONES[LOWER][5] + 0.5)
    check("  the same entrance on the map", D.ZONES[UPPER][6] == D.ZONES[LOWER][6]
          and D.ZONES[UPPER][7] == D.ZONES[LOWER][7] and D.ZONES[UPPER][8] == D.ZONES[LOWER][8])
    local spire = { faction = "Horde", race = 2, class = 1, level = 60 }
    local after = M.Count(spire, {}).c
    eq("Drakkisath's Demise counts under Upper", M.KeyOf(D.QUESTS[5102], spire), UPPER)
    eq("  Seal of Ascension under Lower (done there)", M.KeyOf(D.QUESTS[4742], spire), LOWER)
    -- Lower and Upper add up to the one row there was.
    local held = M.UPPER_Q
    M.UPPER_Q = {}
    local before = M.Count(spire, {}).c
    M.UPPER_Q = held
    check("a Horde 60's Lower and Upper both counted", after[LOWER] and after[UPPER])
    eq("  their totals add up to Blackrock Spire's", after[LOWER][2] + after[UPPER][2], before[LOWER][2])
    local done = { [5102] = true, [4742] = true }
    after, before = M.Count(spire, done).c, nil
    M.UPPER_Q = {}
    before = M.Count(spire, done).c
    M.UPPER_Q = held
    eq("  and so does what's done", after[LOWER][1] + after[UPPER][1], before[LOWER][1])
    eq("  Drakkisath's under Upper", after[UPPER][1], 1)
    -- The rows: Lower, then Upper, side by side in Dungeons.
    local col = { guid = "Player-1-S", snap = { faction = "Horde", race = 2, class = 1, level = 60,
                                                 c = { [LOWER] = { 1, 20 }, [UPPER] = { 1, 14 } } } }
    L.SetFilter("dungeon")
    local rows = L.DisplayRows({ col })
    local at = {}
    for i, r in ipairs(rows) do if not r.isGroup then at[r.key] = i end end
    check("Dungeons lists Lower, then Upper right after it", at[LOWER] and at[UPPER] == at[LOWER] + 1)
    L.SetFilter("all")
    L.search = "blackrock spire"
    rows = L.DisplayRows({ col })
    at = {}
    for i, r in ipairs(rows) do if not r.isGroup then at[r.key] = i end end
    check("a search for Blackrock Spire finds both", at[LOWER] ~= nil and at[UPPER] ~= nil)
    L.search = nil
    -- A synced snapshot carries both rows.
    M.DB().chars["Player-1-S"] = { stamp = 5, ver = M.SNAP_VERSION, level = 60, faction = "Horde", race = 2,
                                   class = 1, completed = 2, cls = { done = 0, total = 0, now = 0 },
                                   c = { [LOWER] = { 1, 20 }, [UPPER] = { 1, 14 } } }
    local back = M.Parse(M.Serialize("Player-1-S"))
    check("the sync line carries Upper's row", back and back.c[UPPER] and back.c[UPPER][2] == 14)
    M.DB().chars["Player-1-S"] = nil
    -- Seal of Ascension, Upper's key: shown under it like a raid's attunement.
    local a = M.Attunement(UPPER, spire, { [4742] = true })
    check("Upper's key chain: Seal of Ascension, 1 of 2 done", a and a.total == 2 and a.done == 1, a and a.done)
    eq("  for the Alliance too", #(M.AttuneChain(UPPER, { faction = "Alliance", race = 1, class = 1, level = 60 }) or {}), 2)
    check("the export's row names hold Upper", (M.WriteZoneNames() or true) and M.DB().zones[UPPER]
          and M.DB().zones[UPPER].name == "Upper Blackrock Spire")
end

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

-- A snapshot counted with these rules keeps its quest list (Codex on #399:
-- the version is what the counting reads, not display fields).
M.DB().chars[ME].ver = M.SNAP_VERSION
M.DB().done[ME].stamp = M.DB().chars[ME].stamp
check("a snapshot with its done set lists its quests",
      L.ListsFor({ guid = ME, snap = M.DB().chars[ME] }) ~= nil)
-- One counted before the whole-chain rule (#429), with the bare data version,
-- is another version's until that character is scanned again.
M.DB().chars[ME].ver = D.VERSION
check("#429: a snapshot from before the chain rule lists nothing",
      L.ListsFor({ guid = ME, snap = M.DB().chars[ME] }) == nil)
check("  the rule's version is the data's plus the rules' (r3: Blackrock Spire split, #537)",
      M.SNAP_VERSION == D.VERSION .. "r3")
do
    WoW.tooltipLines = {}
    L.CellOnEnter({ info = { col = { guid = ME, snap = M.DB().chars[ME], name = "Old", class = "MAGE", level = 30 },
                             key = 405, row = { 2, 5 } } })
    local said = table.concat(WoW.tooltipLines, " / ")
    check("  and its tooltip says it was counted with another version",
          said:find("Counted with another version", 1, true) ~= nil, said)
end
M.DB().chars[ME].ver = M.SNAP_VERSION

------------------------------------------------------------
-- #487: raid attunement chains, shown under their raid
------------------------------------------------------------
-- What has to hold: every step is a quest of the shipped table, each chain
-- for one faction, and the chain is the one the character's faction can take;
-- a step is done by any of its quests (6403 or 99435), Horde's chain opens
-- with 98325; attuned = the last step done; the counts and D.VERSION don't
-- move; a raid with a chain shows for a character with nothing counted under
-- it, its empty cell has a hover, and the list and card show the chain only
-- from this install's done set.
do
    local ALLIANCE, HORDE = P("Alliance", 1, 1, 60), P("Horde", 2, 1, 60)
    local stepsOk, bad = true, {}
    for key, chains in pairs(M.ATTUNE) do
        -- A raid's, or Upper Blackrock Spire's key chain (#537).
        local isRow = D.ZONES[key] and (D.ZONES[key][1] == "raid" or key == M.UBRS_KEY)
        if not isRow then stepsOk = false; bad[#bad + 1] = "raid " .. key end
        for _, chain in ipairs(chains) do
            for _, step in ipairs(chain) do
                for _, id in ipairs(type(step) == "table" and step or { step }) do
                    if not Q[id] then stepsOk = false; bad[#bad + 1] = tostring(id) end
                end
            end
        end
    end
    check("every attunement raid is a raid row, every step a quest of the table", stepsOk, table.concat(bad, ","))

    local ony = 2159
    local a = M.Attunement(ony, ALLIANCE, {})
    eq("Onyxia, Alliance: 16 steps", a and a.total, 16)
    eq("  opening with Dragonkin Menace", a and a.steps[1].id, 4182)
    eq("  none done, the first is next", a and a.next, 1)
    check("  not attuned", a and not a.attuned)
    local h = M.Attunement(ony, HORDE, {})
    eq("Onyxia, Horde: 15 steps", h and h.total, 15)
    eq("  opening with Blood and Thunder (98325)", h and h.steps[1].id, 98325)
    eq("  ending with Blood of the Black Dragon Champion", h and h.steps[15].id, 6602)

    -- The Great Masquerade by its other ID (Codex on the plan): the step is done.
    local masq = Set(4182, 4183, 4184, 4185, 4186, 4223, 4224, 4241, 4242, 4264, 4282, 4322, 6402, 99435)
    a = M.Attunement(ony, ALLIANCE, masq)
    eq("99435 completes The Great Masquerade's step", a.steps[14].state, "done")
    eq("  naming the one done", a.steps[14].id, 99435)
    eq("  14 of 16, The Dragon's Eye next", a.done .. ":" .. tostring(a.next), "14:15")
    masq[6501], masq[6502] = true, true
    a = M.Attunement(ony, ALLIANCE, masq)
    check("the last step done: attuned", a.attuned and a.done == 16 and a.next == nil)

    -- Naxxramas: one step, any of the three.
    for _, id in ipairs({ 9121, 9122, 9123 }) do
        local n = M.Attunement(3456, ALLIANCE, Set(id))
        check("Naxxramas attuned by " .. id, n and n.total == 1 and n.attuned)
    end
    eq("Blackwing Lair: one step for either faction", (M.Attunement(2677, HORDE, {}) or {}).total, 1)
    eq("a raid without a chain has none", M.Attunement(3606, ALLIANCE, {}), nil)

    -- Nothing counted twice: the counts and the data version are the ones before.
    -- A mage: Onyxia's Lair's one quest, Quel'Serrar, is for warriors and paladins.
    local before = M.Count(P("Alliance", 1, 8, 60), masq).c
    eq("Onyxia's Lair counts nothing for a mage, the chain done", before[ony], nil)
    check("  Stormwind still counts The Great Masquerade's step", before[1519] and before[1519][1] >= 1)
    eq("  D.VERSION is the one the table shipped with", D.VERSION, "cabf3cd3")

    -- The tab: a character with a local done set and a synced one.
    local AG, SG = "Player-487-AAAA0001", "Player-487-AAAA0002"
    AltStableDB[AG] = { name = "Attuner", class = "WARRIOR", level = 60, scannedHere = true }
    AltStableDB[SG] = { name = "Synced", class = "MAGE", level = 60 }
    M.DB().chars[AG] = { stamp = 50, ver = M.SNAP_VERSION, faction = "Alliance", race = 1, class = 1, level = 60,
                         c = { [1519] = { 3, 9 } } }
    M.DB().done[AG] = { stamp = 50, ids = Set(4182, 4183) }
    M.DB().chars[SG] = { stamp = 60, ver = M.SNAP_VERSION, faction = "Horde", race = 2, class = 8, level = 60,
                         c = { [1637] = { 1, 4 } } }
    local colA, colS
    for _, c in ipairs(L.Columns()) do
        if c.guid == AG then colA = c elseif c.guid == SG then colS = c end
    end
    local shown = false
    for _, row in ipairs(L.DisplayRows({ colA })) do if row.key == ony then shown = true end end
    check("Onyxia's Lair shows for a character with nothing counted there", shown)
    check("  its chain applies to both columns", L.AttuneApplies(colA, ony) and L.AttuneApplies(colS, ony))
    eq("  the synced one has no attunement to show", L.AttuneFor(colS, ony), nil)
    local att = L.AttuneFor(colA, ony)
    eq("  the local one: 2 of 16", att and L.AttuneText(att), "Attunement 2/16")
    local lines = L.ListLines(colA, ony) or {}
    eq("its quest list opens with the attunement", lines[1] and lines[1].text, "Attunement (2/16)")
    check("  the next step marked", lines[4] and lines[4].text:sub(1, 2) == "> ", lines[4] and lines[4].text)
    check("  with the zone it is counted in", lines[2] and lines[2].text:find("Burning Steppes", 1, true) ~= nil,
          lines[2] and lines[2].text)

    WoW.tooltipLines = {}
    local okHover, herr = pcall(L.CellOnEnter, { info = { col = colA, key = ony } })
    check("an empty attunement cell's hover is no error", okHover, tostring(herr))
    local said = table.concat(WoW.tooltipLines, " / ")
    check("  and shows the chain", said:find("Attunement (2/16)", 1, true) ~= nil, said)
    WoW.tooltipLines = {}
    L.CellOnEnter({ info = { col = colS, key = ony } })
    said = table.concat(WoW.tooltipLines, " / ")
    check("  a synced one's says it shows after a login here", said:find("logs in here", 1, true) ~= nil, said)
    -- Codex on PR #489: a synced warrior with Quel'Serrar done has a complete 1/1
    -- cell, and still no attunement to show; the hint stays.
    WoW.tooltipLines = {}
    L.CellOnEnter({ info = { col = colS, key = ony, row = { 1, 1 } } })
    said = table.concat(WoW.tooltipLines, " / ")
    check("  a synced complete cell still says it shows after a login here", said:find("logs in here", 1, true) ~= nil, said)

    -- The empty cell shows the attunement's steps, dimmed (owner, after PR #489).
    local ct, cr, _, _, ci = L.CellFill(colA, ony, nil)
    eq("an empty attunement cell shows its steps", ct, "2/16")
    -- Clearly darker than a 0/n count (0.55): 0.45 looked the same in game.
    check("  dimmed, clearly below a 0/n count", cr and cr <= (L.CellRGB(0, 1)) - 0.2, tostring(cr))
    check("  with its hover", ci and ci.key == ony and ci.row == nil)
    ct, cr, _, _, ci = L.CellFill(colS, ony, nil)
    check("a synced one's stays empty, with its hover", ct == "" and cr == nil and ci and ci.key == ony, ct)
    ct, _, _, _, ci = L.CellFill(colA, 3606, nil)
    check("an empty cell without a chain stays empty, no hover", ct == "" and ci == nil, ct)
    ct, cr = L.CellFill(colA, ony, { 1, 1 })
    eq("a counted cell keeps its count", ct, "1/1")
    eq("  in its usual colour", cr, (L.CellRGB(1, 1)))
    local allDone = Set(4182, 4183, 4184, 4185, 4186, 4223, 4224, 4241, 4242, 4264, 4282, 4322, 6402, 6403, 6501, 6502)
    M.DB().done[AG].ids = allDone
    ct, cr = L.CellFill(colA, ony, nil)
    check("attuned: 16/16 in a dim gold", ct == "16/16" and cr and cr > 0.5 and cr < 1, ct .. " " .. tostring(cr))
    M.DB().done[AG].ids = Set(4182, 4183)

    -- Codex on PR #489: Blood and Thunder starts in Kargath, so the zone after it
    -- says it is where the quest is counted, not where it starts.
    local HG = "Player-487-AAAA0003"
    AltStableDB[HG] = { name = "Hordling", class = "WARRIOR", level = 60, scannedHere = true }
    M.DB().chars[HG] = { stamp = 70, ver = M.SNAP_VERSION, faction = "Horde", race = 2, class = 1, level = 60,
                         c = { [1637] = { 0, 4 } } }
    M.DB().done[HG] = { stamp = 70, ids = {} }
    local colH
    for _, c in ipairs(L.Columns()) do if c.guid == HG then colH = c end end
    local hl = colH and L.ListLines(colH, ony) or {}
    eq("Horde's list: 0 of 15", hl[1] and hl[1].text, "Attunement (0/15)")
    check("  its opener is the next step, counted under Lower Blackrock Spire (#537)",
          hl[2] and hl[2].text:sub(1, 2) == "> " and hl[2].text:find("(counted under Lower Blackrock Spire)", 1, true) ~= nil,
          hl[2] and hl[2].text)
    M.DB().chars[HG], M.DB().done[HG], AltStableDB[HG] = nil, nil, nil

    L.Select(ony, AG)
    local cardLeft = L.Card() and L.Card().left:GetText() or ""
    check("the card says the attunement", cardLeft:find("Attunement 2/16", 1, true) ~= nil, cardLeft)
    check("  and View quests is on, with nothing counted there", L.Card().view:IsEnabled())
    M.DB().chars[AG], M.DB().done[AG], M.DB().chars[SG] = nil, nil, nil
    AltStableDB[AG], AltStableDB[SG] = nil, nil
end

local okD = pcall(plugin.OnDeactivate, main)
check("the tab closes", okD)
check("  the core's totals are back", main.totalsBar.core:IsShown())
check("  the grid is back", main.bodyScroll:IsShown())

rawset(_G, "C_QuestLog", nil)
WoW.finish("test_loremaster", passed, failed)
