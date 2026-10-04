------------------------------------------------------------
-- CampList.lua - the Roster's camp list (#152, part 2)
--
-- Retail's warband list, beside the scene: a search box and a + to make a camp,
-- then each camp as a header with its seats, then everyone in no camp. Drag a
-- character onto a seat or a header to put it in a camp, onto another seat to
-- reorder or swap, anywhere else in the list to take it out; drag a header onto
-- another to reorder the camps. Right-click a header to rename or delete it.
-- A toggle along the bottom tucks the whole list away.
--
-- Scene view only. The grid is a management view with its own right-click
-- menu, which already has every camp action (CharacterMenu.lua).
--
-- Its own file: AltStableRoster.lua is at Lua 5.1's upvalue limit in places,
-- and this needs nothing from it but the panel, the character list and Refresh.
------------------------------------------------------------

local Roster = AltStable and AltStable.RosterPlugin
if not Roster then return end

local L = {}
Roster.CampList = L

local LIST_W   = 260
local PAD      = 6
local SCROLL_W = 18       -- the scroll bar, inside the list
local ROW_W    = LIST_W - 2 * PAD - SCROLL_W
local HEADER_H, CHAR_H, SEP_H, GAP = 22, 32, 12, 3
local SEARCH_H, TOGGLE_H = 22, 24
L.LIST_W, L.TOGGLE_H = LIST_W, TOGGLE_H
L.MIN_SCENE_W = 360       -- the scene keeps at least this much beside the list

local list, toggle, toggleBtn, search, plusBtn, scroll, content, ghost
local dialog, dialogCatcher
local rows = {}           -- pooled row buttons, reused by position
local folded = {}         -- camp id -> true while its seats are folded away (this session)
L.shown = 0               -- how many rows the last render used
L.search = ""

local function CampSize() return AltStable.CAMP_SIZE or 5 end

local function ListHidden()
    return AltStableConfig and AltStableConfig.rosterCampListHidden == true
end

-- How much of the panel's width the list takes: all of LIST_W while it is open,
-- nothing while it is tucked away or the view is not the scene.
function L.Inset()
    return (list and list:IsShown()) and LIST_W or 0
end

------------------------------------------------------------
-- What the list shows
------------------------------------------------------------

local function Matches(char)
    if L.search == "" then return true end
    return (char and char.name or ""):lower():find(L.search, 1, true) ~= nil
end

-- The rows, top to bottom, as plain tables: built apart from the frames so a
-- test can read the list without reading pixels.
function L.Items()
    local store = type(AltStableDB) == "table" and AltStableDB or {}
    local items = {}
    local searching = L.search ~= ""
    for index, camp in ipairs(AltStable.GetCamps and AltStable.GetCamps() or {}) do
        items[#items + 1] = { kind = "header", camp = camp, index = index }
        if not folded[camp.id] then
            for pos = 1, CampSize() do
                local guid = camp.members[pos]
                local char = guid and store[guid]
                if guid and type(char) == "table" then
                    if Matches(char) then
                        items[#items + 1] = { kind = "slot", camp = camp, pos = pos, guid = guid, char = char }
                    end
                elseif not searching then
                    -- An empty seat is a place to drop someone; while searching
                    -- the list shows matches only.
                    items[#items + 1] = { kind = "slot", camp = camp, pos = pos }
                end
            end
        end
    end
    items[#items + 1] = { kind = "sep" }
    for _, char in ipairs(Roster.AllCharacters and Roster.AllCharacters(false) or {}) do
        if not AltStable.CampOf(char.guid) and Matches(char) then
            items[#items + 1] = { kind = "char", guid = char.guid, char = char }
        end
    end
    return items
end

------------------------------------------------------------
-- Moving things (the drop)
------------------------------------------------------------

-- What the dragged thing does where it lands. `drag` is { kind = "char", guid,
-- fromCamp, fromPos } or { kind = "camp", id }; `target` is a row item, or
-- { kind = "out" } for the list's empty space. Returns whether anything moved.
function L.Drop(drag, target)
    if not (drag and target) then return false end
    local done = false
    if drag.kind == "camp" then
        if target.kind == "header" and target.camp.id ~= drag.id then
            done = AltStable.MoveCamp(drag.id, target.index)
        end
    elseif drag.kind == "char" then
        local guid = drag.guid
        if target.kind == "slot" then
            local camp = target.camp
            local occupant = camp.members[target.pos]
            if occupant == guid then return false end
            if occupant and drag.fromCamp and drag.fromCamp ~= camp.id then
                -- From another camp onto someone: they swap places.
                AltStable.RemoveFromCamp(occupant)
                AltStable.AddToCamp(guid, camp.id, target.pos)
                done = AltStable.AddToCamp(occupant, drag.fromCamp, drag.fromPos)
            elseif occupant and not drag.fromCamp and #camp.members >= CampSize() then
                -- From outside onto someone in a full camp: the newcomer takes
                -- the seat, and the one sitting there leaves the camp.
                AltStable.RemoveFromCamp(occupant)
                done = AltStable.AddToCamp(guid, camp.id, target.pos)
            else
                -- An empty seat, or a move within the camp.
                done = AltStable.AddToCamp(guid, camp.id, target.pos)
            end
            if done then AltStable.SelectCamp(camp.id) end
        elseif target.kind == "header" then
            done = AltStable.AddToCamp(guid, target.camp.id)
            if done then AltStable.SelectCamp(target.camp.id) end
        elseif target.kind == "char" or target.kind == "sep" or target.kind == "out" then
            if drag.fromCamp then done = AltStable.RemoveFromCamp(guid) end
        end
    end
    if done and Roster.Refresh then Roster.Refresh() end
    return done and true or false
end

-- The row under the cursor, else the list's empty space, else nothing.
function L.TargetUnderCursor()
    for i = 1, L.shown do
        local r = rows[i]
        if r and r:IsShown() and r.item and r:IsMouseOver() then return r.item end
    end
    if list and list:IsShown() and list:IsMouseOver() then return { kind = "out" } end
end

local function MoveGhost(self)
    local x, y = GetCursorPosition()
    local s = self:GetEffectiveScale()
    local p = self:GetParent()
    if not (s and s > 0 and p and p:GetLeft()) then return end
    self:ClearAllPoints()
    self:SetPoint("CENTER", p, "BOTTOMLEFT", x / s - p:GetLeft(), y / s - p:GetBottom())
end

local function ShowGhost(text)
    if not ghost then
        -- On the panel's parent, the main window: the showcase hides UIParent,
        -- so nothing parented there would draw (CharacterMenu.lua explains).
        ghost = CreateFrame("Frame", nil, list:GetParent():GetParent())
        ghost:SetFrameStrata("TOOLTIP")
        ghost:SetSize(170, 22)
        local bg = ghost:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.85)
        ghost.text = ghost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        ghost.text:SetPoint("CENTER")
        ghost:SetScript("OnUpdate", MoveGhost)
    end
    ghost.text:SetText(text or "")
    ghost:Show()
    MoveGhost(ghost)
end

function L.DragStart(row)
    local it = row and row.item
    if not it then return end
    if it.kind == "header" then
        L.drag = { kind = "camp", id = it.camp.id, label = it.camp.name }
    elseif (it.kind == "slot" or it.kind == "char") and it.guid then
        L.drag = { kind = "char", guid = it.guid, fromCamp = it.camp and it.camp.id,
                   fromPos = it.pos, label = it.char and it.char.name }
    else
        return
    end
    ShowGhost(L.drag.label)
end

function L.DragStop()
    local drag = L.drag
    L.drag = nil
    if ghost then ghost:Hide() end
    if drag then L.Drop(drag, L.TargetUnderCursor()) end
end

------------------------------------------------------------
-- The camp dialog: name it, rename it, delete it
------------------------------------------------------------

local function Trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

function L.CloseDialog()
    if dialog then dialog:Hide() end
    if dialogCatcher then dialogCatcher:Hide() end
end

local function ShowConfirm(on)
    dialog.confirm:SetShown(on)
    dialog.edit:SetShown(not on)
end

function L.AcceptDialog()
    local name = Trim(dialog.box:GetText())
    if name == "" then return false end
    local camp = dialog.camp
    if camp then
        AltStable.RenameCamp(camp.id, name)
    else
        local id = AltStable.CreateCamp(name)
        AltStable.SelectCamp(id)
    end
    L.CloseDialog()
    if Roster.Refresh then Roster.Refresh() end
    return true
end

function L.ConfirmDelete()
    local camp = dialog.camp
    if camp then AltStable.DeleteCamp(camp.id) end
    L.CloseDialog()
    if Roster.Refresh then Roster.Refresh() end
end

local function Button(parent, w, text, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function BuildDialog()
    if dialog then return end
    local panel = list:GetParent()
    dialogCatcher = CreateFrame("Button", nil, panel)
    dialogCatcher:SetAllPoints(panel)
    dialogCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
    dialogCatcher:RegisterForClicks("AnyUp")
    dialogCatcher:SetScript("OnClick", function() L.CloseDialog() end)
    local dim = dialogCatcher:CreateTexture(nil, "BACKGROUND")
    dim:SetAllPoints()
    dim:SetColorTexture(0, 0, 0, 0.55)
    dialogCatcher:Hide()

    dialog = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    dialog:SetFrameStrata("FULLSCREEN_DIALOG")
    dialog:SetFrameLevel(dialogCatcher:GetFrameLevel() + 5)
    dialog:SetSize(320, 120)
    dialog:SetPoint("CENTER", panel, "CENTER")
    dialog:EnableMouse(true)
    if not (AltStable.SkinWindow and AltStable.SkinWindow(dialog, "small")) then
        if AltStable.ApplyBackdrop then AltStable.ApplyBackdrop(dialog, 0.08, 0.08, 0.1, 0.98) end
    end
    local body = dialog:CreateTexture(nil, "BACKGROUND", nil, 1)
    body:SetPoint("TOPLEFT", 6, -6)
    body:SetPoint("BOTTOMRIGHT", -6, 6)
    body:SetColorTexture(0.06, 0.065, 0.08, 0.94)
    dialog:Hide()

    -- Escape closes and is swallowed; every other key goes on to the game.
    dialog:SetScript("OnKeyDown", function(self, key)
        local stop = (key == "ESCAPE")
        if type(self.SetPropagateKeyboardInput) == "function" then
            pcall(self.SetPropagateKeyboardInput, self, not stop)
        end
        if stop then L.CloseDialog() end
    end)

    -- Naming: the box, Accept and Cancel, and Delete for a camp that exists.
    local edit = CreateFrame("Frame", nil, dialog)
    edit:SetAllPoints()
    dialog.edit = edit
    local title = edit:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -14)
    title:SetText("Enter Camp Name")
    local box = CreateFrame("EditBox", nil, edit, "InputBoxTemplate")
    box:SetSize(260, 22)
    box:SetPoint("TOP", 0, -36)
    box:SetAutoFocus(false)
    box:SetMaxLetters(32)
    box:SetScript("OnEscapePressed", function() L.CloseDialog() end)
    box:SetScript("OnEnterPressed", function() L.AcceptDialog() end)
    box:SetScript("OnTextChanged", function(self)
        if dialog.accept then dialog.accept:SetEnabled(Trim(self:GetText()) ~= "") end
    end)
    dialog.box = box
    dialog.accept = Button(edit, 90, "Accept", function() L.AcceptDialog() end)
    dialog.accept:SetPoint("TOPRIGHT", box, "BOTTOM", -6, -10)
    dialog.cancel = Button(edit, 90, "Cancel", function() L.CloseDialog() end)
    dialog.cancel:SetPoint("TOPLEFT", box, "BOTTOM", 6, -10)
    dialog.delete = Button(edit, 90, "Delete", function() ShowConfirm(true) end)
    dialog.delete:SetPoint("BOTTOM", 0, 10)

    -- Deleting asks first, in the same box.
    local confirm = CreateFrame("Frame", nil, dialog)
    confirm:SetAllPoints()
    confirm:Hide()
    dialog.confirm = confirm
    dialog.question = confirm:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dialog.question:SetPoint("TOP", 0, -24)
    dialog.question:SetWidth(290)
    dialog.yes = Button(confirm, 90, "Yes", function() L.ConfirmDelete() end)
    dialog.yes:SetPoint("BOTTOMRIGHT", dialog, "BOTTOM", -6, 20)
    dialog.no = Button(confirm, 90, "No", function() ShowConfirm(false) end)
    dialog.no:SetPoint("BOTTOMLEFT", dialog, "BOTTOM", 6, 20)
end

-- `camp`: rename or delete it. nil: name a new one.
function L.OpenDialog(camp)
    BuildDialog()
    dialog.camp = camp
    local name = camp and camp.name or ("Camp " .. (#AltStable.GetCamps() + 1))
    dialog.box:SetText(name)
    dialog.accept:SetEnabled(Trim(name) ~= "")
    dialog.delete:SetShown(camp ~= nil)
    dialog:SetHeight(camp and 130 or 100)
    dialog.question:SetText(camp and ("Are you sure you want to delete camp %s?"):format(camp.name) or "")
    ShowConfirm(false)
    dialogCatcher:Show()
    dialog:Show()
    if type(dialog.EnableKeyboard) == "function" and not (InCombatLockdown and InCombatLockdown()) then
        dialog:EnableKeyboard(true)
        if type(dialog.SetPropagateKeyboardInput) == "function" then
            pcall(dialog.SetPropagateKeyboardInput, dialog, true)
        end
    end
    dialog.box:SetFocus()
    dialog.box:HighlightText()
end

function L.Dialog() return dialog end

------------------------------------------------------------
-- Building and drawing
------------------------------------------------------------

local function OnRowClick(self, button)
    local it = self.item
    if not it then return end
    if it.kind == "header" then
        if button == "RightButton" then
            L.OpenDialog(it.camp)
        else
            AltStable.SelectCamp(it.camp.id)
            folded[it.camp.id] = nil
            if Roster.Refresh then Roster.Refresh() end
        end
    elseif it.char then
        if button == "RightButton" then
            if AltStable.ShowCharacterMenu then AltStable.ShowCharacterMenu(it.char) end
        elseif it.camp then
            AltStable.SelectCamp(it.camp.id)
            if Roster.Refresh then Roster.Refresh() end
        end
    end
end

local function Row(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Button", nil, content)
    r:SetWidth(ROW_W)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.07)
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.text:SetPoint("LEFT", 8, 0)
    r.text:SetPoint("RIGHT", -26, 0)
    r.text:SetJustifyH("LEFT")
    r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.sub:SetPoint("TOPLEFT", r.text, "BOTTOMLEFT", 0, -1)
    r.sub:SetJustifyH("LEFT")
    -- Fold a camp's seats away: its own button, so clicking the name selects.
    r.fold = CreateFrame("Button", nil, r)
    r.fold:SetSize(20, 20)
    r.fold:SetPoint("RIGHT", -2, 0)
    r.fold.text = r.fold:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    r.fold.text:SetPoint("CENTER")
    r.fold:SetScript("OnClick", function(self)
        local it = r.item
        if it and it.camp then
            folded[it.camp.id] = not folded[it.camp.id] or nil
            L.Render(true)
        end
    end)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:RegisterForDrag("LeftButton")
    r:SetScript("OnClick", OnRowClick)
    r:SetScript("OnDragStart", function(self) L.DragStart(self) end)
    r:SetScript("OnDragStop", function() L.DragStop() end)
    rows[i] = r
    return r
end

local function Paint(r, it, shownCamp)
    r.item = it
    r.fold:Hide()
    r.sub:SetText("")
    r.text:ClearAllPoints()
    r.text:SetPoint("RIGHT", -26, 0)
    r:SetAlpha(1)
    if it.kind == "header" then
        r:SetHeight(HEADER_H)
        r.bg:SetColorTexture(0.17, 0.09, 0.08, 0.95)
        r.text:SetPoint("LEFT", 8, 0)
        r.text:SetFontObject(GameFontNormal)
        local name = it.camp.name or "Camp"
        if shownCamp and shownCamp.id == it.camp.id then
            local ar, ag, ab = AltStable.GetAccentRGB()
            r.text:SetText(name)
            r.text:SetTextColor(ar, ag, ab)
        else
            r.text:SetText(name)
            r.text:SetTextColor(0.95, 0.95, 0.95)
        end
        r.fold.text:SetText(folded[it.camp.id] and "+" or "-")
        r.fold:Show()
    elseif it.kind == "sep" then
        r:SetHeight(SEP_H)
        r.bg:SetColorTexture(0.5, 0.5, 0.5, 0.25)
        r.text:SetText("")
    elseif it.char then
        r:SetHeight(CHAR_H)
        r.bg:SetColorTexture(0.07, 0.07, 0.08, 0.92)
        r.text:SetPoint("TOPLEFT", 8, -3)
        r.text:SetFontObject(GameFontNormal)
        local c = it.char
        r.text:SetText((AltStable.ClassColor and AltStable.ClassColor(c.class) or "") .. (c.name or "?") .. "|r")
        r.text:SetTextColor(1, 1, 1)
        local class = AltStable.ClassDisplayName and AltStable.ClassDisplayName(c) or (c.class or "")
        local hidden = AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(c.guid)
        r.sub:SetText(("Level %d %s%s"):format(c.level or 0, class or "", hidden and "  (hidden)" or ""))
        if hidden then r:SetAlpha(0.5) end
    else
        -- An empty seat.
        r:SetHeight(CHAR_H)
        r.bg:SetColorTexture(0.04, 0.04, 0.05, 0.7)
        r.text:SetPoint("LEFT", 8, 0)
        r.text:SetFontObject(GameFontDisableSmall)
        r.text:SetText("+  drag a character here")
        r.text:SetTextColor(0.5, 0.5, 0.5)
    end
end

local function Build()
    if list then return end
    local panel = Roster.panel
    if not panel then return end

    list = CreateFrame("Frame", nil, panel)
    list:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    list:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, TOGGLE_H)
    list:SetWidth(LIST_W)
    list:SetFrameLevel(panel:GetFrameLevel() + 20)
    list:EnableMouse(true)
    local bg = list:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.03, 0.03, 0.04, 0.9)
    list:Hide()

    search = CreateFrame("EditBox", nil, list, "SearchBoxTemplate")
    search:SetSize(LIST_W - 2 * PAD - 34, SEARCH_H)
    search:SetPoint("TOPLEFT", PAD + 4, -PAD)
    search:SetAutoFocus(false)
    search:HookScript("OnTextChanged", function(self)
        L.search = Trim(self:GetText() or ""):lower()
        L.Render(true)
    end)

    plusBtn = CreateFrame("Button", nil, list, "UIPanelButtonTemplate")
    plusBtn:SetSize(26, SEARCH_H)
    plusBtn:SetPoint("TOPRIGHT", -PAD, -PAD)
    plusBtn:SetText("+")
    plusBtn:SetScript("OnClick", function() L.OpenDialog(nil) end)
    plusBtn:SetScript("OnEnter", function(self)
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT"); GameTooltip:ClearLines()
            GameTooltip:AddLine("New camp", 1, 1, 1); GameTooltip:Show()
        end
    end)
    plusBtn:SetScript("OnLeave", function(self)
        if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)

    scroll = CreateFrame("ScrollFrame", nil, list, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", PAD, -(PAD + SEARCH_H + 6))
    scroll:SetPoint("BOTTOMRIGHT", -(PAD + SCROLL_W), PAD)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(ROW_W, 1)
    scroll:SetScrollChild(content)

    -- Along the bottom, like retail's: it stays when the list is tucked away.
    toggle = CreateFrame("Frame", nil, panel)
    toggle:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
    toggle:SetSize(LIST_W, TOGGLE_H)
    toggle:SetFrameLevel(panel:GetFrameLevel() + 20)
    local tbg = toggle:CreateTexture(nil, "BACKGROUND")
    tbg:SetAllPoints()
    tbg:SetColorTexture(0.03, 0.03, 0.04, 0.9)
    local tl = toggle:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tl:SetPoint("RIGHT", -34, 0)
    tl:SetText("CAMPS")
    toggleBtn = CreateFrame("Button", nil, toggle, "UIPanelButtonTemplate")
    toggleBtn:SetSize(24, 20)
    toggleBtn:SetPoint("RIGHT", -4, 0)
    toggleBtn:SetScript("OnClick", function()
        AltStable.SetConfigValue("rosterCampListHidden", not ListHidden())
        if Roster.Refresh then Roster.Refresh() end
    end)
    toggle:Hide()
end

-- Draw the list for the current state. `sceneView` false hides it entirely.
function L.Render(sceneView)
    Build()
    if not list then return end
    if not sceneView then
        list:Hide(); toggle:Hide()
        L.CloseDialog()
        return
    end
    -- Too narrow a panel for the list AND a scene worth looking at: the list
    -- steps aside, toggle and all, rather than squeezing the camp to nothing.
    if (Roster.panel:GetWidth() or 0) < LIST_W + L.MIN_SCENE_W then
        list:Hide(); toggle:Hide()
        L.shown = 0
        return
    end
    toggle:Show()
    local hidden = ListHidden()
    -- Retail's arrow: down tucks the list away, up brings it back.
    toggleBtn:SetText(hidden and "^" or "v")
    if hidden then
        list:Hide()
        toggle:SetWidth(140)
        return
    end
    toggle:SetWidth(LIST_W)
    list:Show()

    local shownCamp = AltStable.SelectedCamp and AltStable.SelectedCamp()
    local items = L.Items()
    local y = 0
    for i, it in ipairs(items) do
        local r = Row(i)
        Paint(r, it, shownCamp)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        r:Show()
        y = y + r:GetHeight() + GAP
    end
    for i = #items + 1, #rows do rows[i]:Hide(); rows[i].item = nil end
    L.shown = #items
    content:SetHeight(math.max(1, y))
end

-- For tests: the frames.
L._test = {
    List = function() return list end, Toggle = function() return toggle end,
    ToggleButton = function() return toggleBtn end, Search = function() return search end,
    Plus = function() return plusBtn end, Rows = function() return rows end,
    Folded = folded,
}
