AltStable = AltStable or {}

------------------------------------------------------------
-- Rested XP live extrapolation
--
-- TBC accrues rested XP at:
--   * 5% of a level per 8 hours  while in a rested area (inn/city)
--   * 5% of a level per 32 hours while in the open world
-- Cap is 150% of a level.
--
-- We store at scan time: restXP (raw), xpMax (so % is recomputable),
-- restedArea (was the char in a rested zone at logout?), and
-- restTimestamp (when the snapshot was taken).
--
-- Given that frozen snapshot, we can compute the current rested %
-- for any character — including ones not currently logged in —
-- without needing them to log in again.
------------------------------------------------------------

-- restedArea is a boolean on the character that scanned it, but sync stringifies
-- it and DeserializeChar only coerces numbers - so a synced alt carries the STRING
-- "false", which is truthy. Compare explicitly; never test it for truthiness.
local function InRestedArea(char)
    return char.restedArea == true or char.restedArea == "true"
end

local function ComputeLiveRestedPercent(char)
    if not char then return 0, 0 end

    -- Characters at the level cap don't accrue rested XP
    local lvl = char.level or 0
    if lvl >= AltStable.API.LevelCap() then return 0, 0 end

    -- For the currently-logged-in character, ALWAYS read the live API.
    -- Stored values are a per-snapshot approximation that only moves up
    -- (when rested accrues); actual in-game rested also moves down as
    -- the character burns it at 2x XP.  The live API is the source of
    -- truth for the player character.
    if UnitGUID("player") == char.guid then
        local liveRest = GetXPExhaustion() or 0
        local liveMax  = UnitXPMax("player") or 1
        if liveMax > 0 then
            return math.floor((liveRest / liveMax) * 100 + 0.5), 0
        end
        return 0, 0
    end

    -- Offline / other-character path: extrapolate from last snapshot.
    local snapshotTime = char.restTimestamp or char.lastUpdate or 0
    local now          = time()
    local elapsed      = math.max(0, now - snapshotTime)

    local storedPercent = char.restPercent or 0

    -- Accrual rate (% of a level per hour)
    --   rested area: 5% per 8h  = 0.625 %/h
    --   open world:  5% per 32h = 0.15625 %/h
    local perHour = InRestedArea(char) and 0.625 or 0.15625
    local addedPercent = (elapsed / 3600) * perHour

    local live = storedPercent + addedPercent
    if live > 150 then live = 150 end

    return math.floor(live + 0.5), addedPercent
end

AltStable.ComputeLiveRestedPercent = ComputeLiveRestedPercent


------------------------------------------------------------
-- Profession icons
------------------------------------------------------------

local PROF_ICONS = {
    Alchemy        = "|TInterface\\Icons\\Trade_Alchemy:14:14:0:0|t",
    Blacksmithing  = "|TInterface\\Icons\\Trade_BlackSmithing:14:14:0:0|t",
    Enchanting     = "|TInterface\\Icons\\Trade_Engraving:14:14:0:0|t",
    Engineering    = "|TInterface\\Icons\\Trade_Engineering:14:14:0:0|t",
    Herbalism      = "|TInterface\\Icons\\Trade_Herbalism:14:14:0:0|t",
    Leatherworking = "|TInterface\\Icons\\Trade_LeatherWorking:14:14:0:0|t",
    Mining         = "|TInterface\\Icons\\Trade_Mining:14:14:0:0|t",
    Skinning       = "|TInterface\\Icons\\INV_Misc_Pelt_Wolf_01:14:14:0:0|t",
    Tailoring      = "|TInterface\\Icons\\Trade_Tailoring:14:14:0:0|t",
}

------------------------------------------------------------
-- Class icons
------------------------------------------------------------

local CLASS_DISPLAY = {
    WARRIOR="Warrior", PALADIN="Paladin", HUNTER="Hunter",
    ROGUE="Rogue", PRIEST="Priest", DEATHKNIGHT="Death Knight",
    SHAMAN="Shaman", MAGE="Mage", WARLOCK="Warlock", DRUID="Druid",
}

local function ClassIconText(class)
    if not class then return "" end
    -- ClassIcon_Warrior, ClassIcon_Paladin, etc. — these are portrait atlas icons
    -- capitalized exactly as stored in Interface\Icons\
    local name = class:sub(1,1):upper() .. class:sub(2):lower()
    return "|TInterface\\Icons\\ClassIcon_"..name..":18:18|t"
end

------------------------------------------------------------
-- Race icons — Achievement_Character_Race_Gender
-- Race names in the file system are title-cased with specific spellings.
------------------------------------------------------------

local RACE_DISPLAY = {
    Human="Human", Dwarf="Dwarf", Gnome="Gnome", NightElf="Night Elf",
    Draenei="Draenei", Orc="Orc", Troll="Troll", Tauren="Tauren",
    Scourge="Undead", BloodElf="Blood Elf", Goblin="Goblin",
}


------------------------------------------------------------
-- Race display — atlas-based icons (raceicon-name-gender)
-- Atlas names from ChatLinkIcons addon reference
------------------------------------------------------------

-- The atlas slug is the lowercased race key for every race measured so far,
-- including Forever's Skyborne (raceicon-skyborne-female). Only Scourge breaks
-- the pattern. Derived rather than looked up in an allowlist, so a race added
-- by a future patch renders instead of silently disappearing - which is what
-- an allowlist miss did, since it returned "".
local RACE_ATLAS_OVERRIDE = { Scourge = "undead" }

local function RaceIconText(race, gender)
    if not race or race == "" then return "" end
    local atlas = RACE_ATLAS_OVERRIDE[race] or race:lower()
    local g = (gender == "Female") and "female" or "male"
    return "|A:raceicon-"..atlas.."-"..g..":18:18|a"
end

-- Test seam (matches the AltStable._test convention in Core.lua).
AltStable._test = AltStable._test or {}
AltStable._test.RaceIconText = RaceIconText

------------------------------------------------------------
-- Reputation
------------------------------------------------------------

local REP_TEXT = {
    [1]="Hated",   [2]="Hostile",    [3]="Unfriendly",
    [4]="Neutral", [5]="Friendly",   [6]="Honored",
    [7]="Revered", [8]="Exalted",
}
local REP_TEXT_SHORT = {
    [1]="X", [2]="X", [3]="U",
    [4]="N", [5]="F", [6]="H",
    [7]="R", [8]="E",
}
local REP_COLOR = {
    [1]="|cffcc0000",[2]="|cffff0000",[3]="|cffff6600",
    [4]="|cffffff00",[5]="|cff66ff66",[6]="|cff00ff00",
    [7]="|cff00ffcc",[8]="|cff00ffff",
}

------------------------------------------------------------
-- Money icons
------------------------------------------------------------

local GOLD_ICON   = "|TInterface\\MoneyFrame\\UI-GoldIcon:14:14:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:14:14:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:14:14:2:0|t"
local GOLD_ICON_SM= "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"

------------------------------------------------------------
-- Format helpers  (all local, also used by frozen row renderer)
------------------------------------------------------------

local function ClassColor(class)
    if not class or not RAID_CLASS_COLORS then return "|cffffffff" end
    local c = RAID_CLASS_COLORS[class] or {r=1,g=1,b=1}
    return string.format("|cff%02x%02x%02x", c.r*255, c.g*255, c.b*255)
end
AltStable.ClassColor = ClassColor   -- expose for SheetUI frozen rows

local function FormatReputation(v)
    if not v then return "" end
    return (REP_COLOR[v] or "|cffffffff")..(REP_TEXT_SHORT[v] or "").." |r"
end

local function FormatMoney(copper)
    if not copper then return "" end
    local g=floor(copper/10000); local s=floor((copper%10000)/100); local c=copper%100
    return string.format("%d%s %d%s %d%s",g,GOLD_ICON,s,SILVER_ICON,c,COPPER_ICON)
end

local function FormatMoneySmall(copper)
    if not copper then return "" end
    return math.floor(copper/10000)..GOLD_ICON_SM
end

local function FormatMax(value, max)
    if not value then return "" end
    if max and max>0 and value>=max then return "|cffffd100"..value.."|r" end
    return tostring(value)
end

local function FormatProfession(name, skill, max)
    if not name or name=="" then return "" end
    local icon = PROF_ICONS[name] or ""
    return string.format("%s %s %s/%s", icon, name, FormatMax(skill,max), max or "")
end

------------------------------------------------------------
-- Item level display
--
-- The average renders neutrally: there is no Vanilla item-level
-- scale to colour it against (the old ramp was tuned to TBC raid
-- tiers). GetAverageItemLevel is fractional, so it is rounded.
-- Gear slots are coloured by the item's own quality instead
-- (see FormatGearIlvl).
------------------------------------------------------------

local function FormatItemLevel(ilvl)
    if not ilvl then return "" end
    return tostring(math.floor(ilvl + 0.5))
end

local function FormatSecondarySkill(value, max)
    -- 1 is the untrained default in TBC — treat it the same as 0
    if not value or value <= 1 then return "" end
    return FormatMax(value, max) .. "/" .. (max or "")
end

local function FormatLastOnline(ts, isCurrentPlayer)
    if not ts or ts==0 then return "|cff888888--|r" end
    local diff = time()-ts
    -- Only show "Online" for the character we're actually logged in as
    if isCurrentPlayer and diff<300 then return "|cff00ff00Online|r" end
    if     diff<3600     then return "|cff88ff88"..math.floor(diff/60).."m ago|r"
    elseif diff<86400    then return "|cffffff88"..math.floor(diff/3600).."h ago|r"
    elseif diff<86400*7  then local d=math.floor(diff/86400);      return "|cffaaaaaa"..d..(d==1 and " day"  or " days") .."|r"
    elseif diff<86400*30 then local w=math.floor(diff/(86400*7));  return "|cff888888"..w..(w==1 and " week" or " weeks").."|r"
    else                      local d=math.floor(diff/86400);      return "|cff666666"..d..(d==1 and " day"  or " days") .."|r"
    end
end

------------------------------------------------------------
-- Gear slot coloring — standard WoW item quality colors
--   0 Poor      : grey
--   1 Common    : white
--   2 Uncommon  : green
--   3 Rare      : blue
--   4 Epic      : purple
--   5 Legendary : orange
--   6 Artifact  : light gold  (the Retail enum carries these
--   7 Heirloom  : light blue   two; unmeasured on Forever)
------------------------------------------------------------

local QUALITY_COLORS = {
    [0] = "|cff9d9d9d",  -- grey   (Poor)
    [1] = "|cffffffff",  -- white  (Common)
    [2] = "|cff1eff00",  -- green  (Uncommon)
    [3] = "|cff0070dd",  -- blue   (Rare)
    [4] = "|cffa335ee",  -- purple (Epic)
    [5] = "|cffff8000",  -- orange (Legendary)
    [6] = "|cffe6cc80",  -- gold   (Artifact)
    [7] = "|cff00ccff",  -- cyan   (Heirloom)
}

local function FormatGearIlvl(slotIlvl, slotQuality)
    if not slotIlvl or slotIlvl == 0 then
        return "|cff444444--|r"
    end
    local v = math.floor(slotIlvl)
    return (QUALITY_COLORS[slotQuality] or QUALITY_COLORS[1]) .. v .. "|r"
end

AltStable._test.FormatItemLevel          = FormatItemLevel
AltStable._test.FormatGearIlvl           = FormatGearIlvl
AltStable._test.ComputeLiveRestedPercent = ComputeLiveRestedPercent

------------------------------------------------------------
-- Shared row background colours
-- Using full-opacity colours so the class tint layer sits
-- cleanly on top at low alpha.
------------------------------------------------------------

local function SetRowBg(row, index)
    local C = AltStable.C
    if index % 2 == 0 then
        row.bg:SetColorTexture(
            C.BG_ROW_EVEN[1], C.BG_ROW_EVEN[2],
            C.BG_ROW_EVEN[3], C.BG_ROW_EVEN[4])
    else
        row.bg:SetColorTexture(
            C.BG_ROW_ODD[1], C.BG_ROW_ODD[2],
            C.BG_ROW_ODD[3], C.BG_ROW_ODD[4])
    end
end

-- Group / realm header row background
local function GetGroupBG() return unpack(AltStable.C.BG_GROUP) end

------------------------------------------------------------
-- Scrollable row  (receives only the non-frozen columns)
------------------------------------------------------------

local DIVIDER_COLOR = AltStable.C.GRIDLINE

-- Row pools, one per sheet section. A row is built with one cell and tooltip
-- frame per column, so it can't be reused across a change of columns - and the
-- Reputations section's columns follow the data. A pool remembers the columns
-- its rows were built for; when they change, the old rows are hidden and
-- dropped (frames can't be destroyed; this only happens when a character meets
-- a new faction) and the caller builds fresh ones. Frozen (Name) rows don't
-- depend on the columns and are kept.
function AltStable.RowPoolFor(pools, sectionId, columns)
    local fields = {}
    for i, col in ipairs(columns) do fields[i] = col.field end
    local signature = table.concat(fields, ",")
    local pool = pools[sectionId]
    if not pool then
        pool = { rows = {}, frozenRows = {}, signature = signature }
        pools[sectionId] = pool
    elseif pool.signature ~= signature then
        for _, row in ipairs(pool.rows) do row:Hide() end
        pool.rows = {}
        pool.signature = signature
    end
    return pool
end

function AltStable.CreateRow(parent, height, columns)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(height)
    row.cells    = {}
    row.repTips  = {}
    row.gearTips = {}
    row.cellTips = {}

    -- Base alternating background
    row.bg = row:CreateTexture(nil,"BACKGROUND")
    row.bg:SetAllPoints()

    -- Class-colour tint (layered above bg at low alpha)
    row.classTint = row:CreateTexture(nil,"ARTWORK")
    row.classTint:SetAllPoints()
    row.classTint:SetColorTexture(0,0,0,0)  -- invisible until a char is rendered

    -- Hover highlight
    row.hover = row:CreateTexture(nil,"HIGHLIGHT")
    row.hover:SetAllPoints()
    row.hover:SetColorTexture(1,1,1,0.05)

    local x=10; local padding=6
    for i, col in ipairs(columns) do
        local cell

        if col.type == "classIcon" or col.type == "raceIcon" then
            cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            cell:SetPoint("LEFT", x, 0)
            cell:SetWidth(col.width)
            cell:SetJustifyH("CENTER")
            cell:SetWordWrap(false)
            row.cells[i] = cell
        else
            cell = row:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
            cell:SetPoint("LEFT",x,0)
            cell:SetWidth(col.width)
            cell:SetJustifyH(col.align or "LEFT")
            cell:SetWordWrap(false)
            row.cells[i] = cell
        end

        -- General tooltip button for classIcon, raceIcon, level, restPercent, profSkill
        if col.type=="classIcon" or col.type=="raceIcon"
        or col.field=="level" or col.type=="restXP"
        or col.field=="restPercent" or col.type=="profSkill" then
            local tip = CreateFrame("Button", nil, row)
            tip:SetPoint("LEFT", x, 0)
            tip:SetSize(col.width, height)
            tip:SetScript("OnEnter", function()
                GameTooltip:SetOwner(tip, "ANCHOR_RIGHT")
                GameTooltip:ClearLines()
                if tip.line1 then GameTooltip:AddLine(tip.line1, 1,1,1) end
                if tip.line2 then GameTooltip:AddLine(tip.line2, 0.8,0.8,0.8) end
                if tip.line3 then GameTooltip:AddLine(tip.line3, 0.7,0.7,0.4) end
                if tip.cdLines then
                    GameTooltip:AddLine(" ", 1,1,1)  -- spacer
                    for _, line in ipairs(tip.cdLines) do
                        GameTooltip:AddLine(line, 1,1,1)
                    end
                end
                GameTooltip:Show()
            end)
            tip:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row.cellTips[i] = tip
        end

        -- Invisible hover button for rep cells
        if col.type == "rep" then
            local tip = CreateFrame("Button", nil, row)
            tip:SetPoint("LEFT", x, 0)
            tip:SetSize(col.width, height)
            tip:SetScript("OnEnter", function()
                if tip.standing then
                    GameTooltip:SetOwner(tip, "ANCHOR_RIGHT")
                    GameTooltip:ClearLines()
                    local factionName = tip.factionLabel or ""
                    GameTooltip:AddLine(factionName, 1, 1, 1)
                    GameTooltip:AddLine(tip.standing, 0.8, 0.8, 0.8)
                    GameTooltip:Show()
                end
            end)
            tip:SetScript("OnLeave", function() GameTooltip:Hide() end)
            tip.factionLabel = col.label
            row.repTips[i] = tip
        end

        -- Invisible hover button for gear slots
        if col.type == "gearSlot" then
            local tip = CreateFrame("Button", nil, row)
            tip:SetPoint("LEFT", x, 0)
            tip:SetSize(col.width, height)

            -- Hover highlight background
            local hoverBg = tip:CreateTexture(nil, "BACKGROUND")
            hoverBg:SetAllPoints()
            hoverBg:SetColorTexture(1, 1, 1, 0.12)
            hoverBg:Hide()
            tip.hoverBg = hoverBg

            tip:SetScript("OnEnter", function()
                hoverBg:Show()
                if tip.isCurrentPlayer and tip.slotID then
                    -- Live tooltip for the currently logged-in character's equipped item.
                    -- SetInventoryItem shows enchants, gems, and socket bonuses correctly.
                    GameTooltip:SetOwner(tip, "ANCHOR_RIGHT")
                    GameTooltip:SetInventoryItem("player", tip.slotID)
                    GameTooltip:Show()
                elseif tip.itemLink and tip.itemLink ~= "" then
                    -- Local full item link only (carries this client's
                    -- gems/enchants).
                    local itemID = tip.itemLink:match("item:(%d+)")
                    if itemID then
                        GameTooltip:SetOwner(tip, "ANCHOR_RIGHT")
                        GameTooltip:SetHyperlink("item:"..itemID)
                        GameTooltip:Show()
                    end
                elseif tip.itemID and tip.itemID > 0 then
                    -- Synced characters carry no link, only the item id: the
                    -- base item's tooltip, without this character's enchants.
                    GameTooltip:SetOwner(tip, "ANCHOR_RIGHT")
                    GameTooltip:SetHyperlink("item:"..tip.itemID)
                    GameTooltip:Show()
                elseif tip.slotIlvl and tip.slotIlvl > 0 then
                    -- Fallback for items without a stored link
                    local qColor = QUALITY_COLORS[tip.slotQuality or 1] or "|cffffffff"
                    GameTooltip:SetOwner(tip, "ANCHOR_RIGHT")
                    GameTooltip:ClearLines()
                    if tip.itemName and tip.itemName ~= "" then
                        GameTooltip:AddLine(qColor..tip.itemName.."|r", 1,1,1)
                    end
                    GameTooltip:AddLine(col.label.." — ilvl "..tip.slotIlvl, 0.8,0.8,0.8)
                    GameTooltip:Show()
                end
            end)
            tip:SetScript("OnLeave", function()
                hoverBg:Hide()
                GameTooltip:Hide()
            end)
            row.gearTips[i] = tip
        end

        if i<#columns then
            local div = row:CreateTexture(nil,"ARTWORK")
            div:SetSize(1,height)
            div:SetPoint("LEFT",x+col.width+math.floor(padding/2),0)
            div:SetColorTexture(unpack(DIVIDER_COLOR))
            row.dividers = row.dividers or {}
            table.insert(row.dividers, div)
        end
        x=x+col.width+padding
    end
    return row
end

-- For a scrollable group row: colour the background AND render the
-- "(Account: <name>)" label that visually continues from the realm name in
-- the frozen panel. The frozen scroll frame clips children at FROZEN_WIDTH,
-- so the label can't be a single string spanning both panels — we split it
-- intentionally. Together they read as one continuous "Dreamscythe (Account: Default)".
function AltStable.RenderGroupRow(row, item)
    row.bg:SetColorTexture(GetGroupBG())
    if row.classTint then row.classTint:SetColorTexture(0,0,0,0) end
    for _, cell in ipairs(row.cells) do cell:SetText("") end

    -- Group row is a solid full-width band — column dividers must not paint
    -- through it. RenderRow restores them for character rows.
    if row.dividers then
        for _, d in ipairs(row.dividers) do d:Hide() end
    end

    if not row.groupLabel then
        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("LEFT", row, "LEFT", 6, 0)
        lbl:SetJustifyH("LEFT")
        row.groupLabel = lbl
    end
    -- Account name is a placeholder until/unless the data model ever carries
    -- a real account label. Color: dim gray for the parens, accent green for
    -- the value, matching the approved mockup.
    local accountName = (item.account ~= nil and tostring(item.account)) or "Default"
    row.groupLabel:SetText(
        "|cffaaaaaa(Account: |r"
        .. "|cff66ff66" .. accountName .. "|r"
        .. "|cffaaaaaa)|r"
    )
    row.groupLabel:Show()
    row:Show()
end

function AltStable.RenderRow(row, char, index, columns)
    SetRowBg(row, index)
    -- Pool reuse: a row that previously rendered as a group header may carry
    -- a leftover groupLabel. Hide it so it doesn't bleed onto this char row.
    if row.groupLabel then row.groupLabel:Hide() end
    -- Pool reuse the other direction: dividers were hidden by RenderGroupRow,
    -- restore them now since this is a regular character row.
    if row.dividers then
        for _, d in ipairs(row.dividers) do d:Show() end
    end
    -- Overlay a subtle class-colour tint on top of the base background
    if row.classTint then
        local r, g, b = AltStable.GetClassRGB(char.class)
        row.classTint:SetColorTexture(r, g, b, AltStable.C.CLASS_TINT_ALPHA)
    end
    for i, col in ipairs(columns) do
        local value = ""
        local tip   = row.cellTips[i]

        if col.type=="classIcon" then
            value = ClassIconText(char.class)
            if tip then
                tip.line1 = CLASS_DISPLAY[char.class] or char.class
                tip.line2 = char.gender
                tip.line3 = nil
            end

        elseif col.type=="raceIcon" then
            value = RaceIconText(char.race, char.gender)
            if tip then
                -- Stored localized name first: Skyborne renders as either
                -- "High Order Skyborne" or "Windshaper Skyborne" depending on
                -- faction, and both share the key "Skyborne".
                tip.line1 = (char.raceName ~= "" and char.raceName)
                    or (char.race and RACE_DISPLAY[char.race])
                    or char.race
                tip.line2 = char.gender
                tip.line3 = nil
            end

        elseif col.field=="level" then
            local cap = AltStable.API.LevelCap()
            value = FormatMax(char.level, cap)
            if tip then
                local lvl = char.level or 0
                if lvl < cap then
                    local xpPct = char.xpPercent or 0
                    tip.line1 = "Level " .. lvl
                    tip.line2 = xpPct .. "% through this level"
                    tip.line3 = nil
                else
                    tip.line1 = "Level " .. lvl .. " (max)"
                    tip.line2 = nil; tip.line3 = nil
                end
            end

        elseif col.field=="ilvl" then value = FormatItemLevel(char.ilvl)

        elseif col.type=="gearSlot" then
            local slotKey = col.field:sub(6)  -- e.g. "head", "neck", etc.
            local v = char[col.field]
            local q = char["gearq_"..slotKey] or 0
            local itemName = char["gearname_"..slotKey] or ""
            local itemLink = char["gearlink_"..slotKey] or ""
            value = FormatGearIlvl(v, q)
            if row.gearTips[i] then
                row.gearTips[i].slotIlvl         = v
                row.gearTips[i].slotQuality       = q
                row.gearTips[i].itemName          = itemName
                row.gearTips[i].itemLink          = itemLink
                row.gearTips[i].itemID            = tonumber(char["gearid_"..slotKey]) or 0
                row.gearTips[i].slotID            = col.slotID
                row.gearTips[i].isCurrentPlayer   = (char.guid == UnitGUID("player"))
            end
        elseif col.field=="restPercent" or col.type=="restXP" then
            local lvl = char.level or 0
            local atCap = lvl >= AltStable.API.LevelCap()
            local p   = ComputeLiveRestedPercent(char)  -- 0 at the level cap
            if atCap then
                -- At the level cap rested XP doesn't apply. Show a dim
                -- placeholder rather than a red 0%, which reads like an error.
                value = "|cff888888—|r"
            else
                -- Gradient: 0%=red, 75%=yellow, 150%=green
                local r, g
                if p <= 75 then
                    local t = p / 75
                    r = 1; g = t
                else
                    local t = (p - 75) / 75
                    r = 1 - t; g = 1
                end
                value = string.format("|cff%02x%02x00%d%%|r", math.floor(r*255), math.floor(g*255), p)
            end
            if tip and not atCap then
                if p >= 150 then
                    tip.line1 = "Rested XP: " .. p .. "% (full)"
                    tip.line2 = nil; tip.line3 = nil
                elseif p > 0 then
                    local needed  = 150 - p
                    -- Time to full depends on whether the character
                    -- logged out in a rested zone.
                    local perHour = InRestedArea(char) and 0.625 or 0.15625
                    local hours   = math.ceil(needed / perHour)
                    local days    = math.floor(hours / 24)
                    local remHour = hours % 24
                    local timeStr = days > 0 and (days.."d "..remHour.."h") or (hours.."h")
                    tip.line1 = "Rested XP: " .. p .. "%"
                    if InRestedArea(char) then
                        tip.line2 = "~" .. timeStr .. " offline to reach 150% (in inn/city)"
                    else
                        tip.line2 = "~" .. timeStr .. " offline to reach 150% (open world)"
                    end
                    tip.line3 = nil
                else
                    tip.line1 = "Rested XP: 0%"
                    tip.line2 = "Log off in an inn to accumulate faster"
                    tip.line3 = nil
                end
            elseif tip then
                tip.line1 = "Level cap — rested XP inactive"
                tip.line2 = nil; tip.line3 = nil
            end

        elseif col.type=="profSkill" then
            local skill = char[col.field]
            local max   = col.maxField and char[col.maxField]
            if not skill or skill <= 0 then
                value = ""
            elseif max and max > 0 then
                local ratio = skill / max
                local color
                if skill >= max then
                    -- Maxed (or racial overcap) — green
                    color = "|cff1eff00"
                elseif ratio >= 0.75 then
                    color = "|cffffff00"  -- yellow
                elseif ratio >= 0.50 then
                    color = "|cffff8800"  -- orange
                elseif ratio >= 0.25 then
                    color = "|cffff2020"  -- red
                else
                    color = "|cff808080"  -- grey
                end
                value = color..skill.."|r"
            else
                value = tostring(skill)
            end
            if tip then
                tip.line1 = col.label
                tip.line2 = max and ("Max: "..max) or nil
                tip.line3 = nil
                -- Append any craft cooldowns for this profession. Cooldowns are
                -- captured generically by the Professions plugin as dynamic
                -- cd_<prof>@<label> fields on the record, so we match this
                -- column's profession and list whatever it holds — no allowlist.
                tip.cdLines = nil
                if col.label and skill and skill > 0 then
                    local prefix = "cd_" .. col.label .. "@"
                    local plen   = #prefix
                    local cdLines = {}
                    local now = time()
                    for k, v in pairs(char) do
                        if type(k) == "string" and k:sub(1, plen) == prefix then
                            local label  = k:sub(plen + 1)
                            local expiry = tonumber(v)
                            if expiry then
                                if expiry <= now then
                                    table.insert(cdLines, "|cff00ff00"..label..": Ready!|r")
                                else
                                    local remaining = expiry - now
                                    local d = math.floor(remaining / 86400)
                                    local h = math.floor((remaining % 86400) / 3600)
                                    local m = math.floor((remaining % 3600) / 60)
                                    local timeStr
                                    if d > 0 then
                                        timeStr = d.."d "..(h > 0 and h.."h" or "")
                                    elseif h > 0 then
                                        timeStr = h.."h "..m.."m"
                                    else
                                        timeStr = m.."m"
                                    end
                                    table.insert(cdLines, "|cffff8800"..label..": "..timeStr.."|r")
                                end
                            end
                        end
                    end
                    table.sort(cdLines)
                    if #cdLines > 0 then
                        tip.cdLines = cdLines
                    end
                end
            end
        elseif col.field=="lastUpdate"  then
            local isMe = char.guid == UnitGUID("player")
            value = FormatLastOnline(char.lastUpdate, isMe)
        elseif col.type=="money"        then value = FormatMoney(char[col.field])
        elseif col.type=="rep"          then
            local standing = char[col.field]
            value = FormatReputation(standing)
            if row.repTips[i] then
                row.repTips[i].standing = standing and REP_TEXT[standing] or nil
            end
        else
            value = tostring(char[col.field] or "")
        end

        row.cells[i]:SetText(value)
    end
    row:Show()
end

function AltStable.HideRow(row)
    for _, cell in ipairs(row.cells) do cell:SetText("") end
    row.bg:SetColorTexture(0,0,0,0)
    if row.classTint then row.classTint:SetColorTexture(0,0,0,0) end
    if row.groupLabel then row.groupLabel:Hide() end
    row:Hide()
end

-- Filler row: visible row beyond the last data item, painted in the
-- alternating-row background color so the table reads as continuing past
-- the last alt. No text, no class tint, no group label, no column dividers.
-- Used when the frame is taller than the data needs (e.g. few characters,
-- realm group collapsed, sidebar drives the minimum height). The filler
-- index is 1-based RELATIVE to the start of the filler region so the
-- alternating pattern continues seamlessly from the last real row.
function AltStable.RenderFillerRow(row, index)
    SetRowBg(row, index)
    if row.classTint  then row.classTint:SetColorTexture(0,0,0,0) end
    if row.groupLabel then row.groupLabel:Hide() end
    -- Show dividers so the column lines extend visually through the empty
    -- space — like a real spreadsheet's empty rows below the last data row.
    if row.dividers then for _, d in ipairs(row.dividers) do d:Show() end end
    for _, cell in ipairs(row.cells) do cell:SetText("") end
    row:Show()
end

------------------------------------------------------------
-- Frozen column row  (Name only)
------------------------------------------------------------

function AltStable.CreateFrozenRow(parent, height, nameColWidth)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(height)

    row.bg = row:CreateTexture(nil,"BACKGROUND")
    row.bg:SetAllPoints()

    -- Class-colour tint (same as scrollable row)
    row.classTint = row:CreateTexture(nil,"ARTWORK")
    row.classTint:SetAllPoints()
    row.classTint:SetColorTexture(0,0,0,0)

    row.hover = row:CreateTexture(nil,"HIGHLIGHT")
    row.hover:SetAllPoints()
    row.hover:SetColorTexture(1,1,1,0.05)

    local cBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
    cBtn:SetSize(18, 18); cBtn:SetPoint("LEFT", 8, 0); cBtn:Hide()
    -- Subtle bordered box styling: a small dark panel that the +/- glyph
    -- sits inside, matching the addon's overall flat dark look. Backdrop
    -- is applied at render time so the addon's loaded ApplyBackdrop helper
    -- is guaranteed to be available.
    row.collapseBtn = cBtn
    local cIcon = cBtn:CreateFontString(nil,"OVERLAY","GameFontHighlight")
    cIcon:SetAllPoints(); cIcon:SetJustifyH("CENTER"); cIcon:SetJustifyV("MIDDLE")
    row.collapseIcon = cIcon

    local lbl = row:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    lbl:SetHeight(height); lbl:SetJustifyH("LEFT"); lbl:SetWordWrap(false)
    lbl:SetPoint("LEFT",10,0); lbl:SetWidth(nameColWidth)
    row.nameLabel = lbl

    -- Invisible tooltip button for character rows
    local tipBtn = CreateFrame("Button", nil, row)
    tipBtn:SetAllPoints()
    tipBtn:SetScript("OnEnter", function()
        if not tipBtn.charData then return end
        local c = tipBtn.charData
        local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"
        GameTooltip:SetOwner(tipBtn, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(AltStable.ClassColor(c.class)..(c.name or "").."|r", 1,1,1)
        if c.guild and c.guild ~= "" then
            GameTooltip:AddLine("<"..c.guild..">", 0.7,0.7,0.7)
        end
        GameTooltip:AddLine(" ",1,1,1)
        if c.money then
            local gold = math.floor(c.money/10000)
            local silver = math.floor((c.money%10000)/100)
            local copper = c.money % 100
            GameTooltip:AddLine(string.format("Gold: %d%s %ds %dc", gold,GOLD_ICON,silver,copper), 0.9,0.85,0.1)
        end
        if c.lastUpdate then
            local diff = time()-c.lastUpdate
            local isMe = c.guid == UnitGUID("player")
            local onlineStr
            if isMe and diff<300 then onlineStr="|cff00ff00Online|r"
            elseif diff<3600 then onlineStr=math.floor(diff/60).."m ago"
            elseif diff<86400 then onlineStr=math.floor(diff/3600).."h ago"
            else onlineStr=math.floor(diff/86400).."d ago" end
            GameTooltip:AddLine("Last seen: "..onlineStr, 0.7,0.7,0.7)
        end
        GameTooltip:Show()
    end)
    tipBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.nameTipBtn = tipBtn

    return row
end

function AltStable.RenderFrozenGroupRow(row, item)
    row.bg:SetColorTexture(GetGroupBG())
    if row.classTint then row.classTint:SetColorTexture(0,0,0,0) end
    row.collapseBtn:Show()

    -- Apply the bordered-box backdrop the first time we render this button.
    -- Doing it here (not in CreateFrozenRow) keeps creation lean and lets
    -- ApplyBackdrop be available — Theme.lua loads after RowRenderer.lua.
    if not row._collapseStyled and AltStable.ApplyBackdrop then
        AltStable.ApplyBackdrop(row.collapseBtn, 0.10, 0.10, 0.10, 1)
        row._collapseStyled = true
    end

    -- Use proper unicode minus (en dash) for the expanded state — visually
    -- balanced inside the box. Plus stays as ASCII.
    row.collapseIcon:SetText(item.collapsed and "+" or "−")

    -- Shift label right to make room for the button.
    -- ClearAllPoints first because RenderFrozenCharRow may have anchored
    -- this nameLabel directly to the row left edge in a previous render.
    row.nameLabel:ClearAllPoints()
    row.nameLabel:SetPoint("LEFT", row.collapseBtn, "RIGHT", 6, 0)

    local realm = item.realm
    row.collapseBtn:SetScript("OnClick", function()
        if AltStable.ToggleRealm then AltStable.ToggleRealm(realm) end
    end)

    -- Group row shows just the realm name in white, bold-ish. The character
    -- count, total levels and total gold previously crammed into this label
    -- are already displayed in the totals bar — duplicating them here just
    -- made the row noisy and forced an unnecessary truncation in the
    -- frozen Name column.
    row.nameLabel:SetText("|cffffffff"..(item.realm or "").."|r")
    row:Show()
end

function AltStable.RenderFrozenCharRow(row, char, index)
    SetRowBg(row, index)
    if row.classTint then
        local r, g, b = AltStable.GetClassRGB(char.class)
        row.classTint:SetColorTexture(r, g, b, AltStable.C.CLASS_TINT_ALPHA)
    end
    row.collapseBtn:Hide()
    -- Pool reuse: clear any previous anchor (e.g. from RenderFrozenGroupRow
    -- which anchors nameLabel to the collapse button) before re-anchoring.
    row.nameLabel:ClearAllPoints()
    row.nameLabel:SetPoint("LEFT",10,0)
    row.nameLabel:SetText(AltStable.ClassColor(char.class)..(char.name or "").."|r")
    if row.nameTipBtn then row.nameTipBtn.charData = char end
    row:Show()
end

function AltStable.HideFrozenRow(row)
    row.bg:SetColorTexture(0,0,0,0)
    if row.classTint then row.classTint:SetColorTexture(0,0,0,0) end
    row.collapseBtn:Hide()
    row.nameLabel:SetText("")
    if row.nameTipBtn then row.nameTipBtn.charData = nil end
    row:Hide()
end

-- Filler row on the frozen side. Same alternating-bg as the scrollable
-- side filler. No name, no class icon, no collapse button.
function AltStable.RenderFrozenFillerRow(row, index)
    SetRowBg(row, index)
    if row.classTint then row.classTint:SetColorTexture(0,0,0,0) end
    row.collapseBtn:Hide()
    row.nameLabel:SetText("")
    if row.nameTipBtn then row.nameTipBtn.charData = nil end
    row:Show()
end
