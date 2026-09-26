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

-- How long the player has to be OUT of combat before a capture is considered.
-- Leaving combat is not the same as being done fighting: between pulls there is
-- a gap of a few seconds, and hiding the interface in one of those is worse
-- than not taking the picture at all. Login is the intended moment; this is the
-- fallback for a gear change mid-session, and it is deliberately patient.
local COMBAT_SETTLE = 30

-- Declared up here because Capture() hides the notice before it hides the UI,
-- and Capture is defined long before the popup is. A constant referenced above
-- its own declaration is simply nil - the call still runs, does nothing, and
-- looks right.
local CONSENT_POPUP = "ALTSTABLE_RENDER_CONSENT"

-- Which way the character is turned, in degrees. 0 is dead-on; a slight turn
-- reads better in a lineup than a passport photo, and the same value is used
-- for every capture so a row of alts is consistent. Tunable because the right
-- angle is a matter of taste and can only be judged on screen.
local DEFAULT_FACING = 20

local function Facing()
    local deg = tonumber(AltStableProbeDB and AltStableProbeDB.facing)
    if not deg then deg = DEFAULT_FACING end
    return math.rad(deg), deg
end

local function Out(s)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[render]|r " .. tostring(s))
end

-- UIParent:Hide()/Show() are PROTECTED. Called once combat has started the
-- client blocks them, and the block lands on the way BACK - so the interface
-- stays hidden for the whole fight and the addon takes the blame in an error
-- report. Seen live:
--
--   AddOn 'AltStableProbe' tried to call the protected function 'UIParent:Show()'
--
-- SetUIVisibility is the engine's own call - the one Alt+Z makes - and is not
-- protected. AltStable's camera showcase already uses it for exactly this
-- reason; the stage should never have hidden the UI a different way.
--
-- The stage survives it by being parented to WorldFrame rather than UIParent,
-- so the engine's hide does not take it with the rest of the interface.
local uiHidden        -- "engine" | "uiparent" | nil
local uiWasShown      -- was the interface up before we touched it?
local owedRestore     -- a protected restore we could not make during combat

-- Returns true only if the interface is ACTUALLY gone. The caller aborts
-- otherwise: two screenshots of a character behind a full interface are not a
-- portrait, and the fingerprint that follows would record the ruin as done.
local function HideUI()
    if uiHidden then return true end

    uiWasShown = not (UIParent and UIParent.IsShown and UIParent:IsShown() == false)

    if type(SetUIVisibility) == "function" then
        pcall(SetUIVisibility, false)
        if UIParent and UIParent:IsShown() then
            return false            -- the call did not take
        end
        uiHidden = "engine"
        return true
    end

    -- No engine support: fall back, but never in combat, where the call is
    -- blocked and would strand the player looking at nothing.
    if InCombatLockdown and InCombatLockdown() then return false end
    if UIParent and UIParent:IsShown() then
        pcall(UIParent.Hide, UIParent)
        if UIParent:IsShown() then return false end
        uiHidden = "uiparent"
        return true
    end
    return false
end

-- Returns true when the interface is back, false when we still owe it.
--
-- The flag is cleared ONLY on success. UIParent:Show() is protected, so on the
-- fallback path during combat the call is blocked - and clearing the flag first
-- would lose the fact that we still owe a restore, leaving the player without
-- an interface and nothing tracking that. That is the reported bug with an
-- extra step.
local function ShowUI()
    if not uiHidden then return true end

    -- Leave it off if that is how we found it. The quiet-after-combat trigger
    -- fires in exactly the idle moments where someone has deliberately hidden
    -- their own interface, and forcing it back would be the addon overruling
    -- them.
    if uiWasShown == false then uiHidden = nil; return true end

    if uiHidden == "engine" then
        -- The engine call is safe in combat; it is what Alt+Z does.
        if type(SetUIVisibility) == "function" then pcall(SetUIVisibility, true) end
        uiHidden = nil
        return true
    end

    if InCombatLockdown and InCombatLockdown() then
        owedRestore = true          -- paid at PLAYER_REGEN_ENABLED
        return false
    end
    pcall(UIParent.Show, UIParent)
    uiHidden = nil
    owedRestore = nil
    return true
end

local frame, model, backdrop, hint
local savedFormat
local previewing
local capturing          -- one at a time, always
local spoiled            -- the interface reappeared before both shots landed
-- Bumped by every capture and by every abort. Each timer in the chain holds the
-- value it was scheduled under and does nothing if it no longer matches, so an
-- abandoned capture cannot take a shot, record a fingerprint, or restore an
-- interface that a later capture is legitimately hiding.
local captureToken = 0
local combatSettle       -- the quiet-after-combat wait, cancellable like the rest
local captureStartedAt
local watchdog           -- cancelled by Finish, or it fires into the NEXT capture
local toldConverter      -- the "run the converter" hint: once a session

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

    -- Preview-only caption. It must be HIDDEN for a capture: anything drawn on
    -- the stage is matted straight into the cutout, which is how a tooltip once
    -- ended up beside a gnome.
    hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    hint:SetPoint("TOP", 0, -80)
    hint:Hide()

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
    pcall(model.SetFacing, model, (Facing()))
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
    -- Both from the SAME source. Written as one and/or expression the call is
    -- truncated to a single value, so the width came from GetPhysicalScreenSize
    -- and the height from GetScreenHeight - physical pixels paired with a
    -- UI-scaled number, which is nobody's screen.
    local w, h
    if type(GetPhysicalScreenSize) == "function" then
        w, h = GetPhysicalScreenSize()
    else
        w, h = GetScreenWidth(), GetScreenHeight()
    end

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
    capturing = false
    if watchdog then watchdog:Cancel(); watchdog = nil end
    frame:Hide()

    -- Escape and Alt+Z both call SetUIVisibility(true), so the player can undo
    -- our hide mid-capture - the engine hide is reversible in a way
    -- UIParent:Hide() was not. If that happened, the shots caught the interface
    -- and the portrait is ruined, so the look is deliberately NOT recorded and
    -- the next trigger tries again.
    if spoiled then
        spoiled = nil
        ShowUI()
        if savedFormat and type(SetCVar) == "function" then
            pcall(SetCVar, "screenshotFormat", savedFormat)
            savedFormat = nil
        end
        Out("|cffff8800interface came back mid-capture - portrait discarded, will retry|r")
        return
    end
    -- ALWAYS give the interface back. Everything else here is a nicety; a
    -- player left staring at an empty screen is not.
    ShowUI()
    -- Only now, once both shots are on disk: a fingerprint stored after a
    -- capture that failed half-way would suppress the retry.
    local guid = UnitGUID("player")
    if guid then RememberFingerprint(guid, LookFingerprint()) end
    if savedFormat and type(SetCVar) == "function" then
        pcall(SetCVar, "screenshotFormat", savedFormat)
    end
    -- One line per capture. The converter hint is worth saying once a session
    -- and no more: repeated identical chat is indistinguishable from something
    -- being stuck, which is exactly how the capture loop was first noticed.
    Out("portrait captured.")
    if not toldConverter then
        toldConverter = true
        Out("turn it into a cutout with:  |cffffff00pwsh Tools/RenderCutout/Update-Cutouts.ps1|r"
            .. "  (or -Watch once, and forget about it)")
    end
    -- The addon records that this LOOK was photographed; whether the picture
    -- came out is something only the converter can see. So if one is spoiled,
    -- /asrender forget puts this character back in the automatic queue.
end

local function Capture()
    -- ONE AT A TIME. Overlapping captures fought over the UI-restore flag and
    -- left the interface hidden - the player had to alt-z to get it back. The
    -- age check is the get-out: if a capture somehow never finished, a later
    -- one is allowed through rather than the feature seizing up forever.
    if capturing and captureStartedAt and (GetTime() - captureStartedAt) < 15 then
        return
    end
    -- No captures in combat, from ANY entry point. ConsiderCapture checks this
    -- for the automatic path, but /asrender and the notice's own button both
    -- reach here directly - and hiding the interface for three seconds during a
    -- pull is the single worst thing this feature can do.
    if InCombatLockdown and InCombatLockdown() then
        Out("|cffff8800not while you are in combat|r - try again once the fight is over")
        return
    end

    capturing = true
    captureStartedAt = GetTime()
    captureToken = captureToken + 1
    local token = captureToken

    Build()

    if type(Screenshot) ~= "function" then
        capturing = false
        Out("|cffff5555Screenshot() is unavailable on this client.|r")
        return
    end

    -- The stage hides UIParent, which hides any StaticPopup, which fires its
    -- OnCancel - so take the notice down ourselves first, deliberately, rather
    -- than letting the client dismiss it as a side effect.
    if type(StaticPopup_Hide) == "function" then
        pcall(StaticPopup_Hide, CONSENT_POPUP)
    end
    -- JPEG would make the matte read compression noise instead of coverage.
    if type(GetCVar) == "function" and type(SetCVar) == "function" then
        savedFormat = GetCVar("screenshotFormat")
        pcall(SetCVar, "screenshotFormat", "tga")
        if GetCVar("screenshotFormat") ~= "tga" then
            Out("|cffff8800could not switch screenshots to TGA|r - the matte will be noisy")
        end
    end

    -- Take the preview's click handler off the stage. Left attached, a click
    -- during the three seconds hides the stage while UIParent is still hidden -
    -- the shots then photograph the bare world and the player sees nothing at
    -- all until the watchdog.
    previewing = false
    hint:Hide()
    frame:EnableMouse(false)
    frame:SetScript("OnMouseDown", nil)
    PoseLiveCharacter()
    backdrop:SetColorTexture(0, 0, 0, 1)
    Out("staging... hold still, two screenshots are coming")

    -- Say it BEFORE the UI goes, or the message lands in a hidden chat frame.
    if GameTooltip and GameTooltip.Hide then pcall(GameTooltip.Hide, GameTooltip) end
    if not HideUI() then
        capturing = false
        if watchdog then watchdog:Cancel(); watchdog = nil end
        if savedFormat and type(SetCVar) == "function" then
            pcall(SetCVar, "screenshotFormat", savedFormat)
            savedFormat = nil
        end
        Out("|cffff8800could not hide the interface - no portrait taken|r"
            .. (InCombatLockdown and InCombatLockdown() and " (in combat)" or ""))
        return
    end
    frame:Show()

    -- The whole sequence is a chain of timers. If any link fails, nothing
    -- restores the interface - so an independent timer does it regardless.
    --
    -- CANCELLED on success. Left running, the one armed by an earlier capture
    -- fires in the middle of a later one: it restores the interface and hides
    -- the stage while the second shot is still pending, so that shot
    -- photographs the restored UI and the matte reads the whole frame as
    -- opaque. NewTimer rather than After, precisely so it can be cancelled.
    if watchdog then watchdog:Cancel() end
    watchdog = C_Timer.NewTimer(12, function()
        watchdog = nil
        if token ~= captureToken then return end
        -- Unconditional. The stage is a fullscreen frame on WorldFrame with no
        -- mouse: if a broken chain leaves it up, neither Escape nor Alt+Z
        -- dismisses it and the player needs /reload. ShowUI self-guards, so
        -- putting the frame behind that flag bought nothing and cost this.
        frame:Hide()
        ShowUI()
        Out("|cffff8800capture did not finish - your interface is back|r")
        -- Everything Finish would have restored, because it never ran.
        if savedFormat and type(SetCVar) == "function" then
            pcall(SetCVar, "screenshotFormat", savedFormat)
            savedFormat = nil
        end
        capturing = false
    end)

    C_Timer.After(KEY_DELAY, function()
        if token ~= captureToken then return end
        Screenshot()
        RecordMetadata(1)
        C_Timer.After(SHOT_DELAY, function()
            if token ~= captureToken then return end
            backdrop:SetColorTexture(1, 1, 1, 1)     -- same pose, other backdrop
            C_Timer.After(0.25, function()
                if token ~= captureToken then return end
                Screenshot()
                RecordMetadata(2)
                C_Timer.After(SHOT_DELAY, function()
                    if token ~= captureToken then return end
                    Finish()
                end)
            end)
        end)
    end)
end

-- Show the stage WITHOUT shooting, so the framing and the angle can be judged
-- before two screenshots are spent on them. The UI stays up (this is not a
-- capture) and a click dismisses it.
local function Preview()
    Build()
    local _, deg = Facing()
    PoseLiveCharacter()
    backdrop:SetColorTexture(0.06, 0.06, 0.07, 1)
    hint:SetText(("facing %d\194\176  -  |cffffff00/asrender facing <deg>|r to turn, " ..
                  "|cffffff00/asrender|r to capture  (click to close)"):format(deg))
    hint:Show()
    previewing = true
    frame:EnableMouse(true)
    frame:SetScript("OnMouseDown", function()
        frame:Hide(); frame:EnableMouse(false); hint:Hide(); previewing = false
    end)
    frame:Show()
end

------------------------------------------------------------
-- Auto-capture: keep portraits current without anyone typing anything
------------------------------------------------------------

local pending        -- the countdown timer, so it can be cancelled

local function AutoEnabled()
    return not (AltStableProbeDB and AltStableProbeDB.autoCaptureOff)
end

------------------------------------------------------------
-- Say what is about to happen, the first time
--
-- The capture hides the ENTIRE UI for about three seconds and takes two
-- screenshots. Unannounced, that reads as something going badly wrong with the
-- game rather than a feature working.
--
-- Shaped after the client's own layer-swap notice: state plainly what will
-- happen, offer to do it immediately, otherwise let it proceed. Two buttons, no
-- interrogation - the alarming part is an interface that vanishes without
-- warning, not the capture. After the first one the five-second chat warning is
-- enough, because by then it is a known behaviour.
------------------------------------------------------------

-- Set to "yes" once the player has seen the notice, by either button. Escape
-- closes it without answering, which leaves this nil so the notice returns next
-- login rather than capturing unannounced.
local function Consent()
    return AltStableProbeDB and AltStableProbeDB.autoConsent
end

-- Both are defined below and both are called from the popup's buttons. Without
-- the forward declaration those closures resolve a nil GLOBAL at click time -
-- which is invisible until someone presses the button.
local StartCountdown, CancelPending

if type(StaticPopupDialogs) == "table" then
    StaticPopupDialogs[CONSENT_POPUP] = {
        text = "AltStable will take a portrait of this character for the Roster lineup.\n\n"
            .. "Your interface will be hidden for about 3 seconds while it takes two "
            .. "screenshots. They are deleted once the portrait is made.\n\n"
            .. "Later takes it next time your gear changes. "
            .. "Type |cffffff00/asrender auto|r if you would rather it never did this.",
        button1 = "Capture Now",
        button2 = "Later",
        OnAccept = function()                 -- Capture Now: skip the wait
            AltStableProbeDB.autoConsent = "yes"
            CancelPending()
            Capture()
        end,
        -- "Okay", but ALSO every programmatic dismissal: hiding UIParent hides
        -- the popup and the client calls this. So it records the answer and
        -- nothing more - starting a capture from here is what looped, because
        -- the capture hides the UI, which dismisses the popup, which lands
        -- straight back in this function.
        OnCancel = function()
            AltStableProbeDB.autoConsent = "yes"
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        -- Escape closes the notice WITHOUT running OnCancel. Without this the
        -- client routes Escape through OnCancel, which records consent - so
        -- waving the dialog away would quietly agree to it, and the next gear
        -- change would hide the interface for three seconds unannounced. That
        -- is the exact outcome the notice exists to prevent.
        noCancelOnEscape = true,
        showAlert = false,
    }
end

function CancelPending(reason)
    -- The quiet-after-combat wait counts as pending. Without this, "/asrender
    -- cancel" during that window answered "nothing pending" and then took the
    -- picture thirty seconds later anyway.
    local had = false
    if combatSettle then combatSettle:Cancel(); combatSettle = nil; had = true end
    if pending then pending:Cancel(); pending = nil; had = true end
    if not had then return false end
    Out("auto-capture cancelled" .. (reason and (" - " .. reason) or ""))
    return true
end

function StartCountdown(why)
    -- Idempotent. Five of these queued at once is what turned one dismissed
    -- popup into a capture loop.
    if pending or capturing then return end
    Out(("%s - refreshing your portrait in %ds. |cffffff00/asrender cancel|r to skip.")
        :format(why, WARN_SECONDS))
    pending = C_Timer.NewTimer(WARN_SECONDS, function()
        pending = nil
        Capture()
    end)
end

local function ConsiderCapture(why)
    if not AutoEnabled() then return end
    if pending or capturing then return end
    local guid = UnitGUID("player")
    if not guid then return end

    local fp = LookFingerprint()
    if fp == StoredFingerprint(guid) then return end          -- looks the same

    -- Never interrupt a fight to take a photograph, and never put a popup on
    -- screen during one either. PLAYER_REGEN_ENABLED brings us back.
    if InCombatLockdown and InCombatLockdown() then
        Out("gear changed - portrait will refresh after combat")
        return
    end

    if Consent() ~= "yes" then
        AltStableProbeDB = AltStableProbeDB or {}
        if Consent() == "never" then return end
        if type(StaticPopup_Show) == "function" and StaticPopupDialogs
            and StaticPopupDialogs[CONSENT_POPUP] then
            -- Once. Asking again while the notice is already up queues a second
            -- copy, and each copy answers itself when the stage hides the UI.
            if type(StaticPopup_Visible) == "function"
                and StaticPopup_Visible(CONSENT_POPUP) then
                return
            end
            StaticPopup_Show(CONSENT_POPUP)
        else
            -- No popup API: say it in chat rather than doing it unannounced.
            Out("AltStable can take a portrait of this character: it hides the UI for ~3s "
                .. "and takes two screenshots. |cffffff00/asrender|r to do it, "
                .. "|cffffff00/asrender auto|r to stop being asked.")
            -- "yes", not "asked": every reader compares against "yes" or
            -- "never", so a third value means this branch is re-entered on
            -- every trigger forever - the same notice after every fight, and a
            -- portrait never taken, because nothing ever records a fingerprint.
            AltStableProbeDB.autoConsent = "yes"
        end
        return
    end

    StartCountdown(why)
end

-- SheetUI's showcase hooks this for the same reason: the engine call is how the
-- player takes their interface back, and it can land in the middle of a
-- capture.
if type(hooksecurefunc) == "function" and type(SetUIVisibility) == "function" then
    hooksecurefunc("SetUIVisibility", function(visible)
        if visible and capturing and uiHidden then
            spoiled = true
            uiHidden = nil          -- they restored it; we no longer own it
        end
    end)
end

SLASH_ASRENDER1 = "/asrender"
SlashCmdList["ASRENDER"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()

    if msg == "cancel" then
        if not CancelPending() then Out("nothing pending") end
        return
    end
    local deg = msg:match("^facing%s+(%-?%d+%.?%d*)$")
    if deg then
        AltStableProbeDB = AltStableProbeDB or {}
        AltStableProbeDB.facing = tonumber(deg)
        Out(("facing set to %s\194\176 - every capture from now on uses it"):format(deg))
        if previewing then Preview() else Out("  |cffffff00/asrender preview|r to see it") end
        return
    end
    if msg == "facing" then
        local _, d = Facing()
        Out(("facing is %d\194\176 (0 faces you straight on). usage: /asrender facing <deg>"):format(d))
        return
    end
    if msg == "preview" then
        Preview()
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
        Out("auto-capture " .. (AutoEnabled() and "on" or "off")
            .. " (consent: " .. tostring(Consent() or "not asked yet") .. ")")
        Out("look now    : " .. LookFingerprint())
        Out("last shot   : " .. tostring(guid and StoredFingerprint(guid) or "never"))
        return
    end
    if msg ~= "" then
        Out("usage: /asrender [preview|facing <deg>|cancel|auto|status|forget|forget all]")
        return
    end

    CancelPending()
    -- Doing it by hand answers the question the popup would ask.
    AltStableProbeDB = AltStableProbeDB or {}
    if Consent() ~= "never" then AltStableProbeDB.autoConsent = "yes" end
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
        if combatSettle then combatSettle:Cancel(); combatSettle = nil end
        -- Abandon an in-flight capture on EVERY path, not just the fallback.
        -- The engine hide is combat-safe to REVERSE, but leaving it in place
        -- means the player fights the pull with no action bars until the chain
        -- finishes - which is the same harm as the protected-call bug, just
        -- without an error report to show for it.
        if capturing then
            captureToken = captureToken + 1     -- every pending timer is now void
            capturing = false
            spoiled = nil
            if watchdog then watchdog:Cancel(); watchdog = nil end
            frame:Hide()
            if savedFormat and type(SetCVar) == "function" then
                pcall(SetCVar, "screenshotFormat", savedFormat)
                savedFormat = nil
            end
            local back = ShowUI()
            Out("|cffff8800combat started - portrait abandoned|r"
                .. (back and "" or " (interface returns when the fight ends)"))
        end
    elseif event == "PLAYER_LOGIN" then
        -- Inventory is not reliably readable the instant the world loads, and
        -- a fingerprint built from half-loaded gear would re-shoot every login.
        C_Timer.After(LOGIN_SETTLE, function() ConsiderCapture("gear changed since your last portrait") end)
    else
        -- First, anything we could not give back during the fight.
        if owedRestore then
            owedRestore = nil
            if ShowUI() then Out("interface restored") end
        end
        -- Then wait out the gap between pulls rather than capturing in it. Any
        -- new fight cancels this, so a long chain of pulls never reaches it.
        if combatSettle then combatSettle:Cancel() end
        combatSettle = C_Timer.NewTimer(COMBAT_SETTLE, function()
            combatSettle = nil
            ConsiderCapture("quiet since combat - gear changed since your last portrait")
        end)
    end
end)
