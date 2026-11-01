------------------------------------------------------------
-- test_provenance.lua - ownership provenance and the own-account channel (#281)
--
-- What another addon (Glass Gear first) is promised in docs/PUBLIC-API.md:
--   * every character is "self", "own-account" or "third-party", and only
--     first-hand word from an account LibAccountSync proved ours makes one
--     "own-account" - never a whitelisted friend, a relayed record, an unknown
--     sender, or a field a peer put on the record;
--   * the own-account channel reaches our own accounts only, and hears from
--     them only, gated before the consumer's code runs.
-- The library is a fake instance, as in test_accountsync.lua: its own suite
-- owns the proof; this one owns what AltStable does with it.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
dofile("tests/libaccountsync.lua")
LoadAccountSync("AltStable")
dofile("Libs/LibStub/LibStub.lua")
dofile("Libs/LibDeflate/LibDeflate.lua")

AltStable, AltStableDB, AltStableConfig = {}, {}, {}
dofile("Compat.lua")
dofile("Prompt.lua")
assert(loadfile("Core.lua"))()
dofile("Config.lua")
AltStable.RefreshSheet = function() end
dofile("PublicAPI.lua")

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

local fake
local function freshFake()
    fake = { messages = true, sent = {}, peers = {}, ret = 1, enabled = true }
    function fake.SendTo(guid, msg, onResult)
        fake.sent[#fake.sent + 1] = { guid = guid, msg = msg, onResult = onResult }
        return fake.ret, fake.why
    end
    function fake.Peers() return fake.peers end
    function fake.SetEnabled(on) fake.enabled = on end
    function fake.IsEnabled() return fake.enabled end
    L.inst = fake
    L.Forget()
end

local BEE, BEE_GUID = "Bee Surname", "Player-1-0000BEE"
local FRIEND = "Friend Person"
local function listBee() fake.peers = { { name = BEE, guid = BEE_GUID, realm = "R", faction = "Horde" } } end
local function fromBee(payload)
    L.OnMessage(payload, { name = BEE, guid = BEE_GUID, realm = "R", faction = "Horde", proven = "bnet" })
end
-- Bee on the library and heard from: proven our own account this session.
local function proveBee()
    listBee()
    fromBee(L.MSG_CAP)
    fake.sent = {}
end
local function reset()
    -- A callback still scheduled would stay pending for good once WoW.reset
    -- drops its timer.
    flush()
    WoW.reset(); T.ResetSyncState()
    AltStableDB = {}
    AltStableConfig = { peerWatermarks = {}, sendAllAccounts = true, whitelist = { FRIEND } }
    freshFake()
    flush()
end
local function deflated(text) return L.MSG_DB .. "|" .. LD:CompressDeflate(text, { level = 8 }) end
local function payloadOf(db, extra)
    local saved = AltStableDB
    AltStableDB = db
    local p = T.SerializeFullDB(false)
    AltStableDB = saved
    for _, line in ipairs(extra or {}) do p = p .. "\n" .. line end
    return p .. "\n==NOW==:5000"
end
local function prov(guid) return AltStable.GetCharacterProvenance(guid) end

-- What the other account holds: its own character Zed, and Fay, a friend's
-- character it synced in.
local ZED, FAY = "Player-9-ZED", "Player-9-FAY"
local function theirDB()
    return {
        [ZED] = { guid = ZED, name = "Zed", class = "DRUID", level = 30, lastUpdate = 2000 },
        [FAY] = { guid = FAY, name = "Fay", class = "MAGE", level = 20, lastUpdate = 2000 },
    }
end
local MINE_ZED = "==MINE1==" .. ZED

local seen = {}
for _, ev in ipairs({ "ProvenanceChanged", "OwnAccountPeersChanged" }) do
    AltStable.RegisterCallback(ev, function(e) seen[e] = (seen[e] or 0) + 1 end)
end

------------------------------------------------------------
-- The feature flags
------------------------------------------------------------
check("the features table says provenance is there",
      type(AltStable.PUBLIC_API_FEATURES) == "table" and AltStable.PUBLIC_API_FEATURES.provenance == true)
eq("  and the own-account channel", AltStable.PUBLIC_API_FEATURES.ownAccountChannel, true)
eq("PUBLIC_API_VERSION is unchanged: these are additions", AltStable.PUBLIC_API_VERSION, 1)

------------------------------------------------------------
-- Own account, first-hand: own-account
------------------------------------------------------------
reset()
proveBee()
seen = {}
WoW.now = 7000
fromBee(deflated(payloadOf(theirDB(), { MINE_ZED })))
flush()
local kind, at, via = prov(ZED)
eq("our own account's own character is own-account", kind, "own-account")
eq("  established now", at, 7000)
eq("  by that account", via, BEE)
eq("ProvenanceChanged fired once for the burst", seen.ProvenanceChanged, 1)

-- Relayed by our own account: Fay is a friend's character.
eq("a character our own account relayed is third-party", (prov(FAY)), "third-party")

-- GetCharacters carries the same three fields.
local byGuid = {}
for _, c in ipairs(AltStable.GetCharacters()) do byGuid[c.guid] = c end
eq("GetCharacters: provenance", byGuid[ZED] and byGuid[ZED].provenance, "own-account")
eq("  provenanceAt", byGuid[ZED] and byGuid[ZED].provenanceAt, 7000)
eq("  provenanceVia", byGuid[ZED] and byGuid[ZED].provenanceVia, BEE)
eq("  and third-party for the relayed one", byGuid[FAY] and byGuid[FAY].provenance, "third-party")
eq("  with no via", byGuid[FAY] and byGuid[FAY].provenanceVia, nil)

-- Said again: nothing new, no callback.
seen = {}
fromBee(deflated(payloadOf(theirDB(), { MINE_ZED })))
flush()
eq("said again, no ProvenanceChanged", seen.ProvenanceChanged, nil)
eq("  and the time it was established stays", select(2, prov(ZED)), 7000)

-- It only moves up: a newer copy from a friend says nothing about ownership.
local newer = theirDB()
newer[ZED].lastUpdate = 9000
T.DeserializeFullDB(payloadOf(newer), FRIEND)
eq("a friend's newer copy does not downgrade it", (prov(ZED)), "own-account")
eq("  though the record itself merged", AltStableDB[ZED].lastUpdate, 9000)

-- A delta that carries none of the records still establishes the ones held.
reset()
AltStableDB = theirDB()
proveBee()
fromBee(deflated(payloadOf({}, { MINE_ZED })))
eq("the line alone marks a record we already hold", (prov(ZED)), "own-account")
eq("  and only the ones it names", (prov(FAY)), "third-party")

-- A guid it names that we do not hold is skipped, not invented.
reset()
proveBee()
fromBee(deflated(payloadOf({}, { "==MINE1==Player-9-NOBODY" })))
eq("a named character we do not hold is not created", AltStableDB["Player-9-NOBODY"], nil)

------------------------------------------------------------
-- Everyone else: third-party
------------------------------------------------------------
-- A whitelisted friend sending the same line, by whisper.
reset()
T.DeserializeFullDB(payloadOf(theirDB(), { MINE_ZED }), FRIEND)
check("a whitelisted friend's records merge", AltStableDB[ZED] ~= nil)
eq("  but its line makes nothing own-account", (prov(ZED)), "third-party")

-- Our own account's name, but the library does not list it (offline, or
-- another character on that name): not trusted as ours.
reset()
T.DeserializeFullDB(payloadOf(theirDB(), { MINE_ZED }), BEE)
eq("a name the library does not list now: third-party", (prov(ZED)), "third-party")

-- An unknown sender over the library is not admitted at all.
reset()
fromBee(deflated(payloadOf(theirDB(), { MINE_ZED })))
eq("an unlisted sender over the library: nothing merged", AltStableDB[ZED], nil)

-- Fields on the record are never ownership: not the provenance fields, not
-- scannedHere, not the account label.
reset()
AltStableDB = { [ZED] = { guid = ZED, name = "Zed", class = "DRUID", level = 30, lastUpdate = 1000 } }
local forged = table.concat({
    "guid:" .. ZED, "name:Zed", "class:DRUID", "level:31", "lastUpdate:3000",
    "scannedHere:1", "provKind:own-account", "provAt:1", "provVia:" .. BEE, "account:1",
    T.CHAR_SEP,
}, "\n")
T.DeserializeFullDB(forged .. "\n==NOW==:5000", FRIEND)
eq("a forged record merged (level)", AltStableDB[ZED].level, 31)
eq("  without scannedHere", AltStableDB[ZED].scannedHere, nil)
eq("  without provKind", AltStableDB[ZED].provKind, nil)
eq("  without provAt", AltStableDB[ZED].provAt, nil)
eq("  without provVia", AltStableDB[ZED].provVia, nil)
eq("  and it stays third-party", (prov(ZED)), "third-party")
-- Not guarded as ours afterwards: an older record from the friend still lands
-- inside the normal 60 s grace, as for any record that is not our scan.
local older = table.concat({ "guid:" .. ZED, "name:Zed", "class:DRUID", "level:29",
                             "lastUpdate:2990", T.CHAR_SEP }, "\n")
T.DeserializeFullDB(older, FRIEND)
eq("  and not guarded as our own scan", AltStableDB[ZED].level, 29)

-- The single-record path drops them too.
reset()
local c = T.DeserializeChar("guid:" .. ZED .. "\nname:Zed\nscannedHere:1\nprovKind:self")
eq("DeserializeChar drops scannedHere", c and c.scannedHere, nil)
eq("  and provKind", c and c.provKind, nil)

-- And never sends them.
local wireRec = T.SerializeChar({ guid = "Player-1-A", name = "Alpha", scannedHere = true,
                                  provKind = "self", provAt = 5, provVia = "x" })
check("SerializeChar sends no provenance field",
      not wireRec:find("prov", 1, true) and not wireRec:find("scannedHere", 1, true), wireRec)

------------------------------------------------------------
-- Self
------------------------------------------------------------
reset()
AltStableDB = { ["Player-1-A"] = { guid = "Player-1-A", name = "Alpha", scannedHere = true,
                                   provKind = "self", provAt = 1234 } }
local k, a = prov("Player-1-A")
eq("our own scan is self", k, "self")
eq("  since its stamp", a, 1234)
AltStableDB["Player-1-A"].provKind, AltStableDB["Player-1-A"].provAt = nil, nil
k, a = prov("Player-1-A")
eq("a record from before #281 is self from scannedHere alone", k, "self")
eq("  with no time", a, nil)
-- An own account naming one of ours does not take it, or touch its stamp.
AltStableDB["Player-1-A"].provKind, AltStableDB["Player-1-A"].provAt = "self", 1234
proveBee()
flush()
seen = {}
fromBee(deflated(payloadOf({}, { "==MINE1==Player-1-A" })))
flush()
eq("our own scan stays self when our other account names it", (prov("Player-1-A")), "self")
eq("  its stamp untouched", select(2, prov("Player-1-A")), 1234)
eq("  and no ProvenanceChanged", seen.ProvenanceChanged, nil)
eq("an unknown guid has no provenance", prov("Player-404"), nil)

------------------------------------------------------------
-- The sending side
------------------------------------------------------------
local function seedOurs()
    AltStableDB = {
        ["Player-1-A"] = { guid = "Player-1-A", name = "Alpha", class = "MAGE", level = 60,
                           lastUpdate = 1000, scannedHere = true },
        ["Player-1-B"] = { guid = "Player-1-B", name = "Beta", class = "ROGUE", level = 42,
                           lastUpdate = 1000, scannedHere = true },
        [FAY] = { guid = FAY, name = "Fay", class = "MAGE", level = 20, lastUpdate = 1000 },
    }
end
local function dbSent()
    for _, s in ipairs(fake.sent) do
        if s.msg:sub(1, #L.MSG_DB + 1) == L.MSG_DB .. "|" then return s end
    end
end

reset()
seedOurs()
proveBee()
T.SendFullDatabase("BNET", BEE)
local db = dbSent()
local raw = db and LD:DecompressDeflate(db.msg:sub(#L.MSG_DB + 2)) or ""
local line = raw:match("\n(==MINE1==[^\n]*)")
eq("to our own account: the characters we scan", line, "==MINE1==Player-1-A,Player-1-B")
local lastSep = 0
for i in raw:gmatch("()" .. T.CHAR_SEP) do lastSep = i end
local mineAt, nowAt = raw:find("==MINE1==", 1, true), raw:find("==NOW==", 1, true)
check("  after the last record, where an older parser drops it", mineAt and mineAt > lastSep)
check("  and before our clock", mineAt and nowAt and mineAt < nowAt)

-- To a friend: never. Watched at the source, since the whispered stream is
-- encoded.
reset()
seedOurs()
local P = T.Provenance
local realLine, asked = P.Line, 0
P.Line = function(...) asked = asked + 1; return realLine(...) end
T.SendFullDatabase("WHISPER", FRIEND)
P.Line = realLine
eq("to a whitelisted friend: no line", asked, 0)

reset()
AltStableDB = { [FAY] = { guid = FAY, name = "Fay", lastUpdate = 1 } }
eq("nothing scanned here: no line at all", T.Provenance.Line(), nil)

------------------------------------------------------------
-- The own-account channel: out
------------------------------------------------------------
local function extSent()
    local out = {}
    for _, s in ipairs(fake.sent) do
        if s.msg:sub(1, #L.MSG_EXT + 1) == L.MSG_EXT .. "|" then out[#out + 1] = s end
    end
    return out
end

reset()
eq("no own account found: nothing sent", (AltStable.SendToOwnAccounts("gg", "hi")), 0)
eq("  and says why", select(2, AltStable.SendToOwnAccounts("gg", "hi")), "no-peers")

proveBee()
local n = AltStable.SendToOwnAccounts("gg", "hello|with|bars\nand a newline")
eq("to our own account: taken by the library", n, 1)
local ext = extSent()
eq("  one message", #ext, 1)
eq("  to its GUID", ext[1] and ext[1].guid, BEE_GUID)
eq("  framed with the namespace", ext[1] and ext[1].msg, "EXT1|gg|hello|with|bars\nand a newline")
eq("  and no whisper to anyone (a friend included)", #WoW.sent, 0)

fake.sent = {}
eq("to a GUID that is ours", AltStable.SendToOwnAccounts("gg", "x", BEE_GUID), 1)
fake.sent = {}
eq("to a GUID that is not: nothing", AltStable.SendToOwnAccounts("gg", "x", "Player-9-FRIEND"), 0)
eq("  sent nowhere", #fake.sent, 0)

fake.sent = {}
local big = ("x"):rep(L.MAX_PAYLOAD)
local nb, why = AltStable.SendToOwnAccounts("gg", big)
eq("over the library's cap: refused", nb, 0)
eq("  as too-large", why, "too-large")
eq("  before anything went", #fake.sent, 0)

fake.ret, fake.why = nil, "not-ready"
local nr, whyr = AltStable.SendToOwnAccounts("gg", "x")
eq("the library refusing: 0", nr, 0)
eq("  with its reason", whyr, "not-ready")
fake.ret, fake.why = 1, nil

-- Refused for good: not one of the targets.
AltStableConfig.syncAuth = { [T.AuthKey and T.AuthKey(BEE) or BEE:lower()] = "never" }
fake.sent = {}
eq("an own account refused for good gets nothing", AltStable.SendToOwnAccounts("gg", "x"), 0)
eq("  and is not listed as a peer", #AltStable.GetOwnAccountPeers(), 0)
AltStableConfig.syncAuth = nil

local peers = AltStable.GetOwnAccountPeers()
eq("GetOwnAccountPeers lists our own account", #peers, 1)
eq("  by GUID", peers[1] and peers[1].guid, BEE_GUID)
peers[1].guid = "changed"
eq("  as a copy", AltStable.GetOwnAccountPeers()[1].guid, BEE_GUID)

AltStableConfig.bnetSync = false
eq("Battle.net sync off: nothing sent", (AltStable.SendToOwnAccounts("gg", "x")), 0)
AltStableConfig.bnetSync = nil

for _, bad in ipairs({ "", "has|bar", "has space", ("n"):rep(33) }) do
    check("namespace " .. ("%q"):format(bad) .. " is an error",
          not pcall(AltStable.SendToOwnAccounts, bad, "x"))
end
check("a non-string payload is an error", not pcall(AltStable.SendToOwnAccounts, "gg", 5))

------------------------------------------------------------
-- The own-account channel: in
------------------------------------------------------------
local got = {}
AltStable.RegisterOwnAccountHandler("gg", function(payload, sender)
    got[#got + 1] = { payload = payload, sender = sender }
end)

reset()
proveBee()
fromBee("EXT1|gg|hello|with|bars")
eq("from our own account: delivered", #got, 1)
eq("  the payload whole", got[1] and got[1].payload, "hello|with|bars")
eq("  with the proven sender's GUID", got[1] and got[1].sender.guid, BEE_GUID)
eq("  and name", got[1] and got[1].sender.name, BEE)
eq("  and realm", got[1] and got[1].sender.realm, "R")

got = {}
fromBee("EXT1|other|x")
eq("a namespace nobody registered: dropped", #got, 0)
fromBee("EXT1|nonamespace")
eq("no namespace at all: dropped", #got, 0)

-- Not listed by the library now: not ours.
reset()
fromBee("EXT1|gg|x")
eq("from a sender the library does not list: not delivered", #got, 0)

-- Refused for good.
reset()
listBee()
AltStableConfig.syncAuth = { [T.AuthKey and T.AuthKey(BEE) or BEE:lower()] = "never" }
fromBee("EXT1|gg|x")
eq("from an own account refused for good: not delivered", #got, 0)

-- By whisper - a friend, or anyone: the channel is the library only.
reset()
T.frame:GetScript("OnEvent")(T.frame, "CHAT_MSG_ADDON", T.PREFIX, "EXT1|gg|x", "WHISPER", FRIEND)
eq("by whisper: never delivered", #got, 0)

-- A handler's error is the consumer's: reported, and the next message still comes.
reset()
proveBee()
local caught = {}
local realHandler = geterrorhandler
geterrorhandler = function() return function(e) caught[#caught + 1] = e end end
AltStable.RegisterOwnAccountHandler("gg", function() error("consumer bug") end)
fromBee("EXT1|gg|x")
geterrorhandler = realHandler
eq("a handler's error is reported", #caught, 1)
AltStable.RegisterOwnAccountHandler("gg", function(p) got[#got + 1] = { payload = p } end)
fromBee("EXT1|gg|y")
eq("  and the next message is delivered", got[#got] and got[#got].payload, "y")

-- The sender table is the handler's own: changing it changes nothing of ours.
AltStable.RegisterOwnAccountHandler("gg", function(_, s) s.guid = "changed" end)
fromBee("EXT1|gg|z")
eq("a handler changing its sender changes nothing of ours", L.Peer(BEE) and L.Peer(BEE).guid, BEE_GUID)
AltStable.UnregisterOwnAccountHandler("gg")
got = {}
fromBee("EXT1|gg|after")
eq("unregistered: no longer delivered", #got, 0)

------------------------------------------------------------
-- OwnAccountPeersChanged
------------------------------------------------------------
reset()
seen = {}
proveBee()
flush()
eq("an own account found: OwnAccountPeersChanged", seen.OwnAccountPeersChanged, 1)
seen = {}
fromBee(L.MSG_CAP)
flush()
eq("  heard again: no callback", seen.OwnAccountPeersChanged, nil)
T.frame:GetScript("OnEvent")(T.frame, "BN_DISCONNECTED")
flush()
eq("Battle.net gone: OwnAccountPeersChanged", seen.OwnAccountPeersChanged, 1)
proveBee()
flush()
seen = {}
fake.peers = {}
L.Peer(BEE)
flush()
eq("the library stops listing it: OwnAccountPeersChanged", seen.OwnAccountPeersChanged, 1)

-- Refused, and the refusal taken back (Codex, #282): the list changes with the
-- same binding, so nothing from them would say so.
reset()
proveBee()
flush()
seen = {}
AltStable.DenySyncPeer(BEE)
flush()
eq("refusing an own account: OwnAccountPeersChanged", seen.OwnAccountPeersChanged, 1)
eq("  and it is off the list", #AltStable.GetOwnAccountPeers(), 0)
seen = {}
AltStable.DenySyncPeer(BEE)
flush()
eq("  refused again: no callback", seen.OwnAccountPeersChanged, nil)
AltStable.ForgetSyncPeer(BEE)
flush()
eq("taking the refusal back: OwnAccountPeersChanged", seen.OwnAccountPeersChanged, 1)
eq("  and it is on the list again", #AltStable.GetOwnAccountPeers(), 1)
seen = {}
AltStable.DenySyncPeer(BEE)
flush()
seen = {}
AltStable.AllowSyncPeer(BEE)
flush()
eq("allowing a refused one: OwnAccountPeersChanged", seen.OwnAccountPeersChanged, 1)
seen = {}
AltStable.DenySyncPeer(FRIEND)
flush()
eq("refusing a friend: no callback (not an own account)", seen.OwnAccountPeersChanged, nil)

print(("test_provenance: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
