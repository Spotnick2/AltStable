------------------------------------------------------------
-- test_broker.lua - AltStable as a LibDataBroker data source (#466)
--
-- Pinned, against the REAL CallbackHandler-1.0 and LibDataBroker-1.1 files
-- bundled under Libs/: one "data source" named AltStable; its text is the
-- sheet footer's gold (hidden left out, unreadable never counted as 0), "?"
-- before login and when nothing is readable; it follows a refresh and a coin
-- looted on the next frame, as LibDataBroker's change event shows a display;
-- the clicks are the minimap button's; the tooltip is written into the one the
-- display hands over, never owned or shown here; a taken name or a missing
-- library leaves no broker and no error.
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

-- The sheet, reduced: PublicAPI.lua wraps RefreshSheet and ScanCharacter at
-- load, so they exist first, as in the TOC.
local toggles, configs = 0, 0
AltStable.RefreshSheet = function() end
AltStable.ScanCharacter = function() end
AltStable.ShowSheet = function() toggles = toggles + 1 end
AltStable.OpenConfig = function() configs = configs + 1 end

-- The TOC's order: the libraries, then GoldTooltip, PublicAPI, Broker.
dofile("Libs/LibStub/LibStub.lua")
dofile("Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua")
dofile("Libs/LibDataBroker-1.1/LibDataBroker-1.1.lua")
dofile("GoldTooltip.lua")
dofile("PublicAPI.lua")
dofile("Broker.lua")

local LDB = LibStub("LibDataBroker-1.1")
local obj = LDB:GetDataObjectByName("AltStable")

-- What a display hears: LibDataBroker's own change event for the text.
local heard = {}
local display = {}
LDB.RegisterCallback(display, "LibDataBroker_AttributeChanged_AltStable_text",
    function(_, _, _, value) heard[#heard + 1] = value end)

------------------------------------------------------------
-- The object
------------------------------------------------------------

check("a data object named AltStable exists", obj ~= nil)
eq("  it is the one Broker.lua made", obj, AltStable._test.broker.object)
eq("  a data source", obj.type, "data source")
eq("  labelled AltStable", obj.label, "AltStable")
eq("  with the TOC's icon", obj.icon, 8197123)
eq("  and a text from the start", obj.text, "?")

------------------------------------------------------------
-- The text
------------------------------------------------------------

local ME = UnitGUID("player")
AltStableConfig.hiddenCharacters = {}
AltStableDB = {
    [ME] = { guid = ME, name = "Me",   class = "PRIEST", money = 1000 },
    b    = { guid = "b", name = "Rich", class = "MAGE",   money = 500000 },
    c    = { guid = "c", name = "Gone", class = "ROGUE",  money = 777 },
}
AltStableConfig.hiddenCharacters.c = true

eq("before login it is still the placeholder", obj.text, "?")
WoW.fire("PLAYER_LOGIN")
eq("at login: the saved characters' gold, the hidden one left out", obj.text, "m501000")
eq("  the footer's own figure", obj.text, "m" .. AltStable.CharacterTotals().money)
eq("  and a display heard it", heard[#heard], "m501000")

-- A refresh (a sync landing, forgetting, ...): repainted on the next frame.
AltStableDB.b.money = 600000
AltStable.RefreshSheet()
eq("a refresh does not repaint in the same frame", obj.text, "m501000")
WoW.flushTimers()
eq("  but on the next one", obj.text, "m601000")
eq("  and a display heard it", heard[#heard], "m601000")

-- A coin looted: Core's PLAYER_MONEY writes the money and refreshes.
local realGetMoney = GetMoney
GetMoney = function() return 2500 end
WoW.fire("PLAYER_MONEY")
WoW.flushTimers()
GetMoney = realGetMoney
eq("a coin looted moves the text", obj.text, "m602500")

-- Nothing changed: LibDataBroker keeps quiet.
local before = #heard
AltStable._test.broker.update()
eq("an unchanged total fires no change", #heard, before)

-- Some gold unreadable (a secret value): the readable sum, marked partial.
AltStableDB.b.money = WoW.secret(5)
AltStable._test.broker.update()
eq("partly unreadable: the readable sum and a ?", obj.text, "m2500 ?")

-- Nothing readable: unknown, never 0.
AltStableDB[ME].money = nil
AltStable._test.broker.update()
eq("nothing readable is ?", obj.text, "?")

-- A real zero reads as one.
AltStableDB = { [ME] = { guid = ME, name = "Me", class = "PRIEST", money = 0 } }
AltStable._test.broker.update()
eq("a known zero is 0, not ?", obj.text, "m0")

-- Everyone hidden: nothing counted.
AltStableConfig.hiddenCharacters[ME] = true
AltStable._test.broker.update()
eq("everyone hidden is ?", obj.text, "?")
AltStableConfig.hiddenCharacters = {}

------------------------------------------------------------
-- The clicks
------------------------------------------------------------

obj.OnClick(nil, "LeftButton")
eq("left-click toggles the sheet", toggles, 1)
obj.OnClick(nil, "RightButton")
eq("right-click opens Options", configs, 1)
obj.OnClick(nil, "MiddleButton")
check("another button does nothing", toggles == 1 and configs == 1)

------------------------------------------------------------
-- The tooltip
------------------------------------------------------------

-- The display's tooltip: it owns and shows it, so neither may happen here.
local function displayTooltip()
    local tt = { lines = {}, owned = false, shown = false }
    function tt:AddLine(text) self.lines[#self.lines + 1] = tostring(text) end
    function tt:AddDoubleLine(l, r) self.lines[#self.lines + 1] = tostring(l) .. "|" .. tostring(r) end
    function tt:SetOwner() self.owned = true end
    function tt:Show() self.shown = true end
    return tt
end

AltStableDB = {
    [ME] = { guid = ME, name = "Me",   class = "PRIEST", money = 1000 },
    b    = { guid = "b", name = "Rich", class = "MAGE",   money = 500000 },
}
local tt = displayTooltip()
WoW.tooltipLines = {}
obj.OnTooltipShow(tt)
local all = table.concat(tt.lines, "\n")
eq("the tooltip opens with the addon's name", tt.lines[1], "AltStable")
eq("  then the bag tooltip's total", tt.lines[2], "Gold on all characters|m501000")
check("  one line per character, richest first",
      all:find("Rich|m500000", 1, true) and all:find("Me|m1000", 1, true)
      and all:find("Rich", 1, true) < all:find("Me|", 1, true), all)
check("  the left-click hint", all:find("Left-click: open or close AltStable", 1, true) ~= nil, all)
check("  the right-click hint", all:find("Right-click: options", 1, true) ~= nil, all)
check("  never owned here", not tt.owned)
check("  never shown here", not tt.shown)
eq("  and GameTooltip untouched", #WoW.tooltipLines, 0)

AltStableDB = {}
tt = displayTooltip()
obj.OnTooltipShow(tt)
all = table.concat(tt.lines, "\n")
check("no characters: one grey line instead", all:find("No visible characters yet.", 1, true) ~= nil, all)
check("  and no total", not all:find("Gold on all characters", 1, true), all)
check("  the hints still there", all:find("Right-click: options", 1, true) ~= nil, all)
check("a nil tooltip is no error", pcall(obj.OnTooltipShow, nil))

------------------------------------------------------------
-- No broker
------------------------------------------------------------

-- The name taken (another addon, or a second load): no object, no listener.
local registered = 0
local realRegister = AltStable.RegisterCallback
AltStable.RegisterCallback = function(...) registered = registered + 1; return realRegister(...) end
local ok, err = pcall(dofile, "Broker.lua")
check("a taken name is no error", ok, tostring(err))
eq("  and leaves no object", AltStable._test.broker.object, nil)
eq("  and no listener", registered, 0)
eq("  the first object stays", LDB:GetDataObjectByName("AltStable"), obj)

-- No library at all.
local realLibStub = LibStub
LibStub = setmetatable({}, { __call = function() return nil end })
ok, err = pcall(dofile, "Broker.lua")
check("a missing library is no error", ok, tostring(err))
eq("  and leaves no object", AltStable._test.broker.object, nil)
eq("  and no listener", registered, 0)
LibStub = realLibStub
AltStable.RegisterCallback = realRegister

WoW.finish("test_broker", passed, failed)
