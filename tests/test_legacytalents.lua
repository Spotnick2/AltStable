------------------------------------------------------------
-- test_legacytalents.lua - each character's Legacy talents (#500)
--
-- Pinned (the client's shape as measured on 71139, /fp steps as legacytree):
-- the Generic config of trees 1118 / 1187-1189; a reading only with nothing
-- staged, before and after; proven or nothing (config, type, trees, node IDs,
-- ranks, spentInTree, a choice's active entry); the stored text, its order
-- and its parser; the write (only on a change, touched for the delta), the
-- pending write for a record made later; the account-wide layout per build;
-- the triggers (login + retries, a burst of events settled); the merge
-- clearing a newer peer's missing fields; the field on the wire.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
dofile("Libs/LibStub/LibStub.lua")
dofile("Libs/LibDeflate/LibDeflate.lua")

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
dofile("Prompt.lua")
assert(loadfile("Core.lua"))()
dofile("Config.lua")
local T = AltStable._test

-- Timers in the order they fall due, NewTimer cancellable.
local now, due = 0, {}
C_Timer.After = function(d, fn) due[#due + 1] = { at = now + d, fn = fn } end
C_Timer.NewTimer = function(d, fn)
    local e = { at = now + d, fn = fn }
    e.Cancel = function() e.cancelled = true end
    due[#due + 1] = e
    return e
end
local function advance(sec)
    local stop = now + sec
    while true do
        local best, bi
        for i, e in ipairs(due) do
            if e.at <= stop and (not best or e.at < best.at) then best, bi = e, i end
        end
        if not best then break end
        table.remove(due, bi)
        now = best.at
        if not best.cancelled then best.fn() end
    end
    now = stop
end

------------------------------------------------------------
-- The client: one Generic config, three trees, as measured
------------------------------------------------------------

local api
local function fresh()
    api = {
        config = 6966057, type = 3, treeIDs = { 1118, 1187, 1188, 1189 },
        staged = { false },   -- what ConfigHasStagedChanges answers, call by call (the last repeats)
        cap = 4,
        trees = {
            [1187] = { { id = 110291, rank = 3, max = 5, entries = { 136848 } },
                       { id = 110290, rank = 0, max = 5, entries = { 136841 }, edges = { 110291 } } },
            [1188] = { { id = 110301, rank = 1, max = 5, entries = { 136855 }, x = 2400, y = 1750 },
                       { id = 110298, rank = 0, max = 5, type = 1, entries = { 136852, 137374 } } },
            [1189] = { { id = 110313, rank = 0, max = 3, entries = { 136867 } } },
        },
        spells = { [136848] = 1225435, [136841] = 1225451, [136855] = 1225478, [136852] = 1225474,
                   [137374] = 1225474, [136867] = 1225499 },
    }
end
fresh()
local stagedCalls = 0
local function spentIn(tree)
    local s = 0
    for _, n in ipairs(api.trees[tree] or {}) do s = s + (n.rank or 0) end
    return s
end
local function nodeOf(nodeID)
    for _, list in pairs(api.trees) do
        for _, n in ipairs(list) do if n.id == nodeID then return n end end
    end
end
C_Traits = {
    GetConfigIDByTreeID = function(tree) return (tree == 1118 or tree == 1187) and api.config or nil end,
    GetConfigInfo = function(id)
        if id ~= api.config then return nil end
        return { ID = id, name = "", type = api.type, treeIDs = api.treeIDs }
    end,
    ConfigHasStagedChanges = function()
        stagedCalls = stagedCalls + 1
        local v = api.staged[math.min(stagedCalls, #api.staged)]
        if v == "error" then error("not ready") end
        return v
    end,
    GetTreeNodes = function(tree)
        if api.nodesNil == tree then return nil end
        local out = {}
        for _, n in ipairs(api.trees[tree] or {}) do out[#out + 1] = n.id end
        return out
    end,
    GetTreeCurrencyInfo = function(config, tree)
        if api.noSpent == tree then return { { traitCurrencyID = 4225, quantity = 1, maxQuantity = api.cap } } end
        return { { traitCurrencyID = 9999, spentInTree = 77 },
                 { traitCurrencyID = 4225, quantity = 1, maxQuantity = api.cap, spent = 4, spentInTree = spentIn(tree) } }
    end,
    GetNodeInfo = function(config, nodeID)
        local n = nodeOf(nodeID)
        if not n then return { ID = 0 } end
        local active
        if not n.noActive then active = { entryID = n.active or n.entries[1], rank = n.rank } end
        return { ID = n.answer or nodeID, activeRank = n.rank, currentRank = n.rank, ranksPurchased = n.rank,
                 maxRanks = n.max, type = n.type or 0, posX = n.x or 3300, posY = n.y or 850,
                 entryIDs = n.entries, activeEntry = active, visibleEdges = n.edges and (function()
                     local e = {}
                     for i, t in ipairs(n.edges) do e[i] = { targetNode = t, isActive = true } end
                     return e
                 end)() or {} }
    end,
    GetEntryInfo = function(config, entryID) return { definitionID = entryID + 5000 } end,
    GetDefinitionInfo = function(def)
        local entry = def - 5000
        return { spellID = api.spells[entry], overrideName = api.override and api.override[entry] or nil }
    end,
}

dofile("LegacyTalents.lua")
local LT = AltStable.LegacyTalents
check("LegacyTalents loads", type(LT) == "table")

local function read() stagedCalls = 0; return LT.Read() end

------------------------------------------------------------
-- The reading
------------------------------------------------------------

local r, layout = read()
check("a reading of the three trees", r and #r.trees == 3)
eq("  the points per tree", r and (r.trees[1].spent .. "/" .. r.trees[2].spent .. "/" .. r.trees[3].spent), "3/1/0")
eq("  the 4225 row's maxQuantity is the cap", r and r.cap, 4)
eq("  only nodes with a rank", r and #r.trees[1].nodes, 1)
local n1 = r and r.trees[1].nodes[1] or {}
eq("  a node: id, rank, max, entry, spell", ("%s.%s.%s.%s.%s"):format(tostring(n1.id), tostring(n1.rank),
   tostring(n1.max), tostring(n1.entry), tostring(n1.spell)), "110291.3.5.136848.1225435")
eq("  the staged check before and after", stagedCalls, 2)
check("the layout: every node of every tree", layout and #layout.trees == 3 and #layout.trees[1].nodes == 2)
local l1 = layout and layout.trees[1].nodes or {}
eq("  in ascending ID", l1[1] and l1[1].id, 110290)
eq("  with its edges", l1[1] and l1[1].edges[1], 110291)
eq("  position", layout and (layout.trees[2].nodes[2].x .. "," .. layout.trees[2].nodes[2].y), "2400,1750")
eq("  a tiered node's entries", layout and #layout.trees[2].nodes[1].entries, 2)
eq("  each entry's spell", layout and layout.trees[2].nodes[1].entries[1].spell, 1225474)
check("  nothing of the character's choices", layout and layout.trees[1].nodes[2].rank == nil)

-- Proven or nothing.
local function none(name, set, undo)
    set()
    eq(name, read(), nil)
    undo()
end
none("a config of 0: nothing", function() api.config = 0 end, function() api.config = 6966057 end)
none("a config of -1 (the inspect sentinel): nothing", function() api.config = -1 end, function() api.config = 6966057 end)
none("a config of another type: nothing", function() api.type = 4 end, function() api.type = 3 end)
none("a tree missing from the config: nothing", function() api.treeIDs = { 1118, 1187, 1188 } end,
     function() api.treeIDs = { 1118, 1187, 1188, 1189 } end)
none("something staged: nothing", function() api.staged = { true } end, function() api.staged = { false } end)
none("staged unknown (an error): nothing", function() api.staged = { "error" } end, function() api.staged = { false } end)
none("staged during the read: nothing", function() api.staged = { false, true } end, function() api.staged = { false } end)
none("a tree with no node list: nothing", function() api.nodesNil = 1189 end, function() api.nodesNil = nil end)
none("a tree with no nodes: nothing", function() api.trees[1189] = {} end,
     function() api.trees[1189] = { { id = 110313, rank = 0, max = 3, entries = { 136867 } } } end)
none("a node answering with another ID: nothing", function() api.trees[1188][1].answer = 1 end,
     function() api.trees[1188][1].answer = nil end)
none("a node with no rank: nothing", function() api.trees[1188][1].rank = nil end,
     function() api.trees[1188][1].rank = 1 end)
none("a tree with no spentInTree: nothing (never 0)", function() api.noSpent = 1188 end, function() api.noSpent = nil end)
local savedCT = C_Traits
none("no C_Traits: nothing", function() C_Traits = nil end, function() C_Traits = savedCT end)
local savedStaged = C_Traits.ConfigHasStagedChanges
none("no staged check at all: nothing", function() C_Traits.ConfigHasStagedChanges = nil end,
     function() C_Traits.ConfigHasStagedChanges = savedStaged end)

-- The talent chosen on a node.
api.trees[1188][2].rank, api.trees[1188][2].active = 2, 137374
r = read()
eq("a tiered node with a rank: its active entry", r and r.trees[2].nodes[1].entry, 137374)
api.trees[1188][2].noActive = true
eq("  without one, two entries: not proven", read(), nil)
api.trees[1188][2].rank, api.trees[1188][2].noActive, api.trees[1188][2].active = 0, nil, nil
api.trees[1188][1].noActive = true
r = read()
eq("a node of one entry without an active entry: that entry", r and r.trees[2].nodes[1].entry, 136855)
api.trees[1188][1].type = 2
eq("  but a choice without its active entry: not proven", read(), nil)
api.trees[1188][1].type, api.trees[1188][1].noActive = nil, nil

------------------------------------------------------------
-- The stored text
------------------------------------------------------------

r = read()
local text = LT.Encode(r)
eq("the text", text, "v1;c4;1187:3:110291.3.5.136848.1225435;1188:1:110301.1.5.136855.1225478;1189:0:")
-- Nodes in ascending ID whatever order the client lists them in.
api.trees[1187][2].rank = 1
local a = LT.Encode(read())
api.trees[1187] = { api.trees[1187][2], api.trees[1187][1] }
local b = LT.Encode(read())
eq("  the same reading, nodes listed in another order: the same text", a, b)
check("  in ascending ID", a:find("1187:4:110290.1.5.136841.1225451,110291.3.5.136848.1225435;", 1, true) ~= nil, a)
fresh()

local d = LT.Decode(text)
eq("parsed back: the same text", d and LT.Encode(d), text)
eq("  the points", d and select(1, LT.Points(d)), 4)
eq("  of the cap", d and select(2, LT.Points(d)), 4)
for _, bad in ipairs({ "v2;c4;1187:0:;1188:0:;1189:0:", "c4;1187:0:;1188:0:;1189:0:", "v1;c4;1187:0:;1188:0:",
                       "v1;c4;1187:0:;1189:0:;1188:0:", "v1;c4;1187:0:;1188:0:;1189:0:;1190:0:",
                       "v1;c4;1187:0:x;1188:0:;1189:0:", "v1;c4;1187:1:1.2.3.4;1188:0:;1189:0:", "junk" }) do
    eq("junk is no reading: " .. bad, LT.Decode(bad), nil)
end
eq("a number is no reading", LT.Decode(5), nil)
eq("Get on a record without the field", LT.Get({}), nil)

eq("tree names, without Blizzard's Legacy UI", LT.TreeName(1189), "Resourcefulness")
LegacyTreeData = { { treeID = 1189, name = "Ressources" } }
eq("  with it, the game's", LT.TreeName(1189), "Ressources")
LegacyTreeData = nil

------------------------------------------------------------
-- Scanning and writing
------------------------------------------------------------

local me = UnitGUID("player")
local touched = 0
local realTouch = AltStable.TouchCharacter
AltStable.TouchCharacter = function(g) if g == me then touched = touched + 1 end end
AltStableDB = { [me] = { guid = me, name = "Me", lastUpdate = 1 } }
AltStableConfig = {}
WoW.now = 1000
check("a scan with a proven reading says so", LT.Scan())
eq("  writes the text", AltStableDB[me].legacyTalents, text)
eq("  and when", AltStableDB[me].legacyAt, 1000)
eq("  touched for the delta", touched, 1)
eq("  and learns the layout", AltStableConfig.legacyLayout and AltStableConfig.legacyLayout.build, "71139")
check("  usable on this build", LT.Layout() ~= nil)
WoW.now = 2000
LT.Scan()
eq("the same reading again: not re-dated", AltStableDB[me].legacyAt, 1000)
eq("  not touched", touched, 1)
api.trees[1189][1].rank = 1
LT.Scan()
eq("a change: re-dated", AltStableDB[me].legacyAt, 2000)
eq("  and touched", touched, 2)
fresh()
api.staged = { true }
check("a staged reading isn't proven", not LT.Scan())
eq("  and changes nothing", AltStableDB[me].legacyAt, 2000)
api.staged = { false }

AltStableConfig.legacyLayout.build = "70000"
eq("a layout of another build isn't used", LT.Layout(), nil)
AltStableConfig.legacyLayout = { build = "71139", trees = { {}, {} } }
eq("  nor one without the three trees", LT.Layout(), nil)

-- A reading before the record exists waits for the scan.
AltStableDB = {}
check("no record yet: the reading is still proven", LT.Scan())
eq("  kept, not written anywhere", AltStableDB[me], nil)
AltStableDB[me] = { guid = me, name = "Me" }
LT.OnScanned({ guid = "Player-other" })
eq("  another character's scan doesn't take it", AltStableDB[me].legacyTalents, nil)
LT.OnScanned(AltStableDB[me])
eq("  the scan writes it", AltStableDB[me].legacyTalents, text)
AltStableDB[me].legacyTalents = nil
LT.OnScanned(AltStableDB[me])
eq("  once", AltStableDB[me].legacyTalents, nil)

------------------------------------------------------------
-- When it reads
------------------------------------------------------------

local frame = T.LegacyFrame
local function onEv(ev, ...) frame:GetScript("OnEvent")(frame, ev, ...) end
for _, ev in ipairs(T.LegacyEvents) do
    check("listens to " .. ev, frame:IsEventRegistered(ev))
end
check("listens to PLAYER_ENTERING_WORLD", frame:IsEventRegistered("PLAYER_ENTERING_WORLD"))

local scans = 0
local realScan = LT.Scan
LT.Scan = function() scans = scans + 1; return api.proven ~= false end
onEv("PLAYER_ENTERING_WORLD", false, false)
advance(60)
eq("zoning reads nothing", scans, 0)
onEv("PLAYER_ENTERING_WORLD", true, false)
advance(2.9)
eq("a login reads after 3 s", scans, 0)
advance(0.2)
eq("  then", scans, 1)
advance(60)
eq("  proven: no retry", scans, 1)
api.proven = false
onEv("PLAYER_ENTERING_WORLD", false, true)
advance(3)
eq("a reload reads too", scans, 2)
advance(10)
eq("  not proven: again 10 s later", scans, 3)
advance(30)
eq("  and 30 s after that", scans, 4)
advance(120)
eq("  then it stops", scans, 4)
api.proven = nil

onEv("TRAIT_CONFIG_UPDATED", 6966057)
advance(0.5)
onEv("TRAIT_TREE_CURRENCY_INFO_UPDATED", 1187)
advance(0.5)
onEv("TRAIT_TREE_CURRENCY_INFO_UPDATED", 1188)
advance(0.9)
eq("a burst of events: nothing until it settles", scans, 4)
advance(0.2)
eq("  then one reading", scans, 5)
advance(5)
eq("  only one", scans, 5)
LT.Scan = realScan

------------------------------------------------------------
-- Sync: on the wire, and the merge
------------------------------------------------------------

local rec = { guid = "Player-L", name = "L", class = "MAGE", level = 30, lastUpdate = 200,
              legacyTalents = text, legacyAt = 190 }
AltStableDB = {}
T.DeserializeFullDB(T.SerializeChar(rec) .. "\n" .. T.CHAR_SEP, "Peer")
local got = AltStableDB["Player-L"]
eq("the text crosses the wire unchanged", got and got.legacyTalents, text)
eq("  its date as a number", got and got.legacyAt, 190)
T.DeserializeFullDB(T.SerializeChar({ guid = "Player-L", name = "L", class = "MAGE", level = 30,
    lastUpdate = 300 }) .. "\n" .. T.CHAR_SEP, "OlderBuildPeer")
eq("a newer record without the fields clears ours", AltStableDB["Player-L"].legacyTalents, nil)
eq("  with its date", AltStableDB["Player-L"].legacyAt, nil)

AltStable.TouchCharacter = realTouch
WoW.finish("test_legacytalents", passed, failed)
