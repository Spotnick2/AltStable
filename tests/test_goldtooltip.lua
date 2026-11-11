------------------------------------------------------------
-- test_goldtooltip.lua - every character's gold on the bags' money (#305)
--
-- Pinned: the hook lands on the coin buttons of the bag money frames that
-- exist, once, at login; hovering shows the total and one line per character,
-- richest first; the numbers agree with the sheet's footer (CharacterTotals),
-- so hidden characters are left out and unreadable money is "?" with the total
-- saying it is partial; leaving hides it.
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
assert(loadfile("Core.lua"))()
dofile("Config.lua")
AltStable.FormatMoney = function(c) return "m" .. tostring(c) end

-- Blizzard's bag money frames, shaped as ContainerMoneyFrameTemplate: the
-- frame and its three coin buttons.
local function moneyFrame()
    local mf = WoW.makeFrame("Frame")
    for _, k in ipairs({ "GoldButton", "SilverButton", "CopperButton" }) do
        mf[k] = WoW.makeFrame("Button", mf)
    end
    return mf
end
ContainerFrame1 = WoW.makeFrame("Frame")
ContainerFrame1.MoneyFrame = moneyFrame()
ContainerFrameCombinedBags = WoW.makeFrame("Frame")
ContainerFrameCombinedBags.MoneyFrame = moneyFrame()

dofile("GoldTooltip.lua")

------------------------------------------------------------
-- The hook
------------------------------------------------------------

local gold = ContainerFrame1.MoneyFrame.GoldButton
check("nothing is hooked before login", gold._hook_OnEnter == nil)
WoW.fire("PLAYER_LOGIN")
check("at login the backpack's gold button is hooked", gold._hook_OnEnter ~= nil)
check("  and its copper button", ContainerFrame1.MoneyFrame.CopperButton._hook_OnEnter ~= nil)
check("  and the combined bags' silver button",
      ContainerFrameCombinedBags.MoneyFrame.SilverButton._hook_OnEnter ~= nil)
check("  with a leave that hides it", gold._hook_OnLeave ~= nil)
eq("installing again hooks nothing twice", AltStable.InstallGoldTooltip(), 0)

-- A client without one of the frames: the other is still hooked, nothing throws.
local held = ContainerFrameCombinedBags
ContainerFrameCombinedBags = nil
ContainerFrame1.MoneyFrame = moneyFrame()
local ok, n = pcall(AltStable.InstallGoldTooltip)
check("a missing frame is skipped, not an error", ok and n == 1, tostring(n))
ContainerFrameCombinedBags = held

------------------------------------------------------------
-- What it shows
------------------------------------------------------------

local function hover(button)
    GameTooltip:ClearLines()
    button:GetScript("OnEnter")(button)
    return WoW.tooltipLines
end

AltStableConfig.hiddenCharacters = {}
AltStableDB = {
    a = { guid = "a", name = "Poor",   class = "MAGE",    money = 50 },
    b = { guid = "b", name = "Rich",   class = "PRIEST",  money = 900000 },
    c = { guid = "c", name = "Middle", class = "WARRIOR", money = 20000 },
    d = { guid = "d", name = "Gone",   class = "ROGUE",   money = 777 },
    e = { guid = "e", name = "Secret", class = "DRUID",   money = WoW.secret(5) },
}
AltStableConfig.hiddenCharacters.d = true

gold = ContainerFrame1.MoneyFrame.GoldButton
local lines = hover(gold)
check("hovering the gold shows the tooltip", WoW.tooltipShown == true)
eq("  owned by the button", WoW.tooltipOwner, gold)
local t = AltStable.CharacterTotals()
eq("the first line is the footer's total", lines[1], "Gold on all characters|m" .. t.money)
eq("  which is the readable, shown characters' sum", t.money, 900000 + 20000 + 50)
local order = {}
for _, l in ipairs(lines) do
    local name = l:match("(%a+)|m%d+$") or l:match("(%a+)|%?$")
    if name and name ~= "characters" then order[#order + 1] = name end
end
eq("one line per character, richest first, unreadable last",
   table.concat(order, ","), "Rich,Middle,Poor,Secret")
local all = table.concat(lines, "\n")
check("  a hidden character is left out", not all:find("Gone", 1, true))
check("  and the tooltip says one was", all:find("1 hidden character left out.", 1, true) ~= nil, all)
check("  unreadable gold is '?', and the total says it is partial",
      all:find("leaves out 1 character whose gold can't be read", 1, true) ~= nil, all)

-- Nothing unreadable, nothing hidden: no notes at all.
AltStableConfig.hiddenCharacters = {}
AltStableDB.e = nil
lines = hover(gold)
all = table.concat(lines, "\n")
check("with nothing left out, no note", not all:find("left out", 1, true) and not all:find("leaves out", 1, true), all)
eq("  and the total counts the formerly hidden one", lines[1], "Gold on all characters|m" .. (900000 + 20000 + 50 + 777))

-- Two characters with the same gold: by name, so the order never jumps.
AltStableDB = {
    x = { guid = "x", name = "Zed", class = "MAGE", money = 10 },
    y = { guid = "y", name = "Abe", class = "MAGE", money = 10 },
}
local _, rows = AltStable.GoldTooltipRows()
eq("equal gold sorts by name", rows[1].name .. "," .. rows[2].name, "Abe,Zed")

-- No characters at all (a fresh install before the first scan): no tooltip.
AltStableDB = {}
WoW.tooltipShown = false
hover(gold)
eq("with no characters, nothing is shown", WoW.tooltipShown, false)

-- Leaving hides it.
AltStableDB = { x = { guid = "x", name = "Zed", class = "MAGE", money = 10 } }
hover(gold)
gold:GetScript("OnLeave")(gold)
eq("leaving the button hides it", WoW.tooltipShown, false)

WoW.finish("test_goldtooltip", passed, failed)
