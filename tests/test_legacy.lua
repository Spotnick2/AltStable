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
dofile("tests/libglass.lua"); LoadGlass("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")

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
    for _, id in ipairs({ 62031, 684, 62046, 62382, 62054 }) do points[id] = 1 end
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
eq("  the 45 milestones and 5 checklists, not the pointless one", s and #s.order, 50)
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
eq("  0 of 42000", L.ProgressText(av), "0 / 42000")
check("  and no 'finish' for it", av.action == nil)
eq("PvP holds the battleground reputations", #section("pvp").rows, 1)
check("no Other section when nothing is left over", section("other") == nil)

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

-- Opening a section draws its rows; collapsing it takes them away again.
AltStableLegacyDB.open = { dungeons = true }
L.expanded[62031] = true
ok, err = pcall(L.Render)
check("an open section with an expanded challenge draws", ok, tostring(err))

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
