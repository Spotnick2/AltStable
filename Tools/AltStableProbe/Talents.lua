----------------------------------------------------------------------------
-- /fp steps as talents - can AltStable read and show every alt's talents? (#273)
--
-- Blizzard's own Forever talent frame (wow-ui-source, Blizzard_PlayerSpells/
-- Camelot/ClassTalents) reads one C_Traits tree per class (spec IDs 1482-1491)
-- whose three classic trees are node GROUPS: C_Traits.GetGroupDisplayInfoByTreeID
-- names them (displayName, icon), GetGroupCurrencyInfo counts the points spent
-- in each (currencyInfos[1].spent), and dual spec is two configs,
-- C_SpecializationInfo.GetCombatConfigIDForSpecGroup(1 | 2). To measure:
--   * that reading on the live client: the three trees, the points per tree,
--     every node's position and rank, and the build's import string
--     (C_Traits.GenerateImportString) and its length, for each spec group;
--   * PlayerSpellsUtil.InspectLoadout("specID:level:importString"), what a
--     talent-build chat link calls: called from addon code, does it open
--     Blizzard's talent frame read-only on a stored build, of this class and of
--     another, and does the player's own frame still work after?
--   * when the data is readable at login, and which events fire when a point is
--     spent or the spec group changes.
-- Every login while the probe is deployed records this character's reading in
-- AltStableProbeDB.talents.chars, so the other-class step finds one.
----------------------------------------------------------------------------

local _, NS = ...
local Probe = NS.Probe
local Describe = Probe.Describe

local function Out(s) Probe:Say("[talents] " .. tostring(s)) end

local function DB()
    AltStableProbeDB.talents = AltStableProbeDB.talents or {}
    local t = AltStableProbeDB.talents
    t.chars = t.chars or {}
    return t
end

-- A call that may be absent or throw: ok, then its returns.
local function Try(fn, ...)
    if type(fn) ~= "function" then return false, "absent" end
    return pcall(fn, ...)
end

local function Api(ns, name)
    local t = rawget(_G, ns)
    return type(t) == "table" and t[name] or nil
end

local function SpecID()
    local util = rawget(_G, "PlayerUtil")
    if type(util) == "table" and type(util.GetCurrentSpecID) == "function" then
        local ok, id = pcall(util.GetCurrentSpecID)
        if ok and id then return id, "PlayerUtil" end
    end
    local ok, index = Try(Api("C_SpecializationInfo", "GetSpecialization"))
    if not ok or not index then return nil, "no spec index" end
    local ok2, id = Try(Api("C_SpecializationInfo", "GetSpecializationInfo"), index)
    return ok2 and id or nil, "GetSpecializationInfo(" .. tostring(index) .. ")"
end

local function SpellOf(configID, entryID)
    local ok, entry = Try(Api("C_Traits", "GetEntryInfo"), configID, entryID)
    if not ok or type(entry) ~= "table" or not entry.definitionID then return nil end
    local ok2, def = Try(Api("C_Traits", "GetDefinitionInfo"), entry.definitionID)
    return ok2 and type(def) == "table" and def.spellID or nil
end

-- One config of the class tree: the three trees, the points in each, every
-- node, and the import string.
local function ReadConfig(configID, treeID)
    local r = { configID = configID, groups = {}, nodes = {} }
    if not configID or not treeID then r.error = "no config or tree"; return r end

    local ok, displays = Try(Api("C_Traits", "GetGroupDisplayInfoByTreeID"), treeID)
    local ids = {}
    if ok and type(displays) == "table" then
        for i, d in ipairs(displays) do
            r.groups[i] = { id = d.groupID, name = d.displayName, icon = d.icon }
            ids[#ids + 1] = d.groupID
            if i == 1 then r.groupShape = Describe(d) end
        end
    else
        r.groupsError = tostring(displays)
    end
    local ok2, infos = Try(Api("C_Traits", "GetGroupCurrencyInfo"), configID, ids)
    if ok2 and type(infos) == "table" then
        for _, info in ipairs(infos) do
            for _, g in ipairs(r.groups) do
                if g.id == info.traitNodeGroupID then
                    local c = type(info.currencyInfos) == "table" and info.currencyInfos[1] or nil
                    g.spent = c and c.spent
                    if not r.currencyShape then r.currencyShape = Describe(info) end
                end
            end
        end
    else
        r.currencyError = tostring(infos)
    end

    -- Every node: position, rank, tree, spell. The ranks summed per tree are
    -- checked against the trees' spent points.
    local ok3, nodeIDs = Try(Api("C_Traits", "GetTreeNodes"), treeID)
    r.ranksByGroup, r.visible, r.withPos = {}, 0, 0
    if ok3 and type(nodeIDs) == "table" then
        r.nodeCount = #nodeIDs
        for _, nodeID in ipairs(nodeIDs) do
            local okN, n = Try(Api("C_Traits", "GetNodeInfo"), configID, nodeID)
            if okN and type(n) == "table" then
                if not r.nodeShape and (n.ranksPurchased or 0) > 0 then r.nodeShape = Describe(n) end
                if n.isVisible then r.visible = r.visible + 1 end
                if n.posX and n.posY then r.withPos = r.withPos + 1 end
                local group = type(n.groupIDs) == "table" and n.groupIDs[1] or nil
                local rank = n.ranksPurchased or 0
                local key = tostring(group)
                r.ranksByGroup[key] = (r.ranksByGroup[key] or 0) + rank
                local entry = type(n.entryIDs) == "table" and n.entryIDs[1] or nil
                r.nodes[#r.nodes + 1] = {
                    id = nodeID, x = n.posX, y = n.posY, rank = rank, max = n.maxRanks,
                    group = group, visible = n.isVisible, type = n.type,
                    edges = type(n.visibleEdges) == "table" and #n.visibleEdges or nil,
                    spell = entry and SpellOf(configID, entry) or nil,
                }
            end
        end
    else
        r.nodesError = tostring(nodeIDs)
    end

    local ok4, import = Try(Api("C_Traits", "GenerateImportString"), configID)
    if ok4 and type(import) == "string" then
        r.import, r.importLength = import, #import
    else
        r.importError = tostring(import)
    end
    return r
end

local function Split(r)
    local parts = {}
    for _, g in ipairs(r.groups or {}) do
        parts[#parts + 1] = ("%s %s"):format(tostring(g.name), tostring(g.spent))
    end
    return #parts > 0 and table.concat(parts, " / ") or "no trees"
end

-- This character's whole reading, both spec groups, kept per character.
local function Read(label)
    local t = { at = date("%Y-%m-%d %H:%M:%S"), label = label, level = UnitLevel("player"),
                name = UnitName("player"), class = select(2, UnitClass("player")) }
    t.specID, t.specFrom = SpecID()
    local okA, active = Try(Api("C_SpecializationInfo", "GetActiveSpecGroup"))
    t.activeGroup = okA and active or nil
    local okN, num = Try(rawget(_G, "GetNumSpecGroups"))
    t.numSpecGroups = okN and num or nil
    local okC, cfg = Try(Api("C_ClassTalents", "GetActiveConfigID"))
    t.activeConfigID = okC and cfg or nil
    local okT, tree = Try(Api("C_ClassTalents", "GetTraitTreeForSpec"), t.specID)
    t.treeID = okT and tree or nil
    local okS, serial = Try(Api("C_Traits", "GetLoadoutSerializationVersion"))
    t.serialization = okS and serial or nil
    local util = rawget(_G, "PlayerSpellsUtil")
    t.inspectLoadout = type(util) == "table" and type(util.InspectLoadout) == "function"

    t.groups = {}
    for g = 1, math.max(tonumber(t.numSpecGroups) or 1, 1) do
        local okG, configID = Try(Api("C_SpecializationInfo", "GetCombatConfigIDForSpecGroup"), g)
        t.groups[g] = ReadConfig(okG and configID or nil, t.treeID)
    end
    DB().chars[t.name or "?"] = t

    Out(("%s (%s, level %s): spec %s via %s, tree %s, active group %s of %s, active config %s, "
        .. "InspectLoadout %s"):format(tostring(t.name), tostring(t.class), tostring(t.level),
        tostring(t.specID), tostring(t.specFrom), tostring(t.treeID), tostring(t.activeGroup),
        tostring(t.numSpecGroups), tostring(t.activeConfigID), tostring(t.inspectLoadout)))
    for g, r in ipairs(t.groups) do
        Out(("  group %d, config %s: %s; %s nodes, %d visible, %d placed; import %s chars"):format(
            g, tostring(r.configID), Split(r), tostring(r.nodeCount), r.visible or 0, r.withPos or 0,
            tostring(r.importLength or r.importError)))
    end
    return t
end

local function Mine() return DB().chars[UnitName("player") or "?"] end

-- The points in the three trees must add up to the ranks bought in all the
-- nodes. Per tree can't be checked from the nodes: a node's groupIDs hold more
-- groups than its tree (measured on 70938, #273). A tree with no points has no
-- currency entry, so its spent is nil: 0.
local function Consistent(r)
    if type(r) ~= "table" or #(r.groups or {}) ~= 3 then return false, "not three trees" end
    local spent, ranks = 0, 0
    for _, g in ipairs(r.groups) do spent = spent + (g.spent or 0) end
    for _, n in ipairs(r.nodes or {}) do ranks = ranks + (n.rank or 0) end
    if spent ~= ranks then
        return false, ("%d points in the trees, %d ranks in the nodes"):format(spent, ranks)
    end
    if (r.withPos or 0) == 0 then return false, "no node has a position" end
    return true, Split(r)
end

-- Blizzard's frame, read-only on a stored build, as a talent-build link opens it.
local function View(t)
    if type(t) ~= "table" then error("no stored reading for that character", 0) end
    if InCombatLockdown() then error("in combat: try again after it", 0) end
    local r = t.groups[t.activeGroup or 1]
    if not (r and r.import) then error("no import string stored for " .. tostring(t.name), 0) end
    local util = rawget(_G, "PlayerSpellsUtil")
    if not (type(util) == "table" and type(util.InspectLoadout) == "function") then
        error("PlayerSpellsUtil.InspectLoadout is absent", 0)
    end
    util.InspectLoadout(("%s:%s:%s"):format(tostring(t.specID), tostring(t.level), r.import))
    local frame = rawget(_G, "PlayerSpellsFrame")
    local shown = frame and frame:IsShown() or false
    Out(("viewed %s's build (%s): frame shown %s"):format(tostring(t.name), Split(r), tostring(shown)))
    return shown, t.name, Split(r)
end

local function OtherClass()
    local mine = select(2, UnitClass("player"))
    local best
    for _, t in pairs(DB().chars) do
        if t.class ~= mine and (not best or (t.at or "") > (best.at or "")) then best = t end
    end
    return best
end

----------------------------------------------------------------------------
-- Login timing and events. Events are kept for this session only, with the
-- seconds since PLAYER_LOGIN; the readings at login, entering the world, +2 s
-- and +10 s say when the scan can read the talents.
----------------------------------------------------------------------------

local EVENTS = { "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "TRAIT_CONFIG_LIST_UPDATED",
                 "TRAIT_CONFIG_UPDATED", "TRAIT_CONFIG_CREATED", "TRAIT_TREE_CURRENCY_INFO_UPDATED",
                 "TRAIT_TREE_CHANGED", "TRAIT_NODE_CHANGED", "PLAYER_TALENT_UPDATE",
                 "ACTIVE_TALENT_GROUP_CHANGED", "PLAYER_SPECIALIZATION_CHANGED",
                 "ACTIVE_PLAYER_SPECIALIZATION_CHANGED", "SPEC_INVOLUNTARILY_CHANGED",
                 "CHARACTER_POINTS_CHANGED", "PLAYER_LEVEL_UP",
                 "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }

local session = { events = {}, counts = {} }
local loginAt

local function Quick()
    local okC, cfg = Try(Api("C_ClassTalents", "GetActiveConfigID"))
    local specID = SpecID()
    local okT, tree = Try(Api("C_ClassTalents", "GetTraitTreeForSpec"), specID)
    if not (okC and cfg and okT and tree) then
        return ("config %s, tree %s"):format(tostring(okC and cfg), tostring(okT and tree))
    end
    local r = ReadConfig(cfg, tree)
    return ("config %s: %s, %s nodes"):format(tostring(cfg), Split(r), tostring(r.nodeCount))
end

local function Mark(key)
    session.login = session.login or {}
    session.login[key] = { t = loginAt and ("%.1f"):format(GetTime() - loginAt) or nil,
                           reading = Quick(), eventsBefore = #session.events }
end

local frame = CreateFrame("Frame")
Probe:RegisterEvents(frame, EVENTS)
frame:SetScript("OnEvent", function(_, ev, ...)
    if ev == "PLAYER_LOGIN" then loginAt = GetTime() end
    local args = {}
    for i = 1, math.min(select("#", ...), 4) do args[i] = Describe((select(i, ...))) end
    session.counts[ev] = (session.counts[ev] or 0) + 1
    -- TRAIT_NODE_CHANGED fires per node: counted always, listed only a few times.
    if ev ~= "TRAIT_NODE_CHANGED" or session.counts[ev] <= 5 then
        local list = session.events
        list[#list + 1] = ("%s %s %s"):format(loginAt and ("%.1f"):format(GetTime() - loginAt) or "pre",
                                              ev, table.concat(args, " "))
        while #list > 200 do table.remove(list, 1) end
    end
    if ev == "ADDON_ACTION_BLOCKED" or ev == "ADDON_ACTION_FORBIDDEN" then
        Out("|cffff5555" .. ev .. "|r " .. table.concat(args, " "))
    end
    if ev == "PLAYER_LOGIN" then
        DB().session = session   -- this session's, saved at logout
        Mark("login")
        C_Timer.After(2, function() Mark("plus2s") end)
        C_Timer.After(10, function()
            Mark("plus10s")
            local ok, err = pcall(Read, "login+10s")
            if not ok then Out("reading at login+10s failed: " .. tostring(err)) end
        end)
    elseif ev == "PLAYER_ENTERING_WORLD" and not (session.login and session.login.world) then
        Mark("world")
    end
end)

local function Blocked()
    return (session.counts.ADDON_ACTION_BLOCKED or 0) + (session.counts.ADDON_ACTION_FORBIDDEN or 0)
end

Probe:Command("talents", function()
    Read("manual")
end, ": this character's talent trees, points, nodes and build string (#273)")

Probe:Steps("talents", {
    title = "Talents: read them, and show a stored build in Blizzard's frame (#273)",
    rev = 1,
    { text = "Reading this character's talents: the three trees, the points in each, every node and the build string.",
      auto = true,
      run = function()
          local t = Read("steps")
          local r = t.groups[t.activeGroup or 1]
          return Split(r or {}), r and r.importLength
      end,
      check = function()
          local t = Mine()
          return Consistent(t and t.groups[t.activeGroup or 1])
      end },
    { text = "Open your talent frame (N). Do the three trees' names and points match the [talents] line in the /fp console?",
      ask = true, screenshot = "own talent frame" },
    { text = "Close the talent frame. Out of combat, press View: Blizzard's talent frame should open on this character's stored build, read-only.",
      button = "View", run = function() return View(Mine()) end, screenshot = "own build, viewed" },
    { text = "Did it open on this character's build (same trees and points), with no way to spend or change it?",
      ask = true },
    { text = "Close it, then open your own talents with N. Is it your own talent frame, working as usual?",
      ask = true },
    { text = "Log out to the character list and log in a character of ANOTHER class on this account. "
          .. "The procedure resumes there. Wait 10 s after login, then press Next.", },
    { text = "This character's reading, taken 10 s after login.", auto = true,
      run = function()
          local t = Mine()
          if not t then error("no reading yet: wait 10 s after login, then Retry", 0) end
          local r = t.groups[t.activeGroup or 1]
          return t.class, Split(r or {})
      end,
      check = function()
          local other = OtherClass()
          if not other then return false, "no stored reading of another class" end
          return Consistent(Mine() and Mine().groups[Mine().activeGroup or 1])
      end },
    { text = "Out of combat, press View: Blizzard's frame should open on the first character's build, of the other class.",
      button = "View", run = function() return View(OtherClass()) end, screenshot = "other class, viewed" },
    { text = "Did it show the other character's class, trees and points?", ask = true },
    { text = "Close it. Was any action blocked by the viewing? (Counted from the client's events.)", auto = true,
      run = function() return Blocked() end,
      check = function()
          local n = Blocked()
          return n == 0, n == 0 and "nothing blocked" or (n .. " blocked or forbidden actions: see the log")
      end },
    { text = "Optional: if this character has an unspent talent point, spend it and apply; or, if dual spec is "
          .. "unlocked, switch spec. Otherwise press Skip.", event = "TRAIT_CONFIG_UPDATED" },
    { text = "Type /reload (or press Reload now), to see when the talents are readable at login.", reload = true },
    { text = "When the talents were readable after this login (at login, entering the world, +2 s, +10 s).",
      timeout = 30,
      wait = function()
          local l = session.login or {}
          if not l.plus10s then return false, "waiting for the +10 s reading" end
          local function at(k) return l[k] and (tostring(l[k].t) .. "s " .. tostring(l[k].reading)) or "-" end
          Out("login " .. at("login")); Out("world " .. at("world"))
          Out("+2s " .. at("plus2s")); Out("+10s " .. at("plus10s"))
          return true, at("login"), at("world"), at("plus2s")
      end,
      check = function()
          local l = session.login or {}
          local r = l.plus2s and l.plus2s.reading or ""
          return r:find(" nodes$") ~= nil and not r:find("nil nodes"), "+2s: " .. tostring(r)
      end },
})
