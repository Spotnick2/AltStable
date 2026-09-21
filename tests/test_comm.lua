------------------------------------------------------------
-- test_comm.lua — AltStable sync/communication protocol tests.
--
-- Ported from AltTracker, whose Core.lua this repo imported verbatim
-- (#19). The sync engine is the only path by which other characters'
-- data reaches the sheet while SavedVariables do not load (#23), and
-- this is the harness issue #20 asks for before its fixes.
--
-- Exercises the wire format in Core.lua (base64 codec, checksum,
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

-- Deliver a raw wire message to the receive handler as if from `sender`.
local function receive(message, sender)
    -- Forever reports the sender as "First Surname" - a space, no realm
    -- (docs/forever-api-notes.md). The TBC shape "Name-Realm" was the default
    -- here, so nothing exercised the name this client actually delivers.
    onEvent(T.frame, "CHAT_MSG_ADDON", PREFIX, message, "WHISPER", sender or "Peer Surname")
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
-- 1. Base64 codec
--
-- LEGACY. No packet has used this codec since v7 moved the wire to LibDeflate;
-- its only reference is the _test seam. Delete this section together with the
-- codec, rather than let it keep counting towards wire coverage.
------------------------------------------------------------

eq(T.Base64Encode("Man"), "TWFu", "base64 vector: Man")
eq(T.Base64Encode("Ma"),  "TWE=", "base64 vector: Ma")
eq(T.Base64Encode("M"),   "TQ==", "base64 vector: M")
eq(T.Base64Encode(""),    "",     "base64 of empty string")

for _, s in ipairs({
    "", "a", "ab", "abc", "abcd",
    "guid:Player-1\nname:Bob\nlevel:70",
    string.char(0, 1, 2, 127, 200, 254, 255),
}) do
    eq(T.Base64Decode(T.Base64Encode(s)), s, "base64 round-trip (len " .. #s .. ")")
end

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
for _, m in ipairs(selfWire) do receive(m, UnitName("player")) end
eq(dbCount(), 0, "our own packets (sender == player, Forever-shaped) are ignored")
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
T.DeserializeChar(ps)
eq(delivered["Player-Plug-1"], "blob-for:Player-Plug-1", "plugin OnDeserialize receives its blob for the char")
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
-- 17. Malformed / out-of-range chunks are discarded and reported
------------------------------------------------------------

WoW.reset()
AltStableDB = {}
receive(T.MSG_CHUNK_V .. "|1|not-a-valid-header", "Junk-Realm")
check(chatHas("Malformed"), "malformed chunk header is reported")
WoW.chatOut = {}
receive(T.MSG_CHUNK_V .. "|1|9/3|" .. T.Base64Encode("x"), "Junk-Realm")
check(chatHas("Out-of-range"), "out-of-range seq (seq > total) is reported")
eq(T.Base64Decode("@@@@"), nil, "malformed base64 body decodes to nil")

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
-- #20 bug 2: an echoed OWN character keeps its local-only fields
--
-- gearlink_ and gearsubtype_ never travel on the wire, so the merge cannot
-- restore them. They survive while the slot still holds the item they
-- describe, and go the moment it holds something else.
------------------------------------------------------------

WoW.reset()
AltStableDB = { ["Player-Own-1"] = {
    guid = "Player-Own-1", name = "Mine", class = "PRIEST", level = 60,
    gearid_head = 555, gearlink_head = "|Hitem:555|h[Helm]|h", gearsubtype_head = "Cloth",
    gearid_chest = 777, gearlink_chest = "|Hitem:777|h[Robe]|h", gearsubtype_chest = "Cloth",
    lastUpdate = 1000,
} }
-- A peer echoes our own record back: head unchanged, chest swapped for 888.
T.DeserializeFullDB(T.SerializeChar(
    { guid = "Player-Own-1", name = "Mine", class = "PRIEST", level = 60,
      gearid_head = 555, gearid_chest = 888, lastUpdate = 1000 }
) .. "\n" .. T.CHAR_SEP, "Peer")
local own = AltStableDB["Player-Own-1"]
eq(own.gearlink_head, "|Hitem:555|h[Helm]|h", "an echoed own character keeps the link for an unchanged slot")
eq(own.gearsubtype_head, "Cloth", "  and the local-only subtype with it")
eq(own.gearlink_chest, nil, "a slot now holding a different item loses its stale link")
eq(own.gearsubtype_chest, nil, "  and its stale subtype")

------------------------------------------------------------
-- 26. Delta sync: the watermark advances after a successful receive
------------------------------------------------------------

WoW.reset()
AltStableConfig = { peerWatermarks = {} }
AltStableDB = {
    ["Player-WM-1"] = { guid = "Player-WM-1", name = "W1", class = "MAGE",  ilvl = 100, lastUpdate = 700 },
    ["Player-WM-2"] = { guid = "Player-WM-2", name = "W2", class = "ROGUE", ilvl = 110, lastUpdate = 1200 },
}
T.ChunkAndSendPayload(T.SerializeFullDB(false, 0), "WHISPER", "x")
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
T.ChunkAndSendPayload(T.SerializeFullDB(false, 0), "WHISPER", "x")
WoW.flushTimers()
local fastWire = WoW.sentMessages()
AltStableDB = {}
for _, m in ipairs(fastWire) do receive(m, "Fastpeer-Realm") end
local fwm = AltStableConfig.peerWatermarks["Fastpeer"]
check(fwm and fwm <= 100000, "a future-dated relayed record cannot push the watermark past our clock (got " .. tostring(fwm) .. ")")
check(fwm and fwm <= 99990, "  and it stays below the peer's own recent change, so that is re-requested")
eq(T.ClampWatermark(1200), 1200, "an old watermark is left exact")

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

------------------------------------------------------------
-- #20 bug 4: changing sync scope resets the watermarks
--
-- Newly eligible characters carry lastUpdate values below every watermark, so
-- without a reset they are never sent.
------------------------------------------------------------

AltStableConfig = { peerWatermarks = { A = 500, B = 900 }, sendAllAccounts = false }
AltStable.SetConfigValue("theme", "dark")
eq(AltStableConfig.peerWatermarks.A, 500, "an unrelated setting leaves the watermarks alone")
AltStable.SetConfigValue("sendAllAccounts", false)
eq(AltStableConfig.peerWatermarks.A, 500, "re-setting a scope setting to its current value leaves them alone")
AltStable.SetConfigValue("sendAllAccounts", true)
eq(next(AltStableConfig.peerWatermarks), nil, "turning on send-all-accounts resets every watermark")
AltStableConfig.peerWatermarks = { A = 500 }
AltStable.SetConfigValue("accountNumber", "2")
eq(next(AltStableConfig.peerWatermarks), nil, "changing the account number resets them too")

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

if failures == 0 then
    print(("test_comm: %d passed, %d failed"):format(testsRun, 0))
else
    print(("test_comm: %d passed, %d failed"):format(testsRun - failures, failures))
    os.exit(1)
end
