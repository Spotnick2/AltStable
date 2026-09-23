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

local lk = T.parseLockout("si_Molten Core@1", "1700000000|7|10|40|Normal")
check("a lockout parses", lk ~= nil)
eq("  name", lk and lk.name, "Molten Core")
eq("  progress", lk and lk.prog, 7)
eq("  total", lk and lk.total, 10)
eq("  raid size", lk and lk.size, 40)
eq("  difficulty name", lk and lk.diffName, "Normal")
eq("a killmask value is not a lockout", T.parseLockout("si_boss_Molten Core@1", "5"), nil)
eq("a non-si_ field is not a lockout", T.parseLockout("prof_Mining", "300|1|2|3|x"), nil)

------------------------------------------------------------
-- The read model
------------------------------------------------------------

WoW.reset()
AltStableDB = {
    ["Player-A-1"] = { guid = "Player-A-1", name = "Raider", class = "WARRIOR", level = 60, ilvl = 66,
                       ["si_Molten Core@1"] = "1700000000|7|10|40|Normal",
                       ["si_boss_Molten Core@1"] = "127",
                       ["si_Onyxia's Lair@1"] = "1700000000|1|1|40|Normal" },
    ["Player-B-1"] = { guid = "Player-B-1", name = "Alt", class = "MAGE", level = 60, ilvl = 60 },
    ["Player-C-1"] = { guid = "Player-C-1", name = "Leveller", class = "ROGUE", level = 22, ilvl = 20 },
    ["Player-D-1"] = { guid = "Player-D-1", name = "Saved Low", class = "PRIEST", level = 30, ilvl = 25,
                       ["si_Zul'Gurub@1"] = "1700000000|2|8|20|Normal" },
}
local allChars, lookup = T.gather()
eq("every character is a candidate column", #allChars, 4)
check("a saved character has its lockouts", lookup["Player-A-1"] ~= nil)
eq("  keyed by the canonical raid name", lookup["Player-A-1"]["molten core"].prog, 7)
eq("  a second lockout too", lookup["Player-A-1"]["onyxia's lair"].total, 1)
check("an unsaved character has none", lookup["Player-B-1"] == nil)
eq("the killmask is not read into the model (#17)", lookup["Player-A-1"]["molten core"].mask, nil)

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

-- A lockout the catalogue doesn't know still shows, under "Other".
AltStableDB["Player-E-1"] = { guid = "Player-E-1", name = "Explorer", class = "DRUID", level = 60,
                              ["si_Some New Raid@1"] = "1700000000|1|5|20|Normal" }
local _, lookup2 = T.gather()
local rows2 = T.buildDisplayRows(lookup2)
local other, otherRow = false, nil
for _, r in ipairs(rows2) do
    if r.isGroup and r.key == "other" then other = true end
    if r.raid and r.raid.isOther then otherRow = r.raid.display end
end
check("an unknown lockout gets an Other group", other)
eq("  and its own row", otherRow, "Some New Raid")

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
