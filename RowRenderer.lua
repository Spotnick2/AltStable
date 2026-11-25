AltStable = AltStable or {}

------------------------------------------------------------
-- Rested XP live extrapolation
--
-- TBC accrues rested XP at:
--   * 5% of a level per 8 hours  while in a rested area (inn/city)
--   * 5% of a level per 32 hours while in the open world
-- Cap is 150% of a level.
--
-- The Well Rested Legacy talent (spell 1225478, #352) adds 20% to both:
-- "accumulates 20% faster and your rested experience cap is increased by 20%".
-- The cap with it is UNMEASURED: 180% (150 x 1.2) is assumed, and a stored
-- value above it wins, so a measured one is never clamped down.
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

local BASE_CAP, WELL_RESTED_CAP, WELL_RESTED_RATE = 150, 180, 1.2

-- The scan stores wellRested as 1/0 (a number, so it syncs as one). A stored
-- rested % above the base cap proves a raised cap even when the scan could not
-- tell, e.g. a record from a version before #352.
local function HasWellRested(char)
    return tonumber(char.wellRested) == 1 or (tonumber(char.restPercent) or 0) > BASE_CAP
end

local function RestedCap(char)
    if not HasWellRested(char) then return BASE_CAP end
    return math.max(WELL_RESTED_CAP, tonumber(char.restPercent) or 0)
end

-- Accrual, % of a level per hour: 5% per 8h in a rested area, per 32h outside.
local function RestedPerHour(char)
    local perHour = InRestedArea(char) and 0.625 or 0.15625
    if HasWellRested(char) then perHour = perHour * WELL_RESTED_RATE end
    return perHour
end

AltStable.RestedCap = RestedCap

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
        -- Through the adapter: a secret here would throw on the divide and take
        -- out the row being drawn, not just one number.
        -- Not rested (a plain nil) is 0%, not the stored bonus (#425).
        local liveRest = AltStable.API.RestedXP()
        local liveMax  = AltStable.API.PlainNumber(UnitXPMax("player"))
        if liveRest and liveMax and liveMax > 0 then
            return math.floor((liveRest / liveMax) * 100 + 0.5), 0
        end
        -- Unreadable live values: fall through to the stored snapshot rather
        -- than reporting 0% rested, which reads as fact.
    end

    -- Offline / other-character path: extrapolate from last snapshot.
    local snapshotTime = char.restTimestamp or char.lastUpdate or 0
    local now          = time()
    local elapsed      = math.max(0, now - snapshotTime)

    local storedPercent = char.restPercent or 0

    local addedPercent = (elapsed / 3600) * RestedPerHour(char)

    local live = storedPercent + addedPercent
    local cap  = RestedCap(char)
    if live > cap then live = cap end

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

-- The class and race a character's cell tooltip names, and the Class and Race
-- columns sort by (#160): the stored tokens sort wrong - Undead is "Scourge".
function AltStable.ClassDisplayName(char)
    return CLASS_DISPLAY[char.class] or char.class
end

-- Stored localized name first: Skyborne renders as either "High Order
-- Skyborne" or "Windshaper Skyborne" depending on faction, and both share the
-- key "Skyborne".
function AltStable.RaceDisplayName(char)
    return (char.raceName ~= "" and char.raceName)
        or (char.race and RACE_DISPLAY[char.race])
        or char.race
end


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

-- Money and "last seen", exposed on AltStable rather than kept local.
--
-- The Roster is a SEPARATE addon and cannot reach a local in here, so the
-- detail pane (#91) would have needed its own copy - and there were already
-- two copies of the last-seen rule in this file alone, one colour-coded for
-- the grid and one plain for a tooltip, which had already drifted: the
-- tooltip's stopped at "d ago" where the column goes on to weeks.
--
-- One rule, one place, and the colour is a parameter.
function AltStable.FormatMoney(copper)     return FormatMoney(copper) end
function AltStable.FormatMoneyShort(copper) return FormatMoneySmall(copper) end

local function FormatLastOnline(ts, online)
    -- Online is a fact about now (AltStable.IsCharacterOnline), not about how
    -- recent the stamp is: the character played here went on reading "9m ago"
    -- once nothing had changed for five minutes.
    if online then return "|cff00ff00Online|r" end
    if not ts or ts==0 then return "|cff888888--|r" end
    local diff = math.max(0, time()-ts)
    if     diff<3600     then return "|cff88ff88"..math.floor(diff/60).."m ago|r"
    elseif diff<86400    then return "|cffffff88"..math.floor(diff/3600).."h ago|r"
    elseif diff<86400*7  then local d=math.floor(diff/86400);      return "|cffaaaaaa"..d..(d==1 and " day"  or " days") .."|r"
    elseif diff<86400*30 then local w=math.floor(diff/(86400*7));  return "|cff888888"..w..(w==1 and " week" or " weeks").."|r"
    else                      local d=math.floor(diff/86400);      return "|cff666666"..d..(d==1 and " day"  or " days") .."|r"
    end
end
AltStable.FormatLastSeen = FormatLastOnline

-- The one call for a character: online now, or when it was last seen (Core).
function AltStable.FormatLastOnlineFor(char)
    if type(char) ~= "table" then return FormatLastOnline(nil, false) end
    if not AltStable.LastOnline then
        return FormatLastOnline(char.lastUpdate, char.guid == UnitGUID("player"))
    end
    return FormatLastOnline(AltStable.LastOnline(char), AltStable.IsCharacterOnline(char.guid))
end

------------------------------------------------------------
-- Bag space (#346): the Bags cell and its tooltip
------------------------------------------------------------

-- "14/72": free of total in the bags that take anything. Red when full, orange
-- with a tenth or less left. Blank until the character's first scan with it.
function AltStable.FormatBagSpace(char)
    local slots, free = tonumber(char.bags_slots), tonumber(char.bags_free)
    if not slots or not free or slots <= 0 then return "" end
    local text = free .. "/" .. slots
    if free <= 0 then return "|cffff2020" .. text .. "|r" end
    if free <= slots / 10 then return "|cffff8800" .. text .. "|r" end
    return text
end

-- A bag's name from the client, asked for once when not cached yet (the next
-- hover has it).
local bagNameAsked = {}
local function BagItemName(id)
    local n
    if C_Item and C_Item.GetItemNameByID then
        local ok, v = pcall(C_Item.GetItemNameByID, id); if ok then n = v end
    end
    if type(n) == "string" and n ~= "" then return n end
    if not bagNameAsked[id] and C_Item and C_Item.RequestLoadItemDataByID then
        bagNameAsked[id] = true
        pcall(C_Item.RequestLoadItemDataByID, id)
    end
    return nil
end

-- The item's class and its subtype in words ("Quiver", "Soul Bag"), which need
-- no item cache.
local function ItemClass(id)
    local get = AltStable.API.GetItemInfoInstant
    if not get then return nil end
    local ok, _, _, subType, _, _, classID = pcall(get, id)
    if not ok then return nil end
    return classID, subType
end

local CONTAINER_CLASS, QUIVER_CLASS = 1, 11   -- Enum.ItemClass.Container, .Quiver

local function MaxBankTabs()
    if not (C_Bank and C_Bank.FetchMaxNumBankTabs and Enum and Enum.BankType) then return nil end
    local ok, n = pcall(C_Bank.FetchMaxNumBankTabs, Enum.BankType.Character)
    n = ok and AltStable.API.PlainNumber(n) or nil
    return (n and n > 0) and n or nil
end

local SPARE_WHERE = { bags = "carried", bank = "in the bank", mail = "in the mail" }

-- The cell's tooltip: a title and ready-coloured lines. The carried bags in
-- slot order, the bank at its last visit, and the spare bags the Warband
-- plugin knows of (when it is loaded).
function AltStable.BagSpaceTooltip(char)
    local slots, free = tonumber(char.bags_slots), tonumber(char.bags_free)
    local title = (slots and free) and ("Bags: " .. free .. " free of " .. slots) or "Bags: not read yet"
    local lines = {}
    local E = (Enum and Enum.BagIndex) or {}

    local order = {}
    for k, v in pairs(char) do
        local bag = type(k) == "string" and tonumber(k:match("^bag_(%-?%d+)$"))
        if bag and type(v) == "string" then order[#order + 1] = bag end
    end
    table.sort(order)
    for _, bag in ipairs(order) do
        local item, n, family = char["bag_" .. bag]:match("^(%d+),(%d+),(%d+)$")
        item, n, family = tonumber(item), tonumber(n), tonumber(family)
        if item and item == 0 and bag ~= E.Backpack then
            lines[#lines + 1] = "|cff888888Empty bag slot|r"
        elseif item then
            local name = (bag == E.Backpack and "Backpack") or BagItemName(item) or (n .. "-slot bag")
            local line = name .. ": " .. n .. " slots"
            if bag == E.ReagentBag or family ~= 0 then
                local _, subType = ItemClass(item)
                line = line .. " |cff888888(" .. (subType or "special") .. ", not counted)|r"
            end
            lines[#lines + 1] = line
        end
    end

    lines[#lines + 1] = " "
    local tabs, bankSlots, bankFree = tonumber(char.bank_tabs), tonumber(char.bank_slots), tonumber(char.bank_free)
    if tabs and bankSlots and bankFree then
        local max = MaxBankTabs()
        local t = max and (tabs .. " of " .. max .. " tabs") or (tabs .. (tabs == 1 and " tab" or " tabs"))
        lines[#lines + 1] = "Bank: " .. t .. ", " .. bankFree .. " free of " .. bankSlots
        lines[#lines + 1] = "|cff888888Last visit:|r " .. FormatLastOnline(tonumber(char.bank_at), false)
    else
        lines[#lines + 1] = "|cff888888Bank: not visited with this version yet|r"
    end

    local ok, maps = false, nil
    if AltStable.ItemMapsFor then ok, maps = pcall(AltStable.ItemMapsFor, char.guid) end
    if ok and type(maps) == "table" then
        local spare = {}
        for _, where in ipairs({ "bags", "bank", "mail" }) do
            for id, count in pairs(type(maps[where]) == "table" and maps[where] or {}) do
                local class = ItemClass(id)
                if class == CONTAINER_CLASS or class == QUIVER_CLASS then
                    spare[#spare + 1] = { name = BagItemName(id) or ("item " .. id), count = count, where = where }
                end
            end
        end
        if #spare > 0 then
            table.sort(spare, function(a, b)
                if a.name ~= b.name then return a.name < b.name end
                return a.where < b.where
            end)
            lines[#lines + 1] = " "
            lines[#lines + 1] = "Spare bags:"
            for _, s in ipairs(spare) do
                lines[#lines + 1] = "  " .. s.name .. ((tonumber(s.count) or 1) > 1 and (" x" .. s.count) or "")
                                    .. " |cff888888(" .. SPARE_WHERE[s.where] .. ")|r"
            end
        end
    end
    return title, lines
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

-- ONE palette, in 0..1 components, with the |cff strings derived from it.
--
-- There were three copies: this one as hex, a second in the Roster detail pane
-- as RGB triples, and the tooltip's. They had already drifted - the Roster's
-- was missing Heirloom (7) entirely, so an heirloom drew with a Common white
-- border in the pane and cyan in the grid, for the same item. RGB is the
-- primary form because SetColorTexture and SetTextColor need components and a
-- hex string has to be unpacked to get them, while the reverse is one format
-- call.
AltStable.QUALITY_RGB = {
    [0] = { 0.616, 0.616, 0.616 },  -- grey   (Poor)
    [1] = { 1,     1,     1     },  -- white  (Common)
    [2] = { 0.118, 1,     0     },  -- green  (Uncommon)
    [3] = { 0,     0.439, 0.867 },  -- blue   (Rare)
    [4] = { 0.639, 0.208, 0.933 },  -- purple (Epic)
    [5] = { 1,     0.502, 0     },  -- orange (Legendary)
    [6] = { 0.902, 0.800, 0.502 },  -- gold   (Artifact)
    [7] = { 0,     0.800, 1     },  -- cyan   (Heirloom)
}

-- Always a triple, never nil: every caller was writing `or PALETTE[1]` after
-- the lookup, and the one that forgot passed nil into SetColorTexture.
function AltStable.QualityRGB(quality)
    local c = AltStable.QUALITY_RGB[tonumber(quality) or 1]
        or AltStable.QUALITY_RGB[1]
    return c[1], c[2], c[3]
end

local QUALITY_COLORS = {}
for q, c in pairs(AltStable.QUALITY_RGB) do
    QUALITY_COLORS[q] = ("|cff%02x%02x%02x"):format(
        math.floor(c[1] * 255 + 0.5),
        math.floor(c[2] * 255 + 0.5),
        math.floor(c[3] * 255 + 0.5))
end

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

-- How a hidden character looks when the sheet is listing them (#69).
--
-- Rows come from a POOL and are re-rendered by index, so this is a two-way
-- statement, never "dim it if hidden": the row drawing a dimmed hidden
-- character a frame ago draws a normal one next, and a one-way version leaves
-- a perfectly visible character greyed out for no reason the user can see.
-- That is why every renderer calls it, including the group and filler ones
-- that can never be dim - a call that is always there cannot be the one
-- somebody forgets.
local HIDDEN_ROW_ALPHA = 0.45

-- How much room there is beside the window, in PHYSICAL pixels.
--
-- Converted through effective scale rather than compared raw, for the same
-- reason the window's own screen clamp has to: the sheet carries the user's
-- scale and UIParent the client's, so their GetRight() values are numbers in
-- two different spaces and subtracting them directly is wrong by exactly the
-- ratio nobody notices at scale 1.
local function SideRoomPx(sheet)
    local ss = (sheet.GetEffectiveScale and sheet:GetEffectiveScale()) or 1
    local us = (UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1
    local sheetL = (sheet:GetLeft()  or 0) * ss
    local sheetR = (sheet:GetRight() or 0) * ss
    local screenL = (UIParent:GetLeft()  or 0) * us
    local screenR = (UIParent:GetRight() or 0) * us
    return screenR - sheetR, sheetL - screenL     -- room right, room left
end

-- Wider than any line this tooltip builds: a name, a guild, a gold figure, a
-- hint and a timestamp. A constant rather than a measurement, deliberately -
-- see AnchorRowTooltip.
local TOOLTIP_W_PX = 320

-- Where a row's tooltip opens.
--
-- Not ANCHOR_RIGHT. That anchors to the right of the NAME cell, and the name is
-- the leftmost column - so the tooltip opened on top of the table it describes
-- and, for rows near the top, across the column headers and the title bar.
-- Readable, and covering the thing you were reading.
--
-- Beside the window instead. The fallback is the old behaviour, for when there
-- is no sheet to hang off: the Roster raises this same tooltip from a card.
local function AnchorRowTooltip(owner)
    local sheet = _G["AltStableSheet"]
    if not (sheet and GameTooltip.SetPoint) then
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        return
    end
    GameTooltip:SetOwner(owner, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()

    -- WHICH SIDE is decided from the room beside the window, before the tooltip
    -- is populated - not by measuring it afterwards and flipping.
    --
    -- Measuring looked more precise and does not work: a tooltip's size is not
    -- final in the frame it is shown, so GetRight() straight after Show reads
    -- the layout it had before its lines went in. The first version of this
    -- checked exactly that, agreed with itself, and still opened half off the
    -- screen.
    --
    -- So: a conservative width, and whichever side has room for it. The width
    -- is a constant because the alternative is measuring, which is the thing
    -- that does not work here.
    local roomR, roomL = SideRoomPx(sheet)
    -- Converted too. SideRoomPx returns PHYSICAL pixels, and this constant is
    -- in the tooltip's own units - comparing them raw is the same unit mixing
    -- the comment above SideRoomPx warns about, one layer up and in the one
    -- place it is not obvious. At a high UI scale a 320-unit tooltip is far
    -- wider than 320 physical pixels, so the code would see enough room on the
    -- right, take it, and be clipped: the failure the last two attempts existed
    -- to remove.
    local ts = (GameTooltip.GetEffectiveScale and GameTooltip:GetEffectiveScale()) or 1
    local needed = TOOLTIP_W_PX * ts
    if roomR >= needed or roomR >= roomL then
        GameTooltip:SetPoint("TOPLEFT", sheet, "TOPRIGHT", 8, 0)
    else
        GameTooltip:SetPoint("TOPRIGHT", sheet, "TOPLEFT", -8, 0)
    end
end

-- The guid whose menu is open, and the guid under the cursor. Separate,
-- because they can be different characters at the same time: the menu stays on
-- the one it was opened for while the pointer wanders.
local markedGuid, hoveredGuid
local markRows = {}

local MARK_HOVER, MARK_MENU = 0.05, 0.12

-- A row is TWO frames. The name lives in the frozen column and the data in the
-- scrollable one, side by side, and they are separate objects - so a highlight
-- that lights only one of them lights half a row. Both carry `markGuid`, both
-- register, and both paint from the same two pieces of state.
--
-- The guid is set by the renderers rather than read out of a child, because
-- only the frozen half has the name button the right-click lives on: reading it
-- from there meant the scrollable half could never match.
local function PaintMark(row)
    if not row or not row.mark then return end
    local guid = row.markGuid
    if guid and guid == markedGuid then
        row.mark:SetColorTexture(1, 1, 1, MARK_MENU)
        row.mark:Show()
    elseif guid and guid == hoveredGuid then
        row.mark:SetColorTexture(1, 1, 1, MARK_HOVER)
        row.mark:Show()
    else
        row.mark:Hide()
    end
end

local function RepaintMarks()
    for row in pairs(markRows) do PaintMark(row) end
end

-- Say whose row this is, and repaint it.
--
-- Setting markGuid on its own was not enough, and the gap was the bug: rows
-- come from a POOL, so a sync record landing while the menu is open re-renders
-- the row under it as somebody else. markGuid moved; the texture did not. The
-- addon then pointed at the wrong character as "the row this right-click will
-- act on" while the menu still belonged to the old one - and the old one's new
-- row stayed dark. CharacterMenu's own comment expects exactly that refresh.
--
-- The hover is dropped when the row it belonged to becomes somebody else. The
-- cursor has not moved, so OnLeave never fires, and without this the hovered
-- guid survives a scroll and later lights whichever row happens to hold it.
local function SetRowGuid(row, guid)
    if not row then return end
    local was = row.markGuid
    row.markGuid = guid
    if was and was == hoveredGuid and guid ~= was then hoveredGuid = nil end
    PaintMark(row)
end

-- Called by the character menu when it opens and closes. A guid rather than a
-- row, because rows come from a POOL and are re-rendered by index: the row that
-- held a character when the menu opened may be showing somebody else by the
-- time it closes, and marking the row object would light the wrong name.
function AltStable.SetMenuSubject(guid)
    markedGuid = guid
    RepaintMarks()
end

AltStable._test.SetMenuSubject = AltStable.SetMenuSubject
AltStable._test.MarkedGuid = function() return markedGuid end
AltStable._test.MARK_HOVER, AltStable._test.MARK_MENU = MARK_HOVER, MARK_MENU

local function DimRow(row, char)
    if not row or not row.SetAlpha then return end
    local dim = char ~= nil and AltStable.IsCharacterHidden
        and AltStable.IsCharacterHidden(char.guid) or false
    row:SetAlpha(dim and HIDDEN_ROW_ALPHA or 1)
end

AltStable._test = AltStable._test or {}
AltStable._test.HIDDEN_ROW_ALPHA = HIDDEN_ROW_ALPHA

-- The band, from the skin.
--
-- Under glass a row does not paint a background at all - it paints a LIFT on
-- the one reading surface behind the whole table, or nothing. Twenty-one opaque
-- bands in the flat theme's charcoal was how the table came to be a slab of
-- another palette sitting inside a glass window.
--
-- `index` is the DISPLAY index, not the pooled row's slot. Rows are reused as
-- the list scrolls, so parity taken from the slot would make a row change
-- shade as it moves rather than staying with the character in it.
local function SetRowBg(row, index)
    row.bg:SetColorTexture(AltStable.SkinRowStripe(index))
end

-- Group / realm header row background
local function GetGroupBG() return AltStable.SkinGroupBand() end

------------------------------------------------------------
-- Scrollable row  (receives only the non-frozen columns)
------------------------------------------------------------

local DIVIDER_COLOR = AltStable.C.GRIDLINE

-- Row pools, one per sheet section. A pool remembers the columns its rows
-- were set up for; when they change (a faction met on Reputations, a column
-- hidden or shown, #378), its rows are set up again for the new ones
-- (AltStable.SetRowColumns), reusing the widgets each row already has for a
-- column. Frames can't be destroyed, so building fresh rows instead grew the
-- client's frames with every toggle (Codex review of #494). Frozen (Name)
-- rows don't depend on the columns.
function AltStable.RowPoolFor(pools, sectionId, columns)
    local fields = {}
    for i, col in ipairs(columns) do fields[i] = col.field end
    local signature = table.concat(fields, ",")
    local pool = pools[sectionId]
    if not pool then
        pool = { rows = {}, frozenRows = {}, signature = signature }
        pools[sectionId] = pool
    elseif pool.signature ~= signature then
        for _, row in ipairs(pool.rows) do AltStable.SetRowColumns(row, columns) end
        pool.signature = signature
    end
    return pool
end

-- THE column walk, for the header and every row alike: the first column at
-- x=10, 6px between columns, a divider in the middle of each gap. One copy,
-- so a header and the cells under it cannot be placed by two sums that drift.
-- `widths[i]` when given (the grid spread to fill a wider window, #150),
-- otherwise the column's own width.
AltStable.COLUMN_START, AltStable.COLUMN_GAP = 10, 6
function AltStable.WalkColumns(columns, widths, fn)
    local x, gap = AltStable.COLUMN_START, AltStable.COLUMN_GAP
    for i, col in ipairs(columns) do
        local w = (widths and widths[i]) or col.width
        fn(i, x, w, x + w + math.floor(gap / 2))
        x = x + w + gap
    end
end

-- A row's hover buttons, by kind; each is placed over its cell.
local TIP_SETS = { "cellTips", "repTips", "gearTips" }

-- One column's widgets on a row: its text and its hover button, keyed by
-- field on the row (row.byField) so the row can show other columns and come
-- back to this one without building it again (#378). A column's definition
-- is fixed per field, so the closures below may keep `col`.
local function MakeColumnWidgets(row, col, height)
    local w = {}
    local cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if col.type == "classIcon" or col.type == "raceIcon" then
        cell:SetJustifyH("CENTER")
    else
        cell:SetJustifyH(col.align or "LEFT")
    end
    cell:SetWordWrap(false)
    w.cell = cell

    -- General tooltip button for classIcon, raceIcon, ruleset, level, restPercent, profSkill
    if col.type=="classIcon" or col.type=="raceIcon" or col.type=="ruleset"
    or col.field=="level" or col.type=="restXP"
    or col.field=="restPercent" or col.type=="profSkill" or col.type=="bags"
    or col.type=="played" then
        local tip = CreateFrame("Button", nil, row)
        tip:SetSize(col.width, height)
        -- The Bags tooltip (#346) is built on hover, not at render: the
        -- Warband plugin's bag scan lands a second after the bag update
        -- that redrew the row, and bag names load from the item cache.
        if col.type == "bags" then
            tip.refresh = function(t)
                if t.bagsChar then t.line1, t.cdLines = AltStable.BagSpaceTooltip(t.bagsChar) end
            end
        end
        tip:SetScript("OnEnter", function()
            if tip.refresh then tip.refresh(tip) end
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
        w.cellTip = tip
    end

    -- Invisible hover button for rep cells
    if col.type == "rep" then
        local tip = CreateFrame("Button", nil, row)
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
        w.repTip = tip
    end

    -- Invisible hover button for gear slots
    if col.type == "gearSlot" then
        local tip = CreateFrame("Button", nil, row)
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
        w.gearTip = tip
    end
    return w
end

-- A row's hover buttons on or off. On only once RenderRow has filled them
-- for the character in the row: a pooled row turned filler or group band
-- would otherwise keep the last character's item under a blank cell (Codex
-- review of #494).
local function SetRowTipsShown(row, shown)
    for _, set in ipairs(TIP_SETS) do
        for _, tip in pairs(row[set] or {}) do
            if shown then tip:Show() else tip:Hide() end
        end
    end
end
AltStable._SetRowTipsShown = SetRowTipsShown

local function EachTip(w, fn)
    if w.cellTip then fn(w.cellTip) end
    if w.repTip then fn(w.repTip) end
    if w.gearTip then fn(w.gearTip) end
end

-- Sets a row up for `columns`: each column's widgets (made the first time
-- the row shows it), index by index in row.cells / cellTips / repTips /
-- gearTips, and a divider between each two. A column the row no longer shows
-- keeps its widgets, hidden and blank. Placed by LayoutRowCells: one walk for
-- every position, shared with the header (AltStable.WalkColumns).
function AltStable.SetRowColumns(row, columns)
    local height = row:GetHeight()
    row.byField = row.byField or {}
    row.cells, row.cellTips, row.repTips, row.gearTips = {}, {}, {}, {}
    local used = {}
    for i, col in ipairs(columns) do
        local key = col.field or ("#" .. i)   -- a column without a field: by place
        local w = row.byField[key]
        if not w then
            w = MakeColumnWidgets(row, col, height)
            row.byField[key] = w
        end
        used[key] = true
        row.cells[i] = w.cell
        row.cellTips[i], row.repTips[i], row.gearTips[i] = w.cellTip, w.repTip, w.gearTip
        w.cell:Show()
    end
    -- Every hover button off, the shown columns' too, until RenderRow fills them.
    for field, w in pairs(row.byField) do
        if not used[field] then w.cell:SetText(""); w.cell:Hide() end
        EachTip(w, function(t) t:Hide() end)
    end
    -- Dividers from a pool on the row; row.dividers holds only the ones in
    -- use, since rendering shows every one it holds.
    row.dividerPool = row.dividerPool or {}
    row.dividers = {}
    for i = 1, math.max(#columns - 1, 0) do
        local div = row.dividerPool[i]
        if not div then
            div = row:CreateTexture(nil, "ARTWORK")
            div:SetSize(1, height)
            div:SetColorTexture(unpack(DIVIDER_COLOR))
            row.dividerPool[i] = div
        end
        row.dividers[i] = div
    end
    for i = #row.dividers + 1, #row.dividerPool do row.dividerPool[i]:Hide() end
    AltStable.LayoutRowCells(row, columns)   -- no key: placed, and the cached widths forgotten
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

    -- Hover highlight.
    --
    -- HIGHLIGHT is a layer the client draws only while the frame is
    -- HIGHLIGHTED, and that is a Button behaviour - `row` is a plain Frame, so
    -- this texture has never had anything to switch it on. It is left in place
    -- because it costs nothing and a Button row may happen later; the mark
    -- below is what actually lights up.
    row.hover = row:CreateTexture(nil,"HIGHLIGHT")
    row.hover:SetAllPoints()
    row.hover:SetColorTexture(1,1,1,0.05)

    -- WHICH ROW A RIGHT-CLICK WILL ACT ON.
    --
    -- Two states, one texture. Hovering the name lights it faintly; opening the
    -- menu on that character holds it brighter until the menu closes.
    --
    -- The second is the one that matters and the one hover cannot do: the menu
    -- opens under the cursor, so the moment it appears the pointer is over the
    -- MENU and not over the row it belongs to. A pure hover highlight goes out
    -- exactly when you need to know which character you are about to forget.
    --
    -- ARTWORK above the class tint rather than HIGHLIGHT, so it is drawn on its
    -- own terms rather than waiting for a highlight state that never comes.
    row.mark = row:CreateTexture(nil,"ARTWORK")
    row.mark:SetAllPoints()
    row.mark:SetColorTexture(1,1,1,0.07)
    row.mark:Hide()
    markRows[row] = true

    AltStable.SetRowColumns(row, columns)
    return row
end

-- Re-place a row's cells, hover buttons and dividers for the widths the grid
-- is laid out at (#150): wider than the columns' own when the window has room
-- to spare. By AltStable.WalkColumns, the walk the header uses too; CreateRow
-- places a new row through here. Remembers what it last applied, so a row already at these widths costs
-- nothing.
function AltStable.LayoutRowCells(row, columns, widths, key)
    if key and row._widthsKey == key then return end
    local divs = row.dividers or {}
    AltStable.WalkColumns(columns, widths, function(i, x, w, divX)
        local cell = row.cells[i]
        if cell then
            cell:ClearAllPoints(); cell:SetPoint("LEFT", x, 0); cell:SetWidth(w)
        end
        for _, set in ipairs(TIP_SETS) do
            local tip = row[set] and row[set][i]
            if tip then
                tip:ClearAllPoints(); tip:SetPoint("LEFT", x, 0); tip:SetWidth(w)
            end
        end
        if divs[i] then
            divs[i]:ClearAllPoints(); divs[i]:SetPoint("LEFT", divX, 0)
        end
    end)
    row._widthsKey = key
end

-- For a scrollable group row: colour the background AND render the
-- "(Account: <name>)" label that visually continues from the realm name in
-- the frozen panel. The frozen scroll frame clips children at FROZEN_WIDTH,
-- so the label can't be a single string spanning both panels — we split it
-- intentionally. Together they read as one continuous "Dreamscythe (Account: Default)".
function AltStable.RenderGroupRow(row, item)
    -- Not a character any more, so it must not stay lit.
    SetRowGuid(row, nil)
    DimRow(row, nil)
    row.bg:SetColorTexture(GetGroupBG())
    if row.classTint then row.classTint:SetColorTexture(0,0,0,0) end
    for _, cell in ipairs(row.cells) do cell:SetText("") end
    SetRowTipsShown(row, false)

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
    -- The accounts this realm's characters actually came from, and NOTHING at
    -- all when that says nothing.
    --
    -- This used to read "(Account: Default)" on every group for everybody,
    -- because the group item never carried an account and "Default" was the
    -- fallback for nil. A label that is the same on every row is not
    -- information, and one that claims to name something it never received is
    -- worse than blank.
    --
    -- Shown only when there is more than one account in play, because that is
    -- the only time it distinguishes anything: on a single-account install
    -- every group would carry the same number, which is the old problem with a
    -- different constant in it.
    local list = item.accounts
    if type(list) == "table" and #list > 1 then
        row.groupLabel:SetText(
            "|cffaaaaaa(Accounts: |r"
            .. "|cff66ff66" .. table.concat(list, ", ") .. "|r"
            .. "|cffaaaaaa)|r"
        )
        row.groupLabel:Show()
    else
        row.groupLabel:SetText("")
        row.groupLabel:Hide()
    end
    row:Show()
end

function AltStable.RenderRow(row, char, index, columns)
    -- Rows come from a POOL and are re-rendered by index, so this has to be set
    -- on every render rather than once: the row that held a character a moment
    -- ago may be showing somebody else now, and a stale guid lights the wrong
    -- name.
    SetRowGuid(row, char and char.guid or nil)
    DimRow(row, char)
    SetRowBg(row, index)
    SetRowTipsShown(row, true)
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
                tip.line1 = AltStable.ClassDisplayName(char)
                tip.line2 = char.gender
                tip.line3 = nil
            end

        elseif col.type=="raceIcon" then
            value = RaceIconText(char.race, char.gender)
            if tip then
                tip.line1 = AltStable.RaceDisplayName(char)
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

        elseif col.type=="played" then
            -- Time played (#378): a dim dash until the character's first
            -- reading, never a 0 that reads as "never played".
            local total, level
            if AltStable.PlayedNow then total, level = AltStable.PlayedNow(char) end
            local short = total and AltStable.FormatPlayedShort(total)
            value = short or "|cff888888\226\128\148|r"
            if tip then
                if short then
                    local words, months = AltStable.FormatPlayedLong(total)
                    tip.line1 = "Played: " .. words
                    tip.line2 = level and ("At this level: " .. AltStable.FormatPlayedLong(level)) or nil
                    tip.line3 = (AltStable.PlayedIsLive and AltStable.PlayedIsLive(char))
                        and "Counting while you play"
                        or "As of when it was last played"
                    if months then tip.line3 = tip.line3 .. " (a month is 30 days, a year 365)" end
                else
                    tip.line1 = "Played: not known yet"
                    tip.line2 = "Read the next time this character logs in."
                    tip.line3 = nil
                end
            end

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
                -- Gradient: 0%=red, half the cap=yellow, the cap=green. Clamped:
                -- the logged-in character reads the live value, which can pass
                -- the cap we assume, and a negative red would print as ffffffff
                -- and break the colour code (#352).
                local half = RestedCap(char) / 2
                local r, g
                if p <= half then
                    r = 1; g = p / half
                else
                    r = 1 - math.min(1, (p - half) / half); g = 1
                end
                value = string.format("|cff%02x%02x00%d%%|r", math.floor(r*255), math.floor(g*255), p)
            end
            -- The cap needs saying (1.5 levels of XP, more with Well Rested),
            -- and a bare "to reach 150%" read like a strange target (asked by a user).
            local cap = RestedCap(char)
            if tip and not atCap then
                if p >= cap then
                    tip.line1 = "Rested XP: " .. p .. "% (full)"
                    tip.line2 = string.format("%d%% is the most%s: %s levels of XP", cap,
                        HasWellRested(char) and " with Well Rested" or "",
                        (string.format("%.2f", cap / 100):gsub("%.?0+$", "")))
                    tip.line3 = nil
                elseif p > 0 then
                    local needed  = cap - p
                    -- Time to full depends on whether the character
                    -- logged out in a rested zone.
                    local perHour = RestedPerHour(char)
                    local hours   = math.ceil(needed / perHour)
                    local days    = math.floor(hours / 24)
                    local remHour = hours % 24
                    local timeStr = days > 0 and (days.."d "..remHour.."h") or (hours.."h")
                    tip.line1 = "Rested XP: " .. p .. "% of a level (max " .. cap .. "%)"
                    if InRestedArea(char) then
                        tip.line2 = "~" .. timeStr .. " offline to fill it (in inn/city)"
                    else
                        tip.line2 = "~" .. timeStr .. " offline to fill it (open world)"
                    end
                    tip.line3 = nil
                else
                    tip.line1 = "Rested XP: 0% of a level (max " .. cap .. "%)"
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
                -- Append any craft cooldowns for this profession. The Professions
                -- plugin writes them as cd_<Profession>@<recipe name> on the
                -- record, so we match this column's profession and list whatever
                -- it holds - no allowlist. Also with no rank recorded here: the
                -- plugin can know a leatherworker (and its Salt Shaker, #460)
                -- before the core's scan has the skill.
                tip.cdLines = nil
                if col.label then
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
            value = AltStable.FormatLastOnlineFor(char)
        elseif col.type=="ruleset"      then
            value = AltStable.RulesetBadge(char)
            if tip then
                tip.line1 = AltStable.RulesetName(char)
                tip.line2, tip.line3, tip.cdLines = nil, nil, nil
            end
        elseif col.type=="money"        then value = FormatMoney(char[col.field])
        elseif col.type=="bags"         then
            value = AltStable.FormatBagSpace(char)
            if tip then
                tip.bagsChar = char   -- the lines come at hover (CreateRow)
                tip.line2, tip.line3 = nil, nil
            end
        elseif col.type=="favor"        then
            -- Blank at none, like an unlearned profession: a column of zeros
            -- for every alt that never earned any says nothing.
            local n = tonumber(char[col.field])
            value = (n and n > 0) and tostring(n) or ""
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
    -- Not a character any more, so it must not stay lit.
    SetRowGuid(row, nil)
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
    -- Not a character any more, so it must not stay lit.
    SetRowGuid(row, nil)
    DimRow(row, nil)
    SetRowBg(row, index)
    if row.classTint  then row.classTint:SetColorTexture(0,0,0,0) end
    if row.groupLabel then row.groupLabel:Hide() end
    -- Show dividers so the column lines extend visually through the empty
    -- space — like a real spreadsheet's empty rows below the last data row.
    if row.dividers then for _, d in ipairs(row.dividers) do d:Show() end end
    for _, cell in ipairs(row.cells) do cell:SetText("") end
    SetRowTipsShown(row, false)
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

    -- Which row a right-click will act on, the frozen half.
    --
    -- AFTER the class tint, like the scrollable half. Within one draw layer
    -- order is creation order, and this was created BEFORE it - so the frozen
    -- half painted the mark under the class tint while the scrollable half
    -- painted it over, and the two halves of one row lit at visibly different
    -- strengths. Which is precisely the thing "a row is two frames" was about.
    row.mark = row:CreateTexture(nil,"ARTWORK")
    row.mark:SetAllPoints()
    row.mark:SetColorTexture(1,1,1,0.07)
    row.mark:Hide()
    markRows[row] = true

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
        -- A ruleset group's header names its servers.
        local g = tipBtn.groupData
        if not tipBtn.charData and g and g.realms and #g.realms > 0 then
            AnchorRowTooltip(tipBtn)
            GameTooltip:ClearLines()
            GameTooltip:AddLine(AltStable.GroupLabel(g), 1, 1, 1)
            GameTooltip:AddLine((#g.realms > 1 and "Servers: " or "Server: ")
                .. table.concat(g.realms, ", "), 0.7, 0.7, 0.7)
            GameTooltip:Show()
            return
        end
        if not tipBtn.charData then return end
        local c = tipBtn.charData
        local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"
        AnchorRowTooltip(tipBtn)
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
        GameTooltip:AddLine("Right-click for favourite, hide, forget", 0.5,0.5,0.5)
        if c.lastUpdate then
            -- The shared rule, not a second copy of it. This one used to stop
            -- at "d ago" where the column already counted weeks, so the same
            -- character read differently in the grid and in its own tooltip.
            GameTooltip:AddLine(
                "Last seen: " .. AltStable.FormatLastOnlineFor(c),
                0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
        hoveredGuid = c.guid
        RepaintMarks()
    end)
    tipBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
        hoveredGuid = nil
        RepaintMarks()
    end)
    -- Right-click opens the character menu (#69): favourite, hide/unhide,
    -- forget. It used to go straight to "hide this character?", which spent the
    -- whole gesture on one of the four things that want it. The row only
    -- reports the click; the menu and every action behind it live elsewhere, so
    -- the Roster card can raise the same one. charData is nil on group, filler
    -- and recycled rows, so those right-clicks do nothing.
    tipBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    tipBtn:SetScript("OnClick", function(_, button)
        if button ~= "RightButton" then return end
        local c = tipBtn.charData
        if c and AltStable.ShowCharacterMenu then
            AltStable.ShowCharacterMenu(c)
        end
    end)
    row.nameTipBtn = tipBtn
    markRows[row] = true

    return row
end

function AltStable.RenderFrozenGroupRow(row, item)
    -- Not a character any more, so it must not stay lit.
    SetRowGuid(row, nil)
    DimRow(row, nil)
    row.bg:SetColorTexture(GetGroupBG())
    if row.classTint then row.classTint:SetColorTexture(0,0,0,0) end
    row.collapseBtn:Show()
    -- Frozen rows come from a shared pool and are re-rendered by index, so this
    -- row drew a CHARACTER a frame ago - collapsing a realm is enough. Leaving
    -- charData behind gave the realm header that character's tooltip, and since
    -- #21 a right-click on the header would have offered to hide it.
    if row.nameTipBtn then row.nameTipBtn.charData = nil; row.nameTipBtn.groupData = item end

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

    local key = item.key
    row.collapseBtn:SetScript("OnClick", function()
        if AltStable.ToggleGroup then AltStable.ToggleGroup(key) end
    end)

    -- Group row shows just its name (the faction, the ruleset or both) in
    -- white, bold-ish; the ruleset's servers are in its tooltip. The character
    -- count, total levels and total gold previously crammed into this label
    -- are already displayed in the totals bar — duplicating them here just
    -- made the row noisy and forced an unnecessary truncation in the
    -- frozen Name column.
    row.nameLabel:SetText(AltStable.GroupLabel(item))
    row:Show()
end

-- Faction names in the faction's colour, brighter than the client's
-- PLAYER_FACTION_COLORS so they read on the dark group band.
local FACTION_LABEL = {
    Alliance = { hex = "ff6f9bff", global = "FACTION_ALLIANCE" },
    Horde    = { hex = "ffff6060", global = "FACTION_HORDE" },
}

-- A group header's text: the faction, the ruleset, or both, faction first
-- ("Alliance · PvP"). The faction name is the client's localized one when it
-- has it.
function AltStable.GroupLabel(item)
    local parts = {}
    if item.faction then
        local f = FACTION_LABEL[item.faction]
        local name = f and rawget(_G, f.global)
        if type(name) ~= "string" or name == "" then name = item.faction end
        parts[#parts + 1] = "|c" .. (f and f.hex or "ffaaaaaa") .. name .. "|r"
    end
    if item.ruleset then
        parts[#parts + 1] = "|cffffffff" .. AltStable.RulesetGroupName(item.ruleset) .. "|r"
    end
    return table.concat(parts, "|cffaaaaaa · |r")
end

function AltStable.RenderFrozenCharRow(row, char, index)
    SetRowGuid(row, char and char.guid or nil)
    DimRow(row, char)
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
    -- Not a character any more, so it must not stay lit.
    SetRowGuid(row, nil)
    row.bg:SetColorTexture(0,0,0,0)
    if row.classTint then row.classTint:SetColorTexture(0,0,0,0) end
    row.collapseBtn:Hide()
    row.nameLabel:SetText("")
    if row.nameTipBtn then row.nameTipBtn.charData = nil; row.nameTipBtn.groupData = nil end
    row:Hide()
end

-- Filler row on the frozen side. Same alternating-bg as the scrollable
-- side filler. No name, no class icon, no collapse button.
function AltStable.RenderFrozenFillerRow(row, index)
    -- The mark clear was on every other render path but this one, so a hovered
    -- name near the end of the list left a lit white band in the empty name
    -- column when the list shortened under it - and the stale guid survived, so
    -- a later menu on that character re-lit an empty filler row at full
    -- strength.
    SetRowGuid(row, nil)
    DimRow(row, nil)
    SetRowBg(row, index)
    if row.classTint then row.classTint:SetColorTexture(0,0,0,0) end
    row.collapseBtn:Hide()
    row.nameLabel:SetText("")
    if row.nameTipBtn then row.nameTipBtn.charData = nil; row.nameTipBtn.groupData = nil end
    row:Show()
end
