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
-- The single write path for AltStableConfig
--
-- AltStableConfig is a SavedVariable, so the client writes it at logout and
-- there is normally nothing to save by hand. On 1.60.1.69913 it is written
-- and never read back (#23) - and nothing else an addon can write survives a
-- restart either: addon CVars and per-character SavedVariables were both
-- measured dead across a real exit. Every earlier "it persists" result came
-- from /reload, which keeps the process alive. The fix is Blizzard's.
--
-- Every mutation goes through here regardless, so that whatever the fix needs
-- - a migration, a validation pass, a different store - lands in one place
-- instead of in each checkbox handler. OnConfigChanged is empty on purpose.
--
-- The contract, enforced by a source scan in tests/test_scanner.lua:
--
--   * outside this file, assigning a value goes through SetConfigValue;
--   * an in-place edit of a nested table (plugins[k], minimapButton.angle,
--     toastProfessions[p]) is followed by OnConfigChanged(key);
--   * the one exception is an idempotent initialiser, `X = X or {}`.
--
-- This file owns the table and writes its defaults directly. Writes through a
-- local alias (Toasts' toastsShown set) are invisible to the scan and report
-- by hand. OnConfigChanged fires during a minimap drag, once per frame - so
-- whatever fills it later must be cheap, or debounce.
------------------------------------------------------------

function AltStable.OnConfigChanged(key)
end

-- Settings that decide WHICH characters we send. Changing one makes characters
-- newly eligible whose lastUpdate sits below every peer's watermark for us, so
-- they would be filtered out of every delta the peers ask for. Core answers the
-- next request from each peer in full (see OnSyncScopeChanged). Detected here
-- because this is the one path every writer uses: the Options checkbox, the
-- account box and /alts account.
local SYNC_SCOPE_KEYS = { sendAllAccounts = true, accountNumber = true }

function AltStable.SetConfigValue(key, value)
    AltStableConfig = AltStableConfig or {}
    local previous = AltStableConfig[key]
    AltStableConfig[key] = value
    AltStable.OnConfigChanged(key)
    -- tostring: accountNumber is a number from the Options box and /alts account
    -- but a string from EnsureDefaults and DevConfig, so re-entering the same
    -- "1" must not count as a change.
    if SYNC_SCOPE_KEYS[key] and tostring(previous) ~= tostring(value)
       and AltStable.OnSyncScopeChanged then
        AltStable.OnSyncScopeChanged()
    end
end

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
    -- Delta-sync watermarks: per peer, the lastUpdate we ask it to send changes
    -- since - the newest stamp received, capped a few minutes below the peer's
    -- own clock (see WatermarkCeiling in Core.lua). Keyed by short name. A peer
    -- that sends no clock has none, and gets full replies.
    --
    -- syncScopeGeneration / peerScopeGeneration: bumped when a setting widens
    -- which characters we send; each peer's next request is answered in full
    -- once per generation (see OnSyncScopeChanged in Core.lua).
    AltStableConfig.peerScopeGeneration = AltStableConfig.peerScopeGeneration or {}
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
    -- The default is the client's level cap; a stored value above it (the old
    -- TBC default of 70) could never be reached, so it is pulled down too.
    local levelCap = AltStable.API.LevelCap()
    if AltStableConfig.auditMinLevel == nil or AltStableConfig.auditMinLevel > levelCap then
        AltStableConfig.auditMinLevel = levelCap
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

-- The whitelist is mutated in place rather than assigned, so it cannot go
-- through SetConfigValue - but it reports through the same hook.
local function AddToWhitelist(name)
    if name == "" or IsWhitelisted(name) then return false end
    table.insert(AltStableConfig.whitelist, name)
    AltStable.OnConfigChanged("whitelist")
    return true
end

local function RemoveFromWhitelist(name)
    for i, n in ipairs(AltStableConfig.whitelist) do
        if n:lower() == name:lower() then
            table.remove(AltStableConfig.whitelist, i)
            AltStable.OnConfigChanged("whitelist")
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

------------------------------------------------------------
-- Has Blizzard fixed it?
--
-- AltStableConfig.svLoadCheck is written every session and can only come back
-- if the client actually read the SavedVariables file - so its presence at
-- login is proof, on whichever build fixed it. Needs no working store,
-- because it IS the test for one.
--
-- Lives here rather than in Tools/AltStableProbe: the probe answers when
-- someone remembers to ask, and the point is to be told on the first login
-- after the fix, without asking.
------------------------------------------------------------

local function CurrentBuild()
    return (type(GetBuildInfo) == "function" and select(2, GetBuildInfo())) or nil
end

-- `announce` is false on a /reload. A reload proves nothing - the client may
-- hand back cached data without touching disk, which is exactly how
-- per-character SavedVariables look persisted across /reload today while being
-- lost at every real restart. This check exists to catch the fix; announcing
-- it on a reload would be the same false positive it was written to avoid.
-- The marker is still rewritten on every UI load, so a session that reloaded
-- mid-way still leaves one behind for the next real login to find.
local function CheckSavedVariablesLoad(announce)
    local previous = AltStableConfig.svLoadCheck

    if announce and type(previous) == "table" and previous.stamp and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff55ff55AltStable:|r SavedVariables loaded this session "
            .. "(written " .. tostring(previous.stamp)
            .. " on build " .. tostring(previous.build) .. "; now on "
            .. tostring(CurrentBuild()) .. "). Issue #23 looks fixed - verify with a full exit, "
            .. "not /reload, before relying on it.")
    end

    AltStableConfig.svLoadCheck = {
        stamp = (type(date) == "function" and date("%Y-%m-%d %H:%M:%S")) or "?",
        build = CurrentBuild(),
    }
end

AltStable.CheckSavedVariablesLoad = CheckSavedVariablesLoad

-- PLAYER_LOGIN fires on /reload too, so it cannot tell the two apart;
-- PLAYER_ENTERING_WORLD can, and on 1.60.1.69913 carries
-- (isInitialLogin, isReloadingUi) - checked against the API dump, not
-- assumed. It also fires on every zone change with both false, which is
-- ignored entirely.
--
-- Residual limit, stated rather than solved: logging out to character select
-- and back in is an initial login inside the same process, and may also be
-- served from cache. Hence the message asks for a full exit to confirm.
function AltStable.HandleEnteringWorld(isInitialLogin, isReloadingUi)
    if not (isInitialLogin or isReloadingUi) then return end
    CheckSavedVariablesLoad(isInitialLogin and not isReloadingUi)
end

------------------------------------------------------------
-- Which build were the findings measured on?
--
-- docs/forever-api-notes.md and References/forever-api-<build>.md were
-- measured against one client build, and the beta updates without
-- announcement. The build therefore lives in the SOURCE - the one thing that
-- survives a restart on this client - and a mismatch at login says so.
--
-- Bump this after re-measuring on a new build. Until someone does, it says so
-- on every login, which is the point: the reminder has to outlast the moment
-- someone would have noticed.
------------------------------------------------------------

local MEASURED_ON_BUILD = "69913"
AltStable.MEASURED_ON_BUILD = MEASURED_ON_BUILD

local function CheckClientBuild()
    local build = CurrentBuild()
    -- An unreadable build is not evidence of a new one; stay quiet.
    if not build or build == MEASURED_ON_BUILD then return end
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffffcc00AltStable:|r this client is build " .. tostring(build)
            .. "; everything in the API notes was measured on " .. MEASURED_ON_BUILD
            .. ". Treat it as unverified: re-run |cffffff00/apidump|r, re-check "
            .. "SavedVariables (#23) and the camera CVars (#25), then bump "
            .. "MEASURED_ON_BUILD in Config.lua.")
    end
end

AltStable.CheckClientBuild = CheckClientBuild

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:SetScript("OnEvent", function(_, event, isInitialLogin, isReloadingUi)
    if event == "PLAYER_LOGIN" then
        EnsureDefaults()
        CheckClientBuild()
    elseif event == "PLAYER_ENTERING_WORLD" then
        AltStable.HandleEnteringWorld(isInitialLogin, isReloadingUi)
    end
end)
