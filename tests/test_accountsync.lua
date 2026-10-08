------------------------------------------------------------
-- test_accountsync.lua - own-account sync over LibAccountSync-1.0 (#198)
--
-- The real library (r5, the .pkgmeta pin) loads first, as the TOC loads it,
-- and Core.lua builds its instance. Then:
--   * the instance and the key import, against the real library;
--   * the routing, the handshake and the gates, against a fake instance that
--     records SendTo and answers it as scripted - the library's own suite owns
--     the wire; this one owns which stack AltStable picks and what it lets in.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
dofile("tests/libaccountsync.lua")
local LAS = LoadAccountSync("AltStable")
dofile("Libs/LibStub/LibStub.lua")
dofile("Libs/LibDeflate/LibDeflate.lua")

AltStable, AltStableDB, AltStableConfig = {}, {}, {}
dofile("Compat.lua")
dofile("Prompt.lua")
assert(loadfile("Core.lua"))()
dofile("Config.lua")

local T = AltStable._test
local L = T.LibSync
local LD = LibStub("LibDeflate")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1 else
        failed = failed + 1
        print("  FAIL: " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
    end
end
local function eq(name, got, want) check(name, got == want, ("got %s, want %s"):format(tostring(got), tostring(want))) end

local function flush()
    for _ = 1, 20 do
        if #WoW.timers == 0 then break end
        WoW.flushTimers()
    end
end

------------------------------------------------------------
-- The real instance
------------------------------------------------------------
local real = L.inst
check("Core builds a LibAccountSync instance at load", real ~= nil)
check("  registered under the AltStable tag", LAS.byTag.AltStable == real)
eq("  in independent-message mode (LibAccountSync#18)", real and real.messages, true)
eq("  with SendTo", real and type(real.SendTo), "function")
eq("  and our handler registered right after New", real and real.handler, L.OnMessage)

------------------------------------------------------------
-- The key import (#198, LibAccountSync#14)
------------------------------------------------------------
local OWN   = ("a"):rep(32)
local PEER1 = ("b"):rep(32)
local PEER2 = ("c"):rep(32)
do
    AltStableConfig = {
        bnetKey = OWN,
        bnetTrusted = {
            [PEER1] = true,
            [PEER2] = false,                       -- never written so, but not ours to trust
            [("f"):rep(32)] = 1,                   -- truthy, but not the `true` the hello handler writes
            ["0123456789abcdef"] = true,           -- 16 characters: the legacy rule, not the library's
            [("D"):rep(32)] = true,                -- upper case: not the library's hex
            [OWN] = true,                          -- our own key is never trusted
        },
    }
    local t = L.Store()
    check("the store is built on first use", type(t) == "table" and AltStableConfig.accountSync == t)
    eq("  our legacy key becomes the key", t.key, OWN)
    eq("  at keyAt 1, older than any key the library makes", t.keyAt, 1)
    check("  a trusted key comes along, as a lastSeen number", type(t.trusted[PEER1]) == "number")
    local n = 0
    for _ in pairs(t.trusted) do n = n + 1 end
    eq("  and nothing else: not false, not 1, not short, not upper case, not ours", n, 1)
    check("asked again, the same table (built once)", L.Store() == t)

    -- A key the legacy rule accepted but the library's does not: no key, and
    -- the library makes its own.
    AltStableConfig = { bnetKey = "0123456789abcdef" }
    eq("a 16-character legacy key is not imported", L.Store().key, nil)

    AltStableConfig = nil
    eq("before the SavedVariables load, no store", L.Store(), nil)
end

-- The real library's choice: our imported oldest key becomes the household
-- key even where another addon's store (GlassChat's) already holds one, and
-- that store keeps its own key, never overwritten.
do
    local G = ("e"):rep(32)
    AltStableConfig = { bnetKey = OWN, bnetTrusted = { [PEER1] = true } }
    local gc = { key = G, keyAt = 1700000000, trusted = {} }
    local okNew, glass = pcall(LAS.New, LAS, { addon = "GlassChat", store = function() return gc end })
    check("a second addon registers on the same library", okNew and type(glass) == "table", glass)
    local S = LAS.state
    S.key, S.keyAt = nil, nil
    local wasIn = S.loggedIn
    S.loggedIn = true
    local chosen = LAS.impl.OwnKey()
    eq("the household key is our imported one", chosen, OWN)
    eq("  GlassChat's store keeps its own key", gc.key, G)
    eq("  and ours holds the household key", AltStableConfig.accountSync.key, OWN)
    check("  our trusted key is trusted in GlassChat's store too", type(gc.trusted[PEER1]) == "number")
    -- Back as it was: the rest of this file is not about the real library.
    LAS.byTag.GlassChat = nil
    for i = #LAS.instances, 1, -1 do
        if LAS.instances[i] == glass then table.remove(LAS.instances, i) end
    end
    S.key, S.keyAt, S.loggedIn = nil, nil, wasIn
end

------------------------------------------------------------
-- A fake instance from here on
------------------------------------------------------------
-- SendTo is recorded and answers fake.ret (1 taken, 0 not-ready, nil refused);
-- fake.early, when set, is reported BEFORE SendTo returns, as the library does
-- for a peer without our nonce yet.
local fake
local function freshFake()
    fake = { messages = true, sent = {}, peers = {}, ret = 1, enabled = true }
    function fake.SendTo(guid, msg, onResult)
        fake.sent[#fake.sent + 1] = { guid = guid, msg = msg, onResult = onResult }
        if fake.early then onResult({ guid = guid }, fake.early, "not-ready") end
        return fake.ret
    end
    function fake.Peers() return fake.peers end
    fake.setCalls = 0
    function fake.SetEnabled(on) fake.enabled = on; fake.setCalls = fake.setCalls + 1 end
    function fake.IsEnabled() return fake.enabled end
    L.inst = fake
    L.Forget()
    return fake
end

local BEE, BEE_GUID = "Bee Surname", "Player-1-0000BEE"
local function listBee() fake.peers = { { name = BEE, guid = BEE_GUID, realm = "R", faction = "Horde" } } end
local function fromBee(payload)
    L.OnMessage(payload, { name = BEE, guid = BEE_GUID, realm = "R", faction = "Horde", proven = "bnet" })
end
local function reset()
    WoW.reset(); T.ResetSyncState()
    AltStableDB = {}
    AltStableConfig = { peerWatermarks = {}, sendAllAccounts = true }
    freshFake()
end
local function wire(kind)
    local out = {}
    for _, m in ipairs(WoW.sent) do
        if not kind or m.text:sub(1, #kind) == kind then out[#out + 1] = m end
    end
    return out
end

------------------------------------------------------------
-- The handshake
------------------------------------------------------------
-- What went to them over the library, by message: the question (CAP8), the
-- answer (CAP8|1), a request (REQ8|...).
local ANSWER = L.MSG_CAP .. "|1"
local function count(msg, prefix)
    local n = 0
    for _, s in ipairs(fake.sent) do
        if (prefix and s.msg:sub(1, #msg) == msg) or s.msg == msg then n = n + 1 end
    end
    return n
end

reset()
listBee()
L.Ping()
eq("a listed own account we have not heard on gets a CAP8 question", count(L.MSG_CAP), 1)
eq("  to its GUID", fake.sent[1] and fake.sent[1].guid, BEE_GUID)
L.Ping()
eq("  not again within 30 s", count(L.MSG_CAP), 1)
for _ = 1, 10 do WoW.now = WoW.now + 31; L.Ping() end
eq("  again every 30 s, five times in all, then no more", count(L.MSG_CAP), 5)
check("not counted as on the library just for being pinged", L.Peer(BEE) == nil)

reset()
listBee()
fromBee(L.MSG_CAP)
check("a CAP8 question from them: on the library", L.Peer(BEE) ~= nil)
eq("  answered with CAP8|1", count(ANSWER), 1)
eq("  and, found only this way, asked for their data", count(T.MSG_REQUEST_V .. "|", true), 1)
fromBee(L.MSG_CAP)
eq("  a second question within 5 s is not answered again", count(ANSWER), 1)
WoW.now = WoW.now + 6
fromBee(L.MSG_CAP)
eq("  but after, it is: they may have reloaded and forgotten us", count(ANSWER), 2)
eq("  and they are not asked for their data twice", count(T.MSG_REQUEST_V .. "|", true), 1)
WoW.now = WoW.now + 6           -- past the rate limit, so only the rule can hold it
fromBee(ANSWER)
eq("an answer is never answered (no ping-pong)", count(ANSWER), 2)
WoW.now = WoW.now + 31
L.Ping()
eq("  and nobody heard on it is pinged", count(L.MSG_CAP), 0)

-- An answer the library refuses (no nonce yet) does not count as given.
reset()
listBee()
fake.ret = 0
fromBee(L.MSG_CAP)
fake.ret = 1
fromBee(L.MSG_CAP)
eq("a refused answer is answered again at the next question", count(ANSWER), 2)

-- Found by the legacy discovery as well: not asked twice.
reset()
WoW.bn.accounts[7] = { characterName = BEE, playerGuid = BEE_GUID, isOnline = true,
                       clientProgram = "WoW", wowProjectID = 18, isInCurrentRegion = true, regionID = 90,
                       factionName = "Horde", realmName = "R", bnetAccountID = WoW.bn.me }
AltStable.RescanOwnAccounts()
flush()
check("  (the legacy discovery found it)", AltStable.IsOwnBNetPeer(BEE))
listBee()
fake.sent = {}
WoW.now = WoW.now + 301         -- past the request throttle, so only the rule can hold it
fromBee(L.MSG_CAP)
eq("a peer the legacy discovery found is not asked again from here", count(T.MSG_REQUEST_V .. "|", true), 0)
WoW.bn.accounts[7] = nil

-- The library no longer lists them (logged off, another character): not ours.
reset()
listBee()
fromBee(L.MSG_CAP)
fake.peers = {}
check("a peer the library stops listing is forgotten", L.Peer(BEE) == nil)
check("  and is not our own account any more", not AltStable.IsOwnBNetPeer(BEE))
listBee()
fake.peers[1].name = "Other Name"
fromBee(L.MSG_CAP)
check("a GUID now listed under another name is not ours under the old one", L.Peer(BEE) == nil)

------------------------------------------------------------
-- Requests: which stack
------------------------------------------------------------
local REQ = T.MSG_REQUEST_V .. "|0"

reset()
L.SendRequest(REQ, "WHISPER", BEE, "ALERT")
eq("a peer not heard on the library: the request goes legacy", #wire(T.MSG_REQUEST_V), 1)
eq("  and nothing over the library", #fake.sent, 0)

reset()
listBee()
fromBee(L.MSG_CAP)
fake.sent = {}
local sentResults = {}
L.SendRequest(REQ, "BNET", BEE, "ALERT", function(ok) sentResults[#sentResults + 1] = ok end)
eq("on the library: one SendTo", #fake.sent, 1)
eq("  to their GUID", fake.sent[1] and fake.sent[1].guid, BEE_GUID)
eq("  carrying the legacy command unchanged", fake.sent[1] and fake.sent[1].msg, REQ)
eq("  and no legacy frame", #wire(), 0)
eq("  onSent waits for the library", #sentResults, 0)
fake.sent[1].onResult({ guid = BEE_GUID }, "sent")
eq("  then runs once", #sentResults, 1)
eq("  with true", sentResults[1], true)

-- A refusal reported before SendTo returns: the fallback's onSent is the only one.
reset()
listBee()
fromBee(L.MSG_CAP)
fake.sent, fake.ret, fake.early = {}, 0, "failed"
sentResults = {}
L.SendRequest(REQ, "WHISPER", BEE, "ALERT", function(ok) sentResults[#sentResults + 1] = ok end)
eq("refused (not-ready): the request falls back to the legacy wire", #wire(T.MSG_REQUEST_V), 1)
eq("  one SendTo, never a second try or a broadcast", #fake.sent, 1)
eq("  and onSent runs once, the fallback's", #sentResults, 1)
fake.early = nil

-- Taken, then reported failed later (offline, no route): onSent(false), once.
reset()
listBee()
fromBee(L.MSG_CAP)
fake.sent = {}
sentResults = {}
L.SendRequest(REQ, "BNET", BEE, "ALERT", function(ok) sentResults[#sentResults + 1] = ok end)
fake.sent[1].onResult({ guid = BEE_GUID }, "failed", "offline")
eq("a send that fails after starting: onSent(false)", sentResults[1], false)
eq("  once, with no fallback (the library took it)", #sentResults, 1)
eq("  and no legacy frame", #wire(), 0)

-- Taken, and reported "sent" before SendTo returned (ChatThrottleLib sent at once).
reset()
listBee()
fromBee(L.MSG_CAP)
fake.sent, fake.early = {}, "sent"
sentResults = {}
L.SendRequest(REQ, "BNET", BEE, "ALERT", function(ok) sentResults[#sentResults + 1] = ok end)
eq("a report that comes before the return is held, then given once", #sentResults, 1)
eq("  as true", sentResults[1], true)
fake.early = nil

-- Never the library for an answer to a whisper.
reset()
listBee()
fromBee(L.MSG_CAP)
fake.sent = {}
L.SendRequest(REQ, "WHISPER_DIRECT", BEE, "ALERT")
eq("WHISPER_DIRECT stays a whisper", #wire(T.MSG_REQUEST_V), 1)
eq("  and never the library", #fake.sent, 0)

-- A copy without the #18 delivery, or without SendTo: legacy only.
for _, case in ipairs({ { "a snapshot-mode copy (messages ~= true)", function() fake.messages = nil end },
                        { "a copy without SendTo", function() fake.SendTo = nil end } }) do
    reset()
    listBee()
    fromBee(L.MSG_CAP)
    fake.sent = {}
    case[2]()
    L.SendRequest(REQ, "BNET", BEE, "ALERT")
    eq(case[1] .. ": nothing over the library", #fake.sent, 0)
end

-- Checked when used, not cached at load: an instance an older copy made gains
-- SendTo when a newer copy loads.
reset()
listBee()
local gained = fake.SendTo
fake.SendTo = nil
fromBee(L.MSG_CAP)
fake.SendTo = gained
fake.sent = {}
L.SendRequest(REQ, "BNET", BEE, "ALERT")
eq("SendTo gained after load is used", #fake.sent, 1)

------------------------------------------------------------
-- Replies and pushes: the whole payload, deflated, to one peer
------------------------------------------------------------
local function seed()
    AltStableDB = {
        ["Player-1-A"] = { guid = "Player-1-A", name = "Alpha", class = "MAGE", level = 60, lastUpdate = 1000 },
        ["Player-1-B"] = { guid = "Player-1-B", name = "Beta", class = "ROGUE", level = 42, lastUpdate = 1000 },
    }
end
local function dbSent()
    for _, s in ipairs(fake.sent) do
        if s.msg:sub(1, #L.MSG_DB + 1) == L.MSG_DB .. "|" then return s end
    end
end

reset()
seed()
listBee()
fromBee(L.MSG_CAP)
fake.sent = {}
fromBee(REQ)
flush()
local db = dbSent()
check("a request over the library is served over the library", db ~= nil)
eq("  to their GUID", db and db.guid, BEE_GUID)
local raw = db and LD:DecompressDeflate(db.msg:sub(#L.MSG_DB + 2))
check("  one whole deflated payload", type(raw) == "string" and raw:find("Alpha", 1, true) ~= nil, raw)
check("  with our clock at the end, as the legacy stream has", raw and raw:find("\n==NOW==:", 1, true) ~= nil, raw)
eq("  and no legacy chunks", #wire(T.MSG_CHUNK_V), 0)

-- A whisper to our own account on the library: the library, not the whisper
-- (the legacy route the reply test above used had no binding to show it).
reset()
seed()
listBee()
fromBee(L.MSG_CAP)
fake.sent = {}
T.SendFullDatabase("WHISPER", BEE)
check("a push by whisper to an own account on the library goes over it", dbSent() ~= nil)
eq("  and not also as whispered chunks", #wire(T.MSG_CHUNK_V), 0)

-- Refused (too large, not-ready): the reply falls back to chunks for this one
-- send - still to this one peer.
reset()
seed()
listBee()
fromBee(L.MSG_CAP)
fake.sent, fake.ret = {}, nil
T.SendFullDatabase("WHISPER", BEE)
check("a refused reply goes out as legacy chunks", #wire(T.MSG_CHUNK_V) > 0)
eq("  after one SendTo", #fake.sent, 1)
for _, m in ipairs(wire()) do
    if m.target ~= BEE then check("  every legacy frame to them alone", false, m.target) break end
end

------------------------------------------------------------
-- Inbound: the same gates as the legacy path
------------------------------------------------------------
local function deflated(text) return L.MSG_DB .. "|" .. LD:CompressDeflate(text, { level = 8 }) end
local function payloadOf(db)
    local saved = AltStableDB
    AltStableDB = db
    local p = T.SerializeFullDB(false)
    AltStableDB = saved
    return p
end
local theirs = payloadOf({
    ["Player-9-Z"] = { guid = "Player-9-Z", name = "Zed", class = "DRUID", level = 30, lastUpdate = 2000 },
})

reset()
listBee()
fromBee(deflated(theirs))
check("a database from our own account over the library is merged", AltStableDB["Player-9-Z"] ~= nil)
check("  and counts as on the library", L.Peer(BEE) ~= nil)

reset()
listBee()
AltStableConfig.syncAuth = { [T.AuthKey and T.AuthKey(BEE) or BEE:lower()] = "never" }
fromBee(deflated(theirs))
check("refused for good: a database is dropped unread", AltStableDB["Player-9-Z"] == nil)
fromBee(REQ)
flush()
check("  and a request is not served", dbSent() == nil and #wire(T.MSG_CHUNK_V) == 0)

-- Not (or no longer) listed by the library as ours: not trusted as ours.
reset()
fromBee(deflated(theirs))
check("from a GUID the library does not list: not admitted", AltStableDB["Player-9-Z"] == nil)

reset()
listBee()
fromBee(L.MSG_DB .. "|not deflate at all")
check("undecodable: nothing merged", next(AltStableDB) == nil)

reset()
listBee()
fromBee("WHAT9|something")
fromBee("")
check("an unknown command or an empty payload is ignored",
      next(AltStableDB) == nil and count(ANSWER) == 0 and count(L.MSG_DB .. "|", true) == 0)

-- Battle.net gone, or the switch off: nobody is on the library any more.
reset()
listBee()
fromBee(L.MSG_CAP)
T.frame:GetScript("OnEvent")(T.frame, "BN_DISCONNECTED")
check("BN_DISCONNECTED forgets who runs the library", next(L.peers) == nil)

reset()
listBee()
fromBee(L.MSG_CAP)
AltStableConfig.bnetSync = false
AltStable.RescanOwnAccounts()
eq("switching Battle.net sync off switches the library off", fake.enabled, false)
check("  and forgets who runs it", next(L.peers) == nil)
AltStableConfig.bnetSync = nil
AltStable.RescanOwnAccounts()
eq("  and on again", fake.enabled, true)
local calls = fake.setCalls
AltStable.RescanOwnAccounts()
AltStable.RescanOwnAccounts()
eq("  told only when the switch changes, not on every scan", fake.setCalls, calls)

-- A library-only peer refuses a database (too large, not-ready) and has no
-- legacy Battle.net route: the reply goes nowhere, and no frame reaches anyone.
reset()
seed()
listBee()
fromBee(L.MSG_CAP)
fake.sent, fake.ret = {}, nil
T.SendFullDatabase("BNET", BEE)
eq("a refused database to a library-only peer: no frame to anyone", #wire(), 0)
eq("  after its one SendTo", count(L.MSG_DB .. "|", true), 1)

-- A pairing made over the legacy channel after the store was built reaches
-- the library's store too, by the import's rule.
reset()
AltStableConfig.bnetKey = OWN
L.Store()
T.TrustKey(PEER2)
check("a key trusted later over the legacy channel is trusted by the library too",
      type(AltStableConfig.accountSync.trusted[PEER2]) == "number")
T.TrustKey("0123456789abcdef")
eq("  but not one the library's rule refuses", AltStableConfig.accountSync.trusted["0123456789abcdef"], nil)

L.inst = real
print(("test_accountsync: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
