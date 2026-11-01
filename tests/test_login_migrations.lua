------------------------------------------------------------
-- test_login_migrations.lua - what a login rewrites in the SavedVariables
-- (docs/AUDIT.md sections 1b-1c, #279)
--
-- An old-shape profile (the v0.12-era keys, a record with retired fields, a
-- Warband store with an orphan) goes through the REAL login: every frame's
-- PLAYER_LOGIN in TOC order, PLAYER_ENTERING_WORLD, every timer. The rule:
-- a login may ADD keys (defaults) but may change or remove only what is
-- declared below. Anything else that changed is a finding.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
dofile("tests/libaccountsync.lua"); LoadAccountSync("AltStable")
dofile("Libs/LibStub/LibStub.lua")
dofile("Libs/LibDeflate/LibDeflate.lua")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. name .. (detail and ("  -- " .. tostring(detail)) or "")) end
end
local function eq(name, got, want)
    check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

-- Every frame, in creation order, so PLAYER_LOGIN fires the way the client does.
local frames = {}
local rawCreateFrame = CreateFrame
CreateFrame = function(...)
    local f = rawCreateFrame(...)
    frames[#frames + 1] = f
    return f
end

AltStable, AltStableDB, AltStableConfig = {}, {}, {}
dofile("Compat.lua")
dofile("tests/libglass.lua"); LoadGlass("AltStable")
dofile("tests/libshowcase.lua"); LoadShowcase("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")
dofile("Prompt.lua")
assert(loadfile("Core.lua"))()
dofile("Scanner.lua")
dofile("Reputations.lua")
dofile("Config.lua")
dofile("Toasts.lua")
dofile("Columns.lua")
dofile("RowRenderer.lua")
dofile("CharacterMenu.lua")
dofile("SheetUI.lua")
dofile("PublicAPI.lua")
dofile("Plugins/Warband/WarbandTabs.lua")
dofile("Plugins/Warband/AltStableWarband.lua")

------------------------------------------------------------
-- The profile on disk: v0.12-era keys, a record with retired fields
------------------------------------------------------------
local OLD = "Player-1-0000OLD1"
local ORPHAN = "Player-1-0000GONE"
local tombstones = {}
for i = 1, 201 do tombstones["Player-1-" .. string.format("%07X", i)] = { at = i, forgottenAt = i, name = "Gone " .. i } end

AltStableConfig = {
    syncMode = "whisper", whitelist = { "Friend Person" }, accountNumber = 1,
    theme = "dark", scale = 1.2, hiddenCharacters = { ["Player-1-0000HID1"] = true },
    peerWatermarks = { ["Friend Person"] = 1700000000 + 999999 },   -- ahead of the clock: capped on read, never rewritten
    -- retired with the legacy Battle.net channel (#206) and the BiS column (#8)
    bnetKey = "abc", bnetTrusted = { x = true }, bnetSelfProject = 18, bnetSelfRegion = 90,
    bisTier = "T2", minGemQuality = 3,
    toastProfessions = { Tailoring = true, Jewelcrafting = true },
    -- realm-suffixed and differently-cased sync answers (#61)
    syncAuth = { ["Bob-OtherRealm"] = "auto", ["bob"] = "never", ["Carol Surname-Realm"] = "auto" },
    -- a pre-v10 camera profile
    worldCameraEnterDuration = 0.60, worldCameraZoomPreset = 9,
    -- the library's store from a session with Battle.net sync off, now on
    bnetSync = true, accountSync = { enabled = false, trusted = {}, v = 1 },
    forgottenCharacters = tombstones,
}
AltStableDB = {
    [OLD] = { guid = OLD, name = "Old One", class = "MAGE", level = 60, lastUpdate = 100,
              prof_Tailoring = 300, profmax_Tailoring = 300, gear_head = 50, money = 123, rep_76 = 4,
              -- retired fields (RETIRED_FIELDS in Core.lua)
              prof_Jewelcrafting = 300, profmax_Jewelcrafting = 375, stat_haste = 1, stat_resilience = 2,
              spec = "Arcane", specIcon = 1, refshot_ts = 5, aldor = 3 },
}
AltStableWarbandDB = {
    [OLD]    = { bags = { [2318] = 8 }, bank = { [2589] = 2 }, stamp = 100, bagsStamp = 100, bankStamp = 90 },
    [ORPHAN] = { bags = { [159] = 1 }, stamp = 50, bagsStamp = 50 },
}

local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[deepcopy(k)] = deepcopy(x) end
    return out
end
local before = { cfg = deepcopy(AltStableConfig), db = deepcopy(AltStableDB), wb = deepcopy(AltStableWarbandDB) }

------------------------------------------------------------
-- The login
------------------------------------------------------------
local errors = {}
local function fire(ev, ...)
    for _, f in ipairs(frames) do
        if f["_ev_" .. ev] and f._script_OnEvent then
            local ok, err = pcall(f._script_OnEvent, f, ev, ...)
            if not ok then errors[#errors + 1] = ev .. ": " .. tostring(err) end
        end
    end
end
fire("PLAYER_LOGIN")
fire("PLAYER_ENTERING_WORLD", true, false)
for _ = 1, 30 do
    if #WoW.timers == 0 then break end
    local ok, err = pcall(WoW.flushTimers)
    if not ok then errors[#errors + 1] = "timer: " .. tostring(err) end
end
eq("the whole login runs under the stubs without an error", #errors, 0)
for _, e in ipairs(errors) do print("    " .. e) end

------------------------------------------------------------
-- What changed, against what is declared
------------------------------------------------------------
-- Keys a login may change or remove, by path. A path not here that changed
-- or vanished is a finding.
local declared = {
    -- EnsureDefaults' unconditional deletes (Config.lua)
    ["cfg.bnetKey"] = true, ["cfg.bnetTrusted"] = true, ["cfg.bnetSelfProject"] = true, ["cfg.bnetSelfRegion"] = true,
    ["cfg.bisTier"] = true, ["cfg.minGemQuality"] = true, ["cfg.toastProfessions.Jewelcrafting"] = true,
    -- the one-shot v10 camera block
    ["cfg.worldCameraEnterDuration"] = true, ["cfg.worldCameraZoomPreset"] = true,
    -- MigrateSyncAuthKeys (Core.lua): keys folded to the bare lower-case name
    ["cfg.syncAuth"] = true, ["cfg.syncAuth.Bob-OtherRealm"] = true, ["cfg.syncAuth.Carol Surname-Realm"] = true,
    -- LibSync.Store: the addon's toggle owns the library's
    ["cfg.accountSync"] = true, ["cfg.accountSync.enabled"] = true,
    -- PruneForgotten: the newest 200 tombstones stay
    ["cfg.forgottenCharacters.Player-1-0000001"] = true,
    -- PurgeRetiredFields (Core.lua), every record
    ["db." .. OLD .. ".prof_Jewelcrafting"] = true, ["db." .. OLD .. ".profmax_Jewelcrafting"] = true,
    ["db." .. OLD .. ".stat_haste"] = true, ["db." .. OLD .. ".stat_resilience"] = true,
    ["db." .. OLD .. ".spec"] = true, ["db." .. OLD .. ".specIcon"] = true, ["db." .. OLD .. ".refshot_ts"] = true,
    ["db." .. OLD .. ".aldor"] = true,
}
local me = UnitGUID("player")       -- the scan writes this one from stub data
local undeclared = {}
local function walk(path, a, b)
    if type(a) == "table" and type(b) == "table" then
        for k, v in pairs(a) do
            if k ~= me then walk(path .. "." .. tostring(k), v, b[k]) end
        end
    elseif a ~= b and not declared[path] then
        undeclared[#undeclared + 1] = path .. ": " .. tostring(a) .. " -> " .. tostring(b)
    end
end
-- Only what WAS there: added defaults are fine, changed or removed keys are not.
walk("cfg", before.cfg, AltStableConfig)
walk("db", before.db, AltStableDB)
walk("wb", before.wb, AltStableWarbandDB)
table.sort(undeclared)
check("a login changes or removes nothing it does not declare", #undeclared == 0, "\n    " .. table.concat(undeclared, "\n    "))

-- And the declared changes happened.
local cfg = AltStableConfig
check("the legacy Battle.net keys are gone", cfg.bnetKey == nil and cfg.bnetTrusted == nil and cfg.bnetSelfProject == nil and cfg.bnetSelfRegion == nil)
check("so are bisTier and minGemQuality", cfg.bisTier == nil and cfg.minGemQuality == nil)
eq("Jewelcrafting is not a toast profession", cfg.toastProfessions.Jewelcrafting, nil)
eq("  Tailoring still is", cfg.toastProfessions.Tailoring, true)
eq("the v10 camera block replaced the old enter duration", cfg.worldCameraEnterDuration, 1.50)
eq("  and the zoom preset", cfg.worldCameraZoomPreset, 2.2)
eq("  once: the version is stamped", cfg.worldCameraPresentationDefaultsVersion, 10)
eq("a realm-suffixed sync answer folds to the bare name, and never wins the clash", cfg.syncAuth["bob"], "never")
eq("  the realm form is gone", cfg.syncAuth["Bob-OtherRealm"], nil)
eq("  a two-word name folds to lower case", cfg.syncAuth["carol surname"], "auto")
eq("the library's store follows the addon's toggle", cfg.accountSync.enabled, true)
eq("  and keeps its trusted list", type(cfg.accountSync.trusted), "table")
local count = 0
for _ in pairs(cfg.forgottenCharacters) do count = count + 1 end
eq("the tombstones are capped at 200", count, 200)
eq("  the oldest went", cfg.forgottenCharacters["Player-1-0000001"], nil)
check("  the newest stayed", cfg.forgottenCharacters["Player-1-00000C9"] ~= nil)
eq("the account number is left as the number it was", cfg.accountNumber, 1)
eq("a watermark ahead of the clock is capped on read", AltStable._test.GetPeerWatermark("Friend Person"), WoW.now - 300)
eq("  not rewritten", cfg.peerWatermarks["Friend Person"], 1700000000 + 999999)
local old = AltStableDB[OLD]
check("retired fields are purged from a stored record", old.prof_Jewelcrafting == nil and old.stat_haste == nil and old.spec == nil and old.aldor == nil)
eq("  and nothing else on it moves", old.prof_Tailoring, 300)
eq("  not even its stamp", old.lastUpdate, 100)
check("the Warband store keeps the orphan (A4) and the record's inventory",
      AltStableWarbandDB[ORPHAN] ~= nil and AltStableWarbandDB[OLD] ~= nil and AltStableWarbandDB[OLD].bank[2589] == 2)
check("the scan wrote the current character, and only it, into the database",
      AltStableDB[me] ~= nil and AltStableDB[me].name == "Example Surname")

print(("test_login_migrations: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
