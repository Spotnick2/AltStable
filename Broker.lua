------------------------------------------------------------
-- Broker.lua - AltStable on Titan Panel and other LibDataBroker displays (#466)
--
-- One LibDataBroker-1.1 "data source" named "AltStable": its text is the gold
-- on all your characters, the sheet footer's figure (CharacterTotals: hidden
-- characters left out, unreadable money counted apart, never as 0); its
-- tooltip is the bag money's gold tooltip (GoldTooltip.lua, the same lines);
-- left-click opens or closes the sheet, right-click opens Options, as the
-- minimap button does. Titan users can hide that button in Options.
--
-- A data source rather than a launcher, so a bar shows the gold as well as
-- the icon, as GlassPanel's [AltStable] block does. A display that lists
-- launchers only may leave it out; one object is enough.
--
-- Repainted on the public "CharactersChanged" notification (PublicAPI.lua):
-- it already covers every change to the characters - RefreshSheet from some
-- twenty places, the login scan, TouchCharacter - once a frame. Only the
-- signal comes from there; the number is CharacterTotals', AltStable's own.
--
-- The display owns the tooltip it hands OnTooltipShow (owner, anchor, Show),
-- so this only adds lines to it.
------------------------------------------------------------

AltStable = AltStable or {}

local NAME = "AltStable"
local ICON = 8197123   -- the TOC's IconTexture, as GlassPanel's block shows

local HINT = { 0.3, 1, 0.3 }

-- The footer's total as text: "?" when no counted character's gold can be
-- read (unknown, never 0), the coins plus " ?" when only some can.
local function GoldText()
    local t = AltStable.CharacterTotals()
    if t.characters - t.unknown <= 0 then return "?" end
    local text = AltStable.FormatMoney(t.money)
    if t.unknown > 0 then text = text .. " ?" end
    return text
end

local function OnClick(_, button)
    if button == "RightButton" then
        if AltStable.OpenConfig then AltStable.OpenConfig() end
    elseif button == "LeftButton" then
        if AltStable.ShowSheet then AltStable.ShowSheet() end
    end
end

local function OnTooltipShow(tt)
    if not tt then return end
    tt:AddLine("AltStable")
    local totals, rows = AltStable.GoldTooltipRows()
    if #rows > 0 then
        AltStable.AddGoldTooltipLines(tt, totals, rows)
    else
        tt:AddLine("No visible characters yet.", .55, .55, .55, true)
    end
    tt:AddLine(" ")
    tt:AddLine("Left-click: open or close AltStable", HINT[1], HINT[2], HINT[3])
    tt:AddLine("Right-click: options", HINT[1], HINT[2], HINT[3])
end

-- No library (it is bundled, so only a broken install), or another addon
-- already took the name (NewDataObject answers nil): no broker, nothing else
-- breaks.
local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
local obj = LDB and LDB:NewDataObject(NAME, {
    type = "data source",
    label = NAME,
    icon = ICON,
    -- The spec wants a string from the start; the real one comes at login,
    -- when the saved characters are loaded.
    text = "?",
    OnClick = OnClick,
    OnTooltipShow = OnTooltipShow,
})

-- LibDataBroker ignores an unchanged value, so assigning every time is cheap.
local function Update()
    if obj then obj.text = GoldText() end
end

if obj then
    AltStable.RegisterCallback("CharactersChanged", Update)

    -- The saved characters first, at login; the login scan's own
    -- CharactersChanged repaints with this character's current gold.
    local login = CreateFrame("Frame")
    login:RegisterEvent("PLAYER_LOGIN")
    login:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_LOGIN")
        Update()
    end)
end

AltStable._test = AltStable._test or {}
AltStable._test.broker = { object = obj, update = Update, goldText = GoldText }
