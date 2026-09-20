------------------------------------------------------------
-- AltStable Config
-- Owns the SavedVariable defaults and exposes the public config API
-- (whitelist mutation, defaults init). The standalone config popup
-- has been removed — all settings now live in the in-window Options
-- section (open via /alts config or the minimap right-click).
--
-- Settings:
--   syncMode   : "guild" | "whisper"
--   whitelist  : { "Name-Realm", ... }  (used in whisper mode)
--   accountNumber : number
------------------------------------------------------------

AltStable      = AltStable or {}
AltStableConfig = AltStableConfig or {}

local CAMERA_PRESENTATION_DEFAULTS_VERSION = 10

------------------------------------------------------------
-- Defaults
------------------------------------------------------------

local function EnsureDefaults()
    AltStableConfig.syncMode      = AltStableConfig.syncMode      or "whisper"
    AltStableConfig.whitelist     = AltStableConfig.whitelist     or {}
    AltStableConfig.accountNumber = AltStableConfig.accountNumber or ""
    if AltStableConfig.sendAllAccounts == nil then
        AltStableConfig.sendAllAccounts = false
    end
    if AltStableConfig.toastsEnabled == nil then
        AltStableConfig.toastsEnabled = true
    end
    if AltStableConfig.mailAlertsEnabled == nil then
        AltStableConfig.mailAlertsEnabled = true
    end
    if not AltStableConfig.toastProfessions then
        AltStableConfig.toastProfessions = {
            Tailoring     = true,
            Alchemy       = true,
            Jewelcrafting = true,
        }
    end
    -- On-demand plugins (LoadOnDemand addons AltStable loads at login when
    -- enabled here). Default both on so existing users keep both tabs.
    if not AltStableConfig.plugins then
        AltStableConfig.plugins = { professions = true, roster = true, instances = true, warband = true }
    end
    -- Delta-sync watermarks: newest lastUpdate value received from each peer,
    -- so a sync request pulls only what changed since. Keyed by short name.
    if not AltStableConfig.peerWatermarks then
        AltStableConfig.peerWatermarks = {}
    end
    -- Best-in-Slot phase the BiS column and gear tooltips compare against.
    -- Existing users get T6 (the current raid tier) rather than being
    -- silently left on whatever the old hardcoded constant was.
    AltStableConfig.bisTier = AltStableConfig.bisTier or "T6"

    -- Roster gear audit. minGemQuality is the lowest gem quality considered
    -- acceptable (0 disables gem checks entirely, 3 = Rare, 4 = Epic), matching
    -- CLA's "minimum required gem quality" selector. auditMinLevel keeps the
    -- audit quiet on levelling alts, where a bare enchant slot is not a finding.
    if AltStableConfig.minGemQuality == nil then
        AltStableConfig.minGemQuality = 3
    end
    if AltStableConfig.auditMinLevel == nil then
        AltStableConfig.auditMinLevel = 70
    end

    -- Appearance defaults
    AltStableConfig.theme = AltStableConfig.theme or "dark"
    if AltStableConfig.scale == nil then
        AltStableConfig.scale = 1.0
    end

    -- World camera presentation defaults (live player only). The target is a
    -- portrait-like composition: the camera swings around to the player's
    -- front, pushes the character left of the sheet, and restores everything
    -- on close.
    if AltStableConfig.enableWorldCameraPresentation == nil then
        AltStableConfig.enableWorldCameraPresentation = true
    end
    if AltStableConfig.worldCameraPresentationDebug == nil then
        AltStableConfig.worldCameraPresentationDebug = false
    end
    if AltStableConfig.worldCameraEnterDuration == nil then
        AltStableConfig.worldCameraEnterDuration = 1.50
    end
    if AltStableConfig.worldCameraExitDuration == nil then
        AltStableConfig.worldCameraExitDuration = 0.45
    end
    -- v10 camera migration: mirror Narcissus Classic's eased 1.5s yaw, but
    -- use the leftward direction that keeps AltStable's composition visible.
    -- Because the yaw speed eases down during the move, the configured degree
    -- value needs to be higher than the apparent final rotation. Visual zoom
    -- is closer, while shoulder placement still uses the old 6.2 reference
    -- because the user's ideal state came from zooming in after placement.
    do
        local version = tonumber(AltStableConfig.worldCameraPresentationDefaultsVersion) or 0
        if version < CAMERA_PRESENTATION_DEFAULTS_VERSION then
            local duration = tonumber(AltStableConfig.worldCameraEnterDuration)
            if not duration or duration < 1.0 or math.abs(duration - 0.60) < 0.01 then
                AltStableConfig.worldCameraEnterDuration = 1.50
            end

            AltStableConfig.worldCameraZoomPreset = 2.2
            AltStableConfig.worldCameraShoulderZoomReference = 6.2
            AltStableConfig.worldCameraMountedZoomPreset = 8.0
            AltStableConfig.worldCameraMountedShoulderOffset = 8.0
            AltStableConfig.worldCameraForceMountedPresentation = false
            AltStableConfig.worldCameraYawDegrees = 430
            AltStableConfig.worldCameraYawOffset = -0.22
            AltStableConfig.worldCameraShoulderMult = 1.0

            AltStableConfig.worldCameraContinuousOrbit = true
            AltStableConfig.worldCameraPresentationDefaultsVersion = CAMERA_PRESENTATION_DEFAULTS_VERSION
        end
    end
    if AltStableConfig.worldCameraZoomPreset == nil then
        AltStableConfig.worldCameraZoomPreset = 2.2
    end
    if AltStableConfig.worldCameraShoulderZoomReference == nil then
        AltStableConfig.worldCameraShoulderZoomReference = 6.2
    end
    if AltStableConfig.worldCameraMountedZoomPreset == nil then
        AltStableConfig.worldCameraMountedZoomPreset = 8.0
    end
    if AltStableConfig.worldCameraMountedShoulderOffset == nil then
        AltStableConfig.worldCameraMountedShoulderOffset = 8.0
    end
    if AltStableConfig.worldCameraForceMountedPresentation == nil then
        AltStableConfig.worldCameraForceMountedPresentation = false
    end
    if AltStableConfig.worldCameraYawOffset == nil then
        AltStableConfig.worldCameraYawOffset = -0.22
    end
    if AltStableConfig.worldCameraYawDegrees == nil then
        AltStableConfig.worldCameraYawDegrees = 430
    end
    if AltStableConfig.worldCameraSavedViewSlot == nil then
        AltStableConfig.worldCameraSavedViewSlot = 5
    end
    -- Lateral character placement: multiplier applied on top of Narcissus's
    -- per-race shoulder offset formula (zoom * factor1 + factor2). Higher
    -- pushes the character further LEFT on screen, making more room for
    -- the AltStable window on the right. 1.0 = Narcissus default.
    if AltStableConfig.worldCameraShoulderMult == nil then
        AltStableConfig.worldCameraShoulderMult = 1.0
    end
    -- Continuous slow orbit follows Narcissus's default camera presentation:
    -- after the entry yaw, the world keeps turning slowly around the player.
    if AltStableConfig.worldCameraContinuousOrbit == nil then
        AltStableConfig.worldCameraContinuousOrbit = true
    end
    if AltStableConfig.worldCameraOrbitSpeed == nil then
        -- Matches Narcissus's ZoomFactor.toSpeed; slow enough to be ambient,
        -- fast enough to be visible. Tweak with /run AltStableConfig.worldCameraOrbitSpeed = N
        AltStableConfig.worldCameraOrbitSpeed = 0.005
    end
    if AltStableConfig.enableWorldCameraSalute == nil then
        AltStableConfig.enableWorldCameraSalute = false
    end

    -- Open-window UX defaults
    if AltStableConfig.enableOpenAnimation == nil then
        AltStableConfig.enableOpenAnimation = true
    end
    if AltStableConfig.rememberWindowPosition == nil then
        AltStableConfig.rememberWindowPosition = true
    end

    -- Minimap button (LibDBIcon-free; angle-around-minimap persistence)
    AltStableConfig.minimapButton = AltStableConfig.minimapButton or {}
    if AltStableConfig.minimapButton.hide == nil then
        AltStableConfig.minimapButton.hide = false
    end
    if AltStableConfig.minimapButton.angle == nil then
        AltStableConfig.minimapButton.angle = 200 -- lower-left default
    end
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function IsWhitelisted(name)
    for _, n in ipairs(AltStableConfig.whitelist) do
        if n:lower() == name:lower() then return true end
    end
    return false
end

local function AddToWhitelist(name)
    if name == "" or IsWhitelisted(name) then return false end
    table.insert(AltStableConfig.whitelist, name)
    return true
end

local function RemoveFromWhitelist(name)
    for i, n in ipairs(AltStableConfig.whitelist) do
        if n:lower() == name:lower() then
            table.remove(AltStableConfig.whitelist, i)
            return true
        end
    end
    return false
end

-- Expose so Core.lua can call these
AltStable.IsWhitelisted    = IsWhitelisted
AltStable.AddToWhitelist   = AddToWhitelist
AltStable.RemoveFromWhitelist = RemoveFromWhitelist
AltStable.EnsureConfigDefaults = EnsureDefaults


------------------------------------------------------------
-- Backwards-compat: the standalone config popup has been replaced by
-- the in-window Options section (sidebar -> Options). Keep the public
-- API surface so /alts config and the minimap right-click still work.
-- AltStable.OpenConfig() now opens the AltStable sheet on the Options
-- section directly, instead of building its own popup.
------------------------------------------------------------

function AltStable.OpenConfig()
    if AltStable.EnsureSheetVisible then
        AltStable.EnsureSheetVisible()
    elseif AltStable.ShowSheet then
        AltStable.ShowSheet()
    end
    if AltStable._SwitchToOptions then
        AltStable._SwitchToOptions()
    end
end

------------------------------------------------------------
-- Init on login
------------------------------------------------------------

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function()
    EnsureDefaults()
end)
