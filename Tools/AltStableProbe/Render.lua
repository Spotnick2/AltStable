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

local function Out(s)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[render]|r " .. tostring(s))
end

local frame, model, backdrop
local savedFormat

local function Build()
    if frame then return end

    frame = CreateFrame("Frame", "AltStableRenderStage", UIParent)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetAllPoints(UIParent)
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
    if savedFormat and type(SetCVar) == "function" then
        pcall(SetCVar, "screenshotFormat", savedFormat)
    end
    Out("done - two shots in Screenshots\\, newest first (black, then white).")
    Out("now run:  python Tools/RenderCutout/make-cutout.py")
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
    frame:Show()
    Out("staging... hold still, two screenshots are coming")

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

SLASH_ASRENDER1 = "/asrender"
SlashCmdList["ASRENDER"] = function()
    Capture()
end
