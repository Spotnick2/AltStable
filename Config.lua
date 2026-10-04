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
    -- but a string from EnsureDefaults (and older saved configs), so re-entering the same
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
    -- #58: your other accounts sync through Battle.net unless switched off.
    if AltStableConfig.bnetSync == nil then AltStableConfig.bnetSync = true end
    AltStableConfig.syncAuth      = AltStableConfig.syncAuth      or {}   -- #61: answers, by peer key
    AltStableConfig.accountNumber = AltStableConfig.accountNumber or ""
    if AltStableConfig.sendAllAccounts == nil then
        AltStableConfig.sendAllAccounts = false
    end
    -- The Warband tab's view (#153). Its tabs (warbandTabs) are seeded by the
    -- plugin, which owns their defaults, the first time it draws.
    if AltStableConfig.warbandView == nil then AltStableConfig.warbandView = "single" end
    if AltStableConfig.warbandScope == nil then AltStableConfig.warbandScope = "warband" end
    if AltStableConfig.warbandRuleset == nil then AltStableConfig.warbandRuleset = "current" end
    if AltStableConfig.warbandTab == nil then AltStableConfig.warbandTab = 1 end
    -- Pets in the Roster scene (#75): an option, off unless asked for.
    if AltStableConfig.rosterPets == nil then
        AltStableConfig.rosterPets = false
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
    -- Same shape as hiddenCharacters, which means the same default. A direct
    -- index - which the #69 menu will want - errors on a fresh profile without
    -- it, and "deliberately the same shape" has to include this.
    if AltStableConfig.favouriteCharacters == nil then
        AltStableConfig.favouriteCharacters = {}
    end
    AltStableConfig.hiddenCharacters = AltStableConfig.hiddenCharacters or {}

    -- Show hidden characters in the SHEET, dimmed, so they can be unhidden from
    -- where they were hidden (#69). Off by default, because on means the sheet
    -- is showing you rows you told it not to.
    --
    -- Named for the sheet on purpose. It is a management view; the Roster's
    -- 3D camp is a showcase and never shows a hidden character whatever this
    -- says. A name like "showHidden" would have invited exactly that.
    -- Additive, absence means off: a profile written before this existed reads
    -- back unchanged.
    if AltStableConfig.sheetShowHidden == nil then
        AltStableConfig.sheetShowHidden = false
    end

    -- Retired with the gem audit. Sockets, gems and meta-gems were introduced in
    -- TBC and do not exist here, so the quality threshold this configured is
    -- meaningless on this client - it is an enchant audit now, and enchants need
    -- no quality threshold: a slot either has one or it does not.
    --
    -- Actively cleared rather than merely no longer defaulted. It has been
    -- written to real profiles on disk, and a key nothing reads is a key the
    -- next reader has to work out the meaning of. Same treatment bisTier got.
    AltStableConfig.minGemQuality = nil

    -- auditMinLevel is NOT retired with it, which is the distinction the first
    -- pass at this got wrong: it was cleared alongside minGemQuality on the
    -- argument that enchants need no threshold, but that argument is about
    -- QUALITY. A level gate is a different setting and enchants still want one -
    -- a level 14 alt in quest greens does not need six amber rows about gear it
    -- will replace this afternoon.
    --
    -- Nor is it hardcoded, which is what replaced it: a floor at the level cap
    -- silently means "no character is audited until it is finished levelling",
    -- and deciding that for the player while deleting the setting they had is
    -- two changes wearing one coat. The default IS the cap; the key is honoured
    -- when it is there.
    if AltStableConfig.auditMinLevel == nil then
        AltStableConfig.auditMinLevel =
            (AltStable.API and AltStable.API.LevelCap and AltStable.API.LevelCap()) or 60
    end

    -- Appearance defaults
    --
    -- `skin` is which MATERIAL the window is made of (#97); `theme` is the
    -- older and much smaller question of whether the accent is gold or your
    -- class colour. They are deliberately separate: one palette, two
    -- independent choices on top of it.
    --
    -- Not defaulted here on purpose. AltStable.SkinName() resolves it at call
    -- time and falls back, so an absent key means "the current default" rather
    -- than freezing today's default onto every profile on disk - which is what
    -- makes changing the default later a change rather than a migration.
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
    -- Each sheet tab's sort survives a logout (#160), in sheetSort. Off: every
    -- tab starts on level, highest first, at login, and keeps its own sort only
    -- for the session.
    if AltStableConfig.rememberSortOrder == nil then
        AltStableConfig.rememberSortOrder = true
    end
    if AltStableConfig.sidebarCompact == nil then
        AltStableConfig.sidebarCompact = false
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
    -- Options may be open: `/alts whitelist` adds through here too (#158 review).
    if AltStable.RefreshOptionsWhitelist then AltStable.RefreshOptionsWhitelist() end
    return true
end

local function RemoveFromWhitelist(name)
    for i, n in ipairs(AltStableConfig.whitelist) do
        if n:lower() == name:lower() then
            table.remove(AltStableConfig.whitelist, i)
            AltStable.OnConfigChanged("whitelist")
            if AltStable.RefreshOptionsWhitelist then AltStable.RefreshOptionsWhitelist() end
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

-- The GUID we hold for a forgotten character of this name.
--
-- Same rule as ResolveCharacter, and for the same reason: returning the first
-- match let /alts unforget Karuzo lift an arbitrary one of two tombstones,
-- letting that character back on the next sync while the one the player meant
-- stayed suppressed. Undo has to be as precise as the thing it undoes.
--
-- Returns guid, name - or nil, message when it cannot tell which.
function AltStable.ForgottenGuidFor(name)
    if not name or name == "" then return nil, "usage: a character name" end
    local want = name:lower()

    local full, partial = {}, {}
    for guid, e in pairs((AltStableConfig or {}).forgottenCharacters or {}) do
        local held = type(e) == "table" and e.name
        if held then
            local n = held:lower()
            if n == want then
                full[#full + 1] = { guid = guid, name = held }
            elseif n:match("^(%S+)") == want then
                partial[#partial + 1] = { guid = guid, name = held }
            end
        end
    end

    local function ambiguous(list)
        table.sort(list, function(a, b)
            if a.name ~= b.name then return a.name < b.name end
            return a.guid < b.guid
        end)
        local shown = {}
        for _, e in ipairs(list) do
            -- The GUID, because two tombstones can hold the same name and the
            -- records they came from are gone - there is no realm left to show.
            shown[#shown + 1] = e.name .. " (" .. e.guid .. ")"
        end
        return nil, "|cffff8800" .. name .. " is ambiguous|r - " .. table.concat(shown, ", ")
            .. ". Use the GUID."
    end

    -- A GUID is always an unambiguous answer, so accept one directly.
    local byGuid = ((AltStableConfig or {}).forgottenCharacters or {})[name]
    if type(byGuid) == "table" then return name, byGuid.name end

    if #full == 1 then return full[1].guid, full[1].name end
    if #full > 1 then return ambiguous(full) end
    if #partial == 1 then return partial[1].guid, partial[1].name end
    if #partial > 1 then return ambiguous(partial) end
    return nil, "|cffff8800Not on the forgotten list:|r " .. name
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

-- Roster camps (#152)
--
-- The Roster scene shows a CAMP: a named group of up to CAMP_SIZE characters
-- in order (order is who stands where), with its own backdrop. Modelled on
-- retail's warband camps. They replace favourites as the scene's cast;
-- favourites order the grid only.
--
--   AltStableConfig.rosterCamps = { { id = 1, name = "Camp 1", backdrop = <scene id>,
--                                      members = { guid, ... } }, ... }   -- in display order
--   AltStableConfig.rosterCamp  = <id of the camp the scene shows>
--
-- Local view preferences like favourites and hidden: per account, never synced.
-- Every write goes through SetCamps, a full copy (the config's copy-on-write
-- rule). A character is in at most ONE camp: adding it elsewhere moves it.
-- nil `rosterCamps` means "never set up"; the Roster seeds the first camp then.
------------------------------------------------------------

local CAMP_SIZE = 5
AltStable.CAMP_SIZE = CAMP_SIZE

function AltStable.GetCamps()
    local camps = AltStableConfig and AltStableConfig.rosterCamps
    return type(camps) == "table" and camps or {}
end

function AltStable.CampsSetUp()
    return type(AltStableConfig and AltStableConfig.rosterCamps) == "table"
end

-- A copy to change: EVERY field of each camp kept, members copied deep. A
-- field this build does not know (a later one's) survives its writes.
local function CopyCamps(camps)
    local out = {}
    for i, c in ipairs(camps) do
        local copy = {}
        for k, v in pairs(c) do copy[k] = v end
        local members = {}
        for j, g in ipairs(c.members or {}) do members[j] = g end
        copy.members = members
        out[i] = copy
    end
    return out
end

-- Store `camps` (already a copy - every mutator below makes one). A change to
-- who is in which camp is the PLAYER's choice and ends the first camp's
-- topping-up (see SeedCamp); `keepAuto` marks the changes that are not about
-- members - a name, a backdrop, pruning a record that is gone (#170 review: a
-- no-change Apply in the backdrop picker had ended it).
local function SetCamps(camps, keepAuto)
    AltStable.SetConfigValue("rosterCamps", camps)
    if not keepAuto and AltStableConfig.rosterCampsAuto then
        AltStable.SetConfigValue("rosterCampsAuto", nil)
    end
end

-- A new camp id: from a counter that only goes up, so an id is never reused -
-- a menu or a drag still holding a deleted camp's id must not land in a
-- newer camp that happened to get the same number.
local function NextCampId(camps)
    local n = tonumber(AltStableConfig and AltStableConfig.rosterCampNextId) or 0
    for _, c in ipairs(camps) do
        if (tonumber(c.id) or 0) > n then n = c.id end
    end
    n = n + 1
    AltStable.SetConfigValue("rosterCampNextId", n)
    return n
end

local function FindCamp(camps, id)
    for i, c in ipairs(camps) do
        if c.id == id then return c, i end
    end
end

function AltStable.GetCamp(id)
    return (FindCamp(AltStable.GetCamps(), id))
end

-- The camp the scene shows: the chosen one, else the first.
function AltStable.SelectedCamp()
    local camps = AltStable.GetCamps()
    local want = AltStableConfig and AltStableConfig.rosterCamp
    return (want and FindCamp(camps, want)) or camps[1]
end

function AltStable.SelectCamp(id)
    if not AltStable.GetCamp(id) then return false end
    AltStable.SetConfigValue("rosterCamp", id)
    return true
end

-- The camp a character is in, and its place there.
function AltStable.CampOf(guid)
    if not guid then return nil end
    for _, c in ipairs(AltStable.GetCamps()) do
        for j, g in ipairs(c.members or {}) do
            if g == guid then return c, j end
        end
    end
end

-- A new camp, last in the list. Returns its id. `members` beyond CAMP_SIZE are
-- dropped, and anyone in another camp leaves it.
function AltStable.CreateCamp(name, members, backdrop)
    local camps = CopyCamps(AltStable.GetCamps())
    local nextId = NextCampId(camps)
    local keep, taken = {}, {}
    for _, g in ipairs(members or {}) do
        if #keep < CAMP_SIZE and not taken[g] then keep[#keep + 1] = g; taken[g] = true end
    end
    for _, c in ipairs(camps) do
        for j = #c.members, 1, -1 do
            if taken[c.members[j]] then table.remove(c.members, j) end
        end
    end
    if not name or name == "" then name = "Camp " .. nextId end
    camps[#camps + 1] = { id = nextId, name = name, backdrop = backdrop, members = keep }
    SetCamps(camps)
    return nextId
end

function AltStable.RenameCamp(id, name)
    if not name or name == "" then return false end
    local camps = CopyCamps(AltStable.GetCamps())
    local c = FindCamp(camps, id)
    if not c then return false end
    c.name = name
    SetCamps(camps, true)     -- a name is not who is in it: the top-ups go on
    return true
end

-- Deleting the shown camp shows its neighbour. The last camp can go too: the
-- list is then empty, not "never set up", so it is not seeded again.
function AltStable.DeleteCamp(id)
    local camps = CopyCamps(AltStable.GetCamps())
    local _, i = FindCamp(camps, id)
    if not i then return false end
    local shown = AltStable.SelectedCamp()
    table.remove(camps, i)
    SetCamps(camps)
    if shown and shown.id == id then
        local neighbour = camps[i] or camps[i - 1]
        AltStable.SetConfigValue("rosterCamp", neighbour and neighbour.id or nil)
    end
    return true
end

-- Into camp `id`, at `pos` (default: the end). Out of any other camp first. A
-- full camp refuses (false, "full"); a move WITHIN a camp is a reorder.
function AltStable.AddToCamp(guid, id, pos)
    if not guid then return false end
    local camps = CopyCamps(AltStable.GetCamps())
    local target = FindCamp(camps, id)
    if not target then return false end
    local from, at
    for _, c in ipairs(camps) do
        for j, g in ipairs(c.members) do
            if g == guid then from, at = c, j end
        end
    end
    if from ~= target and #target.members >= CAMP_SIZE then return false, "full" end
    if from then table.remove(from.members, at) end
    pos = math.max(1, math.min(tonumber(pos) or (#target.members + 1), #target.members + 1))
    table.insert(target.members, pos, guid)
    SetCamps(camps)
    return true
end

function AltStable.RemoveFromCamp(guid)
    if not guid then return false end
    local camps, found = CopyCamps(AltStable.GetCamps()), false
    for _, c in ipairs(camps) do
        for j = #c.members, 1, -1 do
            if c.members[j] == guid then table.remove(c.members, j); found = true end
        end
    end
    if found then SetCamps(camps) end
    return found
end

-- The first camp, made for the player (#152): the top characters. Marked as
-- made for them, and topped up as more characters arrive (RefreshSeededCamp)
-- until the player changes any camp. A fresh install knows only the character
-- logged in; without this, that one would have stood alone for good.
function AltStable.SeedCamp(members, backdrop)
    local id = AltStable.CreateCamp("Camp 1", members, backdrop)
    AltStable.SetConfigValue("rosterCampsAuto", true)
    AltStable.SelectCamp(id)
    return id
end

function AltStable.CampsAutoSeeded()
    return AltStableConfig and AltStableConfig.rosterCampsAuto == true or false
end

-- The made-for-you camp's members, while it still is one. Writes only on a
-- change, since this runs on every refresh.
function AltStable.RefreshSeededCamp(members)
    if not AltStable.CampsAutoSeeded() then return false end
    local camps = CopyCamps(AltStable.GetCamps())
    local c = camps[1]
    if not c then return false end
    local want = {}
    for i = 1, math.min(#(members or {}), CAMP_SIZE) do want[i] = members[i] end
    if table.concat(want, ",") == table.concat(c.members, ",") then return false end
    c.members = want
    SetCamps(camps, true)
    return true
end

-- Seats whose character no longer has a record (`/alts cleanup` deletes them
-- without asking the camps) are freed: otherwise the camp counts them as full
-- while the scene shows no one. `store` is AltStableDB. Not the player's
-- change, so a made-for-you camp stays one.
function AltStable.PruneCamps(store)
    if type(store) ~= "table" then return false end
    local camps, changed = CopyCamps(AltStable.GetCamps()), false
    for _, c in ipairs(camps) do
        for j = #c.members, 1, -1 do
            if type(store[c.members[j]]) ~= "table" then table.remove(c.members, j); changed = true end
        end
    end
    if changed then SetCamps(camps, true) end
    return changed
end

-- A camp moved to place `pos` in the list.
function AltStable.MoveCamp(id, pos)
    local camps = CopyCamps(AltStable.GetCamps())
    local c, i = FindCamp(camps, id)
    if not c then return false end
    table.remove(camps, i)
    pos = math.max(1, math.min(tonumber(pos) or 1, #camps + 1))
    table.insert(camps, pos, c)
    SetCamps(camps)
    return true
end

-- Every camp's backdrop at once (the picker's "Apply for all camps"): one write.
function AltStable.SetAllCampsBackdrop(backdrop)
    local camps = CopyCamps(AltStable.GetCamps())
    if #camps == 0 then return false end
    for _, c in ipairs(camps) do c.backdrop = backdrop end
    SetCamps(camps, true)     -- nor is a backdrop
    return true
end

function AltStable.SetCampBackdrop(id, backdrop)
    local camps = CopyCamps(AltStable.GetCamps())
    local c = FindCamp(camps, id)
    if not c then return false end
    c.backdrop = backdrop
    SetCamps(camps, true)     -- nor is a backdrop
    return true
end

-- Favourite characters (#66)
--
-- Deliberately the same shape as hidden below, down to the copy-on-write and
-- the "absent means no" rule: they are the same kind of thing - a per-account
-- view preference keyed by GUID, never synced - and a second, subtly different
-- mechanism for the same job is how the two end up disagreeing.
--
-- Three per-character states now, and they have to stay distinct or none of
-- them means anything:
--
--   favourite   show me first          (here)
--   hidden      do not show me at all  (#21)
--   forgotten   this does not exist    (#65 - removes the record entirely)
------------------------------------------------------------

function AltStable.IsCharacterFavourite(guid)
    if not guid then return false end
    local fav = AltStableConfig and AltStableConfig.favouriteCharacters
    return (fav and fav[guid]) and true or false
end

function AltStable.SetCharacterFavourite(guid, favourite)
    if not guid then return end
    AltStableConfig = AltStableConfig or {}
    local current = AltStableConfig.favouriteCharacters or {}
    local copy = {}
    for k, v in pairs(current) do copy[k] = v end
    copy[guid] = favourite and true or nil    -- nil, not false: absent means no
    AltStable.SetConfigValue("favouriteCharacters", copy)
end

function AltStable.ToggleCharacterFavourite(guid)
    if not guid then return false end
    local now = not AltStable.IsCharacterFavourite(guid)
    AltStable.SetCharacterFavourite(guid, now)
    return now
end

-- Favourites first, then whatever order the caller already wanted.
--
-- Returned as a comparator rather than applied, so every view sorts the same
-- way and a test can assert the ORDER rather than a rendered list. `within` is
-- the existing rule - level desc then name, in both views today.
function AltStable.FavouriteFirst(within)
    return function(a, b)
        local fa = AltStable.IsCharacterFavourite(a and a.guid)
        local fb = AltStable.IsCharacterFavourite(b and b.guid)
        if fa ~= fb then return fa end
        return within(a, b)
    end
end
-- Whether the SHEET is currently listing hidden characters (dimmed).
--
-- A separate question from IsCharacterHidden, and they must not be conflated:
-- this changes what the grid LISTS, never whether a character is hidden. The
-- totals still leave hidden characters out and the "(N hidden)" count still
-- counts them, on or off.
function AltStable.IsShowingHidden()
    return (AltStableConfig and AltStableConfig.sheetShowHidden) and true or false
end

function AltStable.SetShowingHidden(show)
    AltStableConfig = AltStableConfig or {}
    AltStable.SetConfigValue("sheetShowHidden", show and true or false)
end

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
-- (Tools/AltStableProbe/Probe.lua, and docs/RUNBOOK.md).
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

local MEASURED_ON_BUILD = "70205"
AltStable.MEASURED_ON_BUILD = MEASURED_ON_BUILD

-- A development copy, not a release: deploy.ps1 stamps "dev-<sha>" (or "dev"),
-- a checkout run as-is still carries the packager's version keyword, and an
-- unreadable version is treated as dev. A packaged release carries its tag
-- ("v0.7.0-beta"). What the build check below is for is a chore for whoever
-- measures the client - a player can do nothing with it.
--
-- The keyword is ASSEMBLED, never written out: the packager replaces it in
-- every file it ships, not only the .toc. Written literally, v0.7.0-beta
-- shipped `v == "v0.7.0-beta"` here - the release counted itself as a dev copy
-- (tests/test_packaging.lua now fails on a literal keyword in shipped Lua).
local VERSION_KEYWORD = "@" .. "project-version" .. "@"

function AltStable.IsDevBuild()
    local get = AltStable.API and AltStable.API.GetAddOnMetadata
    local ok, v = pcall(function() return get and get("AltStable", "Version") end)
    if not ok or type(v) ~= "string" or v == "" then return true end
    return v == "dev" or v:sub(1, 4) == "dev-" or v == VERSION_KEYWORD
end

local function CheckClientBuild()
    -- Development copies only: on a release, every player on a newer build
    -- was told to run /apidump and bump a constant in the source.
    if not AltStable.IsDevBuild() then return end
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
