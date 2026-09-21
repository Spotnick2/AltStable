AltStable = AltStable or {}

------------------------------------------------------------
-- Layout constants
-- Tuned for ElvUI-style density: compact rows, tight header,
-- no wasted vertical space.
------------------------------------------------------------

local ROW_HEIGHT    = 22
local HEADER_HEIGHT = 28     -- compact; gear/skills/rep icon sections override to 32
local SIDEBAR_WIDTH = 230
local FRAME_W       = 1150   -- default; sections override via preferW
local FRAME_H       = 460    -- default; sections override via preferH
local currentHeaderHeight = HEADER_HEIGHT

-- Title bar occupies the top of the frame; everything sits below it.
local TITLE_H       = 30
-- Column header and body start below the title bar.
local HEADER_TOP_Y  = TITLE_H + 4    -- = 34 (4px gap between title bar and column header)

-- BODY_TOP_Y depends on the *current* header height, which changes per
-- section (compact 28 for text-heavy sections, 32 for icon-heavy ones).
-- Always call this; never cache the value at file load time.
local function BodyTopY()
    return HEADER_TOP_Y + currentHeaderHeight + 1
end

-- Public layout contract — plugins read these to align their content with the
-- main frame. Single source of truth for the global header height, sidebar
-- width, and row metrics. Plugins MUST anchor their panels at TITLE_H below
-- the main frame top, not at 0, or they'll overlap the AltStable title bar.
AltStable.LAYOUT = AltStable.LAYOUT or {}
AltStable.LAYOUT.TITLE_H        = TITLE_H
AltStable.LAYOUT.SIDEBAR_WIDTH  = SIDEBAR_WIDTH
AltStable.LAYOUT.HEADER_HEIGHT  = HEADER_HEIGHT
AltStable.LAYOUT.ROW_HEIGHT     = ROW_HEIGHT
AltStable.LAYOUT.FOOTER_HEIGHT  = 22

------------------------------------------------------------
-- Section definitions
-- Each section lists exactly which column fields to show
-- (excluding the frozen Name column which is always shown).
------------------------------------------------------------

-- Central icon path — set after AltStable.MEDIA_PATH is defined in Theme.lua
local function IC(name)
    return (AltStable.MEDIA_PATH or "Interface\\AddOns\\AltStable\\Media\\")
        .. "Icons\\" .. name .. ".tga"
end

local function SetSidebarIconTexture(tex, texturePath, useCrop)
    tex:SetTexture(texturePath)
    if useCrop then
        tex:SetTexCoord(0.08, 0.92, 0.92, 0.08)
    else
        tex:SetTexCoord(0, 1, 1, 0)
    end
end

local SECTIONS = {
    {
        id    = "summary",
        label = "Account Summary",
        icon  = IC("account-summary"),
        preferW = 985,
        preferH = 400,
        fields = {
            "class","race","level","ilvl",
            "guild","restPercent","money","lastUpdate",
        },
    },
    {
        id    = "gear",
        label = "Gear Progression",
        icon  = IC("gear-progression"),
        headerHeight = 32,
        preferW = 1350,
        preferH = 420,
        fields = {
            "class","race","level","ilvl",
            "gear_head","gear_neck","gear_shoulder","gear_back","gear_chest",
            "gear_wrist","gear_hands","gear_waist","gear_legs","gear_feet",
            "gear_ring1","gear_ring2","gear_trinket1","gear_trinket2",
            "gear_mainhand","gear_offhand","gear_ranged",
        },
    },
    {
        id    = "skills",
        label = "Skills",
        icon  = IC("skills"),
        headerHeight = 32,
        preferW = 1111,
        preferH = 410,
        fields = {
            "class","race","level",
            "prof_Alchemy","prof_Blacksmithing","prof_Enchanting","prof_Engineering",
            "prof_Leatherworking","prof_Tailoring",
            "prof_Herbalism","prof_Mining","prof_Skinning",
            "cooking","fishing","firstAid","riding",
        },
    },
    {
        id    = "rep",
        label = "Reputations",
        icon  = IC("reputations"),
        headerHeight = 32,
        -- Width = sidebar(190) + frozen(156) + identity(119) + 18 rep×28(504) + scrollbar(20) = 989
        preferW = 999,
        preferH = 410,
        fields = {
            "class","race","level",
            "aldor","scryer","shatar","lowercity",
            "cenarion","consortium","keepers","violeteye","sporeggar",
            "honorhold","thrallmar","kurenai","maghar",
            "ogrila","skyguard","netherwing","ashtongue","scaleofsands","shatteredsun",
        },
    },
}

-- Build a lookup: field → column def, used when building section col lists
local function BuildFieldLookup()
    local t = {}
    for _, col in ipairs(AltStable.Columns) do
        t[col.field] = col
    end
    return t
end

------------------------------------------------------------
-- State
------------------------------------------------------------

local frame
local sidebarBtns    = {}
local activeSection  = SECTIONS[1]
local scrollableCols = {}   -- columns for the current section

local headerButtons  = {}
local frozenHeader
local frozenScroll
local frozenBodyContent
local frozenRows = {}
local headerScroll
local headerContent
local bodyScroll
local bodyContent
local hScrollBar
local totalsBar
local rows = {}

-- Row pools keyed by section id so we reuse without SetParent(nil)
local rowPools         = {}   -- rowPools[sectionId] = { rows={}, frozenRows={} }
local function GetPool(sectionId)
    if not rowPools[sectionId] then
        rowPools[sectionId] = { rows={}, frozenRows={} }
    end
    return rowPools[sectionId]
end

-- Only created when devMode is on (see the ROSTER (DEV) block below), so every
-- use must be nil-guarded. Declared here rather than in the block: it was a
-- block-local while the options OnShow handler read it as a global, so with
-- devMode off the panel threw on every open.
local optModelDebugCheck

local displayList = {}
local sortColumn  = "level"
local sortAsc     = false
local collapsed   = {}

local totalChars = 0
local totalLevel = 0
local totalGold  = 0

local FROZEN_WIDTH
local NAME_COL_WIDTH

local function ComputeFrozenWidth()
    NAME_COL_WIDTH = AltStable.Columns[1].width
    FROZEN_WIDTH   = 10 + NAME_COL_WIDTH + 6
end

local AltStableCameraPresentation = {
    active = false,
    mode = nil,
    capture = nil,
    elapsed = 0,
}
AltStable.AltStableCameraPresentation = AltStableCameraPresentation

do
    -- Minimal Narcissus-style camera presentation port for Classic/BCC.
    --
    -- Design notes:
    --   * We use `test_cameraOverShoulder` for Narcissus-style lateral
    --     framing, but unregister Blizzard's experimental-CVar popup event
    --     before writing it and always restore the captured value on close.
    --   * We only use stable, non-experimental camera APIs:
    --       SaveView / SetView          -- exact view restore
    --       GetCameraZoom / CameraZoomIn / CameraZoomOut
    --       MoveViewRightStart / MoveViewRightStop  (and Left*) for orbit
    --   * Every API call is feature-detected and pcall-guarded; missing APIs
    --     fail silently.
    --   * Combat / logout / reload / errors funnel through ForceRestore so
    --     no camera state can leak past close.

    local function CameraDebug(msg)
        if not (AltStableConfig and AltStableConfig.worldCameraPresentationDebug) then
            return
        end
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable Camera]|r " .. tostring(msg or ""))
        end
    end

    local function InOutSine(t, b, e, d)
        return -(e - b) / 2 * (math.cos(math.pi * t / d) - 1) + b
    end

    function AltStableCameraPresentation:_Clamp(v, minV, maxV, fallback)
        v = tonumber(v)
        if not v then
            return fallback
        end
        if v < minV then
            return minV
        end
        if v > maxV then
            return maxV
        end
        return v
    end

    function AltStableCameraPresentation:_GetConfig()
        AltStableConfig = AltStableConfig or {}
        if AltStable.EnsureConfigDefaults then
            AltStable.EnsureConfigDefaults()
        end
        return {
            enabled       = AltStableConfig.enableWorldCameraPresentation ~= false,
            enterDuration = self:_Clamp(AltStableConfig.worldCameraEnterDuration, 0.35, 1.50, 1.50),
            exitDuration  = self:_Clamp(AltStableConfig.worldCameraExitDuration,  0.25, 1.20, 0.45),
            zoomPreset    = self:_Clamp(AltStableConfig.worldCameraZoomPreset,    1.20, 18.0, 2.2),
            shoulderZoomReference = self:_Clamp(AltStableConfig.worldCameraShoulderZoomReference, 1.20, 18.0, 6.2),
            mountedZoomPreset = self:_Clamp(AltStableConfig.worldCameraMountedZoomPreset, 1.20, 18.0, 8.0),
            mountedShoulderOffset = self:_Clamp(AltStableConfig.worldCameraMountedShoulderOffset, 0.0, 12.0, 8.0),
            forceMountedPresentation = AltStableConfig.worldCameraForceMountedPresentation == true,
            yawOffset     = self:_Clamp(AltStableConfig.worldCameraYawOffset,    -1.2,  1.2, -0.22),
            yawDegrees    = self:_Clamp(AltStableConfig.worldCameraYawDegrees,    20,   540, 430),
            savedViewSlot = math.floor(self:_Clamp(AltStableConfig.worldCameraSavedViewSlot, 2, 5, 5)),
            continuousOrbit = AltStableConfig.worldCameraContinuousOrbit == true,
            orbitSpeed    = self:_Clamp(AltStableConfig.worldCameraOrbitSpeed, 0.001, 0.05, 0.005),
            hideGameUI    = AltStableConfig.hideGameUIOnPresentation ~= false,   -- Alt+Z-style clean showcase (default on)
        }
    end

    function AltStableCameraPresentation:IsSupported()
        -- Only require the stable APIs we actually call. test_cameraOverShoulder
        -- intentionally NOT in this set.
        return type(SaveView)       == "function"
           and type(SetView)        == "function"
           and type(GetCameraZoom)  == "function"
           and type(CameraZoomIn)   == "function"
           and type(CameraZoomOut)  == "function"
    end

    function AltStableCameraPresentation:CaptureCurrentCameraState()
        if not self:IsSupported() then
            return false
        end

        local config = self:_GetConfig()
        self.config  = config
        self.capture = {
            savedViewSlot = config.savedViewSlot,
            zoom          = tonumber(GetCameraZoom()) or 0,
        }
        pcall(SaveView, self.capture.savedViewSlot)
        return true
    end

    function AltStableCameraPresentation:_SetZoom(goal)
        local current = tonumber(GetCameraZoom()) or goal
        local delta = (tonumber(goal) or current) - current
        if math.abs(delta) < 0.001 then
            return
        end
        if delta > 0 then
            pcall(CameraZoomOut, delta)
        else
            pcall(CameraZoomIn, -delta)
        end
    end

    function AltStableCameraPresentation:_StopYaw()
        if type(MoveViewRightStop) == "function" then
            pcall(MoveViewRightStop)
        end
        if type(MoveViewLeftStop) == "function" then
            pcall(MoveViewLeftStop)
        end
    end

    -- Lateral character placement via test_cameraOverShoulder. This is
    -- the "experimental" CVar that triggers WoW's confirmation popup —
    -- but we silence that popup immediately before each of our SetCVar
    -- calls fires (see SuppressExperimentalCVarPopup at the end of this
    -- block; every test_* write in the addon goes through it). Narcissus
    -- uses the same approach.
    --
    -- Per-race shoulder factor table copied from Narcissus Classic
    -- ZoomValuebyRaceID. Format: { factor1, factor2 } — used as
    --   offset = zoom * factor1 + factor2
    -- which matches each race's body width / pivot offset so the character
    -- ends up framed in roughly the same on-screen position regardless of
    -- which character is logged in.
    local SHOULDER_FACTORS = {
        [0]  = { 0.361,  -0.1654 },  -- default
        [1]  = { 0.3283, -0.02   },  -- Human
        [2]  = { 0.2667, -0.1233 },  -- Orc
        [3]  = { 0.2667, -0.0267 },  -- Dwarf
        [4]  = { 0.30,   -0.0404 },  -- Night Elf
        [5]  = { 0.3537, -0.15   },  -- Undead
        [6]  = { 0.2027, -0.18   },  -- Tauren
        [7]  = { 0.329,   0.0517 },  -- Gnome
        [8]  = { 0.2787,  0.04   },  -- Troll
        [10] = { 0.361,  -0.1654 },  -- Blood Elf
        [11] = { 0.248,  -0.02   },  -- Draenei
    }
    local MOUNTED_SHOULDER_FACTORS = { 1.2495, -4.0 }

    function AltStableCameraPresentation:_IsPlayerMounted()
        if self.config and self.config.forceMountedPresentation then
            return true
        end
        if type(IsMounted) == "function" and IsMounted() then
            return true
        end
        if type(UnitBuff) == "function" then
            for i = 1, 40 do
                local name, _, icon = UnitBuff("player", i)
                if not name then
                    break
                end
                icon = tostring(icon or ""):lower()
                if icon:find("mount", 1, true) or icon:find("ability_druid_travelform", 1, true) then
                    return true
                end
            end
        end
        return false
    end

    function AltStableCameraPresentation:_GetTargetZoom()
        if self:_IsPlayerMounted() and self.config then
            return self.config.mountedZoomPreset or 8.0
        end
        return (self.config and self.config.zoomPreset) or 2.2
    end

    function AltStableCameraPresentation:_ComputeShoulderOffset(zoom)
        local raceID = 0
        local factors
        if self:_IsPlayerMounted() then
            return (self.config and self.config.mountedShoulderOffset) or 8.0
        elseif type(UnitRace) == "function" then
            local _, _, rid = UnitRace("player")
            raceID = tonumber(rid) or 0
            factors = SHOULDER_FACTORS[raceID] or SHOULDER_FACTORS[0]
        end
        factors = factors or SHOULDER_FACTORS[0]
        -- Sign convention in WoW: POSITIVE shoulder offset shifts the
        -- character to the LEFT on screen (camera goes right of player).
        -- That's exactly what the user wants (room for the addon on the
        -- right, character visible on the left).
        local placementZoom = (self.config and self.config.shoulderZoomReference) or zoom
        local raw = placementZoom * factors[1] + factors[2]
        -- Allow a global multiplier so users can dial it in. >1.0 pushes
        -- the character further left.
        local mult = tonumber(AltStableConfig and AltStableConfig.worldCameraShoulderMult) or 1.0
        return raw * mult
    end

    function AltStableCameraPresentation:_StartYaw(speed)
        speed = tonumber(speed) or 0
        if math.abs(speed) <= 0.001 then
            return
        end
        self:_StopYaw()
        self:_ApplyYaw(speed)
    end

    function AltStableCameraPresentation:_ApplyYaw(speed)
        speed = tonumber(speed) or 0
        if math.abs(speed) <= 0.001 then
            return
        end
        if speed > 0 and type(MoveViewRightStart) == "function" then
            pcall(MoveViewRightStart, speed)
        elseif speed < 0 and type(MoveViewLeftStart) == "function" then
            pcall(MoveViewLeftStart, -speed)
        elseif speed < 0 and type(MoveViewRightStart) == "function" then
            pcall(MoveViewRightStart, -speed)
        end
    end

    -- Slow continuous orbit (Narcissus-style). Uses the same MoveView API
    -- as the swing but bypasses the swing-speed clamp because orbit speeds
    -- are an order of magnitude smaller (e.g. 0.005 vs 0.55).
    function AltStableCameraPresentation:_StartOrbit(speed)
        speed = tonumber(speed) or 0
        if math.abs(speed) <= 0.0001 then
            return
        end
        self:_StopYaw()
        if speed > 0 and type(MoveViewRightStart) == "function" then
            pcall(MoveViewRightStart, speed)
        elseif speed < 0 and type(MoveViewLeftStart) == "function" then
            pcall(MoveViewLeftStart, -speed)
        end
    end

    function AltStableCameraPresentation:_MaybeSalute()
        if self.didSalute then
            return
        end
        self.didSalute = true
        if not (AltStableConfig and AltStableConfig.enableWorldCameraSalute) then
            return
        end
        if InCombatLockdown and InCombatLockdown() then
            return
        end
        if type(DoEmote) == "function" then
            pcall(DoEmote, "SALUTE")
        end
    end

    function AltStableCameraPresentation:UpdateAnimation(elapsed)
        if not self.mode then
            if self.animFrame then
                self.animFrame:Hide()
            end
            return
        end

        self.elapsed = (self.elapsed or 0) + (elapsed or 0)

        if self.mode == "enter" then
            -- The zoom is fired once in Enter() (the engine handles the
            -- smooth animation natively). All we do here is wait for the
            -- swing duration to elapse, then hand the yaw off to the slow
            -- continuous orbit.
            local duration = math.max(0.01, self.config and self.config.enterDuration or 1.50)
            if self.config and self.yawDir and self.yawFromSpeed and self.yawToSpeed then
                local t = math.min(self.elapsed, duration)
                local speed = InOutSine(t, self.yawFromSpeed, self.yawToSpeed, duration)
                self:_ApplyYaw(self.yawDir * speed)
            end
            if self.elapsed >= duration then
                if self.config and self.config.continuousOrbit then
                    local dir = self.yawDir or 1
                    self:_StartOrbit(dir * (self.config.orbitSpeed or 0.005))
                else
                    self:_StopYaw()
                end
                self:_MaybeSalute()
                self.mode = nil
                if self.animFrame then
                    self.animFrame:Hide()
                end
                CameraDebug("enter complete")
            end
            return
        end

        if self.mode == "exit" then
            -- SetView already snapped the camera back instantly in Exit();
            -- we just wait out the exit duration so the OnUpdate loop has a
            -- chance to be torn down cleanly.
            local duration = math.max(0.01, self.config and self.config.exitDuration or 0.45)
            if self.elapsed >= duration then
                self:ForceRestore("exit-complete")
            end
        end
    end

    -- NOTE: We deliberately do NOT touch the AltStable frame's size or
    -- anchor during the camera presentation. Earlier iterations moved the
    -- addon off to a corner so the screen-centered character would be
    -- visible — but the user's correct insight is that this is purely a
    -- camera concern. We now use test_cameraOverShoulder to push the
    -- character laterally on screen (Narcissus-style), which leaves the
    -- addon sitting where the user placed it.

    function AltStableCameraPresentation:Enter()
        if self.active then
            return
        end
        if InCombatLockdown and InCombatLockdown() then
            return
        end
        self.config = self:_GetConfig()
        if not (self.config and self.config.enabled) then
            return
        end
        if not self:CaptureCurrentCameraState() then
            return
        end

        self.active        = true
        self.mode          = "enter"
        self.elapsed       = 0
        self.didSalute     = false
        self.enterFromZoom = self.capture.zoom
        self.enterToZoom   = self:_GetTargetZoom()

        -- Narcissus starts from camera view 2 before its entry yaw. We save
        -- the user's current view first, so Exit/ForceRestore still returns
        -- exactly to the pre-AltStable camera.
        if type(SetView) == "function" then
            pcall(SetView, 2)
        end

        -- Raise cameraDistanceMaxZoomFactor temporarily. On Classic/BCC this
        -- is a stable (non-experimental) CVar with a max of 2.6. The default
        -- of 1.0 caps the engine's zoom-out around ~15 yards; lifting it lets
        -- our preset of 8+ actually reach its target instead of clamping
        -- silently. Captured on entry, restored on exit.
        if type(GetCVar) == "function" and type(SetCVar) == "function" then
            self.capture.cameraDistanceMaxZoomFactor =
                tonumber(GetCVar("cameraDistanceMaxZoomFactor")) or 1.0
            if self.capture.cameraDistanceMaxZoomFactor < 2.0 then
                pcall(SetCVar, "cameraDistanceMaxZoomFactor", 2.0)
            end
        end

        -- Fire the zoom once and let the engine animate it natively. Doing
        -- this incrementally per-frame in OnUpdate (the previous approach)
        -- causes CameraZoomOut calls to queue up and overshoot, leaving the
        -- camera essentially stuck close to the player.
        self:_SetZoom(self.enterToZoom)

        -- Lateral character shift via test_cameraOverShoulder. This is
        -- exactly what Narcissus does — the only reason it's "experimental"
        -- in BCC is the popup gate, which we suppress by unregistering
        -- EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED right before the write (see
        -- SuppressExperimentalCVarPopup at the bottom of this `do` block).
        -- Capture before we touch it; restore on exit.
        if type(GetCVar) == "function" and type(SetCVar) == "function" then
            self.capture.shoulderOffset = tonumber(GetCVar("test_cameraOverShoulder")) or 0
            local desired = self:_ComputeShoulderOffset(self.enterToZoom)
            if AltStable.SuppressExperimentalCVarPopup then
                AltStable.SuppressExperimentalCVarPopup()
            end
            pcall(SetCVar, "test_cameraOverShoulder", desired)
            CameraDebug(string.format("shoulder: from=%.3f to=%.3f",
                self.capture.shoulderOffset, desired))
        end

        do
            local yawMoveSpeed = tonumber(GetCVar and GetCVar("cameraYawMoveSpeed")) or 180
            if yawMoveSpeed <= 0 then yawMoveSpeed = 180 end
            local dir     = (self.config.yawOffset or -1) < 0 and -1 or 1
            local degrees = math.abs(tonumber(self.config.yawDegrees) or 430)
            local seconds = math.max(0.05, tonumber(self.config.enterDuration) or 1.50)
            local speed   = (degrees / yawMoveSpeed) / seconds
            speed = self:_Clamp(speed, 0.10, 4.0, 1.0)
            self.yawDir = dir
            self.yawFromSpeed = speed
            self.yawToSpeed = self.config.orbitSpeed or 0.005
            self:_StartYaw(dir * speed)
            CameraDebug(string.format("enter yaw: target=%d speed=%.3f yawMoveSpeed=%.1f",
                degrees, speed, yawMoveSpeed))
        end

        if self.animFrame then
            self.animFrame:Show()
        end
        self:HideGameUI()
        CameraDebug("enter start")
    end

    function AltStableCameraPresentation:Exit(reason)
        -- Ignore the transient OnHide fired by the capture's UIParent:Hide().
        if self.capturing then return end
        if not self.active or self.mode == "exit" then
            return
        end
        self:RestoreGameUI()
        self:_StopYaw()

        self.mode         = "exit"
        self.elapsed      = 0
        self.exitFromZoom = tonumber(GetCameraZoom()) or (self.capture and self.capture.zoom) or 0
        self.exitToZoom   = (self.capture and self.capture.zoom) or self.exitFromZoom

        -- Snap the saved view back immediately; the zoom lerp on top makes the
        -- handoff look smooth even though the underlying view restore is instant.
        if self.capture and self.capture.savedViewSlot and type(SetView) == "function" then
            pcall(SetView, self.capture.savedViewSlot)
        end

        if self.animFrame then
            self.animFrame:Show()
        end
        CameraDebug("exit start: " .. tostring(reason or "hide"))
    end

    function AltStableCameraPresentation:ForceRestore(reason)
        self:RestoreGameUI()
        self:_StopYaw()
        if self.animFrame then
            self.animFrame:Hide()
        end

        if self.capture then
            if self.capture.savedViewSlot and type(SetView) == "function" then
                pcall(SetView, self.capture.savedViewSlot)
            end
            self:_SetZoom(self.capture.zoom or 0)
            -- Restore CVars exactly as captured. We restore unconditionally
            -- (even if we didn't bump them) so any path through this function
            -- leaves no trace of our CVar changes.
            if type(SetCVar) == "function" then
                if self.capture.cameraDistanceMaxZoomFactor then
                    pcall(SetCVar, "cameraDistanceMaxZoomFactor",
                          self.capture.cameraDistanceMaxZoomFactor)
                end
                if self.capture.shoulderOffset then
                    if AltStable.SuppressExperimentalCVarPopup then
                        AltStable.SuppressExperimentalCVarPopup()
                    end
                    pcall(SetCVar, "test_cameraOverShoulder",
                          self.capture.shoulderOffset)
                end
            end
        end

        self.active  = false
        self.mode    = nil
        self.capture = nil
        self.elapsed = 0
        CameraDebug("restored: " .. tostring(reason or "force"))
    end

    -- ── Optional game-UI hide (Narcissus-style clean showcase) ──────────────
    -- Uses the engine's own SetUIVisibility(false) — the same call Alt+Z makes —
    -- to hide the ENTIRE UI (Blizzard frames, unit frames, and driver-controlled
    -- addon windows like Details! that a per-frame :Hide() can't suppress, since
    -- they re-show themselves). The 3D character (WorldFrame) stays visible.
    --
    -- SetUIVisibility hides everything under UIParent, so we first lift the sheet
    -- AND GameTooltip out from under UIParent (SetParent(nil)) — exactly what
    -- Narcissus's TakeOutFromUIParent does. Reparented frames are siblings of
    -- UIParent, untouched by the engine hide, so the sheet stays up. Lifting
    -- GameTooltip too (not just the sheet) is what makes the ~100 existing
    -- GameTooltip:SetOwner/AddLine callsites keep working — an earlier attempt
    -- moved only the sheet, leaving GameTooltip stranded in the hidden UIParent
    -- so its tooltips vanished. Strata is set so GameTooltip (TOOLTIP) draws
    -- above the sheet (DIALOG).
    --
    -- Combat-safe: SetUIVisibility is what Alt+Z uses and is callable in combat;
    -- SetParent/SetScale on our NON-secure sheet + GameTooltip is allowed in
    -- combat. HideGameUI bails on entry in combat (Enter does too); every restore
    -- path (Exit + ForceRestore on combat/logout/reload) calls RestoreGameUI, so
    -- the UI can never stay stuck hidden.

    -- Lift a frame out from under UIParent (state=true) or put it back (false),
    -- compensating scale so its on-screen size is unchanged either way.
    function AltStableCameraPresentation:_TakeOut(frame, strata, state)
        if not frame then return end
        if state then
            frame._atSavedStrata = frame:GetFrameStrata()
            frame._atSavedScale  = frame:GetScale()
            local eff = frame:GetEffectiveScale()          -- capture while still parented
            pcall(frame.SetParent, frame, nil)
            if strata then pcall(frame.SetFrameStrata, frame, strata) end
            pcall(frame.SetScale, frame, eff)              -- keep the same apparent size
        else
            pcall(frame.SetParent, frame, UIParent)
            pcall(frame.SetScale, frame, frame._atSavedScale or 1)
            if frame._atSavedStrata then pcall(frame.SetFrameStrata, frame, frame._atSavedStrata) end
        end
    end

    function AltStableCameraPresentation:HideGameUI()
        if self.uiHidden then return end
        if not (self.config and self.config.hideGameUI) then return end
        local sheet = self.sheetFrame
        if not sheet then return end
        if InCombatLockdown and InCombatLockdown() then return end
        if type(SetUIVisibility) ~= "function" then return end   -- no engine support: skip cleanly

        -- Close any open chat edit box first. If we were opened by typing "/alts"
        -- in chat, its edit box is still mid-input; hiding the UI in that state
        -- and restoring it later resurrects a half-focused, un-closable /say box.
        -- Deactivating it now means restore brings nothing back.
        for i = 1, (NUM_CHAT_WINDOWS or 10) do
            local eb = _G["ChatFrame" .. i .. "EditBox"]
            if eb and eb.IsShown and eb:IsShown() then
                if type(ChatEdit_DeactivateChat) == "function" then
                    pcall(ChatEdit_DeactivateChat, eb)
                else
                    if eb.ClearFocus then pcall(eb.ClearFocus, eb) end
                    if eb.Hide then pcall(eb.Hide, eb) end
                end
            end
        end

        self:_TakeOut(sheet, "DIALOG", true)
        self:_TakeOut(GameTooltip, "TOOLTIP", true)
        pcall(SetUIVisibility, false)
        self.uiHidden = true
    end

    function AltStableCameraPresentation:RestoreGameUI()
        if not self.uiHidden then return end
        -- Clear the flag BEFORE re-showing the UI so the SetUIVisibility hook
        -- below sees us as already-restoring and doesn't recursively close.
        self.uiHidden = false
        if type(SetUIVisibility) == "function" then pcall(SetUIVisibility, true) end
        self:_TakeOut(self.sheetFrame, nil, false)
        self:_TakeOut(GameTooltip, nil, false)
    end

    AltStableCameraPresentation.animFrame = CreateFrame("Frame")
    AltStableCameraPresentation.animFrame:Hide()
    AltStableCameraPresentation.animFrame:SetScript("OnUpdate", function(_, elapsed)
        AltStableCameraPresentation:UpdateAnimation(elapsed)
    end)

    AltStableCameraPresentation.eventFrame = CreateFrame("Frame")
    AltStableCameraPresentation.eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    AltStableCameraPresentation.eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    AltStableCameraPresentation.eventFrame:RegisterEvent("PLAYER_LOGOUT")
    AltStableCameraPresentation.eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    AltStableCameraPresentation.eventFrame:SetScript("OnEvent", function(_, event)
        local p = AltStableCameraPresentation
        if event == "PLAYER_REGEN_ENABLED" then
            -- Combat ended: nothing to retry (combat START ForceRestores the
            -- showcase, so uiHidden is already false by now). Guarded restore
            -- is a cheap belt-and-suspenders in case a hide outlived combat.
            if p.uiHidden then p:RestoreGameUI() end
            return
        end
        if p.active then
            p:ForceRestore(event)
        end
    end)

    -- ESC (or Alt+Z) while our showcase is up: the engine un-hides the UI by
    -- calling SetUIVisibility(true). That's the same "two-ESC" hazard whole-UI
    -- hiding always had — first press un-hides, the sheet stays open. Catch that
    -- re-show here and close the sheet so a single ESC does the whole thing. Our
    -- own RestoreGameUI clears uiHidden BEFORE it re-shows, so this no-ops on the
    -- normal-close path (Narcissus hooks SetUIVisibility the same way).
    if type(hooksecurefunc) == "function" and type(SetUIVisibility) == "function" then
        hooksecurefunc("SetUIVisibility", function(state)
            local p = AltStableCameraPresentation
            if state and p.uiHidden and p.sheetFrame and p.sheetFrame:IsShown() then
                p.sheetFrame:Hide()   -- OnHide -> Exit -> RestoreGameUI (full restore)
            end
        end)
    end

    -- Suppress the engine-level "Are you sure you want to enable this
    -- experimental feature?" popup, which fires whenever a script writes a
    -- test_* CVar. There is no per-CVar opt-in; you get the popup for all of
    -- them or none. Narcissus takes the same approach.
    --
    -- On Classic the handler lived on UIParent, so unregistering there was
    -- enough. On this client it does not, which is why the popup reappeared on
    -- every window close and "Accept" never stuck - accepting does not stop
    -- the next write from asking again.
    --
    -- So find the actual owner rather than assuming one, and call this
    -- immediately before each of our own test_* writes rather than once at
    -- file load. Two reasons: the owning frame may not exist yet at load, and
    -- unregistering the event takes the confirmation gate away from Blizzard's
    -- own handler for the rest of the session - so we only pay that cost for
    -- users who actually touch a feature that writes one of these CVars.
    AltStable.SuppressExperimentalCVarPopup = function()
        local ev = "EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED"
        local n = 0
        -- The adapter hands back a fresh list (the raw API returns varargs,
        -- not a table - see Compat.lua), so there is nothing live to iterate
        -- and unregistering as we go is safe.
        for _, f in ipairs(AltStable.API.FramesRegisteredForEvent(ev)) do
            if type(f) == "table" and type(f.UnregisterEvent) == "function" then
                if pcall(f.UnregisterEvent, f, ev) then n = n + 1 end
            end
        end
        -- Belt and braces for a client where the lookup is unavailable.
        if n == 0 and UIParent and type(UIParent.UnregisterEvent) == "function" then
            pcall(UIParent.UnregisterEvent, UIParent, ev)
        end
        return n
    end
end

------------------------------------------------------------
-- Open animation
--
-- Plays a short fade-in + tiny scale-up when the AltStable window
-- becomes visible. Independent of the camera presentation so users can
-- toggle them separately. Self-cleans on completion; final values are
-- forced to (alpha=1, scale=user scale) so an interrupted animation
-- can never leave the frame in a half-transparent / shrunk state.
------------------------------------------------------------

local OpenAnimRunner
local function PlayOpenAnimation(targetFrame)
    if not (AltStableConfig and AltStableConfig.enableOpenAnimation) then
        return
    end
    if not targetFrame then return end

    local userScale = AltStableConfig.scale or 1.0
    local startScale = userScale * 0.96
    local duration = 0.22

    targetFrame:SetAlpha(0)
    targetFrame:SetScale(startScale)

    OpenAnimRunner = OpenAnimRunner or CreateFrame("Frame")
    OpenAnimRunner:Hide()
    OpenAnimRunner.elapsed = 0
    OpenAnimRunner:SetScript("OnUpdate", function(self, dt)
        self.elapsed = (self.elapsed or 0) + (dt or 0)
        local p = math.min(1, self.elapsed / duration)
        local eased = p * p * (3 - 2 * p) -- smoothstep
        targetFrame:SetAlpha(eased)
        targetFrame:SetScale(startScale + (userScale - startScale) * eased)
        if p >= 1 then
            targetFrame:SetAlpha(1)
            targetFrame:SetScale(userScale)
            self:SetScript("OnUpdate", nil)
            self:Hide()
        end
    end)
    OpenAnimRunner:Show()
end
AltStable._PlayOpenAnimation = PlayOpenAnimation

------------------------------------------------------------
-- Minimap button
--
-- Minimal LibDBIcon-style button. No external lib dependency to keep the
-- TOC unchanged. Position is stored as an angle around the minimap, so a
-- single number survives between sessions. Left-click toggles the sheet,
-- right-click opens config, drag repositions around the minimap edge.
------------------------------------------------------------

local minimapBtn

-- How far past the minimap edge the button centre sits, in minimap-frame
-- units. Tuned by eye against a 31px button inside a 54px tracking border:
-- lower it if the button floats, raise it if the ring art clips. No claim
-- here about what any library uses - LibDBIcon is not vendored, so that would
-- be an unverifiable number to tune against.
local MINIMAP_BUTTON_CLEARANCE = 10

-- Half the minimap's width, used only when the frame reports no size yet.
-- Measured on this client (build 1.60.1.69913): Minimap is 198 x 198, so 99.
-- The value this replaces was 70 - half of CLASSIC's 140px minimap - which
-- plus the clearance above reconstructed exactly the 80 radius that put the
-- button inside the ring. A fallback has to fail towards the client we are
-- actually on.
local MINIMAP_FALLBACK_RADIUS = 99

local function PositionMinimapButton()
    if not minimapBtn or not Minimap then return end
    AltStableConfig.minimapButton = AltStableConfig.minimapButton or {}
    local angle = tonumber(AltStableConfig.minimapButton.angle) or 200
    local rads = math.rad(angle)

    -- Measure the ring instead of assuming it. The old hardcoded 80 was a
    -- Classic number: that minimap is 140px across, so 70 + clearance landed
    -- the button just outside the edge. The Mainline minimap this client
    -- ships is bigger, so 80 fell INSIDE the map. Reading the live frame
    -- tracks whatever size the client (or the player's UI scale) gives us.
    --
    -- The button is a child of Minimap, so these are already in the same
    -- coordinate space - no scale conversion needed. Width and height are read
    -- separately so a minimap FRAME that is not square still tracks its own
    -- edge on each axis.
    --
    -- This places on an ellipse, which is the right answer for the round
    -- minimap this client ships and for any rectangular frame. It is NOT a
    -- square-minimap solution: a reskin that makes the map square leaves a
    -- button at 45 degrees short of the corner and therefore inside the map.
    -- LibDBIcon handles that with GetMinimapShape() and a per-quadrant
    -- diagonal clamp; if a square reskin ever matters here, that is the
    -- mechanism to copy rather than widening this.
    local w, h = Minimap:GetWidth() or 0, Minimap:GetHeight() or 0
    local rx = (w > 0 and w / 2 or MINIMAP_FALLBACK_RADIUS) + MINIMAP_BUTTON_CLEARANCE
    local ry = (h > 0 and h / 2 or MINIMAP_FALLBACK_RADIUS) + MINIMAP_BUTTON_CLEARANCE

    minimapBtn:ClearAllPoints()
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER", rx * math.cos(rads), ry * math.sin(rads))
end

local function CreateMinimapButton()
    if minimapBtn or not Minimap then return end
    AltStableConfig = AltStableConfig or {}
    AltStableConfig.minimapButton = AltStableConfig.minimapButton or {}

    local btn = CreateFrame("Button", "AltStableMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetMovable(true)

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetTexture("Interface\\Icons\\INV_Misc_GroupNeedMore")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 1)

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)

    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    highlight:SetBlendMode("ADD")
    highlight:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
    highlight:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)

    btn:SetScript("OnDragStart", function(self)
        self.isDragging = true
        self:SetScript("OnUpdate", function(s)
            local mx, my = Minimap:GetCenter()
            if not mx then return end
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            if scale and scale > 0 then
                px, py = px / scale, py / scale
                local angle = math.deg(math.atan2(py - my, px - mx))
                AltStableConfig.minimapButton = AltStableConfig.minimapButton or {}
                AltStableConfig.minimapButton.angle = angle
                -- Fires every frame of a drag. OnConfigChanged is empty today;
                -- whatever fills it later must be cheap or debounce.
                AltStable.OnConfigChanged("minimapButton")
                PositionMinimapButton()
            end
        end)
    end)
    btn:SetScript("OnDragStop", function(self)
        self.isDragging = nil
        self:SetScript("OnUpdate", nil)
    end)

    btn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            if AltStable.OpenConfig then AltStable.OpenConfig() end
        else
            if AltStable.ShowSheet then AltStable.ShowSheet() end
        end
    end)

    btn:SetScript("OnEnter", function(self)
        if self.isDragging then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("AltStable")
        GameTooltip:AddLine("|cffffffffLeft-click|r toggle window", 1, 1, 1)
        GameTooltip:AddLine("|cffffffffRight-click|r options", 1, 1, 1)
        GameTooltip:AddLine("|cffaaaaaaDrag|r reposition", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    minimapBtn = btn
    AltStable._minimapButton = btn
    PositionMinimapButton()

    -- The minimap can be resized after we place the button (UI scale changes,
    -- another addon reskinning the cluster). Follow it rather than stranding
    -- the button at the old radius.
    --
    -- Recorded rather than silently swallowed: without the flag, a client
    -- where this throws is indistinguishable from one that simply never
    -- resized. `/dump AltStable._minimapButton._followsResize` answers it.
    if type(Minimap.HookScript) == "function" then
        btn._followsResize =
            pcall(Minimap.HookScript, Minimap, "OnSizeChanged", PositionMinimapButton)
    else
        btn._followsResize = false
    end

    if AltStableConfig.minimapButton.hide then
        btn:Hide()
    end
end

function AltStable.SetMinimapButtonShown(show)
    AltStableConfig = AltStableConfig or {}
    AltStableConfig.minimapButton = AltStableConfig.minimapButton or {}
    AltStableConfig.minimapButton.hide = not show
    AltStable.OnConfigChanged("minimapButton")
    if not minimapBtn then
        if show then CreateMinimapButton() end
        return
    end
    if show then minimapBtn:Show() else minimapBtn:Hide() end
end

-- Build on PLAYER_LOGIN (Minimap is guaranteed to exist by then) and again
-- on first sheet creation, in case any addon manager loads us late.
do
    local mmInit = CreateFrame("Frame")
    mmInit:RegisterEvent("PLAYER_LOGIN")
    mmInit:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        if AltStable.EnsureConfigDefaults then AltStable.EnsureConfigDefaults() end
        CreateMinimapButton()
    end)
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function StackChars(text)
    local t = {}
    for i = 1, #text do t[i] = text:sub(i,i) end
    return table.concat(t, "\n")
end

local function GetCharacterStore()
    if type(AltStableDB)~="table" then return {} end
    if type(AltStableDB.characters)=="table" then return AltStableDB.characters end
    return AltStableDB
end

local function GetScrollableWidth()
    local padding=6; local total=10
    for _, col in ipairs(scrollableCols) do total=total+col.width+padding end
    return total
end

------------------------------------------------------------
-- Build scrollable column list for a section
------------------------------------------------------------

local function BuildScrollableColsForSection(section)
    wipe(scrollableCols)
    local lookup = BuildFieldLookup()
    for _, field in ipairs(section.fields) do
        -- aldor/scryer is a special combined column
        if field == "aldor" then
            -- find the repCombined column
            for _, col in ipairs(AltStable.Columns) do
                if col.type == "repCombined" and col.field == "aldor" then
                    scrollableCols[#scrollableCols+1] = col
                    break
                end
            end
        elseif lookup[field] then
            scrollableCols[#scrollableCols+1] = lookup[field]
        end
    end
end

------------------------------------------------------------
-- Display list
------------------------------------------------------------

local function BuildDisplayList()
    wipe(displayList)
    totalChars=0; totalLevel=0; totalGold=0
    local store = GetCharacterStore()

    -- Totals reflect EVERY character in the DB, not just the filtered view.
    -- Bank alts below 58 still hold gold, and users expect the total gold
    -- number to match other addons (ElvUI, etc.) that account for them.
    for _, char in next, store do
        if type(char)=="table" and char.name then
            totalLevel = totalLevel + (char.level or 0)
            totalGold  = totalGold  + (char.money or 0)
            totalChars = totalChars + 1
        end
    end

    local allChars = {}
    for _, char in next, store do
        if type(char)=="table" and char.name then
            table.insert(allChars, char)
        end
    end
    table.sort(allChars, function(a,b)
        local v1, v2
        -- Special-case the "level" sort: use a fractional effective level
        -- so that 61.78 sorts above 61.50, above 61.30 — matching what
        -- users see in the tooltip progress indicator.
        if sortColumn == "level" then
            v1 = (a.level or 0) + ((a.xpPercent or 0) / 100)
            v2 = (b.level or 0) + ((b.xpPercent or 0) / 100)
        else
            v1 = a[sortColumn]; if v1==nil then v1="" end
            v2 = b[sortColumn]; if v2==nil then v2="" end
        end
        if v1==v2 then
            local i1=a.ilvl or 0; local i2=b.ilvl or 0
            if i1~=i2 then return i1>i2 end
            return (a.name or "")<(b.name or "")
        end
        if type(v1)~=type(v2) then v1=tostring(v1); v2=tostring(v2) end
        if sortAsc then return v1<v2 else return v1>v2 end
    end)
    local realmOrder, realmChars = {}, {}
    for _, char in ipairs(allChars) do
        local realm = char.realm or "Unknown"
        if not realmChars[realm] then realmChars[realm]={}; table.insert(realmOrder,realm) end
        table.insert(realmChars[realm], char)
    end
    for _, realm in ipairs(realmOrder) do
        local chars=realmChars[realm]; local sumLvl=0; local sumGold=0
        for _, c in ipairs(chars) do
            sumLvl=sumLvl+(c.level or 0); sumGold=sumGold+(c.money or 0)
        end
        table.insert(displayList,{kind="group",realm=realm,count=#chars,
            sumLevel=sumLvl,sumGold=sumGold,collapsed=collapsed[realm]})
        if not collapsed[realm] then
            for _, char in ipairs(chars) do
                table.insert(displayList,{kind="char",data=char})
            end
        end
    end
end

------------------------------------------------------------
-- Row pool management (no SetParent — safe)
------------------------------------------------------------

local function CountVisibleRows()
    return math.max(1, math.floor(bodyScroll:GetHeight()/ROW_HEIGHT)+2)
end

local function EnsureRows(needed)
    local pool = GetPool(activeSection.id)
    -- Scrollable rows
    if #pool.rows < needed then
        for i=#pool.rows+1, needed do
            local row = AltStable.CreateRow(bodyContent, ROW_HEIGHT, scrollableCols)
            pool.rows[i]=row
            row:SetPoint("TOPLEFT",bodyContent,"TOPLEFT",0,-((i-1)*ROW_HEIGHT))
            row:SetPoint("RIGHT",bodyContent,"RIGHT",0,0)
        end
    end
    -- Frozen rows
    if #pool.frozenRows < needed then
        for i=#pool.frozenRows+1, needed do
            local frow = AltStable.CreateFrozenRow(frozenBodyContent, ROW_HEIGHT, NAME_COL_WIDTH)
            pool.frozenRows[i]=frow
            frow:SetPoint("TOPLEFT",frozenBodyContent,"TOPLEFT",0,-((i-1)*ROW_HEIGHT))
            frow:SetWidth(FROZEN_WIDTH)
        end
    end
    rows      = pool.rows
    frozenRows= pool.frozenRows
end

local function HideAllRows()
    -- Hide rows from ALL pools so only active section is visible
    for _, pool in pairs(rowPools) do
        for _, row   in ipairs(pool.rows)       do row:Hide()  end
        for _, frow  in ipairs(pool.frozenRows) do frow:Hide() end
    end
end

local function UpdateRows()
    HideAllRows()
    local needed=CountVisibleRows()
    EnsureRows(needed)
    local offset=bodyScroll:GetVerticalScroll()
    local firstIndex=math.floor(offset/ROW_HEIGHT)+1
    for i=1, needed do
        local item=displayList[firstIndex+i-1]
        local row=rows[i]; local frow=frozenRows[i]
        if not row or not frow then break end
        if item then
            if item.kind=="group" then
                AltStable.RenderGroupRow(row,item)
                AltStable.RenderFrozenGroupRow(frow,item)
            else
                AltStable.RenderRow(row,item.data,firstIndex+i-1,scrollableCols)
                AltStable.RenderFrozenCharRow(frow,item.data,firstIndex+i-1)
            end
        else
            -- Beyond the last data row but still inside the visible body
            -- area. Paint a filler row in the alternating-bg color so the
            -- table reads as continuing past the last alt — instead of
            -- leaving a dead block the user can see through to the world.
            -- index passed to renderer continues the alternating pattern
            -- from the last real row.
            local fillerIndex = firstIndex + i - 1
            AltStable.RenderFillerRow(row, fillerIndex)
            AltStable.RenderFrozenFillerRow(frow, fillerIndex)
        end
    end
end

------------------------------------------------------------
-- Scroll sizing
------------------------------------------------------------

local GOLD_ICON_SM = "|TInterface\\MoneyFrame\\UI-GoldIcon:13:13:2:0|t"

local function UpdateTotalsBar()
    if not totalsBar then return end
    local ar, ag, ab = AltStable.GetAccentRGB()
    local accentHex = string.format("|cff%02x%02x%02x", ar*255, ag*255, ab*255)

    -- The Reputations tab used to replace the totals bar entirely with the
    -- standing legend (E/R/H/F/N/U/X/-), which dropped the char/level/gold
    -- totals shown on every other tab. The footer now stays consistent across
    -- all tabs; the standing key lives in the faction column header tooltips
    -- instead (see REP_STANDING_LEGEND in BuildHeaders). Issue #8.

    -- Compute iLvl average across visible characters
    local totalIlvl, ilvlCount = 0, 0
    local store = GetCharacterStore()
    for _, char in next, store do
        if type(char)=="table" and char.name then
            if char.ilvl and char.ilvl > 0 then
                totalIlvl = totalIlvl + char.ilvl
                ilvlCount  = ilvlCount  + 1
            end
        end
    end
    local avgIlvlStr = ""
    if ilvlCount > 0 then
        -- Rounded, like the iLvl column (FormatItemLevel in RowRenderer.lua).
        avgIlvlStr = string.format("|cffaaaaaa%d|r avg iLvl", math.floor(totalIlvl / ilvlCount + 0.5))
    end

    totalsBar.left:SetText(
        accentHex .. totalChars .. "|r |cffaaaaaa chars  " ..
        accentHex .. totalLevel .. "|r |cffaaaaaa total levels|r")
    if totalsBar.mid then totalsBar.mid:SetText(avgIlvlStr) end
    totalsBar.right:SetText(
        "|cffaaaaaa" .. math.floor(totalGold/10000) .. GOLD_ICON_SM .. " total gold|r")
end

------------------------------------------------------------
-- Layout-aware scrollbar visibility.
--
-- Single source of truth: this function decides BOTH scrollbar visibility
-- and scroll-frame anchors. Frame sizing (ComputeContentSize) reads the
-- same flags via _layoutNeedsHScroll / _layoutNeedsVScroll on the frame.
--
-- Rules (from the spec):
--   - No vertical scrollbar gutter unless content exceeds visible area.
--   - No horizontal scrollbar unless columns exceed visible width.
--   - When a scrollbar is visible, reserve only enough space for it.
------------------------------------------------------------

local SCROLLBAR_GUTTER_W = 18  -- width of vertical scrollbar + a 2px breathing edge
-- The OptionsSliderTemplate slider thumb visually extends ~6px above its
-- nominal frame bounds. A 14px gutter wasn't enough; the thumb peeked into
-- the body area as a dark square (most visible on h-scrollable sections
-- like Gear Progression). 20 puts the thumb cleanly below the body row.
local HSCROLL_GUTTER_H   = 20

local function ApplyContentAnchors(needsH, needsV)
    -- Single source of truth for content-area anchors. Header, body, and
    -- frozen scrolls all use the SAME right offset, so the column header
    -- never extends beyond the body grid (and vice versa).
    --
    --   needsH: leave room at the bottom for the horizontal scrollbar
    --   needsV: leave room on the right for the vertical scrollbar
    local footerTop  = (AltStable.LAYOUT.FOOTER_HEIGHT or 22) + 1   -- +1 for the totals border line
    local bodyBot    = footerTop + (needsH and HSCROLL_GUTTER_H or 0)
    local rightInset = needsV and SCROLLBAR_GUTTER_W or 2

    bodyScroll:ClearAllPoints()
    bodyScroll:SetPoint("TOPLEFT",     frame, "TOPLEFT",     SIDEBAR_WIDTH + FROZEN_WIDTH, -BodyTopY())
    bodyScroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -rightInset, bodyBot)

    frozenScroll:ClearAllPoints()
    frozenScroll:SetPoint("TOPLEFT",    frame, "TOPLEFT",    SIDEBAR_WIDTH, -BodyTopY())
    frozenScroll:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", SIDEBAR_WIDTH, bodyBot)
    frozenScroll:SetWidth(FROZEN_WIDTH)

    -- Header right edge MUST equal body right edge — same rightInset.
    -- Without this, the last column header is clipped (no v-scroll) or
    -- overflows past the v-scrollbar (with v-scroll).
    if headerScroll then
        headerScroll:ClearAllPoints()
        headerScroll:SetPoint("TOPLEFT",  frame, "TOPLEFT",  SIDEBAR_WIDTH + FROZEN_WIDTH, -HEADER_TOP_Y)
        headerScroll:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -rightInset, -HEADER_TOP_Y)
        headerScroll:SetHeight(currentHeaderHeight)
    end

    -- Horizontal scrollbar uses the same right inset as the body so it
    -- never extends past the body's visible area (which would let its
    -- backdrop track peek out from under the bodyScroll's clip region).
    -- Y position is footerTop+1 (just above totals bar's top border line)
    -- so the slider's thumb texture, which extends above nominal bounds,
    -- still sits inside HSCROLL_GUTTER_H without intruding on body rows.
    if hScrollBar then
        hScrollBar:ClearAllPoints()
        hScrollBar:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",  SIDEBAR_WIDTH + 4, footerTop + 1)
        hScrollBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -rightInset,       footerTop + 1)
    end
end

local function UpdateScroll()
    local totalH   = #displayList * ROW_HEIGHT
    local contentW = GetScrollableWidth()

    -- Two-pass layout. Pass 1 with no scrollbars assumed; if either flag
    -- comes back true, re-anchor with the correct gutters and re-measure.
    -- Two passes is enough: a v-scrollbar appearing makes the viewport
    -- narrower, which can flip h-scroll on, but at most one flip per axis.
    local function measure(needsH, needsV)
        ApplyContentAnchors(needsH, needsV)
        return contentW > bodyScroll:GetWidth(), totalH > bodyScroll:GetHeight()
    end

    local needsH, needsV = measure(false, false)
    if needsH or needsV then
        local h2, v2 = measure(needsH, needsV)
        if h2 ~= needsH or v2 ~= needsV then
            -- Pass 3 only when the second pass changed the answer (rare:
            -- v-scrollbar appearing made h-scroll suddenly necessary, etc.)
            needsH, needsV = h2, v2
            ApplyContentAnchors(needsH, needsV)
        end
    end

    local maxH = math.max(0, contentW - bodyScroll:GetWidth())

    -- Vertical scrollbar (auto-created by UIPanelScrollFrameTemplate)
    local vbar = _G["AltStableBodyScrollScrollBar"]
    if vbar then
        if needsV then vbar:Show() else vbar:Hide() end
    end

    -- Sync content sizes
    bodyContent:SetSize(contentW,            math.max(totalH, bodyScroll:GetHeight()))
    frozenBodyContent:SetSize(FROZEN_WIDTH,  math.max(totalH, frozenScroll:GetHeight()))
    headerContent:SetSize(contentW,          currentHeaderHeight)

    -- Horizontal scrollbar visibility
    hScrollBar:SetMinMaxValues(0, maxH)
    hScrollBar:SetValue(0)
    if needsH then hScrollBar:Show() else hScrollBar:Hide() end

    -- Reset scroll positions
    headerScroll:SetHorizontalScroll(0)
    bodyScroll:SetHorizontalScroll(0)
    bodyScroll:SetVerticalScroll(0)
    frozenScroll:SetVerticalScroll(0)

    -- Publish flags so ComputeContentSize can size the frame to match
    if frame then
        frame._layoutNeedsHScroll = needsH
        frame._layoutNeedsVScroll = needsV
    end
end

------------------------------------------------------------
-- Sort arrows
------------------------------------------------------------

local function UpdateSortArrows()
    local ar, ag, ab = AltStable.GetAccentRGB()
    for _, btn in ipairs(headerButtons) do
        if btn.field==sortColumn then
            if btn.arrow then btn.arrow:Show()
                btn.arrow:SetTexCoord(0,1, sortAsc and 0 or 1, sortAsc and 1 or 0)
            end
            if btn.iconTex then btn.iconTex:SetVertexColor(ar, ag, ab)
            else btn.label:SetTextColor(ar, ag, ab) end
        else
            if btn.arrow then btn.arrow:Hide() end
            if btn.iconTex then btn.iconTex:SetVertexColor(1,1,1)
            else btn.label:SetTextColor(unpack(AltStable.C.TEXT_NORM)) end
        end
    end
end

------------------------------------------------------------
-- Header construction
------------------------------------------------------------

local COL_TOOLTIPS = {
    level="Level", ilvl="Item Level",
    gear_head="Head", gear_neck="Neck", gear_shoulder="Shoulders",
    gear_back="Back", gear_chest="Chest", gear_wrist="Wrists",
    gear_hands="Hands", gear_waist="Waist", gear_legs="Legs",
    gear_feet="Feet", gear_ring1="Ring 1", gear_ring2="Ring 2",
    gear_trinket1="Trinket 1", gear_trinket2="Trinket 2",
    gear_mainhand="Main Hand", gear_offhand="Off Hand", gear_ranged="Ranged",
}

-- Standing key for the reputation columns. Shown in each faction header's
-- hover tooltip (issue #8) so the footer can keep the normal char/level/gold
-- totals like every other tab. {letter, colorHex, name}.
local REP_STANDING_LEGEND = {
    { "E", "00ffff", "Exalted"    },
    { "R", "00ffcc", "Revered"    },
    { "H", "00ff00", "Honored"    },
    { "F", "66ff66", "Friendly"   },
    { "N", "ffffff", "Neutral"    },
    { "U", "ff6600", "Unfriendly" },
    { "X", "cc0000", "Hated"      },
    { "-", "aaaaaa", "Unknown"    },
}
-- Append the standing key to a tooltip that's already SetOwner'd + open.
local function AddRepStandingLegend(tt)
    tt:AddLine(" ", 1, 1, 1)
    for _, s in ipairs(REP_STANDING_LEGEND) do
        tt:AddLine("|cff" .. s[2] .. s[1] .. "|r  |cffcccccc" .. s[3] .. "|r", 1, 1, 1)
    end
end

local headerDividers = {}   -- textures created per BuildHeaders call, tracked for cleanup

local function ClearHeaders()
    wipe(headerButtons)
    for _, child in ipairs({headerContent:GetChildren()}) do child:Hide() end
    for _, div in ipairs(headerDividers) do div:Hide() end
    wipe(headerDividers)
end

local function BuildHeaders()
    ClearHeaders()

    -- Re-add the frozen Name button (always present, created in CreateFrameIfNeeded)
    -- It's in frozenHeader, not headerContent, so nothing to do here

    local padding=6; local x=10
    for i, col in ipairs(scrollableCols) do
        local btn=CreateFrame("Button",nil,headerContent)
        btn:SetPoint("LEFT",x,0); btn:SetSize(col.width,currentHeaderHeight); btn.field=col.field

        if col.vertical and not col.repIcon then
            local lbl=btn:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
            lbl:SetPoint("TOP",btn,"TOP",0,-2); lbl:SetPoint("BOTTOM",btn,"BOTTOM",0,2)
            lbl:SetWidth(col.width); lbl:SetJustifyH("CENTER"); lbl:SetJustifyV("TOP")
            lbl:SetWordWrap(true); lbl:SetNonSpaceWrap(true)
            lbl:SetText(StackChars(col.verticalLabel or col.label))
            btn.label=lbl
            btn:SetScript("OnClick",function()
                if sortColumn==col.field then sortAsc=not sortAsc
                else sortColumn=col.field; sortAsc=false end
                UpdateSortArrows(); BuildDisplayList(); UpdateScroll(); UpdateRows(); UpdateTotalsBar()
            end)
            btn:SetScript("OnEnter",function()
                local ar,ag,ab = AltStable.GetAccentRGB()
                lbl:SetTextColor(ar,ag,ab)
                GameTooltip:SetOwner(btn,"ANCHOR_BOTTOM"); GameTooltip:ClearLines()
                GameTooltip:AddLine(col.label,1,1,1)
                if col.type=="repCombined" then GameTooltip:AddLine("|cffaaaaaa(shows whichever is active)|r",1,1,1) end
                GameTooltip:AddLine("Sort by "..col.label,0.7,0.7,0.7); GameTooltip:Show()
            end)
            btn:SetScript("OnLeave",function()
                if sortColumn~=col.field then lbl:SetTextColor(unpack(AltStable.C.TEXT_NORM)) end
                GameTooltip:Hide()
            end)
        elseif col.slotSlug or col.profIcon or col.slotIcon or col.repIcon then
            -- slotSlug: faction-aware gear icon resolved at header-build time
            local iconPath = (col.slotSlug and AltStable.GetGearIconPath and AltStable.GetGearIconPath(col.slotSlug))
                or col.profIcon or col.slotIcon or col.repIcon
            local sz=math.min(currentHeaderHeight-4,col.width-2)
            local tex=btn:CreateTexture(nil,"OVERLAY")
            tex:SetSize(sz,sz); tex:SetPoint("CENTER",btn,"CENTER",0,0); tex:SetTexture(iconPath)
            -- Crop the pixel border of the built-in round WoW icons.
            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            btn.label=btn:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); btn.label:SetText("")
            btn.iconTex=tex
            btn:SetScript("OnClick",function()
                if sortColumn==col.field then sortAsc=not sortAsc
                else sortColumn=col.field; sortAsc=false end
                UpdateSortArrows(); BuildDisplayList(); UpdateScroll(); UpdateRows(); UpdateTotalsBar()
            end)
            btn:SetScript("OnEnter",function()
                local ar,ag,ab = AltStable.GetAccentRGB()
                tex:SetVertexColor(ar,ag,ab)
                GameTooltip:SetOwner(btn,"ANCHOR_BOTTOM"); GameTooltip:ClearLines()
                local tipText = COL_TOOLTIPS[col.field] or col.label
                GameTooltip:AddLine(tipText,1,1,1)
                if col.type=="rep" or col.type=="repCombined" then
                    -- Standing key lives here so the footer keeps normal
                    -- char/level/gold totals like every other tab (issue #8).
                    AddRepStandingLegend(GameTooltip)
                end
                GameTooltip:AddLine("Sort by "..col.label,0.7,0.7,0.7); GameTooltip:Show()
            end)
            btn:SetScript("OnLeave",function()
                tex:SetVertexColor(1,1,1)
                GameTooltip:Hide()
            end)
        elseif col.type=="classIcon" or col.type=="raceIcon" then
            -- Small centered header label for icon columns
            local SHORT = {classIcon="C", raceIcon="R"}
            local lbl=btn:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
            lbl:SetAllPoints(); lbl:SetJustifyH("CENTER"); lbl:SetJustifyV("MIDDLE")
            lbl:SetText(SHORT[col.type] or "")
            btn.label=lbl
            btn:SetScript("OnClick",function()
                if sortColumn==col.field then sortAsc=not sortAsc
                else sortColumn=col.field; sortAsc=false end
                UpdateSortArrows(); BuildDisplayList(); UpdateScroll(); UpdateRows(); UpdateTotalsBar()
            end)
            btn:SetScript("OnEnter",function()
                local ar,ag,ab = AltStable.GetAccentRGB()
                lbl:SetTextColor(ar,ag,ab)
                GameTooltip:SetOwner(btn,"ANCHOR_BOTTOM"); GameTooltip:ClearLines()
                GameTooltip:AddLine(col.label,1,1,1)
                GameTooltip:AddLine("Sort by "..col.label,0.7,0.7,0.7); GameTooltip:Show()
            end)
            btn:SetScript("OnLeave",function()
                if sortColumn~=col.field then lbl:SetTextColor(unpack(AltStable.C.TEXT_NORM)) end
                GameTooltip:Hide()
            end)
        else
            local lbl=btn:CreateFontString(nil,"OVERLAY","GameFontHighlight")
            lbl:SetPoint("LEFT",2,0); lbl:SetPoint("RIGHT",-10,0)
            lbl:SetJustifyH(col.align or "LEFT"); lbl:SetJustifyV("MIDDLE"); lbl:SetText(col.label)
            btn.label=lbl
            local arrow=btn:CreateTexture(nil,"OVERLAY")
            arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
            arrow:SetSize(8,8); arrow:SetPoint("RIGHT",btn,"RIGHT",-1,0); arrow:Hide()
            btn.arrow=arrow
            btn:SetScript("OnClick",function()
                if sortColumn==col.field then sortAsc=not sortAsc
                else sortColumn=col.field; sortAsc=false end
                UpdateSortArrows(); BuildDisplayList(); UpdateScroll(); UpdateRows(); UpdateTotalsBar()
            end)
            btn:SetScript("OnEnter",function()
                local ar,ag,ab = AltStable.GetAccentRGB()
                lbl:SetTextColor(ar,ag,ab)
                local tip=COL_TOOLTIPS[col.field]
                if tip then
                    GameTooltip:SetOwner(btn,"ANCHOR_BOTTOM"); GameTooltip:ClearLines()
                    GameTooltip:AddLine(tip,1,1,1); GameTooltip:AddLine("Sort by "..tip,0.7,0.7,0.7); GameTooltip:Show()
                end
            end)
            btn:SetScript("OnLeave",function()
                if sortColumn~=col.field then lbl:SetTextColor(unpack(AltStable.C.TEXT_NORM)) end
                GameTooltip:Hide()
            end)
        end

        table.insert(headerButtons,btn)
        if i<#scrollableCols then
            local div=headerContent:CreateTexture(nil,"OVERLAY")
            div:SetSize(1,currentHeaderHeight); div:SetPoint("LEFT",x+col.width+math.floor(padding/2),0)
            div:SetColorTexture(unpack(AltStable.C.GRIDLINE))
            table.insert(headerDividers, div)
        end
        x=x+col.width+padding
    end
    UpdateSortArrows()
end

------------------------------------------------------------
-- Per-section window resize.
-- SetSize changes only the dimensions, never the anchor points, so the
-- window stays wherever the user left it.  No need to ClearAllPoints.
------------------------------------------------------------

local function ResizeFrame(w, h)
    if not frame then return end
    frame:SetSize(w, h)
end

local function SaveWindowPosition()
    if not (frame and AltStableConfig and AltStableConfig.rememberWindowPosition) then
        return
    end
    local point, _, relativePoint, xOfs, yOfs = frame:GetPoint(1)
    AltStable.SetConfigValue("windowPosition", {
        point = point or "CENTER",
        relativePoint = relativePoint or point or "CENTER",
        x = xOfs or 0,
        y = yOfs or 0,
    })
end

local function ApplyWindowPosition()
    if not frame then return end
    frame:ClearAllPoints()
    local pos = AltStableConfig and AltStableConfig.rememberWindowPosition and AltStableConfig.windowPosition
    if type(pos) == "table" and pos.point then
        frame:SetPoint(pos.point, UIParent, pos.relativePoint or pos.point, tonumber(pos.x) or 0, tonumber(pos.y) or 0)
    else
        frame:SetPoint("CENTER")
    end
end

local function ResetWindowPosition()
    AltStableConfig = AltStableConfig or {}
    AltStable.SetConfigValue("windowPosition", nil)
    if frame then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER")
    end
end

AltStable.ResetWindowPosition = ResetWindowPosition

------------------------------------------------------------
-- Content-driven frame sizing
--
-- Width  = sidebar + frozen Name col + scrollable cols + vertical scrollbar
-- Height = title bar + column header + (clamped row count × ROW_HEIGHT) + footer
--
-- The section's static preferW/preferH on the SECTIONS table is no longer the
-- source of truth — those left empty borders around the table when the user
-- had fewer alts than the static height assumed, or when the addon was
-- toggled (ShowSheet used to reset to FRAME_W/FRAME_H, blowing away the
-- previous SwitchSection resize). Now the frame snaps tight to whatever's
-- being shown, so the grid feels attached to the frame edges.
------------------------------------------------------------

local MIN_BODY_ROWS = 4   -- minimum row slots so the frame doesn't shrink to a sliver
local MAX_BODY_ROWS = 22  -- cap so users with 50+ alts still get a scrollable view

local function ComputeContentSize()
    local rawRowCount = #displayList
    local rowCount    = rawRowCount
    if rowCount < MIN_BODY_ROWS then rowCount = MIN_BODY_ROWS end
    if rowCount > MAX_BODY_ROWS then rowCount = MAX_BODY_ROWS end

    -- Will the visible row count fit? If we capped rowCount below, that
    -- means the user has more characters than the viewport can show, so
    -- a vertical scrollbar will be needed. This is the single decision
    -- point for v-scrollbar gutter reservation.
    local needsV = rawRowCount > rowCount

    -- Width is determined entirely by columns + sidebar + frozen + maybe
    -- v-scrollbar gutter. There's no horizontal-scrollbar contribution to
    -- width because the h-scrollbar lives below the body, not beside it.
    local w = SIDEBAR_WIDTH + (FROZEN_WIDTH or 156) + GetScrollableWidth()
            + (needsV and SCROLLBAR_GUTTER_W or 4)

    -- Whether h-scroll is needed is decided by content width vs the
    -- viewport width AT THIS frame width — which we just computed.
    -- The viewport width = w - SIDEBAR_WIDTH - FROZEN_WIDTH - rightInset.
    local rightInset = needsV and SCROLLBAR_GUTTER_W or 2
    local viewportW  = w - SIDEBAR_WIDTH - FROZEN_WIDTH - rightInset
    local needsH     = GetScrollableWidth() > viewportW

    local h = TITLE_H                                       -- title bar
            + 4                                             -- gap title→header
            + currentHeaderHeight                           -- column header
            + 1                                             -- separator under header
            + (rowCount * ROW_HEIGHT)                       -- body
            + (needsH and HSCROLL_GUTTER_H or 0)            -- h-scrollbar gutter
            + (AltStable.LAYOUT.FOOTER_HEIGHT or 22)       -- totals bar
            + 2                                             -- breath above frame border

    -- Sidebar height floor.
    --
    -- The sidebar holds N navigation buttons and nothing beneath them any
    -- more - the Filter row and Hide-below checkbox are gone with the
    -- always-on filter, and SIDEBAR_BOTTOM_FOOTER is 0. Plugins can register
    -- more buttons at runtime, so the required height is queried live, not
    -- hardcoded.
    --
    -- When the data grid is shorter than the sidebar — few alts on a
    -- single realm, realm collapsed, or any plugin section that returns
    -- a small list — the frame must still be tall enough that the last
    -- sidebar button doesn't overlap the totals bar. Force the frame
    -- height up to the sidebar minimum here. The body grid below pads
    -- itself with empty filler rows in UpdateRows() so the table reads
    -- as continuing past the last data row.
    local sidebarMin = TITLE_H + (AltStable.GetSidebarRequiredHeight and AltStable.GetSidebarRequiredHeight() or 0)
    if h < sidebarMin then h = sidebarMin end

    return w, h, needsH, needsV
end

local function ResizeFrameToContent()
    if not frame then return end
    -- Plugins (Recipes, Options) manage their own sizing — don't fight them.
    if activeSection and activeSection._isPlugin then return end
    local w, h, needsH, needsV = ComputeContentSize()
    frame:SetSize(w, h)
    -- ComputeContentSize is the authority on scrollbar visibility — it's
    -- derived purely from row count and column width vs the frame size we
    -- just set, so it's always self-consistent. UpdateScroll's measure()
    -- might disagree by a pixel due to rounding; ComputeContentSize wins.
    frame._layoutNeedsHScroll = needsH
    frame._layoutNeedsVScroll = needsV
    -- Apply final anchors and sync content sizes / scrollbar visibility.
    UpdateScroll()
end

------------------------------------------------------------
-- Section switching
------------------------------------------------------------

local function AdjustHeaderHeight(h)
    currentHeaderHeight = h
    if frozenHeader then frozenHeader:SetHeight(h) end
    if headerScroll then headerScroll:SetHeight(h) end
    if headerContent then headerContent:SetHeight(h) end
    -- Body scroll TOPLEFT anchors are handled by ApplyContentAnchors via
    -- BodyTopY(), which reads currentHeaderHeight. UpdateScroll always runs
    -- after this in SwitchSection, so no need to set anchors here.
end

local function SwitchSection(section)
    -- If a plugin is currently active, deactivate it first
    if activeSection._isPlugin and activeSection.OnDeactivate then
        activeSection.OnDeactivate(frame)
    end

    -- If the previous section was a plugin, restore the normal content frames
    if activeSection._isPlugin and frame then
        if frame.bodyScroll   then frame.bodyScroll:Show()   end
        if frame.frozenScroll then frame.frozenScroll:Show() end
        if frame.headerScroll then frame.headerScroll:Show() end
        if frame.frozenHeader then frame.frozenHeader:Show() end
        if frame.hScrollBar   then frame.hScrollBar:Show()  end
        if frame.totalsBar    then frame.totalsBar:Show()   end
    end

    activeSection = section

    -- Adjust header height for this section
    AdjustHeaderHeight(section.headerHeight or HEADER_HEIGHT)

    -- Highlight active sidebar button using theme accent
    local ar, ag, ab = AltStable.GetAccentRGB()
    for _, btn in ipairs(sidebarBtns) do
        if btn.sectionId == section.id then
            btn:SetBackdropColor(
                AltStable.C.BG_BTN_ACTIVE[1], AltStable.C.BG_BTN_ACTIVE[2],
                AltStable.C.BG_BTN_ACTIVE[3], AltStable.C.BG_BTN_ACTIVE[4])
            btn.lbl:SetTextColor(ar, ag, ab)
            if btn.icon then btn.icon:SetAlpha(1.0) end
            if btn.accentStripe then
                btn.accentStripe:SetColorTexture(ar, ag, ab, 1)
                btn.accentStripe:Show()
            end
        else
            btn:SetBackdropColor(
                AltStable.C.BG_BTN_IDLE[1], AltStable.C.BG_BTN_IDLE[2],
                AltStable.C.BG_BTN_IDLE[3], AltStable.C.BG_BTN_IDLE[4])
            btn.lbl:SetTextColor(unpack(AltStable.C.TEXT_DIM))
            if btn.icon then btn.icon:SetAlpha(0.65) end
            if btn.accentStripe then btn.accentStripe:Hide() end
        end
    end

    BuildScrollableColsForSection(section)
    BuildHeaders()
    UpdateScroll()
    local needed=CountVisibleRows()
    EnsureRows(needed)
    BuildDisplayList()
    UpdateRows()
    UpdateTotalsBar()

    -- Snap the frame to the actual content size for this section.
    -- Plugins (and the built-in Options pseudo-section) manage their own
    -- size in OnActivate, so ResizeFrameToContent early-outs for them.
    ResizeFrameToContent()
end

------------------------------------------------------------
-- Main frame
------------------------------------------------------------

local function CreateFrameIfNeeded()
    if frame then return end

    AltStableConfig = AltStableConfig or {}

    ComputeFrozenWidth()
    BuildScrollableColsForSection(activeSection)

    frame=CreateFrame("Frame","AltStableSheet",UIParent,"BackdropTemplate")
    frame:SetSize(FRAME_W, FRAME_H)
    ApplyWindowPosition()
    frame:SetFrameStrata("DIALOG"); frame:SetToplevel(true)
    AltStable.ApplyBackdrop(frame,
        AltStable.C.BG_MAIN[1], AltStable.C.BG_MAIN[2],
        AltStable.C.BG_MAIN[3], AltStable.C.BG_MAIN[4])
    frame:SetScale(AltStableConfig.scale or 1.0)
    frame:SetMovable(true); frame:EnableMouse(false)  -- drag handled by titleBar
    tinsert(UISpecialFrames,"AltStableSheet")
    frame:SetScript("OnShow", function()
        -- The capture's UIParent:Show() re-fires this OnShow; skip re-entering the
        -- presentation / replaying the open animation during a capture.
        if AltStableCameraPresentation and AltStableCameraPresentation.capturing then return end
        -- Camera presentation runs first so the frame-shift it performs
        -- happens before the open-animation alpha fade — otherwise the
        -- frame would fade in at its old position and jump.
        if AltStableCameraPresentation and AltStableCameraPresentation.Enter then
            AltStableCameraPresentation:Enter()
        end
        if AltStable._PlayOpenAnimation then
            AltStable._PlayOpenAnimation(frame)
        end
    end)
    frame:SetScript("OnHide", function()
        if AltStableCameraPresentation and AltStableCameraPresentation.Exit then
            AltStableCameraPresentation:Exit("sheet-hide")
        end
    end)

    -- The camera presentation reparents this sheet out from under UIParent while
    -- it hides the game UI, so it needs a handle to it.
    if AltStableCameraPresentation then
        AltStableCameraPresentation.sheetFrame = frame
    end

    --------------------------------------------------------
    -- Title bar — full-width, spans the top of the frame.
    -- Owns drag, title text, and close button.
    --------------------------------------------------------

    local titleBar = CreateFrame("Frame", nil, frame)
    titleBar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, 0)
    titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT",  0, 0)
    titleBar:SetHeight(TITLE_H)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
    titleBar:SetScript("OnDragStop",  function()
        frame:StopMovingOrSizing()
        SaveWindowPosition()
    end)

    -- Title bar background (slightly lighter than main to distinguish)
    local tbBg = titleBar:CreateTexture(nil, "BACKGROUND")
    tbBg:SetAllPoints()
    tbBg:SetColorTexture(0.10, 0.10, 0.10, 1)

    -- Bottom separator on title bar
    local tbSep = titleBar:CreateTexture(nil, "OVERLAY")
    tbSep:SetHeight(1)
    tbSep:SetPoint("BOTTOMLEFT",  titleBar, "BOTTOMLEFT",  0, 0)
    tbSep:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    tbSep:SetColorTexture(0, 0, 0, 1)

    -- Title text — centered across the full width of the title bar.
    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    titleText:SetText("AltStable")
    local function UpdateTitleTextColor()
        local r, g, b = AltStable.GetAccentRGB()
        titleText:SetTextColor(r, g, b)
    end
    UpdateTitleTextColor()
    AltStable.RegisterThemeCallback(UpdateTitleTextColor)

    -- Close button inside title bar, far right
    local close = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    close:SetSize(18, 18)
    close:SetPoint("RIGHT", titleBar, "RIGHT", -6, 0)
    close:SetFrameLevel(titleBar:GetFrameLevel() + 5)
    AltStable.ApplyBackdrop(close, 0.18, 0.05, 0.05, 1)
    local closeX = close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    closeX:SetAllPoints(); closeX:SetJustifyH("CENTER"); closeX:SetText("|cffdddddd×|r")
    close:SetScript("OnClick",  function() frame:Hide() end)
    close:SetScript("OnEnter",  function() close:SetBackdropColor(0.35, 0.08, 0.08, 1) end)
    close:SetScript("OnLeave",  function() close:SetBackdropColor(0.18, 0.05, 0.05, 1) end)

    -- Update-reference (screenshot) button — captures a clean shot of the
    -- presented character for the AI portrait pipeline. The camera presentation
    -- has already framed/faced the character and hidden the game UI, so we only
    -- hide THIS window (via alpha, so we don't fire OnHide/Exit and tear the
    -- presentation down), draw weapons, Screenshot(), then restore. Stamps
    -- refshot_ts on the player's record for the pipeline to match.
    local function CaptureReferenceFromSheet()
        if type(Screenshot) ~= "function" then return end
        local guid = UnitGUID("player")
        local char = guid and AltStableDB and AltStableDB[guid]
        if not char then
            print("|cffff8800AltStable:|r no character record yet — reopen once so it scans.")
            return
        end

        -- Which weapon to show. GetSheathState: 1=sheathed, 2=melee drawn,
        -- 3=ranged drawn. Hunters want the bow (3); everyone else wants their
        -- main-hand melee weapon (2), NOT their wand. We toggle until the target
        -- state, re-checking after each (it's animated), then leave extra settle
        -- time so the draw finishes before the shot (a bow takes a beat).
        local _, classFile = UnitClass("player")
        local targetState = (classFile == "HUNTER") and 3 or 2
        local haveSheath = type(GetSheathState) == "function" and type(ToggleSheath) == "function"
        local wasSheathed = false
        if haveSheath then
            local ok, s0 = pcall(GetSheathState)
            wasSheathed = (ok and s0 == 1)
        end

        local saved = {}
        -- test_* CVars trip the experimental-CVar confirmation popup, so the
        -- owner has to be unregistered immediately before each write - a
        -- single call at load is not enough (see
        -- SuppressExperimentalCVarPopup). Routing every write through setcv
        -- means the restore path below gets the same treatment.
        local function SilenceExperimental(k)
            if k:find("^test_") and AltStable.SuppressExperimentalCVarPopup then
                AltStable.SuppressExperimentalCVarPopup()
            end
        end
        local function setcv(k, v)
            if type(GetCVar) == "function" and type(SetCVar) == "function" then
                saved[k] = GetCVar(k)
                SilenceExperimental(k)
                pcall(SetCVar, k, v)
            end
        end

        local function doCapture()
            -- Nameplates survive UIParent:Hide, so always hide them for the shot.
            setcv("nameplateShowEnemies", 0)
            setcv("nameplateShowFriends", 0)
            setcv("nameplateShowAll", 0)

            -- Auto-frame (default): center the character (the presentation shifts
            -- it aside for this window) and zoom out to full-body. When
            -- AltStableConfig.refCaptureUseCurrentView is set, skip both and
            -- capture the camera exactly as the player has framed it.
            local savedZoom
            if not (AltStableConfig and AltStableConfig.refCaptureUseCurrentView) then
                setcv("test_cameraOverShoulder", 0)
                if type(GetCameraZoom) == "function" then
                    savedZoom = GetCameraZoom()
                    local target = tonumber(AltStableConfig and AltStableConfig.refCaptureZoom) or 6.5
                    local delta = target - (savedZoom or 0)
                    if delta > 0.05 and type(CameraZoomOut) == "function" then pcall(CameraZoomOut, delta)
                    elseif delta < -0.05 and type(CameraZoomIn) == "function" then pcall(CameraZoomIn, -delta) end
                end
            end

            frame:SetAlpha(0)
            C_Timer.After(1.3, function()   -- let the weapon draw + zoom + recenter settle
                -- Blackout for the shot. When the showcase is active the engine has
                -- ALREADY hidden the whole UI via SetUIVisibility(false), so the
                -- sheet (now alpha 0) is the only thing left to hide — don't touch
                -- UIParent, or UIParent:Show() below would un-hide all the clutter
                -- mid-showcase. When the showcase is OFF (hideGameUI disabled), we
                -- own the blackout: UIParent:Hide() hides ALL UI, including driver-
                -- controlled frames (unit frames, DPS meters), so the shot is still
                -- spotless. `capturing` stops the sheet's OnHide (fired by hiding
                -- UIParent) from tearing the showcase down, and stops OnShow from
                -- re-running Enter when we bring UIParent back.
                AltStableCameraPresentation.capturing = true
                local ownBlackout = not AltStableCameraPresentation.uiHidden
                if ownBlackout and UIParent and UIParent.Hide then UIParent:Hide() end
                C_Timer.After(0.1, function()
                    char.refshot_ts = time()
                    Screenshot()
                    C_Timer.After(0.5, function()
                        if ownBlackout and UIParent and UIParent.Show then UIParent:Show() end
                        AltStableCameraPresentation.capturing = false
                        frame:SetAlpha(1)
                        if type(SetCVar) == "function" then
                            for k, v in pairs(saved) do
                                if v then
                                    SilenceExperimental(k)
                                    pcall(SetCVar, k, v)
                                end
                            end
                        end
                        if savedZoom and type(GetCameraZoom) == "function" then
                            local cur = GetCameraZoom()
                            local d = savedZoom - cur
                            if d > 0.05 and type(CameraZoomOut) == "function" then pcall(CameraZoomOut, d)
                            elseif d < -0.05 and type(CameraZoomIn) == "function" then pcall(CameraZoomIn, -d) end
                        end
                        if wasSheathed and type(ToggleSheath) == "function" then pcall(ToggleSheath) end
                        print("|cff88ff88AltStable:|r reference captured. |cffffff00/reload|r to save it, then re-run the render pipeline.")
                    end)
                end)
            end)
        end

        if haveSheath then
            local function reach(n)
                local ok, s = pcall(GetSheathState)
                if (not ok) or s == targetState or n >= 4 then
                    doCapture()
                else
                    pcall(ToggleSheath)
                    C_Timer.After(0.45, function() reach(n + 1) end)
                end
            end
            reach(0)
        else
            doCapture()
        end
    end

    local refBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    refBtn:SetSize(18, 18)
    refBtn:SetPoint("RIGHT", close, "LEFT", -6, 0)
    refBtn:SetFrameLevel(titleBar:GetFrameLevel() + 5)
    AltStable.ApplyBackdrop(refBtn, 0.12, 0.12, 0.12, 1)
    local refIcon = refBtn:CreateTexture(nil, "OVERLAY")
    refIcon:SetPoint("CENTER")
    refIcon:SetSize(13, 13)
    refIcon:SetTexture("Interface\\ICONS\\INV_Misc_Spyglass_02")
    -- Custom richer tooltip, parented to the sheet so it rides along when the
    -- presentation lifts the sheet out from under UIParent. (GameTooltip is also
    -- lifted during the showcase, so it would work too, but this one is a purpose
    -- built multi-line panel.)
    local refTip = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    refTip:SetFrameStrata("TOOLTIP")
    refTip:SetToplevel(true)
    refTip:SetFrameLevel(200)
    refTip:SetPoint("TOPRIGHT", refBtn, "BOTTOMRIGHT", 0, -5)
    refTip:SetSize(258, 62)
    AltStable.ApplyBackdrop(refTip, 0.05, 0.05, 0.05, 0.96)
    local refTipText = refTip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    refTipText:SetPoint("TOPLEFT", 9, -8)
    refTipText:SetPoint("BOTTOMRIGHT", -9, 8)
    refTipText:SetJustifyH("LEFT"); refTipText:SetJustifyV("TOP")
    refTipText:SetText("|cffffffffUpdate reference|r\n|cffbbbbbbClean screenshot of this character for its AI " ..
        "portrait — draws the weapon, hides the UI, frames full-body. |r|cffffff00/reload|r|cffbbbbbb after to save it.|r")
    refTip:Hide()

    refBtn:SetScript("OnClick", CaptureReferenceFromSheet)
    refBtn:SetScript("OnEnter", function()
        refBtn:SetBackdropColor(0.22, 0.22, 0.22, 1)
        refTip:Show()
        refTip:Raise()
    end)
    refBtn:SetScript("OnLeave", function()
        refBtn:SetBackdropColor(0.12, 0.12, 0.12, 1)
        refTip:Hide()
    end)

    --------------------------------------------------------
    -- Left sidebar
    --------------------------------------------------------

    local sidebar=CreateFrame("Frame",nil,frame,"BackdropTemplate")
    sidebar:SetPoint("TOPLEFT",frame,"TOPLEFT",1,-TITLE_H)
    sidebar:SetPoint("BOTTOMLEFT",frame,"BOTTOMLEFT",1,1)
    -- Fill flush to the SIDEBAR_WIDTH divider line. Was SIDEBAR_WIDTH-8,
    -- which left an 8px dead band between the sidebar's right edge and
    -- the grid's left edge — visible as a vertical strip of empty dark
    -- space in screenshots.
    sidebar:SetWidth(SIDEBAR_WIDTH-1)
    AltStable.ApplyBGOnly(sidebar,
        AltStable.C.BG_SIDEBAR[1], AltStable.C.BG_SIDEBAR[2],
        AltStable.C.BG_SIDEBAR[3], AltStable.C.BG_SIDEBAR[4])

    -- Sidebar right border (1px separator)
    local sbRightLine = sidebar:CreateTexture(nil,"OVERLAY")
    sbRightLine:SetWidth(1)
    sbRightLine:SetPoint("TOPRIGHT",sidebar,"TOPRIGHT",0,0)
    sbRightLine:SetPoint("BOTTOMRIGHT",sidebar,"BOTTOMRIGHT",0,0)
    sbRightLine:SetColorTexture(0, 0, 0, 1)

    -- Thin top divider to visually separate first button from the sidebar top edge
    local sbDivider=sidebar:CreateTexture(nil,"ARTWORK")
    sbDivider:SetHeight(1)
    sbDivider:SetPoint("TOPLEFT",sidebar,"TOPLEFT",0,-4)
    sbDivider:SetPoint("TOPRIGHT",sidebar,"TOPRIGHT",0,-4)
    sbDivider:SetColorTexture(unpack(AltStable.C.SEP))

    -- Section buttons start just below the top divider
    local SIDEBAR_BUTTON_H = 52
    local SIDEBAR_BUTTON_STEP = 53
    local SIDEBAR_BUTTON_ICON = 36
    local btnY = -8
    for _, section in ipairs(SECTIONS) do
        local btn=CreateFrame("Button",nil,sidebar,"BackdropTemplate")
        btn:SetHeight(SIDEBAR_BUTTON_H)
        btn:SetPoint("TOPLEFT",sidebar,"TOPLEFT",0,btnY)
        btn:SetPoint("TOPRIGHT",sidebar,"TOPRIGHT",0,btnY)
        AltStable.ApplyBGOnly(btn,
            AltStable.C.BG_BTN_IDLE[1], AltStable.C.BG_BTN_IDLE[2],
            AltStable.C.BG_BTN_IDLE[3], AltStable.C.BG_BTN_IDLE[4])
        btn.sectionId = section.id

        -- Left accent stripe (shown only when active)
        local stripe=btn:CreateTexture(nil,"OVERLAY")
        stripe:SetWidth(2)
        stripe:SetPoint("TOPLEFT",btn,"TOPLEFT",0,0)
        stripe:SetPoint("BOTTOMLEFT",btn,"BOTTOMLEFT",0,0)
        stripe:Hide()
        btn.accentStripe = stripe

        -- Icon — alpha dims/brightens rather than tinting so artwork colors show
        local icon=btn:CreateTexture(nil,"ARTWORK")
        icon:SetSize(SIDEBAR_BUTTON_ICON, SIDEBAR_BUTTON_ICON); icon:SetPoint("LEFT",10,0)
        SetSidebarIconTexture(icon, section.icon, false)
        icon:SetAlpha(0.78)  -- inactive

        -- Label
        local lbl=btn:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        lbl:SetPoint("LEFT",52,0); lbl:SetPoint("RIGHT",-8,0)
        lbl:SetJustifyH("LEFT"); lbl:SetText(section.label)
        lbl:SetTextColor(unpack(AltStable.C.TEXT_DIM))
        btn.lbl=lbl; btn.icon=icon

        btn:SetScript("OnClick",function() SwitchSection(section) end)
        btn:SetScript("OnEnter",function()
            if activeSection.id~=section.id then
                btn:SetBackdropColor(
                    AltStable.C.BG_BTN_HOVER[1], AltStable.C.BG_BTN_HOVER[2],
                    AltStable.C.BG_BTN_HOVER[3], AltStable.C.BG_BTN_HOVER[4])
                lbl:SetTextColor(unpack(AltStable.C.TEXT_BRIGHT))
                icon:SetAlpha(0.85)
            end
        end)
        btn:SetScript("OnLeave",function()
            if activeSection.id~=section.id then
                btn:SetBackdropColor(
                    AltStable.C.BG_BTN_IDLE[1], AltStable.C.BG_BTN_IDLE[2],
                    AltStable.C.BG_BTN_IDLE[3], AltStable.C.BG_BTN_IDLE[4])
                lbl:SetTextColor(unpack(AltStable.C.TEXT_DIM))
                icon:SetAlpha(0.78)
            end
        end)

        table.insert(sidebarBtns,btn)
        btnY = btnY - SIDEBAR_BUTTON_STEP
    end

    --------------------------------------------------------
    -- Plugin buttons (registered via AltStable.RegisterPlugin)
    -- We store the current Y offset on the sidebar so that
    -- AddPluginButton (called live when a plugin registers late)
    -- can append below whatever is already there.
    --------------------------------------------------------

    sidebar._pluginBtnY = btnY  -- tracked so late-registering plugins can append

    -- Returns the vertical space the sidebar needs to display all of its
    -- buttons without the bottom items overlapping the topmost data rows or
    -- the totals bar.
    --
    -- Used by ComputeContentSize so the frame is at least sidebar-tall when
    -- the data grid would otherwise be shorter (few characters, all on one
    -- realm, the realm group collapsed, etc.). Recomputes live whenever
    -- it's called, so plugin-added buttons that grow the sidebar make the
    -- minimum frame height grow automatically.
    --
    -- Math: btnY starts at -8 (top inset) and decrements by 27 per button.
    -- _pluginBtnY is the next-empty-Y after all buttons. There are no bottom
    -- controls any more, so nothing is reserved below the last button beyond
    -- 8px of breathing space.
    local SIDEBAR_TOP_INSET     = 8
    local SIDEBAR_BOTTOM_FOOTER = 0
    local SIDEBAR_BOTTOM_BREATH = 8
    AltStable.GetSidebarRequiredHeight = function()
        if not sidebar or not sidebar._pluginBtnY then return 0 end
        local buttonsHeight = SIDEBAR_TOP_INSET + (-sidebar._pluginBtnY) - SIDEBAR_TOP_INSET
        return buttonsHeight + SIDEBAR_BOTTOM_FOOTER + SIDEBAR_BOTTOM_BREATH
    end

    local function MakePluginButton(plugin)
        local pbtn=CreateFrame("Button",nil,sidebar,"BackdropTemplate")
        pbtn:SetHeight(SIDEBAR_BUTTON_H)
        pbtn:SetPoint("TOPLEFT",sidebar,"TOPLEFT",0,sidebar._pluginBtnY)
        pbtn:SetPoint("TOPRIGHT",sidebar,"TOPRIGHT",0,sidebar._pluginBtnY)
        AltStable.ApplyBGOnly(pbtn,
            AltStable.C.BG_BTN_IDLE[1], AltStable.C.BG_BTN_IDLE[2],
            AltStable.C.BG_BTN_IDLE[3], AltStable.C.BG_BTN_IDLE[4])
        pbtn.sectionId = plugin.id

        local stripe=pbtn:CreateTexture(nil,"OVERLAY")
        stripe:SetWidth(2)
        stripe:SetPoint("TOPLEFT",pbtn,"TOPLEFT",0,0)
        stripe:SetPoint("BOTTOMLEFT",pbtn,"BOTTOMLEFT",0,0)
        stripe:Hide()
        pbtn.accentStripe = stripe

        local icon=pbtn:CreateTexture(nil,"ARTWORK")
        icon:SetSize(SIDEBAR_BUTTON_ICON, SIDEBAR_BUTTON_ICON); icon:SetPoint("LEFT",10,0)
        if plugin.icon then
            SetSidebarIconTexture(icon, plugin.icon, false)
        end
        icon:SetAlpha(0.78)  -- inactive: dim artwork without color-tinting

        local lbl=pbtn:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        lbl:SetPoint("LEFT",52,0); lbl:SetPoint("RIGHT",-8,0)
        lbl:SetJustifyH("LEFT"); lbl:SetText(plugin.label)
        lbl:SetTextColor(unpack(AltStable.C.TEXT_DIM))
        pbtn.lbl=lbl; pbtn.icon=icon

        pbtn:SetScript("OnClick",function()
            for _, b in ipairs(sidebarBtns) do
                b:SetBackdropColor(
                    AltStable.C.BG_BTN_IDLE[1], AltStable.C.BG_BTN_IDLE[2],
                    AltStable.C.BG_BTN_IDLE[3], AltStable.C.BG_BTN_IDLE[4])
                if b.lbl then b.lbl:SetTextColor(unpack(AltStable.C.TEXT_DIM)) end
                if b.accentStripe then b.accentStripe:Hide() end
                if b.icon then b.icon:SetAlpha(0.78) end
            end
            pbtn:SetBackdropColor(
                AltStable.C.BG_BTN_ACTIVE[1], AltStable.C.BG_BTN_ACTIVE[2],
                AltStable.C.BG_BTN_ACTIVE[3], AltStable.C.BG_BTN_ACTIVE[4])
            local ar, ag, ab = AltStable.GetAccentRGB()
            stripe:SetColorTexture(ar, ag, ab, 1); stripe:Show()
            lbl:SetTextColor(ar, ag, ab)
            icon:SetAlpha(1.0)
            if activeSection._isPlugin and activeSection.OnDeactivate then
                activeSection.OnDeactivate(frame)
            end
            activeSection = plugin
            plugin.OnActivate(frame)
        end)
        pbtn:SetScript("OnEnter",function()
            if activeSection.id~=plugin.id then
                pbtn:SetBackdropColor(
                    AltStable.C.BG_BTN_HOVER[1], AltStable.C.BG_BTN_HOVER[2],
                    AltStable.C.BG_BTN_HOVER[3], AltStable.C.BG_BTN_HOVER[4])
                lbl:SetTextColor(unpack(AltStable.C.TEXT_BRIGHT))
                icon:SetAlpha(0.85)
            end
        end)
        pbtn:SetScript("OnLeave",function()
            if activeSection.id~=plugin.id then
                pbtn:SetBackdropColor(
                    AltStable.C.BG_BTN_IDLE[1], AltStable.C.BG_BTN_IDLE[2],
                    AltStable.C.BG_BTN_IDLE[3], AltStable.C.BG_BTN_IDLE[4])
                lbl:SetTextColor(unpack(AltStable.C.TEXT_DIM))
                icon:SetAlpha(0.78)
            end
        end)

        table.insert(sidebarBtns,pbtn)
        sidebar._pluginBtnY = sidebar._pluginBtnY - SIDEBAR_BUTTON_STEP
    end

    -- Render any plugins already registered before the frame was built
    for _, plugin in ipairs(AltStable.plugins) do
        MakePluginButton(plugin)
    end

    -- Expose so late-registering plugins (loaded after SheetUI) get a button
    AltStable.AddPluginButton = MakePluginButton

    --------------------------------------------------------
    -- Built-in Options section
    -- Shown as a plugin-style section in the sidebar.
    -- Fully self-contained — theme/scale callbacks never
    -- call SwitchSection or re-enter ApplyTheme.
    --------------------------------------------------------

    -- Options content: sized to fit inside the content area
    -- optionsPanel is the visible container; optionsFrame is the scrolling content
    -- inside it and stays the parent for every control built below.
    --
    -- The content is taller than the panel at the default window size and grows with
    -- plugin and sync-peer rows, so without a scroll frame the lower controls (Sync
    -- Peers, Toast, Mail) are simply unreachable — there is no way to scroll to them
    -- and the window cannot be made tall enough.
    local optionsPanel = CreateFrame("Frame", nil, frame)
    optionsPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDEBAR_WIDTH + 1, -TITLE_H)
    optionsPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 1)
    optionsPanel:Hide()

    -- Background
    local optBG = optionsPanel:CreateTexture(nil, "BACKGROUND")
    optBG:SetAllPoints()
    optBG:SetColorTexture(unpack(AltStable.C.BG_MAIN))

    local optionsScroll = CreateFrame("ScrollFrame", nil, optionsPanel, "UIPanelScrollFrameTemplate")
    optionsScroll:SetPoint("TOPLEFT", optionsPanel, "TOPLEFT", 0, 0)
    optionsScroll:SetPoint("BOTTOMRIGHT", optionsPanel, "BOTTOMRIGHT", -26, 0)  -- room for the scrollbar

    local optionsFrame = CreateFrame("Frame", nil, optionsScroll)
    optionsFrame:SetSize(1, 1)
    optionsScroll:SetScrollChild(optionsFrame)
    -- Keep the content as wide as the viewport so the panel reflows on resize.
    optionsScroll:SetScript("OnSizeChanged", function(self, w)
        if w and w > 0 then optionsFrame:SetWidth(w) end
    end)

    -- ── Layout ──────────────────────────────────────────────
    -- We build everything at fixed offsets from TOPLEFT so
    -- nothing can overflow or go off-screen.
    local P = 18   -- left/right padding inside the options panel
    local Y = -12  -- current Y cursor (negative = down from top)

    local function MakeLabel(text, fontObj, yExtra)
        local fs = optionsFrame:CreateFontString(nil, "OVERLAY", fontObj or "GameFontNormal")
        fs:SetPoint("TOPLEFT", P, Y + (yExtra or 0))
        fs:SetText(text)
        return fs
    end

    -- Title
    local optTitle = MakeLabel("Options", "GameFontNormal")
    local function SyncTitleColor()
        local r, g, b = AltStable.GetAccentRGB()
        optTitle:SetTextColor(r, g, b)
    end
    SyncTitleColor()
    AltStable.RegisterThemeCallback(SyncTitleColor)
    Y = Y - 22

    -- Thin divider
    local optDiv1 = optionsFrame:CreateTexture(nil, "ARTWORK")
    optDiv1:SetHeight(1)
    optDiv1:SetPoint("TOPLEFT",  optionsFrame, "TOPLEFT",  0,     Y)
    optDiv1:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", 0,     Y)
    optDiv1:SetColorTexture(unpack(AltStable.C.SEP))
    Y = Y - 16

    -- ── Appearance section ────────────────────────────────
    local optSectionHdr = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optSectionHdr:SetPoint("TOPLEFT", P, Y)
    optSectionHdr:SetText("APPEARANCE")
    optSectionHdr:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    Y = Y - 20

    -- Theme row
    local optThemeLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    optThemeLabel:SetPoint("TOPLEFT", P, Y)
    optThemeLabel:SetText("Theme")
    optThemeLabel:SetTextColor(unpack(AltStable.C.TEXT_NORM))

    local BTNY = Y + 1   -- vertically aligned with label text
    local BTN_W, BTN_H = 72, 22

    local optDarkBtn = CreateFrame("Button", nil, optionsFrame, "BackdropTemplate")
    optDarkBtn:SetSize(BTN_W, BTN_H)
    optDarkBtn:SetPoint("TOPLEFT", P + 60, BTNY)
    AltStable.ApplyBackdrop(optDarkBtn, 0.12, 0.12, 0.12, 1)
    local optDarkLbl = optDarkBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optDarkLbl:SetAllPoints(); optDarkLbl:SetJustifyH("CENTER"); optDarkLbl:SetText("Dark")

    local optClassBtn = CreateFrame("Button", nil, optionsFrame, "BackdropTemplate")
    optClassBtn:SetSize(BTN_W, BTN_H)
    optClassBtn:SetPoint("LEFT", optDarkBtn, "RIGHT", 8, 0)
    AltStable.ApplyBackdrop(optClassBtn, 0.12, 0.12, 0.12, 1)
    local optClassLbl = optClassBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optClassLbl:SetAllPoints(); optClassLbl:SetJustifyH("CENTER"); optClassLbl:SetText("Class")

    -- Theme hint text (to right of buttons)
    local optThemeHint = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optThemeHint:SetPoint("LEFT", optClassBtn, "RIGHT", 14, 0)
    optThemeHint:SetPoint("RIGHT", optionsFrame, "RIGHT", -P, 0)
    optThemeHint:SetJustifyH("LEFT"); optThemeHint:SetWordWrap(true)
    optThemeHint:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    optThemeHint:SetText("Class uses current player class color as accent.")

    -- Refresh theme button highlight (no callbacks, no side effects)
    -- Must NOT call ApplyTheme or SwitchSection
    -- The selected theme gets a persistent pressed state: accent-filled
    -- background + accent border + accent label. Text color alone was too
    -- subtle to read as "active" at a glance (issue #5).
    local function SetThemeBtnState(btn, lbl, active)
        local ar, ag, ab = AltStable.GetAccentRGB()
        if active then
            btn:SetBackdropColor(
                AltStable.C.BG_BTN_ACTIVE[1], AltStable.C.BG_BTN_ACTIVE[2],
                AltStable.C.BG_BTN_ACTIVE[3], AltStable.C.BG_BTN_ACTIVE[4])
            btn:SetBackdropBorderColor(ar, ag, ab, 1)
            lbl:SetTextColor(ar, ag, ab)
        else
            btn:SetBackdropColor(0.12, 0.12, 0.12, 1)
            btn:SetBackdropBorderColor(0, 0, 0, 1)
            lbl:SetTextColor(unpack(AltStable.C.TEXT_NORM))
        end
    end
    local function RefreshThemeBtns()
        local cur = AltStableConfig and AltStableConfig.theme or "dark"
        SetThemeBtnState(optDarkBtn,  optDarkLbl,  cur == "dark")
        SetThemeBtnState(optClassBtn, optClassLbl, cur ~= "dark")
    end
    -- Sync when accent changes (sidebar callback won't call SwitchSection)
    AltStable.RegisterThemeCallback(function()
        if optionsPanel:IsShown() then RefreshThemeBtns() end
    end)

    optDarkBtn:SetScript("OnClick", function()
        AltStableConfig = AltStableConfig or {}
        AltStable.SetConfigValue("theme", "dark")
        RefreshThemeBtns()
        AltStable.ApplyTheme()
    end)
    optClassBtn:SetScript("OnClick", function()
        AltStableConfig = AltStableConfig or {}
        AltStable.SetConfigValue("theme", "class")
        RefreshThemeBtns()
        AltStable.ApplyTheme()
    end)

    Y = Y - 34

    -- ── Scale row ─────────────────────────────────────────
    -- Layout target:
    --   Scale       0.75 ──────●────── 1.25      Reset
    --                          1.00
    --
    -- The slider's template-provided Low/High font strings are anchored to
    -- the slider's bottom-left / bottom-right corners. We add a matching
    -- "1.00" mid-tick anchored to the bottom-center so all three ticks live
    -- on the same baseline. The current numeric value is shown via tooltip
    -- on the slider, not as a floating label that collides with .Low at
    -- smaller UI scales.
    local optScaleLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    optScaleLabel:SetPoint("TOPLEFT", P, Y)
    optScaleLabel:SetText("Scale")
    optScaleLabel:SetTextColor(unpack(AltStable.C.TEXT_NORM))

    local optScaleSlider = CreateFrame("Slider", nil, optionsFrame, "OptionsSliderTemplate")
    optScaleSlider:SetPoint("TOPLEFT", P + 60, Y + 4)
    optScaleSlider:SetWidth(280); optScaleSlider:SetHeight(16)
    optScaleSlider:SetMinMaxValues(0.75, 1.25)
    optScaleSlider:SetValueStep(0.05)
    -- NOTE: SetObeyStepOnDrag does NOT exist in TBC Classic 2.5.x — omitted.

    if optScaleSlider.Low  then optScaleSlider.Low:SetText("0.75")  end
    if optScaleSlider.High then optScaleSlider.High:SetText("1.25") end

    -- 1.00 mid-tick on the same baseline as Low/High
    local optScaleMid = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optScaleMid:SetPoint("TOP", optScaleSlider, "BOTTOM", 0, 2)
    optScaleMid:SetText("1.00")
    optScaleMid:SetTextColor(unpack(AltStable.C.TEXT_DIM))

    local optScaleReset = CreateFrame("Button", nil, optionsFrame, "BackdropTemplate")
    optScaleReset:SetSize(58, 20)
    optScaleReset:SetPoint("LEFT", optScaleSlider, "RIGHT", 16, 0)
    AltStable.ApplyBackdrop(optScaleReset, 0.12, 0.12, 0.12, 1)
    local optScaleResetLbl = optScaleReset:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optScaleResetLbl:SetAllPoints(); optScaleResetLbl:SetJustifyH("CENTER"); optScaleResetLbl:SetText("Reset")

    -- Tooltip showing the live scale value (replaces the old floating label)
    optScaleSlider:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(string.format("Scale: %.2f", self:GetValue()), 1, 1, 1)
        GameTooltip:Show()
    end)
    optScaleSlider:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Flag to prevent recursive firing when we set value programmatically
    local optSliderUpdating = false
    optScaleSlider:SetScript("OnValueChanged", function(self, value)
        if optSliderUpdating then return end
        local rounded = math.floor(value / 0.05 + 0.5) * 0.05
        rounded = math.max(0.75, math.min(1.25, rounded))
        AltStable.SetScale(rounded)
        if GameTooltip:IsOwned(self) then
            GameTooltip:SetText(string.format("Scale: %.2f", rounded), 1, 1, 1)
        end
    end)
    optScaleReset:SetScript("OnClick", function()
        optSliderUpdating = true
        optScaleSlider:SetValue(1.0)
        optSliderUpdating = false
        AltStable.SetScale(1.0)
    end)

    Y = Y - 44   -- a bit more room for the mid-tick baseline below the slider

    -- ── Roster section (developer-only) ─────────────────────
    -- "Preview debug mode" is a developer diagnostic (live model vs static
    -- render vs card, plus the Roster debug text window) that normal users
    -- should never see. Gate the whole block behind a dev flag; enable with
    --   /run AltStableConfig.devMode = true; ReloadUI()
    -- When the flag is off nothing renders and Y is untouched, so the options
    -- below simply move up. Issue #4.
    if AltStableConfig and AltStableConfig.devMode then
        local optCharsHdr = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        optCharsHdr:SetPoint("TOPLEFT", P, Y)
        optCharsHdr:SetText("ROSTER (DEV)")
        optCharsHdr:SetTextColor(unpack(AltStable.C.TEXT_DIM))
        Y = Y - 20

        optModelDebugCheck = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
        optModelDebugCheck:SetSize(18, 18)
        optModelDebugCheck:SetPoint("TOPLEFT", P - 2, Y + 2)
        optModelDebugCheck:SetChecked(AltStableRosterDB and AltStableRosterDB._debugModelStatus and true or false)
        optModelDebugCheck:SetScript("OnClick", function(self)
            AltStableRosterDB = AltStableRosterDB or AltStableAltsDB or {}
            AltStableAltsDB = AltStableRosterDB
            AltStableRosterDB._debugModelStatus = self:GetChecked() and true or false
            if AltStable.RefreshSheet then
                AltStable.RefreshSheet()
            end
        end)

        local optModelDebugLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        optModelDebugLabel:SetPoint("LEFT", optModelDebugCheck, "RIGHT", 4, 0)
        optModelDebugLabel:SetText("Preview debug mode (AltStable Roster)")
        optModelDebugLabel:SetTextColor(unpack(AltStable.C.TEXT_NORM))

        local optModelDebugHint = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        optModelDebugHint:SetPoint("TOPLEFT", P, Y - 16)
        optModelDebugHint:SetPoint("RIGHT", optionsFrame, "RIGHT", -P, 0)
        optModelDebugHint:SetJustifyH("LEFT")
        optModelDebugHint:SetWordWrap(true)
        optModelDebugHint:SetTextColor(unpack(AltStable.C.TEXT_DIM))
        optModelDebugHint:SetText("Shows preview mode diagnostics (live model vs static render vs card) and opens the Roster debug text window.")

        Y = Y - 42
    end

    -- Shared builder for the checkbox rows below (plugins, presentation,
    -- toasts). Defined here so the Plugins section can use it too.
    local function MakeOptCheckRow(savedKey, label, anchorY, onClick, getter)
        local cb = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
        cb:SetSize(18, 18)
        cb:SetPoint("TOPLEFT", P - 2, anchorY + 2)
        cb._getter = getter or function()
            return AltStableConfig and AltStableConfig[savedKey] ~= false
        end
        cb:SetScript("OnClick", function(self)
            AltStableConfig = AltStableConfig or {}
            local checked = self:GetChecked() and true or false
            if onClick then
                onClick(checked)
            else
                AltStable.SetConfigValue(savedKey, checked)
            end
        end)
        local lbl = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
        lbl:SetText(label)
        lbl:SetTextColor(unpack(AltStable.C.TEXT_NORM))
        return cb
    end

    -- ── Plugins section ────────────────────────────────────
    -- Plugins are LoadOnDemand addons; toggling one loads it immediately
    -- (enable) or persists the choice (disable, next /reload) via
    -- AltStable.SetPluginEnabled.
    --
    -- The whole section is skipped when no plugins are registered, otherwise
    -- the heading and hint render above empty space. LOD_PLUGINS is empty
    -- until Warband (#9/#10) and Instances (#11) are ported.
    local optPluginChecks = {}
    if #(AltStable.LOD_PLUGINS or {}) > 0 then
        local optPluginsHdr = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        optPluginsHdr:SetPoint("TOPLEFT", P, Y)
        optPluginsHdr:SetText("PLUGINS")
        optPluginsHdr:SetTextColor(unpack(AltStable.C.TEXT_DIM))
        Y = Y - 20

        for _, p in ipairs(AltStable.LOD_PLUGINS) do
            local key = p.key
            optPluginChecks[key] = MakeOptCheckRow(nil, p.label, Y,
                function(checked)
                    if AltStable.SetPluginEnabled then
                        AltStable.SetPluginEnabled(key, checked)
                    end
                end,
                function()
                    return AltStable.IsPluginEnabled and AltStable.IsPluginEnabled(key)
                end)
            Y = Y - 22
        end

        local optPluginsHint = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        optPluginsHint:SetPoint("TOPLEFT", P, Y - 2)
        optPluginsHint:SetPoint("RIGHT", optionsFrame, "RIGHT", -P, 0)
        optPluginsHint:SetJustifyH("LEFT")
        optPluginsHint:SetWordWrap(true)
        optPluginsHint:SetTextColor(unpack(AltStable.C.TEXT_DIM))
        -- Not "Both": the count is whatever is registered.
        optPluginsHint:SetText("Enabling loads the tab immediately; disabling takes effect after /reload. (They must also stay enabled in the game's AddOns list.)")
        Y = Y - 34
    end

    -- ── Presentation section ──────────────────────────────
    -- Camera presentation, frame shift, continuous orbit, open animation,
    -- and the minimap-button toggle all live here so users find them in
    -- the same place they configure scale/theme.
    local optPresHdr = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optPresHdr:SetPoint("TOPLEFT", P, Y)
    optPresHdr:SetText("PRESENTATION")
    optPresHdr:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    Y = Y - 20

    local optCameraCheck = MakeOptCheckRow("enableWorldCameraPresentation",
        "World camera presentation when AltStable opens", Y)
    Y = Y - 22

    local optOrbitCheck = MakeOptCheckRow("worldCameraContinuousOrbit",
        "Keep the world slowly rotating around your character while open", Y)
    Y = Y - 22

    local optSaluteCheck = MakeOptCheckRow("enableWorldCameraSalute",
        "Salute after the camera finishes moving (visible emote)", Y)
    Y = Y - 22

    local optOpenAnimCheck = MakeOptCheckRow("enableOpenAnimation",
        "Play fade-in animation when AltStable opens", Y)
    Y = Y - 22

    local optMinimapCheck = MakeOptCheckRow(nil,
        "Show minimap button (left-click toggle, right-click options, drag to move)", Y,
        function(checked)
            if AltStable.SetMinimapButtonShown then
                AltStable.SetMinimapButtonShown(checked)
            end
        end,
        function()
            return not (AltStableConfig and AltStableConfig.minimapButton
                        and AltStableConfig.minimapButton.hide)
        end)
    Y = Y - 30

    local optRememberPositionCheck = MakeOptCheckRow("rememberWindowPosition",
        "Remember AltStable window position", Y,
        function(checked)
            AltStable.SetConfigValue("rememberWindowPosition", checked)
            if checked then
                SaveWindowPosition()
            else
                AltStable.SetConfigValue("windowPosition", nil)
            end
        end)

    local optResetPosition = CreateFrame("Button", nil, optionsFrame, "BackdropTemplate")
    optResetPosition:SetSize(92, 20)
    optResetPosition:SetPoint("LEFT", optRememberPositionCheck, "RIGHT", 260, 0)
    AltStable.ApplyBackdrop(optResetPosition, 0.12, 0.12, 0.12, 1)
    local optResetPositionLbl = optResetPosition:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optResetPositionLbl:SetAllPoints()
    optResetPositionLbl:SetJustifyH("CENTER")
    optResetPositionLbl:SetText("Reset Position")
    optResetPosition:SetScript("OnClick", function()
        ResetWindowPosition()
    end)
    optResetPosition:SetScript("OnEnter", function()
        optResetPosition:SetBackdropColor(0.18, 0.18, 0.18, 1)
    end)
    optResetPosition:SetScript("OnLeave", function()
        optResetPosition:SetBackdropColor(0.12, 0.12, 0.12, 1)
    end)
    Y = Y - 30

    -- ── Account & Sync section ────────────────────────────
    local optSyncHdr = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optSyncHdr:SetPoint("TOPLEFT", P, Y)
    optSyncHdr:SetText("ACCOUNT & SYNC")
    optSyncHdr:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    Y = Y - 22

    -- Account number row
    local optAcctLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    optAcctLabel:SetPoint("TOPLEFT", P, Y)
    optAcctLabel:SetText("Account #")
    optAcctLabel:SetTextColor(unpack(AltStable.C.TEXT_NORM))

    local optAcctBox = CreateFrame("EditBox", "AltStableOptAcctBox", optionsFrame, "InputBoxTemplate")
    optAcctBox:SetSize(60, 22)
    optAcctBox:SetPoint("TOPLEFT", P + 80, Y + 4)
    optAcctBox:SetAutoFocus(false)
    optAcctBox:SetNumeric(true)
    optAcctBox:SetMaxLetters(3)
    optAcctBox:SetScript("OnEnterPressed", function(self)
        local v = tonumber(self:GetText())
        AltStableConfig = AltStableConfig or {}
        AltStable.SetConfigValue("accountNumber", v or "")
        self:ClearFocus()
    end)
    optAcctBox:SetScript("OnEscapePressed", function(self)
        self:SetText(tostring(AltStableConfig.accountNumber or ""))
        self:ClearFocus()
    end)

    local optAcctHint = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optAcctHint:SetPoint("LEFT", optAcctBox, "RIGHT", 12, 0)
    optAcctHint:SetPoint("RIGHT", optionsFrame, "RIGHT", -P, 0)
    optAcctHint:SetJustifyH("LEFT")
    optAcctHint:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    optAcctHint:SetText("Tags this client's data on next scan/sync.")
    Y = Y - 30

    local optSendAllCheck = MakeOptCheckRow("sendAllAccounts",
        "Share all known accounts (uncheck to share only this account's data)", Y)
    Y = Y - 24

    -- ── Whitelist (sync peers) ────────────────────────────
    local optWlHdr = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optWlHdr:SetPoint("TOPLEFT", P, Y)
    optWlHdr:SetText("SYNC PEERS")
    optWlHdr:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    Y = Y - 18

    local optWlHint = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optWlHint:SetPoint("TOPLEFT", P, Y)
    optWlHint:SetPoint("RIGHT", optionsFrame, "RIGHT", -P, 0)
    optWlHint:SetJustifyH("LEFT"); optWlHint:SetWordWrap(true)
    optWlHint:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    optWlHint:SetText("Whisper sync targets. Add character names (with realm if needed: Name-Realm).")
    Y = Y - 24

    -- Add box + button
    local optWlAddBox = CreateFrame("EditBox", "AltStableOptWlAddBox", optionsFrame, "InputBoxTemplate")
    optWlAddBox:SetSize(180, 22)
    optWlAddBox:SetPoint("TOPLEFT", P + 4, Y + 4)
    optWlAddBox:SetAutoFocus(false)
    optWlAddBox:SetMaxLetters(48)

    local optWlAddBtn = CreateFrame("Button", nil, optionsFrame, "BackdropTemplate")
    optWlAddBtn:SetSize(60, 22)
    optWlAddBtn:SetPoint("LEFT", optWlAddBox, "RIGHT", 8, 0)
    AltStable.ApplyBackdrop(optWlAddBtn, 0.12, 0.12, 0.12, 1)
    local optWlAddLbl = optWlAddBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optWlAddLbl:SetAllPoints(); optWlAddLbl:SetJustifyH("CENTER"); optWlAddLbl:SetText("Add")

    -- List rows (compact). We render one row per slot up to LIST_VISIBLE; a
    -- name list this small almost never needs scrolling.
    local OPT_WL_ROWS = 5
    local optWlRows = {}
    Y = Y - 30
    for i = 1, OPT_WL_ROWS do
        local row = CreateFrame("Frame", nil, optionsFrame)
        row:SetSize(360, 18)
        row:SetPoint("TOPLEFT", P + 4, Y - (i - 1) * 18)

        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", 0, 0); lbl:SetJustifyH("LEFT")
        lbl:SetTextColor(unpack(AltStable.C.TEXT_NORM))
        row.label = lbl

        local rm = CreateFrame("Button", nil, row, "BackdropTemplate")
        rm:SetSize(18, 16)
        rm:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
        AltStable.ApplyBackdrop(rm, 0.18, 0.05, 0.05, 1)
        local rmLbl = rm:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        rmLbl:SetAllPoints(); rmLbl:SetJustifyH("CENTER"); rmLbl:SetText("|cffdddddd×|r")
        row.removeBtn = rm
        row:Hide()
        optWlRows[i] = row
    end
    Y = Y - (OPT_WL_ROWS * 18) - 6

    local function OptRefreshWhitelist()
        AltStableConfig = AltStableConfig or {}
        AltStableConfig.whitelist = AltStableConfig.whitelist or {}
        local wl = AltStableConfig.whitelist
        for i, row in ipairs(optWlRows) do
            local name = wl[i]
            if name then
                row.label:SetText(name)
                row.removeBtn:SetScript("OnClick", function()
                    if AltStable.RemoveFromWhitelist then
                        AltStable.RemoveFromWhitelist(name)
                        OptRefreshWhitelist()
                    end
                end)
                row:Show()
            else
                row:Hide()
            end
        end
    end

    optWlAddBtn:SetScript("OnClick", function()
        local name = (optWlAddBox:GetText() or ""):match("^%s*(.-)%s*$")
        if name and name ~= "" and AltStable.AddToWhitelist then
            if AltStable.AddToWhitelist(name) then
                optWlAddBox:SetText("")
                OptRefreshWhitelist()
            end
        end
    end)
    optWlAddBox:SetScript("OnEnterPressed", function() optWlAddBtn:Click() end)

    -- ── Toasts section ────────────────────────────────────
    local optToastHdr = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optToastHdr:SetPoint("TOPLEFT", P, Y)
    optToastHdr:SetText("TOASTS")
    optToastHdr:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    Y = Y - 22

    local optToastsCheck = MakeOptCheckRow("toastsEnabled",
        "Show profession toasts", Y)
    Y = Y - 22

    local PROFESSION_KEYS = { "Tailoring", "Alchemy" }
    local optProfChecks = {}
    for _, profKey in ipairs(PROFESSION_KEYS) do
        local cb = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
        cb:SetSize(16, 16)
        cb:SetPoint("TOPLEFT", P + 18, Y + 2)
        cb:SetScript("OnClick", function(self)
            AltStableConfig = AltStableConfig or {}
            AltStableConfig.toastProfessions = AltStableConfig.toastProfessions or {}
            AltStableConfig.toastProfessions[profKey] = self:GetChecked() and true or false
            AltStable.OnConfigChanged("toastProfessions")
        end)
        local lbl = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
        lbl:SetText(profKey)
        lbl:SetTextColor(unpack(AltStable.C.TEXT_DIM))
        optProfChecks[profKey] = cb
        Y = Y - 18
    end

    Y = Y - 12

    -- ── Mail section ──────────────────────────────────────
    local optMailHdr = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optMailHdr:SetPoint("TOPLEFT", P, Y)
    optMailHdr:SetText("MAIL")
    optMailHdr:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    Y = Y - 22

    local optMailAlertsCheck = MakeOptCheckRow("mailAlertsEnabled",
        "Warn at login about mail expiring soon", Y)
    Y = Y - 22

    Y = Y - 12

    -- ── Helper text ───────────────────────────────────────
    local optHint = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optHint:SetPoint("TOPLEFT", P, Y)
    optHint:SetPoint("RIGHT", optionsFrame, "RIGHT", -P, 0)
    optHint:SetJustifyH("LEFT"); optHint:SetWordWrap(true)
    optHint:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    optHint:SetText("Class theme uses the current player class color as the UI accent. "
        .."Character rows still use each character's own class color.")

    -- Content height is known once the layout cursor has run; the scroll range
    -- derives from it. Extra padding covers the wrapped hint text below.
    optionsFrame:SetHeight(math.abs(Y) + 60)

    -- OnShow: safely refresh all controls from saved config.
    -- Bound to the panel, not the content: the scroll child is always shown, so an
    -- OnShow there would never fire when Options is opened.
    optionsPanel:SetScript("OnShow", function()
        AltStableConfig = AltStableConfig or {}
        if AltStable.EnsureConfigDefaults then
            AltStable.EnsureConfigDefaults()
        end
        local scale = AltStableConfig.scale or 1.0
        optSliderUpdating = true
        optScaleSlider:SetValue(scale)
        optSliderUpdating = false
        local rosterDebug = (AltStableRosterDB and AltStableRosterDB._debugModelStatus)
            or (AltStableAltsDB and AltStableAltsDB._debugModelStatus)
        if optModelDebugCheck then
            optModelDebugCheck:SetChecked(rosterDebug and true or false)
        end
        for key, cb in pairs(optPluginChecks) do
            cb:SetChecked(cb._getter())
        end
        optCameraCheck:SetChecked(optCameraCheck._getter())
        optOrbitCheck:SetChecked(optOrbitCheck._getter())
        optSaluteCheck:SetChecked(optSaluteCheck._getter())
        optOpenAnimCheck:SetChecked(optOpenAnimCheck._getter())
        optMinimapCheck:SetChecked(optMinimapCheck._getter())
        optRememberPositionCheck:SetChecked(optRememberPositionCheck._getter())
        optAcctBox:SetText(tostring(AltStableConfig.accountNumber or ""))
        optSendAllCheck:SetChecked(AltStableConfig.sendAllAccounts and true or false)
        optToastsCheck:SetChecked(AltStableConfig.toastsEnabled ~= false)
        optMailAlertsCheck:SetChecked(AltStableConfig.mailAlertsEnabled ~= false)
        AltStableConfig.toastProfessions = AltStableConfig.toastProfessions or {}
        for profKey, cb in pairs(optProfChecks) do
            cb:SetChecked(AltStableConfig.toastProfessions[profKey] ~= false)
        end
        OptRefreshWhitelist()
        RefreshThemeBtns()
    end)

    -- Add the Options sidebar button
    local optSect
    do
        optSect = {
            id = "options",
            label = "Options",
            icon  = (AltStable.MEDIA_PATH or "Interface\\AddOns\\AltStable\\Media\\")
                    .. "Icons\\options.tga",
            _isPlugin  = true,
            preferW = 820,
            preferH = 760,
            OnActivate = function(f)
                f.bodyScroll:Hide(); f.frozenScroll:Hide()
                f.headerScroll:Hide(); f.frozenHeader:Hide()
                f.hScrollBar:Hide(); f.totalsBar:Hide()
                optionsPanel:Show()
                ResizeFrame(820, 760)
            end,
            OnDeactivate = function(f)
                optionsPanel:Hide()
                f.totalsBar:Show()
            end,
        }
        MakePluginButton(optSect)
    end
    -- Stored on AltStable so AltStable.OpenConfig() (and the minimap
    -- right-click) can switch to the Options section without re-introducing
    -- the standalone config popup.
    AltStable._SwitchToOptions = function()
        if optSect then SwitchSection(optSect) end
    end

    --------------------------------------------------------
    -- Totals bar
    --------------------------------------------------------

    totalsBar=CreateFrame("Frame",nil,frame,"BackdropTemplate")
    totalsBar:SetPoint("BOTTOMLEFT",frame,"BOTTOMLEFT",SIDEBAR_WIDTH,1)
    totalsBar:SetPoint("BOTTOMRIGHT",frame,"BOTTOMRIGHT",-1,1)
    totalsBar:SetHeight(22)
    AltStable.ApplyBGOnly(totalsBar,
        AltStable.C.BG_FOOTER[1], AltStable.C.BG_FOOTER[2],
        AltStable.C.BG_FOOTER[3], AltStable.C.BG_FOOTER[4])
    -- top border line
    local totLine=frame:CreateTexture(nil,"OVERLAY"); totLine:SetHeight(1)
    totLine:SetPoint("BOTTOMLEFT",totalsBar,"TOPLEFT",0,0)
    totLine:SetPoint("BOTTOMRIGHT",totalsBar,"TOPRIGHT",0,0)
    totLine:SetColorTexture(unpack(AltStable.C.SEP))
    totalsBar.left=totalsBar:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    totalsBar.left:SetPoint("LEFT",10,0)
    totalsBar.left:SetTextColor(unpack(AltStable.C.TEXT_NORM))
    totalsBar.mid=totalsBar:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    totalsBar.mid:SetPoint("CENTER",totalsBar,"CENTER",0,0)
    totalsBar.mid:SetJustifyH("CENTER")
    totalsBar.mid:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    totalsBar.right=totalsBar:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    totalsBar.right:SetPoint("RIGHT",-10,0); totalsBar.right:SetJustifyH("RIGHT")
    totalsBar.right:SetTextColor(unpack(AltStable.C.TEXT_NORM))

    --------------------------------------------------------
    -- Frozen header (Name column)
    --------------------------------------------------------

    frozenHeader=CreateFrame("Frame",nil,frame)
    frozenHeader:SetPoint("TOPLEFT",frame,"TOPLEFT",SIDEBAR_WIDTH,-HEADER_TOP_Y)
    frozenHeader:SetSize(FROZEN_WIDTH,HEADER_HEIGHT)
    local fhBg=frozenHeader:CreateTexture(nil,"BACKGROUND")
    fhBg:SetAllPoints()
    fhBg:SetColorTexture(
        AltStable.C.BG_HEADER[1], AltStable.C.BG_HEADER[2],
        AltStable.C.BG_HEADER[3], AltStable.C.BG_HEADER[4])
    local fhLine=frozenHeader:CreateTexture(nil,"OVERLAY")
    fhLine:SetHeight(1); fhLine:SetPoint("BOTTOMLEFT"); fhLine:SetPoint("BOTTOMRIGHT")
    fhLine:SetColorTexture(unpack(AltStable.C.SEP))

    -- Name header button (persistent)
    do
        local col=AltStable.Columns[1]
        local btn=CreateFrame("Button",nil,frozenHeader)
        btn:SetPoint("LEFT",10,0); btn:SetSize(col.width,currentHeaderHeight); btn.field=col.field
        local lbl=btn:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        lbl:SetPoint("LEFT",2,0); lbl:SetPoint("RIGHT",-10,0)
        lbl:SetJustifyH("LEFT"); lbl:SetJustifyV("MIDDLE"); lbl:SetText(col.label); btn.label=lbl
        local arrow=btn:CreateTexture(nil,"OVERLAY")
        arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
        arrow:SetSize(8,8); arrow:SetPoint("RIGHT",btn,"RIGHT",-1,0); arrow:Hide(); btn.arrow=arrow
        btn:SetScript("OnClick",function()
            if sortColumn==col.field then sortAsc=not sortAsc
            else sortColumn=col.field; sortAsc=false end
            UpdateSortArrows(); BuildDisplayList(); UpdateScroll(); UpdateRows(); UpdateTotalsBar()
        end)
        btn:SetScript("OnEnter",function()
            local ar,ag,ab = AltStable.GetAccentRGB()
            lbl:SetTextColor(ar,ag,ab)
        end)
        btn:SetScript("OnLeave",function()
            if sortColumn~=col.field then lbl:SetTextColor(unpack(AltStable.C.TEXT_NORM)) end
        end)
        table.insert(headerButtons,btn)
    end

    --------------------------------------------------------
    -- Scrollable header
    --------------------------------------------------------

    headerScroll=CreateFrame("ScrollFrame",nil,frame)
    headerScroll:SetPoint("TOPLEFT",frame,"TOPLEFT",SIDEBAR_WIDTH+FROZEN_WIDTH,-HEADER_TOP_Y)
    headerScroll:SetPoint("TOPRIGHT",frame,"TOPRIGHT",-20,-HEADER_TOP_Y)
    headerScroll:SetHeight(HEADER_HEIGHT)
    headerContent=CreateFrame("Frame",nil,headerScroll)
    headerContent:SetSize(GetScrollableWidth(),HEADER_HEIGHT)
    headerScroll:SetScrollChild(headerContent)
    local hBg=headerContent:CreateTexture(nil,"BACKGROUND")
    hBg:SetAllPoints()
    hBg:SetColorTexture(
        AltStable.C.BG_HEADER[1], AltStable.C.BG_HEADER[2],
        AltStable.C.BG_HEADER[3], AltStable.C.BG_HEADER[4])
    local hLine=headerContent:CreateTexture(nil,"OVERLAY")
    hLine:SetHeight(1); hLine:SetPoint("BOTTOMLEFT"); hLine:SetPoint("BOTTOMRIGHT")
    hLine:SetColorTexture(unpack(AltStable.C.SEP))

    -- 1px vertical separator between frozen name col and scrollable header ONLY.
    -- Anchored to frozenHeader bounds so it never extends into the body area.
    local sep=frame:CreateTexture(nil,"OVERLAY"); sep:SetWidth(1)
    sep:SetPoint("TOPLEFT",   frozenHeader,"TOPLEFT",  0, 0)
    sep:SetPoint("BOTTOMLEFT",frozenHeader,"BOTTOMLEFT",0, 0)
    sep:SetColorTexture(unpack(AltStable.C.SEP))

    -- Sidebar right border (1px full-height, starts below title bar)
    local sbBorder=frame:CreateTexture(nil,"OVERLAY"); sbBorder:SetWidth(1)
    sbBorder:SetPoint("TOPLEFT",frame,"TOPLEFT",SIDEBAR_WIDTH,-TITLE_H)
    sbBorder:SetPoint("BOTTOMLEFT",frame,"BOTTOMLEFT",SIDEBAR_WIDTH,0)
    sbBorder:SetColorTexture(0, 0, 0, 1)

    --------------------------------------------------------
    -- Frozen body scroll
    --------------------------------------------------------

    frozenScroll=CreateFrame("ScrollFrame",nil,frame)
    frozenScroll:SetPoint("TOPLEFT",frame,"TOPLEFT",SIDEBAR_WIDTH,-BodyTopY())
    frozenScroll:SetPoint("BOTTOMLEFT",frame,"BOTTOMLEFT",SIDEBAR_WIDTH,36)
    frozenScroll:SetWidth(FROZEN_WIDTH); frozenScroll:SetClipsChildren(true)
    frozenBodyContent=CreateFrame("Frame",nil,frozenScroll)
    frozenBodyContent:SetSize(FROZEN_WIDTH,400)
    frozenScroll:SetScrollChild(frozenBodyContent)

    --------------------------------------------------------
    -- Body scroll
    --------------------------------------------------------

    bodyScroll=CreateFrame("ScrollFrame","AltStableBodyScroll",frame,"UIPanelScrollFrameTemplate")
    bodyScroll:SetPoint("TOPLEFT",frame,"TOPLEFT",SIDEBAR_WIDTH+FROZEN_WIDTH,-BodyTopY())
    bodyScroll:SetPoint("BOTTOMRIGHT",frame,"BOTTOMRIGHT",-10,36)
    bodyScroll:EnableMouseWheel(true); bodyScroll:SetClipsChildren(true)
    bodyContent=CreateFrame("Frame",nil,bodyScroll)
    bodyScroll:SetScrollChild(bodyContent)
    bodyScroll:SetScript("OnVerticalScroll",function(self,offset)
        self:SetVerticalScroll(offset); frozenScroll:SetVerticalScroll(offset); UpdateRows()
    end)

    --------------------------------------------------------
    -- Horizontal scrollbar
    --------------------------------------------------------

    hScrollBar=CreateFrame("Slider","AltStableHorizontalScroll",frame,"OptionsSliderTemplate")
    hScrollBar:SetOrientation("HORIZONTAL")
    hScrollBar:SetPoint("BOTTOMLEFT",frame,"BOTTOMLEFT",SIDEBAR_WIDTH+4,24)
    hScrollBar:SetPoint("BOTTOMRIGHT",frame,"BOTTOMRIGHT",-4,24)
    hScrollBar:SetHeight(10); hScrollBar:SetMinMaxValues(0,0); hScrollBar:SetValueStep(20)
    -- The OptionsSliderTemplate auto-creates "Low"/"High" font strings anchored
    -- to the slider corners. They're meaningless for a horizontal scroll
    -- position (the thumb itself shows where you are), and they were leaking
    -- into the totals bar area at smaller scales / wider sections. Kill them.
    if hScrollBar.Low  then hScrollBar.Low:Hide();  hScrollBar.Low:SetText("")  end
    if hScrollBar.High then hScrollBar.High:Hide(); hScrollBar.High:SetText("") end
    hScrollBar:SetScript("OnValueChanged",function(self,value)
        bodyScroll:SetHorizontalScroll(value); headerScroll:SetHorizontalScroll(value)
    end)

    --------------------------------------------------------
    -- Mouse wheel
    --------------------------------------------------------

    bodyScroll:SetScript("OnMouseWheel",function(self,delta)
        if IsShiftKeyDown() then
            local maxH=math.max(0,GetScrollableWidth()-(self:GetWidth()+20))
            local new=math.max(0,math.min(headerScroll:GetHorizontalScroll()-delta*40,maxH))
            headerScroll:SetHorizontalScroll(new); self:SetHorizontalScroll(new); hScrollBar:SetValue(new)
        else
            local contentH=#displayList*ROW_HEIGHT; local viewH=self:GetHeight()
            local maxScroll=math.max(0,contentH-viewH)
            if maxScroll==0 then return end
            local newOffset=math.max(0,math.min(self:GetVerticalScroll()-delta*40,maxScroll))
            if newOffset==self:GetVerticalScroll() then return end
            self:SetVerticalScroll(newOffset); frozenScroll:SetVerticalScroll(newOffset); UpdateRows()
        end
    end)

    -- Build initial headers and activate first section
    BuildHeaders()
    SwitchSection(SECTIONS[1])

    -- Re-apply accent colours whenever the user changes theme.
    -- We must NOT call SwitchSection here — if the active section is a
    -- plugin/Options, SwitchSection calls OnDeactivate which hides the
    -- active panel.  Instead, directly update only the accent-sensitive
    -- elements: sidebar button stripe/label colors and sort arrows.
    AltStable.RegisterThemeCallback(function()
        local ar, ag, ab = AltStable.GetAccentRGB()
        for _, btn in ipairs(sidebarBtns) do
            if btn.sectionId == activeSection.id then
                btn.lbl:SetTextColor(ar, ag, ab)
                if btn.accentStripe then
                    btn.accentStripe:SetColorTexture(ar, ag, ab, 1)
                end
                if btn.icon then btn.icon:SetAlpha(1.0) end
            else
                btn.lbl:SetTextColor(unpack(AltStable.C.TEXT_DIM))
                if btn.icon then btn.icon:SetAlpha(0.65) end
            end
        end
        UpdateSortArrows()
        UpdateTotalsBar()
    end)

    --------------------------------------------------------
    -- Expose key sub-frames on the main frame object so that
    -- plugins (e.g. AltStableProfessions) can hide/show the
    -- normal content area when they take over the display.
    --------------------------------------------------------
    frame.bodyScroll   = bodyScroll
    frame.frozenScroll = frozenScroll
    frame.headerScroll = headerScroll
    frame.frozenHeader = frozenHeader
    frame.hScrollBar   = hScrollBar
    frame.totalsBar    = totalsBar

    frame:Hide()
end

------------------------------------------------------------
-- Public API
------------------------------------------------------------

local function Refresh()
    BuildDisplayList()
    local needed=CountVisibleRows()
    EnsureRows(needed)
    UpdateScroll()
    UpdateRows()
    UpdateTotalsBar()
    -- Refresh fires whenever data changes (login, scan finish, alt added).
    -- Snap the frame so it grows/shrinks with the visible row count rather
    -- than leaving leftover dead space below the last row.
    ResizeFrameToContent()
end

function AltStable.ShowSheet()
    CreateFrameIfNeeded()
    if frame:IsShown() then frame:Hide(); return end
    -- Don't reset to FRAME_W/FRAME_H here — that was the bug that left an
    -- oversized container around the grid. Refresh() calls
    -- ResizeFrameToContent which sizes the frame to match the data exactly.
    frame:Show(); Refresh()
end

function AltStable.RefreshSheet()
    if frame and frame:IsShown() then Refresh() end
end

function AltStable.EnsureSheetVisible()
    CreateFrameIfNeeded()
    if not frame:IsShown() then frame:Show(); Refresh() end
end

function AltStable.ToggleRealm(realm)
    collapsed[realm]=not collapsed[realm]
    BuildDisplayList(); UpdateScroll(); UpdateRows(); UpdateTotalsBar()
    ResizeFrameToContent()
end
