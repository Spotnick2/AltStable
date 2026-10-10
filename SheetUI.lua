AltStable = AltStable or {}

------------------------------------------------------------
-- Layout constants
-- Tuned for ElvUI-style density: compact rows, tight header,
-- no wasted vertical space.
------------------------------------------------------------

local ROW_HEIGHT    = 22
local HEADER_HEIGHT = 28     -- compact; gear/skills/rep icon sections override to 32
-- The sidebar's width: full (icon + label) or compact (icon only, #150). A
-- variable, not a constant: everything beside the sidebar is anchored to its
-- right EDGE, or re-anchored from this on every layout pass, so collapsing it
-- moves the content with it. LAYOUT.SIDEBAR_WIDTH follows it for the plugins.
local SIDEBAR_FULL_W    = 230
local SIDEBAR_COMPACT_W = 56     -- the 36px icon at x=10, and the same on its right
local SIDEBAR_WIDTH = SIDEBAR_FULL_W
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
        headerHeight = 32,   -- 64 while a stacked-text label is shown (HeaderHeightFor)
        preferW = 999,
        preferH = 410,
        -- Faction columns are added per build: only those some character has
        -- met (AltStable.RepFieldsInUse), in the order of AltStable.REPUTATIONS.
        fields = { "class","race","level" },
        repFields = true,
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

-- field -> column definition. Built once: AltStable.Columns is complete when
-- this file loads (Columns.lua appends the factions at load, earlier in the
-- .toc) and nothing changes it afterwards.
local columnByField
local function ColumnFor(field)
    columnByField = columnByField or BuildFieldLookup()
    return columnByField[field]
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

-- Row pools keyed by section id so we reuse without SetParent(nil). A pool is
-- rebuilt when its section's columns change (AltStable.RowPoolFor).
local rowPools         = {}   -- rowPools[sectionId] = { rows={}, frozenRows={}, signature }

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
-- Characters whose money is UNREADABLE (secret, see Compat.lua). File scope,
-- like the totals above: BuildDisplayList counts them and UpdateTotalsBar reads
-- the count, and a local in the first would read as a nil global in the second.
local goldUnknown = 0
-- Characters the user has hidden (#21). Same file scope, same reason: counted
-- in BuildDisplayList, reported by UpdateTotalsBar.
local hiddenCount = 0

local FROZEN_WIDTH
local NAME_COL_WIDTH

local function ComputeFrozenWidth()
    NAME_COL_WIDTH = AltStable.Columns[1].width
    FROZEN_WIDTH   = 10 + NAME_COL_WIDTH + 6
end

------------------------------------------------------------
-- The camera showcase
--
-- LibShowcase-1.0 (..\LibShowcase, embedded like LibGlass: .pkgmeta external,
-- loaded by the TOC right after LibGlass). It is AltStable's own presentation,
-- extracted: the camera swings round to the character's front, pushes it left
-- of the sheet (test_cameraOverShoulder, with CameraKeepCharacterCentered and
-- CameraReduceUnexpectedMovement cleared - #25), optionally orbits, and hides
-- the game UI Alt+Z style with the sheet and GameTooltip lifted above it.
-- Every route out restores everything: close, Escape/Alt+Z, combat, logout,
-- zoning, and a crash (the capture rides in AltStableConfig and is put back at
-- the next login). Its docs/DESIGN.md has the guarantees.
--
-- What stays here is a thin adapter keeping AltStable's names: the options
-- still come from AltStableConfig (read at every open, as before), and the
-- callers - the sheet's OnShow/OnHide, CharacterMenu - are unchanged. The
-- camera is global, so the library has ONE owner at a time: if another addon
-- is presenting, opening the sheet simply shows no showcase.
--
-- r3 (#199): a Blizzard dialog or prompt (an invite, a ready check, a loot
-- roll) brings the game UI back, and the sheet stays open over it. Our own
-- prompts are never StaticPopups (Prompt.lua).
------------------------------------------------------------

local AltStableCameraPresentation = {}
AltStable.AltStableCameraPresentation = AltStableCameraPresentation

-- In a block: SheetUI.lua's main chunk is close to Lua 5.1's 200-local limit.
do
    local function CameraDebug(msg)
        if not (AltStableConfig and AltStableConfig.worldCameraPresentationDebug) then return end
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable Camera]|r " .. tostring(msg or ""))
        end
    end

    -- r3 or newer, fully loaded. r3 is the first MINOR that never touches
    -- Blizzard's dialogs (and brings the UI back for them: onGameUIShown); an
    -- older copy in another addon must not run our showcase. LibStub hands the
    -- newest copy loaded, so an older one here means a newer never loaded.
    -- Anything less: no showcase, never an error at load (IsSupported false).
    local NEEDS_MINOR = 3
    local lib, minor
    if LibStub then lib, minor = LibStub:GetLibrary("LibShowcase-1.0", true) end
    local Showcase
    if lib and minor and minor >= NEEDS_MINOR and lib.ready == minor then
        local ok, sc = pcall(lib.New, lib, {
            owner = "AltStable",
            -- A function: AltStableConfig is replaced when the SavedVariables load.
            db = function() return AltStableConfig end,
            debug = CameraDebug,
            -- The library has already restored everything: the camera, the UI.
            -- Close the sheet too, whatever the reason - Escape or Alt+Z
            -- ("ui-shown") so one Escape does the whole thing, and combat,
            -- logout or a loading screen, where a sheet left open over a
            -- restored camera is a sheet nobody asked for any more.
            onForcedExit = function()
                local sheet = AltStableCameraPresentation.sheetFrame
                if sheet and sheet:IsShown() then sheet:Hide() end
            end,
            -- The library brought the UI back for a Blizzard dialog or prompt
            -- (an invite, a ready check, a loot roll). The sheet and the camera
            -- stay; the UI stays up until the sheet closes. Nothing to do.
            onGameUIShown = function(reason)
                CameraDebug("game UI shown: " .. tostring(reason))
            end,
        })
        if ok then Showcase = sc else CameraDebug("LibShowcase New failed: " .. tostring(sc)) end
    elseif lib then
        CameraDebug("LibShowcase-1.0 MINOR " .. tostring(minor) .. " is too old or half-loaded; no showcase")
    end
    AltStable.Showcase = Showcase

    -- AltStableConfig -> the instance's options, at every open. Unset or
    -- non-numeric values fall back exactly as the old _GetConfig did (the library
    -- clamps to the same ranges and falls back to the same defaults; the two that
    -- differ from the library's are given here).
    local function SyncOptions()
        AltStableConfig = AltStableConfig or {}
        if AltStable.EnsureConfigDefaults then AltStable.EnsureConfigDefaults() end
        local c, o = AltStableConfig, Showcase.opts
        o.enterDuration   = tonumber(c.worldCameraEnterDuration)
        o.exitDuration    = tonumber(c.worldCameraExitDuration)
        o.zoom            = tonumber(c.worldCameraZoomPreset)
        o.shoulderRef     = tonumber(c.worldCameraShoulderZoomReference) or 6.2
        o.mountedZoom     = tonumber(c.worldCameraMountedZoomPreset)
        o.mountedShoulder = tonumber(c.worldCameraMountedShoulderOffset) or 8.0
        o.forceMounted    = c.worldCameraForceMountedPresentation == true
        o.yawOffset       = tonumber(c.worldCameraYawOffset)
        o.yawDegrees      = tonumber(c.worldCameraYawDegrees)
        o.savedViewSlot   = tonumber(c.worldCameraSavedViewSlot)
        o.shoulderMult    = tonumber(c.worldCameraShoulderMult) or 1.0
        o.orbit           = c.worldCameraContinuousOrbit == true
        o.orbitSpeed      = tonumber(c.worldCameraOrbitSpeed)
        o.hideUI          = c.hideGameUIOnPresentation ~= false   -- Alt+Z-style clean showcase (default on)
        o.salute          = c.enableWorldCameraSalute == true
        return c.enableWorldCameraPresentation ~= false
    end

    -- Enter may present with the game UI still UP (r3): a Blizzard dialog or a
    -- prompt was already open, and hiding the UI would have lost it. Nothing
    -- here assumes it is hidden - IsGameUIHidden says.
    function AltStableCameraPresentation:Enter()
        if not Showcase or not SyncOptions() then return end
        return Showcase:Enter(self.sheetFrame)
    end
    function AltStableCameraPresentation:Exit(reason) if Showcase then return Showcase:Exit(reason) end end
    function AltStableCameraPresentation:ForceRestore(reason) if Showcase then return Showcase:ForceRestore(reason) end end
    function AltStableCameraPresentation:HideGameUI() if Showcase then return Showcase:HideGameUI(self.sheetFrame) end end
    function AltStableCameraPresentation:RestoreGameUI() if Showcase then return Showcase:RestoreGameUI() end end
    function AltStableCameraPresentation:IsSupported()
        return Showcase ~= nil
           and type(SaveView) == "function" and type(SetView) == "function" and type(GetCameraZoom) == "function"
           and type(CameraZoomIn) == "function" and type(CameraZoomOut) == "function"
    end

    -- The old fields, read-only, from the library (for /run debugging and tests):
    -- active, mode, capture (this addon's presentation only) and uiHidden.
    setmetatable(AltStableCameraPresentation, { __index = function(_, k)
        if not Showcase then return nil end
        local cam = lib.state.cam
        if k == "active" then return Showcase:IsActive() end
        if k == "uiHidden" then return Showcase:IsGameUIHidden() end
        if k == "mode" then return Showcase:IsActive() and cam.mode or nil end
        if k == "capture" then return Showcase:IsActive() and cam.capture or nil end
    end })

    AltStable._test = AltStable._test or {}
    AltStable._test.CENTRING_CVARS = Showcase and lib.CENTRING_CVARS or {}
    AltStable._test.CameraPresentation = AltStableCameraPresentation

    -- Anything that must stay visible while the game UI is hidden has to be lifted
    -- out from under UIParent - no strata makes a child of a hidden parent draw.
    -- The sheet and GameTooltip are lifted by the showcase; this is the same door
    -- for everything else (the character menu). Idempotent in both directions.
    -- Our prompts (Prompt.lua) need no lift: they are parented to nothing.
    function AltStable.IsGameUIHidden()
        return Showcase ~= nil and Showcase:IsGameUIHidden() == true
    end

    function AltStable.LiftAboveHiddenUI(frame, state)
        if not (frame and Showcase) then return end
        if state then Showcase:Lift(frame, "FULLSCREEN_DIALOG") else Showcase:Drop(frame) end
    end

    -- Suppress the "enable this experimental feature?" popup a test_* CVar write
    -- raises. The library does it before each of its own writes. Since r3 it is
    -- never given back (re-registering it was measured to taint): it stays off
    -- until the next /reload.
    AltStable.SuppressExperimentalCVarPopup = Showcase and lib.SuppressExperimentalCVarPopup
        or function() end
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
    -- Recorded on the runner so the fade can be COMPLETED from outside, which
    -- is what FinishOpenAnimation below needs. In the closure alone, the only
    -- thing that could end this animation was the animation itself.
    OpenAnimRunner.target = targetFrame
    OpenAnimRunner.finalScale = userScale
    OpenAnimRunner:SetScript("OnUpdate", function(self, dt)
        self.elapsed = (self.elapsed or 0) + (dt or 0)
        local p = math.min(1, self.elapsed / duration)
        local eased = p * p * (3 - 2 * p) -- smoothstep
        targetFrame:SetAlpha(eased)
        targetFrame:SetScale(startScale + (userScale - startScale) * eased)
        if p >= 1 then
            AltStable.FinishOpenAnimation()
        end
    end)
    OpenAnimRunner:Show()
end
AltStable._PlayOpenAnimation = PlayOpenAnimation

-- Snap the opening fade to its end, now, and return whether there was one.
--
-- This exists because the fade OWNS the sheet's alpha for 0.22 seconds, and
-- something else borrows that alpha: the portrait capture hides the sheet by
-- zeroing it and writes back whatever it found. Start a capture inside the
-- fade and the value it finds is 0, or a third of the way up - the fade then
-- finishes at 1 on its own, and the capture's restore puts the stale number
-- back. A sheet that is shown and completely invisible, with nothing on screen
-- to explain it.
--
-- Two owners of one property need an order, not a race. Anything about to
-- borrow the alpha finishes the fade first, so what it reads is the settled
-- value - which is also what the player would have seen a fifth of a second
-- later anyway.
function AltStable.FinishOpenAnimation()
    -- `target` is the flag, and the only one: it is set when a fade starts and
    -- cleared here when one ends, including when the fade ends by itself. A
    -- second condition on the runner's shown-ness would be a different answer
    -- to the same question, reachable only if the two ever disagreed - which
    -- is a state nothing creates, so no test could pin it.
    local runner = OpenAnimRunner
    if not runner or not runner.target then return false end

    runner.target:SetAlpha(1)
    runner.target:SetScale(runner.finalScale or 1)
    runner:SetScript("OnUpdate", nil)
    runner:Hide()
    runner.target = nil
    return true
end

------------------------------------------------------------
-- The addon's icon: the group of figures from the client's Who tab.
--
-- A FILE ID, because the client gave no path for it. Found with the probe's
-- /asicon on the LFG frame's side tabs: the tab is the `common-sidetab` atlas
-- and the art inside it is this, set by id with no atlas and no filename.
--
-- IT CANNOT BE VALIDATED. Measured on 1.60.1.70009:
--
--     /run local t=UIParent:CreateTexture() t:SetTexture(999999999)
--          print(t:GetTexture(), t:GetTextureFileID())
--     999999999   999999999
--
-- A file id is stored, not resolved: a nonsense one is echoed straight back. So
-- "set it and check whether it took" is a check that can never fire, and an
-- earlier version of this had a fallback behind exactly such a check - green
-- tests, and a blank minimap button the day the id changes.
--
-- SO THE FALLBACK IS DRAWN, NOT DECIDED. The old icon sits on a lower layer and
-- the file id is drawn over it. The same measurement says an id the client does
-- not have draws NOTHING, which is precisely what makes this work: if 8197123
-- ever stops resolving, the layer beneath shows through and the button is the
-- old icon rather than empty. No check, no branch, nothing to be wrong about.
--
-- This only holds while the Who-tab art is OPAQUE - transparent pixels in it
-- would show the old icon through at all times, which is a present defect
-- traded for a hypothetical one. Checked on the minimap button, 2026-09-26: the
-- art covers the underlay completely, no bleed-through. Worth re-checking if
-- the id is ever changed for a different texture.
--
-- If the icon ever does revert, /asicon on the Who tab gives the new id. (That
-- command arrives with #82 and is not on main yet.)
local ROSTER_ICON_FILE_ID = 8197123
local ROSTER_ICON_UNDERLAY = "Interface\\Icons\\INV_Misc_GroupNeedMore"

-- Draws both layers onto a button. Returns the two textures, so a test can see
-- that the underlay is really there and really underneath.
local function ApplyRosterIcon(btn)
    if not btn or not btn.CreateTexture then return nil end

    -- The underlay is Interface\Icons\ art: 64x64 with a border baked in,
    -- which is why it is trimmed by 8%.
    local under = btn:CreateTexture(nil, "BACKGROUND")
    under:SetTexture(ROSTER_ICON_UNDERLAY)
    if under.SetTexCoord then under:SetTexCoord(0.08, 0.92, 0.08, 0.92) end

    -- The Who tab art is NOT trimmed. It is UI art from inside a sidetab and
    -- has no border margin, so the same 8% would shave the outer figures off
    -- the group.
    local over = btn:CreateTexture(nil, "ARTWORK")
    over:SetTexture(ROSTER_ICON_FILE_ID)
    if over.SetTexCoord then over:SetTexCoord(0, 1, 0, 1) end

    return over, under
end

-- Not on the public namespace: one caller in this file, plus tests. The
-- convention here is _PlayOpenAnimation and the _test seam, not AltStable.Foo
-- for an internal.
AltStable._test = AltStable._test or {}
AltStable._test.ApplyRosterIcon = ApplyRosterIcon
AltStable._test.ROSTER_ICON_FILE_ID = ROSTER_ICON_FILE_ID
AltStable._test.ROSTER_ICON_UNDERLAY = ROSTER_ICON_UNDERLAY

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

    -- Two layers: see ApplyRosterIcon. The lower one is the old icon, showing
    -- through only if the file id above it ever stops resolving.
    local icon, underIcon = ApplyRosterIcon(btn)
    for _, t in ipairs({ icon, underIcon }) do
        t:SetSize(20, 20)
        t:SetPoint("CENTER", btn, "CENTER", 0, 1)
    end

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

-- AltStableDB is flat, keyed by guid: that is what Scanner, Core and Config all
-- write and read. The AltTracker-era "db.characters" sub-table this used to fall
-- back to is written by nothing here, and the branch made the sheet read the
-- store differently from every other file - which would have shown hidden
-- characters filtered out of the grid while the restore list in Options found
-- no records at all.
local function GetCharacterStore()
    if type(AltStableDB)~="table" then return {} end
    return AltStableDB
end

-- The laid-out column widths (#150); see SpreadColumns.
local colWidths, colWidthsKey = {}, ""

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
    local fields = section.fields
    if section.repFields then
        fields = {}
        for _, f in ipairs(section.fields) do fields[#fields+1] = f end
        for _, f in ipairs(AltStable.RepFieldsInUse(GetCharacterStore())) do fields[#fields+1] = f end
    end
    for _, field in ipairs(fields) do
        local col = ColumnFor(field)
        if col then scrollableCols[#scrollableCols+1] = col end
    end
end

------------------------------------------------------------
-- Display list
------------------------------------------------------------

-- #21. Hiding is filtered HERE, at render time, and nowhere else: the record
-- still syncs, still updates, and still goes out to peers. Config.lua owns the
-- state (per account, keyed by guid).
local function IsHidden(char)
    if not AltStable.IsCharacterHidden then return false end
    return AltStable.IsCharacterHidden(char.guid)
end

-- #69. The "show hidden" toggle changes WHAT THE GRID LISTS and nothing else.
--
-- Two predicates, not one, and the split is the whole point: IsHidden still
-- decides the totals and the "(N hidden)" count, so those mean the same thing
-- whether the toggle is on or off. Folding the toggle into IsHidden would have
-- made switching a view silently change the account's reported gold.
local function ShouldShowInGrid(char)
    if not IsHidden(char) then return true end
    return AltStable.IsShowingHidden and AltStable.IsShowingHidden() or false
end

-- The distinct accounts a set of characters came from, sorted.
--
-- Its own function so it can be tested as itself: the group header printed
-- "(Account: Default)" for the life of the addon because the item never
-- carried an account at all, and the fix is worth an assertion that does not
-- depend on getting a whole display list to build.
--
-- A SET, because a realm can hold characters from more than one account -
-- which is the entire point of the sync feature - and because the same account
-- appearing on nine characters is one account, not nine.
local function CollectAccounts(chars)
    local seen, out = {}, {}
    for _, c in ipairs(chars or {}) do
        local a = c and c.account
        if a ~= nil and a ~= "" then
            a = tostring(a)
            if not seen[a] then
                seen[a] = true
                out[#out + 1] = a
            end
        end
    end
    -- Sorted NUMERICALLY when they are numbers, which they are: the scanner
    -- writes AltStableConfig.accountNumber, validated as a whole number from a
    -- three-digit box. A plain sort is a string sort, so accounts 2 and 10 read
    -- "(Accounts: 10, 2)" - and the test only ever used 1 and 2, which string
    -- and numeric order agree on.
    --
    -- Falls back to comparing as text when either side is not a number, so a
    -- hand-edited profile holding something odd still sorts predictably rather
    -- than erroring mid-render.
    table.sort(out, function(a, b)
        local na, nb = tonumber(a), tonumber(b)
        if na and nb then return na < nb end
        return a < b
    end)
    return out
end

AltStable._test = AltStable._test or {}
AltStable._test.CollectAccounts = CollectAccounts

------------------------------------------------------------
-- Sorting (#160)
------------------------------------------------------------

local DEFAULT_SORT_FIELD, DEFAULT_SORT_ASC = "level", false


-- What a character is sorted by, for a column - or nil, which always sorts
-- LAST, in both directions: unreadable gold, an unmet faction, no guild. A
-- number column reads a number and a text column a non-empty string, decided
-- per COLUMN: choosing per pair (the old tostring fallback) can form a cycle -
-- 2 < 10 as numbers, "10" < "11" < "2" as text - and table.sort then misorders
-- or raises "invalid order function".
local function SortValue(char, col)
    -- The column's own sortValue when it has one (level, rested XP, class and
    -- race: see Columns.lua), else the stored field.
    local v
    if col.sortValue then v = col.sortValue(char) else v = char[col.field] end
    if col.sortText then
        if type(v) == "number" then v = tostring(v) end
        if type(v) ~= "string" or v == "" then return nil end
        return v
    end
    return tonumber(v)
end

-- Case-insensitive, three-way: <0, 0, >0. The client's own (SortUtil, Mainline
-- FrameXML) compares UTF-8 by locale; the fallback is for a client without it.
local function CompareText(x, y)
    if SortUtil and SortUtil.CompareUtf8i then return SortUtil.CompareUtf8i(x, y) end
    x, y = x:lower(), y:lower()
    if x < y then return -1 elseif x > y then return 1 end
    return 0
end

-- The order of the rows. Values are read ONCE, up front - the rested estimate
-- reads the clock, and a value that moved during the sort would break it.
-- A three-way result is turned into a boolean explicitly: 0 and -1 are both
-- TRUE in Lua, so returning one would make every pair "less". Equal values go
-- to the old tiebreak: item level, highest first, then name.
local function SortComparator(chars, field, asc)
    local col = ColumnFor(field)
    local key = {}
    if col then
        for _, c in ipairs(chars) do key[c] = SortValue(c, col) end
    end
    local text = col and col.sortText
    return function(a, b)
        local va, vb = key[a], key[b]
        if va ~= nil and vb ~= nil then
            local d
            if text then d = CompareText(va, vb)
            elseif va < vb then d = -1
            elseif va > vb then d = 1
            else d = 0 end
            if d ~= 0 then
                if asc then return d < 0 end
                return d > 0
            end
        elseif va ~= nil then
            return true
        elseif vb ~= nil then
            return false
        end
        local i1, i2 = tonumber(a.ilvl) or 0, tonumber(b.ilvl) or 0
        if i1 ~= i2 then return i1 > i2 end
        return (a.name or "") < (b.name or "")
    end
end
AltStable._test.SortComparator = SortComparator

-- Each tab keeps its own sort. For this session always; across sessions while
-- "Remember sort order" is on (default), in AltStableConfig.sheetSort:
--   { [sectionId] = { field = "money", asc = false } }
local sectionSorts = {}

local function RememberSortOrder()
    return not (AltStableConfig and AltStableConfig.rememberSortOrder == false)
end

local function StoredSort(sectionId)
    if not RememberSortOrder() then return nil end
    local all = AltStableConfig and AltStableConfig.sheetSort
    local s = type(all) == "table" and all[sectionId]
    if type(s) == "table" and type(s.field) == "string" and type(s.asc) == "boolean" then
        return s
    end
end

-- The current sort, as the tab's own. Not for a plugin: it has no columns.
local function SaveSort(section)
    if not section or section._isPlugin then return end
    sectionSorts[section.id] = { field = sortColumn, asc = sortAsc }
    if not RememberSortOrder() then return end
    local copy = {}
    if type(AltStableConfig) == "table" and type(AltStableConfig.sheetSort) == "table" then
        for k, v in pairs(AltStableConfig.sheetSort) do copy[k] = v end
    end
    copy[section.id] = { field = sortColumn, asc = sortAsc }
    AltStable.SetConfigValue("sheetSort", copy)
end

-- Every tab's sort this session, saved: for "Remember" being switched on.
local function SaveSessionSorts()
    local copy = {}
    for id, s in pairs(sectionSorts) do copy[id] = { field = s.field, asc = s.asc } end
    AltStable.SetConfigValue("sheetSort", copy)
end

-- Whether `field` can order the active tab's rows: Name always, otherwise a
-- sortable column the tab is showing. A faction no character has any more is
-- not one, and neither is a column of another tab.
local function SortFieldValid(field)
    if type(field) ~= "string" then return false end
    if field == AltStable.Columns[1].field then return true end
    for _, col in ipairs(scrollableCols) do
        if col.field == field then return col.sortable ~= false end
    end
    return false
end

local function ResetSortIfInvalid()
    if not SortFieldValid(sortColumn) then
        sortColumn, sortAsc = DEFAULT_SORT_FIELD, DEFAULT_SORT_ASC
    end
end

-- The tab's sort on arrival: this session's, else the saved one, else level,
-- highest first - whichever still names a column it has.
local function LoadSortFor(section)
    local s = sectionSorts[section.id]
    if not s then
        s = StoredSort(section.id)
        -- A sort restored at login is this tab's for the session from here on,
        -- as one made by a click is: turning "Remember" off clears the saved
        -- ones, and the tab must keep it all the same (#162 review).
        if s then sectionSorts[section.id] = { field = s.field, asc = s.asc } end
    end
    if s then sortColumn, sortAsc = s.field, s.asc
    else sortColumn, sortAsc = DEFAULT_SORT_FIELD, DEFAULT_SORT_ASC end
    ResetSortIfInvalid()
end
AltStable._test.SortState = function() return sortColumn, sortAsc end
-- A new login, as far as sorting goes: this session's per-tab sorts forgotten.
AltStable._test.ForgetSessionSorts = function() wipe(sectionSorts) end
AltStable._test.DisplayList = function() return displayList end

local function BuildDisplayList()
    wipe(displayList)
    totalChars=0; totalLevel=0; totalGold=0; goldUnknown=0; hiddenCount=0
    local store = GetCharacterStore()

    -- Totals reflect every character in the DB EXCEPT the hidden ones. A
    -- hidden character is meant to be gone from the sheet, and a total that
    -- still counted it would be the one place it kept showing up - so the
    -- footer reports how many were left out instead.
    --
    -- Everything else counts, including low-level bank alts: they hold gold,
    -- and the total is expected to match other addons (ElvUI, etc.) that count
    -- them.
    -- A character whose money is UNREADABLE (secret, see Compat.lua) has no
    -- money field at all. Counting it as zero would present the sum as the
    -- whole account's gold while silently leaving one character out, so the
    -- footer says how many are missing instead.
    --
    -- Computed by AltStable.CharacterTotals (Core.lua), which the public
    -- GetTotals() also returns (#123): a bar showing "total gold" and this
    -- footer cannot disagree if there is one piece of arithmetic behind both.
    -- Internal on purpose - the footer must not depend on a function other
    -- addons can see and overwrite.
    local t = AltStable.CharacterTotals()
    totalChars, totalLevel, totalGold = t.characters, t.levels, t.money
    goldUnknown, hiddenCount = t.unknown, t.hidden

    local allChars = {}
    for _, char in next, store do
        -- ShouldShowInGrid, not IsHidden: this is the LIST. The totals above
        -- and the iLvl average below deliberately still use IsHidden.
        if type(char)=="table" and char.name and ShouldShowInGrid(char) then
            table.insert(allChars, char)
        end
    end
    table.sort(allChars, SortComparator(allChars, sortColumn, sortAsc))
    local realmOrder, realmChars = {}, {}
    for _, char in ipairs(allChars) do
        local realm = char.realm or "Unknown"
        if not realmChars[realm] then realmChars[realm]={}; table.insert(realmOrder,realm) end
        table.insert(realmChars[realm], char)
    end
    for _, realm in ipairs(realmOrder) do
        local chars=realmChars[realm]; local sumLvl=0; local sumGold=0
        for _, c in ipairs(chars) do
            sumLvl=sumLvl+(c.level or 0); sumGold=sumGold+(c.money or 0)   -- nil = unreadable; the footer counts those
        end
        -- Which accounts this realm's characters came from.
        --
        -- The group header has always printed "(Account: Default)" because the
        -- item never carried an account at all - `item.account` was nil for
        -- every group ever rendered, and "Default" was the fallback rather than
        -- a value. It was a placeholder that shipped.
        --
        -- A SET, not one value: a realm can hold characters from more than one
        -- account, which is the entire point of the sync feature.
        table.insert(displayList,{kind="group",realm=realm,count=#chars,
            accounts=CollectAccounts(chars),
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
    local pool = AltStable.RowPoolFor(rowPools, activeSection.id, scrollableCols)
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
        if type(char)=="table" and char.name and not IsHidden(char) then
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
    local goldNote = (goldUnknown > 0)
        and ("  |cffff8800(" .. goldUnknown .. " unknown)|r") or ""
    totalsBar.right:SetText(
        "|cffaaaaaa" .. math.floor(totalGold/10000) .. GOLD_ICON_SM .. " total gold|r"
        .. goldNote)

    -- The hidden note, now a button (#69). Dim, and left of the gold: it is not
    -- a warning, it is a reminder that the numbers beside it describe fewer
    -- characters than the database holds.
    --
    -- Shown when there ARE hidden characters OR while the toggle is on. The
    -- second half is not belt and braces: unhide the last hidden character
    -- while listing them and the button would otherwise vanish with the
    -- preference still set, so the next character hidden would silently stay
    -- on screen with no control in sight to explain why.
    local btn = totalsBar.hiddenBtn
    if btn then
        local showing = AltStable.IsShowingHidden and AltStable.IsShowingHidden() or false
        if hiddenCount > 0 or showing then
            btn.label:SetText(showing
                and ("|cffffd100(" .. hiddenCount .. " hidden, listed - not counted)|r")
                or  ("|cff808080(" .. hiddenCount .. " hidden)|r"))
            btn:SetWidth(math.max(1, btn.label:GetStringWidth() or 1))
            btn:Show()
        else
            btn:Hide()
        end
    end
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

    -- The left edges hang off the SIDEBAR's edge rather than a fixed offset
    -- from the window (#150), so the grid follows the sidebar while it
    -- animates between full and compact. The sidebar's top-right is the
    -- window's (SIDEBAR_WIDTH, -TITLE_H) and its bottom-right (SIDEBAR_WIDTH,
    -- 1); a frame with no sidebar yet uses those numbers directly.
    local sb = frame.sidebar
    local function Left(region, point, x, yFromTop, yFromBottom)
        if sb then
            if yFromTop then
                region:SetPoint(point, sb, "TOPRIGHT", x, yFromTop + TITLE_H)
            else
                region:SetPoint(point, sb, "BOTTOMRIGHT", x, yFromBottom - 1)
            end
        else
            region:SetPoint(point, frame, point, SIDEBAR_WIDTH + x, yFromTop or yFromBottom)
        end
    end

    bodyScroll:ClearAllPoints()
    Left(bodyScroll, "TOPLEFT", FROZEN_WIDTH, -BodyTopY())
    bodyScroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -rightInset, bodyBot)

    -- The reading surface spans the two viewports, so it is anchored WITH
    -- them. It used to be pinned once at frame creation, 36 from the bottom,
    -- while this bottom moves: 23 with no horizontal scrollbar and 43 with one.
    -- The 13px difference was invisible while every row painted an opaque band
    -- over it, and the moment the rows became lifts it was a strip of moving
    -- world under the last row. The top has the same problem in reverse - it
    -- was frozen at the header height of whichever section built the frame,
    -- and the taller ones poked the surface up into the header.
    if AltStable._dataBG then
        AltStable._dataBG:ClearAllPoints()
        Left(AltStable._dataBG, "TOPLEFT", 0, -BodyTopY())
        AltStable._dataBG:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -rightInset, bodyBot)
    end

    frozenScroll:ClearAllPoints()
    Left(frozenScroll, "TOPLEFT", 0, -BodyTopY())
    Left(frozenScroll, "BOTTOMLEFT", 0, nil, bodyBot)
    frozenScroll:SetWidth(FROZEN_WIDTH)

    -- Header right edge MUST equal body right edge — same rightInset.
    -- Without this, the last column header is clipped (no v-scroll) or
    -- overflows past the v-scrollbar (with v-scroll).
    if headerScroll then
        headerScroll:ClearAllPoints()
        Left(headerScroll, "TOPLEFT", FROZEN_WIDTH, -HEADER_TOP_Y)
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
        Left(hScrollBar, "BOTTOMLEFT", 4, nil, footerTop + 1)
        hScrollBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -rightInset,       footerTop + 1)
    end
end

-- The columns as LAID OUT (#150), which is not always their own widths.
--
-- A sheet tab sizes its window to its columns, so normally the two agree. When
-- the window is wider than that - maximized, or a plugin tab's size kept after
-- the sidebar collapsed - the grid used to stop where its columns did and
-- leave the rest of the window empty. The spare width is now shared out
-- across the columns in proportion to their own widths, so the table fills
-- the window; when the window fits them again they go back to their own.
--
-- Only ever WIDER: a window narrower than its columns scrolls, as before. And
-- the window is still sized from the columns' own widths (GetScrollableWidth),
-- never these, or every resize would grow it by what the last one spread.
local STRETCH_MIN = 8      -- a sliver of spare width is not worth re-placing every cell for

local function SpreadColumns(viewportW)
    local natural = GetScrollableWidth()
    -- Whole pixels: a fractional viewport (any scale but 1) would otherwise put
    -- every cell and divider on a sub-pixel x and blur the 1px lines.
    local extra = math.floor(viewportW or 0) - natural
    if extra < STRETCH_MIN then extra = 0 end
    local sum = 0
    for _, col in ipairs(scrollableCols) do sum = sum + col.width end
    local given = 0
    for i, col in ipairs(scrollableCols) do
        local add = 0
        if extra > 0 and sum > 0 then add = math.floor(extra * col.width / sum) end
        given = given + add
        colWidths[i] = col.width + add
    end
    -- What flooring left - under a pixel per column - goes a pixel at a time
    -- to the first columns, rather than all of it to the last one.
    for i = 1, math.min(extra - given, #scrollableCols) do
        colWidths[i] = colWidths[i] + 1
    end
    for i = #colWidths, #scrollableCols + 1, -1 do colWidths[i] = nil end
    colWidthsKey = table.concat(colWidths, ",")
    return natural + extra
end
AltStable._test.ColumnWidths = function() return colWidths end

-- The scrolling headers in column order (headerButtons, in the state block) and
-- the dividers between them: the ones in use, index for index with
-- scrollableCols. The pools hold every one ever made, reused by slot.
local headerDividers = {}
local headerPool, dividerPool = {}, {}
-- The frozen Name header. Kept OUT of headerButtons: that list must match
-- scrollableCols index for index, and it is wiped on every rebuild - which is
-- how the Name header, once in it, lost its sort indication for good.
local nameHeader

-- Headers and every pooled row of this tab, at the laid-out widths.
-- The header at `widths` (nil: the columns' own), by the same walk as the rows.
local function LayoutHeaders(widths)
    AltStable.WalkColumns(scrollableCols, widths, function(i, x, w, divX)
        local btn = headerButtons[i]
        if not btn then return end
        btn:ClearAllPoints(); btn:SetPoint("LEFT", x, 0); btn:SetWidth(w)
        if btn.kind == "stacked" then btn.label:SetWidth(w) end
        if headerDividers[i] then
            headerDividers[i]:ClearAllPoints()
            headerDividers[i]:SetPoint("LEFT", divX, 0)
        end
    end)
end

local function LayoutColumns()
    LayoutHeaders(colWidths)
    local pool = AltStable.RowPoolFor(rowPools, activeSection.id, scrollableCols)
    for _, row in ipairs(pool.rows) do
        AltStable.LayoutRowCells(row, scrollableCols, colWidths, colWidthsKey)
    end
end
-- What was laid out, so a test can measure the headers and cells themselves.
AltStable._test.ColumnLayout = function()
    return scrollableCols, headerButtons, headerDividers,
           AltStable.RowPoolFor(rowPools, activeSection.id, scrollableCols).rows,
           bodyContent, headerContent
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

    -- Spare width goes to the columns. A grid that scrolls has none.
    contentW = SpreadColumns(bodyScroll:GetWidth())
    LayoutColumns()

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

------------------------------------------------------------
-- Column headers (#160)
--
-- One builder for every header, the frozen Name one included. Each header is
-- one of three KINDS, which decide only how it looks:
--   text    - a label (Name, Lvl, Guild, Gold...)
--   icon    - a gear, profession or faction icon, or the Class/Race glyph
--   stacked - a faction with no icon: its short name, one letter per line
-- Every kind shows the same states: hover is a neutral fill; sorted is a faint
-- accent fill, an accent underline and an arrow for the direction. A header
-- that does not sort (gear slots) has neither, only its tooltip.
-- How a header BEHAVES - click to sort, hover, tooltip - is wired once, in
-- WireHeader, and reads the column it was last given.
--
-- The buttons are REUSED by slot, like the rows: a section switch used to make
-- a fresh button per column and only hide the old ones, so they piled up for
-- as long as the UI lived. Every region a kind uses is made once per button and
-- reset by ConfigureHeader, so reuse cannot carry one kind's look into another.
------------------------------------------------------------

-- Class and Race: neutral glyphs that name the COLUMN - crossed weapons, two
-- profiles - shipped in Media\Icons. Not the logged-in character's own class
-- and race icons: those looked like one more row, and changed with the alt.
local MEDIA = AltStable.MEDIA_PATH or "Interface\\AddOns\\AltStable\\Media\\"
local HEADER_GLYPH = {
    classIcon = MEDIA .. "Icons\\header-class.tga",
    raceIcon  = MEDIA .. "Icons\\header-race.tga",
}

-- The icon a header shows, and whether it is one of our glyphs (drawn whole)
-- or a game icon (its pixel border cropped). nil: no icon.
local function HeaderIcon(col)
    if HEADER_GLYPH[col.type] then return HEADER_GLYPH[col.type], true end
    -- slotSlug: the faction-aware gear icon, resolved at header-build time.
    return (col.slotSlug and AltStable.GetGearIconPath and AltStable.GetGearIconPath(col.slotSlug))
        or col.profIcon or col.slotIcon or col.repIcon, false
end

-- The kind, and for an icon header its icon (resolved once, here).
local function HeaderKind(col)
    if col.vertical and not col.repIcon then return "stacked" end
    local icon, isGlyph = HeaderIcon(col)
    if icon then return "icon", icon, isGlyph end
    return "text"
end

-- What an order is called, for a column: "highest first", "A to Z".
local function OrderWords(col, asc)
    if col.sortText then return asc and "A to Z" or "Z to A" end
    if col.orderWords then return col.orderWords[asc and 1 or 2] end
    return asc and "lowest first" or "highest first"
end

-- Where the arrow goes. Beside the label on a text header; in the bottom-right
-- corner, just above the underline, on every other kind - a 22px reputation
-- column has no room for an icon and an arrow side by side.
local function PlaceArrow(btn)
    local arrow = btn.arrow
    arrow:ClearAllPoints()
    if btn.kind ~= "text" then
        arrow:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 3)
    elseif (btn.col.align or "LEFT") == "LEFT" then
        local w = btn.label:GetStringWidth()
        arrow:SetPoint("LEFT", btn, "LEFT", 2 + (type(w) == "number" and w or 0) + 3, 0)
    else
        -- A right-aligned label ends 10px from the edge: the arrow sits in that gap.
        arrow:SetPoint("RIGHT", btn, "RIGHT", -1, 0)
    end
end

-- The sorted state on one header: a faint accent fill, a full-strength accent
-- underline, the label in the accent, and the arrow for the direction. Hover
-- is a separate, neutral fill (WireHeader), so the two never look alike.
local function PaintSortState(btn)
    local sorted = btn.sortable and btn.field == sortColumn
    btn.sortFill:SetShown(sorted)
    btn.underline:SetShown(sorted)
    btn.arrow:SetShown(sorted)
    if sorted then
        local ar, ag, ab = AltStable.GetAccentRGB()
        btn.sortFill:SetColorTexture(ar, ag, ab, 0.18)
        btn.underline:SetColorTexture(ar, ag, ab, 1)
        -- The arrow file points up: as is for ascending, flipped for descending.
        btn.arrow:SetTexCoord(0, 1, sortAsc and 0 or 1, sortAsc and 1 or 0)
        PlaceArrow(btn)
        btn.label:SetTextColor(ar, ag, ab)
    else
        btn.label:SetTextColor(unpack(AltStable.C.TEXT_NORM))
    end
end

local function UpdateSortArrows()
    if nameHeader then PaintSortState(nameHeader) end
    for _, btn in ipairs(headerButtons) do PaintSortState(btn) end
end

-- The tooltip: what the column is and, on a sortable one, the order it is in
-- and what the next click does.
local function ShowHeaderTooltip(btn)
    local col = btn.col
    GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM"); GameTooltip:ClearLines()
    GameTooltip:AddLine(COL_TOOLTIPS[col.field] or col.label, 1, 1, 1)
    if btn.sortable then
        if btn.field == sortColumn then
            local now = OrderWords(col, sortAsc)
            GameTooltip:AddLine(now:sub(1, 1):upper() .. now:sub(2), 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Click to sort " .. OrderWords(col, not sortAsc), 0.7, 0.7, 0.7)
        else
            GameTooltip:AddLine("Click to sort " .. OrderWords(col, col.sortText == true), 0.7, 0.7, 0.7)
        end
    end
    -- The standing key lives in the faction headers, so the footer keeps the
    -- normal char/level/gold totals like every other tab.
    if col.type == "rep" then AddRepStandingLegend(GameTooltip) end
    GameTooltip:Show()
end

-- A click on a sortable header: this column, in its first-click direction (text
-- A to Z, numbers highest first), or the other way if it already is. Kept per
-- tab, and saved while "Remember sort order" is on.
local function SortByHeader(btn)
    if not btn.sortable then return end
    local field = btn.field
    if sortColumn == field then sortAsc = not sortAsc
    else sortColumn = field; sortAsc = btn.col.sortText == true end
    SaveSort(activeSection)
    UpdateSortArrows(); BuildDisplayList(); UpdateScroll(); UpdateRows(); UpdateTotalsBar()
    -- The tooltip under the mouse described the order before the click.
    if GameTooltip:IsOwned(btn) then ShowHeaderTooltip(btn) end
end

local function WireHeader(btn)
    btn:SetScript("OnClick", function(self) SortByHeader(self) end)
    btn:SetScript("OnEnter", function(self)
        -- A header that does not sort does not look like a button.
        if self.sortable then self.hoverFill:Show() end
        ShowHeaderTooltip(self)
    end)
    btn:SetScript("OnLeave", function(self)
        self.hoverFill:Hide()
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
end

local function NewHeaderButton(parent)
    local btn = CreateFrame("Button", nil, parent)
    -- The fills sit under everything else on the button, hover below sorted.
    btn.hoverFill = btn:CreateTexture(nil, "BACKGROUND", nil, 1)
    btn.hoverFill:SetAllPoints(); btn.hoverFill:SetColorTexture(1, 1, 1, 0.06); btn.hoverFill:Hide()
    btn.sortFill = btn:CreateTexture(nil, "BACKGROUND", nil, 2)
    btn.sortFill:SetAllPoints(); btn.sortFill:Hide()
    -- Pinned to the button's bottom edge, so it follows a spread column.
    btn.underline = btn:CreateTexture(nil, "ARTWORK")
    btn.underline:SetHeight(2)
    btn.underline:SetPoint("BOTTOMLEFT"); btn.underline:SetPoint("BOTTOMRIGHT")
    btn.underline:Hide()
    btn.label   = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    btn.iconTex = btn:CreateTexture(nil, "OVERLAY")
    -- A sublevel above the icon, so the corner arrow is never under it.
    local arrow = btn:CreateTexture(nil, "OVERLAY", nil, 2)
    arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
    arrow:SetSize(8, 8); arrow:Hide()
    btn.arrow = arrow
    WireHeader(btn)
    return btn
end

-- Give a (new or reused) header button its column. Sets EVERYTHING a kind
-- uses, and hides what it does not.
local function ConfigureHeader(btn, col)
    local kind, icon, isGlyph = HeaderKind(col)
    btn.col, btn.field, btn.kind = col, col.field, kind
    btn.sortable = col.sortable ~= false
    btn:SetSize(col.width, currentHeaderHeight)
    btn.hoverFill:Hide()

    local lbl, tex = btn.label, btn.iconTex
    lbl:ClearAllPoints(); lbl:SetWidth(0)
    lbl:SetWordWrap(true); lbl:SetNonSpaceWrap(false)
    tex:ClearAllPoints()

    if kind == "icon" then
        local sz = math.min(currentHeaderHeight - 4, col.width - 2, col.headerIconSize or math.huge)
        tex:SetSize(sz, sz); tex:SetPoint("CENTER", btn, "CENTER", 0, 0)
        tex:SetTexture(icon)
        if isGlyph then
            tex:SetTexCoord(0, 1, 0, 1)
        else
            -- Crop the pixel border of the built-in round WoW icons.
            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        tex:Show()
        lbl:SetText(""); lbl:Hide()
        return
    end

    tex:Hide(); lbl:Show()
    if kind == "stacked" then
        lbl:SetFontObject(GameFontHighlightSmall)
        lbl:SetPoint("TOP", btn, "TOP", 0, -2); lbl:SetPoint("BOTTOM", btn, "BOTTOM", 0, 2)
        lbl:SetWidth(col.width); lbl:SetJustifyH("CENTER"); lbl:SetJustifyV("TOP")
        lbl:SetNonSpaceWrap(true)
        lbl:SetText(StackChars(col.verticalLabel or col.label))
    else
        lbl:SetFontObject(GameFontHighlight)
        lbl:SetPoint("LEFT", 2, 0); lbl:SetPoint("RIGHT", -10, 0)
        lbl:SetJustifyH(col.align or "LEFT"); lbl:SetJustifyV("MIDDLE")
        lbl:SetText(col.label)
    end
end

local function ClearHeaders()
    wipe(headerButtons)
    wipe(headerDividers)
    for _, btn in ipairs(headerPool) do
        -- A header rebuilt under the mouse may not get its OnLeave, and whether
        -- the client hides a tooltip whose owner is hidden is not measured
        -- here. Closing our own costs nothing either way.
        if GameTooltip:IsOwned(btn) then GameTooltip:Hide() end
        btn:Hide()
    end
    for _, div in ipairs(dividerPool) do div:Hide() end
end

local function BuildHeaders()
    ClearHeaders()
    -- Created or reused here, placed by LayoutHeaders: the rows' walk.
    for i, col in ipairs(scrollableCols) do
        local btn = headerPool[i]
        if not btn then btn = NewHeaderButton(headerContent); headerPool[i] = btn end
        ConfigureHeader(btn, col)
        btn:Show()
        headerButtons[i] = btn
        if i < #scrollableCols then
            local div = dividerPool[i]
            if not div then div = headerContent:CreateTexture(nil, "OVERLAY"); dividerPool[i] = div end
            div:SetSize(1, currentHeaderHeight)
            div:SetColorTexture(unpack(AltStable.C.GRIDLINE))
            div:Show()
            headerDividers[i] = div
        end
    end
    -- Placed by UpdateScroll, which always follows (LayoutColumns).
    UpdateSortArrows()
end
AltStable._test.HeaderPools = function() return headerPool, dividerPool end
AltStable._test.NameHeader  = function() return nameHeader end

------------------------------------------------------------
-- Per-section window resize.
-- SetSize changes only the dimensions, never the anchor points, so the
-- window stays wherever the user left it.  No need to ClearAllPoints.
------------------------------------------------------------

-- The largest window this display can actually show, in the FRAME's own
-- coordinate space (#99).
--
-- Nothing clamped this before, and Options is the one section that asks for a
-- fixed size - ResizeFrame(820, 760) - rather than sizing to its content. On a
-- shorter display, or at scale 1.25 where 760 becomes an effective 950, the
-- window simply ran off the bottom of the screen and the last options went with
-- it. The scroll frame inside it cannot help: the part that is off-screen is the
-- window, not the content.
--
-- Converted through effective scale rather than compared raw. The frame carries
-- the user's scale setting and UIParent carries the client's, so `760` and
-- `UIParent:GetHeight()` are numbers in two different spaces and comparing them
-- directly is wrong by exactly the ratio nobody notices at scale 1.0.
local SCREEN_MARGIN = 40

-- The display's size in the frame's coordinate space, less the margin. Nil
-- when there is nothing to measure against.
local function ScreenLimit()
    if not (frame and UIParent) then return nil end
    local fs = frame:GetEffectiveScale() or 1
    -- The opening fade runs the window at 96% of its scale for a fifth of a
    -- second, and reopening resizes it inside that: measured then, a
    -- maximized window came out 4% larger than the screen once the fade
    -- ended (#157 review). Measure at the scale it is fading TO.
    local fade = OpenAnimRunner
    if fade and fade.target == frame and fade.finalScale then
        local cur = frame:GetScale() or 0
        if cur > 0 then fs = fs * fade.finalScale / cur end
    end
    local us = UIParent:GetEffectiveScale() or 1
    if fs <= 0 then return nil end
    return (UIParent:GetWidth()  * us) / fs - SCREEN_MARGIN,
           (UIParent:GetHeight() * us) / fs - SCREEN_MARGIN
end

local function FitToScreen(w, h)
    local maxW, maxH = ScreenLimit()
    if not maxW then return w, h end

    -- The floor is the SIDEBAR's own requirement, not an arbitrary 200.
    --
    -- ComputeContentSize deliberately raises the height to
    -- `TITLE_H + GetSidebarRequiredHeight()` so the last nav button does not
    -- overlap the totals bar. Clamping below that undoes it, and the sidebar has
    -- no scroll of its own - so the bottom sections simply render past the edge
    -- and become unreachable. Trading "the window is off-screen" for "half the
    -- navigation is off-screen" is not a fix.
    --
    -- Below the floor the honest answer is that the display cannot show this
    -- window, and a window that overflows is better than one with no way to
    -- reach Options and turn the scale down.
    local floorH = TITLE_H + (AltStable.GetSidebarRequiredHeight
                              and AltStable.GetSidebarRequiredHeight() or 0)
    if floorH < 200 then floorH = 200 end

    if maxW > 200    and w > maxW then w = maxW end
    if maxH > floorH and h > maxH then h = maxH end
    return w, h
end

-- The size last ASKED for, before the screen limit touched it.
--
-- Refitting against the CURRENT size is a one-way ratchet: FitToScreen only
-- ever reduces, so scaling up shrinks the window and scaling back down sees
-- something that already fits and does nothing. The window is left permanently
-- short, and on the Options tab - which is where the scale slider lives, and
-- which is a plugin section, so sizing-to-content early-outs - there is no way
-- back at all without switching sections and returning.
--
-- So the request is remembered and the limit is re-applied to THAT. Scaling up
-- clamps, scaling back down restores.
local wantW, wantH

-- Maximized (#150): the window fills the display, less the margin, centred -
-- and STAYS so across tab switches until restored. Every sizing path below
-- still records what it asked for in wantW/wantH; while maximized that request
-- is simply not applied, so Restore lands on the size the current tab wants,
-- at the place the window was before. Not saved: a /reload opens it normally.
-- One table, so the sizing functions gain a single upvalue between them.
local maxState = { on = false }

-- The geometry animation's state (see AnimateWindowChange), declared here so
-- every sizing path below can end it first.
local windowAnim = {}

-- Snap a running geometry animation to its end, now. Anything else that sizes
-- or re-lays out the window - a tab switch, a tab sizing itself, a scale
-- change - goes through this first: otherwise the trip keeps placing the
-- window frame after frame and then settles it on the size and anchors it
-- measured BEFORE that change, over the top of it (#150: restore, then switch
-- tab inside the fifth of a second, and the window came out the wrong size).
-- `skipRelayout`: the tab is about to be switched (#159), so a layout the trip
-- deferred to its end would be for a tab that is leaving - skip it.
local function FinishWindowAnimation(skipRelayout)
    local runner = windowAnim.runner
    if not (runner and runner:GetScript("OnUpdate")) then return false end
    runner:SetScript("OnUpdate", nil)
    windowAnim.settle(skipRelayout)
    return true
end
AltStable.FinishWindowAnimation = FinishWindowAnimation

local function MaximizedSize()
    local maxW, maxH = ScreenLimit()
    if not maxW then return frame:GetWidth(), frame:GetHeight() end
    -- The sidebar floor still wins over the display, as in FitToScreen.
    local floorH = TITLE_H + (AltStable.GetSidebarRequiredHeight
                              and AltStable.GetSidebarRequiredHeight() or 0)
    return maxW, math.max(maxH, floorH)
end

-- The size the window gets for a request: the request through the screen
-- limit, or the whole screen while maximized.
local function SizeFor(w, h)
    if maxState.on then return MaximizedSize() end
    return FitToScreen(w, h)
end

local function ResizeFrame(w, h)
    if not frame then return end
    FinishWindowAnimation()
    wantW, wantH = w, h
    frame:SetSize(SizeFor(w, h))
end

-- The helper AND the two paths that are supposed to use it. Three times this
-- week a helper has been fully asserted while the line calling it had no
-- coverage, so deleting the call changed nothing the suite could see.
AltStable._test = AltStable._test or {}
AltStable._test.FitToScreen = function(...) return FitToScreen(...) end
AltStable._test.SCREEN_MARGIN = SCREEN_MARGIN
AltStable._test.ResizeFrame = function(...) return ResizeFrame(...) end

-- A plugin tab's floor (#154). A tab that needs room - a toolbar, a dialog -
-- says how much, and the window GROWS to it, through the same clamp. The floor
-- never shrinks a window; a tab's preferred size (RequestPluginSize, #150) is
-- what sets it on opening.
--
-- Decided on the ACTUAL size, not the remembered request (Warband -> Raids ->
-- Warband, Codex review of #154) - but the floor is put on the REQUEST (#150).
-- Floored from the actual size, a window the screen had clamped below the
-- minimum replaced the tab's preferred size with the clamped one, so lowering
-- the scale afterwards could never bring the preferred size back.
function AltStable.EnsureWindowMinSize(w, h)
    if not frame then return end
    local cw, ch = frame:GetWidth() or 0, frame:GetHeight() or 0
    local rw, rh = wantW or cw, wantH or ch
    -- Maximized, the actual size is the screen's, and growing the request to
    -- it would make Restore restore to full screen. The request is what Restore
    -- will apply, so the floor goes on that.
    if maxState.on then cw, ch = rw, rh end
    if cw >= w and ch >= h then return end
    -- The request is only trusted while it still explains the window: through
    -- SizeFor it gives the size the window has (the screen clamped it). A
    -- window that does NOT match was sized directly, and its request is stale
    -- (the #154 case), so the floor starts from the actual size there.
    local ew, eh = SizeFor(rw, rh)
    local stale = math.abs((ew or 0) - cw) > 0.5 or math.abs((eh or 0) - ch) > 0.5
    local bw, bh = rw, rh
    if stale then bw, bh = cw, ch end
    ResizeFrame(math.max(bw, w), math.max(bh, h))
end

-- A plugin that sizes the window to its own content (Raids) asks here rather
-- than calling SetSize: the request is remembered, clamped to the display, and
-- not applied while the window is maximized.
function AltStable.RequestWindowSize(w, h)
    ResizeFrame(w, h)
end

-- A plugin tab's PREFERRED size (#150), asked for when it opens, so it opens
-- the same whichever tab came before it and whichever account this is. Given as
-- the content panel's width beside the sidebar as it is now. Roster, Warband
-- and Professions share one window height, so moving between them never
-- changes it (Raids and Options size themselves). 660 fits
-- the owner's 3840x2160 with the UI scale off (1365 x 768 units, less the
-- margin) at addon scale 1. Smaller screens and larger scales clamp through
-- SizeFor as everything else does, and the tab's own floor still applies after.
AltStable.PLUGIN_WINDOW_H = 660
function AltStable.RequestPluginSize(panelW)
    ResizeFrame(SIDEBAR_WIDTH + 1 + panelW, AltStable.PLUGIN_WINDOW_H)
end
-- Forward-declared, because the hook below is registered before the function is
-- defined and a closure written above the `local` would capture a nil GLOBAL of
-- the same name instead - silently, and only failing when something calls it.
local ResizeFrameToContent
-- Registered HERE, not from inside the function body. It used to be assigned on
-- every call, which made the export depend on something having resized first -
-- so a reordering, or a refactor that made the earlier caller bail, would fail
-- the suite for a reason unrelated to what was being tested. It also rewrote a
-- table field on every roster refresh in game.
AltStable._test.ResizeFrameToContent = function() return ResizeFrameToContent() end

-- Re-apply the screen limit to the size the window already has. Called after a
-- scale change, which alters how much display the same numbers occupy without
-- going through either resize path.

-- Lay the current tab out again after the window's geometry changed under it -
-- maximize, restore, or the sidebar collapsing. A sheet section re-sizes to its
-- content; a plugin re-lays itself out in the space it now has.
local function RelayoutWindow()
    if not frame then return end
    if activeSection and activeSection._isPlugin then
        if activeSection.OnResize then activeSection.OnResize(frame) end
    elseif AltStable.RefreshSheet then
        AltStable.RefreshSheet()
    end
end

-- Re-apply the screen limit to the size the window already has. Called after a
-- scale change, which alters how much display the same numbers occupy without
-- going through either resize path.
function AltStable.RefitWindow()
    if not frame then return end
    FinishWindowAnimation()
    -- The remembered request, not the current size. See wantW/wantH above.
    frame:SetSize(SizeFor(wantW or frame:GetWidth(), wantH or frame:GetHeight()))
    -- Maximized, the window's size in its own units just changed with the
    -- scale, and the tab - spread columns, a plugin's layout - is still laid
    -- out for the old one.
    if maxState.on then RelayoutWindow() end
end

function AltStable.IsWindowMaximized() return maxState.on end

-- The CLIENT's scale and the display change the room too, and nothing refitted
-- the window for them (#191 review): a window clamped at a high WoW UI scale
-- stayed small after lowering it, and its remembered request then no longer
-- explained it, so the next floor took the clamped size for the request.
do
    local watch = CreateFrame("Frame")
    watch:RegisterEvent("UI_SCALE_CHANGED")
    watch:RegisterEvent("DISPLAY_SIZE_CHANGED")
    -- And the tab laid out again when that changed its size: RefitWindow
    -- does that only while maximized, and a plugin places its contents from
    -- the panel's size (Codex, #191) - Warband's columns and rail, the
    -- Roster's cards and scene would stay where the old size put them.
    watch:SetScript("OnEvent", function()
        if not frame then return end
        local w0, h0 = frame:GetWidth(), frame:GetHeight()
        AltStable.RefitWindow()
        if not maxState.on and (frame:GetWidth() ~= w0 or frame:GetHeight() ~= h0) then
            RelayoutWindow()
        end
    end)
    AltStable._test = AltStable._test or {}
    AltStable._test.displayWatch = watch
end

-- ANIMATING a change of the window's geometry (#150): maximize, restore, and
-- the sidebar collapsing or expanding.
--
-- The animation system moves, scales and fades; it cannot change a size. So
-- this is an OnUpdate tween, and it tweens only GEOMETRY - the window's rect
-- and the sidebar's width. The change is applied first, its end state
-- measured, the window put back where it started, and then it travels.
--
-- The tab is laid out ONCE, never per frame - the Roster scene rebuilds its
-- models - and WHEN is what keeps it inside the window without clipping:
--   * a sheet tab, first: its layout decides the window's size, and its grid
--     sits in scroll frames that clip themselves;
--   * a plugin tab whose space SHRINKS, first: the smaller layout fits inside
--     the window all the way down;
--   * a plugin tab whose space GROWS, at the end: the old layout fits inside
--     the window all the way up.
-- Clipping the window instead was tried and dropped: the client clipped the
-- children against a stale rect while the frame was being resized, and an
-- interrupted trip could leave it on - the title bar and the sidebar icons
-- came out cut (#150).
--
-- Interrupted - clicked again mid-way - it reverses from where it IS: the
-- running one is settled to its own end state first, so the new change starts
-- from a real anchor, while the new journey starts from the rect on screen.
--
-- Off with the open animation (Options), and whenever the window is not on
-- screen to watch.
local WINDOW_ANIM_TIME = 0.2

local function WindowAnimEnabled()
    return AltStableConfig and AltStableConfig.enableOpenAnimation
        and frame and frame:IsVisible() and frame:GetLeft() ~= nil
        and frame.sidebar ~= nil and UIParent ~= nil
end

-- `laidOut`: applyGeometry lays the tab out itself - a tab switch (#159): the
-- new tab sizes the window, then lays itself out at that size. It is not laid
-- out again, before the trip or after it, and a running trip is settled
-- without the layout it deferred - that was for the tab that is leaving.
local function AnimateWindowChange(applyGeometry, labels, laidOut)
    if not WindowAnimEnabled() then
        FinishWindowAnimation(laidOut)
        applyGeometry()
        if not laidOut then RelayoutWindow() end
        if labels then labels(1, true) end
        return
    end
    -- The open fade scales the window. Measured mid-fade, the rect below would
    -- be applied at a scale that is still moving, and the window drifted (#164
    -- review). The fade finishes first, as anything borrowing it does.
    if AltStable.FinishOpenAnimation then AltStable.FinishOpenAnimation() end
    local sb = frame.sidebar
    -- Where it is on screen now, mid-journey or not.
    local l0, b0 = frame:GetLeft(), frame:GetBottom()
    local w0, h0, s0 = frame:GetWidth(), frame:GetHeight(), sb:GetWidth()
    FinishWindowAnimation(laidOut)

    applyGeometry()
    -- A layout that runs before the trip may size the window itself - a sheet
    -- tab always does, Raids sizes to its grid, Warband holds its floor - so
    -- the end state is measured only AFTER it. A tab that sizes the window to
    -- its content is laid out first whichever way it goes, as a sheet tab is.
    local isPlugin = activeSection and activeSection._isPlugin
    local relayoutAtEnd = false
    if laidOut then
        -- Laid out by the switch, at the size it ends at.
    elseif not isPlugin or activeSection.sizesWindow then
        RelayoutWindow()
    else
        local grows = (frame:GetWidth() - sb:GetWidth() >= w0 - s0) and (frame:GetHeight() >= h0)
        if grows then relayoutAtEnd = true else RelayoutWindow() end
    end

    -- The end state, measured and remembered: settling restores these exactly
    -- rather than re-running the change.
    local points = {}
    for i = 1, (frame:GetNumPoints() or 0) do
        points[i] = { n = 5, frame:GetPoint(i) }
    end
    local l1, b1 = frame:GetLeft(), frame:GetBottom()
    local w1, h1, s1 = frame:GetWidth(), frame:GetHeight(), sb:GetWidth()

    -- Nothing moved - a tab switch between two tabs of one size, or any switch
    -- while maximized: no trip. The window already stands where it ends.
    if l1 == l0 and b1 == b0 and w1 == w0 and h1 == h0 and s1 == s0 then
        if labels then labels(1, true) end
        if relayoutAtEnd then RelayoutWindow() end
        return
    end

    local function Place(e)
        frame:ClearAllPoints()
        -- GetLeft and SetPoint offsets are both in the window's own scale.
        frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l0 + (l1 - l0) * e, b0 + (b1 - b0) * e)
        frame:SetSize(w0 + (w1 - w0) * e, h0 + (h1 - h0) * e)
        sb:SetWidth(s0 + (s1 - s0) * e)
        if labels then labels(e) end
    end
    windowAnim.settle = function(skipRelayout)
        frame:ClearAllPoints()
        for _, p in ipairs(points) do frame:SetPoint(unpack(p, 1, p.n)) end
        frame:SetSize(w1, h1)
        sb:SetWidth(s1)
        if labels then labels(1, true) end
        if relayoutAtEnd and not skipRelayout then RelayoutWindow() end
    end

    Place(0)
    local runner = windowAnim.runner or CreateFrame("Frame")
    windowAnim.runner = runner
    local elapsed = 0
    runner:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + (dt or 0)
        local p = math.min(1, elapsed / WINDOW_ANIM_TIME)
        if p >= 1 then
            self:SetScript("OnUpdate", nil)
            windowAnim.settle()
            return
        end
        Place(p * p * (3 - 2 * p))          -- smoothstep, as the open fade
    end)
    runner:Show()
end
AltStable._test.AnimateWindowChange = AnimateWindowChange
-- Public too (#150): Warband's Single/Combined switch resizes the window, and
-- glides there like a tab switch rather than jumping.
AltStable.AnimateWindowChange = AnimateWindowChange
AltStable._test.WindowAnimRunner = function() return windowAnim.runner end

function AltStable.SetWindowMaximized(on)
    if not frame then return end
    on = on and true or false
    if on == maxState.on then return end
    AnimateWindowChange(function()
    if on then
        -- Where it was, to go back to. Only the first anchor: the window has
        -- one (ApplyWindowPosition, or wherever a drag left it).
        local point, rel, relPoint, x, y = frame:GetPoint(1)
        maxState.point = point and { point, rel, relPoint, x, y } or nil
        wantW = wantW or frame:GetWidth()
        wantH = wantH or frame:GetHeight()
        maxState.on = true
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    else
        maxState.on = false
        frame:ClearAllPoints()
        local p = maxState.point
        if p then
            frame:SetPoint(p[1], p[2] or UIParent, p[3] or p[1], p[4] or 0, p[5] or 0)
        else
            frame:SetPoint("CENTER")
        end
        maxState.point = nil
    end
    frame:SetSize(SizeFor(wantW or frame:GetWidth(), wantH or frame:GetHeight()))
    if AltStable.OnWindowMaximizedChanged then AltStable.OnWindowMaximizedChanged(on) end
    end)
end

-- Anchor a panel's top-left beside the sidebar: where every plugin panel and
-- the Options panel starts, 1px past the divider, under the title bar. To the
-- sidebar's EDGE rather than a fixed offset from the window, so the panel
-- follows when the sidebar collapses (#150). Its other anchors stay the
-- caller's. Returns false with nothing to anchor to - a test's bare frame -
-- and the caller falls back to the fixed offset.
function AltStable.AnchorBesideSidebar(region, mainFrame)
    local sb = (mainFrame and mainFrame.sidebar) or (frame and frame.sidebar)
    if not sb then return false end
    region:SetPoint("TOPLEFT", sb, "TOPRIGHT", 1, 0)
    return true
end

local function SaveWindowPosition()
    if not (frame and AltStableConfig and AltStableConfig.rememberWindowPosition) then
        return
    end
    -- Maximized, the window is centred by the maximize, not placed by the
    -- user: the position to remember is the one Restore will go back to.
    if maxState.on then return end
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
    -- Maximized, the reset is where Restore goes: centred, not the old spot.
    if maxState.on then maxState.point = nil; return end
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
    -- The sidebar holds N navigation buttons and, pinned beneath them, the
    -- collapse chevron (#150) - SIDEBAR_BOTTOM_FOOTER reserves its room; the
    -- Filter row and Hide-below checkbox are long gone. Plugins can register
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

function ResizeFrameToContent()
    if not frame then return end
    FinishWindowAnimation()
    -- Plugins (Recipes, Options) manage their own sizing — don't fight them.
    if activeSection and activeSection._isPlugin then return end
    local w, h, needsH, needsV = ComputeContentSize()
    wantW, wantH = w, h
    -- Through the same clamp: a roster long enough to want more height than the
    -- display has is just as reachable as the Options tab asking for a fixed 760.
    -- Or the whole screen, while maximized.
    frame:SetSize(SizeFor(w, h))
    -- ComputeContentSize decides scrollbar visibility from row count and column
    -- width against the size it ASKED for.
    --
    -- That used to be the size the frame got, so the two were self-consistent by
    -- construction. They are not any more: the screen clamp can hand back
    -- something smaller, and then `needsH`/`needsV` describe a window that was
    -- not built. UpdateScroll re-measures from the real bodyScroll and corrects
    -- it - the failure mode is an extra vertical scrollbar appearing, not rows
    -- being stranded - but the guarantee this comment used to claim is gone, and
    -- claiming it anyway is how the next person trusts the wrong number.
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
    -- The Name header fills its strip like every other header does its slot:
    -- left at the height it was built with, it sat in the middle of a taller
    -- strip, with dead space above and below it (#161 review).
    if nameHeader then nameHeader:SetHeight(h) end
    if headerScroll then headerScroll:SetHeight(h) end
    if headerContent then headerContent:SetHeight(h) end
    -- Body scroll TOPLEFT anchors are handled by ApplyContentAnchors via
    -- BodyTopY(), which reads currentHeaderHeight. UpdateScroll always runs
    -- after this in SwitchSection, so no need to set anchors here.
end

-- The data underlay belongs to the TABLE.
--
-- It spans the body viewports - below the column headers, above the footer -
-- while a plugin panel starts at the title bar and runs down to the footer.
-- Left shown underneath one, the part of the panel that overlapped it was two
-- layers of pane and the part above it was one: a hard horizontal seam about
-- 30px below the title, and another near the bottom. Invisible while those
-- panels were opaque, which is why it has been there since the underlay was.
--
-- Called from BOTH routes, because a plugin button does not go through
-- SwitchSection - it swaps activeSection and calls OnActivate itself, and
-- putting this in one of the two would have covered the way back and not the
-- way in.
local function ShowDataUnderlay(show)
    if AltStable._dataBG then AltStable._dataBG:SetShown(show) end
end

local function SwitchSectionNow(section)
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

    ShowDataUnderlay(not section._isPlugin)

    -- Adjust header height for this section
    AdjustHeaderHeight(section.headerHeight or HEADER_HEIGHT)

    -- Highlight active sidebar button using theme accent
    local ar, ag, ab = AltStable.GetAccentRGB()
    for _, btn in ipairs(sidebarBtns) do
        if btn.sectionId == section.id then
            AltStable.SkinButtonActive(btn)
            btn.lbl:SetTextColor(ar, ag, ab)
            if btn.icon then btn.icon:SetAlpha(1.0) end
            AltStable.SkinStripe(btn.accentStripe, true, ar, ag, ab)
        else
            AltStable.SkinButtonIdle(btn)
            btn.lbl:SetTextColor(AltStable.SkinNavDim())
            if btn.icon then btn.icon:SetAlpha(0.65) end
            AltStable.SkinStripe(btn.accentStripe, false)
        end
    end

    BuildScrollableColsForSection(section)
    -- This tab's own sort (#160), checked against the columns it now has.
    if not section._isPlugin then LoadSortFor(section) end
    AdjustHeaderHeight(AltStable.HeaderHeightFor(scrollableCols, section.headerHeight or HEADER_HEIGHT))
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

-- A tab switch glides to the new tab's size, as maximize does (#159). The tab
-- is built at once at its own size; only the window's rect travels, and the
-- grid clips itself in its scroll frames on the way.
local function SwitchSection(section)
    AnimateWindowChange(function() SwitchSectionNow(section) end, nil, true)
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
    -- The window is either a flat backdrop or the glass material, never both:
    -- a backdrop is an opaque square, and inside a rounded body it would draw
    -- the corners straight back on - the same mistake the fills below make.
    -- Tooltips raised from anywhere inside this window are ours; the plugins'
    -- panels are its children, so one mark covers them. See MarkTooltipHost.
    -- (The hooks go in at the END of this function, not here: see below.)
    if AltStable.MarkTooltipHost then AltStable.MarkTooltipHost(frame) end
    AltStable.glass = AltStable.SkinWindow(frame)
    if not AltStable.glass then
        AltStable.ApplyBackdrop(frame,
            AltStable.C.BG_MAIN[1], AltStable.C.BG_MAIN[2],
            AltStable.C.BG_MAIN[3], AltStable.C.BG_MAIN[4])
    end
    frame:SetScale(AltStableConfig.scale or 1.0)
    -- Fitting is not the same as being ON the display. The position is
    -- remembered from whenever it was last dragged, and a window that fits can
    -- still have been saved with its bottom past the edge - which is what the
    -- Options tab did, because growing taller moves the bottom down while the
    -- saved anchor holds the top still.
    frame:SetClampedToScreen(true)
    AltStable._test = AltStable._test or {}
    AltStable._test.frame = frame
    frame:SetMovable(true)
    -- THE WINDOW EATS THE MOUSE (#74).
    --
    -- It did not, and the comment here said "drag handled by titleBar" - true,
    -- and it is why nobody noticed the rest. A frame with the mouse disabled is
    -- transparent to it, so the 3D world underneath kept receiving mouseover
    -- through every part of this window that is not a row or a button: the
    -- sidebar, the gaps between rows, the footer, the whole panel on a plugin
    -- tab. In a city that is a unit tooltip following your cursor across the
    -- sheet the entire time, and the glass made it plain because you can see
    -- the player standing behind the window.
    --
    -- Dragging still belongs to the title bar; enabling the mouse here only
    -- stops clicks and hovers falling through to the world behind.
    frame:EnableMouse(true)
    -- Recorded at BUILD, because by the time a test can look, a capture's
    -- blackout may have turned it off and its restore turned it back on - so
    -- "the window takes the mouse" answers yes either way and the decision
    -- made here goes unasserted.
    AltStable._test.frameMouseAtBuild = frame:IsMouseEnabled()

    -- AND THE MOUSE FOLLOWS THE ALPHA, whoever sets it.
    --
    -- An invisible frame that still takes the mouse is a dead zone with nothing
    -- on screen to explain it, and this window is hidden by ALPHA in three
    -- different places - the open fade, its own capture blackout, and the
    -- probe's, which is a separate addon reaching in and knows nothing about
    -- any contract of ours. Pairing EnableMouse with each SetAlpha by hand
    -- covers the ones we can see and misses that third one entirely.
    --
    -- Hooked, so it cannot be missed: invisible means click-through, by
    -- construction, with no timing assumption about when a capture ends. The
    -- hook writes EnableMouse, never SetAlpha, so it cannot call itself.
    if type(hooksecurefunc) == "function" then
        hooksecurefunc(frame, "SetAlpha", function(self, a)
            self:EnableMouse((tonumber(a) or 1) > 0)
        end)
    end
    tinsert(UISpecialFrames,"AltStableSheet")
    -- A PARENT'S HIDE IS NOT A CLOSE. Hiding UIParent - a portrait capture, or
    -- Alt+Z - fires OnHide on every child still shown, this window included
    -- when it sits under UIParent, and showing it again fires OnShow. Neither
    -- is the player closing or opening the sheet, and treating them as such
    -- tore the showcase down mid-capture and replayed the whole opening
    -- afterwards. The window can tell for itself: after a parent's hide its
    -- own shown flag is still set. That replaced a `capturing` flag another
    -- file set for the whole capture, which could not tell a parent's hide
    -- from a REAL close in the middle of one - so Alt+Z mid-capture closed the
    -- sheet and left the camera showcase running with nothing to end it (#89).
    local hiddenByParent = false
    frame:SetScript("OnShow", function()
        if hiddenByParent then
            hiddenByParent = false      -- the parent came back; we never left
            return
        end
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
    -- The sheet CLOSING, however it happens.
    local function Closed()
        hiddenByParent = false
        -- The character menu goes with the window that raised it (#69). It is
        -- FULLSCREEN_DIALOG with a full-screen click-catcher under it, so a
        -- menu outliving the sheet is not a stray widget - it is an invisible
        -- sheet of glass over the whole game that eats every click until
        -- something else closes it.
        if AltStable.CloseCharacterMenu then AltStable.CloseCharacterMenu() end
        if AltStableCameraPresentation and AltStableCameraPresentation.Exit then
            AltStableCameraPresentation:Exit("sheet-hide")
        end
    end
    frame:SetScript("OnHide", function()
        if frame:IsShown() then
            hiddenByParent = true       -- see OnShow: not a close
            return
        end
        Closed()
    end)
    -- Closed while its parent is ALREADY hidden - Escape during a capture with
    -- the sheet under UIParent. The window was not visible, so the client
    -- fires no OnHide: without this nothing ends the showcase, and the stale
    -- `hiddenByParent` swallows the next real open's OnShow.
    if type(hooksecurefunc) == "function" then
        hooksecurefunc(frame, "Hide", function()
            if hiddenByParent then Closed() end
        end)
    end

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
    -- A maximized window stays put (and SaveWindowPosition will not record its
    -- centred position: Restore goes back to where it was).
    titleBar:SetScript("OnDragStart", function()
        if maxState.on then return end
        frame:StartMoving()
    end)
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

    -- Under glass the band is lighter than the body rather than darker, and is
    -- clipped to the window so it stops squaring off the top corners. Called
    -- after both textures exist because it restyles them in place.
    AltStable.SkinTitleBand(titleBar, frame, tbBg, tbSep)
    -- Exposed so a test can prove the CALL happens, not merely that the helper
    -- works when called: the helper had fifteen assertions on it and the line
    -- that invokes it had none, so deleting this line changed nothing the suite
    -- could see.
    AltStable._test = AltStable._test or {}
    AltStable._test.titleBar, AltStable._test.titleBarBG = titleBar, tbBg
    -- The nav buttons, so a test can ask what SwitchSection actually painted.
    -- Twice now a helper has been fully asserted while the line calling it had
    -- no coverage at all, and deleting the call changed nothing the suite saw.
    AltStable._test.sidebarBtns = sidebarBtns

    -- Title text — centered across the full width of the title bar.
    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    titleText:SetText("AltStable")
    -- Centred over a band the world shows through, so it needs the shadow.
    AltStable.SkinText(titleText)
    AltStable._test.titleText = titleText
    local function UpdateTitleTextColor()
        titleText:SetTextColor(AltStable.SkinTitleColor())
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

    -- The portrait capture button (#89). The capture is Capture.lua: it hides
    -- the interface, borrows this window's ALPHA rather than hiding it (OnHide
    -- would tear the camera showcase down; the SetAlpha hook above gives the
    -- mouse back with it) and restores everything on every way out. This
    -- button used to run a second, single-screenshot path of its own for the
    -- retired armory pipeline, which nothing read.
    local function CapturePortraitFromSheet()
        if AltStable.CapturePortrait then AltStable.CapturePortrait() end
    end

    -- Maximize / restore (#150). The glyph is drawn, not typed: one outlined
    -- box to maximize, two overlapping ones to restore, as every OS shows it.
    local maxBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    maxBtn:SetSize(18, 18)
    maxBtn:SetPoint("RIGHT", close, "LEFT", -6, 0)
    maxBtn:SetFrameLevel(titleBar:GetFrameLevel() + 5)
    AltStable.ApplyBackdrop(maxBtn, 0.12, 0.12, 0.12, 1)
    local function Box(w, h, x, y)
        local box = {}
        local function Edge(p1, p2, ew, eh)
            local t = maxBtn:CreateTexture(nil, "OVERLAY")
            t:SetColorTexture(0.87, 0.87, 0.87, 1)
            if ew then t:SetWidth(ew) else t:SetHeight(eh) end
            t:SetPoint(p1[1], maxBtn, "CENTER", x + p1[2], y + p1[3])
            t:SetPoint(p2[1], maxBtn, "CENTER", x + p2[2], y + p2[3])
            box[#box + 1] = t
        end
        local hw, hh = w / 2, h / 2
        Edge({ "TOPLEFT", -hw, hh },     { "TOPRIGHT", hw, hh },       nil, 2)  -- the title edge
        Edge({ "BOTTOMLEFT", -hw, -hh }, { "BOTTOMRIGHT", hw, -hh },   nil, 1)
        Edge({ "TOPLEFT", -hw, hh },     { "BOTTOMLEFT", -hw, -hh },   1)
        Edge({ "TOPRIGHT", hw, hh },     { "BOTTOMRIGHT", hw, -hh },   1)
        return box
    end
    local glyphMax     = Box(10, 8, 0, 0)
    local glyphRestore = Box(7, 6, 1.5, 1.5)
    for _, t in ipairs(Box(7, 6, -1.5, -1.5)) do glyphRestore[#glyphRestore + 1] = t end
    local function ShowGlyph()
        local on = maxState.on
        for _, t in ipairs(glyphMax)     do if on then t:Hide() else t:Show() end end
        for _, t in ipairs(glyphRestore) do if on then t:Show() else t:Hide() end end
    end
    ShowGlyph()
    local function MaxTip()
        GameTooltip:SetOwner(maxBtn, "ANCHOR_BOTTOMLEFT")
        GameTooltip:SetText(maxState.on and "Restore size" or "Maximize")
        GameTooltip:Show()
    end
    maxBtn:SetScript("OnClick", function()
        AltStable.SetWindowMaximized(not maxState.on)
        if GameTooltip:IsOwned(maxBtn) then MaxTip() end
    end)
    maxBtn:SetScript("OnEnter", function()
        maxBtn:SetBackdropColor(0.22, 0.22, 0.22, 1)
        MaxTip()
    end)
    maxBtn:SetScript("OnLeave", function()
        maxBtn:SetBackdropColor(0.12, 0.12, 0.12, 1)
        if GameTooltip:IsOwned(maxBtn) then GameTooltip:Hide() end
    end)
    AltStable.OnWindowMaximizedChanged = function() ShowGlyph() end
    AltStable._test.maxBtn = maxBtn
    AltStable._test.MaxGlyphs = function() return glyphMax, glyphRestore end

    local refBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    refBtn:SetSize(18, 18)
    refBtn:SetPoint("RIGHT", maxBtn, "LEFT", -6, 0)
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
    -- A floating surface with its own outline, even though it is parented to
    -- the sheet: TOOLTIP strata, toplevel, its own frame level, and it draws
    -- clear of the window. So it gets the material like the menu and the toast
    -- rather than being left as one flat panel beside them.
    if not AltStable.SkinWindow(refTip, "small") then
        AltStable.ApplyBackdrop(refTip, 0.05, 0.05, 0.05, 0.96)
    end
    local refTipText = refTip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    AltStable.SkinText(refTipText)
    AltStable._test.refTip, AltStable._test.refTipText = refTip, refTipText
    -- The button, so a test can drive the REAL hover rather than calling the
    -- re-levelling helper itself - the bug was the hover not calling it.
    AltStable._test.refBtn = refBtn
    AltStable._test.CapturePortraitFromSheet = CapturePortraitFromSheet
    refTipText:SetPoint("TOPLEFT", 9, -8)
    refTipText:SetPoint("BOTTOMRIGHT", -9, 8)
    refTipText:SetJustifyH("LEFT"); refTipText:SetJustifyV("TOP")
    -- The Companion is said up front (owner's call, #124): without it the two
    -- screenshots never become a portrait, and the button gives no other hint.
    local REF_TIP_BASE = "|cffffffffCapture portrait|r\n|cffbbbbbbHides the interface for about " ..
        "three seconds and takes two screenshots for the Roster lineup. You will be " ..
        "offered a reload afterwards, so the capture is saved.|r\n" ..
        AltStable.COMPANION_NEEDED
    refTipText:SetText(REF_TIP_BASE)
    refTip:Hide()

    -- The "a new capture is due" glow (#128): a soft pulse behind the icon, off
    -- in combat, off with /alts portrait glow off. The tooltip says why.
    local refGlow = refBtn:CreateTexture(nil, "ARTWORK")
    refGlow:SetPoint("CENTER")
    refGlow:SetSize(30, 30)
    refGlow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    refGlow:SetBlendMode("ADD")
    refGlow:SetVertexColor(1, 0.82, 0.25)
    refGlow:Hide()
    local pulse = refGlow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(0.25)
    fade:SetToAlpha(1)
    fade:SetDuration(0.9)
    local STATUS_LINE = {
        missing = "|cffffd100No portrait for this character yet.|r",
        pending = "|cff88cc88Captured - waiting for AltStable Companion to turn it into a portrait.|r",
    }
    -- inCombat: said by the caller when it knows (Capture's combat events: at
    -- PLAYER_REGEN_DISABLED the lockdown has not started yet), asked otherwise.
    function AltStable.UpdateCaptureGlow(status, inCombat)
        status = status or (AltStable.CurrentPortraitStatus and AltStable.CurrentPortraitStatus())
        if not status then return end
        if inCombat == nil then
            inCombat = (InCombatLockdown and InCombatLockdown())
                or (UnitAffectingCombat and UnitAffectingCombat("player")) or false
        end
        local line = STATUS_LINE[status.reason]
        if status.reason == "changed" then
            line = "|cffffd100Your gear changed since the last portrait (" ..
                table.concat(status.changedSlots, ", ") .. ").|r"
        end
        refTipText:SetText(line and (REF_TIP_BASE .. "\n\n" .. line) or REF_TIP_BASE)
        -- As tall as the text: a "changed" line lists any number of slots, and
        -- a fixed height cut off the reason the tooltip is there to give.
        local textH = refTipText.GetStringHeight and tonumber(refTipText:GetStringHeight())
        refTip:SetHeight(textH and textH > 0 and (textH + 18) or (line and 92 or 62))
        local on = status.due
            and not (AltStableConfig and AltStableConfig.portraitGlow == false)
            and not inCombat
        refBtn._glowing = on and true or false
        if on then refGlow:Show(); pulse:Play() else pulse:Stop(); refGlow:Hide() end
    end
    AltStable._test.refGlow = refGlow
    -- Built after the status may already be known (the sheet is built lazily).
    AltStable.UpdateCaptureGlow()

    refBtn:SetScript("OnClick", CapturePortraitFromSheet)
    -- The title-bar capture button, reachable from a test. Both it and the
    -- handler are locals in here.
    AltStable._test = AltStable._test or {}
    AltStable._test.ClickCaptureButton = function()
        local fn = refBtn:GetScript("OnClick")
        if fn then fn(refBtn) end
    end
    refBtn:SetScript("OnEnter", function()
        refBtn:SetBackdropColor(0.22, 0.22, 0.22, 1)
        refTip:Show()
        refTip:Raise()
        -- Raise() moves the HOST. The material's rim is a child frame pinned to
        -- host level + 10 when it was applied, so raising the tooltip climbs it
        -- above its own outline and its body then draws over the rim - from the
        -- second hover onwards it would have been a bare panel with no edge.
        AltStable.SkinRelevel(refTip)
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
    -- What sits beside the sidebar anchors to its right edge, so it follows
    -- when the sidebar collapses (#150). See AltStable.AnchorBesideSidebar.
    frame.sidebar = sidebar
    -- Under glass the sidebar shows the material through instead of covering it
    -- with a panel of its own: it is a region OF the window rather than a card
    -- sitting on one, and its fill is what squares off both left corners.
    if not AltStable.SkinIsGlass() then
        AltStable.ApplyBGOnly(sidebar,
            AltStable.C.BG_SIDEBAR[1], AltStable.C.BG_SIDEBAR[2],
            AltStable.C.BG_SIDEBAR[3], AltStable.C.BG_SIDEBAR[4])
    end

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

    -- Compact (#150): the label is the button's tooltip instead.
    local function NavTip(btn, label)
        if not (AltStableConfig and AltStableConfig.sidebarCompact) then return end
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:SetText(label or "")
        GameTooltip:Show()
    end
    local function NavTipHide(btn)
        if GameTooltip:IsOwned(btn) then GameTooltip:Hide() end
    end

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
        lbl:SetTextColor(AltStable.SkinNavDim())
        btn.lbl=lbl; btn.icon=icon

        btn:SetScript("OnClick",function() SwitchSection(section) end)
        btn:SetScript("OnEnter",function()
            if activeSection.id~=section.id then
                AltStable.SkinButtonHover(btn)
                lbl:SetTextColor(unpack(AltStable.C.TEXT_BRIGHT))
                icon:SetAlpha(0.85)
            end
            NavTip(btn, section.label)
        end)
        btn:SetScript("OnLeave",function()
            if activeSection.id~=section.id then
                AltStable.SkinButtonIdle(btn)
                lbl:SetTextColor(AltStable.SkinNavDim())
                icon:SetAlpha(0.78)
            end
            NavTipHide(btn)
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
    -- Math: btnY starts at -8 (top inset) and decrements by one step per
    -- button. _pluginBtnY is the next-empty-Y after all buttons. Below the
    -- last one: the collapse chevron (#150) and 8px of breathing space.
    local SIDEBAR_TOP_INSET     = 8
    local SIDEBAR_BOTTOM_FOOTER = 26     -- the collapse chevron (#150)
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
        lbl:SetTextColor(AltStable.SkinNavDim())
        pbtn.lbl=lbl; pbtn.icon=icon

        pbtn:SetScript("OnClick",function()
            for _, b in ipairs(sidebarBtns) do
                AltStable.SkinButtonIdle(b)
                if b.lbl then b.lbl:SetTextColor(AltStable.SkinNavDim()) end
                AltStable.SkinStripe(b.accentStripe, false)
                if b.icon then b.icon:SetAlpha(0.78) end
            end
            AltStable.SkinButtonActive(pbtn)
            local ar, ag, ab = AltStable.GetAccentRGB()
            AltStable.SkinStripe(stripe, true, ar, ag, ab)
            lbl:SetTextColor(ar, ag, ab)
            icon:SetAlpha(1.0)
            -- Animated like a sheet tab (#159): every plugin sizes the window in
            -- OnActivate (Raids to its grid, Options, the others to their
            -- preferred size, #150) and glides there. It is laid out at its end
            -- size first, so a growing trip can show it past the window's edge
            -- for the fifth of a second the trip lasts.
            AnimateWindowChange(function()
                if activeSection._isPlugin and activeSection.OnDeactivate then
                    activeSection.OnDeactivate(frame)
                end
                activeSection = plugin
                ShowDataUnderlay(false)
                plugin.OnActivate(frame)
            end, nil, true)
        end)
        pbtn:SetScript("OnEnter",function()
            if activeSection.id~=plugin.id then
                AltStable.SkinButtonHover(pbtn)
                lbl:SetTextColor(unpack(AltStable.C.TEXT_BRIGHT))
                icon:SetAlpha(0.85)
            end
            NavTip(pbtn, plugin.label)
        end)
        pbtn:SetScript("OnLeave",function()
            if activeSection.id~=plugin.id then
                AltStable.SkinButtonIdle(pbtn)
                lbl:SetTextColor(AltStable.SkinNavDim())
                icon:SetAlpha(0.78)
            end
            NavTipHide(pbtn)
        end)
        -- A plugin registering late joins a sidebar that may already be compact.
        if AltStableConfig and AltStableConfig.sidebarCompact then lbl:Hide() end

        table.insert(sidebarBtns,pbtn)
        sidebar._pluginBtnY = sidebar._pluginBtnY - SIDEBAR_BUTTON_STEP
        return pbtn
    end

    -- Render any plugins already registered before the frame was built
    for _, plugin in ipairs(AltStable.plugins) do
        MakePluginButton(plugin)
    end

    -- Expose so late-registering plugins (loaded after SheetUI) get a button
    AltStable.AddPluginButton = MakePluginButton

    -- Collapse / expand the sidebar (#150): a chevron pinned to its bottom.
    -- Collapsed, only the icons show and each label is its tooltip. Saved per
    -- account. A sheet tab re-sizes to its content, so its window narrows; a
    -- plugin tab keeps the window and gets the width.
    local chevron = CreateFrame("Button", nil, sidebar)
    chevron:SetHeight(22)
    chevron:SetPoint("BOTTOMLEFT",  sidebar, "BOTTOMLEFT",  0, 4)
    chevron:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", 0, 4)
    local chevronText = chevron:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    chevronText:SetAllPoints()
    chevronText:SetJustifyH("CENTER")
    AltStable.SkinText(chevronText)
    local function ChevronTip()
        GameTooltip:SetOwner(chevron, "ANCHOR_RIGHT")
        GameTooltip:SetText(AltStableConfig.sidebarCompact and "Expand menu" or "Collapse menu")
        GameTooltip:Show()
    end
    -- The labels as the mode wants them, settled: shown at full alpha, or gone.
    local function SettleLabels(compact)
        for _, b in ipairs(sidebarBtns) do
            if b.lbl then
                b.lbl:SetAlpha(1)
                if compact then b.lbl:Hide() else b.lbl:Show() end
            end
        end
    end
    local function ApplySidebarMode()
        local compact = AltStableConfig.sidebarCompact and true or false
        SIDEBAR_WIDTH = compact and SIDEBAR_COMPACT_W or SIDEBAR_FULL_W
        AltStable.LAYOUT.SIDEBAR_WIDTH = SIDEBAR_WIDTH
        sidebar:SetWidth(SIDEBAR_WIDTH - 1)
        SettleLabels(compact)
        -- The guillemets: \194\187 (>>) collapses, \194\171 (<<) expands.
        chevronText:SetText(compact and "\194\171" or "\194\187")
        chevronText:SetTextColor(AltStable.SkinNavDim())
    end
    ApplySidebarMode()
    function AltStable.SetSidebarCompact(on)
        on = on and true or false
        if on == (AltStableConfig.sidebarCompact and true or false) then return end
        AltStable.SetConfigValue("sidebarCompact", on)
        -- The labels fade with the travel: out in the first half of a
        -- collapse, in over the second half of an expand, once there is room.
        local function FadeLabels(e, done)
            if done then SettleLabels(on); return end
            for _, b in ipairs(sidebarBtns) do
                if b.lbl then
                    b.lbl:Show()
                    b.lbl:SetAlpha(on and math.max(0, 1 - e * 2) or math.max(0, e * 2 - 1))
                end
            end
        end
        AnimateWindowChange(ApplySidebarMode, FadeLabels)
    end
    chevron:SetScript("OnClick", function()
        AltStable.SetSidebarCompact(not AltStableConfig.sidebarCompact)
        if GameTooltip:IsOwned(chevron) then ChevronTip() end
    end)
    chevron:SetScript("OnEnter", function()
        chevronText:SetTextColor(unpack(AltStable.C.TEXT_BRIGHT))
        ChevronTip()
    end)
    chevron:SetScript("OnLeave", function()
        chevronText:SetTextColor(AltStable.SkinNavDim())
        if GameTooltip:IsOwned(chevron) then GameTooltip:Hide() end
    end)
    AltStable._test.chevron, AltStable._test.chevronText = chevron, chevronText

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
    AltStable.AnchorBesideSidebar(optionsPanel, frame)
    optionsPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 1)
    optionsPanel:Hide()

    -- Background
    local optBG = optionsPanel:CreateTexture(nil, "BACKGROUND")
    optBG:SetAllPoints()
    optBG:SetColorTexture(AltStable.SkinTabBG())
    AltStable._test.optBG = optBG
    -- Reaches BOTTOMRIGHT (0, 1), so it owns the window's bottom-right corner on
    -- this tab. Already a texture rather than a backdrop, so it only needs
    -- clipping to the window outline, not replacing.
    AltStable.SkinClipTexture(optionsPanel, optBG, frame)

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

    -- EVERY anchor to this page is measured from its TOP (#151, #158 review):
    -- its height changes as the lists below grow and shrink, so an anchor to
    -- its middle or bottom would move on its own. A control that needs the
    -- page's right edge at a row's centre line anchors to an OptRail instead.
    local function OptRail(topY, h)
        local rail = CreateFrame("Frame", nil, optionsFrame)
        rail:SetPoint("TOPLEFT", P, topY)
        rail:SetPoint("TOPRIGHT", -P, topY)
        rail:SetHeight(h)
        return rail
    end

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

    -- The pressed state both choice rows use. Hoisted out of the Theme row so
    -- the Skin row above can wear it too: one selected look, not two that drift.
    -- The selected one gets an accent fill, an accent border and an accent
    -- label - text colour alone was too subtle to read as "active" (#5).
    local function SetChoiceBtnState(btn, lbl, active)
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

    -- ── Skin row (#108) ───────────────────────────────────
    -- The material was reachable only from `/alts skin`, so a player who never
    -- read the release notes never knew there was one. Built FROM the table
    -- rather than three hard-coded buttons, so a fourth preset appears here on
    -- its own - with flat first, because it is the unstyled one and the order
    -- should read as "none, then these".
    local optSkinLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    optSkinLabel:SetPoint("TOPLEFT", P, Y)
    optSkinLabel:SetText("Skin")
    optSkinLabel:SetTextColor(unpack(AltStable.C.TEXT_NORM))

    local skinNames = {}
    for name in pairs(AltStable.SKINS or {}) do skinNames[#skinNames + 1] = name end
    table.sort(skinNames, function(a, b)
        if (a == "flat") ~= (b == "flat") then return a == "flat" end
        return a < b
    end)

    local skinBtns = {}
    local RefreshSkinRow
    local prevSkinBtn
    for _, name in ipairs(skinNames) do
        local preset = AltStable.SKINS[name]
        local b = CreateFrame("Button", nil, optionsFrame, "BackdropTemplate")
        b:SetSize(96, 22)
        if prevSkinBtn then b:SetPoint("LEFT", prevSkinBtn, "RIGHT", 8, 0)
        else b:SetPoint("TOPLEFT", P + 60, Y + 1) end
        AltStable.ApplyBackdrop(b, 0.12, 0.12, 0.12, 1)
        local lbl = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetAllPoints(); lbl:SetJustifyH("CENTER")
        lbl:SetText(preset.label or name)
        b.skinName, b.lbl = name, lbl
        b:SetScript("OnClick", function()
            AltStable.SetConfigValue("skin", name)
            RefreshSkinRow()
        end)
        skinBtns[#skinBtns + 1] = b
        prevSkinBtn = b
    end

    -- WHAT IS ON DISK vs WHAT IS ON SCREEN. The material is built when the
    -- window is, so choosing one here changes the next load, not this one -
    -- and saying so only when they disagree keeps a permanent instruction off
    -- a panel where nothing is pending.
    --
    -- ON ITS OWN ROW, and measured rather than guessed.
    --
    -- Beside the buttons is where this was, to avoid holding a line open in the
    -- state where nothing is pending - but the OPTIONS VIEWPORT is not the 820
    -- the tab asks for: the sidebar and the scrollbar take it to about 563, the
    -- three choices already end near 382, and what was left could not hold the
    -- message, let alone the button after it. The Reload button was pushed off
    -- the right edge, in a panel that scrolls vertically only, so the one
    -- action the row exists to offer could not be reached at all.
    --
    -- So: the BUTTON is pinned to the right edge, and the message is bounded
    -- between the choices and the button. Neither can push the other out, at
    -- this width or at a clamped one. Twenty-four quiet pixels on a login where
    -- nothing is pending is a cheaper thing to spend than a Reload nobody can
    -- click.
    Y = Y - 24

    local optSkinReloadBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    optSkinReloadBtn:SetSize(80, 20)
    optSkinReloadBtn:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -P, Y)
    optSkinReloadBtn:SetText("Reload")

    local optSkinReload = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- LEFT/RIGHT, not TOPLEFT/RIGHT: two corners at one y give a font string
    -- no height at all, which is its own bug in this file's history.
    optSkinReload:SetPoint("LEFT", optionsFrame, "TOPLEFT", P + 60, Y - 10)
    optSkinReload:SetPoint("RIGHT", optSkinReloadBtn, "LEFT", -10, 0)
    optSkinReload:SetJustifyH("LEFT")
    optSkinReload:SetWordWrap(false)
    optSkinReload:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    -- Through the secure prompt: ReloadUI() from our own click is blocked on
    -- this client (see AltStable.ShowReloadPrompt).
    optSkinReloadBtn:SetScript("OnClick", function()
        if not AltStable.ShowReloadPrompt("Reload now to put on the new skin?") then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable]|r type |cffffff00/reload|r "
                .. "once the fight is over to put on the new skin.")
        end
    end)

    AltStable._test.SkinReloadButton = function() return optSkinReloadBtn end
    AltStable._test.SkinReloadText = function() return optSkinReload end

    RefreshSkinRow = function()
        local pending = AltStable.PendingSkinName()
        for _, b in ipairs(skinBtns) do
            SetChoiceBtnState(b, b.lbl, b.skinName == pending)
        end
        -- Against what the WINDOW is wearing, which is resolved once per
        -- session: choosing the one already loaded is not a pending change.
        local waiting = pending ~= AltStable.SkinName()
        optSkinReload:SetText(waiting
            and ("|cffffcc00" .. (AltStable.SKINS[pending] and AltStable.SKINS[pending].label
                 or pending) .. "|r takes effect after a reload") or "")
        optSkinReload:SetShown(waiting)
        optSkinReloadBtn:SetShown(waiting)
    end
    RefreshSkinRow()
    AltStable._test.RefreshSkinRow = RefreshSkinRow
    AltStable._test.optionsPanel = optionsPanel
    AltStable._test.skinBtns = skinBtns
    AltStable._test.SkinReloadPrompt = function()
        return optSkinReload:IsShown() and optSkinReload:GetText() or nil
    end

    Y = Y - 30

    -- Accent row
    local optThemeLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    optThemeLabel:SetPoint("TOPLEFT", P, Y)
    -- ACCENT, not "Theme". It changes one colour - the gold highlight - and
    -- nothing else: not a background, not a row, not a border. Calling that
    -- the theme is what made the material above look like it had nowhere to
    -- live. The stored values stay `dark` and `class`, because they are on
    -- disk in everybody's SavedVariables and a label is not worth a migration.
    optThemeLabel:SetText("Accent")
    optThemeLabel:SetTextColor(unpack(AltStable.C.TEXT_NORM))

    local BTNY = Y + 1   -- vertically aligned with label text
    local BTN_W, BTN_H = 72, 22

    local optDarkBtn = CreateFrame("Button", nil, optionsFrame, "BackdropTemplate")
    optDarkBtn:SetSize(BTN_W, BTN_H)
    optDarkBtn:SetPoint("TOPLEFT", P + 60, BTNY)
    AltStable.ApplyBackdrop(optDarkBtn, 0.12, 0.12, 0.12, 1)
    local optDarkLbl = optDarkBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optDarkLbl:SetAllPoints(); optDarkLbl:SetJustifyH("CENTER"); optDarkLbl:SetText("Gold")

    local optClassBtn = CreateFrame("Button", nil, optionsFrame, "BackdropTemplate")
    optClassBtn:SetSize(BTN_W, BTN_H)
    optClassBtn:SetPoint("LEFT", optDarkBtn, "RIGHT", 8, 0)
    AltStable.ApplyBackdrop(optClassBtn, 0.12, 0.12, 0.12, 1)
    local optClassLbl = optClassBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optClassLbl:SetAllPoints(); optClassLbl:SetJustifyH("CENTER")
    optClassLbl:SetText("Class colour")

    -- Theme hint text (to right of buttons)
    local optThemeHint = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optThemeHint:SetPoint("LEFT", optClassBtn, "RIGHT", 14, 0)
    optThemeHint:SetPoint("RIGHT", OptRail(BTNY, BTN_H), "RIGHT", 0, 0)
    optThemeHint:SetJustifyH("LEFT"); optThemeHint:SetWordWrap(true)
    optThemeHint:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    optThemeHint:SetText("The highlight colour - the gold in the title, the "
        .. "selected tab and the totals.")

    -- No callbacks, no side effects: must NOT call ApplyTheme or SwitchSection.
    local SetThemeBtnState = SetChoiceBtnState
    local function RefreshThemeBtns()
        local cur = AltStableConfig and AltStableConfig.theme or "dark"
        SetThemeBtnState(optDarkBtn,  optDarkLbl,  cur == "dark")
        SetThemeBtnState(optClassBtn, optClassLbl, cur ~= "dark")
    end
    -- Sync when accent changes (sidebar callback won't call SwitchSection)
    AltStable.RegisterThemeCallback(function()
        if optionsPanel:IsShown() then
            RefreshThemeBtns()
            -- The skin row's selected button is painted in the accent too, so
            -- it goes stale on exactly the same event.
            RefreshSkinRow()
        end
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

    -- 34, not 30: the hint beside the buttons is centred on them and wraps to
    -- three lines in a narrow window, reaching about 28 below the row.
    Y = Y - 34

    -- The distinction the row's own hint has no room for: the accent is one
    -- colour for the UI, not what colours the character rows. It used to sit
    -- at the very bottom of the page, a long scroll away from the row it
    -- explains (#151).
    local optHint = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optHint:SetPoint("TOPLEFT", P + 60, Y)
    optHint:SetPoint("TOPRIGHT", -P, Y)
    optHint:SetJustifyH("LEFT"); optHint:SetWordWrap(true)
    optHint:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    optHint:SetText("Character names and rows always use each character's own class "
        .. "colour, whichever accent is chosen.")
    AltStable._test.OptAccentFootnote = optHint
    Y = Y - 30

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
        optModelDebugHint:SetPoint("TOPRIGHT", -P, Y - 16)
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
    -- the heading and hint render above empty space. LOD_PLUGINS holds Warband
    -- and Raids; Recipes (#14) and Roster (#15) are still to come.
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
        optPluginsHint:SetPoint("TOPRIGHT", -P, Y - 2)
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

    -- Off unless asked for (#75), so the getter is "== true", not the helper's
    -- "~= false".
    local optPetsCheck = MakeOptCheckRow("rosterPets",
        "Show hunter pets and warlock demons in the Roster scene", Y,
        function(checked)
            AltStable.SetConfigValue("rosterPets", checked)
            if AltStable.RefreshSheet then AltStable.RefreshSheet() end
        end,
        function() return AltStableConfig and AltStableConfig.rosterPets == true end)
    Y = Y - 22

    -- Off unless asked for (#94): words over the figure are clutter to some.
    local optEnchantsCheck = MakeOptCheckRow("rosterEnchants",
        "Show enchants beside the gear slots on a Roster character", Y,
        function(checked)
            AltStable.SetConfigValue("rosterEnchants", checked)
            if AltStable.RefreshSheet then AltStable.RefreshSheet() end
        end,
        function() return AltStableConfig and AltStableConfig.rosterEnchants == true end)
    Y = Y - 22

    -- Off unless asked for (#124): it takes a picture on its own.
    local optAutoPortraitCheck = MakeOptCheckRow("portraitAuto",
        "Offer a new portrait when your look changes", Y,
        function(checked)
            AltStable.SetConfigValue("portraitAuto", checked)
            if AltStable.EvaluateAutoCapture then AltStable.EvaluateAutoCapture() end
        end,
        function() return AltStableConfig and AltStableConfig.portraitAuto == true end)
    Y = Y - 20
    -- Without the Companion this only takes screenshots nothing turns into a
    -- portrait: said under the option (owner's call, #124).
    local optAutoPortraitHint = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optAutoPortraitHint:SetPoint("TOPLEFT", P + 22, Y)
    optAutoPortraitHint:SetPoint("TOPRIGHT", -P, Y)
    optAutoPortraitHint:SetJustifyH("LEFT")
    optAutoPortraitHint:SetWordWrap(true)
    optAutoPortraitHint:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    optAutoPortraitHint:SetText("A toast above the chat counts down 5 minutes; close it to skip that look. "
        .. AltStable.COMPANION_NEEDED_PLAIN)
    AltStable._test = AltStable._test or {}
    AltStable._test.optAutoPortraitHint = optAutoPortraitHint
    Y = Y - 30

    -- The portrait capture angle (#149): what `/alts portrait facing` sets, as
    -- a slider. 0, the default, faces you straight on.
    local optFacingLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    optFacingLabel:SetPoint("TOPLEFT", P, Y - 6)
    optFacingLabel:SetText("Portrait angle")
    optFacingLabel:SetTextColor(unpack(AltStable.C.TEXT_NORM))
    local optFacingSlider = CreateFrame("Slider", nil, optionsFrame, "OptionsSliderTemplate")
    optFacingSlider:SetPoint("TOPLEFT", P + 120, Y - 2)
    optFacingSlider:SetWidth(220); optFacingSlider:SetHeight(16)
    optFacingSlider:SetMinMaxValues(-45, 45)
    optFacingSlider:SetValueStep(5)
    if optFacingSlider.Low  then optFacingSlider.Low:SetText("-45\194\176")  end
    if optFacingSlider.High then optFacingSlider.High:SetText("45\194\176") end
    local optFacingMid = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optFacingMid:SetPoint("TOP", optFacingSlider, "BOTTOM", 0, 2)
    optFacingMid:SetText("0\194\176")
    optFacingMid:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    local function FacingTip(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(("Portrait angle: %d\194\176"):format(AltStable.GetPortraitFacing and AltStable.GetPortraitFacing() or 0), 1, 1, 1)
        GameTooltip:AddLine("Which way characters turn in /alts portrait captures; 0 faces you. "
            .. "Re-capture your other characters too, so the lineup matches.", .8, .8, .8, true)
        GameTooltip:Show()
    end
    optFacingSlider:SetScript("OnEnter", FacingTip)
    optFacingSlider:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local optFacingUpdating = false
    local function ShowFacing(deg)
        optFacingUpdating = true
        optFacingSlider:SetValue(deg)
        optFacingUpdating = false
    end
    optFacingSlider:SetScript("OnValueChanged", function(self, value)
        if optFacingUpdating then return end
        local deg = math.floor(value / 5 + 0.5) * 5     -- the setter holds it to +-45
        -- A drag fires this on every pixel: write (and re-pose a preview) only
        -- when the rounded angle actually changes.
        if AltStable.GetPortraitFacing and deg == AltStable.GetPortraitFacing() then return end
        if AltStable.SetPortraitFacing and not AltStable.SetPortraitFacing(deg) then
            -- Refused (a newer AltStable's store): say so, as the command does,
            -- and show what is really stored rather than a value never saved.
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffAltStable|r a newer AltStable wrote the portrait store - not changing it")
            ShowFacing(AltStable.GetPortraitFacing())
            return
        end
        if GameTooltip:IsOwned(self) then FacingTip(self) end
    end)
    -- The command changing it while Options is open moves the slider too.
    AltStable.OnPortraitFacingChanged = function(deg)
        if optionsPanel and optionsPanel:IsShown() then ShowFacing(deg) end
    end
    local optFacingReset = CreateFrame("Button", nil, optionsFrame, "BackdropTemplate")
    optFacingReset:SetSize(58, 20)
    optFacingReset:SetPoint("LEFT", optFacingSlider, "RIGHT", 16, 0)
    AltStable.ApplyBackdrop(optFacingReset, 0.12, 0.12, 0.12, 1)
    local optFacingResetLbl = optFacingReset:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optFacingResetLbl:SetAllPoints(); optFacingResetLbl:SetJustifyH("CENTER"); optFacingResetLbl:SetText("Reset")
    optFacingReset:SetScript("OnClick", function()
        local d = AltStable.DEFAULT_PORTRAIT_FACING or 0
        if AltStable.SetPortraitFacing then AltStable.SetPortraitFacing(d) end
        optFacingUpdating = true
        optFacingSlider:SetValue(d)
        optFacingUpdating = false
    end)
    AltStable._test = AltStable._test or {}
    AltStable._test.FacingSlider = optFacingSlider
    AltStable._test.FacingReset = optFacingReset
    Y = Y - 44

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
    Y = Y - 22

    -- Each tab's sort, kept across logouts (#160). Turning it off forgets the
    -- saved sorts; the tabs keep theirs for the rest of the session.
    local optRememberSortCheck = MakeOptCheckRow("rememberSortOrder",
        "Remember each tab's sort order", Y,
        function(checked)
            AltStable.SetConfigValue("rememberSortOrder", checked)
            if checked then
                -- The sorts the tabs hold right now are saved at once, like the
                -- window position above: not only from the next click on.
                SaveSessionSorts()
            else
                AltStable.SetConfigValue("sheetSort", nil)
            end
        end)
    AltStable._test.OptRememberSort = optRememberSortCheck
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
    -- Enter commits. Losing focus ALSO commits, because Enter-only is how a
    -- typed value gets silently discarded by clicking somewhere else - which
    -- looks exactly like the setting failing to persist, and this one was
    -- already suspected of that.
    --
    -- But blurring an EMPTY or unparseable box reverts rather than clears. The
    -- box selects all of its text when focused, so backspace-then-click-away is
    -- an ordinary thing to do, and it must not wipe a configured account
    -- number - the more so because accountNumber is a sync-scope key, so
    -- clearing it forces a full re-send to every peer. Clearing is explicit:
    -- /alts account clear.
    local function ShowStoredAccount()
        optAcctBox:SetText(tostring(AltStable.GetAccountNumber() or ""))
    end

    local function CommitAccountNumber(text, fromEnter)
        local typed = tostring(text or ""):match("^%s*(.-)%s*$")
        if typed == "" then
            if fromEnter then
                local _, msg = AltStable.SetAccountNumber("clear")
                AltStable.Print(msg)
            end
            ShowStoredAccount()
            return false
        end

        local ok, msg = AltStable.SetAccountNumber(typed)
        if ok or fromEnter then AltStable.Print(msg) end
        ShowStoredAccount()
        return ok
    end

    AltStable._test = AltStable._test or {}
    AltStable._test.CommitAccountNumber = CommitAccountNumber
    AltStable._test.AccountBox = optAcctBox
    -- So a change made anywhere else (the slash command) does not leave a stale
    -- number in the box, which blurring would then commit back over it.
    AltStable._test.ShowStoredAccount = ShowStoredAccount
    AltStable.RefreshAccountBox = ShowStoredAccount

    optAcctBox:SetScript("OnEnterPressed", function(self)
        CommitAccountNumber(self:GetText(), true)
        self:ClearFocus()
    end)
    optAcctBox:SetScript("OnEditFocusLost", function(self)
        CommitAccountNumber(self:GetText(), false)
        -- InputBoxTemplate's own OnEditFocusLost clears the selection made when
        -- the box was focused; overriding it means doing that here.
        self:HighlightText(0, 0)
    end)
    optAcctBox:SetScript("OnEscapePressed", function(self)
        ShowStoredAccount()
        self:ClearFocus()
    end)

    local optAcctHint = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optAcctHint:SetPoint("LEFT", optAcctBox, "RIGHT", 12, 0)
    optAcctHint:SetPoint("RIGHT", OptRail(Y + 4, 22), "RIGHT", 0, 0)
    optAcctHint:SetJustifyH("LEFT")
    optAcctHint:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    optAcctHint:SetText("Tags this client's data on next scan/sync.")
    Y = Y - 30

    local optSendAllCheck = MakeOptCheckRow("sendAllAccounts",
        "Share all known accounts (uncheck to share only this account's data)", Y)
    Y = Y - 24

    -- #58: your own other accounts, found and synced through Battle.net -
    -- any ruleset, any faction, nothing to type. Off clears what was found.
    local optBnetCheck = MakeOptCheckRow("bnetSync",
        "Sync with your other accounts through Battle.net (any ruleset, any faction)", Y,
        function(checked)
            AltStable.SetConfigValue("bnetSync", checked)
            if AltStable.RescanOwnAccounts then AltStable.RescanOwnAccounts() end
        end)
    Y = Y - 24

    -- ── Lists that take only the room they use (#151) ─────
    --
    -- The three lists below - sync peers, requests and answers, hidden
    -- characters - each reserve a fixed number of rows, and everything under
    -- them is laid out by the cursor, at a fixed height, once. An empty list
    -- left its whole reserve as a blank gap, and the page read as broken.
    --
    -- So each list notes what exists when it ends (Mark); at the end of the
    -- layout everything created AFTER a list is recorded with its anchors
    -- (Finish); and whenever a list refreshes it says how many rows it is
    -- really using (Use), and everything below moves up by the rest. Only
    -- anchors to the page itself move, and only their TOP edges: what is
    -- anchored to a sibling follows it. Rather than re-anchoring two dozen
    -- controls by hand, which is what the alternative was.
    -- `skip`: what anchors itself again on every refresh, so must not be put
    -- back where it was at Finish.
    local optFlow = { lists = {}, items = nil, height = nil, skip = {} }
    function optFlow.Mark(reserved, rowH)
        local seen = {}
        for _, o in ipairs({ optionsFrame:GetChildren() }) do seen[o] = true end
        for _, o in ipairs({ optionsFrame:GetRegions() }) do seen[o] = true end
        local list = { seen = seen, reserved = reserved, used = reserved, rowH = rowH or 18, gap = 0 }
        optFlow.lists[#optFlow.lists + 1] = list
        return list
    end
    function optFlow.Finish(height)
        optFlow.height = height
        optFlow.items = {}
        local all = { optionsFrame:GetChildren() }
        for _, o in ipairs({ optionsFrame:GetRegions() }) do all[#all + 1] = o end
        for _, o in ipairs(all) do
            local below = {}
            for _, list in ipairs(optFlow.lists) do
                if not list.seen[o] then below[#below + 1] = list end
            end
            if #below > 0 and not optFlow.skip[o] then
                local points = {}
                for i = 1, (o:GetNumPoints() or 0) do points[i] = { o:GetPoint(i) } end
                optFlow.items[#optFlow.items + 1] = { o = o, below = below, points = points, applied = 0 }
            end
        end
        optFlow.Apply()
    end
    -- Page anchors are moved by where they are measured FROM - the relative
    -- point - which is always the page's top edge here (see OptRail).
    function optFlow.Apply()
        if not optFlow.items then return end      -- still being laid out
        for _, it in ipairs(optFlow.items) do
            local shift = 0
            for _, list in ipairs(it.below) do shift = shift + list.gap end
            -- Only what actually moves: one list changing leaves everything
            -- above it, and everything whose total did not change, alone.
            if shift ~= it.applied then
                it.applied = shift
                it.o:ClearAllPoints()
                for _, p in ipairs(it.points) do
                    local point, rel, relPoint, x, y = p[1], p[2], p[3], p[4], p[5]
                    if rel == optionsFrame then y = (y or 0) + shift end
                    it.o:SetPoint(point, rel, relPoint, x or 0, y or 0)
                end
            end
        end
        local unused = 0
        for _, list in ipairs(optFlow.lists) do unused = unused + list.gap end
        optionsFrame:SetHeight(optFlow.height - unused)
    end
    -- How many rows a list is showing - at least one, for its "none" line.
    function optFlow.Use(list, rows)
        rows = math.max(1, math.min(rows, list.reserved))
        if list.used == rows then return end
        list.used = rows
        list.gap = (list.reserved - rows) * list.rowH
        optFlow.Apply()
    end
    AltStable._test.OptFlow = optFlow

    -- ── Whitelist (sync peers) ────────────────────────────
    local optWlHdr = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optWlHdr:SetPoint("TOPLEFT", P, Y)
    optWlHdr:SetText("SYNC PEERS")
    optWlHdr:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    Y = Y - 18

    local optWlHint = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optWlHint:SetPoint("TOPLEFT", P, Y)
    optWlHint:SetPoint("TOPRIGHT", -P, Y)
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
    local optWlNone = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optWlNone:SetPoint("TOPLEFT", P + 4, Y)
    optWlNone:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    optWlNone:SetText("No sync peers yet.")
    AltStable._test.OptWlNone = optWlNone
    Y = Y - (OPT_WL_ROWS * 18) - 6
    local optWlFlow = optFlow.Mark(OPT_WL_ROWS, 18)
    -- Past the reserve, say so: a list sized to its content otherwise looks
    -- complete. On the last row's own line, so it takes no extra room.
    local optWlMore = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optWlMore:SetPoint("LEFT", optWlRows[OPT_WL_ROWS].removeBtn, "RIGHT", 12, 0)
    optWlMore:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    AltStable._test.OptWlMore = optWlMore

    local function OptRefreshWhitelist()
        AltStableConfig = AltStableConfig or {}
        AltStableConfig.whitelist = AltStableConfig.whitelist or {}
        local wl = AltStableConfig.whitelist
        if #wl == 0 then optWlNone:Show() else optWlNone:Hide() end
        optFlow.Use(optWlFlow, #wl)
        optWlMore:SetText(#wl > OPT_WL_ROWS
            and ("+" .. (#wl - OPT_WL_ROWS) .. " more - |cffffff00/alts whitelist|r") or "")
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

    -- `/alts whitelist` changes the list too, with Options possibly open.
    AltStable.RefreshOptionsWhitelist = function()
        if optionsFrame:IsVisible() then OptRefreshWhitelist() end
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

    -- ── Who may sync with you (#61) ───────────────────────
    -- Everyone who has asked and not been answered, and every stored answer.
    -- The whitelist above is who WE ask; this is who may ask US, and the two
    -- are separate on purpose.
    local optAuthHdr = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optAuthHdr:SetPoint("TOPLEFT", P, Y)
    optAuthHdr:SetText("REQUESTS AND ANSWERS")
    optAuthHdr:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    Y = Y - 18

    local optAuthHint = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optAuthHint:SetPoint("TOPLEFT", P, Y)
    optAuthHint:SetPoint("TOPRIGHT", -P, Y)
    optAuthHint:SetJustifyH("LEFT"); optAuthHint:SetWordWrap(true)
    optAuthHint:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    optAuthHint:SetText("Who may sync with you. Forget goes back to the whitelist, or to asking. "
        .. "Allowing someone does not add them to the list above.")
    Y = Y - 30

    local function OptAuthButton(parent, anchor, dx)
        local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
        b:SetSize(52, 16)
        b:SetPoint("LEFT", anchor, "RIGHT", dx, 0)
        AltStable.ApplyBackdrop(b, 0.12, 0.12, 0.12, 1)
        local l = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        l:SetAllPoints(); l:SetJustifyH("CENTER")
        b.label = l
        return b
    end

    local OPT_AUTH_ROWS = 6
    local optAuthRows = {}
    for i = 1, OPT_AUTH_ROWS do
        local row = CreateFrame("Frame", nil, optionsFrame)
        row:SetSize(360, 18)
        row:SetPoint("TOPLEFT", P + 4, Y - (i - 1) * 18)
        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", 0, 0); lbl:SetWidth(200); lbl:SetJustifyH("LEFT")
        lbl:SetTextColor(unpack(AltStable.C.TEXT_NORM))
        row.label = lbl
        row.first = OptAuthButton(row, lbl, 8)
        row.second = OptAuthButton(row, row.first, 4)
        row:Hide()
        optAuthRows[i] = row
    end
    local optAuthNone = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optAuthNone:SetPoint("TOPLEFT", P + 4, Y)
    optAuthNone:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    optAuthNone:SetText("No requests or answers yet.")
    AltStable._test.OptAuthNone = optAuthNone
    Y = Y - (OPT_AUTH_ROWS * 18)
    local optAuthFlow = optFlow.Mark(OPT_AUTH_ROWS, 18)
    local optAuthMore = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optAuthMore:SetPoint("TOPLEFT", P + 4, Y)
    optAuthMore:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    Y = Y - 20

    local AUTH_STATE = {
        waiting = "|cffffff00waiting|r",
        [AltStable.AUTH_AUTO] = "|cff88ff88allowed|r",
        [AltStable.AUTH_NEVER] = "|cffff8888never|r",
    }
    -- What each state's two buttons do: the first changes the answer, the
    -- second takes it back. A waiting request has nothing to take back, so it
    -- gets Allow and Never.
    local AUTH_ACTIONS = {
        waiting = { { "Allow", "AllowSyncPeer" }, { "Never", "DenySyncPeer" } },
        [AltStable.AUTH_AUTO] = { { "Never", "DenySyncPeer" }, { "Forget", "ForgetSyncPeer" } },
        [AltStable.AUTH_NEVER] = { { "Allow", "AllowSyncPeer" }, { "Forget", "ForgetSyncPeer" } },
    }

    -- Answers first, then who is waiting; one row per peer.
    local function OptSyncAuthEntries()
        local out, seen = {}, {}
        for _, e in ipairs(AltStable.SyncAuthList and AltStable.SyncAuthList() or {}) do
            if AUTH_ACTIONS[e.mode] and not seen[e.name] then
                seen[e.name] = true
                out[#out + 1] = { name = e.name, state = e.mode }
            end
        end
        for _, e in ipairs(AltStable.PendingSyncRequests and AltStable.PendingSyncRequests() or {}) do
            local key = e.key or (AltStable.PeerKey and AltStable.PeerKey(e.name)) or e.name
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = { name = e.name, state = "waiting" }
            end
        end
        return out
    end

    local function OptRefreshSyncAuth()
        local entries = OptSyncAuthEntries()
        if #entries == 0 then optAuthNone:Show() else optAuthNone:Hide() end
        optFlow.Use(optAuthFlow, #entries)
        for i, row in ipairs(optAuthRows) do
            local e = entries[i]
            if e then
                row.label:SetText(e.name .. "  " .. AUTH_STATE[e.state])
                local actions = AUTH_ACTIONS[e.state]
                for n, btn in ipairs({ row.first, row.second }) do
                    local caption, fnName = actions[n][1], actions[n][2]
                    btn.label:SetText(caption)
                    -- Core redraws this list afterwards, through OnSyncAuthChanged.
                    btn:SetScript("OnClick", function() AltStable[fnName](e.name) end)
                end
                row:Show()
            else
                -- Emptied as well as hidden: the label is what a test reads.
                row.label:SetText("")
                row:Hide()
            end
        end
        local extra = #entries - OPT_AUTH_ROWS
        optAuthMore:SetText(extra > 0
            and ("+" .. extra .. " more - |cffffff00/alts auth|r") or "")
    end
    AltStable.RefreshSyncAnswers = function()
        if optionsFrame:IsVisible() then OptRefreshSyncAuth() end
    end
    AltStable._test.SyncAuthRows = optAuthRows

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

    -- ── Hidden characters (#21) ───────────────────────────
    local optHideHdr = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optHideHdr:SetPoint("TOPLEFT", P, Y)
    optHideHdr:SetText("HIDDEN CHARACTERS")
    optHideHdr:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    Y = Y - 18

    local optHideHint = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optHideHint:SetPoint("TOPLEFT", P, Y)
    optHideHint:SetPoint("TOPRIGHT", -P, Y)
    optHideHint:SetJustifyH("LEFT"); optHideHint:SetWordWrap(true)
    optHideHint:SetTextColor(unpack(AltStable.C.TEXT_DIM))
    optHideHint:SetText("Right-click a name on the sheet to hide it. Hidden characters keep "
        .. "syncing; they are only left out of the grid and the totals.")
    Y = Y - 32

    -- Same compact row list as the sync peers above. This one is per account
    -- and not synced, so it stays short in practice.
    local OPT_HIDDEN_ROWS = 6
    local optHiddenRows = {}
    for i = 1, OPT_HIDDEN_ROWS do
        local row = CreateFrame("Frame", nil, optionsFrame)
        row:SetSize(360, 18)
        row:SetPoint("TOPLEFT", P + 4, Y - (i - 1) * 18)

        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", 0, 0); lbl:SetJustifyH("LEFT")
        lbl:SetTextColor(unpack(AltStable.C.TEXT_NORM))
        row.label = lbl

        local show = CreateFrame("Button", nil, row, "BackdropTemplate")
        show:SetSize(48, 16)
        show:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
        AltStable.ApplyBackdrop(show, 0.12, 0.12, 0.12, 1)
        local showLbl = show:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        showLbl:SetAllPoints(); showLbl:SetJustifyH("CENTER"); showLbl:SetText("|cffddddddShow|r")
        row.showBtn = show
        row:Hide()
        optHiddenRows[i] = row
    end

    local optHiddenNote = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    optHiddenNote:SetPoint("TOPLEFT", optHiddenRows[1], "TOPLEFT", 0, 0)
    optHiddenNote:SetJustifyH("LEFT")
    -- Anchored to the list's own rows, which move with the lists above it;
    -- re-anchored on every refresh, so the flow leaves it alone.
    optFlow.skip[optHiddenNote] = true
    optHiddenNote:SetTextColor(unpack(AltStable.C.TEXT_DIM))

    Y = Y - (OPT_HIDDEN_ROWS * 18) - 6
    local optHiddenFlow = optFlow.Mark(OPT_HIDDEN_ROWS, 18)

    local function OptRefreshHidden()
        local list = AltStable.HiddenCharacterList and AltStable.HiddenCharacterList() or {}
        optFlow.Use(optHiddenFlow, #list)
        for i, row in ipairs(optHiddenRows) do
            local entry = list[i]
            if entry then
                local label = AltStable.ClassColor(entry.class) .. entry.name .. "|r"
                if entry.realm and entry.realm ~= "" then
                    label = label .. "  |cff808080" .. entry.realm .. "|r"
                end
                row.label:SetText(label)
                row.showBtn:SetScript("OnClick", function()
                    AltStable.ShowCharacter(entry.guid)
                end)
                row:Show()
            else
                row.label:SetText("")
                row:Hide()
            end
        end
        -- ClearAllPoints first: SetPoint ADDS an anchor, so re-anchoring a
        -- frame that already has one leaves it pinned to both.
        optHiddenNote:ClearAllPoints()
        -- Overflow rather than a scroll frame: six rows cover every case seen,
        -- and the note says plainly what is not on screen instead of pretending
        -- the list is complete.
        if #list == 0 then
            optHiddenNote:SetText("Nothing is hidden.")
            optHiddenNote:SetPoint("TOPLEFT", optHiddenRows[1], "TOPLEFT", 0, 0)
            optHiddenNote:Show()
        elseif #list > OPT_HIDDEN_ROWS then
            optHiddenNote:SetText(("... and %d more (unhide one to see the next)")
                :format(#list - OPT_HIDDEN_ROWS))
            optHiddenNote:SetPoint("TOPLEFT", optHiddenRows[OPT_HIDDEN_ROWS], "BOTTOMLEFT", 0, 0)
            optHiddenNote:Show()
        else
            -- Cleared, not just hidden: the same stale-text trap as the row
            -- labels above, and the note is read back in tests.
            optHiddenNote:SetText("")
            optHiddenNote:Hide()
        end
    end
    -- So HideCharacter/ShowCharacter can repaint this list without the sheet
    -- knowing how it is built.
    AltStable.RefreshOptionsHiddenList = OptRefreshHidden

    -- Test seam: the row labels that carry text, and the note under them. A
    -- stubbed frame answers IsShown() truthily whatever it was told, so the
    -- emptied label is what "this row is not in use" looks like from a test.
    AltStable._test = AltStable._test or {}
    AltStable._test.OptionsHiddenList = function()
        local names = {}
        for _, row in ipairs(optHiddenRows) do
            local t = row.label:GetText()
            if t and t ~= "" then names[#names + 1] = t end
        end
        return names, optHiddenNote:GetText()
    end

    -- Content height is known once the layout cursor has run; the scroll range
    -- derives from it, less whatever the lists are not using (OptFlow).
    optFlow.Finish(math.abs(Y) + 24)

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
        optPetsCheck:SetChecked(optPetsCheck._getter())
        optEnchantsCheck:SetChecked(optEnchantsCheck._getter())
        optAutoPortraitCheck:SetChecked(optAutoPortraitCheck._getter())
        optFacingUpdating = true
        optFacingSlider:SetValue(AltStable.GetPortraitFacing and AltStable.GetPortraitFacing() or 0)
        optFacingUpdating = false
        optMinimapCheck:SetChecked(optMinimapCheck._getter())
        optRememberPositionCheck:SetChecked(optRememberPositionCheck._getter())
        optRememberSortCheck:SetChecked(optRememberSortCheck._getter())
        optAcctBox:SetText(tostring(AltStable.GetAccountNumber() or ""))
        optSendAllCheck:SetChecked(AltStableConfig.sendAllAccounts and true or false)
        optBnetCheck:SetChecked(AltStableConfig.bnetSync ~= false)
        optToastsCheck:SetChecked(AltStableConfig.toastsEnabled ~= false)
        optMailAlertsCheck:SetChecked(AltStableConfig.mailAlertsEnabled ~= false)
        AltStableConfig.toastProfessions = AltStableConfig.toastProfessions or {}
        for profKey, cb in pairs(optProfChecks) do
            cb:SetChecked(AltStableConfig.toastProfessions[profKey] ~= false)
        end
        OptRefreshWhitelist()
        OptRefreshSyncAuth()
        OptRefreshHidden()
        RefreshThemeBtns()
        -- And the skin row, which is the ONE control here that can be changed
        -- from outside this panel: `/alts skin` writes the config and says
        -- "reload" in chat. Without this, opening Options after that command
        -- lights the old skin and shows no pending line - contradicting the
        -- message the player has just read, and inviting them to click the
        -- lit button and silently discard the choice they made.
        RefreshSkinRow()
    end)

    -- Add the Options sidebar button
    local optSect, optBtn
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
        optBtn = MakePluginButton(optSect)
    end
    -- Stored on AltStable so AltStable.OpenConfig() (and the minimap
    -- right-click) can switch to the Options section without re-introducing
    -- the standalone config popup.
    --
    -- Through the Options BUTTON, as a click would: Options is a plugin tab,
    -- and SwitchSection is the sheet tabs' path - handed Options it read the
    -- sheet columns of a section that has none and raised, leaving the tab
    -- half switched (#164 review).
    AltStable._SwitchToOptions = function()
        if optBtn then optBtn:GetScript("OnClick")(optBtn) end
    end

    --------------------------------------------------------
    -- Totals bar
    --------------------------------------------------------

    totalsBar=CreateFrame("Frame",nil,frame,"BackdropTemplate")
    -- CORNER-SAFE. This reaches the bottom-right corner, so under glass its
    -- fill is clipped to the window's outline. See AltStable.SkinPanelFill.
    totalsBar:SetPoint("BOTTOMLEFT",sidebar,"BOTTOMRIGHT",0,0)
    totalsBar:SetPoint("BOTTOMRIGHT",frame,"BOTTOMRIGHT",-1,1)
    totalsBar:SetHeight(22)
    if not AltStable.SkinPanelFill(totalsBar, frame, AltStable.C.BG_FOOTER) then
        AltStable.ApplyBGOnly(totalsBar,
            AltStable.C.BG_FOOTER[1], AltStable.C.BG_FOOTER[2],
            AltStable.C.BG_FOOTER[3], AltStable.C.BG_FOOTER[4])
    end
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

    -- "(N hidden)" is its OWN button rather than a run of text inside
    -- totalsBar.right, because it has to be clickable and the rest of that
    -- string must not be: a click on the gold total silently changing which
    -- characters the grid lists would be indistinguishable from a bug.
    --
    -- It sits in the footer, which every tab shows - including the Roster - so
    -- there is a route back from wherever a character was hidden. That is what
    -- let the hide confirmation go.
    --
    -- "Including the Roster" was an assumption when this was written and was
    -- FALSE: that panel covered the footer and then hid it outright, making the
    -- Roster the one tab where a card could be hidden with no way back on it.
    -- The panel stops above the footer now, and test_roster pins both the gap
    -- and the visibility - being shown underneath an opaque panel looks exactly
    -- like being shown.
    totalsBar.hiddenBtn = CreateFrame("Button", nil, totalsBar)
    totalsBar.hiddenBtn:SetHeight(16)
    totalsBar.hiddenBtn:SetPoint("RIGHT", totalsBar.right, "LEFT", -4, 0)
    totalsBar.hiddenBtn.label = totalsBar.hiddenBtn:CreateFontString(
        nil, "OVERLAY", "GameFontHighlightSmall")
    totalsBar.hiddenBtn.label:SetAllPoints()
    totalsBar.hiddenBtn.label:SetJustifyH("RIGHT")
    totalsBar.hiddenBtn:SetScript("OnClick", function()
        if not AltStable.SetShowingHidden then return end
        AltStable.SetShowingHidden(not AltStable.IsShowingHidden())
        AltStable.RefreshSheet()
    end)
    totalsBar.hiddenBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        if AltStable.IsShowingHidden and AltStable.IsShowingHidden() then
            GameTooltip:AddLine("Hidden characters are listed, dimmed.", 1, 1, 1)
            GameTooltip:AddLine("Right-click one to unhide it. Click here to stop listing them.",
                                0.7, 0.7, 0.7, true)
        else
            GameTooltip:AddLine("Click to list hidden characters, dimmed,", 1, 1, 1)
            GameTooltip:AddLine("so you can right-click one and unhide it.", 1, 1, 1)
        end
        GameTooltip:AddLine("They are left out of the totals either way.", 0.5, 0.5, 0.5, true)
        GameTooltip:Show()
    end)
    totalsBar.hiddenBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    totalsBar.hiddenBtn:Hide()

    --------------------------------------------------------
    -- Frozen header (Name column)
    --------------------------------------------------------

    frozenHeader=CreateFrame("Frame",nil,frame)
    frozenHeader:SetPoint("TOPLEFT",sidebar,"TOPRIGHT",0,TITLE_H-HEADER_TOP_Y)
    frozenHeader:SetSize(FROZEN_WIDTH,HEADER_HEIGHT)
    local fhBg=frozenHeader:CreateTexture(nil,"BACKGROUND")
    fhBg:SetAllPoints()
    fhBg:SetColorTexture(AltStable.SkinHeaderBand())
    AltStable._test.frozenHeaderBG = fhBg
    local fhLine=frozenHeader:CreateTexture(nil,"OVERLAY")
    fhLine:SetHeight(1); fhLine:SetPoint("BOTTOMLEFT"); fhLine:SetPoint("BOTTOMRIGHT")
    fhLine:SetColorTexture(unpack(AltStable.C.SEP))

    -- Name header button (persistent): the same builder as the scrolling ones,
    -- parented to the frozen strip and never reused for another column.
    nameHeader = NewHeaderButton(frozenHeader)
    nameHeader:SetPoint("LEFT", 10, 0)
    ConfigureHeader(nameHeader, AltStable.Columns[1])

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
    hBg:SetColorTexture(AltStable.SkinHeaderBand())
    AltStable._test.headerBG = hBg
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
    sbBorder:SetPoint("TOPLEFT",sidebar,"TOPRIGHT",0,0)
    sbBorder:SetPoint("BOTTOMLEFT",sidebar,"BOTTOMRIGHT",0,-1)
    sbBorder:SetColorTexture(0, 0, 0, 1)

    --------------------------------------------------------
    -- The data region IS this texture under glass
    --------------------------------------------------------
    -- Not an underlay any more. It began as one - the rows were opaque bands in
    -- the flat theme's charcoal and this sat behind them, doing nothing except
    -- for hidden characters - and it is now the table's actual surface, with
    -- the rows painting lifts on it or nothing at all. See SkinDataColor.
    --
    -- OPAQUE, which is the decision: there is no blur available, so what shows
    -- through a translucent table is the world moving sharp behind small text.
    -- That also settles what used to be the hard case here. DimRow takes a
    -- hidden character's whole row - background, text, tint and highlight - to
    -- HIDDEN_ROW_ALPHA, and when this was a 0.62 pane that meant ~16% of the
    -- world came through a dimmed row under `clear`. Against an opaque surface
    -- a dimmed row reveals the surface and nothing else, which is what "these
    -- rows recede" was always supposed to mean.
    --
    -- One texture behind both viewports rather than a change to row rendering:
    -- dimming, alternating bands, class tint and hover all keep working, and
    -- the space below the last row is the same surface as the rows above it.
    -- Glass is for the chrome; the table is somewhere to read.
    if AltStable.SkinIsGlass() then
        local dataBG = frame:CreateTexture(nil, "BACKGROUND", nil, -3)
        -- Placed properly by ApplyContentAnchors, which knows where the
        -- viewports actually end; these are only so it is never unanchored.
        dataBG:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDEBAR_WIDTH, -BodyTopY())
        dataBG:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 23)
        -- The reading surface, which is a different colour from the panels
        -- and deliberately opaque: see SkinDataColor. The rows on top of it
        -- are lifts now, so this is what the table actually IS - not an
        -- underlay that twenty-one opaque bands were hiding.
        dataBG:SetColorTexture(unpack(AltStable.SkinDataColor()))
        -- And clipped, because it runs to the window's right edge.
        AltStable.SkinClipTexture(frame, dataBG, frame)
        AltStable._dataBG = dataBG
    end

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

    -- Activate the first section: it builds the headers. Not animated: the
    -- window is still shown here (it is hidden at the end of the build), so an
    -- animated switch would start a trip on a window nobody sees and leave it
    -- on a temporary anchor while it ran (#164 review).
    SwitchSectionNow(SECTIONS[1])

    -- THE TOOLTIP HOOKS GO IN LAST, with the window already built.
    --
    -- They are cosmetic, and they were being installed between this frame's
    -- creation and its skinning - where a raise would leave the sheet
    -- permanently half-built, because this function early-returns on a frame
    -- that exists. No backdrop, no scrolls, no header, and every later /alts
    -- returning to the same wreck. `hooksecurefunc` raises on a target that is
    -- not a function, which is exactly the shape of thing an unfamiliar client
    -- hands you. Guarded there too, and out of the way here.
    if AltStable.InstallTooltipSkin then AltStable.InstallTooltipSkin() end

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

-- The Reputations tab's columns follow the data - the factions some character
-- has met - so a faction met, or synced in, while the tab is open needs them
-- rebuilt here, not only on a tab switch. Headers are rebuilt only when the
-- set actually changed.
local function ColumnSignature()
    local fields = {}
    for i, col in ipairs(scrollableCols) do fields[i] = col.field end
    return table.concat(fields, ",")
end

local function RebuildDataDrivenColumns()
    if not (activeSection and activeSection.repFields) then return end
    local before = ColumnSignature()
    BuildScrollableColsForSection(activeSection)
    if ColumnSignature() ~= before then
        -- The faction the rows were sorted by may be the column that went.
        ResetSortIfInvalid()
        AdjustHeaderHeight(AltStable.HeaderHeightFor(scrollableCols, activeSection.headerHeight or HEADER_HEIGHT))
        BuildHeaders()
    end
end

local function Refresh()
    RebuildDataDrivenColumns()
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

-- The key binding (Bindings.xml, its own "AltStable" section, as Gnomesweeper's)
-- calls this toggle; this is its line in Key Bindings. A global, as the client
-- looks it up by name.
BINDING_NAME_ALTSTABLE_TOGGLE = "Open or close AltStable"

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
    -- The restore list too, and unconditionally. A record can ARRIVE for a
    -- hidden character while Options is open - a peer syncing an alt, or the
    -- re-pull after /alts cleanup - and the list only shows guids that have a
    -- record. Its OnShow does not fire again while the panel stays open, so
    -- that character would be unrestorable until the user left Options and came
    -- back. Six rows; not worth a visibility check that could itself be wrong.
    if AltStable.RefreshOptionsHiddenList then AltStable.RefreshOptionsHiddenList() end
end

------------------------------------------------------------
-- Forgetting a character (#65), confirmed
--
-- Hiding used to be the thing confirmed here, and is not any more (#69). The
-- confirmation existed because the row vanished on a single right-click and
-- the only way back was a list in Options the user had no reason to know
-- about. The menu removed the single right-click and the footer's "(N hidden)"
-- toggle removed the Options trip, so the popup was asking permission for
-- something now visibly reversible from where it happened.
--
-- Forget keeps it, and always will: it deletes the record and writes a
-- tombstone so peers cannot put it back. That is the one action here that is
-- not a view preference.
------------------------------------------------------------

------------------------------------------------------------
-- "Reload now?" - with a button that is ALLOWED to reload
------------------------------------------------------------
-- ReloadUI() from AltStable's own code is blocked on this client, MEASURED on
-- 1.60.1.70009 (#89):
--
--   [ADDON_ACTION_BLOCKED] AddOn 'AltStable' tried to call the protected
--   function 'Reload()'.   ...  AltStable/Capture.lua: in function 'OnAccept'
--
-- Not every time - the same StaticPopup reloaded after `/alts portrait` and was
-- blocked after the sheet's capture button, where the dialog had been lifted
-- out of the hidden interface by our code - which is exactly why a plain call
-- cannot be trusted. Typing /reload always works, because it is Blizzard's own
-- code that runs. So the Reload button here is a SecureActionButton whose
-- action is the macro "/reload": the click runs C_Macro.RunMacroText in the
-- secure template (Blizzard_FrameXML/SecureTemplates.lua), the same path as
-- typing it.
--
-- A frame of its OWN, not a StaticPopup and not a child of the sheet. A secure
-- button is a protected frame, and hiding a protected frame's parent is blocked
-- in combat: inside the sheet it would stop the sheet closing on Escape
-- mid-fight. Parented to nothing, so a hidden interface (the showcase, Alt+Z)
-- cannot hide it either, and dismissed when combat starts - PLAYER_REGEN_DISABLED
-- arrives before the lockdown does.
local reloadPrompt

local function BuildReloadPrompt()
    if reloadPrompt then return reloadPrompt end
    local f = CreateFrame("Frame", "AltStableReloadPrompt", nil, "BackdropTemplate")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:SetSize(320, 104)
    f:SetPoint("TOP", 0, -180)
    f:EnableMouse(true)
    if not (AltStable.SkinWindow and AltStable.SkinWindow(f, "small")) then
        if AltStable.ApplyBackdrop then AltStable.ApplyBackdrop(f, 0.05, 0.05, 0.05, 0.96) end
    end
    f:Hide()

    local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT", 14, -14)
    text:SetPoint("TOPRIGHT", -14, -14)
    text:SetJustifyH("CENTER")
    if AltStable.SkinText then AltStable.SkinText(text) end
    f.text = text

    -- The secure one. Its attributes are set once, here, out of combat, and
    -- nothing of ours is ever put on its OnClick: replacing the template's
    -- handler would make the click ours again, and blocked.
    local reload = CreateFrame("Button", "AltStableReloadPromptReload", f,
        "SecureActionButtonTemplate, UIPanelButtonTemplate")
    reload:SetSize(110, 22)
    reload:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -6, 14)
    reload:SetText("Reload")
    reload:SetAttribute("type", "macro")
    reload:SetAttribute("macrotext", "/reload")
    -- Down as well as up: with ActionButtonUseKeyDown on, a secure action
    -- button acts on the press and never sees a click registered for Up only.
    reload:RegisterForClicks("AnyUp", "AnyDown")
    f.reload = reload

    local later = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    later:SetSize(110, 22)
    later:SetPoint("BOTTOMLEFT", f, "BOTTOM", 6, 14)
    later:SetText("Later")
    later:SetScript("OnClick", function() f:Hide() end)
    f.later = later

    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:SetScript("OnEvent", function(self) self:Hide() end)

    reloadPrompt = f
    return f
end

-- Offer a reload, saying why. Returns false when it cannot be offered now:
-- in combat the prompt cannot be built or shown, and the caller's chat line
-- has to do.
function AltStable.ShowReloadPrompt(message)
    if InCombatLockdown and InCombatLockdown() then return false end
    local f = BuildReloadPrompt()
    f.text:SetText(message or "Reload now?")
    f:Show()
    f:Raise()
    return true
end

AltStable._test = AltStable._test or {}
AltStable._test.ReloadPrompt = function() return reloadPrompt end

-- The forget confirmation, on our own prompt (Prompt.lua): a StaticPopup taints
-- the client's dialog pool (#199), and it was invisible under the sheet and
-- under the showcase's hidden UIParent anyway.
--
-- The recovery route is NAMED, because there is one and this dialog used to
-- deny it. "There is no undo" was false - /alts unforget lifts the tombstone
-- and re-asks every peer in full - and "it will only reappear by logging into
-- it" was worse than false: logging in on ANOTHER account does not clear THIS
-- account's tombstone, so a player following that instruction leaves the
-- record rejected indefinitely. The slash command has printed the right answer
-- all along; the dialog contradicted it.
local FORGET_TEXT = "Forget |cffffffff%s|r?\n\nThe local record is deleted, and a tombstone stops "
    .. "other accounts sending it back. This is not hiding.\n\n"
    .. "|cffffff00/alts unforget|r lifts the tombstone, and the character can then come "
    .. "back from a peer on the next full sync - not instantly, and not by logging "
    .. "into it."

------------------------------------------------------------
-- "<name> asks to sync with you" (#61)
------------------------------------------------------------
-- The chat line alone was easy to miss, and a request expires in five minutes.
-- Each asker is prompted ONCE per session; after that the Options list
-- ("Requests and answers") is where they wait.
--
-- The queue is not stored: the next peer is worked out from the pending
-- requests every time, so an answer given anywhere else - the slash command,
-- the Options list - just drops out of it, and an expired request is never
-- prompted.
local SYNC_ASK_TEXT = "|cffffffff%s|r asks to sync with you.\n\nThey would receive every character "
    .. "AltStable knows here - gold, bags, mail, lockouts."
local syncPrompted = {}      -- PeerKey -> true: already asked this session
local syncPromptKey          -- the peer on screen now, if any

local function NextSyncAsk()
    local best
    for _, e in ipairs(AltStable.PendingSyncRequests()) do
        local key = e.key or AltStable.PeerKey(e.name)
        if key and not syncPrompted[key]
            and AltStable.SyncAuthFor(e.name) == AltStable.AUTH_ASK
            and (not best or (e.at or 0) < (best.at or 0)) then
            best = e
        end
    end
    return best
end

local ShowNextSyncAsk

-- The prompt is over: free the one-at-a-time slot and look for the next asker
-- on the next frame, not from inside this one - the prompt is still being
-- taken down, and showing it again from its own OnHide is asking for trouble.
local function EndSyncAsk()
    syncPromptKey = nil
    if C_Timer and C_Timer.After then C_Timer.After(0, ShowNextSyncAsk) end
end

function ShowNextSyncAsk()
    -- Not in the middle of a fight: PLAYER_REGEN_ENABLED tries again.
    if InCombatLockdown and InCombatLockdown() then return end
    if not (AltStable.PendingSyncRequests and AltStable.ShowPrompt) then return end
    local e = NextSyncAsk()
    -- One at a time. Checked AFTER NextSyncAsk, not before: it reads the
    -- pending list, which announces an expired entry it drops - and that
    -- announcement can show a prompt from in here (review of #136).
    if not e or syncPromptKey then return end
    local key, name = e.key or AltStable.PeerKey(e.name), e.name
    AltStable.ShowPrompt("SyncAsk", {
        text = SYNC_ASK_TEXT:format(name),
        buttons = { "Allow", "Not now", "Never" },
        -- Every way out comes here, once (Prompt.lua). The answer FIRST, then
        -- the slot: answering announces, the announcement looks for the next
        -- asker, and with the slot still taken it waits for EndSyncAsk's next
        -- frame instead of opening inside this one (Codex, review of #136).
        --
        -- "Not now" (2) and Escape (nil) refuse nobody: the request stays
        -- waiting, in the Options list.
        onClose = function(choice)
            if choice == 1 then
                AltStable.AllowSyncPeer(name)
            elseif choice == 3 then
                AltStable.DenySyncPeer(name)
            end
            EndSyncAsk()
        end,
    })
    syncPrompted[key] = true
    syncPromptKey = key
end

-- Core calls this whenever an answer or a pending request changes.
function AltStable.OnSyncAuthChanged()
    if AltStable.RefreshSyncAnswers then AltStable.RefreshSyncAnswers() end
    -- No longer a question while the prompt was up - answered some other way,
    -- served through /alts sync consent, or expired: take it down, on the next
    -- frame so a button's own handler finishes first.
    local shown = syncPromptKey
    if shown and C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            if syncPromptKey ~= shown then return end
            local waiting = false
            for _, e in ipairs(AltStable.PendingSyncRequests()) do
                if (e.key or AltStable.PeerKey(e.name)) == shown then waiting = true end
            end
            if not waiting or AltStable.SyncAuthFor(shown) ~= AltStable.AUTH_ASK then
                AltStable.HidePrompt("SyncAsk")
            end
        end)
    end
    ShowNextSyncAsk()
end

do
    local regen = CreateFrame("Frame")
    regen:RegisterEvent("PLAYER_REGEN_ENABLED")
    regen:SetScript("OnEvent", function() ShowNextSyncAsk() end)
    AltStable._test.SyncAskRegenFrame = regen
end

AltStable._test.ResetSyncPrompts = function()
    syncPrompted = {}
    syncPromptKey = nil
    if AltStable.HidePrompt then AltStable.HidePrompt("SyncAsk") end
end

function AltStable.HideCharacter(guid)
    if not guid or not AltStable.SetCharacterHidden then return end
    AltStable.SetCharacterHidden(guid, true)
    AltStable.RefreshSheet()   -- repaints the grid, the totals and the restore list
end

function AltStable.ShowCharacter(guid)
    if not guid or not AltStable.SetCharacterHidden then return end
    AltStable.SetCharacterHidden(guid, false)
    AltStable.RefreshSheet()
end

-- Called by the menu's Forget entry. Asks first, always.
function AltStable.RequestForgetCharacter(char)
    if type(char) ~= "table" or not char.guid then return end
    if AltStable.ShowPrompt then
        local guid = char.guid
        AltStable.ShowPrompt("Forget", {
            text = FORGET_TEXT:format(char.name or "?"),
            buttons = { ACCEPT or "Forget", CANCEL or "Cancel" },
            onClose = function(choice)
                if choice ~= 1 then return end
                -- ForgetCharacter re-checks: it refuses the character you are
                -- playing. It is the authority on that, not the menu that
                -- offered the entry - state can change while a prompt sits open.
                local ok, info = AltStable.ForgetCharacter(guid)
                if not ok then
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[AltStable]|r " .. tostring(info))
                end
            end,
        })
        return
    end
    -- No prompt. Unlike hiding, this is NOT done anyway: forgetting is
    -- irreversible, and doing it unconfirmed because the confirmation was
    -- unavailable is the worst of the three possible behaviours.
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff00ccff[AltStable]|r cannot confirm here - use |cffffff00/alts forget "
        .. (char.name or "?") .. "|r")
end

-- Test seam (the AltStable._test convention). The sheet loads and builds under
-- tests/wow_stubs.lua, so the footer can be ASSERTED rather than grepped: a
-- count declared in one function and read in another compiled as a nil global
-- and errored on every build, and a source-text check could not see it.
AltStable._test = AltStable._test or {}
-- The character rows the grid would draw, in order. The footer counts are a
-- different code path from the list, and #21 has to be right in both.
AltStable._test.DisplayNames = function()
    local names = {}
    for _, item in ipairs(displayList) do
        if item.kind == "char" then names[#names + 1] = item.data.name end
    end
    return names
end

-- The hidden toggle is its OWN widget, so it gets its own seam rather than
-- being folded into FooterText: a test that could not tell the two apart would
-- not notice the note moving out of the gold string, which is the change.
AltStable._test.HiddenToggleText = function()
    local btn = totalsBar and totalsBar.hiddenBtn
    if not btn or not btn:IsShown() then return nil end
    return btn.label:GetText()
end

AltStable._test.ClickHiddenToggle = function()
    local btn = totalsBar and totalsBar.hiddenBtn
    if not btn or not btn:IsShown() then return false end
    local fn = btn:GetScript("OnClick")
    if not fn then return false end
    fn(btn)
    return true
end

-- The fade's own driver, so a test can advance it rather than wait 0.22s.
AltStable._test.OpenAnimTick = function()
    if not OpenAnimRunner then return nil end
    local fn = OpenAnimRunner:GetScript("OnUpdate")
    if not fn then return nil end
    return function(dt) fn(OpenAnimRunner, dt) end
end

AltStable._test.FooterText = function()
    if not totalsBar then return nil end
    return (totalsBar.left and totalsBar.left:GetText() or "")
        .. " || " .. (totalsBar.mid and totalsBar.mid:GetText() or "")
        .. " || " .. (totalsBar.right and totalsBar.right:GetText() or "")
end

-- Building alone, without opening: what the first build leaves behind.
AltStable._test.BuildSheet = function() CreateFrameIfNeeded() end

function AltStable.EnsureSheetVisible()
    CreateFrameIfNeeded()
    if not frame:IsShown() then frame:Show(); Refresh() end
end

function AltStable.ToggleRealm(realm)
    collapsed[realm]=not collapsed[realm]
    BuildDisplayList(); UpdateScroll(); UpdateRows(); UpdateTotalsBar()
    ResizeFrameToContent()
end
