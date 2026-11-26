------------------------------------------------------------
-- LegacyTalents.lua - each character's Legacy talents (#500)
--
-- Legacy points (trait currency 4225) are earned account-wide; each
-- character spends its own in three trees. Measured on 1.60.1.71139
-- (/fp steps as legacytree, results on #500):
--   * one trait config of type Generic (3) holds them, readable from
--     PLAYER_LOGIN on: C_Traits.GetConfigIDByTreeID(1118) (or of 1187), and
--     GetConfigInfo(config).treeIDs = 1118 (an empty parent), 1187, 1188,
--     1189, with 9 nodes each; open from level 1, so a character simply has
--     a reading or not;
--   * GetTreeCurrencyInfo(config, tree, false)'s 4225 row: spentInTree (that
--     tree), spent (all three), quantity (free, shared), maxQuantity (what
--     this character can spend now: the "of" in "1 of 4"; = spent + quantity,
--     0 + 4 and 3 + 1);
--   * GetNodeInfo(config, node): ID (its own), activeRank (= currentRank =
--     ranksPurchased, and their sum is spentInTree), maxRanks, type (0 one
--     talent; 1 tiered, one entry per rank; no choice node exists yet),
--     posX/posY on a 900 grid, activeEntry, entryIDs, visibleEdges;
--   * a talent picked but not applied is STAGED: ConfigHasStagedChanges is
--     true, and spentInTree and the ranks include it. Apply fires
--     TRAIT_CONFIG_UPDATED; picking and undoing fire only node and currency
--     events. So a reading is taken only with nothing staged, checked before
--     and after.
--
-- Proven or nothing: any part unreadable, a secret, or a node answering with
-- another ID, and the reading is nil - the stored one stays.
--
-- Stored on the character record, synced like every other field:
--   legacyTalents = "v1;c4;1187:0:;1188:1:110301.1.5.136855.1.1225478;1189:0:"
--     the cap, then per tree (fixed order) its points and each node with a
--     rank (ascending ID) as node.rank.max.entry.entryRank.spell. The entry's
--     own rank is what the game's tooltip takes (activeEntry.rank): on a
--     tiered node, one entry per rank, it isn't the node's. The spell travels
--     so any client can name a talent without the trees of its own.
--   legacyAt = when it last changed.
-- And account-wide, never synced: AltStableConfig.legacyLayout, the trees'
-- shape for the Roster's read-only view (positions, entries, edges; nothing
-- of any character's choices), with the build it was read on.
------------------------------------------------------------

AltStable = AltStable or {}

local LT = {}
AltStable.LegacyTalents = LT

local CURRENCY    = 4225
local PARENT_TREE = 1118
local TREES       = { 1187, 1188, 1189 }
local GENERIC     = 3
-- Enum.TraitNodeType Selection and SubTreeSelection: a choice of talents.
local CHOICE      = { [2] = true, [3] = true }
local VERSION     = "v1"
local TREE_NAMES  = { [1187] = "Professions", [1188] = "Adventure", [1189] = "Resourcefulness" }

local READ_AFTER = 3          -- after a login or a reload
local RETRY      = { 10, 30 } -- while a reading isn't proven
local SETTLE     = 1          -- after the last of a burst of events

LT.TREES = TREES

------------------------------------------------------------
-- Reading the character being played
------------------------------------------------------------

local function Secret(v)
    local f = rawget(_G, "issecretvalue")
    return type(f) == "function" and f(v) == true
end

local function Num(v)
    if v == nil or Secret(v) then return nil end
    return tonumber(v)
end

-- A C_Traits call: its first return, or nil when absent, failing or secret.
local function Traits(name, ...)
    local t = rawget(_G, "C_Traits")
    local f = type(t) == "table" and t[name]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, ...)
    if not ok or Secret(v) then return nil end
    return v
end

-- true or false as the client says it; nil when it can't be told, which
-- never counts as "nothing staged".
local function Staged(config)
    local v = Traits("ConfigHasStagedChanges", config)
    if type(v) ~= "boolean" then return nil end
    return v
end

-- The Legacy config: positive, Generic, with all three trees.
local function Config()
    local id = Num(Traits("GetConfigIDByTreeID", PARENT_TREE)) or Num(Traits("GetConfigIDByTreeID", TREES[1]))
    if not id or id <= 0 then return nil end
    local info = Traits("GetConfigInfo", id)
    if type(info) ~= "table" or Num(info.type) ~= GENERIC or type(info.treeIDs) ~= "table" then return nil end
    local has = {}
    for _, tree in ipairs(info.treeIDs) do
        local n = Num(tree)
        if n then has[n] = true end
    end
    for _, tree in ipairs(TREES) do
        if not has[tree] then return nil end
    end
    return id
end

-- An entry's spell and, when the game renames or re-icons it, those.
local function Entry(config, entryID, cache)
    if cache[entryID] then return cache[entryID] end
    local e = { id = entryID, spell = 0 }
    local info = Traits("GetEntryInfo", config, entryID)
    local def = type(info) == "table" and Num(info.definitionID)
    local d = def and Traits("GetDefinitionInfo", def)
    if type(d) == "table" then
        e.spell = Num(d.spellID) or 0
        if type(d.overrideName) == "string" and d.overrideName ~= "" and not Secret(d.overrideName) then
            e.name = d.overrideName
        end
        e.icon = Num(d.overrideIcon)
    end
    cache[entryID] = e
    return e
end

local function ById(a, b) return a.id < b.id end

-- The reading and the trees' layout, or nil.
function LT.Read()
    local config = Config()
    if not config or Staged(config) ~= false then return nil end
    local reading, layout, cache = { trees = {} }, { trees = {} }, {}
    for i, tree in ipairs(TREES) do
        local ids = Traits("GetTreeNodes", tree)
        if type(ids) ~= "table" or #ids == 0 then return nil end
        local row
        local rows = Traits("GetTreeCurrencyInfo", config, tree, false)
        for _, c in ipairs(type(rows) == "table" and rows or {}) do
            if type(c) == "table" and Num(c.traitCurrencyID) == CURRENCY then row = c end
        end
        local spent = row and Num(row.spentInTree)
        if not spent then return nil end
        -- The cap: maxQuantity, which the API marks optional; else spent +
        -- free, as measured equal. Neither: not proven (never "of 0").
        local cap = Num(row.maxQuantity)
        if not cap then
            local total, free = Num(row.spent), Num(row.quantity)
            if total and free then cap = total + free end
        end
        reading.cap = reading.cap or cap
        local t, l = { tree = tree, spent = spent, nodes = {} }, { tree = tree, nodes = {} }
        for _, raw in ipairs(ids) do
            local nodeID = Num(raw)
            local n = nodeID and Traits("GetNodeInfo", config, nodeID)
            if type(n) ~= "table" or Num(n.ID) ~= nodeID then return nil end
            local rank, max, kind = Num(n.activeRank), Num(n.maxRanks) or 1, Num(n.type) or 0
            if not rank then return nil end
            local entries = {}
            for _, eid in ipairs(type(n.entryIDs) == "table" and n.entryIDs or {}) do
                local id = Num(eid)
                if id then entries[#entries + 1] = Entry(config, id, cache) end
            end
            local edges = {}
            for _, e in ipairs(type(n.visibleEdges) == "table" and n.visibleEdges or {}) do
                local target = type(e) == "table" and Num(e.targetNode)
                if target then edges[#edges + 1] = target end
            end
            table.sort(edges)
            l.nodes[#l.nodes + 1] = { id = nodeID, x = Num(n.posX) or 0, y = Num(n.posY) or 0, type = kind,
                                      max = max, entries = entries, edges = edges }
            if rank > 0 then
                -- The talent chosen: the active entry; a node of one entry
                -- can only be that one. A choice without its active entry
                -- could record the other talent: not proven.
                local entryID, entryRank
                if type(n.activeEntry) == "table" then
                    entryID, entryRank = Num(n.activeEntry.entryID), Num(n.activeEntry.rank)
                end
                if not entryID then
                    if CHOICE[kind] or #entries ~= 1 then return nil end
                    entryID = entries[1].id
                end
                t.nodes[#t.nodes + 1] = { id = nodeID, rank = rank, max = max, entry = entryID,
                                          entryRank = entryRank or rank,
                                          spell = Entry(config, entryID, cache).spell }
            end
        end
        table.sort(t.nodes, ById)
        table.sort(l.nodes, ById)
        reading.trees[i], layout.trees[i] = t, l
    end
    if not reading.cap or Staged(config) ~= false then return nil end
    return reading, layout
end

------------------------------------------------------------
-- The stored text
------------------------------------------------------------

function LT.Encode(r)
    local parts = { VERSION, "c" .. math.floor(tonumber(r.cap) or 0) }
    for i, tree in ipairs(TREES) do
        local t = r.trees[i]
        local nodes = {}
        for _, n in ipairs(t.nodes) do
            nodes[#nodes + 1] = ("%d.%d.%d.%d.%d.%d"):format(n.id, n.rank, n.max, n.entry,
                                                              n.entryRank or n.rank, n.spell or 0)
        end
        parts[#parts + 1] = ("%d:%d:%s"):format(tree, t.spent, table.concat(nodes, ","))
    end
    return table.concat(parts, ";")
end

-- The reading a stored text holds, or nil for anything else: another
-- version, junk, a tree missing or out of order.
function LT.Decode(s)
    if type(s) ~= "string" then return nil end
    local ver, cap, rest = s:match("^(v%d+);c(%d+);(.*)$")
    if ver ~= VERSION then return nil end
    local r, i = { cap = tonumber(cap), trees = {} }, 0
    for seg in (rest .. ";"):gmatch("([^;]*);") do
        i = i + 1
        local tree, spent, list = seg:match("^(%d+):(%d+):(.*)$")
        if not tree or tonumber(tree) ~= TREES[i] then return nil end
        local t = { tree = TREES[i], spent = tonumber(spent), nodes = {} }
        if list ~= "" then
            for item in (list .. ","):gmatch("([^,]*),") do
                local id, rank, max, entry, erank, spell =
                    item:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)%.(%d+)%.(%d+)$")
                if not id then return nil end
                t.nodes[#t.nodes + 1] = { id = tonumber(id), rank = tonumber(rank), max = tonumber(max),
                                          entry = tonumber(entry), entryRank = tonumber(erank),
                                          spell = tonumber(spell) }
            end
        end
        r.trees[i] = t
    end
    if i ~= #TREES then return nil end
    return r
end

-- A character's reading, or nil.
function LT.Get(char)
    return type(char) == "table" and LT.Decode(char.legacyTalents) or nil
end

-- "1/4": points spent of what the character could spend when it was read.
function LT.Points(r)
    local spent = 0
    for _, t in ipairs(r.trees) do spent = spent + (t.spent or 0) end
    return spent, r.cap or 0
end

function LT.TreeName(tree)
    local data = rawget(_G, "LegacyTreeData")
    if type(data) == "table" then
        for _, d in pairs(data) do
            if type(d) == "table" and d.treeID == tree and type(d.name) == "string" and d.name ~= "" then
                return d.name
            end
        end
    end
    return TREE_NAMES[tree] or tostring(tree)
end

------------------------------------------------------------
-- The trees' layout, account-wide
------------------------------------------------------------

local function Build()
    local f = rawget(_G, "GetBuildInfo")
    if type(f) ~= "function" then return "" end
    local _, build = f()
    return tostring(build or "")
end

-- Learned from a proven reading (every node of all three trees).
function LT.Learn(layout)
    if type(AltStableConfig) ~= "table" or type(layout) ~= "table" then return end
    AltStableConfig.legacyLayout = { build = Build(), trees = layout.trees }
end

-- The layout for this build, or nil: one learned on another build may have
-- moved nodes, so the view waits for a character to read it again.
function LT.Layout()
    local l = type(AltStableConfig) == "table" and AltStableConfig.legacyLayout
    if type(l) ~= "table" or l.build ~= Build() or type(l.trees) ~= "table" or #l.trees ~= #TREES then return nil end
    return l
end

------------------------------------------------------------
-- Scanning and writing
------------------------------------------------------------

-- A reading that came before the character's record existed: written by
-- the scan (OnScanned).
local pending

local function Refresh()
    local roster = AltStable.RosterPlugin
    if roster and roster.isActive and roster.RequestRefresh then roster.RequestRefresh() end
end

function LT.Write(char, text)
    if char.legacyTalents == text then return false end
    char.legacyTalents, char.legacyAt = text, time()
    if AltStable.TouchCharacter then AltStable.TouchCharacter(char.guid) end
    Refresh()
    return true
end

-- Reads the character being played. True when the reading was proven
-- (written or the same as stored).
function LT.Scan()
    local guid = UnitGUID and UnitGUID("player")
    if not guid then return false end
    local reading, layout = LT.Read()
    if not reading then return false end
    -- A layout usable now and not before (a new build) enables View for
    -- every alt, whether or not this character's reading changed.
    local had = LT.Layout() ~= nil
    LT.Learn(layout)
    local learned = not had and LT.Layout() ~= nil
    local text = LT.Encode(reading)
    local char = type(AltStableDB) == "table" and AltStableDB[guid]
    if type(char) ~= "table" then
        pending = { guid = guid, text = text }
    else
        pending = nil
        if LT.Write(char, text) then learned = false end
    end
    if learned then Refresh() end
    return true
end

function LT.OnScanned(char)
    if pending and type(char) == "table" and char.guid == pending.guid then
        local text = pending.text
        pending = nil
        LT.Write(char, text)
    end
end

-- At a login or a reload, with retries while it isn't proven.
local function Attempt(n)
    if LT.Scan() then return end
    if RETRY[n] then C_Timer.After(RETRY[n], function() Attempt(n + 1) end) end
end

-- One scan after a burst of events: a learn or a reset fires several.
local settle
local function Settle()
    if settle and settle.Cancel then settle:Cancel() end
    settle = C_Timer.NewTimer(SETTLE, function() settle = nil; LT.Scan() end)
end

local EVENTS = { "TRAIT_CONFIG_UPDATED", "TRAIT_CONFIG_CREATED", "TRAIT_CONFIG_LIST_UPDATED",
                 "TRAIT_TREE_CURRENCY_INFO_UPDATED", "PLAYER_LEVEL_UP", "SKILL_LINES_CHANGED" }
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_LOGOUT")
for _, ev in ipairs(EVENTS) do pcall(events.RegisterEvent, events, ev) end
events:SetScript("OnEvent", function(_, event, a, b)
    if event == "PLAYER_ENTERING_WORLD" then
        if a or b then C_Timer.After(READ_AFTER, function() Attempt(1) end) end
    elseif event == "PLAYER_LOGOUT" then
        -- An Apply just before logging out: read it now, before the saved
        -- variables are written, not after a timer that never comes.
        if settle then
            if settle.Cancel then settle:Cancel() end
            settle = nil
            LT.Scan()
        end
    else
        Settle()
    end
end)

AltStable._test = AltStable._test or {}
AltStable._test.LegacyFrame = events
AltStable._test.LegacyEvents = EVENTS
AltStable._test.ResetLegacy = function() pending, settle = nil, nil end
