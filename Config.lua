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
-- there is normally nothing to save by hand. Through 1.60.1.69977 it was
-- written and never read back (#23); 1.60.1.70009 fixed that, for this store
-- and for per-character SavedVariables both - measured across a real exit, not
-- a /reload.
--
-- Addon CVars are a separate question and were NOT re-measured on 70009: they
-- were dead across a real exit through 69977, and the SavedVariables fix does
-- not imply anything about them. (#25 used to be cited here as a second case of
-- a CVar write going nowhere. It is not one - the camera did read the value,
-- and another setting undid it - so this rests on the 69977 measurement alone.)
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
        }
    end
    AltStableConfig.toastProfessions.Jewelcrafting = nil   -- not a Vanilla profession (#8)
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
    -- Retired with the BiS column (#8): nothing reads it any more.
    AltStableConfig.bisTier = nil

    -- Characters hidden from the sheet, keyed by GUID: names are not unique on
    -- Forever (every character has a surname, and two can share a first name).
    --
    -- Per ACCOUNT, deliberately. This lives in AltStableConfig, which is not
    -- synced, so hiding an alt here leaves it visible on the other account. It
    -- is a display preference, not character data - and the record keeps
    -- syncing either way, so unhiding shows current data rather than starting a
    -- re-sync (which would also disturb the delta watermarks).
    AltStableConfig.hiddenCharacters = AltStableConfig.hiddenCharacters or {}

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

------------------------------------------------------------
-- Hidden characters
--
-- Through the config seam like every other setting write, so one place still
-- owns persistence and the change notification.
------------------------------------------------------------

------------------------------------------------------------
-- Forgotten characters (#65)
--
-- A record deleted locally comes straight back: a peer still holds it and
-- re-sends it on the next sync. So forgetting has to be remembered.
--
-- PER ACCOUNT, and deliberately not on the wire. Each account forgets
-- independently, which needs no protocol change and is the honest model given
-- the config is per account anyway - account A deciding that a character is
-- gone is not evidence for account B, which may still be playing it.
--
-- Each entry is { at = <when a peer last offered it>, name = <what it was
-- called> }.
--
-- `at` is deliberately not "when it was forgotten". That is what lets the list
-- expire safely: a tombstone has to outlive every peer that still remembers the
-- character, and nothing else knows how long that is. While anyone keeps
-- offering it the stamp keeps moving and the tombstone stays; once they have
-- all forgotten too, it ages out and the list stops growing on an account that
-- reorganises alts often.
--
-- `name` is kept only so the player can read the list and undo by name. The
-- record itself is gone, so without it a mistake could only be undone by
-- copying a GUID out of a chat line.
------------------------------------------------------------

-- Bounded by COUNT, not by age.
--
-- The first version expired a tombstone after a month with nobody offering the
-- record, on the theory that the stamp would keep moving while any peer still
-- held the character. It does not: a dead character's lastUpdate is frozen, so
-- it never passes a delta's filter and rides only FULL replies. In the normal
-- login-delta steady state the stamp never moves at all, the tombstone drops on
-- day 31, and the next full sync - a /alts cleanup, a scope change, or the
-- Warband plugin resetting watermarks at login when it has no inventory -
-- brings the character straight back.
--
-- A count cap gets what the issue actually asked for ("so the list does not
-- grow without bound on an account that reorganises alts often") without a
-- clock that can resurrect a character. An entry is a guid, a name and a
-- number; two hundred of them is nothing, and nobody deletes two hundred
-- characters. When the cap is passed the OLDEST go, which is why the stamp is
-- still refreshed when a peer offers the record: a tombstone anyone is still
-- arguing about should be the last to be evicted.
local TOMBSTONE_CAP = 200

function AltStable.IsCharacterForgotten(guid)
    if not guid then return false end
    local gone = AltStableConfig and AltStableConfig.forgottenCharacters
    return (gone and gone[guid]) and true or false
end

-- Records the tombstone, or refreshes how recently a peer offered the record.
-- An existing name is never overwritten with nothing: the refresh path runs
-- when a peer offers the record back, and the peer's copy is not the authority
-- on what the player called it when they forgot it.
function AltStable.MarkCharacterForgotten(guid, when, name)
    if not guid then return false end
    AltStableConfig = AltStableConfig or {}
    local current = AltStableConfig.forgottenCharacters or {}
    local copy = {}
    for k, v in pairs(current) do copy[k] = v end
    local prev = current[guid]
    copy[guid] = {
        at   = tonumber(when) or time(),
        name = name or (type(prev) == "table" and prev.name) or nil,
    }
    AltStable.SetConfigValue("forgottenCharacters", copy)
    return true
end

-- The GUID we hold for a forgotten character of this name, if any.
function AltStable.ForgottenGuidFor(name)
    if not name or name == "" then return nil end
    local want = name:lower()
    for guid, e in pairs((AltStableConfig or {}).forgottenCharacters or {}) do
        local held = type(e) == "table" and e.name
        if held and (held:lower() == want or held:lower():match("^(%S+)") == want) then
            return guid, held
        end
    end
    return nil
end

function AltStable.UnforgetCharacter(guid)
    if not guid or not AltStable.IsCharacterForgotten(guid) then return false end
    local copy = {}
    for k, v in pairs(AltStableConfig.forgottenCharacters or {}) do copy[k] = v end
    copy[guid] = nil
    AltStable.SetConfigValue("forgottenCharacters", copy)

    -- Dropping the tombstone is not enough to bring the character back, and
    -- saying it was would be a lie. The record's lastUpdate is frozen at
    -- whenever it was last played, and every peer's watermark for us has long
    -- since passed it - so it fails the delta filter and is never offered
    -- again. Only a full reply carries it, which means asking for one.
    if AltStable.ResetPeerWatermarks then AltStable.ResetPeerWatermarks() end
    return true
end

-- Keep the list under the cap, oldest out first. Returns how many went.
function AltStable.PruneForgotten()
    AltStableConfig = AltStableConfig or {}
    local gone = AltStableConfig.forgottenCharacters
    if not gone then return 0 end

    local all = {}
    for guid, e in pairs(gone) do
        all[#all + 1] = { guid = guid, at = (type(e) == "table" and tonumber(e.at)) or 0 }
    end
    if #all <= TOMBSTONE_CAP then return 0 end

    -- Newest first, then keep the first TOMBSTONE_CAP of them.
    table.sort(all, function(a, b)
        if a.at ~= b.at then return a.at > b.at end
        return a.guid < b.guid     -- deterministic when stamps tie
    end)

    local copy = {}
    for i = 1, TOMBSTONE_CAP do copy[all[i].guid] = gone[all[i].guid] end
    AltStable.SetConfigValue("forgottenCharacters", copy)
    return #all - TOMBSTONE_CAP
end

function AltStable.ForgottenList()
    local out = {}
    for guid, e in pairs((AltStableConfig or {}).forgottenCharacters or {}) do
        out[#out + 1] = {
            guid = guid,
            name = (type(e) == "table" and e.name) or nil,
            lastOffered = (type(e) == "table" and e.at) or nil,
        }
    end
    table.sort(out, function(a, b) return (a.name or a.guid) < (b.name or b.guid) end)
    return out
end

AltStable._TOMBSTONE_CAP = TOMBSTONE_CAP

function AltStable.IsCharacterHidden(guid)
    if not guid then return false end
    local hidden = AltStableConfig and AltStableConfig.hiddenCharacters
    return (hidden and hidden[guid]) and true or false
end

function AltStable.SetCharacterHidden(guid, hidden)
    if not guid then return end
    AltStableConfig = AltStableConfig or {}
    local current = AltStableConfig.hiddenCharacters or {}
    local copy = {}
    for k, v in pairs(current) do copy[k] = v end
    copy[guid] = hidden and true or nil     -- nil, not false: absent means shown
    AltStable.SetConfigValue("hiddenCharacters", copy)
end

-- The hidden characters that still have a record, sorted by name.
--
-- A guid with no record (deleted character, /alts cleanup, a peer not synced
-- yet) is skipped rather than shown as a bare guid, but the entry is KEPT: the
-- record usually comes back on the next sync, and it should come back hidden
-- rather than silently reappearing in the grid.
function AltStable.HiddenCharacterList()
    local out = {}
    local hidden = AltStableConfig and AltStableConfig.hiddenCharacters or {}
    for guid in pairs(hidden) do
        local c = AltStableDB and AltStableDB[guid]
        if type(c) == "table" and c.name then
            out[#out + 1] = { guid = guid, name = c.name, realm = c.realm, class = c.class,
                              level = c.level }
        end
    end
    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
    return out
end

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
-- When was this file last written, and by which build?
--
-- This started as the detector for #23: a marker that could only come back if
-- the client had read the SavedVariables file, announced at login on whichever
-- build fixed it. Build 1.60.1.70009 fixed it, so the announcement is gone -
-- it would now be a green line at every single login, saying what the sheet
-- being full of alts already says.
--
-- The marker itself stays, and only now means anything, because it survives:
-- a stamp and a build number on the last session that wrote this file. That is
-- the first thing worth knowing when a store looks stale or a future build
-- regresses. Measuring persistence per build is still the probe's job
-- (Tools/AltStableProbe, and docs/RUNBOOK.md).
------------------------------------------------------------

local function CurrentBuild()
    return (type(GetBuildInfo) == "function" and select(2, GetBuildInfo())) or nil
end

-- Written at PLAYER_ENTERING_WORLD, so the stamp is when the session STARTED,
-- not when the file was flushed - the client writes at logout, a play session
-- later. Close enough to answer "which session, on which build, last wrote
-- this store", which is what it is for; wrong if read as a write time.
-- Re-stamped on a /reload too, since that session goes on to write the file.
local function CheckSavedVariablesLoad()
    AltStableConfig.svLoadCheck = {
        stamp = (type(date) == "function" and date("%Y-%m-%d %H:%M:%S")) or "?",
        build = CurrentBuild(),
    }
end

AltStable.CheckSavedVariablesLoad = CheckSavedVariablesLoad

-- PLAYER_ENTERING_WORLD carries (isInitialLogin, isReloadingUi) on
-- 1.60.1.69913 through .70009 - checked against the API dump, not assumed. It
-- also fires on every zone change with both false, and a zone change is not a
-- write worth stamping, so those are ignored entirely.
function AltStable.HandleEnteringWorld(isInitialLogin, isReloadingUi)
    if not (isInitialLogin or isReloadingUi) then return end
    CheckSavedVariablesLoad()
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

local MEASURED_ON_BUILD = "70009"
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
            .. "SavedVariables persistence with the probe and the camera CVars (#25), "
            .. "then bump MEASURED_ON_BUILD in Config.lua.")
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
        -- Drop tombstones nobody has offered in a month (#65). Once here,
        -- because it only changes on the scale of months and a sweep on every
        -- sync would rewrite the config for nothing.
        AltStable.PruneForgotten()
    elseif event == "PLAYER_ENTERING_WORLD" then
        AltStable.HandleEnteringWorld(isInitialLogin, isReloadingUi)
    end
end)
