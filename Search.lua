------------------------------------------------------------
-- Search.lua: find an item on every character (#503)
--
-- One window: type part of an item's name, see who holds it and where - bags,
-- bank, mail (the Warband plugin's records) and worn gear (the core's). Enter
-- opens the Warband tab on the first holder with the item lit; Shift+Enter
-- puts its link in chat.
--
-- In the core, not a plugin: worn gear is the core's, and a search for worn
-- gear works with every plugin off. What a plugin knows comes through what it
-- publishes while it is loaded (AltStable.ItemMapsFor), and its absence is
-- said, never read as "none".
--
-- The plan, agreed over five Codex review rounds, is on the issue
-- (https://github.com/Spotnick2/AltStable/issues/503). The parts that are
-- easy to get wrong:
--   * Counts come from ItemMapsFor, one call per character the sheet lists.
--     Not CountItem: that counts hidden characters too, which is right for
--     an item's tooltip and wrong here. ItemMapsFor already holds the mail
--     rules (what is in flight to a character counts once, under them).
--   * One snapshot per change of data, not per keystroke. Rebuilt when the
--     Warband plugin restamps a section (NotifyItemDataChanged) and on the
--     public "CharactersChanged" (a sheet refresh, a scan, a record touched),
--     while the window is open.
--   * Item names come from the client's cache, which knows only what it has
--     seen. The missing ones are asked for at most 20 at a time; an answer
--     with no name, or none in 10 s, retires the item for the session.
------------------------------------------------------------

local S = {}
AltStable._search = S

local MAX_PENDING   = 20      -- item loads asked for at once
local LOAD_TIMEOUT  = 10      -- seconds before a load with no answer is given up
local REBUILD_DELAY = 0.2     -- a burst of writes, one rebuild
local TYPE_DELAY    = 0.15    -- after the last keystroke
local REPAINT_DELAY = 0.25    -- names arriving, one repaint
local MIN_CHARS     = 2
local ROWS          = 10
local ROW_H         = 34
local WIN_W         = 470

local frame                   -- the window, built on first open

------------------------------------------------------------
-- Text: folded with the client's own lowercase, which knows more than
-- ASCII; the query's length in characters, not bytes.
------------------------------------------------------------

local function Fold(s)
    if C_Intl and C_Intl.ToLower then return C_Intl.ToLower(s) end
    return s:lower()
end

local function Chars(s)
    if strlenutf8 then return strlenutf8(s) end
    return #s
end

------------------------------------------------------------
-- The snapshot: every item a listed character holds or wears
------------------------------------------------------------

local PLACES = { "bags", "bank", "mail" }

-- The characters the sheet lists: a named record, not hidden. A forgotten
-- character has no record, so what someone mailed it never shows here.
local function Eligible(guid, c)
    if type(c) ~= "table" or c.name == nil then return false end
    return not (AltStable.IsCharacterHidden and AltStable.IsCharacterHidden(guid))
end

function S.BuildSnapshot()
    local snap = {}
    local mapsFor = AltStable.ItemMapsFor
    local function add(id, guid, c, place, n)
        id, n = tonumber(id), tonumber(n)
        if not id or not n or n <= 0 then return end
        local e = snap[id]
        if not e then e = { id = id, total = 0, holders = {}, by = {} }; snap[id] = e end
        local h = e.by[guid]
        if not h then
            h = { guid = guid, name = c.name, class = c.class, total = 0,
                  bags = 0, bank = 0, mail = 0, worn = 0 }
            e.by[guid] = h
            e.holders[#e.holders + 1] = h
        end
        h[place] = h[place] + n
        h.total = h.total + n
        e.total = e.total + n
    end
    for guid, c in pairs(AltStableDB or {}) do
        if Eligible(guid, c) then
            local maps = mapsFor and mapsFor(guid)
            if maps then
                for _, place in ipairs(PLACES) do
                    for id, n in pairs(maps[place] or {}) do add(id, guid, c, place, n) end
                end
            end
            -- Worn: one per slot, so two of one ring are two. The item's id
            -- is enough to know the item; the exact string (suffix, enchant)
            -- is what the gear model can call unknown, not the item.
            for _, slot in ipairs(AltStable.GEAR_SLOTS or {}) do
                local id = tonumber(c["gearid_" .. slot.key])
                if id and id > 0 then add(id, guid, c, "worn", 1) end
            end
        end
    end
    for _, e in pairs(snap) do
        table.sort(e.holders, function(a, b)
            if a.total ~= b.total then return a.total > b.total end
            return (a.name or "") < (b.name or "")
        end)
    end
    return snap
end

------------------------------------------------------------
-- Names, asked for at a pace
------------------------------------------------------------

-- names[id]: the name, or false once retired without one (never asked again
-- this session). folded[id]: the name, folded for matching.
S.names, S.folded, S.queue, S.pending, S.outstanding = {}, {}, {}, {}, 0

local function NameNow(id)
    local nm = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
    if type(nm) == "string" and nm ~= "" then return nm end
    return nil
end

local function Known(id, nm)
    S.names[id] = nm
    S.folded[id] = nm and Fold(nm) or nil
end

local ScheduleRepaint, ArmTimeout

local function Pump()
    while S.outstanding < MAX_PENDING and #S.queue > 0 do
        local id = table.remove(S.queue, 1)
        if S.names[id] == nil and not S.pending[id] then
            S.pending[id] = GetTime()
            S.outstanding = S.outstanding + 1
            C_Item.RequestLoadItemDataByID(id)
        end
    end
    if S.outstanding > 0 then ArmTimeout() end
end

-- The candidates of a rebuild: each item with no name yet is queued once.
local function QueueNames(snap)
    local queued = {}
    for _, id in ipairs(S.queue) do queued[id] = true end
    for id in pairs(snap) do
        if S.names[id] == nil and not S.pending[id] and not queued[id] then
            local nm = NameNow(id)
            if nm then Known(id, nm)
            else S.queue[#S.queue + 1] = id; queued[id] = true end
        end
    end
    Pump()
end

local function Retire(id)
    if not S.pending[id] then return end
    S.pending[id] = nil
    S.outstanding = S.outstanding - 1
    Known(id, NameNow(id) or false)
end

function S.OnItemDataLoaded(id)
    id = tonumber(id)
    if not id or not S.pending[id] then return end   -- not ours
    Retire(id)
    Pump()
    ScheduleRepaint()
end

-- A load that never answers would hold its place for good, and the status
-- would say "looking up" for good: given up after LOAD_TIMEOUT.
local timeoutArmed
function ArmTimeout()
    if timeoutArmed then return end
    timeoutArmed = true
    C_Timer.After(1, function()
        timeoutArmed = nil
        if not (frame and frame:IsShown()) then return end
        local now, any = GetTime(), false
        for id, at in pairs(S.pending) do
            if now - at >= LOAD_TIMEOUT then Retire(id); any = true end
        end
        if any then Pump(); ScheduleRepaint() end
        if S.outstanding > 0 then ArmTimeout() end
    end)
end

local function PendingCount() return S.outstanding + #S.queue end

------------------------------------------------------------
-- Matching
------------------------------------------------------------

-- The rows for a query: items whose name holds it, most held first, then by
-- name, then by id (a stable order for equal names).
function S.Match(snap, query)
    local out = {}
    query = (query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if Chars(query) < MIN_CHARS then return out end
    local q = Fold(query)
    for id, e in pairs(snap or {}) do
        local f = S.folded[id]
        if f and f:find(q, 1, true) then out[#out + 1] = e end
    end
    table.sort(out, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        local na, nb = S.names[a.id] or "", S.names[b.id] or ""
        if na ~= nb then return na < nb end
        return a.id < b.id
    end)
    return out
end

------------------------------------------------------------
-- What a row says
------------------------------------------------------------

local function ClassName(h)
    local col = AltStable.ClassColor and AltStable.ClassColor(h.class) or ""
    return (col ~= "" and (col .. (h.name or "?") .. "|r")) or (h.name or "?")
end

-- "Evelyne 264, Brom 166, +4 more"
function S.HoldersLine(e, max)
    max = max or 3
    local parts = {}
    for i, h in ipairs(e.holders) do
        if i > max then
            parts[#parts + 1] = "+" .. (#e.holders - max) .. " more"
            break
        end
        parts[#parts + 1] = ClassName(h) .. " " .. h.total
    end
    return table.concat(parts, ", ")
end

-- "12 in bags, 3 in the bank, 1 in the mail, 1 worn"
function S.PlacesText(h)
    local parts = {}
    if h.bags > 0 then parts[#parts + 1] = h.bags .. " in bags" end
    if h.bank > 0 then parts[#parts + 1] = h.bank .. " in the bank" end
    if h.mail > 0 then parts[#parts + 1] = h.mail .. " in the mail" end
    if h.worn > 0 then parts[#parts + 1] = (h.worn > 1 and (h.worn .. " worn") or "worn") end
    return table.concat(parts, ", ")
end

-- The first holder with the item somewhere Warband shows: bags, bank, mail.
function S.RevealTarget(e)
    for _, h in ipairs(e.holders) do
        if h.bags + h.bank + h.mail > 0 then return h end
    end
    return nil
end

------------------------------------------------------------
-- The window's state
------------------------------------------------------------

S.snap, S.rows, S.offset, S.selected = nil, {}, 0, nil

local function SetStatus(text)
    if frame then frame.status:SetText(text or "") end
end

local function DefaultStatus()
    local n = PendingCount()
    if n > 0 then return ("Looking up %d item %s"):format(n, n == 1 and "name" or "names") end
    if Chars(S.query or "") < MIN_CHARS then return "Type at least two letters of an item's name." end
    if #S.rows == 0 then return "None recorded." end
    return ("%d %s"):format(#S.rows, #S.rows == 1 and "item" or "items")
end

local Paint

local function Rerun()
    if not frame then return end
    -- The selection follows its item, wherever a re-sort puts it.
    local held = S.selected and S.rows[S.selected]
    local keep = held and held.id
    S.rows = S.Match(S.snap, S.query)
    S.selected = nil
    for i, e in ipairs(S.rows) do
        if e.id == keep then S.selected = i end
    end
    if not S.selected and #S.rows > 0 then S.selected = 1 end
    S.message = nil
    Paint()
end

function S.Rebuild()
    S.snap = S.BuildSnapshot()
    QueueNames(S.snap)
    Rerun()
end

local repaintArmed
function ScheduleRepaint()
    if repaintArmed then return end
    repaintArmed = true
    C_Timer.After(REPAINT_DELAY, function()
        repaintArmed = nil
        if frame and frame:IsShown() then Rerun() end
    end)
end

-- Data changed somewhere: one rebuild for the burst, and only while the
-- window is open - closed, there is nothing to keep current.
local rebuildArmed
function AltStable.NotifyItemDataChanged()
    if not (frame and frame:IsShown()) or rebuildArmed then return end
    rebuildArmed = true
    C_Timer.After(REBUILD_DELAY, function()
        rebuildArmed = nil
        if frame and frame:IsShown() then S.Rebuild() end
    end)
end

local function OnCharactersChanged() AltStable.NotifyItemDataChanged() end

------------------------------------------------------------
-- Actions
------------------------------------------------------------

local function Selected() return S.selected and S.rows[S.selected] end

-- Enter: the Warband tab, on the first holder, the item lit.
function S.Reveal(e)
    e = e or Selected()
    if not e then return false end
    if not AltStable.ItemMapsFor then
        S.message = "Bags, bank and mail need the Warband module."
        Paint(); return false
    end
    local h = S.RevealTarget(e)
    if not h then
        local worn = {}
        for _, x in ipairs(e.holders) do if x.worn > 0 then worn[#worn + 1] = x.name end end
        S.message = (#worn > 0) and ("Worn by " .. table.concat(worn, ", ") .. ".") or "None recorded."
        Paint(); return false
    end
    local ok = AltStable._OpenPluginTab and AltStable._OpenPluginTab("warband", "item", h.guid, e.id)
    if not ok then
        S.message = "The Warband tab isn't available."
        Paint(); return false
    end
    frame:Hide()
    return true
end

-- Shift: the item's link into chat, never sent. Straight into the chat box,
-- not ChatFrameUtil.InsertLink, which may hand it to the auction house's
-- search instead.
function S.Link(e)
    e = e or Selected()
    if not e then return false end
    if AltStable.IsGameUIHidden and AltStable.IsGameUIHidden() then
        -- Chat is under the hidden UI. Bringing it back would end the showcase
        -- look, a bigger surprise than a refused link.
        S.message = "Chat is hidden with the game UI."
        Paint(); return false
    end
    local _, link = AltStable.API.GetItemInfo(e.id)
    if not link then
        C_Item.RequestLoadItemDataByID(e.id)
        S.message = "Item link loading, try again."
        Paint(); return false
    end
    local eb = ChatFrameUtil.GetActiveWindow()
    if not eb then
        eb = ChatFrameUtil.ChooseBoxForSend()
        if eb then ChatFrameUtil.ActivateChat(eb) end
        -- Activation can be refused (a box that may not open).
        if not eb or ChatFrameUtil.GetActiveWindow() ~= eb then
            S.message = "Chat isn't available."
            Paint(); return false
        end
    end
    eb:Insert(link)
    eb:SetFocus()          -- Blizzard's own order for an open draft
    return true
end

local function Move(delta)
    if #S.rows == 0 then return end
    S.selected = math.max(1, math.min(#S.rows, (S.selected or 1) + delta))
    if S.selected <= S.offset then S.offset = S.selected - 1 end
    if S.selected > S.offset + ROWS then S.offset = S.selected - ROWS end
    Paint()
end

------------------------------------------------------------
-- The window
------------------------------------------------------------

local function RowTooltip(row)
    local e = row.entry
    if not e then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(S.names[e.id] or ("item " .. e.id), 1, 1, 1)
    for _, h in ipairs(e.holders) do
        GameTooltip:AddDoubleLine(ClassName(h), S.PlacesText(h), 1, 1, 1, 0.8, 0.8, 0.8)
    end
    GameTooltip:Show()
end

local function MakeRow(i)
    local row = CreateFrame("Button", nil, frame)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -78 - (i - 1) * ROW_H)
    row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -78 - (i - 1) * ROW_H)
    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(1, 1, 1, 0.08)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(28, 28)
    row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
    row.name:SetPoint("RIGHT", row, "RIGHT", -60, 0)
    row.name:SetJustifyH("LEFT")
    row.total = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.total:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -3)
    row.who = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.who:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
    row.who:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.who:SetJustifyH("LEFT")
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function(self)
        if not self.entry then return end
        S.selected = self.index
        if IsShiftKeyDown() then S.Link(self.entry) else S.Reveal(self.entry) end
    end)
    row:SetScript("OnEnter", RowTooltip)
    row:SetScript("OnLeave", function(self) if GameTooltip:IsOwned(self) then GameTooltip:Hide() end end)
    return row
end

function Paint()
    if not frame then return end
    local maxOffset = math.max(0, #S.rows - ROWS)
    S.offset = math.max(0, math.min(S.offset or 0, maxOffset))
    for i = 1, ROWS do
        local row = frame.rows[i]
        local idx = S.offset + i
        local e = S.rows[idx]
        row.entry, row.index = e, idx
        if e then
            local nm = S.names[e.id]
            row.icon:SetTexture((C_Item.GetItemIconByID and C_Item.GetItemIconByID(e.id))
                or "Interface\\Icons\\INV_Misc_QuestionMark")
            local q = C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(e.id)
            local qc = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
            row.name:SetText(nm or ("item " .. e.id))
            if qc then row.name:SetTextColor(qc.r, qc.g, qc.b) else row.name:SetTextColor(1, 1, 1) end
            row.total:SetText(tostring(e.total))
            row.who:SetText(S.HoldersLine(e))
            row.sel:SetShown(idx == S.selected)
            row:Show()
        else
            row:Hide()
        end
    end
    SetStatus(S.message or DefaultStatus())
    frame.warn:SetShown(AltStable.ItemMapsFor == nil)
end

local function BuildWindow()
    if frame then return end
    frame = CreateFrame("Frame", "AltStableSearch", UIParent, "BackdropTemplate")
    frame:SetSize(WIN_W, 78 + ROWS * ROW_H + 34)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    if not (AltStable.SkinWindow and AltStable.SkinWindow(frame, "small")) then
        AltStable.ApplyBackdrop(frame, 0.05, 0.05, 0.08, 0.97)
    end
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    tinsert(UISpecialFrames, "AltStableSearch")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Find an item")
    if AltStable.SkinText then AltStable.SkinText(title) end

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local warn = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    warn:SetPoint("TOPRIGHT", close, "TOPLEFT", -4, -8)
    warn:SetText("Bags, bank and mail need the Warband module.")
    warn:SetTextColor(1, 0.6, 0.3)
    frame.warn = warn

    local box = CreateFrame("EditBox", nil, frame, "SearchBoxTemplate")
    box:SetSize(WIN_W - 36, 20)
    box:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -44)
    box:SetAutoFocus(false)
    -- Hooked: the template's own text handler shows and hides its hint.
    local typeArmed
    box:HookScript("OnTextChanged", function(self, userInput)
        S.query = self:GetText() or ""
        if typeArmed then return end
        typeArmed = true
        C_Timer.After(TYPE_DELAY, function()
            typeArmed = nil
            if frame:IsShown() then S.offset = 0; Rerun() end
        end)
    end)
    -- Set, not hooked: the template's Enter and Escape only clear focus.
    box:SetScript("OnEnterPressed", function()
        if IsShiftKeyDown() then S.Link() else S.Reveal() end
    end)
    box:SetScript("OnEscapePressed", function() frame:Hide() end)
    box:SetScript("OnArrowPressed", function(_, key)
        if key == "UP" then Move(-1) elseif key == "DOWN" then Move(1) end
    end)
    frame.box = box

    frame.rows = {}
    for i = 1, ROWS do frame.rows[i] = MakeRow(i) end
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        S.offset = (S.offset or 0) - delta
        Paint()
    end)

    local status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 12)
    status:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    status:SetJustifyH("LEFT")
    status:SetTextColor(0.75, 0.75, 0.75)
    frame.status = status

    frame.events = CreateFrame("Frame")
    frame.events:SetScript("OnEvent", function(_, event, id)
        if event == "ITEM_DATA_LOAD_RESULT" then S.OnItemDataLoaded(id) end
    end)

    -- Closing lets everything go: the names, the queue, the snapshot. A load
    -- already asked for is the client's; its answer is ignored.
    frame:SetScript("OnHide", function(self)
        self.events:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
        if AltStable.UnregisterCallback then AltStable.UnregisterCallback("CharactersChanged", OnCharactersChanged) end
        S.names, S.folded, S.queue, S.pending, S.outstanding = {}, {}, {}, {}, 0
        S.snap, S.rows, S.selected, S.message = nil, {}, nil, nil
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
        -- Back under UIParent, as Export does (#434).
        if AltStable.LiftAboveHiddenUI then AltStable.LiftAboveHiddenUI(self, false) end
    end)
    frame:Hide()
end

-- Open the window, with a query when given one (/alts search <words>).
function AltStable.ShowSearch(query)
    BuildWindow()
    -- With the game UI hidden (the showcase), a child of UIParent is invisible
    -- whatever its strata: lifted out first, as Export does (#434).
    if AltStable.LiftAboveHiddenUI and AltStable.IsGameUIHidden then
        AltStable.LiftAboveHiddenUI(frame, AltStable.IsGameUIHidden())
    end
    local wasShown = frame:IsShown()
    frame:Show()
    -- Above the sheet: both are DIALOG and toplevel, the last raised wins.
    if frame.Raise then frame:Raise() end
    if not wasShown then
        frame.events:RegisterEvent("ITEM_DATA_LOAD_RESULT")
        if AltStable.RegisterCallback then AltStable.RegisterCallback("CharactersChanged", OnCharactersChanged) end
        S.Rebuild()
    end
    if query then
        frame.box:SetText(query)
        S.query = query
        S.offset = 0
        Rerun()
    end
    frame.box:SetFocus()
end

-- Tests.
S._test = {
    Window = function() return frame end,
    Rerun = function() Rerun() end,
    MAX_PENDING = MAX_PENDING, LOAD_TIMEOUT = LOAD_TIMEOUT,
}
