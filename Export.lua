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

local HORDE_RACES = {
    Orc=true, Troll=true, Scourge=true, Tauren=true,
    BloodElf=true, Goblin=true,
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

    -- Faction from race
    local faction = HORDE_RACES[char.race] and "H" or "A"

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
    -- primary profs
    if char.prof1 and char.prof1 ~= "" then
        profSkills[char.prof1] = char.prof1Skill or ""
    end
    if char.prof2 and char.prof2 ~= "" then
        profSkills[char.prof2] = char.prof2Skill or ""
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

-- Test seam (the AltStable._test convention): the row and header builders.
AltStable._test = AltStable._test or {}
AltStable._test.ExportRow    = CharToTSV
AltStable._test.ExportHeader = BuildHeader

local function CreateExportFrame()
    if exportFrame then return end

    exportFrame = CreateFrame("Frame","AltStableExport",UIParent,"BackdropTemplate")
    exportFrame:SetSize(700, 420)
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

    local title = exportFrame:CreateFontString(nil,"OVERLAY","GameFontHighlightLarge")
    title:SetPoint("TOP",0,-16)
    title:SetText("AltStable — Export to Spreadsheet")

    local hint = exportFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    hint:SetPoint("TOP",0,-38)
    hint:SetTextColor(0.7,0.7,0.7)
    hint:SetText("Select All (Ctrl+A)  →  Copy (Ctrl+C)  →  Paste into Google Sheets column A")

    local close = CreateFrame("Button",nil,exportFrame,"UIPanelCloseButton")
    close:SetPoint("TOPRIGHT",-5,-5)

    -- Scrollable text area
    local scroll = CreateFrame("ScrollFrame","AltStableExportScroll",exportFrame,"UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", exportFrame,"TOPLEFT",   16,-60)
    scroll:SetPoint("BOTTOMRIGHT",exportFrame,"BOTTOMRIGHT",-30,14)

    local editBox = CreateFrame("EditBox",nil,scroll)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(GameFontHighlightSmall)
    editBox:SetWidth(640)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(0)  -- unlimited
    editBox:SetScript("OnEscapePressed",function() exportFrame:Hide() end)
    scroll:SetScrollChild(editBox)
    exportFrame.editBox = editBox

    -- Select-all on first click for convenience
    editBox:SetScript("OnMouseDown",function(self)
        if not self._selected then
            self:HighlightText()
            self._selected = true
        end
    end)
    editBox:SetScript("OnTextChanged",function(self)
        self._selected = false
    end)

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
    exportFrame.editBox:SetText(tsv)
    exportFrame.editBox._selected = false
    exportFrame:Show()
    exportFrame.editBox:SetFocus()
    exportFrame.editBox:HighlightText()
end