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
    local ok, r = pcall(C_BattleNet.SendGameData, id, PREFIX, "BPING|" .. Where() .. "|" .. time())
    Log(("  SendGameData(%d, BPING) -> %s"):format(id, ok and ResultStr(r) or ("ERROR " .. tostring(r))))
    Log("  >> a BPONG line on this character, or a RECV BPING on the other, is the proof it arrived")
end

function AltStableProbe.BNet(arg)
    local sub, rest = (arg or ""):match("^(%S*)%s*(.*)$")
    sub = (sub or ""):lower()
    if sub == "me" then Me()
    elseif sub == "send" then Send(rest)
    else Log("usage: /asprobe bnet me | send <gameAccountID>") end
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
        local ok, r = pcall(C_BattleNet.SendGameData, senderID, PREFIX, "BPONG|" .. Where() .. "|" .. time())
        Log(("  BPONG back to %s -> %s"):format(tostring(senderID), ok and ResultStr(r) or ("ERROR " .. tostring(r))))
    elseif kind == "BPONG" then
        Log("  |cff55ff55BNET ROUND-TRIP OK|r - our own other account answered over Battle.net")
    end
end)
