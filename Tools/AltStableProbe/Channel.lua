----------------------------------------------------------------------------
-- /asprobe channel ... - the #58 channel measurements
--
-- docs/SYNC-DISCOVERY.md, "Measure before building any of it". The discovery
-- design wants a private custom channel as the rendezvous for one household's
-- characters. Before building on it, measure on this client:
--
--   1. does SendAddonMessage(..., "CHANNEL", id) deliver, and what result code
--      comes back when it does not;
--   2. is a custom channel shared ACROSS RULESETS (the "realms" of Forever are
--      four rulesets over one region - names are region-wide), and across
--      factions (whispers are not: measured on 70124);
--   3. does a temporary channel stay out of the chat frames, and survive a relog;
--   4. what happens at the channel-count cap;
--   5. what CHAT_MSG_ADDON carries for a channel message (every argument);
--   7. does a whisper reply to a channel sender's `sender` string arrive.
-- (6 - a whisper to an offline character shows "No player named" - is measured.)
--
-- Everything goes to the wire log: /asprobe copy after a session.
----------------------------------------------------------------------------

AltStableProbe = AltStableProbe or {}

local PREFIX = "ASPROBE"
local CAP_PREFIX = "ASPCap"
local CAP_TRIES = 15

local function Log(s)
    if AltStableProbe.WireRecord then AltStableProbe.WireRecord(s)
    else DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[probe]|r " .. tostring(s)) end
end

local RESULT_NAME = {}
if Enum and Enum.SendAddonMessageResult then
    for k, v in pairs(Enum.SendAddonMessageResult) do RESULT_NAME[v] = k end
end
local function ResultStr(r)
    return tostring(r) .. (RESULT_NAME[r] and (" (" .. RESULT_NAME[r] .. ")") or "")
end

-- Every value, in order, nils included: the argument COUNT is part of the answer.
local function Args(...)
    local n, out = select("#", ...), {}
    for i = 1, n do out[i] = i .. "=" .. tostring((select(i, ...))) end
    return ("(%d) %s"):format(n, table.concat(out, "  "))
end

local function Me()
    local full = AltStable and AltStable.API and AltStable.API.PlayerFullName
        and AltStable.API.PlayerFullName()
    return full or (UnitName and UnitName("player")) or "?"
end
local function Where()
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName())
    return ("%s / %s / %s"):format(Me(), tostring(UnitFactionGroup and UnitFactionGroup("player")),
        tostring(realm))
end

local function Exists(name) return type(_G[name]) == "function" end

-- Which chat windows list the channel: "stays out of the chat frame" (3).
local function InChatFrames(name)
    local hits = {}
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local f = _G["ChatFrame" .. i]
        if f and f.ContainsChannel then
            local ok, yes = pcall(f.ContainsChannel, f, name)
            if ok and yes then hits[#hits + 1] = "ChatFrame" .. i end
        end
    end
    return #hits > 0 and table.concat(hits, ",") or "none"
end

local function ChannelList()
    if not Exists("GetChannelList") then return "GetChannelList absent" end
    return Args(GetChannelList())
end

local function Status(name)
    if name and name ~= "" then
        Log(("  GetChannelName(%s) -> %s"):format(name, Args(GetChannelName(name))))
        Log(("  shown in chat windows: %s"):format(InChatFrames(name)))
    end
    Log("  GetChannelList -> " .. ChannelList())
end

local function Join(name, password)
    local fn = Exists("JoinTemporaryChannel") and "JoinTemporaryChannel"
        or Exists("JoinChannelByName") and "JoinChannelByName" or nil
    Log(("join %s  [JoinTemporaryChannel %s, JoinChannelByName %s, JoinPermanentChannel %s]"):format(
        name, tostring(Exists("JoinTemporaryChannel")), tostring(Exists("JoinChannelByName")),
        tostring(Exists("JoinPermanentChannel"))))
    if not fn then Log("  |cffff5555no join function|r"); return end
    local r = { pcall(_G[fn], name, password) }
    Log(("  %s -> %s"):format(fn, Args(unpack(r, 1, table.maxn(r)))))
    AltStableProbeDB.channelName = name
    -- The server confirms asynchronously; look again in a moment.
    C_Timer.After(1.5, function() Log("after join:"); Status(name) end)
end

local function LocalId(name)
    local id = GetChannelName(name)
    return (type(id) == "number" and id > 0) and id or nil
end

local function Send(name, kind)
    local id = LocalId(name)
    if not id then Log(("send: not in channel %s - /asprobe channel join %s first"):format(name, name)); return end
    local msg = (kind or "CPING") .. "|" .. Where() .. "|" .. time()
    -- Number and string targets both deliver (measured, 70124): send once.
    for _, target in ipairs({ id }) do
        local ok, r = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "CHANNEL", target)
        Log(("send %s on %s (target %s %s) -> %s"):format(kind or "CPING", name, type(target),
            tostring(target), ok and ResultStr(r) or ("ERROR " .. tostring(r))))
        if kind then break end        -- replies once
    end
end

local function Leave(name)
    if not Exists("LeaveChannelByName") then Log("LeaveChannelByName absent"); return end
    Log(("leave %s -> %s"):format(name, Args(pcall(LeaveChannelByName, name))))
    if AltStableProbeDB.channelName == name then AltStableProbeDB.channelName = nil end
end

-- (4) Join throwaway channels until the client refuses, then leave them all.
local capActive = false
local function Cap()
    capActive = true
    Log(("cap: joining %s1..%d, 0.4s apart; the channel notices are logged"):format(CAP_PREFIX, CAP_TRIES))
    Status(nil)
    for i = 1, CAP_TRIES do
        C_Timer.After(i * 0.4, function()
            local name = CAP_PREFIX .. i
            local r = { pcall(JoinTemporaryChannel or JoinChannelByName, name) }
            C_Timer.After(0.3, function()
                Log(("  %-9s join -> %s   id -> %s"):format(name, Args(unpack(r, 1, table.maxn(r))),
                    Args(GetChannelName(name))))
            end)
        end)
    end
    C_Timer.After(CAP_TRIES * 0.4 + 2, function()
        Log("cap: at the end"); Status(nil)
        for i = 1, CAP_TRIES do pcall(LeaveChannelByName, CAP_PREFIX .. i) end
        C_Timer.After(1.5, function()
            capActive = false
            Log("cap: left them all"); Status(nil)
        end)
    end)
end

function AltStableProbe.Channel(arg)
    local sub, rest = (arg or ""):match("^(%S*)%s*(.*)$")
    sub = (sub or ""):lower()
    local name, password = rest:match("^(%S+)%s*(%S*)$")
    if password == "" then password = nil end
    if sub ~= "log" and sub ~= "clear" then
        Log(("|cffffd100== channel %s ==|r  %s"):format(sub, Where()))
    end
    if sub == "join" and name then Join(name, password)
    elseif sub == "send" and name then Send(name)
    elseif sub == "leave" and name then Leave(name)
    elseif sub == "status" then Status(name or AltStableProbeDB.channelName)
    elseif sub == "cap" then Cap()
    elseif sub == "log" then
        -- The wire log, which survives /reload and relogs - /asprobe copy shows
        -- the last SWEEP instead, which is how a first round came back empty.
        local w = AltStableProbeDB.wireLog or {}
        local out = { "AltStableProbe channel log  " .. Where() }
        for i = math.max(1, #w - 400), #w do out[#out + 1] = w[i] end
        ShowCopy(out)
    elseif sub == "clear" then
        AltStableProbeDB.wireLog = {}
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[probe]|r channel log cleared")
    else
        Log("usage: /asprobe channel join <name> [password] | send <name> | status [name] | leave <name> | cap | log | clear")
    end
end

----------------------------------------------------------------------------
-- Receiving: every argument, and replies that answer 1, 2 and 7
----------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
f:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE_USER")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        -- (3) survives a relog? Look once the client has settled.
        local name = AltStableProbeDB and AltStableProbeDB.channelName
        if name then
            C_Timer.After(8, function()
                Log(("|cffffd100after login|r: still in %s?"):format(name))
                Status(name)
            end)
        end
        return
    end
    if event == "CHAT_MSG_CHANNEL_NOTICE" or event == "CHAT_MSG_CHANNEL_NOTICE_USER" then
        local notice, _, _, _, _, _, _, _, channelName = ...
        local ours = capActive or (type(channelName) == "string"
            and (channelName:find(CAP_PREFIX, 1, true)
                 or (AltStableProbeDB.channelName and channelName:lower():find(AltStableProbeDB.channelName:lower(), 1, true))))
        if ours then Log(("  %s %s"):format(event, Args(...))) end
        return
    end
    local prefix, text, channel, sender = ...
    if prefix ~= PREFIX then return end
    local kind = tostring(text):match("^(%u+)|")
    if kind ~= "CPING" and kind ~= "CPONG" and kind ~= "WPONG" then return end
    -- A channel message comes back to its own sender (measured, 70124).
    -- Logged, never answered: answering ourselves proved nothing last round.
    if sender == Me() then
        Log(("RECV %s from OURSELVES (own channel echo) - ignored"):format(kind))
        return
    end
    Log(("|cff55ff55RECV %s|r %s"):format(kind, Args(...)))
    if kind == "CPING" then
        -- Reply on the channel (1, 2), and by whisper to `sender` exactly as it
        -- arrived (7): a cross-ruleset sender's form is the thing measured.
        local name = AltStableProbeDB.channelName
        if name then Send(name, "CPONG") end
        local ok, r = pcall(C_ChatInfo.SendAddonMessage, PREFIX, "WPONG|" .. Where() .. "|" .. time(),
            "WHISPER", sender)
        Log(("  whisper WPONG to sender %q -> %s"):format(tostring(sender),
            ok and ResultStr(r) or ("ERROR " .. tostring(r))))
    elseif kind == "CPONG" then
        Log("  |cff55ff55CHANNEL ROUND-TRIP OK|r - they got our CPING and answered on the channel")
    elseif kind == "WPONG" then
        Log("  |cff55ff55WHISPER-BACK OK|r - a whisper to our channel `sender` string reached us")
    end
end)
