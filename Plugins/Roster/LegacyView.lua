------------------------------------------------------------
-- LegacyView.lua - each alt's Legacy talents, in the Roster (#500)
--
-- The detail pane's "Legacy" group: the points spent of what the character
-- could spend, one row per tree with a tooltip of its chosen talents, and a
-- View button. View opens AltStable's own read-only tree: Blizzard's Legacy
-- window has no inspect mode, and a copy of its panel would keep a Reset
-- wired to the character being played and draw that character's gates and
-- edges (plan review on #500). This one is drawn from the account-wide
-- layout (LegacyTalents.lua) and the alt's saved choices; nothing in it calls
-- the game's talent functions beyond tooltips.
--
-- Its own file: AltStableRoster.lua is at Lua 5.1's local and upvalue limits.
------------------------------------------------------------

local Roster = AltStable and AltStable.RosterPlugin
if not Roster then return end

local LV = {}
Roster.LegacyView = LV

local function LT() return AltStable.LegacyTalents end

local UNKNOWN_ICON = 134400   -- the question mark
local NODE_SIZE    = 36
local CANVAS       = 300      -- the tree's drawing area, square
local PAD          = 28

------------------------------------------------------------
-- Names and icons
------------------------------------------------------------

-- The layout's entries by ID, for names and icons the game overrides.
local function LayoutEntries(layout)
    local out = {}
    for _, t in ipairs(layout and layout.trees or {}) do
        for _, n in ipairs(t.nodes or {}) do
            for _, e in ipairs(n.entries or {}) do out[e.id] = e end
        end
    end
    return out
end

local function SpellName(spell)
    local s = rawget(_G, "C_Spell")
    local f = type(s) == "table" and s.GetSpellName
    if type(f) ~= "function" or not spell or spell == 0 then return nil end
    local ok, name = pcall(f, spell)
    if ok and type(name) == "string" and name ~= "" and name ~= "Unknown" then return name end
    return nil
end

-- The first line of the game's own tooltip for a talent at a rank.
local function TraitEntryName(entry, rank)
    local t = rawget(_G, "C_TooltipInfo")
    local f = type(t) == "table" and t.GetTraitEntry
    if type(f) ~= "function" or not entry then return nil end
    local ok, data = pcall(f, entry, rank)
    if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
    for _, line in ipairs(data.lines) do
        local text = type(line) == "table" and line.leftText
        if type(text) == "string" and text ~= "" then return text end
    end
    return nil
end

-- A talent's name: the game's override, the spell's, the trait tooltip's.
function LV.TalentName(n, entries)
    local e = entries and entries[n.entry]
    return (e and e.name) or SpellName(n.spell) or TraitEntryName(n.entry, math.max(n.entryRank or n.rank, 1))
        or ("Talent " .. tostring(n.entry))
end

function LV.TalentIcon(n, entries)
    local e = entries and entries[n.entry]
    if e and e.icon then return e.icon end
    local s = rawget(_G, "C_Spell")
    local f = type(s) == "table" and s.GetSpellTexture
    if type(f) == "function" and n.spell and n.spell > 0 then
        local ok, icon = pcall(f, n.spell)
        if ok and icon then return icon end
    end
    return UNKNOWN_ICON
end

------------------------------------------------------------
-- The detail pane's rows
------------------------------------------------------------

function LV.HasRow(char, def)
    return LT() ~= nil and LT().Get(char) ~= nil
end

function LV.Label(char, def)
    if def.legacyTree then return LT().TreeName(LT().TREES[def.legacyTree]) end
    return def.label or ""
end

function LV.Value(char, def)
    local r = LT() and LT().Get(char)
    if not r then return "-" end
    if def.legacyPoints then
        local spent, cap = LT().Points(r)
        return cap > 0 and (spent .. "/" .. cap) or tostring(spent)
    end
    local t = r.trees[def.legacyTree]
    return t and tostring(t.spent) or "-"
end

-- The tooltip lines of a row, as { text, r, g, b } (tested without frames).
function LV.RowTip(char, def)
    local r = LT() and LT().Get(char)
    if not r then return nil end
    local entries = LayoutEntries(LT().Layout())
    local lines = {}
    if def.legacyPoints then
        local spent, cap = LT().Points(r)
        lines[1] = { "Legacy talents" }
        lines[2] = { ("%d of %d points spent"):format(spent, cap), 1, 1, 1 }
        for i, t in ipairs(r.trees) do
            lines[#lines + 1] = { ("%s: %d"):format(LT().TreeName(LT().TREES[i]), t.spent), 0.8, 0.8, 0.8 }
        end
    else
        local t = r.trees[def.legacyTree]
        if not t then return nil end
        lines[1] = { ("%s: %d points"):format(LT().TreeName(t.tree), t.spent) }
        for _, n in ipairs(t.nodes) do
            lines[#lines + 1] = { ("|T%s:14|t %s %d/%d"):format(tostring(LV.TalentIcon(n, entries)),
                LV.TalentName(n, entries), n.rank, n.max), 1, 1, 1 }
        end
        if #t.nodes == 0 then lines[2] = { "No talent chosen.", 0.7, 0.7, 0.7 } end
    end
    lines[#lines + 1] = { "As of when it was last played.", 0.5, 0.5, 0.5 }
    return lines
end

local function ShowLines(owner, lines)
    if not lines then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    for i, l in ipairs(lines) do
        if i == 1 then GameTooltip:SetText(l[1]) else GameTooltip:AddLine(l[1], l[2], l[3], l[4], true) end
    end
    GameTooltip:Show()
end

-- An invisible frame over a row, for its tooltip.
function LV.MakeHit(parent)
    local hit = CreateFrame("Frame", nil, parent)
    hit:EnableMouse(true)
    hit:SetScript("OnEnter", function(self) ShowLines(self, LV.RowTip(self.char, self.def)) end)
    hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    hit:Hide()
    return hit
end

function LV.PlaceHit(hit, row, char)
    hit.char, hit.def = char, row.def
    hit:ClearAllPoints()
    hit:SetPoint("TOPLEFT", row.label, "TOPLEFT", 0, 0)
    hit:SetPoint("BOTTOMRIGHT", row.value, "BOTTOMRIGHT", 0, 0)
    hit:Show()
end

------------------------------------------------------------
-- What the view draws (no frames: tested on its own)
------------------------------------------------------------

-- Whether the view can draw a character: a reading, a layout for this build,
-- and every saved talent in it. false and why otherwise.
function LV.CanView(char)
    local r = LT() and LT().Get(char)
    if not r then return false, "No Legacy talents read for this character yet." end
    local layout = LT().Layout()
    if not layout then
        return false, "Log in any character with its Legacy trees open on this game version to learn the trees' layout."
    end
    for i, t in ipairs(r.trees) do
        local known = {}
        for _, n in ipairs(layout.trees[i].nodes or {}) do
            known[n.id] = {}
            for _, e in ipairs(n.entries or {}) do known[n.id][e.id] = true end
        end
        for _, n in ipairs(t.nodes) do
            if not (known[n.id] and known[n.id][n.entry]) then
                return false, "This character has a talent the saved layout doesn't know: log in any character to read the trees again."
            end
        end
    end
    return true
end

-- One tree, drawn: each node with its position on the canvas, the saved rank
-- and the entry to show; the edges between them.
function LV.Model(char, index)
    local r, layout = LT().Get(char), LT().Layout()
    local lt = layout and layout.trees[index]
    if not (r and lt) then return nil end
    local chosen = {}
    for _, n in ipairs(r.trees[index].nodes) do chosen[n.id] = n end
    local minX, maxX, minY, maxY
    for _, n in ipairs(lt.nodes) do
        minX, maxX = math.min(minX or n.x, n.x), math.max(maxX or n.x, n.x)
        minY, maxY = math.min(minY or n.y, n.y), math.max(maxY or n.y, n.y)
    end
    local span = math.max((maxX or 0) - (minX or 0), (maxY or 0) - (minY or 0), 1)
    local scale = (CANVAS - 2 * PAD) / span
    local model = { nodes = {}, edges = {}, tree = lt.tree, spent = r.trees[index].spent }
    for _, n in ipairs(lt.nodes) do
        local c = chosen[n.id]
        local first = n.entries and n.entries[1]
        model.nodes[#model.nodes + 1] = {
            id = n.id, px = PAD + (n.x - minX) * scale, py = PAD + (n.y - minY) * scale,
            rank = c and c.rank or 0, max = c and c.max or n.max,
            -- The badge shows the node's rank; the tooltip takes the entry's.
            entryRank = c and (c.entryRank or c.rank) or 0,
            entry = c and c.entry or (first and first.id), spell = c and c.spell or (first and first.spell) or 0,
            choices = (n.type == 2 or n.type == 3) and #(n.entries or {}) or nil,
        }
        for _, to in ipairs(n.edges or {}) do model.edges[#model.edges + 1] = { from = n.id, to = to } end
    end
    return model
end

------------------------------------------------------------
-- The window
------------------------------------------------------------

local win

local function NodeTooltip(self)
    local n = self.node
    if not n then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local shown = false
    if n.entry and type(GameTooltip.SetTraitEntry) == "function" then
        shown = pcall(GameTooltip.SetTraitEntry, GameTooltip, n.entry, math.max(n.entryRank or n.rank, 1))
        shown = shown and GameTooltip:NumLines() > 0
    end
    if not shown and n.spell and n.spell > 0 then shown = pcall(GameTooltip.SetSpellByID, GameTooltip, n.spell) end
    if not shown then GameTooltip:SetText(LV.TalentName(n, win and win.entries)) end
    if n.choices then GameTooltip:AddLine(("A choice of %d talents."):format(n.choices), 0.8, 0.8, 0.8) end
    GameTooltip:AddLine(("Rank %d/%d"):format(n.rank, n.max), 1, 0.82, 0)
    GameTooltip:Show()
end

local function NodeButton(i)
    win.nodes[i] = win.nodes[i] or (function()
        local b = CreateFrame("Frame", nil, win.canvas, "BackdropTemplate")
        b:SetSize(NODE_SIZE, NODE_SIZE)
        b:SetFrameLevel(win.canvas:GetFrameLevel() + 2)
        b:SetBackdrop({ edgeFile = "Interface/Buttons/WHITE8X8", edgeSize = 2 })
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetPoint("TOPLEFT", 2, -2)
        b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
        b.rank = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        b.rank:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 6, -6)
        b:EnableMouse(true)
        b:SetScript("OnEnter", NodeTooltip)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return b
    end)()
    return win.nodes[i]
end

local function Line(i)
    if not win.canvas.CreateLine then return nil end
    win.lines[i] = win.lines[i] or win.canvas:CreateLine(nil, "BACKGROUND")
    return win.lines[i]
end

function LV.Draw(index)
    if not (win and win.char) then return end
    win.index = index
    local model = LV.Model(win.char, index)
    for _, b in ipairs(win.nodes) do b:Hide() end
    for _, l in ipairs(win.lines) do l:Hide() end
    -- Each tab as wide as its name and points, in a row; the window widens
    -- when they need more than the canvas (in game, "Resourcefulness (0)"
    -- ran out of its third of the row and past the window's edge).
    local x = 20
    for i, tab in ipairs(win.tabs) do
        local r = LT().Get(win.char)
        local text = ("%s (%d)"):format(LT().TreeName(LT().TREES[i]), r and r.trees[i].spent or 0)
        tab:SetText(text)
        win.measure:SetText(text)
        local w = math.max(60, math.ceil((tonumber(win.measure:GetStringWidth()) or 0) + 24))
        tab:SetWidth(w)
        tab:ClearAllPoints()
        tab:SetPoint("TOPLEFT", win, "TOPLEFT", x, -58)
        x = x + w + 4
        if tab.SetEnabled then tab:SetEnabled(i ~= index) end
    end
    win:SetWidth(math.max(CANVAS + 40, x - 4 + 20))
    if not model then return end
    local byId = {}
    for i, n in ipairs(model.nodes) do
        local b = NodeButton(i)
        b.node = n
        b:ClearAllPoints()
        b:SetPoint("CENTER", win.canvas, "TOPLEFT", n.px, -n.py)
        b.icon:SetTexture(LV.TalentIcon(n, win.entries))
        if b.icon.SetDesaturated then b.icon:SetDesaturated(n.rank == 0) end
        b:SetBackdropBorderColor(n.rank > 0 and 1 or 0.35, n.rank > 0 and 0.82 or 0.35, n.rank > 0 and 0 or 0.35, 1)
        b.rank:SetText(("%d/%d"):format(n.rank, n.max))
        b:Show()
        byId[n.id] = b
    end
    for i, e in ipairs(model.edges) do
        local line, a, z = Line(i), byId[e.from], byId[e.to]
        if line and a and z then
            line:SetThickness(2)
            line:SetColorTexture(0.55, 0.55, 0.55, 0.9)
            line:SetStartPoint("CENTER", a)
            line:SetEndPoint("CENTER", z)
            line:Show()
        end
    end
end

local function Build()
    win = CreateFrame("Frame", "AltStableLegacyTree", UIParent, "BackdropTemplate")
    win:SetSize(CANVAS + 40, CANVAS + 110)
    win:SetPoint("CENTER")
    win:SetFrameStrata("DIALOG")
    win:SetToplevel(true)
    win:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    win:SetBackdropColor(0.05, 0.05, 0.08, 0.97)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    tinsert(UISpecialFrames, "AltStableLegacyTree")
    win:SetScript("OnHide", function(self)
        if AltStable.LiftAboveHiddenUI then AltStable.LiftAboveHiddenUI(self, false) end
    end)
    win.title = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    win.title:SetPoint("TOP", 0, -16)
    win.sub = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    win.sub:SetPoint("TOP", win.title, "BOTTOM", 0, -4)
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)
    win.tabs = {}
    for i = 1, 3 do
        local tab = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        tab:SetHeight(20)                  -- its width and place: LV.Draw
        tab:SetScript("OnClick", function() LV.Draw(i) end)
        win.tabs[i] = tab
    end
    -- Measures a tab's text in the buttons' font.
    win.measure = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    win.measure:Hide()
    win.canvas = CreateFrame("Frame", nil, win)
    win.canvas:SetSize(CANVAS, CANVAS)
    win.canvas:SetPoint("TOP", win, "TOP", 0, -84)
    win.nodes, win.lines = {}, {}
end

-- Opens the read-only tree of a character. False when it can't be drawn.
function LV.View(guid)
    local char = type(AltStableDB) == "table" and guid and AltStableDB[guid]
    if not (char and LV.CanView(char)) then return false end
    if not win then Build() end
    win.char = char
    win.entries = LayoutEntries(LT().Layout())
    local spent, cap = LT().Points(LT().Get(char))
    win.title:SetText(("%s - Legacy talents"):format(tostring(char.name or "?")))
    win.sub:SetText(("%d of %d points spent, as of when it was last played. Read-only."):format(spent, cap))
    -- Lifted only with the game UI hidden: the lift claims LibShowcase's
    -- shared frame, which a plain window mustn't hold (as CharacterMenu).
    if AltStable.LiftAboveHiddenUI and AltStable.IsGameUIHidden then
        AltStable.LiftAboveHiddenUI(win, AltStable.IsGameUIHidden())
    end
    win:Show()
    win:Raise()
    LV.Draw(win.index or 1)
    return true
end

------------------------------------------------------------
-- The View button beside the "Legacy" header
------------------------------------------------------------

function LV.MakeButton(parent)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(44, 16)
    b:SetText("View")
    if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
    b:SetScript("OnClick", function(self) LV.View(self.guid) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Legacy talents")
        local char = type(AltStableDB) == "table" and AltStableDB[self.guid]
        local ok, why = LV.CanView(char)
        GameTooltip:AddLine(ok and "Opens this character's Legacy trees as they were when it was last played. Read-only."
            or why, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:Hide()
    return b
end

-- Right-aligned with the column's values, on the header's line. Placed only
-- with the group, which shows only for a character with a reading.
function LV.PlaceButton(b, guid, right, y)
    b.guid = guid
    local char = type(AltStableDB) == "table" and guid and AltStableDB[guid]
    b:ClearAllPoints()
    b:SetPoint("TOPRIGHT", b:GetParent(), "TOPLEFT", right, y + 2)
    b:SetEnabled((LV.CanView(char)))
    b:Show()
end

LV._test = { LayoutEntries = LayoutEntries, Window = function() return win end }
