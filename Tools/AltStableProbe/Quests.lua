----------------------------------------------------------------------------
-- /fp steps as quests - what the client gives for quest progress (#374, #372)
--
-- The Loremaster plugin counts, per character and per zone, the quests done
-- out of those the character can ever do. Its quest table comes from
-- QuestieDB; done-ness comes from the client. From the 70959 dump, not yet
-- measured live:
--   * C_QuestLog.GetAllCompletedQuestIDs() -> quests:table
--   * C_QuestLog.IsQuestFlaggedCompleted(id), IsQuestFlaggedCompletedOnAccount(id)
--   * C_QuestLog.GetTitleForQuestID(id) -> optional title
--   * QUEST_TURNED_IN(questID, xpReward, moneyReward)
-- To measure, before the plugin promises anything:
--   1. readiness and cost: is the completed list there at PLAYER_LOGIN, how
--      big, how long it takes (login, +1, +3, +10 s);
--   2. scope: per character, or per account: two characters of one account
--      compared offline, and IsQuestFlaggedCompletedOnAccount on the IDs only
--      the other one has;
--   3. QUEST_TURNED_IN: is the quest already completed inside the handler,
--      or only later (+0.5, +2 s)?
--   4. names: how many quest titles the client holds without asking the
--      server (no Request* call: some of them disconnect the client);
--   5. races: this character's race ID and faction, and every race the
--      client knows (C_CreatureInfo.GetRaceInfo), for QuestieDB's race masks;
--   6. zone names: C_Map.GetMapInfo for the zone and dungeon maps, localized.
-- Every login while the probe is deployed records this character's reading
-- at +10 s in AltStableProbeDB.quests.chars, so the steps find two characters.
----------------------------------------------------------------------------

local _, NS = ...
local Probe = NS.Probe
local Describe = Probe.Describe

local function Out(s) Probe:Say("[quests] " .. tostring(s)) end

-- Quests worth naming in the readings (from QuestieDB 1.1.1 Forever): a
-- Northshire start, a Barrens exploration, a breadcrumb chain, a child quest,
-- the Skyborne shaman chain, a PvP bracket quest.
local SAMPLES = { 7, 783, 870, 1361, 1362, 1365, 3449, 3450, 92466, 92467, 92468, 98895 }
local TITLE_SCAN_MAX = 100000      -- IDs scanned for cached titles

local function DB()
    AltStableProbeDB.quests = AltStableProbeDB.quests or {}
    local t = AltStableProbeDB.quests
    t.chars = t.chars or {}
    t.sessions = t.sessions or {}
    t.turnIns = t.turnIns or {}
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

local function Now()
    local f = rawget(_G, "debugprofilestop")
    return type(f) == "function" and f() or 0
end

-- The completed list, with its cost and shape. Returns the set too.
local function Completed()
    local t0 = Now()
    local ok, list = Try(Api("C_QuestLog", "GetAllCompletedQuestIDs"))
    local ms = Now() - t0
    if not ok then return { error = tostring(list) }, {} end
    if type(list) ~= "table" then return { error = "not a table: " .. Describe(list) }, {} end
    local set, n, maxId, minId, nonNumber = {}, 0, 0, math.huge, 0
    for k, v in pairs(list) do
        local id = tonumber(v)
        if id then
            set[id] = true
            n = n + 1
            if id > maxId then maxId = id end
            if id < minId then minId = id end
        else
            nonNumber = nonNumber + 1
        end
        if type(k) ~= "number" then nonNumber = nonNumber + 1 end
    end
    return { count = n, ms = ("%.2f"):format(ms), maxId = maxId, minId = n > 0 and minId or nil,
             arrayLen = #list, nonNumber = nonNumber }, set
end

local function Flagged(id)
    local ok, v = Try(Api("C_QuestLog", "IsQuestFlaggedCompleted"), id)
    if not ok then return "error" end
    return v
end

local function OnAccount(id)
    local ok, v = Try(Api("C_QuestLog", "IsQuestFlaggedCompletedOnAccount"), id)
    if not ok then return "error" end
    return v
end

local function Title(id)
    local ok, v = Try(Api("C_QuestLog", "GetTitleForQuestID"), id)
    if not ok then return nil, tostring(v) end
    return v
end

-- How many titles the client holds, for every ID up to TITLE_SCAN_MAX.
local function Titles()
    local t0, n, firstNil = Now(), 0, nil
    for id = 1, TITLE_SCAN_MAX do
        local title = Title(id)
        if type(title) == "string" and title ~= "" then n = n + 1 end
    end
    local samples = {}
    for _, id in ipairs(SAMPLES) do samples[#samples + 1] = ("%d=%s"):format(id, Describe(Title(id))) end
    return { cached = n, scanned = TITLE_SCAN_MAX, ms = ("%.0f"):format(Now() - t0),
             samples = table.concat(samples, "; ") }
end

local function Identity()
    local _, raceFile, raceID = UnitRace("player")
    local _, classFile, classID = UnitClass("player")
    local races = {}
    local get = Api("C_CreatureInfo", "GetRaceInfo")
    for id = 1, 128 do
        local ok, info = Try(get, id)
        if ok and type(info) == "table" and info.raceName then
            races[#races + 1] = ("%d=%s/%s"):format(id, tostring(info.clientFileString), tostring(info.raceName))
        end
    end
    return { raceFile = raceFile, raceID = raceID, classFile = classFile, classID = classID,
             faction = UnitFactionGroup("player"), level = UnitLevel("player"),
             races = table.concat(races, ", ") }
end

-- Zone and dungeon maps: Classic's 1411-1460 range and Forever's newer IDs.
local function Maps()
    local get = Api("C_Map", "GetMapInfo")
    local zones, dungeons = {}, {}
    local function scan(a, b)
        for id = a, b do
            local ok, info = Try(get, id)
            if ok and type(info) == "table" and info.name then
                local line = ("%d=%s(p%s)"):format(id, info.name, tostring(info.parentMapID))
                if info.mapType == 3 then zones[#zones + 1] = line
                elseif info.mapType == 4 then dungeons[#dungeons + 1] = line end
            end
        end
    end
    scan(1400, 1470)
    scan(2400, 2800)
    return { zones = table.concat(zones, ", "), dungeons = table.concat(dungeons, ", "),
             numZones = #zones, numDungeons = #dungeons }
end

local function SampleFlags(set)
    local out = {}
    for _, id in ipairs(SAMPLES) do
        out[#out + 1] = ("%d:%s/%s/%s"):format(id, set[id] and "L" or "-", Describe(Flagged(id)),
                                               Describe(OnAccount(id)))
    end
    return table.concat(out, " ")
end

-- The whole reading of this character, saved under its name.
local function Read(label)
    local summary, set = Completed()
    local ids = {}
    for id in pairs(set) do ids[#ids + 1] = id end
    table.sort(ids)
    local t = {
        label = label, at = date("%Y-%m-%d %H:%M:%S"), uptime = GetTime(),
        name = UnitName("player"), realm = GetRealmName(),
        completed = summary, ids = table.concat(ids, ","),
        samples = SampleFlags(set),
        identity = Identity(),
    }
    DB().chars[t.name or "?"] = t
    Out(("%s: %s completed (%s ms, ids %s-%s, array %s), %s %s %s level %s")
        :format(label, tostring(summary.count or summary.error), tostring(summary.ms),
                tostring(summary.minId), tostring(summary.maxId), tostring(summary.arrayLen),
                tostring(t.identity.faction), tostring(t.identity.raceFile), tostring(t.identity.raceID),
                tostring(t.identity.level)))
    Out("samples (log/flagged/account): " .. t.samples)
    return t
end

local function Mine() return DB().chars[UnitName("player") or "?"] end

-- The most recent reading of another character.
local function Other()
    local me, best = UnitName("player"), nil
    for name, t in pairs(DB().chars) do
        if name ~= me and (not best or (t.at or "") > (best.at or "")) then best = t end
    end
    return best
end

local function SetOf(csv)
    local s, n = {}, 0
    for id in tostring(csv or ""):gmatch("%d+") do s[tonumber(id)] = true; n = n + 1 end
    return s, n
end

-- Two characters' completed lists: shared, only one, only the other; and
-- what IsQuestFlaggedCompleted / OnAccount say here for the other's own IDs.
local function Compare(x, y)
    local xs, xn = SetOf(x.ids)
    local ys, yn = SetOf(y.ids)
    local both, onlyX, onlyY = 0, {}, 0
    for id in pairs(xs) do
        if ys[id] then both = both + 1 else onlyX[#onlyX + 1] = id end
    end
    for id in pairs(ys) do if not xs[id] then onlyY = onlyY + 1 end end
    table.sort(onlyX)
    local flaggedHere, accountHere, probed = 0, 0, 0
    for i = 1, math.min(#onlyX, 50) do
        local id = onlyX[i]
        probed = probed + 1
        if Flagged(id) == true then flaggedHere = flaggedHere + 1 end
        if OnAccount(id) == true then accountHere = accountHere + 1 end
    end
    local r = { first = x.name, second = y.name, firstCount = xn, secondCount = yn, both = both,
                onlyFirst = #onlyX, onlySecond = onlyY, probed = probed,
                flaggedHere = flaggedHere, accountHere = accountHere }
    DB().lastCompare = r
    Out(("%s %d vs %s %d: %d shared, %d only %s, %d only %s; of %d of %s's own, here flagged %d, on account %d")
        :format(x.name, xn, y.name, yn, both, #onlyX, x.name, onlyY, y.name, probed, x.name,
                flaggedHere, accountHere))
    return r
end

----------------------------------------------------------------------------
-- Events: the login timeline and every turn-in
----------------------------------------------------------------------------

local EVENTS = { "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "QUEST_TURNED_IN", "QUEST_REMOVED",
                 "QUEST_ACCEPTED", "QUEST_LOG_UPDATE", "PLAYER_LEVEL_UP" }
local NOISY = { QUEST_LOG_UPDATE = true }

local session = { events = {}, counts = {}, login = {} }
local loginAt

local function Since() return loginAt and ("%.1f"):format(GetTime() - loginAt) or "pre" end

local function Mark(key)
    local ok, s = pcall(Completed)
    session.login[key] = { t = Since(), reading = ok and s or { error = tostring(s) } }
end

-- One turn-in: is the quest completed inside the handler, and later?
local function TurnIn(questID)
    local r = { id = questID, at = Since(), title = Title(questID) }
    local function look(key)
        local _, set = Completed()
        r[key] = ("list %s, flagged %s"):format(set[questID] and "yes" or "no", Describe(Flagged(questID)))
    end
    look("handler")
    local list = DB().turnIns
    list[#list + 1] = r
    while #list > 20 do table.remove(list, 1) end
    C_Timer.After(0.5, function() look("plus05s") end)
    C_Timer.After(2, function()
        look("plus2s")
        Out(("turned in %s (%s): in the handler %s; +0.5 s %s; +2 s %s"):format(tostring(questID),
            tostring(r.title), r.handler, tostring(r.plus05s), r.plus2s))
    end)
    return r
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
    if ev == "QUEST_TURNED_IN" then
        TurnIn((...))
    elseif ev == "PLAYER_LOGIN" then
        session.uptimeAtLogin = GetTime()
        DB().sessions[UnitName("player") or "?"] = session   -- this session's, saved at logout
        Mark("login")
        for _, s in ipairs({ 1, 3, 10 }) do
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
    local out = {}
    for _, k in ipairs({ "login", "world", "plus1s", "plus3s", "plus10s" }) do
        local m = session.login[k]
        local r = m and m.reading or {}
        local line = ("%s %s: %s completed, %s ms"):format(k, m and m.t or "-",
            tostring(r.count or r.error or "-"), tostring(r.ms or "-"))
        out[#out + 1] = line
        Out(line)
    end
    return out
end

----------------------------------------------------------------------------
-- Commands and the procedure
----------------------------------------------------------------------------

Probe:Command("quests", function()
    Read("manual")
end, ": this character's completed quests, samples, race and faction (#374)")

Probe:Command("queststime", function()
    Timeline()
end, ": when the completed-quest list was readable after this login (#374)")

Probe:Command("questnames", function()
    local t = Titles()
    DB().titles = t
    Out(("titles held: %d of %d IDs scanned (%s ms); %s"):format(t.cached, t.scanned, t.ms, t.samples))
end, ": how many quest titles the client holds without asking the server (#374)")

Probe:Command("questmaps", function()
    local m = Maps()
    DB().maps = m
    Out(("%d zone maps, %d dungeon maps; zones: %s"):format(m.numZones, m.numDungeons, m.zones))
end, ": the zone and dungeon map names, localized (#374)")

Probe:Steps("quests", {
    title = "Quest progress: what the client gives, per character (#374, #372)",
    rev = 1,
    { text = "Reading this character's completed quests: how many, how fast, race and faction, "
          .. "and the sample quests (in the log / flagged / on the account).",
      auto = true,
      run = function()
          local t = Read("steps")
          return t.completed.count, t.completed.ms, t.identity.raceID
      end,
      check = function()
          local t = Mine()
          if not t then return false, "no reading" end
          local c = t.completed
          return (c.count or 0) > 0, ("%s completed in %s ms"):format(tostring(c.count or c.error), tostring(c.ms))
      end },
    { text = "When the list was readable after this login (login, entering the world, +1, +3, +10 s). "
          .. "Wait about 10 s.",
      timeout = 40,
      wait = function()
          if not session.login.plus10s then return false, "waiting for the +10 s reading" end
          return true, unpack(Timeline())
      end,
      check = function()
          local m = session.login.login
          local r = m and m.reading or {}
          return (r.count or 0) > 0, "at PLAYER_LOGIN: " .. tostring(r.count or r.error)
      end },
    { text = "Quest names and zone maps: how many titles the client holds without asking the server, "
          .. "and the zone names. Press Run (it takes a second or two).",
      button = "Run",
      run = function()
          local t = Titles()
          DB().titles = t
          local m = Maps()
          DB().maps = m
          Out(("titles held: %d of %d (%s ms); %s"):format(t.cached, t.scanned, t.ms, t.samples))
          Out(("%d zone maps, %d dungeon maps"):format(m.numZones, m.numDungeons))
          return t.cached, m.numZones
      end,
      check = function()
          local t, m = DB().titles, DB().maps
          return t ~= nil and m ~= nil and m.numZones > 0,
              ("%s titles, %s zones"):format(tostring(t and t.cached), tostring(m and m.numZones))
      end },
    { text = "Turn in any quest now (accept an easy one and finish it, or hand in one that is ready). "
          .. "The step goes on by itself 2 s after the turn-in.",
      timeout = 900,
      wait = function()
          local list = DB().turnIns
          local r = list[#list]
          if not (r and r.plus2s and session.uptimeAtLogin) then return false, "waiting for a turn-in" end
          return true, ("%s: handler %s; +0.5 s %s; +2 s %s"):format(tostring(r.id), r.handler,
              tostring(r.plus05s), r.plus2s)
      end,
      check = function()
          local list = DB().turnIns
          local r = list[#list]
          return r ~= nil and r.plus2s ~= nil and r.plus2s:find("list yes", 1, true) ~= nil,
              r and ("handler: " .. tostring(r.handler)) or "no turn-in"
      end },
    { text = "Log out and log in ANOTHER character on this account, ideally one that has done "
          .. "different quests. The procedure resumes there. Wait 10 s after login, then press Next." },
    { text = "Comparing this character's completed quests with the first one's, once it is read 10 s "
          .. "after login, and asking the client about the first one's own quests here.",
      timeout = 60,
      wait = function()
          local x, y = Other(), Mine()
          if not (y and session.uptimeAtLogin and (y.uptime or 0) >= session.uptimeAtLogin) then
              return false, "waiting for this login's reading (+10 s)"
          end
          if not x then return false, "no reading of another character on this account" end
          local r = Compare(x, y)
          return true, r.both, r.onlyFirst, r.flaggedHere, r.accountHere
      end,
      check = function()
          local r = DB().lastCompare
          return r ~= nil and r.onlyFirst > 0,
              r and ("%d only on %s; flagged here %d, on account %d"):format(r.onlyFirst, r.first,
                  r.flaggedHere, r.accountHere) or "no comparison"
      end },
    { text = "Done. Type /reload (or press Reload now) to save these results.", reload = true },
})

-- The test seam, on the namespace, never on _G.
NS.quests = { SAMPLES = SAMPLES, Read = Read, Completed = Completed, Compare = Compare, TurnIn = TurnIn,
              Titles = Titles, Maps = Maps, Identity = Identity, Mine = Mine, Other = Other,
              session = session }
