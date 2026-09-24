------------------------------------------------------------
-- test_sheetui.lua — the sheet, executed
--
-- SheetUI.lua now BUILDS under tests/wow_stubs.lua: ShowSheet creates its
-- frames and Refresh draws a pass. That matters because the alternative was
-- grepping the source, and a source check cannot see the failure this file
-- exists to catch - a count declared local in one function and read in another
-- compiles as a nil global and errors on every single sheet build, while the
-- text of both lines looks exactly right.
--
-- What the stubs give up, stated plainly: every frame is a table that accepts
-- any call, geometry getters return fixed numbers, and nothing is drawn. So
-- this file asserts VALUES the sheet computes and text it sets, never layout.
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

AltStable, AltStableDB, AltStableConfig = {}, {}, {}
dofile("Compat.lua")
dofile("Theme.lua")
assert(loadfile("Core.lua"))()
dofile("Scanner.lua")
dofile("Reputations.lua")
dofile("Config.lua")
dofile("Toasts.lua")
dofile("Columns.lua")
dofile("RowRenderer.lua")
dofile("SheetUI.lua")

local GOLD = 10000   -- copper per gold

-- Footer text carries colour codes between the numbers and their labels, so
-- "5 avg iLvl" is really "|cffaaaaaa5|r avg iLvl". Strip the markup before
-- asserting, or every check has to know the colours.
local function plain(s)
    if not s then return nil end
    return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""))
end

local function build(db)
    AltStableDB = db
    local ok, err = pcall(AltStable.ShowSheet)
    check("the sheet builds", ok, tostring(err))
    if ok then
        local ok2, err2 = pcall(AltStable.RefreshSheet)
        check("  and refreshes", ok2, tostring(err2))
    end
    return plain(AltStable._test.FooterText())
end

------------------------------------------------------------
-- The footer totals
------------------------------------------------------------

local footer = build({
    a = { guid = "a", name = "Rich", class = "MAGE", realm = "R", level = 60,
          ilvl = 66, money = 123 * GOLD, lastUpdate = 1 },
    b = { guid = "b", name = "Poor", class = "ROGUE", realm = "R", level = 40,
          ilvl = 40, money = 7 * GOLD, lastUpdate = 1 },
})
check("the footer says something", footer ~= nil and #footer > 0, tostring(footer))
if footer then
    check("it counts the characters", footer:find("2", 1, true) ~= nil, footer)
    check("it totals the levels", footer:find("100", 1, true) ~= nil, footer)
    check("it totals the gold", footer:find("130", 1, true) ~= nil, footer)
    check("  with no unknown marker when every character has money",
          footer:find("unknown", 1, true) == nil, footer)
end

------------------------------------------------------------
-- Money that cannot be read (#49)
------------------------------------------------------------
-- On the measured PvP realm GetMoney returns a secret value, so the scan stores
-- nothing and the field is absent. Counting that as zero would present the sum
-- as the whole account's gold while quietly leaving a character out.

footer = build({
    a = { guid = "a", name = "Rich", class = "MAGE", realm = "R", level = 60,
          ilvl = 66, money = 123 * GOLD, lastUpdate = 1 },
    b = { guid = "b", name = "Secretive", class = "ROGUE", realm = "R", level = 40,
          ilvl = 40, lastUpdate = 1 },   -- no money field at all
})
if footer then
    check("the total still shows the gold it does know", footer:find("123", 1, true) ~= nil, footer)
    check("  and says one character is unknown", footer:find("(1 unknown)", 1, true) ~= nil, footer)
end

footer = build({
    a = { guid = "a", name = "One", class = "MAGE", realm = "R", level = 1, lastUpdate = 1 },
    b = { guid = "b", name = "Two", class = "ROGUE", realm = "R", level = 1, lastUpdate = 1 },
})
if footer then
    check("two unknown characters are both counted", footer:find("(2 unknown)", 1, true) ~= nil, footer)
end

------------------------------------------------------------
-- The average item level is rounded, like the column (#39)
------------------------------------------------------------

footer = build({
    a = { guid = "a", name = "A", class = "MAGE", realm = "R", level = 60, ilvl = 4.5,
          money = 0, lastUpdate = 1 },
    b = { guid = "b", name = "B", class = "ROGUE", realm = "R", level = 60, ilvl = 4.5,
          money = 0, lastUpdate = 1 },
})
if footer then
    check("the footer average is a whole number", footer:find("5 avg iLvl", 1, true) ~= nil, footer)
    check("  not one decimal place", footer:find("4.5 avg", 1, true) == nil, footer)
end

print(("test_sheetui: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
