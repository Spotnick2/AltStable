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
local offered          -- the look this offer is for (or the status reason)
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

-- What a skip remembers: the look, so the next change offers again. A missing
-- portrait has no look to compare; its reason stands in.
local function OfferKey(status)
    return status.look or status.reason
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
local function Place(f)
    f:ClearAllPoints()
    if QuickJoinToastButton and QuickJoinToastButton.IsShown and QuickJoinToastButton:IsShown() then
        f:SetPoint("BOTTOMLEFT", QuickJoinToastButton, "TOPLEFT", 0, 4)
    elseif ChatAlertFrame then
        f:SetPoint("BOTTOMLEFT", ChatAlertFrame, "BOTTOMLEFT", 0, 0)
    elseif DEFAULT_CHAT_FRAME then
        f:SetPoint("BOTTOMLEFT", DEFAULT_CHAT_FRAME, "TOPLEFT", 0, 34)
    else
        f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 20, 220)
    end
end

local Stop, Skip, Now, Paint

local FULL_W, FULL_H, COMPACT_W, COMPACT_H = 300, 52, 210, 30

local function Build()
    if toast then return toast end
    -- UNDER UIParent, so it follows the interface down: hidden for the capture
    -- itself (it must not be in the picture), for Alt+Z, for the showcase.
    -- The icon, on its own, left of the box: Blizzard's toggle. It stays up for
    -- the whole offer, so a box put away is not an offer forgotten.
    local t = CreateFrame("Button", "AltStablePortraitToastToggle", UIParent)
    t:SetSize(28, 28)
    t:SetFrameStrata("DIALOG")
    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetAllPoints()
    t.icon:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_02")
    t.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if t.SetHighlightTexture then t:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD") end
    t:RegisterForClicks("LeftButtonUp")
    t:SetScript("OnClick", function()
        boxHidden = not boxHidden
        Paint()
    end)
    t:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("New portrait", 1, 1, 1)
        GameTooltip:AddLine("Click to show or hide the countdown.", 0.8, 0.8, 0.8, true)
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
    close:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.close = close

    f:RegisterForClicks("LeftButtonUp")
    f:SetScript("OnClick", function() Now() end)
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

-- Full, then one line: the title alone, in a narrower box.
local function Layout(compact)
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

function Paint()
    if not toast or not dueAt then return end
    local left = math.max(0, math.ceil(dueAt - GetTime()))
    -- In full again once the countdown ends, as Blizzard's does ("Refreshing
    -- your world at any time..."): the shot can now come at any moment, which
    -- is worth the full sentence.
    local compact = left > 0 and not hovered and shownAt ~= nil
        and (GetTime() - shownAt) >= COMPACT_AFTER
    Layout(compact)
    Place(toast.toggle)
    toast.toggle:Show()
    toast:SetShown(not boxHidden)
    if left > 0 then
        local clock = ("%d:%02d"):format(math.floor(left / 60), left % 60)
        toast.title:SetText((compact and "Portrait in " or "New portrait in ") .. clock)
    else
        local why = NotNow()
        toast.title:SetText("New portrait at the next quiet moment")
        toast.sub:SetText(why and ("Waiting: " .. why) or "Hold still...")
        return
    end
    toast.sub:SetText(offered == "missing" and "No portrait yet - click to take it now"
        or "Your look changed - click to take it now")
end

------------------------------------------------------------
-- The offer
------------------------------------------------------------

function Stop()
    if ticker then ticker:Cancel(); ticker = nil end
    offered, dueAt, clearFor, shownAt, hovered, boxHidden = nil, nil, 0, nil, false, false
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
    if GetTime() >= dueAt then
        if NotNow() then
            clearFor = 0
        else
            clearFor = clearFor + 1
            if clearFor >= CLEAR_NEEDED then
                Shoot(true)
                return
            end
        end
    end
    Paint()
end

-- Called whenever the status changes, the option is switched, or the player
-- comes back to life. Starts an offer for a due look, restarts it when the
-- look is a different one, and ends it when nothing is due any more.
local function Evaluate(status)
    status = status or (AltStable.CurrentPortraitStatus and AltStable.CurrentPortraitStatus())
    if not On() or type(status) ~= "table" or not status.due or Skipped(status) then
        Stop()
        return
    end
    -- Not while dead: the corpse run that set off three dialogs in the probe.
    -- Whatever is up stays up; coming back to life asks again.
    if Dead() then return end
    local key = OfferKey(status)
    if offered == key and dueAt then return end
    offered, dueAt, clearFor, shownAt = key, GetTime() + DELAY, 0, GetTime()
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
    DELAY = DELAY, SETTLE = SETTLE, CLEAR_NEEDED = CLEAR_NEEDED, COMPACT_AFTER = COMPACT_AFTER,
}
