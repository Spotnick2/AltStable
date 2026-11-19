----------------------------------------------------------------------------
-- /fp steps as legacy - what the client gives for Legacy Challenges (#373)
--
-- Read from the 70959 data and Blizzard's own Legacy window (wow-ui-source,
-- Blizzard_LegacySystem), not yet measured live:
--   * 65 challenges, 1 Legacy Point each (C_Traits.GetTraitCurrencyForAchievement
--     (4225, id)), in two ID sets of identical content: A (flag 0x8000000) and
--     B (0x10000000). Probably Normal and Hardcore.
--   * the earned total is the renown level of faction 2802, the max is
--     C_Traits.GetMaxAvailableTraitCurrency(4225, false); rewards on the renown
--     track.
--   * Blizzard shows a challenge complete only if completed AND wasEarnedByMe.
-- To measure, before the plugin promises anything:
--   1. credit scope: which set this client lists, and completed / wasEarnedByMe
--      / renown on the earner, another alt, and the other WoW account of the
--      same Battle.net account (each account's file is compared offline);
--   2. criteria: their shape, and whether two alts with different dungeons or
--      exploration read different criteria (per character) or the same (per
--      account); whether the other set's names and criteria resolve by ID;
--   3. readiness: when the list and renown are readable after a cold start
--      (client exit) and a warm one (/reload), and whether Blizzard's search
--      box changes what the category calls return.
-- Every login while the probe is deployed records this character's reading
-- at +10 s in AltStableProbeDB.legacy.chars, so the steps find two characters.
----------------------------------------------------------------------------

local _, NS = ...
local Probe = NS.Probe
local Describe = Probe.Describe

local function Out(s) Probe:Say("[legacy] " .. tostring(s)) end

local FACTION, CURRENCY = 2802, 4225
local EXPLORE_AZEROTH = 62053

-- The two ID sets, from forever-achievement-1.60.1.70959.csv (Reward "Earn 1
-- Legacy Point.", flags 0x8000000 / 0x10000000).
local SET_A = { 684, 61499, 61500, 61501, 61502, 61503, 61504, 61989, 61992, 61993, 61994, 61995,
    61996, 61997, 61998, 61999, 62000, 62001, 62002, 62003, 62004, 62005, 62006, 62007, 62008,
    62009, 62010, 62011, 62012, 62013, 62014, 62015, 62016, 62017, 62018, 62019, 62020, 62021,
    62022, 62023, 62024, 62025, 62026, 62028, 62029, 62030, 62031, 62032, 62033, 62034, 62035,
    62041, 62042, 62043, 62044, 62045, 62046, 62047, 62048, 62049, 62054, 62382, 63340, 63341, 63342 }
local SET_B = {}
for id = 63969, 64033 do SET_B[#SET_B + 1] = id end
local IN_A, IN_B = {}, {}
for _, id in ipairs(SET_A) do IN_A[id] = true end
for _, id in ipairs(SET_B) do IN_B[id] = true end

local function DB()
    AltStableProbeDB.legacy = AltStableProbeDB.legacy or {}
    local t = AltStableProbeDB.legacy
    t.chars = t.chars or {}
    t.sessions = t.sessions or {}
    return t
end

local function Try(fn, ...)
    if type(fn) ~= "function" then return false, "absent" end
    return pcall(fn, ...)
end

local function Api(ns, name)
    local t = rawget(_G, ns)
    return type(t) == "table" and t[name] or nil
end

local function Pack(...) return { n = select("#", ...), ... } end

local function Points(id)
    local ok, n = Try(Api("C_Traits", "GetTraitCurrencyForAchievement"), CURRENCY, id)
    if ok then return n end
    return nil
end

-- GetAchievementInfo(id) or (category, index), Retail's 15 returns kept by name.
local function Ach(...)
    local r = Pack(Try(rawget(_G, "GetAchievementInfo"), ...))
    if not r[1] or r[2] == nil then return nil, r[2] end
    return {
        id = r[2], name = r[3], points = r[4], completed = r[5],
        date = r[6] and ("%s-%s-%s"):format(tostring(r[8]), tostring(r[6]), tostring(r[7])) or nil,
        flags = r[10], wasEarnedByMe = r[14], earnedBy = r[15], returns = r.n - 1,
    }
end

-- Every criterion of an achievement, Retail's 13 returns kept by name.
local function Criteria(id)
    local ok, n = Try(rawget(_G, "GetAchievementNumCriteria"), id)
    if not ok or type(n) ~= "number" then return nil, "num criteria: " .. tostring(n) end
    local list = {}
    for i = 1, n do
        local r = Pack(Try(rawget(_G, "GetAchievementCriteriaInfo"), id, i))
        if r[1] then
            list[i] = { text = r[2], type = r[3], done = r[4], q = r[5], req = r[6], char = r[7],
                        flags = r[8], asset = r[9], qs = r[10], id = r[11], eligible = r[12],
                        returns = r.n - 1 }
        else
            list[i] = { error = tostring(r[2]) }
        end
    end
    return list, n
end

local function DoneOf(list)
    local done, n = 0, 0
    for _, c in ipairs(list or {}) do
        n = n + 1
        if c.done then done = done + 1 end
    end
    return done, n
end

----------------------------------------------------------------------------
-- The readings
----------------------------------------------------------------------------

-- Walk the achievement categories as Blizzard's Legacy window does: every
-- category, every achievement, keep those worth Legacy points.
local function Enumerate(withCriteria)
    local out = { cats = {}, challenges = {}, order = {}, inA = 0, inB = 0, other = 0 }
    local ok, list = Try(rawget(_G, "GetCategoryList"))
    if not ok or type(list) ~= "table" then out.error = "GetCategoryList: " .. tostring(list); return out end
    out.numCategories = #list
    for _, cat in ipairs(list) do
        local okI, title, parent, flags = Try(rawget(_G, "GetCategoryInfo"), cat)
        local okN, total, completed = Try(rawget(_G, "GetCategoryNumAchievements"), cat, true)
        local okD, totalDefault = Try(rawget(_G, "GetCategoryNumAchievements"), cat)
        local c = { id = cat, title = okI and title or nil, parent = okI and parent or nil,
                    flags = okI and flags or nil, total = okN and total or nil,
                    completed = okN and completed or nil, totalDefault = okD and totalDefault or nil }
        local legacy = {}
        for i = 1, (okN and tonumber(total) or 0) do
            local a = Ach(cat, i)
            if a then
                a.cat, a.index, a.legacy = cat, i, Points(a.id)
                if (tonumber(a.legacy) or 0) > 0 then
                    legacy[#legacy + 1] = a.id
                    if withCriteria then a.criteria, a.numCriteria = Criteria(a.id) end
                    out.challenges[a.id] = a
                    out.order[#out.order + 1] = a.id
                    if IN_A[a.id] then out.inA = out.inA + 1
                    elseif IN_B[a.id] then out.inB = out.inB + 1
                    else out.other = out.other + 1 end
                end
            end
        end
        -- Only the categories that hold challenges keep their IDs.
        if #legacy > 0 then c.ids = legacy end
        out.cats[#out.cats + 1] = c
    end
    return out
end

-- Both sets read by ID, whichever one the client lists: does the other set
-- resolve (name, completed), and is it worth points here?
local function ById()
    local out, valid = {}, Api("C_AchievementInfo", "IsValidAchievement")
    local function one(id, set)
        local okV, v = Try(valid, id)
        local a = Ach(id)
        local n = select(2, Criteria(id))
        -- A successful false is kept as false; only a failed read is missing
        -- (`x and false or nil` would turn it into nil: Codex on #380).
        local e = { set = set, named = a and a.name ~= nil or false,
                    legacy = Points(id), numCriteria = type(n) == "number" and n or nil }
        if okV then e.valid = v else e.validError = tostring(v) end
        if a then e.completed, e.mine = a.completed, a.wasEarnedByMe end
        out[id] = e
    end
    for _, id in ipairs(SET_A) do one(id, "A") end
    for _, id in ipairs(SET_B) do one(id, "B") end
    return out
end

-- Explore Azeroth (a per-character achievement) and one level down: its
-- criteria are the continents' explore achievements.
local function Explore()
    local a = Ach(EXPLORE_AZEROTH) or {}
    local list = Criteria(EXPLORE_AZEROTH)
    a.criteria = list
    a.parts = {}
    for _, c in ipairs(list or {}) do
        if c.asset and c.asset ~= 0 then
            local sub = Ach(c.asset)
            local subList = Criteria(c.asset)
            local done, n = DoneOf(subList)
            a.parts[#a.parts + 1] = { id = c.asset, name = sub and sub.name, completed = sub and sub.completed,
                                      mine = sub and sub.wasEarnedByMe, done = done, n = n }
        end
    end
    return a
end

local function Renown()
    local r = {}
    local ok, lvl = Try(Api("C_MajorFactions", "GetCurrentRenownLevel"), FACTION)
    r.level = ok and lvl or nil
    if not ok then r.levelError = tostring(lvl) end
    local okD, data = Try(Api("C_MajorFactions", "GetMajorFactionData"), FACTION)
    r.data = okD and Describe(data) or tostring(data)
    local okM, max = Try(Api("C_Traits", "GetMaxAvailableTraitCurrency"), CURRENCY, false)
    r.max = okM and max or nil
    local okS, sourced = Try(Api("C_Traits", "GetMaxAvailableTraitCurrency"), CURRENCY, true)
    r.maxSourced = okS and sourced or nil
    local okL, levels = Try(Api("C_MajorFactions", "GetRenownLevels"), FACTION)
    r.rewards = {}
    if okL and type(levels) == "table" then
        r.numLevels = #levels
        r.levelShape = levels[1] and Describe(levels[1]) or nil
        for _, L in ipairs(levels) do
            local level = type(L) == "table" and L.level or nil
            local okR, rewards = Try(Api("C_MajorFactions", "GetRenownRewardsForLevel"), FACTION, level)
            if okR and type(rewards) == "table" then
                for _, rw in ipairs(rewards) do
                    r.rewards[#r.rewards + 1] = { level = level, itemID = rw.itemID, mountID = rw.mountID,
                                                  name = rw.name, shape = Describe(rw) }
                end
            end
        end
    else
        r.levelsError = tostring(levels)
    end
    return r
end

local function Mode()
    local m = {}
    local okA, mode = Try(Api("C_GameRules", "GetActiveGameMode"))
    m.active = okA and Describe(mode) or tostring(mode)
    local okR, rec = Try(Api("C_GameRules", "GetCurrentGameModeRecordID"))
    m.recordID = okR and rec or nil
    local okP, preset = Try(Api("C_GameRules", "GetForeverExperiencePreset"))
    m.preset = okP and Describe(preset) or tostring(preset)
    local okH, hc = Try(Api("C_GameRules", "IsHardcoreActive"))
    -- false on a Normal realm is an answer, not "n/a" (Codex on #380).
    if okH then m.hardcore = hc else m.hardcore = "n/a: " .. tostring(hc) end
    local realm = rawget(_G, "GetRealmName")
    m.realm = realm and realm() or nil
    local consts = rawget(_G, "Constants")
    m.consts = type(consts) == "table" and Describe(consts.LegacyConsts) or "no Constants"
    return m
end

local function LegacyUILoaded()
    local ok, loaded = Try(Api("C_AddOns", "IsAddOnLoaded"), "Blizzard_LegacySystem")
    return ok and loaded or false
end

-- A cheap reading for the login timeline: is the list there yet, renown,
-- and the criteria too - how many read, how many done - so the timeline
-- says when THEY are readable, not only the list (Codex on #380: the first
-- run sampled criteria at +10 s only).
local function Quick()
    local e = Enumerate(true)
    local done, mine, crit, critDone = 0, 0, 0, 0
    for _, a in pairs(e.challenges) do
        if a.completed then done = done + 1 end
        if a.wasEarnedByMe then mine = mine + 1 end
        for _, c in ipairs(a.criteria or {}) do
            crit = crit + 1
            if c.done then critDone = critDone + 1 end
        end
    end
    local ok, lvl = Try(Api("C_MajorFactions", "GetCurrentRenownLevel"), FACTION)
    return { found = #e.order, inA = e.inA, inB = e.inB, done = done, mine = mine,
             crit = crit, critDone = critDone,
             renown = ok and lvl or nil, cats = e.numCategories, ui = LegacyUILoaded() }
end

local function QuickText(q)
    if type(q) ~= "table" then return "-" end
    return ("%d challenges (A %d, B %d), %d completed, %d mine, %s criteria (%s done), renown %s, "
        .. "%s categories, Legacy UI %s"):format(
        q.found or 0, q.inA or 0, q.inB or 0, q.done or 0, q.mine or 0, tostring(q.crit),
        tostring(q.critDone), tostring(q.renown), tostring(q.cats), q.ui and "loaded" or "not loaded")
end

local function Read(label)
    local t = { at = date("%Y-%m-%d %H:%M:%S"), label = label, name = UnitName("player"),
                guid = UnitGUID("player"), level = UnitLevel("player"),
                class = select(2, UnitClass("player")), uptime = GetTime(),
                build = select(2, GetBuildInfo()) }
    t.mode = Mode()
    t.renown = Renown()
    t.enum = Enumerate(true)
    t.byId = ById()
    t.explore = Explore()
    t.ui = LegacyUILoaded()
    -- A sequence, not the date: two readings in one second must still order.
    DB().seq = (tonumber(DB().seq) or 0) + 1
    t.seq = DB().seq
    DB().chars[t.name or "?"] = t

    local done, mine = 0, 0
    for _, a in pairs(t.enum.challenges) do
        if a.completed then done = done + 1 end
        if a.wasEarnedByMe then mine = mine + 1 end
    end
    Out(("%s (%s %s), %s: %d challenges listed (set A %d, set B %d, other %d), %d completed, %d earned by me"):format(
        tostring(t.name), tostring(t.class), tostring(t.level), tostring(t.mode.realm), #t.enum.order,
        t.enum.inA, t.enum.inB, t.enum.other, done, mine))
    Out(("  renown %s, max %s (sourced %s), %d reward(s) on %s levels; hardcore %s"):format(
        tostring(t.renown.level), tostring(t.renown.max), tostring(t.renown.maxSourced),
        #t.renown.rewards, tostring(t.renown.numLevels), tostring(t.mode.hardcore)))
    for _, id in ipairs(t.enum.order) do
        local a = t.enum.challenges[id]
        local d, n = DoneOf(a.criteria)
        if n > 1 or a.completed then
            Out(("  %d %s: %s%s, criteria %d/%d"):format(id, tostring(a.name),
                a.completed and "completed" or "open", a.wasEarnedByMe and " (me)" or "", d, n))
        end
    end
    local ex = t.explore
    local parts = {}
    for _, p in ipairs(ex.parts or {}) do parts[#parts + 1] = ("%s %d/%d"):format(tostring(p.name), p.done, p.n) end
    Out(("  Explore Azeroth: %s%s; %s"):format(ex.completed and "completed" or "open",
        ex.wasEarnedByMe and " (me)" or "", #parts > 0 and table.concat(parts, ", ") or "no parts"))
    return t
end

local function Mine() return DB().chars[UnitName("player") or "?"] end

-- The most recent reading of another character on this account.
local function Other()
    local me, best = UnitName("player")
    for name, t in pairs(DB().chars) do
        if name ~= me and (not best or (t.seq or 0) > (best.seq or 0)) then best = t end
    end
    return best
end

-- Two characters' readings side by side: the same list? the same completed
-- set? who earned what? the same criteria?
-- The first criterion that differs between two lists, keyed by criteriaID
-- (else position), as text; nil when every one matches.
local function CritDiff(xs, ys)
    local function index(list)
        local t = {}
        for i, c in ipairs(list or {}) do
            local k = (c.id and c.id ~= 0) and c.id or ("#" .. i)
            t[k] = c
        end
        return t
    end
    local a, b = index(xs), index(ys)
    for k, c in pairs(a) do
        local d = b[k]
        if not d then return ("%s only on the first"):format(tostring(c.text or k)) end
        if (c.done and true or false) ~= (d.done and true or false) or c.q ~= d.q or c.req ~= d.req then
            return ("%s %s %s/%s vs %s %s/%s"):format(tostring(c.text or k),
                c.done and "done" or "open", tostring(c.q), tostring(c.req),
                d.done and "done" or "open", tostring(d.q), tostring(d.req))
        end
    end
    for k, d in pairs(b) do
        if not a[k] then return ("%s only on the second"):format(tostring(d.text or k)) end
    end
    return nil
end

local function Compare(x, y)
    local lines = {}
    local function add(s) lines[#lines + 1] = s; Out("  " .. s) end
    if type(x) ~= "table" or type(y) ~= "table" then error("need two readings", 0) end
    Out(("compare %s with %s"):format(tostring(x.name), tostring(y.name)))
    local cx, cy = x.enum.challenges, y.enum.challenges
    local onlyX, onlyY = 0, 0
    for id in pairs(cx) do if not cy[id] then onlyX = onlyX + 1 end end
    for id in pairs(cy) do if not cx[id] then onlyY = onlyY + 1 end end
    add(("listed: %d / %d, only in the first %d, only in the second %d"):format(#x.enum.order, #y.enum.order, onlyX, onlyY))
    local compDiff, mineX, mineY, critDiff = {}, {}, {}, {}
    for id, a in pairs(cx) do
        local b = cy[id]
        if b then
            if (a.completed and true or false) ~= (b.completed and true or false) then compDiff[#compDiff + 1] = id end
            if a.wasEarnedByMe then mineX[#mineX + 1] = id end
            if b.wasEarnedByMe then mineY[#mineY + 1] = id end
            -- Each criterion by its ID: done AND quantity. Counting done rows
            -- would call two different 2/10 dungeon lists, or two crafts at
            -- 48/150 and 78/150, the same (Codex on #380).
            local diff = CritDiff(a.criteria, b.criteria)
            if diff then critDiff[#critDiff + 1] = tostring(a.name) .. ": " .. diff end
        end
    end
    add(("completed differs on %d challenge(s)%s"):format(#compDiff,
        #compDiff > 0 and (": " .. table.concat(compDiff, ",")) or " (same completed set)"))
    add(("earned by me: %d on the first, %d on the second"):format(#mineX, #mineY))
    add(("criteria differ on %d challenge(s)%s"):format(#critDiff,
        #critDiff > 0 and (": " .. table.concat(critDiff, "; ")) or ""))
    add(("renown %s vs %s"):format(tostring(x.renown.level), tostring(y.renown.level)))
    local function ex(t)
        local p = {}
        for _, part in ipairs(t.explore.parts or {}) do p[#p + 1] = ("%d/%d"):format(part.done, part.n) end
        return table.concat(p, " ")
    end
    add(("Explore Azeroth parts: %s vs %s"):format(ex(x), ex(y)))
    DB().lastCompare = { at = date("%Y-%m-%d %H:%M:%S"), first = x.name, second = y.name, lines = lines }
    return #compDiff, #critDiff
end

----------------------------------------------------------------------------
-- Login timeline and events, kept per character for this session: the
-- readings at login, entering the world, +1, +3, +10 and +30 s say when the
-- list and renown are readable, cold or warm.
----------------------------------------------------------------------------

local EVENTS = { "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "ACHIEVEMENT_EARNED", "CRITERIA_EARNED",
                 "CRITERIA_COMPLETE", "CRITERIA_UPDATE", "RECEIVED_ACHIEVEMENT_LIST",
                 "ACHIEVEMENT_SEARCH_UPDATED", "MAJOR_FACTION_RENOWN_LEVEL_CHANGED",
                 "TRAIT_TREE_CURRENCY_INFO_UPDATED" }
-- Counted always, listed only the first few times: they fire in bursts.
local NOISY = { CRITERIA_UPDATE = true, CRITERIA_COMPLETE = true, TRAIT_TREE_CURRENCY_INFO_UPDATED = true }

local session = { events = {}, counts = {}, login = {} }
local loginAt

local function Since() return loginAt and ("%.1f"):format(GetTime() - loginAt) or "pre" end

local function Mark(key)
    local ok, q = pcall(Quick)
    session.login[key] = { t = Since(), reading = ok and q or { error = tostring(q) } }
end

local frame = CreateFrame("Frame")
Probe:RegisterEvents(frame, EVENTS)
frame:SetScript("OnEvent", function(_, ev, ...)
    if ev == "PLAYER_LOGIN" then loginAt = GetTime() end
    local args = {}
    for i = 1, math.min(select("#", ...), 4) do args[i] = Describe((select(i, ...))) end
    session.counts[ev] = (session.counts[ev] or 0) + 1
    if not NOISY[ev] or session.counts[ev] <= 5 then
        local list = session.events
        list[#list + 1] = ("%s %s %s"):format(Since(), ev, table.concat(args, " "))
        while #list > 200 do table.remove(list, 1) end
    end
    if ev == "ACHIEVEMENT_EARNED" or ev == "CRITERIA_EARNED" or ev == "MAJOR_FACTION_RENOWN_LEVEL_CHANGED" then
        Out(ev .. " " .. table.concat(args, " "))
        -- Does renown catch up with an earn, and when?
        Mark(ev .. "@" .. Since())
        C_Timer.After(2, function() Mark(ev .. "+2s") end)
    end
    if ev == "PLAYER_LOGIN" then
        local name = UnitName("player") or "?"
        session.uptimeAtLogin = GetTime()
        DB().sessions[name] = session   -- this session's, saved at logout
        Mark("login")
        for _, s in ipairs({ 1, 3, 10, 30 }) do
            C_Timer.After(s, function() Mark("plus" .. s .. "s") end)
        end
        C_Timer.After(10, function()
            local ok, err = pcall(Read, "login+10s")
            if not ok then Out("reading at login+10s failed: " .. tostring(err)) end
        end)
    elseif ev == "PLAYER_ENTERING_WORLD" and not session.login.world then
        Mark("world")
    end
end)

local function Timeline()
    local l = session.login
    local out = {}
    for _, k in ipairs({ "login", "world", "plus1s", "plus3s", "plus10s", "plus30s" }) do
        local m = l[k]
        local line = ("%s %s: %s"):format(k, m and m.t or "-", m and QuickText(m.reading) or "-")
        out[#out + 1] = line
        Out(line)
    end
    return out
end

Probe:Command("legacy", function()
    Read("manual")
end, ": this character's Legacy Challenges: the list, completed / mine, criteria, renown, rewards (#373)")

Probe:Command("legacytime", function()
    Timeline()
end, ": when the Legacy list and renown were readable after this login (#373)")

local function TimelineStep(kind)
    return {
        text = "When the challenges and renown were readable after this " .. kind
            .. " (login, entering the world, +1, +3, +10, +30 s). Wait about 30 s.",
        timeout = 60,
        wait = function()
            if not session.login.plus30s then return false, "waiting for the +30 s reading" end
            return true, unpack(Timeline())
        end,
        check = function()
            local m = session.login.plus10s
            local q = m and m.reading or {}
            return (q.found or 0) == 65 and q.renown ~= nil,
                "+10s: " .. QuickText(q)
        end,
    }
end

Probe:Steps("legacy", {
    title = "Legacy Challenges: what the client gives, per character and per account (#373)",
    rev = 2,
    { text = "Reading this character's Legacy Challenges: which ID set is listed, completed / earned by me, "
          .. "every criterion, renown, the reward track.",
      auto = true,
      run = function()
          local t = Read("steps")
          return #t.enum.order, t.enum.inA, t.enum.inB, t.renown.level, t.renown.max
      end,
      check = function()
          local t = Mine()
          if not t then return false, "no reading" end
          local e = t.enum
          local one = (e.inA == 65 and e.inB == 0) or (e.inB == 65 and e.inA == 0)
          return one, ("%d listed: set A %d, set B %d, other %d"):format(#e.order, e.inA, e.inB, e.other)
      end },
    { text = "Open the Legacy window (its micro button), Challenges tab. Does its \"x / 65\" match the "
          .. "renown on the [legacy] line in the /fp console?",
      ask = true, screenshot = "legacy window" },
    { text = "In the Legacy window's Challenges tab, type Spelunker in its search box, then press Run: "
          .. "does a search change what the category calls return?",
      button = "Run",
      run = function()
          local q = Quick()
          Out("with a search: " .. QuickText(q))
          return QuickText(q)
      end,
      check = function()
          local q = Quick()
          return q.found == 65, "with a search: " .. QuickText(q)
      end },
    { text = "Clear the search and close the Legacy window. Log out and log in ANOTHER character on this "
          .. "account, ideally one that has done different dungeons or explored different zones. "
          .. "The procedure resumes there. Wait 10 s after login, then press Next." },
    -- A wait, not an auto run: the procedure resumes at PLAYER_LOGIN, before
    -- the +10 s reading exists, and a run that threw there went to the error
    -- handler (seen in Bugsy, 2026-11-19). It also waits for THIS session's
    -- reading, never an older one of the same character.
    { text = "Comparing this character's reading with the first one's, once it is taken 10 s after login: "
          .. "the list, completed, earned by me, criteria, renown, Explore Azeroth.",
      timeout = 60,
      wait = function()
          local x, y = Other(), Mine()
          if not (y and session.uptimeAtLogin and (y.uptime or 0) >= session.uptimeAtLogin) then
              return false, "waiting for this login's reading (+10 s)"
          end
          if not x then return false, "no reading of another character on this account" end
          return true, Compare(x, y)
      end,
      check = function()
          local x, y = Other(), Mine()
          return x ~= nil and y ~= nil, x and y and (x.name .. " vs " .. y.name) or "missing a reading"
      end },
    { text = "Open the Legacy window. Is a challenge the FIRST character earned shown as complete here? "
          .. "(Type in the note which one you looked at.)",
      ask = true, screenshot = "legacy window, second character" },
    { text = "Close the window. Exit the client FULLY and relaunch, then log in this same character "
          .. "(a cold start). The procedure resumes there.", reload = "exit" },
    TimelineStep("cold start"),
    { text = "Now type /reload (or press Reload now): a warm start.", reload = true },
    TimelineStep("warm start"),
    { text = "Last: on the OTHER WoW account (same Battle.net account), log in any character and run "
          .. "/fp steps as legacy there too. Type /reload now to save these results.", reload = true },
})

-- The test seam, on the namespace, never on _G.
NS.legacy = { SET_A = SET_A, SET_B = SET_B, Read = Read, Quick = Quick, Compare = Compare, CritDiff = CritDiff,
              Mine = Mine, Other = Other, session = session }
