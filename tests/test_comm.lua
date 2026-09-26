------------------------------------------------------------
-- test_comm.lua — AltStable sync/communication protocol tests.
--
-- Ported from AltTracker, whose Core.lua this repo imported verbatim
-- (#19). The sync engine is how another ACCOUNT's characters reach the
-- sheet - it was the only path at all while SavedVariables did not load
-- (#23, fixed in 1.60.1.70009) - and this is the harness issue #20 asks
-- for before its fixes.
--
-- Exercises the wire format in Core.lua (protocol versions, checksum,
-- character + full-DB serialization, and the chunk -> reassemble
-- receive path) with no game client, via the tests/wow_stubs.lua mock
-- and the AltStable._test seam.
--
-- Run from the repo root with the Lua 5.1 interpreter:
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_comm.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")

-- LibStub + LibDeflate (Core.lua compresses the sync payload with them).
dofile("Libs/LibStub/LibStub.lua")
dofile("Libs/LibDeflate/LibDeflate.lua")

-- SavedVariables the addon expects to already exist.
AltStable       = {}
AltStableDB     = {}
AltStableConfig = {}

-- Core.lua takes its Retail-API aliases off AltStable.API at file scope, so
-- Compat.lua runs first - and after the tables above, or resetting AltStable
-- would discard AltStable.API. Config.lua owns the config write seam
-- (SetConfigValue / OnConfigChanged) that the merge path calls.
dofile("Compat.lua")
assert(loadfile("Core.lua"))()
dofile("Config.lua")

local T       = AltStable._test

-- WoW.reset() clears the stubs; Core's own module-level sync state needs its
-- seam. Wrapped once here so every section's reset clears both.
local stubReset = WoW.reset
WoW.reset = function() stubReset(); T.ResetSyncState() end
local PREFIX  = T.PREFIX
local onEvent = T.frame:GetScript("OnEvent")


------------------------------------------------------------
-- Tiny assert harness (ParseBuddy style)
------------------------------------------------------------

local testsRun, failures = 0, 0
local function check(cond, msg)
    testsRun = testsRun + 1
    if not cond then
        failures = failures + 1
        print("  FAIL: " .. (msg or "assertion failed"))
    end
end
-- NOTE the argument order: eq(got, want, msg) here, where test_compat and
-- test_scanner use eq(name, got, want). Kept to avoid rewriting 140-odd ported
-- assertions; mind it when moving between files.
local function eq(a, b, msg)
    check(a == b, (msg or "values differ") ..
        " (expected " .. tostring(b) .. ", got " .. tostring(a) .. ")")
end

-- Run timers until none remain: a reply schedules its chunk sends from inside
-- a timer, so one flush is not enough.
local function flushAll() for _ = 1, 10 do if #WoW.timers == 0 then break end WoW.flushTimers() end end

-- Deliver a raw wire message to the receive handler as if from `sender`.
local function receive(message, sender)
    -- Forever reports the sender as "First Surname" - a space, no realm
    -- (docs/forever-api-notes.md). The TBC shape "Name-Realm" was the default
    -- here, so nothing exercised the name this client actually delivers.
    -- Approve the sender first.
    --
    -- Since #61 an unknown character asking for the database is refused and
    -- nothing is sent, which is the point of the feature - so every test in
    -- this file that is about sync MECHANICS would otherwise be testing the
    -- refusal instead. Done here rather than once at the top because several
    -- sections reassign AltStableConfig wholesale and would wipe it.
    --
    -- The gate itself is exercised in its own section, through
    -- receiveUnapproved, which deliberately skips this.
    local who = sender or "Peer Surname"
    AltStableConfig = AltStableConfig or {}
    AltStableConfig.syncAuth = AltStableConfig.syncAuth or {}
    -- Lower-cased, like Core keys it. WoW whisper targets are case-insensitive
    -- and the rest of the addon folds case everywhere; the first version of the
    -- gate did not, which made /alts deny silently no-op on a capitalisation.
    AltStableConfig.syncAuth[(who:match("^([^%-]+)") or who):lower()] = "auto"
    onEvent(T.frame, "CHAT_MSG_ADDON", PREFIX, message, "WHISPER", who)
end

local function chatHas(substr)
    for _, line in ipairs(WoW.chatOut) do
        if line:find(substr, 1, true) then return true end
    end
    return false
end

local function dbCount()
    local n = 0
    for _ in pairs(AltStableDB) do n = n + 1 end
    return n
end

-- Split captured wire into its CHUNK messages and the DONE message.
local CHUNK_PREFIX = T.MSG_CHUNK_V .. "|"
local function splitWire(messages)
    local chunks, done = {}, nil
    for _, m in ipairs(messages) do
        if m:sub(1, #CHUNK_PREFIX) == CHUNK_PREFIX then chunks[#chunks + 1] = m
        else done = m end
    end
    return chunks, done
end

-- Pull the stream id out of a captured CHUNK message.
local function sidOf(chunkMessage)
    return chunkMessage:match("^" .. T.MSG_CHUNK_V .. "|(%d+)|")
end

-- A REQ is now "REQ<ver>|<watermark>" (bare "REQ<ver>" also accepted).
local function isReq(m)
    return m == T.MSG_REQUEST_V
        or m:sub(1, #T.MSG_REQUEST_V + 1) == T.MSG_REQUEST_V .. "|"
end

-- Populate AltStableDB with n fresh characters using a unique guid prefix.
local function seedDB(prefix, n)
    AltStableDB = {}
    for i = 1, n do
        local g = prefix .. i
        AltStableDB[g] = { guid = g, name = "Char" .. i, class = "WARRIOR",
                            level = 60 + i, ilvl = 100 + i, lastUpdate = 1000 }
    end
end

-- Deterministic high-entropy hex string (defeats DEFLATE so payloads still span
-- multiple chunks after the v7 compression).
local function pseudo(seed)
    local x = seed % 2147483648
    local out = {}
    for _ = 1, 20 do
        x = (x * 1103515245 + 12345) % 2147483648
        out[#out + 1] = ("0123456789abcdef"):sub((x % 16) + 1, (x % 16) + 1)
    end
    return table.concat(out)
end

-- Like seedDB but each character carries a large incompressible `salt`, so even
-- a handful of characters compress to several chunks (for the multi-chunk paths).
local function seedBig(prefix, n)
    AltStableDB = {}
    for i = 1, n do
        local g = prefix .. i
        local salt = {}
        for j = 1, 12 do salt[j] = pseudo(i * 101 + j) end
        AltStableDB[g] = { guid = g, name = "Char" .. i, class = "WARRIOR",
                            level = 60 + i, ilvl = 100 + i, lastUpdate = 1000,
                            salt = table.concat(salt) }
    end
end

------------------------------------------------------------
-- 1. Recognising another protocol version (#37)
------------------------------------------------------------
-- The version rides in the command's numeric suffix. The old code LISTED the
-- versions it knew - and stopped at 6, so a v7 peer's DONE7 matched nothing and
-- was dropped in silence while its chunks sat in a buffer (CHUNK5 is shared by
-- v7 and v8). The user saw a stall, never "outdated addon version".

eq(T.CommandVersion("REQ8", "REQ"), 8, "the suffix is the version")
eq(T.CommandVersion("REQ", "REQ"), 1, "no suffix is v1, the first release")
eq(T.CommandVersion("DONE12", "DONE"), 12, "two digits")
eq(T.CommandVersion("REQUEST", "REQ"), nil, "a longer word is not a versioned command")
eq(T.CommandVersion("CHUNK5X", "CHUNK"), nil, "trailing junk is not a version")
eq(T.CommandVersion(nil, "REQ"), nil, "nothing is not a version")
eq(T.CommandVersion("DONE8", "REQ"), nil, "a different command is not ours")

-- A request from any version but ours is refused, and the message says which
-- side has to update.
local current = tonumber(T.PROTOCOL_VERSION)
WoW.reset()
receive("REQ" .. (current - 1) .. "|0", "Old-Realm")
check(chatHas("outdated addon version"), "the previous version's request is reported as outdated")
WoW.chatOut = {}
receive("REQ7|0", "Old-Realm")
check(chatHas("outdated"), "  v7 too, which the old list never reached")
WoW.chatOut = {}
receive("REQ" .. (current + 1) .. "|0", "New-Realm")
check(chatHas("newer addon version"), "a newer version's request says to update HERE")
WoW.chatOut = {}
receive("REQ|0", "Ancient-Realm")
check(chatHas("outdated"), "the unversioned first release is outdated")

-- A DONE from another version drops what it was assembling AND says so. The
-- old code looked up incomingBuffers[shortName], but buffers are keyed
-- "<peer>#<sid>", so it never matched: the data sat until the 120s sweep.
WoW.reset()
AltStableDB = {}
receive(T.MSG_CHUNK_V .. "|1|1/2|body", "Old-Realm")
WoW.chatOut = {}
receive("DONE7|1|abc", "Old-Realm")
check(chatHas("Discarded data"), "a DONE from another version discards the buffered chunks")
check(chatHas("outdated"), "  and names the reason")
WoW.chatOut = {}
receive("DONE7|1|abc", "Old-Realm")
check(chatHas("Ignoring sync") and not chatHas("Discarded"),
      "  with nothing buffered, it is reported without claiming a discard")

-- Discarding the data ends the watch on that stream. Without this the user got
-- the right reason now and, 45 seconds later, "stalled - try /alts sync <name>"
-- for something that cannot succeed: the contradictory advice this change
-- exists to remove, one function call away from the fix.
WoW.reset(); WoW.now = 1000
AltStableDB = {}
T.WatchSyncPeer("Old-Realm")
receive(T.MSG_CHUNK_V .. "|1|1/2|body", "Old-Realm")   -- NoteSyncActivity: sawData
receive("DONE7|1|abc", "Old-Realm")
WoW.chatOut = {}
WoW.now = 1100
WoW.flushTimers()
check(not chatHas("stalled") and not chatHas("No sync response"),
      "discarding another version's stream also ends the watch on it")

-- The line is said once per session, not once per broadcast: a peer whose chunk
-- framing also differs buffers nothing, so every stream it sends lands here.
WoW.reset()
receive("DONE7|1|abc", "Chatty-Realm")
local firstCount = 0
for _, m in ipairs(WoW.chatOut) do if m:find("Ignoring sync", 1, true) then firstCount = firstCount + 1 end end
receive("DONE7|1|abc", "Chatty-Realm")
receive("DONE7|1|abc", "Chatty-Realm")
local total = 0
for _, m in ipairs(WoW.chatOut) do if m:find("Ignoring sync", 1, true) then total = total + 1 end end
eq(firstCount, 1, "the first mismatched DONE with nothing buffered is reported")
eq(total, 1, "  and repeats are not")

-- A chunk in another FRAMING version cannot be reassembled at all.
WoW.reset()
WoW.chatOut = {}
receive("CHUNK4|1|1/1|body", "Old-Realm")
check(chatHas("outdated addon version"), "an older chunk format is reported as outdated")
WoW.chatOut = {}
receive("CHUNK9|1|1/1|body", "New-Realm")
check(chatHas("newer addon version"), "a newer one says to update here")

-- ...and the current one still works, which is what keeps the above honest.
WoW.reset()
AltStableDB = {}
local liveRec = { guid = "Player-Live-1", name = "Live", class = "MAGE", level = 60, lastUpdate = 1000 }
AltStableDB = { ["Player-Live-1"] = liveRec }
T.ChunkAndSendPayload(T.SerializeFullDB(false, 0), "WHISPER", "x")
WoW.flushTimers()
local wire = WoW.sentMessages()
AltStableDB = {}
WoW.chatOut = {}
for _, m in ipairs(wire) do receive(m, "Live-Realm") end
eq(AltStableDB["Player-Live-1"] and AltStableDB["Player-Live-1"].name, "Live",
   "the current version's stream still reassembles")
check(not chatHas("outdated") and not chatHas("newer"),
      "  and is not mistaken for another version")

------------------------------------------------------------
-- 2. Checksum
------------------------------------------------------------

eq(T.ComputeChecksum("hello"), T.ComputeChecksum("hello"), "checksum is deterministic")
check(T.ComputeChecksum("hello") ~= T.ComputeChecksum("hellp"), "checksum reacts to a 1-byte change")
eq(#T.ComputeChecksum("anything at all"), 8, "checksum is 8 hex chars")

------------------------------------------------------------
-- 3. Character serialize / deserialize round-trip
------------------------------------------------------------

local char = {
    guid = "Player-4-0001", name = "Bob", class = "WARRIOR",
    level = 70, ilvl = 123.6, account = 1, lastUpdate = 1000,
    gearlink_head = "|Hitem:12345|h[Helm]|h",  -- must be excluded (local-only)
    -- gearmod_ is the opposite of gearlink_: it MUST ride the wire. The value
    -- carries colons, which is the interesting case for the "^([^:]+):(.*)$"
    -- split in DeserializeChar.
    gearmod_head  = "2673:0:0:0:0",
    gearmod_chest = "2661:2:24028:35759:0",
    gearmod_wrist = "0:?:0:0:0",                 -- unresolved socket count
    specIcon = 98765,                            -- must be excluded (client-specific)
    someTable = { nested = true },               -- must be excluded (table)
}
local s = T.SerializeChar(char)
check(not s:find("gearlink_head", 1, true), "gearlink_ fields excluded from serialization")
check(s:find("gearmod_head", 1, true) ~= nil, "gearmod_ fields ARE included in serialization")
check(not s:find("specIcon", 1, true),      "specIcon excluded from serialization")
check(not s:find("someTable", 1, true),     "table-valued fields excluded from serialization")

local d = T.DeserializeChar(s)
eq(d.guid,  "Player-4-0001", "guid round-trips")
eq(d.name,  "Bob",           "name round-trips")
eq(d.class, "WARRIOR",       "class round-trips")
eq(d.level, 70,              "integer field round-trips as a number")
eq(d.ilvl,  123.6,           "float field round-trips as a number")
eq(d.lastUpdate, 1000,       "lastUpdate round-trips")
eq(d.gearmod_head,  "2673:0:0:0:0",           "packed gearmod_ round-trips intact")
eq(d.gearmod_chest, "2661:2:24028:35759:0",   "colon-bearing gearmod_ survives the first-colon split")
eq(d.gearmod_wrist, "0:?:0:0:0",              "unresolved '?' socket count round-trips")
eq(type(d.gearmod_head), "string",            "gearmod_ stays a string (tonumber must not coerce it)")
check(T.DeserializeChar("name:NoGuid\nlevel:10") == nil, "record without a guid is rejected")

-- Helm/cloak display toggles. They MUST ride the wire: the render pipeline reads one
-- aggregator account, so an alt's toggle only reaches it via sync. They are 1/0 numbers
-- rather than booleans precisely so the tonumber() coercion in DeserializeChar round-trips
-- them unchanged -- a boolean would arrive as the string "true".
local toggles = T.SerializeChar({
    guid = "Player-4-0002", name = "Hidden", class = "WARLOCK", level = 70, lastUpdate = 1,
    hidehelm = 1, hidecloak = 0,
})
check(toggles:find("hidehelm:1", 1, true) ~= nil,  "hidehelm rides the wire")
check(toggles:find("hidecloak:0", 1, true) ~= nil, "hidecloak rides the wire")

local dt = T.DeserializeChar(toggles)
eq(dt.hidehelm,  1, "hidehelm round-trips as a number")
eq(dt.hidecloak, 0, "hidecloak round-trips as a number")
eq(type(dt.hidehelm), "number", "hidehelm stays a number (a boolean would arrive as a string)")

-- Absent is the back-compat case: a peer on an older build sends no toggle at all, and the
-- reader must treat that as "shown", never as "hidden".
local noToggles = T.DeserializeChar(T.SerializeChar({
    guid = "Player-4-0003", name = "Old", class = "MAGE", level = 70, lastUpdate = 1,
}))
eq(noToggles.hidehelm,  nil, "absent hidehelm stays absent (reader defaults it to shown)")
eq(noToggles.hidecloak, nil, "absent hidecloak stays absent")

-- Mixed-version merge: a peer on a build that predates the toggles sends no hidehelm at all.
-- ClearSyncedStateFields must drop the previously-synced value rather than let it linger, so
-- the record falls back to "shown" instead of trusting a scan that peer can no longer confirm.
AltStableDB = {}
T.DeserializeFullDB(T.SerializeChar({
    guid = "Player-4-0004", name = "Mixed", class = "PRIEST", level = 70,
    lastUpdate = 1000, hidehelm = 1,
}) .. "\n" .. T.CHAR_SEP, "NewPeer")
eq(AltStableDB["Player-4-0004"].hidehelm, 1, "toggle arrives from a current peer")

T.DeserializeFullDB(T.SerializeChar({
    guid = "Player-4-0004", name = "Mixed", class = "PRIEST", level = 70,
    lastUpdate = 2000,          -- newer, and carries no toggle at all
}) .. "\n" .. T.CHAR_SEP, "OldPeer")
eq(AltStableDB["Player-4-0004"].hidehelm, nil,
   "a peer that predates the field clears the stale toggle instead of leaving it set")

------------------------------------------------------------
-- 4. Full-DB serialize / deserialize round-trip
------------------------------------------------------------

seedDB("Player-DB-", 3)
local payload = T.SerializeFullDB(false)
local _, sepCount = payload:gsub(T.CHAR_SEP, "")
eq(sepCount, 3, "one ==END== separator per character")

AltStableDB = {}
T.DeserializeFullDB(payload, "Peer")
eq(dbCount(), 3, "all characters restored from full-DB payload")
eq(AltStableDB["Player-DB-2"] and AltStableDB["Player-DB-2"].name, "Char2", "a specific char restored")
eq(AltStableDB["Player-DB-1"].level, 61, "numeric field restored as a number")

------------------------------------------------------------
-- 5. Validation: class change for an existing guid is rejected
------------------------------------------------------------

WoW.reset()
AltStableDB = { ["Player-V-1"] = { guid = "Player-V-1", name = "Vee", class = "MAGE", level = 70, lastUpdate = 500 } }
local badPayload = T.SerializeChar(
    { guid = "Player-V-1", name = "Vee", class = "WARRIOR", level = 70, lastUpdate = 600 }
) .. "\n" .. T.CHAR_SEP
T.DeserializeFullDB(badPayload, "Peer")
eq(AltStableDB["Player-V-1"].class, "MAGE", "class change is rejected — original retained")
check(chatHas("Rejected"), "class-change rejection is reported to the user")

------------------------------------------------------------
-- 6. Last-write-wins timestamp merge
------------------------------------------------------------

AltStableDB = { ["Player-T-1"] = { guid = "Player-T-1", name = "Tee", class = "PRIEST", level = 70, ilvl = 200, lastUpdate = 1000 } }
-- Incoming is >60s OLDER than local: keep local.
T.DeserializeFullDB(T.SerializeChar(
    { guid = "Player-T-1", name = "Tee", class = "PRIEST", level = 70, ilvl = 50, lastUpdate = 900 }
) .. "\n" .. T.CHAR_SEP, "Peer")
eq(AltStableDB["Player-T-1"].ilvl, 200, "older incoming (>60s) does not overwrite newer local")
-- Incoming within 60s: accept.
T.DeserializeFullDB(T.SerializeChar(
    { guid = "Player-T-1", name = "Tee", class = "PRIEST", level = 70, ilvl = 250, lastUpdate = 970 }
) .. "\n" .. T.CHAR_SEP, "Peer")
eq(AltStableDB["Player-T-1"].ilvl, 250, "incoming within 60s overwrites local")

------------------------------------------------------------
-- 7. End-to-end wire round-trip: chunk -> reassemble
------------------------------------------------------------

WoW.reset()
seedBig("Player-W-", 6)
T.ChunkAndSendPayload(T.SerializeFullDB(false), "WHISPER", "Wire")
WoW.flushTimers()                       -- fire the paced C_Timer.After sends
local wire = WoW.sentMessages()
local chunks, done = splitWire(wire)
check(#chunks >= 2, "a 6-character DB spans multiple chunks")
check(done ~= nil, "a DONE message is sent after the chunks")

AltStableDB = {}
WoW.chatOut = {}
for _, m in ipairs(wire) do receive(m, "Wire-Realm") end
check(not chatHas("mismatch"), "clean round-trip has no checksum mismatch")
check(not chatHas("missing"),  "clean round-trip reports no missing chunks")
eq(dbCount(), 6, "all 6 characters reassembled from the wire")
eq(AltStableDB["Player-W-3"] and AltStableDB["Player-W-3"].name, "Char3", "a specific char survived the wire round-trip")

------------------------------------------------------------
-- 8. Out-of-order chunk delivery still reassembles
------------------------------------------------------------

AltStableDB = {}
WoW.chatOut = {}
for i = #chunks, 1, -1 do receive(chunks[i], "Wire-Realm") end  -- reversed
receive(done, "Wire-Realm")
check(not chatHas("mismatch"), "out-of-order delivery still checksums correctly")
eq(dbCount(), 6, "out-of-order chunks reassemble to the full DB")

------------------------------------------------------------
-- 9. Dropped chunk is detected and triggers an auto-resync
------------------------------------------------------------

WoW.reset()
seedBig("Player-D-", 6)
T.ChunkAndSendPayload(T.SerializeFullDB(false), "WHISPER", "Drop")
WoW.flushTimers()
local dChunks, dDone = splitWire(WoW.sentMessages())
check(#dChunks >= 2, "need multiple chunks to simulate a drop")

AltStableDB = {}
WoW.chatOut = {}
WoW.sent = {}
for i = 1, #dChunks - 1 do receive(dChunks[i], "Drop-Realm") end  -- drop the last chunk
receive(dDone, "Drop-Realm")
-- DONE defers behind the grace window; nothing is declared missing yet.
eq(dbCount(), 0, "incomplete stream is not applied")
WoW.flushTimers()  -- grace window elapses -> completion check finds it still missing
check(chatHas("missing") or chatHas("incomplete"), "a genuinely missing chunk is detected after the grace window")
eq(dbCount(), 0, "DB is not updated when a chunk stays missing")
WoW.flushTimers()  -- run the queued resync request
local reqSent = false
for _, m in ipairs(WoW.sentMessages()) do
    if isReq(m) then reqSent = true end
end
check(reqSent, "receiver auto-requests a resync after a genuine drop")

------------------------------------------------------------
-- 10. Checksum mismatch discards the data AND auto-requests a resync (H2)
------------------------------------------------------------

WoW.reset()
seedDB("Player-C-", 3)
T.ChunkAndSendPayload(T.SerializeFullDB(false), "WHISPER", "Corrupt")
WoW.flushTimers()
local cChunks = splitWire(WoW.sentMessages())
local cSid = sidOf(cChunks[1])

AltStableDB = {}
WoW.chatOut = {}
WoW.sent = {}
for _, m in ipairs(cChunks) do receive(m, "Corrupt-Realm") end
receive(T.MSG_DONE_V .. "|" .. cSid .. "|DEADBEEF", "Corrupt-Realm")  -- correct sid, wrong checksum
check(chatHas("mismatch"), "checksum mismatch is detected")
eq(dbCount(), 0, "data is discarded on checksum mismatch")
WoW.flushTimers()   -- run the queued resync request
local cReq = false
for _, m in ipairs(WoW.sentMessages()) do
    if isReq(m) then cReq = true end
end
check(cReq, "checksum mismatch now auto-requests a resync (H2 fix)")

------------------------------------------------------------
-- 11. Packets from ourselves are ignored
------------------------------------------------------------

-- A real, appliable payload, sent under the player's own Forever-shaped name.
-- The ported version sent a Base64 body with a zero checksum from a leftover
-- AltTracker name: it could never apply by any route, so it passed with the
-- self-check deleted. The control below proves the same wire DOES apply from
-- anyone else, which is what makes the first assertion mean something.
WoW.reset()
seedDB("Player-Self-", 2)
T.ChunkAndSendPayload(T.SerializeFullDB(false), "WHISPER", "x")
WoW.flushTimers()
local selfWire = WoW.sentMessages()
AltStableDB = {}
-- WoW.player.name, not UnitName("player"): since 1.60.1.70009 that call
-- returns TWO values, so as the last argument it expanded to (first, surname)
-- and handed receive() half a name. The wire carries the whole thing - the
-- live client logs "Receiving data from Kaleid Sumner", and peer IS sender.
for _, m in ipairs(selfWire) do receive(m, WoW.player.name) end
eq(dbCount(), 0, "our own packets (sender == player, Forever-shaped) are ignored")

-- The half name is what a client reading only UnitName's first return would
-- put in PLAYER_NAME. It must NOT be treated as us: the sender on the wire has
-- the surname, so a short PLAYER_NAME stops matching and we process our own
-- broadcast back into the database.
AltStableDB = {}
for _, m in ipairs(selfWire) do receive(m, WoW.player.name:match("^(%S+)")) end
check(dbCount() > 0, "a HALF name is a different sender, not us")

-- The login refresh. UnitName("player") can return nil at file load, so Core
-- re-reads our own name at PLAYER_LOGIN; if that path drops the surname, the
-- self-echo check is defeated for the whole session and nothing above notices,
-- because those assertions use the name captured at load.
WoW.reset()
WoW.player.name = "Renamed Person"
onEvent(T.frame, "PLAYER_LOGIN")
WoW.sent = {}
seedDB("Player-Self2-", 2)
T.ChunkAndSendPayload(T.SerializeFullDB(false), "WHISPER", "x")
flushAll()
local renamedWire = WoW.sentMessages()
AltStableDB = {}
for _, m in ipairs(renamedWire) do receive(m, "Renamed Person") end
eq(dbCount(), 0, "the name re-read at login carries the surname too")
-- WoW.reset() puts the stub's character back, but nothing outside Core can
-- reach the PLAYER_NAME it captured at login - so fire the login again. Skip
-- it and every later self-echo assertion is judged against "Renamed Person";
-- prove the restore here, once, rather than trusting it.
WoW.reset()
onEvent(T.frame, "PLAYER_LOGIN")
WoW.sent = {}
seedDB("Player-Self3-", 2)
T.ChunkAndSendPayload(T.SerializeFullDB(false), "WHISPER", "x")
flushAll()
local restoredWire = WoW.sentMessages()
AltStableDB = {}
for _, m in ipairs(restoredWire) do receive(m, WoW.player.name) end
eq(dbCount(), 0, "PLAYER_NAME is back to this character after the rename test")
WoW.reset()
WoW.sent = {}

------------------------------------------------------------
-- The reply stagger uses the WHOLE name
------------------------------------------------------------
-- Two clients answering one broadcast must not pick the same moment. Forever
-- surnames make "two characters, one first name" ordinary, so a seed built
-- from the first name alone reintroduces exactly the collision this avoids.

eq(T.ReplyDelay("Kaleid Sumner", 0) == T.ReplyDelay("Kaleid Fox", 0), false,
   "two characters sharing a first name get different delays")
check(T.ReplyDelay("Kaleid Sumner", 0) >= 1 and T.ReplyDelay("Kaleid Sumner", 0) <= 4,
      "the delay stays within 1-4 seconds")
check(T.ReplyDelay(nil, 0) >= 1, "an unreadable name still yields a usable delay")

-- The stub's own promise, since the block above leans on it: a renamed
-- character does not leak into the next test.
WoW.player.name = "Temporary Person"
WoW.reset()
eq(WoW.player.name, "Example Surname", "WoW.reset() puts the character back")

-- ...and the request handler actually uses it, with the full name.
WoW.reset()
AltStableDB = {}
WoW.timers = {}
receive(T.MSG_REQUEST_V .. "|0", "Asker Person")
local scheduled = WoW.timers[1]
check(scheduled ~= nil, "a request schedules a staggered reply")
if scheduled then
    eq(scheduled.delay, T.ReplyDelay(WoW.player.name, WoW.now),
       "the reply delay is seeded from our whole name")
end
WoW.reset()
AltStableDB = {}
for _, m in ipairs(selfWire) do receive(m, "Other Surname") end
eq(dbCount(), 2, "  and the same wire from anyone else applies (control)")

------------------------------------------------------------
-- 11b. Peer keys keep the surname
--
-- PeerShort strips a "-Realm" suffix. On Forever two different characters can
-- share a first name, so splitting on the space would merge "Bob Smith" and
-- "Bob Jones" into one peer - one watermark, one retry budget, one stall watch.
------------------------------------------------------------

eq(T.PeerShort("Bob Smith"), "Bob Smith", "a Forever sender keeps its surname")
check(T.PeerShort("Bob Smith") ~= T.PeerShort("Bob Jones"), "two peers sharing a first name stay distinct")
eq(T.PeerShort("Bob Smith-Realm"), "Bob Smith", "a realm suffix is still stripped")

------------------------------------------------------------
-- 12. Account-only serialization filter
------------------------------------------------------------

WoW.reset()
AltStableConfig = { accountNumber = 2 }
AltStableDB = {
    ["Player-Acct-mine"]  = { guid = "Player-Acct-mine",  name = "Mine",  class = "MAGE",   level = 70, account = 2, lastUpdate = 1 },
    ["Player-Acct-other"] = { guid = "Player-Acct-other", name = "Other", class = "ROGUE",  level = 70, account = 5, lastUpdate = 1 },
    ["Player-Acct-untag"] = { guid = "Player-Acct-untag", name = "Untag", class = "PRIEST", level = 70,              lastUpdate = 1 },
}
local mineOnly = T.SerializeFullDB(true)
check(mineOnly:find("Player-Acct-mine",  1, true), "account filter includes my-account char")
check(mineOnly:find("Player-Acct-untag", 1, true), "account filter includes untagged char")
check(not mineOnly:find("Player-Acct-other", 1, true), "account filter excludes a different account's char")
check(T.SerializeFullDB(false):find("Player-Acct-other", 1, true), "unfiltered serialize includes every account")

------------------------------------------------------------
-- 13. A large field survives compression + multi-chunk reassembly byte-exact
------------------------------------------------------------

WoW.reset()
local bigParts = {}
for i = 1, 60 do bigParts[i] = pseudo(i) end
local bigVal = table.concat(bigParts)   -- ~1200 high-entropy chars
AltStableDB = { ["Player-Big-1"] = { guid = "Player-Big-1", name = "Big", class = "WARRIOR", level = 70, notes = bigVal, lastUpdate = 1000 } }
T.ChunkAndSendPayload(T.SerializeFullDB(false), "WHISPER", "Big")
WoW.flushTimers()
local bigChunks = splitWire(WoW.sentMessages())
check(#bigChunks >= 2, "a large field compresses to more than one chunk")
AltStableDB = {}
WoW.chatOut = {}
for _, m in ipairs(WoW.sentMessages()) do receive(m, "Big-Realm") end
check(not chatHas("mismatch"), "large-field stream checksums correctly")
eq(AltStableDB["Player-Big-1"] and AltStableDB["Player-Big-1"].notes, bigVal, "large field value reassembled byte-exact through compression")

------------------------------------------------------------
-- 14. Merge clears stale profession fields when a peer drops a profession
------------------------------------------------------------

WoW.reset()
AltStableDB = { ["Player-Prof-1"] = { guid = "Player-Prof-1", name = "Pro", class = "WARRIOR", level = 70, prof1 = "Mining", prof_Mining = 300, lastUpdate = 1000 } }
T.DeserializeFullDB(T.SerializeChar(
    { guid = "Player-Prof-1", name = "Pro", class = "WARRIOR", level = 70, lastUpdate = 1000 }
) .. "\n" .. T.CHAR_SEP, "Peer")
eq(AltStableDB["Player-Prof-1"].prof_Mining, nil, "stale prof_ field cleared on merge")
eq(AltStableDB["Player-Prof-1"].prof1, nil, "stale prof1 cleared on merge")

-- Reputations (#8): a standing dropped at the source must not linger here.
-- The incoming record carries the standings it still has; any other rep_
-- field on the stored copy goes.
AltStableDB = { ["Player-Rep-1"] = { guid = "Player-Rep-1", name = "Rep", class = "MAGE", level = 20,
                                      rep_76 = 4, rep_2758 = 5, lastUpdate = 1000 } }
T.DeserializeFullDB(T.SerializeChar(
    { guid = "Player-Rep-1", name = "Rep", class = "MAGE", level = 20, rep_76 = 6, lastUpdate = 1000 }
) .. "\n" .. T.CHAR_SEP, "Peer")
eq(AltStableDB["Player-Rep-1"].rep_2758, nil, "a standing the peer no longer has is cleared on merge")
eq(AltStableDB["Player-Rep-1"].rep_76, 6, "  and a standing it sent is updated")

------------------------------------------------------------
-- 15. Plugin per-character payload round-trips through serialization
------------------------------------------------------------

WoW.reset()
local delivered = {}
AltStable.plugins = {
    { id = "demo",
      OnSerialize   = function(guid) return "blob-for:" .. guid end,
      OnDeserialize = function(guid, blob) delivered[guid] = blob end },
}
local ps = T.SerializeChar({ guid = "Player-Plug-1", name = "Plug", class = "MAGE", level = 70, lastUpdate = 1 })
check(ps:find("plugin_demo:blob-for:Player-Plug-1", 1, true), "plugin data serialized as plugin_<id>:<blob>")
-- Dispatched by the ACCEPT path, not by DeserializeChar: a blob must not be
-- applied for a character whose own record is then rejected.
AltStableDB = {}
T.DeserializeFullDB(ps .. "\n" .. T.CHAR_SEP, "Peer")
eq(delivered["Player-Plug-1"], "blob-for:Player-Plug-1", "plugin OnDeserialize receives its blob for an accepted char")

local parsed = T.DeserializeChar(ps)
eq(parsed._pluginPayloads and parsed._pluginPayloads.demo, "blob-for:Player-Plug-1",
   "  the blob rides on the parsed record until then")
check(not T.SerializeChar(parsed):find("_pluginPayloads", 1, true),
      "  and the carrier field never goes back on the wire")

-- A record rejected by validation (an existing guid under a different name)
-- must not have its inventory applied: the sheet would show one character and
-- the plugin another's items.
delivered = {}
AltStableDB = { ["Player-Plug-1"] = { guid = "Player-Plug-1", name = "Plug", class = "MAGE",
                                      level = 70, lastUpdate = 5 } }
local impostor = T.SerializeChar({ guid = "Player-Plug-1", name = "Impostor", class = "MAGE",
                                   level = 70, lastUpdate = 9 })
T.DeserializeFullDB(impostor .. "\n" .. T.CHAR_SEP, "Peer")
eq(AltStableDB["Player-Plug-1"].name, "Plug", "a conflicting-name record is rejected")
eq(delivered["Player-Plug-1"], nil, "  and its plugin blob is not applied")

-- Same for a record the merge rule declines (well older than what we hold -
-- the rule allows a small window, so this is a minute-plus behind).
delivered = {}
AltStableDB["Player-Plug-1"].lastUpdate = 5000
local older = T.SerializeChar({ guid = "Player-Plug-1", name = "Plug", class = "MAGE",
                                level = 70, lastUpdate = 1 })
T.DeserializeFullDB(older .. "\n" .. T.CHAR_SEP, "Peer")
eq(delivered["Player-Plug-1"], nil, "a record that loses the merge does not apply its blob either")

-- The single-character path (MSG_CHAR) has the same rule; the two receive
-- paths have drifted apart before.
delivered = {}
AltStableDB = {}
T.ReceiveCharacter(T.DeserializeChar(ps), "Peer")
eq(delivered["Player-Plug-1"], "blob-for:Player-Plug-1", "the single-character path dispatches on accept")

delivered = {}
AltStableDB = { ["Player-Plug-1"] = { guid = "Player-Plug-1", name = "Plug", class = "MAGE",
                                      level = 70, lastUpdate = 5000 } }
T.ReceiveCharacter(T.DeserializeChar(impostor), "Peer")
eq(AltStableDB["Player-Plug-1"].name, "Plug", "  a conflicting name is still rejected there")
eq(delivered["Player-Plug-1"], nil, "  and no blob is applied")
AltStable.plugins = {}   -- reset so it doesn't affect other cases

------------------------------------------------------------
-- 16. Name change for an existing guid is rejected
------------------------------------------------------------

WoW.reset()
AltStableDB = { ["Player-Name-1"] = { guid = "Player-Name-1", name = "Alice", class = "MAGE", level = 70, lastUpdate = 500 } }
T.DeserializeFullDB(T.SerializeChar(
    { guid = "Player-Name-1", name = "Bob", class = "MAGE", level = 70, lastUpdate = 600 }
) .. "\n" .. T.CHAR_SEP, "Peer")
eq(AltStableDB["Player-Name-1"].name, "Alice", "name change rejected — original retained")
check(chatHas("name changed") or chatHas("Rejected"), "name-change rejection reported")

------------------------------------------------------------
-- ...but a SURNAME is not a name change (#56)
------------------------------------------------------------
-- Live rejection on 1.60.1.70009: "Rejected data for GUID Player-4618-006B8614
-- from Kaleid Sumner: name changed (Kaleid Sumner -> Kaleid)". The peer had
-- read only UnitName's first return, so it sent the half name for a character
-- this client had on disk, from the previous build, in full. Same GUID, same
-- character - and rejecting it means that character silently stops updating.

WoW.reset()
AltStableDB = { ["Player-Sur-1"] = { guid = "Player-Sur-1", name = "Kaleid Sumner",
                                     class = "MAGE", level = 16, lastUpdate = 500 } }
T.DeserializeFullDB(T.SerializeChar(
    { guid = "Player-Sur-1", name = "Kaleid", class = "MAGE", level = 17, lastUpdate = 600 }
) .. "\n" .. T.CHAR_SEP, "Kaleid Sumner")
eq(AltStableDB["Player-Sur-1"].level, 17, "a half name from an older client still updates")
eq(AltStableDB["Player-Sur-1"].name, "Kaleid Sumner",
   "  and the surname we already had is kept, not dropped")
check(not chatHas("name changed"), "  with nothing rejected")

-- The other direction: we hold the half name, the peer sends it whole.
WoW.reset()
AltStableDB = { ["Player-Sur-2"] = { guid = "Player-Sur-2", name = "Kaleid",
                                     class = "MAGE", level = 16, lastUpdate = 500 } }
T.DeserializeFullDB(T.SerializeChar(
    { guid = "Player-Sur-2", name = "Kaleid Sumner", class = "MAGE", level = 17, lastUpdate = 600 }
) .. "\n" .. T.CHAR_SEP, "Kaleid Sumner")
eq(AltStableDB["Player-Sur-2"].name, "Kaleid Sumner", "a record missing its surname gains one")
eq(AltStableDB["Player-Sur-2"].level, 17, "  and updates")

-- A REAL rename is not reverted. Keeping "the longer name" would pin this
-- record to the stale surname forever, and we would re-broadcast it.
WoW.reset()
AltStableDB = { ["Player-Sur-4"] = { guid = "Player-Sur-4", name = "Kaleid Sumner",
                                     class = "MAGE", level = 16, lastUpdate = 500 } }
T.DeserializeFullDB(T.SerializeChar(
    { guid = "Player-Sur-4", name = "Kaleid Fox", class = "MAGE", level = 17, lastUpdate = 600 }
) .. "\n" .. T.CHAR_SEP, "Peer")
eq(AltStableDB["Player-Sur-4"].name, "Kaleid Fox", "a shorter NEW surname replaces the old one")

-- A DIFFERENT character is still refused: the first name is what cannot change.
WoW.reset()
AltStableDB = { ["Player-Sur-3"] = { guid = "Player-Sur-3", name = "Kaleid Sumner",
                                     class = "MAGE", level = 16, lastUpdate = 500 } }
T.DeserializeFullDB(T.SerializeChar(
    { guid = "Player-Sur-3", name = "Zoruka Sumner", class = "MAGE", level = 17, lastUpdate = 600 }
) .. "\n" .. T.CHAR_SEP, "Peer")
eq(AltStableDB["Player-Sur-3"].name, "Kaleid Sumner", "a different first name is still rejected")
eq(AltStableDB["Player-Sur-3"].level, 16, "  and nothing it carried was merged")
check(chatHas("name changed") or chatHas("Rejected"), "  and it is reported")

------------------------------------------------------------
-- 17. Malformed / out-of-range chunks are discarded and reported
------------------------------------------------------------

WoW.reset()
AltStableDB = {}
receive(T.MSG_CHUNK_V .. "|1|not-a-valid-header", "Junk-Realm")
check(chatHas("Malformed"), "malformed chunk header is reported")
WoW.chatOut = {}
receive(T.MSG_CHUNK_V .. "|1|9/3|body", "Junk-Realm")
check(chatHas("Out-of-range"), "out-of-range seq (seq > total) is reported")

------------------------------------------------------------
-- 18. DONE with no received chunks is a safe no-op
------------------------------------------------------------

WoW.reset()
AltStableDB = {}
receive(T.MSG_DONE_V .. "|1|00000000", "Ghost-Realm")
eq(dbCount(), 0, "DONE with no buffered chunks stores nothing and does not error")

------------------------------------------------------------
-- 19. Duplicate chunk delivery is idempotent
------------------------------------------------------------

WoW.reset()
seedBig("Player-Dup-", 4)
T.ChunkAndSendPayload(T.SerializeFullDB(false), "WHISPER", "Dup")
WoW.flushTimers()
local dupChunks, dupDone = splitWire(WoW.sentMessages())
AltStableDB = {}
WoW.chatOut = {}
receive(dupChunks[1], "Dup-Realm")
receive(dupChunks[1], "Dup-Realm")   -- same seq delivered twice
for i = 2, #dupChunks do receive(dupChunks[i], "Dup-Realm") end
receive(dupDone, "Dup-Realm")
check(not chatHas("mismatch"), "duplicate chunk does not corrupt reassembly")
eq(dbCount(), 4, "duplicate chunk delivery is idempotent")

------------------------------------------------------------
-- 20. Two interleaved streams from one sender do not clobber (H1)
------------------------------------------------------------

WoW.reset()
-- Stream A: chars IA1..IA3
AltStableDB = {}
for i = 1, 3 do local g = "Player-IA-" .. i; AltStableDB[g] = { guid = g, name = "IA" .. i, class = "MAGE",  level = 60, ilvl = 100, lastUpdate = 1 } end
T.ChunkAndSendPayload(T.SerializeFullDB(false), "WHISPER", "Inter")
WoW.flushTimers()
local aChunks, aDone = splitWire(WoW.sentMessages())
-- Stream B: a DIFFERENT set of chars IB1..IB3, same sender
WoW.sent = {}
AltStableDB = {}
for i = 1, 3 do local g = "Player-IB-" .. i; AltStableDB[g] = { guid = g, name = "IB" .. i, class = "ROGUE", level = 60, ilvl = 100, lastUpdate = 1 } end
T.ChunkAndSendPayload(T.SerializeFullDB(false), "WHISPER", "Inter")
WoW.flushTimers()
local bChunks, bDone = splitWire(WoW.sentMessages())
check(sidOf(aChunks[1]) ~= sidOf(bChunks[1]), "the two streams carry distinct stream ids")

-- Deliver the two streams' chunks interleaved, then both DONEs.
AltStableDB = {}
WoW.chatOut = {}
local maxc = math.max(#aChunks, #bChunks)
for i = 1, maxc do
    if aChunks[i] then receive(aChunks[i], "Inter-Realm") end
    if bChunks[i] then receive(bChunks[i], "Inter-Realm") end
end
receive(aDone, "Inter-Realm")
receive(bDone, "Inter-Realm")
check(not chatHas("mismatch"), "interleaved streams each checksum correctly (no clobbering)")
local bothOk = true
for i = 1, 3 do
    if not AltStableDB["Player-IA-" .. i] then bothOk = false end
    if not AltStableDB["Player-IB-" .. i] then bothOk = false end
end
check(bothOk, "both interleaved streams reassembled independently")
eq(dbCount(), 6, "all 6 chars from two interleaved streams stored")

------------------------------------------------------------
-- 21. DONE overtaking a late chunk completes within the grace window (M1)
------------------------------------------------------------

WoW.reset()
seedBig("Player-Late-", 6)
T.ChunkAndSendPayload(T.SerializeFullDB(false), "WHISPER", "Late")
WoW.flushTimers()
local lChunks, lDone = splitWire(WoW.sentMessages())
check(#lChunks >= 2, "need multiple chunks for the late-chunk scenario")

AltStableDB = {}
WoW.chatOut = {}
-- Deliver all but the last chunk, then let the DONE overtake the straggler.
for i = 1, #lChunks - 1 do receive(lChunks[i], "Late-Realm") end
receive(lDone, "Late-Realm")
eq(dbCount(), 0, "DONE does not finalize while a chunk is still in flight")
check(not chatHas("missing"), "DONE does not immediately declare a missing chunk (grace)")
-- The straggler arrives during the grace window; then the grace timer fires.
receive(lChunks[#lChunks], "Late-Realm")
WoW.flushTimers()
check(not chatHas("missing"), "a late chunk arriving within grace avoids a false 'missing'")
eq(dbCount(), 6, "the stream completes once the late chunk arrives within grace")

------------------------------------------------------------
-- 22. Peer-online re-request matches a realm-qualified whitelist entry (M3)
------------------------------------------------------------

WoW.reset()
AltStableConfig = { whitelist = { "Bob-Realm" } }
AltStableDB = {}
onEvent(T.frame, "CHAT_MSG_SYSTEM", "Bob has come online. |Hplayer:Bob|h[Bob]|h")
WoW.flushTimers()   -- fire the delayed re-request
local reqTarget = nil
for _, s in ipairs(WoW.sent) do
    if isReq(s.text) then reqTarget = s.target end
end
eq(reqTarget, "Bob-Realm", "peer-online whispers the REQ to the full Name-Realm whitelist entry")

------------------------------------------------------------
-- 23. Merge drops stale per-slot gear fields — including a stale local-only
--     gearlink from an old sync — but keeps metadata (M6 + cross-account
--     stale-tooltip fix)
------------------------------------------------------------

WoW.reset()
AltStableDB = { ["Player-Stale-1"] = {
    guid = "Player-Stale-1", name = "Stale", class = "WARRIOR", level = 70,
    gearid_head = 111, gearname_head = "Old Helm", gearq_head = 4,
    -- A stale link left over from an old addon version that synced links; on a
    -- received (remote) record this is never trustworthy and must be cleared.
    gearlink_head = "|Hitem:111|h[Felheart Horns]|h",
    -- Likewise stale: the peer re-enchanted, so the old packed mods must not survive.
    gearmod_head = "2673:0:0:0:0",
    account = 2,                     -- metadata, must survive when peer omits it
    lastUpdate = 1000,
} }
-- Incoming record has re-geared the head slot (new id/name/ilvl, no link).
T.DeserializeFullDB(T.SerializeChar(
    { guid = "Player-Stale-1", name = "Stale", class = "WARRIOR", level = 70,
      gearid_head = 999, gearname_head = "Hood of the Corruptor", gearq_head = 4, lastUpdate = 1000 }
) .. "\n" .. T.CHAR_SEP, "Peer")
local rec = AltStableDB["Player-Stale-1"]
eq(rec.gearid_head,   999, "synced item id replaces the old one")
eq(rec.gearname_head, "Hood of the Corruptor", "synced item name replaces the old one")
eq(rec.gearlink_head, nil, "stale local-only gearlink_ is cleared on merge (fixes cross-account stale tooltip)")
eq(rec.gearmod_head,  nil, "stale gearmod_ is cleared on merge -- '^gear_' does NOT match 'gearmod_', so it needs its own pattern")
eq(rec.account,       2,   "metadata (account) is preserved when the incoming record omits it")

------------------------------------------------------------
-- 24. Single-char (CHAR) receive path respects last-write-wins
------------------------------------------------------------

WoW.reset()
AltStableDB = { ["Player-CH-1"] = { guid = "Player-CH-1", name = "Cee", class = "MAGE", ilvl = 200, lastUpdate = 1000 } }
-- An older single-character update (>60s behind) must NOT clobber newer local.
receive("CHAR|" .. T.SerializeChar(
    { guid = "Player-CH-1", name = "Cee", class = "MAGE", ilvl = 50, lastUpdate = 900 }
), "Peer-Realm")
eq(AltStableDB["Player-CH-1"].ilvl, 200, "stale single-char update does not overwrite newer local data")
-- A newer single-character update is applied.
receive("CHAR|" .. T.SerializeChar(
    { guid = "Player-CH-1", name = "Cee", class = "MAGE", ilvl = 260, lastUpdate = 1000 }
), "Peer-Realm")
eq(AltStableDB["Player-CH-1"].ilvl, 260, "current single-char update is applied")

------------------------------------------------------------
-- 25. Delta sync: SerializeFullDB(sinceTS) only sends changed characters
------------------------------------------------------------

WoW.reset()
AltStableConfig = { peerWatermarks = {} }
AltStableDB = {
    ["Player-DS-old"] = { guid = "Player-DS-old", name = "Old", class = "MAGE",  ilvl = 100, lastUpdate = 500 },
    ["Player-DS-new"] = { guid = "Player-DS-new", name = "New", class = "ROGUE", ilvl = 110, lastUpdate = 900 },
}
local full = T.SerializeFullDB(false, 0)
check(full:find("Player-DS-old", 1, true) and full:find("Player-DS-new", 1, true), "full sync (sinceTS 0) includes every character")
local delta = T.SerializeFullDB(false, 600)
check(not delta:find("Player-DS-old", 1, true), "delta excludes a character not changed since the watermark")
check(delta:find("Player-DS-new", 1, true), "delta includes a character changed since the watermark")

------------------------------------------------------------
-- #20 bug 2: a peer cannot overwrite a character this client scans
--
-- The first fix decided from the data (keep a link while the gearid matched).
-- That still let a peer's slightly OLDER echo - inside the 60-second grace -
-- roll our gear back, and let an old synced link survive on a remote record
-- forever. Ownership decides now: our own characters accept only strictly
-- newer records, on both merge paths.
------------------------------------------------------------

local function ownChar()
    return {
        guid = "Player-Own-1", name = "Mine", class = "PRIEST", level = 60, scannedHere = true,
        gearid_chest = 888, gear_chest = 60, gearlink_chest = "|Hitem:888|h[New Robe]|h",
        gearsubtype_chest = "Cloth", lastUpdate = 1030,
    }
end
local olderEcho = { guid = "Player-Own-1", name = "Mine", class = "PRIEST", level = 60,
                    gearid_chest = 777, gear_chest = 50, lastUpdate = 1000 }

-- The reviewer's scenario: the alt swapped 777 -> 888 thirty seconds ago; a
-- peer echoes back its copy from before the swap.
WoW.reset()
AltStableDB = { ["Player-Own-1"] = ownChar() }
T.DeserializeFullDB(T.SerializeChar(olderEcho) .. "\n" .. T.CHAR_SEP, "Peer")
local own = AltStableDB["Player-Own-1"]
eq(own.gearid_chest, 888, "a slightly older echo cannot roll back our own gear")
eq(own.gearlink_chest, "|Hitem:888|h[New Robe]|h", "  or take our local-only link with it")

-- The same through the per-character path, which the first fix never reached.
WoW.reset()
AltStableDB = { ["Player-Own-1"] = ownChar() }
T.ReceiveCharacter(T.DeserializeChar(T.SerializeChar(olderEcho)), "Peer")
own = AltStableDB["Player-Own-1"]
eq(own.gearid_chest, 888, "the CHAR merge path protects our own characters too")
eq(own.gearlink_chest, "|Hitem:888|h[New Robe]|h", "  including their local-only link")

-- An exact echo of our own record changes nothing either.
WoW.reset()
AltStableDB = { ["Player-Own-1"] = ownChar() }
local sameEcho = ownChar(); sameEcho.scannedHere = nil; sameEcho.gearlink_chest = nil; sameEcho.gearsubtype_chest = nil
T.DeserializeFullDB(T.SerializeChar(sameEcho) .. "\n" .. T.CHAR_SEP, "Peer")
eq(AltStableDB["Player-Own-1"].gearsubtype_chest, "Cloth", "an exact echo leaves our local-only fields alone")

-- Played on another machine since: strictly newer wins, and our local-only
-- fields now describe a stale scan, so they go.
WoW.reset()
AltStableDB = { ["Player-Own-1"] = ownChar() }
T.DeserializeFullDB(T.SerializeChar(
    { guid = "Player-Own-1", name = "Mine", class = "PRIEST", level = 60,
      gearid_chest = 999, gear_chest = 70, lastUpdate = 2000 }
) .. "\n" .. T.CHAR_SEP, "Peer")
own = AltStableDB["Player-Own-1"]
eq(own.gearid_chest, 999, "a strictly newer record for our character is accepted")
eq(own.gearlink_chest, nil, "  and our stale local-only link is cleared")

-- A REMOTE record never keeps a link, even for the same item - the invariant
-- the data rule broke. RowRenderer's SetHyperlink branch must never see one.
WoW.reset()
AltStableDB = { ["Player-Remote-1"] = {
    guid = "Player-Remote-1", name = "Theirs", class = "MAGE", level = 60,
    gearid_head = 111, gearlink_head = "|Hitem:111:2673|h[Old]|h", lastUpdate = 1000 } }
T.DeserializeFullDB(T.SerializeChar(
    { guid = "Player-Remote-1", name = "Theirs", class = "MAGE", level = 60,
      gearid_head = 111, lastUpdate = 1000 }
) .. "\n" .. T.CHAR_SEP, "Peer")
eq(AltStableDB["Player-Remote-1"].gearlink_head, nil, "a remote record never keeps a link, even for the same item")

-- The ownership marker must never ride the wire.
check(not T.SerializeChar(ownChar()):find("scannedHere", 1, true),
      "scannedHere is local-only and never serialized")

------------------------------------------------------------
-- 26. Delta sync: the watermark advances after a successful receive
------------------------------------------------------------

WoW.reset()
AltStableConfig = { peerWatermarks = {} }
AltStableDB = {
    ["Player-WM-1"] = { guid = "Player-WM-1", name = "W1", class = "MAGE",  ilvl = 100, lastUpdate = 700 },
    ["Player-WM-2"] = { guid = "Player-WM-2", name = "W2", class = "ROGUE", ilvl = 110, lastUpdate = 1200 },
}
T.SendFullDatabase("WHISPER", "x")      -- the real reply path, which carries our clock
WoW.flushTimers()
local wmWire = WoW.sentMessages()
AltStableDB = {}
for _, m in ipairs(wmWire) do receive(m, "Wmpeer-Realm") end
eq(AltStableConfig.peerWatermarks["Wmpeer"], 1200, "watermark advances to the newest received lastUpdate")

------------------------------------------------------------
-- #20 bug 1: a fast third-party clock cannot drag the watermark forward
--
-- A peer relays records it received from others, stamped by THEIR clocks. One
-- from a machine an hour fast used to push our watermark an hour past the
-- peer's own clock, so the peer's own changes were silently filtered out.
------------------------------------------------------------

WoW.reset(); WoW.now = 100000
AltStableConfig = { peerWatermarks = {} }
AltStableDB = {
    ["Player-Relay-1"] = { guid = "Player-Relay-1", name = "Relayed", class = "MAGE",
                           ilvl = 1, lastUpdate = 100000 + 3600 },
    ["Player-Peer-1"]  = { guid = "Player-Peer-1", name = "Theirs", class = "MAGE",
                           ilvl = 1, lastUpdate = 99990 },
}
T.SendFullDatabase("WHISPER", "x")
WoW.flushTimers()
local fastWire = WoW.sentMessages()
AltStableDB = {}
for _, m in ipairs(fastWire) do receive(m, "Fastpeer-Realm") end
local fwm = AltStableConfig.peerWatermarks["Fastpeer"]
check(fwm and fwm <= 100000, "a future-dated relayed record cannot push the watermark past our clock (got " .. tostring(fwm) .. ")")
check(fwm and fwm <= 99990, "  and it stays below the peer's own recent change, so that is re-requested")
eq(T.WatermarkCeiling(100000), 99700, "the ceiling sits a few minutes below the given clock")

-- The case the first fix missed: OUR clock ahead of the peer's. The peer
-- relays one of our own characters, stamped by our fast clock. Capping at our
-- clock put the watermark ~55 minutes past the peer's; the replier's own
-- SEND_TIME caps it in the peer's frame.
WoW.reset(); WoW.now = 100000          -- the peer sends at ITS time
AltStableConfig = { peerWatermarks = {} }
AltStableDB = { ["Player-Ours-1"] = { guid = "Player-Ours-1", name = "Ours", class = "MAGE",
                                      ilvl = 1, lastUpdate = 103590 } }
T.SendFullDatabase("WHISPER", "x")
flushAll()
local skewWire = WoW.sentMessages()
WoW.now = 103600                       -- we receive, an hour ahead of the peer
AltStableDB = {}
for _, m in ipairs(skewWire) do receive(m, "Skew Surname") end
local swm = AltStableConfig.peerWatermarks["Skew Surname"]
check(swm and swm <= 100000 - 300, "our fast clock cannot drag the watermark past the peer's (got " .. tostring(swm) .. ")")

-- Mixed versions: a v8 peer from before the trailer is still accepted, but
-- sends no clock. Guessing it from ours rebuilt bug 1 - Codex's repro stored
-- 103300. Such a peer gets no watermark at all, so it is asked for everything.
WoW.reset(); WoW.now = 100000           -- the OLD peer sends, at its time
AltStableConfig = { peerWatermarks = { ["Old Surname"] = 90000 } }
AltStableDB = { ["Player-OldRelay-1"] = { guid = "Player-OldRelay-1", name = "Ours", class = "MAGE",
                                          ilvl = 1, lastUpdate = 103590 } }
T.ChunkAndSendPayload(T.SerializeFullDB(false, 0), "WHISPER", "x")   -- no trailer: pre-fix sender
flushAll()
local oldWire = WoW.sentMessages()
WoW.now = 103600                        -- we receive, an hour ahead
AltStableDB = {}
for _, m in ipairs(oldWire) do receive(m, "Old Surname") end
eq(AltStableConfig.peerWatermarks["Old Surname"], nil,
   "a peer that sends no clock gets no watermark, rather than one guessed from ours")
eq(T.GetPeerWatermark("Old Surname"), 0, "  so its next REQ asks for everything")

-- The replier's time rides after the last separator, where older parsers never look.
WoW.reset(); WoW.now = 100000
AltStableDB = { ["Player-Trail-1"] = { guid = "Player-Trail-1", name = "T", class = "MAGE", ilvl = 1, lastUpdate = 1 } }
local _, trailerNow = T.DeserializeFullDB(T.SerializeFullDB(false) .. "\n==NOW==:100000", "Peer")
eq(trailerNow, 100000, "the sender's clock is read from the payload's last line")

-- A watermark already in the future is pulled back, not only ratcheted up.
WoW.reset(); WoW.now = 100000
AltStableConfig = { peerWatermarks = { ["Poison Surname"] = 103600 } }
check(T.GetPeerWatermark("Poison Surname") <= 99700, "a future watermark is never sent in a REQ")
AltStableDB = { ["Player-Pull-1"] = { guid = "Player-Pull-1", name = "P", class = "MAGE", ilvl = 1, lastUpdate = 99000 } }
T.SendFullDatabase("WHISPER", "x"); flushAll()
local pullWire = WoW.sentMessages()
AltStableDB = {}
for _, m in ipairs(pullWire) do receive(m, "Poison Surname") end
check(AltStableConfig.peerWatermarks["Poison Surname"] <= 99700, "a completed stream pulls a future watermark back")

------------------------------------------------------------
-- #20 bug 3: every REQ goes through ChatThrottleLib at ALERT, never raw
------------------------------------------------------------

WoW.reset()
T.RequestCharacters("WHISPER", "Alertpeer", true)
local areq = WoW.sent[#WoW.sent]
check(areq and isReq(areq.text), "a REQ was sent")
eq(areq and areq.prio, "ALERT", "the REQ is paced by ChatThrottleLib at ALERT priority")

WoW.reset()
T.RequestResync("Retrypeer", "test.")
WoW.flushTimers()
local rreq
for _, s in ipairs(WoW.sent) do if isReq(s.text) then rreq = s end end
eq(rreq and rreq.prio, "ALERT", "a resync REQ is paced at ALERT too")

-- ChatThrottleLib raises on an oversize message; QueueWire's fallback must
-- still send it, raw, and the recorded priority must not leak onto it.
WoW.reset()
T.QueueWire(string.rep("x", 300), "WHISPER", "Big Surname")
local big = WoW.sent[#WoW.sent]
check(big and #big.text == 300, "a message ChatThrottleLib refuses still goes out, raw")
eq(big and big.prio, nil, "  with no priority recorded, so it is distinguishable from a paced send")

------------------------------------------------------------
-- #20 bug 4: after a scope change, each peer's next REQ is answered in full
--
-- Watermarks belong to the requester. The first fix reset OUR watermarks, which
-- did nothing for the peer still filtering out our newly eligible characters -
-- and its test only checked that a table emptied, so it passed while the bug
-- stayed open. This one decodes the actual reply.
------------------------------------------------------------

local function decodeReply(wire)
    local saved = AltStableDB
    AltStableDB = {}
    for _, m in ipairs(wire) do receive(m, "Decoder Surname") end
    local got = AltStableDB
    AltStableDB = saved
    return got
end

WoW.reset(); WoW.now = 100000
AltStableConfig = { peerWatermarks = {}, sendAllAccounts = false, accountNumber = "1" }
AltStableDB = {
    ["Player-Late-1"] = { guid = "Player-Late-1", name = "Late", class = "MAGE", ilvl = 1,
                          lastUpdate = 500, account = "2" },   -- another account, stamped long ago
}
local function askWithWatermark(wm)
    WoW.sent = {}
    receive(T.MSG_REQUEST_V .. "|" .. wm, "Asker Surname")
    flushAll()
    return decodeReply(WoW.sentMessages())
end

check(askWithWatermark(900)["Player-Late-1"] == nil, "before the change, the other account's character is not sent")
AltStableConfig.peerWatermarks["Keeper Surname"] = 777
AltStable.SetConfigValue("sendAllAccounts", true)
check(askWithWatermark(900)["Player-Late-1"] ~= nil,
      "after enabling send-all-accounts, the peer's next REQ is answered in full despite its watermark")
check(askWithWatermark(900)["Player-Late-1"] == nil, "  and the one after that honours its watermark again")
eq(AltStableConfig.peerWatermarks["Keeper Surname"], 777, "our own watermarks are not reset - they were never the problem")

-- A relaunch must not forget it. Change scope, then simulate a new session:
-- Core's module state is rebuilt, AltStableConfig survives (as it will once
-- SavedVariables load). The peer that has not asked yet still gets a full reply.
AltStableConfig.peerScopeGeneration = {}
AltStableConfig.sendAllAccounts = false
AltStable.SetConfigValue("sendAllAccounts", true)
T.ResetSyncState()
check(askWithWatermark(900)["Player-Late-1"] ~= nil,
      "a scope change made before a relaunch is still honoured afterwards")

-- ResetPeerWatermarks: it must CLEAR, and it must survive a config that has
-- not loaded yet.
--
-- The clearing half is the one that matters and the one nothing asserted. It
-- exists for /alts cleanup, which wipes the database down to the current
-- character and then resets watermarks precisely so the follow-up
-- BroadcastRequest pulls a FULL database back. A reset that quietly kept the
-- old stamps leaves every peer answering with a delta above them, and the
-- wiped characters never return - the exact regression the function prevents.
-- A no-op version passed the whole suite.
do
    AltStableConfig = AltStableConfig or {}
    AltStableConfig.peerWatermarks = { ["Someone Surname"] = 4242 }
    AltStable.ResetPeerWatermarks()
    eq(next(AltStableConfig.peerWatermarks or {}), nil,
       "resetting watermarks actually empties them")
end

-- And the nil-config half. Plugin bootstrap reaches it: Core.lua is listed
-- before Config.lua in the TOC, so Core's PLAYER_LOGIN handler loads the
-- plugins before Config's EnsureDefaults runs, and the Warband plugin calls
-- this from its bootstrap. Its two siblings, GetPeerWatermark and
-- AdvancePeerWatermark, both open with `AltStableConfig = AltStableConfig or
-- {}`; this one goes through SetConfigValue, which guards the same way.
do
    local saved = AltStableConfig
    AltStableConfig = nil
    local ok, err = pcall(AltStable.ResetPeerWatermarks)
    check(ok, "resetting watermarks before the config loads does not error: " .. tostring(err))
    check(type(AltStableConfig) == "table",
          "  and it leaves a config behind rather than nothing")
    check(type(AltStableConfig and AltStableConfig.peerWatermarks) == "table",
          "  with a watermark table for the next writer to use")
    AltStableConfig = saved
end

local epoch = T.SyncScopeEpoch()
AltStableConfig.accountNumber = "1"
AltStable.SetConfigValue("accountNumber", 1)
eq(T.SyncScopeEpoch(), epoch, "re-entering the same account number as a number is not a scope change")
AltStable.SetConfigValue("theme", "dark")
eq(T.SyncScopeEpoch(), epoch, "an unrelated setting is not a scope change")

------------------------------------------------------------
-- 27. Delta sync: a REQ carries our watermark for that peer
------------------------------------------------------------

WoW.reset()
AltStableConfig = { peerWatermarks = { Zephyr = 4242 } }
WoW.sent = {}
T.RequestCharacters("WHISPER", "Zephyr-Realm", true)
local reqMsg = nil
for _, sdata in ipairs(WoW.sent) do
    if isReq(sdata.text) then reqMsg = sdata.text end
end
eq(reqMsg, T.MSG_REQUEST_V .. "|4242", "REQ carries our delta watermark for the peer")
eq(T.GetPeerWatermark("Zephyr-Realm"), 4242, "GetPeerWatermark resolves by realm-less short name")

------------------------------------------------------------
-- 28. Compression shrinks the wire vs the raw payload (P0)
------------------------------------------------------------

WoW.reset()
seedDB("Player-Zip-", 20)   -- 20 similar characters => highly compressible
local raw = T.SerializeFullDB(false)
T.ChunkAndSendPayload(raw, "WHISPER", "Zip")
WoW.flushTimers()
local wireBytes = 0
for _, m in ipairs(WoW.sentMessages()) do wireBytes = wireBytes + #m end
check(wireBytes < #raw, "compressed wire (" .. wireBytes .. "B incl. headers) is smaller than the raw payload (" .. #raw .. "B)")

------------------------------------------------------------
-- 29. Delta boundary: a character whose lastUpdate EQUALS the watermark is
--     still sent (>= not >), so a same-second-after-sync change isn't lost.
------------------------------------------------------------

WoW.reset()
AltStableConfig = { peerWatermarks = {} }
AltStableDB = {
    ["Player-B-eq"] = { guid = "Player-B-eq", name = "Eq", class = "MAGE",  ilvl = 100, lastUpdate = 600 },
    ["Player-B-lo"] = { guid = "Player-B-lo", name = "Lo", class = "ROGUE", ilvl = 110, lastUpdate = 500 },
}
local bnd = T.SerializeFullDB(false, 600)
check(bnd:find("Player-B-eq", 1, true), "delta includes a character whose lastUpdate == the watermark (same-second fix)")
check(not bnd:find("Player-B-lo", 1, true), "delta still excludes a character older than the watermark")

------------------------------------------------------------
-- 30. Every wire message stays within the 255-byte addon-channel cap
--     (guards the MAX_CHUNK vs header-size budget).
------------------------------------------------------------

WoW.reset()
seedBig("Player-Len-", 8)   -- high-entropy => multi-chunk, near-full chunks
T.ChunkAndSendPayload(T.SerializeFullDB(false), "WHISPER", "Len")
WoW.flushTimers()
local oversize = nil
for _, m in ipairs(WoW.sentMessages()) do if #m > 255 then oversize = #m end end
check(oversize == nil, "every wire message stays within the 255-byte addon-channel cap")

------------------------------------------------------------
-- 31. Sync-watch: the user always gets closure after a request.
------------------------------------------------------------

-- 31a: an unanswered peer we CAN'T confirm online (not in guild/friends) stays
-- silent — the common case for your own alts on another account. We auto-re-request
-- when they come online, so a timeout for an unreachable peer is just noise.
WoW.reset(); WoW.now = 1000
T.WatchSyncPeer("Ghost-Realm")
WoW.now = 1100                 -- advance past the 45s stall deadline
WoW.flushTimers()
check(not chatHas("No sync response"), "sync-watch: an unreachable/unknown peer is NOT warned about")

-- 31a2: an unanswered peer we CAN confirm online (in the guild roster, online) IS
-- reported — worth flagging, since they should have replied.
WoW.reset(); WoW.now = 1000
-- Saved and restored, not nil'd afterwards: this stub file defines IsInGuild,
-- and deleting it left later sections calling a nil global.
local stubIsInGuild, stubNumGuild, stubRosterInfo = IsInGuild, GetNumGuildMembers, GetGuildRosterInfo
IsInGuild          = function() return true end
GetNumGuildMembers = function() return 1 end
GetGuildRosterInfo = function(i) if i == 1 then return "Ghost-Realm", nil, nil, nil, nil, nil, nil, nil, true end end
T.WatchSyncPeer("Ghost-Realm")
WoW.now = 1100
WoW.flushTimers()
check(chatHas("No sync response from Ghost-Realm"), "sync-watch: an online peer that doesn't reply IS reported")
IsInGuild, GetNumGuildMembers, GetGuildRosterInfo = stubIsInGuild, stubNumGuild, stubRosterInfo

-- 31b: a completed stream clears the watch, so no stall/no-response line fires.
-- The peer is confirmed ONLINE, so the watch would report it if it were still
-- armed (31a2 is the control). The ported version used a peer the watch ignores
-- anyway, and passed with ClearSyncWatch turned into a no-op.
WoW.reset(); WoW.now = 1000
IsInGuild          = function() return true end
GetNumGuildMembers = function() return 1 end
GetGuildRosterInfo = function(i) if i == 1 then return "Done-Realm", nil, nil, nil, nil, nil, nil, nil, true end end
T.WatchSyncPeer("Done-Realm")
T.ClearSyncWatch("Done-Realm")  -- CompleteStream calls this on a finished stream
WoW.now = 1100
WoW.flushTimers()
check(not chatHas("No sync response") and not chatHas("stalled"), "sync-watch: a completed sync fires no stall/no-response line")
IsInGuild, GetNumGuildMembers, GetGuildRosterInfo = stubIsInGuild, stubNumGuild, stubRosterInfo

-- 31c: partial data that never completes is reported as stalled (not "no response").
WoW.reset(); WoW.now = 1000
T.WatchSyncPeer("Slow-Realm")
T.NoteSyncActivity("Slow-Realm")  -- a chunk arrived: deadline pushed, sawData=true
WoW.now = 1100
WoW.flushTimers()
check(chatHas("stalled"), "sync-watch: partial data with no completion is reported as stalled")

------------------------------------------------------------
-- 32. Saved raid lockouts: ScanSavedInstances writes syncable si_ fields
------------------------------------------------------------
WoW.reset(); WoW.now = 100000
local sguid = UnitGUID("player")   -- the stub player's GUID (WoW.player.guid)
AltStableDB = { [sguid] = { guid = sguid, name = "Raider", lastUpdate = 0 } }
AltStableConfig = { peerWatermarks = {} }

local savedList = {}
local stubNumSaved, stubSavedInfo = GetNumSavedInstances, GetSavedInstanceInfo
_G.GetNumSavedInstances = function() return #savedList end
_G.GetSavedInstanceInfo = function(i)
    local e = savedList[i]
    if not e then return end
    -- name, id, reset, difficulty, locked, extended, idMostSig, isRaid,
    -- maxPlayers, difficultyName, numEncounters, encounterProgress
    return e.name, 1, e.reset, e.diff or 1, e.locked ~= false, false, 0,
           e.isRaid ~= false, e.maxP or 10, "Normal", e.total or 0, e.prog or 0
end

savedList = {
    { name = "Karazhan",       reset = 3600, prog = 7, total = 11, maxP = 10, isRaid = true },
    { name = "Gruul's Lair",   reset = 7200, prog = 2, total = 2,  maxP = 25, isRaid = true },
    { name = "Shattered Halls", reset = 3600, isRaid = false, maxP = 5 },   -- 5-man, must be ignored
}
T.ScanSavedInstances()
local srec = AltStableDB[sguid]
eq(srec["si_Karazhan@1"], "103560|7|11|10|Normal", "raid lockout stored as packed si_<name>@<diff> (expiry rounded to minute)")
check(srec["si_Gruul's Lair@1"] ~= nil, "a second raid lockout is captured (name with an apostrophe)")
check(srec["si_Shattered Halls@1"] == nil, "a 5-man (non-raid) lockout is ignored")

local siPayload = T.SerializeFullDB(false, 0)
check(siPayload:find("si_Karazhan@1:103560|7|11|10|Normal", 1, true), "si_ lockout serializes into the char record for sync")

-- Reconcile on re-scan: a dropped lockout clears, a progress change updates.
savedList = { { name = "Karazhan", reset = 3600, prog = 8, total = 11, maxP = 10, isRaid = true } }
T.ScanSavedInstances()
check(AltStableDB[sguid]["si_Gruul's Lair@1"] == nil, "a lockout no longer saved is cleared on re-scan")
eq(AltStableDB[sguid]["si_Karazhan@1"], "103560|8|11|10|Normal", "boss-progress change is captured (7/11 -> 8/11)")
-- Restored: left installed, these quietly re-enabled the lockout scan in every later section.
GetNumSavedInstances, GetSavedInstanceInfo = stubNumSaved, stubSavedInfo

------------------------------------------------------------
-- 33. Mail with expiry: ScanMail writes syncable mail_ fields
------------------------------------------------------------
WoW.reset(); WoW.now = 100000
local mguid = UnitGUID("player")   -- the stub player's GUID (WoW.player.guid)
AltStableDB = { [mguid] = { guid = mguid, name = "Mailer", lastUpdate = 0 } }
AltStableConfig = { peerWatermarks = {} }

local inbox = {}
local stubInboxNum, stubInboxHeader = GetInboxNumItems, GetInboxHeaderInfo
_G.GetInboxNumItems = function() return #inbox end
_G.GetInboxHeaderInfo = function(i)
    local e = inbox[i]
    if not e then return end
    -- packageIcon, stationeryIcon, sender, subject, money, CODAmount, daysLeft, itemCount
    return nil, nil, "Sender", "Subj", e.money or 0, 0, e.daysLeft, e.itemCount or 0
end

inbox = {
    { daysLeft = 3,  itemCount = 2, money = 0 },      -- items, ~3 days: this is the soonest
    { daysLeft = 10, itemCount = 0, money = 5000 },   -- gold only: still "has stuff"
    { daysLeft = 5,  itemCount = 0, money = 0 },       -- plain letter, nothing to lose: ignored
}
T.ScanMail()
local mrec = AltStableDB[mguid]
eq(mrec.mail_count, 2, "mail: only mails with items or money are counted (plain letter ignored)")
eq(mrec.mail_expiry, math.floor((100000 + 3 * 86400) / 60) * 60, "mail: soonest expiry stored absolute, rounded to the minute")
eq(mrec.mail_money, 5000, "mail: total attached money summed")

local mPayload = T.SerializeFullDB(false, 0)
check(mPayload:find("mail_expiry:" .. tostring(mrec.mail_expiry), 1, true), "mail_ summary serializes into the char record for sync")

-- Reconcile: an emptied mailbox clears the mail_ fields.
inbox = {}
T.ScanMail()
check(AltStableDB[mguid].mail_count == nil and AltStableDB[mguid].mail_expiry == nil,
      "mail: emptying the mailbox clears the mail_ summary")
GetInboxNumItems, GetInboxHeaderInfo = stubInboxNum, stubInboxHeader

------------------------------------------------------------
-- 34. Mail alerts: login warning respects window + toggle
------------------------------------------------------------
WoW.reset(); WoW.now = 100000
AltStableDB = {
    ["g-soon"] = { guid = "g-soon", name = "Expiro", class = "MAGE",   mail_expiry = 100000 + 2 * 86400, mail_count = 1 },
    ["g-far"]  = { guid = "g-far",  name = "Patient", class = "PRIEST", mail_expiry = 100000 + 20 * 86400, mail_count = 3 },
    ["g-past"] = { guid = "g-past", name = "Toolate", class = "ROGUE",  mail_expiry = 100000 - 100,          mail_count = 1 },
    ["g-none"] = { guid = "g-none", name = "Empty",   class = "WARLOCK" },
}
AltStableConfig = { mailAlertsEnabled = true }
T.CheckMailAlerts()
check(chatHas("Mail expiring soon"), "mail alerts: header printed when an alt has mail expiring within the window")
check(chatHas("Expiro"), "mail alerts: an alt within the window is listed")
check(not chatHas("Patient"), "mail alerts: an alt outside the window is not listed")
check(not chatHas("Toolate"), "mail alerts: already-expired mail is not listed")

-- Same clock as above, so the only difference is the toggle. Without the pin,
-- every seeded expiry fell outside the window and this passed with the toggle
-- check deleted.
WoW.reset(); WoW.now = 100000
AltStableConfig = { mailAlertsEnabled = false }
T.CheckMailAlerts()
check(not chatHas("Mail expiring soon"), "mail alerts: disabling the toggle suppresses the warning")

------------------------------------------------------------
-- GET_ITEM_INFO_RECEIVED must reach the Roster audit's pending gems
--
-- The handler used to bail on `not AltStable.PendingGearSlots`, a queue that
-- only ever holds LOCAL equipment slots and is nil whenever nothing local is
-- waiting. Audit gem lookups never enter it, so a finding suppressed by a cache
-- miss stayed invisible and the tab kept reading "No issues found".
------------------------------------------------------------

local refreshes = 0
local prevRefresh = AltStable.RefreshSheet
AltStable.RefreshSheet = function() refreshes = refreshes + 1 end

AltStable.PendingGearSlots  = nil          -- the case that used to return early
AltStable.PendingAuditItems = { [88888] = true }

onEvent(T.frame, "GET_ITEM_INFO_RECEIVED", 88888, true)
eq(refreshes, 1, "a resolved audit gem repaints even with no local gear pending")
eq(AltStable.PendingAuditItems[88888], nil, "the resolved gem leaves the pending queue")

-- Unrelated items must not repaint: the queue is the whole point of the filter.
onEvent(T.frame, "GET_ITEM_INFO_RECEIVED", 77777, true)
eq(refreshes, 1, "an item nobody is waiting on triggers no repaint")

-- A failed lookup is not a resolution; the gem stays queued for a later event.
AltStable.PendingAuditItems = { [88888] = true }
onEvent(T.frame, "GET_ITEM_INFO_RECEIVED", 88888, false)
eq(refreshes, 1, "a failed cache event does not repaint")
check(AltStable.PendingAuditItems[88888], "a failed cache event leaves the gem queued")

AltStable.RefreshSheet = prevRefresh
AltStable.PendingAuditItems = nil

------------------------------------------------------------
-- Summary
------------------------------------------------------------

------------------------------------------------------------
-- A secret value never reaches the wire
------------------------------------------------------------
-- tostring on one throws, so a single secret field would take the whole sync
-- with it. The scanner keeps them out of the database; this is the boundary
-- refusing one that arrived some other way.
WoW.reset()
local secretRec = { guid = "Player-Secret-1", name = "Secretive", class = "WARLOCK",
                    level = 7, lastUpdate = 1, stat_str = WoW.secret(10), stat_hp = 163 }
local okSer, secretWire = pcall(T.SerializeChar, secretRec)
check(okSer, "serializing a record holding a secret does not throw: " .. tostring(secretWire))
if okSer then
    check(not secretWire:find("stat_str"), "  the secret field is left out")
    check(secretWire:find("stat_hp:163", 1, true) ~= nil, "  and the plain fields still go")
end

-- On a build with no issecretvalue, the fallback is arithmetic - and "Thrall"
-- + 0 throws. Calling that secret dropped every name, class and realm from the
-- wire, guid included, so the record arrived unparseable: sync as a silent
-- no-op. The identity fields must survive the fallback.
do
    local realPredicate = issecretvalue
    issecretvalue = nil
    dofile("Compat.lua")
    local rec = { guid = "Player-Str-1", name = "Thrall", class = "SHAMAN",
                  realm = "Classic Beta PvP", level = 7, money = 1234, lastUpdate = 1 }
    local wire = T.SerializeChar(rec)
    for _, field in ipairs({ "guid:Player-Str-1", "name:Thrall", "class:SHAMAN",
                             "realm:Classic Beta PvP", "level:7", "money:1234" }) do
        check(wire:find(field, 1, true) ~= nil, "without the predicate, " .. field .. " still syncs")
    end
    local back = T.DeserializeChar(wire)
    check(back ~= nil and back.guid == "Player-Str-1", "  and the record parses at the other end")
    issecretvalue = realPredicate
    dofile("Compat.lua")
end

-- A value that became UNREADABLE has to propagate. It is stored as nil and
-- omitted from the wire, so a merge that applies "only the keys present" keeps
-- the last number it saw and goes on summing it as current.
WoW.reset()
AltStableDB = { ["Player-Was-1"] = { guid = "Player-Was-1", name = "Rich", class = "ROGUE",
                                      level = 60, money = 12345, stat_str = 50,
                                      stat_hp = 3000, lastUpdate = 100 } }
T.DeserializeFullDB(T.SerializeChar(
    -- The same character, rescanned where money and the stats are unreadable:
    -- the fields are simply absent.
    { guid = "Player-Was-1", name = "Rich", class = "ROGUE", level = 60, lastUpdate = 200 }
) .. "\n" .. T.CHAR_SEP, "Peer")
local was = AltStableDB["Player-Was-1"]
eq(was.lastUpdate, 200, "the newer record is accepted")
eq(was.money, nil, "  money that went unreadable is cleared, not left showing as current")
eq(was.stat_str, nil, "  and so is a stat")
eq(was.stat_hp, nil, "  every stat, not just the one")
eq(was.name, "Rich", "  while identity is untouched")

-- ...and a record that still HAS the values restores them.
T.DeserializeFullDB(T.SerializeChar(
    { guid = "Player-Was-1", name = "Rich", class = "ROGUE", level = 60,
      money = 999, stat_str = 51, lastUpdate = 300 }
) .. "\n" .. T.CHAR_SEP, "Peer")
eq(AltStableDB["Player-Was-1"].money, 999, "a readable amount arrives normally")
eq(AltStableDB["Player-Was-1"].stat_str, 51, "  and so do the stats")

------------------------------------------------------------
-- Secret values in the live event handlers
------------------------------------------------------------
-- PLAYER_MONEY and the XP events fire constantly during play, so a secret read
-- there errors on every loot and every XP tick - and PLAYER_MONEY refreshes the
-- sheet, which sums money across characters.
WoW.reset()
local liveGuid = UnitGUID("player")
AltStableDB = { [liveGuid] = { guid = liveGuid, name = "Live", class = "MAGE", money = 500,
                               restPercent = 40, restTimestamp = WoW.now, lastUpdate = 1 } }
local realMoney = GetMoney
GetMoney = function() return WoW.secret(99) end
local okMoney = pcall(onEvent, T.frame, "PLAYER_MONEY")
check(okMoney, "a secret from GetMoney does not throw on PLAYER_MONEY")
eq(AltStableDB[liveGuid].money, 500, "  and the known amount is kept, not replaced by a secret")
GetMoney = function() return 750 end
onEvent(T.frame, "PLAYER_MONEY")
eq(AltStableDB[liveGuid].money, 750, "  a readable amount still updates")
GetMoney = realMoney

local realExh = GetXPExhaustion
GetXPExhaustion = function() return WoW.secret(120) end
WoW.xpMax, WoW.level = 400, 20
local okXP = pcall(onEvent, T.frame, "PLAYER_XP_UPDATE")
check(okXP, "a secret from GetXPExhaustion does not throw on an XP tick")
eq(AltStableDB[liveGuid].restPercent, 40, "  and the stored rested % is kept")
GetXPExhaustion = realExh
WoW.reset()

------------------------------------------------------------
-- Retired fields (#8)
------------------------------------------------------------
-- Nothing reads them any more. Stored records still hold them, so they must
-- not be sent, must be dropped if an older peer sends them, and are purged
-- from the database at login. Every key in the real list is checked.
WoW.reset()
local function oldRecord()
    -- A pre-upgrade record: what the old scanner wrote, rating-derived stats included.
    local r = { guid = "Player-Ret-1", name = "Old", level = 20, lastUpdate = 1,
                prof_Tailoring = 80, stat_str = 40 }
    for k in pairs(T.RETIRED_FIELDS) do r[k] = 7 end
    return r
end
local retiredCount = 0
for _ in pairs(T.RETIRED_FIELDS) do retiredCount = retiredCount + 1 end
check(retiredCount >= 8, "the retired list is exposed and populated")
for _, k in ipairs({ "stat_crit", "stat_hitpct", "stat_haste", "stat_resilience",
                     "prof_Jewelcrafting", "profmax_Jewelcrafting", "spec", "specIcon" }) do
    check(T.RETIRED_FIELDS[k], k .. " is retired")
end
-- The TBC reputation slugs (#8): standings are rep_<factionID> now.
for _, k in ipairs({ "aldor", "scryer", "thrallmar", "honorhold", "violeteye", "shatteredsun" }) do
    check(T.RETIRED_FIELDS[k], "TBC reputation field " .. k .. " is retired")
end

local wire = T.SerializeChar(oldRecord())
local wireLines = {}
for line in (wire .. "\n"):gmatch("([^\n]*)\n") do wireLines[#wireLines + 1] = line end
for k in pairs(T.RETIRED_FIELDS) do
    local sent = false
    for _, line in ipairs(wireLines) do
        if line:sub(1, #k + 1) == k .. ":" then sent = true end
    end
    check(not sent, "retired field " .. k .. " is never sent")
end
check(wire:find("prof_Tailoring:80", 1, true) ~= nil, "  a live profession still is")
check(wire:find("stat_str:40", 1, true) ~= nil, "  and a live stat still is")

local incoming = { "guid:Player-Ret-1", "level:20" }
for k in pairs(T.RETIRED_FIELDS) do incoming[#incoming + 1] = k .. ":7" end
local got = T.DeserializeChar(table.concat(incoming, "\n"))
for k in pairs(T.RETIRED_FIELDS) do
    eq(got and got[k], nil, "retired field " .. k .. " from an older peer is dropped")
end
eq(got and got.level, 20, "  the rest of the record is kept")

-- The purge runs at PLAYER_LOGIN - through the real handler, not just the
-- function. The rest of login needs more client than the stubs model, so it
-- runs under pcall; the purge comes first and is what is checked.
local stored = oldRecord()
AltStableDB = { ["Player-Ret-1"] = stored }
pcall(onEvent, T.frame, "PLAYER_LOGIN")
for k in pairs(T.RETIRED_FIELDS) do
    eq(stored[k], nil, "login purges stored " .. k)
end
eq(stored.prof_Tailoring, 80, "  and leaves the rest")
eq(stored.stat_str, 40, "  including the live stats")
WoW.reset()

------------------------------------------------------------
-- Live rested-XP updates (#6)
------------------------------------------------------------
-- UnitXPMax can be 0 (Retail returns 0 at the cap); `or 1` never caught it.
-- Below the cap that is a bad read: the last snapshot stands, rather than a
-- 1-XP level making it 10000%.
WoW.reset()
local xpGuid = UnitGUID("player")
AltStableDB = { [xpGuid] = { guid = xpGuid, restPercent = 40, xpMax = 400, restTimestamp = 0 } }
WoW.level, WoW.xpMax, WoW.restXP = 59, 0, 100
onEvent(T.frame, "PLAYER_XP_UPDATE")
eq(AltStableDB[xpGuid].restPercent, 40, "below the cap, a zero maximum keeps the last rested %")
eq(AltStableDB[xpGuid].xpMax, 400, "  and the last maximum")
eq(AltStableDB[xpGuid].restTimestamp, 0, "  and the snapshot time")
WoW.level = 60
onEvent(T.frame, "PLAYER_XP_UPDATE")
eq(AltStableDB[xpGuid].restPercent, 0, "at the cap, a zero maximum means no rested XP")

-- The transient-zero guard applies below the cap only. At 60 - the cap here -
-- a zero is real, not a loading-screen read, and must be stored.
WoW.reset()
AltStableDB = { [xpGuid] = { guid = xpGuid, restPercent = 40, restTimestamp = WoW.now } }
WoW.level, WoW.xpMax, WoW.restXP = 60, 0, 0
onEvent(T.frame, "PLAYER_XP_UPDATE")
eq(AltStableDB[xpGuid].restPercent, 0, "at the level cap a zero rested read is stored, not held back")
WoW.level = 59
AltStableDB = { [xpGuid] = { guid = xpGuid, restPercent = 40, restTimestamp = WoW.now } }
WoW.xpMax = 400
onEvent(T.frame, "PLAYER_XP_UPDATE")
eq(AltStableDB[xpGuid].restPercent, 40, "  below it, a sudden zero is still treated as transient")

------------------------------------------------------------
-- Forgetting a character that no longer exists (#65)
------------------------------------------------------------
-- Deleting the record is the easy half and not the useful one: a peer still
-- holds it and re-sends it on the next sync, so without a tombstone the
-- character is back within seconds. Through 1.60.1.69977 this never came up
-- because nothing survived a restart (#23); now records persist and only
-- accumulate.

do
    WoW.reset()
    AltStableConfig = { peerWatermarks = {} }
    AltStableDB = {
        ["Player-Gone-1"] = { guid = "Player-Gone-1", name = "Ghost", class = "PRIEST",
                              level = 12, lastUpdate = 1000 },
        ["Player-Here-1"] = { guid = "Player-Here-1", name = "Present", class = "MAGE",
                              level = 60, lastUpdate = 1000 },
    }

    local ok, name = AltStable.ForgetCharacter("Player-Gone-1")
    check(ok, "forgetting a character reports success")
    eq(name, "Ghost", "  and gives back the name, for the message")
    eq(AltStableDB["Player-Gone-1"], nil, "  the record is gone")
    check(AltStableDB["Player-Here-1"] ~= nil, "  and nobody else is touched")
    check(AltStable.IsCharacterForgotten("Player-Gone-1"), "  a tombstone is left")

    local missing, why = AltStable.ForgetCharacter("Player-Nope-9")
    eq(missing, false, "forgetting a character we do not have fails")
    check(type(why) == "string" and why ~= "", "  with something to print")

    -- Not the one you are standing on. The next scan rewrites the record
    -- seconds later, so it would look broken rather than destructive - and the
    -- tombstone would then be fighting our own scanner.
    local me = WoW.player.guid
    AltStableDB[me] = { guid = me, name = "Myself", class = "DRUID", level = 20,
                        lastUpdate = 1000, scannedHere = true }
    local refused, reason = AltStable.ForgetCharacter(me)
    eq(refused, false, "the character you are playing cannot be forgotten")
    check(type(reason) == "string" and reason:find("playing", 1, true) ~= nil,
          "  and the reason says why: " .. tostring(reason))
    check(AltStableDB[me] ~= nil, "  the record is still there")
    check(not AltStable.IsCharacterForgotten(me), "  and no tombstone was left for it")
end

do
    -- The half that matters: the peer sends it back and we do not take it.
    WoW.reset()
    AltStableConfig = { peerWatermarks = {}, forgottenCharacters = {} }
    AltStableDB = {}
    AltStable.MarkCharacterForgotten("Player-Gone-1", 1000, "Ghost")

    local blob = T.SerializeChar({ guid = "Player-Gone-1", name = "Ghost", class = "PRIEST",
                                   level = 12, lastUpdate = 2000 })
    T.DeserializeFullDB(blob .. "\n" .. T.CHAR_SEP, "Peer Surname")
    eq(AltStableDB["Player-Gone-1"], nil,
       "a forgotten character offered back by a peer is not taken")

    -- And the tombstone's clock moves, because a peer is still offering it.
    local after = AltStable.ForgottenList()[1]
    check(after and (after.lastOffered or 0) > 1000,
          "  and the tombstone is refreshed, so it cannot expire while they still send it")
    eq(after and after.name, "Ghost", "  keeping the name we knew it by")

    -- An unrelated character still arrives.
    local other = T.SerializeChar({ guid = "Player-Fine-1", name = "Fine", class = "MAGE",
                                    level = 60, lastUpdate = 2000 })
    T.DeserializeFullDB(other .. "\n" .. T.CHAR_SEP, "Peer Surname")
    check(AltStableDB["Player-Fine-1"] ~= nil, "anyone else still syncs normally")
end

do
    -- Undo, by name, because the record is gone and the player has only a name.
    WoW.reset()
    AltStableConfig = { peerWatermarks = {}, forgottenCharacters = {} }
    AltStable.MarkCharacterForgotten("Player-Gone-2", 1000, "Ghost Surname")

    local guid, held = AltStable.ForgottenGuidFor("ghost surname")
    eq(guid, "Player-Gone-2", "a forgotten character is findable by name")
    eq(held, "Ghost Surname", "  with the name as it was")
    eq(AltStable.ForgottenGuidFor("Ghost"), "Player-Gone-2",
       "  and by first name alone, like everywhere else")
    eq(AltStable.ForgottenGuidFor("Nobody"), nil, "  and not by a name we never had")

    -- Two tombstones can hold the same name, and the records they came from are
    -- gone - so there is no realm left to tell them apart. Returning the first
    -- match let /alts unforget lift an arbitrary one, letting that character
    -- back while the one the player meant stayed suppressed.
    AltStable.MarkCharacterForgotten("Player-Dup-A", 1000, "Twin Surname")
    AltStable.MarkCharacterForgotten("Player-Dup-B", 1000, "Twin Surname")
    local dup, why = AltStable.ForgottenGuidFor("Twin Surname")
    eq(dup, nil, "two tombstones with one name resolve to nobody")
    check(why and why:find("Player-Dup-A", 1, true) and why:find("Player-Dup-B", 1, true),
          "  and the message offers the GUIDs, since nothing else distinguishes them: "
          .. tostring(why))
    for _ = 1, 20 do
        eq(AltStable.ForgottenGuidFor("Twin Surname"), nil, "  every time, not by luck")
    end
    eq(AltStable.ForgottenGuidFor("Twin"), nil, "the shared first name is ambiguous too")

    -- The GUID is the way out.
    eq(AltStable.ForgottenGuidFor("Player-Dup-A"), "Player-Dup-A",
       "a GUID resolves to itself, which is the selector the message offers")
    AltStable.UnforgetCharacter("Player-Dup-A")
    eq(AltStable.ForgottenGuidFor("Twin Surname"), "Player-Dup-B",
       "  and with one lifted the other is unambiguous again")
    AltStable.UnforgetCharacter("Player-Dup-B")

    check(AltStable.UnforgetCharacter("Player-Gone-2"), "unforgetting reports success")
    check(not AltStable.IsCharacterForgotten("Player-Gone-2"), "  and drops the tombstone")
    eq(AltStable.UnforgetCharacter("Player-Gone-2"), false,
       "  doing it twice is not success the second time")
end

do
    -- The list is bounded by COUNT, not by age.
    --
    -- Age was the first design and it was wrong: a dead character's lastUpdate
    -- is frozen, so it never passes a delta's filter and rides only full
    -- replies. In the ordinary login-delta steady state the "last offered"
    -- stamp never moves, the tombstone drops on day 31, and the next full sync
    -- brings the character back. A count cap bounds the list without a clock
    -- that can resurrect somebody.
    WoW.reset()
    AltStableConfig = { forgottenCharacters = {} }
    local cap = AltStable._TOMBSTONE_CAP
    check(type(cap) == "number" and cap > 0, "there is a cap")

    for i = 1, cap + 5 do
        AltStable.MarkCharacterForgotten(("Player-Bulk-%d"):format(i), 1000 + i,
                                         ("Bulk %d"):format(i))
    end
    eq(AltStable.PruneForgotten(), 5, "the overflow is evicted")
    eq(#AltStable.ForgottenList(), cap, "  leaving exactly the cap")
    check(not AltStable.IsCharacterForgotten("Player-Bulk-1"), "  the oldest went")
    check(AltStable.IsCharacterForgotten(("Player-Bulk-%d"):format(cap + 5)),
          "  and the newest stayed")

    eq(AltStable.PruneForgotten(), 0, "a second sweep finds nothing to do")

    -- Age alone must never drop one, however long ago it was forgotten.
    WoW.reset()
    AltStableConfig = { forgottenCharacters = {} }
    AltStable.MarkCharacterForgotten("Player-Ancient-1", 1, "Ancient")
    WoW.now = (WoW.now or 0) + 60 * 60 * 24 * 365
    eq(AltStable.PruneForgotten(), 0, "a year-old tombstone is not swept")
    check(AltStable.IsCharacterForgotten("Player-Ancient-1"),
          "  because expiring it would let the next full sync undo the forget")
end


------------------------------------------------------------
-- Forgetting: the paths the first version missed
------------------------------------------------------------

do
    -- BOTH receive paths. ReceiveCharacter is the single-character path, still
    -- used by the chunked stream and by older peers, and its own header warns
    -- that the two "cannot drift - they had". Checking the tombstone in only
    -- the bulk path drifted them again, and this one put the character back.
    WoW.reset()
    AltStableConfig = { peerWatermarks = {}, forgottenCharacters = {} }
    AltStableDB = {}
    AltStable.MarkCharacterForgotten("Player-Gone-3", 1000, "Ghost")

    T.ReceiveCharacter({ guid = "Player-Gone-3", name = "Ghost", class = "PRIEST",
                         level = 12, lastUpdate = 2000 }, "Peer Surname")
    eq(AltStableDB["Player-Gone-3"], nil,
       "the single-character path refuses a forgotten character too")

    T.ReceiveCharacter({ guid = "Player-Fine-3", name = "Fine", class = "MAGE",
                         level = 60, lastUpdate = 2000 }, "Peer Surname")
    check(AltStableDB["Player-Fine-3"] ~= nil, "  and still takes everyone else")
end

do
    -- Unforgetting has to make the record REACHABLE again, not merely allowed.
    -- Its lastUpdate is frozen at whenever it was last played and every peer's
    -- watermark has long passed it, so without resetting them the character is
    -- never offered and the message promising its return is a lie.
    WoW.reset()
    AltStableConfig = { peerWatermarks = { ["Peer Surname"] = 99999 },
                        forgottenCharacters = {} }
    AltStable.MarkCharacterForgotten("Player-Back-1", 1000, "Returning")

    AltStable.UnforgetCharacter("Player-Back-1")
    check(not AltStable.IsCharacterForgotten("Player-Back-1"), "the tombstone is dropped")
    eq(next(AltStableConfig.peerWatermarks or {}), nil,
       "  and every watermark is reset, so the next reply is a full one")
end

do
    -- Forgetting takes the display preferences with it. The hidden list keeps
    -- orphans on purpose - "the record usually comes back on the next sync" -
    -- but here it never will, so the entry would sit in SavedVariables for good
    -- and an unforget would bring the character back invisible.
    WoW.reset()
    AltStableConfig = { peerWatermarks = {}, forgottenCharacters = {},
                        hiddenCharacters = {}, favouriteCharacters = {} }
    AltStableDB = {
        ["Player-Hid-1"] = { guid = "Player-Hid-1", name = "Hidden One", class = "MAGE",
                             level = 40, lastUpdate = 1000 },
    }
    AltStable.SetCharacterHidden("Player-Hid-1", true)
    check(AltStable.IsCharacterHidden("Player-Hid-1"), "the character starts hidden")

    AltStable.ForgetCharacter("Player-Hid-1")
    check(not AltStable.IsCharacterHidden("Player-Hid-1"),
          "forgetting drops the hidden entry with the record")
end

do
    -- Plugins are actually told, and the bundled one actually listens.
    WoW.reset()
    AltStableConfig = { peerWatermarks = {}, forgottenCharacters = {} }
    AltStableDB = {
        ["Player-Plug-1"] = { guid = "Player-Plug-1", name = "Plugged", class = "MAGE",
                              level = 40, lastUpdate = 1000 },
    }
    local told
    AltStable.plugins = { { id = "spy", OnForget = function(g) told = g end } }
    AltStable.ForgetCharacter("Player-Plug-1")
    eq(told, "Player-Plug-1", "plugins are told which character was forgotten")
    AltStable.plugins = {}
end


------------------------------------------------------------
-- Resolving a character by name, for the slash commands
------------------------------------------------------------
-- The fallback match is on the first name, and this client has four pairs of
-- alts sharing one. Iterating with pairs() picked a different character run to
-- run - silently, for commands that change what the player sees and what gets
-- deleted. Ambiguity is refused rather than guessed.

do
    WoW.reset()
    AltStableDB = {
        ["g-1"] = { guid = "g-1", name = "Karuzo Elegia", class = "MAGE", level = 60 },
        ["g-2"] = { guid = "g-2", name = "Karuzo Maxima", class = "PRIEST", level = 40 },
        ["g-3"] = { guid = "g-3", name = "Solo Surname", class = "ROGUE", level = 20 },
    }

    eq(AltStable.ResolveCharacter("Karuzo Elegia"), "g-1", "a full name resolves exactly")
    eq(AltStable.ResolveCharacter("karuzo elegia"), "g-1", "  whatever the case")
    eq(AltStable.ResolveCharacter("Solo"), "g-3", "an unambiguous first name resolves")
    eq(AltStable.ResolveCharacter("solo surname"), "g-3", "  as does its full name")

    local guid, why = AltStable.ResolveCharacter("Karuzo")
    eq(guid, nil, "an ambiguous first name resolves to nobody")
    check(why and why:find("Karuzo Elegia", 1, true) and why:find("Karuzo Maxima", 1, true),
          "  and names both candidates: " .. tostring(why))

    -- Stable across runs, which is the whole point - pairs() was not.
    for _ = 1, 20 do
        eq(AltStable.ResolveCharacter("Karuzo"), nil, "  every time, not by luck")
    end

    local none, missing = AltStable.ResolveCharacter("Nobody")
    eq(none, nil, "an unknown name resolves to nobody")
    check(missing and missing:find("Nobody", 1, true), "  and says so")
    eq(AltStable.ResolveCharacter(""), nil, "an empty name resolves to nobody")
    eq(AltStable.ResolveCharacter(nil), nil, "and so does no name")

    -- An exact full-name match wins even when it is also somebody's first name.
    AltStableDB["g-4"] = { guid = "g-4", name = "Karuzo", class = "WARRIOR", level = 10 }
    eq(AltStable.ResolveCharacter("Karuzo"), "g-4",
       "a character actually called Karuzo beats the ambiguity")
end

do
    -- THE SAME FULL NAME ON TWO REALMS. This is the case the first fix missed:
    -- `exact = guid` inside a pairs() loop kept whichever was visited last, so a
    -- destructive command picked one at random and the name-only interface gave
    -- no way to ask for the other.
    WoW.reset()
    AltStableDB = {
        ["pve-1"] = { guid = "pve-1", name = "Same Surname", realm = "Pyrewood",
                      class = "MAGE", level = 60 },
        ["pvp-1"] = { guid = "pvp-1", name = "Same Surname", realm = "Nightslayer",
                      class = "ROGUE", level = 60 },
        ["solo-1"] = { guid = "solo-1", name = "Only Surname", realm = "Pyrewood",
                       class = "PRIEST", level = 30 },
    }

    local guid, why = AltStable.ResolveCharacter("Same Surname")
    eq(guid, nil, "a full name held on two realms resolves to nobody")
    check(why and why:find("Pyrewood", 1, true) and why:find("Nightslayer", 1, true),
          "  and names both realms, which is the only way to tell them apart: "
          .. tostring(why))

    -- Stable, because pairs() order was not.
    for _ = 1, 20 do
        eq(AltStable.ResolveCharacter("Same Surname"), nil, "  every time")
    end

    -- The realm is the selector.
    eq(AltStable.ResolveCharacter("Same Surname-Pyrewood"), "pve-1",
       "naming the realm picks one")
    eq(AltStable.ResolveCharacter("same surname-nightslayer"), "pvp-1",
       "  the other, and case does not matter")

    -- A first name shared across realms is ambiguous for the same reason.
    local firstGuid = AltStable.ResolveCharacter("Same")
    eq(firstGuid, nil, "so is the first name they share")

    eq(AltStable.ResolveCharacter("Only Surname"), "solo-1",
       "a name held once still resolves without ceremony")
    eq(AltStable.ResolveCharacter("Only"), "solo-1", "  and so does its first name")
end
-- Authorization, case-folded and mutual
------------------------------------------------------------
-- WoW whisper targets are case-insensitive and the rest of the addon knows it:
-- IsWhitelisted, RemoveFromWhitelist and IsPeerOnline all compare with
-- :lower(). The gate did not. That broke it in both directions - a whitelist
-- entry typed in another case stopped being served, and /alts deny stored an
-- answer under a key the handler never read, so it printed "refusing" and went
-- on serving them. A control that no-ops on a capitalisation while reporting
-- success is worse than no control.

do
    WoW.reset()
    AltStableConfig = { whitelist = { "karuzo" }, peerWatermarks = {} }
    eq(AltStable.SyncAuthFor("Karuzo"), AltStable.AUTH_AUTO,
       "a whitelist entry matches the character whatever the case")
    eq(AltStable.SyncAuthFor("KARUZO-Realm"), AltStable.AUTH_AUTO,
       "  realm suffix and shouting included")

    AltStable.DenySyncPeer("karuzo")
    eq(AltStable.SyncAuthFor("Karuzo"), AltStable.AUTH_NEVER,
       "denying in one case denies in every case")

    AltStable.AllowSyncPeer("KARUZO")
    eq(AltStable.SyncAuthFor("karuzo"), AltStable.AUTH_AUTO,
       "  and so does allowing")

    -- One entry, not three.
    local list = AltStable.SyncAuthList()
    eq(#list, 1, "the same peer in three cases is one stored answer")
end

do
    -- "Refuse them for good" has to mean both directions. Gating only the
    -- inbound request left a denied peer on the whitelist, so every login still
    -- whispered them a REQ and /alts cleanup still pushed them the database.
    WoW.reset()
    AltStableConfig = { whitelist = { "Friend", "Nuisance" }, peerWatermarks = {} }
    local function targetNames()
        local names = {}
        for _, t in ipairs(T.GetSyncTargets()) do names[#names + 1] = t.target end
        table.sort(names)
        return table.concat(names, ",")
    end
    eq(targetNames(), "Friend,Nuisance", "both whitelisted peers are sync targets")

    AltStable.DenySyncPeer("nuisance")
    eq(targetNames(), "Friend", "a denied peer is no longer pushed to either")
end

do
    -- Forgetting an answer for a WHITELISTED peer falls back to the whitelist,
    -- which is auto - so saying "they will be asked about again" would tell the
    -- player the opposite of the truth. The player most likely to type this is
    -- one who denied someone they had whitelisted.
    WoW.reset()
    AltStableConfig = { whitelist = { "Bob" }, peerWatermarks = {} }
    AltStable.DenySyncPeer("Bob")
    WoW.chatOut = {}
    AltStable.ForgetSyncPeer("Bob")
    local said = table.concat(WoW.chatOut or {}, " ")
    eq(AltStable.SyncAuthFor("Bob"), AltStable.AUTH_AUTO,
       "forgetting falls back to the whitelist")
    check(said:find("whitelist", 1, true) ~= nil,
          "  and the message says so rather than promising a prompt: " .. said)
    check(said:lower():find("asked about again", 1, true) == nil,
          "  it does not claim they will be asked about again")

    -- With no whitelist entry, the plain wording is correct.
    WoW.reset()
    AltStableConfig = { peerWatermarks = {} }
    AltStable.DenySyncPeer("Carol")
    WoW.chatOut = {}
    AltStable.ForgetSyncPeer("Carol")
    eq(AltStable.SyncAuthFor("Carol"), AltStable.AUTH_ASK,
       "without a whitelist entry, forgetting really does mean ask")
    check(table.concat(WoW.chatOut or {}, " "):find("asked about again", 1, true) ~= nil,
          "  and it says so")
end

do
    -- Module state has to be reset between sections like every other piece of
    -- sync state, or a leftover pending request decides a later assertion.
    WoW.reset()
    AltStableConfig = { peerWatermarks = {} }
    onEvent(T.frame, "CHAT_MSG_ADDON", PREFIX, T.MSG_REQUEST_V .. "|0", "WHISPER", "Ghost Surname")
    check(#AltStable.PendingSyncRequests() > 0, "a stranger's request is pending")
    WoW.reset()
    eq(#AltStable.PendingSyncRequests(), 0, "  and a reset clears it, like the rest of the sync state")
end

do
    -- An unanswered request expires rather than accumulating for the session.
    WoW.reset()
    AltStableConfig = { peerWatermarks = {} }
    onEvent(T.frame, "CHAT_MSG_ADDON", PREFIX, T.MSG_REQUEST_V .. "|0", "WHISPER", "Fleeting Surname")
    eq(#AltStable.PendingSyncRequests(), 1, "the request is remembered")
    WoW.now = (WoW.now or 0) + 3600
    eq(#AltStable.PendingSyncRequests(), 0, "  and an hour later it is gone, not merely hidden")
end
if failures == 0 then
    print(("test_comm: %d passed, %d failed"):format(testsRun, 0))
else
    print(("test_comm: %d passed, %d failed"):format(testsRun - failures, failures))
    os.exit(1)
end
