------------------------------------------------------------
-- test_publicapi.lua — the read-only API for other addons (#123)
--
-- Other addons (GlassPanel first) build on these functions and never on
-- AltStableDB's layout, so what is pinned here is the CONTRACT in
-- docs/PUBLIC-API.md: copies not live tables, which characters count, the
-- totals the sheet's own footer shows, and a change notification that fires
-- once per burst and survives a consumer's error.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. name .. (detail and ("  -- " .. detail) or "")) end
end
local function eq(name, got, want)
    check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

AltStable, AltStableDB, AltStableConfig = {}, {}, {}
dofile("Compat.lua")
assert(loadfile("Core.lua"))()
dofile("Config.lua")

-- The sheet, reduced to what the API touches. PublicAPI.lua wraps RefreshSheet
-- at load, as the plugins do after it, so it has to exist first.
local refreshes, opened, scans = 0, 0, 0
crashRefresh = false
AltStable.RefreshSheet = function()
    if crashRefresh then error("render bug") end             -- a sheet that breaks
    refreshes = refreshes + 1
end
-- The scanner, reduced: the login scan (Core, 2s after login) calls it and
-- never RefreshSheet, so the API has to hear about it on its own.
AltStable.ScanCharacter = function() scans = scans + 1; return "scanned" end
AltStable.EnsureSheetVisible = function()
    opened = opened + 1
    if _G.AltStableSheet then _G.AltStableSheet:Show() end
end
local toggles = 0
AltStable.ShowSheet = function()                                -- the sheet's own toggle
    toggles = toggles + 1
    local s = _G.AltStableSheet
    if s:IsShown() then s:Hide() else s:Show() end
end
dofile("PublicAPI.lua")

local ME = UnitGUID("player")
local function seed()
    AltStableDB = {
        [ME] = { guid = ME, name = "Example Surname", realm = "Classic Beta PvE", faction = "Horde",
                 class = "PRIEST", level = 60, money = 125000, account = 2, lastUpdate = 1700000000,
                 gearid_head = 1234 },                                   -- internal: must not leak
        ["Player-1-B"] = { guid = "Player-1-B", name = "Bank Alt", realm = "Classic Beta PvE",
                 faction = "Horde", class = "MAGE", level = 1, money = 5000000, account = 2,
                 lastUpdate = 1699990000 },
        ["Player-1-C"] = { guid = "Player-1-C", name = "Hidden Hero", realm = "Another Realm",
                 faction = "Alliance", class = "WARRIOR", level = 40, money = 900, account = 1,
                 lastUpdate = 1699980000 },
        ["Player-1-D"] = { guid = "Player-1-D", name = "Secretive", realm = "Another Realm",
                 faction = "Alliance", class = "ROGUE", level = 20, account = 1,
                 lastUpdate = 1699970000 },                              -- money unreadable: absent
        ["Player-1-E"] = { guid = "Player-1-E", name = "Gone Guy", realm = "Another Realm",
                 class = "HUNTER", level = 10, money = 777 },
        notACharacter = true,                                           -- stray key: ignored
    }
    AltStableConfig = {
        hiddenCharacters = { ["Player-1-C"] = true },
        forgottenCharacters = { ["Player-1-E"] = { stamp = 1 } },
    }
end

------------------------------------------------------------
-- The version, and the name it is NOT under
------------------------------------------------------------
eq("the API says its version", AltStable.PUBLIC_API_VERSION, 1)
check("  and the Retail adapter keeps its own name",
      type(AltStable.API) == "table" and AltStable.API.PlainNumber ~= nil)

------------------------------------------------------------
-- GetCharacters: copies, of a fixed set of fields
------------------------------------------------------------
seed()
local chars = AltStable.GetCharacters()
eq("every character with a record, as the grid lists them", #chars, 5)
local by = {}
for _, c in ipairs(chars) do by[c.name] = c end
-- A forgotten character normally has no record. One that has a record AGAIN
-- (logged into after forgetting it) is on the sheet, so it is here too: a list
-- that disagreed with the sheet was the bug the review of #126 found.
check("  a forgotten character that has a record again is there, as on the sheet",
      by["Gone Guy"] ~= nil)

local me = by["Example Surname"]
eq("fields come across: realm", me.realm, "Classic Beta PvE")
eq("  faction", me.faction, "Horde")
eq("  class token", me.class, "PRIEST")
eq("  level", me.level, 60)
eq("  money in copper", me.money, 125000)
eq("  account, always as a string", me.account, "2")
eq("  lastUpdate", me.lastUpdate, 1700000000)
eq("  guid", me.guid, ME)
eq("internal fields do not", me.gearid_head, nil)
eq("the logged-in character is marked current", me.current, true)
eq("  and nobody else is", by["Bank Alt"].current, false)

eq("a hidden character is included", by["Hidden Hero"] ~= nil, true)
eq("  and flagged", by["Hidden Hero"].hidden, true)
eq("  while the others are not", me.hidden, false)
eq("unreadable money is nil, not 0", by["Secretive"].money, nil)
AltStableDB["Player-1-B"].money = 0
AltStableDB["Player-1-B"].account = nil
for _, c in ipairs(AltStable.GetCharacters()) do
    if c.name == "Bank Alt" then
        eq("zero money stays 0, not unknown", c.money, 0)
        eq("a record with no account reads as empty, not nil", c.account, "")
    end
end
seed()

-- Sorted by realm, then name.
eq("sorted: first by realm", chars[1].realm, "Another Realm")
eq("  then by name", chars[1].name, "Gone Guy")

-- COPIES: a consumer writing to what it was given changes nothing here.
me.money = 1
me.name = "Vandal"
eq("changing a returned table does not touch the database", AltStableDB[ME].money, 125000)
eq("  nor its name", AltStableDB[ME].name, "Example Surname")
check("  and each call hands out fresh tables", AltStable.GetCharacters()[1] ~= chars[1])

-- A secret value never reaches a consumer: every later compare on it would throw.
AltStableDB["Player-1-B"].money = WoW.secret(42)
local fromSecret
for _, c in ipairs(AltStable.GetCharacters()) do
    if c.name == "Bank Alt" then fromSecret = c end
end
eq("a secret money value arrives as unknown", fromSecret.money, nil)

------------------------------------------------------------
-- GetTotals: the numbers the sheet's footer shows
------------------------------------------------------------
seed()
local t = AltStable.GetTotals()
eq("characters that count: every one the grid lists, less the hidden", t.characters, 4)
eq("hidden ones are counted as hidden", t.hidden, 1)
eq("money sums the known amounts, bank alt included", t.money, 125000 + 5000000 + 777)
eq("unreadable money is counted as unknown, not as 0", t.unknown, 1)
eq("levels sum the ones that count", t.levels, 60 + 1 + 20 + 10)
check("they are the sheet's own numbers", (function()
    local s = AltStable.CharacterTotals()
    for k, v in pairs(t) do if s[k] ~= v then return false end end
    return true
end)())
t.money = 1
eq("a consumer changing them changes nothing", AltStable.GetTotals().money, 125000 + 5000000 + 777)
-- Wrapping the PUBLIC function must not change AltStable's own numbers.
local realGetTotals = AltStable.GetTotals
AltStable.GetTotals = function() return { money = 0, unknown = 0, characters = 0, hidden = 0, levels = 0 } end
eq("the sheet's totals do not go through the public, wrappable function",
   AltStable.CharacterTotals().characters, 4)
AltStable.GetTotals = realGetTotals

------------------------------------------------------------
-- Opening and toggling the sheet
------------------------------------------------------------
local sheet = CreateFrame("Frame", "AltStableSheet", UIParent)
sheet:Hide()
AltStable.ToggleSheet()
check("toggle opens a closed sheet", sheet:IsShown())
eq("  through the sheet's own toggle, not a copy of it", toggles, 1)
AltStable.ToggleSheet()
check("and closes an open one", not sheet:IsShown())
AltStable.OpenSheet()
AltStable.OpenSheet()
check("open only ever opens", sheet:IsShown())
eq("  through the normal open path", opened, 2)

------------------------------------------------------------
-- CharactersChanged: once per burst, and a consumer's error stays its own
------------------------------------------------------------
WoW.timers = {}
AltStable.RefreshSheet(); AltStable.TouchCharacter(ME)
eq("with nobody listening, a change schedules nothing", #WoW.timers, 0)

local heard = 0
local function listener() heard = heard + 1 end
AltStable.RegisterCallback("CharactersChanged", listener)

local before = refreshes
AltStable.RefreshSheet(); AltStable.RefreshSheet(); AltStable.RefreshSheet()
eq("the sheet itself still refreshes every time", refreshes - before, 3)
eq("  but nothing is told until the next frame", heard, 0)
WoW.flushTimers()
eq("a burst of refreshes is ONE notification", heard, 1)

-- The callback is called with its event name.
local got
local function namer(e) got = e end
AltStable.RegisterCallback("CharactersChanged", namer)
AltStable.RefreshSheet()
WoW.flushTimers()
eq("the callback gets the event name", got, "CharactersChanged")
AltStable.UnregisterCallback("CharactersChanged", namer)
heard = 1

-- The two changes that never reach RefreshSheet.
eq("the login scan still returns what the scanner returns", AltStable.ScanCharacter(), "scanned")
WoW.flushTimers()
eq("  and notifies", heard, 2)
AltStableDB[ME] = AltStableDB[ME] or { guid = ME, name = "Me" }
AltStable.TouchCharacter(ME)
WoW.flushTimers()
eq("a plugin touching a record (Warband) notifies too", heard, 3)
heard = 1
AltStable.RefreshSheet()
WoW.flushTimers()
eq("  and the next change is another", heard, 2)

-- A consumer that errors must not stop the others, or AltStable.
local caught = {}
local realHandler = geterrorhandler
geterrorhandler = function() return function(e) caught[#caught + 1] = e end end
local function broken() error("consumer bug") end
AltStable.RegisterCallback("CharactersChanged", broken)
AltStable.RefreshSheet()
local ok = pcall(WoW.flushTimers)
check("a consumer's error does not escape into AltStable", ok)
eq("  the other consumer still heard", heard, 3)
eq("  and the error was reported, not swallowed", #caught, 1)
geterrorhandler = realHandler

AltStable.UnregisterCallback("CharactersChanged", broken)
AltStable.UnregisterCallback("CharactersChanged", listener)
AltStable.RefreshSheet()
WoW.flushTimers()
eq("unregistered consumers hear nothing", heard, 3)

-- A listener that refreshes the sheet from inside its callback - to keep it in
-- step with what it was just told - is not a new change. Notifying it again
-- called it again, which refreshed again: every frame, for ever.
local syncs = 0
local function syncer()
    syncs = syncs + 1
    AltStable.RefreshSheet()
end
AltStable.RegisterCallback("CharactersChanged", syncer)
AltStable.RefreshSheet()
WoW.flushTimers()
WoW.flushTimers()
WoW.flushTimers()
eq("a refresh made from inside a callback does not notify again", syncs, 1)
eq("  and leaves nothing scheduled", #WoW.timers, 0)
AltStable.UnregisterCallback("CharactersChanged", syncer)

-- The notification is queued BEFORE the wrapped function runs: a render error
-- in the sheet, after the data already changed, must not swallow it.
AltStable.RegisterCallback("CharactersChanged", listener)
local beforeCrash = heard
crashRefresh = true
check("a refresh that errors still errors for its caller", not pcall(AltStable.RefreshSheet))
crashRefresh = false
WoW.flushTimers()
eq("  but consumers still hear about the change", heard, beforeCrash + 1)
AltStable.UnregisterCallback("CharactersChanged", listener)

-- A listener that registers another from inside its callback: the new one is
-- heard from the NEXT change, and this pass completes cleanly.
local late = 0
local function lateListener() late = late + 1 end
local function recruiter()
    AltStable.RegisterCallback("CharactersChanged", lateListener)
    AltStable.UnregisterCallback("CharactersChanged", recruiter)
end
AltStable.RegisterCallback("CharactersChanged", recruiter)
AltStable.RefreshSheet()
check("registering from inside a callback does not break the pass", pcall(WoW.flushTimers))
eq("  the newcomer is not called in the pass it joined", late, 0)
AltStable.RefreshSheet()
WoW.flushTimers()
eq("  and is from the next change on", late, 1)
AltStable.UnregisterCallback("CharactersChanged", lateListener)

check("an unknown event is refused",
      not pcall(AltStable.RegisterCallback, "SomethingElse", listener))
check("  and so is something that is not a function",
      not pcall(AltStable.RegisterCallback, "CharactersChanged", "nope"))

------------------------------------------------------------
-- A plugin wrapping RefreshSheet after us still notifies
------------------------------------------------------------
-- The plugins load later and replace RefreshSheet with a wrapper of their own;
-- the notification has to survive being wrapped.
local inner = AltStable.RefreshSheet
AltStable.RefreshSheet = function(...) return inner(...) end
AltStable.RegisterCallback("CharactersChanged", listener)
local beforeWrap = heard
AltStable.RefreshSheet()
WoW.flushTimers()
eq("a refresh through a plugin's wrapper still notifies", heard, beforeWrap + 1)

print(("test_publicapi: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
