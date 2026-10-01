----------------------------------------------------------------------------
-- /asprobe bnet ... - can one of the owner's WoW accounts reach the OTHER
-- through Battle.net game data?
--
-- Channels and whispers stop at the ruleset and the faction (measured,
-- 70124). C_BattleNet.SendGameData crosses both - it is how Overlord relays
-- between Horde and Alliance ("Battle.net bridges") - but its target is a
-- game account id, and Overlord only ever targets a FRIEND's. The owner's two
-- WoW accounts sit under one Battle.net account, which cannot friend itself;
-- SYNC-DISCOVERY recorded that as closed without measuring it. The question:
-- will the server deliver game data to your OWN other game account?
--
--   /asprobe bnet me          this account's Battle.net identity and game
--                             account id (the other account's send target)
--   /asprobe bnet send <id>   a BPING to that game account id
--   (receiving a BPING)       every BN_CHAT_MSG_ADDON argument; a BPONG back
--                             to the sender's id
--
-- SendGameData returns an Enum.SendAddonMessageResult: the return alone says
-- whether the server took the target.
----------------------------------------------------------------------------

AltStableProbe = AltStableProbe or {}
local U = AltStableProbe.util
local Log, Args, ResultStr, Where = U.Log, U.Args, U.ResultStr, U.Where
local function Val(v) return AltStableProbe.ValStr and AltStableProbe.ValStr(v, 3) or tostring(v) end

local PREFIX = "ASPROBE"

-- One BPING/BPONG send and its log line (review of #141: it was copied 4 times).
local function Ping(id, kind, indent)
    local ok, r = pcall(C_BattleNet.SendGameData, id, PREFIX, kind .. "|" .. Where() .. "|" .. time())
    Log(("%sSendGameData(%s, %s) -> %s"):format(indent or "  ", tostring(id), kind,
        ok and ResultStr(r) or ("ERROR " .. tostring(r))))
end

local function Call(label, fn, ...)
    if type(fn) ~= "function" then Log(("  %s: absent"):format(label)); return end
    local r = { pcall(fn, ...) }
    if not r[1] then Log(("  %s: ERROR %s"):format(label, tostring(r[2]))); return end
    local parts = {}
    for i = 2, table.maxn(r) do parts[#parts + 1] = Val(r[i]) end
    Log(("  %s -> %s"):format(label, table.concat(parts, "  ")))
    return unpack(r, 2, table.maxn(r))
end

local function Me()
    Log("|cffffd100== bnet me ==|r  " .. Where())
    local BN = C_BattleNet or {}
    Call("BNGetInfo()", BNGetInfo)
    Call("BNFeaturesEnabledAndConnected()", BNFeaturesEnabledAndConnected)
    local info = Call("C_BattleNet.GetAccountInfoByGUID(player)", BN.GetAccountInfoByGUID, UnitGUID("player"))
    Call("C_BattleNet.GetGameAccountInfoByGUID(player)", BN.GetGameAccountInfoByGUID, UnitGUID("player"))
    local id = type(info) == "table" and type(info.gameAccountInfo) == "table"
        and info.gameAccountInfo.gameAccountID
    if id then
        Log(("  |cff55ff55this game account id: %s|r - on the other account: /asprobe bnet send %s"):format(
            tostring(id), tostring(id)))
        Call("C_BattleNet.GetGameAccountInfoByID(own id)", BN.GetGameAccountInfoByID, id)
    else
        Log("  |cffff5555no game account id found for this character|r")
    end
    -- For the record: friends online in WoW (Overlord's bridges are these).
    local n = Call("BNGetNumFriends()", BNGetNumFriends)
    Log(("  friends: %s"):format(tostring(n)))
end

local function Send(id)
    id = tonumber(id)
    Log("|cffffd100== bnet send ==|r  " .. Where())
    if not id then Log("usage: /asprobe bnet send <gameAccountID>  (from /asprobe bnet me on the other account)"); return end
    Call("C_BattleNet.GetGameAccountInfoByID(target)", C_BattleNet and C_BattleNet.GetGameAccountInfoByID, id)
    if not (C_BattleNet and C_BattleNet.SendGameData) then Log("  SendGameData absent"); return end
    Ping(id, "BPING")
    Log("  >> a BPONG line on this character, or a RECV BPING on the other, is the proof it arrived")
end

-- A game account id is a handle LOCAL to the client that hands it out: "7" on
-- one account's client is not the other account's name for it (measured: the
-- own id came back as 7). So the other account cannot be typed in; it has to
-- be looked up on THIS client, by the character's GUID - which AltStable's
-- database already holds for the other account's characters.
local function Scan()
    Log("|cffffd100== bnet scan ==|r  " .. Where())
    local BN = C_BattleNet or {}
    local mine = UnitGUID("player")
    local looked, found = 0, 0
    for guid, c in pairs(AltStableDB or {}) do
        if type(c) == "table" and type(guid) == "string" and guid:find("^Player%-") and guid ~= mine then
            looked = looked + 1
            local okG, game = pcall(BN.GetGameAccountInfoByGUID or function() end, guid)
            local okA, acct = pcall(BN.GetAccountInfoByGUID or function() end, guid)
            local id = (okG and type(game) == "table" and game.gameAccountID)
                or (okA and type(acct) == "table" and type(acct.gameAccountInfo) == "table"
                    and acct.gameAccountInfo.gameAccountID)
            if id or (okG and game) or (okA and acct) then
                found = found + 1
                Log(("  %s (%s): game %s"):format(tostring(c.name), guid, okG and Val(game) or "ERROR"))
                Log(("    account %s"):format(okA and Val(acct) or "ERROR"))
            end
            if id and BN.SendGameData then
                Ping(id, "BPING", "    ")
            end
        end
    end
    Log(("  looked up %d character(s) from the database; Battle.net knew %d"):format(looked, found))
    if found == 0 then
        Log("  >> nothing known: this client cannot see the other account's characters through Battle.net")
    end
end

-- Discovery with no GUID known in advance. Game account ids are small local
-- handles (measured: 3, 7, 8), so walk 1..MAX_ID and keep the ones on OUR OWN
-- Battle.net account - same bnetAccountID or BattleTag as ours - never a
-- friend's. Each one found online is pinged.
local MAX_ID = 100
local function Ids()
    Log("|cffffd100== bnet ids ==|r  " .. Where())
    local BN = C_BattleNet or {}
    local okMe, me = pcall(BN.GetAccountInfoByGUID or function() end, UnitGUID("player"))
    me = okMe and type(me) == "table" and me or {}
    local myGame = type(me.gameAccountInfo) == "table" and me.gameAccountInfo.gameAccountID
    Log(("  me: bnetAccountID=%s battleTag=%s gameAccountID=%s"):format(tostring(me.bnetAccountID),
        tostring(me.battleTag), tostring(myGame)))
    local seen, own = 0, 0
    for id = 1, MAX_ID do
        local ok, game = pcall(BN.GetGameAccountInfoByID or function() end, id)
        if ok and type(game) == "table" then
            seen = seen + 1
            local okA, acct = pcall(BN.GetAccountInfoByGUID or function() end, game.playerGuid)
            acct = okA and type(acct) == "table" and acct or {}
            local mine = (me.bnetAccountID and acct.bnetAccountID == me.bnetAccountID)
                or (me.battleTag and acct.battleTag == me.battleTag)
            Log(("  id %d: %s  %s / %s / %s  online=%s  program=%s  project=%s  %s"):format(id,
                tostring(game.characterName), tostring(game.factionName), tostring(game.realmName),
                tostring(game.playerGuid), tostring(game.isOnline), tostring(game.clientProgram),
                tostring(game.wowProjectID), mine and "|cff55ff55OUR ACCOUNT|r" or "(someone else)"))
            if mine and id ~= myGame and game.isOnline and BN.SendGameData then
                own = own + 1
                Ping(id, "BPING", "    ")
            end
        end
    end
    Log(("  ids 1-%d: %d known to this client, %d of them our own other online account(s)"):format(MAX_ID, seen, own))
end

function AltStableProbe.BNet(arg)
    local sub, rest = (arg or ""):match("^(%S*)%s*(.*)$")
    sub = (sub or ""):lower()
    if sub == "me" then Me()
    elseif sub == "send" then Send(rest)
    elseif sub == "scan" then Scan()
    elseif sub == "ids" then Ids()
    else Log("usage: /asprobe bnet me | scan | ids | send <gameAccountID>") end
end

local f = CreateFrame("Frame")
f:RegisterEvent("BN_CHAT_MSG_ADDON")
f:SetScript("OnEvent", function(_, _, ...)
    local prefix, text, _, senderID = ...
    if prefix ~= PREFIX then return end
    local kind = tostring(text):match("^(%u+)|")
    Log(("|cff55ff55RECV BN %s|r %s"):format(tostring(kind), Args(...)))
    Call("  GetGameAccountInfoByID(sender)", C_BattleNet and C_BattleNet.GetGameAccountInfoByID, senderID)
    if kind == "BPING" then
        Ping(senderID, "BPONG")
    elseif kind == "BPONG" then
        Log("  |cff55ff55BNET ROUND-TRIP OK|r - our own other account answered over Battle.net")
    end
end)
