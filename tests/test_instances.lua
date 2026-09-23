------------------------------------------------------------
-- test_instances.lua — the Raids plugin (#11)
--
-- Vanilla raids only: the nine Outland raids the TBC plugin carried do not
-- exist here, and a group header renders even with no rows under it.
--
-- AGGREGATE PROGRESS ONLY. The core stores a per-encounter killmask
-- (si_boss_<name>@<diff>), but mapping bit e-1 onto a static boss-name list
-- assumes Forever orders encounters as TBC did, and no raid lockout is
-- obtainable on the beta to check that (#17). So this plugin reads the mask
-- for nothing: a wrong name looks like data, while "3/10" cannot be wrong.
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
dofile("Plugins/Instances/AltStableInstances.lua")
WoW.flushTimers()

local plugin
for _, p in ipairs(AltStable.plugins or {}) do if p.id == "instances" then plugin = p end end
check("the plugin registers itself with the core", plugin ~= nil)
if not plugin then
    print(("test_instances: %d passed, %d failed"):format(passed, failed + 1))
    os.exit(1)
end
local T = plugin._test

------------------------------------------------------------
-- The catalogue
------------------------------------------------------------

local byName = {}
for _, r in ipairs(T.RAIDS) do byName[r.apiName] = r end
eq("seven raids", #T.RAIDS, 7)
for _, name in ipairs({ "Molten Core", "Onyxia's Lair", "Blackwing Lair", "Zul'Gurub",
                        "Ruins of Ahn'Qiraj", "Temple of Ahn'Qiraj", "Naxxramas" }) do
    check(name .. " is in the catalogue", byName[name] ~= nil)
end
for _, name in ipairs({ "Karazhan", "Gruul's Lair", "Serpentshrine Cavern", "Black Temple",
                        "Zul'Aman", "Sunwell Plateau", "Hyjal Summit", "Tempest Keep",
                        "Magtheridon's Lair" }) do
    check("no " .. name .. " (Outland)", byName[name] == nil)
end
do
    local named = nil
    for _, r in ipairs(T.RAIDS) do if r.bosses then named = r.apiName end end
    check("no raid carries a boss-name list (#17)", named == nil, tostring(named))
end

------------------------------------------------------------
-- Matching a live lockout name to a row
------------------------------------------------------------

eq("an exact name matches", T.matchRaid("molten core") and T.matchRaid("molten core").apiName, "Molten Core")
eq("a prefixed name still binds", T.matchRaid("blackrock depths: blackwing lair")
   and T.matchRaid("blackrock depths: blackwing lair").apiName, "Blackwing Lair")
eq("an alias binds", T.matchRaid("ahn'qiraj temple") and T.matchRaid("ahn'qiraj temple").apiName,
   "Temple of Ahn'Qiraj")
eq("an unknown raid matches nothing", T.matchRaid("karazhan"), nil)

------------------------------------------------------------
-- Parsing what the core stored
------------------------------------------------------------

local lk = T.parseLockout("si_Molten Core@1", "1700086400|7|10|40|Normal")
check("a lockout parses", lk ~= nil)
eq("  name", lk and lk.name, "Molten Core")
eq("  progress", lk and lk.prog, 7)
eq("  total", lk and lk.total, 10)
eq("  raid size", lk and lk.size, 40)
eq("  difficulty name", lk and lk.diffName, "Normal")
eq("a killmask value is not a lockout", T.parseLockout("si_boss_Molten Core@1", "5"), nil)
eq("a non-si_ field is not a lockout", T.parseLockout("prof_Mining", "300|1|2|3|x"), nil)

------------------------------------------------------------
-- Formatting the reset column
------------------------------------------------------------

eq("a lockout already past reads now", T.fmtDur(-5), "now")
eq("minutes", T.fmtDur(90 * 60), "1h 30m")
eq("hours and minutes", T.fmtDur(3600 + 120), "1h 2m")
eq("days and hours", T.fmtDur(2 * 86400 + 4 * 3600), "2d 4h")
eq("a reset moment reads as a weekday and time", T.resetLabel(1700000000), "Tue 22:13")

local function firstOf(...) return (select(1, ...)) end
check("a lockout resetting within 12h is red", firstOf(T.resetColor(3600)) == 1.00)
check("  within two days, amber", select(2, T.resetColor(30 * 3600)) == 0.82)
check("  further out, green", firstOf(T.resetColor(5 * 86400)) == 0.52)

------------------------------------------------------------
-- Names in the column headers
------------------------------------------------------------

-- Forever gives every character a surname, and first names are not unique, so
-- the header shows the first name rather than a byte-truncated full name.
eq("the first name is what fits a 58px column", T.shortName("Kaleid Sumner", 9), "Kaleid")
eq("a long first name is cut", T.shortName("Bartholomew Smith", 9), "Bartholom")
eq("a short one is left alone", T.shortName("Ash Grey", 9), "Ash")
eq("a missing name is not an error", T.shortName(nil, 9), "?")

-- First names are not unique here, so two "Kaleid" columns would be useless:
-- the surname initial is added only where the shown names would collide.
do
    local names = T.headerNames({ { name = "Kaleid Sumner" }, { name = "Kaleid Thorne" },
                                  { name = "Ash Grey" } }, 9)
    eq("a collision gets the surname initial", names[1], "Kaleid S")
    eq("  for both of them", names[2], "Kaleid T")
    eq("a name that does not collide is left alone", names[3], "Ash")
    local solo = T.headerNames({ { name = "Kaleid Sumner" } }, 9)
    eq("one character needs no initial", solo[1], "Kaleid")
    local nosur = T.headerNames({ { name = "Kaleid" }, { name = "Kaleid" } }, 9)
    eq("two identical names stay identical - nothing distinguishes them", nosur[1], "Kaleid")
end
-- "Ceridwen" with an accented e (2 bytes): cutting at 9 bytes would split it.
local accented = "Cerid" .. string.char(0xC3, 0xA9) .. "wen"
local cut = T.shortName(accented, 6)
check("a multibyte character is never cut in half", cut == "Cerid" or cut == "Cerid" .. string.char(0xC3, 0xA9),
      cut)

------------------------------------------------------------
-- The read model
------------------------------------------------------------

WoW.reset()
AltStableDB = {
    ["Player-A-1"] = { guid = "Player-A-1", name = "Raider", class = "WARRIOR", level = 60, ilvl = 66,
                       ["si_Molten Core@1"] = "1700086400|7|10|40|Normal",
                       ["si_boss_Molten Core@1"] = "127",
                       ["si_Onyxia's Lair@1"] = "1700086400|1|1|40|Normal" },
    ["Player-B-1"] = { guid = "Player-B-1", name = "Alt", class = "MAGE", level = 60, ilvl = 60 },
    ["Player-C-1"] = { guid = "Player-C-1", name = "Leveller", class = "ROGUE", level = 22, ilvl = 20 },
    ["Player-D-1"] = { guid = "Player-D-1", name = "Saved Low", class = "PRIEST", level = 30, ilvl = 25,
                       ["si_Zul'Gurub@1"] = "1700086400|2|8|20|Normal" },
}
local allChars, lookup = T.gather()
eq("every character is a candidate column", #allChars, 4)
check("a saved character has its lockouts", lookup["Player-A-1"] ~= nil)
eq("  keyed by the canonical raid name", lookup["Player-A-1"]["molten core"].prog, 7)
eq("  a second lockout too", lookup["Player-A-1"]["onyxia's lair"].total, 1)
check("an unsaved character has none", lookup["Player-B-1"] == nil)
eq("the killmask is not read into the model (#17)", lookup["Player-A-1"]["molten core"].mask, nil)

-- Two lockouts for the same raid at different difficulties: one row, one rule.
-- Without it, pairs() order decides, and it can change between refreshes.
do
    local a = { expires = 100, prog = 3, diff = 1 }
    local b = { expires = 200, prog = 1, diff = 2 }
    eq("the later reset wins", T.PreferLockout(a, b), b)
    eq("  whichever order they arrive in", T.PreferLockout(b, a), b)
    local c = { expires = 100, prog = 5, diff = 2 }
    eq("same reset: more progress wins", T.PreferLockout(a, c), c)
    local d = { expires = 100, prog = 3, diff = 3 }
    eq("same reset and progress: the lower difficulty", T.PreferLockout(a, d), a)
    eq("nothing to compare against", T.PreferLockout(nil, a), a)
end

-- ...and gather applies it: the core stores one field per difficulty, the grid
-- has one row per raid.
do
    AltStableDB["Player-Two-1"] = { guid = "Player-Two-1", name = "Twice", class = "MAGE", level = 60,
                                    ["si_Naxxramas@1"] = "1700086400|3|15|40|Normal",
                                    ["si_Naxxramas@2"] = "1700172800|1|15|40|Heroic" }
    local _, lk2 = T.gather()
    local kept = lk2["Player-Two-1"]["naxxramas"]
    eq("two difficulties collapse to the later reset", kept.expires, 1700172800)
    eq("  deterministically, not whichever pairs() saw last", kept.prog, 1)
    AltStableDB["Player-Two-1"] = nil
end

-- An expired lockout is not a lockout: left in the model it would keep a
-- low-level character in the columns, and an unknown raid in the Other rows,
-- showing nothing but dashes.
do
    AltStableDB["Player-Old-1"] = { guid = "Player-Old-1", name = "Lapsed", class = "MAGE", level = 30,
                                    ["si_Molten Core@1"] = (WoW.now - 60) .. "|7|10|40|Normal" }
    local chars3, lk4 = T.gather()
    eq("an expired lockout is dropped", lk4["Player-Old-1"], nil)
    local cols3 = T.columnsForView(chars3, lk4)
    local kept3 = false
    for _, c in ipairs(cols3) do if c.guid == "Player-Old-1" then kept3 = true end end
    check("  and stops holding a column open", not kept3)
    AltStableDB["Player-Old-1"] = nil
end

-- An open tab drops a save when it expires, without waiting for a scan.
do
    WoW.timers = {}
    T.ScheduleExpiryRefresh({ a = { mc = { expires = WoW.now + 600 } },
                              b = { zg = { expires = WoW.now + 120 } } })
    eq("a refresh is scheduled", #WoW.timers, 1)
    check("  at the soonest expiry", WoW.timers[1].delay >= 120 and WoW.timers[1].delay <= 122,
          tostring(WoW.timers[1].delay))
    WoW.timers = {}
    T.ScheduleExpiryRefresh({})
    eq("nothing to expire, nothing scheduled", #WoW.timers, 0)
end

-- The footer counts tracked characters, not visible columns (UI code, so this
-- reads the source).
do
    local src = io.open("Plugins/Instances/AltStableInstances.lua"):read("*a")
    local stats = src:match("statsFS:SetText%((.-)%)%s*" .. "statsBar:Show")
    -- The call site, not the definition: "ScheduleExpiryRefresh(lookup)" also
    -- matches "local function ScheduleExpiryRefresh(lookup)".
    local refreshBody = src:match("function AT_SI.Refresh%(%)(.-)\nend")
    check("a refresh schedules the next expiry",
          refreshBody ~= nil and refreshBody:find("ScheduleExpiryRefresh(lookup)", 1, true) ~= nil)
    check("the footer frame gets the backdrop template its theming needs",
          src:find('statsBar = CreateFrame("Frame", nil, panel, "BackdropTemplate")', 1, true) ~= nil)
    check("the footer reports #allChars as tracked",
          stats ~= nil and stats:find("#allChars", 1, true) ~= nil, tostring(stats))
end

local cols = T.columnsForView(allChars, lookup)
local names = {}
for _, c in ipairs(cols) do names[#names + 1] = c.name end
eq("columns: level 60s plus anyone saved", table.concat(names, ","), "Raider,Alt,Saved Low")
check("a low-level character with no lockout is left out",
      not table.concat(names, ","):find("Leveller", 1, true))

local rows = T.buildDisplayRows(lookup)
local groups, raidRows = 0, 0
for _, r in ipairs(rows) do
    if r.isGroup then groups = groups + 1 else raidRows = raidRows + 1 end
end
eq("one group header", groups, 1)
eq("  with every raid under it", raidRows, 7)

-- The column cap must not drop a saved character: they sort last (low level),
-- so a plain truncation would cut exactly the ones the filter exists to keep.
do
    local many, look = {}, { ["Player-Saved-1"] = { ["zul'gurub"] = { prog = 1 } } }
    many[1] = { guid = "Player-Saved-1", name = "Bank Alt", level = 30, ilvl = 20 }
    for i = 1, 60 do
        many[#many + 1] = { guid = "Player-F-" .. i, name = "Filler" .. i, level = 60, ilvl = 100 }
    end
    local capped = T.columnsForView(many, look)
    eq("columns are capped", #capped, 40)
    local kept = false
    for _, c in ipairs(capped) do if c.guid == "Player-Saved-1" then kept = true end end
    check("the saved low-level character survives the cap", kept)
end

-- A lockout the catalogue doesn't know still shows, under "Other".
AltStableDB["Player-E-1"] = { guid = "Player-E-1", name = "Explorer", class = "DRUID", level = 60,
                              ["si_Some New Raid@1"] = "1700086400|1|5|20|Normal" }
local _, lookup2 = T.gather()
local rows2 = T.buildDisplayRows(lookup2)
local other, otherRow = false, nil
for _, r in ipairs(rows2) do
    if r.isGroup and r.key == "other" then other = true end
    if r.raid and r.raid.isOther then otherRow = r.raid.display end
end
check("an unknown lockout gets an Other group", other)
eq("  and its own row", otherRow, "Some New Raid")

-- Those rows are sorted and bounded: the panel has no vertical scroller, so an
-- unbounded list would run under the stats bar with no way to reach it.
do
    AltStableDB = { ["Player-F-1"] = { guid = "Player-F-1", name = "Finder", class = "MAGE", level = 60 } }
    for i = 1, 14 do
        AltStableDB["Player-F-1"]["si_Zone " .. string.char(90 - i) .. "@1"] = "1700086400|1|5|20|Normal"
    end
    local _, lk3 = T.gather()
    local rows3 = T.buildDisplayRows(lk3)
    local others, label = {}, nil
    for _, r in ipairs(rows3) do
        if r.isGroup and r.key == "other" then label = r.label end
        if r.raid and r.raid.isOther then others[#others + 1] = r.raid.display end
    end
    eq("the Other rows are bounded", #others, 10)
    check("  the header says how many there are", label and label:find("10 of 14", 1, true) ~= nil, label)
    local sorted = true
    for i = 2, #others do if others[i - 1] > others[i] then sorted = false end end
    check("  and they are in a stable, sorted order", sorted, table.concat(others, ","))
end

-- Collapsing hides a group's rows, and the state is remembered.
T.toggleCollapse("vanilla")
check("a collapsed group is remembered", T.isCollapsed("vanilla"))
local collapsed = T.buildDisplayRows(lookup)
local shown = 0
for _, r in ipairs(collapsed) do if not r.isGroup then shown = shown + 1 end end
eq("  and its raids are hidden", shown, 0)
T.toggleCollapse("vanilla")
check("expanding brings them back", not T.isCollapsed("vanilla"))

print(("test_instances: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
