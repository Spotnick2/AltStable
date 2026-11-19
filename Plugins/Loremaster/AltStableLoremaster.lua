------------------------------------------------------------
-- AltStableLoremaster - quest progress by zone for every alt (#374, #372)
--
-- SPDX-License-Identifier: GPL-3.0-or-later (see NOTICE.md).
--
-- The tab: zones down the side in collapsible groups (Eastern Kingdoms,
-- Kalimdor, elsewhere, dungeons, raids, battlegrounds, the Class quests row,
-- professions, other), characters across, "27/30" in a cell. Hovering a cell
-- lists the quests still open, by level, and the ones missed. The totals bar
-- carries the character playing's own total.
--
-- The counting is Loremaster.lua's. This file only shows snapshots:
-- AltStableLoremasterDB.chars, one per character, from its own last login or
-- from sync. A character never scanned has no column, never a row of zeros.
--
-- LoadOnDemand: registers on PLAYER_LOGIN, or right away when enabled later.
------------------------------------------------------------

local M = AltStable.Loremaster
local D = AltStable.LoremasterData

local ADDON_ID = "loremaster"
local L = { pools = {} }
M.UI = L

local PAD       = 10
local HEADER_H  = 38      -- title row
local COLHDR_H  = 24      -- the characters' names
local ROW_H     = 20
local GROUP_H   = 22
local NAME_W    = 200
local COL_W     = 58
local HBAR_H    = 12
local MAX_TIP   = 20      -- open quests listed in a tooltip
local PREFERRED_PANEL_W = 900
local MIN_PANEL_W, MIN_PANEL_H = 460, 360

local GOLD = { 1, 0.82, 0 }

-- The groups, in order. A zone's group is its continent's.
L.GROUPS = {
    { key = "EK",           label = "Eastern Kingdoms" },
    { key = "KAL",          label = "Kalimdor" },
    { key = "FOREVER",      label = "Elsewhere" },
    { key = "dungeon",      label = "Dungeons" },
    { key = "raid",         label = "Raids" },
    { key = "battleground", label = "Battlegrounds" },
    { key = "class",        label = "Class" },
    { key = "profession",   label = "Professions" },
    { key = "other",        label = "Other" },
}

local panel, scroll, content, titleFS, emptyFS, vbar, hbar, thisCheck

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function Api(ns, name)
    local t = rawget(_G, ns)
    return type(t) == "table" and t[name] or nil
end

local function Color(key, fallback)
    local c = AltStable.C and AltStable.C[key]
    return c or fallback
end

local function ClassHex(class)
    if AltStable.ClassColor and class then return AltStable.ClassColor(class) end
    return "|cffffffff"
end

local function HideTip() GameTooltip:Hide() end

local function FS(parent, template, justify)
    local f = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    f:SetJustifyH(justify or "LEFT")
    return f
end

local function Pct(done, total)
    if total <= 0 then return 0 end
    return math.floor(100 * done / total + 0.5)
end

-- "27/30 · 90%"
function L.ProgressText(done, total)
    return ("%d/%d \194\183 %d%%"):format(done, total, Pct(done, total))
end

-- A row's group key.
function L.GroupOf(key)
    local z = D.ZONES[key]
    if not z then return nil end
    if z[1] == "zone" then return z[2] or "FOREVER" end
    return z[1]
end

-- A row's name, the client's own (localized) where it has the map.
local nameCache = {}
function L.ZoneName(key)
    if nameCache[key] then return nameCache[key] end
    local z = D.ZONES[key]
    if not z then return tostring(key) end
    local name = z[4]
    local uiMapID = z[3]
    local get = Api("C_Map", "GetMapInfo")
    if uiMapID and get then
        local ok, info = pcall(get, uiMapID)
        if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then name = info.name end
    end
    nameCache[key] = name
    return name
end

-- A cell's colour: complete is gold, the rest fades with what is left.
function L.CellRGB(done, total)
    if total > 0 and done >= total then return GOLD[1], GOLD[2], GOLD[3] end
    local f = total > 0 and done / total or 0
    local v = 0.55 + 0.4 * f
    return v, v, v
end

------------------------------------------------------------
-- The model: columns and rows from the snapshots
------------------------------------------------------------

-- Characters with a snapshot, the sheet's hidden ones left out. The one
-- playing first, then by level and name. "This character": the one playing.
function L.Columns()
    local db = M.DB()
    local me = UnitGUID and UnitGUID("player")
    local out = {}
    for guid, snap in pairs(db.chars) do
        local c = AltStableDB and AltStableDB[guid]
        if type(snap) == "table" and type(c) == "table" and c.name
           and not (AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(guid))
           and (not db.thisChar or guid == me) then
            out[#out + 1] = { guid = guid, name = c.name, class = c.class, snap = snap,
                              level = tonumber(snap.level) or tonumber(c.level) or 0, isMe = guid == me }
        end
    end
    table.sort(out, function(a, b)
        if a.isMe ~= b.isMe then return a.isMe end
        if a.level ~= b.level then return a.level > b.level end
        return a.name < b.name
    end)
    return out
end

-- Characters AltStable holds that Loremaster has not scanned yet.
function L.Unscanned()
    local db, n = M.DB(), 0
    for guid, c in pairs(AltStableDB or {}) do
        if type(c) == "table" and c.name and not db.chars[guid]
           and (c.scannedHere or c.provKind == "own-account")
           and not (AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(guid)) then
            n = n + 1
        end
    end
    return n
end

-- The display list: a group header, then its rows, for every row some column
-- has quests in. Collapsed groups keep their header.
function L.DisplayRows(cols)
    local present = {}
    for _, col in ipairs(cols) do
        for key in pairs(col.snap.c or {}) do
            if D.ZONES[key] then present[key] = true end
        end
    end
    local byGroup = {}
    for key in pairs(present) do
        local g = L.GroupOf(key)
        if g then
            byGroup[g] = byGroup[g] or {}
            table.insert(byGroup[g], key)
        end
    end
    local collapsed = M.DB().collapsed
    local out = {}
    for _, g in ipairs(L.GROUPS) do
        local keys = byGroup[g.key]
        if keys then
            table.sort(keys, function(a, b) return D.ZONES[a][5] < D.ZONES[b][5] end)
            out[#out + 1] = { isGroup = true, key = g.key, label = g.label, n = #keys }
            if not collapsed[g.key] then
                for _, key in ipairs(keys) do out[#out + 1] = { key = key } end
            end
        end
    end
    return out
end

-- One character's total over every row, and its Class row.
function L.Totals(snap)
    local done, total = 0, 0
    for _, row in pairs(snap and snap.c or {}) do
        done, total = done + row[1], total + row[2]
    end
    return done, total
end

------------------------------------------------------------
-- The tooltip's lists: only for a character whose done set this install
-- holds, from the same snapshot the cell shows
------------------------------------------------------------

local listCache = {}
function L.ListsFor(col)
    local db = M.DB()
    local mine = db.done[col.guid]
    local snap = col.snap
    if type(mine) ~= "table" or not mine.ids or mine.stamp ~= snap.stamp or snap.ver ~= D.VERSION then
        return nil
    end
    local cacheKey = col.guid .. ":" .. tostring(snap.stamp)
    if listCache[col.guid] and listCache[col.guid].key == cacheKey then return listCache[col.guid].lists end
    local p = { faction = snap.faction, race = snap.race, class = snap.class, level = snap.level }
    local lists = M.Count(p, mine.ids, true).lists
    listCache[col.guid] = { key = cacheKey, lists = lists }
    return lists
end

local function QuestLine(id, level)
    local q = D.QUESTS[id]
    local name = q and q[7] or ("Quest " .. id)
    local req = q and q[3] or 0
    local title = Api("C_QuestLog", "GetTitleForQuestID")
    if title then
        local ok, t = pcall(title, id)
        if ok and type(t) == "string" and t ~= "" then name = t end
    end
    return ("[%d] %s"):format(req, name), req > (level or 0)
end

function L.CellOnEnter(self)
    local info = self.info
    if not info then return end
    local col, key, row = info.col, info.key, info.row
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(L.ZoneName(key), 1, 1, 1)
    GameTooltip:AddLine(ClassHex(col.class) .. col.name .. "|r")
    GameTooltip:AddLine(L.ProgressText(row[1], row[2]), 0.9, 0.9, 0.9)
    if key == D.CLASS_KEY and col.snap.cls then
        GameTooltip:AddLine(("%d available at level %d"):format(col.snap.cls.now or 0, col.level), 0.7, 0.7, 0.7)
    end
    if col.snap.ver ~= D.VERSION then
        GameTooltip:AddLine("Counted with another version of the quest list.", 0.6, 0.6, 0.6, true)
    end
    local lists = L.ListsFor(col)
    local l = lists and lists[key]
    if l then
        if #l.open > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(("Still to do (%d)"):format(#l.open), GOLD[1], GOLD[2], GOLD[3])
            for i = 1, math.min(#l.open, MAX_TIP) do
                local text, high = QuestLine(l.open[i], col.level)
                if high then GameTooltip:AddLine(text, 0.5, 0.5, 0.5) else GameTooltip:AddLine(text, 0.9, 0.9, 0.9) end
            end
            if #l.open > MAX_TIP then
                GameTooltip:AddLine(("and %d more"):format(#l.open - MAX_TIP), 0.6, 0.6, 0.6)
            end
        end
        if #l.missed > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(("Missed, no longer available (%d)"):format(#l.missed), 0.7, 0.5, 0.5)
            for i = 1, math.min(#l.missed, 5) do
                GameTooltip:AddLine((QuestLine(l.missed[i], col.level)), 0.5, 0.5, 0.5)
            end
            if #l.missed > 5 then GameTooltip:AddLine(("and %d more"):format(#l.missed - 5), 0.5, 0.5, 0.5) end
        end
    elseif row[1] < row[2] then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("The quests themselves show once this character logs in here.", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
end

local function HeaderOnEnter(self)
    local col = self.col
    if not col then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(ClassHex(col.class) .. col.name .. "|r")
    GameTooltip:AddLine("Level " .. col.level, 0.7, 0.7, 0.7)
    local done, total = L.Totals(col.snap)
    GameTooltip:AddLine("Loremaster: " .. L.ProgressText(done, total), 0.9, 0.9, 0.9)
    if col.snap.completed then
        GameTooltip:AddLine(("%d quests completed in all"):format(col.snap.completed), 0.7, 0.7, 0.7)
    end
    if col.snap.log then GameTooltip:AddLine(("%d in the quest log"):format(col.snap.log), 0.7, 0.7, 0.7) end
    GameTooltip:Show()
end

------------------------------------------------------------
-- Widgets, pooled by kind
------------------------------------------------------------

local function Acquire(kind, make)
    local pool = L.pools[kind]
    if not pool then pool = { list = {}, used = 0 }; L.pools[kind] = pool end
    pool.used = pool.used + 1
    local w = pool.list[pool.used]
    if not w then w = make(); pool.list[pool.used] = w end
    w:Show()
    return w
end

local function ReleaseAll()
    for _, pool in pairs(L.pools) do
        for i = 1, #pool.list do pool.list[i]:Hide() end
        pool.used = 0
    end
end

local function MakeCell()
    local cell = CreateFrame("Frame", nil, content)
    cell:SetSize(COL_W, ROW_H)
    cell.text = FS(cell, "GameFontHighlightSmall", "CENTER")
    cell.text:SetPoint("CENTER")
    cell:EnableMouse(true)
    cell:SetScript("OnEnter", L.CellOnEnter)
    cell:SetScript("OnLeave", HideTip)
    return cell
end

local function MakeRowLabel()
    local f = CreateFrame("Frame", nil, content)
    f:SetSize(NAME_W, ROW_H)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.text = FS(f, "GameFontHighlightSmall")
    f.text:SetPoint("LEFT", f, "LEFT", 14, 0)
    f.text:SetPoint("RIGHT", f, "RIGHT", -4, 0)
    f.text:SetWordWrap(false)
    return f
end

local function MakeGroup()
    local g = CreateFrame("Button", nil, content)
    g:SetHeight(GROUP_H)
    g.bg = g:CreateTexture(nil, "BACKGROUND")
    g.bg:SetAllPoints()
    g.label = FS(g, "GameFontNormal")
    g.label:SetPoint("LEFT", g, "LEFT", 4, 0)
    g.sep = g:CreateTexture(nil, "OVERLAY")
    g.sep:SetHeight(1)
    g.sep:SetPoint("BOTTOMLEFT", 0, 0)
    g.sep:SetPoint("BOTTOMRIGHT", 0, 0)
    g:SetScript("OnClick", function(self)
        local c = M.DB().collapsed
        c[self.key] = (not c[self.key]) and true or nil
        L.Render()
    end)
    return g
end

local function MakeHeader()
    local b = CreateFrame("Button", nil, panel)
    b:SetSize(COL_W, COLHDR_H)
    b.text = FS(b, "GameFontHighlightSmall", "CENTER")
    b.text:SetAllPoints()
    b:SetScript("OnEnter", HeaderOnEnter)
    b:SetScript("OnLeave", HideTip)
    return b
end

------------------------------------------------------------
-- Column headers: first names, a surname initial where two would collide
-- (as the Raids tab does)
------------------------------------------------------------

local function FirstChars(s, n)
    local i, taken = 1, 0
    while i <= #s and taken < n do
        local b = s:byte(i)
        i = i + ((b < 0x80 and 1) or (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4)
        taken = taken + 1
    end
    return s:sub(1, i - 1)
end

function L.HeaderNames(cols)
    local out, first, surname, counts = {}, {}, {}, {}
    for i, col in ipairs(cols) do
        first[i] = FirstChars((col.name or "?"):match("^(%S+)") or "?", 8)
        surname[i] = (col.name or ""):match("^%S+%s+(%S+)") or ""
        out[i] = first[i]
        counts[out[i]] = (counts[out[i]] or 0) + 1
    end
    for i = 1, #out do
        if counts[first[i]] > 1 and surname[i] ~= "" then out[i] = first[i] .. " " .. FirstChars(surname[i], 1) end
    end
    return out
end

------------------------------------------------------------
-- Render
------------------------------------------------------------

function L.VisibleColumns()
    local w = panel and panel:GetWidth() or PREFERRED_PANEL_W
    return math.max(1, math.floor((w - 2 * PAD - 14 - NAME_W) / COL_W))
end

function L.Render()
    if not panel then return end
    ReleaseAll()
    local cols = L.Columns()
    L.cols = cols
    local nVis = math.min(#cols, L.VisibleColumns())
    local maxOffset = math.max(0, #cols - nVis)
    L.colOffset = math.min(L.colOffset or 0, maxOffset)
    local x0 = NAME_W

    -- Column headers (frozen above the scroll).
    local names = L.HeaderNames(cols)
    for i = 1, nVis do
        local col = cols[L.colOffset + i]
        local h = Acquire("header", MakeHeader)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + x0 + (i - 1) * COL_W, -HEADER_H)
        h.text:SetText(ClassHex(col.class) .. names[L.colOffset + i] .. "|r")
        h.col = col
    end

    if #cols == 0 then
        emptyFS:SetText(L.Unscanned() > 0
            and "|cff888888No character counted yet: log in on each one once with Loremaster on.|r"
            or "|cff888888No character counted yet.|r")
        emptyFS:Show()
    else
        emptyFS:Hide()
    end

    local rows = L.DisplayRows(cols)
    local y = 0
    local width = x0 + nVis * COL_W
    local C = AltStable.C or {}
    local accent = C.ACCENT or GOLD
    for idx, r in ipairs(rows) do
        if r.isGroup then
            local g = Acquire("group", MakeGroup)
            g:ClearAllPoints()
            g:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            g:SetWidth(width)
            g.key = r.key
            local collapsed = M.DB().collapsed[r.key]
            g.label:SetText((collapsed and "+ " or "\226\128\147 ") .. r.label
                .. (collapsed and (" |cff888888(" .. r.n .. ")|r") or ""))
            g.bg:SetColorTexture(1, 1, 1, 0.06)
            g.sep:SetColorTexture(accent[1], accent[2], accent[3], 0.6)
            y = y + GROUP_H
        else
            local label = Acquire("label", MakeRowLabel)
            label:ClearAllPoints()
            label:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            label.text:SetText(L.ZoneName(r.key))
            label.bg:SetColorTexture(1, 1, 1, idx % 2 == 0 and 0.03 or 0)
            for i = 1, nVis do
                local col = cols[L.colOffset + i]
                local row = col.snap.c and col.snap.c[r.key]
                local cell = Acquire("cell", MakeCell)
                cell:ClearAllPoints()
                cell:SetPoint("TOPLEFT", content, "TOPLEFT", x0 + (i - 1) * COL_W, -y)
                if row then
                    cell.text:SetText(("%d/%d"):format(row[1], row[2]))
                    cell.text:SetTextColor(L.CellRGB(row[1], row[2]))
                    cell.info = { col = col, key = r.key, row = row }
                else
                    cell.text:SetText("")
                    cell.info = nil
                end
            end
            y = y + ROW_H
        end
    end
    content:SetSize(math.max(width, 1), math.max(y, 1))

    -- Vertical scrollbar.
    local viewH = scroll:GetHeight() or 0
    local maxV = math.max(0, y - viewH)
    if maxV > 0 then
        vbar:SetMinMaxValues(0, maxV)
        if (vbar:GetValue() or 0) > maxV then vbar:SetValue(maxV) end
        vbar:Show()
    else
        vbar:SetValue(0)
        scroll:SetVerticalScroll(0)
        vbar:Hide()
    end

    -- Horizontal: whole columns at a time.
    if maxOffset > 0 then
        hbar:SetMinMaxValues(0, maxOffset)
        hbar:SetValue(L.colOffset)
        hbar:Show()
    else
        hbar:Hide()
    end

    if thisCheck then thisCheck:SetChecked(M.DB().thisChar and true or false) end
    L.RenderFooter()
end

------------------------------------------------------------
-- Panel
------------------------------------------------------------

function L.ApplyTheme()
    local tex = L.backing
    if not tex then return end
    local glass = AltStable.SkinIsGlass and AltStable.SkinIsGlass()
    if glass and AltStable.SkinDataColor then
        tex:SetColorTexture(unpack(AltStable.SkinDataColor()))
        tex:Show()
    else
        tex:Hide()
    end
end

function L.BuildPanel(mainFrame)
    if panel then return end
    local layout = AltStable.LAYOUT or {}
    local sidebarW = layout.SIDEBAR_WIDTH or 230
    local titleH = layout.TITLE_H or 30
    local footerH = layout.FOOTER_HEIGHT or 22
    panel = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    if not (AltStable.AnchorBesideSidebar and AltStable.AnchorBesideSidebar(panel, mainFrame)) then
        panel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", sidebarW + 1, -titleH)
    end
    panel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, footerH + 1)
    local bg = Color("BG_MAIN", { 0.05, 0.05, 0.05, 0.95 })
    if not (AltStable.SkinPanelFill and AltStable.SkinPanelFill(panel, mainFrame, bg)) and AltStable.ApplyBGOnly then
        AltStable.ApplyBGOnly(panel, bg[1], bg[2], bg[3], bg[4])
    end
    panel:Hide()

    titleFS = FS(panel, "GameFontNormalLarge")
    titleFS:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + 4, -12)
    titleFS:SetText("Loremaster")
    titleFS:SetTextColor(unpack(Color("TEXT_BRIGHT", { 1, 1, 1 })))

    -- "This character": only the one playing.
    thisCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    thisCheck:SetSize(18, 18)
    thisCheck:SetScript("OnClick", function(self)
        M.DB().thisChar = self:GetChecked() and true or nil
        L.colOffset = 0
        L.Render()
    end)
    thisCheck.label = FS(panel, "GameFontNormalSmall")
    thisCheck.label:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD - 4, -16)
    thisCheck.label:SetText("This character")
    thisCheck.label:SetTextColor(unpack(Color("TEXT_DIM", { 0.7, 0.7, 0.7 })))
    thisCheck:SetPoint("RIGHT", thisCheck.label, "LEFT", -2, 0)

    local top = HEADER_H + COLHDR_H + 2
    scroll = CreateFrame("ScrollFrame", nil, panel)
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -top)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD - 14, HBAR_H + 6)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    -- An opaque reading surface under glass, as the sheet's own and Legacy's.
    L.backing = panel:CreateTexture(nil, "BACKGROUND", nil, -3)
    L.backing:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -HEADER_H + 4)
    L.backing:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
    L.ApplyTheme()
    if AltStable.RegisterThemeCallback and not L._themeHooked then
        AltStable.RegisterThemeCallback(function() L.ApplyTheme(); if L.isActive then L.Render() end end)
        L._themeHooked = true
    end

    emptyFS = FS(panel, "GameFontHighlightSmall")
    emptyFS:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + 4, -(HEADER_H + 4))
    emptyFS:Hide()

    vbar = CreateFrame("Slider", nil, panel)
    vbar:SetWidth(10)
    vbar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -top)
    vbar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, HBAR_H + 6)
    vbar:SetOrientation("VERTICAL")
    vbar:SetValueStep(1)
    local track = vbar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(1, 1, 1, 0.05)
    local thumb = vbar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(1, 1, 1, 0.28)
    thumb:SetSize(10, 32)
    vbar:SetThumbTexture(thumb)
    vbar:SetScript("OnValueChanged", function(_, value) scroll:SetVerticalScroll(value or 0) end)
    vbar:Hide()

    hbar = CreateFrame("Slider", nil, panel)
    hbar:SetHeight(HBAR_H)
    hbar:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PAD + NAME_W, 4)
    hbar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD - 14, 4)
    hbar:SetOrientation("HORIZONTAL")
    hbar:SetValueStep(1)
    local htrack = hbar:CreateTexture(nil, "BACKGROUND")
    htrack:SetAllPoints()
    htrack:SetColorTexture(1, 1, 1, 0.05)
    local hthumb = hbar:CreateTexture(nil, "OVERLAY")
    hthumb:SetColorTexture(1, 1, 1, 0.28)
    hthumb:SetSize(32, HBAR_H)
    hbar:SetThumbTexture(hthumb)
    hbar:SetScript("OnValueChanged", function(_, value)
        value = math.floor((value or 0) + 0.5)
        if value ~= L.colOffset then L.colOffset = value; L.Render() end
    end)
    hbar:Hide()

    panel:SetScript("OnShow", function() if L.isActive then L.Render() end end)
    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(_, delta)
        local shift = rawget(_G, "IsShiftKeyDown")
        if shift and shift() and hbar:IsShown() then
            hbar:SetValue((L.colOffset or 0) - delta)
        elseif vbar:IsShown() then
            vbar:SetValue((vbar:GetValue() or 0) - delta * 3 * ROW_H)
        end
    end)
end

------------------------------------------------------------
-- The footer: the character playing's total, in the sheet's totals bar
------------------------------------------------------------

function L.BuildFooter(mainFrame)
    local tb = mainFrame and mainFrame.totalsBar
    if L.foot or not tb then return end
    local f = CreateFrame("Frame", nil, tb)
    f:SetAllPoints(tb)
    f:Hide()
    f.left = FS(f, "GameFontHighlightSmall")
    f.left:SetPoint("LEFT", f, "LEFT", 10, 0)
    f.right = FS(f, "GameFontHighlightSmall", "RIGHT")
    f.right:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    L.foot = f
end

function L.RenderFooter()
    local f = L.foot
    if not f then return end
    local me = UnitGUID and UnitGUID("player")
    local snap = me and M.DB().chars[me]
    if not snap then
        f.left:SetText("|cff888888Loremaster: this character is not counted yet|r")
        f.right:SetText("")
        return
    end
    local ar, ag, ab = GOLD[1], GOLD[2], GOLD[3]
    if AltStable.GetAccentRGB then ar, ag, ab = AltStable.GetAccentRGB() end
    local hex = ("|cff%02x%02x%02x"):format(ar * 255, ag * 255, ab * 255)
    local done, total = L.Totals(snap)
    f.left:SetText(("%sLoremaster|r %d/%d |cffaaaaaa\194\183 %d%%|r"):format(hex, done, total, Pct(done, total)))
    local cls = snap.cls or {}
    f.right:SetText(("|cffaaaaaaClass quests|r %d/%d |cffaaaaaa(%d at this level)|r"):format(
        cls.done or 0, cls.total or 0, cls.now or 0))
end

------------------------------------------------------------
-- Activation, bootstrap
------------------------------------------------------------

function L.Visible()
    return L.isActive and panel ~= nil and panel:IsVisible() and true or false
end

local refreshTimer
function L.RequestRender(delay)
    if not L.Visible() then return end
    if refreshTimer then return end
    refreshTimer = C_Timer.NewTimer(delay or 0.2, function()
        refreshTimer = nil
        if L.Visible() then L.Render() end
    end)
end

-- A new snapshot (a scan, or one received): redraw if showing.
M.OnChanged = function() L.RequestRender(0.2) end

local function HookRefresh()
    if L._refreshHooked or type(AltStable.RefreshSheet) ~= "function" then return end
    local prev = AltStable.RefreshSheet
    AltStable.RefreshSheet = function(...)
        prev(...)
        if L.isActive then L.RequestRender(0) end
    end
    L._refreshHooked = true
end

local GRID_PARTS = { "bodyScroll", "frozenScroll", "headerScroll", "frozenHeader", "hScrollBar" }

function L.HoldMinSize()
    if not AltStable.EnsureWindowMinSize then return end
    local layout = AltStable.LAYOUT or {}
    AltStable.EnsureWindowMinSize((layout.SIDEBAR_WIDTH or 230) + 1 + MIN_PANEL_W,
        (layout.TITLE_H or 30) + (layout.FOOTER_HEIGHT or 22) + 2 + MIN_PANEL_H)
end

function L.Activate(mainFrame)
    if AltStable.RequestPluginSize then AltStable.RequestPluginSize(PREFERRED_PANEL_W) end
    L.HoldMinSize()
    L.BuildPanel(mainFrame)
    L.BuildFooter(mainFrame)
    HookRefresh()
    L.isActive = true
    for _, k in ipairs(GRID_PARTS) do if mainFrame[k] then mainFrame[k]:Hide() end end
    local tb = mainFrame.totalsBar
    if tb then
        tb:Show()
        if tb.core then tb.core:Hide() end
    end
    if L.foot then L.foot:Show() end
    panel:Show()
    L.Render()
end

function L.Deactivate(mainFrame)
    L.isActive = false
    if panel then panel:Hide() end
    if L.foot then L.foot:Hide() end
    local tb = mainFrame.totalsBar
    if tb and tb.core then tb.core:Show() end
    for _, k in ipairs(GRID_PARTS) do if mainFrame[k] then mainFrame[k]:Show() end end
end

function L.Bootstrap()
    if not AltStable or not AltStable.RegisterPlugin then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable Loremaster]|r AltStable not found.")
        return
    end
    HookRefresh()
    AltStable.RegisterPlugin({
        id           = ADDON_ID,
        label        = "Loremaster",
        icon         = (AltStable.MEDIA_PATH or "Interface\\AddOns\\AltStable\\Media\\") .. "Icons\\loremaster.tga",
        _isPlugin    = true,
        OnActivate   = function(mainFrame) L.Activate(mainFrame) end,
        OnResize     = function()
            if not L.isActive then return end
            L.HoldMinSize()
            L.Render()
        end,
        OnDeactivate = function(mainFrame) L.Deactivate(mainFrame) end,
        -- The counts, on Loremaster's own sync line. They carry their own
        -- stamp, so the core hands them over even when it keeps its own copy
        -- of the character record.
        independentStamp = true,
        OnSerialize   = function(guid) return M.Serialize(guid) end,
        OnDeserialize = function(guid, blob) M.Deserialize(guid, blob) end,
        OnCleanup     = function(keep) M.Cleanup(keep) end,
        OnForget      = function(guid) M.Forget(guid) end,
        _test        = L,
    })
    M.Start()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function() C_Timer.After(1, L.Bootstrap) end)

-- Loaded on demand from the core's PLAYER_LOGIN handler, so PLAYER_LOGIN will
-- not fire for us again.
if IsLoggedIn() then
    C_Timer.After(1, L.Bootstrap)
end
