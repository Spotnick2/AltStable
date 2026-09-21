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
-- CVar-backed settings store
--
-- This client writes SavedVariables and never reads them back (#23), so
-- AltStableConfig is empty at every login: no whitelist, no account number,
-- nothing. CVars DO persist - measured across three sessions on 1.60.1.69913,
-- surviving /reload, loaded from Config.wtf before anything registers them.
-- So the settings that cannot be regenerated live in a CVar until the client
-- is fixed.
--
-- Deliberately small. Only values that are set once and never derived go in
-- here: a roster entry rewrites itself on every scan, but a whitelist the user
-- typed is gone forever. Keeping the payload short also keeps us clear of a
-- value-length limit nobody has measured yet.
--
-- Two traps, both measured:
--
--   * READ BEFORE REGISTERING. RegisterCVar(name, default) takes a default, so
--     registering first can overwrite the value you were about to read - and
--     the whole store then looks like it never persisted.
--   * Client-local. GetCVarInfo reports isStoredServerAccount and
--     isStoredServerCharacter both false, so settings do not follow the player
--     to another machine. Acceptable for a per-client whitelist; say so rather
--     than let someone discover it.
------------------------------------------------------------

local STORE_CVAR = "altstable_config"

-- What persists, and how to read it back. Extend this list rather than the
-- encoder; `kind` is all the encoder needs to know.
local PERSISTED = {
    { key = "accountNumber",    kind = "string" },
    { key = "syncMode",         kind = "string" },
    { key = "whitelist",        kind = "list"   },
    { key = "sendAllAccounts",  kind = "bool"   },
    { key = "toastsEnabled",    kind = "bool"   },
    { key = "mailAlertsEnabled",kind = "bool"   },
}

-- `;` separates pairs, `,` separates list items, `=` separates key from value.
-- Those three and `%` itself are percent-encoded so a character name can
-- contain anything: Forever surnames are space-separated and cross-realm peers
-- carry a "-Realm" suffix, and neither is worth trusting to luck. Quotes and
-- newlines are avoided entirely - Config.wtf stores values as SET name "value"
-- and nobody has measured what it does with either.
local function Escape(v)
    return (tostring(v or "")
        :gsub("%%", "%%25")
        :gsub(";", "%%3B")
        :gsub(",", "%%2C")
        :gsub("=", "%%3D"))
end

local function Unescape(v)
    return (tostring(v or "")
        :gsub("%%3D", "=")
        :gsub("%%2C", ",")
        :gsub("%%3B", ";")
        :gsub("%%25", "%%"))
end

local function EncodeConfig(cfg)
    local parts = {}
    for _, field in ipairs(PERSISTED) do
        local v = cfg[field.key]
        if field.kind == "list" then
            if type(v) == "table" and #v > 0 then
                local items = {}
                for i, item in ipairs(v) do items[i] = Escape(item) end
                parts[#parts + 1] = field.key .. "=" .. table.concat(items, ",")
            end
        elseif field.kind == "bool" then
            if v ~= nil then
                parts[#parts + 1] = field.key .. "=" .. (v and "1" or "0")
            end
        elseif v ~= nil and v ~= "" then
            parts[#parts + 1] = field.key .. "=" .. Escape(v)
        end
    end
    return table.concat(parts, ";")
end

local function DecodeConfig(raw, cfg)
    if type(raw) ~= "string" or raw == "" then return 0 end

    local kinds = {}
    for _, field in ipairs(PERSISTED) do kinds[field.key] = field.kind end

    local applied = 0
    for pair in raw:gmatch("[^;]+") do
        local key, value = pair:match("^([^=]+)=(.*)$")
        local kind = key and kinds[key]
        if kind == "list" then
            local list = {}
            for item in value:gmatch("[^,]+") do
                list[#list + 1] = Unescape(item)
            end
            cfg[key] = list
            applied = applied + 1
        elseif kind == "bool" then
            cfg[key] = (value == "1")
            applied = applied + 1
        elseif kind then
            cfg[key] = Unescape(value)
            applied = applied + 1
        end
        -- An unknown key is left alone rather than dropped: an older client
        -- reading a newer store should ignore what it cannot use, not discard
        -- it. Since we rewrite the whole value on save, that is a one-way
        -- tolerance - noted rather than solved, because nothing writes two
        -- versions of this store today.
    end
    return applied
end

local function StoreRead()
    if type(GetCVar) ~= "function" then return nil end
    local ok, raw = pcall(GetCVar, STORE_CVAR)
    if ok then return raw end
    return nil
end

local function StoreEnsureRegistered()
    -- Only ever register when the CVar is genuinely absent. Registering an
    -- existing one with a default is how you destroy the value you came for.
    if StoreRead() ~= nil then return true end
    local register = RegisterCVar or (C_CVar and C_CVar.RegisterCVar)
    if type(register) ~= "function" then return false end
    return (pcall(register, STORE_CVAR, ""))
end

function AltStable.LoadConfigFromCVar()
    local raw = StoreRead()
    if raw == nil then return 0 end
    return DecodeConfig(raw, AltStableConfig)
end

function AltStable.SaveConfigToCVar()
    if type(SetCVar) ~= "function" then return false, "no SetCVar" end
    StoreEnsureRegistered()

    local encoded = EncodeConfig(AltStableConfig)
    local ok = pcall(SetCVar, STORE_CVAR, encoded)
    if not ok then return false, "SetCVar threw" end

    -- Verify rather than trust. A write that is REFUSED is easy to notice; a
    -- write that silently truncates is the one that quietly loses half a
    -- whitelist and reads back as success. Neither has been measured on this
    -- client, so check the round-trip every time - it costs one string
    -- comparison against a value we already have in hand.
    local readBack = StoreRead()
    if readBack ~= encoded then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cffff5555AltStable:|r settings did not survive the write ("
                .. #encoded .. " chars sent, "
                .. (readBack and #readBack or 0) .. " read back). "
                .. "Your whitelist may not persist - please report this with your settings count.")
        end
        return false, "round-trip mismatch"
    end
    return true
end


------------------------------------------------------------
-- Defaults
------------------------------------------------------------

local function EnsureDefaults()
    -- Before the defaults, not after: a default applied first would look like
    -- a real setting and be written back over the stored one.
    AltStable.LoadConfigFromCVar()

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
    AltStable.SaveConfigToCVar()
    return true
end

local function RemoveFromWhitelist(name)
    for i, n in ipairs(AltStableConfig.whitelist) do
        if n:lower() == name:lower() then
            table.remove(AltStableConfig.whitelist, i)
            AltStable.SaveConfigToCVar()
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
-- Has the client been fixed?
--
-- The CVar store is a workaround for #23, and workarounds outlive their cause
-- silently. AltStableConfig.svLoadCheck is written every session and can only
-- come back if the client actually loaded the SavedVariables file - so its
-- presence at login is proof the bug is gone, on whichever build fixed it.
--
-- This has to live in the addon rather than in Tools/AltStableProbe: the probe
-- answers the question when someone remembers to ask, and the point is to be
-- told without asking, on the first login after a client update.
------------------------------------------------------------

local function CheckSavedVariablesLoad()
    local previous = AltStableConfig.svLoadCheck
    local build = (type(GetBuildInfo) == "function" and select(2, GetBuildInfo())) or "?"

    if type(previous) == "table" and previous.stamp then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff55ff55AltStable:|r account-wide SavedVariables loaded this session "
                .. "(written " .. tostring(previous.stamp)
                .. " on build " .. tostring(previous.build) .. "; now on " .. tostring(build) .. "). "
                .. "Issue #23 looks fixed - the CVar-backed settings store can be retired.")
        end
    end

    AltStableConfig.svLoadCheck = {
        stamp = (type(date) == "function" and date("%Y-%m-%d %H:%M:%S")) or "?",
        build = build,
    }
end

AltStable.CheckSavedVariablesLoad = CheckSavedVariablesLoad

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function()
    CheckSavedVariablesLoad()
    EnsureDefaults()
end)
