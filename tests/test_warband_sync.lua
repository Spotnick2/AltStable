------------------------------------------------------------
-- test_warband_sync.lua - the Warband plugin through the core's receive path
-- (docs/AUDIT.md section 4, #279)
--
-- test_warband drives DeserializePlayer directly and test_comm dispatches to a
-- demo plugin; nothing drove the REAL plugin through DeserializeFullDB. These
-- rows do. Two "sides" are the three SavedVariables globals, swapped in one
-- Lua state, and a payload arrives at LibSync.Apply, where both transports
-- land: this tests the merge and the dispatch, not admission, transport or
-- login (test_comm.lua and test_accountsync.lua own those). Each row states
-- its expected differences by hand, and passes only when the differences are
-- exactly the ones it lists.
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

AltStable, AltStableDB, AltStableConfig = {}, {}, {}
dofile("Compat.lua")
dofile("tests/libglass.lua"); LoadGlass("AltStable")
dofile("Theme.lua")
dofile("Skin.lua")
dofile("Prompt.lua")
assert(loadfile("Core.lua"))()
dofile("Scanner.lua")
dofile("Reputations.lua")
dofile("Config.lua")
dofile("Plugins/Warband/WarbandTabs.lua")
dofile("Plugins/Warband/AltStableWarband.lua")
WoW.flushTimers()   -- BootstrapPlugin registers the plugin with the core

local T  = AltStable._test
local L  = T.LibSync
local LD = LibStub("LibDeflate")
local plugin
for _, p in ipairs(AltStable.plugins or {}) do if p.id == "warband" then plugin = p end end
check("the real Warband plugin is registered with the core", plugin ~= nil)
if not plugin then
    print(("test_warband_sync: %d passed, %d failed"):format(passed, failed))
    os.exit(1)
end
local P = plugin._test
T.ResetSyncState()

------------------------------------------------------------
-- Two sides in one state
------------------------------------------------------------
-- A side is its three SavedVariables tables. Side A's own character is the
-- stub's player (the scans write that guid); B holds copies of A's.
local X = UnitGUID("player")
local Y = "Player-1-0000Y001"
local function side(name, guid)
    return { name = name, guid = guid, db = {}, wb = {},
             cfg = { peerWatermarks = {}, syncMode = "whisper", whitelist = {}, syncAuth = {},
                     accountNumber = "", bnetSync = true } }
end
local function use(s) AltStableDB, AltStableConfig, AltStableWarbandDB = s.db, s.cfg, s.wb end
-- What A would send: the (delta) database with the sender's clock, as
-- SendFullDatabase assembles it, plus any settings lines.
local function payloadFrom(s, sinceTS, extra)
    use(s)
    local p = T.SerializeFullDB(false, sinceTS or 0)
    for _, line in ipairs(extra or {}) do p = p .. "\n" .. line end
    return p .. "\n==NOW==:" .. time()
end
local function receive(s, from, payload)
    use(s)
    L.Apply(from.name, payload)
end
local function slot(id, n) return { itemID = id, stackCount = n, hyperlink = "|Hitem:" .. id .. "|h" } end
-- Side s's own bags hold n of item id, and the plugin scans them.
local function bags(s, id, n)
    use(s)
    WoW.containers = { [0] = { size = 1, slot(id, n) } }
    P.ScanBags()
end

-- Every observable, flat: the Warband maps and stamps, and the core fields a
-- Warband change rides with.
local CORE_FIELDS = { "name", "class", "lastUpdate", "gear_head" }
local function snap(s)
    local out = {}
    for guid, c in pairs(s.db) do
        for _, k in ipairs(CORE_FIELDS) do out["db." .. guid .. "." .. k] = c[k] end
    end
    for guid, w in pairs(s.wb) do
        for _, k in ipairs({ "stamp", "bagsStamp", "bankStamp" }) do out["wb." .. guid .. "." .. k] = w[k] end
        -- An empty map and an absent one are different states (the plugin
        -- header): both are marked, so a row can tell them apart.
        for _, m in ipairs({ "bags", "bank" }) do
            if w[m] == nil then out["wb." .. guid .. "." .. m] = "absent"
            elseif next(w[m]) == nil then out["wb." .. guid .. "." .. m] = "empty"
            else for id, n in pairs(w[m]) do out["wb." .. guid .. "." .. m .. "[" .. id .. "]"] = n end end
        end
    end
    return out
end
local function diff(a, b)
    local keys, out = {}, {}
    for k in pairs(a) do keys[k] = true end
    for k in pairs(b) do keys[k] = true end
    for k in pairs(keys) do
        if a[k] ~= b[k] then out[#out + 1] = k .. ": " .. tostring(a[k]) .. " -> " .. tostring(b[k]) end
    end
    table.sort(out)
    return table.concat(out, "\n")
end
local function expectDiffs(name, before, after, want)
    table.sort(want)
    local got, wanted = diff(before, after), table.concat(want, "\n")
    check(name, got == wanted,
          "\n    got:\n    " .. (got:gsub("\n", "\n    ")) .. "\n    want:\n    " .. (wanted:gsub("\n", "\n    ")))
end
local function x(k) return "db." .. X .. "." .. k end
local function wx(k) return "wb." .. X .. "." .. k end
local function y(k) return "db." .. Y .. "." .. k end
local function wy(k) return "wb." .. Y .. "." .. k end

------------------------------------------------------------
-- R1: a full pull A -> B
------------------------------------------------------------
WoW.now = 1700000000
local A, B = side("Able Surname", X), side("Baker Surname", "Player-1-0000B001")
A.db[X] = { guid = X, name = "Example Surname", class = "PRIEST", level = 60, lastUpdate = 1000, scannedHere = true }
A.db[Y] = { guid = Y, name = "Yarrow Surname", class = "MAGE", level = 40, lastUpdate = 900 }
A.wb[X] = { bags = { [2318] = 8 }, bank = { [2589] = 20 }, stamp = 1000, bagsStamp = 1000, bankStamp = 950 }
A.wb[Y] = { bags = { [159] = 2 }, stamp = 900, bagsStamp = 900 }   -- bank never read: kt=0 on the wire

local before = snap(B)
receive(B, A, payloadFrom(A))
expectDiffs("R1: a full pull brings both records and both inventories, and nothing else", before, snap(B), {
    x("name") .. ": nil -> Example Surname", x("class") .. ": nil -> PRIEST", x("lastUpdate") .. ": nil -> 1000",
    y("name") .. ": nil -> Yarrow Surname", y("class") .. ": nil -> MAGE", y("lastUpdate") .. ": nil -> 900",
    wx("bags[2318]") .. ": nil -> 8", wx("bank[2589]") .. ": nil -> 20",
    wx("stamp") .. ": nil -> 1000", wx("bagsStamp") .. ": nil -> 1000", wx("bankStamp") .. ": nil -> 950",
    wy("bags[159]") .. ": nil -> 2", wy("bank") .. ": nil -> empty",
    wy("stamp") .. ": nil -> 900", wy("bagsStamp") .. ": nil -> 900", wy("bankStamp") .. ": nil -> 0",
})
eq("  the watermark for A is the newest stamp seen", T.GetPeerWatermark(A.name), 1000)

------------------------------------------------------------
-- R2: a bag change on A rides the next delta; B's bank snapshot is untouched
------------------------------------------------------------
WoW.now = WoW.now + 10
bags(A, 2318, 9)
eq("R2: the bag scan moves the core record, which is what a delta carries", A.db[X].lastUpdate, WoW.now)
use(B)
local delta = payloadFrom(A, T.GetPeerWatermark(A.name))
check("  the delta leaves out the character that did not change", not delta:find(Y, 1, true))
before = snap(B)
receive(B, A, delta)
expectDiffs("  B takes the bags and the stamps, and nothing else: the bank snapshot stays", before, snap(B), {
    wx("bags[2318]") .. ": 8 -> 9", wx("stamp") .. ": 1000 -> " .. WoW.now, wx("bagsStamp") .. ": 1000 -> " .. WoW.now,
    x("lastUpdate") .. ": 1000 -> " .. WoW.now,
})

------------------------------------------------------------
-- R3: A's data is reset; its bank is unread (kt=0) until its next bank visit
------------------------------------------------------------
WoW.now = WoW.now + 10
A.wb = {}                       -- the owning account lost AltStableWarband.lua
bags(A, 2318, 10)               -- its login scans the bags; the bank stays unread
use(B); before = snap(B)
receive(B, A, payloadFrom(A, T.GetPeerWatermark(A.name)))
expectDiffs("R3: B keeps the bank snapshot the owner can no longer send (B1), and takes the bags", before, snap(B), {
    wx("bags[2318]") .. ": 9 -> 10", wx("stamp") .. ": " .. (WoW.now - 10) .. " -> " .. WoW.now,
    wx("bagsStamp") .. ": " .. (WoW.now - 10) .. " -> " .. WoW.now,
    x("lastUpdate") .. ": " .. (WoW.now - 10) .. " -> " .. WoW.now,
})
-- Then A visits an empty bank: that is knowledge, and B empties.
WoW.now = WoW.now + 10
use(A)
WoW.bankTabs = { 6 }; WoW.containers[6] = { size = 1 }
P.OnBankOpened(); P.OnBankClosed()
eq("  a bank read as empty carries its stamp", A.wb[X].bankStamp, WoW.now)
use(B); before = snap(B)
receive(B, A, payloadFrom(A, T.GetPeerWatermark(A.name)))
expectDiffs("  and B's snapshot goes with it", before, snap(B), {
    wx("bank[2589]") .. ": 20 -> nil", wx("bank") .. ": nil -> empty", wx("bankStamp") .. ": 950 -> " .. WoW.now,
    wx("stamp") .. ": " .. (WoW.now - 10) .. " -> " .. WoW.now, wx("bagsStamp") .. ": " .. (WoW.now - 10) .. " -> " .. WoW.now,
    x("lastUpdate") .. ": " .. (WoW.now - 10) .. " -> " .. WoW.now,
})

------------------------------------------------------------
-- R4: an older blob is refused, an equal one with other contents applies,
--     a truncated one is ignored whole
------------------------------------------------------------
local held = A.wb[X].stamp
A.wb[X] = { bags = { [2318] = 1 }, bank = {}, stamp = held - 100, bagsStamp = held - 100, bankStamp = held - 100 }
WoW.now = WoW.now + 10; A.db[X].lastUpdate = WoW.now    -- the core record is newer: the blob is dispatched
use(B); before = snap(B)
receive(B, A, payloadFrom(A, T.GetPeerWatermark(A.name)))
expectDiffs("R4: an older blob under a newer record changes no inventory (stale-reject)", before, snap(B), {
    x("lastUpdate") .. ": " .. (WoW.now - 10) .. " -> " .. WoW.now,
})
A.wb[X] = { bags = { [2318] = 11 }, bank = {}, stamp = held, bagsStamp = held, bankStamp = held }
WoW.now = WoW.now + 10; A.db[X].lastUpdate = WoW.now
use(B); before = snap(B)
receive(B, A, payloadFrom(A, T.GetPeerWatermark(A.name)))
expectDiffs("  an equal stamp with other contents applies (two moves in one second)", before, snap(B), {
    wx("bags[2318]") .. ": 10 -> 11", x("lastUpdate") .. ": " .. (WoW.now - 10) .. " -> " .. WoW.now,
})
WoW.now = WoW.now + 10
local truncated = table.concat({ "guid:" .. X, "name:Example Surname", "class:PRIEST", "level:60",
                                 "lastUpdate:" .. WoW.now, "plugin_warband:v1|s=" .. (held + 5),
                                 T.CHAR_SEP, "==NOW==:" .. WoW.now }, "\n")
use(B); before = snap(B)
receive(B, A, truncated)
expectDiffs("  a truncated blob (no b=/k=) is malformed, not empty: ignored whole", before, snap(B), {
    x("lastUpdate") .. ": " .. (WoW.now - 10) .. " -> " .. WoW.now,
})
A.db[X].lastUpdate = WoW.now    -- A as B now holds it

------------------------------------------------------------
-- R5: a rejected record, a forgotten character, a lift, and the settings
--     sync's forget line, all with the real plugin listening
------------------------------------------------------------
-- (a) the first name changed: rejected, its inventory with it; the watermark still moves
WoW.now = WoW.now + 10
A.db[X].name = "Zoruka Surname"; A.db[X].lastUpdate = WoW.now
A.wb[X] = { bags = { [2318] = 50 }, bank = {}, stamp = WoW.now, bagsStamp = WoW.now, bankStamp = held }
use(B); before = snap(B)
local wmBefore = T.GetPeerWatermark(A.name)
receive(B, A, payloadFrom(A, wmBefore))
expectDiffs("R5: a record whose first name changed is rejected, its inventory with it", before, snap(B), {})
check("  and the watermark still moves past it", T.GetPeerWatermark(A.name) > wmBefore)
-- A back as B holds it.
A.db[X].name = "Example Surname"; A.db[X].lastUpdate = B.db[X].lastUpdate
A.wb[X] = { bags = { [2318] = 11 }, bank = {}, stamp = held, bagsStamp = held, bankStamp = held }

-- (b) B forgets Y: the plugin's entry goes with the record (OnForget, the real one)
WoW.now = WoW.now + 10
use(B)
AltStable.ForgetCharacter(Y, WoW.now)
check("  a forgotten character's inventory goes with its record", B.db[Y] == nil and B.wb[Y] == nil)
before = snap(B)
receive(B, A, payloadFrom(A))            -- a full reply, as a cleanup would ask for
expectDiffs("  a stale copy of it from A is refused, inventory included", before, snap(B), {})
WoW.now = WoW.now + 10
A.db[Y].lastUpdate = WoW.now             -- played since the forget
A.wb[Y] = { bags = { [159] = 3 }, stamp = WoW.now, bagsStamp = WoW.now }
before = snap(B)
receive(B, A, payloadFrom(A, T.GetPeerWatermark(A.name)))
expectDiffs("  played since the forget, it is let back with its inventory", before, snap(B), {
    y("name") .. ": nil -> Yarrow Surname", y("class") .. ": nil -> MAGE", y("lastUpdate") .. ": nil -> " .. WoW.now,
    wy("bags[159]") .. ": nil -> 3", wy("bank") .. ": nil -> empty",
    wy("stamp") .. ": nil -> " .. WoW.now, wy("bagsStamp") .. ": nil -> " .. WoW.now, wy("bankStamp") .. ": nil -> 0",
})
eq("  and every watermark is reset, so the rest of it comes in full", next(B.cfg.peerWatermarks), nil)

-- (c) the settings sync's forget line, over the library from the player's own other account
WoW.now = WoW.now + 10
local fake = { messages = true, enabled = true }
function fake.SendTo() return 1 end
function fake.Peers() return { { name = A.name, guid = A.guid, realm = "R", faction = "Horde" } } end
function fake.SetEnabled(on) fake.enabled = on end
function fake.IsEnabled() return fake.enabled end
L.inst = fake; L.Forget()
A.cfg.syncSettings = true
A.cfg.forgottenCharacters = { [Y] = { at = WoW.now, forgottenAt = WoW.now, name = "Yarrow Surname" } }
A.db[Y], A.wb[Y] = nil, nil
use(A)
local lines = AltStable.PrefsSyncLines()
check("  A's forget rides the settings line", #lines == 1 and lines[1]:find(AltStable.FORGOT_LINE, 1, true) == 1)
local full = payloadFrom(A, 0, lines)
use(B); B.cfg.syncSettings = true
before = snap(B)
L.OnMessage(L.MSG_DB .. "|" .. LD:CompressDeflate(full, { level = 8 }),
            { name = A.name, guid = A.guid, realm = "R", faction = "Horde", proven = "bnet" })
expectDiffs("  a synced forget drops the record and the inventory on B", before, snap(B), {
    y("name") .. ": Yarrow Surname -> nil", y("class") .. ": MAGE -> nil", y("lastUpdate") .. ": " .. (WoW.now - 10) .. " -> nil",
    wy("bags[159]") .. ": 3 -> nil", wy("bank") .. ": empty -> nil", wy("stamp") .. ": " .. (WoW.now - 10) .. " -> nil",
    wy("bagsStamp") .. ": " .. (WoW.now - 10) .. " -> nil", wy("bankStamp") .. ": 0 -> nil",
})

------------------------------------------------------------
-- R6: a cache miss at A's login does not reach B as zeros (A1)
------------------------------------------------------------
WoW.now = WoW.now + 10
use(A)
WoW.items[5002] = { name = "A Helm", quality = 3, ilvl = 55, itemType = "Armor", subType = "Mail", equipLoc = "INVTYPE_HEAD" }
WoW.equipped[1] = "|Hitem:5002|h[A Helm]|h"
AltStable.PendingGearSlots = nil
AltStable.ScanCharacter()
eq("R6: A's scan reads the helm", A.db[X].gear_head, 55)
WoW.now = WoW.now + 10
WoW.items[5002] = nil                -- a fresh login: the cache has not answered yet
AltStable.ScanCharacter()
eq("  a rescan with the cache cold keeps its level", A.db[X].gear_head, 55)
bags(A, 2318, 12)                    -- a bag update a second later moves the record
use(B); before = snap(B)
local prevLU, prevStamp = before[x("lastUpdate")], before[wx("stamp")]
receive(B, A, payloadFrom(A, T.GetPeerWatermark(A.name)))
expectDiffs("  the delta carries the helm's level from the previous scan, not 0", before, snap(B), {
    x("gear_head") .. ": nil -> 55", x("lastUpdate") .. ": " .. prevLU .. " -> " .. WoW.now,
    wx("bags[2318]") .. ": 11 -> 12", wx("stamp") .. ": " .. prevStamp .. " -> " .. WoW.now,
    wx("bagsStamp") .. ": " .. prevStamp .. " -> " .. WoW.now,
})
-- The cache answers: the slot is filled (same values) and the record stamped.
use(A)
WoW.items[5002] = { name = "A Helm", quality = 3, ilvl = 55, itemType = "Armor", subType = "Mail", equipLoc = "INVTYPE_HEAD" }
WoW.now = WoW.now + 10
T.frame:GetScript("OnEvent")(T.frame, "GET_ITEM_INFO_RECEIVED", 5002, true)
check("  the cache event fills the slot and stamps the record",
      A.db[X].gear_head == 55 and next(AltStable.PendingGearSlots) == nil and A.db[X].lastUpdate == WoW.now,
      tostring(A.db[X].gear_head) .. " " .. tostring(A.db[X].lastUpdate))
use(B); before = snap(B)
receive(B, A, payloadFrom(A, T.GetPeerWatermark(A.name)))
expectDiffs("  and its next delta changes only the stamp on B", before, snap(B), {
    x("lastUpdate") .. ": " .. (WoW.now - 10) .. " -> " .. WoW.now,
})

------------------------------------------------------------
-- R7: the store through a Lua round trip (SavedVariables lose table identity)
------------------------------------------------------------
local function serialize(v, out)
    local t = type(v)
    if t == "table" then
        out[#out + 1] = "{"
        for k, item in pairs(v) do
            out[#out + 1] = "["; serialize(k, out); out[#out + 1] = "]="; serialize(item, out); out[#out + 1] = ","
        end
        out[#out + 1] = "}"
    elseif t == "string" then out[#out + 1] = ("%q"):format(v)
    else out[#out + 1] = tostring(v) end
end
local function roundTrip(v) local out = {}; serialize(v, out); return assert(loadstring("return " .. table.concat(out)))() end
local R = { name = B.name, guid = B.guid, db = roundTrip(B.db), cfg = roundTrip(B.cfg), wb = roundTrip(B.wb) }
expectDiffs("R7: the store reads back from disk as it was", snap(B), snap(R), {})
use(R); before = snap(R)
receive(R, A, payloadFrom(A))
expectDiffs("  and a resend of everything it holds changes nothing", before, snap(R), {})

print(("test_warband_sync: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
