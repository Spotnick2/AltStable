------------------------------------------------------------
-- AutoCapture.lua - a new portrait when the look changes, opt-in (#124)
--
-- The development probe did this with a dialog, and it was too easily set off:
-- a dialog in the middle of the screen asks for an answer NOW, and a corpse run
-- once produced three of them in a few minutes. This is a TOAST instead, the
-- way Blizzard now announces a layer swap: above the chat window, saying a new
-- portrait will be taken in 10 minutes, click it to take it now, close it to
-- skip this look. Nothing has to be answered, and nothing happens at once.
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

local DELAY  = 600     -- the countdown, as Blizzard's layer-swap toast
local SETTLE = 8       -- after coming back to life, as Capture.lua's loading-screen wait
local CLEAR_NEEDED = 2 -- clear seconds in a row before the shot

local toast, ticker
local offered          -- the look this offer is for (or the status reason)
local dueAt            -- GetTime() when the countdown ends
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
local function Place(f)
    f:ClearAllPoints()
    if ChatAlertFrame then
        f:SetPoint("BOTTOMLEFT", ChatAlertFrame, "BOTTOMLEFT", 0, 0)
    elseif DEFAULT_CHAT_FRAME then
        f:SetPoint("BOTTOMLEFT", DEFAULT_CHAT_FRAME, "TOPLEFT", 0, 34)
    else
        f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 20, 220)
    end
end

local Stop, Skip, Now

local function Build()
    if toast then return toast end
    -- UNDER UIParent, so it follows the interface down: hidden for the capture
    -- itself (it must not be in the picture), for Alt+Z, for the showcase.
    local f = CreateFrame("Button", "AltStablePortraitToast", UIParent, "BackdropTemplate")
    f:SetSize(300, 52)
    f:SetFrameStrata("DIALOG")
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

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(32, 32)
    f.icon:SetPoint("LEFT", 10, 0)
    f.icon:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_02")
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    f.title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 8, -1)
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
    f:Hide()
    toast = f
    return f
end

local function Paint()
    if not toast or not dueAt then return end
    local left = math.max(0, math.ceil(dueAt - GetTime()))
    if left > 0 then
        toast.title:SetText(("New portrait in %d:%02d"):format(math.floor(left / 60), left % 60))
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
    offered, dueAt, clearFor = nil, nil, 0
    if toast then toast:Hide() end
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
    offered, dueAt, clearFor = key, GetTime() + DELAY, 0
    Place(Build())
    Paint()
    toast:Show()
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
    DELAY = DELAY, SETTLE = SETTLE, CLEAR_NEEDED = CLEAR_NEEDED,
}
