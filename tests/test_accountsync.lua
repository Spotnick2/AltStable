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
        return fake.ret, fake.why
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

-- A question the library refuses (no nonce yet - it says hello instead) is
-- not counted: asked again at the next tick, not 30 s later (#206: no legacy
-- hello comes first any more, so this is first contact).
reset()
listBee()
fake.ret = 0
L.Ping()
L.Ping()
eq("a refused question is asked again at once", count(L.MSG_CAP), 2)
fake.ret = 1
L.Ping()
eq("  until one is taken", count(L.MSG_CAP), 3)
L.Ping()
eq("  which then waits its 30 s", count(L.MSG_CAP), 3)
for _ = 1, 10 do WoW.now = WoW.now + 31; L.Ping() end
eq("  and refusals did not use up the five tries", count(L.MSG_CAP), 7)

-- An account that never gets a nonce (no addon on the library there at all)
-- is not asked - and so not said hello to by the library - all session.
reset()
listBee()
fake.ret = 0
for _ = 1, 40 do WoW.now = WoW.now + 10; L.Ping() end
eq("refused questions stop after their own budget of 30", count(L.MSG_CAP), 30)

-- First contact is forced past the request throttle: the login whisper to a
-- whitelisted own account sets it, and may have gone nowhere.
reset()
AltStableConfig.whitelist = { BEE }
T.RequestCharacters("WHISPER", BEE)
listBee()
fake.sent = {}
fromBee(L.MSG_CAP)
eq("found on the library moments after a login whisper: still asked", count(T.MSG_REQUEST_V .. "|", true), 1)
T.ResetSyncState()
check("the test seam's reset forgets who is on the library too", next(L.peers) == nil)

-- First contact whose request the library refuses (Codex, #212): their CAP8
-- overtook the library's hello, so we can hear them but not yet send to them.
-- The request stays pending until one goes out.
local REQS = T.MSG_REQUEST_V .. "|"
reset()
listBee()
fake.ret = 0
fromBee(L.MSG_CAP)
eq("first contact, library not ready: the request is tried", count(REQS, true), 1)
fake.ret = 1
WoW.now = WoW.now + 10
L.Ping()
eq("  and tried again at the next tick, once the library is ready", count(REQS, true), 2)
local last = fake.sent[#fake.sent]
L.Ping()
eq("  not again while that one is on its way", count(REQS, true), 2)
last.onResult({ guid = BEE_GUID }, "sent")
WoW.now = WoW.now + 10
L.Ping()
fromBee(L.MSG_CAP)
eq("  and never again once it went out", count(REQS, true), 2)

-- Taken by the library, then failed on the way: asked again too.
reset()
listBee()
fromBee(L.MSG_CAP)
for _, s in ipairs(fake.sent) do
    if s.msg:sub(1, #REQS) == REQS then s.onResult({ guid = BEE_GUID }, "failed", "offline") end
end
local before = count(REQS, true)
L.Ping()
eq("a request that failed on the way is asked again", count(REQS, true), before + 1)

-- Bounded: a library that never becomes ready is not asked all session.
reset()
listBee()
fake.ret = 0
fromBee(L.MSG_CAP)
for _ = 1, 40 do WoW.now = WoW.now + 10; L.Ping() end
eq("a request the library keeps refusing stops after 30 tries", count(REQS, true), 30)
L.Forget()
fake.ret = 1
fromBee(L.MSG_CAP)
eq("  and starts again after Battle.net reconnects (Forget)", count(REQS, true), 31)

-- Refused for good: never asked, however many ticks.
reset()
listBee()
fake.ret = 0
fromBee(L.MSG_CAP)
AltStableConfig.syncAuth = { [BEE:lower()] = "never" }
fake.ret = 1
local n0 = count(REQS, true)
for _ = 1, 5 do WoW.now = WoW.now + 10; L.Ping() end
eq("a peer refused for good after first contact is not asked again", count(REQS, true), n0)

-- Found on the library: said once, with where they are, and trusted like a
-- whitelist entry.
reset()
listBee()
WoW.chatOut = {}
fromBee(L.MSG_CAP)
local function said(text)
    local n = 0
    for _, l in ipairs(WoW.chatOut) do if l:find(text, 1, true) then n = n + 1 end end
    return n
end
eq("a new own account is announced", said("Found your other account"), 1)
eq("  with its faction and realm", said("(Horde, R)"), 1)
eq("  and is served without asking (#61)", AltStable.SyncAuthFor(BEE), AltStable.AUTH_AUTO)
WoW.now = WoW.now + 6
fromBee(L.MSG_CAP)
eq("  and not announced again", said("Found your other account"), 1)

-- No realm from the library: the database's, for a character synced before.
reset()
fake.peers = { { name = BEE, guid = BEE_GUID, faction = "Horde" } }
AltStableDB[BEE_GUID] = { guid = BEE_GUID, name = BEE, class = "MAGE", level = 1, lastUpdate = 1, realm = "Classic Beta PvE" }
WoW.chatOut = {}
L.OnMessage(L.MSG_CAP, { name = BEE, guid = BEE_GUID, faction = "Horde", proven = "bnet" })
eq("a record without a realm takes the database's", said("(Horde, Classic Beta PvE)"), 1)

-- Refused for good: noticed, but neither announced nor asked.
reset()
listBee()
AltStableConfig.syncAuth = { [BEE:lower()] = "never" }
WoW.chatOut = {}
fromBee(L.MSG_CAP)
eq("a refused own account is not announced", said("Found your other account"), 0)
eq("  nor asked for its data", count(T.MSG_REQUEST_V .. "|", true), 0)

-- An own account that never answers is reported by the stall watch: it is
-- online, so silence is worth a line (what the owner saw while #206's switch
-- was off on the other side).
reset()
listBee()
fromBee(L.MSG_CAP)
WoW.chatOut = {}
WoW.now = WoW.now + 60
flush()
eq("a found account that never answers is reported", said("No sync response from " .. BEE), 1)

-- A character known as our own this session, no longer listed (logged off,
-- another character), is not explained as "factions" when a whisper echoes.
reset()
WoW.faction = "Alliance"
AltStableDB = { [BEE_GUID] = { guid = BEE_GUID, name = BEE, class = "MAGE", level = 60,
                               lastUpdate = 1000, faction = "Horde" } }
listBee()
fromBee(L.MSG_CAP)
fake.peers = {}
WoW.chatOut = {}
SlashCmdList["ALTSTABLE"]("sync " .. BEE)
T.frame:GetScript("OnEvent")(T.frame, "CHAT_MSG_SYSTEM", ERR_CHAT_PLAYER_NOT_FOUND_S:format(BEE))
flush()
check("an own account that just left is not explained as 'factions'",
      said("through Battle.net") == 1 and said("do not cross factions") == 0)
WoW.faction = "Horde"

-- Battle.net game data is nobody's business now (#206): the legacy channel's
-- event is not even registered, and a REQ8 handed to the handler anyway is
-- dropped - not served, not asked about.
check("BN_CHAT_MSG_ADDON is not registered", not T.frame:IsEventRegistered("BN_CHAT_MSG_ADDON"))
check("  while Battle.net's coming and going still is", T.frame:IsEventRegistered("BN_CONNECTED")
      and T.frame:IsEventRegistered("BN_DISCONNECTED") and T.frame:IsEventRegistered("BN_INFO_CHANGED"))
reset()
WoW.bn.accounts[7] = { characterName = BEE, playerGuid = BEE_GUID, isOnline = true,
                       clientProgram = "WoW", wowProjectID = 18, isInCurrentRegion = true, regionID = 90,
                       factionName = "Horde", realmName = "R", bnetAccountID = WoW.bn.me }
T.frame:GetScript("OnEvent")(T.frame, "BN_CHAT_MSG_ADDON", T.PREFIX, T.MSG_REQUEST_V .. "|0", "WHISPER", 7)
flush()
eq("a legacy request over Battle.net game data is not answered", #WoW.sent, 0)
eq("  nor asked about", #AltStable.PendingSyncRequests(), 0)
check("  and does not make them our own account", not AltStable.IsOwnBNetPeer(BEE))
WoW.bn.accounts[7] = nil

-- /alts bnet: the switch, the library's own account of itself, and who is on
-- it - nothing from the legacy discovery's id walk (#206).
reset()
listBee()
fromBee(L.MSG_CAP)
fake.Diagnostics = function()
    local lines, k = { "LibAccountSync-1.0 r5, stand-in" }, 0
    return function() k = k + 1; return lines[k] end
end
WoW.chatOut = {}
SlashCmdList["ALTSTABLE"]("bnet")
eq("/alts bnet gives the switch", said("Battle.net sync: setting on"), 1)
eq("  the library's own lines", said("LibAccountSync-1.0 r5, stand-in"), 1)
eq("  and who is on the library", said("on the library: " .. BEE), 1)
eq("  and nothing from the old id walk", said("game account(s) known") + said("id 7:"), 0)

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
eq("a peer not heard on the library: the request is whispered", #wire(T.MSG_REQUEST_V), 1)
eq("  and nothing over the library", #fake.sent, 0)

reset()
listBee()
fromBee(L.MSG_CAP)
fake.sent = {}
local sentResults = {}
L.SendRequest(REQ, "BNET", BEE, "ALERT", function(ok) sentResults[#sentResults + 1] = ok end)
eq("on the library: one SendTo", #fake.sent, 1)
eq("  to their GUID", fake.sent[1] and fake.sent[1].guid, BEE_GUID)
eq("  carrying the whisper command unchanged", fake.sent[1] and fake.sent[1].msg, REQ)
eq("  and no whisper", #wire(), 0)
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
eq("refused (not-ready): a whispered request falls back to the whisper", #wire(T.MSG_REQUEST_V), 1)
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
eq("  and no whisper", #wire(), 0)

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

-- A copy without the #18 delivery, or without SendTo: not the library.
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
check("  with our clock at the end, as the whispered stream has", raw and raw:find("\n==NOW==:", 1, true) ~= nil, raw)
eq("  and no whispered chunks", #wire(T.MSG_CHUNK_V), 0)

-- A whisper to our own account on the library: the library, not the whisper.
reset()
seed()
listBee()
fromBee(L.MSG_CAP)
fake.sent = {}
T.SendFullDatabase("WHISPER", BEE)
check("a push by whisper to an own account on the library goes over it", dbSent() ~= nil)
eq("  and not also as whispered chunks", #wire(T.MSG_CHUNK_V), 0)

-- Refused (too large, not-ready): a whispered push falls back to whispered
-- chunks for this one send - still to this one peer.
reset()
seed()
listBee()
fromBee(L.MSG_CAP)
fake.sent, fake.ret = {}, nil
T.SendFullDatabase("WHISPER", BEE)
check("a refused push goes out as whispered chunks", #wire(T.MSG_CHUNK_V) > 0)
eq("  after one SendTo", #fake.sent, 1)
for _, m in ipairs(wire()) do
    if m.target ~= BEE then check("  every whisper to them alone", false, m.target) break end
end

------------------------------------------------------------
-- Inbound: the same gates as the whisper path
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

-- The library refuses a database (too large, not-ready) sent as "BNET": there
-- is no other way across, so it goes nowhere, and no whisper reaches anyone.
reset()
seed()
listBee()
fromBee(L.MSG_CAP)
fake.sent, fake.ret = {}, nil
T.SendFullDatabase("BNET", BEE)
eq("a refused database over \"BNET\": no whisper to anyone", #wire(), 0)
eq("  after its one SendTo", count(L.MSG_DB .. "|", true), 1)

-- Refused as too large: that never gets better by asking again, so the player
-- is told - once per send, naming who and the limit. Any other refusal is the
-- requester's stall watch to report.
local function saidHere(text)
    for _, l in ipairs(WoW.chatOut) do if l:find(text, 1, true) then return true end end
    return false
end
reset()
seed()
listBee()
fromBee(L.MSG_CAP)
fake.sent, fake.ret, fake.why = {}, nil, "too-large"
WoW.chatOut = {}
T.SendFullDatabase("BNET", BEE)
check("a database the library finds too large is reported", saidHere("too large to send to " .. BEE))
check("  with the limit", saidHere("the limit is 32 KB"))
fake.why = "not-ready"
WoW.chatOut = {}
T.SendFullDatabase("BNET", BEE)
check("  a not-ready refusal is not called too large", not saidHere("too large"))
fake.why = nil

------------------------------------------------------------
-- A peer only the library proved ours is a sync target (Codex, #204)
------------------------------------------------------------
local function targetsFor(name)
    local out = {}
    for _, t in ipairs(T.GetSyncTargets()) do
        if t.target == name then out[#out + 1] = t end
    end
    return out
end

reset()
listBee()
fromBee(L.MSG_CAP)
local tb = targetsFor(BEE)
eq("a library-only peer is a sync target", #tb, 1)
eq("  over \"BNET\", the library route", tb[1] and tb[1].channel, "BNET")
AltStableConfig.whitelist = { BEE }
eq("  once, whitelisted as well", #targetsFor(BEE), 1)
eq("  over \"WHISPER\" then: the library still, with the whisper to fall back on",
   targetsFor(BEE)[1] and targetsFor(BEE)[1].channel, "WHISPER")
eq("  the route /alts sync <name> takes too", AltStable.SyncChannelFor(BEE), "WHISPER")
AltStableConfig.whitelist = nil
AltStableConfig.syncAuth = { [BEE:lower()] = "never" }
eq("  never, when refused for good", #targetsFor(BEE), 0)
AltStableConfig.syncAuth = nil
fake.peers = {}
eq("  and not once the library stops listing it", #targetsFor(BEE), 0)

-- /alts cleanup wipes the database, then pushes and asks every target: a
-- library-only peer is how the data comes back.
reset()
seed()
listBee()
fromBee(L.MSG_CAP)
fake.sent = {}
local realRefresh = AltStable.RefreshSheet
AltStable.RefreshSheet = nil
SlashCmdList["ALTSTABLE"]("cleanup")
for _ = 1, 5 do WoW.now = WoW.now + 5; flush() end
AltStable.RefreshSheet = realRefresh
check("/alts cleanup pushes to a library-only peer", count(L.MSG_DB .. "|", true) >= 1)
check("  and asks it for its data back", count(T.MSG_REQUEST_V .. "|", true) >= 1)

------------------------------------------------------------
-- The saved off switch holds from the start (Codex, #204)
------------------------------------------------------------
-- r5 reads store.enabled whenever nothing set it this session, and absent
-- means on: an upgrade with Battle.net sync off must not let the library
-- start before the first rescan turns it off.
L.inst = real
LAS.state.enabled = nil
real.enabled = nil
AltStableConfig = { bnetSync = false }
local st = L.Store()
eq("a store built with Battle.net sync off is switched off", st.enabled, false)
eq("  and the real library reads it so", real.IsEnabled(), false)
AltStableConfig.bnetSync = nil
L.Store()
eq("  and follows the setting back on", st.enabled, true)
eq("  as the library reads it", real.IsEnabled(), true)

print(("test_accountsync: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
