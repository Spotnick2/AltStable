------------------------------------------------------------
-- test_legacy.lua - the Legacy Challenges plugin (#373)
--
-- The stubs model what 1.60.1.70959 measured (forever-api-notes.md, "Legacy
-- Challenges"): the challenges are achievements worth Legacy points, found by
-- walking the categories; completion and criteria are one state for the
-- whole Battle.net account; a craft challenge's one criterion is the
-- account's best skill; class challenges have no criteria; Explorer is per
-- character. What has to hold:
--   * a read keeps what it could not see: an earned challenge stays earned,
--     a criterion list that did not read keeps the last one, a partial list
--     is no read at all;
--   * the grids count only our own alts (never a friend's, never a hidden
--     one), and say "~" for a threshold reached on a challenge still open;
--   * a craft names the alt whose skill matches the game's best, else
--     "Crafter unknown";
--   * a checklist puts its missing parts first and names the last one;
--     Explorer names the most complete character seen;
--   * the footer counts the account's points toward the next reward, and the
--     tab swaps the totals bar's content for its own and gives it back.
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

AltStable = {}
AltStableDB = {}
AltStableConfig = {}
dofile("Compat.lua")
assert(loadfile("Core.lua"))()
dofile("Config.lua")
-- The scanner's own skill reading, which "This character" uses live.
dofile("Scanner.lua")
dofile("tests/libglass.lua"); LoadGlass("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")
dofile("CharacterMenu.lua")   -- the right-click menu frame the Bucket List reuses
dofile("RowRenderer.lua")     -- the gear palette (AltStable.QualityRGB) the points bar uses

AltStable.plugins = {}
dofile("Plugins/Legacy/LegacyData.lua")
dofile("Plugins/Legacy/AltStableLegacy.lua")
WoW.flushTimers()

local plugin
for _, p in ipairs(AltStable.plugins or {}) do if p.id == "legacy" then plugin = p end end
check("the plugin registers itself with the core", plugin ~= nil)
if not plugin then
    print(("test_legacy: %d passed, %d failed"):format(passed, failed + 1)); os.exit(1)
end
local L = plugin._test
local D = AltStable.LegacyData

local listed = false
for _, p in ipairs(AltStable.LOD_PLUGINS) do if p.key == "legacy" and p.addon == "AltStableLegacy" then listed = true end end
check("the core lists it among the load-on-demand plugins", listed)

------------------------------------------------------------
-- The grid map
------------------------------------------------------------

local perSet = { A = { class = 0, craft = 0 }, B = { class = 0, craft = 0 } }
local tiers = {}
for _, g in pairs(D.GRID) do
    perSet[g[4]][g[1]] = perSet[g[4]][g[1]] + 1
    local k = g[4] .. g[1] .. g[2]
    tiers[k] = (tiers[k] or 0) + 1
end
for _, set in ipairs({ "A", "B" }) do
    eq("set " .. set .. " maps 27 class milestones", perSet[set].class, 27)
    eq("set " .. set .. " maps 18 craft milestones", perSet[set].craft, 18)
    for _, class in ipairs(D.CLASSES) do eq("  " .. set .. " " .. class .. " has three tiers", tiers[set .. "class" .. class], 3) end
    for _, craft in ipairs(D.CRAFTS) do eq("  " .. set .. " " .. craft .. " has three tiers", tiers[set .. "craft" .. craft], 3) end
end

------------------------------------------------------------
-- A client like the one measured
------------------------------------------------------------

-- The set A ID of a class or craft milestone.
local function gridID(kind, key, threshold)
    for id, g in pairs(D.GRID) do
        if g[1] == kind and g[2] == key and g[3] == threshold and g[4] == "A" then return id end
    end
end

local CRAFT_BEST = { Alchemy = 48, Blacksmithing = 0, Enchanting = 150, Engineering = 89,
                     Leatherworking = 60, Tailoring = 146 }
local DUNGEONS = { "Ragefire Chasm or Hall of Thanes", "Ruins of Lordaeron", "Wailing Caverns",
                   "The Deadmines", "Shadowfang Keep", "Excavation Site: Wetlands" }

local function client()
    local ach, cats = {}, {}
    local function add(catID, id, t)
        ach[id] = t
        t.month, t.day, t.year = t.month or 11, t.day or 10, t.year or 26
        local cat
        for _, c in ipairs(cats) do if c.id == catID then cat = c end end
        if not cat then cat = { id = catID, title = "Cat " .. catID, ids = {} }; cats[#cats + 1] = cat end
        cat.ids[#cat.ids + 1] = id
    end
    for i, class in ipairs(D.CLASSES) do
        for _, t in ipairs(D.TIERS.class) do
            local id = gridID("class", class, t)
            add(15576 + i, id, { name = D.CLASS_NAMES[class] .. " " .. t, criteria = {},
                completed = (class == "MAGE" or class == "PRIEST") and t == 25 })
        end
    end
    for i, craft in ipairs(D.CRAFTS) do
        for _, t in ipairs(D.TIERS.craft) do
            local id = gridID("craft", craft, t)
            local best = CRAFT_BEST[craft]
            add(15586 + i, id, { name = craft .. " " .. t, completed = best >= t,
                criteria = { { text = t .. " " .. craft .. " Skill", type = 7, done = best >= t, q = best, req = t } } })
        end
    end
    local spelunker = {}
    for i, name in ipairs(DUNGEONS) do
        spelunker[i] = { text = name, type = 0, done = name ~= "Shadowfang Keep", q = name ~= "Shadowfang Keep" and 1 or 0, req = 1 }
    end
    add(15593, 62031, { name = "Novice Spelunker", criteria = spelunker })
    add(15594, 684, { name = "Conqueror of the Lair", criteria = {} })
    add(15598, 62046, { name = "Master of Alterac Valley",
        criteria = { { text = "Reach exalted reputation with the Frostwolf Clan", type = 243, q = 0, req = 42000 } } })
    add(15620, 63340, { name = "Field of Honor: Week 4",
        criteria = { { text = "Complete Field of Honor: Week 4", type = 27, q = 0, req = 1 } } })
    add(15596, 62382, { name = "Explorer", criteria = { { text = "Explorer", type = 8, asset = 62053, q = 0, req = 1 } } })
    add(15596, 62054, { name = "Lord Valthalak Laid to Rest", criteria = {} })
    -- Not a challenge: worth no points.
    add(92, 6, { name = "Level 10", completed = true, criteria = {} })
    -- Explore Azeroth and its continents, not in any listed category.
    local ek, kal = {}, {}
    for i = 1, 23 do ek[i] = { text = "EK " .. i, done = i <= 5 } end
    for i = 1, 20 do kal[i] = { text = "Kal " .. i, done = i <= 2 } end
    ach[62053] = { name = "Explore Azeroth", criteria = {
        { text = "Explore Eastern Kingdoms", type = 8, asset = 62353 },
        { text = "Explore Kalimdor", type = 8, asset = 62355 } } }
    ach[62353] = { name = "Explore Eastern Kingdoms", criteria = ek }
    ach[62355] = { name = "Explore Kalimdor", criteria = kal }

    local points = {}
    for id in pairs(ach) do points[id] = 0 end
    for id in pairs(D.GRID) do if D.GRID[id][4] == "A" then points[id] = 1 end end
    for _, id in ipairs({ 62031, 684, 62046, 63340, 62382, 62054 }) do points[id] = 1 end
    WoW.legacy = { categories = cats, achievements = ach, points = points, renown = 5, max = 65,
                   rewards = { [15] = 276236, [25] = 277714, [40] = 277717, [55] = 277718 } }
end

-- C_Traits is the plugin's points source; the stubs leave it out (the Roster
-- tests own their own), so it is put in here and taken out at the end.
local savedTraits = rawget(_G, "C_Traits")
rawset(_G, "C_Traits", {
    GetTraitCurrencyForAchievement = function(cur, id)
        return cur == 4225 and WoW.legacy and WoW.legacy.points[id] or 0
    end,
    GetMaxAvailableTraitCurrency = function(cur, limited)
        if cur ~= 4225 then return 0 end
        return limited and 16 or (WoW.legacy and WoW.legacy.max or 0)
    end,
})

------------------------------------------------------------
-- Reading
------------------------------------------------------------

client()
local s = L.Read(nil)
check("a read finds the challenges", s ~= nil)
eq("  the 45 milestones and 6 checklists, not the pointless one", s and #s.order, 51)
eq("  from set A", s and s.pool, "A")
eq("  the points are the renown", s and s.points, 5)
eq("  out of the max", s and s.max, 65)
eq("  four rewards on the track", s and #s.rewards, 4)
eq("  the first at 15", s and s.rewards[1].level, 15)
local novMage = gridID("class", "MAGE", 25)
check("  Novice Mage is earned", s and s.challenges[novMage].completed)
eq("  with its date", s and s.challenges[novMage].date, "2026-11-10")

-- A later read never un-earns a challenge.
WoW.legacy.achievements[novMage].completed = false
local s2 = L.Read(s)
check("an earned challenge stays earned when a read says otherwise", s2.challenges[novMage].completed)
WoW.legacy.achievements[novMage].completed = true

-- A criterion list that came back empty keeps the last one.
local saved = WoW.legacy.achievements[62031].criteria
WoW.legacy.achievements[62031].criteria = {}
s2 = L.Read(s)
eq("an empty criterion list keeps the last one", #s2.challenges[62031].criteria, 6)
WoW.legacy.achievements[62031].criteria = saved

-- A list that did not read, or only partly, is no read: the last one stays.
local cats = WoW.legacy.categories
WoW.legacy.categories = {}
local s3, why = L.Read(s)
check("an empty list keeps the last read", s3 == s, why)
WoW.legacy.categories = { cats[1], cats[2] }
s3 = L.Read(s)
check("  so does a partial one", s3 == s)
WoW.legacy.categories = cats
check("with nothing before, an empty list is nothing", (L.Read(nil)) ~= nil)
WoW.legacy.categories = {}
check("  (an empty one, from nothing, stays nothing)", L.Read(nil) == nil)
WoW.legacy.categories = cats

-- Losing just one category is no read either (Codex on #381): its earned
-- challenges would drop out, and the section would read 0 / 0.
local fewer = {}
for _, c in ipairs(cats) do if c.id ~= 15593 then fewer[#fewer + 1] = c end end
WoW.legacy.categories = fewer
check("a read that lost one category keeps the last", L.Read(s) == s)
WoW.legacy.categories = cats
check("  and the full list reads again", L.Read(s) ~= s)

------------------------------------------------------------
-- The alts and the grids
------------------------------------------------------------

AltStableDB = {
    ["G-hunter"]  = { name = "Kaleidria", class = "HUNTER", level = 21, scannedHere = true },
    ["G-priest"]  = { name = "Karuzo", class = "PRIEST", level = 30, scannedHere = true,
                      prof_Tailoring = 146, prof_Enchanting = 150 },
    ["G-mage"]    = { name = "Drakuza", class = "MAGE", level = 30, provKind = "own-account",
                      prof_Engineering = 89 },
    ["G-paladin"] = { name = "Elegia", class = "PALADIN", level = 26, scannedHere = true },
    ["G-friend"]  = { name = "Friend", class = "WARRIOR", level = 60, provKind = "third-party" },
    ["G-rogue"]   = { name = "Hidden", class = "ROGUE", level = 50, scannedHere = true },
}
AltStable.SetCharacterHidden("G-rogue", true)

local alts = L.OwnAlts()
local names = {}
for _, a in ipairs(alts) do names[#names + 1] = a.name end
eq("our own alts only, hidden ones left out", table.concat(names, ","), "Drakuza,Elegia,Kaleidria,Karuzo")

local m = L.Model(s, alts)
local function classRow(key) for _, r in ipairs(m.classes) do if r.key == key then return r end end end
local function craftRow(key) for _, r in ipairs(m.crafts) do if r.key == key then return r end end end
local function states(r)
    local out = {}
    for _, c in ipairs(r.cells) do out[#out + 1] = c.state end
    return table.concat(out, ",")
end

eq("Hunter: the next tier shows the best hunter's level", states(classRow("HUNTER")), "progress,later,later")
eq("  21 of 25", L.CellText(classRow("HUNTER").cells[1]), "21/25")
-- A starred later tier shows its own progress, beside its star (GPT-Astra on #389).
eq("  the 45 tier: a dash", L.CellText(classRow("HUNTER").cells[2]), L.CellText({ state = "none" }))
eq("  but starred, 21/45", L.CellText(classRow("HUNTER").cells[2], true), "21/45")
eq("  a starred tier nobody can advance stays a dash", L.CellText(classRow("WARRIOR").cells[1], true),
   L.CellText({ state = "none" }))

-- The name column fits its widest name (GPT-Astra on #389: the crafters were cut).
eq("crafts: Leatherworking at 91 starts the crafters at 131", L.NameColumnX("craft", 91), 131)
eq("classes: Warlock at 50, at 90", L.NameColumnX("class", 50), 90)
eq("  a width not measured yet keeps the fixed 150", L.NameColumnX("craft", 0), 150)
eq("  never past it either", L.NameColumnX("class", 200), 116)
eq("  named", classRow("HUNTER").best.name, "Kaleidria")
eq("Priest: earned, then 30 of 45", states(classRow("PRIEST")), "done,progress,later")
eq("Mage: an own-account alt counts", classRow("MAGE").best and classRow("MAGE").best.name, "Drakuza")
eq("Paladin: 26 reached, still open: credit unknown, never 'gain 0'", states(classRow("PALADIN")), "credit,progress,later")
eq("  shown as ~", L.CellText(classRow("PALADIN").cells[1]), "|cffffd100~|r")
eq("Warrior: a friend's 60 does not count", states(classRow("WARRIOR")), "none,none,none")
check("  nobody named", classRow("WARRIOR").best == nil)
eq("Rogue: a hidden alt does not count", states(classRow("ROGUE")), "none,none,none")
eq("classes earned", m.classDone, 2)
eq("  of", m.classTotal, 27)

eq("Tailoring: the game's best skill, 146 of 150", L.CellText(craftRow("Tailoring").cells[1]), "146/150")
eq("  the alt whose skill matches is the crafter", craftRow("Tailoring").crafter and craftRow("Tailoring").crafter.name, "Karuzo")
eq("Alchemy: 48 that no alt matches", craftRow("Alchemy").skill, 48)
check("  so no crafter named (Crafter unknown)", craftRow("Alchemy").crafter == nil)
eq("Blacksmithing: nobody", states(craftRow("Blacksmithing")), "none,none,none")
eq("Enchanting: earned, then 150 of 225", states(craftRow("Enchanting")), "done,progress,later")
eq("crafts earned", m.craftDone, 1)

-- Hovering a row lists every own alt behind it, highest first.
local tailors = craftRow("Tailoring").others
eq("a craft's row knows every alt with it", #tailors, 1)
eq("  with its skill", tailors[1] and tailors[1].value, 146)
eq("a class's row knows every alt of it", #classRow("PRIEST").others, 1)
eq("  with its level", classRow("PRIEST").others[1].value, 30)
eq("  and none for a class nobody plays", #classRow("ROGUE").others, 0)

-- A skill the game reports below an alt's own: the game's figure wins. Every
-- tier's criterion carries the same best (measured: Enchanting 150 on both).
local function tailoring(q)
    for _, t in ipairs(D.TIERS.craft) do WoW.legacy.achievements[gridID("craft", "Tailoring", t)].criteria[1].q = q end
end
tailoring(140)
local mLow = L.Model(L.Read(nil), alts)
for _, r in ipairs(mLow.crafts) do
    if r.key == "Tailoring" then
        eq("the game's best is used, not an alt's", r.skill, 140)
        check("  and an alt that does not match it is not named", r.crafter == nil)
    end
end
tailoring(146)

------------------------------------------------------------
-- The checklists
------------------------------------------------------------

local function section(key) for _, sec in ipairs(m.sections) do if sec.key == key then return sec end end end
local function row(sec, id) for _, r in ipairs(section(sec).rows) do if r.id == id then return r end end end

local spel = row("dungeons", 62031)
eq("Spelunker: 5 of 6", spel.have, 5)
eq("  out of 6", spel.total, 6)
eq("  as text", L.ProgressText(spel), "5/6 \194\183 83%")
eq("  the missing dungeon first", spel.parts[1].text, "Shadowfang Keep")
eq("  then the rest in the game's order", spel.parts[2].text, "Ragefire Chasm or Hall of Thanes")
eq("  and the one left is named", spel.action, "Finish Shadowfang Keep")
eq("  for the whole account", spel.char, "Account")
check("the Lair has no criteria: open, no progress", row("raids", 684).nocrit)
local av = row("pvp", 62046)
check("a reputation is a number, not a checklist", av.numeric)
eq("  0 of 42,000", L.ProgressText(av), "0 / 42,000")
check("  and no 'finish' for it", av.action == nil)
eq("  nor a part list repeating it", #av.parts, 0)
local foh = L.ChallengeRow(s.challenges[63340], "pvp")
check("one plain criterion is the challenge itself: open, no 0/1", foh.nocrit)
check("  no part list and no 'Complete ...' repeating its name", #foh.parts == 0 and foh.action == nil)
check("  and no 'Account', as on the rank rows: nothing to attribute", foh.char == nil)
eq("PvP holds the reputations and the Field of Honor weeks", #section("pvp").rows, 2)

-- The Field of Honor weeks read as one row of steps, as a class reads as one
-- row of levels; each step keeps its own state.
local weeks = row("pvp", "m15620")
check("the Field of Honor weeks are one row", weeks ~= nil and weeks.milestone)
eq("  labelled as the sequence", weeks and weeks.label, "Field of Honor")
eq("  one step per week", weeks and #weeks.steps, 1)
eq("  named short", weeks and weeks.steps[1].short, "Week 4")
check("  not earned", weeks and weeks.steps[1].done == false and weeks.done == false)
eq("the section still counts every challenge", section("pvp").total, 2)
eq("rank names shorten to their number", L.ShortName("Rank 13"), "13")
eq("  week names to the week", L.ShortName("Field of Honor: Week 10"), "Week 10")

-- Several steps, some earned: the row is earned only when all are.
local g = L.GroupMilestones({
    { ch = { cat = 15597, name = "Rank 3", icon = 1 }, done = true },
    { ch = { cat = 15598, name = "Master of Alterac Valley" }, done = false },
    { ch = { cat = 15597, name = "Rank 7" }, done = false },
})
eq("ranks group into one row, in place, around other rows", #g, 2)
eq("  the steps in order", g[1].steps[1].short .. "," .. g[1].steps[2].short, "3,7")
check("  earned, then not", g[1].steps[1].done and not g[1].steps[2].done)
check("  so the row is not earned", g[1].done == false)
eq("  the other row kept after it", g[2].ch.name, "Master of Alterac Valley")
local late = L.GroupMilestones({
    { ch = { cat = 15620, name = "Field of Honor: Week 4" }, done = false },
    { ch = { cat = 15620, name = "Field of Honor: Week 7" }, done = true },
})
check("  a later step earned does not make the row earned", late[1].done == false)

-- Every step inside the width, down to the panel's minimum (Codex on #382:
-- a 426-wide viewport put Rank 14 past the edge).
-- And below it, where the sheet fits a small display (Codex's follow-up: a
-- 768 UI at 1.25 with the full sidebar leaves about 309): the steps wrap
-- under the name rather than run off the edge.
for _, case in ipairs({ { n = 5, minW = 44, label = "5 ranks" }, { n = 3, minW = 84, label = "3 weeks" } }) do
    for _, w in ipairs({ 260, 309, 426, 600, 900 }) do
        local startX = math.floor(w * 0.40)
        local pos, stepW, lines = L.StepLayout(case.n, w, startX, case.minW)
        eq(("%s at %d: every step placed"):format(case.label, w), #pos, case.n)
        local inside, clearOfName, overlap = true, true, false
        for i, p in ipairs(pos) do
            if p.x < 0 or p.x + stepW > w then inside = false end
            if p.line == 0 and p.x < 140 then clearOfName = false end
            for j = i + 1, #pos do
                local q = pos[j]
                if q.line == p.line and math.abs(q.x - p.x) < stepW then overlap = true end
            end
        end
        check(("  each one inside the width (%d wide, %d line(s))"):format(stepW, lines), inside)
        check("  wide enough for its label", stepW >= case.minW)
        check("  clear of the row's name on its line", clearOfName)
        check("  and none on top of another", not overlap)
        if w >= 426 then eq("  on one line where there is room", lines, 1) end
    end
end
local _, _, narrowLines = L.StepLayout(3, 309, 123, 84)
check("at 309 the weeks wrap under the name", narrowLines > 1)
eq("big numbers get commas", L.Number(1234567), "1,234,567")
eq("  small ones none", L.Number(150), "150")
check("no Other section when nothing is left over", section("other") == nil)

-- A closed section says where its progress is.
eq("Dungeons names the challenge being worked on", section("dungeons").focus and section("dungeons").focus.id, 62031)
eq("  with its count", L.FocusText(section("dungeons")), "Novice Spelunker \194\183 5/6 dungeons")
check("Raids, with nothing started, names nothing", section("raids").focus == nil)
eq("  and says nothing", L.FocusText(section("raids")), "")

-- Two columns only for a long list of plain parts in a wide panel.
local plain = {}
for i = 1, 13 do plain[i] = { text = "Boss " .. i, req = 1 } end
eq("13 bosses in a wide panel: two columns", L.CritColumns(plain, 900), 2)
eq("  in a narrow one: one", L.CritColumns(plain, 500), 1)
eq("6 dungeons: one", L.CritColumns(spel.parts, 900), 1)
local counted = {}
for i = 1, 9 do counted[i] = { text = "Part " .. i, q = 1, req = 20 } end
eq("parts with counts keep one, for their numbers", L.CritColumns(counted, 900), 1)

-- Explorer: per character, the most complete one seen.
AltStableLegacyDB = { explore = {
    ["G-hunter"] = { parts = { { name = "Explore Eastern Kingdoms", done = 3, n = 23 },
                               { name = "Explore Kalimdor", done = 1, n = 20 } } },
    ["G-priest"] = { parts = { { name = "Explore Eastern Kingdoms", done = 9, n = 23 },
                               { name = "Explore Kalimdor", done = 4, n = 20 } } },
} }
m = L.Model(s, alts)
local ex = row("adventure", 62382)
check("Explorer is per character", ex.perChar)
eq("  the most complete one named", ex.char, "Karuzo")
eq("  13 of 43 areas", ex.have, 13)
eq("  its continents listed", #ex.parts, 2)
eq("  everyone seen, furthest first", ex.seen and #ex.seen, 2)

-- Earned or not, the tooltip says why a character is named and lists each
-- one seen (Codex on #381: an earned Explorer lost its breakdown).
local function tipHas(lines, word)
    for _, l in ipairs(lines) do
        if tostring(l[1]):find(word, 1, true) or tostring(l[2]):find(word, 1, true) then return true end
    end
    return false
end
local earnedEx = {}
for k, v in pairs(ex) do earnedEx[k] = v end
earnedEx.done = true
earnedEx.ch = { name = "Explorer", date = "2026-11-19" }
local tip = L.RowTooltipLines(earnedEx)
check("an earned Explorer's tooltip says when", tipHas(tip, "Earned on 2026-11-19"))
check("  and still why a character is named", tipHas(tip, "furthest along"))
check("  and each one seen", tipHas(tip, "Karuzo") and tipHas(tip, "13 / 43"))

-- Seen, but nobody has explored anything: no name beside 0 (it would look
-- like a choice).
AltStableLegacyDB.explore = {
    ["G-hunter"] = { parts = { { name = "Explore Eastern Kingdoms", done = 0, n = 23 },
                               { name = "Explore Kalimdor", done = 0, n = 20 } } },
}
local ex0 = L.ChallengeRow(s.challenges[62382], "adventure")
check("nothing explored yet: nobody named", ex0.char == nil)
eq("  but the total is known", ex0.total, 43)
AltStableLegacyDB.explore = {}
local exNone = L.ChallengeRow(s.challenges[62382], "adventure")
check("no character seen: no total either", exNone.char == nil and exNone.total == nil)
eq("  and a dash for progress, not 0/43 or ?", L.ProgressText(exNone), "|cff666666\226\128\148|r")
eq("seen with nothing explored: 0/43 is the fact", L.ProgressText(ex0), "0/43 \194\183 0%")

-- Reading Explore Azeroth keeps this character's.
local me = UnitGUID("player")
L.ReadExplore()
local mine = AltStableLegacyDB.explore[me]
check("this character's exploration is kept", mine ~= nil)
eq("  Eastern Kingdoms 5 of 23", mine and mine.parts[1].done, 5)
eq("  Kalimdor 2 of 20", mine and mine.parts[2].done, 2)

-- A challenge a patch adds, in a category no section claims, still shows.
table.insert(WoW.legacy.categories, { id = 15999, title = "New", ids = { 70000 } })
WoW.legacy.achievements[70000] = { name = "A new challenge", criteria = {} }
WoW.legacy.points[70000] = 1
local mOther = L.Model(L.Read(nil), alts)
local other
for _, sec in ipairs(mOther.sections) do if sec.key == "other" then other = sec end end
check("a challenge no section claims goes to Other", other ~= nil and #other.rows == 1)
table.remove(WoW.legacy.categories)

------------------------------------------------------------
-- The Bucket List (PR 3 of #373)
------------------------------------------------------------

L.state = s
local function alt(name) for _, a in ipairs(alts) do if a.name == name then return a end end end
local hunter25, priest45 = gridID("class", "HUNTER", 25), gridID("class", "PRIEST", 45)
local paladin25, rogue25 = gridID("class", "PALADIN", 25), gridID("class", "ROGUE", 25)
local tailor150, smith150 = gridID("craft", "Tailoring", 150), gridID("craft", "Blacksmithing", 150)

-- Stars, per pool: set A's IDs never mean set B's.
L.ToggleStar(hunter25)
check("a star goes on", L.IsStarred(hunter25))
check("  in the pool read (A)", AltStableLegacyDB.stars.A[hunter25] == true)
check("  and not in the other", L.Stars("B")[hunter25] == nil)
L.ToggleStar(hunter25)
check("  and comes off again", not L.IsStarred(hunter25))
L.StarClick(novMage, true)
check("an earned challenge cannot be put on the list", not L.IsStarred(novMage))
L.Stars()[novMage] = true
L.StarClick(novMage, true)
check("  but one already on it can be taken off", not L.IsStarred(novMage))

-- What's left, in words a player can act on.
local function item(id, me) return L.BucketItem(s.challenges[id], alts, me, s) end
local it = item(hunter25)
eq("Hunter 25: the best hunter", it.char, "Kaleidria")
eq("  21 of 25", it.have .. "/" .. it.need, "21/25")
eq("  what's left", it.left, "Gain 4 levels")
eq("Priest 45: from 30", item(priest45).left, "Gain 15 levels")
eq("Paladin 25, reached and still open: no 'gain 0'", item(paladin25).left, "Reached; the game has not counted it")
eq("Rogue 25 with nobody: says so", item(rogue25).left, "No known rogue")
eq("Tailoring 150: the game's best", item(tailor150).left, "Gain 4 Tailoring skill points")
eq("  the crafter whose skill matches", item(tailor150).char, "Karuzo")
eq("Blacksmithing with nobody", item(smith150).left, "No known smith")
-- The game's figure wins over an alt's stored skill, as in the grid.
local lowTailor = L.BucketItem({ id = tailor150, cat = 15592, name = "Journeyman Tailor", completed = false,
    criteria = { { text = "150 Tailoring Skill", type = 7, q = 140, req = 150 } } }, alts)
eq("the game's best, not an alt's higher stored one", lowTailor.have, 140)
eq("  so nobody matches: crafter unknown", lowTailor.char, "Crafter unknown")
eq("an earned one", item(novMage).left, "Earned")
eq("Spelunker, one dungeon left: named", item(62031).left, "Finish Shadowfang Keep")
eq("  across the account", item(62031).char, "Account")
eq("a reputation: how much is left", item(62046).left, "Gain 42,000 reputation")
eq("  its progress as numbers", L.BucketProgressText(item(62046)), "0 / 42,000")
eq("a challenge with nothing to count: its description", item(684).left, s.challenges[684].desc)
local twoLeft = L.BucketItem({ id = 99, cat = 15593, name = "Test", completed = false, criteria = {
    { text = "A", done = true }, { text = "B", done = false }, { text = "C", done = false } } }, alts)
eq("several dungeons left: counted", twoLeft.left, "2 dungeons left")
AltStableLegacyDB.explore = {
    ["G-priest"] = { parts = { { name = "Explore Eastern Kingdoms", done = 9, n = 23 },
                               { name = "Explore Kalimdor", done = 4, n = 20 } } },
    ["G-hunter"] = { parts = { { name = "Explore Eastern Kingdoms", done = 3, n = 23 },
                               { name = "Explore Kalimdor", done = 0, n = 20 } } },
}
eq("Explorer: the furthest along", item(62382).char, "Karuzo")
eq("  how many areas are left", item(62382).left, "Explore 30 more areas")

-- This character: only what it can advance, with its own progress.
local hunter, priest = alt("Kaleidria"), alt("Karuzo")
check("a priest cannot advance Hunter 25", item(hunter25, priest) == nil)
eq("  but its own class, from its own level", item(priest45, priest).left, "Gain 15 levels")
check("a hunter without Tailoring cannot advance it", item(tailor150, hunter) == nil)
eq("  the priest can, with its own skill", item(tailor150, priest).have, 146)
eq("a dungeon list stays for any character", item(62031, hunter).left, "Finish Shadowfang Keep")
eq("Explorer with the character's own exploration", item(62382, hunter).left, "Explore 40 more areas")
eq("  named as that character", item(62382, hunter).char, "Kaleidria")

-- The list: open ones first, closest to done on top; earned ones last.
local stars = { [hunter25] = true, [priest45] = true, [62031] = true, [novMage] = true, [99999] = true }
local items = L.BucketItems(s, alts, nil, stars)
eq("a star on a challenge the read does not know is left out", #items, 4)
eq("  closest to done first: Hunter 21/25 (84%)", items[1].id, hunter25)
eq("  then Spelunker 5/6 (83%)", items[2].id, 62031)
eq("  then Priest 30/45", items[3].id, priest45)
eq("  the earned one last", items[4].id, novMage)
local mine = L.BucketItems(s, alts, priest, stars)
local ids = {}
for _, x in ipairs(mine) do ids[x.id] = true end
check("This character: the priest's list leaves Hunter 25 out", not ids[hunter25] and ids[priest45] and ids[62031])
check("no read, no rows", #L.BucketItems(nil, alts, nil, stars) == 0)

-- The crafts' best from every tier, as in the grid (Codex on #383): the
-- starred tier's criterion did not read, a sibling's says 146, an alt has 120.
local tierS = { challenges = {}, order = {} }
for _, t in ipairs(D.TIERS.craft) do
    local id = gridID("craft", "Tailoring", t)
    tierS.challenges[id] = { id = id, cat = 15592, name = "Tailoring " .. t, completed = false,
        criteria = t == 225 and { { text = "225 Tailoring Skill", type = 7, q = 146, req = 225 } } or nil }
end
local lowAlts = { { guid = "G-t", name = "Low", class = "MAGE", level = 30, rec = { prof_Tailoring = 120 } } }
local tierItem = L.BucketItem(tierS.challenges[tailor150], lowAlts, nil, tierS)
eq("a tier that did not read takes its sibling's figure", tierItem.have, 146)
eq("  not the alt's stored 120", tierItem.left, "Gain 4 Tailoring skill points")

-- "This character" reads the playing character live (Codex on #383): its
-- saved record says 30 and Tailoring 146; it is now 31 with 148.
AltStableDB[WoW.player.guid] = { name = "Playing", class = "PRIEST", level = 30, scannedHere = true,
                                 prof_Tailoring = 146 }
local liveAlts = L.OwnAlts()
local savedLevel = WoW.level
WoW.level = 31
WoW.skillLines = { { name = "Professions", isHeader = true },
                   { name = "Tailoring", isHeader = false, rank = 148, maxRank = 150, skillID = 197 } }
local live = L.Me(liveAlts)
eq("the playing character's level, live", live.level, 31)
eq("  its skill, live", live.rec.prof_Tailoring, 148)
eq("  so what's left is current", L.BucketItem(s.challenges[priest45], liveAlts, live, s).left, "Gain 14 levels")
WoW.skillLines = {}
eq("a skill list that does not read keeps the saved skill", L.Me(liveAlts).rec.prof_Tailoring, 146)
-- A collapsed Professions header (Codex on #383): the list reads, but without
-- Tailoring, so the saved 146 stays and a starred Tailoring row still shows.
WoW.skillLines = { { name = "Professions", isHeader = true, isCollapsed = true, skillID = 11 },
                   { name = "Secondary Skills", isHeader = true, skillID = 9 },
                   { name = "Cooking", isHeader = false, rank = 40, maxRank = 75, skillID = 185 } }
local collapsedMe = L.Me(liveAlts)
eq("a collapsed Professions header keeps the saved skill", collapsedMe.rec.prof_Tailoring, 146)
check("  the starred Tailoring row stays under This character",
      L.BucketItem(s.challenges[tailor150], liveAlts, collapsedMe, s) ~= nil)
-- Then a gear swap rescans the saved record with the header still collapsed
-- (Codex on #383): the scanner keeps Tailoring, so the row still shows.
AltStable.ScanSkills(AltStableDB[WoW.player.guid])
eq("a rescan under the collapsed header keeps the saved skill", AltStableDB[WoW.player.guid].prof_Tailoring, 146)
local rescanMe = L.Me(L.OwnAlts())
check("  and the starred Tailoring row still shows under This character",
      L.BucketItem(s.challenges[tailor150], L.OwnAlts(), rescanMe, s) ~= nil)
WoW.level = savedLevel
AltStableDB[WoW.player.guid] = nil

-- The full instruction is in the row's tooltip, whatever the column cuts.
local tipItem = item(paladin25)
local tipText = ""
for _, l in ipairs(L.BucketTooltipLines(tipItem)) do tipText = tipText .. l[1] .. " | " end
check("a row's tooltip carries the whole instruction",
      tipText:find("What's left: Reached; the game has not counted it", 1, true) ~= nil, tipText)
check("  and says a right-click has options", tipText:find("Right-click for options.", 1, true) ~= nil, tipText)

-- A right-click opens the row's menu, on the character menu's frame: its
-- name, then Remove (the owner: the only option for now). A left click only
-- opens the row's parts.
local rcStars = L.Stars()
rcStars[62031] = true
local rcItem = item(62031)
L.BucketRowClick(rcItem, "LeftButton")
check("a left click keeps the star", L.IsStarred(62031))
eq("  and opens the row's parts", AltStableLegacyDB.expanded[62031], true)
check("  and opens no menu", not AltStable._test.MenuIsShown())
L.BucketRowClick(rcItem, "RightButton")
check("a right click opens the menu", AltStable._test.MenuIsShown())
check("  and removes nothing yet", L.IsStarred(62031))
eq("  its entries: the challenge, then Remove", table.concat(AltStable._test.MenuLabels(), " | "),
   rcItem.ch.name .. " | Remove from Bucket List")
check("Remove takes it off the Bucket List", AltStable._test.MenuClick("remove") and not L.IsStarred(62031))
check("  and closes the menu", not AltStable._test.MenuIsShown())
L.BucketMenuPick(rcItem, "remove")
check("  a second Remove does not put it back", not L.IsStarred(62031))
rcStars[62031] = true
L.BucketRowClick(rcItem, "RightButton")
AltStable._test.MenuClickOutside()
check("a click outside closes the menu and keeps the star", not AltStable._test.MenuIsShown() and L.IsStarred(62031))
rcStars[62031] = nil
AltStableLegacyDB.expanded[62031] = nil

------------------------------------------------------------
-- The footer
------------------------------------------------------------

local f = L.FooterModel(s)
eq("the footer counts the points", f.points, 5)
eq("  out of the max", f.max, 65)
eq("  the next reward is at 15", f.nextReward and f.nextReward.level, 15)
eq("  its item", f.nextReward and f.nextReward.itemID, 276236)
eq("  10 to go", f.toGo, 10)
s.points = 56
f = L.FooterModel(s)
check("past the last reward, none is next", f.nextReward == nil)
s.points = 5
check("no read: the footer says so", L.FooterModel(nil).unread)

------------------------------------------------------------
-- The tab: the panel, and the totals bar handed over and back
------------------------------------------------------------

local main = CreateFrame("Frame", nil, UIParent)
main.totalsBar = CreateFrame("Frame", nil, main)
main.totalsBar.core = CreateFrame("Frame", nil, main.totalsBar)
main.bodyScroll = CreateFrame("Frame", nil, main)
main.totalsBar:Hide()                     -- as another plugin leaves it

local ok, err = pcall(plugin.OnActivate, main)
check("the tab opens", ok, tostring(err))
check("  the grid it replaces is hidden", not main.bodyScroll:IsShown())
check("  the totals bar is shown", main.totalsBar:IsShown())
check("  with the core's totals hidden", not main.totalsBar.core:IsShown())
check("  and our points in their place", L.foot and L.foot:IsShown())
local text = L.foot and L.foot.left:GetText() or ""
check("  5 / 65 Legacy Points", text:find("5|r |cffaaaaaa/ 65 Legacy Points", 1, true) ~= nil, text)
local right = L.foot and L.foot.reward.text:GetText() or ""
check("  and the points to the next reward", right:find("10 points to go", 1, true) ~= nil, right)
eq("  a tick per reward", L.foot and #L.foot.bar.ticks, 4)

-- The points bar in item-quality stretches (the owner): one per reward, then
-- the rest, Common first. At 5 of 65 with rewards at 15/25/40/55: five
-- stretches, the Common one a third filled, the others not yet.
local segs = L.BarSegments({ points = 5, max = 65, rewards = { { level = 15 }, { level = 25 }, { level = 40 }, { level = 55 } } })
local shape = {}
for _, sg in ipairs(segs) do shape[#shape + 1] = ("%d-%d q%d f%d"):format(sg.from, sg.to, sg.quality, sg.fill) end
eq("the stretches, their qualities and fills", table.concat(shape, ", "),
   "0-15 q1 f5, 15-25 q2 f0, 25-40 q3 f0, 40-55 q4 f0, 55-65 q5 f0")
local later = L.BarSegments({ points = 70, max = 90, rewards = { { level = 15 }, { level = 25 }, { level = 40 },
    { level = 55 }, { level = 65 }, { level = 75 }, { level = 85 } } })
eq("rewards the game adds later add stretches: Artifact, Heirloom, then Heirloom again",
   later[6].quality .. "/" .. later[7].quality .. "/" .. later[8].quality, "6/7/7")
eq("  filled up to the points (70: 5 into 65-75)", later[6].fill .. "/" .. later[7].fill .. "/" .. later[8].fill, "5/0/0")
eq("a last reward at the max adds no empty stretch", #L.BarSegments({ points = 0, max = 55,
   rewards = { { level = 15 }, { level = 55 } } }), 2)
local bar = L.foot.bar
eq("  drawn: one stretch per segment", #bar.segs, 5)
local c = bar.segs[1].fill._vertexColor
eq("  the earned part in Common white, from the gear palette", c and (c[1] .. "," .. c[2] .. "," .. c[3]), "1,1,1")
check("  a stretch not started has no fill", not bar.segs[2].fill:IsShown())
local tr = bar.segs[2].track._colorTexture
eq("  but shows faintly in Uncommon green", tr and (tr[1] .. "," .. tr[2] .. "," .. tr[3]),
   table.concat(AltStable.QUALITY_RGB[2], ","))
local tk = bar.ticks[1]._colorTexture
eq("  a reward not reached: a grey tick", tk and tk[1], 0.8)
local savedModel = L.footModel
L.footModel = { points = 20, max = 65, rewards = savedModel.rewards }
L.PlaceBar()
tk = bar.ticks[1]._colorTexture
eq("  a reward reached: its tick in the colour of the stretch it opens (Uncommon)",
   tk and (tk[1] .. "," .. tk[2] .. "," .. tk[3]), table.concat(AltStable.QUALITY_RGB[2], ","))
check("  and the Uncommon stretch fills", bar.segs[2].fill:IsShown())
L.footModel = { unread = true }
L.PlaceBar()
check("an unread total draws no stretch", not bar.segs[1].track:IsShown() and not bar.segs[1].fill:IsShown())
L.footModel = savedModel
L.PlaceBar()

-- Opening a section draws its rows; collapsing it takes them away again.
AltStableLegacyDB.open = { dungeons = true, raids = true }
AltStableLegacyDB.expanded = { [62031] = true }
ok, err = pcall(L.Render)
check("an open section with an expanded challenge draws", ok, tostring(err))
-- The Bucket List view: drawn, counted on its tab, and remembered.
AltStableLegacyDB.stars = { A = { [gridID("class", "HUNTER", 25)] = true, [62031] = true } }
AltStableLegacyDB.expanded[62031] = true
ok, err = pcall(L.SetView, "bucket")
check("the Bucket List draws", ok, tostring(err))
eq("  the view is remembered", AltStableLegacyDB.view, "bucket")
eq("  its tab counts the stars", L.tabs.bucket.text:GetText(), "Bucket List (2)")
check("  its filter shows on it", L.thisCharCheck:IsShown())
check("  the underline is under it", L.tabs.bucket.sel:IsShown() and not L.tabs.challenges.sel:IsShown())
L.thisCharCheck:SetChecked(true)
ok, err = pcall(L.thisCharCheck:GetScript("OnClick"), L.thisCharCheck)
check("  'This character' draws", ok, tostring(err))
check("  and is remembered", AltStableLegacyDB.thisChar == true)
AltStableLegacyDB.stars = { A = {} }
ok, err = pcall(L.Render)
check("an empty Bucket List draws its hint", ok, tostring(err))
ok, err = pcall(L.tabs.challenges:GetScript("OnClick"))
check("back to Challenges", ok and L.View() == "challenges", tostring(err))
check("  the filter hides there", not L.thisCharCheck:IsShown())
check("  and the view is remembered as Challenges", AltStableLegacyDB.view == nil)

-- A starred grid cell keeps its text clear of the star (owner's screenshot:
-- "150/225" ran under it); an unstarred one centres across the whole cell.
local h25 = gridID("class", "HUNTER", 25)
AltStableLegacyDB.stars = { A = { [h25] = true } }
L.Render()
local starredInset, plainInset
for i = 1, L.pools.gridRow.used do
    for _, b in ipairs(L.pools.gridRow.list[i].cells) do
        local _, _, _, x = b.text:GetPoint(2)
        if b.cell and b.cell.ch and b.cell.ch.id == h25 then starredInset = x
        elseif b.cell and b.cell.ch then plainInset = x end
    end
end
eq("a starred cell's text stops short of the star", starredInset, -12)
eq("  an unstarred cell's spans it", plainInset, 0)

-- Drawn: a starred later tier carries its progress, and both grids' second
-- columns start where the measured names end (the stub measures 40: 28+40+12).
local h45 = gridID("class", "HUNTER", 45)
AltStableLegacyDB.stars = { A = { [h45] = true } }
L.Render()
local laterText
for i = 1, L.pools.gridRow.used do
    for _, b in ipairs(L.pools.gridRow.list[i].cells) do
        if b.cell and b.cell.ch and b.cell.ch.id == h45 then laterText = b.text:GetText() end
    end
end
check("a starred later tier is drawn with its progress", laterText and laterText:find("/45", 1, true) ~= nil, tostring(laterText))
local heads = {}
for i = 1, L.pools.gridHead.used do
    local _, _, _, hx = L.pools.gridHead.list[i].alt:GetPoint(1)
    heads[#heads + 1] = hx
end
eq("  both grids' name columns fit their names", table.concat(heads, ","), "80,80")
AltStableLegacyDB.stars = { A = {} }

-- A Bucket List row listens for the right button too.
L.SetView("bucket")
AltStableLegacyDB.stars = { A = { [62031] = true } }
L.Render()
local clicks = L.pools.bucketRow and L.pools.bucketRow.list[1]._clicks or {}
check("a Bucket List row takes right-clicks", clicks[2] == "RightButtonUp", table.concat(clicks, ","))
L.SetView("challenges")
AltStableLegacyDB.stars = { A = {} }
AltStableLegacyDB.thisChar = nil

check("the table has an opaque backing under glass", L.backing ~= nil
    and (L.backing:IsShown() == (AltStable.SkinIsGlass and AltStable.SkinIsGlass() or false)))

-- Closing the sheet on this tab calls no OnDeactivate: no reading while it
-- is hidden, and a catch-up when it shows again (Codex on #381).
local reads, realRead = 0, L.Read
L.Read = function(...) reads = reads + 1; return realRead(...) end
main:Hide()
check("a closed sheet's tab is not on screen", not L.Visible())
L.RequestRefresh(0)
for _ = 1, 3 do WoW.flushTimers() end
eq("  a refresh asked for meanwhile reads nothing", reads, 0)
check("  but is remembered", L.dirty == true)
main:Show()
eq("  and done when the sheet shows again", reads, 1)
check("  once", not L.dirty)
L.Read = realRead

-- Every refresh re-reads this character's exploration first (Codex on #383:
-- an area explored moves Explorer without an achievement).
local explores, realExplore = 0, L.ReadExplore
L.ReadExplore = function(...) explores = explores + 1; return realExplore(...) end
L.Refresh()
eq("a refresh re-reads the exploration", explores, 1)
main:Hide(); main:Show()
eq("  and so does showing the sheet again on this tab", explores, 2)
L.ReadExplore = realExplore

-- The reward's name, loaded on request, redraws the footer when it arrives.
local evFrame
for _, w in ipairs(WoW.frames) do
    if w._events and w._events.ITEM_DATA_LOAD_RESULT and w._events.CRITERIA_UPDATE then evFrame = w end
end
check("the plugin listens for the item loads it asks for", evFrame ~= nil)
if evFrame then
    local drawn, realFoot = 0, L.RenderFooter
    L.RenderFooter = function() drawn = drawn + 1 end
    L.wantItem = 276236
    local on = evFrame:GetScript("OnEvent")
    on(evFrame, "ITEM_DATA_LOAD_RESULT", 276236, true)
    eq("  a load that succeeded redraws the footer", drawn, 1)
    on(evFrame, "ITEM_DATA_LOAD_RESULT", 276236, false)
    eq("  a failed one does not", drawn, 1)
    on(evFrame, "ITEM_DATA_LOAD_RESULT", 1, true)
    eq("  nor another item's", drawn, 1)
    L.RenderFooter = realFoot
end

ok, err = pcall(plugin.OnDeactivate, main)
check("the tab closes", ok, tostring(err))
check("  the core's totals are back", main.totalsBar.core:IsShown())
check("  ours are gone", not L.foot:IsShown())
check("  and the grid is back", main.bodyScroll:IsShown())

-- No Legacy calls at all (a build without them): nothing to show, no error.
rawset(_G, "C_Traits", nil)
L.state = nil
ok, err = pcall(plugin.OnActivate, main)
check("without the Legacy calls the tab still opens", ok, tostring(err))
check("  and says nothing was read", L.footModel and L.footModel.unread)
eq("  the cells are unknown, not zero", L.CellText(L.model.classes[1].cells[1]), "|cff888888?|r")
pcall(plugin.OnDeactivate, main)

rawset(_G, "C_Traits", savedTraits)
WoW.legacy = nil
WoW.finish("test_legacy", passed, failed)
