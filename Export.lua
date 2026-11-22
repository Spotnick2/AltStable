AltStable = AltStable or {}

------------------------------------------------------------
-- Column order matches the Google Sheet exactly:
-- Name | Realm | Class | Race | Faction | Level | iLvl | Account
-- Alchemy | Blacksmithing | Enchanting | Engineering | (blank: was Jewelcrafting)
-- Leatherworking | Tailoring | Herbalism | Mining | Skinning
-- Cooking | Fishing | First Aid | Riding
-- (gap cols in sheet are just empty)
-- then one column per faction in AltStable.REPUTATIONS (all of them, in order,
-- so the layout doesn't depend on which factions anyone has met)
------------------------------------------------------------

-- Fallback only, for a record scanned before char.faction existed. Skyborne is
-- in neither on purpose: it is one race key on BOTH factions, which is exactly
-- why the scan now asks the client instead of guessing from the race. Such a
-- record, or one with no race, exports a blank faction (#433), never a guess.
local HORDE_RACES = {
    Orc=true, Troll=true, Scourge=true, Tauren=true,
    BloodElf=true, Goblin=true,
}
local ALLIANCE_RACES = {
    Human=true, Dwarf=true, Gnome=true, NightElf=true, Draenei=true,
}

local REP_LETTER = {
    [1]="H",[2]="H",[3]="U",[4]="N",[5]="F",[6]="H",[7]="R",[8]="E",
}
-- More readable names
-- 1=Hated, 2=Hostile, 3=Unfriendly(U), 4=Neutral(N),
-- 5=Friendly(F), 6=Honored(H), 7=Revered(R), 8=Exalted(E)
local REP_LETTER2 = {
    [1]="X",[2]="X",[3]="U",[4]="N",[5]="F",[6]="H",[7]="R",[8]="E",
}

local GEAR_EXPORT_SLOTS = {
    { key="head",     label="He"  },
    { key="neck",     label="Ne"  },
    { key="shoulder", label="Sh"  },
    { key="back",     label="Ba"  },
    { key="chest",    label="Ch"  },
    { key="wrist",    label="Wr"  },
    { key="hands",    label="Ha"  },
    { key="waist",    label="Wa"  },
    { key="legs",     label="Le"  },
    { key="feet",     label="Fe"  },
    { key="ring1",    label="R1"  },
    { key="ring2",    label="R2"  },
    { key="trinket1", label="T1"  },
    { key="trinket2", label="T2"  },
    { key="mainhand", label="MH"  },
    { key="offhand",  label="OH"  },
    { key="ranged",   label="Ra"  },
}

local PROF_COLS = {
    "Alchemy","Blacksmithing","Enchanting","Engineering",
    "",   -- was Jewelcrafting: kept blank so the sheet's columns don't shift
    "Leatherworking","Tailoring",
    "Herbalism","Mining","Skinning",
    "Cooking","Fishing","First Aid","Riding",
}

local PROF_FIELD = {
    ["Cooking"]   = "cooking",
    ["Fishing"]   = "fishing",
    ["First Aid"] = "firstAid",
    ["Riding"]    = "riding",
}

local function RepCols()
    local out = {}
    for _, r in ipairs(AltStable.REPUTATIONS or {}) do
        out[#out + 1] = { label = r.label, field = AltStable.RepField(r.id) }
    end
    return out
end

------------------------------------------------------------
-- Build TSV row for one character
------------------------------------------------------------

local function CharToTSV(char)
    local t = "\t"

    -- What the client said at scan time, falling back to the race for a
    -- record that predates it - when the race belongs to one side.
    local faction
    if char.faction == "Horde" then faction = "H"
    elseif char.faction == "Alliance" then faction = "A"
    elseif HORDE_RACES[char.race] then faction = "H"
    elseif ALLIANCE_RACES[char.race] then faction = "A"
    else faction = "" end

    -- iLvl rounded to 1 decimal
    local ilvlStr = char.ilvl and string.format("%.1f", char.ilvl) or ""

    local row = {
        char.name   or "",
        char.realm  or "",
        char.class  or "",
        char.race   or "",
        faction,
        char.level  or "",
        ilvlStr,
        char.account or "",
    }

    -- Gear slots
    for _, g in ipairs(GEAR_EXPORT_SLOTS) do
        local v = char["gear_"..g.key]
        table.insert(row, (v and v > 0) and tostring(v) or "")
    end

    -- Primary professions: find which named column each maps to
    local profSkills = {}
    -- Primary profs, from each one's own field (#177): prof1/prof2 held ONE
    -- profession twice for anyone scanned before the fix, or synced from a
    -- peer still running it, and the second was lost. prof_<Name> was right.
    for _, name in ipairs(PROF_COLS) do
        local v = name ~= "" and char["prof_" .. name]
        if type(v) == "number" and v > 0 then profSkills[name] = v end
    end
    -- secondary profs stored directly
    profSkills["Cooking"]   = (char.cooking   and char.cooking   > 0) and char.cooking   or ""
    profSkills["Fishing"]   = (char.fishing   and char.fishing   > 0) and char.fishing   or ""
    profSkills["First Aid"] = (char.firstAid  and char.firstAid  > 0) and char.firstAid  or ""
    profSkills["Riding"]    = (char.riding    and char.riding    > 0) and char.riding    or ""

    for _, profName in ipairs(PROF_COLS) do
        table.insert(row, tostring(profSkills[profName] or ""))
    end

    -- Reputation columns
    for _, repCol in ipairs(RepCols()) do
        local val = char[repCol.field]
        table.insert(row, val and REP_LETTER2[val] or "")
    end

    return table.concat(row, t)
end

------------------------------------------------------------
-- Build header row
------------------------------------------------------------

local function BuildHeader()
    local cols = {
        "Name","Realm","Class","Race","Faction","Level","iLvl","Account",
    }
    for _, g in ipairs(GEAR_EXPORT_SLOTS) do
        table.insert(cols, g.label)
    end
    for _, p in ipairs(PROF_COLS) do
        table.insert(cols, p)
    end
    for _, r in ipairs(RepCols()) do
        table.insert(cols, r.label)
    end
    return table.concat(cols, "\t")
end

------------------------------------------------------------
-- Export popup frame
------------------------------------------------------------

local exportFrame

-- The window's words (#470), plain ASCII beyond the title's dash: the game's
-- fonts draw an arrow, or a tab, as a box.
local HOW_SELECTED = "Selected. Press Ctrl+C now, then paste into cell A1 of a Google Sheet:"
    .. " the columns split by themselves."
local HOW_LOST = "Not selected any more: click Select again, then press Ctrl+C."
local COMPANION_TIP = {
    "A Google Sheet, kept for you",
    "AltStable Companion, the desktop app, writes your characters to a spreadsheet in your own"
        .. " Google Drive: characters, skills, reputations and gear, rewritten after each save."
        .. " It is off until you connect it, in the app's Settings.",
    "Click for the download link.",
}

-- Test seam (the AltStable._test convention): the row and header builders.
AltStable._test = AltStable._test or {}
AltStable._test.ExportRow    = CharToTSV
AltStable._test.ExportHeader = BuildHeader

local function CreateExportFrame()
    if exportFrame then return end

    exportFrame = CreateFrame("Frame","AltStableExport",UIParent,"BackdropTemplate")
    exportFrame:SetSize(460, 190)
    exportFrame:SetPoint("CENTER")
    exportFrame:SetFrameStrata("DIALOG")
    exportFrame:SetToplevel(true)
    exportFrame:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
        tile=true,tileSize=16,edgeSize=32,
        insets={left=8,right=8,top=8,bottom=8},
    })
    exportFrame:SetBackdropColor(0.05,0.05,0.08,0.97)
    exportFrame:SetMovable(true)
    exportFrame:EnableMouse(true)
    exportFrame:RegisterForDrag("LeftButton")
    exportFrame:SetScript("OnDragStart",exportFrame.StartMoving)
    exportFrame:SetScript("OnDragStop", exportFrame.StopMovingOrSizing)
    tinsert(UISpecialFrames,"AltStableExport")
    -- Back under UIParent once closed (#434), as the character menu does: a
    -- frame left lifted would stay out of the hierarchy the showcase restores.
    exportFrame:SetScript("OnHide", function(self)
        if AltStable.LiftAboveHiddenUI then AltStable.LiftAboveHiddenUI(self, false) end
    end)

    local title = exportFrame:CreateFontString(nil,"OVERLAY","GameFontHighlightLarge")
    title:SetPoint("TOP",0,-16)
    title:SetText("AltStable — Export to Spreadsheet")

    -- What is ready, and what to do with it (#470). Only characters the
    -- game's fonts draw: an arrow came out as a box.
    local status = exportFrame:CreateFontString(nil,"OVERLAY","GameFontHighlight")
    status:SetPoint("TOP",0,-52)
    status:SetWidth(400)
    exportFrame.status = status

    local how = exportFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
    how:SetPoint("TOP",status,"BOTTOM",0,-10)
    how:SetWidth(400)
    exportFrame.how = how

    local close = CreateFrame("Button",nil,exportFrame,"UIPanelCloseButton")
    close:SetPoint("TOPRIGHT",-5,-5)

    -- The companion keeps a Google Sheet for you (#470): said beside the close
    -- button, on hover; a click gives the download link to copy.
    local info = CreateFrame("Button",nil,exportFrame)
    info:SetSize(16,16)
    info:SetPoint("RIGHT",close,"LEFT",-2,0)
    info:SetNormalTexture("Interface\\FriendsFrame\\InformationIcon")
    info:SetHighlightTexture("Interface\\FriendsFrame\\InformationIcon-Highlight")
    info:SetScript("OnEnter",function(self)
        GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
        for i, line in ipairs(COMPANION_TIP) do
            if i == 1 then GameTooltip:SetText(line,1,1,1)
            else GameTooltip:AddLine(line,nil,nil,nil,true) end
        end
        GameTooltip:Show()
    end)
    info:SetScript("OnLeave",function() GameTooltip:Hide() end)
    info:SetScript("OnClick",function()
        if AltStable.ShowCopyText and AltStable.COMPANION_URL then
            AltStable.ShowCopyText("AltStable Companion keeps a Google Sheet of your alts. "
                .. "Copy the link (Ctrl+C) and open it in your browser:", AltStable.COMPANION_URL)
        end
    end)
    exportFrame.info = info

    -- The TSV itself, never drawn (#470). Its columns are separated by tabs,
    -- which is what makes Google Sheets split a paste into columns, and the
    -- game's fonts draw a tab as a box. Addons can't write the clipboard on
    -- Forever (CopyToClipboard is forbidden), so the text sits here selected
    -- and focused, invisible, for the player's Ctrl+C - and typing can't
    -- change it.
    local editBox = CreateFrame("EditBox",nil,exportFrame)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(GameFontHighlightSmall)
    editBox:SetSize(400, 14)
    editBox:SetPoint("BOTTOM",0,14)
    editBox:SetAlpha(0)
    editBox:EnableMouse(false)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(0)  -- unlimited
    editBox:SetScript("OnEscapePressed",function() exportFrame:Hide() end)
    editBox:SetScript("OnTextChanged",function(self, userInput)
        if userInput and self.fixed then self:SetText(self.fixed); self:HighlightText() end
    end)
    editBox:SetScript("OnEditFocusGained",function(self)
        self:HighlightText()
        how:SetText(HOW_SELECTED)
    end)
    editBox:SetScript("OnEditFocusLost",function()
        how:SetText(HOW_LOST)
    end)
    exportFrame.editBox = editBox

    local again = CreateFrame("Button",nil,exportFrame,"UIPanelButtonTemplate")
    again:SetSize(140,24)
    again:SetPoint("BOTTOM",0,20)
    again:SetText("Select again")
    again:SetScript("OnClick",function()
        editBox:SetFocus()
        editBox:HighlightText()
    end)
    exportFrame.again = again

    exportFrame:Hide()
end

------------------------------------------------------------
-- Public: open the export window with fresh TSV data
------------------------------------------------------------

function AltStable.ShowExport()
    CreateExportFrame()

    -- Sort characters: realm, then level desc
    local chars = {}
    for _, c in pairs(AltStableDB) do
        if type(c)=="table" and c.name then
            table.insert(chars, c)
        end
    end
    table.sort(chars, function(a,b)
        local ra = a.realm or ""
        local rb = b.realm or ""
        if ra ~= rb then return ra < rb end
        return (a.level or 0) > (b.level or 0)
    end)

    local lines = { BuildHeader() }
    for _, char in ipairs(chars) do
        table.insert(lines, CharToTSV(char))
    end

    local tsv = table.concat(lines, "\n")
    local columns = 1
    for _ in lines[1]:gmatch("\t") do columns = columns + 1 end
    exportFrame.status:SetText(("Ready to copy: %d %s, %d columns."):format(
        #chars, #chars == 1 and "character" or "characters", columns))
    exportFrame.editBox.fixed = tsv
    exportFrame.editBox:SetText(tsv)
    -- With the game UI hidden (the showcase), a child of UIParent is invisible
    -- whatever its strata (#434): lift it out, the same door the character
    -- menu uses. Not hidden: false drops a lift left from before.
    if AltStable.LiftAboveHiddenUI and AltStable.IsGameUIHidden then
        AltStable.LiftAboveHiddenUI(exportFrame, AltStable.IsGameUIHidden())
    end
    exportFrame:Show()
    -- ABOVE THE SHEET. Both are DIALOG and both are toplevel, so whichever was
    -- raised last wins - and clicking the sheet raises it. That was survivable
    -- while the sheet let clicks through to whatever was under it; since it
    -- takes the mouse (#74) an export window left underneath is dead in the
    -- overlap, which is most of it.
    if exportFrame.Raise then exportFrame:Raise() end
    exportFrame.editBox:SetFocus()
    exportFrame.editBox:HighlightText()
    exportFrame.how:SetText(HOW_SELECTED)
end