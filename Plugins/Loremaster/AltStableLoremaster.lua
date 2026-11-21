------------------------------------------------------------
-- AltStableLoremaster - quest progress by zone for every alt (#374, #372, #398)
--
-- SPDX-License-Identifier: GPL-3.0-or-later (see NOTICE.md).
--
-- The tab, top to bottom:
--   * the map panel (#398): the selected zone's own map from the client's own
--     art, desaturated and tinted teal (the owner's glass look); an instance
--     shows its entrance zone with the entrance pinned; where the character
--     playing stands in the zone shown, a pin. Hidden with "Hide map";
--   * beside it the zone card: the selected zone and character, its count, a
--     bar, what is left; "View quests" turns the card into the zone's quest
--     list (to do by level, done, missed);
--   * a toolbar: which groups show, a zone search, Hide map;
--   * the grid: zones down the side in collapsible groups, characters across,
--     "27/30" in a cell. A click selects the row (and the column, on a cell);
--     a header click selects the character;
--   * the totals bar: the selected character's total, and a jump to Class
--     quests.
--
-- The counting is Loremaster.lua's. This file only shows snapshots:
-- AltStableLoremasterDB.chars, one per character, from its own last login or
-- from sync. A character never scanned has no column, never a row of zeros.
--
-- The map, from the 70959 API (seen in game on 70959: Azeroth's tiles load;
-- every call is guarded, so a map that does not read leaves the panel blank,
-- never an error):
--   * art: C_Map.GetMapArtLayers(map)[1] and GetMapArtLayerTextures(map, 1),
--     the tile grid the world map draws (as Blizzard's MapCanvas does), the
--     whole map fitted in the panel;
--   * the zoom: C_Map.GetMapInfo's parents up to the continent, and
--     C_Map.GetMapRectOnMap(zone, continent), where the zone's art sits on the
--     continent's. The camera flies from the whole continent into the zone;
--     a map without a continent shows still;
--   * the entrance of an instance: QuestieDB's, in percent of the entrance
--     zone's map; the player: C_Map.GetPlayerMapPosition in the zone shown.
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
local MAP_H     = 190     -- the map panel and the card
local CARD_W    = 270
local TOOLBAR_H = 26
local COLHDR_H  = 24      -- the characters' names
local ROW_H     = 20
local GROUP_H   = 22
local NAME_W    = 200
local COL_W     = 64      -- the narrowest a character column gets
local MAX_COL_W = 160     -- and the widest, when there is room to spread
local HBAR_H    = 12
local MAX_TIP   = 20      -- open quests listed in a tooltip
local LIST_LINE = 15
local PREFERRED_PANEL_W = 960
local MIN_PANEL_W, MIN_PANEL_H = 560, 420
local AZEROTH   = 947

local GOLD = { 1, 0.82, 0 }
-- The map's glass tint, multiplied over the desaturated art: light enough that
-- land (the art's lighter half) and water (its darker) still part (seen in game:
-- at 0.42/0.80/0.82 under a 30% wash, both were one murky teal).
local TEAL = { 0.66, 0.94, 0.96 }

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
local GROUP_LABEL = {}
for _, g in ipairs(L.GROUPS) do GROUP_LABEL[g.key] = g.label end

-- The toolbar's filter: which groups show.
L.FILTERS = {
    { id = "all",          text = "All",           groups = nil },
    { id = "zones",        text = "Zones",         groups = { EK = true, KAL = true, FOREVER = true } },
    { id = "dungeon",      text = "Dungeons",      groups = { dungeon = true } },
    { id = "raid",         text = "Raids",         groups = { raid = true } },
    { id = "battleground", text = "Battlegrounds", groups = { battleground = true } },
    { id = "class",        text = "Class",         groups = { class = true } },
    { id = "profession",   text = "Professions",   groups = { profession = true } },
    { id = "other",        text = "Other",         groups = { other = true } },
}
local FILTER_BY_ID = {}
for _, f in ipairs(L.FILTERS) do FILTER_BY_ID[f.id] = f end

local panel, scroll, content, titleFS, emptyFS, vbar, hbar, thisCheck
local mapFrame, card, toolbar

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function Api(ns, name)
    local t = rawget(_G, ns)
    return type(t) == "table" and t[name] or nil
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
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
    if AltStable.SkinText then AltStable.SkinText(f) end
    return f
end

-- A small arrow, drawn: the game font has no triangle glyphs (seen in game, an
-- empty box). `dir` "right" or "down".
local ARROW = "Interface\\ChatFrame\\ChatFrameExpandArrow"
local function Arrow(parent, dir, size)
    local t = parent:CreateTexture(nil, "OVERLAY")
    t:SetSize(size or 12, size or 12)
    t:SetTexture(ARROW)
    if dir == "down" and t.SetRotation then t:SetRotation(-math.pi / 2) end
    t:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
    return t
end

-- The owner's mockup's buttons: a dark well, a thin accent edge, gold text,
-- lighter on hover, dim when disabled. Not the game's red panel button.
function L.Button(parent, w, h, text)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.edges = {}
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local e = b:CreateTexture(nil, "BORDER")
        if side == "TOP" or side == "BOTTOM" then
            e:SetHeight(1)
            e:SetPoint(side .. "LEFT", b, side .. "LEFT", 0, 0)
            e:SetPoint(side .. "RIGHT", b, side .. "RIGHT", 0, 0)
        else
            e:SetWidth(1)
            e:SetPoint("TOP" .. side, b, "TOP" .. side, 0, 0)
            e:SetPoint("BOTTOM" .. side, b, "BOTTOM" .. side, 0, 0)
        end
        b.edges[#b.edges + 1] = e
    end
    local fs = FS(b, "GameFontNormal", "CENTER")
    fs:SetPoint("CENTER", b, "CENTER", 0, 0)
    b:SetFontString(fs)
    b.label = fs
    local function paint(self, hover)
        local r, g, bl, a = 0.03, 0.03, 0.04, 1
        if AltStable.SkinWellColor then r, g, bl, a = AltStable.SkinWellColor() end
        if hover and self:IsEnabled() then r, g, bl = r + 0.08, g + 0.08, bl + 0.08 end
        self.bg:SetColorTexture(r, g, bl, a)
        local ar, ag, ab = GOLD[1], GOLD[2], GOLD[3]
        if AltStable.GetAccentRGB then ar, ag, ab = AltStable.GetAccentRGB() end
        for _, e in ipairs(self.edges) do e:SetColorTexture(ar, ag, ab, self:IsEnabled() and 0.55 or 0.2) end
        if self:IsEnabled() then self.label:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
        else self.label:SetTextColor(0.45, 0.45, 0.45) end
    end
    b.Paint = paint
    b:SetScript("OnEnter", function(self) paint(self, true) end)
    b:SetScript("OnLeave", function(self) paint(self, false); GameTooltip:Hide() end)
    b:SetScript("OnEnable", function(self) paint(self, false) end)
    b:SetScript("OnDisable", function(self) paint(self, false) end)
    if text then b:SetText(text) end
    paint(b, false)
    return b
end

local function Pct(done, total)
    if total <= 0 then return 0 end
    return math.floor(100 * done / total + 0.5)
end

local function Number(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
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
    if uiMapID and z[1] == "zone" then
        local ok, info = Call(Api("C_Map", "GetMapInfo"), uiMapID)
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

-- Whether a row passes the toolbar: its group in the filter, its name matching
-- the search.
function L.RowShown(key)
    local f = FILTER_BY_ID[M.DB().filter or "all"] or FILTER_BY_ID.all
    if f.groups and not f.groups[L.GroupOf(key) or ""] then return false end
    local q = L.search
    if q and q ~= "" then
        local name = L.ZoneName(key):lower()
        if not name:find(q, 1, true) then return false end
    end
    return true
end

-- The display list: a group header, then its rows, for every row some column
-- has quests in. Collapsed groups keep their header; a search opens them.
function L.DisplayRows(cols)
    local present = {}
    for _, col in ipairs(cols) do
        for key in pairs(col.snap.c or {}) do
            if D.ZONES[key] and L.RowShown(key) then present[key] = true end
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
    local searching = L.search and L.search ~= ""
    local out = {}
    for _, g in ipairs(L.GROUPS) do
        local keys = byGroup[g.key]
        if keys then
            table.sort(keys, function(a, b) return D.ZONES[a][5] < D.ZONES[b][5] end)
            out[#out + 1] = { isGroup = true, key = g.key, label = g.label, n = #keys }
            if searching or not collapsed[g.key] then
                for _, key in ipairs(keys) do out[#out + 1] = { key = key } end
            end
        end
    end
    return out
end

-- One character's total over every row.
function L.Totals(snap)
    local done, total = 0, 0
    for _, row in pairs(snap and snap.c or {}) do
        done, total = done + row[1], total + row[2]
    end
    return done, total
end

------------------------------------------------------------
-- Selection: a row and a character, driving the map and the card
------------------------------------------------------------

function L.SelectedColumn(cols)
    cols = cols or L.cols or {}
    for _, col in ipairs(cols) do if col.guid == L.selGuid then return col end end
    return cols[1]
end

-- The row to start on: the zone the character is standing in, else the first
-- row it has quests in.
function L.DefaultRow(col)
    if not col then return nil end
    local ok, here = Call(Api("C_Map", "GetBestMapForUnit"), "player")
    if ok and here and col.isMe then
        for key, z in pairs(D.ZONES) do
            if z[3] == here and col.snap.c and col.snap.c[key] then return key end
        end
    end
    local best
    for key in pairs(col.snap.c or {}) do
        if D.ZONES[key] and (not best or D.ZONES[key][5] < D.ZONES[best][5]) then best = key end
    end
    return best
end

function L.Select(key, guid)
    if key ~= nil then L.selKey = key end
    if guid ~= nil then L.selGuid = guid end
    L.cardMode = "summary"
    L.Render()
end

------------------------------------------------------------
-- The quest lists: only for a character whose done set this install holds,
-- from the same snapshot the cell shows
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
    local ok, t = Call(Api("C_QuestLog", "GetTitleForQuestID"), id)
    if ok and type(t) == "string" and t ~= "" then name = t end
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

local function ReleaseAll(only)
    for kind, pool in pairs(L.pools) do
        if not only or only[kind] then
            for i = 1, #pool.list do pool.list[i]:Hide() end
            pool.used = 0
        end
    end
end

local function MakeCell()
    local cell = CreateFrame("Button", nil, content)
    cell:SetSize(COL_W, ROW_H)
    cell.text = FS(cell, "GameFontHighlightSmall", "CENTER")
    cell.text:SetPoint("CENTER")
    cell:SetScript("OnEnter", L.CellOnEnter)
    cell:SetScript("OnLeave", HideTip)
    cell:SetScript("OnClick", function(self)
        if self.rowKey then L.Select(self.rowKey, self.guid) end
    end)
    return cell
end

local function MakeRowLabel()
    local f = CreateFrame("Button", nil, content)
    f:SetSize(NAME_W, ROW_H)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.text = FS(f, "GameFontHighlightSmall")
    f.text:SetPoint("LEFT", f, "LEFT", 14, 0)
    f.text:SetPoint("RIGHT", f, "RIGHT", -4, 0)
    f.text:SetWordWrap(false)
    f:SetScript("OnClick", function(self) if self.rowKey then L.Select(self.rowKey) end end)
    return f
end

-- The selected row's band, under its label and cells.
local function MakeBand()
    local t = content:CreateTexture(nil, "BACKGROUND", nil, 1)
    t:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.18)
    return t
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
    b.sel = b:CreateTexture(nil, "OVERLAY")
    b.sel:SetHeight(2)
    b.sel:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 6, 0)
    b.sel:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -6, 0)
    b.sel:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    b:SetScript("OnEnter", HeaderOnEnter)
    b:SetScript("OnLeave", HideTip)
    b:SetScript("OnClick", function(self) if self.col then L.Select(nil, self.col.guid) end end)
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
        first[i] = FirstChars((col.name or "?"):match("^(%S+)") or "?", 9)
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
-- The map panel
------------------------------------------------------------

-- What the map panel shows for a row (#398, the owner: "zoom to a zone when
-- selecting a zone"): { map = uiMapID, pin = { x, y } (0-1) or nil, dim }.
--   * a zone: its own map, whole; no outline needed, the map IS the zone;
--   * a dungeon or raid: its entrance zone's map, the entrance pinned
--     (QuestieDB's entrance, in percent, carried in the quest table);
--   * Class, Professions, Other: Azeroth, dimmed.
function L.Placement(key)
    local z = D.ZONES[key]
    local map = z and (z[6] or z[3])
    if not map then return { map = AZEROTH, dim = true } end
    local place = { map = map }
    if tonumber(z[7]) and tonumber(z[8]) then place.pin = { x = z[7] / 100, y = z[8] / 100 } end
    return place
end

-- Where the character playing stands, when it stands in the map shown. Live,
-- never cached; a position the client keeps secret (an instance) is no pin.
function L.PlayerPin(map)
    local okB, here = Call(Api("C_Map", "GetBestMapForUnit"), "player")
    if not okB or here ~= map then return nil end
    local ok, pos = Call(Api("C_Map", "GetPlayerMapPosition"), map, "player")
    if not ok or type(pos) ~= "table" or not pos.GetXY then return nil end
    local okXY, x, y = pcall(function()
        local px, py = pos:GetXY()
        if px and py and px > 0 and py > 0 and px < 1 and py < 1 then return px, py end
    end)
    if okXY and x then return { x = x, y = y } end
    return nil
end

-- Forget what was read of the maps (tests; a client whose map loads late).
function L.ResetMapCache()
    L.mapArts, L.zooms, L.cam = {}, {}, nil
end

-- A map's art: its first layer's tiles, read once per map.
function L.MapArt(map)
    map = map or AZEROTH
    L.mapArts = L.mapArts or {}
    if L.mapArts[map] ~= nil then return L.mapArts[map] or nil end
    L.mapArts[map] = false
    local okL, layers = Call(Api("C_Map", "GetMapArtLayers"), map)
    local layer = okL and type(layers) == "table" and layers[1]
    local okT, tiles = Call(Api("C_Map", "GetMapArtLayerTextures"), map, 1)
    if layer and okT and type(tiles) == "table" and #tiles > 0 and tonumber(layer.layerWidth)
       and tonumber(layer.tileWidth) and layer.layerWidth > 0 and layer.tileWidth > 0 then
        L.mapArts[map] = { w = layer.layerWidth, h = layer.layerHeight, tw = layer.tileWidth, th = layer.tileHeight,
                           tiles = tiles }
    end
    return L.mapArts[map] or nil
end

-- Where a map sits on its continent, for the zoom: { cont = uiMapID, art,
-- x0, x1, y0, y1 } (0-1 of the continent), or nil (no continent, no art, or
-- the client does not place it: the map then shows still). Read once per map.
function L.ZoomFrom(map)
    L.zooms = L.zooms or {}
    if L.zooms[map] ~= nil then return L.zooms[map] or nil end
    L.zooms[map] = false
    local okI, info = Call(Api("C_Map", "GetMapInfo"), map)
    local parent = okI and type(info) == "table" and info.parentMapID
    for _ = 1, 6 do
        if not tonumber(parent) or parent <= 0 then break end
        local okP, pinfo = Call(Api("C_Map", "GetMapInfo"), parent)
        if not okP or type(pinfo) ~= "table" then break end
        -- 2 = Enum.UIMapType.Continent, 1 = World: the first one up the chain.
        if tonumber(pinfo.mapType) and pinfo.mapType <= 2 then
            local art = L.MapArt(parent)
            local okR, x0, x1, y0, y1 = Call(Api("C_Map", "GetMapRectOnMap"), map, parent)
            if art and okR and tonumber(x0) and tonumber(x1) and tonumber(y0) and tonumber(y1)
               and x1 > x0 and y1 > y0 then
                L.zooms[map] = { cont = parent, art = art, x0 = x0, x1 = x1, y0 = y0, y1 = y1 }
            end
            break
        end
        parent = pinfo.parentMapID
    end
    return L.zooms[map] or nil
end

local function GlassTile(t, shade)
    -- The owner's glass look from the client's own art: no colour of its own,
    -- then the teal of the Pearl glass (darker for the continent behind).
    if t.SetDesaturated then t:SetDesaturated(true) end
    shade = shade or 1
    t:SetVertexColor(TEAL[1] * shade, TEAL[2] * shade, TEAL[3] * shade, 1)
end

-- Lays a map's tiles: sx, sy panel pixels per art pixel, x, y the art's
-- top-left in the panel.
local function LayTiles(pool, parent, layer, art, sx, sy, x, y, shade)
    local cols = math.ceil(art.w / art.tw)
    local rows = math.ceil(art.h / art.th)
    local i = 0
    for r = 1, rows do
        for c = 1, cols do
            local file = art.tiles[(r - 1) * cols + c]
            if file then
                i = i + 1
                local t = pool[i]
                if not t then
                    t = parent:CreateTexture(nil, layer)
                    pool[i] = t
                end
                if t._file ~= file then t:SetTexture(file); t._file = file end
                GlassTile(t, shade)
                t:SetSize(art.tw * sx, art.th * sy)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", mapFrame.clip, "TOPLEFT", x + (c - 1) * art.tw * sx, -(y + (r - 1) * art.th * sy))
                t:Show()
            end
        end
    end
    for j = i + 1, #pool do pool[j]:Hide() end
end

local function HidePool(pool) for _, t in ipairs(pool) do t:Hide() end end

local ZOOM_IN, ZOOM_OUT = 0.55, 0.35   -- seconds
local function Ease(t) return t * t * (3 - 2 * t) end

-- The camera (#398, the owner: "like if we actually zoomed the map"): t = 0
-- is the whole continent, t = 1 the zone filling the panel, the continent
-- zoomed with it and darkened behind. A new zone zooms out (t back to 0),
-- changes continent if it must, then zooms in.
-- The world map's own sounds (Blizzard_WorldMap.lua: open on show, close on
-- hide), as the zoom opens and closes.
local function MapSound(open)
    local kit = rawget(_G, "SOUNDKIT")
    local id = kit and kit[open and "IG_QUEST_LOG_OPEN" or "IG_QUEST_LOG_CLOSE"]
    local play = rawget(_G, "PlaySound")
    if id and play then pcall(play, id) end
end

local function NewCam(place)
    local zoom = not place.dim and L.ZoomFrom(place.map) or nil
    if zoom then MapSound(true) end
    return { place = place, art = L.MapArt(place.map), zoom = zoom, t = zoom and 0 or 1 }
end

-- Draws the camera where it is now.
function L.LayMap()
    local cam = L.cam
    local clip = mapFrame.clip
    local w, h = clip:GetWidth() or 0, clip:GetHeight() or 0
    if not cam or w <= 0 or h <= 0 then
        if cam then cam.rect = nil end
        HidePool(mapFrame.tiles); HidePool(mapFrame.back)
        mapFrame.pin:Hide(); mapFrame.me:Hide(); mapFrame.shadow:Hide()
        return
    end
    local art, zoom = cam.art, cam.zoom
    -- The zone at rest: whole, fitted inside the panel and centred.
    local s = math.min(w / art.w, h / art.h)
    local zx, zy, zw, zh = (w - art.w * s) / 2, (h - art.h * s) / 2, art.w * s, art.h * s
    local alpha = cam.place.dim and 0.45 or 1
    if zoom then
        local ca = zoom.art
        local e = Ease(cam.t)
        -- The continent: whole at t = 0, zoomed so the zone's rect lands on
        -- the zone at rest at t = 1. Zoom by ratio, centre in a line.
        local s0 = math.min(w / ca.w, h / ca.h)
        local s1 = zw / ((zoom.x1 - zoom.x0) * ca.w)
        local c1x = (w / 2 - (zx - zoom.x0 * ca.w * s1)) / (ca.w * s1)
        local c1y = (h / 2 - (zy - zoom.y0 * ca.h * s1)) / (ca.h * s1)
        local sc = s0 * (s1 / s0) ^ e
        local cx, cy = 0.5 + (c1x - 0.5) * e, 0.5 + (c1y - 0.5) * e
        local ox, oy = w / 2 - cx * ca.w * sc, h / 2 - cy * ca.h * sc
        LayTiles(mapFrame.back, clip, "BORDER", ca, sc, sc, ox, oy, 1 - 0.6 * e)
        -- The zone rides on the continent, where its art sits.
        zx, zy = ox + zoom.x0 * ca.w * sc, oy + zoom.y0 * ca.h * sc
        zw, zh = (zoom.x1 - zoom.x0) * ca.w * sc, (zoom.y1 - zoom.y0) * ca.h * sc
        alpha = math.min(1, e * 1.6)
        mapFrame.shadow:ClearAllPoints()
        mapFrame.shadow:SetPoint("TOPLEFT", clip, "TOPLEFT", zx - 4, -(zy - 4))
        mapFrame.shadow:SetSize(zw + 8, zh + 8)
        mapFrame.shadow:Show()
    else
        HidePool(mapFrame.back)
        mapFrame.shadow:Hide()
    end
    LayTiles(mapFrame.tiles, mapFrame.zone, "ARTWORK", art, zw / art.w, zh / art.h, zx, zy, 1)
    mapFrame.zone:SetAlpha(alpha)

    cam.rect = { x = zx, y = zy, w = zw, h = zh, alpha = alpha }
    L.PutPin(mapFrame.pin, cam.place.pin)
    L.PutPin(mapFrame.me, not cam.place.dim and cam.place.me or nil)
end

-- A pin at a point of the zone shown (0-1), where the camera has it now.
function L.PutPin(tex, at)
    local r = L.cam and L.cam.rect
    if not at or not r then tex:Hide(); return end
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", mapFrame.clip, "TOPLEFT", r.x + at.x * r.w, -(r.y + at.y * r.h))
    tex:SetAlpha(r.alpha)
    tex:Show()
end

-- The player moves while the map shows (Codex on #400): read where it stands
-- again, a few times a second, and drop the pin once it leaves the zone shown.
local PLAYER_EVERY = 0.25
function L.RefreshPlayer()
    local cam = L.cam
    if not mapFrame or not cam then return end
    cam.place.me = not cam.place.dim and L.PlayerPin(cam.place.map) or nil
    L.PutPin(mapFrame.me, cam.place.me)
end

local function PlayerOnUpdate(self, elapsed)
    self.since = (self.since or 0) + (elapsed or 0)
    if self.since < PLAYER_EVERY then return end
    self.since = 0
    L.RefreshPlayer()
end

-- One step of the camera; true while it still moves.
function L.MapTick(elapsed)
    local cam = L.cam
    if not cam then return false end
    if cam.next then
        cam.t = cam.zoom and math.max(0, cam.t - elapsed / ZOOM_OUT) or 0
        if cam.t <= 0 then
            L.cam = NewCam(cam.next)
            cam = L.cam
        end
    elseif cam.t < 1 then
        cam.t = math.min(1, cam.t + elapsed / ZOOM_IN)
    end
    if mapFrame then L.LayMap() end
    return cam.next ~= nil or cam.t < 1
end

local function MapOnUpdate(_, elapsed)
    if not L.MapTick(elapsed or 0) then mapFrame:SetScript("OnUpdate", nil) end
end

function L.RenderMap(key)
    if not mapFrame then return end
    local place = key and L.Placement(key) or { map = AZEROTH, dim = true }
    local art = L.MapArt(place.map)
    if not art and place.map ~= AZEROTH then
        -- A zone without art of its own: Azeroth, dimmed, rather than nothing.
        place = { map = AZEROTH, dim = true }
        art = L.MapArt(AZEROTH)
    end
    L.shownMap = art and place.map or nil
    mapFrame.none:SetShown(not art)
    if not art then
        L.cam = nil
        mapFrame:SetScript("OnUpdate", nil)
        L.LayMap()
        return
    end
    place.me = not place.dim and L.PlayerPin(place.map) or nil
    local cam = L.cam
    local same = cam and cam.place.map == place.map and (cam.place.dim or false) == (place.dim or false)
    if not cam then
        L.cam = NewCam(place)
    elseif same then
        -- The same map (a redraw, or two instances in one entrance zone): the
        -- pins move, the camera stays (or turns back to it mid-zoom).
        if cam.next and cam.zoom then MapSound(true) end
        cam.place, cam.next = place, nil
    elseif cam.zoom and cam.t > 0 then
        if not cam.next then MapSound(false) end
        cam.next = place
    else
        L.cam = NewCam(place)
    end
    L.LayMap()
    if L.cam.next or L.cam.t < 1 then mapFrame:SetScript("OnUpdate", MapOnUpdate) end
end

function L.BuildMap()
    mapFrame = CreateFrame("Frame", nil, panel)
    L.mapFrame = mapFrame   -- tests
    mapFrame.bg = mapFrame:CreateTexture(nil, "BACKGROUND")
    mapFrame.bg:SetAllPoints()
    mapFrame.clip = CreateFrame("Frame", nil, mapFrame)
    mapFrame.clip:SetPoint("TOPLEFT", mapFrame, "TOPLEFT", 2, -2)
    mapFrame.clip:SetPoint("BOTTOMRIGHT", mapFrame, "BOTTOMRIGHT", -2, 2)
    mapFrame.clip:SetClipsChildren(true)
    -- Three layers in the clip: the continent behind (its tiles), the zone
    -- over it (a frame, so it fades as one), and the glass and pins on top.
    mapFrame.back = {}
    mapFrame.zone = CreateFrame("Frame", nil, mapFrame.clip)
    mapFrame.zone:SetAllPoints()
    mapFrame.zone:SetFrameLevel(mapFrame.clip:GetFrameLevel() + 1)
    mapFrame.top = CreateFrame("Frame", nil, mapFrame.clip)
    mapFrame.top:SetAllPoints()
    mapFrame.top:SetFrameLevel(mapFrame.clip:GetFrameLevel() + 2)
    -- Runs only while the map shows (OnUpdate stops with the frame hidden).
    mapFrame.top:SetScript("OnUpdate", PlayerOnUpdate)
    mapFrame.tiles = {}
    -- A soft shadow lifts the zone off the darkened continent.
    mapFrame.shadow = mapFrame.zone:CreateTexture(nil, "BACKGROUND")
    mapFrame.shadow:SetColorTexture(0, 0, 0, 0.55)
    mapFrame.shadow:Hide()
    -- The glass: a teal wash over the art and a light rim.
    mapFrame.wash = mapFrame.top:CreateTexture(nil, "OVERLAY", nil, -1)
    mapFrame.wash:SetAllPoints()
    mapFrame.wash:SetColorTexture(0.04, 0.22, 0.24, 0.14)
    -- Where the character playing stands, in the zone shown (white, under the
    -- gold entrance pin).
    mapFrame.me = mapFrame.top:CreateTexture(nil, "OVERLAY", nil, 1)
    mapFrame.me:SetSize(16, 16)
    mapFrame.me:SetTexture("Interface\\WorldMap\\WorldMapPartyIcon")
    mapFrame.me:SetVertexColor(1, 1, 1, 1)
    mapFrame.me:Hide()
    mapFrame.pin = mapFrame.top:CreateTexture(nil, "OVERLAY", nil, 2)
    mapFrame.pin:SetSize(18, 18)
    mapFrame.pin:SetTexture("Interface\\WorldMap\\WorldMapPartyIcon")
    mapFrame.pin:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
    mapFrame.pin:Hide()
    mapFrame.edges = {}
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local e = mapFrame:CreateTexture(nil, "BORDER")
        if side == "TOP" or side == "BOTTOM" then
            e:SetHeight(1)
            e:SetPoint(side .. "LEFT", mapFrame, side .. "LEFT", 0, 0)
            e:SetPoint(side .. "RIGHT", mapFrame, side .. "RIGHT", 0, 0)
        else
            e:SetWidth(1)
            e:SetPoint("TOP" .. side, mapFrame, "TOP" .. side, 0, 0)
            e:SetPoint("BOTTOM" .. side, mapFrame, "BOTTOM" .. side, 0, 0)
        end
        mapFrame.edges[#mapFrame.edges + 1] = e
    end
    mapFrame.none = FS(mapFrame, "GameFontHighlightSmall", "CENTER")
    mapFrame.none:SetPoint("CENTER")
    mapFrame.none:SetText("|cff888888The map did not load.|r")
    mapFrame.none:Hide()
    mapFrame:SetScript("OnSizeChanged", function() if L.isActive then L.RenderMap(L.selKey) end end)
end

------------------------------------------------------------
-- The zone card
------------------------------------------------------------

local function CardBox(parent)
    local f = CreateFrame("Frame", nil, parent)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    return f
end

function L.BuildCard()
    card = CardBox(panel)
    card.zone = FS(card, "GameFontNormalLarge")
    card.zone:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -12)
    card.zone:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    card.zone:SetWordWrap(false)
    card.sub = FS(card, "GameFontHighlightSmall")
    card.sub:SetPoint("TOPLEFT", card.zone, "BOTTOMLEFT", 0, -3)
    card.icon = card:CreateTexture(nil, "ARTWORK")
    card.icon:SetSize(24, 24)
    card.icon:SetPoint("TOPLEFT", card.sub, "BOTTOMLEFT", 0, -10)
    card.who = FS(card, "GameFontNormal")
    card.who:SetPoint("LEFT", card.icon, "RIGHT", 8, 0)
    card.who:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    card.who:SetWordWrap(false)
    card.count = FS(card, "GameFontHighlight")
    card.count:SetPoint("TOPLEFT", card.icon, "BOTTOMLEFT", 0, -10)
    card.bar = CreateFrame("StatusBar", nil, card)
    card.bar:SetHeight(12)
    card.bar:SetPoint("TOPLEFT", card.count, "BOTTOMLEFT", 0, -6)
    card.bar:SetPoint("RIGHT", card, "RIGHT", -52, 0)
    card.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    card.bar:SetStatusBarColor(GOLD[1], GOLD[2] * 0.85, 0, 1)
    card.bar:SetMinMaxValues(0, 1)
    card.bar.bg = card.bar:CreateTexture(nil, "BACKGROUND")
    card.bar.bg:SetAllPoints()
    -- A light track, so an empty bar still reads as a bar on the dark card
    -- (seen in game: at 0% the black track vanished).
    card.bar.bg:SetColorTexture(1, 1, 1, 0.10)
    card.pct = FS(card, "GameFontHighlight", "RIGHT")
    card.pct:SetPoint("LEFT", card.bar, "RIGHT", 6, 0)
    card.pct:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    card.left = FS(card, "GameFontHighlightSmall")
    card.left:SetPoint("TOPLEFT", card.bar, "BOTTOMLEFT", 0, -6)
    card.bar:SetStatusBarColor(GOLD[1], GOLD[2], 0.1, 1)
    card.view = L.Button(card, 130, 24, "View quests")
    card.view:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 12, 12)
    card.view:SetScript("OnClick", function() L.cardMode = "list"; L.listScroll = 0; L.RenderCard() end)
    card.view:SetScript("OnEnter", function(self)
        self:Paint(true)
        if self:IsEnabled() then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("The quest list shows for characters played here.", 1, 1, 1, true)
        GameTooltip:Show()
    end)

    -- The list mode: the zone's quests for the selected character.
    card.list = CreateFrame("ScrollFrame", nil, card)
    card.list:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -38)
    card.list:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -10, 40)
    card.list.child = CreateFrame("Frame", nil, card.list)
    card.list.child:SetSize(1, 1)
    card.list:SetScrollChild(card.list.child)
    card.list:EnableMouseWheel(true)
    card.list:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, (card.list.child:GetHeight() or 0) - (self:GetHeight() or 0))
        L.listScroll = math.max(0, math.min(max, (L.listScroll or 0) - delta * 3 * LIST_LINE))
        self:SetVerticalScroll(L.listScroll)
    end)
    card.lines = {}
    card.back = L.Button(card, 80, 24, "Back")
    card.back:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 12, 12)
    card.back:SetScript("OnClick", function() L.cardMode = "summary"; L.RenderCard() end)
end

-- The card's lines in list mode: { text, r, g, b } each.
function L.ListLines(col, key)
    local lists = L.ListsFor(col)
    local l = lists and lists[key]
    if not l then return nil end
    local out = {}
    local function section(title, ids, r, g, b, dimHigh)
        if #ids == 0 then return end
        out[#out + 1] = { text = ("%s (%d)"):format(title, #ids), r = GOLD[1], g = GOLD[2], b = GOLD[3] }
        for _, id in ipairs(ids) do
            local text, high = QuestLine(id, col.level)
            if dimHigh and high then out[#out + 1] = { text = text, r = 0.5, g = 0.5, b = 0.5 }
            else out[#out + 1] = { text = text, r = r, g = g, b = b } end
        end
    end
    section("Still to do", l.open, 0.9, 0.9, 0.9, true)
    section("Done", l.done, 0.55, 0.8, 0.55)
    section("Missed", l.missed, 0.6, 0.45, 0.45)
    return out
end

local function ClassIcon(tex, class)
    local coords = rawget(_G, "CLASS_ICON_TCOORDS")
    local c = type(coords) == "table" and class and coords[class]
    if c then
        tex:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
        tex:SetTexCoord(c[1], c[2], c[3], c[4])
        tex:Show()
    else
        tex:Hide()
    end
end

function L.RenderCard()
    if not card then return end
    local col = L.SelectedColumn()
    local key = L.selKey
    local summary = { card.icon, card.who, card.count, card.bar, card.pct, card.left, card.view }
    if not col or not key or not D.ZONES[key] then
        card.zone:SetText("|cff888888No zone selected|r")
        card.sub:SetText("")
        for _, w in ipairs(summary) do w:Hide() end
        card.list:Hide(); card.back:Hide()
        return
    end
    card.zone:SetText(L.ZoneName(key))
    local g = L.GroupOf(key)
    card.sub:SetText(GROUP_LABEL[g] or "")
    local row = col.snap.c and col.snap.c[key]
    local listing = L.cardMode == "list"
    for _, w in ipairs(summary) do w:SetShown(not listing) end
    card.list:SetShown(listing)
    card.back:SetShown(listing)
    if listing then
        card.sub:SetText(ClassHex(col.class) .. col.name .. "|r")
        local lines = L.ListLines(col, key) or { { text = "No quest list for this character here.", r = 0.6, g = 0.6, b = 0.6 } }
        local child = card.list.child
        child:SetWidth(card.list:GetWidth() or 200)
        for i, line in ipairs(lines) do
            local fs = card.lines[i]
            if not fs then
                fs = FS(child, "GameFontHighlightSmall")
                fs:SetWordWrap(false)
                card.lines[i] = fs
            end
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(i - 1) * LIST_LINE)
            fs:SetPoint("RIGHT", child, "RIGHT", 0, 0)
            fs:SetText(line.text)
            fs:SetTextColor(line.r, line.g, line.b)
            fs:Show()
        end
        for i = #lines + 1, #card.lines do card.lines[i]:Hide() end
        child:SetHeight(math.max(1, #lines * LIST_LINE))
        card.list:SetVerticalScroll(L.listScroll or 0)
        return
    end
    ClassIcon(card.icon, col.class)
    card.who:SetText(ClassHex(col.class) .. col.name .. "|r")
    if row then
        card.count:SetText(("%d / %d quests"):format(row[1], row[2]))
        card.bar:SetValue(row[2] > 0 and row[1] / row[2] or 0)
        card.pct:SetText(Pct(row[1], row[2]) .. "%")
        local left = row[2] - row[1]
        local lists = L.ListsFor(col)
        local missed = lists and lists[key] and #lists[key].missed or 0
        local text = left == 0 and "All done" or (left == 1 and "1 quest remaining" or (left .. " quests remaining"))
        if missed > 0 then text = text .. (" \194\183 %d missed"):format(missed) end
        card.left:SetText(text)
    else
        card.count:SetText("|cff888888No quests here for this character|r")
        card.bar:SetValue(0)
        card.pct:SetText("")
        card.left:SetText("")
    end
    card.view:SetEnabled(row ~= nil and L.ListsFor(col) ~= nil)
    card.view:Paint(false)   -- not left to OnEnable/OnDisable alone
end

------------------------------------------------------------
-- The toolbar
------------------------------------------------------------

function L.BuildToolbar()
    toolbar = CreateFrame("Frame", nil, panel)
    toolbar:SetHeight(TOOLBAR_H)
    toolbar.filter = L.Button(toolbar, 140, 24)
    toolbar.filter:SetPoint("LEFT", toolbar, "LEFT", 0, 0)
    toolbar.filter.label:ClearAllPoints()
    toolbar.filter.label:SetPoint("LEFT", toolbar.filter, "LEFT", 12, 0)
    toolbar.filter.arrow = Arrow(toolbar.filter, "down", 12)
    toolbar.filter.arrow:SetPoint("RIGHT", toolbar.filter, "RIGHT", -10, 0)
    toolbar.filter:SetScript("OnClick", function()
        if not AltStable.ShowMenu then return end
        local list = {}
        for _, f in ipairs(L.FILTERS) do list[#list + 1] = { id = f.id, text = f.text } end
        AltStable.ShowMenu(list, function(id) L.SetFilter(id) end)
    end)
    toolbar.hide = L.Button(toolbar, 100, 24)
    toolbar.hide:SetPoint("RIGHT", toolbar, "RIGHT", 0, 0)
    toolbar.hide:SetScript("OnClick", function()
        M.DB().hideMap = (not M.DB().hideMap) and true or nil
        L.Render()
    end)
    local box = CreateFrame("EditBox", nil, toolbar)
    box:SetSize(200, 20)
    box:SetPoint("RIGHT", toolbar.hide, "LEFT", -10, 0)
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetTextInsets(8, 8, 0, 0)
    box.bg = box:CreateTexture(nil, "BACKGROUND")
    box.bg:SetAllPoints()
    box.hint = FS(box, "GameFontDisableSmall")
    box.hint:SetPoint("LEFT", box, "LEFT", 8, 0)
    box.hint:SetText("Search zones")
    box:SetScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        self.hint:SetShown(text == "")
        L.search = text:lower()
        L.Render()
    end)
    box:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    toolbar.search = box
end

function L.SetFilter(id)
    if not FILTER_BY_ID[id] then return end
    M.DB().filter = id ~= "all" and id or nil
    L.Render()
end

------------------------------------------------------------
-- Render
------------------------------------------------------------

function L.VisibleColumns()
    local w = panel and panel:GetWidth() or PREFERRED_PANEL_W
    return math.max(1, math.floor((w - 2 * PAD - 14 - NAME_W) / COL_W))
end

-- Where everything sits, given whether the map shows.
function L.Layout()
    local showMap = not M.DB().hideMap
    local y = HEADER_H
    if mapFrame then
        mapFrame:ClearAllPoints()
        card:ClearAllPoints()
        if showMap then
            mapFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -y)
            mapFrame:SetPoint("BOTTOMRIGHT", panel, "TOPRIGHT", -(PAD + CARD_W + 8), -(y + MAP_H))
            card:SetPoint("TOPLEFT", panel, "TOPRIGHT", -(PAD + CARD_W), -y)
            card:SetPoint("BOTTOMRIGHT", panel, "TOPRIGHT", -PAD, -(y + MAP_H))
            y = y + MAP_H + 8
        end
        mapFrame:SetShown(showMap)
        card:SetShown(showMap)
    end
    if toolbar then
        toolbar:ClearAllPoints()
        toolbar:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -y)
        toolbar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, -y)
        y = y + TOOLBAR_H + 4
    end
    L.colHdrTop = y
    y = y + COLHDR_H + 2
    if scroll then
        scroll:ClearAllPoints()
        scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -y)
        scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD - 14, HBAR_H + 6)
        vbar:ClearAllPoints()
        vbar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -y)
        vbar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, HBAR_H + 6)
    end
end

function L.ApplyColors()
    local wr, wg, wb, wa = 0.03, 0.03, 0.04, 1
    if AltStable.SkinWellColor then wr, wg, wb, wa = AltStable.SkinWellColor() end
    local er, eg, eb, ea = 0.16, 0.16, 0.18, 1
    if AltStable.SkinWellEdgeColor then er, eg, eb, ea = AltStable.SkinWellEdgeColor() end
    if mapFrame then
        mapFrame.bg:SetColorTexture(0.02, 0.10, 0.12, 1)
        for _, e in ipairs(mapFrame.edges) do e:SetColorTexture(er, eg, eb, ea) end
    end
    if card then card.bg:SetColorTexture(wr, wg, wb, wa) end
    if toolbar then toolbar.search.bg:SetColorTexture(wr, wg, wb, wa) end
end

function L.Render()
    if not panel then return end
    ReleaseAll()
    L.Layout()
    local db = M.DB()
    local cols = L.Columns()
    L.cols = cols
    local nVis = math.min(#cols, L.VisibleColumns())
    local maxOffset = math.max(0, #cols - nVis)
    L.colOffset = math.min(L.colOffset or 0, maxOffset)
    local x0 = NAME_W
    -- The columns share the width (seen in game: at a fixed 64 they bunched up
    -- on the left of a wide window).
    local avail = (panel:GetWidth() or PREFERRED_PANEL_W) - 2 * PAD - 14 - NAME_W
    local colW = nVis > 0 and math.max(COL_W, math.min(MAX_COL_W, math.floor(avail / nVis))) or COL_W
    L.colW = colW
    if L.zoneHdr then
        L.zoneHdr:ClearAllPoints()
        L.zoneHdr:SetPoint("LEFT", panel, "TOPLEFT", PAD + 14, -(L.colHdrTop + COLHDR_H / 2))
        -- No characters: the empty-state message takes the header row (Codex on #400).
        L.zoneHdr:SetShown(#cols > 0)
    end

    -- The selection: a character shown, and a row it can see.
    local sel = L.SelectedColumn(cols)
    L.selGuid = sel and sel.guid or nil
    if sel and (not L.selKey or not D.ZONES[L.selKey]) then L.selKey = L.DefaultRow(sel) end

    -- Column headers (frozen above the scroll).
    local names = L.HeaderNames(cols)
    for i = 1, nVis do
        local col = cols[L.colOffset + i]
        local h = Acquire("header", MakeHeader)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + x0 + (i - 1) * colW, -L.colHdrTop)
        h:SetSize(colW, COLHDR_H)
        h.text:SetText(ClassHex(col.class) .. names[L.colOffset + i] .. "|r")
        h.col = col
        h.sel:SetShown(col.guid == L.selGuid)
    end

    if #cols == 0 then
        emptyFS:SetText(L.Unscanned() > 0
            and "|cff888888No character counted yet: log in on each one once with Loremaster on.|r"
            or "|cff888888No character counted yet.|r")
        emptyFS:ClearAllPoints()
        emptyFS:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + 4, -(L.colHdrTop + 4))
        emptyFS:Show()
    else
        emptyFS:Hide()
    end

    local rows = L.DisplayRows(cols)
    local y = 0
    local width = x0 + nVis * colW
    L.rowY = {}
    local C = AltStable.C or {}
    local accent = C.ACCENT or GOLD
    local gr, gg, gb, ga = 1, 1, 1, 0.06
    if AltStable.SkinCardGroupColor then gr, gg, gb, ga = AltStable.SkinCardGroupColor() end
    for idx, r in ipairs(rows) do
        if r.isGroup then
            local g = Acquire("group", MakeGroup)
            g:ClearAllPoints()
            g:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            g:SetWidth(width)
            g.key = r.key
            local collapsed = db.collapsed[r.key] and not (L.search and L.search ~= "")
            g.label:SetText((collapsed and "+ " or "\226\128\147 ") .. r.label
                .. (collapsed and (" |cff888888(" .. r.n .. ")|r") or ""))
            g.bg:SetColorTexture(gr, gg, gb, ga)
            g.sep:SetColorTexture(accent[1], accent[2], accent[3], 0.6)
            y = y + GROUP_H
        else
            local selected = r.key == L.selKey
            L.rowY[r.key] = y
            if selected then
                local band = Acquire("band", MakeBand)
                band:ClearAllPoints()
                band:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
                band:SetSize(width, ROW_H)
            end
            local label = Acquire("label", MakeRowLabel)
            label:ClearAllPoints()
            label:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            label.text:SetText(L.ZoneName(r.key))
            label.text:SetTextColor(selected and GOLD[1] or 0.9, selected and GOLD[2] or 0.9, selected and GOLD[3] or 0.9)
            label.bg:SetColorTexture(1, 1, 1, idx % 2 == 0 and 0.03 or 0)
            label.rowKey = r.key
            for i = 1, nVis do
                local col = cols[L.colOffset + i]
                local row = col.snap.c and col.snap.c[r.key]
                local cell = Acquire("cell", MakeCell)
                cell:ClearAllPoints()
                cell:SetPoint("TOPLEFT", content, "TOPLEFT", x0 + (i - 1) * colW, -y)
                cell:SetSize(colW, ROW_H)
                cell.rowKey, cell.guid = r.key, col.guid
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

    if thisCheck then thisCheck:SetChecked(db.thisChar and true or false) end
    if toolbar then
        local f = FILTER_BY_ID[db.filter or "all"] or FILTER_BY_ID.all
        toolbar.filter:SetText(f.text)
        toolbar.hide:SetText(db.hideMap and "Show map" or "Hide map")
    end
    L.ApplyColors()
    if not db.hideMap then
        L.RenderMap(L.selKey)
        L.RenderCard()
    end
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

    L.BuildMap()
    L.BuildCard()
    L.BuildToolbar()

    scroll = CreateFrame("ScrollFrame", nil, panel)
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
    emptyFS:Hide()
    L.zoneHdr = FS(panel, "GameFontNormal")
    L.zoneHdr:SetText("Zone")
    L.zoneHdr:SetTextColor(unpack(Color("TEXT_BRIGHT", { 1, 1, 1 })))

    vbar = CreateFrame("Slider", nil, panel)
    vbar:SetWidth(10)
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

    L.Layout()
    panel:SetScript("OnShow", function() if L.isActive then L.Render() end end)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        local shift = rawget(_G, "IsShiftKeyDown")
        if shift and shift() and hbar:IsShown() then
            hbar:SetValue((L.colOffset or 0) - delta)
        elseif vbar:IsShown() then
            vbar:SetValue((vbar:GetValue() or 0) - delta * 3 * ROW_H)
        end
    end)
end

------------------------------------------------------------
-- The footer: the selected character's total, in the sheet's totals bar,
-- and a jump to its Class quests
------------------------------------------------------------

function L.BuildFooter(mainFrame)
    local tb = mainFrame and mainFrame.totalsBar
    if L.foot or not tb then return end
    local f = CreateFrame("Frame", nil, tb)
    f:SetAllPoints(tb)
    f:Hide()
    f.left = FS(f, "GameFontHighlightSmall")
    f.left:SetPoint("LEFT", f, "LEFT", 10, 0)
    f.class = CreateFrame("Button", nil, f)
    f.class:SetHeight(18)
    f.class:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    f.class.text = FS(f.class, "GameFontHighlightSmall", "RIGHT")
    f.class.arrow = Arrow(f.class, "right", 12)
    f.class.arrow:SetPoint("RIGHT", f.class, "RIGHT", 0, 0)
    f.class.text:SetPoint("RIGHT", f.class.arrow, "LEFT", -4, 0)
    f.class:SetScript("OnClick", function() L.JumpToClass() end)
    f.right = f.class.text   -- the name the tests read
    L.foot = f
end

-- The scrollbars (tests).
function L.Bars() return vbar, hbar end

-- Scroll the grid so a row is in view, from where Render drew it.
function L.ScrollToRow(key)
    local y = L.rowY and L.rowY[key]
    if not y or not vbar or not vbar:IsShown() then return end
    local _, max = vbar:GetMinMaxValues()
    local viewH = scroll and scroll:GetHeight() or 0
    vbar:SetValue(math.max(0, math.min(max or 0, y - math.max(0, viewH - ROW_H) / 2)))
end

-- "Class quests ▸": the Class row, selected and IN VIEW (Codex on #399): a
-- search or a filter that hides it gives way, its group opens, and the grid
-- scrolls to the row itself, not to the end.
function L.JumpToClass()
    local db = M.DB()
    db.collapsed.class = nil
    if db.filter and db.filter ~= "class" then db.filter = nil end
    if toolbar and toolbar.search and (toolbar.search:GetText() or "") ~= "" then toolbar.search:SetText("") end
    L.search = nil
    L.Select(D.CLASS_KEY)
    L.ScrollToRow(D.CLASS_KEY)
end

function L.RenderFooter()
    local f = L.foot
    if not f then return end
    local col = L.SelectedColumn()
    local snap = col and col.snap
    if not snap then
        -- Through the named core record, like the columns: a kept orphan (#418)
        -- is not shown.
        local me = UnitGUID and UnitGUID("player")
        snap = me and (not AltStable.HasNamedRecord or AltStable.HasNamedRecord(me)) and M.DB().chars[me]
    end
    if not snap then
        f.left:SetText("|cff888888Loremaster: this character is not counted yet|r")
        f.class.text:SetText("")
        return
    end
    local ar, ag, ab = GOLD[1], GOLD[2], GOLD[3]
    if AltStable.GetAccentRGB then ar, ag, ab = AltStable.GetAccentRGB() end
    local hex = ("|cff%02x%02x%02x"):format(ar * 255, ag * 255, ab * 255)
    local done, total = L.Totals(snap)
    local who = col and col.name and col.name:match("^(%S+)") or "Loremaster"
    f.left:SetText(("%s%s|r |cffaaaaaa\194\183|r %s/%s quests |cffaaaaaa\194\183 %d%%|r"):format(
        hex, who, Number(done), Number(total), Pct(done, total)))
    local cls = snap.cls or {}
    f.class.text:SetText(("|cffaaaaaaClass quests|r %d/%d |cffaaaaaa(%d at this level)|r"):format(
        cls.done or 0, cls.total or 0, cls.now or 0))
    f.class:SetWidth((f.class.text:GetStringWidth() or 160) + 20)
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
        OnDeserialize = function(guid, blob) return M.Deserialize(guid, blob) end,
        OnCleanup     = function(keep) M.Cleanup(keep) end,
        OnForget      = function(guid) M.Forget(guid) end,
        DropForgottenOrphans = function() return M.DropForgottenOrphans() end,
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
