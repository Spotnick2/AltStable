------------------------------------------------------------
-- Render.lua — make a cutout of the LIVE character, locally (#15)
--
-- Offline characters cannot be textured on this client (see Models.lua). The
-- live one renders perfectly, so the image source is our own client rather
-- than an armory: pose the live model on a flat backdrop, screenshot it, and
-- matte it to a transparent cutout on disk. Same look the old .NET pipeline
-- got from the Battle.net armory, with nothing to wait for.
--
-- TWO SHOTS, not a chroma key. The same frozen pose is captured once on BLACK
-- and once on WHITE; then for each pixel
--
--     alpha  = 1 - (white - black)
--     colour = black / alpha
--
-- which is exact, including hair, capes and anything semi-transparent, and has
-- none of the magenta fringing a key leaves behind. It costs one extra
-- screenshot and requires the pose to be IDENTICAL in both, which is why the
-- animation is paused and frozen before either shot.
--
-- Screenshots must be TGA: the default JPEG smears every edge and the matte
-- maths would be reading compression noise.
------------------------------------------------------------

local KEY_DELAY   = 1.25   -- let the model stream in before the first shot
local SHOT_DELAY  = 0.65   -- let the client finish writing a file

-- Auto-capture timings. The login one is long because inventory is not
-- reliably readable the instant the world loads, and a fingerprint taken from
-- half-loaded gear would trigger a pointless capture every single login.
local LOGIN_SETTLE = 8
local WARN_SECONDS = 5

local function Out(s)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[render]|r " .. tostring(s))
end

local frame, model, backdrop
local savedFormat
local uiWasShown

local function Build()
    if frame then return end

    -- Parented to WorldFrame, NOT UIParent, so hiding UIParent during the shots
    -- takes every other frame away and leaves the stage standing. A fullscreen
    -- frame is not enough on its own: a tooltip draws at TOOLTIP strata, above
    -- FULLSCREEN_DIALOG, and gets matted straight into the cutout - measured,
    -- after AltStable's own minimap tooltip turned a 250x885 character into a
    -- 1790x1350 image with a tooltip floating beside her.
    frame = CreateFrame("Frame", "AltStableRenderStage", WorldFrame)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetFrameLevel(10000)
    frame:SetAllPoints(WorldFrame)
    frame:Hide()

    backdrop = frame:CreateTexture(nil, "BACKGROUND")
    backdrop:SetAllPoints()
    backdrop:SetColorTexture(0, 0, 0, 1)

    model = CreateFrame("DressUpModel", nil, frame)
    -- A tall, narrow stage centred on screen: the converter trims to content,
    -- so the only thing that matters is that the figure fits with margin.
    model:SetPoint("CENTER", 0, -20)
    model:SetSize(420, 760)
end

-- The render settings measured as correct on 1.60.1.70009 (see Models.lua):
-- both transmog knobs OFF, auto-dress ON.
local function PoseLiveCharacter()
    model:ClearModel()
    if model.SetUseTransmogSkin then pcall(model.SetUseTransmogSkin, model, false) end
    if model.SetUseTransmogChoices then pcall(model.SetUseTransmogChoices, model, false) end
    if model.SetAutoDress then pcall(model.SetAutoDress, model, true) end
    pcall(model.SetUnit, model, "player")
    pcall(model.SetPortraitZoom, model, 0)
    pcall(model.SetPosition, model, 0, 0, 0)
    pcall(model.SetFacing, model, 0.35)
    -- Identical pose in both shots or the matte is nonsense.
    if model.SetAnimation then pcall(model.SetAnimation, model, 0) end
    if model.FreezeAnimation then pcall(model.FreezeAnimation, model, 0, 0, 0) end
    if model.SetPaused then pcall(model.SetPaused, model, true) end
end

------------------------------------------------------------
-- "Has the character's look changed since the last portrait?"
--
-- The whole point of auto-capture: a portrait should refresh when the
-- character actually looks different, and never otherwise. Item IDs are the
-- right granularity - they decide the model - so enchants, gems and stat
-- rerolls do not trigger a pointless re-shoot, and neither does levelling.
------------------------------------------------------------

local function LookFingerprint()
    local parts = {}
    for slot = 1, 19 do
        local link = GetInventoryItemLink("player", slot)
        local id = link and link:match("item:(%d+)")
        parts[#parts + 1] = id or "-"
    end
    -- The display id changes with a barber-shop visit or a race change, which
    -- is exactly the kind of "looks different" this is for.
    local displayID
    if C_PlayerInfo and type(C_PlayerInfo.GetDisplayID) == "function" then
        local ok, id = pcall(C_PlayerInfo.GetDisplayID)
        if ok then displayID = id end
    end
    parts[#parts + 1] = tostring(displayID or "?")
    return table.concat(parts, ":")
end

local function StoredFingerprint(guid)
    local looks = AltStableProbeDB and AltStableProbeDB.looks
    local rec = looks and looks[guid]
    return rec and rec.fp
end

local function RememberFingerprint(guid, fp)
    AltStableProbeDB = AltStableProbeDB or {}
    AltStableProbeDB.looks = AltStableProbeDB.looks or {}
    AltStableProbeDB.looks[guid] = { fp = fp, stamp = date("%Y-%m-%d %H:%M:%S") }
end

local function RecordMetadata(shotIndex)
    AltStableProbeDB = AltStableProbeDB or {}
    AltStableProbeDB.renders = AltStableProbeDB.renders or {}

    local first, surname = UnitName("player")
    local name = (surname and surname ~= "") and (first .. " " .. surname) or first
    local raceLoc, raceToken = UnitRace("player")
    local _, classToken = UnitClass("player")
    local w, h = GetPhysicalScreenSize and GetPhysicalScreenSize() or GetScreenWidth(), GetScreenHeight()

    table.insert(AltStableProbeDB.renders, {
        name = name, guid = UnitGUID("player"),
        race = raceToken, raceLoc = raceLoc, class = classToken,
        sex = UnitSex("player"), level = UnitLevel("player"),
        shot = shotIndex,                     -- 1 = on black, 2 = on white
        stamp = date("%Y-%m-%d %H:%M:%S"),
        screenW = w, screenH = h,
        uiScale = UIParent:GetEffectiveScale(),
    })
end

local function Finish()
    frame:Hide()
    if uiWasShown then UIParent:Show(); uiWasShown = nil end
    -- Only now, once both shots are on disk: a fingerprint stored after a
    -- capture that failed half-way would suppress the retry.
    local guid = UnitGUID("player")
    if guid then RememberFingerprint(guid, LookFingerprint()) end
    if savedFormat and type(SetCVar) == "function" then
        pcall(SetCVar, "screenshotFormat", savedFormat)
    end
    Out("done - two shots in Screenshots\\, newest first (black, then white).")
    Out("now run:  python Tools/RenderCutout/make-cutout.py --all")
    -- The addon records that this LOOK was photographed; whether the picture
    -- came out is something only the converter can see. So if one is spoiled,
    -- /asrender forget puts this character back in the automatic queue.
end

local function Capture()
    Build()

    if type(Screenshot) ~= "function" then
        Out("|cffff5555Screenshot() is unavailable on this client.|r")
        return
    end
    -- JPEG would make the matte read compression noise instead of coverage.
    if type(GetCVar) == "function" and type(SetCVar) == "function" then
        savedFormat = GetCVar("screenshotFormat")
        pcall(SetCVar, "screenshotFormat", "tga")
        if GetCVar("screenshotFormat") ~= "tga" then
            Out("|cffff8800could not switch screenshots to TGA|r - the matte will be noisy")
        end
    end

    PoseLiveCharacter()
    backdrop:SetColorTexture(0, 0, 0, 1)
    Out("staging... hold still, two screenshots are coming")

    -- Say it BEFORE the UI goes, or the message lands in a hidden chat frame.
    if GameTooltip and GameTooltip.Hide then pcall(GameTooltip.Hide, GameTooltip) end
    uiWasShown = UIParent:IsShown()
    if uiWasShown then UIParent:Hide() end
    frame:Show()

    C_Timer.After(KEY_DELAY, function()
        Screenshot()
        RecordMetadata(1)
        C_Timer.After(SHOT_DELAY, function()
            backdrop:SetColorTexture(1, 1, 1, 1)     -- same pose, other backdrop
            C_Timer.After(0.25, function()
                Screenshot()
                RecordMetadata(2)
                C_Timer.After(SHOT_DELAY, Finish)
            end)
        end)
    end)
end

------------------------------------------------------------
-- Auto-capture: keep portraits current without anyone typing anything
------------------------------------------------------------

local pending   -- the countdown timer, so it can be cancelled

local function AutoEnabled()
    return not (AltStableProbeDB and AltStableProbeDB.autoCaptureOff)
end

local function CancelPending(reason)
    if not pending then return false end
    pending:Cancel()
    pending = nil
    Out("auto-capture cancelled" .. (reason and (" - " .. reason) or ""))
    return true
end

local function ConsiderCapture(why)
    if not AutoEnabled() then return end
    local guid = UnitGUID("player")
    if not guid then return end

    local fp = LookFingerprint()
    if fp == StoredFingerprint(guid) then return end          -- looks the same

    -- Never interrupt a fight to take a photograph. PLAYER_REGEN_ENABLED
    -- brings us back.
    if InCombatLockdown and InCombatLockdown() then
        Out("gear changed - portrait will refresh after combat")
        return
    end

    Out(("%s - refreshing your portrait in %ds. |cffffff00/asrender cancel|r to skip.")
        :format(why, WARN_SECONDS))
    pending = C_Timer.NewTimer(WARN_SECONDS, function()
        pending = nil
        Capture()
    end)
end

SLASH_ASRENDER1 = "/asrender"
SlashCmdList["ASRENDER"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()

    if msg == "cancel" then
        if not CancelPending() then Out("nothing pending") end
        return
    end
    if msg == "forget" or msg == "forget all" then
        AltStableProbeDB = AltStableProbeDB or {}
        if msg == "forget all" then
            AltStableProbeDB.looks = {}
            Out("forgot every stored look - each character re-captures at next login")
        else
            local guid = UnitGUID("player")
            if guid and AltStableProbeDB.looks then AltStableProbeDB.looks[guid] = nil end
            Out("forgot this character's look - it re-captures at next login")
        end
        return
    end
    if msg == "auto" then
        AltStableProbeDB = AltStableProbeDB or {}
        AltStableProbeDB.autoCaptureOff = AutoEnabled() and true or nil
        Out("auto-capture " .. (AutoEnabled() and "|cff55ff55on|r" or "|cffff5555off|r"))
        return
    end
    if msg == "status" then
        local guid = UnitGUID("player")
        Out("auto-capture " .. (AutoEnabled() and "on" or "off"))
        Out("look now    : " .. LookFingerprint())
        Out("last shot   : " .. tostring(guid and StoredFingerprint(guid) or "never"))
        return
    end
    if msg ~= "" then
        Out("usage: /asrender [cancel|auto|status|forget|forget all]")
        return
    end

    CancelPending()
    Capture()
end

local auto = CreateFrame("Frame")
auto:RegisterEvent("PLAYER_LOGIN")
auto:RegisterEvent("PLAYER_REGEN_ENABLED")
auto:RegisterEvent("PLAYER_REGEN_DISABLED")
auto:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        -- A fight started inside the countdown: hiding the UI for three
        -- seconds mid-pull is the one thing this must never do.
        CancelPending("combat started")
    elseif event == "PLAYER_LOGIN" then
        -- Inventory is not reliably readable the instant the world loads, and
        -- a fingerprint built from half-loaded gear would re-shoot every login.
        C_Timer.After(LOGIN_SETTLE, function() ConsiderCapture("gear changed since your last portrait") end)
    else
        ConsiderCapture("out of combat - gear changed since your last portrait")
    end
end)
