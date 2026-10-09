------------------------------------------------------------
-- AutoCapture.lua - a new portrait when the look changes, opt-in (#124)
--
-- The development probe did this with a dialog, and it was too easily set off:
-- a dialog in the middle of the screen asks for an answer NOW, and a corpse run
-- once produced three of them in a few minutes. This is a TOAST instead, the
-- way Blizzard now announces a world refresh: above the chat window, saying a
-- new portrait will be taken in 5 minutes, click it to take it now, close it to
-- skip this look. Nothing has to be answered, and nothing happens at once. Like
-- Blizzard's, it says it in full and then shrinks to one line (hovering brings
-- the full text back), and the icon to its left toggles the box away and back
-- while the countdown carries on.
--
-- Off by default (AltStableConfig.portraitAuto). A portrait is an aesthetic
-- choice, and the gear worn when a change is noticed is often not what the
-- player wants to be seen in.
--
-- What "due" means is Capture.lua's (#128): the look - the visible slots, the
-- helm and cloak toggles - against the newest capture, or no portrait at all.
-- It compares against the last CAPTURE, not the last login, and reads an
-- inventory that has not loaded yet as unknown rather than as "wearing
-- nothing". This file only decides when to ask and when to shoot.
--
-- When the countdown ends, the capture waits for a clear moment: nothing
-- PortraitBlockedReason refuses (combat, dead, a dungeon, moving), no capture
-- already running, the interface showing (Alt+Z and the showcase hide it, and
-- the player did that on purpose), and nobody typing. Two clear seconds in a
-- row, so stopping for an instant mid-run is not a moment. One attempt per
-- offer: a capture that refuses (no TGA, say) prints why and ends the offer
-- rather than retrying every second.
------------------------------------------------------------

AltStable = AltStable or {}

local DELAY  = 300     -- the countdown, as Blizzard's world-refresh toast
local COMPACT_AFTER = 10  -- seconds in full before it shrinks to one line
local SETTLE = 8       -- after coming back to life, as Capture.lua's loading-screen wait
local CLEAR_NEEDED = 2 -- clear seconds in a row before the shot

local toast, ticker
local offered          -- the look this offer is for
local offeredReason    -- "changed" or "missing": what the toast says
local dueAt            -- GetTime() when the countdown ends
local shownAt          -- GetTime() the offer was made: when to shrink
local hovered          -- the full text stays while the cursor is on it
local boxHidden        -- the icon was clicked: the box is put away, the offer stands
local clearFor = 0     -- clear seconds in a row, once it has

local function Out(s)
    if AltStable.Print then AltStable.Print(s)
    else DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable]|r " .. tostring(s)) end
end

local function On()
    return AltStableConfig and AltStableConfig.portraitAuto == true
end

local function Guid()
    return UnitGUID and UnitGUID("player") or nil
end

-- What an offer is for, and what a skip remembers: the look, so the next
-- change offers again. Always a look: Evaluate waits for one, because a key
-- that was the reason until inventory loaded and the look after it restarted
-- the countdown, and a skip stored then never matched again (review of #215).
local function OfferKey(status)
    return status.look
end

local function Skipped(status)
    local skip = AltStableConfig and AltStableConfig.portraitAutoSkip
    local guid = Guid()
    return type(skip) == "table" and guid ~= nil and skip[guid] == OfferKey(status)
end

local function Dead()
    if type(UnitIsDeadOrGhost) ~= "function" then return false end
    local ok, dead = pcall(UnitIsDeadOrGhost, "player")
    return ok and dead and true or false
end

-- Why not this second, or nil.
local function NotNow()
    local why = AltStable.PortraitBlockedReason and AltStable.PortraitBlockedReason()
    if why then return why end
    if AltStable.PortraitCapturing and AltStable.PortraitCapturing() then return "a capture is running" end
    if UIParent and UIParent.IsShown and not UIParent:IsShown() then return "the interface is hidden" end
    if type(GetCurrentKeyBoardFocus) == "function" and GetCurrentKeyBoardFocus() then
        return "you are typing"
    end
    return nil
end

------------------------------------------------------------
-- The toast
------------------------------------------------------------

-- Where Blizzard's own toasts appear: ChatAlertFrame is the container the
-- Battle.net and Delves toasts stack in, just above the chat buttons. Anchored
-- to it, not registered with it: an addon frame inside Blizzard's alert tables
-- is taint in code we do not own (#199 was a shared dialog doing exactly that).
--
-- The friends button (QuickJoinToastButton) is the FIRST thing in that stack,
-- and Blizzard's world-refresh toast sits above it - measured in game: at the
-- container's base the toast covered the button. So above it while it shows.
-- Re-placed on every paint: the button comes and goes on its own.
--
-- Unless the player moved it (Alt+drag): then where they put it, kept in
-- AltStableConfig.portraitToastPos as the icon's bottom left against UIParent's.
--
-- Only when the anchor CHANGES: re-anchoring every tick was work for nothing,
-- and it fought an Alt+drag in progress (review of #215).
local placedAt
local function Place(f)
    local pos = AltStableConfig and AltStableConfig.portraitToastPos
    local rel, relPoint, x, y
    if type(pos) == "table" and tonumber(pos.x) and tonumber(pos.y) then
        rel, relPoint, x, y = UIParent, "BOTTOMLEFT", tonumber(pos.x), tonumber(pos.y)
    elseif QuickJoinToastButton and QuickJoinToastButton.IsShown and QuickJoinToastButton:IsShown() then
        rel, relPoint, x, y = QuickJoinToastButton, "TOPLEFT", 0, 4
    elseif ChatAlertFrame then
        rel, relPoint, x, y = ChatAlertFrame, "BOTTOMLEFT", 0, 0
    elseif DEFAULT_CHAT_FRAME then
        rel, relPoint, x, y = DEFAULT_CHAT_FRAME, "TOPLEFT", 0, 34
    else
        rel, relPoint, x, y = UIParent, "BOTTOMLEFT", 20, 220
    end
    local key = tostring(rel) .. relPoint .. x .. "," .. y
    if placedAt == key then return end
    placedAt = key
    f:ClearAllPoints()
    f:SetPoint("BOTTOMLEFT", rel, relPoint, x, y)
end

local Stop, Skip, Now, Paint

local FULL_W, FULL_H, COMPACT_W, COMPACT_H = 300, 52, 210, 30
local TOGGLE_SIZE = 24                  -- GlassChat's button size (Buttons.SIZE)
local GOLD = { 1, 0.82, 0 }             -- GlassChat's symbol gold (Skin.TAB_GOLD)

-- A camera in gold fills on a 16x12 holder: the body, the viewfinder bump on
-- top, and the lens as a dark square with a gold glint.
local function CameraSymbol(parent)
    local h = CreateFrame("Frame", nil, parent)
    h:SetSize(16, 12)
    local function fill(w, hh, point, rel, relPoint, x, y, c)
        local tex = h:CreateTexture(nil, "OVERLAY")
        tex:SetSize(w, hh)
        tex:SetPoint(point, rel, relPoint, x, y)
        tex:SetColorTexture(c[1], c[2], c[3], 1)
        return tex
    end
    local body = fill(16, 9, "BOTTOM", h, "BOTTOM", 0, 0, GOLD)
    fill(6, 3, "BOTTOMLEFT", body, "TOPLEFT", 3, 0, GOLD)
    local lens = fill(6, 6, "CENTER", body, "CENTER", 0, 0, { 0.08, 0.08, 0.1 })
    lens:SetDrawLayer("OVERLAY", 1)
    local glint = fill(2, 2, "CENTER", lens, "CENTER", 0, 0, GOLD)
    glint:SetDrawLayer("OVERLAY", 2)
    h:SetPoint("CENTER", parent, "CENTER", 0, 0)
    return h
end

local function AltDown()
    return type(IsAltKeyDown) == "function" and IsAltKeyDown() and true or false
end

-- Alt+drag, from the icon or the box: the icon moves and the box follows it.
-- Alt, so a plain click keeps meaning what it says (toggle, take it now).
local dragging
-- The release that ends a drag is not a click - whatever Alt is doing by then:
-- letting go of Alt before the button made it "take it now" (review of #215).
-- Cleared by the next press, which comes before that press's own click.
local justDragged
local function DragStart()
    if not AltDown() or not toast then return end
    dragging = true
    toast.toggle:StartMoving()
end
local function DragStop()
    if not dragging then return end
    dragging = nil
    justDragged = true
    local t = toast.toggle
    t:StopMovingOrSizing()
    -- Ours to keep, not the client's layout cache: a named frame moved by
    -- StartMoving is marked user-placed, and the client would then restore it
    -- from layout-local.txt on its own, fighting Place.
    if t.SetUserPlaced then t:SetUserPlaced(false) end
    local x, y = t:GetLeft(), t:GetBottom()
    if x and y then
        AltStable.SetConfigValue("portraitToastPos", { x = math.floor(x + 0.5), y = math.floor(y + 0.5) })
    end
    placedAt = nil      -- StartMoving re-anchored it: put it where it was saved
    Paint()
end

local function PlaceSymbol(t, pressed)
    t.symbol:ClearAllPoints()
    t.symbol:SetPoint("CENTER", t, "CENTER", pressed and 1 or 0, pressed and -1 or 0)
end

local function Build()
    if toast then return toast end
    -- UNDER UIParent, so it follows the interface down: hidden for the capture
    -- itself (it must not be in the picture), for Alt+Z, for the showcase.
    -- The icon, on its own, left of the box: Blizzard's toggle. It stays up for
    -- the whole offer, so a box put away is not an offer forgotten.
    --
    -- Styled like GlassChat's buttons beside the chat, which it sits among: a
    -- small glass pill with a flat gold symbol, not a full-colour item icon
    -- (owner's call: the spyglass looked out of place there). The symbol is a
    -- camera drawn from fills, as GlassChat draws its chat bubble - no
    -- frameless camera art is known on this client.
    local t = CreateFrame("Button", "AltStablePortraitToastToggle", UIParent)
    t:SetSize(TOGGLE_SIZE, TOGGLE_SIZE)
    t:SetFrameStrata("DIALOG")
    -- Level 2, not 0: the pill goes one level UNDER the button, and at 0 it
    -- would be level with it, where the rims are not sure to draw under the
    -- symbol (LibGlass docs, Pill).
    t:SetFrameLevel(2)
    -- The highlight first: Pill softens it (0.4, GlassChat's) rather than
    -- removing it, so hovering still shows.
    if t.SetHighlightTexture then
        t:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    end
    -- The pill itself is LibGlass r5's Glass.Pill (LibGlass#31), through the
    -- skin so it is the chosen glass: one level under the button, no grain or
    -- shadow, the rims under the symbol. A plain dark square without glass.
    t.pill = AltStable.SkinPill and AltStable.SkinPill(t)
    if not t.pill then
        t.pill = CreateFrame("Frame", nil, t)
        t.pill:SetAllPoints()
        local bg = t.pill:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.08, 0.08, 0.1, 0.85)
    end
    t.symbol = CameraSymbol(t)
    -- Pressed, the symbol moves a pixel, as GlassChat's bubble does.
    t:SetScript("OnMouseDown", function(self) justDragged = nil; PlaceSymbol(self, true) end)
    t:SetScript("OnMouseUp", function(self) PlaceSymbol(self, false) end)
    t:SetMovable(true)
    t:SetClampedToScreen(true)
    t:RegisterForDrag("LeftButton")
    t:SetScript("OnDragStart", DragStart)
    t:SetScript("OnDragStop", DragStop)
    t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    t:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            -- Alt+right-click: back above the chat.
            if AltDown() then
                AltStable.SetConfigValue("portraitToastPos", nil)
                Paint()
            end
            return
        end
        if justDragged or AltDown() then justDragged = nil; return end   -- the end of an Alt+drag
        boxHidden = not boxHidden
        Paint()
    end)
    t:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("New portrait", 1, 1, 1)
        GameTooltip:AddLine("Click to show or hide the countdown.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Alt+drag to move it; Alt+right-click to put it back.", 0.6, 0.6, 0.6, true)
        if AltStable.COMPANION_NEEDED_PLAIN then
            GameTooltip:AddLine(AltStable.COMPANION_NEEDED_PLAIN, 1, 0.82, 0, true)
        end
        GameTooltip:Show()
    end)
    t:SetScript("OnLeave", function() GameTooltip:Hide() end)
    t:Hide()

    local f = CreateFrame("Button", "AltStablePortraitToast", UIParent, "BackdropTemplate")
    f:SetSize(FULL_W, FULL_H)
    f:SetFrameStrata("DIALOG")
    f:SetPoint("LEFT", t, "RIGHT", 6, 0)
    f.toggle = t
    if not (AltStable.SkinWindow and AltStable.SkinWindow(f, "small")) then
        f:SetBackdrop({
            bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        f:SetBackdropColor(0.08, 0.08, 0.12, 0.95)
        f:SetBackdropBorderColor(0.4, 0.4, 0.5, 0.9)
    end

    f.title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 10, -9)
    f.title:SetPoint("RIGHT", f, "RIGHT", -28, 0)
    f.title:SetJustifyH("LEFT")
    if AltStable.SkinText then AltStable.SkinText(f.title) end

    f.sub = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.sub:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)
    f.sub:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    f.sub:SetJustifyH("LEFT")
    if AltStable.SkinText then AltStable.SkinText(f.sub) end

    -- Closing is "skip this look", said where the X is.
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", 2, 2)
    close:SetFrameLevel((f:GetFrameLevel() or 0) + 12)
    close:SetScript("OnClick", function() Skip() end)
    close:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Skip this look", 1, 1, 1)
        GameTooltip:AddLine("Asked again when your look changes.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    -- Leaving the X straight off the toast fires only THIS OnLeave - the toast's
    -- fired on the way onto the X and kept the full text - so it is let go here
    -- too, or the toast stayed in full for the rest of the offer (review of #215).
    close:SetScript("OnLeave", function()
        GameTooltip:Hide()
        if not (toast.IsMouseOver and toast:IsMouseOver()) then
            hovered = false
            Paint()
        end
    end)
    f.close = close

    f:RegisterForClicks("LeftButtonUp")
    f:SetScript("OnClick", function()
        if justDragged or AltDown() then justDragged = nil; return end   -- the end of an Alt+drag
        Now()
    end)
    f:SetScript("OnMouseDown", function() justDragged = nil end)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", DragStart)
    f:SetScript("OnDragStop", DragStop)
    -- The full text on hover. OnLeave fires when the cursor moves onto the X,
    -- a child, so it asks whether the cursor is still over the toast at all -
    -- or reaching for the X would shrink the toast out from under it.
    f:SetScript("OnEnter", function() hovered = true; Paint() end)
    f:SetScript("OnLeave", function(self)
        if self.IsMouseOver and self:IsMouseOver() then return end
        hovered = false
        Paint()
    end)
    f:Hide()
    toast = f
    return f
end

-- How long is left, as Blizzard's world-refresh toast says it (measured in
-- game): whole minutes - "4 minutes" through a fifth of the way down - then
-- seconds for the last one. Not a ticking m:ss clock.
local function Remaining(left)
    if left >= 60 then
        local m = math.floor(left / 60)
        return m .. (m == 1 and " minute" or " minutes")
    end
    return left .. (left == 1 and " second" or " seconds")
end

-- Full, then one line: the title alone, in a narrower box. Only when that
-- changes, not every tick.
local function Layout(compact)
    if toast.compact == compact then return end
    toast:SetSize(compact and COMPACT_W or FULL_W, compact and COMPACT_H or FULL_H)
    toast.title:ClearAllPoints()
    if compact then
        toast.title:SetPoint("LEFT", toast, "LEFT", 10, 0)
    else
        toast.title:SetPoint("TOPLEFT", toast, "TOPLEFT", 10, -9)
    end
    toast.title:SetPoint("RIGHT", toast, "RIGHT", -24, 0)
    toast.sub:SetShown(not compact)
    toast.compact = compact
end

-- `why` is the caller's NotNow() when it has one, so a tick asks once.
function Paint(why)
    if not toast or not dueAt then return end
    local left = math.max(0, math.ceil(dueAt - GetTime()))
    -- In full again once the countdown ends, as Blizzard's does ("Refreshing
    -- your world at any time..."): the shot can now come at any moment, which
    -- is worth the full sentence.
    local compact = left > 0 and not hovered and shownAt ~= nil
        and (GetTime() - shownAt) >= COMPACT_AFTER
    Layout(compact)
    if not dragging then Place(toast.toggle) end
    toast.toggle:Show()
    toast:SetShown(not boxHidden)
    if left > 0 then
        toast.title:SetText((compact and "Portrait in " or "New portrait in ") .. Remaining(left))
    else
        if why == nil then why = NotNow() end
        toast.title:SetText("New portrait at the next quiet moment")
        toast.sub:SetText(why and ("Waiting: " .. why) or "Hold still...")
        return
    end
    toast.sub:SetText(offeredReason == "missing" and "No portrait yet - click to take it now"
        or "Your look changed - click to take it now")
end

------------------------------------------------------------
-- The offer
------------------------------------------------------------

function Stop()
    if ticker then ticker:Cancel(); ticker = nil end
    offered, offeredReason, dueAt, clearFor, shownAt, hovered, boxHidden = nil, nil, nil, 0, nil, false, false
    if toast then toast:Hide(); toast.toggle:Hide() end
end

function Skip()
    local guid = Guid()
    if guid and offered then
        AltStableConfig.portraitAutoSkip = AltStableConfig.portraitAutoSkip or {}
        AltStableConfig.portraitAutoSkip[guid] = offered
        if AltStable.OnConfigChanged then AltStable.OnConfigChanged("portraitAutoSkip") end
    end
    Stop()
end

-- The shot, by click or by countdown. Either way the offer ends: on success the
-- status turns "pending", and on a refusal the reason has been printed once.
local function Shoot(auto)
    local why = NotNow()
    if why then
        if not auto then Out("|cffff8800portrait: " .. why .. "|r") end
        return false
    end
    Stop()
    if AltStable.CapturePortrait then AltStable.CapturePortrait({ auto = auto }) end
    return true
end

function Now()
    Shoot(false)
end

local function Tick()
    if not dueAt then return end
    local why = false        -- not asked: the countdown is still running
    if GetTime() >= dueAt then
        why = NotNow()
        if why then
            clearFor = 0
        else
            clearFor = clearFor + 1
            if clearFor >= CLEAR_NEEDED then
                Shoot(true)
                return
            end
        end
    end
    Paint(why or nil)
end

-- Called whenever the status changes, the option is switched, or the player
-- comes back to life. Starts an offer for a due look, restarts it when the
-- look is a different one, and ends it when nothing is due any more.
local function Evaluate(status)
    status = status or (AltStable.CurrentPortraitStatus and AltStable.CurrentPortraitStatus())
    -- Due, but the look cannot be read yet (inventory not loaded after a
    -- login): wait for it rather than offer under a key that changes later.
    if On() and type(status) == "table" and status.due and not status.look then return end
    if not On() or type(status) ~= "table" or not status.due or Skipped(status) then
        Stop()
        return
    end
    -- Not while dead: the corpse run that set off three dialogs in the probe.
    -- Whatever is up stays up; coming back to life asks again.
    if Dead() then return end
    local key = OfferKey(status)
    if offered == key and dueAt then return end
    offered, offeredReason, dueAt, clearFor, shownAt = key, status.reason, GetTime() + DELAY, 0, GetTime()
    boxHidden = false     -- a new offer is said in full, whatever the last one was
    Build()
    Paint()
    if not ticker then ticker = C_Timer.NewTicker(1, Tick) end
end
AltStable.EvaluateAutoCapture = function() Evaluate() end

-- Every change of the answer comes through here (Capture.lua's
-- RefreshPortraitStatus); PublicAPI wraps it too, so call along the chain.
do
    local prior = AltStable.PortraitStatusUpdated
    AltStable.PortraitStatusUpdated = function(status, ...)
        if prior then prior(status, ...) end
        Evaluate(status)
    end
end

-- A different look under the same public answer (chest B, then chest C: both
-- "Chest changed"). Capture.lua says so here rather than widening the public
-- PortraitStatusChanged signal (review of #215).
AltStable.PortraitLookChanged = function(status) Evaluate(status) end

-- A capture that started and was then abandoned (combat, death, the watchdog):
-- the offer ended when the shot began, and the status did not change, so
-- nothing else would offer it again (review of #215). A capture REFUSED
-- before it starts stays one attempt, as above.
AltStable.OnPortraitCaptureAbandoned = function() Evaluate() end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_UNGHOST")
events:RegisterEvent("PLAYER_ALIVE")
local settle
events:SetScript("OnEvent", function()
    if settle then settle:Cancel() end
    settle = C_Timer.NewTimer(SETTLE, function()
        settle = nil
        Evaluate()
    end)
end)

-- Test seam (the AltStable._test convention).
AltStable._test = AltStable._test or {}
AltStable._test.autoCapture = {
    Evaluate = Evaluate, Tick = Tick, Stop = Stop, Skip = Skip, Now = Now, NotNow = NotNow,
    toast = function() return toast end,
    offered = function() return offered end,
    dueAt = function() return dueAt end,
    -- For an in-game check without the ten-minute wait:
    --   /run AltStable._test.autoCapture.Expire()
    Expire = function() if dueAt then dueAt = GetTime() end end,
    ticker = function() return ticker end,
    events = events,
    dragging = function() return dragging end,
    offeredReason = function() return offeredReason end,
    DELAY = DELAY, SETTLE = SETTLE, CLEAR_NEEDED = CLEAR_NEEDED, COMPACT_AFTER = COMPACT_AFTER,
}
