------------------------------------------------------------
-- GoldTooltip.lua - every character's gold on the bags' money (#305)
--
-- Hovering the gold in Blizzard's bag window shows the total across your
-- characters and how much each one holds, richest first. The sheet's footer
-- already shows the total; this puts it where you see your gold in game.
--
-- The numbers are the footer's: AltStable.CharacterTotals (Core.lua) is the one
-- piece of arithmetic behind the footer, the public GetTotals() and this. So a
-- hidden character is left out here too, and a character whose money is
-- unreadable (secret, see Compat.lua) is listed with "?" and the total says it
-- is partial instead of counting it as zero.
--
-- Where: the coin buttons of ContainerFrame1.MoneyFrame (the backpack) and
-- ContainerFrameCombinedBags.MoneyFrame (combined bags), both
-- ContainerMoneyFrameTemplate (wow-ui-source 70862,
-- Blizzard_UIPanels_Game/Mainline/ContainerFrame.xml). The frame itself takes
-- no mouse; its Gold/Silver/Copper buttons do (MoneyFrameButtonTemplate), and
-- their own OnEnter shows nothing for a bag (no showTooltip). HookScript is a
-- post-hook: Blizzard's click to pick up money still works.
--
-- A bag addon that replaces the bags (Bagnon, Baganator) never shows these
-- frames, and has its own gold tooltip.
------------------------------------------------------------

-- Inline class-icon texture escape for a tooltip line (empty if unknown), as
-- the Warband tab's item counts draw it.
local function ClassIconMarkup(class)
    local t = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if not t then return "" end
    return string.format(
        "|TInterface\\TargetingFrame\\UI-Classes-Circles:14:14:0:0:256:256:%d:%d:%d:%d|t ",
        math.floor(t[1] * 256), math.floor(t[2] * 256),
        math.floor(t[3] * 256), math.floor(t[4] * 256))
end

local function Money(copper)
    if AltStable.FormatMoney then return AltStable.FormatMoney(copper) end
    return tostring(copper)
end

-- The totals (CharacterTotals) and one row per character the totals count:
-- { name, class, money } with money nil when unreadable. Richest first; the
-- unreadable last; ties by name.
function AltStable.GoldTooltipRows()
    local Plain = AltStable.API.PlainNumber
    local rows = {}
    for _, c in pairs(type(AltStableDB) == "table" and AltStableDB or {}) do
        if type(c) == "table" and c.name
           and not (AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(c.guid)) then
            rows[#rows + 1] = { name = c.name, class = c.class, money = Plain(c.money) }
        end
    end
    table.sort(rows, function(a, b)
        if (a.money == nil) ~= (b.money == nil) then return b.money == nil end
        if a.money ~= b.money then return a.money > b.money end
        return a.name < b.name
    end)
    return AltStable.CharacterTotals(), rows
end

local function Plural(n, one, many)
    return n .. " " .. (n == 1 and one or many)
end

function AltStable.ShowGoldTooltip(owner)
    local tt = GameTooltip
    if not tt then return end
    local totals, rows = AltStable.GoldTooltipRows()
    if #rows == 0 then return end
    tt:SetOwner(owner, "ANCHOR_TOPRIGHT", 20, 2)
    tt:AddDoubleLine("Gold on all characters", Money(totals.money), 1, .82, 0, 1, 1, 1)
    tt:AddLine(" ")
    for _, r in ipairs(rows) do
        local cc = (r.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[r.class]) or { r = .9, g = .9, b = .9 }
        local left = ClassIconMarkup(r.class) .. r.name
        if r.money then
            tt:AddDoubleLine(left, Money(r.money), cc.r, cc.g, cc.b, 1, 1, 1)
        else
            tt:AddDoubleLine(left, "?", cc.r, cc.g, cc.b, .55, .55, .55)
        end
    end
    if totals.unknown > 0 then
        tt:AddLine(" ")
        tt:AddLine("The total leaves out " .. Plural(totals.unknown, "character", "characters")
            .. " whose gold can't be read (?).", .55, .55, .55, true)
    end
    if totals.hidden > 0 then
        if totals.unknown == 0 then tt:AddLine(" ") end
        tt:AddLine(Plural(totals.hidden, "hidden character", "hidden characters")
            .. " left out.", .55, .55, .55, true)
    end
    tt:Show()
end

local function HookMoneyFrame(mf)
    if type(mf) ~= "table" or mf.altStableGoldTooltip then return false end
    local hooked = false
    for _, key in ipairs({ "GoldButton", "SilverButton", "CopperButton" }) do
        local b = mf[key]
        if type(b) == "table" and b.HookScript then
            b:HookScript("OnEnter", function(self) AltStable.ShowGoldTooltip(self) end)
            b:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
            hooked = true
        end
    end
    mf.altStableGoldTooltip = hooked or nil
    return hooked
end

-- Hooks whichever bag money frames exist. Returns how many it hooked; calling
-- it again never hooks a frame twice.
function AltStable.InstallGoldTooltip()
    local n = 0
    local backpack = ContainerFrame1 and ContainerFrame1.MoneyFrame
    local combined = ContainerFrameCombinedBags and ContainerFrameCombinedBags.MoneyFrame
    if HookMoneyFrame(backpack) then n = n + 1 end
    if HookMoneyFrame(combined) then n = n + 1 end
    return n
end

-- At login: Blizzard's bag frames exist by then whatever the load order.
local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    AltStable.InstallGoldTooltip()
end)
