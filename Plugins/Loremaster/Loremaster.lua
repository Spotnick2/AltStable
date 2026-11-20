------------------------------------------------------------
-- Loremaster.lua - the counting, the store and the sync line (#374, #372)
--
-- SPDX-License-Identifier: GPL-3.0-or-later (see NOTICE.md: the quest table is
-- derived from QuestieDB).
--
-- What the client gives, measured on 1.60.1.70959 (forever-api-notes.md,
-- "Completed quests: per character, ready at login"):
--   * C_QuestLog.GetAllCompletedQuestIDs() is the character's own list (no
--     account-wide credit), complete at PLAYER_LOGIN, about 3 ms.
--   * QUEST_TURNED_IN fires BEFORE the completion is recorded; 0.5 s later it
--     is. So a turn-in schedules a scan, never reads in its handler.
--   * Quest titles are not cached: the names are QuestData.lua's (English).
--
-- The rules (the approved plan, reviewed with Codex):
--   * A quest counts for a character whose faction, race and class can take it
--     (QuestieDB's masks; a race bit is D.RACE_MASK[raceID]) and whose required
--     pre-quests are not impossible for it. Attainable pre-quests, skill and
--     reputation gates stay in the total: "everything it can ever do".
--   * Done = in the completed list. A done quest always counts, in done and
--     total, whatever the masks say.
--   * Unsure quests (no known starter, no zone) count only once done.
--   * Closed (missed) quests leave the total, so 100% is always reachable.
--     Closed only from completions and level, so nothing flips back: an
--     exclusive partner done; a breadcrumb whose target is done or itself
--     closed (along breadcrumb links only); a follow-up done; past the level
--     cap; an availableUntilCompleted quest done; a parent quest done.
--   * A quest both factions take may carry Horde's own links (field 16).
--
-- AltStableLoremasterDB (SavedVariables; the Companion reads it, see
-- docs/LOREMASTER-EXPORT.md):
--   chars[guid] = { stamp, ver, level, faction, race, class, log, completed,
--                   cls = { done, total, now }, c = { [zoneKey] = { done, total } } }
--     No entry = never scanned (unknown), never zeros.
--   done[guid] = { stamp, ids = { [questID] = true } }   -- local only, never synced
--   zones[zoneKey] = { name, uiMapID, group }            -- English names, for exports
------------------------------------------------------------

local D = AltStable.LoremasterData
local M = {}
AltStable.Loremaster = M
M.D = D

AltStableLoremasterDB = AltStableLoremasterDB or {}

-- QuestData.lua's fields.
local KEY, HKEY, REQ, RACES, CLASSES, FLAGS, NAME, MAXLVL = 1, 2, 3, 4, 5, 6, 7, 8
local LINKS = 9                -- fields 9-15: exclusiveTo, preSingle, preGroup, breadcrumbFor, next, parent, until
local HORDE = 16
local EXCL, PRESINGLE, PREGROUP, BREAD, NEXT, PARENT, UNTIL = 1, 2, 3, 4, 5, 6, 7   -- within the links
local F_UNSURE, F_REF = 1, 2

M.BLOB_VERSION = "v1"
M.SCAN_DELAY = 1.5             -- after QUEST_TURNED_IN: the completion lands ~0.5 s later

local floor = math.floor

------------------------------------------------------------
-- The store
------------------------------------------------------------

function M.DB()
    if type(AltStableLoremasterDB) ~= "table" then AltStableLoremasterDB = {} end
    local db = AltStableLoremasterDB
    if type(db.chars) ~= "table" then db.chars = {} end
    if type(db.done) ~= "table" then db.done = {} end
    if type(db.zones) ~= "table" then db.zones = {} end
    if type(db.collapsed) ~= "table" then db.collapsed = {} end
    return db
end

local function Api(ns, name)
    local t = rawget(_G, ns)
    return type(t) == "table" and t[name] or nil
end

------------------------------------------------------------
-- The rules, pure: a quest row, a character profile p = { faction, race,
-- class, level }, and a done set
------------------------------------------------------------

-- `bitValue` is a power of two; masks are wider than 32 bits (Skyborne).
local function HasBit(mask, bitValue) return floor(mask / bitValue) % 2 == 1 end
M.HasBit = HasBit

-- The links as this character sees them: Horde's own copy where there is one.
local function Link(q, p, i)
    local h = q[HORDE]
    if h and p.faction == "Horde" then return h[i] end
    return q[LINKS + i - 1]
end
M.Link = Link

function M.KeyOf(q, p)
    if q[HKEY] and p.faction == "Horde" then return q[HKEY] end
    return q[KEY]
end

-- Faction, race and class allow it. A race the table doesn't know takes only
-- quests open to its whole faction.
function M.CanTake(q, p)
    local races = q[RACES] or 0
    if races ~= 0 then
        local bit = p.race and D.RACE_MASK[p.race]
        if bit then
            if not HasBit(races, bit) then return false end
        else
            -- every bit of the faction's mask must be in the quest's
            local whole = D.FACTION_MASK[p.faction or ""]
            if not whole then return false end
            local m, w = races, whole
            while w > 0 do
                if w % 2 == 1 and m % 2 ~= 1 then return false end
                w, m = floor(w / 2), floor(m / 2)
            end
        end
    end
    local classes = q[CLASSES] or 0
    if classes ~= 0 then
        if not p.class or not HasBit(classes, 2 ^ (p.class - 1)) then return false end
    end
    return true
end

-- Whether a quest the character could take by its masks has pre-quests it can
-- never take. One level deep; a pre-quest the table doesn't hold is possible.
local function PreImpossible(q, p, done)
    local single = Link(q, p, PRESINGLE)
    if single and #single > 0 then
        local any = false
        for _, id in ipairs(single) do
            id = math.abs(id)
            local pq = D.QUESTS[id]
            if done[id] or not pq or M.CanTake(pq, p) then any = true; break end
        end
        if not any then return true end
    end
    local group = Link(q, p, PREGROUP)
    if group then
        for _, id in ipairs(group) do
            id = math.abs(id)          -- signed: -4962 means exactly 4962
            local pq = D.QUESTS[id]
            if not done[id] and pq and not M.CanTake(pq, p) then return true end
        end
    end
    return false
end

function M.Eligible(q, p, done)
    if not q or q[FLAGS] % 4 >= F_REF then return false end
    return M.CanTake(q, p) and not PreImpossible(q, p, done)
end

-- Why an undone quest can no longer be done, or nil. From completions and
-- level only (permanent). `seen` guards the breadcrumb walk.
function M.ClosedWhy(id, p, done, seen)
    local q = D.QUESTS[id]
    if not q or done[id] then return nil end
    for _, x in ipairs(Link(q, p, EXCL) or {}) do
        if done[x] then return "excl", x end
    end
    local nxt = Link(q, p, NEXT)
    if nxt and nxt ~= 0 and done[nxt] then return "next", nxt end
    local maxLevel = q[MAXLVL] or 0
    if maxLevel > 0 and (p.level or 0) > maxLevel then return "level", maxLevel end
    local untilId = Link(q, p, UNTIL)
    if untilId and untilId ~= 0 and done[untilId] then return "until", untilId end
    local parent = Link(q, p, PARENT)
    if parent and parent ~= 0 and done[parent] then return "parent", parent end
    -- A breadcrumb closes with its target: done, or closed itself (along
    -- breadcrumb links only: 1361 -> 1362 -> 1365, doing 1365 closes both).
    local target = Link(q, p, BREAD)
    if target and target ~= 0 then
        if done[target] then return "bread", target end
        seen = seen or {}
        if not seen[target] then
            seen[target] = true
            if M.ClosedWhy(target, p, done, seen) then return "bread", target end
        end
    end
    return nil
end

-- Every row's counts for one character, and its lists when asked.
-- Returns { c = { [key] = { done, total } }, cls = { done, total, now },
--           lists = { [key] = { open = {ids}, missed = {ids}, done = {ids} } } | nil }
function M.Count(p, done, withLists)
    local c, lists = {}, withLists and {} or nil
    local cls = { 0, 0, 0 }
    local classKey = D.CLASS_KEY
    for id, q in pairs(D.QUESTS) do
        local isRef = q[FLAGS] % 4 >= F_REF
        if not isRef then
            local key = M.KeyOf(q, p)
            local state
            if done[id] then
                state = "done"
            elseif M.Eligible(q, p, done) and q[FLAGS] % 2 ~= F_UNSURE then
                state = M.ClosedWhy(id, p, done) and "missed" or "open"
            end
            if state then
                local row = c[key]
                if not row then row = { 0, 0 }; c[key] = row end
                if state ~= "missed" then row[2] = row[2] + 1 end
                if state == "done" then row[1] = row[1] + 1 end
                if key == classKey and state ~= "missed" then
                    cls[2] = cls[2] + 1
                    if state == "done" then cls[1] = cls[1] + 1 end
                    if state == "done" or (q[REQ] or 0) <= (p.level or 0) then cls[3] = cls[3] + 1 end
                end
                if lists then
                    local l = lists[key]
                    if not l then l = { open = {}, missed = {}, done = {} }; lists[key] = l end
                    local into = l[state]
                    into[#into + 1] = id
                end
            end
        end
    end
    -- Rows with nothing to do for this character are not rows of its.
    for key, row in pairs(c) do if row[2] == 0 and row[1] == 0 then c[key] = nil end end
    if lists then
        local function byLevel(a, b)
            local qa, qb = D.QUESTS[a], D.QUESTS[b]
            if (qa[REQ] or 0) ~= (qb[REQ] or 0) then return (qa[REQ] or 0) < (qb[REQ] or 0) end
            return a < b
        end
        for _, l in pairs(lists) do
            table.sort(l.open, byLevel); table.sort(l.missed, byLevel); table.sort(l.done, byLevel)
        end
    end
    return { c = c, cls = { done = cls[1], total = cls[2], now = cls[3] }, lists = lists }
end

------------------------------------------------------------
-- Scanning the character playing
------------------------------------------------------------

function M.Profile()
    local _, _, raceID = UnitRace("player")
    local _, _, classID = UnitClass("player")
    return { faction = UnitFactionGroup("player"), race = raceID, class = classID,
             level = UnitLevel("player") }
end

-- The client's completed list, as a set of the table's quests, and its size.
function M.ReadCompleted()
    local get = Api("C_QuestLog", "GetAllCompletedQuestIDs")
    if not get then return nil end
    local ok, list = pcall(get)
    if not ok or type(list) ~= "table" then return nil end
    local set, n = {}, 0
    for _, id in pairs(list) do
        id = tonumber(id)
        if id then
            n = n + 1
            if D.QUESTS[id] then set[id] = true end
        end
    end
    return set, n
end

local function LogCount()
    local get = Api("C_QuestLog", "GetNumQuestLogEntries")
    if not get then return nil end
    local ok, _, numQuests = pcall(get)
    return ok and tonumber(numQuests) or nil
end

local function SameCounts(a, b)
    for k, row in pairs(a) do
        local o = b[k]
        if not o or o[1] ~= row[1] or o[2] ~= row[2] then return false end
    end
    for k in pairs(b) do if not a[k] then return false end end
    return true
end

local function Same(held, r)
    if type(held) ~= "table" then return false end
    for _, k in ipairs({ "ver", "level", "faction", "race", "class", "log", "completed" }) do
        if held[k] ~= r[k] then return false end
    end
    local hc, rc = held.cls or {}, r.cls
    if hc.done ~= rc.done or hc.total ~= rc.total or hc.now ~= rc.now then return false end
    return SameCounts(held.c or {}, r.c)
end

-- Reads the character playing and keeps a new snapshot when anything moved.
-- Returns true when it did.
function M.Scan()
    local guid = UnitGUID and UnitGUID("player")
    if not guid then return false end
    local done, completed = M.ReadCompleted()
    if not done then return false end
    local p = M.Profile()
    local counts = M.Count(p, done)
    local r = { ver = D.VERSION, level = p.level, faction = p.faction, race = p.race, class = p.class,
                log = LogCount(), completed = completed, cls = counts.cls, c = counts.c }
    local db = M.DB()
    local held = db.chars[guid]
    -- The local done set follows every scan, so tooltips stay right even
    -- when the counts did not move.
    if Same(held, r) then
        db.done[guid] = { stamp = held.stamp, ids = done }
        return false
    end
    -- Strictly increasing: two snapshots in one second must not share a stamp.
    r.stamp = math.max(time(), (type(held) == "table" and tonumber(held.stamp) or 0) + 1)
    db.chars[guid] = r
    db.done[guid] = { stamp = r.stamp, ids = done }
    if AltStable.TouchCharacter then AltStable.TouchCharacter(guid) end
    if M.OnChanged then M.OnChanged() end
    return true
end

-- One scan, SCAN_DELAY after the LAST event: each event re-arms the delay, so
-- a turn-in that comes while a scan is pending still gets a scan after its
-- completion lands (Codex on #397).
local pendingTimer
function M.ScheduleScan(delay)
    if pendingTimer then pendingTimer:Cancel() end
    pendingTimer = C_Timer.NewTimer(delay or M.SCAN_DELAY, function()
        pendingTimer = nil
        M.Scan()
    end)
    return pendingTimer
end
function M.ResetPending()
    if pendingTimer then pendingTimer:Cancel() end
    pendingTimer = nil
end

------------------------------------------------------------
-- Sync: one line per character,
--   "v1|s=<stamp>|d=<ver>|f=<A|H>|r=<race>|k=<class>|lv=<level>|l=<log>|t=<completed>|n=<now>
--    |c=<key>.<done>.<total>,..."
-- Anchored on s= first and c= last; fields between are read by name, so a
-- later field slots in without a version bump (as Professions' w=).
------------------------------------------------------------

local FACTION_CODE = { Alliance = "A", Horde = "H" }
local FACTION_NAME = { A = "Alliance", H = "Horde" }

function M.Serialize(guid)
    local e = M.DB().chars[guid]
    if type(e) ~= "table" or not e.stamp then return "" end
    local keys = {}
    for k in pairs(e.c or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local row = e.c[k]
        parts[#parts + 1] = ("%d.%d.%d"):format(k, row[1], row[2])
    end
    local cls = e.cls or {}
    return ("%s|s=%d|d=%s|f=%s|r=%d|k=%d|lv=%d|l=%d|t=%d|n=%d|c=%s"):format(M.BLOB_VERSION, e.stamp,
        (tostring(e.ver or ""):gsub("[^%w]", "")), FACTION_CODE[e.faction] or "", tonumber(e.race) or 0,
        tonumber(e.class) or 0, tonumber(e.level) or 0, tonumber(e.log) or -1, tonumber(e.completed) or 0,
        tonumber(cls.now) or 0, table.concat(parts, ","))
end

-- nil for anything malformed: a bad line keeps what we hold.
function M.Parse(blob)
    if type(blob) ~= "string" then return nil end
    local ver, s, mid, c = blob:match("^(v%d+)|s=(%d+)|(.-)|c=([^|]*)$")
    if ver ~= M.BLOB_VERSION then return nil end
    local f = {}
    for k, v in (mid .. "|"):gmatch("(%w+)=([^|]*)|") do f[k] = v end
    local r = { stamp = tonumber(s), ver = f.d, faction = FACTION_NAME[f.f or ""],
                race = tonumber(f.r), class = tonumber(f.k), level = tonumber(f.lv),
                log = tonumber(f.l), completed = tonumber(f.t), c = {} }
    if r.log and r.log < 0 then r.log = nil end
    if not (r.stamp and r.ver and r.faction and r.level) then return nil end
    if c ~= "" then
        for item in (c .. ","):gmatch("([^,]*),") do
            local k, dn, tt = item:match("^(%-?%d+)%.(%d+)%.(%d+)$")
            if not k then return nil end
            dn, tt = tonumber(dn), tonumber(tt)
            -- Counts that can't be true are a bad line, not a new snapshot
            -- (Codex on #397: done above total would show past 100%).
            if dn > tt then return nil end
            r.c[tonumber(k)] = { dn, tt }
        end
    end
    local classRow = r.c[D.CLASS_KEY]
    r.cls = { done = classRow and classRow[1] or 0, total = classRow and classRow[2] or 0,
              now = tonumber(f.n) or 0 }
    -- "Now" is the done ones plus those open at its level: between the two.
    if r.cls.now < r.cls.done or r.cls.now > r.cls.total then return nil end
    return r
end

function M.Deserialize(guid, blob)
    if not guid then return end
    local r = M.Parse(blob)
    if not r then return end
    -- Strictly newer only: our own echoes come back equal.
    local db = M.DB()
    local held = db.chars[guid]
    if type(held) == "table" and (tonumber(held.stamp) or 0) >= r.stamp then return end
    db.chars[guid] = r          -- wholesale, an empty c= included
    -- No TouchCharacter: receiving is not a change of ours.
    if M.OnChanged then M.OnChanged() end
end

function M.Forget(guid)
    if not guid then return end
    local db = M.DB()
    db.chars[guid] = nil
    db.done[guid] = nil
end

function M.Cleanup(keepGuid)
    local db = M.DB()
    for guid in pairs(db.chars) do if guid ~= keepGuid then db.chars[guid] = nil end end
    for guid in pairs(db.done) do if guid ~= keepGuid then db.done[guid] = nil end end
end

-- Snapshots whose character the core no longer knows.
function M.PruneOrphans()
    local db = M.DB()
    for _, store in ipairs({ db.chars, db.done }) do
        for guid in pairs(store) do
            local c = AltStableDB and AltStableDB[guid]
            if type(c) ~= "table" or not c.name then store[guid] = nil end
        end
    end
end

-- The rows' English names for exports (the Companion reads SavedVariables
-- without the GPL data file).
function M.WriteZoneNames()
    local zones = {}
    for key, z in pairs(D.ZONES) do zones[key] = { name = z[4], uiMapID = z[3], group = z[1] } end
    M.DB().zones = zones
end

-- At bootstrap: drop snapshots of forgotten characters, pull everything once
-- when there is nothing to build on, then read the character playing.
function M.Start()
    M.PruneOrphans()
    M.WriteZoneNames()
    if AltStable.ResetPeerWatermarks and not next(M.DB().chars) then AltStable.ResetPeerWatermarks() end
    M.ScheduleScan(1)
end

------------------------------------------------------------
-- Events
------------------------------------------------------------

M.EVENTS = { "QUEST_TURNED_IN", "PLAYER_LEVEL_UP", "QUEST_ACCEPTED", "QUEST_REMOVED" }
local frame = CreateFrame("Frame")
for _, ev in ipairs(M.EVENTS) do pcall(frame.RegisterEvent, frame, ev) end
frame:SetScript("OnEvent", function() M.ScheduleScan() end)
